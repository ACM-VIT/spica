//! Native process factory. Configuration is immutable and outlives Host.destroy.
const std = @import("std");
const c = @import("../contract.zig");
const common = @import("adapter.zig");
const transport = @import("transport.zig");
const Codex = @import("codex.zig");
const OpenCode = @import("opencode.zig");

pub const NativeFactory = struct {
    /// At most the two known native runtimes, explicitly authorized by startup.
    /// No configuration lookup, auth probing or process launch occurs in metadata.
    pub const Config = struct {
        selection: c.Selection,
        executable: [:0]const u8,
        environment: []const [:0]const u8,
    };
    configs: []const Config,
    const descriptors = @import("../orchestration_tools.zig").descriptors;

    const CodexInstance = struct { arena: std.heap.ArenaAllocator, wire: transport.Transport, runtime: Codex.Runtime };
    const OpenCodeInstance = struct { arena: std.heap.ArenaAllocator, runtime: OpenCode.Runtime };
    fn cast(p: *anyopaque) *NativeFactory {
        return @ptrCast(@alignCast(p));
    }
    fn configuration(self: *const NativeFactory, selection: c.Selection) ?*const Config {
        if (self.configs.len > 2 or selection.model_id.len == 0 or selection.effort.len == 0 or selection.workspace.value.len == 0 or selection.account_ref.len == 0 or selection.model_provider.len == 0) return null;
        if (!std.mem.eql(u8, selection.runtime_kind, "codex") and !std.mem.eql(u8, selection.runtime_kind, "opencode")) return null;
        for (self.configs) |*config| {
            var expected = config.selection;
            expected.workspace = selection.workspace;
            expected.model_id = selection.model_id;
            expected.effort = selection.effort;
            if (c.equal(expected, selection)) return config;
        }
        return null;
    }
    fn discovery(p: *anyopaque, selection: c.Selection) c.Discovery {
        const self = cast(p);
        var caps = [_]c.CapabilityInfo{.{ .status = .unsupported, .evidence = "Not implemented by the selected concrete adapter" }} ** @typeInfo(c.Capability).@"enum".fields.len;
        if (self.configuration(selection) != null) {
            for ([_]c.Capability{ .create, .start, .stream, .tools, .approval, .cancel, .selection, .workspace }) |cap| {
                caps[@intFromEnum(cap)] = .{ .status = .supported, .evidence = "Compiled adapter protocol support; installed version and effective selection require instance handshake" };
            }
            if (std.mem.eql(u8, selection.runtime_kind, "codex")) caps[@intFromEnum(c.Capability.attach)] = .{ .status = .supported, .evidence = "Codex thread/resume protocol; instance handshake required" };
            caps[@intFromEnum(c.Capability.coordinator_bridge)] = .{ .status = .unknown, .evidence = "Host endpoint and actual provider tool callback require consumer verification" };
        }
        return .{ .runtime_kind = selection.runtime_kind, .runtime_version = selection.required_runtime_version, .capabilities = caps, .limits = .{} };
    }
    fn account(p: *anyopaque, selection: c.Selection) c.Account {
        return .{ .reference = selection.account_ref, .readiness = if (cast(p).configuration(selection) != null) .unknown else .unavailable };
    }
    fn resolve(p: *anyopaque, selection: c.Selection) c.SelectionResult {
        return .{ .requested = selection, .effective = null, .readiness = account(p, selection).readiness };
    }
    fn createInstance(p: *anyopaque, a: std.mem.Allocator, selection: c.Selection, cwd: []const u8, session: c.RuntimeSessionId, bridge: ?common.Bridge) !common.Adapter {
        const self = cast(p);
        const config = self.configuration(selection) orelse return error.SelectionUnavailable;
        if (!std.fs.path.isAbsolute(cwd)) return error.AbsoluteWorkspaceRequired;
        if (std.mem.eql(u8, selection.runtime_kind, "codex")) {
            const instance = try a.create(CodexInstance);
            errdefer a.destroy(instance);
            instance.arena = std.heap.ArenaAllocator.init(a);
            errdefer instance.arena.deinit();
            const retained = instance.arena.allocator();
            const identity = try common.clone(retained, selection);
            const root = try retained.dupeZ(u8, cwd);
            const id = try retained.dupe(u8, session.value);
            const tools = try retained.alloc(Codex.Tool, if (bridge != null) descriptors.len else 0);
            for (tools, descriptors[0..tools.len]) |*tool, descriptor| {
                const schema = try std.json.parseFromSlice(std.json.Value, retained, descriptor.input_schema, .{ .allocate = .alloc_always });
                tool.* = .{ .name = descriptor.name, .description = descriptor.description, .inputSchema = schema.value };
            }
            instance.wire = try transport.Transport.init(a, .{ .argv = &.{ config.executable, "app-server", "--stdio" }, .cwd = root, .environment = config.environment });
            errdefer instance.wire.deinit();
            instance.runtime = try Codex.Runtime.init(a, &instance.wire, .{ .selection = identity, .cwd = root, .instance = id, .tools = tools });
            return instance.runtime.asAdapter();
        }
        if (!std.mem.eql(u8, selection.runtime_kind, "opencode")) return error.UnsupportedRuntime;
        const instance = try a.create(OpenCodeInstance);
        errdefer a.destroy(instance);
        instance.arena = std.heap.ArenaAllocator.init(a);
        errdefer instance.arena.deinit();
        const retained = instance.arena.allocator();
        const identity = try common.clone(retained, selection);
        const root = try retained.dupeZ(u8, cwd);
        const id = try retained.dupe(u8, session.value);
        const servers = if (bridge) |endpoint| try @import("opencode_bridge.zig").serialize(retained, endpoint) else "[]";
        var wire = try transport.Transport.init(a, .{ .argv = &.{ config.executable, "acp" }, .cwd = root, .environment = config.environment });
        errdefer wire.deinit();
        try instance.runtime.init(a, wire, .{ .selection = identity, .cwd = root, .instance = .{ .value = id }, .account = .{ .reference = identity.account_ref, .readiness = .unknown }, .mcp_servers = servers });
        return instance.runtime.asAdapter();
    }
    fn destroyInstance(_: *anyopaque, a: std.mem.Allocator, adapter: common.Adapter) void {
        // asAdapter only returns self and a type-static vtable; it does not read
        // runtime storage. Identify the concrete owner without retaining a map.
        const candidate: *Codex.Runtime = @ptrCast(@alignCast(adapter.context));
        if (adapter.vtable == candidate.asAdapter().vtable) {
            const runtime = candidate;
            const instance: *CodexInstance = @fieldParentPtr("runtime", runtime);
            runtime.deinit();
            instance.arena.deinit();
            a.destroy(instance);
        } else {
            const runtime: *OpenCode.Runtime = @ptrCast(@alignCast(adapter.context));
            const instance: *OpenCodeInstance = @fieldParentPtr("runtime", runtime);
            instance.arena.deinit();
            a.destroy(instance);
        }
    }
    pub fn asFactory(self: *NativeFactory) common.Factory {
        return .{ .context = self, .vtable = &.{ .discover = discovery, .accountStatus = account, .resolveSelection = resolve, .create = createInstance, .destroy = destroyInstance } };
    }
};
