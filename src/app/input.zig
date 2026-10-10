const std = @import("std");
const c = @import("../native/bindings.zig").c;
const widgets = @import("../ui/widgets.zig");
const clipboard = @import("../ui/clipboard.zig");
const App = @import("../app.zig").App;
const commands = @import("commands.zig");
const chat = @import("../features/chat/chat.zig");
const processes = @import("../features/chat/processes.zig");
const workspace = @import("../features/library/workspace.zig");
const conversation = @import("../features/transcript/conversation.zig");
const sidebar = @import("../features/library/sidebar.zig");
const menus = @import("../features/models/menus.zig");

const act = commands.act;

pub fn handle(app: *App, incoming: *const c.SDL_Event) !void {
    var logical = incoming.*;
    if (!c.SDL_ConvertEventToRenderCoordinates(app.renderer, &logical)) return error.InputCoordinates;
    const event = &logical;
    if (event.type == app.wake_event) {
        try workspace.folderChoice(app, event);
        app.consume();
        return;
    }
    const modal = app.closing or app.force_dialog;
    if (event.type == c.SDL_EVENT_KEY_DOWN and !modal and try globalShortcut(app, event)) return;
    if (app.library.open and !modal) switch (event.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING, c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_MOTION, c.SDL_EVENT_MOUSE_WHEEL, c.SDL_EVENT_WINDOW_FOCUS_LOST => {
            if (try app.library.handle(app, event)) |intent| workspace.libraryIntent(app, intent) catch |err| {
                app.library.fail(err);
                app.report("Chat library action", err);
            };
            return;
        },
        else => {},
    };
    switch (event.type) {
        c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => try processes.requestClose(app),
        c.SDL_EVENT_WINDOW_EXPOSED => app.dirty = true,
        c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
            app.buttons.clear();
            app.transcript.draw_width = 0;
            app.library.invalidateTargets();
            app.dirty = true;
        },
        c.SDL_EVENT_WINDOW_MINIMIZED => app.minimized = true,
        c.SDL_EVENT_WINDOW_RESTORED => {
            app.minimized = false;
            app.dirty = true;
            app.requestConversation();
        },
        c.SDL_EVENT_MOUSE_WHEEL => try wheel(app, event),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => try mouseDown(app, event),
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            app.dragging = false;
            if (app.model_picker.open) app.library.dragging = false;
        },
        c.SDL_EVENT_MOUSE_MOTION => try mouseMotion(app, event),
        c.SDL_EVENT_KEY_DOWN => try keyDown(app, event),
        c.SDL_EVENT_TEXT_INPUT => try textInput(app, event),
        c.SDL_EVENT_TEXT_EDITING => try textEditing(app, event),
        c.SDL_EVENT_WINDOW_FOCUS_LOST => if (app.model_picker.open) try menus.editModelQuery(app, event),
        else => {},
    }
}

fn commandHeld(modifiers: u16) bool {
    return (modifiers & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
}

fn wheelDirection(event: *const c.SDL_Event) f32 {
    return event.wheel.y * (if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) @as(f32, -1) else 1);
}

fn globalShortcut(app: *App, event: *const c.SDL_Event) !bool {
    if (!commandHeld(event.key.mod)) return false;
    switch (event.key.key) {
        c.SDLK_K => {
            try workspace.showLibrary(app, .workspace);
            return true;
        },
        c.SDLK_R => {
            workspace.retryEnrollment(app);
            if (!app.library.open) return false;
            try workspace.queryLibrary(app);
            return true;
        },
        c.SDLK_PERIOD => {
            if (!app.library.open) return false;
            try act(app, .stop);
            return true;
        },
        else => return false,
    }
}

fn wheel(app: *App, event: *const c.SDL_Event) !void {
    if (commandHeld(c.SDL_GetModState()) and event.wheel.y != 0) {
        try act(app, .{ .appearance = if (wheelDirection(event) > 0) .scale_larger else .scale_smaller });
        return;
    }
    if (app.settings_open) return;
    if (app.model_picker.open) {
        try app.model_picker.scroll(menus.modelChoices(app), app.library.queryBytes(), wheelDirection(event));
        app.buttons.clear();
    } else if (!app.closing) {
        if (app.sidebar_visible and event.wheel.mouse_x < app.shell.sidebar.width) {
            sidebar.scroll(app, event.wheel.y > 0);
        } else {
            conversation.scrollBy(app, -event.wheel.y * 60, event.wheel.y < 0);
        }
    }
    app.dirty = true;
}

fn mouseDown(app: *App, event: *const c.SDL_Event) !void {
    const modal = app.closing or app.force_dialog;
    if (app.model_picker.open and !modal and try menus.handleModelPointer(app, event)) return;
    const targets = app.buttons.slice();
    var index = targets.len;
    while (index != 0) {
        index -= 1;
        const pressed = targets[index];
        if (modal and pressed.action != .force_stop and pressed.action != .wait) continue;
        if (widgets.contains(pressed.bounds, event.button.x, event.button.y)) {
            try act(app, pressed.action);
            return;
        }
    }
    if (modal or app.settings_open) return;
    if (app.model_picker.open or app.thinking_menu.open) {
        menus.closeAll(app);
        app.dirty = true;
        return;
    }
    if (event.button.button == c.SDL_BUTTON_LEFT) {
        if (app.transcript.copyAt(event.button.x, event.button.y)) |ordinal| {
            try conversation.copyResponse(app, ordinal);
            return;
        }
    }
    const inside = widgets.contains(app.editor_view.bounds, event.button.x, event.button.y);
    app.focused_editor = inside;
    if (inside) {
        app.editor_view.preferred_x = null;
        _ = c.SDL_StartTextInput(app.window);
        if (app.editor_view.offsetAt(event.button.x, event.button.y)) |offset| app.editor.setCaret(offset, (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
        app.dragging = true;
    } else _ = c.SDL_StopTextInput(app.window);
    app.dirty = true;
}

fn mouseMotion(app: *App, event: *const c.SDL_Event) !void {
    if (app.model_picker.open) {
        if (app.library.dragging) {
            try app.library.hitQuery(app, event.motion.x, event.motion.y, true);
            app.dirty = true;
        }
    } else if (app.dragging and !app.settings_open) {
        if (app.editor_view.offsetAt(event.motion.x, event.motion.y)) |offset| app.editor.setCaret(offset, true);
        app.dirty = true;
    }
}

fn keyDown(app: *App, event: *const c.SDL_Event) !void {
    const key = event.key.key;
    const command = commandHeld(event.key.mod);
    const shift = (event.key.mod & c.SDL_KMOD_SHIFT) != 0;
    if (command and shift and key == c.SDLK_ESCAPE and processes.needsForceStop(app)) return act(app, .force_stop);
    if (app.closing or app.force_dialog) {
        if (key == c.SDLK_ESCAPE) try act(app, .wait);
        return;
    }
    if (command) switch (key) {
        c.SDLK_PLUS, c.SDLK_EQUALS, c.SDLK_KP_PLUS => return act(app, .{ .appearance = .scale_larger }),
        c.SDLK_MINUS, c.SDLK_UNDERSCORE, c.SDLK_KP_MINUS => return act(app, .{ .appearance = .scale_smaller }),
        c.SDLK_0, c.SDLK_KP_0 => return act(app, .{ .appearance = .scale_reset }),
        c.SDLK_COMMA => return act(app, .settings),
        else => {},
    };
    if (app.settings_open) {
        if (key == c.SDLK_ESCAPE) try act(app, .{ .appearance = .close });
        return;
    }
    if (command and key == c.SDLK_N) return act(app, .new_thread);
    if (command and key == c.SDLK_B) return act(app, .sidebar);
    if (app.thinking_menu.open) return menus.handleThinkingKey(app, event);
    if (app.model_picker.open) return menus.handleModelKey(app, event);
    if (command) switch (key) {
        c.SDLK_P => return act(app, .start),
        c.SDLK_M => if (!app.options.fixture) return act(app, .models),
        c.SDLK_PERIOD => return act(app, .stop),
        c.SDLK_RETURN => if (!event.key.repeat and app.preedit.items.len == 0 and !app.options.fixture) return chat.submit(app),
        else => {},
    };
    if (key == c.SDLK_PAGEUP or key == c.SDLK_PAGEDOWN) {
        const amount = @max(100, app.transcript.viewport_height - 48);
        conversation.scrollBy(app, if (key == c.SDLK_PAGEUP) -amount else amount, true);
        app.dirty = true;
        return;
    }
    if (command and !app.focused_editor and (key == c.SDLK_HOME or key == c.SDLK_END)) {
        conversation.scrollToEdge(app, key == c.SDLK_END);
        app.dirty = true;
        return;
    }
    if (command and key == c.SDLK_L) {
        commands.toggleTheme(app);
        app.dirty = true;
        return;
    }
    if (command and key == c.SDLK_R) {
        try app.reloadTheme();
        app.catalog_worker.refresh();
        return;
    }
    if (app.focused_editor) try editorKey(app, event, command, shift);
}

fn editorKey(app: *App, event: *const c.SDL_Event, command: bool, shift: bool) !void {
    const key = event.key.key;
    if (key == c.SDLK_ESCAPE) {
        app.preedit.clearRetainingCapacity();
        _ = c.SDL_ClearComposition(app.window);
        app.dirty = true;
        return;
    }
    if (app.preedit.items.len != 0) return;
    const body_px = app.theme.metrics.body_px;
    if (key == c.SDLK_UP or key == c.SDLK_DOWN) {
        try app.editor_view.moveVertical(app.text, &app.editor, body_px, key == c.SDLK_DOWN, shift);
        app.dirty = true;
        return;
    }
    if (key == c.SDLK_HOME or key == c.SDLK_END) {
        try app.editor_view.moveLineEdge(app.text, &app.editor, body_px, key == c.SDLK_END, command, shift);
        app.dirty = true;
        return;
    }
    app.editor_view.preferred_x = null;
    if (command) switch (key) {
        c.SDLK_A => {
            app.editor.selectAll();
            app.dirty = true;
        },
        c.SDLK_C => try clipboard.copySelection(&app.editor, app.copy_buffer),
        c.SDLK_X => {
            try clipboard.copySelection(&app.editor, app.copy_buffer);
            try app.editor.insert("", .paste);
            app.edited();
        },
        c.SDLK_V => {
            const text = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
            defer c.SDL_free(text);
            try app.editor.insert(std.mem.span(text), .paste);
            app.edited();
        },
        c.SDLK_Z => if (if (shift) app.editor.redo() else app.editor.undo()) app.edited(),
        c.SDLK_Y => if (app.editor.redo()) app.edited(),
        c.SDLK_LEFT, c.SDLK_RIGHT => {
            app.editor.moveWord(if (key == c.SDLK_LEFT) .backward else .forward, shift);
            app.dirty = true;
        },
        c.SDLK_BACKSPACE, c.SDLK_DELETE => {
            try app.editor.deleteWord(if (key == c.SDLK_BACKSPACE) .backward else .forward);
            app.edited();
        },
        else => {},
    } else switch (key) {
        c.SDLK_BACKSPACE => {
            try app.editor.backspace();
            app.edited();
        },
        c.SDLK_DELETE => {
            try app.editor.deleteForward();
            app.edited();
        },
        c.SDLK_LEFT, c.SDLK_RIGHT => {
            app.editor.moveGrapheme(if (key == c.SDLK_LEFT) .backward else .forward, shift);
            app.dirty = true;
        },
        c.SDLK_RETURN, c.SDLK_KP_ENTER => {
            // A held Enter must not send: its repeats can outlive the menu that consumed the first press.
            if (app.runtime != null and !shift) {
                if (!event.key.repeat) try chat.submit(app);
            } else {
                try app.editor.insert("\n", .paste);
                app.edited();
            }
        },
        else => {},
    }
}

fn composingElsewhere(app: *const App) bool {
    return app.library.open or !app.focused_editor or app.model_picker.open or app.thinking_menu.open or app.settings_open or app.closing;
}

fn textInput(app: *App, event: *const c.SDL_Event) !void {
    if (app.model_picker.open and !app.closing and !app.force_dialog) return menus.editModelQuery(app, event);
    if (composingElsewhere(app)) return;
    try app.editor.insert(std.mem.span(event.text.text), if (app.preedit.items.len != 0) .ime else .typing);
    app.preedit.clearRetainingCapacity();
    app.edited();
}

fn textEditing(app: *App, event: *const c.SDL_Event) !void {
    if (app.model_picker.open and !app.closing and !app.force_dialog) return menus.editModelQuery(app, event);
    if (composingElsewhere(app)) return;
    const bytes = std.mem.span(event.edit.text);
    if (bytes.len > 4096) return error.PreeditBudgetExceeded;
    app.preedit.clearRetainingCapacity();
    try app.preedit.appendSlice(app.allocator, bytes);
    app.dirty = true;
}
