const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cInclude("text.h");
});

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

fn expectSamePixels(a: *c.SDL_Surface, b: *c.SDL_Surface) !void {
    try std.testing.expectEqual(a.w, b.w);
    try std.testing.expectEqual(a.h, b.h);
    const lhs: [*]const u8 = @ptrCast(a.pixels orelse return error.Pixels);
    const rhs: [*]const u8 = @ptrCast(b.pixels orelse return error.Pixels);
    for (0..@as(usize, @intCast(a.h))) |row| {
        const start_a = row * @as(usize, @intCast(a.pitch));
        const start_b = row * @as(usize, @intCast(b.pitch));
        const bytes = @as(usize, @intCast(a.w)) * 4;
        try std.testing.expectEqualSlices(u8, lhs[start_a .. start_a + bytes], rhs[start_b .. start_b + bytes]);
    }
}

test "DPR transitions rebuild raster pixels without changing wrapping or logical carets" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "office a\u{301} xyz\nmore";
    const retained = c.spica_text_layout_create(f.engine, source, source.len, 90, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(retained);
    try f.clear();
    try std.testing.expect(c.spica_text_layout_draw(f.engine, retained, 5, 4, white));
    const original = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(original);
    for ([_]f32{ 1.5, 2, 1 }) |scale| {
        try std.testing.expect(c.SDL_SetRenderScale(f.renderer, scale, scale));
        try std.testing.expect(c.spica_text_set_render_scale(f.engine, scale, scale));
        var stats: c.SpicaTextStats = undefined;
        try std.testing.expect(c.spica_text_get_stats(f.engine, &stats));
        try std.testing.expectEqual(@as(usize, 0), stats.glyph_bytes);
        const fresh = c.spica_text_layout_create(f.engine, source, source.len, 90, 15, false) orelse return error.Layout;
        defer c.spica_text_layout_release(fresh);
        const count = c.spica_text_layout_line_count(retained);
        try std.testing.expectEqual(count, c.spica_text_layout_line_count(fresh));
        for (0..count) |index| {
            var before: c.SpicaTextLine = undefined;
            var after: c.SpicaTextLine = undefined;
            try std.testing.expect(c.spica_text_layout_line(retained, index, &before));
            try std.testing.expect(c.spica_text_layout_line(fresh, index, &after));
            try std.testing.expectEqual(before.byte_start, after.byte_start);
            try std.testing.expectEqual(before.byte_end, after.byte_end);
            try std.testing.expectEqual(before.width, after.width);
            try std.testing.expectEqual(before.y, after.y);
            try std.testing.expectEqual(before.height, after.height);
        }
        for (0..source.len + 1) |byte| {
            var before: c.SDL_FRect = undefined;
            var after: c.SDL_FRect = undefined;
            try std.testing.expect(c.spica_text_layout_caret(retained, byte, &before));
            try std.testing.expect(c.spica_text_layout_caret(fresh, byte, &after));
            try std.testing.expectEqual(before.x, after.x);
            try std.testing.expectEqual(before.y, after.y);
            try std.testing.expectEqual(before.h, after.h);
        }
        try f.clear();
        try std.testing.expect(c.spica_text_layout_draw(f.engine, retained, 5, 4, white));
        const old_pixels = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(old_pixels);
        try f.clear();
        try std.testing.expect(c.spica_text_layout_draw(f.engine, fresh, 5, 4, white));
        const new_pixels = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(new_pixels);
        try expectSamePixels(old_pixels, new_pixels);
        if (scale == 1) try expectSamePixels(original, old_pixels);
    }
}

test "bitmap color ZWJ emoji and adjacent flag have distinct logical advances" {
    const f = try Fixture.init();
    defer f.deinit();
    if (builtin.os.tag != .macos) {
        const font = "/usr/share/fonts/noto/NotoColorEmoji.ttf";
        const io = c.SDL_IOFromFile(font, "rb") orelse return error.SkipZigTest;
        _ = c.SDL_CloseIO(io);
        try std.testing.expect(c.spica_text_add_fallback(f.engine, font, 0));
    }
    const woman = "👩‍💻";
    const flag = "🇮🇳";
    const source = woman ++ flag;
    const first = c.spica_text_layout_create(f.engine, woman, woman.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(first);
    const second = c.spica_text_layout_create(f.engine, flag, flag.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(second);
    const joined = c.spica_text_layout_create(f.engine, source, source.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(joined);
    var a: c.SpicaTextLine = undefined;
    var b: c.SpicaTextLine = undefined;
    var together: c.SpicaTextLine = undefined;
    try std.testing.expect(c.spica_text_layout_line(first, 0, &a));
    try std.testing.expect(c.spica_text_layout_line(second, 0, &b));
    try std.testing.expect(c.spica_text_layout_line(joined, 0, &together));
    try std.testing.expect(a.width > 7.5 and a.width < 30);
    try std.testing.expect(b.width > 7.5 and b.width < 30);
    try std.testing.expectApproxEqAbs(a.width + b.width, together.width, 1.0 / 64.0);
    var middle: c.SDL_FRect = undefined;
    var end: c.SDL_FRect = undefined;
    var inside: c.SDL_FRect = undefined;
    try std.testing.expect(c.spica_text_layout_caret(joined, woman.len, &middle));
    try std.testing.expect(c.spica_text_layout_caret(joined, source.len, &end));
    try std.testing.expect(c.spica_text_layout_caret(joined, 7, &inside));
    try std.testing.expectEqual(@as(f32, 0), inside.x);
    try std.testing.expectApproxEqAbs(a.width, middle.x, 1.0 / 64.0);
    try std.testing.expectApproxEqAbs(b.width, end.x - middle.x, 1.0 / 64.0);
    try std.testing.expectEqual(woman.len, c.spica_text_layout_hit_test(joined, middle.x, 1));
    for ([_]f32{ 1, 1.5, 2 }) |scale| {
        try std.testing.expect(c.SDL_SetRenderScale(f.renderer, scale, scale));
        try std.testing.expect(c.spica_text_set_render_scale(f.engine, scale, scale));
        try f.clear();
        try std.testing.expect(c.spica_text_layout_draw(f.engine, joined, 5, 4, white));
        const adjacent = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(adjacent);
        try f.clear();
        try std.testing.expect(c.spica_text_layout_draw(f.engine, first, 5, 4, white));
        try std.testing.expect(c.spica_text_layout_draw(f.engine, second, 5 + a.width, 4, white));
        const separate = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(separate);
        try expectSamePixels(adjacent, separate);
    }
}

test "macOS CoreText cascade renders CJK and preserves color emoji in styled spans" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    // No registered system fallback: both scripts must go through the CoreText cascade.
    const cjk = "漢字";
    const cjk_layout = c.spica_text_layout_create(f.engine, cjk, cjk.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(cjk_layout);
    try f.clear();
    try std.testing.expect(c.spica_text_layout_draw(f.engine, cjk_layout, 5, 4, white));
    var cjk_line: c.SpicaTextLine = undefined;
    try std.testing.expect(c.spica_text_layout_line(cjk_layout, 0, &cjk_line));
    try std.testing.expect(cjk_line.width > 0);

    const emoji = "👩‍💻🇮🇳";
    const plain = c.spica_text_layout_create(f.engine, emoji, emoji.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(plain);
    var baseline: c.SpicaTextLine = undefined;
    try std.testing.expect(c.spica_text_layout_line(plain, 0, &baseline));
    try f.clear();
    try std.testing.expect(c.spica_text_layout_draw(f.engine, plain, 5, 4, white));
    const pixels = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(pixels);
    var colored = false;
    for (0..50) |y| {
        for (0..80) |x| {
            var r: u8 = 0;
            var g: u8 = 0;
            var b: u8 = 0;
            var a: u8 = 0;
            try std.testing.expect(c.SDL_ReadSurfacePixel(pixels, @intCast(x), @intCast(y), &r, &g, &b, &a));
            colored = colored or (a != 0 and (r != g or g != b));
        }
    }
    try std.testing.expect(colored);
    for ([_]c_uint{ c.SPICA_TEXT_BOLD, c.SPICA_TEXT_ITALIC, c.SPICA_TEXT_BOLD | c.SPICA_TEXT_ITALIC }) |style| {
        const span = c.SpicaTextSpan{ .byte_start = 0, .byte_end = emoji.len, .style = style };
        const styled = c.spica_text_layout_create_spans(f.engine, emoji, emoji.len, 200, 15, false, &span, 1) orelse return error.Layout;
        defer c.spica_text_layout_release(styled);
        var line: c.SpicaTextLine = undefined;
        try std.testing.expect(c.spica_text_layout_line(styled, 0, &line));
        try std.testing.expectEqual(baseline.width, line.width);
        try f.clear();
        try std.testing.expect(c.spica_text_layout_draw(f.engine, styled, 5, 4, white));
        const rendered = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(rendered);
        try expectSamePixels(pixels, rendered);
    }
}

test "selection geometry keeps bidi gaps and respects output capacity" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "ab\u{202e}CD\u{202c}ef";
    const layout = c.spica_text_layout_create(f.engine, source, source.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(layout);
    var rects: [2]c.SDL_FRect = undefined;
    try std.testing.expectEqual(@as(usize, 2), c.spica_text_layout_selection_rects(layout, 1, 6, &rects, rects.len));
    try std.testing.expect(rects[0].w > 0 and rects[1].w > 0);
    try std.testing.expect(rects[0].x + rects[0].w < rects[1].x);
    try std.testing.expectEqual(@as(usize, 2), c.spica_text_layout_selection_rects(layout, 1, 6, null, 0));
    var bounded = [_]c.SDL_FRect{ rects[1], .{ .x = -1, .y = -1, .w = -1, .h = -1 } };
    try std.testing.expectEqual(@as(usize, 2), c.spica_text_layout_selection_rects(layout, 1, 6, &bounded, 1));
    try std.testing.expectEqual(rects[0].x, bounded[0].x);
    try std.testing.expectEqual(rects[0].w, bounded[0].w);
    try std.testing.expectEqual(@as(f32, -1), bounded[1].x);
    try std.testing.expectEqual(@as(f32, -1), bounded[1].w);
    try std.testing.expect(c.spica_text_set_render_scale(f.engine, 1.5, 1.5));
    var scaled: [2]c.SDL_FRect = undefined;
    try std.testing.expectEqual(@as(usize, 2), c.spica_text_layout_selection_rects(layout, 1, 6, &scaled, scaled.len));
    for (rects, scaled) |a, b| {
        try std.testing.expectEqual(a.x, b.x);
        try std.testing.expectEqual(a.y, b.y);
        try std.testing.expectEqual(a.w, b.w);
        try std.testing.expectEqual(a.h, b.h);
    }
}

test "selection uses grapheme ligature carets and includes tab advance" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "office a\u{301}\tb";
    const layout = c.spica_text_layout_create(f.engine, source, source.len, 200, 15, false) orelse return error.Layout;
    defer c.spica_text_layout_release(layout);
    var rect: c.SDL_FRect = undefined;
    var begin: c.SDL_FRect = undefined;
    var end: c.SDL_FRect = undefined;
    try std.testing.expect(c.spica_text_layout_caret(layout, 2, &begin));
    try std.testing.expect(c.spica_text_layout_caret(layout, 3, &end));
    try std.testing.expectEqual(@as(usize, 1), c.spica_text_layout_selection_rects(layout, 2, 3, &rect, 1));
    try std.testing.expectEqual(begin.x, rect.x);
    try std.testing.expectEqual(end.x - begin.x, rect.w);
    try std.testing.expect(c.spica_text_layout_caret(layout, 7, &begin));
    try std.testing.expect(c.spica_text_layout_caret(layout, 10, &end));
    try std.testing.expectEqual(@as(usize, 1), c.spica_text_layout_selection_rects(layout, 8, 9, &rect, 1));
    try std.testing.expectEqual(begin.x, rect.x);
    try std.testing.expectEqual(end.x - begin.x, rect.w);
    try std.testing.expect(c.spica_text_layout_caret(layout, 10, &begin));
    try std.testing.expect(c.spica_text_layout_caret(layout, 11, &end));
    try std.testing.expectEqual(@as(usize, 1), c.spica_text_layout_selection_rects(layout, 10, 11, &rect, 1));
    try std.testing.expectEqual(begin.x, rect.x);
    try std.testing.expectEqual(end.x - begin.x, rect.w);
    try std.testing.expectEqual(@as(usize, 0), c.spica_text_layout_selection_rects(layout, 2, 2, &rect, 1));
}

test "fractional zoom keeps repeated glyph ink aligned with logical advances" {
    const f = try Fixture.init();
    defer f.deinit();
    const source = "iiiiiiii";
    const layout = c.spica_text_layout_create(f.engine, source, source.len, 200, 13, false) orelse return error.Layout;
    defer c.spica_text_layout_release(layout);
    for ([_]f32{ 1.2, 1.35, 1.5 }) |scale| {
        try std.testing.expect(c.SDL_SetRenderScale(f.renderer, scale, scale));
        try std.testing.expect(c.spica_text_set_render_scale(f.engine, scale, scale));
        try f.clear();
        const origin: f32 = 5.1;
        try std.testing.expect(c.spica_text_layout_draw(f.engine, layout, origin, 4, white));
        const surface: *c.SDL_Surface = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(surface);
        const bytes: [*]const u8 = @ptrCast(surface.pixels orelse return error.Pixels);
        var first_center: f32 = 0;
        var first_caret: f32 = 0;
        for (0..source.len) |index| {
            var start: c.SDL_FRect = undefined;
            var end: c.SDL_FRect = undefined;
            try std.testing.expect(c.spica_text_layout_caret(layout, index, &start));
            try std.testing.expect(c.spica_text_layout_caret(layout, index + 1, &end));
            const left: usize = @intFromFloat(@floor((origin + start.x) * scale));
            const right: usize = @intFromFloat(@floor((origin + end.x) * scale));
            var mass: f32 = 0;
            var moment: f32 = 0;
            for (0..@as(usize, @intCast(surface.h))) |row| {
                for (left..right) |column| {
                    const pixel: *align(1) const u32 = @ptrCast(bytes + row * @as(usize, @intCast(surface.pitch)) + column * 4);
                    var red: u8 = 0;
                    c.SDL_GetRGBA(pixel.*, c.SDL_GetPixelFormatDetails(surface.format), null, &red, null, null, null);
                    mass += @floatFromInt(red);
                    moment += (@as(f32, @floatFromInt(column)) + 0.5) * @as(f32, @floatFromInt(red));
                }
            }
            try std.testing.expect(mass > 0);
            const center = moment / mass;
            if (index == 0) {
                first_center = center;
                first_caret = start.x;
            } else try std.testing.expectApproxEqAbs((start.x - first_caret) * scale, center - first_center, 0.45);
        }
    }
}

test "scaled text respects clip edges and following widget placement" {
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expect(c.SDL_SetRenderLogicalPresentation(f.renderer, 512, 80, c.SDL_LOGICAL_PRESENTATION_STRETCH));
    try std.testing.expect(c.SDL_SetRenderScale(f.renderer, 1.2, 1.2));
    try std.testing.expect(c.spica_text_set_render_scale(f.engine, 2.4, 2.4));
    const viewport = c.SDL_Rect{ .x = 17, .y = 7, .w = 80, .h = 50 };
    const clip = c.SDL_Rect{ .x = 6, .y = 3, .w = 14, .h = 18 };
    try std.testing.expect(c.SDL_SetRenderViewport(f.renderer, &viewport));
    try std.testing.expect(c.SDL_SetRenderClipRect(f.renderer, &clip));
    const panel = c.SDL_FRect{ .x = 0, .y = 0, .w = 80, .h = 50 };
    try f.clear();
    try std.testing.expect(c.SDL_SetRenderDrawColor(f.renderer, 255, 0, 0, 255));
    try std.testing.expect(c.SDL_RenderFillRect(f.renderer, &panel));
    const expected: *c.SDL_Surface = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(expected);
    try f.clear();
    const source = "iiiiiiii";
    const layout = c.spica_text_layout_create(f.engine, source, source.len, 100, 13, false) orelse return error.Layout;
    defer c.spica_text_layout_release(layout);
    try std.testing.expect(c.spica_text_layout_draw(f.engine, layout, -5, 1, white));
    try std.testing.expect(c.SDL_SetRenderDrawColor(f.renderer, 255, 0, 0, 255));
    try std.testing.expect(c.SDL_RenderFillRect(f.renderer, &panel));
    const actual: *c.SDL_Surface = c.SDL_RenderReadPixels(f.renderer, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(actual);
    try expectSamePixels(expected, actual);
}
