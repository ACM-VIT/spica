const std = @import("std");
const edit = @import("edit.zig");

/// Selection only; text and capacity belong to the field. Scratch is bounded by
/// the public 160-byte title/search contract, never by document history.
pub const capacity = 160;

// Call sync before edits; caret/anchor then remain at UTF-8 grapheme boundaries.
pub const LineEdit = struct {
    caret: usize = std.math.maxInt(usize),
    anchor: usize = std.math.maxInt(usize),

    pub fn sync(self: *LineEdit, len: usize, select_all: bool) void {
        self.caret = @min(self.caret, len);
        self.anchor = if (select_all) 0 else @min(self.anchor, len);
        if (select_all) self.caret = len;
    }
    pub fn range(self: LineEdit) struct { start: usize, end: usize } {
        return .{ .start = @min(self.caret, self.anchor), .end = @max(self.caret, self.anchor) };
    }
    pub fn set(self: *LineEdit, at: usize, extend: bool) void {
        self.caret = at;
        if (!extend) self.anchor = at;
    }
    pub fn insert(self: *LineEdit, buffer: []u8, len: *usize, bytes: []const u8) !void {
        if (buffer.len > capacity or len.* > buffer.len) return error.TextTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidUtf8;
        for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidTitle;
        const selected = self.range();
        if (selected.end > len.*) return error.InvalidSelection;
        const next_len = len.* - (selected.end - selected.start) + bytes.len;
        if (next_len > buffer.len) return error.TextTooLarge;
        const tail = buffer[selected.end..len.*];
        if (selected.start + bytes.len > selected.end) {
            std.mem.copyBackwards(u8, buffer[selected.start + bytes.len .. next_len], tail);
        } else std.mem.copyForwards(u8, buffer[selected.start + bytes.len .. next_len], tail);
        @memcpy(buffer[selected.start..][0..bytes.len], bytes);
        len.* = next_len;
        var graphemes: [capacity]u8 = undefined;
        var words: [capacity]u8 = undefined;
        edit.analyzeValidUtf8(buffer[0..next_len], &graphemes, &words);
        var at = selected.start + bytes.len;
        while (at < next_len and !edit.isBoundary(graphemes[0..next_len], at)) at += 1;
        self.set(at, false);
    }
    pub fn move(self: *LineEdit, bytes: []const u8, right: bool, word: bool, extend: bool) !void {
        if (bytes.len > capacity) return error.TextTooLarge;
        var graphemes: [160]u8 = undefined;
        var words: [160]u8 = undefined;
        edit.analyzeValidUtf8(bytes, &graphemes, &words);
        const breaks = if (word) words[0..bytes.len] else graphemes[0..bytes.len];
        const selected = self.range();
        if (!extend and selected.start != selected.end) {
            self.set(if (right) selected.end else selected.start, false);
            return;
        }
        self.set(if (right) edit.nextBoundary(breaks, self.caret) else edit.previousBoundary(breaks, self.caret), extend);
    }
    pub fn delete(self: *LineEdit, buffer: []u8, len: *usize, forward: bool, word: bool) !void {
        if (buffer.len > capacity or len.* > buffer.len) return error.TextTooLarge;
        const selected = self.range();
        if (selected.start == selected.end) try self.move(buffer[0..len.*], forward, word, true);
        try self.insert(buffer, len, "");
    }
};

test "line editing replaces selections transactionally and moves whole Unicode clusters" {
    var buffer: [160]u8 = undefined;
    var len: usize = 0;
    var field: LineEdit = .{};
    field.sync(len, false);
    const value = "a" ++ "e\u{301}" ++ "🇺🇸" ++ "👩‍💻";
    try field.insert(&buffer, &len, value);
    try field.delete(&buffer, &len, false, false);
    try std.testing.expectEqualStrings("ae\u{301}🇺🇸", buffer[0..len]);
    try field.move(buffer[0..len], false, false, false);
    try field.delete(&buffer, &len, false, false);
    try std.testing.expectEqualStrings("a🇺🇸", buffer[0..len]);
    field.set(0, false);
    try field.delete(&buffer, &len, true, false);
    try std.testing.expectEqualStrings("🇺🇸", buffer[0..len]);
    field.sync(len, true);
    const before = field;
    try std.testing.expectError(error.TextTooLarge, field.insert(&buffer, &len, "x" ** 161));
    try std.testing.expectEqualDeep(before, field);
    try std.testing.expectEqualStrings("🇺🇸", buffer[0..len]);
    try std.testing.expectError(error.InvalidTitle, field.insert(&buffer, &len, "new\nline"));
    try field.insert(&buffer, &len, "🎮" ** 40);
    try std.testing.expectEqual(@as(usize, 160), len);
    field.set(0, false);
    try field.move(buffer[0..len], true, false, true);
    try field.insert(&buffer, &len, "z");
    try std.testing.expectEqual(@as(usize, 157), len);
    try std.testing.expectEqual(@as(usize, 1), field.caret);
}

test "line edges word navigation and invalid input preserve bounded state" {
    var buffer: [160]u8 = undefined;
    var len: usize = 0;
    var field: LineEdit = .{};
    field.sync(0, false);
    try field.delete(&buffer, &len, false, false);
    try field.delete(&buffer, &len, true, false);
    try field.insert(&buffer, &len, "hello world");
    const before = field;
    try std.testing.expectError(error.InvalidUtf8, field.insert(&buffer, &len, "\xff"));
    try std.testing.expectEqualDeep(before, field);
    try std.testing.expectEqualStrings("hello world", buffer[0..len]);
    try field.move(buffer[0..len], false, true, false);
    try std.testing.expectEqual(@as(usize, 6), field.caret);
    field.set(0, false);
    field.set(len, true);
    try std.testing.expectEqual(@as(usize, 0), field.range().start);
    try std.testing.expectEqual(len, field.range().end);
    field.set(len, false);
    try field.delete(&buffer, &len, true, false);
    try std.testing.expectEqualStrings("hello world", buffer[0..len]);
    try std.testing.expectError(error.TextTooLarge, field.move("x" ** 161, true, false, false));
}
