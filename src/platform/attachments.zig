const std = @import("std");
const c = @import("../native/bindings.zig").c;
const attachments = @import("../core/attachments.zig");
const allocator = std.heap.page_allocator;

/// Lives independently of App until the asynchronous native dialog completes.
pub const Selection = struct {
    event: u32,
    chat_id: u64,
    paths: [attachments.max_count]?[:0]u8 = @splat(null),
    failure: ?anyerror = null,
    pub fn destroy(self: *Selection) void {
        for (self.paths) |path| if (path) |owned| allocator.free(owned);
        allocator.destroy(self);
    }
};

pub fn pick(window: *c.SDL_Window, event: u32, chat_id: u64) !void {
    const selection = try allocator.create(Selection);
    selection.* = .{ .event = event, .chat_id = chat_id };
    c.SDL_ShowOpenFileDialog(chosen, selection, window, null, 0, null, true);
}

fn chosen(userdata: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    const selection: *Selection = @ptrCast(@alignCast(userdata.?));
    if (files == null) {
        selection.failure = error.FilePickerUnavailable;
    } else {
        var index: usize = 0;
        while (files[index] != null) : (index += 1) {
            if (index == selection.paths.len) {
                selection.failure = error.TooManyAttachments;
                break;
            }
            const path = std.mem.span(files[index]);
            if (path.len > 4096 or !std.unicode.utf8ValidateSlice(path)) {
                selection.failure = error.InvalidAttachmentPath;
                break;
            }
            selection.paths[index] = allocator.dupeZ(u8, path) catch {
                selection.failure = error.OutOfMemory;
                break;
            };
        }
    }
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = selection.event;
    event.user.code = 3;
    event.user.data1 = selection;
    if (!c.SDL_PushEvent(&event)) selection.destroy();
}

/// Image paste takes precedence only when an image representation is present.
/// Text-only clipboard contents continue through the existing editor path.
pub fn clipboardImage() !?[]u8 {
    for ([_][*:0]const u8{ "image/png", "image/jpeg", "image/webp", "image/gif", "image/tiff" }) |mime| {
        if (!c.SDL_HasClipboardData(mime)) continue;
        var size: usize = 0;
        const data = c.SDL_GetClipboardData(mime, &size) orelse return error.ClipboardRead;
        defer c.SDL_free(data);
        const limit: usize = if (std.mem.eql(u8, std.mem.span(mime), "image/tiff")) attachments.max_clipboard_bytes else attachments.max_image_bytes;
        if (size == 0 or size > limit) return error.ImageTooLarge;
        return try allocator.dupe(u8, @as([*]const u8, @ptrCast(data))[0..size]);
    }
    return null;
}
