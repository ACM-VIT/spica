const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const SessionCatalog = @import("../../core/catalog.zig");
const Library = @import("panel.zig");
const App = @import("../../app.zig").App;
const chat = @import("../chat/chat.zig");
const processes = @import("../chat/processes.zig");
const menus = @import("../models/menus.zig");

pub const max_projects = 64;

pub const PendingMutation = struct {
    id: u64,
    kind: SessionCatalog.Mutation,
    path: [:0]u8,
    cwd: [:0]u8,
    title: []u8,
    open_after: bool,
    automatic: bool,
    owner_id: ?u64 = null,

    pub fn deinit(self: *PendingMutation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.cwd);
        allocator.free(self.title);
    }
};

pub fn saveDraft(app: *App) !void {
    var projects: [max_projects][]const u8 = undefined;
    for (app.projects.items, 0..) |path, index| projects[index] = path;
    try app.draft_writer.submit(.{
        .draft = app.editor.textBytes(),
        .light = app.light,
        .font_size = app.appearance.font_size,
        .ui_scale = app.appearance.ui_scale,
        .chat_width = app.appearance.chat_width,
        .projects = projects[0..app.projects.items.len],
    });
    app.draft_due = null;
}

pub fn scheduleSave(app: *App) void {
    app.draft_due = c.SDL_GetTicks() + 250;
}

pub fn addProject(app: *App, path: []const u8) !void {
    for (app.projects.items) |existing| if (std.mem.eql(u8, existing, path)) return;
    if (app.projects.items.len == max_projects) return error.ProjectLimitReached;
    const owned = try app.allocator.dupeZ(u8, path);
    errdefer app.allocator.free(owned);
    try app.projects.append(app.allocator, owned);
    scheduleSave(app);
}

fn folderChosen(userdata: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = @intCast(@intFromPtr(userdata));
    event.user.code = 1;
    if (files == null) event.user.code = 2;
    if (files != null and files[0] != null) event.user.data1 = c.SDL_strdup(files[0]);
    if (!c.SDL_PushEvent(&event)) if (event.user.data1) |path| c.SDL_free(path);
}

pub fn chooseFolder(app: *App) void {
    if (app.folder_pending) return;
    app.folder_pending = true;
    c.SDL_ShowOpenFolderDialog(folderChosen, @ptrFromInt(app.wake_event), app.window, app.project_path.ptr, false);
}

pub fn folderChoice(app: *App, event: *const c.SDL_Event) !void {
    if (event.user.code == 2) {
        app.folder_pending = false;
        return error.FolderPickerUnavailable;
    }
    if (event.user.code != 1) return;
    app.folder_pending = false;
    if (event.user.data1) |path| {
        defer c.SDL_free(path);
        const chosen = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(app.io, chosen, app.allocator);
        defer app.allocator.free(canonical);
        try addProject(app, canonical);
    }
    app.dirty = true;
}

pub fn toggleFolder(app: *App, path: []const u8) !void {
    for (app.collapsed_folders.items, 0..) |folder, index| if (std.mem.eql(u8, path, folder)) {
        app.allocator.free(app.collapsed_folders.orderedRemove(index));
        return;
    };
    const owned = try app.allocator.dupe(u8, path);
    errdefer app.allocator.free(owned);
    try app.collapsed_folders.append(app.allocator, owned);
}

pub fn revealCurrentFolder(app: *App) void {
    for (app.collapsed_folders.items, 0..) |folder, index| if (std.mem.eql(u8, folder, app.project_path)) {
        app.allocator.free(app.collapsed_folders.orderedRemove(index));
        break;
    };
    app.sidebar_reveal_current = true;
}

pub fn queryLibrary(app: *App) !void {
    if (!app.library.open) return;
    app.library_generation += 1;
    app.library.begin(app.library_generation);
    app.buttons.clear();
    app.catalog_worker.search(app.library.scope, app.library.queryBytes(), app.library.offset, app.library_generation) catch |err| {
        app.library.fail(err);
        return err;
    };
    app.dirty = true;
}

pub fn showLibrary(app: *App, scope: SessionCatalog.Scope) !void {
    if (app.closing or app.force_dialog) return;
    if (!app.library.open) app.prior_editor_focus = app.focused_editor;
    app.settings_open = false;
    menus.closeAll(app);
    app.dragging = false;
    app.preedit.clearRetainingCapacity();
    _ = c.SDL_ClearComposition(app.window);
    app.focused_editor = false;
    app.library.show(scope);
    app.library.busy = if (app.pending_mutation) |mutation| !mutation.automatic else false;
    app.buttons.clear();
    _ = c.SDL_StartTextInput(app.window);
    app.catalog_worker.refresh();
    try queryLibrary(app);
}

pub fn closeLibrary(app: *App) void {
    app.library.close();
    _ = c.SDL_ClearComposition(app.window);
    app.focused_editor = app.prior_editor_focus;
    app.syncTextInput();
    app.buttons.clear();
    app.dirty = true;
}

pub fn queueMutation(app: *App, kind: SessionCatalog.Mutation, path: []const u8, cwd: []const u8, title_text: []const u8, open_after: bool, automatic: bool) !void {
    if (app.pending_mutation != null) return error.WorkspaceMutationPending;
    if (app.closing and !automatic) return error.ApplicationClosing;
    if (kind == .archive and std.mem.eql(u8, path, chat.currentSession(app)) and
        (processes.working(app) or app.submitted_prompt != null or app.pending_thread != null)) return error.StopCurrentRunBeforeArchiving;
    if (kind == .archive) for (app.parked_chats.items) |parked| {
        if (!std.mem.eql(u8, path, parked.session())) continue;
        if (parked.submitted != null) return error.StopCurrentRunBeforeArchiving;
        if (parked.snapshot) |snapshot| if (snapshot.status == .streaming or snapshot.bash_running) return error.StopCurrentRunBeforeArchiving;
    };
    if (open_after) {
        if (app.pending_thread != null) return error.ThreadSwitchPending;
        try SessionCatalog.validateSource(app.io, path, cwd);
    }
    const owned_path = try app.allocator.dupeZ(u8, path);
    errdefer app.allocator.free(owned_path);
    const owned_cwd = try app.allocator.dupeZ(u8, cwd);
    errdefer app.allocator.free(owned_cwd);
    const owned_title = try app.allocator.dupe(u8, title_text);
    errdefer app.allocator.free(owned_title);
    app.mutation_id += 1;
    try app.catalog_worker.mutate(kind, owned_path, owned_cwd, owned_title, app.mutation_id);
    app.pending_mutation = .{ .id = app.mutation_id, .kind = kind, .path = owned_path, .cwd = owned_cwd, .title = owned_title, .open_after = open_after, .automatic = automatic, .owner_id = if (automatic) app.chat_id else null };
    app.library.busy = !automatic;
    app.buttons.clear();
    app.library.invalidateTargets();
    app.dirty = true;
}

pub fn enrollCurrent(app: *App) void {
    if (!app.enrollment_intent or app.enrollment_failed or app.pending_mutation != null or app.pending_thread != null) return;
    const snapshot = app.runtime_snapshot orelse return;
    if (snapshot.session_file.len == 0 or (!app.accepted_enrollment and (snapshot.status == .starting or snapshot.status == .failed))) return;
    if (!app.accepted_enrollment) SessionCatalog.validateSource(app.io, snapshot.session_file, app.project_path) catch |err| {
        app.enrollment_failed = true;
        app.report("Explicit resume source could not be enrolled", err);
        return;
    };
    queueMutation(app, .enroll, snapshot.session_file, app.project_path, app.title(), false, true) catch |err| {
        app.enrollment_failed = true;
        app.report("Enrolling accepted chat; Ctrl/Cmd+R retries", err);
    };
}

pub fn enrollParked(app: *App, parked: *chat.ParkedChat) void {
    if (!parked.enrollment_intent or parked.enrollment_failed or app.pending_mutation != null) return;
    const snapshot = parked.snapshot orelse return;
    if (snapshot.session_file.len == 0 or (!parked.accepted_enrollment and (snapshot.status == .starting or snapshot.status == .failed))) return;
    if (!parked.accepted_enrollment) SessionCatalog.validateSource(app.io, snapshot.session_file, parked.cwd) catch |err| {
        parked.enrollment_failed = true;
        parked.fail("Explicit resume source could not be enrolled", err);
        return;
    };
    const title_text = if (snapshot.session_name.len != 0) snapshot.session_name else parked.title.slice();
    queueMutation(app, .enroll, snapshot.session_file, parked.cwd, title_text, false, true) catch |err| {
        parked.enrollment_failed = true;
        parked.fail("Enrolling accepted chat; Ctrl/Cmd+R retries", err);
        return;
    };
    app.pending_mutation.?.owner_id = parked.id;
}

pub fn retryEnrollment(app: *App) void {
    app.enrollment_failed = false;
    for (app.parked_chats.items) |*parked| parked.enrollment_failed = false;
    enrollCurrent(app);
    app.catalog_worker.refresh();
}

pub fn libraryIntent(app: *App, intent: Library.Intent) !void {
    switch (intent) {
        .search => try queryLibrary(app),
        .close => closeLibrary(app),
        .activate => {
            const thread = app.library.selectedThread() orelse return;
            if (app.library.scope == .import_pi) {
                try queueMutation(app, .enroll, thread.path, thread.cwd, thread.title, true, false);
            } else {
                try chat.openSource(app, thread.path, thread.cwd, thread.title, thread.archived, thread.available);
                closeLibrary(app);
            }
        },
        .archive, .restore => {
            const thread = app.library.selectedThread() orelse return;
            try queueMutation(app, if (intent == .archive) .archive else .restore, thread.path, thread.cwd, thread.title, false, false);
        },
    }
}

pub fn consumeCatalog(app: *App) void {
    while (app.catalog_worker.takeMutation()) |result| applyMutation(app, result);
    if (app.closing and processes.closeSettled(app)) app.running = false;
    if (app.catalog_worker.takeSearch()) |result| {
        app.buttons.clear();
        app.library.accept(result);
        app.dirty = true;
    }
    if (app.catalog_worker.take()) |result| switch (result) {
        .ready => |catalog| {
            app.buttons.clear();
            app.library.invalidateTargets();
            if (app.catalog) |*old| old.deinit();
            app.catalog = catalog;
            app.catalog_error = catalog.warning;
            if (app.catalog_error) |err| app.report("Workspace library is incomplete", err);
            app.dirty = true;
        },
        .failure => |err| {
            app.catalog_error = err;
            app.report("Discovering pi threads", err);
        },
    };
}

fn applyMutation(app: *App, result: SessionCatalog.MutationResult) void {
    const value = app.pending_mutation orelse return;
    if (result.id != value.id) {
        app.report("Workspace acknowledgement mismatch", error.UnexpectedMutationAcknowledgement);
        return;
    }
    var target = value;
    defer target.deinit(app.allocator);
    app.pending_mutation = null;
    app.library.busy = false;
    app.buttons.clear();
    app.library.invalidateTargets();
    defer app.dirty = true;
    if (result.err) |err| {
        if (target.automatic) {
            if (target.owner_id == app.chat_id) app.enrollment_failed = true;
            for (app.parked_chats.items) |*parked| if (target.owner_id == parked.id) {
                parked.enrollment_failed = true;
                parked.error_text.print("Enrollment failed: {s}; Ctrl/Cmd+R retries", .{@errorName(err)}, "Enrollment failed");
            };
        }
        if (app.library.open) app.library.fail(err);
        if (!target.automatic or target.owner_id == app.chat_id) {
            app.report(if (target.automatic) "Enrollment failed; Ctrl/Cmd+R retries" else "Workspace change was not saved", err);
        } else std.log.err("Background enrollment failed: {s}", .{@errorName(err)});
        return;
    }
    const archived = result.archived orelse (target.kind == .archive);
    if (target.automatic and target.owner_id == app.chat_id) {
        app.enrollment_intent = false;
        app.enrollment_failed = false;
        app.accepted_enrollment = false;
    }
    for (app.parked_chats.items) |*parked| {
        if (target.automatic and target.owner_id == parked.id) {
            parked.enrollment_intent = false;
            parked.enrollment_failed = false;
            parked.accepted_enrollment = false;
        }
        if (std.mem.eql(u8, target.path, parked.session())) {
            parked.member = true;
            parked.archived = archived;
            if (target.kind == .enroll and parked.view == .new_thread) parked.view = .existing;
        }
    }
    if (std.mem.eql(u8, target.path, chat.currentSession(app))) {
        app.current_member = true;
        if (target.kind == .enroll or target.kind == .restore) revealCurrentFolder(app);
        app.current_archived = archived;
        if (target.kind == .enroll and app.chat_view == .new_thread) app.chat_view = .existing;
    }
    app.catalog_worker.refresh();
    if (target.open_after) {
        chat.openSource(app, target.path, target.cwd, target.title, result.archived orelse false, true) catch |err| {
            app.library.fail(err);
            app.report("Imported chat could not be opened", err);
            return;
        };
        closeLibrary(app);
    } else if (app.library.open) queryLibrary(app) catch |err| app.report("Refreshing chat search", err);
}
