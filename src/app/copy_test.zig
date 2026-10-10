const std = @import("std");
const c = @import("../native/bindings.zig").c;
const theme_module = @import("../ui/theme.zig");
const TranscriptView = @import("../features/transcript/view.zig").View;
const Library = @import("../features/library/panel.zig");
const Composer = @import("../text/composer.zig").Composer;
const App = @import("../app.zig").App;
const input = @import("input.zig");
const clipboard = @import("../ui/clipboard.zig");
const conversation = @import("../features/transcript/conversation.zig");

test "assistant copy controls paint in both themes and use SDL clipboard without changing layout" {
    const allocator = std.testing.allocator;
    const Paint = struct {
        fn clear(renderer: *c.SDL_Renderer, palette: theme_module.Palette) !void {
            try std.testing.expect(c.SDL_SetRenderDrawColor(renderer, palette.canvas.r, palette.canvas.g, palette.canvas.b, 255));
            try std.testing.expect(c.SDL_RenderClear(renderer));
            // App.paint installs the transcript viewport clip before draw.
            const clip = c.SDL_Rect{ .x = 0, .y = 0, .w = 640, .h = 400 };
            try std.testing.expect(c.SDL_SetRenderClipRect(renderer, &clip));
        }

        fn expectInk(pixels: *c.SDL_Surface, rect: c.SDL_Rect, color: theme_module.Color, tolerance: u8) !void {
            var count: usize = 0;
            for (0..@as(usize, @intCast(rect.h))) |y| {
                for (0..@as(usize, @intCast(rect.w))) |x| {
                    var r: u8 = 0;
                    var g: u8 = 0;
                    var b: u8 = 0;
                    try std.testing.expect(c.SDL_ReadSurfacePixel(pixels, rect.x + @as(c_int, @intCast(x)), rect.y + @as(c_int, @intCast(y)), &r, &g, &b, null));
                    if (@abs(@as(i16, r) - color.r) <= tolerance and @abs(@as(i16, g) - color.g) <= tolerance and @abs(@as(i16, b) - color.b) <= tolerance) count += 1;
                }
            }
            try std.testing.expect(count > 8);
        }

        fn expectControl(renderer: *c.SDL_Renderer, y: f32, palette: theme_module.Palette, feedback: ?bool) !void {
            const pixels = c.SDL_RenderReadPixels(renderer, null) orelse return error.ReadPixels;
            defer c.SDL_DestroySurface(pixels);
            const top: c_int = @intFromFloat(y);
            // Separate regions ensure the panel or icon cannot stand in for text.
            try expectInk(pixels, .{ .x = 534, .y = top + 5, .w = 4, .h = 12 }, palette.raised, 0);
            // Text is antialiased; neither theme's panel falls within this tolerance.
            if (feedback) |success| {
                try expectInk(pixels, .{ .x = 540, .y = top + 3, .w = 80, .h = 19 }, if (success) palette.accent else palette.error_color, 32);
            } else {
                try expectInk(pixels, .{ .x = 540, .y = top + 3, .w = 16, .h = 16 }, palette.muted, 32);
                try expectInk(pixels, .{ .x = 564, .y = top + 3, .w = 56, .h = 19 }, palette.muted, 32);
            }
        }
    };
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    try std.testing.expect(c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "dummy"));
    defer _ = c.SDL_ResetHint(c.SDL_HINT_VIDEO_DRIVER);
    try std.testing.expect(c.SDL_InitSubSystem(c.SDL_INIT_VIDEO));
    defer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    const window = c.SDL_CreateWindow("Copy regression", 640, 480, c.SDL_WINDOW_HIDDEN) orelse return error.Window;
    defer c.SDL_DestroyWindow(window);
    const surface = c.SDL_CreateSurface(640, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(engine);
    try std.testing.expect(c.spica_text_set_monospace(engine, ".deps/install/fonts/JetBrainsMono-Regular.ttf"));
    const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/theme.json", allocator, .limited(16384));
    defer allocator.free(theme_bytes);
    const appearance = try theme_module.parse(allocator, theme_bytes);
    const md = @import("../content/markdown.zig");
    const store = @import("../core/store.zig");
    const first = "**First** café 👩‍💻";
    const second = "[Second](https://example.test)\n\n```sh\necho hello\n```";
    const thought = "Private reasoning";
    var entries = [_]store.ConversationEntry{
        .{ .ordinal = 10, .role = .user, .content_id = @splat(1), .length = 4 },
        .{ .ordinal = 20, .role = .assistant, .content_id = @splat(2), .length = first.len, .timestamp = 1_700_000_000_000, .reasoning = .{ .content_ref = @splat(4), .length = thought.len } },
        .{ .ordinal = 30, .role = .assistant, .content_id = @splat(3), .length = second.len },
    };
    var app: App = undefined;
    app.allocator = allocator;
    app.window = window;
    app.renderer = renderer;
    app.wake_event = 0;
    app.closing = false;
    app.force_dialog = false;
    app.settings_open = false;
    app.model_picker = .{};
    app.thinking_menu = .{};
    app.focused_editor = true;
    app.editor_view = .{ .bounds = .{ .x = 0, .y = 400, .w = 640, .h = 80 } };
    app.buttons = .{};
    app.dirty = false;
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    try app.editor.setText("composer selection");
    app.editor.anchor = 0;
    app.copy_buffer = try allocator.alloc(u8, 65537);
    defer allocator.free(app.copy_buffer);
    app.transcript = TranscriptView.init(allocator);
    defer app.transcript.deinit();
    try app.transcript.update(&entries);
    for ([_][]const u8{ "User", first, second }, entries) |source, entry| {
        try app.transcript.accept(renderer, .{ .generation = 1, .ordinal = entry.ordinal, .document = try md.parse(allocator, entry.content_id, source) });
    }
    try app.transcript.accept(renderer, .{ .generation = 1, .ordinal = 20, .document = try md.parse(allocator, @splat(4), thought) });
    app.transcript.toggle(.{ .ordinal = 20, .kind = .reasoning });
    var scroll: f32 = 0;
    for ([_]bool{ false, true }) |light| {
        const palette = if (light) appearance.light else appearance.dark;
        try Paint.clear(renderer, palette);
        try app.transcript.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, palette, light);
        const height = app.transcript.height;
        var targets: [2]f32 = undefined;
        for ([_]usize{ 20, 30 }, 0..) |ordinal, slot| {
            var found = false;
            for (0..400) |row| {
                const y: f32 = @floatFromInt(row);
                if (app.transcript.copyAt(600, y) == ordinal) {
                    targets[slot] = y;
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
            try Paint.expectControl(renderer, targets[slot], palette, null);
        }
        try std.testing.expect(c.SDL_SetClipboardText("unchanged"));
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = c.SDL_BUTTON_RIGHT;
        event.button.x = 600;
        event.button.y = targets[0];
        try input.handle(&app, &event);
        try std.testing.expect(app.transcript.copyDeadline() == null);
        app.focused_editor = true;
        event.button.button = c.SDL_BUTTON_LEFT;
        for ([_][]const u8{ "First café 👩‍💻\n", "Second\necho hello\n" }, targets, [_]usize{ 20, 30 }) |expected, y, ordinal| {
            event.button.y = y;
            try input.handle(&app, &event);
            const actual = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
            defer c.SDL_free(actual);
            try std.testing.expectEqualStrings(expected, std.mem.span(actual));
            try std.testing.expectEqual(ordinal, app.transcript.copy_feedback.?.ordinal);
            try std.testing.expect(app.transcript.copy_feedback.?.success);
            try std.testing.expect(app.focused_editor and app.dirty);
            try std.testing.expectEqualStrings("composer selection", app.editor.textBytes());
            try std.testing.expectEqual(@as(usize, 0), app.editor.anchor);
            const due = app.transcript.copyDeadline().?;
            try std.testing.expect(!app.transcript.expireCopyFeedback(due - 1));
            try Paint.clear(renderer, palette);
            try app.transcript.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, palette, light);
            try Paint.expectControl(renderer, y, palette, true);
            try std.testing.expectEqual(height, app.transcript.height);
            try std.testing.expect(app.transcript.expireCopyFeedback(due));
            try std.testing.expect(app.transcript.copyDeadline() == null);
            try Paint.clear(renderer, palette);
            try app.transcript.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, palette, light);
            try Paint.expectControl(renderer, y, palette, null);
        }
        app.transcript.copied(20, false, 0);
        try Paint.clear(renderer, palette);
        try app.transcript.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, palette, light);
        try Paint.expectControl(renderer, targets[0], palette, false);
        try std.testing.expectEqual(height, app.transcript.height);
        try std.testing.expect(app.transcript.expireCopyFeedback(app.transcript.copyDeadline().?));
    }
    // Composer copy still uses its selected text and original fixed buffer.
    try clipboard.copySelection(&app.editor, app.copy_buffer);
    const selected = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
    defer c.SDL_free(selected);
    try std.testing.expectEqualStrings("composer selection", std.mem.span(selected));
    // A streaming update invalidates hit geometry and cannot copy the old cache.
    entries[1].length += 1;
    try app.transcript.update(&entries);
    try std.testing.expect(app.transcript.copyAt(600, 100) == null);
    try std.testing.expectError(error.ResponseUnavailable, conversation.copyResponse(&app, 20));
    try std.testing.expect(!app.transcript.copy_feedback.?.success);
    const untouched = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
    defer c.SDL_free(untouched);
    try std.testing.expectEqualStrings("composer selection", std.mem.span(untouched));
    app.transcript.clear();
    try std.testing.expect(app.transcript.copyDeadline() == null);
}

test "SDL clipboard write failure records failed response feedback" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(c.SDL_InitFlags, 0), c.SDL_WasInit(c.SDL_INIT_VIDEO));
    const surface = c.SDL_CreateSurface(32, 32, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const md = @import("../content/markdown.zig");
    const id: md.ContentId = @splat(1);
    const body = "An available answer";
    var app: App = undefined;
    app.allocator = allocator;
    app.dirty = false;
    app.transcript = TranscriptView.init(allocator);
    defer app.transcript.deinit();
    try app.transcript.update(&.{.{ .ordinal = 0, .role = .assistant, .content_id = id, .length = body.len }});
    try app.transcript.accept(renderer, .{ .generation = 1, .ordinal = 0, .document = try md.parse(allocator, id, body) });
    // No video subsystem: this exercises SDL's real failure return, rather
    // than the unavailable-document path or manually injected feedback.
    try std.testing.expectError(error.ClipboardWrite, conversation.copyResponse(&app, 0));
    try std.testing.expect(app.dirty);
    try std.testing.expect(!app.transcript.copy_feedback.?.success);
    try std.testing.expect(app.transcript.copyDeadline() != null);
}
