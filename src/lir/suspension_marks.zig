//! Mark which procedures may suspend and which calls are suspension sites
//! (design.md "Suspendability").
//!
//! A call is a suspension site when its callee may suspend. A body-less
//! procedure's mark is given: LIR construction marks a `suspending` hosted
//! procedure, and a cached body's producer committed its own. A procedure
//! with a body may suspend when it calls one that may, directly, or when it
//! holds a running set's `group_next`, which parks the task while no entry
//! has reported (design.md "Child Tasks"), or a `cell_wait`, which parks it
//! until a wake ("Shared State"). An erased call is a site when
//! its class may suspend: when some procedure of the class may. Then every
//! procedure of the class may, so that a call and whatever procedure it
//! enters agree that the task is passed (design.md "Erased Calls That May
//! Suspend").
//!
//! Every procedure with a body and every call gets its mark committed, so
//! running this again after rewrites replaces stale marks.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("lir_core");
const body_clone = @import("body_clone.zig");
const invariant = @import("base").invariant;
const ConcurrencyMode = @import("base").ConcurrencyMode;

const LIR = core.LIR;
const LirStore = core.LirStore;
const Allocator = std.mem.Allocator;

const DirectCall = struct {
    caller: u32,
    callee: u32,
    stmt: LIR.CFStmtId,
};

/// A call through a value of an erased callable type that has a class.
const ErasedCall = struct {
    caller: u32,
    class: LIR.ErasedClass,
    stmt: LIR.CFStmtId,
};

/// Every direct call and every classed erased call in every procedure body,
/// and the procedures whose bodies hold a `group_next` or a `cell_wait`.
const Walk = struct {
    calls: std.ArrayList(DirectCall),
    erased: std.ArrayList(ErasedCall),
    parks: std.bit_set.DynamicBitSetUnmanaged,

    fn deinit(self: *Walk, allocator: Allocator) void {
        self.calls.deinit(allocator);
        self.erased.deinit(allocator);
        self.parks.deinit(allocator);
    }
};

/// The procedures that may suspend and the erased classes that may.
const Marks = struct {
    procs: std.bit_set.DynamicBitSetUnmanaged,
    classes: ClassSet,

    fn deinit(self: *Marks, allocator: Allocator) void {
        self.procs.deinit(allocator);
        self.classes.deinit(allocator);
    }
};

const ClassSet = std.AutoHashMapUnmanaged(LIR.ErasedClass, void);

/// Commit `suspends` on every procedure with a body and `suspension_site` on
/// every direct and classed erased call.
///
/// `mode` is the platform's: every `cell_wait` specialization is a seed, and in
/// a build with tasks every `run_supervised` one (design.md "Shared State",
/// "Waiting."; "Plans And Concurrent Loops", "Supervision.").
pub fn run(allocator: Allocator, store: *LirStore, mode: ConcurrencyMode) Allocator.Error!void {
    if (!anySeed(store, mode)) {
        // Nothing can suspend: commit `never` without walking. A Debug
        // compiler walks anyway and checks that no call is a site. Nor is
        // there a `group_next`: a loop has the task form only when an entry
        // may suspend, which needs a suspending procedure; nor a `cell_wait`,
        // whose helper is a seed.
        if (builtin.mode == .debug) {
            var walk = try walkBodies(allocator, store);
            defer walk.deinit(allocator);
            for (walk.calls.items) |call| {
                if (store.stmtRowOrDefault(store.getCFStmtImmediate(call.stmt).assign_call.extra).suspension_site) {
                    invariant("suspension marks found a site with no suspending procedure", .{});
                }
            }
            for (walk.erased.items) |call| {
                if (store.stmtRow(store.getCFStmtImmediate(call.stmt).assign_call_erased.data).suspension_site) {
                    invariant("suspension marks found an erased site with no suspending procedure", .{});
                }
            }
            if (walk.parks.count() != 0) invariant("suspension marks found a running set's next or a wait on shared state with no suspending procedure", .{});
        }
        for (0..store.procSpecCount()) |index| {
            const proc = store.getProcSpecPtr(@fromBackingInt(@as(u32, @intCast(index))));
            if (proc.body.get() != null) proc.suspends = .never;
        }
        return;
    }

    var walk = try walkBodies(allocator, store);
    defer walk.deinit(allocator);
    const calls = &walk.calls;
    for (0..store.procSpecCount()) |index| {
        if (seeds(store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index)))), mode)) walk.parks.set(index);
    }
    var marks = try maySuspend(allocator, store, &walk);
    defer marks.deinit(allocator);
    const may = &marks.procs;

    for (0..store.procSpecCount()) |index| {
        const proc = store.getProcSpecPtr(@fromBackingInt(@as(u32, @intCast(index))));
        if (proc.body.get() != null) proc.suspends = if (may.isSet(index)) .may else .never;
    }
    for (calls.items) |call| {
        const updated = &store.getCFStmtPtr(call.stmt).assign_call;
        var extra = store.stmtRowOrDefault(updated.extra);
        const site = may.isSet(call.callee);
        if (extra.suspension_site == site) continue;
        extra.suspension_site = site;
        updated.extra = try store.addOptionalStmtRow(LIR.CallExtra, extra);
    }
    for (walk.erased.items) |call| {
        var data = store.stmtRow(store.getCFStmtImmediate(call.stmt).assign_call_erased.data);
        const site = marks.classes.contains(call.class);
        if (data.suspension_site == site) continue;
        data.suspension_site = site;
        const row = try store.addStmtRow(LIR.ErasedCallData, data);
        store.getCFStmtPtr(call.stmt).assign_call_erased.data = row;
    }
    if (builtin.mode == .debug) try verify(allocator, store, &walk, &marks.classes);
}

/// Whether a procedure is a `cell_wait` specialization, or in a build with
/// tasks a `run_supervised` one, that this compilation has the body of; a
/// cached one's producer committed its mark.
fn seeds(proc: *const LIR.LirProcSpec, mode: ConcurrencyMode) bool {
    if (proc.body.get() == null) return false;
    if (proc.running_set_helper == .cell_wait) return true;
    return mode.hasTasks() and proc.running_set_helper == .run_supervised;
}

/// Whether any body-less procedure is marked as one that may suspend, or this
/// compilation holds a seed's body.
fn anySeed(store: *const LirStore, mode: ConcurrencyMode) bool {
    for (0..store.procSpecCount()) |index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index))));
        if (proc.body.get() == null and proc.suspends == .may) return true;
        if (seeds(proc, mode)) return true;
    }
    return false;
}

/// Every direct and classed erased call in every procedure body, and the
/// procedures that hold a `group_next` or a `cell_wait`.
fn walkBodies(allocator: Allocator, store: *const LirStore) Allocator.Error!Walk {
    var calls = std.ArrayList(DirectCall).empty;
    errdefer calls.deinit(allocator);
    var erased = std.ArrayList(ErasedCall).empty;
    errdefer erased.deinit(allocator);
    var parks = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, store.procSpecCount());
    errdefer parks.deinit(allocator);
    var seen = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, store.cfStmtCount());
    defer seen.deinit(allocator);
    var work = std.ArrayList(LIR.CFStmtId).empty;
    defer work.deinit(allocator);
    for (0..store.procSpecCount()) |proc_index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(proc_index))));
        const body = proc.body.get() orelse continue;
        try work.append(allocator, body);
        while (work.pop()) |stmt_id| {
            if (seen.isSet(@backingInt(stmt_id))) continue;
            seen.set(@backingInt(stmt_id));
            const stmt = store.getCFStmt(stmt_id);
            if (stmt == .assign_call) try calls.append(allocator, .{
                .caller = @intCast(proc_index),
                .callee = @backingInt(stmt.assign_call.proc),
                .stmt = stmt_id,
            });
            if (stmt == .assign_call_erased) {
                const class = store.stmtRow(stmt.assign_call_erased.data).erased_class;
                if (class != .none) try erased.append(allocator, .{ .caller = @intCast(proc_index), .class = class, .stmt = stmt_id });
            }
            if (stmt == .assign_low_level and (stmt.assign_low_level.op == .group_next or stmt.assign_low_level.op == .cell_wait)) parks.set(proc_index);
            try body_clone.appendSuccessors(store, &work, stmt_id, allocator);
        }
    }
    return .{ .calls = calls, .erased = erased, .parks = parks };
}

/// The procedures and erased classes that may suspend: the seeds, the
/// procedures that hold a park site or seed one, every procedure that
/// directly calls one that may, and, once a procedure of a class may, the
/// class, every procedure of it and every procedure that calls through it.
fn maySuspend(allocator: Allocator, store: *const LirStore, walk: *const Walk) Allocator.Error!Marks {
    var marks = Marks{ .procs = try walk.parks.clone(allocator), .classes = .empty };
    errdefer marks.deinit(allocator);
    for (0..store.procSpecCount()) |index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index))));
        if (proc.body.get() == null and proc.suspends == .may) marks.procs.set(index);
    }
    try propagate(allocator, store, walk, &marks, .whole_class);
    return marks;
}

/// The procedures that may wait on shared state (design.md "Plans And
/// Concurrent Loops", "Two forms."): the `cell_wait` specializations, and every
/// procedure that calls one that may, directly or through an erased class. A
/// body-less procedure that may suspend and isn't the host's is taken to. Run
/// before the continuation pass promotes anything.
pub fn mayWait(allocator: Allocator, store: *const LirStore) Allocator.Error!std.bit_set.DynamicBitSetUnmanaged {
    var marks = Marks{ .procs = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, store.procSpecCount()), .classes = .empty };
    errdefer marks.procs.deinit(allocator);
    defer marks.classes.deinit(allocator);
    for (0..store.procSpecCount()) |index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index))));
        if (proc.running_set_helper == .cell_wait or (proc.body.get() == null and proc.hosted.get() == null and proc.suspends == .may)) marks.procs.set(index);
    }
    if (marks.procs.count() == 0) return marks.procs;
    var walk = try walkBodies(allocator, store);
    defer walk.deinit(allocator);
    try propagate(allocator, store, &walk, &marks, .callers);
    return marks.procs;
}

/// What a class one of whose procedures is marked passes the mark to: the
/// procedures that call through it, or also every procedure of it.
const ClassSpread = enum { callers, whole_class };

/// Add to `marks` every procedure that calls one in it, through any number of
/// direct calls and calls through classes.
fn propagate(allocator: Allocator, store: *const LirStore, walk: *const Walk, marks: *Marks, spread: ClassSpread) Allocator.Error!void {
    const proc_count = store.procSpecCount();
    const may = &marks.procs;
    var pending = std.ArrayList(u32).empty;
    defer pending.deinit(allocator);
    var seeded = may.iterator(.{});
    while (seeded.next()) |index| try pending.append(allocator, @intCast(index));
    // Each callee's callers, as linked lists threaded through `calls`, and
    // each class's procedures and callers, as ones threaded through `links`.
    const calls = walk.calls.items;
    const first_caller = try allocator.alloc(u32, proc_count);
    defer allocator.free(first_caller);
    @memset(first_caller, no_link);
    const next_caller = try allocator.alloc(u32, calls.len);
    defer allocator.free(next_caller);
    for (calls, 0..) |call, index| {
        next_caller[index] = first_caller[call.callee];
        first_caller[call.callee] = @intCast(index);
    }
    var links = ClassLinks{};
    defer links.deinit(allocator);
    for (walk.erased.items) |call| try links.add(allocator, call.class, call.caller);
    if (spread == .whole_class) for (0..proc_count) |index| {
        const class = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index)))).erased_class;
        if (class != .none) try links.add(allocator, class, @intCast(index));
    };
    while (pending.pop()) |callee| {
        var call_index = first_caller[callee];
        while (call_index != no_link) : (call_index = next_caller[call_index]) {
            const caller = calls[call_index].caller;
            if (may.isSet(caller)) continue;
            may.set(caller);
            try pending.append(allocator, caller);
        }
        const class = store.getProcSpecImmediate(@fromBackingInt(callee)).erased_class;
        if (class == .none or marks.classes.contains(class)) continue;
        try marks.classes.put(allocator, class, {});
        var link_index = links.first.get(class) orelse no_link;
        while (link_index != no_link) : (link_index = links.links.items[link_index].next) {
            const proc = links.links.items[link_index].proc;
            if (may.isSet(proc)) continue;
            may.set(proc);
            try pending.append(allocator, proc);
        }
    }
}

const no_link = std.math.maxInt(u32);

/// For each erased class, the procedures of the class and the procedures
/// that call through it.
const ClassLinks = struct {
    first: std.AutoHashMapUnmanaged(LIR.ErasedClass, u32) = .empty,
    links: std.ArrayList(struct { proc: u32, next: u32 }) = .empty,

    fn deinit(self: *ClassLinks, allocator: Allocator) void {
        self.first.deinit(allocator);
        self.links.deinit(allocator);
    }

    fn add(self: *ClassLinks, allocator: Allocator, class: LIR.ErasedClass, proc: u32) Allocator.Error!void {
        const slot = try self.first.getOrPut(allocator, class);
        const next = if (slot.found_existing) slot.value_ptr.* else no_link;
        slot.value_ptr.* = @intCast(self.links.items.len);
        try self.links.append(allocator, .{ .proc = proc, .next = next });
    }
};

/// Debug check that the marks are complete: a direct call is a site exactly
/// when its callee may suspend, a classed erased call exactly when its class
/// may, a procedure of a class may suspend exactly when the class may, and
/// any other procedure with a body exactly when it holds a site, a
/// `group_next` and a `cell_wait` being ones.
fn verify(allocator: Allocator, store: *const LirStore, walk: *const Walk, classes: *const ClassSet) Allocator.Error!void {
    var has_site = try walk.parks.clone(allocator);
    defer has_site.deinit(allocator);
    for (walk.calls.items) |call| {
        const site = store.stmtRowOrDefault(store.getCFStmtImmediate(call.stmt).assign_call.extra).suspension_site;
        const callee_may = store.getProcSpecImmediate(@fromBackingInt(call.callee)).suspends == .may;
        if (site != callee_may) invariant("suspension site mark disagrees with its callee's mark", .{});
        if (site) has_site.set(call.caller);
    }
    for (walk.erased.items) |call| {
        const site = store.stmtRow(store.getCFStmtImmediate(call.stmt).assign_call_erased.data).suspension_site;
        if (site != classes.contains(call.class)) invariant("erased suspension site mark disagrees with its class", .{});
        if (site) has_site.set(call.caller);
    }
    for (0..store.procSpecCount()) |index| {
        const proc = store.getProcSpecImmediate(@fromBackingInt(@as(u32, @intCast(index))));
        if (proc.body.get() == null) continue;
        const class_may = proc.erased_class != .none and classes.contains(proc.erased_class);
        if (has_site.isSet(index) and proc.erased_class != .none and !class_may) invariant("a procedure with a suspension site is in an erased class that never suspends", .{});
        if ((proc.suspends == .may) != (has_site.isSet(index) or class_may)) invariant("procedure suspends mark disagrees with its suspension sites", .{});
    }
}

const testing = std.testing;

/// A procedure whose body calls `callee` and returns the result, or returns
/// a fresh local when `callee` is null.
fn addRelay(store: *LirStore, identity: u32, callee: ?LIR.LirProcSpecId) Allocator.Error!struct { proc: LIR.LirProcSpecId, call: ?LIR.CFStmtId } {
    const value = try store.addLocal(.{ .layout_idx = .u64 });
    const ret = try store.addCFStmt(.{ .ret = .{ .value = value } }, .test_fixture);
    const call: ?LIR.CFStmtId = if (callee) |target| try store.addCFStmt(.{ .assign_call = .{
        .target = value,
        .proc = target,
        .args = .empty(),
        .next = ret,
    } }, .test_fixture) else null;
    const proc = try store.addProcSpec(.{
        .name = store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.forTest(identity),
        .args = .empty(),
        .body = .some(call orelse ret),
        .ret_layout = .u64,
    }, .none);
    return .{ .proc = proc, .call = call };
}

fn addBodyless(store: *LirStore, identity: u32, suspends: LIR.Suspends) Allocator.Error!LIR.LirProcSpecId {
    return store.addProcSpec(.{
        .name = store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.forTest(identity),
        .args = .empty(),
        .ret_layout = .u64,
        .external = true,
        .suspends = suspends,
    }, .none);
}

fn isSite(store: *const LirStore, call: LIR.CFStmtId) bool {
    return store.stmtRowOrDefault(store.getCFStmtImmediate(call).assign_call.extra).suspension_site;
}

test "suspension marks declarations are referenced" {
    testing.refAllDecls(@This());
}

test "a suspending seed marks its direct callers transitively, and only them" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    const seed = try addBodyless(&store, 1, .may);
    const plain = try addBodyless(&store, 2, .never);
    const relay = try addRelay(&store, 3, seed);
    const root = try addRelay(&store, 4, relay.proc);
    const other = try addRelay(&store, 5, plain);
    const leaf = try addRelay(&store, 6, null);

    try run(a, &store, .none);

    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(seed).suspends);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(relay.proc).suspends);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(root.proc).suspends);
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(other.proc).suspends);
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(leaf.proc).suspends);
    try testing.expect(isSite(&store, relay.call.?));
    try testing.expect(isSite(&store, root.call.?));
    try testing.expect(!isSite(&store, other.call.?));
}

test "running again replaces stale marks" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    const seed = try addBodyless(&store, 1, .may);
    const plain = try addBodyless(&store, 2, .never);
    const relay = try addRelay(&store, 3, seed);
    const root = try addRelay(&store, 4, relay.proc);
    try run(a, &store, .none);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(root.proc).suspends);

    // A rewrite retargets the relay's call to a procedure that never
    // suspends; the relay and its caller stop being suspendable.
    store.getCFStmtPtr(relay.call.?).assign_call.proc = plain;
    try run(a, &store, .none);
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(relay.proc).suspends);
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(root.proc).suspends);
    try testing.expect(!isSite(&store, relay.call.?));
    try testing.expect(!isSite(&store, root.call.?));
}

test "without a suspending seed every procedure with a body is never" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    const plain = try addBodyless(&store, 1, .never);
    const relay = try addRelay(&store, 2, plain);
    store.getProcSpecPtr(relay.proc).suspends = .may;
    try run(a, &store, .none);
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(relay.proc).suspends);
    try testing.expect(!isSite(&store, relay.call.?));
}

test "a recursive cycle through a suspending call is marked as a whole" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    const seed = try addBodyless(&store, 1, .may);
    // `even` calls `odd`, and `odd` calls `even` on one branch and the seed
    // on another: both may suspend.
    const even = try addRelay(&store, 2, null);
    const odd = try addRelay(&store, 3, null);
    const even_value = try store.addLocal(.{ .layout_idx = .u64 });
    const even_ret = try store.addCFStmt(.{ .ret = .{ .value = even_value } }, .test_fixture);
    const even_call = try store.addCFStmt(.{ .assign_call = .{ .target = even_value, .proc = odd.proc, .args = .empty(), .next = even_ret } }, .test_fixture);
    store.getProcSpecPtr(even.proc).body = .some(even_call);
    const odd_value = try store.addLocal(.{ .layout_idx = .u64 });
    const odd_ret = try store.addCFStmt(.{ .ret = .{ .value = odd_value } }, .test_fixture);
    const odd_seed_call = try store.addCFStmt(.{ .assign_call = .{ .target = odd_value, .proc = seed, .args = .empty(), .next = odd_ret } }, .test_fixture);
    const odd_back_call = try store.addCFStmt(.{ .assign_call = .{ .target = odd_value, .proc = even.proc, .args = .empty(), .next = odd_seed_call } }, .test_fixture);
    store.getProcSpecPtr(odd.proc).body = .some(odd_back_call);

    try run(a, &store, .none);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(even.proc).suspends);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(odd.proc).suspends);
    try testing.expect(isSite(&store, even_call));
    try testing.expect(isSite(&store, odd_back_call));
    try testing.expect(isSite(&store, odd_seed_call));
}

/// A procedure whose body is `s = group_next(set); ret s`.
fn addParking(store: *LirStore, identity: u32) Allocator.Error!LIR.LirProcSpecId {
    const set = try store.addLocal(.{ .layout_idx = .opaque_ptr });
    const status = try store.addLocal(.{ .layout_idx = .u32 });
    const ret = try store.addCFStmt(.{ .ret = .{ .value = status } }, .test_fixture);
    const next = try store.addLowLevelStmt(status, .group_next, &.{set}, ret, .test_fixture);
    return store.addProcSpec(.{
        .name = store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.forTest(identity),
        .args = try store.addLocalSpan(&.{set}),
        .body = .some(next),
        .ret_layout = .u32,
    }, .none);
}

test "a running set's next makes its procedure suspend, and its callers" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    // A task-form loop exists only beside a suspending seed.
    const seed = try addBodyless(&store, 1, .may);
    const parking = try addParking(&store, 2);
    const caller = try addRelay(&store, 3, parking);
    const leaf = try addRelay(&store, 4, null);

    try run(a, &store, .none);

    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(seed).suspends);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(parking).suspends);
    try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(caller.proc).suspends);
    try testing.expect(isSite(&store, caller.call.?));
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(leaf.proc).suspends);
}

test "a wait on shared state makes its helper suspend, and the helper's callers, in every mode" {
    const a = testing.allocator;
    for ([_]ConcurrencyMode{ .none, .tasks, .parallel_tasks }) |mode| {
        var store = LirStore.init(a);
        defer store.deinit();
        const helper = try addRelay(&store, 1, null);
        store.getProcSpecPtr(helper.proc).running_set_helper = .cell_wait;
        const settle = try addRelay(&store, 2, null);
        store.getProcSpecPtr(settle.proc).running_set_helper = .cell_settle;
        const caller = try addRelay(&store, 3, helper.proc);
        const settling = try addRelay(&store, 4, settle.proc);

        try run(a, &store, mode);

        try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(helper.proc).suspends);
        try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(caller.proc).suspends);
        try testing.expect(isSite(&store, caller.call.?));
        try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(settle.proc).suspends);
        try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(settling.proc).suspends);
    }
}

test "a procedure that reaches a wait may wait, and one that only suspends may not" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    const hosted = try addBodyless(&store, 1, .may);
    const symbol = try store.insertString("roc_test_suspending");
    store.getProcSpecPtr(hosted).hosted = .some(.{ .symbol = symbol, .dispatch_index = 0 });
    const suspending = try addRelay(&store, 2, hosted);
    const cached = try addBodyless(&store, 3, .may);
    const calls_cached = try addRelay(&store, 4, cached);
    const helper = try addRelay(&store, 5, null);
    store.getProcSpecPtr(helper.proc).running_set_helper = .cell_wait;
    const caller = try addRelay(&store, 6, helper.proc);
    const outer = try addRelay(&store, 7, caller.proc);

    var waits = try mayWait(a, &store);
    defer waits.deinit(a);
    for ([_]LIR.LirProcSpecId{ hosted, suspending.proc }) |proc| try testing.expect(!waits.isSet(@backingInt(proc)));
    for ([_]LIR.LirProcSpecId{ cached, calls_cached.proc, helper.proc, caller.proc, outer.proc }) |proc| try testing.expect(waits.isSet(@backingInt(proc)));
}

/// A procedure of `class` whose body is `x = cl(); ret x` through a value of
/// the class `through`, which a parameter holds.
fn addErasedRelay(store: *LirStore, identity: u32, class: LIR.ErasedClass, through: LIR.ErasedClass) Allocator.Error!struct { proc: LIR.LirProcSpecId, call: LIR.CFStmtId } {
    const closure = try store.addLocal(.{ .layout_idx = .opaque_ptr });
    const value = try store.addLocal(.{ .layout_idx = .u64 });
    const ret = try store.addCFStmt(.{ .ret = .{ .value = value } }, .test_fixture);
    const call = try store.addCFStmt(.{
        .assign_call_erased = .{
            .target = value,
            .data = try store.addStmtRow(LIR.ErasedCallData, .{
                .closure = closure,
                .args = .empty(),
                .arg_plan = undefined, // the marks never read an argument plan
                .erased_class = through,
            }),
            .next = ret,
        },
    }, .test_fixture);
    const proc = try store.addProcSpec(.{
        .name = store.freshSyntheticSymbol(),
        .identity = LIR.ProcIdentity.forTest(identity),
        .args = try store.addLocalSpan(&.{closure}),
        .body = .some(call),
        .ret_layout = .u64,
        .erased_class = class,
    }, .none);
    return .{ .proc = proc, .call = call };
}

fn isErasedSite(store: *const LirStore, call: LIR.CFStmtId) bool {
    return store.stmtRow(store.getCFStmtImmediate(call).assign_call_erased.data).suspension_site;
}

test "a suspending procedure of an erased class makes the class's procedures and calls suspend, and only that class's" {
    const a = testing.allocator;
    var store = LirStore.init(a);
    defer store.deinit();
    const first: LIR.ErasedClass = @fromBackingInt(1);
    const second: LIR.ErasedClass = @fromBackingInt(2);
    const quiet: LIR.ErasedClass = @fromBackingInt(3);
    const seed = try addBodyless(&store, 1, .may);
    // `first` holds a procedure that suspends and one that doesn't.
    const suspending = try addRelay(&store, 2, seed);
    store.getProcSpecPtr(suspending.proc).erased_class = first;
    const other = try addRelay(&store, 3, null);
    store.getProcSpecPtr(other.proc).erased_class = first;
    // A procedure of `second` suspends only by calling through `first`.
    const through = try addErasedRelay(&store, 4, second, first);
    const caller = try addErasedRelay(&store, 5, .none, second);
    const root = try addRelay(&store, 6, caller.proc);
    const quiet_member = try addRelay(&store, 7, null);
    store.getProcSpecPtr(quiet_member.proc).erased_class = quiet;
    const quiet_caller = try addErasedRelay(&store, 8, .none, quiet);
    const unclassed = try addErasedRelay(&store, 9, .none, .none);

    try run(a, &store, .none);

    for ([_]LIR.LirProcSpecId{ suspending.proc, other.proc, through.proc, caller.proc, root.proc }) |proc| {
        try testing.expectEqual(LIR.Suspends.may, store.getProcSpecImmediate(proc).suspends);
    }
    for ([_]LIR.LirProcSpecId{ quiet_member.proc, quiet_caller.proc, unclassed.proc }) |proc| {
        try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(proc).suspends);
    }
    try testing.expect(isErasedSite(&store, through.call));
    try testing.expect(isErasedSite(&store, caller.call));
    try testing.expect(isSite(&store, root.call.?));
    try testing.expect(!isErasedSite(&store, quiet_caller.call));
    try testing.expect(!isErasedSite(&store, unclassed.call));

    // Running again after a rewrite took the suspending call away replaces
    // the marks.
    store.getCFStmtPtr(suspending.call.?).assign_call.proc = quiet_member.proc;
    try run(a, &store, .none);
    try testing.expectEqual(LIR.Suspends.never, store.getProcSpecImmediate(other.proc).suspends);
    try testing.expect(!isErasedSite(&store, through.call));
    try testing.expect(!isErasedSite(&store, caller.call));
}
