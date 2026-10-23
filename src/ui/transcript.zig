const std = @import("std");
const domain = @import("../domain/types.zig");

pub const metadata_page_bytes = 64 * 1024;
pub const metadata_page_rows = 32;
pub const metadata_page_count = 3;
pub const content_page_bytes = 16 * 1024;
pub const content_page_count = 8;
pub const id_bytes = 256;

pub const Id = struct {
    bytes: [id_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn init(value: []const u8) !Id {
        if (value.len == 0 or value.len > id_bytes) return error.InvalidId;
        var result: Id = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Id, value: []const u8) bool {
        return std.mem.eql(u8, self.slice(), value);
    }
};

/// IDs and logical byte offsets survive cache eviction/reflow. No global y/index.
pub const Anchor = struct {
    message: Id,
    block: ?Id = null,
    byte_offset: u64 = 0,
    pixel_offset: f32 = 0,
};

pub const Selection = struct {
    block: Id,
    revision: domain.Revision,
    projection: enum { source, rendered },
    anchor: u64,
    caret: u64,
};

const Metadata = struct {
    storage: []u8,
    page: ?domain.QueryPage = null,
    used: u64 = 0,
};

pub const Content = struct {
    block: Id = .{},
    revision: domain.Revision = 0,
    start: u64 = 0,
    len: usize = 0,
    next_byte: ?u64 = null,
    used: u64 = 0,
    valid: bool = false,
    bytes: [content_page_bytes]u8 = undefined,

    pub fn source(self: *const Content) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Storage = struct {
    metadata: [metadata_page_count + 1][metadata_page_bytes]u8,
    content: [content_page_count]Content,
};

/// A view-local bounded neighborhood, never canonical history or domain state.
/// All admitted slices are copied before Host.drain storage can be reused.
pub const Transcript = struct {
    allocator: std.mem.Allocator,
    storage: *Storage,
    pages: [metadata_page_count]Metadata,
    staging: []u8,
    snapshot: ?domain.SnapshotId = null,
    snapshot_position: domain.EventPosition = .{},
    applied_position: domain.EventPosition = .{},
    clock: u64 = 0,
    generation: u64 = 1,
    anchor: ?Anchor = null,
    selection: ?Selection = null,
    following: bool = true,
    refresh_required: bool = false,
    newer_output: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Transcript {
        const storage = try allocator.create(Storage);
        storage.content = [_]Content{.{}} ** content_page_count;
        var pages: [metadata_page_count]Metadata = undefined;
        for (&pages, 0..) |*page, index| page.* = .{ .storage = &storage.metadata[index] };
        return .{ .allocator = allocator, .storage = storage, .pages = pages, .staging = &storage.metadata[metadata_page_count] };
    }

    pub fn deinit(self: *Transcript) void {
        self.allocator.destroy(self.storage);
        self.* = undefined;
    }

    pub fn reset(self: *Transcript) void {
        for (&self.pages) |*page| page.page = null;
        for (&self.storage.content) |*page| page.valid = false;
        self.snapshot = null;
        self.snapshot_position = .{};
        self.applied_position = .{};
        self.selection = null;
        self.refresh_required = false;
        self.generation +%= 1;
        // Keep stable scroll anchor across refresh; do not silently jump latest.
    }

    /// New snapshot is explicit. Later pages must use exactly this snapshot.
    pub fn begin(self: *Transcript, page: domain.QueryPage) !void {
        // Stage first: malformed/over-budget output must not destroy old view.
        const owned = try self.stage(page);
        self.reset();
        self.snapshot = page.snapshot_id;
        self.snapshot_position = page.snapshot_position;
        self.applied_position = page.snapshot_position;
        self.publish(0, owned);
    }

    pub fn addPage(self: *Transcript, page: domain.QueryPage) !void {
        const snapshot = self.snapshot orelse return error.NoSnapshot;
        if (!std.meta.eql(snapshot, page.snapshot_id) or domain.EventPosition.order(self.snapshot_position, page.snapshot_position) != .eq) return error.MixedSnapshot;
        const owned = try self.stage(page);
        var replacement: usize = 0;
        for (self.pages, 0..) |slot, index| {
            if (slot.page == null) {
                replacement = index;
                break;
            }
            if (slot.used < self.pages[replacement].used) replacement = index;
        }
        self.publish(replacement, owned);
    }

    fn stage(self: *Transcript, page: domain.QueryPage) !domain.QueryPage {
        if (page.items.len > metadata_page_rows) return error.PageRows;
        var previous: ?u64 = null;
        var direction: ?std.math.Order = null;
        for (page.items) |row| switch (row) {
            .message => |message| {
                _ = try Id.init(message.message_id.value);
                if (previous) |ordinal| {
                    const order = std.math.order(message.ordinal, ordinal);
                    if (order == .eq) return error.MessageOrder;
                    if (direction) |expected| {
                        if (order != expected) return error.MessageOrder;
                    } else direction = order;
                }
                previous = message.ordinal;
                for (message.blocks) |block| _ = try Id.init(block.block_id.value);
            },
            else => return error.NotMetadata,
        };
        var fixed = std.heap.FixedBufferAllocator.init(self.staging);
        return copyValue(domain.QueryPage, fixed.allocator(), page);
    }

    fn publish(self: *Transcript, index: usize, page: domain.QueryPage) void {
        const old = self.pages[index].storage;
        self.clock += 1;
        self.pages[index] = .{ .storage = self.staging, .page = page, .used = self.clock };
        self.staging = old;
    }

    pub fn rowCount(self: *const Transcript) usize {
        var total: usize = 0;
        for (self.pages) |slot| if (slot.page) |page| {
            total += page.items.len;
        };
        return total;
    }

    /// Exact bytes, including NUL and incomplete UTF-8, are presentation input.
    /// Decoding and grapheme/paragraph boundaries are a separate visible step.
    pub fn putContent(self: *Transcript, row: domain.Row) !void {
        const value = switch (row) {
            .content => |value| value,
            else => return error.NotContent,
        };
        const block = try Id.init(value.block_id.value);
        if (value.bytes.len > content_page_bytes or value.end_byte < value.start_byte or value.end_byte - value.start_byte != value.bytes.len) return error.ContentRange;
        if (value.next_byte) |next| if (next != value.end_byte) return error.ContentRange;
        var replacement: usize = 0;
        for (self.storage.content, 0..) |slot, index| {
            if (slot.valid and slot.block.eql(value.block_id.value) and slot.revision == value.revision and slot.start == value.start_byte) {
                if (!std.mem.eql(u8, slot.source(), value.bytes)) return error.ContentConflict;
                return;
            }
            if (!slot.valid or slot.used < self.storage.content[replacement].used) replacement = index;
        }
        const slot = &self.storage.content[replacement];
        self.clock += 1;
        slot.* = .{ .block = block, .revision = value.revision, .start = value.start_byte, .len = value.bytes.len, .next_byte = value.next_byte, .used = self.clock, .valid = true };
        @memcpy(slot.bytes[0..value.bytes.len], value.bytes);
    }

    pub fn content(self: *Transcript, block: []const u8, revision: domain.Revision, start: u64) ?*const Content {
        for (&self.storage.content) |*slot| {
            if (slot.valid and slot.revision == revision and slot.start == start and slot.block.eql(block)) {
                self.clock += 1;
                slot.used = self.clock;
                return slot;
            }
        }
        return null;
    }

    /// Every unseen position matters, even when aggregate revisions are equal.
    /// Until typed reducer payloads land, invalidate only the bounded neighborhood.
    pub fn events(self: *Transcript, values: []const domain.Event, end_position: domain.EventPosition) !void {
        if (domain.EventPosition.order(end_position, self.applied_position) != .gt) return;
        var position = self.applied_position;
        var unseen = false;
        for (values) |event| {
            if (domain.EventPosition.order(event.position, position) != .gt) continue;
            if (domain.EventPosition.order(event.position, end_position) == .gt) return error.EventPosition;
            position = event.position;
            unseen = true;
        }
        if (domain.EventPosition.order(end_position, position) != .eq) return error.EventPosition;
        if (unseen) {
            self.applied_position = position;
            self.refresh_required = true;
            self.newer_output = !self.following;
            self.selection = null;
            for (&self.storage.content) |*slot| slot.valid = false;
        }
    }

    pub fn scrollAnchor(self: *Transcript, anchor: Anchor) void {
        self.anchor = anchor;
        self.following = false;
    }

    pub fn followLatest(self: *Transcript) void {
        self.following = true;
        self.newer_output = false;
        self.anchor = null;
    }
};

const native = @import("../native/bindings.zig").c;
const presentation = @import("../content/presentation.zig");
const widgets = @import("widgets.zig");

/// One retained visible semantic block. Its immutable native geometry and
/// rendered-byte selection are never confused with canonical source offsets.
/// The root keeps only its finite visible neighborhood, releasing on eviction.
pub const RichTile = struct {
    key: ?presentation.Key = null,
    block_index: u32 = 0,
    start_byte: u32 = 0,
    projection_start: u32 = 0,
    message: Id = .{},
    canonical_block: Id = .{},
    canonical_ordinal: u64 = 0,
    layout: ?*native.SpicaTextLayout = null,
    width: f32 = 0,
    length: usize = 0,
    rendered: [presentation.tile_bytes]u8 = undefined,
    code: bool = false,
    bounds: native.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    anchor: usize = 0,
    caret: usize = 0,
    selected: bool = false,
    colors: [presentation.tile_runs]native.SpicaTextColorSpan = undefined,
    color_count: usize = 0,
    styles: [presentation.tile_runs]native.SpicaTextSpan = undefined,
    size: c_uint = 16,

    pub fn deinit(self: *RichTile) void {
        if (self.layout) |layout| native.spica_text_layout_release(layout);
        self.* = .{};
    }

    /// Transactional reflow: preserve the last valid geometry on rejection.
    pub fn update(self: *RichTile, text: *native.SpicaText, tile: *const presentation.Tile, width: f32) !void {
        if (tile.state != .rich) return error.DisplayBudget;
        if (width <= 24 or !std.math.isFinite(width)) return error.InvalidWidth;
        if (self.key) |key| {
            if (std.meta.eql(key, tile.key) and self.block_index == tile.block.index and self.start_byte == tile.start_byte and self.width == width) return;
        }
        var spans: [presentation.tile_runs]native.SpicaTextSpan = undefined;
        var colors: [presentation.tile_runs]native.SpicaTextColorSpan = undefined;
        var count: usize = 0;
        var end: usize = 0;
        for (tile.spans[0..tile.span_count]) |span| {
            if (span.start < end or span.start >= span.end or span.end > tile.len) return error.InvalidSpans;
            end = span.end;
            const style: c_uint = (if (span.flags & 1 != 0) @as(c_uint, native.SPICA_TEXT_ITALIC) else 0) |
                (if (span.flags & 2 != 0) @as(c_uint, native.SPICA_TEXT_BOLD) else 0) |
                (if (span.kind == .code) @as(c_uint, native.SPICA_TEXT_MONOSPACE) else 0);
            spans[count] = .{ .byte_start = span.start, .byte_end = span.end, .style = style };
            colors[count] = .{ .byte_start = span.start, .byte_end = span.end, .rgba = if (span.kind == .code) 0xAAD9C0FF else 0xE7EBF2FF };
            count += 1;
        }
        const code = tile.block.kind == .code;
        const size: c_uint = if (tile.block.kind == .heading) switch (tile.block.heading) {
            1 => 24,
            2 => 21,
            else => 18,
        } else 16;
        const layout = native.spica_text_layout_create_spans(text, tile.text[0..tile.len].ptr, tile.len, width - 24, size, code, &spans, count) orelse return error.TranscriptLayout;
        self.deinit();
        self.key = tile.key;
        self.block_index = tile.block.index;
        self.start_byte = tile.start_byte;
        self.projection_start = tile.block.start;
        self.layout = layout;
        self.width = width;
        self.length = tile.len;
        @memcpy(self.rendered[0..tile.len], tile.bytes());
        self.code = code;
        @memcpy(self.colors[0..count], colors[0..count]);
        self.color_count = count;
        @memcpy(self.styles[0..count], spans[0..count]);
        self.size = size;
    }

    pub fn reflow(self: *RichTile, text: *native.SpicaText, width: f32) !void {
        if (self.layout == null or self.width == width) return;
        if (width <= 24 or !std.math.isFinite(width)) return error.InvalidWidth;
        const layout = native.spica_text_layout_create_spans(text, self.rendered[0..self.length].ptr, self.length, width - 24, self.size, self.code, &self.styles, self.color_count) orelse return error.TranscriptLayout;
        native.spica_text_layout_release(self.layout.?);
        self.layout = layout;
        self.width = width;
    }

    pub const ScrollPoint = struct { byte: usize, offset: f32 };

    pub fn capture(self: *const RichTile, y: f32) ScrollPoint {
        const layout = self.layout orelse return .{ .byte = 0, .offset = y };
        const byte = native.spica_text_layout_hit_test(layout, 0, @max(0, y - 10));
        var rect: native.SDL_FRect = undefined;
        if (!native.spica_text_layout_caret(layout, byte, &rect)) return .{ .byte = 0, .offset = y };
        return .{ .byte = byte, .offset = y - rect.y - 10 };
    }

    pub fn restore(self: *const RichTile, point: ScrollPoint) f32 {
        var rect: native.SDL_FRect = undefined;
        if (self.layout) |layout| if (native.spica_text_layout_caret(layout, point.byte, &rect)) return rect.y + 10 + point.offset;
        return 0;
    }

    pub fn height(self: *const RichTile) f32 {
        return if (self.layout) |layout| native.spica_text_layout_height(layout) + 20 else 0;
    }

    pub fn selectedBytes(self: *const RichTile) []const u8 {
        if (!self.selected) return "";
        return self.rendered[@min(self.anchor, self.caret)..@max(self.anchor, self.caret)];
    }

    pub fn hit(self: *RichTile, x: f32, y: f32, extend: bool) bool {
        if (!widgets.contains(self.bounds, x, y)) return false;
        const layout = self.layout orelse return false;
        self.caret = native.spica_text_layout_hit_test(layout, x - self.bounds.x - 12, y - self.bounds.y - 10);
        if (!extend) self.anchor = self.caret;
        self.selected = true;
        return true;
    }

    pub fn draw(self: *RichTile, renderer: *native.SDL_Renderer, text: *native.SpicaText, x: f32, y: f32) !void {
        const layout = self.layout orelse return;
        self.bounds = .{ .x = x, .y = y, .w = self.width, .h = self.height() };
        if (self.code) try widgets.panel(renderer, self.bounds, 6, .{ .r = 27, .g = 32, .b = 41 });
        if (self.selected) {
            var rects: [128]native.SDL_FRect = undefined;
            const count = native.spica_text_layout_selection_rects(layout, @min(self.anchor, self.caret), @max(self.anchor, self.caret), &rects, rects.len);
            if (!native.SDL_SetRenderDrawColor(renderer, 64, 84, 125, 255)) return error.SelectionDraw;
            for (rects[0..@min(count, rects.len)]) |rect| {
                const translated = native.SDL_FRect{ .x = x + 12 + rect.x, .y = y + 10 + rect.y, .w = rect.w, .h = rect.h };
                if (!native.SDL_RenderFillRect(renderer, &translated)) return error.SelectionDraw;
            }
        }
        if (!native.spica_text_layout_draw_colors(text, layout, x + 12, y + 10, .{ .r = 231, .g = 235, .b = 242, .a = 255 }, &self.colors, self.color_count)) return error.TranscriptDraw;
    }
};

test "real Markdown tile draws retained native styles and rendered selection" {
    const build_options = @import("build_options");
    const surface = native.SDL_CreateSurface(640, 300, native.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer native.SDL_DestroySurface(surface);
    const renderer = native.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer native.SDL_DestroyRenderer(renderer);
    const text = native.spica_text_create(renderer, build_options.font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer native.spica_text_destroy(text);
    try std.testing.expect(native.spica_text_set_monospace(text, build_options.font_directory ++ "/JetBrainsMono-Regular.ttf"));
    try std.testing.expect(native.spica_text_add_fallback(text, build_options.font_directory ++ "/InterVariable-Italic.ttf", 0));
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "rich", .{ .read = true });
    var projector = try presentation.Projector.init(std.testing.allocator, std.testing.io, file);
    defer projector.deinit();
    const key = presentation.Key{ .source = @splat(7), .revision = 3, .generation = 1 };
    _ = try projector.project(key, "**bold** and *italic* and `code`");
    var tile: presentation.Tile = undefined;
    try projector.tile(key, 0, &tile);
    var retained: RichTile = .{};
    defer retained.deinit();
    try retained.update(text, &tile, 500);
    const original_layout = retained.layout;
    try retained.draw(renderer, text, 20, 30);
    try retained.update(text, &tile, 500);
    try std.testing.expectEqual(original_layout, retained.layout);
    try std.testing.expectEqualStrings("bold and italic and code\n", tile.bytes());
    try std.testing.expect(retained.hit(35, 45, false));
    try std.testing.expect(retained.hit(160, 45, true));
    try std.testing.expect(retained.caret != retained.anchor);
    try retained.draw(renderer, text, 20, 30);
    try std.testing.expect(native.SDL_RenderPresent(renderer));
    try std.testing.expectError(error.InvalidWidth, retained.update(text, &tile, 0));
    try std.testing.expectEqual(original_layout, retained.layout);
    const selected = retained.caret;
    try retained.reflow(text, 260);
    try std.testing.expectEqual(@as(f32, 260), retained.width);
    try std.testing.expectEqual(selected, retained.caret);
    try std.testing.expectEqualStrings("bold and italic and code\n", retained.rendered[0..retained.length]);
    retained.deinit();
    var stats: native.SpicaTextStats = undefined;
    try std.testing.expect(native.spica_text_get_stats(text, &stats));
    try std.testing.expectEqual(@as(c_uint, 0), stats.live_layouts);
}

/// Deep-copy domain values into a fixed page arena. No JSON round trip or hidden
/// borrowed IDs. Only scalar/optional/array/slice/struct/tagged-union values occur.
fn copyValue(comptime T: type, allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| blk: {
            if (pointer.size != .slice) @compileError("domain page contains non-slice pointer");
            const result = try allocator.alloc(pointer.child, value.len);
            for (result, value) |*destination, source| destination.* = try copyValue(pointer.child, allocator, source);
            break :blk result;
        },
        .optional => |optional| if (value) |inner| try copyValue(optional.child, allocator, inner) else null,
        .array => |array| blk: {
            var result: T = undefined;
            for (0..array.len) |index| result[index] = try copyValue(array.child, allocator, value[index]);
            break :blk result;
        },
        .@"struct" => |structure| blk: {
            var result: T = undefined;
            inline for (structure.fields) |field| @field(result, field.name) = try copyValue(field.type, allocator, @field(value, field.name));
            break :blk result;
        },
        .@"union" => |u| blk: {
            inline for (u.fields) |field| {
                if (std.meta.activeTag(value) == @field(u.tag_type.?, field.name)) break :blk @unionInit(T, field.name, try copyValue(field.type, allocator, @field(value, field.name)));
            }
            unreachable;
        },
        else => value,
    };
}

fn makeMessage(ordinal: u64, name: []const u8) domain.Row {
    return .{ .message = .{ .message_id = .{ .value = name }, .revision = 1, .ordinal = ordinal, .role = .assistant, .incomplete = false, .run_id = .{ .value = "run" }, .blocks = &.{} } };
}

fn makePage(rows: []const domain.Row) domain.QueryPage {
    return .{ .snapshot_id = .{ .slot = 0, .generation = 1 }, .snapshot_position = .{ .commit_sequence = 1, .event_index = 2 }, .items = rows, .expires_at = 5000 };
}

test "metadata pages own all drain bytes and stage errors preserve view" {
    var transcript = try Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    var id = [_]u8{'a'};
    const rows = [_]domain.Row{makeMessage(1, &id)};
    try transcript.begin(makePage(&rows));
    id[0] = 'z';
    try std.testing.expectEqualStrings("a", transcript.pages[0].page.?.items[0].message.message_id.value);
    const bad = [_]domain.Row{ makeMessage(1, "b"), makeMessage(1, "a") };
    try std.testing.expectError(error.MessageOrder, transcript.addPage(makePage(&bad)));
    try std.testing.expectEqual(@as(usize, 1), transcript.rowCount());
    var other = makePage(&rows);
    other.snapshot_id.generation = 2;
    try std.testing.expectError(error.MixedSnapshot, transcript.addPage(other));
}

test "history and content retention plateau independent of source length" {
    var transcript = try Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    const rows = [_]domain.Row{makeMessage(1, "a")};
    try transcript.begin(makePage(&rows));
    for (0..1000) |index| {
        try transcript.addPage(makePage(&rows));
        var raw = [_]u8{ 0, 0xf0, 0x9f, @truncate(index) };
        try transcript.putContent(.{ .content = .{ .block_id = .{ .value = "block" }, .revision = 1, .start_byte = index * 4, .end_byte = index * 4 + 4, .next_byte = index * 4 + 4, .bytes = &raw } });
        raw[0] = 1;
    }
    try std.testing.expectEqual(@as(usize, 3), transcript.rowCount());
    try std.testing.expect(transcript.content("block", 1, 0) == null);
    try std.testing.expectEqual(@as(u8, 0), transcript.content("block", 1, 999 * 4).?.source()[0]);
}

test "same revision unseen positions invalidate selection without stealing scroll" {
    var transcript = try Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    const rows = [_]domain.Row{makeMessage(1, "a")};
    try transcript.begin(makePage(&rows));
    transcript.scrollAnchor(.{ .message = try Id.init("a"), .byte_offset = 42 });
    const events = [_]domain.Event{
        .{ .event_id = .{ .value = "e1" }, .position = .{ .commit_sequence = 2, .event_index = 0 }, .aggregate = .{ .thread = .{ .value = "thread" } }, .aggregate_revision = 2, .kind = "ContentAppended", .payload = "" },
        .{ .event_id = .{ .value = "e2" }, .position = .{ .commit_sequence = 2, .event_index = 1 }, .aggregate = .{ .thread = .{ .value = "thread" } }, .aggregate_revision = 2, .kind = "ContentAppended", .payload = "" },
    };
    try transcript.events(events[0..1], events[0].position);
    try transcript.events(events[1..], events[1].position);
    try std.testing.expectEqual(@as(u32, 1), transcript.applied_position.event_index);
    try std.testing.expectEqual(@as(u64, 42), transcript.anchor.?.byte_offset);
    try std.testing.expect(transcript.newer_output);
}

test "visible geometry reflow preserves logical top anchor and selected byte range" {
    const build_options = @import("build_options");
    const surface = native.SDL_CreateSurface(700, 400, native.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer native.SDL_DestroySurface(surface);
    const renderer = native.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer native.SDL_DestroyRenderer(renderer);
    const text = native.spica_text_create(renderer, build_options.font_directory ++ "/Inter.ttf") orelse return error.Font;
    defer native.spica_text_destroy(text);
    var tile: presentation.Tile = .{
        .key = .{ .source = @splat(13), .revision = 2, .generation = 1 },
        .block = .{ .index = 9000, .kind = .paragraph, .start = 0, .end = 0, .first_run = 0, .end_run = 0, .heading = 0, .flags = 0, .number = 0, .columns = 0, .info_start = 0, .info_len = 0 },
        .state = .rich,
        .start_byte = 400000,
    };
    const line = "anchor survives narrow reflow and distant history jumps\n";
    for (0..30) |index| @memcpy(tile.text[index * line.len ..][0..line.len], line);
    tile.len = line.len * 30;
    var retained: RichTile = .{};
    defer retained.deinit();
    try retained.update(text, &tile, 600);
    retained.selected = true;
    retained.anchor = line.len;
    retained.caret = line.len * 2;
    const point = retained.capture(120);
    try retained.reflow(text, 260);
    const restored = retained.restore(point);
    const recaptured = retained.capture(restored);
    try std.testing.expectEqual(point.byte, recaptured.byte);
    try std.testing.expectApproxEqAbs(point.offset, recaptured.offset, 0.01);
    try std.testing.expectEqualStrings(line, retained.selectedBytes());
    try std.testing.expectEqual(@as(u32, 400000), retained.start_byte);
}
