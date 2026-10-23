//! Actual installed ACP -> NativeFactory -> Host MCP -> durable child/result/reopen.
const std = @import("std");
const domain = @import("domain.zig");
const t = domain.types;
const NativeFactory = @import("runtime/native_factory.zig").NativeFactory;
extern "c" fn usleep(u32) c_int;

const Consumer = struct {
    host: *domain.Host,
    allocator: std.mem.Allocator,
    fn next(self: *Consumer) !t.Output {
        var outputs: [1]t.Output = undefined;
        const bytes = try self.allocator.alloc(u8, 262144);
        for (0..3000) |_| {
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
            std.debug.print("REJECTED {any}\n", .{output.command_receipt.receipt});
            return error.CommandRejected;
        }
        return output.command_receipt.receipt;
    }
    fn query(self: *Consumer, request: t.Query) !t.QueryPage {
        _ = try self.host.query(request);
        const output = try self.next();
        if (output != .query_page) {
            std.debug.print("QUERY ERROR {any}\n", .{output});
            return error.MissingQueryPage;
        }
        return output.query_page.page;
    }
    fn childText(self: *Consumer, thread: t.ThreadId) ![]const u8 {
        const messages = try self.query(.{ .messages = .{ .thread = thread } });
        var text: std.Io.Writer.Allocating = .init(self.allocator);
        for (messages.items) |row| {
            if (row.message.role != .assistant) continue;
            for (row.message.blocks) |block| {
                if (block.kind != .text or block.committed_bytes == 0) continue;
                const content = try self.query(.{ .content = .{ .block = block.block_id, .start_byte = 0, .end_byte = block.committed_bytes } });
                for (content.items) |piece| try text.writer.writeAll(piece.content.bytes);
            }
        }
        return text.toOwnedSlice();
    }
    fn verifyResult(self: *Consumer, parent: t.adapter.RunId, child: t.adapter.RunId) !void {
        const tasks = try self.query(.{ .task_list = .{ .parent = parent } });
        if (tasks.items.len != 1) return error.DuplicateOrMissingTask;
        const row = tasks.items[0].task;
        if (!std.mem.eql(u8, row.task.id.value, child.value) or row.state != .completed or row.task.result == null) return error.MissingDurableTaskResult;
        if (std.mem.indexOf(u8, row.task.result.?.summary, "SPICA_MCP_CHILD_OK") == null) return error.MissingChildResultText;
        std.debug.print("ASSERT durable task={s} state={s} result={s}\n", .{ child.value, @tagName(row.state), row.task.result.?.summary });
    }
};
pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len != 5) return error.ExpectedExecutableWorkspaceAccountState;
    const cwd = args[2];
    const state = args[4];
    const environment = try a.alloc([:0]const u8, 9);
    environment[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{args[3]}, 0);
    environment[1] = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{args[3]}, 0);
    environment[2] = try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{args[3]}, 0);
    environment[3] = try std.fmt.allocPrintSentinel(a, "XDG_CACHE_HOME={s}/cache", .{args[3]}, 0);
    environment[4] = try std.fmt.allocPrintSentinel(a, "XDG_STATE_HOME={s}/state", .{args[3]}, 0);
    environment[5] = "PATH=/usr/bin:/bin";
    environment[6] = try std.fmt.allocPrintSentinel(a, "OPENCODE_CONFIG_DIR={s}/config/opencode", .{args[3]}, 0);
    environment[7] = "OPENCODE_DISABLE_CLAUDE_CODE=1";
    // Installed v2.1.4's Global.home explicitly uses this override, not HOME.
    environment[8] = try std.fmt.allocPrintSentinel(a, "OPENCODE_TEST_HOME={s}", .{args[3]}, 0);
    var selection: t.adapter.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "opencode", .model_id = "big-pickle", .effort = "default", .account_ref = args[3], .workspace = .{ .value = "unregistered" } };
    var native: NativeFactory = .{ .configs = &.{.{ .selection = selection, .executable = try a.dupeZ(u8, args[1]), .environment = environment }} };
    var consumer: Consumer = .{ .host = try domain.Host.create(a, threaded.io(), .{ .state_directory = state, .factory = native.asFactory(), .selection = selection, .workspace_root = cwd }), .allocator = a };
    var host_live = true;
    defer if (host_live) consumer.host.destroy();
    const project = (try consumer.command(.{ .command_id = .{ .value = "mcp-project" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = "isolated OpenCode MCP consumer" } } })).entity_ids.project.?;
    const workspace = (try consumer.command(.{ .command_id = .{ .value = "mcp-workspace" }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = try domain.workspace_binding.capture(a, threaded.io(), cwd) } } })).entity_ids.workspace.?;
    const thread = (try consumer.command(.{ .command_id = .{ .value = "mcp-thread" }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } })).entity_ids.thread.?;
    selection.workspace = workspace;
    const packet: t.orchestration.Packet = .{ .purpose = "real MCP child smoke", .prompt = "Reply exactly SPICA_MCP_CHILD_OK. Do not use tools or delegate.", .selection = selection, .owned_paths = &.{"consumer-result.txt"}, .acceptance = "Return SPICA_MCP_CHILD_OK", .result_location = "consumer-result.txt", .budget = .{ .max_requests = 2, .max_elapsed_ms = 90000, .max_tokens = 4000 } };
    const arguments = try std.json.Stringify.valueAlloc(a, .{ .request_key = "consumer-real-delegate-v1", .packet = packet }, .{});
    const prompt = try std.fmt.allocPrint(a, "Use the execute Code Mode tool to call the application's real registered spica MCP tool exactly once. The MCP tool's original name is task.delegate under the spica namespace. Inside execute use the advertised catalog path (tools.spica['task.delegate'] or the catalog's normalized equivalent), passing these exact arguments:\n{s}\nThen use execute to call the registered spica task.list tool once and print its result. These are MCP calls, not native task/subagent operations. Do not call shell, terminal, filesystem or network tools and do not investigate the environment. If the spica tools are absent from the execute catalog, reply SPICA_MCP_UNAVAILABLE immediately. After the calls reply SPICA_MCP_COORDINATOR_OK; the application collects the child result, do not wait or delegate again.", .{arguments});
    const parent = (try consumer.command(.{ .command_id = .{ .value = "mcp-send" }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 }, .payload = .{ .thread_send = .{ .text = prompt, .selection = selection } } })).entity_ids.run.?;
    var child: ?t.adapter.RunId = null;
    var child_thread: ?t.ThreadId = null;
    var child_revision: u64 = 0;
    for (0..1200) |_| {
        const tasks = try consumer.query(.{ .task_list = .{ .parent = parent } });
        if (tasks.items.len > 1) return error.DuplicateDelegation;
        if (tasks.items.len == 1) {
            const row = tasks.items[0].task;
            child = row.task.id;
            if (row.state == .completed) {
                const threads = try consumer.query(.{ .threads = .{ .project = project } });
                for (threads.items) |candidate| {
                    const runs = try consumer.query(.{ .runs = .{ .thread = candidate.thread.id } });
                    for (runs.items) |run| if (std.mem.eql(u8, run.run.id.value, child.?.value)) {
                        child_thread = candidate.thread.id;
                        child_revision = run.run.revision;
                    };
                }
                break;
            }
            if (row.state == .failed or row.state == .cancelled or row.state == .unknown or row.state == .interrupted) {
                std.debug.print("CHILD FAILURE {any}\n", .{row});
                return error.ChildRunFailed;
            }
        }
        if (tasks.items.len == 0) {
            const parent_runs = try consumer.query(.{ .runs = .{ .thread = thread } });
            for (parent_runs.items) |row| {
                if (row.run.state == .completed or row.run.state == .failed or row.run.state == .unknown or row.run.state == .interrupted) {
                    std.debug.print("COORDINATOR TERMINATED WITHOUT MCP CHILD state={s} text={s}\n", .{ @tagName(row.run.state), try consumer.childText(thread) });
                    return error.RealMcpDelegationMissing;
                }
            }
        }
        _ = usleep(100000);
    } else return error.RealMcpDelegationTimeout;
    const text = try consumer.childText(child_thread orelse return error.ChildThreadMissing);
    if (std.mem.indexOf(u8, text, "SPICA_MCP_CHILD_OK") == null) return error.ChildTextMissing;
    std.debug.print("ASSERT real MCP delegate created one child={s}; actual provider completed text={s}\n", .{ child.?.value, text });
    _ = try consumer.command(.{ .command_id = .{ .value = "mcp-real-child-result" }, .target = .{ .run = child.? }, .expected_revision = .{ .revision = child_revision }, .payload = .{ .task_result = .{ .candidate = "disposable-no-source-change", .evidence = "host-run.log: actual durable child content", .summary = text } } });
    try consumer.verifyResult(parent, child.?);
    consumer.host.destroy();
    host_live = false;
    consumer.host = try domain.Host.create(a, threaded.io(), .{ .state_directory = state });
    host_live = true;
    try consumer.verifyResult(parent, child.?);
    std.debug.print("ASSERT shutdown/reopen retains exact task/result; no provider restarted on read-only reopen\n", .{});
}
