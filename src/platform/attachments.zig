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
    completed: std.atomic.Value(bool) = .init(false),
    references: std.atomic.Value(usize) = .init(1),
    pub fn destroy(self: *Selection) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        for (self.paths) |path| if (path) |owned| allocator.free(owned);
        allocator.destroy(self);
    }
};

pub fn pick(window: *c.SDL_Window, event: u32, chat_id: u64) !*Selection {
    const selection = try allocator.create(Selection);
    selection.* = .{ .event = event, .chat_id = chat_id };
    _ = selection.references.fetchAdd(1, .monotonic); // App and callback each own a reference.
    c.SDL_ShowOpenFileDialog(chosen, selection, window, null, 0, null, true);
    return selection;
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
    // The event only wakes the UI. Completion and paths remain readable even
    // if SDL rejects the post; the App polls while its picker is outstanding.
    selection.completed.store(true, .release);
    _ = c.SDL_PushEvent(&event);
    selection.destroy();
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

test "picker completion survives a rejected SDL wake event" {
    try std.testing.expect(c.SDL_InitSubSystem(c.SDL_INIT_EVENTS));
    defer c.SDL_QuitSubSystem(c.SDL_INIT_EVENTS);
    const event = c.SDL_RegisterEvents(1);
    try std.testing.expect(event != 0);
    c.SDL_SetEventEnabled(event, false); // SDL_PushEvent returns false for disabled events.
    for ([_]bool{ false, true }) |failed| {
        const selection = try allocator.create(Selection);
        selection.* = .{ .event = event, .chat_id = 7, .references = .init(2) };
        defer selection.destroy();
        const files = [_][*c]const u8{ "/tmp/chosen image.png", null };
        chosen(selection, if (failed) null else &files, 0);
        try std.testing.expect(selection.completed.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), selection.references.load(.acquire));
        if (failed) {
            try std.testing.expectEqual(error.FilePickerUnavailable, selection.failure.?);
        } else {
            try std.testing.expectEqualStrings("/tmp/chosen image.png", selection.paths[0].?);
        }
    }
}
