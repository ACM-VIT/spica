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
        "INSERT INTO workspaces VALUES('w',1,'p',X'7b2263616e6f6e6963616c5f726f6f74223a222f746d70222c2266696c6573797374656d5f6964656e74697479223a22222c227265706f7369746f72795f6964656e74697479223a22222c22636865636b6f75745f6964656e74697479223a22222c2265787065637465645f6272616e6368223a22222c22626173655f7265766973696f6e223a22222c226e6f6e5f676974223a747275657d');" ++
        "INSERT INTO sessions(id,revision,workspace_id,selection) VALUES('s',1,'w',X'7b7d');" ++
        "INSERT INTO threads(id,revision,project_id,workspace_id,session_id,root_key) VALUES('h',1,'p','w','s',X'e9671acd244849c57167c658fa2f969752048f7ab184a3dcf5c46cb4d56ae124');" ++
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

test "durable attachment boundary validates digest, keeps bytes out of effects, and binds immutably" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "attachments", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    var runtime: AsyncAdapter = .{};
    owner.factory = runtime.factory();
    const bytes = try allocator.alloc(u8, 256 * 1024);
    @memset(bytes, 0x5a);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var digest_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&digest_hex, "{s}", .{std.fmt.bytesToHex(digest, .lower)}) catch unreachable;
    const add = try owner.command(allocator, .{ .command_id = .{ .value = "attachment-add" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .attachment_add = .{ .metadata = .{ .id = .{ .value = "a1" }, .name = "blob.txt", .media_type = "text/plain", .byte_length = bytes.len, .digest = &digest_hex }, .content = bytes } } });
    try std.testing.expectEqual(.accepted, add.outcome);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM attachments WHERE id='a1' AND length(content)=262144"));
    const bad = try owner.command(allocator, .{ .command_id = .{ .value = "attachment-bad" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .attachment_add = .{ .metadata = .{ .id = .{ .value = "bad" }, .name = "bad.txt", .media_type = "text/plain", .byte_length = 1, .digest = &digest_hex }, .content = "x" } } });
    try std.testing.expectEqual(.rejected, bad.outcome);
    try std.testing.expectEqual(.attachment_limit, bad.reason.?);
    const send = try owner.command(allocator, .{ .command_id = .{ .value = "attachment-send" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "read this", .selection = .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "fixture", .effort = "none", .account_ref = "local", .workspace = conversation.workspace }, .attachments = &.{.{ .value = "a1" }} } } });
    try std.testing.expectEqual(.accepted, send.outcome);
    const start_effect = try f.store.prepare("SELECT request FROM effects WHERE kind='start'", &.{});
    defer start_effect.deinit();
    try std.testing.expect(try start_effect.step());
    try std.testing.expect(std.mem.indexOf(u8, try start_effect.bytes(0), "5a5a5a") == null);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM attachment_refs"));
    const remove = try owner.command(allocator, .{ .command_id = .{ .value = "attachment-remove" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 3 }, .payload = .{ .attachment_remove = .{ .value = "a1" } } });
    try std.testing.expectEqual(.rejected, remove.outcome);
    try std.testing.expectEqual(.busy, remove.reason.?);
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
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE id='h' AND title='' AND revision=1"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM messages WHERE id='m'"));
}

test "sidebar metadata is orthogonal revisioned idempotent and durable" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "sidebar", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const command: t.CommandEnvelope = .{ .command_id = .{ .value = "sidebar-pin" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_set = .{ .pinned = true, .settled = true, .snoozed_until = 5000 } } };
    const first = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, first.outcome);
    try std.testing.expectEqual(@as(usize, 1), first.committed_revisions.len);
    try std.testing.expectEqual(@as(u64, 2), first.committed_revisions[0].revision);
    const retry = try owner.command(allocator, command);
    try std.testing.expectEqual(first.commit_sequence, retry.commit_sequence);
    var stale = command;
    stale.command_id.value = "sidebar-stale";
    try std.testing.expectEqual(t.Reason.revision_conflict, (try owner.command(allocator, stale)).reason.?);
    var conflict = command;
    conflict.payload.thread_sidebar_set.pinned = false;
    try std.testing.expectEqual(t.Reason.command_id_conflict, (try owner.command(allocator, conflict)).reason.?);
    const cleared = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-wake" }, .target = command.target, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_sidebar_set = .{ .pinned = true, .clear_snooze = true } } });
    try std.testing.expectEqual(.accepted, cleared.outcome);
    const invalid = [_]@FieldType(t.Payload, "thread_sidebar_set"){ .{}, .{ .snoozed_until = -1 }, .{ .snoozed_until = 1000 }, .{ .snoozed_until = 5000, .clear_snooze = true } };
    for (invalid, 0..) |payload, index| {
        const rejected = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "sidebar-invalid-{d}", .{index}) }, .target = command.target, .expected_revision = .{ .revision = 3 }, .payload = .{ .thread_sidebar_set = payload } });
        try std.testing.expectEqual(t.Reason.invalid_command, rejected.reason.?);
    }
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadSidebarChanged'"));
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    const stored = try f.store.prepare("SELECT pinned,settled,snoozed_until,revision,sort_order FROM threads WHERE id=?", &.{.{ .text = conversation.thread.value }});
    defer stored.deinit();
    try std.testing.expect(try stored.step());
    try std.testing.expectEqual(@as(i64, 1), stored.integer(0));
    try std.testing.expectEqual(@as(i64, 1), stored.integer(1));
    try std.testing.expectEqual(@as(i64, 0), stored.integer(2));
    try std.testing.expectEqual(@as(i64, 3), stored.integer(3));
    try std.testing.expectEqual(@as(i64, -1024), stored.integer(4));
    try std.testing.expectEqual(first.commit_sequence, (try owner.command(allocator, command)).commit_sequence);
}

test "sidebar snooze refuses queued starts and input waits without touching provider state" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "sidebar-live", .utc_ms = 1000 };
    const states = [_][]const u8{ "queued", "starting", "awaiting_approval", "awaiting_question" };
    for (states, 0..) |state, index| {
        try f.store.execute("UPDATE runs SET state=? WHERE id='r'", &.{.{ .text = state }});
        const rejected = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "sidebar-live-{d}", .{index}) }, .target = .{ .thread = .{ .value = "h" } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_set = .{ .pinned = true, .snoozed_until = 5000 } } });
        try std.testing.expectEqual(t.Reason.busy, rejected.reason.?);
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE revision=1 AND pinned=0 AND snoozed_until=0"));
        const run = try f.store.prepare("SELECT state,revision FROM runs WHERE id='r'", &.{});
        defer run.deinit();
        try std.testing.expect(try run.step());
        try std.testing.expectEqualStrings(state, try run.bytes(0));
        try std.testing.expectEqual(@as(i64, 1), run.integer(1));
    }
    const pinned = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-pin-live" }, .target = .{ .thread = .{ .value = "h" } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_set = .{ .pinned = true } } });
    try std.testing.expectEqual(.accepted, pinned.outcome);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM effects"));
}

test "sidebar snooze accepts running and uncertain runs as metadata only" {
    for ([_][]const u8{ "streaming", "cancel_requested", "unknown", "interrupted", "completed", "failed" }) |state| {
        var f = try Fixture.init();
        defer f.deinit();
        try seed(&f.store);
        try f.store.execute("UPDATE runs SET state=? WHERE id='r'", &.{.{ .text = state }});
        try effect(&f.store, "unresolved-effect", "unknown", "start");
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "snooze-live", .utc_ms = 1000 };
        const accepted = try owner.command(arena.allocator(), .{ .command_id = .{ .value = "snooze-running" }, .target = .{ .thread = .{ .value = "h" } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_set = .{ .snoozed_until = 5000 } } });
        try std.testing.expectEqual(.accepted, accepted.outcome);
        try std.testing.expectEqual(@as(usize, 0), accepted.effect_ids.len);
        try std.testing.expectEqual(@as(i64, 5000), try f.store.scalar("SELECT snoozed_until FROM threads"));
        const run = try f.store.prepare("SELECT state,revision FROM runs", &.{});
        defer run.deinit();
        try std.testing.expect(try run.step());
        try std.testing.expectEqualStrings(state, try run.bytes(0));
        try std.testing.expectEqual(@as(i64, 1), run.integer(1));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE id='unresolved-effect' AND revision=1 AND state='unknown'"));
    }
}

test "schema12 input ownership migration preserves revisions and events and uses thread pending indexes" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("INSERT INTO events VALUES(1,0,'migration-event',X'7b7d',1,'BeforeMigration',NULL,NULL,X'7b7d'); DROP TRIGGER approvals_owner_insert; DROP TRIGGER approvals_owner_immutable; DROP TRIGGER questions_owner_insert; DROP TRIGGER questions_owner_immutable; DROP INDEX approvals_pending_thread; DROP INDEX questions_pending_thread; ALTER TABLE approvals DROP COLUMN thread_id; ALTER TABLE questions DROP COLUMN thread_id; UPDATE meta SET schema_version=11; PRAGMA user_version=11");
    const position = try f.store.position();
    try f.store.close();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_path = try f.path(&path);
    f.store = try storage.Store.open(std.testing.io, directory_path);
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(position, try f.store.position());
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE event_id='migration-event'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT revision FROM threads WHERE id='h'"));
    var plan = try f.store.prepare("EXPLAIN QUERY PLAN SELECT 1 FROM approvals WHERE state='pending' AND thread_id=?", &.{.{ .text = "h" }});
    defer plan.deinit();
    var indexed = false;
    while (try plan.step()) {
        if (std.mem.indexOf(u8, try plan.bytes(3), "approvals_pending_thread") != null) indexed = true;
    }
    try std.testing.expect(indexed);
}

test "pending input ownership is immutable and rejects cross-thread inserts" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("INSERT INTO projects VALUES('p2',1,'second'); INSERT INTO threads(id,revision,project_id,workspace_id,session_id,root_key,sort_order) VALUES('h2',1,'p2','w','s',X'e9671acd244849c57167c658fa2f969752048f7ab184a3dcf5c46cb4d56ae124',-2048)");
    try f.store.execute("INSERT INTO questions(id,revision,run_id,thread_id,session_id,question,state,live_epoch) VALUES(?,1,?,?,?,?,?,?)", &.{ .{ .text = "q-owner" }, .{ .text = "r" }, .{ .text = "h" }, .{ .text = "s" }, .{ .blob = "{}" }, .{ .text = "pending" }, .{ .text = "epoch" } });
    try std.testing.expectError(storage.Error.Conflict, f.store.execute("UPDATE questions SET thread_id='h2' WHERE id='q-owner'", &.{}));
    try std.testing.expectError(storage.Error.Conflict, f.store.execute("INSERT INTO questions(id,revision,run_id,thread_id,session_id,question,state,live_epoch) VALUES('q-bad',1,'r','h2','s',X'7b7d','pending','epoch')", &.{}));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE id='h' AND revision=1 AND snoozed_until=0 AND EXISTS(SELECT 1 FROM questions WHERE thread_id=threads.id AND state='pending')"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE id='h2' AND NOT EXISTS(SELECT 1 FROM questions WHERE thread_id=threads.id AND state='pending')"));
}

test "sidebar move swaps global neighbors atomically and reports both revisions" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "sidebar-order", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const second = (try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-second" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = conversation.project, .workspace = conversation.workspace } } })).entity_ids.thread.?;
    const command: t.CommandEnvelope = .{ .command_id = .{ .value = "sidebar-move" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_move = .{ .direction = .up } } };
    const moved = try owner.command(allocator, command);
    try std.testing.expectEqual(.accepted, moved.outcome);
    try std.testing.expectEqual(@as(usize, 2), moved.committed_revisions.len);
    for (moved.committed_revisions) |revision| try std.testing.expectEqual(@as(u64, 2), revision.revision);
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadSidebarChanged'"));
    try std.testing.expectEqual(moved.commit_sequence, (try owner.command(allocator, command)).commit_sequence);
    const row = try f.store.prepare("SELECT id FROM threads ORDER BY sort_order,id", &.{});
    defer row.deinit();
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings(conversation.thread.value, try row.bytes(0));
    try std.testing.expect(try row.step());
    try std.testing.expectEqualStrings(second.value, try row.bytes(0));
    const edge = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-edge" }, .target = command.target, .expected_revision = .{ .revision = 2 }, .payload = command.payload });
    try std.testing.expectEqual(t.Reason.invalid_command, edge.reason.?);
    try f.store.exec("UPDATE threads SET sort_order=0");
    const tied = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-tied" }, .target = command.target, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_sidebar_move = .{ .direction = .down } } });
    try std.testing.expectEqual(t.Reason.invalid_command, tied.reason.?);
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM threads WHERE revision=2"));
}

test "sidebar schema eight migration preserves execution revisions and creates ordered indexes" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("DROP INDEX threads_sidebar_order; DROP INDEX threads_project_sidebar_order; DROP INDEX threads_sidebar_move; DROP INDEX threads_root_order; DROP INDEX threads_root_project_order; DROP TRIGGER threads_root_immutable; ALTER TABLE threads DROP COLUMN pinned; ALTER TABLE threads DROP COLUMN settled; ALTER TABLE threads DROP COLUMN snoozed_until; ALTER TABLE threads DROP COLUMN sort_order; UPDATE meta SET schema_version=8; PRAGMA user_version=8");
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE id='h' AND revision=1 AND pinned=0 AND settled=0 AND snoozed_until=0 AND sort_order=-1024"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE id='r' AND revision=1 AND state='queued'"));
    const plans = [_][:0]const u8{
        "EXPLAIN QUERY PLAN SELECT id FROM threads WHERE (-pinned,sort_order,id)>(-2,0,'') ORDER BY -pinned,sort_order,id LIMIT 8",
        "EXPLAIN QUERY PLAN SELECT id FROM threads WHERE project_id='p' AND (-pinned,sort_order,id)>(-2,0,'') ORDER BY -pinned,sort_order,id LIMIT 8",
    };
    for (plans, [_][]const u8{ "threads_sidebar_order", "threads_project_sidebar_order" }) |sql, index| {
        const plan = try f.store.prepare(sql, &.{});
        defer plan.deinit();
        try std.testing.expect(try plan.step());
        try std.testing.expect(std.mem.indexOf(u8, try plan.bytes(3), index) != null);
    }
}

test "thread card timestamps use known command clocks and preserve latest user message time" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "sidebar-time", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    owner.utc_ms = 2000;
    const title = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-time-title" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_title_set = .{ .title = "Actual time" } } });
    try std.testing.expectEqual(.accepted, title.outcome);
    owner.utc_ms = 3000;
    const send = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-time-send" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "actual user message", .selection = t.adapter.fakeSelection(conversation.workspace) } } });
    try std.testing.expectEqual(.accepted, send.outcome);
    owner.utc_ms = 4000;
    const pin = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-time-pin" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 3 }, .payload = .{ .thread_sidebar_set = .{ .pinned = true } } });
    try std.testing.expectEqual(.accepted, pin.outcome);
    owner.utc_ms = null;
    const unpin = try owner.command(allocator, .{ .command_id = .{ .value = "sidebar-time-unpin" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 4 }, .payload = .{ .thread_sidebar_set = .{ .pinned = false } } });
    try std.testing.expectEqual(.accepted, unpin.outcome);
    const stored = try f.store.prepare("SELECT created_at_ms,last_user_message_at_ms,updated_at_ms FROM threads WHERE id=?", &.{.{ .text = conversation.thread.value }});
    defer stored.deinit();
    try std.testing.expect(try stored.step());
    try std.testing.expectEqual(@as(i64, 1000), stored.integer(0));
    try std.testing.expectEqual(@as(i64, 3000), stored.integer(1));
    try std.testing.expectEqual(@as(i64, 4000), stored.integer(2));
}

test "schema nine timestamp migration leaves historic ages unknown" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("ALTER TABLE threads DROP COLUMN created_at_ms; ALTER TABLE threads DROP COLUMN last_user_message_at_ms; ALTER TABLE threads DROP COLUMN updated_at_ms; UPDATE meta SET schema_version=9; PRAGMA user_version=9");
    try f.store.close();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    f.store = try storage.Store.open(std.testing.io, try f.path(&directory));
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM threads WHERE id='h' AND revision=1 AND created_at_ms=0 AND last_user_message_at_ms=0 AND updated_at_ms=0"));
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

test "root scoped sidebar navigation is bounded cyclic and fail closed" {
    const Host = @import("../domain.zig").Host;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    {
        var database = try storage.Store.open(std.testing.io, path_buffer[0..n]);
        defer database.close() catch @panic("close");
        try database.exec(
            "INSERT INTO projects VALUES('p1',1,'one'); INSERT INTO projects VALUES('p2',1,'two');" ++
                "INSERT INTO workspaces VALUES('w1',1,'p1',X'7b2263616e6f6e6963616c5f726f6f74223a222f746d70222c2266696c6573797374656d5f6964656e74697479223a22222c227265706f7369746f72795f6964656e74697479223a22222c22636865636b6f75745f6964656e74697479223a22222c2265787065637465645f6272616e6368223a22222c22626173655f7265766973696f6e223a22222c226e6f6e5f676974223a747275657d');" ++
                "INSERT INTO workspaces VALUES('w2',1,'p2',X'7b2263616e6f6e6963616c5f726f6f74223a222f746d70222c2266696c6573797374656d5f6964656e74697479223a22222c227265706f7369746f72795f6964656e74697479223a22222c22636865636b6f75745f6964656e74697479223a22222c2265787065637465645f6272616e6368223a22222c22626173655f7265766973696f6e223a22222c226e6f6e5f676974223a747275657d');" ++
                "INSERT INTO workspaces VALUES('w3',1,'p1',X'7b2263616e6f6e6963616c5f726f6f74223a222f666f726569676e222c2266696c6573797374656d5f6964656e74697479223a22222c227265706f7369746f72795f6964656e74697479223a22222c22636865636b6f75745f6964656e74697479223a22222c2265787065637465645f6272616e6368223a22222c22626173655f7265766973696f6e223a22222c226e6f6e5f676974223a747275657d');" ++
                "INSERT INTO threads(id,revision,project_id,workspace_id,root_key,sort_order) VALUES" ++
                "('t1',1,'p1','w1',X'e9671acd244849c57167c658fa2f969752048f7ab184a3dcf5c46cb4d56ae124',-300)," ++
                "('t2',1,'p2','w2',X'e9671acd244849c57167c658fa2f969752048f7ab184a3dcf5c46cb4d56ae124',-200)," ++
                "('t3',1,'p1','w3',X'025d361730b4940c503ee92c96a7ef773ba7f05b0828d466fa55ce9c5deae97c',-100)," ++
                "('t4',1,'p1','w1',X'e9671acd244849c57167c658fa2f969752048f7ab184a3dcf5c46cb4d56ae124',-50);" ++
                "UPDATE threads SET settled=1 WHERE id='t4';",
        );
    }
    var consumer: Consumer = .{ .host = undefined, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    defer consumer.host.destroy();
    const root = "/tmp";
    const first = try consumer.query(.{ .thread_sidebar_next = .{ .canonical_root = root } });
    try std.testing.expectEqual(@as(usize, 1), first.items.len);
    try std.testing.expectEqualStrings("t1", first.items[0].thread.id.value);
    const second = try consumer.query(.{ .thread_sidebar_next = .{ .canonical_root = root, .after = .{ .value = "t1" } } });
    try std.testing.expectEqual(@as(usize, 1), second.items.len);
    try std.testing.expectEqualStrings("t2", second.items[0].thread.id.value);
    const wrapped = try consumer.query(.{ .thread_sidebar_next = .{ .canonical_root = root, .after = .{ .value = "t2" } } });
    try std.testing.expectEqual(@as(usize, 1), wrapped.items.len);
    try std.testing.expectEqualStrings("t1", wrapped.items[0].thread.id.value);
    const project = try consumer.query(.{ .thread_sidebar_next = .{ .canonical_root = root, .project = .{ .value = "p1" }, .after = .{ .value = "t1" } } });
    try std.testing.expectEqual(@as(usize, 1), project.items.len);
    try std.testing.expectEqualStrings("t1", project.items[0].thread.id.value);
    _ = try consumer.host.query(.{ .thread_sidebar_next = .{ .canonical_root = root, .after = .{ .value = "t3" } } });
    const wrong_root = try consumer.next();
    try std.testing.expectEqual(.cursor_invalid, wrong_root.failure.failure.reason);
}

test "opaque presentation state migrates independently and preserves execution position" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("DROP TABLE presentation_state; UPDATE meta SET schema_version=10; PRAGMA user_version=10");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    const before = try f.store.position();
    try f.store.savePresentation("workspace-a", "{\"route\":\"h\"}");
    try f.store.savePresentation("workspace-b", "opaque\x00value");
    try f.store.savePresentation("workspace-a", "latest");
    const loaded = (try f.store.loadPresentation(std.testing.allocator, "workspace-a")).?;
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("latest", loaded);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, f.store.loadPresentation(failing.allocator(), "workspace-a"));
    try std.testing.expect((try f.store.loadPresentation(std.testing.allocator, "missing")) == null);
    try std.testing.expectEqualDeep(before, try f.store.position());
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT revision FROM threads WHERE id='h'"));
    try std.testing.expectError(error.Limit, f.store.savePresentation("", "value"));
    try std.testing.expectError(error.Limit, f.store.savePresentation("k", &(@as([4097]u8, @splat('x')))));
    try std.testing.expectError(error.InvalidText, f.store.savePresentation("workspace-\xff", "value"));
    try std.testing.expectError(error.InvalidText, f.store.savePresentation("workspace", "bad\xffvalue"));
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    const reopened = (try f.store.loadPresentation(std.testing.allocator, "workspace-b")).?;
    defer std.testing.allocator.free(reopened);
    try std.testing.expectEqualStrings("opaque\x00value", reopened);
    try f.store.exec("PRAGMA ignore_check_constraints=ON; UPDATE presentation_state SET value=zeroblob(4097) WHERE key='workspace-a'");
    try std.testing.expectError(error.Corrupt, f.store.loadPresentation(std.testing.allocator, "workspace-a"));
    try f.store.exec("UPDATE presentation_state SET value=CAST(X'62FF' AS BLOB) WHERE key='workspace-a'");
    try std.testing.expectError(error.InvalidText, f.store.loadPresentation(std.testing.allocator, "workspace-a"));
}

test "Host presentation state copies request buffers and reopens without snapshot invalidation" {
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
    _ = try consumer.command(.{ .command_id = .{ .value = "ui-project-a" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "A" } } });
    _ = try consumer.command(.{ .command_id = .{ .value = "ui-project-b" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "B" } } });
    const first = try consumer.query(.{ .projects = .{ .limit = 1 } });
    var value = [_]u8{'a'} ** 4096;
    const saved = try consumer.host.savePresentation("workspace", &value);
    @memset(&value, 'b');
    const receipt = try consumer.next();
    try std.testing.expectEqual(saved.value, receipt.presentation_saved.ticket.value);
    const next = try consumer.query(.{ .projects = .{ .limit = 1, .snapshot = first.snapshot_id, .cursor = first.next_cursor } });
    try std.testing.expectEqualDeep(first.snapshot_position, next.snapshot_position);
    try std.testing.expectEqualStrings("B", next.items[0].project.display_name);
    try std.testing.expectError(error.TooLarge, consumer.host.savePresentation("workspace", &(@as([4097]u8, @splat('x')))));
    try std.testing.expectError(error.InvalidText, consumer.host.savePresentation("workspace", "bad\xffvalue"));
    try std.testing.expectError(error.InvalidText, consumer.host.retainFinalPresentation("workspace", "bad\xffvalue"));
    consumer.host.destroy();
    live = false;
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const ticket = try consumer.host.loadPresentation("workspace");
    const loaded = try consumer.next();
    try std.testing.expectEqual(ticket.value, loaded.presentation_loaded.ticket.value);
    try std.testing.expectEqualStrings(&(@as([4096]u8, @splat('a'))), loaded.presentation_loaded.value.?);
}

test "Host presentation writes honor durable store quota" {
    const Host = @import("../domain.zig").Host;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var consumer: Consumer = .{ .host = undefined, .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer consumer.arena.deinit();
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .limits = .{ .durable_bytes = 1 }, .wake = Consumer.wake, .wake_context = &consumer });
    defer consumer.host.destroy();
    const ticket = try consumer.host.savePresentation("workspace", "value");
    const failure = (try consumer.next()).failure;
    try std.testing.expectEqual(ticket.value, failure.ticket.value);
    try std.testing.expectEqual(.admission_limit, failure.failure.reason);
    _ = try consumer.host.loadPresentation("workspace");
    try std.testing.expect((try consumer.next()).presentation_loaded.value == null);
}

test "Host final presentation snapshot survives immediate shutdown and supersedes queued writes" {
    const Host = @import("../domain.zig").Host;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .limits = .{ .result_slots = 1 } });
    try std.testing.expectError(error.TooLarge, host.retainFinalPresentation("", "bad"));
    try std.testing.expectError(error.TooLarge, host.retainFinalPresentation("key", "x" ** 4097));
    _ = try host.savePresentation("workspace", "queued-old");
    _ = try host.savePresentation("workspace", "queued-later");
    try host.retainFinalPresentation("workspace", "outgoing-view");
    var final = [_]u8{'z'} ** 4096;
    try host.retainFinalPresentation("workspace", &final);
    @memset(&final, 'q');
    // No drain or sleep: final persistence is a worker-owned shutdown step,
    // including when publication of a normal result is already backpressured.
    host.destroy();
    var reopened = try storage.Store.open(std.testing.io, path_buffer[0..n]);
    defer reopened.close() catch {};
    const saved = (try reopened.loadPresentation(std.testing.allocator, "workspace")).?;
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("z" ** 4096, saved);
    try std.testing.expectEqual(@as(i64, 0), try reopened.scalar("SELECT count(*) FROM events"));
    try std.testing.expectEqual(@as(i64, 0), try reopened.scalar("SELECT count(*) FROM commands"));
}

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
    try std.testing.expect((try consumer.query(.{ .thread = thread })).items[0].thread.can_snooze);
    const selection: t.adapter.Selection = .{ .workspace = workspace, .model_provider = "fake", .model_id = "fixture", .effort = "none", .account_ref = "fixture" };
    const send: t.CommandEnvelope = .{ .command_id = .{ .value = "host-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "Hello 世界", .selection = selection } } };
    const sent = try consumer.command(send);
    const run = sent.entity_ids.run.?;
    const approvals = try consumer.query(.{ .approvals = .{ .run = run } });
    try std.testing.expectEqual(@as(usize, 1), approvals.items.len);
    const approval = approvals.items[0].approval;
    try std.testing.expect(approval.live);
    try std.testing.expect(!(try consumer.query(.{ .thread = thread })).items[0].thread.can_snooze);
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
    fn discoverFactory(context: *anyopaque, requested: t.adapter.Selection) t.adapter.Discovery {
        var result = discover(context);
        result.runtime_kind = requested.runtime_kind;
        result.runtime_version = requested.required_runtime_version;
        return result;
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

const FollowupTurn = struct {
    conversation: Conversation,
    sent: t.Receipt,
    start: domain.Owner.Claimed,
    fn begin(owner: *domain.Owner, allocator: std.mem.Allocator) !FollowupTurn {
        const conversation = try Conversation.create(owner, allocator);
        const sent = try owner.command(allocator, conversation.send("followup-start", "first turn", 1));
        try std.testing.expectEqual(.accepted, sent.outcome);
        const open = (try owner.claimNext(allocator)).?;
        try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "followup-instance" }, .upstream = .{ .value = "followup-session" } } });
        const start = (try owner.claimNext(allocator)).?;
        try std.testing.expect(start.request == .start);
        try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
        const self: FollowupTurn = .{ .conversation = conversation, .sent = sent, .start = start };
        try owner.observe(allocator, self.chunk("before-followup", 0, "before "));
        return self;
    }
    fn chunk(self: FollowupTurn, label: []const u8, offset: u64, text: []const u8) t.adapter.Observation {
        return .{ .correlation = self.start.request.start.correlation, .upstream_event = label, .body = .{ .chunk = .{ .message = self.sent.entity_ids.assistant_message.?, .block = self.sent.entity_ids.assistant_block.?, .offset = offset, .text = text } } };
    }
    fn enqueue(self: FollowupTurn, owner: *domain.Owner, allocator: std.mem.Allocator, id: []const u8) !t.Receipt {
        const revision: u64 = @intCast(try owner.database.scalar("SELECT revision FROM runs"));
        const envelope: t.CommandEnvelope = .{ .command_id = .{ .value = id }, .target = .{ .run = self.sent.entity_ids.run.? }, .expected_revision = .{ .revision = revision }, .payload = .{ .followup_enqueue = .{ .content = "later 世界" } } };
        const receipt = try owner.command(allocator, envelope);
        try std.testing.expectEqual(.accepted, receipt.outcome);
        const position = try owner.database.position();
        try std.testing.expectEqual(receipt.commit_sequence, (try owner.command(allocator, envelope)).commit_sequence);
        try std.testing.expectEqual(position, try owner.database.position());
        return receipt;
    }
    fn complete(self: FollowupTurn, owner: *domain.Owner, allocator: std.mem.Allocator) !void {
        try owner.observe(allocator, .{ .correlation = self.start.request.start.correlation, .upstream_event = "natural-completion", .body = .completed });
    }
};

test "fresh failure and raised input wake snooze atomically while completion and retries retain it" {
    for (0..4) |scenario| {
        var f = try Fixture.init();
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "snooze-attention", .utc_ms = 1000 };
        const turn = try FollowupTurn.begin(&owner, allocator);
        var correlation = turn.start.request.start.correlation;
        if (scenario == 1) {
            correlation.tool = .{ .value = "attention-tool" };
            correlation.upstream_tool = "attention-upstream-tool";
            try owner.observe(allocator, .{ .correlation = correlation, .upstream_event = "attention-tool", .body = .{ .tool_started = .{ .name = "read", .action_digest = "attention-digest" } } });
            correlation.approval = .{ .value = "attention-approval" };
            correlation.upstream_request = "attention-request";
        }
        if (scenario == 2) correlation.question = .{ .value = "attention-question" };
        const snoozed = try owner.command(allocator, .{ .command_id = .{ .value = "snooze-before-attention" }, .target = .{ .thread = turn.conversation.thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_sidebar_set = .{ .snoozed_until = 5000 } } });
        try std.testing.expectEqual(.accepted, snoozed.outcome);
        const attention: t.adapter.Observation = .{ .correlation = correlation, .upstream_event = "fresh-attention", .body = switch (scenario) {
            0 => .{ .failure = .{ .code = "failed", .detail = "fresh failure" } },
            1 => .{ .approval = .{ .correlation = correlation, .workspace = turn.conversation.workspace, .action_digest = "attention-digest", .scope = "one read" } },
            2 => .{ .question = .{ .id = correlation.question.?, .correlation = correlation, .prompt = "Choose a direction", .allow_freeform = true } },
            3 => .completed,
            else => unreachable,
        } };
        try owner.observe(allocator, attention);
        try std.testing.expectEqual(@as(i64, if (scenario == 3) 5000 else 0), try f.store.scalar("SELECT snoozed_until FROM threads"));
        try std.testing.expectEqual(@as(i64, if (scenario == 3) 3 else 4), try f.store.scalar("SELECT revision FROM threads"));
        try std.testing.expectEqual(@as(i64, if (scenario == 3) 0 else 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadWoke' AND revision=4 AND json_extract(CAST(aggregate AS TEXT),'$.thread.value')=(SELECT id FROM threads)"));
        const position = try f.store.position();
        try owner.observe(allocator, attention);
        try std.testing.expectEqual(position, try f.store.position());
        if (scenario == 1 or scenario == 2) {
            // Nonblocking input still forbids snooze even if the provider's
            // independent run lifecycle is currently streaming.
            try f.store.exec("UPDATE runs SET state='streaming'");
            const refused = try owner.command(allocator, .{ .command_id = .{ .value = "pending-input-snooze" }, .target = .{ .thread = turn.conversation.thread }, .expected_revision = .{ .revision = 4 }, .payload = .{ .thread_sidebar_set = .{ .snoozed_until = 6000 } } });
            try std.testing.expectEqual(t.Reason.busy, refused.reason.?);
            try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT snoozed_until FROM threads"));
        } else {
            const resnoozed = try owner.command(allocator, .{ .command_id = .{ .value = "snooze-after-seen" }, .target = .{ .thread = turn.conversation.thread }, .expected_revision = .{ .revision = if (scenario == 3) 3 else 4 }, .payload = .{ .thread_sidebar_set = .{ .snoozed_until = 6000 } } });
            try std.testing.expectEqual(.accepted, resnoozed.outcome);
            const resnoozed_position = try f.store.position();
            try owner.observe(allocator, attention);
            try std.testing.expectEqual(resnoozed_position, try f.store.position());
            var old_failure = attention;
            old_failure.upstream_event = "terminal-late-failure";
            old_failure.body = .{ .failure = .{ .code = "old", .detail = "terminal run already seen" } };
            try owner.observe(allocator, old_failure);
            try std.testing.expectEqual(@as(i64, 6000), try f.store.scalar("SELECT snoozed_until FROM threads"));
            try std.testing.expectEqual(@as(i64, if (scenario == 3) 0 else 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadWoke'"));
        }
    }
}

test "attention wake revision exhaustion rolls back the entire fresh observation" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "wake-exhaustion", .utc_ms = 1000 };
    const turn = try FollowupTurn.begin(&owner, allocator);
    try f.store.exec("UPDATE threads SET revision=9223372036854775807,snoozed_until=5000");
    const position = try f.store.position();
    const revision = try f.store.scalar("SELECT revision FROM runs");
    try std.testing.expectError(error.Limit, owner.observe(allocator, .{ .correlation = turn.start.request.start.correlation, .upstream_event = "exhausted-attention", .body = .{ .failure = .{ .code = "failure", .detail = "cannot increment thread" } } }));
    try std.testing.expectEqual(position, try f.store.position());
    try std.testing.expectEqual(revision, try f.store.scalar("SELECT revision FROM runs"));
    try std.testing.expectEqual(@as(i64, 5000), try f.store.scalar("SELECT snoozed_until FROM threads"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM observations WHERE upstream_event LIKE '%exhausted-attention'"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadWoke'"));
}

test "fresh rejected Start delivery wakes snooze without replay waking a re-snoozed failure" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "snooze-delivery", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const sent = try owner.command(allocator, conversation.send("delivery-send", "first", 1));
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "delivery-instance" }, .upstream = .{ .value = "delivery-session" } } });
    const start = (try owner.claimNext(allocator)).?;
    // Streaming can precede the dispatch receipt. This still represents one
    // live Start, rather than manufacturing a second provider effect.
    try owner.observe(allocator, .{ .correlation = start.request.start.correlation, .upstream_event = "delivery-early-chunk", .body = .{ .chunk = .{ .message = sent.entity_ids.assistant_message.?, .block = sent.entity_ids.assistant_block.?, .offset = 0, .text = "early" } } });
    _ = try owner.command(allocator, .{ .command_id = .{ .value = "delivery-snooze" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_sidebar_set = .{ .snoozed_until = 5000 } } });
    const rejected: t.adapter.Receipt = .{ .outcome = .rejected, .detail = "Start refused" };
    try owner.delivered(allocator, start.id, rejected);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT snoozed_until FROM threads"));
    _ = try owner.command(allocator, .{ .command_id = .{ .value = "delivery-resnooze" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = 4 }, .payload = .{ .thread_sidebar_set = .{ .snoozed_until = 6000 } } });
    const position = try f.store.position();
    try owner.delivered(allocator, start.id, rejected);
    try std.testing.expectEqual(position, try f.store.position());
    try std.testing.expectEqual(@as(i64, 6000), try f.store.scalar("SELECT snoozed_until FROM threads"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='ThreadWoke' AND revision=4 AND json_extract(CAST(aggregate AS TEXT),'$.thread.value')=(SELECT id FROM threads)"));
}

test "message delivery outcomes preserve streaming Start and persist unknown without replay" {
    for ([_]t.adapter.Receipt{ .{ .outcome = .acknowledged }, .{ .outcome = .rejected, .detail = "request refused" }, .{ .outcome = .unknown, .detail = "delivery result lost" } }) |receipt| {
        var f = try Fixture.init();
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var runtime: AsyncAdapter = .{};
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "followup-delivery", .utc_ms = 1000, .factory = runtime.factory() };
        const turn = try FollowupTurn.begin(&owner, allocator);
        const queued = try turn.enqueue(&owner, allocator, "queued");
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='message' AND state='planned'"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='FollowupQueued'"));
        const followup = (try owner.claimNext(allocator)).?;
        try std.testing.expectEqualStrings(queued.effect_ids[0].value, followup.id.value);
        const revision = try f.store.scalar("SELECT revision FROM runs");
        const position = try f.store.position();
        var wrong = receipt;
        wrong.session = .{ .id = .{ .value = "wrong-session" }, .instance = .{ .value = "instance" }, .upstream = .{ .value = "upstream" } };
        try std.testing.expectError(error.Conflict, owner.delivered(allocator, followup.id, wrong));
        try std.testing.expectEqual(position, try f.store.position());
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='message' AND state='in_flight'"));
        try owner.delivered(allocator, followup.id, receipt);
        const delivered_position = try f.store.position();
        try owner.delivered(allocator, followup.id, receipt);
        try std.testing.expectEqual(delivered_position, try f.store.position());
        try std.testing.expectEqual(revision, try f.store.scalar("SELECT revision FROM runs"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='streaming'"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM messages WHERE role='assistant' AND incomplete=1"));
        const expected_state = switch (receipt.outcome) {
            .acknowledged => "confirmed",
            .rejected => "failed",
            .unknown => "unknown",
        };
        {
            const state = try f.store.prepare("SELECT state FROM effects WHERE kind='message'", &.{});
            defer state.deinit();
            try std.testing.expect(try state.step());
            try std.testing.expectEqualStrings(expected_state, try state.bytes(0));
        }
        // Continuation bytes and completion retain the independent Start ID.
        try owner.observe(allocator, turn.chunk("after-followup", 7, "世界"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM observations o JOIN effects e ON e.id=json_extract(CAST(o.correlation AS TEXT),'$.effect.value') WHERE e.kind='start' AND o.upstream_event LIKE '%:after-followup'"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='start' AND state='confirmed'"));
        try turn.complete(&owner, allocator);
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='completed'"));
        try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM messages WHERE incomplete=1"));
        // Real close/reopen retains delivery evidence and cannot claim it again.
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try f.path(&path_buffer);
        try f.store.close();
        f.store = try storage.Store.open(std.testing.io, path);
        owner.epoch = "followup-restart";
        try owner.recover();
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        const persisted = try f.store.prepare("SELECT state,evidence FROM effects WHERE kind='message'", &.{});
        defer persisted.deinit();
        try std.testing.expect(try persisted.step());
        try std.testing.expectEqualStrings(expected_state, try persisted.bytes(0));
        var encoded_receipt: [4096]u8 = undefined;
        try std.testing.expectEqualStrings(try t.encode(receipt, &encoded_receipt), try persisted.bytes(1));
        if (receipt.outcome == .unknown) {
            const blocked = try owner.command(allocator, turn.conversation.send("unsafe-retry", "do not replay", 2));
            try std.testing.expectEqual(t.Reason.unresolved_effects, blocked.reason.?);
        }
    }
}

test "asynchronous request refusal validates exact identity and leaves Start diagnostics and lifecycle intact" {
    for ([_]bool{ false, true }) |normalize| {
        var f = try Fixture.init();
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var runtime: AsyncAdapter = .{};
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "request-refusal", .utc_ms = 1000, .factory = if (normalize) runtime.factory() else null };
        const turn = try FollowupTurn.begin(&owner, allocator);
        _ = try turn.enqueue(&owner, allocator, "refused-followup");
        const followup = (try owner.claimNext(allocator)).?;
        const acknowledgement: t.adapter.Receipt = .{ .outcome = .acknowledged, .detail = &([_]u8{'a'} ** 2048) };
        try owner.delivered(allocator, followup.id, acknowledgement);
        try std.testing.expect((try f.store.scalar("SELECT max(length(payload)) FROM events WHERE kind='EffectDelivery'")) <= 256);
        try std.testing.expectEqual(@as(i64, 2048), try f.store.scalar("SELECT length(outcome) FROM effects WHERE kind='message'"));
        var refusal: t.adapter.Observation = .{ .correlation = followup.request.message.correlation, .upstream_event = "async-refusal", .cursor = .{ .value = "refusal-cursor" }, .body = .{ .request_failed = .{ .code = "busy", .detail = "cannot accept this message" } } };
        const position = try f.store.position();
        const revision = try f.store.scalar("SELECT revision FROM runs");
        const changes = try f.store.scalar("SELECT count(*) FROM aggregate_changes");
        for (0..8) |invalid| {
            var wrong = refusal;
            switch (invalid) {
                0 => wrong.correlation.session.value = "wrong-session",
                1 => wrong.correlation.run = .{ .value = "wrong-run" },
                2 => wrong.correlation.effect = .{ .value = "wrong-effect" },
                3 => wrong.correlation.effect = turn.start.id,
                4 => wrong.correlation.run = null,
                5 => wrong.correlation.effect = null,
                6 => wrong.correlation.followup = .{ .value = "wrong-followup" },
                7 => wrong.body.request_failed.detail = &([_]u8{'x'} ** 4096),
                else => unreachable,
            }
            try std.testing.expectError(if (invalid == 7) error.Limit else error.Conflict, owner.observe(allocator, wrong));
            try std.testing.expectEqual(position, try f.store.position());
            try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM observations WHERE cursor='refusal-cursor'"));
            try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='message' AND state='confirmed'"));
            try std.testing.expectEqual(changes, try f.store.scalar("SELECT count(*) FROM aggregate_changes"));
        }
        try owner.observe(allocator, refusal);
        const committed = try f.store.position();
        try owner.delivered(allocator, followup.id, acknowledgement);
        try std.testing.expectEqual(committed, try f.store.position());
        try std.testing.expectError(error.Conflict, owner.delivered(allocator, followup.id, .{ .outcome = .unknown }));
        try owner.observe(allocator, refusal);
        try std.testing.expectEqual(committed, try f.store.position());
        refusal.body.request_failed.detail = "conflicting duplicate";
        try std.testing.expectError(error.Conflict, owner.observe(allocator, refusal));
        try std.testing.expectEqual(committed, try f.store.position());
        try std.testing.expectEqual(revision, try f.store.scalar("SELECT revision FROM runs"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='streaming'"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='message' AND state='failed' AND CAST(outcome AS TEXT)='cannot accept this message' AND evidence IS NOT NULL"));
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM events WHERE kind='RequestFailed' AND json_extract(CAST(aggregate AS TEXT),'$.effect.value')=effect_id"));
        try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM observations WHERE evidence IS NOT NULL"));
        try owner.observe(allocator, turn.chunk("after-refusal", 7, "still streaming"));
        try turn.complete(&owner, allocator);
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='completed'"));
    }
}

test "unknown followup does not resolve tools and late refusal cannot undo cancellation" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "followup-cancel", .utc_ms = 1000 };
    const turn = try FollowupTurn.begin(&owner, allocator);
    var tool = turn.start.request.start.correlation;
    tool.tool = .{ .value = "live-tool" };
    tool.upstream_tool = "live-upstream-tool";
    try owner.observe(allocator, .{ .correlation = tool, .upstream_event = "tool-start", .body = .{ .tool_started = .{ .name = "work", .action_digest = "work-digest" } } });
    _ = try turn.enqueue(&owner, allocator, "unknown-followup");
    const followup = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, followup.id, .{ .outcome = .unknown });
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM tools WHERE outcome='pending'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT unresolved_tools FROM runs WHERE state='streaming'"));
    const cancel = try owner.command(allocator, .{ .command_id = .{ .value = "cancel-active" }, .target = .{ .run = turn.sent.entity_ids.run.? }, .expected_revision = .{ .revision = @intCast(try f.store.scalar("SELECT revision FROM runs")) }, .payload = .{ .run_cancel = .{ .reason = "stop" } } });
    try std.testing.expectEqual(.accepted, cancel.outcome);
    try owner.observe(allocator, .{ .correlation = followup.request.message.correlation, .upstream_event = "late-refusal", .body = .{ .request_failed = .{ .code = "refused", .detail = "message refused" } } });
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='cancel_requested'"));
    const cancel_effect = (try owner.claimNext(allocator)).?;
    try std.testing.expect(cancel_effect.request == .cancel);
    try owner.delivered(allocator, cancel_effect.id, .{ .outcome = .acknowledged });
    try owner.observe(allocator, .{ .correlation = cancel_effect.request.cancel.correlation, .upstream_event = "cancel-no-tool-proof", .body = .{ .cancelled = .{ .tools_stopped = false } } });
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='unknown'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM tools WHERE outcome='pending'"));
}

test "provider and Start failures remain terminal despite request-scoped refusal support" {
    for (0..3) |scenario| {
        var f = try Fixture.init();
        defer f.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "terminal-failure", .utc_ms = 1000 };
        const conversation = try Conversation.create(&owner, allocator);
        const sent = try owner.command(allocator, conversation.send("start", "terminal fixture", 1));
        const open = (try owner.claimNext(allocator)).?;
        try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "instance" }, .upstream = .{ .value = "session" } } });
        const start = (try owner.claimNext(allocator)).?;
        if (scenario == 0) {
            try owner.delivered(allocator, start.id, .{ .outcome = .rejected, .detail = "start refused" });
        } else {
            if (scenario == 2) try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
            try owner.observe(allocator, .{ .correlation = if (scenario == 1) start.request.start.correlation else .{ .session = sent.entity_ids.session.?, .run = sent.entity_ids.run }, .upstream_event = "provider-failure", .body = .{ .failure = .{ .code = "provider_failed", .detail = "terminal provider failure" } } });
        }
        try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='failed'"));
        try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM messages WHERE incomplete=1"));
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        if (scenario != 2) try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='start' AND state='failed'"));
    }
}

test "message delivery cannot clear awaiting approval or cancellation" {
    for ([_]bool{ false, true }) |cancel| {
        for ([_]@FieldType(t.adapter.Receipt, "outcome"){ .acknowledged, .rejected, .unknown }) |outcome| {
            var f = try Fixture.init();
            defer f.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "delivery-state", .utc_ms = 1000 };
            const turn = try FollowupTurn.begin(&owner, allocator);
            var correlation = turn.start.request.start.correlation;
            correlation.tool = .{ .value = "approval-tool" };
            correlation.upstream_tool = "upstream-tool";
            try owner.observe(allocator, .{ .correlation = correlation, .upstream_event = "tool", .body = .{ .tool_started = .{ .name = "read", .action_digest = "digest" } } });
            correlation.approval = .{ .value = "approval" };
            correlation.upstream_request = "approval-request";
            try owner.observe(allocator, .{ .correlation = correlation, .upstream_event = "approval", .body = .{ .approval = .{ .correlation = correlation, .workspace = turn.conversation.workspace, .action_digest = "digest", .scope = "one read" } } });
            _ = try turn.enqueue(&owner, allocator, "waiting-followup");
            const message = (try owner.claimNext(allocator)).?;
            if (cancel) {
                const receipt = try owner.command(allocator, .{ .command_id = .{ .value = "cancel-waiting" }, .target = .{ .run = turn.sent.entity_ids.run.? }, .expected_revision = .{ .revision = @intCast(try f.store.scalar("SELECT revision FROM runs")) }, .payload = .{ .run_cancel = .{ .reason = "cancel before message result" } } });
                try std.testing.expectEqual(.accepted, receipt.outcome);
            }
            const revision = try f.store.scalar("SELECT revision FROM runs");
            try owner.delivered(allocator, message.id, .{ .outcome = outcome });
            try std.testing.expectEqual(revision, try f.store.scalar("SELECT revision FROM runs"));
            const state = try f.store.prepare("SELECT state,unresolved_tools FROM runs", &.{});
            defer state.deinit();
            try std.testing.expect(try state.step());
            try std.testing.expectEqualStrings(if (cancel) "cancel_requested" else "awaiting_approval", try state.bytes(0));
            try std.testing.expectEqual(@as(i64, 1), state.integer(1));
            try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM tools WHERE outcome='pending'"));
            try std.testing.expectEqual(@as(i64, if (cancel) 0 else 1), try f.store.scalar("SELECT count(*) FROM approvals WHERE state='pending'"));
        }
    }
}

test "late request refusal stays with its original run across reopen and a newer turn" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime: AsyncAdapter = .{};
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "late-request", .utc_ms = 1000, .factory = runtime.factory() };
    const turn = try FollowupTurn.begin(&owner, allocator);
    _ = try turn.enqueue(&owner, allocator, "late-followup");
    const message = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, message.id, .{ .outcome = .acknowledged });
    try turn.complete(&owner, allocator);
    const second = try owner.command(allocator, turn.conversation.send("second", "new independent turn", 2));
    try std.testing.expectEqual(.accepted, second.outcome);
    const resumed = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, resumed.id, .{ .outcome = .acknowledged, .session = .{ .id = second.entity_ids.session.?, .instance = .{ .value = "followup-instance" }, .upstream = .{ .value = "followup-session" } }, .continuity = .proven });
    const start = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
    const refusal: t.adapter.Observation = .{ .correlation = message.request.message.correlation, .upstream_event = "late-refusal", .body = .{ .request_failed = .{ .code = "late", .detail = "old message refused" } } };
    const position = try f.store.position();
    var wrong = refusal;
    wrong.correlation.run = second.entity_ids.run;
    try std.testing.expectError(error.Conflict, owner.observe(allocator, wrong));
    try std.testing.expectEqual(position, try f.store.position());
    try owner.observe(allocator, refusal);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='completed'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='streaming'"));
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    owner.epoch = "late-request-restart";
    try owner.recover();
    const recovered = try f.store.position();
    try owner.delivered(allocator, message.id, .{ .outcome = .acknowledged });
    try std.testing.expectEqual(recovered, try f.store.position());
    try owner.observe(allocator, refusal);
    try std.testing.expectEqual(recovered, try f.store.position());
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM effects WHERE kind='message' AND state='failed' AND CAST(outcome AS TEXT)='old message refused'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='completed'"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='interrupted'"));
}

fn fixtureAttachment(allocator: std.mem.Allocator, id: []const u8, bytes: []const u8) !t.adapter.Attachment {
    return .{ .metadata = .{ .id = .{ .value = id }, .name = "notes.txt", .media_type = "text/plain", .byte_length = bytes.len, .digest = try allocator.dupe(u8, &std.fmt.bytesToHex(t.digest(bytes), .lower)) }, .content = bytes };
}
fn uploadEnvelope(conversation: Conversation, id: []const u8, revision: u64, attachment: t.adapter.Attachment) t.CommandEnvelope {
    return .{ .command_id = .{ .value = id }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = revision }, .payload = .{ .attachment_add = attachment } };
}
fn attachedSend(conversation: Conversation, id: []const u8, revision: u64, refs: []const t.adapter.AttachmentId) t.CommandEnvelope {
    var result = conversation.send(id, "attachment fixture", revision);
    result.payload.thread_send.selection.runtime_kind = "codex";
    result.payload.thread_send.selection.required_runtime_version = "0.163.0";
    result.payload.thread_send.selection.model_provider = "openai";
    result.payload.thread_send.attachments = refs;
    return result;
}

test "attachment history is immutable across ten packets retry reopen and fresh staging budgets" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "attachment-history", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    var runtime: AsyncAdapter = .{};
    owner.factory = runtime.factory();
    const bytes = "a" ** (256 * 1024);
    var revision: u64 = 1;
    for (0..10) |index| {
        const label = try std.fmt.allocPrint(allocator, "upload-{d}", .{index});
        const attachment = try fixtureAttachment(allocator, label, bytes);
        const command = uploadEnvelope(conversation, label, revision, attachment);
        const receipt = try owner.command(allocator, command);
        try std.testing.expectEqual(.accepted, receipt.outcome);
        try std.testing.expectEqual(receipt.commit_sequence, (try owner.command(allocator, command)).commit_sequence);
        revision += 1;
        const send = attachedSend(conversation, try std.fmt.allocPrint(allocator, "send-{d}", .{index}), revision, &.{attachment.metadata.id});
        const sent = try owner.command(allocator, send);
        try std.testing.expectEqual(.accepted, sent.outcome);
        try std.testing.expectEqual(sent.commit_sequence, (try owner.command(allocator, send)).commit_sequence);
        revision += 1;
        const open = (try owner.claimNext(allocator)).?;
        try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "instance" }, .upstream = .{ .value = "session" } }, .continuity = .proven });
        const start = (try owner.claimNext(allocator)).?;
        try std.testing.expectEqual(@as(usize, 0), start.request.start.attachments[0].content.len);
        try std.testing.expectEqualStrings(attachment.metadata.digest, start.request.start.attachments[0].metadata.digest);
        var materialized = start.request;
        try owner.hydrateStartAttachments(allocator, &materialized);
        try std.testing.expectEqualSlices(u8, bytes, materialized.start.attachments[0].content);
        try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
        try owner.observe(allocator, .{ .correlation = start.request.start.correlation, .upstream_event = try std.fmt.allocPrint(allocator, "completed-{d}", .{index}), .body = .completed });
    }
    try std.testing.expectEqual(@as(i64, 10), try f.store.scalar("SELECT count(*) FROM attachment_refs"));
    try std.testing.expectEqual(@as(i64, 10 * 256 * 1024), try f.store.scalar("SELECT sum(length(content)) FROM attachments"));
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    try owner.recover();
    const persisted = try f.store.prepare("SELECT request FROM effects WHERE kind='start' ORDER BY rowid LIMIT 1", &.{});
    defer persisted.deinit();
    try std.testing.expect(try persisted.step());
    const durable = try t.decode(t.adapter.Request, try persisted.bytes(0), allocator);
    var hydrated = durable;
    try owner.hydrateStartAttachments(allocator, &hydrated);
    try std.testing.expectEqualSlices(u8, bytes, hydrated.start.attachments[0].content);
    // Altered refs, metadata, and on-disk bytes must fail before external IO.
    var forged = durable;
    const forged_items = try allocator.dupe(t.adapter.Attachment, durable.start.attachments);
    forged_items[0].metadata.id.value = "not-bound-to-message";
    forged.start.attachments = forged_items;
    try std.testing.expectError(error.Corrupt, owner.hydrateStartAttachments(allocator, &forged));
    forged_items[0] = durable.start.attachments[0];
    forged_items[0].metadata.name = "changed.txt";
    try std.testing.expectError(error.Corrupt, owner.hydrateStartAttachments(allocator, &forged));
    try f.store.exec("UPDATE attachments SET content=X'00' WHERE id='upload-0'");
    var corrupted = durable;
    try std.testing.expectError(error.Corrupt, owner.hydrateStartAttachments(allocator, &corrupted));
    try f.store.execute("UPDATE attachments SET content=? WHERE id='upload-0'", &.{.{ .blob = bytes }});
    const orphan = try fixtureAttachment(allocator, "unsent", "café 世界");
    const add = uploadEnvelope(conversation, "new-after-reopen", revision, orphan);
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, add)).outcome);
    revision += 1;
    var changed = add;
    changed.payload.attachment_add.metadata.name = "changed.txt";
    try std.testing.expectEqual(.command_id_conflict, (try owner.command(allocator, changed)).reason.?);
    const removal: t.CommandEnvelope = .{ .command_id = .{ .value = "cleanup-unsent" }, .target = .{ .thread = conversation.thread }, .expected_revision = .{ .revision = revision }, .payload = .{ .attachment_remove = orphan.metadata.id } };
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, removal)).outcome);
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM attachments WHERE id='unsent'"));
    // Retry returns the original acceptance without resurrecting deleted bytes.
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, add)).outcome);
    try std.testing.expectEqual(@as(i64, 10), try f.store.scalar("SELECT count(*) FROM attachments"));
    const first = try f.store.prepare("SELECT content FROM attachments WHERE id='upload-0'", &.{});
    defer first.deinit();
    try std.testing.expect(try first.step());
    try std.testing.expectEqualSlices(u8, bytes, try first.bytes(0));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM commands WHERE instr(CAST(canonical AS TEXT),'aaaaaaaaaaaaaaaa')>0"));
}

test "attachment sends reject count duplicates cross thread unsupported provider and packet aggregate without consuming staging" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "attachment-reject", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    var runtime: AsyncAdapter = .{};
    owner.factory = runtime.factory();
    const a1 = try fixtureAttachment(allocator, "a1", "notes");
    const a2 = try fixtureAttachment(allocator, "a2", "other");
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, uploadEnvelope(conversation, "add1", 1, a1))).outcome);
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, uploadEnvelope(conversation, "add2", 2, a2))).outcome);
    const other = try owner.command(allocator, .{ .command_id = .{ .value = "other-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = conversation.project, .workspace = conversation.workspace } } });
    var wrong = conversation;
    wrong.thread = other.entity_ids.thread.?;
    const cross = try owner.command(allocator, attachedSend(wrong, "cross-thread", 1, &.{a1.metadata.id}));
    try std.testing.expectEqual(.not_found, cross.reason.?);
    const many = [_]t.adapter.AttachmentId{a1.metadata.id} ** 9;
    const overflow = try owner.command(allocator, attachedSend(conversation, "too-many", 3, &many));
    try std.testing.expectEqual(.attachment_limit, overflow.reason.?);
    const duplicate = try owner.command(allocator, attachedSend(conversation, "duplicate", 3, &.{ a1.metadata.id, a1.metadata.id }));
    try std.testing.expectEqual(.attachment_limit, duplicate.reason.?);
    var unsupported = attachedSend(conversation, "unsupported", 3, &.{a1.metadata.id});
    unsupported.payload.thread_send.selection.runtime_kind = "fake";
    unsupported.payload.thread_send.selection.required_runtime_version = "1";
    try std.testing.expectEqual(.attachment_unsupported, (try owner.command(allocator, unsupported)).reason.?);
    owner.limits.attachment_bytes = 9;
    const aggregate = attachedSend(conversation, "aggregate", 3, &.{ a1.metadata.id, a2.metadata.id });
    const refused = try owner.command(allocator, aggregate);
    try std.testing.expectEqual(.attachment_limit, refused.reason.?);
    owner.limits.attachment_bytes = 256 * 1024;
    try std.testing.expectEqual(refused.commit_sequence, (try owner.command(allocator, aggregate)).commit_sequence);
    try std.testing.expectEqual(@as(i64, 2), try f.store.scalar("SELECT count(*) FROM attachments"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM attachment_refs"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM runs"));
    try std.testing.expectEqual(@as(i64, 0), try f.store.scalar("SELECT count(*) FROM prompt_uploads"));
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, attachedSend(conversation, "valid-after-refusals", 3, &.{ a1.metadata.id, a2.metadata.id }))).outcome);
}

test "attachment staging custom count bytes and Unicode metadata byte budgets survive reopen" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "attachment-limits", .utc_ms = 1 };
    const conversation = try Conversation.create(&owner, allocator);
    var a1 = try fixtureAttachment(allocator, "1", "café");
    a1.metadata.name = "界" ** 30;
    const a2 = try fixtureAttachment(allocator, "2", "x");
    const budget = @import("attachments.zig").metadataBytes(a1.metadata) + @import("attachments.zig").metadataBytes(a2.metadata) - 1;
    owner.limits.attachment_metadata_bytes = budget;
    try std.testing.expectEqual(.accepted, (try owner.command(allocator, uploadEnvelope(conversation, "first", 1, a1))).outcome);
    const rejected = try owner.command(allocator, uploadEnvelope(conversation, "unicode-over-budget", 2, a2));
    try std.testing.expectEqual(.attachment_limit, rejected.reason.?);
    owner.limits.attachment_metadata_bytes = 4096;
    owner.limits.attachment_count = 1;
    try std.testing.expectEqual(.attachment_limit, (try owner.command(allocator, uploadEnvelope(conversation, "count-limit", 2, a2))).reason.?);
    owner.limits.attachment_count = 8;
    owner.limits.attachment_bytes = a1.content.len;
    try std.testing.expectEqual(.attachment_limit, (try owner.command(allocator, uploadEnvelope(conversation, "bytes-limit", 2, a2))).reason.?);
    var invalid = try fixtureAttachment(allocator, "invalid", "\xff");
    owner.limits = .{};
    try std.testing.expectEqual(.invalid_command, (try owner.command(allocator, uploadEnvelope(conversation, "bad-utf8", 2, invalid))).reason.?);
    invalid.metadata.kind = .image;
    try std.testing.expectEqual(.invalid_command, (try owner.command(allocator, uploadEnvelope(conversation, "bad-kind", 2, invalid))).reason.?);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM attachments"));
    try std.testing.expectEqual(rejected.commit_sequence, (try owner.command(allocator, uploadEnvelope(conversation, "unicode-over-budget", 2, a2))).commit_sequence);
}

test "Codex followup attachments retain durable metadata and hydrate at dispatch" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime: AsyncAdapter = .{};
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "attachment-followup", .utc_ms = 1, .factory = runtime.factory() };
    const turn = try FollowupTurn.begin(&owner, allocator);
    const attachment = try fixtureAttachment(allocator, "a", "file body");
    const uploaded = try owner.command(allocator, uploadEnvelope(turn.conversation, "attached-upload", 2, attachment));
    try std.testing.expectEqual(.accepted, uploaded.outcome);
    const revision: u64 = @intCast(try f.store.scalar("SELECT revision FROM runs"));
    const enqueue = try owner.command(allocator, .{ .command_id = .{ .value = "attached-followup" }, .target = .{ .run = turn.sent.entity_ids.run.? }, .expected_revision = .{ .revision = revision }, .payload = .{ .followup_enqueue = .{ .content = "continue", .attachments = &.{attachment} } } });
    try std.testing.expectEqual(.accepted, enqueue.outcome);
    const queued = enqueue;
    const stored = try f.store.prepare("SELECT request FROM effects WHERE id=?", &.{.{ .text = queued.entity_ids.followup.?.value }});
    defer stored.deinit();
    try std.testing.expect(try stored.step());
    const encoded_request = try stored.bytes(0);
    try std.testing.expect(std.mem.indexOf(u8, encoded_request, "file body") == null);
    const effect_revision: u64 = @intCast(try f.store.scalar("SELECT revision FROM effects WHERE kind='message'"));
    const edited = try owner.command(allocator, .{ .command_id = .{ .value = "attached-edit" }, .target = .{ .effect = .{ .value = queued.entity_ids.followup.?.value } }, .expected_revision = .{ .revision = effect_revision }, .payload = .{ .followup_edit = .{ .content = "replace", .attachments = &.{attachment} } } });
    try std.testing.expectEqual(.accepted, edited.outcome);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM runs WHERE state='streaming'"));
    var pending = (try owner.claimNext(allocator)).?;
    try std.testing.expectEqual(@as(usize, 1), pending.request.message.attachments.len);
    try std.testing.expectEqual(@as(usize, 0), pending.request.message.attachments[0].content.len);
    try owner.hydrateMessageAttachments(allocator, &pending.request);
    try std.testing.expectEqualStrings("file body", pending.request.message.attachments[0].content);
    const remove_busy = try owner.command(allocator, .{ .command_id = .{ .value = "attached-remove-busy" }, .target = .{ .thread = turn.conversation.thread }, .expected_revision = .{ .revision = @intCast(try f.store.scalar("SELECT revision FROM threads")) }, .payload = .{ .attachment_remove = .{ .value = "a" } } });
    try std.testing.expectEqual(.busy, remove_busy.reason.?);
}

test "attachment schema v6 migration preserves prior data and reopens with durable bodies and references" {
    var f = try Fixture.init();
    defer f.deinit();
    try seed(&f.store);
    try f.store.exec("DROP TABLE attachment_refs; DROP TABLE attachments; UPDATE meta SET schema_version=6; PRAGMA user_version=6");
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try f.path(&path_buffer);
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    try std.testing.expectEqual(@as(i64, storage.schema_version), try f.store.scalar("PRAGMA user_version"));
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM messages WHERE id='m'"));
    try f.store.exec("INSERT INTO attachments VALUES('a',1,'h','fixture.txt','text/plain',3,'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','file',X'616263'); INSERT INTO attachment_refs VALUES('m','a',0)");
    try f.store.close();
    f.store = try storage.Store.open(std.testing.io, path);
    try std.testing.expectEqual(@as(i64, 1), try f.store.scalar("SELECT count(*) FROM attachments JOIN attachment_refs ON attachment_id=id WHERE content=X'616263'"));
}
