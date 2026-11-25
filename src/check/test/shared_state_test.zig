//! What a type that crosses the host boundary may hold of shared state
//! (design.md "Shared State"): no handle, wherever it is.

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
