const std = @import("std");
const c = @import("../native/bindings.zig").c;
const pi = @import("../core/runtime.zig");
const widgets = @import("../ui/widgets.zig");
const App = @import("../app.zig").App;

pub fn modelChoices(app: *const App) []const pi.Model {
    return if (app.runtime_snapshot) |snapshot| snapshot.models else &.{};
}

pub fn thinkingLevels(app: *const App) []const []const u8 {
    return if (app.runtime_snapshot) |snapshot| snapshot.thinking_levels else &.{};
}

fn query(app: *const App) []const u8 {
    return app.library.queryBytes();
}

pub fn modelCount(app: *App) !usize {
    return app.model_picker.count(modelChoices(app), query(app));
}

pub fn modelIndex(app: *App, ranked_index: usize) !?usize {
    return app.model_picker.index(modelChoices(app), query(app), ranked_index);
}

pub fn selectedModelIndex(app: *App) !?usize {
    return app.model_picker.selected(modelChoices(app), query(app));
}

pub fn updateModelSearch(app: *App, incoming: []const pi.Model) !void {
    if (app.runtime_snapshot) |old| if (pi.Model.listsEqual(old.models, incoming)) return;
    if (try app.model_picker.replaceModels(modelChoices(app), incoming, query(app))) app.buttons.clear();
}

pub fn toggleModelMenu(app: *App) void {
    if (app.model_picker.open) {
        closeModelMenu(app);
    } else {
        app.library.resetQuery();
        app.model_picker.restart();
        app.model_picker.open = true;
        app.dragging = false;
        app.preedit.clearRetainingCapacity();
        app.editor_view.changed = true;
        _ = c.SDL_ClearComposition(app.window);
        _ = c.SDL_StartTextInput(app.window);
    }
    app.buttons.clear();
    app.thinking_menu.open = false;
}

pub fn closeModelMenu(app: *App) void {
    if (!app.model_picker.open) return;
    app.model_picker.open = false;
    app.library.preedit_len = 0;
    app.library.layout_dirty = true;
    app.library.dragging = false;
    app.buttons.clear();
    _ = c.SDL_ClearComposition(app.window);
    app.syncTextInput();
}

pub fn closeAll(app: *App) void {
    closeModelMenu(app);
    app.thinking_menu.open = false;
}

pub fn editModelQuery(app: *App, event: *const c.SDL_Event) !void {
    if (try app.library.handleQuery(app, event)) {
        app.model_picker.restart();
        app.buttons.clear();
    }
}

pub fn selectModel(app: *App, index: usize) !void {
    if (app.runtime_retiring) return error.PiNotReady;
    const snapshot = app.runtime_snapshot orelse return error.PiNotReady;
    if (index >= snapshot.models.len) return error.StaleModelChoice;
    const model = snapshot.models[index];
    try (app.runtime orelse return error.PiNotReady).setModel(model.provider, model.id);
    closeModelMenu(app);
}

pub fn toggleThinkingMenu(app: *App) void {
    app.thinking_menu.open = !app.thinking_menu.open;
    if (app.thinking_menu.open) {
        const current = if (app.runtime_snapshot) |snapshot| snapshot.thinking_level else "";
        app.thinking_menu.highlightCurrent(thinkingLevels(app), current);
    }
    closeModelMenu(app);
}

pub fn selectThinking(app: *App, index: usize) !void {
    if (app.runtime_retiring) return error.PiNotReady;
    const snapshot = app.runtime_snapshot orelse return error.PiNotReady;
    if (index >= snapshot.thinking_levels.len) return error.StaleThinkingChoice;
    try (app.runtime orelse return error.PiNotReady).setThinkingLevel(snapshot.thinking_levels[index]);
    app.thinking_menu.open = false;
}

pub fn handleModelKey(app: *App, event: *const c.SDL_Event) !void {
    if (app.library.preedit_len != 0) return editModelQuery(app, event);
    switch (event.key.key) {
        c.SDLK_ESCAPE => {
            app.focused_editor = true;
            closeModelMenu(app);
            app.dirty = true;
        },
        c.SDLK_UP => {
            app.model_picker.previous();
            app.buttons.clear();
            app.dirty = true;
            try editModelQuery(app, event);
        },
        c.SDLK_DOWN => {
            try app.model_picker.next(modelChoices(app), query(app));
            app.buttons.clear();
            app.dirty = true;
            try editModelQuery(app, event);
        },
        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (try selectedModelIndex(app)) |index| {
            try selectModel(app, index);
            app.dirty = true;
        },
        else => try editModelQuery(app, event),
    }
}

pub fn handleThinkingKey(app: *App, event: *const c.SDL_Event) !void {
    switch (event.key.key) {
        c.SDLK_ESCAPE => {
            app.thinking_menu.open = false;
            app.dirty = true;
        },
        c.SDLK_UP, c.SDLK_DOWN => {
            app.thinking_menu.move(thinkingLevels(app), event.key.key == c.SDLK_DOWN);
            app.dirty = true;
        },
        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (app.thinking_menu.selected(thinkingLevels(app))) |index| {
            try selectThinking(app, index);
            app.dirty = true;
        },
        else => {},
    }
}

pub fn handleModelPointer(app: *App, event: *const c.SDL_Event) !bool {
    if (widgets.contains(app.library.query_bounds, event.button.x, event.button.y)) {
        if (event.button.button == c.SDL_BUTTON_LEFT) {
            try app.library.hitQuery(app, event.button.x, event.button.y, (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
            app.library.dragging = true;
            app.dirty = true;
        }
        return true;
    }
    if (!widgets.contains(app.model_picker.popup_bounds, event.button.x, event.button.y)) return false;
    if (event.button.button == c.SDL_BUTTON_LEFT) {
        for (app.buttons.slice()) |pressed| {
            if (pressed.action == .select_model and widgets.contains(pressed.bounds, event.button.x, event.button.y)) {
                try selectModel(app, pressed.action.select_model);
                app.dirty = true;
                return true;
            }
        }
    }
    return true;
}

pub fn drawModelMenu(app: *App) !void {
    const colors = app.palette();
    const picker = &app.model_picker;
    const composer = app.composer_bounds;
    const x = app.model_bounds.x;
    const width: f32 = @min(360, composer.w - 16);
    const error_height: f32 = if (app.library.input_err != null) 20 else 0;
    const visible: usize = @intFromFloat(@max(1, @min(6, @floor((composer.y - 66 - error_height) / 40))));
    const height = @as(f32, @floatFromInt(visible)) * 40 + 56 + error_height;
    const y = composer.y - height - 10;
    picker.popup_bounds = .{ .x = x, .y = y, .w = width, .h = height };
    try app.rectangle(x, y, width, height, 8, colors.border);
    try app.rectangle(x + 1, y + 1, width - 2, height - 2, 7, colors.panel);
    if (app.runtime_snapshot) |snapshot| {
        const count = try modelCount(app);
        if (count == 0) try app.label(if (snapshot.models.len == 0) "No configured models" else "No matching models", x + 12, y + 16, 13, colors.muted);
        picker.first = @min(picker.first, count -| 1);
        const end = @min(count, picker.first + visible);
        for (picker.search.matches[picker.first..end], picker.first..) |match, filtered_index| {
            const model = snapshot.models[match.index];
            const row = c.SDL_FRect{ .x = x + 8, .y = y + 8 + @as(f32, @floatFromInt(filtered_index - picker.first)) * 40, .w = width - 16, .h = 38 };
            if (!picker.selection_cleared and filtered_index == picker.first) try app.rectangle(row.x, row.y, row.w, row.h, 5, colors.raised);
            var clip = widgets.Clip.push(app.renderer, row);
            defer clip.restore(app.renderer);
            try app.hit(.{ .select_model = match.index }, row);
            try app.label(App.clipped(model.name), x + 12, row.y + 3, 13, colors.text);
            try app.label(App.clipped(model.provider), x + 12, row.y + 23, 10, colors.muted);
        }
    } else try app.label("Start pi to discover models", x + 12, y + 16, 13, colors.muted);
    const query_y = y + height - 42 - error_height;
    try app.rectangle(x + 8, query_y - 5, width - 16, 1, 0, colors.border);
    app.library.query_bounds = .{ .x = x + 8, .y = query_y, .w = width - 16, .h = 34 };
    try app.rectangle(x + 8, query_y, width - 16, 34, 5, colors.raised);
    try app.library.drawQuery(app, "Search models...");
    if (app.library.input_err) |err| {
        var buffer: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "Error: {s}", .{@errorName(err)});
        try app.fitLabel(message, x + 12, query_y + 36, width - 24, 12, colors.error_color);
    }
}

pub fn drawThinkingMenu(app: *App) !void {
    const snapshot = app.runtime_snapshot orelse return;
    const colors = app.palette();
    const height = @as(f32, @floatFromInt(snapshot.thinking_levels.len)) * 32 + 16;
    const x = app.thinking_bounds.x;
    const y = app.composer_bounds.y - height - 10;
    try app.rectangle(x, y, 130, height, 8, colors.border);
    try app.rectangle(x + 1, y + 1, 128, height - 2, 7, colors.panel);
    const highlight = app.thinking_menu.selected(snapshot.thinking_levels);
    for (snapshot.thinking_levels, 0..) |level, index| {
        const row = c.SDL_FRect{ .x = x + 4, .y = y + 8 + @as(f32, @floatFromInt(index)) * 32, .w = 122, .h = 30 };
        if (highlight == index) try app.rectangle(row.x, row.y, row.w, row.h, 5, colors.raised);
        try app.flatButton(.{ .select_thinking = index }, level, row);
    }
}

const Composer = @import("../text/composer.zig").Composer;
const Library = @import("../ui/library.zig");
const input = @import("input.zig");
const commands = @import("commands.zig");

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
    app.thinking_menu = .{};
    app.focused_editor = false;
    app.options = .{};
    app.model_picker = .{ .open = true };
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
    app.model_picker.first = 3;
    app.buttons = .{};
    app.buttons.len = 4;
    app.dirty = false;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "OPUS";
    try input.handle(&app, &event);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.first);
    try std.testing.expectEqual(@as(usize, 0), app.buttons.len);
    try std.testing.expectEqual(@as(usize, 2), try modelCount(&app));
    try std.testing.expectEqual(@as(?usize, 1), try modelIndex(&app, 0));
    try std.testing.expectEqual(@as(?usize, 3), try modelIndex(&app, 1));
    try std.testing.expect(try modelIndex(&app, 2) == null);

    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_A;
    event.key.mod = c.SDL_KMOD_GUI;
    try input.handle(&app, &event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "ANTHROPIC haiku-4";
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 1), try modelCount(&app));
    try std.testing.expectEqual(@as(?usize, 2), try modelIndex(&app, 0));

    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_A;
    event.key.mod = c.SDL_KMOD_CTRL;
    try input.handle(&app, &event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "missing model";
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 0), try modelCount(&app));
    try std.testing.expect(try modelIndex(&app, 0) == null);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RETURN;
    try input.handle(&app, &event);
    try std.testing.expect(app.model_picker.open);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_Z;
    event.key.mod = c.SDL_KMOD_CTRL;
    try input.handle(&app, &event);
    try std.testing.expectEqualStrings("ANTHROPIC haiku-4", app.library.queryBytes());
    event.key.key = c.SDLK_BACKSPACE;
    event.key.mod = 0;
    try input.handle(&app, &event);
    try std.testing.expectEqualStrings("", app.library.queryBytes());
    try std.testing.expectEqual(@as(usize, 4), try modelCount(&app));
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "opsu";
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 2), try modelCount(&app));
    try std.testing.expectEqual(@as(?usize, 1), try modelIndex(&app, 0));
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DOWN;
    event.key.mod = 0;
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 1), app.model_picker.first);
    try std.testing.expect(!app.model_picker.search.dirty);
    try std.testing.expectEqual(@as(?usize, 3), try modelIndex(&app, app.model_picker.first));
    event.key.key = c.SDLK_UP;
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.first);
    try std.testing.expectEqualStrings("keep this message draft", app.editor.textBytes());
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "x" ** 257;
    try input.handle(&app, &event);
    try std.testing.expectEqual(error.QueryTooLarge, app.library.input_err.?);
    try std.testing.expectEqualStrings("opsu", app.library.queryBytes());
    try std.testing.expectEqual(@as(usize, 2), try modelCount(&app));
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_BACKSPACE;
    event.key.mod = 0;
    try input.handle(&app, &event);
    try std.testing.expect(app.library.input_err == null);
    const p = @import("../platform/executables.zig").c;
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
        for (runtime.inputs.items) |queued| if (queued == .bytes) allocator.free(queued.bytes.data);
        runtime.inputs.deinit(allocator);
    }
    app.runtime = &runtime;
    app.runtime_retiring = false;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DOWN;
    try input.handle(&app, &event);
    event.key.key = c.SDLK_RETURN;
    try input.handle(&app, &event);
    try std.testing.expect(!app.model_picker.open);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    const command = try std.json.parseFromSlice(std.json.Value, allocator, runtime.inputs.items[0].bytes.data, .{});
    defer command.deinit();
    try std.testing.expectEqualStrings("set_model", command.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("anthropic", command.value.object.get("provider").?.string);
    try std.testing.expectEqualStrings("claude-opus-4-6", command.value.object.get("modelId").?.string);

    app.model_picker.open = true;
    const remaining = [_]pi.Model{models[1]};
    try updateModelSearch(&app, &remaining);
    app.runtime_snapshot.?.models = @constCast(&remaining);
    try std.testing.expectEqual(@as(usize, 1), try modelCount(&app));
    try input.handle(&app, &event);
    try std.testing.expect(app.model_picker.open);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    event.key.key = c.SDLK_DOWN;
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(?usize, 0), try selectedModelIndex(&app));
    event.key.key = c.SDLK_RETURN;
    try input.handle(&app, &event);
    try std.testing.expect(!app.model_picker.open);
    try std.testing.expectEqual(@as(usize, 2), runtime.inputs.items.len);

    app.model_picker.open = true;
    app.runtime_snapshot.?.models = &.{};
    app.model_picker.search.invalidate();
    try input.handle(&app, &event);
    try std.testing.expect(app.model_picker.open);
    try std.testing.expectEqual(@as(usize, 2), runtime.inputs.items.len);

    app.focused_editor = false;
    app.editor.setCaret(9, true);
    const draft_selection = app.editor.selection();
    event.key.key = c.SDLK_ESCAPE;
    try input.handle(&app, &event);
    try std.testing.expect(!app.model_picker.open);
    try std.testing.expect(app.focused_editor);
    try std.testing.expect(c.SDL_TextInputActive(app.window));
    try std.testing.expectEqualStrings("keep this message draft", app.editor.textBytes());
    try std.testing.expectEqual(draft_selection, app.editor.selection());
}

test "model picker snapshot refresh preserves identity and clears disappeared selections" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    app.model_picker = .{ .open = true, .first = 1 };
    app.buttons = .{};
    app.buttons.len = 2;
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
    try std.testing.expectEqual(@as(?usize, 2), try selectedModelIndex(&app));

    const reordered = [_]pi.Model{
        .{ .name = "Opus renamed", .id = "shared-id", .provider = "two" },
        original[0],
        original[1],
    };
    try updateModelSearch(&app, &reordered);
    app.runtime_snapshot.?.models = @constCast(&reordered);
    try std.testing.expectEqual(@as(usize, 0), app.buttons.len);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.first);
    try std.testing.expectEqual(@as(?usize, 0), try selectedModelIndex(&app));
    try std.testing.expectEqualStrings("opus", app.library.queryBytes());
    const removed = [_]pi.Model{original[1]};
    try updateModelSearch(&app, &removed);
    app.runtime_snapshot.?.models = @constCast(&removed);
    try std.testing.expectEqual(@as(usize, 1), try modelCount(&app));
    try std.testing.expect(try selectedModelIndex(&app) == null);
    const restored = [_]pi.Model{ original[1], reordered[0] };
    try updateModelSearch(&app, &restored);
    app.runtime_snapshot.?.models = @constCast(&restored);
    try std.testing.expect(try selectedModelIndex(&app) == null);
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = " ";
    try editModelQuery(&app, &event);
    try std.testing.expectEqual(@as(?usize, 0), try selectedModelIndex(&app));
    const renamed = [_]pi.Model{
        .{ .name = "Different", .id = "shared-id", .provider = "one" },
        reordered[0],
    };
    try updateModelSearch(&app, &renamed);
    app.runtime_snapshot.?.models = @constCast(&renamed);
    try std.testing.expectEqual(@as(usize, 1), try modelCount(&app));
    try std.testing.expect(try selectedModelIndex(&app) == null);
    try updateModelSearch(&app, &.{});
    app.runtime_snapshot.?.models = &.{};
    try std.testing.expectEqual(@as(usize, 0), try modelCount(&app));
    try std.testing.expect(try selectedModelIndex(&app) == null);
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
    app.model_picker = .{};
    app.thinking_menu = .{ .open = true };
    app.buttons = .{};
    app.focused_editor = true;
    app.options = .{};
    app.preedit = .empty;
    app.editor_view = .{};
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    app.editor = try Composer.init(allocator);
    defer app.editor.deinit();
    try app.editor.setText("unfinished draft");
    app.editor.setCaret(3, true);
    const draft_selection = app.editor.selection();
    var levels = [_][]const u8{ "off", "low", "medium", "high" };
    app.runtime_snapshot = .{ .allocator = allocator, .thinking_levels = &levels, .thinking_level = "low" };
    app.thinking_menu.highlightCurrent(&levels, "low");

    const p = @import("../platform/executables.zig").c;
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
        for (runtime.inputs.items) |queued| if (queued == .bytes) allocator.free(queued.bytes.data);
        runtime.inputs.deinit(allocator);
    }
    app.runtime = &runtime;
    app.runtime_retiring = false;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_ESCAPE;
    try input.handle(&app, &event);
    try std.testing.expect(!app.thinking_menu.open);
    try std.testing.expectEqual(@as(usize, 0), runtime.inputs.items.len);
    try std.testing.expectEqualStrings("unfinished draft", app.editor.textBytes());
    try std.testing.expectEqual(draft_selection, app.editor.selection());
    try commands.act(&app, .thinking);
    try std.testing.expectEqual(@as(?usize, 1), app.thinking_menu.selected(thinkingLevels(&app)));
    event.key.key = c.SDLK_DOWN;
    try input.handle(&app, &event);
    event.key.key = c.SDLK_RETURN;
    try input.handle(&app, &event);
    try std.testing.expect(!app.thinking_menu.open);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    const command = try std.json.parseFromSlice(std.json.Value, allocator, runtime.inputs.items[0].bytes.data, .{});
    defer command.deinit();
    try std.testing.expectEqualStrings("set_thinking_level", command.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("medium", command.value.object.get("level").?.string);
    event.key.repeat = true;
    try input.handle(&app, &event);
    event.key.mod = c.SDL_KMOD_CTRL;
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    try std.testing.expectEqualStrings("unfinished draft", app.editor.textBytes());
    event.key.repeat = false;
    event.key.mod = 0;
    app.thinking_menu.open = true;
    app.runtime_snapshot.?.thinking_levels = &.{};
    try input.handle(&app, &event);
    try std.testing.expect(app.thinking_menu.open);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
}
