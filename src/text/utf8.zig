const std = @import("std");

pub fn prefix(bytes: []const u8, limit: usize) []const u8 {
    var end = @min(bytes.len, limit);
    while (end > 0 and end < bytes.len and (bytes[end] & 0xc0) == 0x80) end -= 1;
    return bytes[0..end];
}

test "prefix never splits a scalar" {
    try std.testing.expectEqualStrings("abc", prefix("abc", 8));
    try std.testing.expectEqualStrings("ab", prefix("abc", 2));
    try std.testing.expectEqualStrings("caf", prefix("café", 4));
    try std.testing.expectEqualStrings("café", prefix("café", 5));
    try std.testing.expectEqualStrings("", prefix("é", 1));
    try std.testing.expectEqualStrings("", prefix("abc", 0));
}
