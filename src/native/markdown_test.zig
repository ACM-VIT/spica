const std = @import("std");
const c = @cImport({ @cInclude("markdown.h"); });
extern fn spica_parse_arena_probe() c_int;

test "arena realloc keeps existing bytes" {
    try std.testing.expectEqual(@as(c_int, 1), spica_parse_arena_probe());
}


test "GFM tables and task lists parse; budget exhaustion does not poison next job" {
    const source = "# Title\n\n- [x] done\n\n| A | B |\n|---|---|\n| 1 | 2 |\n";
    var job: ?*c.SpicaMarkdown = null;
    try std.testing.expectEqual(@as(c_uint, c.SPICA_RICH_BUDGET_EXCEEDED),
        c.spica_markdown_parse(source, source.len, 128, &job));
    try std.testing.expect(job == null);
    try std.testing.expectEqual(@as(c_uint, c.SPICA_RICH_OK),
        c.spica_markdown_parse(source, source.len, 8 * 1024 * 1024, &job));
    defer c.spica_markdown_release(job);
    const document = c.spica_markdown_root(job) orelse return error.MissingRoot;
    var heading = false;
    var table = false;
    var list = false;
    var node = c.cmark_node_first_child(document);
    while (node) |current| : (node = c.cmark_node_next(current)) {
        const kind = std.mem.span(c.cmark_node_get_type_string(current));
        if (std.mem.eql(u8, kind, "heading")) heading = true;
        if (std.mem.eql(u8, kind, "table")) table = true;
        if (std.mem.eql(u8, kind, "list")) list = true;
    }
    try std.testing.expect(heading and table and list);
}
