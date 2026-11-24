//! Concurrent plan builder and flatten tests (design.md "Plans And Concurrent Loops").
//!
//! `Concurrently(a)` is opaque, so these tests observe a plan only through
//! `Concurrently.flatten`, the function the loop lowering calls.

const TestCase = @import("parallel_runner.zig").TestCase;

/// Plan builder and flatten cases shared by the evaluator backends.
pub const tests = [_]TestCase{
    .{
        .name = "Concurrently.flatten of List.concurrently keeps the entries in input order",
        .source =
        \\{
        \\    flat = List.concurrently([|| 10.U64, || 20, || 30]).flatten()
        \\    var $results = []
        \\    for entry in flat.entries {
        \\        $results = $results.append(entry())
        \\    }
        \\    ($results, flat.limit_paths, flat.shielded, flat.background, flat.limits, flat.root_limit)
        \\}
        ,
        .expected = .{ .inspect_str = "([10, 20, 30], [[], [], []], [False, False, False], [False, False, False], [], 0)" },
    },
    .{
        .name = "Concurrently.concat puts the first plan's entries before the second's",
        .source =
        \\{
        \\    first = List.concurrently([|| "a", || "b"]).concat(List.concurrently([|| "c"]))
        \\    flat = first.concat(List.concurrently([])).concat(List.concurrently([|| "d"])).flatten()
        \\    var $results = []
        \\    for entry in flat.entries {
        \\        $results = $results.append(entry())
        \\    }
        \\    ($results, flat.limit_paths.len(), flat.shielded.len(), flat.background.len(), flat.root_limit)
        \\}
        ,
        .expected = .{ .inspect_str = "([\"a\", \"b\", \"c\", \"d\"], 4, 4, 4, 0)" },
    },
    .{
        .name = "Concurrently.flatten numbers limits in preorder and paths list them outermost first",
        .source =
        \\{
        \\    inner = List.concurrently([|| 2.U64]).limit(1).limit(3)
        \\    flat = List.concurrently([|| 1.U64]).limit(4).concat(inner).limit(2).flatten()
        \\    (flat.limits, flat.limit_paths, flat.root_limit)
        \\}
        ,
        .expected = .{ .inspect_str = "([2, 4, 3, 1], [[0, 1], [0, 2, 3]], 1)" },
    },
    .{
        .name = "Concurrently.flatten gives a root limit only when the outermost node is a limit",
        .source =
        \\{
        \\    plan = List.concurrently([|| 1.U64]).limit(2)
        \\    (plan.flatten().root_limit, plan.shielded().flatten().root_limit, plan.background().flatten().root_limit, plan.concat(plan).flatten().root_limit)
        \\}
        ,
        .expected = .{ .inspect_str = "(1, 0, 0, 0)" },
    },
    .{
        .name = "Concurrently.shielded and background mark only the entries they wrap",
        .source =
        \\{
        \\    plain = List.concurrently([|| 1.U64])
        \\    flat = plain.concat(plain.shielded()).concat(plain.background()).concat(plain.shielded().background().limit(5)).flatten()
        \\    (flat.shielded, flat.background, flat.limit_paths)
        \\}
        ,
        .expected = .{ .inspect_str = "([False, True, False, True], [False, False, True, True], [[], [], [], [0]])" },
    },
    .{
        .name = "Concurrently.limit crashes on a limit of zero",
        .source =
        \\List.concurrently([|| 1.U64]).limit(0).flatten().limits
        ,
        .expected = .{ .crash = {} },
    },
};
