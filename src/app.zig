const std = @import("std");
const createRenderer = @import("native/renderer.zig").createRenderer;
const c = @import("native/bindings.zig").c;
const Layout = @import("ui/clay.zig").Layout;
const Coding = @import("ui/coding.zig").View;
const build_options = @import("build_options");
const telemetry = @import("native/metrics.zig");
const automation = @import("native/automation.zig");
const domain = @import("domain.zig");
const types = @import("domain/types.zig");
const contract = @import("contract.zig");
const presentation = @import("content/presentation.zig");
const Id = @import("ui/transcript.zig").Id;
const script = @import("script.zig");
const design = @import("ui/design.zig");
const attachment_text = @import("text/attachments.zig");
const inspection = @import("domain/inspection.zig");

fn fontPath(directory: []const u8, name: []const u8, buffer: []u8) ![:0]const u8 {
    if (!std.fs.path.isAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidFontDirectory;
    return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ directory, name }) catch error.FontPathTooLong;
}

/// Only a payload-free wake crosses worker threads. Registered after SDL init;
/// its storage and SDL outlive both Host and presentation worker joins.
pub const Wake = struct {
    event_type: u32,
    pub fn notify(context: ?*anyopaque) void {
        const self: *Wake = @ptrCast(@alignCast(context.?));
        var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        event.type = self.event_type;
        _ = c.SDL_PushEvent(&event);
    }
    pub fn presentationNotify(context: *anyopaque) void {
        notify(context);
    }
    pub fn scriptNotify(context: ?*anyopaque) callconv(.c) void {
        notify(context);
    }
};

fn setupTarget(id: []const u8, role: []const u8, bounds: c.SDL_FRect, open: bool) automation.Target {
    const enabled = open and bounds.w > 0 and bounds.h > 0;
    return .{ .id = id, .role = role, .key = "", .enabled = enabled, .pointer_bounds = if (enabled) .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) } else null };
}

/// Observations borrow stable copied ledger bytes through the next paint.
/// Iteration must borrow entries, never a temporary by-value loop capture.
fn observeWorkflowTargets(view: *const Coding, output: *[64]automation.Target) void {
    output.* = @splat(.{ .enabled = false });
    if (view.custom_root != null or !view.workflow_open) return;
    for (view.workflow_targets.slice(), 0..) |*target, i| {
        output[i] = setupTarget(target.id[0..target.id_len], target.role[0..target.role_len], target.bounds, target.enabled);
    }
}

/// Extend explicit live observations within the native consumer; the retained
/// base snapshot and final-export contract remain owned by native/automation.
const NavigationObservation = struct {
    snapshot: *const automation.Snapshot,
    view: *const Coding,

    pub fn jsonStringify(self: NavigationObservation, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        inline for (std.meta.fields(automation.Snapshot)) |field| {
            try writer.objectField(field.name);
            try writer.write(@field(self.snapshot, field.name));
        }
        try writer.objectField("navigation_targets");
        try writer.beginArray();
        for (self.view.navigation_targets.slice()) |target| {
            try writer.write(setupTarget(target.id[0..target.id_len], target.role[0..target.role_len], target.bounds, target.enabled));
        }
        try writer.endArray();
        try writer.objectField("workspace_open");
        try writer.write(self.view.workspace_open);
        try writer.objectField("workspace_busy");
        try writer.write(self.view.workspace_busy);
        try writer.objectField("workspace_stale");
        try writer.write(self.view.workspace_stale);
        try writer.objectField("workspace_file_count");
        try writer.write(self.view.workspace_file_count);
        try writer.objectField("workspace_diff_bytes");
        try writer.write(self.view.workspace_diff_len);
        try writer.objectField("workspace_diff_staged");
        try writer.write(self.view.workspace_diff_staged);
        try writer.objectField("workspace_revision");
        try writer.write(self.view.workspace_revision);
        try writer.objectField("thread_more_available");
        try writer.write(self.view.search_more_available);
        try writer.objectField("model_more_available");
        try writer.write(self.view.model_more_available);
        try writer.endObject();
    }
};

/// Native lifetime and input dispatch. Replaceable presentation owns no domain.
pub const App = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    text: *c.SpicaText,
    layout: Layout,
    view: Coding,
    running: bool = true,
    dirty: bool = true,
    minimized: bool = false,
    frames: u64 = 0,
    metrics: ?telemetry.Metrics = null,
    snapshot: automation.Snapshot = .{},
    conversation: ?*Conversation = null,
    live: ?*Live = null,

    lua: ?*LuaBridge = null,

    /// Bounded, content-free native diagnostic report. Null turn identity means
    /// the public Host rows do not expose it; it is never inferred from a run ID.
    pub fn sendDiagnosticReport(self: *const App, buffer: []u8) ![]const u8 {
        const evidence = &self.view.send_diagnostic;
        return types.encode(.{
            .version = @as(u32, 1),
            .stage = evidence.stage,
            .command_id = evidence.command_id[0..evidence.command_id_len],
            .ticket = evidence.ticket,
            .receipt = evidence.receipt,
            .rejection = evidence.rejection[0..evidence.rejection_len],
            .prompt_bytes = evidence.prompt_bytes,
            .frame_bytes = evidence.frame_bytes,
            .frame_limit = domain.start_frame_limit,
            .max_prompt_bytes = domain.startPreflight(0).max_prompt_bytes,
            .run_id = evidence.run_id[0..evidence.run_id_len],
            .session_id = evidence.session_id[0..evidence.session_id_len],
            .effect_id = evidence.effect_id[0..evidence.effect_id_len],
            .turn_id = @as(?[]const u8, null),
            .run_state = evidence.run_state[0..evidence.run_state_len],
            .provider_diagnostic = evidence.provider[0..evidence.provider_len],
            .current_draft_bytes = self.view.editor.len,
            .draft_revision = self.view.revision,
            .editor_focused = self.view.focused,
            .preedit_bytes = self.view.preedit_len,
            .send_ready = self.view.can_send,
            .send_enabled = self.view.can_send and self.view.editor.len != 0,
            .send_disabled_reason = self.view.send_disabled_reason,
        }, buffer);
    }

    /// Presentation-only API. Call on the App thread; values are validated and
    /// copied together before the next paint. Host and provider work are untouched.
    pub fn configurePresentation(self: *App, value: design.Config) !void {
        try value.validate();
        self.view.design = value;
        self.layout.design = value;
        self.dirty = true;
    }

    pub fn configureLua(self: *App, io: std.Io, path: []const u8, wake: *Wake) !void {
        const bridge = try self.view.allocator.create(LuaBridge);
        errdefer self.view.allocator.destroy(bridge);
        bridge.* = .{ .io = io, .path = path, .runtime = try script.Runtime.init(4 * 1024 * 1024, 100000, Wake.scriptNotify, wake) };
        self.lua = bridge;
        bridge.reload(self) catch |err| {
            self.view.notice = @errorName(err);
        };
    }
    const Live = struct { io: std.Io, file: std.Io.File, buffer: [2 * 1024 * 1024]u8 = undefined };

    pub fn enableLive(self: *App, io: std.Io, path: []const u8) !void {
        const live = try self.view.allocator.create(Live);
        errdefer self.view.allocator.destroy(live);
        live.* = .{ .io = io, .file = try std.Io.Dir.cwd().createFile(io, path, .{}) };
        self.live = live;
    }

    pub fn connect(self: *App, io: std.Io, host: *domain.Host, file: std.Io.File, wake: *Wake, workspace: []const u8) !void {
        self.conversation = try Conversation.create(self.view.allocator, io, host, file, wake, workspace);
        self.view.connected = true;
        self.view.status = "Opening durable conversation";
    }

    /// Explicit launch configuration only; never discovers accounts or sends a prompt.
    /// Paths stay in the existing owned launch configuration, outside bounded IDs.
    pub fn configureRuntime(self: *App, selection: contract.Selection, executable: []const u8) !void {
        const conversation = self.conversation orelse return error.NoConversation;
        var unbound = selection;
        unbound.workspace = .{ .value = "" };
        const identity = try Coding.Identity.from(unbound);
        if (!std.mem.eql(u8, selection.runtime_kind, "codex") and !std.mem.eql(u8, selection.runtime_kind, "opencode")) return error.UnsupportedRuntime;
        if (!self.view.configureSetup(.{
            .runtime_kind = if (std.mem.eql(u8, selection.runtime_kind, "codex")) .codex else .opencode,
            .executable = executable,
            .account_directory = selection.account_ref,
            .workspace_root = selection.workspace.value,
            .model_provider = selection.model_provider,
        })) conversation.notice(&self.view, "Launch configuration is active. A path exceeds the connection form's 512-byte limit; it was left empty, not shortened.");
        conversation.launch_selection = identity;
        conversation.configured_setup_key = Conversation.setupKey(Conversation.setupConfiguration(&self.view));
        conversation.catalog_refresh_pending = true;
        self.view.send_disabled_reason = "Loading configured provider models…";
    }

    /// Ordinary startup probes Host-owned saved configuration before creating a
    /// conversation. Defaults seed an editable form; they authorize no process.
    pub fn configureStartup(self: *App, defaults: [2]contract.RuntimeSetup) !void {
        const conversation = self.conversation orelse return error.NoConversation;
        conversation.normal_startup = true;
        conversation.startup_probe_pending = true;
        conversation.runtime_configured = false;
        self.view.selected = null;
        self.view.can_send = false;
        self.view.navigation_enabled = false;
        self.view.send_disabled_reason = "Choose a provider in Connection to get started.";
        self.view.status = "Loading saved connection";
        if (!self.view.setSetupDefaults(defaults)) conversation.notice(&self.view, "A default path exceeds the connection form's 512-byte limit. Open Advanced and enter a shorter explicit path.");
    }

    pub fn init(allocator: std.mem.Allocator) !App {
        return initWithFonts(allocator, build_options.font_directory);
    }

    pub fn initWithFonts(allocator: std.mem.Allocator, font_directory: []const u8) !App {
        // Native font records own paths with this same bound. Reuse one path
        // buffer: opening a face copies the path and retains its file handle.
        var font_path: [1024]u8 = undefined;
        const primary = try fontPath(font_directory, "Inter.ttf", &font_path);
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitialization;
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow("Spica", 1100, 740, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return error.WindowCreation;
        errdefer c.SDL_DestroyWindow(window);
        if (!c.SDL_SetWindowMinimumSize(window, 720, 480)) return error.WindowMinimumSize;
        const renderer = try createRenderer(window);
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, primary.ptr) orelse return error.FontInitialization;
        errdefer c.spica_text_destroy(text);
        // Preserve real faces and the engine's OS fallback path, shaping, bidi,
        // grapheme carets, bounded atlas, and device-pixel rasterization.
        if (!c.spica_text_set_monospace(text, (try fontPath(font_directory, "JetBrainsMono-Regular.ttf", &font_path)).ptr)) return error.FontInitialization;
        inline for (.{ "InterVariable-Italic.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf", "JetBrainsMono-BoldItalic.ttf" }) |font| {
            if (!c.spica_text_add_fallback(text, (try fontPath(font_directory, font, &font_path)).ptr, 0)) return error.FontInitialization;
        }
        var layout = try Layout.init(allocator, 1100, 740);
        errdefer layout.deinit();
        var view = try Coding.init(allocator);
        errdefer view.deinit();
        if (!c.SDL_StartTextInput(window)) return error.TextInputStart;
        std.log.info("Spica ready; renderer={s}; video={s}", .{ c.SDL_GetRendererName(renderer), c.SDL_GetCurrentVideoDriver() });
        return .{ .window = window, .renderer = renderer, .text = text, .layout = layout, .view = view };
    }

    /// Dispose replaceable presentation before Host join, retaining SDL/wake.
    pub fn disconnect(self: *App) void {
        if (self.lua) |bridge| {
            // Accepted actions reserve output slots. Drain/admit them while the
            // actual Host and wake still live, then join the protected worker.
            while (bridge.runtime.deinit()) |_| break else |_| {
                bridge.pump(self) catch |err| {
                    self.view.notice = @errorName(err);
                };
                c.SDL_Delay(1);
            }
            self.view.custom_root = null;
            self.view.custom_render = null;
            self.view.allocator.destroy(bridge);
            self.lua = null;
        }
        if (self.conversation) |conversation| conversation.destroy();
        self.conversation = null;
    }

    pub fn deinit(self: *App) void {
        if (self.live) |live| {
            live.file.close(live.io);
            self.view.allocator.destroy(live);
        }
        self.disconnect();
        self.view.deinit();
        self.layout.deinit();
        c.spica_text_destroy(self.text);
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn run(self: *App, quit_after_ms: ?u32) !void {
        const deadline: ?u64 = if (quit_after_ms) |ms| c.SDL_GetTicks() + ms else null;
        if (self.metrics) |*metrics| metrics.begin_ns = c.SDL_GetTicksNS();
        defer {
            if (self.metrics) |*metrics| metrics.end_ns = c.SDL_GetTicksNS();
            self.snapshot.running = false;
        }
        while (self.running) {
            if (deadline) |due| if (c.SDL_GetTicks() >= due) {
                self.snapshot.close_reason = "deadline";
                break;
            };
            if (self.conversation) |conversation| try conversation.pump(self);
            if (self.lua) |bridge| try bridge.pump(self);
            if (self.dirty and !self.minimized) {
                try self.paint();
                self.dirty = false;
            }
            var event: c.SDL_Event = undefined;
            var next_wake = deadline;
            if (self.conversation) |conversation| if (conversation.login_inflight and conversation.query == null and conversation.command == null) {
                next_wake = if (next_wake) |due| @min(due, conversation.login_poll_due) else conversation.login_poll_due;
            };
            if (next_wake) |due| {
                const now = c.SDL_GetTicks();
                if (now >= due) continue;
                const timeout: c_int = @intCast(@min(due - now, std.math.maxInt(c_int)));
                _ = c.SDL_ClearError();
                if (!c.SDL_WaitEventTimeout(&event, timeout)) {
                    if (c.SDL_GetError()[0] != 0) return error.EventWait;
                    continue;
                }
            } else if (!c.SDL_WaitEvent(&event)) return error.EventWait;
            try self.handle(event);
            while (c.SDL_PollEvent(&event)) try self.handle(event);
        }
        std.log.info("Spica foundation stopped; frames={d}", .{self.frames});
    }

    fn handle(self: *App, event: c.SDL_Event) !void {
        self.snapshot.event_sequence += 1;
        const before = if (self.metrics != null) self.textStats() else null;
        defer if (self.metrics) |*metrics| metrics.observeCache(self.snapshot.event_sequence, c.SDL_GetTicksNS(), before, self.textStats());
        switch (event.type) {
            c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                self.snapshot.close_reason = "window_close";
                self.running = false;
            },
            c.SDL_EVENT_KEY_DOWN => if (event.key.key == c.SDLK_Q and event.key.mod & c.SDL_KMOD_CTRL != 0) {
                self.snapshot.close_reason = "ctrl_q";
                self.running = false;
            },
            c.SDL_EVENT_WINDOW_RESIZED, c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED => {
                self.snapshot.resize_events += 1;
                self.snapshot.generation += 1;
                self.dirty = true;
            },
            c.SDL_EVENT_WINDOW_EXPOSED, c.SDL_EVENT_RENDER_TARGETS_RESET, c.SDL_EVENT_RENDER_DEVICE_RESET => self.dirty = true,
            c.SDL_EVENT_WINDOW_MINIMIZED => self.minimized = true,
            c.SDL_EVENT_WINDOW_RESTORED, c.SDL_EVENT_WINDOW_SHOWN => {
                self.minimized = false;
                self.dirty = true;
            },
            else => {},
        }
        if (event.type == c.SDL_EVENT_KEY_DOWN) {
            if (event.key.key == c.SDLK_C and event.key.mod & c.SDL_KMOD_CTRL != 0 and event.key.mod & c.SDL_KMOD_SHIFT != 0) {
                var report: [16 * 1024]u8 = undefined;
                @import("ui/clipboard.zig").copyBytes(try self.sendDiagnosticReport(&report), self.view.scratch) catch |err| {
                    self.view.notice = @errorName(err);
                    self.dirty = true;
                    return;
                };
                if (self.conversation) |conversation| conversation.notice(&self.view, "Send diagnostic copied. Prompt contents are omitted.");
                self.dirty = true;
                return;
            }
            if (self.lua) |bridge| {
                if (event.key.key == c.SDLK_F5) {
                    bridge.reload(self) catch |err| {
                        self.view.notice = @errorName(err);
                    };
                    self.dirty = true;
                    return;
                }
                if (event.key.key == c.SDLK_F9) {
                    bridge.active = !bridge.active;
                    bridge.epoch += 1;
                    try bridge.install(self);
                    self.dirty = true;
                    return;
                }
            }
        }
        const changed = self.view.handle(event, self.window, self.text) catch |err| switch (err) {
            error.TextTooLarge, error.PieceLimit, error.InvalidUtf8, error.ClipboardRead, error.ClipboardWrite, error.ClipboardContainsNul => blk: {
                self.view.notice = @errorName(err);
                self.snapshot.admission_errors += 1;
                self.snapshot.last_admission_error = @errorName(err);
                break :blk true;
            },
            else => return err,
        };
        if (self.view.workflow_action) |action| {
            self.view.workflow_action = null;
            if (self.conversation) |conversation| conversation.workflow(self, action) catch |err| {
                self.view.workflow_error = @errorName(err);
                self.view.workflowNotice(switch (err) {
                    error.FollowupCapabilityUnavailable => "The selected provider does not support follow-ups. Your draft is retained.",
                    error.NoLiveRun => "Follow-ups need a live run in this chat. Your draft is retained.",
                    error.AbsoluteFilePathRequired => "Enter an absolute file path before adding a file.",
                    error.FollowupDraftSize => "Write a shorter follow-up (up to 4096 bytes). Your draft is retained.",
                    error.AttachmentDeliveryUnavailable => "Remove local files before queueing; this provider cannot receive them.",
                    error.KeepOrClearCurrentDraftBeforeEditing => "Keep or clear the current composer draft before editing a follow-up.",
                    error.FollowupAlreadyDispatched => "This follow-up has already left the queue and cannot be changed.",
                    else => "The action is unavailable in the current chat state. Your draft is retained.",
                });
            } else self.view.workflowNotice("No connected Host; draft retained.");
        }
        if (self.view.navigation) |navigation| {
            self.view.navigation = null;
            if (self.conversation) |conversation| conversation.navigateWorkspace(self, navigation) catch |err| {
                self.view.notice = @errorName(err);
            };
        }
        if (self.view.title_action) |action| {
            self.view.title_action = null;
            if (action == .cancel) {
                self.view.title_editing = false;
            } else if (self.conversation) |conversation| conversation.rename(self) catch |err| {
                self.view.notice = @errorName(err);
            };
        }
        if (self.view.takeWorkspaceDiffRequest()) |file| if (self.conversation) |conversation| conversation.requestInspectionDiff(&self.view, file);
        if (self.view.takeWorkspaceRefreshRequest()) if (self.conversation) |conversation| if (conversation.inspection_binding) |binding| conversation.requestInspectionStatus(&self.view, binding);
        if (self.view.setup_action) |action| {
            self.view.setup_action = null;
            if (self.conversation) |conversation| conversation.setup(self, action) catch |err| {
                self.view.notice = @errorName(err);
            };
        }
        if (self.view.history_move) |move| {
            self.view.history_move = null;
            if (self.conversation) |conversation| conversation.navigate(self, move) catch |err| {
                self.view.notice = @errorName(err);
            };
        }
        if (self.view.copy_selection) |selection| {
            self.view.copy_selection = null;
            if (self.conversation) |conversation| {
                conversation.copy_pending = selection;
                Wake.notify(conversation.wake);
            }
        }
        if (self.view.takeIntent()) |intent| {
            if (self.lua) |bridge| {
                if (bridge.active and self.view.custom_root != null and bridge.generation != 0 and intent == .send) {
                    bridge.queue(self, try script.id("send"), .send) catch |err| {
                        self.view.notice = @errorName(err);
                    };
                } else if (self.conversation) |conversation| conversation.act(self, intent) catch |err| {
                    self.view.notice = @errorName(err);
                };
            } else if (self.conversation) |conversation| conversation.act(self, intent) catch |err| {
                self.view.notice = @errorName(err);
            };
        }
        if (self.view.takeTaskCancel()) |cancel| if (self.conversation) |conversation| {
            conversation.submit(.cancel, .{ .run = .{ .value = &cancel.id } }, .{ .revision = cancel.revision }, .{ .task_cancel = .{ .reason = "Native task cancellation" } }, 0) catch |err| {
                self.view.notice = @errorName(err);
            };
        };
        if (self.view.custom_action) |index| {
            self.view.custom_action = null;
            if (self.lua) |bridge| {
                const action = bridge.root.nodes[index].action;
                const name = action.bytes[0..action.len];
                const intent: @import("ui/coding.zig").Intent = if (std.mem.eql(u8, name, "cancel")) .cancel else if (std.mem.eql(u8, name, "approve")) .allow else if (std.mem.eql(u8, name, "deny")) .deny else .send;
                bridge.queue(self, action, intent) catch |err| {
                    self.view.notice = @errorName(err);
                };
            }
        }
        self.dirty = self.dirty or changed;
    }

    fn textStats(self: *const App) ?telemetry.TextStats {
        var stats: c.SpicaTextStats = undefined;
        if (!c.spica_text_get_stats(self.text, &stats)) return null;
        return .{
            .fixed_cpu_bytes = stats.fixed_cpu_bytes,
            .font_bytes = stats.font_bytes,
            .layout_bytes = stats.layout_bytes,
            .glyph_bytes = stats.glyph_bytes,
            .live_layouts = stats.live_layouts,
            .glyph_count = stats.glyph_count,
            .face_count = stats.face_count,
        };
    }

    fn paint(self: *App) !void {
        const paint_begin = if (self.metrics != null) c.SDL_GetTicksNS() else 0;
        var width: c_int = 0;
        var height: c_int = 0;
        var pixel_width: c_int = 0;
        var pixel_height: c_int = 0;
        if (!c.SDL_GetWindowSize(self.window, &width, &height) or !c.SDL_GetRenderOutputSize(self.renderer, &pixel_width, &pixel_height)) return error.WindowSize;
        if (width <= 0 or height <= 0 or pixel_width <= 0 or pixel_height <= 0) return;
        self.snapshot.logical_width = width;
        self.snapshot.logical_height = height;
        self.snapshot.output_width = pixel_width;
        self.snapshot.output_height = pixel_height;
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        const scale_x = @as(f32, @floatFromInt(pixel_width)) / w;
        const scale_y = @as(f32, @floatFromInt(pixel_height)) / h;
        if (!c.SDL_SetRenderScale(self.renderer, scale_x, scale_y) or !c.spica_text_set_render_scale(self.text, scale_x, scale_y)) return error.RenderScale;
        self.layout.resize(w, h);
        const coding_bounds = if (self.view.custom_root) |root| self.layout.script(root, &self.view.custom_bounds) else self.layout.coding(w);
        try self.view.draw(self.renderer, self.text, self.window, coding_bounds);
        self.snapshot.draft = self.view.editor.textBytes();
        self.snapshot.presentation = self.view.design;
        if (self.lua) |bridge| {
            self.snapshot.presentation_active = bridge.active and bridge.generation != 0;
            self.snapshot.custom_root = self.view.custom_root != null;
            self.snapshot.script_generation = bridge.generation;
            self.snapshot.script_error = if (bridge.error_text[0] != 0) std.mem.sliceTo(&bridge.error_text, 0) else null;
            self.snapshot.custom_render = if (self.view.custom_render) |render| render.bytes[0..render.len] else "";
            self.snapshot.pending_script_action = bridge.pending != null;
        }
        self.snapshot.caret = self.view.editor.caret;
        self.snapshot.anchor = self.view.editor.anchor;
        self.snapshot.editor_focused = self.view.focused and !self.view.workflow_open and !self.view.search_focused and !self.view.setup_open and !self.view.workspace_open and !self.view.picker_open and !self.view.effort_open;
        self.snapshot.preedit_bytes = self.view.preedit_len;
        self.snapshot.draft_revision = self.view.revision;
        const editor_bounds = self.view.editor_view.bounds;
        self.snapshot.targets[1].enabled = editor_bounds.w > 0 and editor_bounds.h > 0;
        self.snapshot.targets[1].pointer_bounds = .{ @intFromFloat(editor_bounds.x), @intFromFloat(editor_bounds.y), @intFromFloat(editor_bounds.w), @intFromFloat(editor_bounds.h) };
        self.snapshot.connected = self.view.connected;
        self.snapshot.run_status = self.view.status;
        self.snapshot.visible_rich_blocks = self.view.rich_count;
        for (self.view.controls, 0..) |bounds, index| {
            self.snapshot.targets[index + 2].pointer_bounds = .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) };
            self.snapshot.targets[index + 2].enabled = switch (index) {
                0 => self.view.can_send and self.view.editor.len != 0,
                1 => self.view.can_cancel,
                else => self.view.can_approve,
            };
        }
        const extra_bounds = [_]c.SDL_FRect{ self.view.new_project_bounds, self.view.new_thread_bounds, self.view.picker_bounds, self.view.effort_bounds, self.view.setup_bounds };
        for (extra_bounds, 6..) |bounds, index| {
            self.snapshot.targets[index].pointer_bounds = .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) };
            self.snapshot.targets[index].enabled = self.view.custom_root == null and (index >= 8 or self.view.navigation_enabled);
        }
        self.snapshot.thread_targets = @splat(.{ .enabled = false });
        for (self.view.threads[0..self.view.thread_count], 0..) |*entry, index| {
            const bounds = self.view.threadRowBounds(index);
            self.snapshot.thread_targets[index] = .{ .id = entry.id.slice(), .role = "thread", .enabled = self.view.custom_root == null and self.view.navigation_enabled and bounds.w > 0 and bounds.h > 0, .pointer_bounds = .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) } };
        }
        self.snapshot.title_editing = self.view.title_editing;
        self.snapshot.title_text = if (self.view.title_editing) self.view.title_buffer[0..self.view.title_len] else blk: {
            var current: []const u8 = "";
            for (self.view.threads[0..self.view.thread_count]) |*entry| {
                if (entry.id.eql(self.view.active_thread.slice())) current = entry.label[0..entry.len];
            }
            break :blk current;
        };
        self.snapshot.title_target = .{ .id = "thread.title.edit", .role = "textbox", .key = "F2", .enabled = self.view.titleEditAvailable() and self.view.title_bounds.w > 0 and self.view.title_bounds.h > 0, .pointer_bounds = .{ @intFromFloat(self.view.title_bounds.x), @intFromFloat(self.view.title_bounds.y), @intFromFloat(self.view.title_bounds.w), @intFromFloat(self.view.title_bounds.h) } };
        self.snapshot.sidebar_search = self.view.search_query[0..self.view.search_len];
        self.snapshot.sidebar_search_focused = self.view.search_focused;
        self.snapshot.sidebar_scope_open = self.view.scope_open;
        self.snapshot.sidebar_scope_project = self.view.scope_project.slice();
        self.snapshot.effort_open = self.view.effort_open;
        const sidebar_bounds = [_]c.SDL_FRect{ self.view.search_bounds, self.view.scope_bounds };
        for (sidebar_bounds, 0..) |bounds, index| {
            self.snapshot.sidebar_targets[index] = .{ .id = if (index == 0) "sidebar.search" else "sidebar.scope", .role = if (index == 0) "textbox" else "button", .key = "", .enabled = self.view.custom_root == null and bounds.w > 0 and bounds.h > 0, .pointer_bounds = .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) } };
        }
        self.snapshot.scope_targets = @splat(.{ .enabled = false });
        for (0..self.view.project_count + 1) |index| {
            const bounds = if (index == 0) self.view.scope_all_bounds else self.view.project_bounds[index - 1];
            const enabled = self.view.custom_root == null and self.view.scope_open and bounds.w > 0 and bounds.h > 0;
            self.snapshot.scope_targets[index] = .{ .id = if (index == 0) "scope.all" else self.view.projects[index - 1].id.slice(), .role = "menuitem", .key = "", .enabled = enabled, .pointer_bounds = if (enabled) .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) } else null };
        }
        self.snapshot.effort_targets = @splat(.{ .enabled = false });
        for (self.view.effort_rows, 0..) |bounds, index| {
            const enabled = self.view.custom_root == null and self.view.effort_open and bounds.w > 0 and bounds.h > 0;
            self.snapshot.effort_targets[index] = .{ .id = "effort.option", .role = "menuitem", .key = "", .enabled = enabled, .pointer_bounds = if (enabled) .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) } else null };
        }
        const present_begin = if (self.metrics != null) c.SDL_GetTicksNS() else 0;
        const succeeded = c.SDL_RenderPresent(self.renderer);
        const present_end = if (self.metrics != null) c.SDL_GetTicksNS() else 0;
        if (self.metrics) |*metrics| {
            // Accessor only copies the existing ledger. Sampling is outside the
            // measured paint/present interval and never schedules idle redraws.
            var stats: c.SpicaTextStats = undefined;
            const stats_ok = c.spica_text_get_stats(self.text, &stats);
            metrics.record(.{
                .frame_id = self.frames + 1,
                .event_sequence = self.snapshot.event_sequence,
                .paint_begin_ns = paint_begin,
                .present_begin_ns = present_begin,
                .present_end_ns = present_end,
                .succeeded = succeeded,
                .text_stats = if (stats_ok) .{
                    .fixed_cpu_bytes = stats.fixed_cpu_bytes,
                    .font_bytes = stats.font_bytes,
                    .layout_bytes = stats.layout_bytes,
                    .glyph_bytes = stats.glyph_bytes,
                    .live_layouts = stats.live_layouts,
                    .glyph_count = stats.glyph_count,
                    .face_count = stats.face_count,
                } else null,
            });
        }
        if (!succeeded) return error.RenderPresent;
        self.frames += 1;
        self.snapshot.frame_id = self.frames;
        self.snapshot.generation = self.frames;
        if (self.conversation) |conversation| {
            self.snapshot.thread_id = conversation.thread.slice();
            self.snapshot.project_id = conversation.project.slice();
            self.snapshot.run_id = conversation.run.slice();
            self.snapshot.approval_id = if (conversation.approval_live) conversation.approval.slice() else "";
            self.snapshot.pending_command = conversation.command != null;
            self.snapshot.workspace_root = conversation.workspace_root;
            self.snapshot.login_pending = conversation.login_inflight;
        }
        self.snapshot.transcript = @splat("");
        self.snapshot.transcript_roles = @splat("");
        self.snapshot.transcript_message_ids = @splat("");
        self.snapshot.transcript_geometry = @splat(.{ 0, 0, 0, 0 });
        for (self.view.rich_tiles[0..self.view.rich_count], 0..) |*tile, index| {
            self.snapshot.transcript[index] = tile.rendered[0..tile.length];
            self.snapshot.transcript_roles[index] = tile.role;
            self.snapshot.transcript_message_ids[index] = tile.message.slice();
            self.snapshot.transcript_ordinals[index] = tile.message_ordinal;
            self.snapshot.transcript_geometry[index] = .{ tile.bounds.x, tile.bounds.y, tile.bounds.w, tile.bounds.h };
        }
        self.snapshot.transcript_scroll = self.view.transcript_scroll;
        self.snapshot.transcript_height = self.view.history_height;
        self.snapshot.follow_latest = self.view.follow_latest;
        self.snapshot.project_count = self.view.project_count;
        self.snapshot.thread_count = self.view.thread_count;
        self.snapshot.model_count = self.view.model_count;
        self.snapshot.send_ready = self.view.can_send;
        self.snapshot.send_disabled_reason = self.view.send_disabled_reason;
        self.snapshot.send_stage = @tagName(self.view.send_diagnostic.stage);
        self.snapshot.send_receipt = @tagName(self.view.send_diagnostic.receipt);
        self.snapshot.send_prompt_bytes = self.view.send_diagnostic.prompt_bytes;
        self.snapshot.send_frame_bytes = self.view.send_diagnostic.frame_bytes;
        self.snapshot.send_command_id = self.view.send_diagnostic.command_id[0..self.view.send_diagnostic.command_id_len];
        self.snapshot.send_effect_id = self.view.send_diagnostic.effect_id[0..self.view.send_diagnostic.effect_id_len];
        self.snapshot.send_run_id = self.view.send_diagnostic.run_id[0..self.view.send_diagnostic.run_id_len];
        self.snapshot.send_session_id = self.view.send_diagnostic.session_id[0..self.view.send_diagnostic.session_id_len];
        self.snapshot.send_rejection = self.view.send_diagnostic.rejection[0..self.view.send_diagnostic.rejection_len];
        self.snapshot.send_provider_diagnostic = self.view.send_diagnostic.provider[0..self.view.send_diagnostic.provider_len];
        self.snapshot.workflow_open = self.view.workflow_open;
        self.snapshot.workflow_busy = self.view.workflow_busy;
        self.snapshot.workflow_path_focused = self.view.workflow_open and self.view.workflow_path_focus;
        self.snapshot.workflow_path = self.view.workflow_path[0..self.view.workflow_path_len];
        self.snapshot.workflow_feedback = self.view.workflow_feedback[0..self.view.workflow_feedback_len];
        self.snapshot.workflow_error = self.view.workflow_error;
        self.snapshot.workflow_run_id = self.view.workflow_run.slice();
        self.snapshot.attachment_count = self.view.attachments.count;
        self.snapshot.attachment_bytes = self.view.attachments.content_bytes;
        self.snapshot.attachment_names = @splat("");
        for (0..attachment_text.max_count) |i| if (self.view.attachments.get(i)) |file| {
            self.snapshot.attachment_names[i] = file.metadata.name;
        };
        self.snapshot.followup_ids = @splat("");
        self.snapshot.followup_states = @splat("");
        self.snapshot.followup_revisions = @splat(0);
        for (self.view.followups[0..self.view.followup_count], 0..) |*item, i| {
            self.snapshot.followup_ids[i] = item.id.slice();
            self.snapshot.followup_states[i] = @tagName(item.state);
            self.snapshot.followup_revisions[i] = item.revision;
        }
        if (self.conversation) |conversation| self.snapshot.followup_capability = @tagName(conversation.followup_capability);
        self.snapshot.workflow_target = setupTarget("workflow.open", "button", self.view.workflow_button, self.view.custom_root == null and !self.view.setup_open and !self.view.workspace_open);
        self.snapshot.workflow_target.key = "F10";
        observeWorkflowTargets(&self.view, &self.snapshot.workflow_targets);
        if (self.view.workflow_open and self.view.custom_root == null) {
            for (self.snapshot.targets[1..]) |*target| target.enabled = false;
            for (&self.snapshot.thread_targets) |*target| target.enabled = false;
            for (&self.snapshot.sidebar_targets) |*target| target.enabled = false;
        }
        self.snapshot.picker_open = self.view.picker_open;
        self.snapshot.setup_open = self.view.setup_open;
        self.snapshot.setup_runtime = @tagName(self.view.setup_runtime);
        self.snapshot.runtime_info = self.view.runtime_info[0..self.view.runtime_info_len];
        self.snapshot.login_url = self.view.login_url[0..self.view.login_url_len];
        self.snapshot.login_code = self.view.login_code[0..self.view.login_code_len];
        for (self.view.setup_provider_bounds, 0..) |bounds, index| self.snapshot.setup_provider_targets[index] = setupTarget(if (index == 0) "runtime.codex" else "runtime.opencode", "button", bounds, self.view.setup_open);
        for (self.view.setup_field_bounds, 0..) |bounds, index| self.snapshot.setup_field_targets[index] = setupTarget(([_][]const u8{ "runtime.executable", "runtime.account", "runtime.workspace", "runtime.model_provider" })[index], "textbox", bounds, self.view.setup_open);
        self.snapshot.setup_advanced_target = setupTarget("runtime.advanced", "button", self.view.setup_advanced_bounds, self.view.setup_open);
        self.snapshot.setup_existing_target = setupTarget("runtime.existing_codex", "button", self.view.setup_existing_bounds, self.view.setup_open and self.view.existingCodexEnabled());
        self.snapshot.setup_login_target = setupTarget("runtime.open_login", "button", self.view.setup_login_bounds, self.view.setup_open and self.view.login_url_len != 0);
        const setup_ids = [_][]const u8{ "runtime.configure", "runtime.browser", "runtime.device", "runtime.refresh" };
        for (self.view.setup_button_bounds, 0..) |bounds, index| {
            const enabled = self.view.custom_root == null and self.view.setup_open and bounds.w > 0 and bounds.h > 0 and self.view.setupActionEnabled(index);
            self.snapshot.setup_targets[index] = .{ .id = setup_ids[index], .role = "button", .key = "", .enabled = enabled, .pointer_bounds = if (enabled) .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) } else null };
        }
        for (0..4) |index| self.snapshot.setup_fields[index] = self.view.setup_fields[index][0..self.view.setup_lengths[index]];
        self.snapshot.thread_labels = @splat("");
        self.snapshot.thread_projects = @splat("");
        self.snapshot.thread_branches = @splat("");
        self.snapshot.thread_run_states = @splat("");
        for (self.view.threads[0..self.view.thread_count], 0..) |*entry, index| {
            self.snapshot.thread_labels[index] = entry.label[0..entry.len];
            self.snapshot.thread_projects[index] = entry.project_id.slice();
            self.snapshot.thread_branches[index] = entry.branch.slice();
            self.snapshot.thread_run_states[index] = @tagName(entry.run_status);
        }
        self.snapshot.selected_runtime = "";
        self.snapshot.selected_model = "";
        self.snapshot.selected_effort = "";
        self.snapshot.notice = self.view.notice;
        if (self.view.selected) |*selected| {
            self.snapshot.selected_runtime = selected.runtime_kind.slice();
            self.snapshot.selected_model = selected.model_id.slice();
            self.snapshot.selected_effort = selected.effort.slice();
        }
        if (self.live) |live| {
            // Explicit automation only. Fixed storage, after measured present,
            // no timers/input endpoints; observers may retry a partial write.
            var writer = std.Io.Writer.fixed(&live.buffer);
            try std.json.Stringify.value(NavigationObservation{ .snapshot = &self.snapshot, .view = &self.view }, .{}, &writer);
            try live.file.writePositionalAll(live.io, writer.buffered(), 0);
            try live.file.setLength(live.io, writer.buffered().len);
        }
    }
};

/// Descriptor and proposal ownership; provider lifetime remains in main's Host.
const LuaBridge = struct {
    io: std.Io,
    path: []const u8,
    runtime: script.Runtime,
    sequence: u64 = 0,
    visual_sequence: u64 = 0,
    reload_pending: bool = false,
    generation: u64 = 0,
    epoch: u64 = 0,
    active: bool = true,
    root: script.Root = undefined,
    render: script.Render = undefined,
    result: script.Result = undefined,
    snapshot: script.Snapshot = std.mem.zeroes(script.Snapshot),
    observed_generation: u64 = std.math.maxInt(u64),
    observed_count: usize = std.math.maxInt(usize),
    observed_revision: u64 = std.math.maxInt(u64),
    error_text: [256]u8 = @splat(0),
    pending: ?Pending = null,

    const Pending = struct {
        sequence: u64,
        generation: u64,
        epoch: u64,
        context: script.ActionContext,
        workspace: Id,
        thread_revision: u64,
        run_revision: u64,
        approval_revision: u64,
        draft_revision: u64,
        command_id: [32]u8,
        selection: ?Coding.Identity = null,
    };

    fn visible(self: *LuaBridge, app: *App) void {
        self.snapshot = std.mem.zeroes(script.Snapshot);
        if (app.conversation) |conversation| self.snapshot.revision = conversation.thread_revision;
        for (0..app.view.rich_count) |offset| {
            const index = if (app.view.rich_count == app.view.rich_tiles.len) (app.view.rich_next + offset) % app.view.rich_tiles.len else offset;
            const tile = &app.view.rich_tiles[index];
            var end = @min(tile.length, self.snapshot.text.bytes.len - self.snapshot.text.len);
            while (end != 0 and !std.unicode.utf8ValidateSlice(tile.rendered[0..end])) end -= 1;
            @memcpy(self.snapshot.text.bytes[self.snapshot.text.len..][0..end], tile.rendered[0..end]);
            self.snapshot.text.len += end;
        }
    }

    fn reload(self: *LuaBridge, app: *App) !void {
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, self.path, app.view.allocator, .limited(script.abi.SPICA_SCRIPT_SOURCE));
        defer app.view.allocator.free(source);
        self.visible(app);
        self.sequence += 1;
        try self.runtime.reload(self.sequence, source, &self.snapshot);
        self.visual_sequence = self.sequence;
        self.reload_pending = true;
    }

    fn install(self: *LuaBridge, app: *App) !void {
        const installed = self.active and self.generation != 0;
        const candidate: design.Config = if (installed) try design.Config.fromScript(&self.root) else .{};
        try app.configurePresentation(candidate);
        // A native root keeps the full conversation and its ordinary commands.
        // It opts into presentation settings without replacing content/actions.
        const custom = installed and !(self.root.count == 1 and self.root.nodes[0].kind == 6);
        app.view.custom_root = if (custom) &self.root else null;
        app.view.custom_render = if (custom) &self.render else null;
    }

    fn queue(self: *LuaBridge, app: *App, action: script.Id, intent: @import("ui/coding.zig").Intent) !void {
        if (!self.active or self.generation == 0) return error.NoCustomRoot;
        if (self.pending != null) return error.ScriptActionPending;
        const conversation = app.conversation orelse return error.NoConversation;
        if (conversation.command != null) return error.CommandPending;
        const enabled = switch (intent) {
            .send => app.view.can_send,
            .cancel => app.view.can_cancel,
            .allow, .deny => app.view.can_approve,
        };
        if (!enabled) return error.ActionUnavailable;
        const context: script.ActionContext = .{
            .thread_id = try script.id(conversation.thread.slice()),
            .run_id = try script.id(conversation.run.slice()),
            .approval_id = try script.id(conversation.approval.slice()),
            .action_digest = try script.id(conversation.approval_digest.slice()),
            .selection = try script.id(conversation.workspace.slice()),
            .revision = switch (intent) {
                .send => conversation.thread_revision,
                .cancel => conversation.run_revision,
                .allow, .deny => conversation.approval_revision,
            },
        };
        const payload = try script.text(if (intent == .send) app.view.editor.textBytes() else "");
        const command_id = try conversation.commandId();
        self.sequence += 1;
        try self.runtime.action(self.sequence, self.generation, &action, &payload, &context);
        self.pending = .{
            .sequence = self.sequence,
            .generation = self.generation,
            .epoch = self.epoch,
            .context = context,
            .workspace = conversation.workspace,
            .selection = app.view.selected,
            .thread_revision = conversation.thread_revision,
            .run_revision = conversation.run_revision,
            .approval_revision = conversation.approval_revision,
            .draft_revision = app.view.revision,
            .command_id = command_id,
        };
    }

    fn admit(self: *LuaBridge, app: *App, result: *const script.Result, pending: Pending) !void {
        if (!self.active or pending.epoch != self.epoch or result.generation != self.generation or result.generation != pending.generation) return error.ObsoleteScriptAction;
        if (!std.meta.eql(pending.context, result.intent.context)) return error.ScriptContextChanged;
        const conversation = app.conversation orelse return error.NoConversation;
        const context = &pending.context;
        switch (result.intent.kind) {
            1 => try conversation.sendIdentified(app, .{ .thread = .{ .value = context.thread_id.bytes[0..context.thread_id.len] } }, .{ .revision = pending.thread_revision }, result.intent.text.bytes[0..result.intent.text.len], if (pending.selection) |*selection| selection.selection() else return error.ChooseModel, pending.draft_revision, pending.command_id),
            2 => try conversation.submitIdentified(.cancel, .{ .run = .{ .value = context.run_id.bytes[0..context.run_id.len] } }, .{ .revision = pending.run_revision }, .{ .run_cancel = .{ .reason = "Custom root cancellation" } }, 0, pending.command_id),
            3, 4 => try conversation.submitIdentified(.approval, .{ .approval = .{ .value = context.approval_id.bytes[0..context.approval_id.len] } }, .{ .revision = pending.approval_revision }, .{ .approval_respond = .{ .decision = if (result.intent.kind == 3) .allow else .deny, .action_digest = context.action_digest.bytes[0..context.action_digest.len] } }, 0, pending.command_id),
            else => return error.InvalidScriptIntent,
        }
    }

    fn pump(self: *LuaBridge, app: *App) !void {
        while (self.runtime.poll(&self.result)) {
            const result = &self.result;
            app.dirty = true;
            if (result.kind == 3) {
                const pending = self.pending orelse return error.UnexpectedScriptAction;
                if (pending.sequence != result.sequence) return error.UnexpectedScriptSequence;
                self.pending = null;
                if (result.status == 0) self.admit(app, result, pending) catch |err| {
                    app.view.notice = @errorName(err);
                };
            } else if (result.sequence >= self.visual_sequence) {
                if (result.kind == 1) {
                    self.reload_pending = false;
                    // Refresh the snapshot after staging, even if Host output
                    // changed while the module was being evaluated.
                    self.observed_revision = std.math.maxInt(u64);
                }
                if (result.status == 0) {
                    self.root = result.root;
                    self.render = result.render;
                    self.generation = result.generation;
                    app.view.custom_render_sequence += 1;
                    try self.install(app);
                    if (result.kind == 1) self.error_text = @splat(0);
                    if (self.error_text[0] == 0) app.view.notice = null;
                }
            }
            if (result.status != 0) {
                self.error_text = result.@"error";
                app.view.notice = std.mem.sliceTo(&self.error_text, 0);
            }
        }
        if (app.conversation) |conversation| {
            if (!self.reload_pending and (self.observed_generation != conversation.generation or self.observed_count != app.view.rich_count or self.observed_revision != conversation.thread_revision)) {
                self.observed_generation = conversation.generation;
                self.observed_count = app.view.rich_count;
                self.observed_revision = conversation.thread_revision;
                self.visible(app);
                if (self.generation != 0) {
                    self.sequence += 1;
                    try self.runtime.render(self.sequence, &self.snapshot);
                    self.visual_sequence = self.sequence;
                }
            }
        }
    }
};

/// Native public-Host consumer, independent of replaceable root lifetime.
/// One query, one mutation, one parse and one visible-tile request at a time.
/// Every borrowed output is consumed/copied before drain storage is reused.
const Conversation = struct {
    const PendingCommand = struct { ticket: types.Ticket, kind: CommandKind, draft_revision: u64, id: [32]u8 };
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *domain.Host,
    worker: *presentation.Worker,
    wake: *Wake,
    workspace_root: []u8,
    attachment_loader: ?*attachment_text.Loader = null,
    attachment_loading: bool = false,
    attachment_thread: Id = .{},
    inspection_worker: ?*inspection.Worker = null,
    inspection_binding_storage: [6][4096]u8 = undefined,
    inspection_binding_lengths: [6]usize = @splat(0),
    inspection_binding: ?inspection.WorkspaceBinding = null,
    inspection_revision: u64 = 0,
    inspection_pending: bool = false,
    inspection_workspace: Id = .{},
    inspection_request: ?InspectionRequest = null,
    drain_storage: [1024 * 1024]u8 = undefined,
    source: [presentation.source_limit]u8 = undefined,
    source_len: usize = 0,
    completion: presentation.Completion = undefined,
    project: Id = .{},
    workspace: Id = .{},
    workspace_branch: Id = .{},
    thread: Id = .{},
    thread_revision: u64 = 0,
    title_pending: [types.max_title_bytes]u8 = undefined,
    title_pending_len: usize = 0,
    card_rows_seen: usize = 0,
    /// Cursor retained after the resident thread-card budget is full. Search
    /// can advance through bounded Host pages without growing the UI arrays.
    thread_page_snapshot: ?types.SnapshotId = null,
    thread_page_cursor: ?Id = null,
    thread_page_anchor: ?Id = null,
    create_thread_after_workspace: bool = false,
    run: Id = .{},
    run_revision: u64 = 0,
    run_state: ?types.RunState = null,
    approval: Id = .{},
    approval_revision: u64 = 0,
    approval_digest: Id = .{},
    approval_live: bool = false,
    subscription: ?types.SubscriptionId = null,
    subscribe_ticket: ?types.Ticket = null,
    query: ?struct { ticket: types.Ticket, kind: QueryKind } = null,
    command: ?PendingCommand = null,
    unknown_send: ?PendingCommand = null,
    receipt_lookup_attempted: bool = false,
    refresh: bool = false,
    generation: u64 = 0,
    messages: [8]Id = undefined,
    message_roles: [8]@FieldType(@FieldType(types.Row, "message"), "role") = @splat(.assistant),
    message_ordinals: [8]u64 = @splat(0),
    message_count: usize = 0,
    message_index: usize = 0,
    blocks: [8]struct { id: Id, revision: u64, bytes: u64, ordinal: u64 } = undefined,
    block_count: usize = 0,
    block_index: usize = 0,
    worker_key: ?presentation.Key = null,
    projected_key: ?presentation.Key = null,
    pending_history_move: ?Coding.HistoryMove = null,
    source_pending: bool = false,
    tile_request: ?presentation.PageRequest = null,
    runs_cursor: ?Id = null,
    runs_snapshot: ?types.SnapshotId = null,
    history_paused: bool = false,
    history_first: ?struct { key: presentation.Key, cursor: presentation.Cursor, ordinal: u64 } = null,
    history_start: ?presentation.PageRequest = null,
    desired_block: ?u64 = null,
    block_cursor: ?Id = null,
    block_snapshot: ?types.SnapshotId = null,
    message_anchor: ?Id = null,
    message_direction: types.Direction = .older,
    message_snapshot: ?types.SnapshotId = null,
    history_retrying: bool = false,
    recovery_block: ?Id = null,
    copy_pending: ?presentation.Selection = null,
    restored_pixel: ?f32 = null,
    restored_revision: ?u64 = null,
    normal_startup: bool = false,
    startup_probe_pending: bool = false,
    bootstrap_after_catalog: bool = false,
    runtime_configured: bool = false,
    startup_runtime: ?contract.RuntimeKind = null,
    startup_account: [4096]u8 = undefined,
    startup_account_len: usize = 0,
    close_setup_after_refresh: bool = false,
    configuration_pending: bool = false,
    configured_setup_key: ?[32]u8 = null,
    submitted_setup_key: ?[32]u8 = null,
    setup_login_after_configure: ?contract.RuntimeLogin = null,
    launch_selection: ?Coding.Identity = null,
    login_inflight: bool = false,
    login_poll_due: u64 = 0,
    catalog_refresh_pending: bool = false,
    catalog_refresh_inflight: bool = false,
    catalog_truncated: bool = false,
    durable_selection: ?Coding.Identity = null,
    attempted_selection: ?Coding.Identity = null,
    notice_storage: [1024]u8 = undefined,
    diagnostic_storage: [1024]u8 = undefined,
    diagnostic_display: [1024]u8 = undefined,
    diagnostic_len: usize = 0,
    preflight_storage: [192]u8 = undefined,
    followup_capability: contract.Status = .unknown,
    capability_runtime: Id = .{},
    workflow_pending: struct {
        thread: Id = .{},
        run: Id = .{},
        id: Id = .{},
        content: [4096]u8 = undefined,
        len: usize = 0,
        attachment_index: usize = 0,
        order: [8]contract.FollowupId = undefined,
        order_ids: [8]Id = undefined,
        order_count: usize = 0,
    } = .{},

    const InspectionRequest = struct {
        revision: u64,
        file: ?Coding.WorkspaceFile = null,
        staged: bool = false,
    };

    fn notice(self: *Conversation, view: *Coding, message: []const u8) void {
        const bounded = @import("text/utf8.zig").prefix(message, self.notice_storage.len);
        @memcpy(self.notice_storage[0..bounded.len], bounded);
        view.notice = self.notice_storage[0..bounded.len];
    }

    fn retainInspectionBinding(self: *Conversation, value: inspection.WorkspaceBinding) !void {
        if (self.inspection_binding) |previous| if (contract.equal(previous, value)) return;
        const fields = [_][]const u8{ value.canonical_root, value.filesystem_identity, value.repository_identity, value.checkout_identity, value.expected_branch, value.base_revision };
        for (fields) |field| if (field.len > self.inspection_binding_storage[0].len) return error.InspectionBindingTooLarge;
        self.inspection_revision +%= 1;
        self.inspection_request = null;
        for (fields, 0..) |field, index| {
            @memcpy(self.inspection_binding_storage[index][0..field.len], field);
            self.inspection_binding_lengths[index] = field.len;
        }
        self.inspection_binding = .{
            .canonical_root = self.inspection_binding_storage[0][0..self.inspection_binding_lengths[0]],
            .filesystem_identity = self.inspection_binding_storage[1][0..self.inspection_binding_lengths[1]],
            .repository_identity = self.inspection_binding_storage[2][0..self.inspection_binding_lengths[2]],
            .checkout_identity = self.inspection_binding_storage[3][0..self.inspection_binding_lengths[3]],
            .expected_branch = self.inspection_binding_storage[4][0..self.inspection_binding_lengths[4]],
            .base_revision = self.inspection_binding_storage[5][0..self.inspection_binding_lengths[5]],
            .non_git = value.non_git,
        };
    }

    fn inspectionFailure(self: *Conversation, view: *Coding, message: []const u8) void {
        view.workspace_busy = false;
        view.workspace_stale = true;
        view.workspace_diff_len = 0;
        const bounded = @import("text/utf8.zig").prefix(message, view.workspace_feedback.len);
        @memcpy(view.workspace_feedback[0..bounded.len], bounded);
        view.workspace_feedback_len = bounded.len;
        self.notice(view, message);
    }

    fn requestInspectionStatus(self: *Conversation, view: *Coding, binding: inspection.WorkspaceBinding) void {
        if (self.inspection_binding == null or !contract.equal(self.inspection_binding.?, binding) or !self.inspection_workspace.eql(self.workspace.slice())) {
            self.inspectionFailure(view, "Checkout binding is unavailable. Reconnect to the intended workspace.");
            return;
        }
        self.inspection_revision +%= 1;
        self.inspection_request = .{ .revision = self.inspection_revision };
        view.workspace_busy = true;
        view.workspace_feedback_len = 0;
    }

    fn requestInspectionDiff(self: *Conversation, view: *Coding, file: Coding.WorkspaceFile) void {
        if (self.inspection_binding == null or !self.inspection_workspace.eql(self.workspace.slice())) {
            self.inspectionFailure(view, "Checkout binding is unavailable. Reconnect before inspecting changes.");
            return;
        }
        if (file.path_len == 0 or file.path_len > file.path.len) return;
        self.inspection_revision +%= 1;
        self.inspection_request = .{ .revision = self.inspection_revision, .file = file, .staged = view.workspace_diff_staged };
        view.workspace_busy = true;
        view.workspace_diff_len = 0;
        view.workspace_feedback_len = 0;
    }

    fn pumpInspection(self: *Conversation, app: *App) void {
        const worker = self.inspection_worker orelse return;
        var completion: inspection.Completion = undefined;
        const ready = worker.drain(&completion) catch blk: {
            Wake.notify(self.wake);
            break :blk false;
        };
        if (ready) {
            defer completion.deinit(self.allocator);
            self.inspection_pending = false;
            if (completion.revision == self.inspection_revision) {
                app.view.workspace_busy = false;
                if (completion.result) |result| {
                    if (completion.query == .status) {
                        var files: [64]Coding.WorkspaceFile = @splat(.{});
                        var count: usize = 0;
                        var omitted: usize = 0;
                        for (result.entries) |entry| {
                            if (count == files.len or entry.path.len > files[count].path.len or !std.unicode.utf8ValidateSlice(entry.path)) {
                                omitted += 1;
                                continue;
                            }
                            files[count].path_len = entry.path.len;
                            @memcpy(files[count].path[0..entry.path.len], entry.path);
                            files[count].index = entry.index;
                            files[count].worktree = entry.worktree;
                            if (entry.original_path) |original| if (original.len <= files[count].original.len and std.unicode.utf8ValidateSlice(original)) {
                                files[count].original_len = original.len;
                                @memcpy(files[count].original[0..original.len], original);
                            };
                            count += 1;
                        }
                        if (app.view.admitWorkspaceInspection(completion.revision, self.workspace_root, files[0..count], "")) {
                            if (omitted != 0) {
                                var message: [160]u8 = undefined;
                                self.inspectionFailure(&app.view, std.fmt.bufPrint(&message, "{d} changed paths exceed the native list or path budget; only {d} are shown.", .{ omitted, count }) catch "Changed paths exceed the native display budget.");
                            }
                        } else self.inspectionFailure(&app.view, "Workspace result does not match the captured checkout.");
                    } else if (result.bytes.len > app.view.workspace_diff.len or !std.unicode.utf8ValidateSlice(result.bytes)) {
                        self.inspectionFailure(&app.view, "Diff exceeds 64 KiB or contains non-UTF8 bytes; native preview is unavailable.");
                    } else if (!app.view.admitWorkspaceInspection(completion.revision, self.workspace_root, app.view.workspace_files[0..app.view.workspace_file_count], result.bytes)) {
                        self.inspectionFailure(&app.view, "Diff result does not match the captured checkout.");
                    }
                } else |err| self.inspectionFailure(&app.view, if (err == error.WorkspaceIdentityChanged or err == error.WrongCheckout)
                    "Captured checkout changed. Reconnect to the intended checkout before inspecting."
                else
                    @errorName(err));
                app.dirty = true;
            }
        }
        if (!self.inspection_pending) if (self.inspection_request) |request| {
            const binding = self.inspection_binding orelse {
                self.inspection_request = null;
                self.inspectionFailure(&app.view, "No captured checkout binding is available.");
                return;
            };
            const query: inspection.Query = if (request.file) |file| .{ .diff = .{ .path = file.path[0..file.path_len], .staged = request.staged } } else .status;
            worker.request(.{ .revision = request.revision, .binding = binding, .root = self.workspace_root, .query = query }) catch |err| {
                if (err == error.Busy) {
                    Wake.notify(self.wake);
                    return;
                }
                self.inspection_request = null;
                self.inspectionFailure(&app.view, @errorName(err));
                return;
            };
            self.inspection_pending = true;
            self.inspection_request = null;
        };
    }

    fn sendPreflight(self: *Conversation, view: *const Coding) ?[]const u8 {
        return self.promptDisabledReason(view.editor.len);
    }

    fn promptDisabledReason(self: *Conversation, prompt_bytes: usize) ?[]const u8 {
        const preflight = domain.startPreflight(prompt_bytes);
        if (preflight.fits()) return null;
        return std.fmt.bufPrint(&self.preflight_storage, "Shorten this message: {d} UTF-8 bytes exceeds the {d}-byte durable prompt limit. Your draft is retained.", .{ preflight.prompt_bytes, preflight.max_prompt_bytes }) catch "Message exceeds the 64 KiB prompt limit. Your draft is retained.";
    }

    fn setupConfiguration(view: *const Coding) contract.RuntimeSetup {
        return .{
            .runtime_kind = if (view.setup_runtime == .codex) .codex else .opencode,
            .executable = view.setup_fields[0][0..view.setup_lengths[0]],
            .account_directory = view.setup_fields[1][0..view.setup_lengths[1]],
            .workspace_root = view.setup_fields[2][0..view.setup_lengths[2]],
            .model_provider = view.setup_fields[3][0..view.setup_lengths[3]],
        };
    }

    // Compare complete configurations without retaining borrowed form storage.
    // A click on sign-in or refresh must target the displayed draft, including
    // its account and workspace, rather than a previously connected provider.
    fn setupKey(configuration: contract.RuntimeSetup) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for ([_][]const u8{ @tagName(configuration.runtime_kind), configuration.executable, configuration.account_directory, configuration.workspace_root, configuration.model_provider }) |field| {
            hash.update(field);
            hash.update(&.{0});
        }
        return hash.finalResult();
    }

    fn setupNeedsConfigure(self: *const Conversation, configuration: contract.RuntimeSetup) bool {
        const applied = self.configured_setup_key orelse return true;
        return !self.runtime_configured or !std.mem.eql(u8, &applied, &setupKey(configuration));
    }

    fn configureSetup(self: *Conversation, configuration: contract.RuntimeSetup, login: ?contract.RuntimeLogin) !void {
        try self.submit(.configure, .absent, .absent, .{ .runtime_configure = configuration }, 0);
        self.submitted_setup_key = setupKey(configuration);
        self.setup_login_after_configure = login;
    }

    fn restoreSelection(self: *Conversation, view: *Coding, durable: ?contract.Selection) !void {
        self.durable_selection = if (durable) |selection| try Coding.Identity.from(selection) else null;
        if (view.selected != null) return;
        if (self.durable_selection) |selection| {
            view.selected = selection;
        } else if (self.launch_selection) |launch| {
            // The launch path stays owned by Conversation. Explicit connection
            // changes clear this fallback before registering another workspace.
            if (launch.model_id.len != 0 and launch.effort.len != 0) {
                var bound = launch;
                bound.workspace = self.workspace;
                view.selected = bound;
            }
        }
    }

    fn selectionDisabledReason(self: *const Conversation, view: *const Coding) ?[]const u8 {
        if (self.normal_startup and !self.runtime_configured) return "Choose a provider in Connection to get started.";
        if (self.login_inflight) return "Complete provider sign-in in Connection before sending.";
        if (self.catalog_refresh_pending or self.catalog_refresh_inflight) return "Loading configured provider models…";
        if (self.run_state) |state| if (state == .unknown or state == .interrupted)
            return "This chat has unresolved work. Start a new chat to continue; previous work will not be retried.";
        const selected = if (view.selected) |*identity| identity else return if (view.model_count == 0)
            "No models loaded. Open Connection and Refresh models."
        else
            "Choose a model and effort before sending.";
        if (!selected.workspace.eql(self.workspace.slice())) return "Selection belongs to another workspace. Choose a model again.";
        for (view.models[0..view.model_count]) |*model| {
            var candidate = model.identity;
            candidate.effort = selected.effort;
            if (!contract.equal(candidate.selection(), selected.selection())) continue;
            if (model.readiness == .unavailable) return if (model.reason_len != 0) model.reason[0..model.reason_len] else "Selected model is unavailable. Open Connection to refresh or sign in.";
            for (model.efforts[0..model.effort_count]) |effort| if (effort.eql(selected.effort.slice())) return null;
            return "Selected effort is unsupported. Choose an effort for this model.";
        }
        return if (self.catalog_truncated)
            "Selected model is outside the 32-model view limit. Narrow the connection's model provider."
        else
            "Selected model is absent from this catalog. Open Connection and Refresh models, or choose a model.";
    }

    /// Copy borrowed status before the query page is drained again. Restoring a
    /// workspace never uses the application state directory as a fallback.
    fn restoreStartup(self: *Conversation, view: *Coding, status: types.RuntimeStatus) !bool {
        for (status.configurations) |saved| {
            if (!view.configureSetup(saved)) self.notice(view, "A saved connection path exceeds the 512-byte form limit. Open Advanced to edit it.");
        }
        const configuration = status.configuration orelse {
            self.notice(view, if (status.readiness == .unavailable) status.reason else "Choose Codex or OpenCode, confirm your workspace, then Connect.");
            return false;
        };
        if (!view.configureSetup(configuration)) self.notice(view, "Saved connection is retained. A path exceeds the 512-byte form limit; use an explicit shorter path to edit it.");
        if (status.binding == null or status.workspace_root.len == 0) {
            self.notice(view, "Saved workspace is unavailable. Check its path in Connection, then Connect again.");
            return false;
        }
        const root = try self.allocator.dupe(u8, status.workspace_root);
        self.allocator.free(self.workspace_root);
        self.workspace_root = root;
        self.workspace_branch = try displayId(status.binding.?.expected_branch);
        self.runtime_configured = true;
        self.configured_setup_key = setupKey(configuration);
        self.startup_runtime = configuration.runtime_kind;
        if (configuration.account_directory.len <= self.startup_account.len) {
            @memcpy(self.startup_account[0..configuration.account_directory.len], configuration.account_directory);
            self.startup_account_len = configuration.account_directory.len;
        }
        self.catalog_refresh_pending = status.readiness != .unavailable;
        if (status.readiness == .unavailable) {
            self.notice(view, status.reason);
            view.setup_open = true;
        }
        return true;
    }

    fn updateLogin(self: *Conversation, view: *Coding, payload: []const u8) void {
        _ = self;
        view.login_url_len = 0;
        view.login_code_len = 0;
        if (payload.len == 0) return;
        var storage: [8192]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), payload, .{}) catch return;
        const result = parsed.value;
        if (result != .object) return;
        for ([_][]const u8{ "authUrl", "verificationUrl", "verificationUri", "verification_uri" }) |key| {
            const value = result.object.get(key) orelse continue;
            if (value != .string or value.string.len == 0 or value.string.len > view.login_url.len) continue;
            // Only web sign-in destinations can be opened by this UI action.
            if (!std.mem.startsWith(u8, value.string, "https://") and !std.mem.startsWith(u8, value.string, "http://localhost:")) continue;
            if (std.mem.indexOfScalar(u8, value.string, 0) != null) continue;
            @memcpy(view.login_url[0..value.string.len], value.string);
            view.login_url_len = value.string.len;
            break;
        }
        for ([_][]const u8{ "userCode", "user_code" }) |key| {
            const value = result.object.get(key) orelse continue;
            if (value != .string or value.string.len > view.login_code.len) continue;
            if (!std.unicode.utf8ValidateSlice(value.string)) continue;
            @memcpy(view.login_code[0..value.string.len], value.string);
            view.login_code_len = value.string.len;
            break;
        }
    }

    fn selectionNeedsSave(self: *const Conversation, view: *const Coding) bool {
        const selected = view.selected orelse return false;
        if (self.selectionDisabledReason(view) != null) return false;
        if (self.durable_selection) |durable| if (contract.equal(durable.selection(), selected.selection())) return false;
        if (self.attempted_selection) |attempted| if (contract.equal(attempted.selection(), selected.selection())) return false;
        return true;
    }

    fn rejectionMessage(reason: types.Reason) []const u8 {
        return switch (reason) {
            .selection_mismatch => "Model or effort no longer matches the provider. Refresh models and choose again.",
            .authority_unavailable, .capability_unavailable => "Provider unavailable. Open Connection to check sign-in and refresh models.",
            .workspace_mismatch => "Workspace changed. Reconnect to the intended checkout before sending.",
            .revision_conflict => "Conversation changed. Wait for refresh, then retry your action.",
            .busy => "Provider or conversation is busy. Wait for the current action to finish.",
            .unresolved_effects => "Previous work has an unresolved outcome. Inspect its status before retrying.",
            .admission_limit => "Send storage or run limit reached. Draft retained. Wait for other runs, then retry.",
            .prompt_incomplete => "Prompt upload is incomplete. Your draft is retained; retry Send.",
            .prompt_invalid => "Prompt upload failed verification. Your draft is retained; send again.",
            .prompt_staging_full => "Prompt staging is full. Open More (F10) → Discard unfinished upload, then retry Send. Draft retained.",
            else => @tagName(reason),
        };
    }

    fn recordRun(self: *Conversation, view: *Coding, row: @FieldType(types.Row, "run")) !void {
        self.run = try Id.init(row.id.value);
        self.run_revision = row.revision;
        self.run_state = row.state;
        view.status = @tagName(row.state);
        for (view.threads[0..view.thread_count]) |*entry| if (entry.id.eql(row.thread.value)) {
            entry.run_status = cardRunStatus(row.state);
        };
        if (view.notice) |message| {
            if (message.ptr == self.diagnostic_display[0..].ptr) view.notice = null;
        }
        const diagnostic = @import("text/utf8.zig").prefix(row.diagnostic, self.diagnostic_storage.len);
        @memcpy(self.diagnostic_storage[0..diagnostic.len], diagnostic);
        self.diagnostic_len = diagnostic.len;
        if (diagnostic.len != 0) view.notice = @import("text/diagnostic.zig").readable(row.diagnostic, &self.diagnostic_display);
        const evidence = &view.send_diagnostic;
        // Historical pages may contain older runs before the current Send.
        // They update cards, but cannot borrow that Send's command/receipt.
        if (evidence.command_id_len != 0 and (evidence.receipt != .accepted or !std.mem.eql(u8, evidence.run_id[0..evidence.run_id_len], row.id.value))) return;
        if (!std.mem.eql(u8, evidence.run_id[0..evidence.run_id_len], row.id.value)) {
            evidence.provider_len = 0;
        }
        switch (row.state) {
            .failed => view.send_diagnostic.setProviderDiagnostic(diagnostic, false),
            .completed, .cancelled, .interrupted, .unknown => view.send_diagnostic.setProviderDiagnostic(diagnostic, true),
            else => {
                evidence.stage = .accepted;
                evidence.provider_len = 0;
            },
        }
        view.send_diagnostic.setRun(row.id.value, row.session.value);
        view.send_diagnostic.setRunState(@tagName(row.state));
    }

    fn recordEffect(self: *Conversation, view: *Coding, row: @FieldType(types.Row, "effect")) void {
        if (!self.run.eql(row.run.value) or self.diagnostic_len != 0 or (row.state != .failed and row.state != .unknown) or row.outcome.len == 0) return;
        const evidence = &view.send_diagnostic;
        if (evidence.command_id_len != 0 and (evidence.receipt != .accepted or !std.mem.eql(u8, evidence.run_id[0..evidence.run_id_len], row.run.value))) return;
        const diagnostic = @import("text/utf8.zig").prefix(row.outcome, self.diagnostic_storage.len);
        @memcpy(self.diagnostic_storage[0..diagnostic.len], diagnostic);
        self.diagnostic_len = diagnostic.len;
        view.notice = @import("text/diagnostic.zig").readable(row.outcome, &self.diagnostic_display);
        evidence.setEffect(row.id.value);
        evidence.setProviderDiagnostic(diagnostic, self.run_state != .failed);
    }

    fn setup(self: *Conversation, app: *App, action: @typeInfo(@FieldType(Coding, "setup_action")).optional.child) !void {
        if (action == .open_login) {
            if (app.view.login_url_len != 0) {
                var url: [2049]u8 = undefined;
                @memcpy(url[0..app.view.login_url_len], app.view.login_url[0..app.view.login_url_len]);
                url[app.view.login_url_len] = 0;
                if (!c.SDL_OpenURL(@ptrCast(&url))) return error.OpenSignInPageFailed;
            }
            return;
        }
        if (self.command != null or self.query != null or self.login_inflight or self.setup_login_after_configure != null) return error.WorkspaceBusy;
        const configuration = setupConfiguration(&app.view);
        switch (action) {
            .status => try self.ask(.runtime_status, .{ .runtime_status = {} }),
            .refresh => {
                if (self.setupNeedsConfigure(configuration)) {
                    try self.configureSetup(configuration, null);
                } else {
                    try self.submit(.refresh_models, .absent, .absent, .{ .runtime_refresh = {} }, 0);
                    self.catalog_refresh_inflight = true;
                }
            },
            .browser, .device => {
                if (configuration.runtime_kind != .codex) return error.SignInUnsupported;
                const login: contract.RuntimeLogin = .{ .runtime_kind = .codex, .mode = if (action == .browser) .browser else .device };
                if (self.setupNeedsConfigure(configuration)) {
                    try self.configureSetup(configuration, login);
                } else try self.submit(.login, .absent, .absent, .{ .runtime_login = login }, 0);
            },
            .open_login => unreachable,
            .configure => try self.configureSetup(configuration, null),
        }
        app.view.notice = null;
    }
    fn navigateWorkspace(self: *Conversation, app: *App, navigation: Coding.Navigation) !void {
        if (!app.view.navigation_enabled) return error.WorkspaceBusy;
        if (std.meta.activeTag(navigation) == .new_thread or std.meta.activeTag(navigation) == .new_project) {
            var available = false;
            for (app.view.retained) |slot| if (slot.editor == null) {
                available = true;
                break;
            };
            if (!available) return error.DraftRetentionFull;
        }
        switch (navigation) {
            .new_project => {
                app.view.scope_project = .{};
                try self.submit(.project, .absent, .absent, .{ .project_create = .{ .display_name = "Coding project" } }, 0);
            },
            .new_thread => {
                if (app.view.scope_project.len != 0 and !app.view.scope_project.eql(self.project.slice())) {
                    self.project = app.view.scope_project;
                    self.create_thread_after_workspace = true;
                    try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = page } });
                } else try self.createThread();
            },
            .project => |index| {
                if (index >= app.view.project_count) return;
                self.project = app.view.projects[index].id;
                self.thread = .{};
                app.view.thread_count = 0;
                try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = page } });
            },
            .thread => |index| {
                if (index >= app.view.thread_count) return;
                self.project = app.view.threads[index].project_id;
                try self.selectThread(app, app.view.threads[index].id);
            },
            .search_more => {
                if (self.thread_page_anchor == null) {
                    app.view.search_more_available = false;
                    self.notice(&app.view, "No additional thread page is available for this search.");
                    return;
                }
                self.thread_page_cursor = null;
                const anchor = self.thread_page_anchor orelse {
                    app.view.search_more_available = false;
                    self.notice(&app.view, "Thread search cursor expired; refresh the thread list and try again.");
                    return;
                };
                app.view.thread_count = 0;
                app.view.search_more_available = false;
                self.card_rows_seen = 0;
                try self.ask(.cards, .{ .threads = .{ .anchor = .{ .value = anchor.slice() }, .page = .{ .limit = page.limit, .max_bytes = page.max_bytes } } });
            },
            .search_reset => {
                self.thread_page_snapshot = null;
                self.thread_page_cursor = null;
                self.thread_page_anchor = null;
                self.card_rows_seen = 0;
                app.view.thread_count = 0;
                app.view.search_more_available = false;
                try self.ask(.cards, .{ .threads = .{ .page = page } });
            },
        }
    }

    fn selectThread(self: *Conversation, app: *App, id: Id) !void {
        const changed_thread = app.view.active_thread.len != 0 and !app.view.active_thread.eql(id.slice());
        try app.view.selectThread(id);
        self.thread = id;
        self.run = .{};
        self.run_state = null;
        app.view.send_diagnostic = .{};
        self.durable_selection = null;
        self.attempted_selection = null;
        if (changed_thread) app.view.notice = null;
        self.approval_live = false;
        app.view.task_count = 0;
        app.view.active_project = self.project;
        self.generation += 1;
        self.worker_key = null;
        self.projected_key = null;
        self.tile_request = null;
        self.source_pending = false;
        self.history_paused = true;
        self.message_count = 0;
        self.message_snapshot = null;
        self.message_anchor = null;
        self.message_direction = .older;
        self.block_snapshot = null;
        self.block_cursor = null;
        self.history_first = null;
        self.pending_history_move = null;
        self.refresh = true;
    }

    fn addEntry(entries: []Coding.Entry, count: *usize, id: []const u8, label: []const u8) !void {
        for (entries[0..count.*]) |*entry| if (entry.id.eql(id)) {
            const bounded = @import("text/utf8.zig").prefix(label, entry.label.len);
            entry.len = bounded.len;
            @memcpy(entry.label[0..entry.len], bounded);
            return;
        };
        if (count.* == entries.len) return;
        const entry = &entries[count.*];
        entry.* = .{};
        entry.id = try Id.init(id);
        entry.len = @import("text/utf8.zig").prefix(label, entry.label.len).len;
        @memcpy(entry.label[0..entry.len], label[0..entry.len]);
        count.* += 1;
    }

    fn cardRunStatus(state: types.RunState) Coding.RunStatus {
        return switch (state) {
            .queued, .starting, .streaming, .cancel_requested => .running,
            .awaiting_approval => .approval,
            .failed => .failed,
            .interrupted, .unknown => .interrupted,
            .completed, .cancelled => .idle,
        };
    }

    fn displayId(bytes: []const u8) !Id {
        const bounded = @import("text/utf8.zig").prefix(bytes, @import("ui/transcript.zig").id_bytes);
        return if (bounded.len == 0) .{} else try Id.init(bounded);
    }

    fn cardTitle(output: *[160]u8, preview: []const u8) []const u8 {
        const bounded = @import("text/utf8.zig").prefix(preview, output.len);
        var len: usize = 0;
        var space = false;
        for (bounded) |byte| {
            if (std.ascii.isWhitespace(byte) or byte < 32 or byte == 127) {
                space = len != 0;
                continue;
            }
            if (space and len < output.len) {
                output[len] = ' ';
                len += 1;
            }
            space = false;
            if (len == output.len) break;
            output[len] = byte;
            len += 1;
        }
        return if (len == 0) "New thread" else output[0..len];
    }

    fn updateThreadCard(self: *Conversation, view: *Coding, row: @FieldType(types.Row, "thread")) !void {
        if (row.project_name.len != 0) try addEntry(&view.projects, &view.project_count, row.project.value, row.project_name);
        var title: [160]u8 = undefined;
        try addEntry(&view.threads, &view.thread_count, row.id.value, if (row.title.len != 0) row.title else cardTitle(&title, row.title_preview));
        for (view.threads[0..view.thread_count]) |*entry| if (entry.id.eql(row.id.value)) {
            entry.project_id = try Id.init(row.project.value);
            for (view.projects[0..view.project_count]) |*project| if (project.id.eql(row.project.value)) {
                entry.project_name = try displayId(project.label[0..project.len]);
                break;
            };
            if (row.project_name.len != 0) entry.project_name = try displayId(row.project_name);
            entry.workspace_name = try displayId(std.fs.path.basename(if (row.workspace_root.len != 0) row.workspace_root else self.workspace_root));
            entry.branch = try displayId(row.workspace_branch);
            entry.run_status = if (row.latest_run_state) |state| cardRunStatus(state) else .idle;
            return;
        };
    }

    fn prepareHistoryRestore(self: *Conversation, view: *Coding) bool {
        if (!view.history_restore) return false;
        view.history_restore = false;
        if (view.follow_latest) return false;
        const position = view.history_position orelse return false;
        self.generation += 1;
        self.message_count = 1;
        self.message_index = 0;
        self.messages[0] = position.message;
        self.message_roles[0] = std.meta.stringToEnum(@FieldType(@FieldType(types.Row, "message"), "role"), position.role) orelse .assistant;
        self.message_ordinals[0] = position.message_ordinal;
        self.desired_block = position.block_ordinal;
        self.recovery_block = position.block;
        self.block_cursor = null;
        self.block_snapshot = null;
        self.message_snapshot = null;
        self.worker_key = null;
        self.projected_key = null;
        self.source_pending = false;
        self.tile_request = null;
        self.history_paused = false;
        self.history_first = null;
        self.history_retrying = false;
        self.pending_history_move = null;
        self.copy_pending = null;
        self.history_start = .{ .key = undefined, .first_block = position.cursor.block, .start_byte = position.cursor.byte };
        self.restored_pixel = position.pixel_offset;
        self.restored_revision = position.revision;
        view.rendered_selection = if (position.selection) |selection| .{ .key = .{ .source = selection.source, .revision = selection.revision, .generation = self.generation }, .anchor = selection.anchor, .caret = selection.caret } else null;
        view.clearHistory();
        return true;
    }

    fn reconcileRestoredRevision(self: *Conversation, view: *Coding, revision: u64) void {
        const restored = self.restored_revision orelse return;
        self.restored_revision = null;
        if (restored == revision) return;
        // Rendered coordinates belong to one projection revision, not its source bytes.
        self.history_start = .{ .key = undefined, .first_block = 0, .start_byte = 0 };
        self.restored_pixel = 0;
        view.rendered_selection = null;
        view.notice = "History revision changed while away";
    }

    fn askHistory(self: *Conversation, app: *App) !void {
        if (self.prepareHistoryRestore(&app.view)) return self.askBlocks();
        return self.askMessages();
    }

    fn recoveryQuery(self: *Conversation, kind: QueryKind) ?struct { kind: QueryKind, value: types.Query } {
        if (self.history_retrying or self.message_count == 0) return null;
        switch (kind) {
            .messages => {
                self.history_retrying = true;
                self.message_snapshot = null;
                var bounds = page;
                bounds.limit = 1;
                return .{ .kind = .messages, .value = .{ .messages = .{ .thread = .{ .value = self.thread.slice() }, .anchor = if (self.message_anchor) |*anchor| .{ .value = anchor.slice() } else null, .direction = self.message_direction, .page = bounds } } };
            },
            .blocks, .content => {
                self.history_retrying = true;
                if (self.message_index >= self.message_count) self.message_index = self.message_count - 1;
                self.block_cursor = null;
                self.block_snapshot = null;
                self.source_pending = false;
                self.worker_key = null;
                if (self.desired_block == null and self.block_count != 0) {
                    self.desired_block = if (self.block_index < self.block_count) self.blocks[self.block_index].ordinal else self.blocks[self.block_count - 1].ordinal + 1;
                }
                if (self.block_index < self.block_count) self.recovery_block = self.blocks[self.block_index].id;
                if (self.history_start == null) if (self.history_first) |first| {
                    if (self.desired_block == first.ordinal) self.history_start = .{ .key = undefined, .first_block = first.cursor.block, .start_byte = first.cursor.byte };
                };
                return .{ .kind = .blocks, .value = .{ .blocks = .{ .message = .{ .value = self.messages[self.message_index].slice() }, .page = page } } };
            },
            else => return null,
        }
    }

    fn navigate(self: *Conversation, app: *App, move: Coding.HistoryMove) !void {
        if (self.query != null or self.source_pending or (!self.history_paused and self.worker_key != null)) {
            // Same latest-wins coalescing rule as source/visible-range requests.
            self.pending_history_move = move;
            return;
        }
        // Retained visible tiles carry their own durable message identity even
        // when the current query page has been cleared during a refresh.
        if (self.message_count == 0 and app.view.rich_count == 0 and move != .first and move != .latest) return;
        self.history_retrying = false;
        self.recovery_block = null;
        switch (move) {
            .first, .latest => {
                self.message_anchor = null;
                self.message_snapshot = null;
                self.message_direction = if (move == .first) .newer else .older;
                app.view.follow_latest = move == .latest;
                app.view.clearHistory();
                self.history_paused = false;
                self.worker_key = null;
                self.tile_request = null;
                try self.askHistory(app);
            },
            .next => {
                app.view.follow_latest = false;
                if (self.history_paused and self.worker_key != null) {
                    self.history_paused = false;
                    self.history_first = null;
                    if (self.tile_request == null) try self.nextBlock(app);
                } else {
                    self.message_anchor = if (app.view.rich_count != 0) app.view.rich_tiles[app.view.rich_count - 1].message else self.messages[self.message_count - 1];
                    self.message_direction = .newer;
                    self.message_snapshot = null;
                    try self.askHistory(app);
                }
            },
            .previous => {
                if (app.view.rich_count != 0) {
                    const tile = &app.view.rich_tiles[0];
                    self.history_first = .{ .key = tile.key.?, .cursor = .{ .block = tile.block_index, .byte = tile.start_byte }, .ordinal = tile.canonical_ordinal };
                    self.messages[0] = tile.message;
                    self.message_roles[0] = std.meta.stringToEnum(@FieldType(@FieldType(types.Row, "message"), "role"), tile.role) orelse .assistant;
                    self.message_ordinals[0] = tile.message_ordinal;
                    self.message_count = 1;
                    self.message_index = 0;
                }
                const first = self.history_first orelse return;
                app.view.follow_latest = false;
                self.message_direction = .older;
                self.history_paused = false;
                self.tile_request = null;
                self.worker_key = null;
                if (first.cursor.block != 0 or first.cursor.byte != 0) {
                    if (self.projected_key) |key| if (std.meta.eql(key, first.key)) {
                        for (self.blocks[0..self.block_count], 0..) |block, index| if (block.ordinal == first.ordinal) {
                            self.block_index = index;
                            self.worker_key = key;
                            self.tile_request = .{ .key = key, .first_block = first.cursor.block, .start_byte = first.cursor.byte, .backward = true };
                            self.history_first = null;
                            return;
                        };
                    };
                    self.desired_block = first.ordinal;
                    self.history_start = .{ .key = undefined, .first_block = first.cursor.block, .start_byte = first.cursor.byte, .backward = true };
                    self.block_cursor = null;
                    self.block_snapshot = null;
                    try self.askBlocks();
                } else if (first.ordinal != 0) {
                    self.desired_block = first.ordinal - 1;
                    self.history_start = .{ .key = undefined, .first_block = 0, .last = true };
                    self.block_cursor = null;
                    self.block_snapshot = null;
                    try self.askBlocks();
                } else {
                    self.message_anchor = self.messages[0];
                    self.message_direction = .older;
                    self.message_snapshot = null;
                    try self.askHistory(app);
                }
            },
        }
    }

    const QueryKind = enum { send_receipt, capabilities, projects, workspaces, inspection_workspace, threads, cards, thread, models, runtime_status, startup_status, runs, effects, approvals, tasks, messages, blocks, content };
    const CommandKind = enum { prompt_cleanup, followup_enqueue, followup_edit, followup_cancel, followup_order, attachment_add, attachment_remove, project, workspace, thread, title, selection, send, cancel, approval, configure, login, refresh_models };
    const page: types.Page = .{ .limit = 8, .max_bytes = 16 * 1024 };

    fn create(allocator: std.mem.Allocator, io: std.Io, host: *domain.Host, file: std.Io.File, wake: *Wake, workspace_root: []const u8) !*Conversation {
        const self = try allocator.create(Conversation);
        errdefer allocator.destroy(self);
        const root = try allocator.dupe(u8, workspace_root);
        errdefer allocator.free(root);
        // Bootstrap admission precedes worker/file ownership transfer.
        const ticket = try host.query(.{ .projects = .{ .limit = 16, .max_bytes = 16 * 1024 } });
        const worker = try presentation.Worker.create(allocator, io, file, .{ .context = wake, .notify = Wake.presentationNotify });
        errdefer worker.destroy();
        const attachment_loader = try attachment_text.Loader.create(allocator, io, wake, Wake.presentationNotify);
        errdefer attachment_loader.destroy();
        const inspection_worker = try inspection.Worker.create(allocator, io, .{ .context = wake, .notify = Wake.presentationNotify }, .{});
        self.* = .{ .allocator = allocator, .io = io, .host = host, .worker = worker, .attachment_loader = attachment_loader, .inspection_worker = inspection_worker, .wake = wake, .workspace_root = root, .query = .{ .ticket = ticket, .kind = .projects } };
        return self;
    }

    fn destroy(self: *Conversation) void {
        if (self.attachment_loader) |loader| loader.destroy();
        if (self.inspection_worker) |worker| worker.destroy();
        self.worker.destroy();
        // Main owns Host and joins it separately before SDL destruction.
        self.allocator.free(self.workspace_root);
        self.allocator.destroy(self);
    }

    fn ask(self: *Conversation, kind: QueryKind, value: types.Query) !void {
        std.debug.assert(self.query == null);
        self.query = .{ .ticket = try self.host.query(value), .kind = kind };
    }

    fn submit(self: *Conversation, kind: CommandKind, target: types.Target, revision: types.Precondition, payload: types.Payload, draft_revision: u64) !void {
        if (self.command != null) return error.CommandPending;
        return self.submitIdentified(kind, target, revision, payload, draft_revision, try self.commandId());
    }

    fn rename(self: *Conversation, app: *App) !void {
        if (!app.view.title_editing or self.thread.len == 0) return error.NoThread;
        const title = app.view.title_buffer[0..app.view.title_len];
        if (title.len == 0 or title.len > types.max_title_bytes or !std.unicode.utf8ValidateSlice(title)) {
            self.notice(&app.view, "Title must contain 1–160 valid UTF-8 bytes.");
            return;
        }
        @memcpy(self.title_pending[0..title.len], title);
        self.title_pending_len = title.len;
        try self.submit(.title, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, .{ .thread_title_set = .{ .title = self.title_pending[0..self.title_pending_len] } }, app.view.revision);
    }

    fn commandId(self: *Conversation) ![32]u8 {
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const hex = "0123456789abcdef";
        var id: [32]u8 = undefined;
        for (random, 0..) |byte, index| {
            id[index * 2] = hex[byte >> 4];
            id[index * 2 + 1] = hex[byte & 15];
        }
        return id;
    }

    fn submitIdentified(self: *Conversation, kind: CommandKind, target: types.Target, revision: types.Precondition, payload: types.Payload, draft_revision: u64, id: [32]u8) !void {
        if (self.command != null) return error.CommandPending;
        if (self.unknown_send != null) return error.SendReceiptUnknown;
        const ticket = try self.host.submit(.{ .command_id = .{ .value = &id }, .target = target, .expected_revision = revision, .payload = payload });
        self.command = .{ .ticket = ticket, .kind = kind, .draft_revision = draft_revision, .id = id };
    }

    /// Both native and custom actions preflight the actual proposed text. Host
    /// queue admission and its concrete provider-frame check remain authoritative.
    fn sendIdentified(self: *Conversation, app: *App, target: types.Target, revision: types.Precondition, prompt: []const u8, selection: contract.Selection, draft_revision: u64, id: [32]u8) !void {
        if (self.command != null) return error.CommandPending;
        if (self.unknown_send) |*pending| {
            if (self.query == null) {
                try self.ask(.send_receipt, .{ .command_receipt = .{ .value = &pending.id } });
                self.receipt_lookup_attempted = true;
            }
            self.notice(&app.view, "Checking the previous Send receipt. Your current draft stays here.");
            return;
        }
        const preflight = domain.startPreflight(prompt.len);
        if (self.attachment_loading or app.view.followup_editing != null) {
            app.view.send_diagnostic.stage = .disabled;
            self.notice(&app.view, if (self.attachment_loading) "A file is still being read. Wait for attachment admission before sending." else "This draft edits a follow-up. Save it or stop editing in More (F10).");
            return;
        }
        if (app.view.attachments.count != 0) {
            app.view.send_diagnostic.stage = .disabled;
            self.notice(&app.view, "Attachments are local only. Remove them in More (F10) before sending; this Host cannot deliver them.");
            return;
        }
        if (self.promptDisabledReason(prompt.len)) |reason| {
            app.view.send_diagnostic = .{ .stage = .preflight_rejected, .prompt_bytes = prompt.len, .frame_bytes = preflight.frame_bytes };
            self.notice(&app.view, reason);
            return;
        }
        if (prompt.len == 0) {
            app.view.send_diagnostic = .{ .stage = .disabled };
            self.notice(&app.view, "Write a message before sending.");
            return;
        }
        app.view.send_diagnostic.begin(&id, prompt.len, preflight.frame_bytes);
        self.submitIdentified(.send, target, revision, .{ .thread_send = .{ .text = prompt, .selection = selection } }, draft_revision, id) catch |err| {
            app.view.send_diagnostic.stage = .admission_failed;
            @import("ui/coding.zig").SendDiagnostic.bounded(&app.view.send_diagnostic.rejection, &app.view.send_diagnostic.rejection_len, @errorName(err));
            app.view.notice = std.fmt.bufPrint(&self.notice_storage, "Send was not queued: {s}. Draft retained; retry after the current action finishes.", .{@errorName(err)}) catch @errorName(err);
            return;
        };
        app.view.send_diagnostic.ticket = self.command.?.ticket.value;
    }

    fn pumpAttachment(self: *Conversation, app: *App) void {
        if (!self.attachment_loading or self.command != null or self.query != null or self.refresh) return;
        const loader = self.attachment_loader orelse return;
        if (!loader.completed()) return;
        defer loader.release();
        self.attachment_loading = false;
        app.dirty = true;
        const view = &app.view;
        if (!self.thread.eql(self.attachment_thread.slice())) {
            view.workflowNotice("Selected chat changed while reading. File was not added.");
            return;
        }
        self.admitAttachment(app, loader) catch |err| {
            view.workflow_error = @errorName(err);
            view.workflowNotice(switch (err) {
                error.AttachmentLimit, error.StreamTooLong => "File is too large. Draft files are limited to 256 KiB total.",
                error.FileNotFound => "File not found. Check the path and try again.",
                error.RegularFileRequired => "Choose a regular file, rather than a folder or special file.",
                error.AccessDenied => "Cannot read this file. Check its permissions.",
                else => "Could not add the file. Your draft is retained; nothing was sent.",
            });
        };
    }

    fn admitAttachment(self: *Conversation, app: *App, loader: *attachment_text.Loader) !void {
        if (loader.failure) |err| return err;
        const view = &app.view;
        const bytes = loader.bytes[0..loader.len];
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const id = try self.commandId();
        const index = try view.attachments.add(.{ .metadata = .{
            .id = .{ .value = &id },
            .name = std.fs.path.basename(loader.path[0..loader.path_len]),
            .media_type = "application/octet-stream",
            .byte_length = bytes.len,
            .digest = &hex,
        }, .content = bytes });
        self.workflow_pending = .{ .thread = self.thread, .run = self.run, .attachment_index = index };
        view.workflowNotice("File copied locally; checking Host attachment admission…");
        try self.submit(.attachment_add, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, .{ .attachment_add = view.attachments.get(index).? }, view.revision);
    }

    fn workflow(self: *Conversation, app: *App, action: Coding.WorkflowAction) !void {
        const view = &app.view;
        if (self.command != null or self.query != null or self.refresh or self.attachment_loading) return error.ConversationUpdating;
        if (!view.active_thread.eql(self.thread.slice()) or !view.workflow_run.eql(self.run.slice())) return error.StaleWorkflow;
        self.workflow_pending = .{ .thread = self.thread, .run = self.run };
        view.workflow_error = "";
        switch (action) {
            .cleanup_prompt => {
                try self.submit(.prompt_cleanup, .absent, .absent, .{ .prompt_discard = .{} }, view.revision);
                view.workflowNotice("Discarding one unfinished prompt upload. Sent messages and your draft are retained.");
            },
            .add => {
                const loader = self.attachment_loader orelse return error.AttachmentLoaderUnavailable;
                try loader.request(view.workflow_path[0..view.workflow_path_len], attachment_text.max_bytes - view.attachments.content_bytes);
                self.attachment_loading = true;
                self.attachment_thread = self.thread;
                view.workflowNotice("Reading the selected file…");
            },
            .remove => |index| {
                const attachment = view.attachments.get(index) orelse return error.AttachmentNotFound;
                self.workflow_pending.attachment_index = index;
                // Removal is local draft editing. The public Host command still
                // records/refuses removal of any provider-owned metadata.
                try self.submit(.attachment_remove, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, .{ .attachment_remove = attachment.metadata.id }, view.revision);
                view.attachments.removeAt(index);
                view.workflowNotice("Local attachment removed; checking Host metadata removal…");
            },
            .enqueue => {
                if (!view.workflow_active) return error.NoLiveRun;
                if (view.workflow_uncertain) return error.FollowupOutcomeUnknown;
                if (self.followup_capability != .supported or view.selected == null or !self.capability_runtime.eql(view.selected.?.runtime_kind.slice())) return error.FollowupCapabilityUnavailable;
                const content = view.editor.textBytes();
                if (content.len == 0 or content.len > self.workflow_pending.content.len) return error.FollowupDraftSize;
                if (view.attachments.count != 0) return error.AttachmentDeliveryUnavailable;
                @memcpy(self.workflow_pending.content[0..content.len], content);
                self.workflow_pending.len = content.len;
                const copy = self.workflow_pending.content[0..content.len];
                if (view.followup_editing) |editing| {
                    for (view.followups[0..view.followup_count]) |*item| if (item.id.eql(editing.slice())) {
                        if (item.state != .planned) return error.FollowupAlreadyDispatched;
                        self.workflow_pending.id = item.id;
                        try self.submit(.followup_edit, .{ .effect = .{ .value = item.id.slice() } }, .{ .revision = item.revision }, .{ .followup_edit = .{ .content = copy } }, view.revision);
                        return;
                    };
                    return error.FollowupNotFound;
                }
                if (view.followup_count == view.followups.len) return error.FollowupLimit;
                try self.submit(.followup_enqueue, .{ .run = .{ .value = self.run.slice() } }, .{ .revision = self.run_revision }, .{ .followup_enqueue = .{ .content = copy } }, view.revision);
            },
            .edit => |index| {
                if (index >= view.followup_count) return error.FollowupNotFound;
                const item = &view.followups[index];
                if (item.state != .planned) return error.FollowupAlreadyDispatched;
                if (view.editor.len != 0) return error.KeepOrClearCurrentDraftBeforeEditing;
                try view.insert(item.content[0..item.len], .paste);
                view.followup_editing = item.id;
                view.workflow_open = false;
                view.focused = true;
            },
            .cancel => |index| {
                if (index >= view.followup_count) return error.FollowupNotFound;
                const item = &view.followups[index];
                if (item.state != .planned) return error.FollowupAlreadyDispatched;
                self.workflow_pending.id = item.id;
                try self.submit(.followup_cancel, .{ .effect = .{ .value = item.id.slice() } }, .{ .revision = item.revision }, .{ .followup_cancel = .{ .reason = "Native follow-up cancellation" } }, view.revision);
            },
            .up, .down => |index| {
                if (index >= view.followup_count) return error.FollowupNotFound;
                const other = if (action == .up) index -| 1 else index + 1;
                if (other == index or other >= view.followup_count) return error.FollowupOrderBoundary;
                for (view.followups[0..view.followup_count], 0..) |item, i| {
                    if (item.state != .planned) return error.FollowupAlreadyDispatched;
                    const from = if (i == index) other else if (i == other) index else i;
                    self.workflow_pending.order_ids[i] = view.followups[from].id;
                }
                self.workflow_pending.order_count = view.followup_count;
                for (0..view.followup_count) |i| self.workflow_pending.order[i] = .{ .value = self.workflow_pending.order_ids[i].slice() };
                try self.submit(.followup_order, .{ .run = .{ .value = self.run.slice() } }, .{ .revision = self.run_revision }, .{ .followup_order = .{ .followups = self.workflow_pending.order[0..view.followup_count] } }, view.revision);
            },
        }
    }

    fn act(self: *Conversation, app: *App, intent: @import("ui/coding.zig").Intent) !void {
        switch (intent) {
            .send => {
                if (self.selectionDisabledReason(&app.view)) |reason| {
                    self.notice(&app.view, reason);
                    return;
                }
                const selected = if (app.view.selected) |*identity| identity.selection() else return error.ChooseModel;
                try self.sendIdentified(app, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, app.view.editor.textBytes(), selected, app.view.revision, try self.commandId());
                app.view.follow_latest = true;
            },
            .cancel => try self.submit(.cancel, .{ .run = .{ .value = self.run.slice() } }, .{ .revision = self.run_revision }, .{ .run_cancel = .{ .reason = "Native user cancellation" } }, 0),
            .allow, .deny => {
                if (!self.approval_live) return error.ApprovalNotLive;
                try self.submit(.approval, .{ .approval = .{ .value = self.approval.slice() } }, .{ .revision = self.approval_revision }, .{ .approval_respond = .{ .decision = if (intent == .allow) .allow else .deny, .action_digest = self.approval_digest.slice() } }, 0);
            },
        }
        app.view.can_send = false;
        app.view.can_cancel = false;
        app.view.can_approve = false;
    }

    fn pump(self: *Conversation, app: *App) !void {
        var outputs: [8]types.Output = undefined;
        const drained = self.host.drain(&outputs, &self.drain_storage);
        if (drained.required_bytes_for_next != 0) return error.DomainOutputBudget;
        for (outputs[0..drained.output_count]) |output| {
            app.dirty = true;
            switch (output) {
                .command_receipt => |value| try self.receipt(app, value.ticket, value.receipt),
                .query_page => |value| {
                    const pending = self.query orelse continue;
                    if (pending.ticket.value != value.ticket.value) return error.UnexpectedQueryTicket;
                    self.query = null;
                    try self.consume(app, pending.kind, value.page);
                },
                .subscribed => |value| {
                    self.subscription = value.id;
                    self.subscribe_ticket = null;
                },
                .event_batch => {
                    self.refresh = true;
                },
                .newer_revision => {
                    self.refresh = true;
                },
                .resync_required => {
                    if (self.subscription) |id| _ = try self.host.unsubscribe(id);
                    self.subscription = null;
                    self.refresh = true;
                },
                .unsubscribed => {},
                .failure => |value| {
                    if (self.query) |pending| if (pending.ticket.value == value.ticket.value) {
                        self.query = null;
                        if (pending.kind == .effects) {
                            self.notice(&app.view, "Provider effect diagnostic is unavailable. Inspect the run before retrying Send.");
                            try self.ask(.approvals, .{ .approvals = .{ .run = .{ .value = self.run.slice() }, .page = page } });
                            continue;
                        }
                        if (pending.kind == .models or pending.kind == .runtime_status or pending.kind == .startup_status) {
                            self.catalog_refresh_inflight = false;
                            if (self.configuration_pending) {
                                self.configuration_pending = false;
                                self.catalog_refresh_pending = false;
                                self.setup_login_after_configure = null;
                                self.submitted_setup_key = null;
                            }
                        }
                        if (value.failure.reason == .cursor_invalid) if (self.recoveryQuery(pending.kind)) |retry| {
                            try self.ask(retry.kind, retry.value);
                            app.view.notice = "History snapshot expired; restoring stable anchor";
                            continue;
                        };
                        if (value.failure.reason == .cursor_invalid and self.history_retrying) {
                            self.history_paused = true;
                            self.worker_key = null;
                            self.source_pending = false;
                            self.tile_request = null;
                            self.refresh = false;
                            app.view.notice = "History snapshot expired again; navigate to retry";
                            continue;
                        }
                    };
                    if (self.command) |pending| if (pending.ticket.value == value.ticket.value) {
                        switch (pending.kind) {
                            .followup_enqueue, .followup_edit, .followup_cancel, .followup_order => {
                                app.view.workflow_uncertain = true;
                                app.view.workflowNotice("Follow-up outcome unknown. Draft retained; further follow-up mutations are blocked for this run.");
                            },
                            .attachment_add, .attachment_remove => app.view.workflowNotice("Host metadata outcome unknown. Local draft state retained; attachment delivery remains unavailable."),
                            else => {},
                        }
                        if (pending.kind == .send) {
                            self.unknown_send = pending;
                            self.receipt_lookup_attempted = false;
                            app.view.send_diagnostic.stage = .outcome_unknown;
                            @import("ui/coding.zig").SendDiagnostic.bounded(&app.view.send_diagnostic.rejection, &app.view.send_diagnostic.rejection_len, @tagName(value.failure.reason));
                        }
                        if (pending.kind == .refresh_models) self.catalog_refresh_inflight = false;
                        if (pending.kind == .configure) {
                            self.setup_login_after_configure = null;
                            self.submitted_setup_key = null;
                        }
                        self.command = null;
                    };
                    self.notice(&app.view, switch (value.failure.reason) {
                        .storage_unavailable => "Conversation storage unavailable. Check the selected state directory.",
                        .outcome_unknown => "Provider outcome is unknown. Inspect the conversation before retrying.",
                        else => @tagName(value.failure.reason),
                    });
                    if (value.failure.refresh_required) self.refresh = true;
                },
            }
        }
        if (self.query == null and self.unknown_send != null and !self.receipt_lookup_attempted) {
            try self.ask(.send_receipt, .{ .command_receipt = .{ .value = &self.unknown_send.?.id } });
            self.receipt_lookup_attempted = true;
        }
        if (drained.more_pending) Wake.notify(self.wake);
        self.pumpInspection(app);
        self.pumpAttachment(app);
        const ready = self.worker.drain(&self.completion) catch |err| switch (err) {
            error.Busy => blk: {
                Wake.notify(self.wake);
                break :blk false;
            },
        };
        if (ready) {
            switch (self.completion) {
                .projected => |header| if (self.worker_key) |key| {
                    if (std.meta.eql(header.key, key)) {
                        self.projected_key = header.key;
                        if (header.state == .rich and header.block_count != 0) {
                            var request = self.history_start orelse presentation.PageRequest{ .key = key, .first_block = 0, .last = app.view.follow_latest and self.blocks[self.block_index].bytes > presentation.page_text_bytes };
                            request.key = key;
                            self.history_start = null;
                            self.tile_request = request;
                        } else try self.nextBlock(app);
                    }
                },
                .tile => |*tile| if (self.worker_key) |key| {
                    if (std.meta.eql(tile.key, key)) {
                        self.history_retrying = false;
                        self.recovery_block = null;
                        if (self.history_first == null) self.history_first = .{ .key = tile.key, .cursor = .{ .block = tile.block.index, .byte = tile.start_byte }, .ordinal = self.blocks[self.block_index].ordinal };
                        var width: c_int = 0;
                        _ = c.SDL_GetWindowSize(app.window, &width, null);
                        app.view.admitTile(app.text, tile, @min(900, @as(f32, @floatFromInt(width)) - Layout.sidebarWidth(@floatFromInt(width)) - 48), .{
                            .message = self.messages[self.message_index],
                            .block = self.blocks[self.block_index].id,
                            .ordinal = self.blocks[self.block_index].ordinal,
                            .message_ordinal = self.message_ordinals[self.message_index],
                            .role = @tagName(self.message_roles[self.message_index]),
                            .backward = !app.view.follow_latest and self.message_direction == .older,
                        }) catch |err| {
                            app.view.notice = @errorName(err);
                        };
                        if (self.restored_pixel) |offset| {
                            app.view.transcript_scroll = @max(0, 10 + offset);
                            self.restored_pixel = null;
                        }
                        app.dirty = true;
                        self.tile_request = if (tile.next) |next| .{ .key = key, .first_block = next.block, .start_byte = next.byte } else null;
                        if (!app.view.follow_latest and app.view.rich_count == app.view.rich_tiles.len and self.tile_request != null) {
                            self.history_paused = true;
                        } else if (self.tile_request == null) try self.nextBlock(app);
                    }
                },
                .copied => |*value| {
                    @import("ui/clipboard.zig").copyBytes(value.bytes[0..value.len], app.view.scratch) catch |err| {
                        app.view.notice = @errorName(err);
                    };
                    app.dirty = true;
                },
                .failure => |failure| {
                    if (failure.copy) {
                        app.view.notice = @errorName(failure.reason);
                    } else if (self.worker_key) |key| {
                        if (std.meta.eql(failure.key, key)) {
                            if (failure.reason != error.EndOfProjection) app.view.notice = @errorName(failure.reason);
                            try self.nextBlock(app);
                        }
                    }
                },
            }
        }
        if (self.copy_pending) |selection| {
            self.worker.copy(selection) catch |err| switch (err) {
                error.Busy => {
                    Wake.notify(self.wake);
                    return;
                },
                else => return err,
            };
            self.copy_pending = null;
        }
        if (self.source_pending) {
            self.worker.submit(self.worker_key.?, self.source[0..self.source_len]) catch |err| switch (err) {
                error.Busy => {
                    Wake.notify(self.wake);
                    return;
                },
                else => return err,
            };
            self.source_pending = false;
        }
        if (!self.history_paused) {
            if (self.tile_request) |request| {
                self.worker.request(request) catch |err| switch (err) {
                    error.Busy => {
                        Wake.notify(self.wake);
                        return;
                    },
                    else => return err,
                };
                self.tile_request = null;
            }
        }
        // Only an explicit sign-in needs a short-lived UI status timer. Normal
        // idle remains event-driven; the Host owns the authentication process.
        if (self.setup_login_after_configure) |login| {
            if (!self.configuration_pending and self.runtime_configured and self.query == null and self.command == null and self.workspace.len != 0 and !self.refresh) {
                try self.submit(.login, .absent, .absent, .{ .runtime_login = login }, 0);
                self.setup_login_after_configure = null;
                self.catalog_refresh_pending = false;
                app.dirty = true;
            }
        }
        if (self.login_inflight and self.query == null and self.command == null and c.SDL_GetTicks() >= self.login_poll_due) {
            self.login_poll_due = c.SDL_GetTicks() + 500;
            try self.ask(.runtime_status, .{ .runtime_status = {} });
        }
        // All discovery runs on Host's worker. Wait for the current query chain;
        // its output must not race a setup receipt that starts another chain.
        if (!self.login_inflight and self.setup_login_after_configure == null and self.catalog_refresh_pending and self.query == null and self.command == null and self.workspace.len != 0 and !self.refresh and (self.worker_key == null or self.history_paused)) {
            try self.submit(.refresh_models, .absent, .absent, .{ .runtime_refresh = {} }, 0);
            self.catalog_refresh_pending = false;
            self.catalog_refresh_inflight = true;
            app.dirty = true;
        }
        if (self.refresh and self.query == null and self.command == null and (self.worker_key == null or self.history_paused) and self.thread.len != 0) {
            self.refresh = false;
            if (app.view.follow_latest) {
                self.history_paused = false;
                self.worker_key = null;
                self.tile_request = null;
                self.message_snapshot = null;
                self.message_anchor = null;
                self.message_direction = .older;
            }
            self.card_rows_seen = 0;
            self.thread_page_snapshot = null;
            self.thread_page_cursor = null;
            self.thread_page_anchor = null;
            app.view.search_more_available = false;
            try self.ask(.cards, .{ .threads = .{ .page = page } });
        }
        const terminal = if (self.run_state) |state| switch (state) {
            .completed, .cancelled, .failed, .interrupted, .unknown => true,
            else => false,
        } else true;
        const settled = self.command == null and self.query == null and !self.refresh and (self.worker_key == null or self.history_paused);
        if (self.unknown_send == null and settled and terminal and self.thread.len != 0 and self.selectionNeedsSave(&app.view)) {
            const selected = app.view.selected.?;
            try self.submit(.selection, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, .{ .thread_select = .{ .selection = selected.selection() } }, 0);
            self.attempted_selection = selected;
            app.dirty = true;
        }
        const selection_reason = self.selectionDisabledReason(&app.view);
        const preflight_reason = self.sendPreflight(&app.view);
        app.view.send_disabled_reason = if (self.attachment_loading) "Reading attachment… Wait for admission before sending." else if (app.view.attachments.count != 0) "Attachments are local only. Remove them in More (F10) before sending." else if (app.view.followup_editing != null) "Editing a follow-up. Use More (F10) to save it to the current run." else if (preflight_reason) |reason| reason else if (selection_reason) |reason| reason else if (self.thread.len == 0)
            "Opening conversation…"
        else if (!terminal)
            "Wait for this run to finish, or cancel it."
        else if (self.command != null or !settled)
            "Updating conversation…"
        else
            null;
        if (self.command == null and app.view.send_diagnostic.command_id_len == 0 and app.view.send_diagnostic.run_id_len == 0) {
            if (preflight_reason != null) {
                const preflight = domain.startPreflight(app.view.editor.len);
                app.view.send_diagnostic.prompt_bytes = preflight.prompt_bytes;
                app.view.send_diagnostic.frame_bytes = preflight.frame_bytes;
                app.view.send_diagnostic.stage = .preflight_rejected;
            } else if (app.view.send_disabled_reason != null and app.view.send_diagnostic.stage == .idle) {
                app.view.send_diagnostic.stage = .disabled;
            } else if (app.view.send_disabled_reason == null and (app.view.send_diagnostic.stage == .disabled or app.view.send_diagnostic.stage == .preflight_rejected)) {
                app.view.send_diagnostic.stage = .idle;
            }
        }
        app.view.workflow_active = !terminal and self.run_state != .queued and self.run_state != .cancel_requested;
        app.view.workflow_busy = !settled or self.attachment_loading or self.unknown_send != null;
        app.view.can_send = app.view.send_disabled_reason == null;
        app.view.can_cancel = self.unknown_send == null and self.run.len != 0 and !terminal and self.command == null;
        app.view.tasks_enabled = self.command == null and !self.refresh;
        app.view.can_approve = self.unknown_send == null and self.approval_live and self.command == null and !self.refresh;
        app.view.navigation_enabled = self.unknown_send == null and (!self.normal_startup or self.runtime_configured) and self.command == null and self.query == null and !self.refresh and !self.attachment_loading and !self.source_pending and (self.worker_key == null or self.history_paused);
        app.view.setup_busy = self.unknown_send != null or self.command != null or self.query != null or self.setup_login_after_configure != null;
        app.view.setup_login_pending = self.login_inflight;
        app.view.setup_feedback = app.view.notice;
        if (self.pending_history_move) |move| {
            if (self.query == null and !self.source_pending and (self.history_paused or self.worker_key == null)) {
                self.pending_history_move = null;
                try self.navigate(app, move);
                Wake.notify(self.wake);
            }
        }
    }

    fn receipt(self: *Conversation, app: *App, ticket: types.Ticket, value: types.Receipt) !void {
        const pending = self.command orelse return error.UnexpectedCommandReceipt;
        if (pending.ticket.value != ticket.value or !std.mem.eql(u8, &pending.id, value.command_id.value)) return error.UnexpectedCommandReceipt;
        self.command = null;
        if (pending.kind == .send) self.unknown_send = null;
        const workflow_command = switch (pending.kind) {
            .followup_enqueue, .followup_edit, .followup_cancel, .followup_order, .attachment_add, .attachment_remove => true,
            else => false,
        };
        if (workflow_command and (!self.workflow_pending.thread.eql(self.thread.slice()) or !self.workflow_pending.run.eql(self.run.slice()))) return error.StaleWorkflowReceipt;
        if (value.outcome == .rejected) {
            if (workflow_command) {
                app.view.workflow_error = if (value.reason) |reason| @tagName(reason) else "rejected";
                app.view.workflowNotice(switch (pending.kind) {
                    .attachment_add => "Attachments are unavailable. File kept locally; nothing sent.",
                    .attachment_remove => "Local file removed. Provider attachment removal is unavailable.",
                    else => "Follow-up refused by the provider. Your draft is retained.",
                });
            }
            if (pending.kind == .send) {
                app.view.send_diagnostic.setReceipt(.rejected, if (value.reason) |reason| @tagName(reason) else "command_rejected");
            }
            if (pending.kind == .title) {
                app.view.title_editing = true;
                self.notice(&app.view, if (value.reason) |reason| rejectionMessage(reason) else "Title was rejected; your edit is retained.");
            }
            if (pending.kind == .refresh_models) self.catalog_refresh_inflight = false;
            if (pending.kind == .configure) {
                self.setup_login_after_configure = null;
                self.submitted_setup_key = null;
            }
            const setup_busy = value.reason == .busy and (pending.kind == .configure or pending.kind == .refresh_models or pending.kind == .login);
            if (pending.kind == .send and !setup_busy) {
                const reason = if (value.reason) |why| rejectionMessage(why) else "Command rejected. Open Connection to inspect provider status.";
                app.view.notice = std.fmt.bufPrint(&self.notice_storage, "{s} (Send rejected; command {s})", .{ reason, pending.id[0..] }) catch reason;
            } else self.notice(&app.view, if (setup_busy)
                "A run is using a provider. Close Connection, open its chat and Stop it, then retry."
            else if (value.reason) |reason| rejectionMessage(reason) else "Command rejected. Open Connection to inspect provider status.");
            self.refresh = self.thread.len != 0;
            return;
        }
        switch (pending.kind) {
            .title => {
                app.view.title_editing = false;
                app.view.title_select_all = false;
                self.title_pending_len = 0;
                self.refresh = true;
                self.notice(&app.view, "Chat title saved.");
            },
            .prompt_cleanup => app.view.workflowNotice("One unfinished upload discarded. Your draft is retained; close More and retry Send."),
            .attachment_add, .attachment_remove => {
                app.view.workflowNotice("Host accepted metadata command; provider delivery remains unavailable.");
                self.refresh = true;
            },
            .followup_enqueue, .followup_edit => {
                const id = if (pending.kind == .followup_enqueue) try Id.init(value.entity_ids.followup.?.value) else self.workflow_pending.id;
                var found: ?usize = null;
                for (app.view.followups[0..app.view.followup_count], 0..) |item, i| if (item.id.eql(id.slice())) {
                    found = i;
                };
                const index = found orelse app.view.followup_count;
                if (index >= app.view.followups.len) return error.FollowupLimit;
                const owned = try self.allocator.dupe(u8, self.workflow_pending.content[0..self.workflow_pending.len]);
                const slot = &app.view.followups[index];
                if (found != null) self.allocator.free(slot.content);
                slot.* = .{ .id = id, .len = owned.len, .content = owned };
                if (found == null) app.view.followup_count += 1;
                app.view.followup_editing = null;
                if (app.view.revision == pending.draft_revision) {
                    try app.view.editor.setText("");
                    app.view.revision += 1;
                    app.view.editor_view.changed = true;
                }
                app.view.workflowNotice("Host accepted follow-up; effect status below tracks delivery.");
                self.refresh = true;
            },
            .followup_cancel => {
                app.view.workflowNotice("Host accepted follow-up withdrawal.");
                self.refresh = true;
            },
            .followup_order => {
                var reordered: [8]Coding.Followup = undefined;
                for (0..self.workflow_pending.order_count) |i| {
                    for (app.view.followups[0..app.view.followup_count]) |item| if (item.id.eql(self.workflow_pending.order_ids[i].slice())) {
                        reordered[i] = item;
                    };
                }
                @memcpy(app.view.followups[0..app.view.followup_count], reordered[0..app.view.followup_count]);
                app.view.workflowNotice("Host accepted follow-up order.");
                self.refresh = true;
            },
            .project => {
                self.project = try Id.init(value.entity_ids.project.?.value);
                try addEntry(&app.view.projects, &app.view.project_count, self.project.slice(), "Coding project");
                try self.createWorkspace();
            },
            .workspace => {
                self.workspace = try Id.init(value.entity_ids.workspace.?.value);
                self.inspection_workspace = self.workspace;
                try self.createThread();
            },
            .thread => {
                try self.selectThread(app, try Id.init(value.entity_ids.thread.?.value));
                app.view.thread_count = 0;
                self.card_rows_seen = 0;
                try self.ask(.threads, .{ .threads = .{ .page = page } });
            },
            .send => {
                app.view.send_diagnostic.setReceipt(.accepted, "");
                app.view.send_diagnostic.setRunState("queued");
                app.view.notice = null;
                if (app.view.revision == pending.draft_revision) {
                    try app.view.editor.setText("");
                    app.view.revision += 1;
                    app.view.editor_view.changed = true;
                }
                self.run = try Id.init(value.entity_ids.run.?.value);
                if (value.entity_ids.session) |session| app.view.send_diagnostic.setRun(value.entity_ids.run.?.value, session.value);
                if (value.effect_ids.len != 0) app.view.send_diagnostic.setEffect(value.effect_ids[value.effect_ids.len - 1].value);
                self.refresh = true;
            },
            .cancel, .approval => {
                self.approval_live = false;
                self.refresh = true;
            },
            .selection => {
                self.durable_selection = self.attempted_selection;
                self.attempted_selection = null;
                self.refresh = true;
            },
            .configure => {
                app.view.notice = null;
                self.configuration_pending = true;
                self.close_setup_after_refresh = true;
                self.launch_selection = null;
                self.catalog_refresh_pending = true;
                try self.ask(.runtime_status, .{ .runtime_status = {} });
            },
            .login => {
                app.view.notice = null;
                self.login_inflight = true;
                self.login_poll_due = c.SDL_GetTicks() + 500;
                self.catalog_refresh_pending = false;
                try self.ask(.runtime_status, .{ .runtime_status = {} });
            },
            .refresh_models => try self.ask(.runtime_status, .{ .runtime_status = {} }),
        }
    }

    fn createWorkspace(self: *Conversation) !void {
        self.create_thread_after_workspace = false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const binding = try domain.workspace_binding.capture(arena.allocator(), self.io, self.workspace_root);
        try self.retainInspectionBinding(binding);
        self.workspace_branch = try displayId(binding.expected_branch);
        try self.submit(.workspace, .absent, .absent, .{ .workspace_register = .{ .project = .{ .value = self.project.slice() }, .binding = binding } }, 0);
    }
    fn createThread(self: *Conversation) !void {
        try self.submit(.thread, .absent, .absent, .{ .thread_create = .{ .project = .{ .value = self.project.slice() }, .workspace = .{ .value = self.workspace.slice() } } }, 0);
    }

    fn consume(self: *Conversation, app: *App, kind: QueryKind, value: types.QueryPage) !void {
        switch (kind) {
            .send_receipt => {
                const pending = self.unknown_send orelse return;
                if (value.items.len != 1 or value.items[0] != .command_receipt) return error.UnexpectedCommandReceipt;
                if (value.items[0].command_receipt) |committed| {
                    self.command = pending;
                    try self.receipt(app, pending.ticket, committed);
                } else {
                    self.unknown_send = null;
                    app.view.send_diagnostic.stage = .admission_failed;
                    self.notice(&app.view, "Previous Send did not commit. Your draft is retained; retry Send when storage is available.");
                }
            },
            .capabilities => {
                self.followup_capability = .unknown;
                self.capability_runtime = .{};
                for (value.items) |row| {
                    self.followup_capability = row.capabilities.capabilities[@intFromEnum(contract.Capability.followup_queue)].status;
                    self.capability_runtime = try Id.init(row.capabilities.runtime_kind);
                    if (self.followup_capability != .supported and app.view.workflow_feedback_len == 0) app.view.workflowNotice("This provider does not support follow-ups. Questions and attachments are also unavailable.");
                }
                try self.askRuns();
            },
            .runtime_status, .startup_status => {
                app.view.runtime_info_len = 0;
                for (value.items) |row| {
                    const status = row.runtime_status;
                    if (self.login_inflight) {
                        self.login_inflight = status.login_pending;
                        if (!status.login_pending and status.readiness == .ready) {
                            self.catalog_refresh_pending = true;
                            self.close_setup_after_refresh = true;
                        }
                    }
                    self.login_poll_due = c.SDL_GetTicks() + 500;
                    self.updateLogin(&app.view, status.login);
                    const remaining = app.view.runtime_info[app.view.runtime_info_len..];
                    const written = if (status.runtime_kind.len == 0)
                        std.fmt.bufPrint(remaining, "No provider connected. Choose a provider and workspace above.\n", .{}) catch continue
                    else
                        std.fmt.bufPrint(remaining, "{s}: {s}\n{s}\n", .{ status.runtime_kind, @tagName(status.readiness), @import("text/utf8.zig").prefix(status.reason, 3000) }) catch continue;
                    app.view.runtime_info_len += written.len;
                    if (kind == .startup_status) {
                        if (try self.restoreStartup(&app.view, status)) {
                            if (self.catalog_refresh_pending) {
                                // Discover before history snapshots are captured;
                                // catalog commits must not invalidate startup reads.
                                self.catalog_refresh_pending = false;
                                self.catalog_refresh_inflight = true;
                                self.bootstrap_after_catalog = true;
                                try self.submit(.refresh_models, .absent, .absent, .{ .runtime_refresh = {} }, 0);
                            } else try self.ask(.projects, .{ .projects = .{ .limit = 16, .max_bytes = 16 * 1024 } });
                        } else {
                            app.view.setup_open = true;
                            app.view.status = "Choose a provider";
                        }
                        return;
                    }
                    if (status.readiness == .unavailable) {
                        if (self.bootstrap_after_catalog) app.view.setup_open = true;
                        self.close_setup_after_refresh = false;
                        var message: [1024]u8 = undefined;
                        self.notice(&app.view, if (self.configuration_pending)
                            std.fmt.bufPrint(&message, "Connection settings were not applied: {s}. Check the fields above and try again.", .{@import("text/utf8.zig").prefix(status.reason, 800)}) catch "Connection settings were not applied. Check the fields above."
                        else
                            std.fmt.bufPrint(&message, "Provider unavailable: {s}. Check sign-in and Refresh models.", .{@import("text/utf8.zig").prefix(status.reason, 800)}) catch "Provider unavailable. Check paths and sign-in.");
                        if (self.configuration_pending) {
                            self.configuration_pending = false;
                            self.catalog_refresh_pending = false;
                            self.setup_login_after_configure = null;
                            self.submitted_setup_key = null;
                        }
                    }
                    if (self.configuration_pending and status.workspace_root.len != 0 and status.binding != null) {
                        self.configuration_pending = false;
                        if (status.configuration) |configuration| {
                            self.configured_setup_key = setupKey(configuration);
                            if (self.submitted_setup_key) |submitted| {
                                const shown = setupKey(setupConfiguration(&app.view));
                                // Canonicalize only the submitted draft; edits or
                                // provider switches made while waiting remain local.
                                if (std.mem.eql(u8, &shown, &submitted)) _ = app.view.configureSetup(configuration);
                            }
                        }
                        self.submitted_setup_key = null;
                        self.workspace_branch = try displayId(status.binding.?.expected_branch);
                        const root = try self.allocator.dupe(u8, status.workspace_root);
                        self.allocator.free(self.workspace_root);
                        self.workspace_root = root;
                        self.runtime_configured = true;
                        try self.retainInspectionBinding(status.binding.?);
                        self.inspection_workspace = .{};
                        app.view.workspace_checkout_len = 0;
                        app.view.workspace_file_count = 0;
                        app.view.workspace_diff_len = 0;
                        app.view.selected = null;
                        app.view.thread_count = 0;
                        app.view.scope_project = .{};
                        self.refresh = false;
                        if (self.project.len == 0) {
                            try self.ask(.projects, .{ .projects = .{ .limit = 16, .max_bytes = 16 * 1024 } });
                            return;
                        }
                        try self.submit(.workspace, .absent, .absent, .{ .workspace_register = .{ .project = .{ .value = self.project.slice() }, .binding = status.binding.? } }, 0);
                        return;
                    }
                }
                if (self.bootstrap_after_catalog) {
                    self.bootstrap_after_catalog = false;
                    try self.ask(.projects, .{ .projects = .{ .limit = 16, .max_bytes = 16 * 1024 } });
                    return;
                }
                if (kind == .startup_status) {
                    app.view.setup_open = true;
                    app.view.status = "Choose a provider";
                    return;
                }
                if (self.workspace.len != 0) {
                    app.view.model_count = 0;
                    self.catalog_truncated = false;
                    try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024 } } });
                }
            },
            .models => {
                for (value.items) |row| {
                    if (app.view.model_count == app.view.models.len) break;
                    const model = row.model;
                    if (self.normal_startup and model.synthetic) continue;
                    const target = &app.view.models[app.view.model_count];
                    target.* = .{ .identity = try Coding.Identity.from(model.selection), .readiness = model.readiness, .synthetic = model.synthetic };
                    target.reason_len = @import("text/utf8.zig").prefix(model.reason, target.reason.len).len;
                    @memcpy(target.reason[0..target.reason_len], model.reason[0..target.reason_len]);
                    for (model.supported_efforts) |effort| {
                        if (target.effort_count == target.efforts.len) break;
                        target.efforts[target.effort_count] = if (effort.len == 0) .{} else try Id.init(effort);
                        target.effort_count += 1;
                    }
                    // Only the independent synthetic fixture has an implicit
                    // default. A real catalog never changes an explicit choice.
                    if (app.view.selected == null and self.launch_selection == null and target.synthetic and contract.isFakeSelection(target.identity.selection())) app.view.selected = target.identity;
                    app.view.model_count += 1;
                }
                if (value.next_cursor != null and app.view.model_count < app.view.models.len) {
                    try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024, .snapshot = value.snapshot_id, .cursor = value.next_cursor } } });
                } else {
                    self.catalog_truncated = value.next_cursor != null;
                    self.catalog_refresh_inflight = false;
                    if (self.close_setup_after_refresh and !self.catalog_refresh_pending and app.view.model_count != 0) {
                        self.close_setup_after_refresh = false;
                        app.view.setup_open = false;
                        if (app.view.notice) |message| {
                            if (std.mem.startsWith(u8, message, "Provider unavailable:")) app.view.notice = null;
                        }
                    }
                    try self.ask(.capabilities, .{ .capabilities = {} });
                }
            },
            .projects => {
                if (self.startup_probe_pending) {
                    self.startup_probe_pending = false;
                    try self.ask(.startup_status, .{ .runtime_status = {} });
                    return;
                }
                for (value.items) |row| try addEntry(&app.view.projects, &app.view.project_count, row.project.id.value, row.project.display_name);
                if (value.items.len == 0) try self.submit(.project, .absent, .absent, .{ .project_create = .{ .display_name = "Native coding workspace" } }, 0) else {
                    self.project = try Id.init(value.items[0].project.id.value);
                    try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = page } });
                }
            },
            .workspaces => {
                var selected = false;
                for (value.items) |row| {
                    if (!std.mem.eql(u8, row.workspace.binding.canonical_root, self.workspace_root)) continue;
                    try self.retainInspectionBinding(row.workspace.binding);
                    self.inspection_workspace = try Id.init(row.workspace.id.value);
                    self.workspace = try Id.init(row.workspace.id.value);
                    self.workspace_branch = try displayId(row.workspace.binding.expected_branch);
                    selected = true;
                    break;
                }
                if (selected) {
                    if (self.create_thread_after_workspace) {
                        self.create_thread_after_workspace = false;
                        try self.createThread();
                    } else {
                        self.card_rows_seen = 0;
                        try self.ask(.threads, .{ .threads = .{ .page = page } });
                    }
                } else if (value.next_cursor) |cursor| {
                    try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = .{ .limit = page.limit, .max_bytes = page.max_bytes, .snapshot = value.snapshot_id, .cursor = cursor } } });
                } else try self.createWorkspace();
            },
            .threads, .cards => {
                for (value.items) |row| {
                    self.card_rows_seen += 1;
                    if (!std.mem.eql(u8, row.thread.workspace_root, self.workspace_root)) continue;
                    try self.updateThreadCard(&app.view, row.thread);
                    if (std.mem.eql(u8, row.thread.project.value, self.project.slice())) {
                        if (self.startup_runtime) |runtime| {
                            if (row.thread.selection) |selection| {
                                if (std.mem.eql(u8, selection.runtime_kind, @tagName(runtime)) and std.mem.eql(u8, selection.account_ref, self.startup_account[0..self.startup_account_len])) self.thread = try Id.init(row.thread.id.value);
                            }
                        } else if (self.thread.len == 0) self.thread = try Id.init(row.thread.id.value);
                    }
                }
                if (value.next_cursor != null and app.view.thread_count < app.view.threads.len and self.card_rows_seen < 128) {
                    self.thread_page_snapshot = value.snapshot_id;
                    self.thread_page_cursor = try Id.init(value.next_cursor.?);
                    app.view.search_more_available = false;
                    try self.ask(kind, .{ .threads = .{ .page = .{ .limit = page.limit, .max_bytes = page.max_bytes, .snapshot = value.snapshot_id, .cursor = value.next_cursor } } });
                } else {
                    self.thread_page_snapshot = value.snapshot_id;
                    self.thread_page_cursor = if (value.next_cursor) |cursor| try Id.init(cursor) else null;
                    self.thread_page_anchor = if (value.items.len != 0) try Id.init(value.items[value.items.len - 1].thread.id.value) else self.thread_page_anchor;
                    app.view.search_more_available = self.thread_page_cursor != null;
                    self.startup_runtime = null;
                    if (kind == .cards) {
                        try self.ask(.thread, .{ .thread = .{ .value = self.thread.slice() } });
                    } else if (self.thread.len != 0) {
                        try self.selectThread(app, self.thread);
                    } else try self.createThread();
                }
            },
            .inspection_workspace => {
                for (value.items) |row| {
                    if (!self.workspace.eql(row.workspace.id.value)) continue;
                    if (!std.mem.eql(u8, row.workspace.binding.canonical_root, self.workspace_root)) return error.WrongCheckout;
                    try self.retainInspectionBinding(row.workspace.binding);
                    self.inspection_workspace = self.workspace;
                    try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024 } } });
                    return;
                }
                if (value.next_cursor) |cursor| {
                    try self.ask(.inspection_workspace, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = .{ .limit = page.limit, .max_bytes = page.max_bytes, .snapshot = value.snapshot_id, .cursor = cursor } } });
                } else {
                    self.inspectionFailure(&app.view, "The selected thread's registered checkout is unavailable.");
                    try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024 } } });
                }
            },
            .thread => {
                if (value.items.len != 1) return error.MissingThread;
                if (!std.mem.eql(u8, value.items[0].thread.workspace_root, self.workspace_root)) return error.WrongCheckout;
                self.project = try Id.init(value.items[0].thread.project.value);
                try self.updateThreadCard(&app.view, value.items[0].thread);
                self.thread_revision = value.items[0].thread.revision;
                self.workspace = try Id.init(value.items[0].thread.workspace.value);
                try self.restoreSelection(&app.view, value.items[0].thread.selection);
                var chat: []const u8 = "Chat";
                for (app.view.threads[0..app.view.thread_count]) |*entry| if (entry.id.eql(self.thread.slice())) {
                    chat = entry.label[0..entry.len];
                    break;
                };
                const label = try std.fmt.bufPrint(&app.view.workspace_label, "{s}  •  {s}", .{ @import("text/utf8.zig").prefix(self.workspace_root, 320), chat });
                app.view.workspace_label_len = label.len;
                if (self.subscription == null and self.subscribe_ticket == null) self.subscribe_ticket = try self.host.subscribe(.{ .scope = .all, .after_position = value.snapshot_position, .max_batch_bytes = 16 * 1024 });
                self.runs_cursor = null;
                self.runs_snapshot = null;
                app.view.model_count = 0;
                self.catalog_truncated = false;
                if (!self.inspection_workspace.eql(self.workspace.slice())) {
                    self.inspection_revision +%= 1;
                    self.inspection_request = null;
                    self.inspection_binding = null;
                    app.view.workspace_checkout_len = 0;
                    app.view.workspace_file_count = 0;
                    app.view.workspace_diff_len = 0;
                    app.view.workspace_selected_file = null;
                    app.view.workspace_busy = false;
                    try self.ask(.inspection_workspace, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = page } });
                } else try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024 } } });
            },
            .runs => {
                for (value.items) |row| try self.recordRun(&app.view, row.run);
                if (self.run_state == null) app.view.status = "Ready";
                if (value.next_cursor) |cursor| {
                    self.runs_cursor = try Id.init(cursor);
                    self.runs_snapshot = value.snapshot_id;
                    try self.askRuns();
                } else {
                    self.approval_live = false;
                    if (self.run.len != 0) {
                        try self.ask(.effects, .{ .effects = .{ .run = .{ .value = self.run.slice() }, .page = page } });
                    } else {
                        app.view.scopeWorkflow(.{});
                        try self.askHistory(app);
                    }
                }
            },
            .effects => {
                app.view.scopeWorkflow(self.run);
                for (value.items) |row| {
                    self.recordEffect(&app.view, row.effect);
                    if (!self.run.eql(row.effect.run.value)) continue;
                    for (app.view.followups[0..app.view.followup_count]) |*item| if (item.id.eql(row.effect.id.value)) {
                        item.revision = row.effect.revision;
                        item.state = @enumFromInt(@intFromEnum(row.effect.state));
                    };
                }
                if (value.next_cursor != null) {
                    var bounds = page;
                    bounds.cursor = value.next_cursor;
                    bounds.snapshot = value.snapshot_id;
                    try self.ask(.effects, .{ .effects = .{ .run = .{ .value = self.run.slice() }, .page = bounds } });
                } else try self.ask(.approvals, .{ .approvals = .{ .run = .{ .value = self.run.slice() }, .page = page } });
            },
            .approvals => {
                for (value.items) |row| if (row.approval.state == .pending and row.approval.live) {
                    self.approval = try Id.init(row.approval.id.value);
                    self.approval_revision = row.approval.revision;
                    self.approval_digest = try Id.init(row.approval.evidence.action_digest);
                    self.approval_live = true;
                };
                app.view.task_count = 0;
                try self.ask(.tasks, .{ .task_list = .{ .parent = .{ .value = self.run.slice() }, .page = .{ .limit = 16, .max_bytes = 64 * 1024 } } });
            },
            .tasks => {
                for (value.items) |row| {
                    if (app.view.task_count == app.view.tasks.len) break;
                    const task = row.task;
                    const line = &app.view.tasks[app.view.task_count];
                    const label = std.fmt.bufPrint(&line.bytes, "{s} | {s}/{s} | {s} | requests {d} | observed tokens {d} | {s}", .{
                        task.task.packet.purpose,
                        task.task.packet.selection.runtime_kind,
                        task.task.packet.selection.model_id,
                        @tagName(task.state),
                        task.task.requests,
                        task.task.input_tokens +| task.task.output_tokens,
                        if (task.task.result) |result| result.summary[0..@min(result.summary.len, 80)] else "No result submitted",
                    }) catch fallback: {
                        const message = "Task label exceeds display budget";
                        @memcpy(line.bytes[0..message.len], message);
                        break :fallback line.bytes[0..message.len];
                    };
                    line.len = label.len;
                    line.cancel = switch (task.state) {
                        .completed, .cancelled, .failed, .cancel_requested => null,
                        else => if (task.task.id.value.len == 32) .{ .id = task.task.id.value[0..32].*, .revision = task.revision } else null,
                    };
                    app.view.task_count += 1;
                }
                if (value.next_cursor) |cursor| {
                    try self.ask(.tasks, .{ .task_list = .{ .parent = .{ .value = self.run.slice() }, .page = .{ .limit = 16, .max_bytes = 64 * 1024, .snapshot = value.snapshot_id, .cursor = cursor } } });
                } else if (app.view.follow_latest or self.message_count == 0 or app.view.history_restore) try self.askHistory(app);
            },
            .messages => {
                if (value.items.len == 0) {
                    self.history_paused = true;
                    return;
                }
                self.message_snapshot = value.snapshot_id;
                self.message_count = value.items.len;
                self.message_index = 0;
                for (value.items, 0..) |_, index| {
                    const source_index = if (self.message_direction == .older) value.items.len - 1 - index else index;
                    const message = value.items[source_index].message;
                    self.messages[index] = try Id.init(message.message_id.value);
                    self.message_roles[index] = message.role;
                    self.message_ordinals[index] = message.ordinal;
                }
                self.generation += 1;
                self.history_first = null;
                self.block_cursor = null;
                self.block_snapshot = null;
                try self.askBlocks();
            },
            .blocks => {
                self.block_snapshot = value.snapshot_id;
                self.block_cursor = if (value.next_cursor) |cursor| try Id.init(cursor) else null;
                self.block_count = value.items.len;
                self.block_index = 0;
                for (value.items, 0..) |row, index| self.blocks[index] = .{ .id = try Id.init(row.block.block_id.value), .revision = row.block.revision, .bytes = row.block.committed_bytes, .ordinal = row.block.ordinal };
                if (self.desired_block) |ordinal| {
                    while (self.block_index < self.block_count and self.blocks[self.block_index].ordinal < ordinal) self.block_index += 1;
                    if (self.block_index == self.block_count and self.block_cursor != null) return self.askBlocks();
                    self.desired_block = null;
                    if (self.recovery_block) |id| {
                        if (self.block_index == self.block_count or !id.eql(self.blocks[self.block_index].id.slice())) {
                            app.view.notice = "History anchor no longer exists";
                            self.history_paused = true;
                            return;
                        }
                    }
                    if (self.block_index < self.block_count) self.reconcileRestoredRevision(&app.view, self.blocks[self.block_index].revision);
                    app.view.clearHistory();
                    self.history_first = null;
                }
                if (self.block_index < self.block_count) try self.startBlock(app) else try self.nextMessage();
            },
            .content => {
                if (value.items.len != 1) return error.MissingContent;
                const content = value.items[0].content;
                const block = &self.blocks[self.block_index];
                if (content.revision != block.revision) {
                    self.refresh = true;
                    try self.nextBlock(app);
                    return;
                }
                if (content.start_byte != self.source_len or content.end_byte > self.source.len) return error.ContentRange;
                @memcpy(self.source[self.source_len..@intCast(content.end_byte)], content.bytes);
                self.source_len = @intCast(content.end_byte);
                if (self.source_len < block.bytes) try self.askContent() else self.source_pending = true;
            },
        }
    }

    fn askRuns(self: *Conversation) !void {
        var bounds = page;
        bounds.limit = 32;
        bounds.cursor = if (self.runs_cursor) |*cursor| cursor.slice() else null;
        bounds.snapshot = self.runs_snapshot;
        try self.ask(.runs, .{ .runs = .{ .thread = .{ .value = self.thread.slice() }, .page = bounds } });
    }
    fn askMessages(self: *Conversation) !void {
        var bounds = page;
        bounds.limit = if (self.message_anchor != null or self.message_direction == .newer) 1 else self.messages.len;
        bounds.snapshot = self.message_snapshot;
        try self.ask(.messages, .{ .messages = .{ .thread = .{ .value = self.thread.slice() }, .anchor = if (self.message_anchor) |*anchor| .{ .value = anchor.slice() } else null, .direction = self.message_direction, .page = bounds } });
        self.history_paused = false;
    }
    fn askBlocks(self: *Conversation) !void {
        var bounds = page;
        bounds.snapshot = self.block_snapshot;
        bounds.cursor = if (self.block_cursor) |*cursor| cursor.slice() else null;
        try self.ask(.blocks, .{ .blocks = .{ .message = .{ .value = self.messages[self.message_index].slice() }, .page = bounds } });
    }
    fn startBlock(self: *Conversation, app: *App) !void {
        const block = &self.blocks[self.block_index];
        if (block.bytes > self.source.len) {
            app.view.notice = "Content exceeds one-MiB rich display budget; canonical source is retained";
            return self.nextBlock(app);
        }
        self.source_len = 0;
        const digest = types.digest(block.id.slice());
        self.worker_key = .{ .source = digest[0..16].*, .revision = block.revision, .generation = self.generation };
        if (block.bytes == 0) return self.nextBlock(app);
        try self.askContent();
    }
    fn askContent(self: *Conversation) !void {
        const block = &self.blocks[self.block_index];
        var bounds = page;
        bounds.snapshot = self.block_snapshot;
        try self.ask(.content, .{ .content = .{ .block = .{ .value = block.id.slice() }, .start_byte = self.source_len, .end_byte = @min(block.bytes, self.source_len + 16 * 1024), .page = bounds } });
    }
    fn nextBlock(self: *Conversation, app: *App) anyerror!void {
        self.worker_key = null;
        self.block_index += 1;
        if (self.block_index < self.block_count) try self.startBlock(app) else if (self.block_cursor != null) try self.askBlocks() else try self.nextMessage();
    }
    fn nextMessage(self: *Conversation) !void {
        self.message_index += 1;
        self.block_cursor = null;
        self.block_snapshot = null;
        self.worker_key = null;
        if (self.message_index < self.message_count) try self.askBlocks() else self.history_paused = true;
    }
};

test "ordinary text admission failure stays local and preserves draft and undo" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    app.snapshot = .{};
    app.dirty = false;
    app.metrics = null;
    app.conversation = null;
    app.lua = null;
    var full: [64 * 1024]u8 = @splat('x');
    try app.view.editor.setText(&full);
    app.view.editor.selectAll();
    try app.view.insert("retained", .paste);
    try std.testing.expect(app.view.editor.undo());
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    app.view.editor.setCaret(app.view.editor.len, false);
    event.type = c.SDL_EVENT_TEXT_INPUT;
    event.text.text = "extra";
    try app.handle(event);
    try std.testing.expectEqualStrings("TextTooLarge", app.view.notice.?);
    try std.testing.expectEqualSlices(u8, &full, app.view.editor.textBytes());
    try std.testing.expect(app.view.editor.redo());
    try std.testing.expectEqualStrings("retained", app.view.editor.textBytes());
}

test "native re-layout during ordinary key dispatch emits event-boundary cache state" {
    const surface = c.SDL_CreateSurface(200, 100, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const text = c.spica_text_create(renderer, build_options.font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(text);
    var changes: [1]telemetry.CacheChange = undefined;
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    app.text = text;
    app.snapshot = .{};
    app.dirty = false;
    app.metrics = .{ .storage = &.{}, .cache_storage = &changes };
    app.conversation = null;
    app.lua = null;
    app.view.editor_view.width = 200;
    try app.view.insert("hello\nworld", .typing);
    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_DOWN;
    try app.handle(event);
    try std.testing.expectEqual(@as(usize, 1), app.metrics.?.cacheSamples().len);
    try std.testing.expectEqual(@as(u32, 0), app.metrics.?.cacheSamples()[0].before.live_layouts);
    try std.testing.expectEqual(@as(u32, 1), app.metrics.?.cacheSamples()[0].after.live_layouts);
}

test "native Lua handoff rejects root switch and generation before Host access" {
    var bridge: LuaBridge = undefined;
    bridge.active = true;
    bridge.epoch = 4;
    bridge.generation = 9;
    var app: App = undefined;
    var result = std.mem.zeroes(script.Result);
    result.generation = 9;
    var pending = std.mem.zeroes(LuaBridge.Pending);
    pending.generation = 9;
    pending.epoch = 3;
    try std.testing.expectError(error.ObsoleteScriptAction, bridge.admit(&app, &result, pending));
    pending.epoch = 4;
    result.generation = 8;
    try std.testing.expectError(error.ObsoleteScriptAction, bridge.admit(&app, &result, pending));
    result.generation = 9;
    result.intent.context.revision = 1;
    try std.testing.expectError(error.ScriptContextChanged, bridge.admit(&app, &result, pending));
}

test "Lua snapshot copies only bounded visible UTF8 without borrowing tiles" {
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    app.conversation = null;
    app.view.rich_count = 1;
    const tile = &app.view.rich_tiles[0];
    @memset(tile.rendered[0..16383], 'x');
    @memcpy(tile.rendered[16383..16386], "€");
    tile.length = 16386;
    var bridge: LuaBridge = undefined;
    bridge.visible(app);
    try std.testing.expectEqual(@as(usize, 16383), bridge.snapshot.text.len);
    tile.rendered[0] = 'y';
    try std.testing.expectEqual(@as(u8, 'x'), bridge.snapshot.text.bytes[0]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bridge.snapshot.text.bytes[0..bridge.snapshot.text.len]));
}

test "history navigation reuses immutable projection and coalesces busy input" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    const key = presentation.Key{ .source = @splat(23), .revision = 4, .generation = 1 };
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    conversation.block_count = 1;
    conversation.blocks[0] = .{ .id = try Id.init("stable-block"), .revision = 4, .bytes = 523183, .ordinal = 0 };
    conversation.worker_key = key;
    conversation.projected_key = key;
    conversation.history_paused = true;
    // No query page and no visible anchor is a harmless boundary.
    try conversation.navigate(&app, .previous);
    try std.testing.expect(conversation.tile_request == null);
    // A retained tile supplies the real chronological anchor independently of
    // the current message query page. No Host query or source decode is needed.
    app.view.rich_count = 1;
    const tile = &app.view.rich_tiles[0];
    tile.key = key;
    tile.message = try Id.init("stable-message");
    tile.message_ordinal = 12;
    tile.role = "user";
    tile.canonical_block = conversation.blocks[0].id;
    tile.canonical_ordinal = 0;
    tile.start_byte = 400000;
    try conversation.navigate(&app, .previous);
    try std.testing.expect(conversation.query == null and !conversation.source_pending);
    try std.testing.expect(conversation.tile_request != null);
    try std.testing.expect(conversation.tile_request.?.backward);
    try std.testing.expectEqual(@as(u32, 400000), conversation.tile_request.?.start_byte);
    try std.testing.expectEqual(@as(usize, 1), conversation.message_count);
    try std.testing.expectEqualStrings("stable-message", conversation.messages[0].slice());
    try std.testing.expectEqual(@as(u64, 12), conversation.message_ordinals[0]);
    try std.testing.expectEqual(.user, conversation.message_roles[0]);
    try std.testing.expect(!app.view.follow_latest and !conversation.history_paused);
    try std.testing.expect(std.meta.eql(key, conversation.tile_request.?.key));
    try conversation.navigate(&app, .latest);
    try std.testing.expectEqual(Coding.HistoryMove.latest, conversation.pending_history_move.?);
}

test "expired history continuation restarts queries once at stable block and byte anchor" {
    const key = presentation.Key{ .source = @splat(24), .revision = 7, .generation = 2 };
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    conversation.message_count = 1;
    conversation.messages[0] = try Id.init("stable-message");
    conversation.block_count = 1;
    conversation.blocks[0] = .{ .id = try Id.init("stable-block"), .revision = 7, .bytes = 523183, .ordinal = 11 };
    conversation.history_first = .{ .key = key, .cursor = .{ .block = 2, .byte = 400000 }, .ordinal = 11 };
    conversation.block_snapshot = .{ .slot = 0, .generation = 9 };
    conversation.block_cursor = try Id.init("expired-cursor");
    const retry = conversation.recoveryQuery(.content).?;
    try std.testing.expectEqualStrings("stable-message", retry.value.blocks.message.value);
    try std.testing.expect(retry.value.blocks.page.snapshot == null and retry.value.blocks.page.cursor == null);
    try std.testing.expectEqualStrings("stable-block", conversation.recovery_block.?.slice());
    try std.testing.expectEqual(@as(u64, 11), conversation.desired_block.?);
    try std.testing.expectEqual(@as(u32, 400000), conversation.history_start.?.start_byte);
    try std.testing.expect(conversation.recoveryQuery(.content) == null);
}

test "bounded per-thread position restores stable history IDs bytes pixels and selection" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    view.follow_latest = false;
    view.history_restore = true;
    view.history_position = .{
        .message = try Id.init("selected-old-message"),
        .block = try Id.init("selected-old-block"),
        .block_ordinal = 42,
        .revision = 7,
        .cursor = .{ .block = 8, .byte = 400123 },
        .pixel_offset = 3.5,
        .selection = .{ .source = @splat(25), .revision = 7, .anchor = 400100, .caret = 404200 },
    };
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    try std.testing.expect(conversation.prepareHistoryRestore(&view));
    try std.testing.expectEqualStrings("selected-old-message", conversation.messages[0].slice());
    try std.testing.expectEqualStrings("selected-old-block", conversation.recovery_block.?.slice());
    try std.testing.expectEqual(@as(u32, 400123), conversation.history_start.?.start_byte);
    try std.testing.expectEqual(@as(f32, 3.5), conversation.restored_pixel.?);
    try std.testing.expectEqual(@as(u32, 404200), view.rendered_selection.?.caret);
    const selection = view.rendered_selection.?;
    conversation.reconcileRestoredRevision(&view, 7);
    try std.testing.expectEqual(@as(u32, 8), conversation.history_start.?.first_block);
    try std.testing.expectEqual(@as(u32, 400123), conversation.history_start.?.start_byte);
    try std.testing.expectEqual(@as(f32, 3.5), conversation.restored_pixel.?);
    try std.testing.expectEqualDeep(selection, view.rendered_selection.?);
    try std.testing.expect(conversation.restored_revision == null);
    // The revision check is one-shot, not a later projection's state reset.
    conversation.reconcileRestoredRevision(&view, 8);
    try std.testing.expectEqual(@as(u32, 400123), conversation.history_start.?.start_byte);
    try std.testing.expectEqualDeep(selection, view.rendered_selection.?);
    try std.testing.expect(!view.history_restore and !view.follow_latest);
    try std.testing.expect(!conversation.prepareHistoryRestore(&view));
}

test "changed history revision restarts canonical block after Markdown append shrinks rendering" {
    const markdown = @import("content/markdown.zig");
    const source = "**bold";
    var before = try markdown.parse(std.testing.allocator, @splat(26), source);
    defer before.deinit();
    var after = try markdown.parse(std.testing.allocator, @splat(26), source ++ "**");
    defer after.deinit();
    try std.testing.expectEqualStrings("**bold\n", before.text.items);
    try std.testing.expectEqualStrings("bold\n", after.text.items);
    const old_byte: u32 = @intCast(before.text.items.len - 1);
    try std.testing.expect(old_byte > after.text.items.len);

    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    view.follow_latest = false;
    view.history_position = .{
        .message = try Id.init("selected-old-message"),
        .block = try Id.init("selected-old-block"),
        .block_ordinal = 42,
        .revision = 7,
        .cursor = .{ .block = 0, .byte = old_byte },
        .pixel_offset = 3.5,
        .selection = .{ .source = @splat(26), .revision = 7, .anchor = 2, .caret = old_byte },
    };
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    // Both an out-of-range byte and a stale semantic range must restart, never clamp.
    for ([_]presentation.Cursor{ .{ .block = 0, .byte = old_byte }, .{ .block = 8, .byte = 400123 } }) |cursor| {
        view.history_position.?.cursor = .{ .block = cursor.block, .byte = cursor.byte };
        view.history_restore = true;
        try std.testing.expect(conversation.prepareHistoryRestore(&view));
        conversation.reconcileRestoredRevision(&view, 8);
        try std.testing.expectEqualStrings("selected-old-message", conversation.messages[0].slice());
        try std.testing.expectEqualStrings("selected-old-block", conversation.recovery_block.?.slice());
        try std.testing.expectEqual(@as(u64, 42), conversation.desired_block.?);
        try std.testing.expectEqual(@as(u32, 0), conversation.history_start.?.first_block);
        try std.testing.expectEqual(@as(u32, 0), conversation.history_start.?.start_byte);
        try std.testing.expect(!conversation.history_start.?.backward and !conversation.history_start.?.last);
        try std.testing.expectEqual(@as(f32, 0), conversation.restored_pixel.?);
        try std.testing.expect(view.rendered_selection == null);
        try std.testing.expect(conversation.restored_revision == null);
        try std.testing.expectEqualStrings("History revision changed while away", view.notice.?);
        try std.testing.expect(!view.follow_latest);
    }
}

const usability_selection: contract.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "fixture-provider", .model_id = "explicit-model", .effort = "high", .account_ref = "/isolated/account", .workspace = .{ .value = "durable-workspace" } };

test "send preflight reports accounted bytes and preserves the editable draft revision" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var root = [_]u8{'/'};
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = &root };
    const prompt = ("x" ** 65534) ++ "€";
    try view.editor.setText(prompt[0..65534]);
    view.revision = 17;
    const before = view.editor.textBytes();
    const reason = conversation.promptDisabledReason(prompt.len) orelse return error.ExpectedPreflightRejection;
    try std.testing.expect(std.mem.indexOf(u8, reason, "65537") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "65536") != null);
    try std.testing.expectEqual(@as(u64, 17), view.revision);
    try std.testing.expectEqualSlices(u8, before, view.editor.textBytes());
    try std.testing.expect(domain.startPreflight(view.editor.len).fits());
    try std.testing.expect(!domain.startPreflight(prompt.len).fits());
}

test "native and custom send preflight rejects proposed text before touching Host" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    try app.view.insert("retained Unicode draft €", .paste);
    const revision = app.view.revision;
    const prompt = ("x" ** 65534) ++ "€";
    try conversation.sendIdentified(&app, .absent, .absent, prompt, usability_selection, revision, @splat('a'));
    try std.testing.expect(conversation.command == null);
    try std.testing.expectEqual(.preflight_rejected, app.view.send_diagnostic.stage);
    try std.testing.expectEqual(@as(usize, 65537), app.view.send_diagnostic.prompt_bytes);
    try std.testing.expectEqualStrings("retained Unicode draft €", app.view.editor.textBytes());
    try std.testing.expectEqual(revision, app.view.revision);
    try std.testing.expect(std.mem.indexOf(u8, app.view.notice.?, "Shorten") != null);
    try std.testing.expect(app.view.editor.undo());
    try std.testing.expectEqualStrings("", app.view.editor.textBytes());
}

test "send receipts preserve rejection and newer drafts while exposing accepted provider failure" {
    for ([_]bool{ false, true }) |newer_draft| {
        var app: App = undefined;
        app.view = try Coding.init(std.testing.allocator);
        defer app.view.deinit();
        var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
        try app.view.insert("sent €", .paste);
        const captured_revision = app.view.revision;
        const id = [_]u8{'a'} ** 32;
        app.view.send_diagnostic.begin(&id, app.view.editor.len, domain.startPreflight(app.view.editor.len).frame_bytes);
        conversation.command = .{ .ticket = .{ .value = 1 }, .kind = .send, .draft_revision = captured_revision, .id = id };
        // An authoritative rejection never clears the captured draft or undo.
        try conversation.receipt(&app, .{ .value = 1 }, .{ .command_id = .{ .value = &id }, .outcome = .rejected, .reason = .revision_conflict, .commit_sequence = 1 });
        try std.testing.expectEqualStrings("sent €", app.view.editor.textBytes());
        try std.testing.expectEqual(captured_revision, app.view.revision);
        try std.testing.expectEqual(.rejected, app.view.send_diagnostic.stage);
        try std.testing.expectEqualStrings("revision_conflict", app.view.send_diagnostic.rejection[0..app.view.send_diagnostic.rejection_len]);
        try conversation.recordRun(&app.view, .{ .id = .{ .value = "older-run" }, .revision = 2, .thread = .{ .value = "thread" }, .session = .{ .value = "older-session" }, .state = .failed, .requested = usability_selection, .effective = null, .diagnostic = "Older provider failure" });
        try std.testing.expectEqual(.rejected, app.view.send_diagnostic.stage);
        try std.testing.expectEqual(@as(usize, 0), app.view.send_diagnostic.run_id_len);
        if (newer_draft) try app.view.insert(" newer 😀", .typing);
        const current_revision = app.view.revision;
        app.view.send_diagnostic.begin(&id, "sent €".len, domain.startPreflight("sent €".len).frame_bytes);
        conversation.command = .{ .ticket = .{ .value = 2 }, .kind = .send, .draft_revision = captured_revision, .id = id };
        const receipt: types.Receipt = .{ .command_id = .{ .value = &id }, .outcome = .accepted, .commit_sequence = 2, .entity_ids = .{ .run = .{ .value = "run" }, .session = .{ .value = "session" } } };
        try conversation.receipt(&app, .{ .value = 2 }, receipt);
        try std.testing.expectEqualStrings(if (newer_draft) "sent € newer 😀" else "", app.view.editor.textBytes());
        try std.testing.expectEqual(current_revision + @as(u64, @intFromBool(!newer_draft)), app.view.revision);
        try std.testing.expectEqual(.accepted, app.view.send_diagnostic.receipt);
        try std.testing.expectEqual(.accepted, app.view.send_diagnostic.stage);
        try std.testing.expectError(error.UnexpectedCommandReceipt, conversation.receipt(&app, .{ .value = 2 }, receipt));
        const row: @FieldType(types.Row, "run") = .{ .id = .{ .value = "run" }, .revision = 2, .thread = .{ .value = "thread" }, .session = .{ .value = "session" }, .state = .failed, .requested = usability_selection, .effective = null };
        try conversation.recordRun(&app.view, row);
        conversation.recordEffect(&app.view, .{ .id = .{ .value = "open-effect" }, .revision = 2, .run = .{ .value = "run" }, .kind = .create_session, .state = .failed, .outcome = "Offline fixture: login expired" });
        try std.testing.expectEqual(.provider_failed, app.view.send_diagnostic.stage);
        try std.testing.expectEqual(.accepted, app.view.send_diagnostic.receipt);
        try conversation.recordRun(&app.view, row);
        try std.testing.expectEqualStrings("Offline fixture: login expired", app.view.send_diagnostic.provider[0..app.view.send_diagnostic.provider_len]);
        var buffer: [8192]u8 = undefined;
        const report = try app.sendDiagnosticReport(&buffer);
        try std.testing.expect(std.mem.indexOf(u8, report, "login expired") != null);
        try std.testing.expect(std.mem.indexOf(u8, report, "sent €") == null);
        try std.testing.expect(std.mem.indexOf(u8, report, "\"turn_id\":null") != null);
    }
}

test "send requires complete catalog identity and negotiated effort without claiming entitlement" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    conversation.workspace = try Id.init(usability_selection.workspace.value);
    view.selected = try Coding.Identity.from(usability_selection);
    var catalog = usability_selection;
    catalog.effort = "medium";
    view.models[0] = .{ .identity = try Coding.Identity.from(catalog), .readiness = .unknown, .efforts = @splat(.{}), .effort_count = 2 };
    view.models[0].efforts[0] = try Id.init("medium");
    view.models[0].efforts[1] = try Id.init("high");
    view.model_count = 1;
    try std.testing.expect(conversation.selectionDisabledReason(&view) == null);
    try std.testing.expectEqualStrings("high", view.selected.?.effort.slice());
    view.models[0].readiness = .ready;
    try std.testing.expect(conversation.selectionDisabledReason(&view) == null);
    view.models[0].readiness = .unavailable;
    try std.testing.expect(conversation.selectionDisabledReason(&view) != null);
    view.models[0].readiness = .unknown;
    inline for (.{ "runtime_kind", "required_runtime_version", "model_provider", "model_id", "account_ref", "workspace", "effort" }) |field| {
        const old = @field(view.selected.?, field);
        @field(view.selected.?, field) = try Id.init("different-identity");
        try std.testing.expect(conversation.selectionDisabledReason(&view) != null);
        @field(view.selected.?, field) = old;
    }
    view.selected.?.capability_revision += 1;
    try std.testing.expect(conversation.selectionDisabledReason(&view) != null);
    view.selected.?.capability_revision -= 1;
    view.model_count = 0;
    conversation.catalog_truncated = true;
    try std.testing.expect(std.mem.indexOf(u8, conversation.selectionDisabledReason(&view).?, "32-model view limit") != null);
    try std.testing.expect(contract.equal(view.selected.?.selection(), usability_selection));
}

test "launch seeds explicit connection without putting long paths in bounded workspace IDs" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    app.conversation = &conversation;
    var launch = usability_selection;
    var path: [700]u8 = @splat('p');
    path[0] = '/';
    launch.workspace.value = &path;
    conversation.workspace_root = &path;
    try app.configureRuntime(launch, &path);
    try std.testing.expectEqual(.opencode, app.view.setup_runtime);
    try std.testing.expectEqualStrings(launch.account_ref, app.view.setup_fields[1][0..app.view.setup_lengths[1]]);
    try std.testing.expectEqualStrings(launch.model_provider, app.view.setup_fields[3][0..app.view.setup_lengths[3]]);
    try std.testing.expectEqual(@as(usize, 0), app.view.setup_lengths[0]);
    try std.testing.expectEqual(@as(usize, 0), app.view.setup_lengths[2]);
    try std.testing.expect(app.view.notice != null);
    try std.testing.expect(conversation.catalog_refresh_pending);
    try std.testing.expectEqual(@as(u16, 0), conversation.launch_selection.?.workspace.len);
    conversation.workspace = try Id.init("registered-id");
    try conversation.restoreSelection(&app.view, null);
    launch.workspace = .{ .value = conversation.workspace.slice() };
    try std.testing.expect(contract.equal(launch, app.view.selected.?.selection()));
    // A connection-only CLI launch asks for a model after discovery.
    launch.model_id = "";
    launch.effort = "";
    try app.configureRuntime(launch, "/runtime");
    app.view.selected = null;
    try conversation.restoreSelection(&app.view, null);
    try std.testing.expect(app.view.selected == null);
}

test "durable and retained choices take precedence over launch and survive catalog default changes" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var root = [_]u8{'/'};
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = &root };
    conversation.workspace = try Id.init(usability_selection.workspace.value);
    var launch = usability_selection;
    launch.model_id = "launch-model";
    conversation.launch_selection = try Coding.Identity.from(launch);
    try conversation.restoreSelection(&view, usability_selection);
    try std.testing.expect(contract.equal(usability_selection, view.selected.?.selection()));
    try view.selectThread(try Id.init("first"));
    view.selected.?.effort = try Id.init("medium");
    try view.selectThread(try Id.init("second"));
    try conversation.restoreSelection(&view, null);
    try std.testing.expectEqualStrings("launch-model", view.selected.?.model_id.slice());
    try view.selectThread(try Id.init("first"));
    // A refreshed durable row must not overwrite an unsent retained choice.
    try conversation.restoreSelection(&view, usability_selection);
    try std.testing.expectEqualStrings("explicit-model", view.selected.?.model_id.slice());
    try std.testing.expectEqualStrings("medium", view.selected.?.effort.slice());
}

test "rejected selection persistence does not spin or overwrite the exact user choice" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    conversation.thread = try Id.init("thread");
    conversation.workspace = try Id.init(usability_selection.workspace.value);
    app.view.selected = try Coding.Identity.from(usability_selection);
    app.view.models[0] = .{ .identity = app.view.selected.?, .readiness = .unknown, .efforts = @splat(.{}), .effort_count = 2 };
    app.view.models[0].efforts[0] = try Id.init("high");
    app.view.models[0].efforts[1] = try Id.init("medium");
    app.view.model_count = 1;
    try std.testing.expect(conversation.selectionNeedsSave(&app.view));
    conversation.attempted_selection = app.view.selected;
    const id = [_]u8{'a'} ** 32;
    conversation.command = .{ .ticket = .{ .value = 7 }, .kind = .selection, .draft_revision = 0, .id = id };
    try conversation.receipt(&app, .{ .value = 7 }, .{ .command_id = .{ .value = &id }, .outcome = .rejected, .reason = .busy, .commit_sequence = 1 });
    try std.testing.expect(!conversation.selectionNeedsSave(&app.view));
    try std.testing.expect(contract.equal(usability_selection, app.view.selected.?.selection()));
    app.view.selected.?.effort = try Id.init("medium");
    try std.testing.expect(conversation.selectionNeedsSave(&app.view));
    conversation.attempted_selection = app.view.selected;
    conversation.command = .{ .ticket = .{ .value = 8 }, .kind = .selection, .draft_revision = 0, .id = id };
    try conversation.receipt(&app, .{ .value = 8 }, .{ .command_id = .{ .value = &id }, .outcome = .accepted, .commit_sequence = 2 });
    try std.testing.expect(!conversation.selectionNeedsSave(&app.view));
    try std.testing.expectEqualStrings("medium", conversation.durable_selection.?.effort.slice());
}

test "run diagnostics own bounded UTF8 bytes and clear when the latest run recovers" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    var diagnostic: [1030]u8 = @splat('x');
    @memcpy(diagnostic[1023..1026], "€");
    var row: @FieldType(types.Row, "run") = .{ .id = .{ .value = "run" }, .revision = 2, .thread = .{ .value = "thread" }, .session = .{ .value = "session" }, .state = .failed, .requested = usability_selection, .effective = null, .diagnostic = &diagnostic };
    try conversation.recordRun(&view, row);
    try std.testing.expectEqual(@as(usize, 1023), view.notice.?.len);
    diagnostic[0] = 'y';
    try std.testing.expectEqual(@as(u8, 'x'), view.notice.?[0]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(view.notice.?));
    row.state = .completed;
    row.diagnostic = "";
    try conversation.recordRun(&view, row);
    try std.testing.expect(view.notice == null);
    try std.testing.expectEqualStrings("completed", view.status);
}

test "provider diagnostic banner shows the message while copied evidence retains raw detail" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    const raw = "{\"failure\":{\"code\":\"failed\",\"detail\":\"{\\\"message\\\":\\\"Quota exhausted café 世界\\\",\\\"codexErrorInfo\\\":{\\\"quota\\\":true}}\"}}";
    var row: @FieldType(types.Row, "run") = .{ .id = .{ .value = "run" }, .revision = 2, .thread = .{ .value = "thread" }, .session = .{ .value = "session" }, .state = .failed, .requested = usability_selection, .effective = null, .diagnostic = raw };
    try conversation.recordRun(&view, row);
    try std.testing.expectEqualStrings("Quota exhausted café 世界", view.notice.?);
    try std.testing.expectEqualStrings(raw, view.send_diagnostic.provider[0..view.send_diagnostic.provider_len]);
    row.diagnostic = "";
    row.state = .completed;
    try conversation.recordRun(&view, row);
    try std.testing.expect(view.notice == null);
    row.id = .{ .value = "later-run" };
    row.state = .failed;
    try conversation.recordRun(&view, row);
    conversation.recordEffect(&view, .{ .id = .{ .value = "start-effect" }, .revision = 1, .run = row.id, .kind = .start, .state = .failed, .outcome = "{\"message\":\"Provider unavailable\"}" });
    try std.testing.expectEqualStrings("Provider unavailable", view.notice.?);
    try std.testing.expectEqualStrings("{\"message\":\"Provider unavailable\"}", view.send_diagnostic.provider[0..view.send_diagnostic.provider_len]);
}

test "presentation API rejects invalid configuration before changing layout or paint" {
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    app.view.design = .{};
    app.layout.design = .{};
    app.dirty = false;
    var configured: design.Config = .{};
    configured.layout.sidebar_width = 304;
    configured.colors.background = .{ .r = 16, .g = 16, .b = 21 };
    try app.configurePresentation(configured);
    try std.testing.expectEqualDeep(configured, app.view.design);
    try std.testing.expectEqualDeep(configured, app.layout.design);
    try std.testing.expect(app.dirty);
    for ([_]f32{ -1, std.math.nan(f32), std.math.inf(f32) }) |invalid| {
        var rejected = configured;
        rejected.layout.sidebar_width = invalid;
        rejected.colors.background = .{ .r = 255, .g = 255, .b = 255 };
        app.dirty = false;
        try std.testing.expectError(error.InvalidDesign, app.configurePresentation(rejected));
        try std.testing.expectEqualDeep(configured, app.view.design);
        try std.testing.expectEqualDeep(configured, app.layout.design);
        try std.testing.expect(!app.dirty);
    }
}

test "native theme keeps ordinary composition and restores default settings on switch" {
    const app = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app);
    const bridge = try std.testing.allocator.create(LuaBridge);
    defer std.testing.allocator.destroy(bridge);
    bridge.active = true;
    bridge.generation = 1;
    bridge.root = std.mem.zeroes(script.Root);
    bridge.root.count = 1;
    bridge.root.nodes[0].kind = 6;
    bridge.root.design.layout_present = 1;
    bridge.root.design.layout[0] = 304;
    try bridge.install(app);
    try std.testing.expect(app.view.custom_root == null);
    try std.testing.expect(app.view.custom_render == null);
    try std.testing.expectEqual(@as(f32, 304), app.view.design.layout.sidebar_width);
    bridge.active = false;
    try bridge.install(app);
    try std.testing.expectEqualDeep(design.Config{}, app.view.design);
    try std.testing.expectEqualDeep(design.Config{}, app.layout.design);
    bridge.active = true;
    bridge.root.nodes[0].kind = 0;
    try bridge.install(app);
    try std.testing.expect(app.view.custom_root == &bridge.root);
    try std.testing.expect(app.view.custom_render == &bridge.render);
}

test "thread cards own real titles and workspace metadata across refresh" {
    const conversation = try std.testing.allocator.create(Conversation);
    defer std.testing.allocator.destroy(conversation);
    conversation.workspace_root = @constCast("/tmp/actual-project");
    conversation.workspace_branch = try Id.init("feature/sidebar");
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    try Conversation.addEntry(&view.projects, &view.project_count, "project", "Coding project");
    var row: @FieldType(types.Row, "thread") = .{
        .id = .{ .value = "thread" },
        .revision = 1,
        .project = .{ .value = "project" },
        .workspace = .{ .value = "workspace" },
        .session = null,
        .title_preview = " \n Fix\t the café sidebar 🎉\r\n",
        .latest_run_state = .awaiting_approval,
        .project_name = "Actual project",
        .workspace_root = "/tmp/actual-project",
        .workspace_branch = "feature/sidebar",
    };
    try conversation.updateThreadCard(&view, row);
    try std.testing.expectEqual(@as(usize, 1), view.thread_count);
    const card = &view.threads[0];
    try std.testing.expectEqualStrings("Fix the café sidebar 🎉", card.label[0..card.len]);
    try std.testing.expectEqualStrings("Actual project", card.project_name.slice());
    try std.testing.expectEqualStrings("Actual project", view.projects[0].label[0..view.projects[0].len]);
    try std.testing.expectEqualStrings("actual-project", card.workspace_name.slice());
    try std.testing.expectEqualStrings("feature/sidebar", card.branch.slice());
    try std.testing.expectEqual(Coding.RunStatus.approval, card.run_status);
    row.latest_run_state = .completed;
    try conversation.updateThreadCard(&view, row);
    try std.testing.expectEqual(@as(usize, 1), view.thread_count);
    try std.testing.expectEqual(Coding.RunStatus.idle, card.run_status);
    row.title_preview = "\n\t";
    try conversation.updateThreadCard(&view, row);
    try std.testing.expectEqualStrings("New thread", card.label[0..card.len]);
    var title: [160]u8 = undefined;
    const long = [_]u8{'x'} ** 159 ++ "🎉 trailing";
    const bounded = Conversation.cardTitle(&title, long);
    try std.testing.expectEqual(@as(usize, 159), bounded.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded));
    // Presentation clipping does not change the registered execution identity.
    const full_branch = [_]u8{'b'} ** 255 ++ "é";
    try std.testing.expectEqual(@as(u16, 255), (try Conversation.displayId(full_branch)).len);
    try std.testing.expectEqual(@as(usize, 257), full_branch.len);
}

test "ordinary startup seeds independent provider forms and blocks synthetic execution" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    app.conversation = &conversation;
    const defaults: [2]contract.RuntimeSetup = .{
        .{ .runtime_kind = .codex, .executable = "/bin/codex", .account_directory = "/managed/codex", .workspace_root = "/project", .model_provider = "openai" },
        .{ .runtime_kind = .opencode, .executable = "/bin/opencode", .account_directory = "/managed/opencode", .workspace_root = "/project", .model_provider = "opencode" },
    };
    try app.configureStartup(defaults);
    try std.testing.expect(conversation.normal_startup and conversation.startup_probe_pending);
    try std.testing.expect(!conversation.runtime_configured);
    try std.testing.expect(!app.view.can_send and !app.view.navigation_enabled);
    try std.testing.expect(app.view.selected == null);
    // A retained fixture choice cannot bypass ordinary-mode admission.
    var fake = usability_selection;
    fake.runtime_kind = "fake";
    app.view.selected = try Coding.Identity.from(fake);
    try std.testing.expectEqualStrings("Choose a provider in Connection to get started.", conversation.selectionDisabledReason(&app.view).?);
}

test "saved startup owns actual workspace and configuration without selecting a model" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = try std.testing.allocator.dupe(u8, "/application-state") };
    defer std.testing.allocator.free(conversation.workspace_root);
    const configuration: contract.RuntimeSetup = .{ .runtime_kind = .opencode, .executable = "/bin/opencode", .account_directory = "/managed/opencode", .workspace_root = "/actual-project", .model_provider = "fixture" };
    var status: types.RuntimeStatus = .{ .runtime_kind = "opencode", .readiness = .unknown, .reason = "Restored", .login = "", .workspace_root = "/actual-project", .configuration = configuration, .binding = .{ .canonical_root = "/actual-project", .filesystem_identity = "fixture", .repository_identity = "", .checkout_identity = "", .expected_branch = "", .base_revision = "", .non_git = true } };
    try std.testing.expect(try conversation.restoreStartup(&view, status));
    try std.testing.expectEqualStrings("/actual-project", conversation.workspace_root);
    try std.testing.expect(conversation.workspace_root.ptr != status.workspace_root.ptr);
    try std.testing.expectEqualStrings("/managed/opencode", view.setup_fields[1][0..view.setup_lengths[1]]);
    try std.testing.expectEqual(.opencode, view.setup_runtime);
    try std.testing.expect(conversation.catalog_refresh_pending and conversation.runtime_configured);
    try std.testing.expect(view.selected == null);
    status.binding = null;
    status.workspace_root = "/missing-project";
    try std.testing.expect(!try conversation.restoreStartup(&view, status));
    try std.testing.expectEqualStrings("/actual-project", conversation.workspace_root);
    try std.testing.expect(std.mem.indexOf(u8, view.notice.?, "Saved workspace is unavailable") != null);
}

test "sign-in fields retain complete bounded web URL and Unicode device code" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    var conversation: Conversation = undefined;
    conversation.updateLogin(&view, "{\"verificationUri\":\"https://example.invalid/device\",\"userCode\":\"世界-123\"}");
    try std.testing.expectEqualStrings("https://example.invalid/device", view.login_url[0..view.login_url_len]);
    try std.testing.expectEqualStrings("世界-123", view.login_code[0..view.login_code_len]);
    conversation.updateLogin(&view, "{\"authUrl\":\"file:///not-a-signin\",\"userCode\":\"new\"}");
    try std.testing.expectEqual(@as(usize, 0), view.login_url_len);
    try std.testing.expectEqualStrings("new", view.login_code[0..view.login_code_len]);
    conversation.updateLogin(&view, "invalid JSON");
    try std.testing.expectEqual(@as(usize, 0), view.login_url_len);
    try std.testing.expectEqual(@as(usize, 0), view.login_code_len);
}

test "setup actions bind to complete displayed configuration rather than saved account" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    const applied: contract.RuntimeSetup = .{ .runtime_kind = .codex, .executable = "/bin/codex", .account_directory = "/managed/first", .workspace_root = "/project/café", .model_provider = "openai" };
    try std.testing.expect(view.configureSetup(applied));
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    try std.testing.expect(conversation.setupNeedsConfigure(Conversation.setupConfiguration(&view)));
    conversation.runtime_configured = true;
    conversation.configured_setup_key = Conversation.setupKey(applied);
    try std.testing.expect(!conversation.setupNeedsConfigure(Conversation.setupConfiguration(&view)));
    inline for (.{ "executable", "account_directory", "workspace_root", "model_provider" }) |field| {
        var changed = applied;
        @field(changed, field) = "/different/世界";
        try std.testing.expect(view.configureSetup(changed));
        try std.testing.expect(conversation.setupNeedsConfigure(Conversation.setupConfiguration(&view)));
    }
    var changed = applied;
    changed.runtime_kind = .opencode;
    try std.testing.expect(view.configureSetup(changed));
    try std.testing.expect(conversation.setupNeedsConfigure(Conversation.setupConfiguration(&view)));
    try std.testing.expect(view.configureSetup(applied));
    try std.testing.expect(!conversation.setupNeedsConfigure(Conversation.setupConfiguration(&view)));
}

test "rejected configuration withdraws queued sign-in without touching an older account" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    const id: [32]u8 = @splat('c');
    conversation.command = .{ .ticket = .{ .value = 1 }, .kind = .configure, .draft_revision = 0, .id = id };
    conversation.submitted_setup_key = @splat(1);
    conversation.setup_login_after_configure = .{ .runtime_kind = .codex, .mode = .device };
    try conversation.receipt(&app, .{ .value = 1 }, .{ .command_id = .{ .value = &id }, .outcome = .rejected, .commit_sequence = 0 });
    try std.testing.expect(conversation.command == null);
    try std.testing.expect(conversation.setup_login_after_configure == null);
    try std.testing.expect(conversation.submitted_setup_key == null);
    try std.testing.expect(app.view.notice != null);
}

test "unresolved chats explain new-chat recovery and setup busy names the live run" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    for ([_]types.RunState{ .unknown, .interrupted }) |state| {
        conversation.run_state = state;
        try std.testing.expect(std.mem.indexOf(u8, conversation.selectionDisabledReason(&app.view).?, "new chat") != null);
        try std.testing.expect(!conversation.selectionNeedsSave(&app.view));
    }
    const id: [32]u8 = @splat('b');
    conversation.command = .{ .ticket = .{ .value = 1 }, .kind = .refresh_models, .draft_revision = 0, .id = id };
    conversation.catalog_refresh_inflight = true;
    try conversation.receipt(&app, .{ .value = 1 }, .{ .command_id = .{ .value = &id }, .outcome = .rejected, .reason = .busy, .commit_sequence = 0 });
    try std.testing.expect(conversation.command == null and !conversation.catalog_refresh_inflight);
    try std.testing.expect(std.mem.indexOf(u8, app.view.notice.?, "Stop") != null);
}

test "workflow refuses unsupported and stale follow-ups without touching Host or draft" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    try app.view.insert("follow-up €", .paste);
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    conversation.thread = try Id.init("thread");
    conversation.run = try Id.init("run");
    app.view.active_thread = conversation.thread;
    app.view.scopeWorkflow(conversation.run);
    app.view.workflow_active = true;
    app.view.selected = try Coding.Identity.from(contract.fakeSelection(.{ .value = "workspace" }));
    conversation.capability_runtime = try Id.init("fake");
    conversation.followup_capability = .unsupported;
    try std.testing.expectError(error.FollowupCapabilityUnavailable, conversation.workflow(&app, .enqueue));
    conversation.followup_capability = .supported;
    app.view.scopeWorkflow(try Id.init("other-run"));
    try std.testing.expectError(error.StaleWorkflow, conversation.workflow(&app, .enqueue));
    try std.testing.expectEqualStrings("follow-up €", app.view.editor.textBytes());
    try std.testing.expect(conversation.command == null);
}

test "workflow receipts preserve newer draft and rejected attachment ownership" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    conversation.thread = try Id.init("thread");
    conversation.run = try Id.init("run");
    app.view.active_thread = conversation.thread;
    app.view.scopeWorkflow(conversation.run);
    try app.view.insert("queued", .paste);
    const revision = app.view.revision;
    conversation.workflow_pending = .{ .thread = conversation.thread, .run = conversation.run, .len = 6 };
    @memcpy(conversation.workflow_pending.content[0..6], "queued");
    try app.view.insert(" newer", .typing);
    const id = [_]u8{'f'} ** 32;
    conversation.command = .{ .ticket = .{ .value = 1 }, .kind = .followup_enqueue, .draft_revision = revision, .id = id };
    try conversation.receipt(&app, .{ .value = 1 }, .{ .command_id = .{ .value = &id }, .outcome = .accepted, .commit_sequence = 1, .entity_ids = .{ .followup = .{ .value = "effect" } } });
    try std.testing.expectEqualStrings("queued newer", app.view.editor.textBytes());
    try std.testing.expectEqualStrings("queued", app.view.followups[0].content[0..app.view.followups[0].len]);
    _ = try app.view.attachments.add(.{ .metadata = .{ .id = .{ .value = "file" }, .name = "notes", .media_type = "text/plain", .byte_length = 5, .digest = "digest" }, .content = "hello" });
    conversation.command = .{ .ticket = .{ .value = 2 }, .kind = .attachment_add, .draft_revision = revision, .id = id };
    try conversation.receipt(&app, .{ .value = 2 }, .{ .command_id = .{ .value = &id }, .outcome = .rejected, .reason = .capability_unavailable, .commit_sequence = 2 });
    try std.testing.expectEqual(@as(usize, 1), app.view.attachments.count);
    try std.testing.expectEqualStrings("capability_unavailable", app.view.workflow_error);
    try conversation.sendIdentified(&app, .absent, .absent, app.view.editor.textBytes(), usability_selection, app.view.revision, id);
    try std.testing.expect(conversation.command == null);
    try std.testing.expectEqualStrings("queued newer", app.view.editor.textBytes());
}

test "workflow observations borrow stable ledger identities after returning" {
    var view = try Coding.init(std.testing.allocator);
    defer view.deinit();
    view.workflow_open = true;
    const rect = c.SDL_FRect{ .x = 1, .y = 2, .w = 30, .h = 20 };
    try view.workflow_targets.add("attachment.path", "textbox", rect, true);
    try view.workflow_targets.add("followup.enqueue", "button", rect, true);
    var output: [64]automation.Target = undefined;
    observeWorkflowTargets(&view, &output);
    try std.testing.expectEqualStrings("attachment.path", output[0].id);
    try std.testing.expectEqualStrings("followup.enqueue", output[1].id);
    try std.testing.expectEqual(view.workflow_targets.items[0].id[0..].ptr, output[0].id.ptr);
    try std.testing.expectEqual(view.workflow_targets.items[1].role[0..].ptr, output[1].role.ptr);
    view.workflow_open = false;
    observeWorkflowTargets(&view, &output);
    try std.testing.expect(!output[0].enabled);
}

test "workflow file read and follow-up edit block delayed custom sends before Host admission" {
    var app: App = undefined;
    app.view = try Coding.init(std.testing.allocator);
    defer app.view.deinit();
    var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
    try app.view.insert("retained", .paste);
    conversation.attachment_loading = true;
    try conversation.sendIdentified(&app, .absent, .absent, "retained", usability_selection, app.view.revision, @splat('a'));
    try std.testing.expect(conversation.command == null);
    conversation.attachment_loading = false;
    app.view.followup_editing = try Id.init("followup");
    try conversation.sendIdentified(&app, .absent, .absent, "retained", usability_selection, app.view.revision, @splat('a'));
    try std.testing.expect(conversation.command == null);
    try std.testing.expectEqualStrings("retained", app.view.editor.textBytes());
}

test "unknown Send receipt lookup resolves original identity and preserves newer full drafts" {
    for ([_]bool{ false, true }) |newer| {
        for (0..3) |outcome| {
            var app: App = undefined;
            app.view = try Coding.init(std.testing.allocator);
            defer app.view.deinit();
            var conversation: Conversation = .{ .allocator = std.testing.allocator, .io = std.testing.io, .host = undefined, .worker = undefined, .wake = undefined, .workspace_root = undefined };
            const text = "😀" ** 16384;
            try app.view.insert(text, .paste);
            const sent_revision = app.view.revision;
            if (newer) {
                app.view.editor.selectAll();
                try app.view.insert("newer draft €", .paste);
            }
            const id = [_]u8{'a'} ** 32;
            conversation.unknown_send = .{ .ticket = .{ .value = 41 }, .kind = .send, .draft_revision = sent_revision, .id = id };
            app.view.send_diagnostic.begin(&id, text.len, domain.startPreflight(text.len).frame_bytes);
            app.view.send_diagnostic.stage = .outcome_unknown;
            try std.testing.expectError(error.SendReceiptUnknown, conversation.submitIdentified(.send, .absent, .absent, .{ .thread_send = .{ .text = "duplicate", .selection = usability_selection } }, app.view.revision, @splat('b')));
            const receipt: types.Receipt = .{ .command_id = .{ .value = &id }, .outcome = if (outcome == 0) .accepted else .rejected, .reason = if (outcome == 0) null else .prompt_staging_full, .commit_sequence = 12, .entity_ids = if (outcome == 0) .{ .run = .{ .value = "original-run" }, .session = .{ .value = "original-session" } } else .{} };
            const rows = [_]types.Row{.{ .command_receipt = if (outcome == 2) null else receipt }};
            const revision = app.view.revision;
            try conversation.consume(&app, .send_receipt, .{ .snapshot_id = .{ .slot = 0, .generation = 1 }, .snapshot_position = .{}, .items = &rows, .expires_at = 1 });
            try std.testing.expect(conversation.unknown_send == null);
            try std.testing.expect(conversation.command == null);
            try std.testing.expectEqualStrings(if (newer) "newer draft €" else if (outcome == 0) "" else text, app.view.editor.textBytes());
            try std.testing.expectEqual(revision + @as(u64, @intFromBool(!newer and outcome == 0)), app.view.revision);
            if (outcome == 0) try std.testing.expectEqualStrings("original-run", conversation.run.slice());
        }
    }
}
