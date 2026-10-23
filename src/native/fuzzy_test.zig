const std = @import("std");
const c = @cImport({
    @cInclude("fuzzy.h");
});

test "native Unicode case folding preserves scalar expansions" {
    var folded: [3]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), c.spica_fuzzy_case_fold('ß', &folded));
    try std.testing.expectEqualSlices(u32, &.{ 's', 's' }, folded[0..2]);
    try std.testing.expectEqual(@as(usize, 1), c.spica_fuzzy_case_fold('Σ', &folded));
    try std.testing.expectEqual(@as(u32, 'σ'), folded[0]);
}

test "native fuzzy query scores borrowed scalars and accepts empty ranges" {
    const query = [_]u32{ 'c', 'a', 'f', 'é' };
    const scorer = c.spica_fuzzy_create(&query, query.len) orelse return error.FuzzyQuery;
    defer c.spica_fuzzy_destroy(scorer);
    var score: c.SpicaFuzzyScore = undefined;
    try std.testing.expect(c.spica_fuzzy_score(scorer, &query, query.len, &score));
    try std.testing.expectEqual(@as(f64, 100), score.ratio);
    try std.testing.expect(score.subsequence);
    const candidate = [_]u32{ 'x', 'c', 'a', 'f', 'é', 'y' };
    try std.testing.expect(c.spica_fuzzy_score(scorer, &candidate, candidate.len, &score));
    try std.testing.expect(score.subsequence and score.ratio < 100);
    try std.testing.expect(c.spica_fuzzy_create(null, 1) == null);
    try std.testing.expect(!c.spica_fuzzy_score(scorer, null, 1, &score));
    const empty = c.spica_fuzzy_create(null, 0) orelse return error.FuzzyQuery;
    defer c.spica_fuzzy_destroy(empty);
    try std.testing.expect(c.spica_fuzzy_score(empty, null, 0, &score));
    try std.testing.expectEqual(@as(f64, 100), score.ratio);
}
