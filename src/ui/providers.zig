const std = @import("std");
const c = @import("../native/bindings.zig").c;
const runtime = @import("../core/runtime.zig");
const ProviderUi = runtime.ProviderUi;
const Color = @import("theme.zig").Color;
const Kind = @FieldType(ProviderUi, "kind");

pub const Intent = enum { cancel, close, retry, respond, url };
const Action = union(enum) { select: usize, intent: Intent };
const Target = struct { bounds: c.SDL_FRect, action: Action };
const RowLayout = struct { index: usize, layout: *c.SpicaTextLayout };
const input_limit = runtime.provider_input_limit;

pub const Panel = struct {
    open: bool = false,
    active: bool = false,
    pending: bool = false,
    seen: bool = false,
    attempt: u64 = 0,
    request_id: [128]u8 = undefined,
    request_len: usize = 0,
    request_kind: Kind = .closed,
    selected: usize = 0,
    visible: usize = 1,
    input: [input_limit]u8 = @splat(0),
    input_len: usize = 0,
    input_error: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    failure: ?[]const u8 = null,
    targets: [32]Target = undefined,
    target_count: usize = 0,
    body_scroll: f32 = 0,
    body_limit: f32 = 0,
    viewport_height: f32 = 0,
    list_origin: f32 = 0,
    reveal_selection: bool = true,
    rows_dirty: bool = true,
    row_width: f32 = 0,
    row_offsets: std.ArrayList(f32) = .empty,
    // Retain only a bounded viewport of shaped option text, not the whole list.
    row_layouts: [24]?RowLayout = @splat(null),

    pub fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        self.wipe();
        self.releaseRows();
        self.row_offsets.deinit(allocator);
    }

    fn releaseRows(self: *Panel) void {
        for (&self.row_layouts) |*row| {
            if (row.*) |cached| c.spica_text_layout_release(cached.layout);
            row.* = null;
        }
    }

    pub fn wipe(self: *Panel) void {
        std.crypto.secureZero(u8, &self.input);
        self.input_len = 0;
        self.input_error = null;
        self.last_error = null;
    }

    pub fn begin(self: *Panel) void {
        self.wipe();
        self.attempt = 0;
        self.seen = false;
        self.open = true;
        self.active = false;
        self.pending = true;
        self.failure = null;
        self.rows_dirty = true;
        self.body_scroll = 0;
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
        self.body_scroll = 0;
        self.target_count = 0;
    }

    pub fn observe(self: *Panel, app: anytype, ui: ProviderUi) void {
        if (ui.attempt == 0 or ui.attempt != self.attempt) return;
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
        self.body_scroll = 0;
        self.rows_dirty = true;
        self.reveal_selection = true;
        self.target_count = 0;
        _ = c.SDL_ClearComposition(app.window);
        if (ui.kind == .closed) {
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

    fn scroll(self: *Panel, delta: f32) void {
        const next = std.math.clamp(self.body_scroll - delta, 0, self.body_limit);
        if (next != self.body_scroll) self.target_count = 0;
        self.body_scroll = next;
        self.reveal_selection = false;
    }

    fn button(self: *Panel, app: anytype, intent: Intent, caption: []const u8, bounds: c.SDL_FRect) !void {
        if (self.target_count == self.targets.len) return error.ProviderTargetBudget;
        self.targets[self.target_count] = .{ .action = .{ .intent = intent }, .bounds = bounds };
        self.target_count += 1;
        try app.rectangle(bounds.x, bounds.y, bounds.w, bounds.h, 6, app.palette().raised);
        try app.label(caption, bounds.x + 10, bounds.y + 8, 13, app.palette().text);
    }

    fn layout(app: anytype, bytes: []const u8, width: f32, size: c_uint) !*c.SpicaTextLayout {
        return c.spica_text_layout_create(app.text, bytes.ptr, bytes.len, @max(1, width), size, false) orelse error.ProviderTextLayout;
    }

    fn drawText(app: anytype, shaped: *c.SpicaTextLayout, x: f32, y: f32, color: Color) !void {
        if (!c.spica_text_layout_draw(app.text, shaped, x, y, .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 })) return error.ProviderTextDraw;
    }

    fn measureRows(self: *Panel, app: anytype, ui: ProviderUi, width: f32) !void {
        if (!self.rows_dirty and self.row_width == width and self.row_offsets.items.len == ui.options.len + 1) return;
        self.releaseRows();
        self.rows_dirty = true;
        self.row_offsets.clearRetainingCapacity();
        try self.row_offsets.ensureTotalCapacity(app.allocator, ui.options.len + 1);
        self.row_offsets.appendAssumeCapacity(0);
        var offset: f32 = 0;
        for (ui.options, 0..) |option, index| {
            const shaped = try layout(app, option, width - 20, 13);
            offset += @max(34, c.spica_text_layout_height(shaped) + 16) + 4;
            self.row_offsets.appendAssumeCapacity(offset);
            if (index < self.row_layouts.len) self.row_layouts[index] = .{ .index = index, .layout = shaped } else c.spica_text_layout_release(shaped);
        }
        self.row_width = width;
        self.rows_dirty = false;
    }

    fn rowLayout(self: *Panel, app: anytype, ui: ProviderUi, index: usize, width: f32) !*c.SpicaTextLayout {
        const slot = &self.row_layouts[index % self.row_layouts.len];
        if (slot.*) |cached| {
            if (cached.index == index) return cached.layout;
            c.spica_text_layout_release(cached.layout);
            slot.* = null;
        }
        const shaped = try layout(app, ui.options[index], width - 20, 13);
        slot.* = .{ .index = index, .layout = shaped };
        return shaped;
    }

    pub fn draw(self: *Panel, app: anytype, ui: ProviderUi) !void {
        if (!self.open) return;
        app.button_count = 0;
        self.target_count = 0;
        const colors = app.palette();
        const canvas_w = app.shell.sidebar.width + app.shell.conversation.width;
        const canvas_h = app.shell.header.height + app.shell.conversation.height + app.shell.composer.height;
        const w = @min(@as(f32, 620), @max(@as(f32, 0), canvas_w - 24));
        const inner = @max(1, w - 40);
        const state = self.kind(ui);
        const heading = if (ui.title.len != 0 and !self.pending and self.failure == null) ui.title else "Connect a provider";
        const title_layout = try layout(app, heading, inner - 10, 19);
        defer c.spica_text_layout_release(title_layout);
        const title_h = c.spica_text_layout_height(title_layout);
        const message = self.failure orelse if (self.pending) "Waiting for Pi…" else ui.message;
        const message_layout = if (message.len != 0) try layout(app, message, inner - 10, 14) else null;
        defer if (message_layout) |shaped| c.spica_text_layout_release(shaped);
        const message_h = if (message_layout) |shaped| c.spica_text_layout_height(shaped) else 0;
        const error_layout = if (self.input_error) |error_text| try layout(app, error_text, inner - 10, 12) else null;
        defer if (error_layout) |shaped| c.spica_text_layout_release(shaped);
        const error_h = if (error_layout) |shaped| c.spica_text_layout_height(shaped) + 8 else 0;
        const url_layout = if (ui.url.len != 0 and error_layout != null) try layout(app, ui.url, inner - 10, 12) else null;
        defer if (url_layout) |shaped| c.spica_text_layout_release(shaped);
        const url_h = if (url_layout) |shaped| c.spica_text_layout_height(shaped) + 12 else 0;
        self.list_origin = title_h + 18 + (if (state == .select and message_h > 0) message_h + 12 else @as(f32, 0));
        if (state == .select) try self.measureRows(app, ui, inner - 10);
        const rows_h = if (state == .select) self.row_offsets.items[ui.options.len] else 0;
        const body_h = if (state == .select) self.list_origin + @max(rows_h, 24) else title_h + 18 + message_h + error_h + url_h;
        const desired_body_h = if (state == .select) self.list_origin + @max(self.row_offsets.items[@min(ui.options.len, 10)], 24) else body_h;
        const input_reserve: f32 = if (state == .input) 60 else 0;
        const h = @min(desired_body_h + 90 + input_reserve, @min(@as(f32, 540), @max(@as(f32, 0), canvas_h - 24)));
        const x = (canvas_w - w) / 2;
        const y = (canvas_h - h) / 2;
        const left = x + 20;
        const footer = y + h - 50;
        const body_top = y + 20;
        self.viewport_height = @max(1, h - 90 - input_reserve);
        self.body_limit = @max(0, body_h - self.viewport_height);
        self.body_scroll = std.math.clamp(self.body_scroll, 0, self.body_limit);
        if (state == .select and ui.options.len != 0) {
            self.selected = @min(self.selected, ui.options.len - 1);
            if (self.reveal_selection) {
                const row_top = self.list_origin + self.row_offsets.items[self.selected];
                const row_bottom = self.list_origin + self.row_offsets.items[self.selected + 1] - 4;
                if (row_top < self.body_scroll or row_bottom - row_top > self.viewport_height) self.body_scroll = row_top;
                if (row_bottom > self.body_scroll + self.viewport_height and row_bottom - row_top <= self.viewport_height)
                    self.body_scroll = row_bottom - self.viewport_height;
                self.body_scroll = std.math.clamp(self.body_scroll, 0, self.body_limit);
            }
        }
        self.reveal_selection = false;
        if (self.input_error != null and self.last_error == null) self.body_scroll = self.body_limit;
        self.last_error = self.input_error;
        try app.rectangle(0, 0, canvas_w, canvas_h, 0, colors.canvas);
        try app.rectangle(x, y, w, h, 10, colors.border);
        try app.rectangle(x + 1, y + 1, w - 2, h - 2, 9, colors.panel);
        const clip = c.SDL_Rect{ .x = @intFromFloat(left), .y = @intFromFloat(body_top), .w = @intFromFloat(inner), .h = @intFromFloat(self.viewport_height) };
        _ = c.SDL_SetRenderClipRect(app.renderer, &clip);
        defer _ = c.SDL_SetRenderClipRect(app.renderer, null);
        const content_top = body_top - self.body_scroll;
        try drawText(app, title_layout, left, content_top, colors.text);
        if (state == .select) {
            if (message_layout) |shaped| try drawText(app, shaped, left, content_top + title_h + 18, colors.text);
            self.visible = 0;
            // Binary search skips off-screen rows even for large provider choice lists.
            var low: usize = 0;
            var high = ui.options.len;
            const start_offset = self.body_scroll - self.list_origin;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (self.row_offsets.items[middle + 1] <= start_offset) low = middle + 1 else high = middle;
            }
            var index = low;
            while (index < ui.options.len and self.visible < self.row_layouts.len) : (index += 1) {
                const row_y = content_top + self.list_origin + self.row_offsets.items[index];
                if (row_y >= body_top + self.viewport_height) break;
                const row_h = self.row_offsets.items[index + 1] - self.row_offsets.items[index] - 4;
                if (index == self.selected) try app.rectangle(left, row_y, inner - 10, row_h, 5, colors.raised);
                const hit_top = @max(body_top, row_y);
                const hit_bottom = @min(body_top + self.viewport_height, row_y + row_h);
                if (hit_bottom > hit_top) {
                    self.targets[self.target_count] = .{ .action = .{ .select = index }, .bounds = .{ .x = left, .y = hit_top, .w = inner - 10, .h = hit_bottom - hit_top } };
                    self.target_count += 1;
                    self.visible += 1;
                }
                try drawText(app, try self.rowLayout(app, ui, index, inner - 10), left + 10, row_y + 8, colors.text);
            }
            self.visible = @max(1, self.visible);
            if (ui.options.len == 0) {
                const empty = try layout(app, "No providers available", inner - 10, 13);
                defer c.spica_text_layout_release(empty);
                try drawText(app, empty, left, content_top + self.list_origin, colors.muted);
            }
        } else {
            const message_color = if (state == .failed) colors.error_color else colors.text;
            var next_y = content_top + title_h + 18;
            if (message_layout) |shaped| try drawText(app, shaped, left, next_y, message_color);
            next_y += message_h;
            if (error_layout) |shaped| {
                try drawText(app, shaped, left, next_y + 8, colors.error_color);
                next_y += error_h;
            }
            if (url_layout) |shaped| try drawText(app, shaped, left, next_y + 12, colors.accent);
        }
        _ = c.SDL_SetRenderClipRect(app.renderer, null);
        if (self.body_limit > 0) {
            const thumb_h = @max(12, self.viewport_height * self.viewport_height / body_h);
            const thumb_y = body_top + (self.viewport_height - thumb_h) * self.body_scroll / self.body_limit;
            try app.rectangle(left + inner - 4, body_top, 3, self.viewport_height, 1, colors.border);
            try app.rectangle(left + inner - 4, thumb_y, 3, thumb_h, 1, colors.muted);
        }
        if (state == .input) {
            // Input and actions stay reachable while instructions and recovery URLs scroll.
            const input_y = footer - 60;
            try app.rectangle(left, input_y, inner, 42, 6, colors.border);
            try app.rectangle(left + 1, input_y + 1, inner - 2, 40, 5, colors.raised);
            const masked: [96]u8 = @splat('*');
            const display = if (self.input_len == 0) ui.placeholder else if (ui.secret) masked[0..@min(masked.len, self.input_len)] else self.input[0..self.input_len];
            const shaped = try layout(app, display, 100000, 14);
            defer c.spica_text_layout_release(shaped);
            const input_clip = c.SDL_Rect{ .x = @intFromFloat(left + 8), .y = @intFromFloat(input_y + 4), .w = @intFromFloat(@max(1, inner - 16)), .h = 34 };
            _ = c.SDL_SetRenderClipRect(app.renderer, &input_clip);
            try drawText(app, shaped, left + 10, input_y + 12, if (self.input_len == 0) colors.muted else colors.text);
            _ = c.SDL_SetRenderClipRect(app.renderer, null);
            const area = c.SDL_Rect{ .x = @intFromFloat(left), .y = @intFromFloat(input_y), .w = @intFromFloat(inner), .h = 42 };
            _ = c.SDL_SetTextInputArea(app.window, &area, 0);
        }
        const finished = state == .done or state == .failed;
        try self.button(app, if (finished) .close else .cancel, if (finished) "Close" else "Cancel", .{ .x = left, .y = footer, .w = 82, .h = 34 });
        if (state == .failed) try self.button(app, .retry, "Retry", .{ .x = x + w - 110, .y = footer, .w = 90, .h = 34 });
        if (state == .input or (state == .select and ui.options.len != 0)) try self.button(app, .respond, if (state == .input) "Continue" else "Connect", .{ .x = x + w - 124, .y = footer, .w = 104, .h = 34 });
        if (ui.url.len != 0 and self.failure == null and !self.pending and !finished) try self.button(app, .url, "Open browser", .{ .x = left + 94, .y = footer, .w = 132, .h = 34 });
    }

    fn insert(self: *Panel, bytes: []const u8) void {
        if (bytes.len > input_limit - self.input_len) {
            self.input_error = "Input is too long (maximum 8192 bytes).";
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
            c.SDL_EVENT_MOUSE_WHEEL => {
                const direction = event.wheel.y * (if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) @as(f32, -1) else 1);
                self.scroll(direction * 38);
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
                    c.SDLK_UP, c.SDLK_DOWN, c.SDLK_PAGEUP, c.SDLK_PAGEDOWN, c.SDLK_HOME, c.SDLK_END => {
                        if (state == .select) {
                            const step: usize = if (event.key.key == c.SDLK_PAGEUP or event.key.key == c.SDLK_PAGEDOWN) self.visible else 1;
                            self.selected = switch (event.key.key) {
                                c.SDLK_HOME => 0,
                                c.SDLK_END => ui.options.len -| 1,
                                c.SDLK_UP, c.SDLK_PAGEUP => self.selected -| step,
                                else => @min(ui.options.len -| 1, self.selected + step),
                            };
                            self.reveal_selection = true;
                            self.target_count = 0;
                        } else {
                            switch (event.key.key) {
                                c.SDLK_HOME => if (command or state != .input) {
                                    self.body_scroll = 0;
                                },
                                c.SDLK_END => if (command or state != .input) {
                                    self.body_scroll = self.body_limit;
                                },
                                c.SDLK_UP => self.scroll(38),
                                c.SDLK_DOWN => self.scroll(-38),
                                c.SDLK_PAGEUP => self.scroll(self.viewport_height),
                                c.SDLK_PAGEDOWN => self.scroll(-self.viewport_height),
                                else => {},
                            }
                        }
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

test "provider scrolling preserves selection and clamps both ends" {
    var panel = Panel{ .selected = 1, .body_limit = 300 };
    panel.scroll(-19);
    panel.scroll(-95);
    try std.testing.expectEqual(@as(f32, 114), panel.body_scroll);
    try std.testing.expectEqual(@as(usize, 1), panel.selected);
    panel.scroll(-1000);
    try std.testing.expectEqual(@as(f32, 300), panel.body_scroll);
    panel.scroll(1000);
    try std.testing.expectEqual(@as(f32, 0), panel.body_scroll);
}

test "provider click selects without submitting and Enter submits" {
    var app = struct { dirty: bool = false, window: *c.SDL_Window = undefined }{};
    var panel = Panel{};
    const ui = ProviderUi{ .kind = .select, .options = &.{ "Anthropic", "OpenAI", "OpenRouter" } };
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
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.key = c.SDLK_RETURN;
    try std.testing.expectEqual(Intent.respond, (try panel.handle(&app, ui, &event)).?);
}

test "authentication input enforces UTF-8 byte boundary without dropping existing input" {
    var panel = Panel{};
    const prefix = [_]u8{'a'} ** (input_limit - 4);
    panel.insert(&prefix);
    panel.insert("😀");
    try std.testing.expectEqual(@as(usize, input_limit), panel.input_len);
    panel.insert("x");
    try std.testing.expect(panel.input_error != null);
    try std.testing.expectEqualStrings("😀", panel.input[input_limit - 4 ..]);
    panel.wipe();
    for (panel.input) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    panel.insert("\xff");
    try std.testing.expectEqual(@as(usize, 0), panel.input_len);
    panel.insert("key\nother");
    try std.testing.expectEqual(@as(usize, 0), panel.input_len);
}

test "obsolete authentication notifications preserve a reopened dialog and its input" {
    var app = struct { window: *c.SDL_Window = undefined, focused_editor: bool = false }{};
    var panel = Panel{ .open = true, .active = true, .attempt = 2, .input_len = 4 };
    @memcpy(panel.input[0..4], "code");
    panel.observe(&app, .{ .kind = .closed, .attempt = 1 });
    panel.observe(&app, .{ .kind = .failed, .attempt = 1 });
    try std.testing.expect(panel.open and panel.active);
    try std.testing.expectEqualStrings("code", panel.input[0..panel.input_len]);
    try std.testing.expect(panel.failure == null);
}
