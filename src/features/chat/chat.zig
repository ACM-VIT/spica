const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const pi = @import("../../core/runtime.zig");
const SessionCatalog = @import("../../core/catalog.zig");
const Bounded = @import("../../text/bounded.zig").Bounded;
const App = @import("../../app.zig").App;
const processes = @import("processes.zig");
const workspace = @import("../library/workspace.zig");
const menus = @import("../models/menus.zig");

pub const Title = Bounded(128);
pub const ErrorText = Bounded(512);
pub const ThreadTarget = struct { path: ?[:0]u8, cwd: [:0]u8, archived: bool = false };
pub const SubmittedPrompt = struct { token: u64, draft_revision: u64 };
pub const View = enum { new_thread, opening, existing };

pub const ModelRestore = struct {
    provider: []u8,
    model: []u8,
    thinking: []u8,

    pub fn capture(allocator: std.mem.Allocator, snapshot: pi.Snapshot) !ModelRestore {
        const provider = try allocator.dupe(u8, snapshot.provider);
        errdefer allocator.free(provider);
        const model = try allocator.dupe(u8, snapshot.model);
        errdefer allocator.free(model);
        const thinking = try allocator.dupe(u8, snapshot.thinking_level);
        return .{ .provider = provider, .model = model, .thinking = thinking };
    }

    pub fn deinit(self: *ModelRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.thinking);
    }
};

pub const SnapshotChanges = struct {
    canonical: bool,
    generation: bool,
    session: bool,
    error_message: bool,
    recovery: bool,

    pub fn between(old: ?pi.Snapshot, incoming: *const pi.Snapshot) SnapshotChanges {
        const previous = old orelse return .{
            .canonical = true,
            .generation = false,
            .session = incoming.session_file.len != 0,
            .error_message = incoming.error_message.len != 0,
            .recovery = incoming.recovery_revision != 0,
        };
        return .{
            .canonical = incoming.visible_revision != previous.visible_revision,
            .generation = incoming.generation != previous.generation,
            .session = incoming.session_file.len != 0 and !std.mem.eql(u8, previous.session_file, incoming.session_file),
            .error_message = incoming.error_message.len != 0 and !std.mem.eql(u8, previous.error_message, incoming.error_message),
            .recovery = incoming.recovery_revision != 0 and incoming.recovery_revision != previous.recovery_revision,
        };
    }
};

// Inactive chats retain only runtime metadata and bounded draft text. The single
// viewport, text layouts, and composer undo storage stay with the active chat.
pub const ParkedChat = struct {
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
    title: Title = .{},
    view: View,
    archived: bool,
    member: bool,
    enrollment_intent: bool,
    accepted_enrollment: bool,
    enrollment_failed: bool,
    run_started: ?u64,
    run_base_revision: u64,
    run_elapsed: ?u64,
    behavior: pi.Behavior,
    error_text: ErrorText = .{},
    scroll: f32,
    retiring: bool = false,

    pub fn session(self: *const ParkedChat) []const u8 {
        if (self.snapshot) |snapshot| if (snapshot.session_file.len != 0) return snapshot.session_file;
        return self.path orelse "";
    }

    pub fn displayTitle(self: *const ParkedChat) []const u8 {
        if (self.snapshot) |snapshot| if (snapshot.session_name.len != 0) return snapshot.session_name;
        return if (self.title.isEmpty()) "New thread" else self.title.slice();
    }

    pub fn fail(self: *ParkedChat, operation: []const u8, err: anyerror) void {
        self.error_text.print("{s}: {s}", .{ operation, @errorName(err) }, "Background chat error");
        std.log.err("{s}", .{self.error_text.slice()});
    }

    pub fn deinit(self: *ParkedChat, allocator: std.mem.Allocator) void {
        if (self.runtime) |runtime| runtime.destroy() catch |err| std.log.err("Parked runtime shutdown invariant: {s}", .{@errorName(err)});
        if (self.snapshot) |*snapshot| snapshot.deinit();
        allocator.free(self.cwd);
        if (self.path) |path| allocator.free(path);
        allocator.free(self.draft);
        if (self.cleared_draft) |draft| allocator.free(draft);
        if (self.model_restore) |*settings| settings.deinit(allocator);
    }
};

pub fn currentSession(app: *const App) []const u8 {
    if (app.pending_thread) |target| if (target.path) |path| return path;
    if (app.chat_view == .opening) return app.options.resume_file orelse "";
    if (app.runtime_snapshot) |snapshot| if (snapshot.session_file.len != 0) return snapshot.session_file;
    return app.options.resume_file orelse "";
}

pub fn parkCurrent(app: *App) !void {
    const draft = try app.allocator.dupe(u8, app.editor.textBytes());
    errdefer app.allocator.free(draft);
    const path: ?[:0]u8 = if (app.resume_path) |owned| owned else if (app.options.resume_file) |source| try app.allocator.dupeZ(u8, source) else null;
    errdefer if (app.resume_path == null) if (path) |owned| app.allocator.free(owned);
    try app.parked_chats.append(app.allocator, .{
        .id = app.chat_id,
        .runtime = app.runtime,
        .snapshot = app.runtime_snapshot,
        .cwd = app.project_path,
        .path = path,
        .trust = app.options.trust_project,
        .draft = draft,
        .caret = app.editor.caret,
        .anchor = app.editor.anchor,
        .draft_revision = app.draft_revision,
        .submitted = app.submitted_prompt,
        .accepted_clear_revision = app.accepted_clear_revision,
        .cleared_draft = app.accepted_draft,
        .model_restore = app.model_restore,
        .title = app.thread_title,
        .view = app.chat_view,
        .archived = app.current_archived,
        .member = app.current_member,
        .enrollment_intent = app.enrollment_intent,
        .accepted_enrollment = app.accepted_enrollment,
        .enrollment_failed = app.enrollment_failed,
        .run_started = app.run_started,
        .run_base_revision = app.run_base_revision,
        .run_elapsed = app.run_elapsed,
        .behavior = app.behavior,
        .error_text = app.error_text,
        .scroll = app.scroll,
        .retiring = app.runtime_retiring,
    });
    app.runtime = null;
    app.runtime_snapshot = null;
    app.resume_path = null;
    app.accepted_draft = null;
    app.model_restore = null;
    app.runtime_retiring = false;
}

pub fn resetViewport(app: *App) void {
    app.transcript.clear();
    app.generation += 1;
    app.content_pending = false;
    app.pending_ordinal = null;
    app.conversation_dirty = false;
    menus.closeModelMenu(app);
    app.thinking_menu.open = false;
    app.preedit.clearRetainingCapacity();
    _ = c.SDL_ClearComposition(app.window);
    app.dragging = false;
    app.editor_view.reset();
    app.buttons.clear();
    app.draft_due = c.SDL_GetTicks() + 250;
    app.dirty = true;
}

pub fn activateParked(app: *App, index: usize) !void {
    // Reserve before transferring ownership; a failed allocation leaves the
    // active chat and every runtime intact.
    try parkCurrent(app);
    const chat = app.parked_chats.orderedRemove(index);
    defer app.allocator.free(chat.draft);
    app.chat_id = chat.id;
    app.runtime = chat.runtime;
    app.runtime_snapshot = chat.snapshot;
    app.project_path = chat.cwd;
    app.resume_path = chat.path;
    app.options.resume_file = chat.path;
    app.options.trust_project = chat.trust;
    app.model_restore = chat.model_restore;
    app.accepted_draft = chat.cleared_draft;
    app.runtime_retiring = chat.retiring;
    try app.editor.setText(chat.draft);
    app.editor.setCaret(chat.anchor, false);
    app.editor.setCaret(chat.caret, true);
    app.draft_revision = chat.draft_revision;
    app.submitted_prompt = chat.submitted;
    app.accepted_clear_revision = chat.accepted_clear_revision;
    app.thread_title = chat.title;
    app.chat_view = chat.view;
    app.current_archived = chat.archived;
    app.current_member = chat.member;
    app.enrollment_intent = chat.enrollment_intent;
    app.accepted_enrollment = chat.accepted_enrollment;
    app.enrollment_failed = chat.enrollment_failed;
    app.run_started = chat.run_started;
    app.run_base_revision = chat.run_base_revision;
    app.run_elapsed = chat.run_elapsed;
    app.behavior = chat.behavior;
    app.error_text = chat.error_text;
    app.scroll = chat.scroll;
    app.follow_bottom = false;
    resetViewport(app);
    if (chat.retiring) {
        // Shutdown cannot be reversed. Keep ownership until exit before
        // starting its replacement, so this session never has two writers.
        app.dirty = true;
    } else if (app.runtime == null or app.runtime.?.isFinished()) {
        try processes.beginRuntime(app);
    }
    app.requestConversation();
}

pub fn openParked(app: *App, index: usize) !void {
    if (app.closing or app.pending_thread != null) return error.ThreadSwitchPending;
    if (app.pending_mutation) |mutation| if (!mutation.automatic) return error.WorkspaceMutationPending;
    if (index >= app.parked_chats.items.len) return error.StaleThreadChoice;
    try workspace.saveDraft(app);
    try activateParked(app, index);
    workspace.revealCurrentFolder(app);
}

pub fn finishThreadSwitch(app: *App) !void {
    const target = app.pending_thread orelse return;
    const trust = app.options.trust_project != null and app.options.trust_project.? and std.mem.eql(u8, app.project_path, target.cwd);
    try parkCurrent(app);
    app.pending_thread = null;
    app.chat_id = app.next_chat_id;
    app.next_chat_id += 1;
    app.project_path = target.cwd;
    app.resume_path = target.path;
    app.options.resume_file = target.path;
    app.options.trust_project = trust;
    app.current_archived = target.archived;
    app.current_member = target.path != null;
    app.enrollment_intent = false;
    app.enrollment_failed = false;
    app.accepted_enrollment = false;
    app.submitted_prompt = null;
    app.accepted_clear_revision = null;
    app.draft_revision = 0;
    try app.editor.setText("");
    app.thread_title.clear();
    app.chat_view = if (target.path == null) .new_thread else .opening;
    app.run_started = null;
    app.run_elapsed = null;
    app.run_base_revision = 0;
    app.behavior = .prompt;
    app.error_text.clear();
    app.scroll = 0;
    app.follow_bottom = true;
    resetViewport(app);
    workspace.revealCurrentFolder(app);
    try processes.beginRuntime(app);
}

pub fn newThreadIn(app: *App, path: []const u8) !void {
    if (app.pending_mutation) |mutation| if (!mutation.automatic) return error.WorkspaceMutationPending;
    if (app.pending_thread != null or app.closing) return error.ThreadSwitchPending;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(app.io, path, app.allocator);
    var transferred = false;
    errdefer if (!transferred) app.allocator.free(cwd);
    var dir = try std.Io.Dir.cwd().openDir(app.io, cwd, .{});
    dir.close(app.io);
    if (app.projects.items.len < 64) try workspace.addProject(app, cwd);
    try workspace.saveDraft(app);
    app.pending_thread = .{ .path = null, .cwd = cwd };
    transferred = true;
    try finishThreadSwitch(app);
}

pub fn openThread(app: *App, index: usize) !void {
    const catalog = app.catalog orelse return;
    if (index >= catalog.threads.len) return;
    const thread = catalog.threads[index];
    try openSource(app, thread.path, thread.cwd, thread.title, thread.archived, thread.available);
}

pub fn openSource(app: *App, source: []const u8, project: []const u8, title_text: []const u8, archived: bool, available: bool) !void {
    if (app.pending_thread != null or app.closing) return error.ThreadSwitchPending;
    if (app.pending_mutation) |mutation| if (!mutation.automatic) return error.WorkspaceMutationPending;
    if (std.mem.eql(u8, currentSession(app), source)) {
        app.current_archived = archived;
        app.current_member = true;
        app.follow_bottom = true;
        app.dirty = true;
        return;
    }
    for (app.parked_chats.items, 0..) |chat, index| {
        if (!std.mem.eql(u8, chat.session(), source)) continue;
        try workspace.saveDraft(app);
        try activateParked(app, index);
        app.current_archived = archived;
        app.current_member = true;
        workspace.revealCurrentFolder(app);
        return;
    }
    if (!available) return error.SessionSourceUnavailable;
    try SessionCatalog.validateSource(app.io, source, project);
    var transferred = false;
    const path = try app.allocator.dupeZ(u8, source);
    errdefer if (!transferred) app.allocator.free(path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(app.io, project, app.allocator);
    errdefer if (!transferred) app.allocator.free(cwd);
    try workspace.saveDraft(app);
    app.pending_thread = .{ .path = path, .cwd = cwd, .archived = archived };
    transferred = true;
    try finishThreadSwitch(app);
    app.thread_title.set(App.clipped(title_text));
}

pub fn submit(app: *App) !void {
    if (app.current_archived) return error.RestoreArchivedChatBeforeSending;
    if (app.enrollment_intent) return error.WorkspaceEnrollmentPending;
    if (app.pending_mutation) |mutation| if (!mutation.automatic or mutation.owner_id == app.chat_id) return error.WorkspaceEnrollmentPending;
    if (app.preedit.items.len != 0 or app.closing) return;
    const runtime = app.runtime orelse return error.StartPiFirst;
    const status = processes.runtimeStatus(app);
    if (status != .ready and status != .streaming) return error.PiNotReady;
    if (processes.bashRunning(app)) return error.PiBusy;
    const text = app.editor.textBytes();
    if (text.len == 0) return;
    if (app.thread_title.isEmpty()) {
        const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        const first = std.mem.trim(u8, App.clipped(text[0..end]), " \t\r");
        if (first.len != 0 and (app.runtime_snapshot == null or app.runtime_snapshot.?.session_name.len == 0)) try runtime.setSessionName(first);
        app.thread_title.set(first);
    }
    app.run_started = c.SDL_GetTicks();
    app.run_base_revision = if (app.runtime_snapshot) |snapshot| snapshot.visible_revision else 0;
    app.run_elapsed = null;
    app.error_text.clear();
    if (app.submitted_prompt != null) return error.PromptAcknowledgementPending;
    const behavior: pi.Behavior = if (status == .ready) .prompt else if (app.behavior == .prompt) .follow_up else app.behavior;
    const token = try runtime.sendPrompt(text, behavior);
    app.submitted_prompt = .{ .token = token, .draft_revision = app.draft_revision };
    app.follow_bottom = true;
    app.dirty = true;
}
