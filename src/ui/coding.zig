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
const script_api = @import("../script.zig");

// Visual reference: T3 Code eb1510d (MIT), apps/marketing/src/assets/app-desktop.webp;
// apps/web/src/components/sidebar/{SidebarThreadHeader,SidebarThreadRow}.tsx and
// chat/{ChatHeader,ComposerSurface,ComposerControlsBar,ComposerPrimaryActions}.tsx.
// Native geometry/strokes are implemented here against Spica's bounded views.

pub const Intent = enum { send, cancel, allow, deny };

/// Presentation state only. No adapter, store, execution lifetime or accepted work.
pub const View = struct {
    allocator: std.mem.Allocator,
    design: @import("design.zig").Config = .{},
    editor: Composer,
    editor_view: EditorView = .{},
    editor_font_size: f32 = 16,
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
    preedit_font_size: f32 = 0,
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
    rich_font_base: [8]c_uint = @splat(0),
    custom_font_base: c_uint = 16,
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
    effort_open: bool = false,
    effort_menu: c.SDL_FRect = zero_rect,
    effort_rows: [8]c.SDL_FRect = @splat(zero_rect),
    effort_hover: usize = 0,
    picker_scroll: f32 = 0,
    picker_menu: c.SDL_FRect = zero_rect,
    picker_rows: c.SDL_FRect = zero_rect,
    picker_hover: usize = 0,
    sidebar_bounds: c.SDL_FRect = zero_rect,
    sidebar_rows: c.SDL_FRect = zero_rect,
    sidebar_scroll: f32 = 0,
    search_bounds: c.SDL_FRect = zero_rect,
    search_clear_bounds: c.SDL_FRect = zero_rect,
    search_query: [160]u8 = undefined,
    search_len: usize = 0,
    search_focused: bool = false,
    search_select_all: bool = false,
    search_hover: usize = 0,
    scope_bounds: c.SDL_FRect = zero_rect,
    scope_all_bounds: c.SDL_FRect = zero_rect,
    scope_menu: c.SDL_FRect = zero_rect,
    scope_project: transcript.Id = .{},
    scope_open: bool = false,
    scope_scroll: f32 = 0,
    sidebar_hover: ?usize = null,
    new_project_bounds: c.SDL_FRect = zero_rect,
    new_thread_bounds: c.SDL_FRect = zero_rect,
    project_bounds: [16]c.SDL_FRect = @splat(zero_rect),
    thread_bounds: [32]c.SDL_FRect = @splat(zero_rect),
    setup_open: bool = false,
    setup_busy: bool = false,
    setup_login_pending: bool = false,
    /// Borrowed App-owned, stable bounded notice; never owns runtime state.
    setup_feedback: ?[]const u8 = null,
    setup_runtime: contract.RuntimeKind = .codex,
    setup_fields: [4][512]u8 = undefined,
    setup_lengths: [4]usize = @splat(0),
    setup_drafts: [2]SetupDraft = @splat(.{}),
    setup_field: usize = 2,
    setup_select_all: bool = false,
    setup_advanced_open: bool = false,
    setup_menu: c.SDL_FRect = zero_rect,
    setup_runtime_bounds: c.SDL_FRect = zero_rect,
    setup_provider_bounds: [2]c.SDL_FRect = @splat(zero_rect),
    setup_advanced_bounds: c.SDL_FRect = zero_rect,
    setup_login_bounds: c.SDL_FRect = zero_rect,
    setup_existing_bounds: c.SDL_FRect = zero_rect,
    setup_existing_account: [512]u8 = undefined,
    setup_existing_account_len: usize = 0,
    setup_close_bounds: c.SDL_FRect = zero_rect,
    setup_field_bounds: [4]c.SDL_FRect = @splat(zero_rect),
    setup_button_bounds: [4]c.SDL_FRect = @splat(zero_rect),
    setup_action: ?enum { configure, browser, device, status, refresh, open_login } = null,
    login_url: [2048]u8 = undefined,
    login_url_len: usize = 0,
    login_code: [128]u8 = undefined,
    login_code_len: usize = 0,
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
    pub const sidebar_card_stride: f32 = 83;

    const SetupDraft = struct {
        fields: [4][512]u8 = undefined,
        lengths: [4]usize = @splat(0),

        fn copy(self: *SetupDraft, configuration: contract.RuntimeSetup) bool {
            var complete = true;
            const fields = [_][]const u8{ configuration.executable, configuration.account_directory, configuration.workspace_root, configuration.model_provider };
            for (fields, 0..) |field, index| {
                self.lengths[index] = 0;
                if (field.len > self.fields[index].len or !std.unicode.utf8ValidateSlice(field)) {
                    complete = false;
                    continue;
                }
                @memcpy(self.fields[index][0..field.len], field);
                self.lengths[index] = field.len;
            }
            return complete;
        }
    };

    /// Seed both provider drafts in Codex, OpenCode order. No borrowed strings
    /// survive this call. An oversized or invalid UTF8 field remains empty.
    pub fn setSetupDefaults(self: *View, defaults: [2]contract.RuntimeSetup) bool {
        var complete = true;
        for (defaults, 0..) |configuration, index| {
            if (!self.setup_drafts[index].copy(configuration)) complete = false;
        }
        self.setup_existing_account_len = self.setup_drafts[0].lengths[1];
        @memcpy(self.setup_existing_account[0..self.setup_existing_account_len], self.setup_drafts[0].fields[1][0..self.setup_existing_account_len]);
        self.loadSetupDraft();
        return complete;
    }

    pub fn existingCodexEnabled(self: *const View) bool {
        return self.setup_runtime == .codex and self.setup_existing_account_len != 0 and self.setupActionEnabled(0);
    }

    /// Explicitly choose the launch Codex home; saved/custom drafts never migrate
    /// implicitly. Configure/discovery uses the ordinary Host command path.
    pub fn useExistingCodex(self: *View) void {
        if (!self.existingCodexEnabled()) return;
        const len = self.setup_existing_account_len;
        @memcpy(self.setup_fields[1][0..len], self.setup_existing_account[0..len]);
        self.setup_lengths[1] = len;
        self.setup_action = .configure;
    }

    /// Display the exact saved configuration, retaining the other provider's
    /// draft. This owns paths only; Host/provider lifetimes belong to the App.
    pub fn configureSetup(self: *View, configuration: contract.RuntimeSetup) bool {
        self.saveSetupDraft();
        self.setup_runtime = configuration.runtime_kind;
        const complete = self.setup_drafts[self.setupIndex()].copy(configuration);
        self.loadSetupDraft();
        return complete;
    }

    fn setupIndex(self: *const View) usize {
        return if (self.setup_runtime == .codex) 0 else 1;
    }

    /// Public button order: configure/browser/device/refresh. Opening the
    /// returned login URL is independent of command/query/auth availability.
    pub fn setupActionEnabled(self: *const View, index: usize) bool {
        if (index >= self.setup_button_bounds.len or self.setup_busy or self.setup_login_pending) return false;
        return self.setup_runtime == .codex or (index != 1 and index != 2);
    }

    fn saveSetupDraft(self: *View) void {
        const draft = &self.setup_drafts[self.setupIndex()];
        for (self.setup_lengths, 0..) |len, index| {
            @memcpy(draft.fields[index][0..len], self.setup_fields[index][0..len]);
        }
        draft.lengths = self.setup_lengths;
    }

    fn loadSetupDraft(self: *View) void {
        const draft = &self.setup_drafts[self.setupIndex()];
        for (draft.lengths, 0..) |len, index| {
            @memcpy(self.setup_fields[index][0..len], draft.fields[index][0..len]);
        }
        self.setup_lengths = draft.lengths;
        self.setup_select_all = false;
    }

    fn selectSetupProvider(self: *View, runtime: contract.RuntimeKind) void {
        if (self.setup_runtime == runtime) return;
        self.saveSetupDraft();
        self.setup_runtime = runtime;
        self.loadSetupDraft();
        self.setup_field = 2;
    }

    fn toggleSetupAdvanced(self: *View) void {
        self.setup_advanced_open = !self.setup_advanced_open;
        if (!self.setup_advanced_open) self.setup_field = 2;
        self.setup_select_all = false;
    }

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
    pub const RunStatus = enum { idle, running, approval, failed, interrupted };
    pub const Entry = struct {
        id: transcript.Id = .{},
        label: [160]u8 = undefined,
        len: usize = 0,
        project_id: transcript.Id = .{},
        project_name: transcript.Id = .{},
        workspace_name: transcript.Id = .{},
        branch: transcript.Id = .{},
        run_status: RunStatus = .idle,
    };
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
        while (at + 1 < self.rich_count) : (at += 1) {
            self.rich_tiles[at] = self.rich_tiles[at + 1];
            self.rich_font_base[at] = self.rich_font_base[at + 1];
        }
        self.rich_count -= 1;
        self.rich_tiles[self.rich_count] = .{};
        self.rich_font_base[self.rich_count] = 0;
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
                const previous = slot.layout;
                try slot.update(text, tile, tileWidthForRole(info.role, width));
                if (previous != slot.layout) self.rich_font_base[index] = slot.size;
                applyTileInfo(slot, info, tile);
                self.applySelection(slot);
                return;
            }
            index += 1;
        }
        var incoming: transcript.RichTile = .{};
        errdefer incoming.deinit();
        try incoming.update(text, tile, tileWidthForRole(info.role, width));
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
        while (at > index) : (at -= 1) {
            self.rich_tiles[at] = self.rich_tiles[at - 1];
            self.rich_font_base[at] = self.rich_font_base[at - 1];
        }
        self.rich_tiles[index] = incoming;
        self.rich_font_base[index] = incoming.size;
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
        self.rich_font_base = @splat(0);
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

    fn selectedModel(self: *const View) ?*const Model {
        const selected = self.selected orelse return null;
        for (self.models[0..self.model_count]) |*model| if (sameModel(model.identity, selected)) return model;
        return null;
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

    /// Original source index, even when search/scope remove preceding cards.
    pub fn threadRowBounds(self: *const View, index: usize) c.SDL_FRect {
        if (self.scope_open or index >= self.thread_count or !self.threadMatches(&self.threads[index])) return zero_rect;
        return clippedRect(self.thread_bounds[index], self.sidebar_rows);
    }

    fn clippedRect(row: c.SDL_FRect, viewport: c.SDL_FRect) c.SDL_FRect {
        const x = @max(row.x, viewport.x);
        const y = @max(row.y, viewport.y);
        const right = @min(row.x + row.w, viewport.x + viewport.w);
        const bottom = @min(row.y + row.h, viewport.y + viewport.h);
        if (right <= x or bottom <= y) return zero_rect;
        return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    }

    fn threadMatches(self: *const View, entry: *const Entry) bool {
        if (self.scope_project.len != 0 and !entry.project_id.eql(self.scope_project.slice())) return false;
        const query = std.mem.trim(u8, self.search_query[0..self.search_len], " \t\r\n");
        if (query.len == 0) return true;
        // Literal Unicode with ASCII case-insensitivity; no history decode,
        // provider requests, allocation or unbounded indexing on the UI thread.
        for ([_][]const u8{ entry.label[0..entry.len], entry.project_name.slice(), entry.workspace_name.slice(), entry.branch.slice() }) |value| {
            if (std.ascii.indexOfIgnoreCase(value, query) != null) return true;
        }
        return false;
    }

    fn visibleThreadCount(self: *const View) usize {
        var count: usize = 0;
        for (self.threads[0..self.thread_count]) |*entry| if (self.threadMatches(entry)) {
            count += 1;
        };
        return count;
    }

    fn sidebarChanged(self: *View) void {
        self.sidebar_scroll = 0;
        self.search_hover = 0;
        self.sidebar_hover = null;
        self.thread_bounds = @splat(zero_rect);
    }

    fn searchInsert(self: *View, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const start = if (self.search_select_all) 0 else self.search_len;
        if (start + bytes.len > self.search_query.len) return error.TextTooLarge;
        @memcpy(self.search_query[start..][0..bytes.len], bytes);
        self.search_len = start + bytes.len;
        self.search_select_all = false;
        self.sidebarChanged();
    }

    fn searchResult(self: *const View, ordinal: usize) ?usize {
        var count: usize = 0;
        for (self.threads[0..self.thread_count], 0..) |*entry, index| {
            if (!self.threadMatches(entry)) continue;
            if (count == ordinal) return index;
            count += 1;
        }
        return null;
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
                        for (self.setup_provider_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.selectSetupProvider(if (index == 0) .codex else .opencode);
                        };
                        if (widgets.contains(self.setup_existing_bounds, x, y)) self.useExistingCodex();
                        if (widgets.contains(self.setup_advanced_bounds, x, y)) self.toggleSetupAdvanced();
                        if (self.setup_runtime == .codex and self.login_url_len != 0 and widgets.contains(self.setup_login_bounds, x, y)) self.setup_action = .open_login;
                        for (self.setup_field_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.setup_field = index;
                            self.setup_select_all = true;
                        };
                        for (self.setup_button_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            if (!self.setupActionEnabled(index)) break;
                            self.setup_action = switch (index) {
                                0 => .configure,
                                1 => .browser,
                                2 => .device,
                                else => .refresh,
                            };
                            self.setup_advanced_open = false;
                            self.setup_field = 2;
                        };
                        return true;
                    }
                    if (self.effort_open) {
                        if (self.selectedModel()) |model| {
                            for (self.effort_rows[0..model.effort_count], 0..) |box, index| if (widgets.contains(box, x, y)) {
                                self.selected.?.effort = model.efforts[index];
                            };
                        }
                        self.effort_open = false;
                        return true;
                    }
                    // An open menu owns pointer input, including outside dismissal.
                    if (self.picker_open) {
                        if (self.pickerIndexAt(x, y)) |index| self.selected = self.models[index].identity;
                        self.picker_open = false;
                        return true;
                    }
                    if (self.scope_open) {
                        if (widgets.contains(self.scope_all_bounds, x, y)) {
                            self.scope_project = .{};
                            self.sidebarChanged();
                        }
                        for (self.project_bounds[0..self.project_count], 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.scope_project = self.projects[index].id;
                            self.sidebarChanged();
                        };
                        self.scope_open = false;
                        return true;
                    }
                    if (widgets.contains(self.search_bounds, x, y)) {
                        self.search_focused = true;
                        self.search_select_all = false;
                        if (widgets.contains(self.search_clear_bounds, x, y)) {
                            self.search_len = 0;
                            self.sidebarChanged();
                        }
                        try self.focus(window, true);
                        const area = c.SDL_Rect{ .x = @intFromFloat(self.search_bounds.x), .y = @intFromFloat(self.search_bounds.y), .w = @intFromFloat(self.search_bounds.w), .h = @intFromFloat(self.search_bounds.h) };
                        if (!c.SDL_SetTextInputArea(window, &area, 0)) return error.TextInputArea;
                        return true;
                    }
                    self.search_focused = false;
                    if (widgets.contains(self.scope_bounds, x, y)) {
                        self.scope_open = true;
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
                        if (self.selectedModel()) |model| {
                            self.effort_open = model.effort_count > 0;
                            self.effort_hover = 0;
                            if (self.selected) |selected| for (model.efforts[0..model.effort_count], 0..) |effort, index| {
                                if (effort.eql(selected.effort.slice())) self.effort_hover = index;
                            };
                        }
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
                            for (0..self.thread_count) |index| if (widgets.contains(self.threadRowBounds(index), x, y)) {
                                self.navigation = .{ .thread = index };
                            };
                        }
                        return true;
                    }
                }
                if (self.custom_root) |root| {
                    for (root.nodes[0..root.count], 0..) |node, index| {
                        const box = self.customVisibleBounds(index);
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
                if (self.custom_root == null and self.effort_open) {
                    for (self.effort_rows, 0..) |row, index| if (widgets.contains(row, event.motion.x, event.motion.y)) {
                        self.effort_hover = index;
                    };
                    return true;
                }
                if (self.custom_root == null and self.picker_open) {
                    if (self.pickerIndexAt(event.motion.x, event.motion.y)) |index| self.picker_hover = index;
                    return true;
                }

                if (self.custom_root == null) {
                    const previous = self.sidebar_hover;
                    self.sidebar_hover = null;
                    for (0..self.thread_count) |index| if (widgets.contains(self.threadRowBounds(index), event.motion.x, event.motion.y)) {
                        self.sidebar_hover = index;
                    };
                    if (!self.dragging and self.transcript_drag == null and previous != self.sidebar_hover) return true;
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
                if (self.custom_root == null and (self.setup_open or self.effort_open)) return true;
                if (self.custom_root == null and self.picker_open) {
                    if (widgets.contains(self.picker_menu, event.wheel.mouse_x, event.wheel.mouse_y)) self.picker_scroll = std.math.clamp(self.picker_scroll - event.wheel.y * wheel_direction * picker_row_height, 0, self.pickerMaxScroll());
                    return true;
                }
                if (self.custom_root == null and widgets.contains(self.sidebar_bounds, event.wheel.mouse_x, event.wheel.mouse_y)) {
                    if (self.scope_open) {
                        const height = @as(f32, @floatFromInt(self.project_count + 1)) * 28;
                        self.scope_scroll = std.math.clamp(self.scope_scroll - event.wheel.y * wheel_direction * 28, 0, @max(0, height - self.scope_menu.h + 8));
                    } else {
                        const height = @as(f32, @floatFromInt(self.visibleThreadCount())) * sidebar_card_stride;
                        self.sidebar_scroll = std.math.clamp(self.sidebar_scroll - event.wheel.y * wheel_direction * 36, 0, @max(0, height - self.sidebar_rows.h));
                    }
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
                if (self.custom_root == null and (self.setup_open or self.picker_open or self.effort_open or self.search_focused)) return true;
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
                if (self.custom_root == null and (self.picker_open or self.effort_open)) return true;
                if (self.setup_open and self.custom_root == null) {
                    try self.setupInsert(std.mem.span(event.text.text));
                    return true;
                }
                if (self.custom_root == null and self.search_focused) {
                    if (!self.window_active) return false;
                    try self.searchInsert(std.mem.span(event.text.text));
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
                    const alt = mods & c.SDL_KMOD_ALT != 0;
                    if (key == c.SDLK_ESCAPE) self.setup_open = false;
                    if (alt and key == c.SDLK_1) self.selectSetupProvider(.codex);
                    if (alt and key == c.SDLK_2) self.selectSetupProvider(.opencode);
                    if (alt and key == c.SDLK_A) self.toggleSetupAdvanced();
                    if (ctrl and key == c.SDLK_L and self.setup_runtime == .codex and self.login_url_len != 0) self.setup_action = .open_login;
                    if (key == c.SDLK_TAB) {
                        if (self.setup_advanced_open) {
                            // Visual order: Workspace, executable, account, provider.
                            const order = [_]usize{ 2, 0, 1, 3 };
                            var position: usize = 0;
                            for (order, 0..) |field, index| if (field == self.setup_field) {
                                position = index;
                            };
                            self.setup_field = order[(position + (if (shift) @as(usize, 3) else 1)) % order.len];
                        } else self.setup_field = 2;
                        self.setup_select_all = true;
                    }
                    if (ctrl and key == c.SDLK_A) self.setup_select_all = true;
                    if (key == c.SDLK_RETURN and self.setupActionEnabled(0)) {
                        self.setup_action = .configure;
                        self.setup_advanced_open = false;
                        self.setup_field = 2;
                    }
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
                if (self.effort_open and self.custom_root == null) {
                    if (self.selectedModel()) |model| {
                        if (key == c.SDLK_UP) self.effort_hover -|= 1;
                        if (key == c.SDLK_DOWN) self.effort_hover = @min(model.effort_count -| 1, self.effort_hover + 1);
                        if (key == c.SDLK_RETURN and self.effort_hover < model.effort_count) {
                            self.selected.?.effort = model.efforts[self.effort_hover];
                            self.effort_open = false;
                        }
                    }
                    if (key == c.SDLK_ESCAPE) self.effort_open = false;
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
                if (self.scope_open and self.custom_root == null) {
                    if (key == c.SDLK_ESCAPE) self.scope_open = false;
                    return true;
                }
                if (self.search_focused and self.custom_root == null) {
                    if (!self.window_active) return false;
                    if (ctrl and key == c.SDLK_A) self.search_select_all = true;
                    if (ctrl and key == c.SDLK_V) {
                        const value = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                        defer c.SDL_free(value);
                        try self.searchInsert(std.mem.span(value));
                    }
                    if (key == c.SDLK_ESCAPE) {
                        self.search_len = 0;
                        self.search_select_all = false;
                        self.search_focused = false;
                        self.sidebarChanged();
                    }
                    if (key == c.SDLK_BACKSPACE or key == c.SDLK_DELETE) {
                        if (self.search_select_all) {
                            self.search_len = 0;
                        } else if (key == c.SDLK_BACKSPACE and self.search_len > 0) {
                            self.search_len -= 1;
                            while (self.search_len > 0 and self.search_query[self.search_len] & 0xc0 == 0x80) self.search_len -= 1;
                        }
                        self.search_select_all = false;
                        self.sidebarChanged();
                    }
                    if (key == c.SDLK_UP) self.search_hover -|= 1;
                    if (key == c.SDLK_DOWN) self.search_hover = @min(self.visibleThreadCount() -| 1, self.search_hover + 1);
                    if (key == c.SDLK_UP or key == c.SDLK_DOWN) {
                        const top = @as(f32, @floatFromInt(self.search_hover)) * sidebar_card_stride;
                        if (top < self.sidebar_scroll) self.sidebar_scroll = top;
                        if (top + sidebar_card_stride > self.sidebar_scroll + self.sidebar_rows.h) self.sidebar_scroll = @max(0, top + sidebar_card_stride - self.sidebar_rows.h);
                    }
                    if ((key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) and self.navigation_enabled) {
                        if (self.searchResult(self.search_hover)) |index| {
                            self.navigation = .{ .thread = index };
                            self.search_focused = false;
                            self.search_len = 0;
                            self.search_select_all = false;
                            self.sidebarChanged();
                        }
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
                        try self.editor_view.moveVertical(text, &self.editor, self.composerFontSize(), key == c.SDLK_DOWN, shift);
                        self.reveal_caret = true;
                    },
                    c.SDLK_HOME, c.SDLK_END => {
                        try self.editor_view.moveLineEdge(text, &self.editor, self.composerFontSize(), key == c.SDLK_END, ctrl, shift);
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

    fn nodeStyle(self: *const View, kind: c_int) script_api.abi.SpicaScriptStyle {
        var result = std.mem.zeroes(script_api.abi.SpicaScriptStyle);
        if (self.custom_root) |root| for (root.nodes[0..root.count]) |node| {
            if (node.kind == kind) result = node.style;
        };
        return result;
    }

    fn styleColor(style: script_api.abi.SpicaScriptStyle, foreground: bool, fallback: Color) Color {
        const mask = if (foreground) script_api.abi.SPICA_STYLE_FOREGROUND else script_api.abi.SPICA_STYLE_BACKGROUND;
        if (style.present & mask == 0) return fallback;
        const rgb = if (foreground) style.foreground else style.background;
        return .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
    }

    fn composerFontSize(self: *const View) f32 {
        const style = self.nodeStyle(4);
        return if (style.present & script_api.abi.SPICA_STYLE_FONT_SIZE != 0) style.font_size else 16;
    }

    fn padded(box: c.Clay_BoundingBox, style: script_api.abi.SpicaScriptStyle) c.Clay_BoundingBox {
        if (style.present & script_api.abi.SPICA_STYLE_PADDING == 0) return box;
        const padding_x = @min(style.padding, box.width / 2);
        const padding_y = @min(style.padding, box.height / 2);
        return .{ .x = box.x + padding_x, .y = box.y + padding_y, .width = @max(0, box.width - padding_x * 2), .height = @max(0, box.height - padding_y * 2) };
    }

    fn transcriptDesign(self: *const View) @import("design.zig").Config {
        var design = self.design;
        const style = self.nodeStyle(5);
        design.colors.foreground = styleColor(style, true, design.colors.foreground);
        design.colors.surface = styleColor(style, false, design.colors.surface);
        if (style.present & script_api.abi.SPICA_STYLE_RADIUS != 0) design.layout.radius = style.radius;
        return design;
    }

    fn styleTile(self: *View, tile: *transcript.RichTile) void {
        var base = &self.custom_font_base;
        for (&self.rich_tiles, 0..) |*candidate, index| if (candidate == tile) {
            base = &self.rich_font_base[index];
            break;
        };
        if (base.* == 0) base.* = tile.size;
        const style = self.nodeStyle(5);
        const size: c_uint = if (style.present & script_api.abi.SPICA_STYLE_FONT_SIZE != 0) @intFromFloat(style.font_size) else base.*;
        if (tile.size != size) {
            tile.size = size;
            tile.width = 0; // Reflow retained spans; restore original size on reload.
        }
    }

    fn tileWidthForRole(role: []const u8, width: f32) f32 {
        return @max(25, if (std.mem.eql(u8, role, "user")) width * 0.85 else width);
    }

    fn intersection(box: c.Clay_BoundingBox, parent: c.Clay_BoundingBox) c.Clay_BoundingBox {
        const x = @max(box.x, parent.x);
        const y = @max(box.y, parent.y);
        return .{ .x = x, .y = y, .width = @max(0, @min(box.x + box.width, parent.x + parent.width) - x), .height = @max(0, @min(box.y + box.height, parent.y + parent.height) - y) };
    }

    /// Parent clipping is shared by painting and custom-button admission. A
    /// fixed-size child may overflow Clay's parent but cannot gain invisible hits.
    fn customVisibleBounds(self: *const View, index: usize) c.Clay_BoundingBox {
        const root = self.custom_root orelse return std.mem.zeroes(c.Clay_BoundingBox);
        var result = self.custom_bounds[index];
        var parent = root.nodes[index].parent;
        var depth: usize = 0;
        while (parent < root.count and depth < 8) : (depth += 1) {
            result = intersection(result, self.custom_bounds[parent]);
            parent = root.nodes[parent].parent;
        }
        return result;
    }

    fn ensurePreedit(self: *View, text: *c.SpicaText, width: f32) !void {
        const font_size = self.composerFontSize();
        if (!self.preedit_changed and self.preedit_width == width and self.preedit_font_size == font_size) return;
        if (self.preedit_layout) |layout| c.spica_text_layout_release(layout);
        self.preedit_layout = null;
        if (self.preedit_len != 0) {
            self.preedit_layout = c.spica_text_layout_create(text, &self.preedit, self.preedit_len, width, @intFromFloat(font_size), false) orelse return error.PreeditLayout;
        }
        self.preedit_width = width;
        self.preedit_font_size = font_size;
        self.preedit_changed = false;
    }

    pub fn sidebarWidth(self: *const View, width: f32) f32 {
        return Layout.sidebarWidthWith(self.design, width);
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

    // Fixed native strokes: no decorative Unicode, face discovery or retained
    // icon textures. Coordinates use a 16-unit local grid.
    const Icon = enum { plus, folder, pen, chevron, send, stop, settings, search, filter, branch, close };
    fn icon(renderer: *c.SDL_Renderer, kind: Icon, x: f32, y: f32, color: Color) !void {
        // ComposerPrimaryActions.tsx uses an 8px filled rounded square inside
        // its 12px Stop glyph, centered in the 32px action.
        if (kind == .stop) return widgets.panel(renderer, .{ .x = x + 4, .y = y + 4, .w = 8, .h = 8 }, 1.5, color);
        if (!c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255)) return error.IconDraw;
        const paths: []const [4]f32 = switch (kind) {
            .search => &.{ .{ 3, 2, 9, 2 }, .{ 9, 2, 12, 5 }, .{ 12, 5, 12, 9 }, .{ 12, 9, 9, 12 }, .{ 9, 12, 3, 12 }, .{ 3, 12, 1, 9 }, .{ 1, 9, 1, 5 }, .{ 1, 5, 3, 2 }, .{ 11, 11, 15, 15 } },
            .filter => &.{ .{ 1, 3, 15, 3 }, .{ 4, 8, 12, 8 }, .{ 6, 13, 10, 13 } },
            .branch => &.{ .{ 4, 2, 4, 13 }, .{ 4, 9, 11, 9 }, .{ 11, 9, 12, 7 }, .{ 12, 7, 12, 3 }, .{ 2, 1, 6, 1 }, .{ 10, 2, 14, 2 }, .{ 2, 14, 6, 14 } },
            .close => &.{ .{ 4, 4, 12, 12 }, .{ 12, 4, 4, 12 } },
            .plus => &.{ .{ 8, 2, 8, 14 }, .{ 2, 8, 14, 8 } },
            .folder => &.{ .{ 1, 4, 6, 4 }, .{ 6, 4, 8, 6 }, .{ 8, 6, 15, 6 }, .{ 15, 6, 15, 14 }, .{ 15, 14, 1, 14 }, .{ 1, 14, 1, 4 } },
            .pen => &.{ .{ 9, 3, 2, 3 }, .{ 2, 3, 2, 14 }, .{ 2, 14, 13, 14 }, .{ 13, 14, 13, 9 }, .{ 7, 10, 8, 6 }, .{ 8, 6, 13, 1 }, .{ 13, 1, 16, 4 }, .{ 16, 4, 10, 10 }, .{ 10, 10, 7, 10 } },
            .chevron => &.{ .{ 4, 6, 8, 10 }, .{ 8, 10, 12, 6 } },
            .send => &.{ .{ 8, 14, 8, 2 }, .{ 8, 2, 3, 7 }, .{ 8, 2, 13, 7 } },
            .stop => &.{ .{ 2, 2, 14, 2 }, .{ 14, 2, 14, 14 }, .{ 14, 14, 2, 14 }, .{ 2, 14, 2, 2 } },
            .settings => &.{ .{ 2, 4, 14, 4 }, .{ 2, 12, 14, 12 }, .{ 5, 1, 5, 7 }, .{ 11, 9, 11, 15 } },
        };
        for (paths) |line| if (!c.SDL_RenderLine(renderer, x + line[0], y + line[1], x + line[2], y + line[3])) return error.IconDraw;
    }

    fn drawChrome(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        const metrics = self.design.layout;
        const palette = self.design.colors;
        const sidebar = self.sidebarWidth(bounds.header.width);
        const height = bounds.composer.y + bounds.composer.height + metrics.gutter;
        const inset = @min(metrics.gutter, 20);
        const radius = @min(metrics.radius, 8);
        self.sidebar_bounds = .{ .x = 0, .y = 0, .w = sidebar, .h = height };
        try widgets.panel(renderer, self.sidebar_bounds, 0, palette.sidebar);
        try widgets.panel(renderer, .{ .x = sidebar - 1, .y = 0, .w = 1, .h = height }, 0, palette.sidebar_border);
        try self.labels.draw(text, "Spica", inset, (bounds.header.height - 16) / 2, 14, foreground);
        // Current eb1510d source puts Search and all three icon actions on
        // one 32px row. The older marketing image uses a separate scope row.
        const row_top = bounds.header.height + 4;
        const action_y = row_top + 2;
        self.new_thread_bounds = .{ .x = sidebar - 36, .y = action_y, .w = 28, .h = 28 };
        self.new_project_bounds = .{ .x = sidebar - 65, .y = action_y, .w = 28, .h = 28 };
        self.scope_bounds = .{ .x = sidebar - 94, .y = action_y, .w = 28, .h = 28 };
        self.search_bounds = .{ .x = 8, .y = row_top, .w = @max(0, self.scope_bounds.x - 9), .h = 32 };
        self.search_clear_bounds = if (self.search_len == 0) zero_rect else .{ .x = self.search_bounds.x + self.search_bounds.w - 22, .y = action_y, .w = 22, .h = 28 };
        const sidebar_muted = palette.sidebar_muted;
        if (self.search_focused) try widgets.panel(renderer, self.search_bounds, 6, palette.raised);
        try icon(renderer, .search, 16, row_top + 8, sidebar_muted);
        const search_label = if (self.search_len == 0) "Search" else self.search_query[0..self.search_len];
        try self.labels.drawFitted(renderer, text, search_label, 40, row_top + 8, self.search_bounds.w - 32 - (if (self.search_len == 0) @as(f32, 0) else 22), 14, if (self.search_len == 0) sidebar_muted else foreground);
        if (self.search_focused and self.search_bounds.w > 40) {
            var search_clip = widgets.Clip.push(renderer, .{ .x = 40, .y = row_top + 6, .w = @max(0, self.search_bounds.w - 54), .h = 20 });
            defer search_clip.restore(renderer);
            const text_width = try self.labels.width(text, @import("../text/utf8.zig").prefix(self.search_query[0..self.search_len], 128), 14);
            if (self.search_select_all and self.search_len > 0) {
                try widgets.panel(renderer, .{ .x = 40, .y = row_top + 6, .w = text_width, .h = 20 }, 2, palette.selection);
                try self.labels.drawFitted(renderer, text, self.search_query[0..self.search_len], 40, row_top + 8, self.search_bounds.w - 54, 14, foreground);
            } else {
                try widgets.panel(renderer, .{ .x = 40 + @min(text_width, @max(0, self.search_bounds.w - 56)), .y = row_top + 8, .w = 1, .h = 16 }, 0, foreground);
            }
        }
        if (self.search_len != 0) try icon(renderer, .close, self.search_clear_bounds.x + 3, row_top + 8, sidebar_muted);
        if (self.scope_project.len != 0) try widgets.panel(renderer, self.scope_bounds, 6, palette.sidebar_active);
        try icon(renderer, .filter, self.scope_bounds.x + 6, action_y + 6, sidebar_muted);
        try icon(renderer, .folder, self.new_project_bounds.x + 6, action_y + 5, sidebar_muted);
        try icon(renderer, .plus, self.new_project_bounds.x + 8, action_y + 7, sidebar_muted);
        try icon(renderer, .pen, self.new_thread_bounds.x + 6, action_y + 6, sidebar_muted);
        self.sidebar_rows = .{ .x = 8, .y = row_top + 40, .w = sidebar - 16, .h = @max(0, height - row_top - 84) };
        const rows_height = @as(f32, @floatFromInt(self.visibleThreadCount())) * sidebar_card_stride;
        self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, rows_height - self.sidebar_rows.h));
        self.project_bounds = @splat(zero_rect);
        self.thread_bounds = @splat(zero_rect);
        var clip = widgets.Clip.push(renderer, self.sidebar_rows);
        defer clip.restore(renderer);
        try self.drawThreads(renderer, text, foreground, sidebar_muted);
        if (self.visibleThreadCount() == 0) try self.labels.drawFitted(renderer, text, if (self.search_len != 0) "No threads found" else "No threads in this project", 18, self.sidebar_rows.y + 12, sidebar - 36, 12, sidebar_muted);
        clip.restore(renderer);
        // Connection is the implemented utility. Do not imitate unavailable
        // Usage, Pull Requests or Settings destinations from the reference.
        self.setup_bounds = .{ .x = 8, .y = height - 36, .w = 32, .h = 32 };
        try icon(renderer, .settings, 16, height - 28, sidebar_muted);
        try self.labels.drawFitted(renderer, text, self.status, 48, height - 25, sidebar - 60, 11, sidebar_muted);
        if (self.scope_open) try self.drawScope(renderer, text, foreground, sidebar_muted);
        const header_x = sidebar + metrics.gutter;
        var project_name: []const u8 = "Workspace";
        var thread_name: []const u8 = "New chat";
        for (self.projects[0..self.project_count]) |*entry| if (entry.id.eql(self.active_project.slice())) {
            project_name = entry.label[0..entry.len];
        };
        for (self.threads[0..self.thread_count]) |*entry| if (entry.id.eql(self.active_thread.slice())) {
            thread_name = entry.label[0..entry.len];
            if (entry.project_name.len != 0) project_name = entry.project_name.slice();
        };
        const project_width = @min(@max(0, bounds.header.width - header_x - metrics.gutter) * 0.3, try self.labels.width(text, @import("../text/utf8.zig").prefix(project_name, 128), 14));
        try icon(renderer, .folder, header_x, (bounds.header.height - 16) / 2, muted);
        try self.labels.drawFitted(renderer, text, project_name, header_x + 24, (bounds.header.height - 16) / 2, project_width, 14, muted);
        try self.labels.draw(text, "/", header_x + 34 + project_width, (bounds.header.height - 16) / 2, 14, muted);
        const title_x = header_x + 52 + project_width;
        try self.labels.drawFitted(renderer, text, thread_name, title_x, (bounds.header.height - 16) / 2, bounds.header.width - title_x - metrics.gutter, 14, foreground);
        self.follow_bounds = if (self.follow_latest) zero_rect else .{ .x = bounds.transcript.x + bounds.transcript.width - 128, .y = bounds.transcript.y + bounds.transcript.height - 32, .w = 128, .h = 28 };
        for (self.tasks[0..self.task_count], 0..) |*task, index| {
            const task_y = bounds.transcript.y + @as(f32, @floatFromInt(index)) * 24;
            try self.labels.drawFitted(renderer, text, task.bytes[0..task.len], bounds.transcript.x, task_y, bounds.transcript.width - 84, 12, muted);
            task.cancel_bounds = .{ .x = bounds.transcript.x + bounds.transcript.width - 76, .y = task_y, .w = 76, .h = 20 };
            if (task.cancel != null) {
                try widgets.panel(renderer, task.cancel_bounds, radius / 2, palette.raised);
                try self.labels.draw(text, "Cancel task", task.cancel_bounds.x + 4, task_y + 2, 11, foreground);
            }
        }
    }

    fn drawScope(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, foreground: Color, muted: Color) !void {
        const height = @min(@as(f32, @floatFromInt(self.project_count + 1)) * 28 + 8, self.sidebar_rows.h);
        self.scope_menu = .{ .x = 8, .y = self.sidebar_rows.y, .w = self.sidebar_rows.w, .h = height };
        self.scope_scroll = std.math.clamp(self.scope_scroll, 0, @max(0, @as(f32, @floatFromInt(self.project_count + 1)) * 28 - height + 8));
        try widgets.panel(renderer, self.scope_menu, 6, self.design.colors.border);
        var clip = widgets.Clip.push(renderer, self.scope_menu);
        defer clip.restore(renderer);
        var y = self.scope_menu.y + 4 - self.scope_scroll;
        self.scope_all_bounds = clippedRect(.{ .x = 12, .y = y, .w = self.scope_menu.w - 8, .h = 28 }, self.scope_menu);
        if (self.scope_project.len == 0) try widgets.panel(renderer, self.scope_all_bounds, 4, self.design.colors.sidebar_active);
        try self.labels.drawFitted(renderer, text, "All projects", 20, y + 7, self.scope_menu.w - 24, 12, foreground);
        y += 28;
        for (self.projects[0..self.project_count], 0..) |*entry, index| {
            self.project_bounds[index] = clippedRect(.{ .x = 12, .y = y, .w = self.scope_menu.w - 8, .h = 28 }, self.scope_menu);
            if (self.scope_project.eql(entry.id.slice())) try widgets.panel(renderer, self.project_bounds[index], 4, self.design.colors.sidebar_active);
            try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], 20, y + 7, self.scope_menu.w - 24, 12, muted);
            y += 28;
        }
    }

    fn drawThreads(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, foreground: Color, muted: Color) !void {
        var y = self.sidebar_rows.y - self.sidebar_scroll;
        var ordinal: usize = 0;
        for (self.threads[0..self.thread_count], 0..) |*entry, index| {
            if (!self.threadMatches(entry)) continue;
            const row = c.SDL_FRect{ .x = self.sidebar_rows.x, .y = y + 2, .w = self.sidebar_rows.w, .h = 78 };
            self.thread_bounds[index] = clippedRect(row, self.sidebar_rows);
            if (self.thread_bounds[index].h > 0) {
                const active = entry.id.eql(self.active_thread.slice());
                if (active) {
                    try widgets.panel(renderer, row, @min(self.design.layout.radius, 6), self.design.colors.sidebar_active);
                } else if (self.sidebar_hover == index or (self.search_focused and self.search_len != 0 and self.search_hover == ordinal)) {
                    try widgets.panel(renderer, row, @min(self.design.layout.radius, 6), self.design.colors.sidebar_hover);
                }
                const x = row.x + 10;
                const width = row.w - 20;
                if (entry.project_name.len != 0) {
                    try icon(renderer, .folder, x, row.y + 9, muted);
                    try self.labels.drawFitted(renderer, text, entry.project_name.slice(), x + 22, row.y + 10, width - 22 - (if (entry.run_status == .idle) @as(f32, 0) else 72), 12, muted);
                }
                if (entry.run_status != .idle) {
                    const status_label: []const u8 = switch (entry.run_status) {
                        .running => "Working",
                        .approval => "Approval",
                        .failed => "Failed",
                        .interrupted => "Interrupted",
                        .idle => unreachable,
                    };
                    try self.labels.drawFitted(renderer, text, status_label, row.x + row.w - 76, row.y + 10, 66, 11, muted);
                }
                try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], x, row.y + 32, width, 14, foreground);
                const metadata = if (entry.branch.len != 0) entry.branch.slice() else entry.workspace_name.slice();
                if (metadata.len != 0) {
                    try icon(renderer, if (entry.branch.len != 0) .branch else .folder, x, row.y + 54, muted);
                    try self.labels.drawFitted(renderer, text, metadata, x + 20, row.y + 56, width - 40, 12, muted);
                }
            }
            ordinal += 1;
            y += sidebar_card_stride;
        }
    }

    fn disabledPrimaryColor(color: Color, surface: Color) Color {
        // T3 eb1510d ComposerPrimaryActions.tsx:313-317 keeps message-action
        // fill/foreground and applies opacity-64 to the complete disabled
        // button. Composite both opaque native paints against its real surface
        // without allocating an intermediate texture or blending the glyph
        // a second time over the already faded circle.
        var result: Color = undefined;
        inline for (std.meta.fields(Color)) |field| {
            const channel = @as(u32, @field(color, field.name)) * 64 + @as(u32, @field(surface, field.name)) * 36;
            @field(result, field.name) = @intCast((channel + 50) / 100);
        }
        return result;
    }

    fn drawComposerControls(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, panel: c.SDL_FRect, foreground: Color, muted: Color) !void {
        self.controls = @splat(zero_rect);
        const gap = self.design.layout.gap;
        const y = panel.y + panel.h - 54 - @min(gap, 16);
        const primary: usize = if (self.can_cancel) 1 else 0;
        self.controls[primary] = .{ .x = panel.x + panel.w - 44, .y = y - 2, .w = 32, .h = 32 };
        const model_x = panel.x + 10;
        const available = @max(0, self.controls[primary].x - model_x - gap * 2);
        const label = if (self.selected) |*selected| (if (selected.runtime_kind.eql("fake")) "Demo · synthetic" else selected.model_id.slice()) else "Choose model";
        const effort = if (self.selected) |*selected| selected.effort.slice() else "Effort";
        const prefix = @import("../text/utf8.zig").prefix;
        const desired_effort = try self.labels.width(text, prefix(effort, 128), 14) + 34;
        const effort_width = @min(desired_effort, available * 0.38);
        const desired_model = try self.labels.width(text, prefix(label, 128), 14) + 40;
        const model_width = @min(desired_model, @max(0, available - effort_width));
        self.picker_bounds = .{ .x = model_x, .y = y, .w = model_width, .h = 28 };
        self.effort_bounds = .{ .x = model_x + model_width + gap, .y = y, .w = effort_width, .h = 28 };
        // Keep menu geometry current while closed, so first-open keyboard
        // reveal uses the same viewport as the next paint.
        const menu_height = @min(344, @max(96, y - 80));
        self.picker_menu = .{ .x = panel.x, .y = y - menu_height - 6, .w = @min(600, panel.w), .h = menu_height };
        self.picker_rows = .{ .x = self.picker_menu.x + 8, .y = self.picker_menu.y + 38, .w = self.picker_menu.w - 16, .h = menu_height - 64 };

        try self.labels.drawFitted(renderer, text, label, self.picker_bounds.x + 8, y + 6, model_width - 32, 14, foreground);
        try icon(renderer, .chevron, self.picker_bounds.x + model_width - 24, y + 6, muted);
        try self.labels.drawFitted(renderer, text, effort, self.effort_bounds.x + 8, y + 6, self.effort_bounds.w - 30, 14, muted);
        try icon(renderer, .chevron, self.effort_bounds.x + self.effort_bounds.w - 22, y + 6, muted);
        const enabled = if (primary == 1) self.can_cancel else self.can_send and self.editor.len != 0;
        const primary_color = if (primary == 1) self.design.colors.danger else self.design.colors.accent;
        const composer_surface = styleColor(self.nodeStyle(4), false, self.design.colors.surface);
        const primary_fill = if (enabled) primary_color else disabledPrimaryColor(primary_color, composer_surface);
        const primary_foreground = if (enabled) self.design.colors.accent_text else disabledPrimaryColor(self.design.colors.accent_text, composer_surface);
        try widgets.panel(renderer, self.controls[primary], 16, primary_fill);
        try icon(renderer, if (primary == 1) .stop else .send, self.controls[primary].x + 8, self.controls[primary].y + 8, primary_foreground);
        if (self.can_approve) {
            try self.labels.drawFitted(renderer, text, "Approval needed", panel.x + 12, y - 28, panel.w - 206, 12, foreground);
            for (2..4) |index| {
                self.controls[index] = .{ .x = panel.x + panel.w - 188 + @as(f32, @floatFromInt(index - 2)) * 90, .y = y - 34, .w = 80, .h = 28 };
                try widgets.panel(renderer, self.controls[index], @min(self.design.layout.radius, 4), self.design.colors.selection);
                try self.labels.draw(text, if (index == 2) "Allow F7" else "Deny F8", self.controls[index].x + 10, y - 27, 12, foreground);
            }
        }
        const guidance = self.send_disabled_reason orelse if (self.can_cancel) "Working · Stop cancels the current run" else if (self.selected == null) "Choose a model, or open Connection to refresh models" else if (!self.can_send) self.status else if (self.editor.len == 0) "Write a message · Enter sends · Shift+Enter adds a line" else "Enter to send · Shift+Enter for a new line";
        try self.labels.drawFitted(renderer, text, guidance, panel.x + 2, panel.y + panel.h - 16, panel.w - 4, 11, muted);
    }

    fn drawEffort(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, foreground: Color, muted: Color) !void {
        const model = self.selectedModel() orelse return;
        const height = @as(f32, @floatFromInt(model.effort_count)) * 28 + 8;
        self.effort_menu = .{ .x = self.effort_bounds.x, .y = @max(0, self.effort_bounds.y - height - 6), .w = @max(100, self.effort_bounds.w), .h = height };
        try widgets.panel(renderer, self.effort_menu, @min(self.design.layout.radius, 6), self.design.colors.raised);
        self.effort_rows = @splat(zero_rect);
        for (model.efforts[0..model.effort_count], 0..) |effort, index| {
            const row = c.SDL_FRect{ .x = self.effort_menu.x + 4, .y = self.effort_menu.y + 4 + @as(f32, @floatFromInt(index)) * 28, .w = self.effort_menu.w - 8, .h = 28 };
            self.effort_rows[index] = row;
            if (index == self.effort_hover) try widgets.panel(renderer, row, 4, self.design.colors.selection);
            try self.labels.drawFitted(renderer, text, effort.slice(), row.x + 6, row.y + 6, row.w - 12, 12, if (index == self.effort_hover) foreground else muted);
        }
    }

    fn drawPicker(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        const height = @min(344, @max(96, self.picker_bounds.y - 80));
        self.picker_menu = .{ .x = bounds.composer.x, .y = self.picker_bounds.y - height - 6, .w = @min(600, bounds.composer.width), .h = height };
        const menu = self.picker_menu;
        self.picker_rows = .{ .x = menu.x + 8, .y = menu.y + 38, .w = menu.w - 16, .h = menu.h - 64 };
        self.picker_scroll = std.math.clamp(self.picker_scroll, 0, self.pickerMaxScroll());
        try widgets.panel(renderer, menu, @min(self.design.layout.radius, 8), self.design.colors.raised);
        try self.labels.draw(text, "Choose model", menu.x + 14, menu.y + 12, 13, foreground);
        var clip = widgets.Clip.push(renderer, self.picker_rows);
        defer clip.restore(renderer);
        if (self.model_count == 0) try self.labels.drawFitted(renderer, text, "No models. Open Connection → Refresh models.", self.picker_rows.x + 6, self.picker_rows.y + 10, self.picker_rows.w - 12, 12, foreground);
        for (self.models[0..self.model_count], 0..) |*model, index| {
            const y = self.picker_rows.y + @as(f32, @floatFromInt(index)) * picker_row_height - self.picker_scroll;
            if (y + picker_row_height <= self.picker_rows.y or y >= self.picker_rows.y + self.picker_rows.h) continue;
            if (index == self.picker_hover) try widgets.panel(renderer, .{ .x = self.picker_rows.x, .y = y, .w = self.picker_rows.w, .h = picker_row_height - 2 }, @min(self.design.layout.radius, 4), self.design.colors.selection);
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
        const height = bounds.composer.y + bounds.composer.height + self.design.layout.gutter;
        const geometry = Layout.setup(width, height, self.setup_advanced_open);
        const menu = geometry.menu;
        self.setup_menu = menu;
        self.setup_close_bounds = geometry.close;
        self.setup_provider_bounds = geometry.providers;
        // Retain the old toggle rectangle for native consumers; it denotes
        // the other provider's actual painted choice, never the gap between.
        self.setup_runtime_bounds = geometry.providers[1 - self.setupIndex()];
        self.setup_advanced_bounds = geometry.advanced;
        self.setup_existing_bounds = zero_rect;
        if (self.setup_runtime == .codex and self.setup_existing_account_len != 0) {
            self.setup_advanced_bounds.w = (geometry.advanced.w - 8) / 2;
            self.setup_existing_bounds = .{ .x = self.setup_advanced_bounds.x + self.setup_advanced_bounds.w + 8, .y = geometry.advanced.y, .w = self.setup_advanced_bounds.w, .h = geometry.advanced.h };
        }
        self.setup_field_bounds = geometry.fields;
        self.setup_button_bounds = geometry.buttons;
        self.setup_login_bounds = zero_rect;
        try widgets.panel(renderer, menu, @min(self.design.layout.radius, 8), self.design.colors.raised);
        var clip = widgets.Clip.push(renderer, menu);
        defer clip.restore(renderer);
        const title = if (self.setup_login_pending) "Connection setup · Sign-in pending" else if (self.setup_busy) "Connection setup · Working…" else "Connection setup";
        try self.labels.drawFitted(renderer, text, title, menu.x + 16, menu.y + 15, menu.w - 116, 16, foreground);
        try widgets.panel(renderer, self.setup_close_bounds, @min(self.design.layout.radius, 4), self.design.colors.surface);
        try self.labels.draw(text, "Close Esc", self.setup_close_bounds.x + 7, menu.y + 19, 11, foreground);
        for (self.setup_provider_bounds, 0..) |box, index| {
            const selected = self.setupIndex() == index;
            try widgets.panel(renderer, box, @min(self.design.layout.radius, 6), if (selected) self.design.colors.selection else self.design.colors.surface);
            try self.labels.draw(text, if (index == 0) "Codex" else "OpenCode", box.x + 12, box.y + 6, 13, foreground);
            try self.labels.draw(text, if (index == 0) "Existing Codex login  ·  Alt+1" else "Preauthorized account  ·  Alt+2", box.x + 12, box.y + 23, 10, if (selected) foreground else muted);
        }
        try self.labels.draw(text, "Workspace · existing project folder", menu.x + 16, menu.y + 104, 11, muted);
        try self.drawSetupField(renderer, text, 2, foreground, muted);
        try widgets.panel(renderer, self.setup_advanced_bounds, @min(self.design.layout.radius, 4), self.design.colors.surface);
        try icon(renderer, .chevron, self.setup_advanced_bounds.x + 8, self.setup_advanced_bounds.y + 6, muted);
        try self.labels.drawFitted(renderer, text, if (self.setup_advanced_open) "Hide Advanced · Alt+A" else "Advanced · Alt+A", self.setup_advanced_bounds.x + 30, self.setup_advanced_bounds.y + 7, self.setup_advanced_bounds.w - 36, 11, muted);
        if (self.setup_existing_bounds.w != 0) {
            try widgets.panel(renderer, self.setup_existing_bounds, @min(self.design.layout.radius, 4), self.design.colors.surface);
            try self.labels.drawFitted(renderer, text, "Use existing Codex", self.setup_existing_bounds.x + 12, self.setup_existing_bounds.y + 7, self.setup_existing_bounds.w - 24, 11, if (self.existingCodexEnabled()) foreground else muted);
        }
        if (self.setup_advanced_open) {
            const names = [_][]const u8{ "Executable", "Account folder", "Model provider" };
            for ([_]usize{ 0, 1, 3 }, names) |index, name| {
                try self.labels.draw(text, name, menu.x + 16, self.setup_field_bounds[index].y + 7, 11, muted);
                try self.drawSetupField(renderer, text, index, foreground, muted);
            }
        }
        const names_buttons = [_][]const u8{ "Connect & discover", "Sign in with browser", "Use device code", "Refresh models" };
        for (names_buttons, 0..) |name, index| {
            const box = self.setup_button_bounds[index];
            const enabled = self.setupActionEnabled(index);
            try widgets.panel(renderer, box, @min(self.design.layout.radius, 4), if (index == 0 and enabled) self.design.colors.selection else self.design.colors.surface);
            try self.labels.draw(text, name, box.x + 12, box.y + 9, 12, if (enabled) foreground else muted);
        }
        var status_y = geometry.status_y;
        if (self.setup_runtime == .codex and self.login_url_len != 0) {
            self.setup_login_bounds = .{ .x = menu.x + 16, .y = geometry.guidance_y, .w = 180, .h = 28 };
            try widgets.panel(renderer, self.setup_login_bounds, @min(self.design.layout.radius, 4), self.design.colors.selection);
            try self.labels.draw(text, "Open sign-in page", self.setup_login_bounds.x + 12, self.setup_login_bounds.y + 7, 12, foreground);
            if (self.login_code_len != 0) {
                try self.labels.draw(text, "Code:", menu.x + 208, geometry.guidance_y + 8, 11, muted);
                try self.labels.drawFitted(renderer, text, self.login_code[0..self.login_code_len], menu.x + 244, geometry.guidance_y + 6, menu.w - 260, 14, foreground);
            }
        } else {
            const guidance = if (self.setup_runtime == .codex)
                "Connect reuses the selected Codex login. Sign in only if it has expired or is missing."
            else
                "OpenCode sign-in is not supported here. Select a preauthorized account in Advanced.";
            try self.labels.drawFitted(renderer, text, guidance, menu.x + 16, geometry.guidance_y, menu.w - 32, 11, muted);
            try self.labels.drawFitted(renderer, text, "Choose a model beside the composer after connecting. No model is selected for you.", menu.x + 16, geometry.guidance_y + 17, menu.w - 32, 11, muted);
        }
        // Actionable App feedback wins the bounded space below the controls,
        // including Advanced at 720x480. Raw URL text is secondary to errors;
        // the explicit open-page control and device code always stay visible.
        if (self.setup_feedback) |feedback| status_y = try self.drawSetupDiagnostic(renderer, text, feedback, status_y, menu, foreground);
        status_y = try self.drawSetupDiagnostic(renderer, text, self.runtime_info[0..self.runtime_info_len], status_y, menu, foreground);
        if (self.setup_runtime == .codex and self.login_url_len != 0 and status_y + 14 <= menu.y + menu.h - 6)
            try self.labels.drawFitted(renderer, text, self.login_url[0..self.login_url_len], menu.x + 16, status_y, menu.w - 32, 11, muted);
    }

    fn drawSetupDiagnostic(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bytes: []const u8, top: f32, menu: c.SDL_FRect, foreground: Color) !f32 {
        var start: usize = 0;
        var y = top;
        while (start < bytes.len and y + 14 <= menu.y + menu.h - 6) : (y += 16) {
            const rest = bytes[start..];
            const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const utf8 = @import("../text/utf8.zig");
            // Bound shaping/cache keys, then fit a scalar-aligned prefix by
            // binary search. Continue on the next row instead of clipping out
            // the actionable suffix of a wide diagnostic.
            const bounded = utf8.prefix(rest[0..line_end], 100);
            var end = bounded.len;
            if (try self.labels.width(text, bounded, 11) > menu.w - 32) {
                var low: usize = 0;
                var high = bounded.len;
                while (low < high) {
                    const middle = low + (high - low + 1) / 2;
                    if (try self.labels.width(text, utf8.prefix(bounded, middle), 11) <= menu.w - 32) low = middle else high = middle - 1;
                }
                end = utf8.prefix(bounded, low).len;
            }
            if (end == 0 and line_end != 0) break;
            try self.labels.drawFitted(renderer, text, rest[0..end], menu.x + 16, y, menu.w - 32, 11, foreground);
            start += end;
            if (start < bytes.len and bytes[start] == '\n') start += 1;
        }
        return y;
    }

    fn drawSetupField(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, index: usize, foreground: Color, muted: Color) !void {
        const box = self.setup_field_bounds[index];
        try widgets.panel(renderer, box, @min(self.design.layout.radius, 4), if (index == self.setup_field) self.design.colors.selection else self.design.colors.surface);
        const placeholders = [_][]const u8{ "Absolute executable path", "Separate account directory", "Enter an absolute project folder", "Provider ID, e.g. openai" };
        const len = self.setup_lengths[index];
        const bytes = if (len == 0) placeholders[index] else self.setup_fields[index][0..len];
        try self.labels.drawFitted(renderer, text, bytes, box.x + 8, box.y + (box.h - 16) / 2, box.w - 16, 12, if (len == 0) muted else foreground);
    }

    pub fn draw(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, window: *c.SDL_Window, outer_bounds: Layout.Coding) !void {
        var bounds = outer_bounds;
        bounds.transcript = padded(bounds.transcript, self.nodeStyle(5));
        bounds.composer = padded(bounds.composer, self.nodeStyle(4));
        if (self.custom_root) |root| for (root.nodes[0..root.count], 0..) |node, index| {
            if (node.kind == 4) bounds.composer = intersection(bounds.composer, self.customVisibleBounds(index));
            if (node.kind == 5) bounds.transcript = intersection(bounds.transcript, self.customVisibleBounds(index));
        };
        const foreground = self.design.colors.foreground;
        const muted = self.design.colors.muted;
        if (!c.SDL_SetRenderDrawColor(renderer, self.design.colors.background.r, self.design.colors.background.g, self.design.colors.background.b, 255) or !c.SDL_RenderClear(renderer)) return error.CanvasDraw;
        if (self.custom_root == null) try self.drawChrome(renderer, text, bounds, foreground, muted);
        // Preorder backgrounds precede content; a styled parent must never
        // paint over the transcript, editor or a child's label later in frame.
        if (self.custom_root) |root| for (root.nodes[0..root.count], 0..) |node, index| {
            const style = node.style;
            if (style.present & script_api.abi.SPICA_STYLE_BACKGROUND != 0 or node.kind == 3) {
                const box = self.custom_bounds[index];
                const visible = self.customVisibleBounds(index);
                var clip = widgets.Clip.push(renderer, .{ .x = visible.x, .y = visible.y, .w = visible.width, .h = visible.height });
                defer clip.restore(renderer);
                const radius = if (style.present & script_api.abi.SPICA_STYLE_RADIUS != 0) style.radius else @min(self.design.layout.radius, 4);
                try widgets.panel(renderer, .{ .x = box.x, .y = box.y, .w = box.width, .h = box.height }, radius, styleColor(style, false, self.design.colors.selection));
            }
        };
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
                self.custom_font_base = self.custom_tile.size;
                self.custom_tile_sequence = self.custom_render_sequence;
            }
            self.styleTile(&self.custom_tile);
            try self.custom_tile.reflow(text, @max(25, bounds.transcript.width));
            try self.custom_tile.drawStyled(renderer, text, bounds.transcript.x, bounds.transcript.y, self.transcriptDesign());
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
                self.styleTile(tile);
                try tile.reflow(text, tileWidthForRole(tile.role, bounds.transcript.width));
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
                    const tile_x = bounds.transcript.x + @max(0, bounds.transcript.width - tile.width);
                    if (tile.heading) try self.labels.draw(text, tile.role, tile_x + 12, heading_y + 2, 12, muted);
                    try tile.drawStyled(renderer, text, tile_x, tile_y, self.transcriptDesign());
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
            try widgets.panel(renderer, self.follow_bounds, @min(self.design.layout.radius, 5), self.design.colors.selection);
            try self.labels.draw(text, "Back to latest ↓", self.follow_bounds.x + 12, self.follow_bounds.y + 7, 12, foreground);
        }

        const panel = c.SDL_FRect{ .x = bounds.composer.x, .y = bounds.composer.y, .w = bounds.composer.width, .h = bounds.composer.height };
        if (bounds.composer.width > 24 and bounds.composer.height > 40) {
            const composer_style = self.nodeStyle(4);
            const composer_radius = if (composer_style.present & script_api.abi.SPICA_STYLE_RADIUS != 0) composer_style.radius else self.design.layout.radius;
            const composer_foreground = styleColor(composer_style, true, foreground);
            try widgets.panel(renderer, .{ .x = panel.x, .y = panel.y, .w = panel.w, .h = panel.h - (if (self.custom_root == null) @as(f32, 24) else 0) }, composer_radius, self.design.colors.border);
            try widgets.panel(renderer, .{ .x = panel.x + 1, .y = panel.y + 1, .w = panel.w - 2, .h = panel.h - (if (self.custom_root == null) @as(f32, 26) else 2) }, @max(0, composer_radius - 1), styleColor(composer_style, false, self.design.colors.surface));
            const inset = @min(self.design.layout.gutter / 3, 8);
            const editor_bounds = c.SDL_FRect{ .x = panel.x + inset, .y = panel.y + inset, .w = @max(0, panel.w - inset * 2), .h = @max(0, panel.h - inset - (if (self.custom_root != null) @as(f32, 40) else if (self.can_approve) @as(f32, 108) else 70)) };
            self.editor_view.bounds = editor_bounds;
            const font_size = self.composerFontSize();
            if (self.editor_font_size != font_size) {
                self.editor_view.changed = true;
                self.preedit_changed = true;
                self.editor_font_size = font_size;
            }
            try self.editor_view.ensureLayout(text, &self.editor, editor_bounds.w, font_size);
            try self.ensurePreedit(text, @max(1, editor_bounds.w - 24));
            var clip = widgets.Clip.push(renderer, .{ .x = editor_bounds.x + 10, .y = editor_bounds.y + 8, .w = @max(0, editor_bounds.w - 20), .h = @max(0, editor_bounds.h - 12) });
            if (self.editor.len == 0 and self.preedit_len == 0) try self.labels.drawFitted(renderer, text, "Ask for changes, or send a follow-up…", editor_bounds.x + 12, editor_bounds.y + 10, editor_bounds.w - 24, @intFromFloat(font_size), muted);
            if (self.editor_view.layout) |layout| {
                const content_height = c.spica_text_layout_height(layout);
                const available = @max(0, editor_bounds.h - 20);
                self.editor_view.scroll = std.math.clamp(self.editor_view.scroll, 0, @max(0, content_height - available));
                if (self.editor_view.caret(&self.editor)) |caret_rect| {
                    if (self.focused and (self.custom_root != null or !self.search_focused) and self.reveal_caret) {
                        if (caret_rect.y < self.editor_view.scroll) self.editor_view.scroll = caret_rect.y;
                        if (caret_rect.y + caret_rect.h > self.editor_view.scroll + available) self.editor_view.scroll = caret_rect.y + caret_rect.h - available;
                    }
                    self.reveal_caret = false;
                    const x = editor_bounds.x + 12;
                    const y = editor_bounds.y + 10 - self.editor_view.scroll;
                    const selection = self.editor.selection();
                    const begin = @max(selection.start, self.editor_view.start) - self.editor_view.start;
                    const end = @min(selection.end, self.editor_view.end) -| self.editor_view.start;
                    var rects: [128]c.SDL_FRect = undefined;
                    const count = c.spica_text_layout_selection_rects(layout, begin, end, &rects, rects.len);
                    if (!c.SDL_SetRenderDrawColor(renderer, self.design.colors.selection.r, self.design.colors.selection.g, self.design.colors.selection.b, 255)) return error.SelectionDraw;
                    for (rects[0..@min(count, rects.len)]) |rect| {
                        const translated = c.SDL_FRect{ .x = x + rect.x, .y = y + rect.y, .w = rect.w, .h = rect.h };
                        if (!c.SDL_RenderFillRect(renderer, &translated)) return error.SelectionDraw;
                    }
                    if (count > rects.len) self.notice = "Selection display budget exceeded";
                    if (!c.spica_text_layout_draw(text, layout, x, y, widgets.rgba(composer_foreground))) return error.EditorDraw;
                    if (self.focused and (self.custom_root != null or !self.search_focused) and self.window_active) {
                        const caret = c.SDL_FRect{ .x = x + caret_rect.x, .y = y + caret_rect.y, .w = 1.5, .h = caret_rect.h };
                        if (!c.SDL_SetRenderDrawColor(renderer, composer_foreground.r, composer_foreground.g, composer_foreground.b, 255) or !c.SDL_RenderFillRect(renderer, &caret)) return error.CaretDraw;
                        const input_rect = c.SDL_Rect{ .x = @intFromFloat(caret.x), .y = @intFromFloat(caret.y), .w = 1, .h = @intFromFloat(caret.h) };
                        if (!c.SDL_SetTextInputArea(window, &input_rect, 0)) return error.TextInputArea;
                        if (self.preedit_layout) |preedit_layout| {
                            if (!c.spica_text_layout_draw(text, preedit_layout, caret.x, caret.y, widgets.rgba(composer_foreground))) return error.PreeditDraw;
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
                    const gap = @min(self.design.layout.gap, panel.w / 16);
                    const control_width = @max(0, (panel.w - 24 - gap * 3) / 4);
                    control.* = .{ .x = panel.x + 12 + @as(f32, @floatFromInt(index)) * (control_width + gap), .y = panel.y + panel.h - 34, .w = control_width, .h = 26 };
                    const enabled = switch (@as(Intent, @enumFromInt(index))) {
                        .send => self.can_send,
                        .cancel => self.can_cancel,
                        .allow, .deny => self.can_approve,
                    };
                    try widgets.panel(renderer, control.*, @min(self.design.layout.radius, 4), if (enabled) self.design.colors.selection else self.design.colors.raised);
                    try self.labels.drawFitted(renderer, text, names[index], control.x + 8, control.y + 5, control.w - 16, 12, if (enabled) composer_foreground else muted);
                }
            }
        } else {
            self.controls = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
            self.editor_view.bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        }
        if (self.custom_root) |root| {
            for (root.nodes[0..root.count], 0..) |node, index| {
                const box = self.custom_bounds[index];
                const style = node.style;
                const label = root.text[node.text_offset..][0..node.text_len];
                if (node.kind == 2 or node.kind == 3) {
                    const padding = if (style.present & script_api.abi.SPICA_STYLE_PADDING != 0) style.padding else 4;
                    const font_size: c_uint = @intFromFloat(if (style.present & script_api.abi.SPICA_STYLE_FONT_SIZE != 0) style.font_size else @as(f32, 14));
                    const visible = self.customVisibleBounds(index);
                    var clip = widgets.Clip.push(renderer, .{ .x = visible.x, .y = visible.y, .w = visible.width, .h = visible.height });
                    defer clip.restore(renderer);
                    try self.labels.drawFitted(renderer, text, label, box.x + padding, box.y + padding, box.width - padding * 2, font_size, styleColor(style, true, foreground));
                }
            }
            try self.labels.drawFitted(renderer, text, self.status, self.design.layout.gutter, 0, 600, 11, muted);
        }
        if (self.notice) |notice| try self.labels.drawFitted(renderer, text, notice, bounds.transcript.x, bounds.transcript.y, bounds.transcript.width, 12, muted);
        if (self.custom_root == null and self.picker_open) try self.drawPicker(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null and self.effort_open) try self.drawEffort(renderer, text, foreground, muted);
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

test "effort menu respects complete runtime account and workspace identity" {
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
    try std.testing.expect(view.effort_open);
    try std.testing.expectEqualStrings("medium", view.selected.?.effort.slice());
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DOWN;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    event.key.key = c.SDLK_RETURN;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expect(!view.effort_open);
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
                .open_login => 5,
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
        // Both real short labels and bounded long catalog IDs must reserve
        // only their measured width and remain disjoint from primary actions.
        for ([_][]const u8{ "m", "catalog-" ++ "x" ** 200 }) |model_label| {
            view.selected = try View.Identity.from(.{ .runtime_kind = "codex", .model_provider = "fixture", .model_id = model_label, .effort = "low", .account_ref = "isolated", .workspace = .{ .value = "checkout" } });
            view.can_cancel = false;
            view.can_approve = false;
            try view.drawComposerControls(renderer, text, panel, foreground, muted);
            try std.testing.expect(view.picker_bounds.x + view.picker_bounds.w + 10 <= view.effort_bounds.x);
            try std.testing.expect(view.effort_bounds.x + view.effort_bounds.w + 10 <= view.controls[0].x);
            try std.testing.expectEqual(@as(f32, 32), view.controls[0].w);
            try std.testing.expectEqual(@as(f32, 32), view.controls[0].h);
            try std.testing.expectEqual(@as(f32, 28), view.picker_bounds.h);
            if (model_label.len == 1) try std.testing.expect(view.picker_bounds.w < 64);
            try std.testing.expect(view.effort_bounds.w < 80);
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

const setup_fixture_defaults = [2]contract.RuntimeSetup{
    .{ .runtime_kind = .codex, .executable = "/fixture/bin/codex", .account_directory = "/fixture/accounts/codex", .workspace_root = "/fixture/project", .model_provider = "openai" },
    .{ .runtime_kind = .opencode, .executable = "/fixture/bin/opencode", .account_directory = "/fixture/accounts/opencode", .workspace_root = "/fixture/project", .model_provider = "opencode" },
};

test "connection defaults own both provider drafts and never substitute another provider paths" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    var executable = "/fixture/bin/codex".*;
    var defaults = setup_fixture_defaults;
    defaults[0].executable = &executable;
    try std.testing.expect(view.setSetupDefaults(defaults));
    executable[0] = 'x';
    try std.testing.expectEqualStrings("/fixture/bin/codex", view.setup_fields[0][0..view.setup_lengths[0]]);
    try std.testing.expect(!view.setup_advanced_open);
    try std.testing.expectEqual(@as(usize, 2), view.setup_field);
    view.setup_select_all = true;
    try view.setupInsert("/fixture/café/新");
    view.selectSetupProvider(.opencode);
    try std.testing.expectEqualStrings("/fixture/bin/opencode", view.setup_fields[0][0..view.setup_lengths[0]]);
    try std.testing.expectEqualStrings("/fixture/accounts/opencode", view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expectEqualStrings("opencode", view.setup_fields[3][0..view.setup_lengths[3]]);
    view.setup_field = 1;
    view.setup_select_all = true;
    try view.setupInsert("/fixture/preauthorized-opencode");
    view.selectSetupProvider(.codex);
    try std.testing.expectEqualStrings("/fixture/accounts/codex", view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expectEqualStrings("/fixture/café/新", view.setup_fields[2][0..view.setup_lengths[2]]);
    view.selectSetupProvider(.opencode);
    try std.testing.expectEqualStrings("/fixture/preauthorized-opencode", view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expect(view.configureSetup(defaults[0]));
    try std.testing.expectEqual(.codex, view.setup_runtime);
    view.selectSetupProvider(.opencode);
    try std.testing.expectEqualStrings("/fixture/preauthorized-opencode", view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expect(view.selected == null);
}

test "connection configuration empties oversized fields without truncation and owns exact boundary" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    var defaults = setup_fixture_defaults;
    defaults[1].account_directory = "x" ** 513;
    try std.testing.expect(!view.setSetupDefaults(defaults));
    view.selectSetupProvider(.opencode);
    try std.testing.expectEqual(@as(usize, 0), view.setup_lengths[1]);
    try std.testing.expectEqualStrings("/fixture/bin/opencode", view.setup_fields[0][0..view.setup_lengths[0]]);
    var configuration = setup_fixture_defaults[0];
    configuration.executable = "e" ** 513;
    configuration.account_directory = "a" ** 512;
    configuration.workspace_root = "w" ** 513;
    configuration.model_provider = "p" ** 513;
    try std.testing.expect(!view.configureSetup(configuration));
    try std.testing.expectEqualDeep([4]usize{ 0, 512, 0, 0 }, view.setup_lengths);
    try std.testing.expectEqualStrings("a" ** 512, view.setup_fields[1][0..view.setup_lengths[1]]);
    view.selectSetupProvider(.opencode);
    view.selectSetupProvider(.codex);
    try std.testing.expectEqualDeep([4]usize{ 0, 512, 0, 0 }, view.setup_lengths);
    configuration = setup_fixture_defaults[0];
    configuration.account_directory = "\xff";
    try std.testing.expect(!view.configureSetup(configuration));
    try std.testing.expectEqual(@as(usize, 0), view.setup_lengths[1]);
}

test "connection keyboard navigates visible fields and deletes whole Unicode characters" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.setup_open = true;
    try std.testing.expect(view.setSetupDefaults(setup_fixture_defaults));
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_TAB;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(usize, 2), view.setup_field);
    try view.setupInsert("/fixture/café/新");
    event.key.key = c.SDLK_BACKSPACE;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("/fixture/café/", view.setup_fields[2][0..view.setup_lengths[2]]);
    event.key.key = c.SDLK_A;
    event.key.mod = c.SDL_KMOD_ALT;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expect(view.setup_advanced_open);
    event.key.mod = 0;
    event.key.key = c.SDLK_TAB;
    for ([_]usize{ 0, 1, 3, 2 }) |field| {
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expectEqual(field, view.setup_field);
    }
    event.key.mod = c.SDL_KMOD_SHIFT;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(usize, 3), view.setup_field);
    event.key.mod = c.SDL_KMOD_ALT;
    event.key.key = c.SDLK_2;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(.opencode, view.setup_runtime);
    try std.testing.expectEqualStrings("/fixture/accounts/opencode", view.setup_fields[1][0..view.setup_lengths[1]]);
    event.key.key = c.SDLK_1;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("/fixture/café/", view.setup_fields[2][0..view.setup_lengths[2]]);
    event.key.mod = 0;
    event.key.key = c.SDLK_RETURN;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(.configure, view.setup_action.?);
    try std.testing.expect(!view.setup_advanced_open);
}

test "connection availability rejects busy pointer and keyboard actions without consuming drafts or login URL" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try std.testing.expect(view.setSetupDefaults(setup_fixture_defaults));
    view.setup_open = true;
    const geometry = Layout.setup(720, 480, true);
    view.setup_button_bounds = geometry.buttons;
    view.setup_login_bounds = .{ .x = geometry.menu.x + 16, .y = geometry.guidance_y, .w = 180, .h = 28 };
    const url = "https://example.invalid/sign-in";
    @memcpy(view.login_url[0..url.len], url);
    view.login_url_len = url.len;
    var click = std.mem.zeroes(c.SDL_Event);
    click.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    click.button.button = c.SDL_BUTTON_LEFT;
    var key = std.mem.zeroes(c.SDL_Event);
    key.type = c.SDL_EVENT_KEY_DOWN;
    for ([_]contract.RuntimeKind{ .codex, .opencode }) |runtime| {
        view.selectSetupProvider(runtime);
        const draft = view.setup_fields[2];
        for ([_]bool{ false, true }) |busy| for ([_]bool{ false, true }) |login_pending| {
            view.setup_busy = busy;
            view.setup_login_pending = login_pending;
            for (geometry.buttons, 0..) |box, index| {
                const enabled = !busy and !login_pending and (runtime == .codex or index == 0 or index == 3);
                try std.testing.expectEqual(enabled, view.setupActionEnabled(index));
                view.setup_action = null;
                view.setup_advanced_open = true;
                click.button.x = box.x + box.w / 2;
                click.button.y = box.y + box.h / 2;
                try std.testing.expect(try view.handle(click, undefined, undefined));
                try std.testing.expectEqual(enabled, view.setup_action != null);
                try std.testing.expectEqual(!enabled, view.setup_advanced_open);
            }
            view.setup_action = null;
            view.setup_advanced_open = true;
            key.key.key = c.SDLK_RETURN;
            key.key.mod = 0;
            try std.testing.expect(try view.handle(key, undefined, undefined));
            try std.testing.expectEqual(!busy and !login_pending, view.setup_action != null);
            try std.testing.expectEqual(busy or login_pending, view.setup_advanced_open);
            view.setup_action = null;
            click.button.x = view.setup_login_bounds.x + 10;
            click.button.y = view.setup_login_bounds.y + 10;
            try std.testing.expect(try view.handle(click, undefined, undefined));
            try std.testing.expectEqual(runtime == .codex, view.setup_action == .open_login);
            view.setup_action = null;
            key.key.key = c.SDLK_L;
            key.key.mod = c.SDL_KMOD_CTRL;
            try std.testing.expect(try view.handle(key, undefined, undefined));
            try std.testing.expectEqual(runtime == .codex, view.setup_action == .open_login);
            try std.testing.expectEqualSlices(u8, draft[0..view.setup_lengths[2]], view.setup_fields[2][0..view.setup_lengths[2]]);
        };
    }
    try std.testing.expect(!view.setupActionEnabled(4));
    try std.testing.expect(!view.setupActionEnabled(std.math.maxInt(usize)));
    view.setup_runtime = .codex;
    view.login_url_len = 0;
    view.setup_action = null;
    try std.testing.expect(try view.handle(key, undefined, undefined));
    try std.testing.expect(view.setup_action == null);
}

test "connection paints provider choices advanced fields and explicit sign-in page at every supported size" {
    const Pixel = struct {
        fn expect(surface: *c.SDL_Surface, box: c.SDL_FRect, color: Color) !void {
            var actual: Color = undefined;
            var alpha: u8 = 0;
            try std.testing.expect(c.SDL_ReadSurfacePixel(surface, @intFromFloat(box.x + box.w - 8), @intFromFloat(box.y + box.h / 2), &actual.r, &actual.g, &actual.b, &alpha));
            try std.testing.expectEqualDeep(color, actual);
        }
    };
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
        try std.testing.expect(view.setSetupDefaults(setup_fixture_defaults));
        view.setup_open = true;
        const bounds = layout.coding(size[0]);
        const fg = view.design.colors.foreground;
        const muted = view.design.colors.muted;
        var click = std.mem.zeroes(c.SDL_Event);
        click.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        click.button.button = c.SDL_BUTTON_LEFT;
        for ([_]bool{ false, true }) |advanced| {
            view.setup_advanced_open = advanced;
            try view.drawSetup(renderer, text, bounds, fg, muted);
            for (view.setup_field_bounds, 0..) |box, index| {
                try std.testing.expectEqual(advanced or index == 2, box.w > 0);
                if (box.w == 0) continue;
                click.button.x = box.x + box.w / 2;
                click.button.y = box.y + box.h / 2;
                try std.testing.expect(try view.handle(click, undefined, undefined));
                try std.testing.expectEqual(index, view.setup_field);
                try std.testing.expect(view.setup_select_all);
            }
            for ([_]contract.RuntimeKind{ .codex, .opencode }) |runtime| {
                const index: usize = if (runtime == .codex) 0 else 1;
                const choice = view.setup_provider_bounds[index];
                click.button.x = choice.x + choice.w / 2;
                click.button.y = choice.y + choice.h / 2;
                view.setup_action = null;
                try std.testing.expect(try view.handle(click, undefined, undefined));
                try std.testing.expectEqual(runtime, view.setup_runtime);
                try std.testing.expect(view.setup_action == null);
                try view.drawSetup(renderer, text, bounds, fg, muted);
                try std.testing.expect(c.SDL_RenderPresent(renderer));
                try Pixel.expect(surface, view.setup_provider_bounds[index], view.design.colors.selection);
                try Pixel.expect(surface, view.setup_provider_bounds[1 - index], view.design.colors.surface);
                try Pixel.expect(surface, view.setup_button_bounds[0], view.design.colors.selection);
                if (runtime == .codex) {
                    const existing = view.setup_existing_bounds;
                    try std.testing.expect(existing.w > 0 and existing.h > 0);
                    try std.testing.expect(existing.x >= view.setup_advanced_bounds.x + view.setup_advanced_bounds.w + 8);
                    try std.testing.expect(existing.x + existing.w <= view.setup_menu.x + view.setup_menu.w);
                    try Pixel.expect(surface, existing, view.design.colors.surface);
                    click.button.x = existing.x + existing.w / 2;
                    click.button.y = existing.y + existing.h / 2;
                    try std.testing.expect(try view.handle(click, undefined, undefined));
                    try std.testing.expectEqual(.configure, view.setup_action.?);
                    view.setup_action = null;
                } else try std.testing.expectEqual(@as(f32, 0), view.setup_existing_bounds.w);
                if (runtime == .opencode) {
                    for ([_]usize{ 1, 2 }) |button| {
                        const box = view.setup_button_bounds[button];
                        click.button.x = box.x + 8;
                        click.button.y = box.y + 8;
                        try std.testing.expect(try view.handle(click, undefined, undefined));
                        try std.testing.expect(view.setup_action == null);
                    }
                }
                for ([_]bool{ false, true }) |busy| for ([_]bool{ false, true }) |login_pending| {
                    view.setup_busy = busy;
                    view.setup_login_pending = login_pending;
                    try view.drawSetup(renderer, text, bounds, fg, muted);
                    try std.testing.expect(c.SDL_RenderPresent(renderer));
                    try Pixel.expect(surface, view.setup_button_bounds[0], if (view.setupActionEnabled(0)) view.design.colors.selection else view.design.colors.surface);
                };
                view.setup_busy = false;
                view.setup_login_pending = false;
            }
            view.selectSetupProvider(.codex);
        }
        view.setup_advanced_open = false;
        const url = "https://example.invalid/explicit-sign-in";
        @memcpy(view.login_url[0..url.len], url);
        view.login_url_len = url.len;
        const code = "ABCD-1234";
        @memcpy(view.login_code[0..code.len], code);
        view.login_code_len = code.len;
        const failure = "Connection failed: fixture diagnostic remains visible";
        @memcpy(view.runtime_info[0..failure.len], failure);
        view.runtime_info_len = failure.len;
        try view.drawSetup(renderer, text, bounds, fg, muted);
        const login = view.setup_login_bounds;
        try std.testing.expect(login.w > 0 and login.h > 0);
        try std.testing.expect(login.y + login.h < view.setup_menu.y + view.setup_menu.h);
        click.button.x = login.x + login.w / 2;
        click.button.y = login.y + login.h / 2;
        view.setup_action = null;
        try std.testing.expect(try view.handle(click, undefined, undefined));
        try std.testing.expectEqual(.open_login, view.setup_action.?);
        try std.testing.expectEqualStrings(failure, view.runtime_info[0..view.runtime_info_len]);
        try std.testing.expect(c.SDL_RenderPresent(renderer));
        try Pixel.expect(surface, login, view.design.colors.selection);
        view.setup_action = null;
        view.selectSetupProvider(.opencode);
        try view.drawSetup(renderer, text, bounds, fg, muted);
        try std.testing.expectEqualDeep(View.zero_rect, view.setup_login_bounds);
        // A stale Codex URL never opens a page while OpenCode is selected.
        try std.testing.expect(try view.handle(click, undefined, undefined));
        try std.testing.expect(view.setup_action == null);
        click.button.x = view.setup_advanced_bounds.x + 10;
        click.button.y = view.setup_advanced_bounds.y + 10;
        try std.testing.expect(try view.handle(click, undefined, undefined));
        try std.testing.expect(view.setup_advanced_open);
        try view.drawSetup(renderer, text, bounds, fg, muted);
        try std.testing.expect(view.setup_field_bounds[1].w > 0);
        click.button.x = view.setup_advanced_bounds.x + 10;
        click.button.y = view.setup_advanced_bounds.y + 10;
        try std.testing.expect(try view.handle(click, undefined, undefined));
        try std.testing.expect(!view.setup_advanced_open);
        try std.testing.expectEqual(@as(usize, 2), view.setup_field);
        // Setup chrome does not cause incidental operating-system font loading.
        var stats: c.SpicaTextStats = undefined;
        try std.testing.expect(c.spica_text_get_stats(text, &stats));
        try std.testing.expectEqual(@as(c_uint, 1), stats.face_count);
    }
}

test "minimum Advanced paints exact actionable feedback below pending sign-in without clipping its second line" {
    const surface = c.SDL_CreateSurface(720, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var layout = try Layout.init(std.testing.allocator, 720, 480);
    defer layout.deinit();
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    const bounds = layout.coding(720);
    const geometry = Layout.setup(720, 480, true);
    view.setup_advanced_open = true;
    view.setup_busy = true;
    view.setup_login_pending = true;
    const lines = [_][]const u8{ "Codex sign-in failed: invalid account folder.", "Open Advanced and choose a writable account folder." };
    const runtime_lines = [_][]const u8{ "codex: unavailable", "Choose a writable account folder." };
    const status = runtime_lines[0] ++ "\n" ++ runtime_lines[1];
    const url = "https://example.invalid/sign-in";
    @memcpy(view.login_url[0..url.len], url);
    const code = "TEST-1234";
    @memcpy(view.login_code[0..code.len], code);
    view.login_code_len = code.len;
    const fg = view.design.colors.foreground;
    const muted = view.design.colors.muted;
    for ([_]bool{ false, true }) |feedback| {
        view.setup_feedback = if (feedback) lines[0] ++ "\n" ++ lines[1] else null;
        @memcpy(view.runtime_info[0..status.len], status);
        view.runtime_info_len = status.len;
        view.login_url_len = url.len;
        try view.drawSetup(renderer, text, bounds, fg, muted);
        try std.testing.expect(c.SDL_RenderPresent(renderer));
        try std.testing.expect(view.setup_login_bounds.y + view.setup_login_bounds.h <= geometry.status_y);
        try std.testing.expect(geometry.status_y + 32 <= geometry.menu.y + geometry.menu.h - 6);
        for (geometry.fields) |box| try std.testing.expect(box.y + box.h <= geometry.buttons[0].y);
        const region = c.SDL_Rect{ .x = @intFromFloat(geometry.menu.x + 16), .y = @intFromFloat(geometry.status_y), .w = @intFromFloat(geometry.menu.w - 32), .h = 32 };
        const actual = c.SDL_RenderReadPixels(renderer, &region) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(actual);
        // Paint an independent expected pair of complete strings over the empty
        // modal. Comparing every diagnostic pixel catches missing/clipped glyphs,
        // stale runtime status, a URL overwriting feedback, and wrong row placement.
        view.setup_feedback = null;
        view.runtime_info_len = 0;
        view.login_url_len = 0;
        try view.drawSetup(renderer, text, bounds, fg, muted);
        try widgets.panel(renderer, .{ .x = @floatFromInt(region.x), .y = @floatFromInt(region.y), .w = @floatFromInt(region.w), .h = @floatFromInt(region.h) }, 0, view.design.colors.raised);
        for (if (feedback) lines else runtime_lines, 0..) |line, row| try view.labels.draw(text, line, geometry.menu.x + 16, geometry.status_y + @as(f32, @floatFromInt(row)) * 16, 11, fg);
        try std.testing.expect(c.SDL_RenderPresent(renderer));
        const expected = c.SDL_RenderReadPixels(renderer, &region) orelse return error.ReadPixels;
        defer c.SDL_DestroySurface(expected);
        var ink: [2]usize = @splat(0);
        var y: c_int = 0;
        while (y < region.h) : (y += 1) {
            var x: c_int = 0;
            while (x < region.w) : (x += 1) {
                var a: [4]u8 = undefined;
                var b: [4]u8 = undefined;
                try std.testing.expect(c.SDL_ReadSurfacePixel(actual, x, y, &a[0], &a[1], &a[2], &a[3]));
                try std.testing.expect(c.SDL_ReadSurfacePixel(expected, x, y, &b[0], &b[1], &b[2], &b[3]));
                try std.testing.expectEqual(a, b);
                if (a[0] != view.design.colors.raised.r or a[1] != view.design.colors.raised.g or a[2] != view.design.colors.raised.b) ink[@intCast(@divTrunc(y, 16))] += 1;
            }
        }
        try std.testing.expect(ink[0] > 20 and ink[1] > 20);
    }
}

test "setup replacement preserves UTF8 and rejects oversized replacement atomically" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.setup_field = 0;
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

test "custom styles share visible paint and action bounds and invalidate font sizes" {
    const surface = c.SDL_CreateSurface(640, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var layout = try Layout.init(std.testing.allocator, 640, 480);
    defer layout.deinit();
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    var root = std.mem.zeroes(script_api.Root);
    root.count = 3;
    root.text_len = 4;
    @memcpy(root.text[0..4], "Send");
    root.nodes[0] = .{ .kind = 0, .parent = std.math.maxInt(u16), .id = try script_api.id("root"), .style = .{ .present = script_api.abi.SPICA_STYLE_WIDTH | script_api.abi.SPICA_STYLE_HEIGHT | script_api.abi.SPICA_STYLE_PADDING | script_api.abi.SPICA_STYLE_GAP | script_api.abi.SPICA_STYLE_BACKGROUND, .width = 320, .height = 360, .padding = 8, .gap = 8, .background = .{ 20, 30, 60 } } };
    root.nodes[1] = .{ .kind = 3, .parent = 0, .id = try script_api.id("send-button"), .action = try script_api.id("send"), .text_len = 4, .style = .{ .present = script_api.abi.SPICA_STYLE_WIDTH | script_api.abi.SPICA_STYLE_HEIGHT | script_api.abi.SPICA_STYLE_BACKGROUND | script_api.abi.SPICA_STYLE_FOREGROUND | script_api.abi.SPICA_STYLE_FONT_SIZE | script_api.abi.SPICA_STYLE_RADIUS, .width = 500, .height = 48, .background = .{ 130, 30, 40 }, .foreground = .{ 250, 220, 170 }, .font_size = 24, .radius = 0 } };
    root.nodes[2] = .{ .kind = 4, .parent = 0, .id = try script_api.id("composer"), .style = .{ .present = script_api.abi.SPICA_STYLE_WIDTH | script_api.abi.SPICA_STYLE_HEIGHT | script_api.abi.SPICA_STYLE_PADDING | script_api.abi.SPICA_STYLE_FONT_SIZE | script_api.abi.SPICA_STYLE_BACKGROUND, .width = 280, .height = 180, .padding = 8, .font_size = 28, .background = .{ 20, 60, 30 } } };
    view.custom_root = &root;
    view.focused = false;
    view.window_active = false;
    view.preedit_len = 2;
    @memcpy(view.preedit[0..2], "hi");
    const boxes = layout.script(&root, &view.custom_bounds);
    try view.draw(renderer, text, undefined, boxes);
    try std.testing.expectEqual(@as(f32, 28), view.editor_font_size);
    try std.testing.expectEqual(@as(f32, 28), view.preedit_font_size);
    const large_preedit = c.spica_text_layout_height(view.preedit_layout.?);
    const editor_width = view.editor_view.width;
    const visible = view.customVisibleBounds(1);
    try std.testing.expect(view.custom_bounds[1].width > visible.width);
    try std.testing.expectEqual(@as(f32, 320), visible.x + visible.width);
    try std.testing.expect(!widgets.contains(.{ .x = visible.x, .y = visible.y, .w = visible.width, .h = visible.height }, 400, 40));
    // Direct surface reads must follow submission of SDL's queued draw batch.
    try std.testing.expect(c.SDL_RenderPresent(renderer));
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 0;
    try std.testing.expect(c.SDL_ReadSurfacePixel(surface, 300, 40, &r, &g, &b, &a));
    try std.testing.expectEqualDeep([3]u8{ 130, 30, 40 }, [3]u8{ r, g, b });
    try std.testing.expect(c.SDL_ReadSurfacePixel(surface, 400, 40, &r, &g, &b, &a));
    try std.testing.expectEqualDeep(view.design.colors.background, Color{ .r = r, .g = g, .b = b });
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = visible.x + 6;
    event.button.y = visible.y + 6;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(?usize, 1), view.custom_action);
    root.nodes[2].style.font_size = 16;
    try view.draw(renderer, text, undefined, boxes);
    try std.testing.expectEqual(editor_width, view.editor_view.width);
    try std.testing.expectEqual(@as(f32, 16), view.editor_font_size);
    try std.testing.expect(c.spica_text_layout_height(view.preedit_layout.?) < large_preedit);
    root.nodes[2].style.font_size = 28;
    try view.ensurePreedit(text, 180);
    const before_default = c.spica_text_layout_height(view.preedit_layout.?);
    view.custom_root = null;
    try view.ensurePreedit(text, 180);
    try std.testing.expectEqual(@as(f32, 16), view.preedit_font_size);
    try std.testing.expect(c.spica_text_layout_height(view.preedit_layout.?) < before_default);
    var stats: c.SpicaTextStats = undefined;
    try std.testing.expect(c.spica_text_get_stats(text, &stats));
    try std.testing.expectEqual(@as(c_uint, 1), stats.face_count);
}

test "user bubbles align after chronological admission and retain exact text hits" {
    const surface = c.SDL_CreateSurface(1100, 740, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var layout = try Layout.init(std.testing.allocator, 1100, 740);
    defer layout.deinit();
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.focused = false;
    view.window_active = false;
    const boxes = layout.coding(1100);
    for ([_]u8{ 2, 1, 3 }) |ordinal| {
        var source: presentation.Tile = .{ .key = .{ .source = @splat(ordinal), .revision = 1, .generation = 1 }, .block = std.mem.zeroes(presentation.Block), .state = .rich, .len = 18 };
        source.block.kind = .paragraph;
        @memcpy(source.text[0..18], "Message in a chat.");
        const id = [_]u8{ 'm', '0' + ordinal };
        try view.admitTile(text, &source, boxes.transcript.width, .{ .message = try transcript.Id.init(&id), .block = try transcript.Id.init(&id), .ordinal = 0, .message_ordinal = ordinal, .role = if (ordinal == 2) "assistant" else "user", .backward = ordinal == 1 });
    }
    try view.draw(renderer, text, undefined, boxes);
    try std.testing.expectEqual(@as(usize, 3), view.rich_count);
    const first = &view.rich_tiles[0];
    const second = &view.rich_tiles[1];
    const third = &view.rich_tiles[2];
    try std.testing.expectEqual(@as(u64, 1), first.message_ordinal);
    try std.testing.expectEqual(@as(u64, 2), second.message_ordinal);
    try std.testing.expectEqual(@as(u64, 3), third.message_ordinal);
    try std.testing.expect(first.bounds.y < second.bounds.y and second.bounds.y < third.bounds.y);
    try std.testing.expect(first.bounds.x > second.bounds.x);
    try std.testing.expectApproxEqAbs(second.bounds.x + second.bounds.w, first.bounds.x + first.bounds.w, 0.1);
    try std.testing.expectApproxEqAbs(second.bounds.w * 0.85, first.bounds.w, 0.1);
    try std.testing.expect(first.hit(first.bounds.x + 12, first.bounds.y + 12, false));
    try std.testing.expect(first.hit(first.bounds.x + first.bounds.w - 14, first.bounds.y + 12, true));
    try std.testing.expectEqualStrings("Message in a chat.", first.selectedBytes());
    const retained_layout = first.layout;
    view.design.colors.surface = .{ .r = 50, .g = 30, .b = 20 };
    try view.draw(renderer, text, undefined, boxes);
    try std.testing.expectEqual(retained_layout, first.layout);
    try std.testing.expectEqualStrings("Message in a chat.", first.selectedBytes());
}

test "bounded sidebar search owns Unicode and preserves source indices and drafts" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("draft must stay intact", .typing);
    view.thread_count = 3;
    const titles = [_][]const u8{ "Repair parser", "Review UTF8 café", "Build shader" };
    for (view.threads[0..3], 0..) |*entry, index| {
        entry.id = try transcript.Id.init(titles[index]);
        @memcpy(entry.label[0..titles[index].len], titles[index]);
        entry.len = titles[index].len;
        entry.project_id = try transcript.Id.init(if (index == 1) "project-b" else "project-a");
        entry.project_name = try transcript.Id.init(if (index == 1) "Engine" else "Spica");
        entry.workspace_name = try transcript.Id.init("checkout");
        entry.branch = try transcript.Id.init(if (index == 2) "feature/shader" else "main");
    }
    view.search_focused = true;
    view.navigation_enabled = true;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "CAFé";
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(usize, 1), view.visibleThreadCount());
    try std.testing.expectEqual(@as(?usize, 1), view.searchResult(0));
    try std.testing.expect(view.threadRowBounds(0).w == 0);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RETURN;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(usize, 1), view.navigation.?.thread);
    view.search_focused = true;
    try view.searchInsert("CAFé");
    event.key.key = c.SDLK_BACKSPACE;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqualStrings("CAF", view.search_query[0..view.search_len]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(view.search_query[0..view.search_len]));
    view.search_select_all = true;
    try view.searchInsert("shader");
    try std.testing.expectEqual(@as(?usize, 2), view.searchResult(0));
    view.scope_project = try transcript.Id.init("project-b");
    try std.testing.expectEqual(@as(usize, 0), view.visibleThreadCount());
    view.search_len = 0;
    try std.testing.expectEqual(@as(?usize, 1), view.searchResult(0));
    view.scope_project = .{};
    try std.testing.expectEqual(@as(usize, 3), view.visibleThreadCount());
    view.search_len = 6;
    var saved: [6]u8 = undefined;
    @memcpy(&saved, view.search_query[0..6]);
    view.search_select_all = true;
    try std.testing.expectError(error.TextTooLarge, view.searchInsert("x" ** 161));
    try std.testing.expectEqualSlices(u8, &saved, view.search_query[0..6]);
    try std.testing.expectEqual(@as(usize, 6), view.search_len);
    try std.testing.expect(view.search_select_all);
    try std.testing.expectError(error.InvalidUtf8, view.searchInsert("\xff"));
    const draft = try view.editor.materialize(view.scratch);
    try std.testing.expectEqualStrings("draft must stay intact", draft);
}

test "flat rendered sidebar cards clip hits filter real project IDs and use bundled chrome" {
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
        view.navigation_enabled = true;
        view.thread_count = 12;
        view.project_count = 2;
        view.projects[0].id = try transcript.Id.init("actual/project-a");
        view.projects[1].id = try transcript.Id.init("actual/project-b");
        for (view.projects[0..2]) |*entry| {
            @memcpy(entry.label[0..5], "Spica");
            entry.len = 5;
        }
        for (view.threads[0..view.thread_count], 0..) |*entry, index| {
            var id_buffer: [32]u8 = undefined;
            entry.id = try transcript.Id.init(try std.fmt.bufPrint(&id_buffer, "real-thread-{d}", .{index}));
            const title = try std.fmt.bufPrint(&entry.label, "Repair actual parser {d}", .{index});
            entry.len = title.len;
            entry.project_id = view.projects[index % 2].id;
            entry.project_name = try transcript.Id.init("Spica");
            entry.workspace_name = try transcript.Id.init("native-workspace");
            entry.branch = try transcript.Id.init(if (index == 1) "feature/needle" else "main");
        }
        view.active_thread = view.threads[0].id;
        view.active_project = view.projects[0].id;
        const bounds = layout.coding(size[0]);
        const fg = view.design.colors.foreground;
        const muted = view.design.colors.muted;
        try view.drawChrome(renderer, text, bounds, fg, muted);
        const first = view.threadRowBounds(0);
        const second = view.threadRowBounds(1);
        try std.testing.expectEqual(@as(f32, 78), first.h);
        try std.testing.expectEqual(@as(f32, 83), second.y - first.y);
        try std.testing.expectEqual(view.sidebar_rows.x, first.x);
        try std.testing.expectEqual(view.sidebar_rows.w, first.w);
        try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(11));
        try std.testing.expect(view.search_bounds.x + view.search_bounds.w <= view.scope_bounds.x);
        try std.testing.expect(view.scope_bounds.x + 28 <= view.new_project_bounds.x);
        try std.testing.expect(view.new_project_bounds.x + 28 <= view.new_thread_bounds.x);
        try std.testing.expectEqual(view.scope_bounds.y, view.new_thread_bounds.y);
        try std.testing.expectEqual(@as(f32, 28), view.new_thread_bounds.w);
        try std.testing.expectEqual(@as(f32, 32), view.search_bounds.h);
        try std.testing.expect(view.setup_bounds.y >= view.sidebar_rows.y + view.sidebar_rows.h);
        try std.testing.expect(c.SDL_RenderPresent(renderer));
        var r: u8 = 0;
        var g: u8 = 0;
        var b: u8 = 0;
        var alpha: u8 = 0;
        // Flat selected surface fills the card, rather than an indented title.
        try std.testing.expect(c.SDL_ReadSurfacePixel(surface, @intFromFloat(first.x + 3), @intFromFloat(first.y + 40), &r, &g, &b, &alpha));
        try std.testing.expectEqual(@as(u8, 0x1a), r);
        try std.testing.expectEqual(@as(u8, 0x1b), g);
        try std.testing.expectEqual(@as(u8, 0x1b), b);
        view.sidebar_scroll = 40;
        try view.drawChrome(renderer, text, bounds, fg, muted);
        const clipped = view.threadRowBounds(0);
        try std.testing.expectEqual(view.sidebar_rows.y, clipped.y);
        try std.testing.expect(clipped.h > 0 and clipped.h < 78);
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
        event.button.button = c.SDL_BUTTON_LEFT;
        event.button.x = clipped.x + 3;
        event.button.y = clipped.y - 1;
        view.navigation = null;
        // Above cards lies the row/header gutter, never a clipped thread hit.
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expect(view.navigation == null);
        event.button.y = clipped.y + 2;
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expectEqual(@as(usize, 0), view.navigation.?.thread);
        try view.searchInsert("NEEDLE");
        try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(0));
        try view.drawChrome(renderer, text, bounds, fg, muted);
        const filtered = view.threadRowBounds(1);
        try std.testing.expect(filtered.h == 78);
        event.button.x = filtered.x + 4;
        event.button.y = filtered.y + 40;
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expectEqual(@as(usize, 1), view.navigation.?.thread);
        event.button.x = view.scope_bounds.x + 4;
        event.button.y = view.scope_bounds.y + 4;
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expect(view.scope_open);
        try view.drawChrome(renderer, text, bounds, fg, muted);
        try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(1));
        event.button.x = view.project_bounds[0].x + 4;
        event.button.y = view.project_bounds[0].y + 4;
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expect(view.scope_project.eql("actual/project-a"));
        try std.testing.expectEqual(@as(usize, 0), view.visibleThreadCount());
        view.search_len = 0;
        try view.drawChrome(renderer, text, bounds, fg, muted);
        try std.testing.expectEqual(@as(usize, 6), view.visibleThreadCount());
        try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(1));
        const a = view.threadRowBounds(0);
        const c_row = view.threadRowBounds(2);
        try std.testing.expectEqual(@as(f32, 83), c_row.y - a.y);
        var stats: c.SpicaTextStats = undefined;
        try std.testing.expect(c.spica_text_get_stats(text, &stats));
        try std.testing.expectEqual(@as(c_uint, 1), stats.face_count);
    }
}

test "primary circle and glyph preserve disabled opacity enabled accent and destructive colors on the real surface" {
    const Pixel = struct {
        fn expect(surface: *c.SDL_Surface, x: f32, y: f32, expected: Color) !void {
            var actual: Color = undefined;
            var alpha: u8 = 0;
            try std.testing.expect(c.SDL_ReadSurfacePixel(surface, @intFromFloat(x), @intFromFloat(y), &actual.r, &actual.g, &actual.b, &alpha));
            try std.testing.expectEqual(expected, actual);
            try std.testing.expectEqual(@as(u8, 255), alpha);
        }
    };
    for ([_][2]f32{ .{ 720, 480 }, .{ 900, 650 }, .{ 1100, 740 }, .{ 1280, 800 } }) |size| {
        const surface = c.SDL_CreateSurface(@intFromFloat(size[0]), @intFromFloat(size[1]), c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
        defer c.SDL_DestroySurface(surface);
        const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
        defer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
        defer c.spica_text_destroy(text);
        var layout = try Layout.init(std.testing.allocator, size[0], size[1]);
        defer layout.deinit();
        const bounds = layout.coding(size[0]);
        for (0..2) |theme| {
            var view = try View.init(std.testing.allocator);
            defer view.deinit();
            view.focused = false;
            view.window_active = false;
            if (theme == 1) {
                // User configuration may change every contributing role. In
                // particular the real composer surface differs from raised.
                view.design.colors.surface = .{ .r = 40, .g = 60, .b = 80 };
                view.design.colors.raised = .{ .r = 100, .g = 110, .b = 120 };
                view.design.colors.accent = .{ .r = 200, .g = 150, .b = 100 };
                view.design.colors.accent_text = .{ .r = 240, .g = 230, .b = 220 };
                view.design.colors.danger = .{ .r = 180, .g = 30, .b = 90 };
            }
            for (0..4) |state| {
                // Empty draft and unavailable provider both retain the visible
                // disabled circle; only admitted Send/Stop use opaque paints.
                if (state == 1) try view.insert("real draft", .typing);
                view.can_send = state < 2;
                view.can_cancel = state == 2;
                try view.draw(renderer, text, undefined, bounds);
                try std.testing.expect(c.SDL_RenderPresent(renderer));
                const primary = view.controls[if (state == 2) @as(usize, 1) else 0];
                try std.testing.expectEqual(@as(f32, 32), primary.w);
                try std.testing.expectEqual(@as(f32, 32), primary.h);
                try std.testing.expect(view.picker_bounds.x + view.picker_bounds.w + 10 <= view.effort_bounds.x);
                try std.testing.expect(view.effort_bounds.x + view.effort_bounds.w + 10 <= primary.x);
                const disabled = state == 0 or state == 3;
                // Independent expected sRGB samples from 64% button opacity,
                // rounded once to bytes. Do not derive expectations with the
                // production compositing helper.
                const fill = if (disabled)
                    (if (theme == 0) Color{ .r = 39, .g = 75, .b = 160 } else Color{ .r = 142, .g = 118, .b = 93 })
                else if (state == 2)
                    view.design.colors.danger
                else
                    view.design.colors.accent;
                const glyph = if (disabled)
                    (if (theme == 0) Color{ .r = 169, .g = 169, .b = 169 } else Color{ .r = 168, .g = 169, .b = 170 })
                else
                    view.design.colors.accent_text;
                try Pixel.expect(surface, primary.x + 16, primary.y + 26, fill);
                try Pixel.expect(surface, primary.x + 16, primary.y + 18, glyph);
                if (state == 2) try Pixel.expect(surface, primary.x + 10, primary.y + 18, fill);
                // Rounded corner stays on the actual composer surface, proving
                // this remains a circle rather than an opaque 32px rectangle.
                try Pixel.expect(surface, primary.x, primary.y, view.design.colors.surface);
                if (disabled) try std.testing.expect(!std.meta.eql(fill, view.design.colors.surface));
            }
        }
    }
}

test "existing Codex is an explicit owned choice preserving saved custom paths and workspace" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try std.testing.expect(view.setSetupDefaults(setup_fixture_defaults));
    var saved = setup_fixture_defaults[0];
    saved.account_directory = "/separate/saved-account";
    saved.workspace_root = "/chosen/workspace";
    try std.testing.expect(view.configureSetup(saved));
    try std.testing.expectEqualStrings(saved.account_directory, view.setup_fields[1][0..view.setup_lengths[1]]);
    view.setup_busy = true;
    view.useExistingCodex();
    try std.testing.expect(view.setup_action == null);
    try std.testing.expectEqualStrings(saved.account_directory, view.setup_fields[1][0..view.setup_lengths[1]]);
    view.setup_busy = false;
    view.useExistingCodex();
    try std.testing.expectEqual(.configure, view.setup_action.?);
    try std.testing.expectEqualStrings(setup_fixture_defaults[0].account_directory, view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expectEqualStrings(saved.workspace_root, view.setup_fields[2][0..view.setup_lengths[2]]);
    view.setup_action = null;
    view.setup_runtime = .opencode;
    view.useExistingCodex();
    try std.testing.expect(view.setup_action == null);
}
