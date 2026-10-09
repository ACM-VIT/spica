const c = @import("../native/bindings.zig").c;
const Composer = @import("../text/composer.zig").Composer;

pub const text_x: f32 = 12;
pub const text_y: f32 = 10;

pub const EditorView = struct {
    layout: ?*c.SpicaTextLayout = null,
    width: f32 = 0,
    start: usize = 0,
    end: usize = 0,
    scroll: f32 = 0,
    preferred_x: ?f32 = null,
    changed: bool = true,
    bounds: c.SDL_FRect = undefined,

    pub fn deinit(self: *EditorView) void {
        if (self.layout) |layout| c.spica_text_layout_release(layout);
        self.layout = null;
    }

    pub fn reset(self: *EditorView) void {
        self.scroll = 0;
        self.start = 0;
        self.end = 0;
        self.width = 0;
        self.preferred_x = null;
        self.changed = true;
    }

    pub fn ensureLayout(self: *EditorView, text: *c.SpicaText, editor: *const Composer, width: f32, body_px: f32) !void {
        if (width <= 24) return;
        if (!self.changed and self.width == width and editor.caret >= self.start and editor.caret <= self.end) return;
        if (self.layout) |layout| c.spica_text_layout_release(layout);
        self.layout = null;
        const bytes = editor.textBytes();
        const range = editor.viewportRange(8192);
        if (range.start != self.start) self.scroll = 0;
        self.start = range.start;
        self.end = range.end;
        const slice = bytes[range.start..range.end];
        self.layout = c.spica_text_layout_create(text, slice.ptr, slice.len, width - 24, @intFromFloat(body_px), false) orelse return error.EditorLayout;
        self.width = width;
        self.changed = false;
    }

    pub fn caret(self: *const EditorView, editor: *const Composer) ?c.SDL_FRect {
        const layout = self.layout orelse return null;
        var rect: c.SDL_FRect = undefined;
        return if (c.spica_text_layout_caret(layout, editor.caret - self.start, &rect)) rect else null;
    }

    pub fn offsetAt(self: *const EditorView, x: f32, y: f32) ?usize {
        const layout = self.layout orelse return null;
        return self.start + c.spica_text_layout_hit_test(layout, x - self.bounds.x - text_x, y - self.bounds.y - text_y + self.scroll);
    }

    pub fn moveVertical(self: *EditorView, text: *c.SpicaText, editor: *Composer, body_px: f32, down: bool, extend: bool) !void {
        try self.ensureLayout(text, editor, self.width, body_px);
        const layout = self.layout orelse return;
        const current = self.caret(editor) orelse return;
        const x = self.preferred_x orelse current.x;
        self.preferred_x = x;
        const y = current.y + (if (down) @as(f32, 1.5) else -0.5) * current.h;
        editor.setCaret(self.start + c.spica_text_layout_hit_test(layout, x, y), extend);
    }

    pub fn moveLineEdge(self: *EditorView, text: *c.SpicaText, editor: *Composer, body_px: f32, end: bool, whole: bool, extend: bool) !void {
        if (whole) {
            editor.setCaret(if (end) editor.len else 0, extend);
        } else {
            try self.ensureLayout(text, editor, self.width, body_px);
            if (self.layout) |layout| if (self.caret(editor)) |current| {
                editor.setCaret(self.start + c.spica_text_layout_hit_test(layout, if (end) 1000000 else 0, current.y + current.h * 0.5), extend);
            };
        }
        self.preferred_x = null;
    }
};
