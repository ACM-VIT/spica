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
    pub const HistoryMove = enum { previous, next, first, latest };
    pub const ThreadHistory = struct {
        message: transcript.Id,
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
    pub fn admitTile(self: *View, text: *c.SpicaText, tile: *const presentation.Tile, width: f32) !void {
        for (self.rich_tiles[0..self.rich_count]) |*slot| {
            if (slot.key) |key| if (std.meta.eql(key, tile.key) and slot.block_index == tile.block.index and slot.start_byte == tile.start_byte) {
                try slot.update(text, tile, width);
                self.applySelection(slot);
                return;
            };
        }
        const index = if (self.rich_count < self.rich_tiles.len) self.rich_count else self.rich_next;
        try self.rich_tiles[index].update(text, tile, width);
        self.applySelection(&self.rich_tiles[index]);
        if (self.rich_count < self.rich_tiles.len) self.rich_count += 1;
        self.rich_next = (index + 1) % self.rich_tiles.len;
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
            try self.labels.drawFitted(renderer, text, self.status, 110, 22, bounds.header.width - 140, 13, muted);
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
                if (old_y + tile.height() + 8 > self.transcript_scroll) {
                    anchor_index = index;
                    anchor_point = tile.capture(self.transcript_scroll - old_y);
                    break;
                }
                old_y += tile.height() + 8;
            };
            var total_height: f32 = 0;
            var restored: ?f32 = null;
            for (0..self.rich_count) |offset| {
                const index = if (self.rich_count == self.rich_tiles.len) (self.rich_next + offset) % self.rich_tiles.len else offset;
                const tile = &self.rich_tiles[index];
                try tile.reflow(text, bounds.transcript.width);
                if (anchor_index == index) restored = total_height + tile.restore(anchor_point);
                total_height += tile.height() + 8;
            }
            self.history_height = total_height;
            const max_scroll = @max(0, total_height - self.transcript_bounds.h);
            self.transcript_scroll = if (self.follow_latest) max_scroll else @min(max_scroll, restored orelse self.transcript_scroll);
            var tile_y = self.transcript_bounds.y - self.transcript_scroll;
            var captured = false;
            for (0..self.rich_count) |offset| {
                const index = if (self.rich_count == self.rich_tiles.len) (self.rich_next + offset) % self.rich_tiles.len else offset;
                const tile = &self.rich_tiles[index];
                if (tile_y + tile.height() >= self.transcript_bounds.y and tile_y < self.transcript_bounds.y + self.transcript_bounds.h) {
                    if (!captured) {
                        self.captureHistory(tile, tile.capture(self.transcript_bounds.y - tile_y));
                        captured = true;
                    }
                    try tile.draw(renderer, text, bounds.transcript.x, tile_y);
                } else tile.bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
                tile_y += tile.height() + 8;
            }
            if (self.rich_count == 0) try self.labels.draw(text, if (self.connected) "Send a prompt to begin." else "Compose a draft below. No provider is running.", bounds.transcript.x, self.transcript_bounds.y + 20, 16, muted);
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
