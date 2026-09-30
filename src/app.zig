const std = @import("std");
const builtin = @import("builtin");
const c = @import("native/bindings.zig").c;
const Clay = @import("ui/clay.zig").Layout;
const theme_module = @import("ui/theme.zig");
const DocumentView = @import("ui/document.zig").View;
const widgets = @import("ui/widgets.zig");
const Composer = @import("text/composer.zig").Composer;
const ContentWorker = @import("content/worker.zig");
const Draft = @import("core/draft.zig");
const Options = @import("options.zig").Options;
const Paths = @import("platform/paths.zig").Paths;
const fixture = @import("diagnostics/fixture.zig");

const Label = struct { bytes: [128]u8 = undefined, len: usize = 0, size: c_uint = 0, layout: ?*c.SpicaTextLayout = null };

pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    layout: Clay,
    text: *c.SpicaText,
    theme: theme_module.Theme,
    editor: Composer,
    editor_layout: ?*c.SpicaTextLayout = null,
    editor_width: f32 = 0,
    editor_start: usize = 0,
    editor_end: usize = 0,
    editor_scroll: f32 = 0,
    editor_changed: bool = true,
    copy_buffer: []u8,
    preedit: std.ArrayList(u8) = .empty,
    labels: [32]Label = [_]Label{.{}} ** 32,
    next_label: usize = 0,
    content: *ContentWorker.Worker,
    draft_writer: *Draft.Writer,
    document: ?ContentWorker.Ready = null,
    document_view: DocumentView,
    image_texture: ?*c.SDL_Texture = null,
    image_width: f32 = 0,
    image_height: f32 = 0,
    paths: Paths,
    options: Options,
    io: std.Io,
    allocator: std.mem.Allocator,
    running: bool = true,
    dirty: bool = true,
    minimized: bool = false,
    focused_editor: bool = true,
    dragging: bool = false,
    light: bool = false,
    selected_message: usize = fixture.message_count - 1,
    generation: u64 = 0,
    scroll: f32 = 0,
    wake_event: u32,
    shell: Clay.Shell = undefined,
    error_text: [512]u8 = undefined,
    error_len: usize = 0,
    draft_due: ?u64 = null,
    quit_due: ?u64 = null,
    captured: bool = false,
    presented: bool = false,
    frames: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !App {
        var paths = try Paths.init(allocator, io, environ, options.data_dir);
        errdefer paths.deinit();
        const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "assets/theme.json", allocator, .limited(16384));
        defer allocator.free(theme_bytes);
        const theme = try theme_module.parse(allocator, theme_bytes);
        var restored = try Draft.restore(io, paths.state);
        defer restored.deinit();
        var editor = try Composer.init(allocator);
        errdefer editor.deinit();
        try editor.setText(restored.value().draft);
        const copy_buffer = try allocator.alloc(u8, 65537);
        errdefer allocator.free(copy_buffer);
        if (!c.spica_image_install_sdl_allocator()) return error.SDLAllocatorInstallation;
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL video initialization: {s}", .{c.SDL_GetError()});
            return error.SDLInitialization;
        }
        errdefer c.SDL_Quit();
        if (options.renderer == .software) _ = c.SDL_SetHint(c.SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
        const window = c.SDL_CreateWindow("Spica", 1280, 800, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return error.WindowCreation;
        errdefer c.SDL_DestroyWindow(window);
        _ = c.SDL_SetWindowMinimumSize(window, 800, 560);
        const native_renderer = switch (builtin.os.tag) { .linux => "opengl", .windows => "direct3d11", .macos => "metal", else => null };
        const renderer = c.SDL_CreateRenderer(window, if (options.renderer == .software) "software" else native_renderer) orelse {
            std.log.err("SDL renderer: {s}", .{c.SDL_GetError()});
            return error.RendererCreation;
        };
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.FontInitialization;
        errdefer c.spica_text_destroy(text);
        if (!c.spica_text_set_monospace(text, ".deps/install/fonts/JetBrainsMono-Regular.ttf")) return error.FontInitialization;
        inline for (.{ "InterVariable-Italic.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf", "JetBrainsMono-BoldItalic.ttf" }) |font| {
            if (!c.spica_text_add_fallback(text, ".deps/install/fonts/" ++ font, 0)) return error.FontInitialization;
        }
        var layout = try Clay.init(allocator, 1280, 800);
        errdefer layout.deinit();
        const wake_event = c.SDL_RegisterEvents(1);
        if (wake_event == 0) return error.EventRegistration;
        const content = try ContentWorker.Worker.create(io, paths.database, options.fixture, wake_event);
        errdefer content.destroy();
        const draft_writer = try Draft.Writer.create(io, paths.state, wake_event);
        errdefer draft_writer.destroy();
        if (!c.SDL_StartTextInput(window)) return error.TextInputInitialization;
        return .{
            .window = window, .renderer = renderer, .layout = layout, .text = text, .theme = theme,
            .editor = editor, .copy_buffer = copy_buffer,
            .content = content, .draft_writer = draft_writer, .document_view = DocumentView.init(allocator),
            .paths = paths, .options = options, .io = io, .allocator = allocator, .wake_event = wake_event,
            .light = options.light or restored.value().light,
            .selected_message = @min(restored.value().selected_message, fixture.message_count - 1),
            .quit_due = if (options.quit_after_ms) |ms| c.SDL_GetTicks() + ms else null,
        };
    }

    pub fn deinit(self: *App) void {
        self.saveDraft() catch |err| std.log.err("final draft queue: {s}", .{@errorName(err)});
        self.draft_writer.destroy();
        self.content.destroy();
        _ = c.SDL_StopTextInput(self.window);
        if (self.editor_layout) |layout| c.spica_text_layout_release(layout);
        for (self.labels) |label_value| if (label_value.layout) |layout| c.spica_text_layout_release(layout);
        self.document_view.deinit();
        if (self.document) |*document| document.deinit();
        if (self.image_texture) |texture| c.SDL_DestroyTexture(texture);
        self.editor.deinit();
        self.allocator.free(self.copy_buffer);
        self.preedit.deinit(self.allocator);
        self.layout.deinit();
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.paths.deinit();
    }

    fn palette(self: *App) theme_module.Palette { return if (self.light) self.theme.light else self.theme.dark; }
    fn rgba(color: theme_module.Color) c.SDL_Color { return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 }; }
    fn rectangle(self: *App, x: f32, y: f32, width: f32, height: f32, radius: f32, color: theme_module.Color) !void {
        try widgets.panel(self.renderer, .{ .x = x, .y = y, .w = width, .h = height }, radius, color);
    }
    fn label(self: *App, bytes: []const u8, x: f32, top: f32, size: c_uint, color: theme_module.Color) !void {
        if (bytes.len > 128) return error.LabelTooLong;
        var found: ?*Label = null;
        for (&self.labels) |*value| {
            if (value.layout != null and value.size == size and std.mem.eql(u8, value.bytes[0..value.len], bytes)) { found = value; break; }
        }
        const value = found orelse blk: {
            const replacement = &self.labels[self.next_label];
            self.next_label = (self.next_label + 1) % self.labels.len;
            if (replacement.layout) |layout| c.spica_text_layout_release(layout);
            replacement.layout = null;
            const layout = c.spica_text_layout_create(self.text, bytes.ptr, bytes.len, 2000, size, false) orelse return error.LabelLayout;
            @memcpy(replacement.bytes[0..bytes.len], bytes);
            replacement.len = bytes.len;
            replacement.size = size;
            replacement.layout = layout;
            break :blk replacement;
        };
        if (!c.spica_text_layout_draw(self.text, value.layout.?, x, top, rgba(color))) return error.LabelDraw;
    }

    fn report(self: *App, operation: []const u8, err: anyerror) void {
        const text = std.fmt.bufPrint(&self.error_text, "{s}: {s}", .{ operation, @errorName(err) }) catch "Error message exceeds display budget";
        self.error_len = text.len;
        std.log.err("{s}; SDL: {s}", .{ text, c.SDL_GetError() });
        self.dirty = true;
    }

    fn requestMessage(self: *App, ordinal: usize) void {
        if (!self.options.fixture) return;
        self.selected_message = @min(ordinal, fixture.message_count - 1);
        self.generation += 1;
        self.content.request(.{ .generation = self.generation, .ordinal = self.selected_message });
        self.draft_due = c.SDL_GetTicks() + 250;
    }

    fn consume(self: *App) void {
        if (self.draft_writer.takeError()) |err| self.report("Draft could not be saved", err);
        if (self.content.take()) |result_value| {
            var result = result_value;
            switch (result) {
                .failure => |err| self.report("Loading conversation", err),
                .ready => |*ready| {
                    if (ready.generation != self.generation or self.minimized) { result.deinit(); return; }
                    self.document_view.clear();
                    if (self.document) |*old| old.deinit();
                    if (self.image_texture) |texture| c.SDL_DestroyTexture(texture);
                    self.image_texture = null;
                    self.image_height = 0;
                    self.image_width = 0;
                    if (ready.image.pixels != null) {
                        const texture = c.SDL_CreateTexture(self.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, ready.image.width, ready.image.height);
                        if (texture) |created| {
                            if (c.SDL_UpdateTexture(created, null, ready.image.pixels, ready.image.stride) and c.SDL_SetTextureScaleMode(created, c.SDL_SCALEMODE_LINEAR)) {
                                self.image_texture = created;
                                self.image_width = @floatFromInt(ready.image.width);
                                self.image_height = @floatFromInt(ready.image.height);
                            } else { c.SDL_DestroyTexture(created); self.report("Uploading image", error.ImageUpload); }
                        } else self.report("Creating image texture", error.ImageUpload);
                        c.spica_image_release(&ready.image);
                    } else if (ready.image_status != c.SPICA_IMAGE_OK) self.report("Decoding image", error.ImageDecode);
                    self.document = ready.*;
                    self.scroll = 0;
                    self.dirty = true;
                },
            }
        }
    }

    fn saveDraft(self: *App) !void {
        const bytes = self.editor.textBytes();
        try self.draft_writer.submit(.{ .draft = bytes, .selected_message = self.selected_message, .light = self.light });
        self.draft_due = null;
    }
    fn edited(self: *App) void {
        self.editor_changed = true;
        self.draft_due = c.SDL_GetTicks() + 250;
        self.dirty = true;
    }
    fn reloadTheme(self: *App) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, "assets/theme.json", self.allocator, .limited(16384));
        defer self.allocator.free(bytes);
        const next = try theme_module.parse(self.allocator, bytes);
        self.theme = next;
        self.document_view.width = 0;
        self.editor_width = 0;
        self.error_len = 0;
        self.dirty = true;
    }

    fn paint(self: *App) !void {
        var width: c_int = 1280;
        var height: c_int = 800;
        _ = c.SDL_GetWindowSize(self.window, &width, &height);
        if (!c.SDL_SetRenderLogicalPresentation(self.renderer, width, height, c.SDL_LOGICAL_PRESENTATION_STRETCH)) return error.LogicalPresentation;
        self.layout.resize(@floatFromInt(width), @floatFromInt(height));
        const colors = self.palette();
        self.shell = self.layout.shell(@min(self.theme.metrics.sidebar_width, @as(f32, @floatFromInt(width)) * 0.28), 64, 176);
        const sidebar = self.shell.sidebar;
        const header = self.shell.header;
        const conversation = self.shell.conversation;
        const composer = self.shell.composer;
        try self.rectangle(0, 0, @floatFromInt(width), @floatFromInt(height), 0, colors.canvas);
        try self.rectangle(sidebar.x, sidebar.y, sidebar.width, sidebar.height, 0, colors.panel);
        try self.rectangle(sidebar.width - 1, 0, 1, @floatFromInt(height), 0, colors.border);
        try self.label("Spica", 24, 22, 24, colors.text);
        try self.label("LOCAL WORKSPACE", 24, 76, 11, colors.muted);
        try self.rectangle(12, 107, sidebar.width - 24, 58, 8, colors.raised);
        try self.label(if (self.options.fixture) "Resource scene" else "No runtime attached", 24, 119, 15, colors.text);
        try self.label(if (self.options.fixture) "200 saved messages" else "Drafts are saved locally", 24, 143, 11, colors.muted);
        try self.label("NATIVE RENDERER", 24, @as(f32, @floatFromInt(height)) - 74, 10, colors.muted);
        try self.label(std.mem.span(c.SDL_GetRendererName(self.renderer)), 24, @as(f32, @floatFromInt(height)) - 50, 13, colors.text);
        try self.rectangle(header.x, header.y + header.height - 1, header.width, 1, 0, colors.border);
        try self.label(if (self.options.fixture) "Resource acceptance scene" else "Conversation", header.x + 28, 18, 18, colors.text);
        try self.label(if (self.options.fixture) "Local fixture · no provider or pi process" else "No agent is running · no prompts are sent", header.x + 28, 41, 11, colors.muted);
        try self.label(if (self.light) "Dark · Ctrl+L" else "Light · Ctrl+L", header.x + header.width - 130, 25, 12, colors.accent);

        const content_width = @min(self.theme.metrics.chat_max_width, conversation.width - 64);
        const content_x = conversation.x + (conversation.width - content_width) / 2;
        const viewport_height = conversation.height - 48;
        const clip = c.SDL_Rect{ .x = @intFromFloat(conversation.x + 16), .y = @intFromFloat(conversation.y + 12), .w = @intFromFloat(conversation.width - 32), .h = @intFromFloat(conversation.height - 24) };
        if (!c.SDL_SetRenderClipRect(self.renderer, &clip)) return error.ClipRectangle;
        if (self.document) |*ready| {
            const doc = &ready.document;
            if (doc.state == .display_budget) {
                try self.label("Rich formatting exceeds the display budget", content_x, conversation.y + 28, 15, colors.error_color);
            } else {
                if (self.document_view.width != content_width) try self.document_view.rebuild(doc, content_width);
                try self.document_view.prepare(self.text, doc, self.scroll, viewport_height, self.theme.metrics);
                self.scroll = @min(self.scroll, @max(0, self.document_view.height + self.image_height + 64 - viewport_height));
                try self.document_view.draw(self.text, self.renderer, doc, ready.highlights.items, content_x, conversation.y + 24 - self.scroll, colors, self.light);
                if (self.image_texture) |texture| {
                    const scale = @min(1, content_width / self.image_width);
                    const destination = c.SDL_FRect{ .x = content_x, .y = conversation.y + 36 - self.scroll + self.document_view.height, .w = self.image_width * scale, .h = self.image_height * scale };
                    if (!c.SDL_RenderTexture(self.renderer, texture, null, &destination)) return error.ImageDraw;
                }
            }
        } else {
            try self.label(if (self.options.fixture) "Loading disk-backed conversation..." else "A native home for your coding agents", content_x, conversation.y + 48, 20, colors.text);
            try self.label(if (self.options.fixture) "The content worker parses away from the UI thread." else "The resource gate precedes connection to real pi sessions.", content_x, conversation.y + 84, 14, colors.muted);
        }
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
        const editor_x = composer.x + 28;
        const editor_y = composer.y + 34;
        const editor_width = composer.width - 56;
        try self.rectangle(editor_x, editor_y, editor_width, 100, 10, colors.border);
        try self.rectangle(editor_x + 1, editor_y + 1, editor_width - 2, 98, 9, colors.raised);
        try self.label("Draft · no runtime attached", editor_x + 12, composer.y + 10, 11, colors.muted);
        if (self.editor_changed or self.editor_width != editor_width or self.editor.caret < self.editor_start or self.editor.caret > self.editor_end) {
            if (self.editor_layout) |layout| c.spica_text_layout_release(layout);
            self.editor_layout = null;
            const bytes = self.editor.textBytes();
            const range = self.editor.viewportRange(8192);
            if (range.start != self.editor_start) self.editor_scroll = 0;
            self.editor_start = range.start;
            self.editor_end = range.end;
            const slice = bytes[range.start..range.end];
            self.editor_layout = c.spica_text_layout_create(self.text, slice.ptr, slice.len, editor_width - 24, @intFromFloat(self.theme.metrics.body_px), false) orelse return error.EditorLayout;
            self.editor_width = editor_width;
            self.editor_changed = false;
        }
        const editor_clip = c.SDL_Rect{ .x = @intFromFloat(editor_x + 8), .y = @intFromFloat(editor_y + 8), .w = @intFromFloat(editor_width - 16), .h = 84 };
        _ = c.SDL_SetRenderClipRect(self.renderer, &editor_clip);
        if (self.editor_layout) |layout| {
            var caret: c.SDL_FRect = undefined;
            if (c.spica_text_layout_caret(layout, self.editor.caret - self.editor_start, &caret)) {
                self.editor_scroll = @max(0, @min(self.editor_scroll, caret.y));
                if (caret.y + caret.h > self.editor_scroll + 76) self.editor_scroll = caret.y + caret.h - 76;
                if (self.focused_editor) try self.rectangle(editor_x + 12 + caret.x, editor_y + 10 + caret.y - self.editor_scroll, 1, caret.h, 0, colors.accent);
                const input_area = c.SDL_Rect{ .x = @intFromFloat(editor_x + 12 + caret.x), .y = @intFromFloat(editor_y + 10 + caret.y - self.editor_scroll), .w = 1, .h = @intFromFloat(caret.h) };
                _ = c.SDL_SetTextInputArea(self.window, &input_area, 0);
            }
            if (!c.spica_text_layout_draw(self.text, layout, editor_x + 12, editor_y + 10 - self.editor_scroll, rgba(colors.text))) return error.EditorDraw;
            if (self.editor.len == 0) try self.label("Write a draft...", editor_x + 12, editor_y + 10, 15, colors.muted);
        }
        if (self.preedit.items.len != 0) try self.label(self.preedit.items[0..@min(128, self.preedit.items.len)], editor_x + 12, editor_y + 66, 15, colors.accent);
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
        var status_buffer: [128]u8 = undefined;
        const status = if (self.error_len != 0) self.error_text[0..@min(self.error_len, 128)] else if (self.options.fixture) try std.fmt.bufPrint(&status_buffer, "Message {d}/{d} · PageUp/PageDown · Wheel to scroll", .{ self.selected_message + 1, fixture.message_count }) else "Enter: newline · Ctrl+R: reload theme · Ctrl+Z: undo";
        try self.label(status, editor_x, composer.y + 145, 11, if (self.error_len != 0) colors.error_color else colors.muted);
        if (!self.captured and self.options.capture != null and (!self.options.fixture or self.document != null)) {
            const surface = c.SDL_RenderReadPixels(self.renderer, null) orelse return error.ScreenCapture;
            defer c.SDL_DestroySurface(surface);
            const path = try self.allocator.dupeZ(u8, self.options.capture.?);
            defer self.allocator.free(path);
            if (!c.IMG_SavePNG(surface, path.ptr)) return error.ScreenCapture;
            self.captured = true;
        }
        if (!c.SDL_RenderPresent(self.renderer)) return error.PresentFrame;
        self.frames += 1;
        if (!self.presented) {
            std.log.info("Spica ready; renderer={s}; video={s}; fixture={}; platform={s}; logical={d}x{d}; composer_bytes={d}", .{ c.SDL_GetRendererName(self.renderer), c.SDL_GetCurrentVideoDriver(), self.options.fixture, @tagName(builtin.os.tag), width, height, Composer.storageBytes });
            self.presented = true;
        }
        self.dirty = false;
    }

    pub fn run(self: *App) !void {
        self.requestMessage(self.selected_message);
        while (self.running) {
            self.consume();
            const now = c.SDL_GetTicks();
            if (self.quit_due) |due| if (now >= due) { self.running = false; continue; };
            if (self.draft_due) |due| if (now >= due) { self.saveDraft() catch |err| self.report("Saving draft", err); self.draft_due = null; };
            if (self.dirty and !self.minimized) try self.paint();
            var timeout: c_int = -1;
            if (self.quit_due) |due| timeout = @intCast(@min(2147483647, due -| c.SDL_GetTicks()));
            if (self.draft_due) |due| {
                const remaining: c_int = @intCast(@min(2147483647, due -| c.SDL_GetTicks()));
                timeout = if (timeout == -1) remaining else @min(timeout, remaining);
            }
            var event: c.SDL_Event = undefined;
            if (c.SDL_WaitEventTimeout(&event, timeout)) {
                self.handle(&event) catch |err| self.report("Input", err);
                while (c.SDL_PollEvent(&event)) self.handle(&event) catch |err| self.report("Input", err);
            } else if (timeout == -1) return error.EventWait;
        }
        std.log.info("Spica closed; presented_frames={d}", .{self.frames});
    }

    fn copySelection(self: *App) !void {
        const bytes = try self.editor.copySelection(self.copy_buffer[0..65536]);
        if (bytes.len == 0) return;
        self.copy_buffer[bytes.len] = 0;
        if (!c.SDL_SetClipboardText(@ptrCast(self.copy_buffer.ptr))) return error.ClipboardWrite;
    }

    fn handle(self: *App, event: *const c.SDL_Event) !void {
        if (event.type == self.wake_event) { self.consume(); return; }
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.running = false,
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => self.dirty = true,
            c.SDL_EVENT_WINDOW_MINIMIZED => self.minimized = true,
            c.SDL_EVENT_WINDOW_RESTORED => { self.minimized = false; self.dirty = true; self.requestMessage(self.selected_message); },
            c.SDL_EVENT_MOUSE_WHEEL => { self.scroll = @max(0, self.scroll - event.wheel.y * 44); self.dirty = true; },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const inside = event.button.x >= self.shell.composer.x + 28 and event.button.y >= self.shell.composer.y + 34 and event.button.y <= self.shell.composer.y + 134;
                self.focused_editor = inside;
                if (inside) {
                    _ = c.SDL_StartTextInput(self.window);
                    if (self.editor_layout) |layout| self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, event.button.x - self.shell.composer.x - 40, event.button.y - self.shell.composer.y - 44 + self.editor_scroll), (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
                    self.dragging = true;
                } else _ = c.SDL_StopTextInput(self.window);
                if (event.button.y < 64 and event.button.x > self.shell.header.x + self.shell.header.width - 140) { self.light = !self.light; self.draft_due = c.SDL_GetTicks() + 250; }
                self.dirty = true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => self.dragging = false,
            c.SDL_EVENT_MOUSE_MOTION => if (self.dragging) {
                if (self.editor_layout) |layout| self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, event.motion.x - self.shell.composer.x - 40, event.motion.y - self.shell.composer.y - 44 + self.editor_scroll), true);
                self.dirty = true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const command = (event.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
                const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
                if (event.key.key == c.SDLK_PAGEUP) { self.requestMessage(self.selected_message -| 1); return; }
                if (event.key.key == c.SDLK_PAGEDOWN) { self.requestMessage(self.selected_message + 1); return; }
                if (command and event.key.key == c.SDLK_L) { self.light = !self.light; self.dirty = true; self.draft_due = c.SDL_GetTicks() + 250; return; }
                if (command and event.key.key == c.SDLK_R) { try self.reloadTheme(); return; }
                if (!self.focused_editor) return;
                if (event.key.key == c.SDLK_ESCAPE) { self.preedit.clearRetainingCapacity(); _ = c.SDL_ClearComposition(self.window); self.dirty = true; return; }
                if (self.preedit.items.len != 0) return;
                if (command) {
                    switch (event.key.key) {
                        c.SDLK_A => { self.editor.selectAll(); self.dirty = true; },
                        c.SDLK_C => try self.copySelection(),
                        c.SDLK_X => { try self.copySelection(); try self.editor.insert("", .paste); self.edited(); },
                        c.SDLK_V => {
                            const clipboard = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                            defer c.SDL_free(clipboard);
                            try self.editor.insert(std.mem.span(clipboard), .paste);
                            self.edited();
                        },
                        c.SDLK_Z => { if (if (shift) self.editor.redo() else self.editor.undo()) self.edited(); },
                        c.SDLK_Y => { if (self.editor.redo()) self.edited(); },
                        c.SDLK_LEFT => { self.editor.moveWord(.backward, shift); self.dirty = true; },
                        c.SDLK_RIGHT => { self.editor.moveWord(.forward, shift); self.dirty = true; },
                        else => {},
                    }
                } else switch (event.key.key) {
                    c.SDLK_BACKSPACE => { try self.editor.backspace(); self.edited(); },
                    c.SDLK_DELETE => { try self.editor.deleteForward(); self.edited(); },
                    c.SDLK_LEFT => { self.editor.moveGrapheme(.backward, shift); self.dirty = true; },
                    c.SDLK_RIGHT => { self.editor.moveGrapheme(.forward, shift); self.dirty = true; },
                    c.SDLK_HOME => { self.editor.setCaret(0, shift); self.dirty = true; },
                    c.SDLK_END => { self.editor.setCaret(self.editor.len, shift); self.dirty = true; },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => { try self.editor.insert("\n", .paste); self.edited(); },
                    else => {},
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (!self.focused_editor) return;
                try self.editor.insert(std.mem.span(event.text.text), if (self.preedit.items.len != 0) .ime else .typing);
                self.preedit.clearRetainingCapacity();
                self.edited();
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
