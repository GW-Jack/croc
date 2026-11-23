//! A threaded test of child tasks (design.md "Child Tasks"): a loop's
//! entries pause on hosted operations that worker threads finish, so their
//! wakes race their parks and the host's cancels. `zig build
//! run-test-builtins-tsan` runs this file under ThreadSanitizer.
//!
//! Main resumes every task `roc_task_ready` hands it, one at a time (P10).
//! A worker takes a pending operation and wakes its task while holding the
//! operations lock, so once `roc_task_abort` has taken the lock and removed
//! the operation, no wake follows it (P4). The properties:
//!
//! - every entry's result arrives once, and the root finishes with them;
//! - a limit never has more entries running than it allows;
//! - a root cancelled mid-run ends `cancelled` after its entries do;
//! - nothing leaks.

const std = @import("std");

const task_mod = @import("task.zig");
const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;

const entry_count = 24;
const pauses_per_entry = 6;
const limit = 4;
const worker_count = 3;
const rounds = 20;

/// Tasks `roc_task_ready` handed the host, which main resumes in order.
const Ready = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var tasks: [64]*RocTask = undefined;
    var len: usize = 0;

    fn push(task: *RocTask) callconv(.c) void {
        acquire(&lock);
        defer lock.unlock();
        tasks[len] = task;
        len += 1;
    }

    fn pop() ?*RocTask {
        acquire(&lock);
        defer lock.unlock();
        if (len == 0) return null;
        const task = tasks[0];
        std.mem.copyForwards(*RocTask, tasks[0 .. len - 1], tasks[1..len]);
        len -= 1;
        return task;
    }
};

/// Hosted operations started and not yet finished or abandoned.
const Operations = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var tasks: [64]*RocTask = undefined;
    var len: usize = 0;
    var aborts: usize = 0;

    fn start(task: *RocTask) void {
        acquire(&lock);
        defer lock.unlock();
        tasks[len] = task;
        len += 1;
    }

    /// `roc_task_abort`: drop the task's operation, if no worker finished
    /// it yet.
    fn abort(task: *RocTask) callconv(.c) void {
        acquire(&lock);
        defer lock.unlock();
        aborts += 1;
        for (tasks[0..len], 0..) |waiting, index| {
            if (waiting != task) continue;
            tasks[index] = tasks[len - 1];
            len -= 1;
            return;
        }
    }

    /// Finish one operation, chosen by `pick`, and wake its task.
    fn finishOne(pick: usize) bool {
        acquire(&lock);
        defer lock.unlock();
        if (len == 0) return false;
        const index = pick % len;
        const task = tasks[index];
        tasks[index] = tasks[len - 1];
        len -= 1;
        task.wake(&Ready.push);
        return true;
    }
};

fn acquire(lock: *std.atomic.Mutex) void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

var all_done: std.atomic.Value(bool) = .init(false);
/// Children that started and haven't reported, and the most at once; only
/// main touches them.
var running: usize = 0;
var max_running: usize = 0;

fn worker(seed: u64) void {
    var random = std.Random.DefaultPrng.init(seed);
    while (!all_done.load(.acquire)) {
        if (!Operations.finishOne(random.random().int(usize))) {
            std.atomic.spinLoopHint();
            continue;
        }
        const spins = random.random().uintLessThan(u32, 64);
        for (0..spins) |_| std.atomic.spinLoopHint();
    }
}

/// An entry: pause `pauses` times, then return `result`.
const EntryStep = extern struct { pauses: u8, result: u64 };

fn entryCall(_: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const EntryStep = @ptrCast(@alignCast(capture.?));
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (step.pauses > 0) {
        const next: EntryStep = .{ .pauses = step.pauses - 1, .result = step.result };
        task.pushRecord(record(task, &entryCall, std.mem.asBytes(&next)), null);
        task.setPending();
        Operations.start(task);
        return;
    }
    @as(*align(1) u64, @ptrCast(ret.?)).* = step.result;
}

/// The loop: the sum of the arrivals, and how many arrived.
const Loop = struct {
    spec: task_mod.GroupSpec,
    group: ?*task_mod.Group = null,
    sum: u64 = 0,
    arrivals: usize = 0,
};

fn loopCall(_: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const loop: *Loop = @as(*align(1) const *Loop, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (loop.group == null) loop.group = task_mod.groupCreate(task, loop.spec);
    while (true) {
        switch (task_mod.groupNext(loop.group.?)) {
            .arrived => |arrival| {
                loop.sum += @as(*align(1) const u64, @ptrCast(arrival.slot)).*;
                loop.arrivals += 1;
            },
            .ended => {
                task_mod.groupFree(loop.group.?);
                @as(*align(1) u64, @ptrCast(ret.?)).* = loop.sum;
                return;
            },
            .pending => {
                task.pushRecord(record(task, &loopCall, std.mem.asBytes(&loop)), null);
                task.setPending();
                return;
            },
        }
    }
}

fn noDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

fn record(task: *RocTask, call: erased_callable.ErasedCallableFn, capture: []const u8) [*]u8 {
    const size = erased_callable.payloadSize(capture.len);
    const built = erased_callable.allocate(call, &noDrop, capture.len, task.ops);
    @memcpy(erased_callable.capturePtr(built)[0..capture.len], capture);
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

/// One run: a root whose loop runs every entry under one limit. With
/// `cancel_after`, main cancels the root after that many resumes.
fn runOnce(ops: *RocOps, cancel_after: ?usize) (std.Thread.SpawnError || error{ TestExpectedEqual, TestUnexpectedResult })!void {
    Ready.len = 0;
    Operations.len = 0;
    Operations.aborts = 0;
    running = 0;
    max_running = 0;
    all_done.store(false, .release);

    var starts: [entry_count][*]u8 = undefined;
    for (&starts, 0..) |*start, index| {
        start.* = erased_callable.allocate(&entryCall, &noDrop, @sizeOf(EntryStep), ops);
        @as(*align(1) EntryStep, @ptrCast(erased_callable.capturePtr(start.*))).* = .{ .pauses = @intCast(1 + index % pauses_per_entry), .result = index + 1 };
    }
    const marks: [entry_count]task_mod.EntryMarks = @splat(.{ .limit_path = &.{0}, .shielded = false, .background = false });
    var loop: Loop = .{ .spec = .{
        .starts = &starts,
        .marks = &marks,
        .limits = &.{limit},
        .root_limit = 0,
        .slot_size = 8,
        .slot_alignment = 8,
        .result_drop = null,
        .result_drop_context = null,
    } };
    const start = erased_callable.allocate(&loopCall, &noDrop, @sizeOf(*Loop), ops);
    @as(*align(1) *Loop, @ptrCast(erased_callable.capturePtr(start))).* = &loop;
    var root: u64 = 0;
    const task = RocTask.create(ops, start, @ptrCast(&root), buffers);

    var workers: [worker_count]std.Thread = undefined;
    for (&workers, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, worker, .{index + 1});
    var status = task.resumeFromHost(&Ready.push, &Operations.abort);
    var resumes: usize = 0;
    var cancelled = false;
    while (status == .pending) {
        if (cancel_after) |after| if (resumes == after and !cancelled) {
            task.cancel(&Operations.abort, &Ready.push);
            cancelled = true;
        };
        const next = Ready.pop() orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        resumes += 1;
        if (next == task) {
            status = task.resumeFromHost(&Ready.push, &Operations.abort);
            continue;
        }
        if (!next.started) {
            running += 1;
            max_running = @max(max_running, running);
        }
        if (next.resumeFromHost(&Ready.push, &Operations.abort) != .pending) running -= 1;
    }
    all_done.store(true, .release);
    for (workers) |thread| thread.join();

    try std.testing.expect(max_running <= limit);
    try std.testing.expectEqual(@as(usize, 0), running);
    if (cancel_after == null) {
        try std.testing.expectEqual(Status.done, status);
        try std.testing.expectEqual(@as(usize, entry_count), loop.arrivals);
        try std.testing.expectEqual(@as(u64, entry_count * (entry_count + 1) / 2), root);
    } else {
        try std.testing.expectEqual(Status.cancelled, status);
    }
    try std.testing.expectEqual(@as(usize, 0), Operations.len);
    task.free();
}

test "children's operations finished on worker threads wake them, and each result arrives once" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    for (0..rounds) |_| try runOnce(env.getOps(), null);
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a root cancelled while workers finish its children's operations ends after every child" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    for (0..rounds) |round| try runOnce(env.getOps(), 5 + round * 3);
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}
