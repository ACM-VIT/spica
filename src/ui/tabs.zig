const std = @import("std");

pub const Scroll = struct {
    offset: f32 = 0,
    content_width: f32 = 0,
    viewport_width: f32 = 0,
    overflowing: bool = false,

    pub fn configure(self: *Scroll, content_width: f32, window_width: f32) void {
        self.content_width = content_width;
        // Fit the trailing plus first; reserve arrows only after overflow occurs.
        self.overflowing = content_width + 38 > window_width;
        self.viewport_width = @max(1, window_width - (if (self.overflowing) @as(f32, 98) else 38));
        self.offset = if (self.overflowing) std.math.clamp(self.offset, 0, self.limit()) else 0;
    }

    pub fn left(self: *const Scroll) f32 {
        return if (self.overflowing) 32 else 0;
    }

    pub fn limit(self: *const Scroll) f32 {
        return if (self.overflowing) @max(0, self.content_width - self.viewport_width) else 0;
    }

    pub fn move(self: *Scroll, delta: f32) bool {
        const before = self.offset;
        self.offset = std.math.clamp(self.offset + delta, 0, self.limit());
        return self.offset != before;
    }

    pub fn wheel(self: *Scroll, x: f32, y: f32, flipped: bool) bool {
        const amount = if (x != 0) x else -y;
        return self.move(amount * 60 * (if (flipped) @as(f32, -1) else 1));
    }

    pub fn reveal(self: *Scroll, start: f32, end: f32) void {
        if (start < self.offset) self.offset = start;
        if (end > self.offset + self.viewport_width) self.offset = end - self.viewport_width;
        self.offset = std.math.clamp(self.offset, 0, self.limit());
    }
};

test "seven tabs scroll on a small display and fit on a large display" {
    var scroll: Scroll = .{};
    scroll.configure(7 * 180, 680);
    try std.testing.expect(scroll.overflowing);
    try std.testing.expect(scroll.wheel(1, 0, false));
    try std.testing.expectEqual(@as(f32, 60), scroll.offset);
    scroll.configure(7 * 180, 1300);
    try std.testing.expect(!scroll.overflowing);
    try std.testing.expectEqual(@as(f32, 0), scroll.offset);
    try std.testing.expect(!scroll.wheel(1, 0, false));
    try std.testing.expect(!scroll.wheel(0, -1, false));
}

test "overflow includes folder badges and stops at both ends" {
    var scroll: Scroll = .{};
    scroll.configure(3 * 180 + 100, 680);
    try std.testing.expect(!scroll.overflowing);
    scroll.configure(3 * 180 + 128, 680);
    try std.testing.expect(scroll.overflowing);
    _ = scroll.move(10000);
    try std.testing.expectEqual(scroll.limit(), scroll.offset);
    try std.testing.expect(!scroll.move(60));
    _ = scroll.move(-10000);
    try std.testing.expectEqual(@as(f32, 0), scroll.offset);
    try std.testing.expect(!scroll.move(-60));
}

test "horizontal gestures vertical wheels and flipped direction move the strip" {
    var scroll: Scroll = .{};
    scroll.configure(7 * 180, 680);
    _ = scroll.wheel(0.5, 0, false);
    try std.testing.expectEqual(@as(f32, 30), scroll.offset);
    _ = scroll.wheel(0, -1, false);
    try std.testing.expectEqual(@as(f32, 90), scroll.offset);
    _ = scroll.wheel(1, 0, true);
    try std.testing.expectEqual(@as(f32, 30), scroll.offset);
}

test "revealing the last tab keeps earlier tabs visible and removal clears overflow" {
    var scroll: Scroll = .{};
    scroll.configure(7 * 180, 680);
    scroll.reveal(6 * 180, 7 * 180);
    try std.testing.expectEqual(scroll.limit(), scroll.offset);
    try std.testing.expect(scroll.offset < 6 * 180);
    scroll.reveal(4 * 180, 5 * 180);
    try std.testing.expectEqual(scroll.limit(), scroll.offset); // Already visible tabs stay put.
    scroll.reveal(0, 180);
    try std.testing.expectEqual(@as(f32, 0), scroll.offset);
    _ = scroll.move(10000);
    scroll.configure(2 * 180, 680);
    try std.testing.expect(!scroll.overflowing);
    try std.testing.expectEqual(@as(f32, 0), scroll.offset);
}
