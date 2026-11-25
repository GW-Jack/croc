//! The wasm half of the browser reference host (design.md "Host Contract",
//! "Browser hosts."). The scheduler is host.mjs, on JavaScript's event loop.
//! This half has what needs Roc's types: the allocator, the results hosted
//! functions write, and the release of their arguments.
//!
//! The module imports the functions of `js` below, under `env`, and exports
//! the `host_` functions, which host.mjs calls. An operation is named by the
//! task that waits on it, since a task waits on at most one.

const std = @import("std");
const builtins = @import("builtins");
const host_allocator = @import("host_alloc");

const shim_symbols = builtins.shim_symbols;
const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;

const js = struct {
    /// Throws, so that no more of the module runs.
    extern "env" fn js_crashed(ptr: [*]const u8, len: usize) noreturn;
    extern "env" fn js_dbg(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_expect_failed(ptr: [*]const u8, len: usize) void;
    extern "env" fn js_log(ptr: [*]const u8, len: usize) void;
    /// Queue a task to resume. Never resumes it before it returns.
    extern "env" fn js_ready(task: *RocTask) void;
    /// Start an operation, whose end calls `host_wake` or `host_wake_get`.
    extern "env" fn js_sleep(task: *RocTask, millis: f64) void;
    extern "env" fn js_get(task: *RocTask, out: *Fetched, url: [*]const u8, url_len: usize) void;
    /// Abandon the operation a task waits on. Nothing wakes the task for it
    /// afterwards.
    extern "env" fn js_abort(task: *RocTask) void;
};

/// `Try(Str, Str)`.
const Fetched = extern struct {
    payload: RocStr,
    tag: enum(u8) { err = 0, ok = 1 },
};

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    js.js_crashed(msg.ptr, msg.len);
}

const wasm_allocator = std.heap.wasm_allocator;

/// Allocations not freed yet.
var live_allocations: usize = 0;

comptime {
    shim_symbols.exportRuntimeFns(.{
        .alloc = &rocAlloc,
        .dealloc = &rocDealloc,
        .realloc = &rocRealloc,
        .dbg = &rocDbg,
        .expect_failed = &rocExpectFailed,
        .crashed = &rocCrashed,
    }, .default);
    @export(&hostedLog, .{ .name = "roc_browser_console_log", .visibility = .hidden });
    @export(&hostedGet, .{ .name = "roc_browser_http_get", .visibility = .hidden });
    @export(&hostedSleep, .{ .name = "roc_browser_sleep_millis", .visibility = .hidden });
    @export(&taskReady, .{ .name = shim_symbols.roc_task_ready, .visibility = .hidden });
    @export(&taskAbort, .{ .name = shim_symbols.roc_task_abort, .visibility = .hidden });
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    live_allocations += 1;
    return host_allocator.alloc(wasm_allocator, length, alignment) orelse @trap();
}

fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    live_allocations -= 1;
    host_allocator.dealloc(wasm_allocator, ptr, alignment);
}

fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    return host_allocator.realloc(wasm_allocator, ptr, new_length, alignment) orelse @trap();
}

fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    js.js_dbg(bytes, len);
}

fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    js.js_expect_failed(bytes, len);
}

fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    js.js_crashed(bytes, len);
}

/// The host's own string operations allocate through the same functions.
fn opsAlloc(_: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
    return rocAlloc(length, alignment);
}

fn opsDealloc(_: *RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    rocDealloc(ptr, alignment);
}

fn opsRealloc(_: *RocOps, ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    return rocRealloc(ptr, new_length, alignment);
}

fn opsDbg(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    rocDbg(bytes, len);
}

fn opsExpectFailed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    rocExpectFailed(bytes, len);
}

fn opsCrashed(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    rocCrashed(bytes, len);
}

var host_env: u8 = 0;

var roc_ops = RocOps{
    .env = @as(*anyopaque, @ptrCast(&host_env)),
    .roc_alloc = opsAlloc,
    .roc_dealloc = opsDealloc,
    .roc_realloc = opsRealloc,
    .roc_dbg = opsDbg,
    .roc_expect_failed = opsExpectFailed,
    .roc_crashed = opsCrashed,
    .hosted_fns = .{ .count = 0, .fns = undefined }, // hosted functions are reached by symbol
};

/// `RocPoll` (design.md "Host Contract").
const poll_pending: u32 = 1;

/// `void roc_browser_console_log(RocStr line)`.
fn hostedLog(line: RocStr) callconv(.c) void {
    var owned = line;
    js.js_log(owned.asSlice().ptr, owned.len());
    owned.decref(&roc_ops);
}

/// `RocPoll roc_browser_sleep_millis(RocTask *task, void *out, uint64_t millis)`.
fn hostedSleep(task: *RocTask, _: *anyopaque, millis: u64) callconv(.c) u32 {
    js.js_sleep(task, @floatFromInt(millis));
    return poll_pending;
}

/// `RocPoll roc_browser_http_get(RocTask *task, Fetched *out, RocStr url)`.
fn hostedGet(task: *RocTask, out: *Fetched, url: RocStr) callconv(.c) u32 {
    var owned = url;
    js.js_get(task, out, owned.asSlice().ptr, owned.len());
    owned.decref(&roc_ops);
    return poll_pending;
}

/// `void roc_task_ready(RocTask *task)`.
fn taskReady(task: *RocTask) callconv(.c) void {
    js.js_ready(task);
}

/// `void roc_task_abort(RocTask *task)`.
fn taskAbort(task: *RocTask) callconv(.c) void {
    js.js_abort(task);
}

extern fn roc_main(result_out: *RocStr) callconv(.c) *RocTask;
extern fn roc_task_resume(task: *RocTask) callconv(.c) u32;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_cancel(task: *RocTask) callconv(.c) void;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;

/// The root's result, once it is done.
var result: RocStr = undefined;

/// Make the root task, which the first `host_resume` begins.
export fn host_start() *RocTask {
    return roc_main(&result);
}

/// `roc_task_resume`.
export fn host_resume(task: *RocTask) u32 {
    return roc_task_resume(task);
}

/// `roc_task_cancel`.
export fn host_cancel(task: *RocTask) void {
    roc_task_cancel(task);
}

/// `roc_task_free`.
export fn host_free(task: *RocTask) void {
    roc_task_free(task);
}

/// A timer is over.
export fn host_wake(task: *RocTask) void {
    roc_task_wake(task);
}

/// A fetch ended with `text`, in memory from `host_alloc`, which this frees. It
/// is the page, or when `failed` what went wrong.
export fn host_wake_get(task: *RocTask, out: *Fetched, text: [*]u8, len: usize, failed: bool) void {
    out.* = .{ .payload = RocStr.fromSlice(text[0..len], &roc_ops), .tag = if (failed) .err else .ok };
    host_dealloc(text);
    roc_task_wake(task);
}

/// The address and length of the root's result, as `(address << 32) | length`.
/// It lives until `host_release_result`.
export fn host_result() u64 {
    return @as(u64, @intFromPtr(result.asSlice().ptr)) << 32 | result.len();
}

/// Release the root's result.
export fn host_release_result() void {
    result.decref(&roc_ops);
}

/// Memory for `len` bytes of text.
export fn host_alloc(len: usize) [*]u8 {
    return @ptrCast(rocAlloc(@max(len, 1), 1));
}

/// Free what `host_alloc` returned.
export fn host_dealloc(text: [*]u8) void {
    rocDealloc(text, 1);
}

/// How many allocations are live, the host's included.
export fn host_live_allocations() usize {
    return live_allocations;
}
