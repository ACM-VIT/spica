const c = @import("../native/bindings.zig").c;
const Settings = @import("../features/settings/settings.zig");
const app_module = @import("../app.zig");
const App = app_module.App;
const Action = app_module.Action;
const chat = @import("../features/chat/chat.zig");
const processes = @import("../features/chat/processes.zig");
const workspace = @import("../features/library/workspace.zig");
const conversation = @import("../features/transcript/conversation.zig");
const menus = @import("../features/models/menus.zig");

pub fn act(app: *App, action: Action) !void {
    switch (action) {
        .start => try processes.beginRuntime(app),
        .new_thread => try chat.newThreadIn(app, app.project_path),
        .open_parked => |index| try chat.openParked(app, index),
        .new_project_thread => |index| {
            if (index < app.projects.items.len) try chat.newThreadIn(app, app.projects.items[index]);
        },
        .new_catalog_thread => |index| {
            if (app.catalog) |catalog| if (index < catalog.folders.len) try chat.newThreadIn(app, catalog.folders[index].cwd);
        },
        .toggle_folder => |index| {
            if (app.catalog) |catalog| if (index < catalog.folders.len) try workspace.toggleFolder(app, catalog.folders[index].cwd);
        },
        .toggle_project_folder => |index| {
            if (index < app.projects.items.len) try workspace.toggleFolder(app, app.projects.items[index]);
        },
        .toggle_current_folder => try workspace.toggleFolder(app, app.project_path),
        .open_library => |scope| try workspace.showLibrary(app, scope),
        .library => |choice| if (app.library.act(choice)) |intent| try workspace.libraryIntent(app, intent),
        .archive_thread => |index| {
            if (app.catalog) |catalog| if (index < catalog.threads.len) {
                const thread = catalog.threads[index];
                try workspace.queueMutation(app, .archive, thread.path, thread.cwd, thread.title, false, false);
            };
        },
        .restore_current => try workspace.queueMutation(app, .restore, chat.currentSession(app), app.project_path, app.title(), false, false),
        .add_project => workspace.chooseFolder(app),
        .settings => toggleSettings(app),
        .appearance => |choice| {
            // Queued clicks and zoom shortcuts can outlive the last drawn hit targets.
            if (!Settings.actionEnabled(app.appearance, choice)) return;
            applyAppearance(app, choice);
        },
        .sidebar => app.sidebar_visible = !app.sidebar_visible,
        .open_thread => |index| try chat.openThread(app, index),
        .send => try chat.submit(app),
        .stop => if (app.runtime) |runtime| {
            try runtime.stop();
        },
        .theme => toggleTheme(app),
        .behavior => app.behavior = if (app.behavior == .steer) .follow_up else .steer,
        .latest => conversation.requestLatest(app),
        .models => menus.toggleModelMenu(app),
        .select_model => |index| try menus.selectModel(app, index),
        .thinking => menus.toggleThinkingMenu(app),
        .select_thinking => |index| try menus.selectThinking(app, index),
        .disclosure => |target| {
            app.transcript.toggle(target);
            app.follow_bottom = false;
        },
        .force_stop => {
            try processes.forceOwned(app);
            app.force_dialog = false;
        },
        .wait => app.force_dialog = false,
    }
    app.dirty = true;
}

fn toggleSettings(app: *App) void {
    app.settings_open = !app.settings_open;
    menus.closeAll(app);
    app.focused_editor = !app.settings_open;
    if (app.settings_open) _ = c.SDL_StopTextInput(app.window) else _ = c.SDL_StartTextInput(app.window);
}

fn applyAppearance(app: *App, choice: Settings.Action) void {
    if (choice == .close) {
        app.settings_open = false;
        app.focused_editor = true;
        _ = c.SDL_StartTextInput(app.window);
        return;
    }
    Settings.apply(&app.appearance, choice);
    app.light = app.appearance.light;
    app.theme.metrics = Settings.metrics(app.base_metrics, app.appearance);
    app.transcript.invalidateLayouts();
    app.editor_view.changed = true;
    workspace.scheduleSave(app);
}

pub fn toggleTheme(app: *App) void {
    app.light = !app.light;
    app.appearance.light = app.light;
    workspace.scheduleSave(app);
}

const std = @import("std");
const Clay = @import("../ui/clay.zig").Layout;
const theme_module = @import("../ui/theme.zig");
const Library = @import("../features/library/panel.zig");
const TranscriptView = @import("../features/transcript/view.zig").View;
const input = @import("input.zig");

test "appearance limits omit targets and ignore queued clicks without invalidating or saving" {
    const allocator = std.testing.allocator;
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const surface = c.SDL_CreateSurface(640, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/theme.json", allocator, .limited(16384));
    defer allocator.free(theme_bytes);
    var app: App = undefined;
    app.renderer = renderer;
    app.text = text;
    app.theme = try theme_module.parse(allocator, theme_bytes);
    app.base_metrics = app.theme.metrics;
    app.labels = .{};
    defer app.labels.deinit();
    app.shell = std.mem.zeroes(Clay.Shell);
    app.shell.conversation.width = 640;
    app.shell.conversation.height = 480;
    app.wake_event = 0;
    app.closing = false;
    app.force_dialog = false;
    app.settings_open = true;
    app.model_picker = .{};
    app.thinking_menu = .{};
    app.buttons = .{};
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    app.transcript = TranscriptView.init(allocator);
    defer app.transcript.deinit();
    const markdown = @import("../content/markdown.zig");
    const body = "Retain this cached layout when an exhausted button is clicked.";
    const content_id: @import("../core/store.zig").ContentId = @splat(1);
    try app.transcript.update(&.{.{ .ordinal = 0, .role = .assistant, .content_id = content_id, .length = body.len }});
    try app.transcript.accept(renderer, .{ .generation = 1, .ordinal = 0, .document = try markdown.parse(allocator, content_id, body) });
    const loaded = app.transcript.items.items[0].loaded.?;
    try loaded.view.rebuild(&loaded.ready.document, 608);

    const Target = @TypeOf(app.buttons).Target;
    const Check = struct {
        fn targets(buttons: []const Target, disabled: ?Settings.Action) !void {
            for ([_]Settings.Action{ .font_smaller, .font_larger, .scale_smaller, .scale_larger, .width_smaller, .width_larger }) |action| {
                var found = false;
                for (buttons) |target| {
                    if (target.action == .appearance and target.action.appearance == action) found = true;
                }
                try std.testing.expectEqual(disabled == null or action != disabled.?, found);
            }
        }
    };
    const cases = [_]struct { values: Settings.Values, exhausted: Settings.Action, reverse: Settings.Action }{
        .{ .values = .{ .font_size = 12 }, .exhausted = .font_smaller, .reverse = .font_larger },
        .{ .values = .{ .font_size = 24 }, .exhausted = .font_larger, .reverse = .font_smaller },
        .{ .values = .{ .ui_scale = 75 }, .exhausted = .scale_smaller, .reverse = .scale_larger },
        .{ .values = .{ .ui_scale = 175 }, .exhausted = .scale_larger, .reverse = .scale_smaller },
        .{ .values = .{ .chat_width = 560 }, .exhausted = .width_smaller, .reverse = .width_larger },
        .{ .values = .{ .chat_width = 1120 }, .exhausted = .width_larger, .reverse = .width_smaller },
    };
    for ([_]bool{ false, true }) |light| for (cases) |case| {
        var boundary = case.values;
        boundary.light = light;
        app.appearance = boundary;
        app.light = light;
        app.buttons.clear();
        try Settings.draw(&app);
        try Check.targets(app.buttons.slice(), case.exhausted);

        // Move back into range: both directions become clickable again.
        try act(&app, .{ .appearance = case.reverse });
        try std.testing.expect(!std.meta.eql(boundary, app.appearance));
        try std.testing.expectEqual(@as(f32, 0), loaded.view.width);
        try std.testing.expect(app.dirty and app.editor_view.changed and app.draft_due != null);
        app.buttons.clear();
        try Settings.draw(&app);
        try Check.targets(app.buttons.slice(), null);
        var stale: ?Target = null;
        for (app.buttons.slice()) |target| {
            if (target.action == .appearance and target.action.appearance == case.exhausted) stale = target;
        }
        const bounds = (stale orelse return error.MissingAdjustmentTarget).bounds;
        try act(&app, .{ .appearance = case.exhausted });
        try std.testing.expectEqualDeep(boundary, app.appearance);

        // The event queue can still contain clicks on the previously enabled target.
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = c.SDL_BUTTON_LEFT;
        event.button.x = bounds.x + bounds.w / 2;
        event.button.y = bounds.y + bounds.h / 2;
        for ([_]?u64{ null, 123 }) |pending_save| {
            app.dirty = false;
            app.editor_view.changed = false;
            app.draft_due = pending_save;
            loaded.view.width = 608;
            for (0..3) |_| try input.handle(&app, &event);
            try std.testing.expectEqualDeep(boundary, app.appearance);
            try std.testing.expectEqual(pending_save, app.draft_due);
            try std.testing.expect(!app.dirty and !app.editor_view.changed);
            try std.testing.expectEqual(@as(f32, 608), loaded.view.width);
        }

        // Redrawing removes the exhausted target; clicking its visible outline is inert.
        app.buttons.clear();
        try Settings.draw(&app);
        try Check.targets(app.buttons.slice(), case.exhausted);
        try input.handle(&app, &event);
        try std.testing.expectEqualDeep(boundary, app.appearance);
        try std.testing.expectEqual(@as(?u64, 123), app.draft_due);
        try std.testing.expect(!app.dirty and !app.editor_view.changed);
        try std.testing.expectEqual(@as(f32, 608), loaded.view.width);

        try act(&app, .{ .appearance = .reset });
        try std.testing.expectEqualDeep(Settings.Values{}, app.appearance);
        app.buttons.clear();
        try Settings.draw(&app);
        try Check.targets(app.buttons.slice(), null);
    };
}
