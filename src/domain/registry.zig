//! Fixed-capacity per-app-session process ownership. No registry entry is reused
//! until its adapter has been shut down and its factory-owned state destroyed.
const std = @import("std");
const common = @import("../runtime/adapter.zig");
const c = @import("../contract.zig");
const Mcp = @import("../orchestration_mcp.zig").Server;
pub const Registry = struct {
    pub const Entry = struct {
        arena: std.heap.ArenaAllocator,
        session: c.RuntimeSessionId,
        selection: c.Selection,
        adapter: common.Adapter,
        pending_open: ?struct { effect: c.EffectId, request: c.Request },
        created_ms: u64,
        pub fn openReady(self: *Entry, allocator: std.mem.Allocator, now: u64) !?struct { effect: c.EffectId, receipt: c.Receipt } {
            const pending = self.pending_open orelse return null;
            const receipt: c.Receipt = if (now -| self.created_ms >= 15000)
                .{ .outcome = .rejected, .detail = "Runtime initialization timed out before open dispatch" }
            else if (self.adapter.ready())
                self.adapter.dispatch(allocator, pending.request) catch |err| .{ .outcome = .unknown, .detail = @errorName(err) }
            else
                return null;
            self.pending_open = null;
            return .{ .effect = pending.effect, .receipt = receipt };
        }
    };
    allocator: std.mem.Allocator,
    factory: common.Factory,
    entries: [3]?Entry = @splat(null),
    pub fn find(self: *Registry, session: c.RuntimeSessionId) ?*Entry {
        for (&self.entries) |*entry| if (entry.*) |*value| {
            if (std.mem.eql(u8, value.session.value, session.value)) return value;
        };
        return null;
    }
    pub fn create(self: *Registry, io: std.Io, server: *Mcp, selection: c.Selection, cwd: []const u8, effect: c.EffectId, request: c.Request, now: u64) !*Entry {
        // Reject mismatched durable envelopes before binding authority or
        // spawning a process. Deferred open must use this exact effect/selection.
        if (request != .open or request.open != .create) return error.InvalidOpenRequest;
        if (!c.equal(effect, request.open.create.effect) or !c.equal(selection, request.open.create.selection) or request.open.create.session.value.len == 0) return error.InvalidOpenRequest;
        const session = request.open.create.session;
        if (self.find(session) != null) return error.DuplicateRuntimeSession;
        for (&self.entries) |*entry| if (entry.* == null) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer arena.deinit();
            const allocator = arena.allocator();
            const retained_session = try common.clone(allocator, session);
            const retained_selection = try common.clone(allocator, selection);
            const retained_request = try common.clone(allocator, request);
            const retained_effect = try common.clone(allocator, effect);
            var random: [16]u8 = undefined;
            try io.randomSecure(&random);
            const token = try allocator.alloc(u8, 32);
            const hex = "0123456789abcdef";
            for (random, 0..) |byte, index| {
                token[index * 2] = hex[byte >> 4];
                token[index * 2 + 1] = hex[byte & 15];
            }
            const bridge = try server.bindSession(allocator, retained_session.value, token);
            errdefer server.unbindSession(retained_session.value);
            const adapter = try self.factory.create(self.allocator, retained_selection, cwd, retained_session, bridge);
            entry.* = .{ .arena = arena, .session = retained_session, .selection = retained_selection, .adapter = adapter, .pending_open = .{ .effect = retained_effect, .request = retained_request }, .created_ms = now };
            return &entry.*.?;
        };
        return error.RuntimeCapacity;
    }
    pub fn release(self: *Registry, server: *Mcp, index: usize) void {
        if (self.entries[index]) |*entry| {
            entry.adapter.shutdown();
            server.unbindSession(entry.session.value);
            self.factory.destroy(self.allocator, entry.adapter);
            entry.arena.deinit();
            self.entries[index] = null;
        }
    }
    pub fn deinit(self: *Registry, server: *Mcp) void {
        for (self.entries, 0..) |_, index| self.release(server, index);
    }
};

const OpenProbe = struct {
    ready_flag: bool = true,
    opens: usize = 0,
    ambiguous: bool = false,
    fn cast(context: *anyopaque) *OpenProbe {
        return @ptrCast(@alignCast(context));
    }
    fn discover(_: *anyopaque) c.Discovery {
        return .{ .capabilities = @splat(.{ .status = .unsupported }), .limits = .{} };
    }
    fn account(_: *anyopaque) c.Account {
        return .{ .reference = "fixture", .readiness = .unknown };
    }
    fn resolve(_: *anyopaque, selection: c.Selection) c.SelectionResult {
        return .{ .requested = selection, .effective = null, .readiness = .unknown };
    }
    fn dispatch(context: *anyopaque, _: std.mem.Allocator, _: c.Request) !c.Receipt {
        const self = cast(context);
        self.opens += 1;
        if (self.ambiguous) return error.ConnectionLostAfterOpen;
        return .{ .outcome = .acknowledged };
    }
    fn pump(_: *anyopaque) !void {}
    fn poll(_: *anyopaque, _: std.mem.Allocator) !?c.Observation {
        return null;
    }
    fn shutdown(_: *anyopaque) void {}
    fn ready(context: *anyopaque) bool {
        return cast(context).ready_flag;
    }
    const vtable: common.Adapter.VTable = .{ .discover = discover, .accountStatus = account, .resolveSelection = resolve, .dispatch = dispatch, .pump = pump, .poll = poll, .shutdown = shutdown, .ready = ready };
};

test "late runtime readiness cannot dispatch expired opens or retry ambiguous effects" {
    var probe: OpenProbe = .{};
    const selection = c.fakeSelection(.{ .value = "workspace" });
    const request: c.Request = .{ .open = .{ .create = .{ .effect = .{ .value = "effect" }, .session = .{ .value = "session" }, .selection = selection } } };
    var entry: Registry.Entry = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .session = request.open.create.session, .selection = selection, .adapter = .{ .context = &probe, .vtable = &OpenProbe.vtable }, .pending_open = .{ .effect = request.open.create.effect, .request = request }, .created_ms = 100 };
    defer entry.arena.deinit();
    // Even if the handshake became ready between pumps, the deadline wins.
    const expired = (try entry.openReady(std.testing.allocator, 15100)).?;
    try std.testing.expectEqual(.rejected, expired.receipt.outcome);
    try std.testing.expectEqual(@as(usize, 0), probe.opens);
    try std.testing.expect((try entry.openReady(std.testing.allocator, 15101)) == null);
    entry.created_ms = 15101;
    entry.pending_open = .{ .effect = request.open.create.effect, .request = request };
    probe.ambiguous = true;
    const ambiguous = (try entry.openReady(std.testing.allocator, 15102)).?;
    try std.testing.expectEqual(.unknown, ambiguous.receipt.outcome);
    try std.testing.expectEqualStrings("effect", ambiguous.effect.value);
    try std.testing.expectEqual(@as(usize, 1), probe.opens);
    try std.testing.expect((try entry.openReady(std.testing.allocator, 15103)) == null);
    try std.testing.expectEqual(@as(usize, 1), probe.opens);
}

test "registry rejects mismatched effect selection and non-create requests before spawning" {
    var registry: Registry = .{ .allocator = std.testing.allocator, .factory = undefined };
    const selection = c.fakeSelection(.{ .value = "workspace" });
    const effect = c.EffectId{ .value = "effect" };
    const request: c.Request = .{ .open = .{ .create = .{ .effect = effect, .session = .{ .value = "session" }, .selection = selection } } };
    // Undefined factory/server are intentional: no authority or process may be
    // touched for these malformed envelopes.
    try std.testing.expectError(error.InvalidOpenRequest, registry.create(std.testing.io, undefined, selection, "/tmp", .{ .value = "other-effect" }, request, 0));
    var wrong_selection = selection;
    wrong_selection.model_id = "another-model";
    try std.testing.expectError(error.InvalidOpenRequest, registry.create(std.testing.io, undefined, wrong_selection, "/tmp", effect, request, 0));
    const cancel: c.Request = .{ .cancel = .{ .correlation = .{ .session = request.open.create.session }, .reason = "not an open" } };
    try std.testing.expectError(error.InvalidOpenRequest, registry.create(std.testing.io, undefined, selection, "/tmp", effect, cancel, 0));
    var empty_session = request;
    empty_session.open.create.session.value = "";
    try std.testing.expectError(error.InvalidOpenRequest, registry.create(std.testing.io, undefined, selection, "/tmp", effect, empty_session, 0));
}
