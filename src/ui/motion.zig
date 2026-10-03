const std = @import("std");

pub const Tween = struct {
    from: f32 = 1,
    target: f32 = 1,
    started: u64 = 0,
    duration: u64 = 160,

    pub fn value(self: *const Tween, now: u64) f32 {
        if (!self.active(now)) return self.target;
        const elapsed: f32 = @floatFromInt(now -| self.started);
        const duration: f32 = @floatFromInt(self.duration);
        const remaining = 1 - elapsed / duration;
        return self.from + (self.target - self.from) * (1 - remaining * remaining * remaining);
    }

    pub fn active(self: *const Tween, now: u64) bool {
        return self.from != self.target and now -| self.started < self.duration;
    }

    pub fn snap(self: *Tween, target: f32) void {
        self.from = target;
        self.target = target;
    }

    pub fn retarget(self: *Tween, target: f32, now: u64, enabled: bool) void {
        const current = self.value(now);
        self.from = if (enabled) current else target;
        self.target = target;
        self.started = now;
    }
};

test "short transitions settle exactly and stop requesting frames" {
    var tween: Tween = .{};
    tween.snap(0);
    tween.retarget(1, 100, true);
    try std.testing.expectEqual(@as(f32, 0), tween.value(100));
    try std.testing.expect(tween.value(180) > 0 and tween.value(180) < 1);
    try std.testing.expect(tween.active(180));
    try std.testing.expectEqual(@as(f32, 1), tween.value(260));
    try std.testing.expect(!tween.active(260));
}

test "reversing a transition starts at the currently displayed value" {
    var tween: Tween = .{};
    tween.retarget(0, 100, true);
    const halfway = tween.value(180);
    tween.retarget(1, 180, true);
    try std.testing.expectEqual(halfway, tween.value(180));
    try std.testing.expect(tween.value(220) > halfway);
    try std.testing.expectEqual(@as(f32, 1), tween.value(340));
}

test "disabled motion snaps immediately including during an active transition" {
    var tween: Tween = .{};
    tween.retarget(0, 100, true);
    tween.retarget(1, 120, false);
    try std.testing.expectEqual(@as(f32, 1), tween.value(120));
    try std.testing.expect(!tween.active(120));
    tween.retarget(0, 140, false);
    try std.testing.expectEqual(@as(f32, 0), tween.value(140));
    try std.testing.expect(!tween.active(140));
}
