//! Real ACP -> public Host -> durable SQLite -> public reopen consumer.
const std = @import("std");
const domain = @import("domain.zig");
const t = domain.types;
const provider = @import("runtime/opencode.zig");
const transport = @import("runtime/transport.zig");
extern "c" fn usleep(u32) c_int;
const Consumer = struct {
    host: *domain.Host,
    allocator: std.mem.Allocator,
    minimum_bytes: usize = 1,
    fn next(self: *Consumer) !t.Output {
        var outputs: [1]t.Output = undefined;
        const bytes = try self.allocator.alloc(u8, 262144);
        for (0..6000) |_| {
            const result = self.host.drain(&outputs, bytes);
            if (result.output_count != 0) return outputs[0];
            if (result.required_bytes_for_next != 0) return error.OutputTooLarge;
            _ = usleep(10000);
        }
        return error.HostOutputTimeout;
    }
    fn command(self: *Consumer, envelope: t.CommandEnvelope) !t.Receipt {
        _ = try self.host.submit(envelope);
        const output = try self.next();
        if (output != .command_receipt) return error.MissingReceipt;
        if (output.command_receipt.receipt.outcome != .accepted) {
            std.debug.print("Rejected command: {any}\n", .{output.command_receipt.receipt});
            return error.CommandRejected;
        }
        return output.command_receipt.receipt;
    }
    fn query(self: *Consumer, request: t.Query) !t.QueryPage {
        _ = try self.host.query(request);
        const output = try self.next();
        if (output != .query_page) return error.MissingQueryPage;
        return output.query_page.page;
    }
    fn verify(self: *Consumer, thread: t.ThreadId) !void {
        const runs = try self.query(.{ .runs = .{ .thread = thread } });
        if (runs.items.len != 1 or runs.items[0].run.state != .completed) return error.NotDurablyCompleted;
        const messages = try self.query(.{ .messages = .{ .thread = thread } });
        if (messages.items.len != 2) return error.MissingMessages;
        const assistant = messages.items[1].message;
        if (assistant.blocks.len != 1) return error.UnexpectedBlocks;
        const descriptor = assistant.blocks[0];
        const content = try self.query(.{ .content = .{ .block = descriptor.block_id, .start_byte = 0, .end_byte = descriptor.committed_bytes } });
        if (content.items.len != 1 or std.mem.indexOf(u8, content.items[0].content.bytes, "SPICA_HOST_OK") == null) return error.MissingDurableLiveText;
        std.debug.print("Durable assistant bytes={d}; content={s}\n", .{ descriptor.committed_bytes, content.items[0].content.bytes });
        if (descriptor.committed_bytes < self.minimum_bytes) return error.MissingLargeContent;
    }
};
pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len != 4) return error.ExpectedExecutableWorkspaceAndState;
    const executable = try a.dupeZ(u8, args[1]);
    const cwd = try a.dupeZ(u8, args[2]);
    const state = args[3];
    var consumer: Consumer = .{ .host = try domain.Host.create(a, io, .{ .state_directory = state }), .allocator = a };
    const project = (try consumer.command(.{ .command_id = .{ .value = "opencode-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "isolated OpenCode consumer" } } })).entity_ids.project.?;
    const workspace = (try consumer.command(.{ .command_id = .{ .value = "opencode-workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = .{ .canonical_root = cwd, .filesystem_identity = "opencode-disposable", .repository_identity = "", .checkout_identity = "opencode-disposable", .expected_branch = "", .base_revision = "", .non_git = true } } } })).entity_ids.workspace.?;
    const thread = (try consumer.command(.{ .command_id = .{ .value = "opencode-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    consumer.host.destroy();
    const selection: t.adapter.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "opencode", .model_id = "big-pickle", .effort = "default", .account_ref = "disposable-free-provider", .workspace = workspace };
    var runtime: provider.Runtime = undefined;
    var process = try transport.Transport.init(a, .{ .argv = &.{ executable, "acp" }, .cwd = cwd });
    runtime.init(a, process, .{ .selection = selection, .cwd = cwd, .instance = .{ .value = "opencode-durable-consumer" }, .account = .{ .reference = selection.account_ref, .readiness = .unknown } }) catch |err| {
        process.deinit();
        return err;
    };
    // Main owns instance; Host exclusively uses it after creation.
    var owned_by_host = false;
    defer if (!owned_by_host) runtime.shutdown();
    for (0..1000) |_| {
        try runtime.pump();
        _ = try runtime.poll(a);
        if (runtime.discover().capabilities[@intFromEnum(t.adapter.Capability.create)].status == .supported) break;
        _ = usleep(10000);
    } else return error.InitializeTimeout;
    consumer.host = try domain.Host.create(a, io, .{ .state_directory = state, .adapter = runtime.asAdapter(), .selection = selection, .workspace_root = cwd });
    owned_by_host = true;
    var host_live = true;
    defer if (host_live) consumer.host.destroy();
    consumer.minimum_bytes = 2049;
    _ = try consumer.command(.{ .command_id = .{ .value = "opencode-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = "Echo the entire following text verbatim, not a summary. Do not count or abbreviate repeated characters. Do not use tools or formatting.\nSPICA_HOST_OK\n" ++ ("x" ** 2500), .selection = selection } } });
    for (0..600) |_| {
        const runs = try consumer.query(.{ .runs = .{ .thread = thread } });
        if (runs.items.len == 1) {
            const status = runs.items[0].run.state;
            if (status == .completed) break;
            if (status == .failed or status == .unknown or status == .interrupted) {
                std.debug.print("Run state={any}\n", .{status});
                return error.ProviderRunFailed;
            }
        }
        _ = usleep(100000);
    } else return error.InferenceTimeout;
    try consumer.verify(thread);
    consumer.host.destroy();
    host_live = false;
    consumer.host = try domain.Host.create(a, io, .{ .state_directory = state });
    host_live = true;
    try consumer.verify(thread);
    std.debug.print("PASS actual ACP -> public Host durable inference -> shutdown -> reopen snapshots; explicit free opencode/big-pickle; no subscription entitlement claim\n", .{});
}
