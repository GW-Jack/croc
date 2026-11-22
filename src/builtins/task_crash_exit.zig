//! The jump routines of a task's crash exit (design.md "The Task Runtime").
//!
//! A builtins object built for one target takes `src/sljmp`'s naked
//! routines, which need no C library, so a platform links nothing new. The
//! LLVM builtins bitcode is compiled for wasm64 and retargeted, so it cannot
//! know its target's routines; the program gets them from the per-target
//! private runtime (`llvm_private_runtime.zig`) with internal linkage.
//! `roc_task_setjmp` there is the target's setjmp itself, never a wrapper
//! around it: the context it saves must be the caller's frame, which a
//! wrapper's return would leave.

const std = @import("std");
const builtin = @import("builtin");
const sljmp = @import("sljmp");

/// The jump buffer a task keeps, as large as the largest `src/sljmp` buffer,
/// so `RocTask`'s layout is the same for every target.
pub const Buffer = extern struct {
    bytes: [256]u8 align(16),
};

const linked = builtin.cpu.arch == .wasm64;

/// Whether this target has naked jump routines: the targets `src/sljmp`
/// supports, on the two architectures its naked routines cover.
pub const native = !linked and sljmp.supported and
    (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);

comptime {
    if (native and (@sizeOf(sljmp.naked.JmpBuf) > @sizeOf(Buffer) or @alignOf(sljmp.naked.JmpBuf) > @alignOf(Buffer))) {
        @compileError("task_crash_exit.Buffer is smaller than this target's naked jump buffer");
    }
}

const linked_routines = struct {
    extern fn roc_task_crash_exits() callconv(.c) bool;
    extern fn roc_task_setjmp(buf: *Buffer) callconv(.c) c_int;
    extern fn roc_task_longjmp(buf: *Buffer) callconv(.c) noreturn;
};

/// Whether this program's target can take a crash exit. Without one, a
/// crash inside a task ends the process.
pub fn available() bool {
    if (comptime linked) return linked_routines.roc_task_crash_exits();
    return native;
}

/// Save the caller's context in `buf`. Returns 0, and 1 when a crash
/// jumps back. Only called when `available()`.
pub inline fn save(buf: *Buffer) c_int {
    if (comptime linked) return linked_routines.roc_task_setjmp(buf);
    if (comptime !native) unreachable; // only called when available()
    const setjmp: *const fn (*Buffer) callconv(.c) c_int = @ptrCast(sljmp.naked.setjmp_routine);
    return setjmp(buf);
}

/// Jump back to the context `buf` saved, making its `save` return 1.
pub fn jump(buf: *Buffer) noreturn {
    if (comptime linked) linked_routines.roc_task_longjmp(buf);
    if (comptime !native) unreachable; // only called when available()
    sljmp.naked.longjmp(@ptrCast(buf), 1);
}

/// The definitions of the three routines the linked builtins call, for the
/// target this file is compiled for: the private runtime exports them into
/// an LLVM object, and the compiler's relocatable loader binds an object it
/// loads into its own process to them (`resolveLinked`).
pub const linked_definitions = struct {
    pub fn crashExits() callconv(.c) bool {
        return native;
    }

    /// `roc_task_setjmp`: the target's naked setjmp itself, or a stand-in
    /// that is never called where there are no crash exits.
    pub const setjmp = if (native) sljmp.naked.setjmp_routine else &noSetjmp;

    fn noSetjmp(_: *Buffer) callconv(.c) c_int {
        return 0;
    }

    pub fn longjmp(buf: *Buffer) callconv(.c) noreturn {
        if (comptime !native) unreachable; // callers check roc_task_crash_exits first
        sljmp.naked.longjmp(@ptrCast(buf), 1);
    }
};

/// The address of the linked routine `name` names, if it is one of the
/// three.
pub fn resolveLinked(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "roc_task_crash_exits")) return @intFromPtr(&linked_definitions.crashExits);
    if (std.mem.eql(u8, name, "roc_task_setjmp")) return @intFromPtr(linked_definitions.setjmp);
    if (std.mem.eql(u8, name, "roc_task_longjmp")) return @intFromPtr(&linked_definitions.longjmp);
    return null;
}
