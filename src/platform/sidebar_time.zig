//! Local-calendar boundary for sidebar snooze controls. No process-global TZ or
//! locale mutation, borrowed libc strings, or retained allocations escape here.
//! Behavior follows T3 Code's threadSettled.ts at
//! eb1510d2493cbf28600432d5193cc22a1af8f3d8 (MIT, T3 Tools Inc., 2026).
const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("locale.h");
    @cInclude("langinfo.h");
});

const hour_ms = 3_600_000;
// JavaScript Date's exact, finite range, shared with the reference behavior.
const max_ms: i64 = 8_640_000_000_000_000;
pub const Error = error{ InvalidDate, InvalidTime, InvalidDuration, NotFuture, OutOfRange, LocalTimeUnavailable };
pub const Unit = enum { minutes, hours, days };
pub const Custom = union(enum) {
    date: struct { date: []const u8, time: []const u8 },
    duration: struct { amount: f64, unit: Unit },
};
pub const PresetId = enum { one_hour, three_hours, this_evening, tomorrow, next_monday };
pub const Text = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Preset = struct { id: PresetId, label: []const u8, when_label: Text, wake_ms: i64 };
pub const Presets = struct {
    items: [5]Preset = undefined,
    count: usize = 0,
    pub fn slice(self: *const Presets) []const Preset {
        return self.items[0..self.count];
    }
};
pub const LocalFormat = struct { date: [10]u8, time: [5]u8 };

const Civil = struct {
    year: i32,
    month: i32,
    day: i32,
    hour: i32 = 0,
    minute: i32 = 0,
    second: i32 = 0,
    weekday: i32 = 0,
    fn at(self: Civil, hour: i32, days: i32) Civil {
        var result = self;
        result.day += days;
        result.hour = hour;
        result.minute = 0;
        result.second = 0;
        return result;
    }
    fn same(self: Civil, other: Civil) bool {
        return self.year == other.year and self.month == other.month and self.day == other.day and
            self.hour == other.hour and self.minute == other.minute and self.second == other.second;
    }
};

fn checked(ms: i64) Error!i64 {
    if (ms < -max_ms or ms > max_ms) return error.OutOfRange;
    return ms;
}

const SystemCalendar = struct {
    fn local(ms: i64) Error!Civil {
        _ = try checked(ms);
        var seconds: c.time_t = @intCast(@divFloor(ms, 1000));
        var result: c.struct_tm = undefined;
        if (c.localtime_r(&seconds, &result) == null) return error.LocalTimeUnavailable;
        return fromTm(result);
    }

    fn instant(value: Civil, exact: bool) Error!i64 {
        // mktime's default ambiguous-time choice is unspecified. Try both DST
        // interpretations and retain the earlier exact match, as JS Date does.
        var earliest: ?i64 = null;
        const interpretations = [_]c_int{ -1, 0, 1 };
        for (interpretations) |dst| {
            var tm = toTm(value);
            tm.tm_isdst = dst;
            const seconds = c.mktime(&tm);
            const multiplied = @mulWithOverflow(@as(i64, @intCast(seconds)), 1000);
            if (multiplied[1] != 0) continue;
            const ms = checked(multiplied[0]) catch continue;
            if (!exact) return ms;
            const roundtrip = local(ms) catch continue;
            if (roundtrip.same(value) and (earliest == null or ms < earliest.?)) earliest = ms;
        }
        return earliest orelse error.InvalidDate;
    }

    fn label(ms: i64, weekday: bool) Error!Text {
        var seconds: c.time_t = @intCast(@divFloor(ms, 1000));
        var tm: c.struct_tm = undefined;
        if (c.localtime_r(&seconds, &tm) == null) return error.LocalTimeUnavailable;
        // An owned locale reads the user's environment without changing global
        // locale state. Respect 12/24-hour convention, omit seconds like T3.
        const locale = c.newlocale(c.LC_TIME_MASK, "", null);
        defer if (locale != null) c.freelocale(locale);
        var twelve_hour = false;
        if (locale != null) {
            const pattern = std.mem.span(c.nl_langinfo_l(c.T_FMT, locale));
            twelve_hour = std.mem.indexOf(u8, pattern, "%I") != null or
                std.mem.indexOf(u8, pattern, "%l") != null or
                std.mem.indexOf(u8, pattern, "%r") != null;
        }
        const pattern: [:0]const u8 = if (twelve_hour)
            (if (weekday) "%a %-I:%M %p" else "%-I:%M %p")
        else
            (if (weekday) "%a %H:%M" else "%H:%M");
        var result: Text = .{};
        result.len = if (locale != null)
            c.strftime_l(&result.bytes, result.bytes.len, pattern, &tm, locale)
        else
            c.strftime(&result.bytes, result.bytes.len, pattern, &tm);
        if (result.len == 0 or !std.unicode.utf8ValidateSlice(result.bytes[0..result.len])) {
            // A locale may use a legacy encoding or unusually long weekday/AM
            // strings. Fall back to ASCII rather than truncate/emit bad UTF-8.
            result.len = (std.fmt.bufPrint(&result.bytes, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch unreachable).len;
        }
        return result;
    }
};

fn fromTm(tm: c.struct_tm) Civil {
    return .{ .year = tm.tm_year + 1900, .month = tm.tm_mon + 1, .day = tm.tm_mday, .hour = tm.tm_hour, .minute = tm.tm_min, .second = tm.tm_sec, .weekday = tm.tm_wday };
}
fn toTm(value: Civil) c.struct_tm {
    var tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = value.year - 1900;
    tm.tm_mon = value.month - 1;
    tm.tm_mday = value.day;
    tm.tm_hour = value.hour;
    tm.tm_min = value.minute;
    tm.tm_sec = value.second;
    tm.tm_isdst = -1;
    return tm;
}

pub fn presets(now_ms: i64) Error!Presets {
    return presetsWith(SystemCalendar, now_ms);
}

fn presetsWith(comptime Calendar: type, now_ms: i64) Error!Presets {
    _ = try checked(now_ms);
    const now = try Calendar.local(now_ms);
    var result: Presets = .{};
    const append = struct {
        fn item(out: *Presets, id: PresetId, label: []const u8, wake: i64) Error!void {
            out.items[out.count] = .{ .id = id, .label = label, .wake_ms = try checked(wake), .when_label = try Calendar.label(wake, id == .next_monday) };
            out.count += 1;
        }
    }.item;
    try append(&result, .one_hour, "In 1 hour", now_ms + hour_ms);
    try append(&result, .three_hours, "In 3 hours", now_ms + 3 * hour_ms);
    const evening = try Calendar.instant(now.at(18, 0), false);
    if (evening - now_ms > hour_ms) try append(&result, .this_evening, "This evening", evening);
    const tomorrow = try Calendar.instant(now.at(9, 1), false);
    try append(&result, .tomorrow, "Tomorrow", tomorrow);
    const until_monday = @mod(1 - now.weekday + 7, 7);
    const next_week = try Calendar.instant(now.at(9, if (until_monday == 0) 7 else until_monday), false);
    if (next_week != tomorrow) try append(&result, .next_monday, "Next week", next_week);
    return result;
}

pub fn resolveCustom(now_ms: i64, input: Custom) Error!i64 {
    return customWith(SystemCalendar, now_ms, input);
}

fn customWith(comptime Calendar: type, now_ms: i64, input: Custom) Error!i64 {
    _ = try checked(now_ms);
    const wake = switch (input) {
        .duration => |duration| blk: {
            if (!std.math.isFinite(duration.amount) or duration.amount <= 0) return error.InvalidDuration;
            const unit_ms: f64 = switch (duration.unit) {
                .minutes => 60_000,
                .hours => hour_ms,
                .days => 24 * hour_ms,
            };
            const floating = @as(f64, @floatFromInt(now_ms)) + duration.amount * unit_ms;
            if (!std.math.isFinite(floating) or floating < -max_ms or floating > max_ms) return error.OutOfRange;
            break :blk @as(i64, @intFromFloat(floating));
        },
        .date => |date| blk: {
            const value = try parse(date.date, date.time);
            const ms = try Calendar.instant(value, true);
            // Defend against a platform calendar normalizing an invalid date or
            // a skipped DST wall-clock minute into a different valid instant.
            if (!(try Calendar.local(ms)).same(value)) return error.InvalidDate;
            break :blk ms;
        },
    };
    _ = try checked(wake);
    if (wake <= now_ms) return error.NotFuture;
    return wake;
}

fn digits(value: []const u8) Error!i32 {
    var result: i32 = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidDate;
        result = result * 10 + byte - '0';
    }
    return result;
}
fn parse(date: []const u8, time: []const u8) Error!Civil {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.InvalidDate;
    if (time.len != 5 or time[2] != ':') return error.InvalidTime;
    const result: Civil = .{ .year = try digits(date[0..4]), .month = try digits(date[5..7]), .day = try digits(date[8..10]), .hour = digits(time[0..2]) catch return error.InvalidTime, .minute = digits(time[3..5]) catch return error.InvalidTime };
    if (result.month < 1 or result.month > 12 or result.day < 1 or result.day > 31) return error.InvalidDate;
    if (result.hour > 23 or result.minute > 59) return error.InvalidTime;
    return result;
}

pub fn formatLocal(ms: i64) Error!LocalFormat {
    return formatWith(SystemCalendar, ms);
}
fn formatWith(comptime Calendar: type, ms: i64) Error!LocalFormat {
    const value = try Calendar.local(ms);
    if (value.year < 0 or value.year > 9999) return error.OutOfRange;
    var result: LocalFormat = undefined;
    _ = std.fmt.bufPrint(&result.date, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(value.year)), @as(u32, @intCast(value.month)), @as(u32, @intCast(value.day)) }) catch return error.OutOfRange;
    _ = std.fmt.bufPrint(&result.time, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(value.hour)), @as(u32, @intCast(value.minute)) }) catch return error.OutOfRange;
    return result;
}

// Injected UTC calendar avoids changing process TZ while tests run in parallel.
const Utc = struct {
    fn local(ms: i64) Error!Civil {
        var seconds: c.time_t = @intCast(@divFloor(try checked(ms), 1000));
        var tm: c.struct_tm = undefined;
        if (c.gmtime_r(&seconds, &tm) == null) return error.LocalTimeUnavailable;
        return fromTm(tm);
    }
    fn instant(value: Civil, _: bool) Error!i64 {
        var tm = toTm(value);
        return checked(@as(i64, @intCast(c.timegm(&tm))) * 1000);
    }
    fn label(ms: i64, _: bool) Error!Text {
        const value = try local(ms);
        var result: Text = .{};
        result.len = (std.fmt.bufPrint(&result.bytes, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(value.hour)), @as(u32, @intCast(value.minute)) }) catch unreachable).len;
        return result;
    }
};

// New York's 2026 transitions modeled over UTC conversion, without global TZ.
const Dst = struct {
    const spring: i64 = 1_772_953_200_000; // 2026-03-08T07:00Z
    const autumn: i64 = 1_793_512_800_000; // 2026-11-01T06:00Z
    fn offset(ms: i64) i64 {
        return if (ms >= spring and ms < autumn) 4 * hour_ms else 5 * hour_ms;
    }
    fn local(ms: i64) Error!Civil {
        return Utc.local(ms - offset(ms));
    }
    fn instant(value: Civil, exact: bool) Error!i64 {
        const naive = try Utc.instant(value, false);
        for ([_]i64{ 4 * hour_ms, 5 * hour_ms }) |shift| {
            const candidate = naive + shift;
            if ((try local(candidate)).same(value)) return candidate;
        }
        if (exact) return error.InvalidDate;
        return naive + 5 * hour_ms;
    }
    fn label(ms: i64, weekday: bool) Error!Text {
        return Utc.label(ms - offset(ms), weekday);
    }
};

test "snooze presets preserve milliseconds and exact evening boundary, omit duplicate Monday" {
    const before = try Utc.instant(try parse("2026-10-27", "16:59"), false);
    const options = try presetsWith(Utc, before + 59_999);
    try std.testing.expectEqual(@as(usize, 5), options.count);
    try std.testing.expectEqual(before + 59_999 + hour_ms, options.items[0].wake_ms);
    try std.testing.expectEqual(before + 59_999 + 3 * hour_ms, options.items[1].wake_ms);
    try std.testing.expectEqual(PresetId.this_evening, options.items[2].id);
    const at_boundary = try presetsWith(Utc, before + 60_000);
    try std.testing.expectEqual(@as(usize, 4), at_boundary.count);
    const sunday = try presetsWith(Utc, try Utc.instant(try parse("2026-11-01", "12:00"), false));
    try std.testing.expectEqual(@as(usize, 4), sunday.count);
    try std.testing.expectEqual(PresetId.tomorrow, sunday.items[3].id);
    const monday = try presetsWith(Utc, try Utc.instant(try parse("2026-11-02", "12:00"), false));
    try std.testing.expectEqual(@as(usize, 5), monday.count);
    try std.testing.expectEqualStrings("Next week", monday.items[4].label);
    try std.testing.expectEqualStrings("09:00", monday.items[4].when_label.slice());
}

test "snooze custom duration validates finite bounds, fractional milliseconds and future edge" {
    try std.testing.expectEqual(@as(i64, 90_123), try customWith(Utc, 123, .{ .duration = .{ .amount = 1.5, .unit = .minutes } }));
    try std.testing.expectEqual(@as(i64, 86_400_123), try customWith(Utc, 123, .{ .duration = .{ .amount = 1, .unit = .days } }));
    for ([_]f64{ 0, -1, std.math.inf(f64), std.math.nan(f64) }) |amount|
        try std.testing.expectError(error.InvalidDuration, customWith(Utc, 0, .{ .duration = .{ .amount = amount, .unit = .hours } }));
    try std.testing.expectError(error.NotFuture, customWith(Utc, 1, .{ .duration = .{ .amount = 0.000_000_1, .unit = .minutes } }));
    try std.testing.expectError(error.OutOfRange, customWith(Utc, max_ms, .{ .duration = .{ .amount = 1, .unit = .hours } }));
    try std.testing.expectError(error.OutOfRange, customWith(Utc, 0, .{ .duration = .{ .amount = std.math.floatMax(f64), .unit = .days } }));
    try std.testing.expectError(error.OutOfRange, presetsWith(Utc, std.math.maxInt(i64)));
}

test "custom wall-clock input rejects normalization and accepts leap day exactly" {
    const leap = try customWith(Utc, 0, .{ .date = .{ .date = "2028-02-29", .time = "23:59" } });
    const formatted = try formatWith(Utc, leap);
    try std.testing.expectEqualStrings("2028-02-29", &formatted.date);
    try std.testing.expectEqualStrings("23:59", &formatted.time);
    for ([_][]const u8{ "2026-02-29", "2028-02-30", "2028-04-31", "2028-13-01", "2028-00-01", "2028-01-00", "2028-1-01", "abcd-01-01" }) |date|
        try std.testing.expectError(error.InvalidDate, customWith(Utc, 0, .{ .date = .{ .date = date, .time = "12:00" } }));
    for ([_][]const u8{ "24:00", "12:60", "1:00", "ab:00" }) |time|
        try std.testing.expectError(error.InvalidTime, customWith(Utc, 0, .{ .date = .{ .date = "2028-01-01", .time = time } }));
    try std.testing.expectError(error.NotFuture, customWith(Utc, leap, .{ .date = .{ .date = "2028-02-29", .time = "23:59" } }));
    try std.testing.expectEqual(leap, try customWith(Utc, leap - 1, .{ .date = .{ .date = "2028-02-29", .time = "23:59" } }));
}

test "calendar presets cross short and long DST days, custom skipped minute rejects and overlap chooses earlier" {
    const spring_now = try Dst.instant(try parse("2026-03-07", "23:30"), true);
    const spring_options = try presetsWith(Dst, spring_now);
    try std.testing.expectEqual(@as(i64, 8 * hour_ms + hour_ms / 2), spring_options.items[2].wake_ms - spring_now);
    const spring_date = try formatWith(Dst, spring_options.items[2].wake_ms);
    try std.testing.expectEqualStrings("2026-03-08", &spring_date.date);
    try std.testing.expectEqualStrings("09:00", &spring_date.time);
    const autumn_now = try Dst.instant(try parse("2026-10-31", "23:30"), true);
    const autumn_options = try presetsWith(Dst, autumn_now);
    try std.testing.expectEqual(@as(i64, 10 * hour_ms + hour_ms / 2), autumn_options.items[2].wake_ms - autumn_now);
    try std.testing.expectError(error.InvalidDate, customWith(Dst, 0, .{ .date = .{ .date = "2026-03-08", .time = "02:30" } }));
    const overlap = try customWith(Dst, 0, .{ .date = .{ .date = "2026-11-01", .time = "01:30" } });
    try std.testing.expectEqual(try Utc.instant(try parse("2026-11-01", "05:30"), false), overlap);
}

test "host libc calendar formats and resolves the same real local minute without TZ mutation" {
    const stamp: i64 = 1_793_232_000_000;
    const local = try formatLocal(stamp);
    const resolved = try resolveCustom(stamp - 2 * hour_ms, .{ .date = .{ .date = &local.date, .time = &local.time } });
    const roundtrip = try formatLocal(resolved);
    try std.testing.expectEqual(local, roundtrip);
    const options = try presets(stamp);
    try std.testing.expect(options.count >= 3 and options.count <= 5);
    for (options.slice()) |option| {
        try std.testing.expect(option.wake_ms > stamp);
        try std.testing.expect(option.when_label.len > 0 and option.when_label.len < option.when_label.bytes.len);
    }
    try std.testing.expectError(error.InvalidDate, resolveCustom(0, .{ .date = .{ .date = "2026-02-29", .time = "12:00" } }));
    // The same test executable is also run in an isolated child whose TZ is
    // America/New_York. No test or product code changes TZ/global locale.
    const spring_local = try SystemCalendar.local(Dst.spring);
    const autumn_local = try SystemCalendar.local(Dst.autumn);
    if (spring_local.hour == 3 and autumn_local.hour == 1) {
        try std.testing.expectError(error.InvalidDate, resolveCustom(0, .{ .date = .{ .date = "2026-03-08", .time = "02:30" } }));
        const overlap = try resolveCustom(0, .{ .date = .{ .date = "2026-11-01", .time = "01:30" } });
        try std.testing.expectEqual(try Utc.instant(try parse("2026-11-01", "05:30"), false), overlap);
        std.debug.print("real libc transition cases verified: 2026-03-08 02:30 rejected; 2026-11-01 01:30 chose 05:30Z\n", .{});
    }
}
