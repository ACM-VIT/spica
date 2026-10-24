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
    setup_open: bool = false,
    setup_runtime: enum { codex, opencode } = .codex,
    setup_fields: [4][512]u8 = undefined,
    setup_lengths: [4]usize = @splat(0),
    setup_field: usize = 0,
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
        if (len.* + bytes.len > 512) return error.TextTooLarge;
        @memcpy(self.setup_fields[self.setup_field][len.*..][0..bytes.len], bytes);
        len.* += bytes.len;
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
        if (enabled) self.intent = intent else self.notice = "Action unavailable in the current durable state";
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
                        if (y >= 140 and y < 332) self.setup_field = @min(3, @as(usize, @intFromFloat((y - 140) / 48)));
                        if (y >= 100 and y < 132) self.setup_runtime = if (self.setup_runtime == .codex) .opencode else .codex;
                        if (y >= 350 and y < 384) self.setup_action = if (x < 400) .configure else if (x < 540) .browser else if (x < 680) .device else .refresh;
                        return true;
                    }
                    if (widgets.contains(self.picker_bounds, x, y)) {
                        self.picker_open = !self.picker_open;
                        return true;
                    }
                    if (widgets.contains(self.effort_bounds, x, y)) {
                        if (self.selected) |*selected| for (self.models[0..self.model_count]) |model| {
                            if (!model.identity.model_id.eql(selected.model_id.slice()) or !model.identity.account_ref.eql(selected.account_ref.slice())) continue;
                            for (model.efforts[0..model.effort_count], 0..) |effort, index| if (effort.eql(selected.effort.slice())) {
                                selected.effort = model.efforts[(index + 1) % model.effort_count];
                                break;
                            };
                        };
                        return true;
                    }
                    if (widgets.contains(self.setup_bounds, x, y)) {
                        self.setup_open = true;
                        self.setup_action = .status;
                        return true;
                    }
                    if (widgets.contains(self.follow_bounds, x, y)) {
                        self.history_move = .latest;
                        return true;
                    }
                    if (self.picker_open) {
                        if (y >= 76 and y < 76 + @as(f32, @floatFromInt(self.model_count)) * 38) {
                            const index: usize = @intFromFloat((y - 76) / 38);
                            self.selected = self.models[index].identity;
                        }
                        self.picker_open = false;
                        return true;
                    }
                }
                if (self.custom_root == null and self.navigation_enabled and event.button.x < 208) {
                    const y = event.button.y;
                    if (y >= 68 and y < 98) self.navigation = .new_project;
                    if (y >= 104 and y < 134) self.navigation = .new_thread;
                    if (y >= 148 and y < 148 + @as(f32, @floatFromInt(self.project_count)) * 26) self.navigation = .{ .project = @intFromFloat((y - 148) / 26) };
                    const start = 168 + @as(f32, @floatFromInt(self.project_count)) * 26;
                    if (y >= start and y < start + @as(f32, @floatFromInt(self.thread_count)) * 28) self.navigation = .{ .thread = @intFromFloat((y - start) / 28) };
                    return true;
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
                    if (key == c.SDLK_TAB) self.setup_field = (self.setup_field + 1) % 4;
                    if (key == c.SDLK_RETURN) self.setup_action = .configure;
                    if (key == c.SDLK_BACKSPACE) {
                        const len = &self.setup_lengths[self.setup_field];
                        if (len.* > 0) {
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

    pub fn draw(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, window: *c.SDL_Window, bounds: Layout.Coding) !void {
        const foreground = Color{ .r = 231, .g = 235, .b = 242 };
        const muted = Color{ .r = 157, .g = 168, .b = 186 };
        if (!c.SDL_SetRenderDrawColor(renderer, 19, 22, 28, 255) or !c.SDL_RenderClear(renderer)) return error.CanvasDraw;
        if (self.custom_root == null) {
            try self.labels.draw(text, "SPICA", 24, 18, 18, foreground);
            const model_width = std.math.clamp((bounds.header.width - 240) * 0.40, 140, 350);
            self.picker_bounds.w = model_width;
            self.effort_bounds = .{ .x = 248 + model_width, .y = 18, .w = 76, .h = 28 };
            self.setup_bounds = .{ .x = self.effort_bounds.x + 84, .y = 18, .w = 112, .h = 28 };
            self.follow_bounds = .{ .x = self.setup_bounds.x + 120, .y = 18, .w = 112, .h = 28 };
            try self.labels.drawFitted(renderer, text, self.status, 110, 22, 124, 13, muted);
            try self.labels.drawFitted(renderer, text, self.workspace_label[0..self.workspace_label_len], 240, 49, bounds.header.width - 260, 11, muted);
            try widgets.panel(renderer, self.picker_bounds, 4, .{ .r = 35, .g = 40, .b = 49 });
            var identity_label: [512]u8 = undefined;
            const identity = if (self.selected) |*selected| try std.fmt.bufPrint(&identity_label, "{s} / {s}", .{ if (selected.runtime_kind.eql("fake")) "DEMO synthetic" else selected.runtime_kind.slice(), selected.model_id.slice() }) else "Choose model";
            try self.labels.drawFitted(renderer, text, identity, 248, 24, self.picker_bounds.w - 16, 13, foreground);
            try widgets.panel(renderer, self.effort_bounds, 4, .{ .r = 35, .g = 40, .b = 49 });
            try self.labels.drawFitted(renderer, text, if (self.selected) |*selected| selected.effort.slice() else "Effort", self.effort_bounds.x + 8, 24, self.effort_bounds.w - 16, 13, foreground);
            try widgets.panel(renderer, self.setup_bounds, 4, .{ .r = 51, .g = 69, .b = 105 });
            try self.labels.draw(text, "Connect provider", self.setup_bounds.x + 4, 24, 12, foreground);
            try widgets.panel(renderer, self.follow_bounds, 4, .{ .r = 35, .g = 40, .b = 49 });
            try self.labels.drawFitted(renderer, text, if (self.follow_latest) "Following live" else "Resume live ↓", self.follow_bounds.x + 4, 24, self.follow_bounds.w - 8, 12, if (self.follow_latest) muted else foreground);
            try self.labels.draw(text, "+ New project", 16, 74, 14, foreground);
            try self.labels.draw(text, "+ New chat", 16, 110, 14, foreground);
            for (self.projects[0..self.project_count], 0..) |*entry, index| {
                try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], 16, 148 + @as(f32, @floatFromInt(index)) * 26, 184, 13, if (entry.id.eql(self.active_project.slice())) foreground else muted);
            }
            const start = 168 + @as(f32, @floatFromInt(self.project_count)) * 26;
            for (self.threads[0..self.thread_count], 0..) |*entry, index| {
                try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], 24, start + @as(f32, @floatFromInt(index)) * 28, 176, 13, if (entry.id.eql(self.active_thread.slice())) foreground else muted);
            }
            for (self.tasks[0..self.task_count], 0..) |*task, index| {
                const y = bounds.transcript.y + @as(f32, @floatFromInt(index)) * 24;
                try self.labels.drawFitted(renderer, text, task.bytes[0..task.len], bounds.transcript.x, y, bounds.transcript.width - 84, 12, muted);
                task.cancel_bounds = .{ .x = bounds.transcript.x + bounds.transcript.width - 76, .y = y, .w = 76, .h = 20 };
                if (task.cancel != null) {
                    try widgets.panel(renderer, task.cancel_bounds, 3, if (self.tasks_enabled) .{ .r = 51, .g = 69, .b = 105 } else .{ .r = 35, .g = 40, .b = 49 });
                    try self.labels.draw(text, "Cancel task", task.cancel_bounds.x + 4, y + 2, 11, muted);
                }
            }
        }
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
                try self.labels.draw(text, "Your native coding workspace", bounds.transcript.x, self.transcript_bounds.y + 20, 22, foreground);
                try self.labels.drawFitted(renderer, text, "Create chats in the sidebar. Drafts and history stay with each chat.", bounds.transcript.x, self.transcript_bounds.y + 58, bounds.transcript.width, 14, muted);
                try self.labels.drawFitted(renderer, text, "Connect provider to authorize your runtime, isolated account and workspace.", bounds.transcript.x, self.transcript_bounds.y + 86, bounds.transcript.width, 14, muted);
                try self.labels.drawFitted(renderer, text, "The synthetic Demo exercises controls only; it does not edit your project.", bounds.transcript.x, self.transcript_bounds.y + 114, bounds.transcript.width, 14, muted);
            }
        }
        transcript_clip.restore(renderer);
        const panel = c.SDL_FRect{ .x = bounds.composer.x, .y = bounds.composer.y, .w = bounds.composer.width, .h = bounds.composer.height };
        if (bounds.composer.width > 24 and bounds.composer.height > 40) {
            try widgets.panel(renderer, panel, 10, if (self.focused) .{ .r = 103, .g = 129, .b = 210 } else .{ .r = 57, .g = 64, .b = 79 });
            try widgets.panel(renderer, .{ .x = panel.x + 1, .y = panel.y + 1, .w = panel.w - 2, .h = panel.h - 2 }, 9, .{ .r = 27, .g = 32, .b = 41 });
            const editor_bounds = c.SDL_FRect{ .x = panel.x, .y = panel.y, .w = panel.w, .h = panel.h - 40 };
            self.editor_view.bounds = editor_bounds;
            try self.editor_view.ensureLayout(text, &self.editor, panel.w, 16);
            try self.ensurePreedit(text, panel.w - 24);
            var clip = widgets.Clip.push(renderer, .{ .x = panel.x + 10, .y = panel.y + 8, .w = panel.w - 20, .h = editor_bounds.h - 12 });
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
        if (self.custom_root == null and self.picker_open) {
            const menu = c.SDL_FRect{ .x = 240, .y = 68, .w = @max(200, bounds.transcript.width), .h = @max(64, @as(f32, @floatFromInt(self.model_count)) * 38 + 16) };
            try widgets.panel(renderer, menu, 6, .{ .r = 35, .g = 40, .b = 49 });
            if (self.model_count == 0) try self.labels.draw(text, "No models. Open Connection, then Refresh models.", 252, 84, 14, foreground);
            for (self.models[0..self.model_count], 0..) |*model, index| {
                var buffer: [768]u8 = undefined;
                const label = try std.fmt.bufPrint(&buffer, "{s} / {s}  [{s}]{s}", .{ model.identity.runtime_kind.slice(), model.identity.model_id.slice(), @tagName(model.readiness), if (model.synthetic) " — synthetic test provider" else "" });
                const y = 76 + @as(f32, @floatFromInt(index)) * 38;
                try self.labels.drawFitted(renderer, text, label, 252, y, menu.w - 24, 13, foreground);
                try self.labels.drawFitted(renderer, text, model.reason[0..model.reason_len], 252, y + 17, menu.w - 24, 11, muted);
            }
        }
        if (self.custom_root == null and self.setup_open) {
            const menu = c.SDL_FRect{ .x = 224, .y = 68, .w = @max(480, bounds.transcript.width), .h = 460 };
            try widgets.panel(renderer, menu, 8, .{ .r = 35, .g = 40, .b = 49 });
            try self.labels.draw(text, "Connect an explicitly authorized runtime (Esc closes)", 240, 78, 15, foreground);
            try self.labels.draw(text, if (self.setup_runtime == .codex) "Runtime: Codex (click to change)" else "Runtime: OpenCode (click to change)", 240, 106, 14, foreground);
            const names = [_][]const u8{ "Absolute executable", "Absolute isolated account directory", "Absolute workspace root", "Model provider (for example openai)" };
            for (names, 0..) |name, index| {
                const y = 140 + @as(f32, @floatFromInt(index)) * 48;
                try self.labels.draw(text, name, 240, y, 11, muted);
                try widgets.panel(renderer, .{ .x = 240, .y = y + 16, .w = menu.w - 32, .h = 26 }, 3, if (index == self.setup_field) .{ .r = 51, .g = 69, .b = 105 } else .{ .r = 27, .g = 32, .b = 41 });
                try self.labels.drawFitted(renderer, text, self.setup_fields[index][0..self.setup_lengths[index]], 246, y + 20, menu.w - 44, 13, foreground);
            }
            try self.labels.draw(text, "Save connection", 240, 358, 13, foreground);
            try self.labels.draw(text, "Browser sign-in", 400, 358, 13, foreground);
            try self.labels.draw(text, "Device sign-in", 540, 358, 13, foreground);
            try self.labels.draw(text, "Refresh models", 680, 358, 13, foreground);
            try self.labels.draw(text, "Tab changes field. Paste supported. No credentials are imported.", 240, 394, 12, muted);
            var start: usize = 0;
            var row: usize = 0;
            while (start < self.runtime_info_len and row < 5) : (row += 1) {
                const end = start + @import("../text/utf8.zig").prefix(self.runtime_info[start..self.runtime_info_len], 92).len;
                try self.labels.drawFitted(renderer, text, self.runtime_info[start..end], 240, 416 + @as(f32, @floatFromInt(row)) * 18, menu.w - 32, 11, foreground);
                start = end;
            }
        }
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
