//! Host for the `concurrency: Tasks` test platform: a pausing host.
//!
//! It calls `roc_main`, which returns a task, and drives that task, and the
//! child tasks it starts, with the loop in scheduler.zig: every
//! `roc_host_fetch` call parks, and the loop answers one when no task is
//! ready, waking the task through the program's `roc_task_wake`. Arguments:
//! - `--finish-at-once` answers every call during the call instead, so the
//!   same app runs both ways;
//! - `--answer-newest-first` answers the newest parked fetch first;
//! - `--cancel-at N` cancels the task through the program's
//!   `roc_task_cancel` at its Nth pause instead of answering, so the program
//!   aborts the fetches through the host's `roc_task_abort` and hands the
//!   unparked tasks back through `roc_task_ready`;
//! - `--cancel-woken-at N` answers and wakes the Nth pause's fetch first, so
//!   the program releases the answer.
//!
//! Either way the cancel is a request: a later resume reports CANCELLED
//! (design.md "The Task Runtime", "Cancellation"). It prints the result, or
//! where it cancelled, and the number of pauses, and fails the run unless
//! every allocation it served was freed. A task that crashes ends with
//! status CRASHED (design.md "The Task Runtime"): the host prints its
//! message and fails the run, without the leak check, since a crash leaves
//! what the crashed frames owned.

const std = @import("std");
const shim_io = @import("shim_io");
const builtins = @import("builtins");
const host_alloc = @import("host_alloc");
const scheduler = @import("scheduler.zig");

pub const std_options_elf_debug_info_search_paths = shim_io.elfDebugInfoSearchPaths;
pub const std_options_debug_io = shim_io.io();
pub const std_options_debug_threaded_io = null;
// See `shim_io.std_options_static_archive` for why these settings matter to a
// static archive that roc links into a program.
pub const std_options = shim_io.std_options_static_archive;

const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;

/// Counts the allocations live in the backing allocator, so the host can
/// check that the program freed everything it allocated.
const HostEnv = struct {
    live_allocations: i64 = 0,

    pub fn rocAllocator(_: *HostEnv) std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

const callbacks = host_alloc.Callbacks(HostEnv);

var g_host_env: HostEnv = .{};

fn rocAllocFn(ops: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
    g_host_env.live_allocations += 1;
    return callbacks.rocAllocFn(ops, length, alignment);
}

fn rocDeallocFn(ops: *RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    g_host_env.live_allocations -= 1;
    callbacks.rocDeallocFn(ops, ptr, alignment);
}

var g_roc_ops = RocOps{
    .env = @as(*anyopaque, @ptrCast(&g_host_env)),
    .roc_alloc = rocAllocFn,
    .roc_dealloc = rocDeallocFn,
    .roc_realloc = callbacks.rocReallocFn,
    .roc_dbg = callbacks.rocDbgFn,
    .roc_expect_failed = callbacks.rocExpectFailedFn,
    .roc_crashed = callbacks.rocCrashedFn,
    .hosted_fns = .{ .count = 0, .fns = undefined }, // hosted functions are reached by symbol
};

fn getOps() *RocOps {
    return &g_roc_ops;
}

var g_config: scheduler.Config = .{};

/// `RocPoll roc_host_fetch(RocTask *task, RocStr *out, RocStr url)`.
fn hostedFetch(task: *RocTask, out: *RocStr, url: RocStr) callconv(.c) u32 {
    return scheduler.fetch(task, out, url);
}

/// `void roc_task_abort(RocTask *task)`, which every `Tasks` host defines
/// (design.md "Host Contract"): abandon the fetch the cancelled task is
/// parked on, releasing its URL.
fn taskAbort(task: *RocTask) callconv(.c) void {
    scheduler.abort(task);
}

/// `void roc_task_ready(RocTask *task)`, which every `Tasks` host defines
/// (design.md "Host Contract"): a wake found the task parked, a cancel
/// unparked it, or the program started it as a child. Queue it for the loop.
fn taskReady(task: *RocTask) callconv(.c) void {
    scheduler.readied(task);
}

comptime {
    @export(&hostedFetch, .{ .name = "roc_host_fetch", .visibility = .hidden });
    @export(&taskAbort, .{ .name = builtins.shim_symbols.roc_task_abort, .visibility = .hidden });
    @export(&taskReady, .{ .name = builtins.shim_symbols.roc_task_ready, .visibility = .hidden });
    host_alloc.exportRuntimeSymbols(getOps, .{});
}

extern fn roc_main(url: RocStr, result_out: *RocStr) callconv(.c) *RocTask;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;
extern fn roc_task_crash_message(task: *RocTask, len: *usize) callconv(.c) [*]const u8;

// OS-specific entry point handling
comptime {
    @export(&main, .{ .name = "main" });
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--finish-at-once")) {
            g_config.finish_at_once = true;
        } else if (std.mem.eql(u8, arg, "--answer-newest-first")) {
            g_config.order = .newest_first;
        } else if (std.mem.eql(u8, arg, "--cancel-at") or std.mem.eql(u8, arg, "--cancel-woken-at")) {
            g_config.cancel_woken = std.mem.eql(u8, arg, "--cancel-woken-at");
            i += 1;
            const pause = if (i < @as(usize, @intCast(argc))) std.mem.span(argv[i]) else "";
            g_config.cancel_at = std.fmt.parseInt(u32, pause, 10) catch return usage(arg);
        } else {
            return usage(arg);
        }
    }
    platformMain() catch |err| {
        std.debug.print("HOST ERROR: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn usage(arg: []const u8) c_int {
    std.debug.print("Error: bad argument '{s}'\nUsage: <app> [--finish-at-once | --answer-newest-first | --cancel-at N | --cancel-woken-at N]\n", .{arg});
    return 1;
}

const HostError = scheduler.Error || error{ TaskCrashed, Leaked };

fn platformMain() HostError!void {
    scheduler.reset(g_config, &g_roc_ops);
    // Long enough that the string, and the answer built from it, live on the
    // heap and so count toward the leak check.
    const url = RocStr.fromSlice("https://example.com/concurrency/tasks", &g_roc_ops);
    var result: RocStr = undefined;
    const task = roc_main(url, &result);
    const outcome = try scheduler.run(task);
    const fetches = scheduler.fetches;
    const pauses = scheduler.pauses;
    if (outcome == .crashed) {
        var len: usize = 0;
        const message = roc_task_crash_message(task, &len);
        std.debug.print("crashed after pause {d}: {s}\nfetches: {d}, pauses: {d}\n", .{ pauses, message[0..len], fetches, pauses });
        roc_task_free(task);
        return error.TaskCrashed;
    }
    roc_task_free(task);
    if (outcome == .cancelled) {
        std.debug.print("cancelled at pause {d}\nfetches: {d}, pauses: {d}\n", .{ pauses, fetches, pauses });
        return checkLeaks();
    }
    std.debug.print("{s}\nfetches: {d}, pauses: {d}\n", .{ result.asSlice(), fetches, pauses });
    result.decref(&g_roc_ops);
    return checkLeaks();
}

fn checkLeaks() HostError!void {
    if (g_host_env.live_allocations != 0) {
        std.debug.print("live allocations: {d}\n", .{g_host_env.live_allocations});
        return error.Leaked;
    }
}
