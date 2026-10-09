const std = @import("std");
const utf8 = @import("utf8.zig");

pub fn Bounded(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn set(self: *Self, text: []const u8) void {
            const kept = utf8.prefix(text, capacity);
            @memcpy(self.bytes[0..kept.len], kept);
            self.len = kept.len;
        }

        pub fn print(self: *Self, comptime format: []const u8, args: anytype, fallback: []const u8) void {
            const written = std.fmt.bufPrint(&self.bytes, format, args) catch return self.set(fallback);
            self.len = written.len;
        }
    };
}

test "bounded text keeps whole scalars and falls back when formatting overflows" {
    var text: Bounded(5) = .{};
    try std.testing.expect(text.isEmpty());
    text.set("café!");
    try std.testing.expectEqualStrings("café", text.slice());
    text.print("{s}-{d}", .{ "ab", 7 }, "x");
    try std.testing.expectEqualStrings("ab-7", text.slice());
    text.print("{s}", .{"too long"}, "small");
    try std.testing.expectEqualStrings("small", text.slice());
    text.clear();
    try std.testing.expectEqualStrings("", text.slice());
}
