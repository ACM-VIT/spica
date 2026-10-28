const std = @import("std");

// Native menu/calendar state following T3 Code eb1510d (MIT),
// threadActionMenu.logic.ts and CustomSnoozeDialog.tsx. Fixed records only;
// rendering, input ownership and platform calendar resolution stay with callers.
pub const Action = enum {
    pin,
    unpin,
    settle,
    unsettle,
    wake,
    snooze,
    rename,
    filter,
    copy,
    copy_path,
    copy_branch,
    copy_id,
    preset,
    custom,
};
pub const Item = struct {
    action: Action,
    id: []const u8,
    label: []const u8,
    enabled: bool = true,
    separator_before: bool = false,
    preset_index: u3 = 0,
};
pub const Panel = struct {
    items: [16]Item = undefined,
    len: usize = 0,
    selected: ?usize = null,

    pub fn slice(self: *const Panel) []const Item {
        return self.items[0..self.len];
    }
    pub fn append(self: *Panel, item: Item) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = item;
        if (self.selected == null and item.enabled) self.selected = self.len;
        self.len += 1;
    }
    pub fn choose(self: *Panel, index: usize) bool {
        if (index >= self.len or !self.items[index].enabled) return false;
        self.selected = index;
        return true;
    }
    pub fn edge(self: *Panel, last: bool) void {
        self.selected = null;
        for (0..self.len) |offset| {
            const index = if (last) self.len - 1 - offset else offset;
            if (self.choose(index)) return;
        }
    }
    pub fn move(self: *Panel, down: bool) void {
        if (self.selected == null) {
            self.edge(!down);
            return;
        }
        var index = self.selected.?;
        for (0..self.len) |_| {
            index = if (down) (index + 1) % self.len else (index + self.len - 1) % self.len;
            if (self.choose(index)) return;
        }
        self.selected = null;
    }
    pub fn current(self: *const Panel) ?Item {
        const index = self.selected orelse return null;
        return if (index < self.len and self.items[index].enabled) self.items[index] else null;
    }
};
pub const MainState = struct {
    can_operate: bool,
    pinned: bool,
    settled: bool,
    snoozed: bool,
    can_snooze: bool,
    filter_active: bool,
};
pub fn main(state: MainState) Panel {
    var panel: Panel = .{};
    panel.append(.{ .action = if (state.pinned) .unpin else .pin, .id = "sidebar.menu.pin", .label = if (state.pinned) "Unpin thread" else "Pin thread", .enabled = state.can_operate });
    panel.append(.{ .action = if (state.settled) .unsettle else .settle, .id = "sidebar.menu.settle", .label = if (state.settled) "Un-settle thread" else "Settle thread", .enabled = state.can_operate });
    panel.append(.{ .action = if (state.snoozed) .wake else .snooze, .id = if (state.snoozed) "sidebar.menu.wake" else "sidebar.menu.snooze", .label = if (state.snoozed) "Wake thread" else "Snooze", .enabled = state.can_operate and (state.snoozed or state.can_snooze) });
    panel.append(.{ .action = .rename, .id = "sidebar.menu.rename", .label = "Rename thread", .separator_before = true });
    panel.append(.{ .action = .filter, .id = "sidebar.menu.filter", .label = if (state.filter_active) "Show all projects" else "Filter by project" });
    panel.append(.{ .action = .copy, .id = "sidebar.menu.copy", .label = "Copy", .separator_before = true });
    return panel;
}
pub fn copy(has_path: bool, has_branch: bool) Panel {
    var panel: Panel = .{};
    panel.append(.{ .action = .copy_path, .id = "sidebar.menu.copy_path", .label = "Path", .enabled = has_path });
    if (has_branch) panel.append(.{ .action = .copy_branch, .id = "sidebar.menu.copy_branch", .label = "Branch" });
    panel.append(.{ .action = .copy_id, .id = "sidebar.menu.copy_id", .label = "Thread ID" });
    return panel;
}

pub fn snooze() Panel {
    var panel: Panel = .{};
    panel.append(.{ .action = .preset, .id = "sidebar.menu.snooze.1h", .label = "In 1 hour", .preset_index = 0 });
    panel.append(.{ .action = .preset, .id = "sidebar.menu.snooze.3h", .label = "In 3 hours", .preset_index = 1 });
    panel.append(.{ .action = .preset, .id = "sidebar.menu.snooze.evening", .label = "This evening", .preset_index = 2 });
    panel.append(.{ .action = .preset, .id = "sidebar.menu.snooze.tomorrow", .label = "Tomorrow 09:00", .preset_index = 3 });
    panel.append(.{ .action = .preset, .id = "sidebar.menu.snooze.monday", .label = "Next week Monday 09:00", .preset_index = 4 });
    panel.append(.{ .action = .custom, .id = "sidebar.menu.snooze.custom", .label = "Custom…", .separator_before = true });
    return panel;
}

/// Gregorian date-grid presentation contains no OS timezone/locale mechanics.
/// Local today/selection come from the platform calendar boundary as ISO dates.
pub const Calendar = struct {
    year: u16,
    month: u8,
    selected: [10]u8,
    today: [10]u8,
    week_start: u3 = 0,
    pub const Cell = struct { date: [10]u8, day: u8, current_month: bool, disabled: bool };

    pub fn init(selected: [10]u8, today: [10]u8) !Calendar {
        const year = try std.fmt.parseInt(u16, selected[0..4], 10);
        const month = try std.fmt.parseInt(u8, selected[5..7], 10);
        const day = try std.fmt.parseInt(u8, selected[8..10], 10);
        if (year == 0 or year > 9999 or month < 1 or month > 12 or day < 1 or day > monthDays(year, month)) return error.InvalidDate;
        return .{ .year = year, .month = month, .selected = selected, .today = today };
    }
    fn monthDays(year: u16, month: u8) u8 {
        return switch (month) {
            2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        };
    }
    pub fn shift(self: *Calendar, forward: bool) bool {
        if (forward) {
            if (self.month == 12) {
                if (self.year == 9999) return false;
                self.year += 1;
                self.month = 1;
            } else self.month += 1;
        } else {
            if (self.month == 1) {
                if (self.year == 1) return false;
                self.year -= 1;
                self.month = 12;
            } else self.month -= 1;
        }
        return true;
    }
    fn start(self: Calendar) usize {
        const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        const year: i32 = @as(i32, self.year) - @as(i32, if (self.month < 3) 1 else 0);
        const weekday = @mod(year + @divFloor(year, 4) - @divFloor(year, 100) + @divFloor(year, 400) + offsets[self.month - 1] + 1, 7);
        return @intCast(@mod(weekday - @as(i32, self.week_start), 7));
    }
    pub fn count(self: Calendar) usize {
        return ((self.start() + monthDays(self.year, self.month) + 6) / 7) * 7;
    }
    pub fn cell(self: Calendar, index: usize) ?Cell {
        if (index >= self.count()) return null;
        var year = self.year;
        var month = self.month;
        var day: i32 = @as(i32, @intCast(index)) - @as(i32, @intCast(self.start())) + 1;
        const current = day > 0 and day <= monthDays(year, month);
        if (day < 1) {
            if (month == 1) {
                if (year == 1) return null;
                year -= 1;
                month = 12;
            } else month -= 1;
            day += monthDays(year, month);
        } else if (day > monthDays(year, month)) {
            day -= monthDays(year, month);
            if (month == 12) {
                if (year == 9999) return null;
                year += 1;
                month = 1;
            } else month += 1;
        }
        var formatted: [32]u8 = undefined;
        const rendered = std.fmt.bufPrint(&formatted, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, @as(u32, @intCast(day)) }) catch return null;
        if (rendered.len != 10) return null;
        var date: [10]u8 = undefined;
        @memcpy(&date, rendered);
        return .{ .date = date, .day = @intCast(day), .current_month = current, .disabled = std.mem.order(u8, &date, &self.today) == .lt };
    }
};

test "menus keep local utilities available and skip disabled items with wrapped navigation" {
    var panel = main(.{ .can_operate = false, .pinned = false, .settled = false, .snoozed = false, .can_snooze = true, .filter_active = false });
    try std.testing.expectEqual(Action.rename, panel.current().?.action);
    panel.move(false);
    try std.testing.expectEqual(Action.copy, panel.current().?.action);
    panel.move(true);
    try std.testing.expectEqual(Action.rename, panel.current().?.action);
    try std.testing.expect(!panel.choose(2));
    panel.edge(true);
    try std.testing.expectEqual(Action.copy, panel.current().?.action);
    var copied = copy(false, false);
    try std.testing.expectEqual(@as(usize, 2), copied.len);
    try std.testing.expectEqual(Action.copy_id, copied.current().?.action);
    copied.move(true);
    try std.testing.expectEqual(Action.copy_id, copied.current().?.action);
    const snoozes = snooze();
    try std.testing.expectEqual(@as(usize, 6), snoozes.len);
    try std.testing.expectEqual(@as(u3, 0), snoozes.items[0].preset_index);
    try std.testing.expectEqual(Action.custom, snoozes.items[5].action);
    panel = .{};
    panel.move(true);
    try std.testing.expect(panel.current() == null);
}

test "calendar grid includes outside days disables past dates and handles leap/year edges" {
    var calendar = try Calendar.init("2026-10-28".*, "2026-10-28".*);
    try std.testing.expectEqualStrings("2026-09-27", &calendar.cell(0).?.date);
    try std.testing.expect(calendar.cell(0).?.disabled);
    try std.testing.expectEqualStrings("2026-10-28", &calendar.cell(31).?.date);
    try std.testing.expect(!calendar.cell(31).?.disabled);
    try std.testing.expectEqual(@as(usize, 35), calendar.count());
    calendar = try Calendar.init("2028-02-29".*, "2028-02-28".*);
    try std.testing.expectEqualStrings("2028-02-29", &calendar.cell(30).?.date);
    try std.testing.expect(calendar.cell(30).?.current_month);
    calendar.week_start = 1;
    try std.testing.expectEqualStrings("2028-02-29", &calendar.cell(29).?.date);
    calendar = try Calendar.init("9999-12-31".*, "9999-12-31".*);
    try std.testing.expect(!calendar.shift(true));
    calendar = try Calendar.init("0001-01-01".*, "0001-01-01".*);
    try std.testing.expect(!calendar.shift(false));
    try std.testing.expectError(error.InvalidDate, Calendar.init("2026-02-29".*, "2026-01-01".*));
}
