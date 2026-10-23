//! ACP HTTP MCP registration for the session-scoped, Host-owned endpoint.
const std = @import("std");
const common = @import("adapter.zig");

/// Returns allocator-owned JSON for Config.mcp_servers. No endpoint is created
/// here. The factory retains these bytes until after Runtime.shutdown, then frees
/// them. URL/token are borrowed only during this call and are never logged.
pub fn serialize(allocator: std.mem.Allocator, bridge: common.Bridge) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    // Allocating.Writer's only write failure is allocation failure.
    writeRegistration(&output.writer, bridge) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn writeRegistration(writer: *std.Io.Writer, bridge: common.Bridge) std.Io.Writer.Error!void {
    try writer.writeAll("[{\"type\":\"http\",\"name\":\"spica\",\"url\":");
    try std.json.Stringify.encodeJsonString(bridge.url, .{}, writer);
    try writer.writeAll(",\"headers\":[{\"name\":\"Authorization\",\"value\":\"Bearer ");
    try std.json.Stringify.encodeJsonStringChars(bridge.token, .{}, writer);
    try writer.writeAll("\"}]}]");
}
