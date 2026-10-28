const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Composer = @import("../text/composer.zig").Composer;
const LineEdit = @import("../text/line_edit.zig").LineEdit;
const LineView = @import("line_view.zig").LineView;
const SidebarMenu = @import("sidebar_menu.zig");
const SidebarTime = @import("../platform/sidebar_time.zig");
const SidebarSnooze = @import("sidebar_snooze.zig");
const SidebarLifecycle = @import("sidebar_lifecycle.zig");
const EditorView = @import("editor_view.zig").EditorView;
const LabelCache = @import("label_cache.zig").LabelCache;
const widgets = @import("widgets.zig");
const hit_targets = @import("hit_targets.zig");
const clipboard = @import("clipboard.zig");
const Layout = @import("clay.zig").Layout;
const Color = @import("color.zig").Color;
const transcript = @import("transcript.zig");
const presentation = @import("../content/presentation.zig");
const contract = @import("../contract.zig");
const attachment_text = @import("../text/attachments.zig");
const script_api = @import("../script.zig");
const fuzzy = @cImport({
    @cInclude("fuzzy.h");
});

// Visual reference: T3 Code eb1510d (MIT), apps/marketing/src/assets/app-desktop.webp;
// apps/web/src/components/sidebar/{SidebarThreadHeader,SidebarThreadRow}.tsx and
// chat/{ChatHeader,ComposerSurface,ComposerControlsBar,ComposerPrimaryActions}.tsx.
// Native geometry/strokes are implemented here against Spica's bounded views.

pub const Intent = enum { send, cancel, allow, deny };
pub const TitleAction = enum { save, cancel };

/// Bounded Send evidence owned by the native consumer. It is intentionally
/// separate from provider contracts: receipts and run rows remain the
/// authority, while this record lets the UI distinguish local disablement,
/// preflight refusal, command rejection, accepted provider failure and a
/// terminal run without retaining prompt contents.
pub const SendStage = enum { idle, disabled, preflight_rejected, submitted, admission_failed, outcome_unknown, accepted, rejected, provider_failed, terminal };
pub const SendReceipt = enum { none, accepted, rejected };
pub const SendDiagnostic = struct {
    stage: SendStage = .idle,
    prompt_bytes: usize = 0,
    frame_bytes: usize = 0,
    ticket: u64 = 0,
    receipt: SendReceipt = .none,
    command_id: [32]u8 = @splat(0),
    command_id_len: usize = 0,
    effect_id: [32]u8 = @splat(0),
    effect_id_len: usize = 0,
    rejection: [96]u8 = @splat(0),
    rejection_len: usize = 0,
    run_id: [32]u8 = @splat(0),
    run_id_len: usize = 0,
    session_id: [32]u8 = @splat(0),
    session_id_len: usize = 0,
    run_state: [24]u8 = @splat(0),
    run_state_len: usize = 0,
    provider: [1024]u8 = @splat(0),
    provider_len: usize = 0,

    pub fn bounded(destination: []u8, length: *usize, value: []const u8) void {
        const clipped = @import("../text/utf8.zig").prefix(value, destination.len);
        @memcpy(destination[0..clipped.len], clipped);
        length.* = clipped.len;
    }

    pub fn begin(self: *SendDiagnostic, command_id: []const u8, prompt_bytes: usize, frame_bytes: usize) void {
        self.* = .{ .stage = .submitted, .prompt_bytes = prompt_bytes, .frame_bytes = frame_bytes, .receipt = .none };
        bounded(&self.command_id, &self.command_id_len, command_id);
    }

    pub fn setReceipt(self: *SendDiagnostic, outcome: SendReceipt, reason: []const u8) void {
        self.receipt = outcome;
        self.stage = if (outcome == .rejected) .rejected else .accepted;
        bounded(&self.rejection, &self.rejection_len, reason);
    }

    pub fn setRun(self: *SendDiagnostic, run: []const u8, session: []const u8) void {
        bounded(&self.run_id, &self.run_id_len, run);
        bounded(&self.session_id, &self.session_id_len, session);
    }

    pub fn setEffect(self: *SendDiagnostic, effect: []const u8) void {
        bounded(&self.effect_id, &self.effect_id_len, effect);
    }

    pub fn setRunState(self: *SendDiagnostic, state: []const u8) void {
        bounded(&self.run_state, &self.run_state_len, state);
    }

    pub fn setProviderDiagnostic(self: *SendDiagnostic, diagnostic: []const u8, terminal: bool) void {
        if (self.provider_len == 0) bounded(&self.provider, &self.provider_len, diagnostic);
        self.stage = if (terminal) .terminal else .provider_failed;
    }
};

/// Bounded, read-only changed-file metadata copied from the inspection worker.
pub const WorkspaceFileData = struct {
    path: [256]u8 = undefined,
    path_len: usize = 0,
    original: [256]u8 = undefined,
    original_len: usize = 0,
    index: u8 = ' ',
    worktree: u8 = ' ',
};

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
    send_diagnostic: SendDiagnostic = .{},
    revision: u64 = 0,
    status: []const u8 = "Conversation not connected",
    connected: bool = false,
    tasks: [16]TaskLine = @splat(.{}),
    task_count: usize = 0,
    tasks_enabled: bool = false,
    task_cancel: ?TaskCancel = null,
    attachments: attachment_text.Store,
    workflow_open: bool = false,
    workflow_path_focus: bool = false,
    workflow_path: [1024]u8 = undefined,
    workflow_path_len: usize = 0,
    workflow_path_select_all: bool = false,
    workflow_action: ?WorkflowAction = null,
    workflow_busy: bool = false,
    workflow_run: transcript.Id = .{},
    workflow_active: bool = false,
    workflow_uncertain: bool = false,
    workflow_feedback: [512]u8 = undefined,
    workflow_feedback_len: usize = 0,
    workflow_error: []const u8 = "",
    workflow_bounds: c.SDL_FRect = zero_rect,
    workflow_button: c.SDL_FRect = zero_rect,
    workflow_targets: hit_targets.SemanticTargets(64, 96, 16) = .{},
    workflow_keyboard: usize = 0,
    workflow_page: usize = 0,
    question_pending: bool = false,
    question_id: transcript.Id = .{},
    question_revision: u64 = 0,
    question_prompt: [1024]u8 = undefined,
    question_prompt_len: usize = 0,
    question_allow_multiple: bool = false,
    question_allow_freeform: bool = false,
    question_selected: u16 = 0,
    question_answer: [4096]u8 = undefined,
    question_answer_len: usize = 0,
    question_choices: [16]struct { id: transcript.Id = .{}, label: [160]u8 = undefined, len: usize = 0 } = @splat(.{}),
    question_choice_count: usize = 0,
    followups: [8]Followup = @splat(.{}),
    followup_count: usize = 0,
    followup_editing: ?transcript.Id = null,
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
    sidebar_collapsed: bool = false,
    sidebar_width_override: ?f32 = null,
    sidebar_window_width: f32 = 1280,
    sidebar_resizing: bool = false,
    sidebar_toggle_bounds: c.SDL_FRect = zero_rect,
    sidebar_resize_bounds: c.SDL_FRect = zero_rect,
    sidebar_now_ms: i64 = 0,
    sidebar_working_shelf: bool = false,
    sidebar_shelf_expanded: [3]bool = @splat(false),
    sidebar_shelf_bounds: [3]c.SDL_FRect = @splat(zero_rect),
    sidebar_menu_thread: transcript.Id = .{},
    sidebar_menu_bounds: c.SDL_FRect = zero_rect,
    sidebar_menu_x: f32 = 0,
    sidebar_menu_y: f32 = 0,
    sidebar_menu_hover: usize = 0,
    sidebar_menu_rows: [16]c.SDL_FRect = @splat(zero_rect),
    sidebar_rename_thread: transcript.Id = .{},
    sidebar_rename_followup: ?RenameFollowup = null,
    sidebar_rename_buffer: [160]u8 = undefined,
    sidebar_rename_len: usize = 0,
    sidebar_rename_select_all: bool = false,
    sidebar_rename_bounds: c.SDL_FRect = zero_rect,
    sidebar_menu_count: usize = 0,
    sidebar_menu_panel: SidebarMenu.Panel = .{},
    sidebar_menu_mode: enum { main, copy, snooze } = .main,
    sidebar_snooze_deadlines: [5]i64 = @splat(0),
    sidebar_snooze_when: [5]SidebarTime.Text = @splat(.{}),
    sidebar_snooze_count: usize = 0,
    custom_snooze: ?SidebarSnooze.State = null,
    custom_snooze_thread: transcript.Id = .{},
    custom_snooze_focus: enum { date_mode, duration_mode, date, time, calendar, amount, unit, cancel, submit } = .date,
    custom_snooze_bounds: [9]c.SDL_FRect = @splat(zero_rect),
    custom_snooze_days: [42]c.SDL_FRect = @splat(zero_rect),
    custom_snooze_month_bounds: [2]c.SDL_FRect = @splat(zero_rect),
    custom_snooze_calendar_bounds: c.SDL_FRect = zero_rect,
    sidebar_lifecycle: SidebarLifecycle.State = .{},
    sidebar_archived: bool = false,
    sidebar_archive_request: ?bool = null,
    sidebar_undo_bounds: c.SDL_FRect = zero_rect,
    sidebar_archive_bounds: c.SDL_FRect = zero_rect,
    sidebar_undo_label: [32]u8 = @splat(0),
    sidebar_undo_len: usize = 0,
    sidebar_undo_request: ?SidebarLifecycle.UndoOperation = null,
    sidebar_lifecycle_bounds: [2]c.SDL_FRect = @splat(zero_rect),
    sidebar_action_bounds: [32][2]c.SDL_FRect = @splat(@splat(zero_rect)),
    search_bounds: c.SDL_FRect = zero_rect,
    search_clear_bounds: c.SDL_FRect = zero_rect,
    search_query: [160]u8 = undefined,
    search_len: usize = 0,
    search_focused: bool = false,
    search_select_all: bool = false,
    search_edit: LineEdit = .{},
    rename_edit: LineEdit = .{},
    title_line_edit: LineEdit = .{},
    line_view: LineView = .{},
    line_drag: ?LineField = null,
    search_hover: usize = 0,
    scope_bounds: c.SDL_FRect = zero_rect,
    scope_all_bounds: c.SDL_FRect = zero_rect,
    scope_menu: c.SDL_FRect = zero_rect,
    scope_project: transcript.Id = .{},
    scope_open: bool = false,
    scope_scroll: f32 = 0,
    scope_hover: usize = 0,
    sidebar_hover: ?usize = null,
    new_project_bounds: c.SDL_FRect = zero_rect,
    new_thread_bounds: c.SDL_FRect = zero_rect,
    project_bounds: [16]c.SDL_FRect = @splat(zero_rect),
    thread_bounds: [32]c.SDL_FRect = @splat(zero_rect),
    title_bounds: c.SDL_FRect = zero_rect,
    title_editing: bool = false,
    title_select_all: bool = false,
    title_buffer: [160]u8 = undefined,
    title_len: usize = 0,
    title_action: ?TitleAction = null,
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
    setup_action: ?enum { configure, browser, device, status, refresh, open_login, choose_workspace } = null,
    setup_folder_bounds: c.SDL_FRect = zero_rect,
    setup_folder_pending: bool = false,
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
    active_thread_title: [160]u8 = undefined,
    active_thread_title_len: usize = 0,
    active_project: transcript.Id = .{},
    active_thread: transcript.Id = .{},
    navigation: ?Navigation = null,
    navigation_enabled: bool = false,
    retained: [16]Retained = @splat(.{}),
    retained_clock: u64 = 0,
    workspace_files: [64]WorkspaceFile = @splat(.{}),
    workspace_file_count: usize = 0,
    workspace_selected_file: ?usize = null,
    workspace_diff: [64 * 1024]u8 = undefined,
    workspace_diff_len: usize = 0,
    workspace_checkout: [256]u8 = undefined,
    workspace_checkout_len: usize = 0,
    workspace_revision: u64 = 0,
    workspace_open: bool = false,
    workspace_scroll: f32 = 0,
    workspace_diff_scroll: f32 = 0,
    workspace_bounds: c.SDL_FRect = zero_rect,
    workspace_close_bounds: c.SDL_FRect = zero_rect,
    workspace_file_bounds: [64]c.SDL_FRect = @splat(zero_rect),
    workspace_diff_bounds: c.SDL_FRect = zero_rect,
    workspace_toggle_bounds: c.SDL_FRect = zero_rect,
    workspace_stale: bool = false,
    workspace_diff_request: ?usize = null,
    workspace_diff_staged: bool = false,
    workspace_refresh_request: bool = false,
    workspace_refresh_bounds: c.SDL_FRect = zero_rect,
    workspace_busy: bool = false,
    workspace_feedback: [256]u8 = undefined,
    workspace_feedback_len: usize = 0,
    navigation_targets: hit_targets.SemanticTargets(128, 96, 16) = .{},
    thread_search_revision: u64 = 0,
    thread_search_busy: bool = false,
    model_search_query: [160]u8 = undefined,
    model_search_len: usize = 0,
    model_search_revision: u64 = 0,
    model_search_busy: bool = false,
    model_more_available: bool = false,
    model_action: ?enum { restart, next } = null,
    selected_model_cache: ?Model = null,
    search_more_available: bool = false,
    search_more_bounds: c.SDL_FRect = zero_rect,
    const zero_rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    pub const picker_row_height: f32 = 48;
    pub const sidebar_card_stride: f32 = 82;
    pub const sidebar_search_stride: f32 = 37;

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

    pub fn chooseWorkspaceEnabled(self: *const View) bool {
        return !self.setup_folder_pending and !self.setup_busy and !self.setup_login_pending;
    }

    pub fn setWorkspaceFolder(self: *View, path: []const u8) bool {
        if (path.len == 0 or path.len > self.setup_fields[2].len or !std.fs.path.isAbsolute(path) or
            !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return false;
        @memcpy(self.setup_fields[2][0..path.len], path);
        self.setup_lengths[2] = path.len;
        self.setup_field = 2;
        self.setup_select_all = false;
        return true;
    }

    /// Explicitly choose the launch Codex home; saved/custom drafts never migrate
    /// implicitly. Configure/discovery uses the ordinary Host command path.
    pub fn useExistingCodex(self: *View) void {
        if (!self.existingCodexEnabled()) return;
        const len = self.setup_existing_account_len;
        @memcpy(self.setup_fields[1][0..len], self.setup_existing_account[0..len]);
        self.setup_lengths[1] = len;
        self.requestSetupAction(0);
    }

    /// Every submission entry point shares availability and focus transitions.
    fn requestSetupAction(self: *View, index: usize) void {
        if (!self.setupActionEnabled(index)) return;
        self.setup_action = switch (index) {
            0 => .configure,
            1 => .browser,
            2 => .device,
            else => .refresh,
        };
        self.setup_advanced_open = false;
        self.setup_field = 2;
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
        if (index >= self.setup_button_bounds.len or self.setup_busy or self.setup_login_pending or self.setup_folder_pending) return false;
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
        // Provider selection is a routing boundary. A model identity from the
        // previous runtime must never remain sendable while the user edits a
        // different connection; the next catalog refresh will repopulate it.
        self.selected = null;
        self.model_count = 0;
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
    /// Sidebar navigation stays presentation-only. `search_more` asks the
    /// App/Host consumer for the next bounded page while retaining the draft,
    /// current thread and scroll state in this view.
    pub const SidebarAction = enum { pin, unpin, settle, unsettle, snooze, wake, move_up, move_down };
    pub const RenameFollowup = union(enum) {
        thread: transcript.Id,
        new_thread,
        new_project,
        edit_active_title,
        sidebar: struct { id: transcript.Id, action: SidebarAction, snoozed_until: i64 = 0 },
    };
    pub const Navigation = union(enum) {
        new_project,
        new_thread,
        project: usize,
        thread: usize,
        search_more,
        search_reset,
        rename: struct { index: usize, title: [160]u8, len: usize },
        sidebar: struct { index: usize, action: SidebarAction, snoozed_until: i64 = 0 },
    };
    pub const RunStatus = enum { idle, running, question, approval, failed, interrupted, unknown };
    pub const Entry = struct {
        id: transcript.Id = .{},
        label: [160]u8 = undefined,
        len: usize = 0,
        project_id: transcript.Id = .{},
        project_name: transcript.Id = .{},
        workspace_name: transcript.Id = .{},
        branch: transcript.Id = .{},
        run_status: RunStatus = .idle,
        can_snooze: bool = false,
        runtime_kind: transcript.Id = .{},
        model_provider: transcript.Id = .{},
        model_id: transcript.Id = .{},
        updated_at_ms: i64 = 0,
        workspace_path: [1024]u8 = undefined,
        workspace_path_len: usize = 0,
        revision: u64 = 0,
        pinned: bool = false,
        settled: bool = false,
        snoozed_until: i64 = 0,
        sort_order: i64 = 0,
        archived: bool = false,
        can_archive: bool = false,
        can_delete: bool = false,
    };

    pub const WorkflowAction = union(enum) { cleanup_prompt, add, remove: usize, enqueue, edit: usize, cancel: usize, up: usize, down: usize, question_choice: usize, question_submit };
    pub const Followup = struct {
        id: transcript.Id = .{},
        revision: u64 = 0,
        state: enum { planned, in_flight, withdrawn, confirmed, failed, unknown } = .planned,
        content: []u8 = &.{},
        len: usize = 0,
    };

    pub fn workflowNotice(self: *View, message: []const u8) void {
        const clipped = @import("../text/utf8.zig").prefix(message, self.workflow_feedback.len);
        @memcpy(self.workflow_feedback[0..clipped.len], clipped);
        self.workflow_feedback_len = clipped.len;
    }

    pub fn scopeWorkflow(self: *View, run: transcript.Id) void {
        if (self.workflow_run.eql(run.slice())) return;
        self.workflow_run = run;
        for (self.followups[0..self.followup_count]) |*item| {
            self.allocator.free(item.content);
            item.* = .{};
        }
        self.followup_count = 0;
        self.followup_editing = null;
        self.workflow_uncertain = false;
        self.workflow_action = null;
        self.question_pending = false;
        self.question_id = .{};
        self.question_revision = 0;
        self.question_prompt_len = 0;
        self.question_choice_count = 0;
        self.question_selected = 0;
        self.question_answer_len = 0;
    }

    fn workflowInsert(self: *View, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidUtf8;
        const start = if (self.workflow_path_select_all) 0 else self.workflow_path_len;
        if (start + bytes.len > self.workflow_path.len) return error.TextTooLarge;
        @memcpy(self.workflow_path[start..][0..bytes.len], bytes);
        self.workflow_path_len = start + bytes.len;
        self.workflow_path_select_all = false;
    }

    fn workflowActivate(self: *View, id: []const u8) !void {
        if (std.mem.eql(u8, id, "workflow.close")) {
            self.workflow_open = false;
            self.workflow_path_focus = false;
            self.focused = true;
        } else if (std.mem.eql(u8, id, "attachment.path")) {
            self.workflow_path_focus = true;
            self.workflow_path_select_all = true;
        } else if (std.mem.eql(u8, id, "question.answer")) {
            self.workflow_path_focus = true;
            self.workflow_path_select_all = true;
        } else if (std.mem.eql(u8, id, "question.submit")) {
            self.workflow_action = .question_submit;
        } else if (std.mem.eql(u8, id, "workflow.previous")) {
            self.workflow_page -|= 1;
        } else if (std.mem.eql(u8, id, "workflow.next")) {
            self.workflow_page = @min(7, self.workflow_page + 1);
        } else if (std.mem.eql(u8, id, "followup.stop_edit")) {
            self.followup_editing = null;
            self.workflowNotice("Editing stopped. Composer retained as a new draft.");
        } else if (!self.workflow_busy) {
            if (std.mem.eql(u8, id, "attachment.add")) self.workflow_action = .add;
            if (std.mem.eql(u8, id, "prompt.cleanup")) self.workflow_action = .cleanup_prompt;
            if (std.mem.eql(u8, id, "followup.enqueue")) self.workflow_action = .enqueue;
            var buffer: [64]u8 = undefined;
            for (0..attachment_text.max_count) |i| if (std.mem.eql(u8, id, try std.fmt.bufPrint(&buffer, "attachment.remove.{d}", .{i}))) {
                self.workflow_action = .{ .remove = i };
            };
            for (0..self.followup_count) |i| {
                inline for (.{ "edit", "cancel", "up", "down" }) |kind| {
                    if (std.mem.eql(u8, id, try std.fmt.bufPrint(&buffer, "followup." ++ kind ++ ".{d}", .{i}))) self.workflow_action = @unionInit(WorkflowAction, kind, i);
                }
            }
            for (0..self.question_choice_count) |i| {
                if (std.mem.eql(u8, id, std.fmt.bufPrint(&buffer, "question.choice.{d}", .{i}) catch "")) self.workflow_action = .{ .question_choice = i };
            }
        }
    }

    const Retained = struct {
        id: transcript.Id = .{},
        editor: ?Composer = null,
        attachments: ?attachment_text.Store = null,
        workflow_run: transcript.Id = .{},
        workflow_uncertain: bool = false,
        followups: [8]Followup = @splat(.{}),
        followup_count: usize = 0,
        followup_editing: ?transcript.Id = null,
        revision: u64 = 0,
        scroll: f32 = 0,
        follow: bool = true,
        position: ?ThreadHistory = null,
        used: u64 = 0,
        selection: ?Identity = null,
    };
    pub const WorkspaceFile = WorkspaceFileData;

    pub fn selectThread(self: *View, id: transcript.Id) !void {
        if (self.active_thread.eql(id.slice())) return;
        self.title_editing = false;
        self.title_select_all = false;
        self.title_action = null;
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
            self.retained[index] = .{ .id = self.active_thread, .editor = self.editor, .revision = self.revision, .scroll = self.editor_view.scroll, .follow = self.follow_latest, .position = self.history_position, .selection = self.selected, .used = self.retained_clock, .attachments = self.attachments, .workflow_run = self.workflow_run, .workflow_uncertain = self.workflow_uncertain, .followups = self.followups, .followup_count = self.followup_count, .followup_editing = self.followup_editing };
        }
        self.editor = next.editor.?;
        self.attachments = next.attachments orelse attachment_text.Store.init(self.allocator);
        self.workflow_path_len = 0;
        self.workflow_feedback_len = 0;
        self.workflow_error = "";
        self.workflow_run = next.workflow_run;
        self.workflow_uncertain = next.workflow_uncertain;
        self.followups = next.followups;
        self.followup_count = next.followup_count;
        self.followup_editing = next.followup_editing;
        self.workflow_page = 0;
        self.selected = next.selection;
        self.revision = next.revision;
        self.editor_view.deinit();
        self.editor_view = .{ .scroll = next.scroll };
        self.follow_latest = next.follow;
        self.history_position = next.position;
        self.history_restore = next.position != null;
        self.active_thread = id;
        self.active_thread_title_len = 0;
        for (self.threads[0..self.thread_count]) |*entry| if (entry.id.eql(id.slice())) {
            self.active_thread_title_len = entry.len;
            @memcpy(self.active_thread_title[0..entry.len], entry.label[0..entry.len]);
            break;
        };
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
        var view: View = undefined;
        try view.initInto(allocator);
        return view;
    }

    /// Initialize the fixed-capacity view in its owner's storage. Production
    /// startup must not duplicate these large arrays in nested stack frames.
    pub fn initInto(self: *View, allocator: std.mem.Allocator) !void {
        var editor = try Composer.init(allocator);
        errdefer editor.deinit();
        self.* = .{ .allocator = allocator, .editor = editor, .scratch = try allocator.alloc(u8, 64 * 1024 + 1), .attachments = attachment_text.Store.init(allocator) };
    }

    pub fn deinit(self: *View) void {
        for (&self.retained) |*slot| {
            if (slot.editor) |*editor| editor.deinit();
            if (slot.attachments) |*attachments| attachments.deinit();
            for (slot.followups[0..slot.followup_count]) |item| self.allocator.free(item.content);
        }
        self.attachments.deinit();
        for (self.followups[0..self.followup_count]) |item| self.allocator.free(item.content);
        for (&self.rich_tiles) |*tile| tile.deinit();
        self.custom_tile.deinit();
        self.line_view.deinit();
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
        self.sidebar_resizing = false;
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

    pub fn selectedModel(self: *const View) ?*const Model {
        const selected = self.selected orelse return null;
        for (self.models[0..self.model_count]) |*model| if (sameModel(model.identity, selected)) return model;
        if (self.selected_model_cache) |*model| if (sameModel(model.identity, selected)) return model;
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
        if (self.custom_snooze != null or self.sidebar_collapsed or self.scope_open or self.sidebar_menu_thread.len != 0 or index >= self.thread_count or !self.threadMatches(&self.threads[index]) or !self.sidebarShelfVisible(&self.threads[index])) return zero_rect;
        return clippedRect(self.thread_bounds[index], self.sidebar_rows);
    }

    pub fn beginTitleEdit(self: *View) void {
        if (self.active_thread.len == 0) return;
        self.sidebar_rename_thread = .{};
        self.search_focused = false;
        for (self.threads[0..self.thread_count]) |*entry| if (entry.id.eql(self.active_thread.slice())) {
            self.title_len = entry.len;
            @memcpy(self.title_buffer[0..self.title_len], entry.label[0..entry.len]);
            self.line_view.reset();
            self.title_line_edit = .{};
            self.title_select_all = true;
            self.title_editing = true;
            self.title_action = null;
            return;
        };
        if (self.active_thread_title_len != 0) {
            self.title_len = self.active_thread_title_len;
            @memcpy(self.title_buffer[0..self.title_len], self.active_thread_title[0..self.title_len]);
            self.line_view.reset();
            self.title_line_edit = .{};
            self.title_select_all = true;
            self.title_editing = true;
            self.title_action = null;
        }
    }

    pub fn titleEditAvailable(self: *const View) bool {
        return self.custom_root == null and self.navigation_enabled and self.active_thread.len != 0 and
            !self.setup_open and !self.workspace_open and !self.workflow_open and !self.scope_open and !self.picker_open and !self.effort_open;
    }

    fn titleInsert(self: *View, bytes: []const u8) !void {
        try self.lineInsert(.title, bytes);
    }

    fn finishTitle(self: *View, action: TitleAction) void {
        if (action == .save) {
            const trimmed = std.mem.trim(u8, self.title_buffer[0..self.title_len], " \t\r\n");
            if (trimmed.len == 0) {
                self.title_action = .cancel;
                self.title_editing = false;
            } else {
                std.mem.copyForwards(u8, &self.title_buffer, trimmed);
                self.title_len = trimmed.len;
                self.title_action = .save;
            }
        } else {
            self.title_action = .cancel;
            self.title_editing = false;
        }
        self.line_view.reset();
    }

    fn clippedRect(row: c.SDL_FRect, viewport: c.SDL_FRect) c.SDL_FRect {
        const x = @max(row.x, viewport.x);
        const y = @max(row.y, viewport.y);
        const right = @min(row.x + row.w, viewport.x + viewport.w);
        const bottom = @min(row.y + row.h, viewport.y + viewport.h);
        if (right <= x or bottom <= y) return zero_rect;
        return .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
    }

    pub fn threadMatches(self: *const View, entry: *const Entry) bool {
        if (self.scope_project.len != 0 and !entry.project_id.eql(self.scope_project.slice())) return false;
        const query = std.mem.trim(u8, self.search_query[0..self.search_len], " \t\r\n");
        if (query.len == 0) return true;
        // Reuse the retained Unicode fold table. Both the source metadata and
        // query are bounded, and ASCII candidates keep the short fast path.
        for ([_][]const u8{ entry.label[0..entry.len], entry.project_name.slice(), entry.workspace_name.slice(), entry.branch.slice() }) |value| {
            if (searchContains(value, query)) return true;
        }
        return false;
    }

    fn foldedSearch(bytes: []const u8, output: []u32) ?[]const u32 {
        const input = std.unicode.Utf8View.init(bytes) catch return null;
        var iterator = input.iterator();
        var length: usize = 0;
        while (iterator.nextCodepoint()) |scalar| {
            var folded: [3]u32 = undefined;
            const count = fuzzy.spica_fuzzy_case_fold(scalar, &folded);
            if (count > folded.len or length + count > output.len) return null;
            @memcpy(output[length..][0..count], folded[0..count]);
            length += count;
        }
        return output[0..length];
    }

    fn searchContains(value: []const u8, query: []const u8) bool {
        var ascii = true;
        for (value) |byte| {
            if (byte >= 0x80) {
                ascii = false;
                break;
            }
        }
        if (ascii) for (query) |byte| {
            if (byte >= 0x80) {
                ascii = false;
                break;
            }
        };
        if (ascii) return std.ascii.indexOfIgnoreCase(value, query) != null;
        var query_buffer: [160 * 3]u32 = undefined;
        var value_buffer: [transcript.id_bytes * 3]u32 = undefined;
        const folded_query = foldedSearch(query, &query_buffer) orelse return false;
        const folded_value = foldedSearch(value, &value_buffer) orelse return false;
        return std.mem.indexOf(u32, folded_value, folded_query) != null;
    }

    pub fn visibleThreadCount(self: *const View) usize {
        var count: usize = 0;
        for (self.threads[0..self.thread_count]) |*entry| if (self.threadMatches(entry)) {
            count += 1;
        };
        return count;
    }

    pub fn wallTimeMs() i64 {
        var time: c.SDL_Time = 0;
        if (!c.SDL_GetCurrentTime(&time)) return 0;
        return @divFloor(time, 1_000_000);
    }

    pub fn nextSidebarWakeMs(self: *const View, now: i64) ?i64 {
        var next: ?i64 = null;
        for (self.threads[0..self.thread_count]) |entry| {
            if (entry.snoozed_until > now and (next == null or entry.snoozed_until < next.?)) next = entry.snoozed_until;
        }
        return next;
    }

    const SidebarSection = enum(u8) { pinned, active, working, snoozed, settled };

    fn sidebarSection(self: *const View, entry: *const Entry) SidebarSection {
        if (entry.archived) return .settled;
        if (entry.snoozed_until > self.sidebar_now_ms) return .snoozed;
        if (entry.settled) return .settled;
        if (entry.pinned) return .pinned;
        if (self.sidebar_working_shelf and entry.run_status == .running) return .working;
        return .active;
    }

    fn sidebarSlim(self: *const View, entry: *const Entry) bool {
        const section = self.sidebarSection(entry);
        return self.search_len != 0 or section == .snoozed or section == .settled;
    }

    fn sidebarShelfVisible(self: *const View, entry: *const Entry) bool {
        if (self.search_len != 0) return true;
        const section = @intFromEnum(self.sidebarSection(entry));
        return section < 2 or self.sidebar_shelf_expanded[section - 2] or entry.id.eql(self.active_thread.slice());
    }

    fn sidebarContentHeight(self: *const View) f32 {
        var height: f32 = 0;
        var counts: [5]usize = @splat(0);
        for (self.threads[0..self.thread_count]) |*entry| {
            if (!self.threadMatches(entry)) continue;
            counts[@intFromEnum(self.sidebarSection(entry))] += 1;
            if (self.sidebarShelfVisible(entry)) height += if (self.sidebarSlim(entry)) sidebar_search_stride else sidebar_card_stride;
        }
        if (self.search_len == 0 and self.visibleThreadCount() != 0) {
            if (counts[2] != 0) height += 33;
            if (counts[3] != 0) height += 33;
            height += 33; // The settled shelf remains available when empty.
        }
        return height;
    }

    fn sidebarMenuIndex(self: *const View) ?usize {
        if (self.sidebar_menu_thread.len == 0) return null;
        for (self.threads[0..self.thread_count], 0..) |entry, index| {
            if (entry.id.eql(self.sidebar_menu_thread.slice())) return index;
        }
        return null;
    }

    fn openSidebarSnooze(self: *View) void {
        self.sidebar_menu_mode = .snooze;
        self.sidebar_snooze_deadlines = @splat(0);
        self.sidebar_snooze_when = @splat(.{});
        self.sidebar_snooze_count = 0;
        const options = SidebarTime.presets(wallTimeMs()) catch {
            self.sidebar_menu_panel = SidebarMenu.snooze(@splat(false));
            self.sidebar_menu_count = self.sidebar_menu_panel.len;
            self.sidebar_menu_hover = 0;
            return;
        };
        var available: [5]bool = @splat(false);
        for (options.slice()) |option| {
            const slot: usize = switch (option.id) {
                .one_hour => 0,
                .three_hours => 1,
                .this_evening => 2,
                .tomorrow => 3,
                .next_monday => 4,
            };
            self.sidebar_snooze_deadlines[slot] = option.wake_ms;
            self.sidebar_snooze_when[slot] = option.when_label;
            self.sidebar_snooze_count = @max(self.sidebar_snooze_count, slot + 1);
            available[slot] = true;
        }
        self.sidebar_menu_panel = SidebarMenu.snooze(available);
        self.sidebar_menu_count = self.sidebar_menu_panel.len;
        self.sidebar_menu_panel.edge(false);
        self.sidebar_menu_hover = self.sidebar_menu_panel.selected orelse 0;
    }

    fn activateSidebarMenu(self: *View, row: usize) void {
        const index = self.sidebarMenuIndex() orelse return;
        if (row >= self.sidebar_menu_panel.len) return;
        const item = self.sidebar_menu_panel.items[row];
        if (!item.enabled) return;
        const entry = &self.threads[index];
        switch (self.sidebar_menu_mode) {
            .copy => switch (item.action) {
                .copy_path => {
                    clipboard.copyBytes(entry.workspace_path[0..entry.workspace_path_len], self.scratch) catch {
                        self.notice = "Unable to copy workspace path";
                    };
                },
                .copy_branch => {
                    clipboard.copyBytes(entry.branch.slice(), self.scratch) catch {
                        self.notice = "Unable to copy branch";
                    };
                },
                .copy_id => {
                    clipboard.copyBytes(entry.id.slice(), self.scratch) catch {
                        self.notice = "Unable to copy thread ID";
                    };
                },
                else => return,
            },
            .snooze => switch (item.action) {
                .preset => {
                    const deadline = self.sidebar_snooze_deadlines[item.preset_index];
                    if (deadline <= wallTimeMs()) return;
                    self.navigation = .{ .sidebar = .{ .index = index, .action = .snooze, .snoozed_until = deadline } };
                },
                .custom => {
                    self.custom_snooze = SidebarSnooze.State.init(wallTimeMs()) catch {
                        self.notice = "Local calendar is unavailable";
                        return;
                    };
                    self.custom_snooze_thread = entry.id;
                    self.custom_snooze_focus = .date;
                    self.sidebar_menu_thread = .{};
                    self.line_view.reset();
                    return;
                },
                else => return,
            },
            .main => switch (item.action) {
                .copy => {
                    self.sidebar_menu_mode = .copy;
                    self.sidebar_menu_panel = SidebarMenu.copy(entry.workspace_path_len != 0, entry.branch.len != 0);
                    self.sidebar_menu_count = self.sidebar_menu_panel.len;
                    self.sidebar_menu_hover = self.sidebar_menu_panel.selected orelse 0;
                    return;
                },
                .rename => self.beginSidebarRename(index),
                .filter => {
                    self.scope_project = if (self.scope_project.eql(entry.project_id.slice())) .{} else entry.project_id;
                    self.sidebarChanged();
                },
                .pin, .unpin, .settle, .unsettle, .wake => |action| {
                    const sidebar_action: SidebarAction = switch (action) {
                        .pin => .pin,
                        .unpin => .unpin,
                        .settle => .settle,
                        .unsettle => .unsettle,
                        .wake => .wake,
                        else => return,
                    };
                    self.navigation = .{ .sidebar = .{ .index = index, .action = sidebar_action, .snoozed_until = 0 } };
                },
                .snooze => {
                    self.openSidebarSnooze();
                    return;
                },
                .archive, .restore, .delete => |action| {
                    self.requestSidebarLifecycle(entry.id, switch (action) {
                        .archive => .archive,
                        .restore => .restore,
                        .delete => .delete,
                        else => unreachable,
                    });
                    return;
                },
                else => return,
            },
        }
        self.sidebar_menu_thread = .{};
        self.sidebar_menu_count = 0;
        self.sidebar_menu_mode = .main;
    }

    pub const CustomSnoozeRequest = struct { id: transcript.Id, snoozed_until: i64 };
    pub fn customSnoozeOpen(self: *const View) bool {
        return self.custom_snooze != null;
    }
    pub fn customSnoozePending(self: *const View) bool {
        return if (self.custom_snooze) |state| state.pending else false;
    }
    pub fn takeCustomSnoozeRequest(self: *View) ?CustomSnoozeRequest {
        const state = if (self.custom_snooze) |*state| state else return null;
        if (!state.requested or state.pending) return null;
        state.requested = false;
        state.pending = true;
        return .{ .id = self.custom_snooze_thread, .snoozed_until = state.deadline };
    }
    pub fn finishCustomSnooze(self: *View, failure: ?[]const u8) void {
        if (failure) |message| {
            if (self.custom_snooze) |*state| {
                state.pending = false;
                state.requested = false;
                state.setError(message);
            }
        } else {
            self.custom_snooze = null;
            self.custom_snooze_thread = .{};
            self.line_view.reset();
        }
    }

    pub const SidebarLifecycleRequest = SidebarLifecycle.Request;
    pub const SidebarUndoOperation = SidebarLifecycle.UndoOperation;
    pub fn takeSidebarLifecycleRequest(self: *View) ?SidebarLifecycleRequest {
        return self.sidebar_lifecycle.take();
    }
    pub fn sidebarLifecycleConfirmOpen(self: *const View) bool {
        return self.sidebar_lifecycle.confirming != null;
    }
    pub fn sidebarLifecyclePending(self: *const View) bool {
        return self.sidebar_lifecycle.pending;
    }
    pub fn finishSidebarLifecycle(self: *View, failure: ?[]const u8) void {
        self.sidebar_lifecycle.finish(failure);
    }
    pub fn requestSidebarLifecycle(self: *View, id: transcript.Id, action: SidebarLifecycle.Action) void {
        self.sidebar_lifecycle.request(id, action);
    }
    pub fn confirmSidebarDelete(self: *View) void {
        self.sidebar_lifecycle.confirmDelete();
    }
    pub fn offerSidebarUndo(self: *View, operation: SidebarUndoOperation, label: []const u8) void {
        self.sidebar_lifecycle.offerUndo(operation, label, wallTimeMs());
    }
    pub fn takeSidebarUndoRequest(self: *View) ?SidebarUndoOperation {
        const undo_request = self.sidebar_undo_request;
        self.sidebar_undo_request = null;
        return undo_request orelse self.sidebar_lifecycle.takeUndo(wallTimeMs());
    }
    pub fn invalidateSidebarUndo(self: *View, id: transcript.Id) void {
        self.sidebar_lifecycle.invalidateUndo(id);
    }

    fn claimSidebarUndo(self: *View) void {
        if (self.sidebar_undo_request == null) self.sidebar_undo_request = self.sidebar_lifecycle.takeUndo(wallTimeMs());
    }
    pub fn takeSidebarArchiveBrowserRequest(self: *View) ?bool {
        const archive_request = self.sidebar_archive_request;
        self.sidebar_archive_request = null;
        return archive_request;
    }
    pub fn discardSidebarThreadDraft(self: *View, id: transcript.Id) void {
        if (self.active_thread.eql(id.slice())) {
            self.editor.setText("") catch {};
            self.active_thread = .{};
            self.active_project = .{};
        }
    }

    fn handleSidebarLifecycle(self: *View, event: c.SDL_Event) bool {
        if (self.sidebar_lifecycle.confirming == null) return false;
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            if (event.key.key == c.SDLK_ESCAPE) {
                self.sidebar_lifecycle.confirming = null;
                return true;
            }
            if (event.key.key == c.SDLK_RETURN or event.key.key == c.SDLK_KP_ENTER) {
                if (self.sidebar_lifecycle.confirm_delete_selected) {
                    self.confirmSidebarDelete();
                } else {
                    self.sidebar_lifecycle.confirming = null;
                }
                return true;
            }
            if (event.key.key == c.SDLK_TAB or event.key.key == c.SDLK_LEFT or event.key.key == c.SDLK_RIGHT) {
                self.sidebar_lifecycle.confirm_delete_selected = !self.sidebar_lifecycle.confirm_delete_selected;
                return true;
            }
        } else if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and event.button.button == c.SDL_BUTTON_LEFT) {
            if (widgets.contains(self.sidebar_lifecycle_bounds[0], event.button.x, event.button.y)) {
                self.sidebar_lifecycle.confirm_delete_selected = false;
                self.sidebar_lifecycle.confirming = null;
                return true;
            }
            if (widgets.contains(self.sidebar_lifecycle_bounds[1], event.button.x, event.button.y)) {
                self.sidebar_lifecycle.confirm_delete_selected = true;
                self.confirmSidebarDelete();
                return true;
            }
        }
        return true;
    }

    fn beginSidebarRename(self: *View, index: usize) void {
        if (index >= self.thread_count or !self.navigation_enabled) return;
        const entry = &self.threads[index];
        self.title_editing = false;
        self.sidebar_rename_followup = null;
        self.sidebar_rename_thread = entry.id;
        self.sidebar_rename_len = entry.len;
        @memcpy(self.sidebar_rename_buffer[0..entry.len], entry.label[0..entry.len]);
        self.line_view.reset();
        self.rename_edit = .{};
        self.sidebar_rename_select_all = true;
        self.search_focused = false;
    }

    fn sidebarRenameInsert(self: *View, bytes: []const u8) !void {
        try self.lineInsert(.rename, bytes);
    }

    pub fn takeRenameFollowup(self: *View) ?RenameFollowup {
        const action = self.sidebar_rename_followup;
        self.sidebar_rename_followup = null;
        return action;
    }

    fn commitSidebarRename(self: *View) void {
        const trimmed = std.mem.trim(u8, self.sidebar_rename_buffer[0..self.sidebar_rename_len], " \t\r\n");
        if (trimmed.len == 0) {
            self.sidebar_rename_thread = .{};
            self.line_view.reset();
            return;
        }
        std.mem.copyForwards(u8, &self.sidebar_rename_buffer, trimmed);
        self.sidebar_rename_len = trimmed.len;
        self.line_view.reset();
        for (self.threads[0..self.thread_count], 0..) |entry, index| {
            if (entry.id.eql(self.sidebar_rename_thread.slice())) {
                self.navigation = .{ .rename = .{ .index = index, .title = self.sidebar_rename_buffer, .len = self.sidebar_rename_len } };
                self.sidebar_rename_thread = .{};
                return;
            }
        }
        self.sidebar_rename_thread = .{};
    }

    fn drawSidebarTitle(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, entry: *const Entry, x: f32, y: f32, width: f32, foreground: Color) !void {
        if (entry.id.eql(self.sidebar_rename_thread.slice())) {
            self.sidebar_rename_bounds = .{ .x = x - 2, .y = y - 2, .w = @max(0, width + 4), .h = 22 };
            try widgets.panel(renderer, self.sidebar_rename_bounds, 3, self.design.colors.border);
            const parts = self.lineParts(.rename);
            parts.edit.sync(parts.len.*, parts.select.*);
            try self.line_view.draw(renderer, text, parts.buffer[0..parts.len.*], parts.edit.*, .{ .x = x, .y = y, .w = width, .h = 20 }, foreground, self.design.colors.selection, self.window_active and self.activeLine() == .rename);
            _ = self.navigation_targets.add("sidebar.rename", "textbox", self.sidebar_rename_bounds, true) catch {};
        } else try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], x, y, width, 14, foreground);
    }

    fn sidebarStride(self: *const View) f32 {
        return if (self.search_len != 0) sidebar_search_stride else sidebar_card_stride;
    }

    fn openScope(self: *View) void {
        self.scope_open = true;
        self.scope_hover = 0;
        for (self.projects[0..self.project_count], 0..) |entry, index| {
            if (entry.id.eql(self.scope_project.slice())) self.scope_hover = index + 1;
        }
        self.scope_scroll = 0;
    }

    fn sidebarChanged(self: *View) void {
        self.thread_search_revision +%= 1;
        self.thread_search_busy = false;
        self.sidebar_scroll = 0;
        self.search_hover = 0;
        self.sidebar_hover = null;
        self.thread_bounds = @splat(zero_rect);
    }

    /// Admit a completed read-only inspection only for the currently selected
    /// checkout. Callers pass an explicit revision so a late worker result can
    /// be rejected without disturbing drafts, selection or scroll positions.
    pub fn admitWorkspaceInspection(self: *View, revision: u64, checkout: []const u8, files: []const WorkspaceFile, diff: []const u8) bool {
        if (revision < self.workspace_revision) {
            self.workspace_stale = true;
            return false;
        }
        if (checkout.len > self.workspace_checkout.len or !std.unicode.utf8ValidateSlice(checkout)) {
            self.workspace_stale = true;
            return false;
        }
        if (self.workspace_checkout_len != 0 and !std.mem.eql(u8, self.workspace_checkout[0..self.workspace_checkout_len], checkout)) {
            self.workspace_stale = true;
            return false;
        }
        if (files.len > self.workspace_files.len or diff.len > self.workspace_diff.len or !std.unicode.utf8ValidateSlice(diff)) {
            self.workspace_stale = true;
            return false;
        }
        for (files) |file| {
            if (file.path_len == 0 or file.path_len > file.path.len or file.original_len > file.original.len or
                !std.unicode.utf8ValidateSlice(file.path[0..file.path_len]) or
                !std.unicode.utf8ValidateSlice(file.original[0..file.original_len]))
            {
                self.workspace_stale = true;
                return false;
            }
        }
        var selected_path: [256]u8 = undefined;
        var selected_path_len: usize = 0;
        if (self.workspace_selected_file) |index| if (index < self.workspace_file_count) {
            selected_path_len = self.workspace_files[index].path_len;
            @memcpy(selected_path[0..selected_path_len], self.workspace_files[index].path[0..selected_path_len]);
        };
        self.workspace_checkout_len = checkout.len;
        @memmove(self.workspace_checkout[0..checkout.len], checkout);
        self.workspace_file_count = files.len;
        @memmove(self.workspace_files[0..files.len], files);
        self.workspace_diff_len = diff.len;
        @memmove(self.workspace_diff[0..diff.len], diff);
        self.workspace_revision = revision;
        self.workspace_stale = false;
        self.workspace_selected_file = null;
        if (selected_path_len != 0) for (self.workspace_files[0..self.workspace_file_count], 0..) |file, index| {
            if (file.path_len == selected_path_len and std.mem.eql(u8, file.path[0..file.path_len], selected_path[0..selected_path_len])) {
                self.workspace_selected_file = index;
                break;
            }
        };
        if (self.workspace_selected_file == null and files.len != 0) self.workspace_selected_file = 0;
        return true;
    }

    pub fn workspaceFileAt(self: *const View, x: f32, y: f32) ?usize {
        if (!self.workspace_open) return null;
        for (self.workspace_file_bounds[0..self.workspace_file_count], 0..) |bounds, index| {
            if (widgets.contains(bounds, x, y)) return index;
        }
        return null;
    }

    pub fn takeWorkspaceDiffRequest(self: *View) ?WorkspaceFile {
        const index = self.workspace_diff_request orelse return null;
        self.workspace_diff_request = null;
        if (index >= self.workspace_file_count) return null;
        return self.workspace_files[index];
    }

    pub fn takeWorkspaceRefreshRequest(self: *View) bool {
        const requested = self.workspace_refresh_request;
        self.workspace_refresh_request = false;
        return requested;
    }

    const LineField = enum { search, rename, title, snooze_date, snooze_time, snooze_amount };
    const LineParts = struct { buffer: []u8, len: *usize, select: *bool, edit: *LineEdit };
    pub fn inputErrorNotice(self: *const View, err: anyerror) ?[]const u8 {
        return switch (err) {
            error.TextTooLarge => if (self.activeLine()) |field| switch (field) {
                .search => "Search is limited to 160 UTF-8 bytes. Existing text retained.",
                .rename, .title => "Titles are limited to 160 UTF-8 bytes. Existing text retained.",
                .snooze_date, .snooze_time, .snooze_amount => "This field is limited to 32 UTF-8 bytes. Existing text retained.",
            } else "Text exceeds this editor's limit. Existing text retained.",
            error.PieceLimit => "The editor has reached its limit. Existing text retained.",
            error.InvalidUtf8 => "Text is not valid UTF-8. Existing text retained.",
            error.InvalidTitle => "Use a single line without control characters. Existing text retained.",
            error.ClipboardRead => "Unable to read the clipboard. Existing text retained.",
            error.ClipboardWrite => "Unable to copy to the clipboard.",
            error.ClipboardContainsNul => "The clipboard text contains an unsupported null character.",
            else => null,
        };
    }

    fn lineParts(self: *View, field: LineField) LineParts {
        return switch (field) {
            .search => .{ .buffer = &self.search_query, .len = &self.search_len, .select = &self.search_select_all, .edit = &self.search_edit },
            .rename => .{ .buffer = &self.sidebar_rename_buffer, .len = &self.sidebar_rename_len, .select = &self.sidebar_rename_select_all, .edit = &self.rename_edit },
            .title => .{ .buffer = &self.title_buffer, .len = &self.title_len, .select = &self.title_select_all, .edit = &self.title_line_edit },
            .snooze_date, .snooze_time, .snooze_amount => blk: {
                const state = &self.custom_snooze.?;
                const value = switch (field) {
                    .snooze_date => &state.date,
                    .snooze_time => &state.time,
                    .snooze_amount => &state.amount,
                    else => unreachable,
                };
                break :blk .{ .buffer = &value.bytes, .len = &value.len, .select = &value.select, .edit = &value.edit };
            },
        };
    }
    fn activeLine(self: *const View) ?LineField {
        if (self.custom_snooze) |state| {
            if (state.pending or state.calendar_open) return null;
            return switch (self.custom_snooze_focus) {
                .date => .snooze_date,
                .time => .snooze_time,
                .amount => .snooze_amount,
                else => null,
            };
        }
        if (self.custom_root != null or self.setup_open or self.workflow_open or self.workspace_open or self.scope_open or self.picker_open or self.effort_open or self.sidebar_menu_thread.len != 0) return null;
        if (self.sidebar_rename_thread.len != 0) return .rename;
        if (self.title_editing) return .title;
        if (self.search_focused) return .search;
        return null;
    }
    fn lineInsert(self: *View, field: LineField, bytes: []const u8) !void {
        const parts = self.lineParts(field);
        parts.edit.sync(parts.len.*, parts.select.*);
        try parts.edit.insert(parts.buffer, parts.len, bytes);
        parts.select.* = false;
        self.line_view.preedit_len = 0;
        if (field == .search) self.sidebarChanged();
    }
    fn lineKey(self: *View, field: LineField, key: c.SDL_Keycode, ctrl: bool, shift: bool) !bool {
        const parts = self.lineParts(field);
        parts.edit.sync(parts.len.*, parts.select.*);
        var edited = false;
        switch (key) {
            c.SDLK_A => {
                if (!ctrl) return false;
                parts.edit.sync(parts.len.*, true);
            },
            c.SDLK_LEFT, c.SDLK_RIGHT => try parts.edit.move(parts.buffer[0..parts.len.*], key == c.SDLK_RIGHT, ctrl, shift),
            c.SDLK_HOME, c.SDLK_END => parts.edit.set(if (key == c.SDLK_HOME) 0 else parts.len.*, shift),
            c.SDLK_BACKSPACE, c.SDLK_DELETE => {
                try parts.edit.delete(parts.buffer, parts.len, key == c.SDLK_DELETE, ctrl);
                edited = true;
            },
            c.SDLK_C, c.SDLK_X => {
                if (!ctrl) return false;
                const range = parts.edit.range();
                var copy: [161]u8 = undefined;
                try clipboard.copyBytes(parts.buffer[range.start..range.end], &copy);
                if (key == c.SDLK_X) {
                    try parts.edit.insert(parts.buffer, parts.len, "");
                    edited = true;
                }
            },
            c.SDLK_V => {
                if (!ctrl) return false;
                const value = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                defer c.SDL_free(value);
                try parts.edit.insert(parts.buffer, parts.len, std.mem.span(value));
                edited = true;
            },
            else => return false,
        }
        parts.select.* = false;
        if (edited) {
            self.line_view.preedit_len = 0;
            if (field == .search) self.sidebarChanged();
        }
        return true;
    }
    fn searchInsert(self: *View, bytes: []const u8) !void {
        try self.lineInsert(.search, bytes);
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

    fn customSnoozeActivate(self: *View, target: usize) void {
        const state = &(self.custom_snooze orelse return);
        if (state.pending) return;
        self.custom_snooze_focus = @enumFromInt(target);
        switch (self.custom_snooze_focus) {
            .date_mode => {
                self.custom_snooze.?.mode = .date;
                self.custom_snooze.?.calendar_open = false;
            },
            .duration_mode => {
                self.custom_snooze.?.mode = .duration;
                self.custom_snooze.?.calendar_open = false;
            },
            .calendar => {
                self.custom_snooze.?.calendar_open = !state.calendar_open;
                if (state.date.len == 10) self.custom_snooze.?.calendar = SidebarMenu.Calendar.init(state.date.bytes[0..10].*, state.calendar.today) catch state.calendar;
                for (0..self.custom_snooze.?.calendar.count()) |index| {
                    const cell = self.custom_snooze.?.calendar.cell(index) orelse continue;
                    if (std.mem.eql(u8, &cell.date, &self.custom_snooze.?.calendar.selected)) self.custom_snooze.?.calendar_cursor = index;
                }
            },
            .unit => self.custom_snooze.?.unit = switch (state.unit) {
                .minutes => .hours,
                .hours => .days,
                .days => .minutes,
            },
            .cancel => {
                self.custom_snooze = null;
                self.line_view.reset();
            },
            .submit => {
                _ = self.custom_snooze.?.submit(wallTimeMs());
            },
            else => {
                self.custom_snooze.?.calendar_open = false;
            },
        }
        self.line_view.reset();
        if (self.custom_snooze) |*value| value.error_len = if (self.custom_snooze_focus == .submit) value.error_len else 0;
    }

    fn handleCustomSnooze(self: *View, event: c.SDL_Event, window: *c.SDL_Window) !bool {
        const state = if (self.custom_snooze) |*value| value else return false;
        if (state.pending) return true;
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                if (!self.window_active) return true;
                const key = event.key.key;
                const ctrl = event.key.mod & c.SDL_KMOD_CTRL != 0;
                const shift = event.key.mod & c.SDL_KMOD_SHIFT != 0;
                if (self.line_view.preedit_len != 0) {
                    if (key == c.SDLK_ESCAPE) self.line_view.preedit_len = 0;
                    return true;
                }
                if (key == c.SDLK_ESCAPE) {
                    if (state.calendar_open) state.calendar_open = false else self.custom_snooze = null;
                    self.line_view.reset();
                    return true;
                }
                if (key == c.SDLK_TAB) {
                    const stops: []const usize = if (state.mode == .date) &[_]usize{ 0, 1, 2, 3, 4, 7, 8 } else &[_]usize{ 0, 1, 5, 6, 7, 8 };
                    var at: usize = 0;
                    for (stops, 0..) |target, index| if (target == @intFromEnum(self.custom_snooze_focus)) {
                        at = index;
                        break;
                    };
                    at = if (shift) (at + stops.len - 1) % stops.len else (at + 1) % stops.len;
                    self.custom_snooze_focus = @enumFromInt(stops[at]);
                    state.calendar_open = false;
                    self.line_view.reset();
                    try self.focus(window, true);
                    return true;
                }
                if (state.calendar_open) {
                    switch (key) {
                        c.SDLK_LEFT => state.moveCalendar(-1),
                        c.SDLK_RIGHT => state.moveCalendar(1),
                        c.SDLK_UP => state.moveCalendar(-7),
                        c.SDLK_DOWN => state.moveCalendar(7),
                        c.SDLK_PAGEUP, c.SDLK_PAGEDOWN => {
                            _ = state.calendar.shift(key == c.SDLK_PAGEDOWN);
                            state.calendar_cursor = @min(state.calendar_cursor, state.calendar.count() - 1);
                        },
                        c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_SPACE => {
                            _ = state.chooseDate(state.calendar_cursor);
                        },
                        else => {},
                    }
                    return true;
                }
                if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                    if (self.activeLine() != null) {
                        _ = state.submit(wallTimeMs());
                    } else self.customSnoozeActivate(@intFromEnum(self.custom_snooze_focus));
                    return true;
                }
                if (self.activeLine()) |field| {
                    _ = self.lineKey(field, key, ctrl, shift) catch |err| {
                        state.setError(self.inputErrorNotice(err) orelse "Unable to edit this value.");
                        return true;
                    };
                    state.error_len = 0;
                } else if (key == c.SDLK_SPACE) self.customSnoozeActivate(@intFromEnum(self.custom_snooze_focus));
            },
            c.SDL_EVENT_TEXT_INPUT => if (self.activeLine()) |field| {
                if (self.window_active) self.lineInsert(field, std.mem.span(event.text.text)) catch |err| {
                    state.setError(self.inputErrorNotice(err) orelse "Unable to edit this value.");
                    return true;
                };
                state.error_len = 0;
            },
            c.SDL_EVENT_TEXT_EDITING => if (self.activeLine() != null and self.window_active) {
                try self.line_view.compose(std.mem.span(event.edit.text));
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button != c.SDL_BUTTON_LEFT) return true;
                const x = event.button.x;
                const y = event.button.y;
                if (state.calendar_open) {
                    for (self.custom_snooze_month_bounds, 0..) |rect, index| if (widgets.contains(rect, x, y)) {
                        _ = state.calendar.shift(index == 1);
                        return true;
                    };
                    for (self.custom_snooze_days, 0..) |rect, index| if (rect.w > 0 and widgets.contains(rect, x, y)) {
                        _ = state.chooseDate(index);
                        self.custom_snooze_focus = .date;
                        return true;
                    };
                    if (!widgets.contains(self.custom_snooze_calendar_bounds, x, y)) state.calendar_open = false;
                    return true;
                }
                for (self.custom_snooze_bounds, 0..) |rect, index| if (rect.w > 0 and widgets.contains(rect, x, y)) {
                    const was_field = self.activeLine();
                    const same_focus = @intFromEnum(self.custom_snooze_focus) == index;
                    if (!same_focus or (index != 2 and index != 3 and index != 5)) self.customSnoozeActivate(index);
                    if (self.activeLine()) |field| {
                        if (was_field == field) {
                            const parts = self.lineParts(field);
                            parts.edit.sync(parts.len.*, parts.select.*);
                            parts.edit.set(self.line_view.hit(x, y) orelse parts.len.*, c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0);
                            parts.select.* = false;
                        }
                        try self.focus(window, true);
                    }
                    return true;
                };
            },
            else => {},
        }
        return true;
    }

    pub fn handle(self: *View, event: c.SDL_Event, window: *c.SDL_Window, text: *c.SpicaText) !bool {
        if (self.handleSidebarLifecycle(event)) return true;
        if (self.custom_snooze != null) switch (event.type) {
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING, c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_MOTION, c.SDL_EVENT_MOUSE_WHEEL => return self.handleCustomSnooze(event, window),
            else => {},
        };
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            const undo_mod = event.key.mod & c.SDL_KMOD_CTRL != 0 or event.key.mod & c.SDL_KMOD_GUI != 0;
            if (undo_mod and event.key.key == c.SDLK_Z and self.sidebar_lifecycle.shortcut_claimed) {
                self.claimSidebarUndo();
                return true;
            }
            if (!(undo_mod and event.key.key == c.SDLK_Z)) self.sidebar_lifecycle.shortcut_claimed = false;
        } else if (event.type == c.SDL_EVENT_TEXT_INPUT or event.type == c.SDL_EVENT_TEXT_EDITING) self.sidebar_lifecycle.shortcut_claimed = false;
        switch (event.type) {
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.releasePointer();
                self.line_drag = null;
                self.line_view.preedit_len = 0;
                self.sidebar_resizing = false;
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
                if (event.button.button == c.SDL_BUTTON_RIGHT and self.custom_root == null and self.navigation_enabled and !self.setup_open and !self.workspace_open and !self.workflow_open and !self.scope_open and !self.picker_open and !self.effort_open) {
                    self.sidebar_menu_thread = .{};
                    for (0..self.thread_count) |index| if (widgets.contains(self.threadRowBounds(index), event.button.x, event.button.y)) {
                        self.sidebar_menu_thread = self.threads[index].id;
                        self.sidebar_menu_mode = .main;
                        self.sidebar_menu_x = event.button.x;
                        self.sidebar_menu_y = event.button.y;
                        self.sidebar_menu_hover = 0;
                    };
                    return true;
                }
                if (event.button.button != c.SDL_BUTTON_LEFT) return false;
                if (self.custom_root == null) {
                    const x = event.button.x;
                    const y = event.button.y;
                    var rename_blurred = false;
                    if (self.activeLine() == .rename) {
                        if (widgets.contains(self.sidebar_rename_bounds, x, y)) {
                            const parts = self.lineParts(.rename);
                            parts.edit.sync(parts.len.*, false);
                            parts.edit.set(@min(self.line_view.hit(x, y) orelse parts.len.*, parts.len.*), c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0);
                            parts.select.* = false;
                            self.line_drag = .rename;
                            return true;
                        }
                        self.commitSidebarRename();
                        rename_blurred = if (self.navigation) |action| std.meta.activeTag(action) == .rename else false;
                    }
                    if (self.sidebar_menu_thread.len != 0) {
                        var hit = false;
                        for (self.sidebar_menu_rows[0..self.sidebar_menu_count], 0..) |row, index| {
                            if (widgets.contains(row, x, y)) {
                                self.activateSidebarMenu(index);
                                hit = true;
                                break;
                            }
                        }
                        if (!hit and !widgets.contains(self.sidebar_menu_bounds, x, y)) self.sidebar_menu_thread = .{};
                        if (self.sidebar_rename_thread.len != 0 or self.custom_snooze != null) try self.focus(window, true);
                        return true;
                    }
                    if (widgets.contains(self.sidebar_toggle_bounds, x, y)) {
                        self.sidebar_collapsed = !self.sidebar_collapsed;
                        self.scope_open = false;
                        self.search_focused = false;
                        return true;
                    }
                    if (widgets.contains(self.sidebar_archive_bounds, x, y)) {
                        self.sidebar_archived = !self.sidebar_archived;
                        self.sidebar_archive_request = self.sidebar_archived;
                        self.sidebarChanged();
                        return true;
                    }
                    if (widgets.contains(self.sidebar_undo_bounds, x, y)) {
                        self.claimSidebarUndo();
                        return true;
                    }
                    if (widgets.contains(self.sidebar_resize_bounds, x, y)) {
                        if (event.button.clicks >= 2) {
                            self.sidebar_width_override = null;
                        } else {
                            self.sidebar_resizing = true;
                            _ = c.SDL_CaptureMouse(true);
                        }
                        return true;
                    }
                    for (self.sidebar_shelf_bounds, 0..) |row, index| {
                        if (widgets.contains(row, x, y)) {
                            self.sidebar_shelf_expanded[index] = !self.sidebar_shelf_expanded[index];
                            self.thread_bounds = @splat(zero_rect);
                            return true;
                        }
                    }
                    if (self.activeLine() == .title) {
                        if (widgets.contains(self.title_bounds, x, y)) {
                            const parts = self.lineParts(.title);
                            parts.edit.sync(parts.len.*, false);
                            parts.edit.set(@min(self.line_view.hit(x, y) orelse parts.len.*, parts.len.*), c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0);
                            parts.select.* = false;
                            self.line_drag = .title;
                        } else self.finishTitle(.save);
                        return true;
                    }
                    if (widgets.contains(self.title_bounds, x, y) and self.titleEditAvailable()) {
                        if (rename_blurred) {
                            self.sidebar_rename_followup = .edit_active_title;
                            return true;
                        }
                        self.beginTitleEdit();
                        try self.focus(window, true);
                        return true;
                    }
                    if (widgets.contains(self.workflow_button, x, y) and !self.setup_open and !self.workspace_open) {
                        self.workflow_open = !self.workflow_open;
                        self.workflow_path_focus = false;
                        self.workflow_keyboard = 0;
                        try self.focus(window, true);
                        return true;
                    }
                    if (self.workflow_open) {
                        for (self.workflow_targets.slice(), 0..) |target, i| if (target.enabled and widgets.contains(target.bounds, x, y)) {
                            self.workflow_keyboard = i;
                            try self.workflowActivate(target.id[0..target.id_len]);
                            try self.focus(window, true);
                            break;
                        };
                        return true;
                    }
                    if (self.workspace_open) {
                        if (widgets.contains(self.workspace_close_bounds, x, y)) {
                            self.workspace_open = false;
                            return true;
                        }
                        if (widgets.contains(self.workspace_refresh_bounds, x, y)) {
                            self.workspace_refresh_request = true;
                            return true;
                        }
                        if (self.workspaceFileAt(x, y)) |index| {
                            const same = self.workspace_selected_file == index;
                            self.workspace_selected_file = index;
                            self.workspace_diff_scroll = 0;
                            self.workspace_diff_staged = if (same and self.workspace_files[index].index != ' ' and self.workspace_files[index].worktree != ' ') !self.workspace_diff_staged else self.workspace_files[index].index != ' ' and self.workspace_files[index].worktree == ' ';
                            self.workspace_diff_request = index;
                        }
                        return true;
                    }
                    if (self.setup_open) {
                        if (widgets.contains(self.setup_close_bounds, x, y)) self.setup_open = false;
                        for (self.setup_provider_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.selectSetupProvider(if (index == 0) .codex else .opencode);
                        };
                        if (widgets.contains(self.setup_existing_bounds, x, y)) self.useExistingCodex();
                        if (widgets.contains(self.setup_advanced_bounds, x, y)) self.toggleSetupAdvanced();
                        if (self.setup_runtime == .codex and self.login_url_len != 0 and widgets.contains(self.setup_login_bounds, x, y)) self.setup_action = .open_login;
                        if (self.chooseWorkspaceEnabled() and widgets.contains(self.setup_folder_bounds, x, y)) self.setup_action = .choose_workspace;
                        for (self.setup_field_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.setup_field = index;
                            self.setup_select_all = true;
                        };
                        for (self.setup_button_bounds, 0..) |box, index| if (widgets.contains(box, x, y)) {
                            self.requestSetupAction(index);
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
                        if (self.pickerIndexAt(x, y)) |index| {
                            self.selected = self.models[index].identity;
                            self.selected_model_cache = self.models[index];
                        }
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
                        const was_focused = self.search_focused;
                        if (!was_focused) self.line_view.reset();
                        self.search_focused = true;
                        self.search_select_all = false;
                        self.search_edit.sync(self.search_len, false);
                        self.search_edit.set(if (was_focused) @min(self.line_view.hit(x, y) orelse self.search_len, self.search_len) else self.search_len, c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0);
                        self.line_drag = .search;
                        if (widgets.contains(self.search_clear_bounds, x, y)) {
                            self.search_len = 0;
                            self.sidebarChanged();
                        }
                        try self.focus(window, true);
                        const area = c.SDL_Rect{ .x = @intFromFloat(self.search_bounds.x), .y = @intFromFloat(self.search_bounds.y), .w = @intFromFloat(self.search_bounds.w), .h = @intFromFloat(self.search_bounds.h) };
                        if (!c.SDL_SetTextInputArea(window, &area, 0)) return error.TextInputArea;
                        return true;
                    }
                    if (self.search_more_available and self.navigation_enabled and widgets.contains(self.search_more_bounds, x, y)) {
                        self.navigation = .search_more;
                        return true;
                    }
                    self.search_focused = false;
                    if (widgets.contains(self.scope_bounds, x, y)) {
                        self.openScope();
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
                    if (widgets.contains(self.workspace_toggle_bounds, x, y)) {
                        self.workspace_open = true;
                        self.workspace_refresh_request = true;
                        self.workspace_selected_file = if (self.workspace_file_count == 0) null else self.workspace_selected_file orelse 0;
                        return true;
                    }
                    if (self.navigation_enabled and widgets.contains(self.sidebar_bounds, x, y)) {
                        if (widgets.contains(self.new_project_bounds, x, y)) {
                            if (rename_blurred) self.sidebar_rename_followup = .new_project else self.navigation = .new_project;
                        }
                        if (widgets.contains(self.new_thread_bounds, x, y)) {
                            if (rename_blurred) self.sidebar_rename_followup = .new_thread else self.navigation = .new_thread;
                        }
                        if (widgets.contains(self.sidebar_rows, x, y)) {
                            for (self.sidebar_action_bounds[0..self.thread_count], 0..) |actions, index| {
                                if (widgets.contains(actions[0], x, y)) {
                                    const entry = &self.threads[index];
                                    const action: SidebarAction = if (entry.snoozed_until > wallTimeMs()) .wake else if (entry.settled) .unsettle else .settle;
                                    if (rename_blurred) self.sidebar_rename_followup = .{ .sidebar = .{ .id = entry.id, .action = action } } else self.navigation = .{ .sidebar = .{ .index = index, .action = action } };
                                    return true;
                                }
                                if (widgets.contains(actions[1], x, y)) {
                                    if (!self.threads[index].can_snooze) return true;
                                    self.sidebar_menu_thread = self.threads[index].id;
                                    self.sidebar_menu_mode = .main;
                                    self.sidebar_menu_x = actions[1].x;
                                    self.sidebar_menu_y = actions[1].y + actions[1].h;
                                    self.sidebar_menu_hover = 2;
                                    return true;
                                }
                            }
                            for (0..self.thread_count) |index| if (widgets.contains(self.threadRowBounds(index), x, y)) {
                                if (event.button.clicks >= 2 and !rename_blurred) {
                                    self.beginSidebarRename(index);
                                    try self.focus(window, true);
                                    return true;
                                }
                                if (rename_blurred) self.sidebar_rename_followup = .{ .thread = self.threads[index].id } else self.navigation = .{ .thread = index };
                                if (self.search_len != 0) {
                                    self.search_len = 0;
                                    self.search_select_all = false;
                                    self.sidebarChanged();
                                }
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
                self.line_drag = null;
                if (event.button.button == c.SDL_BUTTON_LEFT and self.sidebar_resizing) {
                    self.sidebar_resizing = false;
                    _ = c.SDL_CaptureMouse(false);
                    return true;
                }
                if (event.button.button != c.SDL_BUTTON_LEFT or (!self.dragging and self.transcript_drag == null)) return false;
                self.releasePointer();
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (self.line_drag) |field| {
                    const parts = self.lineParts(field);
                    parts.edit.set(@min(self.line_view.hit(event.motion.x, event.motion.y) orelse parts.len.*, parts.len.*), true);
                    parts.select.* = false;
                    return true;
                }
                if (self.custom_root == null and self.sidebar_resizing) {
                    if (std.math.isFinite(event.motion.x)) self.sidebar_width_override = std.math.clamp(event.motion.x, Layout.sidebarMinimumWith(self.design), Layout.sidebarMaximumWith(self.design, self.sidebar_window_width));
                    return true;
                }
                if (self.custom_root == null and self.sidebar_menu_thread.len != 0) {
                    for (self.sidebar_menu_rows[0..self.sidebar_menu_count], 0..) |row, index| {
                        if (widgets.contains(row, event.motion.x, event.motion.y)) self.sidebar_menu_hover = index;
                    }
                    return true;
                }
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

                if (self.custom_root == null and self.scope_open) {
                    if (widgets.contains(self.scope_all_bounds, event.motion.x, event.motion.y)) self.scope_hover = 0;
                    for (self.project_bounds[0..self.project_count], 0..) |row, index| {
                        if (widgets.contains(row, event.motion.x, event.motion.y)) self.scope_hover = index + 1;
                    }
                    return true;
                }
                if (self.custom_root == null) {
                    const previous = self.sidebar_hover;
                    self.sidebar_hover = null;
                    for (0..self.thread_count) |index| if (widgets.contains(self.threadRowBounds(index), event.motion.x, event.motion.y)) {
                        self.sidebar_hover = index;
                        if (self.search_len != 0) {
                            for (0..self.visibleThreadCount()) |ordinal| {
                                if (self.searchResult(ordinal) == index) self.search_hover = ordinal;
                            }
                        }
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
                if (self.workflow_open and self.custom_root == null) return true;
                const wheel_direction: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                if (self.custom_root == null and (self.setup_open or self.effort_open)) return true;
                if (self.custom_root == null and self.workspace_open) {
                    if (widgets.contains(self.workspace_bounds, event.wheel.mouse_x, event.wheel.mouse_y)) {
                        const direction: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                        self.workspace_scroll = @max(0, self.workspace_scroll - event.wheel.y * direction * 32);
                        self.workspace_diff_scroll = @max(0, self.workspace_diff_scroll - event.wheel.y * direction * 32);
                    }
                    return true;
                }
                if (self.custom_root == null and self.picker_open) {
                    if (widgets.contains(self.picker_menu, event.wheel.mouse_x, event.wheel.mouse_y)) self.picker_scroll = std.math.clamp(self.picker_scroll - event.wheel.y * wheel_direction * picker_row_height, 0, self.pickerMaxScroll());
                    return true;
                }
                if (self.custom_root == null and widgets.contains(self.sidebar_bounds, event.wheel.mouse_x, event.wheel.mouse_y)) {
                    if (self.scope_open) {
                        const height = @as(f32, @floatFromInt(self.project_count + 1)) * 28;
                        self.scope_scroll = std.math.clamp(self.scope_scroll - event.wheel.y * wheel_direction * 28, 0, @max(0, height - self.scope_menu.h + 8));
                    } else {
                        const height = self.sidebarContentHeight();
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
                if (self.activeLine() != null) {
                    if (self.window_active) try self.line_view.compose(std.mem.span(event.edit.text));
                    return true;
                }
                if (self.custom_root == null and (self.workflow_open or self.setup_open or self.workspace_open or self.scope_open or self.picker_open or self.effort_open or self.sidebar_menu_thread.len != 0)) return true;
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
                if (self.activeLine() == .rename) {
                    if (self.window_active) try self.sidebarRenameInsert(std.mem.span(event.text.text));
                    return true;
                }
                if (self.custom_root == null and self.sidebar_menu_thread.len != 0) return true;
                if (self.workflow_open and self.custom_root == null) {
                    if (self.workflow_path_focus and self.window_active) try self.workflowInsert(std.mem.span(event.text.text));
                    return true;
                }
                if (self.custom_root == null and (self.picker_open or self.effort_open)) return true;
                if (self.setup_open and self.custom_root == null) {
                    try self.setupInsert(std.mem.span(event.text.text));
                    return true;
                }
                if (self.activeLine() == .title) {
                    if (!self.window_active) return false;
                    try self.titleInsert(std.mem.span(event.text.text));
                    return true;
                }
                if ((self.workspace_open or self.scope_open) and self.custom_root == null) return true;
                if (self.activeLine() == .search) {
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
                if (self.activeLine()) |field| {
                    if (!self.window_active) return false;
                    if (self.line_view.preedit_len != 0) {
                        if (key == c.SDLK_ESCAPE) self.line_view.preedit_len = 0;
                        return true;
                    }
                    if (try self.lineKey(field, key, ctrl, shift)) return true;
                    if (field == .rename) {
                        if (key == c.SDLK_ESCAPE) {
                            self.sidebar_rename_thread = .{};
                            self.sidebar_rename_followup = null;
                            self.line_view.reset();
                        }
                        if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) self.commitSidebarRename();
                        return true;
                    }
                }
                if (self.custom_root == null and ctrl and key == c.SDLK_B and !self.setup_open and !self.workspace_open and !self.workflow_open) {
                    self.sidebar_collapsed = !self.sidebar_collapsed;
                    self.sidebar_menu_thread = .{};
                    self.scope_open = false;
                    self.search_focused = false;
                    return true;
                }
                if (self.custom_root == null and self.sidebar_menu_thread.len != 0) {
                    switch (key) {
                        c.SDLK_ESCAPE => {
                            self.sidebar_menu_thread = .{};
                            self.sidebar_menu_mode = .main;
                        },
                        c.SDLK_UP => {
                            self.sidebar_menu_panel.move(false);
                            self.sidebar_menu_hover = self.sidebar_menu_panel.selected orelse self.sidebar_menu_hover;
                        },
                        c.SDLK_DOWN => {
                            self.sidebar_menu_panel.move(true);
                            self.sidebar_menu_hover = self.sidebar_menu_panel.selected orelse self.sidebar_menu_hover;
                        },
                        c.SDLK_HOME, c.SDLK_END => {
                            self.sidebar_menu_panel.edge(key == c.SDLK_END);
                            self.sidebar_menu_hover = self.sidebar_menu_panel.selected orelse self.sidebar_menu_hover;
                        },
                        c.SDLK_LEFT => if (self.sidebar_menu_mode != .main) {
                            const parent_action: SidebarMenu.Action = if (self.sidebar_menu_mode == .copy) .copy else .snooze;
                            self.sidebar_menu_mode = .main;
                            if (self.sidebarMenuIndex()) |index| {
                                const entry = self.threads[index];
                                self.sidebar_menu_panel = SidebarMenu.main(.{ .can_operate = self.navigation_enabled, .pinned = entry.pinned, .settled = entry.settled, .snoozed = entry.snoozed_until > wallTimeMs(), .can_snooze = entry.can_snooze, .filter_active = self.scope_project.eql(entry.project_id.slice()) });
                                self.sidebar_menu_count = self.sidebar_menu_panel.len;
                                for (self.sidebar_menu_panel.slice(), 0..) |item, row| if (item.action == parent_action) {
                                    self.sidebar_menu_hover = row;
                                    _ = self.sidebar_menu_panel.choose(row);
                                    break;
                                };
                            }
                        },
                        c.SDLK_RIGHT => if (self.sidebar_menu_mode == .main and self.sidebar_menu_hover < self.sidebar_menu_panel.len) {
                            const action = self.sidebar_menu_panel.items[self.sidebar_menu_hover].action;
                            if (action == .copy) self.activateSidebarMenu(self.sidebar_menu_hover) else if (action == .snooze and self.threads[self.sidebarMenuIndex() orelse 0].snoozed_until <= wallTimeMs()) self.activateSidebarMenu(self.sidebar_menu_hover);
                        },
                        c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                            self.activateSidebarMenu(self.sidebar_menu_hover);
                            if (self.sidebar_rename_thread.len != 0 or self.custom_snooze != null) try self.focus(window, true);
                        },
                        else => {},
                    }
                    return true;
                }
                if (self.custom_root == null and ((shift and key == c.SDLK_F10) or key == c.SDLK_MENU) and !self.setup_open and !self.workspace_open and !self.workflow_open) {
                    for (self.threads[0..self.thread_count], 0..) |entry, index| {
                        if (!entry.id.eql(self.active_thread.slice())) continue;
                        const row = self.threadRowBounds(index);
                        if (row.h == 0) return true;
                        self.sidebar_menu_thread = entry.id;
                        self.sidebar_menu_mode = .main;
                        self.sidebar_menu_x = row.x + row.w / 2;
                        self.sidebar_menu_y = row.y;
                        self.sidebar_menu_hover = 0;
                        return true;
                    }
                }
                if (key == c.SDLK_F2 and self.titleEditAvailable()) {
                    self.beginTitleEdit();
                    try self.focus(window, true);
                    return true;
                }
                if (self.activeLine() == .title) {
                    if (key == c.SDLK_ESCAPE) {
                        self.finishTitle(.cancel);
                    } else if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) {
                        self.finishTitle(.save);
                    }
                    return true;
                }
                if (key == c.SDLK_F10 and self.custom_root == null and !self.setup_open and !self.workspace_open) {
                    self.workflow_open = !self.workflow_open;
                    self.workflow_path_focus = false;
                    self.workflow_keyboard = 0;
                    self.picker_open = false;
                    self.effort_open = false;
                    self.scope_open = false;
                    self.search_focused = false;
                    try self.focus(window, true);
                    return true;
                }
                if (self.workflow_open and self.custom_root == null) {
                    if (!self.window_active) return false;
                    if (key == c.SDLK_F6 or key == c.SDLK_F7 or key == c.SDLK_F8) {
                        self.request(if (key == c.SDLK_F6) .cancel else if (key == c.SDLK_F7) .allow else .deny);
                        return true;
                    }
                    if (key == c.SDLK_ESCAPE) {
                        self.workflow_open = false;
                        self.workflow_path_focus = false;
                        try self.focus(window, true);
                    } else if (key == c.SDLK_TAB) {
                        self.workflow_path_focus = false;
                        const count = self.workflow_targets.slice().len;
                        if (count != 0) self.workflow_keyboard = (self.workflow_keyboard + (if (shift) count - 1 else 1)) % count;
                    } else if (self.workflow_path_focus) {
                        if (ctrl and key == c.SDLK_A) self.workflow_path_select_all = true;
                        if (ctrl and key == c.SDLK_V) {
                            const value = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                            defer c.SDL_free(value);
                            try self.workflowInsert(std.mem.span(value));
                        }
                        if (key == c.SDLK_BACKSPACE or key == c.SDLK_DELETE) {
                            if (self.workflow_path_select_all) self.workflow_path_len = 0 else if (key == c.SDLK_BACKSPACE and self.workflow_path_len != 0) {
                                self.workflow_path_len -= 1;
                                while (self.workflow_path_len != 0 and self.workflow_path[self.workflow_path_len] & 0xc0 == 0x80) self.workflow_path_len -= 1;
                            }
                            self.workflow_path_select_all = false;
                        }
                        if (key == c.SDLK_RETURN and !self.workflow_busy) self.workflow_action = .add;
                    } else if (key == c.SDLK_RETURN or key == c.SDLK_SPACE) {
                        const targets = self.workflow_targets.slice();
                        if (self.workflow_keyboard < targets.len and targets[self.workflow_keyboard].enabled) try self.workflowActivate(targets[self.workflow_keyboard].id[0..targets[self.workflow_keyboard].id_len]);
                    }
                    return true;
                }
                if (self.setup_open and self.custom_root == null) {
                    const alt = mods & c.SDL_KMOD_ALT != 0;
                    if (key == c.SDLK_ESCAPE) self.setup_open = false;
                    if (alt and key == c.SDLK_1) self.selectSetupProvider(.codex);
                    if (alt and key == c.SDLK_2) self.selectSetupProvider(.opencode);
                    if (alt and key == c.SDLK_A) self.toggleSetupAdvanced();
                    if (ctrl and key == c.SDLK_O and self.chooseWorkspaceEnabled()) self.setup_action = .choose_workspace;
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
                        self.requestSetupAction(0);
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
                            if (self.picker_hover < self.model_count) {
                                self.selected = self.models[self.picker_hover].identity;
                                self.selected_model_cache = self.models[self.picker_hover];
                            }
                            self.picker_open = false;
                        },
                        else => {},
                    }
                    self.revealPickerRow();
                    return true;
                }
                if (self.scope_open and self.custom_root == null) {
                    if (!self.window_active) return false;
                    switch (key) {
                        c.SDLK_ESCAPE => self.scope_open = false,
                        c.SDLK_UP => self.scope_hover -|= 1,
                        c.SDLK_DOWN => self.scope_hover = @min(self.project_count, self.scope_hover + 1),
                        c.SDLK_HOME => self.scope_hover = 0,
                        c.SDLK_END => self.scope_hover = self.project_count,
                        c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                            self.scope_project = if (self.scope_hover == 0) .{} else self.projects[self.scope_hover - 1].id;
                            self.sidebarChanged();
                            self.scope_open = false;
                        },
                        else => {},
                    }
                    const top = @as(f32, @floatFromInt(self.scope_hover)) * 28;
                    if (top < self.scope_scroll) self.scope_scroll = top;
                    if (top + 28 > self.scope_scroll + self.scope_menu.h - 8) self.scope_scroll = @max(0, top + 36 - self.scope_menu.h);
                    return true;
                }
                if (self.workspace_open and self.custom_root == null) {
                    if (key == c.SDLK_ESCAPE) self.workspace_open = false;
                    return true;
                }
                if (self.activeLine() == .search) {
                    if (!self.window_active) return false;
                    if (ctrl and key == c.SDLK_PAGEDOWN and self.search_more_available and self.navigation_enabled) {
                        self.navigation = .search_more;
                        return true;
                    }
                    if (key == c.SDLK_ESCAPE) {
                        self.search_len = 0;
                        self.search_select_all = false;
                        self.search_edit = .{};
                        self.line_view.reset();
                        self.search_focused = false;
                        self.sidebarChanged();
                    }
                    if (key == c.SDLK_UP) self.search_hover -|= 1;
                    if (key == c.SDLK_DOWN) self.search_hover = @min(self.visibleThreadCount() -| 1, self.search_hover + 1);
                    if (key == c.SDLK_UP or key == c.SDLK_DOWN) {
                        const top = @as(f32, @floatFromInt(self.search_hover)) * self.sidebarStride();
                        if (top < self.sidebar_scroll) self.sidebar_scroll = top;
                        if (top + self.sidebarStride() > self.sidebar_scroll + self.sidebar_rows.h) self.sidebar_scroll = @max(0, top + self.sidebarStride() - self.sidebar_rows.h);
                    }
                    if ((key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) and self.navigation_enabled) {
                        if (self.searchResult(self.search_hover)) |index| {
                            self.navigation = .{ .thread = index };
                            self.search_focused = false;
                            self.search_len = 0;
                            self.search_select_all = false;
                            self.sidebarChanged();
                        } else if (self.search_len != 0 and self.search_more_available) {
                            self.navigation = .search_more;
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
        if (self.sidebar_collapsed) return 0;
        var design = self.design;
        if (self.sidebar_width_override) |preferred| design.layout.sidebar_width = preferred;
        return Layout.sidebarWidthWith(design, width);
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

    /// Keep the provider prefix visible at the point where a prompt is sent.
    /// OpenCode can negotiate prefixes such as `opencode-free`; showing only
    /// the model id here makes it too easy to send through the wrong account.
    /// The identity is already bounded, and the fitted label below handles
    /// narrow composer widths without allocating or changing selection state.
    fn modelLabel(identity: *const Identity, buffer: []u8) []const u8 {
        if (identity.runtime_kind.eql("fake")) return "Demo · synthetic";
        const provider = identity.model_provider.slice();
        const model = identity.model_id.slice();
        if (provider.len == 0) return model;
        return std.fmt.bufPrint(buffer, "{s} / {s}", .{ provider, model }) catch model;
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
    const Icon = enum { plus, folder, pen, chevron, send, stop, settings, search, filter, branch, close, sidebar, chevron_up, working, alert, question, clock, pin, check, copy };
    fn icon(renderer: *c.SDL_Renderer, kind: Icon, x: f32, y: f32, color: Color) !void {
        // ComposerPrimaryActions.tsx uses an 8px filled rounded square inside
        // its 12px Stop glyph, centered in the 32px action.
        if (kind == .stop) return widgets.panel(renderer, .{ .x = x + 4, .y = y + 4, .w = 8, .h = 8 }, 1.5, color);
        if (!c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255)) return error.IconDraw;
        const paths: []const [4]f32 = switch (kind) {
            .check => &.{ .{ 3, 8, 6, 11 }, .{ 6, 11, 13, 4 } },
            .copy => &.{ .{ 5, 5, 14, 5 }, .{ 14, 5, 14, 14 }, .{ 14, 14, 5, 14 }, .{ 5, 14, 5, 5 }, .{ 2, 11, 2, 2 }, .{ 2, 2, 11, 2 } },
            .pin => &.{ .{ 5, 1, 12, 1 }, .{ 6, 1, 6, 6 }, .{ 11, 1, 11, 6 }, .{ 6, 6, 3, 9 }, .{ 3, 9, 13, 9 }, .{ 13, 9, 11, 6 }, .{ 8, 9, 8, 15 } },
            .clock => &.{ .{ 5, 1, 11, 1 }, .{ 11, 1, 15, 5 }, .{ 15, 5, 15, 11 }, .{ 15, 11, 11, 15 }, .{ 11, 15, 5, 15 }, .{ 5, 15, 1, 11 }, .{ 1, 11, 1, 5 }, .{ 1, 5, 5, 1 }, .{ 8, 4, 8, 8 }, .{ 8, 8, 11, 10 } },
            .working => &.{ .{ 5, 1, 10, 1 }, .{ 13, 4, 15, 8 }, .{ 13, 12, 10, 15 }, .{ 6, 15, 2, 12 }, .{ 1, 8, 2, 4 } },
            .alert => &.{ .{ 5, 1, 11, 1 }, .{ 11, 1, 15, 5 }, .{ 15, 5, 15, 11 }, .{ 15, 11, 11, 15 }, .{ 11, 15, 5, 15 }, .{ 5, 15, 1, 11 }, .{ 1, 11, 1, 5 }, .{ 1, 5, 5, 1 }, .{ 8, 4, 8, 9 }, .{ 8, 12, 8, 12 } },
            .question => &.{ .{ 3, 4, 5, 2 }, .{ 5, 2, 10, 2 }, .{ 10, 2, 13, 5 }, .{ 13, 5, 13, 7 }, .{ 13, 7, 8, 10 }, .{ 8, 10, 8, 11 }, .{ 8, 14, 8, 14 } },
            .sidebar => &.{ .{ 1, 2, 15, 2 }, .{ 15, 2, 15, 14 }, .{ 15, 14, 1, 14 }, .{ 1, 14, 1, 2 }, .{ 6, 2, 6, 14 } },
            .chevron_up => &.{ .{ 4, 10, 8, 6 }, .{ 8, 6, 12, 10 } },
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
        self.sidebar_now_ms = wallTimeMs();
        self.sidebar_window_width = bounds.header.width;
        const sidebar = self.sidebarWidth(bounds.header.width);
        const height = bounds.composer.y + bounds.composer.height + metrics.gutter;
        const inset = @min(metrics.gutter, 20);
        const radius = @min(metrics.radius, 8);
        self.sidebar_bounds = .{ .x = 0, .y = 0, .w = sidebar, .h = height };
        self.sidebar_toggle_bounds = .{ .x = sidebar + 8, .y = 12, .w = 28, .h = 28 };
        self.sidebar_resize_bounds = if (self.sidebar_collapsed) zero_rect else .{ .x = sidebar - 3, .y = 0, .w = 6, .h = height };
        _ = self.navigation_targets.add("sidebar.toggle", "button", self.sidebar_toggle_bounds, true) catch {};
        _ = self.navigation_targets.add("sidebar.resize", "separator", self.sidebar_resize_bounds, !self.sidebar_collapsed) catch {};
        self.new_thread_bounds = zero_rect;
        self.new_project_bounds = zero_rect;
        self.search_bounds = zero_rect;
        self.scope_bounds = zero_rect;
        self.setup_bounds = zero_rect;
        self.search_more_bounds = zero_rect;
        self.sidebar_rows = zero_rect;
        self.thread_bounds = @splat(zero_rect);
        self.project_bounds = @splat(zero_rect);
        self.sidebar_shelf_bounds = @splat(zero_rect);
        self.sidebar_action_bounds = @splat(@splat(zero_rect));
        if (!self.sidebar_collapsed) {
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
            if (!self.search_focused or self.search_len == 0) try self.labels.drawFitted(renderer, text, search_label, 40, row_top + 8, self.search_bounds.w - 32 - (if (self.search_len == 0) @as(f32, 0) else 22), 14, if (self.search_len == 0) sidebar_muted else foreground);
            if (self.search_focused and self.search_bounds.w > 40 and self.activeLine() == .search) {
                self.search_edit.sync(self.search_len, self.search_select_all);
                try self.line_view.draw(renderer, text, self.search_query[0..self.search_len], self.search_edit, .{ .x = 40, .y = row_top + 8, .w = @max(0, self.search_bounds.w - 54), .h = 20 }, foreground, palette.selection, self.window_active);
            }
            if (self.search_len != 0) try icon(renderer, .close, self.search_clear_bounds.x + 3, row_top + 8, sidebar_muted);
            if (self.scope_project.len != 0) try widgets.panel(renderer, self.scope_bounds, 6, palette.sidebar_active);
            try icon(renderer, .filter, self.scope_bounds.x + 6, action_y + 6, sidebar_muted);
            try icon(renderer, .folder, self.new_project_bounds.x + 6, action_y + 5, sidebar_muted);
            try icon(renderer, .plus, self.new_project_bounds.x + 8, action_y + 7, sidebar_muted);
            try icon(renderer, .pen, self.new_thread_bounds.x + 6, action_y + 6, sidebar_muted);
            const more_height: f32 = if (self.search_more_available) 24 else 0;
            self.search_more_bounds = if (more_height != 0) .{ .x = 8, .y = row_top + 36, .w = sidebar - 16, .h = more_height } else zero_rect;
            if (more_height != 0) try self.labels.drawFitted(renderer, text, if (self.search_len != 0) "More matches · Ctrl+PgDn" else "More threads", 18, row_top + 40, sidebar - 36, 12, sidebar_muted);
            self.sidebar_rows = .{ .x = 8, .y = row_top + 40 + more_height, .w = sidebar - 16, .h = @max(0, height - row_top - 84 - more_height) };
            const rows_height = self.sidebarContentHeight();
            self.sidebar_scroll = std.math.clamp(self.sidebar_scroll, 0, @max(0, rows_height - self.sidebar_rows.h));
            self.project_bounds = @splat(zero_rect);
            self.thread_bounds = @splat(zero_rect);
            var clip = widgets.Clip.push(renderer, self.sidebar_rows);
            defer clip.restore(renderer);
            try self.drawThreads(renderer, text, foreground, sidebar_muted);
            if (self.visibleThreadCount() == 0) try self.labels.drawFitted(renderer, text, if (self.search_len != 0 and self.thread_search_busy) "Searching older threads…" else if (self.search_len != 0 and self.search_more_available) "No match here · Enter searches older threads" else if (self.search_len != 0) "No threads found" else "No threads in this project", 18, self.sidebar_rows.y + 12, sidebar - 36, 12, sidebar_muted);
            clip.restore(renderer);
            // Make the actual connection entry point legible. A settings glyph
            // alone left first-time users guessing where provider setup lived;
            // the whole status row is now one painted, clickable target.
            self.setup_bounds = .{ .x = 8, .y = height - 36, .w = @max(0, sidebar - 120), .h = 32 };
            self.sidebar_archive_bounds = .{ .x = @max(8, sidebar - 112), .y = height - 36, .w = 96, .h = 32 };
            if (self.setup_open) try widgets.panel(renderer, self.setup_bounds, 6, palette.sidebar_active);
            try icon(renderer, .settings, 16, height - 28, sidebar_muted);
            try self.labels.draw(text, "Connection", 40, height - 29, 12, foreground);
            try self.labels.drawFitted(renderer, text, self.status, 40, height - 16, sidebar - 56, 10, sidebar_muted);
            _ = self.navigation_targets.add("sidebar.archived.toggle", "button", self.sidebar_archive_bounds, true) catch {};
            try self.labels.drawFitted(renderer, text, if (self.sidebar_archived) "Active threads" else "Archived", self.sidebar_archive_bounds.x + 8, height - 28, self.sidebar_archive_bounds.w - 8, 11, sidebar_muted);
            if (self.scope_open) try self.drawScope(renderer, text, foreground, sidebar_muted);
        }
        try icon(renderer, .sidebar, self.sidebar_toggle_bounds.x + 6, self.sidebar_toggle_bounds.y + 6, muted);
        const header_x = sidebar + metrics.gutter + 32;
        var project_name: []const u8 = "Workspace";
        var thread_name: []const u8 = "New chat";
        for (self.projects[0..self.project_count]) |*entry| if (entry.id.eql(self.active_project.slice())) {
            project_name = entry.label[0..entry.len];
        };
        for (self.threads[0..self.thread_count]) |*entry| if (entry.id.eql(self.active_thread.slice())) {
            thread_name = entry.label[0..entry.len];
            if (entry.project_name.len != 0) project_name = entry.project_name.slice();
        };
        if (std.mem.eql(u8, thread_name, "New chat") and self.active_thread_title_len != 0) thread_name = self.active_thread_title[0..self.active_thread_title_len];
        const project_width = @min(@max(0, bounds.header.width - header_x - metrics.gutter) * 0.3, try self.labels.width(text, @import("../text/utf8.zig").prefix(project_name, 128), 14));
        try icon(renderer, .folder, header_x, (bounds.header.height - 16) / 2, muted);
        try self.labels.drawFitted(renderer, text, project_name, header_x + 24, (bounds.header.height - 16) / 2, project_width, 14, muted);
        try self.labels.draw(text, "/", header_x + 34 + project_width, (bounds.header.height - 16) / 2, 14, muted);
        const title_x = header_x + 52 + project_width;
        self.workspace_toggle_bounds = if (bounds.header.width - title_x >= 132)
            .{ .x = bounds.header.width - metrics.gutter - 104, .y = 10, .w = 104, .h = 28 }
        else
            .{ .x = 8, .y = height - 72, .w = 104, .h = 28 };
        const title_end = if (self.workspace_toggle_bounds.y == 10) self.workspace_toggle_bounds.x - 8 else bounds.header.width - metrics.gutter;
        self.title_bounds = .{ .x = title_x, .y = 6, .w = @max(0, title_end - title_x), .h = @max(0, bounds.header.height - 12) };
        _ = self.navigation_targets.add("thread.title.edit", "textbox", self.title_bounds, self.titleEditAvailable()) catch {};
        if (self.title_editing) {
            try widgets.panel(renderer, self.title_bounds, 4, palette.surface);
            self.title_line_edit.sync(self.title_len, self.title_select_all);
            try self.line_view.draw(renderer, text, self.title_buffer[0..self.title_len], self.title_line_edit, .{ .x = title_x + 6, .y = (bounds.header.height - 16) / 2, .w = @max(0, self.title_bounds.w - 12), .h = 20 }, foreground, palette.selection, self.window_active and self.activeLine() == .title);
        } else try self.labels.drawFitted(renderer, text, thread_name, title_x, (bounds.header.height - 16) / 2, self.title_bounds.w, 14, foreground);
        if (self.workspace_toggle_bounds.w != 0) {
            try widgets.panel(renderer, self.workspace_toggle_bounds, @min(metrics.radius, 5), if (self.workspace_open) palette.sidebar_active else palette.surface);
            try icon(renderer, .branch, self.workspace_toggle_bounds.x + 7, self.workspace_toggle_bounds.y + 6, muted);
            try self.labels.drawFitted(renderer, text, "Changes", self.workspace_toggle_bounds.x + 28, self.workspace_toggle_bounds.y + 7, self.workspace_toggle_bounds.w - 34, 12, muted);
        }
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
        if (self.scope_hover == 0) try widgets.panel(renderer, self.scope_all_bounds, 4, self.design.colors.sidebar_hover);
        if (self.scope_project.len == 0) try widgets.panel(renderer, self.scope_all_bounds, 4, self.design.colors.sidebar_active);
        try self.labels.drawFitted(renderer, text, "All projects", 20, y + 7, self.scope_menu.w - 24, 12, foreground);
        y += 28;
        for (self.projects[0..self.project_count], 0..) |*entry, index| {
            self.project_bounds[index] = clippedRect(.{ .x = 12, .y = y, .w = self.scope_menu.w - 8, .h = 28 }, self.scope_menu);
            if (self.scope_hover == index + 1) try widgets.panel(renderer, self.project_bounds[index], 4, self.design.colors.sidebar_hover);
            if (self.scope_project.eql(entry.id.slice())) try widgets.panel(renderer, self.project_bounds[index], 4, self.design.colors.sidebar_active);
            try self.labels.drawFitted(renderer, text, entry.label[0..entry.len], 20, y + 7, self.scope_menu.w - 24, 12, muted);
            y += 28;
        }
    }

    fn drawThreads(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, foreground: Color, muted: Color) !void {
        var y = self.sidebar_rows.y - self.sidebar_scroll;
        var ordinal: usize = 0;
        const searching = self.search_len != 0;
        var ordered: [32]usize = undefined;
        var count: usize = 0;
        var section_counts: [5]usize = @splat(0);
        for (self.threads[0..self.thread_count], 0..) |*entry, index| {
            if (!self.threadMatches(entry)) continue;
            section_counts[@intFromEnum(self.sidebarSection(entry))] += 1;
            ordered[count] = index;
            count += 1;
        }
        if (!searching) {
            // Fixed-capacity insertion sort retains original indices for commands.
            for (1..@max(1, count)) |at| {
                var cursor = at;
                while (cursor > 0) : (cursor -= 1) {
                    const left = &self.threads[ordered[cursor - 1]];
                    const right = &self.threads[ordered[cursor]];
                    const ls = @intFromEnum(self.sidebarSection(left));
                    const rs = @intFromEnum(self.sidebarSection(right));
                    if (ls < rs or (ls == rs and left.sort_order <= right.sort_order)) break;
                    std.mem.swap(usize, &ordered[cursor - 1], &ordered[cursor]);
                }
            }
        }
        var section_cursor: usize = 0;
        const shelf_gap = if (searching) @as(f32, 0) else @max(0, self.sidebar_rows.h - self.sidebarContentHeight());
        var shelf_started = false;
        for (ordered[0..count]) |index| {
            const entry = &self.threads[index];
            const section = @intFromEnum(self.sidebarSection(entry));
            if (!searching and section >= 2) {
                while (section_cursor <= section) : (section_cursor += 1) {
                    if (section_cursor < 2 or (section_cursor < 4 and section_counts[section_cursor] == 0)) continue;
                    if (!shelf_started) {
                        y += shelf_gap;
                        shelf_started = true;
                    }
                    try self.drawSidebarShelf(renderer, text, section_cursor - 2, section_counts[section_cursor], y, muted);
                    y += 33;
                }
            }
            if (!self.sidebarShelfVisible(entry)) continue;
            const slim = self.sidebarSlim(entry);
            const row = c.SDL_FRect{ .x = self.sidebar_rows.x, .y = y + (if (slim) @as(f32, 0) else 2), .w = self.sidebar_rows.w, .h = if (slim) 36 else 78 };
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
                if (slim) {
                    try icon(renderer, .folder, x, row.y + 10, muted);
                    const hovered = !searching and self.sidebar_hover == index and self.navigation_enabled;
                    try self.drawSidebarTitle(renderer, text, entry, x + 26, row.y + 10, @max(0, (if (hovered) sidebarActionStart(entry, row, true) - 8 else x + width) - x - 26), foreground);
                    if (hovered) try self.drawSidebarRowActions(renderer, text, index, row, true, foreground);
                    ordinal += 1;
                    y += sidebar_search_stride;
                    continue;
                }
                const hovered = self.sidebar_hover == index and self.navigation_enabled;
                if (entry.project_name.len != 0) {
                    try icon(renderer, .folder, x, row.y + 9, muted);
                    if (entry.pinned) try icon(renderer, .pin, x + 20, row.y + 9, muted);
                    const project_inset: f32 = if (entry.pinned) 40 else 22;
                    const project_end = if (hovered) sidebarActionStart(entry, row, false) - 8 else row.x + row.w - 10 - (if (entry.run_status == .idle) @as(f32, 36) else 84);
                    try self.labels.drawFitted(renderer, text, entry.project_name.slice(), x + project_inset, row.y + 10, @max(0, project_end - x - project_inset), 12, muted);
                }
                if (!hovered and entry.run_status == .idle and entry.updated_at_ms > 0) {
                    var time_buffer: [32]u8 = undefined;
                    const elapsed = @max(0, self.sidebar_now_ms - entry.updated_at_ms);
                    const time_label = if (elapsed < 60_000) "now" else if (elapsed < 3_600_000) try std.fmt.bufPrint(&time_buffer, "{d}m", .{@divFloor(elapsed, 60_000)}) else if (elapsed < 86_400_000) try std.fmt.bufPrint(&time_buffer, "{d}h", .{@divFloor(elapsed, 3_600_000)}) else try std.fmt.bufPrint(&time_buffer, "{d}d", .{@divFloor(elapsed, 86_400_000)});
                    const time_width = try self.labels.width(text, time_label, 12);
                    try self.labels.draw(text, time_label, row.x + row.w - 10 - time_width, row.y + 10, 12, muted);
                }
                if (!hovered and entry.run_status != .idle) {
                    const status_label: []const u8 = switch (entry.run_status) {
                        .running => "Working",
                        .question => "Input",
                        .approval => "Approval",
                        .failed => "Failed",
                        .interrupted => "Interrupted",
                        .unknown => "Unknown",
                        .idle => unreachable,
                    };
                    const status_color = if (entry.run_status == .failed) self.design.colors.danger else if (entry.run_status == .question or entry.run_status == .approval) self.design.colors.foreground else muted;
                    try icon(renderer, if (entry.run_status == .running) .working else if (entry.run_status == .failed) .alert else .question, row.x + row.w - 92, row.y + 8, status_color);
                    try self.labels.drawFitted(renderer, text, status_label, row.x + row.w - 72, row.y + 10, 62, 11, status_color);
                }
                if (hovered) try self.drawSidebarRowActions(renderer, text, index, row, false, foreground);
                try self.drawSidebarTitle(renderer, text, entry, x, row.y + 32, width, foreground);
                if (entry.runtime_kind.len != 0) {
                    const provider = if (entry.runtime_kind.eql("codex")) "Codex" else if (entry.runtime_kind.eql("opencode")) "OpenCode" else entry.runtime_kind.slice();
                    const provider_label = @import("../text/utf8.zig").prefix(provider, @import("label_cache.zig").max_bytes);
                    const provider_width = try self.labels.width(text, provider_label, 10);
                    try self.labels.draw(text, provider_label, row.x + row.w - 10 - provider_width, row.y + 58, 10, muted);
                }
                const metadata = if (entry.branch.len != 0) entry.branch.slice() else entry.workspace_name.slice();
                if (metadata.len != 0) {
                    try icon(renderer, if (entry.branch.len != 0) .branch else .folder, x, row.y + 54, muted);
                    try self.labels.drawFitted(renderer, text, metadata, x + 20, row.y + 56, @max(0, width - 84), 12, muted);
                }
            }
            ordinal += 1;
            y += if (slim) sidebar_search_stride else sidebar_card_stride;
        }
        if (!searching and count != 0) {
            while (section_cursor <= 4) : (section_cursor += 1) {
                if (section_cursor < 2 or (section_cursor < 4 and section_counts[section_cursor] == 0)) continue;
                if (!shelf_started) {
                    y += shelf_gap;
                    shelf_started = true;
                }
                try self.drawSidebarShelf(renderer, text, section_cursor - 2, section_counts[section_cursor], y, muted);
                y += 33;
            }
        }
    }

    fn sidebarActionStart(entry: *const Entry, row: c.SDL_FRect, slim: bool) f32 {
        const action_width: f32 = if (entry.settled) 68 else 54;
        return row.x + row.w - action_width - 6 - (if (slim or !entry.can_snooze) @as(f32, 0) else 24);
    }

    fn drawSidebarRowActions(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, index: usize, row: c.SDL_FRect, slim: bool, color: Color) !void {
        const entry = &self.threads[index];
        const wake = entry.snoozed_until > self.sidebar_now_ms;
        const label: []const u8 = if (wake) "Wake" else if (entry.settled) "Unsettle" else "Settle";
        const action_width: f32 = if (entry.settled) 68 else 54;
        const top = row.y + (if (slim) @as(f32, 6) else 8);
        self.sidebar_action_bounds[index][0] = clippedRect(.{ .x = row.x + row.w - action_width - 6, .y = top, .w = action_width, .h = 22 }, self.sidebar_rows);
        const action = self.sidebar_action_bounds[index][0];
        try self.labels.draw(text, label, action.x + 4, top + 4, 11, color);
        var id: [96]u8 = undefined;
        _ = self.navigation_targets.add(try std.fmt.bufPrint(&id, "sidebar.thread.{d}.settle", .{index}), "button", action, action.h > 0) catch {};
        if (!slim and entry.can_snooze) {
            self.sidebar_action_bounds[index][1] = clippedRect(.{ .x = action.x - 24, .y = top, .w = 24, .h = 22 }, self.sidebar_rows);
            const snooze = self.sidebar_action_bounds[index][1];
            try icon(renderer, .clock, snooze.x + 4, top + 3, if (entry.can_snooze) color else self.design.colors.muted);
            _ = self.navigation_targets.add(try std.fmt.bufPrint(&id, "sidebar.thread.{d}.snooze", .{index}), "button", snooze, snooze.h > 0 and entry.can_snooze) catch {};
        }
    }

    fn drawSidebarShelf(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, index: usize, count: usize, y: f32, muted: Color) !void {
        const row = c.SDL_FRect{ .x = self.sidebar_rows.x + 2, .y = y, .w = @max(0, self.sidebar_rows.w - 4), .h = 32 };
        self.sidebar_shelf_bounds[index] = clippedRect(row, self.sidebar_rows);
        const names = [_][]const u8{ "Working", "Snoozed", "Settled" };
        const ids = [_][]const u8{ "sidebar.shelf.working", "sidebar.shelf.snoozed", "sidebar.shelf.settled" };
        _ = self.navigation_targets.add(ids[index], "button", self.sidebar_shelf_bounds[index], self.sidebar_shelf_bounds[index].h > 0) catch {};
        var buffer: [48]u8 = undefined;
        const label = if (self.sidebar_shelf_expanded[index]) names[index] else try std.fmt.bufPrint(&buffer, "{s} ({d})", .{ names[index], count });
        try self.labels.draw(text, label, row.x + 8, y + 9, 12, muted);
        const label_width = try self.labels.width(text, label, 12);
        try widgets.panel(renderer, .{ .x = row.x + label_width + 16, .y = y + 16, .w = @max(0, row.w - label_width - 44), .h = 1 }, 0, self.design.colors.sidebar_border);
        try icon(renderer, if (self.sidebar_shelf_expanded[index]) .chevron else .chevron_up, row.x + row.w - 20, y + 8, muted);
    }

    fn drawSidebarMenu(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, width: f32, height: f32) !void {
        const index = self.sidebarMenuIndex() orelse {
            self.sidebar_menu_thread = .{};
            return;
        };
        const entry = self.threads[index];
        const snoozed = entry.snoozed_until > wallTimeMs();
        if (self.sidebar_menu_mode == .main) {
            self.sidebar_menu_panel = SidebarMenu.main(.{ .can_operate = self.navigation_enabled, .pinned = entry.pinned, .settled = entry.settled, .snoozed = snoozed, .can_snooze = entry.can_snooze, .filter_active = self.scope_project.eql(entry.project_id.slice()), .archived = entry.archived, .can_archive = entry.can_archive, .can_delete = entry.can_delete });
        } else if (self.sidebar_menu_mode == .copy) {
            self.sidebar_menu_panel = SidebarMenu.copy(entry.workspace_path_len != 0, entry.branch.len != 0);
        }
        if (self.sidebar_menu_hover < self.sidebar_menu_panel.len and self.sidebar_menu_panel.items[self.sidebar_menu_hover].enabled) _ = self.sidebar_menu_panel.choose(self.sidebar_menu_hover);
        self.sidebar_menu_count = self.sidebar_menu_panel.len;
        const menu_width = @min(260, width - 16);
        const menu_height = self.sidebar_menu_panel.height();
        self.sidebar_menu_bounds = .{ .x = std.math.clamp(self.sidebar_menu_x, 8, @max(8, width - menu_width - 8)), .y = std.math.clamp(self.sidebar_menu_y, 8, @max(8, height - menu_height - 8)), .w = menu_width, .h = menu_height };
        try widgets.panel(renderer, self.sidebar_menu_bounds, 8, self.design.colors.border);
        try widgets.panel(renderer, .{ .x = self.sidebar_menu_bounds.x + 1, .y = self.sidebar_menu_bounds.y + 1, .w = menu_width - 2, .h = menu_height - 2 }, 7, self.design.colors.raised);
        for (0..self.sidebar_menu_count) |row_index| {
            const item = self.sidebar_menu_panel.items[row_index];
            var label_buffer: [64]u8 = undefined;
            const label = if (self.sidebar_menu_mode == .snooze and item.action == .preset and self.sidebar_snooze_deadlines[item.preset_index] != 0)
                std.fmt.bufPrint(&label_buffer, "{s} ({s})", .{ item.label, self.sidebar_snooze_when[item.preset_index].slice() }) catch item.label
            else
                item.label;
            const row = c.SDL_FRect{ .x = self.sidebar_menu_bounds.x + 4, .y = self.sidebar_menu_bounds.y + self.sidebar_menu_panel.rowTop(row_index), .w = menu_width - 8, .h = 28 };
            self.sidebar_menu_rows[row_index] = row;
            if (item.separator_before and row_index != 0) try widgets.panel(renderer, .{ .x = row.x, .y = row.y - 5, .w = row.w, .h = 1 }, 0, self.design.colors.border);
            _ = self.navigation_targets.add(item.id, "menuitem", row, item.enabled) catch {};
            if (row_index == self.sidebar_menu_hover and item.enabled) try widgets.panel(renderer, row, 4, self.design.colors.sidebar_active);
            const color = if (item.enabled) self.design.colors.foreground else self.design.colors.muted;
            const glyph: ?Icon = switch (item.action) {
                .pin, .unpin => .pin,
                .settle, .unsettle => .check,
                .wake, .snooze => .clock,
                .rename => .pen,
                .filter => .folder,
                .copy, .copy_id => .copy,
                .copy_path => .folder,
                .copy_branch => .branch,
                else => null,
            };
            if (glyph) |value| try icon(renderer, value, row.x + 7, row.y + 6, color);
            const has_children = item.action == .copy or item.action == .snooze;
            try self.labels.drawFitted(renderer, text, label, row.x + (if (glyph != null) @as(f32, 30) else 8), row.y + 7, row.w - (if (glyph != null) @as(f32, 38) else 16) - (if (has_children) @as(f32, 18) else 0), 12, color);
            if (has_children) {
                const right = row.x + row.w - 12;
                if (!c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255) or !c.SDL_RenderLine(renderer, right - 3, row.y + 10, right + 1, row.y + 14) or !c.SDL_RenderLine(renderer, right + 1, row.y + 14, right - 3, row.y + 18)) return error.IconDraw;
            }
        }
    }

    fn drawCustomSnooze(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, width: f32, height: f32) !void {
        const state = if (self.custom_snooze) |*value| value else return;
        self.navigation_targets.clear();
        self.custom_snooze_bounds = @splat(zero_rect);
        self.custom_snooze_days = @splat(zero_rect);
        self.custom_snooze_month_bounds = @splat(zero_rect);
        self.custom_snooze_calendar_bounds = zero_rect;
        const palette = self.design.colors;
        const w = @min(384, @max(0, width - 24));
        const h: f32 = @min(350, @max(0, height - 24));
        const panel = c.SDL_FRect{ .x = (width - w) / 2, .y = (height - h) / 2, .w = w, .h = h };
        if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND) or !c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 160) or !c.SDL_RenderFillRect(renderer, null)) return error.ModalDraw;
        try widgets.panel(renderer, panel, 10, palette.border);
        try widgets.panel(renderer, .{ .x = panel.x + 1, .y = panel.y + 1, .w = w - 2, .h = h - 2 }, 9, palette.raised);
        _ = self.navigation_targets.add("sidebar.custom_snooze", "dialog", panel, true) catch {};
        try self.labels.draw(text, "Custom snooze", panel.x + 20, panel.y + 20, 16, palette.foreground);
        try self.labels.drawFitted(renderer, text, "Choose when snoozed threads return to your inbox.", panel.x + 20, panel.y + 48, w - 40, 12, palette.muted);
        const half = (w - 48) / 2;
        self.custom_snooze_bounds[0] = .{ .x = panel.x + 20, .y = panel.y + 80, .w = half, .h = 32 };
        self.custom_snooze_bounds[1] = .{ .x = panel.x + 28 + half, .y = panel.y + 80, .w = half, .h = 32 };
        if (state.mode == .date) {
            self.custom_snooze_bounds[2] = .{ .x = panel.x + 20, .y = panel.y + 148, .w = half - 30, .h = 32 };
            self.custom_snooze_bounds[4] = .{ .x = panel.x + 20 + half - 28, .y = panel.y + 148, .w = 28, .h = 32 };
            self.custom_snooze_bounds[3] = .{ .x = panel.x + 28 + half, .y = panel.y + 148, .w = half, .h = 32 };
            try self.labels.draw(text, "Date", panel.x + 20, panel.y + 128, 12, palette.muted);
            try self.labels.draw(text, "Time", panel.x + 28 + half, panel.y + 128, 12, palette.muted);
        } else {
            self.custom_snooze_bounds[5] = .{ .x = panel.x + 20, .y = panel.y + 148, .w = half, .h = 32 };
            self.custom_snooze_bounds[6] = .{ .x = panel.x + 28 + half, .y = panel.y + 148, .w = half, .h = 32 };
            try self.labels.draw(text, "Snooze for", panel.x + 20, panel.y + 128, 12, palette.muted);
            try self.labels.draw(text, "Unit", panel.x + 28 + half, panel.y + 128, 12, palette.muted);
        }
        self.custom_snooze_bounds[7] = .{ .x = panel.x + w - 184, .y = panel.y + h - 52, .w = 76, .h = 32 };
        self.custom_snooze_bounds[8] = .{ .x = panel.x + w - 100, .y = panel.y + h - 52, .w = 80, .h = 32 };
        const ids = [_][]const u8{ "sidebar.custom_snooze.mode.date", "sidebar.custom_snooze.mode.duration", "sidebar.custom_snooze.date", "sidebar.custom_snooze.time", "sidebar.custom_snooze.calendar", "sidebar.custom_snooze.amount", "sidebar.custom_snooze.unit", "sidebar.custom_snooze.cancel", "sidebar.custom_snooze.submit" };
        const unit_label: []const u8 = switch (state.unit) {
            .minutes => "Minutes",
            .hours => "Hours",
            .days => "Days",
        };
        const labels = [_][]const u8{ "Date and time", "Duration", state.date.slice(), state.time.slice(), "▦", state.amount.slice(), unit_label, "Cancel", if (state.pending) "Snoozing…" else "Snooze" };
        for (self.custom_snooze_bounds, 0..) |rect, index| {
            if (rect.w <= 0) continue;
            const field: ?LineField = switch (index) {
                2 => .snooze_date,
                3 => .snooze_time,
                5 => .snooze_amount,
                else => null,
            };
            const focused = @intFromEnum(self.custom_snooze_focus) == index;
            const selected_mode = (index == 0 and state.mode == .date) or (index == 1 and state.mode == .duration);
            try widgets.panel(renderer, rect, 5, if (focused or selected_mode) palette.selection else palette.surface);
            _ = self.navigation_targets.add(ids[index], if (field != null) "textbox" else "button", rect, !state.pending) catch {};
            if (field != null and self.activeLine() == field) {
                const parts = self.lineParts(field.?);
                parts.edit.sync(parts.len.*, parts.select.*);
                try self.line_view.draw(renderer, text, parts.buffer[0..parts.len.*], parts.edit.*, .{ .x = rect.x + 7, .y = rect.y + 7, .w = rect.w - 14, .h = 20 }, palette.foreground, palette.selection, self.window_active);
            } else try self.labels.drawFitted(renderer, text, labels[index], rect.x + 8, rect.y + 9, rect.w - 16, 12, if (state.pending) palette.muted else palette.foreground);
        }
        if (state.error_len != 0) try self.labels.drawFitted(renderer, text, state.error_bytes[0..state.error_len], panel.x + 20, panel.y + 200, w - 40, 12, palette.danger);
        if (state.calendar_open) {
            self.navigation_targets.clear();
            // Keep the six-week grid inside the viewport even on short windows.
            const cw = @min(280, width - 16);
            const ch: f32 = 256;
            const cx = std.math.clamp(panel.x + 20, 8, @max(8, width - cw - 8));
            const cy = std.math.clamp(panel.y + 184, 8, @max(8, height - ch - 8));
            const popup = c.SDL_FRect{ .x = cx, .y = cy, .w = cw, .h = ch };
            self.custom_snooze_calendar_bounds = popup;
            try widgets.panel(renderer, popup, 6, palette.border);
            try widgets.panel(renderer, .{ .x = cx + 1, .y = cy + 1, .w = cw - 2, .h = ch - 2 }, 5, palette.raised);
            var month: [32]u8 = undefined;
            try self.labels.draw(text, try std.fmt.bufPrint(&month, "{d:0>4}-{d:0>2}", .{ @as(u32, state.calendar.year), @as(u32, state.calendar.month) }), cx + 78, cy + 12, 14, palette.foreground);
            for (0..2) |index| {
                const rect = c.SDL_FRect{ .x = cx + (if (index == 0) @as(f32, 8) else cw - 36), .y = cy + 6, .w = 28, .h = 28 };
                self.custom_snooze_month_bounds[index] = rect;
                _ = self.navigation_targets.add(if (index == 0) "sidebar.custom_snooze.calendar.previous" else "sidebar.custom_snooze.calendar.next", "button", rect, !state.pending) catch {};
                try self.labels.draw(text, if (index == 0) "‹" else "›", rect.x + 8, rect.y + 4, 18, palette.foreground);
            }
            const day_width = (cw - 16) / 7;
            for ([_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }, 0..) |name, index| try self.labels.draw(text, name, cx + 13 + @as(f32, @floatFromInt(index)) * day_width, cy + 40, 11, palette.muted);
            for (0..state.calendar.count()) |index| {
                const cell = state.calendar.cell(index) orelse continue;
                const rect = c.SDL_FRect{ .x = cx + 8 + @as(f32, @floatFromInt(index % 7)) * day_width, .y = cy + 62 + @as(f32, @floatFromInt(index / 7)) * 30, .w = day_width, .h = 28 };
                self.custom_snooze_days[index] = rect;
                var id: [80]u8 = undefined;
                _ = self.navigation_targets.add(try std.fmt.bufPrint(&id, "sidebar.custom_snooze.calendar.day.{d}", .{index}), "button", rect, !cell.disabled and !state.pending) catch {};
                if (std.mem.eql(u8, &cell.date, &state.calendar.selected)) try widgets.panel(renderer, rect, 4, palette.selection);
                if (index == state.calendar_cursor) try widgets.panel(renderer, .{ .x = rect.x + 2, .y = rect.y + rect.h - 2, .w = rect.w - 4, .h = 1 }, 0, palette.foreground);
                var day: [4]u8 = undefined;
                try self.labels.draw(text, try std.fmt.bufPrint(&day, "{d}", .{@as(u32, cell.day)}), rect.x + 8, rect.y + 7, 12, if (cell.disabled or !cell.current_month) palette.muted else palette.foreground);
            }
        }
    }

    fn drawSidebarLifecycle(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, width: f32, height: f32) !void {
        const id = self.sidebar_lifecycle.confirming orelse return;
        _ = id;
        self.navigation_targets.clear();
        const palette = self.design.colors;
        const w: f32 = @min(360, width - 24);
        const h: f32 = 170;
        const panel = c.SDL_FRect{ .x = (width - w) / 2, .y = (height - h) / 2, .w = w, .h = h };
        if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND) or !c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 160) or !c.SDL_RenderFillRect(renderer, null)) return error.ModalDraw;
        try widgets.panel(renderer, panel, 10, palette.border);
        try widgets.panel(renderer, .{ .x = panel.x + 1, .y = panel.y + 1, .w = w - 2, .h = h - 2 }, 9, palette.raised);
        try self.labels.draw(text, "Delete thread?", panel.x + 20, panel.y + 22, 16, palette.foreground);
        try self.labels.drawFitted(renderer, text, "This permanently removes the thread from the workspace.", panel.x + 20, panel.y + 52, w - 40, 12, palette.muted);
        self.sidebar_lifecycle_bounds[0] = .{ .x = panel.x + w - 180, .y = panel.y + h - 48, .w = 76, .h = 32 };
        self.sidebar_lifecycle_bounds[1] = .{ .x = panel.x + w - 96, .y = panel.y + h - 48, .w = 76, .h = 32 };
        const labels = [_][]const u8{ "Cancel", "Delete" };
        for (self.sidebar_lifecycle_bounds, 0..) |rect, index| {
            try widgets.panel(renderer, rect, 5, if ((index == 1) == self.sidebar_lifecycle.confirm_delete_selected) palette.selection else palette.surface);
            _ = self.navigation_targets.add(if (index == 0) "sidebar.delete.cancel" else "sidebar.delete.confirm", "button", rect, !self.sidebar_lifecycle.pending) catch {};
            try self.labels.draw(text, labels[index], rect.x + 12, rect.y + 9, 12, if (index == 1) palette.danger else palette.foreground);
        }
    }

    fn drawSidebarUndo(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, width: f32, height: f32) !void {
        const undo = self.sidebar_lifecycle.undo orelse return;
        if (wallTimeMs() >= undo.expires_at) {
            self.sidebar_lifecycle.undo = null;
            self.sidebar_lifecycle.shortcut_claimed = false;
            return;
        }
        self.sidebar_undo_label = undo.label;
        self.sidebar_undo_len = undo.label_len;
        const w: f32 = @min(300, width - 24);
        self.sidebar_undo_bounds = .{ .x = width - w - 16, .y = height - 74, .w = w, .h = 34 };
        try widgets.panel(renderer, self.sidebar_undo_bounds, 6, self.design.colors.raised);
        const label = undo.label[0..undo.label_len];
        try self.labels.drawFitted(renderer, text, label, self.sidebar_undo_bounds.x + 10, self.sidebar_undo_bounds.y + 10, w - 90, 11, self.design.colors.foreground);
        _ = self.navigation_targets.add("sidebar.undo", "button", .{ .x = self.sidebar_undo_bounds.x + w - 72, .y = self.sidebar_undo_bounds.y + 4, .w = 64, .h = 26 }, true) catch {};
        try self.labels.draw(text, "Undo", self.sidebar_undo_bounds.x + w - 64, self.sidebar_undo_bounds.y + 10, 11, self.design.colors.accent_text);
    }

    fn drawWorkspace(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        const width = @min(760, @max(420, bounds.transcript.width * 0.82));
        const height = @min(bounds.transcript.height - 20, @max(260, bounds.transcript.height * 0.86));
        const panel = c.SDL_FRect{ .x = bounds.transcript.x + (bounds.transcript.width - width) / 2, .y = bounds.transcript.y + 10, .w = width, .h = height };
        self.workspace_bounds = panel;
        self.workspace_close_bounds = .{ .x = panel.x + panel.w - 76, .y = panel.y + 10, .w = 60, .h = 26 };
        self.workspace_refresh_bounds = .{ .x = panel.x + panel.w - 148, .y = panel.y + 10, .w = 64, .h = 26 };
        _ = self.navigation_targets.add("workspace.close", "button", self.workspace_close_bounds, true) catch {};
        _ = self.navigation_targets.add("workspace.refresh", "button", self.workspace_refresh_bounds, !self.workspace_busy) catch {};
        try widgets.panel(renderer, panel, @min(self.design.layout.radius, 8), self.design.colors.raised);
        try self.labels.draw(text, "Workspace changes", panel.x + 16, panel.y + 14, 16, foreground);
        try self.labels.draw(text, if (self.workspace_stale) "Snapshot is stale · refresh the selected checkout" else "Read-only snapshot · captured checkout", panel.x + 16, panel.y + 36, 11, if (self.workspace_stale) self.design.colors.danger else muted);
        if (self.workspace_feedback_len != 0) try self.labels.drawFitted(renderer, text, self.workspace_feedback[0..self.workspace_feedback_len], panel.x + 16, panel.y + 52, panel.w - 180, 10, self.design.colors.danger);
        try widgets.panel(renderer, self.workspace_close_bounds, 4, self.design.colors.surface);
        try self.labels.draw(text, "Close", self.workspace_close_bounds.x + 12, self.workspace_close_bounds.y + 7, 11, foreground);
        try widgets.panel(renderer, self.workspace_refresh_bounds, 4, self.design.colors.surface);
        try self.labels.draw(text, "Refresh", self.workspace_refresh_bounds.x + 8, self.workspace_refresh_bounds.y + 7, 11, foreground);
        const list = c.SDL_FRect{ .x = panel.x + 14, .y = panel.y + 72, .w = @min(300, panel.w * 0.42), .h = panel.h - 86 };
        const diff = c.SDL_FRect{ .x = list.x + list.w + 12, .y = list.y, .w = panel.x + panel.w - list.x - list.w - 26, .h = list.h };
        self.workspace_diff_bounds = diff;
        if (self.workspace_selected_file) |selected| if (selected < self.workspace_file_count and self.workspace_files[selected].index != ' ' and self.workspace_files[selected].worktree != ' ') {
            _ = self.navigation_targets.add("workspace.staged", "button", .{ .x = diff.x, .y = diff.y - 22, .w = diff.w / 2, .h = 20 }, true) catch {};
            _ = self.navigation_targets.add("workspace.unstaged", "button", .{ .x = diff.x + diff.w / 2, .y = diff.y - 22, .w = diff.w / 2, .h = 20 }, true) catch {};
        };
        if (self.workspace_selected_file) |selected| if (selected < self.workspace_file_count and self.workspace_files[selected].index != ' ' and self.workspace_files[selected].worktree != ' ') {
            try self.labels.drawFitted(renderer, text, if (self.workspace_diff_staged) "Staged diff · click again for unstaged" else "Unstaged diff · click again for staged", diff.x + 8, diff.y - 18, diff.w - 16, 10, muted);
        };
        self.workspace_file_bounds = @splat(zero_rect);
        var list_clip = widgets.Clip.push(renderer, list);
        defer list_clip.restore(renderer);
        var y = list.y - self.workspace_scroll;
        for (self.workspace_files[0..self.workspace_file_count], 0..) |*file, index| {
            const row = c.SDL_FRect{ .x = list.x, .y = y, .w = list.w, .h = 28 };
            self.workspace_file_bounds[index] = clippedRect(row, list);
            var target_id: [32]u8 = undefined;
            const target_name = std.fmt.bufPrint(&target_id, "workspace.file.{d}", .{index}) catch "workspace.file";
            _ = self.navigation_targets.add(target_name, "listitem", self.workspace_file_bounds[index], true) catch {};
            if (self.workspace_selected_file == index) try widgets.panel(renderer, self.workspace_file_bounds[index], 4, self.design.colors.selection);
            var label: [300]u8 = undefined;
            const path = file.path[0..file.path_len];
            const prefix = std.fmt.bufPrint(&label, "{c}{c}  {s}", .{ file.index, file.worktree, path }) catch path;
            try self.labels.drawFitted(renderer, text, prefix, row.x + 8, row.y + 7, row.w - 16, 11, if (self.workspace_selected_file == index) foreground else muted);
            y += 30;
        }
        list_clip.restore(renderer);
        var diff_clip = widgets.Clip.push(renderer, diff);
        defer diff_clip.restore(renderer);
        if (self.workspace_selected_file == null) {
            try self.labels.drawFitted(renderer, text, if (self.workspace_file_count == 0) "No changed files" else "Select a file to inspect its diff", diff.x + 8, diff.y + 8, diff.w - 16, 12, muted);
        } else if (self.workspace_diff_len == 0) {
            try self.labels.drawFitted(renderer, text, "No diff for this file", diff.x + 8, diff.y + 8, diff.w - 16, 12, muted);
        } else {
            var line_y = diff.y + 8 - self.workspace_diff_scroll;
            var start: usize = 0;
            var lines: usize = 0;
            const first_line = @as(usize, @intFromFloat(@max(0, self.workspace_diff_scroll) / 16));
            while (start < self.workspace_diff_len and lines < first_line) : (lines += 1) {
                const rest = self.workspace_diff[start..self.workspace_diff_len];
                const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                start += end + @intFromBool(end < rest.len);
            }
            line_y = diff.y + 8;
            while (start < self.workspace_diff_len and line_y < diff.y + diff.h) : (line_y += 16) {
                const rest = self.workspace_diff[start..self.workspace_diff_len];
                const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
                try self.labels.drawFitted(renderer, text, rest[0..end], diff.x + 8, line_y, diff.w - 16, 10, muted);
                start += end + @intFromBool(end < rest.len);
            }
        }
        diff_clip.restore(renderer);
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
        self.workflow_button = .{ .x = self.controls[primary].x - 110, .y = y, .w = 104, .h = 28 };
        try self.labels.drawFitted(renderer, text, "More · F10", self.workflow_button.x + 4, y + 6, 98, 13, foreground);
        const available = @max(0, self.workflow_button.x - model_x - gap * 2);
        var label_buffer: [768]u8 = undefined;
        const label = if (self.selected) |*selected| modelLabel(selected, &label_buffer) else "Choose model";
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

    fn workflowControl(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, id: []const u8, label: []const u8, rect: c.SDL_FRect, enabled: bool, color: Color) !void {
        const index = self.workflow_targets.slice().len;
        try self.workflow_targets.add(id, if (std.mem.eql(u8, id, "attachment.path")) "textbox" else "button", rect, enabled);
        try widgets.panel(renderer, rect, 4, if (index == self.workflow_keyboard) self.design.colors.selection else self.design.colors.raised);
        try self.labels.drawFitted(renderer, text, label, rect.x + 5, rect.y + 6, rect.w - 10, 12, if (enabled) color else self.design.colors.muted);
    }

    fn drawWorkflow(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Coding, foreground: Color, muted: Color) !void {
        self.workflow_targets.clear();
        const box = c.SDL_FRect{ .x = bounds.transcript.x, .y = bounds.header.y + bounds.header.height + 4, .w = bounds.transcript.width, .h = bounds.composer.y + bounds.composer.height - bounds.header.y - bounds.header.height - 4 };
        self.workflow_bounds = box;
        var clip = widgets.Clip.push(renderer, box);
        defer clip.restore(renderer);
        try widgets.panel(renderer, box, 8, self.design.colors.surface);
        try self.labels.drawFitted(renderer, text, "Follow-ups, questions & attachments", box.x + 12, box.y + 10, box.w - 100, 16, foreground);
        try self.workflowControl(renderer, text, "workflow.close", "Close · Esc", .{ .x = box.x + box.w - 92, .y = box.y + 5, .w = 84, .h = 28 }, true, foreground);
        if (self.question_pending) {
            try self.labels.drawFitted(renderer, text, "Provider question · answer is sent to the active run", box.x + 12, box.y + 38, box.w - 24, 12, foreground);
            try self.labels.drawFitted(renderer, text, self.question_prompt[0..self.question_prompt_len], box.x + 12, box.y + 56, box.w - 24, 13, foreground);
            var choice_y = box.y + 78;
            var id_buffer: [64]u8 = undefined;
            for (self.question_choices[0..self.question_choice_count], 0..) |choice, index| {
                const selected = self.question_selected & (@as(u16, 1) << @intCast(index)) != 0;
                try self.workflowControl(renderer, text, try std.fmt.bufPrint(&id_buffer, "question.choice.{d}", .{index}), choice.label[0..choice.len], .{ .x = box.x + 12, .y = choice_y, .w = @min(box.w - 24, 420), .h = 26 }, !self.workflow_busy, if (selected) foreground else muted);
                choice_y += 30;
            }
            if (self.question_allow_freeform) {
                const answer_rect = c.SDL_FRect{ .x = box.x + 12, .y = choice_y, .w = @max(80, box.w - 104), .h = 28 };
                try self.workflowControl(renderer, text, "question.answer", if (self.workflow_path_len == 0) "Optional written answer…" else self.workflow_path[0..self.workflow_path_len], answer_rect, true, foreground);
                try self.workflowControl(renderer, text, "question.submit", "Answer", .{ .x = box.x + box.w - 84, .y = choice_y, .w = 72, .h = 28 }, !self.workflow_busy, foreground);
            } else {
                try self.workflowControl(renderer, text, "question.submit", "Answer", .{ .x = box.x + 12, .y = choice_y, .w = 92, .h = 28 }, !self.workflow_busy and self.question_selected != 0, foreground);
            }
            if (self.workflow_feedback_len != 0) try self.labels.drawFitted(renderer, text, self.workflow_feedback[0..self.workflow_feedback_len], box.x + 12, box.y + box.h - 28, box.w - 24, 12, foreground);
            return;
        }
        try self.labels.drawFitted(renderer, text, "Questions appear here when the provider needs a bounded answer.", box.x + 12, box.y + 38, box.w - 24, 12, muted);
        try self.labels.drawFitted(renderer, text, "Files in this draft are sent with your next message when the provider supports them.", box.x + 12, box.y + 58, box.w - 24, 12, muted);
        const path_rect = c.SDL_FRect{ .x = box.x + 12, .y = box.y + 82, .w = @max(60, box.w - 104), .h = 28 };
        try self.workflowControl(renderer, text, "attachment.path", if (self.workflow_path_len == 0) "Absolute file path…" else self.workflow_path[0..self.workflow_path_len], path_rect, true, foreground);
        try self.workflowControl(renderer, text, "attachment.add", "Add", .{ .x = box.x + box.w - 84, .y = path_rect.y, .w = 72, .h = 28 }, !self.workflow_busy, foreground);
        var buffer: [512]u8 = undefined;
        var id_buffer: [64]u8 = undefined;
        // Page one attachment and one follow-up together. Every bounded slot
        // remains reachable on a 720x480 window, without offscreen hit targets.
        const pages = @max(@max(self.attachments.count, self.followup_count), 1);
        self.workflow_page = @min(self.workflow_page, pages - 1);
        const y = box.y + 118;
        var ordinal: usize = 0;
        for (0..attachment_text.max_count) |i| if (self.attachments.get(i)) |file| {
            defer ordinal += 1;
            if (ordinal != self.workflow_page) continue;
            const label = try std.fmt.bufPrint(&buffer, "{s} · {d} bytes · attached to draft", .{ file.metadata.name, file.content.len });
            try self.labels.drawFitted(renderer, text, label, box.x + 12, y + 6, box.w - 106, 12, foreground);
            try self.workflowControl(renderer, text, try std.fmt.bufPrint(&id_buffer, "attachment.remove.{d}", .{i}), "Remove", .{ .x = box.x + box.w - 84, .y = y, .w = 72, .h = 28 }, !self.workflow_busy, foreground);
        };
        if (self.attachments.count == 0) try self.labels.drawFitted(renderer, text, "No local attachments · 8 files / 256 KiB maximum", box.x + 12, y + 6, box.w - 24, 12, muted);
        try self.workflowControl(renderer, text, "followup.enqueue", if (self.followup_editing != null) "Save draft edit" else "Queue composer draft", .{ .x = box.x + 12, .y = y + 34, .w = 174, .h = 28 }, !self.workflow_busy and !self.workflow_uncertain and self.workflow_active, foreground);
        if (self.followup_editing != null) try self.workflowControl(renderer, text, "followup.stop_edit", "Stop editing", .{ .x = box.x + 194, .y = y + 34, .w = 104, .h = 28 }, !self.workflow_busy, foreground);
        try self.labels.drawFitted(renderer, text, if (self.workflow_active) "Provider support is checked. Your draft stays here if refused." else "Follow-ups require a current live run. F6 stops; F7/F8 approve/deny.", box.x + 12, y + 68, box.w - 24, 12, muted);
        if (self.workflow_page < self.followup_count) {
            const i = self.workflow_page;
            const item = &self.followups[i];
            const label = try std.fmt.bufPrint(&buffer, "{s}: {s}", .{ @tagName(item.state), @import("../text/utf8.zig").prefix(item.content[0..item.len], 160) });
            try self.labels.drawFitted(renderer, text, label, box.x + 12, y + 90, box.w - 24, 12, foreground);
            inline for (.{ "edit", "cancel", "up", "down" }, 0..) |kind, k| {
                try self.workflowControl(renderer, text, try std.fmt.bufPrint(&id_buffer, "followup." ++ kind ++ ".{d}", .{i}), kind, .{ .x = box.x + 12 + k * 74, .y = y + 109, .w = 68, .h = 26 }, !self.workflow_busy and !self.workflow_uncertain and item.state == .planned and self.workflow_active, foreground);
            }
        }
        if (self.send_diagnostic.stage == .rejected and std.mem.eql(u8, self.send_diagnostic.rejection[0..self.send_diagnostic.rejection_len], "prompt_staging_full")) {
            try self.workflowControl(renderer, text, "prompt.cleanup", "Discard unfinished upload", .{ .x = box.x + 12, .y = box.y + box.h - 60, .w = @min(202, box.w - 214), .h = 26 }, !self.workflow_busy, foreground);
        }
        if (pages > 1) {
            try self.workflowControl(renderer, text, "workflow.previous", "Previous", .{ .x = box.x + box.w - 190, .y = box.y + box.h - 60, .w = 82, .h = 26 }, self.workflow_page > 0, foreground);
            try self.workflowControl(renderer, text, "workflow.next", "Next", .{ .x = box.x + box.w - 100, .y = box.y + box.h - 60, .w = 82, .h = 26 }, self.workflow_page + 1 < pages, foreground);
        }
        if (self.workflow_feedback_len != 0) try self.labels.drawFitted(renderer, text, self.workflow_feedback[0..self.workflow_feedback_len], box.x + 12, box.y + box.h - 28, box.w - 24, 12, foreground);
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
        self.setup_field_bounds[2].w -= 120;
        self.setup_folder_bounds = .{ .x = self.setup_field_bounds[2].x + self.setup_field_bounds[2].w + 8, .y = self.setup_field_bounds[2].y, .w = 112, .h = self.setup_field_bounds[2].h };
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
            try self.labels.draw(text, if (index == 0) "ChatGPT sign-in  ·  Alt+1" else "OpenCode models  ·  Alt+2", box.x + 12, box.y + 23, 10, if (selected) foreground else muted);
        }
        try self.labels.draw(text, "Workspace · existing project folder", menu.x + 16, menu.y + 104, 11, muted);
        try self.drawSetupField(renderer, text, 2, foreground, muted);
        try widgets.panel(renderer, self.setup_folder_bounds, 4, self.design.colors.surface);
        try self.labels.drawFitted(renderer, text, if (self.setup_folder_pending) "Choosing…" else "Choose folder…", self.setup_folder_bounds.x + 10, self.setup_folder_bounds.y + 9, self.setup_folder_bounds.w - 20, 11, if (self.chooseWorkspaceEnabled()) foreground else muted);
        try widgets.panel(renderer, self.setup_advanced_bounds, @min(self.design.layout.radius, 4), self.design.colors.surface);
        try icon(renderer, .chevron, self.setup_advanced_bounds.x + 8, self.setup_advanced_bounds.y + 6, muted);
        try self.labels.drawFitted(renderer, text, if (self.setup_advanced_open) "Hide Advanced · Alt+A" else "Advanced · Alt+A", self.setup_advanced_bounds.x + 30, self.setup_advanced_bounds.y + 7, self.setup_advanced_bounds.w - 36, 11, muted);
        if (self.setup_existing_bounds.w != 0) {
            try widgets.panel(renderer, self.setup_existing_bounds, @min(self.design.layout.radius, 4), self.design.colors.surface);
            try self.labels.drawFitted(renderer, text, "Use my ChatGPT login", self.setup_existing_bounds.x + 12, self.setup_existing_bounds.y + 7, self.setup_existing_bounds.w - 24, 11, if (self.existingCodexEnabled()) foreground else muted);
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
                "Connect discovers OpenCode's free models. For a paid provider, choose its account folder in Advanced.";
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
        self.navigation_targets.clear();
        if (!c.SDL_SetRenderDrawColor(renderer, self.design.colors.background.r, self.design.colors.background.g, self.design.colors.background.b, 255) or !c.SDL_RenderClear(renderer)) return error.CanvasDraw;
        if (self.custom_root == null) try self.drawChrome(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null) _ = self.navigation_targets.add("workspace.changes", "button", self.workspace_toggle_bounds, self.workspace_toggle_bounds.w > 0) catch {};
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
        const notice_height: f32 = if (self.notice != null) 20 else 0;
        self.transcript_bounds = .{ .x = bounds.transcript.x, .y = bounds.transcript.y + task_height + notice_height, .w = bounds.transcript.width, .h = @max(0, bounds.transcript.height - task_height - notice_height) };
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
            try self.custom_tile.drawStyled(renderer, text, bounds.transcript.x, self.transcript_bounds.y, self.transcriptDesign());
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
                    if (self.focused and (self.activeLine() == null) and self.reveal_caret) {
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
                    if (self.focused and (self.activeLine() == null) and self.window_active) {
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
        if (self.notice) |notice| {
            const hint_width: f32 = if (self.send_diagnostic.stage != .idle and bounds.transcript.width >= 600) 222 else 0;
            try self.labels.drawFitted(renderer, text, notice, bounds.transcript.x, bounds.transcript.y + task_height, bounds.transcript.width - hint_width, 12, muted);
            if (hint_width != 0) try self.labels.drawFitted(renderer, text, "Ctrl+Shift+C: Send diagnostics", bounds.transcript.x + bounds.transcript.width - hint_width + 12, bounds.transcript.y + task_height, hint_width - 12, 11, muted);
        }
        if (self.custom_root == null and self.workflow_open) try self.drawWorkflow(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null and self.picker_open) try self.drawPicker(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null and self.effort_open) try self.drawEffort(renderer, text, foreground, muted);
        if (self.custom_root == null and self.setup_open) try self.drawSetup(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null and self.workspace_open and !self.setup_open) try self.drawWorkspace(renderer, text, bounds, foreground, muted);
        if (self.custom_root == null and self.sidebar_menu_thread.len != 0) try self.drawSidebarMenu(renderer, text, bounds.header.width, self.sidebar_bounds.h);
        if (self.custom_snooze != null) try self.drawCustomSnooze(renderer, text, bounds.header.width, self.sidebar_bounds.h);
        if (self.sidebar_lifecycle.confirming != null) try self.drawSidebarLifecycle(renderer, text, bounds.header.width, self.sidebar_bounds.h);
        if (self.sidebar_lifecycle.undo != null and self.sidebar_lifecycle.confirming == null and self.custom_snooze == null) try self.drawSidebarUndo(renderer, text, bounds.header.width, self.sidebar_bounds.h);
        if (self.window_active and self.focused) if (self.activeLine()) |field| {
            const fallback = switch (field) {
                .search => self.search_bounds,
                .rename => self.sidebar_rename_bounds,
                .title => self.title_bounds,
                .snooze_date => self.custom_snooze_bounds[2],
                .snooze_time => self.custom_snooze_bounds[3],
                .snooze_amount => self.custom_snooze_bounds[5],
            };
            const caret = self.line_view.caretArea() orelse fallback;
            if (caret.w > 0 and caret.h > 0) {
                const area: c.SDL_Rect = .{ .x = @intFromFloat(caret.x), .y = @intFromFloat(caret.y), .w = @max(1, @as(c_int, @intFromFloat(caret.w))), .h = @max(1, @as(c_int, @intFromFloat(caret.h))) };
                if (!c.SDL_SetTextInputArea(window, &area, 0)) return error.TextInputArea;
            }
        };
    }
};

test "sidebar custom snooze owns input and retains stable request values on rejection" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("composer preserved", .typing);
    view.custom_snooze = try SidebarSnooze.State.init(View.wallTimeMs());
    view.custom_snooze_thread = try transcript.Id.init("stable-target");
    view.custom_snooze.?.mode = .duration;
    view.custom_snooze_focus = .amount;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    var entered = "1.5".* ++ .{@as(u8, 0)};
    event.text.text = &entered;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("1.5", view.custom_snooze.?.amount.slice());
    const now = View.wallTimeMs();
    try std.testing.expect(view.custom_snooze.?.submit(now));
    const request = view.takeCustomSnoozeRequest().?;
    try std.testing.expectEqualStrings("stable-target", request.id.slice());
    try std.testing.expectEqual(now + 5_400_000, request.snoozed_until);
    try std.testing.expect(view.customSnoozePending());
    try std.testing.expect(view.takeCustomSnoozeRequest() == null);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_ESCAPE;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expect(view.customSnoozeOpen());
    view.finishCustomSnooze("Busy");
    try std.testing.expect(!view.customSnoozePending());
    try std.testing.expectEqualStrings("1.5", view.custom_snooze.?.amount.slice());
    try std.testing.expectEqualStrings("Busy", view.custom_snooze.?.error_bytes[0..view.custom_snooze.?.error_len]);
    try std.testing.expectEqualStrings("composer preserved", view.editor.textBytes());
    view.finishCustomSnooze(null);
    try std.testing.expect(!view.customSnoozeOpen());
}

test "sidebar custom snooze renders only modal targets and a bounded calendar" {
    const surface = c.SDL_CreateSurface(720, 480, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.custom_snooze = try SidebarSnooze.State.init(View.wallTimeMs());
    _ = try view.navigation_targets.add("underlying.send", "button", .{ .x = 1, .y = 1, .w = 50, .h = 50 }, true);
    try view.drawCustomSnooze(renderer, text, 720, 480);
    for (view.navigation_targets.slice()) |target| try std.testing.expect(std.mem.startsWith(u8, target.id[0..target.id_len], "sidebar.custom_snooze"));
    view.customSnoozeActivate(4);
    try std.testing.expect(view.custom_snooze.?.calendar_open);
    try view.drawCustomSnooze(renderer, text, 720, 480);
    for (view.custom_snooze_days) |rect| if (rect.w > 0) {
        try std.testing.expect(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= 720 and rect.y + rect.h <= 480);
    };
}

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

test "workspace inspection keeps selection and rejects stale checkout results" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    var file: View.WorkspaceFile = .{};
    @memcpy(file.path[0..8], "src/main");
    file.path_len = 8;
    file.index = 'M';
    try std.testing.expect(view.admitWorkspaceInspection(4, "/tmp/checkout", &.{file}, "diff\n"));
    view.workspace_open = true;
    view.workspace_selected_file = 0;
    view.workspace_scroll = 19;
    try std.testing.expect(view.admitWorkspaceInspection(5, "/tmp/checkout", &.{file}, "next\n"));
    try std.testing.expectEqual(@as(?usize, 0), view.workspace_selected_file);
    try std.testing.expectEqual(@as(f32, 19), view.workspace_scroll);
    // A selected-file completion retains the view's already admitted file list.
    // Refreshing that diff must allow the retained slices to alias their output.
    try std.testing.expect(view.admitWorkspaceInspection(6, view.workspace_checkout[0..view.workspace_checkout_len], view.workspace_files[0..view.workspace_file_count], "selected file diff\n"));
    try std.testing.expectEqualStrings("src/main", view.workspace_files[0].path[0..view.workspace_files[0].path_len]);
    try std.testing.expectEqualStrings("selected file diff\n", view.workspace_diff[0..view.workspace_diff_len]);
    try std.testing.expectEqual(@as(?usize, 0), view.workspace_selected_file);
    try std.testing.expect(view.admitWorkspaceInspection(7, view.workspace_checkout[0..view.workspace_checkout_len], view.workspace_files[0..view.workspace_file_count], view.workspace_diff[0..view.workspace_diff_len]));
    try std.testing.expectEqualStrings("selected file diff\n", view.workspace_diff[0..view.workspace_diff_len]);
    file.path_len = file.path.len + 1;
    try std.testing.expect(!view.admitWorkspaceInspection(8, "/tmp/checkout", &.{file}, "invalid\n"));
    try std.testing.expectEqual(@as(u64, 7), view.workspace_revision);
    try std.testing.expectEqualStrings("selected file diff\n", view.workspace_diff[0..view.workspace_diff_len]);
    try std.testing.expect(!view.admitWorkspaceInspection(4, "/tmp/other", &.{file}, "wrong\n"));
    try std.testing.expect(view.workspace_stale);
}

test "send diagnostic keeps bounded command, receipt and provider evidence" {
    var diagnostic: SendDiagnostic = .{};
    const command = "a" ** 40;
    diagnostic.begin(command, 3792, 4096);
    try std.testing.expectEqual(SendStage.submitted, diagnostic.stage);
    try std.testing.expectEqual(@as(usize, 32), diagnostic.command_id_len);
    diagnostic.setReceipt(.rejected, "admission_limit");
    try std.testing.expectEqual(SendStage.rejected, diagnostic.stage);
    try std.testing.expectEqual(SendReceipt.rejected, diagnostic.receipt);
    diagnostic.setRun("run-id", "session-id");
    diagnostic.setProviderDiagnostic("provider failed", false);
    try std.testing.expectEqual(SendStage.provider_failed, diagnostic.stage);
    try std.testing.expectEqualStrings("run-id", diagnostic.run_id[0..diagnostic.run_id_len]);
    try std.testing.expectEqualStrings("session-id", diagnostic.session_id[0..diagnostic.session_id_len]);
    diagnostic.setProviderDiagnostic("completed", true);
    try std.testing.expectEqual(SendStage.terminal, diagnostic.stage);
    diagnostic.setProviderDiagnostic("", true);
    try std.testing.expectEqualStrings("provider failed", diagnostic.provider[0..diagnostic.provider_len]);
    diagnostic.begin(command, 3792, 4096);
    diagnostic.setProviderDiagnostic("€" ** 400, false);
    try std.testing.expectEqual(@as(usize, 1023), diagnostic.provider_len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(diagnostic.provider[0..diagnostic.provider_len]));
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
                .choose_workspace => 6,
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
            // Keep the short-label case genuinely compact; a provider prefix
            // is deliberately visible for real catalog identities and makes
            // the resulting label wider by design.
            const provider = if (model_label.len == 1) "" else "fixture";
            view.selected = try View.Identity.from(.{ .runtime_kind = "codex", .model_provider = provider, .model_id = model_label, .effort = "low", .account_ref = "isolated", .workspace = .{ .value = "checkout" } });
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
    view.selected = try View.Identity.from(.{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "gpt", .effort = "low", .account_ref = "/fixture/accounts/codex", .workspace = .{ .value = "/fixture/project" } });
    view.selectSetupProvider(.opencode);
    try std.testing.expect(view.selected == null);
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

test "workspace chooser updates exact Unicode paths and leaves invalid selections untouched" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try std.testing.expect(view.setSetupDefaults(setup_fixture_defaults));
    try std.testing.expect(view.setWorkspaceFolder("/tmp/project 世界"));
    try std.testing.expect(!view.setWorkspaceFolder("relative/project"));
    try std.testing.expect(!view.setWorkspaceFolder("/" ++ ("x" ** 512)));
    try std.testing.expectEqualStrings("/tmp/project 世界", view.setup_fields[2][0..view.setup_lengths[2]]);
    view.setup_open = true;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_O;
    event.key.mod = c.SDL_KMOD_CTRL;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(.choose_workspace, view.setup_action.?);
    view.setup_action = null;
    view.setup_folder_pending = true;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expect(view.setup_action == null);
    try std.testing.expect(!view.setupActionEnabled(0));
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

test "composer model label keeps negotiated provider prefix visible" {
    const opencode = try View.Identity.from(.{ .runtime_kind = "opencode", .model_provider = "opencode-free", .model_id = "glm-5.3-flash", .effort = "default", .account_ref = "isolated", .workspace = .{ .value = "checkout" } });
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("opencode-free / glm-5.3-flash", View.modelLabel(&opencode, &buffer));

    const fake = try View.Identity.from(contract.fakeSelection(.{ .value = "fixture" }));
    try std.testing.expectEqualStrings("Demo · synthetic", View.modelLabel(&fake, &buffer));
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

test "title editor validates replacement atomically and respects modal availability" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("retained composer draft", .typing);
    view.thread_count = 1;
    view.active_thread = try transcript.Id.init("thread");
    view.threads[0].id = view.active_thread;
    view.threads[0].len = 4;
    @memcpy(view.threads[0].label[0..4], "chat");
    view.navigation_enabled = true;
    try std.testing.expect(view.titleEditAvailable());
    view.effort_open = true;
    try std.testing.expect(!view.titleEditAvailable());
    view.effort_open = false;
    view.workflow_open = true;
    try std.testing.expect(!view.titleEditAvailable());
    view.workflow_open = false;
    view.beginTitleEdit();
    try std.testing.expectError(error.InvalidTitle, view.titleInsert("line\nbreak"));
    try std.testing.expectError(error.InvalidUtf8, view.titleInsert("\xff"));
    try std.testing.expectError(error.TextTooLarge, view.titleInsert("🎮" ** 40 ++ "x"));
    try std.testing.expect(view.title_select_all);
    try std.testing.expectEqualStrings("chat", view.title_buffer[0..view.title_len]);
    try view.titleInsert("🎮" ** 40);
    try std.testing.expectEqual(@as(usize, 160), view.title_len);
    try std.testing.expectError(error.TextTooLarge, view.titleInsert("x"));
    try std.testing.expectEqualStrings("🎮" ** 40, view.title_buffer[0..view.title_len]);
    view.finishTitle(.cancel);
    try std.testing.expect(!view.title_editing);
    try std.testing.expectEqualStrings("retained composer draft", view.editor.textBytes());
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

test "search filtering preserves the active title editor when its card is absent" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.active_thread = try transcript.Id.init("active");
    view.active_thread_title_len = "Pinned chat".len;
    @memcpy(view.active_thread_title[0..view.active_thread_title_len], "Pinned chat");
    view.navigation_enabled = true;
    view.beginTitleEdit();
    try std.testing.expect(view.title_editing);
    try std.testing.expectEqualStrings("Pinned chat", view.title_buffer[0..view.title_len]);
    view.title_editing = false;
    view.thread_count = view.threads.len;
    for (view.threads[0..], 0..) |*entry, index| {
        var id: [32]u8 = undefined;
        entry.id = try transcript.Id.init(try std.fmt.bufPrint(&id, "thread-{d}", .{index}));
        entry.len = 6;
        @memcpy(entry.label[0..6], "needle");
    }
    view.search_len = 6;
    @memcpy(view.search_query[0..6], "needle");
    try std.testing.expectEqual(view.threads.len, view.visibleThreadCount());
    view.thread_count = 0;
    try std.testing.expectEqual(@as(usize, 0), view.visibleThreadCount());
    view.beginTitleEdit();
    try std.testing.expect(view.title_editing);
    try std.testing.expectEqualStrings("Pinned chat", view.title_buffer[0..view.title_len]);
}

test "sidebar project scope keyboard selection retains real identity and consumes modal input" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.project_count = 2;
    view.projects[0].id = try transcript.Id.init("project-a");
    view.projects[1].id = try transcript.Id.init("project-b");
    view.scope_menu = .{ .x = 8, .y = 96, .w = 240, .h = 64 };
    view.scope_project = view.projects[0].id;
    view.openScope();
    try std.testing.expectEqual(@as(usize, 1), view.scope_hover);
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_END;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expectEqual(@as(usize, 2), view.scope_hover);
    try std.testing.expect(view.scope_scroll > 0);
    event.key.key = c.SDLK_RETURN;
    try std.testing.expect(try view.handle(event, undefined, undefined));
    try std.testing.expect(view.scope_project.eql("project-b"));
    try std.testing.expect(!view.scope_open);
    try std.testing.expect(view.navigation == null);
    view.openScope();
    event.key.key = c.SDLK_HOME;
    _ = try view.handle(event, undefined, undefined);
    event.key.key = c.SDLK_RETURN;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(@as(usize, 0), view.scope_project.len);
}

test "sidebar Unicode search folds accents sharp s and Greek without allocating" {
    for ([_][2][]const u8{ .{ "CAFÉ", "café" }, .{ "Straße", "STRASSE" }, .{ "Σίσυφος", "ΣΊΣΥΦΟΣ" }, .{ "naïve", "NAÏVE" } }) |pair| {
        try std.testing.expect(View.searchContains(pair[0], pair[1]));
        try std.testing.expect(View.searchContains(pair[1], pair[0]));
    }
    try std.testing.expect(!View.searchContains("café", "cafe"));
    try std.testing.expect(!View.searchContains("🎮", "🎧"));
    try std.testing.expect(!View.searchContains("\xff", "query"));
}

test "sidebar inline rename targets an unselected Unicode row without changing the active draft" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("active chat draft", .typing);
    view.navigation_enabled = true;
    view.thread_count = 2;
    view.threads[0].id = try transcript.Id.init("active-thread");
    view.threads[1].id = try transcript.Id.init("other-thread");
    view.threads[1].len = 4;
    @memcpy(view.threads[1].label[0..4], "Chat");
    view.active_thread = view.threads[0].id;
    view.beginSidebarRename(1);
    try view.sidebarRenameInsert("レビュー 🎮");
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_BACKSPACE;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("レビュー ", view.sidebar_rename_buffer[0..view.sidebar_rename_len]);
    try std.testing.expectError(error.InvalidTitle, view.sidebarRenameInsert("bad\nname"));
    try std.testing.expectError(error.InvalidUtf8, view.sidebarRenameInsert("\xff"));
    view.sidebar_rename_select_all = true;
    try view.sidebarRenameInsert("🎮" ** 40);
    try std.testing.expectError(error.TextTooLarge, view.sidebarRenameInsert("x"));
    std.mem.swap(View.Entry, &view.threads[0], &view.threads[1]);
    view.commitSidebarRename();
    try std.testing.expectEqual(@as(usize, 0), view.navigation.?.rename.index);
    try std.testing.expectEqualStrings("🎮" ** 40, view.navigation.?.rename.title[0..view.navigation.?.rename.len]);
    try std.testing.expect(view.active_thread.eql("active-thread"));
    try std.testing.expectEqualStrings("active chat draft", view.editor.textBytes());
    view.beginSidebarRename(0);
    event.key.key = c.SDLK_ESCAPE;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(@as(usize, 0), view.sidebar_rename_thread.len);
}

test "sidebar shelves retain selected rows and context actions keep stable thread identity" {
    const surface = c.SDL_CreateSurface(1280, 800, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, @import("build_options").font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var layout = try Layout.init(std.testing.allocator, 1280, 800);
    defer layout.deinit();
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("preserve this draft", .typing);
    view.navigation_enabled = true;
    view.thread_count = 5;
    for (view.threads[0..5], 0..) |*entry, index| {
        var id: [32]u8 = undefined;
        entry.id = try transcript.Id.init(try std.fmt.bufPrint(&id, "actual-{d}", .{index}));
        entry.len = 4;
        @memcpy(entry.label[0..4], "Chat");
    }
    view.threads[0].pinned = true;
    view.threads[2].run_status = .running;
    view.threads[3].snoozed_until = View.wallTimeMs() + 3_600_000;
    view.threads[4].settled = true;
    view.active_thread = view.threads[1].id;
    @memcpy(view.threads[0].label[0..160], "🎮" ** 40);
    view.threads[0].len = 160;
    view.beginSidebarRename(0);
    const bounds = layout.coding(1280);
    try view.drawChrome(renderer, text, bounds, view.design.colors.foreground, view.design.colors.muted);
    try std.testing.expectEqual(@as(f32, 78), view.threadRowBounds(0).h);
    try std.testing.expectEqualStrings("🎮" ** 40, view.sidebar_rename_buffer[0..view.sidebar_rename_len]);
    view.sidebar_rename_thread = .{};
    try std.testing.expectEqual(@as(f32, 78), view.threadRowBounds(2).h);
    try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(3));
    try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(4));
    try std.testing.expectEqual(@as(f32, 0), view.sidebar_shelf_bounds[0].h);
    try std.testing.expect(view.sidebar_shelf_bounds[1].h > 0);
    try std.testing.expect(view.sidebar_shelf_bounds[2].h > 0);
    view.active_thread = view.threads[4].id;
    try view.drawChrome(renderer, text, bounds, view.design.colors.foreground, view.design.colors.muted);
    try std.testing.expectEqual(@as(f32, 36), view.threadRowBounds(4).h);
    view.sidebar_shelf_expanded[1] = true;
    try view.drawChrome(renderer, text, bounds, view.design.colors.foreground, view.design.colors.muted);
    try std.testing.expectEqual(@as(f32, 36), view.threadRowBounds(3).h);
    view.sidebar_menu_thread = view.threads[0].id;
    try view.drawSidebarMenu(renderer, text, 1280, 800);
    try std.testing.expectEqualDeep(View.zero_rect, view.threadRowBounds(0));
    std.mem.swap(View.Entry, &view.threads[0], &view.threads[1]);
    view.activateSidebarMenu(0);
    try std.testing.expectEqual(@as(usize, 1), view.navigation.?.sidebar.index);
    try std.testing.expectEqual(View.SidebarAction.unpin, view.navigation.?.sidebar.action);
    try std.testing.expectEqualStrings("preserve this draft", view.editor.textBytes());
    view.sidebar_collapsed = true;
    layout.sidebar_collapsed = true;
    const collapsed = layout.coding(1280);
    try view.drawChrome(renderer, text, collapsed, view.design.colors.foreground, view.design.colors.muted);
    try std.testing.expectEqual(@as(f32, 0), view.sidebarWidth(1280));
    try std.testing.expectEqual(@as(f32, 0), view.search_bounds.w);
    try std.testing.expectEqual(@as(f32, 0), view.setup_bounds.w);
    try std.testing.expect(collapsed.composer.x < bounds.composer.x);
    view.sidebar_collapsed = false;
    layout.sidebar_collapsed = false;
    view.sidebar_width_override = 340;
    layout.sidebar_width_override = view.sidebar_width_override;
    try std.testing.expectEqual(view.sidebarWidth(1280), layout.sidebarWidthFor(1280));
    try std.testing.expectEqual(@as(f32, 340), view.sidebarWidth(1280));
    try std.testing.expectEqual(@as(?i64, view.threads[3].snoozed_until), view.nextSidebarWakeMs(View.wallTimeMs()));
    try std.testing.expectEqual(@as(?i64, null), view.nextSidebarWakeMs(view.threads[3].snoozed_until));
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
        try std.testing.expectEqual(@as(f32, 82), second.y - first.y);
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
        try std.testing.expectEqual(@as(f32, 36), filtered.h);
        event.button.x = filtered.x + 4;
        event.button.y = filtered.y + 18;
        try std.testing.expect(try view.handle(event, undefined, undefined));
        try std.testing.expectEqual(@as(usize, 1), view.navigation.?.thread);
        try std.testing.expectEqual(@as(usize, 0), view.search_len);
        // Selecting a result clears search, just like keyboard Enter. Start
        // another query before checking its intersection with project scope.
        try view.searchInsert("NEEDLE");
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
        try std.testing.expectEqual(@as(f32, 82), c_row.y - a.y);
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
    view.setup_advanced_open = true;
    view.setup_field = 1;
    view.useExistingCodex();
    try std.testing.expectEqual(.configure, view.setup_action.?);
    try std.testing.expect(!view.setup_advanced_open);
    try std.testing.expectEqual(@as(usize, 2), view.setup_field);
    try std.testing.expectEqualStrings(setup_fixture_defaults[0].account_directory, view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expectEqualStrings(saved.workspace_root, view.setup_fields[2][0..view.setup_lengths[2]]);
    view.setup_action = null;
    view.setup_runtime = .opencode;
    view.useExistingCodex();
    try std.testing.expect(view.setup_action == null);
}

test "workflow attachments and follow-up edits retain thread identity and release owned copies" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.selectThread(try transcript.Id.init("first"));
    try view.insert("draft café", .paste);
    view.scopeWorkflow(try transcript.Id.init("run-one"));
    _ = try view.attachments.add(.{ .metadata = .{ .id = .{ .value = "file" }, .name = "notes", .media_type = "text/plain", .byte_length = 5, .digest = "digest" }, .content = "hello" });
    view.followups[0] = .{ .id = try transcript.Id.init("followup"), .revision = 7, .len = 6, .content = try std.testing.allocator.dupe(u8, "queued") };
    view.followup_count = 1;
    view.followup_editing = view.followups[0].id;
    try view.selectThread(try transcript.Id.init("second"));
    try std.testing.expectEqual(@as(usize, 0), view.attachments.count);
    try std.testing.expectEqual(@as(usize, 0), view.followup_count);
    try std.testing.expect(view.followup_editing == null);
    try view.selectThread(try transcript.Id.init("first"));
    try std.testing.expectEqualStrings("hello", view.attachments.get(0).?.content);
    try std.testing.expectEqualStrings("draft café", view.editor.textBytes());
    try std.testing.expectEqual(@as(u64, 7), view.followups[0].revision);
    try std.testing.expectEqualStrings("run-one", view.workflow_run.slice());
    view.scopeWorkflow(try transcript.Id.init("run-two"));
    try std.testing.expectEqual(@as(usize, 0), view.followup_count);
    try std.testing.expect(view.followup_editing == null);
    try std.testing.expectEqualStrings("draft café", view.editor.textBytes());
    try std.testing.expectEqual(@as(usize, 1), view.attachments.count);
}

test "workflow path editing rejects overflow transactionally and never edits the composer" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("composer", .typing);
    try view.workflowInsert("/tmp/café");
    try std.testing.expectError(error.TextTooLarge, view.workflowInsert("x" ** 1024));
    try std.testing.expectEqualStrings("/tmp/café", view.workflow_path[0..view.workflow_path_len]);
    try std.testing.expectEqualStrings("composer", view.editor.textBytes());
    view.followup_editing = try transcript.Id.init("old");
    try view.workflowActivate("followup.stop_edit");
    try std.testing.expect(view.followup_editing == null);
    try std.testing.expectEqualStrings("composer", view.editor.textBytes());
}

test "workflow paging keeps every bounded action inside minimum native geometry" {
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
    view.workflow_active = true;
    view.workflow_open = true;
    for (0..8) |i| {
        var buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&buffer, "file-{d}", .{i});
        _ = try view.attachments.add(.{ .metadata = .{ .id = .{ .value = id }, .name = id, .media_type = "text/plain", .byte_length = 1, .digest = "digest" }, .content = "x" });
        view.followups[i] = .{ .id = try transcript.Id.init(id), .revision = 1, .content = try std.testing.allocator.dupe(u8, "queued"), .len = 6 };
        view.followup_count += 1;
    }
    for (0..8) |page| {
        view.workflow_page = page;
        try view.drawWorkflow(renderer, text, layout.coding(720), view.design.colors.foreground, view.design.colors.muted);
        var remove: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&remove, "attachment.remove.{d}", .{page});
        var found = false;
        for (view.workflow_targets.slice()) |target| {
            const b = target.bounds;
            try std.testing.expect(b.x >= view.workflow_bounds.x and b.y >= view.workflow_bounds.y);
            try std.testing.expect(b.x + b.w <= view.workflow_bounds.x + view.workflow_bounds.w);
            try std.testing.expect(b.y + b.h <= view.workflow_bounds.y + view.workflow_bounds.h);
            if (std.mem.eql(u8, target.id[0..target.id_len], expected)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "small fields own Unicode selection composition and trimmed blur without touching draft" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("composer draft", .typing);
    view.navigation_enabled = true;
    view.thread_count = 1;
    view.threads[0].id = try transcript.Id.init("row");
    view.beginSidebarRename(0);
    try view.sidebarRenameInsert("a" ++ "e\u{301}" ++ "🇺🇸" ++ "👩‍💻");
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_BACKSPACE;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("ae\u{301}🇺🇸", view.sidebar_rename_buffer[0..view.sidebar_rename_len]);
    event.key.key = c.SDLK_HOME;
    _ = try view.handle(event, undefined, undefined);
    event.key.key = c.SDLK_RIGHT;
    event.key.mod = c.SDL_KMOD_SHIFT;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(@as(usize, 1), view.rename_edit.range().end);
    try view.sidebarRenameInsert("z");
    try std.testing.expectEqualStrings("ze\u{301}🇺🇸", view.sidebar_rename_buffer[0..view.sidebar_rename_len]);
    event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_EDITING;
    event.edit.text = "日本";
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("日本", view.line_view.preedit[0..view.line_view.preedit_len]);
    try std.testing.expectEqual(@as(usize, 0), view.preedit_len);
    event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RETURN;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expect(view.navigation == null);
    try std.testing.expect(view.sidebar_rename_thread.eql("row"));
    event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "日本";
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqual(@as(usize, 0), view.line_view.preedit_len);
    view.sidebar_rename_select_all = true;
    try view.sidebarRenameInsert("  trimmed title  ");
    view.sidebar_rename_bounds = .{ .x = 10, .y = 10, .w = 100, .h = 22 };
    view.sidebar_toggle_bounds = .{ .x = 200, .y = 100, .w = 20, .h = 20 };
    event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = 200;
    event.button.y = 100;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("trimmed title", view.navigation.?.rename.title[0..view.navigation.?.rename.len]);
    try std.testing.expectEqualStrings("composer draft", view.editor.textBytes());
}

test "modal input ownership protects covered title and sidebar fields" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    try view.insert("draft", .typing);
    try view.titleInsert("title");
    try view.searchInsert("search");
    view.title_editing = true;
    view.search_focused = true;
    inline for (.{ "setup_open", "workflow_open", "workspace_open", "scope_open", "picker_open", "effort_open" }) |modal| {
        @field(view, modal) = true;
        try std.testing.expect(view.activeLine() == null);
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_KEY_DOWN;
        event.key.key = c.SDLK_A;
        event.key.mod = c.SDL_KMOD_CTRL;
        _ = try view.handle(event, undefined, undefined);
        event.key.key = c.SDLK_LEFT;
        _ = try view.handle(event, undefined, undefined);
        event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_TEXT_EDITING;
        event.edit.text = "日本";
        _ = try view.handle(event, undefined, undefined);
        event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_TEXT_INPUT;
        event.text.text = "x";
        _ = try view.handle(event, undefined, undefined);
        try std.testing.expectEqualStrings("title", view.title_buffer[0..view.title_len]);
        try std.testing.expectEqualStrings("search", view.search_query[0..view.search_len]);
        try std.testing.expectEqual(@as(usize, 0), view.line_view.preedit_len);
        try std.testing.expectEqualStrings("draft", view.editor.textBytes());
        @field(view, modal) = false;
    }
}

test "blur retains the clicked thread identity until rename receipt" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.navigation_enabled = true;
    view.thread_count = 2;
    view.threads[0].id = try transcript.Id.init("renamed");
    view.threads[1].id = try transcript.Id.init("clicked");
    view.sidebar_bounds = .{ .x = 0, .y = 0, .w = 256, .h = 300 };
    view.sidebar_rows = view.sidebar_bounds;
    view.thread_bounds[1] = .{ .x = 0, .y = 100, .w = 256, .h = 80 };
    view.sidebar_rename_bounds = .{ .x = 10, .y = 10, .w = 100, .h = 22 };
    view.beginSidebarRename(0);
    try view.sidebarRenameInsert("name");
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = 120;
    event.button.y = 120;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("name", view.navigation.?.rename.title[0..view.navigation.?.rename.len]);
    std.mem.swap(View.Entry, &view.threads[0], &view.threads[1]);
    try std.testing.expect(view.takeRenameFollowup().?.thread.eql("clicked"));
    try std.testing.expect(view.takeRenameFollowup() == null);
}

test "bounded field errors explain limits while diagnostic errors stay available" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.search_focused = true;
    try std.testing.expectEqualStrings("Search is limited to 160 UTF-8 bytes. Existing text retained.", view.inputErrorNotice(error.TextTooLarge).?);
    view.search_focused = false;
    view.title_editing = true;
    try std.testing.expectEqualStrings("Titles are limited to 160 UTF-8 bytes. Existing text retained.", view.inputErrorNotice(error.TextTooLarge).?);
    try std.testing.expect(view.inputErrorNotice(error.Unrelated) == null);
}

test "rename blur preserves hover settlement and header editing intent" {
    var view = try View.init(std.testing.allocator);
    defer view.deinit();
    view.navigation_enabled = true;
    view.thread_count = 2;
    view.threads[0].id = try transcript.Id.init("renamed");
    view.threads[1].id = try transcript.Id.init("settled-on-click");
    view.active_thread = view.threads[0].id;
    view.sidebar_bounds = .{ .x = 0, .y = 0, .w = 256, .h = 300 };
    view.sidebar_rows = view.sidebar_bounds;
    view.sidebar_rename_bounds = .{ .x = 10, .y = 10, .w = 100, .h = 22 };
    view.sidebar_action_bounds[1][0] = .{ .x = 190, .y = 100, .w = 54, .h = 22 };
    view.beginSidebarRename(0);
    try view.sidebarRenameInsert("saved title");
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = 200;
    event.button.y = 110;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expectEqualStrings("saved title", view.navigation.?.rename.title[0..view.navigation.?.rename.len]);
    const followup = view.takeRenameFollowup().?.sidebar;
    try std.testing.expect(followup.id.eql("settled-on-click"));
    try std.testing.expectEqual(View.SidebarAction.settle, followup.action);
    view.navigation = null;
    view.title_bounds = .{ .x = 300, .y = 10, .w = 200, .h = 32 };
    view.beginSidebarRename(0);
    try view.sidebarRenameInsert("new header title");
    event.button.x = 320;
    event.button.y = 20;
    _ = try view.handle(event, undefined, undefined);
    try std.testing.expect(!view.title_editing);
    try std.testing.expectEqualStrings("new header title", view.navigation.?.rename.title[0..view.navigation.?.rename.len]);
    try std.testing.expectEqual(std.meta.Tag(View.RenameFollowup).edit_active_title, std.meta.activeTag(view.takeRenameFollowup().?));
}

test "long hovered project text cannot paint underneath sidebar actions" {
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
    view.sidebar_width_override = 208;
    layout.sidebar_width_override = 208;
    view.navigation_enabled = true;
    view.sidebar_hover = 0;
    view.thread_count = 1;
    view.threads[0].id = try transcript.Id.init("long-project");
    view.threads[0].can_snooze = true;
    for ([_]bool{ false, true }) |pinned| {
        view.threads[0].pinned = pinned;
        view.threads[0].project_name = try transcript.Id.init("Project with a deliberately long name that must stop before hovered controls");
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        const bounds = layout.coding(720);
        try view.drawChrome(renderer, text, bounds, view.design.colors.foreground, view.design.colors.muted);
        _ = c.SDL_RenderPresent(renderer);
        const expected = c.SDL_DuplicateSurface(surface) orelse return error.Surface;
        defer c.SDL_DestroySurface(expected);
        const action = view.sidebar_action_bounds[0][1];
        view.threads[0].project_name = .{};
        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        try view.drawChrome(renderer, text, bounds, view.design.colors.foreground, view.design.colors.muted);
        _ = c.SDL_RenderPresent(renderer);
        const row = view.thread_bounds[0];
        var y: c_int = @intFromFloat(row.y + 6);
        while (y < @as(c_int, @intFromFloat(row.y + 30))) : (y += 1) {
            var x: c_int = @intFromFloat(action.x);
            while (x < @as(c_int, @intFromFloat(row.x + row.w))) : (x += 1) {
                var a: [4]u8 = undefined;
                var b: [4]u8 = undefined;
                try std.testing.expect(c.SDL_ReadSurfacePixel(surface, x, y, &a[0], &a[1], &a[2], &a[3]));
                try std.testing.expect(c.SDL_ReadSurfacePixel(expected, x, y, &b[0], &b[1], &b[2], &b[3]));
                try std.testing.expectEqualSlices(u8, &a, &b);
            }
        }
    }
}
