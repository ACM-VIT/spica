const std = @import("std");
const Theme = @import("../../ui/theme.zig");
const c = @import("../../native/bindings.zig").c;

const min_font_size: u8 = 12;
const max_font_size: u8 = 24;
const min_ui_scale: u16 = 75;
const max_ui_scale: u16 = 175;
const min_chat_width: u16 = 560;
const max_chat_width: u16 = 1120;

pub const Action = enum {
    close,
    dark,
    light,
    font_smaller,
    font_larger,
    scale_smaller,
    scale_larger,
    scale_reset,
    width_smaller,
    width_larger,
    reset,
};

pub const Values = struct {
    font_size: u8 = 15,
    ui_scale: u16 = 100,
    chat_width: u16 = 768,
    light: bool = false,
};

pub fn actionEnabled(values: Values, action: Action) bool {
    return switch (action) {
        .font_smaller => values.font_size > min_font_size,
        .font_larger => values.font_size < max_font_size,
        .scale_smaller => values.ui_scale > min_ui_scale,
        .scale_larger => values.ui_scale < max_ui_scale,
        .width_smaller => values.chat_width > min_chat_width,
        .width_larger => values.chat_width < max_chat_width,
        else => true,
    };
}

pub fn apply(values: *Values, action: Action) void {
    switch (action) {
        .close => {},
        .dark => values.light = false,
        .light => values.light = true,
        .font_smaller => values.font_size = std.math.clamp(values.font_size -| 1, min_font_size, max_font_size),
        .font_larger => values.font_size = std.math.clamp(values.font_size +| 1, min_font_size, max_font_size),
        .scale_smaller => values.ui_scale = std.math.clamp(values.ui_scale -| 5, min_ui_scale, max_ui_scale),
        .scale_larger => values.ui_scale = std.math.clamp(values.ui_scale +| 5, min_ui_scale, max_ui_scale),
        .scale_reset => values.ui_scale = 100,
        .width_smaller => values.chat_width = std.math.clamp(values.chat_width -| 40, min_chat_width, max_chat_width),
        .width_larger => values.chat_width = std.math.clamp(values.chat_width +| 40, min_chat_width, max_chat_width),
        .reset => values.* = .{},
    }
}

pub fn metrics(base: Theme.Metrics, values: Values) Theme.Metrics {
    var adjusted = base;
    const body: f32 = @floatFromInt(values.font_size);
    const ratio = body / base.body_px;
    adjusted.body_px = body;
    adjusted.code_px = base.code_px * ratio;
    adjusted.line_height_px = base.line_height_px * ratio;
    adjusted.chat_max_width = @floatFromInt(values.chat_width);
    return adjusted;
}

fn adjustmentButton(app: anytype, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
    if (actionEnabled(app.appearance, action)) return app.button(.{ .appearance = action }, text, bounds);
    const colors = app.palette();
    try app.rectangle(bounds.x, bounds.y, bounds.w, bounds.h, 6, colors.border);
    try app.rectangle(bounds.x + 1, bounds.y + 1, bounds.w - 2, bounds.h - 2, 5, colors.panel);
    try app.label(text, bounds.x + 10, bounds.y + 8, 13, colors.muted);
}

pub fn draw(app: anytype) !void {
    if (!app.settings_open) return;
    const colors = app.palette();
    const canvas_width = app.shell.sidebar.width + app.shell.conversation.width;
    const canvas_height = app.shell.header.height + app.shell.conversation.height + app.shell.composer.height;
    const width = @min(@as(f32, 500), @max(@as(f32, 0), canvas_width - 32));
    const height = @min(@as(f32, 360), @max(@as(f32, 0), canvas_height - 32));
    const x = (canvas_width - width) / 2;
    const y = (canvas_height - height) / 2;
    const left = x + 20;
    const right = x + width - 20;
    const row_step = (height - 146) / 4;
    const theme_y = y + 96;
    const font_y = theme_y + row_step;
    const scale_y = font_y + row_step;
    const width_y = scale_y + row_step;
    const footer_y = width_y + row_step;

    try app.rectangle(0, 0, canvas_width, canvas_height, 0, colors.canvas);
    try app.rectangle(x, y, width, height, 10, colors.border);
    try app.rectangle(x + 1, y + 1, width - 2, height - 2, 9, colors.panel);
    try app.label("Appearance", left, y + 18, 19, colors.text);
    try app.label("UI scale changes interface size.", left, y + 48, 13, colors.muted);
    try app.label("Hardware DPI remains automatic.", left, y + 66, 13, colors.muted);

    try app.label("Theme", left, theme_y + 8, 13, colors.text);
    try app.button(.{ .appearance = .dark }, if (app.appearance.light) "Dark" else "Dark (on)", .{ .x = right - 182, .y = theme_y, .w = 86, .h = 34 });
    try app.button(.{ .appearance = .light }, if (app.appearance.light) "Light (on)" else "Light", .{ .x = right - 86, .y = theme_y, .w = 86, .h = 34 });

    var buffer: [32]u8 = undefined;
    const font = try std.fmt.bufPrint(&buffer, "{d} px", .{app.appearance.font_size});
    try app.label("Text size", left, font_y + 8, 13, colors.text);
    try app.label(font, right - 182, font_y + 8, 13, colors.text);
    try adjustmentButton(app, .font_smaller, "-", .{ .x = right - 82, .y = font_y, .w = 36, .h = 34 });
    try adjustmentButton(app, .font_larger, "+", .{ .x = right - 36, .y = font_y, .w = 36, .h = 34 });

    const scale = try std.fmt.bufPrint(&buffer, "{d}%", .{app.appearance.ui_scale});
    try app.label("UI scale", left, scale_y + 8, 13, colors.text);
    try app.label(scale, right - 182, scale_y + 8, 13, colors.text);
    try adjustmentButton(app, .scale_smaller, "-", .{ .x = right - 82, .y = scale_y, .w = 36, .h = 34 });
    try adjustmentButton(app, .scale_larger, "+", .{ .x = right - 36, .y = scale_y, .w = 36, .h = 34 });

    const reading_width = try std.fmt.bufPrint(&buffer, "{d} px", .{app.appearance.chat_width});
    try app.label("Reading width", left, width_y + 8, 13, colors.text);
    try app.label(reading_width, right - 182, width_y + 8, 13, colors.text);
    try adjustmentButton(app, .width_smaller, "-", .{ .x = right - 82, .y = width_y, .w = 36, .h = 34 });
    try adjustmentButton(app, .width_larger, "+", .{ .x = right - 36, .y = width_y, .w = 36, .h = 34 });

    try app.button(.{ .appearance = .reset }, "Reset", .{ .x = left, .y = footer_y, .w = 76, .h = 34 });
    try app.button(.{ .appearance = .close }, "Done", .{ .x = right - 76, .y = footer_y, .w = 76, .h = 34 });
}
