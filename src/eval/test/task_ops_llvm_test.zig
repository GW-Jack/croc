//! The promoted running-set programs of `task_ops_lir_test.zig`, compiled
//! by the LLVM backend and loaded in this process (design.md "Backends").
//! The program links its own builtins, so its tasks resume through its
//! exported `roc_task_resume` and are freed through its `roc_task_free`.
//! Its builtins ready tasks through the host's `roc_task_ready`, which this
//! test host queues for `lir_test`'s drive functions.

const std = @import("std");
const builtins = @import("builtins");
const eval = @import("eval");
const lir = @import("lir");
const lir_test = @import("task_ops_lir_test.zig");

const LIR = lir.LIR;
const RocTask = builtins.task.RocTask;
const Status = builtins.task.Status;
const Fixture = lir_test.Fixture;
const shim_symbols = builtins.shim_symbols;

const LlvmTaskTestError = lir_test.TaskOpsTestError || eval.InspectedRun.LlvmError || error{MissingTaskCall};

/// The C-ABI host the loaded program's hosted calls reach. Compiled code
/// calls it through plain function pointers, so it lives in globals.
const LlvmHost = struct {
    var ready_queue: [32]*RocTask = undefined;
    var ready_len: usize = 0;
    var calls: u32 = 0;

    /// `void roc_task_ready(RocTask *task)`.
    fn ready(task: *RocTask) callconv(.c) void {
        ready_queue[ready_len] = task;
        ready_len += 1;
    }

    /// `void roc_task_abort(RocTask *task)`: nothing here has a host call
    /// to abort.
    fn abort(_: *RocTask) callconv(.c) void {}

    /// `roc_test_unused`, which the promotion programs' `run_entry!` calls
    /// only on an entry no test uses: it counts as a call nobody expected.
    fn unused(_: *RocTask, _: [*]u8) callconv(.c) u32 {
        calls += 1;
        return 0;
    }

    fn resolve(_: ?*anyopaque, name: []const u8) ?usize {
        if (std.mem.eql(u8, name, shim_symbols.roc_task_ready)) return @intFromPtr(&ready);
        if (std.mem.eql(u8, name, shim_symbols.roc_task_abort)) return @intFromPtr(&abort);
        if (std.mem.eql(u8, name, "roc_test_unused")) return @intFromPtr(&unused);
        return null;
    }
};

const ResumeFn = *const fn (*RocTask) callconv(.c) u32;
const FreeFn = *const fn (*RocTask) callconv(.c) void;

/// `f`'s program compiled by the LLVM backend and loaded, with the task
/// entry as its main procedure. It runs tasks for `lir_test`'s drive
/// functions.
const LlvmRun = struct {
    image: eval.InspectedRun.LlvmImage,
    resume_task: ResumeFn,
    free_task: FreeFn,
    entered: builtins.in_process_host.Saved,

    /// A task, by its address.
    pub const Task = *RocTask;
    /// What running a task in the loaded program can fail with.
    pub const Error = LlvmTaskTestError;

    /// Compile and load `f` with `entry` as its main procedure, and enter
    /// `f`'s runtime host for the builtins.
    fn init(self: *LlvmRun, f: *Fixture, entry: LIR.LirProcSpecId) LlvmTaskTestError!void {
        LlvmHost.calls = 0;
        // Code generation takes LIR after ARC, which the pipeline runs after
        // the continuation pass, with the task entry as a root.
        _ = try lir.Arc.insert(&f.store, &f.layouts, .{ .roots = &.{entry} });
        self.image = try eval.InspectedRun.LlvmImage.load(f.allocator, .{
            .store = &f.store,
            .layouts = &f.layouts,
            .erased_capture_prefix = 0,
            .main_proc = entry,
        }, .{ .resolve = LlvmHost.resolve });
        errdefer self.image.deinit();
        self.resume_task = self.image.lib.lookup(ResumeFn, shim_symbols.roc_task_resume) orelse return error.MissingTaskCall;
        self.free_task = self.image.lib.lookup(FreeFn, shim_symbols.roc_task_free) orelse return error.MissingTaskCall;
        self.entered = builtins.in_process_host.enter(f.runtime_env.get_ops(), null);
    }

    fn deinit(self: *LlvmRun) void {
        builtins.in_process_host.leave(self.entered);
        self.image.deinit();
    }

    /// Call a promotion program's task entry, which takes only the root
    /// result's address, and return the task it creates.
    fn startRoot(self: *LlvmRun, root: [*]u8) LlvmTaskTestError!*RocTask {
        const entry = try self.image.entry();
        var result_out: usize = @intFromPtr(root);
        var created: usize = 0;
        entry(@ptrCast(&created), @ptrCast(&result_out));
        return @ptrFromInt(created);
    }

    /// Forget the tasks readied so far.
    pub fn begin(_: *LlvmRun) void {
        LlvmHost.ready_len = 0;
    }

    /// Resume `task` through the program's `roc_task_resume` and return its
    /// status.
    pub fn resumeTask(self: *LlvmRun, task: *RocTask) LlvmTaskTestError!Status {
        return @fromBackingInt(@intCast(self.resume_task(task)));
    }

    /// Every task readied since `begin`, in order.
    pub fn readied(_: *LlvmRun) []const *RocTask {
        return LlvmHost.ready_queue[0..LlvmHost.ready_len];
    }
};

test "a promoted loop runs its entries as child tasks and spawns into its set on the LLVM backend" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try lir_test.promotionProgram(&f, .{ false, true, true }, .sum_and_spawn, .arc, .direct);
    var run: LlvmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.startRoot(@ptrCast(&root));
    try lir_test.driveSpawnLoop(LlvmRun, &run, task);
    try std.testing.expectEqual(lir_test.spawn_loop_result, root);
    try std.testing.expectEqual(@as(u32, 0), LlvmHost.calls);
    run.free_task(task);
    try f.runtime_env.checkForLeaks();
}

test "a promoted loop cancels its set and drains it on the LLVM backend" {
    var f = try Fixture.init(std.testing.allocator);
    defer f.deinit();
    const entry = try lir_test.promotionProgram(&f, .{ false, false, false }, .first, .arc, .copied_i128);
    var run: LlvmRun = undefined;
    try run.init(&f, entry);
    defer run.deinit();
    var root: u64 = 0;
    const task = try run.startRoot(@ptrCast(&root));
    try lir_test.driveCancelLoop(LlvmRun, &run, task);
    try std.testing.expectEqual(lir_test.cancel_loop_result, root);
    try std.testing.expectEqual(@as(u32, 0), LlvmHost.calls);
    run.free_task(task);
    try f.runtime_env.checkForLeaks();
}
