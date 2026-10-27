//! Dedicated Start serialization limits; ordinary frames/queues stay unchanged.
const std = @import("std");
const c = @import("../contract.zig");
pub const max_bytes = 64 * 1024;
// JSON can expand a raw control byte to six ASCII bytes. Metadata gets its own
// fixed allowance; a provider session with larger metadata refuses actionably.
pub const json_bytes = 6 * max_bytes + 16 * 1024;
pub fn validate(start: @FieldType(c.Request, "start")) !void {
    if (start.prompt_ref != null or start.prompt.len == 0 or start.prompt.len > max_bytes or !std.unicode.utf8ValidateSlice(start.prompt)) return error.InvalidPrompt;
}
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const buffer = try allocator.alloc(u8, json_bytes);
    errdefer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(value, .{}, &writer) catch return error.FrameTooLarge;
    // Return the allocation as well as length via a sentinel-free owned slice.
    return allocator.realloc(buffer, writer.buffered().len);
}

fn encodeFailure(allocator: std.mem.Allocator) !void {
    const bytes = try encode(allocator, .{ .text = "\x01" ** max_bytes });
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len <= json_bytes);
    try std.testing.expect(bytes.len > 6 * max_bytes);
}
test "bounded Start JSON encoding cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeFailure, .{});
}
