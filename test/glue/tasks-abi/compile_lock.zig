//! ABI lock for the task ABI in generated Zig glue (design.md "Host
//! Contract", "Glue").
//!
//! The build generates `roc_platform_abi.zig` for test/tasks-platform, a
//! `concurrency: Tasks` platform, and compiles this root against it (as
//! `glue_abi`) and the canonical `builtins` definitions on every lock target.
//! Drift between the ZigGlue template's task declarations and the runtime
//! that defines them is a compile error here.

const std = @import("std");
const builtins = @import("builtins");
const abi = @import("glue_abi");

const task = builtins.task;
const shim_symbols = builtins.shim_symbols;

/// This compile-only object has no host runtime; safety failures trap on every target.
pub const panic = std.debug.no_panic;

const Task = *abi.RocTask;

comptime {
    lockEnum("RocTaskStatus", abi.RocTaskStatus, task.Status);
    lockPoll();
    lockRuntimeCalls();
    lockHostedShapes();
    lockProvidedShape();
}

/// `Generated` is a 32-bit C enum with exactly `Canonical`'s tags, in order
/// from 0, as `roc_task_resume` returns `Canonical` widened to `u32`.
fn lockEnum(comptime what: []const u8, comptime Generated: type, comptime Canonical: type) void {
    if (std.meta.Tag(Generated) != u32) @compileError("generated " ++ what ++ " is not a 32-bit enum");
    const generated = @typeInfo(Generated).@"enum".field_names;
    const canonical = @typeInfo(Canonical).@"enum".field_names;
    if (generated.len != canonical.len) @compileError("generated " ++ what ++ " tag count differs from builtins");
    inline for (generated, canonical, 0..) |g, c, index| {
        if (!std.mem.eql(u8, g, c)) @compileError("generated " ++ what ++ "." ++ g ++ " is not builtins ." ++ c);
        if (@backingInt(@field(Generated, g)) != index or @backingInt(@field(Canonical, c)) != index)
            @compileError("generated " ++ what ++ "." ++ g ++ " value differs from builtins");
    }
}

/// `RocPoll` is what a suspending hosted function returns; the continuation
/// pass treats 0 as finished and anything else as pending.
fn lockPoll() void {
    if (std.meta.Tag(abi.RocPoll) != u32) @compileError("generated RocPoll is not a 32-bit enum");
    if (@typeInfo(abi.RocPoll).@"enum".field_names.len != 2 or
        @backingInt(abi.RocPoll.ready) != 0 or @backingInt(abi.RocPoll.pending) != 1)
        @compileError("generated RocPoll must be ready = 0, pending = 1");
}

/// Each runtime call is declared under its canonical symbol name with the
/// type the runtime defines it with, the task pointer standing for
/// `*builtins.task.RocTask`.
fn lockRuntimeCalls() void {
    expectFn(shim_symbols.roc_task_resume, fn (Task) callconv(.c) abi.RocTaskStatus);
    if (@TypeOf(task.host_calls.resumeTask) != fn (*task.RocTask) callconv(.c) std.meta.Tag(abi.RocTaskStatus))
        @compileError("builtins roc_task_resume changed: update the glue templates and this lock");

    expectFn(shim_symbols.roc_task_free, fn (Task) callconv(.c) void);
    if (@TypeOf(task.host_calls.free) != fn (*task.RocTask) callconv(.c) void)
        @compileError("builtins roc_task_free changed: update the glue templates and this lock");

    expectFn(shim_symbols.roc_task_crash_message, fn (Task, *usize) callconv(.c) [*]const u8);
    if (@TypeOf(task.host_calls.crashMessage) != fn (*task.RocTask, *usize) callconv(.c) [*]const u8)
        @compileError("builtins roc_task_crash_message changed: update the glue templates and this lock");

    // The program's wake and cancel take only the task; the runtime calls
    // the host's ready and abort through these pointer types.
    expectFn(shim_symbols.roc_task_wake, fn (Task) callconv(.c) void);
    expectFn(shim_symbols.roc_task_cancel, fn (Task) callconv(.c) void);
    expectFn(shim_symbols.roc_task_ready, fn (Task) callconv(.c) void);
    expectFn(shim_symbols.roc_task_abort, fn (Task) callconv(.c) void);
    if (task.ReadyFn != *const fn (*task.RocTask) callconv(.c) void or
        task.AbortFn != *const fn (*task.RocTask) callconv(.c) void)
        @compileError("builtins roc_task_ready or roc_task_abort changed: update the glue templates and this lock");
}

/// A suspending hosted function takes the task and its result pointer first
/// and returns `RocPoll`; the pointer is untyped when the result has no
/// bytes. One without the marker keeps its natural signature.
fn lockHostedShapes() void {
    expectFn("roc_tasks_file_read_utf8", fn (Task, *abi.FileRead_utf8Result, abi.RocStr) callconv(.c) abi.RocPoll);
    expectFn("roc_tasks_stdin_line", fn (Task, *abi.RocStr) callconv(.c) abi.RocPoll);
    expectFn("roc_tasks_scheduler_yield", fn (Task, *anyopaque) callconv(.c) abi.RocPoll);
    expectFn("roc_tasks_sleep_millis", fn (Task, *anyopaque, u64) callconv(.c) abi.RocPoll);
    expectFn("roc_tasks_stdout_line", fn (abi.RocStr) callconv(.c) void);
    expectFn("roc_tasks_clock_monotonic_ns", fn () callconv(.c) u64);
}

/// A provided procedure takes its result pointer last and returns its task.
fn lockProvidedShape() void {
    expectFn("roc_main", fn (*i32) callconv(.c) Task);
}

fn expectFn(comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(abi, name)) @compileError("generated glue is missing extern " ++ name);
    if (@TypeOf(@field(abi, name)) != Expected)
        @compileError("generated extern " ++ name ++ " has the wrong signature: " ++ @typeName(@TypeOf(@field(abi, name))));
}
