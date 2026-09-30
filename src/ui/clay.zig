const std = @import("std");
const c = @import("../native/bindings.zig").c;

pub const Layout = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,

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
        return .{ .bytes = bytes, .allocator = allocator };
    }

    pub fn deinit(self: *Layout) void {
        c.Clay_SetCurrentContext(null);
        self.allocator.free(self.bytes);
    }

    pub fn resize(_: *Layout, width: f32, height: f32) void {
        c.Clay_SetLayoutDimensions(.{ .width = width, .height = height });
    }

    pub const Shell = struct {
        sidebar: c.Clay_BoundingBox,
        header: c.Clay_BoundingBox,
        conversation: c.Clay_BoundingBox,
        composer: c.Clay_BoundingBox,
    };

    pub fn shell(_: *Layout, sidebar_width: f32, header_height: f32, composer_height: f32) Shell {
        c.Clay_BeginLayout();
        open("shell", grow(), grow(), c.CLAY_LEFT_TO_RIGHT);
        open("sidebar", fixed(sidebar_width), grow(), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        open("workspace", grow(), grow(), c.CLAY_TOP_TO_BOTTOM);
        open("header", grow(), fixed(header_height), c.CLAY_LEFT_TO_RIGHT);
        c.Clay__CloseElement();
        open("conversation", grow(), grow(), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        open("composer", grow(), fixed(composer_height), c.CLAY_TOP_TO_BOTTOM);
        c.Clay__CloseElement();
        c.Clay__CloseElement();
        c.Clay__CloseElement();
        _ = c.Clay_EndLayout();
        return .{
            .sidebar = bounds("sidebar"), .header = bounds("header"),
            .conversation = bounds("conversation"), .composer = bounds("composer"),
        };
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
