const std = @import("std");
const c = @cImport({ @cInclude("text.h"); });

const Fixture = struct {
    surface: *c.SDL_Surface,
    renderer: *c.SDL_Renderer,
    engine: *c.SpicaText,

    fn init() !Fixture {
        const surface = c.SDL_CreateSurface(1024, 160, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
        errdefer c.SDL_DestroySurface(surface);
        const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
        errdefer c.SDL_DestroyRenderer(renderer);
        const engine = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.Font;
        return .{ .surface = surface, .renderer = renderer, .engine = engine };
    }
    fn deinit(self: Fixture) void {
        c.spica_text_destroy(self.engine);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroySurface(self.surface);
    }
    fn clear(self: Fixture) !void {
        try std.testing.expect(c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255));
        try std.testing.expect(c.SDL_RenderClear(self.renderer));
    }
};

const white = c.SDL_Color{ .r = 255, .g = 255, .b = 255, .a = 255 };

test "wrapped composer carets stay at grapheme boundaries and retain trailing blank line" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "a\u{301} bc def ghi\n";
    const layout = c.spica_text_layout_create(f.engine, source, source.len, 42, 16, false) orelse return error.Layout;
    defer c.spica_text_layout_release(layout);
    const count = c.spica_text_layout_line_count(layout);
    try std.testing.expect(count >= 3);
    var first: c.SpicaTextLine = undefined;
    var last: c.SpicaTextLine = undefined;
    try std.testing.expect(c.spica_text_layout_line(layout, 0, &first));
    try std.testing.expect(c.spica_text_layout_line(layout, count - 1, &last));
    try std.testing.expectEqual(@as(usize, 0), first.byte_start);
    try std.testing.expect(first.byte_end >= 3);
    try std.testing.expectEqual(source.len, last.byte_start);
    try std.testing.expectEqual(source.len, last.byte_end);
    var base: c.SDL_FRect = undefined;
    var inside: c.SDL_FRect = undefined;
    try std.testing.expect(c.spica_text_layout_caret(layout, 0, &base));
    try std.testing.expect(c.spica_text_layout_caret(layout, 1, &inside));
    try std.testing.expectEqual(base.x, inside.x);
    for (0..43) |x| {
        const byte = c.spica_text_layout_hit_test(layout, @floatFromInt(x), first.y + 1);
        try std.testing.expect(byte != 1 and byte != 2);
    }
    try std.testing.expectEqual(source.len, c.spica_text_layout_hit_test(layout, 0, last.y + 1));
}

test "bidi override makes visual caret order independent of logical byte order" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "\u{202e}abc\u{202c}";
    const layout = c.spica_text_layout_create(f.engine, source, source.len, 200, 18, false) orelse return error.Layout;
    defer c.spica_text_layout_release(layout);
    var a: c.SDL_FRect = undefined;
    var b: c.SDL_FRect = undefined;
    try std.testing.expect(c.spica_text_layout_caret(layout, 3, &a));
    try std.testing.expect(c.spica_text_layout_caret(layout, 4, &b));
    try std.testing.expect(a.x > b.x);
    try std.testing.expectEqual(@as(usize, 4), c.spica_text_layout_hit_test(layout, b.x, b.y + 1));
}

test "glyph cache eviction preserves an older retained layout's rendered pixels" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "Cache revisited";
    const retained = c.spica_text_layout_create(f.engine, source, source.len, 900, 16, false) orelse return error.Layout;
    defer c.spica_text_layout_release(retained);
    try f.clear();
    try std.testing.expect(c.spica_text_layout_draw(f.engine, retained, 5, 4, white));
    const before: *c.SDL_Surface = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(before);
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    for (8..65) |size| {
        const layout = c.spica_text_layout_create(f.engine, alphabet, alphabet.len, 900, @intCast(size), false) orelse return error.Layout;
        defer c.spica_text_layout_release(layout);
        try f.clear();
        try std.testing.expect(c.spica_text_layout_draw(f.engine, layout, 0, 0, white));
    }
    try f.clear();
    try std.testing.expect(c.spica_text_layout_draw(f.engine, retained, 5, 4, white));
    const after: *c.SDL_Surface = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(after);
    try std.testing.expectEqual(before.w, after.w);
    try std.testing.expectEqual(before.h, after.h);
    const lhs: [*]const u8 = @ptrCast(before.pixels orelse return error.Pixels);
    const rhs: [*]const u8 = @ptrCast(after.pixels orelse return error.Pixels);
    for (0..@as(usize, @intCast(before.h))) |row| {
        const a = row * @as(usize, @intCast(before.pitch));
        const b = row * @as(usize, @intCast(after.pitch));
        const bytes = @as(usize, @intCast(before.w)) * 4;
        try std.testing.expectEqualSlices(u8, lhs[a .. a + bytes], rhs[b .. b + bytes]);
    }
}
