const std = @import("std");

pub const Menu = struct {
    open: bool = false,
    highlight: usize = 0,

    pub fn highlightCurrent(self: *Menu, levels: []const []const u8, current: []const u8) void {
        self.highlight = 0;
        for (levels, 0..) |level, index| {
            if (std.mem.eql(u8, level, current)) {
                self.highlight = index;
                return;
            }
        }
    }

    pub fn selected(self: *Menu, levels: []const []const u8) ?usize {
        if (levels.len == 0) return null;
        self.highlight = @min(self.highlight, levels.len - 1);
        return self.highlight;
    }

    pub fn move(self: *Menu, levels: []const []const u8, down: bool) void {
        const index = self.selected(levels) orelse return;
        self.highlight = if (down) index + 1 else index -| 1;
        _ = self.selected(levels);
    }
};

test "thinking highlight follows the current level and clamps to the list" {
    var menu: Menu = .{};
    var levels = [_][]const u8{ "off", "low", "medium", "high" };
    menu.highlightCurrent(&levels, "medium");
    try std.testing.expectEqual(@as(?usize, 2), menu.selected(&levels));
    menu.move(&levels, true);
    menu.move(&levels, true);
    try std.testing.expectEqual(@as(?usize, 3), menu.selected(&levels));
    for (0..5) |_| menu.move(&levels, false);
    try std.testing.expectEqual(@as(?usize, 0), menu.selected(&levels));
    menu.highlightCurrent(&levels, "custom");
    try std.testing.expectEqual(@as(?usize, 0), menu.selected(&levels));
    menu.highlight = 3;
    try std.testing.expectEqual(@as(?usize, 1), menu.selected(levels[0..2]));
    try std.testing.expect(menu.selected(&.{}) == null);
    menu.move(&.{}, true);
    try std.testing.expect(menu.selected(&.{}) == null);
}
