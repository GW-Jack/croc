//! Tests of child tasks and groups (design.md "Child Tasks", "Plans And
//! Concurrent Loops"), driven by a single-threaded test host.
//!
//! The host keeps the tasks `roc_task_ready` handed it in a queue and
//! resumes them in order. When none is ready it finishes the oldest pending
//! hosted operation, which wakes its task. Entries are records that pause on
//! a hosted operation a given number of times and then return a value or
//! crash. A loop record plays the owner's code: it opens a group, takes
//! arrivals with `groupNext`, and suspends when nothing has arrived, as a
//! task-form loop compiles.

const std = @import("std");

const task_mod = @import("task.zig");
const dev_wrappers = @import("dev_wrappers.zig");
const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;
const Group = task_mod.Group;

/// Stop the test from a record or a host callback, which can't return an
/// error.
fn fail(comptime message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    @trap();
}

/// The test host: ready tasks, pending hosted operations and what happened.
const Host = struct {
    var ready: [64]*RocTask = undefined;
    var ready_head: usize = 0;
    var ready_len: usize = 0;
    var pending: [64]*RocTask = undefined;
    var pending_len: usize = 0;
    var aborts: usize = 0;
    var aborted: [16]*RocTask = undefined;
    /// Children running now, and the most at once.
    var live: usize = 0;
    var max_live: usize = 0;
    /// Arrivals the loop record took: the entry's id, in order.
    var arrivals: [32]u8 = undefined;
    var arrival_count: usize = 0;
    /// Entries whose code started, by id.
    var started: [32]u8 = undefined;
    var started_count: usize = 0;
    /// Crashes a supervised loop record took, and the last one's message.
    var crashes: usize = 0;
    var crash_message: [64]u8 = undefined;
    var crash_message_len: usize = 0;
    /// Children whose terminal status the host saw, by status.
    var ended: [4]usize = @splat(0);

    fn reset() void {
        ready_head = 0;
        ready_len = 0;
        pending_len = 0;
        aborts = 0;
        live = 0;
        max_live = 0;
        arrival_count = 0;
        started_count = 0;
        crashes = 0;
        crash_message_len = 0;
        ended = @splat(0);
    }

    fn readyTask(task: *RocTask) callconv(.c) void {
        ready[ready_len] = task;
        ready_len += 1;
    }

    fn abortTask(task: *RocTask) callconv(.c) void {
        aborted[aborts] = task;
        aborts += 1;
        for (pending[0..pending_len], 0..) |waiting, index| {
            if (waiting != task) continue;
            std.mem.copyForwards(*RocTask, pending[index .. pending_len - 1], pending[index + 1 .. pending_len]);
            pending_len -= 1;
            return;
        }
        fail("abort of a task with no pending operation");
    }

    fn startOperation(task: *RocTask) void {
        pending[pending_len] = task;
        pending_len += 1;
    }

    fn resumeTask(task: *RocTask) Status {
        return task.resumeFromHost(&readyTask, &abortTask);
    }

    /// Resume the root, then every task that becomes ready, finishing
    /// pending operations oldest first while none is, until the root ends.
    /// `cancel_at` cancels the root when that many operations have been
    /// started in all.
    fn run(root: *RocTask, cancel_at: ?usize) Status {
        return drive(root, resumeTask(root), cancel_at);
    }

    /// `run` after the root's resume returned `first`.
    fn drive(root: *RocTask, first: Status, cancel_at: ?usize) Status {
        var status = first;
        var operations_finished: usize = 0;
        while (status == .pending) {
            if (ready_head == ready_len) {
                if (cancel_at) |at| if (operations_finished == at) {
                    root.cancel(&abortTask, &readyTask);
                    operations_finished += 1;
                    continue;
                };
                if (pending_len == 0) fail("the root is pending with nothing ready and no operation pending");
                const task = pending[0];
                std.mem.copyForwards(*RocTask, pending[0 .. pending_len - 1], pending[1..pending_len]);
                pending_len -= 1;
                operations_finished += 1;
                task.wake(&readyTask);
                continue;
            }
            const task = ready[ready_head];
            ready_head += 1;
            if (ready_head == ready_len) {
                ready_head = 0;
                ready_len = 0;
            }
            if (task == root) {
                status = resumeTask(root);
                continue;
            }
            const was_started = task.started;
            if (!was_started) {
                live += 1;
                max_live = @max(max_live, live);
            }
            const child_status = resumeTask(task);
            if (child_status != .pending) {
                live -= 1;
                ended[@backingInt(child_status)] += 1;
            }
        }
        return status;
    }
};

/// What an entry's record does each time it runs.
const EntryStep = extern struct {
    id: u8,
    /// Hosted operations left to pause on before it finishes.
    pauses: u8,
    result: u64,
    crashes: bool = false,
    /// A loop the entry runs inside itself, as its first step.
    inner: ?*Loop = null,
};

fn entryCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const EntryStep = @ptrCast(@alignCast(capture.?));
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (step.inner) |inner| {
        var next = step.*;
        next.inner = null;
        // Run the inner loop first; this entry continues after it. Saves
        // go innermost first.
        task.pushRecord(record(task, &loopCall, std.mem.asBytes(&inner)), null);
        task.pushRecord(record(task, &entryCall, std.mem.asBytes(&next)), null);
        return;
    }
    if (step.pauses > 0) {
        var next = step.*;
        next.pauses -= 1;
        task.pushRecord(record(task, &entryCall, std.mem.asBytes(&next)), null);
        task.setPending();
        Host.startOperation(task);
        return;
    }
    if (step.crashes) ops.crash(crash_messages[step.id]);
    @as(*align(1) u64, @ptrCast(ret.?)).* = step.result;
}

const crash_messages = [_][]const u8{ "entry 0 crashed", "entry 1 crashed", "entry 2 crashed", "entry 3 crashed", "entry 4 crashed", "entry 5 crashed", long_crash_message };

/// Too long for a small string, so a message nobody releases is a leak.
const long_crash_message = "entry 6 crashed, and says so at length";

fn noDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

/// A record the task allocates, running `call` on a copy of `capture`.
fn record(task: *RocTask, call: erased_callable.ErasedCallableFn, capture: []const u8) [*]u8 {
    const size = erased_callable.payloadSize(capture.len);
    const built = erased_callable.allocate(call, &noDrop, capture.len, task.ops);
    @memcpy(erased_callable.capturePtr(built)[0..capture.len], capture);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], built[0..size]);
    utils.freeDataPtrC(built, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    return moved;
}

/// A start record for an entry, built before its child exists, as a plan's
/// entry closure is.
fn startRecord(ops: *RocOps, step: EntryStep) [*]u8 {
    const built = erased_callable.allocate(&entryCall, &noDrop, @sizeOf(EntryStep), ops);
    @as(*align(1) EntryStep, @ptrCast(erased_callable.capturePtr(built))).* = step;
    return built;
}

/// A concurrent loop's state, which the loop record's capture points at.
const Loop = struct {
    spec: task_mod.GroupSpec,
    group: ?*Group = null,
    /// After this many arrivals the body leaves the loop: cancel the group,
    /// then take what arrives until it ends.
    break_after: ?usize = null,
    /// Spawn this entry when the first result arrives.
    spawn_on_first: ?EntryStep = null,
    /// Pause on a hosted operation in the body when the first result
    /// arrives.
    pause_on_first: bool = false,
    /// Crash in the body when the first result arrives.
    crash_on_first: bool = false,
    /// Run this loop in the body when the first result arrives.
    inner_on_first: ?*Loop = null,
    /// The entry's steps when a supervised set's crash restarts it, which it
    /// does at most this many times.
    restart: ?EntryStep = null,
    restarts_left: usize = 0,
    restart_starts: [1][*]u8 = undefined,
    /// Drive the group through the C ABI a compiled task-form loop calls,
    /// with `result_drop` as the results' drop, rather than the Zig API.
    through_abi: bool = false,
    result_drop: ?erased_callable.OnDropFn = null,
    arrivals: usize = 0,
    exiting: bool = false,
    in_body_pause: bool = false,
    ended: bool = false,
};

fn loopCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const loop: *Loop = @as(*align(1) const *Loop, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (loop.group == null) loop.group = if (loop.through_abi) createThroughAbi(task, loop) else task_mod.groupCreate(task, loop.spec);
    var group = loop.group.?;
    loop.in_body_pause = false;
    while (true) {
        switch (if (loop.through_abi) nextThroughAbi(task) else task_mod.groupNext(group)) {
            .arrived => |arrival| {
                const value = @as(*align(1) const u64, @ptrCast(arrival.slot)).*;
                if (loop.exiting) continue;
                Host.arrivals[Host.arrival_count] = @intCast(value);
                Host.arrival_count += 1;
                loop.arrivals += 1;
                if (loop.arrivals == 1) {
                    if (loop.crash_on_first) ops.crash("the loop body crashed");
                    if (loop.spawn_on_first) |step| {
                        if (loop.through_abi) dev_wrappers.roc_builtins_group_spawn(abi_loop_id, startRecord(task.ops, step), task) else task_mod.spawnIn(group, startRecord(task.ops, step));
                    }
                    if (loop.inner_on_first) |inner| {
                        // The inner loop runs, then this one carries on.
                        task.pushRecord(record(task, &loopCall, std.mem.asBytes(&inner)), null);
                        task.pushRecord(record(task, &loopCall, std.mem.asBytes(&loop)), null);
                        return;
                    }
                    if (loop.pause_on_first) {
                        loop.in_body_pause = true;
                        task.pushRecord(record(task, &loopCall, std.mem.asBytes(&loop)), null);
                        task.setPending();
                        Host.startOperation(task);
                        return;
                    }
                }
                if (loop.break_after) |after| if (loop.arrivals == after) {
                    if (loop.through_abi) dev_wrappers.roc_builtins_group_cancel(abi_loop_id, task) else task_mod.cancelGroup(group);
                    loop.exiting = true;
                };
            },
            .ended => {
                if (loop.through_abi) dev_wrappers.roc_builtins_group_free(abi_loop_id, task) else task_mod.groupFree(group);
                loop.ended = true;
                if (ret) |out| @as(*align(1) u64, @ptrCast(out)).* = loop.arrivals;
                return;
            },
            .crashed => |crash| {
                const message = crash.message.asSlice();
                Host.crashes += 1;
                Host.crash_message_len = message.len;
                @memcpy(Host.crash_message[0..message.len], message);
                crash.message.decref(task.ops);
                if (loop.through_abi) dev_wrappers.roc_builtins_group_free(abi_loop_id, task) else task_mod.groupFree(group);
                if (loop.restarts_left == 0) {
                    loop.ended = true;
                    @as(*align(1) u64, @ptrCast(ret.?)).* = loop.arrivals;
                    return;
                }
                loop.restarts_left -= 1;
                loop.restart_starts = .{startRecord(task.ops, loop.restart.?)};
                loop.spec.starts = &loop.restart_starts;
                group = if (loop.through_abi) createThroughAbi(task, loop) else task_mod.groupCreate(task, loop.spec);
                loop.group = group;
            },
            .pending => {
                task.pushRecord(record(task, &loopCall, std.mem.asBytes(&loop)), null);
                task.setPending();
                return;
            },
        }
    }
}

/// The loop id the C ABI test's loop names its set by.
const abi_loop_id: u64 = 7;

/// `group` as a compiled loop makes it: init, one push per entry with its
/// limit path as a `List(U64)`, then start, each naming the set by its loop
/// id and owner.
fn createThroughAbi(task: *RocTask, loop: *const Loop) *Group {
    const plan = loop.spec;
    const root_limit: u64 = if (plan.root_limit) |root| @as(u64, root) + 1 else 0;
    dev_wrappers.roc_builtins_group_init(abi_loop_id, plan.starts.len, @ptrCast(plan.limits.ptr), plan.limits.len, root_limit, plan.supervised, plan.slot_size, plan.slot_alignment, loop.result_drop, task);
    for (plan.starts, plan.marks) |start_record, marks| {
        var path: [8]u64 = undefined;
        for (marks.limit_path, path[0..marks.limit_path.len]) |limit, *wide| wide.* = limit;
        dev_wrappers.roc_builtins_group_push(abi_loop_id, start_record, @ptrCast(&path), marks.limit_path.len, marks.shielded, marks.background, task);
    }
    dev_wrappers.roc_builtins_group_start(abi_loop_id, task);
    return task_mod.openGroup(task, abi_loop_id);
}

/// `next` as a compiled loop calls it.
fn nextThroughAbi(task: *RocTask) task_mod.Next {
    return switch (dev_wrappers.roc_builtins_group_next(abi_loop_id, task)) {
        0 => .{ .arrived = .{ .index = 0, .slot = dev_wrappers.roc_builtins_group_arrival(abi_loop_id, task) } },
        1 => .ended,
        2 => .pending,
        3 => .{ .crashed = .{ .message = @ptrCast(@alignCast(dev_wrappers.roc_builtins_group_arrival(abi_loop_id, task))) } },
        else => fail("group_next returned an unknown status"),
    };
}

/// A result drop with an erased capture's `on_drop` shape: adds the
/// dropped result to `dropped_sum`.
fn countDrop(slot: ?[*]u8, _: *RocOps) callconv(.c) void {
    dropped_sum += @as(*align(1) const u64, @ptrCast(slot.?)).*;
}
var dropped_sum: u64 = 0;

const buffers = task_mod.BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

/// A root task whose code is `loop`.
fn rootTask(ops: *RocOps, loop: *Loop, root: *u64) *RocTask {
    const start = erased_callable.allocate(&loopCall, &noDrop, @sizeOf(*Loop), ops);
    @as(*align(1) *Loop, @ptrCast(erased_callable.capturePtr(start))).* = loop;
    return RocTask.create(ops, start, @ptrCast(root), buffers);
}

fn spec(starts: []const [*]u8, marks: []const task_mod.EntryMarks, limits: []const u64, root_limit: ?u32) task_mod.GroupSpec {
    return .{
        .starts = starts,
        .marks = marks,
        .limits = limits,
        .root_limit = root_limit,
        .slot_size = 8,
        .slot_alignment = 8,
        .result_drop = null,
        .result_drop_context = null,
    };
}

const plain: task_mod.EntryMarks = .{ .limit_path = &.{}, .shielded = false, .background = false };

test "a loop runs each entry as a child task and takes each result as it arrives" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 2, .result = 10 }),
        startRecord(ops, .{ .id = 1, .pauses = 0, .result = 11 }),
        startRecord(ops, .{ .id = 2, .pauses = 1, .result = 12 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain, plain }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqual(@as(u64, 3), root);
    // Entry 1 never pauses; 2 pauses once and 0 twice.
    try std.testing.expectEqualSlices(u8, &.{ 11, 12, 10 }, Host.arrivals[0..Host.arrival_count]);
    try std.testing.expectEqual(@as(usize, 3), Host.ended[@backingInt(Status.done)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a loop driven through the group C ABI runs limited, spawned and background entries, and drops a result nobody takes" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    dropped_sum = 0;
    const limited: task_mod.EntryMarks = .{ .limit_path = &.{0}, .shielded = false, .background = false };
    // Shielded and begun, so the loop's end lets it finish, and its result
    // is dropped.
    const kept_background: task_mod.EntryMarks = .{ .limit_path = &.{}, .shielded = true, .background = true };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 1, .result = 60 }),
        startRecord(ops, .{ .id = 1, .pauses = 4, .result = 7 }),
        startRecord(ops, .{ .id = 2, .pauses = 0, .result = 62 }),
    };
    var loop: Loop = .{
        .spec = spec(&starts, &.{ limited, kept_background, limited }, &.{1}, 0),
        .spawn_on_first = .{ .id = 3, .pauses = 1, .result = 63 },
        .through_abi = true,
        .result_drop = &countDrop,
    };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    // Limit 0 runs entry 0, then 2, then the spawned entry, one at a time.
    try std.testing.expectEqual(@as(usize, 2), Host.max_live);
    try std.testing.expectEqualSlices(u8, &.{ 60, 62, 63 }, Host.arrivals[0..Host.arrival_count]);
    try std.testing.expectEqual(@as(u64, 7), dropped_sum);
    try std.testing.expectEqual(@as(usize, 4), Host.ended[@backingInt(Status.done)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a limit keeps at most its count of entries running, and starts the next as one finishes" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    var starts: [5][*]u8 = undefined;
    for (&starts, 0..) |*start, index| start.* = startRecord(ops, .{ .id = @intCast(index), .pauses = 2, .result = 20 + index });
    const under_limit: task_mod.EntryMarks = .{ .limit_path = &.{0}, .shielded = false, .background = false };
    const marks: [5]task_mod.EntryMarks = @splat(under_limit);
    var loop: Loop = .{ .spec = spec(&starts, &marks, &.{2}, 0) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqual(@as(u64, 5), root);
    try std.testing.expectEqual(@as(usize, 2), Host.max_live);
    // Input order among entries waiting for room.
    try std.testing.expectEqualSlices(u8, &.{ 20, 21, 22, 23, 24 }, Host.arrivals[0..Host.arrival_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "nested limits: an entry starts only when every limit on its path has room" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    var starts: [4][*]u8 = undefined;
    for (&starts, 0..) |*start, index| start.* = startRecord(ops, .{ .id = @intCast(index), .pauses = 1, .result = 30 + index });
    const outer: task_mod.EntryMarks = .{ .limit_path = &.{0}, .shielded = false, .background = false };
    const inner: task_mod.EntryMarks = .{ .limit_path = &.{ 0, 1 }, .shielded = false, .background = false };
    // Limit 0 allows 3; limit 1, inside it, allows 1. Entries 1 and 2 are
    // under both, so 2 waits for 1 although limit 0 has room.
    var loop: Loop = .{ .spec = spec(&starts, &.{ outer, inner, inner, outer }, &.{ 3, 1 }, 0) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqual(@as(u64, 4), root);
    try std.testing.expectEqual(@as(usize, 3), Host.max_live);
    try std.testing.expectEqualSlices(u8, &.{ 30, 31, 33, 32 }, Host.arrivals[0..Host.arrival_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "once only background entries are left, the loop cancels them, drops what they report and ends" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const background: task_mod.EntryMarks = .{ .limit_path = &.{}, .shielded = false, .background = true };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 5, .result = 40 }),
        startRecord(ops, .{ .id = 1, .pauses = 1, .result = 41 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ background, plain }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqualSlices(u8, &.{41}, Host.arrivals[0..Host.arrival_count]);
    // The background entry was parked on its operation: aborted, then
    // cancelled.
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.cancelled)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a loop exit cancels running entries, waits for shielded ones that have begun, and drops unstarted ones even if shielded" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const shielded: task_mod.EntryMarks = .{ .limit_path = &.{0}, .shielded = true, .background = false };
    const limited: task_mod.EntryMarks = .{ .limit_path = &.{0}, .shielded = false, .background = false };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 50 }),
        startRecord(ops, .{ .id = 1, .pauses = 3, .result = 51 }),
        startRecord(ops, .{ .id = 2, .pauses = 3, .result = 52 }),
        // Waits for room under limit 0, which entries 1 and 2 hold until
        // the exit, so it hasn't started then.
        startRecord(ops, .{ .id = 3, .pauses = 0, .result = 53 }),
    };
    var loop: Loop = .{
        .spec = spec(&starts, &.{ plain, shielded, limited, shielded }, &.{2}, null),
        .break_after = 1,
    };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqual(@as(u64, 1), root);
    try std.testing.expectEqualSlices(u8, &.{50}, Host.arrivals[0..Host.arrival_count]);
    // Entry 2 was cancelled at its pause; shielded entry 1 ran to the end;
    // entry 3 never started.
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    try std.testing.expectEqual(@as(usize, 2), Host.ended[@backingInt(Status.done)]);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.cancelled)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a spawned entry goes under the root limit and arrives like the others" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const limited: task_mod.EntryMarks = .{ .limit_path = &.{0}, .shielded = false, .background = false };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 60 }),
        startRecord(ops, .{ .id = 1, .pauses = 2, .result = 61 }),
    };
    var loop: Loop = .{
        .spec = spec(&starts, &.{ limited, limited }, &.{2}, 0),
        .spawn_on_first = .{ .id = 2, .pauses = 1, .result = 62 },
    };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqual(@as(u64, 3), root);
    try std.testing.expectEqual(@as(usize, 2), Host.max_live);
    try std.testing.expectEqualSlices(u8, &.{ 60, 62, 61 }, Host.arrivals[0..Host.arrival_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "cancelling a root parked on its loop cancels every entry, and the root ends after they report" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const shielded: task_mod.EntryMarks = .{ .limit_path = &.{}, .shielded = true, .background = false };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 3, .result = 70 }),
        startRecord(ops, .{ .id = 1, .pauses = 3, .result = 71 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, shielded }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    // Both entries are parked on their first operation when the host
    // cancels; a shield doesn't protect from a cancel.
    try std.testing.expectEqual(Status.cancelled, Host.run(task, 0));
    try std.testing.expectEqual(@as(usize, 0), Host.arrival_count);
    try std.testing.expectEqual(@as(usize, 2), Host.aborts);
    try std.testing.expectEqual(@as(usize, 2), Host.ended[@backingInt(Status.cancelled)]);
    try std.testing.expect(!loop.ended);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "an entry's crash crashes its parked owner with the same message and cancels the other entries" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 4, .result = 80 }),
        startRecord(ops, .{ .id = 1, .pauses = 1, .result = 81, .crashes = true }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.crashed, Host.run(task, null));
    var len: usize = 0;
    const message = task_mod.host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("entry 1 crashed", message[0..len]);
    try std.testing.expectEqual(@as(usize, 0), Host.arrival_count);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.crashed)]);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.cancelled)]);
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

/// The set of one supervised entry.
fn supervisedSpec(starts: []const [*]u8) task_mod.GroupSpec {
    var result = spec(starts, &.{plain}, &.{}, null);
    result.supervised = true;
    return result;
}

fn checkSupervisedRestarts(through_abi: bool) error{ TestExpectedEqual, TestUnexpectedResult }!void {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const crashing: EntryStep = .{ .id = 6, .pauses = 1, .result = 0, .crashes = true };
    const starts = [_][*]u8{startRecord(ops, crashing)};
    var loop: Loop = .{ .spec = supervisedSpec(&starts), .restart = crashing, .restarts_left = 2, .through_abi = through_abi };
    var root: u64 = 99;
    const task = rootTask(ops, &loop, &root);
    // The owner takes each crash and runs on: two restarts, then it ends with
    // no arrival.
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqual(@as(u64, 0), root);
    try std.testing.expectEqual(@as(usize, 3), Host.crashes);
    try std.testing.expectEqualStrings(long_crash_message, Host.crash_message[0..Host.crash_message_len]);
    try std.testing.expectEqual(@as(usize, 3), Host.ended[@backingInt(Status.crashed)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a supervised entry's crash is a report its owner takes, with the message" {
    try checkSupervisedRestarts(false);
}

test "a supervised entry's crash is a report its owner takes through the group C ABI" {
    try checkSupervisedRestarts(true);
}

test "a supervised entry that returns arrives as any entry does" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{startRecord(ops, .{ .id = 0, .pauses = 1, .result = 60, .crashes = false })};
    var loop: Loop = .{ .spec = supervisedSpec(&starts) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    try std.testing.expectEqualSlices(u8, &.{60}, Host.arrivals[0..Host.arrival_count]);
    try std.testing.expectEqual(@as(usize, 0), Host.crashes);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a supervised entry's crash cancels its own entries and reports once they have" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const inner_starts = [_][*]u8{
        startRecord(ops, .{ .id = 6, .pauses = 1, .result = 0, .crashes = true }),
        startRecord(ops, .{ .id = 1, .pauses = 5, .result = 71 }),
        startRecord(ops, .{ .id = 2, .pauses = 5, .result = 72 }),
    };
    var inner: Loop = .{ .spec = spec(&inner_starts, &.{ plain, plain, plain }, &.{}, null) };
    const starts = [_][*]u8{startRecord(ops, .{ .id = 0, .pauses = 0, .result = 70, .inner = &inner })};
    var loop: Loop = .{ .spec = supervisedSpec(&starts), .restart = .{ .id = 0, .pauses = 0, .result = 73 }, .restarts_left = 1 };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.done, Host.run(task, null));
    // The grandchild crashed and its siblings were cancelled, then the entry
    // crashed with its message, and the restarted one arrived.
    try std.testing.expectEqual(@as(usize, 1), Host.crashes);
    try std.testing.expectEqualStrings(long_crash_message, Host.crash_message[0..Host.crash_message_len]);
    try std.testing.expectEqual(@as(usize, 2), Host.ended[@backingInt(Status.crashed)]);
    try std.testing.expectEqual(@as(usize, 2), Host.ended[@backingInt(Status.cancelled)]);
    try std.testing.expectEqual(@as(usize, 2), Host.aborts);
    try std.testing.expectEqualSlices(u8, &.{73}, Host.arrivals[0..Host.arrival_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "cancelling the owner of a supervised entry cancels the entry" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{startRecord(ops, .{ .id = 6, .pauses = 3, .result = 0, .crashes = true })};
    var loop: Loop = .{ .spec = supervisedSpec(&starts) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.cancelled, Host.run(task, 1));
    try std.testing.expectEqual(@as(usize, 0), Host.crashes);
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.cancelled)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "cancelling the owner of a supervised entry whose crash it has not taken drops the message" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{startRecord(ops, .{ .id = 6, .pauses = 0, .result = 0, .crashes = true })};
    var loop: Loop = .{ .spec = supervisedSpec(&starts) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.pending, Host.resumeTask(task));
    try std.testing.expectEqual(@as(usize, 1), Host.ready_len);
    try std.testing.expectEqual(Status.crashed, Host.resumeTask(Host.ready[0]));
    task.cancel(&Host.abortTask, &Host.readyTask);
    try std.testing.expectEqual(Status.cancelled, Host.resumeTask(task));
    try std.testing.expectEqual(@as(usize, 0), Host.crashes);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "an entry's crash aborts the hosted operation its owner is parked on, then readies the owner to crash" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 90 }),
        startRecord(ops, .{ .id = 1, .pauses = 1, .result = 91, .crashes = true }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null), .pause_on_first = true };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.crashed, Host.run(task, null));
    var len: usize = 0;
    const message = task_mod.host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("entry 1 crashed", message[0..len]);
    try std.testing.expectEqualSlices(u8, &.{90}, Host.arrivals[0..Host.arrival_count]);
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    try std.testing.expectEqual(task, Host.aborted[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "cancelling a root cancels its grandchildren, and every task ends after its children" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const inner_starts = [_][*]u8{
        startRecord(ops, .{ .id = 2, .pauses = 3, .result = 102 }),
        startRecord(ops, .{ .id = 3, .pauses = 3, .result = 103 }),
    };
    var inner: Loop = .{ .spec = spec(&inner_starts, &.{ plain, plain }, &.{}, null) };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 100, .inner = &inner }),
        startRecord(ops, .{ .id = 1, .pauses = 3, .result = 101 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.cancelled, Host.run(task, 0));
    // Entry 1 and both grandchildren were parked on operations.
    try std.testing.expectEqual(@as(usize, 3), Host.aborts);
    try std.testing.expectEqual(@as(usize, 4), Host.ended[@backingInt(Status.cancelled)]);
    try std.testing.expect(!inner.ended);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "the task tree orders an ancestor before its descendants and siblings by creation" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const inner_starts = [_][*]u8{startRecord(ops, .{ .id = 2, .pauses = 1, .result = 112 })};
    var inner: Loop = .{ .spec = spec(&inner_starts, &.{plain}, &.{}, null) };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 1, .result = 110, .inner = &inner }),
        startRecord(ops, .{ .id = 1, .pauses = 1, .result = 111 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    // Run until the grandchild is parked: root, entry 0 (opens the inner
    // loop), entry 1, then the grandchild.
    try std.testing.expectEqual(Status.pending, Host.resumeTask(task));
    const first = Host.ready[0];
    const second = Host.ready[1];
    // The root waits at its loop's next, so it asks for its entries, which
    // have not begun.
    try std.testing.expect(task_mod.coroutineMayBegin(first));
    try std.testing.expect(task_mod.coroutineMayBegin(second));
    const root_wait = task.wait;
    task.wait = null;
    try std.testing.expect(!task_mod.coroutineMayBegin(second));
    task.wait = root_wait;
    try std.testing.expectEqual(Status.pending, Host.resumeTask(first));
    try std.testing.expectEqual(Status.pending, Host.resumeTask(second));
    const grandchild = Host.ready[2];
    // The first child waits at its own loop, and the root still at its own.
    try std.testing.expect(task_mod.coroutineMayBegin(grandchild));
    try std.testing.expect(task_mod.coroutineMayBegin(second));
    try std.testing.expectEqual(Status.pending, Host.resumeTask(grandchild));
    const Order = std.math.Order;
    try std.testing.expectEqual(Order.lt, task_mod.treeOrder(task, first));
    try std.testing.expectEqual(Order.lt, task_mod.treeOrder(first, second));
    try std.testing.expectEqual(Order.lt, task_mod.treeOrder(first, grandchild));
    try std.testing.expectEqual(Order.lt, task_mod.treeOrder(grandchild, second));
    try std.testing.expectEqual(Order.gt, task_mod.treeOrder(grandchild, task));
    try std.testing.expectEqual(Order.eq, task_mod.treeOrder(second, second));
    // Finish the run; every ready task was resumed above, and the three
    // children are running.
    Host.ready_len = 0;
    Host.ready_head = 0;
    Host.live = 3;
    try std.testing.expectEqual(Status.done, Host.drive(task, .pending, null));
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a crash in the loop body cancels the running entries, and the task crashes once they have reported" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 120 }),
        startRecord(ops, .{ .id = 1, .pauses = 3, .result = 121 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null), .crash_on_first = true };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.crashed, Host.run(task, null));
    var len: usize = 0;
    const message = task_mod.host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("the loop body crashed", message[0..len]);
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.cancelled)]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "a grandchild's crash crashes its parent, then the root, with the same message" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const inner_starts = [_][*]u8{
        startRecord(ops, .{ .id = 2, .pauses = 1, .result = 132, .crashes = true }),
        startRecord(ops, .{ .id = 3, .pauses = 4, .result = 133 }),
    };
    var inner: Loop = .{ .spec = spec(&inner_starts, &.{ plain, plain }, &.{}, null) };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 130, .inner = &inner }),
        startRecord(ops, .{ .id = 1, .pauses = 4, .result = 131 }),
    };
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null) };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.crashed, Host.run(task, null));
    var len: usize = 0;
    const message = task_mod.host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("entry 2 crashed", message[0..len]);
    // The grandchild and its parent crashed; their siblings were cancelled
    // at their pauses.
    try std.testing.expectEqual(@as(usize, 2), Host.ended[@backingInt(Status.crashed)]);
    try std.testing.expectEqual(@as(usize, 2), Host.ended[@backingInt(Status.cancelled)]);
    try std.testing.expectEqual(@as(usize, 2), Host.aborts);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "an entry's crash readies its owner parked on another of its loops, and the owner crashes after both loops' entries report" {
    var env = utils.TestEnv.init(std.testing.allocator);
    defer env.deinit();
    const ops = env.getOps();
    Host.reset();
    const inner_starts = [_][*]u8{startRecord(ops, .{ .id = 2, .pauses = 4, .result = 142 })};
    var inner: Loop = .{ .spec = spec(&inner_starts, &.{plain}, &.{}, null) };
    const starts = [_][*]u8{
        startRecord(ops, .{ .id = 0, .pauses = 0, .result = 140 }),
        startRecord(ops, .{ .id = 1, .pauses = 2, .result = 141, .crashes = true }),
    };
    // The body opens the inner loop at the first arrival, so the owner is
    // parked on the inner group when entry 1 of the outer one crashes.
    var loop: Loop = .{ .spec = spec(&starts, &.{ plain, plain }, &.{}, null), .inner_on_first = &inner };
    var root: u64 = 0;
    const task = rootTask(ops, &loop, &root);
    try std.testing.expectEqual(Status.crashed, Host.run(task, null));
    var len: usize = 0;
    const message = task_mod.host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("entry 1 crashed", message[0..len]);
    try std.testing.expectEqual(@as(usize, 1), Host.ended[@backingInt(Status.cancelled)]);
    try std.testing.expectEqual(@as(usize, 1), Host.aborts);
    try std.testing.expect(!inner.ended);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}
