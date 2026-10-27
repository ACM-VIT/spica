const std = @import("std");
const c = @import("contract.zig");
const opencode = @import("runtime/opencode.zig");
const Mock = struct {
    sent: [@import("runtime/prompt.zig").json_bytes]u8 = undefined,
    len: usize = 0,
    exited: bool = false,
    polls: usize = 0,
    pump_error: bool = false,
    pumps: usize = 0,
    pub fn send(self: *Mock, bytes: []const u8) !void {
        @memcpy(self.sent[0..bytes.len], bytes);
        self.len = bytes.len;
    }
    pub fn pump(self: *Mock) !void {
        self.pumps += 1;
        if (self.pump_error) return error.TransportWrite;
    }
    pub fn poll(self: *Mock, _: std.mem.Allocator) !?[]const u8 {
        self.polls += 1;
        return null;
    }
    pub fn deinit(_: *Mock) void {}
};
const Runtime = opencode.RuntimeFor(Mock);
const selection: c.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "opencode", .model_id = "big-pickle", .effort = "default", .account_ref = "isolated", .workspace = .{ .value = "/tmp/spica" } };
const correlation: c.Correlation = .{ .session = .{ .value = "session" }, .run = .{ .value = "run" }, .effect = .{ .value = "effect" } };
fn consume(runtime: *Runtime, a: std.mem.Allocator, bytes: []const u8) !?c.Observation {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    return runtime.consume(a, parsed.value);
}
fn ready(runtime: *Runtime, a: std.mem.Allocator) !void {
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
    _ = try consume(runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
    _ = try runtime.asAdapter().dispatch(a, .{ .open = .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = selection } } });
    _ = try consume(runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"ses_upstream\"}}");
    const event = (try consume(runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"opencode/big-pickle\"}]}}")).?;
    try std.testing.expect(event.body == .session);
    const selected = (try runtime.poll(a)).?;
    try std.testing.expect(selected.body == .selection);
    try std.testing.expect(c.equal(selection, selected.body.selection.requested));
    try std.testing.expect(c.equal(selection, selected.body.selection.effective.?));
    try std.testing.expect(c.equal(correlation.session, selected.correlation.session));
    try std.testing.expectEqual(@as(usize, 0), runtime.transport.polls);
}
fn prompting(runtime: *Runtime, a: std.mem.Allocator) !void {
    try ready(runtime, a);
    _ = try runtime.asAdapter().dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "hello" } });
}

test "ACP subsequent turns keep upstream session and bounded retained state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    try std.testing.expect((try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"stopReason\":\"end_turn\"}}")).?.body == .completed);
    const retained = runtime.retained.end_index;
    var turn_bytes: usize = 0;
    var previous_message: []const u8 = "";
    for (0..128) |index| {
        const run = try std.fmt.allocPrint(a, "run-{d:0>3}", .{index});
        var next = correlation;
        next.run = .{ .value = run };
        _ = try runtime.asAdapter().dispatch(a, .{ .start = .{ .correlation = next, .prompt = "follow-up only" } });
        const sent = try std.json.parseFromSlice(std.json.Value, a, runtime.transport.sent[0..runtime.transport.len], .{});
        const params = sent.value.object.get("params").?;
        try std.testing.expectEqualStrings("session/prompt", sent.value.object.get("method").?.string);
        try std.testing.expectEqualStrings("ses_upstream", params.object.get("sessionId").?.string);
        try std.testing.expectEqualStrings("follow-up only", params.object.get("prompt").?.array.items[0].object.get("text").?.string);
        const chunk = (try textFrame(&runtime, a, "next response")).?;
        try std.testing.expectEqualStrings(run, chunk.correlation.run.?.value);
        try std.testing.expectEqual(@as(u64, 0), chunk.body.chunk.offset);
        try std.testing.expect(!std.mem.eql(u8, previous_message, chunk.body.chunk.message.value));
        previous_message = chunk.body.chunk.message.value;
        const response = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = runtime.pending_id, .result = .{ .stopReason = "end_turn" } }, .{});
        try std.testing.expect((try consume(&runtime, a, response)).?.body == .completed);
        try std.testing.expectEqual(retained, runtime.retained.end_index);
        if (index == 0) turn_bytes = runtime.turn.end_index else try std.testing.expectEqual(turn_bytes, runtime.turn.end_index);
    }
    try std.testing.expect((try textFrame(&runtime, a, "late replay")) == null);
}

test "ACP fresh runtime resumes exact session via either public request without history replay" {
    for ([_]bool{ false, true }) |attach| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var runtime: Runtime = undefined;
        try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "new-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
        defer runtime.shutdown();
        _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
        const session: c.Session = .{ .id = correlation.session, .instance = .{ .value = "old-instance" }, .upstream = .{ .value = "ses_upstream" } };
        const request: c.Request = if (attach) .{ .attach = .{ .session = session } } else .{ .open = .{ .existing = .{ .session = session } } };
        _ = try runtime.asAdapter().dispatch(a, request);
        const sent = try std.json.parseFromSlice(std.json.Value, a, runtime.transport.sent[0..runtime.transport.len], .{});
        const params = sent.value.object.get("params").?;
        try std.testing.expectEqualStrings("session/resume", sent.value.object.get("method").?.string);
        try std.testing.expectEqualStrings("ses_upstream", params.object.get("sessionId").?.string);
        try std.testing.expectEqualStrings("/tmp/spica", params.object.get("cwd").?.string);
        try std.testing.expectError(error.NotReady, runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "too early" } }));
        try std.testing.expect((try textFrame(&runtime, a, "old history")) == null);
        // Resume replies need not echo sessionId; the correlated request binds it.
        _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}");
        const observed = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"opencode/big-pickle\"}]}}")).?.body.session;
        try std.testing.expectEqualStrings("ses_upstream", observed.upstream.value);
        try std.testing.expectEqualStrings("new-instance", observed.instance.value);
        try std.testing.expect((try runtime.poll(a)).?.body == .selection);
        _ = try runtime.asAdapter().dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "continue" } });
        const start = try std.json.parseFromSlice(std.json.Value, a, runtime.transport.sent[0..runtime.transport.len], .{});
        try std.testing.expectEqualStrings("ses_upstream", start.value.object.get("params").?.object.get("sessionId").?.string);
    }
}

test "ACP missing unsupported or mismatched resume cannot create or start" {
    for ([_]bool{ false, true }) |supported| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var runtime: Runtime = undefined;
        try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "new-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
        defer runtime.shutdown();
        _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
        runtime.resume_supported = supported;
        var session: c.Session = .{ .id = correlation.session, .instance = .{ .value = "old" }, .upstream = .{ .value = "" } };
        try std.testing.expectError(if (supported) error.MissingSession else error.CapabilityUnavailable, runtime.dispatch(a, .{ .attach = .{ .session = session } }));
        session.upstream.value = "missing-session";
        try std.testing.expectError(error.CapabilityUnavailable, runtime.dispatch(a, .{ .attach = .{ .session = session, .after = .{ .value = "cursor" } } }));
        try std.testing.expectEqual(@as(i64, 1), runtime.request_id);
        if (!supported) continue;
        _ = try runtime.dispatch(a, .{ .attach = .{ .session = session } });
        const failure = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32002,\"message\":\"session not found\"}}")).?;
        try std.testing.expectEqualStrings("session_resume_failed", failure.body.failure.code);
        try std.testing.expectEqualStrings("session not found", failure.body.failure.detail);
        try std.testing.expectEqualStrings("session", failure.correlation.session.value);
        try std.testing.expectError(error.NotReady, runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "never sent" } }));
        try std.testing.expectError(error.NotReady, runtime.dispatch(a, .{ .open = .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = selection } } }));
        try std.testing.expectEqual(@as(i64, 2), runtime.request_id);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "new-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
    defer runtime.shutdown();
    _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
    _ = try runtime.dispatch(a, .{ .attach = .{ .session = .{ .id = correlation.session, .instance = .{ .value = "old" }, .upstream = .{ .value = "exact" } } } });
    try std.testing.expectError(error.InvalidCorrelation, consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"replacement\"}}"));
    try std.testing.expectError(error.NotReady, runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "never sent" } }));
    try std.testing.expectEqual(@as(i64, 2), runtime.request_id);
}
test "ACP common adapter selection is negotiated not inferred and observations own text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    try std.testing.expect(runtime.resolveSelection(selection).effective != null);
    try std.testing.expectEqual(c.Readiness.unknown, runtime.accountStatus().readiness);
    const first = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"ses_upstream\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hé\"}}}}")).?;
    try std.testing.expectEqualStrings("hé", first.body.chunk.text);
    const second = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"ses_upstream\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"llo\"}}}}")).?;
    try std.testing.expectEqual(@as(u64, 3), second.body.chunk.offset);
    try std.testing.expectEqualStrings("hé", first.body.chunk.text);
    try std.testing.expectEqual(c.Status.unsupported, runtime.discover().capabilities[@intFromEnum(c.Capability.coordinator_bridge)].status);
}
test "ACP permissions bind complete action and preserve offered once option IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    const event = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":\"permission-1\",\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"ses_upstream\",\"toolCall\":{\"toolCallId\":\"call1\",\"title\":\"write file\"},\"options\":[{\"optionId\":\"actual-allow\",\"kind\":\"allow_once\"},{\"optionId\":\"danger\",\"kind\":\"allow_always\"},{\"optionId\":\"actual-deny\",\"kind\":\"reject_once\"}]}}")).?;
    const approval = event.body.approval;
    try std.testing.expectError(error.InvalidCorrelation, runtime.dispatch(a, .{ .respond_approval = .{ .correlation = approval.correlation, .decision = .allow, .action_digest = "stale" } }));
    _ = try runtime.dispatch(a, .{ .respond_approval = .{ .correlation = approval.correlation, .decision = .allow, .action_digest = approval.action_digest } });
    try std.testing.expect(std.mem.indexOf(u8, runtime.transport.sent[0..runtime.transport.len], "actual-allow") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transport.sent[0..runtime.transport.len], "danger") == null);
    try std.testing.expectError(error.InvalidCorrelation, runtime.dispatch(a, .{ .respond_approval = .{ .correlation = approval.correlation, .decision = .allow, .action_digest = approval.action_digest } }));
}
test "ACP error never completes and mismatched session response fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    try std.testing.expectError(error.InvalidCorrelation, consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"wrong\",\"update\":{}}}"));
    try std.testing.expectError(error.UnexpectedResponse, consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}"));
    const failure = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32000,\"message\":\"auth required\"}}")).?;
    try std.testing.expect(failure.body == .failure);
    try std.testing.expectEqualStrings("auth required", failure.body.failure.detail);
}
test "ACP cancellation waits for upstream stop and does not claim tools stopped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    _ = try runtime.dispatch(a, .{ .cancel = .{ .correlation = correlation, .reason = "stop" } });
    const stopped = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"stopReason\":\"cancelled\"}}")).?;
    try std.testing.expect(stopped.body == .cancelled);
    try std.testing.expect(!stopped.body.cancelled.tools_stopped);
    const before = runtime.request_id;
    try std.testing.expectError(error.NotReady, runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "never retried" } }));
    try std.testing.expectEqual(before, runtime.request_id);
}
test "ACP exact model and version mismatches are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
    defer runtime.shutdown();
    try std.testing.expectError(error.RuntimeVersionMismatch, consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"1.0\"}}}"));
}

fn textFrame(runtime: *Runtime, a: std.mem.Allocator, bytes: []const u8) !?c.Observation {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"ses_upstream\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"\"}}}}", .{});
    defer parsed.deinit();
    parsed.value.object.getPtr("params").?.object.getPtr("update").?.object.getPtr("content").?.object.getPtr("text").?.* = .{ .string = bytes };
    return runtime.consume(a, parsed.value);
}

test "ACP durable splitting preserves multibyte boundaries and applies polling backpressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    var source: [6149]u8 = undefined;
    @memset(&source, 'a');
    @memcpy(source[2047..2051], "😀");
    @memcpy(source[4094..4097], "€");
    var current = (try textFrame(&runtime, a, &source)).?;
    try std.testing.expectEqual(@as(usize, 2047), current.body.chunk.text.len);
    try std.testing.expectError(error.Backpressure, textFrame(&runtime, a, "not consumed"));
    var offset: usize = 0;
    var previous: []const u8 = "";
    while (true) {
        const chunk = current.body.chunk;
        try std.testing.expect(chunk.text.len <= 2048);
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk.text));
        try std.testing.expectEqual(offset, chunk.offset);
        try std.testing.expectEqualSlices(u8, source[offset..][0..chunk.text.len], chunk.text);
        try std.testing.expect(!std.mem.eql(u8, previous, current.upstream_event));
        try std.testing.expect(c.frameBytes(current) <= 4096);
        previous = current.upstream_event;
        offset += chunk.text.len;
        if (offset == source.len) break;
        current = (try runtime.poll(a)).?;
        try std.testing.expectEqual(@as(usize, 0), runtime.transport.polls);
    }
    try std.testing.expectEqual(source.len, offset);
}

test "ACP fragmented UTF8 scalars are retained exactly and incomplete completion fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    try std.testing.expect((try textFrame(&runtime, a, "\xf0\x9f")) == null);
    const joined = (try textFrame(&runtime, a, "\x98\x80!")).?;
    try std.testing.expectEqualStrings("😀!", joined.body.chunk.text);
    try std.testing.expectEqual(@as(u64, 0), joined.body.chunk.offset);
    try std.testing.expect((try textFrame(&runtime, a, "\xe2")) == null);
    try std.testing.expectError(error.IncompleteUtf8, consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"stopReason\":\"end_turn\"}}"));
}

test "ACP large tool result streams exact readable text then one terminal event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    const body = try a.alloc(u8, 9000);
    for (0..3000) |index| @memcpy(body[index * 3 ..][0..3], "界");
    const wire = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "session/update", .params = .{ .sessionId = "ses_upstream", .update = .{ .sessionUpdate = "tool_call_update", .toolCallId = "large-tool", .status = "completed", .content = .{.{ .type = "text", .text = body }} } } }, .{});
    const expected = body;
    var current = (try consume(&runtime, a, wire)).?;
    var offset: usize = 0;
    while (current.body == .chunk) {
        const chunk = current.body.chunk;
        try std.testing.expectEqualStrings("large-tool", current.correlation.tool.?.value);
        try std.testing.expectEqualStrings("large-tool", chunk.block.value);
        try std.testing.expectEqual(offset, chunk.offset);
        try std.testing.expect(chunk.text.len <= 2048 and c.frameBytes(current) <= 4096);
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk.text));
        try std.testing.expectEqualSlices(u8, expected[offset..][0..chunk.text.len], chunk.text);
        offset += chunk.text.len;
        current = (try runtime.poll(a)).?;
        try std.testing.expectEqual(@as(usize, 0), runtime.transport.polls);
    }
    try std.testing.expectEqual(expected.len, offset);
    try std.testing.expect(current.body == .tool_completed);
    try std.testing.expectEqualStrings("", current.body.tool_completed.result);
    try std.testing.expect((try runtime.poll(a)) == null);
    try std.testing.expectEqual(@as(usize, 1), runtime.transport.polls);
}

test "ACP readable tool output retains file changes and unfamiliar content without JSON wrapping text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    const wire = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "session/update", .params = .{ .sessionId = "ses_upstream", .update = .{
        .sessionUpdate = "tool_call_update",
        .toolCallId = "file-tool",
        .status = "completed",
        .content = .{
            .{ .type = "content", .content = .{ .type = "text", .text = "Updated café.txt" } },
            .{ .type = "diff", .path = "/tmp/café.txt", .oldText = "before 世界", .newText = "after 世界" },
            .{ .type = "future", .detail = "retain me" },
        },
    } } }, .{});
    const result = (try consume(&runtime, a, wire)).?;
    try std.testing.expectEqualStrings("Updated café.txt\n\nFile: /tmp/café.txt\nBefore:\n```\nbefore 世界\n```\nAfter:\n```\nafter 世界\n```\n\n{\"type\":\"future\",\"detail\":\"retain me\"}", result.body.chunk.text);
    try std.testing.expectEqualStrings("file-tool", result.correlation.tool.?.value);
    try std.testing.expect((try runtime.poll(a)).?.body == .tool_completed);
    const empty = (try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"ses_upstream\",\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"empty\",\"status\":\"failed\"}}}")).?;
    try std.testing.expectEqual(.failed, empty.body.tool_completed.outcome);
    try std.testing.expect((try runtime.poll(a)) == null);
}

test "ACP tool file creation deletion and formatting overflow preserve bounded admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    for ([_]struct { before: ?[]const u8, after: ?[]const u8, expected: []const u8 }{
        .{ .before = null, .after = "new 世界\n", .expected = "File: /tmp/file\nAfter:\n```\nnew 世界\n\n```" },
        .{ .before = "old 世界\n", .after = null, .expected = "File: /tmp/file\nBefore:\n```\nold 世界\n\n```\nDeleted" },
    }) |case| {
        const wire = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "session/update", .params = .{ .sessionId = "ses_upstream", .update = .{
            .sessionUpdate = "tool_call_update",
            .toolCallId = "file-tool",
            .status = "completed",
            .content = .{.{ .type = "diff", .path = "/tmp/file", .oldText = case.before, .newText = case.after }},
        } } }, .{});
        const result = (try consume(&runtime, a, wire)).?;
        try std.testing.expectEqualStrings(case.expected, result.body.chunk.text);
        try std.testing.expect((try runtime.poll(a)).?.body == .tool_completed);
    }
    const body = try a.alloc(u8, runtime.pending_bytes.len);
    @memset(body, 'x');
    const oversized = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "session/update", .params = .{ .sessionId = "ses_upstream", .update = .{
        .sessionUpdate = "tool_call_update",
        .toolCallId = "too-large",
        .status = "completed",
        .content = .{.{ .type = "diff", .path = "/tmp/file", .oldText = @as(?[]const u8, null), .newText = body }},
    } } }, .{});
    try std.testing.expectError(error.FrameTooLarge, consume(&runtime, a, oversized));
    try std.testing.expectEqual(.none, runtime.pending_kind);
}

test "ACP opaque workspace identity stays separate from explicit cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    var requested = selection;
    requested.workspace = .{ .value = "workspace-opaque-db-id" };
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/explicit-process-root", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
    defer runtime.shutdown();
    _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
    _ = try runtime.dispatch(a, .{ .open = .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = requested } } });
    try std.testing.expect(std.mem.indexOf(u8, runtime.transport.sent[0..runtime.transport.len], "\"cwd\":\"/tmp/explicit-process-root\"") != null);
    try std.testing.expectEqualStrings("workspace-opaque-db-id", runtime.selection.workspace.value);
    try std.testing.expectEqual(c.Readiness.unknown, runtime.resolveSelection(requested).readiness);
    _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"ses_upstream\"}}");
    _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"opencode/big-pickle\"}]}}");
    try std.testing.expect(c.equal(requested, runtime.resolveSelection(requested).effective.?));
}

test "ACP bridge registration persists through create and resume until shutdown" {
    const helper = @import("runtime/opencode_bridge.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try helper.serialize(std.testing.allocator, .{ .url = "http://127.0.0.1:4321/mcp/app-session", .token = "per-session-token" });
    defer std.testing.allocator.free(json);
    for ([_]bool{ false, true }) |is_resume| {
        var runtime: Runtime = undefined;
        try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown }, .mcp_servers = json });
        defer runtime.shutdown();
        try std.testing.expect(!runtime.asAdapter().ready());
        _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
        try std.testing.expect(runtime.asAdapter().ready());
        const open: c.Open = if (is_resume)
            .{ .existing = .{ .session = .{ .id = correlation.session, .instance = .{ .value = "old-instance" }, .upstream = .{ .value = "existing-upstream" } } } }
        else
            .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = selection } };
        _ = try runtime.dispatch(a, .{ .open = open });
        const sent = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, runtime.transport.sent[0..runtime.transport.len], .{});
        defer sent.deinit();
        try std.testing.expectEqualStrings(if (is_resume) "session/resume" else "session/new", sent.value.object.get("method").?.string);
        const registered = try std.json.Stringify.valueAlloc(std.testing.allocator, sent.value.object.get("params").?.object.get("mcpServers").?, .{});
        defer std.testing.allocator.free(registered);
        try std.testing.expectEqualStrings(json, registered);
        runtime.shutdown();
        try std.testing.expect(runtime.asAdapter().ready());
        try std.testing.expectEqualStrings(json, runtime.config.mcp_servers);
    }
}

test "ACP bridge malformed registration fails before initialization" {
    var runtime: Runtime = undefined;
    try std.testing.expectError(error.InvalidMcpServers, runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown }, .mcp_servers = "{}" }));
    try std.testing.expectError(error.UnexpectedEndOfInput, runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown }, .mcp_servers = "[" }));
}

test "ACP initialization error and version mismatch end readiness wait" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |wrong_version| {
        var runtime: Runtime = undefined;
        try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
        defer runtime.shutdown();
        try std.testing.expect(!runtime.asAdapter().ready());
        if (wrong_version) {
            try std.testing.expectError(error.RuntimeVersionMismatch, consume(&runtime, arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"wrong\"}}}"));
        } else {
            const failed = (try consume(&runtime, arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"initialization refused\"}}")).?;
            try std.testing.expect(failed.body == .failure);
        }
        try std.testing.expect(runtime.asAdapter().ready());
        try std.testing.expectError(error.NotReady, runtime.dispatch(arena.allocator(), .{ .open = .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = selection } } }));
    }
}

test "ACP pump error ends initialization and emits one disconnect before reap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try runtime.init(std.testing.allocator, .{ .pump_error = true }, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "failed-init" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
    defer runtime.shutdown();
    const adapter = runtime.asAdapter();
    try std.testing.expect(!adapter.ready());
    try std.testing.expectError(error.TransportWrite, adapter.pump());
    try std.testing.expect(adapter.ready());
    try std.testing.expect(!runtime.transport.exited);
    const event = (try adapter.poll(a)).?;
    try std.testing.expect(event.body == .disconnect);
    try std.testing.expectEqualStrings("TransportWrite", event.body.disconnect.reason);
    try std.testing.expect(event.body.disconnect.continuity == .unknown);
    try std.testing.expectError(error.NotReady, adapter.dispatch(a, .{ .open = .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = selection } } }));
    try std.testing.expectError(error.TransportWrite, adapter.pump());
    try std.testing.expectEqual(@as(usize, 1), runtime.transport.pumps);
    try std.testing.expect((try adapter.poll(a)) == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.transport.polls);
}

test "ACP pump error during a turn preserves run correlation and drains accepted text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    const source = "x" ** 4096;
    _ = try textFrame(&runtime, a, source);
    runtime.transport.pump_error = true;
    try std.testing.expectError(error.TransportWrite, runtime.pump());
    const piece = (try runtime.poll(a)).?;
    try std.testing.expect(piece.body == .chunk);
    try std.testing.expectEqual(@as(u64, 2048), piece.body.chunk.offset);
    const event = (try runtime.poll(a)).?;
    try std.testing.expect(event.body == .disconnect);
    try std.testing.expect(c.equal(correlation, event.correlation));
    try std.testing.expect((try runtime.poll(a)) == null);
    try std.testing.expectEqual(@as(usize, 0), runtime.transport.polls);
}

fn permissionForTool(runtime: *Runtime, a: std.mem.Allocator, tool: []const u8) !c.Observation {
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .id = tool,
        .method = "session/request_permission",
        .params = .{
            .sessionId = "ses_upstream",
            .toolCall = .{ .toolCallId = tool, .title = "controlled printf", .rawInput = .{ .command = "printf proof" } },
            .options = .{ .{ .optionId = "once", .kind = "allow_once" }, .{ .optionId = "reject", .kind = "reject_once" } },
        },
    }, .{});
    return (try consume(runtime, a, bytes)).?;
}

fn toolUpdate(runtime: *Runtime, a: std.mem.Allocator, tool: []const u8, status: []const u8, input: ?[]const u8) !?c.Observation {
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .jsonrpc = "2.0",
        .method = "session/update",
        .params = .{
            .sessionId = "ses_upstream",
            .update = .{ .sessionUpdate = "tool_call_update", .toolCallId = tool, .status = status, .title = "controlled printf", .rawInput = if (input) |command| .{ .command = command } else null, .content = .{.{ .type = "content", .content = .{ .type = "text", .text = "proof" } }} },
        },
    }, .{});
    return consume(runtime, a, bytes);
}

test "ACP approved tool authority survives postdecision status updates and interleaving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    const first = (try permissionForTool(&runtime, a, "tool-A")).body.approval;
    _ = try runtime.dispatch(a, .{ .respond_approval = .{ .correlation = first.correlation, .decision = .allow, .action_digest = first.action_digest } });
    const second = (try permissionForTool(&runtime, a, "tool-B")).body.approval;
    _ = try runtime.dispatch(a, .{ .respond_approval = .{ .correlation = second.correlation, .decision = .deny, .action_digest = second.action_digest } });
    const first_update = (try toolUpdate(&runtime, a, "tool-A", "in_progress", null)).?;
    try std.testing.expectEqualStrings(first.action_digest, first_update.body.tool_started.action_digest);
    const second_update = (try toolUpdate(&runtime, a, "tool-B", "in_progress", "printf proof")).?;
    try std.testing.expectEqualStrings(second.action_digest, second_update.body.tool_started.action_digest);
    try std.testing.expectError(error.ActionChanged, toolUpdate(&runtime, a, "tool-A", "in_progress", "different command"));
    try std.testing.expectError(error.ActionChanged, toolUpdate(&runtime, a, "tool-A", "completed", "different command"));
    const result = (try toolUpdate(&runtime, a, "tool-A", "completed", null)).?;
    try std.testing.expect(result.body == .chunk);
    try std.testing.expectEqualStrings("proof", result.body.chunk.text);
    try std.testing.expectEqualStrings("tool-A", result.correlation.tool.?.value);
    const terminal = (try runtime.poll(a)).?;
    try std.testing.expect(terminal.body == .tool_completed);
    try std.testing.expect(terminal.body.tool_completed.outcome == .succeeded);
    _ = try toolUpdate(&runtime, a, "tool-B", "failed", null);
    const denied = (try runtime.poll(a)).?;
    try std.testing.expect(denied.body == .tool_completed);
    try std.testing.expect(denied.body.tool_completed.outcome == .failed);
    try std.testing.expect(runtime.tool_authorities == null);
}

test "ACP permission authority index is bounded by turn storage and reset per turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    _ = try permissionForTool(&runtime, a, "prior-tool");
    _ = try consume(&runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"stopReason\":\"end_turn\"}}");
    _ = try runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "next" } });
    try std.testing.expect(runtime.tool_authorities == null);
    const update = (try toolUpdate(&runtime, a, "prior-tool", "in_progress", null)).?;
    try std.testing.expectEqualStrings("prior-tool", update.body.tool_started.action_digest);
    for (0..256) |_| {
        const event = permissionForTool(&runtime, a, "bounded-tool") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            return;
        };
        const approval = event.body.approval;
        _ = try runtime.dispatch(a, .{ .respond_approval = .{ .correlation = approval.correlation, .decision = .deny, .action_digest = approval.action_digest } });
    }
    return error.ExpectedBoundedAuthorityStorage;
}

test "ACP effort acknowledgement must retain exact model and initialize uses an object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime: Runtime = undefined;
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .cwd = "/tmp/spica", .instance = .{ .value = "test" }, .account = .{ .reference = selection.account_ref, .readiness = .unknown } });
    defer runtime.shutdown();
    const initialize = try std.json.parseFromSlice(std.json.Value, allocator, runtime.transport.sent[0..runtime.transport.len], .{});
    try std.testing.expect(initialize.value.object.get("params").?.object.get("clientCapabilities").? == .object);
    runtime.session = .{ .id = correlation.session, .instance = .{ .value = "test" }, .upstream = .{ .value = "upstream" } };
    runtime.selection.effort = "high";
    runtime.phase = .effort;
    try std.testing.expectError(error.SelectionUnavailable, consume(&runtime, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"opencode/substituted\"},{\"id\":\"effort\",\"currentValue\":\"high\"}]}}"));
    _ = try consume(&runtime, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"opencode/big-pickle\"},{\"id\":\"effort\",\"currentValue\":\"high\"}]}}");
    try std.testing.expect(runtime.resolveSelection(runtime.selection).effective != null);
    const selected = (try runtime.poll(allocator)).?;
    try std.testing.expect(selected.body == .selection);
    try std.testing.expect(c.equal(runtime.selection, selected.body.selection.effective.?));
    try std.testing.expect((try runtime.poll(allocator)) == null);
}

test "ACP failure preserves provider error data in bounded diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, allocator);
    defer runtime.shutdown();
    const failed = (try consume(&runtime, allocator, "{\"jsonrpc\":\"2.0\",\"id\":4,\"error\":{\"code\":-32603,\"message\":\"Internal error\",\"data\":{\"type\":\"provider.free-limit\",\"status\":429}}}")).?;
    try std.testing.expect(failed.body == .failure);
    try std.testing.expect(failed.body.failure.detail.len <= 2048);
    try std.testing.expect(std.mem.indexOf(u8, failed.body.failure.detail, "provider.free-limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.body.failure.detail, "429") != null);
}

test "ACP Start serializes exact full composer prompts including sixfold escaping" {
    for ([_][]const u8{ "a" ** 65536, "😀" ** 16384, "\x01" ** 65536, "\n\"\\\t" ** 16384 }) |prompt| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var runtime: Runtime = undefined;
        try ready(&runtime, a);
        defer runtime.shutdown();
        const before = runtime.transport.len;
        try std.testing.expectError(error.InvalidPrompt, runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "a" ** 65537 } }));
        try std.testing.expectError(error.InvalidPrompt, runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "\xf0\x9f" } }));
        try std.testing.expectEqual(before, runtime.transport.len);
        _ = try runtime.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = prompt } });
        const line = runtime.transport.sent[0..runtime.transport.len];
        try std.testing.expect(line.len <= @import("runtime/prompt.zig").json_bytes);
        if (prompt[0] == 1) try std.testing.expect(line.len > 6 * prompt.len);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        try std.testing.expectEqualStrings("session/prompt", parsed.value.object.get("method").?.string);
        try std.testing.expectEqualStrings(prompt, parsed.value.object.get("params").?.object.get("prompt").?.array.items[0].object.get("text").?.string);
    }
}
