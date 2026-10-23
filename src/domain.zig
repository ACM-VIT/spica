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

test {
    _ = types;
    _ = @import("domain/domain_test.zig");
}
