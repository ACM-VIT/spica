const std = @import("std");
const bridge = @import("runtime/opencode_bridge.zig");
const common = @import("runtime/adapter.zig");

fn allocationCase(allocator: std.mem.Allocator) !void {
    const json = try bridge.serialize(allocator, .{ .url = "http://127.0.0.1:4321/mcp/session", .token = "session-secret" });
    defer allocator.free(json);
    try std.testing.expectEqualStrings("[{\"type\":\"http\",\"name\":\"spica\",\"url\":\"http://127.0.0.1:4321/mcp/session\",\"headers\":[{\"name\":\"Authorization\",\"value\":\"Bearer session-secret\"}]}]", json);
}

test "OpenCode bridge exact installed ACP HTTP registration" {
    try allocationCase(std.testing.allocator);
}

test "OpenCode bridge cleans every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "OpenCode bridge output owns escaped URL and bearer token" {
    var url = "http://localhost/mcp/\"session\\value".*;
    var token = "secret\"\\\n\t".*;
    const registration: common.Bridge = .{ .url = &url, .token = &token };
    const json = try bridge.serialize(std.testing.allocator, registration);
    defer std.testing.allocator.free(json);
    @memset(&url, 'x');
    @memset(&token, 'x');
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const servers = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 1), servers.len);
    try std.testing.expectEqualStrings("http://localhost/mcp/\"session\\value", servers[0].object.get("url").?.string);
    const headers = servers[0].object.get("headers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("Authorization", headers[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("Bearer secret\"\\\n\t", headers[0].object.get("value").?.string);
}
