const std = @import("std");
const c = @cImport({
    @cInclude("graphemebreak.h");
    @cInclude("wordbreak.h");
});

/// Returns the byte offset before the last extended grapheme cluster.
/// The caller reuses `breaks` across edits; no per-keystroke allocation.
pub fn beforeLastGrapheme(utf8: []const u8, breaks: []u8) !usize {
    if (utf8.len == 0) return 0;
    if (breaks.len < utf8.len) return error.InsufficientScratch;
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    c.set_graphemebreaks_utf8(utf8.ptr, utf8.len, null, @ptrCast(breaks.ptr));
    var i = utf8.len - 1;
    while (i > 0) {
        i -= 1;
        if (breaks[i] == c.GRAPHEMEBREAK_BREAK) return i + 1;
    }
    return 0;
}

/// The composer validates external input before mutation; the assembled text
/// stays valid by construction. Avoid rescanning it before each native pass.
pub fn analyzeValidUtf8(utf8: []const u8, graphemes: []u8, words: []u8) void {
    std.debug.assert(graphemes.len >= utf8.len and words.len >= utf8.len);
    if (utf8.len == 0) return;
    c.set_graphemebreaks_utf8(utf8.ptr, utf8.len, null, @ptrCast(graphemes.ptr));
    c.set_wordbreaks_utf8(utf8.ptr, utf8.len, null, @ptrCast(words.ptr));
}

/// libunibreak marks a boundary on the final byte preceding it.
pub fn isBoundary(breaks: []const u8, offset: usize) bool {
    return offset == 0 or (offset <= breaks.len and breaks[offset - 1] == 0);
}

pub fn previousBoundary(breaks: []const u8, offset: usize) usize {
    var at = @min(offset, breaks.len);
    if (at == 0) return 0;
    at -= 1;
    while (!isBoundary(breaks, at)) at -= 1;
    return at;
}

pub fn nextBoundary(breaks: []const u8, offset: usize) usize {
    var at = @min(offset, breaks.len);
    if (at == breaks.len) return at;
    at += 1;
    while (at < breaks.len and !isBoundary(breaks, at)) at += 1;
    return at;
}

/// Unicode White_Space at a known UTF-8/grapheme boundary.
pub fn whitespaceAt(utf8: []const u8, offset: usize) bool {
    if (offset >= utf8.len) return false;
    const size = std.unicode.utf8ByteSequenceLength(utf8[offset]) catch unreachable;
    const scalar = std.unicode.utf8Decode(utf8[offset..][0..size]) catch unreachable;
    return switch (scalar) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

test "delete complete combining, flag, and emoji joiner clusters" {
    var scratch: [128]u8 = undefined;
    const text = "a" ++ "e\u{301}" ++ "🇺🇸" ++ "👩‍💻";
    const after_emoji = try beforeLastGrapheme(text, &scratch);
    try std.testing.expectEqualStrings("a" ++ "e\u{301}" ++ "🇺🇸", text[0..after_emoji]);
    const after_flag = try beforeLastGrapheme(text[0..after_emoji], &scratch);
    try std.testing.expectEqualStrings("a" ++ "e\u{301}", text[0..after_flag]);
    const after_combining = try beforeLastGrapheme(text[0..after_flag], &scratch);
    try std.testing.expectEqualStrings("a", text[0..after_combining]);
    try std.testing.expectEqual(@as(usize, 0), try beforeLastGrapheme("a", &scratch));
}
