//! OpenCode 2.1.4 ACP protocol 1. The transport belongs to Host, never UI.
const std = @import("std");
const c = @import("../contract.zig");
const Value = std.json.Value;
const prompt_wire = @import("prompt.zig");
const common = @import("adapter.zig");
pub const Runtime = RuntimeFor(@import("transport.zig").Transport);

pub const Config = struct {
    selection: c.Selection,
    /// Absolute provider process workspace; never the durable opaque workspace ID.
    cwd: []const u8,
    instance: c.RuntimeInstanceId,
    /// Reference names isolated runtime-owned state; never an OMP credential.
    account: c.Account,
    /// Serialized ACP mcpServers array, supplied by the app's actual MCP owner.
    mcp_servers: []const u8 = "[]",
};

fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn text(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
const clone = common.clone;

/// ACP content becomes shared text blocks. Keep ordinary text readable and
/// retain both sides of file changes; preserve unfamiliar payloads verbatim as
/// JSON until the shared contract has a renderer for them. The caller supplies
/// the existing fixed pending buffer, so formatting cannot grow retained memory.
fn writeToolContent(writer: *std.Io.Writer, content: Value) !void {
    if (content == .null) return;
    if (content != .array) return std.json.Stringify.value(content, .{}, writer);
    for (content.array.items, 0..) |item, index| {
        if (index != 0) try writer.writeAll("\n\n");
        const kind = text(field(item, "type"));
        const block = if (eq(kind, "content")) field(item, "content") else item;
        if (eq(text(field(block, "type")), "text") and field(block, "text") == .string) {
            try writer.writeAll(text(field(block, "text")));
        } else if (eq(kind, "diff") and field(item, "path") == .string and
            (field(item, "oldText") == .null or field(item, "oldText") == .string) and
            (field(item, "newText") == .null or field(item, "newText") == .string))
        {
            try writer.print("File: {s}\n", .{text(field(item, "path"))});
            const before = field(item, "oldText");
            const after = field(item, "newText");
            if (before == .string) try writer.print("Before:\n```\n{s}\n```\n", .{before.string});
            if (after == .string) {
                try writer.print("After:\n```\n{s}\n```", .{after.string});
            } else try writer.writeAll("Deleted");
        } else try std.json.Stringify.value(item, .{}, writer);
    }
}

/// Transport supplies bounded JSONL IO. Initialize at final address.
pub fn RuntimeFor(comptime Transport: type) type {
    return struct {
        const Self = @This();
        const ToolAuthority = struct {
            next: ?*ToolAuthority,
            tool: []const u8,
            digest: []const u8,
            raw_input: []const u8,
        };
        allocator: std.mem.Allocator,
        transport: Transport,
        config: Config,
        storage: [32768]u8 = undefined,
        retained: std.heap.FixedBufferAllocator = undefined,
        // At most ceil(256KiB/3)*4 base64 bytes + 8 resource URIs,
        // correlation and tool state. JSON is allocated separately by prompt_wire;
        // raw text bodies are borrowed until synchronous serialization completes.
        // No second base64 copy/data URL is retained. Ordinary frames stay 64KiB.
        turn_storage: [512 * 1024]u8 = undefined,
        turn: std.heap.FixedBufferAllocator = undefined,
        selection: c.Selection = undefined,
        session: ?c.Session = null,
        correlation: c.Correlation = undefined,
        phase: enum { cold, initializing, idle, creating, resuming, model, effort, ready, prompting, failed, stopped } = .cold,
        request_id: i64 = 0,
        pending_id: i64 = 0,
        prompt_id: i64 = 0,
        approval_id: ?Value = null,
        approval_tool: []const u8 = "",
        approval_digest: []const u8 = "",
        approval_allow: []const u8 = "",
        approval_deny: []const u8 = "",
        // Permission refines the initial tool-ID placeholder. Preserve that
        // authority across status-only updates, including interleaved tools.
        // All nodes/strings share the existing bounded per-turn allocator.
        tool_authorities: ?*ToolAuthority = null,
        offset: u64 = 0,
        sequence: u64 = 0,
        load_supported: bool = false,
        resume_supported: bool = false,
        image_supported: bool = false,
        embedded_supported: bool = false,
        runtime_version: []const u8 = "unnegotiated",
        effective: bool = false,
        selection_pending: bool = false,
        cancel_requested: bool = false,
        shutdown_done: bool = false,
        transport_failure: ?anyerror = null,
        transport_failure_emitted: bool = false,
        // One decoded upstream payload. Poll drains it before reading another
        // transport frame; no unbounded queue or allocation per retained piece.
        pending_bytes: [65536]u8 = undefined,
        pending_len: usize = 0,
        pending_cursor: usize = 0,
        pending_kind: enum { none, text, tool, tool_terminal } = .none,
        pending_tool: [1024]u8 = undefined,
        pending_tool_len: usize = 0,
        pending_tool_failed: bool = false,
        utf8_carry: [3]u8 = undefined,
        utf8_carry_len: usize = 0,

        /// Initialize at final address (fixed allocator references inline buffers).
        /// Config strings and Transport must remain alive until shutdown.
        pub fn init(self: *Self, allocator: std.mem.Allocator, transport: Transport, config: Config) !void {
            if (!eq(config.selection.runtime_kind, "opencode") or
                !eq(config.selection.required_runtime_version, "2.1.4") or
                !std.fs.path.isAbsolute(config.cwd) or
                !eq(config.selection.account_ref, config.account.reference)) return error.SelectionUnavailable;
            const mcp = try std.json.parseFromSlice(Value, allocator, config.mcp_servers, .{});
            defer mcp.deinit();
            if (mcp.value != .array) return error.InvalidMcpServers;
            self.* = .{ .allocator = allocator, .transport = transport, .config = config };
            self.retained = std.heap.FixedBufferAllocator.init(&self.storage);
            self.turn = std.heap.FixedBufferAllocator.init(&self.turn_storage);
            self.selection = try clone(self.retained.allocator(), config.selection);
            self.correlation = .{ .session = .{ .value = "unopened" } };
            try self.rpc("initialize", .{ .protocolVersion = 1, .clientCapabilities = Value{ .object = .empty }, .clientInfo = .{ .name = "spica", .version = "1" } });
            self.phase = .initializing;
        }
        pub fn shutdown(self: *Self) void {
            if (self.shutdown_done) return;
            self.shutdown_done = true;
            self.transport.deinit();
            self.phase = .stopped;
        }
        pub fn discover(self: *const Self) c.Discovery {
            var caps: [@typeInfo(c.Capability).@"enum".fields.len]c.CapabilityInfo = undefined;
            for (&caps) |*cap| cap.* = .{ .status = .unsupported, .evidence = "OpenCode 2.1.4 ACP; no invented parity" };
            if (self.phase != .cold and self.phase != .initializing and self.phase != .failed and self.phase != .stopped) {
                for ([_]c.Capability{ .create, .start, .stream, .tools, .approval, .cancel, .selection, .workspace }) |cap| caps[@intFromEnum(cap)].status = .supported;
                if (self.image_supported or self.embedded_supported) caps[@intFromEnum(c.Capability.attachment)] = .{ .status = .supported, .evidence = "ACP image/resource serializers tested against offline consumer; content kinds require negotiated promptCapabilities" };
                if (self.resume_supported) caps[@intFromEnum(c.Capability.attach)].status = .supported;
            }
            // ACP MCP registration is not itself an implemented app MCP bridge.
            return .{ .runtime_kind = "opencode", .runtime_version = self.runtime_version, .capabilities = caps, .limits = .{ .frame_bytes = 65536, .chunk_bytes = 2048, .queue_bytes = 262144, .queue_frames = 16, .pending_requests = 1 } };
        }
        pub fn accountStatus(self: *const Self) c.Account {
            // User-provided readiness is not inferred from model listings.
            return self.config.account;
        }
        pub fn asAdapter(self: *Self) common.Adapter {
            return .{ .context = self, .vtable = &.{
                .discover = struct {
                    fn call(p: *anyopaque) c.Discovery {
                        return cast(p).discover();
                    }
                }.call,
                .accountStatus = struct {
                    fn call(p: *anyopaque) c.Account {
                        return cast(p).accountStatus();
                    }
                }.call,
                .resolveSelection = struct {
                    fn call(p: *anyopaque, s: c.Selection) c.SelectionResult {
                        return cast(p).resolveSelection(s);
                    }
                }.call,
                .dispatch = struct {
                    fn call(p: *anyopaque, a: std.mem.Allocator, r: c.Request) anyerror!c.Receipt {
                        return cast(p).dispatch(a, r);
                    }
                }.call,
                .pump = struct {
                    fn call(p: *anyopaque) anyerror!void {
                        return cast(p).pump();
                    }
                }.call,
                .poll = struct {
                    fn call(p: *anyopaque, a: std.mem.Allocator) anyerror!?c.Observation {
                        return cast(p).poll(a);
                    }
                }.call,
                .shutdown = struct {
                    fn call(p: *anyopaque) void {
                        cast(p).shutdown();
                    }
                }.call,
                .ready = struct {
                    fn call(p: *anyopaque) bool {
                        const phase = cast(p).phase;
                        return phase != .cold and phase != .initializing;
                    }
                }.call,
            } };
        }
        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }
        pub fn resolveSelection(self: *const Self, requested: c.Selection) c.SelectionResult {
            return .{ .requested = requested, .effective = if (self.effective and c.equal(requested, self.selection)) self.selection else null, .readiness = self.accountStatus().readiness };
        }
        fn compatibleSelection(self: *const Self, requested: c.Selection) bool {
            var expected = self.selection;
            if (self.session == null) expected.workspace = requested.workspace;
            return c.equal(requested, expected);
        }
        fn send(self: *Self, value: anytype) !void {
            const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
            defer self.allocator.free(bytes);
            if (bytes.len > 65536) return error.FrameTooLarge;
            try self.transport.send(bytes);
        }
        fn rpc(self: *Self, method: []const u8, params: anytype) !void {
            const id = self.request_id + 1;
            const packet = .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params };
            if (eq(method, "session/prompt")) {
                const bytes = try prompt_wire.encode(self.allocator, packet);
                defer self.allocator.free(bytes);
                if (@hasDecl(Transport, "sendPrompt")) {
                    try self.transport.sendPrompt(bytes);
                } else try self.transport.send(bytes);
            } else try self.send(packet);
            self.request_id = id;
            self.pending_id = id;
        }
        fn sessionParams(self: *Self, method: []const u8, upstream: ?[]const u8) !void {
            const parsed = try std.json.parseFromSlice(Value, self.allocator, self.config.mcp_servers, .{});
            defer parsed.deinit();
            if (upstream) |id| {
                try self.rpc(method, .{ .sessionId = id, .cwd = self.config.cwd, .mcpServers = parsed.value });
            } else {
                try self.rpc(method, .{ .cwd = self.config.cwd, .mcpServers = parsed.value });
            }
        }
        pub fn dispatch(self: *Self, allocator: std.mem.Allocator, request: c.Request) !c.Receipt {
            if (request == .start) {
                try prompt_wire.validate(request.start);
                for (request.start.attachments) |attachment| {
                    const m = attachment.metadata;
                    if (!@import("../domain/attachments.zig").supported(m.media_type, m.kind, .opencode) or
                        (m.kind == .image and !self.image_supported) or
                        (m.kind == .file and !self.embedded_supported)) return error.AttachmentUnsupported;
                }
                if (c.frameBytes(request) > (c.Limits{}).frame_bytes + (c.Limits{}).attachment_packet_bytes) return error.FrameTooLarge;
            } else if (c.frameBytes(request) > 65536) return error.FrameTooLarge;
            switch (request) {
                .open => |open| {
                    if (self.phase != .idle) return error.NotReady;
                    self.turn.reset();
                    self.tool_authorities = null;
                    switch (open) {
                        .create => |r| {
                            if (!self.compatibleSelection(r.selection)) return error.SelectionUnavailable;
                            self.selection.workspace = try clone(self.retained.allocator(), r.selection.workspace);
                            self.correlation = try clone(self.turn.allocator(), c.Correlation{ .session = r.session, .effect = r.effect });
                            try self.sessionParams("session/new", null);
                        },
                        .existing => |r| {
                            if (!self.resume_supported or r.after != null) return error.CapabilityUnavailable;
                            if (r.session.id.value.len == 0 or r.session.upstream.value.len == 0) return error.MissingSession;
                            self.session = try clone(self.retained.allocator(), r.session);
                            self.session.?.instance = self.config.instance;
                            self.correlation = try clone(self.turn.allocator(), c.Correlation{ .session = r.session.id });
                            try self.sessionParams("session/resume", r.session.upstream.value);
                        },
                    }
                    self.phase = if (open == .existing) .resuming else .creating;
                },
                .attach => |r| return self.dispatch(allocator, .{ .open = .{ .existing = .{ .session = r.session, .after = r.after } } }),
                .start => |r| {
                    if (self.phase != .ready or self.session == null) return error.NotReady;
                    if (r.correlation.effect == null or r.correlation.run == null or !c.equal(r.correlation.session, self.session.?.id)) return error.InvalidCorrelation;
                    self.turn.reset();
                    self.tool_authorities = null;
                    self.correlation = try clone(self.turn.allocator(), r.correlation);
                    // ACP v1 ContentBlock (pinned effect-acp schema): images carry
                    // base64 data/mimeType; embedded resources carry text or blob.
                    // Encode inactive fields by omission, never invented file URLs.
                    const Resource = struct { uri: []const u8, mimeType: []const u8, text: ?[]const u8 = null, blob: ?[]const u8 = null };
                    const Part = struct { type: []const u8, text: ?[]const u8 = null, data: ?[]const u8 = null, mimeType: ?[]const u8 = null, resource: ?Resource = null };
                    var parts: [9]Part = undefined;
                    var part_count: usize = 0;
                    if (r.prompt.len != 0) {
                        parts[part_count] = .{ .type = "text", .text = r.prompt };
                        part_count += 1;
                    }
                    for (r.attachments) |attachment| {
                        const m = attachment.metadata;
                        if (m.kind == .image) {
                            const encoded = try self.turn.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(attachment.content.len));
                            _ = std.base64.standard.Encoder.encode(encoded, attachment.content);
                            parts[part_count] = .{ .type = "image", .mimeType = m.media_type, .data = encoded };
                        } else {
                            // Digest-only URI cannot contain path escapes or refer to
                            // local/provider files. Resource body is self-contained.
                            const uri = try std.fmt.allocPrint(self.turn.allocator(), "spica-attachment:sha256:{s}", .{m.digest});
                            var resource: Resource = .{ .uri = uri, .mimeType = m.media_type };
                            if (eq(m.media_type, "text/plain")) {
                                resource.text = attachment.content;
                            } else {
                                const encoded = try self.turn.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(attachment.content.len));
                                _ = std.base64.standard.Encoder.encode(encoded, attachment.content);
                                resource.blob = encoded;
                            }
                            parts[part_count] = .{ .type = "resource", .resource = resource };
                        }
                        part_count += 1;
                    }
                    if (part_count == 0) return error.InvalidPrompt;
                    try self.rpc("session/prompt", .{ .sessionId = self.session.?.upstream.value, .prompt = parts[0..part_count] });
                    self.prompt_id = self.pending_id;
                    self.offset = 0;
                    self.cancel_requested = false;
                    self.phase = .prompting;
                },
                .cancel => |r| {
                    if (self.phase != .prompting or !c.equal(r.correlation.session, self.correlation.session) or !c.equal(r.correlation.run, self.correlation.run)) return error.InvalidCorrelation;
                    try self.send(.{ .jsonrpc = "2.0", .method = "session/cancel", .params = .{ .sessionId = self.session.?.upstream.value } });
                    self.cancel_requested = true;
                },
                .respond_approval => |r| {
                    if (self.phase != .prompting or self.approval_id == null or !c.equal(r.correlation.session, self.correlation.session) or !c.equal(r.correlation.run, self.correlation.run) or r.correlation.approval == null or !eq(r.correlation.approval.?.value, self.approval_digest) or r.correlation.tool == null or !eq(r.correlation.tool.?.value, self.approval_tool) or !eq(r.action_digest, self.approval_digest)) return error.InvalidCorrelation;
                    const option = if (r.decision == .allow) self.approval_allow else self.approval_deny;
                    if (option.len == 0) return error.CapabilityUnavailable;
                    try self.send(.{ .jsonrpc = "2.0", .id = self.approval_id.?, .result = .{ .outcome = .{ .outcome = "selected", .optionId = option } } });
                    self.approval_id = null;
                },
                else => return error.CapabilityUnavailable,
            }
            return try clone(allocator, c.Receipt{ .outcome = .acknowledged });
        }
        pub fn pump(self: *Self) !void {
            if (self.shutdown_done) return;
            if (self.transport_failure) |err| return err;
            self.transport.pump() catch |err| {
                // A write failure can precede reap; transport.exited is not an
                // authoritative signal in that path. Retain the original error
                // and terminate protocol use without inventing process exit.
                self.transport_failure = err;
                self.phase = .failed;
                return err;
            };
        }
        fn observation(self: *Self, allocator: std.mem.Allocator, event: []const u8, body: @FieldType(c.Observation, "body")) !c.Observation {
            self.sequence += 1;
            var event_buffer: [512]u8 = undefined;
            const identity = try std.fmt.bufPrint(&event_buffer, "{s}:{d}:{s}", .{ self.config.instance.value, self.sequence, event });
            const result = c.Observation{ .correlation = self.correlation, .upstream_event = identity, .runtime_version = self.runtime_version, .sequence = self.sequence, .body = body };
            if (c.frameBytes(result) > 4096) return error.FrameTooLarge;
            return clone(allocator, result);
        }
        fn configureModel(self: *Self) !void {
            const model = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.selection.model_provider, self.selection.model_id });
            defer self.allocator.free(model);
            try self.rpc("session/set_config_option", .{ .sessionId = self.session.?.upstream.value, .configId = "model", .value = model });
            self.phase = .model;
        }
        fn toolCorrelation(self: *Self, allocator: std.mem.Allocator, result: *c.Observation) !void {
            const tool = try allocator.dupe(u8, self.pending_tool[0..self.pending_tool_len]);
            result.correlation.tool = .{ .value = tool };
            result.correlation.upstream_tool = tool;
            if (c.frameBytes(result.*) > 4096) return error.FrameTooLarge;
        }
        /// Largest valid complete UTF-8 prefix within the durable chunk bound.
        /// A trailing partial scalar is retained, not replaced or emitted.
        fn prefix(bytes: []const u8) !usize {
            var end: usize = 0;
            while (end < bytes.len) {
                const width = try std.unicode.utf8ByteSequenceLength(bytes[end]);
                if (bytes.len - end < width) {
                    for (bytes[end + 1 ..]) |byte| if (byte & 0xc0 != 0x80) return error.InvalidUtf8;
                    break;
                }
                _ = try std.unicode.utf8Decode(bytes[end..][0..width]);
                if (end + width > 2048) break;
                end += width;
            }
            return end;
        }
        pub fn drainPending(self: *Self, allocator: std.mem.Allocator) !?c.Observation {
            if (self.pending_kind == .none) return null;
            if (self.pending_kind == .tool_terminal) {
                var result = try self.observation(allocator, "tool/result/completed", .{ .tool_completed = .{ .outcome = if (self.pending_tool_failed) .failed else .succeeded, .result = "" } });
                try self.toolCorrelation(allocator, &result);
                self.pending_kind = .none;
                return result;
            }
            const remaining = self.pending_bytes[self.pending_cursor..self.pending_len];
            const count = try prefix(remaining);
            if (count == 0) {
                if (self.pending_kind == .tool) return error.InvalidUtf8;
                if (remaining.len > self.utf8_carry.len) return error.InvalidUtf8;
                @memcpy(self.utf8_carry[0..remaining.len], remaining);
                self.utf8_carry_len = remaining.len;
                self.pending_kind = .none;
                return null;
            }
            const is_tool = self.pending_kind == .tool;
            // ACP has no message ID here. Scope the synthetic message to the
            // admitted run so a later turn cannot alias its predecessor's block.
            var message_bytes: [512]u8 = undefined;
            const message = try std.fmt.bufPrint(&message_bytes, "opencode-message:{s}", .{self.correlation.run.?.value});
            var result = try self.observation(allocator, if (is_tool) "tool/result/chunk" else "agent_message_chunk", .{ .chunk = .{
                .message = .{ .value = message },
                .block = .{ .value = if (is_tool) self.pending_tool[0..self.pending_tool_len] else "opencode-text" },
                .offset = if (is_tool) self.pending_cursor else self.offset,
                .text = remaining[0..count],
            } });
            if (is_tool) try self.toolCorrelation(allocator, &result);
            self.pending_cursor += count;
            if (!is_tool) self.offset += count;
            if (self.pending_cursor == self.pending_len) self.pending_kind = if (is_tool) .tool_terminal else .none;
            return result;
        }
        /// One frame per poll, preserving order and bounding per-call work.
        pub fn poll(self: *Self, allocator: std.mem.Allocator) !?c.Observation {
            if (self.selection_pending) {
                const result = try self.observation(allocator, "session/effective-selection", .{ .selection = self.resolveSelection(self.selection) });
                self.selection_pending = false;
                return result;
            }
            if (try self.drainPending(allocator)) |result| return result;
            if (self.transport_failure) |err| {
                if (self.transport_failure_emitted) return null;
                const result = try self.observation(allocator, "transport/error", .{ .disconnect = .{ .reason = @errorName(err), .continuity = .unknown } });
                self.transport_failure_emitted = true;
                return result;
            }
            const bytes = (try self.transport.poll(self.allocator)) orelse {
                if (self.transport.exited and self.phase != .stopped) {
                    self.phase = .stopped;
                    return try self.observation(allocator, "process/exit", .{ .disconnect = .{ .reason = "OpenCode ACP process exited", .continuity = .unknown } });
                }
                return null;
            };
            defer self.allocator.free(bytes);
            if (bytes.len > 65536) return error.FrameTooLarge;
            const parsed = try std.json.parseFromSlice(Value, self.allocator, bytes, .{ .max_value_len = 65536 });
            defer parsed.deinit();
            return self.consume(allocator, parsed.value);
        }
        pub fn consume(self: *Self, allocator: std.mem.Allocator, frame: Value) !?c.Observation {
            if (self.pending_kind != .none) return error.Backpressure;
            if (!eq(text(field(frame, "jsonrpc")), "2.0")) return error.InvalidProtocol;
            const method = text(field(frame, "method"));
            const params = field(frame, "params");
            const id = field(frame, "id");
            if (method.len == 0) {
                if (id != .integer or id.integer != self.pending_id) return error.UnexpectedResponse;
                const failure = field(frame, "error");
                if (failure != .null) {
                    const resuming = self.phase == .resuming;
                    self.phase = .failed;
                    const structured = if (field(failure, "data") != .null) try std.json.Stringify.valueAlloc(self.allocator, failure, .{}) else null;
                    defer if (structured) |bytes| self.allocator.free(bytes);
                    const diagnostic = structured orelse text(field(failure, "message"));
                    var end = @min(diagnostic.len, 2048);
                    while (end < diagnostic.len and end > 0 and diagnostic[end] & 0xc0 == 0x80) end -= 1;
                    return try self.observation(allocator, "rpc/error", .{ .failure = .{ .code = if (resuming) "session_resume_failed" else "opencode_rpc_error", .detail = diagnostic[0..end] } });
                }
                const result = field(frame, "result");
                switch (self.phase) {
                    .initializing => {
                        const version = field(result, "protocolVersion");
                        const info = field(result, "agentInfo");
                        if (version != .integer or version.integer != 1 or !eq(text(field(info, "version")), self.selection.required_runtime_version)) {
                            self.phase = .failed;
                            return error.RuntimeVersionMismatch;
                        }
                        self.runtime_version = try self.retained.allocator().dupe(u8, text(field(info, "version")));
                        const caps = field(result, "agentCapabilities");
                        const load = field(caps, "loadSession");
                        self.load_supported = load == .bool and load.bool;
                        const prompt_caps = field(caps, "promptCapabilities");
                        self.image_supported = field(prompt_caps, "image") == .bool and field(prompt_caps, "image").bool;
                        self.embedded_supported = field(prompt_caps, "embeddedContext") == .bool and field(prompt_caps, "embeddedContext").bool;
                        self.resume_supported = field(field(caps, "sessionCapabilities"), "resume") == .object;
                        self.phase = .idle;
                    },
                    .creating, .resuming => {
                        if (self.session == null) {
                            const upstream = text(field(result, "sessionId"));
                            if (upstream.len == 0) return error.InvalidProtocol;
                            self.session = try clone(self.retained.allocator(), c.Session{ .id = self.correlation.session, .instance = self.config.instance, .upstream = .{ .value = upstream } });
                        } else if (field(result, "sessionId") != .null and !eq(text(field(result, "sessionId")), self.session.?.upstream.value)) {
                            self.phase = .failed;
                            return error.InvalidCorrelation;
                        }
                        try self.configureModel();
                    },
                    .model => {
                        if (!configMatches(result, "model", self.selection.model_provider, self.selection.model_id)) return error.SelectionUnavailable;
                        if (self.selection.effort.len != 0 and !eq(self.selection.effort, "default")) {
                            try self.rpc("session/set_config_option", .{ .sessionId = self.session.?.upstream.value, .configId = "effort", .value = self.selection.effort });
                            self.phase = .effort;
                        } else {
                            self.phase = .ready;
                            self.effective = true;
                            self.selection_pending = true;
                            return try self.observation(allocator, "session/selected", .{ .session = self.session.? });
                        }
                    },
                    .effort => {
                        if (!configMatches(result, "effort", "", self.selection.effort) or !configMatches(result, "model", self.selection.model_provider, self.selection.model_id)) return error.SelectionUnavailable;
                        self.phase = .ready;
                        self.effective = true;
                        self.selection_pending = true;
                        return try self.observation(allocator, "session/selected", .{ .session = self.session.? });
                    },
                    .prompting => {
                        if (self.utf8_carry_len != 0) return error.IncompleteUtf8;
                        const reason = text(field(result, "stopReason"));
                        self.phase = if (eq(reason, "end_turn")) .ready else .failed;
                        self.approval_id = null;
                        if (eq(reason, "cancelled")) return try self.observation(allocator, "session/prompt", .{ .cancelled = .{ .tools_stopped = false } });
                        if (eq(reason, "end_turn")) return try self.observation(allocator, "session/prompt", .{ .completed = {} });
                        return try self.observation(allocator, "session/prompt", .{ .failure = .{ .code = "opencode_stop", .detail = reason } });
                    },
                    else => return error.UnexpectedResponse,
                }
                return null;
            }
            if (!eq(text(field(params, "sessionId")), if (self.session) |s| s.upstream.value else "")) return error.InvalidCorrelation;
            if (eq(method, "session/request_permission")) {
                if (self.phase != .prompting or self.approval_id != null or (id != .integer and id != .string)) return error.InvalidProtocol;
                const tool = field(params, "toolCall");
                const tool_id = text(field(tool, "toolCallId"));
                if (tool_id.len == 0) return error.InvalidProtocol;
                const options = field(params, "options");
                if (options != .array) return error.InvalidProtocol;
                var allow: []const u8 = "";
                var deny: []const u8 = "";
                for (options.array.items) |option| {
                    if (eq(text(field(option, "kind")), "allow_once")) allow = text(field(option, "optionId"));
                    if (eq(text(field(option, "kind")), "reject_once")) deny = text(field(option, "optionId"));
                }
                // Never select allow_always or infer an option ID from prose.
                if (allow.len == 0 or deny.len == 0) return error.CapabilityUnavailable;
                const serialized = try std.json.Stringify.valueAlloc(self.allocator, frame, .{});
                defer self.allocator.free(serialized);
                var digest_buf: [64]u8 = undefined;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(serialized, &digest, .{});
                digest_buf = std.fmt.bytesToHex(digest, .lower);
                self.approval_digest = try self.turn.allocator().dupe(u8, &digest_buf);
                self.approval_tool = try self.turn.allocator().dupe(u8, tool_id);
                self.approval_allow = try self.turn.allocator().dupe(u8, allow);
                self.approval_deny = try self.turn.allocator().dupe(u8, deny);
                self.approval_id = if (id == .string) .{ .string = try self.turn.allocator().dupe(u8, id.string) } else id;
                const authority = try self.turn.allocator().create(ToolAuthority);
                authority.* = .{
                    .next = self.tool_authorities,
                    .tool = self.approval_tool,
                    .digest = self.approval_digest,
                    .raw_input = try std.json.Stringify.valueAlloc(self.turn.allocator(), field(tool, "rawInput"), .{}),
                };
                self.tool_authorities = authority;
                var correlation = self.correlation;
                correlation.tool = .{ .value = self.approval_tool };
                correlation.approval = .{ .value = self.approval_digest };
                correlation.upstream_tool = self.approval_tool;
                correlation.upstream_request = try std.json.Stringify.valueAlloc(self.turn.allocator(), id, .{});
                var result = try self.observation(allocator, method, .{ .approval = .{ .correlation = correlation, .workspace = self.selection.workspace, .action_digest = self.approval_digest, .scope = text(field(tool, "title")) } });
                result.correlation = result.body.approval.correlation;
                return result;
            }
            if (id != .null) {
                try self.send(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32601), .message = "Unsupported ACP client method" } });
                return null;
            }
            if (!eq(method, "session/update")) return null;
            const update = field(params, "update");
            const kind = text(field(update, "sessionUpdate"));
            if (eq(kind, "agent_message_chunk")) {
                if (self.phase != .prompting) return null; // No replay-as-new-output.
                const content = field(update, "content");
                if (!eq(text(field(content, "type")), "text")) return null;
                const chunk = text(field(content, "text"));
                if (chunk.len > self.pending_bytes.len - self.utf8_carry_len) return error.ChunkTooLarge;
                @memcpy(self.pending_bytes[0..self.utf8_carry_len], self.utf8_carry[0..self.utf8_carry_len]);
                @memcpy(self.pending_bytes[self.utf8_carry_len..][0..chunk.len], chunk);
                self.pending_len = self.utf8_carry_len + chunk.len;
                self.pending_cursor = 0;
                self.utf8_carry_len = 0;
                self.pending_kind = .text;
                return self.drainPending(allocator);
            }
            if (eq(kind, "tool_call") or eq(kind, "tool_call_update")) {
                if (self.phase != .prompting) return null;
                const tool_id = text(field(update, "toolCallId"));
                if (tool_id.len == 0) return error.InvalidProtocol;
                const status = text(field(update, "status"));
                var action_digest = tool_id;
                var authority = self.tool_authorities;
                while (authority) |entry| : (authority = entry.next) {
                    if (!eq(entry.tool, tool_id)) continue;
                    const raw_input = field(update, "rawInput");
                    if (raw_input != .null) {
                        var writer = std.Io.Writer.fixed(&self.pending_bytes);
                        std.json.Stringify.value(raw_input, .{}, &writer) catch return error.FrameTooLarge;
                        if (!eq(entry.raw_input, writer.buffered())) return error.ActionChanged;
                    }
                    action_digest = entry.digest;
                    break;
                }
                if (eq(status, "completed") or eq(status, "failed")) {
                    if (tool_id.len > self.pending_tool.len) return error.FrameTooLarge;
                    var link = &self.tool_authorities;
                    while (link.*) |entry| {
                        if (eq(entry.tool, tool_id)) {
                            link.* = entry.next;
                            break;
                        }
                        link = &entry.next;
                    }
                    var writer = std.Io.Writer.fixed(&self.pending_bytes);
                    writeToolContent(&writer, field(update, "content")) catch return error.FrameTooLarge;
                    @memcpy(self.pending_tool[0..tool_id.len], tool_id);
                    self.pending_tool_len = tool_id.len;
                    self.pending_tool_failed = eq(status, "failed");
                    self.pending_len = writer.buffered().len;
                    self.pending_cursor = 0;
                    self.pending_kind = if (self.pending_len == 0) .tool_terminal else .tool;
                    return self.drainPending(allocator);
                }
                var result = try self.observation(allocator, kind, .{ .tool_started = .{ .name = text(field(update, "title")), .action_digest = action_digest } });
                result.correlation.tool = .{ .value = try allocator.dupe(u8, tool_id) };
                result.correlation.upstream_tool = result.correlation.tool.?.value;
                return result;
            }
            if (eq(kind, "config_option_update") and self.effective and !configMatches(update, "model", self.selection.model_provider, self.selection.model_id)) {
                self.effective = false;
                self.phase = .failed;
                return try self.observation(allocator, kind, .{ .failure = .{ .code = "selection_changed", .detail = "OpenCode effective model changed outside this runtime" } });
            }
            return null;
        }
    };
}

fn configMatches(result: Value, id: []const u8, provider: []const u8, model: []const u8) bool {
    const options = field(result, "configOptions");
    if (options != .array) return false;
    for (options.array.items) |option| {
        if (!eq(text(field(option, "id")), id)) continue;
        const current = text(field(option, "currentValue"));
        if (provider.len == 0) return eq(current, model);
        return current.len == provider.len + 1 + model.len and std.mem.startsWith(u8, current, provider) and current[provider.len] == '/' and std.mem.endsWith(u8, current, model);
    }
    return false;
}
