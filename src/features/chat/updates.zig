const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const pi = @import("../../core/runtime.zig");
const composer = @import("../../text/composer.zig");
const App = @import("../../app.zig").App;
const chat = @import("chat.zig");
const processes = @import("processes.zig");
const workspace = @import("../library/workspace.zig");
const menus = @import("../models/menus.zig");

pub fn consumeRuntime(app: *App) void {
    const runtime = app.runtime orelse return;
    if (runtime.takeSnapshot()) |incoming| if (!applySnapshot(app, runtime, incoming)) return;
    if (runtime.isFinished()) {
        app.submitted_prompt = null;
        workspace.enrollCurrent(app);
        if (app.enrollment_intent and !app.enrollment_failed and app.pending_mutation == null) {
            app.enrollment_failed = true;
            app.report("Accepted chat has no resumable source path", error.SessionPathUnavailable);
        }
        if (app.runtime_retiring and !app.closing) processes.beginRuntime(app) catch |err| app.report("Restarting parked chat", err);
    }
    if (!app.closing) chat.finishThreadSwitch(app) catch |err| app.report("Opening thread", err);
}

fn applySnapshot(app: *App, runtime: *pi.Runtime, incoming: pi.Snapshot) bool {
    const previous_status = processes.runtimeStatus(app);
    const changes = chat.SnapshotChanges.between(app.runtime_snapshot, &incoming);
    menus.updateModelSearch(app, incoming.models) catch |err| {
        app.model_picker.search.invalidate();
        app.model_picker.selection_cleared = true;
        app.buttons.clear();
        app.report("Refreshing model choices", err);
    };
    if (app.runtime_snapshot) |*old| old.deinit();
    app.runtime_snapshot = incoming;
    const snapshot = &app.runtime_snapshot.?;
    if (snapshot.status == .ready) if (app.model_restore) |settings| {
        app.model_restore = null;
        var owned = settings;
        defer owned.deinit(app.allocator);
        if (settings.model.len != 0) runtime.setModel(settings.provider, settings.model) catch |err| app.report("Restoring chat model", err);
        if (settings.thinking.len != 0) runtime.setThinkingLevel(settings.thinking) catch |err| app.report("Restoring chat thinking level", err);
    };
    if (changes.session or changes.generation) {
        if (app.chat_view != .opening) app.thread_title.clear();
        if (snapshot.session_name.len == 0 and app.thread_title.isEmpty()) if (app.catalog) |catalog| {
            for (catalog.threads) |thread| {
                if (!std.mem.eql(u8, thread.path, snapshot.session_file)) continue;
                app.thread_title.set(App.clipped(thread.title));
                break;
            }
        };
        if (changes.generation) {
            app.run_started = null;
            app.run_elapsed = null;
            app.behavior = .prompt;
        }
        app.generation += 1;
        app.content_pending = false;
        app.transcript.clear();
        app.scroll = 0;
        app.catalog_worker.refresh();
    }
    if (changes.error_message) {
        app.error_text.set(App.clipped(snapshot.error_message));
        std.log.err("Pi: {s}", .{snapshot.error_message});
    }
    if (app.submitted_prompt) |submitted| switch (snapshot.promptOutcome(submitted.token)) {
        .accepted => {
            app.submitted_prompt = null;
            if (!app.current_member) {
                app.enrollment_intent = true;
                app.enrollment_failed = false;
                app.accepted_enrollment = true;
            }
            if (app.draft_revision == submitted.draft_revision) {
                const saved = app.allocator.dupe(u8, app.editor.textBytes()) catch |err| {
                    app.report("Retaining accepted draft", err);
                    return false;
                };
                if (app.accepted_draft) |old| app.allocator.free(old);
                app.accepted_draft = saved;
                app.editor.selectAll();
                app.editor.insert("", .paste) catch |err| {
                    app.report("Clearing accepted draft", err);
                    return false;
                };
                app.edited();
                app.accepted_clear_revision = app.draft_revision;
            }
        },
        .rejected => app.submitted_prompt = null,
        .pending => if (runtime.isFinished()) {
            app.submitted_prompt = null;
        },
    };
    if (changes.recovery and snapshot.pending_draft.len != 0 and app.editor.len == 0 and app.submitted_prompt == null) {
        app.editor.insert(snapshot.pending_draft, .paste) catch |err| {
            app.report("Recovering cancelled input; raw source retained", err);
            return false;
        };
        app.edited();
    }
    if (!app.minimized) app.requestConversation();
    if (snapshot.session_file.len != 0 and (app.resume_path == null or !std.mem.eql(u8, app.resume_path.?, snapshot.session_file))) {
        const path = app.allocator.dupeZ(u8, snapshot.session_file) catch |err| {
            app.report("Retaining current session path", err);
            return false;
        };
        if (app.resume_path) |old| app.allocator.free(old);
        app.resume_path = path;
        app.options.resume_file = path;
    }
    if (changes.error_message and snapshot.visible_length == 0 and snapshot.status == .ready and app.run_started != null and app.accepted_clear_revision == app.draft_revision and app.editor.len == 0) {
        if (app.editor.undo()) {
            app.edited();
        } else if (app.accepted_draft) |draft| {
            app.editor.setText(draft) catch |err| app.report("Recovering rejected input", err);
            app.edited();
        }
    }
    if (app.run_started) |started| if (snapshot.runCompleted(app.run_base_revision)) {
        app.run_elapsed = c.SDL_GetTicks() - started;
        app.run_started = null;
    };
    if (snapshot.status == .needs_force_stop and previous_status != .needs_force_stop) app.force_dialog = true;
    if (snapshot.status == .ready and (previous_status == .streaming or changes.canonical)) app.catalog_worker.refresh();
    workspace.enrollCurrent(app);
    app.dirty = true;
    return true;
}

fn replaceParkedDraft(app: *App, parked: *chat.ParkedChat, text: []const u8) !void {
    if (text.len > composer.max_bytes) return error.TextTooLarge;
    const draft = try app.allocator.dupe(u8, text);
    app.allocator.free(parked.draft);
    parked.draft = draft;
    parked.caret = text.len;
    parked.anchor = text.len;
    parked.draft_revision += 1;
}

pub fn consumeParkedSnapshot(app: *App, parked: *chat.ParkedChat, incoming: pi.Snapshot) !void {
    const previous_status: pi.Status = if (parked.snapshot) |snapshot| snapshot.status else .stopped;
    const changes = chat.SnapshotChanges.between(parked.snapshot, &incoming);
    if (parked.snapshot) |*snapshot| snapshot.deinit();
    parked.snapshot = incoming;
    if (incoming.status == .ready) if (parked.model_restore) |settings| {
        parked.model_restore = null;
        var owned = settings;
        defer owned.deinit(app.allocator);
        const runtime = parked.runtime.?;
        if (settings.model.len != 0) runtime.setModel(settings.provider, settings.model) catch |err| parked.fail("Restoring chat model", err);
        if (settings.thinking.len != 0) runtime.setThinkingLevel(settings.thinking) catch |err| parked.fail("Restoring chat thinking level", err);
    };
    if (changes.generation) {
        parked.run_started = null;
        parked.run_elapsed = null;
        parked.behavior = .prompt;
        parked.scroll = 0;
    }
    if (changes.error_message) {
        parked.error_text.set(App.clipped(incoming.error_message));
        std.log.err("Background pi: {s}", .{incoming.error_message});
    }
    if (parked.submitted) |submitted| switch (incoming.promptOutcome(submitted.token)) {
        .accepted => {
            parked.submitted = null;
            if (!parked.member) {
                parked.enrollment_intent = true;
                parked.accepted_enrollment = true;
                parked.enrollment_failed = false;
            }
            if (parked.draft_revision == submitted.draft_revision) {
                const cleared = try app.allocator.dupe(u8, parked.draft);
                errdefer app.allocator.free(cleared);
                try replaceParkedDraft(app, parked, "");
                if (parked.cleared_draft) |draft| app.allocator.free(draft);
                parked.cleared_draft = cleared;
                parked.accepted_clear_revision = parked.draft_revision;
            }
        },
        .rejected => parked.submitted = null,
        .pending => if (parked.runtime.?.isFinished()) {
            parked.submitted = null;
        },
    };
    if (changes.recovery and incoming.pending_draft.len != 0 and parked.draft.len == 0 and parked.submitted == null) {
        try replaceParkedDraft(app, parked, incoming.pending_draft);
    }
    if (incoming.session_file.len != 0 and (parked.path == null or !std.mem.eql(u8, parked.path.?, incoming.session_file))) {
        const path = try app.allocator.dupeZ(u8, incoming.session_file);
        if (parked.path) |previous| app.allocator.free(previous);
        parked.path = path;
    }
    if (changes.error_message and incoming.visible_length == 0 and incoming.status == .ready and parked.run_started != null and
        parked.accepted_clear_revision == parked.draft_revision and parked.draft.len == 0)
    {
        if (parked.cleared_draft) |draft| try replaceParkedDraft(app, parked, draft);
    }
    if (parked.run_started) |started| if (incoming.runCompleted(parked.run_base_revision)) {
        parked.run_elapsed = c.SDL_GetTicks() - started;
        parked.run_started = null;
    };
    if (incoming.status == .needs_force_stop and previous_status != .needs_force_stop) app.force_dialog = true;
    if (incoming.status == .ready and (previous_status == .streaming or changes.canonical)) app.catalog_worker.refresh();
    // The recovery revision, not its copied text, is needed for subsequent
    // snapshots. The recovered text now belongs to this chat's draft.
    if (parked.snapshot) |*snapshot| {
        app.allocator.free(snapshot.pending_draft);
        snapshot.pending_draft = "";
    }
    app.dirty = true;
}

pub fn consumeParked(app: *App) void {
    var idle_count: usize = 0;
    // Keep a small most-recent idle pool. Busy chats are never retired for
    // resource pressure; compact drafts outlive an idle child process.
    var index = app.parked_chats.items.len;
    while (index != 0) {
        index -= 1;
        const parked = &app.parked_chats.items[index];
        const runtime = parked.runtime orelse {
            workspace.enrollParked(app, parked);
            continue;
        };
        if (runtime.takeSnapshot()) |snapshot| consumeParkedSnapshot(app, parked, snapshot) catch |err| parked.fail("Updating background chat", err);
        workspace.enrollParked(app, parked);
        if (runtime.isFinished()) {
            parked.submitted = null;
            if (parked.enrollment_intent and !parked.enrollment_failed and app.pending_mutation == null and
                (parked.snapshot == null or parked.snapshot.?.session_file.len == 0))
            {
                parked.enrollment_failed = true;
                parked.fail("Accepted chat has no resumable source path", error.SessionPathUnavailable);
            }
            runtime.destroy() catch |err| {
                parked.fail("Releasing background runtime", err);
                continue;
            };
            parked.runtime = null;
            parked.retiring = false;
            if (parked.snapshot) |*snapshot| snapshot.releaseChoices();
        } else if (!app.closing and !parked.retiring and parked.submitted == null and parked.run_started == null and !parked.enrollment_intent and parked.model_restore == null) {
            if (parked.snapshot) |snapshot| if (snapshot.status == .ready and !snapshot.bash_running and snapshot.queued_count == 0) {
                idle_count += 1;
                if (idle_count > 4) {
                    runtime.shutdown() catch |err| {
                        parked.fail("Retiring idle chat", err);
                        continue;
                    };
                    parked.retiring = true;
                }
            };
        }
    }
}

const Composer = @import("../../text/composer.zig").Composer;

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
        var parked = chat.ParkedChat{
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
            .scroll = 0,
        };
        defer parked.deinit(allocator);
        const snapshot = pi.Snapshot{
            .allocator = allocator,
            .status = .streaming,
            .accepted_command_id = try allocator.dupe(u8, "desktop-11"),
            .role = try allocator.dupe(u8, "assistant"),
            .kind = try allocator.dupe(u8, "message"),
        };
        try consumeParkedSnapshot(&app, &parked, snapshot);
        try std.testing.expect(parked.submitted == null);
        try std.testing.expect(parked.enrollment_intent and parked.accepted_enrollment);
        try std.testing.expectEqualStrings(if (edited_after_send) text else "", parked.draft);
        if (!edited_after_send) {
            try std.testing.expectEqualStrings(text, parked.cleared_draft.?);
            try std.testing.expectEqual(parked.draft_revision, parked.accepted_clear_revision.?);
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
        try consumeParkedSnapshot(&app, &parked, recovery);
        try std.testing.expectEqualStrings(if (edited_after_send) text else "recovered background input", parked.draft);
        try std.testing.expectEqualStrings("active chat draft", app.editor.textBytes());
    }
}
