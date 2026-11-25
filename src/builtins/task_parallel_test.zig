//! A threaded test of parallel resumes (design.md "Parallel Resumes"): a
//! `ParallelTasks` host whose workers resume ready tasks and finish hosted
//! operations at the same time, so reports, wakes, cancels and crashes of one
//! tree race each other, parks and the owner's own code. `zig build
//! run-test-builtins-tsan` runs this file under ThreadSanitizer.
//!
//! Each round builds one tree of loops from a seed. The properties:
//!
//! - no task is resumed by two threads at once, and a limit never has more
//!   entries running than it allows, which the runtime's monitors check;
//! - a run that nothing cancels or crashes delivers every entry's result
//!   once, and one that is cancelled or crashes reports so after every task
//!   below has ended;
//! - every allocation is released.

const std = @import("std");
const builtin = @import("builtin");

const crash_exit = @import("task_crash_exit.zig");
const erased_callable = @import("erased_callable.zig");
const task_mod = @import("task.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;

const worker_count = 4;
const rounds: u64 = if (builtin.sanitize_thread) 60 else 1500;
const max_tasks = 4096;
/// How often a worker finds nothing to do before the run counts as stalled.
const stalled_spins = 100_000_000;

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

/// A list of tasks several threads add to and take from.
const Tasks = struct {
    lock: std.atomic.Mutex = .unlocked,
    items: [max_tasks]*RocTask = undefined,
    len: usize = 0,

    fn push(self: *Tasks, task: *RocTask) void {
        acquire(&self.lock);
        defer self.lock.unlock();
        self.items[self.len] = task;
        self.len += 1;
    }

    fn take(self: *Tasks, pick: usize) ?*RocTask {
        acquire(&self.lock);
        defer self.lock.unlock();
        if (self.len == 0) return null;
        const index = pick % self.len;
        const task = self.items[index];
        self.len -= 1;
        self.items[index] = self.items[self.len];
        return task;
    }
};

/// Tasks `roc_task_ready` named.
var ready: Tasks = .{};
/// Hosted operations started and neither finished nor abandoned.
var operations: Tasks = .{};
var aborts: std.atomic.Value(usize) = .init(0);

fn readyTask(task: *RocTask) callconv(.c) void {
    ready.push(task);
}

/// `roc_task_abort`: drop the task's operation, if no worker finished it.
fn abortTask(task: *RocTask) callconv(.c) void {
    acquire(&operations.lock);
    defer operations.lock.unlock();
    _ = aborts.fetchAdd(1, .monotonic);
    for (operations.items[0..operations.len], 0..) |waiting, index| {
        if (waiting != task) continue;
        operations.len -= 1;
        operations.items[index] = operations.items[operations.len];
        return;
    }
}

/// Finish one operation, waking its task under the lock `abortTask` takes
/// (P4).
fn finishOperation(pick: usize) bool {
    acquire(&operations.lock);
    defer operations.lock.unlock();
    if (operations.len == 0) return false;
    const index = pick % operations.len;
    const task = operations.items[index];
    operations.len -= 1;
    operations.items[index] = operations.items[operations.len];
    task.wake(&readyTask);
    return true;
}

var root_task: *RocTask = undefined;
var root_ended: std.atomic.Value(bool) = .init(false);
var root_status: Status = undefined;
/// Cancel the root at its resume with this number.
var cancel_at: usize = 0;
/// How many of the root's resumes ran; only the root's resumer touches it.
var root_resumes: usize = 0;
var failed: std.atomic.Value(bool) = .init(false);

fn worker(seed: u64) void {
    var random = std.Random.DefaultPrng.init(seed);
    var idle: u32 = 0;
    while (!root_ended.load(.acquire)) {
        const pick = random.random().int(usize);
        if (random.random().uintLessThan(u8, 3) == 0) _ = finishOperation(pick);
        const task = ready.take(pick) orelse {
            idle = if (finishOperation(pick)) 0 else idle + 1;
            if (idle == stalled_spins) {
                // Nothing is ready and no operation is pending.
                std.debug.print("a task was never readied\n", .{});
                std.process.abort();
            }
            std.atomic.spinLoopHint();
            continue;
        };
        idle = 0;
        if (task != root_task) {
            _ = task.resumeParallelFromHost(&readyTask, &abortTask, &threadSlot);
            continue;
        }
        resumeRoot();
    }
}

fn resumeRoot() void {
    // Between the root's resumes, as `roc_task_cancel` requires, while its
    // children's resumes run.
    root_resumes += 1;
    if (root_resumes == cancel_at) {
        root_task.cancel(&abortTask, &readyTask);
    }
    const status = root_task.resumeParallelFromHost(&readyTask, &abortTask, &threadSlot);
    if (status == .pending) return;
    root_status = status;
    root_ended.store(true, .release);
}

/// A leaf entry: pause `pauses` times, then return `result`, or crash.
const Leaf = extern struct { pauses: u32, crashes: bool, result: u64 };

fn leafCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const leaf = @as(*align(1) const Leaf, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (leaf.pauses > 0) {
        var next = leaf;
        next.pauses -= 1;
        task.pushRecord(record(task, &leafCall, std.mem.asBytes(&next)), null);
        task.setPending();
        operations.push(task);
        return;
    }
    if (leaf.crashes) ops.crash("a leaf crashed");
    @as(*align(1) u64, @ptrCast(ret.?)).* = leaf.result;
}

/// How a loop's body ends it.
const Ending = enum(u8) { exhaust, exit_early };

/// A loop over leaves and nested loops, each of whose results is 1, as its
/// own is.
const Loop = struct {
    seed: u64,
    depth: u8,
    entries: u32,
    limit: u32,
    ending: Ending,
    spawns: u32,
    group: ?*task_mod.Group = null,
    exiting: bool = false,
    sum: u64 = 0,
    arrivals: u32 = 0,
};

/// What each round's tree may do.
const Shape = struct { crashes: bool, exits: bool };
var shape: Shape = undefined;

/// The loops of a round, which its records point at.
var loops_lock: std.atomic.Mutex = .unlocked;
var loops: [max_tasks]Loop = undefined;
var loops_len: usize = 0;

fn newLoop(seed: u64, depth: u8) *Loop {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    acquire(&loops_lock);
    defer loops_lock.unlock();
    const loop = &loops[loops_len];
    loops_len += 1;
    loop.* = .{
        .seed = seed,
        .depth = depth,
        .entries = 1 + random.uintLessThan(u32, 6),
        .limit = 1 + random.uintLessThan(u32, 4),
        .ending = if (shape.exits and random.uintLessThan(u8, 4) == 0) .exit_early else .exhaust,
        .spawns = random.uintLessThan(u32, 3),
    };
    return loop;
}

/// The start record of a loop's entry at `index`, and the result it gives.
fn entryStart(loop: *Loop, ops: *RocOps, index: u32) [*]u8 {
    var prng = std.Random.DefaultPrng.init(loop.seed ^ (@as(u64, index + 1) *% 0x9E37_79B9_7F4A_7C15));
    const random = prng.random();
    if (loop.depth > 0 and random.uintLessThan(u8, 3) == 0) {
        const nested = newLoop(random.int(u64), loop.depth - 1);
        return startRecord(ops, &loopCall, std.mem.asBytes(&nested));
    }
    const leaf: Leaf = .{
        .pauses = random.uintLessThan(u32, 4),
        .crashes = shape.crashes and random.uintLessThan(u8, 12) == 0,
        .result = 1,
    };
    return startRecord(ops, &leafCall, std.mem.asBytes(&leaf));
}

fn loopCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const loop: *Loop = @as(*align(1) const *Loop, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (loop.group == null) {
        var starts: [8][*]u8 = undefined;
        for (starts[0..loop.entries], 0..) |*start, index| start.* = entryStart(loop, ops, @intCast(index));
        const marks: [8]task_mod.EntryMarks = @splat(.{ .limit_path = &.{0}, .shielded = false, .background = false });
        loop.group = task_mod.groupCreate(task, .{
            .starts = starts[0..loop.entries],
            .marks = marks[0..loop.entries],
            .limits = &.{loop.limit},
            .root_limit = 0,
            .slot_size = 8,
            .slot_alignment = 8,
            .result_drop = null,
            .result_drop_context = null,
        });
    }
    while (true) {
        switch (task_mod.groupNext(loop.group.?)) {
            .arrived => |arrival| {
                if (loop.exiting) continue;
                loop.sum += @as(*align(1) const u64, @ptrCast(arrival.slot)).*;
                loop.arrivals += 1;
                if (loop.spawns > 0) {
                    loop.spawns -= 1;
                    loop.entries += 1;
                    task_mod.spawnIn(loop.group.?, entryStart(loop, ops, loop.entries));
                }
                if (loop.ending == .exit_early) {
                    loop.exiting = true;
                    task_mod.cancelGroup(loop.group.?);
                }
            },
            .crashed => unreachable, // rationale: none of these groups is supervised
            .ended => {
                task_mod.groupFree(loop.group.?);
                if (!loop.exiting and (loop.arrivals != loop.entries or loop.sum != loop.entries)) failed.store(true, .monotonic);
                @as(*align(1) u64, @ptrCast(ret.?)).* = 1;
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

fn startRecord(ops: *RocOps, call: erased_callable.ErasedCallableFn, capture: []const u8) [*]u8 {
    const built = erased_callable.allocate(call, &noDrop, capture.len, ops);
    @memcpy(erased_callable.capturePtr(built)[0..capture.len], capture);
    return built;
}

fn record(task: *RocTask, call: erased_callable.ErasedCallableFn, capture: []const u8) [*]u8 {
    const size = erased_callable.payloadSize(capture.len);
    const built = startRecord(task.ops, call, capture);
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

const RunError = std.Thread.SpawnError || error{ TestExpectedEqual, TestUnexpectedResult };

/// One tree, on `worker_count` threads. With `cancel`, the host cancels the
/// root before one of its later resumes.
fn runTree(seed: u64, round_shape: Shape, cancel: bool) RunError!void {
    var prng = std.Random.DefaultPrng.init(seed);
    shape = round_shape;
    ready.len = 0;
    operations.len = 0;
    loops_len = 0;
    root_resumes = 0;
    cancel_at = if (cancel) 2 else 0;
    failed.store(false, .monotonic);
    root_ended.store(false, .monotonic);
    test_host.live.store(0, .monotonic);

    const ops = &test_host.ops;
    const loop = newLoop(prng.random().int(u64), 3);
    var root: u64 = 0;
    root_task = RocTask.createParallel(ops, startRecord(ops, &loopCall, std.mem.asBytes(&loop)), @ptrCast(&root), buffers);
    ready.push(root_task);

    var workers: [worker_count]std.Thread = undefined;
    for (&workers, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, worker, .{seed *% 31 +% index});
    for (workers) |thread| thread.join();

    if (!cancel and !round_shape.crashes) try std.testing.expectEqual(Status.done, root_status);
    if (root_status == .crashed) {
        var len: usize = undefined;
        const message = task_mod.host_calls.crashMessage(root_task, &len);
        try std.testing.expectEqualStrings("a leaf crashed", message[0..len]);
    }
    if (!round_shape.crashes) try std.testing.expect(root_status != .crashed);
    if (root_status == .done) try std.testing.expectEqual(@as(u64, 1), root);
    root_task.free();
    // Every child ended before the root, so nothing is ready or running.
    try std.testing.expectEqual(@as(usize, 0), ready.len);
    try std.testing.expectEqual(@as(usize, 0), operations.len);
    try std.testing.expect(!failed.load(.monotonic));
    // A crash here happens before its frame owns anything, so it leaks
    // nothing either.
    try std.testing.expectEqual(@as(isize, 0), test_host.live.load(.monotonic));
}

test "trees of loops resumed on several threads deliver every result" {
    for (0..rounds) |round| try runTree(round, .{ .crashes = false, .exits = false }, false);
}

test "loops that exit early cancel entries running on other threads" {
    for (0..rounds) |round| try runTree(round, .{ .crashes = false, .exits = true }, false);
}

test "an entry that crashes ends its owners running on other threads" {
    if (!crash_exit.available()) return error.SkipZigTest;
    var crashed: usize = 0;
    for (0..rounds) |round| {
        try runTree(round, .{ .crashes = true, .exits = round % 2 == 0 }, false);
        if (root_status == .crashed) crashed += 1;
    }
    try std.testing.expect(crashed > 0);
}

test "a root cancelled while its tree runs on several threads ends after every task below it" {
    if (!crash_exit.available()) return error.SkipZigTest;
    var cancelled: usize = 0;
    for (0..rounds) |round| {
        try runTree(round, .{ .crashes = round % 3 == 0, .exits = round % 2 == 0 }, true);
        if (root_status == .cancelled) cancelled += 1;
    }
    try std.testing.expect(cancelled > 0);
}
