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
const Settings = @import("ui/settings.zig");
const Library = @import("ui/library.zig");
const ModelSearch = @import("ui/model_search.zig").Search;

const Label = struct { bytes: [128]u8 = undefined, len: usize = 0, size: c_uint = 0, layout: ?*c.SpicaTextLayout = null, used: u64 = 0 };
const Action = union(enum) { start, new_thread, new_project_thread: usize, new_catalog_thread: usize, toggle_folder: usize, toggle_project_folder: usize, toggle_current_folder, add_project, settings, appearance: Settings.Action, sidebar, open_thread: usize, open_parked: usize, archive_thread: usize, open_library: SessionCatalog.Scope, library: Library.Action, restore_current, send, stop, theme, behavior, latest, models, select_model: usize, thinking, select_thinking: usize, disclosure: @import("ui/transcript.zig").Toggle, force_stop, wait };
const ThreadTarget = struct { path: ?[:0]u8, cwd: [:0]u8, archived: bool = false };
const SubmittedPrompt = struct { token: u64, draft_revision: u64 };
const ChatView = enum { new_thread, opening, existing };
const ModelRestore = struct {
    provider: []u8,
    model: []u8,
    thinking: []u8,

    fn deinit(self: *ModelRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.thinking);
    }
};

// Inactive chats retain only runtime metadata and bounded draft text. The single
// viewport, text layouts, and composer undo storage stay with the active chat.
const ParkedChat = struct {
    id: u64,
    runtime: ?*pi.Runtime,
    snapshot: ?pi.Snapshot,
    cwd: [:0]u8,
    path: ?[:0]u8,
    trust: ?bool,
    model_restore: ?ModelRestore = null,
    draft: []u8,
    caret: usize,
    anchor: usize,
    draft_revision: u64,
    submitted: ?SubmittedPrompt,
    accepted_clear_revision: ?u64,
    cleared_draft: ?[]u8 = null,
    title: [128]u8,
    title_len: usize,
    view: ChatView,
    archived: bool,
    member: bool,
    enrollment_intent: bool,
    accepted_enrollment: bool,
    enrollment_failed: bool,
    run_started: ?u64,
    run_base_revision: u64,
    run_elapsed: ?u64,
    behavior: pi.Behavior,
    error_text: [512]u8,
    error_len: usize,
    scroll: f32,
    retiring: bool = false,

    fn session(self: *const ParkedChat) []const u8 {
        if (self.snapshot) |snapshot| if (snapshot.session_file.len != 0) return snapshot.session_file;
        return self.path orelse "";
    }

    fn deinit(self: *ParkedChat, allocator: std.mem.Allocator) void {
        if (self.runtime) |runtime| runtime.destroy() catch |err| std.log.err("Parked runtime shutdown invariant: {s}", .{@errorName(err)});
        if (self.snapshot) |*snapshot| snapshot.deinit();
        allocator.free(self.cwd);
        if (self.path) |path| allocator.free(path);
        allocator.free(self.draft);
        if (self.cleared_draft) |draft| allocator.free(draft);
        if (self.model_restore) |*settings| settings.deinit(allocator);
    }
};
const PendingMutation = struct {
    id: u64,
    kind: SessionCatalog.Mutation,
    path: [:0]u8,
    cwd: [:0]u8,
    title: []u8,
    open_after: bool,
    automatic: bool,
    owner_id: ?u64 = null,

    fn deinit(self: *PendingMutation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.cwd);
        allocator.free(self.title);
    }
};
const Button = struct { bounds: c.SDL_FRect, action: Action };

fn modelsEqual(a: []const pi.Model, b: []const pi.Model) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name) or
            !std.mem.eql(u8, left.id, right.id) or
            !std.mem.eql(u8, left.provider, right.provider)) return false;
    }
    return true;
}

fn folderChosen(userdata: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(@intFromPtr(userdata));
    event.user.code = 1;
    if (files == null) event.user.code = 2;
    if (files != null and files[0] != null) event.user.data1 = c.SDL_strdup(files[0]);
    if (!c.SDL_PushEvent(&event)) if (event.user.data1) |path| c.SDL_free(path);
}

pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    layout: Clay,
    text: *c.SpicaText,
    theme: theme_module.Theme,
    base_metrics: theme_module.Metrics,
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
    parked_chats: std.ArrayList(ParkedChat) = .empty,
    chat_id: u64 = 1,
    next_chat_id: u64 = 2,
    model_restore: ?ModelRestore = null,
    runtime_retiring: bool = false,
    accepted_draft: ?[]u8 = null,
    closing: bool = false,
    force_dialog: bool = false,
    model_menu: bool = false,
    // Ranks into model_search: the first visible row and the highlighted row.
    model_first: usize = 0,
    model_highlight: usize = 0,
    model_visible: usize = 1,
    model_selection_cleared: bool = false,
    model_search: ModelSearch = .{},
    thinking_menu: bool = false,
    thinking_highlight: usize = 0,
    // A menu hover that arrived while row targets were cleared, retried after the next paint.
    pending_hover: ?[2]f32 = null,
    sidebar_visible: bool = true,
    editor_bounds: c.SDL_FRect = undefined,
    model_bounds: c.SDL_FRect = undefined,
    model_popup_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    thinking_bounds: c.SDL_FRect = undefined,
    composer_bounds: c.SDL_FRect = undefined,
    thread_title: [128]u8 = undefined,
    thread_title_len: usize = 0,
    chat_view: ChatView = .new_thread,
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
    submitted_prompt: ?SubmittedPrompt = null,
    accepted_clear_revision: ?u64 = null,
    buttons: [256]Button = undefined,
    button_count: usize = 0,
    follow_bottom: bool = false,
    transcript: TranscriptView,
    catalog_worker: *SessionCatalog.Worker,
    catalog: ?SessionCatalog.Catalog = null,
    library: Library.Panel,
    library_generation: u64 = 0,
    mutation_id: u64 = 0,
    prior_editor_focus: bool = true,
    pending_mutation: ?PendingMutation = null,
    current_archived: bool = false,
    current_member: bool = false,
    enrollment_intent: bool = false,
    accepted_enrollment: bool = false,
    enrollment_failed: bool = false,
    sidebar_first: usize = 0,
    sidebar_reveal_current: bool = false,
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
        var library = try Library.Panel.init(allocator);
        errdefer library.deinit();
        try editor.setText(restored.value().draft);
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
            if (!duplicate and projects.items.len < 64) {
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
            .light = options.light or restored.value().light,
            .follow_bottom = true,
            .quit_due = if (options.quit_after_ms) |ms| c.SDL_GetTicks() + ms else null,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.runtime) |runtime| runtime.destroy() catch |err| std.log.err("Runtime shutdown invariant: {s}", .{@errorName(err)});
        if (self.runtime_snapshot) |*snapshot| snapshot.deinit();
        for (self.parked_chats.items) |*chat| chat.deinit(self.allocator);
        self.parked_chats.deinit(self.allocator);
        if (self.model_restore) |*settings| settings.deinit(self.allocator);
        if (self.accepted_draft) |draft| self.allocator.free(draft);
        self.saveDraft() catch |err| std.log.err("final draft queue: {s}", .{@errorName(err)});
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
        for (self.projects.items) |path| self.allocator.free(path);
        self.projects.deinit(self.allocator);
        for (self.collapsed_folders.items) |path| self.allocator.free(path);
        self.collapsed_folders.deinit(self.allocator);
    }

    pub fn palette(self: *App) theme_module.Palette {
        return if (self.light) self.theme.light else self.theme.dark;
    }
    fn rgba(color: theme_module.Color) c.SDL_Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
    }
    pub fn rectangle(self: *App, x: f32, y: f32, width: f32, height: f32, radius: f32, color: theme_module.Color) !void {
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

    pub fn label(self: *App, bytes: []const u8, x: f32, top: f32, size: c_uint, color: theme_module.Color) !void {
        if (!c.spica_text_layout_draw(self.text, try self.labelLayout(bytes, size), x, top, rgba(color))) return error.LabelDraw;
    }

    fn labelWidth(self: *App, bytes: []const u8, size: c_uint) !f32 {
        var row: c.SpicaTextLine = undefined;
        return if (c.spica_text_layout_line(try self.labelLayout(bytes, size), 0, &row)) row.width else 0;
    }

    fn fitLabel(self: *App, bytes: []const u8, x: f32, top: f32, width: f32, size: c_uint, color: theme_module.Color) !void {
        if (width <= 0) return;
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
        if (self.chat_view == .opening) return if (self.thread_title_len != 0) self.thread_title[0..self.thread_title_len] else "Opening chat...";
        if (self.runtime_snapshot) |snapshot| if (snapshot.session_name.len != 0) return clippedLabel(snapshot.session_name);
        return if (self.thread_title_len != 0) self.thread_title[0..self.thread_title_len] else "New thread";
    }

    fn report(self: *App, operation: []const u8, err: anyerror) void {
        const text = std.fmt.bufPrint(&self.error_text, "{s}: {s}", .{ operation, @errorName(err) }) catch "Error message exceeds display budget";
        self.error_len = text.len;
        self.formatting_error = false;
        std.log.err("{s}", .{text});
        self.dirty = true;
    }

    fn requestConversation(self: *App) void {
        self.conversation_dirty = true;
        self.dirty = true;
    }

    fn pumpContent(self: *App) !void {
        if (self.content_pending or self.minimized) return;
        if (self.chat_view == .opening) {
            if (self.pending_thread != null) return;
            const snapshot = self.runtime_snapshot orelse return;
            if (snapshot.visible_revision == 0) return;
        }
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

    fn addProject(self: *App, path: []const u8) !void {
        for (self.projects.items) |existing| if (std.mem.eql(u8, existing, path)) return;
        if (self.projects.items.len == 64) return error.ProjectLimitReached;
        const owned = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(owned);
        try self.projects.append(self.allocator, owned);
        self.draft_due = c.SDL_GetTicks() + 250;
    }

    fn newThreadIn(self: *App, path: []const u8) !void {
        if (self.pending_mutation) |mutation| if (!mutation.automatic) return error.WorkspaceMutationPending;
        if (self.pending_thread != null or self.closing) return error.ThreadSwitchPending;
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(cwd);
        var dir = try std.Io.Dir.cwd().openDir(self.io, cwd, .{});
        dir.close(self.io);
        if (self.projects.items.len < 64) try self.addProject(cwd);
        try self.saveDraft();
        self.pending_thread = .{ .path = null, .cwd = cwd };
        transferred = true;
        try self.finishThreadSwitch();
    }

    fn openThread(self: *App, index: usize) !void {
        const catalog = self.catalog orelse return;
        if (index >= catalog.threads.len) return;
        const thread = catalog.threads[index];
        try self.openSource(thread.path, thread.cwd, thread.title, thread.archived, thread.available);
    }

    fn openSource(self: *App, source: []const u8, project: []const u8, title_text: []const u8, archived: bool, available: bool) !void {
        if (self.pending_thread != null or self.closing) return error.ThreadSwitchPending;
        if (self.pending_mutation) |mutation| if (!mutation.automatic) return error.WorkspaceMutationPending;
        if (std.mem.eql(u8, self.currentSession(), source)) {
            self.current_archived = archived;
            self.current_member = true;
            self.follow_bottom = true;
            self.dirty = true;
            return;
        }
        for (self.parked_chats.items, 0..) |chat, index| {
            if (!std.mem.eql(u8, chat.session(), source)) continue;
            try self.saveDraft();
            try self.activateParked(index);
            self.current_archived = archived;
            self.current_member = true;
            self.revealCurrentFolder();
            return;
        }
        if (!available) return error.SessionSourceUnavailable;
        try SessionCatalog.validateSource(self.io, source, project);
        var transferred = false;
        const path = try self.allocator.dupeZ(u8, source);
        errdefer if (!transferred) self.allocator.free(path);
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, project, self.allocator);
        errdefer if (!transferred) self.allocator.free(cwd);
        try self.saveDraft();
        self.pending_thread = .{ .path = path, .cwd = cwd, .archived = archived };
        transferred = true;
        try self.finishThreadSwitch();
        const name = clippedLabel(title_text);
        @memcpy(self.thread_title[0..name.len], name);
        self.thread_title_len = name.len;
    }

    fn parkCurrent(self: *App) !void {
        const draft = try self.allocator.dupe(u8, self.editor.textBytes());
        errdefer self.allocator.free(draft);
        const path: ?[:0]u8 = if (self.resume_path) |owned| owned else if (self.options.resume_file) |source| try self.allocator.dupeZ(u8, source) else null;
        errdefer if (self.resume_path == null) if (path) |owned| self.allocator.free(owned);
        try self.parked_chats.append(self.allocator, .{
            .id = self.chat_id,
            .runtime = self.runtime,
            .snapshot = self.runtime_snapshot,
            .cwd = self.project_path,
            .path = path,
            .trust = self.options.trust_project,
            .draft = draft,
            .caret = self.editor.caret,
            .anchor = self.editor.anchor,
            .draft_revision = self.draft_revision,
            .submitted = self.submitted_prompt,
            .accepted_clear_revision = self.accepted_clear_revision,
            .cleared_draft = self.accepted_draft,
            .model_restore = self.model_restore,
            .title = self.thread_title,
            .title_len = self.thread_title_len,
            .view = self.chat_view,
            .archived = self.current_archived,
            .member = self.current_member,
            .enrollment_intent = self.enrollment_intent,
            .accepted_enrollment = self.accepted_enrollment,
            .enrollment_failed = self.enrollment_failed,
            .run_started = self.run_started,
            .run_base_revision = self.run_base_revision,
            .run_elapsed = self.run_elapsed,
            .behavior = self.behavior,
            .error_text = self.error_text,
            .error_len = self.error_len,
            .scroll = self.scroll,
            .retiring = self.runtime_retiring,
        });
        self.runtime = null;
        self.runtime_snapshot = null;
        self.resume_path = null;
        self.accepted_draft = null;
        self.model_restore = null;
        self.runtime_retiring = false;
    }

    fn resetChatViewport(self: *App) void {
        self.transcript.clear();
        self.generation += 1;
        self.content_pending = false;
        self.pending_ordinal = null;
        self.conversation_dirty = false;
        self.closeModelMenu();
        self.thinking_menu = false;
        self.preedit.clearRetainingCapacity();
        _ = c.SDL_ClearComposition(self.window);
        self.dragging = false;
        self.editor_scroll = 0;
        self.editor_start = 0;
        self.editor_end = 0;
        self.editor_width = 0;
        self.preferred_caret_x = null;
        self.editor_changed = true;
        self.button_count = 0;
        self.draft_due = c.SDL_GetTicks() + 250;
        self.dirty = true;
    }

    fn activateParked(self: *App, index: usize) !void {
        // Reserve before transferring ownership; a failed allocation leaves the
        // active chat and every runtime intact.
        try self.parkCurrent();
        const chat = self.parked_chats.orderedRemove(index);
        defer self.allocator.free(chat.draft);
        self.chat_id = chat.id;
        self.runtime = chat.runtime;
        self.runtime_snapshot = chat.snapshot;
        self.project_path = chat.cwd;
        self.resume_path = chat.path;
        self.options.resume_file = chat.path;
        self.options.trust_project = chat.trust;
        self.model_restore = chat.model_restore;
        self.accepted_draft = chat.cleared_draft;
        self.runtime_retiring = chat.retiring;
        try self.editor.setText(chat.draft);
        self.editor.setCaret(chat.anchor, false);
        self.editor.setCaret(chat.caret, true);
        self.draft_revision = chat.draft_revision;
        self.submitted_prompt = chat.submitted;
        self.accepted_clear_revision = chat.accepted_clear_revision;
        self.thread_title = chat.title;
        self.thread_title_len = chat.title_len;
        self.chat_view = chat.view;
        self.current_archived = chat.archived;
        self.current_member = chat.member;
        self.enrollment_intent = chat.enrollment_intent;
        self.accepted_enrollment = chat.accepted_enrollment;
        self.enrollment_failed = chat.enrollment_failed;
        self.run_started = chat.run_started;
        self.run_base_revision = chat.run_base_revision;
        self.run_elapsed = chat.run_elapsed;
        self.behavior = chat.behavior;
        self.error_text = chat.error_text;
        self.error_len = chat.error_len;
        self.formatting_error = false;
        self.scroll = chat.scroll;
        self.follow_bottom = false;
        self.resetChatViewport();
        if (chat.retiring) {
            // Shutdown cannot be reversed. Keep ownership until exit before
            // starting its replacement, so this session never has two writers.
            self.dirty = true;
        } else if (self.runtime == null or self.runtime.?.isFinished()) {
            try self.beginRuntime();
        }
        self.requestConversation();
    }

    fn finishThreadSwitch(self: *App) !void {
        const target = self.pending_thread orelse return;
        const trust = self.options.trust_project != null and self.options.trust_project.? and std.mem.eql(u8, self.project_path, target.cwd);
        try self.parkCurrent();
        self.pending_thread = null;
        self.chat_id = self.next_chat_id;
        self.next_chat_id += 1;
        self.project_path = target.cwd;
        self.resume_path = target.path;
        self.options.resume_file = target.path;
        self.options.trust_project = trust;
        self.current_archived = target.archived;
        self.current_member = target.path != null;
        self.enrollment_intent = false;
        self.enrollment_failed = false;
        self.accepted_enrollment = false;
        self.submitted_prompt = null;
        self.accepted_clear_revision = null;
        self.draft_revision = 0;
        try self.editor.setText("");
        self.thread_title_len = 0;
        self.chat_view = if (target.path == null) .new_thread else .opening;
        self.run_started = null;
        self.run_elapsed = null;
        self.run_base_revision = 0;
        self.behavior = .prompt;
        self.error_len = 0;
        self.formatting_error = false;
        self.scroll = 0;
        self.follow_bottom = true;
        self.resetChatViewport();
        self.revealCurrentFolder();
        try self.beginRuntime();
    }

    fn runtimeStatus(self: *const App) pi.Status {
        const status = if (self.runtime_snapshot) |snapshot| snapshot.status else .stopped;
        return if (self.runtime_retiring and status == .ready) .stopping else status;
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
        if (self.model_restore == null) if (self.runtime_snapshot) |snapshot| {
            const provider = try self.allocator.dupe(u8, snapshot.provider);
            errdefer self.allocator.free(provider);
            const model = try self.allocator.dupe(u8, snapshot.model);
            errdefer self.allocator.free(model);
            const thinking = try self.allocator.dupe(u8, snapshot.thinking_level);
            self.model_restore = .{ .provider = provider, .model = model, .thinking = thinking };
        };
        self.runtime_retiring = false;
        if (self.runtime_snapshot) |*snapshot| snapshot.deinit();
        self.runtime_snapshot = null;
        self.closeModelMenu();
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

    fn ownedRuntimesFinished(self: *const App) bool {
        if (self.runtime) |runtime| if (!runtime.isFinished()) return false;
        for (self.parked_chats.items) |chat| if (chat.runtime) |runtime| if (!runtime.isFinished()) return false;
        return true;
    }

    fn shutdownOwned(self: *App) !void {
        var failure: ?anyerror = null;
        if (self.runtime) |runtime| if (!runtime.isFinished()) {
            runtime.shutdown() catch |err| {
                failure = err;
            };
        };
        for (self.parked_chats.items) |*chat| if (chat.runtime) |runtime| if (!runtime.isFinished()) {
            runtime.shutdown() catch |err| {
                failure = err;
            };
            chat.retiring = true;
        };
        if (failure) |err| return err;
    }

    fn needsForceStop(self: *const App) bool {
        if (self.runtime) |runtime| if (!runtime.isFinished() and self.runtimeStatus() == .needs_force_stop) return true;
        for (self.parked_chats.items) |chat| if (chat.runtime) |runtime| if (!runtime.isFinished()) {
            if (chat.snapshot) |snapshot| if (snapshot.status == .needs_force_stop) return true;
        };
        return false;
    }

    fn forceOwned(self: *App) !void {
        var failure: ?anyerror = null;
        if (self.runtime) |runtime| if (!runtime.isFinished() and (self.closing or self.runtimeStatus() == .needs_force_stop)) {
            runtime.forceTerminate() catch |err| {
                failure = err;
            };
        };
        for (self.parked_chats.items) |chat| if (chat.runtime) |runtime| if (!runtime.isFinished()) {
            if (self.closing or (chat.snapshot != null and chat.snapshot.?.status == .needs_force_stop)) {
                runtime.forceTerminate() catch |err| {
                    failure = err;
                };
            }
        };
        if (failure) |err| return err;
    }

    fn closeSettled(self: *const App) bool {
        if (!self.ownedRuntimesFinished() or self.pending_mutation != null or self.submitted_prompt != null or
            (self.enrollment_intent and !self.enrollment_failed)) return false;
        for (self.parked_chats.items) |chat| if (chat.submitted != null or (chat.enrollment_intent and !chat.enrollment_failed)) return false;
        return true;
    }

    fn requestClose(self: *App) !void {
        if (!self.closing) {
            try self.saveDraft();
            self.closeModelMenu();
            self.closing = true;
            self.focused_editor = false;
            _ = c.SDL_StopTextInput(self.window);
            self.dirty = true;
            try self.shutdownOwned();
        }
        self.enrollCurrent();
        if (self.closeSettled()) self.running = false;
    }

    fn requestLatest(self: *App) void {
        self.follow_bottom = true;
        self.requestConversation();
    }

    fn consumeRuntime(self: *App) void {
        const runtime = self.runtime orelse return;
        if (runtime.takeSnapshot()) |incoming| {
            const previous_status = self.runtimeStatus();
            const canonical_changed = self.runtime_snapshot == null or incoming.visible_revision != self.runtime_snapshot.?.visible_revision;
            const generation_changed = self.runtime_snapshot != null and incoming.generation != self.runtime_snapshot.?.generation;
            const session_changed = incoming.session_file.len != 0 and (self.runtime_snapshot == null or !std.mem.eql(u8, self.runtime_snapshot.?.session_file, incoming.session_file));
            const changed_error = incoming.error_message.len != 0 and (self.runtime_snapshot == null or !std.mem.eql(u8, self.runtime_snapshot.?.error_message, incoming.error_message));
            const recovery_changed = incoming.recovery_revision != 0 and (self.runtime_snapshot == null or incoming.recovery_revision != self.runtime_snapshot.?.recovery_revision);
            self.updateModelSearch(incoming.models) catch |err| {
                self.model_search.invalidate();
                self.model_selection_cleared = true;
                self.button_count = 0;
                self.report("Refreshing model choices", err);
            };
            if (self.runtime_snapshot) |*old| old.deinit();
            self.runtime_snapshot = incoming;
            const snapshot = &self.runtime_snapshot.?;
            if (snapshot.status == .ready) if (self.model_restore) |settings| {
                self.model_restore = null;
                var owned = settings;
                defer owned.deinit(self.allocator);
                if (settings.model.len != 0) runtime.setModel(settings.provider, settings.model) catch |err| self.report("Restoring chat model", err);
                if (settings.thinking.len != 0) runtime.setThinkingLevel(settings.thinking) catch |err| self.report("Restoring chat thinking level", err);
            };
            if (session_changed or generation_changed) {
                if (self.chat_view != .opening) self.thread_title_len = 0;
                if (snapshot.session_name.len == 0 and self.thread_title_len == 0) if (self.catalog) |catalog| {
                    for (catalog.threads) |thread| {
                        if (!std.mem.eql(u8, thread.path, snapshot.session_file)) continue;
                        const name = clippedLabel(thread.title);
                        @memcpy(self.thread_title[0..name.len], name);
                        self.thread_title_len = name.len;
                        break;
                    }
                };
                if (generation_changed) {
                    self.run_started = null;
                    self.run_elapsed = null;
                    self.behavior = .prompt;
                }
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
                    if (!self.current_member) {
                        self.enrollment_intent = true;
                        self.enrollment_failed = false;
                        self.accepted_enrollment = true;
                    }
                    if (self.draft_revision == submitted.draft_revision) {
                        const saved = self.allocator.dupe(u8, self.editor.textBytes()) catch |err| {
                            self.report("Retaining accepted draft", err);
                            return;
                        };
                        if (self.accepted_draft) |old| self.allocator.free(old);
                        self.accepted_draft = saved;
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
                if (self.editor.undo()) {
                    self.edited();
                } else if (self.accepted_draft) |draft| {
                    self.editor.setText(draft) catch |err| self.report("Recovering rejected input", err);
                    self.edited();
                }
            }
            if (self.run_started) |started| {
                if (snapshot.status == .ready and snapshot.visible_revision > self.run_base_revision and std.mem.eql(u8, snapshot.content_status, "complete")) {
                    self.run_elapsed = c.SDL_GetTicks() - started;
                    self.run_started = null;
                }
            }
            if (snapshot.status == .needs_force_stop and previous_status != .needs_force_stop) self.force_dialog = true;
            if (snapshot.status == .ready and (previous_status == .streaming or canonical_changed)) self.catalog_worker.refresh();
            self.enrollCurrent();
            self.dirty = true;
        }
        if (runtime.isFinished()) {
            self.submitted_prompt = null;
            self.enrollCurrent();
            if (self.enrollment_intent and !self.enrollment_failed and self.pending_mutation == null) {
                self.enrollment_failed = true;
                self.report("Accepted chat has no resumable source path", error.SessionPathUnavailable);
            }
            if (self.runtime_retiring and !self.closing) self.beginRuntime() catch |err| self.report("Restarting parked chat", err);
        }
        if (!self.closing) self.finishThreadSwitch() catch |err| self.report("Opening thread", err);
    }
    fn parkedFailure(chat: *ParkedChat, operation: []const u8, err: anyerror) void {
        const text = std.fmt.bufPrint(&chat.error_text, "{s}: {s}", .{ operation, @errorName(err) }) catch "Background chat error";
        chat.error_len = text.len;
        std.log.err("{s}", .{text});
    }

    fn replaceParkedDraft(self: *App, chat: *ParkedChat, text: []const u8) !void {
        if (text.len > @import("text/composer.zig").max_bytes) return error.TextTooLarge;
        const draft = try self.allocator.dupe(u8, text);
        self.allocator.free(chat.draft);
        chat.draft = draft;
        chat.caret = text.len;
        chat.anchor = text.len;
        chat.draft_revision += 1;
    }

    fn consumeParkedSnapshot(self: *App, chat: *ParkedChat, incoming: pi.Snapshot) !void {
        const old = chat.snapshot;
        const previous_status: pi.Status = if (old) |snapshot| snapshot.status else .stopped;
        const canonical_changed = old == null or incoming.visible_revision != old.?.visible_revision;
        const recovery_changed = incoming.recovery_revision != 0 and (old == null or incoming.recovery_revision != old.?.recovery_revision);
        const changed_error = incoming.error_message.len != 0 and (old == null or !std.mem.eql(u8, old.?.error_message, incoming.error_message));
        const generation_changed = old != null and incoming.generation != old.?.generation;
        if (chat.snapshot) |*snapshot| snapshot.deinit();
        chat.snapshot = incoming;
        if (incoming.status == .ready) if (chat.model_restore) |settings| {
            chat.model_restore = null;
            var owned = settings;
            defer owned.deinit(self.allocator);
            const runtime = chat.runtime.?;
            if (settings.model.len != 0) runtime.setModel(settings.provider, settings.model) catch |err| parkedFailure(chat, "Restoring chat model", err);
            if (settings.thinking.len != 0) runtime.setThinkingLevel(settings.thinking) catch |err| parkedFailure(chat, "Restoring chat thinking level", err);
        };
        if (generation_changed) {
            chat.run_started = null;
            chat.run_elapsed = null;
            chat.behavior = .prompt;
            chat.scroll = 0;
        }
        if (changed_error) {
            const text = clippedLabel(incoming.error_message);
            @memcpy(chat.error_text[0..text.len], text);
            chat.error_len = text.len;
            std.log.err("Background pi: {s}", .{incoming.error_message});
        }
        if (chat.submitted) |submitted| {
            var buffer: [32]u8 = undefined;
            const id = std.fmt.bufPrint(&buffer, "desktop-{d}", .{submitted.token}) catch unreachable;
            if (std.mem.eql(u8, incoming.accepted_command_id, id)) {
                chat.submitted = null;
                if (!chat.member) {
                    chat.enrollment_intent = true;
                    chat.accepted_enrollment = true;
                    chat.enrollment_failed = false;
                }
                if (chat.draft_revision == submitted.draft_revision) {
                    const cleared = try self.allocator.dupe(u8, chat.draft);
                    errdefer self.allocator.free(cleared);
                    try self.replaceParkedDraft(chat, "");
                    if (chat.cleared_draft) |draft| self.allocator.free(draft);
                    chat.cleared_draft = cleared;
                    chat.accepted_clear_revision = chat.draft_revision;
                }
            } else if (std.mem.eql(u8, incoming.rejected_command_id, id) or chat.runtime.?.isFinished()) {
                chat.submitted = null;
            }
        }
        if (recovery_changed and incoming.pending_draft.len != 0 and chat.draft.len == 0 and chat.submitted == null) {
            try self.replaceParkedDraft(chat, incoming.pending_draft);
        }
        if (incoming.session_file.len != 0 and (chat.path == null or !std.mem.eql(u8, chat.path.?, incoming.session_file))) {
            const path = try self.allocator.dupeZ(u8, incoming.session_file);
            if (chat.path) |previous| self.allocator.free(previous);
            chat.path = path;
        }
        if (changed_error and incoming.visible_length == 0 and incoming.status == .ready and chat.run_started != null and
            chat.accepted_clear_revision == chat.draft_revision and chat.draft.len == 0)
        {
            if (chat.cleared_draft) |draft| try self.replaceParkedDraft(chat, draft);
        }
        if (chat.run_started) |started| {
            if (incoming.status == .ready and incoming.visible_revision > chat.run_base_revision and std.mem.eql(u8, incoming.content_status, "complete")) {
                chat.run_elapsed = c.SDL_GetTicks() - started;
                chat.run_started = null;
            }
        }
        if (incoming.status == .needs_force_stop and previous_status != .needs_force_stop) self.force_dialog = true;
        if (incoming.status == .ready and (previous_status == .streaming or canonical_changed)) self.catalog_worker.refresh();
        // The recovery revision, not its copied text, is needed for subsequent
        // snapshots. The recovered text now belongs to this chat's draft.
        if (chat.snapshot) |*snapshot| {
            self.allocator.free(snapshot.pending_draft);
            snapshot.pending_draft = "";
        }
        self.dirty = true;
    }

    fn enrollParked(self: *App, chat: *ParkedChat) void {
        if (!chat.enrollment_intent or chat.enrollment_failed or self.pending_mutation != null) return;
        const snapshot = chat.snapshot orelse return;
        if (snapshot.session_file.len == 0 or (!chat.accepted_enrollment and (snapshot.status == .starting or snapshot.status == .failed))) return;
        if (!chat.accepted_enrollment) SessionCatalog.validateSource(self.io, snapshot.session_file, chat.cwd) catch |err| {
            chat.enrollment_failed = true;
            parkedFailure(chat, "Explicit resume source could not be enrolled", err);
            return;
        };
        const title_text = if (snapshot.session_name.len != 0) snapshot.session_name else chat.title[0..chat.title_len];
        self.queueMutation(.enroll, snapshot.session_file, chat.cwd, title_text, false, true) catch |err| {
            chat.enrollment_failed = true;
            parkedFailure(chat, "Enrolling accepted chat; Ctrl/Cmd+R retries", err);
            return;
        };
        self.pending_mutation.?.owner_id = chat.id;
    }

    fn consumeParked(self: *App) void {
        var idle_count: usize = 0;
        // Keep a small most-recent idle pool. Busy chats are never retired for
        // resource pressure; compact drafts outlive an idle child process.
        var index = self.parked_chats.items.len;
        while (index != 0) {
            index -= 1;
            const chat = &self.parked_chats.items[index];
            if (chat.runtime) |runtime| {
                if (runtime.takeSnapshot()) |snapshot| self.consumeParkedSnapshot(chat, snapshot) catch |err| parkedFailure(chat, "Updating background chat", err);
                self.enrollParked(chat);
                if (runtime.isFinished()) {
                    chat.submitted = null;
                    if (chat.enrollment_intent and !chat.enrollment_failed and self.pending_mutation == null and
                        (chat.snapshot == null or chat.snapshot.?.session_file.len == 0))
                    {
                        chat.enrollment_failed = true;
                        parkedFailure(chat, "Accepted chat has no resumable source path", error.SessionPathUnavailable);
                    }
                    runtime.destroy() catch |err| {
                        parkedFailure(chat, "Releasing background runtime", err);
                        continue;
                    };
                    chat.runtime = null;
                    chat.retiring = false;
                    if (chat.snapshot) |*snapshot| {
                        for (snapshot.models) |model| {
                            self.allocator.free(model.provider);
                            self.allocator.free(model.id);
                            self.allocator.free(model.name);
                        }
                        self.allocator.free(snapshot.models);
                        snapshot.models = &.{};
                        for (snapshot.thinking_levels) |level| self.allocator.free(level);
                        self.allocator.free(snapshot.thinking_levels);
                        snapshot.thinking_levels = &.{};
                    }
                } else if (!self.closing and !chat.retiring and chat.submitted == null and chat.run_started == null and !chat.enrollment_intent and chat.model_restore == null) {
                    if (chat.snapshot) |snapshot| if (snapshot.status == .ready and !snapshot.bash_running and snapshot.queued_count == 0) {
                        idle_count += 1;
                        if (idle_count > 4) {
                            runtime.shutdown() catch |err| {
                                parkedFailure(chat, "Retiring idle chat", err);
                                continue;
                            };
                            chat.retiring = true;
                        }
                    };
                }
            } else self.enrollParked(chat);
        }
    }

    fn submit(self: *App) !void {
        if (self.current_archived) return error.RestoreArchivedChatBeforeSending;
        if (self.enrollment_intent) return error.WorkspaceEnrollmentPending;
        if (self.pending_mutation) |mutation| if (!mutation.automatic or mutation.owner_id == self.chat_id) return error.WorkspaceEnrollmentPending;
        if (self.preedit.items.len != 0 or self.closing) return;
        const runtime = self.runtime orelse return error.StartPiFirst;
        if (self.runtimeStatus() != .ready and self.runtimeStatus() != .streaming) return error.PiNotReady;
        if (self.bashRunning()) return error.PiBusy;
        const text = self.editor.textBytes();
        if (text.len == 0) return;
        if (self.thread_title_len == 0) {
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
        if (self.submitted_prompt != null) return error.PromptAcknowledgementPending;
        const behavior: pi.Behavior = if (self.runtimeStatus() == .ready) .prompt else if (self.behavior == .prompt) .follow_up else self.behavior;
        const token = try runtime.sendPrompt(text, behavior);
        self.submitted_prompt = .{ .token = token, .draft_revision = self.draft_revision };
        self.follow_bottom = true;
        self.dirty = true;
    }

    fn toggleFolder(self: *App, path: []const u8) !void {
        for (self.collapsed_folders.items, 0..) |folder, i| if (std.mem.eql(u8, path, folder)) {
            self.allocator.free(self.collapsed_folders.orderedRemove(i));
            return;
        };
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.collapsed_folders.append(self.allocator, owned);
    }

    fn queryLibrary(self: *App) !void {
        if (!self.library.open) return;
        self.library_generation += 1;
        self.library.begin(self.library_generation);
        self.button_count = 0;
        self.catalog_worker.search(self.library.scope, self.library.queryBytes(), self.library.offset, self.library_generation) catch |err| {
            self.library.fail(err);
            return err;
        };
        self.dirty = true;
    }

    fn showLibrary(self: *App, scope: SessionCatalog.Scope) !void {
        if (self.closing or self.force_dialog) return;
        if (!self.library.open) self.prior_editor_focus = self.focused_editor;
        self.settings_open = false;
        self.closeModelMenu();
        self.thinking_menu = false;
        self.dragging = false;
        self.preedit.clearRetainingCapacity();
        _ = c.SDL_ClearComposition(self.window);
        self.focused_editor = false;
        self.library.show(scope);
        self.library.busy = if (self.pending_mutation) |mutation| !mutation.automatic else false;
        self.button_count = 0;
        _ = c.SDL_StartTextInput(self.window);
        self.catalog_worker.refresh();
        try self.queryLibrary();
    }

    fn closeLibrary(self: *App) void {
        self.library.close();
        _ = c.SDL_ClearComposition(self.window);
        self.focused_editor = self.prior_editor_focus;
        if (self.focused_editor) _ = c.SDL_StartTextInput(self.window) else _ = c.SDL_StopTextInput(self.window);
        self.button_count = 0;
        self.dirty = true;
    }

    fn queueMutation(self: *App, kind: SessionCatalog.Mutation, path: []const u8, cwd: []const u8, title_text: []const u8, open_after: bool, automatic: bool) !void {
        if (self.pending_mutation != null) return error.WorkspaceMutationPending;
        if (self.closing and !automatic) return error.ApplicationClosing;
        if (kind == .archive and std.mem.eql(u8, path, self.currentSession()) and
            (self.runtimeStatus() == .streaming or self.bashRunning() or self.submitted_prompt != null or self.pending_thread != null)) return error.StopCurrentRunBeforeArchiving;
        if (kind == .archive) for (self.parked_chats.items) |chat| {
            if (!std.mem.eql(u8, path, chat.session())) continue;
            if (chat.submitted != null) return error.StopCurrentRunBeforeArchiving;
            if (chat.snapshot) |snapshot| if (snapshot.status == .streaming or snapshot.bash_running) return error.StopCurrentRunBeforeArchiving;
        };
        if (open_after) {
            if (self.pending_thread != null) return error.ThreadSwitchPending;
            try SessionCatalog.validateSource(self.io, path, cwd);
        }
        const owned_path = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_cwd = try self.allocator.dupeZ(u8, cwd);
        errdefer self.allocator.free(owned_cwd);
        const owned_title = try self.allocator.dupe(u8, title_text);
        errdefer self.allocator.free(owned_title);
        self.mutation_id += 1;
        try self.catalog_worker.mutate(kind, owned_path, owned_cwd, owned_title, self.mutation_id);
        self.pending_mutation = .{ .id = self.mutation_id, .kind = kind, .path = owned_path, .cwd = owned_cwd, .title = owned_title, .open_after = open_after, .automatic = automatic, .owner_id = if (automatic) self.chat_id else null };
        self.library.busy = !automatic;
        self.button_count = 0;
        self.library.invalidateTargets();
        self.dirty = true;
    }

    fn enrollCurrent(self: *App) void {
        if (!self.enrollment_intent or self.enrollment_failed or self.pending_mutation != null or self.pending_thread != null) return;
        const snapshot = self.runtime_snapshot orelse return;
        if (snapshot.session_file.len == 0 or (!self.accepted_enrollment and (snapshot.status == .starting or snapshot.status == .failed))) return;
        if (!self.accepted_enrollment) SessionCatalog.validateSource(self.io, snapshot.session_file, self.project_path) catch |err| {
            self.enrollment_failed = true;
            self.report("Explicit resume source could not be enrolled", err);
            return;
        };
        self.queueMutation(.enroll, snapshot.session_file, self.project_path, self.title(), false, true) catch |err| {
            self.enrollment_failed = true;
            self.report("Enrolling accepted chat; Ctrl/Cmd+R retries", err);
        };
    }

    fn libraryIntent(self: *App, intent: Library.Intent) !void {
        switch (intent) {
            .search => try self.queryLibrary(),
            .close => self.closeLibrary(),
            .activate => {
                const thread = self.library.selectedThread() orelse return;
                if (self.library.scope == .import_pi) {
                    try self.queueMutation(.enroll, thread.path, thread.cwd, thread.title, true, false);
                } else {
                    try self.openSource(thread.path, thread.cwd, thread.title, thread.archived, thread.available);
                    self.closeLibrary();
                }
            },
            .archive, .restore => {
                const thread = self.library.selectedThread() orelse return;
                try self.queueMutation(if (intent == .archive) .archive else .restore, thread.path, thread.cwd, thread.title, false, false);
            },
        }
    }

    fn act(self: *App, action: Action) !void {
        switch (action) {
            .start => try self.beginRuntime(),
            .new_thread => try self.newThreadIn(self.project_path),
            .open_parked => |index| {
                if (self.closing or self.pending_thread != null) return error.ThreadSwitchPending;
                if (self.pending_mutation) |mutation| if (!mutation.automatic) return error.WorkspaceMutationPending;
                if (index >= self.parked_chats.items.len) return error.StaleThreadChoice;
                try self.saveDraft();
                try self.activateParked(index);
                self.revealCurrentFolder();
            },
            .new_project_thread => |index| {
                if (index < self.projects.items.len) try self.newThreadIn(self.projects.items[index]);
            },
            .new_catalog_thread => |index| {
                if (self.catalog) |catalog| if (index < catalog.folders.len) try self.newThreadIn(catalog.folders[index].cwd);
            },
            .toggle_folder => |index| {
                if (self.catalog) |catalog| if (index < catalog.folders.len) try self.toggleFolder(catalog.folders[index].cwd);
            },
            .toggle_project_folder => |index| {
                if (index < self.projects.items.len) try self.toggleFolder(self.projects.items[index]);
            },
            .toggle_current_folder => try self.toggleFolder(self.project_path),
            .open_library => |scope| try self.showLibrary(scope),
            .library => |choice| if (self.library.act(choice)) |intent| try self.libraryIntent(intent),
            .archive_thread => |index| {
                if (self.catalog) |catalog| if (index < catalog.threads.len) {
                    const thread = catalog.threads[index];
                    try self.queueMutation(.archive, thread.path, thread.cwd, thread.title, false, false);
                };
            },
            .restore_current => try self.queueMutation(.restore, self.currentSession(), self.project_path, self.title(), false, false),
            .add_project => if (!self.folder_pending) {
                self.folder_pending = true;
                c.SDL_ShowOpenFolderDialog(folderChosen, @ptrFromInt(self.wake_event), self.window, self.project_path.ptr, false);
            },
            .settings => {
                self.settings_open = !self.settings_open;
                self.closeModelMenu();
                self.thinking_menu = false;
                self.focused_editor = !self.settings_open;
                if (self.settings_open) _ = c.SDL_StopTextInput(self.window) else _ = c.SDL_StartTextInput(self.window);
            },
            .appearance => |choice| {
                if (choice == .close) {
                    self.settings_open = false;
                    self.focused_editor = true;
                    _ = c.SDL_StartTextInput(self.window);
                } else {
                    Settings.apply(&self.appearance, choice);
                    self.light = self.appearance.light;
                    self.theme.metrics = Settings.metrics(self.base_metrics, self.appearance);
                    self.transcript.invalidateLayouts();
                    self.editor_changed = true;
                    self.draft_due = c.SDL_GetTicks() + 250;
                }
            },
            .sidebar => self.sidebar_visible = !self.sidebar_visible,
            .open_thread => |index| try self.openThread(index),
            .send => try self.submit(),
            .stop => if (self.runtime) |runtime| {
                try runtime.stop();
            },
            .theme => {
                self.light = !self.light;
                self.appearance.light = self.light;
                self.draft_due = c.SDL_GetTicks() + 250;
            },
            .behavior => self.behavior = if (self.behavior == .steer) .follow_up else .steer,
            .latest => {
                self.follow_bottom = true;
                self.requestLatest();
            },
            .models => {
                if (self.model_menu) {
                    self.closeModelMenu();
                } else {
                    // Mutually exclusive popups share the library's bounded query editor.
                    self.library.resetQuery();
                    self.model_search.invalidate();
                    self.model_first = 0;
                    self.model_highlight = 0;
                    self.model_selection_cleared = false;
                    self.model_menu = true;
                    self.dragging = false;
                    self.preedit.clearRetainingCapacity();
                    self.editor_changed = true;
                    _ = c.SDL_ClearComposition(self.window);
                    _ = c.SDL_StartTextInput(self.window);
                }
                self.button_count = 0;
                self.thinking_menu = false;
            },
            .thinking => {
                self.thinking_menu = !self.thinking_menu;
                if (self.thinking_menu) self.highlightCurrentThinking();
                self.closeModelMenu();
            },
            .select_thinking => |index| {
                if (self.runtime_retiring) return error.PiNotReady;
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
                if (self.runtime_retiring) return error.PiNotReady;
                const snapshot = self.runtime_snapshot orelse return error.PiNotReady;
                if (index >= snapshot.models.len) return error.StaleModelChoice;
                const model = snapshot.models[index];
                try (self.runtime orelse return error.PiNotReady).setModel(model.provider, model.id);
                self.closeModelMenu();
            },
            .force_stop => {
                try self.forceOwned();
                self.force_dialog = false;
            },
            .wait => self.force_dialog = false,
        }
        self.dirty = true;
    }

    pub fn button(self: *App, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
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

    fn highlightCurrentThinking(self: *App) void {
        self.thinking_highlight = 0;
        const snapshot = self.runtime_snapshot orelse return;
        for (snapshot.thinking_levels, 0..) |level, index| {
            if (std.mem.eql(u8, level, snapshot.thinking_level)) {
                self.thinking_highlight = index;
                return;
            }
        }
    }

    fn selectedThinkingIndex(self: *App) ?usize {
        const snapshot = self.runtime_snapshot orelse return null;
        if (snapshot.thinking_levels.len == 0) return null;
        self.thinking_highlight = @min(self.thinking_highlight, snapshot.thinking_levels.len - 1);
        return self.thinking_highlight;
    }

    fn moveThinkingHighlight(self: *App, down: bool) void {
        const index = self.selectedThinkingIndex() orelse return;
        self.thinking_highlight = if (down) index + 1 else index -| 1;
        _ = self.selectedThinkingIndex();
        self.pending_hover = null;
        self.dirty = true;
    }

    fn hoverMenu(self: *App, x: f32, y: f32) void {
        if (self.button_count == 0) {
            self.pending_hover = .{ x, y };
            self.dirty = true;
            return;
        }
        self.pending_hover = null;
        if (self.model_menu) self.hoverModel(x, y) else if (self.thinking_menu) self.hoverThinking(x, y);
    }

    fn hoverThinking(self: *App, x: f32, y: f32) void {
        for (self.buttons[0..self.button_count]) |hovered| switch (hovered.action) {
            .select_thinking => |index| if (contains(hovered.bounds, x, y)) {
                if (self.thinking_highlight != index) {
                    self.thinking_highlight = index;
                    self.dirty = true;
                }
                return;
            },
            else => {},
        };
    }

    fn closeModelMenu(self: *App) void {
        if (!self.model_menu) return;
        self.model_menu = false;
        self.library.preedit_len = 0;
        self.library.layout_dirty = true;
        self.library.dragging = false;
        self.button_count = 0;
        _ = c.SDL_ClearComposition(self.window);
        if (self.focused_editor) _ = c.SDL_StartTextInput(self.window) else _ = c.SDL_StopTextInput(self.window);
    }

    fn refreshModelSearch(self: *App) !void {
        if (!self.model_search.dirty) return;
        const models = if (self.runtime_snapshot) |snapshot| snapshot.models else &.{};
        try self.model_search.rebuild(models, self.library.queryBytes());
    }

    fn modelCount(self: *App) !usize {
        try self.refreshModelSearch();
        return self.model_search.len;
    }

    fn modelIndex(self: *App, ranked_index: usize) !?usize {
        try self.refreshModelSearch();
        return self.model_search.index(ranked_index);
    }

    fn selectedModelIndex(self: *App) !?usize {
        if (self.model_selection_cleared) return null;
        return self.modelIndex(self.model_highlight);
    }

    fn revealModelHighlight(self: *App) void {
        if (self.model_highlight < self.model_first) self.model_first = self.model_highlight;
        if (self.model_highlight >= self.model_first + self.model_visible) self.model_first = self.model_highlight + 1 - self.model_visible;
    }

    fn moveModelHighlight(self: *App, down: bool) !void {
        const last = (try self.modelCount()) -| 1;
        self.model_highlight = if (self.model_selection_cleared) @min(last, self.model_first) else if (down) @min(last, self.model_highlight + 1) else self.model_highlight -| 1;
        self.model_selection_cleared = false;
        self.revealModelHighlight();
        self.pending_hover = null;
        self.button_count = 0;
        self.dirty = true;
    }

    fn hoverModel(self: *App, x: f32, y: f32) void {
        for (self.buttons[0..self.button_count]) |hovered| switch (hovered.action) {
            .select_model => |index| if (contains(hovered.bounds, x, y)) {
                const end = @min(self.model_search.len, self.model_first + self.model_visible);
                for (self.model_search.matches[self.model_first..end], self.model_first..) |match, rank| {
                    if (match.index != index) continue;
                    if (self.model_selection_cleared or self.model_highlight != rank) {
                        self.model_highlight = rank;
                        self.model_selection_cleared = false;
                        self.dirty = true;
                    }
                    return;
                }
                return;
            },
            else => {},
        };
    }

    // Called before releasing the old snapshot, so identity comparisons borrow
    // its strings and retain only an index into the incoming model list.
    fn updateModelSearch(self: *App, models: []const pi.Model) !void {
        if (self.runtime_snapshot) |old| if (modelsEqual(old.models, models)) return;
        const selected = if (self.model_menu) try self.selectedModelIndex() else null;
        var retained: ?usize = null;
        if (selected) |index| {
            const previous = self.runtime_snapshot.?.models[index];
            for (models, 0..) |model, incoming_index| {
                if (std.mem.eql(u8, previous.provider, model.provider) and std.mem.eql(u8, previous.id, model.id)) {
                    retained = incoming_index;
                    break;
                }
            }
        }
        self.model_search.invalidate();
        if (!self.model_menu) return;
        self.button_count = 0;
        if (selected != null) self.model_selection_cleared = true;
        try self.model_search.rebuild(models, self.library.queryBytes());
        self.model_first = @min(self.model_first, self.model_search.len -| 1);
        if (retained) |index| {
            for (self.model_search.matches[0..self.model_search.len], 0..) |match, rank| {
                if (match.index == index) {
                    self.model_highlight = rank;
                    self.model_selection_cleared = false;
                    self.revealModelHighlight();
                    break;
                }
            }
        }
        if (self.model_selection_cleared) {
            self.model_first = 0;
            self.model_highlight = 0;
        }
    }

    fn editModelQuery(self: *App, event: *const c.SDL_Event) !void {
        if (try self.library.handleQuery(self, event)) {
            self.model_search.invalidate();
            self.model_first = 0;
            self.model_highlight = 0;
            self.model_selection_cleared = false;
            self.button_count = 0;
        }
    }

    fn drawOverlays(self: *App) !void {
        const colors = self.palette();
        if (self.model_menu) {
            const x = self.model_bounds.x;
            const width: f32 = @min(360, self.composer_bounds.w - 16);
            const error_height: f32 = if (self.library.input_err != null) 20 else 0;
            const visible: usize = @intFromFloat(@max(1, @min(6, @floor((self.composer_bounds.y - 66 - error_height) / 40))));
            const height = @as(f32, @floatFromInt(visible)) * 40 + 56 + error_height;
            const y = self.composer_bounds.y - height - 10;
            self.model_popup_bounds = .{ .x = x, .y = y, .w = width, .h = height };
            try self.rectangle(x, y, width, height, 8, colors.border);
            try self.rectangle(x + 1, y + 1, width - 2, height - 2, 7, colors.panel);
            if (self.runtime_snapshot) |snapshot| {
                const count = try self.modelCount();
                if (count == 0) try self.label(if (snapshot.models.len == 0) "No configured models" else "No matching models", x + 12, y + 16, 13, colors.muted);
                self.model_visible = visible;
                self.model_highlight = @min(self.model_highlight, count -| 1);
                self.model_first = @min(self.model_first, count -| 1);
                self.revealModelHighlight();
                const end = @min(count, self.model_first + visible);
                for (self.model_search.matches[self.model_first..end], self.model_first..) |match, filtered_index| {
                    const index = match.index;
                    const model = snapshot.models[index];
                    const row_y = y + 8 + @as(f32, @floatFromInt(filtered_index - self.model_first)) * 40;
                    if (!self.model_selection_cleared and filtered_index == self.model_highlight) try self.rectangle(x + 8, row_y, width - 16, 38, 5, colors.raised);
                    const row_clip = c.SDL_Rect{ .x = @intFromFloat(x + 8), .y = @intFromFloat(row_y), .w = @intFromFloat(width - 16), .h = 38 };
                    _ = c.SDL_SetRenderClipRect(self.renderer, &row_clip);
                    try self.hit(.{ .select_model = index }, .{ .x = x + 8, .y = row_y, .w = width - 16, .h = 38 });
                    try self.label(clippedLabel(model.name), x + 12, row_y + 3, 13, colors.text);
                    try self.label(clippedLabel(model.provider), x + 12, row_y + 23, 10, colors.muted);
                    _ = c.SDL_SetRenderClipRect(self.renderer, null);
                }
            } else try self.label("Start pi to discover models", x + 12, y + 16, 13, colors.muted);
            const query_y = y + height - 42 - error_height;
            try self.rectangle(x + 8, query_y - 5, width - 16, 1, 0, colors.border);
            self.library.query_bounds = .{ .x = x + 8, .y = query_y, .w = width - 16, .h = 34 };
            try self.rectangle(x + 8, query_y, width - 16, 34, 5, colors.raised);
            try self.library.drawQuery(self, "Search models...");
            if (self.library.input_err) |err| {
                var buffer: [128]u8 = undefined;
                const message = try std.fmt.bufPrint(&buffer, "Error: {s}", .{@errorName(err)});
                try self.fitLabel(message, x + 12, query_y + 36, width - 24, 12, colors.error_color);
            }
        }
        if (self.thinking_menu) {
            if (self.runtime_snapshot) |snapshot| {
                const height = @as(f32, @floatFromInt(snapshot.thinking_levels.len)) * 32 + 16;
                const x = self.thinking_bounds.x;
                const y = self.composer_bounds.y - height - 10;
                try self.rectangle(x, y, 130, height, 8, colors.border);
                try self.rectangle(x + 1, y + 1, 128, height - 2, 7, colors.panel);
                const highlight = self.selectedThinkingIndex();
                for (snapshot.thinking_levels, 0..) |level, index| {
                    if (highlight == index) try self.rectangle(x + 4, y + 8 + @as(f32, @floatFromInt(index)) * 32, 122, 30, 5, colors.raised);
                    try self.flatButton(.{ .select_thinking = index }, level, .{ .x = x + 4, .y = y + 8 + @as(f32, @floatFromInt(index)) * 32, .w = 122, .h = 30 });
                }
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
        self.consumeParked();
        while (self.catalog_worker.takeMutation()) |result| {
            if (self.pending_mutation) |value| {
                if (result.id != value.id) {
                    self.report("Workspace acknowledgement mismatch", error.UnexpectedMutationAcknowledgement);
                    continue;
                }
                var target = value;
                defer target.deinit(self.allocator);
                self.pending_mutation = null;
                self.library.busy = false;
                self.button_count = 0;
                self.library.invalidateTargets();
                if (result.err) |err| {
                    if (target.automatic) {
                        if (target.owner_id == self.chat_id) self.enrollment_failed = true;
                        for (self.parked_chats.items) |*chat| if (target.owner_id == chat.id) {
                            chat.enrollment_failed = true;
                            const message = std.fmt.bufPrint(&chat.error_text, "Enrollment failed: {s}; Ctrl/Cmd+R retries", .{@errorName(err)}) catch "Enrollment failed";
                            chat.error_len = message.len;
                        };
                    }
                    if (self.library.open) self.library.fail(err);
                    if (!target.automatic or target.owner_id == self.chat_id) {
                        self.report(if (target.automatic) "Enrollment failed; Ctrl/Cmd+R retries" else "Workspace change was not saved", err);
                    } else std.log.err("Background enrollment failed: {s}", .{@errorName(err)});
                } else {
                    if (target.automatic and target.owner_id == self.chat_id) {
                        self.enrollment_intent = false;
                        self.enrollment_failed = false;
                        self.accepted_enrollment = false;
                    }
                    for (self.parked_chats.items) |*chat| {
                        if (target.automatic and target.owner_id == chat.id) {
                            chat.enrollment_intent = false;
                            chat.enrollment_failed = false;
                            chat.accepted_enrollment = false;
                        }
                        if (std.mem.eql(u8, target.path, chat.session())) {
                            chat.member = true;
                            chat.archived = result.archived orelse (target.kind == .archive);
                            if (target.kind == .enroll and chat.view == .new_thread) chat.view = .existing;
                        }
                    }
                    if (std.mem.eql(u8, target.path, self.currentSession())) {
                        self.current_member = true;
                        if (target.kind == .enroll or target.kind == .restore) self.revealCurrentFolder();
                        self.current_archived = result.archived orelse (target.kind == .archive);
                        if (target.kind == .enroll and self.chat_view == .new_thread) self.chat_view = .existing;
                    }
                    self.catalog_worker.refresh();
                    if (target.open_after) {
                        self.openSource(target.path, target.cwd, target.title, result.archived orelse false, true) catch |err| {
                            self.library.fail(err);
                            self.report("Imported chat could not be opened", err);
                            continue;
                        };
                        self.closeLibrary();
                    } else if (self.library.open) self.queryLibrary() catch |err| self.report("Refreshing chat search", err);
                }
                self.dirty = true;
            }
        }
        if (self.closing and self.closeSettled()) self.running = false;
        if (self.catalog_worker.takeSearch()) |result| {
            self.button_count = 0;
            self.library.accept(result);
            self.dirty = true;
        }
        if (self.catalog_worker.take()) |result| switch (result) {
            .ready => |catalog| {
                self.button_count = 0;
                self.library.invalidateTargets();
                if (self.catalog) |*old| old.deinit();
                self.catalog = catalog;
                self.catalog_error = catalog.warning;
                if (self.catalog_error) |err| self.report("Workspace library is incomplete", err);
                self.dirty = true;
            },
            .failure => |err| {
                self.catalog_error = err;
                self.report("Discovering pi threads", err);
            },
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
                    if (self.pending_thread == null) if (self.runtime_snapshot) |snapshot| {
                        if (self.chat_view == .opening and snapshot.visible_revision != 0 and
                            std.mem.eql(u8, snapshot.session_file, self.options.resume_file orelse ""))
                            self.chat_view = .existing;
                        if (self.chat_view == .new_thread and value.entries.len != 0) self.chat_view = .existing;
                    };
                    value.deinit();
                },
                .ready => |ready| self.transcript.accept(self.renderer, ready) catch |err| self.report("Rendering message", err),
            }
            self.dirty = true;
        }
    }

    fn saveDraft(self: *App) !void {
        const bytes = self.editor.textBytes();
        var projects: [64][]const u8 = undefined;
        for (self.projects.items, 0..) |path, index| projects[index] = path;
        try self.draft_writer.submit(.{ .draft = bytes, .light = self.light, .font_size = self.appearance.font_size, .ui_scale = self.appearance.ui_scale, .chat_width = self.appearance.chat_width, .projects = projects[0..self.projects.items.len] });
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
        self.base_metrics = next.metrics;
        self.theme.metrics = Settings.metrics(next.metrics, self.appearance);
        self.transcript.invalidateLayouts();
        self.editor_width = 0;
        self.error_len = 0;
        self.dirty = true;
    }

    fn currentSession(self: *const App) []const u8 {
        if (self.pending_thread) |target| if (target.path) |path| return path;
        if (self.chat_view == .opening) return self.options.resume_file orelse "";
        if (self.runtime_snapshot) |snapshot| if (snapshot.session_file.len != 0) return snapshot.session_file;
        return self.options.resume_file orelse "";
    }

    fn currentIndexed(self: *const App) bool {
        const current = self.currentSession();
        if (self.catalog) |catalog| for (catalog.threads) |thread| {
            if (std.mem.eql(u8, current, thread.path)) return true;
        };
        return false;
    }

    fn indexedFolder(self: *const App, path: []const u8) bool {
        if (self.catalog) |catalog| for (catalog.folders) |folder| {
            if (std.mem.eql(u8, path, folder.cwd)) return true;
        };
        return false;
    }

    fn savedFolder(self: *const App, path: []const u8) bool {
        for (self.projects.items) |project| if (std.mem.eql(u8, project, path)) return true;
        return false;
    }

    fn folderCollapsed(self: *const App, path: []const u8) bool {
        for (self.collapsed_folders.items) |folder| if (std.mem.eql(u8, folder, path)) return true;
        return false;
    }

    fn transientCurrent(self: *const App) bool {
        return !self.current_archived and !self.currentIndexed() and
            (self.chat_view == .new_thread or self.enrollment_intent or self.current_member);
    }

    fn revealCurrentFolder(self: *App) void {
        for (self.collapsed_folders.items, 0..) |folder, index| if (std.mem.eql(u8, folder, self.project_path)) {
            self.allocator.free(self.collapsed_folders.orderedRemove(index));
            break;
        };
        self.sidebar_reveal_current = true;
    }

    fn currentSidebarRow(self: *const App) ?usize {
        var row: usize = 0;
        const transient = self.transientCurrent();
        if (!self.indexedFolder(self.project_path) and self.savedFolder(self.project_path)) {
            row += 1;
            if (transient and !self.folderCollapsed(self.project_path)) return row;
        }
        if (!self.indexedFolder(self.project_path) and !self.savedFolder(self.project_path)) {
            row += 1;
            if (transient and !self.folderCollapsed(self.project_path)) return row;
        }
        if (self.catalog) |catalog| for (catalog.folders) |folder| {
            row += 1;
            if (self.folderCollapsed(folder.cwd)) continue;
            if (transient and std.mem.eql(u8, folder.cwd, self.project_path)) return row;
            const count = folder.row_count - 1;
            for (catalog.rows[folder.first_row + 1 ..][0..count], 0..) |item, offset| {
                if (std.mem.eql(u8, catalog.threads[item.thread].path, self.currentSession())) return row + offset;
            }
            row += count;
        };
        return null;
    }

    fn sidebarRows(self: *const App) usize {
        var rows: usize = 0;
        if (self.catalog) |catalog| for (catalog.folders) |folder| {
            rows += if (self.folderCollapsed(folder.cwd)) 1 else folder.row_count;
        };
        for (self.projects.items) |path| if (!self.indexedFolder(path)) {
            rows += 1;
        };
        if (!self.indexedFolder(self.project_path) and !self.savedFolder(self.project_path)) rows += 1;
        if (self.transientCurrent() and !self.folderCollapsed(self.project_path)) rows += 1;
        for (self.parked_chats.items) |*chat| if (self.transientParked(chat)) {
            rows += 1;
        };
        return rows;
    }

    fn transientParked(self: *const App, chat: *const ParkedChat) bool {
        if (chat.archived) return false;
        if (self.catalog) |catalog| for (catalog.threads) |thread| {
            if (std.mem.eql(u8, thread.path, chat.session())) return false;
        };
        return true;
    }

    fn sidebarRowY(self: *const App, row: usize, height: f32) ?f32 {
        if (row < self.sidebar_first) return null;
        const y = 158 + @as(f32, @floatFromInt(row - self.sidebar_first)) * 38;
        return if (y + 36 <= height - 104) y else null;
    }

    fn drawFolderRow(self: *App, path: []const u8, action: Action, browse: ?Action, row: usize, height: f32) !void {
        const y = self.sidebarRowY(row, height) orelse return;
        const colors = self.palette();
        const width = self.shell.sidebar.width;
        const active = std.mem.eql(u8, path, self.project_path);
        try widgets.icon(self.renderer, .folder, .{ .x = 20, .y = y + 10, .w = 14, .h = 14 }, if (active) colors.accent else colors.muted);
        // Browsing only expands/collapses; the separate plus creates a thread.
        if (browse) |choice| try self.hit(choice, .{ .x = 10, .y = y, .w = width - 52, .h = 34 });
        const name = std.fs.path.basename(path);
        try self.fitLabel(clippedLabel(if (name.len == 0) path else name), 42, y + 9, width - 86, 13, colors.text);
        try self.iconButton(action, .plus, .{ .x = width - 42, .y = y + 2, .w = 30, .h = 30 }, colors.muted);
    }

    fn drawCurrentRow(self: *App, row: usize, height: f32) !void {
        const y = self.sidebarRowY(row, height) orelse return;
        const width = self.shell.sidebar.width;
        const colors = self.palette();
        try self.rectangle(28, y, width - 40, 34, 6, colors.raised);
        try self.hit(.latest, .{ .x = 28, .y = y, .w = width - 40, .h = 34 });
        try self.fitLabel(clippedLabel(self.title()), 40, y + 9, width - 64, 13, colors.accent);
    }

    fn drawSidebar(self: *App, height: f32) !void {
        const colors = self.palette();
        const width = self.shell.sidebar.width;
        try self.rectangle(0, 0, width, height, 0, colors.panel);
        try self.rectangle(width - 1, 0, 1, height, 0, colors.border);
        try self.iconButton(.sidebar, .sidebar, .{ .x = 12, .y = 9, .w = 30, .h = 30 }, colors.muted);
        try self.label("Spica", 50, 17, 15, colors.text);
        try self.button(.new_thread, "New thread", .{ .x = 12, .y = 46, .w = width - 24, .h = 30 });
        try self.flatButton(.{ .open_library = .workspace }, if (builtin.os.tag == .macos) "Search chats    Cmd+K" else "Search chats    Ctrl+K", .{ .x = 12, .y = 80, .w = width - 24, .h = 30 });
        try self.label("Projects", 20, 128, 12, colors.muted);
        try self.flatButton(.add_project, "+ Add folder", .{ .x = width - 108, .y = 120, .w = 100, .h = 30 });
        const visible: usize = @intFromFloat(@max(1, @floor((height - 262) / 38)));
        self.sidebar_first = @min(self.sidebar_first, self.sidebarRows() -| visible);
        if (self.sidebar_reveal_current) if (self.currentSidebarRow()) |selected_row| {
            if (selected_row < self.sidebar_first) self.sidebar_first = selected_row;
            if (selected_row >= self.sidebar_first + visible) self.sidebar_first = selected_row + 1 -| visible;
            self.sidebar_reveal_current = false;
        };
        const current_missing = self.transientCurrent();
        var row: usize = 0;
        for (self.projects.items, 0..) |path, project_index| {
            if (self.indexedFolder(path) or !std.mem.eql(u8, path, self.project_path)) continue;
            try self.drawFolderRow(path, .{ .new_project_thread = project_index }, .{ .toggle_project_folder = project_index }, row, height);
            row += 1;
            if (current_missing and !self.folderCollapsed(path) and std.mem.eql(u8, path, self.project_path)) {
                try self.drawCurrentRow(row, height);
                row += 1;
            }
        }
        if (!self.indexedFolder(self.project_path) and !self.savedFolder(self.project_path)) {
            try self.drawFolderRow(self.project_path, .new_thread, .toggle_current_folder, row, height);
            row += 1;
            if (current_missing and !self.folderCollapsed(self.project_path)) {
                try self.drawCurrentRow(row, height);
                row += 1;
            }
        }
        if (self.catalog) |catalog| for (catalog.folders, 0..) |folder, folder_index| {
            try self.drawFolderRow(folder.cwd, .{ .new_catalog_thread = folder_index }, .{ .toggle_folder = folder_index }, row, height);
            row += 1;
            if (self.folderCollapsed(folder.cwd)) continue;
            if (current_missing and std.mem.eql(u8, folder.cwd, self.project_path)) {
                try self.drawCurrentRow(row, height);
                row += 1;
            }
            const count = folder.row_count - 1;
            // Decode/draw/hit-test only the visible slice, not every session.
            const first = @min(count, self.sidebar_first -| row);
            const end = @min(count, (self.sidebar_first + visible) -| row);
            for (catalog.rows[folder.first_row + 1 + first .. folder.first_row + 1 + end], first..) |item, offset| {
                const index = item.thread;
                const thread = catalog.threads[index];
                const y = self.sidebarRowY(row + offset, height) orelse continue;
                const active = std.mem.eql(u8, self.currentSession(), thread.path);
                if (active) try self.rectangle(28, y, width - 40, 34, 6, colors.raised);
                try self.hit(.{ .open_thread = index }, .{ .x = 28, .y = y, .w = width - 76, .h = 34 });
                try self.fitLabel(clippedLabel(thread.title), 40, y + 9, width - 100, 13, if (active) colors.accent else if (thread.available) colors.text else colors.muted);
                try self.iconButton(.{ .archive_thread = index }, .archive, .{ .x = width - 42, .y = y + 2, .w = 30, .h = 30 }, colors.muted);
            }
            row += count;
        };
        for (self.projects.items, 0..) |path, project_index| {
            if (self.indexedFolder(path) or std.mem.eql(u8, path, self.project_path)) continue;
            try self.drawFolderRow(path, .{ .new_project_thread = project_index }, .{ .toggle_project_folder = project_index }, row, height);
            row += 1;
        }
        for (self.parked_chats.items, 0..) |*chat, index| {
            if (!self.transientParked(chat)) continue;
            const parked_row = row;
            row += 1;
            const y = self.sidebarRowY(parked_row, height) orelse continue;
            const text = if (chat.snapshot) |snapshot|
                (if (snapshot.session_name.len != 0) snapshot.session_name else if (chat.title_len != 0) chat.title[0..chat.title_len] else "New thread")
            else if (chat.title_len != 0) chat.title[0..chat.title_len] else "New thread";
            try self.hit(.{ .open_parked = index }, .{ .x = 28, .y = y, .w = width - 40, .h = 34 });
            try self.fitLabel(clippedLabel(text), 40, y + 9, width - 68, 13, colors.text);
        }
        try self.rectangle(12, height - 100, width - 24, 1, 0, colors.border);
        try self.flatButton(.{ .open_library = .import_pi }, "Import Pi chat", .{ .x = 12, .y = height - 96, .w = width - 24, .h = 28 });
        try self.flatButton(.{ .open_library = .archives }, "Archives", .{ .x = 12, .y = height - 66, .w = width - 24, .h = 28 });
        try self.flatButton(.settings, "Settings", .{ .x = 12, .y = height - 36, .w = width - 24, .h = 28 });
    }

    fn paint(self: *App) !void {
        self.button_count = 0;
        var width: c_int = 1280;
        var height: c_int = 800;
        _ = c.SDL_GetWindowSize(self.window, &width, &height);
        const scale = @as(f32, @floatFromInt(self.appearance.ui_scale)) / 100;
        var pixel_width: c_int = width;
        var pixel_height: c_int = height;
        if (!c.SDL_GetRenderOutputSize(self.renderer, &pixel_width, &pixel_height)) return error.RenderOutputSize;
        const scale_x = @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(width)) * scale;
        const scale_y = @as(f32, @floatFromInt(pixel_height)) / @as(f32, @floatFromInt(height)) * scale;
        if (!c.SDL_SetRenderLogicalPresentation(self.renderer, 0, 0, c.SDL_LOGICAL_PRESENTATION_DISABLED) or
            !c.SDL_SetRenderScale(self.renderer, scale_x, scale_y)) return error.RenderScale;
        if (!c.spica_text_set_render_scale(self.text, scale_x, scale_y)) return error.TextRenderScale;
        width = @intFromFloat(@as(f32, @floatFromInt(width)) / scale);
        height = @intFromFloat(@as(f32, @floatFromInt(height)) / scale);
        self.layout.resize(@floatFromInt(width), @floatFromInt(height));
        const colors = self.palette();
        self.shell = self.layout.shell(if (self.sidebar_visible) @min(268, @as(f32, @floatFromInt(width)) * 0.34) else 0, self.theme.metrics.header_height, @min(202, @as(f32, @floatFromInt(height)) * 0.4));
        const header = self.shell.header;
        const conversation = self.shell.conversation;
        const displayed_project = if (self.pending_thread) |target| target.cwd else self.project_path;
        const project = clippedLabel(std.fs.path.basename(displayed_project));
        if (!c.SDL_SetRenderDrawColor(self.renderer, colors.canvas.r, colors.canvas.g, colors.canvas.b, 255) or
            !c.SDL_RenderClear(self.renderer)) return error.ClearFrame;
        if (self.sidebar_visible) try self.drawSidebar(@floatFromInt(height)) else try self.iconButton(.sidebar, .sidebar, .{ .x = header.x + 12, .y = 7, .w = 30, .h = 30 }, colors.muted);
        const crumb_x = header.x + (if (self.sidebar_visible) @as(f32, 22) else 52);
        try widgets.icon(self.renderer, .folder, .{ .x = crumb_x, .y = 15, .w = 14, .h = 14 }, colors.accent);
        const project_width = @min(try self.labelWidth(project, 13), header.width * 0.32);
        try self.fitLabel(project, crumb_x + 24, 15, project_width, 13, colors.text);
        const title_x = crumb_x + 40 + project_width;
        try self.label("/", title_x, 15, 13, colors.muted);
        try self.fitLabel(clippedLabel(self.title()), title_x + 20, 15, @max(0, header.x + header.width - 158 - title_x), 13, colors.muted);
        const state: []const u8 = if (self.options.fixture) "Resource scene" else if (self.current_archived) "Archived" else switch (self.runtimeStatus()) {
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

        const content_width = @max(160, @min(self.theme.metrics.chat_max_width, conversation.width - 40));
        const content_x = conversation.x + (conversation.width - content_width) / 2;
        const body_top = conversation.y + 20;
        const viewport_height = @max(24, conversation.height - 56);
        const clip = c.SDL_Rect{ .x = @intFromFloat(content_x), .y = @intFromFloat(body_top), .w = @intFromFloat(content_width), .h = @intFromFloat(viewport_height) };
        _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
        if (self.chat_view != .opening) {
            try self.transcript.draw(self.text, self.renderer, content_x, body_top, content_width, viewport_height, &self.scroll, self.follow_bottom, self.theme.metrics, colors, self.light);
            for (self.transcript.disclosures[0..self.transcript.disclosure_count]) |disclosure| try self.hit(.{ .disclosure = disclosure.toggle }, disclosure.bounds);
        }
        _ = c.SDL_SetRenderClipRect(self.renderer, null);
        if (!self.options.fixture and (self.chat_view == .opening or
            (self.transcript.items.items.len == 0 and !self.content_pending and !self.conversation_dirty and self.runtimeStatus() == .ready)))
        {
            const empty_y = body_top + @min(96, viewport_height * 0.2);
            try self.label(if (self.chat_view == .opening) self.title() else if (self.chat_view == .existing) "No messages in this chat" else "New thread", content_x + 16, empty_y, @intFromFloat(self.theme.metrics.body_px + 5), colors.text);
            try self.fitLabel(clippedLabel(displayed_project), content_x + 16, empty_y + 38, content_width - 32, 13, colors.muted);
            const description = if (self.chat_view == .opening)
                (if (self.runtimeStatus() == .failed) "Unable to open chat." else "Opening chat...")
            else if (self.chat_view == .existing) "This saved chat has no messages." else "Describe what you want to build or change.";
            try self.fitLabel(description, content_x + 16, empty_y + 64, content_width - 32, 13, colors.muted);
        }
        if (!self.follow_bottom and self.transcript.height > viewport_height) try self.flatButton(.latest, "Jump to latest", .{ .x = content_x + content_width - 128, .y = conversation.y + conversation.height - 33, .w = 128, .h = 28 });
        self.composer_bounds = .{ .x = content_x, .y = self.shell.composer.y + 8, .w = content_width, .h = @min(144, self.shell.composer.height - 44) };
        const composer = self.composer_bounds;
        const fill = theme_module.Color{
            .r = @intCast((@as(u16, colors.canvas.r) * 3 + colors.raised.r) / 4),
            .g = @intCast((@as(u16, colors.canvas.g) * 3 + colors.raised.g) / 4),
            .b = @intCast((@as(u16, colors.canvas.b) * 3 + colors.raised.b) / 4),
        };
        try self.rectangle(composer.x, composer.y, composer.w, composer.h, 14, colors.border);
        try self.rectangle(composer.x + 1, composer.y + 1, composer.w - 2, composer.h - 2, 13, fill);
        self.editor_bounds = .{ .x = composer.x + 4, .y = composer.y + 4, .w = composer.w - 8, .h = composer.h - 52 };
        try self.drawEditor();
        const controls_y = composer.y + composer.h - 40;
        var model_name: []const u8 = "Select model";
        if (self.runtime_snapshot) |snapshot| {
            if (snapshot.model.len != 0) model_name = snapshot.model;
            for (snapshot.models) |model| if (std.mem.eql(u8, model.id, snapshot.model) and std.mem.eql(u8, model.provider, snapshot.provider)) {
                model_name = model.name;
                break;
            };
        }
        const model_width = @min(@min(220, composer.w * 0.43), try self.labelWidth(clippedLabel(model_name), 13) + 34);
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
            if (self.runtimeStatus() == .streaming and mode_x + 100 < composer.x + composer.w - 48) {
                try self.flatButton(.behavior, if (self.behavior == .steer) "Steer" else "Follow-up", .{ .x = mode_x, .y = controls_y, .w = 96, .h = 30 });
            }
            const send_bounds = c.SDL_FRect{ .x = composer.x + composer.w - 44, .y = controls_y, .w = 32, .h = 32 };
            const working = self.runtimeStatus() == .streaming or self.bashRunning();
            if (self.current_archived) {
                try self.button(.restore_current, "Restore", .{ .x = composer.x + composer.w - 86, .y = controls_y, .w = 78, .h = 32 });
            } else {
                try self.rectangle(send_bounds.x, send_bounds.y, send_bounds.w, send_bounds.h, 16, if (self.runtime == null) colors.raised else colors.accent);
                try self.iconButton(if (working) .stop else .send, if (working) .stop else .arrow_up, send_bounds, if (self.runtime == null) colors.muted else colors.text);
            }
        }
        try widgets.icon(self.renderer, .folder, .{ .x = composer.x + 2, .y = composer.y + composer.h + 13, .w = 12, .h = 12 }, colors.muted);
        try self.label("Local checkout", composer.x + 22, composer.y + composer.h + 13, 11, colors.muted);
        try self.fitLabel(project, composer.x + 130, composer.y + composer.h + 13, @max(0, composer.w - 130), 11, colors.muted);
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
        if (self.settings_open) {
            self.button_count = 0;
            try Settings.draw(self);
        }
        if (self.library.open) try self.library.draw(self);
        if (self.library.open and (self.closing or self.force_dialog)) {
            self.button_count = 0;
            try self.drawOverlays();
        }
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
        if (self.pending_hover) |point| {
            self.pending_hover = null;
            if (self.button_count != 0) self.hoverMenu(point[0], point[1]);
        }
    }

    fn drawEditor(self: *App) !void {
        const bounds = self.editor_bounds;
        const colors = self.palette();
        try self.ensureEditorLayout(bounds.w);
        const clip = c.SDL_Rect{ .x = @intFromFloat(bounds.x + 8), .y = @intFromFloat(bounds.y + 8), .w = @intFromFloat(bounds.w - 16), .h = @intFromFloat(bounds.h - 16) };
        _ = c.SDL_SetRenderClipRect(self.renderer, &clip);
        defer _ = c.SDL_SetRenderClipRect(self.renderer, null);
        var caret: c.SDL_FRect = undefined;
        var has_caret = false;
        if (self.editor_layout) |layout| {
            has_caret = c.spica_text_layout_caret(layout, self.editor.caret - self.editor_start, &caret);
            if (has_caret) {
                self.editor_scroll = @max(0, @min(self.editor_scroll, caret.y));
                if (caret.y + caret.h > self.editor_scroll + bounds.h - 20) self.editor_scroll = caret.y + caret.h - (bounds.h - 20);
                var input_x: f32 = 0;
                var input_y: f32 = 0;
                var input_bottom: f32 = 0;
                if (!c.SDL_RenderCoordinatesToWindow(self.renderer, bounds.x + 12 + caret.x, bounds.y + 10 + caret.y - self.editor_scroll, &input_x, &input_y) or
                    !c.SDL_RenderCoordinatesToWindow(self.renderer, bounds.x + 12 + caret.x, bounds.y + 10 + caret.y - self.editor_scroll + caret.h, null, &input_bottom)) return error.InputCoordinates;
                const input_area = c.SDL_Rect{ .x = @intFromFloat(input_x), .y = @intFromFloat(input_y), .w = 2, .h = @intFromFloat(@max(1, input_bottom - input_y)) };
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
            if (self.editor.len == 0) try self.label("Ask for changes or send a follow-up", bounds.x + 12, bounds.y + 10, @intFromFloat(self.theme.metrics.body_px), colors.muted);
        }
        if (self.preedit.items.len != 0) try self.label(clippedLabel(self.preedit.items), bounds.x + 12, bounds.y + 66, 15, colors.accent);
        if (self.focused_editor and !self.model_menu and has_caret) try self.rectangle(bounds.x + 12 + caret.x, bounds.y + 10 + caret.y - self.editor_scroll, 2, caret.h, 0, colors.text);
    }

    fn retainOwnedProcessOnError(self: *App) void {
        if (self.ownedRuntimesFinished()) return;
        self.closing = true;
        self.shutdownOwned() catch |err| std.log.err("Shutdown after UI failure: {s}", .{@errorName(err)});
        var prompted = false;
        while (!self.ownedRuntimesFinished()) {
            self.consumeRuntime();
            self.consumeParked();
            if (self.needsForceStop() and !prompted) {
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
                if (c.SDL_ShowMessageBox(&dialog, &choice) and choice == 1) self.forceOwned() catch |err| std.log.err("Explicit force: {s}", .{@errorName(err)});
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

    fn handle(self: *App, incoming: *const c.SDL_Event) !void {
        var logical = incoming.*;
        if (!c.SDL_ConvertEventToRenderCoordinates(self.renderer, &logical)) return error.InputCoordinates;
        const event = &logical;
        if (event.type == self.wake_event) {
            if (event.user.code == 2) {
                self.folder_pending = false;
                return error.FolderPickerUnavailable;
            }
            if (event.user.code == 1) {
                self.folder_pending = false;
                if (event.user.data1) |path| {
                    defer c.SDL_free(path);
                    const chosen = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
                    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, chosen, self.allocator);
                    defer self.allocator.free(canonical);
                    try self.addProject(canonical);
                }
                self.dirty = true;
            }
            self.consume();
            return;
        }
        if (event.type == c.SDL_EVENT_KEY_DOWN and !self.closing and !self.force_dialog) {
            const command = (event.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
            if (command and event.key.key == c.SDLK_K) {
                try self.showLibrary(.workspace);
                return;
            }
            if (command and event.key.key == c.SDLK_R) {
                self.enrollment_failed = false;
                for (self.parked_chats.items) |*chat| chat.enrollment_failed = false;
                self.enrollCurrent();
                self.catalog_worker.refresh();
                if (self.library.open) {
                    try self.queryLibrary();
                    return;
                }
            }
            if (self.library.open and command and event.key.key == c.SDLK_PERIOD) {
                try self.act(.stop);
                return;
            }
        }
        if (self.library.open and !self.closing and !self.force_dialog) switch (event.type) {
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING, c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_MOTION, c.SDL_EVENT_MOUSE_WHEEL, c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                if (try self.library.handle(self, event)) |intent| self.libraryIntent(intent) catch |err| {
                    self.library.fail(err);
                    self.report("Chat library action", err);
                };
                return;
            },
            else => {},
        };
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => try self.requestClose(),
            c.SDL_EVENT_WINDOW_EXPOSED => self.dirty = true,
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                self.button_count = 0;
                self.library.invalidateTargets();
                self.dirty = true;
            },
            c.SDL_EVENT_WINDOW_MINIMIZED => self.minimized = true,
            c.SDL_EVENT_WINDOW_RESTORED => {
                self.minimized = false;
                self.dirty = true;
                self.requestConversation();
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if ((c.SDL_GetModState() & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0 and event.wheel.y != 0) {
                    const direction = event.wheel.y * (if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) @as(f32, -1) else 1);
                    try self.act(.{ .appearance = if (direction > 0) .scale_larger else .scale_smaller });
                    return;
                }
                if (self.settings_open) return;
                if (self.model_menu) {
                    const last = (try self.modelCount()) -| 1;
                    const direction = event.wheel.y * (if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) @as(f32, -1) else 1);
                    const before = self.model_first;
                    self.model_first = if (direction > 0) self.model_first -| 1 else if (direction < 0) @min(last, self.model_first + 1) else self.model_first;
                    // The highlight scrolls with its row so it stays under the cursor.
                    if (self.model_selection_cleared) self.model_highlight = self.model_first else self.model_highlight = @min(last, (self.model_highlight + self.model_first) -| before);
                    if (direction != 0) self.model_selection_cleared = false;
                    self.button_count = 0;
                } else if (!self.closing) {
                    if (self.sidebar_visible and event.wheel.mouse_x < self.shell.sidebar.width) {
                        const last = self.sidebarRows() -| 1;
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
                if (self.model_menu and !self.closing and !self.force_dialog) {
                    if (contains(self.library.query_bounds, event.button.x, event.button.y)) {
                        if (event.button.button == c.SDL_BUTTON_LEFT) {
                            try self.library.hitQuery(self, event.button.x, event.button.y, (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
                            self.library.dragging = true;
                            self.dirty = true;
                        }
                        return;
                    }
                    if (contains(self.model_popup_bounds, event.button.x, event.button.y)) {
                        if (event.button.button == c.SDL_BUTTON_LEFT) {
                            for (self.buttons[0..self.button_count]) |pressed| {
                                if (pressed.action == .select_model and contains(pressed.bounds, event.button.x, event.button.y)) {
                                    try self.act(pressed.action);
                                    return;
                                }
                            }
                        }
                        return;
                    }
                }
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
                if (self.closing or self.force_dialog or self.settings_open) return;
                if (self.model_menu or self.thinking_menu) {
                    self.closeModelMenu();
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
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                self.dragging = false;
                if (self.model_menu) self.library.dragging = false;
            },
            c.SDL_EVENT_MOUSE_MOTION => if (self.model_menu) {
                if (self.library.dragging) {
                    try self.library.hitQuery(self, event.motion.x, event.motion.y, true);
                    self.dirty = true;
                } else self.hoverMenu(event.motion.x, event.motion.y);
            } else if (self.thinking_menu) {
                self.hoverMenu(event.motion.x, event.motion.y);
            } else if (self.dragging and !self.settings_open) {
                if (self.editor_layout) |layout| self.editor.setCaret(self.editor_start + c.spica_text_layout_hit_test(layout, event.motion.x - self.editor_bounds.x - 12, event.motion.y - self.editor_bounds.y - 10 + self.editor_scroll), true);
                self.dirty = true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const command = (event.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
                const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
                if (command and shift and event.key.key == c.SDLK_ESCAPE and self.needsForceStop()) {
                    try self.act(.force_stop);
                    return;
                }
                if (self.closing or self.force_dialog) {
                    if (event.key.key == c.SDLK_ESCAPE) try self.act(.wait);
                    return;
                }
                if (command) {
                    switch (event.key.key) {
                        c.SDLK_PLUS, c.SDLK_EQUALS, c.SDLK_KP_PLUS => {
                            try self.act(.{ .appearance = .scale_larger });
                            return;
                        },
                        c.SDLK_MINUS, c.SDLK_UNDERSCORE, c.SDLK_KP_MINUS => {
                            try self.act(.{ .appearance = .scale_smaller });
                            return;
                        },
                        c.SDLK_0, c.SDLK_KP_0 => {
                            try self.act(.{ .appearance = .scale_reset });
                            return;
                        },
                        else => {},
                    }
                }
                if (command and event.key.key == c.SDLK_COMMA) {
                    try self.act(.settings);
                    return;
                }
                if (self.settings_open) {
                    if (event.key.key == c.SDLK_ESCAPE) try self.act(.{ .appearance = .close });
                    return;
                }
                if (command and event.key.key == c.SDLK_N) {
                    try self.act(.new_thread);
                    return;
                }
                if (command and event.key.key == c.SDLK_B) {
                    try self.act(.sidebar);
                    return;
                }
                if (self.thinking_menu) {
                    switch (event.key.key) {
                        c.SDLK_ESCAPE => {
                            self.thinking_menu = false;
                            self.dirty = true;
                        },
                        c.SDLK_UP, c.SDLK_DOWN => self.moveThinkingHighlight(event.key.key == c.SDLK_DOWN),
                        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (self.selectedThinkingIndex()) |index| try self.act(.{ .select_thinking = index }),
                        else => {},
                    }
                    return;
                }
                if (self.model_menu) {
                    if (self.library.preedit_len != 0) {
                        try self.editModelQuery(event);
                        return;
                    }
                    if (event.key.key == c.SDLK_ESCAPE) {
                        self.focused_editor = true;
                        self.closeModelMenu();
                        self.dirty = true;
                        return;
                    }
                    if (event.key.key == c.SDLK_UP or event.key.key == c.SDLK_DOWN) try self.moveModelHighlight(event.key.key == c.SDLK_DOWN);
                    if (event.key.key == c.SDLK_RETURN or event.key.key == c.SDLK_KP_ENTER) {
                        if (try self.selectedModelIndex()) |index| try self.act(.{ .select_model = index });
                    } else try self.editModelQuery(event);
                    return;
                }
                if (command and event.key.key == c.SDLK_P) {
                    try self.act(.start);
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
                if (command and event.key.key == c.SDLK_RETURN and !event.key.repeat and self.preedit.items.len == 0 and !self.options.fixture) {
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
                    self.appearance.light = self.light;
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
                        c.SDLK_BACKSPACE => {
                            try self.editor.deleteWord(.backward);
                            self.edited();
                        },
                        c.SDLK_DELETE => {
                            try self.editor.deleteWord(.forward);
                            self.edited();
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
                        // A held Enter must not send: its repeats can outlive the menu that consumed the first press.
                        if (self.runtime != null and !shift) {
                            if (!event.key.repeat) try self.submit();
                        } else {
                            try self.editor.insert("\n", .paste);
                            self.edited();
                        }
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (self.model_menu and !self.closing and !self.force_dialog) {
                    try self.editModelQuery(event);
                    return;
                }
                if (self.library.open or !self.focused_editor or self.model_menu or self.thinking_menu or self.settings_open or self.closing) return;
                try self.editor.insert(std.mem.span(event.text.text), if (self.preedit.items.len != 0) .ime else .typing);
                self.preedit.clearRetainingCapacity();
                self.edited();
            },
            c.SDL_EVENT_TEXT_EDITING => {
                if (self.model_menu and !self.closing and !self.force_dialog) {
                    try self.editModelQuery(event);
                    return;
                }
                if (self.library.open or !self.focused_editor or self.model_menu or self.thinking_menu or self.settings_open or self.closing) return;
                const bytes = std.mem.span(event.edit.text);
                if (bytes.len > 4096) return error.PreeditBudgetExceeded;
                self.preedit.clearRetainingCapacity();
                try self.preedit.appendSlice(self.allocator, bytes);
                self.dirty = true;
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => if (self.model_menu) try self.editModelQuery(event),
            else => {},
        }
    }
};

test "new chat reveal expands only its project and archived current never makes a transient row" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    app.allocator = allocator;
    app.project_path = @constCast("/b");
    app.projects = .empty;
    app.collapsed_folders = .empty;
    defer {
        for (app.collapsed_folders.items) |path| allocator.free(path);
        app.collapsed_folders.deinit(allocator);
    }
    try app.collapsed_folders.append(allocator, try allocator.dupe(u8, "/a"));
    try app.collapsed_folders.append(allocator, try allocator.dupe(u8, "/b"));
    app.catalog = null;
    app.parked_chats = .empty;
    app.current_archived = false;
    app.current_member = false;
    app.enrollment_intent = false;
    app.chat_view = .new_thread;
    app.runtime_snapshot = null;
    app.pending_thread = null;
    app.options = .{};
    try std.testing.expect(app.currentSidebarRow() == null);
    app.revealCurrentFolder();
    try std.testing.expect(app.folderCollapsed("/a"));
    try std.testing.expect(!app.folderCollapsed("/b"));
    try std.testing.expectEqual(@as(?usize, 1), app.currentSidebarRow());
    try std.testing.expectEqual(@as(usize, 2), app.sidebarRows());
    app.current_member = true;
    app.current_archived = true;
    app.chat_view = .existing;
    try std.testing.expect(!app.transientCurrent());
    try std.testing.expect(app.currentSidebarRow() == null);
    try std.testing.expectEqual(@as(usize, 1), app.sidebarRows());
}

test "model search filters names IDs and providers without editing the draft" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    try std.testing.expect(c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "dummy"));
    defer _ = c.SDL_ResetHint(c.SDL_HINT_VIDEO_DRIVER);
    try std.testing.expect(c.SDL_InitSubSystem(c.SDL_INIT_VIDEO));
    defer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    app.window = c.SDL_CreateWindow("Model picker regression", 640, 480, c.SDL_WINDOW_HIDDEN) orelse return error.Window;
    defer c.SDL_DestroyWindow(app.window);
    const surface = c.SDL_CreateSurface(640, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    app.renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(app.renderer);
    app.wake_event = 0;
    app.closing = false;
    app.force_dialog = false;
    app.settings_open = false;
    app.model_menu = true;
    app.thinking_menu = false;
    app.focused_editor = false;
    app.options = .{};
    app.model_search = .{};
    app.model_selection_cleared = false;
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    app.library.resetQuery();
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    try app.editor.setText("keep this message draft");
    const models = [_]pi.Model{
        .{ .name = "DeepSeek V4", .id = "deepseek-v4", .provider = "openrouter" },
        .{ .name = "Anthropic: Claude Opus", .id = "anthropic/claude-opus", .provider = "openrouter" },
        .{ .name = "Claude Haiku", .id = "claude-haiku-4-5", .provider = "anthropic" },
        .{ .name = "Claude Opus", .id = "claude-opus-4-6", .provider = "anthropic" },
    };
    app.runtime_snapshot = .{ .allocator = allocator, .models = @constCast(&models) };
    app.model_first = 3;
    app.model_highlight = 3;
    app.model_visible = 6;
    app.button_count = 4;
    app.dirty = false;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "OPUS";
    try app.handle(&event);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 0), app.model_first);
    try std.testing.expectEqual(@as(usize, 0), app.model_highlight);
    try std.testing.expectEqual(@as(usize, 0), app.button_count);
    try std.testing.expectEqual(@as(usize, 2), try app.modelCount());
    try std.testing.expectEqual(@as(?usize, 1), try app.modelIndex(0));
    try std.testing.expectEqual(@as(?usize, 3), try app.modelIndex(1));
    try std.testing.expect(try app.modelIndex(2) == null);

    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_A;
    event.key.mod = c.SDL_KMOD_GUI;
    try app.handle(&event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "ANTHROPIC haiku-4";
    try app.handle(&event);
    try std.testing.expectEqual(@as(usize, 1), try app.modelCount());
    try std.testing.expectEqual(@as(?usize, 2), try app.modelIndex(0));

    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_A;
    event.key.mod = c.SDL_KMOD_CTRL;
    try app.handle(&event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "missing model";
    try app.handle(&event);
    try std.testing.expectEqual(@as(usize, 0), try app.modelCount());
    try std.testing.expect(try app.modelIndex(0) == null);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RETURN;
    try app.handle(&event);
    try std.testing.expect(app.model_menu);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_Z;
    event.key.mod = c.SDL_KMOD_CTRL;
    try app.handle(&event);
    try std.testing.expectEqualStrings("ANTHROPIC haiku-4", app.library.queryBytes());
    event.key.key = c.SDLK_BACKSPACE;
    event.key.mod = 0;
    try app.handle(&event);
    try std.testing.expectEqualStrings("", app.library.queryBytes());
    try std.testing.expectEqual(@as(usize, 4), try app.modelCount());
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "opsu";
    try app.handle(&event);
    try std.testing.expectEqual(@as(usize, 2), try app.modelCount());
    try std.testing.expectEqual(@as(?usize, 1), try app.modelIndex(0));
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DOWN;
    event.key.mod = 0;
    try app.handle(&event);
    try std.testing.expectEqual(@as(usize, 1), app.model_highlight);
    try std.testing.expect(!app.model_search.dirty);
    try std.testing.expectEqual(@as(?usize, 3), try app.modelIndex(app.model_highlight));
    event.key.key = c.SDLK_UP;
    try app.handle(&event);
    try std.testing.expectEqual(@as(usize, 0), app.model_highlight);
    try std.testing.expectEqualStrings("keep this message draft", app.editor.textBytes());

    // Rejected input keeps the current results and leaves an error for the popup.
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "x" ** 257;
    try app.handle(&event);
    try std.testing.expectEqual(error.QueryTooLarge, app.library.input_err.?);
    try std.testing.expectEqualStrings("opsu", app.library.queryBytes());
    try std.testing.expectEqual(@as(usize, 2), try app.modelCount());
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_BACKSPACE;
    event.key.mod = 0;
    try app.handle(&event);
    try std.testing.expect(app.library.input_err == null);

    // Exercise Enter through the existing set_model action without starting Pi.
    const p = @import("platform/executables.zig").c;
    const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
    defer c.SDL_DestroyMutex(mutex);
    var wake: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), p.spica_wake_create(&wake));
    defer p.spica_close(wake[0]);
    defer p.spica_close(wake[1]);
    var runtime: pi.Runtime = .{
        .allocator = allocator,
        .io = undefined,
        .options = .{ .database_path = "", .project_path = "", .wake_event = 0 },
        .options_arena = undefined,
        .mutex = mutex,
        .wake = wake,
        .state = .{ .allocator = allocator },
    };
    defer {
        for (runtime.inputs.items) |input| if (input == .bytes) allocator.free(input.bytes.data);
        runtime.inputs.deinit(allocator);
    }
    app.runtime = &runtime;
    app.runtime_retiring = false;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DOWN;
    try app.handle(&event);
    event.key.key = c.SDLK_RETURN;
    try app.handle(&event);
    try std.testing.expect(!app.model_menu);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    const command = try std.json.parseFromSlice(std.json.Value, allocator, runtime.inputs.items[0].bytes.data, .{});
    defer command.deinit();
    try std.testing.expectEqualStrings("set_model", command.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("anthropic", command.value.object.get("provider").?.string);
    try std.testing.expectEqualStrings("claude-opus-4-6", command.value.object.get("modelId").?.string);

    app.model_menu = true;
    const remaining = [_]pi.Model{models[1]};
    try app.updateModelSearch(&remaining);
    app.runtime_snapshot.?.models = @constCast(&remaining);
    try std.testing.expectEqual(@as(usize, 1), try app.modelCount());
    try app.handle(&event);
    try std.testing.expect(app.model_menu);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    event.key.key = c.SDLK_DOWN;
    try app.handle(&event);
    try std.testing.expectEqual(@as(?usize, 0), try app.selectedModelIndex());
    event.key.key = c.SDLK_RETURN;
    try app.handle(&event);
    try std.testing.expect(!app.model_menu);
    try std.testing.expectEqual(@as(usize, 2), runtime.inputs.items.len);

    app.model_menu = true;
    app.runtime_snapshot.?.models = &.{};
    app.model_search.invalidate();
    try app.handle(&event);
    try std.testing.expect(app.model_menu);
    try std.testing.expectEqual(@as(usize, 2), runtime.inputs.items.len);

    app.focused_editor = false;
    app.editor.setCaret(9, true);
    const draft_selection = app.editor.selection();
    event.key.key = c.SDLK_ESCAPE;
    try app.handle(&event);
    try std.testing.expect(!app.model_menu);
    try std.testing.expect(app.focused_editor);
    try std.testing.expect(c.SDL_TextInputActive(app.window));
    try std.testing.expectEqualStrings("keep this message draft", app.editor.textBytes());
    try std.testing.expectEqual(draft_selection, app.editor.selection());
}

test "model picker snapshot refresh preserves identity and clears disappeared selections" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    app.model_menu = true;
    app.model_first = 0;
    app.model_highlight = 1;
    app.model_visible = 6;
    app.model_selection_cleared = false;
    app.model_search = .{};
    app.button_count = 2;
    app.dirty = false;
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    try app.library.editor.setText("opus");
    const original = [_]pi.Model{
        .{ .name = "Other", .id = "other", .provider = "local" },
        .{ .name = "Opus One", .id = "shared-id", .provider = "one" },
        .{ .name = "Opus Two", .id = "shared-id", .provider = "two" },
    };
    app.runtime_snapshot = .{ .allocator = allocator, .models = @constCast(&original) };
    try std.testing.expectEqual(@as(?usize, 2), try app.selectedModelIndex());

    const reordered = [_]pi.Model{
        .{ .name = "Opus renamed", .id = "shared-id", .provider = "two" },
        original[0],
        original[1],
    };
    try app.updateModelSearch(&reordered);
    app.runtime_snapshot.?.models = @constCast(&reordered);
    try std.testing.expectEqual(@as(usize, 0), app.button_count);
    try std.testing.expectEqual(@as(usize, 0), app.model_highlight);
    try std.testing.expectEqual(@as(?usize, 0), try app.selectedModelIndex());
    try std.testing.expectEqualStrings("opus", app.library.queryBytes());

    // Same ID from a different provider must not replace the disappeared choice.
    const removed = [_]pi.Model{original[1]};
    try app.updateModelSearch(&removed);
    app.runtime_snapshot.?.models = @constCast(&removed);
    try std.testing.expectEqual(@as(usize, 1), try app.modelCount());
    try std.testing.expect(try app.selectedModelIndex() == null);
    const restored = [_]pi.Model{ original[1], reordered[0] };
    try app.updateModelSearch(&restored);
    app.runtime_snapshot.?.models = @constCast(&restored);
    try std.testing.expect(try app.selectedModelIndex() == null);

    // A deliberate query edit re-enables selection.
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = " ";
    try app.editModelQuery(&event);
    try std.testing.expectEqual(@as(?usize, 0), try app.selectedModelIndex());
    const renamed = [_]pi.Model{
        .{ .name = "Different", .id = "shared-id", .provider = "one" },
        reordered[0],
    };
    try app.updateModelSearch(&renamed);
    app.runtime_snapshot.?.models = @constCast(&renamed);
    try std.testing.expectEqual(@as(usize, 1), try app.modelCount());
    try std.testing.expect(try app.selectedModelIndex() == null);
    try app.updateModelSearch(&.{});
    app.runtime_snapshot.?.models = &.{};
    try std.testing.expectEqual(@as(usize, 0), try app.modelCount());
    try std.testing.expect(try app.selectedModelIndex() == null);
}

test "thinking menu keyboard highlight follows Pi's levels and clamps" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    app.dirty = false;
    var levels = [_][]const u8{ "off", "low", "medium", "high" };
    app.runtime_snapshot = .{ .allocator = allocator, .thinking_levels = &levels, .thinking_level = "medium" };

    app.highlightCurrentThinking();
    try std.testing.expectEqual(@as(?usize, 2), app.selectedThinkingIndex());
    app.moveThinkingHighlight(true);
    app.moveThinkingHighlight(true);
    try std.testing.expectEqual(@as(?usize, 3), app.selectedThinkingIndex());
    for (0..5) |_| app.moveThinkingHighlight(false);
    try std.testing.expectEqual(@as(?usize, 0), app.selectedThinkingIndex());
    try std.testing.expect(app.dirty);

    app.runtime_snapshot.?.thinking_level = "custom";
    app.highlightCurrentThinking();
    try std.testing.expectEqual(@as(?usize, 0), app.selectedThinkingIndex());

    app.thinking_highlight = 3;
    app.runtime_snapshot.?.thinking_levels = levels[0..2];
    try std.testing.expectEqual(@as(?usize, 1), app.selectedThinkingIndex());
    app.runtime_snapshot.?.thinking_levels = &.{};
    try std.testing.expect(app.selectedThinkingIndex() == null);
    app.moveThinkingHighlight(true);
    try std.testing.expect(app.selectedThinkingIndex() == null);
    app.runtime_snapshot = null;
    try std.testing.expect(app.selectedThinkingIndex() == null);
}

test "thinking menu hover moves the shared highlight only when the row changes" {
    var app: App = undefined;
    app.thinking_highlight = 0;
    app.dirty = false;
    app.buttons[0] = .{ .action = .thinking, .bounds = .{ .x = 0, .y = 0, .w = 200, .h = 200 } };
    app.buttons[1] = .{ .action = .{ .select_thinking = 0 }, .bounds = .{ .x = 4, .y = 8, .w = 122, .h = 30 } };
    app.buttons[2] = .{ .action = .{ .select_thinking = 1 }, .bounds = .{ .x = 4, .y = 40, .w = 122, .h = 30 } };
    app.button_count = 3;

    app.hoverThinking(20, 50);
    try std.testing.expectEqual(@as(usize, 1), app.thinking_highlight);
    try std.testing.expect(app.dirty);

    app.dirty = false;
    app.hoverThinking(60, 55);
    try std.testing.expect(!app.dirty);

    app.hoverThinking(150, 150);
    try std.testing.expectEqual(@as(usize, 1), app.thinking_highlight);
    try std.testing.expect(!app.dirty);

    app.hoverThinking(20, 10);
    try std.testing.expectEqual(@as(usize, 0), app.thinking_highlight);
    try std.testing.expect(app.dirty);
}

test "model menu hover highlights the row under the cursor without scrolling" {
    var app: App = undefined;
    const models = [_]pi.Model{
        .{ .name = "One", .id = "one", .provider = "local" },
        .{ .name = "Two", .id = "two", .provider = "local" },
        .{ .name = "Three", .id = "three", .provider = "local" },
    };
    app.model_search = .{};
    try app.model_search.rebuild(&models, "");
    app.model_first = 1;
    app.model_highlight = 1;
    app.model_visible = 2;
    app.model_selection_cleared = false;
    app.dirty = false;
    app.buttons[0] = .{ .action = .{ .select_model = app.model_search.index(1).? }, .bounds = .{ .x = 8, .y = 8, .w = 200, .h = 38 } };
    app.buttons[1] = .{ .action = .{ .select_model = app.model_search.index(2).? }, .bounds = .{ .x = 8, .y = 48, .w = 200, .h = 38 } };
    app.button_count = 2;

    app.hoverModel(20, 60);
    try std.testing.expectEqual(@as(usize, 2), app.model_highlight);
    try std.testing.expectEqual(@as(usize, 1), app.model_first);
    try std.testing.expect(app.dirty);

    app.dirty = false;
    app.hoverModel(100, 70);
    try std.testing.expect(!app.dirty);

    app.hoverModel(300, 300);
    try std.testing.expectEqual(@as(usize, 2), app.model_highlight);
    try std.testing.expect(!app.dirty);

    // A hover with cleared row targets waits for the next paint, and a key press cancels it.
    app.model_menu = true;
    app.thinking_menu = false;
    app.button_count = 0;
    app.hoverMenu(20, 20);
    try std.testing.expect(app.pending_hover != null);
    try std.testing.expectEqual(@as(usize, 2), app.model_highlight);
    app.button_count = 2;
    app.hoverMenu(app.pending_hover.?[0], app.pending_hover.?[1]);
    try std.testing.expect(app.pending_hover == null);
    try std.testing.expectEqual(@as(usize, 1), app.model_highlight);
    app.button_count = 0;
    app.hoverMenu(20, 60);
    try app.moveModelHighlight(false);
    try std.testing.expect(app.pending_hover == null);
    try std.testing.expectEqual(@as(usize, 0), app.model_highlight);
    app.model_first = 1;
    app.model_highlight = 2;
    app.button_count = 2;

    // Hovering restores a selection that a snapshot refresh cleared.
    app.model_selection_cleared = true;
    app.hoverModel(20, 60);
    try std.testing.expect(!app.model_selection_cleared);
    try std.testing.expect(app.dirty);
}

test "thinking menu keys choose through Pi and held Enter never sends the draft" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    try std.testing.expect(c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "dummy"));
    defer _ = c.SDL_ResetHint(c.SDL_HINT_VIDEO_DRIVER);
    try std.testing.expect(c.SDL_InitSubSystem(c.SDL_INIT_VIDEO));
    defer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    app.window = c.SDL_CreateWindow("Thinking menu regression", 640, 480, c.SDL_WINDOW_HIDDEN) orelse return error.Window;
    defer c.SDL_DestroyWindow(app.window);
    const surface = c.SDL_CreateSurface(640, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    app.renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(app.renderer);
    app.wake_event = 0;
    app.closing = false;
    app.force_dialog = false;
    app.settings_open = false;
    app.model_menu = false;
    app.thinking_menu = true;
    app.focused_editor = true;
    app.options = .{};
    app.preedit = .empty;
    app.preferred_caret_x = null;
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    try app.editor.setText("unfinished draft");
    app.editor.setCaret(3, true);
    const draft_selection = app.editor.selection();
    var levels = [_][]const u8{ "off", "low", "medium", "high" };
    app.runtime_snapshot = .{ .allocator = allocator, .thinking_levels = &levels, .thinking_level = "low" };
    app.highlightCurrentThinking();

    const p = @import("platform/executables.zig").c;
    const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
    defer c.SDL_DestroyMutex(mutex);
    var wake: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), p.spica_wake_create(&wake));
    defer p.spica_close(wake[0]);
    defer p.spica_close(wake[1]);
    var runtime: pi.Runtime = .{
        .allocator = allocator,
        .io = undefined,
        .options = .{ .database_path = "", .project_path = "", .wake_event = 0 },
        .options_arena = undefined,
        .mutex = mutex,
        .wake = wake,
        .state = .{ .allocator = allocator },
    };
    defer {
        for (runtime.inputs.items) |input| if (input == .bytes) allocator.free(input.bytes.data);
        runtime.inputs.deinit(allocator);
    }
    app.runtime = &runtime;
    app.runtime_retiring = false;

    // Escape closes without choosing and leaves the draft and its selection alone.
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_ESCAPE;
    try app.handle(&event);
    try std.testing.expect(!app.thinking_menu);
    try std.testing.expectEqual(@as(usize, 0), runtime.inputs.items.len);
    try std.testing.expectEqualStrings("unfinished draft", app.editor.textBytes());
    try std.testing.expectEqual(draft_selection, app.editor.selection());

    // Enter sends the highlighted level and closes the menu.
    try app.act(.thinking);
    try std.testing.expectEqual(@as(?usize, 1), app.selectedThinkingIndex());
    event.key.key = c.SDLK_DOWN;
    try app.handle(&event);
    event.key.key = c.SDLK_RETURN;
    try app.handle(&event);
    try std.testing.expect(!app.thinking_menu);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    const command = try std.json.parseFromSlice(std.json.Value, allocator, runtime.inputs.items[0].bytes.data, .{});
    defer command.deinit();
    try std.testing.expectEqualStrings("set_thinking_level", command.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("medium", command.value.object.get("level").?.string);

    // Repeats of that held Enter reach the focused editor but must not submit.
    event.key.repeat = true;
    try app.handle(&event);
    event.key.mod = c.SDL_KMOD_CTRL;
    try app.handle(&event);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    try std.testing.expectEqualStrings("unfinished draft", app.editor.textBytes());
    event.key.repeat = false;
    event.key.mod = 0;

    // An empty level list leaves nothing to choose.
    app.thinking_menu = true;
    app.runtime_snapshot.?.thinking_levels = &.{};
    try app.handle(&event);
    try std.testing.expect(app.thinking_menu);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
}

test "background prompt acknowledgements clear only the submitted chat revision" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    app.allocator = allocator;
    app.dirty = false;
    app.force_dialog = false;
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    try app.editor.setText("active chat draft");
    for ([_]bool{ false, true }) |edited_after_send| {
        const text = if (edited_after_send) "new background draft" else "submitted prompt";
        var chat = ParkedChat{
            .id = 7,
            .runtime = null,
            .snapshot = null,
            .cwd = try allocator.dupeZ(u8, "/project"),
            .path = null,
            .trust = false,
            .draft = try allocator.dupe(u8, text),
            .caret = text.len,
            .anchor = text.len,
            .draft_revision = if (edited_after_send) 2 else 1,
            .submitted = .{ .token = 11, .draft_revision = 1 },
            .accepted_clear_revision = null,
            .title = undefined,
            .title_len = 0,
            .view = .new_thread,
            .archived = false,
            .member = false,
            .enrollment_intent = false,
            .accepted_enrollment = false,
            .enrollment_failed = false,
            .run_started = null,
            .run_base_revision = 0,
            .run_elapsed = null,
            .behavior = .prompt,
            .error_text = undefined,
            .error_len = 0,
            .scroll = 0,
        };
        defer chat.deinit(allocator);
        const snapshot = pi.Snapshot{
            .allocator = allocator,
            .status = .streaming,
            .accepted_command_id = try allocator.dupe(u8, "desktop-11"),
            .role = try allocator.dupe(u8, "assistant"),
            .kind = try allocator.dupe(u8, "message"),
        };
        try app.consumeParkedSnapshot(&chat, snapshot);
        try std.testing.expect(chat.submitted == null);
        try std.testing.expect(chat.enrollment_intent and chat.accepted_enrollment);
        try std.testing.expectEqualStrings(if (edited_after_send) text else "", chat.draft);
        if (!edited_after_send) {
            try std.testing.expectEqualStrings(text, chat.cleared_draft.?);
            try std.testing.expectEqual(chat.draft_revision, chat.accepted_clear_revision.?);
        }
        try std.testing.expectEqualStrings("active chat draft", app.editor.textBytes());
        const recovery = pi.Snapshot{
            .allocator = allocator,
            .status = .streaming,
            .recovery_revision = 1,
            .pending_draft = try allocator.dupe(u8, "recovered background input"),
            .role = try allocator.dupe(u8, "assistant"),
            .kind = try allocator.dupe(u8, "message"),
        };
        try app.consumeParkedSnapshot(&chat, recovery);
        try std.testing.expectEqualStrings(if (edited_after_send) text else "recovered background input", chat.draft);
        try std.testing.expectEqualStrings("active chat draft", app.editor.textBytes());
    }
}
