//! Tests of the runs of a `None` program that can wait on shared state
//! (design.md "Shared State", "Programs without tasks."). Runs on several
//! threads at once, which update their own cells and crash, must each go as
//! they go alone. `zig build run-test-builtins-tsan` runs this file under
//! ThreadSanitizer too.
//!
//! A run's root opens a loop of entries, each with a script of updates. An
//! update has a threshold: it answers `Wait` while its cell's value is below
//! that, and otherwise stores a new value, keeps it or crashes.

const std = @import("std");
const builtin = @import("builtin");

const crash_exit = @import("task_crash_exit.zig");
const dev_wrappers = @import("dev_wrappers.zig");
const erased_callable = @import("erased_callable.zig");
const task_mod = @import("task.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;
const RocTask = task_mod.RocTask;
const Scheduler = task_mod.Scheduler;

const thread_count = 4;
const max_entries = 6;
const max_steps = 6;
const rounds: u64 = if (builtin.sanitize_thread) 100 else 2000;

const Cell = struct {
    value: i64 = 0,
    empty: bool = false,
};

const Answer = enum(u8) { add, keep, crash, run_inside };

const Step = struct {
    cell: usize,
    threshold: i64,
    answer: Answer,
    amount: i64,
};

const Entry = struct {
    run: *Run = undefined,
    steps: [max_steps]Step = undefined,
    len: usize = 0,
    next: usize = 0,
};

/// One call of the host into the program: what it does, and what came of it.
const Run = struct {
    ops: RocOps = undefined,
    memory: std.heap.ArenaAllocator = undefined,
    live: isize = 0,
    crash_jmp: crash_exit.Buffer = undefined,
    message: [128]u8 = undefined,
    message_len: usize = 0,
    cells: [2]Cell = @splat(.{}),
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    group: ?*task_mod.Group = null,
    /// The entry that took each step, and each arrival as 100 more.
    log: [4 * max_entries * max_steps]u8 = undefined,
    log_len: usize = 0,
    result: u64 = 0,
    finished: bool = false,

    fn note(self: *Run, what: usize) void {
        self.log[self.log_len] = @intCast(what);
        self.log_len += 1;
    }

    fn of(ops: *RocOps) *Run {
        return @ptrCast(@alignCast(ops.env));
    }

    fn alloc(ops: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
        const self = of(ops);
        self.live += 1;
        std.debug.assert(alignment <= 16); // rationale: no task allocation asks for more
        const memory = self.memory.allocator().alignedAlloc(u8, .@"16", @max(length, 1) + 16) catch @trap();
        std.mem.writeInt(usize, memory[0..@sizeOf(usize)], length, builtin.cpu.arch.endian());
        return memory.ptr + 16;
    }

    fn dealloc(ops: *RocOps, _: *anyopaque, _: usize) callconv(.c) void {
        of(ops).live -= 1;
    }

    fn realloc(ops: *RocOps, ptr: *anyopaque, length: usize, alignment: usize) callconv(.c) *anyopaque {
        const old: [*]u8 = @ptrCast(ptr);
        const old_length = std.mem.readInt(usize, (old - 16)[0..@sizeOf(usize)], builtin.cpu.arch.endian());
        const new: [*]u8 = @ptrCast(alloc(ops, length, alignment));
        of(ops).live -= 1;
        @memcpy(new[0..@min(length, old_length)], old[0..@min(length, old_length)]);
        return new;
    }

    fn print(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
        std.debug.print("{s}\n", .{bytes[0..len]});
    }

    /// The host goes on after a crash, outside the program's code.
    fn crashed(ops: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
        const self = of(ops);
        self.message_len = @min(len, self.message.len);
        @memcpy(self.message[0..self.message_len], bytes[0..self.message_len]);
        crash_exit.jump(&self.crash_jmp);
    }

    fn init(self: *Run, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        self.* = .{ .entry_count = 1 + random.uintLessThan(usize, max_entries) };
        self.memory = .init(std.heap.c_allocator);
        self.ops = .{
            .env = self,
            .roc_alloc = alloc,
            .roc_dealloc = dealloc,
            .roc_realloc = realloc,
            .roc_dbg = print,
            .roc_expect_failed = print,
            .roc_crashed = crashed,
            .hosted_fns = .{ .count = 0, .fns = undefined },
        };
        const crashes = seed % 3 == 0;
        for (&self.entries) |*entry| {
            entry.* = .{ .run = self, .len = 1 + random.uintLessThan(usize, max_steps) };
            for (&entry.steps) |*step| step.* = .{
                .cell = random.uintLessThan(usize, self.cells.len),
                .threshold = random.intRangeAtMost(i64, -8, 1),
                .answer = if (crashes and random.uintLessThan(u32, 20) == 0)
                    .crash
                else if (random.uintLessThan(u32, 5) == 0)
                    .keep
                else if (random.uintLessThan(u32, 8) == 0)
                    .run_inside
                else
                    .add,
                .amount = random.intRangeAtMost(i64, -1, 2),
            };
        }
    }

    /// Call the program. A crash leaves `finished` false.
    noinline fn call(self: *Run) void {
        if (crash_exit.save(&self.crash_jmp) != 0) return;
        const start = allocCallable(&self.ops, &rootCall, *Run, self);
        const result = Scheduler.run(&self.ops, start, 8, 8, 8, 8);
        self.result = @as(*align(1) u64, @ptrCast(result)).*;
        Scheduler.runEnd(&self.ops, result, 8, 8);
        self.finished = true;
    }

    fn deinit(self: *Run) void {
        self.memory.deinit();
    }
};

fn noDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {}

fn allocCallable(ops: *RocOps, call: erased_callable.ErasedCallableFn, comptime T: type, capture: T) [*]u8 {
    const built = erased_callable.allocate(call, &noDrop, @sizeOf(T), ops);
    @as(*align(1) T, @ptrCast(erased_callable.capturePtr(built))).* = capture;
    return built;
}

/// A record of `call` on `capture`, in memory from the task.
fn record(task: *RocTask, call: erased_callable.ErasedCallableFn, comptime T: type, capture: T) [*]u8 {
    const size = erased_callable.payloadSize(@sizeOf(T));
    const built = allocCallable(task.ops, call, T, capture);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], built[0..size]);
    utils.freeDataPtrC(built, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    return moved;
}

/// The root: a loop over the entries' results.
fn rootCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const run: *Run = @as(*align(1) const *Run, @ptrCast(capture.?)).*;
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    if (run.group == null) {
        var starts: [max_entries][*]u8 = undefined;
        var marks: [max_entries]task_mod.EntryMarks = undefined;
        for (starts[0..run.entry_count], marks[0..run.entry_count], run.entries[0..run.entry_count]) |*start, *mark, *entry| {
            start.* = allocCallable(ops, &entryCall, *Entry, entry);
            mark.* = .{ .limit_path = &.{}, .shielded = false, .background = false };
        }
        run.group = task_mod.groupCreate(task, .{
            .starts = starts[0..run.entry_count],
            .marks = marks[0..run.entry_count],
            .limits = &.{},
            .root_limit = null,
            .slot_size = 8,
            .slot_alignment = 8,
            .result_drop = null,
            .result_drop_context = null,
        });
    }
    while (true) switch (task_mod.groupNext(run.group.?)) {
        .arrived => |arrival| run.note(100 + arrival.index),
        .ended => {
            task_mod.groupFree(run.group.?);
            @as(*align(1) u64, @ptrCast(ret.?)).* = 7;
            return;
        },
        .pending => {
            task.pushRecord(record(task, &rootCall, *Run, run), null);
            task.setPending();
            return;
        },
        .crashed => unreachable, // rationale: only a supervised group reports a crash
    };
}

const Probed = extern struct { cell: *Cell, threshold: i64, crashes: bool };

/// `cell_probe!`: 0 for `Wait`, 1 for another answer.
fn probeCall(ops: *RocOps, ret: ?[*]u8, _: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const probed = @as(*align(1) const Probed, @ptrCast(capture.?)).*;
    const waits = probed.cell.value < probed.threshold;
    if (!waits and probed.crashes) ops.crash("an update crashed");
    ret.?[0] = @intFromBool(!waits);
}

fn entryCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const entry: *Entry = @as(*align(1) const *Entry, @ptrCast(capture.?)).*;
    const run = entry.run;
    const index = (@intFromPtr(entry) - @intFromPtr(&run.entries)) / @sizeOf(Entry);
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    while (entry.next < entry.len) {
        const step = entry.steps[entry.next];
        const cell = &run.cells[step.cell];
        if (cell.empty) ops.crash("this cell was poisoned");
        cell.empty = true;
        if (cell.value < step.threshold) {
            cell.empty = false;
            const probe = allocCallable(ops, &probeCall, Probed, .{ .cell = cell, .threshold = step.threshold, .crashes = step.answer == .crash });
            std.debug.assert(dev_wrappers.roc_builtins_cell_wait(cell, probe, task) == 2); // rationale: the park status is fixed
            task.pushRecord(record(task, &entryCall, *Entry, entry), null);
            task.setPending();
            return;
        }
        if (step.answer == .crash) ops.crash("an update crashed");
        if (step.answer != .keep) cell.value += step.amount;
        cell.empty = false;
        dev_wrappers.roc_builtins_cell_settle(cell, step.answer != .keep, false);
        run.note(index);
        entry.next += 1;
        // A hosted call that calls back into the program.
        if (step.answer == .run_inside) runInside(ops, run);
    }
    @as(*align(1) u64, @ptrCast(ret.?)).* = index;
}

fn runInside(ops: *RocOps, outer: *Run) void {
    var inner: Run = .{ .entry_count = 2 };
    for (inner.entries[0..2]) |*entry| entry.* = .{ .run = &inner, .len = 1 };
    inner.entries[0].steps[0] = .{ .cell = 0, .threshold = 1, .answer = .add, .amount = 5 };
    inner.entries[1].steps[0] = .{ .cell = 0, .threshold = 0, .answer = .add, .amount = 1 };
    const result = Scheduler.run(ops, allocCallable(ops, &rootCall, *Run, &inner), 8, 8, 8, 8);
    Scheduler.runEnd(ops, result, 8, 8);
    // The second entry stores what the first waits for.
    if (!std.mem.eql(u8, inner.log[0..inner.log_len], &.{ 1, 101, 0, 100 }) and
        !std.mem.eql(u8, inner.log[0..inner.log_len], &.{ 1, 0, 100, 101 })) ops.crash("the inner run went wrong");
    outer.note(200);
}

const testing = std.testing;

fn runOn(run: *Run, seed: u64) void {
    run.init(seed);
    run.call();
}

fn expectSame(alone: *Run, beside: *Run) error{TestExpectedEqual}!void {
    try testing.expectEqualStrings(alone.message[0..alone.message_len], beside.message[0..beside.message_len]);
    try testing.expectEqual(alone.finished, beside.finished);
    try testing.expectEqual(alone.result, beside.result);
    try testing.expectEqualSlices(u8, alone.log[0..alone.log_len], beside.log[0..beside.log_len]);
}

test "runs on several threads, some of which crash, go as each goes alone" {
    if (!crash_exit.native) return error.SkipZigTest;
    var ended: usize = 0;
    var deadlocked: usize = 0;
    var crashed: usize = 0;
    for (0..rounds / thread_count) |round| {
        var alone: [thread_count]Run = undefined;
        for (&alone, 0..) |*run, i| {
            runOn(run, round * thread_count + i);
            try testing.expect(!task_mod.anyWaiter());
            if (run.finished) {
                try testing.expectEqual(@as(isize, 0), run.live);
                try testing.expectEqual(@as(u64, 7), run.result);
                ended += 1;
            } else if (std.mem.eql(u8, run.message[0..run.message_len], task_mod.deadlock)) {
                deadlocked += 1;
            } else {
                try testing.expectEqualStrings("an update crashed", run.message[0..run.message_len]);
                crashed += 1;
            }
        }
        var beside: [thread_count]Run = undefined;
        var threads: [thread_count]std.Thread = undefined;
        for (&threads, &beside, 0..) |*thread, *run, i| thread.* = try std.Thread.spawn(.{}, runOn, .{ run, round * thread_count + i });
        for (threads) |thread| thread.join();
        try testing.expect(!task_mod.anyWaiter());
        for (&alone, &beside) |*first, *second| {
            try expectSame(first, second);
            first.deinit();
            second.deinit();
        }
    }
    // The seeds cover each way a run ends.
    const least = rounds / 50;
    try testing.expect(ended > least and deadlocked > least and crashed > least);
}

test "a run's result comes from memory that runEnd frees, none of it for a result with no size" {
    var run: Run = undefined;
    run.init(1);
    defer run.deinit();
    run.entry_count = 0;
    const result = Scheduler.run(&run.ops, allocCallable(&run.ops, &rootCall, *Run, &run), 8, 8, 8, 8);
    try testing.expectEqual(@as(u64, 7), @as(*align(1) u64, @ptrCast(result)).*);
    try testing.expectEqual(@as(isize, 1), run.live);
    Scheduler.runEnd(&run.ops, result, 8, 8);
    try testing.expectEqual(@as(isize, 0), run.live);
    const empty = Scheduler.run(&run.ops, allocCallable(&run.ops, &emptyCall, *Run, &run), 0, 1, 0, 1);
    try testing.expectEqual(@as(isize, 0), run.live);
    Scheduler.runEnd(&run.ops, empty, 0, 1);
    try testing.expectEqual(@as(isize, 0), run.live);
}

fn emptyCall(_: *RocOps, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {}
