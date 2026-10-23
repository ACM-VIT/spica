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
    upstream_turn: ?UpstreamTurn = null,
    upstream_request: ?[]const u8 = null,
    upstream_tool: ?[]const u8 = null,
};
pub const Open = union(enum) {
    create: struct { effect: EffectId, session: RuntimeSessionId, selection: Selection },
    // Exact attach has no effect ID or create fallback.
    existing: struct { session: Session, after: ?UpstreamCursor = null },
};
pub const Request = union(enum) {
    open: Open,
    start: struct { correlation: Correlation, prompt: []const u8 },
    respond_approval: struct { correlation: Correlation, decision: enum { allow, deny }, action_digest: []const u8 },
    cancel: struct { correlation: Correlation, reason: []const u8 },
    message: struct { correlation: Correlation, message: MessageId, content: []const u8 },
    inspect: struct { session: Session, run: ?RunId = null, effect: ?EffectId = null, turn: ?UpstreamTurn = null },
    attach: struct { session: Session, after: ?UpstreamCursor = null },
};
pub const ApprovalEvidence = struct {
    correlation: Correlation,
    workspace: WorkspaceId,
    action_digest: []const u8,
    scope: []const u8,
    expires_at: ?u64 = null,
};
pub const Receipt = struct {
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
        completed: void,
        cancelled: struct { tools_stopped: bool },
        failure: struct { code: []const u8, detail: []const u8 },
        disconnect: struct { reason: []const u8, continuity: enum { unknown, lost } },
        ambiguous: struct { reason: []const u8 },
    },
};
pub const Counters = struct { O: u64 = 0, S: u64 = 0, A: u64 = 0, C: u64 = 0, I: u64 = 0, T: u64 = 0, D: u64 = 0, X: u64 = 0 };
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
        .pointer => std.mem.eql(u8, a, b),
        else => a == b,
    };
}

/// Wire admission size: all variable byte fields, plus the typed fixed header.
/// Checked without allocation; repeated string fields count separately.
pub fn frameBytes(value: anytype) usize {
    return @sizeOf(@TypeOf(value)) +| variableBytes(value);
}
fn variableBytes(value: anytype) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => value.len,
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
