//! The task a `concurrency: Tasks` program runs in (design.md "Records And
//! The Task"). LIR reaches it only through the `task_*` low-level
//! operations, which read and write its first three fields. The rest is the
//! runtime's: the record list, the root's result storage and the buffers'
//! sizes. Every backend shares it, since a record is called through the
//! erased-callable ABI.

const std = @import("std");

const crash_exit = @import("task_crash_exit.zig");
const erased_callable = @import("erased_callable.zig");
const str = @import("str.zig");
const utils = @import("utils.zig");

const RocOps = utils.RocOps;

/// Releases the hosted result in `slot`, as the `slot_drop` RC helper
/// `suspend_save` names does. It also gets the hosted site's record, which
/// is where an interpreter's release finds its interpreter and the layout.
pub const SlotDropFn = *const fn (slot: [*]u8, record: [*]u8, ops: *RocOps) callconv(.c) void;

/// What `resume` reports, as `roc_task_resume` returns it.
pub const Status = enum(u8) {
    pending,
    done,
    cancelled,
    crashed,
};

/// One saved record: a boxed erased callable's data pointer, holding one
/// reference, and the release of the hosted result when it is a hosted
/// site's record.
pub const Entry = extern struct {
    record: [*]u8,
    slot_drop: ?SlotDropFn,
    /// Whether the task allocated the record (`allocRecord`), so releasing
    /// it returns it to the task's record cache. Only the start record is
    /// not (design.md "The Task Runtime", "Record cache").
    from_task: bool,
};

/// The record cache's size classes: a payload of up to `record_class_bytes *
/// record_classes` bytes is served from the free list of its class.
const record_class_bytes = 16;
const record_classes = 32;

/// A record's class, 1 to `record_classes`, or 0 for a payload too large to
/// cache.
fn recordClass(payload_size: usize) u32 {
    if (payload_size == 0 or payload_size > record_class_bytes * record_classes) return 0;
    return @intCast((payload_size + record_class_bytes - 1) / record_class_bytes);
}

/// The word before a record's reference count, which an allocation with
/// one reference leaves unused (`utils.allocateWithRefcount` with alignment
/// `erased_callable.payload_alignment`): `allocRecord` keeps the record's
/// class there.
fn recordClassWord(record: [*]u8) *u32 {
    return @ptrCast(@alignCast(record - erased_callable.payload_alignment));
}

/// A cached record's link to the next one of its class, kept in its payload.
fn recordNext(record: [*]u8) *?[*]u8 {
    return @ptrCast(@alignCast(record));
}

comptime {
    // The class word and the reference count must not overlap.
    std.debug.assert(@sizeOf(u32) + @sizeOf(usize) <= erased_callable.payload_alignment);
    std.debug.assert(!erased_callable.allocation_has_refcounted_children);
}

/// The host's `roc_task_abort`: abandon the operation a cancelled task is
/// parked on (design.md "Host Contract").
pub const AbortFn = *const fn (*RocTask) callconv(.c) void;

/// The host's `roc_task_ready`: resume the task once (design.md "Host
/// Contract"). The runtime calls it from `wake` exactly once per park.
pub const ReadyFn = *const fn (*RocTask) callconv(.c) void;

/// The wake word's parked bit (design.md "The Task Runtime"). The low bits
/// count completions the host published and no resume has consumed yet.
pub const wake_parked: u32 = 1 << 31;

/// Whether the runtime checks the host contract: the conformance monitors
/// (design.md "The Task Runtime", "Conformance"). Only a runtime with safety
/// checks does; a release runtime pays nothing for them.
const monitors = std.debug.runtime_safety;

/// A host broke the host contract (design.md "Host Contract"). A runtime
/// with monitors crashes with the obligation's message, through the host's
/// `roc_crashed` and never a task's crash exit, since the host may break the
/// contract on any thread. One without does no check, and the caller
/// carries on as the contract assumes. Each check runs before the operation
/// changes the task, so a host that survives the crash (the conformance
/// harness) finds the task as it was.
fn hostViolation(ops: *RocOps, comptime message: []const u8) void {
    if (monitors) ops.crashHost("host contract violated: " ++ message);
}

/// The task whose resume is running, claimed by every resume of a `Tasks`
/// program while the monitors are on: a resume that finds it taken
/// overlapped another (P10), or ran inside its own task's resume, from a
/// hosted call (P1).
var resuming: ?*RocTask = null;

/// Recently freed tasks, with their ops, so a host that uses a task after
/// freeing it (P8) is caught while the address is remembered. `create`
/// forgets an address the allocator hands out again. Only while the
/// monitors are on.
const freed_capacity = 64;
var freed_tasks: [freed_capacity]usize = @splat(0);
var freed_ops: [freed_capacity]usize = @splat(0);
var freed_next: u32 = 0;

fn noteFreed(task: *RocTask, ops: *RocOps) void {
    if (!monitors) return;
    const index = @atomicRmw(u32, &freed_next, .Add, 1, .monotonic) % freed_capacity;
    @atomicStore(usize, &freed_ops[index], @intFromPtr(ops), .monotonic);
    @atomicStore(usize, &freed_tasks[index], @intFromPtr(task), .release);
}

fn forgetFreed(task: *RocTask) void {
    if (!monitors) return;
    for (&freed_tasks) |*slot| _ = @cmpxchgStrong(usize, slot, @intFromPtr(task), 0, .monotonic, .monotonic);
}

/// Crash if `task` was freed (P8): `operation` is what the host did with it.
fn checkNotFreed(task: *RocTask, comptime operation: []const u8) void {
    if (!monitors) return;
    for (&freed_tasks, &freed_ops) |*slot, *ops| {
        if (@atomicLoad(usize, slot, .acquire) != @intFromPtr(task)) continue;
        const freed_with: *RocOps = @ptrFromInt(@atomicLoad(usize, ops, .monotonic));
        hostViolation(freed_with, "a task was " ++ operation ++ " after it was freed (P8)");
    }
}

/// The sizes and alignments of a task's two buffers, which the continuation
/// pass records as program constants.
pub const BufferLayout = struct {
    hosted_slot_size: usize,
    hosted_slot_alignment: usize,
    result_buffer_size: usize,
    result_buffer_alignment: usize,
};

/// The C-ABI task calls a backend's runtime exports to the host (design.md
/// "Host Contract"). The program defines `roc_task_resume`
/// (`RocTask.resumeFromHost`), which returns a `RocTaskStatus`, a C enum:
/// `PENDING`, `DONE`, `CANCELLED`, `CRASHED` in `Status` order.
pub const host_calls = struct {
    pub fn free(task: *RocTask) callconv(.c) void {
        task.free();
    }

    /// `roc_task_crash_message`: the message of a task that crashed, as the
    /// bytes and length of a UTF-8 string the task owns until it is freed.
    pub fn crashMessage(task: *RocTask, len: *usize) callconv(.c) [*]const u8 {
        if (task.status != .crashed) utils.builtinInvariant(task.ops, "the crash message of a task that did not crash was read");
        len.* = task.crash_message_len;
        return task.crash_message;
    }
};

/// The host's `roc_task_thread_slot` in a `ParallelTasks` program: the
/// address of the running-task pointer the host keeps for the calling
/// thread, null until a resume on that thread sets it (design.md "Parallel
/// Resumes").
pub const ThreadSlotFn = *const fn () callconv(.c) *?*RocTask;

/// The task whose resume is running, which a crash exits to, or the task
/// whose probe is. A `Tasks`
/// program's resumes never overlap (design.md "The Task Runtime"), so one
/// pointer per process is enough.
var running_serial: ?*RocTask = null;

/// `Scheduler.crashed`, from a `None` program's first run that can wait on; a
/// program that has none doesn't link it.
var run_crashed: ?*const fn () void = null;

/// The host's thread slots, from the first resume of a `ParallelTasks`
/// program on; null in every other program.
var thread_slot: ?ThreadSlotFn = null;

/// The calling thread's running-task pointer.
fn runningSlot() *?*RocTask {
    const slot = @atomicLoad(?ThreadSlotFn, &thread_slot, .monotonic) orelse return &running_serial;
    return slot();
}

/// Take the crash exit of the running task, if there is one and the target
/// has crash exits: keep `msg` in the task and jump back to its resume.
/// Returns otherwise, and the caller hands the crash to the host. A `None`
/// program's tasks have no crash exit, only its probes do.
pub fn crashRunning(msg: []const u8) void {
    const slot = runningSlot();
    const task = slot.* orelse {
        const crashed_in_run = @atomicLoad(?*const fn () void, &run_crashed, .monotonic) orelse return;
        return crashed_in_run();
    };
    if (!crash_exit.available()) return;
    // A crash while copying the message must reach the host, not loop.
    slot.* = null;
    // A probe's crash is its answer (`RocTask.probe`), not the waiter's crash.
    if (task.probing) crash_exit.jump(&task.crash_jmp);
    task.lockTree();
    task.takeCrash(msg);
    task.unlockTree();
    crash_exit.jump(&task.crash_jmp);
}

/// Clear the running task for a hosted call and return it, so a crash in
/// the host ends the process rather than the task: the host's frames sit
/// between the task's resume and the crash, and the exit would skip them.
pub fn hostEnter() ?*RocTask {
    const slot = runningSlot();
    const task = slot.*;
    slot.* = null;
    return task;
}

/// Restore the running task `hostEnter` returned once the hosted call is
/// back.
pub fn hostLeave(task: ?*RocTask) void {
    const slot = runningSlot();
    std.debug.assert(slot.* == null); // rationale: hostEnter cleared it, and any resume ends by clearing it
    slot.* = task;
}

/// Where compiled code finds the three fields the `task_*` low-level
/// operations reach, for a target whose pointers are `pointer_size` bytes
/// (design.md "Backends"): `pending` first, then the two buffer pointers,
/// each at the next pointer-aligned offset. The comptime check below holds
/// `RocTask` to it.
pub const FieldOffsets = struct {
    pending: u32,
    hosted_slot: u32,
    result_buffer: u32,

    /// The offsets on a target with `pointer_size`-byte pointers.
    pub fn forPointerSize(pointer_size: u32) FieldOffsets {
        return .{ .pending = 0, .hosted_slot = pointer_size, .result_buffer = 2 * pointer_size };
    }
};

comptime {
    const native = FieldOffsets.forPointerSize(@sizeOf(usize));
    if (@offsetOf(RocTask, "pending") != native.pending or
        @offsetOf(RocTask, "hosted_slot") != native.hosted_slot or
        @offsetOf(RocTask, "result_buffer") != native.result_buffer or
        @sizeOf(@FieldType(RocTask, "pending")) != 1)
        @compileError("RocTask's first three fields moved; compiled code reads them at FieldOffsets");
}

/// One task. The runtime owns it; LIR holds a pointer to it with no
/// reference count.
pub const RocTask = extern struct {
    /// Nonzero while the task is paused on an operation that has not
    /// finished. Resuming clears it.
    pending: u8,
    /// Where a `suspending` hosted procedure writes its result.
    hosted_slot: [*]u8,
    /// Where a resumed record writes the result of a procedure that may
    /// suspend, and where its caller's resume entry reads it.
    result_buffer: [*]u8,

    /// The wake word of the task's one wait source, its hosted operation:
    /// `wake_parked` while the task is parked, and a count of completions
    /// published and not yet consumed (design.md "The Task Runtime"). The
    /// only field two threads touch, so only atomic operations reach it.
    wake_word: u32,
    /// Whether the host's first resume has run; a later resume needs a
    /// `roc_task_ready`.
    started: bool,
    /// Whether the host asked to cancel the task (`roc_task_cancel`): its
    /// next resume runs no Roc code and reports `cancelled`.
    cancel_requested: bool,
    /// `pending` while the task can be resumed or cancelled.
    status: Status,
    /// Whether a cancel's `roc_task_abort` returned, after which the host
    /// must not wake the task (P4). Kept while the monitors are on.
    aborted: bool,
    /// The host's `roc_task_ready` and `roc_task_abort`, which its resume
    /// hands the runtime for the task's children (design.md "Child Tasks").
    /// Null until the host's first resume.
    ready_fn: ?ReadyFn,
    abort_fn: ?AbortFn,
    /// Where the outermost record writes the root's result.
    root_result: [*]u8,
    /// The records, innermost last.
    entries: [*]Entry,
    len: usize,
    capacity: usize,
    hosted_slot_size: usize,
    hosted_slot_alignment: usize,
    result_buffer_size: usize,
    result_buffer_alignment: usize,
    ops: *RocOps,
    /// Where a crash in this task's resume jumps back to.
    crash_jmp: crash_exit.Buffer,
    /// The record whose call is running, which a crash releases.
    running_record: [*]u8,
    /// A crashed task's message, which it owns.
    crash_message: [*]const u8,
    crash_message_len: usize,
    /// Whether the running record is one the task allocated.
    running_from_task: bool,
    /// Released records the task allocated, by class, for its next
    /// suspensions (design.md "The Task Runtime", "Record cache").
    record_cache: [record_classes]?[*]u8,
    /// A child's group, whose owner is its parent, and its entry there
    /// (design.md "Child Tasks"); null for a root.
    group: ?*Group,
    entry_index: u32,
    /// The task's place among its parent's children, fixed when its entry
    /// was made, so the tree order is creation order.
    tree_index: u32,
    /// The places this task has handed its groups' entries so far.
    child_counter: u32,
    /// The group whose wake word the task is parked on, or null while it
    /// waits on its hosted operation (its own `wake_word`).
    wait: ?*Group,
    /// Whether the wake word the task is parked on is `cell_word`.
    waits_on_cell: bool,
    /// The wake word of the task's wait on a cell of shared state:
    /// `wake_parked` while it is parked there, and 1 once a wake came that no
    /// resume has consumed.
    cell_word: u32,
    /// The cell the task waits on, from an update's `Wait` until an update of
    /// the cell answers without one or the task ends; null otherwise (design.md
    /// "Shared State", "Waiting"). The next three fields are set with it.
    waited_cell: ?*anyopaque,
    /// The probe of the update that waits, a boxed erased callable the task
    /// holds a reference to.
    waiting_probe: [*]u8,
    /// The waiters before and after this one, oldest first, among the cells
    /// that share its `CellWaiters`.
    older_waiter: ?*RocTask,
    newer_waiter: ?*RocTask,
    /// Whether the task was readied by a wake its update has not yet answered.
    carries_wake: bool,
    /// The lock the task's running update holds in a `ParallelTasks` program,
    /// until it settles, parks or crashes.
    locked_cells: ?*CellWaiters,
    /// The waiter a waiting update passed its wake on to, which the task's
    /// park tells the host of.
    passed_wake: HostCalls,
    /// Whether the task's probe is running, in another task's resume, and the
    /// task that was running there.
    probing: bool,
    probe_goes_on: bool,
    probe_outer: ?*RocTask,
    /// The innermost group the task's code has open; each holds the next
    /// one out (`Group.outer`).
    open_groups: ?*Group,
    /// Whether the task runs no more of its code: its records are released,
    /// and it ends once its children have reported (design.md "Child
    /// Tasks").
    finishing: bool,
    /// Whether the task ends `crashed`, with `crash_message`: its own crash,
    /// or one of its entries'.
    crashing: bool,
    /// Whether one of the task's resumes is running, in a `ParallelTasks`
    /// program while the monitors are on (P1).
    resume_claimed: bool,
    /// The lock of the task's tree, in a `ParallelTasks` program: the root's
    /// `tree_lock`. Null in a `Tasks` program, whose resumes never overlap.
    tree: ?*u32,
    /// A root's lock over its tree (design.md "Parallel Resumes"): 0 free,
    /// 1 held.
    tree_lock: u32,
    /// The next task in a list of host calls due once the tree is unlocked
    /// (`HostCalls`), and whether this one's operation is abandoned first.
    host_next: ?*RocTask,
    host_abort: bool,
    /// The run that resumes the task, in a `None` program; null in a program
    /// whose host does.
    scheduler: ?*Scheduler,
    /// The task's place in the heap that holds it (`TaskHeap`).
    heap_child: ?*RocTask,
    heap_sibling: ?*RocTask,

    /// A task with no records, which has not run.
    pub fn initial(ops: *RocOps, root_result: [*]u8, buffers: BufferLayout, hosted_slot: [*]u8, result_buffer: [*]u8) RocTask {
        return .{
            .pending = 0,
            .hosted_slot = hosted_slot,
            .result_buffer = result_buffer,
            .wake_word = 0,
            .started = false,
            .cancel_requested = false,
            .status = .pending,
            .aborted = false,
            .ready_fn = null,
            .abort_fn = null,
            .root_result = root_result,
            .entries = undefined,
            .len = 0,
            .capacity = 0,
            .hosted_slot_size = buffers.hosted_slot_size,
            .hosted_slot_alignment = buffers.hosted_slot_alignment,
            .result_buffer_size = buffers.result_buffer_size,
            .result_buffer_alignment = buffers.result_buffer_alignment,
            .ops = ops,
            .crash_jmp = undefined,
            .running_record = undefined,
            .crash_message = undefined,
            .crash_message_len = 0,
            .running_from_task = false,
            .record_cache = @splat(null),
            .group = null,
            .entry_index = 0,
            .tree_index = 0,
            .child_counter = 0,
            .wait = null,
            .waits_on_cell = false,
            .cell_word = 0,
            .waited_cell = null,
            .waiting_probe = undefined,
            .older_waiter = null,
            .newer_waiter = null,
            .carries_wake = false,
            .locked_cells = null,
            .passed_wake = .{},
            .probing = false,
            .probe_goes_on = false,
            .probe_outer = null,
            .open_groups = null,
            .finishing = false,
            .crashing = false,
            .resume_claimed = false,
            .tree = null,
            .tree_lock = 0,
            .host_next = null,
            .host_abort = false,
            .scheduler = null,
            .heap_child = null,
            .heap_sibling = null,
        };
    }

    /// A task whose list holds `start`, the root's start record, and whose
    /// outermost record writes to `root_result`. The host's first resume
    /// runs it.
    pub fn create(ops: *RocOps, start: [*]u8, root_result: [*]u8, buffers: BufferLayout) *RocTask {
        const task: *RocTask = @ptrCast(@alignCast(ops.alloc(@alignOf(RocTask), @sizeOf(RocTask))));
        task.* = initial(
            ops,
            root_result,
            buffers,
            allocBuffer(ops, buffers.hosted_slot_size, buffers.hosted_slot_alignment),
            allocBuffer(ops, buffers.result_buffer_size, buffers.result_buffer_alignment),
        );
        task.push(.{ .record = start, .slot_drop = null, .from_task = false });
        forgetFreed(task);
        return task;
    }

    /// `create` for the root of a `ParallelTasks` program: the root has its
    /// tree's lock from the start, since its tree may be touched by two
    /// threads from its first resume on (design.md "Parallel Resumes").
    pub fn createParallel(ops: *RocOps, start: [*]u8, root_result: [*]u8, buffers: BufferLayout) *RocTask {
        const task = create(ops, start, root_result, buffers);
        task.tree = &task.tree_lock;
        return task;
    }

    /// `task_ready`: whether the pending flag is clear.
    pub fn ready(self: *const RocTask) bool {
        return self.pending == 0;
    }

    /// `task_set_pending`.
    pub fn setPending(self: *RocTask) void {
        self.pending = 1;
    }

    /// `task_alloc_record`: memory for a record of `payload_size` bytes with
    /// one reference, from the record cache when its class has one.
    pub fn allocRecord(self: *RocTask, payload_size: usize) [*]u8 {
        const class = recordClass(payload_size);
        if (class != 0) {
            if (self.record_cache[class - 1]) |record| {
                // Its reference count is still the one it was released with.
                self.record_cache[class - 1] = recordNext(record).*;
                return record;
            }
        }
        const size = if (class == 0) payload_size else class * record_class_bytes;
        const record = utils.allocateWithRefcount(size, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, self.ops);
        recordClassWord(record).* = class;
        return record;
    }

    /// What `suspend_save` does with the record it packed in memory from
    /// `allocRecord`: the list takes the record's one reference.
    pub fn pushRecord(self: *RocTask, record: [*]u8, slot_drop: ?SlotDropFn) void {
        self.push(.{ .record = record, .slot_drop = slot_drop, .from_task = true });
    }

    /// How many released records the cache holds: the allocations freeing
    /// the task releases beyond its own.
    pub fn cachedRecordCount(self: *const RocTask) usize {
        var count: usize = 0;
        for (self.record_cache) |head| {
            var next = head;
            while (next) |record| : (next = recordNext(record).*) count += 1;
        }
        return count;
    }

    fn push(self: *RocTask, entry: Entry) void {
        if (self.len == self.capacity) self.grow();
        self.entries[self.len] = entry;
        self.len += 1;
    }

    /// Release a record the list held: run its capture's `on_drop` and keep
    /// its memory for the task's next suspension, or, for the start record,
    /// release it as any boxed erased callable.
    fn releaseRecord(self: *RocTask, record: [*]u8, from_task: bool) void {
        if (!from_task) return erased_callable.decref(record, self.ops);
        std.debug.assert(utils.isUnique(record, self.ops)); // rationale: the list holds a record's only reference (design.md "Backends")
        if (erased_callable.payloadPtr(record).on_drop) |on_drop| on_drop(erased_callable.capturePtr(record), self.ops);
        const class = recordClassWord(record).*;
        if (class == 0) return utils.freeDataPtrC(record, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, self.ops);
        recordNext(record).* = self.record_cache[class - 1];
        self.record_cache[class - 1] = record;
    }

    /// Take the lock of the task's tree, if it has one. The holder runs no
    /// Roc code and calls no task function of the host; it may allocate.
    fn lockTree(self: *const RocTask) void {
        const lock = self.tree orelse return;
        while (@cmpxchgWeak(u32, lock, 0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    /// Release the lock of the task's tree. The root, which holds it, may be
    /// freed as soon as it is released, so this is the holder's last access.
    fn unlockTree(self: *const RocTask) void {
        const lock = self.tree orelse return;
        @atomicStore(u32, lock, 0, .release);
    }

    /// `roc_task_resume` of a `Tasks` program (`roc_builtins_task_resume`):
    /// keep the host's `ready_fn` and `abort_fn` on the task for its children
    /// (design.md "Child Tasks"), then resume it.
    pub fn resumeFromHost(self: *RocTask, ready_fn: ReadyFn, abort_fn: AbortFn) Status {
        if (!self.resumable()) return self.status;
        self.keepHostFns(ready_fn, abort_fn);
        return self.resumeChecked();
    }

    /// `roc_task_resume` of a `ParallelTasks` program
    /// (`roc_builtins_task_resume_parallel`), whose resumes of different
    /// tasks may overlap (design.md "Parallel Resumes").
    pub fn resumeParallelFromHost(self: *RocTask, ready_fn: ReadyFn, abort_fn: AbortFn, thread_slot_fn: ThreadSlotFn) Status {
        if (!self.resumable()) return self.status;
        @atomicStore(?ThreadSlotFn, &thread_slot, thread_slot_fn, .monotonic);
        std.debug.assert(self.tree != null); // rationale: a `ParallelTasks` root is made by `createParallel`, and a child copies its parent's tree
        self.keepHostFns(ready_fn, abort_fn);
        return self.resumeChecked();
    }

    /// Keep the host's functions, which are the same at every call, at the
    /// first: after it, the task's children read them on their own threads.
    fn keepHostFns(self: *RocTask, ready_fn: ReadyFn, abort_fn: AbortFn) void {
        if (self.ready_fn == null) self.ready_fn = ready_fn;
        if (self.abort_fn == null) self.abort_fn = abort_fn;
    }

    /// Resume the task with the host functions it has: run records,
    /// innermost first, until the list is empty, the task pauses again or
    /// it crashes. A host resumes through `resumeFromHost`.
    pub fn resumeTask(self: *RocTask) Status {
        if (!self.resumable()) return self.status;
        return self.resumeChecked();
    }

    /// Whether the host may resume the task: not after it was freed or
    /// ended (P8). The check comes before the resume changes the task.
    fn resumable(self: *RocTask) bool {
        checkNotFreed(self, "resumed");
        if (monitors and self.status != .pending) {
            hostViolation(self.ops, "a task was resumed after it ended (P8)");
            return false;
        }
        return true;
    }

    fn resumeChecked(self: *RocTask) Status {
        const serial = self.tree == null;
        self.claimResume();
        const status = self.runResume();
        // A parallel resume gave up its claim when it parked, after which the
        // task may be gone; giving up a serial one only compares pointers.
        if (serial) self.releaseSerialResume();
        return status;
    }

    fn runResume(self: *RocTask) Status {
        // Readied: the parked bit of the word the task waited on is clear.
        // For its hosted operation the host's one completion is counted,
        // unless a cancel or a crash readied it; a group has at least one
        // report waiting, and a cell its one wake.
        self.lockTree();
        if (monitors and self.started) {
            const seen = @atomicLoad(u32, self.waitWord(), .monotonic);
            const readied = if (self.finishing or self.cancel_requested or self.crashing)
                seen & wake_parked == 0
            else if (!self.waitsOnOperation())
                seen & wake_parked == 0 and seen != 0
            else
                seen == 1;
            if (!readied) {
                self.unlockTree();
                self.releaseResume();
                hostViolation(self.ops, "a task was resumed without a roc_task_ready (P1)");
            }
        }
        // Consuming a hosted completion with acquire ordering makes the
        // hosted slot the host wrote visible. A group's reports stay queued
        // for `groupNext`.
        const completed = self.started and self.waitsOnOperation() and self.consumeCompletion();
        self.started = true;
        self.endWait();
        const ending = self.finishing or self.cancel_requested or self.crashing;
        self.unlockTree();
        if (monitors and !ending and self.tree == null) {
            if (self.group) |group| {
                const owner = group.owner;
                if (owner.cancel_requested or owner.crashing) utils.builtinInvariant(self.ops, "a task's code ran after its owner was cancelled or crashed");
            }
        }
        if (ending) return self.finish(completed);
        self.pending = 0;
        const exits = self.scheduler == null and crash_exit.available();
        while (self.len > 0) {
            self.len -= 1;
            const entry = self.entries[self.len];
            const base = self.len;
            // Set on every target: a settled update finds its task there. A
            // `None` program's runs may overlap on several threads, so they
            // keep no running task for the process.
            if (self.scheduler == null) runningSlot().* = self;
            if (exits) {
                // Kept in the task, since a crash exit restores no local.
                self.running_record = entry.record;
                self.running_from_task = entry.from_task;
                if (crash_exit.save(&self.crash_jmp) != 0) return self.crashed();
            }
            self.call(entry.record, if (base == 0) self.root_result else self.result_buffer);
            if (self.scheduler == null) runningSlot().* = null;
            std.mem.reverse(Entry, self.entries[base..self.len]);
            self.releaseRecord(entry.record, entry.from_task);
            if (self.pending != 0) switch (self.park()) {
                .parked => return .pending,
                // The completion or the report came before the park: run
                // on, from the suspension site's resume entry.
                .ready => self.pending = 0,
                .ending_wait => return self.finish(false),
                .ending_operation => {
                    // Once `roc_task_abort` returns, no completion follows
                    // (P4).
                    callHost(self.abort_fn.?, self);
                    if (monitors) @atomicStore(bool, &self.aborted, true, .monotonic);
                    return self.finish(self.consumeCompletion());
                },
            };
        }
        if (self.open_groups != null) utils.builtinInvariant(self.ops, "a task's code finished with a concurrent loop still open");
        return self.end(.done);
    }

    /// The wake word of the task's wait source: its hosted operation's, or
    /// the group's or the cell's it waits on.
    fn waitWord(self: *RocTask) *u32 {
        if (self.waits_on_cell) return &self.cell_word;
        return if (self.wait) |group| &group.word else &self.wake_word;
    }

    /// Whether the task's wait source is its hosted operation.
    fn waitsOnOperation(self: *const RocTask) bool {
        return self.wait == null and !self.waits_on_cell;
    }

    /// The task waits on its source no more. A group's reports stay queued,
    /// and a cell's wake is consumed here: the update the task runs next
    /// answers it.
    fn endWait(self: *RocTask) void {
        self.wait = null;
        if (!self.waits_on_cell) return;
        self.waits_on_cell = false;
        @atomicStore(u32, &self.cell_word, 0, .monotonic);
    }

    /// Take the hosted operation's completion, if the host published one.
    fn consumeCompletion(self: *RocTask) bool {
        return @atomicRmw(u32, &self.wake_word, .Xchg, 0, .acquire) & ~wake_parked != 0;
    }

    /// Back from a crash exit: the records saved at call sites are
    /// consistent, so release them all; what the running frames owned is
    /// leaked. The task's children are cancelled, and it ends `crashed`
    /// once they have reported.
    fn crashed(self: *RocTask) Status {
        self.endUpdate();
        self.releaseRecord(self.running_record, self.running_from_task);
        // The crash may have been an update's, which poisons its cell.
        probeEveryCell(self.tree != null);
        return self.finish(false);
    }

    const Park = enum {
        /// The task is parked: another thread may already be resuming it.
        parked,
        /// Its source already has something for it.
        ready,
        /// While its resume ran, a cancel reached it or one of its entries
        /// crashed (a `ParallelTasks` program only), so it runs no more of
        /// its code. It paused at a loop's `next`, or on a hosted operation
        /// to abandon.
        ending_wait,
        ending_operation,
    };

    /// Park the task, whose code paused, on its wait source: set the parked
    /// bit of its wake word, but only while the word is zero. It is not
    /// when a host finished on another thread before the hosted function
    /// returned, or a report was queued since `groupNext` looked. The resume
    /// then carries on, so nothing is lost and no `roc_task_ready` is due.
    ///
    /// A cancel or an entry's crash marks the task and unparks it under the
    /// tree's lock, so either it finds the task parked here, or this finds
    /// the mark.
    ///
    /// An update that waits keeps its cell's lock until here, so that a probe
    /// of the task, on another thread, finds its crash exit free.
    fn park(self: *RocTask) Park {
        self.endUpdate();
        self.releaseParallelResume();
        self.lockTree();
        if (self.cancel_requested or self.crashing) {
            const operation = self.waitsOnOperation();
            self.endWait();
            self.unlockTree();
            self.claimParallelResume();
            return if (operation) .ending_operation else .ending_wait;
        }
        if (self.parkOnWait()) return .parked;
        self.claimParallelResume();
        return .ready;
    }

    /// The task runs no more of its code, for now or for good, so an update it
    /// was running releases its lock, and then tells the host of the wake it
    /// passed on.
    fn endUpdate(self: *RocTask) void {
        if (self.locked_cells) |cells| {
            self.locked_cells = null;
            cells.unlock();
        }
        const calls = self.passed_wake;
        self.passed_wake = .{};
        calls.make();
    }

    /// Park on the wait source with the tree locked, and unlock it. False,
    /// with no wait left, when the source has something for the task.
    fn parkOnWait(self: *RocTask) bool {
        const word = self.waitWord();
        const seen = @cmpxchgStrong(u32, word, 0, wake_parked, .acq_rel, .acquire) orelse {
            self.unlockTree();
            return true;
        };
        const hosted = self.waitsOnOperation();
        self.endWait();
        self.unlockTree();
        if (hosted) {
            if (seen != 1) hostViolation(self.ops, "a task was woken more than once for one operation (P3)");
            @atomicStore(u32, word, 0, .monotonic);
        }
        return false;
    }

    /// `roc_task_wake`, from any thread: the host wrote the hosted slot.
    /// Count the completion and clear the parked bit in one atomic step
    /// with release ordering, so the slot is visible to the resume that
    /// consumes it; if the task was parked, it is ready to resume, so tell
    /// the host once through `ready_fn`, the host's `roc_task_ready`.
    ///
    /// The hosted operation is one wait source, so a completion is never
    /// counted twice: the swap's result is 0 (running, not yet parked) or
    /// `wake_parked`. A group's wake word is another source, whose count
    /// may exceed one (`Group.word`).
    pub fn wake(self: *RocTask, ready_fn: ReadyFn) void {
        checkNotFreed(self, "woken");
        if (monitors and @atomicLoad(bool, &self.aborted, .monotonic)) hostViolation(self.ops, "a task was woken after its operation was aborted (P4)");
        if (monitors and @atomicLoad(u32, &self.wake_word, .monotonic) & ~wake_parked != 0) hostViolation(self.ops, "a task was woken more than once for one operation (P3)");
        const word = @atomicRmw(u32, &self.wake_word, .Xchg, 1, .release);
        if (word & wake_parked != 0) ready_fn(self);
    }

    /// `roc_task_cancel`, between resumes: request that the task's next
    /// resume finish it (design.md "The Task Runtime", "Cancellation").
    /// Only a root's host cancels it; the runtime cancels children.
    pub fn cancel(self: *RocTask, abort: AbortFn, ready_fn: ReadyFn) void {
        checkNotFreed(self, "cancelled");
        if (monitors and self.status != .pending) return hostViolation(self.ops, "a task was cancelled after it ended (P8)");
        if (monitors and self.group != null) return hostViolation(self.ops, "the host cancelled a child task, which only the runtime cancels (P8)");
        self.keepHostFns(ready_fn, abort);
        var calls: HostCalls = .{};
        self.lockTree();
        self.requestCancel(&calls);
        self.unlockTree();
        calls.make();
    }

    /// Request that the task's next resume finish it. A task parked with
    /// nothing for it is unparked here: its hosted operation abandoned with
    /// `roc_task_abort`, if it waits on one, and the task readied with
    /// `roc_task_ready`. One that has something was readied by its source,
    /// or is about to be, and a new task is resumed anyway. One that is
    /// running, in a `ParallelTasks` program, finds the request when it next
    /// parks. The tree is locked.
    ///
    /// Unparking is a compare-and-swap from parked to zero, so exactly one
    /// of this and a racing wake or report clears the parked bit, and that
    /// one readies the task. A wake that lands between the swap and the
    /// abort counts its completion without readying; the finishing resume
    /// releases it.
    ///
    /// A task that isn't running never runs its code again, so its entries are
    /// cancelled here too, and theirs. A running one's are when it next parks.
    fn requestCancel(self: *RocTask, calls: *HostCalls) void {
        var task = self;
        // Down the tree, a task before its descendants, entering the groups
        // only of a task that isn't running.
        var down = task.markCancelled(calls);
        while (true) {
            var place = if (down) task.firstEntry() else null;
            while (place == null) {
                if (task == self) return;
                const group = task.group.?;
                place = group.entryFrom(task.entry_index + 1);
                task = group.owner;
            }
            task = place.?;
            down = !task.cancel_requested and task.markCancelled(calls);
        }
    }

    /// Request that the task finish. Returns whether its own code surely runs no
    /// more: in a `ParallelTasks` program, whether it was parked.
    fn markCancelled(self: *RocTask, calls: *HostCalls) bool {
        @atomicStore(bool, &self.cancel_requested, true, .monotonic);
        const parked = self.started and self.unpark(calls);
        return self.tree == null or parked;
    }

    /// Cancel the task's entries, whose code won't run again. The tree is
    /// locked; the start records it drops are released when the task finishes.
    fn cancelGroups(self: *RocTask, calls: *HostCalls) void {
        var group = self.open_groups;
        while (group) |open| : (group = open.outer) open.cancelLocked(.all, calls);
    }

    /// Ready a parked task that will run no more of its code, abandoning
    /// its hosted operation first if it waits on one. Nothing happens to a
    /// task that isn't parked, and the result is false. The tree is locked.
    fn unpark(self: *RocTask, calls: *HostCalls) bool {
        if (@cmpxchgStrong(u32, self.waitWord(), wake_parked, 0, .acq_rel, .monotonic) != null) return false;
        calls.add(self, self.waitsOnOperation());
        return true;
    }

    /// The first running entry of the task's open groups.
    fn firstEntry(self: *RocTask) ?*RocTask {
        const outermost = Group.justInside(self.open_groups, null) orelse return null;
        return outermost.entryFrom(0);
    }

    /// Claim the process's one running resume for this task, while the
    /// monitors are on (P1, P10), or in a `ParallelTasks` program the task's
    /// own (P1).
    fn claimResume(self: *RocTask) void {
        if (!monitors or self.scheduler != null) return;
        if (self.tree != null) return self.claimParallelResume();
        const holder = @cmpxchgStrong(?*RocTask, &resuming, null, self, .acquire, .monotonic) orelse return;
        if (holder == self) hostViolation(self.ops, "a task was resumed inside its own resume, from a hosted call (P1)");
        hostViolation(self.ops, "two resumes ran at the same time (P10)");
    }

    /// Give up the claim, if this task holds it.
    fn releaseResume(self: *RocTask) void {
        if (!monitors) return;
        if (self.tree == null) self.releaseSerialResume() else self.releaseParallelResume();
    }

    fn releaseSerialResume(self: *RocTask) void {
        if (!monitors) return;
        _ = @cmpxchgStrong(?*RocTask, &resuming, self, null, .release, .monotonic);
    }

    fn claimParallelResume(self: *RocTask) void {
        if (!monitors or self.tree == null) return;
        if (@atomicRmw(bool, &self.resume_claimed, .Xchg, true, .acquire)) hostViolation(self.ops, "a task was resumed while it was running (P1)");
    }

    /// Give up a parallel resume's claim. A park does so before it sets the
    /// parked bit, after which another thread may resume the task.
    fn releaseParallelResume(self: *RocTask) void {
        if (!monitors or self.tree == null) return;
        @atomicStore(bool, &self.resume_claimed, false, .release);
    }

    /// A resume of a task that runs no more of its code: cancelled, or
    /// crashing (its own crash or an entry's). The first such resume
    /// releases the hosted result if a completion was counted
    /// (`completed`), with the release the innermost record names for it,
    /// then every record, and cancels the task's children, shielded ones
    /// included. The task ends once they have all reported.
    fn finish(self: *RocTask, completed: bool) Status {
        if (!self.finishing) {
            self.lockTree();
            self.finishing = true;
            self.unlockTree();
            if (completed) {
                const innermost = self.entries[self.len - 1];
                if (innermost.slot_drop) |slot_drop| slot_drop(self.hosted_slot, innermost.record, self.ops);
            }
            while (self.len > 0) {
                self.len -= 1;
                self.releaseRecord(self.entries[self.len].record, self.entries[self.len].from_task);
            }
            self.leaveCell();
            self.pending = 0;
            var group = self.open_groups;
            while (group) |open| : (group = open.outer) open.cancelEntries(.all);
        }
        // Take each group's reports, innermost first, and close it once its
        // last child has reported; park on the first that still has one
        // running.
        while (self.open_groups) |group| {
            group.dropReports();
            self.releaseParallelResume();
            self.lockTree();
            if (group.live > 0) {
                self.wait = group;
                if (self.parkOnWait()) return .pending;
                self.claimParallelResume();
                continue;
            }
            const last_taken = group.reports_taken == group.reports_len;
            self.unlockTree();
            self.claimParallelResume();
            if (last_taken) group.close();
        }
        return self.end(if (self.crashing) .crashed else .cancelled);
    }

    /// The task, if it waits on a cell: an update it runs is then the one that
    /// waited, run again.
    fn retriedWaiter(self: *RocTask) ?*RocTask {
        return if (self.waited_cell == null) null else self;
    }

    /// Take the task off the waiters of the cell it waits on, if it waits,
    /// because it ended or its update answered without a `Wait`. If it
    /// carried a wake it did not pass on, the waiters after it are probed.
    fn leaveCell(self: *RocTask) void {
        const cell = self.waited_cell orelse return;
        var calls: HostCalls = .{};
        const waiters = cellWaiters(cell);
        if (self.tree != null) waiters.lock();
        self.leaveLocked(&calls);
        if (self.tree != null) waiters.unlock();
        calls.make();
    }

    /// `leaveCell` with the cell's waiters locked.
    fn leaveLocked(self: *RocTask, calls: *HostCalls) void {
        const cell = self.waited_cell.?;
        const carried = self.carries_wake;
        const next = cellWaiters(cell).after(cell, self);
        self.removeWaiter();
        if (carried) probeFrom(cell, next, calls);
    }

    fn removeWaiter(self: *RocTask) void {
        const waiters = cellWaiters(self.waited_cell.?);
        waiters.list.lock();
        waiters.unlink(self);
        waiters.list.unlock();
        self.waited_cell = null;
        self.older_waiter = null;
        self.newer_waiter = null;
        self.carries_wake = false;
        erased_callable.decref(self.waiting_probe, self.ops);
    }

    /// Run the waiting task's probe, in the running task's resume: whether its
    /// update would go on now, rather than answer `Wait`. A crash exit of the
    /// waiter's own, whose buffer is free while it is parked, makes a crash
    /// mean that it would, so that the update itself crashes.
    noinline fn probe(self: *RocTask) bool {
        // Kept in the task, since a crash exit restores no local.
        if (self.scheduler == null) {
            self.probe_outer = runningSlot().*;
            runningSlot().* = self;
        }
        self.probe_goes_on = true;
        self.probing = true;
        if (!crash_exit.available() or crash_exit.save(&self.crash_jmp) == 0) {
            var answer: u8 = undefined;
            var out_desc: ?*const anyopaque = null;
            erased_callable.payloadPtr(self.waiting_probe).callable_fn_ptr(
                self.ops,
                @ptrCast(&answer),
                null,
                erased_callable.capturePtr(self.waiting_probe),
                null,
                &out_desc,
            );
            self.probe_goes_on = answer != 0;
        }
        self.probing = false;
        if (self.scheduler == null) runningSlot().* = self.probe_outer;
        return self.probe_goes_on;
    }

    /// The task crashed, or one of its entries did, with `message` (design.md
    /// "Child Tasks", "Crashes"): the task runs no more of its code, and
    /// crashes with that message once its children have reported. The first
    /// crash's message is the one it keeps. The tree is locked.
    fn takeCrash(self: *RocTask, message: []const u8) void {
        if (self.crashing) return;
        const copy: [*]u8 = @ptrCast(self.ops.alloc(1, @max(message.len, 1)));
        @memcpy(copy[0..message.len], message);
        self.crash_message = copy;
        self.crash_message_len = message.len;
        @atomicStore(bool, &self.crashing, true, .monotonic);
    }

    /// The task reached its terminal `status`. A child reports to its group
    /// and is freed before its resume returns (design.md "Child Tasks").
    fn end(self: *RocTask, status: Status) Status {
        self.status = status;
        if (self.group) |group| group.report(self);
        return status;
    }

    /// `roc_task_free`, after the task is done or cancelled.
    pub fn free(self: *RocTask) void {
        checkNotFreed(self, "freed");
        if (monitors and self.status == .pending) return hostViolation(self.ops, "a task was freed before it ended (P8)");
        if (monitors and self.group != null) return hostViolation(self.ops, "the host freed a child task, which the runtime frees (P8)");
        self.release();
    }

    /// Free the task's memory.
    fn release(self: *RocTask) void {
        const ops = self.ops;
        std.debug.assert(self.waited_cell == null); // rationale: `finish` and an update without a `Wait` leave the cell, and a task ends only after one
        for (&self.record_cache) |*list| {
            while (list.*) |record| {
                list.* = recordNext(record).*;
                utils.freeDataPtrC(record, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, ops);
            }
        }
        if (self.capacity > 0) ops.dealloc(@ptrCast(self.entries), @alignOf(Entry));
        if (self.status == .crashed) ops.dealloc(@ptrCast(@constCast(self.crash_message)), 1);
        freeBuffer(ops, self.hosted_slot, self.hosted_slot_size, self.hosted_slot_alignment);
        freeBuffer(ops, self.result_buffer, self.result_buffer_size, self.result_buffer_alignment);
        // Before the address can be another thread's new task.
        noteFreed(self, ops);
        ops.dealloc(@ptrCast(self), @alignOf(RocTask));
    }

    /// The buffer sizes the program gave this task, which its children get
    /// too.
    fn bufferLayout(self: *const RocTask) BufferLayout {
        return .{
            .hosted_slot_size = self.hosted_slot_size,
            .hosted_slot_alignment = self.hosted_slot_alignment,
            .result_buffer_size = self.result_buffer_size,
            .result_buffer_alignment = self.result_buffer_alignment,
        };
    }

    fn call(self: *RocTask, record: [*]u8, ret: [*]u8) void {
        var task: *RocTask = self;
        var out_desc: ?*const anyopaque = null;
        erased_callable.payloadPtr(record).callable_fn_ptr(
            self.ops,
            ret,
            @ptrCast(&task),
            erased_callable.capturePtr(record),
            null,
            &out_desc,
        );
    }

    fn grow(self: *RocTask) void {
        const capacity = if (self.capacity == 0) 4 else self.capacity * 2;
        const bytes = capacity * @sizeOf(Entry);
        const raw = if (self.capacity == 0)
            self.ops.alloc(@alignOf(Entry), bytes)
        else
            self.ops.realloc(@ptrCast(self.entries), bytes, @alignOf(Entry));
        self.entries = @ptrCast(@alignCast(raw));
        self.capacity = capacity;
    }
};

/// A lock a short piece of the runtime's own code holds.
const SpinLock = struct {
    word: u32 = 0,

    fn lock(self: *SpinLock) void {
        while (@cmpxchgWeak(u32, &self.word, 0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        @atomicStore(u32, &self.word, 0, .release);
    }
};

/// The tasks waiting on the cells that share one entry of `cell_waiters`,
/// oldest first.
const CellWaiters = struct {
    /// The lock of the cells in a `ParallelTasks` program, 0 free and 1 held:
    /// an update holds it from taking its cell's state until it settled or
    /// waits, so it covers the cells' payloads and this list.
    locked: u32 = 0,
    /// The lock of the list's links, which cells of a `None` program's runs on
    /// several threads share.
    list: SpinLock = .{},
    oldest: ?*RocTask = null,
    newest: ?*RocTask = null,

    /// The oldest waiter of `cell` that is newer than `last`, or its oldest. A
    /// waiter of `cell` stays in the list while the caller may use the cell.
    fn after(self: *CellWaiters, cell: *anyopaque, last: ?*RocTask) ?*RocTask {
        self.list.lock();
        defer self.list.unlock();
        var next = if (last) |task| task.newer_waiter else self.oldest;
        while (next) |waiter| : (next = waiter.newer_waiter) {
            if (waiter.waited_cell.? == cell) return waiter;
        }
        return null;
    }

    /// Whether no task waits on a cell that shares the entry.
    fn empty(self: *const CellWaiters) bool {
        return @atomicLoad(?*RocTask, &self.oldest, .monotonic) == null;
    }

    /// Put `task` last. The list is locked.
    fn link(self: *CellWaiters, task: *RocTask) void {
        task.older_waiter = self.newest;
        task.newer_waiter = null;
        if (self.newest) |newest| newest.newer_waiter = task else @atomicStore(?*RocTask, &self.oldest, task, .monotonic);
        self.newest = task;
    }

    /// Take `task` off. The list is locked.
    fn unlink(self: *CellWaiters, task: *RocTask) void {
        if (task.older_waiter) |older| older.newer_waiter = task.newer_waiter else @atomicStore(?*RocTask, &self.oldest, task.newer_waiter, .monotonic);
        if (task.newer_waiter) |newer| newer.older_waiter = task.older_waiter else self.newest = task.older_waiter;
    }

    fn lock(self: *CellWaiters) void {
        while (@cmpxchgWeak(u32, &self.locked, 0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *CellWaiters) void {
        @atomicStore(u32, &self.locked, 0, .release);
    }

    /// Release the lock the running update took, if its program takes one.
    fn unlockUpdate(self: *CellWaiters, running: ?*RocTask) void {
        if (running) |task| task.locked_cells = null;
        // A `ParallelTasks` update holds it, so nothing else changes it here.
        if (@atomicLoad(u32, &self.locked, .monotonic) != 0) self.unlock();
    }
};

/// Every waiting task, by the address of the cell it waits on. Cells that
/// share an entry are told apart by address, so a cell needs no room for its
/// waiters. A cell outlives its waiters, whose probes hold it.
var cell_waiters: [256]CellWaiters = @splat(.{});

fn cellWaiters(cell: *anyopaque) *CellWaiters {
    const address = @intFromPtr(cell) >> 4;
    return &cell_waiters[@as(u8, @truncate(address ^ (address >> 8) ^ (address >> 16)))];
}

/// `cell_lock`, in a `ParallelTasks` program: an update of `cell` is about to
/// take its state. Cells that share the lock exclude each other too, which
/// can't deadlock: an update's function can't use another cell.
pub fn cellLock(cell: *anyopaque) void {
    const waiters = cellWaiters(cell);
    waiters.lock();
    if (runningSlot().*) |task| task.locked_cells = waiters;
}

/// `cell_wait`: the running `task`'s update of `cell` answered `Wait`, so the
/// task pauses until a wake. It takes `probe`, a boxed erased callable. A task
/// whose retried update waits again keeps its place, and passes on the wake
/// it carried.
///
/// The lock is held from before the update took the state until the task runs
/// no more code, so no store comes between that the task would miss.
pub fn cellWait(task: *RocTask, cell: *anyopaque, probe: [*]u8) void {
    if (task.waited_cell) |waited| {
        std.debug.assert(waited == cell); // rationale: a readied waiter's code goes on with the update that waited
        if (!task.carries_wake) utils.builtinInvariant(task.ops, "a task waiting on shared state ran again without a wake");
        erased_callable.decref(task.waiting_probe, task.ops);
        task.waiting_probe = probe;
        task.carries_wake = false;
        probeFrom(cell, cellWaiters(cell).after(cell, task), &task.passed_wake);
    } else {
        const waiters = cellWaiters(cell);
        task.waited_cell = cell;
        task.waiting_probe = probe;
        waiters.list.lock();
        waiters.link(task);
        waiters.list.unlock();
    }
    task.lockTree();
    task.waits_on_cell = true;
    task.unlockTree();
}

/// `cell_settle`: an update of `cell` by the running code answered without a
/// `Wait`, and `stored` a new state or put back the one it was given.
pub fn cellSettle(cell: *anyopaque, stored: bool) void {
    const waiters = cellWaiters(cell);
    const running = runningSlot().*;
    var calls: HostCalls = .{};
    if (!waiters.empty()) {
        const retried = if (running) |task| task.retriedWaiter() else Scheduler.retriedWaiter(cell);
        if (retried) |task| {
            std.debug.assert(task.waited_cell.? == cell); // rationale: a readied waiter's code goes on with the update that waited
            if (stored) task.removeWaiter() else task.leaveLocked(&calls);
        }
        if (stored) probeFrom(cell, waiters.after(cell, null), &calls);
    }
    waiters.unlockUpdate(running);
    calls.make();
}

/// Probe the waiters of `cell` from `first` on and wake the first that would
/// not wait, stopping at one that already carries a wake: whichever of them
/// ends without a store probes on from its successor, so no wake is lost. A
/// poisoned cell's waiters all go on, each when the one before it crashed.
/// The cell's waiters are locked.
fn probeFrom(cell: *anyopaque, first: ?*RocTask, calls: *HostCalls) void {
    var next = first;
    while (next) |waiter| : (next = cellWaiters(cell).after(cell, waiter)) {
        if (waiter.carries_wake) return;
        // A task that runs no more of its code leaves the cell when it ends.
        if (@atomicLoad(bool, &waiter.cancel_requested, .monotonic) or @atomicLoad(bool, &waiter.crashing, .monotonic)) continue;
        if (!waiter.probe()) continue;
        waiter.carries_wake = true;
        const seen = @atomicRmw(u32, &waiter.cell_word, .Xchg, 1, .acq_rel);
        if (seen & wake_parked != 0) calls.add(waiter, false);
        return;
    }
}

/// Probe the oldest waiter of every cell, which finds each poisoned one.
fn probeEveryCell(parallel: bool) void {
    for (&cell_waiters) |*waiters| {
        var calls: HostCalls = .{};
        if (parallel) waiters.lock();
        var next = waiters.oldest;
        while (next) |waiter| : (next = waiter.newer_waiter) {
            if (oldestOf(waiters, waiter.waited_cell.?) == waiter) probeFrom(waiter.waited_cell.?, waiter, &calls);
        }
        if (parallel) waiters.unlock();
        calls.make();
    }
}

/// Whether any task waits on a cell, when no thread runs a task. For tests.
pub fn anyWaiter() bool {
    for (&cell_waiters) |*waiters| if (!waiters.empty()) return true;
    return false;
}

fn oldestOf(waiters: *const CellWaiters, cell: *anyopaque) ?*RocTask {
    var next = waiters.oldest;
    while (next) |waiter| : (next = waiter.newer_waiter) {
        if (waiter.waited_cell.? == cell) return waiter;
    }
    return null;
}

/// Calls of the host's `roc_task_ready`, and `roc_task_abort` before it for
/// a task whose operation is abandoned, that are due once the tree is
/// unlocked, in order. Each task in the list is new or was unparked by what
/// added it, so until its ready nothing else resumes, readies or frees it.
const HostCalls = extern struct {
    first: ?*RocTask = null,
    last: ?*RocTask = null,

    fn add(self: *HostCalls, task: *RocTask, abort: bool) void {
        task.host_abort = abort;
        task.host_next = null;
        if (self.last) |last| last.host_next = task else self.first = task;
        self.last = task;
    }

    /// Make the calls. The tree is unlocked: the host's functions may take
    /// locks of its own.
    fn make(self: *const HostCalls) void {
        var next = self.first;
        while (next) |task| {
            // Once it is readied, another thread may resume the task.
            next = task.host_next;
            if (task.scheduler) |scheduler| {
                std.debug.assert(!task.host_abort); // rationale: a `None` program's hosted calls never pause
                scheduler.ready(task);
                continue;
            }
            if (task.host_abort) {
                callHost(task.abort_fn.?, task);
                if (monitors) @atomicStore(bool, &task.aborted, true, .monotonic);
            }
            callHost(task.ready_fn.?, task);
        }
    }
};

/// Call one of the host's task functions from inside a resume, with no
/// running task, so a crash in the host reaches its `roc_crashed` rather
/// than the task's crash exit, as a hosted call does (`hostEnter`).
fn callHost(f: *const fn (*RocTask) callconv(.c) void, task: *RocTask) void {
    const was_running = hostEnter();
    f(task);
    hostLeave(was_running);
}

/// Releases a result left in an entry's slot that no `groupNext` hands out:
/// a background entry's after the loop ended, or any entry's after its
/// owner was cancelled or crashed. `context` is the group's
/// (`GroupSpec.result_drop_context`).
pub const ResultDropFn = *const fn (slot: [*]u8, context: ?*anyopaque, ops: *RocOps) callconv(.c) void;

/// Releases a `ResultDropFn`'s context, once, when its group closes: the
/// interpreter's context keeps the interpreter alive until then.
pub const ResultDropReleaseFn = *const fn (context: ?*anyopaque, ops: *RocOps) callconv(.c) void;

/// One entry's marks from a flattened plan (design.md "Plans And Concurrent
/// Loops").
pub const EntryMarks = struct {
    /// Indexes into `GroupSpec.limits` of the limits the entry is under,
    /// outermost first.
    limit_path: []const u32,
    shielded: bool,
    background: bool,
};

/// What a task-form loop's `group` operation hands the runtime.
pub const GroupSpec = struct {
    /// The compiled loop's id (`openGroup`).
    loop_id: u64 = 0,
    /// Each entry's start record, in input order. The group takes them.
    starts: []const [*]u8,
    /// Parallel to `starts`.
    marks: []const EntryMarks,
    /// How many running entries each limit allows; none allows zero.
    limits: []const u64,
    /// The limit a spawned entry goes under: the plan's outermost node when
    /// that node is a `Limit`.
    root_limit: ?u32,
    /// The size and alignment of one entry's result.
    slot_size: usize,
    slot_alignment: usize,
    /// Releases a result nobody takes; null when the result holds nothing
    /// to release.
    result_drop: ?ResultDropFn,
    result_drop_context: ?*anyopaque,
    /// Releases `result_drop_context` when the group closes; null when it
    /// needs no release.
    result_drop_release: ?ResultDropReleaseFn = null,
    /// Whether an entry's crash is a report for `groupNext` instead of its
    /// owner's crash (`Group.supervised`).
    supervised: bool = false,
};

/// What `groupNext` found.
pub const Next = union(enum) {
    /// The entry at `index` finished; its result is in `slot`, and the
    /// caller moves it out.
    arrived: struct { index: u32, slot: [*]u8 },
    /// The entry of a supervised group crashed; `message` is its crash's,
    /// and the caller moves it out.
    crashed: struct { message: *str.RocStr },
    /// Every entry has finished, been cancelled or been dropped.
    ended,
    /// Nothing has arrived: the owner suspends here, parked on the group's
    /// wake word, and calls `groupNext` again from its resume entry.
    pending,
};

/// The running set of a task-form concurrent loop: its entries, each run
/// as a child task of the loop's task, the owner (design.md "Plans And
/// Concurrent Loops", "Child Tasks").
///
/// Everything but `word` is touched only inside resumes and the host's
/// `roc_task_cancel`, which a `Tasks` host never overlaps (P10), and in a
/// `ParallelTasks` program only with the tree locked (design.md "Parallel
/// Resumes"), except for what only the owner's code touches: pushing entries
/// before `groupStart`, a taken entry's slot, dropped entries' start records
/// and closing the group.
pub const Group = struct {
    owner: *RocTask,
    /// The compiled loop's id, which each of its operations names
    /// (`openGroup`).
    loop_id: u64,
    /// The slot of the entry `groupNext` last reported arrived, for a
    /// compiled loop to move its result out of.
    arrival: [*]u8,
    /// The wake word of the owner's wait on this group: `wake_parked` while
    /// the owner is parked on it, and the count of reports queued that
    /// `groupNext` has not taken.
    word: u32,
    /// The group the owner opened before this one, still open.
    outer: ?*Group,
    entries: [*]GroupEntry,
    len: u32,
    capacity: u32,
    /// The entries' limit paths, back to back (`GroupEntry.path_start`).
    paths: [*]u32,
    paths_len: u32,
    paths_capacity: u32,
    limits: [*]Limit,
    limit_count: u32,
    root_limit: ?u32,
    /// The slots of the `block_slots` entries `groupCreate` made, in one
    /// block; a spawned entry's slot is its own allocation.
    block: [*]u8,
    block_slots: usize,
    slot_size: usize,
    slot_alignment: usize,
    result_drop: ?ResultDropFn,
    result_drop_context: ?*anyopaque,
    result_drop_release: ?ResultDropReleaseFn,
    /// Indexes of reported entries in report order; `reports[taken..len]`
    /// are queued. Each entry reports once, so `capacity` entries fit.
    reports: [*]u32,
    reports_len: u32,
    reports_taken: u32,
    /// The first entry that may not have started yet.
    first_unstarted: u32,
    /// Entries whose child is running.
    live: u32,
    /// Entries that haven't started and weren't dropped.
    unstarted: u32,
    /// Entries that aren't background and are unstarted or running: the
    /// ones that keep the loop going.
    foreground_left: u32,
    /// The running entries that have not begun and that the scheduler has not
    /// taken, in a `None` program (`Scheduler`).
    unbegun: TaskHeap,
    /// Whether only background entries were left and `groupNext` cancelled
    /// them: what arrives after is dropped, and the loop ends.
    ending: bool,
    /// Whether this is `supervise!`'s set: its one entry's crash is a report
    /// `groupNext` takes, and not a crash of its owner (design.md "Plans And
    /// Concurrent Loops", "Supervision.").
    supervised: bool,
    /// The message of a supervised entry's crash, from its report until
    /// `groupNext` takes it or the owner's finish drops it.
    crash_message: str.RocStr,

    const Limit = struct { allowed: u64, running: u64 };

    const State = enum(u8) { unstarted, running, reported, taken, dropped };

    const GroupEntry = struct {
        /// The start record, until the entry starts or its record is
        /// dropped.
        start: ?[*]u8,
        /// The running child.
        child: ?*RocTask,
        slot: [*]u8,
        path_start: u32,
        path_len: u32,
        tree_index: u32,
        shielded: bool,
        background: bool,
        /// Whether `slot` is the entry's own allocation (a spawned entry).
        own_slot: bool,
        state: State,
        /// How the child ended, once it reported.
        outcome: Status,
    };

    /// Which running entries a cancel reaches: a loop exit spares the
    /// shielded ones that have begun; a cancelled or crashing owner
    /// cancels all of them.
    const Reach = enum { exit, all };

    fn path(self: *const Group, entry: *const GroupEntry) []const u32 {
        return self.paths[entry.path_start..][0..entry.path_len];
    }

    fn hasRoom(self: *const Group, entry: *const GroupEntry) bool {
        for (self.path(entry)) |limit| {
            if (self.limits[limit].running >= self.limits[limit].allowed) return false;
        }
        return true;
    }

    /// Start every unstarted entry whose limits have room, in input order.
    fn startEligible(self: *Group, calls: *HostCalls) void {
        var index = self.first_unstarted;
        var first: ?u32 = null;
        while (index < self.len) : (index += 1) {
            const entry = &self.entries[index];
            if (entry.state != .unstarted) continue;
            if (self.hasRoom(entry)) {
                self.start(index, calls);
            } else if (first == null) {
                first = index;
            }
        }
        self.first_unstarted = first orelse self.len;
    }

    /// `startEligible` for the owner's code, which in a `ParallelTasks`
    /// program may run while an entry of another of its groups crashes.
    fn startUnlessCrashing(self: *Group, calls: *HostCalls) void {
        if (!self.owner.crashing) self.startEligible(calls);
    }

    /// Start the entry at `index` as a child task: it writes its result to
    /// its slot, and the host learns it is ready through the owner's
    /// `roc_task_ready`. The tree is locked.
    fn start(self: *Group, index: u32, calls: *HostCalls) void {
        const owner = self.owner;
        if (owner.ready_fn == null and owner.scheduler == null) utils.builtinInvariant(owner.ops, "a task started children without the host's roc_task_ready; its resume came from no host");
        const entry = &self.entries[index];
        for (self.path(entry)) |limit| {
            self.limits[limit].running += 1;
            if (monitors and self.limits[limit].running > self.limits[limit].allowed) utils.builtinInvariant(owner.ops, "a limit has more running entries than it allows");
        }
        const child = RocTask.create(owner.ops, entry.start.?, entry.slot, owner.bufferLayout());
        entry.start = null;
        child.tree = owner.tree;
        child.ready_fn = owner.ready_fn;
        child.abort_fn = owner.abort_fn;
        child.scheduler = owner.scheduler;
        child.group = self;
        child.entry_index = index;
        child.tree_index = entry.tree_index;
        entry.child = child;
        entry.state = .running;
        self.unstarted -= 1;
        self.live += 1;
        calls.add(child, false);
    }

    /// Append an entry under the limits `limit_path`; it starts when they
    /// have room and nothing before it is waiting for them.
    /// Add an entry. `limit_path` holds limit indexes, as `u32` from Zig
    /// callers or `u64` from a compiled program's `List(U64)`.
    fn append(self: *Group, start_record: [*]u8, slot: [*]u8, own_slot: bool, limit_path: anytype, shielded: bool, background: bool) void {
        const ops = self.owner.ops;
        if (self.len == self.capacity) {
            const capacity = @max(4, self.capacity * 2);
            self.entries = @ptrCast(@alignCast(growArray(ops, @ptrCast(self.entries), self.capacity, capacity, @sizeOf(GroupEntry), @alignOf(GroupEntry))));
            self.reports = @ptrCast(@alignCast(growArray(ops, @ptrCast(self.reports), self.capacity, capacity, @sizeOf(u32), @alignOf(u32))));
            self.capacity = capacity;
        }
        if (self.paths_len + limit_path.len > self.paths_capacity) {
            const capacity: u32 = @intCast(@max(8, self.paths_capacity * 2, self.paths_len + limit_path.len));
            self.paths = @ptrCast(@alignCast(growArray(ops, @ptrCast(self.paths), self.paths_capacity, capacity, @sizeOf(u32), @alignOf(u32))));
            self.paths_capacity = capacity;
        }
        for (limit_path, self.paths[self.paths_len..][0..limit_path.len]) |limit, *copy| {
            if (limit >= self.limit_count) utils.builtinInvariant(ops, "an entry's limit path names a limit the plan doesn't have");
            copy.* = @intCast(limit);
        }
        self.entries[self.len] = .{
            .start = start_record,
            .child = null,
            .slot = slot,
            .path_start = self.paths_len,
            .path_len = @intCast(limit_path.len),
            .tree_index = self.owner.child_counter,
            .shielded = shielded,
            .background = background,
            .own_slot = own_slot,
            .state = .unstarted,
            .outcome = .pending,
        };
        self.owner.child_counter += 1;
        self.paths_len += @intCast(limit_path.len);
        self.len += 1;
        self.unstarted += 1;
        if (!background) self.foreground_left += 1;
    }

    /// A child finished, from inside its own resume: record its report,
    /// free it, start what its limits now have room for, and queue the
    /// report for the owner, readying the owner if it is parked on this
    /// group. A crash also makes the owner crash wherever it waits
    /// (design.md "Child Tasks", "Crashes").
    fn report(self: *Group, child: *RocTask) void {
        var calls: HostCalls = .{};
        child.lockTree();
        const owner = self.owner;
        const index = child.entry_index;
        const entry = &self.entries[index];
        entry.state = .reported;
        entry.outcome = child.status;
        entry.child = null;
        self.live -= 1;
        if (!entry.background) self.foreground_left -= 1;
        for (self.path(entry)) |limit| self.limits[limit].running -= 1;
        const was_crashing = owner.crashing;
        if (child.status == .crashed) {
            const message = child.crash_message[0..child.crash_message_len];
            if (self.supervised) {
                self.crash_message = str.RocStr.fromSlice(message, owner.ops);
            } else {
                owner.takeCrash(message);
            }
        }
        self.reports[self.reports_len] = index;
        self.reports_len += 1;
        if (!owner.finishing and !owner.crashing and !owner.cancel_requested) self.startEligible(&calls);
        // Count the report and clear the parked bit in one step, so
        // exactly one report readies a parked owner.
        var seen = @atomicLoad(u32, &self.word, .monotonic);
        while (@cmpxchgWeak(u32, &self.word, seen, (seen & ~wake_parked) + 1, .release, .monotonic)) |actual| seen = actual;
        var parked = seen & wake_parked != 0;
        if (parked) {
            calls.add(owner, false);
        } else if (owner.crashing) {
            // Parked elsewhere, on its hosted operation or on another of
            // its groups, or running.
            parked = owner.unpark(&calls);
        }
        // Its code won't run again, so its entries are cancelled here too.
        const ends_here = if (owner.tree == null) !was_crashing else parked;
        if (owner.crashing and !owner.finishing and ends_here) owner.cancelGroups(&calls);
        // Once the tree is unlocked, the owner may take this report, close
        // the group and end.
        child.unlockTree();
        child.release();
        calls.make();
    }

    /// Take the next queued report, counting it off the wake word. The tree
    /// is locked.
    fn takeReport(self: *Group) ?u32 {
        if (self.reports_taken == self.reports_len) return null;
        const index = self.reports[self.reports_taken];
        self.reports_taken += 1;
        _ = @atomicRmw(u32, &self.word, .Sub, 1, .acquire);
        self.entries[index].state = .taken;
        return index;
    }

    /// Take every queued report and release the results in them.
    fn dropReports(self: *Group) void {
        const owner = self.owner;
        while (true) {
            owner.lockTree();
            const taken = self.takeReport();
            owner.unlockTree();
            self.dropResult(taken orelse return);
        }
    }

    /// Release the result of a taken entry, if it finished with one.
    fn dropResult(self: *Group, index: u32) void {
        const entry = &self.entries[index];
        if (entry.outcome == .crashed and self.supervised) self.crash_message.decref(self.owner.ops);
        if (entry.outcome != .done) return;
        if (self.result_drop) |drop| drop(entry.slot, self.result_drop_context, self.owner.ops);
    }

    /// Drop the entries that haven't started, and cancel the running ones
    /// `reach` covers.
    fn cancelEntries(self: *Group, reach: Reach) void {
        var calls: HostCalls = .{};
        self.owner.lockTree();
        self.cancelLocked(reach, &calls);
        self.owner.unlockTree();
        self.afterCancel(&calls);
    }

    /// `cancelEntries`' half under the lock: its other half is `afterCancel`.
    fn cancelLocked(self: *Group, reach: Reach, calls: *HostCalls) void {
        for (self.entries[0..self.len]) |*entry| {
            switch (entry.state) {
                .unstarted => {
                    entry.state = .dropped;
                    self.unstarted -= 1;
                    if (!entry.background) self.foreground_left -= 1;
                },
                .running => {
                    const child = entry.child.?;
                    if (reach == .exit and entry.shielded and child.started) continue;
                    if (!child.cancel_requested) child.requestCancel(calls);
                },
                .reported, .taken, .dropped => {},
            }
        }
        self.first_unstarted = self.len;
        // Every entry that has not begun was cancelled, so it may end now.
        if (self.owner.scheduler) |scheduler| scheduler.readied.takeAll(&self.unbegun);
    }

    /// The group of the list that starts at `innermost` just inside of
    /// `outer`, or its outermost.
    fn justInside(innermost: ?*Group, outer: ?*Group) ?*Group {
        var group = innermost;
        while (group) |open| : (group = open.outer) {
            if (open.outer == outer) return open;
        }
        return null;
    }

    /// The first running entry from `index` on, or of the groups inside this
    /// one that its owner opened after it.
    fn entryFrom(self: *Group, index: usize) ?*RocTask {
        var group = self;
        var from = index;
        while (true) {
            for (group.entries[from..group.len]) |*entry| {
                if (entry.child) |child| return child;
            }
            group = justInside(group.owner.open_groups, group) orelse return null;
            from = 0;
        }
    }

    /// Ready the tasks a cancel reached and release the start records it
    /// dropped, the only ones left, which runs the program's drops, so with
    /// the tree unlocked.
    fn afterCancel(self: *Group, calls: *const HostCalls) void {
        calls.make();
        for (self.entries[0..self.len]) |*entry| {
            const dropped = entry.start orelse continue;
            entry.start = null;
            erased_callable.decref(dropped, self.owner.ops);
        }
    }

    /// Free the group once nothing in it runs or waits, and take it off its
    /// owner's open groups. It must be the innermost.
    fn close(self: *Group) void {
        const owner = self.owner;
        const ops = owner.ops;
        if (owner.open_groups != self) utils.builtinInvariant(ops, "a concurrent loop was closed while a loop inside it was open");
        if (self.live != 0 or self.unstarted != 0 or self.reports_taken != self.reports_len) utils.builtinInvariant(ops, "a concurrent loop was closed with entries running or reports queued");
        owner.open_groups = self.outer;
        for (self.entries[0..self.len]) |*entry| {
            if (entry.own_slot) freeBuffer(ops, entry.slot, self.slot_size, self.slot_alignment);
        }
        if (self.capacity > 0) {
            ops.dealloc(@ptrCast(self.entries), @alignOf(GroupEntry));
            ops.dealloc(@ptrCast(self.reports), @alignOf(u32));
        }
        if (self.paths_capacity > 0) ops.dealloc(@ptrCast(self.paths), @alignOf(u32));
        if (self.limit_count > 0) ops.dealloc(@ptrCast(self.limits), @alignOf(Limit));
        freeBuffer(ops, self.block, self.slot_size * self.block_slots, self.slot_alignment);
        const release = self.result_drop_release;
        const context = self.result_drop_context;
        ops.dealloc(@ptrCast(self), @alignOf(Group));
        if (release) |release_context| release_context(context, ops);
    }
};

/// Grow an array of `old` items of `size` bytes to `new` items.
fn growArray(ops: *RocOps, items: *anyopaque, old: u32, new: u32, size: usize, alignment: usize) *anyopaque {
    if (old == 0) return ops.alloc(alignment, new * size);
    return ops.realloc(items, new * size, alignment);
}

/// `group`: open a running set for the task's code, the owner, and start
/// every entry whose limits have room (design.md "Plans And Concurrent
/// Loops", task form). Each entry's place in the task tree is fixed here,
/// in input order. Called from the owner's code during its resume.
pub fn groupCreate(owner: *RocTask, spec: GroupSpec) *Group {
    if (spec.marks.len != spec.starts.len) utils.builtinInvariant(owner.ops, "a group's marks don't match its entries");
    const group = groupInit(owner, spec.loop_id, spec.starts.len, spec.limits, spec.root_limit, spec.slot_size, spec.slot_alignment, spec.result_drop, spec.result_drop_context, spec.result_drop_release, spec.supervised);
    for (spec.starts, spec.marks) |start_record, marks| groupPush(group, start_record, marks.limit_path, marks.shielded, marks.background);
    groupStart(group);
    return group;
}

/// The first of `group`'s three steps, for a compiled program that adds
/// its entries one at a time: a group for `entry_count` entries, with no
/// entry yet. `groupPush` adds each, in input order, and `groupStart`
/// starts every entry its limits allow.
pub fn groupInit(
    owner: *RocTask,
    loop_id: u64,
    entry_count: usize,
    limits: []const u64,
    root_limit: ?u32,
    slot_size: usize,
    slot_alignment: usize,
    result_drop: ?ResultDropFn,
    result_drop_context: ?*anyopaque,
    result_drop_release: ?ResultDropReleaseFn,
    supervised: bool,
) *Group {
    const ops = owner.ops;
    if (supervised and entry_count != 1) utils.builtinInvariant(ops, "a supervised group was made for more or fewer entries than one");
    const group: *Group = @ptrCast(@alignCast(ops.alloc(@alignOf(Group), @sizeOf(Group))));
    const stride = std.mem.alignForward(usize, slot_size, slot_alignment);
    group.* = .{
        .owner = owner,
        .loop_id = loop_id,
        .arrival = undefined,
        .word = 0,
        .outer = owner.open_groups,
        .entries = undefined,
        .len = 0,
        .capacity = 0,
        .paths = undefined,
        .paths_len = 0,
        .paths_capacity = 0,
        .limits = undefined,
        .limit_count = @intCast(limits.len),
        .root_limit = root_limit,
        .block = allocBuffer(ops, stride * entry_count, slot_alignment),
        .block_slots = entry_count,
        .slot_size = stride,
        .slot_alignment = slot_alignment,
        .result_drop = result_drop,
        .result_drop_context = result_drop_context,
        .result_drop_release = result_drop_release,
        .reports = undefined,
        .reports_len = 0,
        .reports_taken = 0,
        .first_unstarted = 0,
        .live = 0,
        .unstarted = 0,
        .foreground_left = 0,
        .unbegun = .{},
        .ending = false,
        .supervised = supervised,
        .crash_message = undefined,
    };
    if (limits.len > 0) {
        group.limits = @ptrCast(@alignCast(ops.alloc(@alignOf(Group.Limit), limits.len * @sizeOf(Group.Limit))));
        for (limits, group.limits[0..limits.len]) |allowed, *limit| {
            if (allowed == 0) utils.builtinInvariant(ops, "a limit allows no running entries");
            limit.* = .{ .allowed = allowed, .running = 0 };
        }
    }
    if (root_limit) |root| if (root >= limits.len) utils.builtinInvariant(ops, "a group's root limit names a limit the plan doesn't have");
    owner.open_groups = group;
    return group;
}

/// The running set a compiled loop's operation names: the owner's innermost
/// open group. Loops nest lexically within a task's code, and a loop closes
/// before the code around it goes on, so the loop whose operation runs is
/// always the innermost one open; a recursive call that opens the same loop
/// again opens a new innermost group. In a runtime with monitors, the
/// group's loop id must be `loop_id`.
pub fn openGroup(owner: *RocTask, loop_id: u64) *Group {
    const group = owner.open_groups orelse utils.builtinInvariant(owner.ops, "a concurrent loop's operation ran with no loop open");
    if (monitors and group.loop_id != loop_id) utils.builtinInvariant(owner.ops, "a concurrent loop's operation named a loop other than the innermost open one");
    return group;
}

/// The slot of the entry whose arrival `groupNext` last reported, or the
/// message of the crash it last reported.
pub fn groupArrival(group: *const Group) [*]u8 {
    return group.arrival;
}

/// Add the next entry to a group `groupInit` made: the group takes
/// `start_record`, and the entry's result goes to its slot in the group's
/// block.
pub fn groupPush(group: *Group, start_record: [*]u8, limit_path: anytype, shielded: bool, background: bool) void {
    if (group.len >= group.block_slots) utils.builtinInvariant(group.owner.ops, "a group got more entries than it was made for");
    group.append(start_record, group.block + group.len * group.slot_size, false, limit_path, shielded, background);
}

/// Start every entry its limits allow, once `groupPush` has added them all.
pub fn groupStart(group: *Group) void {
    if (group.len != group.block_slots) utils.builtinInvariant(group.owner.ops, "a group started before all its entries were added");
    var calls: HostCalls = .{};
    group.owner.lockTree();
    group.startUnlessCrashing(&calls);
    group.owner.unlockTree();
    calls.make();
}

/// `next`: take one report (design.md "Plans And Concurrent Loops"). A
/// result is in its slot for the caller to move out; a cancelled entry's
/// report is skipped. With nothing queued and only background entries left,
/// cancel them as an exit would and drop what they report. With nothing
/// queued and entries still to come, the owner parks on the group.
pub fn groupNext(group: *Group) Next {
    const owner = group.owner;
    owner.lockTree();
    while (true) {
        // An entry crashed on another thread, so the owner takes no result
        // after it: it suspends here, and finishes instead of parking.
        if (owner.crashing) {
            owner.wait = group;
            owner.unlockTree();
            return .pending;
        }
        const index = group.takeReport() orelse break;
        const entry = &group.entries[index];
        switch (entry.outcome) {
            .done => {
                const arrived = !group.ending;
                owner.unlockTree();
                if (arrived) {
                    group.arrival = entry.slot;
                    return .{ .arrived = .{ .index = index, .slot = entry.slot } };
                }
                group.dropResult(index);
                owner.lockTree();
            },
            .cancelled => {},
            .crashed => {
                // The owner of any other group crashes before it runs code
                // again, so its code never sees a crash report.
                if (!group.supervised) utils.builtinInvariant(owner.ops, "a loop's next took a crash report");
                owner.unlockTree();
                group.arrival = @ptrCast(&group.crash_message);
                return .{ .crashed = .{ .message = &group.crash_message } };
            },
            .pending => utils.builtinInvariant(owner.ops, "a loop's next took a report from a running entry"),
        }
    }
    var calls: HostCalls = .{};
    const cancelling = group.foreground_left == 0 and !group.ending and (group.live > 0 or group.unstarted > 0);
    if (cancelling) {
        group.ending = true;
        group.cancelLocked(.exit, &calls);
    }
    const ended = group.live == 0 and group.unstarted == 0;
    if (!ended) owner.wait = group;
    owner.unlockTree();
    if (cancelling) group.afterCancel(&calls);
    return if (ended) .ended else .pending;
}

/// `spawn_in`: add an entry under the root limit, if the plan has one, and
/// start it when that limit has room. It is never background or shielded.
pub fn spawnIn(group: *Group, start_record: [*]u8) void {
    const owner = group.owner;
    const root_path: []const u32 = if (group.root_limit) |*root| root[0..1] else &.{};
    const slot = allocBuffer(owner.ops, group.slot_size, group.slot_alignment);
    var calls: HostCalls = .{};
    owner.lockTree();
    group.append(start_record, slot, true, root_path, false, false);
    group.startUnlessCrashing(&calls);
    owner.unlockTree();
    calls.make();
}

/// `cancel_group`, a loop exit: drop the entries that haven't started, and
/// cancel the running ones unless they are shielded and have begun. The
/// exit then calls `groupNext` until it reports `ended`.
pub fn cancelGroup(group: *Group) void {
    group.cancelEntries(.exit);
}

/// Free a group after `groupNext` reported `ended`.
pub fn groupFree(group: *Group) void {
    group.close();
}

/// Whether `task` may be resumed next under the coroutine schedule, as far as
/// beginning it goes. A task that has begun, or that a cancel asked to
/// end, always may. An entry that has not begun may only while its owner is
/// parked on the group that holds it, waiting at its loop's next; otherwise
/// another task must run first, if one can. For `Scheduler` and a test host
/// (design.md "Sequential equivalence"); not part of the host ABI.
pub fn coroutineMayBegin(task: *const RocTask) bool {
    if (task.started or task.cancel_requested) return true;
    const group = task.group orelse return true;
    return group.owner.wait == group;
}

/// Where `a` comes in the task tree against `b`, which shares its root: an
/// ancestor before its descendants, and siblings in the order their entries
/// were made. For `Scheduler`, and a test host that resumes the ready task
/// first in the tree (design.md "Sequential equivalence"); not part of the host
/// ABI.
pub fn treeOrder(a: *const RocTask, b: *const RocTask) std.math.Order {
    var x = a;
    var y = b;
    var depth_x = treeDepth(x);
    var depth_y = treeDepth(y);
    while (depth_x > depth_y) : (depth_x -= 1) {
        if (parentOf(x) == y) return .gt;
        x = parentOf(x);
    }
    while (depth_y > depth_x) : (depth_y -= 1) {
        if (parentOf(y) == x) return .lt;
        y = parentOf(y);
    }
    if (x == y) return .eq;
    while (parentOf(x) != parentOf(y)) {
        x = parentOf(x);
        y = parentOf(y);
    }
    return std.math.order(x.tree_index, y.tree_index);
}

fn parentOf(task: *const RocTask) *const RocTask {
    return task.group.?.owner;
}

fn treeDepth(task: *const RocTask) u32 {
    var depth: u32 = 0;
    var current = task;
    while (current.group) |group| : (current = group.owner) depth += 1;
    return depth;
}

/// Tasks of one run, linked through them, so that the one first in the task
/// tree is the cheapest to find: a pairing heap. A task is in at most one.
const TaskHeap = struct {
    first: ?*RocTask = null,

    fn add(self: *TaskHeap, task: *RocTask) void {
        std.debug.assert(task.heap_child == null and task.heap_sibling == null); // rationale: `takeFirst` clears both
        self.first = merge(self.first, task);
    }

    /// Move every task of `other` here.
    fn takeAll(self: *TaskHeap, other: *TaskHeap) void {
        self.first = merge(self.first, other.first);
        other.first = null;
    }

    fn takeFirst(self: *TaskHeap) ?*RocTask {
        const taken = self.first orelse return null;
        // Merge the children in pairs, then each pair into the rest.
        var pairs: ?*RocTask = null;
        var next = taken.heap_child;
        while (next) |left| {
            const right = left.heap_sibling;
            left.heap_sibling = null;
            next = if (right) |one| one.heap_sibling else null;
            if (right) |one| one.heap_sibling = null;
            const pair = merge(left, right).?;
            pair.heap_sibling = pairs;
            pairs = pair;
        }
        var rest: ?*RocTask = null;
        while (pairs) |pair| {
            pairs = pair.heap_sibling;
            pair.heap_sibling = null;
            rest = merge(rest, pair);
        }
        self.first = rest;
        taken.heap_child = null;
        return taken;
    }

    /// The heap of two heaps' tasks; neither root has a sibling.
    fn merge(a: ?*RocTask, b: ?*RocTask) ?*RocTask {
        const x = a orelse return b;
        const y = b orelse return a;
        const first, const other = if (treeOrder(x, y) == .lt) .{ x, y } else .{ y, x };
        other.heap_sibling = first.heap_child;
        first.heap_child = other;
        return first;
    }
};

/// One run of a `None` program that can wait on shared state (design.md
/// "Shared State", "Programs without tasks."): the host of its tasks, from
/// `task_run`'s call of the root until it ends. Runs on several threads may
/// overlap, and one may be inside another's hosted call; each has its own
/// tasks.
pub const Scheduler = struct {
    /// The thread the run is on (`crash_exit.threadId`).
    thread: u64,
    root: *RocTask,
    /// The task whose resume is running.
    running: ?*RocTask,
    /// The tasks to resume: those readied, and of each group whose owner is
    /// waiting at its loop's next, the first entry that has not begun.
    readied: TaskHeap,

    /// The message of the crash when no task can run.
    pub const deadlock = "deadlock: no task can ever change the shared state this task waits for";

    /// `task_run`: run the root whose start record is `start`, with every task
    /// it makes, until it ends. Returns the address of its result, which
    /// `runEnd` frees once the caller has moved it out.
    pub fn run(ops: *RocOps, start: [*]u8, buffer_size: usize, buffer_alignment: usize, result_size: usize, result_alignment: usize) [*]u8 {
        @atomicStore(?*const fn () void, &run_crashed, &crashed, .monotonic);
        const result = allocBuffer(ops, result_size, result_alignment);
        var self = Scheduler{ .thread = crash_exit.threadId(), .root = undefined, .running = null, .readied = .{} };
        self.root = RocTask.create(ops, start, result, .{
            .hosted_slot_size = 0,
            .hosted_slot_alignment = 1,
            .result_buffer_size = buffer_size,
            .result_buffer_alignment = buffer_alignment,
        });
        self.root.scheduler = &self;
        self.readied.add(self.root);
        while (true) {
            const task = self.next() orelse ops.crash(deadlock);
            // The entry after it is the next one its owner asked for.
            if (!task.started) if (task.group) |group| self.offer(group);
            self.running = task;
            const status = task.resumeTask();
            self.running = null;
            if (status == .pending) {
                if (task.wait) |group| self.offer(group);
            } else if (task == self.root) break;
        }
        self.root.release();
        return result;
    }

    /// `task_run_end`.
    pub fn runEnd(ops: *RocOps, result: [*]u8, result_size: usize, result_alignment: usize) void {
        freeBuffer(ops, result, result_size, result_alignment);
    }

    /// `task` may be resumed: it is new, or was parked and now has something.
    fn ready(self: *Scheduler, task: *RocTask) void {
        if (coroutineMayBegin(task)) return self.readied.add(task);
        task.group.?.unbegun.add(task);
    }

    /// Ready the first entry of `group` that has not begun, if its owner waits
    /// at its loop's next.
    fn offer(self: *Scheduler, group: *Group) void {
        const first = group.unbegun.takeFirst() orelse return;
        if (group.owner.wait != group) return group.unbegun.add(first);
        self.readied.add(first);
    }

    /// The next task to resume, or null when none can run.
    fn next(self: *Scheduler) ?*RocTask {
        while (self.readied.takeFirst()) |task| {
            if (coroutineMayBegin(task)) return task;
            // Its owner is waiting elsewhere by now.
            task.group.?.unbegun.add(task);
        }
        const group = self.firstUnbegun() orelse return null;
        return group.unbegun.takeFirst();
    }

    /// The group whose entry is the first in the tree that has not begun.
    fn firstUnbegun(self: *Scheduler) ?*Group {
        // In tree order: a task, then its open groups' entries, outermost
        // group first, each with its own descendants.
        var task = self.root;
        while (true) {
            if (!task.started) return task.group;
            var place = task.firstEntry();
            while (place == null) {
                const group = task.group orelse return null;
                place = group.entryFrom(task.entry_index + 1);
                task = group.owner;
            }
            task = place.?;
        }
    }

    /// The running task of the calling thread's run, if it waits on `cell`: an
    /// update it runs is then the one that waited, run again.
    fn retriedWaiter(cell: *anyopaque) ?*RocTask {
        const waiters = cellWaiters(cell);
        var next_waiter = waiters.after(cell, null);
        while (next_waiter) |waiter| : (next_waiter = waiters.after(cell, waiter)) {
            const scheduler = waiter.scheduler orelse continue;
            if (scheduler.running == waiter) return waiter;
        }
        return null;
    }

    /// A crash with no running task. If the calling thread is running a probe
    /// of one of its runs' waiters, that is the probe's answer. Otherwise its
    /// runs are over, and the crash is the host's.
    fn crashed() void {
        const thread = crash_exit.threadId();
        for (&cell_waiters) |*waiters| {
            if (waiters.empty()) continue;
            waiters.list.lock();
            const probing = waiterOn(waiters.oldest, thread, true);
            waiters.list.unlock();
            if (probing) |task| if (crash_exit.available()) crash_exit.jump(&task.crash_jmp);
        }
        for (&cell_waiters) |*waiters| {
            if (waiters.empty()) continue;
            waiters.list.lock();
            while (waiterOn(waiters.oldest, thread, false)) |task| waiters.unlink(task);
            waiters.list.unlock();
        }
    }

    /// The first waiter from `first` on of a run on `thread`, one whose probe
    /// is running when `probing` holds. Another thread's are only looked at for
    /// their run, which the list's lock keeps from ending.
    fn waiterOn(first: ?*RocTask, thread: u64, probing: bool) ?*RocTask {
        var next_waiter = first;
        while (next_waiter) |waiter| : (next_waiter = waiter.newer_waiter) {
            const scheduler = waiter.scheduler orelse continue;
            if (scheduler.thread == thread and (!probing or waiter.probing)) return waiter;
        }
        return null;
    }
};

/// A buffer no result is ever written to has no allocation.
var empty_buffer: [1]u8 align(16) = .{0};

fn allocBuffer(ops: *RocOps, size: usize, alignment: usize) [*]u8 {
    if (size == 0) return &empty_buffer;
    return @ptrCast(ops.alloc(alignment, size));
}

fn freeBuffer(ops: *RocOps, buffer: [*]u8, size: usize, alignment: usize) void {
    if (size == 0) return;
    ops.dealloc(@ptrCast(buffer), alignment);
}

// Tests drive the runtime with records built in Zig: each record's capture
// is a `TestStep` saying what its call does, and every call is logged.

const TestStep = extern struct {
    id: u8,
    /// Records this call saves before pausing, innermost first, or none.
    saves: [2]?[*]u8,
    /// Pause after saving, as a pending edge does.
    pauses: bool,
    /// What it writes through the result pointer.
    result: u8,
    /// Crash after saving, instead of pausing or writing a result.
    crashes: bool = false,
    /// With `crashes`, crash this many frames down a chain of calls that
    /// each hold values across the next (`crashDeep`).
    crash_depth: u8 = 0,
    /// With `pauses`, wake the task before returning, as a host that
    /// finished the operation on another thread before the hosted function
    /// returned does.
    wakes_early: bool = false,
};

const TestLog = struct {
    var calls: [16]u8 = undefined;
    var call_count: usize = 0;
    var results_written_to: [16]?[*]u8 = undefined;
    var drops: usize = 0;
    var slot_drops: usize = 0;
    var aborts: usize = 0;
    var readies: usize = 0;
    /// What `crashDeep` would return; never written, since it crashes.
    var deep_sink: u64 = 0;

    fn reset() void {
        call_count = 0;
        drops = 0;
        slot_drops = 0;
        aborts = 0;
        readies = 0;
    }
};

fn testStepCall(ops: *RocOps, ret: ?[*]u8, args: ?[*]const u8, capture: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const step: *const TestStep = @ptrCast(@alignCast(capture.?));
    const task: *RocTask = @as(*const *RocTask, @ptrCast(@alignCast(args.?))).*;
    TestLog.calls[TestLog.call_count] = step.id;
    TestLog.results_written_to[TestLog.call_count] = ret;
    TestLog.call_count += 1;
    for (step.saves) |save| if (save) |record| task.pushRecord(testMoveIntoTask(task, record), &testSlotDrop);
    if (step.crashes and step.crash_depth > 0) TestLog.deep_sink = @call(.never_inline, crashDeep, .{ ops, step.crash_depth, step.id });
    if (step.crashes) ops.crash("a record crashed");
    if (step.pauses) {
        task.setPending();
        if (step.wakes_early) task.wake(&testReady);
    }
    ret.?[0] = step.result;
}

/// A chain of `depth` frames, each holding integer and float values across
/// the next call, so the callee-saved registers and the stack are live
/// when the bottom one crashes.
fn crashDeep(ops: *RocOps, depth: u8, seed: u64) u64 {
    if (depth == 0) {
        ops.crash("a record crashed deep");
        return seed;
    }
    const a = seed *% 0x9e3779b97f4a7c15 +% depth;
    const b = a ^ (a >> 29);
    const c = b *% 0xbf58476d1ce4e5b9;
    const f: f64 = @floatFromInt(a >> 11);
    const below = @call(.never_inline, crashDeep, .{ ops, depth - 1, c });
    return a +% b +% c +% below +% @as(u64, @intFromFloat(f * 0.5));
}

fn testStepDrop(_: ?[*]u8, _: *RocOps) callconv(.c) void {
    TestLog.drops += 1;
}

fn testSlotDrop(_: [*]u8, _: [*]u8, _: *RocOps) callconv(.c) void {
    TestLog.slot_drops += 1;
}

fn testAbort(_: *RocTask) callconv(.c) void {
    TestLog.aborts += 1;
}

fn testReady(_: *RocTask) callconv(.c) void {
    TestLog.readies += 1;
}

/// A copy of `record` in memory `task` allocates, as `suspend_save` packs
/// one, with the original freed. Tests build records before their task.
fn testMoveIntoTask(task: *RocTask, record: [*]u8) [*]u8 {
    const size = erased_callable.payloadSize(erased_callable.payloadPtr(record).capture_size);
    const moved = task.allocRecord(size);
    @memcpy(moved[0..size], record[0..size]);
    utils.freeDataPtrC(record, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, task.ops);
    return moved;
}

fn testRecord(ops: *RocOps, step: TestStep) [*]u8 {
    const record = erased_callable.allocate(&testStepCall, &testStepDrop, @sizeOf(TestStep), ops);
    @as(*align(1) TestStep, @ptrCast(erased_callable.capturePtr(record))).* = step;
    return record;
}

const test_buffers = BufferLayout{
    .hosted_slot_size = 8,
    .hosted_slot_alignment = 8,
    .result_buffer_size = 8,
    .result_buffer_alignment = 8,
};

const dev_wrappers = @import("dev_wrappers.zig");

test "the pending flag starts clear and is set by setPending" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    var root: [1]u8 = undefined;
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 0 }), &root, test_buffers);
    try std.testing.expect(task.ready());
    task.setPending();
    try std.testing.expect(!task.ready());
    task.pending = 0;
    try std.testing.expectEqual(Status.done, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a resume runs an unwind's records innermost first, the outermost into the root's result" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // The start record (1) pauses after saving 2 (innermost) then 3; on
    // resume 2 runs, then 3, which writes the root's result.
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    const outer = testRecord(ops, .{ .id = 3, .saves = .{ null, null }, .pauses = false, .result = 30 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 10 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 2), task.len);
    task.wake(&testReady);
    try std.testing.expectEqual(Status.done, task.resumeTask());

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(?[*]u8, task.result_buffer), TestLog.results_written_to[1]);
    try std.testing.expectEqual(@as(?[*]u8, &root), TestLog.results_written_to[2]);
    try std.testing.expectEqual(@as(u8, 30), root[0]);
    try std.testing.expectEqual(@as(usize, 3), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "records a resumed record saves go before the records still waiting" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // 1 saves 2 then 9 and pauses. Resumed, 2 saves 4 then 5 and pauses
    // again, so the list runs 4, 5, then 9.
    const nested_inner = testRecord(ops, .{ .id = 4, .saves = .{ null, null }, .pauses = false, .result = 0 });
    const nested_outer = testRecord(ops, .{ .id = 5, .saves = .{ null, null }, .pauses = false, .result = 0 });
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ nested_inner, nested_outer }, .pauses = true, .result = 0 });
    const outer = testRecord(ops, .{ .id = 9, .saves = .{ null, null }, .pauses = false, .result = 90 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&testReady);
    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&testReady);
    try std.testing.expectEqual(Status.done, task.resumeTask());

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 4, 5, 9 }, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(u8, 90), root[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a task reuses a released record's memory for its next record of that size class, and frees the rest with itself" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 10 }), &root, test_buffers);
    try std.testing.expectEqual(Status.done, task.resumeTask());
    const step: TestStep = .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 };

    // A released record goes to its class's list, not back to the
    // allocator, and the next record of that class takes its memory.
    const first = testMoveIntoTask(task, testRecord(ops, step));
    const allocations = test_env.getAllocationCount();
    const drops = TestLog.drops;
    task.releaseRecord(first, true);
    try std.testing.expectEqual(drops + 1, TestLog.drops);
    try std.testing.expectEqual(allocations, test_env.getAllocationCount());
    const second = testMoveIntoTask(task, testRecord(ops, step));
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(allocations, test_env.getAllocationCount());

    // A record of another class gets fresh memory.
    const wider = testMoveIntoTask(task, erased_callable.allocate(&testStepCall, &testStepDrop, @sizeOf(TestStep) + record_class_bytes, ops));
    try std.testing.expect(wider != second);
    try std.testing.expectEqual(allocations + 1, test_env.getAllocationCount());

    // One past the largest class is freed on release.
    const huge = testMoveIntoTask(task, erased_callable.allocate(&testStepCall, &testStepDrop, record_classes * record_class_bytes, ops));
    try std.testing.expectEqual(allocations + 2, test_env.getAllocationCount());
    task.releaseRecord(huge, true);
    try std.testing.expectEqual(allocations + 1, test_env.getAllocationCount());

    // Freeing the task frees what its cache holds.
    task.releaseRecord(second, true);
    task.releaseRecord(wider, true);
    try std.testing.expectEqual(drops + 4, TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "cancelling a parked task aborts its operation and readies it, and the next resume releases every record" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 });
    const outer = testRecord(ops, .{ .id = 3, .saves = .{ null, null }, .pauses = false, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.cancel(&testAbort, &testReady);
    try std.testing.expectEqual(@as(usize, 1), TestLog.aborts);
    try std.testing.expectEqual(@as(usize, 1), TestLog.readies);
    // A request: nothing is released until the resume.
    try std.testing.expectEqual(@as(usize, 1), TestLog.drops);
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 0), TestLog.slot_drops);
    try std.testing.expectEqual(@as(usize, 3), TestLog.drops);
    try std.testing.expectEqualSlices(u8, &.{1}, TestLog.calls[0..TestLog.call_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "cancelling a woken task neither aborts nor readies it again, and the resume releases the hosted result" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, null }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&testReady);
    task.cancel(&testAbort, &testReady);
    try std.testing.expectEqual(@as(usize, 0), TestLog.aborts);
    try std.testing.expectEqual(@as(usize, 1), TestLog.readies);
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 1), TestLog.slot_drops);
    try std.testing.expectEqual(@as(usize, 2), TestLog.drops);
    try std.testing.expectEqualSlices(u8, &.{1}, TestLog.calls[0..TestLog.call_count]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

/// An abort that finds the host already finished: the completion took the
/// operation's lock first, between the cancel's unpark and its abort.
fn testAbortAfterWake(task: *RocTask) callconv(.c) void {
    task.wake(&testReady);
    TestLog.aborts += 1;
}

test "a completion that lands between a cancel's unpark and its abort is released by the cancelling resume, with one ready" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, null }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.cancel(&testAbortAfterWake, &testReady);
    // The wake found the task unparked, so only the cancel readied it.
    try std.testing.expectEqual(@as(usize, 1), TestLog.readies);
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 1), TestLog.slot_drops);
    try std.testing.expectEqual(@as(usize, 2), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a task cancelled before its first resume runs no record, and a second cancel changes nothing" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 7 }), &root, test_buffers);

    task.cancel(&testAbort, &testReady);
    task.cancel(&testAbort, &testReady);
    try std.testing.expectEqual(@as(usize, 0), TestLog.aborts);
    try std.testing.expectEqual(@as(usize, 0), TestLog.readies);
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 0), TestLog.call_count);
    try std.testing.expectEqual(@as(usize, 1), TestLog.drops);
    try std.testing.expectEqual(@as(u8, 0), root[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a second cancel of a parked task neither aborts nor readies it again" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.cancel(&testAbort, &testReady);
    task.cancel(&testAbort, &testReady);
    try std.testing.expectEqual(@as(usize, 1), TestLog.aborts);
    try std.testing.expectEqual(@as(usize, 1), TestLog.readies);
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "the host's C calls resume and free a task and report its status as a C enum" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, null }, .pauses = true, .result = 10 }), &root, test_buffers);

    try std.testing.expectEqual(@as(?ReadyFn, null), task.ready_fn);
    try std.testing.expectEqual(@as(u32, 0), dev_wrappers.roc_builtins_task_resume(task, &testReady, &testAbort));
    // The resume keeps the host's functions for the task's children.
    try std.testing.expectEqual(@as(?ReadyFn, &testReady), task.ready_fn);
    try std.testing.expectEqual(@as(?AbortFn, &testAbort), task.abort_fn);
    task.wake(&testReady);
    try std.testing.expectEqual(@as(u32, 1), dev_wrappers.roc_builtins_task_resume(task, &testReady, &testAbort));
    try std.testing.expectEqual(@as(u8, 20), root[0]);
    host_calls.free(task);
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "each park gets exactly one roc_task_ready, from the wake" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // Pauses twice: 1 saves 2, which saves 3; each pause parks once.
    const last = testRecord(ops, .{ .id = 3, .saves = .{ null, null }, .pauses = false, .result = 30 });
    const middle = testRecord(ops, .{ .id = 2, .saves = .{ last, null }, .pauses = true, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ middle, null }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    try std.testing.expectEqual(wake_parked, task.wake_word);
    try std.testing.expectEqual(@as(usize, 0), TestLog.readies);
    task.wake(&testReady);
    try std.testing.expectEqual(@as(u32, 1), task.wake_word);
    try std.testing.expectEqual(@as(usize, 1), TestLog.readies);
    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&testReady);
    try std.testing.expectEqual(@as(usize, 2), TestLog.readies);
    try std.testing.expectEqual(Status.done, task.resumeTask());
    try std.testing.expectEqual(@as(u32, 0), task.wake_word);
    try std.testing.expectEqual(@as(u8, 30), root[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a completion that arrives before the task parks is consumed by the same resume, with no roc_task_ready" {
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // 1 saves 2 and pauses, but its host finished first: the resume runs
    // straight on into 2 instead of returning PENDING.
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, null }, .pauses = true, .result = 0, .wakes_early = true }), &root, test_buffers);

    try std.testing.expectEqual(Status.done, task.resumeTask());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(usize, 0), TestLog.readies);
    try std.testing.expectEqual(@as(u32, 0), task.wake_word);
    try std.testing.expectEqual(@as(u8, 20), root[0]);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a crash in a resumed record ends its task, releases every record and keeps the message" {
    if (!crash_exit.available()) return error.SkipZigTest;
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // 1 saves 2 then 3 and pauses. Resumed, 2 crashes: 2 (running) and 3
    // (waiting) are released, and 3 never runs.
    const inner = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0, .crashes = true });
    const outer = testRecord(ops, .{ .id = 3, .saves = .{ null, null }, .pauses = false, .result = 30 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ inner, outer }, .pauses = true, .result = 0 }), &root, test_buffers);

    try std.testing.expectEqual(Status.pending, task.resumeTask());
    task.wake(&testReady);
    try std.testing.expectEqual(@as(u32, 3), dev_wrappers.roc_builtins_task_resume(task, &testReady, &testAbort));
    try std.testing.expectEqual(Status.crashed, task.status);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(usize, 3), TestLog.drops);
    try std.testing.expectEqual(@as(u8, 0), root[0]);
    var len: usize = undefined;
    const message = host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("a record crashed", message[0..len]);
    try std.testing.expectEqual(@as(?*RocTask, null), runningSlot().*);
    host_calls.free(task);
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a crash after a record saved others releases those too" {
    if (!crash_exit.available()) return error.SkipZigTest;
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    // The start record saves 2 and then crashes before it can pause.
    const saved = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 0 });
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ saved, null }, .pauses = false, .result = 0, .crashes = true }), &root, test_buffers);

    try std.testing.expectEqual(Status.crashed, task.resumeTask());
    try std.testing.expectEqualSlices(u8, &.{1}, TestLog.calls[0..TestLog.call_count]);
    try std.testing.expectEqual(@as(usize, 2), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a crash several frames deep leaves the resume's caller's values intact" {
    if (!crash_exit.available()) return error.SkipZigTest;
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    TestLog.reset();
    var root: [1]u8 = .{0};
    const task = RocTask.create(ops, testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 0, .crashes = true, .crash_depth = 8 }), &root, test_buffers);

    // Values computed at run time and used after the resume, so they live
    // in callee-saved registers or this frame across it.
    var seed: u64 = 0x0123_4567_89ab_cdef;
    std.mem.doNotOptimizeAway(&seed);
    const v0 = seed *% 3;
    const v1 = seed ^ 0xffff_0000_ffff_0000;
    const v2 = seed >> 7;
    const v3 = v0 +% v1;
    const v4 = v1 *% v2;
    const v5 = v2 ^ v3;
    const f0: f64 = @floatFromInt(seed >> 12);
    const f1 = f0 * 1.5;
    const f2 = f1 - f0 / 3.0;

    const status = @call(.never_inline, dev_wrappers.roc_builtins_task_resume, .{ task, &testReady, &testAbort });

    try std.testing.expectEqual(@as(u32, 3), status);
    try std.testing.expectEqual(seed *% 3, v0);
    try std.testing.expectEqual(seed ^ 0xffff_0000_ffff_0000, v1);
    try std.testing.expectEqual(seed >> 7, v2);
    try std.testing.expectEqual(v0 +% v1, v3);
    try std.testing.expectEqual(v1 *% v2, v4);
    try std.testing.expectEqual(v2 ^ v3, v5);
    try std.testing.expectEqual(@as(f64, @floatFromInt(seed >> 12)), f0);
    try std.testing.expectEqual(f0 * 1.5, f1);
    try std.testing.expectEqual(f1 - f0 / 3.0, f2);
    var len: usize = undefined;
    const message = host_calls.crashMessage(task, &len);
    try std.testing.expectEqualStrings("a record crashed deep", message[0..len]);
    try std.testing.expectEqual(@as(?*RocTask, null), runningSlot().*);
    host_calls.free(task);
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}

test "a hosted call runs with no running task, so a crash in it reaches the host" {
    var task: RocTask = undefined;
    runningSlot().* = &task;
    defer runningSlot().* = null;
    const saved = hostEnter();
    try std.testing.expectEqual(@as(?*RocTask, &task), saved);
    try std.testing.expectEqual(@as(?*RocTask, null), runningSlot().*);
    // With no running task, a crash returns to its caller, which hands it
    // to the host, rather than jumping to `task`'s exit.
    crashRunning("the host crashed");
    hostLeave(saved);
    try std.testing.expectEqual(@as(?*RocTask, &task), runningSlot().*);
}

test "FieldOffsets is where RocTask keeps its first three fields, scaled by the pointer size" {
    const native = FieldOffsets.forPointerSize(@sizeOf(usize));
    try std.testing.expectEqual(@as(usize, native.pending), @offsetOf(RocTask, "pending"));
    try std.testing.expectEqual(@as(usize, native.hosted_slot), @offsetOf(RocTask, "hosted_slot"));
    try std.testing.expectEqual(@as(usize, native.result_buffer), @offsetOf(RocTask, "result_buffer"));
    try std.testing.expectEqual(FieldOffsets{ .pending = 0, .hosted_slot = 4, .result_buffer = 8 }, FieldOffsets.forPointerSize(4));
}

test "compiled code's task builtins create a task with the entered ops and push records onto its list" {
    const in_process_host = @import("in_process_host.zig");
    var test_env = utils.TestEnv.init(std.testing.allocator);
    defer test_env.deinit();
    const ops = test_env.getOps();
    const saved_host = in_process_host.enter(ops, null);
    defer in_process_host.leave(saved_host);
    TestLog.reset();

    var root: [1]u8 = .{0};
    const start = testRecord(ops, .{ .id = 1, .saves = .{ null, null }, .pauses = false, .result = 10 });
    const task = dev_wrappers.roc_builtins_task_create(start, &root, 16, 8, 24, 8);
    try std.testing.expectEqual(ops, task.ops);
    try std.testing.expectEqual(@as(usize, 16), task.hosted_slot_size);
    try std.testing.expectEqual(@as(usize, 24), task.result_buffer_size);
    try std.testing.expectEqual(@as(usize, 1), task.len);
    try std.testing.expectEqual(start, task.entries[0].record);

    const size = erased_callable.payloadSize(@sizeOf(TestStep));
    const record = dev_wrappers.roc_builtins_task_alloc_record(task, size);
    const built = testRecord(ops, .{ .id = 2, .saves = .{ null, null }, .pauses = false, .result = 20 });
    @memcpy(record[0..size], built[0..size]);
    utils.freeDataPtrC(built, erased_callable.payload_alignment, erased_callable.allocation_has_refcounted_children, ops);
    dev_wrappers.roc_builtins_task_push_record(task, record, &testSlotDrop);
    try std.testing.expectEqual(@as(usize, 2), task.len);
    try std.testing.expectEqual(record, task.entries[1].record);
    try std.testing.expectEqual(@as(?SlotDropFn, &testSlotDrop), task.entries[1].slot_drop);

    // Cancelled before the first resume: that resume releases both records.
    task.cancel(&testAbort, &testReady);
    try std.testing.expectEqual(Status.cancelled, task.resumeTask());
    try std.testing.expectEqual(@as(usize, 2), TestLog.drops);
    task.free();
    try std.testing.expectEqual(@as(usize, 0), test_env.getAllocationCount());
}
