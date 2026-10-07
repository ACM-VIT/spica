const std = @import("std");
const md = @import("markdown.zig");

const source_id: md.ContentId = [_]u8{0xA5} ** 16;

test "clipboard projection preserves readable Markdown and list semantics" {
    const source = "# Résumé 👩‍💻\n\n**bold** and *soft* [label](https://example.test)\n\n3. parent\n   - [x] done\n   - [ ] pending\n4. next\n\n| Name | Value |\n|---|---|\n| café | 42 |\n\n```zig\nconst x = \"**literal**\";\n```\n\n> quote\n\n![alt](image.png)\n";
    var doc = try md.parse(std.testing.allocator, source_id, source);
    defer doc.deinit();
    const bytes = try doc.clipboardText(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("Résumé 👩‍💻\nbold and soft label\n3. parent\n  • [x] done\n  • [ ] pending\n4. next\nName\tValue\ncafé\t42\nconst x = \"**literal**\";\nquote\nalt\n", bytes);
    try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len]);
}

test "clipboard projection copies beyond composer capacity and rejects unavailable formatting" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 90_000);
    defer allocator.free(source);
    @memset(source, 'a');
    var doc = try md.parse(allocator, source_id, source);
    defer doc.deinit();
    const bytes = try doc.clipboardText(allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 90_001), bytes.len);
    try std.testing.expectEqualSlices(u8, source, bytes[0..source.len]);
    var unavailable = try md.parse(allocator, source_id, "before\x00after");
    defer unavailable.deinit();
    try std.testing.expectError(error.FormattingUnavailable, unavailable.clipboardText(allocator));
}

test "clipboard projection indents multiline list blocks without removing code spaces" {
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{
            .source = "- parent\n  - child\n    continued\n",
            .expected = "• parent\n  • child\n    continued\n",
        },
        .{
            .source = "3. parent\n   continued  \n   hard break\n\n   - child\n     continued\n\n     another paragraph\n\n     ```zig\n     if (ok) {\n       work();\n     }\n     ```\n\n   back to parent\n4. next\n\n```zig\n  outside();\n```\n",
            .expected = "3. parent\n  continued\n  hard break\n  • child\n    continued\n    another paragraph\n    if (ok) {\n      work();\n    }\n  back to parent\n4. next\n  outside();\n",
        },
    };
    for (cases) |case| {
        var doc = try md.parse(std.testing.allocator, source_id, case.source);
        defer doc.deinit();
        const bytes = try doc.clipboardText(std.testing.allocator);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(case.expected, bytes);
    }
}

fn blockOf(doc: *const md.Document, kind: md.BlockKind) ?md.Block {
    for (doc.blocks.items) |block| if (block.kind == kind) return block;
    return null;
}

fn runOf(doc: *const md.Document, kind: md.RunKind) ?md.Run {
    for (doc.runs.items) |run| if (run.kind == kind) return run;
    return null;
}

fn target(doc: *const md.Document, run: md.Run) []const u8 {
    return doc.metadata.items[run.target.start..][0..run.target.len];
}

test "GFM structure, nested numbering and inline styling survive the projection" {
    const source = "# Heading\n\n1. parent\n   - [x] done\n   - [ ] pending\n\n| L | R |\n|:--|--:|\n| ~~gone~~ | **bold** and *soft* |\n\n> quote\n\n```zig\nconst x = 1;\n```\n";
    var doc = try md.parse(std.testing.allocator, source_id, source);
    defer doc.deinit();
    try std.testing.expectEqual(md.State.rich, doc.state);
    const heading = blockOf(&doc, .heading) orelse return error.MissingHeading;
    try std.testing.expectEqual(@as(u8, 1), heading.heading_level);
    const list = blockOf(&doc, .list) orelse return error.MissingList;
    try std.testing.expect(list.ordered);
    try std.testing.expectEqual(@as(i32, 1), list.number);
    var checked = false;
    var unchecked = false;
    var nested = false;
    var numbered = false;
    for (doc.blocks.items) |block| {
        if (block.kind == .list and block.parent != null) nested = true;
        if (block.task == .checked) checked = true;
        if (block.task == .unchecked) unchecked = true;
        if (block.kind == .item and block.parent != null and doc.blocks.items[block.parent.?].ordered and block.number == 1) numbered = true;
    }
    try std.testing.expect(nested and checked and unchecked and numbered);
    const table = blockOf(&doc, .table) orelse return error.MissingTable;
    try std.testing.expectEqual(@as(u16, 2), table.columns);
    var left = false;
    var right = false;
    var header = false;
    for (doc.blocks.items) |block| {
        if (block.kind == .table_cell and block.alignment == .left) left = true;
        if (block.kind == .table_cell and block.alignment == .right) right = true;
        if (block.kind == .table_row and block.header) header = true;
    }
    try std.testing.expect(left and right and header);
    try std.testing.expect(blockOf(&doc, .quote) != null);
    const code = blockOf(&doc, .code) orelse return error.MissingCode;
    try std.testing.expectEqualStrings("zig", doc.metadata.items[code.info.start..][0..code.info.len]);
    try std.testing.expect(runOf(&doc, .code) != null);
    var strike = false;
    var strong = false;
    var emphasis = false;
    for (doc.runs.items) |run| {
        strike = strike or run.strike;
        strong = strong or run.strong;
        emphasis = emphasis or run.emphasis;
        try std.testing.expect(run.start <= run.end and run.end <= doc.text.items.len);
    }
    try std.testing.expect(strike and strong and emphasis);
}

test "HTML is literal, links need explicit activation, and images never fetch" {
    const source = "<script>alert('x')</script>\n\nRaw <b>label</b> [safe](https://example.test/) [local](file:///tmp/secret) [bad](javascript:alert) ![alt](https://example.test/a.png)\n";
    var doc = try md.parse(std.testing.allocator, source_id, source);
    defer doc.deinit();
    try std.testing.expectEqual(md.State.rich, doc.state);
    try std.testing.expect(blockOf(&doc, .html) != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.text.items, "<script>") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.text.items, "<b>label</b>") != null);
    var open = false;
    var confirm = false;
    var blocked_link = false;
    var blocked_image = false;
    for (doc.runs.items) |run| {
        const url = target(&doc, run);
        if (run.policy == .open_link and std.mem.eql(u8, url, "https://example.test/")) open = true;
        if (run.policy == .confirm_local_file and std.mem.eql(u8, url, "file:///tmp/secret")) confirm = true;
        if (run.policy == .blocked and std.mem.startsWith(u8, url, "javascript:")) blocked_link = true;
        if (run.kind == .image and run.policy == .blocked and std.mem.eql(u8, url, "https://example.test/a.png")) blocked_image = true;
    }
    try std.testing.expect(open and confirm and blocked_link and blocked_image);
}

test "display budget retains original content identity and next rich job succeeds" {
    const huge = try std.testing.allocator.alloc(u8, md.max_source_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'a');
    var oversized = try md.parse(std.testing.allocator, source_id, huge);
    defer oversized.deinit();
    try std.testing.expectEqual(md.State.display_budget, oversized.state);
    try std.testing.expectEqual(source_id, oversized.source_id);
    try std.testing.expectEqual(@as(u64, md.max_source_bytes + 1), oversized.source_length);
    try std.testing.expectEqual(@as(usize, 0), oversized.text.items.len);
    var invalid = try md.parse(std.testing.allocator, source_id, "before\x00after");
    defer invalid.deinit();
    try std.testing.expectEqual(md.State.display_budget, invalid.state);
    var ordinary = try md.parse(std.testing.allocator, source_id, "# healthy\n\nbody\n");
    defer ordinary.deinit();
    try std.testing.expectEqual(md.State.rich, ordinary.state);
    try std.testing.expect(blockOf(&ordinary, .heading) != null);
}

test "bounded C parse failure releases its tree before the next job" {
    const repeated = try std.testing.allocator.alloc(u8, 4 * 180_000);
    defer std.testing.allocator.free(repeated);
    for (0..180_000) |index| @memcpy(repeated[index * 4 ..][0..4], "- x\n");
    var exhausted = try md.parse(std.testing.allocator, source_id, repeated);
    defer exhausted.deinit();
    try std.testing.expectEqual(md.State.display_budget, exhausted.state);
    try std.testing.expectEqual(source_id, exhausted.source_id);
    try std.testing.expectEqual(@as(usize, 0), exhausted.blocks.items.len);
    var recovered = try md.parse(std.testing.allocator, source_id, "| a | b |\n|---|---|\n| c | d |\n");
    defer recovered.deinit();
    try std.testing.expectEqual(md.State.rich, recovered.state);
    try std.testing.expect(blockOf(&recovered, .table) != null);
}

test "serialization carries source identity separately from rendered text" {
    var doc = try md.parse(std.testing.allocator, source_id, "**bold**\n");
    defer doc.deinit();
    try std.testing.expectEqualStrings("bold\n", doc.text.items);
    try std.testing.expect(doc.runs.items[0].strong);
    const Sink = struct {
        data: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,
        pub fn write(self: *@This(), bytes: []const u8) !void {
            try self.data.appendSlice(self.allocator, bytes);
        }
    };
    var sink: Sink = .{ .allocator = std.testing.allocator };
    defer sink.data.deinit(std.testing.allocator);
    try doc.serialize(&sink);
    try std.testing.expectEqualStrings("SPMD", sink.data.items[0..4]);
    try std.testing.expectEqualSlices(u8, &source_id, sink.data.items[8..24]);
    try std.testing.expectEqualSlices(u8, doc.text.items, sink.data.items[sink.data.items.len - doc.text.items.len ..]);
}
