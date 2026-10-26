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

/// Fixed-storage semantic target ledger for painted native controls. IDs and
/// roles are copied into the ledger so automation can inspect a frame without
/// retaining transient text or pointers owned by a renderer.
pub fn SemanticTargets(comptime capacity: usize, comptime id_capacity: usize, comptime role_capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Target = struct {
            id: [id_capacity]u8 = undefined,
            id_len: usize = 0,
            role: [role_capacity]u8 = undefined,
            role_len: usize = 0,
            bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            enabled: bool = false,
        };
        items: [capacity]Target = @splat(.{}),
        len: usize = 0,
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
        pub fn add(self: *Self, id: []const u8, role: []const u8, bounds: c.SDL_FRect, enabled: bool) !void {
            if (self.len == capacity or id.len > id_capacity or role.len > role_capacity) return error.SemanticTargetBudget;
            var target = Target{ .bounds = bounds, .enabled = enabled, .id_len = id.len, .role_len = role.len };
            @memcpy(target.id[0..id.len], id);
            @memcpy(target.role[0..role.len], role);
            self.items[self.len] = target;
            self.len += 1;
        }
        pub fn slice(self: *const Self) []const Target {
            return self.items[0..self.len];
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

test "semantic targets copy bounded ids and roles" {
    var targets: SemanticTargets(2, 12, 8) = .{};
    try targets.add("workspace", "button", .{ .x = 1, .y = 2, .w = 3, .h = 4 }, true);
    try std.testing.expectEqualStrings("workspace", targets.slice()[0].id[0..targets.slice()[0].id_len]);
    try std.testing.expectEqualStrings("button", targets.slice()[0].role[0..targets.slice()[0].role_len]);
    try std.testing.expectError(error.SemanticTargetBudget, targets.add("identifier-too-long", "button", .{}, true));
}
