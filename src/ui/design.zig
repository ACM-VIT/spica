//! Runtime-independent, owned-by-value presentation settings. No VM pointers.
const std = @import("std");
const script = @import("../script.zig");
pub const Color = @import("color.zig").Color;

/// T3 Code eb1510d, packages/shared/src/themePalettes.ts,
/// T3_CODE_DARK_THEME_COLORS (MIT). Selection uses its terminalSelection role.
pub const Palette = struct {
    background: Color = rgb(0x0a0a0a),
    sidebar: Color = rgb(0x000000),
    surface: Color = rgb(0x111111),
    raised: Color = rgb(0x111111),
    border: Color = rgb(0x191919),
    foreground: Color = rgb(0xf5f5f5),
    muted: Color = rgb(0x818181),
    accent: Color = rgb(0x346bf1),
    accent_text: Color = rgb(0xffffff),
    selection: Color = rgb(0x343a47),
    sidebar_active: Color = rgb(0x1a1b1b),
    sidebar_hover: Color = rgb(0x131313),
    sidebar_muted: Color = rgb(0xa3a3a3),
    sidebar_border: Color = rgb(0x141414),
    danger: Color = rgb(0xfb414a),
};

pub const Metrics = struct {
    sidebar_width: f32 = 256,
    content_width: f32 = 736,
    header_height: f32 = 52,
    composer_height: f32 = 160,
    gutter: f32 = 24,
    gap: f32 = 12,
    radius: f32 = 24,
};

pub const metric_min = [7]f32{ 148, 400, 48, 136, 12, 4, 0 };
pub const metric_max = [7]f32{ 400, 1600, 96, 240, 48, 32, 24 };
pub const ValidationError = error{InvalidDesign};

pub const Config = struct {
    colors: Palette = .{},
    layout: Metrics = .{},

    pub fn validate(self: Config) ValidationError!void {
        inline for (std.meta.fields(Metrics), 0..) |f, i| {
            const value = @field(self.layout, f.name);
            if (!std.math.isFinite(value) or value < metric_min[i] or value > metric_max[i])
                return error.InvalidDesign;
        }
    }

    /// Validate the complete native descriptor before copying any optional value.
    /// Transport implementations must provide the same validation as Lua.
    pub fn fromScript(root: *const script.Root) ValidationError!Config {
        const source = &root.design;
        if (source.colors_present & ~@as(u32, 0x7fff) != 0 or
            source.layout_present & ~@as(u32, 0x7f) != 0)
            return error.InvalidDesign;
        inline for (0..7) |i| {
            if (source.layout_present & (@as(u32, 1) << i) != 0) {
                const value = source.layout[i];
                if (!std.math.isFinite(value) or value < metric_min[i] or value > metric_max[i])
                    return error.InvalidDesign;
            }
        }
        var result: Config = .{};
        inline for (std.meta.fields(Palette), 0..) |f, i| {
            if (source.colors_present & (@as(u32, 1) << i) != 0) {
                const c = source.colors[i];
                @field(result.colors, f.name) = .{ .r = c[0], .g = c[1], .b = c[2] };
            }
        }
        inline for (std.meta.fields(Metrics), 0..) |f, i| {
            if (source.layout_present & (@as(u32, 1) << i) != 0)
                @field(result.layout, f.name) = source.layout[i];
        }
        try result.validate();
        return result;
    }
};

fn rgb(comptime value: u24) Color {
    return .{ .r = @intCast(value >> 16), .g = @intCast((value >> 8) & 255), .b = @intCast(value & 255) };
}
