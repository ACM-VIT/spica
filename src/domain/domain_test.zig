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

test "real reducers accept arbitrary prompt dedup before revision and withdraw queued effects" {
    var f = try Fixture.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: domain.Owner = .{ .database = &f.store, .io = std.testing.io, .epoch = "one", .utc_ms = 1000 };
    const conversation = try Conversation.create(&owner, allocator);
    const command = conversation.send("send", "Any user text: 世界 é\x00\xf0\x9f", 1);
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
    const second = try consumer.command(.{ .command_id = .{ .value = "host-send-2" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "cancel me", .selection = selection } } });
    const active = try consumer.query(.{ .runs = .{ .thread = thread } });
    const active_run = active.items[1].run;
    _ = try consumer.command(.{ .command_id = .{ .value = "host-cancel" }, .target = .{ .run = second.entity_ids.run.? }, .expected_revision = .{ .revision = active_run.revision }, .payload = .{ .run_cancel = .{ .reason = "consumer cancel" } } });
    const cancelled = try consumer.query(.{ .runs = .{ .thread = thread } });
    try std.testing.expectEqual(t.RunState.cancelled, cancelled.items[1].run.state);
    const cancelled_messages = try consumer.query(.{ .messages = .{ .thread = thread } });
    try std.testing.expect(!cancelled_messages.items[3].message.incomplete);
    consumer.host.destroy();
    live = false;
    consumer.host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path_buffer[0..n], .wake = Consumer.wake, .wake_context = &consumer });
    live = true;
    const replay = try consumer.command(send);
    try std.testing.expectEqualStrings(run.value, replay.entity_ids.run.?.value);
    const retained = try consumer.query(.{ .runs = .{ .thread = thread } });
    try std.testing.expectEqual(@as(usize, 2), retained.items.len);
    try std.testing.expectEqual(t.RunState.completed, retained.items[0].run.state);
    try std.testing.expectEqual(t.RunState.cancelled, retained.items[1].run.state);
    const retained_messages = try consumer.query(.{ .messages = .{ .thread = thread } });
    try std.testing.expect(!retained_messages.items[1].message.incomplete);
    try std.testing.expect(!retained_messages.items[3].message.incomplete);
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
}
