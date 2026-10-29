const std = @import("std");
const c = @import("../native/bindings.zig").c;
const widgets = @import("widgets.zig");
const Color = @import("color.zig").Color;
const utf8 = @import("../text/utf8.zig");

pub const max_bytes = 128;

const Entry = struct { bytes: [max_bytes]u8 = undefined, len: usize = 0, size: c_uint = 0, layout: ?*c.SpicaTextLayout = null, used: u64 = 0 };

pub const LabelCache = struct {
    entries: [64]Entry = [_]Entry{.{}} ** 64,
    clock: u64 = 0,

    pub fn deinit(self: *LabelCache) void {
        for (&self.entries) |*entry| if (entry.layout) |layout| {
            c.spica_text_layout_release(layout);
            entry.layout = null;
        };
    }

    pub fn layoutFor(self: *LabelCache, text: *c.SpicaText, bytes: []const u8, size: c_uint) !*c.SpicaTextLayout {
        if (bytes.len > max_bytes) return error.LabelTooLong;
        self.clock += 1;
        var replacement = &self.entries[0];
        for (&self.entries) |*entry| {
            if (entry.layout != null and entry.size == size and std.mem.eql(u8, entry.bytes[0..entry.len], bytes)) {
                entry.used = self.clock;
                return entry.layout.?;
            }
            if (entry.layout == null or entry.used < replacement.used) replacement = entry;
        }
        if (replacement.layout) |old| c.spica_text_layout_release(old);
        replacement.layout = null;
        replacement.layout = c.spica_text_layout_create(text, bytes.ptr, bytes.len, 2000, size, false) orelse return error.LabelLayout;
        @memcpy(replacement.bytes[0..bytes.len], bytes);
        replacement.len = bytes.len;
        replacement.size = size;
        replacement.used = self.clock;
        return replacement.layout.?;
    }

    pub fn draw(self: *LabelCache, text: *c.SpicaText, bytes: []const u8, x: f32, top: f32, size: c_uint, color: Color) !void {
        if (!c.spica_text_layout_draw(text, try self.layoutFor(text, bytes, size), x, top, widgets.rgba(color))) return error.LabelDraw;
    }

    pub fn width(self: *LabelCache, text: *c.SpicaText, bytes: []const u8, size: c_uint) !f32 {
        var row: c.SpicaTextLine = undefined;
        return if (c.spica_text_layout_line(try self.layoutFor(text, bytes, size), 0, &row)) row.width else 0;
    }

    pub fn drawFitted(self: *LabelCache, renderer: *c.SDL_Renderer, text: *c.SpicaText, bytes: []const u8, x: f32, top: f32, available: f32, size: c_uint, color: Color) !void {
        if (available <= 0) return;
        // Bound presentation before measuring/caching. The caller retains the
        // complete identity; clipping alone cannot bound shaping or cache keys.
        const visible = utf8.prefix(bytes, max_bytes);
        const truncated = visible.len < bytes.len or try self.width(text, visible, size) > available;
        const suffix_width = if (truncated) try self.width(text, "…", size) else 0;
        var clip = widgets.Clip.push(renderer, .{ .x = x, .y = top, .w = @max(0, available - suffix_width), .h = @floatFromInt(size + 8) });
        defer clip.restore(renderer);
        try self.draw(text, visible, x, top, size, color);
        clip.restore(renderer);
        if (truncated) try self.draw(text, "…", x + available - suffix_width, top, size, color);
    }

    pub fn drawCentered(self: *LabelCache, renderer: *c.SDL_Renderer, text: *c.SpicaText, bytes: []const u8, x: f32, top: f32, available: f32, size: c_uint, color: Color) !void {
        if (available <= 0) return;
        const label_width = @min(available, try self.width(text, utf8.prefix(bytes, max_bytes), size));
        try self.drawFitted(renderer, text, bytes, x + (available - label_width) / 2, top, label_width, size, color);
    }
};

const TestCanvas = struct {
    surface: *c.SDL_Surface,
    renderer: *c.SDL_Renderer,
    text: *c.SpicaText,

    fn init() !TestCanvas {
        const surface = c.SDL_CreateSurface(200, 40, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
        errdefer c.SDL_DestroySurface(surface);
        const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
        return .{ .surface = surface, .renderer = renderer, .text = text };
    }

    fn deinit(self: TestCanvas) void {
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroySurface(self.surface);
    }

    fn expectClip(self: TestCanvas, expected: c.SDL_Rect) !void {
        var actual: c.SDL_Rect = undefined;
        try std.testing.expect(c.SDL_RenderClipEnabled(self.renderer));
        try std.testing.expect(c.SDL_GetRenderClipRect(self.renderer, &actual));
        try std.testing.expectEqual(expected, actual);
    }

    fn litColumns(self: TestCanvas, start: c_int, end: c_int) !usize {
        const pixels: *c.SDL_Surface = c.SDL_RenderReadPixels(self.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(pixels);
        var lit: usize = 0;
        var x = start;
        while (x < end) : (x += 1) {
            var y: c_int = 0;
            while (y < 40) : (y += 1) {
                var r: u8 = 0;
                var g: u8 = 0;
                var b: u8 = 0;
                var a: u8 = 0;
                if (!c.SDL_ReadSurfacePixel(pixels, x, y, &r, &g, &b, &a)) return error.ReadPixel;
                if (r != 0 or g != 0 or b != 0) {
                    lit += 1;
                    break;
                }
            }
        }
        return lit;
    }
};

test "fitted labels stay inside an enclosing clip and restore it" {
    const canvas = try TestCanvas.init();
    defer canvas.deinit();
    var cache: LabelCache = .{};
    defer cache.deinit();
    const parent = c.SDL_Rect{ .x = 10, .y = 0, .w = 60, .h = 40 };
    try std.testing.expect(c.SDL_SetRenderDrawColor(canvas.renderer, 0, 0, 0, 255));
    try std.testing.expect(c.SDL_RenderClear(canvas.renderer));
    try std.testing.expect(c.SDL_SetRenderClipRect(canvas.renderer, &parent));
    const white = Color{ .r = 255, .g = 255, .b = 255 };
    const label = "Wide label that must be truncated";
    try std.testing.expect(try cache.width(canvas.text, label, 13) > 120);
    try cache.drawFitted(canvas.renderer, canvas.text, label, 0, 4, 120, 13, white);
    try canvas.expectClip(parent);
    try std.testing.expectEqual(@as(usize, 0), try canvas.litColumns(0, parent.x));
    try std.testing.expectEqual(@as(usize, 0), try canvas.litColumns(parent.x + parent.w, 200));
    try std.testing.expect(try canvas.litColumns(parent.x, parent.x + parent.w) > 0);
}

test "fitted labels restore an enclosing clip when drawing fails" {
    const canvas = try TestCanvas.init();
    defer canvas.deinit();
    const other = c.spica_text_create(canvas.renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(other);
    var cache: LabelCache = .{};
    defer cache.deinit();
    const parent = c.SDL_Rect{ .x = 10, .y = 0, .w = 60, .h = 40 };
    try std.testing.expect(c.SDL_SetRenderClipRect(canvas.renderer, &parent));
    const label = "Wide label that must be truncated";
    _ = try cache.width(canvas.text, label, 13);
    try std.testing.expectError(error.LabelDraw, cache.drawFitted(canvas.renderer, other, label, 0, 4, 120, 13, .{ .r = 255, .g = 255, .b = 255 }));
    try canvas.expectClip(parent);
}

test "fitted labels bound long workspace and model identities at UTF8 boundaries" {
    const canvas = try TestCanvas.init();
    defer canvas.deinit();
    var cache: LabelCache = .{};
    defer cache.deinit();
    // The euro sign straddles the cache byte limit, as a path/model may do.
    const label = "/" ++ "a" ** (max_bytes - 2) ++ "€" ++ "/isolated-workspace • complete-thread-identity";
    try std.testing.expect(label.len > max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expect(c.SDL_SetRenderDrawColor(canvas.renderer, 0, 0, 0, 255));
    try std.testing.expect(c.SDL_RenderClear(canvas.renderer));
    const parent = c.SDL_Rect{ .x = 10, .y = 0, .w = 150, .h = 40 };
    try std.testing.expect(c.SDL_SetRenderClipRect(canvas.renderer, &parent));
    try cache.drawFitted(canvas.renderer, canvas.text, label, 10, 4, 150, 13, .{ .r = 255, .g = 255, .b = 255 });
    try canvas.expectClip(parent);
    var found_prefix = false;
    var found_ellipsis = false;
    for (cache.entries) |entry| if (entry.layout != null) {
        try std.testing.expect(entry.len <= max_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(entry.bytes[0..entry.len]));
        if (std.mem.eql(u8, entry.bytes[0..entry.len], label[0 .. max_bytes - 1])) found_prefix = true;
        if (std.mem.eql(u8, entry.bytes[0..entry.len], "…")) found_ellipsis = true;
    };
    try std.testing.expect(found_prefix and found_ellipsis);
    try std.testing.expect(try canvas.litColumns(10, 160) > 0);
    try std.testing.expectEqual(@as(usize, 0), try canvas.litColumns(160, 200));
    // Direct cache admission stays strict; its fixed budget is unchanged.
    try std.testing.expectError(error.LabelTooLong, cache.layoutFor(canvas.text, label, 13));
    try std.testing.expect(std.mem.endsWith(u8, label, "complete-thread-identity"));
}
