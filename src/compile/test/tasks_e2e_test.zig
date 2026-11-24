//! Milestone 1, end to end (design.md "What Implements It First"): a
//! program whose platform declares `concurrency: Tasks` and calls a
//! `suspending` hosted function compiles under `.lss` and runs on the
//! interpreter as a task. A host that pauses at every suspending call gives
//! the same result and the same hosted-call trace as a host that finishes
//! each at once, and neither leaves a live allocation. Cancelling before
//! the first resume, or at each pause before or after the host finishes the
//! operation, is a request the next resume carries out: it reports
//! `CANCELLED` and also leaves none.
//!
//! The program's root is the task entry the continuation pass builds: the
//! test calls it as a host calls a `provides` entry and drives the task it
//! returns.
//!
//! The same runs go through the LLVM and dev backends, loaded in this
//! process, with the host's C-ABI hosted functions (design.md "Backends"),
//! and through the wasm backend, in bytebox, with a host that keeps its
//! strings in the module's memory.

const std = @import("std");
const lir = @import("lir");
const eval = @import("eval");
const builtins = @import("builtins");

const harness = @import("lower_to_lir_harness.zig");
const static_data = @import("static_data");
const CoreCtx = @import("ctx").CoreCtx;
const task_test_host = @import("task_test_host.zig");

const RocStr = builtins.str.RocStr;
const WasmCodeGen = @import("backend").wasm.WasmCodeGen;
const wasm_runner = eval.wasm_runner;
const RocTask = builtins.task.RocTask;
const TestHost = task_test_host.TestHost;

const app_path = "test/postcheck/suspension_marks/app.roc";
const url = "https://example.com/a/path/long/enough/for/the/heap";
const expected_result = url ++ "/body" ++ url ++ "/body!";
const expected_trace = [_][]const u8{ "log(" ++ url ++ ")", "fetch(" ++ url ++ ")", "fetch(" ++ url ++ ")" };
/// `fetch_both!` calls `fetch!` twice, so the task pauses twice.
const pause_count = 2;

/// The URL a run passes to the root. The crash runs add a marker saying
/// where the program crashes.
var root_url: []const u8 = url;

/// Where the crash fixture crashes, chosen by a marker in its URL, and how
/// many fetches it makes first.
const CrashPoint = struct { marker: []const u8, message: []const u8, fetches: usize };
const crash_app_path = "test/postcheck/suspension_crash/app.roc";
const crash_points = [_]CrashPoint{
    .{ .marker = "#before", .message = "crashed before the first pause", .fetches = 0 },
    .{ .marker = "#between", .message = "crashed between the pauses", .fetches = 1 },
    .{ .marker = "#after", .message = "crashed after the last pause", .fetches = 2 },
};

/// The task's `roc_task_resume`, as a host links it.
const ResumeFn = task_test_host.ResumeFn;

const E2eError = std.mem.Allocator.Error || eval.LirInterpreter.Error || eval.RuntimeHostEnv.LeakError || error{ TestUnexpectedResult, TestExpectedEqual };

/// One interpreter over the lowered program, with the test host's handler.
const Run = struct {
    const Program = *const lir.CheckedPipeline.LoweredProgram;

    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    static_data: ?eval.InterpreterStaticData,
    static_strings: eval.LirInterpreter.StaticStrings.Table,
    interpreter: eval.LirInterpreter,

    fn init(self: *Run, lowered: Program, mode: task_test_host.Mode) E2eError!void {
        const program = &lowered.lir_result;
        self.runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
        const ops = self.runtime.get_ops();
        self.host = TestHost.init(std.testing.allocator, ops, mode);
        self.static_data = try harness.interpreterStaticData(lowered);
        self.static_strings = try eval.LirInterpreter.buildStaticStrings(std.testing.allocator, &program.store);
        self.interpreter = try eval.LirInterpreter.init(std.testing.allocator, &program.store, &program.layouts, self.static_strings.view(), ops);
        self.interpreter.hosted_call_handler = self.host.handler();
        if (self.static_data) |*data| {
            data.install(&self.interpreter);
            data.ownByInterpreter(&self.interpreter);
        }
    }

    fn deinit(self: *Run) void {
        self.interpreter.deinit();
        self.static_strings.deinit();
        if (self.static_data) |*data| data.deinit();
        self.host.deinit();
        self.runtime.deinit();
    }

    /// The interpreter's program defines no `roc_task_cancel`.
    fn cancelFn(_: Program) task_test_host.CancelFn {
        return &task_test_host.nativeCancel;
    }

    /// The interpreter runs on this process's runtime.
    fn resumeFn(_: Program) ResumeFn {
        return &task_test_host.nativeResume;
    }

    /// Make the root's task by calling the program's root, the task entry
    /// `E(url, result_out)` the continuation pass put in the root's place
    /// (design.md "Host Contract"): it creates the task, whose result goes
    /// to `result`, and returns it.
    fn startRoot(self: *Run, lowered: Program, result: *RocStr) E2eError!*RocTask {
        const program = &lowered.lir_result;
        const entry_id = program.root_procs.items[0];
        const entry = program.store.getProcSpec(entry_id);
        // The root returns the task, not the program's `Str`.
        try std.testing.expectEqual(@import("layout").Idx.opaque_ptr, entry.ret_layout);
        const ops = self.runtime.get_ops();
        const url_str = RocStr.fromSlice(root_url, ops);
        var entry_args = EntryArgs{ .url = url_str, .result_out = result };
        var task: *RocTask = undefined;
        _ = try self.interpreter.eval(.{
            .proc_id = entry_id,
            .arg_layouts = &.{ .str, .opaque_ptr },
            .ret_layout = entry.ret_layout,
            .arg_ptr = @ptrCast(&entry_args),
            .ret_ptr = @ptrCast(&task),
        });
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) url_str.decref(ops);
        return task;
    }
};

/// The program compiled by the LLVM backend and loaded in this process, its
/// hosted symbols bound to the test host's C-ABI functions.
const LlvmProgram = struct {
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    static_data: []static_data.StaticDataExport,
    image: eval.InspectedRun.LlvmImage,
    /// The program's `roc_task_wake`.
    wake: task_test_host.WakeFn,
    /// The program's `roc_task_cancel`.
    cancel: task_test_host.CancelFn,
    /// The program's `roc_task_resume` and `roc_task_free`, from the
    /// builtins it links privately, whose crash exits its own crashes
    /// reach and which keep its tasks' monitor state.
    resume_task: ResumeFn,
    free_task: task_test_host.FreeFn,

    fn init(self: *LlvmProgram, lowered: *const lir.CheckedPipeline.LoweredProgram) (eval.InspectedRun.LlvmError || error{MissingTaskCall})!void {
        self.lowered = lowered;
        self.static_data = try harness.nativeStaticData(lowered);
        errdefer harness.freeNativeStaticData(self.static_data);
        const program = &lowered.lir_result;
        self.image = try eval.InspectedRun.LlvmImage.load(std.testing.allocator, .{
            .store = &program.store,
            .layouts = &program.layouts,
            .erased_capture_prefix = program.erased_capture_prefix,
            .main_proc = program.root_procs.items[0],
            .static_data = self.static_data,
            .static_data_value_count = program.static_data_values.items.len,
        }, .{ .resolve = task_test_host.resolveCAbiSymbol });
        self.wake = self.image.lib.lookup(task_test_host.WakeFn, builtins.shim_symbols.roc_task_wake) orelse {
            self.image.deinit();
            return error.MissingTaskCall;
        };
        self.cancel = self.image.lib.lookup(task_test_host.CancelFn, builtins.shim_symbols.roc_task_cancel) orelse {
            self.image.deinit();
            return error.MissingTaskCall;
        };
        self.resume_task = self.image.lib.lookup(ResumeFn, builtins.shim_symbols.roc_task_resume) orelse {
            self.image.deinit();
            return error.MissingTaskCall;
        };
        self.free_task = self.image.lib.lookup(task_test_host.FreeFn, builtins.shim_symbols.roc_task_free) orelse {
            self.image.deinit();
            return error.MissingTaskCall;
        };
    }

    fn deinit(self: *LlvmProgram) void {
        self.image.deinit();
        harness.freeNativeStaticData(self.static_data);
    }
};

/// One run of the LLVM-compiled program, in this process: the runtime's ops
/// are entered for the builtins, and the test host serves the C-ABI hosted
/// calls.
const LlvmRun = struct {
    const Program = *const LlvmProgram;

    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    entered: builtins.in_process_host.Saved,

    fn init(self: *LlvmRun, program: Program, mode: task_test_host.Mode) E2eError!void {
        self.runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
        const ops = self.runtime.get_ops();
        self.host = TestHost.init(std.testing.allocator, ops, mode);
        // The host wakes, resumes and frees through the program's own task
        // calls.
        self.host.wake = program.wake;
        self.host.resume_task = program.resume_task;
        self.host.free_task = program.free_task;
        self.entered = builtins.in_process_host.enter(ops, null);
        self.host.enterCAbi();
        task_test_host.c_abi_failure = null;
    }

    fn deinit(self: *LlvmRun) void {
        self.host.leaveCAbi();
        builtins.in_process_host.leave(self.entered);
        self.host.deinit();
        self.runtime.deinit();
    }

    /// The program's own `roc_task_cancel`, which cancels with the test
    /// host's `roc_task_abort`.
    fn cancelFn(program: Program) task_test_host.CancelFn {
        return program.cancel;
    }

    fn resumeFn(program: Program) ResumeFn {
        return program.resume_task;
    }

    /// Make the root's task by calling the compiled task entry
    /// `E(url, result_out)` through its entrypoint wrapper.
    fn startRoot(self: *LlvmRun, program: Program, result: *RocStr) E2eError!*RocTask {
        const store = &program.lowered.lir_result.store;
        const entry = store.getProcSpec(program.lowered.lir_result.root_procs.items[0]);
        try std.testing.expectEqual(@import("layout").Idx.opaque_ptr, entry.ret_layout);
        const ops = self.runtime.get_ops();
        const url_str = RocStr.fromSlice(root_url, ops);
        var entry_args = EntryArgs{ .url = url_str, .result_out = result };
        var task: *RocTask = undefined;
        const call = program.image.entry() catch return error.TestUnexpectedResult;
        call(@ptrCast(&task), @ptrCast(&entry_args));
        if (task_test_host.c_abi_failure) |err| return err;
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) url_str.decref(ops);
        return task;
    }
};

/// The program compiled by the dev backend into this process, its hosted
/// symbols bound to the test host's C-ABI functions.
const DevProgram = struct {
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    static_data: []static_data.StaticDataExport,
    image: eval.InspectedRun.DevImage,

    fn init(self: *DevProgram, lowered: *const lir.CheckedPipeline.LoweredProgram) eval.InspectedRun.DevError!void {
        self.lowered = lowered;
        self.static_data = try harness.nativeStaticData(lowered);
        errdefer harness.freeNativeStaticData(self.static_data);
        const program = &lowered.lir_result;
        const resolver_context: u8 = 0;
        self.image = try eval.InspectedRun.DevImage.load(std.testing.allocator, .{
            .store = &program.store,
            .layouts = &program.layouts,
            .erased_capture_prefix = program.erased_capture_prefix,
            .main_proc = program.root_procs.items[0],
            .static_data = self.static_data,
            .static_data_value_count = program.static_data_values.items.len,
        }, .{ .context = &resolver_context, .resolve = resolveHostedSymbol });
    }

    fn deinit(self: *DevProgram) void {
        self.image.deinit();
        harness.freeNativeStaticData(self.static_data);
    }

    fn resolveHostedSymbol(_: *const anyopaque, name: []const u8) ?usize {
        return task_test_host.resolveCAbiSymbol(null, name);
    }
};

/// One run of the dev-compiled program, in this process, set up as an LLVM
/// run is.
const DevRun = struct {
    const Program = *const DevProgram;

    runtime: eval.RuntimeHostEnv,
    host: TestHost,
    entered: builtins.in_process_host.Saved,

    fn init(self: *DevRun, _: Program, mode: task_test_host.Mode) E2eError!void {
        self.runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
        const ops = self.runtime.get_ops();
        self.host = TestHost.init(std.testing.allocator, ops, mode);
        self.entered = builtins.in_process_host.enter(ops, null);
        self.host.enterCAbi();
        task_test_host.c_abi_failure = null;
    }

    fn deinit(self: *DevRun) void {
        self.host.leaveCAbi();
        builtins.in_process_host.leave(self.entered);
        self.host.deinit();
        self.runtime.deinit();
    }

    /// A dev image defines no `roc_task_cancel`: a dev shim build's comes
    /// with its generated platform shim (design.md "Backends").
    fn cancelFn(_: Program) task_test_host.CancelFn {
        return &task_test_host.nativeCancel;
    }

    /// A dev image loaded in this process calls this process's builtins.
    fn resumeFn(_: Program) ResumeFn {
        return &task_test_host.nativeResume;
    }

    /// Make the root's task by calling the compiled task entry
    /// `E(url, result_out)` through its entrypoint wrapper.
    fn startRoot(self: *DevRun, program: Program, result: *RocStr) E2eError!*RocTask {
        const store = &program.lowered.lir_result.store;
        const entry = store.getProcSpec(program.lowered.lir_result.root_procs.items[0]);
        try std.testing.expectEqual(@import("layout").Idx.opaque_ptr, entry.ret_layout);
        const ops = self.runtime.get_ops();
        const url_str = RocStr.fromSlice(root_url, ops);
        var entry_args = EntryArgs{ .url = url_str, .result_out = result };
        var task: *RocTask = undefined;
        program.image.entry()(@ptrCast(&task), @ptrCast(&entry_args));
        if (task_test_host.c_abi_failure) |err| return err;
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) url_str.decref(ops);
        return task;
    }
};

/// The program compiled by the wasm backend for wasm32 into one module that
/// exports the task entry beside the merged builtins' task calls, as a
/// wasm host links them (design.md "Backends").
const WasmProgram = struct {
    lowered: *const lir.CheckedPipeline.LoweredProgram,
    module: WasmCodeGen.EntrypointModule,

    fn init(self: *WasmProgram, lowered: *const lir.CheckedPipeline.LoweredProgram) eval.InspectedRun.WasmError!void {
        self.lowered = lowered;
        const data = try harness.nativeStaticData(lowered);
        defer harness.freeNativeStaticData(data);
        const program = &lowered.lir_result;
        const root = program.root_procs.items[0];
        self.module = try eval.InspectedRun.generateWasmEntrypointModule(std.testing.allocator, .{
            .store = &program.store,
            .layouts = &program.layouts,
            .erased_capture_prefix = program.erased_capture_prefix,
            .main_proc = root,
            .static_data = data,
            .static_data_value_count = program.static_data_values.items.len,
        }, &.{.{ .symbol_name = wasm_entry, .proc = root, .arg_layouts = &.{ .str, .opaque_ptr }, .ret_layout = .opaque_ptr }}, &task_calls, .default);
    }

    fn deinit(self: *WasmProgram) void {
        std.testing.allocator.free(self.module.wasm_bytes);
    }
};

/// The export the wasm module gives the task entry.
const wasm_entry = "roc_task_entry";
const task_calls = [_][]const u8{builtins.shim_symbols.roc_task_free};

/// The size of a wasm32 `Str`, and the tag a seamless slice's allocation
/// pointer carries.
const wasm_str_size = builtins.str.RocStr.word_count * 4;
const wasm_slice_tag = 1;

/// A hosted operation of a wasm run that the host has not finished.
const WasmPending = struct { task: u32, out: u32, url: [wasm_str_size]u8 };

/// The test host for the wasm-compiled program: `TestHost`'s behaviour over
/// the module's linear memory, where its strings live. Its hosted functions
/// are the module's `env` imports, with wasm32's C ABI: a `Str` argument is
/// the address of a copy the callee owns.
const WasmRun = struct {
    const Program = *const WasmProgram;

    session: wasm_runner.Session,
    mode: task_test_host.Mode,
    trace: std.ArrayList([]u8) = .empty,
    /// The operations not finished yet, oldest first: each one's task, its
    /// result slot, and its URL.
    pending: std.ArrayList(WasmPending) = .empty,
    pauses: u32 = 0,
    /// How many paused operations a cancel abandoned.
    aborts: u32 = 0,
    /// How many times a wake told the host a parked task is ready.
    readies: u32 = 0,
    /// As `TestHost`'s fields of these names, for `driveQueue`.
    queue_readies: bool = false,
    trace_steps: bool = false,
    ready_tasks: std.ArrayList(u32) = .empty,
    numbers: task_test_host.TaskNumbers(u32) = .{},
    /// The first error a hosted call hit, which it cannot return.
    failure: ?E2eError = null,

    fn init(self: *WasmRun, program: Program, mode: task_test_host.Mode) E2eError!void {
        self.* = .{ .session = undefined, .mode = mode };
        const fetch_params = [_]wasm_runner.ValType{ .I32, .I32, .I32 };
        const task_params = [_]wasm_runner.ValType{.I32};
        self.session.init(std.testing.allocator, program.module.wasm_bytes, program.module.heap_base, &.{
            .{ .name = "roc_host_fetch", .params = &fetch_params, .results = &.{.I32}, .callback = fetch, .context = self },
            .{ .name = "roc_host_log", .params = &task_params, .results = &.{}, .callback = log, .context = self },
            .{ .name = builtins.shim_symbols.roc_task_abort, .params = &task_params, .results = &.{}, .callback = abort, .context = self },
            .{ .name = builtins.shim_symbols.roc_task_ready, .params = &task_params, .results = &.{}, .callback = ready, .context = self },
        }) catch return error.TestUnexpectedResult;
    }

    fn deinit(self: *WasmRun) void {
        for (self.trace.items) |entry| std.testing.allocator.free(entry);
        self.trace.deinit(std.testing.allocator);
        self.pending.deinit(std.testing.allocator);
        self.ready_tasks.deinit(std.testing.allocator);
        self.numbers.deinit(std.testing.allocator);
        self.session.deinit();
    }

    fn mem(self: *WasmRun) []u8 {
        return self.session.memory();
    }

    fn readWord(self: *WasmRun, addr: u32) u32 {
        return std.mem.readInt(u32, self.mem()[addr..][0..4], .little);
    }

    fn writeWord(self: *WasmRun, addr: u32, value: u32) void {
        std.mem.writeInt(u32, self.mem()[addr..][0..4], value, .little);
    }

    /// A `Str` holding `text`, as Roc makes one: in place when it is small,
    /// and otherwise allocated, with its refcount of one in the word before
    /// its bytes.
    fn newStr(self: *WasmRun, text: []const u8, at: u32) void {
        if (text.len < wasm_str_size) {
            const str = self.mem()[at..][0..wasm_str_size];
            @memset(str, 0);
            @memcpy(str[0..text.len], text);
            str[wasm_str_size - 1] = @as(u8, @intCast(text.len)) | builtins.str.RocStr.small_str_flag;
            return;
        }
        const len: u32 = @intCast(text.len);
        const data = self.session.alloc(4, 4 + len);
        self.writeWord(data, 1);
        @memcpy(self.mem()[data + 4 ..][0..len], text);
        self.writeWord(at, data + 4);
        self.writeWord(at + 4, len << builtins.str.RocStr.capacity_shift);
        self.writeWord(at + 8, len);
    }

    /// Release the `Str` at `at`, as `RocStr.decref` does.
    fn decrefStr(self: *WasmRun, at: u32) void {
        self.decrefStrValue(self.mem()[at..][0..wasm_str_size].*);
    }

    /// Release the `Str` whose bytes are `str`.
    fn decrefStrValue(self: *WasmRun, str: [wasm_str_size]u8) void {
        if (str[wasm_str_size - 1] & builtins.str.RocStr.small_str_flag != 0) return;
        const cap = std.mem.readInt(u32, str[4..8], .little);
        const alloc = if (cap & wasm_slice_tag != 0) cap & ~@as(u32, wasm_slice_tag) else std.mem.readInt(u32, str[0..4], .little);
        const count = self.readWord(alloc - 4);
        switch (count) {
            0 => {},
            1 => {
                self.writeWord(alloc - 4, 0);
                self.session.free();
            },
            else => self.writeWord(alloc - 4, count - 1),
        }
    }

    fn note(self: *WasmRun, name: []const u8, str_addr: u32) E2eError!void {
        const text = wasm_runner.readWasmStr(self.mem(), str_addr) catch return error.TestUnexpectedResult;
        const entry = try std.fmt.allocPrint(std.testing.allocator, "{s}({s})", .{ name, text });
        errdefer std.testing.allocator.free(entry);
        try self.trace.append(std.testing.allocator, entry);
    }

    fn answer(self: *WasmRun, url_addr: u32, out: u32) E2eError!void {
        const url_text = wasm_runner.readWasmStr(self.mem(), url_addr) catch return error.TestUnexpectedResult;
        const text = try std.fmt.allocPrint(std.testing.allocator, "{s}/body", .{url_text});
        defer std.testing.allocator.free(text);
        self.newStr(text, out);
    }

    /// `u32 roc_host_fetch(RocTask *task, RocStr *out, RocStr *url)`.
    fn fetch(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const wasm_runner.Val, results: [*]wasm_runner.Val) error{}!void {
        const self: *WasmRun = @ptrCast(@alignCast(context));
        const task: u32 = @bitCast(params[0].I32);
        const out: u32 = @bitCast(params[1].I32);
        const url_addr: u32 = @bitCast(params[2].I32);
        results[0] = .{ .I32 = 0 };
        self.fetchOrFail(task, out, url_addr, &results[0]) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn fetchOrFail(self: *WasmRun, task: u32, out: u32, url_addr: u32, poll: *wasm_runner.Val) E2eError!void {
        try self.note("fetch", url_addr);
        switch (self.mode) {
            .ready => {
                try self.answer(url_addr, out);
                self.decrefStr(url_addr);
            },
            .pause => {
                // A task waits on at most one hosted operation at a time.
                for (self.pending.items) |pending| if (pending.task == task) return error.TestUnexpectedResult;
                try self.pending.append(std.testing.allocator, .{ .task = task, .out = out, .url = self.mem()[url_addr..][0..wasm_str_size].* });
                self.pauses += 1;
                poll.* = .{ .I32 = 1 };
            },
        }
    }

    /// `void roc_host_log(RocStr *text)`.
    fn log(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const wasm_runner.Val, _: [*]wasm_runner.Val) error{}!void {
        const self: *WasmRun = @ptrCast(@alignCast(context));
        const text: u32 = @bitCast(params[0].I32);
        self.note("log", text) catch |err| {
            if (self.failure == null) self.failure = err;
        };
        self.decrefStr(text);
    }

    /// `void roc_task_abort(RocTask *task)`: abandon its paused operation.
    fn abort(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const wasm_runner.Val, _: [*]wasm_runner.Val) error{}!void {
        const self: *WasmRun = @ptrCast(@alignCast(context));
        self.abandon(@bitCast(params[0].I32)) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn abandon(self: *WasmRun, task: u32) E2eError!void {
        const index = for (self.pending.items, 0..) |pending, i| {
            if (pending.task == task) break i;
        } else return error.TestUnexpectedResult;
        const pending = self.pending.orderedRemove(index);
        self.aborts += 1;
        self.decrefStrValue(pending.url);
        if (self.trace_steps) try self.noteStep("task {d} aborted", .{try self.numbers.of(std.testing.allocator, task)});
    }

    /// `void roc_task_ready(RocTask *task)`: a woken task was parked, or a
    /// task is new.
    fn ready(context: ?*anyopaque, _: *wasm_runner.ModuleInstance, params: [*]const wasm_runner.Val, _: [*]wasm_runner.Val) error{}!void {
        const self: *WasmRun = @ptrCast(@alignCast(context));
        self.readies += 1;
        if (!self.queue_readies) return;
        self.queueReady(@bitCast(params[0].I32)) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn queueReady(self: *WasmRun, task: u32) E2eError!void {
        _ = try self.numbers.of(std.testing.allocator, task);
        try self.ready_tasks.append(std.testing.allocator, task);
    }

    fn noteStep(self: *WasmRun, comptime format: []const u8, args: anytype) E2eError!void {
        const entry = try std.fmt.allocPrint(std.testing.allocator, format, args);
        errdefer std.testing.allocator.free(entry);
        try self.trace.append(std.testing.allocator, entry);
    }

    fn call(self: *WasmRun, name: []const u8, task: u32, returns: []wasm_runner.Val) E2eError!void {
        self.session.invoke(name, &.{.{ .I32 = @bitCast(task) }}, returns) catch return error.TestUnexpectedResult;
        if (self.failure) |err| return err;
    }

    fn resumeTask(self: *WasmRun, task: u32) E2eError!builtins.task.Status {
        var status: [1]wasm_runner.Val = undefined;
        try self.call(builtins.shim_symbols.roc_task_resume, task, &status);
        return @fromBackingInt(@intCast(status[0].I32));
    }

    /// Finish the oldest paused operation: write its result and wake its
    /// task.
    fn finish(self: *WasmRun) E2eError!void {
        const pending = self.pending.orderedRemove(0);
        // The URL goes back into memory the host owns while it answers.
        const url_addr = self.session.alloc(4, wasm_str_size);
        self.mem()[url_addr..][0..wasm_str_size].* = pending.url;
        try self.answer(url_addr, pending.out);
        self.session.free();
        self.decrefStrValue(pending.url);
        try self.call(builtins.shim_symbols.roc_task_wake, pending.task, &.{});
    }

    /// Run the task to its end, as `TestHost.drive` does.
    fn drive(self: *WasmRun, task: u32) E2eError!builtins.task.Status {
        var status = try self.resumeTask(task);
        while (status == .pending) {
            try self.finish();
            status = try self.resumeTask(task);
        }
        return status;
    }

    /// Run the tree of `root` under a queue, as `TestHost.driveQueue` does.
    fn driveQueue(self: *WasmRun, root: u32, cancel_after: ?u32) (E2eError || error{Stuck})!builtins.task.Status {
        self.queue_readies = true;
        self.trace_steps = true;
        defer {
            self.queue_readies = false;
            self.trace_steps = false;
        }
        if (cancel_after == 0) try self.call(builtins.shim_symbols.roc_task_cancel, root, &.{});
        var resumes: u32 = 0;
        var next = root;
        while (true) {
            const number = try self.numbers.of(std.testing.allocator, next);
            const status = try self.resumeTask(next);
            resumes += 1;
            try self.noteStep("task {d} resumed: {s}", .{ number, @tagName(status) });
            if (status != .pending) {
                if (next == root) return status;
                self.numbers.forget(next);
            }
            if (cancel_after == resumes) try self.call(builtins.shim_symbols.roc_task_cancel, root, &.{});
            while (self.ready_tasks.items.len == 0) {
                if (self.pending.items.len == 0) return error.Stuck;
                try self.finish();
            }
            next = self.ready_tasks.orderedRemove(0);
        }
    }

    /// Run the task until its `pause`th pause, then cancel it there with
    /// the program's `roc_task_cancel` and resume it once more, as
    /// `TestHost.driveAndCancel` does. Pause 0 cancels before the first
    /// resume. Returns the task's last status.
    fn driveAndCancel(self: *WasmRun, task: u32, pause: u32, woken: bool) E2eError!builtins.task.Status {
        if (pause == 0) {
            try self.call(builtins.shim_symbols.roc_task_cancel, task, &.{});
            return self.resumeTask(task);
        }
        var status = try self.resumeTask(task);
        var seen: u32 = 0;
        while (status == .pending) {
            seen += 1;
            if (seen == pause) {
                if (woken) try self.finish();
                try self.call(builtins.shim_symbols.roc_task_cancel, task, &.{});
                // Readied by the cancel, or by the wake before it.
                return self.resumeTask(task);
            }
            try self.finish();
            status = try self.resumeTask(task);
        }
        return status;
    }

    /// Call the task entry with the URL and the root result's storage, both
    /// in memory the host owns, and return the task.
    fn startRoot(self: *WasmRun, program: *const WasmProgram, result: u32) E2eError!u32 {
        const store = &program.lowered.lir_result.store;
        const entry = store.getProcSpec(program.lowered.lir_result.root_procs.items[0]);
        const url_addr = self.session.alloc(4, wasm_str_size);
        self.newStr(root_url, url_addr);
        var task: [1]wasm_runner.Val = undefined;
        self.session.invoke(wasm_entry, &.{ .{ .I32 = @bitCast(url_addr) }, .{ .I32 = @bitCast(result) } }, &task) catch return error.TestUnexpectedResult;
        if (self.failure) |err| return err;
        // A borrowed argument stays the caller's.
        if ((entry.rc_borrowed_params & 1) != 0) self.decrefStr(url_addr);
        self.session.free();
        return @bitCast(task[0].I32);
    }

    /// Storage for the root's result, which the host owns.
    fn resultStorage(self: *WasmRun) u32 {
        const result = self.session.alloc(4, wasm_str_size);
        @memset(self.mem()[result..][0..wasm_str_size], 0);
        return result;
    }
};

/// Run the wasm-compiled program to its end with a host in `mode`: the same
/// result, trace, and pauses as the interpreter's, and nothing live after.
fn runToEndWasm(program: *const WasmProgram, mode: task_test_host.Mode) E2eError!void {
    var run: WasmRun = undefined;
    try run.init(program, mode);
    defer run.deinit();
    const result = run.resultStorage();
    const task_addr = try run.startRoot(program, result);
    try std.testing.expectEqual(builtins.task.Status.done, try run.drive(task_addr));
    try run.call(builtins.shim_symbols.roc_task_free, task_addr, &.{});
    const got = wasm_runner.readWasmStr(run.mem(), result) catch return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected_result, got);
    run.decrefStr(result);
    run.session.free();
    try std.testing.expectEqual(expected_trace.len, run.trace.items.len);
    for (expected_trace, run.trace.items) |want, got_entry| try std.testing.expectEqualStrings(want, got_entry);
    try std.testing.expectEqual(@as(u32, if (mode == .pause) pause_count else 0), run.pauses);
    // Every pause parks the task, and each wake of a parked task readies it.
    try std.testing.expectEqual(run.pauses, run.readies);
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

/// Cancel the wasm-compiled program's task at its `pause`th pause through
/// the module's `roc_task_cancel` (0: before its first resume), before or
/// after the host finishes the operation, and resume it: it reports
/// `CANCELLED`, the host's `roc_task_abort` runs only for a parked task the
/// host had not finished, every pause was readied once, and nothing is
/// live after.
fn cancelAtWasm(program: *const WasmProgram, pause: u32, woken: bool) E2eError!void {
    var run: WasmRun = undefined;
    try run.init(program, .pause);
    defer run.deinit();
    const result = run.resultStorage();
    const task = try run.startRoot(program, result);
    try std.testing.expectEqual(builtins.task.Status.cancelled, try run.driveAndCancel(task, pause, woken));
    try run.call(builtins.shim_symbols.roc_task_free, task, &.{});
    run.session.free();
    try std.testing.expectEqual(@as(u32, if (woken or pause == 0) 0 else 1), run.aborts);
    try std.testing.expectEqual(pause, run.pauses);
    try std.testing.expectEqual(run.pauses, run.readies);
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
}

fn runAllWasm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: WasmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the Tasks program with the wasm backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    for ([_]task_test_host.Mode{ .ready, .pause }) |mode| {
        runToEndWasm(&program, mode) catch |err| {
            std.log.err("tasks end-to-end run on wasm ({s}) failed: {s}", .{ @tagName(mode), @errorName(err) });
            return error.TestUnexpectedResult;
        };
    }
    for (0..pause_count + 1) |pause| {
        for ([_]bool{ false, true }) |woken| {
            if (pause == 0 and woken) continue;
            cancelAtWasm(&program, @intCast(pause), woken) catch |err| {
                std.log.err("cancelling the wasm task at pause {d} (woken: {}) failed: {s}", .{ pause, woken, @errorName(err) });
                return error.TestUnexpectedResult;
            };
        }
    }
}

/// The task entry's arguments, laid out as the entrypoint ABI lays them out.
const EntryArgs = extern struct { url: RocStr, result_out: *RocStr };

fn expectTrace(host: *const TestHost) E2eError!void {
    try std.testing.expectEqual(expected_trace.len, host.trace.items.len);
    for (expected_trace, host.trace.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

fn runToEnd(comptime R: type, program: R.Program, mode: task_test_host.Mode) E2eError!void {
    var run: R = undefined;
    try run.init(program, mode);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    try std.testing.expectEqual(builtins.task.Status.done, try run.host.drive(task));
    run.host.freeTask(task);
    try std.testing.expectEqualStrings(expected_result, result.asSlice());
    result.decref(run.runtime.get_ops());
    try expectTrace(&run.host);
    try std.testing.expectEqual(@as(u32, if (mode == .pause) pause_count else 0), run.host.pauses);
    // Every pause parks the task, and each wake of a parked task readies it.
    try std.testing.expectEqual(run.host.pauses, run.host.readies);
    try run.runtime.checkForLeaks();
}

fn cancelAt(comptime R: type, program: R.Program, pause: u32, woken: bool) E2eError!void {
    var run: R = undefined;
    try run.init(program, .pause);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    try std.testing.expectEqual(builtins.task.Status.cancelled, try run.host.driveAndCancel(task, pause, woken, R.cancelFn(program)));
    run.host.freeTask(task);
    try std.testing.expectEqual(@as(u32, if (woken or pause == 0) 0 else 1), run.host.aborts);
    try std.testing.expectEqual(pause, run.host.pauses);
    try std.testing.expectEqual(run.host.pauses, run.host.readies);
    try run.runtime.checkForLeaks();
}

/// Crash at `point`: the task reports `CRASHED` with the program's message,
/// no hosted call follows the crash, and freeing the task releases exactly
/// the runtime's own allocations. The records were released by the crash
/// (task.zig's tests count them); what the crashed frames owned stays live.
fn crashAt(comptime R: type, program: R.Program, point: CrashPoint) E2eError!void {
    const marked_url = try std.mem.concat(std.testing.allocator, u8, &.{ url, point.marker });
    defer std.testing.allocator.free(marked_url);
    root_url = marked_url;
    defer root_url = url;
    var run: R = undefined;
    try run.init(program, .pause);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    const resume_task = R.resumeFn(program);
    var status = resume_task(task);
    while (status == @backingInt(builtins.task.Status.pending)) {
        try run.host.finish();
        status = resume_task(task);
    }
    try std.testing.expectEqual(@as(u32, @backingInt(builtins.task.Status.crashed)), status);
    try std.testing.expectEqualStrings(point.message, task.crash_message[0..task.crash_message_len]);

    try std.testing.expectEqual(1 + point.fetches, run.host.trace.items.len);
    const log_line = try std.fmt.allocPrint(std.testing.allocator, "log({s})", .{marked_url});
    defer std.testing.allocator.free(log_line);
    try std.testing.expectEqualStrings(log_line, run.host.trace.items[0]);

    const own: usize = @as(usize, 2) + @intFromBool(task.hosted_slot_size > 0) + @intFromBool(task.result_buffer_size > 0) + @intFromBool(task.capacity > 0) + task.cachedRecordCount();
    const live = run.runtime.live_count;
    run.host.freeTask(task);
    try std.testing.expectEqual(live - own, run.runtime.live_count);
    if (task_test_host.c_abi_failure) |err| return err;

    // The crash leaves the runtime usable: a task started after it on the
    // same run finishes.
    root_url = url;
    var next_result: RocStr = RocStr.empty();
    const next = try run.startRoot(program, &next_result);
    status = resume_task(next);
    while (status == @backingInt(builtins.task.Status.pending)) {
        try run.host.finish();
        status = resume_task(next);
    }
    try std.testing.expectEqual(@as(u32, @backingInt(builtins.task.Status.done)), status);
    try std.testing.expect(std.mem.endsWith(u8, next_result.asSlice(), "!"));
    run.host.freeTask(next);
    next_result.decref(run.runtime.get_ops());
    if (task_test_host.c_abi_failure) |err| return err;
}

fn checkCrashes(comptime R: type, program: R.Program) E2eError!void {
    for (crash_points) |point| crashAt(R, program, point) catch |err| {
        std.log.err("crashing {s} failed: {s}", .{ point.marker, @errorName(err) });
        return err;
    };
}

fn crashAll(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    checkCrashes(Run, lowered) catch return error.TestUnexpectedResult;
}

fn crashAllLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the crashing Tasks program with LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    checkCrashes(LlvmRun, &program) catch return error.TestUnexpectedResult;
}

fn crashAllDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the crashing Tasks program with the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    checkCrashes(DevRun, &program) catch return error.TestUnexpectedResult;
}

fn runAll(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    checkAll(Run, lowered) catch |err| {
        std.log.err("tasks end-to-end run failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn checkAll(comptime R: type, program: R.Program) E2eError!void {
    try runToEnd(R, program, .ready);
    try runToEnd(R, program, .pause);
    for (0..pause_count + 1) |pause| {
        for ([_]bool{ false, true }) |woken| {
            if (pause == 0 and woken) continue;
            try cancelAt(R, program, @intCast(pause), woken);
        }
    }
    if (task_test_host.c_abi_failure) |err| return err;
}

fn runAllLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the Tasks program with LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    // A host links its task calls from the program it runs.
    for ([_][]const u8{ builtins.shim_symbols.roc_task_resume, builtins.shim_symbols.roc_task_wake, builtins.shim_symbols.roc_task_free, builtins.shim_symbols.roc_task_cancel }) |name| {
        if (program.image.lib.lookup(*const anyopaque, name) == null) {
            std.log.err("the LLVM-compiled Tasks program does not export {s}", .{name});
            return error.TestUnexpectedResult;
        }
    }
    checkAll(LlvmRun, &program) catch |err| {
        std.log.err("tasks end-to-end run on LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn runAllDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the Tasks program with the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    checkAll(DevRun, &program) catch |err| {
        std.log.err("tasks end-to-end run on the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

test "a Tasks program pauses at every suspending call and gives the same result with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAll);
}

test "a Tasks program compiled by LLVM pauses and cancels as it does on the interpreter, with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAllLlvm);
}

test "a Tasks program compiled by the dev backend pauses and cancels as it does on the interpreter, with no leaks" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, runAllDev);
}

test "a Tasks program compiled by the wasm backend pauses and cancels as it does on the interpreter, with no leaks" {
    try harness.runAppPathLoweredInspection(app_path, .{ .specialization_strategy = .lss, .target_usize = .u32 }, runAllWasm);
}

test "a crash inside a Tasks program ends its task with CRASHED and its message, before, between and after its pauses" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (!builtins.task_crash_exit.available()) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(crash_app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, crashAll);
}

test "a crash inside a Tasks program compiled by LLVM ends its task as it does on the interpreter" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (!builtins.task_crash_exit.available()) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(crash_app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, crashAllLlvm);
}

test "a crash inside a Tasks program compiled by the dev backend ends its task as it does on the interpreter" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (!builtins.task_crash_exit.available()) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(crash_app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, crashAllDev);
}

/// A call that pauses returns a `Try` its caller reads only after the
/// operation finished, so nothing may look at the poison value the pause
/// left in its place.
const tag_result_app_path = "test/postcheck/suspension_tag_result/app.roc";

fn runTagResult(comptime R: type, program: R.Program, mode: task_test_host.Mode) E2eError!void {
    var run: R = undefined;
    try run.init(program, mode);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    try std.testing.expectEqual(builtins.task.Status.done, try run.host.drive(task));
    run.host.freeTask(task);
    if (task_test_host.c_abi_failure) |err| return err;
    try std.testing.expectEqualStrings(url ++ "/body!", result.asSlice());
    result.decref(run.runtime.get_ops());
    try std.testing.expectEqual(@as(u32, if (mode == .pause) 1 else 0), run.host.pauses);
    try std.testing.expectEqual(@as(usize, 1), run.host.trace.items.len);
    try std.testing.expectEqualStrings("fetch(" ++ url ++ ")", run.host.trace.items[0]);
    try run.runtime.checkForLeaks();
}

fn checkTagResult(comptime R: type, program: R.Program) E2eError!void {
    for ([_]task_test_host.Mode{ .ready, .pause }) |mode| {
        runTagResult(R, program, mode) catch |err| {
            std.log.err("the paused call's tag-union result ({s}) failed: {s}", .{ @tagName(mode), @errorName(err) });
            return err;
        };
    }
}

fn tagResultInterpreter(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    checkTagResult(Run, lowered) catch return error.TestUnexpectedResult;
}

fn tagResultDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch return error.TestUnexpectedResult;
    defer program.deinit();
    checkTagResult(DevRun, &program) catch return error.TestUnexpectedResult;
}

fn tagResultLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch return error.TestUnexpectedResult;
    defer program.deinit();
    checkTagResult(LlvmRun, &program) catch return error.TestUnexpectedResult;
}

test "a pausing call may return a tag union, on the interpreter" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(tag_result_app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, tagResultInterpreter);
}

test "a pausing call may return a tag union, on the dev backend" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(tag_result_app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, tagResultDev);
}

test "a pausing call may return a tag union, on LLVM" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(tag_result_app_path, .{ .specialization_strategy = .lss, .target_usize = .u64 }, tagResultLlvm);
}

// Sequential equivalence (design.md "Sequential equivalence"): a program's
// concurrent loops give the same result and make the same hosted calls in
// the same order when their entries run as child tasks, on a host that
// finishes every hosted call in place and resumes the ready task first in the
// task tree, as a `None` build of the same program gives without tasks.

const plan_loop_tasks_path = "test/postcheck/plan_loops_tasks/app.roc";
const plan_loop_none_path = "test/postcheck/plan_loops_none/app.roc";
const plan_loop_cases = [_][]const u8{
    "basic", "limits", "spawn", "background", "break", "return", "try", "nested", "children", "after_break", "supervise",
};

/// What a run of one case gave: its result, and the hosted calls it made.
const CaseOutcome = struct {
    result: []u8,
    trace: [][]u8,

    fn init(result: []const u8, trace: []const []const u8) std.mem.Allocator.Error!CaseOutcome {
        const gpa = std.testing.allocator;
        const result_copy = try gpa.dupe(u8, result);
        errdefer gpa.free(result_copy);
        const entries = try gpa.alloc([]u8, trace.len);
        var made: usize = 0;
        errdefer {
            for (entries[0..made]) |entry| gpa.free(entry);
            gpa.free(entries);
        }
        for (trace, entries) |entry, *copy| {
            copy.* = try gpa.dupe(u8, entry);
            made += 1;
        }
        return .{ .result = result_copy, .trace = entries };
    }

    fn deinit(self: CaseOutcome) void {
        const gpa = std.testing.allocator;
        for (self.trace) |entry| gpa.free(entry);
        gpa.free(self.trace);
        gpa.free(self.result);
    }
};

/// The outcomes of the `None` build, which `recordNoneOutcomes` fills and the
/// Tasks runs compare with. Tests run one at a time.
var none_outcomes: ?[plan_loop_cases.len]CaseOutcome = null;

fn freeNoneOutcomes() void {
    const outcomes = none_outcomes orelse return;
    for (outcomes) |outcome| outcome.deinit();
    none_outcomes = null;
}

/// The host of the `None` build on the interpreter: the same calls, all
/// answered in place, with no task to park.
const NoneHost = struct {
    ops: *builtins.host_abi.RocOps,
    trace: std.ArrayList([]u8) = .empty,

    fn deinit(self: *NoneHost) void {
        for (self.trace.items) |entry| std.testing.allocator.free(entry);
        self.trace.deinit(std.testing.allocator);
    }

    fn handler(self: *NoneHost) eval.Interpreter.HostedCallHandler {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(context: *anyopaque, call: eval.Interpreter.HostedCall) eval.Interpreter.Error!void {
        const self: *NoneHost = @ptrCast(@alignCast(context));
        var arg: RocStr = undefined;
        @memcpy(std.mem.asBytes(&arg), call.args[call.arg_offsets[0]..][0..@sizeOf(RocStr)]);
        const gpa = std.testing.allocator;
        if (std.mem.eql(u8, call.symbol, "roc_host_fetch")) {
            self.note("fetch", arg) catch return error.OutOfMemory;
            const text = std.fmt.allocPrint(gpa, "{s}/body", .{arg.asSlice()}) catch return error.OutOfMemory;
            defer gpa.free(text);
            const result = RocStr.fromSlice(text, self.ops);
            @memcpy(call.ret[0..@sizeOf(RocStr)], std.mem.asBytes(&result));
        } else if (std.mem.eql(u8, call.symbol, "roc_host_log")) {
            self.note("log", arg) catch return error.OutOfMemory;
        } else {
            return error.UnsupportedHostedFunction;
        }
        arg.decref(self.ops);
    }

    fn note(self: *NoneHost, name: []const u8, arg: RocStr) std.mem.Allocator.Error!void {
        const gpa = std.testing.allocator;
        const entry = try std.fmt.allocPrint(gpa, "{s}({s})", .{ name, arg.asSlice() });
        errdefer gpa.free(entry);
        try self.trace.append(gpa, entry);
    }
};

/// Run each case of the `None` build and record what it gives.
fn recordNoneOutcomes(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    recordNone(lowered) catch |err| {
        std.log.err("the None build of the plan loops failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn recordNone(lowered: *const lir.CheckedPipeline.LoweredProgram) E2eError!void {
    var outcomes: [plan_loop_cases.len]CaseOutcome = undefined;
    for (plan_loop_cases, 0..) |name, index| {
        outcomes[index] = noneCase(lowered, name) catch |err| {
            std.log.err("the None build's case {s} failed: {s}", .{ name, @errorName(err) });
            for (outcomes[0..index]) |outcome| outcome.deinit();
            return err;
        };
    }
    none_outcomes = outcomes;
}

fn noneCase(lowered: *const lir.CheckedPipeline.LoweredProgram, name: []const u8) E2eError!CaseOutcome {
    const program = &lowered.lir_result;
    var runtime = eval.RuntimeHostEnv.init(std.testing.allocator);
    defer runtime.deinit();
    const ops = runtime.get_ops();
    var host = NoneHost{ .ops = ops };
    defer host.deinit();
    var data = try harness.interpreterStaticData(lowered);
    defer if (data) |*static| static.deinit();
    var strings = try eval.LirInterpreter.buildStaticStrings(std.testing.allocator, &program.store);
    defer strings.deinit();
    var interpreter = try eval.LirInterpreter.init(std.testing.allocator, &program.store, &program.layouts, strings.view(), ops);
    defer interpreter.deinit();
    interpreter.hosted_call_handler = host.handler();
    if (data) |*static| {
        static.install(&interpreter);
        static.ownByInterpreter(&interpreter);
    }
    const entry_id = program.root_procs.items[0];
    const entry = program.store.getProcSpec(entry_id);
    try std.testing.expectEqual(@import("layout").Idx.str, entry.ret_layout);
    var arg = RocStr.fromSlice(name, ops);
    var result: RocStr = RocStr.empty();
    _ = try interpreter.eval(.{
        .proc_id = entry_id,
        .arg_layouts = &.{.str},
        .ret_layout = entry.ret_layout,
        .arg_ptr = @ptrCast(&arg),
        .ret_ptr = @ptrCast(&result),
    });
    if ((entry.rc_borrowed_params & 1) != 0) arg.decref(ops);
    const outcome = try CaseOutcome.init(result.asSlice(), host.trace.items);
    errdefer outcome.deinit();
    result.decref(ops);
    try runtime.checkForLeaks();
    return outcome;
}

/// Run each case of the Tasks build under the coroutine schedule and compare
/// it with the `None` build's outcome.
fn compareCoroutineRuns(comptime R: type, program: R.Program) E2eError!void {
    const want_all = none_outcomes orelse return error.TestUnexpectedResult;
    for (plan_loop_cases, want_all) |name, want| {
        const got = coroutineCase(R, program, name) catch |err| {
            std.log.err("the Tasks build's case {s} failed: {s}", .{ name, @errorName(err) });
            return err;
        };
        defer got.deinit();
        errdefer std.log.err("the Tasks build's case {s} differs from the None build's", .{name});
        try std.testing.expectEqualStrings(want.result, got.result);
        try std.testing.expectEqual(want.trace.len, got.trace.len);
        for (want.trace, got.trace) |want_entry, got_entry| try std.testing.expectEqualStrings(want_entry, got_entry);
    }
}

fn coroutineCase(comptime R: type, program: R.Program, name: []const u8) E2eError!CaseOutcome {
    root_url = name;
    defer root_url = url;
    var run: R = undefined;
    try run.init(program, .ready);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    const status = run.host.driveTree(task) catch |err| {
        std.log.err("{s}: no task is ready: {s}", .{ name, @errorName(err) });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(builtins.task.Status.done, status);
    run.host.freeTask(task);
    if (task_test_host.c_abi_failure) |err| return err;
    const outcome = try CaseOutcome.init(result.asSlice(), run.host.trace.items);
    errdefer outcome.deinit();
    result.decref(run.runtime.get_ops());
    try run.runtime.checkForLeaks();
    return outcome;
}

fn compareInterpreter(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    compareCoroutineRuns(Run, lowered) catch return error.TestUnexpectedResult;
}

fn compareDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the plan loops with the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    compareCoroutineRuns(DevRun, &program) catch return error.TestUnexpectedResult;
}

fn compareLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the plan loops with LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    compareCoroutineRuns(LlvmRun, &program) catch return error.TestUnexpectedResult;
}

const plan_loop_options: harness.LirLoweringOptions = .{ .specialization_strategy = .lss, .target_usize = .u64 };

/// Both builds lower the same program: the twin platforms differ only in
/// declaring tasks and marking `fetch!` suspending.
fn expectTwinApps() E2eError!void {
    const gpa = std.testing.allocator;
    const tasks_app = try readFixture(gpa, plan_loop_tasks_path);
    defer gpa.free(tasks_app);
    const none_app = try readFixture(gpa, plan_loop_none_path);
    defer gpa.free(none_app);
    try std.testing.expectEqualStrings(tasks_app, none_app);
}

fn readFixture(gpa: std.mem.Allocator, path: []const u8) E2eError![]u8 {
    return CoreCtx.os(gpa, gpa, std.testing.io).readFile(path, gpa) catch return error.TestUnexpectedResult;
}

fn checkSequentialEquivalence(inspect: harness.LoweredInspectFn) E2eError!void {
    try expectTwinApps();
    defer freeNoneOutcomes();
    harness.runAppPathLoweredInspection(plan_loop_none_path, plan_loop_options, recordNoneOutcomes) catch return error.TestUnexpectedResult;
    harness.runAppPathLoweredInspection(plan_loop_tasks_path, plan_loop_options, inspect) catch return error.TestUnexpectedResult;
}

test "concurrent loops run on child tasks as a None build runs them, on the interpreter" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try checkSequentialEquivalence(compareInterpreter);
}

test "concurrent loops run on child tasks as a None build runs them, on the dev backend" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try checkSequentialEquivalence(compareDev);
}

test "concurrent loops run on child tasks as a None build runs them, on LLVM" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try checkSequentialEquivalence(compareLlvm);
}

// The queue schedule: every backend runs the same program through the same
// steps. The host answers in place or pauses every fetch, resumes tasks in
// the order it was given them, and may cancel the root after any resume. A
// run's trace records each hosted call, resume and abort, so a backend that
// parks, reports, cancels or frees a task at another point differs from the
// interpreter there.

/// One run under the queue: the case, whether fetches pause, and after how
/// many resumes the root is cancelled, if it is.
const QueueRun = struct {
    name: []const u8,
    mode: task_test_host.Mode,
    cancel_after: ?u32,
    outcome: CaseOutcome,
};

/// The interpreter's queue runs, which `recordQueueRuns` fills and the other
/// backends' runs compare with. Tests run one at a time.
var queue_runs: std.ArrayList(QueueRun) = .empty;

fn freeQueueRuns() void {
    for (queue_runs.items) |run| run.outcome.deinit();
    queue_runs.deinit(std.testing.allocator);
    queue_runs = .empty;
}

/// Make the interpreter's runs: each case in each mode to its end, and then
/// cancelled after each number of resumes up to that end.
fn recordQueueRuns(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    recordQueue(lowered) catch |err| {
        std.log.err("a queue run on the interpreter failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn recordQueue(lowered: *const lir.CheckedPipeline.LoweredProgram) E2eError!void {
    for (plan_loop_cases) |name| {
        for ([_]task_test_host.Mode{ .ready, .pause }) |mode| {
            const resumes = try recordQueueRun(lowered, name, mode, null);
            var cancel_after: u32 = 0;
            while (cancel_after < resumes) : (cancel_after += 1) {
                _ = try recordQueueRun(lowered, name, mode, cancel_after);
            }
        }
    }
}

/// Record one run, and return how many resumes it made.
fn recordQueueRun(lowered: *const lir.CheckedPipeline.LoweredProgram, name: []const u8, mode: task_test_host.Mode, cancel_after: ?u32) E2eError!u32 {
    errdefer std.log.err("queue run {s}, {s}, cancelled after {?d}", .{ name, @tagName(mode), cancel_after });
    const outcome = try queueCase(Run, lowered, name, mode, cancel_after);
    errdefer outcome.deinit();
    try queue_runs.append(std.testing.allocator, .{ .name = name, .mode = mode, .cancel_after = cancel_after, .outcome = outcome });
    var resumes: u32 = 0;
    for (outcome.trace) |entry| resumes += @intFromBool(std.mem.find(u8, entry, " resumed: ") != null);
    return resumes;
}

fn queueCase(comptime R: type, program: R.Program, name: []const u8, mode: task_test_host.Mode, cancel_after: ?u32) E2eError!CaseOutcome {
    root_url = name;
    defer root_url = url;
    var run: R = undefined;
    try run.init(program, mode);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    const cancel: ?task_test_host.CancelAfter = if (cancel_after) |resumes| .{ .resumes = resumes, .cancel = R.cancelFn(program) } else null;
    const status = run.host.driveQueue(task, cancel) catch |err| switch (err) {
        error.Stuck => return error.TestUnexpectedResult,
        else => |other| return other,
    };
    run.host.freeTask(task);
    if (task_test_host.c_abi_failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 0), run.host.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), run.host.ready_tasks.items.len);
    // Only a cancel keeps a root from its result, whose storage nothing may
    // read then (P8).
    const done = status == .done;
    try std.testing.expect(done or (status == .cancelled and cancel_after != null));
    const outcome = try CaseOutcome.init(if (done) result.asSlice() else "", run.host.trace.items);
    errdefer outcome.deinit();
    if (done) result.decref(run.runtime.get_ops());
    try run.runtime.checkForLeaks();
    return outcome;
}

fn queueCaseWasm(program: *const WasmProgram, name: []const u8, mode: task_test_host.Mode, cancel_after: ?u32) E2eError!CaseOutcome {
    root_url = name;
    defer root_url = url;
    var run: WasmRun = undefined;
    try run.init(program, mode);
    defer run.deinit();
    const result = run.resultStorage();
    const task = try run.startRoot(program, result);
    const status = run.driveQueue(task, cancel_after) catch |err| switch (err) {
        error.Stuck => return error.TestUnexpectedResult,
        else => |other| return other,
    };
    try run.call(builtins.shim_symbols.roc_task_free, task, &.{});
    // The trace ends with the root's status, so both sides agree on it.
    const done = status == .done;
    const text = if (done) wasm_runner.readWasmStr(run.mem(), result) catch return error.TestUnexpectedResult else "";
    const outcome = try CaseOutcome.init(text, run.trace.items);
    errdefer outcome.deinit();
    if (done) run.decrefStr(result);
    run.session.free();
    try std.testing.expectEqual(@as(i64, 0), run.session.liveAllocations());
    return outcome;
}

fn expectQueueOutcome(want: QueueRun, got: CaseOutcome) E2eError!void {
    try std.testing.expectEqualStrings(want.outcome.result, got.result);
    for (want.outcome.trace, 0..) |entry, i| {
        if (i < got.trace.len) try std.testing.expectEqualStrings(entry, got.trace[i]);
    }
    try std.testing.expectEqual(want.outcome.trace.len, got.trace.len);
}

fn compareQueueRuns(comptime R: type, program: R.Program) E2eError!void {
    for (queue_runs.items) |want| {
        errdefer std.log.err("queue run {s}, {s}, cancelled after {?d}, differs from the interpreter's", .{ want.name, @tagName(want.mode), want.cancel_after });
        const got = try queueCase(R, program, want.name, want.mode, want.cancel_after);
        defer got.deinit();
        try expectQueueOutcome(want, got);
    }
}

fn compareQueueDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the plan loops with the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    compareQueueRuns(DevRun, &program) catch return error.TestUnexpectedResult;
}

fn compareQueueLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the plan loops with LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    compareQueueRuns(LlvmRun, &program) catch return error.TestUnexpectedResult;
}

fn compareQueueWasm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: WasmProgram = undefined;
    program.init(lowered) catch |err| {
        std.log.err("compiling the plan loops with the wasm backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer program.deinit();
    for (queue_runs.items) |want| {
        compareQueueRunWasm(&program, want) catch |err| {
            std.log.err("queue run {s}, {s}, cancelled after {?d}, on wasm differs from the interpreter's: {s}", .{ want.name, @tagName(want.mode), want.cancel_after, @errorName(err) });
            return error.TestUnexpectedResult;
        };
    }
}

fn compareQueueRunWasm(program: *const WasmProgram, want: QueueRun) E2eError!void {
    const got = try queueCaseWasm(program, want.name, want.mode, want.cancel_after);
    defer got.deinit();
    try expectQueueOutcome(want, got);
}

fn checkQueueRuns(options: harness.LirLoweringOptions, inspect: harness.LoweredInspectFn) E2eError!void {
    defer freeQueueRuns();
    harness.runAppPathLoweredInspection(plan_loop_tasks_path, plan_loop_options, recordQueueRuns) catch return error.TestUnexpectedResult;
    harness.runAppPathLoweredInspection(plan_loop_tasks_path, options, inspect) catch return error.TestUnexpectedResult;
}

test "concurrent loops take the interpreter's steps under a queue, cancelled after any resume, on the dev backend" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try checkQueueRuns(plan_loop_options, compareQueueDev);
}

test "concurrent loops take the interpreter's steps under a queue, cancelled after any resume, on LLVM" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try checkQueueRuns(plan_loop_options, compareQueueLlvm);
}

test "concurrent loops take the interpreter's steps under a queue, cancelled after any resume, on the wasm backend" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try checkQueueRuns(.{ .specialization_strategy = .lss, .target_usize = .u32 }, compareQueueWasm);
}

// Supervision (design.md "Plans And Concurrent Loops", "Supervision."): every
// run of the function crashes, so the inner `supervise!` runs it three times,
// the outer one runs that twice, and the last crash is the root's.

fn superviseCrash(comptime R: type, program: R.Program) E2eError!void {
    root_url = "supervise_crash";
    defer root_url = url;
    var run: R = undefined;
    try run.init(program, .ready);
    defer run.deinit();
    var result: RocStr = RocStr.empty();
    const task = try run.startRoot(program, &result);
    const status = run.host.driveTree(task) catch return error.TestUnexpectedResult;
    try std.testing.expectEqual(builtins.task.Status.crashed, status);
    try std.testing.expectEqualStrings("the run crashed", task.crash_message[0..task.crash_message_len]);
    run.host.freeTask(task);
    if (task_test_host.c_abi_failure) |err| return err;

    const one_run = [_][]const u8{ "log(run)", "log(start x)", "fetch(x)", "log(finish x)" };
    const inner = [_][]const u8{"log(outer)"} ++ one_run ++ one_run ++ one_run;
    const want = [_][]const u8{"log(begin supervise_crash)"} ++ inner ++ inner;
    try std.testing.expectEqual(want.len, run.host.trace.items.len);
    for (want, run.host.trace.items) |want_entry, got_entry| try std.testing.expectEqualStrings(want_entry, got_entry);
    // Nothing a crashing frame held was on the heap, so nothing leaks.
    try run.runtime.checkForLeaks();
}

fn superviseCrashInterpreter(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    superviseCrash(Run, lowered) catch |err| {
        std.log.err("supervising on the interpreter failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn superviseCrashDev(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: DevProgram = undefined;
    program.init(lowered) catch return error.TestUnexpectedResult;
    defer program.deinit();
    superviseCrash(DevRun, &program) catch |err| {
        std.log.err("supervising on the dev backend failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

fn superviseCrashLlvm(lowered: *const lir.CheckedPipeline.LoweredProgram) harness.LowerToLirHarnessError!void {
    var program: LlvmProgram = undefined;
    program.init(lowered) catch return error.TestUnexpectedResult;
    defer program.deinit();
    superviseCrash(LlvmRun, &program) catch |err| {
        std.log.err("supervising on LLVM failed: {s}", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
}

test "supervise! restarts a crashing function up to its limit and then crashes with its message, on the interpreter" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(plan_loop_tasks_path, plan_loop_options, superviseCrashInterpreter);
}

test "supervise! restarts a crashing function up to its limit and then crashes with its message, on the dev backend" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    if (comptime !@import("backend").host_lir_codegen_available) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(plan_loop_tasks_path, plan_loop_options, superviseCrashDev);
}

test "supervise! restarts a crashing function up to its limit and then crashes with its message, on LLVM" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try harness.runAppPathLoweredInspection(plan_loop_tasks_path, plan_loop_options, superviseCrashLlvm);
}
