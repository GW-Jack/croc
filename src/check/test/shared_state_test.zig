//! Shared state (design.md "Shared State"): a type that crosses the host
//! boundary holds no handle, wherever it is, and the three warnings.

const std = @import("std");
const TestEnv = @import("TestEnv.zig");

test "no type that crosses the host boundary holds a handle to shared state" {
    const Case = struct { ty: []const u8, valid: bool };
    const cases = [_]Case{
        .{ .ty = "Shared(U64)", .valid = false },
        .{ .ty = "{ name : Str, count : Shared(U64) }", .valid = false },
        .{ .ty = "List(Shared(U64))", .valid = false },
        .{ .ty = "[Done, Running(Shared(U64))]", .valid = false },
        // A host that only holds a value holds the handles in it too.
        .{ .ty = "Box(Shared(U64))", .valid = false },
        .{ .ty = "Box(Model)", .valid = false },
        .{ .ty = "Box(Generic(Shared(U64)))", .valid = false },
        .{ .ty = "Box(Shared(U64) -> U64)", .valid = false },
        .{ .ty = "Box(Generic(U64))", .valid = true },
    };
    for (cases) |case| {
        const provided = try std.fmt.allocPrint(std.testing.allocator,
            \\platform ""
            \\    requires {{}} {{}}
            \\    exposes []
            \\    packages {{}}
            \\    provides {{ "roc_entry": entry }}
            \\
            \\Model := {{ count : Shared(U64) }}
            \\Generic(a) := {{ value : a }}
            \\
            \\entry : ({s}) -> U64
            \\entry = |_x| ...
        , .{case.ty});
        defer std.testing.allocator.free(provided);
        var provides = try TestEnv.init("Test", provided);
        defer provides.deinit();
        errdefer std.debug.print("provided case: {s}\n", .{provided});
        if (case.valid) try provides.assertNoErrors() else try provides.assertOneTypeError("Host Boundary Forbids Shared State");

        const hosted = try std.fmt.allocPrint(std.testing.allocator,
            \\Effect := [].{{
            \\    Model := {{ count : Shared(U64) }}
            \\    Generic(a) := {{ value : a }}
            \\    call! : ({s}) => U64
            \\}}
        , .{case.ty});
        defer std.testing.allocator.free(hosted);
        var effect = try TestEnv.initHosted("Effect", hosted);
        defer effect.deinit();
        errdefer std.debug.print("hosted case: {s}\n", .{hosted});
        if (case.valid) try effect.assertNoErrors() else try effect.assertOneTypeError("Host Boundary Forbids Shared State");
    }
}

const Warning = enum { unshared, lost, pause };

fn expectWarnings(body: []const u8, expected: []const Warning) TestEnv.TestEnvError!void {
    const source = try std.mem.concat(std.testing.allocator, u8, &.{
        \\Sem :: {}.{}
        \\
        \\tick! : () => {}
        \\tick! = || ...
        \\
        \\use! : Shared(U64) => {}
        \\use! = |handle| handle.modify!(|n| n + 1)
        \\
        \\main! : Shared(U64) => U64
        \\main! = |h|
        \\
        ,
        body,
        "\n",
    });
    defer std.testing.allocator.free(source);
    var env = try TestEnv.init("Test", source);
    defer env.deinit();
    errdefer std.debug.print("case:\n{s}\n", .{source});
    var titles: [4][]const u8 = undefined;
    for (expected, titles[0..expected.len]) |warning, *title| title.* = switch (warning) {
        .unshared => "Unshared State",
        .lost => "Lost Update",
        .pause => "Pause Before Cleanup",
    };
    try env.assertOnlyTypeWarnings(titles[0..expected.len]);
}

test "state that only one function uses is warned about" {
    try expectWarnings(
        \\{
        \\    seen = Shared.new!(0)
        \\    seen.modify!(|n| n + 1)
        \\    if h.get!() > 3 { Shared.modify!(seen, |n| n + 1) }
        \\    seen.get!()
        \\}
    , &.{.unshared});
    // Passed, captured, stored, returned as a part, and renamed.
    for ([_][]const u8{
        \\{
        \\    seen = Shared.new!(0)
        \\    use!(seen)
        \\    seen.get!()
        \\}
        ,
        \\{
        \\    seen = Shared.new!(0)
        \\    run! = || seen.get!()
        \\    run!()
        \\}
        ,
        \\{
        \\    seen = Shared.new!(0)
        \\    parts = [seen]
        \\    parts.len()
        \\}
        ,
        \\{
        \\    seen = Shared.new!(0)
        \\    same = seen
        \\    same.get!()
        \\}
        ,
        \\{
        \\    seen = Shared.new!(0)
        \\    Concurrent.both!(|| seen.get!(), || seen.get!()).0
        \\}
        ,
    }) |body| try expectWarnings(body, &.{});
}

test "an update that stores a value from an earlier read is warned about" {
    for ([_][]const u8{
        \\{
        \\    n = h.get!()
        \\    h.modify!(|_| n - 1)
        \\    n
        \\}
        ,
        \\{
        \\    less = Shared.get!(h) - 1
        \\    (smaller, _) = (less - 1, 0)
        \\    Shared.modify!(h, |_state| smaller)
        \\    smaller
        \\}
        ,
        \\{
        \\    n = h.get!()
        \\    h.update!(|_| if n > 3 { Set(n - 1, n) } else { Keep(0) })
        \\}
        ,
    }) |body| try expectWarnings(body, &.{.lost});
    for ([_][]const u8{
        // It uses the state.
        \\{
        \\    n = h.get!()
        \\    h.modify!(|m| m + n)
        \\    n
        \\}
        ,
        // What it stores is not from the read.
        \\{
        \\    n = h.get!()
        \\    if n > 3 { h.modify!(|_| 0) }
        \\    n
        \\}
        ,
        // Only its answer is.
        \\{
        \\    n = h.get!()
        \\    h.update!(|_| Set(0, n))
        \\}
        ,
        // The read is of other state.
        \\{
        \\    other = Shared.new!(3)
        \\    use!(other)
        \\    n = other.get!()
        \\    h.modify!(|_| n)
        \\    n
        \\}
        ,
    }) |body| try expectWarnings(body, &.{});
}

test "a call that may pause between an update and its cleanup is warned about" {
    for ([_][]const u8{
        \\{
        \\    h.modify!(|n| n)
        \\    h.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
        \\    tick!()
        \\    h.finally!(|n| n + 1, || 3)
        \\}
        ,
        \\{
        \\    h.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
        \\    if h.get!() > 3 { tick!() }
        \\    h.on_failure!(|n| n + 1, || 3)
        \\}
        ,
        \\{
        \\    h.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
        \\    if h.get!() > 3 { {} } else { tick!() }
        \\    h.on_failure!(|n| n + 1, || 3)
        \\}
        ,
        \\match h.update!(|n| if n == 0 { Keep(Full) } else { Set(n - 1, Took) }) {
        \\    Full => 0
        \\    Took => {
        \\        tick!()
        \\        h.finally!(|n| n + 1, || 3)
        \\    }
        \\}
        ,
    }) |body| try expectWarnings(body, &.{.pause});
    for ([_][]const u8{
        // Nothing pauses between.
        \\{
        \\    tick!()
        \\    h.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
        \\    _ = h.get!()
        \\    h.finally!(|n| n + 1, || {
        \\        tick!()
        \\        3
        \\    })
        \\}
        ,
        // The pause is on a path that never reaches the cleanup.
        \\match h.update!(|n| if n == 0 { Keep(Full) } else { Set(n - 1, Took) }) {
        \\    Full => {
        \\        tick!()
        \\        0
        \\    }
        \\    Took => h.finally!(|n| n + 1, || 3)
        \\}
        ,
        \\{
        \\    match h.update!(|n| if n == 0 { Keep(Full) } else { Set(n - 1, Took) }) {
        \\        Full => {
        \\            tick!()
        \\            return 0
        \\        }
        \\        Took => {}
        \\    }
        \\    h.finally!(|n| n + 1, || 3)
        \\}
        ,
        // The update is undone before.
        \\{
        \\    h.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
        \\    _ = h.finally!(|n| n + 1, || 3)
        \\    tick!()
        \\    h.finally!(|n| n + 1, || 3)
        \\}
        ,
        // The call is in another function.
        \\{
        \\    h.update!(|n| if n == 0 { Wait } else { Set(n - 1, {}) })
        \\    run! = || tick!()
        \\    h.finally!(|n| n + 1, || {
        \\        run!()
        \\        3
        \\    })
        \\}
        ,
    }) |body| try expectWarnings(body, &.{});
}

test "a module that refers to Shared.update! says so" {
    const Case = struct { body: []const u8, refers: bool };
    for ([_]Case{
        .{ .body = "main! : Shared(U64) => U64\nmain! = |h| h.update!(|n| if n == 0 { Wait } else { Set(n - 1, n) })", .refers = true },
        .{ .body = "main! : Shared(U64) => U64\nmain! = |h| Shared.update!(h, |n| Keep(n))", .refers = true },
        .{ .body =
        \\main! : Shared(U64) => U64
        \\main! = |h| {
        \\    f! = Shared.update!
        \\    f!(h, |n| Keep(n))
        \\}
        , .refers = true },
        // Through a requirement its caller fills.
        .{ .body =
        \\change! : a, b => U64 where [a.update! : a, b => U64]
        \\change! = |target, transform| target.update!(transform)
        \\
        \\main! : Shared(U64) => U64
        \\main! = |h| change!(h, |n| Keep(n))
        , .refers = true },
        .{ .body =
        \\change! : a, b => U64 where [a.update! : a, b => U64]
        \\change! = |target, transform| target.update!(transform)
        \\
        \\main! : Shared(U64) => U64
        \\main! = |h| h.get!()
        , .refers = false },
        .{ .body =
        \\main! : Shared(U64) => U64
        \\main! = |h| {
        \\    h.modify!(|n| n + 1)
        \\    h.finally!(|n| n, || h.get!())
        \\}
        , .refers = false },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ "Sem :: {}.{}\n\n", case.body, "\n" });
        defer std.testing.allocator.free(source);
        var env = try TestEnv.init("Test", source);
        defer env.deinit();
        errdefer std.debug.print("case:\n{s}\n", .{source});
        try env.assertNoErrors();
        try std.testing.expectEqual(case.refers, env.module_env.refers_to_shared_update);
    }
}
