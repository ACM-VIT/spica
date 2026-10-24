const std = @import("std");
const c = @import("../native/bindings.zig").c;

pub const Layout = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    height: f32,

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
        return if (width < 700) 148 else if (width < 1000) 184 else 224;
    }

    pub fn coding(self: *Layout, width: f32) Coding {
        c.Clay_BeginLayout();
        open("coding", grow(), grow(), c.CLAY_TOP_TO_BOTTOM);
        open("header", grow(), fixed(64), c.CLAY_LEFT_TO_RIGHT);
        c.Clay__CloseElement();
        var body = std.mem.zeroes(c.Clay_ElementDeclaration);
        body.id = id("body");
        body.layout.sizing = .{ .width = grow(), .height = grow() };
        body.layout.layoutDirection = c.CLAY_TOP_TO_BOTTOM;
        body.layout.childAlignment.x = c.CLAY_ALIGN_X_CENTER;
        body.layout.childGap = 12;
        body.layout.padding = .{ .left = @intFromFloat(sidebarWidth(width) + 24), .right = 24, .top = 16, .bottom = 16 };
        c.Clay__OpenElement();
        c.Clay__ConfigureOpenElement(body);
        const content_width = fixed(@min(900, @max(0, width - sidebarWidth(width) - 48)));
        open("transcript", content_width, grow(), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        open("composer", content_width, fixed(std.math.clamp(self.height * 0.23, 136, 168)), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        c.Clay__CloseElement();
        c.Clay__CloseElement();
        _ = c.Clay_EndLayout();
        return .{ .header = bounds("header"), .transcript = bounds("transcript"), .composer = bounds("composer") };
    }

    /// The runtime validates preorder, unique IDs, depth and node/text bounds.
    /// Layout remains finite and uses the same retained native Clay arena.
    pub fn script(_: *Layout, root: *const @import("../script.zig").Root, output: *[64]c.Clay_BoundingBox) Coding {
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
            declaration.layout.childGap = 8;
            if (index == 0) declaration.layout.padding = .{ .left = 24, .right = 24, .top = 12, .bottom = 20 };
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
