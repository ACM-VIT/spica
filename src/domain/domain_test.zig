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
        const w = try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = p.entity_ids.project.?, .binding = .{ .canonical_root = "/tmp/isolated", .filesystem_identity = "test", .repository_identity = "", .checkout_identity = "", .expected_branch = "", .base_revision = "", .non_git = true } } } });
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
