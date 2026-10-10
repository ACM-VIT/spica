const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const fixture = @import("../../diagnostics/fixture.zig");
const store = @import("../../core/store.zig");
const ContentWorker = @import("../../content/worker.zig");
const App = @import("../../app.zig").App;

pub fn pump(app: *App) !void {
    if (app.content_pending or app.minimized) return;
    if (app.chat_view == .opening) {
        if (app.pending_thread != null) return;
        const snapshot = app.runtime_snapshot orelse return;
        if (snapshot.visible_revision == 0) return;
    }
    if (app.last_content_metadata) {
        if (try requestVisible(app)) return;
    }
    if (app.conversation_dirty) {
        const session_file = if (app.options.fixture) fixture.session_file else if (app.runtime_snapshot) |snapshot| snapshot.session_file else return;
        if (session_file.len == 0) return;
        app.generation += 1;
        try app.content.request(.{
            .generation = app.generation,
            .conversation = true,
            .session_file = session_file,
            .runtime_id = if (app.runtime_snapshot) |snapshot| snapshot.runtime_id else 0,
            .run_generation = if (app.runtime_snapshot) |snapshot| snapshot.generation else 0,
        });
        app.conversation_dirty = false;
        app.content_pending = true;
        app.pending_ordinal = null;
        app.last_content_metadata = true;
    } else _ = try requestVisible(app);
}

fn requestVisible(app: *App) !bool {
    const request = app.transcript.request(app.generation + 1) orelse return false;
    app.generation += 1;
    try app.content.request(request);
    app.content_pending = true;
    app.pending_ordinal = request.ordinal;
    app.last_content_metadata = false;
    return true;
}

pub fn consume(app: *App) void {
    var result = app.content.take() orelse return;
    const generation = switch (result) {
        .ready => |value| value.generation,
        .conversation => |value| value.generation,
        .failure => |value| value.generation orelse app.generation,
    };
    if (generation != app.generation) {
        result.deinit();
        return;
    }
    app.content_pending = false;
    switch (result) {
        .failure => |failure| {
            if (app.pending_ordinal) |ordinal| app.transcript.fail(ordinal);
            app.report("Loading conversation", failure.err);
        },
        .conversation => |*value| {
            attachLiveReasoning(app, value);
            app.transcript.update(value.entries) catch |err| app.report("Updating conversation", err);
            if (app.pending_thread == null) if (app.runtime_snapshot) |snapshot| {
                if (app.chat_view == .opening and snapshot.visible_revision != 0 and
                    std.mem.eql(u8, snapshot.session_file, app.options.resume_file orelse ""))
                    app.chat_view = .existing;
                if (app.chat_view == .new_thread and value.entries.len != 0) app.chat_view = .existing;
            };
            value.deinit();
        },
        .ready => |ready| app.transcript.accept(app.renderer, ready) catch |err| app.report("Rendering message", err),
    }
    app.dirty = true;
}

fn attachLiveReasoning(app: *const App, value: *ContentWorker.Conversation) void {
    const snapshot = app.runtime_snapshot orelse return;
    const id = snapshot.thinking_content_ref orelse return;
    var index = value.entries.len;
    while (index > 0) {
        index -= 1;
        if (value.entries[index].role == .assistant and value.entries[index].ordinal >= store.live_ordinal_base) {
            value.entries[index].reasoning = .{ .content_ref = id, .length = snapshot.thinking_length };
            return;
        }
    }
}

pub fn requestLatest(app: *App) void {
    app.follow_bottom = true;
    app.requestConversation();
}

pub fn scrollBy(app: *App, delta: f32, follow_at_end: bool) void {
    app.follow_bottom = false;
    app.transcript.draw_width = 0;
    app.scroll = @max(0, app.scroll + delta);
    if (follow_at_end and app.scroll >= maxScroll(app)) app.follow_bottom = true;
}

pub fn scrollToEdge(app: *App, bottom: bool) void {
    app.transcript.draw_width = 0;
    app.follow_bottom = bottom;
    app.scroll = if (bottom) maxScroll(app) else 0;
}

fn maxScroll(app: *const App) f32 {
    return @max(0, app.transcript.height - app.transcript.viewport_height);
}

pub fn copyResponse(app: *App, ordinal: usize) !void {
    var success = false;
    defer {
        app.transcript.copied(ordinal, success, c.SDL_GetTicks());
        app.dirty = true;
    }
    const bytes = try app.transcript.copyText(ordinal);
    defer app.allocator.free(bytes);
    if (!c.SDL_SetClipboardText(bytes.ptr)) return error.ClipboardWrite;
    success = true;
}
