//! The conformance harness (design.md "The Task Runtime", "Conformance"):
//! hosts that break the task host contract, each in exactly one checkable
//! way, and hosts that keep it, against the runtime's monitors.
//!
//! Every adversarial host must be caught, through the host's `roc_crashed`,
//! with a message naming the obligation it broke, and the task must be as
//! it was before the bad call, so the host can finish it and nothing leaks.
//! The harness's `roc_crashed` keeps the message and jumps back to the
//! driver (`caughtCrash`), which a real host would not do. Conforming hosts
//! must run with no crash at all.
//!
//! Some obligations have no runtime check. A wake without writing `*out`
//! (P3) cannot be told from a result that happens to match any poison, and
//! the runtime never sees a host read `result_out` after `CANCELLED` (P8).
//! A skipped argument release (P5) is the host's own leak, which the e2e
//! and platform hosts' leak checks catch.

const std = @import("std");

const task_mod = @import("task.zig");
const crash_exit = @import("task_crash_exit.zig");
const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;

/// Stop the test from a record or a host callback, which can't return an
/// error.
fn fail(comptime message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    @trap();
}

const buffers = task_mod.BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

/// Where this thread's `roc_crashed` jumps back to, and the message it kept.
threadlocal var catch_point: ?*crash_exit.Buffer = null;
threadlocal var caught_buf: [256]u8 = undefined;
threadlocal var caught_len: usize = 0;

fn harnessCrashed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    const point = catch_point orelse {
        std.debug.print("a crash outside caughtCrash: {s}\n", .{bytes[0..len]});
        @trap();
    };
    caught_len = @min(len, caught_buf.len);
    @memcpy(caught_buf[0..caught_len], bytes[0..caught_len]);
    crash_exit.jump(point);
}

/// Run `body(context)` and return the message of the crash it caused, or
/// null when it ran to its end.
fn caughtCrash(comptime Context: type, body: *const fn (Context) void, context: Context) ?[]const u8 {
    var point: crash_exit.Buffer = undefined;
    catch_point = &point;
    defer catch_point = null;
    if (crash_exit.save(&point) != 0) return caught_buf[0..caught_len];
    body(context);
    return null;
}

fn expectCaught(message: ?[]const u8, comptime obligation: []const u8) error{ TestExpectedCrash, TestWrongCrash }!void {
    const got = message orelse {
        std.debug.print("expected a host-contract crash naming {s}, got none\n", .{obligation});
        return error.TestExpectedCrash;
    };
    if (!std.mem.startsWith(u8, got, "host contract violated: ") or std.mem.find(u8, got, "(" ++ obligation ++ ")") == null) {
        std.debug.print("expected a host-contract crash naming {s}, got: {s}\n", .{ obligation, got });
        return error.TestWrongCrash;
    }
}

/// The harness's ops: the test env's, with `roc_crashed` replaced.
const Harness = struct {
    env: utils.TestEnv,
    ops: RocOps,

    fn init(self: *Harness) error{SkipZigTest}!void {
        if (!crash_exit.available()) return error.SkipZigTest;
        self.env = utils.TestEnv.init(std.testing.allocator);
        self.ops = self.env.getOps().*;
        self.ops.roc_crashed = &harnessCrashed;
    }

    fn deinit(self: *Harness) void {
        self.env.deinit();
    }

    fn live(self: *const Harness) usize {
        return self.env.getAllocationCount();
    }
};

/// What a record does inside its call, besides pausing.
const Hook = enum {
    none,
    /// Resume its own task, as a hosted call that resumes it would (P1).
    resume_own_task,
    /// Signal that it is running, then wait until main says go (P10).
    hold_for_overlap,
    /// Wake its own task before returning, as a host that finished on
    /// another thread before the hosted function returned does.
    wake_early,
};

/// One record: pause and save `next`, or finish with `result`.
const Step = struct {
    next: ?[*]u8,
    result: u8,
    hook: Hook = .none,
};

var hook_message: ?[]const u8 = null;
var overlap_running: std.atomic.Value(bool) = .init(false);
var overlap_go: std.atomic.Value(bool) = .init(false);
var readies: u32 = 0;
var aborts: u32 = 0;

fn ready(_: *RocTask) callconv(.c) void {
    readies += 1;
}

fn abort(_: *RocTask) callconv(.c) void {
    aborts += 1;
}

fn resumeOwn(task: *RocTask) void {
    _ = task.resumeTask();
}

fn stepCall(_: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const Step = @ptrCast(@alignCast(capture.?));
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    switch (step.hook) {
        .none => {},
        .resume_own_task => hook_message = caughtCrash(*RocTask, &resumeOwn, task),
        .hold_for_overlap => {
            overlap_running.store(true, .release);
            while (!overlap_go.load(.acquire)) std.atomic.spinLoopHint();
        },
        .wake_early => {},
    }
    if (step.next) |next| {
        task.pushRecord(next, null);
        task.setPending();
        if (step.hook == .wake_early) task.wake(&ready);
    }
    ret.?[0] = step.result;
}

fn stepDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

/// A record in memory `task` would allocate, as `suspend_save` packs one.
fn moveIntoTask(task: *RocTask, original: [*]u8) [*]u8 {
    const size = erased_callable.payloadSize(erased_callable.payloadPtr(original).capture_size);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], original[0..size]);
    utils.freeDataPtrC(original, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    return moved;
}

/// A task whose records pause once per hook in `hooks` and then finish
/// with `result`.
fn chainTask(ops: *RocOps, hooks: []const Hook, root: *[8]u8, result: u8) *RocTask {
    var steps: [8][*]u8 = undefined;
    std.debug.assert(hooks.len < steps.len);
    // Built from the end: the last record finishes, each before it pauses.
    steps[hooks.len] = record(ops, .{ .next = null, .result = result });
    var index = hooks.len;
    while (index > 0) {
        index -= 1;
        steps[index] = record(ops, .{ .next = steps[index + 1], .result = 0, .hook = hooks[index] });
    }
    const task = RocTask.create(ops, steps[0], root, buffers);
    // Every record but the start record is the task's own, as compiled
    // code saves it.
    for (steps[1 .. hooks.len + 1], 1..) |*step, at| {
        const moved = moveIntoTask(task, step.*);
        @as(*align(1) Step, @ptrCast(erased_callable.capturePtr(steps[at - 1]))).next = moved;
        step.* = moved;
    }
    return task;
}

fn record(ops: *RocOps, step: Step) [*]u8 {
    const bytes = erased_callable.allocate(&stepCall, &stepDrop, @sizeOf(Step), ops);
    @as(*align(1) Step, @ptrCast(erased_callable.capturePtr(bytes))).* = step;
    return bytes;
}

fn reset() void {
    hook_message = null;
    readies = 0;
    aborts = 0;
    overlap_running.store(false, .monotonic);
    overlap_go.store(false, .monotonic);
}

fn resumeTask(task: *RocTask) void {
    _ = task.resumeTask();
}

fn wakeTask(task: *RocTask) void {
    task.wake(&ready);
}

fn cancelTask(task: *RocTask) void {
    task.cancel(&abort, &ready);
}

fn freeTask(task: *RocTask) void {
    task.free();
}

test "a host that resumes a task twice for one ready is caught (P1)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{ .none, .none }, &root, 7);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&ready);
    try std.testing.expectEqual(Status.pending, task.resumeTask());
    try expectCaught(caughtCrash(*RocTask, &resumeTask, task), "P1");

    // The task is as it was: a ready lets the host finish it.
    task.wake(&ready);
    try std.testing.expectEqual(Status.done, task.resumeTask());
    try std.testing.expectEqual(@as(u8, 7), root[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

test "a host that resumes a task inside one of its hosted calls is caught (P1)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{.resume_own_task}, &root, 7);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    try expectCaught(hook_message, "P1");
    task.wake(&ready);
    try std.testing.expectEqual(Status.done, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

test "a host that wakes a task twice for one operation is caught (P3)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{.none}, &root, 7);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&ready);
    try expectCaught(caughtCrash(*RocTask, &wakeTask, task), "P3");
    try std.testing.expectEqual(@as(u32, 1), readies);
    try std.testing.expectEqual(Status.done, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

test "a host that wakes a task after aborting its operation is caught (P4)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{.none}, &root, 7);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.cancel(&abort, &ready);
    try std.testing.expectEqual(@as(u32, 1), aborts);
    try expectCaught(caughtCrash(*RocTask, &wakeTask, task), "P4");
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

test "a host that cancels, resumes or frees a task after it ended is caught (P8)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{}, &root, 7);

    try std.testing.expectEqual(Status.done, task.resumeTask());
    try expectCaught(caughtCrash(*RocTask, &cancelTask, task), "P8");
    try expectCaught(caughtCrash(*RocTask, &resumeTask, task), "P8");
    task.free();
    try expectCaught(caughtCrash(*RocTask, &freeTask, task), "P8");
    try expectCaught(caughtCrash(*RocTask, &wakeTask, task), "P8");
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

test "a host that frees a task before it ended is caught (P8)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{.none}, &root, 7);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    try expectCaught(caughtCrash(*RocTask, &freeTask, task), "P8");
    task.wake(&ready);
    try std.testing.expectEqual(Status.done, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

var held_status: Status = .pending;

fn runHeld(task: *RocTask) void {
    held_status = task.resumeTask();
}

test "a host whose resumes of two tasks overlap on two threads is caught (P10)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();
    var root_a: [8]u8 = @splat(0);
    var root_b: [8]u8 = @splat(0);
    const held = chainTask(&h.ops, &.{}, &root_a, 1);
    @as(*align(1) Step, @ptrCast(erased_callable.capturePtr(held.entries[0].record))).hook = .hold_for_overlap;
    const other = chainTask(&h.ops, &.{}, &root_b, 2);

    const thread = try std.Thread.spawn(.{}, runHeld, .{held});
    while (!overlap_running.load(.acquire)) std.atomic.spinLoopHint();
    try expectCaught(caughtCrash(*RocTask, &resumeTask, other), "P10");
    overlap_go.store(true, .release);
    thread.join();
    try std.testing.expectEqual(Status.done, held_status);

    try std.testing.expectEqual(Status.done, other.resumeTask());
    try std.testing.expectEqual(@as(u8, 1), root_a[0]);
    try std.testing.expectEqual(@as(u8, 2), root_b[0]);
    held.free();
    other.free();
    try std.testing.expectEqual(@as(usize, 0), h.live());
}

fn driveConforming(task: *RocTask) void {
    var status = task.resumeTask();
    while (status == .pending) {
        task.wake(&ready);
        status = task.resumeTask();
    }
}

/// The task the harness's last `roc_task_ready` named.
var last_readied: ?*RocTask = null;

fn readyChild(task: *RocTask) callconv(.c) void {
    last_readied = task;
}

/// A loop over one entry: open the group and wait for the entry, then take
/// its result and close the group.
fn loopOverOne(_: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const group_out: **task_mod.Group = @as(*align(1) const **task_mod.Group, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    const entry = record(task.ops, .{ .next = null, .result = 7 });
    group_out.* = task_mod.groupCreate(task, .{
        .starts = &.{entry},
        .marks = &.{.{ .limit_path = &.{}, .shielded = false, .background = false }},
        .limits = &.{},
        .root_limit = null,
        .slot_size = 8,
        .slot_alignment = 8,
        .result_drop = null,
        .result_drop_context = null,
    });
    if (task_mod.groupNext(group_out.*) != .pending) fail("the entry arrived before it ran");
    const size = erased_callable.payloadSize(@sizeOf(**task_mod.Group));
    const built = erased_callable.allocate(&finishLoop, &stepDrop, @sizeOf(**task_mod.Group), task.ops);
    @as(*align(1) **task_mod.Group, @ptrCast(erased_callable.capturePtr(built))).* = group_out;
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], built[0..size]);
    utils.freeDataPtrC(built, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    task.pushRecord(moved, null);
    task.setPending();
    ret.?[0] = 0;
}

fn finishLoop(_: *RocOps, ret: ?[*]u8, _: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const group: *task_mod.Group = @as(*align(1) const **task_mod.Group, @ptrCast(capture.?)).*.*;
    const arrival = task_mod.groupNext(group).arrived;
    ret.?[0] = arrival.slot[0];
    if (task_mod.groupNext(group) != .ended) fail("the loop did not end after its one entry");
    task_mod.groupFree(group);
}

test "a host that frees or cancels a child task, which only the runtime does, is caught (P8)" {
    var harness: Harness = undefined;
    try harness.init();
    defer harness.deinit();
    reset();
    last_readied = null;
    var group: *task_mod.Group = undefined;
    const start = erased_callable.allocate(&loopOverOne, &stepDrop, @sizeOf(**task_mod.Group), &harness.ops);
    @as(*align(1) **task_mod.Group, @ptrCast(erased_callable.capturePtr(start))).* = &group;
    var root: [8]u8 = undefined;
    const task = RocTask.create(&harness.ops, start, &root, buffers);
    try std.testing.expectEqual(Status.pending, task.resumeFromHost(&readyChild, &abort));
    const child = last_readied.?;
    last_readied = null;

    try expectCaught(caughtCrash(*RocTask, &freeTask, child), "P8");
    try expectCaught(caughtCrash(*RocTask, &cancelTask, child), "P8");

    // The child is as it was: it runs, reports, and readies its owner.
    try std.testing.expectEqual(Status.done, child.resumeFromHost(&readyChild, &abort));
    try std.testing.expectEqual(task, last_readied.?);
    try std.testing.expectEqual(Status.done, task.resumeFromHost(&readyChild, &abort));
    try std.testing.expectEqual(@as(u8, 7), root[0]);
    // The runtime freed the child before its resume returned.
    try expectCaught(caughtCrash(*RocTask, &resumeTask, child), "P8");
    task.free();
    try std.testing.expectEqual(@as(usize, 0), harness.live());
}

test "conforming hosts run with the monitors on and no crash" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    reset();

    // Single-threaded: wake each parked task, then resume it.
    var root: [8]u8 = @splat(0);
    const task = chainTask(&h.ops, &.{ .none, .none, .none }, &root, 3);
    try std.testing.expectEqual(@as(?[]const u8, null), caughtCrash(*RocTask, &driveConforming, task));
    try std.testing.expectEqual(@as(u8, 3), root[0]);
    try std.testing.expectEqual(@as(u32, 3), readies);
    task.free();

    // Completion before the hosted function returns: no park, no ready.
    reset();
    const early = chainTask(&h.ops, &.{ .wake_early, .wake_early }, &root, 4);
    try std.testing.expectEqual(Status.done, early.resumeTask());
    try std.testing.expectEqual(@as(u32, 0), readies);
    early.free();

    // Cancelling, before and after a completion, and before the first
    // resume.
    reset();
    const parked = chainTask(&h.ops, &.{.none}, &root, 5);
    try std.testing.expectEqual(Status.pending, parked.resumeTask());
    parked.cancel(&abort, &ready);
    try std.testing.expectEqual(Status.cancelled, parked.resumeTask());
    parked.free();
    const woken = chainTask(&h.ops, &.{.none}, &root, 5);
    try std.testing.expectEqual(Status.pending, woken.resumeTask());
    woken.wake(&ready);
    woken.cancel(&abort, &ready);
    try std.testing.expectEqual(Status.cancelled, woken.resumeTask());
    woken.free();
    // Only the start record: records it would save do not exist yet.
    const fresh = chainTask(&h.ops, &.{}, &root, 5);
    fresh.cancel(&abort, &ready);
    try std.testing.expectEqual(Status.cancelled, fresh.resumeTask());
    fresh.free();
    try std.testing.expectEqual(@as(u32, 1), aborts);
    try std.testing.expectEqual(@as(u32, 2), readies);

    try std.testing.expectEqual(@as(usize, 0), h.live());
}
