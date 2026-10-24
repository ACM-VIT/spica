const std = @import("std");
const c = @import("../contract.zig");
const codex = @import("codex.zig");
const Mock = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8) = .empty,
    input: std.ArrayList([]const u8) = .empty,
    exited: bool = false,
    pub fn send(self: *@This(), line: []const u8) !void {
        try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
    }
    pub fn pump(_: *@This()) !void {}
    pub fn poll(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 {
        if (self.input.items.len == 0) return null;
        const line = self.input.orderedRemove(0);
        return try allocator.dupe(u8, line);
    }
    pub fn deinit(_: *@This()) void {}
};
const selection: c.Selection = .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "gpt-6.1-sol", .effort = "medium", .account_ref = "/tmp/spica-codex", .workspace = .{ .value = "opaque-workspace" } };
test "Codex initialize account create stream approval cancel exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "test", .tool_bindings = &.{.{ .wire_name = "task_list", .application_name = "task.list" }} });
    defer runtime.deinit();
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
    try std.testing.expect(std.mem.indexOf(u8, wire.lines.items[wire.lines.items.len - 1], "decline") != null);
    try wire.input.append(a, "{\"id\":\"tool-rpc\",\"method\":\"item/tool/call\",\"params\":{\"threadId\":\"upstream\",\"turnId\":\"turn\",\"callId\":\"call-1\",\"tool\":\"task_list\",\"arguments\":{\"parent_run\":\"run\"}}}");
    try runtime.pump();
    const call = (try runtime.asAdapter().pollTool(a)).?;
    try std.testing.expectEqualStrings("call-1", call.call_id);
    try std.testing.expectEqualStrings("task.list", call.name);
    try std.testing.expectEqualStrings("run", call.correlation.run.?.value);
    try std.testing.expectError(error.InvalidCorrelation, runtime.asAdapter().respondTool("wrong", true, "{}"));
    try runtime.asAdapter().respondTool(call.request_id_json, true, "{\"tasks\":[]}");
    try std.testing.expect((try runtime.asAdapter().pollTool(a)) == null);
    _ = try runtime.dispatch(a, .{ .cancel = .{ .correlation = correlation, .reason = "stop" } });
    try wire.input.append(a, "{\"id\":5,\"result\":{}}");
    try wire.input.append(a, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"id\":\"turn\",\"status\":\"interrupted\"}}}");
    try runtime.pump();
    try std.testing.expect((try runtime.poll(a)).?.body == .cancelled);
    wire.exited = true;
    try runtime.pump();
    try std.testing.expect((try runtime.poll(a)).?.body == .disconnect);
}

extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
test "Codex installed isolated handshake and unsigned account" {
    if (getenv("SPICA_CODEX_LIVE_PROBE") == null) return error.SkipZigTest;
    const transport = @import("transport.zig");
    var path: [40:0]u8 = undefined;
    const template = "/tmp/spica-codex-probe-XXXXXX";
    @memcpy(path[0..template.len], template);
    path[template.len] = 0;
    const directory = mkdtemp(&path) orelse return error.TempDirectory;
    const root = std.mem.span(directory);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0);
    const codex_home = try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{root}, 0);
    var wire = try transport.Transport.init(a, .{ .argv = &.{ "/usr/bin/codex", "app-server", "--stdio" }, .cwd = directory[0..root.len :0], .environment = &.{ home, codex_home, "PATH=/usr/bin:/bin" } });
    defer wire.deinit();
    var runtime = try codex.Runtime.init(a, &wire, .{ .selection = selection, .cwd = root, .instance = "isolated-probe" });
    defer runtime.deinit();
    const started = transport.c.spica_monotonic_ms();
    while (transport.c.spica_monotonic_ms() - started < 15000) {
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

test "Codex resume retains explicit effort and tool callbacks reject stale turn authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var wire: Mock = .{ .allocator = allocator };
    var runtime = try codex.RuntimeFor(Mock).init(allocator, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "resume-fixture" });
    defer runtime.deinit();
    try wire.input.append(allocator, "{\"id\":1,\"result\":{\"userAgent\":\"codex/0.163.0\"}}");
    try wire.input.append(allocator, "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try runtime.pump();
    _ = try runtime.dispatch(allocator, .{ .attach = .{ .session = .{ .id = .{ .value = "session" }, .instance = .{ .value = "resume-fixture" }, .upstream = .{ .value = "upstream" } } } });
    const sent = try std.json.parseFromSlice(std.json.Value, allocator, wire.lines.items[wire.lines.items.len - 1], .{});
    try std.testing.expectEqualStrings("medium", sent.value.object.get("params").?.object.get("config").?.object.get("model_reasoning_effort").?.string);
    try wire.input.append(allocator, "{\"id\":3,\"result\":{\"thread\":{\"id\":\"upstream\"},\"model\":\"gpt-6.1-sol\",\"modelProvider\":\"openai\",\"cwd\":\"/tmp/project\",\"reasoningEffort\":\"medium\"}}");
    try runtime.pump();
    _ = try runtime.poll(allocator);
    _ = try runtime.poll(allocator);
    _ = try runtime.dispatch(allocator, .{ .start = .{ .correlation = .{ .session = .{ .value = "session" }, .run = .{ .value = "run" }, .effect = .{ .value = "start" } }, .prompt = "fixture" } });
    try wire.input.append(allocator, "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"id\":\"turn\"}}}");
    try wire.input.append(allocator, "{\"id\":4,\"result\":{\"turn\":{\"id\":\"turn\"}}}");
    try runtime.pump();
    try std.testing.expectEqualStrings("turn", runtime.turn);
    var wrong: c.Correlation = runtime.correlation;
    wrong.run = .{ .value = "another-run" };
    try std.testing.expectError(error.InvalidCorrelation, runtime.dispatch(allocator, .{ .cancel = .{ .correlation = wrong, .reason = "stale" } }));
    try wire.input.append(allocator, "{\"id\":\"tool\",\"method\":\"item/tool/call\",\"params\":{\"threadId\":\"upstream\",\"turnId\":\"old-turn\",\"callId\":\"call\",\"tool\":\"task.list\",\"arguments\":{}}}");
    try std.testing.expectError(error.InvalidCorrelation, runtime.pump());
    try std.testing.expect(runtime.disconnected);
    try std.testing.expect((try runtime.pollTool(allocator)) == null);
}

test "Codex open and restore RPC errors publish session correlated failure before any run" {
    for ([_]bool{ false, true }) |restore| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var wire: Mock = .{ .allocator = allocator };
        var runtime = try codex.RuntimeFor(Mock).init(allocator, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "rpc-rejection" });
        defer runtime.deinit();
        try wire.input.append(allocator, "{\"id\":1,\"result\":{\"userAgent\":\"codex/0.163.0\"}}");
        try wire.input.append(allocator, "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
        try runtime.pump();
        if (restore) {
            _ = try runtime.dispatch(allocator, .{ .attach = .{ .session = .{ .id = .{ .value = "session" }, .instance = .{ .value = "fixture" }, .upstream = .{ .value = "upstream" } } } });
        } else {
            _ = try runtime.dispatch(allocator, .{ .open = .{ .create = .{ .effect = .{ .value = "open" }, .session = .{ .value = "session" }, .selection = selection } } });
        }
        try wire.input.append(allocator, "{\"id\":3,\"error\":{\"code\":-32600,\"message\":\"dynamic tool name rejected\"}}");
        try runtime.pump();
        const failure = (try runtime.poll(allocator)).?;
        try std.testing.expect(failure.body == .failure);
        try std.testing.expect(failure.correlation.run == null);
        try std.testing.expectEqualStrings("session", failure.correlation.session.value);
        if (!restore) try std.testing.expectEqualStrings("open", failure.correlation.effect.?.value);
        try std.testing.expect(std.mem.indexOf(u8, failure.body.failure.detail, "dynamic tool name rejected") != null);
        try std.testing.expect((try runtime.poll(allocator)) == null);
        try std.testing.expect(runtime.pending == null);
    }
}

fn startErrorFixture(a: std.mem.Allocator, wire: *Mock, runtime: *codex.RuntimeFor(Mock)) !void {
    try wire.input.append(a, "{\"id\":1,\"result\":{\"userAgent\":\"codex/0.163.0\"}}");
    try wire.input.append(a, "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try runtime.pump();
    _ = try runtime.dispatch(a, .{ .open = .{ .create = .{ .effect = .{ .value = "open" }, .session = .{ .value = "session" }, .selection = selection } } });
    try wire.input.append(a, "{\"id\":3,\"result\":{\"thread\":{\"id\":\"upstream\"},\"model\":\"gpt-6.1-sol\",\"modelProvider\":\"openai\",\"cwd\":\"/tmp/project\",\"reasoningEffort\":\"medium\"}}");
    try runtime.pump();
    _ = try runtime.poll(a);
    _ = try runtime.poll(a);
    _ = try runtime.dispatch(a, .{ .start = .{ .correlation = .{ .session = .{ .value = "session" }, .run = .{ .value = "run" }, .effect = .{ .value = "start" } }, .prompt = "fixture only" } });
    try wire.input.append(a, "{\"id\":4,\"result\":{\"turn\":{\"id\":\"turn\"}}}");
    try runtime.pump();
}

test "Codex failed completion preserves usage limit message code and additional details without history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "errors" });
    defer runtime.deinit();
    try startErrorFixture(a, &wire, &runtime);
    try wire.input.append(a,
        \\{"method":"turn/completed","params":{"threadId":"upstream","turn":{"id":"turn","status":"failed","items":[{"private_history":"not diagnostic evidence"}],"error":{"message":"You’ve hit your usage limit. Try again Oct 31st 2026 12:07 AM","codexErrorInfo":"usageLimitExceeded","additionalDetails":"Selected account quota exhausted","code":"usage_limit_exceeded"}}}}
    );
    try runtime.pump();
    const observation = (try runtime.poll(a)).?;
    try std.testing.expectEqualStrings("run", observation.correlation.run.?.value);
    try std.testing.expectEqualStrings("turn", observation.correlation.upstream_turn.?.value);
    const detail = observation.body.failure.detail;
    for ([_][]const u8{ "You’ve hit your usage limit", "Oct 31st 2026", "usageLimitExceeded", "usage_limit_exceeded", "Selected account quota exhausted" }) |expected| try std.testing.expect(std.mem.indexOf(u8, detail, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "private_history") == null);
    try std.testing.expectEqualStrings(detail, runtime.diagnostic);
    try std.testing.expectEqualStrings("", runtime.turn);
    // A subsequent run must not inherit the previous run's quota diagnostic.
    _ = try runtime.dispatch(a, .{ .start = .{ .correlation = .{ .session = .{ .value = "session" }, .run = .{ .value = "next-run" }, .effect = .{ .value = "next-start" } }, .prompt = "fixture" } });
    try wire.input.append(a, "{\"id\":5,\"result\":{\"turn\":{\"id\":\"next-turn\"}}}");
    try wire.input.append(a, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"id\":\"next-turn\",\"status\":\"failed\",\"error\":null}}}");
    try runtime.pump();
    const next = (try runtime.poll(a)).?;
    try std.testing.expectEqualStrings("next-run", next.correlation.run.?.value);
    try std.testing.expectEqualStrings("Codex turn did not complete", next.body.failure.detail);
}

test "Codex retry errors remain nonterminal bounded and correlated with terminal fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "retry-errors" });
    defer runtime.deinit();
    try startErrorFixture(a, &wire, &runtime);
    const retained = runtime.state.end_index;
    const retry =
        \\{"method":"error","params":{"threadId":"upstream","turnId":"turn","willRetry":true,"error":{"message":"Response stream disconnected; retrying","codexErrorInfo":{"responseStreamDisconnected":{"httpStatusCode":503}},"additionalDetails":"upstream request diagnostic"}}}
    ;
    for (0..1000) |_| {
        try wire.input.append(a, retry);
        try runtime.pump();
        try std.testing.expect((try runtime.poll(a)) == null);
    }
    try std.testing.expectEqual(retained, runtime.state.end_index);
    try std.testing.expect(!runtime.disconnected);
    // Old-turn and foreign-thread errors/completions cannot poison this run.
    try wire.input.append(a, "{\"method\":\"error\",\"params\":{\"threadId\":\"upstream\",\"turnId\":\"old-turn\",\"willRetry\":false,\"error\":{\"message\":\"stale failure\"}}}");
    try wire.input.append(a, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"id\":\"old-turn\",\"status\":\"failed\",\"error\":{\"message\":\"stale failure\"}}}}");
    try wire.input.append(a, "{\"method\":\"error\",\"params\":{\"threadId\":\"foreign\",\"turnId\":\"turn\",\"willRetry\":false,\"error\":{\"message\":\"foreign failure\"}}}");
    try runtime.pump();
    try std.testing.expect((try runtime.poll(a)) == null);
    try std.testing.expectEqualStrings("turn", runtime.turn);
    try wire.input.append(a, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"id\":\"turn\",\"status\":\"failed\",\"error\":null}}}");
    try runtime.pump();
    const failure = (try runtime.poll(a)).?.body.failure;
    for ([_][]const u8{ "Response stream disconnected", "responseStreamDisconnected", "503", "upstream request diagnostic" }) |expected| try std.testing.expect(std.mem.indexOf(u8, failure.detail, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.detail, "stale failure") == null);
}

test "Codex nonretry error is observable immediately and completion replaces it with bounded UTF8 details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "terminal-errors" });
    defer runtime.deinit();
    try startErrorFixture(a, &wire, &runtime);
    try wire.input.append(a, "{\"method\":\"error\",\"params\":{\"threadId\":\"upstream\",\"turnId\":\"turn\",\"willRetry\":false,\"error\":{\"message\":\"Quota exhausted\",\"codexErrorInfo\":\"usageLimitExceeded\",\"additionalDetails\":\"try later\"}}}");
    try runtime.pump();
    const immediate = (try runtime.poll(a)).?;
    try std.testing.expectEqualStrings("codex_error", immediate.body.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, immediate.body.failure.detail, "Quota exhausted") != null);
    const message = "界" ** 3000;
    const details = "🦉" ** 3000;
    const completion = try std.json.Stringify.valueAlloc(a, .{ .method = "turn/completed", .params = .{ .threadId = "upstream", .turn = .{ .id = "turn", .status = "failed", .@"error" = .{ .message = message, .codexErrorInfo = "usageLimitExceeded", .additionalDetails = details } } } }, .{});
    try wire.input.append(a, completion);
    try runtime.pump();
    const terminal = (try runtime.poll(a)).?;
    try std.testing.expect(terminal.body.failure.detail.len <= 2048);
    try std.testing.expect(std.unicode.utf8ValidateSlice(terminal.body.failure.detail));
    try std.testing.expect(std.mem.indexOf(u8, terminal.body.failure.detail, "usageLimitExceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.body.failure.detail, "🦉") != null);
    try std.testing.expect(std.mem.indexOf(u8, immediate.body.failure.detail, "Quota exhausted") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, terminal.body.failure.detail, .{});
    try std.testing.expect(parsed.value.object.get("message").?.string.len <= 768);
    try std.testing.expect(parsed.value.object.get("additionalDetails").?.string.len <= 768);
}

test "Codex retry can recover successfully and oversized structured error stays UTF8 bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "recovered-error" });
    defer runtime.deinit();
    try startErrorFixture(a, &wire, &runtime);
    try wire.input.append(a, "{\"method\":\"error\",\"params\":{\"threadId\":\"upstream\",\"turnId\":\"turn\",\"willRetry\":true,\"error\":{\"message\":\"transient\",\"codexErrorInfo\":\"serverOverloaded\"}}}");
    try wire.input.append(a, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"upstream\",\"turn\":{\"id\":\"turn\",\"status\":\"completed\",\"error\":null}}}");
    try runtime.pump();
    try std.testing.expect((try runtime.poll(a)).?.body == .completed);
    try std.testing.expect((try runtime.poll(a)) == null);
    _ = try runtime.dispatch(a, .{ .start = .{ .correlation = .{ .session = .{ .value = "session" }, .run = .{ .value = "next-run" }, .effect = .{ .value = "next-start" } }, .prompt = "fixture" } });
    try wire.input.append(a, "{\"id\":5,\"result\":{\"turn\":{\"id\":\"next-turn\"}}}");
    const oversized = try std.json.Stringify.valueAlloc(a, .{ .method = "turn/completed", .params = .{ .threadId = "upstream", .turn = .{ .id = "next-turn", .status = "failed", .@"error" = .{ .message = "failure", .codexErrorInfo = .{ .futureError = "界" ** 3000 } } } } }, .{});
    try wire.input.append(a, oversized);
    const retained = runtime.state.end_index;
    try runtime.pump();
    const failure = (try runtime.poll(a)).?.body.failure;
    try std.testing.expect(failure.detail.len <= 2048);
    try std.testing.expect(failure.detail.len >= 2045);
    try std.testing.expect(std.unicode.utf8ValidateSlice(failure.detail));
    // Only the next turn's ID, not the oversized error, enters retained state.
    try std.testing.expectEqual(retained + "next-turn".len, runtime.state.end_index);
}

fn loginFixture(a: std.mem.Allocator, wire: *Mock, runtime: *codex.RuntimeFor(Mock)) !void {
    try wire.input.append(a, "{\"id\":1,\"result\":{\"userAgent\":\"codex/0.163.0\"}}");
    try wire.input.append(a, "{\"id\":2,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try runtime.pump();
    try std.testing.expectEqual(c.Readiness.ready, runtime.readiness);
    try runtime.startLogin(true);
    try std.testing.expectEqual(c.Readiness.unknown, runtime.readiness);
    try wire.input.append(a, "{\"id\":3,\"result\":{\"loginId\":\"current\",\"verificationUrl\":\"https://example.invalid\",\"userCode\":\"FIXTURE\"}}");
    try runtime.pump();
}

test "Codex matched failed login is immediate owned bounded and cannot inherit account readiness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "login-failure" });
    defer runtime.deinit();
    try loginFixture(a, &wire, &runtime);
    // An account update while login is outstanding can refresh metadata but
    // cannot treat the previously signed-in account as this flow's completion.
    try wire.input.append(a, "{\"method\":\"account/updated\",\"params\":{}}");
    try runtime.pump();
    try std.testing.expect(runtime.pending.?.kind == .account);
    try wire.input.append(a, "{\"id\":4,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try runtime.pump();
    try std.testing.expectEqual(c.Readiness.unknown, runtime.readiness);
    try wire.input.append(a, "{\"method\":\"account/updated\",\"params\":{}}");
    try runtime.pump();
    const retained = runtime.state.end_index;
    const failure = try std.json.Stringify.valueAlloc(a, .{ .method = "account/login/completed", .params = .{ .loginId = "current", .success = false, .@"error" = "Sign-in denied: 界\n" ** 300 } }, .{});
    try wire.input.append(a, failure);
    try runtime.pump();
    try std.testing.expectEqual(c.Readiness.unavailable, runtime.readiness);
    try std.testing.expect(!runtime.login_active);
    try std.testing.expect(runtime.diagnostic.len <= 1024);
    try std.testing.expect(std.unicode.utf8ValidateSlice(runtime.diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, runtime.diagnostic, "Sign-in denied: 界") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, runtime.diagnostic, '\n') == null);
    const saved = try a.dupe(u8, runtime.diagnostic);
    // Drain a previously requested account read and late notifications after
    // the parse arena was reset. Neither may erase the matched failure.
    try wire.input.append(a, "{\"id\":5,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try wire.input.append(a, "{\"method\":\"account/updated\",\"params\":{}}");
    try wire.input.append(a, "{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"current\",\"success\":true}}");
    try runtime.pump();
    try std.testing.expectEqualStrings(saved, runtime.diagnostic);
    try std.testing.expectEqual(c.Readiness.unavailable, runtime.readiness);
    try std.testing.expectEqual(retained, runtime.state.end_index);
    try std.testing.expect(runtime.pending == null);
}

test "Codex stale login completions are ignored and success refresh survives a pending request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var wire: Mock = .{ .allocator = a };
    var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "login-success" });
    defer runtime.deinit();
    try loginFixture(a, &wire, &runtime);
    const sent = wire.lines.items.len;
    for ([_]bool{ false, true }) |success| {
        try wire.input.append(a, try std.json.Stringify.valueAlloc(a, .{ .method = "account/login/completed", .params = .{ .loginId = "superseded", .success = success, .@"error" = "stale denial" } }, .{}));
    }
    try runtime.pump();
    try std.testing.expectEqual(sent, wire.lines.items.len);
    try std.testing.expectEqual(c.Readiness.unknown, runtime.readiness);
    try std.testing.expectEqualStrings("", runtime.diagnostic);
    try wire.input.append(a, "{\"method\":\"account/updated\",\"params\":{}}");
    try runtime.pump();
    try wire.input.append(a, "{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"current\",\"success\":true}}");
    try runtime.pump();
    try std.testing.expect(runtime.account_refresh);
    try std.testing.expectEqual(@as(u64, 4), runtime.pending.?.id);
    try wire.input.append(a, "{\"method\":\"account/updated\",\"params\":{}}");
    try runtime.pump();
    try std.testing.expect(runtime.account_refresh);
    try wire.input.append(a, "{\"id\":4,\"result\":{\"account\":null}}");
    try runtime.pump();
    try std.testing.expectEqual(@as(u64, 5), runtime.pending.?.id);
    try std.testing.expect(!runtime.account_refresh);
    try wire.input.append(a, "{\"id\":5,\"result\":{\"account\":{\"type\":\"chatgpt\"}}}");
    try runtime.pump();
    try std.testing.expectEqual(c.Readiness.ready, runtime.readiness);
    try std.testing.expectEqualStrings("", runtime.diagnostic);
    try std.testing.expect(runtime.pending == null);
    try std.testing.expect(!runtime.login_active);
    // A completion from that now-finished flow cannot poison readiness.
    try wire.input.append(a, "{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"current\",\"success\":false,\"error\":\"duplicate\"}}");
    try runtime.pump();
    try std.testing.expectEqual(c.Readiness.ready, runtime.readiness);
}

test "Codex adapter reuses cached ChatGPT and API-key auth without sending login requests" {
    for ([_]struct { account: []const u8, readiness: c.Readiness }{
        .{ .account = "{\"type\":\"chatgpt\"}", .readiness = .ready },
        .{ .account = "{\"type\":\"apiKey\"}", .readiness = .ready },
        .{ .account = "null", .readiness = .unavailable },
        .{ .account = "{\"type\":\"unrecognized\"}", .readiness = .unavailable },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var wire: Mock = .{ .allocator = a };
        var runtime = try codex.RuntimeFor(Mock).init(a, &wire, .{ .selection = selection, .cwd = "/tmp/project", .instance = "existing-auth" });
        defer runtime.deinit();
        try wire.input.append(a, "{\"id\":1,\"result\":{\"userAgent\":\"codex/0.163.0\"}}");
        try runtime.pump();
        try wire.input.append(a, try std.fmt.allocPrint(a, "{{\"id\":2,\"result\":{{\"account\":{s},\"requiresOpenaiAuth\":true}}}}", .{case.account}));
        try runtime.pump();
        try std.testing.expectEqual(case.readiness, runtime.accountStatus().readiness);
        try std.testing.expect(!runtime.login_active);
        try std.testing.expectEqual(@as(usize, 3), wire.lines.items.len);
        try std.testing.expect(std.mem.indexOf(u8, wire.lines.items[2], "account/read") != null);
        for (wire.lines.items) |line| try std.testing.expect(std.mem.indexOf(u8, line, "login/start") == null);
    }
}
