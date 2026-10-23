//! Standalone public Host and storage consumers using isolated temporary state.
//! Abrupt modes deliberately bypass Zig defers to exercise SQLite recovery.
const std = @import("std");
const domain = @import("domain");
const Store = domain.store.Store;
const t = domain.types;
extern "c" fn _exit(status: c_int) noreturn;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len != 4) return error.UsageExpectedStateDirectoryModeAndName;
    if (std.mem.startsWith(u8, args[2], "host-")) return hostSmoke(io, args[1], args[2]);
    var store = try Store.open(io, args[1]);
    defer store.close() catch @panic("storage consumer close failed");
    const mode = args[2];
    const command: t.CommandEnvelope = .{ .command_id = .{ .value = "storage-smoke-command" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = args[3] } } };
    var canonical_buffer: [64 * 1024]u8 = undefined;
    const canonical = try t.encode(command, &canonical_buffer);
    var receipt_buffer: [4096]u8 = undefined;
    if (std.mem.eql(u8, mode, "read")) {
        const receipt = try store.lookupCommand(command.command_id.value, canonical, &receipt_buffer);
        try std.Io.File.stdout().writeStreamingAll(io, receipt orelse "absent");
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }
    const crash_before = std.mem.eql(u8, mode, "crash-uncommitted");
    const crash_after = std.mem.eql(u8, mode, "crash-committed");
    if (!crash_before and !crash_after and !std.mem.eql(u8, mode, "write")) return error.UnknownMode;
    // Exact redelivery returns the original bytes, not new IDs/revisions/events.
    if (try store.lookupCommand(command.command_id.value, canonical, &receipt_buffer)) |receipt| {
        try std.Io.File.stdout().writeStreamingAll(io, receipt);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }
    try store.begin();
    errdefer store.rollback() catch {};
    const sequence = try store.nextSequence();
    const project = t.ProjectId{ .value = "storage-smoke-project" };
    try store.execute("INSERT INTO projects(id,revision,display_name) VALUES(?,1,?)", &.{ .{ .text = project.value }, .{ .text = args[3] } });
    const revisions = [_]t.CommittedRevision{.{ .target = .{ .project = project }, .revision = 1 }};
    const receipt: t.Receipt = .{ .command_id = command.command_id, .outcome = .accepted, .entity_ids = .{ .project = project }, .committed_revisions = &revisions, .commit_sequence = sequence };
    const receipt_bytes = try t.encode(receipt, &receipt_buffer);
    try store.recordCommand(command.command_id.value, canonical, receipt_bytes, sequence);
    try store.appendEvent(.{ .event_id = .{ .value = "storage-smoke-event" }, .position = .{ .commit_sequence = sequence }, .aggregate = .{ .project = project }, .aggregate_revision = 1, .kind = "ProjectCreated", .causation_command_id = command.command_id, .payload = "{}" });
    if (crash_before) _exit(73);
    try store.commit();
    if (crash_after) _exit(74);
    try std.Io.File.stdout().writeStreamingAll(io, receipt_bytes);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

const Consumer = struct {
    host: *domain.Host = undefined,
    io: std.Io,
    event: std.Io.Event = .unset,
    arena: std.heap.ArenaAllocator,
    fn wake(context: ?*anyopaque) void {
        const self: *Consumer = @ptrCast(@alignCast(context.?));
        self.event.set(self.io);
    }
    fn next(self: *Consumer) !t.Output {
        var output: [1]t.Output = undefined;
        const bytes = try self.arena.allocator().alloc(u8, 1024 * 1024);
        while (true) {
            self.event.reset();
            const result = self.host.drain(&output, bytes);
            if (result.output_count != 0) return output[0];
            if (result.required_bytes_for_next != 0) return error.OutputTooLarge;
            self.event.waitUncancelable(self.io);
        }
    }
    fn command(self: *Consumer, envelope: t.CommandEnvelope) !t.Receipt {
        _ = try self.host.submit(envelope);
        const output = try self.next();
        if (output != .command_receipt or output.command_receipt.receipt.outcome != .accepted) return error.CommandFailed;
        return output.command_receipt.receipt;
    }
    fn query(self: *Consumer, q: t.Query) !t.QueryPage {
        _ = try self.host.query(q);
        const output = try self.next();
        if (output != .query_page) return error.QueryFailed;
        return output.query_page.page;
    }
};

fn hostSmoke(io: std.Io, state_directory: []const u8, mode: []const u8) !void {
    var consumer: Consumer = .{ .io = io, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer consumer.arena.deinit();
    consumer.host = try domain.Host.create(std.heap.page_allocator, io, .{ .state_directory = state_directory, .wake = Consumer.wake, .wake_context = &consumer });
    defer consumer.host.destroy();
    const project = (try consumer.command(.{ .command_id = .{ .value = "smoke-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "temporary Host smoke" } } })).entity_ids.project.?;
    const workspace = (try consumer.command(.{ .command_id = .{ .value = "smoke-workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try domain.workspace_binding.capture(consumer.arena.allocator(), io, "/tmp") } } })).entity_ids.workspace.?;
    const thread = (try consumer.command(.{ .command_id = .{ .value = "smoke-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    const selection: t.adapter.Selection = .{ .workspace = workspace, .model_provider = "fake", .model_id = "smoke", .effort = "none", .account_ref = "temporary" };
    const sent = try consumer.command(.{ .command_id = .{ .value = "smoke-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "Hello café 世界", .selection = selection } } });
    const run = sent.entity_ids.run.?;
    const approvals = try consumer.query(.{ .approvals = .{ .run = run } });
    if (approvals.items.len != 1) return error.MissingApproval;
    const approval = approvals.items[0].approval;
    if (std.mem.eql(u8, mode, "host-crash-approval")) {
        if (!approval.live or approval.state != .pending) return error.NoLiveApproval;
        try std.Io.File.stdout().writeStreamingAll(io, "{\"stage\":\"durable-approval\",\"exit\":75}\n");
        _exit(75);
    }
    if (std.mem.eql(u8, mode, "host-recover")) {
        const runs = try consumer.query(.{ .runs = .{ .thread = thread } });
        if (runs.items.len != 1 or runs.items[0].run.state != .interrupted or approval.live or approval.state != .invalidated) return error.UnsafeRecovery;
        const effects = try consumer.query(.{ .effects = .{ .run = run } });
        if (effects.items.len != 2) return error.DuplicateDispatchIntent;
        try std.Io.File.stdout().writeStreamingAll(io, "{\"recovery\":\"interrupted\",\"approval\":\"invalidated\",\"effects\":2,\"replayed\":false}\n");
        return;
    }
    if (!std.mem.eql(u8, mode, "host-flow")) return error.UnknownMode;
    const messages = try consumer.query(.{ .messages = .{ .thread = thread } });
    const assistant = messages.items[1].message;
    const content = try consumer.query(.{ .content = .{ .block = assistant.blocks[0].block_id, .start_byte = 0, .end_byte = assistant.blocks[0].committed_bytes } });
    if (std.mem.indexOf(u8, content.items[0].content.bytes, "世界") == null) return error.MissingStream;
    _ = try consumer.command(.{ .command_id = .{ .value = "smoke-allow" }, .target = .{ .approval = approval.id }, .expected_revision = .{ .revision = approval.revision }, .payload = .{ .approval_respond = .{ .decision = .allow, .action_digest = approval.evidence.action_digest } } });
    const completed = try consumer.query(.{ .runs = .{ .thread = thread } });
    if (completed.items[0].run.state != .completed) return error.NotCompleted;
    const second = try consumer.command(.{ .command_id = .{ .value = "smoke-send-2" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 2 }, .payload = .{ .thread_send = .{ .text = "Cancel this run", .selection = selection } } });
    const active = try consumer.query(.{ .runs = .{ .thread = thread } });
    _ = try consumer.command(.{ .command_id = .{ .value = "smoke-cancel" }, .target = .{ .run = second.entity_ids.run.? }, .expected_revision = .{ .revision = active.items[1].run.revision }, .payload = .{ .run_cancel = .{ .reason = "consumer cancellation" } } });
    const cancelled = try consumer.query(.{ .runs = .{ .thread = thread } });
    if (cancelled.items[1].run.state != .cancelled) return error.NotCancelled;
    try std.Io.File.stdout().writeStreamingAll(io, "{\"prompt\":true,\"unicode_stream\":true,\"tool_approval\":\"allowed\",\"run\":\"completed\",\"second_run\":\"cancelled\"}\n");
}
