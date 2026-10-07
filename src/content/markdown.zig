const std = @import("std");
const c = @cImport({
    @cInclude("markdown.h");
    @cInclude("cmark-gfm-core-extensions.h");
});

pub const ContentId = [16]u8;
pub const max_source_bytes: usize = 1024 * 1024;
pub const parse_arena_bytes: usize = 8 * 1024 * 1024;
const max_text_bytes: usize = 2 * 1024 * 1024;
const max_metadata_bytes: usize = 1024 * 1024;
const max_blocks: usize = 8192;
const max_runs: usize = 16384;
const max_depth: usize = 64;

pub const State = enum(u8) { rich, display_budget };
pub const BlockKind = enum(u8) {
    paragraph,
    heading,
    quote,
    list,
    item,
    code,
    html,
    rule,
    table,
    table_row,
    table_cell,
};
pub const RunKind = enum(u8) { text, code, html, image, line_break };
pub const TargetPolicy = enum(u8) { none, open_link, confirm_local_file, blocked };
pub const Alignment = enum(u8) { default, left, center, right };

pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const Block = struct {
    kind: BlockKind,
    parent: ?u32,
    text_start: u32,
    text_end: u32,
    first_run: u32,
    end_run: u32,
    heading_level: u8 = 0,
    ordered: bool = false,
    tight: bool = false,
    number: i32 = 0,
    task: enum(u8) { none, unchecked, checked } = .none,
    columns: u16 = 0,
    header: bool = false,
    paren_delimiter: bool = false,
    alignment: Alignment = .default,
    info: Range = .{}, // code fence info, in metadata
};
pub const Run = struct {
    kind: RunKind,
    start: u32, // UTF-8 byte offsets into rendered text, never source offsets
    end: u32,
    emphasis: bool = false,
    strong: bool = false,
    strike: bool = false,
    target: Range = .{}, // inert metadata, never fetched or navigated by this module
    policy: TargetPolicy = .none,
};

/// `source_id` refers to disk-backed Markdown, never to `text`. `text` is the
/// distinct rendered plain-text projection. Only a content worker owns this
/// result; UI state should retain a disk reference and paged derived records,
/// not this entire document. All slices are invalid after deinit.
pub const Document = struct {
    allocator: std.mem.Allocator,
    source_id: ContentId,
    source_length: u64,
    state: State = .rich,
    blocks: std.ArrayList(Block) = .empty,
    runs: std.ArrayList(Run) = .empty,
    text: std.ArrayList(u8) = .empty,
    metadata: std.ArrayList(u8) = .empty,

    /// Copy the readable projection, including list markers drawn separately by
    /// the UI. Source Markdown and inert metadata never enter the clipboard.
    pub fn clipboardText(self: *const Document, allocator: std.mem.Allocator) ![:0]u8 {
        if (self.state != .rich) return error.FormattingUnavailable;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var offset: usize = 0;
        for (self.blocks.items) |block| {
            switch (block.kind) {
                .item, .paragraph, .heading, .code, .html, .rule, .table_row => {},
                else => continue,
            }
            try result.appendSlice(allocator, self.text.items[offset..block.text_start]);
            var indent: usize = 0;
            var parent = block.parent;
            while (parent) |index| {
                const ancestor = self.blocks.items[index];
                if (ancestor.kind == .item) indent += 2;
                parent = ancestor.parent;
            }
            if (block.kind != .item) {
                // Each child block keeps its list depth, including continuation
                // lines. Prefix the projection without touching code's own spaces.
                var start: usize = block.text_start;
                while (start < block.text_end) {
                    if (result.items.len == 0 or result.items[result.items.len - 1] == '\n')
                        try result.appendNTimes(allocator, ' ', indent);
                    const end = if (std.mem.indexOfScalarPos(u8, self.text.items[0..block.text_end], start, '\n')) |newline| newline + 1 else block.text_end;
                    try result.appendSlice(allocator, self.text.items[start..end]);
                    start = end;
                }
                offset = block.text_end;
                continue;
            }
            if (result.items.len != 0 and result.items[result.items.len - 1] != '\n') try result.append(allocator, '\n');
            try result.appendNTimes(allocator, ' ', indent);
            const list = self.blocks.items[block.parent.?];
            if (list.ordered) {
                var buffer: [32]u8 = undefined;
                try result.appendSlice(allocator, try std.fmt.bufPrint(&buffer, "{d}{s} ", .{ block.number, if (list.paren_delimiter) ")" else "." }));
            } else try result.appendSlice(allocator, "• ");
            switch (block.task) {
                .checked => try result.appendSlice(allocator, "[x] "),
                .unchecked => try result.appendSlice(allocator, "[ ] "),
                .none => {},
            }
            offset = block.text_start;
        }
        try result.appendSlice(allocator, self.text.items[offset..]);
        return result.toOwnedSliceSentinel(allocator, 0);
    }

    pub fn deinit(self: *Document) void {
        self.blocks.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.* = undefined;
    }

    fn discardRich(self: *Document) void {
        self.blocks.deinit(self.allocator);
        self.runs.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.metadata.deinit(self.allocator);
        self.blocks = .empty;
        self.runs = .empty;
        self.text = .empty;
        self.metadata = .empty;
        self.state = .display_budget;
    }

    /// Stable little-endian v1 stream. The sink receives ephemeral chunks and
    /// must copy/persist them before returning (e.g. into <=64 KiB store chunks).
    /// Header: "SPMD", version u32, source ID, source length u64, state u32,
    /// block/run counts, text/metadata byte counts u32. Each block then has kind u32,
    /// parent i32 (-1=root), text start/end and first/end run u32, heading u32,
    /// flags u32 (ordered/tight/header/task/paren-delimiter bits), number i32, columns u32,
    /// alignment u32, info start/len u32. Each run has kind/start/end u32,
    /// flags u32 (emphasis/strong/strike), policy u32, target start/len u32.
    /// Finally raw rendered text bytes and raw inert metadata bytes.
    pub fn serialize(self: *const Document, sink: anytype) !void {
        try sink.write("SPMD");
        try emitU32(sink, 1);
        try sink.write(&self.source_id);
        try emitU64(sink, self.source_length);
        try emitU32(sink, @intFromEnum(self.state));
        try emitU32(sink, @intCast(self.blocks.items.len));
        try emitU32(sink, @intCast(self.runs.items.len));
        try emitU32(sink, @intCast(self.text.items.len));
        try emitU32(sink, @intCast(self.metadata.items.len));
        for (self.blocks.items) |block| {
            try emitU32(sink, @intFromEnum(block.kind));
            try emitU32(sink, if (block.parent) |parent| parent else std.math.maxInt(u32));
            try emitU32(sink, block.text_start);
            try emitU32(sink, block.text_end);
            try emitU32(sink, block.first_run);
            try emitU32(sink, block.end_run);
            try emitU32(sink, block.heading_level);
            const flags: u32 = @as(u32, @intFromBool(block.ordered)) |
                (@as(u32, @intFromBool(block.tight)) << 1) |
                (@as(u32, @intFromBool(block.header)) << 2) |
                (@as(u32, @intFromEnum(block.task)) << 3) |
                (@as(u32, @intFromBool(block.paren_delimiter)) << 5);
            try emitU32(sink, flags);
            try emitU32(sink, @bitCast(block.number));
            try emitU32(sink, block.columns);
            try emitU32(sink, @intFromEnum(block.alignment));
            try emitU32(sink, block.info.start);
            try emitU32(sink, block.info.len);
        }
        for (self.runs.items) |run| {
            try emitU32(sink, @intFromEnum(run.kind));
            try emitU32(sink, run.start);
            try emitU32(sink, run.end);
            const flags: u32 = @as(u32, @intFromBool(run.emphasis)) |
                (@as(u32, @intFromBool(run.strong)) << 1) |
                (@as(u32, @intFromBool(run.strike)) << 2);
            try emitU32(sink, flags);
            try emitU32(sink, @intFromEnum(run.policy));
            try emitU32(sink, run.target.start);
            try emitU32(sink, run.target.len);
        }
        try emitBytes(sink, self.text.items);
        try emitBytes(sink, self.metadata.items);
    }
};

fn emitBytes(sink: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + 64 * 1024);
        try sink.write(bytes[offset..end]);
        offset = end;
    }
}

fn emitU32(sink: anytype, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try sink.write(&bytes);
}
fn emitU64(sink: anytype, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try sink.write(&bytes);
}

/// Parse and project within one C-only guard. The AST is explicitly released
/// before returning, including when traversal/serialization preparation fails.
/// Allocation failure from the Zig result allocator is propagated; malformed,
/// oversized, or parse-budget content becomes a display-budget document whose
/// complete original remains available through source_id.
pub fn parse(allocator: std.mem.Allocator, source_id: ContentId, source: []const u8) !Document {
    var doc: Document = .{ .allocator = allocator, .source_id = source_id, .source_length = source.len };
    errdefer doc.deinit();
    if (source.len > max_source_bytes or std.mem.indexOfScalar(u8, source, 0) != null) {
        doc.state = .display_budget;
        return doc;
    }
    var job: ?*c.SpicaMarkdown = null;
    const status = c.spica_markdown_parse(source.ptr, source.len, parse_arena_bytes, &job);
    if (status != c.SPICA_RICH_OK) {
        doc.state = .display_budget;
        return doc;
    }
    defer c.spica_markdown_release(job);
    const root = c.spica_markdown_root(job) orelse {
        doc.state = .display_budget;
        return doc;
    };
    const walker: Walker = .{ .doc = &doc };
    walker.children(root, null, .{}, 0) catch |err| switch (err) {
        error.DisplayBudget => doc.discardRich(),
        else => return err,
    };
    return doc;
}

const Style = struct {
    emphasis: bool = false,
    strong: bool = false,
    strike: bool = false,
    image: bool = false,
    target: Range = .{},
    policy: TargetPolicy = .none,
};

const Walker = struct {
    doc: *Document,

    fn children(self: Walker, parent: *c.cmark_node, block_parent: ?u32, style: Style, depth: usize) !void {
        if (depth >= max_depth) return error.DisplayBudget;
        const is_row = eq(parent, "table_row") or eq(parent, "table_header");
        const ordered = c.cmark_node_get_type(parent) == c.CMARK_NODE_LIST and
            c.cmark_node_get_list_type(parent) == c.CMARK_ORDERED_LIST;
        var child = c.cmark_node_first_child(parent);
        var column: usize = 0;
        while (child) |node| : (child = c.cmark_node_next(node)) {
            if (column != 0 and is_row) try self.appendText("\t", .text, .{});
            var alignment: Alignment = .default;
            if (is_row) {
                const table = c.cmark_node_parent(parent);
                const aligns = c.cmark_gfm_extensions_get_table_alignments(table);
                const count = c.cmark_gfm_extensions_get_table_columns(table);
                if (aligns != null and column < count) alignment = switch (aligns[column]) {
                    'l' => .left,
                    'c' => .center,
                    'r' => .right,
                    else => .default,
                };
            }
            const number: i32 = if (ordered)
                std.math.add(i32, c.cmark_node_get_list_start(parent), std.math.cast(i32, column) orelse return error.DisplayBudget) catch return error.DisplayBudget
            else
                0;
            try self.visit(node, block_parent, style, depth + 1, alignment, number);
            column += 1;
        }
    }

    fn visit(self: Walker, node: *c.cmark_node, parent: ?u32, style: Style, depth: usize, alignment: Alignment, item_number: i32) anyerror!void {
        if (depth >= max_depth) return error.DisplayBudget;
        if (blockKind(node)) |kind| {
            if (self.doc.blocks.items.len >= max_blocks) return error.DisplayBudget;
            const index: u32 = @intCast(self.doc.blocks.items.len);
            var block: Block = .{
                .kind = kind,
                .parent = parent,
                .text_start = @intCast(self.doc.text.items.len),
                .text_end = 0,
                .first_run = @intCast(self.doc.runs.items.len),
                .end_run = 0,
            };
            if (kind == .heading) block.heading_level = @intCast(c.cmark_node_get_heading_level(node));
            if (kind == .list) {
                block.ordered = c.cmark_node_get_list_type(node) == c.CMARK_ORDERED_LIST;
                block.tight = c.cmark_node_get_list_tight(node) != 0;
                block.paren_delimiter = c.cmark_node_get_list_delim(node) == c.CMARK_PAREN_DELIM;
                block.number = c.cmark_node_get_list_start(node);
            }
            if (kind == .item) {
                const item_type = std.mem.span(c.cmark_node_get_type_string(node));
                if (std.mem.eql(u8, item_type, "tasklist"))
                    block.task = if (c.cmark_gfm_extensions_get_tasklist_item_checked(node)) .checked else .unchecked;
                block.number = item_number;
            }
            if (kind == .table) block.columns = c.cmark_gfm_extensions_get_table_columns(node);
            if (kind == .table_row) block.header = c.cmark_gfm_extensions_get_table_row_is_header(node) != 0;
            if (kind == .table_cell) block.alignment = alignment;
            if (kind == .code) block.info = try self.addMetadata(borrowed(c.spica_markdown_fence_info(node)));
            try self.doc.blocks.append(self.doc.allocator, block);
            switch (kind) {
                .code => try self.appendText(borrowed(c.spica_markdown_literal(node)), .code, .{}),
                .html => try self.appendText(borrowed(c.spica_markdown_literal(node)), .html, .{}),
                .rule => try self.appendText("―", .text, .{}),
                else => try self.children(node, index, style, depth),
            }
            if (kind == .paragraph or kind == .heading or kind == .code or kind == .html or
                kind == .rule or kind == .table_row)
                try self.lineEnd();
            self.doc.blocks.items[index].text_end = @intCast(self.doc.text.items.len);
            self.doc.blocks.items[index].end_run = @intCast(self.doc.runs.items.len);
            return;
        }
        const name = std.mem.span(c.cmark_node_get_type_string(node));
        if (std.mem.eql(u8, name, "text")) return self.appendText(borrowed(c.spica_markdown_literal(node)), if (style.image) .image else .text, style);
        if (std.mem.eql(u8, name, "code")) return self.appendText(borrowed(c.spica_markdown_literal(node)), .code, style);
        if (std.mem.eql(u8, name, "html_inline")) return self.appendText(borrowed(c.spica_markdown_literal(node)), .html, style);
        if (std.mem.eql(u8, name, "softbreak") or std.mem.eql(u8, name, "linebreak")) return self.appendText("\n", .line_break, style);
        var nested = style;
        if (std.mem.eql(u8, name, "emph")) nested.emphasis = true;
        if (std.mem.eql(u8, name, "strong")) nested.strong = true;
        if (std.mem.eql(u8, name, "strikethrough")) nested.strike = true;
        if (std.mem.eql(u8, name, "link") or std.mem.eql(u8, name, "image")) {
            const image = std.mem.eql(u8, name, "image");
            const target = borrowed(c.spica_markdown_url(node));
            nested.target = try self.addMetadata(target);
            nested.policy = if (image) .blocked else linkPolicy(target);
            nested.image = image;
            if (image and c.cmark_node_first_child(node) == null)
                return self.appendText("[Image]", .image, nested);
        }
        try self.children(node, parent, nested, depth);
    }

    fn lineEnd(self: Walker) !void {
        const text = self.doc.text.items;
        if (text.len == 0 or text[text.len - 1] != '\n') try self.appendText("\n", .line_break, .{});
    }

    fn appendText(self: Walker, bytes: []const u8, kind: RunKind, style: Style) !void {
        if (bytes.len == 0) return;
        if (bytes.len > max_text_bytes - self.doc.text.items.len or self.doc.runs.items.len >= max_runs) return error.DisplayBudget;
        const start: u32 = @intCast(self.doc.text.items.len);
        try self.doc.text.appendSlice(self.doc.allocator, bytes);
        try self.doc.runs.append(self.doc.allocator, .{
            .kind = kind,
            .start = start,
            .end = @intCast(self.doc.text.items.len),
            .emphasis = style.emphasis,
            .strong = style.strong,
            .strike = style.strike,
            .target = style.target,
            .policy = style.policy,
        });
    }

    fn addMetadata(self: Walker, bytes: []const u8) !Range {
        if (bytes.len > max_metadata_bytes - self.doc.metadata.items.len) return error.DisplayBudget;
        const start: u32 = @intCast(self.doc.metadata.items.len);
        try self.doc.metadata.appendSlice(self.doc.allocator, bytes);
        return .{ .start = start, .len = @intCast(bytes.len) };
    }
};

fn eq(node: *c.cmark_node, name: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(c.cmark_node_get_type_string(node)), name);
}
fn borrowed(bytes: c.SpicaMarkdownBytes) []const u8 {
    return if (bytes.length == 0) "" else bytes.data[0..bytes.length];
}
fn blockKind(node: *c.cmark_node) ?BlockKind {
    const name = std.mem.span(c.cmark_node_get_type_string(node));
    const names = [_][]const u8{ "paragraph", "heading", "block_quote", "list", "item", "tasklist", "code_block", "html_block", "thematic_break", "table", "table_row", "table_header", "table_cell" };
    const kinds = [_]BlockKind{ .paragraph, .heading, .quote, .list, .item, .item, .code, .html, .rule, .table, .table_row, .table_row, .table_cell };
    for (names, kinds) |entry, kind| if (std.mem.eql(u8, name, entry)) return kind;
    return null;
}

/// This classifies a target only; consumers still require user activation.
/// No image target is openable or automatically loaded from Markdown.
pub fn linkPolicy(url: []const u8) TargetPolicy {
    if ((std.ascii.startsWithIgnoreCase(url, "https://") and url.len > 8) or
        (std.ascii.startsWithIgnoreCase(url, "http://") and url.len > 7) or
        (std.ascii.startsWithIgnoreCase(url, "mailto:") and url.len > 7)) return .open_link;
    if (std.ascii.startsWithIgnoreCase(url, "file://")) return .confirm_local_file;
    if (url.len == 0 or url[0] == '#' or std.mem.startsWith(u8, url, "//")) return .blocked;
    if (url.len >= 3 and std.ascii.isAlphabetic(url[0]) and url[1] == ':' and
        (url[2] == '/' or url[2] == '\\')) return .confirm_local_file;
    if (std.mem.indexOfScalar(u8, url, ':') != null) return .blocked;
    return .confirm_local_file;
}
