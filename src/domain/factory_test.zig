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
        tool_requested: std.atomic.Value(bool) = .init(false),
        tool_responded: std.atomic.Value(bool) = .init(false),
        tool_result: [65536]u8 = undefined,
        tool_result_len: usize = 0,
        cancels: std.atomic.Value(u32) = .init(0),
        ready_flag: std.atomic.Value(bool) = .init(false),
        stopping: bool = false,
        stopped: bool = false,
        fn pollTool(context: *anyopaque, allocator: std.mem.Allocator) !?common.ToolCall {
            const self = cast(context);
            if (!self.tool_requested.swap(false, .acq_rel)) return null;
            return try common.clone(allocator, common.ToolCall{ .request_id_json = "73", .call_id = "dynamic-list", .name = "task.list", .arguments_json = "{}", .correlation = .{ .session = self.session } });
        }
        fn respondTool(context: *anyopaque, request: []const u8, success: bool, result: []const u8) !void {
            const self = cast(context);
            if (!std.mem.eql(u8, request, "73") or !success or result.len > self.tool_result.len) return error.InvalidToolResponse;
            @memcpy(self.tool_result[0..result.len], result);
            self.tool_result_len = result.len;
            self.tool_responded.store(true, .release);
        }
        fn cast(context: *anyopaque) *Instance {
            return @ptrCast(@alignCast(context));
        }
        fn discover(_: *anyopaque) c.Discovery {
            return .{ .capabilities = @splat(.{ .status = .supported }), .limits = .{} };
        }
        fn account(context: *anyopaque) c.Account {
            return .{ .reference = cast(context).selection.account_ref, .readiness = .unknown };
        }
        fn resolve(_: *anyopaque, selection: c.Selection) c.SelectionResult {
            return .{ .requested = selection, .effective = null, .readiness = .unknown };
        }
        fn dispatch(context: *anyopaque, _: std.mem.Allocator, request: c.Request) !c.Receipt {
            const self = cast(context);
            switch (request) {
                .open => {
                    std.debug.assert(c.equal(request.open.create.selection, self.selection));
                    std.debug.assert(std.mem.eql(u8, request.open.create.session.value, self.session.value));
                    _ = self.opens.fetchAdd(1, .release);
                    return .{ .outcome = .acknowledged, .session = .{ .id = self.session, .instance = .{ .value = self.session.value }, .upstream = .{ .value = self.session.value } } };
                },
                .start => {
                    _ = self.starts.fetchAdd(1, .release);
                },
                .cancel => {
                    _ = self.cancels.fetchAdd(1, .release);
                    self.stopping = true;
                },
                else => {},
            }
            return .{ .outcome = .acknowledged };
        }
        fn pump(context: *anyopaque) !void {
            _ = cast(context).pumps.fetchAdd(1, .release);
        }
        fn ready(context: *anyopaque) bool {
            return cast(context).ready_flag.load(.acquire);
        }
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
                for (server.bindings) |binding| if (std.mem.eql(u8, binding.session, self.session.value)) {
                    found = true;
                };
                std.debug.assert(found);
            }
            self.stopped = true;
            _ = self.owner.shutdowns.fetchAdd(1, .release);
        }
        const vtable: common.Adapter.VTable = .{ .discover = discover, .accountStatus = account, .resolveSelection = resolve, .dispatch = dispatch, .pump = pump, .poll = poll, .shutdown = shutdown, .ready = ready, .pollTool = pollTool, .respondTool = respondTool };
    };
    instances: [8]?*Instance = @splat(null),
    creates: std.atomic.Value(u32) = .init(0),
    shutdowns: std.atomic.Value(u32) = .init(0),
    destroys: std.atomic.Value(u32) = .init(0),
    fail_create: bool = false,
    auto_ready: bool = false,
    server: ?*Mcp = null,
    fn factoryCast(context: *anyopaque) *Factory {
        return @ptrCast(@alignCast(context));
    }
    fn factoryDiscover(_: *anyopaque, _: c.Selection) c.Discovery {
        return Instance.discover(undefined);
    }
    fn factoryAccount(_: *anyopaque, selection: c.Selection) c.Account {
        return .{ .reference = selection.account_ref, .readiness = .unknown };
    }
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
        instance.ready_flag.store(self.auto_ready, .release);
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
    fn handle(self: *Factory) common.Factory {
        return .{ .context = self, .vtable = &.{ .discover = factoryDiscover, .accountStatus = factoryAccount, .resolveSelection = Instance.resolve, .create = create, .destroy = destroy } };
    }
};
fn sampleSelection(workspace: []const u8) c.Selection {
    return .{ .workspace = .{ .value = workspace }, .model_provider = "fake", .model_id = "exact-model", .account_ref = "local", .effort = "high" };
}
fn open(session: []const u8, selected: c.Selection) c.Request {
    return .{ .open = .{ .create = .{ .effect = .{ .value = session }, .session = .{ .value = session }, .selection = selected } } };
}

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

const Consumer = struct {
    host: *domain.Host = undefined,
    arena: std.heap.ArenaAllocator,
    event: std.Io.Event = .unset,
    fn wake(context: ?*anyopaque) void {
        (@as(*Consumer, @ptrCast(@alignCast(context.?)))).event.set(std.testing.io);
    }
    fn next(self: *Consumer) !t.Output {
        var outputs: [1]t.Output = undefined;
        const storage = try self.arena.allocator().alloc(u8, 1024 * 1024);
        while (true) {
            self.event.reset();
            const drained = self.host.drain(&outputs, storage);
            if (drained.output_count != 0) return outputs[0];
            if (drained.required_bytes_for_next != 0) return error.OutputTooLarge;
            try self.event.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } });
        }
    }
    fn command(self: *Consumer, command_value: t.CommandEnvelope) !t.Receipt {
        _ = try self.host.submit(command_value);
        const output = try self.next();
        if (output != .command_receipt) return error.ExpectedReceipt;
        return output.command_receipt.receipt;
    }
    fn query(self: *Consumer, query_value: t.Query) !t.QueryPage {
        _ = try self.host.query(query_value);
        const output = try self.next();
        if (output != .query_page) return error.ExpectedPage;
        return output.query_page.page;
    }
    fn register(self: *Consumer, project: t.ProjectId, path: []const u8, key: []const u8) !c.WorkspaceId {
        const registered = try self.command(.{ .command_id = .{ .value = key }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try domain.workspace_binding.capture(self.arena.allocator(), std.testing.io, path) } } });
        try std.testing.expectEqual(.accepted, registered.outcome);
        return registered.entity_ids.workspace.?;
    }
    fn start(self: *Consumer, project: t.ProjectId, workspace: c.WorkspaceId) !t.Receipt {
        const thread = (try self.command(.{ .command_id = .{ .value = "consumer-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
        return self.command(.{ .command_id = .{ .value = "consumer-start" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "coordinate", .selection = sampleSelection(workspace.value) } } });
    }
    fn http(self: *Consumer, bridge: common.Bridge, token: []const u8, body: []const u8) !struct { status: []const u8, body: []const u8 } {
        const allocator = self.arena.allocator();
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
        const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "curl", "--silent", "--show-error", "--max-time", "5", "--write-out", "\n%{http_code}", "-X", "POST", "-H", "Content-Type: application/json", "-H", auth, "--data-binary", body, bridge.url }, .stdout_limit = .limited(65536), .stderr_limit = .limited(4096) });
        if (result.term != .exited or result.term.exited != 0) return error.HttpConsumerFailed;
        const split = std.mem.lastIndexOfScalar(u8, result.stdout, '\n') orelse return error.InvalidHttpResponse;
        return .{ .status = result.stdout[split + 1 ..], .body = result.stdout[0..split] };
    }
    fn call(self: *Consumer, bridge: common.Bridge, name: []const u8, args: anytype) !std.json.Value {
        const allocator = self.arena.allocator();
        const request = try t.encode(.{ .jsonrpc = "2.0", .id = 42, .method = "tools/call", .params = .{ .name = name, .arguments = args } }, try allocator.alloc(u8, 32768));
        const response = try self.http(bridge, bridge.token, request);
        try std.testing.expectEqualStrings("200", response.status);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, response.body, .{});
        try std.testing.expectEqual(@as(i64, 42), parsed.object.get("id").?.integer);
        return parsed.object.get("result") orelse return error.MissingToolResult;
    }
    fn receipt(result: std.json.Value, allocator: std.mem.Allocator) !t.Receipt {
        return t.decode(t.Receipt, result.object.get("content").?.array.items[0].object.get("text").?.string, allocator);
    }
};

test "public factory Host authenticates MCP durable retries and pumps three isolated sessions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "other", .default_dir);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..n];
    var consumer: Consumer = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    const allocator = consumer.arena.allocator();
    var factory: Factory = .{ .auto_ready = true };
    consumer.host = try domain.Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = root, .factory = factory.handle(), .selection = sampleSelection(""), .workspace_root = root, .wake = Consumer.wake, .wake_context = &consumer });
    var live = true;
    defer if (live) consumer.host.destroy();
    const project = (try consumer.command(.{ .command_id = .{ .value = "consumer-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "factory consumer" } } })).entity_ids.project.?;
    const workspace = try consumer.register(project, root, "consumer-workspace");
    const alias = try consumer.register(project, root, "consumer-alias");
    const other_root = try std.fmt.allocPrint(allocator, "{s}/other", .{root});
    const other = try consumer.register(project, other_root, "consumer-other");
    const parent = try consumer.start(project, workspace);
    try std.testing.expectEqual(.accepted, parent.outcome);
    _ = try consumer.query(.{ .runs = .{ .thread = parent.entity_ids.thread.? } });
    try std.testing.expectEqual(@as(u32, 1), factory.creates.load(.acquire));
    const bridge = factory.instances[0].?.bridge;
    const unauthorized = try consumer.http(bridge, "short", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    try std.testing.expectEqualStrings("401", unauthorized.status);
    const initialized = try consumer.http(bridge, bridge.token, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try std.testing.expectEqualStrings("202", initialized.status);
    const initialize = try consumer.http(bridge, bridge.token, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}");
    try std.testing.expect(std.mem.indexOf(u8, initialize.body, "2025-03-26") != null);
    const initialize_json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, initialize.body, .{});
    try std.testing.expect(initialize_json.object.get("result").?.object.get("capabilities").?.object.get("tools").? == .object);
    const tools = try consumer.http(bridge, bridge.token, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/list\"}");
    try std.testing.expect(std.mem.indexOf(u8, tools.body, "task.delegate") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.body, "task.result") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.body, "task.review") != null);
    var packet: t.orchestration.Packet = .{ .purpose = "child one", .prompt = "first exact work", .selection = sampleSelection(workspace.value), .owned_paths = &.{"src/a"}, .acceptance = "check", .result_location = "first-evidence" };
    packet.selection.model_id = "child-one-model";
    packet.selection.account_ref = "child-one-account";
    const first_args = .{ .request_key = "delegate-first", .packet = packet };
    const first = try Consumer.receipt(try consumer.call(bridge, "task.delegate", first_args), allocator);
    try std.testing.expectEqual(.accepted, first.outcome);
    const retry = try Consumer.receipt(try consumer.call(bridge, "task.delegate", first_args), allocator);
    try std.testing.expectEqualStrings(first.entity_ids.run.?.value, retry.entity_ids.run.?.value);
    packet.selection.workspace = alias;
    packet.owned_paths = &.{"src/a/file.zig"};
    const overlap = try Consumer.receipt(try consumer.call(bridge, "task.delegate", .{ .request_key = "alias-overlap", .packet = packet }), allocator);
    try std.testing.expectEqual(t.Reason.workspace_mismatch, overlap.reason.?);
    packet.selection.workspace = other;
    packet.selection.model_id = "child-two-model";
    packet.selection.account_ref = "child-two-account";
    packet.owned_paths = &.{"src/a"};
    packet.detached = true;
    packet.budget.max_requests = 2;
    const second = try Consumer.receipt(try consumer.call(bridge, "task.delegate", .{ .request_key = "delegate-second", .packet = packet }), allocator);
    try std.testing.expectEqual(.accepted, second.outcome);
    _ = try consumer.query(.{ .task_list = .{ .parent = parent.entity_ids.run.? } });
    try std.testing.expectEqual(@as(u32, 3), factory.creates.load(.acquire));
    for (factory.instances[0..3], 0..) |optional, index| {
        const instance = optional.?;
        try std.testing.expect(instance.pumps.load(.acquire) > 0);
        try std.testing.expectEqual(@as(u32, 1), instance.opens.load(.acquire));
        try std.testing.expectEqual(@as(u32, 1), instance.starts.load(.acquire));
        try std.testing.expectEqualStrings(if (index == 2) other_root else root, instance.cwd);
    }
    try std.testing.expectEqualStrings("child-one-account", factory.instances[1].?.selection.account_ref);
    try std.testing.expectEqualStrings("child-two-model", factory.instances[2].?.selection.model_id);
    const steering_args = .{ .request_key = "send-second", .task_id = second.entity_ids.run.?.value, .content = "one durable steering request" };
    const steering = try Consumer.receipt(try consumer.call(bridge, "task.send", steering_args), allocator);
    try std.testing.expectEqual(.accepted, steering.outcome);
    const steering_retry = try Consumer.receipt(try consumer.call(bridge, "task.send", steering_args), allocator);
    try std.testing.expectEqual(steering.commit_sequence, steering_retry.commit_sequence);
    const over_budget = try Consumer.receipt(try consumer.call(bridge, "task.send", .{ .request_key = "send-over-budget", .task_id = second.entity_ids.run.?.value, .content = "must not dispatch" }), allocator);
    try std.testing.expectEqual(t.Reason.admission_limit, over_budget.reason.?);
    const denied = try consumer.call(factory.instances[2].?.bridge, "task.cancel", .{ .request_key = "steal", .task_id = first.entity_ids.run.?.value, .reason = "unauthorized sibling" });
    try std.testing.expect(denied.object.get("isError").?.bool);
    const conflicting = try consumer.call(bridge, "task.cancel", .{ .request_key = "delegate-first", .task_id = first.entity_ids.run.?.value, .reason = "conflicting key" });
    try std.testing.expect(conflicting.object.get("isError").?.bool);
    const cancelled = try Consumer.receipt(try consumer.call(bridge, "task.cancel", .{ .request_key = "cancel-first", .task_id = first.entity_ids.run.?.value, .reason = "independent cancellation" }), allocator);
    try std.testing.expectEqual(.accepted, cancelled.outcome);
    const rows = try consumer.query(.{ .task_list = .{ .parent = parent.entity_ids.run.? } });
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqual(.cancelled, rows.items[0].task.state);
    try std.testing.expectEqual(.streaming, rows.items[1].task.state);
    try std.testing.expectEqual(@as(u32, 1), factory.shutdowns.load(.acquire));
    const parent_instance = factory.instances[0].?;
    parent_instance.tool_requested.store(true, .release);
    var dynamic_attempts: usize = 0;
    while (!parent_instance.tool_responded.load(.acquire) and dynamic_attempts < 128) : (dynamic_attempts += 1)
        _ = try consumer.query(.{ .task_list = .{ .parent = parent.entity_ids.run.? } });
    try std.testing.expect(parent_instance.tool_responded.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, parent_instance.tool_result[0..parent_instance.tool_result_len], second.entity_ids.run.?.value) != null);
    const saved_result: t.orchestration.Result = .{ .candidate = "child-one-candidate", .evidence = "actual-consumer-checks", .summary = "cancelled independently" };
    const result_receipt = try Consumer.receipt(try consumer.call(bridge, "task.result", .{ .request_key = "child-result", .task_id = first.entity_ids.run.?.value, .candidate = saved_result.candidate, .evidence = saved_result.evidence, .summary = saved_result.summary }), allocator);
    try std.testing.expectEqual(.accepted, result_receipt.outcome);
    const review_receipt = try Consumer.receipt(try consumer.call(bridge, "task.review", .{ .request_key = "child-review", .task_id = first.entity_ids.run.?.value, .candidate = saved_result.candidate, .evidence = saved_result.evidence, .disposition = "accepted" }), allocator);
    try std.testing.expectEqual(.accepted, review_receipt.outcome);
    const wait_result = try consumer.call(bridge, "task.wait", .{ .task_id = first.entity_ids.run.?.value });
    try std.testing.expect(!wait_result.object.get("isError").?.bool);
    try std.testing.expect(std.mem.indexOf(u8, wait_result.object.get("content").?.array.items[0].object.get("text").?.string, saved_result.candidate) != null);
    const current_parent = (try consumer.query(.{ .runs = .{ .thread = parent.entity_ids.thread.? } })).items[0].run;
    const cancel_parent = try consumer.command(.{ .command_id = .{ .value = "cancel-parent" }, .target = .{ .run = parent.entity_ids.run.? }, .expected_revision = .{ .revision = current_parent.revision }, .payload = .{ .run_cancel = .{ .reason = "attached cancellation only" } } });
    try std.testing.expectEqual(.accepted, cancel_parent.outcome);
    const detached = try consumer.query(.{ .task_wait = second.entity_ids.run.? });
    try std.testing.expectEqual(.streaming, detached.items[0].task.state);
    consumer.host.destroy();
    live = false;
    try std.testing.expectEqual(@as(u32, 3), factory.shutdowns.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), factory.destroys.load(.acquire));
    consumer.host = try domain.Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = root, .factory = factory.handle(), .selection = sampleSelection(""), .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const recovered = try consumer.query(.{ .task_list = .{ .parent = parent.entity_ids.run.? } });
    try std.testing.expectEqual(.cancelled, recovered.items[0].task.state);
    try std.testing.expectEqualStrings("child-one-candidate", recovered.items[0].task.task.result.?.candidate);
    try std.testing.expectEqual(.interrupted, recovered.items[1].task.state);
    try std.testing.expectEqual(@as(u32, 3), factory.creates.load(.acquire));
}

test "Host cancellation before readiness never opens and partial create stays unknown after reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..n];
    var consumer: Consumer = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    var factory: Factory = .{};
    consumer.host = try domain.Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = root, .factory = factory.handle(), .selection = sampleSelection(""), .wake = Consumer.wake, .wake_context = &consumer });
    var live = true;
    defer if (live) consumer.host.destroy();
    const project = (try consumer.command(.{ .command_id = .{ .value = "consumer-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "cancel initialization" } } })).entity_ids.project.?;
    const workspace = try consumer.register(project, root, "consumer-workspace");
    const parent = try consumer.start(project, workspace);
    const active = (try consumer.query(.{ .runs = .{ .thread = parent.entity_ids.thread.? } })).items[0].run;
    try std.testing.expectEqual(@as(u32, 0), factory.instances[0].?.opens.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), factory.instances[0].?.starts.load(.acquire));
    const cancel = try consumer.command(.{ .command_id = .{ .value = "cancel-initialize" }, .target = .{ .run = parent.entity_ids.run.? }, .expected_revision = .{ .revision = active.revision }, .payload = .{ .run_cancel = .{ .reason = "cancel before ready" } } });
    try std.testing.expectEqual(.accepted, cancel.outcome);
    const cancelled = (try consumer.query(.{ .runs = .{ .thread = parent.entity_ids.thread.? } })).items[0].run;
    try std.testing.expectEqual(.cancelled, cancelled.state);
    try std.testing.expectEqual(@as(u32, 1), factory.destroys.load(.acquire));
    consumer.host.destroy();
    live = false;
    factory.fail_create = true;
    consumer.host = try domain.Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = root, .factory = factory.handle(), .selection = sampleSelection(""), .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const failed = try consumer.command(.{ .command_id = .{ .value = "partial-create-send" }, .target = .{ .thread = parent.entity_ids.thread.? }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "partial failure", .selection = sampleSelection(workspace.value) } } });
    try std.testing.expectEqual(.accepted, failed.outcome);
    const effects = try consumer.query(.{ .effects = .{ .run = failed.entity_ids.run.? } });
    try std.testing.expectEqual(.unknown, effects.items[0].effect.state);
    try std.testing.expectEqual(.planned, effects.items[1].effect.state);
    consumer.host.destroy();
    live = false;
    consumer.host = try domain.Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = root, .factory = factory.handle(), .selection = sampleSelection(""), .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const recovered = try consumer.query(.{ .effects = .{ .run = failed.entity_ids.run.? } });
    try std.testing.expectEqual(.unknown, recovered.items[0].effect.state);
    try std.testing.expectEqual(@as(u32, 1), factory.creates.load(.acquire));
}

fn gitFixture(allocator: std.mem.Allocator, root: []const u8, args: []const []const u8) !void {
    var argv: [20][]const u8 = undefined;
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = root;
    @memcpy(argv[3..][0..args.len], args);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = argv[0 .. args.len + 3], .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
    if (result.term != .exited or result.term.exited != 0) return error.GitFixtureFailed;
}

test "real workspace Git capture rejects changed checkouts aliases and shared metadata ownership" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try temporary.dir.createDir(std.testing.io, "repo", .default_dir);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = try std.fmt.allocPrint(allocator, "{s}/repo", .{path_buffer[0..n]});
    const linked = try std.fmt.allocPrint(allocator, "{s}/linked", .{path_buffer[0..n]});
    try gitFixture(allocator, root, &.{ "init", "--initial-branch=fixture" });
    try gitFixture(allocator, root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "base" });
    const binding = try domain.workspace_binding.capture(allocator, std.testing.io, root);
    try std.testing.expect(!binding.non_git);
    try std.testing.expect(try domain.workspace_binding.verify(allocator, std.testing.io, binding));
    try gitFixture(allocator, root, &.{ "worktree", "add", "-b", "linked-fixture", linked });
    const linked_binding = try domain.workspace_binding.capture(allocator, std.testing.io, linked);
    try std.testing.expectEqualStrings(binding.repository_identity, linked_binding.repository_identity);
    try std.testing.expect(!std.mem.eql(u8, binding.checkout_identity, linked_binding.checkout_identity));
    try std.testing.expect(try domain.workspace_binding.ownershipOverlaps(allocator, binding, ".git", linked_binding, ".git"));
    try std.testing.expect(!try domain.workspace_binding.ownershipOverlaps(allocator, binding, "src/a", linked_binding, "src/a"));
    try std.testing.expect(!try domain.workspace_binding.ownershipOverlaps(allocator, binding, "src/a", binding, "src/ab"));
    try std.testing.expect(try domain.workspace_binding.ownershipOverlaps(allocator, binding, "src/a", binding, "src/a/file"));
    try std.testing.expect(!try domain.workspace_binding.validOwnedPath(allocator, binding, "src/../escape"));
    try std.testing.expect(!try domain.workspace_binding.validOwnedPath(allocator, binding, "src//file"));
    try temporary.dir.symLink(std.testing.io, "/tmp", "repo/escape", .{});
    try std.testing.expect(!try domain.workspace_binding.validOwnedPath(allocator, binding, "escape/write"));
    try gitFixture(allocator, root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "changed" });
    try std.testing.expect(!try domain.workspace_binding.verify(allocator, std.testing.io, binding));
}
