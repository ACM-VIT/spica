const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const pi = @import("../../core/runtime.zig");
const widgets = @import("../../ui/widgets.zig");
const App = @import("../../app.zig").App;

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

// Called before releasing the old snapshot, so identity comparisons borrow
// its strings and retain only an index into the incoming model list.
pub fn updateModelSearch(app: *App, incoming: []const pi.Model) !void {
    if (app.runtime_snapshot) |old| if (pi.Model.listsEqual(old.models, incoming)) return;
    if (try app.model_picker.replaceModels(modelChoices(app), incoming, query(app))) {
        app.buttons.clear();
        app.pending_hover = null;
    }
}

pub fn toggleModelMenu(app: *App) void {
    if (app.model_picker.open) {
        closeModelMenu(app);
    } else {
        // Mutually exclusive popups share the library's bounded query editor.
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
    app.pending_hover = null;
    app.thinking_menu.open = false;
}

pub fn closeModelMenu(app: *App) void {
    if (!app.model_picker.open) return;
    app.model_picker.open = false;
    app.library.preedit_len = 0;
    app.library.layout_dirty = true;
    app.library.dragging = false;
    app.buttons.clear();
    app.pending_hover = null;
    _ = c.SDL_ClearComposition(app.window);
    app.syncTextInput();
}

pub fn closeAll(app: *App) void {
    closeModelMenu(app);
    app.thinking_menu.open = false;
    app.pending_hover = null;
}

pub fn editModelQuery(app: *App, event: *const c.SDL_Event) !void {
    if (try app.library.handleQuery(app, event)) {
        app.model_picker.restart();
        app.pending_hover = null;
        app.buttons.clear();
    }
}

pub fn hoverMenu(app: *App, x: f32, y: f32) void {
    if (app.closing or app.force_dialog) return;
    if (app.buttons.len == 0) {
        app.pending_hover = .{ x, y };
        app.dirty = true;
        return;
    }
    app.pending_hover = null;
    if (app.model_picker.open) hoverModel(app, x, y) else if (app.thinking_menu.open) hoverThinking(app, x, y);
}

fn hoverThinking(app: *App, x: f32, y: f32) void {
    for (app.buttons.slice()) |hovered| switch (hovered.action) {
        .select_thinking => |index| if (widgets.contains(hovered.bounds, x, y)) {
            if (app.thinking_menu.hover(index)) app.dirty = true;
            return;
        },
        else => {},
    };
}

fn hoverModel(app: *App, x: f32, y: f32) void {
    for (app.buttons.slice()) |hovered| switch (hovered.action) {
        .select_model => |index| if (widgets.contains(hovered.bounds, x, y)) {
            if (app.model_picker.hover(index)) app.dirty = true;
            return;
        },
        else => {},
    };
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
    app.pending_hover = null;
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
    app.pending_hover = null;
}

pub fn handleModelKey(app: *App, event: *const c.SDL_Event) !void {
    if (app.library.preedit_len != 0) return editModelQuery(app, event);
    switch (event.key.key) {
        c.SDLK_ESCAPE => {
            app.focused_editor = true;
            closeModelMenu(app);
            app.dirty = true;
        },
        c.SDLK_UP, c.SDLK_DOWN => {
            try app.model_picker.move(modelChoices(app), query(app), event.key.key == c.SDLK_DOWN);
            app.pending_hover = null;
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
            app.pending_hover = null;
            app.dirty = true;
        },
        c.SDLK_UP, c.SDLK_DOWN => {
            app.thinking_menu.move(thinkingLevels(app), event.key.key == c.SDLK_DOWN);
            app.pending_hover = null;
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
        picker.scrollToHighlight(count, visible);
        const end = @min(count, picker.first + visible);
        for (picker.search.matches[picker.first..end], picker.first..) |match, filtered_index| {
            const model = snapshot.models[match.index];
            const row = c.SDL_FRect{ .x = x + 8, .y = y + 8 + @as(f32, @floatFromInt(filtered_index - picker.first)) * 40, .w = width - 16, .h = 38 };
            if (!picker.selection_cleared and filtered_index == picker.highlight) try app.rectangle(row.x, row.y, row.w, row.h, 5, colors.raised);
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

const Composer = @import("../../text/composer.zig").Composer;
const Library = @import("../library/panel.zig");
const input = @import("../../app/input.zig");
const commands = @import("../../app/commands.zig");

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
    app.model_picker.highlight = 3;
    app.model_picker.visible = 6;
    app.pending_hover = null;
    app.buttons = .{};
    app.buttons.len = 4;
    app.dirty = false;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "OPUS";
    try input.handle(&app, &event);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.first);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.highlight);
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
    try std.testing.expectEqual(@as(usize, 1), app.model_picker.highlight);
    try std.testing.expect(!app.model_picker.search.dirty);
    try std.testing.expectEqual(@as(?usize, 3), try modelIndex(&app, app.model_picker.highlight));
    event.key.key = c.SDLK_UP;
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.highlight);
    try std.testing.expectEqualStrings("keep this message draft", app.editor.textBytes());
    // Rejected input keeps the current results and leaves an error for the popup.
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
    // Exercise Enter through the existing set_model action without starting Pi.
    const p = @import("../../platform/executables.zig").c;
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
    app.model_picker = .{ .open = true, .first = 0, .highlight = 1, .visible = 6 };
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
    app.pending_hover = .{ 20, 60 };
    try updateModelSearch(&app, &reordered);
    app.runtime_snapshot.?.models = @constCast(&reordered);
    try std.testing.expectEqual(@as(usize, 0), app.buttons.len);
    try std.testing.expect(app.pending_hover == null);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.highlight);
    try std.testing.expectEqual(@as(?usize, 0), try selectedModelIndex(&app));
    try std.testing.expectEqualStrings("opus", app.library.queryBytes());
    // Same ID from a different provider must not replace the disappeared choice.
    const removed = [_]pi.Model{original[1]};
    try updateModelSearch(&app, &removed);
    app.runtime_snapshot.?.models = @constCast(&removed);
    try std.testing.expectEqual(@as(usize, 1), try modelCount(&app));
    try std.testing.expect(try selectedModelIndex(&app) == null);
    const restored = [_]pi.Model{ original[1], reordered[0] };
    try updateModelSearch(&app, &restored);
    app.runtime_snapshot.?.models = @constCast(&restored);
    try std.testing.expect(try selectedModelIndex(&app) == null);
    // A deliberate query edit re-enables selection.
    app.pending_hover = .{ 20, 60 };
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = " ";
    try editModelQuery(&app, &event);
    try std.testing.expectEqual(@as(?usize, 0), try selectedModelIndex(&app));
    try std.testing.expect(app.pending_hover == null);
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

test "thinking menu hover moves the shared highlight only when the row changes" {
    var app: App = undefined;
    app.thinking_menu = .{ .open = true };
    app.dirty = false;
    app.buttons = .{};
    try app.buttons.add(.thinking, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try app.buttons.add(.{ .select_thinking = 0 }, .{ .x = 4, .y = 8, .w = 122, .h = 30 });
    try app.buttons.add(.{ .select_thinking = 1 }, .{ .x = 4, .y = 40, .w = 122, .h = 30 });

    hoverThinking(&app, 20, 50);
    try std.testing.expectEqual(@as(usize, 1), app.thinking_menu.highlight);
    try std.testing.expect(app.dirty);

    app.dirty = false;
    hoverThinking(&app, 60, 55);
    try std.testing.expect(!app.dirty);

    hoverThinking(&app, 150, 150);
    try std.testing.expectEqual(@as(usize, 1), app.thinking_menu.highlight);
    try std.testing.expect(!app.dirty);

    hoverThinking(&app, 20, 10);
    try std.testing.expectEqual(@as(usize, 0), app.thinking_menu.highlight);
    try std.testing.expect(app.dirty);
}

test "model menu hover highlights the row under the cursor without scrolling" {
    const allocator = std.testing.allocator;
    var app: App = undefined;
    const models = [_]pi.Model{
        .{ .name = "One", .id = "one", .provider = "local" },
        .{ .name = "Two", .id = "two", .provider = "local" },
        .{ .name = "Three", .id = "three", .provider = "local" },
    };
    app.library = try Library.Panel.init(allocator);
    defer app.library.deinit();
    app.library.resetQuery();
    app.runtime_snapshot = .{ .allocator = allocator, .models = @constCast(&models) };
    app.model_picker = .{ .open = true, .first = 1, .highlight = 1, .visible = 2 };
    try app.model_picker.search.rebuild(&models, "");
    app.thinking_menu = .{};
    app.dirty = false;
    app.buttons = .{};
    try app.buttons.add(.{ .select_model = app.model_picker.search.index(1).? }, .{ .x = 8, .y = 8, .w = 200, .h = 38 });
    try app.buttons.add(.{ .select_model = app.model_picker.search.index(2).? }, .{ .x = 8, .y = 48, .w = 200, .h = 38 });

    hoverModel(&app, 20, 60);
    try std.testing.expectEqual(@as(usize, 2), app.model_picker.highlight);
    try std.testing.expectEqual(@as(usize, 1), app.model_picker.first);
    try std.testing.expect(app.dirty);

    app.dirty = false;
    hoverModel(&app, 100, 70);
    try std.testing.expect(!app.dirty);

    hoverModel(&app, 300, 300);
    try std.testing.expectEqual(@as(usize, 2), app.model_picker.highlight);
    try std.testing.expect(!app.dirty);

    app.closing = true;
    app.force_dialog = false;
    app.pending_hover = null;
    hoverMenu(&app, 20, 20);
    try std.testing.expectEqual(@as(usize, 2), app.model_picker.highlight);
    app.closing = false;
    const drawn = app.buttons;
    app.buttons.clear();
    hoverMenu(&app, 20, 20);
    try std.testing.expect(app.pending_hover != null);
    try std.testing.expectEqual(@as(usize, 2), app.model_picker.highlight);
    app.buttons = drawn;
    hoverMenu(&app, app.pending_hover.?[0], app.pending_hover.?[1]);
    try std.testing.expect(app.pending_hover == null);
    try std.testing.expectEqual(@as(usize, 1), app.model_picker.highlight);
    app.buttons.clear();
    hoverMenu(&app, 20, 60);
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_UP;
    app.library.preedit_len = 0;
    try handleModelKey(&app, &event);
    try std.testing.expect(app.pending_hover == null);
    try std.testing.expectEqual(@as(usize, 0), app.model_picker.highlight);
    try std.testing.expectEqual(@as(usize, 1), app.model_picker.first);
    app.model_picker.first = 1;
    app.model_picker.highlight = 2;
    app.buttons = drawn;

    app.model_picker.selection_cleared = true;
    hoverModel(&app, 20, 60);
    try std.testing.expect(!app.model_picker.selection_cleared);
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

    const p = @import("../../platform/executables.zig").c;
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
    // Escape closes without choosing and leaves the draft and its selection alone.
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_ESCAPE;
    try input.handle(&app, &event);
    try std.testing.expect(!app.thinking_menu.open);
    try std.testing.expectEqual(@as(usize, 0), runtime.inputs.items.len);
    try std.testing.expectEqualStrings("unfinished draft", app.editor.textBytes());
    try std.testing.expectEqual(draft_selection, app.editor.selection());
    // Enter sends the highlighted level and closes the menu.
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
    // Repeats of that held Enter reach the focused editor but must not submit.
    event.key.repeat = true;
    try input.handle(&app, &event);
    event.key.mod = c.SDL_KMOD_CTRL;
    try input.handle(&app, &event);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
    try std.testing.expectEqualStrings("unfinished draft", app.editor.textBytes());
    event.key.repeat = false;
    event.key.mod = 0;
    // An empty level list leaves nothing to choose.
    app.thinking_menu.open = true;
    app.runtime_snapshot.?.thinking_levels = &.{};
    try input.handle(&app, &event);
    try std.testing.expect(app.thinking_menu.open);
    try std.testing.expectEqual(@as(usize, 1), runtime.inputs.items.len);
}
