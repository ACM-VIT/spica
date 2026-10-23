//! Deterministic native fixture backend on the same factory/session path as
//! external runtimes. Every instance owns its selection and observation queue.
const std = @import("std");
const c = @import("../contract.zig");
const common = @import("../runtime/adapter.zig");
const fake = @import("../runtime/fake.zig");
const Instance = struct {
    arena: std.heap.ArenaAllocator,
    selection: c.Selection,
    session: c.RuntimeSessionId,
    correlation: ?c.Correlation = null,
    tool: c.ToolCallId,
    approval: c.ApprovalId,
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
            .open => return .{ .outcome = .acknowledged, .session = .{ .id = self.session, .instance = .{ .value = self.session.value }, .upstream = .{ .value = self.session.value } } },
            .start => |start| {
                var correlation = try common.clone(self.arena.allocator(), start.correlation);
                correlation.effect = null;
                correlation.tool = self.tool;
                correlation.approval = self.approval;
                correlation.upstream_tool = "fake-tool";
                correlation.upstream_request = "fake-approval";
                self.correlation = correlation;
                try self.emit("selection", .{ .selection = .{ .requested = self.selection, .effective = self.selection, .readiness = .ready } });
                try self.emit("response", .{ .chunk = .{ .message = .{ .value = "fake-message" }, .block = .{ .value = "fake-text" }, .offset = 0, .text = "Fake response: café 世界 👩‍💻\n\n```zig\nconst answer = 42;\n```\n" } });
                try self.emit("tool-start", .{ .tool_started = .{ .name = "workspace.inspect", .action_digest = "fake-v1-inspect" } });
                try self.emit("approval", .{ .approval = .{ .correlation = correlation, .workspace = self.selection.workspace, .action_digest = "fake-v1-inspect", .scope = "one workspace inspection" } });
            },
            .respond_approval => |reply| {
                try self.emit("tool-result", .{ .tool_completed = .{ .outcome = if (reply.decision == .allow) .succeeded else .failed, .result = if (reply.decision == .allow) "Inspection approved; temporary workspace inspected." else "Inspection denied; no action executed." } });
                try self.emit("completed", .completed);
            },
            .cancel => |cancel| {
                if (self.correlation == null) self.correlation = try common.clone(self.arena.allocator(), cancel.correlation);
                try self.emit("cancelled", .{ .cancelled = .{ .tools_stopped = true } });
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
    const tool = try std.fmt.allocPrint(arena.allocator(), "{s}-tool", .{session.value});
    const approval = try std.fmt.allocPrint(arena.allocator(), "{s}-approval", .{session.value});
    instance.* = .{ .arena = arena, .selection = retained_selection, .session = retained_session, .tool = .{ .value = tool }, .approval = .{ .value = approval } };
    return .{ .context = instance, .vtable = &Instance.vtable };
}
fn destroy(_: *anyopaque, allocator: std.mem.Allocator, adapter: common.Adapter) void {
    const instance = Instance.cast(adapter.context);
    std.debug.assert(instance.stopped);
    instance.arena.deinit();
    allocator.destroy(instance);
}
pub fn factory(context: *anyopaque) common.Factory {
    return .{ .context = context, .vtable = &.{ .discover = factoryDiscover, .accountStatus = factoryAccount, .resolveSelection = Instance.resolve, .create = create, .destroy = destroy } };
}
