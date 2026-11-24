//! The Builtin running-set helpers a `for!` loop over a plan lowers to.

/// Which Builtin running-set helper a definition is (design.md "Plans And
/// Concurrent Loops", "Sequential lowering."). Canonicalization of the Builtin
/// module records it per definition; every Monotype specialization of the
/// definition carries it, which keeps the helper out of inlining and marks its LIR
/// procedure (`LIR.RunningSetHelper`). `none` is every other definition.
pub const RunningSetHelper = enum(u8) {
    none,
    run_create,
    run_next,
    run_spawn,
    run_cancel,
    run_entry,
    run_arrived,
    run_ended,
};
