const std = @import("std");
const c = @import("../native/bindings.zig").c;
const catalog = @import("../core/catalog.zig");
const Composer = @import("../text/composer.zig").Composer;
const GroupKind = @import("../text/composer.zig").GroupKind;
const Color = @import("theme.zig").Color;

pub const Action = union(enum) {
    scope: catalog.Scope,
    select: usize,
    activate,
    archive,
    restore,
    previous,
    next,
    close,
};
pub const Intent = union(enum) {
    search: struct { scope: catalog.Scope, offset: usize },
    activate,
    archive,
    restore,
    close,
};
const Target = struct { bounds: c.SDL_FRect, action: Action };
const query_limit = 256;
const preedit_limit = 4096;
const row_height: f32 = 66;

pub const Panel = struct {
    editor: Composer,
    open: bool = false,
    scope: catalog.Scope = .workspace,
    busy: bool = false,
    generation: u64 = 0,
    offset: usize = 0,
    waiting: bool = false,
    page: ?catalog.SearchPage = null,
    selected: usize = 0,
    selected_path: [4096]u8 = undefined,
    selected_path_len: usize = 0,
    first: usize = 0,
    visible: usize = 1,
    err: ?anyerror = null,
    input_err: ?anyerror = null,
    dragging: bool = false,
    targets: [40]Target = undefined,
    target_count: usize = 0,
    query_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    results_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    layout: ?*c.SpicaTextLayout = null,
    layout_dirty: bool = true,
    scroll_x: f32 = 0,
    preedit: [preedit_limit]u8 = undefined,
    preedit_len: usize = 0,
    preedit_start: usize = 0,
    preedit_end: usize = 0,
    copy: [query_limit + 1]u8 = undefined,
    display: [query_limit + preedit_limit]u8 = undefined,
    display_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Panel {
        return .{ .editor = try Composer.init(allocator) };
    }

    pub fn deinit(self: *Panel) void {
        if (self.layout) |layout| c.spica_text_layout_release(layout);
        if (self.page) |*page| page.deinit();
        self.editor.deinit();
        self.* = undefined;
    }

    pub fn show(self: *Panel, scope: catalog.Scope) void {
        self.close();
        self.open = true;
        self.scope = scope;
        self.offset = 0;
        self.selected = 0;
        self.first = 0;
        self.scroll_x = 0;
        self.err = null;
        self.input_err = null;
        self.editor.setText("") catch unreachable;
        self.layout_dirty = true;
    }

    pub fn close(self: *Panel) void {
        self.open = false;
        self.waiting = false;
        self.selected_path_len = 0;
        self.dragging = false;
        self.preedit_len = 0;
        self.layout_dirty = true;
        self.invalidateTargets();
        if (self.page) |*page| page.deinit();
        self.page = null;
    }

    pub fn invalidateTargets(self: *Panel) void {
        self.target_count = 0;
    }

    pub fn queryBytes(self: *const Panel) []const u8 {
        return self.editor.textBytes();
    }

    pub fn begin(self: *Panel, generation: u64) void {
        if (!self.waiting) self.rememberSelection();
        self.generation = generation;
        self.waiting = true;
        self.err = null;
        self.invalidateTargets();
    }

    pub fn fail(self: *Panel, err: anyerror) void {
        self.err = err;
        self.waiting = false;
        self.invalidateTargets();
    }

    pub fn accept(self: *Panel, result: catalog.SearchResult) void {
        switch (result) {
            .failure => |failure| {
                if (!self.open or failure.generation != self.generation) return;
                self.err = failure.err;
                self.waiting = false;
                // A failed new query must not make the old query actionable.
                if (self.page) |*page| page.deinit();
                self.page = null;
                self.invalidateTargets();
            },
            .ready => |value| {
                var incoming = value;
                if (!self.open or incoming.generation != self.generation or incoming.scope != self.scope or incoming.offset != self.offset) {
                    incoming.deinit();
                    return;
                }
                if (!self.waiting) self.rememberSelection();
                var selected: usize = 0;
                for (incoming.threads, 0..) |thread, index| {
                    if (std.mem.eql(u8, thread.path, self.selected_path[0..self.selected_path_len])) {
                        selected = index;
                        break;
                    }
                }
                if (self.page) |*old| old.deinit();
                self.page = incoming;
                self.selected = selected;
                self.waiting = false;
                self.err = null;
                self.ensureVisible();
                self.invalidateTargets();
                if (!incoming.searching) self.rememberSelection();
            },
        }
    }

    fn rememberSelection(self: *Panel) void {
        const page = self.page orelse return;
        if (page.searching or self.selected >= page.threads.len) return;
        const path = page.threads[self.selected].path;
        if (path.len > self.selected_path.len) return;
        @memcpy(self.selected_path[0..path.len], path);
        self.selected_path_len = path.len;
    }

    pub fn selectedThread(self: *const Panel) ?*const catalog.Thread {
        if (!self.open or self.waiting or self.busy) return null;
        if (self.page) |*page| {
            if (page.searching or page.generation != self.generation or page.scope != self.scope or page.offset != self.offset or self.selected >= page.threads.len) return null;
            return &page.threads[self.selected];
        }
        return null;
    }

    fn request(self: *Panel, reset: bool) Intent {
        if (reset) {
            self.offset = 0;
            self.first = 0;
            self.selected = 0;
            self.selected_path_len = 0;
        }
        self.waiting = true;
        self.err = null;
        self.invalidateTargets();
        return .{ .search = .{ .scope = self.scope, .offset = self.offset } };
    }

    pub fn act(self: *Panel, action: Action) ?Intent {
        if (!self.open) return null;
        switch (action) {
            .scope => |scope| {
                if (scope == self.scope) return null;
                self.scope = scope;
                self.preedit_len = 0;
                self.layout_dirty = true;
                return self.request(true);
            },
            .select => |index| {
                if (self.waiting or self.busy) return null;
                if (self.page) |page| if (!page.searching and index < page.threads.len) {
                    self.selected = index;
                    self.ensureVisible();
                };
            },
            .activate => {
                if (self.preedit_len == 0) if (self.selectedThread()) |_| return .activate;
            },
            .archive => {
                if (self.selectedThread()) |thread| if (!thread.archived and self.scope != .import_pi) return .archive;
            },
            .restore => {
                if (self.selectedThread()) |thread| if (thread.archived) return .restore;
            },
            .previous => {
                if (self.waiting or self.busy or self.offset == 0) return null;
                self.offset -|= 32;
                self.first = 0;
                self.selected = 0;
                return self.request(false);
            },
            .next => {
                if (self.waiting or self.busy) return null;
                const page = self.page orelse return null;
                if (page.generation != self.generation or page.scope != self.scope or page.offset != self.offset or !page.more or page.searching) return null;
                self.offset += 32;
                self.first = 0;
                self.selected = 0;
                return self.request(false);
            },
            .close => return .close,
        }
        return null;
    }

    fn ensureVisible(self: *Panel) void {
        const count = if (self.page) |page| page.threads.len else 0;
        self.first = @min(self.first, count -| self.visible);
        if (self.selected < self.first) self.first = self.selected;
        if (self.selected >= self.first + self.visible) self.first = self.selected + 1 -| self.visible;
    }

    fn addTarget(self: *Panel, action: Action, bounds: c.SDL_FRect) void {
        std.debug.assert(self.target_count < self.targets.len);
        self.targets[self.target_count] = .{ .action = action, .bounds = bounds };
        self.target_count += 1;
    }

    fn button(self: *Panel, app: anytype, action: Action, text: []const u8, bounds: c.SDL_FRect) !void {
        try app.button(.{ .library = action }, text, bounds);
        self.addTarget(action, bounds);
    }

    pub fn draw(self: *Panel, app: anytype) !void {
        if (!self.open) return;
        app.button_count = 0;
        self.invalidateTargets();
        const colors = app.palette();
        const canvas_w = app.shell.sidebar.width + app.shell.conversation.width;
        const canvas_h = app.shell.header.height + app.shell.conversation.height + app.shell.composer.height;
        const w = @min(@as(f32, 720), @max(@as(f32, 0), canvas_w - 24));
        const h = @min(@as(f32, 600), @max(@as(f32, 0), canvas_h - 24));
        const x = (canvas_w - w) / 2;
        const y = (canvas_h - h) / 2;
        const left = x + 12;
        const inner = w - 24;
        const footer_y = y + h - 40;
        try app.rectangle(0, 0, canvas_w, canvas_h, 0, colors.canvas);
        try app.rectangle(x, y, w, h, 9, colors.border);
        try app.rectangle(x + 1, y + 1, w - 2, h - 2, 8, colors.panel);
        try app.label("Chat library", left, y + 10, 17, colors.text);
        try self.button(app, .close, "Close", .{ .x = x + w - 74, .y = y + 7, .w = 62, .h = 28 });
        const tab_w = (inner - 12) / 3;
        const scopes = [_]catalog.Scope{ .workspace, .archives, .import_pi };
        const names = [_][]const u8{ "Search", "Archives", "Import Pi" };
        for (scopes, names, 0..) |scope, name, index| {
            const bounds = c.SDL_FRect{ .x = left + @as(f32, @floatFromInt(index)) * (tab_w + 6), .y = y + 41, .w = tab_w, .h = 28 };
            try self.button(app, .{ .scope = scope }, name, bounds);
            if (scope == self.scope) try app.rectangle(bounds.x + 4, bounds.y + bounds.h - 2, bounds.w - 8, 2, 0, colors.accent);
        }
        self.query_bounds = .{ .x = left, .y = y + 77, .w = inner, .h = 34 };
        try app.rectangle(left, self.query_bounds.y, inner, 34, 5, colors.raised);
        try self.drawQuery(app);
        var status_buffer: [128]u8 = undefined;
        const current_error: ?anyerror = if (self.input_err) |err| err else self.err;
        const status: []const u8 = if (current_error) |err|
            try std.fmt.bufPrint(&status_buffer, "Error: {s}", .{@errorName(err)})
        else if (self.busy)
            "Saving workspace change..."
        else if (self.waiting)
            "Searching..."
        else if (self.page) |page|
            if (page.warning) |warning| try std.fmt.bufPrint(&status_buffer, "{s}{s}Incomplete: {s}", .{ if (page.searching) "Searching... " else "", if (page.indexing) "Indexing... " else "", @errorName(warning) }) else if (page.searching and page.indexing) "Searching...  Indexing..." else if (page.searching) "Searching..." else if (page.indexing) "Indexing..." else if (page.threads.len == 0) "No matches" else try std.fmt.bufPrint(&status_buffer, "Results {d}-{d}", .{ page.offset + 1, page.offset + page.threads.len })
        else
            "Searching...";
        try clippedLabel(app, status, left, y + 118, inner, 12, colors.muted);
        self.results_bounds = .{ .x = left, .y = y + 140, .w = inner, .h = @max(0, footer_y - (y + 140) - 6) };
        self.visible = @max(1, @as(usize, @intFromFloat(@floor(self.results_bounds.h / row_height))));
        const count = if (self.page) |page| page.threads.len else 0;
        self.first = @min(self.first, count -| self.visible);
        var clip = Clip.push(app.renderer, self.results_bounds);
        defer clip.restore(app.renderer);
        if (self.page) |page| {
            const end = @min(page.threads.len, self.first + self.visible);
            for (page.threads[self.first..end], self.first..) |thread, index| {
                const top = self.results_bounds.y + @as(f32, @floatFromInt(index - self.first)) * row_height;
                const bounds = c.SDL_FRect{ .x = left, .y = top, .w = inner, .h = row_height - 4 };
                if (index == self.selected) try app.rectangle(bounds.x, bounds.y, bounds.w, bounds.h, 5, colors.raised);
                const badge: []const u8 = if (thread.archived and !thread.available) "Archived/offline" else if (thread.archived) "Archived" else if (!thread.available) "Unavailable" else "";
                const badge_w: f32 = if (badge.len != 0) 104 else 0;
                try clippedLabel(app, thread.title, left + 8, top + 5, inner - 16 - badge_w, 14, colors.text);
                if (badge.len != 0) try app.label(badge, left + inner - 100, top + 6, 11, colors.muted);
                try clippedLabel(app, if (thread.cwd.len != 0) thread.cwd else thread.path, left + 8, top + 24, inner - 16, 11, colors.muted);
                const excerpt = if (thread.snippet.len != 0) thread.snippet else if (!thread.available) "Source unavailable; cached result" else thread.path;
                try clippedLabel(app, excerpt, left + 8, top + 42, inner - 16, 11, colors.muted);
                if (!self.waiting and !self.busy and page.generation == self.generation and page.scope == self.scope and page.offset == self.offset and bounds.y + bounds.h <= self.results_bounds.y + self.results_bounds.h) self.addTarget(.{ .select = index }, bounds);
            }
        }
        clip.restore(app.renderer);
        // Footer is outside the result clip and stays fixed at minimum size.
        const paging_width: f32 = 52;
        if (!self.waiting and self.offset > 0) try self.button(app, .previous, "Prev", .{ .x = left, .y = footer_y, .w = paging_width, .h = 28 });
        if (!self.waiting) if (self.page) |page| if (page.generation == self.generation and page.scope == self.scope and page.offset == self.offset and page.more and !page.searching) try self.button(app, .next, "Next", .{ .x = left + 58, .y = footer_y, .w = paging_width, .h = 28 });
        if (self.selectedThread()) |thread| {
            const open_w: f32 = if (self.scope == .import_pi) 118 else 62;
            if (self.scope != .import_pi) try self.button(app, if (thread.archived) .restore else .archive, if (thread.archived) "Restore" else "Archive", .{ .x = left + inner - open_w - 84, .y = footer_y, .w = 78, .h = 28 });
            try self.button(app, .activate, if (self.scope == .import_pi) "Import and open" else "Open", .{ .x = left + inner - open_w, .y = footer_y, .w = open_w, .h = 28 });
        }
    }

    fn ensureLayout(self: *Panel, app: anytype) !void {
        if (!self.layout_dirty and self.layout != null) return;
        if (self.layout) |layout| c.spica_text_layout_release(layout);
        self.layout = null;
        const bytes = self.editor.textBytes();
        if (self.preedit_len != 0) {
            const range = self.editor.selection();
            @memcpy(self.display[0..range.start], bytes[0..range.start]);
            @memcpy(self.display[range.start..][0..self.preedit_len], self.preedit[0..self.preedit_len]);
            @memcpy(self.display[range.start + self.preedit_len ..][0 .. bytes.len - range.end], bytes[range.end..]);
            self.display_len = range.start + self.preedit_len + bytes.len - range.end;
        } else {
            @memcpy(self.display[0..bytes.len], bytes);
            self.display_len = bytes.len;
        }
        self.layout = c.spica_text_layout_create(app.text, &self.display, self.display_len, 100000, 15, false) orelse return error.LibraryQueryLayout;
        self.layout_dirty = false;
    }

    fn drawQuery(self: *Panel, app: anytype) !void {
        try self.ensureLayout(app);
        const layout = self.layout orelse return;
        const bounds = self.query_bounds;
        var clip = Clip.push(app.renderer, .{ .x = bounds.x + 6, .y = bounds.y + 4, .w = bounds.w - 12, .h = bounds.h - 8 });
        defer clip.restore(app.renderer);
        const colors = app.palette();
        const range = self.editor.selection();
        const caret_byte = if (self.preedit_len != 0) range.start + self.preedit_end else self.editor.caret;
        var caret: c.SDL_FRect = undefined;
        if (!c.spica_text_layout_caret(layout, caret_byte, &caret)) return error.LibraryCaret;
        const usable = bounds.w - 20;
        if (caret.x < self.scroll_x) self.scroll_x = caret.x;
        if (caret.x + 2 > self.scroll_x + usable) self.scroll_x = caret.x + 2 - usable;
        self.scroll_x = @max(0, self.scroll_x);
        const tx = bounds.x + 8 - self.scroll_x;
        const ty = bounds.y + 7;
        var rects: [preedit_limit + query_limit]c.SDL_FRect = undefined;
        const select_start = if (self.preedit_len != 0) range.start + self.preedit_start else range.start;
        const select_end = if (self.preedit_len != 0) range.start + self.preedit_end else range.end;
        const count = c.spica_text_layout_selection_rects(layout, select_start, select_end, &rects, rects.len);
        if (count > rects.len) return error.LibrarySelectionBudget;
        for (rects[0..count]) |*rect| {
            rect.x += tx;
            rect.y += ty;
        }
        if (!c.SDL_SetRenderDrawBlendMode(app.renderer, c.SDL_BLENDMODE_BLEND) or !c.SDL_SetRenderDrawColor(app.renderer, colors.accent.r, colors.accent.g, colors.accent.b, 60) or !c.SDL_RenderFillRects(app.renderer, &rects, @intCast(count))) return error.LibrarySelectionDraw;
        if (!c.spica_text_layout_draw(app.text, layout, tx, ty, rgba(colors.text))) return error.LibraryQueryDraw;
        if (self.preedit_len != 0) {
            const n = c.spica_text_layout_selection_rects(layout, range.start, range.start + self.preedit_len, &rects, rects.len);
            if (n > rects.len) return error.LibrarySelectionBudget;
            for (rects[0..n]) |rect| try app.rectangle(tx + rect.x, ty + rect.y + rect.h - 1, rect.w, 1, 0, colors.accent);
        } else if (self.editor.len == 0) try app.label(if (self.scope == .import_pi) "Search Pi titles and folders" else "Search titles, folders and messages", bounds.x + 8, ty, 13, colors.muted);
        try app.rectangle(tx + caret.x, ty + caret.y, 1, caret.h, 0, colors.text);
        var input_x: f32 = 0;
        var input_y: f32 = 0;
        var input_bottom: f32 = 0;
        const caret_x = std.math.clamp(tx + caret.x, bounds.x + 6, bounds.x + bounds.w - 6);
        if (!c.SDL_RenderCoordinatesToWindow(app.renderer, caret_x, ty + caret.y, &input_x, &input_y) or !c.SDL_RenderCoordinatesToWindow(app.renderer, caret_x, ty + caret.y + caret.h, null, &input_bottom)) return error.InputCoordinates;
        const area = c.SDL_Rect{ .x = @intFromFloat(input_x), .y = @intFromFloat(input_y), .w = 2, .h = @intFromFloat(@max(1, input_bottom - input_y)) };
        _ = c.SDL_SetTextInputArea(app.window, &area, 0);
    }

    fn insert(self: *Panel, bytes: []const u8, kind: GroupKind) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        var normalized: [query_limit]u8 = undefined;
        var n: usize = 0;
        var skip_lf = false;
        for (bytes) |byte| {
            if (skip_lf and byte == '\n') {
                skip_lf = false;
                continue;
            }
            skip_lf = byte == '\r';
            if (n == normalized.len) return error.QueryTooLarge;
            normalized[n] = if (byte == '\n' or byte == '\r') ' ' else byte;
            n += 1;
        }
        const selection = self.editor.selection();
        if (n > query_limit - (self.editor.len - (selection.end - selection.start))) return error.QueryTooLarge;
        try self.editor.insert(normalized[0..n], kind);
    }

    fn copySelection(self: *Panel) !void {
        const bytes = try self.editor.copySelection(self.copy[0..query_limit]);
        if (bytes.len == 0) return;
        self.copy[bytes.len] = 0;
        if (!c.SDL_SetClipboardText(@ptrCast(&self.copy))) return error.ClipboardWrite;
    }

    fn hitQuery(self: *Panel, app: anytype, x: f32, y: f32, extend: bool) !void {
        if (self.preedit_len != 0) {
            self.preedit_len = 0;
            _ = c.SDL_ClearComposition(app.window);
            self.layout_dirty = true;
        }
        try self.ensureLayout(app);
        if (self.layout) |layout| self.editor.setCaret(c.spica_text_layout_hit_test(layout, x - self.query_bounds.x - 8 + self.scroll_x, y - self.query_bounds.y - 7), extend);
    }

    /// Receives logical/render coordinates, after SDL_ConvertEventToRenderCoordinates.
    /// The app must return after this handler for every modal event, even with no intent.
    pub fn handle(self: *Panel, app: anytype, event: *const c.SDL_Event) !?Intent {
        if (!self.open) return null;
        app.dirty = true;
        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (event.button.button != c.SDL_BUTTON_LEFT) return null;
                if (contains(self.query_bounds, event.button.x, event.button.y)) {
                    try self.hitQuery(app, event.button.x, event.button.y, (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
                    self.dragging = true;
                    _ = c.SDL_StartTextInput(app.window);
                    return null;
                }
                var index = self.target_count;
                while (index > 0) {
                    index -= 1;
                    const target = self.targets[index];
                    if (!contains(target.bounds, event.button.x, event.button.y)) continue;
                    const intent = self.act(target.action);
                    if (target.action == .select and event.button.clicks >= 2) return self.act(.activate);
                    if (target.action == .scope) _ = c.SDL_ClearComposition(app.window);
                    return intent;
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => self.dragging = false,
            c.SDL_EVENT_MOUSE_MOTION => {
                if (self.dragging) try self.hitQuery(app, event.motion.x, event.motion.y, true);
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                if (self.page) |page| {
                    const last = page.threads.len -| self.visible;
                    self.first = if (event.wheel.y > 0) self.first -| 1 else if (event.wheel.y < 0) @min(last, self.first + 1) else self.first;
                    self.invalidateTargets();
                }
            },
            c.SDL_EVENT_TEXT_EDITING => {
                const bytes = std.mem.span(event.edit.text);
                if (bytes.len > self.preedit.len or !std.unicode.utf8ValidateSlice(bytes)) {
                    self.input_err = error.PreeditBudgetExceeded;
                    self.preedit_len = 0;
                    self.layout_dirty = true;
                    _ = c.SDL_ClearComposition(app.window);
                    return null;
                }
                for (bytes, 0..) |byte, index| self.preedit[index] = if (byte == '\r' or byte == '\n') ' ' else byte;
                self.preedit_len = bytes.len;
                self.preedit_start = scalarOffset(bytes, event.edit.start);
                self.preedit_end = scalarOffset(bytes, @as(i64, event.edit.start) + event.edit.length);
                self.layout_dirty = true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                self.insert(std.mem.span(event.text.text), if (self.preedit_len != 0) .ime else .typing) catch |err| {
                    self.preedit_len = 0;
                    self.layout_dirty = true;
                    self.input_err = err;
                    return null;
                };
                self.preedit_len = 0;
                self.layout_dirty = true;
                self.input_err = null;
                return self.request(true);
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mods = event.key.mod;
                const command = (mods & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
                const shift = (mods & c.SDL_KMOD_SHIFT) != 0;
                const word = command or (mods & c.SDL_KMOD_ALT) != 0;
                if (key == c.SDLK_ESCAPE) {
                    if (self.preedit_len != 0) {
                        self.preedit_len = 0;
                        self.layout_dirty = true;
                        _ = c.SDL_ClearComposition(app.window);
                        return null;
                    }
                    return .close;
                }
                if (self.preedit_len != 0) return null;
                if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) return self.act(.activate);
                if (key == c.SDLK_UP or key == c.SDLK_DOWN) {
                    if (self.waiting or self.busy) return null;
                    if (self.page) |page| {
                        if (page.threads.len != 0) {
                            self.selected = if (key == c.SDLK_UP) self.selected -| 1 else @min(page.threads.len - 1, self.selected + 1);
                            self.ensureVisible();
                            self.invalidateTargets();
                        }
                    }
                    return null;
                }
                if (key == c.SDLK_PAGEUP) return self.act(.previous);
                if (key == c.SDLK_PAGEDOWN) return self.act(.next);
                if (key == c.SDLK_HOME or key == c.SDLK_END) {
                    self.editor.setCaret(if (key == c.SDLK_END) self.editor.len else 0, shift);
                    return null;
                }
                if (key == c.SDLK_LEFT or key == c.SDLK_RIGHT) {
                    const direction: @import("../text/composer.zig").Direction = if (key == c.SDLK_LEFT) .backward else .forward;
                    if (word) self.editor.moveWord(direction, shift) else self.editor.moveGrapheme(direction, shift);
                    return null;
                }
                if (command and key == c.SDLK_A) {
                    self.editor.selectAll();
                    return null;
                }
                if (command and key == c.SDLK_C) {
                    try self.copySelection();
                    return null;
                }
                var before: [query_limit]u8 = undefined;
                const old_len = self.editor.len;
                @memcpy(before[0..old_len], self.editor.textBytes());
                if (command) switch (key) {
                    c.SDLK_X => {
                        try self.copySelection();
                        try self.editor.insert("", .paste);
                    },
                    c.SDLK_V => {
                        const clipboard = c.SDL_GetClipboardText() orelse return error.ClipboardRead;
                        defer c.SDL_free(clipboard);
                        self.insert(std.mem.span(clipboard), .paste) catch |err| {
                            self.input_err = err;
                            return null;
                        };
                    },
                    c.SDLK_Z => {
                        _ = if (shift) self.editor.redo() else self.editor.undo();
                    },
                    c.SDLK_Y => {
                        _ = self.editor.redo();
                    },
                    else => {},
                };
                if (key == c.SDLK_BACKSPACE) {
                    if (word) try self.editor.deleteWord(.backward) else try self.editor.backspace();
                } else if (key == c.SDLK_DELETE) {
                    if (word) try self.editor.deleteWord(.forward) else try self.editor.deleteForward();
                }
                if (!std.mem.eql(u8, before[0..old_len], self.editor.textBytes())) {
                    self.layout_dirty = true;
                    self.input_err = null;
                    return self.request(true);
                }
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.dragging = false;
                self.preedit_len = 0;
                self.layout_dirty = true;
                _ = c.SDL_ClearComposition(app.window);
            },
            else => {},
        }
        return null;
    }
};

fn scalarOffset(bytes: []const u8, requested: i64) usize {
    var offset: usize = 0;
    var remaining = @max(0, requested);
    while (offset < bytes.len and remaining > 0) : (remaining -= 1) {
        offset += std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return offset;
    }
    return @min(offset, bytes.len);
}

fn contains(bounds: c.SDL_FRect, x: f32, y: f32) bool {
    return x >= bounds.x and x < bounds.x + bounds.w and y >= bounds.y and y < bounds.y + bounds.h;
}

fn rgba(color: Color) c.SDL_Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
}

// Both labels and native query drawing preserve an enclosing renderer clip.
const Clip = struct {
    previous: c.SDL_Rect,
    enabled: bool,
    restored: bool = false,

    fn push(renderer: *c.SDL_Renderer, bounds: c.SDL_FRect) Clip {
        var result = Clip{ .previous = undefined, .enabled = c.SDL_RenderClipEnabled(renderer) };
        _ = c.SDL_GetRenderClipRect(renderer, &result.previous);
        var next = c.SDL_Rect{ .x = @intFromFloat(bounds.x), .y = @intFromFloat(bounds.y), .w = @intFromFloat(@max(0, bounds.w)), .h = @intFromFloat(@max(0, bounds.h)) };
        if (result.enabled) {
            const right = @min(next.x + next.w, result.previous.x + result.previous.w);
            const bottom = @min(next.y + next.h, result.previous.y + result.previous.h);
            next.x = @max(next.x, result.previous.x);
            next.y = @max(next.y, result.previous.y);
            next.w = @max(0, right - next.x);
            next.h = @max(0, bottom - next.y);
        }
        _ = c.SDL_SetRenderClipRect(renderer, &next);
        return result;
    }

    fn restore(self: *Clip, renderer: *c.SDL_Renderer) void {
        if (self.restored) return;
        _ = c.SDL_SetRenderClipRect(renderer, if (self.enabled) &self.previous else null);
        self.restored = true;
    }
};

fn clippedLabel(app: anytype, bytes: []const u8, x: f32, y: f32, width: f32, size: c_uint, color: Color) !void {
    if (width <= 0) return;
    var length = @min(bytes.len, 128);
    if (length < bytes.len) while (length > 0 and (bytes[length] & 0xc0) == 0x80) : (length -= 1) {};
    var clip = Clip.push(app.renderer, .{ .x = x, .y = y, .w = width, .h = @as(f32, @floatFromInt(size)) + 5 });
    defer clip.restore(app.renderer);
    // Newlines in excerpts must not produce rows outside the result cell.
    var single_line: [128]u8 = undefined;
    for (bytes[0..length], 0..) |byte, index| single_line[index] = if (byte == '\r' or byte == '\n' or byte == '\t') ' ' else byte;
    try app.label(single_line[0..length], x, y, size, color);
}

test "query size rejection preserves text selection and undo history" {
    var panel = try Panel.init(std.testing.allocator);
    defer panel.deinit();
    panel.show(.workspace);
    try panel.insert("café\r\nsettings\npanel", .paste);
    try std.testing.expectEqualStrings("café settings panel", panel.queryBytes());
    panel.editor.selectAll();
    const selection = panel.editor.selection();
    const oversized = [_]u8{'x'} ** 257;
    try std.testing.expectError(error.QueryTooLarge, panel.insert(&oversized, .paste));
    try std.testing.expectEqualStrings("café settings panel", panel.queryBytes());
    try std.testing.expectEqual(selection, panel.editor.selection());
    try std.testing.expectError(error.InvalidUtf8, panel.insert("\xff", .paste));
    try std.testing.expectEqualStrings("café settings panel", panel.queryBytes());
    try panel.insert(&([_]u8{'x'} ** 256), .paste);
    try std.testing.expectEqualStrings(&([_]u8{'x'} ** 256), panel.queryBytes());
    try std.testing.expectError(error.QueryTooLarge, panel.insert("é", .typing));
    try std.testing.expect(panel.editor.undo());
    try std.testing.expectEqualStrings("café settings panel", panel.queryBytes());
}

fn testPage(paths: []const []const u8, generation: u64, searching: bool) !catalog.SearchPage {
    const allocator = std.heap.page_allocator;
    const threads = try allocator.alloc(catalog.Thread, paths.len);
    var count: usize = 0;
    errdefer {
        for (threads[0..count]) |*thread| thread.deinit();
        allocator.free(threads);
    }
    for (paths, threads) |path, *thread| {
        const source = try allocator.dupeZ(u8, path);
        errdefer allocator.free(source);
        const cwd = try allocator.dupeZ(u8, "/project");
        errdefer allocator.free(cwd);
        thread.* = .{ .path = source, .cwd = cwd, .title = try allocator.dupe(u8, "Same title"), .modified = 1 };
        count += 1;
    }
    return .{ .threads = threads, .generation = generation, .scope = .workspace, .offset = 0, .more = true, .searching = searching };
}

test "library selection retains source identity through incomplete and stale replacements" {
    var panel = try Panel.init(std.testing.allocator);
    defer panel.deinit();
    panel.show(.workspace);
    panel.begin(1);
    panel.accept(.{ .ready = try testPage(&.{ "/first.jsonl", "/selected.jsonl" }, 1, false) });
    _ = panel.act(.{ .select = 1 });
    panel.begin(2);
    panel.accept(.{ .ready = try testPage(&.{}, 2, true) });
    try std.testing.expect(panel.selectedThread() == null);
    try std.testing.expect(panel.act(.activate) == null);
    try std.testing.expect(panel.act(.next) == null);
    panel.accept(.{ .ready = try testPage(&.{"/wrong-generation.jsonl"}, 1, false) });
    try std.testing.expect(panel.selectedThread() == null);
    panel.accept(.{ .ready = try testPage(&.{ "/selected.jsonl", "/first.jsonl" }, 2, false) });
    try std.testing.expectEqualStrings("/selected.jsonl", panel.selectedThread().?.path);
    panel.preedit_len = 1;
    try std.testing.expect(panel.act(.activate) == null);
    panel.preedit_len = 0;
    try std.testing.expect(panel.act(.activate).? == .activate);
    _ = panel.request(true);
    panel.begin(3);
    panel.accept(.{ .ready = try testPage(&.{ "/first.jsonl", "/selected.jsonl" }, 3, false) });
    try std.testing.expectEqualStrings("/first.jsonl", panel.selectedThread().?.path);
    panel.accept(.{ .failure = .{ .generation = 3, .err = error.FuzzySearchFailed } });
    try std.testing.expect(panel.selectedThread() == null);
    try std.testing.expect(!panel.waiting);
}
