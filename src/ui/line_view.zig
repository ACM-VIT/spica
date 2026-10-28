const std = @import("std");
const c = @import("../native/bindings.zig").c;
const LineEdit = @import("../text/line_edit.zig").LineEdit;
const widgets = @import("widgets.zig");
const Color = @import("color.zig").Color;

/// One retained native shape shared by mutually exclusive small text fields.
pub const LineView = struct {
    layout: ?*c.SpicaTextLayout = null,
    bytes: [320]u8 = undefined,
    len: usize = 0,
    scroll: f32 = 0,
    bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    preedit: [160]u8 = undefined,
    preedit_len: usize = 0,
    composition_at: usize = 0,
    composition_end: usize = 0,
    pub fn deinit(self: *LineView) void {
        if (self.layout) |layout| c.spica_text_layout_release(layout);
        self.layout = null;
    }
    pub fn compose(self: *LineView, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        if (bytes.len > self.preedit.len) return error.TextTooLarge;
        for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidTitle;
        @memcpy(self.preedit[0..bytes.len], bytes);
        self.preedit_len = bytes.len;
    }
    pub fn reset(self: *LineView) void {
        self.preedit_len = 0;
        self.scroll = 0;
    }
    fn mapped(self: *const LineView, at: usize) usize {
        return at + if (at >= self.composition_at) self.preedit_len else @as(usize, 0);
    }
    pub fn draw(self: *LineView, renderer: *c.SDL_Renderer, text: *c.SpicaText, bytes: []const u8, field: LineEdit, bounds: c.SDL_FRect, foreground: Color, selection: Color, active: bool) !void {
        if (bytes.len > 160) return error.TextTooLarge;
        self.bounds = bounds;
        if (bounds.w <= 0 or bounds.h <= 0) return;
        var combined: [320]u8 = undefined;
        const composing = if (active) self.preedit_len else 0;
        const selected = field.range();
        const insertion = @min(if (composing != 0) selected.start else field.caret, bytes.len);
        const suffix = if (composing != 0) @min(selected.end, bytes.len) else insertion;
        @memcpy(combined[0..insertion], bytes[0..insertion]);
        @memcpy(combined[insertion..][0..composing], self.preedit[0..composing]);
        @memcpy(combined[insertion + composing ..][0 .. bytes.len - suffix], bytes[suffix..]);
        const len = bytes.len - (suffix - insertion) + composing;
        if (self.layout == null or self.len != len or !std.mem.eql(u8, self.bytes[0..self.len], combined[0..len])) {
            const layout = c.spica_text_layout_create(text, &combined, len, 1000000, 14, false) orelse return error.LineLayout;
            if (self.layout) |previous| c.spica_text_layout_release(previous);
            self.layout = layout;
            self.len = len;
            @memcpy(self.bytes[0..len], combined[0..len]);
        }
        self.composition_at = insertion;
        self.composition_end = suffix;
        const layout = self.layout.?;
        var caret: c.SDL_FRect = undefined;
        const caret_at = insertion + composing;
        const has_caret = c.spica_text_layout_caret(layout, caret_at, &caret);
        if (active and has_caret) {
            if (caret.x < self.scroll) self.scroll = @max(0, caret.x - bounds.w / 2);
            if (caret.x + 2 > self.scroll + bounds.w) self.scroll = @max(0, caret.x + 2 - bounds.w);
        } else self.scroll = 0;
        var clip = widgets.Clip.push(renderer, bounds);
        defer clip.restore(renderer);
        const x = bounds.x - self.scroll;
        if (active and composing == 0) {
            const range = field.range();
            var rects: [160]c.SDL_FRect = undefined;
            const count = c.spica_text_layout_selection_rects(layout, self.mapped(range.start), self.mapped(range.end), &rects, rects.len);
            for (rects[0..@min(count, rects.len)]) |rect| try widgets.panel(renderer, .{ .x = x + rect.x, .y = bounds.y + rect.y, .w = rect.w, .h = rect.h }, 0, selection);
        }
        if (!c.spica_text_layout_draw(text, layout, x, bounds.y, widgets.rgba(foreground))) return error.LineDraw;
        if (active and has_caret) {
            try widgets.panel(renderer, .{ .x = x + caret.x, .y = bounds.y + caret.y, .w = 1, .h = caret.h }, 0, foreground);
            if (composing != 0) {
                var start: c.SDL_FRect = undefined;
                if (c.spica_text_layout_caret(layout, insertion, &start)) try widgets.panel(renderer, .{ .x = x + @min(start.x, caret.x), .y = bounds.y + caret.y + caret.h - 1, .w = @abs(caret.x - start.x), .h = 1 }, 0, foreground);
            }
        }
    }
    pub fn hit(self: *const LineView, x: f32, y: f32) ?usize {
        const layout = self.layout orelse return null;
        const at = c.spica_text_layout_hit_test(layout, x - self.bounds.x + self.scroll, y - self.bounds.y);
        if (at <= self.composition_at) return at;
        return at - @min(at - self.composition_at, self.preedit_len) + (self.composition_end - self.composition_at);
    }
};

test "single line shapes full Unicode titles once and scrolls selection caret" {
    const surface = c.SDL_CreateSurface(180, 80, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var line: LineView = .{};
    defer line.deinit();
    var edit: LineEdit = .{};
    const value = "🎮" ** 40;
    edit.sync(value.len, true);
    const bounds: c.SDL_FRect = .{ .x = 4, .y = 4, .w = 65, .h = 24 };
    const fg: Color = .{ .r = 255, .g = 255, .b = 255 };
    const selected_color: Color = .{ .r = 210, .g = 20, .b = 30 };
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);
    try line.draw(renderer, text, value, edit, bounds, fg, selected_color, true);
    _ = c.SDL_RenderPresent(renderer);
    var painted_selection: usize = 0;
    for (0..80) |y| for (0..180) |x| {
        var rgba: [4]u8 = undefined;
        try std.testing.expect(c.SDL_ReadSurfacePixel(surface, @intCast(x), @intCast(y), &rgba[0], &rgba[1], &rgba[2], &rgba[3]));
        if (rgba[0] == selected_color.r and rgba[1] == selected_color.g and rgba[2] == selected_color.b) {
            painted_selection += 1;
            try std.testing.expect(x >= 4 and x < 69 and y >= 4 and y < 28);
        }
    };
    try std.testing.expect(painted_selection > 0);
    try std.testing.expect(line.scroll > 0);
    try std.testing.expectEqual(@as(usize, 160), line.len);
    const retained = line.layout.?;
    try line.draw(renderer, text, value, edit, bounds, fg, fg, true);
    try std.testing.expectEqual(retained, line.layout.?);
    try std.testing.expectEqual(value.len, line.hit(bounds.x + bounds.w, bounds.y + 4).?);
    edit.set(0, false);
    try line.compose("e\u{301}");
    try line.draw(renderer, text, value, edit, bounds, fg, fg, true);
    try std.testing.expectEqual(@as(f32, 0), line.scroll);
    try std.testing.expectEqual(@as(usize, 163), line.len);
    try std.testing.expectError(error.TextTooLarge, line.compose("x" ** 161));
    try std.testing.expectEqual(@as(usize, 3), line.preedit_len);
    line.reset();
    const bidi = "a אבג z";
    edit.set(2, false);
    edit.set(8, true);
    try line.draw(renderer, text, bidi, edit, bounds, fg, selected_color, true);
    var rects: [8]c.SDL_FRect = undefined;
    try std.testing.expect(c.spica_text_layout_selection_rects(line.layout.?, 2, 8, &rects, rects.len) > 0);
    try line.compose("日本");
    try line.draw(renderer, text, bidi, edit, bounds, fg, selected_color, true);
    try std.testing.expectEqualStrings("a 日本 z", line.bytes[0..line.len]);
}
