const std = @import("std");
const cache = @import("store.zig");

const alloc = std.testing.allocator;

test "sealed content survives reopen; offsets, chunk bounds, and cancellation are enforced" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer alloc.free(db_path);
    const id: cache.ContentId = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const cancelled: cache.ContentId = @splat(37);
    const empty: cache.ContentId = @splat(42);
    var first: [cache.chunk_size]u8 = undefined;
    @memset(&first, 0xa5);
    var oversized: [cache.chunk_size + 1]u8 = undefined;
    @memset(&oversized, 0x5a);
    {
        var store = try cache.Store.init(alloc, db_path);
        defer store.deinit();
        try store.beginContent(id, "base64", "image/png");
        try store.append(id, 0, &first, false);
        try std.testing.expectError(error.UnsealedContent, store.readChunk(alloc, id, 0));
        try std.testing.expectError(error.UnsealedContent, store.contentInfo(alloc, id));
        try std.testing.expectError(error.NonContiguous, store.append(id, 0, "bad", false));
        try std.testing.expectError(error.ChunkTooLarge, store.append(id, cache.chunk_size, &oversized, false));
        try store.append(id, cache.chunk_size, "the end", true);
        try std.testing.expectError(error.AlreadySealed, store.append(id, cache.chunk_size + 7, "!", true));
        try store.cancelContent(id);
        try store.append(cancelled, 0, "unsealed attachment", false);
        try std.testing.expectError(error.UnsealedContent, store.readChunk(alloc, cancelled, 0));
        try store.cancelContent(cancelled);
        try std.testing.expectError(error.ContentNotFound, store.readChunk(alloc, cancelled, 0));
        try store.append(empty, 0, "", true);
        try std.testing.expect((try store.readChunk(alloc, empty, 0)) == null);
    }
    {
        var store = try cache.Store.init(alloc, db_path);
        defer store.deinit();
        const block = (try store.readChunk(alloc, id, 0)) orelse return error.TestUnexpectedResult;
        defer alloc.free(block);
        var info = try store.contentInfo(alloc, id);
        defer info.deinit();
        try std.testing.expectEqualStrings("base64", info.encoding);
        try std.testing.expectEqualStrings("image/png", info.mime_type);
        try std.testing.expectEqual(@as(u64, cache.chunk_size + 7), info.total_length);
        try std.testing.expectEqualSlices(u8, &first, block);
        const final_block = (try store.readChunk(alloc, id, 1)) orelse return error.TestUnexpectedResult;
        defer alloc.free(final_block);
        try std.testing.expectEqualStrings("the end", final_block);
        try std.testing.expect((try store.readChunk(alloc, id, 2)) == null);
        try std.testing.expectError(error.ContentNotFound, store.readChunk(alloc, cancelled, 0));
    }
}

test "entry and live metadata pages preserve stable IDs and compound cursors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer alloc.free(db_path);
    var store = try cache.Store.init(alloc, db_path);
    defer store.deinit();
    const path = "/project/escaped ' name/session.jsonl";
    try store.putSession(.{ .session_file = path, .session_id = "uuid", .project_id = "project" });
    const ref: cache.ContentId = @splat(9);
    try store.append(ref, 0, "message", true);
    try store.putEntry(.{
        .session_file = path,
        .entry_id = "entry-one",
        .append_ordinal = 0,
        .entry_type = "message",
        .row = .{ .row_id = "entry-one", .kind = "message", .role = "user", .title = "it's quoted", .content_ref = ref },
    });
    try store.putEntry(.{
        .session_file = path,
        .entry_id = "entry-two",
        .parent_id = "entry-one",
        .append_ordinal = 1,
        .entry_type = "message",
        .row = .{ .row_id = "entry-two", .kind = "message", .role = "assistant", .revision = 3, .content_ref = ref },
    });
    try std.testing.expectError(error.SqliteFailure, store.putEntry(.{
        .session_file = path,
        .entry_id = "different identity",
        .append_ordinal = 1,
        .entry_type = "message",
        .row = .{ .row_id = "different identity", .kind = "message", .role = "assistant" },
    }));
    var first_page = try store.pageEntries(alloc, path, -1, 1);
    defer first_page.deinit();
    try std.testing.expectEqual(@as(usize, 1), first_page.rows.len);
    try std.testing.expectEqualStrings("entry-one", first_page.rows[0].row_id);
    try std.testing.expectEqualStrings("it's quoted", first_page.rows[0].title);
    try std.testing.expectEqual(@as(?i64, 0), first_page.next_cursor);
    var second_page = try store.pageEntries(alloc, path, first_page.next_cursor.?, 1);
    defer second_page.deinit();
    try std.testing.expectEqual(@as(usize, 1), second_page.rows.len);
    try std.testing.expectEqualStrings("entry-two", second_page.rows[0].row_id);
    try std.testing.expectEqual(@as(i64, 3), second_page.rows[0].revision);
    const returned_ref = second_page.rows[0].content_ref orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &ref, &returned_ref);
    try std.testing.expectError(error.InvalidLimit, store.pageEntries(alloc, path, -1, 129));
    try store.putActivePath(path, "entry-two", 0, "entry-one");
    try store.putActivePath(path, "entry-two", 1, "entry-two");
    var path_page = try store.pageActivePath(alloc, path, "entry-two", 0, 1);
    defer path_page.deinit();
    try std.testing.expectEqual(@as(usize, 1), path_page.rows.len);
    try std.testing.expectEqualStrings("entry-two", path_page.rows[0].row_id);
    try store.clearActivePath(path, "entry-two");
    var cleared_path = try store.pageActivePath(alloc, path, "entry-two", -1, 2);
    defer cleared_path.deinit();
    try std.testing.expectEqual(@as(usize, 0), cleared_path.rows.len);

    try store.putLiveRow(.{ .runtime = 8, .run_generation = 2, .local_sequence = 4, .content_index = 0, .row = .{ .row_id = "live:8:2:4:0", .kind = "message", .role = "assistant" } });
    try store.putLiveRow(.{ .runtime = 8, .run_generation = 2, .local_sequence = 4, .content_index = 1, .row = .{ .row_id = "live:8:2:4:1", .kind = "tool", .role = "assistant" } });
    var live_first = try store.pageLiveRows(alloc, 8, 2, -1, -1, 1);
    defer live_first.deinit();
    try std.testing.expectEqualStrings("live:8:2:4:0", live_first.rows[0].row_id);
    var live_next = try store.pageLiveRows(alloc, 8, 2, live_first.next_cursor.?, live_first.next_content_index.?, 1);
    defer live_next.deinit();
    try std.testing.expectEqualStrings("live:8:2:4:1", live_next.rows[0].row_id);
    try store.clearLiveGeneration(8, 2);
    var cleared = try store.pageLiveRows(alloc, 8, 2, -1, -1, 1);
    defer cleared.deinit();
    try std.testing.expectEqual(@as(usize, 0), cleared.rows.len);
}

const ConcurrentOpen = struct {
    path: []const u8,
    failure: ?anyerror = null,
    fn run(self: *ConcurrentOpen) void {
        var store = cache.Store.init(std.heap.page_allocator, self.path) catch |err| {
            self.failure = err;
            return;
        };
        store.deinit();
    }
};

test "fresh history database initializes safely across all app workers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var opens: [8]ConcurrentOpen = undefined;
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&opens, &threads) |*context, *thread| {
        context.* = .{ .path = path };
        thread.* = try std.Thread.spawn(.{}, ConcurrentOpen.run, .{context});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    for (opens) |context| try std.testing.expect(context.failure == null);
}
