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
            const receipt: c.Receipt = if (self.adapter.ready())
                self.adapter.dispatch(allocator, pending.request) catch |err| .{ .outcome = .unknown, .detail = @errorName(err) }
            else if (now -| self.created_ms >= 15000)
                .{ .outcome = .rejected, .detail = "Runtime initialization timed out before open dispatch" }
            else return null;
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
            for (random, 0..) |byte, index| { token[index*2] = hex[byte>>4]; token[index*2+1] = hex[byte&15]; }
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
