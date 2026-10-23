const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Composer = @import("../text/composer.zig").Composer;

pub fn copySelection(editor: *const Composer, buffer: []u8) !void {
    if (buffer.len == 0) return error.InsufficientBuffer;
    const bytes = try editor.copySelection(buffer[0 .. buffer.len - 1]);
    try copyBytes(bytes, buffer);
}

/// Exact selected source or rendered bytes; caller chooses the representation.
pub fn copyBytes(bytes: []const u8, buffer: []u8) !void {
    if (bytes.len >= buffer.len) return error.InsufficientBuffer;
    if (bytes.len == 0) return;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.ClipboardContainsNul;
    std.mem.copyForwards(u8, buffer[0..bytes.len], bytes);
    buffer[bytes.len] = 0;
    if (!c.SDL_SetClipboardText(@ptrCast(buffer.ptr))) return error.ClipboardWrite;
}

test "embedded NUL selection rejects before SDL clipboard changes" {
    var editor = try Composer.init(std.testing.allocator);
    defer editor.deinit();
    try editor.setText("a\x00b");
    editor.selectAll();
    var buffer: [16]u8 = undefined;
    try std.testing.expectError(error.ClipboardContainsNul, copySelection(&editor, &buffer));
    try std.testing.expectEqualStrings("a\x00b", editor.textBytes());
    try std.testing.expectError(error.InsufficientBuffer, copySelection(&editor, &.{}));
}
