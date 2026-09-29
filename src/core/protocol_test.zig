const std = @import("std");
const protocol = @import("protocol.zig");

const Spool = struct {
    const Record = struct { bytes: []u8, reason: ?u8 };
    allocator: std.mem.Allocator,
    raw: std.array_list.Managed(u8),
    records: std.array_list.Managed(Record),
    cursor: usize = 0,
    largest_append: usize = 0,

    fn init(allocator: std.mem.Allocator) Spool {
        return .{
            .allocator = allocator,
            .raw = std.array_list.Managed(u8).init(allocator),
            .records = std.array_list.Managed(Record).init(allocator),
        };
    }

    fn deinit(self: *Spool) void {
        for (self.records.items) |entry| self.allocator.free(entry.bytes);
        self.records.deinit();
        self.raw.deinit();
    }

    pub fn beginRecord(self: *Spool) !void {
        self.raw.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn appendRecord(self: *Spool, bytes: []const u8) !void {
        self.largest_append = @max(self.largest_append, bytes.len);
        try self.raw.appendSlice(bytes);
    }

    pub fn rewindRecord(self: *Spool) !void {
        self.cursor = 0;
    }

    pub fn readRecordChunk(self: *Spool) !?[]const u8 {
        if (self.cursor == self.raw.items.len) return null;
        const end = @min(self.cursor + 7, self.raw.items.len);
        defer self.cursor = end;
        return self.raw.items[self.cursor..end];
    }

    pub fn onValid(self: *Spool, source: anytype) !void {
        try self.collect(source, null);
    }

    pub fn onQuarantine(self: *Spool, source: anytype, reason: anytype) !void {
        try self.collect(source, @intFromEnum(reason));
    }

    fn collect(self: *Spool, source: anytype, reason: ?u8) !void {
        var copy = std.array_list.Managed(u8).init(self.allocator);
        errdefer copy.deinit();
        while (try source.next()) |chunk| try copy.appendSlice(chunk);
        try std.testing.expectEqual(source.length, @as(u64, @intCast(copy.items.len)));
        const owned = try copy.toOwnedSlice();
        errdefer self.allocator.free(owned);
        try self.records.append(.{ .bytes = owned, .reason = reason });
    }
};

const Framer = protocol.Framer(Spool);

fn checkRecord(spool: *Spool, index: usize, bytes: []const u8, reason: ?Framer.Reason) !void {
    try std.testing.expectEqualStrings(bytes, spool.records.items[index].bytes);
    try std.testing.expectEqual(if (reason) |r| @as(?u8, @intFromEnum(r)) else null, spool.records.items[index].reason);
}

test "each byte boundary preserves UTF-8, escapes, CRLF and LF framing" {
    const fixture = "{\"type\":\"message_update\",\"text\":\"A\xe2\x80\xa8B\xe2\x80\xa9C\\uD83D\\uDE00\\n\"}\r\n" ++
        "{\"type\":\"agent_settled\"}\n";
    const first = "{\"type\":\"message_update\",\"text\":\"A\xe2\x80\xa8B\xe2\x80\xa9C\\uD83D\\uDE00\\n\"}";
    const second = "{\"type\":\"agent_settled\"}";
    for (0..fixture.len + 1) |split| {
        var spool = Spool.init(std.testing.allocator);
        defer spool.deinit();
        var framer = Framer.init(std.testing.allocator, &spool);
        defer framer.deinit();
        try framer.ingest(fixture[0..split]);
        try framer.ingest(fixture[split..]);
        try framer.eof();
        try std.testing.expectEqual(@as(usize, 2), spool.records.items.len);
        try checkRecord(&spool, 0, first, null);
        try checkRecord(&spool, 1, second, null);
    }
    var spool = Spool.init(std.testing.allocator);
    defer spool.deinit();
    var framer = Framer.init(std.testing.allocator, &spool);
    defer framer.deinit();
    for (fixture) |byte| {
        const one = [1]u8{byte};
        try framer.ingest(&one);
    }
    try framer.eof();
    try checkRecord(&spool, 0, first, null);
    try checkRecord(&spool, 1, second, null);
}

test "bad records quarantine independently, including unpaired surrogate and EOF partial" {
    var spool = Spool.init(std.testing.allocator);
    defer spool.deinit();
    var framer = Framer.init(std.testing.allocator, &spool);
    defer framer.deinit();
    try framer.ingest("{\"ok\":1}\n{\"bad\":}\r\n[1,2]\n{\"s\":\"\\uD800\"}\n{} trailing\n\n{\"partial\":\"foo\r");
    try framer.eof();
    try std.testing.expectEqual(@as(usize, 7), spool.records.items.len);
    try checkRecord(&spool, 0, "{\"ok\":1}", null);
    try checkRecord(&spool, 1, "{\"bad\":}", .malformed_json);
    try checkRecord(&spool, 2, "[1,2]", .invalid_root);
    try checkRecord(&spool, 3, "{\"s\":\"\\uD800\"}", .malformed_json);
    try checkRecord(&spool, 4, "{} trailing", .malformed_json);
    try checkRecord(&spool, 5, "", .malformed_json);
    try checkRecord(&spool, 6, "{\"partial\":\"foo\r", .interrupted_record);
    try std.testing.expectError(error.EndOfStream, framer.ingest("{}\n"));
}

test "large single record spills in bounded writes and validates across slices" {
    var spool = Spool.init(std.testing.allocator);
    defer spool.deinit();
    var framer = Framer.init(std.testing.allocator, &spool);
    defer framer.deinit();
    const payload = try std.testing.allocator.alloc(u8, 160 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    try framer.ingest("{\"text\":\"");
    try framer.ingest(payload);
    try framer.ingest("\"}\n");
    try std.testing.expectEqual(@as(usize, 1), spool.records.items.len);
    try std.testing.expect(spool.largest_append <= Framer.chunk_size);
    try std.testing.expectEqual(@as(usize, payload.len + 11), spool.records.items[0].bytes.len);
    try std.testing.expectEqual(@as(?u8, null), spool.records.items[0].reason);
}

test "depth limit quarantines record and following frame still succeeds" {
    var spool = Spool.init(std.testing.allocator);
    defer spool.deinit();
    var framer = Framer.init(std.testing.allocator, &spool);
    defer framer.deinit();
    try framer.ingest("{\"deep\":");
    for (0..Framer.max_depth) |_| try framer.ingest("[");
    try framer.ingest("\n{}\n");
    try std.testing.expectEqual(@as(usize, 2), spool.records.items.len);
    try std.testing.expectEqual(@as(?u8, @intFromEnum(Framer.Reason.excessive_depth)), spool.records.items[0].reason);
    try checkRecord(&spool, 1, "{}", null);
}
