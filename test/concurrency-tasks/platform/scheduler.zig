//! The loop that drives the `concurrency: Tasks` test platform's task tree,
//! shared by its native host (host.zig) and its wasm host (wasm_host.zig).
//!
//! The root task comes from `roc_main`. A program that runs a concurrent
//! loop's entries as child tasks hands each child to the host through
//! `roc_task_ready`, and so does a wake or a cancel that unparks a task
//! (design.md "Host Contract"). The loop resumes ready tasks in the order
//! they were handed over. Only once none is ready does it answer a parked
//! `roc_host_fetch`: by default the oldest, so it answers fetches in the
//! order they were made, or the newest first, so a concurrent loop's entries
//! arrive in the reverse of their order. Answering wakes the fetching task
//! through the program's `roc_task_wake`, which hands it back. Each answer
//! counts as a pause.
//!
//! A program with one task gives the same pauses as a host that answers its
//! one fetch at a time. The runtime owns the child tasks, so the loop frees
//! none of them; the host frees the root once the loop returns.

const std = @import("std");
const builtins = @import("builtins");

const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;
const TaskStatus = builtins.task.Status;

/// `RocPoll` (design.md "Host Contract").
pub const poll_ready: u32 = 0;
/// `RocPoll` (design.md "Host Contract").
pub const poll_pending: u32 = 1;

/// Which parked fetch the loop answers when no task is ready.
pub const Order = enum { oldest_first, newest_first };

/// How a run goes.
pub const Config = struct {
    /// Answer every fetch during the call, so no task parks on one.
    finish_at_once: bool = false,
    /// Which parked fetch to answer next.
    order: Order = .oldest_first,
    /// The pause at which to cancel the root task instead of answering, if
    /// any. The program aborts every fetch its tree is parked on through
    /// `roc_task_abort`, and hands each unparked task back.
    cancel_at: ?u32 = null,
    /// Whether to answer and wake the pause's fetch before cancelling, so
    /// the program releases the answer.
    cancel_woken: bool = false,
};

/// How the root task ended.
pub const Outcome = enum { done, cancelled, crashed };

/// What makes a run fail.
pub const Error = error{
    /// The root reported CANCELLED without a cancel from the host.
    TaskCancelled,
    /// A resume reported a status no task can have.
    UnexpectedStatus,
    /// The root has not ended, yet no task is ready and no fetch is parked.
    Stuck,
};

/// A `fetch!` call a task is parked on.
const Pending = struct {
    task: *RocTask,
    out: *RocStr,
    url: RocStr,
};

/// Far more than any test program's tasks.
const capacity = 64;

var config: Config = .{};
var ops: *RocOps = undefined;
var pending: [capacity]Pending = undefined;
var pending_len: usize = 0;
var ready: [capacity]*RocTask = undefined;
var ready_len: usize = 0;
/// The `roc_host_fetch` calls made in this run.
pub var fetches: u32 = 0;
/// The fetches answered, or cancelled at, in this run.
pub var pauses: u32 = 0;

extern fn roc_task_resume(task: *RocTask) callconv(.c) u32;
extern fn roc_task_wake(task: *RocTask) callconv(.c) void;
extern fn roc_task_cancel(task: *RocTask) callconv(.c) void;

/// Start a run with `new_config`, allocating through `roc_ops`.
pub fn reset(new_config: Config, roc_ops: *RocOps) void {
    config = new_config;
    ops = roc_ops;
    pending_len = 0;
    ready_len = 0;
    fetches = 0;
    pauses = 0;
}

/// The answer to `fetch!(url)`. It owns `url`.
fn answer(url: RocStr) RocStr {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "fetched({s})", .{url.asSlice()}) catch "fetched(...)";
    var owned = url;
    owned.decref(ops);
    return RocStr.fromSlice(text, ops);
}

/// `RocPoll roc_host_fetch(RocTask *task, RocStr *out, RocStr url)`.
pub fn fetch(task: *RocTask, out: *RocStr, url: RocStr) u32 {
    fetches += 1;
    if (config.finish_at_once) {
        out.* = answer(url);
        return poll_ready;
    }
    // design.md "Host Contract": the host resumes a task only after a resume
    // returns, so one task waits on at most one call.
    for (pending[0..pending_len]) |parked| {
        if (parked.task == task) @panic("a second fetch from a task with one pending");
    }
    if (pending_len == capacity) @panic("more parked fetches than the host holds");
    pending[pending_len] = .{ .task = task, .out = out, .url = url };
    pending_len += 1;
    return poll_pending;
}

/// `void roc_task_abort(RocTask *task)`: abandon the fetch the cancelled
/// task is parked on, releasing its URL.
pub fn abort(task: *RocTask) void {
    for (pending[0..pending_len], 0..) |parked, index| {
        if (parked.task != task) continue;
        var url = take(index).url;
        url.decref(ops);
        return;
    }
    @panic("roc_task_abort for a task with no fetch pending");
}

/// `void roc_task_ready(RocTask *task)`: queue the task for the loop.
pub fn readied(task: *RocTask) void {
    if (ready_len == capacity) @panic("more ready tasks than the host holds");
    ready[ready_len] = task;
    ready_len += 1;
}

/// Remove and return the parked fetch at `index`, keeping the others in
/// order.
fn take(index: usize) Pending {
    const parked = pending[index];
    std.mem.copyForwards(Pending, pending[index .. pending_len - 1], pending[index + 1 .. pending_len]);
    pending_len -= 1;
    return parked;
}

/// Drive `root` and the tasks it starts until `root` ends.
pub fn run(root: *RocTask) Error!Outcome {
    var cancel_requested = false;
    readied(root);
    while (true) {
        if (ready_len > 0) {
            const task = ready[0];
            std.mem.copyForwards(*RocTask, ready[0 .. ready_len - 1], ready[1..ready_len]);
            ready_len -= 1;
            const status = roc_task_resume(task);
            // A child's end reaches its owner through the runtime, which
            // readies the owner.
            if (task != root) continue;
            if (status == @backingInt(TaskStatus.done)) return .done;
            if (status == @backingInt(TaskStatus.crashed)) return .crashed;
            if (status == @backingInt(TaskStatus.cancelled)) {
                if (!cancel_requested) return error.TaskCancelled;
                return .cancelled;
            }
            if (status != @backingInt(TaskStatus.pending)) return error.UnexpectedStatus;
            continue;
        }
        if (pending_len == 0) return error.Stuck;
        pauses += 1;
        const cancelling = config.cancel_at == pauses;
        // Unanswered, the fetch stays parked for the program to abort.
        if (!cancelling or config.cancel_woken) {
            const parked = take(if (config.order == .oldest_first) 0 else pending_len - 1);
            parked.out.* = answer(parked.url);
            roc_task_wake(parked.task);
        }
        if (cancelling) {
            cancel_requested = true;
            roc_task_cancel(root);
        }
    }
}
