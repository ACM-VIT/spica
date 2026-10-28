const std = @import("std");
const Time = @import("../platform/sidebar_time.zig");
const LineEdit = @import("../text/line_edit.zig").LineEdit;
const Calendar = @import("sidebar_menu.zig").Calendar;

pub const Field = struct {
    bytes: [32]u8 = @splat(0),
    len: usize = 0,
    edit: LineEdit = .{},
    select: bool = true,
    pub fn set(self: *Field, value: []const u8) void {
        std.debug.assert(value.len <= self.bytes.len);
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
        self.edit = .{};
        self.select = true;
    }
    pub fn slice(self: *const Field) []const u8 {
        return self.bytes[0..self.len];
    }
};

// Bounded presentation state only. Ownership of the thread and command receipt
// remains in View/App; this object never starts provider/domain work.
pub const State = struct {
    mode: enum { date, duration } = .date,
    date: Field = .{},
    time: Field = .{},
    amount: Field = .{},
    unit: Time.Unit = .hours,
    calendar: Calendar,
    calendar_open: bool = false,
    calendar_cursor: usize = 0,
    error_bytes: [160]u8 = @splat(0),
    error_len: usize = 0,
    pending: bool = false,
    requested: bool = false,
    deadline: i64 = 0,

    pub fn init(now: i64) !State {
        const initial = try Time.formatLocal(now + 3_600_000);
        const today = try Time.formatLocal(now);
        var self: State = .{ .calendar = try Calendar.init(initial.date, today.date) };
        self.date.set(&initial.date);
        self.time.set(&initial.time);
        self.amount.set("2");
        return self;
    }
    pub fn setError(self: *State, value: []const u8) void {
        const bounded = @import("../text/utf8.zig").prefix(value, self.error_bytes.len);
        @memcpy(self.error_bytes[0..bounded.len], bounded);
        self.error_len = bounded.len;
    }
    pub fn submit(self: *State, now: i64) bool {
        if (self.pending or self.requested) return false;
        const input: Time.Custom = if (self.mode == .date)
            .{ .date = .{ .date = self.date.slice(), .time = self.time.slice() } }
        else
            .{ .duration = .{ .amount = std.fmt.parseFloat(f64, self.amount.slice()) catch {
                self.setError("Enter a positive duration.");
                return false;
            }, .unit = self.unit } };
        self.deadline = Time.resolveCustom(now, input) catch {
            self.setError(if (self.mode == .date) "Choose a valid date and time in the future." else "Enter a positive duration.");
            return false;
        };
        self.error_len = 0;
        self.requested = true;
        return true;
    }
    pub fn chooseDate(self: *State, index: usize) bool {
        const cell = self.calendar.cell(index) orelse return false;
        if (cell.disabled) return false;
        self.date.set(&cell.date);
        self.calendar.selected = cell.date;
        self.calendar_open = false;
        self.error_len = 0;
        return true;
    }
    pub fn moveCalendar(self: *State, amount: i32) void {
        var index: i32 = @intCast(self.calendar_cursor);
        for (0..42) |_| {
            index += amount;
            if (index < 0 or index >= self.calendar.count()) return;
            const cell = self.calendar.cell(@intCast(index)) orelse return;
            if (!cell.disabled) {
                self.calendar_cursor = @intCast(index);
                return;
            }
        }
    }
};

test "custom sidebar snooze retains fractional duration and errors until receipt" {
    const now: i64 = 1_793_232_000_000;
    var state = try State.init(now);
    try std.testing.expectEqualStrings("2", state.amount.slice());
    state.mode = .duration;
    state.amount.set("1.5");
    state.unit = .minutes;
    try std.testing.expect(state.submit(now));
    try std.testing.expectEqual(now + 90_000, state.deadline);
    try std.testing.expect(!state.submit(now));
    state.requested = false;
    state.pending = true;
    state.setError("Busy");
    try std.testing.expect(!state.submit(now));
    try std.testing.expectEqualStrings("1.5", state.amount.slice());
    state.pending = false;
    state.amount.set("nan");
    try std.testing.expect(!state.submit(now));
    try std.testing.expect(state.error_len > 0);
    state.mode = .date;
    state.date.set("2026-02-30");
    try std.testing.expect(!state.submit(now));
    try std.testing.expect(!state.chooseDate(0));
}
