//! A threaded test of a task's wake word (design.md "The Task Runtime"):
//! hosts finish operations on worker threads that race the task's park.
//!
//! Main runs every task's records. Each pausing record starts an operation,
//! which a worker finishes: it writes the operation's answer, then calls
//! `RocTask.wake`. A worker may wake the task before its resume reaches the
//! park, so the resume carries on without returning PENDING, or after it,
//! so the wake calls the host's `roc_task_ready`, and main resumes only a
//! task that was handed back. The properties:
//!
//! - every task finishes with its result;
//! - `roc_task_ready` arrives exactly once per park, and only for a parked
//!   task;
//! - the record after a pause reads the answer its worker wrote before the
//!   wake, which needs release ordering on the wake and acquire ordering on
//!   the consume. `zig build run-test-builtins-tsan` runs this file under
//!   ThreadSanitizer, which models those orderings exactly.
//!
//! Pauses come in three kinds (`PauseKind`), so both paths run across
//! threads every round whatever the timing: an early pause waits inside its
//! hosted call until the worker woke the task; for a late one the worker
//! waits until the task parked; a racing one is woken after a varying number
//! of spins. The whole run repeats.

const std = @import("std");

const task_mod = @import("task.zig");
const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const wake_parked = task_mod.wake_parked;

const task_count = 16;
const pauses_per_task = 8;
const worker_count = 4;
const rounds = 40;

/// One task and the operation it waits on.
const Slot = struct {
    task: *RocTask = undefined,
    /// Operations the task's records started; main writes it.
    started: std.atomic.Value(u32) = .init(0),
    /// Operations a worker finished; only that worker touches it.
    finished: u32 = 0,
    /// Wakes the worker made, for a record that waits for its own.
    wakes: std.atomic.Value(u32) = .init(0),
    /// What the worker wrote for its last operation: a plain write the wake
    /// must publish.
    answer: u32 = 0,
    /// Set by `roc_task_ready`, cleared by main when it resumes the task.
    readied: std.atomic.Value(bool) = .init(false),
    /// Whether the task's last resume returned PENDING. Main's.
    parked: bool = false,
    done: bool = false,
    root: [8]u8 = undefined,
};

/// What a record does when the task runs it.
const Step = struct {
    slot: *Slot,
    /// The record it saves for the task to run next, if any.
    next: ?[*]u8,
    /// The answer this record must read: the number of operations its task
    /// finished before it.
    expect_answer: u32,
    /// The result it writes through its result pointer.
    result: u8,
};

/// When a pause's worker wakes the task, chosen by the pause's index.
const PauseKind = enum {
    /// Before the hosted call returns, as a host that finished on another
    /// thread first: the resume carries on without parking.
    early,
    /// After the task parked: the wake hands it back.
    late,
    /// Whenever the worker gets to it.
    racing,

    fn of(pause: u32) PauseKind {
        return switch (pause % 3) {
            0 => .early,
            1 => .late,
            else => .racing,
        };
    }
};

var slots: [task_count]Slot = undefined;
var all_done: std.atomic.Value(bool) = .init(false);
var readies: std.atomic.Value(u32) = .init(0);
/// Readies for a task that was not parked, and answers a record read before
/// its worker wrote them.
var wrong_readies: std.atomic.Value(u32) = .init(0);
var wrong_answers: u32 = 0;

fn stepCall(_: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const Step = @ptrCast(@alignCast(capture.?));
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (step.slot.answer != step.expect_answer) wrong_answers += 1;
    if (step.next) |next| {
        task.pushRecord(moveIntoTask(task, next), null);
        task.setPending();
        // The hosted call returns PENDING: the operation is started, and a
        // worker may finish it at once.
        const started = step.slot.started.fetchAdd(1, .release) + 1;
        if (PauseKind.of(step.expect_answer) == .early) {
            while (step.slot.wakes.load(.acquire) != started) std.atomic.spinLoopHint();
        }
    }
    ret.?[0] = step.result;
}

fn stepDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

/// A copy of `bytes` in memory `task` allocates, as `suspend_save` packs a
/// record, with the original freed. Records are built before their task.
fn moveIntoTask(task: *RocTask, bytes: [*]u8) [*]u8 {
    const size = erased_callable.payloadSize(erased_callable.payloadPtr(bytes).capture_size);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], bytes[0..size]);
    utils.freeDataPtrC(bytes, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    return moved;
}

fn record(ops: *RocOps, step: Step) [*]u8 {
    const bytes = erased_callable.allocate(&stepCall, &stepDrop, @sizeOf(Step), ops);
    @as(*align(1) Step, @ptrCast(erased_callable.capturePtr(bytes))).* = step;
    return bytes;
}

/// `roc_task_ready`, on a worker's thread.
fn taskReady(task: *RocTask) callconv(.c) void {
    _ = readies.fetchAdd(1, .monotonic);
    for (&slots) |*slot| {
        if (slot.task != task) continue;
        if (slot.readied.swap(true, .release)) _ = wrong_readies.fetchAdd(1, .monotonic);
        return;
    }
    _ = wrong_readies.fetchAdd(1, .monotonic);
}

fn worker(id: usize) void {
    var rng: u64 = 0x9e3779b97f4a7c15 *% (id + 1);
    while (!all_done.load(.acquire)) {
        var index = id;
        while (index < task_count) : (index += worker_count) {
            const slot = &slots[index];
            if (slot.started.load(.acquire) == slot.finished) continue;
            // The operation's pause is the number finished before it.
            switch (PauseKind.of(slot.finished)) {
                // Its hosted call is waiting for this wake.
                .early => {},
                .late => while (@atomicLoad(u32, &slot.task.wake_word, .acquire) != wake_parked) std.atomic.spinLoopHint(),
                .racing => {
                    rng ^= rng << 13;
                    rng ^= rng >> 7;
                    rng ^= rng << 17;
                    var spins = rng % 512;
                    while (spins > 0) : (spins -= 1) std.atomic.spinLoopHint();
                },
            }
            slot.finished += 1;
            slot.answer = slot.finished;
            slot.task.wake(&taskReady);
            _ = slot.wakes.fetchAdd(1, .release);
        }
        std.atomic.spinLoopHint();
    }
}

fn resumeSlot(slot: *Slot, parks: *u32) void {
    switch (slot.task.resumeTask()) {
        .pending => {
            slot.parked = true;
            parks.* += 1;
        },
        .done => {
            slot.parked = false;
            slot.done = true;
        },
        .cancelled, .crashed => unreachable, // the test cancels no task and no record crashes
    }
}

/// One round: every task runs to its end with workers finishing its
/// operations. Returns the number of parks.
fn runRound(ops: *RocOps) std.Thread.SpawnError!u32 {
    all_done.store(false, .release);
    for (&slots, 0..) |*slot, index| {
        slot.* = .{};
        // The chain, built from its end: the last record writes the
        // task's result; each before it pauses and saves the next.
        var next: ?[*]u8 = null;
        var pause: u32 = pauses_per_task + 1;
        while (pause > 0) {
            pause -= 1;
            const result: u8 = if (next == null) @intCast(index + 1) else 0;
            next = record(ops, .{ .slot = slot, .next = next, .expect_answer = pause, .result = result });
        }
        slot.task = RocTask.create(ops, next.?, &slot.root, .{
            .hosted_slot_size = 8,
            .hosted_slot_alignment = 8,
            .result_buffer_size = 8,
            .result_buffer_alignment = 8,
        });
    }

    var threads: [worker_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, id| thread.* = try std.Thread.spawn(.{}, worker, .{id});

    var parks: u32 = 0;
    for (&slots) |*slot| resumeSlot(slot, &parks);
    var remaining: usize = 0;
    for (slots) |slot| remaining += @intFromBool(!slot.done);
    while (remaining > 0) {
        for (&slots) |*slot| {
            if (slot.done or !slot.readied.load(.acquire)) continue;
            slot.readied.store(false, .monotonic);
            if (!slot.parked) _ = wrong_readies.fetchAdd(1, .monotonic);
            resumeSlot(slot, &parks);
            remaining -= @intFromBool(slot.done);
        }
        std.atomic.spinLoopHint();
    }

    all_done.store(true, .release);
    for (threads) |thread| thread.join();
    return parks;
}

test "wakes from worker threads that race the park ready each parked task exactly once and publish its answer" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    readies.store(0, .monotonic);
    wrong_readies.store(0, .monotonic);
    wrong_answers = 0;

    var parks: u32 = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        parks += try runRound(ops);
        for (&slots, 0..) |*slot, index| {
            try std.testing.expectEqual(@as(u8, @intCast(index + 1)), slot.root[0]);
            try std.testing.expectEqual(@as(u32, pauses_per_task), slot.finished);
            slot.task.free();
        }
    }

    try std.testing.expectEqual(@as(u32, 0), wrong_readies.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), wrong_answers);
    try std.testing.expectEqual(parks, readies.load(.monotonic));
    // Every late pause parks, no early one does, and a racing one may.
    var late: u32 = 0;
    var racing: u32 = 0;
    var pause: u32 = 0;
    while (pause < pauses_per_task) : (pause += 1) switch (PauseKind.of(pause)) {
        .early => {},
        .late => late += 1,
        .racing => racing += 1,
    };
    try std.testing.expect(parks >= rounds * task_count * late);
    try std.testing.expect(parks <= rounds * task_count * (late + racing));
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}
