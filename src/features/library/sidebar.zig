const std = @import("std");
const builtin = @import("builtin");
const widgets = @import("../../ui/widgets.zig");
const app_module = @import("../../app.zig");
const App = app_module.App;
const Action = app_module.Action;
const chat = @import("../chat/chat.zig");

const first_row_y = 158;
const row_step = 38;
const row_height = 34;

fn indexedFolder(app: *const App, path: []const u8) bool {
    if (app.catalog) |catalog| for (catalog.folders) |folder| {
        if (std.mem.eql(u8, path, folder.cwd)) return true;
    };
    return false;
}

fn savedFolder(app: *const App, path: []const u8) bool {
    for (app.projects.items) |project| if (std.mem.eql(u8, project, path)) return true;
    return false;
}

pub fn folderCollapsed(app: *const App, path: []const u8) bool {
    for (app.collapsed_folders.items) |folder| if (std.mem.eql(u8, folder, path)) return true;
    return false;
}

fn currentIndexed(app: *const App) bool {
    const current = chat.currentSession(app);
    if (app.catalog) |catalog| for (catalog.threads) |thread| {
        if (std.mem.eql(u8, current, thread.path)) return true;
    };
    return false;
}

pub fn transientCurrent(app: *const App) bool {
    return !app.current_archived and !currentIndexed(app) and
        (app.chat_view == .new_thread or app.enrollment_intent or app.current_member);
}

fn transientParked(app: *const App, parked: *const chat.ParkedChat) bool {
    if (parked.archived) return false;
    if (app.catalog) |catalog| for (catalog.threads) |thread| {
        if (std.mem.eql(u8, thread.path, parked.session())) return false;
    };
    return true;
}

pub fn currentRow(app: *const App) ?usize {
    var row: usize = 0;
    const transient = transientCurrent(app);
    const indexed = indexedFolder(app, app.project_path);
    if (!indexed) {
        row += 1;
        if (transient and !folderCollapsed(app, app.project_path)) return row;
    }
    if (app.catalog) |catalog| for (catalog.folders) |folder| {
        row += 1;
        if (folderCollapsed(app, folder.cwd)) continue;
        if (transient and std.mem.eql(u8, folder.cwd, app.project_path)) return row;
        const count = folder.row_count - 1;
        for (catalog.rows[folder.first_row + 1 ..][0..count], 0..) |item, offset| {
            if (std.mem.eql(u8, catalog.threads[item.thread].path, chat.currentSession(app))) return row + offset;
        }
        row += count;
    };
    return null;
}

pub fn rowCount(app: *const App) usize {
    var rows: usize = 0;
    if (app.catalog) |catalog| for (catalog.folders) |folder| {
        rows += if (folderCollapsed(app, folder.cwd)) 1 else folder.row_count;
    };
    for (app.projects.items) |path| if (!indexedFolder(app, path)) {
        rows += 1;
    };
    if (!indexedFolder(app, app.project_path) and !savedFolder(app, app.project_path)) rows += 1;
    if (transientCurrent(app) and !folderCollapsed(app, app.project_path)) rows += 1;
    for (app.parked_chats.items) |*parked| if (transientParked(app, parked)) {
        rows += 1;
    };
    return rows;
}

pub fn scroll(app: *App, up: bool) void {
    const last = rowCount(app) -| 1;
    app.sidebar_first = if (up) app.sidebar_first -| 1 else @min(last, app.sidebar_first + 1);
}

fn rowY(app: *const App, row: usize, height: f32) ?f32 {
    if (row < app.sidebar_first) return null;
    const y = first_row_y + @as(f32, @floatFromInt(row - app.sidebar_first)) * row_step;
    return if (y + 36 <= height - 104) y else null;
}

fn drawFolderRow(app: *App, path: []const u8, action: Action, browse: Action, row: usize, height: f32) !void {
    const y = rowY(app, row, height) orelse return;
    const colors = app.palette();
    const width = app.shell.sidebar.width;
    const active = std.mem.eql(u8, path, app.project_path);
    try widgets.icon(app.renderer, .folder, .{ .x = 20, .y = y + 10, .w = 14, .h = 14 }, if (active) colors.accent else colors.muted);
    // Browsing only expands/collapses; the separate plus creates a thread.
    try app.hit(browse, .{ .x = 10, .y = y, .w = width - 52, .h = row_height });
    const name = std.fs.path.basename(path);
    try app.fitLabel(App.clipped(if (name.len == 0) path else name), 42, y + 9, width - 86, 13, colors.text);
    try app.iconButton(action, .plus, .{ .x = width - 42, .y = y + 2, .w = 30, .h = 30 }, colors.muted);
}

fn drawCurrentRow(app: *App, row: usize, height: f32) !void {
    const y = rowY(app, row, height) orelse return;
    const width = app.shell.sidebar.width;
    const colors = app.palette();
    try app.rectangle(28, y, width - 40, row_height, 6, colors.raised);
    try app.hit(.latest, .{ .x = 28, .y = y, .w = width - 40, .h = row_height });
    try app.fitLabel(App.clipped(app.title()), 40, y + 9, width - 64, 13, colors.accent);
}

fn drawFolderWithCurrent(app: *App, path: []const u8, action: Action, browse: Action, row: *usize, height: f32, current_missing: bool) !void {
    try drawFolderRow(app, path, action, browse, row.*, height);
    row.* += 1;
    if (current_missing and !folderCollapsed(app, path)) {
        try drawCurrentRow(app, row.*, height);
        row.* += 1;
    }
}

pub fn draw(app: *App, height: f32) !void {
    const colors = app.palette();
    const width = app.shell.sidebar.width;
    try app.rectangle(0, 0, width, height, 0, colors.panel);
    try app.rectangle(width - 1, 0, 1, height, 0, colors.border);
    try app.iconButton(.sidebar, .sidebar, .{ .x = 12, .y = 9, .w = 30, .h = 30 }, colors.muted);
    try app.label("Spica", 50, 17, 15, colors.text);
    try app.button(.new_thread, "New thread", .{ .x = 12, .y = 46, .w = width - 24, .h = 30 });
    try app.flatButton(.{ .open_library = .workspace }, if (builtin.os.tag == .macos) "Search chats    Cmd+K" else "Search chats    Ctrl+K", .{ .x = 12, .y = 80, .w = width - 24, .h = 30 });
    try app.label("Projects", 20, 128, 12, colors.muted);
    try app.flatButton(.add_project, "+ Add folder", .{ .x = width - 108, .y = 120, .w = 100, .h = 30 });
    const visible: usize = @intFromFloat(@max(1, @floor((height - 262) / row_step)));
    app.sidebar_first = @min(app.sidebar_first, rowCount(app) -| visible);
    if (app.sidebar_reveal_current) if (currentRow(app)) |selected_row| {
        if (selected_row < app.sidebar_first) app.sidebar_first = selected_row;
        if (selected_row >= app.sidebar_first + visible) app.sidebar_first = selected_row + 1 -| visible;
        app.sidebar_reveal_current = false;
    };
    const current_missing = transientCurrent(app);
    var row: usize = 0;
    if (!indexedFolder(app, app.project_path)) {
        for (app.projects.items, 0..) |path, project_index| if (std.mem.eql(u8, path, app.project_path)) {
            try drawFolderWithCurrent(app, path, .{ .new_project_thread = project_index }, .{ .toggle_project_folder = project_index }, &row, height, current_missing);
        };
        if (!savedFolder(app, app.project_path)) try drawFolderWithCurrent(app, app.project_path, .new_thread, .toggle_current_folder, &row, height, current_missing);
    }
    if (app.catalog) |catalog| for (catalog.folders, 0..) |folder, folder_index| {
        try drawFolderRow(app, folder.cwd, .{ .new_catalog_thread = folder_index }, .{ .toggle_folder = folder_index }, row, height);
        row += 1;
        if (folderCollapsed(app, folder.cwd)) continue;
        if (current_missing and std.mem.eql(u8, folder.cwd, app.project_path)) {
            try drawCurrentRow(app, row, height);
            row += 1;
        }
        const count = folder.row_count - 1;
        // Decode/draw/hit-test only the visible slice, not every session.
        const first = @min(count, app.sidebar_first -| row);
        const end = @min(count, (app.sidebar_first + visible) -| row);
        for (catalog.rows[folder.first_row + 1 + first .. folder.first_row + 1 + end], first..) |item, offset| {
            const index = item.thread;
            const thread = catalog.threads[index];
            const y = rowY(app, row + offset, height) orelse continue;
            const active = std.mem.eql(u8, chat.currentSession(app), thread.path);
            if (active) try app.rectangle(28, y, width - 40, row_height, 6, colors.raised);
            try app.hit(.{ .open_thread = index }, .{ .x = 28, .y = y, .w = width - 76, .h = row_height });
            try app.fitLabel(App.clipped(thread.title), 40, y + 9, width - 100, 13, if (active) colors.accent else if (thread.available) colors.text else colors.muted);
            try app.iconButton(.{ .archive_thread = index }, .archive, .{ .x = width - 42, .y = y + 2, .w = 30, .h = 30 }, colors.muted);
        }
        row += count;
    };
    for (app.projects.items, 0..) |path, project_index| {
        if (indexedFolder(app, path) or std.mem.eql(u8, path, app.project_path)) continue;
        try drawFolderRow(app, path, .{ .new_project_thread = project_index }, .{ .toggle_project_folder = project_index }, row, height);
        row += 1;
    }
    for (app.parked_chats.items, 0..) |*parked, index| {
        if (!transientParked(app, parked)) continue;
        const parked_row = row;
        row += 1;
        const y = rowY(app, parked_row, height) orelse continue;
        try app.hit(.{ .open_parked = index }, .{ .x = 28, .y = y, .w = width - 40, .h = row_height });
        try app.fitLabel(App.clipped(parked.displayTitle()), 40, y + 9, width - 68, 13, colors.text);
    }
    try app.rectangle(12, height - 100, width - 24, 1, 0, colors.border);
    try app.flatButton(.{ .open_library = .import_pi }, "Import Pi chat", .{ .x = 12, .y = height - 96, .w = width - 24, .h = 28 });
    try app.flatButton(.{ .open_library = .archives }, "Archives", .{ .x = 12, .y = height - 66, .w = width - 24, .h = 28 });
    try app.flatButton(.settings, "Settings", .{ .x = 12, .y = height - 36, .w = width - 24, .h = 28 });
}

test "new chat reveal expands only its project and archived current never makes a transient row" {
    const allocator = std.testing.allocator;
    const workspace = @import("workspace.zig");
    var app: App = undefined;
    app.allocator = allocator;
    app.project_path = @constCast("/b");
    app.projects = .empty;
    app.collapsed_folders = .empty;
    defer {
        for (app.collapsed_folders.items) |path| allocator.free(path);
        app.collapsed_folders.deinit(allocator);
    }
    try app.collapsed_folders.append(allocator, try allocator.dupe(u8, "/a"));
    try app.collapsed_folders.append(allocator, try allocator.dupe(u8, "/b"));
    app.catalog = null;
    app.parked_chats = .empty;
    app.current_archived = false;
    app.current_member = false;
    app.enrollment_intent = false;
    app.chat_view = .new_thread;
    app.runtime_snapshot = null;
    app.pending_thread = null;
    app.options = .{};
    try std.testing.expect(currentRow(&app) == null);
    workspace.revealCurrentFolder(&app);
    try std.testing.expect(folderCollapsed(&app, "/a"));
    try std.testing.expect(!folderCollapsed(&app, "/b"));
    try std.testing.expectEqual(@as(?usize, 1), currentRow(&app));
    try std.testing.expectEqual(@as(usize, 2), rowCount(&app));
    app.current_member = true;
    app.current_archived = true;
    app.chat_view = .existing;
    try std.testing.expect(!transientCurrent(&app));
    try std.testing.expect(currentRow(&app) == null);
    try std.testing.expectEqual(@as(usize, 1), rowCount(&app));
}
