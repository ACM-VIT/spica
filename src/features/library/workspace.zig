const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const SessionCatalog = @import("../../core/catalog.zig");
const Draft = @import("../../core/draft.zig");
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

pub fn dupeDraft(allocator: std.mem.Allocator, entry: Draft.Entry) !Draft.Entry {
    const session = try allocator.dupe(u8, entry.session);
    errdefer allocator.free(session);
    const cwd = try allocator.dupe(u8, entry.cwd);
    errdefer allocator.free(cwd);
    return .{ .session = session, .cwd = cwd, .text = try allocator.dupe(u8, entry.text) };
}

pub fn freeDraft(allocator: std.mem.Allocator, entry: Draft.Entry) void {
    allocator.free(entry.session);
    allocator.free(entry.cwd);
    allocator.free(entry.text);
}

pub fn freeDrafts(allocator: std.mem.Allocator, drafts: *std.ArrayList(Draft.Entry)) void {
    for (drafts.items) |entry| freeDraft(allocator, entry);
    drafts.deinit(allocator);
}

pub fn draftIndex(drafts: []const Draft.Entry, session: []const u8, cwd: []const u8) ?usize {
    for (drafts, 0..) |entry, index| if (entry.matches(session, cwd)) return index;
    return null;
}

pub fn dropMissingSessions(allocator: std.mem.Allocator, io: std.Io, drafts: *std.ArrayList(Draft.Entry)) void {
    var index: usize = 0;
    while (index < drafts.items.len) {
        const session = drafts.items[index].session;
        if (session.len != 0) if (std.Io.Dir.cwd().access(io, session, .{})) {} else |err| if (err == error.FileNotFound) {
            freeDraft(allocator, drafts.orderedRemove(index));
            continue;
        };
        index += 1;
    }
}

pub fn takeStoredDraft(app: *App, session: []const u8, cwd: []const u8) !void {
    const index = draftIndex(app.stored_drafts.items, session, cwd) orelse return;
    try app.editor.setText(app.stored_drafts.items[index].text);
    freeDraft(app.allocator, app.stored_drafts.orderedRemove(index));
}

// A chat keeps its draft under its Pi session only once it is a workspace
// member or enrolling; Pi names a session file before the first prompt.
fn draftEntry(session: []const u8, durable: bool, cwd: []const u8, text: []const u8) Draft.Entry {
    return .{ .session = if (durable) session else "", .cwd = cwd, .text = text };
}

pub const DraftLoss = struct { dropped: usize = 0, shadowed: usize = 0 };

pub const CollectedDrafts = struct { count: usize, dropped: usize, shadowed: usize };

pub fn collectDrafts(app: *const App, drafts: *[Draft.max_drafts]Draft.Entry) CollectedDrafts {
    const resumed = app.options.resume_file orelse "";
    const active_session = if (app.runtime_snapshot) |snapshot| if (snapshot.session_file.len != 0) snapshot.session_file else resumed else resumed;
    const parked = app.parked_chats.items;
    var count: usize = 0;
    var dropped: usize = 0;
    var shadowed: usize = 0;
    for (0..1 + parked.len + app.stored_drafts.items.len) |index| {
        const entry = if (index == 0)
            draftEntry(active_session, app.current_member or app.enrollment_intent, app.project_path, app.editor.textBytes())
        else if (index <= parked.len)
            draftEntry(parked[index - 1].session(), parked[index - 1].member or parked[index - 1].enrollment_intent, parked[index - 1].cwd, parked[index - 1].draft)
        else
            app.stored_drafts.items[index - 1 - parked.len];
        if (entry.text.len == 0) continue;
        // Live chats come first, so an older stored copy never replaces them.
        // Two live unsent threads in one project share a key; only the first is kept.
        if (draftIndex(drafts[0..count], entry.session, entry.cwd) != null) {
            if (index <= parked.len) shadowed += 1;
            continue;
        }
        if (count == drafts.len) {
            dropped += 1;
            continue;
        }
        drafts[count] = entry;
        count += 1;
    }
    return .{ .count = count, .dropped = dropped, .shadowed = shadowed };
}

pub fn saveDraft(app: *App) !void {
    var drafts: [Draft.max_drafts]Draft.Entry = undefined;
    const collected = collectDrafts(app, &drafts);
    var projects: [max_projects][]const u8 = undefined;
    for (app.projects.items, 0..) |path, index| projects[index] = path;
    try app.draft_writer.submit(.{
        .drafts = drafts[0..collected.count],
        .light = app.light,
        .font_size = app.appearance.font_size,
        .ui_scale = app.appearance.ui_scale,
        .chat_width = app.appearance.chat_width,
        .projects = projects[0..app.projects.items.len],
    });
    app.draft_due = null;
    // Unsaved drafts stay in memory; only the disk copy is bounded.
    if (collected.dropped > app.draft_loss.dropped) app.report("Some drafts exceed the saved draft limit", error.DraftLimitReached);
    if (collected.shadowed > app.draft_loss.shadowed) app.report("Only one unsent draft per project is saved", error.DraftKeyShared);
    app.draft_loss = .{ .dropped = collected.dropped, .shadowed = collected.shadowed };
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

const Composer = @import("../../text/composer.zig").Composer;

test "drafts persist per chat and unsent threads stay unenrolled" {
    const allocator = std.testing.allocator;
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "workspace.json" });
    defer allocator.free(path);

    var app: App = undefined;
    app.allocator = allocator;
    app.runtime_snapshot = null;
    app.options = .{ .resume_file = "/s/a.jsonl" };
    app.project_path = @constCast("/p");
    app.current_member = true;
    app.enrollment_intent = false;
    app.light = false;
    app.appearance = .{};
    app.projects = .empty;
    app.dirty = false;
    app.error_text = .{};
    app.draft_loss = .{};
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    try app.editor.setText("draft A");
    app.stored_drafts = .empty;
    defer freeDrafts(allocator, &app.stored_drafts);
    try app.stored_drafts.append(allocator, try dupeDraft(allocator, .{ .session = "/s/a.jsonl", .cwd = "/p", .text = "stale A" }));
    try app.stored_drafts.append(allocator, try dupeDraft(allocator, .{ .session = "/s/d.jsonl", .cwd = "/p", .text = "never opened" }));
    app.parked_chats = .empty;
    defer {
        for (app.parked_chats.items) |*parked| parked.deinit(allocator);
        app.parked_chats.deinit(allocator);
    }
    for ([_]struct { path: []const u8, cwd: []const u8, draft: []const u8, member: bool }{
        .{ .path = "/s/b.jsonl", .cwd = "/p", .draft = "draft B", .member = true },
        .{ .path = "/s/c.jsonl", .cwd = "/q", .draft = "unsent C", .member = false },
        .{ .path = "/s/e.jsonl", .cwd = "/p", .draft = "", .member = true },
    }, 0..) |spec, id| {
        const cwd = try allocator.dupeZ(u8, spec.cwd);
        errdefer allocator.free(cwd);
        const session = try allocator.dupeZ(u8, spec.path);
        errdefer allocator.free(session);
        const draft = try allocator.dupe(u8, spec.draft);
        errdefer allocator.free(draft);
        try app.parked_chats.append(allocator, .{
            .id = id + 2,
            .runtime = null,
            .snapshot = null,
            .cwd = cwd,
            .path = session,
            .trust = false,
            .draft = draft,
            .caret = 0,
            .anchor = 0,
            .draft_revision = 1,
            .submitted = null,
            .accepted_clear_revision = null,
            .view = .existing,
            .archived = false,
            .member = spec.member,
            .enrollment_intent = false,
            .accepted_enrollment = false,
            .enrollment_failed = false,
            .run_started = null,
            .run_base_revision = 0,
            .run_elapsed = null,
            .behavior = .prompt,
            .scroll = 0,
        });
    }

    app.draft_writer = try Draft.Writer.create(io, path, 0);
    try saveDraft(&app);
    app.draft_writer.destroy();
    try std.testing.expectEqual(@as(usize, 0), app.error_text.slice().len);
    try std.testing.expect(!app.parked_chats.items[1].member and !app.parked_chats.items[1].enrollment_intent);

    var restored = try Draft.restore(io, path);
    defer restored.deinit();
    const drafts = restored.value().drafts;
    try std.testing.expectEqual(@as(usize, 4), drafts.len);
    try std.testing.expectEqualStrings("draft A", drafts[draftIndex(drafts, "/s/a.jsonl", "").?].text);
    try std.testing.expectEqualStrings("draft B", drafts[draftIndex(drafts, "/s/b.jsonl", "").?].text);
    try std.testing.expectEqualStrings("unsent C", drafts[draftIndex(drafts, "", "/q").?].text);
    try std.testing.expect(draftIndex(drafts, "/s/c.jsonl", "/q") == null);
    try std.testing.expectEqualStrings("never opened", drafts[draftIndex(drafts, "/s/d.jsonl", "").?].text);
    try std.testing.expect(draftIndex(drafts, "/s/e.jsonl", "") == null);

    var buffer: [Draft.max_drafts]Draft.Entry = undefined;
    allocator.free(app.parked_chats.items[0].draft);
    app.parked_chats.items[0].draft = try allocator.dupe(u8, "");
    const collected = collectDrafts(&app, &buffer);
    try std.testing.expectEqual(@as(usize, 3), collected.count);
    try std.testing.expect(draftIndex(buffer[0..collected.count], "/s/b.jsonl", "") == null);
    try std.testing.expect(draftIndex(buffer[0..collected.count], "/s/a.jsonl", "") != null);
    try std.testing.expectEqual(@as(usize, 0), collected.shadowed);

    // A second unsent thread in /q shares C's key. The active chat's draft wins,
    // and the lost draft is counted so saveDraft can report it.
    app.current_member = false;
    app.project_path = @constCast("/q");
    const shared = collectDrafts(&app, &buffer);
    try std.testing.expectEqual(@as(usize, 1), shared.shadowed);
    try std.testing.expectEqualStrings("draft A", buffer[draftIndex(buffer[0..shared.count], "", "/q").?].text);

    app.draft_writer = try Draft.Writer.create(io, path, 0);
    defer app.draft_writer.destroy();
    app.draft_loss = .{ .shadowed = 1 };
    try saveDraft(&app);
    try std.testing.expectEqual(@as(usize, 0), app.error_text.slice().len);
    try std.testing.expectEqual(@as(usize, 1), app.draft_loss.shadowed);
}

test "stored drafts of deleted sessions are dropped and the oldest drafts are evicted first" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.jsonl", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const kept = try std.fs.path.join(allocator, &.{ root, "kept.jsonl" });
    defer allocator.free(kept);
    const deleted = try std.fs.path.join(allocator, &.{ root, "deleted.jsonl" });
    defer allocator.free(deleted);

    var drafts: std.ArrayList(Draft.Entry) = .empty;
    defer freeDrafts(allocator, &drafts);
    try drafts.append(allocator, try dupeDraft(allocator, .{ .session = deleted, .cwd = root, .text = "gone" }));
    try drafts.append(allocator, try dupeDraft(allocator, .{ .session = kept, .cwd = root, .text = "kept" }));
    try drafts.append(allocator, try dupeDraft(allocator, .{ .cwd = "/missing-folder", .text = "folder" }));
    dropMissingSessions(allocator, io, &drafts);
    try std.testing.expectEqual(@as(usize, 2), drafts.items.len);
    try std.testing.expect(draftIndex(drafts.items, deleted, "") == null);
    try std.testing.expect(draftIndex(drafts.items, kept, "") != null);
    try std.testing.expect(draftIndex(drafts.items, "", "/missing-folder") != null);

    var app: App = undefined;
    app.runtime_snapshot = null;
    app.options = .{};
    app.project_path = @constCast("/active");
    app.current_member = false;
    app.enrollment_intent = false;
    app.parked_chats = .empty;
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    app.stored_drafts = .empty;
    defer freeDrafts(allocator, &app.stored_drafts);
    var name: [32]u8 = undefined;
    for (0..Draft.max_drafts) |index| {
        const cwd = try std.fmt.bufPrint(&name, "/project-{d}", .{index});
        try app.stored_drafts.append(allocator, try dupeDraft(allocator, .{ .cwd = cwd, .text = "stored" }));
    }
    try app.editor.setText("active");
    var buffer: [Draft.max_drafts]Draft.Entry = undefined;
    const collected = collectDrafts(&app, &buffer);
    try std.testing.expectEqual(@as(usize, Draft.max_drafts), collected.count);
    try std.testing.expectEqual(@as(usize, 1), collected.dropped);
    try std.testing.expect(draftIndex(buffer[0..collected.count], "", "/active") != null);
    try std.testing.expect(draftIndex(buffer[0..collected.count], "", "/project-0") != null);
    const last = try std.fmt.bufPrint(&name, "/project-{d}", .{Draft.max_drafts - 1});
    try std.testing.expect(draftIndex(buffer[0..collected.count], "", last) == null);
}
