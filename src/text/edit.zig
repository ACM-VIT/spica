const std = @import("std");
const c = @cImport({ @cInclude("graphemebreak.h"); });

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
