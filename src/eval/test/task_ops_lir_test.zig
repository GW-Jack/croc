//! LIR-level tests for the task operations (design.md "Records And The
//! Task"), run through the interpreter on hand-built LIR against a
//! `RocTask`.

const std = @import("std");
const base = @import("base");
const builtins = @import("builtins");
const eval = @import("eval");
const layout = @import("layout");
const lir = @import("lir");
const RuntimeHostEnv = eval.RuntimeHostEnv;

const Allocator = std.mem.Allocator;
const LIR = lir.LIR;
const LirStore = lir.LirStore;
const LocalId = LIR.LocalId;
const CFStmtId = LIR.CFStmtId;
const LowLevel = lir.LowLevel;
const RocTask = builtins.task.RocTask;

/// The errors these tests' helpers return.
pub const TaskOpsTestError = Allocator.Error || eval.Interpreter.Error || RuntimeHostEnv.LeakError || error{
    TestExpectedEqual,
    TestUnexpectedResult,
};

/// A LIR store and layouts to build a program in, and the runtime host
/// whose allocations the tests check for leaks.
pub const Fixture = struct {
    allocator: Allocator,
    store: LirStore,
    layouts: layout.Store,
    runtime_env: RuntimeHostEnv,
    locals: std.ArrayList(LocalId) = .empty,

    /// An empty program for this process's pointer width.
    pub fn init(allocator: Allocator) TaskOpsTestError!Fixture {
        return initFor(allocator, base.target.TargetUsize.native);
    }

    /// An empty program whose layouts are for a target with `target_usize`
    /// pointers, such as wasm32's.
    pub fn initFor(allocator: Allocator, target_usize: base.target.TargetUsize) TaskOpsTestError!Fixture {
        var store = LirStore.init(allocator);
        errdefer store.deinit();
        return .{
            .allocator = allocator,
            .store = store,
            .layouts = try layout.Store.init(allocator, target_usize),
            .runtime_env = RuntimeHostEnv.init(allocator),
        };
    }

    /// Release the program and the runtime host.
    pub fn deinit(self: *Fixture) void {
        self.locals.deinit(self.allocator);
        self.runtime_env.deinit();
        self.layouts.deinit();
        self.store.deinit();
    }

    fn local(self: *Fixture, layout_idx: layout.Idx) TaskOpsTestError!LocalId {
        const id = try self.store.addLocal(.{ .layout_idx = layout_idx });
        try self.locals.append(self.allocator, id);
        return id;
    }

    fn op(self: *Fixture, target: LocalId, low_level: LowLevel, args: []const LocalId, next: CFStmtId) TaskOpsTestError!CFStmtId {
        return try self.store.addCFStmt(.{ .assign_low_level = .{
            .target = target,
            .op = low_level,
            .rc_effect = try self.store.addRcEffect(low_level.rcEffect()),
            .args = try self.store.addLocalSpan(args),
            .next = next,
        } }, .test_fixture);
    }

    fn ret(self: *Fixture, value: LocalId) TaskOpsTestError!CFStmtId {
        return try self.store.addCFStmt(.{ .ret = .{ .value = value } }, .test_fixture);
    }

    /// Run a procedure of one task argument, returning its `ret_layout`
    /// result's first `T`.
    fn run(self: *Fixture, comptime T: type, task_arg: LocalId, body: CFStmtId, ret_layout: layout.Idx, task: *RocTask) TaskOpsTestError!T {
        const proc = try self.store.addProcSpec(.{
            .name = self.store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.programLocal("task-ops-test", self.store.next_synthetic_symbol),
            .args = try self.store.addLocalSpan(&.{task_arg}),
            .frame_locals = try self.store.addLocalSpan(self.locals.items),
            .body = .some(body),
            .ret_layout = ret_layout,
        }, .none);
        var static_strings = try eval.Interpreter.buildStaticStrings(self.allocator, &self.store);
        defer static_strings.deinit();
        var interp = try eval.Interpreter.init(self.allocator, &self.store, &self.layouts, static_strings.view(), self.runtime_env.get_ops());
        defer interp.deinit();
        var address: usize = @intFromPtr(task);
        const result = try interp.eval(.{
            .proc_id = proc,
            .arg_layouts = &.{.opaque_ptr},
            .arg_ptr = @ptrCast(&address),
        });
        return result.value.read(T);
    }
};

/// The host's `roc_task_ready` for a test that resumes the task itself
/// right after waking it.
pub fn readyTask(_: *RocTask) callconv(.c) void {}

/// A task with the fields the operations read and nothing the runtime uses:
/// these tests run no records.
fn bareTask(hosted_slot: [*]u8, result_buffer: [*]u8) RocTask {
    return .{
        .pending = 0,
        .hosted_slot = hosted_slot,
        .result_buffer = result_buffer,
        .wake_word = 0,
        .started = false,
        .cancel_requested = false,
        .aborted = false,
        .ready_fn = null,
        .abort_fn = null,
        .status = .pending,
        .root_result = undefined,
        .entries = undefined,
        .len = 0,
        .capacity = 0,
        .hosted_slot_size = 0,
        .hosted_slot_alignment = 1,
        .result_buffer_size = 0,
        .result_buffer_alignment = 1,
        .ops = undefined,
        .crash_jmp = undefined,
        .running_record = undefined,
        .crash_message = undefined,
        .crash_message_len = 0,
        .running_from_task = false,
        .record_cache = @splat(null),
        .group = null,
        .entry_index = 0,
        .tree_index = 0,
        .child_counter = 0,
        .wait = null,
        .open_groups = null,
        .finishing = false,
        .crashing = false,
    };
}

test "task_ready reads the pending flag and task_set_pending sets it" {
    var slot: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var task = bareTask(&slot, &buffer);
    for ([_]bool{ false, true }) |set_first| {
        var f = try Fixture.init(std.testing.allocator);
        defer f.deinit();
        // [task_set_pending(task);] ret task_ready(task)
        const task_arg = try f.local(.opaque_ptr);
        const ready = try f.local(.bool);
        const unit = try f.local(.zst);
        const ret = try f.ret(ready);
        const read = try f.op(ready, .task_ready, &.{task_arg}, ret);
        const body = if (set_first) try f.op(unit, .task_set_pending, &.{task_arg}, read) else read;

        try std.testing.expectEqual(@as(u8, if (set_first) 0 else 1), try f.run(u8, task_arg, body, .bool, &task));
        try std.testing.expectEqual(set_first, !task.ready());
        try f.runtime_env.checkForLeaks();
    }
}

test "task_hosted_slot and task_result_buffer address the task's buffers" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    var slot: u64 = 77;
    var buffer: u64 = 0;
    var task = bareTask(@ptrCast(&slot), @ptrCast(&buffer));
    const ptr_u64 = try f.layouts.insertPtr(.u64);

    // buffer.* = slot.* + 1; ret slot.*
    const task_arg = try f.local(.opaque_ptr);
    const slot_ptr = try f.local(ptr_u64);
    const buffer_ptr = try f.local(ptr_u64);
    const value = try f.local(.u64);
    const one = try f.local(.u64);
    const next = try f.local(.u64);
    const unit = try f.local(.zst);
    const ret = try f.ret(value);
    const write = try f.op(unit, .ptr_store, &.{ buffer_ptr, next }, ret);
    const add = try f.op(next, .num_int_add_wrap, &.{ value, one }, write);
    const lit = try f.store.addCFStmt(.{ .assign_literal = .{
        .target = one,
        .value = .{ .i64_literal = .{ .value = 1, .layout_idx = .u64 } },
        .next = add,
    } }, .test_fixture);
    const load = try f.op(value, .ptr_load, &.{slot_ptr}, lit);
    const get_buffer = try f.op(buffer_ptr, .task_result_buffer, &.{task_arg}, load);
    const get_slot = try f.op(slot_ptr, .task_hosted_slot, &.{task_arg}, get_buffer);

    try std.testing.expectEqual(@as(u64, 77), try f.run(u64, task_arg, get_slot, .u64, &task));
    try std.testing.expectEqual(@as(u64, 78), buffer);
    try f.runtime_env.checkForLeaks();
}

/// What the test host saw at its one suspending hosted call.
const PausingHost = struct {
    calls: u32 = 0,
    task: ?*RocTask = null,
    slot: ?[*]u8 = null,
    x: u64 = 0,

    fn dispatch(context: *anyopaque, call: eval.Interpreter.HostedCall) eval.Interpreter.Error!void {
        const self: *PausingHost = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.task = @ptrFromInt(std.mem.readInt(usize, call.args[call.arg_offsets[0]..][0..@sizeOf(usize)], .little));
        self.slot = @ptrFromInt(std.mem.readInt(usize, call.args[call.arg_offsets[1]..][0..@sizeOf(usize)], .little));
        self.x = std.mem.readInt(u64, call.args[call.arg_offsets[2]..][0..8], .little);
        // Pending: the host writes the slot and wakes the task later.
        std.mem.writeInt(u32, call.ret[0..4], 1, .little);
    }
};

/// A program whose task pauses at a suspending hosted call `h(x)` with a
/// result of `hosted_ret`, after the continuation pass: the provides root
/// `g(x) = t = h(x); ret (if add then t + x else x)`. Returns the task entry
/// that takes `g`'s place among the roots.
pub fn pausingProgram(f: *Fixture, hosted_ret: layout.Idx, add: bool) TaskOpsTestError!LIR.LirProcSpecId {
    const allocator = f.allocator;
    const h_arg = try f.store.addLocal(.{ .layout_idx = .u64 });
    const h = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{h_arg}),
        .ret_layout = hosted_ret,
        .hosted = .some(.{ .symbol = try f.store.insertString("roc_test_pause"), .dispatch_index = 0 }),
        .suspends = .may,
    }, .none);
    const x = try f.store.addLocal(.{ .layout_idx = .u64 });
    const t = try f.store.addLocal(.{ .layout_idx = hosted_ret });
    const r = try f.store.addLocal(.{ .layout_idx = .u64 });
    const after = if (add) try f.op(r, .num_int_add_wrap, &.{ t, x }, try f.ret(r)) else try f.ret(x);
    const site = try f.store.addCFStmt(.{ .assign_call = .{
        .target = t,
        .proc = h,
        .args = try f.store.addLocalSpan(&.{x}),
        .next = after,
    } }, .test_fixture);
    const g = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{x}),
        .frame_locals = try f.store.addLocalSpan(&.{ x, t, r }),
        .body = .some(site),
        .ret_layout = .u64,
    }, .none);
    try lir.SuspensionMarks.run(allocator, &f.store);
    var roots = [_]LIR.LirProcSpecId{g};
    try lir.ContinuationPass.run(allocator, &f.store, &f.layouts, .{ .procs = &roots, .provided = &.{true} });
    return roots[0];
}

/// A program whose task pauses twice at the suspending hosted call `h` of a
/// `U64` result, after the continuation pass: the provides root
/// `g(x) = t = h(x); u = h(t); ret u + x`. Its second pause is inside the
/// resume entry of the first. Returns the task entry that takes `g`'s place
/// among the roots.
pub fn pausingTwiceProgram(f: *Fixture) TaskOpsTestError!LIR.LirProcSpecId {
    const allocator = f.allocator;
    const h_arg = try f.store.addLocal(.{ .layout_idx = .u64 });
    const h = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{h_arg}),
        .ret_layout = .u64,
        .hosted = .some(.{ .symbol = try f.store.insertString("roc_test_pause"), .dispatch_index = 0 }),
        .suspends = .may,
    }, .none);
    const x = try f.store.addLocal(.{ .layout_idx = .u64 });
    const t = try f.store.addLocal(.{ .layout_idx = .u64 });
    const u = try f.store.addLocal(.{ .layout_idx = .u64 });
    const r = try f.store.addLocal(.{ .layout_idx = .u64 });
    const second = try f.store.addCFStmt(.{ .assign_call = .{
        .target = u,
        .proc = h,
        .args = try f.store.addLocalSpan(&.{t}),
        .next = try f.op(r, .num_int_add_wrap, &.{ u, x }, try f.ret(r)),
    } }, .test_fixture);
    const first = try f.store.addCFStmt(.{ .assign_call = .{
        .target = t,
        .proc = h,
        .args = try f.store.addLocalSpan(&.{x}),
        .next = second,
    } }, .test_fixture);
    const g = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{x}),
        .frame_locals = try f.store.addLocalSpan(&.{ x, t, u, r }),
        .body = .some(first),
        .ret_layout = .u64,
    }, .none);
    try lir.SuspensionMarks.run(allocator, &f.store);
    var roots = [_]LIR.LirProcSpecId{g};
    try lir.ContinuationPass.run(allocator, &f.store, &f.layouts, .{ .procs = &roots, .provided = &.{true} });
    return roots[0];
}

/// A program whose task pauses inside a procedure it calls, after the
/// continuation pass: the provides root `g(x) = t = k(x); ret t + x` over
/// `k(y) = s = h(y); ret s`, with `h` the suspending hosted call of a `U64`
/// result. A hosted site is never a tail site, so `k` saves its record at
/// `h`, and `g`'s call of `k` is a procedure site: `g` tests `task_ready`
/// after `k` returns and saves its own record when `k` paused. Returns the
/// task entry that takes `g`'s place among the roots.
pub fn pausingNestedProgram(f: *Fixture) TaskOpsTestError!LIR.LirProcSpecId {
    const allocator = f.allocator;
    const h_arg = try f.store.addLocal(.{ .layout_idx = .u64 });
    const h = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{h_arg}),
        .ret_layout = .u64,
        .hosted = .some(.{ .symbol = try f.store.insertString("roc_test_pause"), .dispatch_index = 0 }),
        .suspends = .may,
    }, .none);
    const y = try f.store.addLocal(.{ .layout_idx = .u64 });
    const s = try f.store.addLocal(.{ .layout_idx = .u64 });
    const k = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{y}),
        .frame_locals = try f.store.addLocalSpan(&.{ y, s }),
        .body = .some(try f.store.addCFStmt(.{ .assign_call = .{
            .target = s,
            .proc = h,
            .args = try f.store.addLocalSpan(&.{y}),
            .next = try f.ret(s),
        } }, .test_fixture)),
        .ret_layout = .u64,
    }, .none);
    const x = try f.store.addLocal(.{ .layout_idx = .u64 });
    const t = try f.store.addLocal(.{ .layout_idx = .u64 });
    const r = try f.store.addLocal(.{ .layout_idx = .u64 });
    const g = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{x}),
        .frame_locals = try f.store.addLocalSpan(&.{ x, t, r }),
        .body = .some(try f.store.addCFStmt(.{ .assign_call = .{
            .target = t,
            .proc = k,
            .args = try f.store.addLocalSpan(&.{x}),
            .next = try f.op(r, .num_int_add_wrap, &.{ t, x }, try f.ret(r)),
        } }, .test_fixture)),
        .ret_layout = .u64,
    }, .none);
    try lir.SuspensionMarks.run(allocator, &f.store);
    var roots = [_]LIR.LirProcSpecId{g};
    try lir.ContinuationPass.run(allocator, &f.store, &f.layouts, .{ .procs = &roots, .provided = &.{true} });
    return roots[0];
}

/// An interpreter for `f`'s program whose hosted calls go to `host`, kept
/// alive while its records are.
const PausingRun = struct {
    static_strings: eval.Interpreter.StaticStrings.Table,
    interp: eval.Interpreter,

    fn init(self: *PausingRun, f: *Fixture, host: *PausingHost) TaskOpsTestError!void {
        self.static_strings = try eval.Interpreter.buildStaticStrings(f.allocator, &f.store);
        errdefer self.static_strings.deinit();
        self.interp = try eval.Interpreter.init(f.allocator, &f.store, &f.layouts, self.static_strings.view(), f.runtime_env.get_ops());
        self.interp.hosted_call_handler = .{ .context = host, .dispatch = PausingHost.dispatch };
    }

    fn deinit(self: *PausingRun) void {
        self.interp.deinit();
        self.static_strings.deinit();
    }

    /// Call the task entry as the host calls a provides entry, with 20 and
    /// the root result's address, and return the task it creates.
    fn start(self: *PausingRun, entry: LIR.LirProcSpecId, root: [*]u8) TaskOpsTestError!*RocTask {
        const Args = extern struct { x: u64, result_out: usize };
        var args = Args{ .x = 20, .result_out = @intFromPtr(root) };
        const created = try self.interp.eval(.{
            .proc_id = entry,
            .arg_layouts = &.{ .u64, .opaque_ptr },
            .arg_ptr = @ptrCast(&args),
        });
        return @ptrFromInt(created.value.read(usize));
    }
};

test "a task paused at a hosted call resumes from its record and returns the root result" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingProgram(&f, .u64, true);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));

    // The first run reaches the hosted call, which is pending: the task
    // parks with g's record saved.
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());
    try std.testing.expectEqual(@as(u32, 1), host.calls);
    try std.testing.expectEqual(task, host.task.?);
    try std.testing.expectEqual(@as(u64, 20), host.x);
    try std.testing.expectEqual(@as(usize, 1), task.len);

    // The host finishes: it writes the result and wakes the task, which
    // resumes in g's continuation with x restored from the record.
    @as(*align(1) u64, @ptrCast(host.slot.?)).* = 22;
    task.wake(&readyTask);
    try std.testing.expectEqual(builtins.task.Status.done, task.resumeTask());
    try std.testing.expectEqual(@as(u64, 42), root);
    try std.testing.expectEqual(@as(u32, 1), host.calls);
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "a task paused inside a called procedure resumes in its caller's continuation" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingNestedProgram(&f);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));

    // k saves its record at the hosted call; g sees the pending flag after
    // k returns and saves its own record.
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());
    try std.testing.expectEqual(@as(u32, 1), host.calls);
    try std.testing.expectEqual(@as(u64, 20), host.x);
    try std.testing.expectEqual(@as(usize, 2), task.len);

    @as(*align(1) u64, @ptrCast(host.slot.?)).* = 22;
    task.wake(&readyTask);
    try std.testing.expectEqual(builtins.task.Status.done, task.resumeTask());
    try std.testing.expectEqual(@as(u64, 42), root);
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "cancelling a woken task releases the hosted result in its slot and its records" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingProgram(&f, .str, false);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());

    // The host writes a heap string and wakes the task, which is then
    // cancelled instead of resumed: the record's slot release frees the
    // string, and no abort runs.
    const text = builtins.str.RocStr.fromSlice("a string too long to be small", f.runtime_env.get_ops());
    try std.testing.expect(!text.isSmallStr());
    @as(*align(1) builtins.str.RocStr, @ptrCast(host.slot.?)).* = text;
    task.wake(&readyTask);
    task.cancel(&abortUnexpected, &readyTask);
    try std.testing.expectEqual(builtins.task.Status.cancelled, task.resumeTask());
    task.free();
    try f.runtime_env.checkForLeaks();
}

test "cancelling a task the host has not finished aborts the host call and releases its records" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try pausingProgram(&f, .str, false);
    var host = PausingHost{};
    var run: PausingRun = undefined;
    try run.init(&f, &host);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.start(entry, @ptrCast(&root));
    try std.testing.expectEqual(builtins.task.Status.pending, task.resumeTask());

    aborted = null;
    task.cancel(&abortRecord, &readyTask);
    try std.testing.expectEqual(task, aborted.?);
    try std.testing.expectEqual(builtins.task.Status.cancelled, task.resumeTask());
    task.free();
    try f.runtime_env.checkForLeaks();
}

/// The task the last `abortRecord` call aborted.
pub var aborted: ?*RocTask = null;

/// A host's abort callback that records the task it was given.
pub fn abortRecord(task: *RocTask) callconv(.c) void {
    aborted = task;
}

/// A host's abort callback for a cancel that must not abort a host call.
pub fn abortUnexpected(_: *RocTask) callconv(.c) void {
    std.debug.panic("a woken task's cancel aborted the host call", .{});
}

/// Tasks the running-set test's `roc_task_ready` was handed, in order.
const ReadyChildren = struct {
    var tasks: [8]*RocTask = undefined;
    var len: usize = 0;

    fn ready(task: *RocTask) callconv(.c) void {
        tasks[len] = task;
        len += 1;
    }

    fn abort(_: *RocTask) callconv(.c) void {}
};

/// An entry's start procedure, as the continuation pass makes one: an
/// erased callable of the task that returns `result`.
fn constantStart(f: *Fixture, result: i64) TaskOpsTestError!LIR.LirProcSpecId {
    const erased = try f.layouts.insertErasedCallable();
    const task = try f.store.addLocal(.{ .layout_idx = .opaque_ptr });
    const capture = try f.store.addLocal(.{ .layout_idx = .opaque_ptr });
    const reuse = try f.store.addLocal(.{ .layout_idx = erased });
    const value = try f.store.addLocal(.{ .layout_idx = .u64 });
    const body = try f.store.addCFStmt(.{ .assign_literal = .{
        .target = value,
        .value = .{ .i64_literal = .{ .value = result, .layout_idx = .u64 } },
        .next = try f.ret(value),
    } }, .test_fixture);
    return try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{ task, capture, reuse }),
        .frame_locals = try f.store.addLocalSpan(&.{ task, capture, reuse, value }),
        .body = .some(body),
        .ret_layout = .u64,
        .abi = .erased_callable,
        .erased_capture_arg = .some(capture),
        .erased_reuse_arg = .some(reuse),
        .erased_call_args = .some(try f.store.internErasedCallArgsPlan(&f.layouts, &.{.opaque_ptr})),
    }, .none);
}

/// A procedure of the one argument `arg`, with `body`.
fn unaryProc(f: *Fixture, arg: LocalId, body: CFStmtId, ret_layout: layout.Idx) TaskOpsTestError!LIR.LirProcSpecId {
    const proc = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = try f.store.addLocalSpan(&.{arg}),
        .frame_locals = try f.store.addLocalSpan(f.locals.items),
        .body = .some(body),
        .ret_layout = ret_layout,
    }, .none);
    f.locals.clearRetainingCapacity();
    return proc;
}

fn literal(f: *Fixture, target: LocalId, value: i64, layout_idx: layout.Idx, next: CFStmtId) TaskOpsTestError!CFStmtId {
    return try f.store.addCFStmt(.{ .assign_literal = .{
        .target = target,
        .value = .{ .i64_literal = .{ .value = value, .layout_idx = layout_idx } },
        .next = next,
    } }, .test_fixture);
}

/// The loop id the running-set tests' loops name their sets by.
const test_loop_id: i64 = 3;

/// `group_init(id, count, [], 0, task)` for a set of `count` entries with
/// results of `result`, before `next`; `id`, `limits` and `no_limit` are
/// the caller's locals, which this defines.
fn groupInit(f: *Fixture, id: LocalId, count: i64, result: layout.Idx, task: ?LocalId, next: CFStmtId) TaskOpsTestError!CFStmtId {
    const count_local = try f.local(.u64);
    const no_limit = try f.local(.u64);
    const limits = try f.local(try f.layouts.insertList(.u64));
    const unit = try f.local(.zst);
    var args = std.ArrayList(LocalId).empty;
    defer args.deinit(f.allocator);
    try args.appendSlice(f.allocator, &.{ id, count_local, limits, no_limit });
    if (task) |owner| try args.append(f.allocator, owner);
    var head = try f.store.addCFStmt(.{ .assign_low_level = .{
        .target = unit,
        .op = .group_init,
        .rc_effect = try f.store.addRcEffect(LowLevel.group_init.rcEffect()),
        .extra = try f.store.addStmtRow(LIR.LowLevelExtra, .{ .group_result = .some(result) }),
        .args = try f.store.addLocalSpan(args.items),
        .next = next,
    } }, .test_fixture);
    head = try f.store.addCFStmt(.{ .assign_list = .{ .target = limits, .elems = .empty(), .next = head } }, .test_fixture);
    head = try literal(f, no_limit, 0, .u64, head);
    head = try literal(f, count_local, count, .u64, head);
    return try literal(f, id, test_loop_id, .u64, head);
}

/// Pack each of `starts` into `start_locals`, an erased callable with no
/// capture, before `next`.
fn packStarts(f: *Fixture, starts: []const LIR.LirProcSpecId, start_locals: []const LocalId, next: CFStmtId) TaskOpsTestError!CFStmtId {
    var head = next;
    var index = starts.len;
    while (index > 0) {
        index -= 1;
        head = try f.store.addCFStmt(.{ .assign_packed_erased_fn = .{
            .target = start_locals[index],
            .data = try f.store.addStmtRow(LIR.PackedErasedFnData, .{
                .proc = starts[index],
                .capture = .none,
                .capture_layout = .none,
                .on_drop = .none,
            }),
            .next = head,
        } }, .test_fixture);
    }
    return head;
}

test "the running-set operations run each entry as a child task and move its result out of its slot" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const erased = try f.layouts.insertErasedCallable();
    const list_u64 = try f.layouts.insertList(.u64);
    const ptr_u64 = try f.layouts.insertPtr(.u64);
    const starts = [_]LIR.LirProcSpecId{ try constantStart(&f, 5), try constantStart(&f, 7) };

    // make(task): group_init(3, 2, [], 0, task); push each entry under no
    // limit; group_start(3, task)
    const make = blk: {
        const task = try f.local(.opaque_ptr);
        const id = try f.local(.u64);
        const path = try f.local(list_u64);
        const no = try f.local(.bool);
        const unit = try f.local(.zst);
        var start_locals: [2]LocalId = undefined;
        for (&start_locals) |*start| start.* = try f.local(erased);
        var head = try f.op(unit, .group_start, &.{ id, task }, try f.ret(unit));
        var index: usize = start_locals.len;
        while (index > 0) {
            index -= 1;
            head = try f.op(unit, .group_push, &.{ id, start_locals[index], path, no, no, task }, head);
        }
        head = try f.store.addCFStmt(.{ .assign_list = .{ .target = path, .elems = .empty(), .next = head } }, .test_fixture);
        head = try literal(&f, no, 0, .bool, head);
        head = try groupInit(&f, id, 2, .u64, task, head);
        break :blk try unaryProc(&f, task, try packStarts(&f, &starts, &start_locals, head), .zst);
    };
    // take(task): group_next(3, task) must be 0; ret ptr_load(group_arrival(3, task))
    const take = blk: {
        const task = try f.local(.opaque_ptr);
        const id = try f.local(.u64);
        const status = try f.local(.u32);
        const slot = try f.local(ptr_u64);
        const value = try f.local(.u64);
        const load = try f.op(value, .ptr_load, &.{slot}, try f.ret(value));
        const arrival = try f.op(slot, .group_arrival, &.{ id, task }, load);
        const body = try literal(&f, id, test_loop_id, .u64, try f.op(status, .group_next, &.{ id, task }, arrival));
        break :blk try unaryProc(&f, task, body, .u64);
    };
    // next(task): ret group_next(3, task)
    const next = blk: {
        const task = try f.local(.opaque_ptr);
        const id = try f.local(.u64);
        const status = try f.local(.u32);
        const body = try literal(&f, id, test_loop_id, .u64, try f.op(status, .group_next, &.{ id, task }, try f.ret(status)));
        break :blk try unaryProc(&f, task, body, .u32);
    };
    // free(task): group_free(3, task); ret {}
    const free = blk: {
        const task = try f.local(.opaque_ptr);
        const id = try f.local(.u64);
        const unit = try f.local(.zst);
        const body = try literal(&f, id, test_loop_id, .u64, try f.op(unit, .group_free, &.{ id, task }, try f.ret(unit)));
        break :blk try unaryProc(&f, task, body, .zst);
    };

    var static_strings = try eval.Interpreter.buildStaticStrings(f.allocator, &f.store);
    defer static_strings.deinit();
    var interp = try eval.Interpreter.init(f.allocator, &f.store, &f.layouts, static_strings.view(), f.runtime_env.get_ops());
    defer interp.deinit();

    var slot: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var owner = bareTask(&slot, &buffer);
    owner.ops = f.runtime_env.get_ops();
    owner.ready_fn = &ReadyChildren.ready;
    owner.abort_fn = &ReadyChildren.abort;
    ReadyChildren.len = 0;
    var address = @intFromPtr(&owner);
    const call = struct {
        fn call(i: *eval.Interpreter, proc: LIR.LirProcSpecId, task: *usize) TaskOpsTestError!eval.Interpreter.EvalResult {
            return try i.eval(.{ .proc_id = proc, .arg_layouts = &.{.opaque_ptr}, .arg_ptr = @ptrCast(task) });
        }
    }.call;

    // Both entries start as children, readied in input order.
    _ = try call(&interp, make, &address);
    try std.testing.expectEqual(@as(usize, 2), ReadyChildren.len);
    try std.testing.expectEqual(@as(u32, 2), (try call(&interp, next, &address)).value.read(u32));

    // The host resumes the second child first, so its result arrives first.
    for ([_]usize{ 1, 0 }) |index| {
        const child = ReadyChildren.tasks[index];
        try std.testing.expectEqual(builtins.task.Status.done, child.resumeFromHost(&ReadyChildren.ready, &ReadyChildren.abort));
    }
    try std.testing.expectEqual(@as(u64, 7), (try call(&interp, take, &address)).value.read(u64));
    try std.testing.expectEqual(@as(u64, 5), (try call(&interp, take, &address)).value.read(u64));
    try std.testing.expectEqual(@as(u32, 1), (try call(&interp, next, &address)).value.read(u32));
    _ = try call(&interp, free, &address);
    try f.runtime_env.checkForLeaks();
}

test "a running set of heap results drops one through the interpreter and releases its drop at close" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();

    // make(task): group_init(3, 0, [], 0, task) with Str results; group_start(3, task)
    const make = blk: {
        const task = try f.local(.opaque_ptr);
        const id = try f.local(.u64);
        const unit = try f.local(.zst);
        const head = try groupInit(&f, id, 0, .str, task, try f.op(unit, .group_start, &.{ id, task }, try f.ret(unit)));
        break :blk try unaryProc(&f, task, head, .zst);
    };
    // finish(task): s = group_next(3, task); group_free(3, task); ret s
    const finish = blk: {
        const task = try f.local(.opaque_ptr);
        const id = try f.local(.u64);
        const status = try f.local(.u32);
        const unit = try f.local(.zst);
        const free = try f.op(unit, .group_free, &.{ id, task }, try f.ret(status));
        const body = try literal(&f, id, test_loop_id, .u64, try f.op(status, .group_next, &.{ id, task }, free));
        break :blk try unaryProc(&f, task, body, .u32);
    };

    var static_strings = try eval.Interpreter.buildStaticStrings(f.allocator, &f.store);
    defer static_strings.deinit();
    var interp = try eval.Interpreter.init(f.allocator, &f.store, &f.layouts, static_strings.view(), f.runtime_env.get_ops());
    defer interp.deinit();

    var slot: [8]u8 = undefined;
    var buffer: [8]u8 = undefined;
    var owner = bareTask(&slot, &buffer);
    owner.ops = f.runtime_env.get_ops();
    owner.ready_fn = &ReadyChildren.ready;
    owner.abort_fn = &ReadyChildren.abort;

    var address = @intFromPtr(&owner);
    _ = try interp.eval(.{ .proc_id = make, .arg_layouts = &.{.opaque_ptr}, .arg_ptr = @ptrCast(&address) });
    const group = builtins.task.openGroup(&owner, test_loop_id);

    // A heap string in a result slot, as an entry nobody takes would leave
    // it; the set's drop must release it.
    var result: builtins.str.RocStr = .fromSlice("a string too long to fit in a small string", owner.ops);
    try std.testing.expect(!result.isSmallStr());
    const drop = group.result_drop orelse return error.TestUnexpectedResult;
    drop(@ptrCast(&result), group.result_drop_context, owner.ops);

    const ended = try interp.eval(.{ .proc_id = finish, .arg_layouts = &.{.opaque_ptr}, .arg_ptr = @ptrCast(&address) });
    try std.testing.expectEqual(@as(u32, 1), ended.value.read(u32));
    try f.runtime_env.checkForLeaks();
}

/// The task-form loop the park-site test runs, after the continuation pass:
/// the provides root `g()` opens a running set of three entries (one
/// returning 5, then two background ones returning 100 and 200) and sums
/// what arrives:
///
///     join L(sum) { s = group_next(3); match s { 0 => sum = sum +
///     load(group_arrival(3)); jump L, _ => group_free(3); ret sum } }
///
/// Its operations have no task until the pass gives `g` one and passes it
/// to each. Only a task-form loop has a `group_next`, and it has that form
/// because an entry may suspend at a `suspending` hosted call. The program
/// declares one, `roc_test_unused`, which nothing here calls. Returns the
/// task entry that takes `g`'s place.
fn parkingProgram(f: *Fixture) TaskOpsTestError!LIR.LirProcSpecId {
    _ = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = .empty(),
        .ret_layout = .u64,
        .hosted = .some(.{ .symbol = try f.store.insertString("roc_test_unused"), .dispatch_index = 0 }),
        .suspends = .may,
    }, .none);
    const erased = try f.layouts.insertErasedCallable();
    const list_u64 = try f.layouts.insertList(.u64);
    const starts = [_]LIR.LirProcSpecId{ try constantStart(f, 5), try constantStart(f, 100), try constantStart(f, 200) };
    const background = [_]bool{ false, true, true };

    const id = try f.local(.u64);
    const path = try f.local(list_u64);
    const no = try f.local(.bool);
    const yes = try f.local(.bool);
    const unit = try f.local(.zst);
    const sum0 = try f.local(.u64);
    const sum = try f.local(.u64);
    const status = try f.local(.u32);
    const slot = try f.local(try f.layouts.insertPtr(.u64));
    const value = try f.local(.u64);
    const sum2 = try f.local(.u64);
    const freed = try f.local(.zst);
    var start_locals: [3]LocalId = undefined;
    for (&start_locals) |*start| start.* = try f.local(erased);
    const join_id: LIR.JoinPointId = @fromBackingInt(@intCast(1));

    // The loop.
    const back = try f.store.addCFStmt(.{ .jump = .{ .target = join_id } }, .test_fixture);
    const rebind = try f.store.addCFStmt(.{ .set_local = .{ .target = sum, .value = sum2, .mode = .initialize_join_param, .next = back } }, .test_fixture);
    const add = try f.op(sum2, .num_int_add_wrap, &.{ sum, value }, rebind);
    const arrived = try f.op(slot, .group_arrival, &.{id}, try f.op(value, .ptr_load, &.{slot}, add));
    const ended = try f.op(freed, .group_free, &.{id}, try f.ret(sum));
    const branch = try f.store.addCFStmt(.{ .switch_stmt = .{
        .cond = status,
        .branches = try f.store.addCFSwitchBranches(&.{.{ .value = 0, .body = arrived }}),
        .default_branch = ended,
    } }, .test_fixture);
    const loop_body = try f.op(status, .group_next, &.{id}, branch);
    const enter = try f.store.addCFStmt(.{ .jump = .{ .target = join_id } }, .test_fixture);
    const init_sum = try f.store.addCFStmt(.{ .set_local = .{ .target = sum, .value = sum0, .mode = .initialize_join_param, .next = enter } }, .test_fixture);
    const loop = try f.store.addCFStmt(.{ .join = .{ .id = join_id, .params = try f.store.addLocalSpan(&.{sum}), .body = loop_body, .remainder = init_sum } }, .test_fixture);

    // Opening the set.
    var head = try literal(f, sum0, 0, .u64, loop);
    head = try f.op(unit, .group_start, &.{id}, head);
    var index: usize = start_locals.len;
    while (index > 0) {
        index -= 1;
        head = try f.op(unit, .group_push, &.{ id, start_locals[index], path, no, if (background[index]) yes else no }, head);
    }
    head = try f.store.addCFStmt(.{ .assign_list = .{ .target = path, .elems = .empty(), .next = head } }, .test_fixture);
    head = try literal(f, yes, 1, .bool, head);
    head = try literal(f, no, 0, .bool, head);
    head = try groupInit(f, id, 3, .u64, null, head);
    head = try packStarts(f, &starts, &start_locals, head);
    const g = try f.store.addProcSpec(.{
        .name = f.store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.programLocal("task-ops-test", f.store.next_synthetic_symbol),
        .args = .empty(),
        .frame_locals = try f.store.addLocalSpan(f.locals.items),
        .body = .some(head),
        .ret_layout = .u64,
    }, .none);
    f.locals.clearRetainingCapacity();

    try lir.SuspensionMarks.run(f.allocator, &f.store);
    var roots = [_]LIR.LirProcSpecId{g};
    try lir.ContinuationPass.run(f.allocator, &f.store, &f.layouts, .{ .procs = &roots, .provided = &.{true} });
    try indexJoinPoints(f);
    return roots[0];
}

/// Give every procedure the table of its join points that the interpreter
/// jumps through. A compiled program's ARC builds these tables; these tests
/// run LIR from before ARC, so they build them here: the loop's `g` and the
/// continuation the pass copies the loop into both need one.
fn indexJoinPoints(f: *Fixture) TaskOpsTestError!void {
    var work = std.ArrayList(CFStmtId).empty;
    defer work.deinit(f.allocator);
    var joins = std.ArrayList(LIR.JoinPoint).empty;
    defer joins.deinit(f.allocator);
    for (0..f.store.procSpecCount()) |index| {
        const proc_id: LIR.LirProcSpecId = @fromBackingInt(@intCast(index));
        const body = f.store.getProcSpecImmediate(proc_id).body.get() orelse continue;
        joins.clearRetainingCapacity();
        try work.append(f.allocator, body);
        while (work.pop()) |stmt_id| {
            const stmt = f.store.getCFStmtImmediate(stmt_id).*;
            if (stmt == .join) try joins.append(f.allocator, .{ .id = stmt.join.id, .params = stmt.join.params, .body = stmt.join.body });
            try lir.BodyClone.appendSuccessors(&f.store, &work, stmt_id, f.allocator);
        }
        std.mem.sort(LIR.JoinPoint, joins.items, {}, struct {
            fn lessThan(_: void, lhs: LIR.JoinPoint, rhs: LIR.JoinPoint) bool {
                return @backingInt(lhs.id) < @backingInt(rhs.id);
            }
        }.lessThan);
        f.store.getProcSpecPtr(proc_id).join_points = try f.store.addJoinPointSpan(joins.items);
    }
}

test "a task parks at its running set's next and resumes there until the loop ends" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try parkingProgram(&f);

    var static_strings = try eval.Interpreter.buildStaticStrings(f.allocator, &f.store);
    defer static_strings.deinit();
    var interp = try eval.Interpreter.init(f.allocator, &f.store, &f.layouts, static_strings.view(), f.runtime_env.get_ops());
    defer interp.deinit();

    var root: u64 = 0;
    var result_out = @intFromPtr(&root);
    const created = try interp.eval(.{ .proc_id = entry, .arg_layouts = &.{.opaque_ptr}, .arg_ptr = @ptrCast(&result_out) });
    const task: *RocTask = @ptrFromInt(created.value.read(usize));
    const ready = &ReadyChildren.ready;
    const abort = &ReadyChildren.abort;
    ReadyChildren.len = 0;
    const Status = builtins.task.Status;

    // The loop opens the set, which starts all three entries, and parks at
    // its next: nothing has reported.
    try std.testing.expectEqual(Status.pending, task.resumeFromHost(ready, abort));
    try std.testing.expectEqual(@as(usize, 3), ReadyChildren.len);
    const first = ReadyChildren.tasks[0];
    const second = ReadyChildren.tasks[1];
    const third = ReadyChildren.tasks[2];

    // The first entry's report readies the task. It resumes at its next and
    // takes 5; only background entries are left, so the next after that
    // cancels them and parks again.
    try std.testing.expectEqual(Status.done, first.resumeFromHost(ready, abort));
    try std.testing.expectEqual(task, ReadyChildren.tasks[ReadyChildren.len - 1]);
    try std.testing.expectEqual(Status.pending, task.resumeFromHost(ready, abort));

    // One cancelled entry's report readies the task, but the other still
    // runs: the resumed next parks once more.
    try std.testing.expectEqual(Status.cancelled, second.resumeFromHost(ready, abort));
    try std.testing.expectEqual(task, ReadyChildren.tasks[ReadyChildren.len - 1]);
    try std.testing.expectEqual(Status.pending, task.resumeFromHost(ready, abort));

    // The last report ends the loop, which returns the sum.
    try std.testing.expectEqual(Status.cancelled, third.resumeFromHost(ready, abort));
    try std.testing.expectEqual(Status.done, task.resumeFromHost(ready, abort));
    try std.testing.expectEqual(@as(u64, 5), root);
    task.free();
    try f.runtime_env.checkForLeaks();
}
