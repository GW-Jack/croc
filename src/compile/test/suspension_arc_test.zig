//! ARC's rules for procedures that may suspend (design.md "The Continuation
//! Pass"): such a procedure returns an owned result even where the same
//! body without a suspension site would return a borrow of its argument.

const std = @import("std");
const layout = @import("layout");
const lir = @import("lir");

const harness = @import("lower_to_lir_harness.zig");

const Seen = struct {
    after_fetch: ?struct { suspends: lir.LIR.Suspends, ret_borrowed: bool } = null,
    after_log: ?struct { suspends: lir.LIR.Suspends, ret_borrowed: bool } = null,
};

var seen: Seen = .{};

fn collect(store: *const lir.LirStore, _: *const layout.Store) harness.LowerToLirHarnessError!void {
    seen = .{};
    for (0..store.getProcSpecs().len) |index| {
        const proc_id: lir.LIR.LirProcSpecId = @fromBackingInt(@intCast(index));
        const proc = store.getProcSpec(proc_id);
        const name = store.procDebugName(proc_id) orelse continue;
        if (std.mem.eql(u8, name, "keep_after_fetch!")) seen.after_fetch = .{ .suspends = proc.suspends, .ret_borrowed = proc.rc_ret_borrowed };
        if (std.mem.eql(u8, name, "keep_after_log!")) seen.after_log = .{ .suspends = proc.suspends, .ret_borrowed = proc.rc_ret_borrowed };
    }
}

test "a procedure that may suspend returns an owned result" {
    try harness.runAppPathLirInspection(
        "test/postcheck/suspension_arc/app.roc",
        .{ .inline_mode = .none },
        collect,
    );
    const after_log = seen.after_log orelse return error.TestUnexpectedResult;
    const after_fetch = seen.after_fetch orelse return error.TestUnexpectedResult;
    // Without a suspension site, returning the argument returns a borrow.
    try std.testing.expectEqual(lir.LIR.Suspends.never, after_log.suspends);
    try std.testing.expect(after_log.ret_borrowed);
    try std.testing.expectEqual(lir.LIR.Suspends.may, after_fetch.suspends);
    try std.testing.expect(!after_fetch.ret_borrowed);
}

var list_counts: struct { plain: usize, atomic: usize } = .{ .plain = 0, .atomic = 0 };

/// The counts of `List(U8)` values in `keep_list!` and what the continuation
/// pass made from it.
fn countListUpdates(store: *const lir.LirStore, layouts: *const layout.Store) harness.LowerToLirHarnessError!void {
    list_counts = .{ .plain = 0, .atomic = 0 };
    var stmts = std.ArrayList(lir.LIR.CFStmtId).empty;
    defer stmts.deinit(std.testing.allocator);
    for (0..store.getProcSpecs().len) |index| {
        const proc_id: lir.LIR.LirProcSpecId = @fromBackingInt(@intCast(index));
        const name = store.procDebugName(proc_id) orelse continue;
        if (!std.mem.startsWith(u8, name, "keep_list!")) continue;
        const body = store.getProcSpec(proc_id).body.get() orelse continue;
        try lir.ArcSolve.collectProcStatements(std.testing.allocator, store, body, &stmts);
        for (stmts.items) |stmt_id| {
            const stmt = store.getCFStmt(stmt_id);
            const value, const atomicity = if (stmt == .incref)
                .{ stmt.incref.value, stmt.incref.atomicity }
            else if (stmt == .decref)
                .{ stmt.decref.value, stmt.decref.atomicity }
            else
                continue;
            if (layouts.getLayout(store.getLocal(value).layout_idx).tag != .list) continue;
            switch (atomicity) {
                .single_thread => list_counts.plain += 1,
                .atomic => list_counts.atomic += 1,
            }
        }
    }
}

test "a list only one task holds is counted without atomics across its pauses" {
    try harness.runAppPathLirInspection(
        "test/postcheck/suspension_arc/app.roc",
        .{ .inline_mode = .none, .thread_confined_rc = true },
        countListUpdates,
    );
    try std.testing.expect(list_counts.plain > 0);
    try std.testing.expectEqual(@as(usize, 0), list_counts.atomic);
}
