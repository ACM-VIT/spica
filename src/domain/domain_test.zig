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
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
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
    try std.testing.expectEqual(.duplicate, try f.store.appendChunk("b", 0, bytes));
    try std.testing.expectEqual(.duplicate, try f.store.appendChunk("b", 2, bytes[2..6]));
    try std.testing.expectError(error.Conflict, f.store.appendChunk("b", bytes.len - 1, bytes));
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
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM events WHERE kind='RecoveryUnknown'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='RecoveryUnknown' AND CAST(aggregate AS TEXT) LIKE '%effect%'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='RecoveryUnknown' AND CAST(aggregate AS TEXT) LIKE '%run%'"));
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

const domain = @import("../domain.zig");
const Conversation = struct {
    project: t.ProjectId,
    workspace: t.adapter.WorkspaceId,
    thread: t.ThreadId,
    fn create(owner: *domain.Owner, allocator: std.mem.Allocator) !Conversation {
        const p = try owner.command(allocator, .{ .command_id = .{ .value = "project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "真实 project" } } });
        const w = try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = p.entity_ids.project.?, .binding = try domain.workspace_binding.capture(allocator, owner.io, "/tmp") } } });
        const h = try owner.command(allocator, .{ .command_id = .{ .value = "thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = p.entity_ids.project.?, .workspace = w.entity_ids.workspace.? } } });
        return .{ .project = p.entity_ids.project.?, .workspace = w.entity_ids.workspace.?, .thread = h.entity_ids.thread.? };
    }
    fn send(self: Conversation, id: []const u8, text: []const u8, revision: u64) t.CommandEnvelope {
        return .{ .command_id = .{ .value = id }, .target = .{ .thread = self.thread }, .expected_revision = .{ .revision = revision }, .payload = .{ .thread_send = .{ .text = text, .selection = .{ .model_provider = "fake", .model_id = "test", .effort = "low", .account_ref = "local", .workspace = self.workspace } } } };
    }
};

test "explicit chat titles are durable, bounded, revisioned and idempotent" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "title", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    const title = "日本語 café 🎮";
    const command: t.CommandEnvelope = .{ .command_id = .{ .value = "title" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_title_set = .{ .title = title } } };
    const accepted = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, accepted.outcome);
    try std.testing.expectEqual(@as(u64, 2), accepted.committed_revisions[0].revision);
    const retry = try owner.command(allocator, command);
    try std.testing.expectEqualSlices(u8, try t.encode(accepted, try allocator.alloc(u8, 4096)), try t.encode(retry, try allocator.alloc(u8, 4096)));
    const stale = try owner.command(allocator, .{ .command_id = .{ .value = "title-stale" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_title_set = .{ .title = "other" } } });
    try std.testing.expectEqual(t.Reason.revision_conflict, stale.reason.?);
    var stored = try f.store.prepare("SELECT title FROM threads WHERE id=?", &.{.{ .text = conversation.thread.value }});
    defer stored.deinit();
    try std.testing.expect(try stored.step());
    try std.testing.expectEqualStrings(title, try stored.bytes(0));
    const after_send = try owner.command(allocator, conversation.send("after-title-send", "automatic naming must not replace", 2));
    try std.testing.expectEqual(.accepted, after_send.outcome);
    var bytes: [t.max_title_bytes + 8]u8 = undefined;
    @memset(&bytes, 'x');
    const boundary = try owner.command(allocator, .{ .command_id = .{ .value = "title-boundary" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 3 }, .payload = .{ .thread_title_set = .{ .title = bytes[0 .. t.max_title_bytes + 1] } } });
    try std.testing.expectEqual(t.Reason.invalid_command, boundary.reason.?);
    var retained = try f.store.prepare("SELECT title FROM threads WHERE id=?", &.{.{ .text = conversation.thread.value }});
    defer retained.deinit();
    try std.testing.expect(try retained.step());
    try std.testing.expectEqualStrings(title, try retained.bytes(0));
}

test "title validation is transactional at Unicode byte boundaries and survives reopen" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "title-boundaries", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    const title = "🎮" ** 40;
    const command: t.CommandEnvelope = .{ .command_id = .{ .value = "exact-title" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_title_set = .{ .title = title } } };
    const accepted = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, accepted.outcome);
    var conflict = command;
    conflict.payload.thread_title_set.title = "different";
    try std.testing.expectEqual(t.Reason.command_id_conflict, (try owner.command(allocator, conflict)).reason.?);
    const invalid = [_][]const u8{ "", title ++ "x", "\xff", "line\nbreak", "tab\t", "\x7f", "nul\x00" };
    for (invalid, 0..) |value, index| {
        const rejected = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "invalid-title-{d}", .{index}) }, .target = command.target, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_title_set = .{ .title = value } } });
        try std.testing.expectEqual(t.Reason.invalid_command, rejected.reason.?);
    }
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadTitleChanged'"));
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    const stored = try f.store.prepare("SELECT title,revision FROM threads WHERE id=?", &.{.{ .text = conversation.thread.value }});
    defer stored.deinit();
    try std.testing.expect(try stored.step());
    try std.testing.expectEqualStrings(title, try stored.bytes(0));
    try std.testing.expectEqual(@as(i64, 2), stored.integer(1));
    const retry = try owner.command(allocator, command);
    try std.testing.expectEqualSlices(u8, try t.encode(accepted, try allocator.alloc(u8, 4096)), try t.encode(retry, try allocator.alloc(u8, 4096)));
}

test "schema five adds empty titles without changing existing messages or revisions" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("ALTER TABLE threads DROP COLUMN title; UPDATE meta SET schema_version=5; PRAGMA user_version=5");
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    try std.testing.expectEqual(@as(i64, 6), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE id='h' AND title='' AND revision=1"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM messages WHERE id='m'"));
}

test "real reducers accept arbitrary prompt dedup before revision and withdraw queued effects" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "one", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const command = conversation.send("send", "Any user text: 世界 é\x00😀", 1);
    const receipt = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, receipt.outcome);
    try std.testing.expectEqual(@as(usize, 2), receipt.effect_ids.len);
    try std.testing.expectEqual(@as(usize, 9), receipt.committed_revisions.len);
    try expectRevisionEvents(&f.store, receipt.committed_revisions, receipt.commit_sequence);
    const duplicate = try owner.command(allocator, command);
    var first: [8192]u8 = undefined;
    var second: [8192]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try t.encode(receipt, &first), try t.encode(duplicate, &second));
    const conflict = try owner.command(allocator, conversation.send("send", "changed", 1));
    try std.testing.expectEqual(t.Reason.command_id_conflict, conflict.reason.?);
    const stale_command = conversation.send("stale", "later", 1);
    const stale = try owner.command(allocator, stale_command);
    try std.testing.expectEqual(t.Reason.revision_conflict, stale.reason.?);
    const cancel = try owner.command(allocator, .{ .command_id = .{ .value = "cancel" }, .target = .{ .run = receipt.entity_ids.run.? }, .expected_revision = .{ .revision = 1 }, .payload = .{ .run_cancel = .{ .reason = "before dispatch" } } });
    try std.testing.expectEqual(.accepted, cancel.outcome);
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM effects WHERE state='withdrawn'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='cancelled'"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM messages WHERE incomplete=1"));
    try expectRevisionEvents(&f.store, cancel.committed_revisions, cancel.commit_sequence);
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    try owner.recover();
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const stale_again = try owner.command(allocator, stale_command);
    try std.testing.expectEqual(stale.commit_sequence, stale_again.commit_sequence);
}

test "committed effect claims recover unknown without replay and explicit reconciliation clears only evidence" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "one", .utc_ms = null };
    const conversation = try Conversation.create(&owner, allocator);
    const sent = try owner.command(allocator, conversation.send("send", "arbitrary prompt", 1));
    const claimed = (try owner.claimNext(allocator)).?;
    try std.testing.expectEqualStrings(sent.effect_ids[0].value, claimed.id.value);
    try std.testing.expect(!f.store.in_transaction);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE state='in_flight'"));
    try owner.recover();
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    var reconcile: t.CommandEnvelope = .{ .command_id = .{ .value = "reconcile-no-proof" }, .target = .{ .run = sent.entity_ids.run.? }, .expected_revision = .{ .revision = 2 }, .payload = .{ .run_reconcile = .{ .session = sent.entity_ids.session.?, .effects = sent.effect_ids[0..1] } } };
    const denied = try owner.command(allocator, reconcile);
    try std.testing.expectEqual(t.Reason.authority_unavailable, denied.reason.?);
    reconcile.command_id.value = "reconcile-proof";
    reconcile.payload.run_reconcile.resolution = .{ .actor = "operator", .evidence = "external verified no call", .no_execution = true };
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, reconcile)).outcome);
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const approval = try owner.command(allocator, .{ .command_id = .{ .value = "missing-approval" }, .target = .{ .approval = .{ .value = "missing" } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .approval_respond = .{ .decision = .allow, .action_digest = "x" } } });
    try std.testing.expectEqual(t.Reason.not_found, approval.reason.?);
}

test "revision exhaustion rejects chunks claims and recovery without numeric promotion" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.store.begin();
    try seed(&f.store);
    try effect(&f.store, "exhausted", "planned", "start");
    try f.store.exec("UPDATE blocks SET revision=9223372036854775807; UPDATE effects SET revision=9223372036854775807");
    try std.testing.expectError(error.Limit, f.store.appendChunk("b", 0, "x"));
    try std.testing.expectError(error.Limit, f.store.claim("exhausted", "owner"));
    try f.store.exec("UPDATE effects SET state='in_flight'");
    try std.testing.expectError(error.Limit, f.store.recoverClaims());
    try f.store.rollback();
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM events"));
}

test "adapter evidence reduction persists bytes approval expiry and cancel reply race" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "one", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const sent = try owner.command(allocator, conversation.send("send", "not a fixture ID, arbitrary 世界", 1));
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "fake-process" }, .upstream = .{ .value = "upstream" } } });
    const start = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
    var observation: t.adapter.Observation = .{ .correlation = .{ .effect = start.id, .session = sent.entity_ids.session.?, .run = sent.entity_ids.run.? }, .upstream_event = "chunk-1", .cursor = .{ .value = "1" }, .body = .{ .chunk = .{ .message = sent.entity_ids.assistant_message.?, .block = sent.entity_ids.assistant_block.?, .offset = 0, .text = "Unicode\x00\xf0\x9f" } } };
    try owner.observe(allocator, observation);
    const position = try f.store.position();
    try owner.observe(allocator, observation);
    try std.testing.expectEqual(position, try f.store.position());
    observation.body.chunk.text = "conflict";
    try std.testing.expectError(error.Conflict, owner.observe(allocator, observation));
    observation.upstream_event = "tool-start";
    observation.correlation.tool = .{ .value = "domain-allocated-tool" };
    observation.correlation.upstream_tool = "upstream-tool";
    observation.body = .{ .tool_started = .{ .name = "fake local read", .action_digest = "action" } };
    try owner.observe(allocator, observation);
    observation.upstream_event = "approval";
    observation.correlation.approval = .{ .value = "domain-allocated-approval" };
    observation.correlation.upstream_request = "request";
    observation.body = .{ .approval = .{ .correlation = observation.correlation, .workspace = conversation.workspace, .action_digest = "action", .scope = "read only", .expires_at = 2000 } };
    try owner.observe(allocator, observation);
    var reply: t.CommandEnvelope = .{ .command_id = .{ .value = "expired" }, .target = .{ .approval = observation.correlation.approval.? }, .expected_revision = .{ .revision = 1 }, .payload = .{ .approval_respond = .{ .decision = .allow, .action_digest = "action" } } };
    owner.utc_ms = 2000;
    try std.testing.expectEqual(t.Reason.approval_expired, (try owner.command(allocator, reply)).reason.?);
    owner.utc_ms = 1000;
    reply.command_id.value = "allow";
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, reply)).outcome);
    const run_revision = try f.store.scalar("SELECT revision FROM runs");
    const cancelled = try owner.command(allocator, .{ .command_id = .{ .value = "cancel" }, .target = .{ .run = sent.entity_ids.run.? }, .expected_revision = .{ .revision = @intCast(run_revision) }, .payload = .{ .run_cancel = .{ .reason = "cancel races reply dispatch" } } });
    try std.testing.expectEqual(.accepted, cancelled.outcome);
    const next = (try owner.claimNext(allocator)).?;
    try std.testing.expect(next.request == .cancel);
    try owner.delivered(allocator, next.id, .{ .outcome = .unknown });
    observation.upstream_event = "late-tool-result";
    observation.body = .{ .tool_completed = .{ .outcome = .succeeded, .result = "exact tool result\x00" } };
    try owner.observe(allocator, observation);
    observation.upstream_event = "late-cancel-no-proof";
    observation.body = .{ .cancelled = .{ .tools_stopped = false } };
    try owner.observe(allocator, observation);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='unknown'"));
    observation.upstream_event = "late-completed";
    observation.body = .completed;
    try owner.observe(allocator, observation);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='unknown'"));
    observation.upstream_event = "late-failure";
    observation.body = .{ .failure = .{ .code = "late", .detail = "ignored lifecycle" } };
    try owner.observe(allocator, observation);
    observation.upstream_event = "late-disconnect";
    observation.body = .{ .disconnect = .{ .reason = "lost", .continuity = .lost } };
    try owner.observe(allocator, observation);
    observation.upstream_event = "late-ambiguous";
    observation.body = .{ .ambiguous = .{ .reason = "unknown" } };
    try owner.observe(allocator, observation);
}

const Consumer = struct {
    host: *@import("../domain.zig").Host,
    event: std.Io.Event = .unset,
    arena: std.heap.ArenaAllocator,
    fn wake(context: ?*anyopaque) void {
        const self: *Consumer = @ptrCast(@alignCast(context.?));
        self.event.set(std.testing.io);
    }
    fn next(self: *Consumer) !t.Output {
        var output: [1]t.Output = undefined;
        const bytes = try self.arena.allocator().alloc(u8, 1024 * 1024);
        while (true) {
            self.event.reset();
            const result = self.host.drain(&output, bytes);
            if (result.output_count != 0) return output[0];
            if (result.required_bytes_for_next != 0) return error.OutputTooLarge;
            self.event.waitUncancelable(std.testing.io);
        }
    }
    fn command(self: *Consumer, envelope: t.CommandEnvelope) !t.Receipt {
        const ticket = try self.host.submit(envelope);
        const output = try self.next();
        if (output != .command_receipt) return error.ExpectedReceipt;
        try std.testing.expectEqual(ticket.value, output.command_receipt.ticket.value);
        try std.testing.expectEqual(.accepted, output.command_receipt.receipt.outcome);
        return output.command_receipt.receipt;
    }
    fn query(self: *Consumer, q: t.Query) !t.QueryPage {
        const ticket = try self.host.query(q);
        const output = try self.next();
        if (output != .query_page) return error.ExpectedPage;
        try std.testing.expectEqual(ticket.value, output.query_page.ticket.value);
        return output.query_page.page;
    }
};

test "public Host consumer streams approves cancels pages and reopens durable state" {
    const Host = @import("../domain.zig").Host;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var consumer: Consumer = .{ .host = undefined, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    var live = true;
    defer if (live) consumer.host.destroy();
    const project = (try consumer.command(.{ .command_id = .{ .value = "host-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "consumer" } } })).entity_ids.project.?;
    const workspace = (try consumer.command(.{ .command_id = .{ .value = "host-workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try domain.workspace_binding.capture(consumer.arena.allocator(), std.testing.io, path_buffer[0..n]) } } })).entity_ids.workspace.?;
    const thread = (try consumer.command(.{ .command_id = .{ .value = "host-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    const selection: t.adapter.Selection = .{ .workspace = workspace, .model_provider = "fake", .model_id = "fixture", .effort = "none", .account_ref = "fixture" };
    const send: t.CommandEnvelope = .{ .command_id = .{ .value = "host-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "Hello 世界", .selection = selection } } };
    const sent = try consumer.command(send);
    const run = sent.entity_ids.run.?;
    const approvals = try consumer.query(.{ .approvals = .{ .run = run } });
    try std.testing.expectEqual(@as(usize, 1), approvals.items.len);
    const approval = approvals.items[0].approval;
    try std.testing.expect(approval.live);
    const messages = try consumer.query(.{ .messages = .{ .thread = thread, .page = .{ .limit = 1 } } });
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    const continuation = try consumer.query(.{ .messages = .{ .thread = thread, .page = .{ .limit = 1, .snapshot = messages.snapshot_id, .cursor = messages.next_cursor.? } } });
    const assistant = continuation.items[0].message;
    const content = try consumer.query(.{ .content = .{ .block = assistant.blocks[0].block_id, .start_byte = 0, .end_byte = assistant.blocks[0].committed_bytes } });
    try std.testing.expect(std.mem.indexOf(u8, content.items[0].content.bytes, "世界") != null);
    _ = try consumer.host.subscribe(.{ .scope = .{ .thread = thread }, .after_position = content.snapshot_position });
    const subscribed = try consumer.next();
    try std.testing.expect(subscribed == .subscribed);
    _ = try consumer.command(.{ .command_id = .{ .value = "host-allow" }, .target = .{ .approval = approval.id }, .expected_revision = .{ .revision = approval.revision }, .payload = .{ .approval_respond = .{ .decision = .allow, .action_digest = approval.evidence.action_digest } } });
    const batch = try consumer.next();
    try std.testing.expect(batch == .event_batch);
    var kinds = std.EnumSet(std.meta.Tag(t.AggregateRef)).initEmpty();
    for (batch.event_batch.events) |value| kinds.insert(std.meta.activeTag(value.aggregate));
    inline for (.{ .message, .block, .tool, .effect, .approval, .run }) |kind| try std.testing.expect(kinds.contains(kind));
    _ = try consumer.host.unsubscribe(subscribed.subscribed.id);
    try std.testing.expect((try consumer.next()) == .unsubscribed);
    const finalized = try consumer.query(.{ .messages = .{ .thread = thread } });
    try std.testing.expect(!finalized.items[1].message.incomplete);
    try std.testing.expect(finalized.items[1].message.revision > assistant.revision);
    const runs = try consumer.query(.{ .runs = .{ .thread = thread } });
    try std.testing.expectEqual(t.RunState.completed, runs.items[0].run.state);
    const tools = try consumer.query(.{ .tools = .{ .run = run } });
    try std.testing.expectEqual(t.ToolOutcome.succeeded, tools.items[0].tool.outcome);
    const blocks = try consumer.query(.{ .blocks = .{ .message = sent.entity_ids.assistant_message.? } });
    try std.testing.expectEqual(@as(usize, 2), blocks.items.len);
    // Reopen a completed conversation, then exercise a second approval on the
    // same durable session. Fake process-local counters cannot supply identity.
    consumer.host.destroy();
    live = false;
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const second = try consumer.command(.{ .command_id = .{ .value = "host-send-2" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "deny this turn", .selection = selection } } });
    try std.testing.expectEqualStrings(sent.entity_ids.session.?.value, second.entity_ids.session.?.value);
    const next_approvals = try consumer.query(.{ .approvals = .{ .run = second.entity_ids.run.? } });
    try std.testing.expectEqual(@as(usize, 1), next_approvals.items.len);
    const next_approval = next_approvals.items[0].approval;
    try std.testing.expect(next_approval.live);
    try std.testing.expect(!t.adapter.equal(approval.id, next_approval.id));
    try std.testing.expect(!t.adapter.equal(approval.evidence.correlation.upstream_request, next_approval.evidence.correlation.upstream_request));
    const old = (try consumer.query(.{ .approvals = .{ .run = run } })).items[0].approval;
    _ = try consumer.host.submit(.{ .command_id = .{ .value = "host-stale-allow" }, .target = .{ .approval = old.id }, .expected_revision = .{ .revision = old.revision }, .payload = .{ .approval_respond = .{ .decision = .allow, .action_digest = old.evidence.action_digest } } });
    const refused = try consumer.next();
    try std.testing.expect(refused == .command_receipt);
    try std.testing.expectEqual(t.Reason.approval_invalid, refused.command_receipt.receipt.reason.?);
    _ = try consumer.command(.{ .command_id = .{ .value = "host-deny-2" }, .target = .{ .approval = next_approval.id }, .expected_revision = .{ .revision = next_approval.revision }, .payload = .{ .approval_respond = .{ .decision = .deny, .action_digest = next_approval.evidence.action_digest } } });
    const second_tools = try consumer.query(.{ .tools = .{ .run = second.entity_ids.run.? } });
    try std.testing.expectEqual(@as(usize, 1), second_tools.items.len);
    try std.testing.expectEqual(t.ToolOutcome.failed, second_tools.items[0].tool.outcome);
    const second_runs = try consumer.query(.{ .runs = .{ .thread = thread } });
    try std.testing.expectEqual(t.RunState.completed, second_runs.items[1].run.state);
    const third = try consumer.command(.{ .command_id = .{ .value = "host-send-3" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 3 }, .payload = .{ .thread_send = .{ .text = "cancel me", .selection = selection } } });
    try std.testing.expectEqualStrings(sent.entity_ids.session.?.value, third.entity_ids.session.?.value);
    const active = try consumer.query(.{ .runs = .{ .thread = thread } });
    const active_run = active.items[2].run;
    _ = try consumer.command(.{ .command_id = .{ .value = "host-cancel" }, .target = .{ .run = third.entity_ids.run.? }, .expected_revision = .{ .revision = active_run.revision }, .payload = .{ .run_cancel = .{ .reason = "consumer cancel" } } });
    const cancelled = try consumer.query(.{ .runs = .{ .thread = thread } });
    try std.testing.expectEqual(t.RunState.cancelled, cancelled.items[2].run.state);
    const cancelled_messages = try consumer.query(.{ .messages = .{ .thread = thread } });
    try std.testing.expect(!cancelled_messages.items[5].message.incomplete);
    consumer.host.destroy();
    live = false;
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const replay = try consumer.command(send);
    try std.testing.expectEqualStrings(run.value, replay.entity_ids.run.?.value);
    const retained = try consumer.query(.{ .runs = .{ .thread = thread } });
    try std.testing.expectEqual(@as(usize, 3), retained.items.len);
    try std.testing.expectEqual(t.RunState.completed, retained.items[0].run.state);
    try std.testing.expectEqual(t.RunState.completed, retained.items[1].run.state);
    try std.testing.expectEqual(t.RunState.cancelled, retained.items[2].run.state);
    const retained_messages = try consumer.query(.{ .messages = .{ .thread = thread } });
    try std.testing.expect(!retained_messages.items[1].message.incomplete);
    try std.testing.expect(!retained_messages.items[3].message.incomplete);
    try std.testing.expect(!retained_messages.items[5].message.incomplete);
}

test "Host subscriptions retain delivery under small drain and unsubscribe generation checks" {
    const Host = @import("../domain.zig").Host;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var consumer: Consumer = .{ .host = undefined, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    defer consumer.host.destroy();
    _ = try consumer.host.subscribe(.{ .scope = .all, .after_position = .{} });
    const subscribed = try consumer.next();
    try std.testing.expect(subscribed == .subscribed);
    const id_value = subscribed.subscribed.id;
    _ = try consumer.command(.{ .command_id = .{ .value = "subscription-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "event consumer" } } });
    const batch = try consumer.next();
    try std.testing.expect(batch == .event_batch);
    try std.testing.expectEqual(@as(usize, 1), batch.event_batch.events.len);
    try std.testing.expectEqual(id_value.generation, batch.event_batch.id.generation);
    consumer.event.reset();
    _ = try consumer.host.unsubscribe(id_value);
    consumer.event.waitUncancelable(std.testing.io);
    var output: [1]t.Output = undefined;
    var tiny: [1]u8 = undefined;
    const retained = consumer.host.drain(&output, &tiny);
    try std.testing.expectEqual(@as(usize, 0), retained.output_count);
    try std.testing.expect(retained.more_pending and retained.required_bytes_for_next > tiny.len);
    try std.testing.expect((try consumer.next()) == .unsubscribed);
    _ = try consumer.host.unsubscribe(id_value);
    const failure = try consumer.next();
    try std.testing.expect(failure == .failure);
    try std.testing.expectEqual(.cursor_invalid, failure.failure.failure.reason);
}

fn expectRevisionEvents(database: *storage.Store, revisions: []const t.CommittedRevision, sequence: u64) !void {
    for (revisions) |revision| {
        var buffer: [1024]u8 = undefined;
        const target = try t.encode(revision.target, &buffer);
        const s = try database.prepare("SELECT count(*) FROM events WHERE sequence=? AND aggregate=? AND revision=?", &.{ .{ .integer = @intCast(sequence) }, .{ .blob = target }, .{ .integer = @intCast(revision.revision) } });
        defer s.deinit();
        try std.testing.expect(try s.step());
        try std.testing.expectEqual(@as(i64, 1), s.integer(0));
    }
}

test "transaction journal rolls back rejected mutations and publishes each changed revision once" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "journal", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const sent = try owner.command(allocator, conversation.send("journal-send", "hello", 1));
    try expectRevisionEvents(&f.store, sent.committed_revisions, sent.commit_sequence);
    const claimed = (try owner.claimNext(allocator)).?;
    try expectRevisionEvents(&f.store, try f.store.committedRevisions(allocator), (try f.store.position()).commit_sequence);
    try owner.delivered(allocator, claimed.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "journal" }, .upstream = .{ .value = "upstream" } } });
    try expectRevisionEvents(&f.store, try f.store.committedRevisions(allocator), (try f.store.position()).commit_sequence);
    try owner.observe(allocator, .{ .correlation = .{ .session = sent.entity_ids.session.?, .run = sent.entity_ids.run.? }, .upstream_event = "failure", .body = .{ .failure = .{ .code = "test", .detail = "terminal failure" } } });
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM messages WHERE incomplete=1"));
    try expectRevisionEvents(&f.store, try f.store.committedRevisions(allocator), (try f.store.position()).commit_sequence);
    const before = try f.store.position();
    const rejected = try owner.command(allocator, conversation.send("journal-stale", "rejected", 1));
    try std.testing.expectEqual(.rejected, rejected.outcome);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM aggregate_changes"));
    try std.testing.expectEqual(before, try f.store.position());
    try f.store.begin();
    try f.store.execute("UPDATE runs SET revision=revision+1 WHERE id=?", &.{.{ .text = sent.entity_ids.run.?.value }});
    try f.store.rollback();
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM aggregate_changes"));
}

const AsyncAdapter = struct {
    const adapter = @import("../runtime/adapter.zig");
    fn discover(_: *anyopaque) t.adapter.Discovery {
        return .{ .capabilities = @splat(.{ .status = .supported }), .limits = .{} };
    }
    fn account(_: *anyopaque) t.adapter.Account {
        return .{ .reference = "local", .readiness = .ready };
    }
    fn selection(_: *anyopaque, requested: t.adapter.Selection) t.adapter.SelectionResult {
        return .{ .requested = requested, .effective = null, .readiness = .ready };
    }
    fn dispatch(_: *anyopaque, _: std.mem.Allocator, _: t.adapter.Request) !t.adapter.Receipt {
        return .{ .outcome = .acknowledged };
    }
    fn pump(_: *anyopaque) !void {}
    fn poll(_: *anyopaque, _: std.mem.Allocator) !?t.adapter.Observation {
        return null;
    }
    fn shutdown(_: *anyopaque) void {}
    const vtable: adapter.Adapter.VTable = .{
        .discover = discover,
        .accountStatus = account,
        .resolveSelection = selection,
        .dispatch = dispatch,
        .pump = pump,
        .poll = poll,
        .shutdown = shutdown,
    };
    fn handle(self: *AsyncAdapter) adapter.Adapter {
        return .{ .context = self, .vtable = &vtable };
    }
    fn discoverFactory(context: *anyopaque, _: t.adapter.Selection) t.adapter.Discovery {
        return discover(context);
    }
    fn accountFactory(context: *anyopaque, _: t.adapter.Selection) t.adapter.Account {
        return account(context);
    }
    fn createFactory(context: *anyopaque, _: std.mem.Allocator, _: t.adapter.Selection, _: []const u8, _: t.adapter.RuntimeSessionId, _: ?adapter.Bridge) !adapter.Adapter {
        return (@as(*AsyncAdapter, @ptrCast(@alignCast(context)))).handle();
    }
    fn destroyFactory(_: *anyopaque, _: std.mem.Allocator, _: adapter.Adapter) void {}
    fn factory(self: *AsyncAdapter) adapter.Factory {
        return .{ .context = self, .vtable = &.{
            .discover = discoverFactory,
            .accountStatus = accountFactory,
            .resolveSelection = selection,
            .create = createFactory,
            .destroy = destroyFactory,
        } };
    }
};

test "async session evidence unlocks start and upstream chunks retain durable identity" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime: AsyncAdapter = .{};
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "async", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    owner.factory = runtime.factory();
    const sent = try owner.command(allocator, conversation.send("async-send", "hello", 1));
    try std.testing.expectEqual(.accepted, sent.outcome);
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged });
    try std.testing.expectEqual(@as(?domain.Owner.Claimed, null), try owner.claimNext(allocator));
    const session = sent.entity_ids.session.?;
    const opened: t.adapter.Observation = .{
        .correlation = .{ .session = session, .effect = open.id },
        .upstream_event = "instance:1:session",
        .body = .{ .session = .{ .id = session, .instance = .{ .value = "instance" }, .upstream = .{ .value = "upstream-session" } } },
    };
    try owner.observe(allocator, opened);
    try owner.observe(allocator, opened);
    const start = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
    const chunk: t.adapter.Observation = .{
        .correlation = .{ .session = session, .run = sent.entity_ids.run, .effect = start.id },
        .upstream_event = "instance:2:text",
        .body = .{ .chunk = .{ .message = .{ .value = "upstream-message" }, .block = .{ .value = "upstream-block" }, .offset = 0, .text = "世界" } },
    };
    try owner.observe(allocator, chunk);
    try owner.observe(allocator, chunk);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runtime_blocks"));
    try std.testing.expectEqual(@as(i64, 6), try f.store.scalar("SELECT committed_bytes FROM blocks WHERE id=(SELECT block_id FROM runtime_blocks)"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runtime_blocks rb JOIN blocks b ON b.id=rb.block_id JOIN messages m ON m.id=b.message_id WHERE m.role='assistant'"));
    try owner.recover();
    try std.testing.expectEqual(@as(?domain.Owner.Claimed, null), try owner.claimNext(allocator));
}

test "schema one conversation migrates runtime mapping without rewriting history" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("DROP TABLE runtime_blocks; DROP TABLE tasks; DROP TABLE bridge_calls; UPDATE meta SET schema_version=1; PRAGMA user_version=1");
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM messages WHERE id='m'"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM runtime_blocks"));
}

test "durable app task delegation deduplicates bounds and correlates out of order children" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "tasks", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const parent = try owner.command(allocator, conversation.send("task-parent", "coordinate", 1));
    const opened = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, opened.id, .{ .outcome = .acknowledged, .session = .{ .id = parent.entity_ids.session.?, .instance = .{ .value = "tasks" }, .upstream = .{ .value = "parent" } } });
    const started = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, started.id, .{ .outcome = .acknowledged });
    const packet: t.orchestration.Packet = .{
        .purpose = "first child",
        .prompt = "implement first",
        .selection = conversation.send("", "", 1).payload.thread_send.selection,
        .owned_paths = &.{"first.zig"},
        .acceptance = "deterministic result",
        .result_location = "evidence/first",
        .budget = .{ .max_elapsed_ms = 1000 },
    };
    var command: t.CommandEnvelope = .{ .command_id = .{ .value = "delegate-one" }, .target = .{ .run = parent.entity_ids.run.? }, .expected_revision = .{ .revision = 3 }, .payload = .{ .task_delegate = packet } };
    const first = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, first.outcome);
    const duplicate = try owner.command(allocator, command);
    try std.testing.expectEqualStrings(first.entity_ids.run.?.value, duplicate.entity_ids.run.?.value);
    command.command_id.value = "delegate-two";
    command.expected_revision.revision = 4;
    command.payload.task_delegate.owned_paths = &.{"second.zig"};
    command.payload.task_delegate.detached = true;
    const second = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, second.outcome);
    command.command_id.value = "delegate-over-capacity";
    command.expected_revision.revision = 5;
    command.payload.task_delegate.owned_paths = &.{"third.zig"};
    try std.testing.expectEqual(t.Reason.admission_limit, (try owner.command(allocator, command)).reason.?);
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM tasks"));
    // Dispatch the accepted children's independent durable effects, not a prose
    // delegation or a second in-memory task owner.
    while (try owner.claimNext(allocator)) |claim| {
        const session = if (claim.request == .open) claim.request.open.create.session else claim.request.start.correlation.session;
        try owner.delivered(allocator, claim.id, .{ .outcome = .acknowledged, .session = if (claim.request == .open) .{ .id = session, .instance = .{ .value = "tasks" }, .upstream = .{ .value = session.value } } else null });
    }
    const second_event: t.adapter.Observation = .{ .correlation = .{ .run = second.entity_ids.run, .session = second.entity_ids.session.? }, .upstream_event = "second-complete", .body = .completed };
    try owner.observe(allocator, second_event);
    try owner.observe(allocator, second_event);
    try owner.observe(allocator, .{ .correlation = .{ .run = first.entity_ids.run, .session = first.entity_ids.session.? }, .upstream_event = "first-failure", .body = .{ .failure = .{ .code = "test", .detail = "deterministic failure" } } });
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM tasks t JOIN runs r ON r.id=t.run_id WHERE r.state='completed'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM tasks t JOIN runs r ON r.id=t.run_id WHERE r.state='failed'"));
    const result = try owner.command(allocator, .{ .command_id = .{ .value = "first-result" }, .target = .{ .run = first.entity_ids.run.? }, .expected_revision = .{ .revision = 4 }, .payload = .{ .task_result = .{ .candidate = "candidate-sha", .evidence = "checks.log", .summary = "failed check" } } });
    try std.testing.expectEqual(.accepted, result.outcome);
    const review = try owner.command(allocator, .{ .command_id = .{ .value = "first-review" }, .target = .{ .run = first.entity_ids.run.? }, .expected_revision = .{ .revision = 5 }, .payload = .{ .task_review = .{ .candidate = "candidate-sha", .evidence = "checks.log", .disposition = .changes_requested } } });
    try std.testing.expectEqual(.accepted, review.outcome);
    try owner.recover();
    try std.testing.expectEqual(@as(?domain.Owner.Claimed, null), try owner.claimNext(allocator));
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM tasks"));
}

fn acknowledgeOpenAndStart(owner: *domain.Owner, allocator: std.mem.Allocator) !void {
    const open = (try owner.claimNext(allocator)).?;
    try std.testing.expect(open.request == .open);
    const session = open.request.open.create.session;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = session, .instance = .{ .value = "orchestration-fixture" }, .upstream = .{ .value = session.value } } });
    const start = (try owner.claimNext(allocator)).?;
    try std.testing.expect(start.request == .start);
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
}

test "bridge retries survive disk reopen without replaying ambiguous child effects" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "before", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const parent = try owner.command(allocator, conversation.send("parent", "coordinate", 1));
    try acknowledgeOpenAndStart(&owner, allocator);
    const packet: t.orchestration.Packet = .{ .purpose = "restart fixture", .prompt = "one child", .selection = conversation.send("", "", 1).payload.thread_send.selection, .owned_paths = &.{"restart.zig"}, .acceptance = "no replay", .result_location = "temporary evidence" };
    const args = try std.json.Stringify.valueAlloc(allocator, .{ .request_key = "delegate", .packet = packet }, .{});
    const first = try owner.toolCall(allocator, parent.entity_ids.session.?, "task.delegate", args);
    const delegated = try t.decode(t.Receipt, first.json, allocator);
    try std.testing.expect(first.success);
    const open = (try owner.claimNext(allocator)).?;
    try std.testing.expect(open.request == .open);
    // Crash after claiming the open, before any delivery receipt. The test does
    // not dispatch external work or invent a successful provider completion.
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&directory);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    owner.epoch = "after";
    try owner.recover();
    const sequence = (try f.store.position()).commit_sequence;
    const retry = try owner.toolCall(allocator, parent.entity_ids.session.?, "task.delegate", args);
    try std.testing.expectEqualStrings(first.json, retry.json);
    try std.testing.expectEqual(sequence, (try f.store.position()).commit_sequence);
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const wait_args = try std.json.Stringify.valueAlloc(allocator, .{ .task_id = delegated.entity_ids.run.?.value }, .{});
    const waited = try owner.toolCall(allocator, parent.entity_ids.session.?, "task.wait", wait_args);
    const rows = try t.decode([]t.Row, waited.json, allocator);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(.unknown, rows[0].task.state);
    try std.testing.expectEqualStrings(delegated.entity_ids.run.?.value, rows[0].task.task.id.value);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM tasks"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE state='unknown'"));
    try std.testing.expectError(error.ToolRequestConflict, owner.toolCall(allocator, parent.entity_ids.session.?, "task.cancel", try std.json.Stringify.valueAlloc(allocator, .{ .request_key = "delegate", .task_id = delegated.entity_ids.run.?.value, .reason = "conflicting retry" }, .{})));
    try std.testing.expectError(error.AuthorityUnavailable, owner.toolCall(allocator, parent.entity_ids.session.?, "task.delegate", try std.json.Stringify.valueAlloc(allocator, .{ .request_key = "new-after-crash", .packet = packet }, .{})));
    // Unknown work cannot be presented as an explicit successful result.
    const result: t.CommandEnvelope = .{ .command_id = .{ .value = "unknown-result" }, .target = .{ .run = delegated.entity_ids.run.? }, .expected_revision = .{ .revision = rows[0].task.revision }, .payload = .{ .task_result = .{ .candidate = "sha", .evidence = "log", .summary = "must not be accepted" } } };
    try std.testing.expectEqual(t.Reason.invalid_command, (try owner.command(allocator, result)).reason.?);
}

test "bridge validates exact arguments before reserving keys and selects newest coordinator turn" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "turns", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const parent = try owner.command(allocator, conversation.send("parent", "coordinate", 1));
    try acknowledgeOpenAndStart(&owner, allocator);
    const session = parent.entity_ids.session.?;
    try std.testing.expectError(error.InvalidToolArguments, owner.toolCall(allocator, session, "task.catalog", "{\"task_id\":\"ignored\"}"));
    try std.testing.expectError(error.InvalidToolArguments, owner.toolCall(allocator, session, "task.list", "{\"task_id\":\"ignored\"}"));
    try std.testing.expectError(error.InvalidToolArguments, owner.toolCall(allocator, session, "task.send", "{\"request_key\":\"invalid\",\"task_id\":\"child\",\"content\":\"message\",\"packet\":null}"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM bridge_calls"));
    // Stopped-app fixture: model an already persisted second coordinator turn
    // sharing its exact session. This is a bridge authority test, not provider
    // continuation or GUI evidence.
    try f.store.execute("UPDATE runs SET state='completed' WHERE id=?", &.{.{ .text = parent.entity_ids.run.?.value }});
    try f.store.execute("INSERT INTO runs(id,revision,thread_id,session_id,state,requested) SELECT 'newest-parent',1,thread_id,session_id,'streaming',requested FROM runs WHERE id=?", &.{.{ .text = parent.entity_ids.run.?.value }});
    const packet: t.orchestration.Packet = .{ .purpose = "latest parent", .prompt = "one child", .selection = conversation.send("", "", 1).payload.thread_send.selection, .owned_paths = &.{"latest.zig"}, .acceptance = "exact parent", .result_location = "temporary evidence" };
    const response = try owner.toolCall(allocator, session, "task.delegate", try std.json.Stringify.valueAlloc(allocator, .{ .request_key = "new-turn-delegate", .packet = packet }, .{}));
    try std.testing.expect(response.success);
    const listed = try owner.toolCall(allocator, session, "task.list", "{}");
    const rows = try t.decode([]t.Row, listed.json, allocator);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("newest-parent", rows[0].task.task.parent.value);
    try std.testing.expectEqualStrings("latest.zig", rows[0].task.task.packet.owned_paths[0]);
    const catalog = try owner.toolCall(allocator, session, "task.catalog", "{}");
    try std.testing.expectEqualStrings("[]", catalog.json);
}

test "indexed distant history pages retain boundaries cursors and exact source ranges" {
    const Host = @import("../domain.zig").Host;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    {
        var database = try storage.Store.open(std.testing.io, path_buffer[0..n]);
        defer database.close() catch @panic("close");
        try seed(&database);
        try database.exec("UPDATE runs SET state='completed'; WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<10000) INSERT INTO messages SELECT printf('message-%d',n),1,'h','r',n,'assistant',0 FROM numbers");
        try database.begin();
        var raw: [2048]u8 = undefined;
        for (&raw, 0..) |*byte, index| byte.* = @truncate(index);
        for (0..256) |index| _ = try database.appendChunk("b", index * raw.len, &raw);
        const imported = try std.testing.allocator.alloc(u8, 523183);
        defer std.testing.allocator.free(imported);
        for (imported, 0..) |*byte, index| byte.* = @truncate(index);
        try database.exec("INSERT INTO blocks(id,revision,message_id,ordinal,kind,committed_bytes) VALUES('large-import',1,'m',1,'text',524207)");
        try database.execute("INSERT INTO chunks VALUES('large-import',0,?)", &.{.{ .blob = imported }});
        const tail: [1024]u8 = @splat('z');
        try database.execute("INSERT INTO chunks VALUES('large-import',523183,?)", &.{.{ .blob = &tail }});
        const seek = try database.prepare("EXPLAIN QUERY PLAN SELECT byte_offset FROM chunks WHERE block_id=? AND byte_offset<=? ORDER BY byte_offset DESC LIMIT 1", &.{ .{ .text = "large-import" }, .{ .integer = 100000 } });
        defer seek.deinit();
        try std.testing.expect(try seek.step());
        try std.testing.expect(std.mem.indexOf(u8, try seek.bytes(3), "SEARCH") != null);
        // Model an explicit independent/older importer, not Store's current
        // 1MiB writer-value admission cap. Snapshot reads must remain bounded.
        _ = c.sqlite3_limit(database.database, c.SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024);
        try database.exec("INSERT INTO blocks(id,revision,message_id,ordinal,kind,committed_bytes) VALUES('huge-import',1,'m',2,'text',16777216); INSERT INTO chunks VALUES('huge-import',0,zeroblob(16777216))");
        try database.commit();
    }
    var consumer: Consumer = .{ .host = undefined, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    defer consumer.host.destroy();
    const latest = try consumer.query(.{ .messages = .{ .thread = .{ .value = "h" }, .direction = .older, .page = .{ .limit = 32 } } });
    try std.testing.expectEqual(@as(u64, 10000), latest.items[0].message.ordinal);
    try std.testing.expectEqual(@as(u64, 9969), latest.items[31].message.ordinal);
    const continued = try consumer.query(.{ .messages = .{ .thread = .{ .value = "h" }, .direction = .older, .page = .{ .limit = 32, .snapshot = latest.snapshot_id, .cursor = latest.next_cursor.? } } });
    try std.testing.expectEqual(@as(u64, 9968), continued.items[0].message.ordinal);
    const distant = try consumer.query(.{ .messages = .{ .thread = .{ .value = "h" }, .anchor = .{ .value = "message-5000" }, .direction = .newer, .page = .{ .limit = 1 } } });
    try std.testing.expectEqual(@as(u64, 5001), distant.items[0].message.ordinal);
    const oldest = try consumer.query(.{ .messages = .{ .thread = .{ .value = "h" }, .anchor = .{ .value = "message-1" }, .direction = .older, .page = .{ .limit = 1 } } });
    try std.testing.expectEqual(@as(u64, 0), oldest.items[0].message.ordinal);
    try std.testing.expect(oldest.next_cursor == null);
    const end = try consumer.query(.{ .messages = .{ .thread = .{ .value = "h" }, .anchor = .{ .value = "m" }, .direction = .older } });
    try std.testing.expectEqual(@as(usize, 0), end.items.len);
    const range = try consumer.query(.{ .content = .{ .block = .{ .value = "b" }, .start_byte = 500001, .end_byte = 504097 } });
    for (range.items[0].content.bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(500001 + index)), byte);
    _ = try consumer.host.query(.{ .messages = .{ .thread = .{ .value = "h" }, .anchor = .{ .value = "missing" } } });
    const missing = try consumer.next();
    try std.testing.expectEqual(.not_found, missing.failure.failure.reason);
    _ = try consumer.host.query(.{ .messages = .{ .thread = .{ .value = "h" }, .page = .{ .cursor = "malformed" } } });
    const invalid = try consumer.next();
    try std.testing.expectEqual(.cursor_invalid, invalid.failure.failure.reason);
    // Several newer roots have evicted this paused snapshot deterministically.
    _ = try consumer.host.query(.{ .content = .{ .block = .{ .value = "b" }, .start_byte = 500001, .end_byte = 504097, .page = .{ .snapshot = latest.snapshot_id } } });
    const expired = try consumer.next();
    try std.testing.expectEqual(.cursor_invalid, expired.failure.failure.reason);
    const fresh = try consumer.query(.{ .blocks = .{ .message = .{ .value = "m" } } });
    try std.testing.expectEqualStrings("b", fresh.items[0].block.block_id.value);
    const restored = try consumer.query(.{ .content = .{ .block = fresh.items[0].block.block_id, .start_byte = 500001, .end_byte = 504097, .page = .{ .snapshot = fresh.snapshot_id } } });
    try std.testing.expectEqualSlices(u8, range.items[0].content.bytes, restored.items[0].content.bytes);
    const interior = try consumer.query(.{ .content = .{ .block = .{ .value = "large-import" }, .start_byte = 100000, .end_byte = 104096 } });
    for (interior.items[0].content.bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(100000 + index)), byte);
    const crossing = try consumer.query(.{ .content = .{ .block = .{ .value = "large-import" }, .start_byte = 522111, .end_byte = 524000 } });
    for (crossing.items[0].content.bytes, 0..) |byte, index| try std.testing.expectEqual(if (522111 + index < 523183) @as(u8, @truncate(522111 + index)) else @as(u8, 'z'), byte);
    var heap_before: i64 = 0;
    var heap_peak: i64 = 0;
    try storage.check(c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &heap_before, &heap_peak, 1));
    const bounded = try consumer.query(.{ .content = .{ .block = .{ .value = "huge-import" }, .start_byte = 8000000, .end_byte = 8004096 } });
    try std.testing.expectEqual(@as(usize, 4096), bounded.items[0].content.bytes.len);
    for (bounded.items[0].content.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    var heap_after: i64 = 0;
    try storage.check(c.sqlite3_status64(c.SQLITE_STATUS_MEMORY_USED, &heap_after, &heap_peak, 0));
    const query_peak = heap_peak - heap_before;
    std.debug.print("incremental blob 16MiB/4KiB query SQLite peak delta={d} bytes\n", .{query_peak});
    try std.testing.expect(query_peak < 4 * 1024 * 1024);
}

fn completeInitialTurn(owner: *domain.Owner, allocator: std.mem.Allocator, conversation: Conversation) !t.Receipt {
    const sent = try owner.command(allocator, conversation.send("initial-turn", "retain this context", 1));
    try std.testing.expectEqual(.accepted, sent.outcome);
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "initial-process" }, .upstream = .{ .value = "retained-context" } } });
    const start = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
    try owner.observe(allocator, .{ .correlation = start.request.start.correlation, .upstream_event = "initial-completed", .body = .completed });
    return sent;
}

test "queued and claimed continuation opens stay dormant after recovery including old read-only journals" {
    for (0..3) |scenario| {
        var f = try Fixture.init();
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "before", .utc_ms = 1 };
        const conversation = try Conversation.create(&owner, allocator);
        const first = try completeInitialTurn(&owner, allocator, conversation);
        const command = conversation.send("second-turn", "never replay this prompt", 2);
        const second = try owner.command(allocator, command);
        try std.testing.expectEqual(.accepted, second.outcome);
        try std.testing.expectEqualStrings(first.entity_ids.session.?.value, second.entity_ids.session.?.value);
        // SQLite needs the exact partial-index predicate; kind='start' alone
        // otherwise scans all historical effects for every compatibility probe.
        const plan = try f.store.prepare("EXPLAIN QUERY PLAN SELECT 1 FROM effects continuation WHERE continuation.run_id=? AND continuation.kind IN('create_session','start','cancel') AND continuation.kind='start' AND continuation.depends_on=?", &.{ .{ .text = second.entity_ids.run.?.value }, .{ .text = second.effect_ids[0].value } });
        {
            defer plan.deinit();
            try std.testing.expect(try plan.step());
            try std.testing.expect(std.mem.indexOf(u8, try plan.bytes(3), "SEARCH continuation USING INDEX one_effect") != null);
        }
        try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='attach' AND read_only=1"));
        // Simulate the prior durable classification, not application input.
        if (scenario != 0) try f.store.exec("UPDATE effects SET read_only=1 WHERE kind='attach'");
        if (scenario == 2) {
            const attach = (try owner.claimNext(allocator)).?;
            try std.testing.expectEqualStrings("retained-context", attach.request.open.existing.session.upstream.value);
        }
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try allocator.dupe(u8, try f.path(&path_buffer));
        try f.store.close();
        f.store = try storage.Store.open(std.testing.io, path);
        owner.epoch = "after";
        try owner.recover();
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        const state = try f.store.prepare("SELECT state FROM runs WHERE id=?", &.{.{ .text = second.entity_ids.run.?.value }});
        {
            defer state.deinit();
            try std.testing.expect(try state.step());
            try std.testing.expectEqualStrings(if (scenario == 2) "unknown" else "interrupted", try state.bytes(0));
        }
        const replay = try owner.command(allocator, command);
        try std.testing.expectEqual(second.commit_sequence, replay.commit_sequence);
        try std.testing.expectEqualStrings(second.entity_ids.run.?.value, replay.entity_ids.run.?.value);
        const refused = try owner.command(allocator, conversation.send("new-attempt", "still unresolved", 3));
        try std.testing.expectEqual(t.Reason.unresolved_effects, refused.reason.?);
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='create_session'"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='start' AND state='planned'"));
    }
}

test "failed resume permits only an explicit retry of the same context and waits for session evidence" {
    for ([_]bool{ false, true }) |synchronous_rejection| {
        var f = try Fixture.init();
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "resume", .utc_ms = 1 };
        owner.factory = @import("fake_factory.zig").factory(&owner);
        const conversation = try Conversation.create(&owner, allocator);
        const first = try completeInitialTurn(&owner, allocator, conversation);
        const second = try owner.command(allocator, conversation.send("second-turn", "resume existing", 2));
        try std.testing.expectEqual(.accepted, second.outcome);
        const attach = (try owner.claimNext(allocator)).?;
        try std.testing.expect(attach.request.open == .existing);
        // A transport acknowledgement cannot release the prompt before resume has
        // actually succeeded, and a replacement context is never accepted.
        try owner.delivered(allocator, attach.id, .{ .outcome = .acknowledged });
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        var replacement: t.adapter.Observation = .{ .correlation = .{ .session = second.entity_ids.session.? }, .upstream_event = "wrong-resume", .body = .{ .session = .{ .id = second.entity_ids.session.?, .instance = .{ .value = "replacement-process" }, .upstream = .{ .value = "contextless-replacement" } } } };
        try std.testing.expectError(error.Conflict, owner.observe(allocator, replacement));
        try std.testing.expectError(error.Conflict, owner.delivered(allocator, attach.id, .{ .outcome = .acknowledged, .session = replacement.body.session }));
        if (synchronous_rejection) {
            try owner.delivered(allocator, attach.id, .{ .outcome = .rejected, .detail = "retained context temporarily unavailable" });
        } else {
            try owner.observe(allocator, .{ .correlation = .{ .session = second.entity_ids.session.? }, .upstream_event = "resume-failed", .body = .{ .failure = .{ .code = "session_resume_failed", .detail = "retained context temporarily unavailable" } } });
        }
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='start' AND state='withdrawn'"));
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try allocator.dupe(u8, try f.path(&path_buffer));
        try f.store.close();
        f.store = try storage.Store.open(std.testing.io, path);
        owner.epoch = "retry-after-restart";
        try owner.recover();
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        const third_command = conversation.send("explicit-retry", "retry same context", 3);
        const third = try owner.command(allocator, third_command);
        try std.testing.expectEqual(.accepted, third.outcome);
        try std.testing.expectEqualStrings(first.entity_ids.session.?.value, third.entity_ids.session.?.value);
        const retry = (try owner.claimNext(allocator)).?;
        try std.testing.expect(retry.request.open == .existing);
        try std.testing.expectEqualStrings("retained-context", retry.request.open.existing.session.upstream.value);
        try owner.delivered(allocator, retry.id, .{ .outcome = .acknowledged });
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        replacement.correlation = .{ .session = third.entity_ids.session.? };
        replacement.upstream_event = "same-context-resumed";
        replacement.body.session.upstream.value = "retained-context";
        try owner.observe(allocator, replacement);
        const start = (try owner.claimNext(allocator)).?;
        try std.testing.expect(start.request == .start);
        try std.testing.expectEqualStrings(third.entity_ids.run.?.value, start.request.start.correlation.run.?.value);
        const prompt_ref = start.request.start.prompt_ref.?;
        var prompt_buffer: [64 * 1024]u8 = undefined;
        try std.testing.expectEqualStrings("retry same context", try @import("prompts.zig").readBlock(&f.store, prompt_ref.id, prompt_ref, &prompt_buffer));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM sessions"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='create_session'"));
        try std.testing.expectEqual(@as(i64, 6), try f.store.scalar("SELECT count(*) FROM messages"));
    }
}

test "late resume delivery cannot revive ambiguous work or release its dependent prompt" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "late-resume", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    _ = try completeInitialTurn(&owner, allocator, conversation);
    const second = try owner.command(allocator, conversation.send("second-turn", "do not replay", 2));
    const attach = (try owner.claimNext(allocator)).?;
    try owner.observe(allocator, .{ .correlation = .{ .session = second.entity_ids.session.?, .run = second.entity_ids.run.? }, .upstream_event = "lost-resume", .body = .{ .ambiguous = .{ .reason = "resume outcome unknown" } } });
    try owner.delivered(allocator, attach.id, .{ .outcome = .acknowledged, .session = attach.request.open.existing.session, .continuity = .proven });
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='unknown'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='start' AND state='planned'"));
}

test "rejected initial open withdraws dependent work and requires an explicit new thread" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "initial-rejection", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    const command = conversation.send("initial-turn", "unpublished context", 1);
    const first = try owner.command(allocator, command);
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .rejected, .detail = "definitive initial open rejection" });
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM effects WHERE state IN('planned','in_flight','unknown')"));
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try allocator.dupe(u8, try f.path(&path_buffer));
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    owner.epoch = "initial-rejection-reopened";
    try owner.recover();
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const replay = try owner.command(allocator, command);
    try std.testing.expectEqual(first.commit_sequence, replay.commit_sequence);
    try std.testing.expectEqualStrings(first.entity_ids.run.?.value, replay.entity_ids.run.?.value);
    const refused = try owner.command(allocator, conversation.send("second-turn", "must not lose first prompt", 2));
    try std.testing.expectEqual(t.Reason.session_unavailable, refused.reason.?);
    const thread = (try owner.command(allocator, .{ .command_id = .{ .value = "new-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = conversation.project, .workspace = conversation.workspace } } })).entity_ids.thread.?;
    var fresh = conversation;
    fresh.thread = thread;
    const second = try owner.command(allocator, fresh.send("new-context", "explicit fresh conversation", 1));
    try std.testing.expectEqual(.accepted, second.outcome);
    try std.testing.expect(!t.adapter.equal(first.entity_ids.session.?, second.entity_ids.session.?));
    try std.testing.expect((try owner.claimNext(allocator)).?.request.open == .create);
}

test "staged Send has no effects before durable completion and verifies content on reopen" {
    const prompts = @import("prompts.zig");
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "upload", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    const text = ("a" ** 2047) ++ "€" ++ ("\x01" ** 63486);
    const ref = prompts.reference("complete-send", text);
    try prompts.begin(&f.store, ref);
    try prompts.append(&f.store, ref, 0, text[0..2048]);
    var buffer: [prompts.max_bytes]u8 = undefined;
    try std.testing.expectError(error.PromptIncomplete, prompts.complete(&f.store, ref, &buffer));
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const selection = conversation.send("", "", 1).payload.thread_send.selection;
    const incomplete: t.CommandEnvelope = .{ .command_id = .{ .value = "incomplete-command" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send_staged = .{ .prompt = ref, .selection = selection } } };
    const refused = try owner.command(allocator, incomplete);
    try std.testing.expectEqual(t.Reason.prompt_incomplete, refused.reason.?);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM effects"));
    // A definitive refusal releases only the matching reservation.
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM prompt_uploads"));
    try prompts.begin(&f.store, ref);
    try prompts.append(&f.store, ref, 0, text[0..2048]);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    try owner.recover();
    var offset: usize = 2048;
    while (offset < text.len) : (offset += 2048) try prompts.append(&f.store, ref, offset, text[offset..@min(text.len, offset + 2048)]);
    try prompts.complete(&f.store, ref, &buffer);
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const replay = try owner.command(allocator, incomplete);
    try std.testing.expectEqual(refused.commit_sequence, replay.commit_sequence);
    var complete = incomplete;
    complete.command_id.value = "complete-command";
    const receipt = try owner.command(allocator, complete);
    try std.testing.expectEqual(.accepted, receipt.outcome);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM prompt_uploads"));
    const s = try f.store.prepare("SELECT request FROM effects WHERE kind='start'", &.{});
    {
        defer s.deinit();
        try std.testing.expect(try s.step());
        const bytes = try s.bytes(0);
        try std.testing.expect(bytes.len < 2048);
        const request = try t.decode(t.adapter.Request, bytes, allocator);
        try std.testing.expectEqualStrings("", request.start.prompt);
        const committed_ref = request.start.prompt_ref.?;
        try std.testing.expectEqualStrings(text, try prompts.readBlock(&f.store, committed_ref.id, committed_ref, &buffer));
        // Prefix-only title/history queries do not participate in Start loading.
        try f.store.execute("DELETE FROM chunks WHERE block_id=? AND byte_offset=2048", &.{.{ .text = committed_ref.id }});
        try std.testing.expectError(error.InvalidPrompt, prompts.readBlock(&f.store, committed_ref.id, committed_ref, &buffer));
    }
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM commands WHERE command_id='complete-command' AND length(canonical)<2048"));
}

test "invalid UTF8 prompt is durably refused without provider effects" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "invalid", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, arena.allocator());
    const command = conversation.send("invalid", "\xf0\x9f", 1);
    const receipt = try owner.command(arena.allocator(), command);
    try std.testing.expectEqual(t.Reason.invalid_command, receipt.reason.?);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM effects"));
    try std.testing.expectEqual(receipt.commit_sequence, (try owner.command(arena.allocator(), command)).commit_sequence);
}

test "schema 4 inline Send retry retains original receipt before reserving prompt staging" {
    const prompts = @import("prompts.zig");
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "upgrade", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    var command = conversation.send("prior-send", "retained café 世界", 1);
    const original = try owner.command(allocator, command);
    // Reconstruct only the older journal representation in this disposable
    // fixture. Reopening performs the actual version 4 -> 5 store migration.
    var buffer: [65536]u8 = undefined;
    const canonical = try t.encode(command, &buffer);
    try f.store.execute("UPDATE commands SET canonical=?,digest=? WHERE command_id='prior-send'", &.{ .{ .blob = canonical }, .{ .blob = &t.digest(canonical) } });
    try f.store.exec("DROP TABLE prompt_chunks; DROP TABLE prompt_uploads; UPDATE meta SET schema_version=4; PRAGMA user_version=4");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    for ([_][]const u8{ "one", "two", "three", "four" }) |id| try prompts.begin(&f.store, prompts.reference(id, "x"));
    const replay = try owner.command(allocator, command);
    try std.testing.expectEqual(original.commit_sequence, replay.commit_sequence);
    try std.testing.expectEqual(original.outcome, replay.outcome);
    try std.testing.expectEqual(@as(i64, 4), try f.store.scalar("SELECT count(*) FROM prompt_uploads"));
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM effects"));
    command.payload.thread_send.text = "changed";
    try std.testing.expectEqual(t.Reason.command_id_conflict, (try owner.command(allocator, command)).reason.?);
}
