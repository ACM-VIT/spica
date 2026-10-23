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
        var reason: ?t.Reason = if (envelope.contract_version != 1) .unsupported_version else null;
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
    /// Persist adapter delivery evidence without interpreting acknowledgement as
    /// run completion. An ambiguous call is never changed back to planned.
    pub fn delivered(self: *Owner, allocator: std.mem.Allocator, effect: a.EffectId, receipt: a.Receipt) !void {
        const db = self.database;
        try db.begin();
        errdefer db.rollback() catch {};
        const s = try db.prepare("SELECT run_id,session_id,kind,revision,state FROM effects WHERE id=?", &.{.{ .text = effect.value }});
        defer s.deinit();
        if (!try s.step() or !std.mem.eql(u8, try s.bytes(4), "in_flight")) return error.Conflict;
        if (s.integer(3) == std.math.maxInt(i64)) return error.Limit;
        const run = try allocator.dupe(u8, try s.bytes(0));
        const session = try allocator.dupe(u8, try s.bytes(1));
        const kind = try allocator.dupe(u8, try s.bytes(2));
        try self.guardRunRevisions(run);
        const sequence = try db.nextSequence();
        const missing_session = std.mem.eql(u8, kind, "create_session") and receipt.outcome == .acknowledged and receipt.session == null;
        const state = if (missing_session) "unknown" else switch (receipt.outcome) {
            .acknowledged => "confirmed",
            .rejected => "failed",
            .unknown => "unknown",
        };
        try db.execute("UPDATE effects SET state=?,outcome=?,evidence=?,revision=revision+1 WHERE id=?", &.{ .{ .text = state }, .{ .blob = receipt.detail }, .{ .blob = try encoded(allocator, receipt) }, .{ .text = effect.value } });
        try self.event(allocator, sequence, 0, .{ .effect = effect }, @intCast(s.integer(3) + 1), "EffectDelivery", null, effect, "");
        if (receipt.session) |live| {
            if (!std.mem.eql(u8, live.id.value, session)) return error.Conflict;
            const revision_statement = try db.prepare("SELECT revision FROM sessions WHERE id=?", &.{.{ .text = session }});
            defer revision_statement.deinit();
            if (!try revision_statement.step() or revision_statement.integer(0) == std.math.maxInt(i64)) return error.Limit;
            try db.execute("UPDATE sessions SET instance_id=?,upstream_session=?,continuity=?,revision=revision+1 WHERE id=?", &.{ .{ .text = live.instance.value }, .{ .text = live.upstream.value }, .{ .text = @tagName(receipt.continuity) }, .{ .text = session } });
            try self.event(allocator, sequence, 1, .{ .session = .{ .value = session } }, @intCast(revision_statement.integer(0) + 1), "SessionEvidence", null, effect, "");
        }
        const next_state: []const u8 = if (missing_session or receipt.outcome == .unknown) "unknown" else if (receipt.outcome == .rejected) "failed" else if (std.mem.eql(u8, kind, "create_session")) "starting" else if (std.mem.eql(u8, kind, "cancel")) "cancel_requested" else "streaming";
        const revision_statement = try db.prepare("SELECT revision,state FROM runs WHERE id=?", &.{.{ .text = run }});
        defer revision_statement.deinit();
        if (!try revision_statement.step()) return error.Corrupt;
        const current = try revision_statement.bytes(1);
        // Delivery after terminal evidence never revives the lifecycle.
        if (!(std.mem.eql(u8, current, "completed") or std.mem.eql(u8, current, "cancelled") or std.mem.eql(u8, current, "failed"))) {
            try db.execute("UPDATE runs SET state=?,revision=revision+1 WHERE id=?", &.{ .{ .text = next_state }, .{ .text = run } });
            try self.event(allocator, sequence, 2, .{ .run = .{ .value = run } }, @intCast(revision_statement.integer(0) + 1), "RunDelivery", null, effect, "");
        }
        try db.commit();
    }

    /// A complete bounded observation is retained by the caller until this
    /// transaction succeeds. Duplicate identity requires byte-equal evidence.
    pub fn observe(self: *Owner, allocator: std.mem.Allocator, observation: a.Observation) !void {
        if (a.frameBytes(observation) > 4096 or observation.upstream_event.len == 0) return error.Limit;
        const run = observation.correlation.run orelse return error.Conflict;
        const session = observation.correlation.session;
        const db = self.database;
        const canonical = try encoded(allocator, observation);
        const digest = t.digest(canonical);
        try db.begin();
        errdefer db.rollback() catch {};
        {
            const duplicate = try db.prepare("SELECT digest FROM observations WHERE session_id=? AND upstream_event=?", &.{ .{ .text = session.value }, .{ .text = observation.upstream_event } });
            defer duplicate.deinit();
            if (try duplicate.step()) {
                if (!std.mem.eql(u8, try duplicate.bytes(0), &digest)) return error.Conflict;
                try db.rollback();
                return;
            }
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
                    index += 1;
                }
                if (!terminal and !std.mem.eql(u8, current_state, "cancel_requested")) next_state = "streaming";
            },
            .tool_started => |tool| {
                const tool_id = observation.correlation.tool orelse return error.Conflict;
                const upstream = observation.correlation.upstream_tool orelse return error.Conflict;
                if (terminal) return error.Conflict;
                const existing = try self.field(allocator, "SELECT id FROM tools WHERE session_id=? AND upstream_tool=?", &.{ .{ .text = session.value }, .{ .text = upstream } });
                if (existing != null) return error.Conflict;
                try db.execute("INSERT INTO tools(id,revision,run_id,session_id,upstream_tool,name,action_digest,outcome) VALUES(?,1,?,?,?,?,?,'pending')", &.{ .{ .text = tool_id.value }, .{ .text = run.value }, .{ .text = session.value }, .{ .text = upstream }, .{ .blob = tool.name }, .{ .blob = tool.action_digest } });
                try db.execute("UPDATE runs SET unresolved_tools=unresolved_tools+1 WHERE id=?", &.{.{ .text = run.value }});
                try self.event(allocator, sequence, index, .{ .tool = tool_id }, 1, "ToolStarted", null, observation.correlation.effect, "");
                index += 1;
            },
            .tool_completed => |result| {
                const tool = observation.correlation.tool orelse return error.Conflict;
                const found = try db.prepare("SELECT revision,outcome FROM tools WHERE id=? AND run_id=? AND session_id=? AND upstream_tool=?", &.{ .{ .text = tool.value }, .{ .text = run.value }, .{ .text = session.value }, if (observation.correlation.upstream_tool) |v| .{ .text = v } else .null });
                defer found.deinit();
                if (!try found.step() or found.integer(0) == std.math.maxInt(i64)) return error.Conflict;
                if (!std.mem.eql(u8, try found.bytes(1), "pending")) return error.Conflict;
                // Tool results are bounded canonical content, not UI-only text.
                const block = try self.id(allocator);
                const message = try self.field(allocator, "SELECT id FROM messages WHERE run_id=? AND role='assistant'", &.{.{ .text = run.value }}) orelse return error.Corrupt;
                const ordinal = try db.prepare("SELECT coalesce(max(ordinal),-1)+1 FROM blocks WHERE message_id=?", &.{.{ .text = message }});
                defer ordinal.deinit();
                if (!try ordinal.step()) return error.Corrupt;
                try db.execute("INSERT INTO blocks(id,revision,message_id,ordinal,kind,tool_id) VALUES(?,1,?,?,'tool_result',?)", &.{ .{ .text = block }, .{ .text = message }, .{ .integer = ordinal.integer(0) }, .{ .text = tool.value } });
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
                if (!std.mem.eql(u8, tool_digest, approval.action_digest) or !std.mem.eql(u8, workspace, approval.workspace.value)) return error.Conflict;
                if (approval.expires_at) |expiry| if (expiry > std.math.maxInt(i64)) return error.Limit;
                try db.execute("INSERT INTO approvals(id,revision,run_id,session_id,tool_id,workspace_id,upstream_request,action_digest,scope,expires_at,state,live_epoch) VALUES(?,1,?,?,?,?,?,?,?,?,'pending',?)", &.{ .{ .text = approval_id.value }, .{ .text = run.value }, .{ .text = session.value }, .{ .text = tool_id.value }, .{ .text = workspace }, .{ .text = request }, .{ .blob = approval.action_digest }, .{ .blob = approval.scope }, if (approval.expires_at) |v| .{ .integer = @intCast(v) } else .null, .{ .text = self.epoch } });
                next_state = "awaiting_approval";
                try self.event(allocator, sequence, index, .{ .approval = approval_id }, 1, "ApprovalPending", null, observation.correlation.effect, "");
                index += 1;
            },
            .completed => {
                const pending = try self.field(allocator, "SELECT id FROM tools WHERE run_id=? AND outcome IN('pending','unknown') LIMIT 1", &.{.{ .text = run.value }});
                if (!terminal) next_state = if (pending == null) "completed" else "unknown";
            },
            .cancelled => |cancelled| if (!terminal) {
                next_state = if (cancelled.tools_stopped) "cancelled" else "unknown";
            },
            .failure => if (!terminal) {
                next_state = "failed";
            },
            .disconnect, .ambiguous => if (!terminal) {
                next_state = "unknown";
            },
            .selection => |selection| {
                const bytes = try self.field(allocator, "SELECT requested FROM runs WHERE id=?", &.{.{ .text = run.value }}) orelse return error.Corrupt;
                const requested = try t.decode(a.Selection, bytes, allocator);
                if (!a.equal(requested, selection.requested) or selection.effective == null or !a.equal(requested, selection.effective.?)) return error.Conflict;
                try db.execute("UPDATE runs SET effective=? WHERE id=?", &.{ .{ .blob = try encoded(allocator, selection.effective.?) }, .{ .text = run.value } });
            },
            .session => return error.Conflict,
        }
        try db.execute("INSERT INTO observations(session_id,upstream_event,runtime_version,correlation,digest,cursor,commit_sequence) VALUES(?,?,?,?,?,?,?)", &.{ .{ .text = session.value }, .{ .text = observation.upstream_event }, .{ .text = observation.runtime_version }, .{ .blob = try encoded(allocator, observation.correlation) }, .{ .blob = &digest }, if (observation.cursor) |v| .{ .blob = v.value } else .null, .{ .integer = @intCast(sequence) } });
        // Cursor advances only in the transaction containing the canonical bytes.
        if (observation.cursor) |cursor| {
            const session_revision = try db.prepare("SELECT revision FROM sessions WHERE id=?", &.{.{ .text = session.value }});
            defer session_revision.deinit();
            if (!try session_revision.step() or session_revision.integer(0) == std.math.maxInt(i64)) return error.Limit;
            try db.execute("UPDATE sessions SET cursor=?,revision=revision+1 WHERE id=?", &.{ .{ .blob = cursor.value }, .{ .text = session.value } });
            try self.event(allocator, sequence, index, .{ .session = session }, @intCast(session_revision.integer(0) + 1), "CursorCommitted", null, observation.correlation.effect, "");
            index += 1;
        }
        try db.execute("UPDATE runs SET state=?,revision=revision+1 WHERE id=?", &.{ .{ .text = next_state }, .{ .text = run.value } });
        try self.event(allocator, sequence, index, .{ .run = run }, @intCast(state_statement.integer(1) + 1), "ObservationCommitted", null, observation.correlation.effect, "");
        try db.commit();
    }

    pub fn recover(self: *Owner) !void {
        try self.database.begin();
        errdefer self.database.rollback() catch {};
        try self.database.recoverClaims();
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
    };
    const Request = union(enum) { command: t.CommandEnvelope, query: t.Query, subscribe: t.Subscribe, unsubscribe: t.SubscriptionId };
    const Frame = struct { ticket: t.Ticket = .{ .value = 0 }, len: usize = 0, bytes: [65536]u8 = undefined };
    const Result = struct { len: usize = 0, bytes: [262144]u8 = undefined };
    const Snapshot = struct { generation: u64 = 0, database: ?*store.c.sqlite3 = null, position: t.EventPosition = .{}, deadline: u64 = 0 };
    const Subscription = struct { generation: u64 = 0, active: bool = false, scope: t.Scope = .all, after: t.EventPosition = .{}, max_bytes: usize = 65536, arena: std.heap.ArenaAllocator };
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    database: store.Store,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    closed: bool = false,
    next_ticket: u64 = 1,
    requests: [8]Frame = undefined,
    request_head: usize = 0,
    request_count: usize = 0,
    results: [8]Result = undefined,
    result_head: usize = 0,
    result_count: usize = 0,
    snapshots: [2]Snapshot = .{ .{}, .{} },
    subscriptions: [4]Subscription = undefined,
    epoch: [32]u8 = undefined,
    path: [:0]u8,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Host {
        const l = options.limits;
        if (l.request_slots == 0 or l.request_slots > 8 or l.result_slots == 0 or l.result_slots > 8 or l.snapshot_slots == 0 or l.snapshot_slots > 2 or l.subscription_slots > 4 or l.command_bytes > 65536 or l.page_bytes > 65536 or l.page_rows > 128 or l.page_rows == 0) return error.InvalidLimits;
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
        self.* = .{ .allocator = allocator, .io = io, .options = options, .database = database, .path = path };
        for (&self.subscriptions) |*sub| sub.* = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var owner: Owner = .{ .database = &self.database, .io = io, .epoch = "", .utc_ms = null };
        @memcpy(&self.epoch, try owner.id(arena.allocator()));
        try owner.recover();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn destroy(self: *Host) void {
        self.mutex.lockUncancelable(self.io);
        self.closed = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        for (&self.snapshots) |*snapshot| self.closeSnapshot(snapshot);
        for (&self.subscriptions) |*sub| sub.arena.deinit();
        self.database.close() catch {};
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
    pub fn submit(self: *Host, command: t.CommandEnvelope) t.AdmissionError!t.Ticket {
        return self.admit(.{ .command = command });
    }
    pub fn query(self: *Host, request: t.Query) t.AdmissionError!t.Ticket {
        return self.admit(.{ .query = request });
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
        if (self.closed) return error.Closed;
        if (self.request_count == self.options.limits.request_slots or self.next_ticket == std.math.maxInt(u64)) return error.Full;
        const frame = &self.requests[(self.request_head + self.request_count) % 8];
        const bytes = t.encode(request, frame.bytes[0..self.options.limits.command_bytes]) catch return error.TooLarge;
        frame.len = bytes.len;
        frame.ticket = .{ .value = self.next_ticket };
        self.next_ticket += 1;
        self.request_count += 1;
        self.changed.signal(self.io);
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
        var owner: Owner = .{ .database = &self.database, .io = self.io, .epoch = &self.epoch, .utc_ms = null };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var operation_memory: [2 * 1024 * 1024]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.closed and self.request_count == 0) self.changed.waitUncancelable(self.io, &self.mutex);
            if (self.closed) {
                self.mutex.unlock(self.io);
                return;
            }
            const frame = self.requests[self.request_head];
            self.request_head = (self.request_head + 1) % 8;
            self.request_count -= 1;
            self.mutex.unlock(self.io);
            var fixed = std.heap.FixedBufferAllocator.init(&operation_memory);
            const allocator = fixed.allocator();
            owner.utc_ms = @intCast(@max(0, std.Io.Clock.real.now(self.io).toMilliseconds()));
            for (&self.snapshots) |*snapshot| if (snapshot.database != null and self.now() >= snapshot.deadline) {
                self.closeSnapshot(snapshot);
            };
            const request = t.decode(Request, frame.bytes[0..frame.len], allocator) catch {
                self.fail(frame.ticket, .admission_limit);
                continue;
            };
            self.handle(&owner, allocator, frame.ticket, request) catch |err| {
                self.database.rollback() catch {};
                self.fail(frame.ticket, switch (err) {
                    error.CursorInvalid => .cursor_invalid,
                    error.NotFound => .not_found,
                    error.InvalidQuery => .invalid_query,
                    error.Limit, error.OutOfMemory, error.TooLarge => .admission_limit,
                    else => .storage_unavailable,
                });
            };
            // Each adapter call follows a committed claim. A failed delivery is
            // left in_flight and recovery will mark it unknown, never retry it.
            var steps: usize = 0;
            while (steps < 8) : (steps += 1) {
                _ = arena.reset(.retain_capacity);
                const claimed = owner.claimNext(arena.allocator()) catch break;
                const effect = claimed orelse break;
                self.dispatch(&owner, arena.allocator(), effect) catch break;
            }
            self.deliverSubscriptions(allocator) catch {};
        }
    }
    fn fail(self: *Host, ticket: t.Ticket, reason: @FieldType(t.Failure, "reason")) void {
        self.publish(.{ .failure = .{ .ticket = ticket, .failure = .{ .reason = reason, .refresh_required = reason == .cursor_invalid } } }) catch {};
    }
    fn handle(self: *Host, owner: *Owner, allocator: std.mem.Allocator, ticket: t.Ticket, request: Request) !void {
        switch (request) {
            .command => |command| {
                const used = try self.database.scalar("PRAGMA page_count");
                const page_size = try self.database.scalar("PRAGMA page_size");
                if (@as(u64, @intCast(used)) *| @as(u64, @intCast(page_size)) >= self.options.limits.durable_bytes) return error.Limit;
                try self.publish(.{ .command_receipt = .{ .ticket = ticket, .receipt = try owner.command(allocator, command) } });
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

    const fake = @import("runtime/fake.zig");
    /// Fixed fake-v1 scenario. IDs derive from durable run identity, not UI state.
    /// Each call is exercised through the accepted bounded fake adapter, with no
    /// external provider or script owning lifecycle. No recovered run is started.
    fn dispatch(self: *Host, owner: *Owner, allocator: std.mem.Allocator, effect: Owner.Claimed) !void {
        const request = effect.request;
        const s = try self.database.prepare("SELECT e.run_id,e.session_id,r.requested,m.id,b.id FROM effects e JOIN runs r ON r.id=e.run_id JOIN messages m ON m.run_id=r.id AND m.role='assistant' JOIN blocks b ON b.message_id=m.id AND b.ordinal=0 WHERE e.id=?", &.{.{ .text = effect.id.value }});
        defer s.deinit();
        if (!try s.step()) return error.Corrupt;
        const run_id = a.RunId{ .value = try allocator.dupe(u8, try s.bytes(0)) };
        const session_id = a.RuntimeSessionId{ .value = try allocator.dupe(u8, try s.bytes(1)) };
        const selection = try t.decode(a.Selection, try s.bytes(2), allocator);
        const tool_id = a.ToolCallId{ .value = try std.fmt.allocPrint(allocator, "{s}-tool", .{run_id.value}) };
        const approval_id = a.ApprovalId{ .value = try std.fmt.allocPrint(allocator, "{s}-approval", .{run_id.value}) };
        const correlation: a.Correlation = .{ .session = session_id, .run = run_id, .tool = tool_id, .approval = approval_id, .upstream_tool = "fake-tool", .upstream_request = "fake-approval" };
        var receipt: a.Receipt = .{ .outcome = .acknowledged };
        if (request == .open) receipt.session = .{ .id = session_id, .instance = .{ .value = &self.epoch }, .upstream = .{ .value = session_id.value } };
        var script: [6]fake.Step = undefined;
        script[0] = .{ .expect = .{ .request = request, .receipt = receipt } };
        var count: usize = 1;
        switch (request) {
            .start => {
                script[1] = .{ .emit = .{ .correlation = correlation, .upstream_event = "selection", .body = .{ .selection = .{ .requested = selection, .effective = selection, .readiness = .ready } } } };
                script[2] = .{ .emit = .{ .correlation = correlation, .upstream_event = "response", .body = .{ .chunk = .{ .message = .{ .value = try s.bytes(3) }, .block = .{ .value = try s.bytes(4) }, .offset = 0, .text = "Fake response: café 世界 👩‍💻\n\n```zig\nconst answer = 42;\n```\n" } } } };
                script[3] = .{ .emit = .{ .correlation = correlation, .upstream_event = "tool-start", .body = .{ .tool_started = .{ .name = "workspace.inspect", .action_digest = "fake-v1-inspect" } } } };
                script[4] = .{ .emit = .{ .correlation = correlation, .upstream_event = "approval", .body = .{ .approval = .{ .correlation = correlation, .workspace = selection.workspace, .action_digest = "fake-v1-inspect", .scope = "one workspace inspection" } } } };
                count = 5;
            },
            .respond_approval => |reply| {
                script[1] = .{ .emit = .{ .correlation = correlation, .upstream_event = "tool-result", .body = .{ .tool_completed = .{ .outcome = if (reply.decision == .allow) .succeeded else .failed, .result = if (reply.decision == .allow) "Inspection approved; temporary workspace inspected." else "Inspection denied; no action executed." } } } };
                script[2] = .{ .emit = .{ .correlation = correlation, .upstream_event = "completed", .body = .completed } };
                count = 3;
            },
            .cancel => {
                script[1] = .{ .emit = .{ .correlation = correlation, .upstream_event = "cancelled", .body = .{ .cancelled = .{ .tools_stopped = true } } } };
                count = 2;
            },
            .open => {},
            else => receipt = .{ .outcome = .unknown, .detail = "no live recovery continuity" },
        }
        script[0] = .{ .expect = .{ .request = request, .receipt = receipt } };
        var runtime = try fake.Runtime(16, 32).init(.{ .account = .{ .reference = selection.account_ref, .readiness = .ready }, .selection = .{ .requested = selection, .effective = selection, .readiness = .ready } }, script[0..count]);
        try owner.delivered(allocator, effect.id, try runtime.dispatch(request));
        try runtime.pump();
        while (runtime.poll()) |observation| try owner.observe(allocator, observation);
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
            errdefer if (database) |db| { _ = store.c.sqlite3_close(db); };
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
        for (self.snapshots[0..self.options.limits.snapshot_slots], 0..) |snapshot, i| if (snapshot.deadline < self.snapshots[oldest].deadline) { oldest = i; };
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
            .workspaces => |v| v.page,
            .threads => |v| v.page,
            .messages => |v| v.page,
            .blocks => |v| v.page,
            .content => |v| v.page,
            .runs => |v| v.page,
            .effects => |v| v.page,
            .tools => |v| v.page,
            .approvals => |v| v.page,
            .thread, .capabilities => .{},
        };
        if (page.limit == 0 or page.limit > self.options.limits.page_rows or page.max_bytes == 0 or page.max_bytes > self.options.limits.page_bytes) return error.InvalidQuery;
        const snapshot = try self.snapshotFor(page);
        var reader = self.database;
        reader.database = snapshot.value.database.?;
        var result: t.QueryPage = .{ .snapshot_id = snapshot.id, .snapshot_position = snapshot.value.position, .items = &.{}, .expires_at = snapshot.value.deadline };
        const rows = try allocator.alloc(t.Row, page.limit);
        var count: usize = 0;
        var bytes_used: usize = 0;
        const Cursor = struct { query: []const u8, key: u64 };
        const identity_buffer = try allocator.alloc(u8, 65536);
        var identity_query = q;
        switch (identity_query) {
            .projects => |*v| v.* = .{},
            .workspaces => |*v| v.page = .{},
            .threads => |*v| v.page = .{},
            .messages => |*v| v.page = .{},
            .blocks => |*v| v.page = .{},
            .content => |*v| v.page = .{},
            .runs => |*v| v.page = .{},
            .effects => |*v| v.page = .{},
            .tools => |*v| v.page = .{},
            .approvals => |*v| v.page = .{},
            else => {},
        }
        const identity = try t.encode(identity_query, identity_buffer);
        var cursor: u64 = 0;
        if (page.cursor) |raw| {
            const parsed = t.decode(Cursor, raw, allocator) catch return error.CursorInvalid;
            if (!std.mem.eql(u8, parsed.query, identity) or parsed.key > std.math.maxInt(i64)) return error.CursorInvalid;
            cursor = parsed.key;
        }
        var sql: [:0]const u8 = undefined;
        var values: [5]V = undefined;
        var n: usize = 0;
        switch (q) {
            .capabilities => {
                rows[0] = .{ .capabilities = .{ .capabilities = fake.defaultCapabilities(), .limits = .{} } };
                result.items = rows[0..1];
                return result;
            },
            .projects => sql = "SELECT rowid,id,revision,display_name FROM projects WHERE rowid>? ORDER BY rowid LIMIT ?",
            .workspaces => |v| { sql = "SELECT rowid,id,revision,project_id,binding FROM workspaces WHERE project_id=? AND rowid>? ORDER BY rowid LIMIT ?"; values[0] = .{ .text = v.project.value }; n = 1; },
            .threads => |v| { sql = "SELECT rowid,id,revision,project_id,workspace_id,session_id FROM threads WHERE project_id=? AND rowid>max(?,coalesce((SELECT rowid FROM threads WHERE id=?),0)) ORDER BY rowid LIMIT ?"; values[0] = .{ .text = v.project.value }; values[1] = .{ .integer = @intCast(cursor) }; values[2] = if (v.anchor) |anchor| .{ .text = anchor.value } else .null; n = 3; },
            .thread => |v| { sql = "SELECT rowid,id,revision,project_id,workspace_id,session_id FROM threads WHERE id=? AND rowid>? LIMIT ?"; values[0] = .{ .text = v.value }; n = 1; },
            .messages => |v| {
                sql = if (v.direction == .newer) "SELECT ordinal+1,id,revision,ordinal,role,incomplete,run_id FROM messages WHERE thread_id=? AND ordinal+1>max(?,coalesce((SELECT ordinal+1 FROM messages WHERE id=? AND thread_id=?),0)) ORDER BY ordinal LIMIT ?" else "SELECT ordinal+1,id,revision,ordinal,role,incomplete,run_id FROM messages WHERE thread_id=? AND ordinal+1<min(nullif(?,0),coalesce((SELECT ordinal+1 FROM messages WHERE id=? AND thread_id=?),9223372036854775807)) ORDER BY ordinal DESC LIMIT ?";
                if (v.direction == .older and cursor == 0) cursor = std.math.maxInt(i64);
                values[0] = .{ .text = v.thread.value }; values[1] = .{ .integer = @intCast(cursor) }; values[2] = if (v.anchor) |anchor| .{ .text = anchor.value } else .null; values[3] = .{ .text = v.thread.value }; n = 4;
            },
            .blocks => |v| { sql = "SELECT ordinal+1,id,revision,ordinal,kind,committed_bytes,tool_id FROM blocks WHERE message_id=? AND ordinal+1>? ORDER BY ordinal LIMIT ?"; values[0] = .{ .text = v.message.value }; n = 1; },
            .runs => |v| { sql = "SELECT rowid,id,revision,thread_id,session_id,state,requested,effective FROM runs WHERE thread_id=? AND rowid>? ORDER BY rowid LIMIT ?"; values[0] = .{ .text = v.thread.value }; n = 1; },
            .effects => |v| { sql = "SELECT rowid,id,revision,run_id,kind,state,outcome FROM effects WHERE run_id=? AND rowid>? ORDER BY rowid LIMIT ?"; values[0] = .{ .text = v.run.value }; n = 1; },
            .tools => |v| { sql = "SELECT rowid,id,revision,run_id,name,action_digest,outcome,result_block FROM tools WHERE run_id=? AND rowid>? ORDER BY rowid LIMIT ?"; values[0] = .{ .text = v.run.value }; n = 1; },
            .approvals => |v| { sql = "SELECT rowid,id,revision,run_id,state,session_id,tool_id,workspace_id,upstream_request,action_digest,scope,expires_at,live_epoch FROM approvals WHERE run_id=? AND rowid>? ORDER BY rowid LIMIT ?"; values[0] = .{ .text = v.run.value }; n = 1; },
            .content => |v| {
                if (v.start_byte > v.end_byte or v.end_byte > std.math.maxInt(i64) or v.end_byte - v.start_byte > page.max_bytes) return error.InvalidQuery;
                const s = try reader.prepare("SELECT revision,committed_bytes FROM blocks WHERE id=?", &.{.{ .text = v.block.value }});
                defer s.deinit();
                if (!try s.step()) return error.NotFound;
                const committed = try number(s, 1);
                if (v.start_byte > committed) return error.InvalidQuery;
                const end = @min(v.end_byte, committed);
                const bytes = try allocator.alloc(u8, @intCast(end - v.start_byte));
                const chunks = try reader.prepare("SELECT byte_offset,bytes FROM chunks WHERE block_id=? AND byte_offset<? AND byte_offset+length(bytes)>? ORDER BY byte_offset", &.{ .{ .text = v.block.value }, .{ .integer = @intCast(end) }, .{ .integer = @intCast(v.start_byte) } });
                defer chunks.deinit();
                var copied: usize = 0;
                while (try chunks.step()) {
                    const start = try number(chunks, 0);
                    const chunk = try chunks.bytes(1);
                    const low = @max(start, v.start_byte);
                    const high = @min(start + chunk.len, end);
                    @memcpy(bytes[@intCast(low - v.start_byte)..@intCast(high - v.start_byte)], chunk[@intCast(low - start)..@intCast(high - start)]);
                    copied += @intCast(high - low);
                }
                if (copied != bytes.len) return error.Corrupt;
                rows[0] = .{ .content = .{ .block_id = v.block, .revision = try number(s, 0), .start_byte = v.start_byte, .end_byte = end, .next_byte = if (end < committed) end else null, .bytes = bytes } };
                result.items = rows[0..1];
                return result;
            },
        }
        if (q != .messages and q != .threads) { values[n] = .{ .integer = @intCast(cursor) }; n += 1; }
        values[n] = .{ .integer = @as(i64, page.limit) + 1 }; n += 1;
        const statement = try reader.prepare(sql, values[0..n]);
        defer statement.deinit();
        var last_key: u64 = cursor;
        var encode_buffer: [131072]u8 = undefined;
        while (try statement.step()) {
            if (count == page.limit) { result.next_cursor = try Owner.encoded(allocator, Cursor{ .query = identity, .key = last_key }); break; }
            const s = statement;
            const row: t.Row = switch (q) {
                .projects => .{ .project = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .display_name = try text(allocator, s, 3) } },
                .workspaces => .{ .workspace = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .project = .{ .value = try text(allocator, s, 3) }, .binding = try t.decode(t.WorkspaceBinding, try s.bytes(4), allocator) } },
                .threads, .thread => .{ .thread = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .project = .{ .value = try text(allocator, s, 3) }, .workspace = .{ .value = try text(allocator, s, 4) }, .session = if (s.isNull(5)) null else .{ .value = try text(allocator, s, 5) } } },
                .blocks => .{ .block = try descriptor(allocator, s) },
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
                            next = try Owner.encoded(allocator, Cursor{ .query = try t.encode(block_query, try allocator.alloc(u8, 2048)), .key = key });
                        }
                    }
                    break :blk .{ .message = .{ .message_id = message_id, .revision = try number(s, 2), .ordinal = try number(s, 3), .role = try enumeration(@FieldType(@FieldType(t.Row, "message"), "role"), s, 4), .incomplete = s.integer(5) != 0, .run_id = .{ .value = try text(allocator, s, 6) }, .blocks = descriptors, .next_block_cursor = next } };
                },
                .runs => .{ .run = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .thread = .{ .value = try text(allocator, s, 3) }, .session = .{ .value = try text(allocator, s, 4) }, .state = try enumeration(t.RunState, s, 5), .requested = try t.decode(a.Selection, try s.bytes(6), allocator), .effective = if (s.isNull(7)) null else try t.decode(a.Selection, try s.bytes(7), allocator) } },
                .effects => .{ .effect = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .kind = try enumeration(t.EffectKind, s, 4), .state = try enumeration(t.EffectState, s, 5), .outcome = try text(allocator, s, 6) } },
                .tools => .{ .tool = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .name = try text(allocator, s, 4), .action_digest = try text(allocator, s, 5), .outcome = try enumeration(t.ToolOutcome, s, 6), .result_block = if (s.isNull(7)) null else .{ .value = try text(allocator, s, 7) } } },
                .approvals => .{ .approval = .{ .id = .{ .value = try text(allocator, s, 1) }, .revision = try number(s, 2), .run = .{ .value = try text(allocator, s, 3) }, .state = try enumeration(t.ApprovalState, s, 4), .evidence = .{ .correlation = .{ .session = .{ .value = try text(allocator, s, 5) }, .run = .{ .value = try text(allocator, s, 3) }, .tool = .{ .value = try text(allocator, s, 6) }, .approval = .{ .value = try text(allocator, s, 1) }, .upstream_request = try text(allocator, s, 8) }, .workspace = .{ .value = try text(allocator, s, 7) }, .action_digest = try text(allocator, s, 9), .scope = try text(allocator, s, 10), .expires_at = if (s.isNull(11)) null else try number(s, 11) }, .live = !s.isNull(12) and std.mem.eql(u8, try s.bytes(12), &self.epoch) } },
                else => unreachable,
            };
            const row_bytes = (try t.encode(row, &encode_buffer)).len;
            if (row_bytes > page.max_bytes - bytes_used) {
                if (count == 0) return error.Limit;
                result.next_cursor = try Owner.encoded(allocator, Cursor{ .query = identity, .key = last_key });
                break;
            }
            rows[count] = row;
            count += 1;
            bytes_used += row_bytes;
            last_key = try number(s, 0);
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
                if (scanned > self.options.limits.subscriber_lag_events) { overflow = true; break; }
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
                    if (count == events.len or size > sub.max_bytes - bytes) { overflow = true; break; }
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
}
