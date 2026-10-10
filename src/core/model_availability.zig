const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
});
const Model = @import("runtime.zig").Model;

pub const Availability = enum { available, unavailable, unknown };

/// A provider is restrictive only after a complete catalog was received. This
/// keeps transient network/auth failures from hiding models that Pi can use.
pub fn status(policy: std.json.Value, provider: []const u8, id: []const u8) Availability {
    if (policy != .object) return .unknown;
    const providers = policy.object.get("providers") orelse return .unknown;
    if (providers != .array) return .unknown;
    for (providers.array.items) |entry| {
        if (entry != .object) continue;
        const name = entry.object.get("provider") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, provider)) continue;
        const ids = entry.object.get("availableIds") orelse return .unknown;
        if (ids != .array) return .unknown;
        for (ids.array.items) |item| if (item != .string) return .unknown;
        for (ids.array.items) |item| if (std.mem.eql(u8, item.string, id)) return .available;
        return .unavailable;
    }
    return .unknown;
}

pub fn keep(policy: std.json.Value, model: Model) bool {
    return status(policy, model.provider, model.id) != .unavailable;
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn boolField(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .bool) field.bool else null;
}

fn numberField(value: std.json.Value, key: []const u8) ?f64 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn environment(name: []const u8) ?[]const u8 {
    var name_z: [128:0]u8 = undefined;
    if (name.len >= name_z.len) return null;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    const value = c.getenv(&name_z);
    return if (value) |bytes| std.mem.span(bytes) else null;
}

fn agentDirectory(allocator: std.mem.Allocator) !?[]u8 {
    if (environment("PI_CODING_AGENT_DIR")) |path| {
        if (path.len != 0) {
            const owned = try allocator.dupe(u8, path);
            return owned;
        }
    }
    const home = environment("HOME") orelse return null;
    return try std.fs.path.join(allocator, &.{ home, ".pi", "agent" });
}

fn readJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
    defer allocator.free(bytes);
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
}

fn isProviderOverridden(allocator: std.mem.Allocator, io: std.Io, agent: []const u8, provider: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ agent, "models.json" }) catch return true;
    defer allocator.free(path);
    var parsed = readJson(allocator, io, path, 256 * 1024) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    const providers = parsed.value.object.get("providers") orelse return false;
    if (providers != .object) return true;
    return providers.object.contains(provider);
}

const Credential = struct {
    value: std.json.Value,
    present: bool,
};

fn credential(parsed: *std.json.Parsed(std.json.Value), provider: []const u8) Credential {
    if (parsed.value != .object) return .{ .value = .null, .present = false };
    const value = parsed.value.object.get(provider) orelse return .{ .value = .null, .present = true };
    return .{ .value = value, .present = true };
}

fn credentialIsValidOAuth(value: std.json.Value, now_ms: i64) bool {
    if (value != .object or !std.mem.eql(u8, stringField(value, "type") orelse "", "oauth")) return false;
    const access = stringField(value, "access") orelse return false;
    _ = access;
    const expires = numberField(value, "expires") orelse return false;
    return std.math.isFinite(expires) and expires > @as(f64, @floatFromInt(now_ms));
}

fn listedSlugs(allocator: std.mem.Allocator, result: std.json.Value) !?[][]const u8 {
    if (result != .object) return null;
    const models = result.object.get("models") orelse return null;
    if (models != .array) return null;
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    for (models.array.items) |model| {
        const slug = stringField(model, "slug") orelse return null;
        const visibility = stringField(model, "visibility") orelse return null;
        if (!std.mem.eql(u8, visibility, "list") and !std.mem.eql(u8, visibility, "hide")) return null;
        if (model == .object) if (model.object.get("supported_in_api")) |supported| {
            if (supported != .bool) return null;
        };
        if (!std.mem.eql(u8, visibility, "list")) continue;
        if (boolField(model, "supported_in_api")) |supported| if (!supported) continue;
        try ids.append(allocator, try allocator.dupe(u8, slug));
    }
    return try ids.toOwnedSlice(allocator);
}

const ProviderResult = struct {
    provider: []const u8,
    availableIds: []const []const u8,
};

fn policyBytes(allocator: std.mem.Allocator, provider: []const u8, ids: []const []const u8) ![]u8 {
    const providers = [_]ProviderResult{.{ .provider = provider, .availableIds = ids }};
    return std.json.Stringify.valueAlloc(allocator, .{ .providers = providers[0..] }, .{});
}

fn fetchJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    authorization: []const u8,
    account_id: ?[]const u8,
) !std.json.Parsed(std.json.Value) {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var extra: [2]std.http.Header = undefined;
    var extra_len: usize = 0;
    if (account_id) |id| {
        extra[extra_len] = .{ .name = "ChatGPT-Account-ID", .value = id };
        extra_len += 1;
        extra[extra_len] = .{ .name = "originator", .value = "pi" };
        extra_len += 1;
    }
    const body = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(body);
    var writer = std.Io.Writer.fixed(body);
    const response = try client.fetch(.{
        .location = .{ .url = url },
        .redirect_behavior = .not_allowed,
        .headers = .{ .authorization = .{ .override = authorization }, .accept_encoding = .{ .override = "identity" } },
        .extra_headers = extra[0..extra_len],
        .response_writer = &writer,
    });
    if (response.status != .ok) return error.AvailabilityRequestFailed;
    return std.json.parseFromSlice(std.json.Value, allocator, body[0..writer.end], .{ .allocate = .alloc_always, .max_value_len = 2 * 1024 * 1024 });
}

fn nowMilliseconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Resolves the ChatGPT account catalog used by Pi's openai-codex provider.
/// This is deliberately a catalog request, never an inference request.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const agent = try agentDirectory(allocator) orelse return allocator.dupe(u8, "{\"providers\":[]}");
    defer allocator.free(agent);
    if (isProviderOverridden(allocator, io, agent, "openai-codex")) return allocator.dupe(u8, "{\"providers\":[]}");
    const auth_path = try std.fs.path.join(allocator, &.{ agent, "auth.json" });
    defer allocator.free(auth_path);
    var auth = readJson(allocator, io, auth_path, 512 * 1024) catch return allocator.dupe(u8, "{\"providers\":[]}");
    defer auth.deinit();
    const found = credential(&auth, "openai-codex");
    if (!found.present) return allocator.dupe(u8, "{\"providers\":[]}");
    // A readable auth store with no saved Codex credential is a confirmed
    // logout. An unreadable store above remains unknown and shows the list.
    if (found.value == .null) return policyBytes(allocator, "openai-codex", &.{});
    if (!credentialIsValidOAuth(found.value, nowMilliseconds(io))) return allocator.dupe(u8, "{\"providers\":[]}");
    const access = stringField(found.value, "access").?;
    const account = stringField(found.value, "accountId");
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0", .{});
    var authorization_buffer: [4096]u8 = undefined;
    const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{access});
    var result = fetchJson(allocator, io, url, authorization, account) catch return allocator.dupe(u8, "{\"providers\":[]}");
    defer result.deinit();
    const ids = listedSlugs(allocator, result.value) catch return allocator.dupe(u8, "{\"providers\":[]}");
    const owned_ids = ids orelse return allocator.dupe(u8, "{\"providers\":[]}");
    defer {
        for (owned_ids) |id| allocator.free(id);
        allocator.free(owned_ids);
    }
    return policyBytes(allocator, "openai-codex", owned_ids);
}

test "availability keeps unknown providers and removes models absent from a complete catalog" {
    const source = [_]Model{
        .{ .provider = "openai-codex", .id = "included", .name = "Included" },
        .{ .provider = "openai-codex", .id = "subscription-only", .name = "Subscription only" },
        .{ .provider = "anthropic", .id = "claude", .name = "Claude" },
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"providers":[{"provider":"openai-codex","availableIds":["included"]}]}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(keep(parsed.value, source[0]));
    try std.testing.expect(!keep(parsed.value, source[1]));
    try std.testing.expect(keep(parsed.value, source[2]));
}

test "malformed catalogs are unknown instead of empty entitlements" {
    const model: Model = .{ .provider = "openai-codex", .id = "model", .name = "Model" };
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"providers":[{"provider":"openai-codex","availableIds":[42]}]}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(keep(parsed.value, model));
}
