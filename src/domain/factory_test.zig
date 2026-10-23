const std = @import("std");
const domain = @import("../domain.zig");
const t = domain.types;
const c = t.adapter;
const common = @import("../runtime/adapter.zig");
const Registry = @import("registry.zig").Registry;
const Mcp = @import("../orchestration_mcp.zig").Server;

const Factory = struct {
    const Instance = struct {
        owner: *Factory,
        arena: std.heap.ArenaAllocator,
        session: c.RuntimeSessionId,
        selection: c.Selection,
        cwd: []const u8,
        bridge: common.Bridge,
        pumps: std.atomic.Value(u32) = .init(0),
        opens: std.atomic.Value(u32) = .init(0),
        starts: std.atomic.Value(u32) = .init(0),
        cancels: std.atomic.Value(u32) = .init(0),
        ready_flag: std.atomic.Value(bool) = .init(false),
        stopping: bool = false,
        stopped: bool = false,
        fn cast(context: *anyopaque) *Instance { return @ptrCast(@alignCast(context)); }
        fn discover(_: *anyopaque) c.Discovery { return .{ .capabilities = @splat(.{ .status = .supported }), .limits = .{} }; }
        fn account(context: *anyopaque) c.Account { return .{ .reference = cast(context).selection.account_ref, .readiness = .unknown }; }
        fn resolve(_: *anyopaque, selection: c.Selection) c.SelectionResult { return .{ .requested = selection, .effective = null, .readiness = .unknown }; }
        fn dispatch(context: *anyopaque, _: std.mem.Allocator, request: c.Request) !c.Receipt {
            const self = cast(context);
            switch (request) {
                .open => {
                    std.debug.assert(c.equal(request.open.create.selection, self.selection));
                    std.debug.assert(std.mem.eql(u8, request.open.create.session.value, self.session.value));
                    _ = self.opens.fetchAdd(1, .release);
                    return .{ .outcome = .acknowledged, .session = .{ .id = self.session, .instance = .{ .value = self.session.value }, .upstream = .{ .value = self.session.value } } };
                },
                .start => { _ = self.starts.fetchAdd(1, .release); },
                .cancel => { _ = self.cancels.fetchAdd(1, .release); self.stopping = true; },
                else => {},
            }
            return .{ .outcome = .acknowledged };
        }
        fn pump(context: *anyopaque) !void { _ = cast(context).pumps.fetchAdd(1, .release); }
        fn ready(context: *anyopaque) bool { return cast(context).ready_flag.load(.acquire); }
        fn poll(context: *anyopaque, _: std.mem.Allocator) !?c.Observation {
            const self = cast(context);
            if (!self.stopping) return null;
            self.stopping = false;
            return .{ .correlation = .{ .session = self.session }, .upstream_event = "cancelled", .body = .{ .cancelled = .{ .tools_stopped = true } } };
        }
        fn shutdown(context: *anyopaque) void {
            const self = cast(context);
            std.debug.assert(!self.stopped);
            if (self.owner.server) |server| {
                var found = false;
                for (server.bindings) |binding| if (std.mem.eql(u8, binding.session, self.session.value)) { found = true; };
                std.debug.assert(found);
            }
            self.stopped = true;
            _ = self.owner.shutdowns.fetchAdd(1, .release);
        }
        const vtable: common.Adapter.VTable = .{ .discover = discover, .accountStatus = account, .resolveSelection = resolve, .dispatch = dispatch, .pump = pump, .poll = poll, .shutdown = shutdown, .ready = ready };
    };
    instances: [8]?*Instance = @splat(null),
    creates: std.atomic.Value(u32) = .init(0),
    shutdowns: std.atomic.Value(u32) = .init(0),
    destroys: std.atomic.Value(u32) = .init(0),
    fail_create: bool = false,
    server: ?*Mcp = null,
    fn factoryCast(context: *anyopaque) *Factory { return @ptrCast(@alignCast(context)); }
    fn factoryDiscover(_: *anyopaque, _: c.Selection) c.Discovery { return Instance.discover(undefined); }
    fn factoryAccount(_: *anyopaque, selection: c.Selection) c.Account { return .{ .reference = selection.account_ref, .readiness = .unknown }; }
    fn create(context: *anyopaque, allocator: std.mem.Allocator, selection: c.Selection, cwd: []const u8, session: c.RuntimeSessionId, bridge: ?common.Bridge) !common.Adapter {
        const self = factoryCast(context);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const instance = try allocator.create(Instance);
        errdefer allocator.destroy(instance);
        if (self.fail_create) return error.PartialCreate;
        const retained_selection = try common.clone(arena.allocator(), selection);
        const retained_cwd = try arena.allocator().dupe(u8, cwd);
        const retained_session = try common.clone(arena.allocator(), session);
        const retained_bridge = try common.clone(arena.allocator(), bridge.?);
        instance.* = .{ .owner = self, .arena = arena, .selection = retained_selection, .cwd = retained_cwd, .session = retained_session, .bridge = retained_bridge };
        const index = self.creates.load(.acquire);
        self.instances[index] = instance;
        self.creates.store(index + 1, .release);
        return .{ .context = instance, .vtable = &Instance.vtable };
    }
    fn destroy(context: *anyopaque, allocator: std.mem.Allocator, adapter: common.Adapter) void {
        const self = factoryCast(context);
        const instance = Instance.cast(adapter.context);
        std.debug.assert(instance.stopped);
        instance.arena.deinit();
        allocator.destroy(instance);
        _ = self.destroys.fetchAdd(1, .release);
    }
    fn handle(self: *Factory) common.Factory { return .{ .context = self, .vtable = &.{ .discover = factoryDiscover, .accountStatus = factoryAccount, .resolveSelection = Instance.resolve, .create = create, .destroy = destroy } }; }
};
fn sampleSelection(workspace: []const u8) c.Selection { return .{ .workspace = .{ .value = workspace }, .model_provider = "fake", .model_id = "exact-model", .account_ref = "local", .effort = "high" }; }
fn open(session: []const u8, selected: c.Selection) c.Request { return .{ .open = .{ .create = .{ .effect = .{ .value = session }, .session = .{ .value = session }, .selection = selected } } }; }

test "three final address factory instances gate open and retain MCP through shutdown" {
    var server = try Mcp.init();
    defer server.deinit();
    var factory: Factory = .{ .server = &server };
    var registry: Registry = .{ .allocator = std.testing.allocator, .factory = factory.handle() };
    defer registry.deinit(&server);
    const names = [_][]const u8{ "coordinator", "child-one", "child-two" };
    for (names, 0..) |name, index| {
        var selected = sampleSelection("workspace");
        selected.model_id = name;
        selected.account_ref = name;
        const entry = try registry.create(std.testing.io, &server, selected, "/tmp", .{ .value = name }, open(name, selected), 100);
        try std.testing.expect(entry == registry.find(.{ .value = name }).?);
        try std.testing.expectEqualStrings(name, factory.instances[index].?.selection.model_id);
    }
    try std.testing.expectError(error.RuntimeCapacity, registry.create(std.testing.io, &server, sampleSelection("w"), "/tmp", .{ .value = "four" }, open("four", sampleSelection("w")), 100));
    for (&registry.entries, 0..) |*optional, index| {
        const entry = &optional.*.?;
        try entry.adapter.pump();
        try std.testing.expect((try entry.openReady(std.testing.allocator, 15099)) == null);
        try std.testing.expectEqual(@as(u32, 0), factory.instances[index].?.opens.load(.acquire));
    }
    factory.instances[1].?.ready_flag.store(true, .release);
    const child = registry.find(.{ .value = "child-one" }).?;
    try std.testing.expectEqual(.acknowledged, (try child.openReady(std.testing.allocator, 200)).?.receipt.outcome);
    try std.testing.expect((try child.openReady(std.testing.allocator, 300)) == null);
    try std.testing.expectEqual(@as(u32, 1), factory.instances[1].?.opens.load(.acquire));
    const timed_out = registry.find(.{ .value = "child-two" }).?;
    try std.testing.expectEqual(.rejected, (try timed_out.openReady(std.testing.allocator, 15100)).?.receipt.outcome);
    try std.testing.expectEqual(@as(u32, 0), factory.instances[2].?.opens.load(.acquire));
    registry.release(&server, 1);
    registry.release(&server, 1);
    try std.testing.expect(registry.find(.{ .value = "coordinator" }) != null);
    registry.deinit(&server);
    try std.testing.expectEqual(@as(u32, 3), factory.shutdowns.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), factory.destroys.load(.acquire));
    factory.fail_create = true;
    try std.testing.expectError(error.PartialCreate, registry.create(std.testing.io, &server, sampleSelection("w"), "/tmp", .{ .value = "partial" }, open("partial", sampleSelection("w")), 0));
    try std.testing.expect(registry.find(.{ .value = "partial" }) == null);
    for (server.bindings) |binding| try std.testing.expectEqual(@as(usize, 0), binding.session.len);
}
