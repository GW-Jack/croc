//! `List.map` may write its output into its input's allocation only when both
//! items have the same layout. The output item's closures may capture values
//! that reach the returned list from elsewhere, so its layout must come from
//! the returned list, never from the transform: optimized lowering gives each
//! reference to a known transform an instance of its own. This test maps to an
//! item that is the input item's size without those captures and larger with
//! them, and requires the reuse check to be answered at compile time.

const std = @import("std");
const layout = @import("layout");
const lir = @import("lir");
const harness = @import("lower_to_lir_harness.zig");

/// Both maps in the source change their item's layout, so LIR lowering answers
/// each reuse check itself and none reaches the backends.
fn expectNoReuseCheck(store: *const lir.LirStore, _: *const layout.Store) harness.LowerToLirHarnessError!void {
    for (0..store.cfStmtCount()) |index| {
        const stmt = store.getCFStmt(@fromBackingInt(@intCast(index)));
        if (stmt != .assign_low_level) continue;
        try std.testing.expect(stmt.assign_low_level.op != .list_map_can_reuse);
    }
}

const larger_elsewhere =
    \\Cell : [Plain(Str), Captured(Str, ({} -> Str))]
    \\
    \\cell : { label : Str, n : U64 } -> Cell
    \\cell = |row| Plain(row.label)
    \\
    \\said : Cell -> Str
    \\said = |each|
    \\    match each {
    \\        Plain(text) => text
    \\        Captured(label, press) => "${label}: ${press({})}"
    \\    }
    \\
    \\main! = |args| {
    \\    rows = [{ label: "a", n: 1 }, { label: "b", n: 2 }].keep_if(|row| row.n > args.len())
    \\    count = args.len().to_str()
    \\    cells = rows.map(cell).concat([Captured("args", |{}| "pressed ${count}")])
    \\    match Str.join_with(cells.map(said), ", ") {
    \\        "" => Err(Exit(1))
    \\        _ => Ok({})
    \\    }
    \\}
;

test "List.map copies when a capture from elsewhere makes the output item larger" {
    try harness.expectLirInspectionWithOptions(larger_elsewhere, .{ .list_in_place_map = true, .inline_mode = .wrappers }, expectNoReuseCheck);
}
