const std = @import("std");

pub const Color = struct { r: u8, g: u8, b: u8 };
pub const Palette = struct {
    canvas: Color,
    panel: Color,
    raised: Color,
    border: Color,
    text: Color,
    muted: Color,
    accent: Color,
    success: Color,
    error_color: Color,
};
pub const Metrics = struct {
    sidebar_width: f32,
    header_height: f32,
    inspector_width: f32,
    chat_max_width: f32,
    label_px: f32,
    body_px: f32,
    line_height_px: f32,
    code_px: f32,
    radius_px: f32,
};
pub const Theme = struct { light: Palette, dark: Palette, metrics: Metrics };

const RawPalette = struct {
    canvas: []const u8,
    panel: []const u8,
    raised: []const u8,
    border: []const u8,
    text: []const u8,
    muted: []const u8,
    accent: []const u8,
    success: []const u8,
    @"error": []const u8,
};
const RawTheme = struct { light: RawPalette, dark: RawPalette, metrics: Metrics };

fn color(value: []const u8) !Color {
    if (value.len != 7 or value[0] != '#') return error.InvalidColor;
    return .{
        .r = std.fmt.parseInt(u8, value[1..3], 16) catch return error.InvalidColor,
        .g = std.fmt.parseInt(u8, value[3..5], 16) catch return error.InvalidColor,
        .b = std.fmt.parseInt(u8, value[5..7], 16) catch return error.InvalidColor,
    };
}

fn palette(raw: RawPalette) !Palette {
    return .{
        .canvas = try color(raw.canvas),
        .panel = try color(raw.panel),
        .raised = try color(raw.raised),
        .border = try color(raw.border),
        .text = try color(raw.text),
        .muted = try color(raw.muted),
        .accent = try color(raw.accent),
        .success = try color(raw.success),
        .error_color = try color(raw.@"error"),
    };
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Theme {
    const parsed = try std.json.parseFromSlice(RawTheme, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const metrics = parsed.value.metrics;
    inline for (std.meta.fields(Metrics)) |field| {
        const number = @field(metrics, field.name);
        if (!std.math.isFinite(number) or number < 1 or number > 4096)
            return error.InvalidMetric;
    }
    return .{
        .light = try palette(parsed.value.light),
        .dark = try palette(parsed.value.dark),
        .metrics = metrics,
    };
}

test "invalid theme does not become active" {
    const source =
        \\{"light":{"canvas":"#F7F9FC","panel":"#FFFFFF","raised":"#EDF1F6","border":"#CCD5E0","text":"#182231","muted":"#526174","accent":"#2357B5","success":"#247242","error":"#B42332"},"dark":{"canvas":"#14171B","panel":"#1B2027","raised":"#232A33","border":"#343E4B","text":"#E7EDF5","muted":"#A8B3C2","accent":"#8AB4F8","success":"#8BD5A5","error":"#FF9B9B"},"metrics":{"sidebar_width":248,"header_height":48,"inspector_width":320,"chat_max_width":960,"label_px":13,"body_px":15,"line_height_px":22,"code_px":13,"radius_px":8}}
    ;
    const initial = try parse(std.testing.allocator, source);
    try std.testing.expectEqual(@as(u8, 0x14), initial.dark.canvas.r);
    const broken = try std.mem.replaceOwned(u8, std.testing.allocator, source, "#14171B", "#GG171B");
    defer std.testing.allocator.free(broken);
    try std.testing.expectError(error.InvalidColor, parse(std.testing.allocator, broken));
    try std.testing.expectEqual(@as(u8, 0x14), initial.dark.canvas.r);
}