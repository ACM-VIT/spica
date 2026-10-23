const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Composer = @import("../text/composer.zig").Composer;
const EditorView = @import("editor_view.zig").EditorView;
const LabelCache = @import("label_cache.zig").LabelCache;
const widgets = @import("widgets.zig");
const clipboard = @import("clipboard.zig");
const Layout = @import("clay.zig").Layout;
const Color = @import("color.zig").Color;

/// Presentation state only. No adapter, store, execution lifetime or accepted work.
pub const View = struct {
    allocator: std.mem.Allocator,
    editor: Composer,
    editor_view: EditorView = .{},
    labels: LabelCache = .{},
    scratch: []u8,
    focused: bool = true,
    dragging: bool = false,
    preedit: [4096]u8 = undefined,
    preedit_len: usize = 0,
    notice: ?[]const u8 = null,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !View {
        var editor = try Composer.init(allocator);
        errdefer editor.deinit();
        return .{ .allocator = allocator, .editor = editor, .scratch = try allocator.alloc(u8, 64 * 1024 + 1) };
    }

    pub fn deinit(self: *View) void {
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
    }

    pub fn insert(self: *View, bytes: []const u8, kind: @import("../text/composer.zig").GroupKind) !void {
        try self.editor.insert(bytes, kind);
        self.changed();
    }

    fn focus(self: *View, window: *c.SDL_Window, enabled: bool) !void {
        self.focused = enabled;
        self.preedit_len = 0;
        if (enabled) {
            if (!c.SDL_StartTextInput(window)) return error.TextInputStart;
        } else if (!c.SDL_StopTextInput(window)) return error.TextInputStop;
    }

    fn releasePointer(self: *View) void {
        self.dragging = false;
        _ = c.SDL_CaptureMouse(false);
    }

    pub fn handle(self: *View, event: c.SDL_Event, window: *c.SDL_Window, text: *c.SpicaText) !bool {
        switch (event.type) {
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.releasePointer();
                try self.focus(window, false);
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button != c.SDL_BUTTON_LEFT) return false;
                const inside = widgets.contains(self.editor_view.bounds, event.button.x, event.button.y);
                try self.focus(window, inside);
                if (inside) {
                    const extend = c.SDL_GetModState() & c.SDL_KMOD_SHIFT != 0;
                    if (self.editor_view.offsetAt(event.button.x, event.button.y)) |at| self.editor.setCaret(at, extend);
                    self.dragging = true;
                    if (!c.SDL_CaptureMouse(true)) self.notice = "Pointer capture unavailable";
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button != c.SDL_BUTTON_LEFT or !self.dragging) return false;
                self.releasePointer();
                return true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (!self.dragging) return false;
                if (self.editor_view.offsetAt(event.motion.x, event.motion.y)) |at| self.editor.setCaret(at, true);
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if (!widgets.contains(self.editor_view.bounds, event.wheel.mouse_x, event.wheel.mouse_y)) return false;
                const direction: f32 = if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
                self.editor_view.scroll = @max(0, self.editor_view.scroll - event.wheel.y * direction * 44);
                return true;
            },
            c.SDL_EVENT_TEXT_EDITING => {
                if (!self.focused) return false;
                const bytes = std.mem.span(event.edit.text);
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
                if (!self.focused) return false;
                const kind: @import("../text/composer.zig").GroupKind = if (self.preedit_len != 0) .ime else .typing;
                self.preedit_len = 0;
                try self.insert(std.mem.span(event.text.text), kind);
                return true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mods = event.key.mod;
                const ctrl = mods & c.SDL_KMOD_CTRL != 0;
                const shift = mods & c.SDL_KMOD_SHIFT != 0;
                if (key == c.SDLK_TAB) {
                    try self.focus(window, !self.focused);
                    return true;
                }
                if (key == c.SDLK_ESCAPE) {
                    self.preedit_len = 0;
                    self.releasePointer();
                    self.notice = null;
                    return true;
                }
                if (!self.focused or self.preedit_len != 0) return false;
                if (ctrl) switch (key) {
                    c.SDLK_A => self.editor.selectAll(),
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
                    },
                    c.SDLK_UP, c.SDLK_DOWN => try self.editor_view.moveVertical(text, &self.editor, 16, key == c.SDLK_DOWN, shift),
                    c.SDLK_HOME, c.SDLK_END => try self.editor_view.moveLineEdge(text, &self.editor, 16, key == c.SDLK_END, ctrl, shift),
                    c.SDLK_BACKSPACE, c.SDLK_DELETE => {
                        if (ctrl) try self.editor.deleteWord(if (key == c.SDLK_BACKSPACE) .backward else .forward) else if (key == c.SDLK_BACKSPACE) try self.editor.backspace() else try self.editor.deleteForward();
                        self.changed();
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                        if (shift) try self.insert("\n", .typing) else self.notice = "No conversation connected; draft retained";
                    },
                    else => {},
                }
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, window: *c.SDL_Window, bounds: Layout.Coding) !void {
        const foreground = Color{ .r = 231, .g = 235, .b = 242 };
        const muted = Color{ .r = 157, .g = 168, .b = 186 };
        if (!c.SDL_SetRenderDrawColor(renderer, 19, 22, 28, 255) or !c.SDL_RenderClear(renderer)) return error.CanvasDraw;
        try self.labels.draw(text, "SPICA", 24, 18, 18, foreground);
        try self.labels.drawFitted(renderer, text, "Conversation not connected", 110, 22, bounds.header.width - 140, 13, muted);
        try self.labels.draw(text, "Compose a draft below. No provider is running.", bounds.transcript.x, bounds.transcript.y + 20, 16, muted);
        const panel = c.SDL_FRect{ .x = bounds.composer.x, .y = bounds.composer.y, .w = bounds.composer.width, .h = bounds.composer.height };
        try widgets.panel(renderer, panel, 10, if (self.focused) .{ .r = 103, .g = 129, .b = 210 } else .{ .r = 57, .g = 64, .b = 79 });
        try widgets.panel(renderer, .{ .x = panel.x + 1, .y = panel.y + 1, .w = panel.w - 2, .h = panel.h - 2 }, 9, .{ .r = 27, .g = 32, .b = 41 });
        const editor_bounds = c.SDL_FRect{ .x = panel.x, .y = panel.y, .w = panel.w, .h = panel.h - 40 };
        self.editor_view.bounds = editor_bounds;
        try self.editor_view.ensureLayout(text, &self.editor, panel.w, 16);
        var clip = widgets.Clip.push(renderer, .{ .x = panel.x + 10, .y = panel.y + 8, .w = panel.w - 20, .h = editor_bounds.h - 12 });
        if (self.editor_view.layout) |layout| {
            const content_height = c.spica_text_layout_height(layout);
            const available = editor_bounds.h - 20;
            self.editor_view.scroll = std.math.clamp(self.editor_view.scroll, 0, @max(0, content_height - available));
            if (self.editor_view.caret(&self.editor)) |caret_rect| {
                if (self.focused) {
                    if (caret_rect.y < self.editor_view.scroll) self.editor_view.scroll = caret_rect.y;
                    if (caret_rect.y + caret_rect.h > self.editor_view.scroll + available) self.editor_view.scroll = caret_rect.y + caret_rect.h - available;
                }
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
                if (self.focused) {
                    const caret = c.SDL_FRect{ .x = x + caret_rect.x, .y = y + caret_rect.y, .w = 1.5, .h = caret_rect.h };
                    if (!c.SDL_SetRenderDrawColor(renderer, 231, 235, 242, 255) or !c.SDL_RenderFillRect(renderer, &caret)) return error.CaretDraw;
                    const input_rect = c.SDL_Rect{ .x = @intFromFloat(caret.x), .y = @intFromFloat(caret.y), .w = 1, .h = @intFromFloat(caret.h) };
                    if (!c.SDL_SetTextInputArea(window, &input_rect, 0)) return error.TextInputArea;
                    if (self.preedit_len != 0) {
                        const preedit_layout = c.spica_text_layout_create(text, &self.preedit, self.preedit_len, panel.w - 24, 16, false) orelse return error.PreeditLayout;
                        defer c.spica_text_layout_release(preedit_layout);
                        if (!c.spica_text_layout_draw(text, preedit_layout, caret.x, caret.y, .{ .r = 164, .g = 185, .b = 255, .a = 255 })) return error.PreeditDraw;
                        if (!c.SDL_RenderLine(renderer, caret.x, caret.y + caret.h, caret.x + 32, caret.y + caret.h)) return error.PreeditDraw;
                    }
                }
            }
        }
        clip.restore(renderer);
        try self.labels.drawFitted(renderer, text, self.notice orelse "Enter send (unavailable)  /  Shift+Enter newline  /  Ctrl+Q close", panel.x + 12, panel.y + panel.h - 28, panel.w - 24, 12, muted);
    }
};

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
