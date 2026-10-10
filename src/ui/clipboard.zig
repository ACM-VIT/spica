const c = @import("../native/bindings.zig").c;
const Composer = @import("../text/composer.zig").Composer;

pub fn copySelection(editor: *const Composer, buffer: []u8) !void {
    const bytes = try editor.copySelection(buffer[0 .. buffer.len - 1]);
    if (bytes.len == 0) return;
    buffer[bytes.len] = 0;
    if (!c.SDL_SetClipboardText(@ptrCast(buffer.ptr))) return error.ClipboardWrite;
}
