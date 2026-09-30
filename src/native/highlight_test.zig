const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({ @cInclude("highlight.h"); });
const grammar_directory = ".deps/install/" ++ @tagName(builtin.os.tag) ++
    "-" ++ @tagName(builtin.cpu.arch) ++ "/lib";
const budget = 8 * 1024 * 1024;

fn parse(source: []const u8, language: [:0]const u8) !*c.SpicaHighlight {
    var job: ?*c.SpicaHighlight = null;
    try std.testing.expectEqual(@as(c_uint, c.SPICA_HIGHLIGHT_OK),
        c.spica_highlight_parse(source.ptr, source.len, language, grammar_directory, budget, &job));
    return job orelse error.MissingHighlight;
}

fn expectToken(job: *c.SpicaHighlight, source: []const u8, text: []const u8, expected: c_uint) !void {
    const start = std.mem.indexOf(u8, source, text) orelse return error.MissingFixtureToken;
    const spans = c.spica_highlight_spans(job)[0..c.spica_highlight_span_count(job)];
    for (spans) |span| {
        if (span.byte_start <= start and span.byte_end >= start + text.len) {
            try std.testing.expectEqual(expected, span.token_class);
            return;
        }
    }
    return error.TokenNotHighlighted;
}

fn expectUncolored(job: *c.SpicaHighlight, source: []const u8, text: []const u8) !void {
    const start = std.mem.indexOf(u8, source, text) orelse return error.MissingFixtureToken;
    const spans = c.spica_highlight_spans(job)[0..c.spica_highlight_span_count(job)];
    for (spans) |span| {
        try std.testing.expect(span.byte_end <= start or span.byte_start >= start + text.len);
    }
}

fn expectOrdered(job: *c.SpicaHighlight, source_length: usize) !void {
    var previous: usize = 0;
    for (c.spica_highlight_spans(job)[0..c.spica_highlight_span_count(job)]) |span| {
        try std.testing.expect(previous <= span.byte_start);
        try std.testing.expect(span.byte_start < span.byte_end);
        try std.testing.expect(span.byte_end <= source_length);
        previous = span.byte_end;
    }
    try std.testing.expect(c.spica_highlight_arena_used(job) <= budget);
}

test "Zig structural tokens preserve Unicode byte offsets and do not color uppercase names by regex" {
    const source = "// 雪: fn pretend()\nconst LOUD = \"héllo\";\nfn greet(value: u32) u32 { return value + 7; }\nconst _ = LOUD;\n";
    const job = try parse(source, "zig");
    defer c.spica_highlight_release(job);
    try expectToken(job, source, "fn pretend", c.SPICA_TOKEN_COMMENT);
    try expectToken(job, source, "\"héllo\"", c.SPICA_TOKEN_STRING);
    try expectToken(job, source, "greet", c.SPICA_TOKEN_FUNCTION);
    try expectToken(job, source, "u32", c.SPICA_TOKEN_TYPE);
    try expectToken(job, source, "return", c.SPICA_TOKEN_KEYWORD);
    try expectToken(job, source, "7", c.SPICA_TOKEN_NUMBER);
    try expectToken(job, source, "_", c.SPICA_TOKEN_CONSTANT);
    try expectUncolored(job, source, "LOUD");
    try expectOrdered(job, source.len);
}

test "Python scanner and structural queries highlight definitions strings and literal predicates" {
    const source = "# 東京 def pretend\ndef greet(name: str):\n    LOUD = f\"héllo {name}\"\n    return len(name) + 42\nif __name__ == \"__main__\":\n    greet(\"world\")\nordinary = 0\nwidget.update()\n";
    const job = try parse(source, "py");
    defer c.spica_highlight_release(job);
    try expectToken(job, source, "def pretend", c.SPICA_TOKEN_COMMENT);
    try expectToken(job, source, "greet", c.SPICA_TOKEN_FUNCTION);
    try expectToken(job, source, "str", c.SPICA_TOKEN_TYPE);
    try expectToken(job, source, "héllo", c.SPICA_TOKEN_STRING);
    try expectToken(job, source, "return", c.SPICA_TOKEN_KEYWORD);
    try expectToken(job, source, "len", c.SPICA_TOKEN_FUNCTION);
    try expectToken(job, source, "42", c.SPICA_TOKEN_NUMBER);
    try expectToken(job, source, "__name__", c.SPICA_TOKEN_CONSTANT);
    try expectToken(job, source, "update", c.SPICA_TOKEN_FUNCTION);
    try expectUncolored(job, source, "LOUD");
    try expectUncolored(job, source, "ordinary");
    try expectOrdered(job, source.len);
}

test "JSON property precedence and JavaScript grammar aliases remain independent" {
    const json = "{\"雪\": \"value\", \"enabled\": true, \"count\": 12}";
    const json_job = try parse(json, "JSON");
    defer c.spica_highlight_release(json_job);
    try expectToken(json_job, json, "\"雪\"", c.SPICA_TOKEN_PROPERTY);
    try expectToken(json_job, json, "\"value\"", c.SPICA_TOKEN_STRING);
    try expectToken(json_job, json, "true", c.SPICA_TOKEN_CONSTANT);
    try expectOrdered(json_job, json.len);
    const js = "const text = '雪'; function greet() { return 12; } widget.update();";
    const js_job = try parse(js, "js");
    defer c.spica_highlight_release(js_job);
    try expectToken(js_job, js, "const", c.SPICA_TOKEN_KEYWORD);
    try expectToken(js_job, js, "'雪'", c.SPICA_TOKEN_STRING);
    try expectToken(js_job, js, "greet", c.SPICA_TOKEN_FUNCTION);
    try expectToken(js_job, js, "update", c.SPICA_TOKEN_FUNCTION);
    try expectOrdered(js_job, js.len);
}

test "arena and capture exhaustion preserve source and do not poison following scanner job" {
    const source = "def greet():\n    return 'unchanged'\n";
    var job: ?*c.SpicaHighlight = null;
    // Borrowing avoids a source copy, but still charges its bytes to the cap.
    try std.testing.expectEqual(@as(c_uint, c.SPICA_HIGHLIGHT_BUDGET_EXCEEDED),
        c.spica_highlight_parse(source, source.len, "python", "/absent/grammars", source.len, &job));
    try std.testing.expect(job == null);
    try std.testing.expectEqual(@as(c_uint, c.SPICA_HIGHLIGHT_BUDGET_EXCEEDED),
        c.spica_highlight_parse(source, source.len, "python", grammar_directory, 128, &job));
    try std.testing.expect(job == null);
    // This input has over 16K captures and a large real syntax tree. Exhaustion
    // must fail the whole job, not return silently truncated token colors.
    const hostile = try std.testing.allocator.alloc(u8, 480 * 1024);
    defer std.testing.allocator.free(hostile);
    const line = "const x = 1;\n";
    var offset: usize = 0;
    while (offset + line.len <= hostile.len) : (offset += line.len)
        @memcpy(hostile[offset..][0..line.len], line);
    @memset(hostile[offset..], ' ');
    try std.testing.expectEqual(@as(c_uint, c.SPICA_HIGHLIGHT_BUDGET_EXCEEDED),
        c.spica_highlight_parse(hostile.ptr, hostile.len, "zig", grammar_directory, budget, &job));
    try std.testing.expect(job == null);
    try std.testing.expectEqualStrings("const x = 1;\n", hostile[0..line.len]);
    const recovered = try parse(source, "python");
    defer c.spica_highlight_release(recovered);
    try expectToken(recovered, source, "greet", c.SPICA_TOKEN_FUNCTION);
    try expectToken(recovered, source, "'unchanged'", c.SPICA_TOKEN_STRING);
}

test "unsupported language is uncolored without loading an arbitrary grammar" {
    const source = "fn readable() { return 1; }";
    var job: ?*c.SpicaHighlight = null;
    try std.testing.expectEqual(@as(c_uint, c.SPICA_HIGHLIGHT_UNSUPPORTED),
        c.spica_highlight_parse(source, source.len, "rust", "/absent/grammars", budget, &job));
    try std.testing.expect(job == null);
}
