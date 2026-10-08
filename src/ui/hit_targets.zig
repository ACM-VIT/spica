const std = @import("std");
const c = @import("../native/bindings.zig").c;
const widgets = @import("widgets.zig");

pub fn HitTargets(comptime Action: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Target = struct { bounds: c.SDL_FRect, action: Action };

        items: [capacity]Target = undefined,
        len: usize = 0,

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn add(self: *Self, action: Action, bounds: c.SDL_FRect) !void {
            if (self.len == capacity) return error.HitTargetBudget;
            self.items[self.len] = .{ .action = action, .bounds = bounds };
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const Target {
            return self.items[0..self.len];
        }

        pub fn topmost(self: *const Self, x: f32, y: f32) ?Target {
            var index = self.len;
            while (index != 0) {
                index -= 1;
                if (widgets.contains(self.items[index].bounds, x, y)) return self.items[index];
            }
            return null;
        }
    };
}

test "the most recently drawn target wins and the budget is enforced" {
    var targets: HitTargets(u8, 2) = .{};
    try targets.add(1, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try targets.add(2, .{ .x = 5, .y = 5, .w = 10, .h = 10 });
    try std.testing.expectError(error.HitTargetBudget, targets.add(3, .{ .x = 0, .y = 0, .w = 1, .h = 1 }));
    try std.testing.expectEqual(@as(u8, 2), targets.topmost(6, 6).?.action);
    try std.testing.expectEqual(@as(u8, 1), targets.topmost(1, 1).?.action);
    try std.testing.expect(targets.topmost(20, 20) == null);
    targets.clear();
    try std.testing.expect(targets.topmost(1, 1) == null);
}
