const std = @import("std");
const builtin = @import("builtin");
const c = @import("native/bindings.zig").c;
const Layout = @import("ui/clay.zig").Layout;
const Foundation = @import("ui/foundation.zig").View;
const build_options = @import("build_options");

/// Native window lifecycle only. Future workspace state and agent execution
/// belong behind their own APIs; this starter owns no process or data store.
pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    text: *c.SpicaText,
    layout: Layout,
    view: Foundation = .{},
    running: bool = true,
    dirty: bool = true,
    minimized: bool = false,
    frames: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitialization;
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow("Spica — Native Foundation", 1100, 740, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return error.WindowCreation;
        errdefer c.SDL_DestroyWindow(window);
        if (!c.SDL_SetWindowMinimumSize(window, 720, 480)) return error.WindowMinimumSize;
        const driver: [*:0]const u8 = switch (builtin.os.tag) {
            .linux => "opengl",
            .macos => "metal",
            else => @compileError("The native foundation currently supports Linux and macOS"),
        };
        const renderer = c.SDL_CreateRenderer(window, driver) orelse return error.RendererCreation;
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, build_options.font_directory ++ "/Inter.ttf") orelse return error.FontInitialization;
        errdefer c.spica_text_destroy(text);
        // Preserve real faces and the engine's OS fallback path, shaping, bidi,
        // grapheme carets, bounded atlas, and device-pixel rasterization.
        if (!c.spica_text_set_monospace(text, build_options.font_directory ++ "/JetBrainsMono-Regular.ttf")) return error.FontInitialization;
        inline for (.{ "InterVariable-Italic.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf", "JetBrainsMono-BoldItalic.ttf" }) |font| {
            if (!c.spica_text_add_fallback(text, build_options.font_directory ++ "/" ++ font, 0)) return error.FontInitialization;
        }
        var layout = try Layout.init(allocator, 1100, 740);
        errdefer layout.deinit();
        std.log.info("Spica foundation ready; renderer={s}; video={s}", .{ c.SDL_GetRendererName(renderer), c.SDL_GetCurrentVideoDriver() });
        return .{ .window = window, .renderer = renderer, .text = text, .layout = layout };
    }

    pub fn deinit(self: *App) void {
        self.view.deinit();
        self.layout.deinit();
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn run(self: *App, quit_after_ms: ?u32) !void {
        const deadline: ?u64 = if (quit_after_ms) |ms| c.SDL_GetTicks() + ms else null;
        while (self.running) {
            if (deadline) |due| if (c.SDL_GetTicks() >= due) break;
            if (self.dirty and !self.minimized) {
                try self.paint();
                self.dirty = false;
            }
            var event: c.SDL_Event = undefined;
            if (deadline) |due| {
                const now = c.SDL_GetTicks();
                if (now >= due) break;
                const timeout: c_int = @intCast(@min(due - now, std.math.maxInt(c_int)));
                _ = c.SDL_ClearError();
                if (!c.SDL_WaitEventTimeout(&event, timeout)) {
                    if (c.SDL_GetError()[0] != 0) return error.EventWait;
                    continue;
                }
            } else if (!c.SDL_WaitEvent(&event)) return error.EventWait;
            self.handle(event);
            while (c.SDL_PollEvent(&event)) self.handle(event);
        }
        std.log.info("Spica foundation stopped; frames={d}", .{self.frames});
    }

    fn handle(self: *App, event: c.SDL_Event) void {
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.running = false,
            c.SDL_EVENT_KEY_DOWN => if (event.key.key == c.SDLK_ESCAPE) {
                self.running = false;
            },
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED, c.SDL_EVENT_RENDER_TARGETS_RESET, c.SDL_EVENT_RENDER_DEVICE_RESET => self.dirty = true,
            c.SDL_EVENT_WINDOW_MINIMIZED => self.minimized = true,
            c.SDL_EVENT_WINDOW_RESTORED, c.SDL_EVENT_WINDOW_SHOWN => {
                self.minimized = false;
                self.dirty = true;
            },
            else => {},
        }
    }

    fn paint(self: *App) !void {
        var width: c_int = 0;
        var height: c_int = 0;
        var pixel_width: c_int = 0;
        var pixel_height: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &width, &height) or !c.SDL_GetRenderOutputSize(self.renderer, &pixel_width, &pixel_height)) return error.WindowSize;
        if (width <= 0 or height <= 0 or pixel_width <= 0 or pixel_height <= 0) return;
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        const scale_x = @as(f32, @floatFromInt(pixel_width)) / w;
        const scale_y = @as(f32, @floatFromInt(pixel_height)) / h;
        if (!c.SDL_SetRenderScale(self.renderer, scale_x, scale_y) or !c.spica_text_set_render_scale(self.text, scale_x, scale_y)) return error.RenderScale;
        self.layout.resize(w, h);
        try self.view.draw(self.renderer, self.text, self.layout.foundation(w));
        if (!c.SDL_RenderPresent(self.renderer)) return error.RenderPresent;
        self.frames += 1;
    }
};
