//! Tests of waits on cells of shared state (design.md "Shared State",
//! "Waiting."), driven by a single-threaded test host.
//!
//! Each task runs a script of updates. An update has a threshold: it answers
//! `Wait` while its cell's value is below that, and otherwise stores a new
//! value, keeps it or crashes. The tests make the calls that `Shared.update!`
//! compiles to, in its order: an update takes the state, runs its function,
//! puts the state back, then settles or waits. A crash leaves the cell empty.

const std = @import("std");

const task_mod = @import("task.zig");
const dev_wrappers = @import("dev_wrappers.zig");
const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");
const crash_exit = @import("task_crash_exit.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;

/// A cell's payload. Its address is what the runtime knows the cell by.
const Cell = struct {
    value: i64 = 0,
    empty: bool = false,
};

/// What an update does once it no longer waits.
const Answer = enum(u8) { add, keep, crash };

const Step = struct {
    cell: *Cell,
    /// The update waits while the value is below this.
    threshold: i64 = std.math.minInt(i64),
    answer: Answer = .add,
    amount: i64 = 0,
    /// Whether the update's function crashes, instead of answering, for a
    /// value that is at least the threshold.
    log: ?u8 = null,
    /// Whether the step is no update, but the start of a `finally!`, whose
    /// cleanup is the step's update, or a return from one.
    cleanup: enum(u8) { none, push, pop } = .none,
};

/// One task and its script.
const Runner = struct {
    task: *RocTask = undefined,
    steps: []const Step,
    next: usize = 0,
    root: u64 = 0,
    ended: ?Status = null,
    ready: bool = false,
    index: usize = 0,

    /// The step its task waits in.
    fn waitingStep(self: *const Runner) ?Step {
        if (self.ended != null or self.task.waited_cell == null) return null;
        return self.steps[self.next];
    }
};

/// The host: which tasks are ready, in order.
const Host = struct {
    var queue: [256]*RocTask = undefined;
    var head: usize = 0;
    var len: usize = 0;
    var log: [64]u8 = undefined;
    var log_len: usize = 0;
    var probes: usize = 0;
    var message: [256]u8 = undefined;
    var message_len: usize = 0;

    fn reset() void {
        head = 0;
        len = 0;
        log_len = 0;
        probes = 0;
    }

    fn readyTask(task: *RocTask) callconv(.c) void {
        queue[len] = task;
        len += 1;
    }

    fn abortTask(_: *RocTask) callconv(.c) void {
        std.debug.print("a task waiting on a cell was aborted\n", .{});
        @trap();
    }

    fn resumeRunner(runner: *Runner) void {
        const status = runner.task.resumeFromHost(&readyTask, &abortTask);
        if (status == .pending) return;
        runner.ended = status;
        message_len = runner.task.crash_message_len;
        if (message_len > 0) @memcpy(message[0..message_len], runner.task.crash_message);
        runner.task.free();
    }

    /// Resume the ready task `pick` places from the front.
    fn resumeReady(runners: []Runner, pick: usize) void {
        const task = queue[head + pick];
        std.mem.copyBackwards(*RocTask, queue[head + 1 .. head + pick + 1], queue[head .. head + pick]);
        head += 1;
        if (head == len) {
            head = 0;
            len = 0;
        }
        for (runners) |*runner| if (runner.ended == null and runner.task == task) return resumeRunner(runner);
        std.debug.print("a task that ended was readied\n", .{});
        @trap();
    }

    fn drain(runners: []Runner) void {
        while (head < len) resumeReady(runners, 0);
    }
};

fn noDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

fn allocCallable(ops: *RocOps, call: erased_callable.ErasedCallableFn, comptime T: type, capture: T) [*]u8 {
    const built = erased_callable.allocate(call, &noDrop, @sizeOf(T), ops);
    @as(*align(1) T, @ptrCast(erased_callable.capturePtr(built))).* = capture;
    return built;
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

/// What the probe of an update captures.
const Probed = extern struct { cell: *Cell, threshold: i64, crashes: bool };

/// `cell_probe!`: 0 for `Wait`, 1 for another answer or a poisoned cell.
fn probeCall(ops: *RocOps, ret: ?[*]u8, _: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const probed = @as(*align(1) const Probed, @ptrCast(capture.?)).*;
    Host.probes += 1;
    if (probed.cell.empty) {
        ret.?[0] = 1;
        return;
    }
    const waits = probed.cell.value < probed.threshold;
    if (!waits and probed.crashes) ops.crash("an update crashed");
    ret.?[0] = @intFromBool(!waits);
}

/// What follows an update's function: the step's answer, and settling.
fn answer(ops: *RocOps, step: *const Step, crash_message: []const u8) void {
    if (step.answer == .crash) ops.crash(crash_message);
    if (step.answer == .add) step.cell.value += step.amount;
    step.cell.empty = false;
    dev_wrappers.roc_builtins_cell_settle(step.cell, step.answer == .add);
    if (step.log) |name| {
        Host.log[Host.log_len] = name;
        Host.log_len += 1;
    }
}

/// `cell_cleanup!`.
fn cleanupCall(ops: *RocOps, ret: ?[*]u8, _: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const Step = @as(*align(1) const *const Step, @ptrCast(capture.?)).*;
    if (step.cell.empty) ops.crash("a cleanup's cell was poisoned");
    step.cell.empty = true;
    answer(ops, step, "a cleanup crashed");
    ret.?[0] = 0;
}

fn scriptCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const runner: *Runner = @as(*align(1) const *Runner, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    while (runner.next < runner.steps.len) {
        const step = runner.steps[runner.next];
        switch (step.cleanup) {
            .none => {},
            .push => {
                dev_wrappers.roc_builtins_cleanup_push(allocCallable(ops, &cleanupCall, *const Step, &runner.steps[runner.next]));
                runner.next += 1;
                continue;
            },
            .pop => {
                dev_wrappers.roc_builtins_cleanup_pop();
                runner.next += 1;
                continue;
            },
        }
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
        answer(ops, &step, "an update crashed");
        runner.next += 1;
    }
    @as(*align(1) u64, @ptrCast(ret.?)).* = runner.index;
}

const buffers = task_mod.BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

fn begin(ops: *RocOps, runners: []Runner) void {
    Host.reset();
    for (runners, 0..) |*runner, index| {
        runner.index = index;
        const start = allocCallable(ops, &scriptCall, *Runner, runner);
        runner.task = RocTask.create(ops, start, @ptrCast(&runner.root), buffers);
    }
}

const testing = std.testing;

fn expectLog(expected: []const u8) error{ TestExpectedEqual, TestUnexpectedResult }!void {
    try testing.expectEqualStrings(expected, Host.log[0..Host.log_len]);
}

test "waiters go on oldest first, one for each store that only lets one go on" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const take = [_]Step{.{ .cell = &cell, .threshold = 1, .amount = -1, .log = 'a' }};
    const take_b = [_]Step{.{ .cell = &cell, .threshold = 1, .amount = -1, .log = 'b' }};
    const take_c = [_]Step{.{ .cell = &cell, .threshold = 1, .amount = -1, .log = 'c' }};
    const give = [_]Step{.{ .cell = &cell, .amount = 1 }};
    var runners = [_]Runner{ .{ .steps = &take }, .{ .steps = &take_b }, .{ .steps = &take_c }, .{ .steps = &give }, .{ .steps = &give }, .{ .steps = &give } };
    begin(env.getOps(), &runners);
    for (runners[0..4]) |*runner| Host.resumeRunner(runner);
    // Only the first was woken, though the state would let any one go on.
    try testing.expectEqual(@as(usize, 1), Host.len);
    Host.drain(&runners);
    for (runners[4..]) |*runner| {
        Host.resumeRunner(runner);
        Host.drain(&runners);
    }
    try expectLog("abc");
    for (runners) |runner| try testing.expectEqual(Status.done, runner.ended.?);
}

test "a store wakes the oldest waiter it lets go on, not one it doesn't" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const big = [_]Step{.{ .cell = &cell, .threshold = 10, .answer = .keep, .log = 'a' }};
    const small = [_]Step{.{ .cell = &cell, .threshold = 1, .answer = .keep, .log = 'b' }};
    const one = [_]Step{.{ .cell = &cell, .amount = 1 }};
    const ten = [_]Step{.{ .cell = &cell, .amount = 10 }};
    var runners = [_]Runner{ .{ .steps = &big }, .{ .steps = &small }, .{ .steps = &one }, .{ .steps = &ten } };
    begin(env.getOps(), &runners);
    for (runners[0..3]) |*runner| Host.resumeRunner(runner);
    Host.drain(&runners);
    try expectLog("b");
    Host.resumeRunner(&runners[3]);
    Host.drain(&runners);
    try expectLog("ba");
    for (runners) |runner| try testing.expectEqual(Status.done, runner.ended.?);
}

test "a waiter that goes on and keeps the state passes its wake on" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const keep = [_]Step{.{ .cell = &cell, .threshold = 1, .answer = .keep, .log = 'k' }};
    const give = [_]Step{.{ .cell = &cell, .amount = 1 }};
    var runners = [_]Runner{ .{ .steps = &keep }, .{ .steps = &keep }, .{ .steps = &keep }, .{ .steps = &give } };
    begin(env.getOps(), &runners);
    for (&runners) |*runner| Host.resumeRunner(runner);
    Host.drain(&runners);
    try expectLog("kkk");
    for (runners) |runner| try testing.expectEqual(Status.done, runner.ended.?);
}

test "a waiter that waits again keeps its place and passes its wake on" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const a = [_]Step{.{ .cell = &cell, .threshold = 2, .answer = .keep, .log = 'a' }};
    const b = [_]Step{.{ .cell = &cell, .threshold = 1, .answer = .keep, .log = 'b' }};
    const two = [_]Step{.{ .cell = &cell, .amount = 2 }};
    const less = [_]Step{.{ .cell = &cell, .amount = -1 }};
    var runners = [_]Runner{ .{ .steps = &a }, .{ .steps = &b }, .{ .steps = &two }, .{ .steps = &less }, .{ .steps = &two } };
    begin(env.getOps(), &runners);
    // `a` is woken at 2, but before it runs the value is 1, where only `b`
    // would go on: `a` carries the wake, waits again and hands it to `b`.
    for (runners[0..4]) |*runner| Host.resumeRunner(runner);
    try testing.expectEqual(@as(usize, 1), Host.len);
    Host.drain(&runners);
    try expectLog("b");
    try testing.expectEqual(@as(?*RocTask, null), runners[0].task.older_waiter);
    Host.resumeRunner(&runners[4]);
    Host.drain(&runners);
    try expectLog("ba");
    for (runners) |runner| try testing.expectEqual(Status.done, runner.ended.?);
}

test "a cancelled waiter leaves the cell, and one that carried a wake passes it on" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const take = [_]Step{.{ .cell = &cell, .threshold = 1, .amount = -1, .log = 't' }};
    const give = [_]Step{.{ .cell = &cell, .amount = 1 }};
    var runners = [_]Runner{ .{ .steps = &take }, .{ .steps = &take }, .{ .steps = &take }, .{ .steps = &give } };
    begin(env.getOps(), &runners);
    for (runners[0..3]) |*runner| Host.resumeRunner(runner);
    // The first is parked when it's cancelled.
    runners[0].task.cancel(&Host.abortTask, &Host.readyTask);
    Host.drain(&runners);
    try testing.expectEqual(Status.cancelled, runners[0].ended.?);
    // The second was woken when it's cancelled, so nothing readies it again,
    // and the third goes on in its place.
    Host.resumeRunner(&runners[3]);
    try testing.expectEqual(@as(usize, 1), Host.len);
    runners[1].task.cancel(&Host.abortTask, &Host.readyTask);
    try testing.expectEqual(@as(usize, 1), Host.len);
    Host.drain(&runners);
    try testing.expectEqual(Status.cancelled, runners[1].ended.?);
    try testing.expectEqual(Status.done, runners[2].ended.?);
    try expectLog("t");
}

test "a store doesn't wake a waiter that was cancelled, but the next one" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const take = [_]Step{.{ .cell = &cell, .threshold = 1, .amount = -1, .log = 't' }};
    const give = [_]Step{.{ .cell = &cell, .amount = 1 }};
    var runners = [_]Runner{ .{ .steps = &take }, .{ .steps = &take }, .{ .steps = &give } };
    begin(env.getOps(), &runners);
    for (runners[0..2]) |*runner| Host.resumeRunner(runner);
    runners[0].task.cancel(&Host.abortTask, &Host.readyTask);
    Host.resumeRunner(&runners[2]);
    // The cancel readied the first, and the store the second.
    try testing.expectEqual(@as(usize, 2), Host.len);
    Host.drain(&runners);
    try testing.expectEqual(Status.cancelled, runners[0].ended.?);
    try testing.expectEqual(Status.done, runners[1].ended.?);
    try expectLog("t");
}

test "a crashed update poisons its cell, and every task waiting on it crashes" {
    if (comptime !crash_exit.native) return error.SkipZigTest;
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    var other: Cell = .{};
    const wait = [_]Step{.{ .cell = &cell, .threshold = 1, .answer = .keep }};
    const wait_other = [_]Step{.{ .cell = &other, .threshold = 1, .answer = .keep }};
    const crash = [_]Step{.{ .cell = &cell, .answer = .crash }};
    const give = [_]Step{.{ .cell = &other, .amount = 1 }};
    var runners = [_]Runner{ .{ .steps = &wait }, .{ .steps = &wait_other }, .{ .steps = &wait }, .{ .steps = &wait }, .{ .steps = &crash }, .{ .steps = &give } };
    begin(env.getOps(), &runners);
    for (runners[0..5]) |*runner| Host.resumeRunner(runner);
    try testing.expectEqual(Status.crashed, runners[4].ended.?);
    Host.drain(&runners);
    for ([_]usize{ 0, 2, 3 }) |index| try testing.expectEqual(Status.crashed, runners[index].ended.?);
    try testing.expectEqual(@as(?Status, null), runners[1].ended);
    Host.resumeRunner(&runners[5]);
    Host.drain(&runners);
    try testing.expectEqual(Status.done, runners[1].ended.?);
}

test "a probe that crashes wakes its waiter, whose update crashes, and the waiters before and after it crash too" {
    if (comptime !crash_exit.native) return error.SkipZigTest;
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const wait = [_]Step{.{ .cell = &cell, .threshold = 5, .answer = .keep }};
    const crash = [_]Step{.{ .cell = &cell, .threshold = 1, .answer = .crash }};
    const give = [_]Step{.{ .cell = &cell, .amount = 1 }};
    var runners = [_]Runner{ .{ .steps = &wait }, .{ .steps = &crash }, .{ .steps = &wait }, .{ .steps = &give } };
    begin(env.getOps(), &runners);
    for (&runners) |*runner| Host.resumeRunner(runner);
    // The store's task is not the one that crashed.
    try testing.expectEqual(Status.done, runners[3].ended.?);
    try testing.expectEqual(@as(usize, 1), Host.len);
    Host.drain(&runners);
    for (runners[0..3]) |runner| try testing.expectEqual(Status.crashed, runner.ended.?);
}

test "an update of one cell probes no other cell's waiters" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    // Cells far enough apart to share an entry of the waiters' table and
    // close enough not to: any two of these may or may not.
    var cells: [512]Cell = @splat(.{});
    var waits: [512][1]Step = undefined;
    for (&waits, &cells) |*wait, *cell| wait[0] = .{ .cell = cell, .threshold = 1, .amount = -1 };
    var runners: [512]Runner = undefined;
    for (&runners, &waits) |*runner, *wait| runner.* = .{ .steps = wait };
    begin(env.getOps(), &runners);
    for (&runners) |*runner| Host.resumeRunner(runner);
    try testing.expectEqual(@as(usize, 0), Host.probes);
    for (&cells, 0..) |*cell, index| {
        const give = [_]Step{.{ .cell = cell, .amount = 1 }};
        var giver = [_]Runner{.{ .steps = &give }};
        giver[0].task = RocTask.create(env.getOps(), allocCallable(env.getOps(), &scriptCall, *Runner, &giver[0]), @ptrCast(&giver[0].root), buffers);
        Host.resumeRunner(&giver[0]);
        try testing.expectEqual(index + 1, Host.probes);
        Host.drain(&runners);
        try testing.expectEqual(Status.done, runners[index].ended.?);
    }
}

/// A random script of updates of `cells`.
fn randomSteps(random: std.Random, cells: []Cell, steps: []Step) void {
    for (steps) |*step| step.* = .{
        .cell = &cells[random.uintLessThan(usize, cells.len)],
        .threshold = random.intRangeAtMost(i64, -2, 3),
        .answer = if (crash_exit.native and random.uintLessThan(u32, 24) == 0) .crash else if (random.uintLessThan(u32, 3) == 0) .keep else .add,
        .amount = random.intRangeAtMost(i64, -2, 2),
    };
}

/// V7: with no task ready, no task is parked whose update would go on.
fn expectNoneLeftParked(runners: []const Runner) error{TestUnexpectedResult}!void {
    for (runners) |*runner| {
        const step = runner.waitingStep() orelse continue;
        try testing.expect(!step.cell.empty and step.cell.value < step.threshold);
    }
}

test "a cancelled task runs its cleanups innermost first, and their stores wake waiters" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    var never: Cell = .{};
    const hold = [_]Step{
        .{ .cell = &cell, .amount = 1, .log = 'o', .cleanup = .push },
        .{ .cell = &cell, .amount = 100, .log = 'x', .cleanup = .push },
        .{ .cell = &cell, .cleanup = .pop },
        .{ .cell = &cell, .amount = 10, .log = 'i', .cleanup = .push },
        .{ .cell = &never, .threshold = 1 },
    };
    const take = [_]Step{.{ .cell = &cell, .threshold = 11, .amount = -11, .log = 't' }};
    var runners = [_]Runner{ .{ .steps = &hold }, .{ .steps = &take } };
    begin(env.getOps(), &runners);
    for (&runners) |*runner| Host.resumeRunner(runner);
    try expectLog("");
    runners[0].task.cancel(&Host.abortTask, &Host.readyTask);
    Host.drain(&runners);
    try testing.expectEqual(Status.cancelled, runners[0].ended.?);
    try testing.expectEqual(Status.done, runners[1].ended.?);
    try expectLog("iot");
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a crashed task runs its cleanups and keeps its message" {
    if (!crash_exit.native) return error.SkipZigTest;
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    var other: Cell = .{};
    const steps = [_]Step{
        .{ .cell = &cell, .amount = 1, .log = 'o', .cleanup = .push },
        .{ .cell = &other, .answer = .crash },
    };
    var runners = [_]Runner{.{ .steps = &steps }};
    begin(env.getOps(), &runners);
    Host.resumeRunner(&runners[0]);
    try testing.expectEqual(Status.crashed, runners[0].ended.?);
    try testing.expectEqualStrings("an update crashed", Host.message[0..Host.message_len]);
    try expectLog("o");
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a cleanup's crash is a cancelled task's, poisons its cell, and leaves the other cleanups to run" {
    if (!crash_exit.native) return error.SkipZigTest;
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    var poisoned: Cell = .{};
    var never: Cell = .{};
    const hold = [_]Step{
        .{ .cell = &cell, .amount = 1, .log = 'o', .cleanup = .push },
        .{ .cell = &poisoned, .answer = .crash, .cleanup = .push },
        .{ .cell = &never, .threshold = 1 },
    };
    const waits = [_]Step{.{ .cell = &poisoned, .threshold = 1 }};
    var runners = [_]Runner{ .{ .steps = &hold }, .{ .steps = &waits } };
    begin(env.getOps(), &runners);
    for (&runners) |*runner| Host.resumeRunner(runner);
    runners[0].task.cancel(&Host.abortTask, &Host.readyTask);
    Host.resumeReady(&runners, 0);
    try testing.expectEqual(Status.crashed, runners[0].ended.?);
    try testing.expectEqualStrings("a cleanup crashed", Host.message[0..Host.message_len]);
    try expectLog("o");
    Host.drain(&runners);
    try testing.expectEqual(Status.crashed, runners[1].ended.?);
    try testing.expectEqualStrings("this cell was poisoned", Host.message[0..Host.message_len]);
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "the messages of cleanups that crash follow a crashed task's own" {
    if (!crash_exit.native) return error.SkipZigTest;
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const steps = [_]Step{
        .{ .cell = &cell, .amount = 1, .log = 'o', .cleanup = .push },
        .{ .cell = &cell, .answer = .crash, .cleanup = .push },
        .{ .cell = &cell, .answer = .crash },
    };
    var runners = [_]Runner{.{ .steps = &steps }};
    begin(env.getOps(), &runners);
    Host.resumeRunner(&runners[0]);
    try testing.expectEqual(Status.crashed, runners[0].ended.?);
    try testing.expectEqualStrings(
        "an update crashed\na cleanup then crashed: a cleanup's cell was poisoned\na cleanup then crashed: a cleanup's cell was poisoned",
        Host.message[0..Host.message_len],
    );
    try expectLog("");
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a push outside any task drops its cleanup" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var cell: Cell = .{};
    const step = Step{ .cell = &cell };
    task_mod.cleanupPush(env.getOps(), allocCallable(env.getOps(), &cleanupCall, *const Step, &step));
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
    task_mod.cleanupPop();
}

test "in random runs, no task is left parked whose update would go on, whatever order tasks run and end in" {
    var woken_again: usize = 0;
    for (0..400) |seed| {
        var env = utils.TestEnv.init(testing.allocator);
        defer env.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var cells: [3]Cell = @splat(.{});
        var steps: [12][6]Step = undefined;
        for (&steps) |*script| randomSteps(random, &cells, script);
        var runners: [steps.len]Runner = undefined;
        for (&runners, &steps) |*runner, *script| runner.* = .{ .steps = script[0 .. 1 + random.uintLessThan(usize, script.len)] };
        begin(env.getOps(), &runners);
        var started: usize = 0;
        while (true) {
            const ready = Host.len - Host.head;
            if (started < runners.len and (ready == 0 or random.boolean())) {
                Host.resumeRunner(&runners[started]);
                started += 1;
            } else if (ready > 0) {
                if (ready > 1) woken_again += 1;
                Host.resumeReady(&runners, random.uintLessThan(usize, ready));
            } else break;
            if (random.uintLessThan(u32, 16) == 0) {
                const victim = &runners[random.uintLessThan(usize, runners.len)];
                if (victim.ended == null and victim.task.started and !victim.task.cancel_requested and victim.task.status == .pending) victim.task.cancel(&Host.abortTask, &Host.readyTask);
            }
            if (Host.head == Host.len) try expectNoneLeftParked(&runners);
        }
        // What still waits waits for good: cancel it.
        for (&runners) |*runner| {
            if (runner.ended != null) continue;
            runner.task.cancel(&Host.abortTask, &Host.readyTask);
            Host.drain(&runners);
        }
        for (runners) |runner| try testing.expect(runner.ended != null);
    }
    try testing.expect(woken_again > 0);
}
