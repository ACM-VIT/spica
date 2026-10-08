const std = @import("std");
const c = @import("../native/bindings.zig").c;
const pi = @import("../core/runtime.zig");
const App = @import("../app.zig").App;
const chat = @import("chat.zig");
const menus = @import("menus.zig");
const workspace = @import("workspace.zig");
const updates = @import("updates.zig");

pub fn runtimeStatus(app: *const App) pi.Status {
    const status = if (app.runtime_snapshot) |snapshot| snapshot.status else .stopped;
    return if (app.runtime_retiring and status == .ready) .stopping else status;
}

pub fn bashRunning(app: *const App) bool {
    return if (app.runtime_snapshot) |snapshot| snapshot.bash_running and (snapshot.status == .ready or snapshot.status == .streaming) else false;
}

pub fn working(app: *const App) bool {
    return runtimeStatus(app) == .streaming or bashRunning(app);
}

pub fn beginRuntime(app: *App) !void {
    if (app.options.fixture or app.closing) return;
    if (app.runtime) |runtime| {
        if (!runtime.isFinished()) return;
        try runtime.destroy();
        app.runtime = null;
    }
    if (app.model_restore == null) if (app.runtime_snapshot) |snapshot| {
        app.model_restore = try chat.ModelRestore.capture(app.allocator, snapshot);
    };
    app.runtime_retiring = false;
    if (app.runtime_snapshot) |*snapshot| snapshot.deinit();
    app.runtime_snapshot = null;
    menus.closeModelMenu(app);
    app.submitted_prompt = null;
    app.error_text.clear();
    app.follow_bottom = true;
    app.runtime = try pi.Runtime.create(app.allocator, app.io, .{
        .database_path = app.paths.database,
        .project_path = app.project_path,
        .node_path = app.options.node_path,
        .pi_entrypoint = app.options.pi_entrypoint,
        .trust_project = app.options.trust_project orelse false,
        .resume_file = app.options.resume_file,
        .wake_event = app.wake_event,
    });
    try app.runtime.?.start();
    app.dirty = true;
}

pub fn ownedRuntimesFinished(app: *const App) bool {
    if (app.runtime) |runtime| if (!runtime.isFinished()) return false;
    for (app.parked_chats.items) |parked| if (parked.runtime) |runtime| if (!runtime.isFinished()) return false;
    return true;
}

pub fn shutdownOwned(app: *App) !void {
    var failure: ?anyerror = null;
    if (app.runtime) |runtime| if (!runtime.isFinished()) {
        runtime.shutdown() catch |err| {
            failure = err;
        };
    };
    for (app.parked_chats.items) |*parked| if (parked.runtime) |runtime| if (!runtime.isFinished()) {
        runtime.shutdown() catch |err| {
            failure = err;
        };
        parked.retiring = true;
    };
    if (failure) |err| return err;
}

pub fn needsForceStop(app: *const App) bool {
    if (app.runtime) |runtime| if (!runtime.isFinished() and runtimeStatus(app) == .needs_force_stop) return true;
    for (app.parked_chats.items) |parked| if (parked.runtime) |runtime| if (!runtime.isFinished()) {
        if (parked.snapshot) |snapshot| if (snapshot.status == .needs_force_stop) return true;
    };
    return false;
}

pub fn forceOwned(app: *App) !void {
    var failure: ?anyerror = null;
    if (app.runtime) |runtime| if (!runtime.isFinished() and (app.closing or runtimeStatus(app) == .needs_force_stop)) {
        runtime.forceTerminate() catch |err| {
            failure = err;
        };
    };
    for (app.parked_chats.items) |parked| if (parked.runtime) |runtime| if (!runtime.isFinished()) {
        if (app.closing or (parked.snapshot != null and parked.snapshot.?.status == .needs_force_stop)) {
            runtime.forceTerminate() catch |err| {
                failure = err;
            };
        }
    };
    if (failure) |err| return err;
}

pub fn closeSettled(app: *const App) bool {
    if (!ownedRuntimesFinished(app) or app.pending_mutation != null or app.submitted_prompt != null or
        (app.enrollment_intent and !app.enrollment_failed)) return false;
    for (app.parked_chats.items) |parked| if (parked.submitted != null or (parked.enrollment_intent and !parked.enrollment_failed)) return false;
    return true;
}

pub fn requestClose(app: *App) !void {
    if (!app.closing) {
        try workspace.saveDraft(app);
        menus.closeModelMenu(app);
        app.closing = true;
        app.focused_editor = false;
        _ = c.SDL_StopTextInput(app.window);
        app.dirty = true;
        try shutdownOwned(app);
    }
    workspace.enrollCurrent(app);
    if (closeSettled(app)) app.running = false;
}

pub fn retainOwnedProcessOnError(app: *App) void {
    if (ownedRuntimesFinished(app)) return;
    app.closing = true;
    shutdownOwned(app) catch |err| std.log.err("Shutdown after UI failure: {s}", .{@errorName(err)});
    var prompted = false;
    while (!ownedRuntimesFinished(app)) {
        updates.consumeRuntime(app);
        updates.consumeParked(app);
        if (needsForceStop(app) and !prompted) {
            prompted = true;
            const buttons = [_]c.SDL_MessageBoxButtonData{
                .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT | c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 0, .text = "Keep waiting" },
                .{ .flags = 0, .buttonID = 1, .text = "Force owned process tree" },
            };
            const dialog = c.SDL_MessageBoxData{
                .flags = c.SDL_MESSAGEBOX_ERROR,
                .window = app.window,
                .title = "Spica — UI failure",
                .message = "Pi has not exited. Spica will retain ownership until it exits.\nCtrl+Shift+Esc reopens this choice.",
                .numbuttons = buttons.len,
                .buttons = &buttons,
                .colorScheme = null,
            };
            var choice: c_int = 0;
            if (c.SDL_ShowMessageBox(&dialog, &choice) and choice == 1) forceOwned(app) catch |err| std.log.err("Explicit force: {s}", .{@errorName(err)});
        }
        var event: c.SDL_Event = undefined;
        if (c.SDL_WaitEventTimeout(&event, 1000)) {
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.key == c.SDLK_ESCAPE and (event.key.mod & c.SDL_KMOD_CTRL) != 0 and (event.key.mod & c.SDL_KMOD_SHIFT) != 0) prompted = false;
        } else c.SDL_Delay(50);
    }
}
