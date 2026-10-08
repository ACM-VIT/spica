const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Model = @import("../core/runtime.zig").Model;
const preferences = @import("../core/model_preferences.zig");

const Quality = struct { class: u8, score: f64 };
const Match = struct { index: usize, quality: Quality, hidden: bool = false };
const query_scalars = 256 * 3; // Maximum case-fold expansion per input byte.

/// Reusable ranked indices, bounded by the runtime's complete catalog budget.
pub const Search = struct {
    matches: [@import("../core/runtime.zig").model_limit]Match = undefined,
    len: usize = 0,
    active_len: usize = 0,
    dirty: bool = true,

    pub fn invalidate(self: *Search) void {
        self.len = 0;
        self.dirty = true;
    }

    pub fn index(self: *const Search, ranked_index: usize) ?usize {
        return if (ranked_index < self.len) self.matches[ranked_index].index else null;
    }

    pub fn rebuild(self: *Search, models: []const Model, query: []const u8) !void {
        return self.rebuildVisible(models, query, &.{});
    }

    pub fn rebuildVisible(self: *Search, models: []const Model, query: []const u8, hidden: []const preferences.Identity) !void {
        return self.build(models, query, hidden, false);
    }

    /// One bounded result buffer, active results first, independently ranked
    /// within each section. Hidden results are retained even with no query.
    pub fn rebuildGrouped(self: *Search, models: []const Model, query: []const u8, hidden: []const preferences.Identity) !void {
        try self.build(models, query, hidden, true);
    }

    fn build(self: *Search, models: []const Model, query: []const u8, hidden: []const preferences.Identity, grouped: bool) !void {
        self.invalidate();
        self.active_len = 0;
        if (models.len > self.matches.len) return error.ModelSearchBudget;
        if (query.len > 256 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidSearchQuery;
        const browsing = std.mem.trim(u8, query, " \t\r\n").len == 0;
        for (models, 0..) |model, i| self.matches[i] = .{ .index = i, .hidden = preferences.contains(hidden, model.provider, model.id), .quality = .{
            .class = if (!grouped and browsing and preferences.contains(hidden, model.provider, model.id)) 0 else 2,
            .score = 0,
        } };
        var terms = std.mem.tokenizeAny(u8, query, " \t\r\n");
        while (terms.next()) |term| {
            var query_buffer: [query_scalars]u32 = undefined;
            const values = try normalize(term, &query_buffer);
            const scorer = if (values.len >= 3)
                c.spica_fuzzy_create(values.ptr, values.len) orelse return error.FuzzySearchFailed
            else
                null;
            defer if (scorer) |owned| c.spica_fuzzy_destroy(owned);
            for (self.matches[0..models.len]) |*match| {
                if (match.quality.class == 0) continue;
                const quality = try scoreTerm(models[match.index], values, scorer);
                match.quality.class = @min(match.quality.class, quality.class);
                match.quality.score += quality.score;
            }
        }
        for (self.matches[0..models.len]) |match| {
            if (match.quality.class == 0) continue;
            self.matches[self.len] = match;
            self.len += 1;
            if (!match.hidden) self.active_len += 1;
        }
        std.mem.sort(Match, self.matches[0..self.len], grouped, better);
        self.dirty = false;
    }
};

fn better(grouped: bool, a: Match, b: Match) bool {
    if (grouped and a.hidden != b.hidden) return !a.hidden;
    if (a.quality.class != b.quality.class) return a.quality.class > b.quality.class;
    if (a.quality.score != b.quality.score) return a.quality.score > b.quality.score;
    return a.index < b.index;
}

test "hidden models stay searchable and later providers survive large catalogs" {
    const models = try std.testing.allocator.alloc(Model, 600);
    defer std.testing.allocator.free(models);
    for (models) |*model| model.* = .{ .provider = "router", .id = "common", .name = "Common" };
    models[599] = .{ .provider = "google", .id = "gemini-example", .name = "Gemini example" };
    const hidden = [_]preferences.Identity{.{ .provider = "google", .id = "gemini-example" }};
    var search: Search = .{};
    try search.rebuildVisible(models, "", &hidden);
    try std.testing.expectEqual(@as(usize, 599), search.len);
    try search.rebuildVisible(models, "   ", &hidden);
    try std.testing.expectEqual(@as(usize, 599), search.len);
    try search.rebuildVisible(models, "gemini", &hidden);
    try std.testing.expectEqual(@as(usize, 1), search.len);
    try std.testing.expectEqual(@as(?usize, 599), search.index(0));
    // Identical IDs on another provider are separate user choices.
    models[0] = .{ .provider = "other", .id = "gemini-example", .name = "Gemini example" };
    try search.rebuildVisible(models, "", &hidden);
    try std.testing.expectEqual(@as(?usize, 0), search.index(0));
}

test "grouped model results rank each section and move restored identities immediately" {
    const models = [_]Model{
        .{ .provider = "one", .id = "shared", .name = "Model B" },
        .{ .provider = "two", .id = "shared", .name = "Model A" },
        .{ .provider = "one", .id = "other", .name = "Model A" },
    };
    const hidden = [_]preferences.Identity{.{ .provider = "one", .id = "shared" }};
    var search: Search = .{};
    try search.rebuildGrouped(&models, "", &hidden);
    try std.testing.expectEqual(@as(usize, 3), search.len);
    try std.testing.expectEqual(@as(usize, 2), search.active_len);
    try std.testing.expectEqual(@as(?usize, 1), search.index(0));
    try std.testing.expectEqual(@as(?usize, 0), search.index(2));
    try search.rebuildGrouped(&models, "model b", &hidden);
    try std.testing.expectEqual(@as(usize, 1), search.len);
    try std.testing.expectEqual(@as(usize, 0), search.active_len);
    try search.rebuildGrouped(&models, "model b", &.{});
    try std.testing.expectEqual(@as(usize, 1), search.active_len);
}

const FoldIterator = struct {
    utf8: std.unicode.Utf8Iterator,
    folded: [3]u32 = undefined,
    len: usize = 0,
    index: usize = 0,

    fn init(bytes: []const u8) !FoldIterator {
        return .{ .utf8 = (try std.unicode.Utf8View.init(bytes)).iterator() };
    }

    fn next(self: *FoldIterator) ?u32 {
        if (self.index == self.len) {
            const scalar = self.utf8.nextCodepoint() orelse return null;
            self.len = c.spica_fuzzy_case_fold(scalar, &self.folded);
            self.index = 0;
        }
        const scalar = self.folded[self.index];
        self.index += 1;
        return scalar;
    }
};

fn normalize(bytes: []const u8, buffer: []u32) ![]const u32 {
    var iterator = try FoldIterator.init(bytes);
    var len: usize = 0;
    while (iterator.next()) |scalar| {
        if (len == buffer.len) return error.SearchTokenTooLarge;
        buffer[len] = scalar;
        len += 1;
    }
    return buffer[0..len];
}

// Stream direct matching so even fields beyond the fuzzy budget stay searchable.
fn containsTerm(field: []const u8, term: []const u32) !bool {
    var iterator = try FoldIterator.init(field);
    while (iterator.next()) |scalar| {
        if (scalar != term[0]) continue;
        var rest = iterator;
        for (term[1..]) |expected| {
            if (rest.next() != expected) break;
        } else return true;
    }
    return false;
}

fn similarity(bytes: []const u8, query: *c.SpicaFuzzyQuery, buffer: []u32) !f64 {
    const values = normalize(bytes, buffer) catch |err| switch (err) {
        // A candidate over twice the query budget cannot reach 70% similarity.
        error.SearchTokenTooLarge => return 0,
        else => return err,
    };
    var score: c.SpicaFuzzyScore = undefined;
    if (!c.spica_fuzzy_score(query, values.ptr, values.len, &score)) return error.FuzzySearchFailed;
    return score.ratio;
}

fn scoreTerm(model: Model, term: []const u32, scorer: ?*c.SpicaFuzzyQuery) !Quality {
    const fields = [_][]const u8{ model.name, model.id, model.provider };
    for (fields) |field| {
        if (try containsTerm(field, term)) return .{ .class = 2, .score = 100 };
    }
    const query = scorer orelse return .{ .class = 0, .score = 0 };
    var best: f64 = 0;
    var buffer: [query_scalars * 2]u32 = undefined;
    for (fields) |field| {
        best = @max(best, try similarity(field, query, &buffer));
        var words = std.mem.tokenizeAny(u8, field, " \t\r\n-_/.:()");
        while (words.next()) |word| {
            best = @max(best, try similarity(word, query, &buffer));
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

test "model fuzzy search scores full IDs with transposed letters" {
    var search: Search = .{};
    const models = [_]Model{
        .{ .name = "Claude Opus", .id = "claude-opus-4-6", .provider = "anthropic" },
        .{ .name = "Exact typo", .id = "claude-opsu-4-6", .provider = "test" },
        .{ .name = "Claude Haiku", .id = "claude-haiku-4-5", .provider = "anthropic" },
    };
    try search.rebuild(&models, "claude-opsu-4-6");
    try std.testing.expectEqual(@as(usize, 3), search.len);
    try std.testing.expectEqual(@as(?usize, 1), search.index(0));
    try std.testing.expectEqual(@as(?usize, 0), search.index(1));
    try std.testing.expectEqual(@as(?usize, 2), search.index(2));
}

test "model search folds Unicode for short prefixes and fuzzy matches in every field" {
    var search: Search = .{};
    const models = [_]Model{
        .{ .name = "Écho", .id = "echo", .provider = "local" },
        .{ .name = "Other", .id = "Écho", .provider = "local" },
        .{ .name = "Other", .id = "other", .provider = "Écho" },
    };
    for ([_][]const u8{ "éc", "ÉC", "éHco", "Éhco" }) |query| {
        try search.rebuild(&models, query);
        try std.testing.expectEqual(models.len, search.len);
        for (0..models.len) |i| try std.testing.expectEqual(@as(?usize, i), search.index(i));
    }
}

test "model search streams long fields and handles expanding Unicode folds" {
    var search: Search = .{};
    const models = [_]Model{
        .{ .name = "x" ** (query_scalars * 2 + 1) ++ "Écho", .id = "echo", .provider = "local" },
        .{ .name = "Straße", .id = "street", .provider = "local" },
        .{ .name = "ΟΣ", .id = "greek", .provider = "local" },
    };
    for ([_][]const u8{ "éc", "ÉC" }) |query| {
        try search.rebuild(&models, query);
        try std.testing.expectEqual(@as(usize, 1), search.len);
        try std.testing.expectEqual(@as(?usize, 0), search.index(0));
    }
    try search.rebuild(&models, "STRASSE");
    try std.testing.expectEqual(@as(?usize, 1), search.index(0));
    try search.rebuild(&models, "ος");
    try std.testing.expectEqual(@as(usize, 1), search.len);
    try std.testing.expectEqual(@as(?usize, 2), search.index(0));
    const expanding = [_]Model{.{ .name = "ΐ" ** 128, .id = "expanded", .provider = "local" }};
    try search.rebuild(&expanding, "ΐ" ** 128);
    try std.testing.expectEqual(@as(usize, 1), search.len);
}
