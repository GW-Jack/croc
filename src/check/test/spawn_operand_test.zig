//! A `spawn` operand is stored in the loop's running set. A closed lambda is
//! generalized where it is written, so the spawned entry is an instance of it:
//! unifying the loop's item type with the lambda's own scheme would generalize
//! the item, and everything unified with it.
const TestEnv = @import("TestEnv.zig");

test "spawn of a closed lambda does not generalize the loop's item type" {
    const source =
        \\Name := [Anon, Id(U64)].{
        \\    text : Name -> Str
        \\    text = |_| ""
        \\
        \\    run! : Name => Try(Str, Str)
        \\    run! = |name| {
        \\        plan : Concurrently(Str)
        \\        plan = List.concurrently([])
        \\        for! _ in plan {
        \\            spawn || "a"
        \\        }
        \\        Ok(name.text())
        \\    }
        \\}
    ;
    var env = try TestEnv.init("Name", source);
    defer env.deinit();
    try env.assertNoErrors();
}
