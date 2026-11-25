//! Keep reuse inputs out of procedures that may suspend (design.md "Erased
//! Calls That May Suspend").
//!
//! An erased callable's reuse input is null when its caller declined reuse, and
//! a null erased callable is valid only there. A procedure that may suspend
//! would save it in a record, so it never packs into its input or hands it on:
//! - an erased callable that may suspend keeps its input, which the erased ABI
//!   gives it, and packs into none;
//! - a Roc-ABI destination variant that may suspend loses its input, and every
//!   call to it the argument;
//! - a call from one to a destination variant that never suspends passes a
//!   declined input.
//!
//! Runs on lowered bodies right after the marks, where an input is named only
//! by the statements lowering handed it to.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("lir_core");
const body_clone = @import("body_clone.zig");
const invariant = @import("base").invariant;

const LIR = core.LIR;
const LirStore = core.LirStore;
const GuardedList = LirStore.GuardedList;
const Allocator = std.mem.Allocator;
const LocalId = LIR.LocalId;
const ProcId = LIR.LirProcSpecId;

/// Rewrite every procedure that may suspend to hold no reuse input.
pub fn run(allocator: Allocator, store: *LirStore) Allocator.Error!void {
    const count = store.procSpecCount();
    var dropped = try std.DynamicBitSetUnmanaged.initEmpty(allocator, count);
    defer dropped.deinit(allocator);
    var any = false;
    for (0..count) |index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index))));
        if (proc.suspends == .never or proc.body.get() == null or proc.erased_reuse_arg == .none) continue;
        any = true;
        if (proc.abi == .roc) dropped.set(index);
    }
    if (!any) return;

    var seen = try std.DynamicBitSetUnmanaged.initEmpty(allocator, store.cfStmtCount());
    defer seen.deinit(allocator);
    var work = std.ArrayList(LIR.CFStmtId).empty;
    defer work.deinit(allocator);
    for (0..count) |index| {
        const proc_id: ProcId = @fromBackingInt(@as(u32, @intCast(index)));
        const proc = store.getProcSpecImmediate(proc_id).*;
        const body = proc.body.get() orelse continue;
        const input: ?LocalId = if (proc.suspends == .never) null else proc.erased_reuse_arg.get();
        if (dropped.isSet(index)) {
            const args = try spanWithout(allocator, store, proc.args, position(store, proc.args, input.?), null);
            const frame = try spanWithout(allocator, store, proc.frame_locals, position(store, proc.frame_locals, input.?), null);
            const spec = store.getProcSpecPtr(proc_id);
            spec.erased_reuse_arg = .none;
            spec.args = args;
            spec.frame_locals = frame;
        }
        const mark = store.bodyMark();
        // Every statement of the body, before any it gains.
        try work.append(allocator, body);
        var stmts = std.ArrayList(LIR.CFStmtId).empty;
        defer stmts.deinit(allocator);
        while (work.pop()) |stmt_id| {
            if (seen.isSet(@backingInt(stmt_id))) continue;
            seen.set(@backingInt(stmt_id));
            try stmts.append(allocator, stmt_id);
            try body_clone.appendSuccessors(store, &work, stmt_id, allocator);
        }
        for (stmts.items) |stmt_id| {
            try rewrite(allocator, store, proc_id, stmt_id, input, &dropped);
            if (builtin.mode == .debug and dropped.isSet(index)) try verifyDropped(store, stmt_id, input.?);
        }
        try store.recordBodyChunk(proc_id, mark);
    }
}

fn rewrite(allocator: Allocator, store: *LirStore, proc: ProcId, stmt_id: LIR.CFStmtId, input: ?LocalId, dropped: *const std.DynamicBitSetUnmanaged) Allocator.Error!void {
    const stmt = store.getCFStmtImmediate(stmt_id).*;
    if (stmt == .assign_call) {
        const call = stmt.assign_call;
        const len = call.args.len;
        if (dropped.isSet(@backingInt(call.proc))) {
            const args = try spanWithout(allocator, store, call.args, len - 1, null);
            store.getCFStmtPtr(stmt_id).assign_call.args = args;
            return;
        }
        const local = input orelse return;
        if (len == 0 or GuardedList.at(store.getLocalSpan(call.args), len - 1) != local) return;
        // declined = erased_reuse_none(); then the call, as it was but for its
        // last argument.
        const declined = try store.addLocal(.{ .layout_idx = store.getLocal(local).layout_idx });
        var moved = stmt;
        moved.assign_call.args = try spanWithout(allocator, store, call.args, len - 1, declined);
        const origin = store.stmtOrigin(stmt_id);
        const next = try store.addCFStmt(moved, origin);
        try store.replaceCFStmt(stmt_id, .{ .assign_low_level = .{
            .target = declined,
            .op = .erased_reuse_none,
            .rc_effect = try store.addRcEffect(LIR.LowLevel.erased_reuse_none.rcEffect()),
            .args = .empty(),
            .next = next,
        } }, origin);
        const frame = store.getProcSpecImmediate(proc).frame_locals;
        const grown = try spanWithout(allocator, store, frame, null, declined);
        store.getProcSpecPtr(proc).frame_locals = grown;
        return;
    }
    const local = input orelse return;
    if (stmt == .assign_packed_erased_fn) {
        var data = store.stmtRow(stmt.assign_packed_erased_fn.data);
        if (data.reuse.get() != local) return;
        data.reuse = .none;
        data.reuse_unique = false;
        const row = try store.addStmtRow(LIR.PackedErasedFnData, data);
        store.getCFStmtPtr(stmt_id).assign_packed_erased_fn.data = row;
    } else if (stmt == .dyn) {
        var op = store.stmtRow(stmt.dyn.data);
        if (op != .closure or op.closure.reuse != local) return;
        op.closure.reuse = null;
        op.closure.reuse_unique = false;
        const row = try store.addStmtRow(LIR.DynOp, op);
        store.getCFStmtPtr(stmt_id).dyn.data = row;
    }
}

fn verifyDropped(store: *const LirStore, stmt_id: LIR.CFStmtId, input: LocalId) Allocator.Error!void {
    var found = Found{ .input = input };
    body_clone.forEachStmtRead(store, store.getCFStmtImmediate(stmt_id).*, &found, Found.note);
    if (found.read) invariant("a procedure that may suspend reads the reuse input it lost", .{});
}

const Found = struct {
    input: LocalId,
    read: bool = false,

    fn note(self: *Found, local: LocalId) void {
        if (local == self.input) self.read = true;
    }
};

/// `span` without its local at `drop` if there is one, then `add`.
fn spanWithout(allocator: Allocator, store: *LirStore, span: LIR.LocalSpan, drop: ?usize, add: ?LocalId) Allocator.Error!LIR.LocalSpan {
    var locals = try std.ArrayList(LocalId).initCapacity(allocator, span.len + 1);
    defer locals.deinit(allocator);
    for (0..span.len) |index| {
        if (index == drop) continue;
        locals.appendAssumeCapacity(GuardedList.at(store.getLocalSpan(span), index));
    }
    if (add) |local| locals.appendAssumeCapacity(local);
    return store.addLocalSpan(locals.items);
}

/// Where `local` is in `span`.
fn position(store: *const LirStore, span: LIR.LocalSpan, local: LocalId) ?usize {
    const list = store.getLocalSpan(span);
    for (0..span.len) |index| if (GuardedList.at(list, index) == local) return index;
    return null;
}

const testing = std.testing;

test "decline reuse declarations are referenced" {
    testing.refAllDecls(@This());
}

/// A store with three procedures of one erased result: `stays`, a destination
/// variant that never suspends, `moves`, one that calls `stays` and packs into
/// its own input, and `worker`, an erased callable that calls `moves`.
const Fixture = struct {
    store: LirStore,
    layouts: @import("layout").Store,
    stays: ProcId,
    moves: ProcId,
    moves_call: LIR.CFStmtId,
    moves_pack: LIR.CFStmtId,
    worker: ProcId,
    worker_call: LIR.CFStmtId,

    fn init(suspends: LIR.Suspends) Allocator.Error!Fixture {
        const a = testing.allocator;
        var layouts = try @import("layout").Store.init(a, .u64);
        errdefer layouts.deinit();
        var store = LirStore.init(a);
        errdefer store.deinit();
        const erased = try layouts.insertErasedCallable();
        const local = LIR.Local{ .layout_idx = erased };

        const s_reuse = try store.addLocal(local);
        const s_value = try store.addLocal(local);
        const s_ret = try store.addCFStmt(.{ .ret = .{ .value = s_value } }, .test_fixture);
        const stays = try store.addProcSpec(.{
            .name = store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(1),
            .args = try store.addLocalSpan(&.{s_reuse}),
            .frame_locals = try store.addLocalSpan(&.{ s_reuse, s_value }),
            .ret_layout = erased,
            .erased_reuse_arg = .some(s_reuse),
        }, .none);
        const s_pack = try store.addCFStmt(.{ .assign_packed_erased_fn = .{
            .target = s_value,
            .data = try store.addStmtRow(LIR.PackedErasedFnData, .{ .proc = stays, .capture = .none, .capture_layout = .none, .on_drop = .none, .reuse = .some(s_reuse) }),
            .next = s_ret,
        } }, .test_fixture);
        store.getProcSpecPtr(stays).body = .some(s_pack);

        const m_x = try store.addLocal(.{ .layout_idx = .u64 });
        const m_reuse = try store.addLocal(local);
        const m_first = try store.addLocal(local);
        const m_value = try store.addLocal(local);
        const m_ret = try store.addCFStmt(.{ .ret = .{ .value = m_value } }, .test_fixture);
        const m_pack = try store.addCFStmt(.{ .assign_packed_erased_fn = .{
            .target = m_value,
            .data = try store.addStmtRow(LIR.PackedErasedFnData, .{ .proc = stays, .capture = .none, .capture_layout = .none, .on_drop = .none, .reuse = .some(m_reuse), .reuse_unique = true }),
            .next = m_ret,
        } }, .test_fixture);
        const m_call = try store.addCFStmt(.{ .assign_call = .{
            .target = m_first,
            .proc = stays,
            .args = try store.addLocalSpan(&.{m_reuse}),
            .next = m_pack,
        } }, .test_fixture);
        const moves = try store.addProcSpec(.{
            .name = store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(2),
            .args = try store.addLocalSpan(&.{ m_x, m_reuse }),
            .frame_locals = try store.addLocalSpan(&.{ m_x, m_reuse, m_first, m_value }),
            .body = .some(m_call),
            .ret_layout = erased,
            .erased_reuse_arg = .some(m_reuse),
            .suspends = suspends,
        }, .none);

        const w_x = try store.addLocal(.{ .layout_idx = .u64 });
        const w_capture = try store.addLocal(.{ .layout_idx = .opaque_ptr });
        const w_reuse = try store.addLocal(local);
        const w_value = try store.addLocal(local);
        const w_ret = try store.addCFStmt(.{ .ret = .{ .value = w_value } }, .test_fixture);
        const w_call = try store.addCFStmt(.{ .assign_call = .{
            .target = w_value,
            .proc = moves,
            .args = try store.addLocalSpan(&.{ w_x, w_reuse }),
            .next = w_ret,
        } }, .test_fixture);
        const worker = try store.addProcSpec(.{
            .name = store.freshSyntheticSymbol(),
            .identity = LIR.ProcIdentity.forTest(3),
            .args = try store.addLocalSpan(&.{ w_x, w_capture, w_reuse }),
            .frame_locals = try store.addLocalSpan(&.{ w_x, w_capture, w_reuse, w_value }),
            .body = .some(w_call),
            .ret_layout = erased,
            .abi = .erased_callable,
            .erased_capture_arg = .some(w_capture),
            .erased_reuse_arg = .some(w_reuse),
            .suspends = suspends,
        }, .none);
        return .{
            .store = store,
            .layouts = layouts,
            .stays = stays,
            .moves = moves,
            .moves_call = m_call,
            .moves_pack = m_pack,
            .worker = worker,
            .worker_call = w_call,
        };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.layouts.deinit();
    }
};

test "a procedure that may suspend takes no reuse input and declines the ones it passes" {
    var f = try Fixture.init(.may);
    defer f.deinit();
    const erased_input = f.store.getProcSpecImmediate(f.worker).erased_reuse_arg;
    try run(testing.allocator, &f.store);

    // The variant that suspends loses its input, in its frame too.
    const moves = f.store.getProcSpecImmediate(f.moves).*;
    try testing.expectEqual(@as(usize, 1), moves.args.len);
    try testing.expect(moves.erased_reuse_arg == .none);
    // It packs into nothing, and its call to the other variant, which keeps
    // its input, passes a declined one.
    const pack = f.store.stmtRow(f.store.getCFStmtImmediate(f.moves_pack).assign_packed_erased_fn.data);
    try testing.expect(pack.reuse == .none);
    try testing.expect(!pack.reuse_unique);
    const declined = f.store.getCFStmtImmediate(f.moves_call).assign_low_level;
    try testing.expectEqual(LIR.LowLevel.erased_reuse_none, declined.op);
    const call = f.store.getCFStmtImmediate(declined.next).assign_call;
    try testing.expectEqual(f.stays, call.proc);
    try testing.expectEqual(declined.target, GuardedList.at(f.store.getLocalSpan(call.args), 0));
    try testing.expectEqual(f.moves_pack, call.next);
    const frame = f.store.getLocalSpan(moves.frame_locals);
    try testing.expectEqual(@as(usize, 4), moves.frame_locals.len); // x, first, value, declined
    try testing.expectEqual(declined.target, GuardedList.at(frame, 3));
    const stays = f.store.getProcSpecImmediate(f.stays);
    try testing.expect(stays.erased_reuse_arg != .none);

    // The erased callable keeps the input its ABI gives it, and its call to
    // the variant that suspends passes none.
    const worker = f.store.getProcSpecImmediate(f.worker);
    try testing.expectEqual(erased_input, worker.erased_reuse_arg);
    try testing.expectEqual(@as(usize, 3), worker.args.len);
    try testing.expectEqual(@as(usize, 1), f.store.getCFStmtImmediate(f.worker_call).assign_call.args.len);
}

test "procedures that never suspend keep their reuse inputs" {
    var f = try Fixture.init(.never);
    defer f.deinit();
    const stmts = f.store.cfStmtCount();
    try run(testing.allocator, &f.store);
    try testing.expectEqual(stmts, f.store.cfStmtCount());
    try testing.expect(f.store.getProcSpecImmediate(f.moves).erased_reuse_arg != .none);
    try testing.expectEqual(@as(usize, 2), f.store.getCFStmtImmediate(f.worker_call).assign_call.args.len);
    try testing.expect(f.store.stmtRow(f.store.getCFStmtImmediate(f.moves_pack).assign_packed_erased_fn.data).reuse != .none);
}
