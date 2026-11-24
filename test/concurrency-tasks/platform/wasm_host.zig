//! wasm32 host for the `concurrency: Tasks` test platform: the native
//! host's loop (host.zig, scheduler.zig) inside the module, driven from
//! `wasm_main`.
//!
//! `wasm_configure(mode, pause)` picks how the next `wasm_main` runs:
//! - 0: answer the oldest parked `roc_host_fetch` when no task is ready,
//!   waking its task, which the program hands back through `roc_task_ready`;
//! - 1: answer every fetch during the call;
//! - 2: cancel at pause `pause` before answering, so the program aborts the
//!   fetches through `roc_task_abort` and hands the unparked tasks back
//!   through `roc_task_ready`;
//! - 3: answer and wake at pause `pause`, then cancel, so the program
//!   releases the answer;
//! - 4: as 0, but answer the newest parked fetch first.
//!
//! A cancel is a request: a later resume of the task reports CANCELLED.
//!
//! `wasm_main` returns the text the native host prints (the result or where
//! it cancelled, then the fetch and pause counts), copied out of the heap,
//! so a run that frees everything it allocated leaves `wasm_alloc_count`
//! equal to `wasm_dealloc_count`. The module imports only `roc_panic`,
//! `roc_dbg` and `roc_expect_failed` from `env`.

const std = @import("std");
const builtins = @import("builtins");
const host_alloc = @import("host_alloc");
const scheduler = @import("scheduler.zig");

const shim_symbols = builtins.shim_symbols;
const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;

const env_imports = struct {
    extern "env" fn roc_panic(ptr: [*]const u8, len: usize) noreturn;
    extern "env" fn roc_dbg(ptr: [*]const u8, len: usize) void;
    extern "env" fn roc_expect_failed(ptr: [*]const u8, len: usize) void;
};

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    env_imports.roc_panic(msg.ptr, msg.len);
}

const wasm_allocator = std.heap.wasm_allocator;

/// Allocations and deallocations served, by the program and by the host.
var alloc_counts: [2]usize = .{ 0, 0 };

comptime {
    shim_symbols.exportRuntimeFns(.{
        .alloc = &rocAlloc,
        .dealloc = &rocDealloc,
        .realloc = &rocRealloc,
        .dbg = &rocDbg,
        .expect_failed = &rocExpectFailed,
        .crashed = &rocCrashed,
    }, .default);
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    alloc_counts[0] += 1;
    return host_alloc.alloc(wasm_allocator, length, alignment) orelse @trap();
}

fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    alloc_counts[1] += 1;
    host_alloc.dealloc(wasm_allocator, ptr, alignment);
}

fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    alloc_counts[0] += 1;
    alloc_counts[1] += 1;
    return host_alloc.realloc(wasm_allocator, ptr, new_length, alignment) orelse @trap();
}

fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    env_imports.roc_dbg(bytes, len);
}

fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    env_imports.roc_expect_failed(bytes, len);
}

fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    env_imports.roc_panic(bytes, len);
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

const Mode = enum(u32) { pause_every_fetch = 0, finish_at_once = 1, cancel_at = 2, cancel_woken_at = 3, newest_first = 4 };

var config: scheduler.Config = .{};

/// `RocPoll roc_host_fetch(RocTask *task, RocStr *out, RocStr url)`.
fn hostedFetch(task: *RocTask, out: *RocStr, url: RocStr) callconv(.c) u32 {
    return scheduler.fetch(task, out, url);
}

/// `void roc_task_abort(RocTask *task)`: abandon the fetch the cancelled
/// task is parked on, releasing its URL.
fn taskAbort(task: *RocTask) callconv(.c) void {
    scheduler.abort(task);
}

/// `void roc_task_ready(RocTask *task)`: a wake found the task parked, a
/// cancel unparked it, or the program started it as a child. Queue it for
/// the loop.
fn taskReady(task: *RocTask) callconv(.c) void {
    scheduler.readied(task);
}

comptime {
    @export(&hostedFetch, .{ .name = "roc_host_fetch", .visibility = .hidden });
    @export(&taskAbort, .{ .name = shim_symbols.roc_task_abort, .visibility = .hidden });
    @export(&taskReady, .{ .name = shim_symbols.roc_task_ready, .visibility = .hidden });
}

extern fn roc_main(url: RocStr, result_out: *RocStr) callconv(.c) *RocTask;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;

var report_buf: [512]u8 = undefined;
var report_len: usize = 0;

fn report(comptime fmt: []const u8, args: anytype) void {
    report_len = (std.fmt.bufPrint(&report_buf, fmt, args) catch @panic("report too long")).len;
}

/// Set how the next `wasm_main` runs; see the module comment.
export fn wasm_configure(new_mode: u32, pause: u32) void {
    const mode = std.enums.fromInt(Mode, new_mode) orelse @panic("unknown mode");
    config = .{
        .finish_at_once = mode == .finish_at_once,
        .order = if (mode == .newest_first) .newest_first else .oldest_first,
        .cancel_at = if (mode == .cancel_at or mode == .cancel_woken_at) pause else null,
        .cancel_woken = mode == .cancel_woken_at,
    };
}

/// Run the app once and return the address of its report.
export fn wasm_main() [*]const u8 {
    scheduler.reset(config, &roc_ops);
    // Long enough that the string, and the answer built from it, live on the
    // heap and so count toward the allocation balance.
    const url = RocStr.fromSlice("https://example.com/concurrency/tasks", &roc_ops);
    var result: RocStr = undefined;
    const task = roc_main(url, &result);
    const outcome = scheduler.run(task) catch |err| @panic(@errorName(err));
    roc_task_free(task);
    const fetches = scheduler.fetches;
    const pauses = scheduler.pauses;
    if (outcome == .cancelled) {
        report("cancelled at pause {d}\nfetches: {d}, pauses: {d}\n", .{ pauses, fetches, pauses });
        return &report_buf;
    }
    // wasm has no crash exit: a crash reaches `roc_crashed` while the task
    // runs (design.md "The Task Runtime").
    if (outcome == .crashed) @panic("the task reported CRASHED");
    report("{s}\nfetches: {d}, pauses: {d}\n", .{ result.asSlice(), fetches, pauses });
    result.decref(&roc_ops);
    return &report_buf;
}

/// The length of the last `wasm_main` report.
export fn wasm_result_len() usize {
    return report_len;
}

export fn wasm_alloc_count() usize {
    return alloc_counts[0];
}

export fn wasm_dealloc_count() usize {
    return alloc_counts[1];
}
