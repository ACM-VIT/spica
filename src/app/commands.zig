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
        .appearance => |choice| applyAppearance(app, choice),
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
