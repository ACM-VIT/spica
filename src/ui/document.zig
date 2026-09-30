const std = @import("std");
const c = @import("../native/bindings.zig").c;
const md = @import("../content/markdown.zig");
const Theme = @import("theme.zig");
const Highlight = @import("../content/worker.zig").Highlight;

const Box = struct {
    block: u32,
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

    pub fn init(allocator: std.mem.Allocator) View { return .{ .allocator = allocator }; }
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
            const indent = indentation(document, block);
            const available = @max(32, width - indent);
            const bytes = document.text.items[block.text_start..block.text_end];
            var lines: usize = 1;
            for (bytes) |byte| { if (byte == '\n') lines += 1; }
            const estimate = @max(lines, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(bytes.len)) * 7.2 / available))));
            try self.boxes.append(self.allocator, .{ .block = @intCast(index), .x = indent, .width = available, .height = @as(f32, @floatFromInt(estimate)) * 22 + 12 });
        }
        self.reflow(document);
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

    pub fn prepare(self: *View, engine: *c.SpicaText, document: *const md.Document, scroll: f32, viewport_height: f32, metrics: Theme.Metrics) !void {
        // Table widths are derived before shaping. Reflow once after new line
        // heights arrive; a warm scroll over retained visible lines does no work.
        var changed = false;
        for (self.boxes.items) |*box| {
            const visible = box.y + box.height >= scroll - 40 and box.y <= scroll + viewport_height + 40;
            if (!visible) {
                if (box.layout) |layout| { c.spica_text_layout_release(layout); box.layout = null; }
                continue;
            }
            if (box.layout != null) continue;
            const block = document.blocks.items[box.block];
            const mono = block.kind == .code or block.kind == .html;
            const size: c_uint = @intFromFloat(if (block.kind == .heading) @max(metrics.body_px, 27 - @as(f32, @floatFromInt(block.heading_level)) * 2) else if (mono) metrics.code_px else metrics.body_px);
            const text = std.mem.trimEnd(u8, document.text.items[block.text_start..block.text_end], "\n");
            var spans: std.ArrayList(c.SpicaTextSpan) = .empty;
            defer spans.deinit(self.allocator);
            for (document.runs.items[block.first_run..block.end_run]) |run| {
                const style: c_uint = (if (run.strong) @as(c_uint, c.SPICA_TEXT_BOLD) else 0) |
                    (if (run.emphasis) @as(c_uint, c.SPICA_TEXT_ITALIC) else 0) |
                    (if (run.kind == .code) @as(c_uint, c.SPICA_TEXT_MONOSPACE) else 0);
                const end = @min(run.end - block.text_start, text.len);
                const start = @min(run.start - block.text_start, end);
                if (style != 0 and start != end) try spans.append(self.allocator, .{ .byte_start = start, .byte_end = end, .style = style });
            }
            const layout = c.spica_text_layout_create_spans(engine, text.ptr, text.len, @max(16, box.width - (if (mono) @as(f32, 24) else 0)), size, mono, spans.items.ptr, spans.items.len) orelse {
                std.log.err("text layout: {s}", .{c.SDL_GetError()});
                return error.TextLayout;
            };
            box.layout = layout;
            const height = c.spica_text_layout_height(layout) + (if (mono) @as(f32, 24) else 12);
            changed = changed or box.height != height;
            box.height = height;
        }
        if (changed) self.reflow(document);
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
                    if (span.start < block.text_start or span.end > block.text_end) continue;
                    try self.color_scratch.append(self.allocator, .{ .byte_start = span.start - block.text_start, .byte_end = span.end - block.text_start, .rgba = tokenColor(span.token_class, light) });
                }
            }
            if (!c.spica_text_layout_draw_colors(engine, layout, x + box.x + (if (mono) @as(f32, 12) else 0), y + box.y + (if (mono) @as(f32, 12) else 4), color, self.color_scratch.items.ptr, self.color_scratch.items.len)) return error.TextDraw;
            if (block.parent) |parent| {
                const ancestor = document.blocks.items[parent];
                if (ancestor.kind == .item) {
                    const label = switch (ancestor.task) { .checked => "☑", .unchecked => "☐", .none => "•" };
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
