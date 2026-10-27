//! Adapter-only core-v1 vocabulary. No domain persistence or committed-intent proof.
const std = @import("std");

fn Id(comptime name: []const u8) type {
    return struct {
        pub const kind = name;
        value: []const u8,
    };
}
pub const EffectId = Id("effect");
pub const RunId = Id("run");
pub const RuntimeSessionId = Id("runtime_session");
pub const RuntimeInstanceId = Id("runtime_instance");
pub const WorkspaceId = Id("workspace");
pub const ApprovalId = Id("approval");
pub const MessageId = Id("message");
pub const ToolCallId = Id("tool_call");
pub const FollowupId = Id("followup");
pub const QuestionId = Id("question");
pub const AttachmentId = Id("attachment");
pub const PromptRef = struct { id: []const u8, byte_length: usize, sha256: [32]u8 };
pub const UpstreamSession = struct { value: []const u8 };
pub const UpstreamTurn = struct { value: []const u8 };
pub const UpstreamCursor = struct { value: []const u8 };

pub const Status = enum { supported, unsupported, unknown };
pub const Capability = enum {
    create,
    attach,
    start,
    stream,
    tools,
    approval,
    cancel,
    inspect,
    replay,
    message,
    selection,
    workspace,
    usage,
    coordinator_bridge,
    followup_queue,
    question,
    attachment,
};
pub const CapabilityInfo = struct {
    status: Status,
    evidence: []const u8 = "synthetic script; no live runtime evidence",
};
pub const Limits = struct {
    frame_bytes: usize = 4096,
    chunk_bytes: usize = 2048,
    queue_bytes: usize = 16384,
    queue_frames: usize = 16,
    call_frames: usize = 32,
    followup_count: usize = 8,
    followup_bytes: usize = 64 * 1024,
    question_choices: usize = 16,
    question_answer_bytes: usize = 4096,
    attachment_count: usize = 8,
    attachment_bytes: usize = 256 * 1024,
    attachment_metadata_bytes: usize = 4096,
    attachment_packet_bytes: usize = 384 * 1024,
    // Synchronous dispatch: no hidden outstanding requests or transport buffers.
    pending_requests: usize = 1,
};
pub const Discovery = struct {
    schema_version: u32 = 1,
    runtime_kind: []const u8 = "fake",
    runtime_version: []const u8 = "1",
    capability_revision: u32 = 1,
    capabilities: [@typeInfo(Capability).@"enum".fields.len]CapabilityInfo,
    limits: Limits,
};
pub const Readiness = enum { ready, unavailable, unknown };
pub const Account = struct { reference: []const u8, readiness: Readiness };
pub const Selection = struct {
    runtime_kind: []const u8 = "fake",
    required_runtime_version: []const u8 = "1",
    model_provider: []const u8,
    model_id: []const u8,
    effort: []const u8,
    account_ref: []const u8,
    workspace: WorkspaceId,
    capability_revision: u32 = 1,
};
/// The local fixture remains independent of configured external runtimes.
pub fn fakeSelection(workspace: WorkspaceId) Selection {
    return .{ .model_provider = "fake", .model_id = "fixture", .effort = "none", .account_ref = "fixture", .workspace = workspace };
}
pub fn isFakeSelection(selection: Selection) bool {
    return equal(selection, fakeSelection(selection.workspace));
}
/// Catalog entries are protocol evidence, not account entitlement.
pub const Model = struct {
    selection: Selection,
    supported_efforts: []const []const u8,
    display_name: []const u8,
    readiness: Readiness,
    reason: []const u8,
    synthetic: bool = false,
};
pub const RuntimeKind = enum { codex, opencode };
pub const RuntimeSetup = struct {
    runtime_kind: RuntimeKind,
    executable: []const u8,
    account_directory: []const u8,
    workspace_root: []const u8,
    model_provider: []const u8,
};
pub const RuntimeLogin = struct { runtime_kind: RuntimeKind, mode: enum { browser, device } };
pub const RuntimeAction = union(enum) {
    configure: RuntimeSetup,
    /// Restore saved metadata without creating account state or running a provider.
    restore: RuntimeSetup,
    refresh: void,
    login: RuntimeLogin,
};
pub const RuntimeStatus = struct {
    login_pending: bool = false,
    /// Borrowed from the factory until its next setup action.
    configuration: ?RuntimeSetup = null,
    /// At most two saved setups, borrowed until the next status query or action.
    configurations: []const RuntimeSetup = &.{},
    runtime_kind: []const u8 = "",
    readiness: Readiness = .unknown,
    reason: []const u8 = "Configure a runtime, then explicitly refresh its catalog.",
    login: []const u8 = "",
    workspace_root: []const u8 = "",
};
pub const SelectionResult = struct {
    requested: Selection,
    // null is explicitly unverified, never inferred from requested identity.
    effective: ?Selection,
    readiness: Readiness,
};
pub const Session = struct {
    id: RuntimeSessionId,
    instance: RuntimeInstanceId,
    upstream: UpstreamSession,
};
pub const Correlation = struct {
    effect: ?EffectId = null,
    session: RuntimeSessionId,
    run: ?RunId = null,
    tool: ?ToolCallId = null,
    approval: ?ApprovalId = null,
    question: ?QuestionId = null,
    followup: ?FollowupId = null,
    upstream_turn: ?UpstreamTurn = null,
    upstream_request: ?[]const u8 = null,
    upstream_tool: ?[]const u8 = null,
};
pub const AttachmentKind = enum { file, image };
pub const AttachmentMetadata = struct {
    id: AttachmentId,
    name: []const u8,
    media_type: []const u8,
    byte_length: u64,
    digest: []const u8,
    kind: AttachmentKind = .file,
};
/// Content is copied by an adapter boundary and is never retained through a
/// caller-owned buffer. Empty content is valid for metadata-only handoff.
pub const Attachment = struct {
    metadata: AttachmentMetadata,
    content: []const u8 = &.{},
};
pub const Followup = struct {
    id: FollowupId,
    content: []const u8,
};
pub const QuestionChoice = struct { id: []const u8, label: []const u8 };
pub const Question = struct {
    id: QuestionId,
    correlation: Correlation,
    prompt: []const u8,
    choices: []const QuestionChoice = &.{},
    allow_multiple: bool = false,
    allow_freeform: bool = false,
    expires_at: ?u64 = null,
};
pub const QuestionAnswer = struct {
    choice_ids: []const []const u8 = &.{},
    text: []const u8 = "",
};
pub const Open = union(enum) {
    create: struct { effect: EffectId, session: RuntimeSessionId, selection: Selection },
    // Exact attach has no effect ID or create fallback.
    existing: struct { session: Session, after: ?UpstreamCursor = null },
};
pub const Request = union(enum) {
    open: Open,
    start: struct { correlation: Correlation, prompt: []const u8 = "", prompt_ref: ?PromptRef = null, attachments: []const Attachment = &.{} },
    respond_approval: struct { correlation: Correlation, decision: enum { allow, deny }, action_digest: []const u8 },
    cancel: struct { correlation: Correlation, reason: []const u8 },
    message: struct {
        correlation: Correlation,
        message: MessageId,
        content: []const u8,
        followup: ?Followup = null,
        attachments: []const Attachment = &.{},
    },
    answer_question: struct { correlation: Correlation, question: QuestionId, answer: QuestionAnswer },
    inspect: struct { session: Session, run: ?RunId = null, effect: ?EffectId = null, turn: ?UpstreamTurn = null },
    attach: struct { session: Session, after: ?UpstreamCursor = null },
};
pub const ApprovalEvidence = struct {
    correlation: Correlation,
    workspace: WorkspaceId,
    action_digest: []const u8,
    scope: []const u8,
    /// Absolute Unix epoch milliseconds (UTC), never monotonic ticks.
    /// Null means no advertised expiry, not permission; domain fails closed on
    /// unknown/expired wall-time evidence without extending authority on restart.
    expires_at: ?u64 = null,
};
pub const Receipt = struct {
    /// Request delivery/acknowledgement only; never proof of run completion.
    /// Acknowledged messages may still receive an asynchronous request_failed.
    outcome: enum { acknowledged, rejected, unknown },
    session: ?Session = null,
    inspection: ?enum { active, completed, failed, cancelled, unknown } = null,
    continuity: enum { not_requested, proven, unknown, lost } = .not_requested,
    // Positive scripted evidence only. Null never proves an old callback live.
    live_approval: ?ApprovalEvidence = null,
    detail: []const u8 = "",
};
pub const BlockId = Id("content_block");
pub const Observation = struct {
    correlation: Correlation,
    upstream_event: []const u8,
    cursor: ?UpstreamCursor = null,
    runtime_version: []const u8 = "1",
    sequence: u64 = 0,
    body: union(enum) {
        selection: SelectionResult,
        session: Session,
        chunk: struct { message: MessageId, block: BlockId, offset: u64, text: []const u8 },
        tool_started: struct { name: []const u8, action_digest: []const u8 },
        tool_completed: struct { outcome: enum { succeeded, failed, unknown }, result: []const u8 },
        approval: ApprovalEvidence,
        question: Question,
        /// Cumulative run usage; cached input is a subset of input, not added
        /// again. Subscription billing cannot be inferred from these counters.
        usage: struct { input_tokens: u64, output_tokens: u64, cached_tokens: u64 },
        completed: void,
        cancelled: struct { tools_stopped: bool },
        /// Definitive refusal of one message request, not failure of its run.
        /// Requires explicit session/run/effect correlation to a dispatched
        /// message. Acknowledged delivery alone does not preclude this outcome.
        request_failed: struct { code: []const u8, detail: []const u8 },
        /// Terminal provider/turn (including start/open) failure. Request-only
        /// refusals must use request_failed, even when an effect ID is known.
        failure: struct { code: []const u8, detail: []const u8 },
        disconnect: struct { reason: []const u8, continuity: enum { unknown, lost } },
        ambiguous: struct { reason: []const u8 },
    },
};
pub const Counters = struct { O: u64 = 0, S: u64 = 0, A: u64 = 0, C: u64 = 0, I: u64 = 0, T: u64 = 0, D: u64 = 0, F: u64 = 0, Q: u64 = 0, H: u64 = 0, X: u64 = 0 };
pub const Error = error{
    InvalidLimits,
    CapabilityUnavailable,
    AccountUnavailable,
    SelectionUnavailable,
    InvalidCorrelation,
    FrameTooLarge,
    ChunkTooLarge,
    QueueFull,
    CallLogFull,
    UnexpectedRequest,
    ScriptFinished,
    ClockReversed,
    BarrierMismatch,
    InvalidFollowup,
    InvalidQuestion,
    QuestionExpired,
    InvalidAttachment,
    AttachmentLimit,
};

/// Structural byte equality, including borrowed string contents (not addresses).
pub fn equal(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (!equal(@field(a, field.name), @field(b, field.name))) break :blk false;
            }
            break :blk true;
        },
        .@"union" => blk: {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) break :blk false;
            inline for (@typeInfo(T).@"union".fields) |field| {
                if (std.meta.activeTag(a) == @field(std.meta.Tag(T), field.name))
                    break :blk equal(@field(a, field.name), @field(b, field.name));
            }
            unreachable;
        },
        .optional => if (a) |value| if (b) |other| equal(value, other) else false else b == null,
        .pointer => |pointer| if (pointer.child == u8) std.mem.eql(u8, a, b) else blk: {
            if (a.len != b.len) break :blk false;
            for (a, b) |left, right| if (!equal(left, right)) break :blk false;
            break :blk true;
        },
        .array => |array| blk: {
            for (a, b) |left, right| if (!equal(left, right)) break :blk false;
            _ = array;
            break :blk true;
        },
        else => a == b,
    };
}

/// Wire admission size: all variable byte fields, plus the typed fixed header.
/// Checked without allocation; repeated string fields count separately.
pub fn frameBytes(value: anytype) usize {
    const T = @TypeOf(value);
    // Keep the v1 start-frame accounting stable as optional queue/question
    // fields are added to the structural union. Their variable payload bytes
    // are still counted below, so bounded admission remains conservative.
    const fixed = if (T == Request) 208 else @sizeOf(T);
    return fixed +| variableBytes(value);
}

pub fn validateAttachments(attachments: []const Attachment, limits: Limits) Error!void {
    if (attachments.len > limits.attachment_count) return error.InvalidAttachment;
    var content_bytes: usize = 0;
    var metadata_bytes: usize = 0;
    for (attachments) |attachment| {
        if (attachment.metadata.id.value.len == 0 or attachment.metadata.name.len == 0 or
            attachment.metadata.media_type.len == 0 or attachment.metadata.digest.len == 0 or
            attachment.metadata.byte_length > @as(u64, @intCast(std.math.maxInt(usize)))) return error.InvalidAttachment;
        if (attachment.content.len != 0 and attachment.content.len != attachment.metadata.byte_length) return error.InvalidAttachment;
        content_bytes +|= @intCast(attachment.metadata.byte_length);
        metadata_bytes +|= attachment.metadata.name.len +| attachment.metadata.media_type.len +| attachment.metadata.digest.len +| attachment.metadata.id.value.len;
    }
    if (content_bytes > limits.attachment_bytes or metadata_bytes > limits.attachment_metadata_bytes) return error.InvalidAttachment;
}

/// Metadata-only journal references are allowed here; runtime admission additionally
/// requires bodies and verifies their digest before mutating provider state.
pub fn validateNativeAttachments(attachments: []const Attachment, limits: Limits) Error!void {
    if (attachments.len > @min(limits.attachment_count, 8)) return error.InvalidAttachment;
    var content_bytes: usize = 0;
    var metadata_bytes: usize = 0;
    for (attachments, 0..) |attachment, index| {
        const m = attachment.metadata;
        if (m.id.value.len == 0 or m.id.value.len > 128 or m.name.len == 0 or m.name.len > 256 or
            m.media_type.len == 0 or m.media_type.len > 128 or m.digest.len != 64 or
            m.byte_length > @min(limits.attachment_bytes, 256 * 1024)) return error.InvalidAttachment;
        for ([_][]const u8{ m.id.value, m.name, m.media_type, m.digest }) |value| {
            if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidAttachment;
        }
        for (m.digest) |byte| if (!std.ascii.isHex(byte)) return error.InvalidAttachment;
        const image_type = std.mem.startsWith(u8, m.media_type, "image/");
        if ((m.kind == .image) != image_type) return error.InvalidAttachment;
        for (attachments[0..index]) |previous| if (equal(m.id, previous.metadata.id)) return error.InvalidAttachment;
        if (attachment.content.len != 0 and attachment.content.len != m.byte_length) return error.InvalidAttachment;
        content_bytes +|= @intCast(m.byte_length);
        metadata_bytes +|= m.name.len +| m.media_type.len +| m.digest.len +| m.id.value.len;
    }
    if (content_bytes > @min(limits.attachment_bytes, 256 * 1024) or metadata_bytes > @min(limits.attachment_metadata_bytes, 4096)) return error.InvalidAttachment;
}

pub fn attachmentDigestMatches(attachment: Attachment) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(attachment.content, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&hex, attachment.metadata.digest);
}

pub fn validateFollowup(followup: Followup, limits: Limits) Error!void {
    if (followup.id.value.len == 0 or followup.content.len == 0 or followup.content.len > limits.followup_bytes) return error.InvalidFollowup;
    if (frameBytes(followup) > limits.frame_bytes) return error.FrameTooLarge;
}

pub fn validateQuestion(question: Question, limits: Limits) Error!void {
    if (question.id.value.len == 0 or question.prompt.len == 0 or question.choices.len > limits.question_choices or
        (question.choices.len == 0 and !question.allow_freeform)) return error.InvalidQuestion;
    var seen: [16][]const u8 = undefined;
    var seen_count: usize = 0;
    for (question.choices) |choice| {
        if (choice.id.len == 0 or choice.label.len == 0 or seen_count == seen.len) return error.InvalidQuestion;
        for (seen[0..seen_count]) |previous| if (std.mem.eql(u8, previous, choice.id)) return error.InvalidQuestion;
        seen[seen_count] = choice.id;
        seen_count += 1;
    }
    if (frameBytes(question) > limits.frame_bytes) return error.FrameTooLarge;
}

pub fn validateQuestionAnswer(answer: QuestionAnswer, limits: Limits) Error!void {
    if (answer.text.len > limits.question_answer_bytes or answer.choice_ids.len > limits.question_choices) return error.InvalidQuestion;
    for (answer.choice_ids, 0..) |choice, index| {
        if (choice.len == 0) return error.InvalidQuestion;
        for (answer.choice_ids[0..index]) |previous| if (std.mem.eql(u8, previous, choice)) return error.InvalidQuestion;
    }
    if (frameBytes(answer) > limits.frame_bytes) return error.FrameTooLarge;
}

fn variableBytes(value: anytype) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |pointer| if (pointer.child == u8) value.len else blk: {
            var n: usize = 0;
            for (value) |item| n +|= variableBytes(item);
            break :blk n;
        },
        .optional => if (value) |v| variableBytes(v) else 0,
        .@"struct" => blk: {
            var n: usize = 0;
            inline for (@typeInfo(T).@"struct".fields) |field| n +|= variableBytes(@field(value, field.name));
            break :blk n;
        },
        .@"union" => blk: {
            inline for (@typeInfo(T).@"union".fields) |field| {
                if (std.meta.activeTag(value) == @field(std.meta.Tag(T), field.name))
                    break :blk variableBytes(@field(value, field.name));
            }
            unreachable;
        },
        else => 0,
    };
}
