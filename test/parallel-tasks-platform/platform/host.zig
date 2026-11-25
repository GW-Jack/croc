//! Host for the reference `concurrency: ParallelTasks` platform (design.md
//! "The Reference Platform").
//!
//! A pool of workers resumes tasks, so resumes of different tasks overlap.
//! The host keeps the ready tasks in one queue, which `roc_task_ready` pushes
//! to from any thread. `Sleep.millis!` queues a deadline, which a timer
//! thread delivers by waking the task. `Meet.all!` blocks its worker until as
//! many calls as it names are inside it, so a program can require that its
//! tasks run on that many threads at once.
//!
//! `roc_task_thread_slot` returns the address of a thread-local, so a crash
//! finds the task its own thread runs (design.md "Parallel Resumes").
//! The root's `I32` is the exit status. A crashed root prints its message and
//! exits with status 1. After a root that finishes, the host fails the run
//! unless every allocation it served was released.

const std = @import("std");
const shim_io = @import("shim_io");
const builtins = @import("builtins");
const host_alloc = @import("host_alloc");

pub const std_options_elf_debug_info_search_paths = shim_io.elfDebugInfoSearchPaths;
pub const std_options_debug_io = shim_io.io();
pub const std_options_debug_threaded_io = null;
// See `shim_io.std_options_static_archive` for why these settings matter to a
// static archive that roc links into a program.
pub const std_options = shim_io.std_options_static_archive;

const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;
const TaskStatus = builtins.task.Status;

/// `RocPoll` (design.md "Host Contract").
const poll_pending: u32 = 1;

const worker_count = 4;

fn io() std.Io {
    return shim_io.io();
}

/// Counts the allocations live in libc's thread-safe `malloc` (P6).
const HostEnv = struct {
    live_allocations: std.atomic.Value(i64) = .init(0),

    pub fn rocAllocator(_: *HostEnv) std.mem.Allocator {
        return std.heap.c_allocator;
    }
};

const callbacks = host_alloc.Callbacks(HostEnv);

var g_host_env: HostEnv = .{};

fn rocAllocFn(ops: *RocOps, length: usize, alignment: usize) callconv(.c) *anyopaque {
    _ = g_host_env.live_allocations.fetchAdd(1, .monotonic);
    return callbacks.rocAllocFn(ops, length, alignment);
}

fn rocDeallocFn(ops: *RocOps, ptr: *anyopaque, alignment: usize) callconv(.c) void {
    _ = g_host_env.live_allocations.fetchSub(1, .monotonic);
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

/// Tasks handed over through `roc_task_ready`. A push happens-before the pop
/// that takes it, through the mutex (P2).
const ReadyQueue = struct {
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    tasks: std.Deque(*RocTask) = .empty,
    closed: bool = false,

    fn push(queue: *ReadyQueue, task: *RocTask) void {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        queue.tasks.pushBack(std.heap.c_allocator, task) catch host_alloc.allocFailed();
        queue.changed.signal(io());
    }

    /// The task readied first, waiting for one, or null once the queue is
    /// closed.
    fn pop(queue: *ReadyQueue) ?*RocTask {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        while (!queue.closed) {
            if (queue.tasks.popFront()) |task| return task;
            queue.changed.waitUncancelable(io(), &queue.mutex);
        }
        return null;
    }

    fn close(queue: *ReadyQueue) void {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        queue.closed = true;
        queue.changed.broadcast(io());
    }
};

/// The sleeping tasks. A delivery and an abort both take the lock, so nothing
/// wakes the task after `roc_task_abort` returns (P4). A task sleeps at most
/// once at a time.
const Timers = struct {
    mutex: std.Io.Mutex = .init,
    sleeping: std.AutoHashMapUnmanaged(*RocTask, u64) = .empty,

    fn add(timers: *Timers, task: *RocTask, deadline: u64) void {
        timers.mutex.lockUncancelable(io());
        defer timers.mutex.unlock(io());
        timers.sleeping.putNoClobber(std.heap.c_allocator, task, deadline) catch host_alloc.allocFailed();
    }

    fn abort(timers: *Timers, task: *RocTask) void {
        timers.mutex.lockUncancelable(io());
        defer timers.mutex.unlock(io());
        _ = timers.sleeping.remove(task);
    }

    /// Wake one task whose deadline has passed (P3); its result is
    /// zero-sized. Whether there was one.
    fn deliver(timers: *Timers, now: u64) bool {
        timers.mutex.lockUncancelable(io());
        defer timers.mutex.unlock(io());
        var it = timers.sleeping.iterator();
        while (it.next()) |sleep| {
            if (sleep.value_ptr.* > now) continue;
            const task = sleep.key_ptr.*;
            timers.sleeping.removeByPtr(sleep.key_ptr);
            roc_task_wake(task);
            return true;
        }
        return false;
    }
};

/// The calls inside `Meet.all!`, which leave together.
const Meeting = struct {
    mutex: std.Io.Mutex = .init,
    waiting: u64 = 0,
    /// Counts the meetings held.
    round: u64 = 0,

    fn all(meeting: *Meeting, count: u64) bool {
        const deadline = now_ns() + 10 * std.time.ns_per_s;
        meeting.mutex.lockUncancelable(io());
        const round = meeting.round;
        meeting.waiting += 1;
        if (meeting.waiting == count) {
            meeting.waiting = 0;
            meeting.round += 1;
        }
        while (meeting.round == round) {
            if (now_ns() >= deadline) {
                meeting.waiting -= 1;
                meeting.mutex.unlock(io());
                return false;
            }
            meeting.mutex.unlock(io());
            pause_briefly();
            meeting.mutex.lockUncancelable(io());
        }
        meeting.mutex.unlock(io());
        return true;
    }
};

var g_ready: ReadyQueue = .{};
var g_timers: Timers = .{};
var g_meeting: Meeting = .{};
var g_root: *RocTask = undefined;
/// The root's terminal status, set before the ready queue closes.
var g_root_status: u32 = undefined;
var g_stdout_mutex: std.Io.Mutex = .init;
/// Set once the workers are done, so the timer thread ends.
var g_stopped: std.atomic.Value(bool) = .init(false);

threadlocal var thread_task: ?*RocTask = null;

fn now_ns() u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &ts) == 0); // rationale: the monotonic clock always exists on the platform's targets
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn pause_briefly() void {
    _ = std.c.poll(undefined, 0, 1);
}

/// `bool roc_parallel_meet_all(uint64_t count)`, an ordinary hosted call that
/// blocks its worker.
fn hostedMeetAll(count: u64) callconv(.c) bool {
    return g_meeting.all(count);
}

/// `uint64_t roc_parallel_meet_rounds(void)`, an ordinary hosted call.
fn hostedMeetRounds() callconv(.c) u64 {
    g_meeting.mutex.lockUncancelable(io());
    defer g_meeting.mutex.unlock(io());
    return g_meeting.round;
}

/// `RocPoll roc_parallel_sleep_millis(RocTask *task, void *out, uint64_t millis)`.
fn hostedSleepMillis(task: *RocTask, _: *anyopaque, millis: u64) callconv(.c) u32 {
    const span = std.math.mul(u64, millis, std.time.ns_per_ms) catch std.math.maxInt(u32) * std.time.ns_per_ms;
    g_timers.add(task, now_ns() + span);
    return poll_pending;
}

/// `void roc_parallel_stdout_line(RocStr line)`, an ordinary hosted call.
fn hostedStdoutLine(line: RocStr) callconv(.c) void {
    {
        g_stdout_mutex.lockUncancelable(io());
        defer g_stdout_mutex.unlock(io());
        std.Io.File.stdout().writeStreamingAll(io(), line.asSlice()) catch {};
        std.Io.File.stdout().writeStreamingAll(io(), "\n") catch {};
    }
    var owned = line;
    owned.decref(&g_roc_ops);
}

/// `void roc_task_abort(RocTask *task)`: any thread that runs a resume may
/// call it for a task another thread parked.
fn taskAbort(task: *RocTask) callconv(.c) void {
    g_timers.abort(task);
}

/// `void roc_task_ready(RocTask *task)`.
fn taskReady(task: *RocTask) callconv(.c) void {
    g_ready.push(task);
}

/// `void **roc_task_thread_slot(void)`.
fn taskThreadSlot() callconv(.c) *?*RocTask {
    return &thread_task;
}

comptime {
    @export(&hostedMeetAll, .{ .name = "roc_parallel_meet_all", .visibility = .hidden });
    @export(&hostedMeetRounds, .{ .name = "roc_parallel_meet_rounds", .visibility = .hidden });
    @export(&hostedSleepMillis, .{ .name = "roc_parallel_sleep_millis", .visibility = .hidden });
    @export(&hostedStdoutLine, .{ .name = "roc_parallel_stdout_line", .visibility = .hidden });
    @export(&taskAbort, .{ .name = builtins.shim_symbols.roc_task_abort, .visibility = .hidden });
    @export(&taskReady, .{ .name = builtins.shim_symbols.roc_task_ready, .visibility = .hidden });
    @export(&taskThreadSlot, .{ .name = builtins.shim_symbols.roc_task_thread_slot, .visibility = .hidden });
    host_alloc.exportRuntimeSymbols(getOps, .{});
}

extern fn roc_main(result_out: *i32) callconv(.c) *RocTask;
extern fn roc_task_resume(task: *RocTask) callconv(.c) u32;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;
extern fn roc_task_crash_message(task: *RocTask, len: *usize) callconv(.c) [*]const u8;

/// Resume ready tasks until the root ends. A terminal status of another task
/// says the runtime has freed it (P8).
fn workerMain() void {
    while (g_ready.pop()) |task| {
        const status = roc_task_resume(task);
        if (task == g_root and status != @backingInt(TaskStatus.pending)) {
            g_root_status = status;
            g_ready.close();
        }
    }
}

fn timerMain() void {
    while (!g_stopped.load(.acquire)) {
        if (!g_timers.deliver(now_ns())) pause_briefly();
    }
}

comptime {
    @export(&main, .{ .name = "main" });
}

fn main(_: c_int, _: [*][*:0]u8) callconv(.c) c_int {
    return platformMain() catch |err| {
        std.debug.print("HOST ERROR: {s}\n", .{@errorName(err)});
        return 1;
    };
}

const HostError = error{ TaskCrashed, UnexpectedStatus, Leaked, ThreadSpawnFailed };

fn platformMain() HostError!c_int {
    var exit_code: i32 = undefined;
    g_root = roc_main(&exit_code);
    g_ready.push(g_root);
    const timer = std.Thread.spawn(.{}, timerMain, .{}) catch return error.ThreadSpawnFailed;
    var workers: [worker_count]std.Thread = undefined;
    for (&workers) |*worker| worker.* = std.Thread.spawn(.{}, workerMain, .{}) catch return error.ThreadSpawnFailed;
    for (workers) |worker| worker.join();
    g_stopped.store(true, .release);
    timer.join();

    if (g_root_status == @backingInt(TaskStatus.crashed)) {
        var len: usize = 0;
        const message = roc_task_crash_message(g_root, &len);
        std.debug.print("Roc crashed: {s}\n", .{message[0..len]});
        roc_task_free(g_root);
        return error.TaskCrashed;
    }
    if (g_root_status != @backingInt(TaskStatus.done)) return error.UnexpectedStatus;
    roc_task_free(g_root);
    const live = g_host_env.live_allocations.load(.monotonic);
    if (live != 0) {
        std.debug.print("{d} allocations were not released\n", .{live});
        return error.Leaked;
    }
    return exit_code;
}
