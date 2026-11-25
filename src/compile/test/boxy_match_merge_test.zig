//! A match carries out the variables it reassigns, but not one its scrutinee
//! declares. That one is bound by the time Boxy compiles the match's branches,
//! to a local of a branch inside the scrutinee, where nothing after the
//! scrutinee can read it.

const harness = @import("lower_to_lir_harness.zig");

const app_body =
    \\run = |args| {
    \\    thunk = Box.box(|| {
    \\        var $name = match ({
    \\            size = if args.is_empty() {
    \\                var $text = Str.join_with(args, " ")
    \\                if Str.is_empty($text) {
    \\                    $text = Str.join_with(args, ",")
    \\                }
    \\                Str.count_utf8_bytes($text)
    \\            } else {
    \\                3
    \\            }
    \\            size
    \\        }) {
    \\            3 => "three"
    \\            n => U64.to_str(n)
    \\        }
    \\        $name
    \\    })
    \\    Box.unbox(thunk)()
    \\}
    \\
    \\main! = |args| {
    \\    echo!(run(args))
    \\    Ok({})
    \\}
;

test "a match merges no variable its scrutinee declares" {
    inline for (.{ .boxy, .lss }) |strategy| {
        try harness.expectLowersToLirWithOptions(app_body, .{ .specialization_strategy = strategy });
    }
}
