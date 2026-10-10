const std = @import("std");
const c = @import("../../native/bindings.zig").c;
const Model = @import("../../core/runtime.zig").Model;
const Search = @import("search.zig").Search;

pub const Picker = struct {
    open: bool = false,
    first: usize = 0,
    selection_cleared: bool = false,
    search: Search = .{},
    popup_bounds: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn restart(self: *Picker) void {
        self.search.invalidate();
        self.first = 0;
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
        return self.index(models, query, self.first);
    }

    pub fn previous(self: *Picker) void {
        self.first -|= 1;
        self.selection_cleared = false;
    }

    pub fn next(self: *Picker, models: []const Model, query: []const u8) !void {
        const last = (try self.count(models, query)) -| 1;
        self.first = if (self.selection_cleared) 0 else @min(last, self.first + 1);
        self.selection_cleared = false;
    }

    pub fn scroll(self: *Picker, models: []const Model, query: []const u8, direction: f32) !void {
        const last = (try self.count(models, query)) -| 1;
        self.first = if (direction > 0) self.first -| 1 else if (direction < 0) @min(last, self.first + 1) else self.first;
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
                    self.first = rank;
                    self.selection_cleared = false;
                    break;
                }
            }
        }
        if (self.selection_cleared) self.first = 0;
        return true;
    }
};

test "model refresh with retained snapshot preserves keyboard selection" {
    var picker: Picker = .{ .open = true };
    const models = [_]Model{
        .{ .provider = "openai-codex", .id = "one", .name = "One" },
        .{ .provider = "anthropic", .id = "two", .name = "Two" },
    };
    try std.testing.expectEqual(@as(?usize, 0), try picker.selected(&models, ""));
    try std.testing.expect(try picker.replaceModels(&models, &models, ""));
    try std.testing.expectEqual(@as(?usize, 0), try picker.selected(&models, ""));
}
