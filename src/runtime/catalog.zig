//! Explicit metadata refresh. No prompt, turn/start, or sign-in is issued here.
const std = @import("std");
const c = @import("../contract.zig");
const transport = @import("transport.zig");
const common = @import("adapter.zig");
const Value = std.json.Value;
pub const max_models = 128;
pub const max_efforts = 16;
pub fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn text(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn call(wire: *transport.Transport, allocator: std.mem.Allocator, id: u64, method: []const u8, params: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, .{});
    try wire.send(bytes);
    const start = transport.c.spica_monotonic_ms();
    while (transport.c.spica_monotonic_ms() - start < 15000) {
        try wire.pump();
        while (try wire.poll(allocator)) |line| {
            const frame = try std.json.parseFromSlice(Value, allocator, line, .{ .allocate = .alloc_always });
            const actual = field(frame.value, "id");
            if (actual != .integer or actual.integer != id) continue;
            if (field(frame.value, "error") != .null) return error.CatalogRpcRejected;
            return field(frame.value, "result");
        }
        if (wire.exited) return error.ProviderDisconnected;
        _ = transport.c.spica_process_poll(&wire.process, -1, @intFromBool(wire.input_len != 0), 20);
    }
    return error.CatalogTimeout;
}
pub fn codex(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, output: []c.Model) !usize {
    const init = try call(wire, allocator, 1, "initialize", .{ .clientInfo = .{ .name = "spica", .version = "1" }, .capabilities = .{ .experimentalApi = true } });
    if (std.mem.indexOf(u8, text(field(init, "userAgent")), "0.163.0") == null) return error.RuntimeVersionMismatch;
    try wire.send("{\"method\":\"initialized\",\"params\":{}}");
    const account = try call(wire, allocator, 2, "account/read", .{ .refreshToken = false });
    const readiness: c.Readiness = if (eq(text(field(field(account, "account"), "type")), "chatgpt")) .ready else .unavailable;
    var cursor: ?[]const u8 = null;
    var count: usize = 0;
    var id: u64 = 3;
    while (id < 131) : (id += 1) {
        const result = try call(wire, allocator, id, "model/list", .{ .cursor = cursor, .limit = @as(u32, 32), .includeHidden = false });
        const data = field(result, "data");
        if (data != .array) return error.InvalidCatalog;
        for (data.array.items) |model| {
            if (count == output.len) return error.CatalogLimit;
            output[count] = try codexModel(retained, selection, model, readiness);
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
    return .{ .selection = try common.clone(allocator, selection), .supported_efforts = efforts, .display_name = try allocator.dupe(u8, text(field(model, "displayName"))), .readiness = readiness, .reason = if (readiness == .ready) "Codex model/list; account ready, entitlement not proven" else "Codex model/list succeeded; selected isolated account requires ChatGPT sign-in" };
}
pub fn opencode(allocator: std.mem.Allocator, retained: std.mem.Allocator, wire: *transport.Transport, selection: c.Selection, cwd: []const u8, output: []c.Model) !usize {
    const init = try call(wire, allocator, 1, "initialize", .{ .protocolVersion = 1, .clientCapabilities = Value{ .object = .empty }, .clientInfo = .{ .name = "spica", .version = "1" } });
    if (field(init, "protocolVersion") != .integer or field(init, "protocolVersion").integer != 1 or !eq(text(field(field(init, "agentInfo"), "version")), "2.1.4")) return error.RuntimeVersionMismatch;
    const session = try call(wire, allocator, 2, "session/new", .{ .cwd = cwd, .mcpServers = @as([0]Value, .{}) });
    const count = try opencodeModels(retained, selection, session, output);
    const session_id = text(field(session, "sessionId"));
    if (session_id.len == 0) return error.InvalidCatalog;
    // Efforts are per model. Ask the negotiated session, never project the
    // current model's option list onto every other catalog item.
    for (output[0..count], 0..) |*model, index| {
        const identity = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.selection.model_provider, model.selection.model_id });
        const configured = try call(wire, allocator, index + 3, "session/set_config_option", .{ .sessionId = session_id, .configId = "model", .value = identity });
        try applyOpenCodeOptions(retained, model, identity, configured);
    }
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
    // Authorization is provider-specific; a negotiated other-provider item is not authorized.
    if (!eq(value[0..slash], input.model_provider)) return;
    if (count.* == output.len) return error.CatalogLimit;
    var selection = input;
    selection.model_id = value[slash + 1 ..];
    selection.effort = "default";
    output[count.*] = .{ .selection = try common.clone(allocator, selection), .supported_efforts = &.{"default"}, .display_name = try allocator.dupe(u8, text(field(model, "name"))), .readiness = .unknown, .reason = "OpenCode negotiated catalog; account entitlement unverified; per-model variants require exact session negotiation" };
    count.* += 1;
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
