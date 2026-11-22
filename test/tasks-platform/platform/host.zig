//! Host for the reference `concurrency: Tasks` platform (design.md "The
//! Reference Platform").
//!
//! The main thread is the scheduler: it creates the root task with
//! `roc_main`, resumes it, and is the only thread that runs Roc code. A
//! fixed pool of workers runs the blocking operations. A suspending call
//! copies what its operation needs, releases its arguments, queues a job and
//! returns `ROC_PENDING`. A worker runs the job, writes the result to the
//! call's `out` and wakes the task through the program's `roc_task_wake`. If
//! the task had parked, that hands it back through the host's
//! `roc_task_ready`, which queues it for the scheduler to resume. The root's
//! `I32` is the exit status. A crashed root prints
//! its message and exits with status 1. After a root that finishes, the host
//! fails the run unless every allocation it served was released.
//!
//! `--alloc=cache` serves allocations from per-size free lists that only the
//! scheduler thread may use, for measuring what allocation costs a pause
//! (design.md "The Reference Platform", "Measuring records").

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

/// Counts the allocations live in the backing allocator. Workers allocate
/// results, so the count is atomic and the backing allocator is libc's
/// thread-safe `malloc` (P6).
const HostEnv = struct {
    live_allocations: std.atomic.Value(i64) = .init(0),

    pub fn rocAllocator(_: *HostEnv) std.mem.Allocator {
        return switch (g_alloc_mode) {
            .malloc => std.heap.c_allocator,
            .cache => .{ .ptr = undefined, .vtable = &cache_vtable },
        };
    }
};

const AllocMode = enum { malloc, cache };

var g_alloc_mode: AllocMode = .malloc;

/// The `--alloc=cache` allocator: a free list per 16-byte size class up to
/// `cache_max`, backed by `malloc`. Freed blocks are kept, never returned.
/// Only the scheduler thread may use it, which the benchmark guarantees by
/// running no worker operation.
const cache_granule = 16;
const cache_max = 1024;
const FreeBlock = struct { next: ?*FreeBlock };
var g_free_lists: [cache_max / cache_granule]?*FreeBlock = @splat(null);
var g_scheduler_thread: std.Thread.Id = undefined;

const cache_vtable: std.mem.Allocator.VTable = .{
    .alloc = cacheAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = cacheFree,
};

fn cacheClass(len: usize, alignment: std.mem.Alignment) ?usize {
    if (len == 0 or len > cache_max or alignment.toByteUnits() > cache_granule) return null;
    return (len - 1) / cache_granule;
}

fn cacheAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    std.debug.assert(std.Thread.getCurrentId() == g_scheduler_thread); // rationale: --alloc=cache is for programs that allocate only on the scheduler
    const class = cacheClass(len, alignment) orelse return std.heap.c_allocator.rawAlloc(len, alignment, ret_addr);
    if (g_free_lists[class]) |block| {
        g_free_lists[class] = block.next;
        return @ptrCast(block);
    }
    return std.heap.c_allocator.rawAlloc((class + 1) * cache_granule, .fromByteUnits(cache_granule), ret_addr);
}

fn cacheFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    std.debug.assert(std.Thread.getCurrentId() == g_scheduler_thread); // rationale: --alloc=cache is for programs that allocate only on the scheduler
    const class = cacheClass(memory.len, alignment) orelse return std.heap.c_allocator.rawFree(memory, alignment, ret_addr);
    const block: *FreeBlock = @ptrCast(@alignCast(memory.ptr));
    block.next = g_free_lists[class];
    g_free_lists[class] = block;
}

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

/// `Try(Str, [FileErr(Str)])`: both payloads are a `Str`, and `Ok` sorts
/// after `Err`, so its tag is 1.
const ReadResult = extern struct {
    payload: RocStr,
    tag: u8,

    const err_tag: u8 = 0;
    const ok_tag: u8 = 1;
};

/// A blocking operation a suspending call hands to a worker.
const Operation = union(enum) {
    /// `Stdin.line!`, writing a `Str` to `out`.
    read_line,
    /// `File.read_utf8!` of a path the host owns, writing a `ReadResult`.
    read_file: []u8,
    /// `Sleep.millis!`, whose result is zero-sized.
    sleep: u64,
};

/// One parked call, queued for the workers.
const Job = struct {
    next: ?*Job = null,
    task: *RocTask,
    out: *anyopaque,
    operation: Operation,
};

/// A first-in, first-out queue of jobs that blocks on pop. Its mutex hands
/// a job and everything written before the push to the thread that pops it
/// (P2).
const Queue = struct {
    mutex: std.Io.Mutex = .init,
    nonempty: std.Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    closed: bool = false,

    fn push(queue: *Queue, job: *Job) void {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        job.next = null;
        if (queue.tail) |tail| tail.next = job else queue.head = job;
        queue.tail = job;
        queue.nonempty.signal(io());
    }

    /// The next job, or null once the queue is closed and empty.
    fn pop(queue: *Queue) ?*Job {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        while (queue.head == null and !queue.closed) queue.nonempty.waitUncancelable(io(), &queue.mutex);
        const job = queue.head orelse return null;
        queue.head = job.next;
        if (queue.head == null) queue.tail = null;
        return job;
    }

    fn close(queue: *Queue) void {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        queue.closed = true;
        queue.nonempty.broadcast(io());
    }
};

/// Tasks handed back through `roc_task_ready`, waiting for the scheduler.
/// A worker's push happens-after the result it wrote, and the scheduler's
/// pop happens-before the resume, through the mutex (P2).
const ReadyQueue = struct {
    /// Without spawning, the root is the only task, so at most one is ever
    /// ready. Tasks spawned later need room for each one.
    const capacity = 1;

    mutex: std.Io.Mutex = .init,
    nonempty: std.Io.Condition = .init,
    tasks: [capacity]*RocTask = undefined,
    len: usize = 0,

    fn push(queue: *ReadyQueue, task: *RocTask) void {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        std.debug.assert(queue.len < capacity); // rationale: each task is readied once per park, and only the root exists
        queue.tasks[queue.len] = task;
        queue.len += 1;
        queue.nonempty.signal(io());
    }

    fn pop(queue: *ReadyQueue) *RocTask {
        queue.mutex.lockUncancelable(io());
        defer queue.mutex.unlock(io());
        while (queue.len == 0) queue.nonempty.waitUncancelable(io(), &queue.mutex);
        queue.len -= 1;
        return queue.tasks[queue.len];
    }
};

/// Jobs waiting for a worker.
var g_jobs: Queue = .{};
var g_ready: ReadyQueue = .{};
var g_workers: [worker_count]std.Thread = undefined;

fn park(task: *RocTask, out: *anyopaque, operation: Operation) u32 {
    const job = std.heap.c_allocator.create(Job) catch host_alloc.allocFailed();
    job.* = .{ .task = task, .out = out, .operation = operation };
    g_jobs.push(job);
    return poll_pending;
}

/// `RocPoll roc_tasks_stdin_line(RocTask *task, RocStr *out)`.
fn hostedStdinLine(task: *RocTask, out: *RocStr) callconv(.c) u32 {
    return park(task, out, .read_line);
}

/// `RocPoll roc_tasks_file_read_utf8(RocTask *task, ReadResult *out, RocStr path)`.
/// The path is copied and released here, on the scheduler thread, so no
/// worker touches a refcount the program can see.
fn hostedFileReadUtf8(task: *RocTask, out: *ReadResult, path: RocStr) callconv(.c) u32 {
    const copy = std.heap.c_allocator.dupe(u8, path.asSlice()) catch host_alloc.allocFailed();
    var owned = path;
    owned.decref(&g_roc_ops);
    return park(task, out, .{ .read_file = copy });
}

/// `RocPoll roc_tasks_sleep_millis(RocTask *task, void *out, uint64_t millis)`.
fn hostedSleepMillis(task: *RocTask, out: *anyopaque, millis: u64) callconv(.c) u32 {
    return park(task, out, .{ .sleep = millis });
}

/// The task that called `Scheduler.yield!` in the resume now running, which
/// the scheduler readies itself once that resume returns.
var g_yielded: ?*RocTask = null;

/// `RocPoll roc_tasks_scheduler_yield(RocTask *task, void *out)`.
fn hostedSchedulerYield(task: *RocTask, _: *anyopaque) callconv(.c) u32 {
    std.debug.assert(g_yielded == null); // rationale: a task waits on at most one call
    g_yielded = task;
    return poll_pending;
}

/// `uint64_t roc_tasks_clock_monotonic_ns(void)`, an ordinary hosted call.
fn hostedClockMonotonicNs() callconv(.c) u64 {
    var ts: std.c.timespec = undefined;
    std.debug.assert(std.c.clock_gettime(.MONOTONIC, &ts) == 0); // rationale: the monotonic clock always exists on the platform's targets
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// `void roc_tasks_stdout_line(RocStr line)`, an ordinary hosted call.
fn hostedStdoutLine(line: RocStr) callconv(.c) void {
    std.Io.File.stdout().writeStreamingAll(io(), line.asSlice()) catch {};
    std.Io.File.stdout().writeStreamingAll(io(), "\n") catch {};
    var owned = line;
    owned.decref(&g_roc_ops);
}

/// `void roc_task_abort(RocTask *task)`, which every `Tasks` host defines.
/// This host never cancels (design.md "The Reference Platform").
fn taskAbort(_: *RocTask) callconv(.c) void {
    @panic("roc_task_abort: the reference platform never cancels a task");
}

/// `void roc_task_ready(RocTask *task)`, which every `Tasks` host defines: a
/// wake found the task parked, so it may be resumed. It runs on whichever
/// thread woke the task.
fn taskReady(task: *RocTask) callconv(.c) void {
    g_ready.push(task);
}

comptime {
    @export(&hostedStdinLine, .{ .name = "roc_tasks_stdin_line", .visibility = .hidden });
    @export(&hostedFileReadUtf8, .{ .name = "roc_tasks_file_read_utf8", .visibility = .hidden });
    @export(&hostedSleepMillis, .{ .name = "roc_tasks_sleep_millis", .visibility = .hidden });
    @export(&hostedStdoutLine, .{ .name = "roc_tasks_stdout_line", .visibility = .hidden });
    @export(&hostedSchedulerYield, .{ .name = "roc_tasks_scheduler_yield", .visibility = .hidden });
    @export(&hostedClockMonotonicNs, .{ .name = "roc_tasks_clock_monotonic_ns", .visibility = .hidden });
    @export(&taskAbort, .{ .name = builtins.shim_symbols.roc_task_abort, .visibility = .hidden });
    @export(&taskReady, .{ .name = builtins.shim_symbols.roc_task_ready, .visibility = .hidden });
    host_alloc.exportRuntimeSymbols(getOps, .{});
}

fn workerMain() void {
    while (g_jobs.pop()) |job| {
        run(job);
        // A wake before the task parks readies nothing: the resume still
        // running carries on with the result instead of pausing.
        const task = job.task;
        std.heap.c_allocator.destroy(job);
        roc_task_wake(task);
    }
}

/// Run `job`'s operation and write its result to `out` (P3). The result is
/// allocated here, on the worker; the program releases it on the scheduler.
fn run(job: *Job) void {
    switch (job.operation) {
        .read_line => {
            const out: *RocStr = @ptrCast(@alignCast(job.out));
            out.* = readLine();
        },
        .read_file => |path| {
            const out: *ReadResult = @ptrCast(@alignCast(job.out));
            out.* = readFile(path);
            std.heap.c_allocator.free(path);
        },
        .sleep => |millis| {
            const ts: std.c.timespec = .{
                .sec = @intCast(millis / std.time.ms_per_s),
                .nsec = @intCast((millis % std.time.ms_per_s) * std.time.ns_per_ms),
            };
            var remaining = ts;
            while (std.c.nanosleep(&remaining, &remaining) != 0) {}
        },
    }
}

/// Buffered standard input, read by whichever worker runs a `Stdin.line!`.
var g_stdin_mutex: std.Io.Mutex = .init;
var g_stdin_buffer: [4096]u8 = undefined;
var g_stdin_start: usize = 0;
var g_stdin_end: usize = 0;

fn readLine() RocStr {
    g_stdin_mutex.lockUncancelable(io());
    defer g_stdin_mutex.unlock(io());
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.heap.c_allocator);
    while (true) {
        if (g_stdin_start == g_stdin_end) {
            g_stdin_start = 0;
            g_stdin_end = 0;
            // End of input, or a read error, ends the last line.
            g_stdin_end = std.Io.File.stdin().readStreaming(io(), &.{&g_stdin_buffer}) catch break;
        }
        const pending = g_stdin_buffer[g_stdin_start..g_stdin_end];
        if (std.mem.findScalar(u8, pending, '\n')) |newline| {
            line.appendSlice(std.heap.c_allocator, pending[0..newline]) catch host_alloc.allocFailed();
            g_stdin_start += newline + 1;
            break;
        }
        line.appendSlice(std.heap.c_allocator, pending) catch host_alloc.allocFailed();
        g_stdin_start = g_stdin_end;
    }
    return RocStr.fromSlice(line.items, &g_roc_ops);
}

fn readFile(path: []const u8) ReadResult {
    const contents = readAll(path) catch |err| return .{
        .payload = RocStr.fromSlice(@errorName(err), &g_roc_ops),
        .tag = ReadResult.err_tag,
    };
    defer std.heap.c_allocator.free(contents);
    if (!std.unicode.utf8ValidateSlice(contents)) return .{
        .payload = RocStr.fromSlice("InvalidUtf8", &g_roc_ops),
        .tag = ReadResult.err_tag,
    };
    return .{ .payload = RocStr.fromSlice(contents, &g_roc_ops), .tag = ReadResult.ok_tag };
}

fn readAll(path: []const u8) (std.Io.File.OpenError || std.Io.File.ReadStreamingError || std.mem.Allocator.Error)![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io(), path, .{});
    defer file.close(io());
    var contents: std.ArrayList(u8) = .empty;
    errdefer contents.deinit(std.heap.c_allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io(), &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try contents.appendSlice(std.heap.c_allocator, chunk[0..n]);
    }
    return contents.toOwnedSlice(std.heap.c_allocator);
}

extern fn roc_main(result_out: *i32) callconv(.c) *RocTask;
extern fn roc_task_resume(task: *RocTask) callconv(.c) u32;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;
extern fn roc_task_crash_message(task: *RocTask, len: *usize) callconv(.c) [*]const u8;

comptime {
    @export(&main, .{ .name = "main" });
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    for (argv[1..@intCast(argc)]) |arg_z| {
        const arg = std.mem.span(arg_z);
        if (std.mem.eql(u8, arg, "--alloc=malloc")) {
            g_alloc_mode = .malloc;
        } else if (std.mem.eql(u8, arg, "--alloc=cache")) {
            g_alloc_mode = .cache;
        } else {
            std.debug.print("Error: bad argument '{s}'\nUsage: <app> [--alloc=malloc | --alloc=cache]\n", .{arg});
            return 1;
        }
    }
    g_scheduler_thread = std.Thread.getCurrentId();
    return platformMain() catch |err| {
        std.debug.print("HOST ERROR: {s}\n", .{@errorName(err)});
        return 1;
    };
}

const HostError = error{ TaskCrashed, UnexpectedStatus, Leaked, ThreadSpawnFailed };

fn platformMain() HostError!c_int {
    var started: usize = 0;
    defer {
        g_jobs.close();
        for (g_workers[0..started]) |worker| worker.join();
    }
    while (started < worker_count) : (started += 1) {
        g_workers[started] = std.Thread.spawn(.{}, workerMain, .{}) catch return error.ThreadSpawnFailed;
    }

    var exit_code: i32 = undefined;
    const root = roc_main(&exit_code);
    var status = roc_task_resume(root);
    while (status == @backingInt(TaskStatus.pending)) {
        if (g_yielded) |task| {
            // A yield parked the task with no worker: wake it now, after the
            // park, so the wake hands it back through `roc_task_ready`.
            g_yielded = null;
            roc_task_wake(task);
        }
        // The root parked on one call; resume it once a wake hands it back.
        const task = g_ready.pop();
        std.debug.assert(task == root); // rationale: without spawning, the root is the only task
        status = roc_task_resume(task);
    }
    if (status == @backingInt(TaskStatus.crashed)) {
        var len: usize = 0;
        const message = roc_task_crash_message(root, &len);
        std.debug.print("Roc crashed: {s}\n", .{message[0..len]});
        roc_task_free(root);
        return error.TaskCrashed;
    }
    if (status != @backingInt(TaskStatus.done)) return error.UnexpectedStatus;
    roc_task_free(root);
    const live = g_host_env.live_allocations.load(.monotonic);
    if (live != 0) {
        std.debug.print("{d} allocations were not released\n", .{live});
        return error.Leaked;
    }
    return exit_code;
}
