//! The WASI 0.3 reference host (design.md "Host Contract", "WASI hosts."), a
//! whole program's scheduler on the component model's callback ABI.
//!
//! The module it links into is the core module of a component that exports
//! `wasi:cli/run` (world.wit). Its imports and exports have the names the
//! component model's tools give the interfaces' functions and the canonical
//! built-ins.

const std = @import("std");
const builtins = @import("builtins");
const host_allocator = @import("host_alloc");

const shim_symbols = builtins.shim_symbols;
const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;

/// What an async lowering returns in place of a result that is not there yet.
const blocked: u32 = 0xffff_ffff;

const canon = struct {
    extern "$root" fn @"[waitable-set-new]"() u32;
    /// Blocks until an event of the set. Its code, with its operands in `out`.
    extern "$root" fn @"[waitable-set-wait]"(set: u32, out: *[2]u32) Event;
    extern "$root" fn @"[waitable-set-drop]"(set: u32) void;
    extern "$root" fn @"[waitable-join]"(waitable: u32, set: u32) void;
    extern "$root" fn @"[subtask-drop]"(subtask: u32) void;
    /// Blocks until the subtask resolves. The state it resolved in.
    extern "$root" fn @"[subtask-cancel]"(subtask: u32) SubtaskState;
    extern "$root" fn @"[backpressure-inc]"() void;
    extern "$root" fn @"[backpressure-dec]"() void;
    extern "[export]$root" fn @"[task-cancel]"() void;
};

const run_export = struct {
    extern "[export]wasi:cli/run@0.3.0" fn @"[task-return]run"(failed: u32) void;
};

const clock = struct {
    /// `(subtask << 4) | state`.
    extern "wasi:clocks/monotonic-clock@0.3.0" fn @"[async-lower]wait-for"(nanoseconds: u64) u32;
};

/// `write-via-stream` takes a stream of bytes to write and returns a future of
/// how that went. A new stream is `(writable << 32) | readable`.
const stdout = struct {
    extern "wasi:cli/stdout@0.3.0" fn @"write-via-stream"(readable: u32) u32;
    extern "wasi:cli/stdout@0.3.0" fn @"[stream-new-0]write-via-stream"() u64;
    extern "wasi:cli/stdout@0.3.0" fn @"[async-lower][stream-write-0]write-via-stream"(writable: u32, ptr: [*]const u8, len: usize) u32;
    extern "wasi:cli/stdout@0.3.0" fn @"[stream-drop-writable-0]write-via-stream"(writable: u32) void;
    extern "wasi:cli/stdout@0.3.0" fn @"[async-lower][future-read-1]write-via-stream"(future: u32, out: *WriteResult) u32;
    extern "wasi:cli/stdout@0.3.0" fn @"[future-drop-readable-1]write-via-stream"(future: u32) void;
};

const stderr = struct {
    extern "wasi:cli/stderr@0.3.0" fn @"write-via-stream"(readable: u32) u32;
    extern "wasi:cli/stderr@0.3.0" fn @"[stream-new-0]write-via-stream"() u64;
    extern "wasi:cli/stderr@0.3.0" fn @"[async-lower][stream-write-0]write-via-stream"(writable: u32, ptr: [*]const u8, len: usize) u32;
    extern "wasi:cli/stderr@0.3.0" fn @"[stream-drop-writable-0]write-via-stream"(writable: u32) void;
    extern "wasi:cli/stderr@0.3.0" fn @"[async-lower][future-read-1]write-via-stream"(future: u32, out: *WriteResult) u32;
    extern "wasi:cli/stderr@0.3.0" fn @"[future-drop-readable-1]write-via-stream"(future: u32) void;
};

/// `result<_, error-code>`.
const WriteResult = extern struct { tag: enum(u8) { ok = 0, err = 1 }, code: u8 };

/// How far a stream write got, as its return value or its event has it.
const Copied = packed struct(u32) {
    result: enum(u4) { completed = 0, dropped = 1, cancelled = 2, _ },
    count: u28,
};

/// A subtask's progress, as its call's return value or its event has it.
const SubtaskState = enum(u32) {
    starting = 0,
    started = 1,
    returned = 2,
    cancelled_before_started = 3,
    cancelled_before_returned = 4,
    _,

    fn resolved(state: SubtaskState) bool {
        return switch (state) {
            .starting, .started => false,
            .returned, .cancelled_before_started, .cancelled_before_returned => true,
            _ => die("an unknown subtask state"),
        };
    }
};

/// What the callback is called for.
const Event = enum(u32) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancelled = 6,
    _,
};

/// What a callback answers: `EXIT`, or `WAIT` on a set.
const exit: u32 = 0;
fn waitOn(set: u32) u32 {
    return 2 | set << 4;
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, _: ?usize) noreturn {
    die(msg);
}

/// For what the host keeps. Roc's memory is counted, in `rocAlloc`.
const gpa = std.heap.wasm_allocator;

fn outOfMemory() noreturn {
    die("out of memory");
}

/// Roc's allocations not freed yet.
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
    @export(&hostedLine, .{ .name = "roc_wasi_stdout_line", .visibility = .hidden });
    @export(&hostedSleep, .{ .name = "roc_wasi_sleep_millis", .visibility = .hidden });
    @export(&taskReady, .{ .name = shim_symbols.roc_task_ready, .visibility = .hidden });
    @export(&taskAbort, .{ .name = shim_symbols.roc_task_abort, .visibility = .hidden });
    @export(&run, .{ .name = "[async-lift]wasi:cli/run@0.3.0#run" });
    @export(&callback, .{ .name = "[callback][async-lift]wasi:cli/run@0.3.0#run" });
}

fn rocAlloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    live_allocations += 1;
    return host_allocator.alloc(gpa, length, alignment) orelse outOfMemory();
}

fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    live_allocations -= 1;
    host_allocator.dealloc(gpa, ptr, alignment);
}

fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    return host_allocator.realloc(gpa, ptr, new_length, alignment) orelse outOfMemory();
}

fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    errors.line(bytes[0..len]);
}

fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    errors.line(bytes[0..len]);
}

fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    die(bytes[0..len]);
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

/// The error stream. Each write of it blocks, so that what it says is out before
/// a trap. WASI 0.3.0 leaves out the blocking forms of the operations, so this
/// waits on a set of its own.
const errors = struct {
    var open: ?struct { writable: u32, future: u32, set: u32 } = null;

    fn line(text: []const u8) void {
        write(text);
        write("\n");
    }

    fn write(text: []const u8) void {
        const stream = open orelse opened: {
            const ends = stderr.@"[stream-new-0]write-via-stream"();
            open = .{
                .writable = @truncate(ends >> 32),
                .future = stderr.@"write-via-stream"(@truncate(ends)),
                .set = canon.@"[waitable-set-new]"(),
            };
            canon.@"[waitable-join]"(open.?.writable, open.?.set);
            canon.@"[waitable-join]"(open.?.future, open.?.set);
            break :opened open.?;
        };
        var rest = text;
        while (rest.len > 0) {
            const copied: Copied = @bitCast(wait(stream.set, stderr.@"[async-lower][stream-write-0]write-via-stream"(stream.writable, rest.ptr, rest.len)));
            rest = rest[copied.count..];
            if (copied.result == .dropped) return; // nothing reads it
        }
    }

    /// Wait until what was written is out.
    fn close() void {
        const stream = open orelse return;
        open = null;
        var result: WriteResult = undefined;
        stderr.@"[stream-drop-writable-0]write-via-stream"(stream.writable);
        _ = wait(stream.set, stderr.@"[async-lower][future-read-1]write-via-stream"(stream.future, &result));
        stderr.@"[future-drop-readable-1]write-via-stream"(stream.future);
        canon.@"[waitable-set-drop]"(stream.set);
    }

    /// The result of the one operation in progress, which `returned` is unless
    /// it is `blocked`.
    fn wait(set: u32, returned: u32) u32 {
        if (returned != blocked) return returned;
        var operands: [2]u32 = undefined;
        _ = canon.@"[waitable-set-wait]"(set, &operands);
        return operands[1];
    }
};

var dying = false;

/// End the program by trapping, which no component's code runs after.
fn die(message: []const u8) noreturn {
    if (!dying) {
        dying = true;
        errors.line(message);
        errors.close();
    }
    @trap();
}

/// `RocPoll` (design.md "Host Contract").
const RocPoll = enum(u32) { ready = 0, pending = 1 };

/// `RocTaskStatus` (design.md "Host Contract").
const RocTaskStatus = enum(u32) { pending = 0, done = 1, cancelled = 2, crashed = 3 };

/// The waitable set that has every subtask and stream end.
var waitables: u32 = undefined;

/// What a task waits on.
const Operation = union(enum) { timer: u32, line: *Line };

/// The operation each waiting task waits on, so that an abort finds it.
var operations: std.AutoHashMapUnmanaged(*RocTask, Operation) = .empty;

/// The task each timer's subtask wakes.
var timers: std.AutoHashMapUnmanaged(u32, *RocTask) = .empty;

fn waitFor(task: *RocTask, operation: Operation) RocPoll {
    operations.putNoClobber(gpa, task, operation) catch outOfMemory();
    return .pending;
}

fn wake(task: *RocTask) void {
    if (!operations.remove(task)) die("a wake of a task that waits on nothing");
    roc_task_wake(task);
}

/// `RocPoll roc_wasi_sleep_millis(RocTask *task, void *out, uint64_t millis)`.
fn hostedSleep(task: *RocTask, _: *anyopaque, millis: u64) callconv(.c) RocPoll {
    const started = clock.@"[async-lower]wait-for"(millis *| std.time.ns_per_ms);
    const state: SubtaskState = @fromBackingInt(@intCast(started & 0xf));
    if (state.resolved()) return .ready;
    const subtask = started >> 4;
    canon.@"[waitable-join]"(subtask, waitables);
    timers.putNoClobber(gpa, subtask, task) catch outOfMemory();
    return waitFor(task, .{ .timer = subtask });
}

fn timerProgressed(subtask: u32, state: SubtaskState) void {
    if (!state.resolved()) return;
    const timer = timers.fetchRemove(subtask) orelse die("an event for no timer");
    canon.@"[subtask-drop]"(subtask);
    wake(timer.value);
}

/// A line to write. Its bytes follow it in memory, which the host owns.
const Line = struct {
    /// The task that waits until the line is written.
    task: ?*RocTask = null,
    next: ?*Line = null,
    text: []u8,
    written: usize = 0,

    fn create(text: []const u8) *Line {
        const line = gpa.create(Line) catch outOfMemory();
        line.* = .{ .text = gpa.alloc(u8, text.len + 1) catch outOfMemory() };
        @memcpy(line.text[0..text.len], text);
        line.text[text.len] = '\n';
        return line;
    }

    fn destroy(line: *Line) void {
        gpa.free(line.text);
        gpa.destroy(line);
    }
};

/// The output stream and the lines not written yet, in order.
const output = struct {
    var open: ?struct { writable: u32, future: u32 } = null;
    var first: ?*Line = null;
    var last: ?*Line = null;
    /// The stream is writing the first line.
    var writing = false;
    /// Nothing reads the stream any more.
    var unread = false;
    var result: WriteResult = undefined;
    var failed = false;

    fn append(line: *Line) void {
        if (last) |before| before.next = line else first = line;
        last = line;
    }

    /// Give the stream lines until it takes one that it does not write at once.
    fn pump() void {
        while (!writing) {
            const line = first orelse return;
            if (unread) {
                finishFirst();
                continue;
            }
            const stream = open orelse opened: {
                const ends = stdout.@"[stream-new-0]write-via-stream"();
                open = .{
                    .writable = @truncate(ends >> 32),
                    .future = stdout.@"write-via-stream"(@truncate(ends)),
                };
                canon.@"[waitable-join]"(open.?.writable, waitables);
                break :opened open.?;
            };
            const rest = line.text[line.written..];
            const copied = stdout.@"[async-lower][stream-write-0]write-via-stream"(stream.writable, rest.ptr, rest.len);
            if (copied == blocked) {
                writing = true;
            } else {
                progressed(@bitCast(copied));
            }
        }
    }

    fn progressed(copied: Copied) void {
        const line = first orelse die("an event for no line");
        line.written += copied.count;
        if (copied.result == .dropped) unread = true;
        if (line.written == line.text.len or unread) finishFirst();
    }

    fn finishFirst() void {
        const line = first.?;
        first = line.next;
        if (first == null) last = null;
        const task = line.task;
        line.destroy();
        if (task) |waiting| wake(waiting);
    }

    /// Forget the task that waits on a line, and the line unless it is begun.
    fn abort(line: *Line) void {
        line.task = null;
        var before: ?*Line = null;
        var at = first;
        while (at) |each| : ({
            before = each;
            at = each.next;
        }) {
            if (each == line) break;
        }
        const previous = before orelse return; // the first line is begun
        previous.next = line.next;
        if (last == line) last = previous;
        line.destroy();
    }

    /// Close the stream once every line is written. Whether it is closed.
    fn close() bool {
        if (first != null) return false;
        const stream = open orelse return true;
        if (writing) return false; // the future is being read
        stdout.@"[stream-drop-writable-0]write-via-stream"(stream.writable);
        writing = true;
        if (stdout.@"[async-lower][future-read-1]write-via-stream"(stream.future, &result) == blocked) {
            canon.@"[waitable-join]"(stream.future, waitables);
            return false;
        }
        closed();
        return true;
    }

    fn closed() void {
        stdout.@"[future-drop-readable-1]write-via-stream"(open.?.future);
        failed = result.tag == .err;
        open = null;
        writing = false;
    }
};

/// `RocPoll roc_wasi_stdout_line(RocTask *task, void *out, RocStr line)`.
fn hostedLine(task: *RocTask, _: *anyopaque, text: RocStr) callconv(.c) RocPoll {
    var owned = text;
    const line = Line.create(owned.asSlice());
    owned.decref(&roc_ops);
    output.append(line);
    output.pump();
    if (output.first == null) return .ready;
    line.task = task;
    return waitFor(task, .{ .line = line });
}

/// The tasks to resume, in the order they became ready, from `ready_next`.
var ready: std.ArrayList(*RocTask) = .empty;
var ready_next: usize = 0;

/// `void roc_task_ready(RocTask *task)`.
fn taskReady(task: *RocTask) callconv(.c) void {
    ready.append(gpa, task) catch outOfMemory();
}

/// `void roc_task_abort(RocTask *task)`.
fn taskAbort(task: *RocTask) callconv(.c) void {
    const aborted = operations.fetchRemove(task) orelse die("an abort of a task that waits on nothing");
    switch (aborted.value) {
        .line => |line| output.abort(line),
        .timer => |subtask| {
            if (!timers.remove(subtask)) die("an abort of a timer that is over");
            // Cancelling blocks on the subtask, which must be in no set.
            canon.@"[waitable-join]"(subtask, 0);
            if (!canon.@"[subtask-cancel]"(subtask).resolved()) die("a cancelled subtask did not resolve");
            canon.@"[subtask-drop]"(subtask);
        },
    }
}

extern fn roc_main(result_out: *Outcome) callconv(.c) *RocTask;
extern fn roc_task_resume(task: *RocTask) callconv(.c) RocTaskStatus;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_cancel(task: *RocTask) callconv(.c) void;
extern fn roc_task_free(task: *RocTask) callconv(.c) void;

/// `Try({}, Str)`.
const Outcome = extern struct {
    message: RocStr,
    tag: enum(u8) { err = 0, ok = 1 },
};

var outcome: Outcome = undefined;
var root: *RocTask = undefined;
/// The root's terminal status, once it has reported it.
var root_status: ?RocTaskStatus = null;

/// The export `run`, which begins the program.
fn run() callconv(.c) u32 {
    // The host's state is one program's, so another call waits for this one.
    canon.@"[backpressure-inc]"();
    waitables = canon.@"[waitable-set-new]"();
    root = roc_main(&outcome);
    taskReady(root);
    return proceed();
}

/// What the program waited for happened.
fn callback(event: Event, waitable: u32, payload: u32) callconv(.c) u32 {
    switch (event) {
        .subtask => timerProgressed(waitable, @fromBackingInt(@intCast(payload))),
        .stream_write => {
            output.writing = false;
            output.progressed(@bitCast(payload));
        },
        .future_read => output.closed(),
        .task_cancelled => if (root_status == null) roc_task_cancel(root),
        .none, .stream_read, .future_write => die("an event the host never waits for"),
        _ => die("an unknown event"),
    }
    return proceed();
}

/// Run what is ready, then wait for an event or end the program.
fn proceed() u32 {
    output.pump();
    while (ready_next < ready.items.len) {
        const task = ready.items[ready_next];
        ready_next += 1;
        const status = roc_task_resume(task);
        if (task == root and status != .pending) root_status = status;
    }
    ready.clearRetainingCapacity();
    ready_next = 0;

    const status = root_status orelse return waitOn(waitables);
    if (!output.close()) return waitOn(waitables);
    finish(status);
    return exit;
}

fn finish(status: RocTaskStatus) void {
    roc_task_free(root);
    var failed = output.failed;
    if (status == .done) {
        if (outcome.tag == .err) {
            failed = true;
            errors.line(outcome.message.asSlice());
            outcome.message.decref(&roc_ops);
        }
    }
    if (live_allocations != 0) die("the program ended with memory it had not freed");
    errors.close();
    canon.@"[waitable-set-drop]"(waitables);
    root_status = null;
    output.unread = false;
    output.failed = false;
    canon.@"[backpressure-dec]"();
    switch (status) {
        .done => run_export.@"[task-return]run"(@intFromBool(failed)),
        .cancelled => canon.@"[task-cancel]"(),
        // wasm has no crash exit, so no task reports a crash.
        .pending, .crashed => unreachable, // rationale: a terminal status, and no crash exit
    }
}
