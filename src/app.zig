const std = @import("std");
const builtin = @import("builtin");
const c = @import("native/bindings.zig").c;
const Layout = @import("ui/clay.zig").Layout;
const Coding = @import("ui/coding.zig").View;
const build_options = @import("build_options");
const telemetry = @import("native/metrics.zig");
const automation = @import("native/automation.zig");

/// Native lifetime and input dispatch. Replaceable presentation owns no domain.
pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    text: *c.SpicaText,
    layout: Layout,
    view: Coding,
    running: bool = true,
    dirty: bool = true,
    minimized: bool = false,
    frames: u64 = 0,
    metrics: ?telemetry.Metrics = null,
    snapshot: automation.Snapshot = .{},

    pub fn init(allocator: std.mem.Allocator) !App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitialization;
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow("Spica", 1100, 740, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return error.WindowCreation;
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
        var view = try Coding.init(allocator);
        errdefer view.deinit();
        if (!c.SDL_StartTextInput(window)) return error.TextInputStart;
        std.log.info("Spica ready; renderer={s}; video={s}", .{ c.SDL_GetRendererName(renderer), c.SDL_GetCurrentVideoDriver() });
        return .{ .window = window, .renderer = renderer, .text = text, .layout = layout, .view = view };
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
        if (self.metrics) |*metrics| metrics.begin_ns = c.SDL_GetTicksNS();
        defer {
            if (self.metrics) |*metrics| metrics.end_ns = c.SDL_GetTicksNS();
            self.snapshot.running = false;
        }
        while (self.running) {
            if (deadline) |due| if (c.SDL_GetTicks() >= due) {
                self.snapshot.close_reason = "deadline";
                break;
            };
            if (self.dirty and !self.minimized) {
                try self.paint();
                self.dirty = false;
            }
            var event: c.SDL_Event = undefined;
            if (deadline) |due| {
                const now = c.SDL_GetTicks();
                if (now >= due) {
                    self.snapshot.close_reason = "deadline";
                    break;
                }
                const timeout: c_int = @intCast(@min(due - now, std.math.maxInt(c_int)));
                _ = c.SDL_ClearError();
                if (!c.SDL_WaitEventTimeout(&event, timeout)) {
                    if (c.SDL_GetError()[0] != 0) return error.EventWait;
                    continue;
                }
            } else if (!c.SDL_WaitEvent(&event)) return error.EventWait;
            try self.handle(event);
            while (c.SDL_PollEvent(&event)) try self.handle(event);
        }
        std.log.info("Spica foundation stopped; frames={d}", .{self.frames});
    }

    fn handle(self: *App, event: c.SDL_Event) !void {
        self.snapshot.event_sequence += 1;
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                self.snapshot.close_reason = "window_close";
                self.running = false;
            },
            c.SDL_EVENT_KEY_DOWN => if (event.key.key == c.SDLK_Q and event.key.mod & c.SDL_KMOD_CTRL != 0) {
                self.snapshot.close_reason = "ctrl_q";
                self.running = false;
            },
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
                self.snapshot.resize_events += 1;
                self.snapshot.generation += 1;
                self.dirty = true;
            },
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_RENDER_TARGETS_RESET, c.SDL_EVENT_RENDER_DEVICE_RESET => self.dirty = true,
            c.SDL_EVENT_WINDOW_MINIMIZED => self.minimized = true,
            c.SDL_EVENT_WINDOW_RESTORED, c.SDL_EVENT_WINDOW_SHOWN => {
                self.minimized = false;
                self.dirty = true;
            },
            else => {},
        }
        const changed = self.view.handle(event, self.window, self.text) catch |err| switch (err) {
            error.TextTooLarge, error.PieceLimit, error.InvalidUtf8, error.ClipboardRead, error.ClipboardWrite, error.ClipboardContainsNul => blk: {
                self.view.notice = @errorName(err);
                self.snapshot.admission_errors += 1;
                self.snapshot.last_admission_error = @errorName(err);
                break :blk true;
            },
            else => return err,
        };
        self.dirty = self.dirty or changed;
    }

    fn paint(self: *App) !void {
        const paint_begin = if (self.metrics != null) c.SDL_GetTicksNS() else 0;
        var width: c_int = 0;
        var height: c_int = 0;
        var pixel_width: c_int = 0;
        var pixel_height: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &width, &height) or !c.SDL_GetRenderOutputSize(self.renderer, &pixel_width, &pixel_height)) return error.WindowSize;
        if (width <= 0 or height <= 0 or pixel_width <= 0 or pixel_height <= 0) return;
        self.snapshot.logical_width = width;
        self.snapshot.logical_height = height;
        self.snapshot.output_width = pixel_width;
        self.snapshot.output_height = pixel_height;
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        const scale_x = @as(f32, @floatFromInt(pixel_width)) / w;
        const scale_y = @as(f32, @floatFromInt(pixel_height)) / h;
        if (!c.SDL_SetRenderScale(self.renderer, scale_x, scale_y) or !c.spica_text_set_render_scale(self.text, scale_x, scale_y)) return error.RenderScale;
        self.layout.resize(w, h);
        try self.view.draw(self.renderer, self.text, self.window, self.layout.coding(w));
        self.snapshot.draft = self.view.editor.textBytes();
        self.snapshot.caret = self.view.editor.caret;
        self.snapshot.anchor = self.view.editor.anchor;
        self.snapshot.editor_focused = self.view.focused;
        self.snapshot.preedit_bytes = self.view.preedit_len;
        self.snapshot.draft_revision = self.view.revision;
        const editor_bounds = self.view.editor_view.bounds;
        self.snapshot.targets[1].pointer_bounds = .{ @intFromFloat(editor_bounds.x), @intFromFloat(editor_bounds.y), @intFromFloat(editor_bounds.w), @intFromFloat(editor_bounds.h) };
        const present_begin = if (self.metrics != null) c.SDL_GetTicksNS() else 0;
        const succeeded = c.SDL_RenderPresent(self.renderer);
        const present_end = if (self.metrics != null) c.SDL_GetTicksNS() else 0;
        if (self.metrics) |*metrics| {
            // Accessor only copies the existing ledger. Sampling is outside the
            // measured paint/present interval and never schedules idle redraws.
            var stats: c.SpicaTextStats = undefined;
            const stats_ok = c.spica_text_get_stats(self.text, &stats);
            metrics.record(.{
                .frame_id = self.frames + 1,
                .event_sequence = self.snapshot.event_sequence,
                .paint_begin_ns = paint_begin,
                .present_begin_ns = present_begin,
                .present_end_ns = present_end,
                .succeeded = succeeded,
                .text_stats = if (stats_ok) .{
                    .fixed_cpu_bytes = stats.fixed_cpu_bytes,
                    .font_bytes = stats.font_bytes,
                    .layout_bytes = stats.layout_bytes,
                    .glyph_bytes = stats.glyph_bytes,
                    .live_layouts = stats.live_layouts,
                    .glyph_count = stats.glyph_count,
                    .face_count = stats.face_count,
                } else null,
            });
        }
        if (!succeeded) return error.RenderPresent;
        self.frames += 1;
        self.snapshot.frame_id = self.frames;
    }
};

test "ordinary text admission failure stays local and preserves draft and undo" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    app.snapshot = .{};
    app.dirty = false;
    var full: [64 * 1024]u8 = @splat('x');
    try app.view.editor.setText(&full);
    app.view.editor.selectAll();
    try app.view.insert("retained", .paste);
    try std.testing.expect(app.view.editor.undo());
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    app.view.editor.setCaret(app.view.editor.len, false);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "extra";
    try app.handle(event);
    try std.testing.expectEqualStrings("TextTooLarge", app.view.notice.?);
    try std.testing.expectEqualSlices(u8, &full, app.view.editor.textBytes());
    try std.testing.expect(app.view.editor.redo());
    try std.testing.expectEqualStrings("retained", app.view.editor.textBytes());
}
