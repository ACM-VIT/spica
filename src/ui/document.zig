const std = @import("std");
const c = @import("../native/bindings.zig").c;
const md = @import("../content/markdown.zig");
const Theme = @import("theme.zig");
const Highlight = @import("../content/worker.zig").Highlight;
const Edit = @import("../text/edit.zig");

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
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) View {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *View) void {
        self.clear();
        self.boxes.deinit(self.allocator);
        self.color_scratch.deinit(self.allocator);
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
            self.color_scratch.clearRetainingCapacity();
            if (block.kind == .code) {
                for (highlights) |span| {
                    const start = @max(span.start, box.text_start);
                    const end = @min(span.end, box.text_end);
                    if (start >= end) continue;
                    try self.color_scratch.append(self.allocator, .{ .byte_start = start - box.text_start, .byte_end = end - box.text_start, .rgba = tokenColor(span.token_class, light) });
                }
            }
            if (!c.spica_text_layout_draw_colors(engine, layout, x + box.x + (if (mono) @as(f32, 12) else 0), y + box.y + (if (mono) (if (box.first) @as(f32, 12) else 0) else 4), color, self.color_scratch.items.ptr, self.color_scratch.items.len)) return error.TextDraw;
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
