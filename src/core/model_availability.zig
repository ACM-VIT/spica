const std = @import("std");
const Model = @import("runtime.zig").Model;

pub const Availability = enum { available, unavailable, unknown };

/// The helper only emits a provider after a complete, successful lookup.
/// Missing providers and malformed results are unknown and retain Pi's list.
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
        // Validate the full list before treating absence as evidence.
        for (ids.array.items) |item| if (item != .string) return .unknown;
        for (ids.array.items) |item| if (std.mem.eql(u8, item.string, id)) return .available;
        return .unavailable;
    }
    return .unknown;
}

pub fn keep(policy: std.json.Value, model: Model) bool {
    return status(policy, model.provider, model.id) != .unavailable;
}

test "provider-neutral availability preserves unknown models and the registry" {
    const source = [_]Model{
        .{ .provider = "openai-codex", .id = "a", .name = "A" },
        .{ .provider = "openai-codex", .id = "b", .name = "B" },
        .{ .provider = "google", .id = "a", .name = "A" },
        .{ .provider = "other", .id = "x", .name = "X" },
    };
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"providers":[{"provider":"openai-codex","availableIds":["a"]},{"provider":"google","availableIds":[]}]}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(keep(parsed.value, source[0]));
    try std.testing.expect(!keep(parsed.value, source[1]));
    try std.testing.expect(!keep(parsed.value, source[2]));
    try std.testing.expect(keep(parsed.value, source[3]));
    try std.testing.expectEqualStrings("b", source[1].id);
    var failed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"providers":[{"provider":"openai-codex","availableIds":[42]}]}
    , .{});
    defer failed.deinit();
    try std.testing.expect(keep(failed.value, source[1]));
}
