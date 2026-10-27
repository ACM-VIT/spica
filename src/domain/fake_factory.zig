//! Deterministic native fixture backend on the same factory/session path as
//! external runtimes. Every instance owns its selection and observation queue.
const std = @import("std");
const c = @import("../contract.zig");
const common = @import("../runtime/adapter.zig");
const fake = @import("../runtime/fake.zig");
const prompt = @import("../runtime/prompt.zig");
const Instance = struct {
    arena: std.heap.ArenaAllocator,
    turn_arena: std.heap.ArenaAllocator,
    selection: c.Selection,
    session: c.RuntimeSessionId,
    correlation: ?c.Correlation = null,
    opened: bool = false,
    active: bool = false,
    awaiting_approval: bool = false,
    queue: [8]c.Observation = undefined,
    head: usize = 0,
    count: usize = 0,
    stopped: bool = false,
    fn cast(context: *anyopaque) *Instance {
        return @ptrCast(@alignCast(context));
    }
    fn discover(_: *anyopaque) c.Discovery {
        return .{ .capabilities = fake.defaultCapabilities(), .limits = .{} };
    }
    fn account(context: *anyopaque) c.Account {
        return .{ .reference = cast(context).selection.account_ref, .readiness = .ready };
    }
    fn resolve(_: *anyopaque, selection: c.Selection) c.SelectionResult {
        return .{ .requested = selection, .effective = selection, .readiness = .ready };
    }
    fn emit(self: *Instance, name: []const u8, body: @FieldType(c.Observation, "body")) !void {
        if (self.count == self.queue.len) return error.QueueFull;
        var correlation = self.correlation.?;
        if (body == .chunk) {
            correlation.tool = null;
            correlation.approval = null;
            correlation.upstream_tool = null;
            correlation.upstream_request = null;
        }
        self.queue[(self.head + self.count) % self.queue.len] = .{ .correlation = correlation, .upstream_event = name, .body = body };
        self.count += 1;
    }
    fn dispatch(context: *anyopaque, _: std.mem.Allocator, request: c.Request) !c.Receipt {
        const self = cast(context);
        switch (request) {
            .open => |open| {
                switch (open) {
                    .create => |create_request| if (!c.equal(create_request.session, self.session) or !c.equal(create_request.selection, self.selection)) return error.InvalidCorrelation,
                    .existing => |existing| if (!c.equal(existing.session.id, self.session) or !std.mem.eql(u8, existing.session.upstream.value, self.session.value)) return error.InvalidCorrelation,
                }
                self.opened = true;
                return .{ .outcome = .acknowledged, .session = .{ .id = self.session, .instance = .{ .value = self.session.value }, .upstream = .{ .value = self.session.value } }, .continuity = if (open == .existing) .proven else .not_requested };
            },
            .start => |start| {
                prompt.validate(start) catch return error.FrameTooLarge;
                var metadata = request;
                metadata.start.prompt = "";
                if (c.frameBytes(metadata) > discover(self).limits.frame_bytes) return error.FrameTooLarge;
                if (!self.opened or !c.equal(start.correlation.session, self.session) or start.correlation.run == null or start.correlation.effect == null) return error.InvalidCorrelation;
                if (self.active or self.count != 0) return error.QueueFull;
                // Queued observations borrow this turn's storage. Reuse it only
                // after the prior turn is terminal and every observation copied.
                _ = self.turn_arena.reset(.retain_capacity);
                const retained = self.turn_arena.allocator();
                var correlation = try common.clone(retained, start.correlation);
                const run = correlation.run.?.value;
                correlation.effect = null;
                correlation.tool = .{ .value = try std.fmt.allocPrint(retained, "{s}-tool", .{run}) };
                correlation.approval = .{ .value = try std.fmt.allocPrint(retained, "{s}-approval", .{run}) };
                correlation.upstream_turn = .{ .value = run };
                correlation.upstream_tool = correlation.tool.?.value;
                correlation.upstream_request = correlation.approval.?.value;
                self.correlation = correlation;
                self.active = true;
                self.awaiting_approval = true;
                try self.emit("selection", .{ .selection = .{ .requested = self.selection, .effective = self.selection, .readiness = .ready } });
                try self.emit("response", .{ .chunk = .{ .message = .{ .value = "fake-message" }, .block = .{ .value = "fake-text" }, .offset = 0, .text = "Fake response: café 世界 👩‍💻\n\n```zig\nconst answer = 42;\n```\n" } });
                try self.emit("tool-start", .{ .tool_started = .{ .name = "workspace.inspect", .action_digest = "fake-v1-inspect" } });
                try self.emit("approval", .{ .approval = .{ .correlation = correlation, .workspace = self.selection.workspace, .action_digest = "fake-v1-inspect", .scope = "one workspace inspection" } });
            },
            .respond_approval => |reply| {
                const current = self.correlation orelse return error.InvalidCorrelation;
                if (!self.active or !self.awaiting_approval or !c.equal(reply.correlation.session, self.session) or
                    !c.equal(reply.correlation.run, current.run) or !c.equal(reply.correlation.approval, current.approval) or
                    !c.equal(reply.correlation.upstream_request, current.upstream_request) or
                    !std.mem.eql(u8, reply.action_digest, "fake-v1-inspect")) return error.InvalidCorrelation;
                if (self.count > self.queue.len - 2) return error.QueueFull;
                try self.emit("tool-result", .{ .tool_completed = .{ .outcome = if (reply.decision == .allow) .succeeded else .failed, .result = if (reply.decision == .allow) "Inspection approved; temporary workspace inspected." else "Inspection denied; no action executed." } });
                try self.emit("completed", .completed);
                self.active = false;
                self.awaiting_approval = false;
            },
            .cancel => |cancel| {
                if (!c.equal(cancel.correlation.session, self.session) or cancel.correlation.run == null) return error.InvalidCorrelation;
                if (self.active and !c.equal(cancel.correlation.run, self.correlation.?.run)) return error.InvalidCorrelation;
                if (self.count == self.queue.len) return error.QueueFull;
                if (!self.active and self.count == 0) _ = self.turn_arena.reset(.retain_capacity);
                self.correlation = try common.clone(self.turn_arena.allocator(), c.Correlation{ .session = cancel.correlation.session, .run = cancel.correlation.run });
                try self.emit("cancelled", .{ .cancelled = .{ .tools_stopped = true } });
                self.active = false;
                self.awaiting_approval = false;
            },
            else => return .{ .outcome = .rejected, .detail = "Fake fixture does not support live steering or recovery continuity" },
        }
        return .{ .outcome = .acknowledged };
    }
    fn pump(_: *anyopaque) !void {}
    fn poll(context: *anyopaque, allocator: std.mem.Allocator) !?c.Observation {
        const self = cast(context);
        if (self.count == 0) return null;
        const result = try common.clone(allocator, self.queue[self.head]);
        self.head = (self.head + 1) % self.queue.len;
        self.count -= 1;
        return result;
    }
    fn shutdown(context: *anyopaque) void {
        const self = cast(context);
        std.debug.assert(!self.stopped);
        self.stopped = true;
    }
    const vtable: common.Adapter.VTable = .{ .discover = discover, .accountStatus = account, .resolveSelection = resolve, .dispatch = dispatch, .pump = pump, .poll = poll, .shutdown = shutdown };
};
fn factoryDiscover(_: *anyopaque, _: c.Selection) c.Discovery {
    var result = Instance.discover(undefined);
    result.capabilities[@intFromEnum(c.Capability.message)].status = .unsupported;
    return result;
}
fn factoryAccount(_: *anyopaque, selection: c.Selection) c.Account {
    return .{ .reference = selection.account_ref, .readiness = .ready };
}
fn create(_: *anyopaque, allocator: std.mem.Allocator, selection: c.Selection, _: []const u8, session: c.RuntimeSessionId, _: ?common.Bridge) !common.Adapter {
    const instance = try allocator.create(Instance);
    errdefer allocator.destroy(instance);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const retained_selection = try common.clone(arena.allocator(), selection);
    const retained_session = try common.clone(arena.allocator(), session);
    instance.* = .{ .arena = arena, .turn_arena = std.heap.ArenaAllocator.init(allocator), .selection = retained_selection, .session = retained_session };
    return .{ .context = instance, .vtable = &Instance.vtable };
}
fn destroy(_: *anyopaque, allocator: std.mem.Allocator, adapter: common.Adapter) void {
    const instance = Instance.cast(adapter.context);
    std.debug.assert(instance.stopped);
    instance.turn_arena.deinit();
    instance.arena.deinit();
    allocator.destroy(instance);
}
pub fn factory(context: *anyopaque) common.Factory {
    return .{ .context = context, .vtable = &.{ .discover = factoryDiscover, .accountStatus = factoryAccount, .resolveSelection = Instance.resolve, .create = create, .destroy = destroy } };
}

test "fake factory Start validates dedicated prompts before changing session state" {
    var context: u8 = 0;
    const backend = factory(&context);
    const allocator = std.testing.allocator;
    const selection = c.fakeSelection(.{ .value = "workspace" });
    const session: c.RuntimeSessionId = .{ .value = "prompt-session" };
    const bytes = try allocator.alloc(u8, prompt.max_bytes + 1);
    defer allocator.free(bytes);
    for ([_][]const u8{ "x", "🙂", "\x01" }) |unit| {
        for (0..prompt.max_bytes / unit.len) |index| @memcpy(bytes[index * unit.len ..][0..unit.len], unit);
        bytes[prompt.max_bytes] = 'x';
        const adapter = try backend.create(allocator, selection, "/tmp", session, null);
        defer {
            adapter.shutdown();
            backend.destroy(allocator, adapter);
        }
        _ = try adapter.dispatch(allocator, .{ .open = .{ .create = .{ .effect = .{ .value = "open" }, .session = session, .selection = selection } } });
        const instance = Instance.cast(adapter.context);
        const start: c.Request = .{ .start = .{ .correlation = .{ .session = session, .run = .{ .value = "run" }, .effect = .{ .value = "start" } }, .prompt = bytes[0..prompt.max_bytes] } };
        var bad = start;
        bad.start.prompt = bytes;
        try std.testing.expectError(error.FrameTooLarge, adapter.dispatch(allocator, bad));
        bad.start.prompt = "\xff";
        try std.testing.expectError(error.FrameTooLarge, adapter.dispatch(allocator, bad));
        bad.start.prompt = "";
        try std.testing.expectError(error.FrameTooLarge, adapter.dispatch(allocator, bad));
        bad = start;
        bad.start.prompt_ref = .{ .id = "unresolved", .byte_length = prompt.max_bytes, .sha256 = [_]u8{0} ** 32 };
        try std.testing.expectError(error.FrameTooLarge, adapter.dispatch(allocator, bad));
        bad = start;
        bad.start.correlation.session.value = bytes[0..prompt.max_bytes];
        try std.testing.expectError(error.FrameTooLarge, adapter.dispatch(allocator, bad));
        try std.testing.expect(!instance.active and instance.correlation == null);
        try std.testing.expectEqual(@as(usize, 0), instance.turn_arena.queryCapacity());
        try std.testing.expect((try adapter.poll(allocator)) == null);
        _ = try adapter.dispatch(allocator, start);
        try std.testing.expect(instance.active);
        try std.testing.expectEqual(@as(usize, 4), instance.count);
        var observed = std.heap.ArenaAllocator.init(allocator);
        defer observed.deinit();
        while (try adapter.poll(observed.allocator())) |event| {
            try std.testing.expectEqualStrings("run", event.correlation.run.?.value);
        }
    }
}

test "fake session turns retain distinct authority with bounded storage and cancel the requested run" {
    var context: u8 = 0;
    const backend = factory(&context);
    const allocator = std.testing.allocator;
    const selection = c.fakeSelection(.{ .value = "workspace" });
    const session: c.RuntimeSessionId = .{ .value = "same-session" };
    const adapter = try backend.create(allocator, selection, "/tmp", session, null);
    defer {
        adapter.shutdown();
        backend.destroy(allocator, adapter);
    }
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    _ = try adapter.dispatch(allocator, .{ .open = .{ .create = .{ .effect = .{ .value = "open" }, .session = session, .selection = selection } } });
    const instance = Instance.cast(adapter.context);
    var capacity: usize = 0;
    var first_approval: ?c.ApprovalEvidence = null;
    var history = std.heap.ArenaAllocator.init(allocator);
    defer history.deinit();
    for (0..128) |turn| {
        _ = scratch.reset(.retain_capacity);
        const retained = scratch.allocator();
        var run_buffer: [32]u8 = undefined;
        const run = try std.fmt.bufPrint(&run_buffer, "turn-{d:0>4}", .{turn});
        const start: c.Request = .{ .start = .{ .correlation = .{ .session = session, .run = .{ .value = run }, .effect = .{ .value = "start" } }, .prompt = "bounded synthetic turn" } };
        _ = try adapter.dispatch(allocator, start);
        // Pending bytes cannot be discarded by a new start.
        try std.testing.expectError(error.QueueFull, adapter.dispatch(allocator, start));
        var approval: ?c.ApprovalEvidence = null;
        var count: usize = 0;
        while (try adapter.poll(retained)) |observation| {
            count += 1;
            try std.testing.expectEqualStrings(run, observation.correlation.run.?.value);
            try std.testing.expect(observation.correlation.effect == null);
            if (observation.body == .approval) approval = observation.body.approval;
        }
        try std.testing.expectEqual(@as(usize, 4), count);
        const evidence = approval.?;
        if (turn == 0) first_approval = try common.clone(history.allocator(), evidence) else {
            try std.testing.expect(!c.equal(first_approval.?.correlation.approval, evidence.correlation.approval));
            try std.testing.expect(!c.equal(first_approval.?.correlation.upstream_request, evidence.correlation.upstream_request));
            try std.testing.expectError(error.InvalidCorrelation, adapter.dispatch(allocator, .{ .respond_approval = .{ .correlation = first_approval.?.correlation, .action_digest = first_approval.?.action_digest, .decision = .allow } }));
        }
        _ = try adapter.dispatch(allocator, .{ .respond_approval = .{ .correlation = evidence.correlation, .action_digest = evidence.action_digest, .decision = .allow } });
        count = 0;
        while (try adapter.poll(retained)) |observation| {
            count += 1;
            try std.testing.expectEqualStrings(run, observation.correlation.run.?.value);
        }
        try std.testing.expectEqual(@as(usize, 2), count);
        if (turn == 0) capacity = instance.turn_arena.queryCapacity() else try std.testing.expectEqual(capacity, instance.turn_arena.queryCapacity());
    }
    // A later turn may be cancelled before Start; correlation must not come
    // from the previously completed turn still held in the fake instance.
    _ = try adapter.dispatch(allocator, .{ .cancel = .{ .correlation = .{ .session = session, .run = .{ .value = "cancel-before-start" }, .effect = .{ .value = "cancel" } }, .reason = "stop requested turn" } });
    const cancelled = (try adapter.poll(scratch.allocator())).?;
    try std.testing.expect(cancelled.body == .cancelled);
    try std.testing.expectEqualStrings("cancel-before-start", cancelled.correlation.run.?.value);
    try std.testing.expect(cancelled.correlation.tool == null and cancelled.correlation.approval == null and cancelled.correlation.effect == null);
    try std.testing.expect((try adapter.poll(scratch.allocator())) == null);
}
