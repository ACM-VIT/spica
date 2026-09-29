const std = @import("std");
const c = @import("native/bindings.zig").c;
const Clay = @import("ui/clay.zig").Layout;
const Theme = @import("ui/theme.zig").Theme;
const parseTheme = @import("ui/theme.zig").parse;
const beforeLastGrapheme = @import("text/edit.zig").beforeLastGrapheme;

pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    layout: Clay,
    text: *c.SpicaText,
    theme: Theme,
    draft: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    grapheme_scratch: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    running: bool = true,
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !App {
        const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "assets/theme.json", allocator, .limited(16384));
        defer allocator.free(theme_bytes);
        const theme = try parseTheme(allocator, theme_bytes);
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
        return .{ .window = window, .renderer = renderer, .layout = layout, .text = text, .theme = theme, .allocator = allocator };
    }

    pub fn deinit(self: *App) void {
        _ = c.SDL_StopTextInput(self.window);
        self.draft.deinit(self.allocator);
        self.preedit.deinit(self.allocator);
        self.grapheme_scratch.deinit(self.allocator);
        self.layout.deinit();
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    fn rect(self: *App, x: f32, y: f32, w: f32, h: f32, color: @import("ui/theme.zig").Color) void {
        _ = c.SDL_SetRenderDrawColor(self.renderer, color.r, color.g, color.b, 255);
        _ = c.SDL_RenderFillRect(self.renderer, &c.SDL_FRect{ .x = x, .y = y, .w = w, .h = h });
    }

    fn paint(self: *App) void {
        var width: c_int = 1280;
        var height: c_int = 800;
        _ = c.SDL_GetWindowSize(self.window, &width, &height);
        self.layout.resize(@floatFromInt(width), @floatFromInt(height));
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        const colors = self.theme.dark;
        const sidebar = self.theme.metrics.sidebar_width;
        const header = self.theme.metrics.header_height;
        self.rect(0, 0, w, h, colors.canvas);
        self.rect(0, 0, sidebar, h, colors.panel);
        self.rect(sidebar, 0, w - sidebar, header, colors.raised);
        self.rect(sidebar + 24, h - 130, @max(0, w - sidebar - 48), 106, colors.raised);
        self.rect(sidebar, h - 1, w - sidebar, 1, colors.border);
        const text_color = c.SDL_Color{ .r = colors.text.r, .g = colors.text.g, .b = colors.text.b, .a = 255 };
        const muted = c.SDL_Color{ .r = colors.muted.r, .g = colors.muted.g, .b = colors.muted.b, .a = 255 };
        _ = c.spica_text_draw(self.text, "Spica", 5, 24, 28, text_color);
        _ = c.spica_text_draw(self.text, "Workspace", 9, sidebar + 24, 28, text_color);
        _ = c.spica_text_draw(self.text, "Compose", 7, sidebar + 40, h - 92, muted);
        const visible = if (self.draft.items.len == 0) "Type a message..." else self.draft.items;
        _ = c.spica_text_draw(self.text, visible.ptr, visible.len, sidebar + 40, h - 62, text_color);
        if (self.preedit.items.len != 0)
            _ = c.spica_text_draw(self.text, self.preedit.items.ptr, self.preedit.items.len, sidebar + 40, h - 37, .{ .r = colors.accent.r, .g = colors.accent.g, .b = colors.accent.b, .a = 255 });
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
            c.SDL_EVENT_KEY_DOWN => {
                if (event.key.key == c.SDLK_BACKSPACE and self.preedit.items.len == 0 and self.draft.items.len != 0) {
                    try self.grapheme_scratch.resize(self.allocator, self.draft.items.len);
                    const end = try beforeLastGrapheme(self.draft.items, self.grapheme_scratch.items);
                    self.draft.shrinkRetainingCapacity(end);
                    self.dirty = true;
                }
            },
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
