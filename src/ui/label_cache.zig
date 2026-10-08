const std = @import("std");
const c = @import("../native/bindings.zig").c;
const widgets = @import("widgets.zig");
const Color = @import("theme.zig").Color;

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
        const truncated = try self.width(text, bytes, size) > available;
        const suffix_width = if (truncated) try self.width(text, "…", size) else 0;
        var clip = widgets.Clip.push(renderer, .{ .x = x, .y = top, .w = @max(0, available - suffix_width), .h = @floatFromInt(size + 8) });
        defer clip.restore(renderer);
        try self.draw(text, bytes, x, top, size, color);
        clip.restore(renderer);
        if (truncated) try self.draw(text, "…", x + available - suffix_width, top, size, color);
    }
};
