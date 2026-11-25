//! Warnings about uses of shared state that a value or an earlier step should
//! replace (design.md "Shared State", "Warnings."). They read the checked module
//! and change nothing in it.

const std = @import("std");
const base = @import("base");
const can = @import("can");
const collections = @import("collections");

const CIR = can.CIR;
const Allocator = std.mem.Allocator;
const Region = base.Region;

/// The function of `Shared` that a call calls.
pub const Operation = enum { new, update, get, modify, finally, on_failure };

/// A call, with the receiver of a method call as its first argument.
const Call = struct {
    operation: ?Operation,
    effectful: bool,
    receiver: ?CIR.Expr.Idx,
    args: []const CIR.Expr.Idx,

    fn arg(self: Call, index: usize) ?CIR.Expr.Idx {
        const receiver = self.receiver orelse
            return if (index < self.args.len) self.args[index] else null;
        if (index == 0) return receiver;
        return if (index - 1 < self.args.len) self.args[index - 1] else null;
    }
};

/// The binding of a handle that a name with a fixed value is bound to.
const Handle = CIR.Pattern.Idx;

/// Report the warnings of every definition. `checker` supplies the checked
/// module (`cir`), the visitors of its children, what a call calls
/// (`sharedOperation`, `callIsEffectful`), and where problems go (`problems`).
pub fn report(gpa: Allocator, checker: anytype) Allocator.Error!void {
    var bodies = Bodies(@TypeOf(checker)){ .gpa = gpa, .checker = checker };
    defer bodies.deinit();
    for (checker.cir.store.sliceDefs(checker.cir.all_defs)) |def| {
        try bodies.scan(checker.cir.store.getDef(def).expr);
    }
    try bodies.reportUnshared();
    try bodies.reportLostUpdates();
    var pauses = Pauses(@TypeOf(checker)){ .gpa = gpa, .checker = checker };
    defer pauses.deinit();
    for (checker.cir.store.sliceDefs(checker.cir.all_defs)) |def| {
        try pauses.walk(checker.cir.store.getDef(def).expr);
    }
}

fn callOf(checker: anytype, expr: CIR.Expr.Idx) Allocator.Error!?Call {
    const node = checker.cir.store.getExpr(expr);
    const receiver: ?CIR.Expr.Idx, const args = if (node == .e_call)
        .{ null, node.e_call.args }
    else if (node == .e_method_call)
        .{ node.e_method_call.receiver, node.e_method_call.args }
    else if (node == .e_dispatch_call)
        .{ node.e_dispatch_call.receiver, node.e_dispatch_call.args }
    else if (node == .e_type_method_call)
        .{ null, node.e_type_method_call.args }
    else if (node == .e_type_dispatch_call)
        .{ null, node.e_type_dispatch_call.args }
    else
        return null;
    return .{
        .operation = try checker.sharedOperation(expr),
        .effectful = try checker.callIsEffectful(expr),
        .receiver = receiver,
        .args = checker.cir.store.sliceExpr(args),
    };
}

fn handleOf(checker: anytype, expr: ?CIR.Expr.Idx) ?Handle {
    const handle = expr orelse return null;
    const lookup = checker.cir.store.getExpr(handle);
    if (lookup != .e_lookup_local) return null;
    const pattern = lookup.e_lookup_local.pattern_idx;
    return if (checker.cir.store.getPattern(pattern) == .assign) pattern else null;
}

/// The lambda that an expression is, if it is written as one.
fn lambdaOf(checker: anytype, expr: ?CIR.Expr.Idx) ?CIR.Expr.Idx {
    const written = expr orelse return null;
    const node = checker.cir.store.getExpr(written);
    if (node == .e_lambda) return written;
    if (node == .e_closure) return node.e_closure.lambda_idx;
    return null;
}

/// What the first two warnings need: where each handle is used, and what each
/// name is computed from.
fn Bodies(comptime Checker: type) type {
    return struct {
        const Self = @This();
        const Work = struct { expr: CIR.Expr.Idx, body: ?CIR.Expr.Idx };
        const Made = struct { body: ?CIR.Expr.Idx, region: Region, used: bool, escaped: bool };
        const Update = struct { handle: Handle, transform: CIR.Expr.Idx, operation: Operation, region: Region };

        gpa: Allocator,
        checker: Checker,
        work: std.ArrayList(Work) = .empty,
        /// Each name bound to the result of `Shared.new!`.
        made: std.ArrayList(struct { handle: Handle, made: Made }) = .empty,
        made_index: collections.DenseMapUnmanaged(Handle, u32) = .empty,
        /// The lookups that are the handle a `Shared` function is called on.
        operands: collections.DenseMapUnmanaged(CIR.Expr.Idx, void) = .empty,
        /// What a name that a declaration, a `var` or a `match` binds is
        /// computed from.
        sources: collections.DenseMapUnmanaged(CIR.Pattern.Idx, CIR.Expr.Idx) = .empty,
        updates: std.ArrayList(Update) = .empty,

        fn deinit(self: *Self) void {
            self.work.deinit(self.gpa);
            self.made.deinit(self.gpa);
            self.made_index.deinit(self.gpa);
            self.operands.deinit(self.gpa);
            self.sources.deinit(self.gpa);
            self.updates.deinit(self.gpa);
        }

        /// Visits in source order, so a name is bound before it is used.
        fn scan(self: *Self, root: CIR.Expr.Idx) Allocator.Error!void {
            try self.work.append(self.gpa, .{ .expr = root, .body = null });
            while (self.work.pop()) |next| try self.scanExpr(next);
        }

        fn scanExpr(self: *Self, next: Work) Allocator.Error!void {
            const node = self.checker.cir.store.getExpr(next.expr);
            if (node == .e_lookup_local) {
                const index = self.made_index.get(node.e_lookup_local.pattern_idx) orelse return;
                const made = &self.made.items[index].made;
                made.used = true;
                if (!self.operands.contains(next.expr) or made.body != next.body) made.escaped = true;
                return;
            }
            if (node == .e_block) {
                for (self.checker.cir.store.sliceStatements(node.e_block.stmts)) |statement| {
                    try self.scanBinding(statement, next.body);
                }
            }
            if (node == .e_match) {
                for (self.checker.cir.store.sliceMatchBranches(node.e_match.branches)) |branch_idx| {
                    const branch = self.checker.cir.store.getMatchBranch(branch_idx);
                    for (self.checker.cir.store.sliceMatchBranchPatterns(branch.patterns)) |pattern| {
                        try self.bind(self.checker.cir.store.getMatchBranchPattern(pattern).pattern, node.e_match.cond);
                    }
                }
            }
            if (try callOf(self.checker, next.expr)) |call| {
                if (call.operation) |operation| try self.scanOperation(next.expr, call, operation);
            }
            const body = if (node == .e_lambda) next.expr else next.body;
            const first = self.work.items.len;
            try self.checker.visitExprChildren(next.expr, Pusher{ .bodies = self, .body = body });
            std.mem.reverse(Work, self.work.items[first..]);
        }

        fn scanBinding(self: *Self, statement: CIR.Statement.Idx, body: ?CIR.Expr.Idx) Allocator.Error!void {
            switch (self.checker.cir.store.getStatement(statement)) {
                .s_decl => |decl| {
                    try self.bind(decl.pattern, decl.expr);
                    const made = try callOf(self.checker, decl.expr) orelse return;
                    if (made.operation != .new) return;
                    if (self.checker.cir.store.getPattern(decl.pattern) != .assign) return;
                    try self.made_index.put(self.gpa, decl.pattern, @intCast(self.made.items.len));
                    try self.made.append(self.gpa, .{ .handle = decl.pattern, .made = .{
                        .body = body,
                        .region = self.checker.cir.store.getPatternRegion(decl.pattern),
                        .used = false,
                        .escaped = false,
                    } });
                },
                .s_var => |var_| try self.bind(var_.pattern_idx, var_.expr),
                .s_reassign,
                .s_var_uninitialized,
                .s_dbg,
                .s_expr,
                .s_expect,
                .s_for,
                .s_while,
                .s_infinite_loop,
                .s_breakable_loop,
                .s_return,
                .s_crash,
                .s_break,
                .s_import,
                .s_alias_decl,
                .s_nominal_decl,
                .s_where_alias_decl,
                .s_type_anno,
                .s_type_var_alias,
                .s_runtime_error,
                => {},
            }
        }

        fn bind(self: *Self, root: CIR.Pattern.Idx, source: CIR.Expr.Idx) Allocator.Error!void {
            var pending: std.ArrayList(CIR.Pattern.Idx) = .empty;
            defer pending.deinit(self.gpa);
            try pending.append(self.gpa, root);
            while (pending.pop()) |pattern| {
                try self.sources.put(self.gpa, pattern, source);
                try self.checker.pushCirSubpatterns(&pending, pattern);
            }
        }

        fn scanOperation(self: *Self, expr: CIR.Expr.Idx, call: Call, operation: Operation) Allocator.Error!void {
            if (operation == .new) return;
            const handle = handleOf(self.checker, call.arg(0)) orelse return;
            try self.operands.put(self.gpa, call.arg(0).?, {});
            if (operation != .update and operation != .modify) return;
            const transform = lambdaOf(self.checker, call.arg(1)) orelse return;
            try self.updates.append(self.gpa, .{
                .handle = handle,
                .transform = transform,
                .operation = operation,
                .region = self.checker.cir.store.getExprRegion(expr),
            });
        }

        fn reportUnshared(self: *Self) Allocator.Error!void {
            for (self.made.items) |entry| {
                if (!entry.made.used or entry.made.escaped) continue;
                _ = try self.checker.problems.appendProblem(.{ .unshared_state = .{
                    .region = entry.made.region,
                    .name = self.checker.cir.store.getPattern(entry.handle).assign.ident,
                } });
            }
        }

        /// An update whose function ignores the state, and stores a value
        /// computed from an earlier read of it.
        fn reportLostUpdates(self: *Self) Allocator.Error!void {
            for (self.updates.items) |update| {
                const lambda = self.checker.cir.store.getExpr(update.transform).e_lambda;
                const params = self.checker.cir.store.slicePatterns(lambda.args);
                if (params.len != 1) continue;
                const param = self.checker.cir.store.getPattern(params[0]);
                if (param != .underscore and param != .assign) continue;
                const reads = try self.readsOf(lambda.body, update, params[0]);
                if (reads.state_used) continue;
                const read = reads.region orelse continue;
                _ = try self.checker.problems.appendProblem(.{ .lost_update = .{
                    .region = update.region,
                    .read_region = read,
                    .name = self.checker.cir.store.getPattern(update.handle).assign.ident,
                } });
            }
        }

        const Reads = struct { state_used: bool, region: ?Region };

        fn readsOf(self: *Self, body: CIR.Expr.Idx, update: Update, state: CIR.Pattern.Idx) Allocator.Error!Reads {
            var reads = Reads{ .state_used = false, .region = null };
            var seen: collections.DenseMapUnmanaged(CIR.Expr.Idx, void) = .empty;
            defer seen.deinit(self.gpa);
            // What the function stores: the whole of what `modify!`'s returns,
            // and the first payload of a `Set` in `update!`'s.
            var stored: std.ArrayList(CIR.Expr.Idx) = .empty;
            defer stored.deinit(self.gpa);
            if (update.operation == .modify) try stored.append(self.gpa, body);

            var inside: std.ArrayList(CIR.Expr.Idx) = .empty;
            defer inside.deinit(self.gpa);
            try inside.append(self.gpa, body);
            while (inside.pop()) |expr| {
                const node = self.checker.cir.store.getExpr(expr);
                if (node == .e_lookup_local and node.e_lookup_local.pattern_idx == state) reads.state_used = true;
                if (update.operation == .update and node == .e_tag and node.e_tag.name.eql(self.checker.cir.idents.set)) {
                    const payloads = self.checker.cir.store.sliceExpr(node.e_tag.args);
                    if (payloads.len > 0) try stored.append(self.gpa, payloads[0]);
                }
                try self.checker.visitExprChildren(expr, ExprPusher{ .gpa = self.gpa, .work = &inside });
            }
            if (reads.state_used) return reads;

            while (stored.pop()) |expr| {
                if ((try seen.getOrPut(self.gpa, expr)).found_existing) continue;
                const node = self.checker.cir.store.getExpr(expr);
                if (node == .e_lambda and expr != update.transform) continue;
                if (node == .e_lookup_local) {
                    if (self.sources.get(node.e_lookup_local.pattern_idx)) |source| try stored.append(self.gpa, source);
                    continue;
                }
                if (try callOf(self.checker, expr)) |call| {
                    if (call.operation == .get and handleOf(self.checker, call.arg(0)) == update.handle) {
                        reads.region = self.checker.cir.store.getExprRegion(expr);
                        return reads;
                    }
                }
                try self.checker.visitExprChildren(expr, ExprPusher{ .gpa = self.gpa, .work = &stored });
            }
            return reads;
        }

        const Pusher = struct {
            bodies: *Self,
            body: ?CIR.Expr.Idx,

            /// Visitor callback: a child expression.
            pub fn expr(self: Pusher, child: CIR.Expr.Idx) Allocator.Error!void {
                try self.bodies.work.append(self.bodies.gpa, .{ .expr = child, .body = self.body });
            }

            /// Visitor callback: a pattern the node binds.
            pub fn boundPattern(_: Pusher, _: CIR.Pattern.Idx) Allocator.Error!void {}

            /// Visitor callback: the pattern a reassignment writes.
            pub fn reassignTarget(_: Pusher, _: CIR.Pattern.Idx) Allocator.Error!void {}
        };
    };
}

const ExprPusher = struct {
    gpa: Allocator,
    work: *std.ArrayList(CIR.Expr.Idx),

    /// Visitor callback: a child expression.
    pub fn expr(self: ExprPusher, child: CIR.Expr.Idx) Allocator.Error!void {
        try self.work.append(self.gpa, child);
    }

    /// Visitor callback: a pattern the node binds.
    pub fn boundPattern(_: ExprPusher, _: CIR.Pattern.Idx) Allocator.Error!void {}

    /// Visitor callback: the pattern a reassignment writes.
    pub fn reassignTarget(_: ExprPusher, _: CIR.Pattern.Idx) Allocator.Error!void {}
};

/// The third warning: each body is followed along its control flow, with the
/// handles it has updated and whether it may have paused since.
fn Pauses(comptime Checker: type) type {
    return struct {
        const Self = @This();

        /// What a body may have done to a handle since its last cleanup.
        const Entry = struct { handle: Handle, pause: ?Region };
        /// Index into `nodes`; a list of entries, at most one for a handle.
        /// `null` is the state of code that control doesn't reach.
        const State = ?u32;
        const empty: State = 0;
        const Node = struct { entry: Entry, rest: u32 };

        const Task = union(enum) {
            expr: CIR.Expr.Idx,
            statement: CIR.Statement.Idx,
            /// The operands of a call were evaluated.
            call: CIR.Expr.Idx,
            /// Go on from the state of a slot.
            enter: u32,
            /// Join the state into a slot.
            join: u32,
            /// The body paused here.
            pause: Region,
            /// The state after a loop, from its slot, which is then the
            /// innermost loop no longer.
            loop_end: u32,
            /// Control doesn't go on from here.
            stop,
            /// Control leaves the innermost loop.
            break_,
        };

        gpa: Allocator,
        checker: Checker,
        tasks: std.ArrayList(Task) = .empty,
        bodies: std.ArrayList(CIR.Expr.Idx) = .empty,
        nodes: std.ArrayList(Node) = .empty,
        slots: std.ArrayList(State) = .empty,
        loops: std.ArrayList(u32) = .empty,
        state: State = empty,

        fn deinit(self: *Self) void {
            self.tasks.deinit(self.gpa);
            self.bodies.deinit(self.gpa);
            self.nodes.deinit(self.gpa);
            self.slots.deinit(self.gpa);
            self.loops.deinit(self.gpa);
        }

        fn walk(self: *Self, root: CIR.Expr.Idx) Allocator.Error!void {
            try self.bodies.append(self.gpa, root);
            while (self.bodies.pop()) |body| {
                self.nodes.clearRetainingCapacity();
                self.slots.clearRetainingCapacity();
                self.loops.clearRetainingCapacity();
                // Node 0 is the end of every list.
                try self.nodes.append(self.gpa, .{ .entry = undefined, .rest = 0 });
                self.state = empty;
                try self.tasks.append(self.gpa, .{ .expr = body });
                while (self.tasks.pop()) |task| try self.step(task);
            }
        }

        fn step(self: *Self, task: Task) Allocator.Error!void {
            switch (task) {
                .expr => |expr| try self.stepExpr(expr),
                .statement => |statement| try self.stepStatement(statement),
                .call => |expr| try self.finishCall(expr),
                .enter => |slot| self.state = self.slots.items[slot],
                .join => |slot| self.slots.items[slot] = try self.merge(self.slots.items[slot], self.state),
                .pause => |region| try self.pause(region, null),
                .loop_end => |slot| {
                    _ = self.loops.pop();
                    self.state = self.slots.items[slot];
                },
                .stop => self.state = null,
                .break_ => {
                    if (self.loops.items.len > 0) {
                        const slot = self.loops.items[self.loops.items.len - 1];
                        self.slots.items[slot] = try self.merge(self.slots.items[slot], self.state);
                    }
                    self.state = null;
                },
            }
        }

        fn newSlot(self: *Self, state: State) Allocator.Error!u32 {
            try self.slots.append(self.gpa, state);
            return @intCast(self.slots.items.len - 1);
        }

        fn stepExpr(self: *Self, expr: CIR.Expr.Idx) Allocator.Error!void {
            const store = &self.checker.cir.store;
            const node = store.getExpr(expr);
            const first = self.tasks.items.len;
            switch (node) {
                .e_lambda => |lambda| {
                    try self.bodies.append(self.gpa, lambda.body);
                    return;
                },
                .e_block => |block| {
                    for (store.sliceStatements(block.stmts)) |statement| try self.tasks.append(self.gpa, .{ .statement = statement });
                    try self.tasks.append(self.gpa, .{ .expr = block.final_expr });
                },
                .e_match => |match| {
                    // The entry is only known after the condition, so each
                    // branch is entered from the slot that its end joins.
                    const entry = try self.newSlot(null);
                    const exit = try self.newSlot(null);
                    try self.tasks.append(self.gpa, .{ .expr = match.cond });
                    try self.tasks.append(self.gpa, .{ .join = entry });
                    for (store.sliceMatchBranches(match.branches)) |branch_idx| {
                        const branch = store.getMatchBranch(branch_idx);
                        try self.tasks.append(self.gpa, .{ .enter = entry });
                        if (branch.guard) |guard| try self.tasks.append(self.gpa, .{ .expr = guard });
                        try self.tasks.append(self.gpa, .{ .expr = branch.value });
                        try self.tasks.append(self.gpa, .{ .join = exit });
                    }
                    try self.tasks.append(self.gpa, .{ .enter = exit });
                },
                .e_if => |if_| {
                    const exit = try self.newSlot(null);
                    for (store.sliceIfBranches(if_.branches)) |branch_idx| {
                        const branch = store.getIfBranch(branch_idx);
                        const after_cond = try self.newSlot(null);
                        try self.tasks.append(self.gpa, .{ .expr = branch.cond });
                        try self.tasks.append(self.gpa, .{ .join = after_cond });
                        try self.tasks.append(self.gpa, .{ .expr = branch.body });
                        try self.tasks.append(self.gpa, .{ .join = exit });
                        try self.tasks.append(self.gpa, .{ .enter = after_cond });
                    }
                    try self.tasks.append(self.gpa, .{ .expr = if_.final_else });
                    try self.tasks.append(self.gpa, .{ .join = exit });
                    try self.tasks.append(self.gpa, .{ .enter = exit });
                },
                .e_for => |for_| try self.scheduleLoop(.{
                    .before = for_.expr,
                    .pause = if (for_.kind == .stream) store.getExprRegion(for_.expr) else null,
                    .cond = null,
                    .body = for_.body,
                }),
                .e_return => |ret| {
                    try self.tasks.append(self.gpa, .{ .expr = ret.expr });
                    try self.tasks.append(self.gpa, .stop);
                },
                .e_crash, .e_expect_err, .e_runtime_error => try self.tasks.append(self.gpa, .stop),
                .e_break => try self.tasks.append(self.gpa, .break_),
                .e_spawn => |spawn| {
                    // Another task runs the spawned call.
                    try self.checker.visitExprChildren(spawn.expr, Pusher{ .pauses = self });
                },
                .e_anno_only,
                .e_binop,
                .e_bytes_literal,
                .e_call,
                .e_closure,
                .e_dbg,
                .e_dec,
                .e_dec_small,
                .e_deferred_import_ref,
                .e_derived_method,
                .e_dispatch_call,
                .e_ellipsis,
                .e_empty_list,
                .e_empty_record,
                .e_expect,
                .e_field_access,
                .e_frac_f32,
                .e_frac_f64,
                .e_hosted_lambda,
                .e_interpolation,
                .e_list,
                .e_lookup_associated,
                .e_lookup_associated_local,
                .e_lookup_associated_resolved,
                .e_lookup_external,
                .e_lookup_local,
                .e_lookup_required,
                .e_method_call,
                .e_method_eq,
                .e_nominal,
                .e_nominal_external,
                .e_num,
                .e_num_from_numeral,
                .e_record,
                .e_run_low_level,
                .e_str,
                .e_str_segment,
                .e_structural_eq,
                .e_structural_hash,
                .e_tag,
                .e_tuple,
                .e_tuple_access,
                .e_type_dispatch_call,
                .e_type_method_call,
                .e_typed_frac,
                .e_typed_int,
                .e_typed_num_from_numeral,
                .e_unary_minus,
                .e_zero_argument_tag,
                => {
                    try self.checker.visitExprChildren(expr, Pusher{ .pauses = self });
                    if (try callOf(self.checker, expr) != null) try self.tasks.append(self.gpa, .{ .call = expr });
                },
            }
            std.mem.reverse(Task, self.tasks.items[first..]);
        }

        const Loop = struct { before: ?CIR.Expr.Idx, pause: ?Region, cond: ?CIR.Expr.Idx, body: CIR.Expr.Idx };

        /// The body is followed once: a state it leaves for its next iteration
        /// is one that the code after the loop sees too.
        fn scheduleLoop(self: *Self, loop: Loop) Allocator.Error!void {
            const exit = try self.newSlot(null);
            if (loop.before) |before| try self.tasks.append(self.gpa, .{ .expr = before });
            if (loop.pause) |region| try self.tasks.append(self.gpa, .{ .pause = region });
            if (loop.cond) |cond| try self.tasks.append(self.gpa, .{ .expr = cond });
            try self.tasks.append(self.gpa, .{ .join = exit });
            try self.loops.append(self.gpa, exit);
            try self.tasks.append(self.gpa, .{ .expr = loop.body });
            try self.tasks.append(self.gpa, .{ .join = exit });
            try self.tasks.append(self.gpa, .{ .loop_end = exit });
        }

        fn stepStatement(self: *Self, statement: CIR.Statement.Idx) Allocator.Error!void {
            const first = self.tasks.items.len;
            const store = &self.checker.cir.store;
            switch (store.getStatement(statement)) {
                .s_for => |for_| try self.scheduleLoop(.{
                    .before = for_.expr,
                    .pause = if (for_.kind == .stream) store.getExprRegion(for_.expr) else null,
                    .cond = null,
                    .body = for_.body,
                }),
                inline .s_while, .s_infinite_loop, .s_breakable_loop => |while_| try self.scheduleLoop(.{
                    .before = null,
                    .pause = null,
                    .cond = while_.cond,
                    .body = while_.body,
                }),
                .s_return => |ret| {
                    try self.tasks.append(self.gpa, .{ .expr = ret.expr });
                    try self.tasks.append(self.gpa, .stop);
                },
                .s_crash, .s_runtime_error => try self.tasks.append(self.gpa, .stop),
                .s_break => try self.tasks.append(self.gpa, .break_),
                .s_decl,
                .s_var,
                .s_var_uninitialized,
                .s_reassign,
                .s_dbg,
                .s_expr,
                .s_expect,
                .s_import,
                .s_alias_decl,
                .s_nominal_decl,
                .s_where_alias_decl,
                .s_type_anno,
                .s_type_var_alias,
                => try self.checker.visitStatementChildren(statement, Pusher{ .pauses = self }),
            }
            std.mem.reverse(Task, self.tasks.items[first..]);
        }

        fn finishCall(self: *Self, expr: CIR.Expr.Idx) Allocator.Error!void {
            const call = try callOf(self.checker, expr) orelse return;
            const region = self.checker.cir.store.getExprRegion(expr);
            const operation = call.operation orelse {
                if (call.effectful) try self.pause(region, null);
                return;
            };
            const handle = handleOf(self.checker, call.arg(0));
            switch (operation) {
                // An update that doesn't wait runs no other task.
                .new, .get, .modify => {},
                .update => {
                    try self.pause(region, handle);
                    const updated = handle orelse return;
                    self.state = try self.with(self.state, .{ .handle = updated, .pause = null });
                },
                .finally, .on_failure => {
                    if (handle) |cleaned| {
                        if (self.find(self.state, cleaned)) |entry| {
                            if (entry.pause) |paused| {
                                _ = try self.checker.problems.appendProblem(.{ .pause_before_cleanup = .{
                                    .region = paused,
                                    .cleanup_region = region,
                                    .name = self.checker.cir.store.getPattern(cleaned).assign.ident,
                                } });
                            }
                            self.state = try self.without(self.state, cleaned);
                        }
                    }
                    try self.pause(region, null);
                },
            }
        }

        fn find(self: *const Self, state: State, handle: Handle) ?Entry {
            var at = state orelse return null;
            while (at != 0) : (at = self.nodes.items[at].rest) {
                if (self.nodes.items[at].entry.handle == handle) return self.nodes.items[at].entry;
            }
            return null;
        }

        fn without(self: *Self, state: State, handle: Handle) Allocator.Error!State {
            var at = state orelse return null;
            var kept: u32 = 0;
            while (at != 0) : (at = self.nodes.items[at].rest) {
                const entry = self.nodes.items[at].entry;
                if (entry.handle != handle) kept = try self.cons(entry, kept);
            }
            return kept;
        }

        fn with(self: *Self, state: State, entry: Entry) Allocator.Error!State {
            const rest = try self.without(state, entry.handle) orelse return null;
            return try self.cons(entry, rest);
        }

        fn cons(self: *Self, entry: Entry, rest: u32) Allocator.Error!u32 {
            try self.nodes.append(self.gpa, .{ .entry = entry, .rest = rest });
            return @intCast(self.nodes.items.len - 1);
        }

        /// The body may pause at `region`, which matters to every handle it has
        /// updated but `except`.
        fn pause(self: *Self, region: Region, except: ?Handle) Allocator.Error!void {
            var at = self.state orelse return;
            var paused: u32 = 0;
            while (at != 0) : (at = self.nodes.items[at].rest) {
                const entry = self.nodes.items[at].entry;
                const first = if (entry.handle == except) entry.pause else entry.pause orelse region;
                paused = try self.cons(.{ .handle = entry.handle, .pause = first }, paused);
            }
            self.state = paused;
        }

        fn merge(self: *Self, left: State, right: State) Allocator.Error!State {
            if (left == null) return right;
            if (right == null) return left;
            var merged = left;
            var at = right.?;
            while (at != 0) : (at = self.nodes.items[at].rest) {
                const entry = self.nodes.items[at].entry;
                const other = self.find(left, entry.handle);
                merged = try self.with(merged, .{
                    .handle = entry.handle,
                    .pause = if (other) |known| known.pause orelse entry.pause else entry.pause,
                });
            }
            return merged;
        }

        const Pusher = struct {
            pauses: *Self,

            /// Visitor callback: a child expression.
            pub fn expr(self: Pusher, child: CIR.Expr.Idx) Allocator.Error!void {
                try self.pauses.tasks.append(self.pauses.gpa, .{ .expr = child });
            }

            /// Visitor callback: a pattern the node binds.
            pub fn boundPattern(_: Pusher, _: CIR.Pattern.Idx) Allocator.Error!void {}

            /// Visitor callback: the pattern a reassignment writes.
            pub fn reassignTarget(_: Pusher, _: CIR.Pattern.Idx) Allocator.Error!void {}
        };
    };
}
