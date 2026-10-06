const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Model = @import("../core/runtime.zig").Model;

const Quality = struct { class: u8, score: f64 };
const Match = struct { index: usize, quality: Quality };

/// Ranked original indices, bounded by the runtime's 256-model display budget.
pub const Search = struct {
    matches: [256]Match = undefined,
    len: usize = 0,
    dirty: bool = true,

    pub fn invalidate(self: *Search) void {
        self.len = 0;
        self.dirty = true;
    }

    pub fn index(self: *const Search, ranked_index: usize) ?usize {
        return if (ranked_index < self.len) self.matches[ranked_index].index else null;
    }

    pub fn rebuild(self: *Search, models: []const Model, query: []const u8) !void {
        self.invalidate();
        if (models.len > self.matches.len) return error.ModelSearchBudget;
        if (query.len > 256 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidSearchQuery;
        for (models, 0..) |_, i| self.matches[i] = .{ .index = i, .quality = .{ .class = 2, .score = 0 } };
        var terms = std.mem.tokenizeAny(u8, query, " \t\r\n");
        while (terms.next()) |term| {
            var query_buffer: [256]u32 = undefined;
            const values = try normalize(term, &query_buffer);
            const scorer = if (values.len >= 3)
                c.spica_fuzzy_create(values.ptr, values.len) orelse return error.FuzzySearchFailed
            else
                null;
            defer if (scorer) |owned| c.spica_fuzzy_destroy(owned);
            for (self.matches[0..models.len]) |*match| {
                if (match.quality.class == 0) continue;
                const quality = try scoreTerm(models[match.index], term, scorer);
                match.quality.class = @min(match.quality.class, quality.class);
                match.quality.score += quality.score;
            }
        }
        for (self.matches[0..models.len]) |match| {
            if (match.quality.class == 0) continue;
            self.matches[self.len] = match;
            self.len += 1;
        }
        std.mem.sort(Match, self.matches[0..self.len], {}, better);
        self.dirty = false;
    }
};

fn better(_: void, a: Match, b: Match) bool {
    if (a.quality.class != b.quality.class) return a.quality.class > b.quality.class;
    if (a.quality.score != b.quality.score) return a.quality.score > b.quality.score;
    return a.index < b.index;
}

fn normalize(bytes: []const u8, buffer: []u32) ![]const u32 {
    var iterator = (try std.unicode.Utf8View.init(bytes)).iterator();
    var len: usize = 0;
    while (iterator.nextCodepoint()) |scalar| {
        if (len == buffer.len) return error.SearchTokenTooLarge;
        buffer[len] = if (scalar < 128) std.ascii.toLower(@intCast(scalar)) else scalar;
        len += 1;
    }
    return buffer[0..len];
}

fn scoreTerm(model: Model, term: []const u8, scorer: ?*c.SpicaFuzzyQuery) !Quality {
    const fields = [_][]const u8{ model.name, model.id, model.provider };
    for (fields) |field| {
        if (std.ascii.indexOfIgnoreCase(field, term) != null) return .{ .class = 2, .score = 100 };
    }
    const query = scorer orelse return .{ .class = 0, .score = 0 };
    var best: f64 = 0;
    var buffer: [512]u32 = undefined;
    for (fields) |field| {
        var words = std.mem.tokenizeAny(u8, field, " \t\r\n-_/.:()");
        while (words.next()) |word| {
            // A >512-scalar token cannot reach 70% similarity to a <=256-scalar query.
            const values = normalize(word, &buffer) catch |err| switch (err) {
                error.SearchTokenTooLarge => continue,
                else => return err,
            };
            var score: c.SpicaFuzzyScore = undefined;
            if (!c.spica_fuzzy_score(query, values.ptr, values.len, &score)) return error.FuzzySearchFailed;
            best = @max(best, score.ratio);
        }
    }
    return if (best >= 70) .{ .class = 1, .score = best } else .{ .class = 0, .score = 0 };
}

test "model fuzzy search tolerates typos and ranks direct matches before approximations" {
    var search: Search = .{};
    const models = [_]Model{
        .{ .name = "Claude Opus", .id = "claude-opus-4-6", .provider = "anthropic" },
        .{ .name = "Claude Haiku", .id = "claude-haiku-4-5", .provider = "anthropic" },
        .{ .name = "DeepSeek V4", .id = "deepseek-v4", .provider = "openrouter" },
        .{ .name = "Opsu", .id = "opsu", .provider = "test" },
    };
    try search.rebuild(&models, "OPSU");
    try std.testing.expectEqual(@as(usize, 2), search.len);
    try std.testing.expectEqual(@as(?usize, 3), search.index(0));
    try std.testing.expectEqual(@as(?usize, 0), search.index(1));
    try std.testing.expect(search.index(2) == null);
    for ([_][]const u8{ "opuss", "ops", "anthrpic opsu" }) |query| {
        try search.rebuild(models[0..3], query);
        try std.testing.expectEqual(@as(usize, 1), search.len);
        try std.testing.expectEqual(@as(?usize, 0), search.index(0));
    }
    try search.rebuild(&models, "haikuu");
    try std.testing.expectEqual(@as(usize, 1), search.len);
    try std.testing.expectEqual(@as(?usize, 1), search.index(0));
    try search.rebuild(&models, "opu haiku");
    try std.testing.expectEqual(@as(usize, 0), search.len);
    try search.rebuild(&models, "zz");
    try std.testing.expectEqual(@as(usize, 0), search.len);
    try search.rebuild(&models, "   ");
    try std.testing.expectEqual(models.len, search.len);
    for (0..models.len) |i| try std.testing.expectEqual(@as(?usize, i), search.index(i));
    search.invalidate();
    try std.testing.expect(search.dirty);
    try std.testing.expect(search.index(0) == null);
}

test "model fuzzy search orders similarity scores and keeps indices tied to the current list" {
    var search: Search = .{};
    const models = [_]Model{
        .{ .name = "Opus", .id = "opus", .provider = "anthropic" },
        .{ .name = "Opsus", .id = "opsus", .provider = "anthropic" },
        .{ .name = "Café", .id = "café", .provider = "test" },
    };
    try search.rebuild(&models, "opsu");
    try std.testing.expectEqual(@as(?usize, 1), search.index(0));
    try std.testing.expectEqual(@as(?usize, 0), search.index(1));
    try search.rebuild(&models, "cafè");
    try std.testing.expectEqual(@as(?usize, 2), search.index(0));
    try search.rebuild(models[1..], "opsu");
    try std.testing.expectEqual(@as(?usize, 0), search.index(0));
    try std.testing.expectEqual(@as(usize, 1), search.len);
    try std.testing.expectError(error.InvalidSearchQuery, search.rebuild(&models, "\xff"));
    try std.testing.expect(search.dirty);
    try std.testing.expect(search.index(0) == null);
}
