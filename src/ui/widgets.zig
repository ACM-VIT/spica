const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Color = @import("color.zig").Color;

pub fn rgba(color: Color) c.SDL_Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
}

pub fn contains(bounds: c.SDL_FRect, x: f32, y: f32) bool {
    return x >= bounds.x and x < bounds.x + bounds.w and y >= bounds.y and y < bounds.y + bounds.h;
}

pub const Clip = struct {
    previous: c.SDL_Rect,
    enabled: bool,
    restored: bool = false,

    pub fn push(renderer: *c.SDL_Renderer, bounds: c.SDL_FRect) Clip {
        var result = Clip{ .previous = undefined, .enabled = c.SDL_RenderClipEnabled(renderer) };
        _ = c.SDL_GetRenderClipRect(renderer, &result.previous);
        var next = c.SDL_Rect{ .x = @intFromFloat(bounds.x), .y = @intFromFloat(bounds.y), .w = @intFromFloat(@max(0, bounds.w)), .h = @intFromFloat(@max(0, bounds.h)) };
        if (result.enabled) {
            const right = @min(next.x + next.w, result.previous.x + result.previous.w);
            const bottom = @min(next.y + next.h, result.previous.y + result.previous.h);
            next.x = @max(next.x, result.previous.x);
            next.y = @max(next.y, result.previous.y);
            next.w = @max(0, right - next.x);
            next.h = @max(0, bottom - next.y);
        }
        _ = c.SDL_SetRenderClipRect(renderer, &next);
        return result;
    }

    pub fn restore(self: *Clip, renderer: *c.SDL_Renderer) void {
        if (self.restored) return;
        _ = c.SDL_SetRenderClipRect(renderer, if (self.enabled) &self.previous else null);
        self.restored = true;
    }
};

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
    const fill = c.SDL_FColor{ .r = @as(f32, @floatFromInt(color.r)) / 255, .g = @as(f32, @floatFromInt(color.g)) / 255, .b = @as(f32, @floatFromInt(color.b)) / 255, .a = 1 };
    vertices[0] = .{ .position = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 }, .color = fill, .tex_coord = .{ .x = 0, .y = 0 } };
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
            vertices[1 + index] = .{ .position = .{ .x = center.x + dx * radius, .y = center.y + dy * radius }, .color = fill, .tex_coord = .{ .x = 0, .y = 0 } };
            var transparent = fill;
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
