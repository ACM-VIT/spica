const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Composer = @import("../text/composer.zig").Composer;
const EditorView = @import("editor_view.zig").EditorView;
const LabelCache = @import("label_cache.zig").LabelCache;
const widgets = @import("widgets.zig");
const clipboard = @import("clipboard.zig");
const Layout = @import("clay.zig").Layout;
const Color = @import("color.zig").Color;
const transcript = @import("transcript.zig");
const presentation = @import("../content/presentation.zig");
const contract = @import("../contract.zig");

pub const Intent = enum { send, cancel, allow, deny };

/// Presentation state only. No adapter, store, execution lifetime or accepted work.
pub const View = struct {
    allocator: std.mem.Allocator,
    editor: Composer,
    editor_view: EditorView = .{},
    labels: LabelCache = .{},
    scratch: []u8,
    focused: bool = true,
    window_active: bool = true,
    reveal_caret: bool = true,
    dragging: bool = false,
    preedit: [4096]u8 = undefined,
    preedit_len: usize = 0,
    preedit_layout: ?*c.SpicaTextLayout = null,
    preedit_changed: bool = true,
    preedit_width: f32 = 0,
    notice: ?[]const u8 = null,
    revision: u64 = 0,
    status: []const u8 = "Conversation not connected",
    connected: bool = false,
    tasks: [16]TaskLine = @splat(.{}),
    task_count: usize = 0,
    tasks_enabled: bool = false,
    task_cancel: ?TaskCancel = null,
    can_send: bool = false,
    send_disabled_reason: ?[]const u8 = null,
    can_cancel: bool = false,
    can_approve: bool = false,
    intent: ?Intent = null,
    controls: [4]c.SDL_FRect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 }),
    rich_tiles: [8]transcript.RichTile = @splat(.{}),
    rich_count: usize = 0,
    rich_next: usize = 0,
    transcript_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    transcript_scroll: f32 = 0,
    follow_latest: bool = true,
    history_move: ?HistoryMove = null,
    history_height: f32 = 0,
    transcript_drag: ?usize = null,
    rendered_selection: ?presentation.Selection = null,
    copy_selection: ?presentation.Selection = null,
    history_position: ?ThreadHistory = null,
    history_restore: bool = false,
    custom_root: ?*const @import("../script.zig").Root = null,
    custom_render: ?*const @import("../script.zig").Render = null,
    custom_bounds: [64]c.Clay_BoundingBox = undefined,
    custom_action: ?usize = null,
    custom_tile: transcript.RichTile = .{},
    custom_render_sequence: u64 = 0,
    custom_tile_sequence: u64 = std.math.maxInt(u64),
    models: [32]Model = undefined,
    model_count: usize = 0,
    selected: ?Identity = null,
    picker_open: bool = false,
    picker_scroll: f32 = 0,
    picker_menu: c.SDL_FRect = zero_rect,
    picker_rows: c.SDL_FRect = zero_rect,
    picker_hover: usize = 0,
    sidebar_bounds: c.SDL_FRect = zero_rect,
    sidebar_rows: c.SDL_FRect = zero_rect,
    sidebar_scroll: f32 = 0,
    new_project_bounds: c.SDL_FRect = zero_rect,
    new_thread_bounds: c.SDL_FRect = zero_rect,
    project_bounds: [16]c.SDL_FRect = @splat(zero_rect),
    thread_bounds: [32]c.SDL_FRect = @splat(zero_rect),
    setup_open: bool = false,
    setup_runtime: enum { codex, opencode } = .codex,
    setup_fields: [4][512]u8 = undefined,
    setup_lengths: [4]usize = @splat(0),
    setup_field: usize = 0,
    setup_select_all: bool = false,
    setup_menu: c.SDL_FRect = zero_rect,
    setup_runtime_bounds: c.SDL_FRect = zero_rect,
    setup_close_bounds: c.SDL_FRect = zero_rect,
    setup_field_bounds: [4]c.SDL_FRect = @splat(zero_rect),
    setup_button_bounds: [4]c.SDL_FRect = @splat(zero_rect),
    setup_action: ?enum { configure, browser, device, status, refresh } = null,
    runtime_info: [4096]u8 = undefined,
    runtime_info_len: usize = 0,
    picker_bounds: c.SDL_FRect = .{ .x = 240, .y = 18, .w = 350, .h = 28 },
    effort_bounds: c.SDL_FRect = .{ .x = 600, .y = 18, .w = 120, .h = 28 },
    setup_bounds: c.SDL_FRect = .{ .x = 730, .y = 18, .w = 120, .h = 28 },
    follow_bounds: c.SDL_FRect = .{ .x = 860, .y = 18, .w = 164, .h = 28 },
    workspace_label: [512]u8 = undefined,
    workspace_label_len: usize = 0,
    projects: [16]Entry = @splat(.{}),
    project_count: usize = 0,
    threads: [32]Entry = @splat(.{}),
    thread_count: usize = 0,
    active_project: transcript.Id = .{},
    active_thread: transcript.Id = .{},
    navigation: ?Navigation = null,
    navigation_enabled: bool = false,
    retained: [16]Retained = @splat(.{}),
    retained_clock: u64 = 0,
    const zero_rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    pub const picker_row_height: f32 = 48;

    pub const Identity = struct {
        runtime_kind: transcript.Id = .{},
        required_runtime_version: transcript.Id = .{},
        model_provider: transcript.Id = .{},
        model_id: transcript.Id = .{},
        effort: transcript.Id = .{},
        account_ref: transcript.Id = .{},
        workspace: transcript.Id = .{},
        capability_revision: u32 = 1,
        pub fn from(value: contract.Selection) !Identity {
            var result: Identity = .{};
            inline for (@typeInfo(Identity).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "capability_revision")) {
                    result.capability_revision = value.capability_revision;
                } else {
                    const bytes = if (comptime std.mem.eql(u8, field.name, "workspace")) value.workspace.value else @field(value, field.name);
                    @field(result, field.name) = if (bytes.len == 0) .{} else try transcript.Id.init(bytes);
                }
            }
            return result;
        }
        pub fn selection(self: *const Identity) contract.Selection {
            var result: contract.Selection = undefined;
            inline for (@typeInfo(contract.Selection).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "capability_revision")) {
                    result.capability_revision = self.capability_revision;
                } else if (comptime std.mem.eql(u8, field.name, "workspace")) {
                    result.workspace = .{ .value = self.workspace.slice() };
                } else @field(result, field.name) = @field(self, field.name).slice();
            }
            return result;
        }
    };
    pub const Model = struct {
        identity: Identity,
        efforts: [8]transcript.Id = @splat(.{}),
        effort_count: usize = 0,
        readiness: contract.Readiness,
        reason: [256]u8 = undefined,
        reason_len: usize = 0,
        synthetic: bool = false,
    };
    pub const Navigation = union(enum) { new_project, new_thread, project: usize, thread: usize };
    pub const Entry = struct { id: transcript.Id = .{}, label: [160]u8 = undefined, len: usize = 0 };
    const Retained = struct {
        id: transcript.Id = .{},
        editor: ?Composer = null,
        revision: u64 = 0,
        scroll: f32 = 0,
        follow: bool = true,
        position: ?ThreadHistory = null,
        used: u64 = 0,
        selection: ?Identity = null,
    };

    pub fn selectThread(self: *View, id: transcript.Id) !void {
        if (self.active_thread.eql(id.slice())) return;
        if (self.active_thread.len == 0) {
            self.active_thread = id;
            return;
        }
        var incoming: ?usize = null;
        var replacement: ?usize = null;
        for (self.retained, 0..) |slot, index| {
            if (slot.id.eql(id.slice())) incoming = index;
            if (slot.editor == null) replacement = index;
        }
        const index = incoming orelse replacement orelse return error.DraftRetentionFull;
        const next = if (incoming) |found| self.retained[found] else Retained{ .editor = try Composer.init(self.allocator) };
        if (self.active_thread.len == 0) {
            self.editor.deinit();
            self.retained[index] = .{};
        } else {
            self.retained_clock += 1;
            self.retained[index] = .{ .id = self.active_thread, .editor = self.editor, .revision = self.revision, .scroll = self.editor_view.scroll, .follow = self.follow_latest, .position = self.history_position, .selection = self.selected, .used = self.retained_clock };
        }
        self.editor = next.editor.?;
        self.selected = next.selection;
        self.revision = next.revision;
        self.editor_view.deinit();
        self.editor_view = .{ .scroll = next.scroll };
        self.follow_latest = next.follow;
        self.history_position = next.position;
        self.history_restore = next.position != null;
        self.active_thread = id;
        self.rendered_selection = null;
        self.preedit_len = 0;
        self.preedit_changed = true;
        self.clearHistory();
    }

    fn setupInsert(self: *View, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const len = &self.setup_lengths[self.setup_field];
        const start = if (self.setup_select_all) 0 else len.*;
        if (start + bytes.len > 512) return error.TextTooLarge;
        @memcpy(self.setup_fields[self.setup_field][start..][0..bytes.len], bytes);
        len.* = start + bytes.len;
        self.setup_select_all = false;
    }
    pub const HistoryMove = enum { previous, next, first, latest };
    pub const ThreadHistory = struct {
        message: transcript.Id,
        role: []const u8 = "assistant",
        message_ordinal: u64 = 0,
        block: transcript.Id,
        block_ordinal: u64,
        revision: u64,
        cursor: struct { block: u32, byte: u32 = 0 },
        pixel_offset: f32 = 0,
        selection: ?struct { source: [16]u8, revision: u64, anchor: u32, caret: u32 } = null,
    };
    pub const TaskCancel = struct { id: [32]u8, revision: u64 };
    pub const TaskLine = struct {
        bytes: [320]u8 = undefined,
        len: usize = 0,
        cancel: ?TaskCancel = null,
        cancel_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };

    pub fn init(allocator: std.mem.Allocator) !View {
        var editor = try Composer.init(allocator);
        errdefer editor.deinit();
        return .{ .allocator = allocator, .editor = editor, .scratch = try allocator.alloc(u8, 64 * 1024 + 1) };
    }

    pub fn deinit(self: *View) void {
        for (&self.retained) |*slot| if (slot.editor) |*editor| editor.deinit();
        for (&self.rich_tiles) |*tile| tile.deinit();
        self.custom_tile.deinit();
        if (self.preedit_layout) |layout| c.spica_text_layout_release(layout);
        self.editor_view.deinit();
        self.labels.deinit();
        self.editor.deinit();
        self.allocator.free(self.scratch);
    }

    fn changed(self: *View) void {
        self.revision += 1;
        self.editor_view.changed = true;
        self.editor_view.preferred_x = null;
        self.notice = null;
        self.reveal_caret = true;
    }

    pub fn insert(self: *View, bytes: []const u8, kind: @import("../text/composer.zig").GroupKind) !void {
        try self.editor.insert(bytes, kind);
        self.changed();
    }

    fn focus(self: *View, window: *c.SDL_Window, enabled: bool) !void {
        self.focused = enabled;
        self.preedit_len = 0;
        self.preedit_changed = true;
        if (enabled and self.window_active) {
            if (!c.SDL_StartTextInput(window)) return error.TextInputStart;
        } else if (!c.SDL_StopTextInput(window)) return error.TextInputStop;
    }

    fn releasePointer(self: *View) void {
        self.dragging = false;
        self.transcript_drag = null;
        _ = c.SDL_CaptureMouse(false);
    }

    pub fn takeIntent(self: *View) ?Intent {
        const value = self.intent;
        self.intent = null;
        return value;
    }
    pub fn takeTaskCancel(self: *View) ?TaskCancel {
        const value = self.task_cancel;
        self.task_cancel = null;
        return value;
    }

    fn request(self: *View, intent: Intent) void {
        const enabled = switch (intent) {
            .send => self.can_send and self.editor.len != 0,
            .cancel => self.can_cancel,
            .allow, .deny => self.can_approve,
        };
        if (enabled) self.intent = intent else self.notice = if (intent == .send) self.send_disabled_reason orelse (if (self.editor.len == 0) "Write a message before sending" else "Send is unavailable. Check the connection and selected model.") else "Action unavailable in the current durable state";
    }

    /// Worker completions carry explicit source/revision/generation identity.
    /// Caller discards stale generations before admission into this root.
    pub const TileInfo = struct { message: transcript.Id, block: transcript.Id, ordinal: u64, message_ordinal: u64, role: []const u8, backward: bool };

    fn removeTile(self: *View, index: usize) void {
        const height = self.rich_tiles[index].height() + self.rich_tiles[index].headingHeight() + 8;
        var y: f32 = 0;
        for (self.rich_tiles[0..index]) |*tile| y += tile.height() + tile.headingHeight() + 8;
        if (!self.follow_latest and y < self.transcript_scroll) self.transcript_scroll = @max(0, self.transcript_scroll - height);
        self.rich_tiles[index].deinit();
        var at = index;
        while (at + 1 < self.rich_count) : (at += 1) self.rich_tiles[at] = self.rich_tiles[at + 1];
        self.rich_count -= 1;
        self.rich_tiles[self.rich_count] = .{};
        self.transcript_drag = null;
    }

    pub fn admitTile(self: *View, text: *c.SpicaText, tile: *const presentation.Tile, width: f32, info: TileInfo) !void {
        var index: usize = 0;
        while (index < self.rich_count) {
            const slot = &self.rich_tiles[index];
            if (slot.canonical_block.eql(info.block.slice()) and slot.key != null and slot.key.?.revision != tile.key.revision) {
                self.removeTile(index);
                continue;
            }
            if (slot.canonical_block.eql(info.block.slice()) and slot.block_index == tile.block.index and slot.start_byte == tile.start_byte) {
                try slot.update(text, tile, width);
                applyTileInfo(slot, info, tile);
                self.applySelection(slot);
                return;
            }
            index += 1;
        }
        var incoming: transcript.RichTile = .{};
        errdefer incoming.deinit();
        try incoming.update(text, tile, width);
        applyTileInfo(&incoming, info, tile);
        if (self.rich_count == self.rich_tiles.len) self.removeTile(if (info.backward) self.rich_count - 1 else 0);
        index = 0;
        while (index < self.rich_count) : (index += 1) {
            const slot = &self.rich_tiles[index];
            if (slot.message_ordinal > info.message_ordinal or (slot.message_ordinal == info.message_ordinal and (slot.canonical_ordinal > info.ordinal or (slot.canonical_ordinal == info.ordinal and (slot.block_index > tile.block.index or (slot.block_index == tile.block.index and slot.start_byte > tile.start_byte)))))) break;
        }
        var y: f32 = 0;
        for (self.rich_tiles[0..index]) |*slot| y += slot.height() + slot.headingHeight() + 8;
        if (!self.follow_latest and self.rich_count != 0 and y <= self.transcript_scroll) self.transcript_scroll += incoming.height() + incoming.headingHeight() + 8;
        var at = self.rich_count;
        while (at > index) : (at -= 1) self.rich_tiles[at] = self.rich_tiles[at - 1];
        self.rich_tiles[index] = incoming;
        self.rich_count += 1;
        self.rich_next = 0;
        self.applySelection(&self.rich_tiles[index]);
    }

    fn applyTileInfo(slot: *transcript.RichTile, info: TileInfo, tile: *const presentation.Tile) void {
        slot.message = info.message;
        slot.canonical_block = info.block;
        slot.canonical_ordinal = info.ordinal;
        slot.message_ordinal = info.message_ordinal;
        slot.role = info.role;
        slot.heading = tile.block.index == 0 and tile.start_byte == 0;
    }

    pub fn clearHistory(self: *View) void {
        for (&self.rich_tiles) |*tile| tile.deinit();
        self.rich_count = 0;
        self.rich_next = 0;
        self.transcript_drag = null;
        self.transcript_scroll = 0;
    }

    fn applySelection(self: *View, tile: *transcript.RichTile) void {
        const selection = self.rendered_selection orelse {
            tile.selected = false;
            return;
        };
        const key = tile.key orelse return;
        if (!selection.sameSource(key)) {
            tile.selected = false;
            return;
        }
        const start = tile.projection_start + tile.start_byte;
        const end = start + @as(u32, @intCast(tile.length));
        const low = @min(selection.anchor, selection.caret);
        const high = @max(selection.anchor, selection.caret);
        tile.selected = low < end and high > start;
        tile.anchor = std.math.clamp(low, start, end) - start;
        tile.caret = std.math.clamp(high, start, end) - start;
    }

    fn selectTile(self: *View, tile: *transcript.RichTile, extend: bool) void {
        const key = tile.key orelse return;
        const caret = tile.projection_start + tile.start_byte + @as(u32, @intCast(tile.caret));
        if (extend and self.rendered_selection != null and self.rendered_selection.?.sameSource(key)) {
            self.rendered_selection.?.caret = caret;
        } else self.rendered_selection = .{ .key = key, .anchor = caret, .caret = caret };
        for (self.rich_tiles[0..self.rich_count]) |*slot| self.applySelection(slot);
    }

    pub fn captureHistory(self: *View, tile: *const transcript.RichTile, point: transcript.RichTile.ScrollPoint) void {
        if (tile.message.len == 0 or tile.canonical_block.len == 0) return;
        const key = tile.key orelse return;
        self.history_position = .{
            .message = tile.message,
            .role = tile.role,
            .message_ordinal = tile.message_ordinal,
            .block = tile.canonical_block,
            .block_ordinal = tile.canonical_ordinal,
            .revision = key.revision,
            .cursor = .{ .block = tile.block_index, .byte = tile.start_byte + @as(u32, @intCast(point.byte)) },
            .pixel_offset = point.offset,
            .selection = if (self.rendered_selection) |selection| if (selection.sameSource(key)) .{ .source = selection.key.source, .revision = selection.key.revision, .anchor = selection.anchor, .caret = selection.caret } else null else null,
        };
    }

    fn sameModel(a: Identity, b: Identity) bool {
        return a.runtime_kind.eql(b.runtime_kind.slice()) and a.required_runtime_version.eql(b.required_runtime_version.slice()) and a.model_provider.eql(b.model_provider.slice()) and a.model_id.eql(b.model_id.slice()) and a.account_ref.eql(b.account_ref.slice()) and a.workspace.eql(b.workspace.slice()) and a.capability_revision == b.capability_revision;
    }

    fn pickerMaxScroll(self: *const View) f32 {
        return @max(0, @as(f32, @floatFromInt(self.model_count)) * picker_row_height - self.picker_rows.h);
    }

    pub fn pickerIndexAt(self: *const View, x: f32, y: f32) ?usize {
        if (!widgets.contains(self.picker_rows, x, y)) return null;
        const index: usize = @intFromFloat((y - self.picker_rows.y + self.picker_scroll) / picker_row_height);
        return if (index < self.model_count) index else null;
    }

    /// Visible intersection, shared by automation and pointer hit testing.
    pub fn pickerRowBounds(self: *const View, index: usize) c.SDL_FRect {
        if (index >= self.model_count) return zero_rect;
        const top = self.picker_rows.y + @as(f32, @floatFromInt(index)) * picker_row_height - self.picker_scroll;
        const bottom = @min(top + picker_row_height, self.picker_rows.y + self.picker_rows.h);
        const y = @max(top, self.picker_rows.y);
        return .{ .x = self.picker_rows.x, .y = y, .w = self.picker_rows.w, .h = @max(0, bottom - y) };
    }

    pub fn threadRowBounds(self: *const View, index: usize) c.SDL_FRect {
        if (index >= self.thread_count) return zero_rect;
        const row = self.thread_bounds[index];
        const top = @max(row.y, self.sidebar_rows.y);
        const bottom = @min(row.y + row.h, self.sidebar_rows.y + self.sidebar_rows.h);
        return .{ .x = row.x, .y = top, .w = row.w, .h = @max(0, bottom - top) };
    }

    fn revealPickerRow(self: *View) void {
        const top = @as(f32, @floatFromInt(self.picker_hover)) * picker_row_height;
        if (top < self.picker_scroll) self.picker_scroll = top;
        if (top + picker_row_height > self.picker_scroll + self.picker_rows.h) self.picker_scroll = top + picker_row_height - self.picker_rows.h;
        self.picker_scroll = std.math.clamp(self.picker_scroll, 0, self.pickerMaxScroll());
    }

    fn hasComposer(self: *const View) bool {
        const root = self.custom_root orelse return true;
        for (root.nodes[0..root.count]) |node| if (node.kind == 4) return true;
        return false;
    }

    pub fn handle(self: *View, event: c.SDL_Event, window: *c.SDL_Window, text: *c.SpicaText) !bool {
        switch (event.type) {
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.releasePointer();
                self.window_active = false;
                self.preedit_len = 0;
                self.preedit_changed = true;
                if (!c.SDL_StopTextInput(window)) return error.TextInputStop;
                return true;
            },
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                self.window_active = true;
                if (self.focused and !c.SDL_StartTextInput(window)) return error.TextInputStart;
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button != c.SDL_BUTTON_LEFT) return false;
                if (self.custom_root == null) {
                    const x = event.button.x;
                    const y = event.button.y;
                    if (self.setup_open) {
                        if (widgets.contains(self.setup_close_bounds, x, y)) self.setup_open = false;
                        if (widgets.contains(self.setup_runtime_bounds, x, y)) self.setup_runtime = if (self.setup_runtime == .codex) .opencode else .codex;
                        for (self.setup_field_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.setup_field = index;
                            self.setup_select_all = true;
                        };
                        for (self.setup_button_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            if (self.setup_runtime == .opencode and (index == 1 or index == 2)) break;
                            self.setup_action = switch (index) {
                                0 => .configure,
                                1 => .browser,
                                2 => .device,
                                else => .refresh,
                            };
                        };
                        return true;
                    }
                    // An open menu owns pointer input, including outside dismissal.
                    if (self.picker_open) {
                        if (self.pickerIndexAt(x, y)) |index| self.selected = self.models[index].identity;
                        self.picker_open = false;
                        return true;
                    }
                    if (widgets.contains(self.picker_bounds, x, y)) {
                        self.picker_open = true;
                        self.picker_hover = 0;
                        for (self.models[0..self.model_count], 0..) |*model, index| if (self.selected) |*selected| {
                            if (sameModel(model.identity, selected.*)) self.picker_hover = index;
                        };
                        self.revealPickerRow();
                        return true;
                    }
                    if (widgets.contains(self.effort_bounds, x, y)) {
                        if (self.selected) |*selected| for (self.models[0..self.model_count]) |model| {
                            if (!sameModel(model.identity, selected.*)) continue;
                            for (model.efforts[0..model.effort_count], 0..) |effort, index| if (effort.eql(selected.effort.slice())) {
                                selected.effort = model.efforts[(index + 1) % model.effort_count];
                                break;
                            };
                        };
                        return true;
                    }
                    if (widgets.contains(self.setup_bounds, x, y)) {
                        self.setup_open = true;
                        self.picker_open = false;
                        self.setup_action = .status;
                        try self.focus(window, true);
                        return true;
                    }
                    if (widgets.contains(self.follow_bounds, x, y)) {
                        self.history_move = .latest;
                        return true;
                    }
                    if (self.navigation_enabled and widgets.contains(self.sidebar_bounds, x, y)) {
                        if (widgets.contains(self.new_project_bounds, x, y)) self.navigation = .new_project;
                        if (widgets.contains(self.new_thread_bounds, x, y)) self.navigation = .new_thread;
                        if (widgets.contains(self.sidebar_rows, x, y)) {
                            for (self.project_bounds[0..self.project_count], 0..) |box, index| if (widgets.contains(box, x, y)) {
                                self.navigation = .{ .project = index };
                            };
                            for (self.thread_bounds[0..self.thread_count], 0..) |box, index| if (widgets.contains(box, x, y)) {
                                self.navigation = .{ .thread = index };
                            };
                        }
                        return true;
                    }
                }
                if (self.custom_root) |root| {
                    for (root.nodes[0..root.count], 0..) |node, index| {
                        const box = self.custom_bounds[index];
                        if (node.kind == 3 and widgets.contains(.{ .x = box.x, .y = box.y, .w = box.width, .h = box.height }, event.button.x, event.button.y)) {
                            self.custom_action = index;
                            return true;
                        }
                    }
                }
                if (self.custom_root == null and self.tasks_enabled) for (self.tasks[0..self.task_count]) |task| {
                    if (task.cancel) |cancel| if (widgets.contains(task.cancel_bounds, event.button.x, event.button.y)) {
                        self.task_cancel = cancel;
                        return true;
                    };
                };
                for (self.controls, 0..) |bounds, index| {
                    if (widgets.contains(bounds, event.button.x, event.button.y)) {
                        self.request(@enumFromInt(index));
                        return true;
                    }
                }
                if (widgets.contains(self.transcript_bounds, event.button.x, event.button.y)) {
                    try self.focus(window, false);
                    for (self.rich_tiles[0..self.rich_count], 0..) |*tile, index| {
                        if (tile.hit(event.button.x, event.button.y, false)) {
                            self.transcript_drag = index;
                            self.selectTile(tile, c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0);
                        }
                    }
                    if (self.transcript_drag != null) _ = c.SDL_CaptureMouse(true);
                    return true;
                }
                const inside = widgets.contains(self.editor_view.bounds, event.button.x, event.button.y);
                try self.focus(window, inside);
                if (inside) {
                    const extend = c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0;
                    if (self.editor_view.offsetAt(event.button.x, event.button.y)) |at| self.editor.setCaret(at, extend);
                    self.reveal_caret = true;
                    self.dragging = true;
                    if (!c.SDL_CaptureMouse(true)) self.notice = "Pointer capture unavailable";
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button != c.SDL_BUTTON_LEFT or (!self.dragging and self.transcript_drag == null)) return false;
                self.releasePointer();
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (self.custom_root == null and self.picker_open) {
                    if (self.pickerIndexAt(event.motion.x, event.motion.y)) |index| self.picker_hover = index;
                    return true;
                }

                if (self.transcript_drag) |index| {
                    const tile = &self.rich_tiles[index];
                    _ = tile.hit(std.math.clamp(event.motion.x, tile.bounds.x, tile.bounds.x + tile.bounds.w - 1), std.math.clamp(event.motion.y, tile.bounds.y, tile.bounds.y + tile.bounds.h - 1), true);
                    self.selectTile(tile, true);
                    return true;
                }
                if (!self.dragging) return false;
                if (self.editor_view.offsetAt(event.motion.x, event.motion.y)) |at| self.editor.setCaret(at, true);
                self.reveal_caret = true;
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const wheel_direction: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                if (self.custom_root == null and self.setup_open) return true;
                if (self.custom_root == null and self.picker_open) {
                    if (widgets.contains(self.picker_menu, event.wheel.mouse_x, event.wheel.mouse_y)) self.picker_scroll = std.math.clamp(self.picker_scroll - event.wheel.y * wheel_direction * picker_row_height, 0, self.pickerMaxScroll());
                    return true;
                }
                if (self.custom_root == null and widgets.contains(self.sidebar_bounds, event.wheel.mouse_x, event.wheel.mouse_y)) {
                    const height = @as(f32, @floatFromInt(self.project_count)) * 30 + @as(f32, @floatFromInt(self.thread_count)) * 36 + 32;
                    self.sidebar_scroll = std.math.clamp(self.sidebar_scroll - event.wheel.y * wheel_direction * 36, 0, @max(0, height - self.sidebar_rows.h));
                    return true;
                }
                if (widgets.contains(self.transcript_bounds, event.wheel.mouse_x, event.wheel.mouse_y)) {
                    const direction: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                    if (event.wheel.y * direction > 0 and self.transcript_scroll == 0) self.history_move = .previous;
                    if (event.wheel.y * direction < 0 and self.transcript_scroll >= @max(0, self.history_height - self.transcript_bounds.h)) self.history_move = .next;
                    self.transcript_scroll = @max(0, self.transcript_scroll - event.wheel.y * direction * 44);
                    self.follow_latest = false;
                    return true;
                }
                if (!widgets.contains(self.editor_view.bounds, event.wheel.mouse_x, event.wheel.mouse_y)) return false;
                const direction: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                self.editor_view.scroll = @max(0, self.editor_view.scroll - event.wheel.y * direction * 44);
                self.reveal_caret = false;
                return true;
            },
            c.SDL_EVENT_TEXT_EDITING => {
                if (self.custom_root == null and (self.setup_open or self.picker_open)) return true;
                if (!self.hasComposer() or !self.focused or !self.window_active) return false;
                const bytes = std.mem.span(event.edit.text);
                self.preedit_changed = true;
                if (bytes.len > self.preedit.len or !std.unicode.utf8ValidateSlice(bytes)) {
                    self.preedit_len = 0;
                    self.notice = "Composition exceeds presentation budget";
                } else {
                    @memcpy(self.preedit[0..bytes.len], bytes);
                    self.preedit_len = bytes.len;
                }
                return true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (self.custom_root == null and self.picker_open) return true;
                if (self.setup_open and self.custom_root == null) {
                    try self.setupInsert(std.mem.span(event.text.text));
                    return true;
                }
                if (!self.hasComposer() or !self.focused or !self.window_active) return false;
                const kind: @import("../text/composer.zig").GroupKind = if (self.preedit_len != 0) .ime else .typing;
                self.preedit_len = 0;
                self.preedit_changed = true;
                try self.insert(std.mem.span(event.text.text), kind);
                return true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mods = event.key.mod;
                const ctrl = mods & c.SDL_KMOD_CTRL != 0;
                const shift = mods & c.SDL_KMOD_SHIFT != 0;
                if (self.setup_open and self.custom_root == null) {
                    if (key == c.SDLK_ESCAPE) self.setup_open = false;
                    if (key == c.SDLK_TAB) {
                        self.setup_field = (self.setup_field + (if (shift) @as(usize, 3) else 1)) % 4;
                        self.setup_select_all = true;
                    }
                    if (ctrl and key == c.SDLK_A) self.setup_select_all = true;
                    if (key == c.SDLK_RETURN) self.setup_action = .configure;
                    if (key == c.SDLK_BACKSPACE or (key == c.SDLK_DELETE and self.setup_select_all)) {
                        const len = &self.setup_lengths[self.setup_field];
                        if (self.setup_select_all) {
                            len.* = 0;
                            self.setup_select_all = false;
                        } else if (len.* > 0) {
                            len.* -= 1;
                            while (len.* > 0 and self.setup_fields[self.setup_field][len.*] & 0xc0 == 0x80) len.* -= 1;
                        }
                    }
                    if (ctrl and key == c.SDLK_V) {
                        const value = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                        defer c.SDL_free(value);
                        try self.setupInsert(std.mem.span(value));
                    }
                    return true;
                }
                if (self.picker_open and self.custom_root == null) {
                    switch (key) {
                        c.SDLK_ESCAPE => self.picker_open = false,
                        c.SDLK_UP => self.picker_hover -|= 1,
                        c.SDLK_DOWN => self.picker_hover = @min(self.model_count -| 1, self.picker_hover + 1),
                        c.SDLK_RETURN => {
                            if (self.picker_hover < self.model_count) self.selected = self.models[self.picker_hover].identity;
                            self.picker_open = false;
                        },
                        else => {},
                    }
                    self.revealPickerRow();
                    return true;
                }
                if (!ctrl and mods & c.SDL_KMOD_ALT != 0 and self.window_active) {
                    self.history_move = switch (key) {
                        c.SDLK_PAGEUP => .previous,
                        c.SDLK_PAGEDOWN => .next,
                        c.SDLK_HOME => .first,
                        c.SDLK_END => .latest,
                        else => null,
                    };
                    if (self.history_move != null) return true;
                }
                switch (key) {
                    c.SDLK_F6 => {
                        self.request(.cancel);
                        return true;
                    },
                    c.SDLK_F7 => {
                        self.request(.allow);
                        return true;
                    },
                    c.SDLK_F8 => {
                        self.request(.deny);
                        return true;
                    },
                    else => {},
                }
                if (ctrl and key == c.SDLK_C and !self.focused and self.window_active) {
                    if (self.rendered_selection) |selection| self.copy_selection = selection;
                    return true;
                }
                if (!self.hasComposer()) return false;
                if (key == c.SDLK_TAB) {
                    try self.focus(window, !self.focused);
                    return true;
                }
                if (key == c.SDLK_ESCAPE) {
                    self.preedit_len = 0;
                    self.preedit_changed = true;
                    self.releasePointer();
                    self.notice = null;
                    return true;
                }
                if (!self.focused or !self.window_active or self.preedit_len != 0) return false;
                if (ctrl) switch (key) {
                    c.SDLK_A => {
                        self.editor.selectAll();
                        self.reveal_caret = true;
                    },
                    c.SDLK_C => try clipboard.copySelection(&self.editor, self.scratch),
                    c.SDLK_X => {
                        try clipboard.copySelection(&self.editor, self.scratch);
                        if (self.editor.selection().start != self.editor.selection().end) {
                            try self.editor.backspace();
                            self.changed();
                        }
                    },
                    c.SDLK_V => {
                        const value = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                        defer c.SDL_free(value);
                        try self.insert(std.mem.span(value), .paste);
                    },
                    c.SDLK_Z => {
                        const edited = if (shift) self.editor.redo() else self.editor.undo();
                        if (edited) self.changed();
                    },
                    c.SDLK_Y => if (self.editor.redo()) self.changed(),
                    else => {},
                };
                switch (key) {
                    c.SDLK_LEFT, c.SDLK_RIGHT => {
                        const direction: @import("../text/composer.zig").Direction = if (key == c.SDLK_LEFT) .backward else .forward;
                        if (ctrl) self.editor.moveWord(direction, shift) else self.editor.moveGrapheme(direction, shift);
                        self.editor_view.preferred_x = null;
                        self.reveal_caret = true;
                    },
                    c.SDLK_UP, c.SDLK_DOWN => {
                        try self.editor_view.moveVertical(text, &self.editor, 16, key == c.SDLK_DOWN, shift);
                        self.reveal_caret = true;
                    },
                    c.SDLK_HOME, c.SDLK_END => {
                        try self.editor_view.moveLineEdge(text, &self.editor, 16, key == c.SDLK_END, ctrl, shift);
                        self.reveal_caret = true;
                    },
                    c.SDLK_BACKSPACE, c.SDLK_DELETE => {
                        if (ctrl) try self.editor.deleteWord(if (key == c.SDLK_BACKSPACE) .backward else .forward) else if (key == c.SDLK_BACKSPACE) try self.editor.backspace() else try self.editor.deleteForward();
                        self.changed();
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                        if (shift) try self.insert("\n", .typing) else self.request(.send);
                    },
                    else => {},
                }
                return true;
            },
            else => return false,
        }
    }

    fn ensurePreedit(self: *View, text: *c.SpicaText, width: f32) !void {
        if (!self.preedit_changed and self.preedit_width == width) return;
        if (self.preedit_layout) |layout| c.spica_text_layout_release(layout);
        self.preedit_layout = null;
        if (self.preedit_len != 0) {
            self.preedit_layout = c.spica_text_layout_create(text, &self.preedit, self.preedit_len, width, 16, false) orelse return error.PreeditLayout;
        }
        self.preedit_width = width;
        self.preedit_changed = false;
    }

    fn workspaceName(self: *const View) []const u8 {
        const label = self.workspace_label[0..self.workspace_label_len];
        const end = std.mem.indexOf(u8, label, "  •  ") orelse label.len;
        const path = std.mem.trimEnd(u8, label[0..end], "/");
        if (path.len == 0) return if (label.len == 0) "Workspace" else "/";
        const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
        return path[start..];
    }

    fn runtimeName(identity: *const Identity) []const u8 {
        return if (identity.runtime_kind.eql("opencode")) "OpenCode" else if (identity.runtime_kind.eql("codex")) "Codex" else if (identity.runtime_kind.eql("fake")) "Demo" else identity.runtime_kind.slice();
    }

    const EmptyState = struct { description: []const u8, context: []const u8 };
    fn emptyState(self: *const View, buffer: []u8) !EmptyState {
        if (self.selected) |*selected| {
            if (selected.runtime_kind.eql("fake")) return .{
                .description = self.send_disabled_reason orelse "Try a message to explore the conversation controls.",
                .context = "Demo is synthetic. Connect a coding provider to work on files.",
            };
            return .{
                .description = self.send_disabled_reason orelse if (self.can_send) "Describe a change, ask a question, or continue your work." else "Preparing the selected model…",
                .context = try std.fmt.bufPrint(buffer, "{s} · {s} · {s}", .{ runtimeName(selected), selected.model_id.slice(), self.workspaceName() }),
            };
        }
        return .{
            .description = self.send_disabled_reason orelse "Choose a model below to start a conversation.",
            .context = "Manage your runtime and workspace in Connection.",
        };
    }

    fn modelSubtitle(model: *const Model, buffer: []u8) ![]const u8 {
        if (model.readiness == .unavailable and model.reason_len != 0) return std.fmt.bufPrint(buffer, "{s} · unavailable · {s}", .{ model.identity.model_provider.slice(), model.reason[0..model.reason_len] });
        return std.fmt.bufPrint(buffer, "{s} · {d} effort option{s} · {s}", .{ model.identity.model_provider.slice(), model.effort_count, if (model.effort_count == 1) "" else "s", switch (model.readiness) {
            .ready => "ready",
            .unknown => "availability unverified",
            .unavailable => "unavailable",
        } });
    }

    fn drawChrome(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        const sidebar = Layout.sidebarWidth(bounds.header.width);
        const height = bounds.composer.y + bounds.composer.height + 16;
        self.sidebar_bounds = .{ .x = 0, .y = 0, .w = sidebar, .h = height };
        try widgets.panel(renderer, self.sidebar_bounds, 0, .{ .r = 15, .g = 18, .b = 23 });
        try self.labels.draw(text, "Spica", 20, 20, 18, foreground);
        self.new_thread_bounds = .{ .x = 12, .y = 64, .w = sidebar - 24, .h = 34 };
        self.new_project_bounds = .{ .x = 12, .y = 104, .w = sidebar - 24, .h = 30 };
        try widgets.panel(renderer, self.new_thread_bounds, 6, .{ .r = 35, .g = 40, .b = 49 });
        try self.labels.draw(text, "+ New chat", 24, 73, 13, foreground);
        try self.labels.draw(text, "+ New project", 24, 112, 12, muted);
        try self.labels.draw(text, "PROJECTS", 20, 151, 10, muted);
        self.sidebar_rows = .{ .x = 8, .y = 174, .w = sidebar - 16, .h = @max(0, height - 230) };
        const rows_height = @as(f32, @floatFromInt(self.project_count)) * 30 + @as(f32, @floatFromInt(self.thread_count)) * 36 + 32;
        self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, rows_height - self.sidebar_rows.h));
        var clip = widgets.Clip.push(renderer, self.sidebar_rows);
        defer clip.restore(renderer);
        var y = self.sidebar_rows.y - self.sidebar_scroll;
        self.project_bounds = @splat(zero_rect);
        self.thread_bounds = @splat(zero_rect);
        var project_name: []const u8 = "Workspace";
        var thread_name: []const u8 = "New chat";
        for (self.projects[0..self.project_count], 0..) |*entry, index| {
            const active = entry.id.eql(self.active_project.slice());
            if (active) project_name = entry.label[0..entry.len];
            self.project_bounds[index] = .{ .x = 12, .y = y, .w = sidebar - 24, .h = 28 };
            if (y + 28 > self.sidebar_rows.y and y < self.sidebar_rows.y + self.sidebar_rows.h) try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], 20, y + 7, sidebar - 40, 12, if (active) foreground else muted);
            y += 30;
        }
        try self.labels.draw(text, "CHATS", 20, y + 12, 10, muted);
        y += 32;
        for (self.threads[0..self.thread_count], 0..) |*entry, index| {
            const active = entry.id.eql(self.active_thread.slice());
            if (active) thread_name = entry.label[0..entry.len];
            const row = c.SDL_FRect{ .x = 12, .y = y, .w = sidebar - 24, .h = 32 };
            self.thread_bounds[index] = row;
            if (y + 32 > self.sidebar_rows.y and y < self.sidebar_rows.y + self.sidebar_rows.h) {
                if (active) try widgets.panel(renderer, row, 6, .{ .r = 39, .g = 45, .b = 56 });
                try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], 22, y + 8, sidebar - 44, 13, if (active) foreground else muted);
            }
            y += 36;
        }
        clip.restore(renderer);
        try self.labels.draw(text, "Enter to send", 20, height - 44, 11, muted);
        try self.labels.draw(text, "Shift+Enter newline", 20, height - 26, 10, muted);
        self.setup_bounds = .{ .x = bounds.header.width - 134, .y = 16, .w = 118, .h = 32 };
        try widgets.panel(renderer, self.setup_bounds, 5, .{ .r = 35, .g = 40, .b = 49 });
        try self.labels.draw(text, "Connection", self.setup_bounds.x + 18, 25, 12, foreground);
        var title: [512]u8 = undefined;
        const label = try std.fmt.bufPrint(&title, "{s}  /  {s}", .{ project_name, thread_name });
        const header_x = sidebar + 24;
        try self.labels.drawFitted(renderer, text, label, header_x, 15, self.setup_bounds.x - header_x - 16, 16, foreground);
        var workspace_info: [1024]u8 = undefined;
        const workspace_status = try std.fmt.bufPrint(&workspace_info, "{s}  ·  {s}", .{ self.workspaceName(), @import("../text/utf8.zig").prefix(self.status, 128) });
        try self.labels.drawFitted(renderer, text, workspace_status, header_x, 40, self.setup_bounds.x - header_x - 16, 11, muted);
        self.follow_bounds = if (self.follow_latest) zero_rect else .{ .x = bounds.transcript.x + bounds.transcript.width - 128, .y = bounds.transcript.y + bounds.transcript.height - 32, .w = 128, .h = 28 };
        for (self.tasks[0..self.task_count], 0..) |*task, index| {
            const task_y = bounds.transcript.y + @as(f32, @floatFromInt(index)) * 24;
            try self.labels.drawFitted(renderer, text, task.bytes[0..task.len], bounds.transcript.x, task_y, bounds.transcript.width - 84, 12, muted);
            task.cancel_bounds = .{ .x = bounds.transcript.x + bounds.transcript.width - 76, .y = task_y, .w = 76, .h = 20 };
            if (task.cancel != null) {
                try widgets.panel(renderer, task.cancel_bounds, 3, .{ .r = 35, .g = 40, .b = 49 });
                try self.labels.draw(text, "Cancel task", task.cancel_bounds.x + 4, task_y + 2, 11, foreground);
            }
        }
    }

    fn drawComposerControls(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, panel: c.SDL_FRect, foreground: Color, muted: Color) !void {
        self.controls = @splat(zero_rect);
        const y = panel.y + panel.h - 62;
        const primary: usize = if (self.can_cancel) 1 else 0;
        self.controls[primary] = .{ .x = panel.x + panel.w - 90, .y = y, .w = 80, .h = 30 };
        self.effort_bounds = .{ .x = self.controls[primary].x - 114, .y = y, .w = 104, .h = 30 };
        const model_x = panel.x + 10;
        const model_width = @min(270, @max(0, self.effort_bounds.x - 10 - model_x));
        self.picker_bounds = .{ .x = model_x, .y = y, .w = model_width, .h = 30 };
        // Keep menu geometry current while closed, so first-open keyboard
        // reveal uses the same viewport as the next paint.
        const menu_height = @min(344, @max(96, y - 80));
        self.picker_menu = .{ .x = panel.x, .y = y - menu_height - 6, .w = @min(600, panel.w), .h = menu_height };
        self.picker_rows = .{ .x = self.picker_menu.x + 8, .y = self.picker_menu.y + 38, .w = self.picker_menu.w - 16, .h = menu_height - 64 };

        try widgets.panel(renderer, self.picker_bounds, 5, .{ .r = 35, .g = 40, .b = 49 });
        try widgets.panel(renderer, self.effort_bounds, 5, .{ .r = 35, .g = 40, .b = 49 });
        const label = if (self.selected) |*selected| (if (selected.runtime_kind.eql("fake")) "Demo · synthetic" else selected.model_id.slice()) else "Choose model";
        try self.labels.drawFitted(renderer, text, label, self.picker_bounds.x + 8, y + 8, model_width - 32, 12, foreground);
        // A native chevron avoids system font discovery for a decorative glyph
        // absent from the bundled proportional font. No extra face or buffer.
        const chevron = [_]c.SDL_FPoint{
            .{ .x = self.picker_bounds.x + model_width - 18, .y = y + 13 },
            .{ .x = self.picker_bounds.x + model_width - 14, .y = y + 17 },
            .{ .x = self.picker_bounds.x + model_width - 10, .y = y + 13 },
        };
        if (!c.SDL_SetRenderDrawColor(renderer, foreground.r, foreground.g, foreground.b, 255) or !c.SDL_RenderLines(renderer, &chevron, chevron.len)) return error.ChevronDraw;
        var effort_label: [320]u8 = undefined;
        const effort = if (self.selected) |*selected| try std.fmt.bufPrint(&effort_label, "{s}  ↻", .{selected.effort.slice()}) else "Effort";
        try self.labels.drawFitted(renderer, text, effort, self.effort_bounds.x + 8, y + 8, 86, 12, muted);
        const enabled = if (primary == 1) self.can_cancel else self.can_send and self.editor.len != 0;
        try widgets.panel(renderer, self.controls[primary], 5, if (enabled) .{ .r = 56, .g = 83, .b = 138 } else .{ .r = 35, .g = 40, .b = 49 });
        try self.labels.draw(text, if (primary == 1) "Stop F6" else "Send ↑", self.controls[primary].x + 12, y + 8, 12, if (enabled) foreground else muted);
        if (self.can_approve) {
            try self.labels.drawFitted(renderer, text, "Approval needed", panel.x + 12, y - 28, panel.w - 206, 12, foreground);
            for (2..4) |index| {
                self.controls[index] = .{ .x = panel.x + panel.w - 188 + @as(f32, @floatFromInt(index - 2)) * 90, .y = y - 34, .w = 80, .h = 28 };
                try widgets.panel(renderer, self.controls[index], 4, .{ .r = 51, .g = 69, .b = 105 });
                try self.labels.draw(text, if (index == 2) "Allow F7" else "Deny F8", self.controls[index].x + 10, y - 27, 12, foreground);
            }
        }
        const guidance = self.send_disabled_reason orelse if (self.can_cancel) "Working · Stop cancels the current run" else if (self.selected == null) "Choose a model, or open Connection to refresh models" else if (!self.can_send) self.status else if (self.editor.len == 0) "Write a message · Enter sends · Shift+Enter adds a line" else "Enter to send · Shift+Enter for a new line";
        try self.labels.drawFitted(renderer, text, guidance, panel.x + 2, panel.y + panel.h - 16, panel.w - 4, 11, muted);
    }

    fn drawPicker(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        const height = @min(344, @max(96, self.picker_bounds.y - 80));
        self.picker_menu = .{ .x = bounds.composer.x, .y = self.picker_bounds.y - height - 6, .w = @min(600, bounds.composer.width), .h = height };
        const menu = self.picker_menu;
        self.picker_rows = .{ .x = menu.x + 8, .y = menu.y + 38, .w = menu.w - 16, .h = menu.h - 64 };
        self.picker_scroll = std.math.clamp(self.picker_scroll, 0, self.pickerMaxScroll());
        try widgets.panel(renderer, menu, 8, .{ .r = 39, .g = 45, .b = 56 });
        try self.labels.draw(text, "Choose model", menu.x + 14, menu.y + 12, 13, foreground);
        var clip = widgets.Clip.push(renderer, self.picker_rows);
        defer clip.restore(renderer);
        if (self.model_count == 0) try self.labels.drawFitted(renderer, text, "No models. Open Connection → Refresh models.", self.picker_rows.x + 6, self.picker_rows.y + 10, self.picker_rows.w - 12, 12, foreground);
        for (self.models[0..self.model_count], 0..) |*model, index| {
            const y = self.picker_rows.y + @as(f32, @floatFromInt(index)) * picker_row_height - self.picker_scroll;
            if (y + picker_row_height <= self.picker_rows.y or y >= self.picker_rows.y + self.picker_rows.h) continue;
            if (index == self.picker_hover) try widgets.panel(renderer, .{ .x = self.picker_rows.x, .y = y, .w = self.picker_rows.w, .h = picker_row_height - 2 }, 4, .{ .r = 51, .g = 62, .b = 82 });
            var buffer: [768]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ model.identity.model_id.slice(), if (model.synthetic) " · synthetic test" else "" });
            try self.labels.drawFitted(renderer, text, label, menu.x + 16, y + 5, menu.w - 32, 13, foreground);
            const subtitle = try modelSubtitle(model, &buffer);
            try self.labels.drawFitted(renderer, text, subtitle, menu.x + 16, y + 25, menu.w - 32, 11, muted);
        }
        clip.restore(renderer);
        try self.labels.drawFitted(renderer, text, "Scroll for more · ↑ ↓ choose · Enter selects · Esc closes", menu.x + 14, menu.y + menu.h - 20, menu.w - 28, 10, muted);
        if (self.pickerMaxScroll() > 0) {
            const thumb_height = @max(18, self.picker_rows.h * self.picker_rows.h / (@as(f32, @floatFromInt(self.model_count)) * picker_row_height));
            try widgets.panel(renderer, .{ .x = menu.x + menu.w - 5, .y = self.picker_rows.y + (self.picker_rows.h - thumb_height) * self.picker_scroll / self.pickerMaxScroll(), .w = 3, .h = thumb_height }, 1, muted);
        }
    }

    fn drawSetup(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        const width = bounds.header.width;
        const height = bounds.composer.y + bounds.composer.height + 16;
        const menu_width = @min(800, width - 24);
        const menu_height = @min(536, height - 24);
        self.setup_menu = .{ .x = (width - menu_width) / 2, .y = (height - menu_height) / 2, .w = menu_width, .h = menu_height };
        const menu = self.setup_menu;
        try widgets.panel(renderer, menu, 8, .{ .r = 35, .g = 40, .b = 49 });
        var clip = widgets.Clip.push(renderer, menu);
        defer clip.restore(renderer);
        try self.labels.draw(text, "Provider connection", menu.x + 16, menu.y + 15, 16, foreground);
        self.setup_close_bounds = .{ .x = menu.x + menu.w - 82, .y = menu.y + 10, .w = 66, .h = 30 };
        try widgets.panel(renderer, self.setup_close_bounds, 4, .{ .r = 51, .g = 59, .b = 73 });
        try self.labels.draw(text, "Close Esc", self.setup_close_bounds.x + 7, menu.y + 19, 11, foreground);
        self.setup_runtime_bounds = .{ .x = menu.x + 16, .y = menu.y + 48, .w = menu.w - 32, .h = 30 };
        try widgets.panel(renderer, self.setup_runtime_bounds, 4, .{ .r = 27, .g = 32, .b = 41 });
        try self.labels.draw(text, if (self.setup_runtime == .codex) "Runtime: Codex  ↻ click to switch" else "Runtime: OpenCode  ↻ click to switch", menu.x + 24, menu.y + 57, 13, foreground);
        const names = [_][]const u8{ "Runtime executable · absolute path", "Isolated account directory · absolute path", "Workspace · absolute path", "Model provider · e.g. openai" };
        for (names, 0..) |name, index| {
            const y = menu.y + 88 + @as(f32, @floatFromInt(index)) * 48;
            try self.labels.draw(text, name, menu.x + 16, y, 11, muted);
            const box = c.SDL_FRect{ .x = menu.x + 16, .y = y + 15, .w = menu.w - 32, .h = 28 };
            self.setup_field_bounds[index] = box;
            try widgets.panel(renderer, box, 3, if (index == self.setup_field) .{ .r = 51, .g = 69, .b = 105 } else .{ .r = 27, .g = 32, .b = 41 });
            try self.labels.drawFitted(renderer, text, self.setup_fields[index][0..self.setup_lengths[index]], box.x + 6, box.y + 6, box.w - 12, 12, foreground);
        }
        const names_buttons = [_][]const u8{ "Save connection", "Browser sign-in", "Device sign-in", "Refresh models" };
        const button_width = (menu.w - 40) / 2;
        for (names_buttons, 0..) |name, index| {
            const box = c.SDL_FRect{ .x = menu.x + 16 + @as(f32, @floatFromInt(index % 2)) * (button_width + 8), .y = menu.y + 286 + @as(f32, @floatFromInt(index / 2)) * 38, .w = button_width, .h = 32 };
            self.setup_button_bounds[index] = box;
            const enabled = self.setup_runtime == .codex or (index != 1 and index != 2);
            try widgets.panel(renderer, box, 4, if (enabled) .{ .r = 51, .g = 69, .b = 105 } else .{ .r = 27, .g = 32, .b = 41 });
            try self.labels.draw(text, name, box.x + 12, box.y + 9, 12, if (enabled) foreground else muted);
        }
        try self.labels.drawFitted(renderer, text, "Tab changes field · Ctrl+A replaces · Paste supported · No credentials imported", menu.x + 16, menu.y + 368, menu.w - 32, 11, muted);
        var start: usize = 0;
        var y = menu.y + 390;
        while (start < self.runtime_info_len and y + 18 < menu.y + menu.h - 8) : (y += 18) {
            const rest = self.runtime_info[start..self.runtime_info_len];
            const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const end = @import("../text/utf8.zig").prefix(rest[0..line_end], 100).len;
            try self.labels.drawFitted(renderer, text, rest[0..end], menu.x + 16, y, menu.w - 32, 11, foreground);
            start += end;
            if (start < self.runtime_info_len and self.runtime_info[start] == '\n') start += 1;
        }
    }

    pub fn draw(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, window: *c.SDL_Window, bounds: Layout.Coding) !void {
        const foreground = Color{ .r = 231, .g = 235, .b = 242 };
        const muted = Color{ .r = 157, .g = 168, .b = 186 };
        if (!c.SDL_SetRenderDrawColor(renderer, 19, 22, 28, 255) or !c.SDL_RenderClear(renderer)) return error.CanvasDraw;
        if (self.custom_root == null) try self.drawChrome(renderer, text, bounds, foreground, muted);
        const task_height: f32 = if (self.custom_root == null) @as(f32, @floatFromInt(self.task_count)) * 24 else 0;
        self.transcript_bounds = .{ .x = bounds.transcript.x, .y = bounds.transcript.y + task_height, .w = bounds.transcript.width, .h = @max(0, bounds.transcript.height - task_height) };
        var transcript_clip = widgets.Clip.push(renderer, self.transcript_bounds);
        if (self.custom_render) |render| {
            if (self.custom_tile_sequence != self.custom_render_sequence) {
                var tile: presentation.Tile = .{
                    .key = .{ .source = @splat(0), .revision = self.custom_render_sequence, .generation = 0 },
                    .block = std.mem.zeroes(presentation.Block),
                    .state = .rich,
                    .len = render.len,
                };
                tile.block.kind = if (render.format == 2) .code else .paragraph;
                @memcpy(tile.text[0..render.len], render.bytes[0..render.len]);
                if (render.format == 2 and render.len != 0) {
                    tile.spans[0] = .{ .start = 0, .end = @intCast(render.len), .kind = .code, .flags = 0 };
                    tile.span_count = 1;
                }
                try self.custom_tile.update(text, &tile, @max(25, bounds.transcript.width));
                self.custom_tile_sequence = self.custom_render_sequence;
            }
            try self.custom_tile.reflow(text, @max(25, bounds.transcript.width));
            try self.custom_tile.draw(renderer, text, bounds.transcript.x, bounds.transcript.y);
        } else {
            var anchor_index: ?usize = null;
            var anchor_point: transcript.RichTile.ScrollPoint = .{ .byte = 0, .offset = 0 };
            var old_y: f32 = 0;
            if (!self.follow_latest) for (0..self.rich_count) |offset| {
                const index = if (self.rich_count == self.rich_tiles.len) (self.rich_next + offset) % self.rich_tiles.len else offset;
                const tile = &self.rich_tiles[index];
                if (old_y + tile.headingHeight() + tile.height() + 8 > self.transcript_scroll) {
                    anchor_index = index;
                    anchor_point = tile.capture(self.transcript_scroll - old_y - tile.headingHeight());
                    break;
                }
                old_y += tile.headingHeight() + tile.height() + 8;
            };
            var total_height: f32 = 0;
            var restored: ?f32 = null;
            for (0..self.rich_count) |offset| {
                const index = if (self.rich_count == self.rich_tiles.len) (self.rich_next + offset) % self.rich_tiles.len else offset;
                const tile = &self.rich_tiles[index];
                try tile.reflow(text, bounds.transcript.width);
                if (anchor_index == index) restored = total_height + tile.headingHeight() + tile.restore(anchor_point);
                total_height += tile.headingHeight() + tile.height() + 8;
            }
            self.history_height = total_height;
            const max_scroll = @max(0, total_height - self.transcript_bounds.h);
            self.transcript_scroll = if (self.follow_latest) max_scroll else @min(max_scroll, restored orelse self.transcript_scroll);
            var tile_y = self.transcript_bounds.y - self.transcript_scroll;
            var captured = false;
            for (0..self.rich_count) |offset| {
                const index = if (self.rich_count == self.rich_tiles.len) (self.rich_next + offset) % self.rich_tiles.len else offset;
                const tile = &self.rich_tiles[index];
                const heading_y = tile_y;
                tile_y += tile.headingHeight();
                if (tile_y + tile.height() >= self.transcript_bounds.y and heading_y < self.transcript_bounds.y + self.transcript_bounds.h) {
                    if (!captured) {
                        self.captureHistory(tile, tile.capture(self.transcript_bounds.y - tile_y));
                        captured = true;
                    }
                    if (tile.heading) try self.labels.draw(text, tile.role, bounds.transcript.x, heading_y + 2, 13, muted);
                    try tile.draw(renderer, text, bounds.transcript.x, tile_y);
                } else tile.bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                tile_y += tile.height() + 8;
            }
            if (self.rich_count == 0) {
                var context: [1024]u8 = undefined;
                const empty = try self.emptyState(&context);
                try self.labels.drawFitted(renderer, text, "What would you like to build?", bounds.transcript.x, self.transcript_bounds.y + 20, bounds.transcript.width, 22, foreground);
                try self.labels.drawFitted(renderer, text, empty.description, bounds.transcript.x, self.transcript_bounds.y + 58, bounds.transcript.width, 14, muted);
                try self.labels.drawFitted(renderer, text, empty.context, bounds.transcript.x, self.transcript_bounds.y + 86, bounds.transcript.width, 13, muted);
            }
        }
        transcript_clip.restore(renderer);
        if (self.custom_root == null and !self.follow_latest) {
            try widgets.panel(renderer, self.follow_bounds, 5, .{ .r = 51, .g = 62, .b = 82 });
            try self.labels.draw(text, "Back to latest ↓", self.follow_bounds.x + 12, self.follow_bounds.y + 7, 12, foreground);
        }

        const panel = c.SDL_FRect{ .x = bounds.composer.x, .y = bounds.composer.y, .w = bounds.composer.width, .h = bounds.composer.height };
        if (bounds.composer.width > 24 and bounds.composer.height > 40) {
            try widgets.panel(renderer, .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = panel.h - (if (self.custom_root == null) @as(f32, 24) else 0) }, 10, if (self.focused) .{ .r = 103, .g = 129, .b = 210 } else .{ .r = 57, .g = 64, .b = 79 });
            try widgets.panel(renderer, .{ .x = panel.x + 1, .y = panel.y + 1, .w = panel.w - 2, .h = panel.h - (if (self.custom_root == null) @as(f32, 26) else 2) }, 9, .{ .r = 27, .g = 32, .b = 41 });
            const editor_bounds = c.SDL_FRect{ .x = panel.x, .y = panel.y, .w = panel.w, .h = panel.h - (if (self.custom_root != null) @as(f32, 40) else if (self.can_approve) @as(f32, 108) else 70) };
            self.editor_view.bounds = editor_bounds;
            try self.editor_view.ensureLayout(text, &self.editor, panel.w, 16);
            try self.ensurePreedit(text, panel.w - 24);
            var clip = widgets.Clip.push(renderer, .{ .x = panel.x + 10, .y = panel.y + 8, .w = panel.w - 20, .h = editor_bounds.h - 12 });
            if (self.editor.len == 0 and self.preedit_len == 0) try self.labels.drawFitted(renderer, text, "Ask for changes, or send a follow-up…", panel.x + 12, panel.y + 12, panel.w - 24, 15, muted);
            if (self.editor_view.layout) |layout| {
                const content_height = c.spica_text_layout_height(layout);
                const available = editor_bounds.h - 20;
                self.editor_view.scroll = std.math.clamp(self.editor_view.scroll, 0, @max(0, content_height - available));
                if (self.editor_view.caret(&self.editor)) |caret_rect| {
                    if (self.focused and self.reveal_caret) {
                        if (caret_rect.y < self.editor_view.scroll) self.editor_view.scroll = caret_rect.y;
                        if (caret_rect.y + caret_rect.h > self.editor_view.scroll + available) self.editor_view.scroll = caret_rect.y + caret_rect.h - available;
                    }
                    self.reveal_caret = false;
                    const x = panel.x + 12;
                    const y = panel.y + 10 - self.editor_view.scroll;
                    const selection = self.editor.selection();
                    const begin = @max(selection.start, self.editor_view.start) - self.editor_view.start;
                    const end = @min(selection.end, self.editor_view.end) -| self.editor_view.start;
                    var rects: [128]c.SDL_FRect = undefined;
                    const count = c.spica_text_layout_selection_rects(layout, begin, end, &rects, rects.len);
                    if (!c.SDL_SetRenderDrawColor(renderer, 64, 84, 125, 255)) return error.SelectionDraw;
                    for (rects[0..@min(count, rects.len)]) |rect| {
                        const translated = c.SDL_FRect{ .x = x + rect.x, .y = y + rect.y, .w = rect.w, .h = rect.h };
                        if (!c.SDL_RenderFillRect(renderer, &translated)) return error.SelectionDraw;
                    }
                    if (count > rects.len) self.notice = "Selection display budget exceeded";
                    if (!c.spica_text_layout_draw(text, layout, x, y, .{ .r = 231, .g = 235, .b = 242, .a = 255 })) return error.EditorDraw;
                    if (self.focused and self.window_active) {
                        const caret = c.SDL_FRect{ .x = x + caret_rect.x, .y = y + caret_rect.y, .w = 1.5, .h = caret_rect.h };
                        if (!c.SDL_SetRenderDrawColor(renderer, 231, 235, 242, 255) or !c.SDL_RenderFillRect(renderer, &caret)) return error.CaretDraw;
                        const input_rect = c.SDL_Rect{ .x = @intFromFloat(caret.x), .y = @intFromFloat(caret.y), .w = 1, .h = @intFromFloat(caret.h) };
                        if (!c.SDL_SetTextInputArea(window, &input_rect, 0)) return error.TextInputArea;
                        if (self.preedit_layout) |preedit_layout| {
                            if (!c.spica_text_layout_draw(text, preedit_layout, caret.x, caret.y, .{ .r = 164, .g = 185, .b = 255, .a = 255 })) return error.PreeditDraw;
                            if (!c.SDL_RenderLine(renderer, caret.x, caret.y + caret.h, caret.x + 32, caret.y + caret.h)) return error.PreeditDraw;
                        }
                    }
                }
            }
            clip.restore(renderer);
            if (self.custom_root == null) {
                try self.drawComposerControls(renderer, text, panel, foreground, muted);
            } else {
                const names = [_][]const u8{ "Send", "Cancel F6", "Allow F7", "Deny F8" };
                for (&self.controls, 0..) |*control, index| {
                    control.* = .{ .x = panel.x + 12 + @as(f32, @floatFromInt(index)) * 112, .y = panel.y + panel.h - 34, .w = 104, .h = 26 };
                    const enabled = switch (@as(Intent, @enumFromInt(index))) {
                        .send => self.can_send,
                        .cancel => self.can_cancel,
                        .allow, .deny => self.can_approve,
                    };
                    try widgets.panel(renderer, control.*, 4, if (enabled) .{ .r = 51, .g = 69, .b = 105 } else .{ .r = 35, .g = 40, .b = 49 });
                    try self.labels.draw(text, names[index], control.x + 8, control.y + 5, 12, if (enabled) foreground else muted);
                }
            }
        } else {
            self.controls = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            self.editor_view.bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }
        if (self.custom_root) |root| {
            for (root.nodes[0..root.count], 0..) |node, index| {
                const box = self.custom_bounds[index];
                const label = root.text[node.text_offset..][0..node.text_len];
                if (node.kind == 3) try widgets.panel(renderer, .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height }, 4, .{ .r = 51, .g = 69, .b = 105 });
                if (node.kind == 2 or node.kind == 3) try self.labels.drawFitted(renderer, text, label, box.x + 4, box.y + 4, box.width - 8, 14, foreground);
            }
            try self.labels.drawFitted(renderer, text, self.status, 24, 0, 600, 11, muted);
        }
        if (self.notice) |notice| try self.labels.drawFitted(renderer, text, notice, bounds.transcript.x, bounds.transcript.y, bounds.transcript.width, 12, muted);
        if (self.custom_root == null and self.picker_open) try self.drawPicker(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null and self.setup_open) try self.drawSetup(renderer, text, bounds, foreground, muted);
    }
};

test "root emits only enabled explicit intents and preserves draft until receipt" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("retained prompt", .typing);
    view.request(.send);
    try std.testing.expect(view.takeIntent() == null);
    view.can_send = true;
    view.request(.send);
    try std.testing.expectEqual(Intent.send, view.takeIntent().?);
    try std.testing.expect(view.takeIntent() == null);
    try std.testing.expectEqualStrings("retained prompt", view.editor.textBytes());
    view.request(.allow);
    try std.testing.expect(view.takeIntent() == null);
    view.can_approve = true;
    view.request(.deny);
    try std.testing.expectEqual(Intent.deny, view.takeIntent().?);
    view.can_cancel = true;
    view.request(.cancel);
    try std.testing.expectEqual(Intent.cancel, view.takeIntent().?);
}

test "presentation edits retain exact Unicode and rejected insertion state" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("e\u{301} שלום 👩‍💻\n", .paste);
    const original = view.editor.textBytes();
    var copy: [128]u8 = undefined;
    @memcpy(copy[0..original.len], original);
    const revision = view.revision;
    try std.testing.expectError(error.InvalidUtf8, view.insert("\xff", .typing));
    try std.testing.expectEqualStrings(copy[0..original.len], view.editor.textBytes());
    try std.testing.expectEqual(revision, view.revision);
    view.editor.moveGrapheme(.backward, true);
    try view.insert("x", .typing);
    try std.testing.expect(view.editor.undo());
    try std.testing.expectEqualStrings(copy[0..original.len], view.editor.textBytes());
}

test "manual wheel scroll only follows caret again after explicit edit" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.editor_view.bounds = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    view.editor_view.scroll = 100;
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = 20;
    event.wheel.mouse_y = 20;
    event.wheel.y = 1;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expect(!view.reveal_caret);
    try std.testing.expectEqual(@as(f32, 56), view.editor_view.scroll);
    try view.insert("x", .typing);
    try std.testing.expect(view.reveal_caret);
}

test "unchanged preedit reuses retained shaping and releases when cleared" {
    const surface = c.SDL_CreateSurface(200, 100, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    @memcpy(view.preedit[0..3], "abc");
    view.preedit_len = 3;
    try view.ensurePreedit(text, 180);
    const retained = view.preedit_layout.?;
    try view.ensurePreedit(text, 180);
    try std.testing.expectEqual(retained, view.preedit_layout.?);
    view.preedit_len = 0;
    view.preedit_changed = true;
    try view.ensurePreedit(text, 180);
    try std.testing.expect(view.preedit_layout == null);
}

test "custom root with absent composer cannot edit or send invisible draft" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("retained", .typing);
    view.can_send = true;
    var root = std.mem.zeroes(@import("../script.zig").Root);
    root.count = 1;
    root.nodes[0].kind = 2;
    view.custom_root = &root;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "hidden";
    try std.testing.expect(!try view.handle(event, undefined, undefined));
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RETURN;
    try std.testing.expect(!try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("retained", view.editor.textBytes());
    try std.testing.expect(view.takeIntent() == null);
}

test "native task cancellation retains exact durable run revision" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.task_cancel = .{ .id = @splat('a'), .revision = 91 };
    const intent = view.takeTaskCancel().?;
    try std.testing.expectEqual(@as(u64, 91), intent.revision);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat('a')), &intent.id);
    try std.testing.expect(view.takeTaskCancel() == null);
}

test "history shortcuts preserve focused composer document edges and inactive input" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("first\nlast", .paste);
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.mod = c.SDL_KMOD_CTRL;
    event.key.key = c.SDLK_HOME;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(@as(usize, 0), view.editor.caret);
    try std.testing.expect(view.history_move == null);
    event.key.key = c.SDLK_END;
    event.key.mod |= c.SDL_KMOD_SHIFT;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(view.editor.len, view.editor.caret);
    try std.testing.expectEqual(@as(usize, 0), view.editor.anchor);
    try std.testing.expect(view.history_move == null);
    view.window_active = false;
    event.key.mod = c.SDL_KMOD_ALT;
    try std.testing.expect(!try view.handle(event, undefined, undefined));
    try std.testing.expect(view.history_move == null);
    view.window_active = true;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(View.HistoryMove.latest, view.history_move.?);
}

test "stable rendered selection survives page eviction and clips adjacent geometry" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    const key = presentation.Key{ .source = @splat(22), .revision = 3, .generation = 1 };
    view.rich_count = 1;
    const tile = &view.rich_tiles[0];
    tile.key = key;
    tile.start_byte = 4000;
    tile.length = 100;
    tile.caret = 80;
    view.selectTile(tile, false);
    view.clearHistory();
    view.rich_count = 1;
    tile.key = key;
    tile.start_byte = 4100;
    tile.length = 100;
    tile.caret = 50;
    view.selectTile(tile, true);
    try std.testing.expectEqual(@as(u32, 4080), view.rendered_selection.?.anchor);
    try std.testing.expectEqual(@as(u32, 4150), view.rendered_selection.?.caret);
    try std.testing.expect(tile.selected);
    try std.testing.expectEqual(@as(usize, 0), tile.anchor);
    try std.testing.expectEqual(@as(usize, 50), tile.caret);
}

test "thread switching retains complete composer undo selection and refuses destructive eviction" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.selectThread(try transcript.Id.init("first"));
    try view.insert("draft café", .typing);
    view.editor.setCaret(6, false);
    view.editor.setCaret(10, true);
    const caret = view.editor.caret;
    const anchor = view.editor.anchor;
    try view.selectThread(try transcript.Id.init("second"));
    try view.insert("independent", .typing);
    try view.selectThread(try transcript.Id.init("first"));
    try std.testing.expectEqualStrings("draft café", view.editor.textBytes());
    try std.testing.expectEqual(caret, view.editor.caret);
    try std.testing.expectEqual(anchor, view.editor.anchor);
    try std.testing.expect(view.editor.undo());
    try std.testing.expectEqualStrings("", view.editor.textBytes());
    try std.testing.expect(view.editor.redo());
    for (0..15) |index| {
        var id: [32]u8 = undefined;
        try view.selectThread(try transcript.Id.init(try std.fmt.bufPrint(&id, "thread-{d}", .{index})));
    }
    try std.testing.expectError(error.DraftRetentionFull, view.selectThread(try transcript.Id.init("overflow")));
    try view.selectThread(try transcript.Id.init("second"));
    try std.testing.expectEqualStrings("independent", view.editor.textBytes());
}

test "model identity copies complete selection without borrowed provider strings" {
    var model = [_]u8{ 'm', 'o', 'd', 'e', 'l' };
    var identity = try View.Identity.from(.{ .model_provider = "provider", .model_id = &model, .effort = "high", .account_ref = "explicit-account", .workspace = .{ .value = "selected-workspace" } });
    model[0] = 'x';
    const selected = identity.selection();
    try std.testing.expectEqualStrings("model", selected.model_id);
    try std.testing.expectEqualStrings("high", selected.effort);
    try std.testing.expectEqualStrings("explicit-account", selected.account_ref);
    try std.testing.expectEqualStrings("selected-workspace", selected.workspace.value);
}

test "model picker clips pointer selection and scrolls to every bounded catalog row" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.model_count = view.models.len;
    for (view.models[0..view.model_count], 0..) |*model, index| {
        var name: [32]u8 = undefined;
        model.* = .{ .identity = try View.Identity.from(.{ .model_provider = "fixture", .effort = "none", .model_id = try std.fmt.bufPrint(&name, "model-{d}", .{index}), .account_ref = "isolated", .workspace = .{ .value = "checkout" } }), .readiness = .ready };
    }
    view.picker_menu = .{ .x = 200, .y = 80, .w = 400, .h = 224 };
    view.picker_rows = .{ .x = 208, .y = 118, .w = 384, .h = 160 };
    view.picker_open = true;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.mouse_x = 230;
    event.wheel.mouse_y = 140;
    event.wheel.y = -100;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(view.pickerMaxScroll(), view.picker_scroll);
    try std.testing.expectEqual(@as(?usize, 31), view.pickerIndexAt(240, 277));
    try std.testing.expect(view.pickerIndexAt(100, 277) == null);
    try std.testing.expect(view.pickerIndexAt(240, 280) == null);
    try std.testing.expectEqual(@as(f32, 0), view.pickerRowBounds(0).h);
    const final = view.pickerRowBounds(31);
    try std.testing.expect(final.h > 0);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = final.x + 4;
    event.button.y = final.y + final.h / 2;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("model-31", view.selected.?.model_id.slice());
    try std.testing.expect(!view.picker_open);
    view.picker_open = true;
    event.button.x = 100;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("model-31", view.selected.?.model_id.slice());
    try std.testing.expect(!view.picker_open);
    view.picker_open = true;
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_UP;
    view.picker_hover = 31;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(usize, 30), view.picker_hover);
    event.key.key = c.SDLK_ESCAPE;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expect(!view.picker_open);
}

test "effort cycling respects complete runtime account and workspace identity" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    const selected = try View.Identity.from(.{ .runtime_kind = "codex", .model_provider = "openai", .model_id = "same-name", .effort = "medium", .account_ref = "selected-account", .workspace = .{ .value = "selected-checkout" } });
    view.selected = selected;
    view.model_count = 2;
    view.models[0] = .{ .identity = selected, .readiness = .ready, .effort_count = 2 };
    view.models[0].identity.workspace = try transcript.Id.init("another-checkout");
    view.models[0].efforts[0] = try transcript.Id.init("medium");
    view.models[0].efforts[1] = try transcript.Id.init("low");
    view.models[1] = .{ .identity = selected, .readiness = .ready, .effort_count = 2 };
    view.models[1].efforts[0] = try transcript.Id.init("medium");
    view.models[1].efforts[1] = try transcript.Id.init("high");
    view.effort_bounds = .{ .x = 300, .y = 400, .w = 100, .h = 30 };
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = 310;
    event.button.y = 410;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("high", view.selected.?.effort.slice());
    try std.testing.expectEqualStrings("selected-checkout", view.selected.?.workspace.slice());
    try std.testing.expectEqualStrings("selected-account", view.selected.?.account_ref.slice());
}

test "painted connection and composer controls fit minimum and regular windows" {
    const foreground = Color{ .r = 231, .g = 235, .b = 242 };
    const muted = Color{ .r = 157, .g = 168, .b = 186 };
    for ([_][2]f32{ .{ 720, 480 }, .{ 900, 650 }, .{ 1100, 740 }, .{ 1280, 800 } }) |size| {
        const surface = c.SDL_CreateSurface(@intFromFloat(size[0]), @intFromFloat(size[1]), c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
        defer c.SDL_DestroySurface(surface);
        const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
        defer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
        defer c.spica_text_destroy(text);
        var layout = try Layout.init(std.testing.allocator, size[0], size[1]);
        defer layout.deinit();
        var view = try View.init(std.testing.allocator);
        defer view.deinit();
        const bounds = layout.coding(size[0]);
        try view.drawChrome(renderer, text, bounds, foreground, muted);
        const panel = c.SDL_FRect{ .x = bounds.composer.x, .y = bounds.composer.y, .w = bounds.composer.width, .h = bounds.composer.height };
        try view.drawComposerControls(renderer, text, panel, foreground, muted);
        try view.drawSetup(renderer, text, bounds, foreground, muted);
        for (view.setup_field_bounds) |box| {
            try std.testing.expect(box.x >= 0 and box.y >= 0 and box.x + box.w <= size[0] and box.y + box.h <= size[1]);
        }
        for (view.setup_button_bounds, 0..) |box, index| {
            try std.testing.expect(box.x >= 0 and box.y >= 0 and box.x + box.w <= size[0] and box.y + box.h <= size[1]);
            view.setup_open = true;
            view.setup_action = null;
            var event = std.mem.zeroes(c.SDL_Event);
            event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
            event.button.button = c.SDL_BUTTON_LEFT;
            event.button.x = box.x + box.w / 2;
            event.button.y = box.y + box.h / 2;
            try std.testing.expect(try view.handle(event, undefined, undefined));
            try std.testing.expectEqual(index, switch (view.setup_action.?) {
                .configure => @as(usize, 0),
                .browser => 1,
                .device => 2,
                .refresh => 3,
                .status => 4,
            });
        }
        try std.testing.expect(view.picker_bounds.x + view.picker_bounds.w <= view.effort_bounds.x);
        try std.testing.expect(view.effort_bounds.x + view.effort_bounds.w <= view.controls[0].x);
        try std.testing.expect(view.controls[1].h == 0 and view.controls[2].h == 0 and view.controls[3].h == 0);
        try std.testing.expect(view.picker_menu.y >= 0 and view.picker_menu.x + view.picker_menu.w <= size[0]);
        // Exercise the full paint path, including the reduced editor height
        // used while approval controls are visible, at every supported size.
        view.setup_open = false;
        view.focused = false;
        view.window_active = false;
        for (0..3) |state| {
            view.can_send = state == 0;
            view.can_cancel = state != 0;
            view.can_approve = state == 2;
            try view.draw(renderer, text, undefined, bounds);
            const painted = [_]c.SDL_FRect{ view.editor_view.bounds, view.picker_bounds, view.effort_bounds, view.controls[0], view.controls[1], view.controls[2], view.controls[3] };
            for (painted, 0..) |box, index| {
                if (box.h == 0 or box.w == 0) continue;
                try std.testing.expect(box.x >= panel.x and box.y >= panel.y and box.x + box.w <= panel.x + panel.w and box.y + box.h <= panel.y + panel.h);
                for (painted[index + 1 ..]) |other| {
                    if (other.h == 0 or other.w == 0) continue;
                    try std.testing.expect(box.x + box.w <= other.x or other.x + other.w <= box.x or box.y + box.h <= other.y or other.y + other.h <= box.y);
                }
            }
            const primary = view.controls[if (view.can_cancel) @as(usize, 1) else 0];
            try std.testing.expect(view.picker_bounds.x + view.picker_bounds.w + 10 <= view.effort_bounds.x);
            try std.testing.expect(view.effort_bounds.x + view.effort_bounds.w + 10 <= primary.x);
        }
        var stats: c.SpicaTextStats = undefined;
        try std.testing.expect(c.spica_text_get_stats(text, &stats));
        // Default chrome, setup and empty states fit the bundled face. UI
        // decoration must not trigger OS font discovery and its retained heap.
        try std.testing.expectEqual(@as(c_uint, 1), stats.face_count);
        view.setup_open = true;
        view.setup_runtime = .opencode;
        view.setup_action = null;
        const browser = view.setup_button_bounds[1];
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = c.SDL_BUTTON_LEFT;
        event.button.x = browser.x + 4;
        event.button.y = browser.y + 4;
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expect(view.setup_action == null);
    }
}

test "setup replacement preserves UTF8 and rejects oversized replacement atomically" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.setupInsert("/tmp/old-account");
    view.setup_select_all = true;
    try view.setupInsert("/tmp/café/新");
    try std.testing.expectEqualStrings("/tmp/café/新", view.setup_fields[0][0..view.setup_lengths[0]]);
    view.setup_select_all = true;
    try std.testing.expectError(error.TextTooLarge, view.setupInsert(&@as([513]u8, @splat('x'))));
    try std.testing.expectEqualStrings("/tmp/café/新", view.setup_fields[0][0..view.setup_lengths[0]]);
}

test "empty workspace describes actual selection and keeps paths and demo guidance contextual" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    const workspace = "/tmp/isolated-account/project-café/  •  Chat 1";
    @memcpy(view.workspace_label[0..workspace.len], workspace);
    view.workspace_label_len = workspace.len;
    try std.testing.expectEqualStrings("project-café", view.workspaceName());
    try std.testing.expectEqualStrings(workspace, view.workspace_label[0..view.workspace_label_len]);
    view.selected = try View.Identity.from(.{ .runtime_kind = "opencode", .model_provider = "explicit-provider", .model_id = "selected-model", .effort = "default", .account_ref = "isolated", .workspace = .{ .value = "opaque-workspace-binding" } });
    view.can_send = true;
    var buffer: [1024]u8 = undefined;
    const ready = try view.emptyState(&buffer);
    try std.testing.expectEqualStrings("Describe a change, ask a question, or continue your work.", ready.description);
    try std.testing.expectEqualStrings("OpenCode · selected-model · project-café", ready.context);
    view.can_send = false;
    view.send_disabled_reason = "Loading models…";
    const loading = try view.emptyState(&buffer);
    try std.testing.expectEqualStrings("Loading models…", loading.description);
    try std.testing.expectEqualStrings("OpenCode · selected-model · project-café", loading.context);
    view.selected = null;
    const unselected = try view.emptyState(&buffer);
    try std.testing.expectEqualStrings("Loading models…", unselected.description);
    try std.testing.expectEqualStrings("Manage your runtime and workspace in Connection.", unselected.context);
    view.selected = try View.Identity.from(contract.fakeSelection(.{ .value = "fixture" }));
    view.send_disabled_reason = null;
    const fake = try view.emptyState(&buffer);
    try std.testing.expectEqualStrings("Demo is synthetic. Connect a coding provider to work on files.", fake.context);
}

test "picker uses compact catalog metadata and retains actionable unavailable reasons" {
    var model = View.Model{
        .identity = try View.Identity.from(.{ .runtime_kind = "opencode", .model_provider = "explicit-provider", .model_id = "selected-model", .effort = "default", .account_ref = "isolated", .workspace = .{ .value = "checkout" } }),
        .readiness = .unknown,
        .effort_count = 2,
    };
    const discovery_detail = "negotiated catalog; account entitlement unverified; per-model variants require exact session negotiation";
    @memcpy(model.reason[0..discovery_detail.len], discovery_detail);
    model.reason_len = discovery_detail.len;
    var buffer: [768]u8 = undefined;
    try std.testing.expectEqualStrings("explicit-provider · 2 effort options · availability unverified", try View.modelSubtitle(&model, &buffer));
    model.readiness = .ready;
    try std.testing.expectEqualStrings("explicit-provider · 2 effort options · ready", try View.modelSubtitle(&model, &buffer));
    const unavailable = "Sign in to the selected account";
    @memcpy(model.reason[0..unavailable.len], unavailable);
    model.reason_len = unavailable.len;
    model.readiness = .unavailable;
    try std.testing.expectEqualStrings("explicit-provider · unavailable · Sign in to the selected account", try View.modelSubtitle(&model, &buffer));
}
