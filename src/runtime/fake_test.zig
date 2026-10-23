const std = @import("std");
const f = @import("fake.zig");
const c = f.contract;
const t = std.testing;
const selection: c.Selection = .{ .model_provider = "synthetic", .model_id = "unicode", .effort = "not_applicable", .account_ref = "fixture", .workspace = .{ .value = "workspace" } };
const config: f.Config = .{ .account = .{ .reference = "fixture", .readiness = .ready }, .selection = .{ .requested = selection, .effective = selection, .readiness = .ready } };
const session: c.Session = .{ .id = .{ .value = "session" }, .instance = .{ .value = "instance" }, .upstream = .{ .value = "upstream-session" } };
const corr: c.Correlation = .{ .effect = .{ .value = "fixture-effect-not-committed" }, .session = session.id, .run = .{ .value = "run" }, .tool = .{ .value = "tool" }, .approval = .{ .value = "approval" }, .upstream_turn = .{ .value = "turn" }, .upstream_request = "request", .upstream_tool = "native-tool" };
const start: c.Request = .{ .start = .{ .correlation = corr, .prompt = "你好 👩🏽‍💻" } };
const approval: c.ApprovalEvidence = .{ .correlation = corr, .workspace = selection.workspace, .action_digest = "exact-digest", .scope = "synthetic write", .expires_at = 100 };
const chunk: c.Observation = .{ .correlation = corr, .upstream_event = "chunk-1", .sequence = 7, .body = .{ .chunk = .{ .message = .{ .value = "assistant" }, .block = .{ .value = "block" }, .offset = 0, .text = "你好 👩🏽‍💻" } } };
const ack: c.Receipt = .{ .outcome = .acknowledged };
fn cfg(comptime q: usize, comptime calls: usize) f.Config {
    var result = config;
    result.discovery.limits.queue_frames = q;
    result.discovery.limits.call_frames = calls;
    return result;
}

test "Unicode lifecycle keeps duplicates, reordering, approval, unknown and exact counters" {
    const response: c.Request = .{ .respond_approval = .{ .correlation = corr, .decision = .allow, .action_digest = approval.action_digest } };
    const cancel: c.Request = .{ .cancel = .{ .correlation = corr, .reason = "stop" } };
    const script = [_]f.Step{
        .{ .expect = .{ .request = start, .receipt = ack } },
        .{ .emit = chunk },
        .{ .emit = chunk },
        .{ .emit = .{ .correlation = corr, .upstream_event = "approval", .sequence = 3, .body = .{ .approval = approval } } },
        .{ .barrier = "before reply" },
        .{ .expect = .{ .request = response, .receipt = ack } },
        .{ .native_action = {} },
        .{ .expect = .{ .request = cancel, .receipt = .{ .outcome = .unknown } } },
        .{ .at = 50 },
        .{ .emit = .{ .correlation = corr, .upstream_event = "disconnect", .body = .{ .disconnect = .{ .reason = "lost", .continuity = .unknown } } } },
        .{ .emit = .{ .correlation = corr, .upstream_event = "failure", .body = .{ .failure = .{ .code = "synthetic", .detail = "result lost" } } } },
    };
    var runtime = try f.Runtime(8, 8).init(cfg(8, 8), &script);
    try t.expectEqual(.ready, runtime.accountStatus("fixture").readiness);
    try t.expectEqual(.unavailable, runtime.accountStatus("other").readiness);
    try t.expect(c.equal(selection, (try runtime.resolveSelection(selection)).effective.?));
    _ = try runtime.start(start.start);
    try runtime.pump();
    const first = runtime.poll().?;
    try t.expect(c.equal(chunk, first));
    try t.expect(c.equal(chunk, runtime.poll().?));
    const a = runtime.poll().?;
    try t.expectEqualStrings("exact-digest", a.body.approval.action_digest);
    try t.expectEqual(@as(u64, 3), a.sequence);
    try t.expectError(error.BarrierMismatch, runtime.release("wrong"));
    try runtime.release("before reply");
    _ = try runtime.respondApproval(response.respond_approval);
    try runtime.pump();
    try t.expectEqual(@as(u64, 1), runtime.counters.X);
    try t.expectEqual(.unknown, (try runtime.cancel(cancel.cancel)).outcome);
    try runtime.advance(49);
    try runtime.pump();
    try t.expect(runtime.poll() == null);
    try t.expectError(error.ClockReversed, runtime.advance(48));
    try runtime.advance(50);
    try runtime.pump();
    try t.expectEqualStrings("lost", runtime.poll().?.body.disconnect.reason);
    try t.expectEqualStrings("synthetic", runtime.poll().?.body.failure.code);
    try t.expectEqualStrings("你好 👩🏽‍💻", first.body.chunk.text);
    try t.expect(c.equal(c.Counters{ .S = 1, .A = 1, .C = 1, .X = 1 }, runtime.counters));
    try t.expect(runtime.finished());
    try t.expect(c.equal(start, runtime.takeCall().?.request));
}

test "all call operations preserve exact session, correlation, receipts and no retry" {
    const requests = [_]c.Request{
        .{ .open = .{ .create = .{ .effect = corr.effect.?, .session = session.id, .selection = selection } } },
        .{ .open = .{ .existing = .{ .session = session, .after = .{ .value = "cursor" } } } },
        .{ .attach = .{ .session = session, .after = .{ .value = "cursor" } } },
        .{ .inspect = .{ .session = session, .run = corr.run, .effect = corr.effect, .turn = corr.upstream_turn } },
        .{ .message = .{ .correlation = corr, .message = .{ .value = "message" }, .content = "steer" } },
    };
    var script: [requests.len]f.Step = undefined;
    for (requests, 0..) |r, i| script[i] = .{ .expect = .{ .request = r, .receipt = .{ .outcome = .unknown, .session = session, .inspection = .unknown, .continuity = .unknown, .live_approval = approval } } };
    var runtime = try f.Runtime(1, 1).init(cfg(1, 1), &script);
    for (requests) |r| {
        const receipt = try runtime.dispatch(r);
        try t.expectEqual(.unknown, receipt.outcome);
        try t.expect(c.equal(approval, receipt.live_approval.?));
        try t.expectError(error.CallLogFull, runtime.dispatch(r));
        try t.expect(c.equal(r, runtime.takeCall().?.request));
    }
    try t.expect(c.equal(c.Counters{ .O = 1, .T = 2, .I = 1, .D = 1 }, runtime.counters));
    try t.expectError(error.ScriptFinished, runtime.dispatch(requests[0]));
    try t.expectEqual(@as(u64, 1), runtime.counters.O);
}

test "capability unknown and unsupported gate both attach paths without create fallback" {
    for ([_]c.Status{ .unknown, .unsupported }) |status| {
        var configuration = cfg(1, 1);
        configuration.discovery.capabilities[@intFromEnum(c.Capability.replay)].status = status;
        var runtime = try f.Runtime(1, 1).init(configuration, &.{});
        try t.expectError(error.CapabilityUnavailable, runtime.attach(.{ .session = session, .after = .{ .value = "c" } }));
        try t.expectError(error.CapabilityUnavailable, runtime.openSession(.{ .existing = .{ .session = session, .after = .{ .value = "c" } } }));
        try t.expect(c.equal(c.Counters{}, runtime.counters));
        try t.expectEqual(@as(usize, 0), runtime.position);
        inline for ([_]c.Capability{ .start, .approval, .cancel, .message, .inspect, .create, .attach, .selection, .workspace }) |capability| {
            var unavailable = cfg(1, 1);
            unavailable.discovery.capabilities[@intFromEnum(capability)].status = status;
            var blocked = try f.Runtime(1, 1).init(unavailable, &.{});
            const request: c.Request = switch (capability) {
                .start => start,
                .approval => .{ .respond_approval = .{ .correlation = corr, .decision = .deny, .action_digest = "exact" } },
                .cancel => .{ .cancel = .{ .correlation = corr, .reason = "cancel" } },
                .message => .{ .message = .{ .correlation = corr, .message = .{ .value = "m" }, .content = "text" } },
                .inspect => .{ .inspect = .{ .session = session } },
                .attach => .{ .attach = .{ .session = session } },
                else => .{ .open = .{ .create = .{ .effect = corr.effect.?, .session = session.id, .selection = selection } } },
            };
            try t.expectError(error.CapabilityUnavailable, blocked.dispatch(request));
            try t.expect(c.equal(c.Counters{}, blocked.counters));
        }
    }
}

test "queue byte and frame admission is bounded and reusable without losing steps" {
    const script = [_]f.Step{ .{ .emit = chunk }, .{ .emit = chunk }, .{ .emit = chunk } };
    var configuration = cfg(1, 1);
    configuration.discovery.limits.queue_bytes = c.frameBytes(chunk);
    var runtime = try f.Runtime(1, 1).init(configuration, &script);
    for (0..3) |i| {
        if (i < 2) try t.expectError(error.QueueFull, runtime.pump()) else try runtime.pump();
        try t.expectEqual(c.frameBytes(chunk), runtime.observation_bytes);
        try t.expect(c.equal(chunk, runtime.poll().?));
        try t.expectEqual(@as(usize, 0), runtime.observation_bytes);
    }
    configuration.discovery.limits.queue_bytes -= 1;
    runtime = try f.Runtime(1, 1).init(configuration, &script);
    try t.expectError(error.QueueFull, runtime.pump());
    try t.expectEqual(@as(usize, 0), runtime.position);
    configuration = cfg(1, 1);
    configuration.discovery.limits.frame_bytes = c.frameBytes(chunk) - 1;
    configuration.discovery.limits.chunk_bytes = 1;
    runtime = try f.Runtime(1, 1).init(configuration, &script);
    try t.expectError(error.FrameTooLarge, runtime.pump());
    configuration = cfg(1, 1);
    configuration.discovery.limits.chunk_bytes = 1;
    runtime = try f.Runtime(1, 1).init(configuration, &script);
    try t.expectError(error.ChunkTooLarge, runtime.pump());
}

test "mismatch, invalid correlation, selection failures and caller string lifetime" {
    const script = [_]f.Step{.{ .expect = .{ .request = start, .receipt = ack } }};
    var runtime = try f.Runtime(1, 1).init(cfg(1, 1), &script);
    var bad = start;
    bad.start.correlation.effect = null;
    try t.expectError(error.InvalidCorrelation, runtime.dispatch(bad));
    bad = start;
    bad.start.correlation.run = .{ .value = "other" };
    try t.expectError(error.UnexpectedRequest, runtime.dispatch(bad));
    try t.expectEqual(@as(usize, 0), runtime.position);
    const text = try t.allocator.dupe(u8, start.start.prompt);
    var transient = start;
    transient.start.prompt = text;
    _ = try runtime.dispatch(transient);
    t.allocator.free(text);
    try t.expectEqualStrings(start.start.prompt, runtime.takeCall().?.request.start.prompt);
    var requested = selection;
    requested.model_id = "silent fallback forbidden";
    try t.expectError(error.SelectionUnavailable, runtime.resolveSelection(requested));
    requested = selection;
    requested.account_ref = "missing";
    try t.expectError(error.AccountUnavailable, runtime.resolveSelection(requested));
    var configuration = cfg(1, 1);
    configuration.selection.effective = null;
    var unverified = try f.Runtime(1, 1).init(configuration, &.{});
    try t.expect((try unverified.resolveSelection(selection)).effective == null);
    try t.expectError(error.SelectionUnavailable, unverified.openSession(.{ .create = .{ .effect = corr.effect.?, .session = session.id, .selection = selection } }));
}

test "historical completion preserves correlation without start and validates capability limits" {
    var configuration = cfg(1, 1);
    configuration.discovery.capabilities[@intFromEnum(c.Capability.start)].status = .unsupported;
    const script = [_]f.Step{.{ .emit = .{ .correlation = corr, .upstream_event = "old-terminal", .body = .{ .completed = {} } } }};
    var runtime = try f.Runtime(1, 1).init(configuration, &script);
    try runtime.pump();
    const observed = runtime.poll().?;
    try t.expect(c.equal(corr, observed.correlation));
    try t.expectEqualStrings("old-terminal", observed.upstream_event);
    try t.expectEqual(.completed, std.meta.activeTag(observed.body));
    try t.expect(runtime.poll() == null);
    configuration.discovery.limits.queue_frames = 2;
    try t.expectError(error.InvalidLimits, f.Runtime(1, 1).init(configuration, &.{}));
    configuration = cfg(1, 1);
    configuration.discovery.capabilities[@intFromEnum(c.Capability.usage)].status = .supported;
    try t.expectError(error.CapabilityUnavailable, f.Runtime(1, 1).init(configuration, &.{}));
}
