//! App-owned durable conversation boundary. No UI or adapter owns durable state.
const std = @import("std");
pub const types = @import("domain/types.zig");
pub const store = @import("domain/store.zig");
const prompts = @import("domain/prompts.zig");
const attachments = @import("domain/attachments.zig");
const t = types;
const a = t.adapter;
const V = store.Value;
const common = @import("runtime/adapter.zig");
const Factory = common.Factory;
const Registry = @import("domain/registry.zig").Registry;
const Mcp = @import("orchestration_mcp.zig").Server;
pub const coordinator_tools = @import("orchestration_tools.zig");
pub const workspace_binding = @import("domain/workspace.zig");

/// Prompt admission is independent of the ordinary provider frame budget.
pub const start_frame_limit = (a.Limits{}).frame_bytes;
pub const attachment_packet_limit = start_frame_limit + (a.Limits{}).attachment_packet_bytes;
pub const max_prompt_bytes = prompts.max_bytes;
const generated_id_bytes = 32;
pub const StartPreflight = struct {
    prompt_bytes: usize,
    /// Accounted materialized request bytes; it is not an ordinary queue frame.
    frame_bytes: usize,
    max_prompt_bytes: usize,
    pub fn fits(self: StartPreflight) bool {
        return self.prompt_bytes <= self.max_prompt_bytes;
    }
};
pub fn startPreflight(prompt_bytes: usize) StartPreflight {
    const id = [_]u8{'0'} ** generated_id_bytes;
    const request: a.Request = .{ .start = .{ .correlation = .{
        .effect = .{ .value = &id },
        .run = .{ .value = &id },
        .session = .{ .value = &id },
    }, .prompt = "" } };
    return .{ .prompt_bytes = prompt_bytes, .frame_bytes = a.frameBytes(request) +| prompt_bytes, .max_prompt_bytes = max_prompt_bytes };
}

/// Journals retain intent and a content digest, while attachment bytes stay in
/// the dedicated durable table. This also makes retries compare metadata
/// exactly without copying binary bodies into command/event rows.
fn canonicalEnvelope(allocator: std.mem.Allocator, envelope: t.CommandEnvelope) !t.CommandEnvelope {
    var result = envelope;
    if (result.payload == .attachment_add) {
        result.payload.attachment_add.content = &.{};
    }
    const attached = switch (result.payload) {
        .followup_enqueue => |v| v.attachments,
        .followup_edit => |v| v.attachments,
        else => return result,
    };
    if (attached.len > attachments.max_count) return error.Limit;
    const metadata = try allocator.dupe(a.Attachment, attached);
    for (metadata) |*item| item.content = &.{};
    switch (result.payload) {
        .followup_enqueue => |*v| v.attachments = metadata,
        .followup_edit => |*v| v.attachments = metadata,
        else => unreachable,
    }
    return result;
}

// Every nested lookup is a point/range lookup on an existing primary/unique
// index (plus runs_by_thread). The preview reads only a prefix of one chunk.
const snooze_blockers = "EXISTS(SELECT 1 FROM runs r WHERE r.thread_id=threads.id AND r.state IN('queued','starting','awaiting_approval','awaiting_question')) OR EXISTS(SELECT 1 FROM approvals a INDEXED BY approvals_pending_thread WHERE a.state='pending' AND a.thread_id=threads.id) OR EXISTS(SELECT 1 FROM questions q INDEXED BY questions_pending_thread WHERE q.state='pending' AND q.thread_id=threads.id)";

const thread_columns = "SELECT rowid,id,revision,project_id,workspace_id,session_id,coalesce((SELECT selection FROM thread_selections WHERE thread_id=threads.id),(SELECT requested FROM runs WHERE thread_id=threads.id ORDER BY rowid DESC LIMIT 1)),coalesce((SELECT substr(bytes,1,163) FROM chunks WHERE block_id=(SELECT id FROM blocks WHERE message_id=(SELECT id FROM messages WHERE thread_id=threads.id AND ordinal=0 AND role='user') AND ordinal=0) AND byte_offset=0),''),(SELECT state FROM runs WHERE thread_id=threads.id ORDER BY rowid DESC LIMIT 1),coalesce((SELECT substr(display_name,1,256) FROM projects WHERE id=threads.project_id),''),coalesce((SELECT json_extract(CAST(binding AS TEXT),'$.canonical_root') FROM workspaces WHERE id=threads.workspace_id),''),coalesce((SELECT json_extract(CAST(binding AS TEXT),'$.expected_branch') FROM workspaces WHERE id=threads.workspace_id),''),coalesce(title,''),pinned,settled,snoozed_until,sort_order,created_at_ms,last_user_message_at_ms,updated_at_ms,NOT(" ++ snooze_blockers ++ "),archived FROM threads ";

fn canonicalRootKey(root: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
    return digest;
}

/// Internal single-thread reducer. Every returned slice belongs to the operation
/// allocator; callers must copy before resetting it. Never call from the UI.
pub const Owner = struct {
    database: *store.Store,
    io: std.Io,
    epoch: []const u8,
    utc_ms: ?u64,
    factory: ?Factory = null,
    limits: t.Limits = .{},
    workspace_root: ?[]const u8 = null,
    setup_factory: ?Factory = null,
    runtime_registry: ?*const Registry = null,

    fn liveRuntimeCount(self: *const Owner) usize {
        var count: usize = 0;
        if (self.runtime_registry) |registry| for (registry.entries) |entry| {
            if (entry != null) count += 1;
        };
        return count;
    }

    fn id(self: *Owner, allocator: std.mem.Allocator) ![]const u8 {
        var random: [generated_id_bytes / 2]u8 = undefined;
        try self.io.randomSecure(&random);
        const result = try allocator.alloc(u8, generated_id_bytes);
        const hex = "0123456789abcdef";
        for (random, 0..) |byte, i| {
            result[i * 2] = hex[byte >> 4];
            result[i * 2 + 1] = hex[byte & 15];
        }
        return result;
    }
    fn encoded(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
        return t.encode(value, try allocator.alloc(u8, 65536));
    }
    fn field(self: *Owner, allocator: std.mem.Allocator, sql: [:0]const u8, values: []const V) !?[]const u8 {
        const statement = try self.database.prepare(sql, values);
        defer statement.deinit();
        if (!try statement.step() or statement.isNull(0)) return null;
        return try allocator.dupe(u8, try statement.bytes(0));
    }
    fn scalar(self: *Owner, sql: [:0]const u8, values: []const V) !i64 {
        const statement = try self.database.prepare(sql, values);
        defer statement.deinit();
        if (!try statement.step()) return error.Corrupt;
        return statement.integer(0);
    }
    fn revision(self: *Owner, target: t.Target) !?u64 {
        const sql: [:0]const u8, const key: []const u8 = switch (target) {
            .absent => return null,
            .project => |v| .{ "SELECT revision FROM projects WHERE id=?", v.value },
            .workspace => |v| .{ "SELECT revision FROM workspaces WHERE id=?", v.value },
            .thread => |v| .{ "SELECT revision FROM threads WHERE id=? AND deleted=0", v.value },
            .run => |v| .{ "SELECT revision FROM runs WHERE id=? AND EXISTS(SELECT 1 FROM threads WHERE id=runs.thread_id AND deleted=0)", v.value },
            .approval => |v| .{ "SELECT revision FROM approvals WHERE id=? AND EXISTS(SELECT 1 FROM threads WHERE id=(SELECT thread_id FROM runs WHERE id=approvals.run_id) AND deleted=0)", v.value },
            .effect => |v| .{ "SELECT revision FROM effects WHERE id=? AND EXISTS(SELECT 1 FROM threads WHERE id=(SELECT thread_id FROM runs WHERE id=effects.run_id) AND deleted=0)", v.value },
            .question => |v| .{ "SELECT revision FROM questions WHERE id=? AND EXISTS(SELECT 1 FROM threads WHERE id=(SELECT thread_id FROM runs WHERE id=questions.run_id) AND deleted=0)", v.value },
            // Follow-up and attachment commands target effects/threads and
            // carry their own bounded revision checks in reduce.
            .followup, .attachment => return null,
        };
        const statement = try self.database.prepare(sql, &.{.{ .text = key }});
        defer statement.deinit();
        return if (try statement.step()) @intCast(statement.integer(0)) else null;
    }
    fn timeValue(self: *const Owner) store.Value {
        const utc = self.utc_ms orelse return .null;
        return if (utc <= std.math.maxInt(i64)) .{ .integer = @intCast(utc) } else .null;
    }
    fn event(self: *Owner, allocator: std.mem.Allocator, sequence: u64, index: u32, aggregate: t.AggregateRef, revision_value: u64, kind: []const u8, causation: ?t.CommandId, effect: ?a.EffectId, payload: []const u8) !void {
        const next = try self.database.prepare("SELECT coalesce(max(event_index)+1,0) FROM events WHERE sequence=?", &.{.{ .integer = @intCast(sequence) }});
        defer next.deinit();
        if (!try next.step()) return error.Corrupt;
        const position: u32 = @intCast(@max(index, next.integer(0)));
        try self.database.appendEvent(.{ .event_id = .{ .value = try self.id(allocator) }, .position = .{ .commit_sequence = sequence, .event_index = position }, .aggregate = aggregate, .aggregate_revision = revision_value, .kind = kind, .causation_command_id = causation, .effect_id = effect, .payload = payload });
    }
    fn plan(self: *Owner, allocator: std.mem.Allocator, effect: []const u8, run: []const u8, session: []const u8, kind: t.EffectKind, request: a.Request, dependency: ?[]const u8, approval: ?[]const u8, causation: t.CommandId) !void {
        // Attachment bodies are hydrated from the durable attachment table at
        // dispatch. Effects retain immutable metadata only.
        var persisted = request;
        var metadata: [8]a.Attachment = undefined;
        if (persisted == .start) {
            if (persisted.start.attachments.len > metadata.len) return error.Limit;
            for (persisted.start.attachments, 0..) |attachment, i| {
                metadata[i] = attachment;
                metadata[i].content = &.{};
            }
            persisted.start.attachments = metadata[0..persisted.start.attachments.len];
        } else if (persisted == .message) {
            if (persisted.message.attachments.len > metadata.len) return error.Limit;
            for (persisted.message.attachments, 0..) |attachment, i| {
                metadata[i] = attachment;
                metadata[i].content = &.{};
            }
            persisted.message.attachments = metadata[0..persisted.message.attachments.len];
        }
        const bytes = try encoded(allocator, persisted);
        const digest = t.digest(bytes);
        try self.database.execute("INSERT INTO effects(id,revision,run_id,session_id,kind,read_only,request,digest,state,depends_on,approval_id,command_id) VALUES(?,1,?,?,?,?,?,?,'planned',?,?,?)", &.{ .{ .text = effect }, .{ .text = run }, .{ .text = session }, .{ .text = @tagName(kind) }, .{ .integer = @intFromBool(request == .inspect or request == .attach) }, .{ .blob = bytes }, .{ .blob = &digest }, if (dependency) |v| .{ .text = v } else .null, if (approval) |v| .{ .text = v } else .null, .{ .text = causation.value } });
    }

    fn commandReplay(self: *Owner, allocator: std.mem.Allocator, e: t.CommandEnvelope) !?t.Receipt {
        const canonical = try encoded(allocator, try canonicalEnvelope(allocator, e));
        const output = try allocator.alloc(u8, 65536);
        const bytes = self.database.lookupCommand(e.command_id.value, canonical, output) catch |err| switch (err) {
            error.Conflict => {
                const stored = try self.database.prepare("SELECT canonical,receipt FROM commands WHERE command_id=?", &.{.{ .text = e.command_id.value }});
                defer stored.deinit();
                if (!try stored.step()) return error.Corrupt;
                const original = try t.decode(t.Receipt, try stored.bytes(1), allocator);
                const conflict: t.Receipt = .{ .command_id = e.command_id, .outcome = .rejected, .reason = .command_id_conflict, .commit_sequence = original.commit_sequence };
                // Schema 4 journaled the inline Send envelope. Recognize its
                // exact semantic retry before reserving any new prompt bytes.
                if (e.payload == .thread_send_staged) {
                    var previous = t.decode(t.CommandEnvelope, try stored.bytes(0), allocator) catch |parse_error| {
                        if (parse_error == error.OutOfMemory) return parse_error;
                        return conflict;
                    };
                    if (previous.payload == .thread_send) {
                        const p = previous.payload.thread_send;
                        previous.payload = .{ .thread_send_staged = .{ .prompt = prompts.reference(previous.command_id.value, p.text), .selection = p.selection, .attachments = p.attachments } };
                        if (a.equal(previous, e)) return original;
                    }
                }
                return conflict;
            },
            else => return err,
        };
        return if (bytes) |value| try t.decode(t.Receipt, value, allocator) else null;
    }
    pub fn stagePrompt(self: *Owner, ref: t.PromptRef, bytes: []const u8) !void {
        try prompts.begin(self.database, ref);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + prompts.chunk_bytes);
            try prompts.append(self.database, ref, offset, bytes[offset..end]);
            offset = end;
        }
        var buffer: [prompts.max_bytes]u8 = undefined;
        try prompts.complete(self.database, ref, &buffer);
    }

    /// Lookup precedes validation. Rejections are durable and byte-exact retries
    /// return their original receipt even after aggregate revisions have changed.
    pub fn command(self: *Owner, allocator: std.mem.Allocator, envelope: t.CommandEnvelope) !t.Receipt {
        if (envelope.payload == .thread_send) {
            const p = envelope.payload.thread_send;
            if (p.text.len != 0 and p.text.len <= max_prompt_bytes and std.unicode.utf8ValidateSlice(p.text)) {
                const ref = prompts.reference(envelope.command_id.value, p.text);
                var compact = envelope;
                compact.payload = .{ .thread_send_staged = .{ .prompt = ref, .selection = p.selection, .attachments = p.attachments } };
                // Receipt lookup must precede staging: a retry after consumption
                // must work even when all upload reservations are in use.
                if (try self.commandReplay(allocator, compact)) |receipt| return receipt;
                try self.stagePrompt(ref, p.text);
                return self.command(allocator, compact);
            }
        }
        return self.commandCanonical(allocator, envelope, null);
    }
    fn commandCanonical(self: *Owner, allocator: std.mem.Allocator, envelope: t.CommandEnvelope, refusal: ?t.Reason) !t.Receipt {
        const canonical = try encoded(allocator, try canonicalEnvelope(allocator, envelope));
        const output = try allocator.alloc(u8, 65536);
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        if (self.database.lookupCommand(envelope.command_id.value, canonical, output) catch |err| switch (err) {
            error.Conflict => {
                const stored = try self.field(allocator, "SELECT receipt FROM commands WHERE command_id=?", &.{.{ .text = envelope.command_id.value }}) orelse return error.Corrupt;
                const original = try t.decode(t.Receipt, stored, allocator);
                try self.database.rollback();
                return .{ .command_id = envelope.command_id, .outcome = .rejected, .reason = .command_id_conflict, .commit_sequence = original.commit_sequence };
            },
            else => return err,
        }) |previous| {
            const receipt = try t.decode(t.Receipt, previous, allocator);
            try self.database.rollback();
            return receipt;
        }
        const sequence = try self.database.nextSequence();
        const current = try self.revision(envelope.target);
        var receipt: t.Receipt = .{ .command_id = envelope.command_id, .outcome = .rejected, .commit_sequence = sequence, .current_revision = current };
        var reason: ?t.Reason = if (envelope.contract_version != 1) .unsupported_version else refusal;
        if (reason == null) switch (envelope.expected_revision) {
            .absent => if (current != null) {
                reason = .revision_conflict;
            },
            .revision => |expected| if (current == null) {
                reason = .not_found;
            } else if (current.? != expected or expected >= std.math.maxInt(i64)) {
                reason = .revision_conflict;
            },
        };
        try self.database.exec("SAVEPOINT mutation");
        if (reason == null) reason = try self.reduce(allocator, envelope, &receipt);
        if (reason) |rejected| {
            try self.database.exec("ROLLBACK TO mutation; RELEASE mutation");
            receipt.reason = rejected;
            receipt.entity_ids = .{};
            receipt.effect_ids = &.{};
            receipt.committed_revisions = &.{};
        } else {
            try self.database.exec("RELEASE mutation");
            receipt.outcome = .accepted;
            if (envelope.target == .run) try self.finalizeMessages(envelope.target.run.value);
            receipt.committed_revisions = try self.database.committedRevisions(allocator);
            try self.database.publishChanges(sequence, envelope.command_id);
        }
        // A definitive receipt releases its upload. Unknown storage/transport
        // failures keep the reservation for an exact retry or explicit discard.
        if (envelope.payload == .thread_send_staged) try prompts.discardMatching(self.database, envelope.payload.thread_send_staged.prompt);
        const bytes = try encoded(allocator, receipt);
        try self.database.recordCommand(envelope.command_id.value, canonical, bytes, sequence);
        try self.database.commit();
        return receipt;
    }
    fn guardRunRevisions(self: *Owner, run: []const u8) !void {
        const statement = try self.database.prepare("SELECT 1 FROM effects WHERE run_id=? AND revision=9223372036854775807 UNION ALL SELECT 1 FROM approvals WHERE run_id=? AND revision=9223372036854775807 UNION ALL SELECT 1 FROM runs WHERE id=? AND revision=9223372036854775807", &.{ .{ .text = run }, .{ .text = run }, .{ .text = run } });
        defer statement.deinit();
        if (try statement.step()) return error.Limit;
    }
    /// Attention is recorded in the same observation/delivery transaction.
    /// Call only after deduplication and accepted fresh attention evidence.
    fn wakeSnoozed(self: *Owner, allocator: std.mem.Allocator, sequence: u64, effect: ?a.EffectId, run: []const u8) !void {
        const now = self.utc_ms orelse return;
        if (now > std.math.maxInt(i64)) return error.Limit;
        const statement = try self.database.prepare("SELECT t.id,t.revision FROM threads t JOIN runs r ON r.thread_id=t.id WHERE r.id=? AND t.snoozed_until>?", &.{ .{ .text = run }, .{ .integer = @intCast(now) } });
        defer statement.deinit();
        if (!try statement.step()) return;
        if (statement.integer(1) == std.math.maxInt(i64)) return error.Limit;
        const thread = try allocator.dupe(u8, try statement.bytes(0));
        const revision_value: u64 = @intCast(statement.integer(1) + 1);
        try self.database.execute("UPDATE threads SET snoozed_until=0,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?", &.{ self.timeValue(), .{ .text = thread } });
        try self.event(allocator, sequence, 0, .{ .thread = .{ .value = thread } }, revision_value, "ThreadWoke", null, effect, "");
    }
    fn touchMessage(self: *Owner, message: []const u8) !void {
        const s = try self.database.prepare("SELECT revision FROM messages WHERE id=?", &.{.{ .text = message }});
        defer s.deinit();
        if (!try s.step()) return error.Corrupt;
        if (s.integer(0) == std.math.maxInt(i64)) return error.Limit;
        try self.database.execute("UPDATE messages SET revision=revision+1 WHERE id=?", &.{.{ .text = message }});
    }
    /// Terminal metadata is canonical domain state, not a UI-derived flag.
    fn finalizeMessages(self: *Owner, run: []const u8) !void {
        const s = try self.database.prepare("SELECT 1 FROM messages m JOIN runs r ON r.id=m.run_id WHERE r.id=? AND r.state IN('completed','cancelled','failed') AND m.incomplete=1 AND m.revision=9223372036854775807", &.{.{ .text = run }});
        defer s.deinit();
        if (try s.step()) return error.Limit;
        try self.database.execute("UPDATE messages SET incomplete=0,revision=revision+1 WHERE run_id=? AND incomplete=1 AND EXISTS(SELECT 1 FROM runs WHERE id=? AND state IN('completed','cancelled','failed'))", &.{ .{ .text = run }, .{ .text = run } });
    }
    fn reduce(self: *Owner, allocator: std.mem.Allocator, e: t.CommandEnvelope, r: *t.Receipt) anyerror!?t.Reason {
        return self.reduceWithPrompt(allocator, e, r, null);
    }
    fn reduceWithPrompt(self: *Owner, allocator: std.mem.Allocator, e: t.CommandEnvelope, r: *t.Receipt, staged_ref: ?t.PromptRef) anyerror!?t.Reason {
        const db = self.database;
        const seq = r.commit_sequence;
        var aggregate: t.AggregateRef = undefined;
        var revision_value: u64 = 1;
        var event_payload: []const u8 = "";
        const visibility_sql: ?[:0]const u8, const visibility_key: []const u8 = switch (e.target) {
            .thread => |v| .{ "SELECT archived FROM threads WHERE id=? AND deleted=0", v.value },
            .run => |v| .{ "SELECT archived FROM threads WHERE id=(SELECT thread_id FROM runs WHERE id=?) AND deleted=0", v.value },
            .effect => |v| .{ "SELECT archived FROM threads WHERE id=(SELECT thread_id FROM runs WHERE id=(SELECT run_id FROM effects WHERE id=?)) AND deleted=0", v.value },
            .approval => |v| .{ "SELECT archived FROM threads WHERE id=(SELECT thread_id FROM approvals WHERE id=?) AND deleted=0", v.value },
            .question => |v| .{ "SELECT archived FROM threads WHERE id=(SELECT thread_id FROM questions WHERE id=?) AND deleted=0", v.value },
            else => .{ null, "" },
        };
        if (visibility_sql) |sql| {
            const visible = try db.prepare(sql, &.{.{ .text = visibility_key }});
            defer visible.deinit();
            if (!try visible.step()) return .not_found;
            if (visible.integer(0) != 0 and e.payload != .thread_restore and e.payload != .thread_delete) return .invalid_command;
        }
        switch (e.payload) {
            .unsupported => return .unsupported_kind,
            .runtime_configure, .runtime_refresh, .runtime_login => {
                if (e.target != .absent or e.expected_revision != .absent) return .invalid_command;
                if (self.setup_factory == null) return .capability_unavailable;
                // Recovery keeps uncertain work in the journal, but it owns no
                // process in this Host. It must not prevent account setup for
                // other chats. Live adapters and accepted dispatches still do.
                if (self.liveRuntimeCount() != 0) return .busy;
                if (try db.scalar("SELECT EXISTS(SELECT 1 FROM runs WHERE state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested')) OR EXISTS(SELECT 1 FROM effects WHERE state='in_flight')") != 0) return .busy;
                // The command record commits explicit intent before Host performs
                // any configuration, provider discovery or login side effect.
                return null;
            },
            .project_create => |p| {
                if (e.target != .absent or e.expected_revision != .absent or p.display_name.len == 0) return .invalid_command;
                const key = try self.id(allocator);
                try db.execute("INSERT INTO projects VALUES(?,1,?)", &.{ .{ .text = key }, .{ .blob = p.display_name } });
                r.entity_ids.project = .{ .value = key };
                aggregate = .{ .project = r.entity_ids.project.? };
            },
            .workspace_register => |p| {
                if (e.target != .absent or e.expected_revision != .absent or p.binding.canonical_root.len == 0 or p.binding.canonical_root[0] != '/') return .invalid_command;
                if (self.factory != null and !(workspace_binding.verify(allocator, self.io, p.binding) catch false)) return .workspace_mismatch;
                if (try self.revision(.{ .project = p.project }) == null) return .not_found;
                const key = try self.id(allocator);
                try db.execute("INSERT INTO workspaces VALUES(?,1,?,?)", &.{ .{ .text = key }, .{ .text = p.project.value }, .{ .blob = try encoded(allocator, p.binding) } });
                r.entity_ids.workspace = .{ .value = key };
                aggregate = .{ .workspace = r.entity_ids.workspace.? };
            },
            .thread_create => |p| {
                if (e.target != .absent or e.expected_revision != .absent) return .invalid_command;
                const project = try self.field(allocator, "SELECT project_id FROM workspaces WHERE id=?", &.{.{ .text = p.workspace.value }}) orelse return .not_found;
                if (!std.mem.eql(u8, project, p.project.value)) return .workspace_mismatch;
                const binding_bytes = try self.field(allocator, "SELECT binding FROM workspaces WHERE id=?", &.{.{ .text = p.workspace.value }}) orelse return .workspace_mismatch;
                const binding = t.decode(t.WorkspaceBinding, binding_bytes, allocator) catch return .workspace_mismatch;
                if (binding.canonical_root.len == 0) return .workspace_mismatch;
                const root_key = canonicalRootKey(binding.canonical_root);
                const key = try self.id(allocator);
                const creation = try db.scalar("SELECT coalesce(max(rowid),0) FROM threads");
                const ordinal = std.math.add(i64, creation, 1) catch return .admission_limit;
                const order = std.math.mul(i64, ordinal, -1024) catch return .admission_limit;
                try db.execute("INSERT INTO threads(id,revision,project_id,workspace_id,root_key,sort_order,created_at_ms,updated_at_ms) VALUES(?,1,?,?,?, ?,coalesce(?,0),coalesce(?,0))", &.{ .{ .text = key }, .{ .text = p.project.value }, .{ .text = p.workspace.value }, .{ .blob = &root_key }, .{ .integer = order }, self.timeValue(), self.timeValue() });
                r.entity_ids.thread = .{ .value = key };
                aggregate = .{ .thread = r.entity_ids.thread.? };
            },
            .thread_archive, .thread_restore, .thread_delete => {
                if (e.target != .thread or e.expected_revision != .revision) return .invalid_command;
                const thread = e.target.thread.value;
                const row = try db.prepare("SELECT archived,session_id FROM threads WHERE id=? AND deleted=0", &.{.{ .text = thread }});
                defer row.deinit();
                if (!try row.step()) return .not_found;
                if (e.payload == .thread_restore and row.integer(0) == 0) return .invalid_command;
                if (e.payload != .thread_restore) {
                    // A sidebar mutation never shuts down a process or guesses
                    // whether an uncertain effect executed. The domain rejects
                    // until execution ownership has explicitly been resolved.
                    if (self.runtime_registry) |registry| for (registry.entries) |entry| {
                        if (entry) |live| {
                            if ((!row.isNull(1) and std.mem.eql(u8, try row.bytes(1), live.session.value)) or
                                try self.scalar("SELECT EXISTS(SELECT 1 FROM runs WHERE thread_id=? AND session_id=?)", &.{ .{ .text = thread }, .{ .text = live.session.value } }) != 0) return .busy;
                        }
                    };
                    if (try self.scalar("SELECT EXISTS(SELECT 1 FROM runs WHERE thread_id=? AND state NOT IN('completed','cancelled','failed')) OR EXISTS(SELECT 1 FROM runs r JOIN effects e ON e.run_id=r.id WHERE r.thread_id=? AND e.state IN('planned','in_flight','unknown')) OR EXISTS(SELECT 1 FROM approvals WHERE thread_id=? AND state='pending') OR EXISTS(SELECT 1 FROM questions WHERE thread_id=? AND state='pending')", &.{ .{ .text = thread }, .{ .text = thread }, .{ .text = thread }, .{ .text = thread } }) != 0) return .busy;
                }
                try db.execute(switch (e.payload) {
                    .thread_archive => "UPDATE threads SET archived=1,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?",
                    .thread_restore => "UPDATE threads SET archived=0,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?",
                    .thread_delete => "UPDATE threads SET deleted=1,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?",
                    else => unreachable,
                }, &.{ self.timeValue(), .{ .text = thread } });
                r.entity_ids.thread = e.target.thread;
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
            },
            .thread_title_set => |p| {
                if (e.target != .thread or e.expected_revision != .revision or
                    p.title.len == 0 or p.title.len > t.max_title_bytes or
                    !std.unicode.utf8ValidateSlice(p.title) or
                    std.mem.indexOfScalar(u8, p.title, 0) != null)
                    return .invalid_command;
                for (p.title) |byte| if (byte < 0x20 or byte == 0x7f) return .invalid_command;
                const thread = e.target.thread.value;
                if (try self.field(allocator, "SELECT id FROM threads WHERE id=?", &.{.{ .text = thread }}) == null) return .not_found;
                try db.execute("UPDATE threads SET title=?,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?", &.{ .{ .blob = p.title }, self.timeValue(), .{ .text = thread } });
                r.entity_ids.thread = e.target.thread;
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
                event_payload = try encoded(allocator, p);
            },
            .thread_sidebar_set => |p| {
                if (e.target != .thread or e.expected_revision != .revision or
                    (p.pinned == null and p.settled == null and p.snoozed_until == null and !p.clear_snooze and p.sort_order == null) or
                    (p.clear_snooze and p.snoozed_until != null)) return .invalid_command;
                if (p.snoozed_until) |deadline| {
                    if (deadline <= 0) return .invalid_command;
                    const now = self.utc_ms orelse return .authority_unavailable;
                    if (@as(u64, @intCast(deadline)) <= now) return .invalid_command;
                    if (try self.field(allocator, "SELECT id FROM threads WHERE id=? AND (" ++ snooze_blockers ++ ")", &.{.{ .text = e.target.thread.value }}) != null) return .busy;
                }
                var order = p.sort_order;
                if (p.pinned == true and order == null) {
                    const existing = try db.prepare("SELECT pinned FROM threads WHERE id=?", &.{.{ .text = e.target.thread.value }});
                    defer existing.deinit();
                    if (!try existing.step()) return .not_found;
                    if (existing.integer(0) == 0) {
                        const first = try db.scalar("SELECT coalesce(min(sort_order),0) FROM threads WHERE pinned=1 AND archived=0 AND deleted=0");
                        order = std.math.sub(i64, first, 1024) catch return .admission_limit;
                    }
                }
                try db.execute("UPDATE threads SET pinned=coalesce(?,pinned),settled=coalesce(?,settled),snoozed_until=CASE WHEN ? THEN 0 ELSE coalesce(?,snoozed_until) END,sort_order=coalesce(?,sort_order),revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?", &.{
                    if (p.pinned) |value| .{ .integer = @intFromBool(value) } else .null,
                    if (p.settled) |value| .{ .integer = @intFromBool(value) } else .null,
                    .{ .integer = @intFromBool(p.clear_snooze) },
                    if (p.snoozed_until) |value| .{ .integer = value } else .null,
                    if (order) |value| .{ .integer = value } else .null,
                    self.timeValue(),
                    .{ .text = e.target.thread.value },
                });
                r.entity_ids.thread = e.target.thread;
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
                event_payload = try encoded(allocator, p);
            },
            .thread_sidebar_move => |p| {
                if (e.target != .thread or e.expected_revision != .revision) return .invalid_command;
                const now = self.utc_ms orelse return .authority_unavailable;
                if (now > std.math.maxInt(i64)) return .authority_unavailable;
                const source = try db.prepare("SELECT pinned,settled,snoozed_until,sort_order,root_key,(SELECT json_extract(CAST(binding AS TEXT),'$.canonical_root') FROM workspaces WHERE id=threads.workspace_id) FROM threads WHERE id=?", &.{.{ .text = e.target.thread.value }});
                defer source.deinit();
                if (!try source.step()) return .not_found;
                const original_order = source.integer(3);
                const source_root = try source.bytes(5);
                const source_digest = canonicalRootKey(source_root);
                if (!std.mem.eql(u8, &source_digest, try source.bytes(4))) return .workspace_mismatch;
                const neighbor = try db.prepare(if (p.direction == .up)
                    "SELECT id,revision,sort_order FROM threads WHERE archived=0 AND deleted=0 AND root_key=? AND EXISTS(SELECT 1 FROM workspaces w WHERE w.id=threads.workspace_id AND json_extract(CAST(w.binding AS TEXT),'$.canonical_root')=?) AND (CASE WHEN snoozed_until>? THEN 3 WHEN settled=1 THEN 2 WHEN pinned=1 THEN 1 ELSE 0 END)=? AND (sort_order,id)<(?,?) ORDER BY sort_order DESC,id DESC LIMIT 1"
                else
                    "SELECT id,revision,sort_order FROM threads WHERE archived=0 AND deleted=0 AND root_key=? AND EXISTS(SELECT 1 FROM workspaces w WHERE w.id=threads.workspace_id AND json_extract(CAST(w.binding AS TEXT),'$.canonical_root')=?) AND (CASE WHEN snoozed_until>? THEN 3 WHEN settled=1 THEN 2 WHEN pinned=1 THEN 1 ELSE 0 END)=? AND (sort_order,id)>(?,?) ORDER BY sort_order,id LIMIT 1", &.{
                    .{ .blob = &source_digest },
                    .{ .text = source_root },
                    .{ .integer = @intCast(now) },
                    .{ .integer = if (source.integer(2) > @as(i64, @intCast(now))) 3 else if (source.integer(1) != 0) 2 else if (source.integer(0) != 0) 1 else 0 },
                    .{ .integer = original_order },
                    .{ .text = e.target.thread.value },
                });
                defer neighbor.deinit();
                if (!try neighbor.step()) return .invalid_command;
                const neighbor_id = try allocator.dupe(u8, try neighbor.bytes(0));
                const neighbor_revision = neighbor.integer(1);
                if (neighbor_revision < 0) return error.Corrupt;
                if (neighbor_revision >= std.math.maxInt(i64)) return .admission_limit;
                if (neighbor.integer(2) == original_order) return .invalid_command;
                try db.execute("UPDATE threads SET sort_order=?,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?", &.{ .{ .integer = neighbor.integer(2) }, self.timeValue(), .{ .text = e.target.thread.value } });
                try db.execute("UPDATE threads SET sort_order=?,revision=revision+1,updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?", &.{ .{ .integer = original_order }, self.timeValue(), .{ .text = neighbor_id } });
                r.entity_ids.thread = e.target.thread;
                const payload = try encoded(allocator, p);
                try self.event(allocator, seq, 0, .{ .thread = e.target.thread }, e.expected_revision.revision + 1, "ThreadSidebarChanged", e.command_id, null, payload);
                try self.event(allocator, seq, 1, .{ .thread = .{ .value = neighbor_id } }, @intCast(neighbor_revision + 1), "ThreadSidebarChanged", e.command_id, null, payload);
                return null;
            },
            .thread_select => |p| {
                if (e.target != .thread or e.expected_revision != .revision) return .invalid_command;
                const workspace = try self.field(allocator, "SELECT workspace_id FROM threads WHERE id=?", &.{.{ .text = e.target.thread.value }}) orelse return .not_found;
                if (!std.mem.eql(u8, workspace, p.selection.workspace.value)) return .workspace_mismatch;
                if (try self.field(allocator, "SELECT id FROM runs WHERE thread_id=? AND state NOT IN('completed','cancelled','failed')", &.{.{ .text = e.target.thread.value }}) != null) return .busy;
                var supported = false;
                if (self.factory) |factory| {
                    for (factory.models()) |model| {
                        var candidate = model.selection;
                        candidate.workspace = p.selection.workspace;
                        candidate.effort = p.selection.effort;
                        if (!a.equal(candidate, p.selection)) continue;
                        for (model.supported_efforts) |effort| if (std.mem.eql(u8, effort, p.selection.effort)) {
                            supported = true;
                        };
                    }
                }
                if (std.mem.eql(u8, p.selection.runtime_kind, "fake") and std.mem.eql(u8, p.selection.required_runtime_version, "1") and std.mem.eql(u8, p.selection.model_provider, "fake") and std.mem.eql(u8, p.selection.model_id, "fixture") and std.mem.eql(u8, p.selection.account_ref, "fixture") and std.mem.eql(u8, p.selection.effort, "none") and p.selection.capability_revision == 1) supported = true;
                if (!supported) return .selection_mismatch;
                try db.execute("INSERT INTO thread_selections VALUES(?,?) ON CONFLICT(thread_id) DO UPDATE SET selection=excluded.selection", &.{ .{ .text = e.target.thread.value }, .{ .blob = try encoded(allocator, p.selection) } });
                try db.execute("UPDATE threads SET revision=revision+1 WHERE id=?", &.{.{ .text = e.target.thread.value }});
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
                r.entity_ids.thread = e.target.thread;
            },
            .followup_enqueue => |p| {
                if (e.target != .run or e.expected_revision != .revision or p.content.len == 0) return .followup_invalid;
                const run = e.target.run.value;
                const state = try self.field(allocator, "SELECT state FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return .not_found;
                if (!(std.mem.eql(u8, state, "starting") or std.mem.eql(u8, state, "streaming") or std.mem.eql(u8, state, "awaiting_approval"))) return .busy;
                const requested = try self.field(allocator, "SELECT requested FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return error.Corrupt;
                const selection = try t.decode(a.Selection, requested, allocator);
                if (self.factory) |runtime| {
                    if (runtime.discover(selection).capabilities[@intFromEnum(a.Capability.followup_queue)].status != .supported) return .capability_unavailable;
                    if (p.attachments.len != 0 and runtime.discover(selection).capabilities[@intFromEnum(a.Capability.attachment)].status != .supported) return .attachment_unsupported;
                } else if (p.attachments.len != 0 and !std.mem.eql(u8, selection.runtime_kind, "codex")) {
                    return .attachment_unsupported;
                }
                if (try self.validateFollowupAttachments(allocator, run, selection, p.attachments)) |reason| return reason;
                const count = try self.scalar("SELECT count(*) FROM effects WHERE run_id=? AND kind='message' AND state='planned' AND instr(CAST(request AS TEXT),'\"followup\":{\"id\"')>0", &.{.{ .text = run }});
                if (count >= 8) return .followup_limit;
                const session = try self.field(allocator, "SELECT session_id FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return error.Corrupt;
                const effect_id = try self.id(allocator);
                const message_id = try self.id(allocator);
                const request: a.Request = .{ .message = .{
                    .correlation = .{ .effect = .{ .value = effect_id }, .session = .{ .value = session }, .run = e.target.run, .followup = .{ .value = effect_id } },
                    .message = .{ .value = message_id },
                    .content = p.content,
                    .attachments = p.attachments,
                    .followup = .{ .id = .{ .value = effect_id }, .content = p.content },
                } };
                if (a.frameBytes(request) > @min(attachment_packet_limit, start_frame_limit +| self.limits.attachment_packet_bytes)) return .admission_limit;
                const dependency = try self.field(allocator, "SELECT id FROM effects WHERE run_id=? AND kind='message' AND state='planned' AND instr(CAST(request AS TEXT),'\"followup\":{\"id\"')>0 AND NOT EXISTS(SELECT 1 FROM effects child WHERE child.depends_on=effects.id AND child.state='planned') ORDER BY rowid DESC LIMIT 1", &.{.{ .text = run }});
                try self.plan(allocator, effect_id, run, session, .message, request, dependency, null, e.command_id);
                r.entity_ids.run = e.target.run;
                r.entity_ids.followup = .{ .value = effect_id };
                r.effect_ids = try allocator.dupe(a.EffectId, &.{.{ .value = effect_id }});
                aggregate = .{ .run = e.target.run };
                revision_value = e.expected_revision.revision + 1;
            },
            .followup_edit => |p| {
                if (e.target != .effect or e.expected_revision != .revision or p.content.len == 0) return .followup_invalid;
                const statement = try db.prepare("SELECT run_id,session_id,kind,state,request FROM effects WHERE id=?", &.{.{ .text = e.target.effect.value }});
                defer statement.deinit();
                if (!try statement.step()) return .followup_not_found;
                if (!std.mem.eql(u8, try statement.bytes(2), "message") or !std.mem.eql(u8, try statement.bytes(3), "planned")) return .followup_invalid;
                var request = try t.decode(a.Request, try statement.bytes(4), allocator);
                if (request != .message or request.message.followup == null) return .followup_invalid;
                const requested = try self.field(allocator, "SELECT requested FROM runs WHERE id=?", &.{.{ .text = try statement.bytes(0) }}) orelse return error.Corrupt;
                const selection = try t.decode(a.Selection, requested, allocator);
                if (p.attachments.len != 0) {
                    if (self.factory) |runtime| {
                        if (runtime.discover(selection).capabilities[@intFromEnum(a.Capability.attachment)].status != .supported) return .attachment_unsupported;
                    } else if (!std.mem.eql(u8, selection.runtime_kind, "codex")) return .attachment_unsupported;
                }
                if (try self.validateFollowupAttachments(allocator, try statement.bytes(0), selection, p.attachments)) |reason| return reason;
                request.message.content = p.content;
                var metadata: [8]a.Attachment = undefined;
                if (p.attachments.len > metadata.len) return .attachment_limit;
                for (p.attachments, 0..) |attachment, i| {
                    metadata[i] = attachment;
                    metadata[i].content = &.{};
                }
                request.message.attachments = metadata[0..p.attachments.len];
                request.message.followup.?.content = p.content;
                if (a.frameBytes(request) > @min(attachment_packet_limit, start_frame_limit +| self.limits.attachment_packet_bytes)) return .admission_limit;
                const bytes = try encoded(allocator, request);
                const digest = t.digest(bytes);
                try db.execute("UPDATE effects SET request=?,digest=?,revision=revision+1 WHERE id=? AND state='planned'", &.{ .{ .blob = bytes }, .{ .blob = &digest }, .{ .text = e.target.effect.value } });
                r.entity_ids.followup = .{ .value = e.target.effect.value };
                aggregate = .{ .effect = e.target.effect };
                revision_value = e.expected_revision.revision + 1;
            },
            .followup_cancel => |p| {
                if (e.target != .effect or e.expected_revision != .revision or p.reason.len == 0) return .followup_invalid;
                const statement = try db.prepare("SELECT run_id,kind,state FROM effects WHERE id=?", &.{.{ .text = e.target.effect.value }});
                defer statement.deinit();
                if (!try statement.step()) return .followup_not_found;
                if (!std.mem.eql(u8, try statement.bytes(1), "message")) return .followup_invalid;
                if (!std.mem.eql(u8, try statement.bytes(2), "planned")) return .followup_invalid;
                const request_bytes = try self.field(allocator, "SELECT request FROM effects WHERE id=?", &.{.{ .text = e.target.effect.value }}) orelse return .followup_not_found;
                const existing_request = try t.decode(a.Request, request_bytes, allocator);
                if (existing_request != .message or existing_request.message.followup == null) return .followup_invalid;
                try db.execute("UPDATE effects SET state='withdrawn',outcome=?,revision=revision+1 WHERE id=? AND state='planned'", &.{ .{ .blob = p.reason }, .{ .text = e.target.effect.value } });
                r.entity_ids.followup = .{ .value = e.target.effect.value };
                aggregate = .{ .effect = e.target.effect };
                revision_value = e.expected_revision.revision + 1;
            },
            .followup_order => |p| {
                if (e.target != .run or e.expected_revision != .revision or p.followups.len == 0 or p.followups.len > 8) return .followup_invalid;
                const run = e.target.run.value;
                const state = try self.field(allocator, "SELECT state FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return .not_found;
                if (!(std.mem.eql(u8, state, "starting") or std.mem.eql(u8, state, "streaming") or std.mem.eql(u8, state, "awaiting_approval"))) return .busy;
                const expected = try self.scalar("SELECT count(*) FROM effects WHERE run_id=? AND kind='message' AND state='planned' AND instr(CAST(request AS TEXT),'\"followup\":{\"id\"')>0", &.{.{ .text = run }});
                if (expected != @as(i64, @intCast(p.followups.len))) return .followup_invalid;
                for (p.followups, 0..) |followup, i| {
                    for (p.followups[0..i]) |previous| if (std.mem.eql(u8, previous.value, followup.value)) return .followup_invalid;
                    const found = try db.prepare("SELECT run_id,kind,state FROM effects WHERE id=?", &.{.{ .text = followup.value }});
                    defer found.deinit();
                    if (!try found.step() or !std.mem.eql(u8, try found.bytes(0), run) or !std.mem.eql(u8, try found.bytes(1), "message") or !std.mem.eql(u8, try found.bytes(2), "planned")) return .followup_not_found;
                    const request_bytes = try self.field(allocator, "SELECT request FROM effects WHERE id=?", &.{.{ .text = followup.value }}) orelse return .followup_not_found;
                    const request = try t.decode(a.Request, request_bytes, allocator);
                    if (request != .message or request.message.followup == null or !std.mem.eql(u8, request.message.followup.?.id.value, followup.value)) return .followup_not_found;
                }
                try db.execute("UPDATE effects SET depends_on=NULL WHERE run_id=? AND kind='message' AND state='planned' AND instr(CAST(request AS TEXT),'\"followup\":{\"id\"')>0", &.{.{ .text = run }});
                for (p.followups, 0..) |followup, i| if (i != 0) try db.execute("UPDATE effects SET depends_on=? WHERE id=? AND state='planned'", &.{ .{ .text = p.followups[i - 1].value }, .{ .text = followup.value } });
                aggregate = .{ .run = e.target.run };
                revision_value = e.expected_revision.revision + 1;
            },
            .question_answer => |p| {
                if (e.target != .question or e.expected_revision != .revision) return .question_invalid;
                const statement = try db.prepare("SELECT run_id,session_id,question,state,live_epoch,expires_at FROM questions WHERE id=?", &.{.{ .text = e.target.question.value }});
                defer statement.deinit();
                if (!try statement.step()) return .not_found;
                if (!std.mem.eql(u8, try statement.bytes(3), "pending") or statement.isNull(4) or !std.mem.eql(u8, try statement.bytes(4), self.epoch)) return .question_invalid;
                if (!statement.isNull(5) and (self.utc_ms == null or self.utc_ms.? >= @as(u64, @intCast(statement.integer(5))))) return .question_expired;
                if (self.factory) |runtime| {
                    const requested = try self.field(allocator, "SELECT requested FROM runs WHERE id=?", &.{.{ .text = try statement.bytes(0) }}) orelse return error.Corrupt;
                    const selection = try t.decode(a.Selection, requested, allocator);
                    if (runtime.discover(selection).capabilities[@intFromEnum(a.Capability.question)].status != .supported) return .capability_unavailable;
                }
                try a.validateQuestionAnswer(p.answer, .{});
                const pending_question = try t.decode(a.Question, try statement.bytes(2), allocator);
                if (!pending_question.allow_freeform and p.answer.text.len != 0) return .question_invalid;
                if (!pending_question.allow_multiple and p.answer.choice_ids.len > 1) return .question_invalid;
                if (!pending_question.allow_freeform and pending_question.choices.len != 0 and p.answer.choice_ids.len == 0) return .question_invalid;
                for (p.answer.choice_ids) |choice_id| {
                    var found = false;
                    for (pending_question.choices) |choice| {
                        if (std.mem.eql(u8, choice.id, choice_id)) found = true;
                    }
                    if (!found) return .question_invalid;
                }
                const run = try allocator.dupe(u8, try statement.bytes(0));
                const session = try allocator.dupe(u8, try statement.bytes(1));
                const question = try allocator.dupe(u8, e.target.question.value);
                const effect_id = try self.id(allocator);
                const request: a.Request = .{ .answer_question = .{ .correlation = .{ .effect = .{ .value = effect_id }, .session = .{ .value = session }, .run = .{ .value = run }, .question = e.target.question }, .question = e.target.question, .answer = p.answer } };
                if (a.frameBytes(request) > start_frame_limit) return .admission_limit;
                try self.plan(allocator, effect_id, run, session, .message, request, null, null, e.command_id);
                try db.execute("UPDATE questions SET state='resolved',answer=?,reply_effect=?,revision=revision+1 WHERE id=? AND state='pending'", &.{ .{ .blob = try encoded(allocator, p.answer) }, .{ .text = effect_id }, .{ .text = question } });
                try db.execute("UPDATE runs SET state='streaming',revision=revision+1 WHERE id=? AND state='awaiting_question'", &.{.{ .text = run }});
                r.entity_ids = .{ .run = .{ .value = run }, .question = e.target.question };
                r.effect_ids = try allocator.dupe(a.EffectId, &.{.{ .value = effect_id }});
                aggregate = .{ .question = e.target.question };
                revision_value = e.expected_revision.revision + 1;
            },
            .prompt_discard => |p| {
                if (e.target != .absent or e.expected_revision != .absent) return .invalid_command;
                if (p.id) |upload| {
                    if (upload.len == 0 or upload.len > 128) return .invalid_command;
                    try prompts.discard(db, upload);
                } else prompts.discardOldest(db) catch |err| return switch (err) {
                    error.Busy => .busy,
                    error.NotFound => .not_found,
                    else => .prompt_invalid,
                };
                return null;
            },
            .thread_send_staged => |p| {
                if (e.target != .thread or e.expected_revision != .revision or !prompts.validForDomain(p.prompt)) return .invalid_command;
                var prompt_buffer: [prompts.max_bytes]u8 = undefined;
                const prompt = prompts.read(db, p.prompt, &prompt_buffer) catch |err| return switch (err) {
                    error.PromptIncomplete => .prompt_incomplete,
                    error.PromptConflict, error.InvalidPrompt => .prompt_invalid,
                    else => .admission_limit,
                };
                const result = try self.reduceWithPrompt(allocator, .{ .command_id = e.command_id, .target = e.target, .expected_revision = e.expected_revision, .payload = .{ .thread_send = .{ .text = prompt, .selection = p.selection, .attachments = p.attachments } } }, r, p.prompt);
                return result;
            },
            .attachment_add => |attachment| {
                if (e.target != .thread or e.expected_revision != .revision) return .invalid_command;
                attachments.validate(attachment, true) catch |err| return switch (err) {
                    error.UnsupportedAttachment => .attachment_unsupported,
                    error.AttachmentLimit => .attachment_limit,
                    error.DigestMismatch => .attachment_limit,
                    else => .invalid_command,
                };
                if (!attachments.digestMatches(attachment)) return .attachment_limit;
                if (attachment.metadata.byte_length > self.limits.attachment_bytes or attachments.metadataBytes(attachment.metadata) > self.limits.attachment_metadata_bytes or self.limits.attachment_count == 0) return .attachment_limit;
                const thread = e.target.thread.value;
                if (try self.field(allocator, "SELECT id FROM threads WHERE id=?", &.{.{ .text = thread }}) == null) return .not_found;
                const limits = try db.prepare("SELECT count(*),coalesce(sum(byte_length),0),coalesce(sum(length(CAST(name AS BLOB))+length(CAST(media_type AS BLOB))+length(CAST(digest AS BLOB))+length(CAST(id AS BLOB))),0) FROM attachments WHERE thread_id=? AND NOT EXISTS(SELECT 1 FROM attachment_refs r WHERE r.attachment_id=attachments.id)", &.{.{ .text = thread }});
                defer limits.deinit();
                if (!try limits.step()) return error.Corrupt;
                if (limits.integer(0) >= @as(i64, @intCast(self.limits.attachment_count)) or limits.integer(1) > @as(i64, @intCast(self.limits.attachment_bytes)) -| @as(i64, @intCast(attachment.metadata.byte_length)) or limits.integer(2) > @as(i64, @intCast(self.limits.attachment_metadata_bytes)) -| @as(i64, @intCast(attachments.metadataBytes(attachment.metadata)))) return .attachment_limit;
                if (try self.field(allocator, "SELECT id FROM attachments WHERE id=?", &.{.{ .text = attachment.metadata.id.value }}) != null) return .attachment_limit;
                try db.execute("INSERT INTO attachments(id,revision,thread_id,name,media_type,byte_length,digest,kind,content) VALUES(?,1,?,?,?,?,?,?,?)", &.{ .{ .text = attachment.metadata.id.value }, .{ .text = thread }, .{ .text = attachment.metadata.name }, .{ .text = attachment.metadata.media_type }, .{ .integer = @intCast(attachment.metadata.byte_length) }, .{ .text = attachment.metadata.digest }, .{ .text = @tagName(attachment.metadata.kind) }, .{ .blob = attachment.content } });
                try db.execute("UPDATE threads SET revision=revision+1 WHERE id=?", &.{.{ .text = thread }});
                r.entity_ids = .{ .thread = e.target.thread, .attachment = attachment.metadata.id };
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
                event_payload = try encoded(allocator, attachment.metadata);
            },
            .attachment_remove => |attachment_id| {
                if (e.target != .thread or e.expected_revision != .revision) return .invalid_command;
                const thread = e.target.thread.value;
                const found = try self.database.prepare("SELECT revision FROM attachments WHERE id=? AND thread_id=?", &.{ .{ .text = attachment_id.value }, .{ .text = thread } });
                defer found.deinit();
                if (!try found.step()) return .not_found;
                if (try self.scalar("SELECT count(*) FROM attachment_refs WHERE attachment_id=?", &.{.{ .text = attachment_id.value }}) != 0 or try self.followupReferencesAttachment(allocator, attachment_id.value)) return .busy;
                try db.execute("DELETE FROM attachments WHERE id=? AND thread_id=?", &.{ .{ .text = attachment_id.value }, .{ .text = thread } });
                try db.execute("UPDATE threads SET revision=revision+1 WHERE id=?", &.{.{ .text = thread }});
                r.entity_ids = .{ .thread = e.target.thread, .attachment = attachment_id };
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
            },
            .thread_send => |p| {
                if (e.target != .thread or e.expected_revision != .revision or p.text.len == 0 or !std.unicode.utf8ValidateSlice(p.text)) return .invalid_command;
                if (p.text.len > max_prompt_bytes) return .admission_limit;
                if (p.attachments.len > @min(self.limits.attachment_count, attachments.max_count)) return .attachment_limit;
                for (p.attachments, 0..) |id_value, index| {
                    if (id_value.value.len == 0 or id_value.value.len > attachments.max_id_bytes) return .attachment_limit;
                    for (p.attachments[0..index]) |previous| if (a.equal(id_value, previous)) return .attachment_limit;
                }
                if (p.attachments.len != 0 and !std.mem.eql(u8, p.selection.runtime_kind, "codex") and !std.mem.eql(u8, p.selection.runtime_kind, "opencode")) return .attachment_unsupported;
                const thread = e.target.thread.value;
                const workspace = try self.field(allocator, "SELECT workspace_id FROM threads WHERE id=?", &.{.{ .text = thread }}) orelse return .not_found;
                if (!std.mem.eql(u8, workspace, p.selection.workspace.value)) return .workspace_mismatch;
                if (self.factory != null or self.workspace_root != null) {
                    const binding_bytes = try self.field(allocator, "SELECT binding FROM workspaces WHERE id=?", &.{.{ .text = workspace }}) orelse return .workspace_mismatch;
                    const binding = try t.decode(t.WorkspaceBinding, binding_bytes, allocator);
                    if (!(workspace_binding.verifyCheckout(allocator, self.io, binding) catch false)) return .workspace_mismatch;
                    if (self.workspace_root) |root| if (!std.mem.eql(u8, binding.canonical_root, root)) return .workspace_mismatch;
                }
                if (p.selection.account_ref.len == 0 or p.selection.model_id.len == 0 or p.selection.model_provider.len == 0) return .capability_unavailable;
                if (self.factory) |runtime| {
                    const discovery = runtime.discover(p.selection);
                    if (p.attachments.len != 0 and discovery.capabilities[@intFromEnum(a.Capability.attachment)].status != .supported) return .attachment_unsupported;
                    const account = runtime.accountStatus(p.selection);
                    const resolved = runtime.resolveSelection(p.selection);
                    if (!std.mem.eql(u8, discovery.runtime_kind, p.selection.runtime_kind) or
                        !std.mem.eql(u8, discovery.runtime_version, p.selection.required_runtime_version) or
                        discovery.capability_revision != p.selection.capability_revision or
                        account.readiness == .unavailable or !std.mem.eql(u8, account.reference, p.selection.account_ref) or
                        resolved.readiness == .unavailable or !a.equal(resolved.requested, p.selection))
                        return .capability_unavailable;
                    for ([_]a.Capability{ .create, .start, .stream }) |capability|
                        if (discovery.capabilities[@intFromEnum(capability)].status != .supported) return .capability_unavailable;
                } else if (!std.mem.eql(u8, p.selection.runtime_kind, "fake") or !std.mem.eql(u8, p.selection.required_runtime_version, "1") or p.selection.capability_revision != 1) return .capability_unavailable;
                if (self.factory != null and (self.liveRuntimeCount() >= 3 or try db.scalar("SELECT count(*) FROM runs WHERE state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested')") >= 3)) return .admission_limit;
                if (try self.field(allocator, "SELECT id FROM runs WHERE thread_id=? AND (state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested','unknown','interrupted') OR EXISTS(SELECT 1 FROM effects WHERE run_id=runs.id AND state IN('unknown','in_flight')))", &.{.{ .text = thread }}) != null) return .unresolved_effects;
                const run = try self.id(allocator);
                var session = try self.id(allocator);
                var resumed: ?a.Session = null;
                const previous = try db.prepare("SELECT s.id,s.instance_id,s.upstream_session,s.selection FROM threads t JOIN sessions s ON s.id=t.session_id WHERE t.id=?", &.{.{ .text = thread }});
                defer previous.deinit();
                if (try previous.step()) {
                    const previous_selection = try t.decode(a.Selection, try previous.bytes(3), allocator);
                    if (!a.equal(previous_selection, p.selection)) return .selection_mismatch;
                    if (previous.isNull(1) or previous.isNull(2)) return .session_unavailable;
                    const instance = try previous.bytes(1);
                    const upstream = try previous.bytes(2);
                    if (instance.len == 0 or upstream.len == 0) return .session_unavailable;
                    session = try allocator.dupe(u8, try previous.bytes(0));
                    resumed = .{ .id = .{ .value = session }, .instance = .{ .value = try allocator.dupe(u8, instance) }, .upstream = .{ .value = try allocator.dupe(u8, upstream) } };
                    if (self.factory) |runtime| {
                        if (runtime.discover(p.selection).capabilities[@intFromEnum(a.Capability.attach)].status != .supported) return .capability_unavailable;
                    }
                }
                const user = try self.id(allocator);
                const assistant = try self.id(allocator);
                const user_block = try self.id(allocator);
                const assistant_block = try self.id(allocator);
                const open = try self.id(allocator);
                const start = try self.id(allocator);
                // Reference the canonical user block. This is the only durable copy;
                // command/effect journals never JSON-escape the large text.
                var prompt_ref = staged_ref orelse prompts.reference(user_block, p.text);
                prompt_ref.id = user_block;
                var attached = try allocator.alloc(a.Attachment, p.attachments.len);
                for (p.attachments, 0..) |attachment_id, index| {
                    const found = try db.prepare("SELECT name,media_type,byte_length,digest,kind FROM attachments WHERE id=? AND thread_id=?", &.{ .{ .text = attachment_id.value }, .{ .text = thread } });
                    defer found.deinit();
                    if (!try found.step()) return .not_found;
                    attached[index] = .{ .metadata = .{ .id = .{ .value = try allocator.dupe(u8, attachment_id.value) }, .name = try allocator.dupe(u8, try found.bytes(0)), .media_type = try allocator.dupe(u8, try found.bytes(1)), .byte_length = @intCast(found.integer(2)), .digest = try allocator.dupe(u8, try found.bytes(3)), .kind = std.meta.stringToEnum(a.AttachmentKind, try found.bytes(4)) orelse return error.Corrupt } };
                    const provider: attachments.Provider = if (std.mem.eql(u8, p.selection.runtime_kind, "codex")) .codex else .opencode;
                    if (!attachments.supported(attached[index].metadata.media_type, attached[index].metadata.kind, provider)) return .attachment_unsupported;
                }
                a.validateNativeAttachments(attached, .{ .attachment_count = self.limits.attachment_count, .attachment_bytes = self.limits.attachment_bytes, .attachment_metadata_bytes = self.limits.attachment_metadata_bytes }) catch return .attachment_limit;
                const request: a.Request = .{ .start = .{ .correlation = .{ .effect = .{ .value = start }, .run = .{ .value = run }, .session = .{ .value = session } }, .prompt_ref = prompt_ref, .attachments = attached } };
                var materialized_bytes = a.frameBytes(request) +| p.text.len;
                for (attached) |attachment| materialized_bytes +|= @intCast(attachment.metadata.byte_length);
                if (materialized_bytes > @min(attachment_packet_limit, start_frame_limit +| self.limits.attachment_packet_bytes)) return .admission_limit;
                const selection = try encoded(allocator, p.selection);
                try db.execute("INSERT INTO thread_selections VALUES(?,?) ON CONFLICT(thread_id) DO UPDATE SET selection=excluded.selection", &.{ .{ .text = thread }, .{ .blob = selection } });
                if (resumed == null) try db.execute("INSERT INTO sessions(id,revision,workspace_id,selection) VALUES(?,1,?,?)", &.{ .{ .text = session }, .{ .text = workspace }, .{ .blob = selection } });
                try db.execute("INSERT INTO runs(id,revision,thread_id,session_id,state,requested) VALUES(?,1,?,?,'queued',?)", &.{ .{ .text = run }, .{ .text = thread }, .{ .text = session }, .{ .blob = selection } });
                const ordinal = try db.prepare("SELECT next_ordinal FROM threads WHERE id=?", &.{.{ .text = thread }});
                defer ordinal.deinit();
                if (!try ordinal.step()) return error.Corrupt;
                const next = ordinal.integer(0);
                if (next > std.math.maxInt(i64) - 2) return .admission_limit;
                try db.execute("INSERT INTO messages VALUES(?,1,?,?,?,'user',0),(?,1,?,?,?,'assistant',1)", &.{ .{ .text = user }, .{ .text = thread }, .{ .text = run }, .{ .integer = next }, .{ .text = assistant }, .{ .text = thread }, .{ .text = run }, .{ .integer = next + 1 } });
                try db.execute("INSERT INTO blocks(id,revision,message_id,ordinal,kind) VALUES(?,1,?,0,'text'),(?,1,?,0,'text')", &.{ .{ .text = user_block }, .{ .text = user }, .{ .text = assistant_block }, .{ .text = assistant } });
                var offset: usize = 0;
                while (offset < p.text.len) {
                    const end = @min(offset + 2048, p.text.len);
                    _ = try db.appendChunk(user_block, offset, p.text[offset..end]);
                    offset = end;
                }
                for (p.attachments, 0..) |attachment_id, index| try db.execute("INSERT INTO attachment_refs(message_id,attachment_id,ordinal) VALUES(?,?,?)", &.{ .{ .text = user }, .{ .text = attachment_id.value }, .{ .integer = @intCast(index) } });
                try db.execute("UPDATE threads SET revision=revision+1,session_id=?,next_ordinal=next_ordinal+2,last_user_message_at_ms=coalesce(?,last_user_message_at_ms),updated_at_ms=coalesce(?,updated_at_ms) WHERE id=?", &.{ .{ .text = session }, self.timeValue(), self.timeValue(), .{ .text = thread } });
                if (resumed) |existing| {
                    try self.plan(allocator, open, run, session, .attach, .{ .open = .{ .existing = .{ .session = existing } } }, null, null, e.command_id);
                    try self.plan(allocator, start, run, session, .start, request, open, null, e.command_id);
                } else {
                    try self.plan(allocator, open, run, session, .create_session, .{ .open = .{ .create = .{ .effect = .{ .value = open }, .session = .{ .value = session }, .selection = p.selection } } }, null, null, e.command_id);
                    try self.plan(allocator, start, run, session, .start, request, open, null, e.command_id);
                }
                r.entity_ids = .{ .thread = e.target.thread, .run = .{ .value = run }, .session = .{ .value = session }, .user_message = .{ .value = user }, .assistant_message = .{ .value = assistant }, .assistant_block = .{ .value = assistant_block } };
                const effects = try allocator.alloc(a.EffectId, 2);
                effects[0] = .{ .value = open };
                effects[1] = .{ .value = start };
                r.effect_ids = effects;
                aggregate = .{ .thread = e.target.thread };
                revision_value = e.expected_revision.revision + 1;
                try self.event(allocator, seq, 0, .{ .run = .{ .value = run } }, 1, "RunQueued", e.command_id, null, "");
            },
            .run_cancel => |p| {
                if (e.target != .run or e.expected_revision != .revision) return .invalid_command;
                const run = e.target.run.value;
                try self.guardRunRevisions(run);
                const state = try self.field(allocator, "SELECT state FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return .not_found;
                if (!(std.mem.eql(u8, state, "queued") or std.mem.eql(u8, state, "starting") or std.mem.eql(u8, state, "streaming") or std.mem.eql(u8, state, "awaiting_approval") or std.mem.eql(u8, state, "unknown") or std.mem.eql(u8, state, "interrupted"))) return .invalid_command;
                const children = try db.prepare("SELECT t.run_id,r.revision FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.parent_run=? AND t.detached=0 AND r.state IN('queued','starting','streaming','awaiting_approval','unknown','interrupted')", &.{.{ .text = run }});
                defer children.deinit();
                while (try children.step()) {
                    var child_receipt: t.Receipt = .{ .command_id = e.command_id, .outcome = .accepted, .commit_sequence = seq };
                    const child = try allocator.dupe(u8, try children.bytes(0));
                    const reason = try self.reduce(allocator, .{ .command_id = e.command_id, .target = .{ .run = .{ .value = child } }, .expected_revision = .{ .revision = @intCast(children.integer(1)) }, .payload = .{ .run_cancel = p } }, &child_receipt);
                    if (reason != null) return reason;
                    try self.finalizeMessages(child);
                }
                const session = try self.field(allocator, "SELECT session_id FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return error.Corrupt;
                const dispatched = try self.field(allocator, "SELECT id FROM effects WHERE run_id=? AND read_only=0 AND state IN('in_flight','confirmed','unknown') LIMIT 1", &.{.{ .text = run }});
                try db.execute("UPDATE effects SET state='withdrawn',revision=revision+1 WHERE run_id=? AND state='planned' AND read_only=0", &.{.{ .text = run }});
                try db.execute("UPDATE approvals SET state='invalidated',live_epoch=NULL,revision=revision+1 WHERE run_id=? AND state='pending'", &.{.{ .text = run }});
                if (dispatched == null) {
                    try db.execute("UPDATE runs SET state='cancelled',cancel_cause=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = p.reason }, .{ .text = run } });
                } else {
                    const effect_id = try self.id(allocator);
                    const request: a.Request = .{ .cancel = .{ .correlation = .{ .effect = .{ .value = effect_id }, .run = e.target.run, .session = .{ .value = session } }, .reason = p.reason } };
                    if (a.frameBytes(request) > 4096) return .admission_limit;
                    if (try self.field(allocator, "SELECT id FROM effects WHERE run_id=? AND kind='cancel'", &.{.{ .text = run }}) != null) return .busy;
                    try self.plan(allocator, effect_id, run, session, .cancel, request, null, null, e.command_id);
                    const effects = try allocator.alloc(a.EffectId, 1);
                    effects[0] = .{ .value = effect_id };
                    r.effect_ids = effects;
                    try db.execute("UPDATE runs SET state='cancel_requested',cancel_cause=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = p.reason }, .{ .text = run } });
                }
                aggregate = .{ .run = e.target.run };
                revision_value = e.expected_revision.revision + 1;
            },
            .approval_respond => |p| {
                if (e.target != .approval or e.expected_revision != .revision) return .invalid_command;
                const statement = try db.prepare("SELECT a.run_id,a.session_id,a.tool_id,a.workspace_id,a.upstream_request,a.action_digest,a.scope,a.expires_at,a.state,a.live_epoch,r.state FROM approvals a JOIN runs r ON r.id=a.run_id WHERE a.id=?", &.{.{ .text = e.target.approval.value }});
                defer statement.deinit();
                if (!try statement.step()) return .not_found;
                if (!std.mem.eql(u8, try statement.bytes(8), "pending") or !std.mem.eql(u8, try statement.bytes(10), "awaiting_approval") or statement.isNull(9) or !std.mem.eql(u8, try statement.bytes(9), self.epoch)) return .approval_invalid;
                if (!std.mem.eql(u8, try statement.bytes(5), p.action_digest)) return .approval_invalid;
                if (!statement.isNull(7) and (self.utc_ms == null or self.utc_ms.? >= @as(u64, @intCast(statement.integer(7))))) return .approval_expired;
                const run = try allocator.dupe(u8, try statement.bytes(0));
                const session = try allocator.dupe(u8, try statement.bytes(1));
                const effect_id = try self.id(allocator);
                const request: a.Request = .{ .respond_approval = .{ .correlation = .{ .effect = .{ .value = effect_id }, .session = .{ .value = session }, .run = .{ .value = run }, .approval = e.target.approval, .tool = .{ .value = try allocator.dupe(u8, try statement.bytes(2)) }, .upstream_request = try allocator.dupe(u8, try statement.bytes(4)) }, .decision = if (p.decision == .allow) .allow else .deny, .action_digest = p.action_digest } };
                if (a.frameBytes(request) > 4096) return .admission_limit;
                try self.plan(allocator, effect_id, run, session, .approval_reply, request, null, e.target.approval.value, e.command_id);
                try db.execute("UPDATE approvals SET state='resolved',decision=?,reply_effect=?,revision=revision+1 WHERE id=?", &.{ .{ .text = @tagName(p.decision) }, .{ .text = effect_id }, .{ .text = e.target.approval.value } });
                const effects = try allocator.alloc(a.EffectId, 1);
                effects[0] = .{ .value = effect_id };
                r.effect_ids = effects;
                aggregate = .{ .approval = e.target.approval };
                revision_value = e.expected_revision.revision + 1;
            },
            .run_reconcile => |p| {
                if (e.target != .run or e.expected_revision != .revision or p.effects.len == 0) return .invalid_command;
                const session = try self.field(allocator, "SELECT session_id FROM runs WHERE id=?", &.{.{ .text = e.target.run.value }}) orelse return .not_found;
                if (!std.mem.eql(u8, session, p.session.value)) return .invalid_command;
                try self.guardRunRevisions(e.target.run.value);
                for (p.effects, 0..) |effect_id, i| {
                    for (p.effects[0..i]) |previous| if (std.mem.eql(u8, previous.value, effect_id.value)) return .invalid_command;
                    const found = try self.field(allocator, "SELECT state FROM effects WHERE id=? AND run_id=? AND session_id=?", &.{ .{ .text = effect_id.value }, .{ .text = e.target.run.value }, .{ .text = session } }) orelse return .not_found;
                    if (!std.mem.eql(u8, found, "unknown")) return .invalid_command;
                }
                // Explicit operator evidence can clear ownership, never replay an
                // old request. Without proof preserve unknown, not optimistic retry.
                const resolution = p.resolution orelse return .authority_unavailable;
                if (!resolution.no_execution or resolution.actor.len == 0 or resolution.evidence.len == 0) return .authority_unavailable;
                for (p.effects) |effect_id| try db.execute("UPDATE effects SET state='failed',outcome='operator_proved_no_execution',evidence=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = try encoded(allocator, resolution) }, .{ .text = effect_id.value } });
                if (try self.field(allocator, "SELECT id FROM effects WHERE run_id=? AND state IN('unknown','in_flight')", &.{.{ .text = e.target.run.value }}) != null) return .unresolved_effects;
                try db.execute("UPDATE effects SET state='withdrawn',revision=revision+1 WHERE run_id=? AND state='planned'", &.{.{ .text = e.target.run.value }});
                try db.execute("UPDATE runs SET state='failed',revision=revision+1 WHERE id=?", &.{.{ .text = e.target.run.value }});
                aggregate = .{ .run = e.target.run };
                revision_value = e.expected_revision.revision + 1;
            },
            .task_delegate, .task_send, .task_cancel, .task_result, .task_review => return self.taskCommand(allocator, e, r),
        }
        const event_kind = switch (e.payload) {
            .thread_archive => "ThreadArchived",
            .thread_restore => "ThreadRestored",
            .thread_delete => "ThreadDeleted",
            .thread_title_set => "ThreadTitleChanged",
            .thread_sidebar_set => "ThreadSidebarChanged",
            .followup_enqueue => "FollowupQueued",
            .followup_edit => "FollowupEdited",
            .followup_cancel => "FollowupCancelled",
            .followup_order => "FollowupReordered",
            .question_answer => "QuestionAnswered",
            .attachment_add => "AttachmentAccepted",
            .attachment_remove => "AttachmentRejected",
            else => @tagName(e.payload),
        };
        try self.event(allocator, seq, if (e.payload == .thread_send or e.payload == .thread_send_staged) 1 else 0, aggregate, revision_value, event_kind, e.command_id, null, event_payload);
        return null;
    }
    fn taskCommand(self: *Owner, allocator: std.mem.Allocator, e: t.CommandEnvelope, r: *t.Receipt) anyerror!?t.Reason {
        if (e.target != .run or e.expected_revision != .revision) return .invalid_command;
        const run = e.target.run.value;
        const db = self.database;
        switch (e.payload) {
            .task_delegate => |packet| {
                if (!packet.budget.valid() or packet.purpose.len == 0 or packet.prompt.len == 0 or packet.acceptance.len == 0 or packet.result_location.len == 0 or packet.owned_paths.len == 0 or packet.owned_paths.len > 32) return .invalid_command;
                if (self.utc_ms == null) return .authority_unavailable;
                if (try self.field(allocator, "SELECT run_id FROM tasks WHERE run_id=?", &.{.{ .text = run }}) != null) return .admission_limit;
                const parent = try db.prepare("SELECT t.project_id,r.state FROM runs r JOIN threads t ON t.id=r.thread_id WHERE r.id=?", &.{.{ .text = run }});
                defer parent.deinit();
                if (!try parent.step()) return .not_found;
                const state = try parent.bytes(1);
                if (!(std.mem.eql(u8, state, "streaming") or std.mem.eql(u8, state, "awaiting_approval"))) return .invalid_command;
                const count = try db.prepare("SELECT count(*),coalesce(sum(CASE WHEN r.state NOT IN('completed','cancelled','failed') THEN 1 ELSE 0 END),0) FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.parent_run=?", &.{.{ .text = run }});
                defer count.deinit();
                if (!try count.step() or count.integer(0) >= 16 or count.integer(1) >= 2) return .admission_limit;
                const project = try allocator.dupe(u8, try parent.bytes(0));
                const workspace_project = try self.field(allocator, "SELECT project_id FROM workspaces WHERE id=?", &.{.{ .text = packet.selection.workspace.value }}) orelse return .workspace_mismatch;
                if (!std.mem.eql(u8, project, workspace_project)) return .workspace_mismatch;
                const binding_bytes = try self.field(allocator, "SELECT binding FROM workspaces WHERE id=?", &.{.{ .text = packet.selection.workspace.value }}) orelse return .workspace_mismatch;
                const binding = try t.decode(t.WorkspaceBinding, binding_bytes, allocator);
                for (packet.owned_paths) |path| {
                    if (!try workspace_binding.validOwnedPath(allocator, binding, path)) return .invalid_command;
                }
                // Workspace IDs and different coordinators are not isolation:
                // compare real checkout paths and shared Git metadata ownership.
                const siblings = try db.prepare("SELECT t.packet,w.binding FROM tasks t JOIN runs r ON r.id=t.run_id JOIN sessions s ON s.id=r.session_id JOIN workspaces w ON w.id=s.workspace_id WHERE r.state NOT IN('completed','cancelled','failed')", &.{});
                defer siblings.deinit();
                while (try siblings.step()) {
                    const other = try t.decode(t.orchestration.Packet, try siblings.bytes(0), allocator);
                    const other_binding = try t.decode(t.WorkspaceBinding, try siblings.bytes(1), allocator);
                    for (other.owned_paths) |left| for (packet.owned_paths) |right| {
                        if (try workspace_binding.ownershipOverlaps(allocator, other_binding, left, binding, right)) return .workspace_mismatch;
                    };
                }
                const thread = try self.id(allocator);
                const root_key = canonicalRootKey(binding.canonical_root);
                const creation = try db.scalar("SELECT coalesce(max(rowid),0) FROM threads");
                const ordinal = std.math.add(i64, creation, 1) catch return .admission_limit;
                const order = std.math.mul(i64, ordinal, -1024) catch return .admission_limit;
                try db.execute("INSERT INTO threads(id,revision,project_id,workspace_id,root_key,sort_order,created_at_ms,updated_at_ms) VALUES(?,1,?,?,?, ?,coalesce(?,0),coalesce(?,0))", &.{ .{ .text = thread }, .{ .text = project }, .{ .text = packet.selection.workspace.value }, .{ .blob = &root_key }, .{ .integer = order }, self.timeValue(), self.timeValue() });
                var child_owner = self.*;
                child_owner.workspace_root = null;
                const reason = try child_owner.reduce(allocator, .{ .command_id = e.command_id, .target = .{ .thread = .{ .value = thread } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = packet.prompt, .selection = packet.selection } } }, r);
                if (reason != null) return reason;
                try db.execute("INSERT INTO tasks(run_id,parent_run,packet,detached,created_at) VALUES(?,?,?,?,?)", &.{ .{ .text = r.entity_ids.run.?.value }, .{ .text = run }, .{ .blob = try encoded(allocator, packet) }, .{ .integer = @intFromBool(packet.detached) }, .{ .integer = @intCast(self.utc_ms.?) } });
            },
            .task_send => |message| {
                if (message.content.len == 0) return .invalid_command;
                const task = try db.prepare("SELECT t.packet,t.requests,r.session_id,r.state FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.run_id=?", &.{.{ .text = run }});
                defer task.deinit();
                if (!try task.step()) return .not_found;
                const packet = try t.decode(t.orchestration.Packet, try task.bytes(0), allocator);
                if (task.integer(1) >= packet.budget.max_requests) return .admission_limit;
                if (!std.mem.eql(u8, try task.bytes(3), "streaming")) return .invalid_command;
                if (self.factory) |runtime| {
                    if (runtime.discover(packet.selection).capabilities[@intFromEnum(a.Capability.message)].status != .supported) return .capability_unavailable;
                } else return .capability_unavailable;
                const effect_id = try self.id(allocator);
                const request: a.Request = .{ .message = .{ .correlation = .{ .effect = .{ .value = effect_id }, .run = e.target.run, .session = .{ .value = try allocator.dupe(u8, try task.bytes(2)) } }, .message = .{ .value = try self.id(allocator) }, .content = message.content } };
                if (a.frameBytes(request) > 4096) return .admission_limit;
                try self.plan(allocator, effect_id, run, request.message.correlation.session.value, .message, request, null, null, e.command_id);
                try db.execute("UPDATE tasks SET requests=requests+1 WHERE run_id=?", &.{.{ .text = run }});
            },
            .task_cancel => |cancel| {
                if (try self.field(allocator, "SELECT run_id FROM tasks WHERE run_id=?", &.{.{ .text = run }}) == null) return .not_found;
                var nested = e;
                nested.payload = .{ .run_cancel = .{ .reason = cancel.reason } };
                return self.reduce(allocator, nested, r);
            },
            .task_result => |result| {
                if (result.candidate.len == 0 or result.evidence.len == 0 or result.summary.len == 0) return .invalid_command;
                if (try self.field(allocator, "SELECT t.run_id FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.run_id=? AND r.state IN('completed','failed','cancelled') AND t.result IS NULL", &.{.{ .text = run }}) == null) return .invalid_command;
                try db.execute("UPDATE tasks SET result=? WHERE run_id=?", &.{ .{ .blob = try encoded(allocator, result) }, .{ .text = run } });
            },
            .task_review => |review| {
                const bytes = try self.field(allocator, "SELECT result FROM tasks WHERE run_id=?", &.{.{ .text = run }}) orelse return .invalid_command;
                const result = try t.decode(t.orchestration.Result, bytes, allocator);
                if (!std.mem.eql(u8, result.candidate, review.candidate) or !std.mem.eql(u8, result.evidence, review.evidence)) return .invalid_command;
                try db.execute("UPDATE tasks SET review=? WHERE run_id=?", &.{ .{ .text = @tagName(review.disposition) }, .{ .text = run } });
            },
            else => unreachable,
        }
        try db.execute("UPDATE runs SET revision=revision+1 WHERE id=?", &.{.{ .text = run }});
        try self.event(allocator, r.commit_sequence, 0, .{ .run = e.target.run }, e.expected_revision.revision + 1, @tagName(e.payload), e.command_id, null, "");
        return null;
    }

    pub const Claimed = struct { id: a.EffectId, request: a.Request };
    /// Claim commits before returning an immutable request to a dispatcher.
    pub fn claimNext(self: *Owner, allocator: std.mem.Allocator) !?Claimed {
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        // Old journals classified continuation opens as read-only attaches.
        // Their dependent start makes them ordinary Send work: recovery must
        // not claim the attach and revive that interrupted/unknown turn. Repeat
        // one_effect's partial-index predicate for a bounded compatibility lookup.
        const statement = try self.database.prepare("SELECT e.id,e.request FROM effects e JOIN runs r ON r.id=e.run_id WHERE e.state='planned' AND ((e.read_only=1 AND NOT EXISTS(SELECT 1 FROM effects continuation WHERE continuation.run_id=e.run_id AND continuation.kind IN('create_session','start','cancel') AND continuation.kind='start' AND continuation.depends_on=e.id)) OR r.state IN('queued','starting','streaming','awaiting_approval','awaiting_question') OR (e.kind='cancel' AND r.state='cancel_requested')) AND (e.depends_on IS NULL OR EXISTS(SELECT 1 FROM effects d WHERE d.id=e.depends_on AND d.state='confirmed')) ORDER BY e.rowid LIMIT 1", &.{});
        const result: ?Claimed = blk: {
            defer statement.deinit();
            if (!try statement.step()) break :blk null;
            break :blk .{ .id = a.EffectId{ .value = try allocator.dupe(u8, try statement.bytes(0)) }, .request = try t.decode(a.Request, try statement.bytes(1), allocator) };
        };
        if (result) |effect| {
            if (!try self.database.claim(effect.id.value, self.epoch)) return error.Conflict;
            const sequence = try self.database.nextSequence();
            try self.database.publishChanges(sequence, null);
        }
        try self.database.commit();
        return result;
    }
    /// Persist adapter delivery evidence without interpreting acknowledgement as
    /// run completion. An ambiguous call is never changed back to planned.
    pub fn delivered(self: *Owner, allocator: std.mem.Allocator, effect: a.EffectId, receipt: a.Receipt) !void {
        const db = self.database;
        try db.begin();
        errdefer db.rollback() catch {};
        const s = try db.prepare("SELECT run_id,session_id,kind,revision,state,evidence FROM effects WHERE id=?", &.{.{ .text = effect.value }});
        defer s.deinit();
        if (!try s.step()) return error.Conflict;
        const evidence = try encoded(allocator, receipt);
        // Keep event/retry evidence fixed in size even for detailed receipts.
        // The complete current evidence remains on the effect itself.
        const delivery_proof = try encoded(allocator, .{ .outcome = receipt.outcome, .digest = t.digest(evidence) });
        if (!s.isNull(5) and std.mem.eql(u8, try s.bytes(5), evidence)) {
            try db.rollback();
            return;
        }
        if (!std.mem.eql(u8, try s.bytes(4), "in_flight")) {
            // A later request outcome may replace effects.evidence. Retain the
            // original receipt identity in its indexed effect event so a retry
            // remains idempotent after refusal or restart, without replay.
            const aggregate = try encoded(allocator, t.AggregateRef{ .effect = effect });
            const original = try self.field(allocator, "SELECT payload FROM events WHERE aggregate=? AND kind='EffectDelivery' ORDER BY sequence DESC,event_index DESC LIMIT 1", &.{.{ .blob = aggregate }}) orelse return error.Conflict;
            if (!std.mem.eql(u8, original, delivery_proof)) return error.Conflict;
            try db.rollback();
            return;
        }
        if (s.integer(3) == std.math.maxInt(i64)) return error.Limit;
        const run = try allocator.dupe(u8, try s.bytes(0));
        const session = try allocator.dupe(u8, try s.bytes(1));
        const kind = try allocator.dupe(u8, try s.bytes(2));
        try self.guardRunRevisions(run);
        const sequence = try db.nextSequence();
        const opening_session = std.mem.eql(u8, kind, "create_session") or std.mem.eql(u8, kind, "attach");
        const missing_session = opening_session and receipt.outcome == .acknowledged and receipt.session == null;
        // An accepted resume RPC is not evidence that the old context exists.
        // Hold its dependent start until the adapter publishes that session.
        const pending_session = missing_session and self.factory != null;
        const state = if (pending_session) "in_flight" else if (missing_session) "unknown" else switch (receipt.outcome) {
            .acknowledged => "confirmed",
            .rejected => "failed",
            .unknown => "unknown",
        };
        try db.execute("UPDATE effects SET state=?,outcome=?,evidence=?,revision=revision+1 WHERE id=?", &.{ .{ .text = state }, .{ .blob = receipt.detail }, .{ .blob = evidence }, .{ .text = effect.value } });
        if (std.mem.eql(u8, kind, "message") and receipt.outcome == .rejected) {
            const request_bytes = try self.field(allocator, "SELECT request FROM effects WHERE id=?", &.{.{ .text = effect.value }}) orelse return error.Corrupt;
            const request = try t.decode(a.Request, request_bytes, allocator);
            if (request == .answer_question) {
                try db.execute("UPDATE questions SET state='pending',answer=NULL,reply_effect=NULL,revision=revision+1 WHERE id=? AND state='resolved' AND reply_effect=?", &.{ .{ .text = request.answer_question.question.value }, .{ .text = effect.value } });
                try db.execute("UPDATE runs SET state='awaiting_question',revision=revision+1 WHERE id=? AND state='streaming'", &.{.{ .text = run }});
            }
        }
        try self.event(allocator, sequence, 0, .{ .effect = effect }, @intCast(s.integer(3) + 1), "EffectDelivery", null, effect, delivery_proof);
        if (receipt.session) |live| {
            if (!std.mem.eql(u8, live.id.value, session)) return error.Conflict;
            const revision_statement = try db.prepare("SELECT revision,upstream_session FROM sessions WHERE id=?", &.{.{ .text = session }});
            defer revision_statement.deinit();
            if (!try revision_statement.step() or revision_statement.integer(0) == std.math.maxInt(i64)) return error.Limit;
            if (!revision_statement.isNull(1) and !std.mem.eql(u8, try revision_statement.bytes(1), live.upstream.value)) return error.Conflict;
            try db.execute("UPDATE sessions SET instance_id=?,upstream_session=?,continuity=?,revision=revision+1 WHERE id=?", &.{ .{ .text = live.instance.value }, .{ .text = live.upstream.value }, .{ .text = @tagName(receipt.continuity) }, .{ .text = session } });
            try self.event(allocator, sequence, 1, .{ .session = .{ .value = session } }, @intCast(revision_statement.integer(0) + 1), "SessionEvidence", null, effect, "");
        }
        const next_state: []const u8 = if (pending_session) "starting" else if (missing_session or receipt.outcome == .unknown) "unknown" else if (receipt.outcome == .rejected) "failed" else if (std.mem.eql(u8, kind, "create_session") or std.mem.eql(u8, kind, "attach")) "starting" else if (std.mem.eql(u8, kind, "cancel")) "cancel_requested" else "streaming";
        const revision_statement = try db.prepare("SELECT revision,state FROM runs WHERE id=?", &.{.{ .text = run }});
        defer revision_statement.deinit();
        if (!try revision_statement.step()) return error.Corrupt;
        const current = try revision_statement.bytes(1);
        // Delivery after terminal evidence never revives the lifecycle.
        // Message delivery resolves only that effect. It neither starts a new
        // turn nor supplies evidence about the independent Start's lifecycle,
        // tools or cancellation, including when delivery itself is uncertain.
        if (!std.mem.eql(u8, kind, "message") and !(std.mem.eql(u8, current, "completed") or std.mem.eql(u8, current, "cancelled") or std.mem.eql(u8, current, "failed") or std.mem.eql(u8, current, "unknown") or std.mem.eql(u8, current, "interrupted"))) {
            const applied_state = if (std.mem.eql(u8, current, "cancel_requested") and std.mem.eql(u8, kind, "create_session")) current else next_state;
            try db.execute("UPDATE runs SET state=?,revision=revision+1 WHERE id=?", &.{ .{ .text = applied_state }, .{ .text = run } });
            if (std.mem.eql(u8, applied_state, "failed")) try self.wakeSnoozed(allocator, sequence, effect, run);
            try self.event(allocator, sequence, 2, .{ .run = .{ .value = run } }, @intCast(revision_statement.integer(0) + 1), "RunDelivery", null, effect, "");
        }
        if (opening_session and receipt.outcome == .rejected)
            try db.execute("UPDATE effects SET state='withdrawn',revision=revision+1 WHERE run_id=? AND state='planned'", &.{.{ .text = run }});
        try self.finalizeMessages(run);
        try db.publishChanges(sequence, null);
        try db.commit();
    }

    /// A complete bounded observation is retained by the caller until this
    /// transaction succeeds. Duplicate identity requires byte-equal evidence.
    pub fn observe(self: *Owner, allocator: std.mem.Allocator, input: a.Observation) !void {
        if (a.frameBytes(input) > 4096 or input.upstream_event.len == 0) return error.Limit;
        // Never infer a request outcome's run from the newest turn in a
        // session. Both identities must come from the dispatched request.
        if (input.body == .request_failed and (input.correlation.run == null or input.correlation.effect == null)) return error.Conflict;
        var observation = input;
        const run = observation.correlation.run orelse if (self.factory != null) a.RunId{
            .value = try self.field(allocator, "SELECT id FROM runs WHERE session_id=? ORDER BY rowid DESC LIMIT 1", &.{.{ .text = observation.correlation.session.value }}) orelse return error.Conflict,
        } else return error.Conflict;
        const session = observation.correlation.session;
        const db = self.database;
        // Provider event labels may be reused for each turn of a durable
        // session. Scope the journal identity to the durable run while still
        // retaining the original upstream label in the correlation payload.
        const observation_key = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run.value, observation.upstream_event });
        const canonical = try encoded(allocator, input);
        const digest = t.digest(canonical);
        try db.begin();
        errdefer db.rollback() catch {};
        {
            const duplicate = try db.prepare("SELECT digest FROM observations WHERE session_id=? AND upstream_event=?", &.{ .{ .text = session.value }, .{ .text = observation_key } });
            defer duplicate.deinit();
            if (try duplicate.step()) {
                if (!std.mem.eql(u8, try duplicate.bytes(0), &digest)) return error.Conflict;
                try db.rollback();
                return;
            }
        }
        if (self.factory != null) {
            observation.correlation.run = run;
            // Resume adapters can publish only the session identity while the
            // open RPC is pending. Bind its success/failure to this run's live
            // open claim, never an earlier turn's confirmed attach.
            if (observation.correlation.effect == null and (observation.body == .session or observation.body == .failure)) {
                if (try self.field(allocator, "SELECT id FROM effects WHERE session_id=? AND run_id=? AND state='in_flight' AND kind IN('create_session','attach') ORDER BY rowid DESC LIMIT 1", &.{ .{ .text = session.value }, .{ .text = run.value } })) |pending|
                    observation.correlation.effect = .{ .value = pending };
            }
            if (observation.correlation.upstream_tool) |upstream| {
                observation.correlation.upstream_tool = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run.value, upstream });
                if (observation.correlation.tool) |tool| observation.correlation.tool = .{ .value = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run.value, tool.value }) };
            }
            if (observation.body == .approval) {
                if (!a.equal(input.body.approval.correlation, input.correlation)) return error.Conflict;
                observation.body.approval.correlation = observation.correlation;
            }
            if (observation.body == .chunk) {
                const chunk = &observation.body.chunk;
                const message = try self.field(allocator, "SELECT id FROM messages WHERE run_id=? AND role='assistant'", &.{.{ .text = run.value }}) orelse return error.Corrupt;
                const upstream_message = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run.value, chunk.message.value });
                const upstream_block = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run.value, chunk.block.value });
                const mapped = try self.field(allocator, "SELECT block_id FROM runtime_blocks WHERE session_id=? AND upstream_message=? AND upstream_block=?", &.{ .{ .text = session.value }, .{ .text = upstream_message }, .{ .text = upstream_block } });
                const block = mapped orelse blk: {
                    var key: ?[]const u8 = null;
                    if (observation.correlation.tool) |tool| {
                        key = try self.resultBlock(allocator, run.value, tool.value);
                    } else {
                        key = try self.field(allocator, "SELECT id FROM blocks WHERE message_id=? AND ordinal=0 AND kind='text' AND NOT EXISTS(SELECT 1 FROM runtime_blocks WHERE block_id=blocks.id)", &.{.{ .text = message }});
                        if (key == null) key = try self.newBlock(allocator, message, null);
                    }
                    try db.execute("INSERT INTO runtime_blocks VALUES(?,?,?,?)", &.{ .{ .text = session.value }, .{ .text = upstream_message }, .{ .text = upstream_block }, .{ .text = key.? } });
                    break :blk key.?;
                };
                chunk.message = .{ .value = message };
                chunk.block = .{ .value = block };
            }
        }
        if (observation.correlation.effect) |effect_id| {
            if (try self.field(allocator, "SELECT id FROM effects WHERE id=? AND session_id=? AND run_id=?", &.{ .{ .text = effect_id.value }, .{ .text = session.value }, .{ .text = run.value } }) == null) return error.Conflict;
        }
        const state_statement = try db.prepare("SELECT state,revision FROM runs WHERE id=? AND session_id=?", &.{ .{ .text = run.value }, .{ .text = session.value } });
        defer state_statement.deinit();
        if (!try state_statement.step()) return error.Conflict;
        try self.guardRunRevisions(run.value);
        const current_state = try allocator.dupe(u8, try state_statement.bytes(0));
        const terminal = std.mem.eql(u8, current_state, "completed") or std.mem.eql(u8, current_state, "cancelled") or std.mem.eql(u8, current_state, "failed") or std.mem.eql(u8, current_state, "unknown") or std.mem.eql(u8, current_state, "interrupted");
        var next_state: []const u8 = current_state;
        const sequence = try db.nextSequence();
        var index: u32 = 0;
        switch (observation.body) {
            .chunk => |chunk| {
                const block = try db.prepare("SELECT b.revision FROM blocks b JOIN messages m ON m.id=b.message_id WHERE b.id=? AND m.id=? AND m.run_id=? AND m.role='assistant'", &.{ .{ .text = chunk.block.value }, .{ .text = chunk.message.value }, .{ .text = run.value } });
                defer block.deinit();
                if (!try block.step()) return error.Conflict;
                if (try db.appendChunk(chunk.block.value, chunk.offset, chunk.text) == .appended) {
                    try self.event(allocator, sequence, index, .{ .block = chunk.block }, @intCast(block.integer(0) + 1), "ContentAppended", null, observation.correlation.effect, try encoded(allocator, .{ .start_byte = chunk.offset, .end_byte = chunk.offset + chunk.text.len }));
                    try self.touchMessage(chunk.message.value);
                    index += 1;
                }
                if (!terminal and !std.mem.eql(u8, current_state, "cancel_requested")) next_state = "streaming";
            },
            .tool_started => |tool| {
                const tool_id = observation.correlation.tool orelse return error.Conflict;
                const upstream = observation.correlation.upstream_tool orelse return error.Conflict;
                if (terminal) return error.Conflict;
                const existing = try self.field(allocator, "SELECT id FROM tools WHERE session_id=? AND upstream_tool=?", &.{ .{ .text = session.value }, .{ .text = upstream } });
                if (existing) |key| {
                    if (self.factory == null or !std.mem.eql(u8, key, tool_id.value)) return error.Conflict;
                    const old = try db.prepare("SELECT revision,action_digest FROM tools WHERE id=? AND run_id=? AND outcome='pending'", &.{ .{ .text = key }, .{ .text = run.value } });
                    defer old.deinit();
                    if (!try old.step() or old.integer(0) == std.math.maxInt(i64)) return error.Conflict;
                    if (!std.mem.eql(u8, try old.bytes(1), tool.action_digest))
                        try self.refineTool(key, tool.action_digest);
                    try db.execute("UPDATE tools SET name=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = tool.name }, .{ .text = key } });
                    try self.event(allocator, sequence, index, .{ .tool = tool_id }, @intCast(old.integer(0) + 1), "ToolUpdated", null, observation.correlation.effect, "");
                } else {
                    try db.execute("INSERT INTO tools(id,revision,run_id,session_id,upstream_tool,name,action_digest,outcome) VALUES(?,1,?,?,?,?,?,'pending')", &.{ .{ .text = tool_id.value }, .{ .text = run.value }, .{ .text = session.value }, .{ .text = upstream }, .{ .blob = tool.name }, .{ .blob = tool.action_digest } });
                    try db.execute("UPDATE runs SET unresolved_tools=unresolved_tools+1 WHERE id=?", &.{.{ .text = run.value }});
                    try self.event(allocator, sequence, index, .{ .tool = tool_id }, 1, "ToolStarted", null, observation.correlation.effect, "");
                }
                index += 1;
            },
            .tool_completed => |result| {
                const tool = observation.correlation.tool orelse return error.Conflict;
                const found = try db.prepare("SELECT revision,outcome FROM tools WHERE id=? AND run_id=? AND session_id=? AND upstream_tool=?", &.{ .{ .text = tool.value }, .{ .text = run.value }, .{ .text = session.value }, if (observation.correlation.upstream_tool) |v| .{ .text = v } else .null });
                defer found.deinit();
                if (!try found.step() or found.integer(0) == std.math.maxInt(i64)) return error.Conflict;
                if (!std.mem.eql(u8, try found.bytes(1), "pending")) return error.Conflict;
                // Tool results are bounded canonical content, not UI-only text.
                const block = try self.resultBlock(allocator, run.value, tool.value);
                var offset: usize = 0;
                while (offset < result.result.len) {
                    const end = @min(offset + 2048, result.result.len);
                    _ = try db.appendChunk(block, offset, result.result[offset..end]);
                    offset = end;
                }
                try db.execute("UPDATE tools SET outcome=?,result_block=?,revision=revision+1 WHERE id=?", &.{ .{ .text = @tagName(result.outcome) }, .{ .text = block }, .{ .text = tool.value } });
                try db.execute("UPDATE runs SET unresolved_tools=unresolved_tools-1 WHERE id=? AND unresolved_tools>0", &.{.{ .text = run.value }});
                try self.event(allocator, sequence, index, .{ .tool = tool }, @intCast(found.integer(0) + 1), "ToolCompleted", null, observation.correlation.effect, "");
                index += 1;
            },
            .approval => |approval| {
                if (terminal or std.mem.eql(u8, current_state, "cancel_requested") or !a.equal(approval.correlation, observation.correlation)) return error.Conflict;
                const approval_id = approval.correlation.approval orelse return error.Conflict;
                const tool_id = approval.correlation.tool orelse return error.Conflict;
                const request = approval.correlation.upstream_request orelse return error.Conflict;
                const tool_digest = try self.field(allocator, "SELECT action_digest FROM tools WHERE id=? AND run_id=? AND session_id=?", &.{ .{ .text = tool_id.value }, .{ .text = run.value }, .{ .text = session.value } }) orelse return error.Conflict;
                const workspace = try self.field(allocator, "SELECT workspace_id FROM sessions WHERE id=?", &.{.{ .text = session.value }}) orelse return error.Corrupt;
                if (self.factory != null and !std.mem.eql(u8, tool_digest, approval.action_digest)) {
                    try self.refineTool(tool_id.value, approval.action_digest);
                } else if (!std.mem.eql(u8, tool_digest, approval.action_digest)) return error.Conflict;
                if (!std.mem.eql(u8, workspace, approval.workspace.value)) return error.Conflict;
                if (approval.expires_at) |expiry| if (expiry > std.math.maxInt(i64)) return error.Limit;
                const thread = try self.field(allocator, "SELECT thread_id FROM runs WHERE id=?", &.{.{ .text = run.value }}) orelse return error.Corrupt;
                try db.execute("INSERT INTO approvals(id,revision,run_id,thread_id,session_id,tool_id,workspace_id,upstream_request,action_digest,scope,expires_at,state,live_epoch) VALUES(?,1,?,?,?,?,?,?,?,?,?,'pending',?)", &.{ .{ .text = approval_id.value }, .{ .text = run.value }, .{ .text = thread }, .{ .text = session.value }, .{ .text = tool_id.value }, .{ .text = workspace }, .{ .text = request }, .{ .blob = approval.action_digest }, .{ .blob = approval.scope }, if (approval.expires_at) |v| .{ .integer = @intCast(v) } else .null, .{ .text = self.epoch } });
                next_state = "awaiting_approval";
                try self.wakeSnoozed(allocator, sequence, observation.correlation.effect, run.value);
                try self.event(allocator, sequence, index, .{ .approval = approval_id }, 1, "ApprovalPending", null, observation.correlation.effect, "");
                index += 1;
            },
            .question => |question| {
                if (terminal or std.mem.eql(u8, current_state, "cancel_requested") or !a.equal(question.correlation, observation.correlation)) return error.Conflict;
                const question_id = question.correlation.question orelse return error.Conflict;
                try a.validateQuestion(question, .{});
                const existing = try self.field(allocator, "SELECT state FROM questions WHERE id=?", &.{.{ .text = question_id.value }});
                if (existing != null) return error.Conflict;
                const expires = if (question.expires_at) |value| blk: {
                    if (value > std.math.maxInt(i64)) return error.Limit;
                    break :blk V{ .integer = @intCast(value) };
                } else V.null;
                const thread = try self.field(allocator, "SELECT thread_id FROM runs WHERE id=?", &.{.{ .text = run.value }}) orelse return error.Corrupt;
                try db.execute("INSERT INTO questions(id,revision,run_id,thread_id,session_id,question,expires_at,state,live_epoch) VALUES(?,1,?,?,?,?,?, 'pending',?)", &.{ .{ .text = question_id.value }, .{ .text = run.value }, .{ .text = thread }, .{ .text = session.value }, .{ .blob = try encoded(allocator, question) }, expires, .{ .text = self.epoch } });
                next_state = "awaiting_question";
                try self.wakeSnoozed(allocator, sequence, observation.correlation.effect, run.value);
                try self.event(allocator, sequence, index, .{ .question = question_id }, 1, "QuestionPending", null, observation.correlation.effect, "");
                index += 1;
            },
            .completed => {
                const pending = try self.field(allocator, "SELECT id FROM tools WHERE run_id=? AND outcome IN('pending','unknown') LIMIT 1", &.{.{ .text = run.value }});
                if (!terminal) next_state = if (pending == null) "completed" else "unknown";
            },
            .cancelled => |cancelled| if (!terminal) {
                next_state = if (cancelled.tools_stopped) "cancelled" else "unknown";
            },
            .request_failed => |failure| {
                const effect_id = observation.correlation.effect.?;
                const pending = try db.prepare("SELECT revision,request FROM effects WHERE id=? AND run_id=? AND session_id=? AND kind='message' AND state IN('in_flight','confirmed','unknown')", &.{ .{ .text = effect_id.value }, .{ .text = run.value }, .{ .text = session.value } });
                defer pending.deinit();
                if (!try pending.step()) return error.Conflict;
                if (pending.integer(0) == std.math.maxInt(i64)) return error.Limit;
                const request = try t.decode(a.Request, try pending.bytes(1), allocator);
                if (request != .message or !a.equal(request.message.correlation.effect, observation.correlation.effect) or !a.equal(request.message.correlation.run, observation.correlation.run) or !a.equal(request.message.correlation.session, session)) return error.Conflict;
                if (observation.correlation.followup != null and !a.equal(request.message.correlation.followup, observation.correlation.followup)) return error.Conflict;
                try db.execute("UPDATE effects SET state='failed',outcome=?,evidence=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = failure.detail }, .{ .blob = try encoded(allocator, observation.body) }, .{ .text = effect_id.value } });
                try self.event(allocator, sequence, index, .{ .effect = effect_id }, @intCast(pending.integer(0) + 1), "RequestFailed", null, effect_id, "");
                index += 1;
            },
            .failure => |failure| if (!terminal) {
                // A definitive rejection before session publication resolves the
                // committed open claim; no dependent start may remain runnable.
                if (observation.correlation.effect) |effect| {
                    try db.execute("UPDATE effects SET state='failed',outcome=?,evidence=?,revision=revision+1 WHERE id=? AND run_id=? AND state='in_flight'", &.{ .{ .blob = failure.detail }, .{ .blob = try encoded(allocator, observation.body) }, .{ .text = effect.value }, .{ .text = run.value } });
                }
                try db.execute("UPDATE effects SET state='withdrawn',revision=revision+1 WHERE run_id=? AND state='planned'", &.{.{ .text = run.value }});
                next_state = "failed";
                try self.wakeSnoozed(allocator, sequence, observation.correlation.effect, run.value);
            },
            .disconnect, .ambiguous => if (!terminal) {
                // Unknown tools/requests remain unreplayed after process loss.
                next_state = "unknown";
            },
            .usage => |usage| {
                if (usage.cached_tokens > usage.input_tokens or usage.input_tokens > std.math.maxInt(i64) or usage.output_tokens > std.math.maxInt(i64)) return error.Limit;
                try db.execute("UPDATE tasks SET input_tokens=max(input_tokens,?),output_tokens=max(output_tokens,?),cached_tokens=max(cached_tokens,?) WHERE run_id=?", &.{ .{ .integer = @intCast(usage.input_tokens) }, .{ .integer = @intCast(usage.output_tokens) }, .{ .integer = @intCast(usage.cached_tokens) }, .{ .text = run.value } });
            },
            .selection => |selection| {
                const bytes = try self.field(allocator, "SELECT requested FROM runs WHERE id=?", &.{.{ .text = run.value }}) orelse return error.Corrupt;
                const requested = try t.decode(a.Selection, bytes, allocator);
                if (!a.equal(requested, selection.requested) or selection.effective == null or !a.equal(requested, selection.effective.?)) return error.Conflict;
                try db.execute("UPDATE runs SET effective=? WHERE id=?", &.{ .{ .blob = try encoded(allocator, selection.effective.?) }, .{ .text = run.value } });
            },
            .session => |live| {
                if (self.factory == null or terminal or !std.mem.eql(u8, live.id.value, session.value)) return error.Conflict;
                const effect_id: a.EffectId = if (observation.correlation.effect) |effect| effect else a.EffectId{ .value = try self.field(allocator, "SELECT id FROM effects WHERE session_id=? AND run_id=? AND kind='attach' AND state='confirmed' ORDER BY rowid DESC LIMIT 1", &.{ .{ .text = session.value }, .{ .text = run.value } }) orelse return error.Conflict };
                const pending = try db.prepare("SELECT revision FROM effects WHERE id=? AND session_id=? AND kind IN('create_session','attach') AND state IN('in_flight','confirmed')", &.{ .{ .text = effect_id.value }, .{ .text = session.value } });
                defer pending.deinit();
                if (!try pending.step()) return error.Conflict;
                const upstream = try self.field(allocator, "SELECT upstream_session FROM sessions WHERE id=?", &.{.{ .text = session.value }});
                if (upstream) |previous| if (!std.mem.eql(u8, previous, live.upstream.value)) return error.Conflict;
                try db.execute("UPDATE sessions SET instance_id=?,upstream_session=?,revision=revision+1 WHERE id=?", &.{ .{ .text = live.instance.value }, .{ .text = live.upstream.value }, .{ .text = session.value } });
                try db.execute("UPDATE effects SET state='confirmed',revision=revision+1 WHERE id=?", &.{.{ .text = effect_id.value }});
                try self.event(allocator, sequence, index, .{ .effect = effect_id }, @intCast(pending.integer(0) + 1), "SessionOpened", null, effect_id, "");
                index += 1;
                if (!std.mem.eql(u8, current_state, "cancel_requested")) next_state = "starting";
            },
        }
        try db.execute("INSERT INTO observations(session_id,upstream_event,runtime_version,correlation,digest,evidence,cursor,commit_sequence) VALUES(?,?,?,?,?,?,?,?)", &.{ .{ .text = session.value }, .{ .text = observation_key }, .{ .text = observation.runtime_version }, .{ .blob = try encoded(allocator, observation.correlation) }, .{ .blob = &digest }, switch (observation.body) {
            .failure, .disconnect, .ambiguous => .{ .blob = try encoded(allocator, observation.body) },
            else => .null,
        }, if (observation.cursor) |v| .{ .blob = v.value } else .null, .{ .integer = @intCast(sequence) } });
        // Cursor advances only in the transaction containing the canonical bytes.
        if (observation.cursor) |cursor| {
            const session_revision = try db.prepare("SELECT revision FROM sessions WHERE id=?", &.{.{ .text = session.value }});
            defer session_revision.deinit();
            if (!try session_revision.step() or session_revision.integer(0) == std.math.maxInt(i64)) return error.Limit;
            try db.execute("UPDATE sessions SET cursor=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = cursor.value }, .{ .text = session.value } });
            try self.event(allocator, sequence, index, .{ .session = session }, @intCast(session_revision.integer(0) + 1), "CursorCommitted", null, observation.correlation.effect, "");
            index += 1;
        }
        // Request diagnostics live on the effect, not the run's terminal
        // diagnostic projection. Cursor/observation identity still commits.
        if (observation.body != .request_failed) {
            try db.execute("UPDATE runs SET state=?,revision=revision+1 WHERE id=?", &.{ .{ .text = next_state }, .{ .text = run.value } });
            try self.event(allocator, sequence, index, .{ .run = run }, @intCast(state_statement.integer(1) + 1), "ObservationCommitted", null, observation.correlation.effect, "");
        }
        try self.finalizeMessages(run.value);
        try db.publishChanges(sequence, null);
        try db.commit();
    }
    fn newBlock(self: *Owner, allocator: std.mem.Allocator, message: []const u8, tool: ?[]const u8) ![]const u8 {
        const key = try self.id(allocator);
        try self.database.execute("INSERT INTO blocks(id,revision,message_id,ordinal,kind,tool_id) SELECT ?,1,?,coalesce(max(ordinal),-1)+1,?,? FROM blocks WHERE message_id=?", &.{
            .{ .text = key }, .{ .text = message }, .{ .text = if (tool != null) "tool_result" else "text" }, if (tool) |v| .{ .text = v } else .null, .{ .text = message },
        });
        try self.touchMessage(message);
        return key;
    }
    fn resultBlock(self: *Owner, allocator: std.mem.Allocator, run: []const u8, tool: []const u8) ![]const u8 {
        const statement = try self.database.prepare("SELECT result_block FROM tools WHERE id=? AND run_id=? AND outcome='pending'", &.{ .{ .text = tool }, .{ .text = run } });
        defer statement.deinit();
        if (!try statement.step()) return error.Conflict;
        if (!statement.isNull(0)) return allocator.dupe(u8, try statement.bytes(0));
        const message = try self.field(allocator, "SELECT id FROM messages WHERE run_id=? AND role='assistant'", &.{.{ .text = run }}) orelse return error.Corrupt;
        const block = try self.newBlock(allocator, message, tool);
        try self.database.execute("UPDATE tools SET result_block=? WHERE id=?", &.{ .{ .text = block }, .{ .text = tool } });
        return block;
    }
    fn refineTool(self: *Owner, tool: []const u8, digest: []const u8) !void {
        const resolved = try self.database.prepare("SELECT 1 FROM approvals WHERE tool_id=? AND state='resolved' LIMIT 1", &.{.{ .text = tool }});
        defer resolved.deinit();
        if (try resolved.step()) return error.Conflict;
        try self.database.execute("UPDATE approvals SET state='invalidated',live_epoch=NULL,revision=revision+1 WHERE tool_id=? AND state='pending'", &.{.{ .text = tool }});
        try self.database.execute("UPDATE tools SET action_digest=? WHERE id=? AND outcome='pending'", &.{ .{ .blob = digest }, .{ .text = tool } });
    }

    pub fn enforceTaskBudgets(self: *Owner, allocator: std.mem.Allocator) !void {
        const utc = self.utc_ms orelse return;
        const pending = try self.database.prepare("SELECT t.run_id,t.packet,t.created_at,t.input_tokens,t.output_tokens,r.revision FROM tasks t JOIN runs r ON r.id=t.run_id WHERE r.state IN('queued','starting','streaming','awaiting_approval') LIMIT 128", &.{});
        defer pending.deinit();
        while (try pending.step()) {
            const packet = try t.decode(t.orchestration.Packet, try pending.bytes(1), allocator);
            const tokens: u64 = @as(u64, @intCast(pending.integer(3))) +| @as(u64, @intCast(pending.integer(4)));
            const elapsed = if (pending.isNull(2)) 0 else utc -| @as(u64, @intCast(pending.integer(2)));
            if (tokens < packet.budget.max_tokens and elapsed < packet.budget.max_elapsed_ms) continue;
            const run = try allocator.dupe(u8, try pending.bytes(0));
            _ = try self.command(allocator, .{
                .command_id = .{ .value = try std.fmt.allocPrint(allocator, "budget:{s}", .{run}) },
                .target = .{ .run = .{ .value = run } },
                .expected_revision = .{ .revision = @intCast(pending.integer(5)) },
                .payload = .{ .task_cancel = .{ .reason = if (tokens >= packet.budget.max_tokens) "Observed token budget exhausted" else "Elapsed task budget exhausted" } },
            });
        }
    }
    pub const ToolReply = struct { success: bool, json: []const u8 };
    /// Both Codex dynamic RPCs and authenticated MCP invoke this owner method.
    /// A stable caller request key retains the exact public envelope before
    /// dispatch, including its original optimistic revision across retries.
    pub fn toolCall(self: *Owner, allocator: std.mem.Allocator, session: a.RuntimeSessionId, name: []const u8, arguments_json: []const u8) !ToolReply {
        const args = try coordinator_tools.parseArguments(allocator, name, arguments_json);
        // A resumed session can contain completed coordinator turns. The newest
        // run owns new calls; durable request keys still replay their saved
        // envelope/receipt, even when that envelope belongs to an earlier turn.
        const coordinator = try self.field(allocator, "SELECT id FROM runs WHERE session_id=? ORDER BY rowid DESC LIMIT 1", &.{.{ .text = session.value }}) orelse return error.AuthorityUnavailable;
        // Explicit task references retain their original parent across turns.
        // A sibling session cannot acquire that authority by knowing the ID.
        const parent = if (args.task_id) |task|
            try self.field(allocator, "SELECT t.parent_run FROM tasks t JOIN runs p ON p.id=t.parent_run WHERE t.run_id=? AND p.session_id=?", &.{ .{ .text = task }, .{ .text = session.value } }) orelse return error.AuthorityUnavailable
        else
            coordinator;
        if (std.mem.eql(u8, name, "task.catalog")) {
            const models = if (self.factory) |factory| factory.models() else &.{};
            return .{ .success = true, .json = try encoded(allocator, models) };
        }
        if (std.mem.eql(u8, name, "task.list") or std.mem.eql(u8, name, "task.wait")) {
            if (std.mem.eql(u8, name, "task.wait") and args.task_id == null) return error.InvalidToolArguments;
            return .{ .success = true, .json = try encoded(allocator, try self.taskRows(allocator, parent, args.task_id)) };
        }
        const key = args.request_key orelse return error.InvalidToolArguments;
        if (key.len == 0 or key.len > 256) return error.InvalidToolArguments;
        const canonical_args = try encoded(allocator, args);
        const digest = t.digest(canonical_args);
        var envelope: t.CommandEnvelope = undefined;
        const previous = try self.database.prepare("SELECT method,digest,command FROM bridge_calls WHERE session_id=? AND request_key=?", &.{ .{ .text = session.value }, .{ .text = key } });
        {
            defer previous.deinit();
            if (try previous.step()) {
                if (!std.mem.eql(u8, try previous.bytes(0), name) or !std.mem.eql(u8, try previous.bytes(1), &digest)) return error.ToolRequestConflict;
                envelope = try t.decode(t.CommandEnvelope, try previous.bytes(2), allocator);
            } else {
                const state = try self.field(allocator, "SELECT state FROM runs WHERE id=?", &.{.{ .text = coordinator }}) orelse return error.AuthorityUnavailable;
                if (!(std.mem.eql(u8, state, "streaming") or std.mem.eql(u8, state, "awaiting_approval"))) return error.AuthorityUnavailable;
                var payload: t.Payload = undefined;
                var target: a.RunId = .{ .value = parent };
                if (std.mem.eql(u8, name, "task.delegate")) {
                    payload = .{ .task_delegate = args.packet orelse return error.InvalidToolArguments };
                    if (args.task_id != null or args.content != null or args.reason != null or args.candidate != null or args.evidence != null or args.summary != null or args.disposition != null) return error.InvalidToolArguments;
                } else {
                    const task = args.task_id orelse return error.InvalidToolArguments;
                    if (try self.field(allocator, "SELECT run_id FROM tasks WHERE parent_run=? AND run_id=?", &.{ .{ .text = parent }, .{ .text = task } }) == null) return error.AuthorityUnavailable;
                    target = .{ .value = task };
                    if (std.mem.eql(u8, name, "task.send")) {
                        if (args.content == null or args.reason != null or args.candidate != null or args.evidence != null or args.summary != null or args.disposition != null) return error.InvalidToolArguments;
                        payload = .{ .task_send = .{ .content = args.content.? } };
                    } else if (std.mem.eql(u8, name, "task.cancel")) {
                        if (args.reason == null or args.content != null or args.candidate != null or args.evidence != null or args.summary != null or args.disposition != null) return error.InvalidToolArguments;
                        payload = .{ .task_cancel = .{ .reason = args.reason.? } };
                    } else if (std.mem.eql(u8, name, "task.result")) {
                        if (args.candidate == null or args.evidence == null or args.summary == null or args.content != null or args.reason != null or args.disposition != null) return error.InvalidToolArguments;
                        payload = .{ .task_result = .{ .candidate = args.candidate.?, .evidence = args.evidence.?, .summary = args.summary.? } };
                    } else if (std.mem.eql(u8, name, "task.review")) {
                        if (args.candidate == null or args.evidence == null or args.disposition == null or args.content != null or args.reason != null or args.summary != null) return error.InvalidToolArguments;
                        payload = .{ .task_review = .{ .candidate = args.candidate.?, .evidence = args.evidence.?, .disposition = std.meta.stringToEnum(t.orchestration.Disposition, args.disposition.?) orelse return error.InvalidToolArguments } };
                    } else return error.UnsupportedTool;
                    if (args.packet != null) return error.InvalidToolArguments;
                }
                const command_id = try std.fmt.allocPrint(allocator, "tool:{s}:{s}", .{ session.value, key });
                envelope = .{ .command_id = .{ .value = command_id }, .target = .{ .run = target }, .expected_revision = .{ .revision = (try self.revision(.{ .run = target })) orelse return error.NotFound }, .payload = payload };
                try self.database.execute("INSERT INTO bridge_calls VALUES(?,?,?,?,?)", &.{ .{ .text = session.value }, .{ .text = key }, .{ .text = name }, .{ .blob = &digest }, .{ .blob = try encoded(allocator, envelope) } });
            }
        }
        const receipt = try self.command(allocator, envelope);
        return .{ .success = receipt.outcome == .accepted, .json = try encoded(allocator, receipt) };
    }
    fn taskRows(self: *Owner, allocator: std.mem.Allocator, parent: []const u8, task: ?[]const u8) ![]t.Row {
        const statement = try self.database.prepare("SELECT t.run_id,t.parent_run,t.packet,t.requests,t.input_tokens,t.output_tokens,t.cached_tokens,t.result,t.review,r.state,r.revision FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.parent_run=? AND (? IS NULL OR t.run_id=?) ORDER BY t.rowid LIMIT 16", &.{ .{ .text = parent }, if (task) |v| .{ .text = v } else .null, if (task) |v| .{ .text = v } else .null });
        defer statement.deinit();
        const rows = try allocator.alloc(t.Row, 16);
        var count: usize = 0;
        while (try statement.step()) {
            rows[count] = .{ .task = .{
                .task = .{
                    .id = .{ .value = try allocator.dupe(u8, try statement.bytes(0)) },
                    .parent = .{ .value = try allocator.dupe(u8, try statement.bytes(1)) },
                    .packet = try t.decode(t.orchestration.Packet, try statement.bytes(2), allocator),
                    .requests = @intCast(statement.integer(3)),
                    .input_tokens = @intCast(statement.integer(4)),
                    .output_tokens = @intCast(statement.integer(5)),
                    .cached_tokens = @intCast(statement.integer(6)),
                    .result = if (statement.isNull(7)) null else try t.decode(t.orchestration.Result, try statement.bytes(7), allocator),
                    .review = if (statement.isNull(8)) null else std.meta.stringToEnum(t.orchestration.Disposition, try statement.bytes(8)) orelse return error.Corrupt,
                },
                .state = std.meta.stringToEnum(t.RunState, try statement.bytes(9)) orelse return error.Corrupt,
                .revision = @intCast(statement.integer(10)),
            } };
            count += 1;
        }
        if (task != null and count == 0) return error.AuthorityUnavailable;
        return rows[0..count];
    }
    /// Follow-up journals carry attachment metadata only. The durable body is
    /// owned by the thread attachment row and remains protected from removal
    /// while any follow-up effect still references it.
    fn validateFollowupAttachments(self: *Owner, allocator: std.mem.Allocator, run: []const u8, selection: a.Selection, references: []const a.Attachment) !?t.Reason {
        if (references.len == 0) return null;
        a.validateNativeAttachments(references, .{ .attachment_count = self.limits.attachment_count, .attachment_bytes = self.limits.attachment_bytes, .attachment_metadata_bytes = self.limits.attachment_metadata_bytes }) catch return .attachment_limit;
        const thread = try self.field(allocator, "SELECT thread_id FROM runs WHERE id=?", &.{.{ .text = run }}) orelse return .not_found;
        const provider: attachments.Provider = if (std.mem.eql(u8, selection.runtime_kind, "codex")) .codex else .opencode;
        for (references) |reference| {
            const row = try self.database.prepare("SELECT name,media_type,byte_length,digest,kind,content FROM attachments WHERE id=? AND thread_id=?", &.{ .{ .text = reference.metadata.id.value }, .{ .text = thread } });
            defer row.deinit();
            if (!try row.step()) return .not_found;
            const metadata: a.AttachmentMetadata = .{ .id = reference.metadata.id, .name = try row.bytes(0), .media_type = try row.bytes(1), .byte_length = @intCast(row.integer(2)), .digest = try row.bytes(3), .kind = std.meta.stringToEnum(a.AttachmentKind, try row.bytes(4)) orelse return error.Corrupt };
            if (!a.equal(reference.metadata, metadata)) return .attachment_limit;
            const body: a.Attachment = .{ .metadata = metadata, .content = try row.bytes(5) };
            attachments.validate(body, true) catch return .attachment_limit;
            if (!attachments.supported(metadata.media_type, metadata.kind, provider)) return .attachment_unsupported;
            if (reference.content.len != 0 and (!a.equal(reference.metadata, metadata) or !attachments.digestMatches(reference))) return .attachment_limit;
        }
        return null;
    }

    fn followupReferencesAttachment(self: *Owner, allocator: std.mem.Allocator, attachment_id: []const u8) !bool {
        const rows = try self.database.prepare("SELECT request FROM effects WHERE kind='message' AND state IN('planned','in_flight','confirmed','unknown')", &.{});
        defer rows.deinit();
        while (try rows.step()) {
            const request = t.decode(a.Request, try rows.bytes(0), allocator) catch continue;
            if (request == .message) for (request.message.attachments) |reference| if (std.mem.eql(u8, reference.metadata.id.value, attachment_id)) return true;
        }
        return false;
    }

    /// Materialize only immutable refs belonging to the Start's durable user
    /// message. Draft rows in the same thread do not grant dispatch authority.
    pub fn hydrateStartAttachments(self: *Owner, allocator: std.mem.Allocator, request: *a.Request) !void {
        if (request.* != .start or request.start.attachments.len == 0) return;
        const start = &request.start;
        a.validateNativeAttachments(start.attachments, .{ .attachment_count = self.limits.attachment_count, .attachment_bytes = self.limits.attachment_bytes, .attachment_metadata_bytes = self.limits.attachment_metadata_bytes }) catch return error.Corrupt;
        const run = start.correlation.run orelse return error.Corrupt;
        const hydrated = try allocator.alloc(a.Attachment, start.attachments.len);
        for (start.attachments, 0..) |reference, index| {
            const body = try self.database.prepare("SELECT a.name,a.media_type,a.byte_length,a.digest,a.kind,a.content FROM attachments a JOIN attachment_refs ref ON ref.attachment_id=a.id JOIN messages m ON m.id=ref.message_id WHERE a.id=? AND m.run_id=? AND m.role='user' AND a.thread_id=m.thread_id AND ref.ordinal=?", &.{ .{ .text = reference.metadata.id.value }, .{ .text = run.value }, .{ .integer = @intCast(index) } });
            defer body.deinit();
            if (!try body.step()) return error.Corrupt;
            const content = try body.bytes(5);
            const metadata: a.AttachmentMetadata = .{ .id = reference.metadata.id, .name = try body.bytes(0), .media_type = try body.bytes(1), .byte_length = @intCast(body.integer(2)), .digest = try body.bytes(3), .kind = std.meta.stringToEnum(a.AttachmentKind, try body.bytes(4)) orelse return error.Corrupt };
            const borrowed: a.Attachment = .{ .metadata = metadata, .content = content };
            // Validate borrowed SQLite views before allocating any body/metadata.
            if (!a.equal(reference.metadata, metadata)) return error.Corrupt;
            attachments.validate(borrowed, true) catch return error.Corrupt;
            if (!attachments.digestMatches(borrowed)) return error.Corrupt;
            hydrated[index] = try @import("runtime/adapter.zig").clone(allocator, borrowed);
        }
        start.attachments = hydrated;
    }

    /// Materialize a queued follow-up's attachment bodies immediately before
    /// provider dispatch. The run/thread join is the authority boundary; a
    /// metadata-only journal cannot smuggle a body or another thread's file.
    pub fn hydrateMessageAttachments(self: *Owner, allocator: std.mem.Allocator, request: *a.Request) !void {
        if (request.* != .message or request.message.attachments.len == 0) return;
        const message = &request.message;
        const run = message.correlation.run orelse return error.Corrupt;
        const hydrated = try allocator.alloc(a.Attachment, message.attachments.len);
        const thread = try self.field(allocator, "SELECT thread_id FROM runs WHERE id=? AND session_id=?", &.{ .{ .text = run.value }, .{ .text = message.correlation.session.value } }) orelse return error.Corrupt;
        a.validateNativeAttachments(message.attachments, .{ .attachment_count = self.limits.attachment_count, .attachment_bytes = self.limits.attachment_bytes, .attachment_metadata_bytes = self.limits.attachment_metadata_bytes }) catch return error.Corrupt;
        for (message.attachments, 0..) |reference, index| {
            const row = try self.database.prepare("SELECT name,media_type,byte_length,digest,kind,content FROM attachments WHERE id=? AND thread_id=?", &.{ .{ .text = reference.metadata.id.value }, .{ .text = thread } });
            defer row.deinit();
            if (!try row.step()) return error.Corrupt;
            const content = try row.bytes(5);
            const metadata: a.AttachmentMetadata = .{ .id = reference.metadata.id, .name = try row.bytes(0), .media_type = try row.bytes(1), .byte_length = @intCast(row.integer(2)), .digest = try row.bytes(3), .kind = std.meta.stringToEnum(a.AttachmentKind, try row.bytes(4)) orelse return error.Corrupt };
            if (!a.equal(reference.metadata, metadata)) return error.Corrupt;
            const body: a.Attachment = .{ .metadata = metadata, .content = content };
            attachments.validate(body, true) catch return error.Corrupt;
            if (!attachments.digestMatches(body)) return error.Corrupt;
            hydrated[index] = try @import("runtime/adapter.zig").clone(allocator, body);
        }
        message.attachments = hydrated;
    }

    pub fn recover(self: *Owner) !void {
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        try self.database.recoverClaims();
        if (try self.database.scalar("SELECT count(*) FROM aggregate_changes") != 0) {
            try self.database.publishChanges((try self.database.position()).commit_sequence, null);
        }
        try self.database.commit();
    }
};

/// Bounded asynchronous gateway. The worker is the only database/adapter owner.
/// Admission copies input; drain relocates every output slice into caller storage.
pub const Host = struct {
    pub const Options = struct {
        state_directory: []const u8,
        limits: t.Limits = .{},
        wake: ?*const fn (?*anyopaque) void = null,
        wake_context: ?*anyopaque = null,
        /// Main retains factory/config through Host.destroy. Each committed
        /// app session receives a distinct Host-owned process/session object.
        factory: ?Factory = null,
        setup_factory: ?Factory = null,
        /// Explicit CLI runtime selection wins over remembered settings.
        restore_configuration: bool = true,
        selection: ?a.Selection = null,
        workspace_root: ?[]const u8 = null,
    };
    const Request = union(enum) {
        command: t.CommandEnvelope,
        query: t.Query,
        subscribe: t.Subscribe,
        unsubscribe: t.SubscriptionId,
        presentation_load: []const u8,
        presentation_save: struct { key: []const u8, value: []const u8 },
    };
    const Frame = struct {
        prompt_bytes: usize = 0,
        attachment_bytes: usize = 0,
        ticket: t.Ticket = .{ .value = 0 },
        len: usize = 0,
        bytes: [65536]u8 = undefined,
        attachment_content: [attachments.max_bytes]u8 = undefined,
    };
    const Result = struct { len: usize = 0, bytes: [262144]u8 = undefined };
    const Snapshot = struct { generation: u64 = 0, database: ?*store.c.sqlite3 = null, position: t.EventPosition = .{}, deadline: u64 = 0 };
    const Subscription = struct { generation: u64 = 0, active: bool = false, scope: t.Scope = .all, after: t.EventPosition = .{}, max_bytes: usize = 65536, arena: std.heap.ArenaAllocator };
    const FinalPresentation = struct {
        key: [128]u8 = undefined,
        key_len: usize = 0,
        value: [4096]u8 = undefined,
        value_len: usize = 0,
    };
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    database: store.Store,
    registry: ?Registry = null,
    mcp: ?Mcp = null,
    setup_active: bool = false,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    runtime_wake: std.Io.Event = .unset,
    closed: bool = false,
    final_presentation: FinalPresentation = .{},
    next_ticket: u64 = 1,
    requests: [8]Frame = undefined,
    prompt_inbox: [prompts.max_bytes]u8 = undefined,
    prompt_pending: bool = false,
    request_head: usize = 0,
    request_count: usize = 0,
    results: [8]Result = undefined,
    result_head: usize = 0,
    result_count: usize = 0,
    snapshots: [2]Snapshot = .{ .{}, .{} },
    subscriptions: [4]Subscription = undefined,
    epoch: [32]u8 = undefined,
    path: [:0]u8,
    restore_arena: std.heap.ArenaAllocator,
    restore_status: ?a.RuntimeStatus = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Host {
        const l = options.limits;
        if (l.request_slots == 0 or l.request_slots > 8 or l.result_slots == 0 or l.result_slots > 8 or l.snapshot_slots == 0 or l.snapshot_slots > 2 or l.subscription_slots > 4 or l.command_bytes > 65536 or l.page_bytes > 65536 or l.page_rows > 128 or l.page_rows == 0 or l.attachment_count > attachments.max_count or l.attachment_bytes > attachments.max_bytes or l.attachment_metadata_bytes > attachments.max_metadata_bytes or l.attachment_packet_bytes > attachment_packet_limit) return error.InvalidLimits;
        if (options.factory != null and options.selection == null) return error.InvalidSelection;
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        var database = try store.Store.open(io, options.state_directory);
        errdefer database.close() catch {};
        var filename: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = try std.Io.Dir.cwd().openDir(io, options.state_directory, .{});
        defer dir.close(io);
        const n = try dir.realPath(io, &filename);
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/conversation.sqlite3", .{filename[0..n]}, 0);
        errdefer allocator.free(path);
        self.* = .{ .allocator = allocator, .io = io, .options = options, .database = database, .path = path, .restore_arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer self.restore_arena.deinit();
        const factory = options.factory orelse @import("domain/fake_factory.zig").factory(self);
        self.mcp = try Mcp.init();
        self.registry = .{ .allocator = allocator, .factory = factory };
        errdefer if (self.mcp) |*server| server.deinit();
        for (&self.subscriptions) |*sub| sub.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var owner: Owner = .{ .database = &self.database, .io = io, .epoch = "", .utc_ms = null, .limits = options.limits };
        @memcpy(&self.epoch, try owner.id(arena.allocator()));
        try owner.recover();
        // Restore explicit configuration only. Never replay refresh, sign-in,
        // accepted inference, or an interrupted setup effect.
        if (options.restore_configuration) if (options.setup_factory) |setup| {
            const stored = try database.prepare("SELECT runtime_kind,configuration FROM runtime_configurations ORDER BY CASE WHEN runtime_kind=(SELECT active_runtime_kind FROM runtime_preferences WHERE singleton=1) THEN 1 ELSE 0 END,runtime_kind", &.{});
            defer stored.deinit();
            while (try stored.step()) {
                _ = arena.reset(.retain_capacity);
                const retained = self.restore_arena.allocator();
                // Even a broken saved configuration must not route through the
                // synthetic fixture. The last (active) entry owns public status.
                self.registry.?.factory = setup;
                self.options.factory = setup;
                self.restore_status = null;
                const kind = try stored.bytes(0);
                const configuration = t.decode(a.RuntimeSetup, try stored.bytes(1), arena.allocator()) catch {
                    self.restore_status = try common.clone(retained, a.RuntimeStatus{ .runtime_kind = kind, .configurations = setup.runtimeStatus().configurations, .readiness = .unavailable, .reason = "Saved provider settings are invalid. Edit and save the connection to repair them." });
                    self.options.workspace_root = null;
                    continue;
                };
                setup.runtimeAction(allocator, io, .{ .restore = configuration }) catch |err| {
                    self.restore_status = try common.clone(retained, a.RuntimeStatus{ .runtime_kind = @tagName(configuration.runtime_kind), .configuration = configuration, .configurations = setup.runtimeStatus().configurations, .workspace_root = configuration.workspace_root, .readiness = .unavailable, .reason = try std.fmt.allocPrint(retained, "Saved provider setup could not be restored: {s}. Edit and save the connection.", .{@errorName(err)}) });
                };
                self.options.workspace_root = if (self.restore_status) |status| status.workspace_root else setup.runtimeStatus().workspace_root;
            }
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Host) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.changed.broadcast(self.io);
        self.runtime_wake.set(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        for (&self.snapshots) |*snapshot| self.closeSnapshot(snapshot);
        if (self.mcp) |*server| server.deinit();
        for (&self.subscriptions) |*sub| sub.arena.deinit();
        self.database.close() catch {};
        self.restore_arena.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
    pub fn selectionFor(self: *const Host, workspace: a.WorkspaceId) a.Selection {
        var selection = self.options.selection orelse a.Selection{
            .model_provider = "fake",
            .model_id = "fixture",
            .effort = "none",
            .account_ref = "fixture",
            .workspace = workspace,
        };
        selection.workspace = workspace;
        return selection;
    }
    pub fn submit(self: *Host, command: t.CommandEnvelope) t.AdmissionError!t.Ticket {
        if (command.payload == .followup_enqueue or command.payload == .followup_edit) {
            const attached = if (command.payload == .followup_enqueue) command.payload.followup_enqueue.attachments else command.payload.followup_edit.attachments;
            if (attached.len > attachments.max_count) return error.TooLarge;
            var metadata: [attachments.max_count]a.Attachment = undefined;
            for (attached, 0..) |item, index| {
                metadata[index] = item;
                metadata[index].content = &.{};
            }
            var compact = command;
            if (compact.payload == .followup_enqueue) compact.payload.followup_enqueue.attachments = metadata[0..attached.len] else compact.payload.followup_edit.attachments = metadata[0..attached.len];
            return self.admit(.{ .command = compact });
        }
        if (command.payload == .attachment_add) {
            const input = command.payload.attachment_add;
            attachments.validate(input, true) catch return error.TooLarge;
            if (!attachments.digestMatches(input)) return error.TooLarge;
            if (input.content.len > self.options.limits.attachment_bytes or attachments.metadataBytes(input.metadata) > self.options.limits.attachment_metadata_bytes) return error.TooLarge;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var compact = command;
            compact.payload.attachment_add.content = &.{};
            const ticket = try self.admitLocked(.{ .command = compact });
            const frame = &self.requests[(self.request_head + self.request_count - 1) % 8];
            frame.attachment_bytes = input.content.len;
            @memcpy(frame.attachment_content[0..input.content.len], input.content);
            return ticket;
        }
        if (command.payload != .thread_send) return self.admit(.{ .command = command });
        const p = command.payload.thread_send;
        if (p.text.len == 0 or p.text.len > max_prompt_bytes or !std.unicode.utf8ValidateSlice(p.text)) return error.TooLarge;
        var compact = command;
        compact.payload = .{ .thread_send_staged = .{ .prompt = prompts.reference(command.command_id.value, p.text), .selection = p.selection, .attachments = p.attachments } };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.prompt_pending) return error.Busy;
        const ticket = try self.admitLocked(.{ .command = compact });
        const frame = &self.requests[(self.request_head + self.request_count - 1) % 8];
        frame.prompt_bytes = p.text.len;
        frame.attachment_bytes = 0;
        @memcpy(self.prompt_inbox[0..p.text.len], p.text);
        self.prompt_pending = true;
        return ticket;
    }
    /// Copies one bounded attachment into the Host request ring and admits its
    /// durable add command. The caller may release or reuse all input memory
    /// immediately after this call returns.
    pub fn uploadAttachment(self: *Host, command_id: t.CommandId, thread: t.ThreadId, revision: u64, attachment: a.Attachment) t.AdmissionError!t.Ticket {
        return self.submit(.{ .command_id = command_id, .target = .{ .thread = thread }, .expected_revision = .{ .revision = revision }, .payload = .{ .attachment_add = attachment } });
    }
    pub fn query(self: *Host, request: t.Query) t.AdmissionError!t.Ticket {
        return self.admit(.{ .query = request });
    }
    pub fn loadPresentation(self: *Host, key: []const u8) t.AdmissionError!t.Ticket {
        if (key.len == 0 or key.len > 128) return error.TooLarge;
        if (!std.unicode.utf8ValidateSlice(key) or std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidText;
        return self.admit(.{ .presentation_load = key });
    }
    pub fn savePresentation(self: *Host, key: []const u8, value: []const u8) t.AdmissionError!t.Ticket {
        if (key.len == 0 or key.len > 128 or value.len > 4096) return error.TooLarge;
        if (!std.unicode.utf8ValidateSlice(key) or std.mem.indexOfScalar(u8, key, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        return self.admit(.{ .presentation_save = .{ .key = key, .value = value } });
    }
    /// Reserve the latest final UI snapshot independently of request/result
    /// capacity. Shutdown persists only this slot on the owning worker; it does
    /// not replay pending commands or extend provider lifetimes.
    pub fn retainFinalPresentation(self: *Host, key: []const u8, value: []const u8) t.AdmissionError!void {
        if (key.len == 0 or key.len > 128 or value.len > 4096) return error.TooLarge;
        if (!std.unicode.utf8ValidateSlice(key) or std.mem.indexOfScalar(u8, key, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        @memcpy(self.final_presentation.key[0..key.len], key);
        self.final_presentation.key_len = key.len;
        @memcpy(self.final_presentation.value[0..value.len], value);
        self.final_presentation.value_len = value.len;
    }
    pub fn subscribe(self: *Host, request: t.Subscribe) t.AdmissionError!t.Ticket {
        return self.admit(.{ .subscribe = request });
    }
    pub fn unsubscribe(self: *Host, id_value: t.SubscriptionId) t.AdmissionError!t.Ticket {
        return self.admit(.{ .unsubscribe = id_value });
    }
    fn admit(self: *Host, request: Request) t.AdmissionError!t.Ticket {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.admitLocked(request);
    }
    fn admitLocked(self: *Host, request: Request) t.AdmissionError!t.Ticket {
        if (self.closed) return error.Closed;
        if (self.request_count == self.options.limits.request_slots or self.next_ticket == std.math.maxInt(u64)) return error.Full;
        const frame = &self.requests[(self.request_head + self.request_count) % 8];
        const bytes = t.encode(request, frame.bytes[0..self.options.limits.command_bytes]) catch return error.TooLarge;
        frame.len = bytes.len;
        frame.prompt_bytes = 0;
        frame.attachment_bytes = 0;
        frame.ticket = .{ .value = self.next_ticket };
        self.next_ticket += 1;
        self.request_count += 1;
        self.changed.signal(self.io);
        self.runtime_wake.set(self.io);
        return frame.ticket;
    }
    pub fn drain(self: *Host, outputs: []t.Output, storage_bytes: []u8) t.DrainResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var fixed = std.heap.FixedBufferAllocator.init(storage_bytes);
        var count: usize = 0;
        var required: usize = 0;
        while (count < outputs.len and self.result_count != 0) {
            const frame = &self.results[self.result_head];
            const before = fixed.end_index;
            outputs[count] = t.decode(t.Output, frame.bytes[0..frame.len], fixed.allocator()) catch {
                fixed.end_index = before;
                required = frame.len * 8 + 8192;
                break;
            };
            count += 1;
            self.result_count -= 1;
            self.result_head = (self.result_head + 1) % 8;
        }
        self.changed.signal(self.io);
        return .{ .output_count = count, .bytes_used = fixed.end_index, .more_pending = self.result_count != 0, .required_bytes_for_next = required };
    }
    fn publish(self: *Host, output: t.Output) !void {
        self.mutex.lockUncancelable(self.io);
        while (!self.closed and self.result_count == self.options.limits.result_slots) self.changed.waitUncancelable(self.io, &self.mutex);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return error.Closed;
        }
        const frame = &self.results[(self.result_head + self.result_count) % 8];
        const encoded_output = t.encode(output, &frame.bytes) catch |err| {
            self.mutex.unlock(self.io);
            return err;
        };
        frame.len = encoded_output.len;
        self.result_count += 1;
        self.mutex.unlock(self.io);
        if (self.options.wake) |wake| wake(self.options.wake_context);
    }
    fn now(self: *Host) u64 {
        return @intCast(@max(0, std.Io.Clock.awake.now(self.io).toMilliseconds()));
    }
    fn closeSnapshot(_: *Host, snapshot: *Snapshot) void {
        if (snapshot.database) |database| _ = store.c.sqlite3_close(database);
        snapshot.database = null;
    }
    fn run(self: *Host) void {
        var owner: Owner = .{ .database = &self.database, .io = self.io, .epoch = &self.epoch, .utc_ms = null, .factory = self.registry.?.factory, .workspace_root = self.options.workspace_root, .setup_factory = self.options.setup_factory, .runtime_registry = &self.registry.?, .limits = self.options.limits };
        defer if (self.registry) |*registry| registry.deinit(&self.mcp.?);
        defer if (self.options.setup_factory) |setup| {
            if (setup.vtable.shutdownSetup) |call| call(setup.context);
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var operation_memory: [2 * 1024 * 1024]u8 = undefined;
        var prompt_transfer: [prompts.max_bytes]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.closed and self.request_count == 0 and self.options.factory == null and !self.setup_active) self.changed.waitUncancelable(self.io, &self.mutex);
            if (self.closed) {
                const final = self.final_presentation;
                self.mutex.unlock(self.io);
                if (final.key_len != 0) self.persistPresentation(final.key[0..final.key_len], final.value[0..final.value_len]) catch |err| {
                    std.log.err("Final sidebar settings could not be saved: {s}", .{@errorName(err)});
                };
                return;
            }
            const frame: ?Frame = if (self.request_count != 0) blk: {
                const value = self.requests[self.request_head];
                if (value.prompt_bytes != 0) {
                    @memcpy(prompt_transfer[0..value.prompt_bytes], self.prompt_inbox[0..value.prompt_bytes]);
                    self.prompt_pending = false;
                }
                self.request_head = (self.request_head + 1) % 8;
                self.request_count -= 1;
                break :blk value;
            } else null;
            self.runtime_wake.reset();
            self.mutex.unlock(self.io);
            var fixed = std.heap.FixedBufferAllocator.init(&operation_memory);
            const allocator = fixed.allocator();
            owner.utc_ms = @intCast(@max(0, std.Io.Clock.real.now(self.io).toMilliseconds()));
            owner.enforceTaskBudgets(allocator) catch {};
            for (&self.snapshots) |*snapshot| if (snapshot.database != null and self.now() >= snapshot.deadline) {
                self.closeSnapshot(snapshot);
            };
            if (frame) |input| {
                var request = t.decode(Request, input.bytes[0..input.len], allocator) catch {
                    self.fail(input.ticket, .admission_limit);
                    continue;
                };
                if (request == .command and request.command.payload == .attachment_add and input.attachment_bytes != 0) {
                    const bytes = allocator.alloc(u8, input.attachment_bytes) catch {
                        self.fail(input.ticket, .admission_limit);
                        continue;
                    };
                    @memcpy(bytes, input.attachment_content[0..input.attachment_bytes]);
                    request.command.payload.attachment_add.content = bytes;
                }
                self.handle(&owner, allocator, input.ticket, request, prompt_transfer[0..input.prompt_bytes]) catch |err| {
                    self.database.rollback() catch {};
                    self.fail(input.ticket, switch (err) {
                        error.CursorInvalid => .cursor_invalid,
                        error.NotFound => .not_found,
                        error.InvalidQuery => .invalid_query,
                        error.Limit, error.OutOfMemory, error.TooLarge => .admission_limit,
                        else => .storage_unavailable,
                    });
                };
            }
            // Each adapter call follows a committed claim. A failed delivery is
            // left in_flight and recovery will mark it unknown, never retry it.
            var steps: usize = 0;
            while (steps < 8) : (steps += 1) {
                _ = arena.reset(.retain_capacity);
                const claimed = owner.claimNext(arena.allocator()) catch break;
                const effect = claimed orelse break;
                self.dispatch(&owner, arena.allocator(), effect) catch break;
                self.pumpRuntimes(&owner, &arena) catch {};
            }
            self.pumpRuntimes(&owner, &arena) catch {};
            if (self.options.setup_factory) |setup| {
                self.setup_active = if (setup.vtable.pumpSetup) |call| call(setup.context) else false;
            }
            self.deliverSubscriptions(allocator) catch {};
            // Admission and shutdown wake immediately; absent transport wake
            // support, pending protocol frames are sampled at a bounded 10ms.
            if (frame == null and (self.options.factory != null or self.setup_active))
                self.runtime_wake.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        }
    }
    fn runtimeFault(owner: *Owner, allocator: std.mem.Allocator, session: a.RuntimeSessionId, reason: []const u8) !void {
        try owner.observe(allocator, .{
            .correlation = .{ .session = session },
            .upstream_event = try owner.id(allocator),
            .body = .{ .ambiguous = .{ .reason = reason } },
        });
    }
    /// Recreate a provider process only for a durable upstream session. This
    /// path never emits an open.create request and cannot replace a missing
    /// conversation with a contextless session.
    fn restoreExisting(self: *Host, selection: a.Selection, binding: t.WorkspaceBinding, effect: a.EffectId, request: a.Request, now_ms: u64) !void {
        if (request != .open or request.open != .existing) return error.InvalidOpenRequest;
        const registry = &self.registry.?;
        const session = request.open.existing.session.id;
        if (registry.find(session) != null) return;
        for (&registry.entries) |*slot| if (slot.* == null) {
            var entry_arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer entry_arena.deinit();
            const retained = entry_arena.allocator();
            const retained_session = try common.clone(retained, session);
            const retained_selection = try common.clone(retained, selection);
            const retained_request = try common.clone(retained, request);
            var random: [16]u8 = undefined;
            try self.io.randomSecure(&random);
            const token = try retained.alloc(u8, 32);
            const hex = "0123456789abcdef";
            for (random, 0..) |byte, index| {
                token[index * 2] = hex[byte >> 4];
                token[index * 2 + 1] = hex[byte & 15];
            }
            const bridge = try self.mcp.?.bindSession(retained, retained_session.value, token);
            errdefer self.mcp.?.unbindSession(retained_session.value);
            const adapter = try registry.factory.create(self.allocator, retained_selection, binding.canonical_root, retained_session, bridge);
            slot.* = .{ .arena = entry_arena, .session = retained_session, .selection = retained_selection, .adapter = adapter, .pending_open = .{ .effect = try common.clone(retained, effect), .request = retained_request }, .created_ms = now_ms };
            return;
        };
        return error.RuntimeCapacity;
    }
    fn pumpRuntimes(self: *Host, owner: *Owner, arena: *std.heap.ArenaAllocator) !void {
        const registry = if (self.registry) |*value| value else return;
        for (&registry.entries, 0..) |*optional, entry_index| {
            const entry = if (optional.*) |*value| value else continue;
            _ = arena.reset(.retain_capacity);
            var allocator = arena.allocator();
            entry.adapter.pump() catch |err| {
                if (entry.pending_open) |pending| {
                    try owner.delivered(allocator, pending.effect, .{ .outcome = .rejected, .detail = @errorName(err) });
                    entry.pending_open = null;
                } else try runtimeFault(owner, allocator, entry.session, @errorName(err));
                registry.release(&self.mcp.?, entry_index);
                continue;
            };
            if (try entry.openReady(allocator, self.now())) |delivery|
                try owner.delivered(allocator, delivery.effect, delivery.receipt);
            var observations: usize = 0;
            while (observations < 32) : (observations += 1) {
                _ = arena.reset(.retain_capacity);
                allocator = arena.allocator();
                const observation = (entry.adapter.poll(allocator) catch |err| {
                    try runtimeFault(owner, allocator, entry.session, @errorName(err));
                    break;
                }) orelse break;
                if (!std.mem.eql(u8, observation.correlation.session.value, entry.session.value)) {
                    try runtimeFault(owner, allocator, entry.session, "Runtime emitted another app session identity");
                    break;
                }
                owner.observe(allocator, observation) catch |err| {
                    try runtimeFault(owner, allocator, entry.session, @errorName(err));
                };
            }
            _ = arena.reset(.retain_capacity);
            allocator = arena.allocator();
            if (try entry.adapter.pollTool(allocator)) |call| {
                const reply: Owner.ToolReply = if (!std.mem.eql(u8, call.correlation.session.value, entry.session.value))
                    .{ .success = false, .json = "{\"error\":\"Session authority mismatch\"}" }
                else
                    owner.toolCall(allocator, entry.session, call.name, call.arguments_json) catch |err|
                        .{ .success = false, .json = try t.encode(.{ .@"error" = @errorName(err) }, try allocator.alloc(u8, 4096)) };
                try entry.adapter.respondTool(call.request_id_json, reply.success, reply.json);
            }
            // Process ownership ends at a terminal/ambiguous boundary, while
            // durable unknown claims remain for explicit reconciliation.
            const done = try self.database.prepare("SELECT 1 FROM sessions s WHERE s.id=? AND NOT EXISTS(SELECT 1 FROM runs active WHERE active.session_id=s.id AND active.state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested')) AND NOT EXISTS(SELECT 1 FROM effects pending WHERE pending.session_id=s.id AND pending.state IN('planned','in_flight')) AND EXISTS(SELECT 1 FROM runs terminal WHERE terminal.session_id=s.id AND (terminal.state IN('unknown','interrupted','failed') OR terminal.state IN('completed','cancelled')))", &.{.{ .text = entry.session.value }});
            const release = blk: {
                defer done.deinit();
                break :blk try done.step();
            };
            if (release) {
                registry.release(&self.mcp.?, entry_index);
            }
        }
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();
        if (try self.mcp.?.poll(allocator, @intCast(self.now()))) |invocation| {
            self.handleMcp(owner, allocator, invocation) catch |err| {
                const body = try t.encode(.{ .jsonrpc = "2.0", .id = @as(?u8, null), .@"error" = .{ .code = -32603, .message = @errorName(err) } }, try allocator.alloc(u8, 4096));
                try self.mcp.?.respond(invocation.client, 200, body);
            };
        }
    }
    fn jsonField(value: std.json.Value, key: []const u8) std.json.Value {
        return if (value == .object) value.object.get(key) orelse .null else .null;
    }
    fn handleMcp(self: *Host, owner: *Owner, allocator: std.mem.Allocator, invocation: Mcp.Invocation) !void {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, invocation.json, .{ .allocate = .alloc_always, .max_value_len = 65536 });
        const id = jsonField(value, "id");
        const method = jsonField(value, "method");
        if (method != .string) return error.InvalidMcpRequest;
        if (id == .null) {
            if (!std.mem.eql(u8, method.string, "notifications/initialized")) return error.UnsupportedMcpNotification;
            try self.mcp.?.respond(invocation.client, 202, "");
            return;
        }
        const response = try allocator.alloc(u8, 65536);
        const bytes = if (std.mem.eql(u8, method.string, "initialize"))
            try t.encode(.{ .jsonrpc = "2.0", .id = id, .result = .{ .protocolVersion = "2025-03-26", .capabilities = .{ .tools = .{ .listChanged = false } }, .serverInfo = .{ .name = "spica", .version = "1" }, .instructions = "These task tools create and manage Spica-owned children. Provider-native subagents are separate and do not appear in Spica. Delegate packets require an explicit authorized runtime, account, model, effort, workspace, owned paths and acceptance evidence. task.wait reads current durable state without blocking generation. Use the registered task tools for app-owned delegation." } }, response)
        else if (std.mem.eql(u8, method.string, "tools/list")) blk: {
            const Tool = struct { name: []const u8, description: []const u8, inputSchema: std.json.Value };
            var tools: [coordinator_tools.descriptors.len]Tool = undefined;
            for (coordinator_tools.descriptors, 0..) |tool_descriptor, index| tools[index] = .{
                .name = tool_descriptor.name,
                .description = tool_descriptor.description,
                .inputSchema = try std.json.parseFromSliceLeaky(std.json.Value, allocator, tool_descriptor.input_schema, .{}),
            };
            break :blk try t.encode(.{ .jsonrpc = "2.0", .id = id, .result = .{ .tools = tools } }, response);
        } else if (std.mem.eql(u8, method.string, "tools/call")) blk: {
            const params = jsonField(value, "params");
            const name = jsonField(params, "name");
            if (name != .string) return error.InvalidMcpRequest;
            const args = try t.encode(jsonField(params, "arguments"), try allocator.alloc(u8, 16384));
            const reply = owner.toolCall(allocator, .{ .value = invocation.session }, name.string, args) catch |err| Owner.ToolReply{
                .success = false,
                .json = try t.encode(.{ .@"error" = @errorName(err) }, try allocator.alloc(u8, 4096)),
            };
            break :blk try t.encode(.{ .jsonrpc = "2.0", .id = id, .result = .{ .content = .{.{ .type = "text", .text = reply.json }}, .isError = !reply.success } }, response);
        } else if (std.mem.eql(u8, method.string, "ping"))
            try t.encode(.{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = .empty } }, response)
        else
            try t.encode(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32601, .message = "Unsupported MCP method" } }, response);
        try self.mcp.?.respond(invocation.client, 200, bytes);
    }
    fn fail(self: *Host, ticket: t.Ticket, reason: @FieldType(t.Failure, "reason")) void {
        self.publish(.{ .failure = .{ .ticket = ticket, .failure = .{ .reason = reason, .refresh_required = reason == .cursor_invalid } } }) catch {};
    }
    fn handle(self: *Host, owner: *Owner, allocator: std.mem.Allocator, ticket: t.Ticket, request: Request, prompt: []const u8) !void {
        switch (request) {
            .presentation_load => |key| try self.publish(.{ .presentation_loaded = .{ .ticket = ticket, .value = try self.database.loadPresentation(allocator, key) } }),
            .presentation_save => |value| {
                try self.persistPresentation(value.key, value.value);
                try self.publish(.{ .presentation_saved = .{ .ticket = ticket } });
            },
            .command => |command| {
                const used = try self.database.scalar("PRAGMA page_count");
                const page_size = try self.database.scalar("PRAGMA page_size");
                if (@as(u64, @intCast(used)) *| @as(u64, @intCast(page_size)) >= self.options.limits.durable_bytes) return error.Limit;
                const before_sequence: u64 = @intCast(try self.database.scalar("SELECT next_sequence FROM meta WHERE singleton=1"));
                const receipt = blk: {
                    if (prompt.len != 0) {
                        if (try owner.commandReplay(allocator, command)) |previous| break :blk previous;
                        owner.stagePrompt(command.payload.thread_send_staged.prompt, prompt) catch |err| switch (err) {
                            error.PromptStagingFull => break :blk try owner.commandCanonical(allocator, command, .prompt_staging_full),
                            error.PromptConflict, error.InvalidPrompt, error.PromptIncomplete => break :blk try owner.commandCanonical(allocator, command, .prompt_invalid),
                            else => return err,
                        };
                    }
                    break :blk try owner.command(allocator, command);
                };
                if (receipt.outcome == .accepted and receipt.commit_sequence >= before_sequence) {
                    if (command.payload == .thread_archive or command.payload == .thread_restore or command.payload == .thread_delete)
                        for (&self.snapshots) |*snapshot| self.closeSnapshot(snapshot);
                    const action: ?a.RuntimeAction = switch (command.payload) {
                        .runtime_configure => |v| .{ .configure = v },
                        .runtime_refresh => .refresh,
                        .runtime_login => |v| .{ .login = v },
                        else => null,
                    };
                    if (action) |value| {
                        const setup = self.options.setup_factory.?;
                        // Release completed adapters with their original factory
                        // before switching execution routing/configuration.
                        self.registry.?.deinit(&self.mcp.?);
                        if (value == .configure or value == .login) self.restore_status = null;
                        const applied = if (setup.runtimeAction(self.allocator, self.io, value)) |_| true else |_| false;
                        if (value == .configure and applied) {
                            const configuration = setup.runtimeStatus().configuration orelse return error.InvalidConfiguration;
                            try self.database.saveRuntimeConfiguration(@tagName(configuration.runtime_kind), try Owner.encoded(allocator, configuration));
                            self.registry.?.factory = setup;
                            owner.factory = setup;
                            self.options.factory = setup;
                            owner.workspace_root = setup.runtimeStatus().workspace_root;
                            self.options.workspace_root = owner.workspace_root;
                        }
                        for (&self.snapshots) |*snapshot| self.closeSnapshot(snapshot);
                    }
                }
                try self.publish(.{ .command_receipt = .{ .ticket = ticket, .receipt = receipt } });
            },
            .query => |q| try self.publish(.{ .query_page = .{ .ticket = ticket, .page = try self.project(allocator, q) } }),
            .subscribe => |subscription| {
                if (subscription.max_batch_bytes == 0 or subscription.max_batch_bytes > self.options.limits.page_bytes) return error.Limit;
                const position = try self.database.position();
                if (subscription.after_position.order(position) == .gt) return error.CursorInvalid;
                for (self.subscriptions[0..self.options.limits.subscription_slots], 0..) |*sub, i| {
                    if (sub.active) continue;
                    if (sub.generation == std.math.maxInt(u64)) return error.Limit;
                    _ = sub.arena.reset(.retain_capacity);
                    var buffer: [4096]u8 = undefined;
                    sub.scope = try t.decode(t.Scope, try t.encode(subscription.scope, &buffer), sub.arena.allocator());
                    sub.generation += 1;
                    sub.active = true;
                    sub.after = subscription.after_position;
                    sub.max_bytes = subscription.max_batch_bytes;
                    try self.publish(.{ .subscribed = .{ .ticket = ticket, .id = .{ .slot = @intCast(i), .generation = sub.generation }, .after_position = sub.after } });
                    return;
                }
                return error.Limit;
            },
            .unsubscribe => |id_value| {
                if (id_value.slot >= self.options.limits.subscription_slots) return error.CursorInvalid;
                const sub = &self.subscriptions[id_value.slot];
                if (!sub.active or sub.generation != id_value.generation) return error.CursorInvalid;
                sub.active = false;
                _ = sub.arena.reset(.retain_capacity);
                try self.publish(.{ .unsubscribed = .{ .ticket = ticket } });
            },
        }
    }

    fn persistPresentation(self: *Host, key: []const u8, value: []const u8) !void {
        const used = try self.database.scalar("PRAGMA page_count");
        const page_size = try self.database.scalar("PRAGMA page_size");
        if (@as(u64, @intCast(used)) *| @as(u64, @intCast(page_size)) >= self.options.limits.durable_bytes) return error.Limit;
        try self.database.savePresentation(key, value);
    }

    fn dispatch(self: *Host, owner: *Owner, allocator: std.mem.Allocator, effect: Owner.Claimed) !void {
        const registry = &self.registry.?;
        {
            const metadata = try self.database.prepare("SELECT e.session_id,s.selection,w.binding FROM effects e JOIN sessions s ON s.id=e.session_id JOIN workspaces w ON w.id=s.workspace_id WHERE e.id=?", &.{.{ .text = effect.id.value }});
            defer metadata.deinit();
            if (!try metadata.step()) return error.Corrupt;
            const session: a.RuntimeSessionId = .{ .value = try allocator.dupe(u8, try metadata.bytes(0)) };
            const selection = try t.decode(a.Selection, try metadata.bytes(1), allocator);
            const binding = try t.decode(t.WorkspaceBinding, try metadata.bytes(2), allocator);
            if (effect.request == .open or effect.request == .start or effect.request == .message or effect.request == .answer_question) {
                if (!(workspace_binding.verifyCheckout(allocator, self.io, binding) catch false)) {
                    try owner.delivered(allocator, effect.id, .{ .outcome = .rejected, .detail = "Workspace identity changed before dispatch" });
                    return;
                }
            }
            if (effect.request == .open and effect.request.open == .create) {
                _ = registry.create(self.io, &self.mcp.?, selection, binding.canonical_root, effect.id, effect.request, self.now()) catch |err| {
                    try owner.delivered(allocator, effect.id, .{ .outcome = .unknown, .detail = @errorName(err) });
                };
            } else if (effect.request == .open and effect.request.open == .existing) {
                if (registry.find(session)) |entry| {
                    _ = entry;
                    try owner.delivered(allocator, effect.id, .{ .outcome = .acknowledged, .session = effect.request.open.existing.session, .continuity = .proven });
                } else {
                    self.restoreExisting(selection, binding, effect.id, effect.request, self.now()) catch |err| {
                        try owner.delivered(allocator, effect.id, .{ .outcome = .unknown, .detail = @errorName(err) });
                    };
                }
            } else if (registry.find(session)) |entry| {
                if (effect.request == .cancel) if (entry.pending_open) |pending| {
                    entry.pending_open = null;
                    try owner.delivered(allocator, pending.effect, .{ .outcome = .rejected, .detail = "Cancelled before open dispatch" });
                    try owner.delivered(allocator, effect.id, .{ .outcome = .acknowledged });
                    try owner.observe(allocator, .{ .correlation = effect.request.cancel.correlation, .upstream_event = "host-cancel-before-open", .body = .{ .cancelled = .{ .tools_stopped = true } } });
                    for (registry.entries, 0..) |optional, index| if (optional) |value| {
                        if (std.mem.eql(u8, value.session.value, session.value)) {
                            registry.release(&self.mcp.?, index);
                            break;
                        }
                    };
                    return;
                };
                var request = effect.request;
                var prompt_buffer: [prompts.max_bytes]u8 = undefined;
                if (request == .start) if (request.start.prompt_ref) |ref| {
                    request.start.prompt = prompts.readBlock(&self.database, ref.id, ref, &prompt_buffer) catch |err| {
                        try owner.delivered(allocator, effect.id, .{ .outcome = .rejected, .detail = @errorName(err) });
                        return;
                    };
                    request.start.prompt_ref = null;
                };
                try owner.hydrateStartAttachments(allocator, &request);
                try owner.hydrateMessageAttachments(allocator, &request);
                try owner.delivered(allocator, effect.id, try entry.adapter.dispatch(allocator, request));
            } else {
                try owner.delivered(allocator, effect.id, .{ .outcome = .unknown, .detail = "No live instance for durable session; explicit reconciliation required" });
            }
            return;
        }
    }

    fn snapshotFor(self: *Host, page: t.Page) !struct { id: t.SnapshotId, value: *Snapshot } {
        if (page.snapshot) |id_value| {
            if (id_value.slot >= self.options.limits.snapshot_slots) return error.CursorInvalid;
            const snapshot = &self.snapshots[id_value.slot];
            if (snapshot.database == null or snapshot.generation != id_value.generation or self.now() >= snapshot.deadline) return error.CursorInvalid;
            return .{ .id = id_value, .value = snapshot };
        }
        if (page.cursor != null) return error.CursorInvalid;
        for (self.snapshots[0..self.options.limits.snapshot_slots], 0..) |*snapshot, i| {
            if (snapshot.database != null) continue;
            if (snapshot.generation == std.math.maxInt(u64)) return error.Limit;
            var database: ?*store.c.sqlite3 = null;
            try store.check(store.c.sqlite3_open_v2(self.path.ptr, &database, store.c.SQLITE_OPEN_READONLY | store.c.SQLITE_OPEN_NOFOLLOW, null));
            errdefer if (database) |db| {
                _ = store.c.sqlite3_close(db);
            };
            try store.check(store.c.sqlite3_exec(database, "BEGIN", null, null, null));
            var reader = self.database;
            reader.database = database.?;
            snapshot.position = try reader.position();
            snapshot.database = database;
            snapshot.generation += 1;
            snapshot.deadline = self.now() +| self.options.limits.snapshot_ttl_ms;
            return .{ .id = .{ .slot = @intCast(i), .generation = snapshot.generation }, .value = snapshot };
        }
        // A new root query replaces the oldest ephemeral view; old IDs fail closed.
        var oldest: usize = 0;
        for (self.snapshots[0..self.options.limits.snapshot_slots], 0..) |snapshot, i| if (snapshot.deadline < self.snapshots[oldest].deadline) {
            oldest = i;
        };
        self.closeSnapshot(&self.snapshots[oldest]);
        return self.snapshotFor(page);
    }
    fn text(allocator: std.mem.Allocator, statement: store.Statement, column: c_int) ![]const u8 {
        return allocator.dupe(u8, try statement.bytes(column));
    }
    fn enumeration(comptime T: type, statement: store.Statement, column: c_int) !T {
        return std.meta.stringToEnum(T, try statement.bytes(column)) orelse error.Corrupt;
    }
    fn number(statement: store.Statement, column: c_int) !u64 {
        const value = statement.integer(column);
        if (value < 0) return error.Corrupt;
        return @intCast(value);
    }
    fn descriptor(allocator: std.mem.Allocator, s: store.Statement) !t.BlockDescriptor {
        return .{ .block_id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .ordinal = try number(s, 3), .kind = try enumeration(@FieldType(t.BlockDescriptor, "kind"), s, 4), .committed_bytes = try number(s, 5), .tool_id = if (s.isNull(6)) null else .{ .value = try text(allocator, s, 6) } };
    }
    fn project(self: *Host, allocator: std.mem.Allocator, q: t.Query) !t.QueryPage {
        const page: t.Page = switch (q) {
            .projects => |p| p,
            .models => |v| v.page,
            .workspaces => |v| v.page,
            .threads => |v| v.page,
            .thread_sidebar_next => |v| v.page,
            .messages => |v| v.page,
            .blocks => |v| v.page,
            .attachments => |v| v.page,
            .content => |v| v.page,
            .runs => |v| v.page,
            .effects => |v| v.page,
            .tools => |v| v.page,
            .approvals => |v| v.page,
            .task_list => |v| v.page,
            .questions => |v| v.page,
            .thread, .capabilities, .runtime_status, .task_wait, .command_receipt => .{},
        };
        if (page.limit == 0 or page.limit > self.options.limits.page_rows or page.max_bytes == 0 or page.max_bytes > self.options.limits.page_bytes) return error.InvalidQuery;
        const snapshot = try self.snapshotFor(page);
        var reader = self.database;
        reader.database = snapshot.value.database.?;
        var result: t.QueryPage = .{ .snapshot_id = snapshot.id, .snapshot_position = snapshot.value.position, .items = &.{}, .expires_at = snapshot.value.deadline };
        const rows = try allocator.alloc(t.Row, page.limit);
        var count: usize = 0;
        var bytes_used: usize = 0;
        const Cursor = struct { query: []const u8, key: u64, order_pin: i64 = -2, order_sort: i64 = 0, order_id: []const u8 = "" };
        const identity_buffer = try allocator.alloc(u8, 65536);
        var identity_query = q;
        switch (identity_query) {
            .projects => |*v| v.* = .{},
            .models => |*v| v.page = .{},
            .workspaces => |*v| v.page = .{},
            .threads => |*v| v.page = .{},
            .thread_sidebar_next => |*v| v.page = .{},
            .messages => |*v| v.page = .{},
            .blocks => |*v| v.page = .{},
            .attachments => |*v| v.page = .{},
            .content => |*v| v.page = .{},
            .runs => |*v| v.page = .{},
            .effects => |*v| v.page = .{},
            .tools => |*v| v.page = .{},
            .approvals => |*v| v.page = .{},
            .questions => |*v| v.page = .{},
            .task_list => |*v| v.page = .{},
            else => {},
        }
        const identity = try t.encode(identity_query, identity_buffer);
        var cursor: u64 = 0;
        var order_pin: i64 = -2;
        var order_sort: i64 = 0;
        var order_id: []const u8 = "";
        if (page.cursor) |raw| {
            const parsed = t.decode(Cursor, raw, allocator) catch return error.CursorInvalid;
            if (!std.mem.eql(u8, parsed.query, identity) or parsed.key > std.math.maxInt(i64)) return error.CursorInvalid;
            cursor = parsed.key;
            order_pin = parsed.order_pin;
            order_sort = parsed.order_sort;
            order_id = parsed.order_id;
            if (q == .threads and q.threads.sidebar_order and
                ((order_pin != -1 and order_pin != 0) or order_id.len == 0)) return error.CursorInvalid;
        }
        var sql: [:0]const u8 = undefined;
        var values: [8]V = undefined;
        var query_root_digest: [32]u8 = undefined;
        var n: usize = 0;
        switch (q) {
            .command_receipt => |id_value| {
                const statement = try reader.prepare("SELECT receipt FROM commands WHERE command_id=?", &.{.{ .text = id_value.value }});
                defer statement.deinit();
                rows[0] = .{ .command_receipt = if (try statement.step()) try t.decode(t.Receipt, try statement.bytes(0), allocator) else null };
                result.items = rows[0..1];
                return result;
            },
            .runtime_status => {
                const borrowed = self.restore_status orelse if (self.options.setup_factory) |setup| setup.runtimeStatus() else a.RuntimeStatus{};
                if (borrowed.configurations.len > 2) return error.ConfigurationLimit;
                const status = try common.clone(allocator, borrowed);
                const binding = if (status.workspace_root.len != 0) workspace_binding.capture(allocator, self.io, status.workspace_root) catch null else null;
                rows[0] = .{ .runtime_status = .{ .configuration = status.configuration, .configurations = status.configurations, .login_pending = status.login_pending, .runtime_kind = status.runtime_kind, .readiness = status.readiness, .reason = status.reason, .login = status.login, .workspace_root = status.workspace_root, .binding = binding, .supported_login_modes = if (std.mem.eql(u8, status.runtime_kind, "codex")) &.{ "browser", "device" } else &.{} } };
                result.items = rows[0..1];
                return result;
            },
            .models => |v| {
                if (v.workspace.value.len == 0) return error.InvalidQuery;
                // Metadata pages are invalidated on any committed command,
                // including a refresh; never continue a stale catalog snapshot.
                if ((try self.database.position()).order(snapshot.value.position) != .eq) return error.CursorInvalid;
                const configured = if (self.options.setup_factory) |setup| setup.models() else &.{};
                const fake_models = [_]a.Model{.{
                    .selection = self.selectionFor(v.workspace),
                    .supported_efforts = &.{"none"},
                    .display_name = "Fake provider (synthetic fixture)",
                    .readiness = .ready,
                    .reason = "Synthetic local fixture; no provider inference or account",
                    .synthetic = true,
                }};
                const catalog = if (self.options.factory == null) &fake_models else configured;
                var index: usize = @intCast(cursor);
                if (index > catalog.len) return error.CursorInvalid;
                var encoded_row: [65536]u8 = undefined;
                while (index < catalog.len and count < page.limit) : (index += 1) {
                    var model = catalog[index];
                    model.selection.workspace = v.workspace;
                    const row: t.Row = .{ .model = model };
                    const size = (try t.encode(row, &encoded_row)).len;
                    if (size > page.max_bytes - bytes_used) {
                        if (count == 0) return error.Limit;
                        break;
                    }
                    rows[count] = row;
                    count += 1;
                    bytes_used += size;
                }
                if (index < catalog.len) result.next_cursor = try Owner.encoded(allocator, .{ .query = identity, .key = index });
                result.items = rows[0..count];
                return result;
            },
            .capabilities => {
                rows[0] = .{ .capabilities = self.registry.?.factory.discover(self.selectionFor(.{ .value = "" })) };
                result.items = rows[0..1];
                return result;
            },
            .task_list => |v| {
                sql = "SELECT t.rowid,t.run_id,t.parent_run,t.packet,t.requests,t.input_tokens,t.output_tokens,t.cached_tokens,t.result,t.review,r.state,r.revision FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.parent_run=? AND EXISTS(SELECT 1 FROM threads WHERE id=r.thread_id AND deleted=0) AND EXISTS(SELECT 1 FROM runs p JOIN threads h ON h.id=p.thread_id WHERE p.id=t.parent_run AND h.deleted=0) AND t.rowid>? ORDER BY t.rowid LIMIT ?";
                values[0] = .{ .text = v.parent.value };
                n = 1;
            },
            .task_wait => |v| {
                sql = "SELECT t.rowid,t.run_id,t.parent_run,t.packet,t.requests,t.input_tokens,t.output_tokens,t.cached_tokens,t.result,t.review,r.state,r.revision FROM tasks t JOIN runs r ON r.id=t.run_id WHERE t.run_id=? AND EXISTS(SELECT 1 FROM threads WHERE id=r.thread_id AND deleted=0) AND EXISTS(SELECT 1 FROM runs p JOIN threads h ON h.id=p.thread_id WHERE p.id=t.parent_run AND h.deleted=0) AND t.rowid>? LIMIT ?";
                values[0] = .{ .text = v.value };
                n = 1;
            },
            .projects => sql = "SELECT rowid,id,revision,display_name FROM projects WHERE rowid>? ORDER BY rowid LIMIT ?",
            .workspaces => |v| {
                sql = "SELECT rowid,id,revision,project_id,binding FROM workspaces WHERE project_id=? AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.project.value };
                n = 1;
            },
            .threads => |v| {
                if (v.archived and (v.canonical_root == null or v.canonical_root.?.len == 0)) return error.InvalidQuery;
                const has_root = v.canonical_root != null;
                if (v.canonical_root) |root| query_root_digest = canonicalRootKey(root);
                var anchor_rowid: i64 = 0;
                if (page.cursor == null) if (v.anchor) |anchor| {
                    const boundary = try reader.prepare("SELECT rowid,-pinned,sort_order,id,project_id,root_key,(SELECT json_extract(CAST(binding AS TEXT),'$.canonical_root') FROM workspaces WHERE id=threads.workspace_id) FROM threads WHERE id=? AND deleted=0 AND archived=?", &.{ .{ .text = anchor.value }, .{ .integer = @intFromBool(v.archived) } });
                    defer boundary.deinit();
                    if (!try boundary.step()) return error.NotFound;
                    if (v.project) |project_id| if (!std.mem.eql(u8, project_id.value, try boundary.bytes(4))) return error.NotFound;
                    if (v.canonical_root) |root| if (!std.mem.eql(u8, &query_root_digest, try boundary.bytes(5)) or !std.mem.eql(u8, root, try boundary.bytes(6))) return error.NotFound;
                    anchor_rowid = boundary.integer(0);
                    order_pin = boundary.integer(1);
                    order_sort = boundary.integer(2);
                    order_id = try allocator.dupe(u8, try boundary.bytes(3));
                };
                values[0] = .{ .integer = @intFromBool(v.archived) };
                n = 1;
                if (has_root) {
                    values[n] = .{ .blob = &query_root_digest };
                    values[n + 1] = .{ .text = v.canonical_root.? };
                    n += 2;
                }
                const visible = "WHERE deleted=0 AND archived=? ";
                const root_scope = "AND root_key=? AND EXISTS(SELECT 1 FROM workspaces w WHERE w.id=threads.workspace_id AND json_extract(CAST(w.binding AS TEXT),'$.canonical_root')=?) ";
                const project_scope = "AND project_id=? ";
                const ordered = "AND (-pinned,sort_order,id)>(?,?,?) ORDER BY -pinned,sort_order,id LIMIT ?";
                const classic = "AND rowid>max(?,?) ORDER BY rowid LIMIT ?";
                if (v.project) |scoped_project| {
                    sql = if (has_root)
                        (if (v.sidebar_order) thread_columns ++ visible ++ root_scope ++ project_scope ++ ordered else thread_columns ++ visible ++ root_scope ++ project_scope ++ classic)
                    else
                        (if (v.sidebar_order) thread_columns ++ visible ++ project_scope ++ ordered else thread_columns ++ visible ++ project_scope ++ classic);
                    values[n] = .{ .text = scoped_project.value };
                    n += 1;
                } else sql = if (has_root)
                    (if (v.sidebar_order) thread_columns ++ visible ++ root_scope ++ ordered else thread_columns ++ visible ++ root_scope ++ classic)
                else
                    (if (v.sidebar_order) thread_columns ++ visible ++ ordered else thread_columns ++ visible ++ classic);
                if (v.sidebar_order) {
                    values[n] = .{ .integer = order_pin };
                    values[n + 1] = .{ .integer = order_sort };
                    values[n + 2] = .{ .text = order_id };
                    n += 3;
                } else {
                    values[n] = .{ .integer = @intCast(cursor) };
                    values[n + 1] = .{ .integer = anchor_rowid };
                    n += 2;
                }
            },
            .thread_sidebar_next => |v| {
                query_root_digest = canonicalRootKey(v.canonical_root);
                var boundary_pin: i64 = 0;
                var boundary_sort: i64 = 0;
                var boundary_id: []const u8 = "";
                if (v.after) |after| {
                    // The anchor is valid only when both its immutable root
                    // partition and its authoritative binding match this
                    // request. A hash match alone is insufficient: a corrupt
                    // or colliding row must fail closed.
                    const b = try reader.prepare("SELECT -pinned,sort_order,id FROM threads WHERE id=? AND deleted=0 AND archived=0 AND root_key=? AND EXISTS(SELECT 1 FROM workspaces w WHERE w.id=threads.workspace_id AND json_extract(CAST(w.binding AS TEXT),'$.canonical_root')=?)", &.{ .{ .text = after.value }, .{ .blob = &query_root_digest }, .{ .text = v.canonical_root } });
                    defer b.deinit();
                    if (!try b.step()) return error.CursorInvalid;
                    boundary_pin = b.integer(0);
                    boundary_sort = b.integer(1);
                    boundary_id = try allocator.dupe(u8, try b.bytes(2));
                }
                // Filter the root partition once, then choose the first row
                // strictly after the anchor and wrap to the first eligible row
                // when the tail is exhausted. The candidate CTEs are bounded
                // by the root indexes and the outer projection fetches one row.
                const eligible_prefix = "WITH eligible AS (SELECT id,pinned,sort_order FROM threads WHERE deleted=0 AND archived=0 AND root_key=? AND EXISTS(SELECT 1 FROM workspaces w WHERE w.id=threads.workspace_id AND json_extract(CAST(w.binding AS TEXT),'$.canonical_root')=?)";
                values[0] = .{ .blob = &query_root_digest };
                values[1] = .{ .text = v.canonical_root };
                if (v.project) |scoped_project| {
                    values[2] = .{ .text = scoped_project.value };
                    n = 3;
                } else {
                    n = 2;
                }
                values[n] = .{ .integer = @intCast(@max(0, std.Io.Clock.real.now(self.io).toMilliseconds())) };
                n += 1;
                const eligible_project = " AND project_id=?";
                const eligible_live = " AND settled=0 AND snoozed_until<=?), candidate AS (SELECT id,pinned,sort_order FROM eligible";
                const candidate_after = " WHERE (-pinned,sort_order,id)>(?,?,?) ORDER BY pinned DESC,sort_order,id LIMIT 1), chosen AS (SELECT id,pinned,sort_order FROM candidate UNION ALL SELECT id,pinned,sort_order FROM eligible WHERE NOT EXISTS(SELECT 1 FROM candidate) ORDER BY pinned DESC,sort_order,id LIMIT 1)";
                const candidate_first = " WHERE 0 ORDER BY pinned DESC,sort_order,id LIMIT 1), chosen AS (SELECT id,pinned,sort_order FROM candidate UNION ALL SELECT id,pinned,sort_order FROM eligible WHERE NOT EXISTS(SELECT 1 FROM candidate) ORDER BY pinned DESC,sort_order,id LIMIT 1)";
                const projection = thread_columns ++ "WHERE id=(SELECT id FROM chosen) LIMIT 1";
                const project_after = eligible_prefix ++ eligible_project ++ eligible_live ++ candidate_after ++ projection;
                const project_first = eligible_prefix ++ eligible_project ++ eligible_live ++ candidate_first ++ projection;
                const root_after = eligible_prefix ++ eligible_live ++ candidate_after ++ projection;
                const root_first = eligible_prefix ++ eligible_live ++ candidate_first ++ projection;
                if (v.after) |_| {
                    values[n] = .{ .integer = boundary_pin };
                    values[n + 1] = .{ .integer = boundary_sort };
                    values[n + 2] = .{ .text = boundary_id };
                    n += 3;
                }
                sql = if (v.project != null)
                    (if (v.after != null) project_after else project_first)
                else
                    (if (v.after != null) root_after else root_first);
            },
            .thread => |v| {
                sql = thread_columns ++ "WHERE id=? AND deleted=0 AND rowid>? LIMIT ?";
                values[0] = .{ .text = v.value };
                n = 1;
            },
            .messages => |v| {
                if (v.anchor) |anchor| {
                    const existing = try reader.prepare("SELECT 1 FROM messages WHERE id=? AND thread_id=?", &.{ .{ .text = anchor.value }, .{ .text = v.thread.value } });
                    defer existing.deinit();
                    if (!try existing.step()) return error.NotFound;
                }
                sql = if (v.direction == .newer) "SELECT ordinal+1,id,revision,ordinal,role,incomplete,run_id FROM messages WHERE thread_id=? AND EXISTS(SELECT 1 FROM threads WHERE id=messages.thread_id AND deleted=0) AND ordinal>=max(?,coalesce((SELECT ordinal+1 FROM messages WHERE id=? AND thread_id=?),0)) ORDER BY ordinal LIMIT ?" else "SELECT ordinal+1,id,revision,ordinal,role,incomplete,run_id FROM messages WHERE thread_id=? AND EXISTS(SELECT 1 FROM threads WHERE id=messages.thread_id AND deleted=0) AND ordinal<min(?-1,coalesce((SELECT ordinal FROM messages WHERE id=? AND thread_id=?),9223372036854775807)) ORDER BY ordinal DESC LIMIT ?";
                if (v.direction == .older and cursor == 0) cursor = std.math.maxInt(i64);
                values[0] = .{ .text = v.thread.value };
                values[1] = .{ .integer = @intCast(cursor) };
                values[2] = if (v.anchor) |anchor| .{ .text = anchor.value } else .null;
                values[3] = .{ .text = v.thread.value };
                n = 4;
            },
            .blocks => |v| {
                sql = "SELECT ordinal+1,id,revision,ordinal,kind,committed_bytes,tool_id FROM blocks WHERE message_id=? AND EXISTS(SELECT 1 FROM messages m JOIN threads t ON t.id=m.thread_id WHERE m.id=blocks.message_id AND t.deleted=0) AND ordinal+1>? ORDER BY ordinal LIMIT ?";
                values[0] = .{ .text = v.message.value };
                n = 1;
            },
            .attachments => |v| {
                sql = "SELECT rowid,id,revision,thread_id,name,media_type,byte_length,digest,kind FROM attachments WHERE thread_id=? AND EXISTS(SELECT 1 FROM threads WHERE id=attachments.thread_id AND deleted=0) AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.thread.value };
                n = 1;
            },
            .runs => |v| {
                sql = "SELECT rowid,id,revision,thread_id,session_id,state,requested,effective,coalesce((SELECT evidence FROM observations WHERE session_id=runs.session_id AND json_extract(CAST(correlation AS TEXT),'$.run.value')=runs.id AND evidence IS NOT NULL ORDER BY commit_sequence DESC LIMIT 1),'') FROM runs WHERE thread_id=? AND EXISTS(SELECT 1 FROM threads WHERE id=runs.thread_id AND deleted=0) AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.thread.value };
                n = 1;
            },
            .effects => |v| {
                sql = "SELECT rowid,id,revision,run_id,kind,state,outcome FROM effects WHERE run_id=? AND EXISTS(SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id WHERE r.id=effects.run_id AND t.deleted=0) AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.run.value };
                n = 1;
            },
            .tools => |v| {
                sql = "SELECT rowid,id,revision,run_id,name,action_digest,outcome,result_block FROM tools WHERE run_id=? AND EXISTS(SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id WHERE r.id=tools.run_id AND t.deleted=0) AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.run.value };
                n = 1;
            },
            .approvals => |v| {
                sql = "SELECT rowid,id,revision,run_id,state,session_id,tool_id,workspace_id,upstream_request,action_digest,scope,expires_at,live_epoch FROM approvals WHERE run_id=? AND EXISTS(SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id WHERE r.id=approvals.run_id AND t.deleted=0) AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.run.value };
                n = 1;
            },
            .questions => |v| {
                sql = "SELECT rowid,id,revision,run_id,state,question,expires_at,live_epoch FROM questions WHERE run_id=? AND EXISTS(SELECT 1 FROM runs r JOIN threads t ON t.id=r.thread_id WHERE r.id=questions.run_id AND t.deleted=0) AND rowid>? ORDER BY rowid LIMIT ?";
                values[0] = .{ .text = v.run.value };
                n = 1;
            },
            .content => |v| {
                if (v.start_byte > v.end_byte or v.end_byte > std.math.maxInt(i64) or v.end_byte - v.start_byte > page.max_bytes) return error.InvalidQuery;
                const s = try reader.prepare("SELECT revision,committed_bytes FROM blocks WHERE id=? AND EXISTS(SELECT 1 FROM messages m JOIN threads t ON t.id=m.thread_id WHERE m.id=blocks.message_id AND t.deleted=0)", &.{.{ .text = v.block.value }});
                defer s.deinit();
                if (!try s.step()) return error.NotFound;
                const committed = try number(s, 1);
                if (v.start_byte > committed) return error.InvalidQuery;
                const end = @min(v.end_byte, committed);
                const bytes = try allocator.alloc(u8, @intCast(end - v.start_byte));
                const chunks = try reader.prepare("SELECT rowid,byte_offset,length(bytes) FROM chunks WHERE block_id=? AND byte_offset>=coalesce((SELECT byte_offset FROM chunks WHERE block_id=? AND byte_offset<=? ORDER BY byte_offset DESC LIMIT 1),?) AND byte_offset<? AND byte_offset+length(bytes)>? ORDER BY byte_offset", &.{ .{ .text = v.block.value }, .{ .text = v.block.value }, .{ .integer = @intCast(v.start_byte) }, .{ .integer = @intCast(v.start_byte) }, .{ .integer = @intCast(end) }, .{ .integer = @intCast(v.start_byte) } });
                defer chunks.deinit();
                var copied: usize = 0;
                while (try chunks.step()) {
                    const start = try number(chunks, 1);
                    const length = try number(chunks, 2);
                    const low = @max(start, v.start_byte);
                    const high = @min(start + length, end);
                    var blob: ?*store.c.sqlite3_blob = null;
                    try store.check(store.c.sqlite3_blob_open(reader.database, "main", "chunks", "bytes", chunks.integer(0), 0, &blob));
                    defer _ = store.c.sqlite3_blob_close(blob);
                    const actual = store.c.sqlite3_blob_bytes(blob);
                    if (actual < 0 or @as(u64, @intCast(actual)) != length) return error.Corrupt;
                    try store.check(store.c.sqlite3_blob_read(blob, bytes[@intCast(low - v.start_byte)..].ptr, @intCast(high - low), @intCast(low - start)));
                    copied += @intCast(high - low);
                }
                if (copied != bytes.len) return error.Corrupt;
                rows[0] = .{ .content = .{ .block_id = v.block, .revision = try number(s, 0), .start_byte = v.start_byte, .end_byte = end, .next_byte = if (end < committed) end else null, .bytes = bytes } };
                result.items = rows[0..1];
                return result;
            },
        }
        if (q != .messages and q != .threads and q != .thread_sidebar_next) {
            values[n] = .{ .integer = @intCast(cursor) };
            n += 1;
        }
        if (q != .thread_sidebar_next) {
            values[n] = .{ .integer = @as(i64, page.limit) + 1 };
            n += 1;
        }
        const statement = try reader.prepare(sql, values[0..n]);
        defer statement.deinit();
        var last_key: u64 = cursor;
        var last_cursor: Cursor = .{ .query = identity, .key = cursor, .order_pin = order_pin, .order_sort = order_sort, .order_id = order_id };
        var encode_buffer: [131072]u8 = undefined;
        while (try statement.step()) {
            if (count == page.limit) {
                result.next_cursor = if (q == .threads and q.threads.sidebar_order)
                    try Owner.encoded(allocator, last_cursor)
                else
                    try Owner.encoded(allocator, .{ .query = identity, .key = last_key });
                break;
            }
            const s = statement;
            const row: t.Row = switch (q) {
                .projects => .{ .project = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .display_name = try text(allocator, s, 3) } },
                .workspaces => .{ .workspace = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .project = .{ .value = try text(allocator, s, 3) }, .binding = try t.decode(t.WorkspaceBinding, try s.bytes(4), allocator) } },
                .threads, .thread, .thread_sidebar_next => blk: {
                    const explicit_title = try allocator.dupe(u8, @import("text/utf8.zig").prefix(try s.bytes(12), t.max_title_bytes));
                    const prompt_preview = @import("text/utf8.zig").prefix(try s.bytes(7), t.max_title_bytes);
                    break :blk .{ .thread = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .project = .{ .value = try text(allocator, s, 3) }, .workspace = .{ .value = try text(allocator, s, 4) }, .session = if (s.isNull(5)) null else .{ .value = try text(allocator, s, 5) }, .selection = if (s.isNull(6)) null else try t.decode(a.Selection, try s.bytes(6), allocator), .title_preview = if (explicit_title.len != 0) explicit_title else try allocator.dupe(u8, prompt_preview), .title = explicit_title, .latest_run_state = if (s.isNull(8)) null else try enumeration(t.RunState, s, 8), .project_name = try text(allocator, s, 9), .workspace_root = try text(allocator, s, 10), .workspace_branch = try text(allocator, s, 11), .pinned = s.integer(13) != 0, .settled = s.integer(14) != 0, .snoozed_until = s.integer(15), .sort_order = s.integer(16), .created_at_ms = s.integer(17), .last_user_message_at_ms = s.integer(18), .updated_at_ms = s.integer(19), .can_snooze = s.integer(20) != 0, .archived = s.integer(21) != 0 } };
                },
                .blocks => .{ .block = try descriptor(allocator, s) },
                .attachments => .{ .attachment = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .thread = .{ .value = try text(allocator, s, 3) }, .name = try text(allocator, s, 4), .media_type = try text(allocator, s, 5), .byte_length = try number(s, 6), .digest = try text(allocator, s, 7), .kind = try enumeration(a.AttachmentKind, s, 8) } },
                .messages => blk: {
                    const message_id = a.MessageId{ .value = try text(allocator, s, 1) };
                    // One descriptor keeps nested work bounded; continuation uses
                    // the same snapshot and the explicit blocks query.
                    const blocks = try reader.prepare("SELECT ordinal+1,id,revision,ordinal,kind,committed_bytes,tool_id FROM blocks WHERE message_id=? ORDER BY ordinal LIMIT 2", &.{.{ .text = message_id.value }});
                    defer blocks.deinit();
                    var descriptors: []t.BlockDescriptor = &.{};
                    var next: ?[]const u8 = null;
                    if (try blocks.step()) {
                        descriptors = try allocator.alloc(t.BlockDescriptor, 1);
                        descriptors[0] = try descriptor(allocator, blocks);
                        const key = try number(blocks, 0);
                        if (try blocks.step()) {
                            const block_query: t.Query = .{ .blocks = .{ .message = message_id } };
                            next = try Owner.encoded(allocator, .{ .query = try t.encode(block_query, try allocator.alloc(u8, 2048)), .key = key });
                        }
                    }
                    break :blk .{ .message = .{ .message_id = message_id, .revision = try number(s, 2), .ordinal = try number(s, 3), .role = try enumeration(@FieldType(@FieldType(t.Row, "message"), "role"), s, 4), .incomplete = s.integer(5) != 0, .run_id = .{ .value = try text(allocator, s, 6) }, .blocks = descriptors, .next_block_cursor = next } };
                },
                .runs => .{ .run = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .thread = .{ .value = try text(allocator, s, 3) }, .session = .{ .value = try text(allocator, s, 4) }, .state = try enumeration(t.RunState, s, 5), .requested = try t.decode(a.Selection, try s.bytes(6), allocator), .effective = if (s.isNull(7)) null else try t.decode(a.Selection, try s.bytes(7), allocator), .diagnostic = try text(allocator, s, 8) } },
                .effects => .{ .effect = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .kind = try enumeration(t.EffectKind, s, 4), .state = try enumeration(t.EffectState, s, 5), .outcome = try text(allocator, s, 6) } },
                .tools => .{ .tool = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .name = try text(allocator, s, 4), .action_digest = try text(allocator, s, 5), .outcome = try enumeration(t.ToolOutcome, s, 6), .result_block = if (s.isNull(7)) null else .{ .value = try text(allocator, s, 7) } } },
                .task_list, .task_wait => .{ .task = .{
                    .task = .{
                        .id = .{ .value = try text(allocator, s, 1) },
                        .parent = .{ .value = try text(allocator, s, 2) },
                        .packet = try t.decode(t.orchestration.Packet, try s.bytes(3), allocator),
                        .requests = @intCast(try number(s, 4)),
                        .input_tokens = try number(s, 5),
                        .output_tokens = try number(s, 6),
                        .cached_tokens = try number(s, 7),
                        .result = if (s.isNull(8)) null else try t.decode(t.orchestration.Result, try s.bytes(8), allocator),
                        .review = if (s.isNull(9)) null else try enumeration(t.orchestration.Disposition, s, 9),
                    },
                    .state = try enumeration(t.RunState, s, 10),
                    .revision = try number(s, 11),
                } },
                .approvals => .{ .approval = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .state = try enumeration(t.ApprovalState, s, 4), .evidence = .{ .correlation = .{ .session = .{ .value = try text(allocator, s, 5) }, .run = .{ .value = try text(allocator, s, 3) }, .tool = .{ .value = try text(allocator, s, 6) }, .approval = .{ .value = try text(allocator, s, 1) }, .upstream_request = try text(allocator, s, 8) }, .workspace = .{ .value = try text(allocator, s, 7) }, .action_digest = try text(allocator, s, 9), .scope = try text(allocator, s, 10), .expires_at = if (s.isNull(11)) null else try number(s, 11) }, .live = !s.isNull(12) and std.mem.eql(u8, try s.bytes(12), &self.epoch) } },
                .questions => .{ .question = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .state = try enumeration(t.QuestionState, s, 4), .question = try t.decode(a.Question, try s.bytes(5), allocator), .live = !s.isNull(7) and std.mem.eql(u8, try s.bytes(7), &self.epoch) } },
                else => unreachable,
            };
            const row_bytes = (try t.encode(row, &encode_buffer)).len;
            if (row_bytes > page.max_bytes - bytes_used) {
                if (count == 0) return error.Limit;
                result.next_cursor = if (q == .threads and q.threads.sidebar_order)
                    try Owner.encoded(allocator, last_cursor)
                else
                    try Owner.encoded(allocator, .{ .query = identity, .key = last_key });
                break;
            }
            rows[count] = row;
            count += 1;
            bytes_used += row_bytes;
            last_key = try number(s, 0);
            last_cursor.key = last_key;
            if (q == .threads and q.threads.sidebar_order) {
                last_cursor.order_pin = -s.integer(13);
                last_cursor.order_sort = s.integer(16);
                last_cursor.order_id = row.thread.id.value;
            }
        }
        result.items = rows[0..count];
        if (q == .thread and count == 0) return error.NotFound;
        return result;
    }
    fn deliverSubscriptions(self: *Host, allocator: std.mem.Allocator) !void {
        const position = try self.database.position();
        for (self.subscriptions[0..self.options.limits.subscription_slots], 0..) |*sub, i| {
            if (!sub.active or sub.after.order(position) != .lt) continue;
            const id_value: t.SubscriptionId = .{ .slot = @intCast(i), .generation = sub.generation };
            const s = try self.database.prepare("SELECT sequence,event_index,event_id,aggregate,revision,kind,command_id,effect_id,payload FROM events WHERE (sequence,event_index)>(?,?) ORDER BY sequence,event_index LIMIT ?", &.{ .{ .integer = @intCast(sub.after.commit_sequence) }, .{ .integer = sub.after.event_index }, .{ .integer = @intCast(self.options.limits.subscriber_lag_events +| 1) } });
            defer s.deinit();
            var events: [128]t.Event = undefined;
            var count: usize = 0;
            var scanned: usize = 0;
            var bytes: usize = 0;
            var overflow = false;
            var buffer: [131072]u8 = undefined;
            while (try s.step()) {
                scanned += 1;
                if (scanned > self.options.limits.subscriber_lag_events) {
                    overflow = true;
                    break;
                }
                const event_value: t.Event = .{ .position = .{ .commit_sequence = try number(s, 0), .event_index = @intCast(try number(s, 1)) }, .event_id = .{ .value = try text(allocator, s, 2) }, .aggregate = try t.decode(t.AggregateRef, try s.bytes(3), allocator), .aggregate_revision = try number(s, 4), .kind = try text(allocator, s, 5), .causation_command_id = if (s.isNull(6)) null else .{ .value = try text(allocator, s, 6) }, .effect_id = if (s.isNull(7)) null else .{ .value = try text(allocator, s, 7) }, .payload = try text(allocator, s, 8) };
                // A scoped subscriber receives invalidations, never misses a
                // cross-aggregate content/tool event belonging to its scope.
                const matches = switch (sub.scope) {
                    .all => true,
                    .thread => |thread_id| try self.belongs(event_value.aggregate, thread_id.value, null),
                    .run => |run_id| try self.belongs(event_value.aggregate, null, run_id.value),
                };
                if (matches) {
                    const size = (try t.encode(event_value, &buffer)).len;
                    if (count == events.len or size > sub.max_bytes - bytes) {
                        overflow = true;
                        break;
                    }
                    events[count] = event_value;
                    count += 1;
                    bytes += size;
                }
            }
            if (overflow) {
                sub.active = false;
                try self.publish(.{ .resync_required = .{ .id = id_value } });
            } else {
                sub.after = position;
                if (count != 0) try self.publish(.{ .event_batch = .{ .id = id_value, .events = events[0..count], .end_position = position } });
            }
        }
    }
    fn belongs(self: *Host, aggregate: t.AggregateRef, thread_id: ?[]const u8, run_id: ?[]const u8) !bool {
        const sql: [:0]const u8, const key: []const u8 = switch (aggregate) {
            .run => |v| .{ "SELECT thread_id,id FROM runs WHERE id=?", v.value },
            .thread => |v| return thread_id != null and std.mem.eql(u8, thread_id.?, v.value),
            .message => |v| .{ "SELECT thread_id,run_id FROM messages WHERE id=?", v.value },
            .block => |v| .{ "SELECT m.thread_id,m.run_id FROM blocks b JOIN messages m ON m.id=b.message_id WHERE b.id=?", v.value },
            .tool => |v| .{ "SELECT r.thread_id,r.id FROM tools t JOIN runs r ON r.id=t.run_id WHERE t.id=?", v.value },
            .approval => |v| .{ "SELECT r.thread_id,r.id FROM approvals a JOIN runs r ON r.id=a.run_id WHERE a.id=?", v.value },
            .effect => |v| .{ "SELECT r.thread_id,r.id FROM effects e JOIN runs r ON r.id=e.run_id WHERE e.id=?", v.value },
            .followup, .attachment => return error.NotFound,
            .question => |v| .{ "SELECT run_id,id FROM questions WHERE id=?", v.value },
            .session => |v| .{ "SELECT thread_id,id FROM runs WHERE session_id=?", v.value },
            else => return false,
        };
        const s = try self.database.prepare(sql, &.{.{ .text = key }});
        defer s.deinit();
        if (!try s.step()) return false;
        return if (thread_id) |id_value| std.mem.eql(u8, id_value, try s.bytes(0)) else std.mem.eql(u8, run_id.?, try s.bytes(1));
    }
};

test {
    _ = types;
    _ = @import("domain/domain_test.zig");
    _ = @import("domain/factory_test.zig");
}

test "provider start preflight admits the complete UTF8 composer capacity" {
    try std.testing.expectEqual(@as(usize, 65536), startPreflight(0).max_prompt_bytes);
    for ([_][]const u8{ "x" ** 65536, ("x" ** 65533) ++ "€", ("x" ** 65532) ++ "😀", "\x01" ** 65536 }) |prompt| {
        try std.testing.expect(startPreflight(prompt.len).fits());
    }
    try std.testing.expect(!startPreflight(65537).fits());
    try std.testing.expect(!startPreflight(std.math.maxInt(usize)).fits());
}

test "structured question is durable, answerable and dispatchable" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var database = try store.Store.open(std.testing.io, path_buffer[0..path_len]);
    defer database.close() catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: Owner = .{ .database = &database, .io = std.testing.io, .epoch = "question-fixture", .utc_ms = 1000 };
    const project = (try owner.command(allocator, .{ .command_id = .{ .value = "question-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "Question fixture" } } })).entity_ids.project.?;
    const workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "question-workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try workspace_binding.capture(allocator, std.testing.io, path_buffer[0..path_len]) } } })).entity_ids.workspace.?;
    const thread = (try owner.command(allocator, .{ .command_id = .{ .value = "question-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    const sent = try owner.command(allocator, .{ .command_id = .{ .value = "question-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "configure it", .selection = a.fakeSelection(workspace) } } });
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "question-instance" }, .upstream = .{ .value = "question-session" } } });
    const start = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
    var correlation = start.request.start.correlation;
    correlation.question = .{ .value = "question-1" };
    const question: a.Question = .{ .id = correlation.question.?, .correlation = correlation, .prompt = "Which mode?", .choices = &.{ .{ .id = "safe", .label = "Safe" }, .{ .id = "fast", .label = "Fast" } } };
    try owner.observe(allocator, .{ .correlation = correlation, .upstream_event = "question", .body = .{ .question = question } });
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM questions WHERE state='pending'"));
    {
        const run_state = try database.prepare("SELECT state FROM runs WHERE id=?", &.{.{ .text = sent.entity_ids.run.?.value }});
        defer run_state.deinit();
        try std.testing.expect(try run_state.step());
        try std.testing.expectEqualStrings("awaiting_question", try run_state.bytes(0));
    }
    const answered = try owner.command(allocator, .{ .command_id = .{ .value = "question-answer" }, .target = .{ .question = question.id }, .expected_revision = .{ .revision = 1 }, .payload = .{ .question_answer = .{ .question = question.id, .answer = .{ .choice_ids = &.{"safe"} } } } });
    try std.testing.expectEqual(.accepted, answered.outcome);
    const reply = (try owner.claimNext(allocator)).?;
    try std.testing.expect(reply.request == .answer_question);
    try std.testing.expectEqualStrings("question-1", reply.request.answer_question.question.value);
    try owner.delivered(allocator, reply.id, .{ .outcome = .acknowledged });
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM questions WHERE state='resolved'"));
    {
        const run_state = try database.prepare("SELECT state FROM runs WHERE id=?", &.{.{ .text = sent.entity_ids.run.?.value }});
        defer run_state.deinit();
        try std.testing.expect(try run_state.step());
        try std.testing.expectEqualStrings("streaming", try run_state.bytes(0));
    }
}

test "session-only open rejection closes starting claim and preserves indexed run diagnostics on reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    var database = try store.Store.open(std.testing.io, path);
    var database_live = true;
    defer if (database_live) database.close() catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: Owner = .{ .database = &database, .io = std.testing.io, .epoch = "rejection-fixture", .utc_ms = 1 };
    const project = (try owner.command(allocator, .{ .command_id = .{ .value = "project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "RPC rejection fixture" } } })).entity_ids.project.?;
    const workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try workspace_binding.capture(allocator, std.testing.io, path) } } })).entity_ids.workspace.?;
    const thread = (try owner.command(allocator, .{ .command_id = .{ .value = "thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    owner.factory = @import("domain/fake_factory.zig").factory(&owner);
    const sent = try owner.command(allocator, .{ .command_id = .{ .value = "send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "no external inference", .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.accepted, sent.outcome);
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged });
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM runs WHERE state='starting'"));
    var failure: a.Observation = .{ .correlation = .{ .session = sent.entity_ids.session.?, .effect = open.id }, .upstream_event = "rejected-open", .body = .{ .failure = .{ .code = "rpc_error", .detail = "dynamic tool name rejected" } } };
    try owner.observe(allocator, failure);
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM runs WHERE state='failed'"));
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM effects WHERE kind='create_session' AND state='failed'"));
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM effects WHERE kind='start' AND state='withdrawn'"));
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    // Explicit mismatched run/session authority cannot overwrite diagnostics.
    failure.upstream_event = "stale-run";
    failure.correlation.run = .{ .value = "another-run" };
    try std.testing.expectError(error.Conflict, owner.observe(allocator, failure));
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM observations WHERE evidence IS NOT NULL"));
    // No upstream session was ever published. Continuing this transcript must
    // not silently create a new provider context and omit its first prompt.
    const retry = try owner.command(allocator, .{ .command_id = .{ .value = "second-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "second run", .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.rejected, retry.outcome);
    try std.testing.expectEqual(t.Reason.session_unavailable, retry.reason.?);
    try std.testing.expect((try owner.claimNext(allocator)) == null);
    const second_thread = (try owner.command(allocator, .{ .command_id = .{ .value = "second-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    const second = try owner.command(allocator, .{ .command_id = .{ .value = "new-thread-send" }, .target = .{ .thread = second_thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "second run", .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.accepted, second.outcome);
    try std.testing.expect(!a.equal(sent.entity_ids.session.?, second.entity_ids.session.?));
    const second_open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, second_open.id, .{ .outcome = .acknowledged });
    failure.correlation.run = second.entity_ids.run;
    try std.testing.expectError(error.Conflict, owner.observe(allocator, failure));
    try owner.observe(allocator, .{ .correlation = .{ .session = second.entity_ids.session.? }, .upstream_event = "disconnected", .body = .{ .disconnect = .{ .reason = "second connection lost", .continuity = .unknown } } });
    try owner.observe(allocator, .{ .correlation = .{ .session = second.entity_ids.session.? }, .upstream_event = "ambiguous", .body = .{ .ambiguous = .{ .reason = "second run only" } } });
    const oversized = [_]u8{'x'} ** 4096;
    try std.testing.expectError(error.Limit, owner.observe(allocator, .{ .correlation = .{ .session = second.entity_ids.session.? }, .upstream_event = "oversized-diagnostic", .body = .{ .ambiguous = .{ .reason = &oversized } } }));
    try std.testing.expectEqual(@as(i64, 3), try database.scalar("SELECT count(*) FROM observations WHERE evidence IS NOT NULL"));
    const plan = try database.prepare("EXPLAIN QUERY PLAN SELECT evidence FROM observations WHERE session_id=? AND json_extract(CAST(correlation AS TEXT),'$.run.value')=? AND evidence IS NOT NULL ORDER BY commit_sequence DESC LIMIT 1", &.{ .{ .text = sent.entity_ids.session.?.value }, .{ .text = sent.entity_ids.run.?.value } });
    {
        defer plan.deinit();
        try std.testing.expect(try plan.step());
        try std.testing.expect(std.mem.indexOf(u8, try plan.bytes(3), "observation_diagnostics") != null);
    }
    try database.close();
    database_live = false;
    const host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path });
    defer host.destroy();
    const backing = try allocator.alloc(u8, 262144);
    for ([_]t.ThreadId{ thread, second_thread }, 0..) |query_thread, index| {
        const ticket = try host.query(.{ .runs = .{ .thread = query_thread } });
        var received = false;
        for (0..2000) |_| {
            var output: [1]t.Output = undefined;
            const drained = host.drain(&output, backing);
            if (drained.output_count == 0) {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                continue;
            }
            try std.testing.expect(output[0] == .query_page);
            try std.testing.expectEqual(ticket, output[0].query_page.ticket);
            try std.testing.expectEqual(@as(usize, 1), output[0].query_page.page.items.len);
            const row = output[0].query_page.page.items[0].run;
            try std.testing.expectEqual(if (index == 0) t.RunState.failed else t.RunState.unknown, row.state);
            const expected = if (index == 0) "dynamic tool name rejected" else "second run only";
            const unrelated = if (index == 0) "second run only" else "dynamic tool name rejected";
            try std.testing.expect(std.mem.indexOf(u8, row.diagnostic, expected) != null);
            try std.testing.expect(std.mem.indexOf(u8, row.diagnostic, unrelated) == null);
            received = true;
            break;
        }
        try std.testing.expect(received);
    }
}

test "fake send admission matches the shared start-frame preflight at UTF-8 boundaries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    var database = try store.Store.open(std.testing.io, path);
    defer database.close() catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: Owner = .{ .database = &database, .io = std.testing.io, .epoch = "send-frame-boundary", .utc_ms = 1 };
    const project = (try owner.command(allocator, .{ .command_id = .{ .value = "project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "Frame boundary fixture" } } })).entity_ids.project.?;
    const workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try workspace_binding.capture(allocator, std.testing.io, path) } } })).entity_ids.workspace.?;
    const prompt_cases = [_][]const u8{ "x" ** 65536, "x" ** 65537, ("x" ** 65533) ++ "€", ("x" ** 65534) ++ "€", ("x" ** 65532) ++ "😀", ("x" ** 65533) ++ "😀" };
    for (prompt_cases, 0..) |prompt, index| {
        const thread_command = try std.fmt.allocPrint(allocator, "thread-{d}", .{index});
        const thread = (try owner.command(allocator, .{ .command_id = .{ .value = thread_command }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
        const before = try database.scalar("SELECT count(*) FROM effects");
        const command: t.CommandEnvelope = .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "send-{d}", .{index}) }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = prompt, .selection = a.fakeSelection(workspace) } } };
        var proposed = command;
        if (index % 2 != 0) proposed.payload = .{ .thread_send_staged = .{ .prompt = prompts.reference(command.command_id.value, prompt), .selection = a.fakeSelection(workspace) } };
        const receipt = try owner.command(allocator, proposed);
        if (index % 2 == 0) {
            try std.testing.expectEqual(.accepted, receipt.outcome);
            const stored = (try owner.field(allocator, "SELECT request FROM effects WHERE run_id=? AND kind='start'", &.{.{ .text = receipt.entity_ids.run.?.value }})).?;
            const request = try t.decode(a.Request, stored, allocator);
            try std.testing.expect(a.frameBytes(request) <= start_frame_limit);
            try std.testing.expectEqualStrings("", request.start.prompt);
            const ref = request.start.prompt_ref.?;
            var materialized: [prompts.max_bytes]u8 = undefined;
            try std.testing.expectEqualStrings(prompt, try prompts.readBlock(&database, ref.id, ref, &materialized));
            try std.testing.expectEqual(before + 2, try database.scalar("SELECT count(*) FROM effects"));
        } else {
            try std.testing.expectEqual(.rejected, receipt.outcome);
            try std.testing.expectEqual(t.Reason.invalid_command, receipt.reason.?);
            try std.testing.expectEqual(before, try database.scalar("SELECT count(*) FROM effects"));
        }
        // Even rejected oversized Sends retain their original durable receipt.
        const replay = try owner.command(allocator, proposed);
        try std.testing.expectEqual(receipt.commit_sequence, replay.commit_sequence);
        try std.testing.expectEqual(receipt.outcome, replay.outcome);
    }
}

test "sidebar ordering pages beyond resident capacity with composite snapshot cursors" {
    const Harness = struct {
        fn query(host: *Host, allocator: std.mem.Allocator, request: t.Query) !t.Output {
            const ticket = try host.query(request);
            const backing = try allocator.alloc(u8, 262144);
            for (0..4000) |_| {
                var output: [1]t.Output = undefined;
                const drained = host.drain(&output, backing);
                if (drained.output_count == 0) {
                    try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                    continue;
                }
                switch (output[0]) {
                    .query_page => |page_value| if (page_value.ticket.value == ticket.value) return common.clone(allocator, output[0]),
                    .failure => |failure| if (failure.ticket.value == ticket.value) return common.clone(allocator, output[0]),
                    else => {},
                }
            }
            return error.Timeout;
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(std.testing.io, &path_buffer)];
    var database = try store.Store.open(std.testing.io, path);
    var database_live = true;
    defer if (database_live) database.close() catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try database.exec("INSERT INTO projects VALUES('p',1,'Paging'); INSERT INTO workspaces VALUES('w',1,'p',X'7b2263616e6f6e6963616c5f726f6f74223a222f746d70222c2266696c6573797374656d5f6964656e74697479223a22222c227265706f7369746f72795f6964656e74697479223a22222c22636865636b6f75745f6964656e74697479223a22222c2265787065637465645f6272616e6368223a22222c22626173655f7265766973696f6e223a22222c226e6f6e5f676974223a747275657d')");
    for (0..70) |index| {
        const id_value = try std.fmt.allocPrint(allocator, "thread-{d:0>2}", .{index});
        try database.execute("INSERT INTO threads(id,revision,project_id,workspace_id,root_key,sort_order) VALUES(?,1,'p','w',X'e9671acd244849c57167c658fa2f969752048f7ab184a3dcf5c46cb4d56ae124',?)", &.{ .{ .text = id_value }, .{ .integer = -@as(i64, @intCast(index + 1)) * 1024 } });
    }
    var owner: Owner = .{ .database = &database, .io = std.testing.io, .epoch = "sidebar-pages", .utc_ms = 1000 };
    const pin = try owner.command(allocator, .{ .command_id = .{ .value = "paging-pin" }, .target = .{ .thread = .{ .value = "thread-00" } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_set = .{ .pinned = true } } });
    try std.testing.expectEqual(.accepted, pin.outcome);
    const move = try owner.command(allocator, .{ .command_id = .{ .value = "paging-move" }, .target = .{ .thread = .{ .value = "thread-01" } }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_sidebar_move = .{ .direction = .up } } });
    try std.testing.expectEqual(.accepted, move.outcome);
    try database.close();
    database_live = false;
    const host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path });
    defer host.destroy();
    var request: t.Query = .{ .threads = .{ .sidebar_order = true, .page = .{ .limit = 7, .max_bytes = 8192 } } };
    var seen: [70]bool = @splat(false);
    var count: usize = 0;
    var first_cursor: ?[]const u8 = null;
    var first_snapshot: ?t.SnapshotId = null;
    while (true) {
        const output = try Harness.query(host, allocator, request);
        try std.testing.expect(output == .query_page);
        const value = output.query_page.page;
        try std.testing.expect(value.items.len <= 7);
        if (count == 0) {
            try std.testing.expectEqualStrings("thread-00", value.items[0].thread.id.value);
            try std.testing.expect(value.items[0].thread.pinned);
            first_cursor = value.next_cursor;
            first_snapshot = value.snapshot_id;
        }
        for (value.items) |row| {
            const index = try std.fmt.parseInt(usize, row.thread.id.value[7..], 10);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            count += 1;
        }
        const next = value.next_cursor orelse break;
        request.threads.page.snapshot = value.snapshot_id;
        request.threads.page.cursor = next;
    }
    try std.testing.expectEqual(@as(usize, 70), count);
    for (seen) |found| try std.testing.expect(found);
    const invalid = try Harness.query(host, allocator, .{ .threads = .{ .page = .{ .limit = 7, .max_bytes = 8192, .snapshot = first_snapshot, .cursor = first_cursor } } });
    try std.testing.expect(invalid == .failure);
    try std.testing.expectEqual(.cursor_invalid, invalid.failure.failure.reason);
    const anchored = try Harness.query(host, allocator, .{ .threads = .{ .project = .{ .value = "p" }, .anchor = .{ .value = "thread-00" }, .sidebar_order = true, .page = .{ .limit = 7, .max_bytes = 8192 } } });
    try std.testing.expect(anchored == .query_page);
    try std.testing.expectEqualStrings("thread-69", anchored.query_page.page.items[0].thread.id.value);
    const expired = try Harness.query(host, allocator, .{ .threads = .{ .sidebar_order = true, .page = .{ .limit = 7, .max_bytes = 8192, .snapshot = .{ .slot = first_snapshot.?.slot, .generation = first_snapshot.?.generation + 1 }, .cursor = first_cursor } } });
    try std.testing.expect(expired == .failure);
    try std.testing.expectEqual(.cursor_invalid, expired.failure.failure.reason);
    const classic = try Harness.query(host, allocator, .{ .threads = .{ .page = .{ .limit = 7, .max_bytes = 8192 } } });
    try std.testing.expect(classic == .query_page);
    const classic_cursor = classic.query_page.page.next_cursor.?;
    try std.testing.expect(std.mem.indexOf(u8, classic_cursor, "order_pin") == null);
    try std.testing.expect(classic_cursor.len <= 256);
}

test "thread cards read bounded UTF8 first-prompt previews and latest status after reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    var database = try store.Store.open(std.testing.io, path);
    var database_live = true;
    defer if (database_live) database.close() catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: Owner = .{ .database = &database, .io = std.testing.io, .epoch = "thread-preview", .utc_ms = 1 };
    const project = (try owner.command(allocator, .{ .command_id = .{ .value = "project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "Card fixture" } } })).entity_ids.project.?;
    const workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try workspace_binding.capture(allocator, std.testing.io, path) } } })).entity_ids.workspace.?;
    const thread = (try owner.command(allocator, .{ .command_id = .{ .value = "thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    const prompt = [_]u8{'a'} ** 159 ++ "🎉\n" ++ [_]u8{'z'} ** 2400;
    const sent = try owner.command(allocator, .{ .command_id = .{ .value = "send-first" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = prompt, .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.accepted, sent.outcome);
    // Establish actual session evidence and resolve both effects before the
    // next turn. Merely changing the run state cannot establish continuity.
    const open = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, open.id, .{ .outcome = .acknowledged, .session = .{ .id = sent.entity_ids.session.?, .instance = .{ .value = "card-instance" }, .upstream = .{ .value = "card-session" } } });
    const start = (try owner.claimNext(allocator)).?;
    try owner.delivered(allocator, start.id, .{ .outcome = .acknowledged });
    try owner.observe(allocator, .{ .correlation = start.request.start.correlation, .upstream_event = "card-completed", .body = .completed });
    const second = try owner.command(allocator, .{ .command_id = .{ .value = "send-again" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "A later prompt must not replace the title", .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.accepted, second.outcome);
    _ = try owner.command(allocator, .{ .command_id = .{ .value = "empty-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } });
    const other_project = (try owner.command(allocator, .{ .command_id = .{ .value = "other-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "Other café" } } })).entity_ids.project.?;
    const other_workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "other-workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = other_project, .binding = try workspace_binding.capture(allocator, std.testing.io, path) } } })).entity_ids.workspace.?;
    const other_thread = (try owner.command(allocator, .{ .command_id = .{ .value = "other-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = other_project, .workspace = other_workspace } } })).entity_ids.thread.?;
    const plan = try database.prepare("EXPLAIN QUERY PLAN SELECT state FROM runs WHERE thread_id=? ORDER BY rowid DESC LIMIT 1", &.{.{ .text = thread.value }});
    {
        defer plan.deinit();
        try std.testing.expect(try plan.step());
        try std.testing.expect(std.mem.indexOf(u8, try plan.bytes(3), "runs_by_thread") != null);
    }
    try database.close();
    database_live = false;
    const host = try Host.create(std.testing.allocator, std.testing.io, .{ .state_directory = path });
    defer host.destroy();
    const backing = try allocator.alloc(u8, 262144);
    for ([_]t.Query{ .{ .thread = thread }, .{ .threads = .{ .project = project } }, .{ .threads = .{} } }) |query| {
        const ticket = try host.query(query);
        var received = false;
        for (0..2000) |_| {
            var output: [1]t.Output = undefined;
            const drained = host.drain(&output, backing);
            if (drained.output_count == 0) {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
                continue;
            }
            try std.testing.expect(output[0] == .query_page);
            try std.testing.expectEqual(ticket, output[0].query_page.ticket);
            const rows = output[0].query_page.page.items;
            try std.testing.expectEqual(@as(usize, if (query == .thread) 1 else if (query.threads.project == null) 3 else 2), rows.len);
            try std.testing.expectEqualStrings(prompt[0..159], rows[0].thread.title_preview);
            try std.testing.expect(std.unicode.utf8ValidateSlice(rows[0].thread.title_preview));
            try std.testing.expectEqual(t.RunState.interrupted, rows[0].thread.latest_run_state.?);
            try std.testing.expectEqualStrings("Card fixture", rows[0].thread.project_name);
            try std.testing.expectEqualStrings(path, rows[0].thread.workspace_root);
            if (rows.len >= 2) {
                try std.testing.expectEqualStrings("", rows[1].thread.title_preview);
                try std.testing.expect(rows[1].thread.latest_run_state == null);
            }
            if (rows.len == 3) {
                try std.testing.expectEqualStrings(other_thread.value, rows[2].thread.id.value);
                try std.testing.expectEqualStrings(other_project.value, rows[2].thread.project.value);
                try std.testing.expectEqualStrings("Other café", rows[2].thread.project_name);
                try std.testing.expectEqualStrings(path, rows[2].thread.workspace_root);
            }
            received = true;
            break;
        }
        try std.testing.expect(received);
    }
}

test "reopened uncertain runs do not block setup or replay claimed work" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(std.testing.io, &path_buffer)];
    var database = try store.Store.open(std.testing.io, path);
    defer database.close() catch {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var owner: Owner = .{ .database = &database, .io = std.testing.io, .epoch = "busy-before", .utc_ms = 1 };
    const project = (try owner.command(allocator, .{ .command_id = .{ .value = "project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "Busy recovery" } } })).entity_ids.project.?;
    const workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try workspace_binding.capture(allocator, std.testing.io, path) } } })).entity_ids.workspace.?;
    owner.factory = @import("domain/fake_factory.zig").factory(&owner);
    owner.setup_factory = owner.factory;
    const actions = [_]t.Payload{
        .{ .runtime_configure = .{ .runtime_kind = .codex, .executable = "/fixture/codex", .account_directory = "/fixture/account", .workspace_root = path, .model_provider = "openai" } },
        .{ .runtime_refresh = {} },
        .{ .runtime_login = .{ .runtime_kind = .codex, .mode = .device } },
    };
    const thread = (try owner.command(allocator, .{ .command_id = .{ .value = "thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    const sent = try owner.command(allocator, .{ .command_id = .{ .value = "send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "Offline uncertainty fixture", .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.accepted, sent.outcome);
    // Accepted but not-yet-spawned work owns the configuration as well.
    for (actions, 0..) |payload, i| {
        const receipt = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "queued-{d}", .{i}) }, .target = .absent, .expected_revision = .absent, .payload = payload });
        try std.testing.expectEqual(.busy, receipt.reason.?);
    }
    _ = (try owner.claimNext(allocator)).?;
    try database.close();
    database = try store.Store.open(std.testing.io, path);
    owner.epoch = "busy-after";
    try owner.recover();
    const run_revisions = try database.scalar("SELECT sum(revision) FROM runs");
    const effect_revisions = try database.scalar("SELECT sum(revision) FROM effects");
    const events = try database.scalar("SELECT count(*) FROM events");
    // All three actions are admitted after real recovery. Exact redelivery
    // returns the original receipt and cannot grant a second setup side effect.
    for (actions, 0..) |payload, i| {
        const command: t.CommandEnvelope = .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "recovered-{d}", .{i}) }, .target = .absent, .expected_revision = .absent, .payload = payload };
        const receipt = try owner.command(allocator, command);
        try std.testing.expectEqual(.accepted, receipt.outcome);
        try std.testing.expectEqual(receipt.commit_sequence, (try owner.command(allocator, command)).commit_sequence);
        try std.testing.expect((try owner.claimNext(allocator)) == null);
    }
    try std.testing.expectEqual(run_revisions, try database.scalar("SELECT sum(revision) FROM runs"));
    try std.testing.expectEqual(effect_revisions, try database.scalar("SELECT sum(revision) FROM effects"));
    try std.testing.expectEqual(events, try database.scalar("SELECT count(*) FROM events"));
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM runs WHERE state='unknown'"));
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM effects WHERE state='unknown' AND outcome='crash_after_claim'"));
    const retry = try owner.command(allocator, .{ .command_id = .{ .value = "unsafe-retry" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "Must not replay", .selection = a.fakeSelection(workspace) } } });
    try std.testing.expectEqual(.unresolved_effects, retry.reason.?);
    // In-flight authority still blocks setup even when the run is unknown.
    try database.exec("UPDATE effects SET state='in_flight' WHERE kind='create_session'");
    const blocked = try owner.command(allocator, .{ .command_id = .{ .value = "still-in-flight" }, .target = .absent, .expected_revision = .absent, .payload = actions[1] });
    try std.testing.expectEqual(.busy, blocked.reason.?);
    try database.exec("UPDATE effects SET state='unknown' WHERE kind='create_session'");
    // A live adapter is independently authoritative. This sentinel entry is
    // inspected only for occupancy; no adapter or arena method may be called.
    var registry: Registry = .{ .allocator = std.testing.allocator, .factory = owner.factory.? };
    registry.entries[0] = .{ .arena = undefined, .session = sent.entity_ids.session.?, .selection = a.fakeSelection(workspace), .adapter = undefined, .pending_open = null, .created_ms = 0 };
    owner.runtime_registry = &registry;
    for (actions, 0..) |payload, i| {
        const receipt = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "owned-{d}", .{i}) }, .target = .absent, .expected_revision = .absent, .payload = payload });
        try std.testing.expectEqual(.busy, receipt.reason.?);
    }
    registry.entries[0] = null;
    // Recovered runs do not use the three live execution slots. Recovery of
    // unclaimed work must remain interrupted, with its calls still unclaimed.
    for (0..4) |i| {
        const next = (try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "thread-{d}", .{i}) }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
        const run = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "send-{d}", .{i}) }, .target = .{ .thread = next }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "New isolated chat", .selection = a.fakeSelection(workspace) } } });
        try std.testing.expectEqual(.accepted, run.outcome);
        try owner.recover();
        for (actions, 0..) |payload, j| {
            const receipt = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "interrupted-{d}-{d}", .{ i, j }) }, .target = .absent, .expected_revision = .absent, .payload = payload });
            try std.testing.expectEqual(.accepted, receipt.outcome);
        }
        try std.testing.expect((try owner.claimNext(allocator)) == null);
    }
    try std.testing.expectEqual(@as(i64, 4), try database.scalar("SELECT count(*) FROM runs WHERE state='interrupted'"));
    try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM runs WHERE state='unknown'"));
    for (0..4) |i| {
        const next = (try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "live-thread-{d}", .{i}) }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
        const run = try owner.command(allocator, .{ .command_id = .{ .value = try std.fmt.allocPrint(allocator, "live-send-{d}", .{i}) }, .target = .{ .thread = next }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "Still bounded to three live runs", .selection = a.fakeSelection(workspace) } } });
        if (i < 3) try std.testing.expectEqual(.accepted, run.outcome) else try std.testing.expectEqual(.admission_limit, run.reason.?);
    }
}

const FollowupLifetimeProbe = struct {
    arena: std.heap.ArenaAllocator,
    session: a.RuntimeSessionId = .{ .value = "" },
    start: ?a.Correlation = null,
    next: ?a.Observation = null,
    message_outcome: @FieldType(a.Receipt, "outcome"),
    messages: usize = 0,
    starts: usize = 0,
    shutdowns: usize = 0,
    destroys: usize = 0,
    fn cast(context: *anyopaque) *FollowupLifetimeProbe {
        return @ptrCast(@alignCast(context));
    }
    fn discover(_: *anyopaque) a.Discovery {
        var capabilities = @import("runtime/fake.zig").defaultCapabilities();
        // Only this deterministic test fixture implements message refusal.
        capabilities[@intFromEnum(a.Capability.followup_queue)].status = .supported;
        return .{ .capabilities = capabilities, .limits = .{} };
    }
    fn account(_: *anyopaque) a.Account {
        return .{ .reference = "fixture", .readiness = .ready };
    }
    fn selection(_: *anyopaque, requested: a.Selection) a.SelectionResult {
        return .{ .requested = requested, .effective = requested, .readiness = .ready };
    }
    fn dispatch(context: *anyopaque, _: std.mem.Allocator, request: a.Request) !a.Receipt {
        const self = cast(context);
        switch (request) {
            .open => return .{ .outcome = .acknowledged, .session = .{ .id = self.session, .instance = .{ .value = "probe-instance" }, .upstream = .{ .value = "probe-session" } } },
            .start => |start| {
                self.starts += 1;
                self.start = try common.clone(self.arena.allocator(), start.correlation);
                self.next = .{ .correlation = self.start.?, .upstream_event = "before-followup", .body = .{ .chunk = .{ .message = .{ .value = "message" }, .block = .{ .value = "block" }, .offset = 0, .text = "before " } } };
                return .{ .outcome = .acknowledged };
            },
            .message => |message| {
                self.messages += 1;
                if (self.message_outcome == .acknowledged) self.next = .{ .correlation = try common.clone(self.arena.allocator(), message.correlation), .upstream_event = "request-refused", .body = .{ .request_failed = .{ .code = "busy", .detail = "followup refused asynchronously" } } };
                return .{ .outcome = self.message_outcome, .detail = "message delivery" };
            },
            else => return error.UnexpectedRequest,
        }
    }
    fn pump(_: *anyopaque) !void {}
    fn poll(context: *anyopaque, allocator: std.mem.Allocator) !?a.Observation {
        const self = cast(context);
        const next = self.next orelse return null;
        const copied = try common.clone(allocator, next);
        self.next = null;
        return copied;
    }
    fn shutdown(context: *anyopaque) void {
        cast(context).shutdowns += 1;
    }
    fn create(context: *anyopaque, _: std.mem.Allocator, _: a.Selection, _: []const u8, session: a.RuntimeSessionId, _: ?common.Bridge) !common.Adapter {
        const self = cast(context);
        self.session = try common.clone(self.arena.allocator(), session);
        return .{ .context = self, .vtable = &.{ .discover = discover, .accountStatus = account, .resolveSelection = selection, .dispatch = dispatch, .pump = pump, .poll = poll, .shutdown = shutdown } };
    }
    fn discoverFactory(context: *anyopaque, _: a.Selection) a.Discovery {
        return discover(context);
    }
    fn accountFactory(context: *anyopaque, _: a.Selection) a.Account {
        return account(context);
    }
    fn destroy(context: *anyopaque, _: std.mem.Allocator, _: common.Adapter) void {
        cast(context).destroys += 1;
    }
    fn factory(self: *FollowupLifetimeProbe) Factory {
        return .{ .context = self, .vtable = &.{ .discover = discoverFactory, .accountStatus = accountFactory, .resolveSelection = selection, .create = create, .destroy = destroy } };
    }
};

test "Host retains provider after followup delivery or refusal until original Start completes" {
    for ([_]@FieldType(a.Receipt, "outcome"){ .rejected, .acknowledged, .unknown }) |outcome| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = path_buffer[0..try temporary.dir.realPath(std.testing.io, &path_buffer)];
        var probe: FollowupLifetimeProbe = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .message_outcome = outcome };
        defer probe.arena.deinit();
        // Exercise the real dispatch/pump/release path synchronously. No worker
        // thread, timing sleeps or internal mutation of domain state is needed.
        const host = try std.testing.allocator.create(Host);
        defer std.testing.allocator.destroy(host);
        host.* = .{ .allocator = std.testing.allocator, .io = std.testing.io, .options = .{ .state_directory = path }, .database = try store.Store.open(std.testing.io, path), .path = undefined, .restore_arena = undefined };
        defer host.database.close() catch @panic("test host database close failed");
        host.mcp = try Mcp.init();
        defer host.mcp.?.deinit();
        host.registry = .{ .allocator = std.testing.allocator, .factory = probe.factory() };
        defer host.registry.?.deinit(&host.mcp.?);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var pump_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pump_arena.deinit();
        const allocator = arena.allocator();
        var owner: Owner = .{ .database = &host.database, .io = std.testing.io, .epoch = "host-followup", .utc_ms = 1000, .factory = probe.factory(), .runtime_registry = &host.registry.? };
        const project = (try owner.command(allocator, .{ .command_id = .{ .value = "project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "Followup lifetime" } } })).entity_ids.project.?;
        const workspace = (try owner.command(allocator, .{ .command_id = .{ .value = "workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try workspace_binding.capture(allocator, std.testing.io, path) } } })).entity_ids.workspace.?;
        const thread = (try owner.command(allocator, .{ .command_id = .{ .value = "thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
        const sent = try owner.command(allocator, .{ .command_id = .{ .value = "send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "original turn", .selection = a.fakeSelection(workspace) } } });
        try std.testing.expectEqual(.accepted, sent.outcome);
        try host.dispatch(&owner, allocator, (try owner.claimNext(allocator)).?);
        try host.pumpRuntimes(&owner, &pump_arena);
        const start = (try owner.claimNext(allocator)).?;
        try host.dispatch(&owner, allocator, start);
        try host.pumpRuntimes(&owner, &pump_arena);
        const queued = try owner.command(allocator, .{ .command_id = .{ .value = "followup" }, .target = .{ .run = sent.entity_ids.run.? }, .expected_revision = .{ .revision = @intCast(try host.database.scalar("SELECT revision FROM runs")) }, .payload = .{ .followup_enqueue = .{ .content = "queued request" } } });
        try std.testing.expectEqual(.accepted, queued.outcome);
        const message = (try owner.claimNext(allocator)).?;
        try host.dispatch(&owner, allocator, message);
        try host.pumpRuntimes(&owner, &pump_arena);
        try std.testing.expectEqual(@as(usize, 0), probe.shutdowns);
        try std.testing.expectEqual(@as(usize, 0), probe.destroys);
        try std.testing.expect(host.registry.?.find(sent.entity_ids.session.?) != null);
        try std.testing.expectEqual(@as(i64, 1), try host.database.scalar("SELECT count(*) FROM runs WHERE state='streaming'"));
        try std.testing.expect(a.equal(start.request.start.correlation, probe.start.?));
        probe.next = .{ .correlation = probe.start.?, .upstream_event = "after-followup", .body = .{ .chunk = .{ .message = .{ .value = "message" }, .block = .{ .value = "block" }, .offset = 7, .text = "世界" } } };
        try host.pumpRuntimes(&owner, &pump_arena);
        try std.testing.expectEqual(@as(i64, 13), try host.database.scalar("SELECT committed_bytes FROM blocks WHERE kind='text' AND message_id=(SELECT id FROM messages WHERE role='assistant')"));
        probe.next = .{ .correlation = probe.start.?, .upstream_event = "completed", .body = .completed };
        try host.pumpRuntimes(&owner, &pump_arena);
        try std.testing.expectEqual(@as(i64, 1), try host.database.scalar("SELECT count(*) FROM runs WHERE state='completed'"));
        try std.testing.expect(host.registry.?.find(sent.entity_ids.session.?) == null);
        try std.testing.expectEqual(@as(usize, 1), probe.shutdowns);
        try std.testing.expectEqual(@as(usize, 1), probe.destroys);
        try std.testing.expectEqual(@as(usize, 1), probe.starts);
        try std.testing.expectEqual(@as(usize, 1), probe.messages);
        try std.testing.expect((try owner.claimNext(allocator)) == null);
        try host.pumpRuntimes(&owner, &pump_arena);
        try std.testing.expectEqual(@as(usize, 1), probe.shutdowns);
    }
}
