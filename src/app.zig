const std = @import("std");
const builtin = @import("builtin");
const c = @import("native/bindings.zig").c;
const Clay = @import("ui/clay.zig").Layout;
const theme_module = @import("ui/theme.zig");
const transcript_view = @import("features/transcript/view.zig");
const TranscriptView = transcript_view.View;
const widgets = @import("ui/widgets.zig");
const LabelCache = @import("ui/label_cache.zig").LabelCache;
const label_cache = @import("ui/label_cache.zig");
const HitTargets = @import("ui/hit_targets.zig").HitTargets;
const EditorView = @import("ui/editor_view.zig").EditorView;
const ModelPicker = @import("features/models/picker.zig").Picker;
const ThinkingMenu = @import("features/models/thinking.zig").Menu;
const Settings = @import("features/settings/settings.zig");
const Library = @import("features/library/panel.zig");
const Composer = @import("text/composer.zig").Composer;
const utf8 = @import("text/utf8.zig");
const ContentWorker = @import("content/worker.zig");
const Draft = @import("core/draft.zig");
const pi = @import("core/runtime.zig");
const SessionCatalog = @import("core/catalog.zig");
const Options = @import("options.zig").Options;
const Paths = @import("platform/paths.zig").Paths;
const build_options = @import("build_options");
const chat = @import("features/chat/chat.zig");
const processes = @import("features/chat/processes.zig");
const updates = @import("features/chat/updates.zig");
const workspace = @import("features/library/workspace.zig");
const conversation = @import("features/transcript/conversation.zig");
const input = @import("app/input.zig");
const view = @import("app/view.zig");

pub const Action = union(enum) { start, new_thread, new_project_thread: usize, new_catalog_thread: usize, toggle_folder: usize, toggle_project_folder: usize, toggle_current_folder, add_project, settings, appearance: Settings.Action, sidebar, open_thread: usize, open_parked: usize, archive_thread: usize, open_library: SessionCatalog.Scope, library: Library.Action, restore_current, send, stop, theme, behavior, latest, models, select_model: usize, thinking, select_thinking: usize, disclosure: transcript_view.Toggle, force_stop, wait };

const theme_path = build_options.asset_directory ++ "/theme.json";

pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    layout: Clay,
    text: *c.SpicaText,
    theme: theme_module.Theme,
    base_metrics: theme_module.Metrics,
    editor: Composer,
    editor_view: EditorView = .{},
    copy_buffer: []u8,
    preedit: std.ArrayList(u8) = .empty,
    labels: LabelCache = .{},
    content: *ContentWorker.Worker,
    draft_writer: *Draft.Writer,
    runtime: ?*pi.Runtime = null,
    runtime_snapshot: ?pi.Snapshot = null,
    parked_chats: std.ArrayList(chat.ParkedChat) = .empty,
    chat_id: u64 = 1,
    next_chat_id: u64 = 2,
    model_restore: ?chat.ModelRestore = null,
    runtime_retiring: bool = false,
    accepted_draft: ?[]u8 = null,
    // Restored drafts for chats not opened since launch. Opening a chat moves its
    // draft into the editor; the rest are written back unchanged.
    stored_drafts: std.ArrayList(Draft.Entry) = .empty,
    closing: bool = false,
    force_dialog: bool = false,
    model_picker: ModelPicker = .{},
    thinking_menu: ThinkingMenu = .{},
    sidebar_visible: bool = true,
    model_bounds: c.SDL_FRect = undefined,
    thinking_bounds: c.SDL_FRect = undefined,
    composer_bounds: c.SDL_FRect = undefined,
    thread_title: chat.Title = .{},
    chat_view: chat.View = .new_thread,
    run_started: ?u64 = null,
    run_base_revision: u64 = 0,
    run_elapsed: ?u64 = null,
    appearance: Settings.Values = .{},
    settings_open: bool = false,
    projects: std.ArrayList([:0]u8) = .empty,
    catalog_error: ?anyerror = null,
    collapsed_folders: std.ArrayList([]u8) = .empty,
    folder_pending: bool = false,
    behavior: pi.Behavior = .prompt,
    draft_revision: u64 = 0,
    submitted_prompt: ?chat.SubmittedPrompt = null,
    accepted_clear_revision: ?u64 = null,
    buttons: HitTargets(Action, 256) = .{},
    follow_bottom: bool = false,
    transcript: TranscriptView,
    catalog_worker: *SessionCatalog.Worker,
    catalog: ?SessionCatalog.Catalog = null,
    library: Library.Panel,
    library_generation: u64 = 0,
    mutation_id: u64 = 0,
    prior_editor_focus: bool = true,
    pending_mutation: ?workspace.PendingMutation = null,
    current_archived: bool = false,
    current_member: bool = false,
    enrollment_intent: bool = false,
    accepted_enrollment: bool = false,
    enrollment_failed: bool = false,
    sidebar_first: usize = 0,
    sidebar_reveal_current: bool = false,
    pending_thread: ?chat.ThreadTarget = null,
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
    error_text: chat.ErrorText = .{},
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
        const theme = try theme_module.load(allocator, io, theme_path);
        var restored = try Draft.restore(io, paths.state);
        defer restored.deinit();
        var editor = try Composer.init(allocator);
        errdefer editor.deinit();
        var library = try Library.Panel.init(allocator);
        errdefer library.deinit();
        var stored_drafts: std.ArrayList(Draft.Entry) = .empty;
        errdefer workspace.freeDrafts(allocator, &stored_drafts);
        try stored_drafts.ensureTotalCapacityPrecise(allocator, restored.value().drafts.len);
        for (restored.value().drafts) |entry| stored_drafts.appendAssumeCapacity(try workspace.dupeDraft(allocator, entry));
        const startup_draft = workspace.draftIndex(stored_drafts.items, options.resume_file orelse "", project_path);
        try editor.setText(if (startup_draft) |index| stored_drafts.items[index].text else restored.legacy_draft);
        if (startup_draft) |index| workspace.freeDraft(allocator, stored_drafts.orderedRemove(index));
        const copy_buffer = try allocator.alloc(u8, 65537);
        errdefer allocator.free(copy_buffer);
        if (!c.spica_image_install_sdl_allocator()) return error.SDLAllocatorInstallation;
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.log.err("SDL video initialization: {s}", .{c.SDL_GetError()});
            return error.SDLInitialization;
        }
        errdefer c.SDL_Quit();
        // The software renderer draws into the window's framebuffer surface. Linux and Windows
        // provide one natively, and the hint keeps SDL from routing it through a GPU renderer.
        // Cocoa has no native window framebuffer, so SDL emulates one with a GPU renderer; with
        // the hint set to "0" that emulation is off and SDL_CreateRenderer fails ("Window
        // framebuffer support not available"). macOS therefore skips the hint: the CPU still
        // draws every frame, and Metal (built into macOS, nothing to install) only presents it.
        // SDL's Wayland backend has no native framebuffer either, so Wayland skips it too.
        const video_driver = if (c.SDL_GetCurrentVideoDriver()) |name| std.mem.span(name) else "";
        const native_framebuffer = builtin.os.tag != .macos and !std.mem.eql(u8, video_driver, "wayland");
        if (options.renderer == .software and native_framebuffer) _ = c.SDL_SetHint(c.SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
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
        const catalog_worker = try SessionCatalog.Worker.create(io, environ, legacy_sessions, paths.database, wake_event);
        errdefer catalog_worker.destroy();
        const saved = restored.value();
        const appearance = Settings.Values{ .font_size = saved.font_size, .ui_scale = saved.ui_scale, .chat_width = saved.chat_width, .light = options.light or saved.light };
        var projects: std.ArrayList([:0]u8) = .empty;
        errdefer {
            for (projects.items) |path| allocator.free(path);
            projects.deinit(allocator);
        }
        {
            const initial_project = try allocator.dupeZ(u8, project_path);
            errdefer allocator.free(initial_project);
            try projects.append(allocator, initial_project);
        }
        for (saved.projects) |path| {
            var duplicate = false;
            for (projects.items) |existing| if (std.mem.eql(u8, existing, path)) {
                duplicate = true;
                break;
            };
            if (!duplicate and projects.items.len < workspace.max_projects) {
                const owned = try allocator.dupeZ(u8, path);
                errdefer allocator.free(owned);
                try projects.append(allocator, owned);
            }
        }
        return .{
            .window = window,
            .renderer = renderer,
            .layout = layout,
            .text = text,
            .theme = .{ .light = theme.light, .dark = theme.dark, .metrics = Settings.metrics(theme.metrics, appearance) },
            .base_metrics = theme.metrics,
            .appearance = appearance,
            .projects = projects,
            .editor = editor,
            .copy_buffer = copy_buffer,
            .content = content,
            .draft_writer = draft_writer,
            .transcript = TranscriptView.init(allocator),
            .chat_view = if (options.resume_file != null) .opening else .new_thread,
            .library = library,
            .enrollment_intent = options.resume_file != null,
            .catalog_worker = catalog_worker,
            .paths = paths,
            .options = options,
            .io = io,
            .allocator = allocator,
            .wake_event = wake_event,
            .project_path = project_path,
            .light = options.light or saved.light,
            .follow_bottom = true,
            .quit_due = if (options.quit_after_ms) |ms| c.SDL_GetTicks() + ms else null,
            .stored_drafts = stored_drafts,
        };
    }

    pub fn deinit(self: *App) void {
        // Queue the final write while every parked chat still owns its draft.
        workspace.saveDraft(self) catch |err| std.log.err("final draft queue: {s}", .{@errorName(err)});
        if (self.runtime) |runtime| runtime.destroy() catch |err| std.log.err("Runtime shutdown invariant: {s}", .{@errorName(err)});
        if (self.runtime_snapshot) |*snapshot| snapshot.deinit();
        for (self.parked_chats.items) |*parked| parked.deinit(self.allocator);
        self.parked_chats.deinit(self.allocator);
        if (self.model_restore) |*settings| settings.deinit(self.allocator);
        if (self.accepted_draft) |draft| self.allocator.free(draft);
        workspace.freeDrafts(self.allocator, &self.stored_drafts);
        self.draft_writer.destroy();
        self.content.destroy();
        self.catalog_worker.destroy();
        if (self.catalog) |*catalog| catalog.deinit();
        self.library.deinit();
        if (self.pending_mutation) |*mutation| mutation.deinit(self.allocator);
        if (self.resume_path) |path| self.allocator.free(path);
        if (self.pending_thread) |target| {
            if (target.path) |path| self.allocator.free(path);
            self.allocator.free(target.cwd);
        }
        _ = c.SDL_StopTextInput(self.window);
        self.editor_view.deinit();
        self.labels.deinit();
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
        for (self.projects.items) |path| self.allocator.free(path);
        self.projects.deinit(self.allocator);
        for (self.collapsed_folders.items) |path| self.allocator.free(path);
        self.collapsed_folders.deinit(self.allocator);
    }

    pub fn clipped(bytes: []const u8) []const u8 {
        return utf8.prefix(bytes, label_cache.max_bytes);
    }

    pub fn palette(self: *App) theme_module.Palette {
        return if (self.light) self.theme.light else self.theme.dark;
    }

    pub fn rectangle(self: *App, x: f32, y: f32, width: f32, height: f32, radius: f32, color: theme_module.Color) !void {
        try widgets.panel(self.renderer, .{ .x = x, .y = y, .w = width, .h = height }, radius, color);
    }

    pub fn label(self: *App, bytes: []const u8, x: f32, top: f32, size: c_uint, color: theme_module.Color) !void {
        try self.labels.draw(self.text, bytes, x, top, size, color);
    }

    pub fn labelWidth(self: *App, bytes: []const u8, size: c_uint) !f32 {
        return self.labels.width(self.text, bytes, size);
    }

    pub fn fitLabel(self: *App, bytes: []const u8, x: f32, top: f32, width: f32, size: c_uint, color: theme_module.Color) !void {
        try self.labels.drawFitted(self.renderer, self.text, bytes, x, top, width, size, color);
    }

    pub fn hit(self: *App, action: Action, bounds: c.SDL_FRect) !void {
        try self.buttons.add(action, bounds);
    }

    pub fn button(self: *App, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
        try self.hit(action, bounds);
        try self.rectangle(bounds.x, bounds.y, bounds.w, bounds.h, 6, self.palette().raised);
        try self.label(clipped(text), bounds.x + 10, bounds.y + 8, 13, self.palette().text);
    }

    pub fn flatButton(self: *App, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
        try self.hit(action, bounds);
        const reserve: f32 = switch (action) {
            .models, .thinking => 28,
            else => 16,
        };
        try self.fitLabel(clipped(text), bounds.x + 8, bounds.y + 7, @max(0, bounds.w - reserve), 13, self.palette().muted);
    }

    pub fn iconButton(self: *App, action: Action, kind: widgets.Icon, bounds: c.SDL_FRect, color: theme_module.Color) !void {
        try self.hit(action, bounds);
        try widgets.icon(self.renderer, kind, .{ .x = bounds.x + (bounds.w - 16) / 2, .y = bounds.y + (bounds.h - 16) / 2, .w = 16, .h = 16 }, color);
    }

    pub fn title(self: *const App) []const u8 {
        if (self.options.fixture) return "Resource scene";
        if (self.chat_view == .opening) return if (self.thread_title.isEmpty()) "Opening chat..." else self.thread_title.slice();
        if (self.runtime_snapshot) |snapshot| if (snapshot.session_name.len != 0) return clipped(snapshot.session_name);
        return if (self.thread_title.isEmpty()) "New thread" else self.thread_title.slice();
    }

    pub fn report(self: *App, operation: []const u8, err: anyerror) void {
        self.error_text.print("{s}: {s}", .{ operation, @errorName(err) }, "Error message exceeds display budget");
        std.log.err("{s}", .{self.error_text.slice()});
        self.dirty = true;
    }

    pub fn requestConversation(self: *App) void {
        self.conversation_dirty = true;
        self.dirty = true;
    }

    pub fn edited(self: *App) void {
        self.draft_revision += 1;
        self.editor_view.preferred_x = null;
        self.editor_view.changed = true;
        workspace.scheduleSave(self);
        self.dirty = true;
    }

    pub fn syncTextInput(self: *App) void {
        if (self.focused_editor) _ = c.SDL_StartTextInput(self.window) else _ = c.SDL_StopTextInput(self.window);
    }

    pub fn reloadTheme(self: *App) !void {
        const next = try theme_module.load(self.allocator, self.io, theme_path);
        self.theme = next;
        self.base_metrics = next.metrics;
        self.theme.metrics = Settings.metrics(next.metrics, self.appearance);
        self.transcript.invalidateLayouts();
        self.editor_view.width = 0;
        self.error_text.clear();
        self.dirty = true;
    }

    pub fn consume(self: *App) void {
        updates.consumeRuntime(self);
        updates.consumeParked(self);
        workspace.consumeCatalog(self);
        if (self.draft_writer.takeError()) |err| self.report("Draft could not be saved", err);
        conversation.consume(self);
    }

    pub fn run(self: *App) !void {
        errdefer processes.retainOwnedProcessOnError(self);
        if (self.options.fixture) self.requestConversation() else processes.beginRuntime(self) catch |err| self.report("Starting pi", err);
        while (self.running) {
            self.consume();
            const now = c.SDL_GetTicks();
            if (self.quit_due) |due| if (now >= due) {
                self.quit_due = null;
                try processes.requestClose(self);
                if (!self.running) continue;
            };
            if (self.draft_due) |due| if (now >= due) {
                workspace.saveDraft(self) catch |err| self.report("Saving draft", err);
                self.draft_due = null;
            };
            if (self.dirty and !self.minimized) try view.paint(self);
            conversation.pump(self) catch |err| self.report("Loading viewport", err);
            var event: c.SDL_Event = undefined;
            const timeout = self.waitTimeout();
            if (c.SDL_WaitEventTimeout(&event, timeout)) {
                input.handle(self, &event) catch |err| self.report("Input", err);
                while (c.SDL_PollEvent(&event)) input.handle(self, &event) catch |err| self.report("Input", err);
            } else if (timeout == -1) return error.EventWait;
        }
        std.log.info("Spica closed; presented_frames={d}", .{self.frames});
    }

    fn waitTimeout(self: *const App) c_int {
        var timeout: c_int = -1;
        for ([_]?u64{ self.quit_due, self.draft_due }) |deadline| if (deadline) |due| {
            const remaining: c_int = @intCast(@min(2147483647, due -| c.SDL_GetTicks()));
            timeout = if (timeout == -1) remaining else @min(timeout, remaining);
        };
        return timeout;
    }
};

test {
    _ = chat;
    _ = processes;
    _ = updates;
    _ = workspace;
    _ = conversation;
    _ = input;
    _ = view;
    _ = @import("features/library/sidebar.zig");
    _ = @import("features/models/menus.zig");
    _ = @import("app/commands.zig");
}
