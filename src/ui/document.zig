const std = @import("std");
const c = @import("../native/bindings.zig").c;
const md = @import("../content/markdown.zig");
const Theme = @import("theme.zig");
const Highlight = @import("../content/worker.zig").Highlight;
const Edit = @import("../text/edit.zig");
pub const Range = struct { start: usize, end: usize };

const Box = struct {
    block: u32,
    text_start: u32,
    text_end: u32,
    first: bool,
    last: bool,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    layout: ?*c.SpicaTextLayout = null,
};

// Compact block metadata stays resident while offscreen text shapes are released.
pub const View = struct {
    allocator: std.mem.Allocator,
    boxes: std.ArrayList(Box) = .empty,
    color_scratch: std.ArrayList(c.SpicaTextColorSpan) = .empty,
    selection_scratch: std.ArrayList(c.SDL_FRect) = .empty,
    selection: ?Range = null,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) View {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *View) void {
        self.clear();
        self.boxes.deinit(self.allocator);
        self.color_scratch.deinit(self.allocator);
        self.selection_scratch.deinit(self.allocator);
    }
    pub fn clear(self: *View) void {
        for (self.boxes.items) |box| if (box.layout) |layout| c.spica_text_layout_release(layout);
        self.boxes.clearRetainingCapacity();
        self.width = 0;
        self.height = 0;
    }
    pub fn rebuild(self: *View, document: *const md.Document, width: f32) !void {
        self.clear();
        self.width = width;
        for (document.blocks.items, 0..) |block, index| {
            switch (block.kind) {
                .paragraph, .heading, .code, .html, .rule, .table_cell => {},
                else => continue,
            }
            var start: usize = block.text_start;
            if (start == block.text_end) try self.appendSegment(document, block, index, start, start);
            while (start < block.text_end) {
                const end = segmentEnd(document.text.items, start, block.text_end);
                try self.appendSegment(document, block, index, start, end);
                start = end;
            }
        }
        self.reflow(document);
    }

    fn segmentEnd(text: []const u8, start: usize, limit: usize) usize {
        var end = start;
        var points: usize = 0;
        var line_end = start;
        var word_end = start;
        while (end < limit and points < 4096) : (points += 1) {
            const bytes = std.unicode.utf8ByteSequenceLength(text[end]) catch unreachable;
            if (end + bytes - start > 32768) break;
            if (Edit.whitespaceAt(text, end)) word_end = end + bytes;
            if (text[end] == '\n') line_end = end + bytes;
            end += bytes;
        }
        if (end == limit) return end;
        if (line_end > start) return line_end;
        if (word_end > start) return word_end;
        var breaks: [32768]u8 = undefined;
        const boundary = Edit.beforeLastGrapheme(text[start..end], &breaks) catch unreachable;
        // A single cluster can itself exceed the native layout's fixed bound.
        // Preserve every scalar even when such a cluster must be split.
        return if (boundary != 0) start + boundary else end;
    }

    fn appendSegment(self: *View, document: *const md.Document, block: md.Block, index: usize, start: usize, end: usize) !void {
        const indent = indentation(document, block);
        const available = @max(32, self.width - indent);
        var bytes = document.text.items[start..end];
        if (std.mem.endsWith(u8, bytes, "\n")) bytes = bytes[0 .. bytes.len - 1];
        var lines: usize = 1;
        for (bytes) |byte| if (byte == '\n') {
            lines += 1;
        };
        const estimate = @max(lines, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(bytes.len)) * 7.2 / available))));
        const first = start == block.text_start;
        const last = end == block.text_end;
        const mono = block.kind == .code or block.kind == .html;
        const padding: f32 = if (mono) (if (first) @as(f32, 12) else 0) + (if (last) @as(f32, 12) else 0) else if (last) 12 else 0;
        try self.boxes.append(self.allocator, .{
            .block = @intCast(index),
            .text_start = @intCast(start),
            .text_end = @intCast(end),
            .first = first,
            .last = last,
            .x = indent,
            .width = available,
            .height = @as(f32, @floatFromInt(estimate)) * 22 + padding,
        });
    }

    fn indentation(document: *const md.Document, block: md.Block) f32 {
        var parent = block.parent;
        var indent: f32 = 0;
        while (parent) |index| {
            const ancestor = document.blocks.items[index];
            if (ancestor.kind == .item or ancestor.kind == .quote) indent += 20;
            parent = ancestor.parent;
        }
        return indent;
    }

    fn reflow(self: *View, document: *const md.Document) void {
        var y: f32 = 0;
        var index: usize = 0;
        while (index < self.boxes.items.len) {
            const block = document.blocks.items[self.boxes.items[index].block];
            if (block.kind == .table_cell) {
                const row = block.parent.?;
                var end = index;
                var columns: usize = 0;
                var height: f32 = 0;
                while (end < self.boxes.items.len and document.blocks.items[self.boxes.items[end].block].parent == row) {
                    const cell = self.boxes.items[end].block;
                    var cell_height: f32 = 0;
                    while (end < self.boxes.items.len and self.boxes.items[end].block == cell) : (end += 1) cell_height += self.boxes.items[end].height;
                    height = @max(height, cell_height);
                    columns += 1;
                }
                const column_count: f32 = @floatFromInt(columns);
                var at = index;
                for (0..columns) |column| {
                    const cell = self.boxes.items[at].block;
                    var cell_y = y;
                    while (at < end and self.boxes.items[at].block == cell) : (at += 1) {
                        const box = &self.boxes.items[at];
                        box.x = @as(f32, @floatFromInt(column)) * self.width / column_count;
                        box.width = self.width / column_count - 16;
                        box.y = cell_y;
                        cell_y += box.height;
                    }
                }
                y += height;
                index = end;
            } else {
                self.boxes.items[index].y = y;
                y += self.boxes.items[index].height;
                index += 1;
            }
        }
        self.height = y;
    }

    pub fn releaseShapes(self: *View) void {
        for (self.boxes.items) |*box| {
            if (box.layout) |layout| c.spica_text_layout_release(layout);
            box.layout = null;
        }
    }

    /// A transcript supplies the unclamped local viewport, including negative
    /// offsets when a message starts partway down the visible conversation.
    pub fn prepareRegion(self: *View, engine: *c.SpicaText, document: *const md.Document, scroll: f32, viewport_height: f32, metrics: Theme.Metrics) !void {
        for (0..self.boxes.items.len + 2) |_| {
            if (!try self.shapeVisible(engine, document, scroll, viewport_height, metrics)) return;
        }
        return error.UnstableTextReflow;
    }

    fn shapeVisible(self: *View, engine: *c.SpicaText, document: *const md.Document, scroll: f32, viewport_height: f32, metrics: Theme.Metrics) !bool {
        // Table widths are derived before shaping. Reflow once after new line
        // heights arrive; a warm scroll over retained visible lines does no work.
        var changed = false;
        for (self.boxes.items) |*box| {
            const visible = box.y + box.height >= scroll - 40 and box.y <= scroll + viewport_height + 40;
            if (!visible) {
                if (box.layout) |layout| {
                    c.spica_text_layout_release(layout);
                    box.layout = null;
                }
            }
        }
        // Free every offscreen segment before allocating newly visible ones.
        for (self.boxes.items) |*box| {
            if (box.y + box.height < scroll - 40 or box.y > scroll + viewport_height + 40) continue;
            if (box.layout != null) continue;
            const block = document.blocks.items[box.block];
            const mono = block.kind == .code or block.kind == .html;
            const size: c_uint = @intFromFloat(if (block.kind == .heading) @max(metrics.body_px, 27 - @as(f32, @floatFromInt(block.heading_level)) * 2) else if (mono) metrics.code_px else metrics.body_px);
            var text = document.text.items[box.text_start..box.text_end];
            if (std.mem.endsWith(u8, text, "\n")) text = text[0 .. text.len - 1];
            var spans: std.ArrayList(c.SpicaTextSpan) = .empty;
            defer spans.deinit(self.allocator);
            for (document.runs.items[block.first_run..block.end_run]) |run| {
                const style: c_uint = (if (run.strong) @as(c_uint, c.SPICA_TEXT_BOLD) else 0) |
                    (if (run.emphasis) @as(c_uint, c.SPICA_TEXT_ITALIC) else 0) |
                    (if (run.kind == .code) @as(c_uint, c.SPICA_TEXT_MONOSPACE) else 0);
                const end = @min(run.end, box.text_start + text.len);
                const start = @min(@max(run.start, box.text_start), end);
                if (style != 0 and start != end) try spans.append(self.allocator, .{ .byte_start = start - box.text_start, .byte_end = end - box.text_start, .style = style });
            }
            const layout = c.spica_text_layout_create_spans(engine, text.ptr, text.len, @max(16, box.width - (if (mono) @as(f32, 24) else 0)), size, mono, spans.items.ptr, spans.items.len) orelse {
                std.log.err("text layout: {s}", .{c.SDL_GetError()});
                return error.TextLayout;
            };
            box.layout = layout;
            const padding: f32 = if (mono) (if (box.first) @as(f32, 12) else 0) + (if (box.last) @as(f32, 12) else 0) else if (box.last) 12 else 0;
            const height = c.spica_text_layout_height(layout) + padding;
            changed = changed or box.height != height;
            box.height = height;
        }
        if (changed) self.reflow(document);
        return changed;
    }

    fn textOrigin(box: Box, document: *const md.Document) struct { x: f32, y: f32 } {
        const kind = document.blocks.items[box.block].kind;
        const mono = kind == .code or kind == .html;
        return .{ .x = box.x + (if (mono) @as(f32, 12) else 0), .y = box.y + (if (mono) (if (box.first) @as(f32, 12) else 0) else 4) };
    }

    /// Only inspect retained shapes; selecting never shapes offscreen history.
    pub fn hitText(self: *const View, document: *const md.Document, x: f32, y: f32) ?usize {
        var nearest: ?usize = null;
        var distance: f32 = std.math.inf(f32);
        for (self.boxes.items) |box| {
            const layout = box.layout orelse continue;
            const origin = textOrigin(box, document);
            const dy = @max(0, @max(origin.y - y, y - origin.y - c.spica_text_layout_height(layout)));
            const dx = @max(0, @max(box.x - x, x - box.x - box.width));
            const d = dy * dy + dx * dx;
            if (d < distance) {
                distance = d;
                nearest = box.text_start + c.spica_text_layout_hit_test(layout, x - origin.x, y - origin.y);
            }
        }
        return nearest;
    }

    pub fn caretRect(self: *const View, document: *const md.Document, offset: usize) ?c.SDL_FRect {
        for (self.boxes.items) |box| {
            if (offset < box.text_start or offset > box.text_end or (offset == box.text_end and offset != document.text.items.len)) continue;
            const layout = box.layout orelse continue;
            var rect: c.SDL_FRect = undefined;
            const end = box.text_end - @as(u32, if (box.text_end > box.text_start and document.text.items[box.text_end - 1] == '\n') 1 else 0);
            if (!c.spica_text_layout_caret(layout, @min(offset, end) - box.text_start, &rect)) continue;
            const origin = textOrigin(box, document);
            rect.x += origin.x;
            rect.y += origin.y;
            return rect;
        }
        return null;
    }

    pub fn offsetY(self: *const View, document: *const md.Document, offset: usize) f32 {
        if (self.caretRect(document, offset)) |rect| return rect.y;
        for (self.boxes.items) |box| {
            if (offset >= box.text_start and offset <= box.text_end) return box.y;
        }
        return 0;
    }

    pub fn lineEdge(self: *const View, document: *const md.Document, offset: usize, end: bool) usize {
        const caret = self.caretRect(document, offset) orelse return offset;
        for (self.boxes.items) |box| {
            if (offset < box.text_start or offset > box.text_end) continue;
            const layout = box.layout orelse continue;
            const origin = textOrigin(box, document);
            if (caret.y < origin.y or caret.y >= origin.y + c.spica_text_layout_height(layout)) continue;
            return box.text_start + c.spica_text_layout_hit_test(layout, if (end) 1000000 else 0, caret.y - origin.y + caret.h / 2);
        }
        return offset;
    }

    pub fn moveVertical(self: *const View, document: *const md.Document, offset: usize, x: f32, down: bool) usize {
        const caret = self.caretRect(document, offset) orelse return offset;
        for (self.boxes.items, 0..) |box, index| {
            if (offset < box.text_start or offset > box.text_end) continue;
            const layout = box.layout orelse continue;
            const origin = textOrigin(box, document);
            const line_count = c.spica_text_layout_line_count(layout);
            for (0..line_count) |line_index| {
                var line: c.SpicaTextLine = undefined;
                if (!c.spica_text_layout_line(layout, line_index, &line)) continue;
                if (@abs(line.y + origin.y - caret.y) > 0.5) continue;
                if ((down and line_index + 1 < line_count) or (!down and line_index > 0)) {
                    _ = c.spica_text_layout_line(layout, if (down) line_index + 1 else line_index - 1, &line);
                    return box.text_start + c.spica_text_layout_hit_test(layout, x - origin.x, line.y + line.height * 0.5);
                }
                if ((down and index + 1 < self.boxes.items.len) or (!down and index > 0)) {
                    const next = self.boxes.items[if (down) index + 1 else index - 1];
                    if (next.layout) |next_layout| {
                        const next_origin = textOrigin(next, document);
                        return next.text_start + c.spica_text_layout_hit_test(next_layout, x - next_origin.x, if (down) 0 else c.spica_text_layout_height(next_layout));
                    }
                    return if (down) next.text_start else next.text_end;
                }
                return if (down) document.text.items.len else 0;
            }
        }
        return offset;
    }

    /// Analyze at most one bounded text segment per keypress, including for
    /// offscreen carets. Offsets refer to rendered UTF-8, not Markdown source.
    pub fn moveHorizontal(self: *const View, document: *const md.Document, offset: usize, forward: bool, word: bool) usize {
        const text = document.text.items;
        for (self.boxes.items) |box| {
            if (if (forward) offset < box.text_start or offset >= box.text_end else offset <= box.text_start or offset > box.text_end) continue;
            var graphemes: [32768]u8 = undefined;
            var words: [32768]u8 = undefined;
            const bytes = text[box.text_start..box.text_end];
            Edit.analyzeValidUtf8(bytes, &graphemes, &words);
            const breaks = if (word) words[0..bytes.len] else graphemes[0..bytes.len];
            const local = offset - box.text_start;
            return box.text_start + (if (forward) Edit.nextBoundary(breaks, local) else Edit.previousBoundary(breaks, local));
        }
        // Gaps between rendered blocks consist of separators (newlines/tabs).
        if (forward) {
            var end = @min(offset + 1, text.len);
            while (end < text.len and text[end] & 0xc0 == 0x80) end += 1;
            return end;
        }
        var start = offset -| 1;
        while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
        return start;
    }

    pub fn draw(self: *View, engine: *c.SpicaText, renderer: *c.SDL_Renderer, document: *const md.Document, highlights: []const Highlight, x: f32, y: f32, palette: Theme.Palette, light: bool) !void {
        const color = c.SDL_Color{ .r = palette.text.r, .g = palette.text.g, .b = palette.text.b, .a = 255 };
        for (self.boxes.items) |box| {
            const layout = box.layout orelse continue;
            const block = document.blocks.items[box.block];
            const mono = block.kind == .code or block.kind == .html;
            if (mono or block.kind == .table_cell) {
                const shade = if (mono) palette.raised else palette.panel;
                _ = c.SDL_SetRenderDrawColor(renderer, shade.r, shade.g, shade.b, 255);
                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = x + box.x, .y = y + box.y, .w = box.width + (if (block.kind == .table_cell) @as(f32, 16) else 0), .h = box.height });
            }
            const origin = textOrigin(box, document);
            if (self.selection) |range| {
                const start = @max(range.start, box.text_start);
                const end = @min(range.end, box.text_end);
                if (start < end) {
                    // A native layout has at most 8192 codepoints. Use reusable
                    // scratch so bidi selections cannot silently lose rectangles.
                    const count = c.spica_text_layout_selection_rects(layout, start - box.text_start, end - box.text_start, null, 0);
                    try self.selection_scratch.resize(self.allocator, count);
                    const rects = self.selection_scratch.items;
                    _ = c.spica_text_layout_selection_rects(layout, start - box.text_start, end - box.text_start, rects.ptr, rects.len);
                    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(renderer, palette.accent.r, palette.accent.g, palette.accent.b, 90);
                    for (rects) |rect| {
                        const screen = c.SDL_FRect{ .x = x + origin.x + rect.x, .y = y + origin.y + rect.y, .w = rect.w, .h = rect.h };
                        if (!c.SDL_RenderFillRect(renderer, &screen)) return error.SelectionDraw;
                    }
                }
            }
            self.color_scratch.clearRetainingCapacity();
            if (block.kind == .code) {
                for (highlights) |span| {
                    const start = @max(span.start, box.text_start);
                    const end = @min(span.end, box.text_end);
                    if (start >= end) continue;
                    try self.color_scratch.append(self.allocator, .{ .byte_start = start - box.text_start, .byte_end = end - box.text_start, .rgba = tokenColor(span.token_class, light) });
                }
            }
            if (!c.spica_text_layout_draw_colors(engine, layout, x + origin.x, y + origin.y, color, self.color_scratch.items.ptr, self.color_scratch.items.len)) return error.TextDraw;
            if (self.selection) |range| if (range.start == range.end and range.start >= box.text_start and range.start <= box.text_end) {
                var caret: c.SDL_FRect = undefined;
                if (c.spica_text_layout_caret(layout, range.start - box.text_start, &caret)) {
                    caret.x += x + origin.x;
                    caret.y += y + origin.y;
                    caret.w = 1;
                    _ = c.SDL_SetRenderDrawColor(renderer, palette.accent.r, palette.accent.g, palette.accent.b, 255);
                    _ = c.SDL_RenderFillRect(renderer, &caret);
                }
            };
            if (block.parent) |parent| {
                const ancestor = document.blocks.items[parent];
                if (ancestor.kind == .item and box.first) {
                    const label = switch (ancestor.task) {
                        .checked => "☑",
                        .unchecked => "☐",
                        .none => "•",
                    };
                    if (!c.spica_text_draw(engine, label.ptr, label.len, x + box.x - 18, y + box.y + 18, color)) return error.TextDraw;
                } else if (ancestor.kind == .quote) {
                    _ = c.SDL_SetRenderDrawColor(renderer, palette.accent.r, palette.accent.g, palette.accent.b, 255);
                    _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = x + box.x - 16, .y = y + box.y, .w = 2, .h = box.height - 4 });
                }
            }
        }
    }

    fn tokenColor(token: c_uint, light: bool) u32 {
        return switch (token) {
            c.SPICA_TOKEN_KEYWORD => if (light) 0x7D35A6FF else 0xC792EAFF,
            c.SPICA_TOKEN_STRING => if (light) 0x267544FF else 0xA9D18EFF,
            c.SPICA_TOKEN_NUMBER, c.SPICA_TOKEN_CONSTANT => if (light) 0xA35213FF else 0xE9B277FF,
            c.SPICA_TOKEN_FUNCTION => if (light) 0x2357B5FF else 0x82B7F7FF,
            c.SPICA_TOKEN_TYPE => if (light) 0x177B78FF else 0x82D4CCFF,
            c.SPICA_TOKEN_COMMENT => if (light) 0x657181FF else 0x8493A6FF,
            c.SPICA_TOKEN_PROPERTY => if (light) 0x7C4B21FF else 0xD7BE8CFF,
            else => if (light) 0x182231FF else 0xE7EDF5FF,
        };
    }
};

test "selection arrows preserve combining characters flags and joined emoji" {
    const allocator = std.testing.allocator;
    const text = "e\u{301}🇺🇸👩‍💻";
    var document = try md.parse(allocator, @splat(90), text);
    defer document.deinit();
    var view = View.init(allocator);
    defer view.deinit();
    try view.rebuild(&document, 300);
    const after_accent = view.moveHorizontal(&document, 0, true, false);
    try std.testing.expectEqual(@as(usize, "e\u{301}".len), after_accent);
    const after_flag = view.moveHorizontal(&document, after_accent, true, false);
    try std.testing.expectEqual(@as(usize, "e\u{301}🇺🇸".len), after_flag);
    try std.testing.expectEqual(text.len, view.moveHorizontal(&document, after_flag, true, false));
    try std.testing.expectEqual(after_flag, view.moveHorizontal(&document, text.len, false, false));
    try std.testing.expectEqual(after_accent, view.moveHorizontal(&document, after_flag, false, false));
}

test "large single-line Unicode paragraphs retain late text within native visible layouts" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    for (0..30000) |_| try source.appendSlice(allocator, "é ");
    try source.appendSlice(allocator, "late-visible-sentinel");
    var document = try md.parse(allocator, @splat(91), source.items);
    defer document.deinit();
    var view = View.init(allocator);
    defer view.deinit();
    try view.rebuild(&document, 768);
    var end: u32 = 0;
    for (view.boxes.items) |box| {
        try std.testing.expectEqual(end, box.text_start);
        const bytes = document.text.items[box.text_start..box.text_end];
        try std.testing.expect(std.unicode.utf8ValidateSlice(bytes));
        try std.testing.expect(try std.unicode.utf8CountCodepoints(bytes) <= 4096);
        end = box.text_end;
    }
    try std.testing.expectEqual(document.text.items.len, end);
    for (view.boxes.items[1..]) |box| {
        const previous = view.moveHorizontal(&document, box.text_start, false, false);
        try std.testing.expect(previous < box.text_start);
        try std.testing.expectEqual(@as(usize, box.text_start), view.moveHorizontal(&document, previous, true, false));
    }
    const sentinel_offset = std.mem.indexOf(u8, document.text.items, "late-visible-sentinel") orelse return error.LateTextMissing;
    try std.testing.expect(sentinel_offset > 65536);
    if (!c.spica_image_install_sdl_allocator()) return error.SDLAllocatorInstallation;
    const surface = c.SDL_CreateSurface(800, 200, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(engine);
    defer view.releaseShapes();
    const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/theme.json", allocator, .limited(16384));
    defer allocator.free(theme_bytes);
    const theme = try Theme.parse(allocator, theme_bytes);
    for (0..view.boxes.items.len) |index| {
        try view.prepareRegion(engine, &document, view.boxes.items[index].y, 200, theme.metrics);
        const box = view.boxes.items[index];
        const layout = box.layout orelse return error.VisibleSegmentMissing;
        var line: c.SpicaTextLine = undefined;
        try std.testing.expect(c.spica_text_layout_line(layout, c.spica_text_layout_line_count(layout) - 1, &line));
        if (box.last) try std.testing.expect(box.text_start + line.byte_end >= sentinel_offset + "late-visible-sentinel".len);
    }
}

test "long table cells retain one column across bounded text segments" {
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "| A | B |\n| --- | --- |\n| ");
    for (0..12000) |_| try source.appendSlice(allocator, "猫 ");
    try source.appendSlice(allocator, "tail-sentinel | adjacent-cell |\n");
    var document = try md.parse(allocator, @splat(92), source.items);
    defer document.deinit();
    var view = View.init(allocator);
    defer view.deinit();
    try view.rebuild(&document, 768);
    var previous: ?Box = null;
    var checked = false;
    for (view.boxes.items) |box| {
        const block = document.blocks.items[box.block];
        if (block.kind != .table_cell or block.text_end - block.text_start < 32768) continue;
        if (previous) |before| {
            try std.testing.expectEqual(before.block, box.block);
            try std.testing.expectEqual(before.x, box.x);
            try std.testing.expectEqual(before.width, box.width);
            try std.testing.expectEqual(before.y + before.height, box.y);
            try std.testing.expectEqual(before.text_end, box.text_start);
            checked = true;
        }
        previous = box;
        if (box.last) try std.testing.expect(std.mem.indexOf(u8, document.text.items[box.text_start..box.text_end], "tail-sentinel") != null);
    }
    try std.testing.expect(checked);
}
