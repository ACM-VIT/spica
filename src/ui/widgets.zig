const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Color = @import("theme.zig").Color;

pub fn panel(renderer: *c.SDL_Renderer, rect: c.SDL_FRect, radius_value: f32, color: Color) !void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const radius = @min(radius_value, @min(rect.w, rect.h) / 2);
    if (radius <= 0) {
        if (!c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255) or !c.SDL_RenderFillRect(renderer, &rect)) return error.RectangleDraw;
        return;
    }
    // Center fan + a one-pixel coverage fringe. Fixed stack buffers, painter
    // order preserved, no retained full-window texture and no frame allocation.
    const segments = 8;
    const perimeter = 4 * (segments + 1);
    var vertices: [1 + perimeter * 2]c.SDL_Vertex = undefined;
    var indices: [perimeter * 9]c_int = undefined;
    const rgba = c.SDL_FColor{ .r = @as(f32, @floatFromInt(color.r)) / 255, .g = @as(f32, @floatFromInt(color.g)) / 255, .b = @as(f32, @floatFromInt(color.b)) / 255, .a = 1 };
    vertices[0] = .{ .position = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 }, .color = rgba, .tex_coord = .{ .x = 0, .y = 0 } };
    const centers = [_]c.SDL_FPoint{
        .{ .x = rect.x + rect.w - radius, .y = rect.y + radius },
        .{ .x = rect.x + rect.w - radius, .y = rect.y + rect.h - radius },
        .{ .x = rect.x + radius, .y = rect.y + rect.h - radius },
        .{ .x = rect.x + radius, .y = rect.y + radius },
    };
    for (centers, 0..) |center, corner| {
        for (0..segments + 1) |step| {
            const angle = (-std.math.pi / 2.0 + @as(f32, @floatFromInt(corner)) * std.math.pi / 2.0) + @as(f32, @floatFromInt(step)) * std.math.pi / (2.0 * segments);
            const dx = @cos(angle);
            const dy = @sin(angle);
            const index = corner * (segments + 1) + step;
            vertices[1 + index] = .{ .position = .{ .x = center.x + dx * radius, .y = center.y + dy * radius }, .color = rgba, .tex_coord = .{ .x = 0, .y = 0 } };
            var transparent = rgba;
            transparent.a = 0;
            vertices[1 + perimeter + index] = .{ .position = .{ .x = center.x + dx * (radius + 1), .y = center.y + dy * (radius + 1) }, .color = transparent, .tex_coord = .{ .x = 0, .y = 0 } };
        }
    }
    for (0..perimeter) |index| {
        const a: c_int = @intCast(1 + index);
        const b: c_int = @intCast(1 + (index + 1) % perimeter);
        const outer_a: c_int = a + perimeter;
        const outer_b: c_int = b + perimeter;
        @memcpy(indices[index * 9 ..][0..9], &[_]c_int{ 0, a, b, a, outer_a, outer_b, a, outer_b, b });
    }
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND) or !c.SDL_RenderGeometry(renderer, null, &vertices, vertices.len, &indices, indices.len)) return error.RoundedRectangleDraw;
}

pub const Icon = enum { sidebar, plus, folder, layers, arrow_up, stop, chevron_down, theme };

fn line(renderer: *c.SDL_Renderer, x1: f32, y1: f32, x2: f32, y2: f32) !void {
    if (!c.SDL_RenderLine(renderer, x1, y1, x2, y2)) return error.IconDraw;
}

pub fn icon(renderer: *c.SDL_Renderer, kind: Icon, bounds: c.SDL_FRect, color: Color) !void {
    if (!c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255)) return error.IconDraw;
    const x = bounds.x;
    const y = bounds.y;
    const s = bounds.w / 16;
    switch (kind) {
        .sidebar => {
            const border = c.SDL_FRect{ .x = x + 2 * s, .y = y + 2 * s, .w = 12 * s, .h = 12 * s };
            if (!c.SDL_RenderRect(renderer, &border)) return error.IconDraw;
            try line(renderer, x + 6 * s, y + 2 * s, x + 6 * s, y + 14 * s);
        },
        .plus => {
            try line(renderer, x + 3 * s, y + 8 * s, x + 13 * s, y + 8 * s);
            try line(renderer, x + 8 * s, y + 3 * s, x + 8 * s, y + 13 * s);
        },
        .folder => {
            const points = [_]c.SDL_FPoint{
                .{ .x = x + 2 * s, .y = y + 13 * s }, .{ .x = x + 2 * s, .y = y + 3 * s },
                .{ .x = x + 7 * s, .y = y + 3 * s },  .{ .x = x + 9 * s, .y = y + 5 * s },
                .{ .x = x + 14 * s, .y = y + 5 * s }, .{ .x = x + 14 * s, .y = y + 13 * s },
                .{ .x = x + 2 * s, .y = y + 13 * s },
            };
            if (!c.SDL_RenderLines(renderer, &points, points.len)) return error.IconDraw;
        },
        .layers => {
            const points = [_]c.SDL_FPoint{
                .{ .x = x + s, .y = y + 4 * s },      .{ .x = x + 8 * s, .y = y + s },
                .{ .x = x + 15 * s, .y = y + 4 * s }, .{ .x = x + 8 * s, .y = y + 7 * s },
                .{ .x = x + s, .y = y + 4 * s },
            };
            if (!c.SDL_RenderLines(renderer, &points, points.len)) return error.IconDraw;
            for ([_]f32{ 7, 10 }) |offset| {
                try line(renderer, x + s, y + offset * s, x + 8 * s, y + (offset + 3) * s);
                try line(renderer, x + 8 * s, y + (offset + 3) * s, x + 15 * s, y + offset * s);
            }
        },
        .arrow_up => {
            try line(renderer, x + 4 * s, y + 7 * s, x + 8 * s, y + 3 * s);
            try line(renderer, x + 8 * s, y + 3 * s, x + 12 * s, y + 7 * s);
            try line(renderer, x + 8 * s, y + 3 * s, x + 8 * s, y + 13 * s);
        },
        .stop => try panel(renderer, .{ .x = x + 4 * s, .y = y + 4 * s, .w = 8 * s, .h = 8 * s }, s, color),
        .chevron_down => {
            try line(renderer, x + 4 * s, y + 6 * s, x + 8 * s, y + 10 * s);
            try line(renderer, x + 8 * s, y + 10 * s, x + 12 * s, y + 6 * s);
        },
        .theme => {
            const border = c.SDL_FRect{ .x = x + 2 * s, .y = y + 2 * s, .w = 12 * s, .h = 12 * s };
            if (!c.SDL_RenderRect(renderer, &border)) return error.IconDraw;
            try panel(renderer, .{ .x = x + 3 * s, .y = y + 3 * s, .w = 5 * s, .h = 10 * s }, 0, color);
        },
    }
}
