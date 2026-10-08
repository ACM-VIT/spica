const std = @import("std");
const builtin = @import("builtin");
const c = @import("../native/bindings.zig").c;
const theme_module = @import("../ui/theme.zig");
const widgets = @import("../ui/widgets.zig");
const editor_view = @import("../ui/editor_view.zig");
const Settings = @import("../ui/settings.zig");
const Composer = @import("../text/composer.zig").Composer;
const App = @import("../app.zig").App;
const processes = @import("processes.zig");
const sidebar = @import("sidebar.zig");
const menus = @import("menus.zig");

pub fn paint(app: *App) !void {
    app.buttons.clear();
    const size = try applyScale(app);
    const width = size[0];
    const height = size[1];
    app.layout.resize(width, height);
    const colors = app.palette();
    app.shell = app.layout.shell(if (app.sidebar_visible) @min(268, width * 0.34) else 0, app.theme.metrics.header_height, @min(202, height * 0.4));
    if (!c.SDL_SetRenderDrawColor(app.renderer, colors.canvas.r, colors.canvas.g, colors.canvas.b, 255) or
        !c.SDL_RenderClear(app.renderer)) return error.ClearFrame;
    if (app.sidebar_visible) try sidebar.draw(app, height) else try app.iconButton(.sidebar, .sidebar, .{ .x = app.shell.header.x + 12, .y = 7, .w = 30, .h = 30 }, colors.muted);
    try drawHeader(app);
    const content = try drawTranscript(app);
    try drawComposer(app, content);
    try drawStatusLine(app);
    try drawOverlays(app);
    if (app.settings_open) {
        app.buttons.clear();
        try Settings.draw(app);
    }
    if (app.library.open) try app.library.draw(app);
    if (app.library.open and (app.closing or app.force_dialog)) {
        app.buttons.clear();
        try drawOverlays(app);
    }
    try captureWhenSettled(app);
    if (!c.SDL_RenderPresent(app.renderer)) return error.PresentFrame;
    app.frames += 1;
    if (!app.presented) {
        std.log.info("Spica ready; renderer={s}; video={s}; fixture={}; platform={s}; logical={d}x{d}; composer_bytes={d}", .{ c.SDL_GetRendererName(app.renderer), c.SDL_GetCurrentVideoDriver(), app.options.fixture, @tagName(builtin.os.tag), @as(c_int, @intFromFloat(width)), @as(c_int, @intFromFloat(height)), Composer.storageBytes });
        app.presented = true;
    }
    app.dirty = false;
}

fn applyScale(app: *App) ![2]f32 {
    var width: c_int = 1280;
    var height: c_int = 800;
    _ = c.SDL_GetWindowSize(app.window, &width, &height);
    const scale = @as(f32, @floatFromInt(app.appearance.ui_scale)) / 100;
    var pixel_width: c_int = width;
    var pixel_height: c_int = height;
    if (!c.SDL_GetRenderOutputSize(app.renderer, &pixel_width, &pixel_height)) return error.RenderOutputSize;
    const scale_x = @as(f32, @floatFromInt(pixel_width)) / @as(f32, @floatFromInt(width)) * scale;
    const scale_y = @as(f32, @floatFromInt(pixel_height)) / @as(f32, @floatFromInt(height)) * scale;
    if (!c.SDL_SetRenderLogicalPresentation(app.renderer, 0, 0, c.SDL_LOGICAL_PRESENTATION_DISABLED) or
        !c.SDL_SetRenderScale(app.renderer, scale_x, scale_y)) return error.RenderScale;
    if (!c.spica_text_set_render_scale(app.text, scale_x, scale_y)) return error.TextRenderScale;
    const logical_width: c_int = @intFromFloat(@as(f32, @floatFromInt(width)) / scale);
    const logical_height: c_int = @intFromFloat(@as(f32, @floatFromInt(height)) / scale);
    return .{ @floatFromInt(logical_width), @floatFromInt(logical_height) };
}

fn displayedProject(app: *const App) []const u8 {
    return if (app.pending_thread) |target| target.cwd else app.project_path;
}

fn statusText(app: *const App) []const u8 {
    if (app.options.fixture) return "Resource scene";
    if (app.current_archived) return "Archived";
    return switch (processes.runtimeStatus(app)) {
        .starting => "Starting pi",
        .ready => if (processes.bashRunning(app)) "Running Bash" else "Ready",
        .streaming => "Working",
        .stopping => "Stopping",
        .needs_force_stop => "Needs Force",
        .failed => "Pi failed",
        .exited => "Pi exited",
        .stopped => "Stopped",
    };
}

fn drawHeader(app: *App) !void {
    const colors = app.palette();
    const header = app.shell.header;
    const project = App.clipped(std.fs.path.basename(displayedProject(app)));
    const crumb_x = header.x + (if (app.sidebar_visible) @as(f32, 22) else 52);
    try widgets.icon(app.renderer, .folder, .{ .x = crumb_x, .y = 15, .w = 14, .h = 14 }, colors.accent);
    const project_width = @min(try app.labelWidth(project, 13), header.width * 0.32);
    try app.fitLabel(project, crumb_x + 24, 15, project_width, 13, colors.text);
    const title_x = crumb_x + 40 + project_width;
    try app.label("/", title_x, 15, 13, colors.muted);
    try app.fitLabel(App.clipped(app.title()), title_x + 20, 15, @max(0, header.x + header.width - 158 - title_x), 13, colors.muted);
    const status = processes.runtimeStatus(app);
    try app.label(statusText(app), header.x + header.width - 138, 16, 11, if (status == .failed) colors.error_color else if (status == .streaming) colors.accent else colors.muted);
    if (!app.options.fixture and app.pending_thread == null and (app.runtime == null or app.runtime.?.isFinished())) try app.button(.start, "Retry", .{ .x = header.x + header.width - 86, .y = 8, .w = 68, .h = 28 });
}

const ContentColumn = struct { x: f32, width: f32 };

fn drawTranscript(app: *App) !ContentColumn {
    const colors = app.palette();
    const conversation = app.shell.conversation;
    const content_width = @max(160, @min(app.theme.metrics.chat_max_width, conversation.width - 40));
    const content_x = conversation.x + (conversation.width - content_width) / 2;
    const body_top = conversation.y + 20;
    const viewport_height = @max(24, conversation.height - 56);
    if (app.chat_view != .opening) {
        var clip = widgets.Clip.push(app.renderer, .{ .x = content_x, .y = body_top, .w = content_width, .h = viewport_height });
        defer clip.restore(app.renderer);
        try app.transcript.draw(app.text, app.renderer, content_x, body_top, content_width, viewport_height, &app.scroll, app.follow_bottom, app.theme.metrics, colors, app.light);
        for (app.transcript.disclosures[0..app.transcript.disclosure_count]) |disclosure| try app.hit(.{ .disclosure = disclosure.toggle }, disclosure.bounds);
    }
    if (!app.options.fixture and (app.chat_view == .opening or
        (app.transcript.items.items.len == 0 and !app.content_pending and !app.conversation_dirty and processes.runtimeStatus(app) == .ready)))
    {
        const empty_y = body_top + @min(96, viewport_height * 0.2);
        try app.label(if (app.chat_view == .opening) app.title() else if (app.chat_view == .existing) "No messages in this chat" else "New thread", content_x + 16, empty_y, @intFromFloat(app.theme.metrics.body_px + 5), colors.text);
        try app.fitLabel(App.clipped(displayedProject(app)), content_x + 16, empty_y + 38, content_width - 32, 13, colors.muted);
        const description = if (app.chat_view == .opening)
            (if (processes.runtimeStatus(app) == .failed) "Unable to open chat." else "Opening chat...")
        else if (app.chat_view == .existing) "This saved chat has no messages." else "Describe what you want to build or change.";
        try app.fitLabel(description, content_x + 16, empty_y + 64, content_width - 32, 13, colors.muted);
    }
    if (!app.follow_bottom and app.transcript.height > viewport_height) try app.flatButton(.latest, "Jump to latest", .{ .x = content_x + content_width - 128, .y = conversation.y + conversation.height - 33, .w = 128, .h = 28 });
    return .{ .x = content_x, .width = content_width };
}

fn blend(base: theme_module.Color, top: theme_module.Color) theme_module.Color {
    return .{
        .r = @intCast((@as(u16, base.r) * 3 + top.r) / 4),
        .g = @intCast((@as(u16, base.g) * 3 + top.g) / 4),
        .b = @intCast((@as(u16, base.b) * 3 + top.b) / 4),
    };
}

fn currentModelName(app: *const App) []const u8 {
    const snapshot = app.runtime_snapshot orelse return "Select model";
    for (snapshot.models) |model| if (std.mem.eql(u8, model.id, snapshot.model) and std.mem.eql(u8, model.provider, snapshot.provider)) return model.name;
    return if (snapshot.model.len != 0) snapshot.model else "Select model";
}

fn drawComposer(app: *App, column: ContentColumn) !void {
    const colors = app.palette();
    app.composer_bounds = .{ .x = column.x, .y = app.shell.composer.y + 8, .w = column.width, .h = @min(144, app.shell.composer.height - 44) };
    const composer = app.composer_bounds;
    try app.rectangle(composer.x, composer.y, composer.w, composer.h, 14, colors.border);
    try app.rectangle(composer.x + 1, composer.y + 1, composer.w - 2, composer.h - 2, 13, blend(colors.canvas, colors.raised));
    app.editor_view.bounds = .{ .x = composer.x + 4, .y = composer.y + 4, .w = composer.w - 8, .h = composer.h - 52 };
    try drawEditor(app);
    const controls_y = composer.y + composer.h - 40;
    const model_name = currentModelName(app);
    const model_width = @min(@min(220, composer.w * 0.43), try app.labelWidth(App.clipped(model_name), 13) + 34);
    app.model_bounds = .{ .x = composer.x + 8, .y = controls_y, .w = model_width, .h = 30 };
    try app.flatButton(.models, model_name, app.model_bounds);
    try widgets.icon(app.renderer, .chevron_down, .{ .x = app.model_bounds.x + model_width - 19, .y = controls_y + 9, .w = 12, .h = 12 }, colors.muted);
    const thinking = if (app.runtime_snapshot) |snapshot| snapshot.thinking_level else "";
    app.thinking_bounds = .{ .x = app.model_bounds.x + model_width + 4, .y = controls_y, .w = 80, .h = 30 };
    if (thinking.len != 0) {
        try app.flatButton(.thinking, thinking, app.thinking_bounds);
        try widgets.icon(app.renderer, .chevron_down, .{ .x = app.thinking_bounds.x + 59, .y = controls_y + 9, .w = 12, .h = 12 }, colors.muted);
    }
    if (!app.options.fixture) {
        const mode_x = app.thinking_bounds.x + (if (thinking.len == 0) @as(f32, 0) else 84);
        if (processes.runtimeStatus(app) == .streaming and mode_x + 100 < composer.x + composer.w - 48) {
            try app.flatButton(.behavior, if (app.behavior == .steer) "Steer" else "Follow-up", .{ .x = mode_x, .y = controls_y, .w = 96, .h = 30 });
        }
        const send_bounds = c.SDL_FRect{ .x = composer.x + composer.w - 44, .y = controls_y, .w = 32, .h = 32 };
        const working = processes.working(app);
        if (app.current_archived) {
            try app.button(.restore_current, "Restore", .{ .x = composer.x + composer.w - 86, .y = controls_y, .w = 78, .h = 32 });
        } else {
            try app.rectangle(send_bounds.x, send_bounds.y, send_bounds.w, send_bounds.h, 16, if (app.runtime == null) colors.raised else colors.accent);
            try app.iconButton(if (working) .stop else .send, if (working) .stop else .arrow_up, send_bounds, if (app.runtime == null) colors.muted else colors.text);
        }
    }
    const project = App.clipped(std.fs.path.basename(displayedProject(app)));
    try widgets.icon(app.renderer, .folder, .{ .x = composer.x + 2, .y = composer.y + composer.h + 13, .w = 12, .h = 12 }, colors.muted);
    try app.label("Local checkout", composer.x + 22, composer.y + composer.h + 13, 11, colors.muted);
    try app.fitLabel(project, composer.x + 130, composer.y + composer.h + 13, @max(0, composer.w - 130), 11, colors.muted);
}

fn drawStatusLine(app: *App) !void {
    const colors = app.palette();
    const composer = app.composer_bounds;
    const y = composer.y - 25;
    if (!app.error_text.isEmpty()) return app.fitLabel(App.clipped(app.error_text.slice()), composer.x, y, composer.w, 12, colors.error_color);
    const snapshot = app.runtime_snapshot orelse return;
    if (snapshot.attention.len != 0) return app.fitLabel(App.clipped(snapshot.attention), composer.x, y, composer.w, 12, colors.muted);
    if (snapshot.status == .streaming or processes.bashRunning(app)) {
        var buffer: [128]u8 = undefined;
        const progress = std.fmt.bufPrint(&buffer, "{s}{s}{d} queued", .{ if (processes.bashRunning(app)) "Running Bash" else "Working", " · ", snapshot.queued_count }) catch unreachable;
        try app.fitLabel(progress, composer.x, y, composer.w - 140, 12, colors.accent);
    }
}

fn drawEditor(app: *App) !void {
    const view = &app.editor_view;
    const bounds = view.bounds;
    const colors = app.palette();
    try view.ensureLayout(app.text, &app.editor, bounds.w, app.theme.metrics.body_px);
    var clip = widgets.Clip.push(app.renderer, .{ .x = bounds.x + 8, .y = bounds.y + 8, .w = bounds.w - 16, .h = bounds.h - 16 });
    defer clip.restore(app.renderer);
    const origin_x = bounds.x + editor_view.text_x;
    const origin_y = bounds.y + editor_view.text_y;
    const caret = view.caret(&app.editor);
    if (view.layout) |layout| {
        if (caret) |rect| {
            view.scroll = @max(0, @min(view.scroll, rect.y));
            if (rect.y + rect.h > view.scroll + bounds.h - 20) view.scroll = rect.y + rect.h - (bounds.h - 20);
            try placeInputArea(app, origin_x + rect.x, origin_y + rect.y - view.scroll, rect.h);
        }
        const selected = app.editor.selection();
        const start = @max(selected.start, view.start);
        const end = @min(selected.end, view.end);
        if (start < end) {
            var rects: [8192]c.SDL_FRect = undefined;
            const count = c.spica_text_layout_selection_rects(layout, start - view.start, end - view.start, &rects, rects.len);
            if (count > rects.len) return error.SelectionGeometryBudget;
            for (rects[0..count]) |*rect| {
                rect.x += origin_x;
                rect.y += origin_y - view.scroll;
            }
            if (!c.SDL_SetRenderDrawBlendMode(app.renderer, c.SDL_BLENDMODE_BLEND) or !c.SDL_SetRenderDrawColor(app.renderer, colors.accent.r, colors.accent.g, colors.accent.b, 60) or !c.SDL_RenderFillRects(app.renderer, &rects, @intCast(count))) return error.SelectionDraw;
        }
        if (!c.spica_text_layout_draw(app.text, layout, origin_x, origin_y - view.scroll, widgets.rgba(colors.text))) return error.EditorDraw;
        if (app.editor.len == 0) try app.label("Ask for changes or send a follow-up", origin_x, origin_y, @intFromFloat(app.theme.metrics.body_px), colors.muted);
    }
    if (app.preedit.items.len != 0) try app.label(App.clipped(app.preedit.items), origin_x, bounds.y + 66, 15, colors.accent);
    if (caret) |rect| if (app.focused_editor and !app.model_picker.open) try app.rectangle(origin_x + rect.x, origin_y + rect.y - view.scroll, 2, rect.h, 0, colors.text);
}

fn placeInputArea(app: *App, x: f32, y: f32, height: f32) !void {
    var input_x: f32 = 0;
    var input_y: f32 = 0;
    var input_bottom: f32 = 0;
    if (!c.SDL_RenderCoordinatesToWindow(app.renderer, x, y, &input_x, &input_y) or
        !c.SDL_RenderCoordinatesToWindow(app.renderer, x, y + height, null, &input_bottom)) return error.InputCoordinates;
    const area = c.SDL_Rect{ .x = @intFromFloat(input_x), .y = @intFromFloat(input_y), .w = 2, .h = @intFromFloat(@max(1, input_bottom - input_y)) };
    _ = c.SDL_SetTextInputArea(app.window, &area, 0);
}

fn drawOverlays(app: *App) !void {
    if (app.model_picker.open) try menus.drawModelMenu(app);
    if (app.thinking_menu.open) try menus.drawThinkingMenu(app);
    if (app.closing or app.force_dialog) try drawShutdownDialog(app);
}

fn drawShutdownDialog(app: *App) !void {
    const colors = app.palette();
    const x = app.shell.conversation.x + 36;
    try app.rectangle(x, 110, app.shell.conversation.width - 72, 166, 10, colors.panel);
    try app.label(if (app.force_dialog) "Pi has not exited" else "Closing pi gracefully...", x + 20, 130, 18, colors.text);
    try app.label("The window stays alive until its owned process exits.", x + 20, 164, 13, colors.muted);
    if (app.force_dialog) {
        try app.button(.wait, "Wait", .{ .x = x + 20, .y = 213, .w = 80, .h = 34 });
        try app.button(.force_stop, "Force owned tree · Ctrl+Shift+Esc", .{ .x = x + 114, .y = 213, .w = 258, .h = 34 });
    }
}

fn captureWhenSettled(app: *App) !void {
    const destination = app.options.capture orelse return;
    if (app.captured or app.transcript.wanted != null or app.content_pending or app.conversation_dirty) return;
    const settled = if (app.options.fixture) app.transcript.items.items.len != 0 else processes.runtimeStatus(app) == .ready;
    if (!settled) return;
    const surface = c.SDL_RenderReadPixels(app.renderer, null) orelse return error.ScreenCapture;
    defer c.SDL_DestroySurface(surface);
    const path = try app.allocator.dupeZ(u8, destination);
    defer app.allocator.free(path);
    if (!c.IMG_SavePNG(surface, path.ptr)) return error.ScreenCapture;
    app.captured = true;
}
