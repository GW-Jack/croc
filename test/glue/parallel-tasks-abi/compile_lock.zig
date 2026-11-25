//! ABI lock for what generated Zig glue adds for a `ParallelTasks` platform
//! (design.md "Host Contract", "Glue").
//!
//! The build generates `roc_platform_abi.zig` for test/parallel-tasks-platform
//! and compiles this root against it (as `glue_abi`) and the canonical
//! `builtins` definitions on every lock target. test/glue/tasks-abi locks the
//! declarations that every mode with tasks has.

const std = @import("std");
const builtins = @import("builtins");
const abi = @import("glue_abi");

const task = builtins.task;
const shim_symbols = builtins.shim_symbols;

/// This compile-only object has no host runtime; safety failures trap on every target.
pub const panic = std.debug.no_panic;

const Task = *abi.RocTask;

comptime {
    expectFn(shim_symbols.roc_task_thread_slot, fn () callconv(.c) *?Task);
    if (task.ThreadSlotFn != *const fn () callconv(.c) *?*task.RocTask)
        @compileError("builtins roc_task_thread_slot changed: update the glue templates and this lock");

    expectFn(shim_symbols.roc_task_resume, fn (Task) callconv(.c) abi.RocTaskStatus);
    if (@TypeOf(task.RocTask.resumeParallelFromHost) != fn (*task.RocTask, task.ReadyFn, task.AbortFn, task.ThreadSlotFn) task.Status)
        @compileError("builtins roc_task_resume changed: update the glue templates and this lock");
    expectFn("roc_parallel_sleep_millis", fn (Task, *anyopaque, u64) callconv(.c) abi.RocPoll);
    expectFn("roc_main", fn (*i32) callconv(.c) Task);
}

fn expectFn(comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(abi, name)) @compileError("generated glue is missing extern " ++ name);
    if (@TypeOf(@field(abi, name)) != Expected)
        @compileError("generated extern " ++ name ++ " has the wrong signature: " ++ @typeName(@TypeOf(@field(abi, name))));
}
