const std = @import("std");
const c = @import("../contract.zig");
const codex = @import("codex.zig");
const Mock = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,
    input: std.ArrayList([]const u8) = .empty,
    exited: bool = false,
    pub fn send(self: *@This(), line: []const u8) !void { try self.lines.append(self.allocator, try self.allocator.dupe(u8, line)); }
    pub fn pump(_: *@This()) !void {}
    pub fn poll(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 { if (self.input.items.len == 0) return null; const line = self.input.orderedRemove(0); return try allocator.dupe(u8, line); }
    pub fn deinit(_: *@This()) void {}
};
const selection: c.Selection = .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "gpt-6.1-sol", .effort = "medium", .account_ref = "/tmp/spica-codex", .workspace = .{ .value = "opaque-workspace" } };
test "Codex initialize account create stream approval cancel exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "test" }); defer runtime.deinit();
    try wire.input.append(a, "{\"id\":1,\"result\":{\"userAgent\":\"codex/0.163.0\"}}");
    try runtime.pump();
    try wire.input.append(a, "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try runtime.pump();
    try std.testing.expectEqual(c.Readiness.ready, runtime.accountStatus().readiness);
    const receipt = try runtime.dispatch(a, .{ .open = .{ .create = .{ .effect = .{ .value = "open" }, .session = .{ .value = "session" }, .selection = selection } } });
    try std.testing.expectEqual(.acknowledged, receipt.outcome);
    try wire.input.append(a, "{\"id\":3,\"result\":{\"thread\":{\"id\":\"upstream\"},\"model\":\"gpt-6.1-sol\",\"modelProvider\":\"openai\",\"cwd\":\"/tmp/project\",\"reasoningEffort\":\"medium\"}}");
    try runtime.pump();
    try std.testing.expect((try runtime.poll(a)).?.body == .session);
    try std.testing.expect((try runtime.poll(a)).?.body == .selection);
    try std.testing.expectEqualStrings("opaque-workspace", runtime.config.selection.workspace.value);
    try std.testing.expect(std.mem.indexOf(u8, wire.lines.items[3], "\"cwd\":\"/tmp/project\"") != null);
    const correlation: c.Correlation = .{ .session = .{ .value = "session" }, .run = .{ .value = "run" }, .effect = .{ .value = "start" } };
    _ = try runtime.asAdapter().dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "hello" } });
    try wire.input.append(a, "{\"id\":4,\"result\":{\"turn\":{\"id\":\"turn\"}}}");
    try wire.input.append(a, "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"upstream\",\"itemId\":\"message\",\"delta\":\"hello\"}}");
    try runtime.pump();
    try std.testing.expectEqualStrings("hello", (try runtime.poll(a)).?.body.chunk.text);
    try wire.input.append(a, "{\"id\":\"approval-rpc\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"upstream\",\"itemId\":\"tool\",\"command\":\"echo hi\"}}");
    try runtime.pump();
    const approval = (try runtime.poll(a)).?.body.approval;
    try std.testing.expectError(error.InvalidCorrelation, runtime.dispatch(a, .{ .respond_approval = .{ .correlation = approval.correlation, .action_digest = "wrong", .decision = .allow } }));
    _ = try runtime.dispatch(a, .{ .respond_approval = .{ .correlation = approval.correlation, .action_digest = approval.action_digest, .decision = .deny } });
    try std.testing.expect(std.mem.indexOf(u8, wire.lines.items[wire.lines.items.len-1], "decline") != null);
    try wire.input.append(a, "{\"id\":\"tool-rpc\",\"method\":\"item/tool/call\",\"params\":{\"threadId\":\"upstream\",\"callId\":\"call-1\",\"tool\":\"task.list\",\"arguments\":{\"parent_run\":\"run\"}}}");
    try runtime.pump();
    const call = (try runtime.asAdapter().pollTool(a)).?;
    try std.testing.expectEqualStrings("call-1", call.call_id);
    try std.testing.expectEqualStrings("run", call.correlation.run.?.value);
    try std.testing.expectError(error.InvalidCorrelation, runtime.asAdapter().respondTool("wrong", true, "{}"));
    try runtime.asAdapter().respondTool(call.request_id_json, true, "{\"tasks\":[]}");
    try std.testing.expect((try runtime.asAdapter().pollTool(a)) == null);
    _ = try runtime.dispatch(a, .{ .cancel = .{ .correlation = correlation, .reason = "stop" } });
    try wire.input.append(a, "{\"id\":5,\"result\":{}}");
    try wire.input.append(a, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"status\":\"interrupted\"}}}");
    try runtime.pump();
    try std.testing.expect((try runtime.poll(a)).?.body == .cancelled);
    wire.exited = true; try runtime.pump();
    try std.testing.expect((try runtime.poll(a)).?.body == .disconnect);
}

extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
test "Codex installed isolated handshake and unsigned account" {
    if (getenv("SPICA_CODEX_LIVE_PROBE") == null) return error.SkipZigTest;
    const transport = @import("transport.zig");
    var path: [40:0]u8 = undefined;
    const template = "/tmp/spica-codex-probe-XXXXXX";
    @memcpy(path[0..template.len], template); path[template.len] = 0;
    const directory = mkdtemp(&path) orelse return error.TempDirectory;
    const root = std.mem.span(directory);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const home = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0);
    const codex_home = try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{root}, 0);
    var wire = try transport.Transport.init(a, .{ .argv = &.{ "/usr/bin/codex", "app-server", "--stdio" }, .cwd = directory[0..root.len :0], .environment = &.{ home, codex_home, "PATH=/usr/bin:/bin" } });
    defer wire.deinit();
    var runtime = try codex.Runtime.init(a, &wire, .{ .selection = selection, .cwd = root, .instance = "isolated-probe" }); defer runtime.deinit();
    const started = transport.c.spica_monotonic_ms();
    while (transport.c.spica_monotonic_ms()-started < 15000) {
        try runtime.pump();
        if (runtime.initialized and runtime.pending == null) {
            try std.testing.expectEqual(c.Readiness.unavailable, runtime.accountStatus().readiness);
            std.debug.print("isolated Codex0.163.0 initialized; managed ChatGPT account absent; state={s}\\n", .{root});
            return;
        }
        _ = transport.c.spica_process_poll(&wire.process, -1, @intFromBool(wire.input_len != 0), 20);
    }
    return error.HandshakeTimeout;
}
