//! A deterministic test host for `concurrency: Tasks` programs on the
//! interpreter (design.md "What Implements It First"). It serves the hosted
//! functions of the test/postcheck/suspension_* fixtures:
//!
//! - `roc_host_fetch` (`suspending fetch! : Str => Str`) answers
//!   `"<url>/body"`, at once in `.ready` mode, or by pausing in `.pause`
//!   mode, writing the result when the driver finishes the operation;
//! - `roc_host_log` (`log! : Str => {}`) only records its argument.
//!
//! Every call goes into a trace, so a pausing run can be compared with a
//! run that never pauses. The host owns its arguments, as every hosted
//! function does, and releases them.

const std = @import("std");
const builtins = @import("builtins");
const eval = @import("eval");

const RocOps = builtins.host_abi.RocOps;
const RocStr = builtins.str.RocStr;
const RocTask = builtins.task.RocTask;
const Status = builtins.task.Status;

const poll_ready: u32 = 0;
const poll_pending: u32 = 1;

/// Whether a suspending call finishes at once or pauses its task.
pub const Mode = enum { ready, pause };

/// A suspending call the host has not finished yet.
const Pending = struct {
    task: *RocTask,
    out: *align(1) RocStr,
    url: RocStr,
};

/// The host: its mode, its trace, and the operation a paused task waits on.
pub const TestHost = struct {
    allocator: std.mem.Allocator,
    ops: *RocOps,
    mode: Mode,
    trace: std.ArrayList([]u8) = .empty,
    pending: ?Pending = null,
    /// How many suspending calls paused.
    pauses: u32 = 0,
    /// How many paused operations a cancel abandoned.
    aborts: u32 = 0,
    /// How many times a wake told the host a parked task is ready.
    readies: u32 = 0,
    /// The task's `roc_task_wake`: a program's own, or `nativeWake`.
    wake: WakeFn = &nativeWake,
    /// The task's `roc_task_resume` and `roc_task_free`: a program's own
    /// when it links the builtins privately (LLVM), so one runtime handles
    /// its tasks (design.md "Backends", One runtime per process), or this
    /// process's (`nativeResume`).
    resume_task: ResumeFn = &nativeResume,
    free_task: FreeFn = &builtins.task.host_calls.free,

    pub fn init(allocator: std.mem.Allocator, ops: *RocOps, mode: Mode) TestHost {
        return .{ .allocator = allocator, .ops = ops, .mode = mode };
    }

    pub fn deinit(self: *TestHost) void {
        if (self.pending) |pending| pending.url.decref(self.ops);
        for (self.trace.items) |entry| self.allocator.free(entry);
        self.trace.deinit(self.allocator);
    }

    pub fn handler(self: *TestHost) eval.Interpreter.HostedCallHandler {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(context: *anyopaque, call: eval.Interpreter.HostedCall) eval.Interpreter.Error!void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, call.symbol, "roc_host_fetch")) {
            // The host's shape: the task and the result pointer come first.
            const poll = try self.fetch(@ptrFromInt(readArg(usize, call, 0)), @ptrFromInt(readArg(usize, call, 1)), readArg(RocStr, call, 2));
            std.mem.writeInt(u32, call.ret[0..4], poll, .little);
            return;
        }
        if (std.mem.eql(u8, call.symbol, "roc_host_log")) return self.log(readArg(RocStr, call, 0));
        return error.UnsupportedHostedFunction;
    }

    /// `roc_host_fetch`: answer at once, or pause the task on the operation.
    /// Only a pause needs the task.
    fn fetch(self: *TestHost, task: ?*RocTask, out: *align(1) RocStr, url: RocStr) eval.Interpreter.Error!u32 {
        try self.note("fetch", url);
        switch (self.mode) {
            .ready => {
                out.* = try self.answer(url);
                url.decref(self.ops);
                return poll_ready;
            },
            .pause => {
                // A task waits on at most one hosted operation at a time.
                if (self.pending != null) return error.RuntimeError;
                self.pending = .{ .task = task orelse return error.RuntimeError, .out = out, .url = url };
                self.pauses += 1;
                return poll_pending;
            },
        }
    }

    /// `roc_host_log`: record the text and release it.
    fn log(self: *TestHost, text: RocStr) eval.Interpreter.Error!void {
        try self.note("log", text);
        text.decref(self.ops);
    }

    /// Serve compiled code's hosted calls (design.md "Backends") until
    /// `leaveCAbi`: `resolveCAbiSymbol` binds the fixture's hosted symbols to
    /// functions that reach this host.
    pub fn enterCAbi(self: *TestHost) void {
        std.debug.assert(c_abi_host == null);
        c_abi_host = self;
    }

    /// Stop serving compiled code's hosted calls.
    pub fn leaveCAbi(self: *TestHost) void {
        std.debug.assert(c_abi_host == self);
        c_abi_host = null;
    }

    fn answer(self: *TestHost, url: RocStr) std.mem.Allocator.Error!RocStr {
        const text = try std.fmt.allocPrint(self.allocator, "{s}/body", .{url.asSlice()});
        defer self.allocator.free(text);
        return RocStr.fromSlice(text, self.ops);
    }

    fn note(self: *TestHost, name: []const u8, arg: RocStr) eval.Interpreter.Error!void {
        const entry = std.fmt.allocPrint(self.allocator, "{s}({s})", .{ name, arg.asSlice() }) catch return error.OutOfMemory;
        self.trace.append(self.allocator, entry) catch {
            self.allocator.free(entry);
            return error.OutOfMemory;
        };
    }

    /// Finish the paused operation: write its result and wake its task.
    pub fn finish(self: *TestHost) std.mem.Allocator.Error!void {
        const pending = self.pending.?;
        self.pending = null;
        pending.out.* = try self.answer(pending.url);
        pending.url.decref(self.ops);
        active_host = self;
        self.wake(pending.task);
        active_host = null;
    }

    /// Resume `task` through the runtime that made it.
    pub fn resumeTask(self: *TestHost, task: *RocTask) Status {
        return @fromBackingInt(@as(u8, @intCast(self.resume_task(task))));
    }

    /// Free `task` through the runtime that made it.
    pub fn freeTask(self: *TestHost, task: *RocTask) void {
        self.free_task(task);
    }

    /// Run `task` to its end, finishing every paused operation.
    pub fn drive(self: *TestHost, task: *RocTask) std.mem.Allocator.Error!Status {
        var status = self.resumeTask(task);
        while (status == .pending) {
            try self.finish();
            status = self.resumeTask(task);
        }
        return status;
    }

    /// Run `task` until its `pause`th pause (counting from 1), then cancel
    /// it there with `cancel`, before the host finishes the operation when
    /// `woken` is false and after it when true, and resume it once more: a
    /// cancel is a request the next resume carries out. Returns the task's
    /// last status: `.done` when it finished before that pause. Pause 0
    /// cancels before the first resume.
    pub fn driveAndCancel(self: *TestHost, task: *RocTask, pause: u32, woken: bool, cancel: CancelFn) std.mem.Allocator.Error!Status {
        if (pause == 0) {
            active_host = self;
            cancel(task);
            active_host = null;
            return self.resumeTask(task);
        }
        var status = self.resumeTask(task);
        var seen: u32 = 0;
        while (status == .pending) {
            seen += 1;
            if (seen == pause) {
                if (woken) try self.finish();
                active_host = self;
                cancel(task);
                active_host = null;
                // Readied by the cancel, or by the wake before it.
                return self.resumeTask(task);
            }
            try self.finish();
            status = self.resumeTask(task);
        }
        return status;
    }
};

/// `roc_task_wake`: a program's own, or `nativeWake`.
pub const WakeFn = *const fn (*RocTask) callconv(.c) void;

/// `roc_task_resume`, which returns a `RocTaskStatus`.
pub const ResumeFn = *const fn (*RocTask) callconv(.c) u32;

/// `roc_task_free`.
pub const FreeFn = *const fn (*RocTask) callconv(.c) void;

/// Wake with the test host's `roc_task_ready`, as a program's
/// `roc_task_wake` does, for a run whose program defines none.
pub fn nativeWake(task: *RocTask) callconv(.c) void {
    task.wake(&readyTask);
}

/// `roc_task_cancel`: a program's own, or `nativeCancel`.
pub const CancelFn = *const fn (*RocTask) callconv(.c) void;

/// Resume with the test host's `roc_task_ready` and `roc_task_abort`, as a
/// program's `roc_task_resume` does, for a run whose program defines none.
pub fn nativeResume(task: *RocTask) callconv(.c) u32 {
    return builtins.dev_wrappers.roc_builtins_task_resume(task, &readyTask, &abortPending);
}

/// Cancel with the test host's `roc_task_abort` and `roc_task_ready`, as a
/// program's `roc_task_cancel` does, for a run whose program defines none.
pub fn nativeCancel(task: *RocTask) callconv(.c) void {
    task.cancel(&abortPending, &readyTask);
}

/// The host a wake's or a cancel's ready, or a cancel's abort, reaches:
/// `roc_task_ready` and `roc_task_abort` take only the task.
var active_host: ?*TestHost = null;

/// The host compiled code's hosted calls reach, between `enterCAbi` and
/// `leaveCAbi`. A C-ABI hosted function has no context argument.
var c_abi_host: ?*TestHost = null;

/// The first error a C-ABI hosted call hit, which it cannot return.
pub var c_abi_failure: ?eval.Interpreter.Error = null;

/// Bind the fixture's hosted symbols, and the host's `roc_task_ready` and
/// `roc_task_abort`, for
/// an object compiled code is loaded from, to the C-ABI functions that reach
/// the entered host.
pub fn resolveCAbiSymbol(_: ?*anyopaque, name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "roc_host_fetch")) return @intFromPtr(&cAbiFetch);
    if (std.mem.eql(u8, name, "roc_host_log")) return @intFromPtr(&cAbiLog);
    if (std.mem.eql(u8, name, builtins.shim_symbols.roc_task_ready)) return @intFromPtr(&readyTask);
    if (std.mem.eql(u8, name, builtins.shim_symbols.roc_task_abort)) return @intFromPtr(&abortPending);
    return null;
}

/// `u32 roc_host_fetch(RocTask *task, RocStr *out, RocStr url)`.
fn cAbiFetch(task: *RocTask, out: *RocStr, url: RocStr) callconv(.c) u32 {
    return c_abi_host.?.fetch(task, out, url) catch |err| blk: {
        if (c_abi_failure == null) c_abi_failure = err;
        break :blk poll_ready;
    };
}

/// `void roc_host_log(RocStr text)`.
fn cAbiLog(text: RocStr) callconv(.c) void {
    c_abi_host.?.log(text) catch |err| {
        if (c_abi_failure == null) c_abi_failure = err;
    };
}

/// `void roc_task_ready(RocTask *task)`: the task the host just woke was
/// parked, so the host may resume it. The driver resumes it next.
fn readyTask(_: *RocTask) callconv(.c) void {
    active_host.?.readies += 1;
}

/// `void roc_task_abort(RocTask *task)`.
fn abortPending(task: *RocTask) callconv(.c) void {
    const host = active_host.?;
    const pending = host.pending.?;
    std.debug.assert(pending.task == task);
    host.pending = null;
    host.aborts += 1;
    pending.url.decref(host.ops);
}

fn readArg(comptime T: type, call: eval.Interpreter.HostedCall, index: usize) T {
    const offset = call.arg_offsets[index];
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), call.args[offset..][0..@sizeOf(T)]);
    return value;
}

/// A fake hosted call's argument buffer, laid out as the interpreter lays
/// one out: each argument at its offset.
fn fakeCall(symbol: []const u8, args: []const u8, offsets: []const u32, ret: []u8) eval.Interpreter.HostedCall {
    return .{
        .symbol = symbol,
        .dispatch_index = 0,
        .args = args,
        .arg_layouts = &.{},
        .arg_offsets = offsets,
        .ret = ret,
        .ret_layout = .u32,
        .layouts = undefined,
    };
}

test "the test host answers a suspending call at once in ready mode and traces every call" {
    var runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
    defer runtime.deinit();
    const ops = runtime.get_ops();
    var host = TestHost.init(std.testing.allocator, ops, .ready);
    defer host.deinit();
    const handler = host.handler();

    var out: RocStr = RocStr.empty();
    const url = RocStr.fromSlice("https://example.com/a/long/enough/url", ops);
    var args: [2 * @sizeOf(usize) + @sizeOf(RocStr)]u8 = undefined;
    const task_addr: usize = 0;
    const out_addr: usize = @intFromPtr(&out);
    @memcpy(args[0..@sizeOf(usize)], std.mem.asBytes(&task_addr));
    @memcpy(args[@sizeOf(usize)..][0..@sizeOf(usize)], std.mem.asBytes(&out_addr));
    @memcpy(args[2 * @sizeOf(usize) ..][0..@sizeOf(RocStr)], std.mem.asBytes(&url));
    var ret: [4]u8 = undefined;
    try handler.dispatch(handler.context, fakeCall("roc_host_fetch", &args, &.{ 0, @sizeOf(usize), 2 * @sizeOf(usize) }, &ret));
    try std.testing.expectEqual(poll_ready, std.mem.readInt(u32, &ret, .little));
    try std.testing.expectEqualStrings("https://example.com/a/long/enough/url/body", out.asSlice());
    out.decref(ops);

    const text = RocStr.fromSlice("a note long enough to live on the heap", ops);
    var log_args: [@sizeOf(RocStr)]u8 = undefined;
    @memcpy(&log_args, std.mem.asBytes(&text));
    try handler.dispatch(handler.context, fakeCall("roc_host_log", &log_args, &.{0}, &ret));

    try std.testing.expectEqual(@as(usize, 2), host.trace.items.len);
    try std.testing.expectEqualStrings("fetch(https://example.com/a/long/enough/url)", host.trace.items[0]);
    try std.testing.expectEqualStrings("log(a note long enough to live on the heap)", host.trace.items[1]);
    try runtime.checkForLeaks();
}
