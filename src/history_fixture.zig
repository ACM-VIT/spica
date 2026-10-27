//! Bounded synthetic history producer for pressure evaluation.
//!
//! This executable deliberately uses only the public domain.Host command/query
//! boundary. The fake factory is the domain's deterministic provider fixture;
//! no provider credentials, history, or direct SQL writes are involved.
const std = @import("std");
const domain = @import("domain");
const t = domain.types;
const a = t.adapter;

const max_threads: usize = 64;
const max_turns: usize = 4096;
const max_content_bytes: usize = domain.max_prompt_bytes;
const max_generated_turns: usize = 16 * 1024;
const max_total_prompt_bytes: usize = 128 * 1024 * 1024;
const max_wait_ms: u64 = 10_000;
const drain_bytes = 1024 * 1024;

const Config = struct {
    state_path: []const u8,
    workspace_path: []const u8,
    threads: usize,
    turns: usize,
    content_bytes: usize,
    seed: u64,
    name: []const u8,
    cancel_last: bool,
    git_init: bool,
};

const Manifest = struct {
    fixture: []const u8,
    state_path: []const u8,
    workspace_path: []const u8,
    project_id: []const u8,
    workspace_id: []const u8,
    latest_thread_id: []const u8,
    latest_run_id: []const u8,
    latest_user_message_id: []const u8,
    latest_assistant_message_id: []const u8,
    latest_assistant_block_id: []const u8,
    latest_thread_revision: u64,
    generated_threads: usize,
    generated_turns: usize,
    generated_runs: usize,
    generated_messages: usize,
    completed_runs: usize,
    cancelled_runs: usize,
    prompt_bytes: u64,
    content_bytes: u64,
    provenance: Provenance,
};
const Provenance = struct {
    generator: []const u8,
    runtime: []const u8,
    seed: u64,
    name: []const u8,
    git_initialized: bool,
};

const Approval = struct {
    id: []const u8,
    revision: u64,
    action_digest: []const u8,
};

const Consumer = struct {
    host: *domain.Host = undefined,
    io: std.Io,
    event: std.Io.Event = .unset,
    storage: [drain_bytes]u8 = undefined,

    fn wake(context: ?*anyopaque) void {
        const self: *Consumer = @ptrCast(@alignCast(context.?));
        self.event.set(self.io);
    }

    fn next(self: *Consumer) !t.Output {
        const deadline = std.Io.Clock.Timestamp.now(self.io, .awake).addDuration(.{ .raw = .fromMilliseconds(max_wait_ms), .clock = .awake });
        var output: [1]t.Output = undefined;
        while (true) {
            self.event.reset();
            const drained = self.host.drain(&output, &self.storage);
            if (drained.output_count != 0) return output[0];
            if (drained.required_bytes_for_next != 0) return error.OutputTooLarge;
            if (std.Io.Clock.awake.now(self.io).nanoseconds >= deadline.raw.nanoseconds) return error.DeadlineExceeded;
            self.event.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {}, // The event API also permits spurious wakeups.
                else => return err,
            };
        }
    }

    fn command(self: *Consumer, envelope: t.CommandEnvelope) !t.Receipt {
        const ticket = try self.host.submit(envelope);
        const output = try self.next();
        if (output != .command_receipt or !std.meta.eql(output.command_receipt.ticket, ticket)) return error.CommandFailed;
        const receipt = output.command_receipt.receipt;
        if (receipt.outcome != .accepted) return error.CommandRejected;
        return receipt;
    }

    fn query(self: *Consumer, request: t.Query) !t.QueryPage {
        const ticket = try self.host.query(request);
        const output = try self.next();
        if (output == .failure) {
            std.debug.print("history fixture query {s}: {s}\n", .{ @tagName(request), @tagName(output.failure.failure.reason) });
            return error.QueryFailed;
        }
        if (output != .query_page or !std.meta.eql(output.query_page.ticket, ticket)) return error.QueryFailed;
        return output.query_page.page;
    }
};

fn usage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(
        io,
        "usage: build-history-fixture --state PATH --workspace PATH --threads N --turns N --content-bytes N --seed N --name NAME [--cancel-last] [--git-init]\n",
    );
}

fn parseSize(value: []const u8, comptime label: []const u8, max: usize) !usize {
    const result = std.fmt.parseInt(usize, value, 10) catch return error.InvalidArgument;
    if (result == 0 or result > max) return error.InvalidArgument;
    _ = label;
    return result;
}

fn parse(args: []const []const u8, io: std.Io) !Config {
    var state: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;
    var threads: ?usize = null;
    var turns: ?usize = null;
    var content: ?usize = null;
    var seed: ?u64 = null;
    var name: ?[]const u8 = null;
    var cancel_last = false;
    var git_init = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--git-init")) {
            if (git_init) return error.InvalidArgument;
            git_init = true;
            continue;
        }
        if (std.mem.eql(u8, flag, "--cancel-last")) {
            if (cancel_last) return error.InvalidArgument;
            cancel_last = true;
            continue;
        }
        if (index + 1 >= args.len) {
            try usage(io);
            return error.InvalidArgument;
        }
        const value = args[index + 1];
        index += 1;
        if (std.mem.eql(u8, flag, "--state")) {
            if (state != null) return error.InvalidArgument;
            state = value;
        } else if (std.mem.eql(u8, flag, "--workspace")) {
            if (workspace != null) return error.InvalidArgument;
            workspace = value;
        } else if (std.mem.eql(u8, flag, "--threads")) {
            if (threads != null) return error.InvalidArgument;
            threads = try parseSize(value, "threads", max_threads);
        } else if (std.mem.eql(u8, flag, "--turns")) {
            if (turns != null) return error.InvalidArgument;
            turns = try parseSize(value, "turns", max_turns);
        } else if (std.mem.eql(u8, flag, "--content-bytes")) {
            if (content != null) return error.InvalidArgument;
            content = try parseSize(value, "content-bytes", max_content_bytes);
        } else if (std.mem.eql(u8, flag, "--seed")) {
            if (seed != null) return error.InvalidArgument;
            seed = std.fmt.parseInt(u64, value, 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, flag, "--name")) {
            if (name != null or value.len == 0 or value.len > 128 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidArgument;
            name = value;
        } else {
            try usage(io);
            return error.InvalidArgument;
        }
    }
    if (state == null or workspace == null or threads == null or turns == null or content == null or seed == null or name == null) {
        try usage(io);
        return error.InvalidArgument;
    }
    const generated_turns = threads.? * turns.?;
    if (generated_turns > max_generated_turns or generated_turns > max_total_prompt_bytes / content.?) return error.InvalidArgument;
    if (!std.fs.path.isAbsolute(state.?) or !std.fs.path.isAbsolute(workspace.?)) return error.AmbiguousPath;
    if (std.mem.eql(u8, state.?, workspace.?)) return error.AmbiguousPath;
    return .{ .state_path = state.?, .workspace_path = workspace.?, .threads = threads.?, .turns = turns.?, .content_bytes = content.?, .seed = seed.?, .name = name.?, .cancel_last = cancel_last, .git_init = git_init };
}

fn directoryIsEmpty(io: std.Io, path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return true,
        error.NotDir => return error.FreshStateRequired,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    return (try iterator.next(io)) == null;
}

fn canonicalNewPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or !std.fs.path.isAbsolute(path)) return error.AmbiguousPath;
    const parent = std.fs.path.dirname(path) orelse return error.AmbiguousPath;
    const base = std.fs.path.basename(path);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.AmbiguousPath;
    const parent_real = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);
    defer allocator.free(parent_real);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_real, base });
}

fn ensureFreshDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const canonical = try canonicalNewPath(allocator, io, path);
    errdefer allocator.free(canonical);
    if (!try directoryIsEmpty(io, canonical)) return error.FreshStateRequired;
    const created = try std.Io.Dir.cwd().createDirPathOpen(io, canonical, .{ .permissions = .fromMode(0o700) });
    created.close(io);
    return canonical;
}

fn pathsOverlap(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    return (std.mem.startsWith(u8, left, right) and left.len > right.len and left[right.len] == '/') or
        (std.mem.startsWith(u8, right, left) and right.len > left.len and right[left.len] == '/');
}

fn boundedId(allocator: std.mem.Allocator, prefix: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{d:0>6}", .{ prefix, index });
}

fn copyId(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.Limit;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

fn makePrompt(buffer: []u8, config: Config, thread_index: usize, turn: usize, random: *std.Random.Xoroshiro128) []const u8 {
    const prefix = "Synthetic history fixture ";
    var header: [256]u8 = undefined;
    const header_bytes = std.fmt.bufPrint(&header, "{s} seed={d} thread={d} turn={d} sample={x}: ", .{ config.name, config.seed, thread_index, turn, random.next() }) catch unreachable;
    const count = @min(buffer.len, config.content_bytes);
    @memcpy(buffer[0..@min(prefix.len, count)], prefix[0..@min(prefix.len, count)]);
    var offset: usize = @min(prefix.len, count);
    if (offset < count) {
        var copy = @min(header_bytes.len, count - offset);
        while (copy > 0 and copy < header_bytes.len and header_bytes[copy] & 0xc0 == 0x80) copy -= 1;
        @memcpy(buffer[offset..][0..copy], header_bytes[0..copy]);
        offset += copy;
    }
    // Keep generated prompt boundaries valid UTF-8 for every requested size;
    // the fake assistant stream supplies the Unicode regression bytes.
    const alphabet = "abcdefghijklmnopqrstuvwxyz 0123456789";
    while (offset < count) : (offset += 1) buffer[offset] = alphabet[(offset + thread_index + turn) % @as(usize, alphabet.len)];
    return buffer[0..count];
}

fn waitApproval(consumer: *Consumer, retained: std.mem.Allocator, run: a.RunId) !Approval {
    const deadline = std.Io.Clock.awake.now(consumer.io).addDuration(.fromMilliseconds(max_wait_ms));
    while (std.Io.Clock.awake.now(consumer.io).nanoseconds < deadline.nanoseconds) {
        const page = try consumer.query(.{ .approvals = .{ .run = run, .page = .{ .limit = 4, .max_bytes = 64 * 1024 } } });
        if (page.items.len != 0) {
            const row = page.items[0];
            if (row != .approval) return error.QueryFailed;
            return .{ .id = try retained.dupe(u8, row.approval.id.value), .revision = row.approval.revision, .action_digest = try retained.dupe(u8, row.approval.evidence.action_digest) };
        }
        std.Io.sleep(consumer.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.DeadlineExceeded;
}

const Run = struct { state: t.RunState, revision: u64 };

fn findRun(consumer: *Consumer, thread: t.ThreadId, run: a.RunId) !Run {
    const deadline = std.Io.Clock.awake.now(consumer.io).addDuration(.fromMilliseconds(max_wait_ms));
    var snapshot: ?t.SnapshotId = null;
    var cursor_storage: [1024]u8 = undefined;
    var cursor_len: usize = 0;
    var pages: usize = 0;
    while (pages < max_turns and std.Io.Clock.awake.now(consumer.io).nanoseconds < deadline.nanoseconds) : (pages += 1) {
        const page = try consumer.query(.{ .runs = .{ .thread = thread, .page = .{ .limit = 16, .max_bytes = 16 * 1024, .snapshot = snapshot, .cursor = if (cursor_len == 0) null else cursor_storage[0..cursor_len] } } });
        for (page.items) |row| if (row == .run and std.mem.eql(u8, row.run.id.value, run.value)) return .{ .state = row.run.state, .revision = row.run.revision };
        const cursor = page.next_cursor orelse return error.MissingRun;
        snapshot = page.snapshot_id;
        cursor_len = (try copyId(&cursor_storage, cursor)).len;
    }
    return error.DeadlineExceeded;
}

fn waitRun(consumer: *Consumer, thread: t.ThreadId, run: a.RunId, expected: t.RunState) !void {
    const deadline = std.Io.Clock.awake.now(consumer.io).addDuration(.fromMilliseconds(max_wait_ms));
    while (std.Io.Clock.awake.now(consumer.io).nanoseconds < deadline.nanoseconds) {
        const row = try findRun(consumer, thread, run);
        if (row.state == expected) return;
        if (row.state == .failed or row.state == .unknown or row.state == .interrupted or row.state == .cancelled) return error.UnexpectedRunOutcome;
        std.Io.sleep(consumer.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.DeadlineExceeded;
}

fn collectBlocks(consumer: *Consumer, message: a.MessageId, bytes: *u64) !void {
    var snapshot: ?t.SnapshotId = null;
    var cursor_storage: [512]u8 = undefined;
    var cursor_len: usize = 0;
    while (true) {
        const page = try consumer.query(.{ .blocks = .{ .message = message, .page = .{ .limit = 2, .max_bytes = 64 * 1024, .snapshot = snapshot, .cursor = if (cursor_len == 0) null else cursor_storage[0..cursor_len] } } });
        snapshot = page.snapshot_id;
        var block_ids: [2][128]u8 = undefined;
        var block_lengths: [2]usize = undefined;
        var block_bytes: [2]u64 = undefined;
        var block_count: usize = 0;
        for (page.items) |row| {
            if (row != .block or block_count == block_ids.len or row.block.block_id.value.len > block_ids[block_count].len) continue;
            @memcpy(block_ids[block_count][0..row.block.block_id.value.len], row.block.block_id.value);
            block_lengths[block_count] = row.block.block_id.value.len;
            block_bytes[block_count] = row.block.committed_bytes;
            block_count += 1;
        }
        var next_len: usize = 0;
        if (page.next_cursor) |next| {
            if (next.len > cursor_storage.len) return error.OutputTooLarge;
            @memcpy(cursor_storage[0..next.len], next);
            next_len = next.len;
        }
        for (0..block_count) |index| {
            const block = a.BlockId{ .value = block_ids[index][0..block_lengths[index]] };
            if (block_bytes[index] == 0) continue;
            var offset: u64 = 0;
            while (offset < block_bytes[index]) {
                const end = @min(offset + 4096, block_bytes[index]);
                const content = try consumer.query(.{ .content = .{ .block = block, .start_byte = offset, .end_byte = end, .page = .{ .limit = 1, .max_bytes = 64 * 1024, .snapshot = snapshot } } });
                if (content.items.len != 1 or content.items[0] != .content or content.items[0].content.bytes.len != end - offset) return error.MissingContent;
                bytes.* += content.items[0].content.bytes.len;
                offset = end;
            }
        }
        if (next_len == 0) break;
        cursor_len = next_len;
    }
}

fn collectMessageBytes(consumer: *Consumer, thread: t.ThreadId, user: a.MessageId, assistant: a.MessageId, bytes: *u64) !void {
    // Exact IDs come from the accepted Send receipt; history before them never
    // needs decoding merely to count this turn's content.
    _ = thread;
    try collectBlocks(consumer, user, bytes);
    try collectBlocks(consumer, assistant, bytes);
}

fn runFixture(allocator: std.mem.Allocator, io: std.Io, config: Config, state_path: []const u8, workspace_path: []const u8) !void {
    var retained_arena = std.heap.ArenaAllocator.init(allocator);
    defer retained_arena.deinit();
    const retained = retained_arena.allocator();
    const binding = try domain.workspace_binding.capture(retained, io, workspace_path);
    var consumer = Consumer{ .io = io };
    consumer.host = try domain.Host.create(allocator, io, .{ .state_directory = state_path, .wake = Consumer.wake, .wake_context = &consumer, .workspace_root = binding.canonical_root });
    var host_live = true;
    defer if (host_live) consumer.host.destroy();

    const project_command = try boundedId(retained, "fixture-project", 0);
    const project_receipt = try consumer.command(.{ .command_id = .{ .value = project_command }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = config.name } } });
    const project_value = (project_receipt.entity_ids.project orelse return error.CommandFailed).value;
    const project = t.ProjectId{ .value = try retained.dupe(u8, project_value) };
    const workspace_command = try boundedId(retained, "fixture-workspace", 0);
    const workspace_receipt = try consumer.command(.{ .command_id = .{ .value = workspace_command }, .target = .absent, .expected_revision = .absent, .payload = .{ .workspace_register = .{ .project = project, .binding = binding } } });
    const workspace_value = (workspace_receipt.entity_ids.workspace orelse return error.CommandFailed).value;
    const workspace = a.WorkspaceId{ .value = try retained.dupe(u8, workspace_value) };
    const selection = a.fakeSelection(workspace);

    var random = std.Random.Xoroshiro128.init(config.seed);
    var prompt_buffer: [max_content_bytes]u8 = undefined;
    var turn_arena = std.heap.ArenaAllocator.init(allocator);
    defer turn_arena.deinit();
    var latest_thread_storage: [128]u8 = undefined;
    var latest_run_storage: [128]u8 = undefined;
    var latest_user_storage: [128]u8 = undefined;
    var latest_assistant_storage: [128]u8 = undefined;
    var latest_block_storage: [128]u8 = undefined;
    var latest_thread: []const u8 = "";
    var latest_run: []const u8 = "";
    var latest_user: []const u8 = "";
    var latest_assistant: []const u8 = "";
    var latest_block: []const u8 = "";
    var latest_revision: u64 = 0;
    var prompt_bytes: u64 = 0;
    var content_bytes: u64 = 0;
    var completed_runs: usize = 0;
    var cancelled_runs: usize = 0;
    var thread_index: usize = 0;
    while (thread_index < config.threads) : (thread_index += 1) {
        const thread_command = try boundedId(retained, "fixture-thread", thread_index);
        const thread_receipt = try consumer.command(.{ .command_id = .{ .value = thread_command }, .target = .absent, .expected_revision = .absent, .payload = .{ .thread_create = .{ .project = project, .workspace = workspace } } });
        const thread_value = (thread_receipt.entity_ids.thread orelse return error.CommandFailed).value;
        const thread = t.ThreadId{ .value = try retained.dupe(u8, thread_value) };
        var turn: usize = 0;
        while (turn < config.turns) : (turn += 1) {
            _ = turn_arena.reset(.retain_capacity);
            const turn_alloc = turn_arena.allocator();
            const command_id = try boundedId(turn_alloc, "fixture-send", thread_index * config.turns + turn);
            const prompt = makePrompt(&prompt_buffer, config, thread_index, turn, &random);
            const receipt = try consumer.command(.{ .command_id = .{ .value = command_id }, .target = .{ .thread = thread }, .expected_revision = .{ .revision = 1 + turn }, .payload = .{ .thread_send = .{ .text = prompt, .selection = selection } } });
            const run_value = (receipt.entity_ids.run orelse return error.CommandFailed).value;
            const run = a.RunId{ .value = try turn_alloc.dupe(u8, run_value) };
            const user_value = (receipt.entity_ids.user_message orelse return error.CommandFailed).value;
            const user = a.MessageId{ .value = try turn_alloc.dupe(u8, user_value) };
            const assistant_value = (receipt.entity_ids.assistant_message orelse return error.CommandFailed).value;
            const assistant = a.MessageId{ .value = try turn_alloc.dupe(u8, assistant_value) };
            const block_value = (receipt.entity_ids.assistant_block orelse return error.CommandFailed).value;
            const block = a.BlockId{ .value = try turn_alloc.dupe(u8, block_value) };
            prompt_bytes += prompt.len;
            const approval = try waitApproval(&consumer, turn_alloc, run);
            const cancel = config.cancel_last and thread_index + 1 == config.threads and turn + 1 == config.turns;
            if (cancel) {
                const run_revision = (try findRun(&consumer, thread, run)).revision;
                _ = try consumer.command(.{ .command_id = .{ .value = try boundedId(turn_alloc, "fixture-cancel", thread_index * config.turns + turn) }, .target = .{ .run = run }, .expected_revision = .{ .revision = run_revision }, .payload = .{ .run_cancel = .{ .reason = "synthetic fixture cancellation" } } });
                _ = try waitRun(&consumer, thread, run, .cancelled);
                cancelled_runs += 1;
            } else {
                _ = try consumer.command(.{ .command_id = .{ .value = try boundedId(turn_alloc, "fixture-allow", thread_index * config.turns + turn) }, .target = .{ .approval = .{ .value = approval.id } }, .expected_revision = .{ .revision = approval.revision }, .payload = .{ .approval_respond = .{ .decision = .allow, .action_digest = approval.action_digest } } });
                _ = try waitRun(&consumer, thread, run, .completed);
                completed_runs += 1;
            }
            try collectMessageBytes(&consumer, thread, user, assistant, &content_bytes);
            latest_thread = try copyId(&latest_thread_storage, thread.value);
            latest_run = try copyId(&latest_run_storage, run.value);
            latest_user = try copyId(&latest_user_storage, user.value);
            latest_assistant = try copyId(&latest_assistant_storage, assistant.value);
            latest_block = try copyId(&latest_block_storage, block.value);
            latest_revision = 1 + turn + 1;
        }
    }
    consumer.host.destroy();
    host_live = false;
    const manifest = Manifest{
        .fixture = "synthetic-large-history",
        .state_path = state_path,
        .workspace_path = workspace_path,
        .project_id = project.value,
        .workspace_id = workspace.value,
        .latest_thread_id = latest_thread,
        .latest_run_id = latest_run,
        .latest_user_message_id = latest_user,
        .latest_assistant_message_id = latest_assistant,
        .latest_assistant_block_id = latest_block,
        .latest_thread_revision = latest_revision,
        .generated_threads = config.threads,
        .generated_turns = config.threads * config.turns,
        .generated_runs = config.threads * config.turns,
        .generated_messages = config.threads * config.turns * 2,
        .completed_runs = completed_runs,
        .cancelled_runs = cancelled_runs,
        .prompt_bytes = prompt_bytes,
        .content_bytes = content_bytes,
        .provenance = .{ .generator = "build-history-fixture", .runtime = "domain.Host fake", .seed = config.seed, .name = config.name, .git_initialized = config.git_init },
    };
    var output: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try std.json.Stringify.value(manifest, .{ .whitespace = .minified }, &writer);
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var args_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer args_arena.deinit();
    const args = try init.args.toSlice(args_arena.allocator());
    const config = parse(args, io) catch |err| {
        try usage(io);
        return err;
    };
    const allocator = std.heap.page_allocator;
    const state_candidate = try canonicalNewPath(allocator, io, config.state_path);
    defer allocator.free(state_candidate);
    const workspace_candidate = try canonicalNewPath(allocator, io, config.workspace_path);
    defer allocator.free(workspace_candidate);
    if (pathsOverlap(state_candidate, workspace_candidate)) return error.AmbiguousPath;
    const state_path = try ensureFreshDirectory(allocator, io, config.state_path);
    defer allocator.free(state_path);
    const workspace_path = try ensureFreshDirectory(allocator, io, config.workspace_path);
    defer allocator.free(workspace_path);
    if (config.git_init) {
        // Capture the intended checkout identity only after creating its own
        // empty repository. Initializing Git after capture would invalidate
        // every Send binding and could inherit a surrounding checkout.
        const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", workspace_path, "init", "--quiet" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.GitInitFailed;
    }
    try runFixture(allocator, io, config, state_path, workspace_path);
}
