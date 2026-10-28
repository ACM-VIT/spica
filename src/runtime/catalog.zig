//! Explicit metadata refresh. No prompt, turn/start, or sign-in is issued here.
const std = @import("std");
const c = @import("../contract.zig");
const transport = @import("transport.zig");
const common = @import("adapter.zig");
const Value = std.json.Value;
pub const max_models = 128;
pub const max_efforts = 16;
/// Explicitly tested app-server revisions. Parse the protocol version from the
/// first UA product token, whose name is the initializing client's identity.
pub fn codexVersionSupported(version: []const u8) bool {
    return std.mem.eql(u8, version, "0.163.0") or std.mem.eql(u8, version, "0.164.0");
}
pub fn codexRuntimeVersion(user_agent: []const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, user_agent, ' ') orelse user_agent.len;
    const product = user_agent[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, product, '/') orelse return error.RuntimeVersionMismatch;
    const version = product[slash + 1 ..];
    if (std.mem.eql(u8, version, "0.163.0")) return "0.163.0";
    if (std.mem.eql(u8, version, "0.164.0")) return "0.164.0";
    return error.RuntimeVersionMismatch;
}
pub fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn text(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
/// Reusable, owned diagnostic: retain only method/code/message, never error.data.
pub const RpcDiagnostic = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const RpcDiagnostic) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn remember(self: *RpcDiagnostic, method: []const u8, failure: Value) void {
        self.len = 0;
        self.append(method, 96);
        self.append(" rejected", 16);
        const code = field(failure, "code");
        if (code == .integer) {
            var number: [32]u8 = undefined;
            const printed = std.fmt.bufPrint(&number, " ({d})", .{code.integer}) catch "";
            self.append(printed, number.len);
        } else if (code == .string) {
            self.append(" (", 2);
            self.append(code.string, 64);
            self.append(")", 1);
        }
        const message = if (failure == .string) failure.string else text(field(failure, "message"));
        if (message.len != 0) {
            self.append(": ", 2);
            self.append(message, 768);
        }
    }
    fn append(self: *RpcDiagnostic, bytes: []const u8, limit: usize) void {
        var end = @min(bytes.len, @min(limit, self.bytes.len - self.len));
        while (end < bytes.len and end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
        for (bytes[0..end]) |byte| {
            self.bytes[self.len] = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
            self.len += 1;
        }
    }
};
fn call(wire: *transport.Transport, allocator: std.mem.Allocator, diagnostic: *RpcDiagnostic, id: u64, method: []const u8, params: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{});
    try wire.send(bytes);
    const start = transport.c.spica_monotonic_ms();
    while (transport.c.spica_monotonic_ms() - start < 15000) {
        try wire.pump();
        while (try wire.poll(allocator)) |line| {
            const frame = try std.json.parseFromSlice(Value, allocator, line, .{ .allocate = .alloc_always });
            const actual = field(frame.value, "id");
            if (actual != .integer or actual.integer != id) continue;
            if (field(frame.value, "error") != .null) {
                diagnostic.remember(method, field(frame.value, "error"));
                return error.CatalogRpcRejected;
            }
            return field(frame.value, "result");
        }
        if (wire.exited) return error.ProviderDisconnected;
        _ = transport.c.spica_process_poll(&wire.process, -1, @intFromBool(wire.input_len != 0), 20);
    }
    return error.CatalogTimeout;
}
/// account/read describes cached authentication, never model entitlement.
/// Both supported OpenAI account variants can already be authorized; discovering
/// an API-key account must not initiate an unrelated ChatGPT sign-in.
pub fn codexAccountReadiness(result: Value) c.Readiness {
    const kind = text(field(field(result, "account"), "type"));
    return if (eq(kind, "chatgpt") or eq(kind, "apiKey")) .ready else .unavailable;
}
pub fn codexAccountReason(result: Value) []const u8 {
    const kind = text(field(field(result, "account"), "type"));
    if (eq(kind, "chatgpt")) return "ChatGPT account signed in; model access is verified when a request completes.";
    if (eq(kind, "apiKey")) return "API-key account configured; this uses API billing, not a ChatGPT subscription. Sign in to use ChatGPT instead.";
    return "Codex account needs authentication. Choose the existing ChatGPT account folder or sign in.";
}

pub fn codex(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, output: []c.Model) !usize {
    var diagnostic: RpcDiagnostic = .{};
    return codexWithDiagnostic(allocator, retained, wire, selection, output, &diagnostic);
}
pub fn codexWithDiagnostic(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, output: []c.Model, diagnostic: *RpcDiagnostic) !usize {
    const init = try call(wire, allocator, diagnostic, 1, "initialize", .{ .clientInfo = .{ .name = "spica", .version = "1" }, .capabilities = .{ .experimentalApi = true } });
    _ = try codexRuntimeVersion(text(field(init, "userAgent")));
    try wire.send("{\"method\":\"initialized\",\"params\":{}}");
    const account = try call(wire, allocator, diagnostic, 2, "account/read", .{ .refreshToken = false });
    const readiness = codexAccountReadiness(account);
    var cursor: ?[]const u8 = null;
    var count: usize = 0;
    var id: u64 = 3;
    while (id < 131) : (id += 1) {
        const result = try call(wire, allocator, diagnostic, id, "model/list", .{ .cursor = cursor, .limit = @as(u32, 32), .includeHidden = false });
        const data = field(result, "data");
        if (data != .array) return error.InvalidCatalog;
        for (data.array.items) |model| {
            if (count == output.len) return error.CatalogLimit;
            // Keep the tested compatibility requirement stable across CLI
            // updates. Sessions compare selection identities exactly; replacing
            // this with the observed build would strand an existing chat.
            // The adapter records its actual build on every observation.
            output[count] = try codexModel(retained, selection, model, readiness);
            output[count].reason = codexAccountReason(account);
            count += 1;
        }
        const next = text(field(result, "nextCursor"));
        if (next.len == 0) return count;
        if (cursor) |old| if (eq(old, next)) return error.InvalidCatalog;
        cursor = next;
    }
    return error.CatalogLimit;
}
pub fn codexModel(allocator: std.mem.Allocator, input: c.Selection, model: Value, readiness: c.Readiness) !c.Model {
    const id = text(field(model, "model"));
    const options = field(model, "supportedReasoningEfforts");
    if (id.len == 0 or id.len > 256 or options != .array or options.array.items.len == 0 or options.array.items.len > max_efforts) return error.InvalidCatalog;
    const efforts = try allocator.alloc([]const u8, options.array.items.len);
    for (options.array.items, efforts) |option, *effort| {
        const value = text(field(option, "reasoningEffort"));
        if (value.len == 0 or value.len > 64) return error.InvalidCatalog;
        effort.* = try allocator.dupe(u8, value);
    }
    var selection = input;
    selection.model_id = id;
    selection.effort = text(field(model, "defaultReasoningEffort"));
    var valid_default = false;
    for (efforts) |effort| {
        if (eq(effort, selection.effort)) valid_default = true;
    }
    if (!valid_default) return error.InvalidCatalog;
    return .{ .selection = try common.clone(allocator, selection), .supported_efforts = efforts, .display_name = try allocator.dupe(u8, text(field(model, "displayName"))), .readiness = readiness, .reason = if (readiness == .ready) "Codex model/list; account ready, entitlement not proven" else "Codex model/list succeeded; selected account needs authentication" };
}
pub fn opencode(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, cwd: []const u8, output: []c.Model) !usize {
    var diagnostic: RpcDiagnostic = .{};
    return opencodeWithDiagnostic(allocator, retained, wire, selection, cwd, output, &diagnostic);
}
pub fn opencodeWithDiagnostic(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, cwd: []const u8, output: []c.Model, diagnostic: *RpcDiagnostic) !usize {
    var resume_supported = false;
    return opencodeWithCapabilities(allocator, retained, wire, selection, cwd, output, diagnostic, &resume_supported);
}
pub fn opencodeResumeSupported(init: Value) bool {
    return field(field(field(init, "agentCapabilities"), "sessionCapabilities"), "resume") == .object;
}
pub fn opencodeWithCapabilities(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, cwd: []const u8, output: []c.Model, diagnostic: *RpcDiagnostic, resume_supported: *bool) !usize {
    resume_supported.* = false;
    const init = try call(wire, allocator, diagnostic, 1, "initialize", .{ .protocolVersion = 1, .clientCapabilities = Value{ .object = .empty }, .clientInfo = .{ .name = "spica", .version = "1" } });
    if (field(init, "protocolVersion") != .integer or field(init, "protocolVersion").integer != 1 or !eq(text(field(field(init, "agentInfo"), "version")), "2.1.4")) return error.RuntimeVersionMismatch;
    const session = try call(wire, allocator, diagnostic, 2, "session/new", .{ .cwd = cwd, .mcpServers = @as([0]Value, .{}) });
    const count = try opencodeModels(retained, selection, session, output);
    const session_id = text(field(session, "sessionId"));
    if (session_id.len == 0) return error.InvalidCatalog;
    // Efforts are per model. Ask the negotiated session, never project the
    // current model's option list onto every other catalog item.
    for (output[0..count], 0..) |*model, index| {
        const identity = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.selection.model_provider, model.selection.model_id });
        const configured = call(wire, allocator, diagnostic, index + 3, "session/set_config_option", .{ .sessionId = session_id, .configId = "model", .value = identity }) catch |err| {
            if (err != error.CatalogRpcRejected) return err;
            model.readiness = .unavailable;
            model.reason = try retained.dupe(u8, diagnostic.slice());
            diagnostic.len = 0;
            continue;
        };
        try applyOpenCodeOptions(retained, model, identity, configured);
    }
    resume_supported.* = opencodeResumeSupported(init);
    return count;
}

/// One advertised entry may fail exact negotiation. Its returned effort list
/// belongs to a different model and must never contaminate this or other rows.
pub fn applyOpenCodeOptions(retained: std.mem.Allocator, model: *c.Model, identity: []const u8, configured: Value) !void {
    const options = field(configured, "configOptions");
    if (options != .array) return error.InvalidCatalog;
    var actual_model = false;
    for (options.array.items) |option| {
        if (eq(text(field(option, "id")), "model")) actual_model = eq(text(field(option, "currentValue")), identity);
    }
    if (!actual_model) {
        model.readiness = .unavailable;
        model.reason = "OpenCode returned a different model during discovery. Refresh to verify this entry; other verified models remain usable.";
        return;
    }
    for (options.array.items) |option| {
        if (!eq(text(field(option, "id")), "effort")) continue;
        const values = field(option, "options");
        if (values != .array or values.array.items.len > max_efforts) return error.InvalidCatalog;
        var unique: [max_efforts][]const u8 = undefined;
        unique[0] = "default";
        var count: usize = 1;
        for (values.array.items) |value| {
            const name = text(field(value, "value"));
            if (name.len == 0 or name.len > 64) return error.InvalidCatalog;
            var found = false;
            for (unique[0..count]) |old| if (eq(old, name)) {
                found = true;
                break;
            };
            if (found) continue;
            if (count == unique.len) return error.InvalidCatalog;
            unique[count] = name;
            count += 1;
        }
        const efforts = try retained.alloc([]const u8, count);
        for (unique[0..count], efforts) |name, *effort| effort.* = try retained.dupe(u8, name);
        model.supported_efforts = efforts;
    }
}
pub fn opencodeModels(allocator: std.mem.Allocator, input: c.Selection, session: Value, output: []c.Model) !usize {
    const options = field(session, "configOptions");
    if (options != .array) return error.InvalidCatalog;
    var count: usize = 0;
    for (options.array.items) |option| {
        if (!eq(text(field(option, "id")), "model")) continue;
        const groups = field(option, "options");
        if (groups != .array) return error.InvalidCatalog;
        for (groups.array.items) |group| {
            const nested = field(group, "options");
            if (nested == .array) {
                for (nested.array.items) |model| {
                    try appendOpenCode(allocator, input, model, output, &count);
                }
            } else try appendOpenCode(allocator, input, group, output, &count);
        }
    }
    if (count == 0) return error.InvalidCatalog;
    return count;
}
fn appendOpenCode(allocator: std.mem.Allocator, input: c.Selection, model: Value, output: []c.Model, count: *usize) !void {
    const value = text(field(model, "value"));
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidCatalog;
    if (slash == 0 or slash + 1 == value.len or value.len > 512) return error.InvalidCatalog;
    // An explicit provider prefix is strict. `auto` is an explicit discovery
    // mode for installations such as opencode-free where the negotiated
    // provider namespace is not known before session/new.
    if (!eq(input.model_provider, "auto") and !eq(value[0..slash], input.model_provider)) return;
    if (count.* == output.len) return error.CatalogLimit;
    var selection = input;
    if (eq(input.model_provider, "auto")) selection.model_provider = value[0..slash];
    selection.model_id = value[slash + 1 ..];
    selection.effort = "default";
    output[count.*] = .{ .selection = try common.clone(allocator, selection), .supported_efforts = &.{"default"}, .display_name = try allocator.dupe(u8, text(field(model, "name"))), .readiness = .unknown, .reason = "OpenCode negotiated catalog; account entitlement unverified; per-model variants require exact session negotiation" };
    count.* += 1;
}

test "Codex supported revisions use the first UA token and reject untested versions" {
    try std.testing.expectEqualStrings("0.163.0", try codexRuntimeVersion("codex/0.163.0"));
    try std.testing.expectEqualStrings("0.164.0", try codexRuntimeVersion("spica/0.164.0 (Linux; x86_64) unknown (spica; 1)"));
    for ([_][]const u8{ "codex/0.163.01", "codex/0.164.0-beta.1", "spica/0.165.0 (client/0.163.0)", "0.164.0", "" }) |ua| try std.testing.expectError(error.RuntimeVersionMismatch, codexRuntimeVersion(ua));
}

test "Codex account reasons distinguish subscription login from API billing without retaining identity" {
    const a = std.testing.allocator;
    for ([_]struct { json: []const u8, reason: []const u8, readiness: c.Readiness }{
        .{ .json = "{\"account\":{\"type\":\"chatgpt\",\"email\":\"private@example.invalid\"}}", .reason = "ChatGPT account signed in", .readiness = .ready },
        .{ .json = "{\"account\":{\"type\":\"apiKey\"}}", .reason = "API-key account configured", .readiness = .ready },
        .{ .json = "{\"account\":null}", .reason = "Codex account needs authentication", .readiness = .unavailable },
    }) |fixture| {
        const parsed = try std.json.parseFromSlice(Value, a, fixture.json, .{});
        defer parsed.deinit();
        const reason = codexAccountReason(parsed.value);
        try std.testing.expect(std.mem.startsWith(u8, reason, fixture.reason));
        try std.testing.expect(std.mem.indexOf(u8, reason, "private@example.invalid") == null);
        try std.testing.expectEqual(fixture.readiness, codexAccountReadiness(parsed.value));
    }
}

test "Codex catalog preserves protocol efforts and unauthed evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const model = try std.json.parseFromSlice(Value, allocator, "{\"model\":\"actual-model\",\"displayName\":\"Actual\",\"defaultReasoningEffort\":\"low\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"},{\"reasoningEffort\":\"high\"}]}", .{});
    const result = try codexModel(allocator, .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "", .effort = "", .account_ref = "/isolated", .workspace = .{ .value = "workspace" } }, model.value, .unavailable);
    try std.testing.expectEqualStrings("actual-model", result.selection.model_id);
    try std.testing.expectEqualStrings("low", result.selection.effort);
    try std.testing.expectEqual(@as(usize, 2), result.supported_efforts.len);
    try std.testing.expectEqual(c.Readiness.unavailable, result.readiness);
}

test "OpenCode grouped catalog filters unauthorized provider and bounds rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(Value, allocator, "{\"configOptions\":[{\"id\":\"model\",\"options\":[{\"name\":\"Group\",\"options\":[{\"value\":\"authorized/one\",\"name\":\"One\"},{\"value\":\"other/two\",\"name\":\"Two\"}]}]}]}", .{});
    const input: c.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "authorized", .model_id = "", .effort = "", .account_ref = "/isolated", .workspace = .{ .value = "w" } };
    var output: [2]c.Model = undefined;
    try std.testing.expectEqual(@as(usize, 1), try opencodeModels(allocator, input, parsed.value, &output));
    try std.testing.expectEqualStrings("one", output[0].selection.model_id);
    try std.testing.expectEqual(c.Readiness.unknown, output[0].readiness);
    try std.testing.expectError(error.CatalogLimit, opencodeModels(allocator, input, parsed.value, output[0..0]));
}

test "OpenCode auto catalog preserves the negotiated provider prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(Value, allocator, "{\"configOptions\":[{\"id\":\"model\",\"options\":[{\"value\":\"opencode-free/glm-5.3-flash\",\"name\":\"GLM 5.3 Flash\"},{\"value\":\"openai-codex/gpt-5\",\"name\":\"Codex\"}]}]}", .{});
    const input: c.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "auto", .model_id = "", .effort = "", .account_ref = "/isolated/opencode", .workspace = .{ .value = "w" } };
    var output: [2]c.Model = undefined;
    try std.testing.expectEqual(@as(usize, 2), try opencodeModels(allocator, input, parsed.value, &output));
    try std.testing.expectEqualStrings("opencode-free", output[0].selection.model_provider);
    try std.testing.expectEqualStrings("glm-5.3-flash", output[0].selection.model_id);
    try std.testing.expectEqualStrings("openai-codex", output[1].selection.model_provider);
}

test "one mismatched OpenCode catalog row cannot poison exact selections or efforts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const initial: c.Model = .{ .selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "fixture", .model_id = "requested", .effort = "default", .account_ref = "/isolated", .workspace = .{ .value = "workspace" } }, .supported_efforts = &.{"default"}, .display_name = "Requested", .readiness = .unknown, .reason = "Fixture negotiated catalog" };
    var rejected = initial;
    const mismatch = try std.json.parseFromSlice(Value, allocator, "{\"configOptions\":[{\"id\":\"model\",\"currentValue\":\"fixture/other\"},{\"id\":\"effort\",\"options\":[{\"value\":\"wrong-model-effort\"}]}]}", .{});
    try applyOpenCodeOptions(allocator, &rejected, "fixture/requested", mismatch.value);
    try std.testing.expectEqual(c.Readiness.unavailable, rejected.readiness);
    try std.testing.expectEqualStrings("requested", rejected.selection.model_id);
    try std.testing.expectEqualStrings("default", rejected.supported_efforts[0]);
    try std.testing.expectEqual(@as(usize, 1), rejected.supported_efforts.len);
    var verified = initial;
    const exact = try std.json.parseFromSlice(Value, allocator, "{\"configOptions\":[{\"id\":\"effort\",\"options\":[{\"value\":\"high\"},{\"value\":\"default\"},{\"value\":\"high\"}]},{\"id\":\"model\",\"currentValue\":\"fixture/requested\"}]}", .{});
    try applyOpenCodeOptions(allocator, &verified, "fixture/requested", exact.value);
    try std.testing.expectEqual(c.Readiness.unknown, verified.readiness);
    try std.testing.expectEqual(@as(usize, 2), verified.supported_efforts.len);
    try std.testing.expectEqualStrings("default", verified.supported_efforts[0]);
    try std.testing.expectEqualStrings("high", verified.supported_efforts[1]);
    try std.testing.expectEqual(c.Readiness.unavailable, rejected.readiness);
}

test "RPC diagnostic bounds UTF8 sanitizes controls and excludes structured private fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .code = -32001, .message = "denied 界\n" ** 400, .data = .{ .access_token = "PRIVATE-TOKEN", .history = "PRIVATE-HISTORY" } }, .{});
    const parsed = try std.json.parseFromSlice(Value, a, encoded, .{ .allocate = .alloc_always });
    var diagnostic: RpcDiagnostic = .{};
    diagnostic.remember("model/list", parsed.value);
    try std.testing.expect(diagnostic.len <= diagnostic.bytes.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(diagnostic.slice()));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "model/list rejected (-32001): denied 界") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.slice(), "PRIVATE") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, diagnostic.slice(), '\n') == null);
    const saved = try a.dupe(u8, diagnostic.slice());
    // Mutating the source JSON does not change retained diagnostic bytes.
    @memset(@constCast(parsed.value.object.get("message").?.string), 'x');
    try std.testing.expectEqualStrings(saved, diagnostic.slice());
}

test "Codex catalog auth accepts existing supported accounts and rejects absent malformed unknown accounts" {
    for ([_]struct { json: []const u8, ready: bool }{
        .{ .json = "{\"account\":{\"type\":\"chatgpt\"},\"requiresOpenaiAuth\":true}", .ready = true },
        .{ .json = "{\"account\":{\"type\":\"apiKey\"},\"requiresOpenaiAuth\":true}", .ready = true },
        .{ .json = "{\"account\":null,\"requiresOpenaiAuth\":true}", .ready = false },
        .{ .json = "{\"account\":{\"type\":\"unsupported\"}}", .ready = false },
        .{ .json = "{\"account\":{\"type\":true}}", .ready = false },
    }) |case| {
        const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(if (case.ready) c.Readiness.ready else .unavailable, codexAccountReadiness(parsed.value));
    }
}

test "OpenCode resume requires the negotiated ACP capability object" {
    for ([_]struct { json: []const u8, supported: bool }{
        .{ .json = "{\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":{}}}}", .supported = true },
        .{ .json = "{}", .supported = false },
        .{ .json = "{\"agentCapabilities\":{\"sessionCapabilities\":{}}}", .supported = false },
        .{ .json = "{\"agentCapabilities\":{\"sessionCapabilities\":{\"resume\":true}}}", .supported = false },
        .{ .json = "{\"agentCapabilities\":{\"sessionCapabilities\":{\"load\":{}}}}", .supported = false },
    }) |case| {
        const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.supported, opencodeResumeSupported(parsed.value));
    }
}
