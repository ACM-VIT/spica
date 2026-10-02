const std = @import("std");
const c = @import("../native/bindings.zig").c;
const ProviderUi = @import("../core/runtime.zig").ProviderUi;
const Color = @import("theme.zig").Color;
const Kind = @TypeOf(@as(ProviderUi, .{ .kind = .closed }).kind);

pub const Intent = enum { cancel, close, retry, respond, url };
const Action = union(enum) { select: usize, intent: Intent };
const Target = struct { bounds: c.SDL_FRect, action: Action };
const input_limit = 4096;

pub const Panel = struct {
    open: bool = false,
    active: bool = false,
    pending: bool = false,
    seen: bool = false,
    request_id: [128]u8 = undefined,
    request_len: usize = 0,
    request_kind: Kind = .closed,
    selected: usize = 0,
    first: usize = 0,
    visible: usize = 1,
    wheel_remainder: f32 = 0,
    input: [input_limit]u8 = @splat(0),
    input_len: usize = 0,
    input_error: ?[]const u8 = null,
    failure: ?[]const u8 = null,
    targets: [32]Target = undefined,
    target_count: usize = 0,

    pub fn wipe(self: *Panel) void {
        std.crypto.secureZero(u8, &self.input);
        self.input_len = 0;
        self.input_error = null;
    }

    pub fn begin(self: *Panel) void {
        self.wipe();
        self.open = true;
        self.active = false;
        self.pending = true;
        self.failure = null;
        self.target_count = 0;
    }

    pub fn close(self: *Panel) void {
        self.wipe();
        self.open = false;
        self.active = false;
        self.pending = false;
        self.target_count = 0;
    }

    pub fn fail(self: *Panel, message: []const u8) void {
        self.wipe();
        self.open = true;
        self.pending = false;
        self.failure = message;
        self.target_count = 0;
    }

    pub fn observe(self: *Panel, app: anytype, ui: ProviderUi) void {
        const bounded = ui.id.len <= self.request_id.len;
        if (bounded and self.seen and self.request_kind == ui.kind and
            self.request_len == ui.id.len and std.mem.eql(u8, self.request_id[0..self.request_len], ui.id)) return;
        self.seen = bounded;
        if (bounded) {
            @memcpy(self.request_id[0..ui.id.len], ui.id);
            self.request_len = ui.id.len;
        }
        self.request_kind = ui.kind;
        if (!self.open) return;
        self.wipe();
        self.pending = false;
        self.failure = null;
        self.selected = 0;
        self.first = 0;
        self.wheel_remainder = 0;
        self.target_count = 0;
        _ = c.SDL_ClearComposition(app.window);
        if (ui.kind == .closed) {
            self.active = false;
            self.close();
            app.focused_editor = true;
            _ = c.SDL_StartTextInput(app.window);
        } else if (ui.kind == .input) {
            _ = c.SDL_StartTextInput(app.window);
        } else {
            if (ui.kind == .done or ui.kind == .failed) self.active = false;
            _ = c.SDL_StopTextInput(app.window);
        }
    }

    fn kind(self: *const Panel, ui: ProviderUi) Kind {
        return if (self.failure != null) .failed else if (self.pending) .waiting else ui.kind;
    }

    fn ensureVisible(self: *Panel, count: usize) void {
        self.selected = @min(self.selected, count -| 1);
        self.first = @min(self.first, count -| self.visible);
        if (self.selected < self.first) self.first = self.selected;
        if (self.selected >= self.first + self.visible) self.first = self.selected + 1 -| self.visible;
    }

    fn scroll(self: *Panel, count: usize, delta: f32) void {
        self.wheel_remainder += delta;
        const rows = @trunc(std.math.clamp(self.wheel_remainder, -@as(f32, @floatFromInt(count)), @as(f32, @floatFromInt(count))));
        self.wheel_remainder -= rows;
        const step: usize = @intFromFloat(@abs(rows));
        const previous = self.first;
        self.first = if (rows > 0) self.first -| step else @min(count -| self.visible, self.first +| step);
        if (self.first != previous) self.target_count = 0;
        if ((rows > 0 and self.first == 0) or (rows < 0 and self.first == count -| self.visible)) self.wheel_remainder = 0;
    }

    fn button(self: *Panel, app: anytype, intent: Intent, caption: []const u8, bounds: c.SDL_FRect) !void {
        if (self.target_count == self.targets.len) return error.ProviderTargetBudget;
        self.targets[self.target_count] = .{ .action = .{ .intent = intent }, .bounds = bounds };
        self.target_count += 1;
        try app.rectangle(bounds.x, bounds.y, bounds.w, bounds.h, 6, app.palette().raised);
        try app.label(caption, bounds.x + 10, bounds.y + 8, 13, app.palette().text);
    }

    // All variable provider text bypasses the application's retained label cache.
    fn text(app: anytype, bytes: []const u8, x: f32, y: f32, width: f32, size: c_uint, color: Color) !f32 {
        if (bytes.len == 0) return 0;
        const layout = c.spica_text_layout_create(app.text, bytes.ptr, bytes.len, @max(1, width), size, false) orelse return error.ProviderTextLayout;
        defer c.spica_text_layout_release(layout);
        if (!c.spica_text_layout_draw(app.text, layout, x, y, .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 })) return error.ProviderTextDraw;
        return c.spica_text_layout_height(layout);
    }

    pub fn draw(self: *Panel, app: anytype, ui: ProviderUi) !void {
        if (!self.open) return;
        app.button_count = 0;
        self.target_count = 0;
        const colors = app.palette();
        const canvas_w = app.shell.sidebar.width + app.shell.conversation.width;
        const canvas_h = app.shell.header.height + app.shell.conversation.height + app.shell.composer.height;
        const w = @min(@as(f32, 620), @max(@as(f32, 0), canvas_w - 24));
        const h = @min(@as(f32, 540), @max(@as(f32, 0), canvas_h - 24));
        const x = (canvas_w - w) / 2;
        const y = (canvas_h - h) / 2;
        const left = x + 20;
        const inner = @max(1, w - 40);
        const footer = y + h - 50;
        const state = self.kind(ui);
        try app.rectangle(0, 0, canvas_w, canvas_h, 0, colors.canvas);
        try app.rectangle(x, y, w, h, 10, colors.border);
        try app.rectangle(x + 1, y + 1, w - 2, h - 2, 9, colors.panel);
        _ = try text(app, if (ui.title.len != 0 and !self.pending and self.failure == null) ui.title else "Connect a provider", left, y + 18, inner, 19, colors.text);
        const body_top = y + 60;
        const clip = c.SDL_Rect{ .x = @intFromFloat(left), .y = @intFromFloat(body_top), .w = @intFromFloat(inner), .h = @intFromFloat(@max(1, footer - body_top - 10)) };
        _ = c.SDL_SetRenderClipRect(app.renderer, &clip);
        defer _ = c.SDL_SetRenderClipRect(app.renderer, null);
        if (state == .select) {
            self.visible = @min(@as(usize, 24), @max(@as(usize, 1), @as(usize, @intFromFloat(@max(0, footer - body_top - 34) / 38))));
            self.selected = @min(self.selected, ui.options.len -| 1);
            self.first = @min(self.first, ui.options.len -| self.visible);
            _ = try text(app, "Wheel scrolls · click to select · Enter connects", left, body_top, inner, 13, colors.muted);
            const end = @min(ui.options.len, self.first + self.visible);
            for (ui.options[self.first..end], self.first..) |option, index| {
                const row_y = body_top + 30 + @as(f32, @floatFromInt(index - self.first)) * 38;
                const bounds = c.SDL_FRect{ .x = left, .y = row_y, .w = inner, .h = 34 };
                if (index == self.selected) try app.rectangle(left, row_y, inner, 34, 5, colors.raised);
                self.targets[self.target_count] = .{ .action = .{ .select = index }, .bounds = bounds };
                self.target_count += 1;
                _ = try text(app, option, left + 10, row_y + 8, inner - 20, 13, colors.text);
            }
            if (ui.options.len == 0) _ = try text(app, "No providers are available.", left, body_top + 38, inner, 13, colors.muted);
        } else {
            const message = self.failure orelse if (self.pending) "Waiting for Pi…" else ui.message;
            const message_h = try text(app, message, left, body_top, inner, 14, if (state == .failed) colors.error_color else colors.text);
            if (state == .input) {
                const input_y = @min(footer - 92, body_top + message_h + 18);
                try app.rectangle(left, input_y, inner, 42, 6, colors.border);
                try app.rectangle(left + 1, input_y + 1, inner - 2, 40, 5, colors.raised);
                const masked: [96]u8 = @splat('*');
                const display = if (self.input_len == 0) (if (ui.placeholder.len != 0) ui.placeholder else "Enter a value") else if (ui.secret) masked[0..@min(masked.len, self.input_len)] else self.input[0..self.input_len];
                const input_clip = c.SDL_Rect{ .x = @intFromFloat(left + 8), .y = @intFromFloat(input_y + 4), .w = @intFromFloat(@max(1, inner - 16)), .h = 34 };
                _ = c.SDL_SetRenderClipRect(app.renderer, &input_clip);
                _ = try text(app, display, left + 10, input_y + 12, 100000, 14, if (self.input_len == 0) colors.muted else colors.text);
                _ = c.SDL_SetRenderClipRect(app.renderer, &clip);
                if (self.input_error) |message_text| _ = try text(app, message_text, left, input_y + 48, inner, 12, colors.error_color);
                const area = c.SDL_Rect{ .x = @intFromFloat(left), .y = @intFromFloat(input_y), .w = @intFromFloat(inner), .h = 42 };
                _ = c.SDL_SetTextInputArea(app.window, &area, 0);
            } else if (ui.url.len != 0 and self.failure == null and !self.pending) {
                _ = try text(app, ui.url, left, body_top + message_h + 18, inner, 12, colors.accent);
            }
            if (state != .input) if (self.input_error) |message_text| {
                _ = try text(app, message_text, left, footer - 30, inner, 12, colors.error_color);
            };
        }
        _ = c.SDL_SetRenderClipRect(app.renderer, null);
        const finished = state == .done or state == .failed;
        try self.button(app, if (finished) .close else .cancel, if (finished) "Close" else "Cancel", .{ .x = left, .y = footer, .w = 82, .h = 34 });
        if (state == .failed) try self.button(app, .retry, "Retry", .{ .x = x + w - 110, .y = footer, .w = 90, .h = 34 });
        if (state == .input or (state == .select and ui.options.len != 0)) try self.button(app, .respond, if (state == .input) "Continue" else "Connect", .{ .x = x + w - 124, .y = footer, .w = 104, .h = 34 });
        if (ui.url.len != 0 and self.failure == null and !self.pending and !finished) try self.button(app, .url, "Open browser", .{ .x = left + 94, .y = footer, .w = 132, .h = 34 });
    }

    fn insert(self: *Panel, bytes: []const u8) void {
        if (bytes.len > input_limit - self.input_len) {
            self.input_error = "Input is too long (maximum 4096 bytes).";
            return;
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            self.input_error = "Input must be valid UTF-8.";
            return;
        }
        for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) {
            self.input_error = "Enter a single line without control characters.";
            return;
        };
        @memcpy(self.input[self.input_len..][0..bytes.len], bytes);
        self.input_len += bytes.len;
        self.input_error = null;
    }

    pub fn handle(self: *Panel, app: anytype, ui: ProviderUi, event: *const c.SDL_Event) !?Intent {
        app.dirty = true;
        const state = self.kind(ui);
        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button != c.SDL_BUTTON_LEFT) return null;
                for (self.targets[0..self.target_count]) |target| {
                    const b = target.bounds;
                    if (event.button.x >= b.x and event.button.x < b.x + b.w and event.button.y >= b.y and event.button.y < b.y + b.h) {
                        switch (target.action) {
                            .select => |index| {
                                self.selected = index;
                                return null;
                            },
                            .intent => |intent| return intent,
                        }
                    }
                }
            },
            c.SDL_EVENT_MOUSE_WHEEL => if (state == .select) {
                const direction = event.wheel.y * (if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) @as(f32, -1) else 1);
                self.scroll(ui.options.len, direction);
            },
            c.SDL_EVENT_KEY_DOWN => {
                const command = (event.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
                switch (event.key.key) {
                    c.SDLK_ESCAPE => return if (state == .done or state == .failed) .close else .cancel,
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                        if (state == .done) return .close;
                        if (state == .failed) return .retry;
                        if (state == .input or (state == .select and ui.options.len != 0)) return .respond;
                    },
                    c.SDLK_UP, c.SDLK_DOWN, c.SDLK_PAGEUP, c.SDLK_PAGEDOWN, c.SDLK_HOME, c.SDLK_END => if (state == .select) {
                        const step: usize = if (event.key.key == c.SDLK_PAGEUP or event.key.key == c.SDLK_PAGEDOWN) self.visible else 1;
                        self.wheel_remainder = 0;
                        self.selected = switch (event.key.key) {
                            c.SDLK_HOME => 0,
                            c.SDLK_END => ui.options.len -| 1,
                            c.SDLK_UP, c.SDLK_PAGEUP => self.selected -| step,
                            else => @min(ui.options.len -| 1, self.selected + step),
                        };
                        self.ensureVisible(ui.options.len);
                    },
                    c.SDLK_BACKSPACE => if (state == .input and self.input_len != 0) {
                        var end = self.input_len - 1;
                        while (end > 0 and self.input[end] & 0xc0 == 0x80) end -= 1;
                        std.crypto.secureZero(u8, self.input[end..self.input_len]);
                        self.input_len = end;
                        self.input_error = null;
                    },
                    c.SDLK_V => if (state == .input and command) {
                        const clipboard = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                        const bytes = std.mem.span(clipboard);
                        defer {
                            std.crypto.secureZero(u8, bytes);
                            c.SDL_free(clipboard);
                        }
                        self.insert(bytes);
                    },
                    else => {},
                }
            },
            c.SDL_EVENT_TEXT_INPUT => if (state == .input) self.insert(std.mem.span(event.text.text)),
            c.SDL_EVENT_WINDOW_FOCUS_LOST => _ = c.SDL_ClearComposition(app.window),
            else => {},
        }
        return null;
    }
};

test "provider wheel scroll preserves selection and accumulates fractional movement" {
    var panel = Panel{ .selected = 1, .visible = 3 };
    panel.scroll(10, -0.5);
    try std.testing.expectEqual(@as(usize, 0), panel.first);
    panel.scroll(10, -2.5);
    try std.testing.expectEqual(@as(usize, 3), panel.first);
    try std.testing.expectEqual(@as(usize, 1), panel.selected);
    panel.scroll(10, -100);
    try std.testing.expectEqual(@as(usize, 7), panel.first);
    panel.scroll(10, 1);
    try std.testing.expectEqual(@as(usize, 6), panel.first);
    panel.scroll(10, 100);
    try std.testing.expectEqual(@as(usize, 0), panel.first);
    panel.scroll(0, -1);
    try std.testing.expectEqual(@as(usize, 0), panel.first);
}

test "provider click selects without submitting and keyboard navigation reveals selection" {
    var app = struct { dirty: bool = false, window: *c.SDL_Window = undefined }{};
    var panel = Panel{ .visible = 2 };
    const ui = ProviderUi{ .kind = .select, .options = &.{ "Anthropic", "OpenAI", "OpenRouter", "Google" } };
    panel.targets[0] = .{ .bounds = .{ .x = 10, .y = 10, .w = 200, .h = 34 }, .action = .{ .select = 2 } };
    panel.target_count = 1;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_BUTTON_DOWN;
    event.button.button = c.SDL_BUTTON_LEFT;
    event.button.x = 20;
    event.button.y = 20;
    try std.testing.expect(try panel.handle(&app, ui, &event) == null);
    try std.testing.expectEqual(@as(usize, 2), panel.selected);
    event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_MOUSE_WHEEL;
    event.wheel.y = 2;
    event.wheel.direction = c.SDL_MOUSEWHEEL_FLIPPED;
    _ = try panel.handle(&app, ui, &event);
    try std.testing.expectEqual(@as(usize, 2), panel.first);
    try std.testing.expectEqual(@as(usize, 2), panel.selected);
    event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_HOME;
    _ = try panel.handle(&app, ui, &event);
    try std.testing.expectEqual(@as(usize, 0), panel.first);
    try std.testing.expectEqual(@as(usize, 0), panel.selected);
    event.key.key = c.SDLK_END;
    _ = try panel.handle(&app, ui, &event);
    try std.testing.expectEqual(@as(usize, 2), panel.first);
    try std.testing.expectEqual(@as(usize, 3), panel.selected);
    event.key.key = c.SDLK_RETURN;
    try std.testing.expectEqual(Intent.respond, (try panel.handle(&app, ui, &event)).?);
}
