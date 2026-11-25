//! A threaded test of shared state in a `ParallelTasks` program (design.md
//! "Shared State", "Updates on several threads."): workers run updates of a
//! few cells at the same time, so updates, waits, probes, wakes, cancels and
//! crashes of different tasks race. `zig build run-test-builtins-tsan` runs
//! this file under ThreadSanitizer, which finds a cell read or written without
//! its lock, since a cell's fields are plain memory.
//!
//! Each round makes tasks with random scripts of updates. The properties:
//!
//! - a cell's value is the sum of the stores made to it;
//! - once nothing is ready, no task is parked whose update would go on (V7);
//! - a poisoned cell leaves no task waiting on it (V6);
//! - every allocation is released.

const std = @import("std");
const builtin = @import("builtin");

const crash_exit = @import("task_crash_exit.zig");
const dev_wrappers = @import("dev_wrappers.zig");
const erased_callable = @import("erased_callable.zig");
const task_mod = @import("task.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;

const worker_count = 4;
const task_count = 32;
const step_count = 24;
const rounds: u64 = if (builtin.sanitize_thread) 60 else 1500;

const test_host = struct {
    var live: std.atomic.Value(isize) = .init(0);

    fn alloc(_: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
        std.debug.assert(alignment <= 16); // rationale: malloc aligns to 16, and no task allocation asks for more
        _ = live.fetchAdd(1, .monotonic);
        return std.c.malloc(@max(length, 1)) orelse @trap();
    }

    fn dealloc(_: *RocOps, ptr: *anyopaque, _: usize) callconv(.c) void {
        _ = live.fetchSub(1, .monotonic);
        std.c.free(ptr);
    }

    fn realloc(_: *RocOps, ptr: *anyopaque, length: usize, _: usize) callconv(.c) *anyopaque {
        return std.c.realloc(ptr, length) orelse @trap();
    }

    fn print(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
        std.debug.print("{s}\n", .{bytes[0..len]});
    }

    fn crashed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
        std.debug.print("a crash reached the host: {s}\n", .{bytes[0..len]});
        std.process.abort();
    }

    var ops: RocOps = .{
        .env = undefined,
        .roc_alloc = alloc,
        .roc_dealloc = dealloc,
        .roc_realloc = realloc,
        .roc_dbg = print,
        .roc_expect_failed = print,
        .roc_crashed = crashed,
        .hosted_fns = .{ .count = 0, .fns = undefined },
    };
};

threadlocal var running_task: ?*RocTask = null;

fn threadSlot() callconv(.c) *?*RocTask {
    return &running_task;
}

fn acquire(lock: *std.atomic.Mutex) void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

/// A cell's payload, with no synchronization but the cell's lock.
const Cell = struct {
    value: i64 = 0,
    empty: bool = false,
    /// What the stores to it add up to.
    stored: std.atomic.Value(i64) = .init(0),
};

const Answer = enum(u8) { add, keep, crash };

const Step = struct {
    cell: *Cell,
    /// The update waits while the value is below this.
    threshold: i64,
    answer: Answer,
    amount: i64,
};

const Runner = struct {
    task: *RocTask = undefined,
    steps: [step_count]Step = undefined,
    len: usize = 0,
    next: usize = 0,
    root: u64 = 0,
    ended: ?Status = null,
    /// Held during a resume and a cancel, so a cancel comes between resumes.
    lock: std.atomic.Mutex = .unlocked,

    fn run(self: *Runner) void {
        const status = self.task.resumeParallelFromHost(&readyTask, &abortTask, &threadSlot);
        if (status == .pending) return;
        self.ended = status;
        self.task.free();
    }
};

var runners: [task_count]Runner = undefined;
var ready_lock: std.atomic.Mutex = .unlocked;
var ready_tasks: [task_count]*RocTask = undefined;
var ready_len: usize = 0;
/// Resumes due or running: with none, nothing can change any more.
var due: std.atomic.Value(usize) = .init(0);

fn readyTask(task: *RocTask) callconv(.c) void {
    _ = due.fetchAdd(1, .monotonic);
    acquire(&ready_lock);
    defer ready_lock.unlock();
    ready_tasks[ready_len] = task;
    ready_len += 1;
}

fn abortTask(_: *RocTask) callconv(.c) void {
    std.debug.print("a task waiting on a cell was aborted\n", .{});
    std.process.abort();
}

fn takeReady(pick: usize) ?*Runner {
    acquire(&ready_lock);
    defer ready_lock.unlock();
    if (ready_len == 0) return null;
    const index = pick % ready_len;
    const task = ready_tasks[index];
    ready_len -= 1;
    ready_tasks[index] = ready_tasks[ready_len];
    for (&runners) |*runner| if (runner.task == task) return runner;
    unreachable; // rationale: only the round's tasks are readied
}

fn worker(seed: u64, cancels: bool) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    while (due.load(.acquire) > 0) {
        if (cancels and random.uintLessThan(u32, 64) == 0) {
            const runner = &runners[random.uintLessThan(usize, runners.len)];
            if (runner.lock.tryLock()) {
                defer runner.lock.unlock();
                // A cancel may ready its task, and runs while a resume is due.
                if (runner.ended == null) {
                    _ = due.fetchAdd(1, .monotonic);
                    runner.task.cancel(&abortTask, &readyTask);
                    _ = due.fetchSub(1, .release);
                }
            }
        }
        const runner = takeReady(random.int(usize)) orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        acquire(&runner.lock);
        runner.run();
        runner.lock.unlock();
        _ = due.fetchSub(1, .release);
    }
}

fn noDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

fn allocCallable(ops: *RocOps, call: erased_callable.ErasedCallableFn, comptime T: type, capture: T) [*]u8 {
    const built = erased_callable.allocate(call, &noDrop, @sizeOf(T), ops);
    @as(*align(1) T, @ptrCast(erased_callable.capturePtr(built))).* = capture;
    return built;
}

const Probed = extern struct { cell: *Cell, threshold: i64, crashes: bool };

/// `cell_probe!`: the state out of its cell and back, then the function.
fn probeCall(ops: *RocOps, ret: ?[*]u8, _: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const probed = @as(*align(1) const Probed, @ptrCast(capture.?)).*;
    if (probed.cell.empty) {
        ret.?[0] = 1;
        return;
    }
    probed.cell.empty = true;
    const waits = probed.cell.value < probed.threshold;
    probed.cell.empty = false;
    if (!waits and probed.crashes) ops.crash("an update crashed");
    ret.?[0] = @intFromBool(!waits);
}

fn scriptCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const runner: *Runner = @as(*align(1) const *Runner, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    while (runner.next < runner.len) {
        const step = runner.steps[runner.next];
        dev_wrappers.roc_builtins_cell_lock(step.cell);
        if (step.cell.empty) ops.crash("this cell was poisoned");
        step.cell.empty = true;
        if (step.cell.value < step.threshold) {
            step.cell.empty = false;
            const probe = allocCallable(ops, &probeCall, Probed, .{ .cell = step.cell, .threshold = step.threshold, .crashes = step.answer == .crash });
            std.debug.assert(dev_wrappers.roc_builtins_cell_wait(step.cell, probe, task) == 2); // rationale: the park status is fixed
            task.setPending();
            task.pushRecord(scriptRecord(task, runner), null);
            return;
        }
        if (step.answer == .crash) ops.crash("an update crashed");
        if (step.answer == .add) {
            step.cell.value += step.amount;
            _ = step.cell.stored.fetchAdd(step.amount, .monotonic);
        }
        step.cell.empty = false;
        dev_wrappers.roc_builtins_cell_settle(step.cell, step.answer == .add, false);
        runner.next += 1;
    }
    @as(*align(1) u64, @ptrCast(ret.?)).* = 1;
}

/// A record of `runner`'s script, in memory from the task.
fn scriptRecord(task: *RocTask, runner: *Runner) [*]u8 {
    const size = erased_callable.payloadSize(@sizeOf(*Runner));
    const built = allocCallable(task.ops, &scriptCall, *Runner, runner);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], built[0..size]);
    utils.freeDataPtrC(built, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    return moved;
}

const buffers = task_mod.BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

/// Resume what is ready on every worker until nothing is.
fn runReady(seed: u64, cancels: bool) std.Thread.SpawnError!void {
    var threads: [worker_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, worker, .{ seed *% worker_count +% index, cancels });
    for (threads) |thread| thread.join();
}

fn runRound(seed: u64) (std.Thread.SpawnError || error{ TestUnexpectedResult, TestExpectedEqual })!void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    // The runs with crashes poison cells, so they are kept short of all.
    const crashes = crash_exit.native and seed % 3 == 0;
    var cells: [3]Cell = @splat(.{});
    const live = test_host.live.load(.monotonic);
    due.store(0, .monotonic);
    for (&runners) |*runner| {
        runner.* = .{ .len = 1 + random.uintLessThan(usize, step_count) };
        for (&runner.steps) |*step| step.* = .{
            .cell = &cells[random.uintLessThan(usize, cells.len)],
            .threshold = random.intRangeAtMost(i64, -6, 3),
            .answer = if (crashes and random.uintLessThan(u32, 150) == 0) .crash else if (random.uintLessThan(u32, 4) == 0) .keep else .add,
            .amount = random.intRangeAtMost(i64, -2, 2),
        };
        runner.task = RocTask.createParallel(&test_host.ops, allocCallable(&test_host.ops, &scriptCall, *Runner, runner), @ptrCast(&runner.root), buffers);
        // Its cells are other roots' too, so its tree has not stalled when they wait.
        runner.task.busy += 1;
        readyTask(runner.task);
    }
    try runReady(seed, seed % 2 == 0);
    for (&cells) |*cell| {
        if (!cell.empty) try std.testing.expectEqual(cell.stored.load(.monotonic), cell.value);
    }
    for (&runners) |*runner| {
        if (runner.ended != null) continue;
        const step = runner.steps[runner.next];
        try std.testing.expectEqual(@as(?*anyopaque, step.cell), runner.task.waited_cell);
        try std.testing.expect(!step.cell.empty and step.cell.value < step.threshold);
        runner.task.cancel(&abortTask, &readyTask);
    }
    try runReady(seed, false);
    for (&runners) |*runner| try std.testing.expect(runner.ended != null);
    try std.testing.expectEqual(live, test_host.live.load(.monotonic));
}

test "updates of cells on several threads lose no store and no wake, however tasks end" {
    for (0..rounds) |seed| try runRound(seed);
}
