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
const presentation = @import("content/presentation.zig");
const Id = @import("ui/transcript.zig").Id;
const script = @import("script.zig");

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

    pub fn init(allocator: std.mem.Allocator) !App {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SDLInitialization;
        errdefer c.SDL_Quit();
        const window = c.SDL_CreateWindow("Spica", 1100, 740, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return error.WindowCreation;
        errdefer c.SDL_DestroyWindow(window);
        if (!c.SDL_SetWindowMinimumSize(window, 720, 480)) return error.WindowMinimumSize;
        const renderer = try createRenderer(window);
        errdefer c.SDL_DestroyRenderer(renderer);
        const text = c.spica_text_create(renderer, build_options.font_directory ++ "/Inter.ttf") orelse return error.FontInitialization;
        errdefer c.spica_text_destroy(text);
        // Preserve real faces and the engine's OS fallback path, shaping, bidi,
        // grapheme carets, bounded atlas, and device-pixel rasterization.
        if (!c.spica_text_set_monospace(text, build_options.font_directory ++ "/JetBrainsMono-Regular.ttf")) return error.FontInitialization;
        inline for (.{ "InterVariable-Italic.ttf", "JetBrainsMono-Bold.ttf", "JetBrainsMono-Italic.ttf", "JetBrainsMono-BoldItalic.ttf" }) |font| {
            if (!c.spica_text_add_fallback(text, build_options.font_directory ++ "/" ++ font, 0)) return error.FontInitialization;
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
            if (deadline) |due| {
                const now = c.SDL_GetTicks();
                if (now >= due) {
                    self.snapshot.close_reason = "deadline";
                    break;
                }
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
                    bridge.install(self);
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
        if (self.view.navigation) |navigation| {
            self.view.navigation = null;
            if (self.conversation) |conversation| conversation.navigateWorkspace(self, navigation) catch |err| {
                self.view.notice = @errorName(err);
            };
        }
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
                if (bridge.active and bridge.generation != 0 and intent == .send) {
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
        if (self.lua) |bridge| {
            self.snapshot.custom_root = self.view.custom_root != null;
            self.snapshot.script_generation = bridge.generation;
            self.snapshot.script_error = if (bridge.error_text[0] != 0) std.mem.sliceTo(&bridge.error_text, 0) else null;
            self.snapshot.custom_render = if (self.view.custom_render) |render| render.bytes[0..render.len] else "";
            self.snapshot.pending_script_action = bridge.pending != null;
        }
        self.snapshot.caret = self.view.editor.caret;
        self.snapshot.anchor = self.view.editor.anchor;
        self.snapshot.editor_focused = self.view.focused;
        self.snapshot.preedit_bytes = self.view.preedit_len;
        self.snapshot.draft_revision = self.view.revision;
        const editor_bounds = self.view.editor_view.bounds;
        self.snapshot.targets[1].pointer_bounds = .{ @intFromFloat(editor_bounds.x), @intFromFloat(editor_bounds.y), @intFromFloat(editor_bounds.w), @intFromFloat(editor_bounds.h) };
        self.snapshot.connected = self.view.connected;
        self.snapshot.run_status = self.view.status;
        self.snapshot.visible_rich_blocks = self.view.rich_count;
        for (self.view.controls, 0..) |bounds, index| {
            self.snapshot.targets[index + 2].pointer_bounds = .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) };
            self.snapshot.targets[index + 2].enabled = switch (index) {
                0 => self.view.can_send,
                1 => self.view.can_cancel,
                else => self.view.can_approve,
            };
        }
        const extra_bounds = [_]c.SDL_FRect{ .{ .x = 16, .y = 68, .w = 184, .h = 30 }, .{ .x = 16, .y = 104, .w = 184, .h = 30 }, self.view.picker_bounds, self.view.effort_bounds, self.view.setup_bounds };
        for (extra_bounds, 6..) |bounds, index| {
            self.snapshot.targets[index].pointer_bounds = .{ @intFromFloat(bounds.x), @intFromFloat(bounds.y), @intFromFloat(bounds.w), @intFromFloat(bounds.h) };
            self.snapshot.targets[index].enabled = self.view.custom_root == null and (index >= 8 or self.view.navigation_enabled);
        }
        self.snapshot.thread_targets = @splat(.{ .enabled = false });
        for (self.view.threads[0..self.view.thread_count], 0..) |*entry, index| {
            self.snapshot.thread_targets[index] = .{ .id = entry.id.slice(), .role = "thread", .enabled = self.view.navigation_enabled, .pointer_bounds = .{ 24, @as(i32, @intCast(168 + self.view.project_count * 26 + index * 28)), 176, 28 } };
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
            self.snapshot.run_id = conversation.run.slice();
            self.snapshot.approval_id = if (conversation.approval_live) conversation.approval.slice() else "";
            self.snapshot.pending_command = conversation.command != null;
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
            try std.json.Stringify.value(self.snapshot, .{}, &writer);
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

    fn install(self: *LuaBridge, app: *App) void {
        app.view.custom_root = if (self.active and self.generation != 0) &self.root else null;
        app.view.custom_render = if (self.active and self.generation != 0) &self.render else null;
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
            1 => try conversation.submitIdentified(.send, .{ .thread = .{ .value = context.thread_id.bytes[0..context.thread_id.len] } }, .{ .revision = pending.thread_revision }, .{ .thread_send = .{
                .text = result.intent.text.bytes[0..result.intent.text.len],
                .selection = if (pending.selection) |*selection| selection.selection() else return error.ChooseModel,
            } }, pending.draft_revision, pending.command_id),
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
                    self.install(app);
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
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *domain.Host,
    worker: *presentation.Worker,
    wake: *Wake,
    workspace_root: []u8,
    drain_storage: [1024 * 1024]u8 = undefined,
    source: [presentation.source_limit]u8 = undefined,
    source_len: usize = 0,
    completion: presentation.Completion = undefined,
    project: Id = .{},
    workspace: Id = .{},
    thread: Id = .{},
    thread_revision: u64 = 0,
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
    command: ?struct { ticket: types.Ticket, kind: CommandKind, draft_revision: u64, id: [32]u8 } = null,
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
    configuration_pending: bool = false,

    fn setup(self: *Conversation, app: *App, action: @typeInfo(@FieldType(Coding, "setup_action")).optional.child) !void {
        if (self.command != null or self.query != null) return error.WorkspaceBusy;
        switch (action) {
            .status => try self.ask(.runtime_status, .{ .runtime_status = {} }),
            .refresh => try self.submit(.refresh_models, .absent, .absent, .{ .runtime_refresh = {} }, 0),
            .browser, .device => try self.submit(.login, .absent, .absent, .{ .runtime_login = .{ .runtime_kind = if (app.view.setup_runtime == .codex) .codex else .opencode, .mode = if (action == .browser) .browser else .device } }, 0),
            .configure => try self.submit(.configure, .absent, .absent, .{ .runtime_configure = .{
                .runtime_kind = if (app.view.setup_runtime == .codex) .codex else .opencode,
                .executable = app.view.setup_fields[0][0..app.view.setup_lengths[0]],
                .account_directory = app.view.setup_fields[1][0..app.view.setup_lengths[1]],
                .workspace_root = app.view.setup_fields[2][0..app.view.setup_lengths[2]],
                .model_provider = app.view.setup_fields[3][0..app.view.setup_lengths[3]],
            } }, 0),
        }
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
            .new_project => try self.submit(.project, .absent, .absent, .{ .project_create = .{ .display_name = "Coding project" } }, 0),
            .new_thread => try self.createThread(),
            .project => |index| {
                if (index >= app.view.project_count) return;
                self.project = app.view.projects[index].id;
                self.thread = .{};
                app.view.thread_count = 0;
                try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = page } });
            },
            .thread => |index| {
                if (index >= app.view.thread_count) return;
                try self.selectThread(app, app.view.threads[index].id);
            },
        }
    }

    fn selectThread(self: *Conversation, app: *App, id: Id) !void {
        try app.view.selectThread(id);
        self.thread = id;
        self.run = .{};
        self.run_state = null;
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
        for (entries[0..count.*]) |entry| if (entry.id.eql(id)) return;
        if (count.* == entries.len) return;
        const entry = &entries[count.*];
        entry.id = try Id.init(id);
        entry.len = @min(label.len, entry.label.len);
        @memcpy(entry.label[0..entry.len], label[0..entry.len]);
        count.* += 1;
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

    const QueryKind = enum { projects, workspaces, threads, thread, models, runtime_status, runs, approvals, tasks, messages, blocks, content };
    const CommandKind = enum { project, workspace, thread, send, cancel, approval, configure, login, refresh_models };
    const page: types.Page = .{ .limit = 8, .max_bytes = 16 * 1024 };

    fn create(allocator: std.mem.Allocator, io: std.Io, host: *domain.Host, file: std.Io.File, wake: *Wake, workspace_root: []const u8) !*Conversation {
        const self = try allocator.create(Conversation);
        errdefer allocator.destroy(self);
        const root = try allocator.dupe(u8, workspace_root);
        errdefer allocator.free(root);
        // Bootstrap admission precedes worker/file ownership transfer.
        const ticket = try host.query(.{ .projects = .{ .limit = 16, .max_bytes = 16 * 1024 } });
        const worker = try presentation.Worker.create(allocator, io, file, .{ .context = wake, .notify = Wake.presentationNotify });
        self.* = .{ .allocator = allocator, .io = io, .host = host, .worker = worker, .wake = wake, .workspace_root = root, .query = .{ .ticket = ticket, .kind = .projects } };
        return self;
    }

    fn destroy(self: *Conversation) void {
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
        const ticket = try self.host.submit(.{ .command_id = .{ .value = &id }, .target = target, .expected_revision = revision, .payload = payload });
        self.command = .{ .ticket = ticket, .kind = kind, .draft_revision = draft_revision, .id = id };
    }

    fn act(self: *Conversation, app: *App, intent: @import("ui/coding.zig").Intent) !void {
        switch (intent) {
            .send => {
                const selected = if (app.view.selected) |*identity| identity.selection() else return error.ChooseModel;
                try self.submit(.send, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, .{ .thread_send = .{ .text = app.view.editor.textBytes(), .selection = selected } }, app.view.revision);
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
                        self.command = null;
                    };
                    app.view.notice = @tagName(value.failure.reason);
                    if (value.failure.refresh_required) self.refresh = true;
                },
            }
        }
        if (drained.more_pending) Wake.notify(self.wake);
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
                        app.view.admitTile(app.text, tile, @min(960, @as(f32, @floatFromInt(width)) - 248), .{
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
        if (self.refresh and self.query == null and (self.worker_key == null or self.history_paused) and self.thread.len != 0) {
            self.refresh = false;
            if (app.view.follow_latest) {
                self.history_paused = false;
                self.worker_key = null;
                self.tile_request = null;
                self.message_snapshot = null;
                self.message_anchor = null;
                self.message_direction = .older;
            }
            try self.ask(.thread, .{ .thread = .{ .value = self.thread.slice() } });
        }
        const terminal = if (self.run_state) |state| switch (state) {
            .completed, .cancelled, .failed, .interrupted, .unknown => true,
            else => false,
        } else true;
        app.view.can_send = self.thread.len != 0 and app.view.selected != null and terminal and self.command == null and self.query == null and !self.refresh and (self.worker_key == null or self.history_paused);
        app.view.can_cancel = self.run.len != 0 and !terminal and self.command == null;
        app.view.tasks_enabled = self.command == null and !self.refresh;
        app.view.can_approve = self.approval_live and self.command == null and !self.refresh;
        app.view.navigation_enabled = self.command == null and self.query == null and !self.refresh and !self.source_pending and (self.worker_key == null or self.history_paused);
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
        if (value.outcome == .rejected) {
            app.view.notice = if (value.reason) |reason| @tagName(reason) else "Command rejected";
            self.refresh = self.thread.len != 0;
            return;
        }
        switch (pending.kind) {
            .project => {
                self.project = try Id.init(value.entity_ids.project.?.value);
                try addEntry(&app.view.projects, &app.view.project_count, self.project.slice(), "Coding project");
                try self.createWorkspace();
            },
            .workspace => {
                self.workspace = try Id.init(value.entity_ids.workspace.?.value);
                try self.createThread();
            },
            .thread => {
                try self.selectThread(app, try Id.init(value.entity_ids.thread.?.value));
                app.view.thread_count = 0;
                try self.ask(.threads, .{ .threads = .{ .project = .{ .value = self.project.slice() }, .page = page } });
            },
            .send => {
                if (app.view.revision == pending.draft_revision) {
                    try app.view.editor.setText("");
                    app.view.revision += 1;
                    app.view.editor_view.changed = true;
                }
                self.run = try Id.init(value.entity_ids.run.?.value);
                self.refresh = true;
            },
            .cancel, .approval => {
                self.approval_live = false;
                self.refresh = true;
            },
            .configure => {
                self.configuration_pending = true;
                try self.ask(.runtime_status, .{ .runtime_status = {} });
            },
            .login, .refresh_models => try self.ask(.runtime_status, .{ .runtime_status = {} }),
        }
    }

    fn createWorkspace(self: *Conversation) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const binding = try domain.workspace_binding.capture(arena.allocator(), self.io, self.workspace_root);
        try self.submit(.workspace, .absent, .absent, .{ .workspace_register = .{ .project = .{ .value = self.project.slice() }, .binding = binding } }, 0);
    }
    fn createThread(self: *Conversation) !void {
        try self.submit(.thread, .absent, .absent, .{ .thread_create = .{ .project = .{ .value = self.project.slice() }, .workspace = .{ .value = self.workspace.slice() } } }, 0);
    }

    fn consume(self: *Conversation, app: *App, kind: QueryKind, value: types.QueryPage) !void {
        switch (kind) {
            .runtime_status => {
                app.view.runtime_info_len = 0;
                for (value.items) |row| {
                    const status = row.runtime_status;
                    const remaining = app.view.runtime_info[app.view.runtime_info_len..];
                    const written = std.fmt.bufPrint(remaining, "{s}: {s} {s}\n{s}\n", .{ status.runtime_kind, @tagName(status.readiness), status.reason, status.login }) catch continue;
                    app.view.runtime_info_len += written.len;
                    if (self.configuration_pending and status.workspace_root.len != 0 and status.binding != null) {
                        self.configuration_pending = false;
                        const root = try self.allocator.dupe(u8, status.workspace_root);
                        self.allocator.free(self.workspace_root);
                        self.workspace_root = root;
                        app.view.selected = null;
                        try self.submit(.workspace, .absent, .absent, .{ .workspace_register = .{ .project = .{ .value = self.project.slice() }, .binding = status.binding.? } }, 0);
                        return;
                    }
                }
                if (self.workspace.len != 0) {
                    app.view.model_count = 0;
                    try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024 } } });
                }
            },
            .models => {
                for (value.items) |row| {
                    if (app.view.model_count == app.view.models.len) break;
                    const model = row.model;
                    const target = &app.view.models[app.view.model_count];
                    target.* = .{ .identity = try Coding.Identity.from(model.selection), .readiness = model.readiness, .synthetic = model.synthetic };
                    target.reason_len = @min(target.reason.len, model.reason.len);
                    @memcpy(target.reason[0..target.reason_len], model.reason[0..target.reason_len]);
                    for (model.supported_efforts) |effort| {
                        if (target.effort_count == target.efforts.len) break;
                        target.efforts[target.effort_count] = if (effort.len == 0) .{} else try Id.init(effort);
                        target.effort_count += 1;
                    }
                    if (app.view.selected == null) app.view.selected = target.identity;
                    app.view.model_count += 1;
                }
                if (value.next_cursor != null and app.view.model_count < app.view.models.len) {
                    try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024, .snapshot = value.snapshot_id, .cursor = value.next_cursor } } });
                } else try self.askRuns();
            },
            .projects => {
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
                    self.workspace = try Id.init(row.workspace.id.value);
                    selected = true;
                    break;
                }
                if (selected) {
                    try self.ask(.threads, .{ .threads = .{ .project = .{ .value = self.project.slice() }, .page = page } });
                } else if (value.next_cursor) |cursor| {
                    try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = .{ .limit = page.limit, .max_bytes = page.max_bytes, .snapshot = value.snapshot_id, .cursor = cursor } } });
                } else try self.createWorkspace();
            },
            .threads => {
                var selected = false;
                for (value.items) |row| {
                    if (!std.mem.eql(u8, row.thread.workspace.value, self.workspace.slice())) continue;
                    try addEntry(&app.view.threads, &app.view.thread_count, row.thread.id.value, row.thread.id.value);
                    if (self.thread.len == 0) self.thread = try Id.init(row.thread.id.value);
                    selected = true;
                }
                if (value.next_cursor != null and app.view.thread_count < app.view.threads.len) {
                    try self.ask(.threads, .{ .threads = .{ .project = .{ .value = self.project.slice() }, .page = .{ .limit = page.limit, .max_bytes = page.max_bytes, .snapshot = value.snapshot_id, .cursor = value.next_cursor } } });
                } else if (selected or self.thread.len != 0) {
                    try self.selectThread(app, self.thread);
                } else try self.createThread();
            },
            .thread => {
                if (value.items.len != 1) return error.MissingThread;
                self.thread_revision = value.items[0].thread.revision;
                self.workspace = try Id.init(value.items[0].thread.workspace.value);
                if (app.view.selected == null) if (value.items[0].thread.selection) |selection| {
                    app.view.selected = try Coding.Identity.from(selection);
                };
                const label = try std.fmt.bufPrint(&app.view.workspace_label, "{s}  •  {s}", .{ @import("text/utf8.zig").prefix(self.workspace_root, 384), self.thread.slice() });
                app.view.workspace_label_len = label.len;
                if (self.subscription == null and self.subscribe_ticket == null) self.subscribe_ticket = try self.host.subscribe(.{ .scope = .all, .after_position = value.snapshot_position, .max_batch_bytes = 16 * 1024 });
                self.runs_cursor = null;
                self.runs_snapshot = null;
                app.view.model_count = 0;
                try self.ask(.models, .{ .models = .{ .workspace = .{ .value = self.workspace.slice() }, .page = .{ .limit = 32, .max_bytes = 64 * 1024 } } });
            },
            .runs => {
                for (value.items) |row| {
                    self.run = try Id.init(row.run.id.value);
                    self.run_revision = row.run.revision;
                    self.run_state = row.run.state;
                    app.view.status = @tagName(row.run.state);
                }
                if (self.run_state == null) app.view.status = "Ready";
                if (value.next_cursor) |cursor| {
                    self.runs_cursor = try Id.init(cursor);
                    self.runs_snapshot = value.snapshot_id;
                    try self.askRuns();
                } else {
                    self.approval_live = false;
                    if (self.run.len != 0) try self.ask(.approvals, .{ .approvals = .{ .run = .{ .value = self.run.slice() }, .page = page } }) else try self.askHistory(app);
                }
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
