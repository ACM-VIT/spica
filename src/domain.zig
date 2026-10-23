//! App-owned durable conversation boundary. No UI or adapter owns durable state.
const std = @import("std");
pub const types = @import("domain/types.zig");
pub const store = @import("domain/store.zig");
const t = types;
const a = t.adapter;
const V = store.Value;

/// Internal single-thread reducer. Every returned slice belongs to the operation
/// allocator; callers must copy before resetting it. Never call from the UI.
pub const Owner = struct {
    database: *store.Store,
    io: std.Io,
    epoch: []const u8,
    utc_ms: ?u64,

    fn id(self: *Owner, allocator: std.mem.Allocator) ![]const u8 {
        var random: [16]u8 = undefined;
        try self.io.randomSecure(&random);
        const result = try allocator.alloc(u8, 32);
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
    fn revision(self: *Owner, target: t.Target) !?u64 {
        const sql: [:0]const u8, const key: []const u8 = switch (target) {
            .absent => return null,
            .project => |v| .{ "SELECT revision FROM projects WHERE id=?", v.value },
            .workspace => |v| .{ "SELECT revision FROM workspaces WHERE id=?", v.value },
            .thread => |v| .{ "SELECT revision FROM threads WHERE id=?", v.value },
            .run => |v| .{ "SELECT revision FROM runs WHERE id=?", v.value },
            .approval => |v| .{ "SELECT revision FROM approvals WHERE id=?", v.value },
        };
        const statement = try self.database.prepare(sql, &.{.{ .text = key }});
        defer statement.deinit();
        return if (try statement.step()) @intCast(statement.integer(0)) else null;
    }
    fn event(self: *Owner, allocator: std.mem.Allocator, sequence: u64, index: u32, aggregate: t.AggregateRef, revision_value: u64, kind: []const u8, causation: ?t.CommandId, effect: ?a.EffectId, payload: []const u8) !void {
        try self.database.appendEvent(.{ .event_id = .{ .value = try self.id(allocator) }, .position = .{ .commit_sequence = sequence, .event_index = index }, .aggregate = aggregate, .aggregate_revision = revision_value, .kind = kind, .causation_command_id = causation, .effect_id = effect, .payload = payload });
    }
    fn plan(self: *Owner, allocator: std.mem.Allocator, effect: []const u8, run: []const u8, session: []const u8, kind: t.EffectKind, request: a.Request, dependency: ?[]const u8, approval: ?[]const u8, causation: t.CommandId) !void {
        const bytes = try encoded(allocator, request);
        const digest = t.digest(bytes);
        try self.database.execute("INSERT INTO effects(id,revision,run_id,session_id,kind,read_only,request,digest,state,depends_on,approval_id,command_id) VALUES(?,1,?,?,?,?,?,?,'planned',?,?,?)", &.{ .{ .text = effect }, .{ .text = run }, .{ .text = session }, .{ .text = @tagName(kind) }, .{ .integer = @intFromBool(kind == .inspect or kind == .attach) }, .{ .blob = bytes }, .{ .blob = &digest }, if (dependency) |v| .{ .text = v } else .null, if (approval) |v| .{ .text = v } else .null, .{ .text = causation.value } });
    }

    /// Lookup precedes validation. Rejections are durable and byte-exact retries
    /// return their original receipt even after aggregate revisions have changed.
    pub fn command(self: *Owner, allocator: std.mem.Allocator, envelope: t.CommandEnvelope) !t.Receipt {
        const canonical = try encoded(allocator, envelope);
        const output = try allocator.alloc(u8, 65536);
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        if (self.database.lookupCommand(envelope.command_id.value, canonical, output) catch |err| switch (err) {
            error.Conflict => {
                try self.database.rollback();
                return .{ .command_id = envelope.command_id, .outcome = .rejected, .reason = .command_id_conflict, .commit_sequence = 0 };
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
        var reason: ?t.Reason = if (envelope.contract_version != 1) .unsupported_version else null;
        if (reason == null) switch (envelope.expected_revision) {
            .absent => if (current != null) { reason = .revision_conflict; },
            .revision => |expected| if (current == null) { reason = .not_found; } else if (current.? != expected or expected >= std.math.maxInt(i64)) { reason = .revision_conflict; },
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
        }
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
    fn reduce(self: *Owner, allocator: std.mem.Allocator, e: t.CommandEnvelope, r: *t.Receipt) !?t.Reason {
        const db = self.database;
        const seq = r.commit_sequence;
        var aggregate: t.AggregateRef = undefined;
        var revision_value: u64 = 1;
        switch (e.payload) {
            .unsupported => return .unsupported_kind,
            .project_create => |p| {
                if (e.target != .absent or e.expected_revision != .absent or p.display_name.len == 0) return .invalid_command;
                const key = try self.id(allocator);
                try db.execute("INSERT INTO projects VALUES(?,1,?)", &.{ .{ .text = key }, .{ .blob = p.display_name } });
                r.entity_ids.project = .{ .value = key };
                aggregate = .{ .project = r.entity_ids.project.? };
            },
            .workspace_register => |p| {
                if (e.target != .absent or e.expected_revision != .absent or p.binding.canonical_root.len == 0 or p.binding.canonical_root[0] != '/') return .invalid_command;
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
                const key = try self.id(allocator);
                try db.execute("INSERT INTO threads(id,revision,project_id,workspace_id) VALUES(?,1,?,?)", &.{ .{ .text = key }, .{ .text = p.project.value }, .{ .text = p.workspace.value } });
                r.entity_ids.thread = .{ .value = key };
                aggregate = .{ .thread = r.entity_ids.thread.? };
            },
            .thread_send => |p| {
                if (e.target != .thread or e.expected_revision != .revision or p.text.len == 0) return .invalid_command;
                const thread = e.target.thread.value;
                const workspace = try self.field(allocator, "SELECT workspace_id FROM threads WHERE id=?", &.{.{ .text = thread }}) orelse return .not_found;
                if (!std.mem.eql(u8, workspace, p.selection.workspace.value)) return .workspace_mismatch;
                if (!std.mem.eql(u8, p.selection.runtime_kind, "fake") or !std.mem.eql(u8, p.selection.required_runtime_version, "1") or p.selection.capability_revision != 1 or p.selection.account_ref.len == 0 or p.selection.model_id.len == 0 or p.selection.model_provider.len == 0) return .capability_unavailable;
                if (try self.field(allocator, "SELECT id FROM runs WHERE thread_id=? AND (state IN('queued','starting','streaming','awaiting_approval','cancel_requested','unknown','interrupted') OR EXISTS(SELECT 1 FROM effects WHERE run_id=runs.id AND state IN('unknown','in_flight')))", &.{.{ .text = thread }}) != null) return .unresolved_effects;
                const run = try self.id(allocator);
                const session = try self.id(allocator);
                const user = try self.id(allocator);
                const assistant = try self.id(allocator);
                const user_block = try self.id(allocator);
                const assistant_block = try self.id(allocator);
                const open = try self.id(allocator);
                const start = try self.id(allocator);
                const request: a.Request = .{ .start = .{ .correlation = .{ .effect = .{ .value = start }, .run = .{ .value = run }, .session = .{ .value = session } }, .prompt = p.text } };
                if (a.frameBytes(request) > 4096) return .admission_limit;
                const selection = try encoded(allocator, p.selection);
                try db.execute("INSERT INTO sessions(id,revision,workspace_id,selection) VALUES(?,1,?,?)", &.{ .{ .text = session }, .{ .text = workspace }, .{ .blob = selection } });
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
                try db.execute("UPDATE threads SET revision=revision+1,session_id=?,next_ordinal=next_ordinal+2 WHERE id=?", &.{ .{ .text = session }, .{ .text = thread } });
                try self.plan(allocator, open, run, session, .create_session, .{ .open = .{ .create = .{ .effect = .{ .value = open }, .session = .{ .value = session }, .selection = p.selection } } }, null, null, e.command_id);
                try self.plan(allocator, start, run, session, .start, request, open, null, e.command_id);
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
                for (p.effects) |effect_id| {
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
        }
        const revisions = try allocator.alloc(t.CommittedRevision, 1);
        revisions[0] = .{ .target = aggregate, .revision = revision_value };
        r.committed_revisions = revisions;
        try self.event(allocator, seq, if (e.payload == .thread_send) 1 else 0, aggregate, revision_value, @tagName(e.payload), e.command_id, null, "");
        return null;
    }

    pub const Claimed = struct { id: a.EffectId, request: a.Request };
    /// Claim commits before returning an immutable request to a dispatcher.
    pub fn claimNext(self: *Owner, allocator: std.mem.Allocator) !?Claimed {
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        const statement = try self.database.prepare("SELECT e.id,e.request FROM effects e JOIN runs r ON r.id=e.run_id WHERE e.state='planned' AND (e.read_only=1 OR r.state IN('queued','starting','streaming','awaiting_approval') OR (e.kind='cancel' AND r.state='cancel_requested')) AND (e.depends_on IS NULL OR EXISTS(SELECT 1 FROM effects d WHERE d.id=e.depends_on AND d.state='confirmed')) ORDER BY e.rowid LIMIT 1", &.{});
        const result: ?Claimed = blk: {
            defer statement.deinit();
            if (!try statement.step()) break :blk null;
            break :blk .{ .id = a.EffectId{ .value = try allocator.dupe(u8, try statement.bytes(0)) }, .request = try t.decode(a.Request, try statement.bytes(1), allocator) };
        };
        if (result) |effect| {
            if (!try self.database.claim(effect.id.value, self.epoch)) return error.Conflict;
        }
        try self.database.commit();
        return result;
    }
    pub fn recover(self: *Owner) !void {
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        try self.database.recoverClaims();
        try self.database.commit();
    }
};

test {
    _ = types;
    _ = @import("domain/domain_test.zig");
}
