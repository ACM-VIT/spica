//! Throwaway public Host consumer: metadata/setup/selection only, never inference.
const std = @import("std");
const domain = @import("domain.zig");
const t = domain.types;
const c = t.adapter;
const NativeFactory = @import("runtime/native_factory.zig").NativeFactory;
const Consumer = struct {
    host: *domain.Host,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    fn receive(self: *Consumer, ticket: t.Ticket) !t.Output {
        const start = @import("runtime/transport.zig").c.spica_monotonic_ms();
        const backing = try self.arena.allocator().alloc(u8, 2 * 1024 * 1024);
        while (@import("runtime/transport.zig").c.spica_monotonic_ms() - start < 45000) {
            var outputs: [1]t.Output = undefined;
            const drained = self.host.drain(&outputs, backing);
            if (drained.output_count != 0) {
                const actual = switch (outputs[0]) {
                    .command_receipt => |v| v.ticket,
                    .query_page => |v| v.ticket,
                    .failure => |v| v.ticket,
                    else => continue,
                };
                if (actual.value != ticket.value) continue;
                if (outputs[0] == .failure) return error.HostFailure;
                return outputs[0];
            }
            try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
        return error.HostTimeout;
    }
    fn command(self: *Consumer, id: []const u8, target: t.Target, expected: t.Precondition, payload: t.Payload) !t.Receipt {
        return (try self.receive(try self.host.submit(.{ .command_id = .{ .value = id }, .target = target, .expected_revision = expected, .payload = payload }))).command_receipt.receipt;
    }
    fn query(self: *Consumer, query_value: t.Query) !t.QueryPage {
        return (try self.receive(try self.host.query(query_value))).query_page.page;
    }
    fn requireAccepted(receipt: t.Receipt) !t.Receipt {
        if (receipt.outcome != .accepted) return error.CommandRejected;
        return receipt;
    }
};
pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try init.args.toSlice(allocator);
    if (args.len != 8) return error.ExpectedKindExecutableAccountWorkspaceStateProviderReport;
    const kind = std.meta.stringToEnum(c.RuntimeKind, args[1]) orelse return error.InvalidRuntime;
    const factory = try allocator.create(NativeFactory);
    factory.* = .{ .configs = &.{} };
    var consumer: Consumer = .{ .host = try domain.Host.create(std.heap.page_allocator, io, .{ .state_directory = args[5], .setup_factory = factory.asFactory() }), .io = io, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer consumer.arena.deinit();
    var host_live = true;
    defer if (host_live) consumer.host.destroy();
    _ = try Consumer.requireAccepted(try consumer.command("configure", .absent, .absent, .{ .runtime_configure = .{ .runtime_kind = kind, .executable = args[2], .account_directory = args[3], .workspace_root = args[4], .model_provider = args[6] } }));
    _ = try Consumer.requireAccepted(try consumer.command("refresh", .absent, .absent, .runtime_refresh));
    const status = (try consumer.query(.runtime_status)).items[0].runtime_status;
    const binding = status.binding orelse return error.WorkspaceUnavailable;
    const project = (try Consumer.requireAccepted(try consumer.command("project", .absent, .absent, .{ .project_create = .{ .display_name = "Catalog public consumer" } }))).entity_ids.project.?;
    const workspace = (try Consumer.requireAccepted(try consumer.command("workspace", .absent, .absent, .{ .workspace_register = .{ .project = project, .binding = binding } }))).entity_ids.workspace.?;
    const thread = (try Consumer.requireAccepted(try consumer.command("thread", .absent, .absent, .{ .thread_create = .{ .project = project, .workspace = workspace } }))).entity_ids.thread.?;
    const catalog = try consumer.query(.{ .models = .{ .workspace = workspace, .page = .{ .limit = 128 } } });
    if (catalog.items.len == 0) {
        std.debug.print("Catalog unavailable: {s}\n", .{status.reason});
        return error.CatalogUnavailable;
    }
    // Choose a different actual item if the runtime reports more than one.
    const model = catalog.items[@min(1, catalog.items.len - 1)].model;
    _ = try Consumer.requireAccepted(try consumer.command("select", .{ .thread = thread }, .{ .revision = 1 }, .{ .thread_select = .{ .selection = model.selection } }));
    const persisted = (try consumer.query(.{ .thread = thread })).items[0].thread;
    if (!c.equal(model.selection, persisted.selection.?)) return error.SelectionChanged;
    var stale = model.selection;
    stale.effort = "not-a-negotiated-effort";
    const rejected = try consumer.command("stale-selection", .{ .thread = thread }, .{ .revision = 2 }, .{ .thread_send = .{ .text = "This must never dispatch", .selection = stale } });
    if (rejected.outcome != .rejected or rejected.reason != .capability_unavailable) return error.StaleSelectionAdmitted;
    if (model.readiness == .unavailable) {
        const unready = try consumer.command("unready-selection", .{ .thread = thread }, .{ .revision = 2 }, .{ .thread_send = .{ .text = "This must never dispatch", .selection = model.selection } });
        if (unready.outcome != .rejected or unready.reason != .capability_unavailable) return error.UnreadySelectionAdmitted;
    }
    consumer.host.destroy();
    host_live = false;
    consumer.host = try domain.Host.create(std.heap.page_allocator, io, .{ .state_directory = args[5], .setup_factory = factory.asFactory() });
    host_live = true;
    const reopened = (try consumer.query(.{ .thread = thread })).items[0].thread;
    if (!c.equal(model.selection, reopened.selection.?)) return error.ReopenedSelectionChanged;
    const report = try std.json.Stringify.valueAlloc(allocator, .{ .runtime = args[1], .status = status, .catalog_count = catalog.items.len, .catalog = catalog.items, .chosen = model.selection, .persisted = persisted.selection, .reopened = reopened.selection, .stale_outcome = rejected, .inference_issued = false, .login_initiated = false }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[7], .data = report });
    try std.Io.File.stdout().writeStreamingAll(io, "Public Host catalog/select/persist/reopen and stale admission succeeded; no inference/sign-in.\n");
}
