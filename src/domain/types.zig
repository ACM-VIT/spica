//! Domain values only. Adapter observations/receipts are never public domain results.
const std = @import("std");
pub const adapter = @import("../contract.zig");
pub const orchestration = @import("../orchestration.zig");

fn Id(comptime name: []const u8) type {
    return struct {
        pub const kind = name;
        value: []const u8,
    };
}
pub const ProjectId = Id("project");
pub const ThreadId = Id("thread");
pub const CommandId = Id("command");
pub const EventId = Id("event");
pub const FollowupId = adapter.FollowupId;
pub const QuestionId = adapter.QuestionId;
pub const AttachmentId = adapter.AttachmentId;
pub const SnapshotId = struct { slot: u8, generation: u64 };
pub const SubscriptionId = struct { slot: u8, generation: u64 };
pub const Ticket = struct { value: u64 };
pub const Revision = u64;
/// Maximum UTF-8 byte length for an explicit editable thread title.
pub const max_title_bytes: usize = 160;
pub const EventPosition = struct {
    commit_sequence: u64 = 0,
    event_index: u32 = 0,
    pub fn order(a: EventPosition, b: EventPosition) std.math.Order {
        const sequence = std.math.order(a.commit_sequence, b.commit_sequence);
        return if (sequence == .eq) std.math.order(a.event_index, b.event_index) else sequence;
    }
};
pub const Precondition = union(enum) { absent, revision: Revision };
pub const Target = union(enum) {
    absent,
    project: ProjectId,
    workspace: adapter.WorkspaceId,
    thread: ThreadId,
    run: adapter.RunId,
    approval: adapter.ApprovalId,
    effect: adapter.EffectId,
    followup: FollowupId,
    question: QuestionId,
    attachment: AttachmentId,
};

/// Mutations target command aggregates; events/receipts also identify content,
/// session and journal aggregates without relabeling them as runs or threads.
pub const AggregateRef = union(enum) {
    project: ProjectId,
    workspace: adapter.WorkspaceId,
    thread: ThreadId,
    run: adapter.RunId,
    approval: adapter.ApprovalId,
    message: adapter.MessageId,
    block: adapter.BlockId,
    session: adapter.RuntimeSessionId,
    effect: adapter.EffectId,
    tool: adapter.ToolCallId,
    followup: FollowupId,
    question: QuestionId,
    attachment: AttachmentId,
};
pub const WorkspaceBinding = struct {
    canonical_root: []const u8,
    filesystem_identity: []const u8,
    repository_identity: []const u8,
    checkout_identity: []const u8,
    expected_branch: []const u8,
    /// Empty for non-Git directories or a proven unborn symbolic Git branch.
    /// The first commit changes this identity; it never silently rebases a binding.
    base_revision: []const u8,
    non_git: bool = false,
};
pub const PromptRef = adapter.PromptRef;

pub const Payload = union(enum) {
    project_create: struct { display_name: []const u8 },
    workspace_register: struct { project: ProjectId, binding: WorkspaceBinding },
    thread_create: struct { project: ProjectId, workspace: adapter.WorkspaceId },
    /// Replace the durable user title for one thread.
    thread_title_set: struct { title: []const u8 },
    thread_send: struct { text: []const u8, selection: adapter.Selection, attachments: []const AttachmentId = &.{} },
    thread_send_staged: struct { prompt: PromptRef, selection: adapter.Selection, attachments: []const AttachmentId = &.{} },
    /// Explicitly discard one bounded orphan upload. Never affects a sent prompt.
    prompt_discard: struct { id: ?[]const u8 = null },
    thread_select: struct { selection: adapter.Selection },
    /// A queued follow-up is represented by a planned provider message effect.
    /// The effect remains nondispatchable until its dependency chain permits it.
    followup_enqueue: struct { content: []const u8, attachments: []const adapter.Attachment = &.{} },
    followup_edit: struct { content: []const u8, attachments: []const adapter.Attachment = &.{} },
    followup_cancel: struct { reason: []const u8 },
    followup_order: struct { followups: []const FollowupId },
    /// Provider questions are separate from permission approvals. Durable
    /// pending-question storage is a later schema handoff; this command shape
    /// is still shared by domain and provider fixtures.
    question_answer: struct { question: QuestionId, answer: adapter.QuestionAnswer },
    attachment_add: adapter.Attachment,
    attachment_remove: AttachmentId,
    runtime_configure: adapter.RuntimeSetup,
    runtime_refresh: void,
    runtime_login: adapter.RuntimeLogin,
    approval_respond: struct { decision: enum { allow, deny }, action_digest: []const u8 },
    run_cancel: struct { reason: []const u8 },
    run_reconcile: struct {
        session: adapter.RuntimeSessionId,
        effects: []const adapter.EffectId,
        resolution: ?struct { actor: []const u8, evidence: []const u8, no_execution: bool } = null,
    },
    task_delegate: orchestration.Packet,
    task_send: struct { content: []const u8 },
    task_cancel: struct { reason: []const u8 },
    task_result: orchestration.Result,
    task_review: struct { candidate: []const u8, evidence: []const u8, disposition: orchestration.Disposition },
    unsupported: struct { kind: []const u8, payload: []const u8 },
};
pub const CommandEnvelope = struct {
    contract_version: u32 = 1,
    command_id: CommandId,
    target: Target,
    expected_revision: Precondition,
    payload: Payload,
};
pub const Reason = enum {
    revision_conflict,
    command_id_conflict,
    unsupported_version,
    unsupported_kind,
    invalid_command,
    not_found,
    busy,
    capability_unavailable,
    selection_mismatch,
    workspace_mismatch,
    authority_unavailable,
    approval_invalid,
    approval_expired,
    unresolved_effects,
    session_unavailable,
    admission_limit,
    followup_limit,
    followup_not_found,
    followup_invalid,
    question_invalid,
    question_expired,
    attachment_limit,
    attachment_unsupported,
    prompt_incomplete,
    prompt_invalid,
    prompt_staging_full,
};
pub const EntityIds = struct {
    project: ?ProjectId = null,
    workspace: ?adapter.WorkspaceId = null,
    thread: ?ThreadId = null,
    run: ?adapter.RunId = null,
    user_message: ?adapter.MessageId = null,
    assistant_message: ?adapter.MessageId = null,
    assistant_block: ?adapter.BlockId = null,
    session: ?adapter.RuntimeSessionId = null,
    followup: ?FollowupId = null,
    question: ?QuestionId = null,
    attachment: ?AttachmentId = null,
};
pub const CommittedRevision = struct { target: AggregateRef, revision: Revision };
pub const Receipt = struct {
    command_id: CommandId,
    outcome: enum { accepted, rejected },
    reason: ?Reason = null,
    current_revision: ?Revision = null,
    entity_ids: EntityIds = .{},
    committed_revisions: []const CommittedRevision = &.{},
    commit_sequence: u64,
    effect_ids: []const adapter.EffectId = &.{},
};
pub const RunState = enum { queued, starting, streaming, awaiting_approval, cancel_requested, completed, cancelled, failed, interrupted, unknown };
pub const EffectState = enum { planned, in_flight, withdrawn, confirmed, failed, unknown };
pub const EffectKind = enum { create_session, start, approval_reply, cancel, inspect, attach, message };
pub const ApprovalState = enum { pending, resolved, invalidated };
pub const ToolOutcome = enum { pending, succeeded, failed, unknown };
pub const Direction = enum { older, newer };
pub const Page = struct {
    limit: u16 = 64,
    max_bytes: u32 = 64 * 1024,
    snapshot: ?SnapshotId = null,
    cursor: ?[]const u8 = null,
};
pub const Query = union(enum) {
    // Provider effects require explicit commands; these queries are cache-only.
    projects: Page,
    command_receipt: CommandId,
    models: struct { workspace: adapter.WorkspaceId, page: Page = .{} },
    runtime_status: void,
    workspaces: struct { project: ProjectId, page: Page = .{} },
    threads: struct { project: ?ProjectId = null, anchor: ?ThreadId = null, page: Page = .{} },
    thread: ThreadId,
    messages: struct { thread: ThreadId, anchor: ?adapter.MessageId = null, direction: Direction = .newer, page: Page = .{} },
    blocks: struct { message: adapter.MessageId, page: Page = .{} },
    attachments: struct { thread: ThreadId, page: Page = .{} },
    content: struct { block: adapter.BlockId, start_byte: u64, end_byte: u64, page: Page = .{} },
    runs: struct { thread: ThreadId, page: Page = .{} },
    effects: struct { run: adapter.RunId, page: Page = .{} },
    tools: struct { run: adapter.RunId, page: Page = .{} },
    approvals: struct { run: adapter.RunId, page: Page = .{} },
    capabilities: void,
    task_list: struct { parent: adapter.RunId, page: Page = .{} },
    task_wait: adapter.RunId,
};
pub const BlockDescriptor = struct {
    block_id: adapter.BlockId,
    ordinal: u64,
    kind: enum { text, tool_result },
    committed_bytes: u64,
    revision: Revision,
    tool_id: ?adapter.ToolCallId = null,
};
pub const RuntimeStatus = struct {
    login_pending: bool = false,
    /// Owned by the query projection, borrowed by its consumer.
    configuration: ?adapter.RuntimeSetup = null,
    /// At most two saved setups, deeply owned by the query projection.
    configurations: []const adapter.RuntimeSetup = &.{},
    runtime_kind: []const u8,
    readiness: adapter.Readiness,
    reason: []const u8,
    login: []const u8,
    workspace_root: []const u8,
    binding: ?WorkspaceBinding = null,
    supported_login_modes: []const []const u8 = &.{},
};
pub const Row = union(enum) {
    command_receipt: ?Receipt,
    project: struct { id: ProjectId, revision: Revision, display_name: []const u8 },
    workspace: struct { id: adapter.WorkspaceId, revision: Revision, project: ProjectId, binding: WorkspaceBinding },
    thread: struct {
        id: ThreadId,
        revision: Revision,
        project: ProjectId,
        workspace: adapter.WorkspaceId,
        session: ?adapter.RuntimeSessionId,
        selection: ?adapter.Selection = null,
        /// At most 160 UTF-8 bytes from the first user prompt, read without
        /// decoding history. Explicit user titles take precedence over it.
        title_preview: []const u8 = "",
        /// Explicit title bytes, empty when the thread still uses automatic naming.
        title: []const u8 = "",
        latest_run_state: ?RunState = null,
        project_name: []const u8 = "",
        workspace_root: []const u8 = "",
        workspace_branch: []const u8 = "",
    },
    message: struct {
        message_id: adapter.MessageId,
        revision: Revision,
        ordinal: u64,
        role: enum { user, assistant, tool },
        incomplete: bool,
        run_id: adapter.RunId,
        blocks: []const BlockDescriptor,
        next_block_cursor: ?[]const u8 = null,
    },
    block: BlockDescriptor,
    attachment: struct {
        id: AttachmentId,
        thread: ThreadId,
        name: []const u8,
        media_type: []const u8,
        byte_length: u64,
        digest: []const u8,
        kind: adapter.AttachmentKind,
        revision: Revision,
    },
    content: struct { block_id: adapter.BlockId, revision: Revision, start_byte: u64, end_byte: u64, next_byte: ?u64, bytes: []const u8 },
    run: struct { id: adapter.RunId, revision: Revision, thread: ThreadId, session: adapter.RuntimeSessionId, state: RunState, requested: adapter.Selection, effective: ?adapter.Selection, diagnostic: []const u8 = "" },
    effect: struct { id: adapter.EffectId, revision: Revision, run: adapter.RunId, kind: EffectKind, state: EffectState, outcome: []const u8 },
    tool: struct { id: adapter.ToolCallId, revision: Revision, run: adapter.RunId, name: []const u8, action_digest: []const u8, outcome: ToolOutcome, result_block: ?adapter.BlockId },
    approval: struct { id: adapter.ApprovalId, revision: Revision, run: adapter.RunId, state: ApprovalState, evidence: adapter.ApprovalEvidence, live: bool },
    capabilities: adapter.Discovery,
    model: adapter.Model,
    runtime_status: RuntimeStatus,
    task: struct { task: orchestration.Task, state: RunState, revision: Revision },
};
pub const QueryPage = struct {
    snapshot_id: SnapshotId,
    snapshot_position: EventPosition,
    items: []const Row,
    next_cursor: ?[]const u8 = null,
    /// Ephemeral snapshot deadline in host-monotonic milliseconds. Not UTC and
    /// never comparable to ApprovalEvidence.expires_at (Unix epoch UTC ms).
    expires_at: u64,
};
pub const Event = struct {
    contract_version: u32 = 1,
    event_id: EventId,
    position: EventPosition,
    aggregate: AggregateRef,
    aggregate_revision: Revision,
    kind: []const u8,
    causation_command_id: ?CommandId = null,
    effect_id: ?adapter.EffectId = null,
    // Bounded normalized record; content events reference blocks/ranges, not copied history.
    payload: []const u8,
};
pub const EventKind = enum {
    FollowupQueued,
    FollowupEdited,
    FollowupCancelled,
    FollowupReordered,
    QuestionRequested,
    QuestionAnswered,
    QuestionInvalidated,
    AttachmentAccepted,
    AttachmentRejected,
};
pub const TypedEvent = struct {
    contract_version: u32 = 1,
    event_id: EventId,
    position: EventPosition,
    aggregate: AggregateRef,
    aggregate_revision: Revision,
    kind: EventKind,
    causation_command_id: ?CommandId = null,
    effect_id: ?adapter.EffectId = null,
    payload: union(enum) {
        followup: struct { id: FollowupId, order: u32 = 0 },
        question: adapter.Question,
        answer: struct { id: QuestionId, answer: adapter.QuestionAnswer },
        attachment: adapter.AttachmentMetadata,
    },
};
pub const Scope = union(enum) { all, thread: ThreadId, run: adapter.RunId };
pub const Subscribe = struct { scope: Scope, after_position: EventPosition, max_batch_bytes: u32 = 64 * 1024 };
pub const Failure = struct {
    reason: enum { storage_unavailable, outcome_unknown, cursor_invalid, not_found, invalid_query, admission_limit, closed },
    refresh_required: bool = false,
    anchor_id: ?[]const u8 = null,
};
pub const Output = union(enum) {
    command_receipt: struct { ticket: Ticket, receipt: Receipt },
    query_page: struct { ticket: Ticket, page: QueryPage },
    subscribed: struct { ticket: Ticket, id: SubscriptionId, after_position: EventPosition },
    unsubscribed: struct { ticket: Ticket },
    event_batch: struct { id: SubscriptionId, events: []const Event, end_position: EventPosition },
    resync_required: struct { id: SubscriptionId },
    newer_revision: struct { snapshot_id: SnapshotId, position: EventPosition },
    failure: struct { ticket: Ticket, failure: Failure },
};
pub const DrainResult = struct { output_count: usize, bytes_used: usize, more_pending: bool, required_bytes_for_next: usize = 0 };
pub const AdmissionError = error{ Full, TooLarge, Closed, Busy };
pub const Limits = struct {
    command_bytes: usize = 64 * 1024,
    page_bytes: usize = 64 * 1024,
    page_rows: usize = 128,
    request_slots: usize = 8,
    result_slots: usize = 8,
    subscription_slots: usize = 4,
    snapshot_slots: usize = 2,
    snapshot_ttl_ms: u64 = 5000,
    subscriber_lag_events: u64 = 4096,
    durable_bytes: u64 = 256 * 1024 * 1024,
    attachment_count: usize = 8,
    attachment_bytes: usize = 256 * 1024,
    attachment_metadata_bytes: usize = 4096,
    attachment_packet_bytes: usize = 384 * 1024,
};

/// Versioned structural encoding: declaration field order, explicit union tags,
/// nulls and string bytes. Never includes padding, pointer values or formatting.
/// No allocation. The caller owns both input and output storage.
pub fn encode(value: anytype, buffer: []u8) error{TooLarge}![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = true }, &writer) catch return error.TooLarge;
    return writer.buffered();
}
pub fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

test "canonical envelope includes target precondition and byte contents" {
    const command: CommandEnvelope = .{ .command_id = .{ .value = "cmd" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "é世界" } } };
    var first: [1024]u8 = undefined;
    var second: [1024]u8 = undefined;
    const bytes = try encode(command, &first);
    try std.testing.expectEqualStrings(bytes, try encode(command, &second));
    var altered = command;
    altered.expected_revision = .{ .revision = 7 };
    try std.testing.expect(!std.mem.eql(u8, bytes, try encode(altered, &second)));
    altered = command;
    altered.target = .{ .thread = .{ .value = "other" } };
    try std.testing.expect(!std.mem.eql(u8, bytes, try encode(altered, &second)));
    try std.testing.expectError(error.TooLarge, encode(command, second[0..8]));
}
test "event ordering retains unseen equal revision transaction members" {
    try std.testing.expectEqual(std.math.Order.lt, EventPosition.order(.{ .commit_sequence = 3, .event_index = 0 }, .{ .commit_sequence = 3, .event_index = 1 }));
    try std.testing.expectEqual(std.math.Order.gt, EventPosition.order(.{ .commit_sequence = 4 }, .{ .commit_sequence = 3, .event_index = 99 }));
}

/// Caller supplies a bounded allocator whose lifetime owns every returned slice.
/// Both JSON strings and numeric byte arrays decode to the original u8 slices.
pub fn decode(comptime T: type, bytes: []const u8, allocator: std.mem.Allocator) !T {
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = bytes.len });
}

test "arbitrary content range bytes roundtrip without UTF-8 normalization" {
    const Content = struct { bytes: []const u8 };
    const samples = [_][]const u8{ "é\x00世界", "\xc3", "\xa9", "\xf0\x9f", "\x91\xa9", "\xff\x00" };
    for (samples) |sample| {
        var encoded: [1024]u8 = undefined;
        const source = try encode(Content{ .bytes = sample }, &encoded);
        var backing: [4096]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&backing);
        const restored = try decode(Content, source, allocator.allocator());
        try std.testing.expectEqualSlices(u8, sample, restored.bytes);
    }
    var first: [1024]u8 = undefined;
    var second: [1024]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, try encode(Content{ .bytes = "\xc3" }, &first), try encode(Content{ .bytes = "\xa9" }, &second)));
}

test "block and effect aggregates retain distinct canonical identities" {
    var first: [1024]u8 = undefined;
    var second: [1024]u8 = undefined;
    const block: AggregateRef = .{ .block = .{ .value = "same-id" } };
    const effect: AggregateRef = .{ .effect = .{ .value = "same-id" } };
    try std.testing.expect(!std.mem.eql(u8, try encode(block, &first), try encode(effect, &second)));
}
