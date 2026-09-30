const std = @import("std");
const c = @import("../native/bindings.zig").c;
const md = @import("../content/markdown.zig");
const Theme = @import("theme.zig");
const Highlight = @import("../content/worker.zig").Highlight;

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

// Only the selected document's compact block metadata is retained. Shapes for
// offscreen blocks are released; text source and rich structure remain intact.
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
            var end = start;
            var cursor = start;
            var points: usize = 0;
            while (cursor < block.text_end) {
                const line_end = if (std.mem.indexOfScalar(u8, document.text.items[cursor..block.text_end], '\n')) |offset| cursor + offset + 1 else block.text_end;
                const line_points = try std.unicode.utf8CountCodepoints(document.text.items[cursor..line_end]);
                if (block.kind != .table_cell and end > start and (points + line_points > 4096 or line_end - start > 32768)) {
                    try self.appendSegment(document, block, index, start, end);
                    start = cursor;
                    points = 0;
                }
                points += line_points;
                end = line_end;
                cursor = line_end;
            }
            try self.appendSegment(document, block, index, start, end);
        }
        self.reflow(document);
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
                var height: f32 = 0;
                while (end < self.boxes.items.len and document.blocks.items[self.boxes.items[end].block].parent == row) : (end += 1) {
                    height = @max(height, self.boxes.items[end].height);
                }
                const columns: f32 = @floatFromInt(end - index);
                for (self.boxes.items[index..end], 0..) |*box, column| {
                    box.x = @as(f32, @floatFromInt(column)) * self.width / columns;
                    box.width = self.width / columns - 16;
                    box.y = y;
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

    pub fn prepare(self: *View, engine: *c.SpicaText, document: *const md.Document, scroll: *f32, viewport_height: f32, trailing_height: f32, follow_bottom: bool, metrics: Theme.Metrics) !void {
        // Each changed pass makes another block's estimated height exact.
        // Reflow can reveal a previously offscreen block, so finish that work
        // before presenting rather than leaving an unshaped hole until input.
        for (0..self.boxes.items.len + 2) |_| {
            const maximum = @max(0, self.height + trailing_height - viewport_height);
            scroll.* = if (follow_bottom) maximum else @min(scroll.*, maximum);
            if (!try self.shapeVisible(engine, document, scroll.*, viewport_height, metrics)) return;
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
