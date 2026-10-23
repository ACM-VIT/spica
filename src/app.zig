const std = @import("std");
const builtin = @import("builtin");
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
        const driver: [*:0]const u8 = switch (builtin.os.tag) {
            .linux => "opengl",
            .macos => "metal",
            else => @compileError("The native foundation currently supports Linux and macOS"),
        };
        const renderer = c.SDL_CreateRenderer(window, driver) orelse return error.RendererCreation;
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
        for (self.view.rich_tiles[0..self.view.rich_count], 0..) |*tile, index| self.snapshot.transcript[index] = tile.rendered[0..tile.length];
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
                .selection = .{ .model_provider = "fake", .model_id = "fixture", .effort = "none", .account_ref = "fixture", .workspace = .{ .value = pending.workspace.slice() } },
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
    message_count: usize = 0,
    message_index: usize = 0,
    blocks: [8]struct { id: Id, revision: u64, bytes: u64 } = undefined,
    block_count: usize = 0,
    block_index: usize = 0,
    worker_key: ?presentation.Key = null,
    source_pending: bool = false,
    tile_request: ?presentation.PageRequest = null,
    runs_cursor: ?Id = null,
    runs_snapshot: ?types.SnapshotId = null,

    const QueryKind = enum { projects, workspaces, threads, thread, runs, approvals, messages, blocks, content };
    const CommandKind = enum { project, workspace, thread, send, cancel, approval };
    const page: types.Page = .{ .limit = 8, .max_bytes = 16 * 1024 };

    fn create(allocator: std.mem.Allocator, io: std.Io, host: *domain.Host, file: std.Io.File, wake: *Wake, workspace_root: []const u8) !*Conversation {
        const self = try allocator.create(Conversation);
        errdefer allocator.destroy(self);
        const root = try allocator.dupe(u8, workspace_root);
        errdefer allocator.free(root);
        // Bootstrap admission precedes worker/file ownership transfer.
        const ticket = try host.query(.{ .projects = page });
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
            .send => try self.submit(.send, .{ .thread = .{ .value = self.thread.slice() } }, .{ .revision = self.thread_revision }, .{ .thread_send = .{ .text = app.view.editor.textBytes(), .selection = .{ .model_provider = "fake", .model_id = "fixture", .effort = "none", .account_ref = "fixture", .workspace = .{ .value = self.workspace.slice() } } } }, app.view.revision),
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
                        if (header.state == .rich and header.block_count != 0) self.tile_request = .{ .key = key, .first_block = 0 } else try self.nextBlock(app);
                    }
                },
                .tile => |*tile| if (self.worker_key) |key| {
                    if (std.meta.eql(tile.key, key)) {
                        var width: c_int = 0;
                        _ = c.SDL_GetWindowSize(app.window, &width, null);
                        app.view.admitTile(app.text, tile, @min(960, @as(f32, @floatFromInt(width)) - 48)) catch |err| {
                            app.view.notice = @errorName(err);
                        };
                        app.dirty = true;
                        if (tile.next_block) |index| self.tile_request = .{ .key = key, .first_block = index } else try self.nextBlock(app);
                    }
                },
                .failure => |failure| if (self.worker_key) |key| {
                    if (std.meta.eql(failure.key, key)) {
                        if (failure.reason != error.EndOfProjection) app.view.notice = @errorName(failure.reason);
                        try self.nextBlock(app);
                    }
                },
            }
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
        if (self.refresh and self.query == null and self.worker_key == null and self.thread.len != 0) {
            self.refresh = false;
            try self.ask(.thread, .{ .thread = .{ .value = self.thread.slice() } });
        }
        const terminal = if (self.run_state) |state| switch (state) {
            .completed, .cancelled, .failed, .interrupted, .unknown => true,
            else => false,
        } else true;
        app.view.can_send = self.thread.len != 0 and terminal and self.command == null and self.query == null and !self.refresh and self.worker_key == null;
        app.view.can_cancel = self.run.len != 0 and !terminal and self.command == null;
        app.view.can_approve = self.approval_live and self.command == null and !self.refresh;
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
                try self.createWorkspace();
            },
            .workspace => {
                self.workspace = try Id.init(value.entity_ids.workspace.?.value);
                try self.createThread();
            },
            .thread => {
                self.thread = try Id.init(value.entity_ids.thread.?.value);
                self.refresh = true;
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
        }
    }

    fn createWorkspace(self: *Conversation) !void {
        try self.submit(.workspace, .absent, .absent, .{ .workspace_register = .{ .project = .{ .value = self.project.slice() }, .binding = .{ .canonical_root = self.workspace_root, .filesystem_identity = self.workspace_root, .repository_identity = "", .checkout_identity = self.workspace_root, .expected_branch = "", .base_revision = "", .non_git = true } } }, 0);
    }
    fn createThread(self: *Conversation) !void {
        try self.submit(.thread, .absent, .absent, .{ .thread_create = .{ .project = .{ .value = self.project.slice() }, .workspace = .{ .value = self.workspace.slice() } } }, 0);
    }

    fn consume(self: *Conversation, app: *App, kind: QueryKind, value: types.QueryPage) !void {
        switch (kind) {
            .projects => {
                if (value.items.len == 0) try self.submit(.project, .absent, .absent, .{ .project_create = .{ .display_name = "Native coding workspace" } }, 0) else {
                    self.project = try Id.init(value.items[0].project.id.value);
                    try self.ask(.workspaces, .{ .workspaces = .{ .project = .{ .value = self.project.slice() }, .page = page } });
                }
            },
            .workspaces => {
                if (value.items.len == 0) try self.createWorkspace() else {
                    self.workspace = try Id.init(value.items[0].workspace.id.value);
                    try self.ask(.threads, .{ .threads = .{ .project = .{ .value = self.project.slice() }, .page = page } });
                }
            },
            .threads => {
                if (value.items.len == 0) try self.createThread() else {
                    self.thread = try Id.init(value.items[0].thread.id.value);
                    self.refresh = true;
                }
            },
            .thread => {
                if (value.items.len != 1) return error.MissingThread;
                self.thread_revision = value.items[0].thread.revision;
                self.workspace = try Id.init(value.items[0].thread.workspace.value);
                if (self.subscription == null and self.subscribe_ticket == null) self.subscribe_ticket = try self.host.subscribe(.{ .scope = .{ .thread = .{ .value = self.thread.slice() } }, .after_position = value.snapshot_position, .max_batch_bytes = 16 * 1024 });
                self.runs_cursor = null;
                self.runs_snapshot = null;
                try self.askRuns();
            },
            .runs => {
                for (value.items) |row| {
                    self.run = try Id.init(row.run.id.value);
                    self.run_revision = row.run.revision;
                    self.run_state = row.run.state;
                    app.view.status = @tagName(row.run.state);
                }
                if (self.run_state == null) app.view.status = "Ready — fake/fixture";
                if (value.next_cursor) |cursor| {
                    self.runs_cursor = try Id.init(cursor);
                    self.runs_snapshot = value.snapshot_id;
                    try self.askRuns();
                } else {
                    self.approval_live = false;
                    if (self.run.len != 0) try self.ask(.approvals, .{ .approvals = .{ .run = .{ .value = self.run.slice() }, .page = page } }) else try self.askMessages();
                }
            },
            .approvals => {
                for (value.items) |row| if (row.approval.state == .pending and row.approval.live) {
                    self.approval = try Id.init(row.approval.id.value);
                    self.approval_revision = row.approval.revision;
                    self.approval_digest = try Id.init(row.approval.evidence.action_digest);
                    self.approval_live = true;
                };
                try self.askMessages();
            },
            .messages => {
                self.message_count = value.items.len;
                self.message_index = 0;
                for (value.items, 0..) |row, index| self.messages[value.items.len - 1 - index] = try Id.init(row.message.message_id.value);
                self.generation += 1;
                for (&app.view.rich_tiles) |*tile| tile.deinit();
                app.view.rich_count = 0;
                app.view.rich_next = 0;
                if (self.message_count != 0) try self.askBlocks();
            },
            .blocks => {
                self.block_count = value.items.len;
                self.block_index = 0;
                for (value.items, 0..) |row, index| self.blocks[index] = .{ .id = try Id.init(row.block.block_id.value), .revision = row.block.revision, .bytes = row.block.committed_bytes };
                if (value.next_cursor != null) app.view.notice = "Message block neighborhood exceeds eight-block display budget";
                if (self.block_count != 0) try self.startBlock(app) else try self.nextMessage();
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
        try self.ask(.messages, .{ .messages = .{ .thread = .{ .value = self.thread.slice() }, .direction = .older, .page = page } });
    }
    fn askBlocks(self: *Conversation) !void {
        try self.ask(.blocks, .{ .blocks = .{ .message = .{ .value = self.messages[self.message_index].slice() }, .page = page } });
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
        try self.ask(.content, .{ .content = .{ .block = .{ .value = block.id.slice() }, .start_byte = self.source_len, .end_byte = @min(block.bytes, self.source_len + 16 * 1024), .page = page } });
    }
    fn nextBlock(self: *Conversation, app: *App) anyerror!void {
        self.worker_key = null;
        self.block_index += 1;
        if (self.block_index < self.block_count) try self.startBlock(app) else try self.nextMessage();
    }
    fn nextMessage(self: *Conversation) !void {
        self.message_index += 1;
        if (self.message_index < self.message_count) try self.askBlocks();
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
