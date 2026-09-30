const std = @import("std");
const builtin = @import("builtin");
const c = @import("native/bindings.zig").c;
const Clay = @import("ui/clay.zig").Layout;
const theme_module = @import("ui/theme.zig");
const TranscriptView = @import("ui/transcript.zig").View;
const widgets = @import("ui/widgets.zig");
const Composer = @import("text/composer.zig").Composer;
const ContentWorker = @import("content/worker.zig");
const Draft = @import("core/draft.zig");
const pi = @import("core/runtime.zig");
const Options = @import("options.zig").Options;
const Paths = @import("platform/paths.zig").Paths;
const fixture = @import("diagnostics/fixture.zig");
const build_options = @import("build_options");
const SessionCatalog = @import("core/catalog.zig");

const Label = struct { bytes: [128]u8 = undefined, len: usize = 0, size: c_uint = 0, layout: ?*c.SpicaTextLayout = null, used: u64 = 0 };
const Action = union(enum) { start, new_thread, sidebar, open_thread: usize, send, stop, theme, mode, behavior, latest, models, select_model: usize, thinking, select_thinking: usize, disclosure: @import("ui/transcript.zig").Toggle, force_stop, wait };
const ThreadTarget = struct { path: [:0]u8, cwd: [:0]u8 };
const Button = struct { bounds: c.SDL_FRect, action: Action };

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
    preferred_caret_x: ?f32 = null,
    editor_changed: bool = true,
    copy_buffer: []u8,
    preedit: std.ArrayList(u8) = .empty,
    labels: [64]Label = [_]Label{.{}} ** 64,
    label_clock: u64 = 0,
    content: *ContentWorker.Worker,
    draft_writer: *Draft.Writer,
    runtime: ?*pi.Runtime = null,
    runtime_snapshot: ?pi.Snapshot = null,
    closing: bool = false,
    force_dialog: bool = false,
    model_menu: bool = false,
    model_first: usize = 0,
    thinking_menu: bool = false,
    sidebar_visible: bool = true,
    editor_bounds: c.SDL_FRect = undefined,
    model_bounds: c.SDL_FRect = undefined,
    thinking_bounds: c.SDL_FRect = undefined,
    composer_bounds: c.SDL_FRect = undefined,
    thread_title: [128]u8 = undefined,
    thread_title_len: usize = 0,
    run_started: ?u64 = null,
    run_base_revision: u64 = 0,
    run_elapsed: ?u64 = null,
    bash_mode: bool = false,
    behavior: pi.Behavior = .prompt,
    draft_revision: u64 = 0,
    submitted_prompt: ?struct { token: u64, draft_revision: u64 } = null,
    accepted_clear_revision: ?u64 = null,
    buttons: [64]Button = undefined,
    button_count: usize = 0,
    follow_bottom: bool = false,
    transcript: TranscriptView,
    catalog_worker: *SessionCatalog.Worker,
    catalog: ?SessionCatalog.Catalog = null,
    sidebar_first: usize = 0,
    pending_thread: ?ThreadTarget = null,
    resume_path: ?[:0]u8 = null,
    conversation_dirty: bool = false,
    content_pending: bool = false,
    pending_ordinal: ?usize = null,
    last_content_metadata: bool = false,
    paths: Paths,
    project_path: [:0]u8,
    options: Options,
    io: std.Io,
    allocator: std.mem.Allocator,
    running: bool = true,
    dirty: bool = true,
    minimized: bool = false,
    focused_editor: bool = true,
    dragging: bool = false,
    light: bool = false,
    generation: u64 = 0,
    scroll: f32 = 0,
    wake_event: u32,
    shell: Clay.Shell = undefined,
    error_text: [512]u8 = undefined,
    error_len: usize = 0,
    formatting_error: bool = false,
    draft_due: ?u64 = null,
    quit_due: ?u64 = null,
    captured: bool = false,
    presented: bool = false,
    frames: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) !App {
        var paths = try Paths.init(allocator, io, environ, options.data_dir);
        errdefer paths.deinit();
        const project_path = if (options.fixture) try allocator.dupeZ(u8, options.project) else try std.Io.Dir.cwd().realPathFileAlloc(io, options.project, allocator);
        errdefer allocator.free(project_path);
        const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(io, build_options.asset_directory ++ "/theme.json", allocator, .limited(16384));
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
        const native_renderer = switch (builtin.os.tag) {
            .linux => "opengl",
            .windows => "direct3d11",
            .macos => "metal",
            else => null,
        };
        const renderer = c.SDL_CreateRenderer(window, if (options.renderer == .software) "software" else native_renderer) orelse {
            std.log.err("SDL renderer: {s}", .{c.SDL_GetError()});
            return error.RendererCreation;
        };
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, build_options.font_directory ++ "/Inter.ttf") orelse return error.FontInitialization;
        errdefer c.spica_text_destroy(text);
        if (!c.spica_text_set_monospace(text, build_options.font_directory ++ "/JetBrainsMono-Regular.ttf")) return error.FontInitialization;
        inline for (.{ "InterVariable-Italic.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf", "JetBrainsMono-BoldItalic.ttf" }) |font| {
            if (!c.spica_text_add_fallback(text, build_options.font_directory ++ "/" ++ font, 0)) return error.FontInitialization;
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
        const legacy_sessions = try std.fs.path.join(allocator, &.{ paths.data, "pi-sessions" });
        defer allocator.free(legacy_sessions);
        const catalog_worker = try SessionCatalog.Worker.create(io, environ, legacy_sessions, wake_event);
        errdefer catalog_worker.destroy();
        return .{
            .window = window,
            .renderer = renderer,
            .layout = layout,
            .text = text,
            .theme = theme,
            .editor = editor,
            .copy_buffer = copy_buffer,
            .content = content,
            .draft_writer = draft_writer,
            .transcript = TranscriptView.init(allocator),
            .catalog_worker = catalog_worker,
            .paths = paths,
            .options = options,
            .io = io,
            .allocator = allocator,
            .wake_event = wake_event,
            .project_path = project_path,
            .light = options.light or restored.value().light,
            .follow_bottom = true,
            .quit_due = if (options.quit_after_ms) |ms| c.SDL_GetTicks() + ms else null,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.runtime) |runtime| runtime.destroy() catch |err| std.log.err("Runtime shutdown invariant: {s}", .{@errorName(err)});
        if (self.runtime_snapshot) |*snapshot| snapshot.deinit();
        self.saveDraft() catch |err| std.log.err("final draft queue: {s}", .{@errorName(err)});
        self.draft_writer.destroy();
        self.content.destroy();
        self.catalog_worker.destroy();
        if (self.catalog) |*catalog| catalog.deinit();
        if (self.resume_path) |path| self.allocator.free(path);
        if (self.pending_thread) |target| {
            self.allocator.free(target.path);
            self.allocator.free(target.cwd);
        }
        _ = c.SDL_StopTextInput(self.window);
        if (self.editor_layout) |layout| c.spica_text_layout_release(layout);
        for (self.labels) |label_value| if (label_value.layout) |layout| c.spica_text_layout_release(layout);
        self.transcript.deinit();
        self.editor.deinit();
        self.allocator.free(self.copy_buffer);
        self.preedit.deinit(self.allocator);
        self.layout.deinit();
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.paths.deinit();
        self.allocator.free(self.project_path);
    }

    fn palette(self: *App) theme_module.Palette {
        return if (self.light) self.theme.light else self.theme.dark;
    }
    fn rgba(color: theme_module.Color) c.SDL_Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
    }
    fn rectangle(self: *App, x: f32, y: f32, width: f32, height: f32, radius: f32, color: theme_module.Color) !void {
        try widgets.panel(self.renderer, .{ .x = x, .y = y, .w = width, .h = height }, radius, color);
    }
    fn labelLayout(self: *App, bytes: []const u8, size: c_uint) !*c.SpicaTextLayout {
        if (bytes.len > 128) return error.LabelTooLong;
        self.label_clock += 1;
        var replacement = &self.labels[0];
        for (&self.labels) |*value| {
            if (value.layout != null and value.size == size and std.mem.eql(u8, value.bytes[0..value.len], bytes)) {
                value.used = self.label_clock;
                return value.layout.?;
            }
            if (value.layout == null or value.used < replacement.used) replacement = value;
        }
        if (replacement.layout) |layout| c.spica_text_layout_release(layout);
        replacement.layout = null;
        replacement.layout = c.spica_text_layout_create(self.text, bytes.ptr, bytes.len, 2000, size, false) orelse return error.LabelLayout;
        @memcpy(replacement.bytes[0..bytes.len], bytes);
        replacement.len = bytes.len;
        replacement.size = size;
        replacement.used = self.label_clock;
        return replacement.layout.?;
    }

    fn label(self: *App, bytes: []const u8, x: f32, top: f32, size: c_uint, color: theme_module.Color) !void {
        if (!c.spica_text_layout_draw(self.text, try self.labelLayout(bytes, size), x, top, rgba(color))) return error.LabelDraw;
    }

    fn labelWidth(self: *App, bytes: []const u8, size: c_uint) !f32 {
        var row: c.SpicaTextLine = undefined;
        return if (c.spica_text_layout_line(try self.labelLayout(bytes, size), 0, &row)) row.width else 0;
    }

    fn fitLabel(self: *App, bytes: []const u8, x: f32, top: f32, width: f32, size: c_uint, color: theme_module.Color) !void {
        const truncated = try self.labelWidth(bytes, size) > width;
        const suffix_width = if (truncated) try self.labelWidth("…", size) else 0;
        const clip = c.SDL_Rect{ .x = @intFromFloat(x), .y = @intFromFloat(top), .w = @intFromFloat(@max(0, width - suffix_width)), .h = @intCast(size + 8) };
        _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
        try self.label(bytes, x, top, size, color);
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
        if (truncated) try self.label("…", x + width - suffix_width, top, size, color);
    }

    fn title(self: *const App) []const u8 {
        if (self.options.fixture) return "Resource scene";
        if (self.runtime_snapshot) |snapshot| if (snapshot.session_name.len != 0) return clippedLabel(snapshot.session_name);
        return if (self.thread_title_len != 0) self.thread_title[0..self.thread_title_len] else "New thread";
    }

    fn report(self: *App, operation: []const u8, err: anyerror) void {
        const text = std.fmt.bufPrint(&self.error_text, "{s}: {s}", .{ operation, @errorName(err) }) catch "Error message exceeds display budget";
        self.error_len = text.len;
        self.formatting_error = false;
        std.log.err("{s}; SDL: {s}", .{ text, c.SDL_GetError() });
        self.dirty = true;
    }

    fn requestConversation(self: *App) void {
        self.conversation_dirty = true;
        self.dirty = true;
    }

    fn pumpContent(self: *App) !void {
        if (self.content_pending or self.minimized) return;
        if (self.last_content_metadata) {
            if (self.transcript.request(self.generation + 1)) |request| {
                self.generation += 1;
                try self.content.request(request);
                self.content_pending = true;
                self.pending_ordinal = request.ordinal;
                self.last_content_metadata = false;
                return;
            }
        }
        if (self.conversation_dirty) {
            const session_file = if (self.options.fixture) fixture.session_file else if (self.runtime_snapshot) |snapshot| snapshot.session_file else return;
            if (session_file.len == 0) return;
            self.generation += 1;
            try self.content.request(.{
                .generation = self.generation,
                .conversation = true,
                .session_file = session_file,
                .runtime_id = if (self.runtime_snapshot) |snapshot| snapshot.runtime_id else 0,
                .run_generation = if (self.runtime_snapshot) |snapshot| snapshot.generation else 0,
            });
            self.conversation_dirty = false;
            self.content_pending = true;
            self.pending_ordinal = null;
            self.last_content_metadata = true;
        } else if (self.transcript.request(self.generation + 1)) |request| {
            self.generation += 1;
            try self.content.request(request);
            self.content_pending = true;
            self.pending_ordinal = request.ordinal;
            self.last_content_metadata = false;
        }
    }

    fn openThread(self: *App, index: usize) !void {
        const catalog = self.catalog orelse return;
        if (index >= catalog.threads.len or self.pending_thread != null) return;
        if (self.runtimeStatus() == .streaming or self.bashRunning() or self.submitted_prompt != null) return error.StopCurrentRunBeforeSwitchingThread;
        const thread = catalog.threads[index];
        if (self.runtime_snapshot) |snapshot| if (std.mem.eql(u8, snapshot.session_file, thread.path)) {
            self.follow_bottom = true;
            self.dirty = true;
            return;
        };
        const path = try self.allocator.dupeZ(u8, thread.path);
        errdefer self.allocator.free(path);
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, thread.cwd, self.allocator);
        errdefer self.allocator.free(cwd);
        try self.saveDraft();
        if (self.runtime) |runtime| if (!runtime.isFinished()) try runtime.shutdown();
        self.pending_thread = .{ .path = path, .cwd = cwd };
        try self.finishThreadSwitch();
    }

    fn finishThreadSwitch(self: *App) !void {
        const target = self.pending_thread orelse return;
        if (self.runtime) |runtime| if (!runtime.isFinished()) return;
        self.pending_thread = null;
        self.allocator.free(self.project_path);
        self.project_path = target.cwd;
        if (self.resume_path) |path| self.allocator.free(path);
        self.resume_path = target.path;
        self.options.resume_file = target.path;
        self.transcript.clear();
        self.scroll = 0;
        self.follow_bottom = true;
        self.generation += 1;
        self.content_pending = false;
        try self.beginRuntime();
    }

    fn runtimeStatus(self: *const App) pi.Status {
        return if (self.runtime_snapshot) |snapshot| snapshot.status else .stopped;
    }

    fn bashRunning(self: *const App) bool {
        return if (self.runtime_snapshot) |snapshot| snapshot.bash_running and (snapshot.status == .ready or snapshot.status == .streaming) else false;
    }

    fn beginRuntime(self: *App) !void {
        if (self.options.fixture or self.closing) return;
        if (self.runtime) |runtime| {
            if (!runtime.isFinished()) return;
            try runtime.destroy();
            self.runtime = null;
        }
        if (self.runtime_snapshot) |*snapshot| snapshot.deinit();
        self.runtime_snapshot = null;
        self.model_menu = false;
        self.submitted_prompt = null;
        self.error_len = 0;
        self.follow_bottom = true;
        self.runtime = try pi.Runtime.create(self.allocator, self.io, .{
            .database_path = self.paths.database,
            .project_path = self.project_path,
            .node_path = self.options.node_path,
            .pi_entrypoint = self.options.pi_entrypoint,
            .trust_project = self.options.trust_project orelse false,
            .resume_file = self.options.resume_file,
            .wake_event = self.wake_event,
        });
        try self.runtime.?.start();
        self.dirty = true;
    }

    fn requestClose(self: *App) !void {
        if (self.runtime) |runtime| {
            if (!runtime.isFinished()) {
                if (!self.closing) {
                    try self.saveDraft();
                    try runtime.shutdown();
                    self.closing = true;
                    self.focused_editor = false;
                    _ = c.SDL_StopTextInput(self.window);
                    self.dirty = true;
                }
                return;
            }
        }
        self.running = false;
    }

    fn requestLatest(self: *App) void {
        self.follow_bottom = true;
        self.requestConversation();
    }

    fn consumeRuntime(self: *App) void {
        const runtime = self.runtime orelse return;
        if (runtime.takeSnapshot()) |incoming| {
            const previous_status = self.runtimeStatus();
            const generation_changed = self.runtime_snapshot != null and incoming.generation != self.runtime_snapshot.?.generation;
            const session_changed = incoming.session_file.len != 0 and (self.runtime_snapshot == null or !std.mem.eql(u8, self.runtime_snapshot.?.session_file, incoming.session_file));
            const changed_error = incoming.error_message.len != 0 and (self.runtime_snapshot == null or !std.mem.eql(u8, self.runtime_snapshot.?.error_message, incoming.error_message));
            const recovery_changed = incoming.recovery_revision != 0 and (self.runtime_snapshot == null or incoming.recovery_revision != self.runtime_snapshot.?.recovery_revision);
            if (self.runtime_snapshot) |*old| old.deinit();
            self.runtime_snapshot = incoming;
            const snapshot = &self.runtime_snapshot.?;
            if (session_changed or generation_changed) {
                self.thread_title_len = 0;
                self.run_started = null;
                self.run_elapsed = null;
                self.behavior = .prompt;
                self.generation += 1;
                self.content_pending = false;
                self.transcript.clear();
                self.scroll = 0;
                self.catalog_worker.refresh();
            }
            if (changed_error) {
                const text = clippedLabel(snapshot.error_message);
                @memcpy(self.error_text[0..text.len], text);
                self.error_len = text.len;
                self.formatting_error = false;
                std.log.err("Pi: {s}", .{snapshot.error_message});
            }
            if (self.submitted_prompt) |submitted| {
                var id_buffer: [32]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buffer, "desktop-{d}", .{submitted.token}) catch unreachable;
                if (std.mem.eql(u8, snapshot.accepted_command_id, id)) {
                    self.submitted_prompt = null;
                    if (self.draft_revision == submitted.draft_revision) {
                        self.editor.selectAll();
                        self.editor.insert("", .paste) catch |err| {
                            self.report("Clearing accepted draft", err);
                            return;
                        };
                        self.edited();
                        self.accepted_clear_revision = self.draft_revision;
                    }
                } else if (std.mem.eql(u8, snapshot.rejected_command_id, id) or runtime.isFinished()) {
                    self.submitted_prompt = null;
                }
            }
            if (recovery_changed and snapshot.pending_draft.len != 0 and self.editor.len == 0 and self.submitted_prompt == null) {
                self.editor.insert(snapshot.pending_draft, .paste) catch |err| {
                    self.report("Recovering cancelled input; raw source retained", err);
                    return;
                };
                self.edited();
            }
            if (!self.minimized) self.requestConversation();
            if (snapshot.session_file.len != 0 and (self.resume_path == null or !std.mem.eql(u8, self.resume_path.?, snapshot.session_file))) {
                const path = self.allocator.dupeZ(u8, snapshot.session_file) catch |err| {
                    self.report("Retaining current session path", err);
                    return;
                };
                if (self.resume_path) |old| self.allocator.free(old);
                self.resume_path = path;
                self.options.resume_file = path;
            }
            if (changed_error and snapshot.visible_length == 0 and snapshot.status == .ready and self.run_started != null and self.accepted_clear_revision == self.draft_revision and self.editor.len == 0) {
                if (self.editor.undo()) self.edited();
            }
            if (self.run_started) |started| {
                if (snapshot.status == .ready and snapshot.visible_revision > self.run_base_revision and std.mem.eql(u8, snapshot.content_status, "complete")) {
                    self.run_elapsed = c.SDL_GetTicks() - started;
                    self.run_started = null;
                }
            }
            if (snapshot.status == .needs_force_stop and previous_status != .needs_force_stop) self.force_dialog = true;
            self.dirty = true;
        }
        if (self.closing and runtime.isFinished()) self.running = false;
        if (!self.closing) self.finishThreadSwitch() catch |err| self.report("Opening thread", err);
    }

    fn submit(self: *App) !void {
        if (self.preedit.items.len != 0 or self.closing) return;
        const runtime = self.runtime orelse return error.StartPiFirst;
        if (self.runtimeStatus() != .ready and self.runtimeStatus() != .streaming) return error.PiNotReady;
        if (self.bashRunning()) return error.PiBusy;
        const text = self.editor.textBytes();
        if (text.len == 0) return;
        if (self.thread_title_len == 0 and !self.bash_mode) {
            const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            const first = std.mem.trim(u8, clippedLabel(text[0..end]), " \t\r");
            if (first.len != 0 and (self.runtime_snapshot == null or self.runtime_snapshot.?.session_name.len == 0)) try runtime.setSessionName(first);
            @memcpy(self.thread_title[0..first.len], first);
            self.thread_title_len = first.len;
        }
        self.run_started = c.SDL_GetTicks();
        self.run_base_revision = if (self.runtime_snapshot) |snapshot| snapshot.visible_revision else 0;
        self.run_elapsed = null;
        self.error_len = 0;
        if (self.bash_mode) {
            try runtime.bash(text);
        } else {
            if (self.submitted_prompt != null) return error.PromptAcknowledgementPending;
            const behavior: pi.Behavior = if (self.runtimeStatus() == .ready) .prompt else if (self.behavior == .prompt) .follow_up else self.behavior;
            const token = try runtime.sendPrompt(text, behavior);
            self.submitted_prompt = .{ .token = token, .draft_revision = self.draft_revision };
        }
        self.follow_bottom = true;
        self.dirty = true;
    }

    fn act(self: *App, action: Action) !void {
        switch (action) {
            .start => try self.beginRuntime(),
            .new_thread => {
                if (self.runtime) |runtime| {
                    if (runtime.isFinished()) try self.beginRuntime() else if (self.runtimeStatus() == .streaming or self.bashRunning() or self.submitted_prompt != null) return error.PiBusy else try runtime.newSession();
                } else try self.beginRuntime();
            },
            .sidebar => self.sidebar_visible = !self.sidebar_visible,
            .open_thread => |index| try self.openThread(index),
            .send => try self.submit(),
            .stop => if (self.runtime) |runtime| {
                try runtime.stop();
            },
            .theme => {
                self.light = !self.light;
                self.draft_due = c.SDL_GetTicks() + 250;
            },
            .mode => self.bash_mode = !self.bash_mode,
            .behavior => self.behavior = if (self.behavior == .steer) .follow_up else .steer,
            .latest => {
                self.follow_bottom = true;
                self.requestLatest();
            },
            .models => {
                self.model_menu = !self.model_menu;
                self.thinking_menu = false;
            },
            .thinking => {
                self.thinking_menu = !self.thinking_menu;
                self.model_menu = false;
            },
            .select_thinking => |index| {
                const snapshot = self.runtime_snapshot orelse return error.PiNotReady;
                if (index >= snapshot.thinking_levels.len) return error.StaleThinkingChoice;
                try (self.runtime orelse return error.PiNotReady).setThinkingLevel(snapshot.thinking_levels[index]);
                self.thinking_menu = false;
            },
            .disclosure => |target| {
                self.transcript.toggle(target);
                self.follow_bottom = false;
            },
            .select_model => |index| {
                const snapshot = self.runtime_snapshot orelse return error.PiNotReady;
                if (index >= snapshot.models.len) return error.StaleModelChoice;
                const model = snapshot.models[index];
                try (self.runtime orelse return error.PiNotReady).setModel(model.provider, model.id);
                self.model_menu = false;
            },
            .force_stop => if (self.runtime) |runtime| {
                try runtime.forceTerminate();
                self.force_dialog = false;
            },
            .wait => self.force_dialog = false,
        }
        self.dirty = true;
    }

    fn button(self: *App, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
        if (self.button_count == self.buttons.len) return error.ButtonBudget;
        self.buttons[self.button_count] = .{ .action = action, .bounds = bounds };
        self.button_count += 1;
        try self.rectangle(bounds.x, bounds.y, bounds.w, bounds.h, 6, self.palette().raised);
        try self.label(clippedLabel(text), bounds.x + 10, bounds.y + 8, 13, self.palette().text);
    }

    fn hit(self: *App, action: Action, bounds: c.SDL_FRect) !void {
        if (self.button_count == self.buttons.len) return error.ButtonBudget;
        self.buttons[self.button_count] = .{ .action = action, .bounds = bounds };
        self.button_count += 1;
    }

    fn flatButton(self: *App, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
        try self.hit(action, bounds);
        const reserve: f32 = switch (action) {
            .models, .thinking => 28,
            else => 16,
        };
        try self.fitLabel(clippedLabel(text), bounds.x + 8, bounds.y + 7, @max(0, bounds.w - reserve), 13, self.palette().muted);
    }

    fn iconButton(self: *App, action: Action, kind: widgets.Icon, bounds: c.SDL_FRect, color: theme_module.Color) !void {
        try self.hit(action, bounds);
        try widgets.icon(self.renderer, kind, .{ .x = bounds.x + (bounds.w - 16) / 2, .y = bounds.y + (bounds.h - 16) / 2, .w = 16, .h = 16 }, color);
    }

    fn contains(bounds: c.SDL_FRect, x: f32, y: f32) bool {
        return x >= bounds.x and x < bounds.x + bounds.w and y >= bounds.y and y < bounds.y + bounds.h;
    }

    fn drawOverlays(self: *App) !void {
        const colors = self.palette();
        if (self.model_menu) {
            const x = self.model_bounds.x;
            const width: f32 = @min(360, self.composer_bounds.w - 16);
            const y = self.composer_bounds.y - 270;
            try self.rectangle(x, y, width, 260, 8, colors.border);
            try self.rectangle(x + 1, y + 1, width - 2, 258, 7, colors.panel);
            if (self.runtime_snapshot) |snapshot| {
                if (snapshot.models.len == 0) try self.label("No configured models", x + 12, y + 16, 13, colors.muted);
                self.model_first = @min(self.model_first, snapshot.models.len -| 1);
                const end = @min(snapshot.models.len, self.model_first + 6);
                for (snapshot.models[self.model_first..end], self.model_first..) |model, index| {
                    const row_y = y + 8 + @as(f32, @floatFromInt(index - self.model_first)) * 40;
                    const row_clip = c.SDL_Rect{ .x = @intFromFloat(x + 8), .y = @intFromFloat(row_y), .w = @intFromFloat(width - 16), .h = 38 };
                    _ = c.SDL_SetRenderClipRect(self.renderer, &row_clip);
                    try self.hit(.{ .select_model = index }, .{ .x = x + 8, .y = row_y, .w = width - 16, .h = 38 });
                    try self.label(clippedLabel(model.name), x + 12, row_y + 3, 13, colors.text);
                    try self.label(clippedLabel(model.provider), x + 12, row_y + 23, 10, colors.muted);
                    _ = c.SDL_SetRenderClipRect(self.renderer, null);
                }
            } else try self.label("Start pi to discover models", x + 12, y + 16, 13, colors.muted);
        }
        if (self.thinking_menu) {
            if (self.runtime_snapshot) |snapshot| {
                const height = @as(f32, @floatFromInt(snapshot.thinking_levels.len)) * 32 + 16;
                const x = self.thinking_bounds.x;
                const y = self.composer_bounds.y - height - 10;
                try self.rectangle(x, y, 130, height, 8, colors.border);
                try self.rectangle(x + 1, y + 1, 128, height - 2, 7, colors.panel);
                for (snapshot.thinking_levels, 0..) |level, index| try self.flatButton(.{ .select_thinking = index }, level, .{ .x = x + 4, .y = y + 8 + @as(f32, @floatFromInt(index)) * 32, .w = 122, .h = 30 });
            }
        }
        if (self.closing or self.force_dialog) {
            const x = self.shell.conversation.x + 36;
            try self.rectangle(x, 110, self.shell.conversation.width - 72, 166, 10, colors.panel);
            try self.label(if (self.force_dialog) "Pi has not exited" else "Closing pi gracefully...", x + 20, 130, 18, colors.text);
            try self.label("The window stays alive until its owned process exits.", x + 20, 164, 13, colors.muted);
            if (self.force_dialog) {
                try self.button(.wait, "Wait", .{ .x = x + 20, .y = 213, .w = 80, .h = 34 });
                try self.button(.force_stop, "Force owned tree · Ctrl+Shift+Esc", .{ .x = x + 114, .y = 213, .w = 258, .h = 34 });
            }
        }
    }

    fn consume(self: *App) void {
        self.consumeRuntime();
        if (self.catalog_worker.take()) |result| switch (result) {
            .ready => |catalog| {
                if (self.catalog) |*old| old.deinit();
                self.catalog = catalog;
                self.sidebar_first = @min(self.sidebar_first, catalog.threads.len -| 1);
                self.dirty = true;
            },
            .failure => |err| self.report("Discovering pi threads", err),
        };
        if (self.draft_writer.takeError()) |err| self.report("Draft could not be saved", err);
        if (self.content.take()) |result_value| {
            var result = result_value;
            const generation = switch (result) {
                .ready => |value| value.generation,
                .conversation => |value| value.generation,
                .failure => |value| value.generation orelse self.generation,
            };
            if (generation != self.generation) {
                result.deinit();
                return;
            }
            self.content_pending = false;
            switch (result) {
                .failure => |failure| {
                    if (self.pending_ordinal) |ordinal| self.transcript.fail(ordinal);
                    self.report("Loading conversation", failure.err);
                },
                .conversation => |*value| {
                    if (self.runtime_snapshot) |snapshot| if (snapshot.thinking_content_ref) |id| {
                        var index = value.entries.len;
                        while (index > 0) {
                            index -= 1;
                            if (value.entries[index].role == .assistant and value.entries[index].ordinal >= @import("core/store.zig").live_ordinal_base) {
                                value.entries[index].reasoning = .{ .content_ref = id, .length = snapshot.thinking_length };
                                break;
                            }
                        }
                    };
                    self.transcript.update(value.entries) catch |err| self.report("Updating conversation", err);
                    value.deinit();
                },
                .ready => |ready| self.transcript.accept(self.renderer, ready) catch |err| self.report("Rendering message", err),
            }
            self.dirty = true;
        }
    }

    fn saveDraft(self: *App) !void {
        const bytes = self.editor.textBytes();
        try self.draft_writer.submit(.{ .draft = bytes, .light = self.light });
        self.draft_due = null;
    }

    fn clippedLabel(bytes: []const u8) []const u8 {
        var end = @min(bytes.len, 128);
        while (end < bytes.len and end > 0 and (bytes[end] & 0xc0) == 0x80) end -= 1;
        return bytes[0..end];
    }

    fn ensureEditorLayout(self: *App, editor_width: f32) !void {
        if (editor_width <= 24) return;
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
    }

    fn moveVertical(self: *App, down: bool, extend: bool) !void {
        try self.ensureEditorLayout(self.editor_width);
        const layout = self.editor_layout orelse return;
        var caret: c.SDL_FRect = undefined;
        if (!c.spica_text_layout_caret(layout, self.editor.caret - self.editor_start, &caret)) return;
        const x = self.preferred_caret_x orelse caret.x;
        self.preferred_caret_x = x;
        const y = caret.y + (if (down) @as(f32, 1.5) else -0.5) * caret.h;
        self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, x, y), extend);
        self.dirty = true;
    }

    fn moveLineEdge(self: *App, end: bool, whole: bool, extend: bool) !void {
        if (!whole) try self.ensureEditorLayout(self.editor_width);
        if (whole) {
            self.editor.setCaret(if (end) self.editor.len else 0, extend);
        } else if (self.editor_layout) |layout| {
            var caret: c.SDL_FRect = undefined;
            if (c.spica_text_layout_caret(layout, self.editor.caret - self.editor_start, &caret)) {
                self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, if (end) 1000000 else 0, caret.y + caret.h * 0.5), extend);
            }
        }
        self.preferred_caret_x = null;
        self.dirty = true;
    }
    fn edited(self: *App) void {
        self.draft_revision += 1;
        self.preferred_caret_x = null;
        self.editor_changed = true;
        self.draft_due = c.SDL_GetTicks() + 250;
        self.dirty = true;
    }
    fn reloadTheme(self: *App) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, build_options.asset_directory ++ "/theme.json", self.allocator, .limited(16384));
        defer self.allocator.free(bytes);
        const next = try theme_module.parse(self.allocator, bytes);
        self.theme = next;
        self.transcript.invalidateLayouts();
        self.editor_width = 0;
        self.error_len = 0;
        self.dirty = true;
    }

    fn paint(self: *App) !void {
        self.button_count = 0;
        var width: c_int = 1280;
        var height: c_int = 800;
        _ = c.SDL_GetWindowSize(self.window, &width, &height);
        if (!c.SDL_SetRenderLogicalPresentation(self.renderer, width, height, c.SDL_LOGICAL_PRESENTATION_STRETCH)) return error.LogicalPresentation;
        var pixel_width: c_int = width;
        var pixel_height: c_int = height;
        if (!c.SDL_GetRenderOutputSize(self.renderer, &pixel_width, &pixel_height)) return error.RenderOutputSize;
        if (!c.spica_text_set_render_scale(self.text, @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(width)), @as(f32, @floatFromInt(pixel_height)) / @as(f32, @floatFromInt(height)))) return error.TextRenderScale;
        self.layout.resize(@floatFromInt(width), @floatFromInt(height));
        const colors = self.palette();
        self.shell = self.layout.shell(if (self.sidebar_visible) @min(self.theme.metrics.sidebar_width, @as(f32, @floatFromInt(width)) * 0.28) else 0, self.theme.metrics.header_height, 202);
        const sidebar = self.shell.sidebar;
        const header = self.shell.header;
        const conversation = self.shell.conversation;
        const project = clippedLabel(std.fs.path.basename(self.project_path));
        try self.rectangle(0, 0, @floatFromInt(width), @floatFromInt(height), 0, colors.canvas);
        if (self.sidebar_visible) {
            try self.rectangle(sidebar.x, sidebar.y, sidebar.width, sidebar.height, 0, colors.panel);
            try self.iconButton(.sidebar, .sidebar, .{ .x = 12, .y = 9, .w = 30, .h = 30 }, colors.muted);
            try self.label("Spica", 50, 17, 15, colors.text);
            try self.iconButton(.new_thread, .plus, .{ .x = sidebar.width - 42, .y = 9, .w = 30, .h = 30 }, colors.muted);
            try widgets.icon(self.renderer, .folder, .{ .x = 22, .y = 84, .w = 14, .h = 14 }, colors.muted);
            try self.label("All projects", 46, 84, 13, colors.muted);
            try self.rectangle(10, 112, sidebar.width - 20, 66, 7, colors.raised);
            try self.hit(.latest, .{ .x = 10, .y = 112, .w = sidebar.width - 20, .h = 66 });
            try self.fitLabel(clippedLabel(self.title()), 22, 125, sidebar.width - 44, 13, colors.text);
            try self.fitLabel(project, 22, 151, sidebar.width - 44, 11, colors.muted);
            if (self.catalog) |catalog| {
                const sidebar_clip = c.SDL_Rect{ .x = 10, .y = 188, .w = @intFromFloat(sidebar.width - 20), .h = @max(0, height - 244) };
                _ = c.SDL_SetRenderClipRect(self.renderer, &sidebar_clip);
                var row_y: f32 = 188;
                var index = self.sidebar_first;
                while (index < catalog.threads.len and row_y + 58 <= @as(f32, @floatFromInt(height)) - 56) : (index += 1) {
                    const thread = catalog.threads[index];
                    const selected = if (self.runtime_snapshot) |snapshot| std.mem.eql(u8, snapshot.session_file, thread.path) else false;
                    if (selected) try self.rectangle(10, row_y, sidebar.width - 20, 54, 6, colors.raised);
                    try self.hit(.{ .open_thread = index }, .{ .x = 10, .y = row_y, .w = sidebar.width - 20, .h = 54 });
                    try self.fitLabel(clippedLabel(thread.title), 22, row_y + 8, sidebar.width - 44, 13, colors.text);
                    try self.fitLabel(clippedLabel(thread.cwd), 22, row_y + 32, sidebar.width - 44, 10, colors.muted);
                    row_y += 58;
                }
                _ = c.SDL_SetRenderClipRect(self.renderer, null);
            }
            try self.iconButton(.theme, .theme, .{ .x = 12, .y = @as(f32, @floatFromInt(height)) - 42, .w = 30, .h = 30 }, colors.muted);
        } else try self.iconButton(.sidebar, .sidebar, .{ .x = header.x + 12, .y = 7, .w = 30, .h = 30 }, colors.muted);
        const crumb_x = header.x + (if (self.sidebar_visible) @as(f32, 22) else 52);
        try widgets.icon(self.renderer, .folder, .{ .x = crumb_x, .y = 15, .w = 14, .h = 14 }, colors.accent);
        try self.label(project, crumb_x + 24, 15, 13, colors.text);
        const title_x = crumb_x + 40 + try self.labelWidth(project, 13);
        try self.label("/", title_x, 15, 13, colors.muted);
        try self.fitLabel(clippedLabel(self.title()), title_x + 20, 15, @max(0, header.x + header.width - 158 - title_x), 13, colors.muted);
        const state: []const u8 = if (self.options.fixture) "Resource scene" else switch (self.runtimeStatus()) {
            .starting => "Starting pi",
            .ready => if (self.bashRunning()) "Running Bash" else "Ready",
            .streaming => "Working",
            .stopping => "Stopping",
            .needs_force_stop => "Needs Force",
            .failed => "Pi failed",
            .exited => "Pi exited",
            .stopped => "Stopped",
        };
        try self.label(state, header.x + header.width - 138, 16, 11, if (self.runtimeStatus() == .failed) colors.error_color else if (self.runtimeStatus() == .streaming) colors.accent else colors.muted);
        if (!self.options.fixture and self.pending_thread == null and (self.runtime == null or self.runtime.?.isFinished())) try self.button(.start, "Retry", .{ .x = header.x + header.width - 86, .y = 8, .w = 68, .h = 28 });

        const content_width = @min(self.theme.metrics.chat_max_width, conversation.width - 64);
        const content_x = conversation.x + (conversation.width - content_width) / 2;
        const body_top = conversation.y + 24;
        const viewport_height = conversation.height - 34;
        const clip = c.SDL_Rect{ .x = @intFromFloat(content_x), .y = @intFromFloat(body_top), .w = @intFromFloat(content_width), .h = @intFromFloat(viewport_height) };
        _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
        try self.transcript.draw(self.text, self.renderer, content_x, body_top, content_width, viewport_height, &self.scroll, self.follow_bottom, self.theme.metrics, colors, self.light);
        for (self.transcript.disclosures[0..self.transcript.disclosure_count]) |disclosure| try self.hit(.{ .disclosure = disclosure.toggle }, disclosure.bounds);
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
        if (!self.follow_bottom and self.transcript.height > viewport_height) try self.flatButton(.latest, "Jump to latest", .{ .x = content_x + content_width - 128, .y = conversation.y + conversation.height - 33, .w = 128, .h = 28 });
        self.composer_bounds = .{ .x = content_x, .y = @as(f32, @floatFromInt(height)) - 194, .w = content_width, .h = 144 };
        const composer = self.composer_bounds;
        const fill = theme_module.Color{
            .r = @intCast((@as(u16, colors.canvas.r) * 3 + colors.raised.r) / 4),
            .g = @intCast((@as(u16, colors.canvas.g) * 3 + colors.raised.g) / 4),
            .b = @intCast((@as(u16, colors.canvas.b) * 3 + colors.raised.b) / 4),
        };
        try self.rectangle(composer.x, composer.y, composer.w, composer.h, 14, colors.border);
        try self.rectangle(composer.x + 1, composer.y + 1, composer.w - 2, composer.h - 2, 13, fill);
        self.editor_bounds = .{ .x = composer.x + 4, .y = composer.y + 4, .w = composer.w - 8, .h = 92 };
        try self.drawEditor();
        const controls_y = composer.y + 104;
        var model_name: []const u8 = "Select model";
        if (self.runtime_snapshot) |snapshot| {
            if (snapshot.model.len != 0) model_name = snapshot.model;
            for (snapshot.models) |model| if (std.mem.eql(u8, model.id, snapshot.model) and std.mem.eql(u8, model.provider, snapshot.provider)) {
                model_name = model.name;
                break;
            };
        }
        const model_width = @min(220, try self.labelWidth(clippedLabel(model_name), 13) + 34);
        self.model_bounds = .{ .x = composer.x + 8, .y = controls_y, .w = model_width, .h = 30 };
        try self.flatButton(.models, model_name, self.model_bounds);
        try widgets.icon(self.renderer, .chevron_down, .{ .x = self.model_bounds.x + model_width - 19, .y = controls_y + 9, .w = 12, .h = 12 }, colors.muted);
        const thinking = if (self.runtime_snapshot) |snapshot| snapshot.thinking_level else "";
        self.thinking_bounds = .{ .x = self.model_bounds.x + model_width + 4, .y = controls_y, .w = 80, .h = 30 };
        if (thinking.len != 0) {
            try self.flatButton(.thinking, thinking, self.thinking_bounds);
            try widgets.icon(self.renderer, .chevron_down, .{ .x = self.thinking_bounds.x + 59, .y = controls_y + 9, .w = 12, .h = 12 }, colors.muted);
        }
        if (!self.options.fixture) {
            const mode_x = self.thinking_bounds.x + (if (thinking.len == 0) @as(f32, 0) else 84);
            if (!self.bash_mode and self.runtimeStatus() == .streaming) {
                try self.flatButton(.behavior, if (self.behavior == .steer) "Steer" else "Follow-up", .{ .x = mode_x, .y = controls_y, .w = 96, .h = 30 });
            } else try self.flatButton(.mode, if (self.bash_mode) "Bash" else "Prompt", .{ .x = mode_x, .y = controls_y, .w = 70, .h = 30 });
            const send_bounds = c.SDL_FRect{ .x = composer.x + composer.w - 44, .y = controls_y, .w = 32, .h = 32 };
            const working = self.runtimeStatus() == .streaming or self.bashRunning();
            try self.rectangle(send_bounds.x, send_bounds.y, send_bounds.w, send_bounds.h, 16, if (self.runtime == null) colors.raised else colors.accent);
            try self.iconButton(if (working) .stop else .send, if (working) .stop else .arrow_up, send_bounds, if (self.runtime == null) colors.muted else colors.text);
        }
        try widgets.icon(self.renderer, .folder, .{ .x = composer.x + 2, .y = composer.y + composer.h + 13, .w = 12, .h = 12 }, colors.muted);
        try self.label("Local checkout", composer.x + 22, composer.y + composer.h + 13, 11, colors.muted);
        try self.label(project, composer.x + composer.w - try self.labelWidth(project, 11), composer.y + composer.h + 13, 11, colors.muted);
        if (self.error_len != 0) {
            try self.fitLabel(clippedLabel(self.error_text[0..self.error_len]), composer.x, composer.y - 25, composer.w, 12, colors.error_color);
        } else if (self.runtime_snapshot) |snapshot| {
            if (snapshot.attention.len != 0) {
                try self.fitLabel(clippedLabel(snapshot.attention), composer.x, composer.y - 25, composer.w, 12, colors.muted);
            } else if (snapshot.status == .streaming or self.bashRunning()) {
                var buffer: [128]u8 = undefined;
                const progress = std.fmt.bufPrint(&buffer, "{s}{s}{d} queued", .{ if (self.bashRunning()) "Running Bash" else "Working", " · ", snapshot.queued_count }) catch unreachable;
                try self.fitLabel(progress, composer.x, composer.y - 25, composer.w - 140, 12, colors.accent);
            }
        }
        try self.drawOverlays();
        if (!self.captured and self.options.capture != null and self.transcript.wanted == null and !self.content_pending and !self.conversation_dirty and (if (self.options.fixture) self.transcript.items.items.len != 0 else self.runtimeStatus() == .ready)) {
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

    fn drawEditor(self: *App) !void {
        const bounds = self.editor_bounds;
        const colors = self.palette();
        try self.ensureEditorLayout(bounds.w);
        const clip = c.SDL_Rect{ .x = @intFromFloat(bounds.x + 8), .y = @intFromFloat(bounds.y + 8), .w = @intFromFloat(bounds.w - 16), .h = @intFromFloat(bounds.h - 16) };
        _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
        if (self.editor_layout) |layout| {
            var caret: c.SDL_FRect = undefined;
            if (c.spica_text_layout_caret(layout, self.editor.caret - self.editor_start, &caret)) {
                self.editor_scroll = @max(0, @min(self.editor_scroll, caret.y));
                if (caret.y + caret.h > self.editor_scroll + bounds.h - 20) self.editor_scroll = caret.y + caret.h - (bounds.h - 20);
                if (self.focused_editor and self.editor.len != 0) try self.rectangle(bounds.x + 12 + caret.x, bounds.y + 10 + caret.y - self.editor_scroll, 1, caret.h, 0, colors.text);
                const input_area = c.SDL_Rect{ .x = @intFromFloat(bounds.x + 12 + caret.x), .y = @intFromFloat(bounds.y + 10 + caret.y - self.editor_scroll), .w = 1, .h = @intFromFloat(caret.h) };
                _ = c.SDL_SetTextInputArea(self.window, &input_area, 0);
            }
            const selected = self.editor.selection();
            const start = @max(selected.start, self.editor_start);
            const end = @min(selected.end, self.editor_end);
            if (start < end) {
                var rects: [8192]c.SDL_FRect = undefined;
                const count = c.spica_text_layout_selection_rects(layout, start - self.editor_start, end - self.editor_start, &rects, rects.len);
                if (count > rects.len) return error.SelectionGeometryBudget;
                for (rects[0..count]) |*rect| {
                    rect.x += bounds.x + 12;
                    rect.y += bounds.y + 10 - self.editor_scroll;
                }
                if (!c.SDL_SetRenderDrawBlendMode(self.renderer, c.SDL_BLENDMODE_BLEND) or !c.SDL_SetRenderDrawColor(self.renderer, colors.accent.r, colors.accent.g, colors.accent.b, 60) or !c.SDL_RenderFillRects(self.renderer, &rects, @intCast(count))) return error.SelectionDraw;
            }
            if (!c.spica_text_layout_draw(self.text, layout, bounds.x + 12, bounds.y + 10 - self.editor_scroll, rgba(colors.text))) return error.EditorDraw;
            if (self.editor.len == 0) try self.label(if (self.bash_mode) "Run a command" else "Ask for changes or send a follow-up", bounds.x + 12, bounds.y + 10, 15, colors.muted);
        }
        if (self.preedit.items.len != 0) try self.label(clippedLabel(self.preedit.items), bounds.x + 12, bounds.y + 66, 15, colors.accent);
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
    }

    fn retainOwnedProcessOnError(self: *App) void {
        const runtime = self.runtime orelse return;
        if (runtime.isFinished()) return;
        self.closing = true;
        runtime.shutdown() catch |err| std.log.err("Shutdown after UI failure: {s}", .{@errorName(err)});
        var prompted = false;
        while (!runtime.isFinished()) {
            self.consumeRuntime();
            if (self.runtimeStatus() == .needs_force_stop and !prompted) {
                prompted = true;
                const buttons = [_]c.SDL_MessageBoxButtonData{
                    .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT | c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 0, .text = "Keep waiting" },
                    .{ .flags = 0, .buttonID = 1, .text = "Force owned process tree" },
                };
                const dialog = c.SDL_MessageBoxData{
                    .flags = c.SDL_MESSAGEBOX_ERROR,
                    .window = self.window,
                    .title = "Spica — UI failure",
                    .message = "Pi has not exited. Spica will retain ownership until it exits.\nCtrl+Shift+Esc reopens this choice.",
                    .numbuttons = buttons.len,
                    .buttons = &buttons,
                    .colorScheme = null,
                };
                var choice: c_int = 0;
                if (c.SDL_ShowMessageBox(&dialog, &choice) and choice == 1) runtime.forceTerminate() catch |err| std.log.err("Explicit force: {s}", .{@errorName(err)});
            }
            var event: c.SDL_Event = undefined;
            if (c.SDL_WaitEventTimeout(&event, 1000)) {
                if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_ESCAPE and (event.key.mod & c.SDL_KMOD_CTRL) != 0 and (event.key.mod & c.SDL_KMOD_SHIFT) != 0) prompted = false;
            } else c.SDL_Delay(50);
        }
    }

    pub fn run(self: *App) !void {
        errdefer self.retainOwnedProcessOnError();
        if (self.options.fixture) self.requestConversation() else self.beginRuntime() catch |err| self.report("Starting pi", err);
        while (self.running) {
            self.consume();
            const now = c.SDL_GetTicks();
            if (self.quit_due) |due| if (now >= due) {
                self.quit_due = null;
                try self.requestClose();
                if (!self.running) continue;
            };
            if (self.draft_due) |due| if (now >= due) {
                self.saveDraft() catch |err| self.report("Saving draft", err);
                self.draft_due = null;
            };
            if (self.dirty and !self.minimized) try self.paint();
            self.pumpContent() catch |err| self.report("Loading viewport", err);
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
        if (event.type == self.wake_event) {
            self.consume();
            return;
        }
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => try self.requestClose(),
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => self.dirty = true,
            c.SDL_EVENT_WINDOW_MINIMIZED => self.minimized = true,
            c.SDL_EVENT_WINDOW_RESTORED => {
                self.minimized = false;
                self.dirty = true;
                self.requestConversation();
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if (self.model_menu) {
                    const last = if (self.runtime_snapshot) |snapshot| snapshot.models.len -| 1 else 0;
                    self.model_first = if (event.wheel.y > 0) self.model_first -| 1 else @min(last, self.model_first + 1);
                } else if (!self.closing) {
                    var mouse_x: f32 = 0;
                    var mouse_y: f32 = 0;
                    _ = c.SDL_GetMouseState(&mouse_x, &mouse_y);
                    if (self.sidebar_visible and mouse_x < self.shell.sidebar.width) {
                        const last = if (self.catalog) |catalog| catalog.threads.len -| 1 else 0;
                        self.sidebar_first = if (event.wheel.y > 0) self.sidebar_first -| 1 else @min(last, self.sidebar_first + 1);
                    } else {
                        self.follow_bottom = false;
                        self.scroll = @max(0, self.scroll - event.wheel.y * 60);
                        if (event.wheel.y < 0 and self.scroll >= @max(0, self.transcript.height - self.transcript.viewport_height)) self.follow_bottom = true;
                    }
                }
                self.dirty = true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                var button_index = self.button_count;
                while (button_index != 0) {
                    button_index -= 1;
                    const pressed = self.buttons[button_index];
                    if ((self.closing or self.force_dialog) and pressed.action != .force_stop and pressed.action != .wait) continue;
                    if (contains(pressed.bounds, event.button.x, event.button.y)) {
                        try self.act(pressed.action);
                        return;
                    }
                }
                if (self.closing or self.force_dialog) return;
                if (self.model_menu or self.thinking_menu) {
                    self.model_menu = false;
                    self.thinking_menu = false;
                    self.dirty = true;
                    return;
                }
                const inside = contains(self.editor_bounds, event.button.x, event.button.y);
                self.focused_editor = inside;
                if (inside) {
                    self.preferred_caret_x = null;
                    _ = c.SDL_StartTextInput(self.window);
                    if (self.editor_layout) |layout| self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, event.button.x - self.editor_bounds.x - 12, event.button.y - self.editor_bounds.y - 10 + self.editor_scroll), (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
                    self.dragging = true;
                } else _ = c.SDL_StopTextInput(self.window);
                self.dirty = true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => self.dragging = false,
            c.SDL_EVENT_MOUSE_MOTION => if (self.dragging) {
                if (self.editor_layout) |layout| self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, event.motion.x - self.editor_bounds.x - 12, event.motion.y - self.editor_bounds.y - 10 + self.editor_scroll), true);
                self.dirty = true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const command = (event.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
                const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
                if (command and shift and event.key.key == c.SDLK_ESCAPE and self.runtimeStatus() == .needs_force_stop) {
                    try self.act(.force_stop);
                    return;
                }
                if (self.closing or self.force_dialog) {
                    if (event.key.key == c.SDLK_ESCAPE) try self.act(.wait);
                    return;
                }
                if (self.thinking_menu) {
                    if (event.key.key == c.SDLK_ESCAPE) {
                        self.thinking_menu = false;
                        self.dirty = true;
                    }
                    return;
                }
                if (self.model_menu) {
                    if (event.key.key == c.SDLK_ESCAPE) {
                        self.model_menu = false;
                        self.dirty = true;
                    }
                    if (event.key.key == c.SDLK_UP) {
                        self.model_first -|= 1;
                        self.dirty = true;
                    }
                    if (event.key.key == c.SDLK_DOWN) {
                        const last = if (self.runtime_snapshot) |snapshot| snapshot.models.len -| 1 else 0;
                        self.model_first = @min(last, self.model_first + 1);
                        self.dirty = true;
                    }
                    if (event.key.key == c.SDLK_RETURN) try self.act(.{ .select_model = self.model_first });
                    return;
                }
                if (command and event.key.key == c.SDLK_P) {
                    try self.act(.start);
                    return;
                }
                if (command and event.key.key == c.SDLK_B and !self.options.fixture) {
                    try self.act(.mode);
                    return;
                }
                if (command and event.key.key == c.SDLK_M and !self.options.fixture) {
                    try self.act(.models);
                    return;
                }
                if (command and event.key.key == c.SDLK_PERIOD) {
                    try self.act(.stop);
                    return;
                }
                if (command and event.key.key == c.SDLK_RETURN and self.preedit.items.len == 0 and !self.options.fixture) {
                    try self.submit();
                    return;
                }
                if (event.key.key == c.SDLK_PAGEUP or event.key.key == c.SDLK_PAGEDOWN) {
                    self.follow_bottom = false;
                    const amount = @max(100, self.transcript.viewport_height - 48);
                    self.scroll = @max(0, self.scroll + (if (event.key.key == c.SDLK_PAGEUP) -amount else amount));
                    if (self.scroll >= @max(0, self.transcript.height - self.transcript.viewport_height)) self.follow_bottom = true;
                    self.dirty = true;
                    return;
                }
                if (command and !self.focused_editor and (event.key.key == c.SDLK_HOME or event.key.key == c.SDLK_END)) {
                    self.follow_bottom = event.key.key == c.SDLK_END;
                    self.scroll = if (self.follow_bottom) @max(0, self.transcript.height - self.transcript.viewport_height) else 0;
                    self.dirty = true;
                    return;
                }
                if (command and event.key.key == c.SDLK_L) {
                    self.light = !self.light;
                    self.dirty = true;
                    self.draft_due = c.SDL_GetTicks() + 250;
                    return;
                }
                if (command and event.key.key == c.SDLK_R) {
                    try self.reloadTheme();
                    self.catalog_worker.refresh();
                    return;
                }
                if (!self.focused_editor) return;
                if (event.key.key == c.SDLK_ESCAPE) {
                    self.preedit.clearRetainingCapacity();
                    _ = c.SDL_ClearComposition(self.window);
                    self.dirty = true;
                    return;
                }
                if (self.preedit.items.len != 0) return;
                if (event.key.key == c.SDLK_UP or event.key.key == c.SDLK_DOWN) {
                    try self.moveVertical(event.key.key == c.SDLK_DOWN, shift);
                    return;
                }
                if (event.key.key == c.SDLK_HOME or event.key.key == c.SDLK_END) {
                    try self.moveLineEdge(event.key.key == c.SDLK_END, command, shift);
                    return;
                }
                self.preferred_caret_x = null;
                if (command) {
                    switch (event.key.key) {
                        c.SDLK_A => {
                            self.editor.selectAll();
                            self.dirty = true;
                        },
                        c.SDLK_C => try self.copySelection(),
                        c.SDLK_X => {
                            try self.copySelection();
                            try self.editor.insert("", .paste);
                            self.edited();
                        },
                        c.SDLK_V => {
                            const clipboard = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                            defer c.SDL_free(clipboard);
                            try self.editor.insert(std.mem.span(clipboard), .paste);
                            self.edited();
                        },
                        c.SDLK_Z => {
                            if (if (shift) self.editor.redo() else self.editor.undo()) self.edited();
                        },
                        c.SDLK_Y => {
                            if (self.editor.redo()) self.edited();
                        },
                        c.SDLK_LEFT => {
                            self.editor.moveWord(.backward, shift);
                            self.dirty = true;
                        },
                        c.SDLK_RIGHT => {
                            self.editor.moveWord(.forward, shift);
                            self.dirty = true;
                        },
                        else => {},
                    }
                } else switch (event.key.key) {
                    c.SDLK_BACKSPACE => {
                        try self.editor.backspace();
                        self.edited();
                    },
                    c.SDLK_DELETE => {
                        try self.editor.deleteForward();
                        self.edited();
                    },
                    c.SDLK_LEFT => {
                        self.editor.moveGrapheme(.backward, shift);
                        self.dirty = true;
                    },
                    c.SDLK_RIGHT => {
                        self.editor.moveGrapheme(.forward, shift);
                        self.dirty = true;
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                        if (self.runtime != null and !shift) try self.submit() else {
                            try self.editor.insert("\n", .paste);
                            self.edited();
                        }
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (!self.focused_editor or self.model_menu or self.closing) return;
                try self.editor.insert(std.mem.span(event.text.text), if (self.preedit.items.len != 0) .ime else .typing);
                self.preedit.clearRetainingCapacity();
                self.edited();
            },
            c.SDL_EVENT_TEXT_EDITING => {
                if (!self.focused_editor or self.model_menu or self.closing) return;
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
