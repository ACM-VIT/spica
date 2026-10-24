const std = @import("std");
const c = @import("../native/bindings.zig").c;
const script_api = @import("../script.zig");

pub const Layout = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    height: f32,
    design: @import("design.zig").Config = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32) !Layout {
        c.Clay_SetMaxElementCount(1024);
        c.Clay_SetMaxMeasureTextCacheWordCount(2048);
        const needed = c.Clay_MinMemorySize();
        const bytes = try allocator.alloc(u8, needed);
        errdefer allocator.free(bytes);
        const arena = c.Clay_CreateArenaWithCapacityAndMemory(needed, bytes.ptr);
        if (c.Clay_Initialize(arena, .{ .width = width, .height = height }, .{
            .errorHandlerFunction = null,
            .userData = null,
        }) == null) return error.ClayInitialization;
        return .{ .bytes = bytes, .allocator = allocator, .height = height };
    }

    pub fn deinit(self: *Layout) void {
        c.Clay_SetCurrentContext(null);
        self.allocator.free(self.bytes);
    }

    pub fn resize(self: *Layout, width: f32, height: f32) void {
        self.height = height;
        c.Clay_SetLayoutDimensions(.{ .width = width, .height = height });
    }

    pub const Coding = struct {
        header: c.Clay_BoundingBox,
        transcript: c.Clay_BoundingBox,
        composer: c.Clay_BoundingBox,
    };

    pub fn sidebarWidth(width: f32) f32 {
        return sidebarWidthWith(.{}, width);
    }

    pub fn sidebarWidthFor(self: *const Layout, width: f32) f32 {
        return sidebarWidthWith(self.design, width);
    }

    pub fn sidebarWidthWith(design: @import("design.zig").Config, width: f32) f32 {
        const preferred = design.layout.sidebar_width;
        return @min(@max(0, width * 0.4), if (width <= 700) @min(preferred, 148) else preferred);
    }

    pub fn coding(self: *Layout, width: f32) Coding {
        const metrics = self.design.layout;
        const gutter = @min(metrics.gutter, @max(0, (width - self.sidebarWidthFor(width)) / 4));
        c.Clay_BeginLayout();
        open("coding", grow(), grow(), c.CLAY_TOP_TO_BOTTOM);
        open("header", grow(), fixed(metrics.header_height), c.CLAY_LEFT_TO_RIGHT);
        c.Clay__CloseElement();
        var body = std.mem.zeroes(c.Clay_ElementDeclaration);
        body.id = id("body");
        body.layout.sizing = .{ .width = grow(), .height = grow() };
        body.layout.layoutDirection = c.CLAY_TOP_TO_BOTTOM;
        body.layout.childAlignment.x = c.CLAY_ALIGN_X_CENTER;
        body.layout.childGap = @intFromFloat(metrics.gap);
        body.layout.padding = .{ .left = @intFromFloat(self.sidebarWidthFor(width) + gutter), .right = @intFromFloat(gutter), .top = @intFromFloat(metrics.gap), .bottom = @intFromFloat(gutter) };
        c.Clay__OpenElement();
        c.Clay__ConfigureOpenElement(body);
        const content_width = fixed(@min(metrics.content_width, @max(0, width - self.sidebarWidthFor(width) - gutter * 2)));
        open("transcript", content_width, grow(), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        open("composer", content_width, fixed(@min(metrics.composer_height, @max(0, self.height - metrics.header_height - gutter - metrics.gap * 2))), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        c.Clay__CloseElement();
        c.Clay__CloseElement();
        _ = c.Clay_EndLayout();
        return .{ .header = bounds("header"), .transcript = bounds("transcript"), .composer = bounds("composer") };
    }

    /// The runtime validates preorder, unique IDs, depth and node/text bounds.
    /// Layout remains finite and uses the same retained native Clay arena.
    pub fn script(self: *Layout, root: *const script_api.Root, output: *[64]c.Clay_BoundingBox) Coding {
        c.Clay_BeginLayout();
        var stack: [8]usize = undefined;
        var depth: usize = 0;
        for (root.nodes[0..root.count], 0..) |*node, index| {
            while (depth != 0 and stack[depth - 1] != node.parent) {
                c.Clay__CloseElement();
                depth -= 1;
            }
            var declaration = std.mem.zeroes(c.Clay_ElementDeclaration);
            declaration.id = id(node.id.bytes[0..node.id.len]);
            declaration.layout.sizing = .{ .width = grow(), .height = switch (node.kind) {
                2 => fixed(28),
                3 => fixed(32),
                4 => fixed(180),
                else => grow(),
            } };
            declaration.layout.layoutDirection = if (node.kind == 1) c.CLAY_LEFT_TO_RIGHT else c.CLAY_TOP_TO_BOTTOM;
            declaration.layout.childGap = @intFromFloat(self.design.layout.gap);
            if (index == 0) declaration.layout.padding = .{ .left = @intFromFloat(self.design.layout.gutter), .right = @intFromFloat(self.design.layout.gutter), .top = @intFromFloat(self.design.layout.gap), .bottom = @intFromFloat(self.design.layout.gutter) };
            const style = node.style;
            if (style.present & script_api.abi.SPICA_STYLE_WIDTH != 0) declaration.layout.sizing.width = fixed(style.width);
            if (style.present & script_api.abi.SPICA_STYLE_HEIGHT != 0) declaration.layout.sizing.height = fixed(style.height);
            if (style.present & script_api.abi.SPICA_STYLE_GAP != 0) declaration.layout.childGap = @intFromFloat(style.gap);
            if (style.present & script_api.abi.SPICA_STYLE_PADDING != 0) {
                const padding: u16 = @intFromFloat(style.padding);
                declaration.layout.padding = .{ .left = padding, .right = padding, .top = padding, .bottom = padding };
            }
            c.Clay__OpenElement();
            c.Clay__ConfigureOpenElement(declaration);
            if (node.kind <= 1) {
                stack[depth] = index;
                depth += 1;
            } else c.Clay__CloseElement();
        }
        while (depth != 0) : (depth -= 1) c.Clay__CloseElement();
        _ = c.Clay_EndLayout();
        var result: Coding = std.mem.zeroes(Coding);
        for (root.nodes[0..root.count], 0..) |*node, index| {
            output[index] = bounds(node.id.bytes[0..node.id.len]);
            if (node.kind == 4) result.composer = output[index];
            if (node.kind == 5) result.transcript = output[index];
        }
        return result;
    }

    fn id(name: []const u8) c.Clay_ElementId {
        return c.Clay_GetElementId(.{ .isStaticallyAllocated = true, .length = @intCast(name.len), .chars = name.ptr });
    }
    fn bounds(name: []const u8) c.Clay_BoundingBox {
        return c.Clay_GetElementData(id(name)).boundingBox;
    }
    fn grow() c.Clay_SizingAxis {
        return .{ .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } }, .type = c.CLAY__SIZING_TYPE_GROW };
    }
    fn fixed(value: f32) c.Clay_SizingAxis {
        return .{ .size = .{ .minMax = .{ .min = value, .max = value } }, .type = c.CLAY__SIZING_TYPE_FIXED };
    }
    fn open(name: []const u8, width: c.Clay_SizingAxis, height: c.Clay_SizingAxis, direction: c.Clay_LayoutDirection) void {
        var declaration = std.mem.zeroes(c.Clay_ElementDeclaration);
        declaration.id = id(name);
        declaration.layout.sizing = .{ .width = width, .height = height };
        declaration.layout.layoutDirection = direction;
        c.Clay__OpenElement();
        c.Clay__ConfigureOpenElement(declaration);
    }
};

test "configured native geometry keeps responsive sidebar and bounded centered content" {
    for ([_]f32{ 300, 700, 720, 1000, 1280, 2200 }) |width| {
        var layout = try Layout.init(std.testing.allocator, width, 720);
        defer layout.deinit();
        try std.testing.expectEqual(Layout.sidebarWidth(width), layout.sidebarWidthFor(width));
        layout.design.layout = .{ .sidebar_width = 360, .content_width = 640, .header_height = 80, .composer_height = 208, .gutter = 32, .gap = 20, .radius = 24 };
        const boxes = layout.coding(width);
        try std.testing.expectEqual(@as(f32, 80), boxes.header.height);
        try std.testing.expectApproxEqAbs(@as(f32, 208), boxes.composer.height, 0.1);
        try std.testing.expect(layout.sidebarWidthFor(width) <= width * 0.4);
        try std.testing.expect(boxes.composer.x >= layout.sidebarWidthFor(width));
        try std.testing.expect(boxes.composer.width <= 640);
        try std.testing.expect(boxes.composer.x + boxes.composer.width <= width);
        try std.testing.expectApproxEqAbs(boxes.transcript.x, boxes.composer.x, 0.1);
        try std.testing.expectApproxEqAbs(boxes.transcript.width, boxes.composer.width, 0.1);
        try std.testing.expect(boxes.transcript.y + boxes.transcript.height + 19.9 <= boxes.composer.y);
        try std.testing.expectApproxEqAbs(@as(f32, 688), boxes.composer.y + boxes.composer.height, 0.1);
        if (width == 700) try std.testing.expectEqual(@as(f32, 148), layout.sidebarWidthFor(width));
        if (width == 1000) try std.testing.expectEqual(@as(f32, 360), layout.sidebarWidthFor(width));
        if (width == 1280) try std.testing.expectEqual(@as(f32, 360), layout.sidebarWidthFor(width));
    }
}

test "custom node dimensions padding and gap reach Clay and preserve action indices" {
    var layout = try Layout.init(std.testing.allocator, 640, 480);
    defer layout.deinit();
    var root = std.mem.zeroes(script_api.Root);
    root.count = 4;
    root.nodes[0] = .{ .kind = 0, .parent = std.math.maxInt(u16), .id = try script_api.id("styled-root"), .style = .{ .present = script_api.abi.SPICA_STYLE_PADDING | script_api.abi.SPICA_STYLE_GAP, .padding = 20, .gap = 12 } };
    root.nodes[1] = .{ .kind = 2, .parent = 0, .id = try script_api.id("styled-title"), .style = .{ .present = script_api.abi.SPICA_STYLE_WIDTH | script_api.abi.SPICA_STYLE_HEIGHT, .width = 180, .height = 36 } };
    root.nodes[2] = .{ .kind = 3, .parent = 0, .id = try script_api.id("styled-action"), .action = try script_api.id("send"), .style = .{ .present = script_api.abi.SPICA_STYLE_WIDTH | script_api.abi.SPICA_STYLE_HEIGHT, .width = 240, .height = 44 } };
    root.nodes[3] = .{ .kind = 4, .parent = 0, .id = try script_api.id("styled-composer"), .style = .{ .present = script_api.abi.SPICA_STYLE_HEIGHT, .height = 180 } };
    var output: [64]c.Clay_BoundingBox = undefined;
    const boxes = layout.script(&root, &output);
    try std.testing.expectApproxEqAbs(@as(f32, 20), output[1].x, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 20), output[1].y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 180), output[1].width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 68), output[2].y, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 240), output[2].width, 0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 44), output[2].height, 0.1);
    try std.testing.expectEqualDeep(output[3], boxes.composer);
    try std.testing.expectApproxEqAbs(@as(f32, 180), boxes.composer.height, 0.1);
    try std.testing.expectEqualStrings("send", root.nodes[2].action.bytes[0..root.nodes[2].action.len]);
}
