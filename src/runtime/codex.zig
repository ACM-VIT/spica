//! Codex 0.163.0 app-server, experimental dynamicTools explicitly negotiated.
const std = @import("std");
const c = @import("../contract.zig");
const adapter = @import("adapter.zig");
const transport = @import("transport.zig");
const Value = std.json.Value;
fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn text(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub const Config = struct {
    selection: c.Selection,
    cwd: []const u8,
    instance: []const u8,
    /// Only advertise tools when a consumer actually drains/responds to tool calls.
    tools: []const Tool = &.{},
    tool_bindings: []const ToolBinding = &.{},
};
pub const Tool = struct { type: []const u8 = "function", name: []const u8, description: []const u8, inputSchema: Value };
pub const ToolBinding = struct { wire_name: []const u8, application_name: []const u8 };
pub const ToolCall = adapter.ToolCall;
pub const Runtime = RuntimeFor(transport.Transport);
pub fn RuntimeFor(comptime T: type) type {
    return struct {
        const Self = @This();
        const Operation = enum { initialize, account, login, open, restore, start, cancel };
        allocator: std.mem.Allocator,
        state: std.heap.FixedBufferAllocator,
        state_bytes: []u8,
        wire: *T,
        config: Config,
        initialized: bool = false,
        readiness: c.Readiness = .unknown,
        login: []const u8 = "",
        diagnostic: []const u8 = "",
        next_id: u64 = 1,
        pending: ?struct { id: u64, kind: Operation, correlation: c.Correlation } = null,
        session: ?c.Session = null,
        correlation: c.Correlation = .{ .session = .{ .value = "" } },
        turn: []const u8 = "",
        offset: u64 = 0,
        sequence: u64 = 0,
        approval: ?struct { id_json: []const u8, evidence: c.ApprovalEvidence } = null,
        tool: ?ToolCall = null,
        queue: [16]c.Observation = undefined,
        storage: [16][8192]u8 = undefined,
        head: usize = 0,
        count: usize = 0,
        disconnected: bool = false,
        pub fn init(allocator: std.mem.Allocator, wire: *T, config: Config) !Self {
            if (!std.fs.path.isAbsolute(config.cwd)) return error.AbsoluteWorkspaceRequired;
            // Runtime-retained protocol identity/callback state has a hard byte cap.
            const state_bytes = try allocator.alloc(u8, 1048576);
            errdefer allocator.free(state_bytes);
            var self: Self = .{ .allocator = allocator, .wire = wire, .state = std.heap.FixedBufferAllocator.init(state_bytes), .state_bytes = state_bytes, .config = config };
            self.config.selection = try adapter.clone(self.state.allocator(), config.selection);
            try self.rpc(.initialize, .{ .clientInfo = .{ .name = "spica", .version = "1" }, .capabilities = .{ .experimentalApi = true } }, self.correlation);
            return self;
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.state_bytes);
        }
        fn rpc(self: *Self, kind: Operation, params: anytype, correlation: c.Correlation) !void {
            if (self.pending != null) return error.RequestPending;
            const method: []const u8 = switch (kind) {
                .initialize => "initialize",
                .account => "account/read",
                .login => "account/login/start",
                .open => "thread/start",
                .restore => "thread/resume",
                .start => "turn/start",
                .cancel => "turn/interrupt",
            };
            const bytes = try std.json.Stringify.valueAlloc(self.allocator, .{ .id = self.next_id, .method = method, .params = params }, .{});
            defer self.allocator.free(bytes);
            try self.wire.send(bytes);
            self.pending = .{ .id = self.next_id, .kind = kind, .correlation = try adapter.clone(self.state.allocator(), correlation) };
            self.next_id += 1;
        }
        pub fn startLogin(self: *Self, device_code: bool) !void {
            if (!self.initialized) return error.NotInitialized;
            try self.rpc(.login, .{ .type = if (device_code) @as([]const u8, "chatgptDeviceCode") else "chatgpt" }, self.correlation);
        }
        pub fn discover(_: *Self) c.Discovery {
            var caps = [_]c.CapabilityInfo{.{ .status = .unsupported, .evidence = "Codex adapter unsupported surface" }} ** @typeInfo(c.Capability).@"enum".fields.len;
            inline for ([_]c.Capability{ .create, .attach, .start, .stream, .tools, .approval, .cancel, .selection, .workspace }) |cap| caps[@intFromEnum(cap)] = .{ .status = .supported, .evidence = "Codex 0.163.0 app-server protocol" };
            caps[@intFromEnum(c.Capability.coordinator_bridge)] = .{ .status = .unknown, .evidence = "dynamicTools protocol available; live app bridge acceptance required" };
            return .{ .runtime_kind = "codex", .runtime_version = "0.163.0", .capabilities = caps, .limits = .{} };
        }
        pub fn accountStatus(self: *Self) c.Account {
            return .{ .reference = self.config.selection.account_ref, .readiness = self.readiness };
        }
        fn matchesSelection(self: *Self, selection: c.Selection) bool {
            var expected = self.config.selection;
            expected.workspace = selection.workspace;
            return c.equal(selection, expected);
        }
        pub fn resolveSelection(self: *Self, selection: c.Selection) c.SelectionResult {
            return .{ .requested = selection, .effective = null, .readiness = if (self.matchesSelection(selection)) self.readiness else .unavailable };
        }
        pub fn dispatch(self: *Self, allocator: std.mem.Allocator, request: c.Request) !c.Receipt {
            if (self.disconnected) return .{ .outcome = .rejected, .detail = "Codex disconnected" };
            if (!self.initialized or self.pending != null) return .{ .outcome = .rejected, .detail = "Codex initialization/request pending" };
            switch (request) {
                .open => |open| switch (open) {
                    .create => |p| {
                        if (self.readiness != .ready or !self.matchesSelection(p.selection)) return .{ .outcome = .rejected, .detail = "Codex account or selection unavailable" };
                        if (self.session != null) return .{ .outcome = .rejected, .detail = "Runtime already owns a session" };
                        self.config.selection = try adapter.clone(self.state.allocator(), p.selection);
                        self.correlation = try adapter.clone(self.state.allocator(), c.Correlation{ .session = p.session, .effect = p.effect });
                        try self.rpc(.open, .{ .model = p.selection.model_id, .modelProvider = p.selection.model_provider, .cwd = self.config.cwd, .approvalPolicy = "on-request", .sandbox = "workspace-write", .allowProviderModelFallback = false, .config = .{ .model_reasoning_effort = p.selection.effort }, .dynamicTools = self.config.tools }, self.correlation);
                    },
                    .existing => |p| try self.restore(p.session),
                },
                .attach => |p| try self.restore(p.session),
                .start => |p| {
                    if (p.correlation.run == null or p.correlation.effect == null or self.session == null or !eq(p.correlation.session.value, self.session.?.id.value) or self.turn.len != 0) return error.InvalidCorrelation;
                    self.correlation = try adapter.clone(self.state.allocator(), p.correlation);
                    self.offset = 0;
                    try self.rpc(.start, .{ .threadId = self.session.?.upstream.value, .input = .{.{ .type = "text", .text = p.prompt }}, .model = self.config.selection.model_id, .effort = self.config.selection.effort, .cwd = self.config.cwd }, self.correlation);
                },
                .cancel => |p| {
                    if (self.turn.len == 0 or !eq(p.correlation.session.value, self.correlation.session.value) or !c.equal(p.correlation.run, self.correlation.run)) return error.InvalidCorrelation;
                    try self.rpc(.cancel, .{ .threadId = self.session.?.upstream.value, .turnId = self.turn }, p.correlation);
                },
                .respond_approval => |p| {
                    const approval = self.approval orelse return error.InvalidCorrelation;
                    if (!c.equal(p.correlation.session, approval.evidence.correlation.session) or !c.equal(p.correlation.run, approval.evidence.correlation.run) or !c.equal(p.correlation.tool, approval.evidence.correlation.tool) or !c.equal(p.correlation.approval, approval.evidence.correlation.approval) or !eq(p.action_digest, approval.evidence.action_digest)) return error.InvalidCorrelation;
                    try self.reply(approval.id_json, .{ .decision = if (p.decision == .allow) @as([]const u8, "accept") else "decline" });
                    self.approval = null;
                },
                else => return .{ .outcome = .rejected, .detail = "Codex operation not supported" },
            }
            return try adapter.clone(allocator, c.Receipt{ .outcome = .acknowledged });
        }
        fn restore(self: *Self, session: c.Session) !void {
            if (self.session != null or self.readiness != .ready) return error.SessionUnavailable;
            self.session = try adapter.clone(self.state.allocator(), session);
            self.correlation = .{ .session = self.session.?.id };
            try self.rpc(.restore, .{ .threadId = session.upstream.value, .model = self.config.selection.model_id, .modelProvider = self.config.selection.model_provider, .cwd = self.config.cwd, .config = .{ .model_reasoning_effort = self.config.selection.effort } }, self.correlation);
        }
        fn reply(self: *Self, id_json: []const u8, result: anytype) !void {
            const body = try std.json.Stringify.valueAlloc(self.allocator, result, .{});
            defer self.allocator.free(body);
            const bytes = try std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"result\":{s}}}", .{ id_json, body });
            defer self.allocator.free(bytes);
            try self.wire.send(bytes);
        }
        pub fn pollTool(self: *Self, allocator: std.mem.Allocator) !?ToolCall {
            return if (self.tool) |call| try adapter.clone(allocator, call) else null;
        }
        pub fn respondTool(self: *Self, request_id_json: []const u8, success: bool, result: []const u8) !void {
            const call = self.tool orelse return error.InvalidCorrelation;
            if (!eq(call.request_id_json, request_id_json)) return error.InvalidCorrelation;
            try self.reply(request_id_json, .{ .success = success, .contentItems = .{.{ .type = "inputText", .text = result }} });
            self.tool = null;
        }
        fn emit(self: *Self, body: @FieldType(c.Observation, "body")) !void {
            if (self.count == self.queue.len) return error.QueueFull;
            const index = (self.head + self.count) % self.queue.len;
            var fixed = std.heap.FixedBufferAllocator.init(&self.storage[index]);
            self.sequence += 1;
            var id: [64]u8 = undefined;
            const event = try std.fmt.bufPrint(&id, "codex-{d}", .{self.sequence});
            self.queue[index] = try adapter.clone(fixed.allocator(), c.Observation{ .correlation = self.correlation, .upstream_event = event, .sequence = self.sequence, .runtime_version = "0.163.0", .body = body });
            self.count += 1;
        }
        pub fn poll(self: *Self, allocator: std.mem.Allocator) !?c.Observation {
            if (self.count == 0) return null;
            const result = try adapter.clone(allocator, self.queue[self.head]);
            self.head = (self.head + 1) % self.queue.len;
            self.count -= 1;
            return result;
        }
        pub fn pump(self: *Self) !void {
            self.wire.pump() catch |err| {
                try self.disconnect(@errorName(err));
                return err;
            };
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            while (self.count < self.queue.len - 2) {
                const line = try self.wire.poll(arena.allocator()) orelse break;
                const parsed = std.json.parseFromSlice(Value, arena.allocator(), line, .{ .allocate = .alloc_always }) catch |err| {
                    try self.disconnect(@errorName(err));
                    return err;
                };
                self.receive(parsed.value) catch |err| {
                    try self.disconnect(@errorName(err));
                    return err;
                };
                _ = arena.reset(.retain_capacity);
            }
            if (self.wire.exited) try self.disconnect("Codex process exited");
        }
        fn disconnect(self: *Self, reason: []const u8) !void {
            if (self.disconnected) return;
            if (self.correlation.session.value.len != 0) try self.emit(.{ .disconnect = .{ .reason = reason, .continuity = .unknown } });
            self.disconnected = true;
            self.approval = null;
            self.tool = null;
            self.readiness = .unavailable;
        }
        fn receive(self: *Self, value: Value) !void {
            const method = text(field(value, "method"));
            const params = field(value, "params");
            if (method.len == 0) {
                const pending = self.pending orelse return error.UnexpectedResponse;
                const id = field(value, "id");
                if (id != .integer or id.integer != pending.id) return error.InvalidCorrelation;
                self.pending = null;
                const failure = field(value, "error");
                if (failure != .null) {
                    self.diagnostic = try std.json.Stringify.valueAlloc(self.state.allocator(), failure, .{});
                    if (self.correlation.session.value.len != 0) {
                        var end = @min(self.diagnostic.len, 2048);
                        while (end < self.diagnostic.len and end > 0 and self.diagnostic[end] & 0xc0 == 0x80) end -= 1;
                        try self.emit(.{ .failure = .{ .code = "rpc_error", .detail = self.diagnostic[0..end] } });
                    }
                    return;
                }
                const result = field(value, "result");
                switch (pending.kind) {
                    .initialize => {
                        if (std.mem.indexOf(u8, text(field(result, "userAgent")), "0.163.0") == null) return error.RuntimeVersionMismatch;
                        self.initialized = true;
                        try self.wire.send("{\"method\":\"initialized\",\"params\":{}}");
                        try self.rpc(.account, .{ .refreshToken = false }, self.correlation);
                    },
                    .account => {
                        const account = field(result, "account");
                        self.readiness = if (eq(text(field(account, "type")), "chatgpt")) .ready else .unavailable;
                    },
                    .login => {
                        self.login = try std.json.Stringify.valueAlloc(self.state.allocator(), result, .{});
                    },
                    .open, .restore => {
                        if (!eq(text(field(result, "model")), self.config.selection.model_id) or !eq(text(field(result, "modelProvider")), self.config.selection.model_provider) or !eq(text(field(result, "cwd")), self.config.cwd)) return error.SelectionMismatch;
                        const thread_id = text(field(field(result, "thread"), "id"));
                        if (thread_id.len == 0) return error.InvalidSession;
                        if (self.session) |session| {
                            if (!eq(session.upstream.value, thread_id)) return error.InvalidSession;
                        }
                        self.session = try adapter.clone(self.state.allocator(), c.Session{ .id = self.correlation.session, .instance = .{ .value = self.config.instance }, .upstream = .{ .value = thread_id } });
                        try self.emit(.{ .session = self.session.? });
                        const effort = text(field(result, "reasoningEffort"));
                        if (!eq(effort, self.config.selection.effort)) return error.SelectionMismatch;
                        try self.emit(.{ .selection = .{ .requested = self.config.selection, .effective = self.config.selection, .readiness = self.readiness } });
                    },
                    .start => {
                        const turn_id = text(field(field(result, "turn"), "id"));
                        if (turn_id.len == 0) return error.InvalidTurn;
                        if (self.turn.len != 0 and !eq(self.turn, turn_id)) return error.InvalidCorrelation;
                        self.turn = try self.state.allocator().dupe(u8, turn_id);
                        self.correlation.upstream_turn = .{ .value = self.turn };
                    },
                    .cancel => {},
                }
                return;
            }
            if (eq(method, "account/login/completed") or eq(method, "account/updated")) {
                if (self.pending == null) try self.rpc(.account, .{ .refreshToken = false }, self.correlation);
                return;
            }
            const thread_id = text(field(params, "threadId"));
            if (self.session == null or !eq(thread_id, self.session.?.upstream.value)) return;
            const turn_id = text(field(params, "turnId"));
            if (turn_id.len != 0 and self.turn.len != 0 and !eq(turn_id, self.turn)) return error.InvalidCorrelation;
            if (eq(method, "turn/started")) {
                const started = text(field(field(params, "turn"), "id"));
                if (started.len == 0 or self.correlation.run == null or (self.turn.len != 0 and !eq(self.turn, started))) return error.InvalidCorrelation;
                if (self.turn.len == 0) self.turn = try self.state.allocator().dupe(u8, started);
                self.correlation.upstream_turn = .{ .value = self.turn };
            } else if (eq(method, "item/agentMessage/delta")) {
                const delta = text(field(params, "delta"));
                var start: usize = 0;
                while (start < delta.len) {
                    var end = @min(start + 2048, delta.len);
                    while (end < delta.len and end > start and delta[end] & 0xc0 == 0x80) end -= 1;
                    if (end == start) return error.InvalidUtf8;
                    try self.emit(.{ .chunk = .{ .message = .{ .value = text(field(params, "itemId")) }, .block = .{ .value = text(field(params, "itemId")) }, .offset = self.offset, .text = delta[start..end] } });
                    self.offset += end - start;
                    start = end;
                }
            } else if (eq(method, "item/started") or eq(method, "item/completed")) {
                const item = field(params, "item");
                const kind = text(field(item, "type"));
                if (eq(kind, "commandExecution") or eq(kind, "fileChange") or eq(kind, "mcpToolCall") or eq(kind, "dynamicToolCall")) {
                    const previous = self.correlation;
                    self.correlation.tool = .{ .value = text(field(item, "id")) };
                    defer self.correlation = previous;
                    const encoded = try std.json.Stringify.valueAlloc(self.allocator, item, .{});
                    defer self.allocator.free(encoded);
                    if (encoded.len > 2048) return error.ToolFrameTooLarge;
                    if (eq(method, "item/started")) try self.emit(.{ .tool_started = .{ .name = kind, .action_digest = encoded } }) else try self.emit(.{ .tool_completed = .{ .outcome = if (eq(text(field(item, "status")), "completed")) .succeeded else .unknown, .result = encoded } });
                }
            } else if (eq(method, "turn/completed")) {
                const status = text(field(field(params, "turn"), "status"));
                if (eq(status, "completed")) try self.emit(.completed) else if (eq(status, "interrupted")) try self.emit(.{ .cancelled = .{ .tools_stopped = false } }) else try self.emit(.{ .failure = .{ .code = status, .detail = "Codex turn did not complete" } });
                self.turn = "";
                self.approval = null;
                self.tool = null;
            } else if (eq(method, "item/commandExecution/requestApproval") or eq(method, "item/fileChange/requestApproval")) {
                if (self.approval != null) return error.TooManyApprovals;
                const a = self.state.allocator();
                const id_json = try std.json.Stringify.valueAlloc(a, field(value, "id"), .{});
                var correlation = self.correlation;
                correlation.upstream_request = id_json;
                correlation.tool = .{ .value = try a.dupe(u8, text(field(params, "itemId"))) };
                correlation.approval = .{ .value = id_json };
                const evidence: c.ApprovalEvidence = .{ .correlation = correlation, .workspace = self.config.selection.workspace, .action_digest = try std.json.Stringify.valueAlloc(a, params, .{}), .scope = method };
                self.approval = .{ .id_json = id_json, .evidence = evidence };
                const previous = self.correlation;
                self.correlation = correlation;
                defer self.correlation = previous;
                try self.emit(.{ .approval = evidence });
            } else if (eq(method, "item/tool/call")) {
                if (self.tool != null) return error.TooManyToolCalls;
                if (self.correlation.run == null or self.correlation.session.value.len == 0 or self.turn.len == 0 or !eq(turn_id, self.turn) or text(field(params, "callId")).len == 0 or text(field(params, "tool")).len == 0 or (field(value, "id") != .integer and field(value, "id") != .string)) return error.InvalidCorrelation;
                const a = self.state.allocator();
                const wire_name = text(field(params, "tool"));
                var application_name: ?[]const u8 = null;
                for (self.config.tools) |registered| {
                    if (eq(registered.name, wire_name)) application_name = registered.name;
                }
                for (self.config.tool_bindings) |binding| {
                    if (eq(binding.wire_name, wire_name)) application_name = binding.application_name;
                }
                const name = application_name orelse return error.UnknownTool;
                self.tool = .{ .request_id_json = try std.json.Stringify.valueAlloc(a, field(value, "id"), .{}), .call_id = try a.dupe(u8, text(field(params, "callId"))), .name = try a.dupe(u8, name), .arguments_json = try std.json.Stringify.valueAlloc(a, field(params, "arguments"), .{}), .correlation = self.correlation };
            } else if (field(value, "id") != .null) {
                const id_json = try std.json.Stringify.valueAlloc(self.allocator, field(value, "id"), .{});
                defer self.allocator.free(id_json);
                const reply_json = try std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Unsupported server request\"}}}}", .{id_json});
                defer self.allocator.free(reply_json);
                try self.wire.send(reply_json);
            }
        }
        pub fn asAdapter(self: *Self) adapter.Adapter {
            return .{ .context = self, .vtable = &.{ .discover = discoverAny, .accountStatus = accountAny, .resolveSelection = selectionAny, .dispatch = dispatchAny, .pump = pumpAny, .poll = pollAny, .shutdown = shutdownAny, .pollTool = pollToolAny, .respondTool = respondToolAny, .ready = readyAny } };
        }
        fn ptr(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }
        fn readyAny(context: *anyopaque) bool {
            const self = ptr(context);
            return self.disconnected or self.diagnostic.len != 0 or (self.initialized and self.pending == null);
        }
        fn discoverAny(context: *anyopaque) c.Discovery {
            return ptr(context).discover();
        }
        fn accountAny(context: *anyopaque) c.Account {
            return ptr(context).accountStatus();
        }
        fn selectionAny(context: *anyopaque, selection: c.Selection) c.SelectionResult {
            return ptr(context).resolveSelection(selection);
        }
        fn dispatchAny(context: *anyopaque, allocator: std.mem.Allocator, request: c.Request) anyerror!c.Receipt {
            return ptr(context).dispatch(allocator, request);
        }
        fn pumpAny(context: *anyopaque) anyerror!void {
            return ptr(context).pump();
        }
        fn pollAny(context: *anyopaque, allocator: std.mem.Allocator) anyerror!?c.Observation {
            return ptr(context).poll(allocator);
        }
        fn pollToolAny(context: *anyopaque, allocator: std.mem.Allocator) anyerror!?ToolCall {
            return ptr(context).pollTool(allocator);
        }
        fn respondToolAny(context: *anyopaque, request_id: []const u8, success: bool, result: []const u8) anyerror!void {
            return ptr(context).respondTool(request_id, success, result);
        }
        fn shutdownAny(context: *anyopaque) void {
            ptr(context).wire.deinit();
        }
    };
}
