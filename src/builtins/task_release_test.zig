//! Tests of how tracked cells of shared state are freed (design.md "Shared State",
//! "Releasing cells."), driven by a single-threaded test host.
//!
//! Each task runs a script of steps on the handles it holds, or random ones. A cell's
//! state is two handles, so cells form cycles. The tests make the calls that
//! `Shared.new!` and `Shared.update!` compile to. A cell whose state was moved
//! out was released, so a step that uses a handle to one fails.

const std = @import("std");

const task_mod = @import("task.zig");
const erased_callable = @import("erased_callable.zig");
const utils = @import("utils.zig");
const crash_exit = @import("task_crash_exit.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Status = task_mod.Status;
const testing = std.testing;

/// Stop the test from a record or a host callback, which can't return an error.
fn fail(comptime message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    @trap();
}

/// A cell's payload. A handle is its address.
const Cell = extern struct {
    held: [2]?*Cell,
    released: bool,
};

var live_cells: usize = 0;

fn newCell(ops: *RocOps) *Cell {
    live_cells += 1;
    const cell: *Cell = @ptrCast(@alignCast(utils.allocateWithRefcountC(@sizeOf(Cell), @alignOf(Cell), true, ops)));
    cell.* = .{ .held = .{ null, null }, .released = false };
    return cell;
}

fn countOf(cell: *Cell) *isize {
    const words: [*]isize = @ptrCast(@alignCast(cell));
    return &(words - 1)[0];
}

fn retain(handle: ?*Cell) ?*Cell {
    if (handle) |cell| countOf(cell).* += 1;
    return handle;
}

fn drop(handle: ?*Cell, ops: *RocOps) void {
    const cell = handle orelse return;
    countOf(cell).* -= 1;
    if (countOf(cell).* != 0) return;
    for (cell.held) |held| drop(held, ops);
    live_cells -= 1;
    utils.freeDataPtrC(@ptrCast(cell), @alignOf(Cell), true, ops);
}

/// `cell_release!`.
fn releaseCall(ops: *RocOps, ret: ?[*]u8, _: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const cell: *Cell = @as(*align(1) const *Cell, @ptrCast(capture.?)).*;
    const held = cell.held;
    cell.held = .{ null, null };
    cell.released = true;
    for (held) |handle| drop(handle, ops);
    ret.?[0] = 0;
}

fn releaseDrop(capture: ?[*]u8, ops: *RocOps) callconv(.c) void {
    drop(@as(*align(1) const *Cell, @ptrCast(capture.?)).*, ops);
}

/// `Shared.new!`.
fn trackedCell(ops: *RocOps) *Cell {
    const cell = newCell(ops);
    const release = erased_callable.allocate(&releaseCall, &releaseDrop, @sizeOf(*Cell), ops);
    @as(*align(1) ?*Cell, @ptrCast(erased_callable.capturePtr(release))).* = retain(cell);
    task_mod.cellTrack(ops, @ptrCast(cell), release);
    return cell;
}

const slots = 4;

/// One step of a task, on the handles in its slots.
const Step = union(enum) {
    /// Make a cell.
    make: usize,
    /// Copy the handle `from` holds over the one in `to`.
    copy: struct { from: usize, to: usize },
    /// `cell`'s state holds the handle in `from`, as its `index`th.
    store: struct { cell: usize, index: usize, from: usize },
    /// Copy the `index`th handle of `cell`'s state.
    load: struct { cell: usize, index: usize, to: usize },
    drop: usize,
    /// Run children at once, until they end. A child begins with copies of the
    /// handles its parent holds.
    children: struct { of: []const []const Step, results: bool = false, supervised: bool = false },
    /// End with the handle.
    answer: usize,
    crash,
    /// Cancel the root.
    cancel,
    /// How many cells there are, exactly or at most.
    expect: usize,
    at_most: usize,
};

/// What a task's records hold: one reference each.
const State = struct {
    records: usize,
    steps: []const Step,
    next: usize = 0,
    random: ?std.Random = null,
    depth: usize = 0,
    handles: [slots]?*Cell = @splat(null),
    group: ?*task_mod.Group = null,
    answers: bool = false,
    steps_left: usize = 0,
    generated: [1]Step = undefined,
    generated_children: [3][]const Step = @splat(&.{}),
    arrived: usize = 0,
};

var arena: std.mem.Allocator = undefined;

fn stateDrop(capture: ?[*]u8, ops: *RocOps) callconv(.c) void {
    const state: *State = @as(*align(1) const *State, @ptrCast(capture.?)).*;
    state.records -= 1;
    if (state.records > 0) return;
    for (&state.handles) |*handle| {
        drop(handle.*, ops);
        handle.* = null;
    }
}

fn newRecord(ops: *RocOps, state: *State) [*]u8 {
    const built = erased_callable.allocate(&taskCall, &stateDrop, @sizeOf(*State), ops);
    @as(*align(1) *State, @ptrCast(erased_callable.capturePtr(built))).* = state;
    state.records += 1;
    return built;
}

fn pause(task: *RocTask, state: *State) void {
    const size = erased_callable.payloadSize(@sizeOf(*State));
    const built = newRecord(task.ops, state);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], built[0..size]);
    utils.freeDataPtrC(built, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    task.pushRecord(moved, null);
    task.setPending();
}

/// The host: which tasks are ready, in order.
const Host = struct {
    var queue: [4096]*RocTask = undefined;
    var len: usize = 0;
    var root: *RocTask = undefined;

    fn readyTask(task: *RocTask) callconv(.c) void {
        queue[len] = task;
        len += 1;
    }

    fn abortTask(_: *RocTask) callconv(.c) void {
        fail("a task that made no hosted call was aborted");
    }

    /// Run `state`'s task as a root until it ends, resuming ready tasks in order,
    /// or in random order.
    fn run(ops: *RocOps, state: *State) Status {
        live_cells = 0;
        len = 0;
        var result: ?*Cell = null;
        root = RocTask.create(ops, newRecord(ops, state), @ptrCast(&result), buffers);
        var status = root.resumeFromHost(&readyTask, &abortTask);
        while (status == .pending) {
            if (len == 0) fail("the root is pending with nothing ready");
            const pick = if (state.random) |random| random.uintLessThan(usize, len) else 0;
            const task = queue[pick];
            std.mem.copyForwards(*RocTask, queue[pick .. len - 1], queue[pick + 1 .. len]);
            len -= 1;
            const got = task.resumeFromHost(&readyTask, &abortTask);
            if (task == root) status = got;
        }
        root.free();
        return status;
    }
};

const buffers = task_mod.BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

fn usable(state: *State, slot: usize) *Cell {
    const cell = state.handles[slot] orelse fail("a step used a handle its task doesn't hold");
    if (cell.released) fail("a task holds a handle to a cell that was released");
    return cell;
}

fn put(state: *State, slot: usize, handle: ?*Cell, ops: *RocOps) void {
    const old = state.handles[slot];
    state.handles[slot] = handle;
    drop(old, ops);
}

fn resultDrop(slot: [*]u8, _: ?*anyopaque, ops: *RocOps) callconv(.c) void {
    drop(@as(*?*Cell, @ptrCast(@alignCast(slot))).*, ops);
}

fn open(task: *RocTask, state: *State, of: []const []const Step, results: bool, supervised: bool) void {
    var starts: [3][*]u8 = undefined;
    for (of, starts[0..of.len]) |steps, *start| {
        const child = arena.create(State) catch fail("out of memory");
        child.* = .{ .records = 0, .steps = steps, .random = state.random, .depth = state.depth + 1, .answers = results };
        if (state.random) |random| child.steps_left = random.uintLessThan(usize, 12);
        for (state.handles, &child.handles) |handle, *copy| copy.* = retain(handle);
        start.* = newRecord(task.ops, child);
    }
    const marks: [3]task_mod.EntryMarks = @splat(.{ .limit_path = &.{}, .shielded = false, .background = false });
    state.group = task_mod.groupCreate(task, .{
        .starts = starts[0..of.len],
        .marks = marks[0..of.len],
        .limits = &.{},
        .root_limit = null,
        .slot_size = 8,
        .slot_alignment = 8,
        .result_drop = &resultDrop,
        .result_drop_context = null,
        .supervised = supervised,
        .results_hold_handles = results,
    });
}

/// A random step that uses only what the task holds.
fn randomStep(state: *State) Step {
    const random = state.random.?;
    var full: [slots]usize = undefined;
    var full_len: usize = 0;
    for (state.handles, 0..) |handle, slot| if (handle != null) {
        full[full_len] = slot;
        full_len += 1;
    };
    const any = random.uintLessThan(usize, slots);
    const index = random.uintLessThan(usize, 2);
    const kind = random.uintLessThan(u32, 100);
    if (kind < 12 and state.depth < 4) {
        const count = 1 + random.uintLessThan(usize, 3);
        const supervised = random.uintLessThan(u32, 3) == 0;
        return .{ .children = .{
            .of = state.generated_children[0..if (supervised) 1 else count],
            .results = random.boolean(),
            .supervised = supervised,
        } };
    }
    if (kind < 14 and crash_exit.native) return .crash;
    if (kind < 15 and random.uintLessThan(u32, 4) == 0) return .cancel;
    if (full_len == 0 or kind < 40) return .{ .make = any };
    const one = full[random.uintLessThan(usize, full_len)];
    const other = full[random.uintLessThan(usize, full_len)];
    if (kind < 70) return .{ .store = .{ .cell = one, .index = index, .from = other } };
    if (kind < 90) return .{ .load = .{ .cell = one, .index = index, .to = any } };
    return .{ .drop = one };
}

fn nextStep(state: *State) ?Step {
    if (state.random == null) {
        if (state.next == state.steps.len) return null;
        defer state.next += 1;
        return state.steps[state.next];
    }
    if (state.steps_left == 0) {
        if (!state.answers or state.arrived == std.math.maxInt(usize)) return null;
        state.arrived = std.math.maxInt(usize);
        for (state.handles, 0..) |handle, slot| if (handle != null) return .{ .answer = slot };
        return null;
    }
    state.steps_left -= 1;
    return randomStep(state);
}

fn taskCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const state: *State = @as(*align(1) const *State, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    const result: *?*Cell = @ptrCast(@alignCast(ret.?));
    var answered: ?*Cell = null;
    while (true) {
        if (state.group) |group| switch (task_mod.groupNext(group)) {
            .arrived => |arrival| {
                // The oldest result is in the first slot, and so on.
                const slot = state.arrived % slots;
                state.arrived += 1;
                const handle = @as(*?*Cell, @ptrCast(@alignCast(arrival.slot))).*;
                if (handle) |cell| put(state, slot, cell, ops);
                continue;
            },
            .crashed => |crash| {
                crash.message.decref(ops);
                task_mod.groupFree(group);
                state.group = null;
                continue;
            },
            .ended => {
                task_mod.groupFree(group);
                state.group = null;
                state.arrived = 0;
                continue;
            },
            .pending => return pause(task, state),
        };
        switch (nextStep(state) orelse break) {
            .make => |slot| put(state, slot, trackedCell(ops), ops),
            .copy => |copy| put(state, copy.to, retain(usable(state, copy.from)), ops),
            .store => |store| {
                const cell = usable(state, store.cell);
                const old = cell.held[store.index];
                cell.held[store.index] = retain(usable(state, store.from));
                task_mod.cellSettle(@ptrCast(cell), true, true);
                drop(old, ops);
            },
            .load => |load| put(state, load.to, retain(usable(state, load.cell).held[load.index]), ops),
            .drop => |slot| put(state, slot, null, ops),
            .children => |children| {
                for (&state.handles) |handle| if (handle) |cell| if (cell.released) fail("a task holds a handle to a cell that was released");
                open(task, state, children.of, children.results, children.supervised);
            },
            .answer => |slot| answered = retain(usable(state, slot)),
            .crash => ops.crash("a task crashed"),
            .cancel => if (!Host.root.cancel_requested and Host.root.status == .pending) Host.root.cancel(&Host.abortTask, &Host.readyTask),
            .expect => |count| if (live_cells != count) {
                std.debug.print("expected {d} cells, found {d}\n", .{ count, live_cells });
                fail("the wrong number of cells is live");
            },
            .at_most => |count| if (live_cells > count) fail("too many cells are live"),
        }
    }
    result.* = answered;
}

fn runScript(steps: []const Step) error{TestExpectedEqual}!Status {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    var memory = std.heap.ArenaAllocator.init(testing.allocator);
    defer memory.deinit();
    arena = memory.allocator();
    var state: State = .{ .records = 0, .steps = steps };
    const status = Host.run(env.getOps(), &state);
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
    return status;
}

/// A cell whose state holds a handle to it.
const make_cycle = [_]Step{ .{ .make = 0 }, .{ .store = .{ .cell = 0, .index = 0, .from = 0 } } };

test "a task's end frees the cycles it made, though its parent runs on" {
    try testing.expectEqual(Status.done, try runScript(&.{
        .{ .children = .{ .of = &.{ &make_cycle, &make_cycle } } },
        .{ .expect = 0 },
    }));
}

test "a root's end frees the cycles of its tree" {
    try testing.expectEqual(Status.done, try runScript(&(make_cycle ++ [_]Step{.{ .expect = 1 }})));
}

test "a cell that a child's state or result brought to its parent lives as long as the parent's own" {
    // In slot 1, a cell of the child's that is on a cycle, through the parent's in
    // slot 0.
    const stores = [_]Step{
        .{ .make = 1 },
        .{ .store = .{ .cell = 1, .index = 0, .from = 1 } },
        .{ .store = .{ .cell = 0, .index = 0, .from = 1 } },
    };
    try testing.expectEqual(Status.done, try runScript(&.{
        .{ .make = 0 },
        .{ .children = .{ .of = &.{&stores} } },
        .{ .load = .{ .cell = 0, .index = 0, .to = 1 } },
        .{ .load = .{ .cell = 1, .index = 0, .to = 2 } },
        .{ .expect = 2 },
    }));
    const answers = make_cycle ++ [_]Step{.{ .answer = 0 }};
    try testing.expectEqual(Status.done, try runScript(&.{
        .{ .children = .{ .of = &.{&answers}, .results = true } },
        .{ .load = .{ .cell = 0, .index = 0, .to = 1 } },
        .{ .expect = 1 },
    }));
}

test "a task whose descendants' handles reach only its own cells frees them all at its end" {
    // The grandchildren's cells reach the child's cell, and the second's the first's.
    // The first still runs then, and has escaped, so its cell is as good as the
    // child's.
    const first = [_]Step{
        .{ .make = 1 },
        .{ .store = .{ .cell = 1, .index = 0, .from = 0 } },
        .{ .store = .{ .cell = 0, .index = 0, .from = 1 } },
        .{ .children = .{ .of = &.{&.{}} } },
    };
    const second = [_]Step{
        .{ .load = .{ .cell = 0, .index = 0, .to = 1 } },
        .{ .make = 2 },
        .{ .store = .{ .cell = 1, .index = 1, .from = 2 } },
        .{ .store = .{ .cell = 2, .index = 0, .from = 2 } },
    };
    const child = [_]Step{
        .{ .make = 0 },
        .{ .children = .{ .of = &.{ &first, &second } } },
        .{ .expect = 3 },
    };
    try testing.expectEqual(Status.done, try runScript(&.{
        .{ .children = .{ .of = &.{&child} } },
        .{ .expect = 0 },
    }));
}

test "a task that crashes or is cancelled frees the cycles it made" {
    if (comptime !crash_exit.native) return error.SkipZigTest;
    const crashes = make_cycle ++ [_]Step{.crash};
    try testing.expectEqual(Status.done, try runScript(&.{
        .{ .children = .{ .of = &.{&crashes}, .supervised = true } },
        .{ .expect = 0 },
    }));
    const cancels = make_cycle ++ [_]Step{ .cancel, .{ .children = .{ .of = &.{&.{}} } } };
    try testing.expectEqual(Status.cancelled, try runScript(&.{.{ .children = .{ .of = &.{&cancels} } }}));
}

test "a task that makes cells for as long as it runs holds at most as many dead ones as live ones" {
    const make_many: [1000]Step = @splat(.{ .make = 0 });
    try testing.expectEqual(Status.done, try runScript(&([_]Step{.{ .make = 1 }} ++ make_many ++ [_]Step{.{ .at_most = 10 }})));
    // Four live ones.
    try testing.expectEqual(Status.done, try runScript(&([_]Step{ .{ .make = 1 }, .{ .make = 2 }, .{ .make = 3 } } ++ make_many ++ [_]Step{.{ .at_most = 10 }})));
}

test "a parent's list is swept as its children's cells reach it" {
    // Each child's cell was stored in the parent's, and is dropped from it.
    const child = [_]Step{
        .{ .make = 1 },
        .{ .store = .{ .cell = 0, .index = 0, .from = 1 } },
    };
    const round = [_]Step{.{ .children = .{ .of = &.{&child} } }};
    const rounds: [100]Step = @splat(round[0]);
    try testing.expectEqual(Status.done, try runScript(&([_]Step{.{ .make = 0 }} ++ rounds ++ [_]Step{.{ .at_most = 10 }})));
}

test "a cell made outside any task is freed with its last handle" {
    var env = utils.TestEnv.init(testing.allocator);
    defer env.deinit();
    live_cells = 0;
    const cell = trackedCell(env.getOps());
    task_mod.cellSettle(@ptrCast(cell), true, true);
    drop(cell, env.getOps());
    try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
}

test "in random runs, no task finds a cell that was released, and every cell is freed" {
    var ended: [4]usize = @splat(0);
    for (0..2000) |seed| {
        var env = utils.TestEnv.init(testing.allocator);
        defer env.deinit();
        var memory = std.heap.ArenaAllocator.init(testing.allocator);
        defer memory.deinit();
        arena = memory.allocator();
        var prng = std.Random.DefaultPrng.init(seed);
        var state: State = .{ .records = 0, .steps = &.{}, .random = prng.random(), .steps_left = 40 };
        ended[@backingInt(Host.run(env.getOps(), &state))] += 1;
        try testing.expectEqual(@as(usize, 0), env.getAllocationCount());
    }
    for ([_]Status{ .done, .cancelled }) |status| try testing.expect(ended[@backingInt(status)] > 50);
    if (comptime crash_exit.native) try testing.expect(ended[@backingInt(Status.crashed)] > 50);
}
