const std = @import("std");
const c = @import("contract.zig");
const opencode = @import("runtime/opencode.zig");
const Mock = struct {
    sent: [65536]u8 = undefined,
    len: usize = 0,
    exited: bool = false,
    polls: usize = 0,
    pub fn send(self: *Mock, bytes: []const u8) !void {
        @memcpy(self.sent[0..bytes.len], bytes);
        self.len = bytes.len;
    }
    pub fn pump(_: *Mock) !void {}
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
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
    _ = try consume(runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentInfo\":{\"version\":\"2.1.4\"},\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}}");
    _ = try runtime.asAdapter().dispatch(a, .{ .open = .{ .create = .{ .session = correlation.session, .effect = correlation.effect.?, .selection = selection } } });
    _ = try consume(runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"ses_upstream\"}}");
    const event = (try consume(runtime, a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"opencode/big-pickle\"}]}}")).?;
    try std.testing.expect(event.body == .session);
}
fn prompting(runtime: *Runtime, a: std.mem.Allocator) !void {
    try ready(runtime, a);
    _ = try runtime.asAdapter().dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "hello" } });
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
}
test "ACP exact model and version mismatches are explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try runtime.init(std.testing.allocator, .{}, .{ .selection = selection, .instance = .{ .value = "test-instance" }, .account = .{ .reference = "isolated", .readiness = .unknown } });
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

test "ACP large tool result streams exact canonical content then one terminal event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runtime: Runtime = undefined;
    try prompting(&runtime, a);
    defer runtime.shutdown();
    const body = try a.alloc(u8, 9000);
    @memset(body, 'z');
    const wire = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .method = "session/update", .params = .{ .sessionId = "ses_upstream", .update = .{ .sessionUpdate = "tool_call_update", .toolCallId = "large-tool", .status = "completed", .content = .{.{ .type = "text", .text = body }} } } }, .{});
    const expected = try std.json.Stringify.valueAlloc(a, .{.{ .type = "text", .text = body }}, .{});
    var current = (try consume(&runtime, a, wire)).?;
    var offset: usize = 0;
    while (current.body == .chunk) {
        const chunk = current.body.chunk;
        try std.testing.expectEqualStrings("large-tool", current.correlation.tool.?.value);
        try std.testing.expectEqualStrings("large-tool", chunk.block.value);
        try std.testing.expectEqual(offset, chunk.offset);
        try std.testing.expect(chunk.text.len <= 2048 and c.frameBytes(current) <= 4096);
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
