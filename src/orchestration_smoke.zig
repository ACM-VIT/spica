//! Opt-in installed-provider gate, derived from opencode_smoke_host.zig.
//! Uses real coordinator tools, public Host commands, and explicit account paths.
const std = @import("std");
const domain = @import("domain.zig");
const t = domain.types;
const c = t.adapter;
const common = @import("runtime/adapter.zig");
const NativeFactory = @import("runtime/native_factory.zig").NativeFactory;
const clock = @import("runtime/transport.zig").c;

const Runtime = struct {
    kind: c.RuntimeKind,
    executable: []const u8,
    account_directory: []const u8,
    model_provider: []const u8,
    model: []const u8,
    effort: []const u8,
};
const Configuration = struct {
    workspace: []const u8,
    state_directory: []const u8,
    candidate: []const u8,
    runtimes: []const Runtime,
};
const Consumer = struct {
    host: *domain.Host,
    io: std.Io,
    buffer: []u8,
    fn receive(self: *Consumer, ticket: t.Ticket) !t.Output {
        const start = clock.spica_monotonic_ms();
        while (clock.spica_monotonic_ms() - start < 45000) {
            var outputs: [1]t.Output = undefined;
            const drained = self.host.drain(&outputs, self.buffer);
            if (drained.required_bytes_for_next > self.buffer.len) return error.OutputTooLarge;
            if (drained.output_count != 0) {
                const actual = switch (outputs[0]) {
                    .command_receipt => |v| v.ticket,
                    .query_page => |v| v.ticket,
                    .failure => |v| v.ticket,
                    else => continue,
                };
                if (actual.value != ticket.value) return error.UnexpectedTicket;
                if (outputs[0] == .failure) {
                    std.debug.print("HOST FAILURE {any}\n", .{outputs[0].failure});
                    return error.HostFailure;
                }
                return outputs[0];
            }
            try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
        return error.HostTimeout;
    }
    fn command(self: *Consumer, id: []const u8, target: t.Target, expected: t.Precondition, payload: t.Payload) !t.Receipt {
        const output = try self.receive(try self.host.submit(.{ .command_id = .{ .value = id }, .target = target, .expected_revision = expected, .payload = payload }));
        if (output != .command_receipt) return error.MissingReceipt;
        const receipt = output.command_receipt.receipt;
        if (receipt.outcome != .accepted) {
            std.debug.print("REJECTED {s}: {any}\n", .{ id, receipt });
            return error.CommandRejected;
        }
        return receipt;
    }
    fn query(self: *Consumer, q: t.Query) !t.QueryPage {
        const output = try self.receive(try self.host.query(q));
        if (output != .query_page) return error.MissingPage;
        return output.query_page.page;
    }
    fn text(self: *Consumer, allocator: std.mem.Allocator, thread: t.ThreadId) ![]const u8 {
        const page = try self.query(.{ .messages = .{ .thread = thread, .page = .{ .limit = 32 } } });
        if (page.next_cursor != null) return error.MessageLimit;
        const rows = try common.clone(allocator, page.items);
        var result: std.Io.Writer.Allocating = .init(allocator);
        for (rows) |row| {
            if (row.message.role != .assistant) continue;
            // Tool activity can fill the inline descriptors before the final
            // coordinator reply. Read bounded public block pages explicitly.
            var bounds: t.Page = .{ .limit = 32 };
            for (0..8) |_| {
                const blocks = try common.clone(allocator, try self.query(.{ .blocks = .{ .message = row.message.message_id, .page = bounds } }));
                for (blocks.items) |item| {
                    const block = item.block;
                    if (block.kind != .text or block.committed_bytes == 0) continue;
                    if (block.committed_bytes > 16384 or result.written().len + block.committed_bytes > 65536) return error.TextLimit;
                    const content = try self.query(.{ .content = .{ .block = block.block_id, .start_byte = 0, .end_byte = block.committed_bytes } });
                    if (content.next_cursor != null) return error.ContentLimit;
                    for (content.items) |piece| try result.writer.writeAll(piece.content.bytes);
                }
                if (blocks.next_cursor == null) break;
                bounds.snapshot = blocks.snapshot_id;
                bounds.cursor = blocks.next_cursor;
            } else return error.BlockLimit;
        }
        return result.toOwnedSlice();
    }
};

fn terminal(state: t.RunState) bool {
    return switch (state) {
        .completed, .failed, .cancelled, .unknown, .interrupted => true,
        else => false,
    };
}
fn environment(a: std.mem.Allocator, account: []const u8, kind: c.RuntimeKind) ![]const [:0]const u8 {
    const values = try a.alloc([:0]const u8, if (kind == .opencode) 9 else 7);
    values[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{account}, 0);
    values[1] = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{account}, 0);
    values[2] = try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{account}, 0);
    values[3] = try std.fmt.allocPrintSentinel(a, "XDG_CACHE_HOME={s}/cache", .{account}, 0);
    values[4] = try std.fmt.allocPrintSentinel(a, "XDG_STATE_HOME={s}/state", .{account}, 0);
    values[5] = "PATH=/usr/bin:/bin";
    if (kind == .opencode) {
        values[6] = try std.fmt.allocPrintSentinel(a, "OPENCODE_CONFIG_DIR={s}/config/opencode", .{account}, 0);
        values[7] = "OPENCODE_DISABLE_CLAUDE_CODE=1";
        values[8] = try std.fmt.allocPrintSentinel(a, "OPENCODE_TEST_HOME={s}", .{account}, 0);
    } else values[6] = try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{account}, 0);
    return values;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len != 3) return error.ExpectedConfigurationAndReport;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], a, .limited(32768));
    const configuration = (try std.json.parseFromSlice(Configuration, a, source, .{})).value;
    if (configuration.runtimes.len == 0 or configuration.runtimes.len > 2 or configuration.candidate.len == 0) return error.InvalidConfiguration;
    const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, configuration.workspace, a);
    if (!std.fs.path.isAbsolute(configuration.state_directory)) return error.AbsoluteStateRequired;
    // A fresh test state is mandatory: repeated invocation must never reuse
    // command IDs against a previous live cohort.
    const database_path = try std.fs.path.join(a, &.{ configuration.state_directory, "conversation.sqlite3" });
    if (std.Io.Dir.cwd().access(io, database_path, .{})) |_| return error.FreshStateRequired else |err| if (err != error.FileNotFound) return err;
    var configs: [2]NativeFactory.Config = undefined;
    for (configuration.runtimes, 0..) |runtime, index| {
        if (!std.fs.path.isAbsolute(runtime.executable) or !std.fs.path.isAbsolute(runtime.account_directory) or runtime.model.len == 0 or runtime.effort.len == 0 or runtime.model_provider.len == 0) return error.ExplicitRuntimeSelectionRequired;
        const account = try std.Io.Dir.cwd().realPathFileAlloc(io, runtime.account_directory, a);
        if (std.mem.eql(u8, account, workspace)) return error.AccountDirectoryIsWorkspace;
        if (index != 0 and (runtime.kind == configuration.runtimes[0].kind or std.mem.eql(u8, account, configs[0].selection.account_ref))) return error.SeparateRuntimesAndAccountsRequired;
        configs[index] = .{ .selection = .{ .runtime_kind = @tagName(runtime.kind), .required_runtime_version = if (runtime.kind == .codex) "0.163.0" else "2.1.4", .model_provider = runtime.model_provider, .model_id = runtime.model, .effort = runtime.effort, .account_ref = account, .workspace = .{ .value = "unregistered" } }, .executable = try a.dupeZ(u8, runtime.executable), .environment = try environment(a, account, runtime.kind) };
    }
    const native = try a.create(NativeFactory);
    native.* = .{ .configs = configs[0..configuration.runtimes.len] };
    var consumer: Consumer = .{ .host = try domain.Host.create(std.heap.page_allocator, io, .{ .state_directory = configuration.state_directory, .factory = native.asFactory(), .selection = configs[0].selection, .workspace_root = workspace }), .io = io, .buffer = try a.alloc(u8, 2 * 1024 * 1024) };
    var host_live = true;
    defer if (host_live) consumer.host.destroy();
    const project = try common.clone(a, (try consumer.command("project", .absent, .absent, .{ .project_create = .{ .display_name = "Installed orchestration gate" } })).entity_ids.project.?);
    const binding = try domain.workspace_binding.capture(a, io, workspace);
    const registered = try common.clone(a, (try consumer.command("workspace", .absent, .absent, .{ .workspace_register = .{ .project = project, .binding = binding } })).entity_ids.workspace.?);
    const thread = try common.clone(a, (try consumer.command("thread", .absent, .absent, .{ .thread_create = .{ .project = project, .workspace = registered } })).entity_ids.thread.?);
    var instructions: std.Io.Writer.Allocating = .init(a);
    try instructions.writer.writeAll("Use the application's registered delegation and task listing tools to create app-owned children. For OpenCode, call execute with JavaScript: return await tools.spica.task_delegate(ARGUMENT_OBJECT). The server namespace is spica and dotted MCP names normalize to underscores. If the catalog is partial, use search({namespace:'spica',query:'task',limit:5}) inside execute to discover the exact paths, then invoke them. For Codex, call the registered dynamic task_delegate and task_list tools directly. Do not use provider-native subagents, shell, filesystem, network or web search. Call the delegation tool exactly once for EACH of these exact argument objects, without changing any selection or packet field:\n");
    for (configs[0..configuration.runtimes.len], 0..) |config, index| {
        var selection = config.selection;
        selection.workspace = registered;
        const marker = try std.fmt.allocPrint(a, "SPICA_CHILD_{s}_OK", .{selection.runtime_kind});
        const packet: t.orchestration.Packet = .{ .purpose = "installed provider orchestration gate", .prompt = try std.fmt.allocPrint(a, "Reply exactly {s}. Do not use tools or delegate.", .{marker}), .selection = selection, .owned_paths = &.{try std.fmt.allocPrint(a, "child-{d}.txt", .{index})}, .acceptance = marker, .result_location = try std.fmt.allocPrint(a, "child-{d}.txt", .{index}), .budget = .{ .max_requests = 2, .max_elapsed_ms = 90000, .max_tokens = 4000 } };
        const arguments = try std.json.Stringify.valueAlloc(a, .{ .request_key = try std.fmt.allocPrint(a, "installed-delegate-{d}", .{index}), .packet = packet }, .{});
        try instructions.writer.print("{s}\n", .{arguments});
    }
    try instructions.writer.writeAll("Then call the application's task listing tool once (OpenCode: execute return await tools.spica.task_list({}); Codex: task_list) and reply exactly SPICA_COORDINATOR_OK. Do not wait for the children; the application collects their results. Attempt the registered application tools before reporting SPICA_BRIDGE_UNAVAILABLE.");
    var parent_selection = configs[0].selection;
    parent_selection.workspace = registered;
    const parent = try common.clone(a, (try consumer.command("send", .{ .thread = thread }, .{ .revision = 1 }, .{ .thread_send = .{ .text = instructions.written(), .selection = parent_selection } })).entity_ids.run.?);
    const start = clock.spica_monotonic_ms();
    while (clock.spica_monotonic_ms() - start < 180000) {
        const tasks = try consumer.query(.{ .task_list = .{ .parent = parent } });
        if (tasks.next_cursor != null or tasks.items.len > configuration.runtimes.len) return error.DuplicateDelegation;
        var complete = tasks.items.len == configuration.runtimes.len;
        for (tasks.items) |row| {
            if (terminal(row.task.state) and row.task.state != .completed) {
                std.debug.print("CHILD TERMINATED state={s}\n", .{@tagName(row.task.state)});
                return error.ChildRunFailed;
            }
            complete = complete and row.task.state == .completed;
        }
        const runs = try consumer.query(.{ .runs = .{ .thread = thread } });
        if (runs.items.len != 1) return error.ParentRunMissing;
        if (terminal(runs.items[0].run.state)) {
            if (runs.items[0].run.state != .completed) {
                std.debug.print("COORDINATOR TERMINATED state={s} diagnostic={s}\n", .{ @tagName(runs.items[0].run.state), runs.items[0].run.diagnostic });
                return error.CoordinatorFailed;
            }
            const present = try consumer.query(.{ .task_list = .{ .parent = parent } });
            if (present.items.len != configuration.runtimes.len) {
                std.debug.print("COORDINATOR NO DELEGATION text={s}\n", .{try consumer.text(a, thread)});
                return error.DelegationMissing;
            }
            if (complete) break;
        }
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    } else return error.OrchestrationTimeout;
    const coordinator_text = try consumer.text(a, thread);
    if (std.mem.indexOf(u8, coordinator_text, "SPICA_COORDINATOR_OK") == null) return error.CoordinatorTextMissing;
    const tasks = try common.clone(a, (try consumer.query(.{ .task_list = .{ .parent = parent } })).items);
    const threads = try common.clone(a, (try consumer.query(.{ .threads = .{ .project = project, .page = .{ .limit = 8 } } })).items);
    var verified: [2]bool = @splat(false);
    for (tasks, 0..) |row, index| {
        var child_thread: ?t.ThreadId = null;
        for (threads) |candidate| {
            const runs = try consumer.query(.{ .runs = .{ .thread = candidate.thread.id } });
            for (runs.items) |run| if (std.mem.eql(u8, run.run.id.value, row.task.task.id.value)) {
                const effective = run.run.effective orelse return error.EffectiveSelectionMissing;
                if (!c.equal(row.task.task.packet.selection, effective)) return error.ChildSelectionChanged;
                child_thread = candidate.thread.id;
            };
        }
        const text = try consumer.text(a, child_thread orelse return error.ChildThreadMissing);
        const selection = row.task.task.packet.selection;
        const marker = try std.fmt.allocPrint(a, "SPICA_CHILD_{s}_OK", .{selection.runtime_kind});
        if (std.mem.indexOf(u8, text, marker) == null) return error.ChildTextMissing;
        for (configs[0..configuration.runtimes.len], 0..) |config, config_index| {
            var expected = config.selection;
            expected.workspace = registered;
            if (c.equal(expected, selection)) {
                if (verified[config_index]) return error.DuplicateRuntimeChild;
                verified[config_index] = true;
            }
        }
        const result = try consumer.command(try std.fmt.allocPrint(a, "result-{d}", .{index}), .{ .run = row.task.task.id }, .{ .revision = row.task.revision }, .{ .task_result = .{ .candidate = configuration.candidate, .evidence = args[2], .summary = text } });
        if (result.committed_revisions.len != 1) return error.ResultRevisionMissing;
        _ = try consumer.command(try std.fmt.allocPrint(a, "review-{d}", .{index}), .{ .run = row.task.task.id }, .{ .revision = result.committed_revisions[0].revision }, .{ .task_review = .{ .candidate = configuration.candidate, .evidence = args[2], .disposition = .accepted } });
        std.debug.print("VERIFIED child={s} runtime={s} model={s} effort={s} text={s}\n", .{ row.task.task.id.value, selection.runtime_kind, selection.model_id, selection.effort, text });
    }
    for (verified[0..configuration.runtimes.len]) |actual| if (!actual) return error.MissingRuntimeChild;
    const completed = try common.clone(a, (try consumer.query(.{ .task_list = .{ .parent = parent } })).items);
    consumer.host.destroy();
    host_live = false;
    consumer.host = try domain.Host.create(std.heap.page_allocator, io, .{ .state_directory = configuration.state_directory });
    host_live = true;
    const reopened = (try consumer.query(.{ .task_list = .{ .parent = parent } })).items;
    if (!std.meta.eql(completed.len, reopened.len)) return error.ReopenedTaskCountChanged;
    for (completed, reopened) |before, after| {
        const before_json = try std.json.Stringify.valueAlloc(a, before.task, .{});
        const after_json = try std.json.Stringify.valueAlloc(a, after.task, .{});
        if (!std.mem.eql(u8, before_json, after_json) or after.task.task.result == null or after.task.task.review != .accepted) return error.ReopenedTaskChanged;
    }
    const report = try std.json.Stringify.valueAlloc(a, .{ .passed = true, .configuration = configuration, .parent = parent, .parent_selection = parent_selection, .coordinator_text = coordinator_text, .tasks = reopened, .reopened_without_factory = true, .limitations = [_][]const u8{ "Finite installed-provider completion/bridge/result/reopen cohort; no approval/cancellation or physical UI latency claim.", "Observed token counters are not complete provider usage or billing.", "Accepted review records mark this smoke's marker/selection checks, not product acceptance." } }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = report });
    try std.Io.File.stdout().writeStreamingAll(io, "Installed coordinator/children, exact selections, durable results/reviews and read-only reopen passed.\n");
}
