//! The Builtin running-set helpers a `for!` loop over a plan lowers to, and
//! the ones `Concurrent.supervise!` and `Shared.update!` call.

const std = @import("std");

/// Which Builtin running-set helper a definition is (design.md "Plans And
/// Concurrent Loops", "Sequential lowering." and "Supervision."; "Shared
/// State", "Waiting.").
/// Canonicalization of the Builtin module records it per definition; every
/// Monotype specialization of the definition carries it, which keeps the
/// helper out of inlining and marks its LIR procedure
/// (`LIR.RunningSetHelper`). `none` is every other definition.
pub const RunningSetHelper = enum(u8) {
    none,
    run_create,
    run_next,
    run_spawn,
    run_cancel,
    run_entry,
    run_arrived,
    run_ended,
    run_supervised,
    cell_lock,
    cell_wait,
    cell_settle,
    cleanup_push,
    cleanup_pop,
};

/// The loop id of every supervised set. Monotype mints it for no loop
/// (design.md "Plans And Concurrent Loops", "Supervision.").
pub const supervised_loop_id: u64 = std.math.maxInt(i64);
