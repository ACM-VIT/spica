const c = @import("../../native/bindings.zig").c;
const Model = @import("../../core/runtime.zig").Model;
const Search = @import("search.zig").Search;

pub const Picker = struct {
    open: bool = false,
    first: usize = 0,
    highlight: usize = 0,
    visible: usize = 1,
    selection_cleared: bool = false,
    search: Search = .{},
    popup_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn restart(self: *Picker) void {
        self.search.invalidate();
        self.first = 0;
        self.highlight = 0;
        self.selection_cleared = false;
    }

    fn refresh(self: *Picker, models: []const Model, query: []const u8) !void {
        if (!self.search.dirty) return;
        try self.search.rebuild(models, query);
    }

    pub fn count(self: *Picker, models: []const Model, query: []const u8) !usize {
        try self.refresh(models, query);
        return self.search.len;
    }

    pub fn index(self: *Picker, models: []const Model, query: []const u8, ranked_index: usize) !?usize {
        try self.refresh(models, query);
        return self.search.index(ranked_index);
    }

    pub fn selected(self: *Picker, models: []const Model, query: []const u8) !?usize {
        if (self.selection_cleared) return null;
        return self.index(models, query, self.highlight);
    }

    pub fn move(self: *Picker, models: []const Model, query: []const u8, down: bool) !void {
        const last = (try self.count(models, query)) -| 1;
        self.highlight = if (self.selection_cleared) @min(last, self.first) else if (down) @min(last, self.highlight + 1) else self.highlight -| 1;
        self.selection_cleared = false;
    }

    pub fn hover(self: *Picker, model_index: usize) bool {
        const end = @min(self.search.len, self.first + self.visible);
        for (self.search.matches[self.first..end], self.first..) |match, rank| {
            if (match.index != model_index) continue;
            if (!self.selection_cleared and self.highlight == rank) return false;
            self.highlight = rank;
            self.selection_cleared = false;
            return true;
        }
        return false;
    }

    pub fn scrollToHighlight(self: *Picker, count_: usize, visible: usize) void {
        self.visible = visible;
        self.highlight = @min(self.highlight, count_ -| 1);
        self.first = @min(self.first, count_ -| 1);
        if (self.highlight < self.first) self.first = self.highlight;
        if (self.highlight >= self.first + visible) self.first = self.highlight + 1 - visible;
    }

    pub fn scroll(self: *Picker, models: []const Model, query: []const u8, direction: f32) !void {
        const last = (try self.count(models, query)) -| 1;
        const before = self.first;
        self.first = if (direction > 0) self.first -| 1 else if (direction < 0) @min(last, self.first + 1) else self.first;
        self.highlight = if (self.selection_cleared) self.first else @min(last, (self.highlight + self.first) -| before);
        if (direction != 0) self.selection_cleared = false;
    }

    pub fn replaceModels(self: *Picker, old: []const Model, incoming: []const Model, query: []const u8) !bool {
        const selected_index = if (self.open) try self.selected(old, query) else null;
        var retained: ?usize = null;
        if (selected_index) |previous_index| {
            for (incoming, 0..) |model, incoming_index| {
                if (old[previous_index].sameIdentity(model)) {
                    retained = incoming_index;
                    break;
                }
            }
        }
        self.search.invalidate();
        if (!self.open) return false;
        if (selected_index != null) self.selection_cleared = true;
        try self.search.rebuild(incoming, query);
        self.first = @min(self.first, self.search.len -| 1);
        if (retained) |kept| {
            for (self.search.matches[0..self.search.len], 0..) |match, rank| {
                if (match.index == kept) {
                    self.highlight = rank;
                    self.selection_cleared = false;
                    break;
                }
            }
        }
        if (self.selection_cleared) {
            self.first = 0;
            self.highlight = 0;
        }
        return true;
    }
};
