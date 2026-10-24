//! Host-owned native process factory. Explicit setup is serialized with execution.
const std = @import("std");
const c = @import("../contract.zig");
const common = @import("adapter.zig");
const transport = @import("transport.zig");
const Codex = @import("codex.zig");
const OpenCode = @import("opencode.zig");
const fake_factory = @import("../domain/fake_factory.zig");

pub const NativeFactory = struct {
    /// At most the two known native runtimes, explicitly authorized by startup.
    /// No configuration lookup, auth probing or process launch occurs in metadata.
    pub const Config = struct {
        selection: c.Selection,
        executable: [:0]const u8,
        environment: []const [:0]const u8,
    };
    configs: []const Config,
    owned_configs: [2]Config = undefined,
    config_storage: [2][2][65536]u8 = undefined,
    config_generation: [2]u1 = @splat(0),
    catalog_storage: [262144]u8 = undefined,
    catalog_models: [128]c.Model = undefined,
    catalog_count: usize = 0,
    catalog_authoritative: bool = false,
    status: c.RuntimeStatus = .{},
    login_instance: ?common.Adapter = null,
    login_allocator: ?std.mem.Allocator = null,
    login_started: u64 = 0,
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
        if (c.isFakeSelection(selection)) return fake_factory.factory(p).discover(selection);
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
        const self = cast(p);
        if (c.isFakeSelection(selection)) return fake_factory.factory(p).accountStatus(selection);
        if (self.configuration(selection) == null) return .{ .reference = selection.account_ref, .readiness = .unavailable };
        for (self.catalog_models[0..self.catalog_count]) |model| {
            var candidate = model.selection;
            candidate.workspace = selection.workspace;
            candidate.effort = selection.effort;
            if (!c.equal(candidate, selection)) continue;
            for (model.supported_efforts) |effort| if (std.mem.eql(u8, effort, selection.effort)) return .{ .reference = selection.account_ref, .readiness = model.readiness };
            return .{ .reference = selection.account_ref, .readiness = .unavailable };
        }
        // Before an explicit catalog refresh, protocol negotiation still fails
        // closed at open. A refreshed catalog is authoritative for stale items.
        return .{ .reference = selection.account_ref, .readiness = if (self.catalog_authoritative) .unavailable else .unknown };
    }
    fn resolve(p: *anyopaque, selection: c.Selection) c.SelectionResult {
        if (c.isFakeSelection(selection)) return fake_factory.factory(p).resolveSelection(selection);
        return .{ .requested = selection, .effective = null, .readiness = account(p, selection).readiness };
    }
    fn createInstance(p: *anyopaque, a: std.mem.Allocator, selection: c.Selection, cwd: []const u8, session: c.RuntimeSessionId, bridge: ?common.Bridge) !common.Adapter {
        const self = cast(p);
        if (c.isFakeSelection(selection)) return fake_factory.factory(p).create(a, selection, cwd, session, bridge);
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
            const bindings = try retained.alloc(Codex.ToolBinding, tools.len);
            for (tools, bindings, descriptors[0..tools.len]) |*tool, *binding, descriptor| {
                const schema = try std.json.parseFromSlice(std.json.Value, retained, descriptor.input_schema, .{ .allocate = .alloc_always });
                // Codex restricts function names to Responses API identifiers.
                // Keep the public/MCP task.* vocabulary at the adapter boundary.
                const wire_name = try std.mem.replaceOwned(u8, retained, descriptor.name, ".", "_");
                binding.* = .{ .wire_name = wire_name, .application_name = descriptor.name };
                tool.* = .{ .name = wire_name, .description = descriptor.description, .inputSchema = schema.value };
            }
            instance.wire = try transport.Transport.init(a, .{ .argv = &.{ config.executable, "app-server", "--stdio" }, .cwd = root, .environment = config.environment });
            errdefer instance.wire.deinit();
            instance.runtime = try Codex.Runtime.init(a, &instance.wire, .{ .selection = identity, .cwd = root, .instance = id, .tools = tools, .tool_bindings = bindings });
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
    fn destroyInstance(p: *anyopaque, a: std.mem.Allocator, adapter: common.Adapter) void {
        // asAdapter only returns self and a type-static vtable; it does not read
        // runtime storage. Identify the concrete owner without retaining a map.
        const candidate: *Codex.Runtime = @ptrCast(@alignCast(adapter.context));
        if (adapter.vtable == candidate.asAdapter().vtable) {
            const runtime = candidate;
            const instance: *CodexInstance = @fieldParentPtr("runtime", runtime);
            runtime.deinit();
            instance.arena.deinit();
            a.destroy(instance);
        } else if (adapter.vtable == @as(*OpenCode.Runtime, @ptrCast(@alignCast(adapter.context))).asAdapter().vtable) {
            const runtime: *OpenCode.Runtime = @ptrCast(@alignCast(adapter.context));
            const instance: *OpenCodeInstance = @fieldParentPtr("runtime", runtime);
            instance.arena.deinit();
            a.destroy(instance);
        } else fake_factory.factory(p).destroy(a, adapter);
    }
    fn models(p: *anyopaque) []const c.Model {
        const self = cast(p);
        return self.catalog_models[0..self.catalog_count];
    }
    fn runtimeStatus(p: *anyopaque) c.RuntimeStatus {
        return cast(p).status;
    }
    fn stopLogin(self: *NativeFactory) void {
        if (self.login_instance) |instance| {
            instance.shutdown();
            destroyInstance(self, self.login_allocator.?, instance);
            self.login_instance = null;
            self.login_allocator = null;
            self.status.login = "";
        }
    }
    fn pumpSetup(p: *anyopaque) bool {
        const self = cast(p);
        const instance = self.login_instance orelse return false;
        const runtime: *Codex.Runtime = @ptrCast(@alignCast(instance.context));
        runtime.pump() catch |err| {
            self.status.reason = @errorName(err);
            self.status.readiness = .unavailable;
            self.stopLogin();
            return false;
        };
        // Login strings live in the runtime until the next explicit action.
        self.status.login = runtime.login;
        self.status.readiness = runtime.readiness;
        if (runtime.diagnostic.len != 0) self.status.reason = runtime.diagnostic;
        if (runtime.diagnostic.len != 0) {
            self.status.reason = "Sign-in failed; explicitly initiate again.";
            self.status.readiness = .unavailable;
            self.stopLogin();
            return false;
        }
        if (runtime.readiness == .ready and runtime.pending == null) {
            self.status.reason = "ChatGPT account ready; explicitly refresh catalog before sending.";
            self.stopLogin();
            return false;
        }
        if (runtime.disconnected or transport.c.spica_monotonic_ms() - self.login_started > 120000) {
            self.status.reason = "Sign-in interrupted or timed out; explicitly initiate again.";
            self.status.login = "";
            self.stopLogin();
            return false;
        }
        return true;
    }
    fn shutdownSetup(p: *anyopaque) void {
        cast(p).stopLogin();
    }
    fn action(p: *anyopaque, allocator: std.mem.Allocator, io: std.Io, request: c.RuntimeAction) !void {
        const self = cast(p);
        self.performAction(allocator, io, request) catch |err| {
            self.status.reason = @errorName(err);
            self.status.readiness = .unavailable;
            self.catalog_count = 0;
            self.catalog_authoritative = true;
            return err;
        };
    }
    fn performAction(self: *NativeFactory, allocator: std.mem.Allocator, io: std.Io, request: c.RuntimeAction) !void {
        self.status.login = "";
        self.stopLogin();
        switch (request) {
            .configure => |setup| {
                if (!std.fs.path.isAbsolute(setup.executable) or !std.fs.path.isAbsolute(setup.account_directory) or !std.fs.path.isAbsolute(setup.workspace_root) or setup.model_provider.len == 0) return error.AbsoluteRuntimePathsRequired;
                if (setup.executable.len > 4096 or setup.account_directory.len > 4096 or setup.workspace_root.len > 4096 or setup.model_provider.len > 128) return error.ConfigurationLimit;
                if (self.configs.len > 2 or std.mem.indexOfScalar(u8, setup.executable, 0) != null or std.mem.indexOfScalar(u8, setup.account_directory, 0) != null or std.mem.indexOfScalar(u8, setup.workspace_root, 0) != null or std.mem.indexOfScalar(u8, setup.model_provider, 0) != null) return error.InvalidConfiguration;
                const kind = @tagName(setup.runtime_kind);
                var index: usize = self.configs.len;
                for (self.configs, 0..) |config, i| {
                    self.owned_configs[i] = config;
                    if (std.mem.eql(u8, config.selection.runtime_kind, kind)) index = i;
                }
                if (index >= 2) return error.ConfigurationLimit;
                // Validate and canonicalize in operation storage before replacing
                // any currently configured identity.
                try std.Io.Dir.cwd().createDirPath(io, setup.account_directory);
                const account_root = try std.Io.Dir.cwd().realPathFileAlloc(io, setup.account_directory, allocator);
                defer allocator.free(account_root);
                const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, setup.workspace_root, allocator);
                defer allocator.free(workspace);
                const directory = try std.Io.Dir.cwd().openDir(io, workspace, .{});
                directory.close(io);
                if (std.mem.eql(u8, workspace, account_root)) return error.AccountDirectoryIsWorkspace;
                for (self.configs, 0..) |config, i| if (i != index and std.mem.eql(u8, config.selection.account_ref, account_root)) return error.SeparateRuntimeAccountsRequired;
                const generation = self.config_generation[index] ^ 1;
                var fixed = std.heap.FixedBufferAllocator.init(&self.config_storage[index][generation]);
                const retained = fixed.allocator();
                const codex = setup.runtime_kind == .codex;
                const environment = try retained.alloc([:0]const u8, if (codex) 7 else 9);
                environment[0] = try std.fmt.allocPrintSentinel(retained, "HOME={s}", .{account_root}, 0);
                environment[1] = try std.fmt.allocPrintSentinel(retained, "XDG_DATA_HOME={s}/data", .{account_root}, 0);
                environment[2] = try std.fmt.allocPrintSentinel(retained, "XDG_CONFIG_HOME={s}/config", .{account_root}, 0);
                environment[3] = try std.fmt.allocPrintSentinel(retained, "XDG_CACHE_HOME={s}/cache", .{account_root}, 0);
                environment[4] = try std.fmt.allocPrintSentinel(retained, "XDG_STATE_HOME={s}/state", .{account_root}, 0);
                environment[5] = if (codex) try std.fmt.allocPrintSentinel(retained, "CODEX_HOME={s}", .{account_root}, 0) else try std.fmt.allocPrintSentinel(retained, "OPENCODE_CONFIG_DIR={s}/config/opencode", .{account_root}, 0);
                environment[6] = "PATH=/usr/bin:/bin";
                if (!codex) {
                    environment[7] = try std.fmt.allocPrintSentinel(retained, "OPENCODE_TEST_HOME={s}", .{account_root}, 0);
                    environment[8] = "OPENCODE_DISABLE_CLAUDE_CODE=1";
                }
                self.owned_configs[index] = .{ .selection = .{ .runtime_kind = kind, .required_runtime_version = if (codex) "0.163.0" else "2.1.4", .model_provider = try retained.dupe(u8, setup.model_provider), .model_id = "", .effort = "", .account_ref = try retained.dupe(u8, account_root), .workspace = .{ .value = try retained.dupe(u8, workspace) } }, .executable = try retained.dupeZ(u8, setup.executable), .environment = environment };
                self.config_generation[index] = generation;
                self.configs = self.owned_configs[0..@max(self.configs.len, index + 1)];
                self.catalog_count = 0;
                self.catalog_authoritative = true;
                self.status = .{ .runtime_kind = kind, .workspace_root = self.owned_configs[index].selection.workspace.value, .reason = "Configured explicitly; refresh catalog to discover models and account readiness." };
            },
            .refresh => {
                self.catalog_count = 0;
                self.catalog_authoritative = true;
                var retained = std.heap.FixedBufferAllocator.init(&self.catalog_storage);
                const catalog = @import("catalog.zig");
                const scratch_bytes = try allocator.alloc(u8, 4 * 1024 * 1024);
                defer allocator.free(scratch_bytes);
                for (self.configs) |config| {
                    var scratch_fixed = std.heap.FixedBufferAllocator.init(scratch_bytes);
                    const scratch = scratch_fixed.allocator();
                    const codex = std.mem.eql(u8, config.selection.runtime_kind, "codex");
                    const root = try scratch.dupeZ(u8, config.selection.workspace.value);
                    var wire = try transport.Transport.init(allocator, .{ .argv = if (codex) &.{ config.executable, "app-server", "--stdio" } else &.{ config.executable, "acp" }, .cwd = root, .environment = config.environment });
                    defer wire.deinit();
                    const output = self.catalog_models[self.catalog_count..];
                    self.catalog_count += if (codex) try catalog.codex(scratch, retained.allocator(), &wire, config.selection, output) else try catalog.opencode(scratch, retained.allocator(), &wire, config.selection, root, output);
                }
                if (self.catalog_count == 0) return error.NoConfiguredModels;
                self.status.readiness = self.catalog_models[0].readiness;
                self.status.reason = self.catalog_models[0].reason;
            },
            .login => |login| {
                if (login.runtime_kind != .codex) return error.SignInUnsupported;
                self.catalog_count = 0;
                self.catalog_authoritative = true;
                for (self.configs) |config| {
                    if (!std.mem.eql(u8, config.selection.runtime_kind, "codex")) continue;
                    var selection = config.selection;
                    // Authentication does not select or infer a model.
                    selection.model_id = "authentication-only";
                    selection.effort = "authentication-only";
                    const instance = try createInstance(self, allocator, selection, config.selection.workspace.value, .{ .value = "explicit-login" }, null);
                    errdefer {
                        instance.shutdown();
                        destroyInstance(self, allocator, instance);
                    }
                    const runtime: *Codex.Runtime = @ptrCast(@alignCast(instance.context));
                    const start = transport.c.spica_monotonic_ms();
                    while (!runtime.initialized or runtime.pending != null) {
                        if (runtime.diagnostic.len != 0) return error.AccountStatusFailed;
                        try runtime.pump();
                        if (runtime.disconnected or transport.c.spica_monotonic_ms() - start > 15000) return error.InitializeTimeout;
                        _ = transport.c.spica_process_poll(&runtime.wire.process, -1, @intFromBool(runtime.wire.input_len != 0), 20);
                    }
                    if (runtime.diagnostic.len != 0) return error.AccountStatusFailed;
                    self.status.runtime_kind = "codex";
                    self.status.workspace_root = config.selection.workspace.value;
                    self.status.readiness = .unknown;
                    try runtime.startLogin(login.mode == .device);
                    self.login_instance = instance;
                    self.login_allocator = allocator;
                    self.login_started = transport.c.spica_monotonic_ms();
                    self.status.reason = "Explicit supported ChatGPT sign-in initiated; waiting for runtime URL/code.";
                    return;
                }
                return error.CodexNotConfigured;
            },
        }
    }
    pub fn asFactory(self: *NativeFactory) common.Factory {
        return .{ .context = self, .vtable = &.{ .discover = discovery, .accountStatus = account, .resolveSelection = resolve, .create = createInstance, .destroy = destroyInstance, .models = models, .runtimeStatus = runtimeStatus, .runtimeAction = action, .pumpSetup = pumpSetup, .shutdownSetup = shutdownSetup } };
    }
};
