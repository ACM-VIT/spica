const std = @import("std");
const c = @import("native/bindings.zig").c;
const Clay = @import("ui/clay.zig").Layout;

pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    layout: Clay,
    text: *c.SpicaText,
    draft: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    running: bool = true,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator) !App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitialization;
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow("Spica", 1280, 800, c.SDL_WINDOW_RESIZABLE) orelse return error.WindowCreation;
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_SetWindowMinimumSize(window, 800, 560);
        const renderer = c.SDL_CreateRenderer(window, null) orelse return error.RendererCreation;
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.FontInitialization;
        errdefer c.spica_text_destroy(text);
        var layout = try Clay.init(allocator, 1280, 800);
        errdefer layout.deinit();
        _ = c.SDL_StartTextInput(window);
        return .{ .window = window, .renderer = renderer, .layout = layout, .text = text, .allocator = allocator };
    }

    pub fn deinit(self: *App) void {
        _ = c.SDL_StopTextInput(self.window);
        self.draft.deinit(self.allocator);
        self.preedit.deinit(self.allocator);
        self.layout.deinit();
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    fn rect(self: *App, x: f32, y: f32, w: f32, h: f32, color: [3]u8) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, color[0], color[1], color[2], 255);
        _ = c.SDL_RenderFillRect(self.renderer, &c.SDL_FRect{ .x = x, .y = y, .w = w, .h = h });
    }

    fn paint(self: *App) void {
        var width: c_int = 1280;
        var height: c_int = 800;
        _ = c.SDL_GetWindowSize(self.window, &width, &height);
        self.layout.resize(@floatFromInt(width), @floatFromInt(height));
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        self.rect(0, 0, w, h, .{ 20, 23, 27 });
        self.rect(0, 0, 248, h, .{ 27, 32, 39 });
        self.rect(248, 0, w - 248, 48, .{ 35, 42, 51 });
        self.rect(272, h - 130, @max(0, w - 296), 106, .{ 35, 42, 51 });
        self.rect(248, h - 1, w - 248, 1, .{ 52, 62, 75 });
        _ = c.spica_text_draw(self.text, "Spica", 5, 24, 28, .{ .r = 231, .g = 237, .b = 245, .a = 255 });
        _ = c.spica_text_draw(self.text, "Workspace", 9, 272, 28, .{ .r = 231, .g = 237, .b = 245, .a = 255 });
        _ = c.spica_text_draw(self.text, "Compose", 7, 288, h - 92, .{ .r = 168, .g = 179, .b = 194, .a = 255 });
        const visible = if (self.draft.items.len == 0) "Type a message..." else self.draft.items;
        _ = c.spica_text_draw(self.text, visible.ptr, visible.len, 288, h - 62, .{ .r = 231, .g = 237, .b = 245, .a = 255 });
        if (self.preedit.items.len != 0)
            _ = c.spica_text_draw(self.text, self.preedit.items.ptr, self.preedit.items.len, 288, h - 37, .{ .r = 138, .g = 180, .b = 248, .a = 255 });
        _ = c.SDL_RenderPresent(self.renderer);
        self.dirty = false;
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            if (self.dirty) self.paint();
            var event: c.SDL_Event = undefined;
            if (!c.SDL_WaitEventTimeout(&event, -1)) return error.EventWait;
            try self.handle(&event);
            while (c.SDL_PollEvent(&event)) try self.handle(&event);
        }
    }

    fn handle(self: *App, event: *const c.SDL_Event) !void {
        switch (event.type) {
            c.SDL_EVENT_QUIT => self.running = false,
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_WINDOW_RESIZED => self.dirty = true,
            c.SDL_EVENT_TEXT_INPUT => {
                const bytes = std.mem.span(event.text.text);
                if (bytes.len > 65536 - self.draft.items.len) return error.DraftBudgetExceeded;
                try self.draft.appendSlice(self.allocator, bytes);
                self.preedit.clearRetainingCapacity();
                self.dirty = true;
            },
            c.SDL_EVENT_TEXT_EDITING => {
                const bytes = std.mem.span(event.edit.text);
                if (bytes.len > 4096) return error.PreeditBudgetExceeded;
                self.preedit.clearRetainingCapacity();
                try self.preedit.appendSlice(self.allocator, bytes);
                self.dirty = true;
            },
            else => {},
        }
    }
};
