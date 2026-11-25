//! Promotion of concurrent loops to the task form (design.md "Plans And
//! Concurrent Loops", "Promotion").
//!
//! Monotype lowers every concurrent loop to calls of the Builtin running-set
//! helpers, its sequential form. A loop whose `run_next!` specialization may
//! suspend, or whose procedure may wait on shared state, is task-form: this
//! rewrites each of its helper calls in place to running-set operations, which
//! name the set by the loop's id. In a build with tasks it also replaces the body
//! of each `run_supervised!` specialization with its restart loop
//! ("Supervision."). In one with tasks or whose updates can wait, it replaces
//! those of the `cell_wait!` and `cell_settle!` specializations with their
//! operations ("Shared State", "Waiting."). The continuation pass runs this
//! before it finds any sites, since a promoted `group_next` is a park site, and
//! afterwards gives every operation its task.

const std = @import("std");
const collections = @import("collections");
const core = @import("lir_core");
const layout = @import("layout");
const body_clone = @import("body_clone.zig");
const SuspensionMarks = @import("suspension_marks.zig");
const ContinuationPass = @import("continuation_pass.zig");
const base = @import("base");
const invariant = base.invariant;

const LIR = core.LIR;
const LirStore = core.LirStore;
const GuardedList = LirStore.GuardedList;
const Allocator = std.mem.Allocator;
const CFStmtId = LIR.CFStmtId;
const LocalId = LIR.LocalId;
const ProcId = LIR.LirProcSpecId;
const Start = ContinuationPass.Start;

/// What promotion uses of one task-form `run_next!` specialization: the
/// helpers its body calls and its loops' children's start procedure.
const Loop = struct {
    arrived: ProcId,
    ended: ProcId,
    /// The layout of an entry, `run_entry!`'s argument; a spawned function
    /// has it too.
    item: layout.Idx,
    /// The layout of an entry's result.
    result: layout.Idx,
    /// One per `run_entry!` specialization; loops that share it share this.
    start: Start,
};

/// Promote every task-form loop in the program (design.md "Promotion"), and
/// in a build with tasks every `run_supervised!` specialization, and where
/// updates can wait every `cell_wait!` and `cell_settle!` one ("Supervision.";
/// "Shared State", "Waiting.").
pub fn run(allocator: Allocator, store: *LirStore, layouts: *layout.Store, mode: base.ConcurrencyMode) Allocator.Error!void {
    var loops = collections.DenseMapUnmanaged(ProcId, Loop).empty;
    defer loops.deinit(allocator);
    var starts = collections.DenseMapUnmanaged(ProcId, Start).empty;
    defer starts.deinit(allocator);

    // Start procedures are added below; none of them calls a helper.
    const proc_count = store.procSpecCount();
    // Nothing waits in a program without tasks whose updates can't.
    const waits = mode.hasTasks() or holdsWait(store);
    var may_wait = if (waits) try SuspensionMarks.mayWait(allocator, store) else try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, proc_count);
    defer may_wait.deinit(allocator);
    for (0..proc_count) |index| {
        const proc_id: ProcId = @fromBackingInt(@intCast(index));
        const proc = store.getProcSpecImmediate(proc_id);
        if (proc.running_set_helper != .run_next or proc.suspends == .never) continue;
        try loops.put(allocator, proc_id, try describe(allocator, store, layouts, &starts, proc_id));
    }
    if (waits) {
        for (0..proc_count) |index| {
            const proc_id: ProcId = @fromBackingInt(@intCast(index));
            const proc = store.getProcSpecImmediate(proc_id);
            if (proc.body.get() == null) continue;
            switch (proc.running_set_helper) {
                .run_supervised => if (mode.hasTasks()) try promoteSupervised(allocator, store, layouts, &starts, proc_id),
                .cell_lock => if (mode == .parallel_tasks) try promoteCell(allocator, store, proc_id, .cell_lock),
                .cell_wait => try promoteCell(allocator, store, proc_id, .cell_wait),
                .cell_settle => try promoteCell(allocator, store, proc_id, .cell_settle),
                .none, .run_create, .run_next, .run_spawn, .run_cancel, .run_entry, .run_arrived, .run_ended => {},
            }
        }
    }
    if (loops.count() == 0 and may_wait.count() == 0) return;
    for (0..proc_count) |index| try promoteIn(allocator, store, layouts, &loops, &starts, may_wait.isSet(index), @fromBackingInt(@intCast(index)));
}

/// Whether this compilation holds the body of a `cell_wait!` specialization.
fn holdsWait(store: *const LirStore) bool {
    for (0..store.procSpecCount()) |index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@intCast(index)));
        if (proc.running_set_helper == .cell_wait and proc.body.get() != null) return true;
    }
    return false;
}

/// The helpers a task-form `run_next!` calls: exactly one specialization
/// each of `run_entry!`, `run_arrived` and `run_ended`.
fn describe(allocator: Allocator, store: *LirStore, layouts: *layout.Store, starts: *collections.DenseMapUnmanaged(ProcId, Start), next: ProcId) Allocator.Error!Loop {
    var entry: ?ProcId = null;
    var arrived: ?ProcId = null;
    var ended: ?ProcId = null;
    var stmts = try bodyStmts(allocator, store, next);
    defer stmts.deinit(allocator);
    for (stmts.items) |stmt_id| {
        const stmt = store.getCFStmtImmediate(stmt_id).*;
        if (stmt != .assign_call) continue;
        const callee = stmt.assign_call.proc;
        const slot: *?ProcId = switch (store.getProcSpecImmediate(callee).running_set_helper) {
            .run_entry => &entry,
            .run_arrived => &arrived,
            .run_ended => &ended,
            .none, .run_create, .run_next, .run_spawn, .run_cancel, .run_supervised, .cell_lock, .cell_wait, .cell_settle => continue,
        };
        if (slot.*) |seen| {
            if (seen != callee) invariant("a run_next! specialization calls two specializations of one running-set helper", .{});
        }
        slot.* = callee;
    }
    const entry_proc = entry orelse invariant("a task-form run_next! specialization calls no run_entry!", .{});
    const child = try describeEntry(allocator, store, layouts, starts, entry_proc);
    return .{
        .arrived = arrived orelse invariant("a task-form run_next! specialization calls no run_arrived", .{}),
        .ended = ended orelse invariant("a task-form run_next! specialization calls no run_ended", .{}),
        .item = child.item,
        .result = child.result,
        .start = child.start,
    };
}

/// What promotion uses of one `run_entry!` specialization.
const Entry = struct {
    /// The layout of an entry, its argument.
    item: layout.Idx,
    /// The layout of an entry's result.
    result: layout.Idx,
    start: Start,
};

/// The entry's layouts, and the one start procedure of `entry`. A task-form
/// loop's entry may suspend and so takes the task; a supervised one takes it
/// only then.
fn describeEntry(allocator: Allocator, store: *LirStore, layouts: *layout.Store, starts: *collections.DenseMapUnmanaged(ProcId, Start), entry: ProcId) Allocator.Error!Entry {
    const spec = store.getProcSpecImmediate(entry).*;
    if (GuardedList.borrowLen(store.getLocalSpan(spec.args)) != 1) invariant("run_entry! does not take exactly its entry before the continuation pass", .{});
    const item = store.getLocal(GuardedList.at(store.getLocalSpan(spec.args), 0)).layout_idx;
    const start = starts.get(entry) orelse blk: {
        const made = try ContinuationPass.buildStart(allocator, store, layouts, entry, &.{item}, spec.suspends != .never, .child_start);
        try starts.put(allocator, entry, made);
        break :blk made;
    };
    return .{ .item = item, .result = spec.ret_layout, .start = start };
}

/// Every statement of `proc`'s body, once. Paths that share a tail, such as a
/// loop's `break` and its normal end, reach it once each.
fn bodyStmts(allocator: Allocator, store: *LirStore, proc: ProcId) Allocator.Error!std.ArrayList(CFStmtId) {
    var all = std.ArrayList(CFStmtId).empty;
    errdefer all.deinit(allocator);
    var seen = collections.DenseMapUnmanaged(CFStmtId, void).empty;
    defer seen.deinit(allocator);
    var work = std.ArrayList(CFStmtId).empty;
    defer work.deinit(allocator);
    try work.append(allocator, store.getProcSpecImmediate(proc).body.get() orelse return all);
    while (work.pop()) |stmt_id| {
        if ((try seen.getOrPut(allocator, stmt_id)).found_existing) continue;
        try all.append(allocator, stmt_id);
        try body_clone.appendSuccessors(store, &work, stmt_id, allocator);
    }
    return all;
}

/// Rewrites one procedure's task-form loops. Holds the procedure's new
/// locals and the join ids it may still use.
const Promoter = struct {
    allocator: Allocator,
    store: *LirStore,
    layouts: *layout.Store,
    frame: std.ArrayList(LocalId) = .empty,
    joins: body_clone.JoinParamIndex,

    fn local(self: *Promoter, layout_idx: layout.Idx) Allocator.Error!LocalId {
        return try ContinuationPass.freshLocal(self.store, &self.frame, self.allocator, layout_idx);
    }

    fn op(self: *Promoter, target: LocalId, low_level: LIR.LowLevel, args: []const LocalId, next: CFStmtId, origin: LIR.StmtOrigin) Allocator.Error!CFStmtId {
        return try self.store.addLowLevelStmt(target, low_level, args, next, origin);
    }

    fn literal(self: *Promoter, target: LocalId, value: i64, layout_idx: layout.Idx, next: CFStmtId, origin: LIR.StmtOrigin) Allocator.Error!CFStmtId {
        return try self.store.addCFStmt(.{ .assign_literal = .{
            .target = target,
            .value = .{ .i64_literal = .{ .value = value, .layout_idx = layout_idx } },
            .next = next,
        } }, origin);
    }

    fn call(self: *Promoter, target: LocalId, proc: ProcId, args: []const LocalId, next: CFStmtId, origin: LIR.StmtOrigin) Allocator.Error!CFStmtId {
        return try self.store.addCFStmt(.{ .assign_call = .{
            .target = target,
            .proc = proc,
            .args = try self.store.addLocalSpan(args),
            .next = next,
        } }, origin);
    }

    /// `target = source` before `next`, then `jump join`.
    fn jumpWith(self: *Promoter, join: LIR.JoinPointId, target: LocalId, source: LocalId, origin: LIR.StmtOrigin) Allocator.Error!CFStmtId {
        const jump = try self.store.addCFStmt(.{ .jump = .{ .target = join } }, origin);
        return try self.store.addCFStmt(.{ .set_local = .{ .target = target, .value = source, .mode = .initialize_join_param, .next = jump } }, origin);
    }

    /// `site` becomes the statement `head` is, which leads to the call's
    /// `next`; the call's origin stays on it.
    fn replace(self: *Promoter, site: CFStmtId, head: CFStmtId) void {
        self.store.getCFStmtPtr(site).* = self.store.getCFStmtImmediate(head).*;
    }

    /// `r = run_create!(id, entries, limit_paths, shielded, background,
    /// limits, root_limit)`: open the set, push each entry, start it, then
    /// make the empty sequential set the rest of the loop passes around.
    fn promoteCreate(self: *Promoter, site: CFStmtId, loop: Loop) Allocator.Error!void {
        const created = self.store.getCFStmtImmediate(site).assign_call;
        const origin = self.store.stmtOrigin(site);
        const args = try ContinuationPass.copyLocals(self.allocator, self.store, created.args);
        defer self.allocator.free(args);
        if (args.len != 7) invariant("run_create! does not take a loop id, five lists and a root limit", .{});
        const id = args[0];
        const entries = args[1];
        const limit_paths = args[2];
        const shielded = args[3];
        const background = args[4];
        const limits = args[5];
        const root_limit = args[6];

        // After the pushes: start the set and make the empty Running value.
        var empties: [5]LocalId = undefined;
        for (&empties, args[1..6]) |*empty, list| empty.* = try self.local(self.store.getLocal(list).layout_idx);
        const no_limit = try self.local(self.store.getLocal(root_limit).layout_idx);
        var after = try self.call(created.target, created.proc, &.{ id, empties[0], empties[1], empties[2], empties[3], empties[4], no_limit }, created.next, origin);
        after = try self.literal(no_limit, 0, self.store.getLocal(root_limit).layout_idx, after, origin);
        var index = empties.len;
        while (index > 0) {
            index -= 1;
            after = try self.store.addCFStmt(.{ .assign_list = .{ .target = empties[index], .elems = .empty(), .next = after } }, origin);
        }
        after = try self.op(try self.local(.zst), .group_start, &.{id}, after, origin);

        // The pushes: join push(i) { if i < n { ...; jump push(i + 1) } else after }.
        const push = self.joins.freshJoinPoint();
        const n = try self.local(.u64);
        const i = try self.local(.u64);
        const more = try self.local(.bool);
        const next_i = try self.local(.u64);
        const one = try self.local(.u64);
        const item = try self.local(loop.item);
        const record = try self.local(try self.layouts.insertErasedCallable());
        const path = try self.local(try self.layouts.insertList(.u64));
        const is_shielded = try self.local(.bool);
        const is_background = try self.local(.bool);
        var body = try self.jumpWith(push, i, next_i, origin);
        body = try self.op(next_i, .num_int_add_wrap, &.{ i, one }, body, origin);
        body = try self.literal(one, 1, .u64, body, origin);
        body = try self.op(try self.local(.zst), .group_push, &.{ id, record, path, is_shielded, is_background }, body, origin);
        body = try self.op(is_background, .list_get_unsafe, &.{ background, i }, body, origin);
        body = try self.op(is_shielded, .list_get_unsafe, &.{ shielded, i }, body, origin);
        body = try self.op(path, .list_get_unsafe, &.{ limit_paths, i }, body, origin);
        body = try ContinuationPass.packStart(self.allocator, self.store, self.layouts, &self.frame, loop.start, &.{item}, record, body, origin);
        body = try self.op(item, .list_get_unsafe, &.{ entries, i }, body, origin);
        const test_more = try self.store.addCFStmt(.{ .switch_stmt = .{
            .cond = more,
            .branches = try self.store.addCFSwitchBranches(&.{.{ .value = 1, .body = body }}),
            .default_branch = after,
        } }, origin);
        const push_body = try self.op(more, .num_is_lt, &.{ i, n }, test_more, origin);

        // Before them: open the set, then enter the pushes at 0.
        const zero = try self.local(.u64);
        const unsupervised = try self.local(.bool);
        var head = try self.jumpWith(push, i, zero, origin);
        head = try self.literal(zero, 0, .u64, head, origin);
        head = try self.store.addCFStmt(.{ .join = .{
            .id = push,
            .params = try self.store.addLocalSpan(&.{i}),
            .body = push_body,
            .remainder = head,
        } }, origin);
        head = try self.store.addCFStmt(.{ .assign_low_level = .{
            .target = try self.local(.zst),
            .op = .group_init,
            .rc_effect = try self.store.addRcEffect(LIR.LowLevel.group_init.rcEffect()),
            .extra = try self.store.addStmtRow(LIR.LowLevelExtra, .{ .group_result = .some(loop.result) }),
            .args = try self.store.addLocalSpan(&.{ id, n, limits, root_limit, unsupervised }),
            .next = head,
        } }, origin);
        head = try self.literal(unsupervised, 0, .bool, head, origin);
        head = try self.op(n, .list_len, &.{entries}, head, origin);
        self.replace(site, head);
    }

    /// `t = run_next!(id, r)`: the park site `s = group_next(id)`, then
    /// `run_arrived` with the arrived result on 0 or `run_ended` once the set
    /// is freed on 1, joining with `t` before the call's `next`.
    fn promoteNext(self: *Promoter, site: CFStmtId, loop: Loop) Allocator.Error!void {
        const called = self.store.getCFStmtImmediate(site).assign_call;
        const origin = self.store.stmtOrigin(site);
        const args = self.store.getLocalSpan(called.args);
        if (GuardedList.borrowLen(args) != 2) invariant("run_next! does not take a loop id and its running set", .{});
        const id = GuardedList.at(args, 0);
        const running = GuardedList.at(args, 1);
        const t_layout = self.store.getLocal(called.target).layout_idx;
        const joined = self.joins.freshJoinPoint();

        const status = try self.local(.u32);
        const slot = try self.local(try self.layouts.insertPtr(loop.result));
        const value = try self.local(loop.result);
        const arrived_t = try self.local(t_layout);
        const ended_t = try self.local(t_layout);
        var arrived = try self.jumpWith(joined, called.target, arrived_t, origin);
        arrived = try self.call(arrived_t, loop.arrived, &.{ running, value }, arrived, origin);
        arrived = try self.store.addTaskResultLoad(value, slot, loop.start.proc, arrived, origin);
        arrived = try self.op(slot, .group_arrival, &.{id}, arrived, origin);
        var ended = try self.jumpWith(joined, called.target, ended_t, origin);
        ended = try self.call(ended_t, loop.ended, &.{running}, ended, origin);
        ended = try self.op(try self.local(.zst), .group_free, &.{id}, ended, origin);
        const branch = try self.store.addCFStmt(.{ .switch_stmt = .{
            .cond = status,
            .branches = try self.store.addCFSwitchBranches(&.{.{ .value = 0, .body = arrived }}),
            .default_branch = ended,
        } }, origin);
        const park = try self.op(status, .group_next, &.{id}, branch, origin);
        const head = try self.store.addCFStmt(.{ .join = .{
            .id = joined,
            .params = try self.store.addLocalSpan(&.{called.target}),
            .body = called.next,
            .remainder = park,
        } }, origin);
        self.replace(site, head);
    }

    /// `r2 = run_spawn!(id, r, f)`: spawn `f`'s start record; `r2` is `r`.
    fn promoteSpawn(self: *Promoter, site: CFStmtId, loop: Loop) Allocator.Error!void {
        const called = self.store.getCFStmtImmediate(site).assign_call;
        const origin = self.store.stmtOrigin(site);
        const args = self.store.getLocalSpan(called.args);
        if (GuardedList.borrowLen(args) != 3) invariant("run_spawn! does not take a loop id, its running set and a function", .{});
        const id = GuardedList.at(args, 0);
        const running = GuardedList.at(args, 1);
        const function = GuardedList.at(args, 2);
        const record = try self.local(try self.layouts.insertErasedCallable());
        var head = try self.store.addCFStmt(.{ .assign_ref = .{ .target = called.target, .op = LIR.RefOp.local(running), .next = called.next } }, origin);
        head = try self.op(try self.local(.zst), .group_spawn, &.{ id, record }, head, origin);
        head = try ContinuationPass.packStart(self.allocator, self.store, self.layouts, &self.frame, loop.start, &.{function}, record, head, origin);
        self.replace(site, head);
    }

    /// `r2 = run_cancel!(id, r)`: cancel the set; `r2` is `r`.
    fn promoteCancel(self: *Promoter, site: CFStmtId) Allocator.Error!void {
        const called = self.store.getCFStmtImmediate(site).assign_call;
        const origin = self.store.stmtOrigin(site);
        const args = self.store.getLocalSpan(called.args);
        if (GuardedList.borrowLen(args) != 2) invariant("run_cancel! does not take a loop id and its running set", .{});
        var head = try self.store.addCFStmt(.{ .assign_ref = .{ .target = called.target, .op = LIR.RefOp.local(GuardedList.at(args, 1)), .next = called.next } }, origin);
        head = try self.op(try self.local(.zst), .group_cancel, &.{GuardedList.at(args, 0)}, head, origin);
        self.replace(site, head);
    }
};

/// Replace the body of one `run_supervised!(max_restarts, f)` specialization,
/// `run_entry!(f)`, with its restart loop (design.md "Supervision."):
///
///     join restart(left = max_restarts) {
///         group_init(id, 1, [], 0, True); group_push(id, start of f, [], False, False);
///         group_start(id); s = group_next(id)
///         match s {
///             0 => v = ptr_load(group_arrival(id)); group_free(id); ret v
///             _ => m = ptr_load(group_arrival(id)); group_free(id);
///                  match left { 0 => crash m, _ => jump restart(left - 1) }
///         }
///     }
fn promoteSupervised(allocator: Allocator, store: *LirStore, layouts: *layout.Store, starts: *collections.DenseMapUnmanaged(ProcId, Start), proc_id: ProcId) Allocator.Error!void {
    var entry: ?ProcId = null;
    var stmts = try bodyStmts(allocator, store, proc_id);
    defer stmts.deinit(allocator);
    for (stmts.items) |stmt_id| {
        const stmt = store.getCFStmtImmediate(stmt_id).*;
        if (stmt != .assign_call) continue;
        const callee = stmt.assign_call.proc;
        if (store.getProcSpecImmediate(callee).running_set_helper != .run_entry) continue;
        if (entry != null) invariant("a run_supervised! specialization calls run_entry! twice", .{});
        entry = callee;
    }
    const child = try describeEntry(allocator, store, layouts, starts, entry orelse invariant("a run_supervised! specialization calls no run_entry!", .{}));
    const args = try ContinuationPass.copyLocals(allocator, store, store.getProcSpecImmediate(proc_id).args);
    defer allocator.free(args);
    if (args.len != 2) invariant("run_supervised! does not take a restart limit and its function", .{});
    const max_restarts = args[0];
    const function = args[1];
    if (store.getLocal(function).layout_idx != child.item) invariant("run_supervised!'s function is not its run_entry!'s entry", .{});
    if (store.getProcSpecImmediate(proc_id).ret_layout != child.result) invariant("run_supervised! does not return its run_entry!'s result", .{});

    const origin = store.stmtOrigin(store.getProcSpecImmediate(proc_id).body.get().?);
    var b = Promoter{
        .allocator = allocator,
        .store = store,
        .layouts = layouts,
        .joins = body_clone.JoinParamIndex.init(allocator),
    };
    defer b.frame.deinit(allocator);
    defer b.joins.deinit();
    try b.frame.appendSlice(allocator, args);
    const restart = b.joins.freshJoinPoint();
    const left = try b.local(.u64);
    const id = try b.local(.u64);
    const status = try b.local(.u32);

    // It returned.
    const slot = try b.local(try layouts.insertPtr(child.result));
    const value = try b.local(child.result);
    var arrived = try store.addCFStmt(.{ .ret = .{ .value = value } }, origin);
    arrived = try b.op(try b.local(.zst), .group_free, &.{id}, arrived, origin);
    arrived = try store.addTaskResultLoad(value, slot, child.start.proc, arrived, origin);
    arrived = try b.op(slot, .group_arrival, &.{id}, arrived, origin);

    // It crashed.
    const message_ptr = try b.local(try layouts.insertPtr(.str));
    const message = try b.local(.str);
    const next_left = try b.local(.u64);
    const one = try b.local(.u64);
    const give_up = try store.addCFStmt(.{ .crash = .{ .msg = .{ .local = message } } }, origin);
    var again = try b.jumpWith(restart, left, next_left, origin);
    again = try b.op(next_left, .num_int_sub_wrap, &.{ left, one }, again, origin);
    again = try b.literal(one, 1, .u64, again, origin);
    var crashed = try store.addCFStmt(.{ .switch_stmt = .{
        .cond = left,
        .branches = try store.addCFSwitchBranches(&.{.{ .value = 0, .body = give_up }}),
        .default_branch = again,
    } }, origin);
    crashed = try b.op(try b.local(.zst), .group_free, &.{id}, crashed, origin);
    crashed = try store.addHostVisibleLoad(message, message_ptr, crashed, origin);
    crashed = try b.op(message_ptr, .group_arrival, &.{id}, crashed, origin);

    // Start it.
    const count = try b.local(.u64);
    const limits = try b.local(try layouts.insertList(.u64));
    const no_limit = try b.local(.u64);
    const supervised = try b.local(.bool);
    const record = try b.local(try layouts.insertErasedCallable());
    const path = try b.local(try layouts.insertList(.u64));
    const no = try b.local(.bool);
    var body = try store.addCFStmt(.{ .switch_stmt = .{
        .cond = status,
        .branches = try store.addCFSwitchBranches(&.{.{ .value = 0, .body = arrived }}),
        .default_branch = crashed,
    } }, origin);
    body = try b.op(status, .group_next, &.{id}, body, origin);
    body = try b.op(try b.local(.zst), .group_start, &.{id}, body, origin);
    body = try b.op(try b.local(.zst), .group_push, &.{ id, record, path, no, no }, body, origin);
    body = try ContinuationPass.packStart(allocator, store, layouts, &b.frame, child.start, &.{function}, record, body, origin);
    body = try b.literal(no, 0, .bool, body, origin);
    body = try store.addCFStmt(.{ .assign_list = .{ .target = path, .elems = .empty(), .next = body } }, origin);
    body = try store.addCFStmt(.{ .assign_low_level = .{
        .target = try b.local(.zst),
        .op = .group_init,
        .rc_effect = try store.addRcEffect(LIR.LowLevel.group_init.rcEffect()),
        .extra = try store.addStmtRow(LIR.LowLevelExtra, .{ .group_result = .some(child.result) }),
        .args = try store.addLocalSpan(&.{ id, count, limits, no_limit, supervised }),
        .next = body,
    } }, origin);
    body = try b.literal(supervised, 1, .bool, body, origin);
    body = try b.literal(no_limit, 0, .u64, body, origin);
    body = try store.addCFStmt(.{ .assign_list = .{ .target = limits, .elems = .empty(), .next = body } }, origin);
    body = try b.literal(count, 1, .u64, body, origin);
    body = try b.literal(id, base.supervised_loop_id, .u64, body, origin);

    const head = try store.addCFStmt(.{ .join = .{
        .id = restart,
        .params = try store.addLocalSpan(&.{left}),
        .body = body,
        .remainder = try b.jumpWith(restart, left, max_restarts, origin),
    } }, origin);
    std.mem.sort(LocalId, b.frame.items, {}, localLessThan);
    const proc = store.getProcSpecPtr(proc_id);
    proc.body = .some(head);
    proc.frame_locals = try store.addLocalSpan(b.frame.items);
}

/// Replace the body of one `cell_lock!(cell)`, `cell_wait!(cell, probe)` or
/// `cell_settle!(cell, stored)` specialization with `op` on its arguments
/// (design.md "Shared State", "Waiting."). Before, the second crashed and the
/// others did nothing.
fn promoteCell(allocator: Allocator, store: *LirStore, proc_id: ProcId, op: LIR.LowLevel) Allocator.Error!void {
    const args = try ContinuationPass.copyLocals(allocator, store, store.getProcSpecImmediate(proc_id).args);
    defer allocator.free(args);
    if (args.len != @as(usize, if (op == .cell_lock) 1 else 2)) invariant("a shared-state helper does not take what its operation does", .{});
    const origin = store.stmtOrigin(store.getProcSpecImmediate(proc_id).body.get().?);
    const unit = try store.addLocal(.{ .layout_idx = store.getProcSpecImmediate(proc_id).ret_layout });
    const result = try store.addLocal(.{ .layout_idx = if (op == .cell_wait) .u32 else .zst });
    const ret = try store.addCFStmt(.{ .ret = .{ .value = unit } }, origin);
    const value = try store.addCFStmt(.{ .assign_struct = .{ .target = unit, .fields = .empty(), .next = ret } }, origin);
    const head = try store.addLowLevelStmt(result, op, args, value, origin);
    var frame = std.ArrayList(LocalId).empty;
    defer frame.deinit(allocator);
    try frame.appendSlice(allocator, args);
    try frame.appendSlice(allocator, &.{ unit, result });
    std.mem.sort(LocalId, frame.items, {}, localLessThan);
    const proc = store.getProcSpecPtr(proc_id);
    proc.body = .some(head);
    proc.frame_locals = try store.addLocalSpan(frame.items);
}

fn localLessThan(_: void, a: LocalId, b: LocalId) bool {
    return @backingInt(a) < @backingInt(b);
}

/// Promote the task-form loops of one procedure: each call of a task-form
/// `run_next!` names its loop's id, and the procedure's other helper calls
/// with that id belong to the same loop. `may_wait` is whether the procedure
/// may wait on shared state, which makes all its loops task-form. `loops` gains
/// those that only this makes so.
fn promoteIn(allocator: Allocator, store: *LirStore, layouts: *layout.Store, loops: *collections.DenseMapUnmanaged(ProcId, Loop), starts: *collections.DenseMapUnmanaged(ProcId, Start), may_wait: bool, proc_id: ProcId) Allocator.Error!void {
    if (store.getProcSpecImmediate(proc_id).body.get() == null) return;
    var stmts = try bodyStmts(allocator, store, proc_id);
    defer stmts.deinit(allocator);

    // What the locals say about loop ids, and the helper calls.
    var ids = LoopIds{};
    defer ids.deinit(allocator);
    var calls = std.ArrayList(CFStmtId).empty;
    defer calls.deinit(allocator);
    for (stmts.items) |stmt_id| {
        const stmt = store.getCFStmtImmediate(stmt_id).*;
        if (stmt == .assign_literal) {
            const value = stmt.assign_literal.value;
            if (value == .i64_literal) {
                try ids.define(allocator, stmt.assign_literal.target, .{ .literal = value.i64_literal.value });
            } else if (value == .i128_literal) {
                try ids.define(allocator, stmt.assign_literal.target, .{ .literal = store.stmtRow(value.i128_literal).value });
            }
        } else if (stmt == .assign_ref and stmt.assign_ref.op.kind == .local) {
            try ids.define(allocator, stmt.assign_ref.target, .{ .copy = stmt.assign_ref.op.source });
        } else if (stmt == .assign_call) switch (store.getProcSpecImmediate(stmt.assign_call.proc).running_set_helper) {
            .run_create, .run_next, .run_spawn, .run_cancel => try calls.append(allocator, stmt_id),
            .none, .run_entry, .run_arrived, .run_ended, .run_supervised, .cell_lock, .cell_wait, .cell_settle => {},
        };
    }

    // The task-form loops, by id.
    var task_form = std.AutoHashMapUnmanaged(u64, Loop).empty;
    defer task_form.deinit(allocator);
    for (calls.items) |stmt_id| {
        const assign = store.getCFStmtImmediate(stmt_id).assign_call;
        const callee = store.getProcSpecImmediate(assign.proc);
        if (callee.running_set_helper != .run_next or (callee.suspends == .never and !may_wait)) continue;
        const loop = loops.get(assign.proc) orelse blk: {
            const described = try describe(allocator, store, layouts, starts, assign.proc);
            try loops.put(allocator, assign.proc, described);
            break :blk described;
        };
        try task_form.put(allocator, loopId(store, &ids, assign), loop);
    }
    if (task_form.count() == 0) return;

    var promoter = Promoter{
        .allocator = allocator,
        .store = store,
        .layouts = layouts,
        .joins = body_clone.JoinParamIndex.init(allocator),
    };
    defer promoter.frame.deinit(allocator);
    defer promoter.joins.deinit();
    try promoter.joins.indexReachable(store, store.getProcSpecImmediate(proc_id).body.get().?);
    var created = std.AutoHashMapUnmanaged(u64, void).empty;
    defer created.deinit(allocator);
    for (calls.items) |stmt_id| {
        const assign = store.getCFStmtImmediate(stmt_id).assign_call;
        const id = loopId(store, &ids, assign);
        const loop = task_form.get(id) orelse continue;
        switch (store.getProcSpecImmediate(assign.proc).running_set_helper) {
            .run_create => {
                // Two would share one running set: today's inlining never
                // copies a loop within a procedure, so fail loudly if it does.
                const seen = try created.getOrPut(allocator, id);
                if (seen.found_existing) invariant("two run_create! calls of one loop id in one procedure", .{});
                try promoter.promoteCreate(stmt_id, loop);
            },
            .run_next => {
                if (store.getProcSpecImmediate(assign.proc).suspends == .never and !may_wait) invariant("one loop id names a task-form and a sequential run_next!", .{});
                try promoter.promoteNext(stmt_id, loop);
            },
            .run_spawn => try promoter.promoteSpawn(stmt_id, loop),
            .run_cancel => try promoter.promoteCancel(stmt_id),
            .none, .run_entry, .run_arrived, .run_ended, .run_supervised, .cell_lock, .cell_wait, .cell_settle => unreachable, // `calls` holds only these four helpers' calls.
        }
    }
    var task_form_ids = task_form.keyIterator();
    while (task_form_ids.next()) |id| {
        if (!created.contains(id.*)) invariant("a task-form loop's run_next! is in a procedure with no run_create! of its id", .{});
    }
    for (promoter.frame.items) |local| try ContinuationPass.appendLocal(store, &store.getProcSpecPtr(proc_id).frame_locals, local);
}

/// The loop id a helper call passes first: a `U64` integer literal of the
/// same procedure, or a copy of one.
fn loopId(store: *const LirStore, ids: *const LoopIds, assign: @FieldType(LIR.CFStmt, "assign_call")) u64 {
    const id = GuardedList.at(store.getLocalSpan(assign.args), 0);
    if (store.getLocal(id).layout_idx != .u64) invariant("a running-set helper's loop id is not a U64", .{});
    return ids.of(id);
}

/// What a procedure's locals say about its loop ids. Lowering gives a loop
/// id as an integer literal, `i64_literal` or `i128_literal`, which helper
/// calls may pass through `ref.local` copies of it.
const LoopIds = struct {
    defs: collections.DenseMapUnmanaged(LocalId, Def) = .empty,

    const Def = union(enum) {
        literal: i128,
        copy: LocalId,
        /// Defined more than once, so it holds no one value.
        several,
    };

    fn deinit(self: *LoopIds, allocator: Allocator) void {
        self.defs.deinit(allocator);
    }

    fn define(self: *LoopIds, allocator: Allocator, local: LocalId, def: Def) Allocator.Error!void {
        const entry = try self.defs.getOrPut(allocator, local);
        entry.value_ptr.* = if (entry.found_existing) .several else def;
    }

    /// The literal `local` holds, following copies back to it in any
    /// statement order.
    fn of(self: *const LoopIds, local: LocalId) u64 {
        var at = local;
        // A chain longer than the number of definitions goes round a cycle.
        for (0..self.defs.count() + 1) |_| {
            const def = self.defs.get(at) orelse
                invariant("a running-set helper's loop id is not an integer literal of its procedure", .{});
            switch (def) {
                .literal => |value| {
                    if (value < 0 or value > std.math.maxInt(u64)) invariant("a running-set helper's loop id does not fit a U64", .{});
                    return @intCast(value);
                },
                .copy => |source| at = source,
                .several => invariant("a running-set helper's loop id is defined more than once", .{}),
            }
        }
        invariant("a running-set helper's loop id copies itself", .{});
    }
};
