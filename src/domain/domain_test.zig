const std = @import("std");
const storage = @import("store.zig");
const t = @import("types.zig");
const c = storage.c;
const Fixture = struct {
    temporary: std.testing.TmpDir,
    store: storage.Store,
    fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        var directory_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try temporary.dir.realPath(std.testing.io, &directory_path);
        return .{ .temporary = temporary, .store = try storage.Store.open(std.testing.io, directory_path[0..n]) };
    }
    fn deinit(self: *Fixture) void {
        self.store.close() catch @panic("store close failed");
        self.temporary.cleanup();
    }
    fn path(self: *Fixture, buffer: []u8) ![]const u8 {
        const n = try self.temporary.dir.realPath(std.testing.io, buffer);
        return buffer[0..n];
    }
};
fn seed(store: *storage.Store) !void {
    try store.exec("INSERT INTO projects VALUES('p',1,'synthetic');" ++
        "INSERT INTO workspaces VALUES('w',1,'p',X'7b7d');" ++
        "INSERT INTO sessions(id,revision,workspace_id,selection) VALUES('s',1,'w',X'7b7d');" ++
        "INSERT INTO threads(id,revision,project_id,workspace_id,session_id) VALUES('h',1,'p','w','s');" ++
        "INSERT INTO runs(id,revision,thread_id,session_id,state,requested) VALUES('r',1,'h','s','queued',X'7b7d');" ++
        "INSERT INTO messages VALUES('m',1,'h','r',0,'assistant',1);" ++
        "INSERT INTO blocks(id,revision,message_id,ordinal,kind) VALUES('b',1,'m',0,'text');");
}
fn effect(store: *storage.Store, id: []const u8, state: []const u8, kind: []const u8) !void {
    try store.execute("INSERT INTO effects(id,revision,run_id,session_id,kind,request,digest,state,command_id) VALUES(?,1,'r','s',?,X'7b7d',zeroblob(32),?,'cmd')", &.{ .{ .text = id }, .{ .text = kind }, .{ .text = state } });
}
fn event(sequence: u64, index: u32, id: []const u8) t.Event {
    return .{ .event_id = .{ .value = id }, .position = .{ .commit_sequence = sequence, .event_index = index }, .aggregate = .{ .thread = .{ .value = "h" } }, .aggregate_revision = 2, .kind = "MessageAdded", .payload = "{}" };
}

test "store identity is independent and second owner fails without truncating lock" {
    var f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectEqual(storage.application_id, try f.store.scalar("PRAGMA application_id"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("PRAGMA user_version"));
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, storage.Store.open(std.testing.io, try f.path(&path)));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("PRAGMA foreign_keys"));
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("PRAGMA synchronous"));
}

test "foreign legacy schema rejects before modifying identity or journal mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_path);
    var db_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&db_path, "{s}/conversation.sqlite3", .{dir_path[0..n]});
    var db: ?*c.sqlite3 = null;
    try storage.check(c.sqlite3_open(path.ptr, &db));
    try storage.check(c.sqlite3_exec(db, "CREATE TABLE history(value);INSERT INTO history VALUES(42);PRAGMA user_version=6", null, null, null));
    try storage.check(c.sqlite3_close(db));
    try std.testing.expectError(error.UnsupportedStore, storage.Store.open(std.testing.io, dir_path[0..n]));
    try storage.check(c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY, null));
    defer _ = c.sqlite3_close(db);
    var raw: ?*c.sqlite3_stmt = null;
    try storage.check(c.sqlite3_prepare_v2(db, "SELECT value FROM history", -1, &raw, null));
    const s = storage.Statement{ .raw = raw.? };
    defer s.deinit();
    try std.testing.expect(try s.step());
    try std.testing.expectEqual(@as(i64, 42), s.integer(0));
}

test "receipt events and entity writes commit or roll back atomically" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.begin();
    try seed(&f.store);
    const abandoned = try f.store.nextSequence();
    try f.store.recordCommand("send", "canonical", "receipt-original", abandoned);
    try f.store.appendEvent(event(abandoned, 0, "e1"));
    try f.store.rollback();
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM messages"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM commands"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM events"));
    try f.store.begin();
    try seed(&f.store);
    const sequence = try f.store.nextSequence();
    try std.testing.expectEqual(abandoned, sequence);
    try f.store.recordCommand("send", "canonical", "receipt-original", sequence);
    try f.store.appendEvent(event(sequence, 0, "e1"));
    try f.store.appendEvent(event(sequence, 1, "e2"));
    try f.store.commit();
    const position = try f.store.position();
    try std.testing.expectEqual(@as(u32, 1), position.event_index);
    try std.testing.expectEqual(sequence, position.commit_sequence);
    try f.store.execute("UPDATE threads SET revision=99 WHERE id='h'", &.{});
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings("receipt-original", (try f.store.lookupCommand("send", "canonical", &output)).?);
    try std.testing.expectError(error.Conflict, f.store.lookupCommand("send", "altered-precondition", &output));
    try std.testing.expectError(error.Limit, f.store.lookupCommand("send", "canonical", output[0..1]));
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM events WHERE revision=2"));
    // A durable rejection consumes a commit sequence but not an event position.
    try f.store.begin();
    const rejection_sequence = try f.store.nextSequence();
    try f.store.recordCommand("stale", "canonical-stale", "rejected:revision_conflict:99", rejection_sequence);
    try f.store.commit();
    try std.testing.expectEqual(position, try f.store.position());
    try std.testing.expectEqualStrings("rejected:revision_conflict:99", (try f.store.lookupCommand("stale", "canonical-stale", &output)).?);
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    try std.testing.expectEqualStrings("receipt-original", (try f.store.lookupCommand("send", "canonical", &output)).?);
}

test "chunk append retains Unicode bytes across boundaries and rejects gap overlap" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.begin();
    try seed(&f.store);
    const bytes = "é👩‍💻\x00世界";
    try std.testing.expectEqual(.appended, try f.store.appendChunk("b", 0, bytes[0..1]));
    try std.testing.expectEqual(.appended, try f.store.appendChunk("b", 1, bytes[1..]));
    try std.testing.expectEqual(.duplicate, try f.store.appendChunk("b", 0, bytes[0..1]));
    try std.testing.expectError(error.Conflict, f.store.appendChunk("b", 0, "wrong"));
    try std.testing.expectError(error.Conflict, f.store.appendChunk("b", bytes.len + 1, "gap"));
    try f.store.commit();
    const s = try f.store.prepare("SELECT bytes FROM chunks WHERE block_id='b' ORDER BY byte_offset", &.{});
    defer s.deinit();
    var restored: [128]u8 = undefined;
    var n: usize = 0;
    while (try s.step()) {
        const chunk = try s.bytes(0);
        @memcpy(restored[n..][0..chunk.len], chunk);
        n += chunk.len;
    }
    try std.testing.expectEqualStrings(bytes, restored[0..n]);
    try std.testing.expectEqual(@as(i64, 3), try f.store.scalar("SELECT revision FROM blocks WHERE id='b'"));
}

test "claimed ambiguity and withdrawn effects never return to dispatchable state" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.begin();
    try seed(&f.store);
    try effect(&f.store, "start", "planned", "start");
    try effect(&f.store, "reply", "withdrawn", "approval_reply");
    try f.store.commit();
    try f.store.begin();
    try std.testing.expect(try f.store.claim("start", "incarnation1"));
    try f.store.rollback();
    try f.store.begin();
    try std.testing.expect(try f.store.claim("start", "incarnation1"));
    try std.testing.expect(!try f.store.claim("reply", "incarnation1"));
    try f.store.commit();
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    try f.store.begin();
    try f.store.recoverClaims();
    try std.testing.expect(!try f.store.claim("start", "incarnation2"));
    try std.testing.expect(!try f.store.claim("reply", "incarnation2"));
    try f.store.commit();
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE id='start' AND state='unknown'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE id='reply' AND state='withdrawn'"));
}

test "SQLite FULL rolls back intent without advancing durable sequence" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.exec("CREATE TABLE pressure(bytes BLOB)");
    const pages = try f.store.scalar("PRAGMA page_count");
    var sql: [128]u8 = undefined;
    try f.store.exec(try std.fmt.bufPrintZ(&sql, "PRAGMA max_page_count={d}", .{pages}));
    try f.store.begin();
    _ = try f.store.nextSequence();
    try std.testing.expectError(error.Full, f.store.exec("INSERT INTO pressure VALUES(zeroblob(65536))"));
    try f.store.rollback();
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT next_sequence FROM meta"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM pressure"));
}

test "cancellation blocks queued starts but permits journaled cancel request" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.begin();
    try seed(&f.store);
    try effect(&f.store, "start", "planned", "start");
    try effect(&f.store, "cancel", "planned", "cancel");
    try f.store.exec("UPDATE runs SET state='cancel_requested' WHERE id='r'");
    try std.testing.expect(!try f.store.claim("start", "owner"));
    try std.testing.expect(try f.store.claim("cancel", "owner"));
    try f.store.commit();
}

fn readScalar(database: *c.sqlite3, sql: [:0]const u8) !i64 {
    var raw: ?*c.sqlite3_stmt = null;
    try storage.check(c.sqlite3_prepare_v2(database, sql.ptr, -1, &raw, null));
    const statement = storage.Statement{ .raw = raw.? };
    defer statement.deinit();
    if (!try statement.step()) return error.MissingRow;
    return statement.integer(0);
}

test "pinned read snapshot does not mix a later writer transaction" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.begin();
    const first = try f.store.nextSequence();
    try f.store.appendEvent(event(first, 0, "before"));
    try f.store.commit();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var database_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&database_path, "{s}/conversation.sqlite3", .{try f.path(&directory)});
    var reader: ?*c.sqlite3 = null;
    try storage.check(c.sqlite3_open_v2(path.ptr, &reader, c.SQLITE_OPEN_READONLY, null));
    defer _ = c.sqlite3_close(reader);
    try storage.check(c.sqlite3_exec(reader, "BEGIN", null, null, null));
    try std.testing.expectEqual(@as(i64, 1), try readScalar(reader.?, "SELECT count(*) FROM events"));
    try f.store.begin();
    const second = try f.store.nextSequence();
    try f.store.appendEvent(event(second, 0, "after"));
    try f.store.commit();
    try std.testing.expectEqual(@as(i64, 1), try readScalar(reader.?, "SELECT count(*) FROM events"));
    try storage.check(c.sqlite3_exec(reader, "ROLLBACK", null, null, null));
    try std.testing.expectEqual(@as(i64, 2), try readScalar(reader.?, "SELECT count(*) FROM events"));
}
