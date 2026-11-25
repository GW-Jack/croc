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
    /// The helpers' task forms under `.boxy` (design.md "Plans And
    /// Concurrent Loops", "Promotion."), which no other lowering calls.
    task_create,
    task_next,
    task_spawn,
    task_cancel,
    task_supervised,
    cell_lock,
    cell_wait,
    cell_settle,
    cell_tracked,
    cell_track,
    cleanup_push,
    cleanup_pop,

    /// The helper that is this one's task form, `none` if it has none.
    pub fn taskForm(self: RunningSetHelper) RunningSetHelper {
        return switch (self) {
            .run_create => .task_create,
            .run_next => .task_next,
            .run_spawn => .task_spawn,
            .run_cancel => .task_cancel,
            .run_supervised => .task_supervised,
            .none, .run_entry, .run_arrived, .run_ended => .none,
            .task_create, .task_next, .task_spawn, .task_cancel, .task_supervised => .none,
            .cell_lock, .cell_wait, .cell_settle, .cell_tracked, .cell_track, .cleanup_push, .cleanup_pop => .none,
        };
    }
};

/// The loop id of every supervised set. Monotype mints it for no loop
/// (design.md "Plans And Concurrent Loops", "Supervision.").
pub const supervised_loop_id: u64 = std.math.maxInt(i64);
