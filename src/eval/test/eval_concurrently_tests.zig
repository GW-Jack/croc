//! Concurrent plan builder and flatten tests (design.md "Plans And Concurrent Loops").
//!
//! `Concurrently(a)` is opaque, so the builder tests observe a plan only
//! through `Concurrently.flatten`, the function the loop lowering calls. The
//! library tests run `Concurrently.all!`, `all_ok!` and the `Concurrent`
//! functions under both lowering strategies, where their loops take the
//! sequential form: an entry that would crash if it started shows it never did.

const TestCase = @import("parallel_runner.zig").TestCase;

/// Plan builder, flatten and library cases shared by the evaluator backends.
pub const tests = builder_tests ++ underBothStrategies(&library_tests);

const builder_tests = [_]TestCase{
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

// design.md "Plans And Concurrent Loops", "The library.": each case runs under
// `.lss` and `.boxy`.
const library_tests = [_]TestCase{
    .{
        .name = "Concurrently.all! returns the results in input order, and limits and shields change nothing",
        .source =
        \\List.concurrently([|| 10.U64, || 20]).limit(1).concat(List.concurrently([|| 30, || 40]).shielded()).limit(2).all!()
        ,
        .expected = .{ .inspect_str = "[10, 20, 30, 40]" },
    },
    .{
        .name = "Concurrently.all! leaves out background results, and a background entry after the others never starts",
        .source =
        \\List.concurrently([|| 1.U64]).background().concat(List.concurrently([|| 2, || 3])).concat(List.concurrently([|| crash "a background entry after the others started"]).background()).all!()
        ,
        .expected = .{ .inspect_str = "[2, 3]" },
    },
    .{
        .name = "Concurrently.all! leaves out every entry of a background plan's limits, shields and concats",
        .source =
        \\{
        \\    background = List.concurrently([|| 1.U64, || 2]).limit(1).concat(List.concurrently([|| 3]).shielded()).background()
        \\    List.concurrently([|| 4]).concat(background).concat(List.concurrently([|| 5, || 6])).all!()
        \\}
        ,
        .expected = .{ .inspect_str = "[4, 5, 6]" },
    },
    .{
        .name = "Concurrently.all! of an empty plan is empty",
        .source =
        \\{
        \\    empty : List(() => Str)
        \\    empty = []
        \\    List.concurrently(empty).all!()
        \\}
        ,
        .expected = .{ .inspect_str = "[]" },
    },
    .{
        .name = "Concurrent.all! is List.concurrently(fs).all!()",
        .source =
        \\Concurrent.all!([|| "a", || "b", || "c"])
        ,
        .expected = .{ .inspect_str = "[\"a\", \"b\", \"c\"]" },
    },
    .{
        .name = "Concurrently.all_ok! returns every Ok in input order and leaves out a background Err",
        .source =
        \\List.concurrently([|| Err("background")]).background().concat(List.concurrently([|| Ok(1.U64), || Ok(2)]).limit(1)).all_ok!()
        ,
        .expected = .{ .inspect_str = "Ok([1, 2])" },
    },
    .{
        .name = "Concurrent.all_ok! returns the first Err and the entries after it never start",
        .source =
        \\Concurrent.all_ok!([|| Ok(1.U64), || Err("second"), || crash "an entry after the first Err started", || Err("fourth")])
        ,
        .expected = .{ .inspect_str = "Err(\"second\")" },
    },
    .{
        .name = "Concurrent.race! returns its first function's result and the others never start",
        .source =
        \\Concurrent.race!(|| 7.U64, [|| crash "a second racer started", || crash "a third racer started"])
        ,
        .expected = .{ .inspect_str = "7" },
    },
    .{
        .name = "Concurrent.race! with no other functions returns the first one's result",
        .source =
        \\Concurrent.race!(|| "only", [])
        ,
        .expected = .{ .inspect_str = "\"only\"" },
    },
    .{
        .name = "Concurrent.supervise! returns its function's result",
        .source =
        \\Concurrent.supervise!({ max_restarts: 3 }, || Concurrent.supervise!({ max_restarts: 0 }, || "inner").concat(" outer"))
        ,
        .expected = .{ .inspect_str = "\"inner outer\"" },
    },
    .{
        .name = "Concurrent.both! returns both results",
        .source =
        \\Concurrent.both!(|| 1.U64, || "two")
        ,
        .expected = .{ .inspect_str = "(1, \"two\")" },
    },
};

fn underBothStrategies(comptime cases: []const TestCase) [cases.len * 2]TestCase {
    var result: [cases.len * 2]TestCase = undefined;
    for (cases, 0..) |case, i| {
        result[2 * i] = case;
        result[2 * i].name = case.name ++ " (lss)";
        result[2 * i].specialization_strategy = .lss;
        result[2 * i + 1] = case;
        result[2 * i + 1].name = case.name ++ " (boxy)";
        result[2 * i + 1].specialization_strategy = .boxy;
    }
    return result;
}
