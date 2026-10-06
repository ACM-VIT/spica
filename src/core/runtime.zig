const std = @import("std");
const builtin = @import("builtin");
const native = @import("../native/bindings.zig").c;
const executables = @import("../platform/executables.zig");
const p = executables.c;
const storage = @import("store.zig");
const protocol = @import("protocol.zig");
const session = @import("session.zig");
const Value = std.json.Value;
const record_limit = 1024 * 1024;

pub const Behavior = enum { prompt, steer, follow_up };
pub const Status = enum { stopped, starting, ready, streaming, stopping, needs_force_stop, exited, failed };
pub const Model = struct { provider: []const u8, id: []const u8, name: []const u8 };
pub const Options = struct {
    database_path: []const u8,
    project_path: []const u8,
    node_path: ?[]const u8 = null,
    pi_entrypoint: ?[]const u8 = null,
    trust_project: bool = false,
    resume_file: ?[]const u8 = null,
    wake_event: u32,
};
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    status: Status = .stopped,
    revision: u64 = 0,
    bash_running: bool = false,
    runtime_id: u64 = 0,
    generation: i64 = 1,
    model: []const u8 = "",
    provider: []const u8 = "",
    session_file: []const u8 = "",
    session_id: []const u8 = "",
    session_name: []const u8 = "",
    thinking_level: []const u8 = "",
    last_ordinal: i64 = -1,
    active_count: i64 = 0,
    error_message: []const u8 = "",
    attention: []const u8 = "",
    visible_active_ordinal: i64 = -1,
    pending_draft: []const u8 = "",
    recovery_revision: u64 = 0,
    queued_count: usize = 0,
    rejected_command_id: []const u8 = "",
    accepted_command_id: []const u8 = "",
    models: []Model = &.{},
    thinking_levels: [][]const u8 = &.{},
    visible_content_ref: ?storage.ContentId = null,
    visible_revision: u64 = 0,
    visible_length: u64 = 0,
    thinking_content_ref: ?storage.ContentId = null,
    thinking_length: u64 = 0,
    role: []const u8 = "assistant",
    kind: []const u8 = "message",
    content_status: []const u8 = "",
    pub fn deinit(self: *Snapshot) void {
        inline for (.{ "model", "provider", "session_file", "session_id", "session_name", "thinking_level", "error_message", "attention", "pending_draft", "rejected_command_id", "accepted_command_id", "role", "kind", "content_status" }) |field| self.allocator.free(@field(self, field));
        for (self.models) |m| {
            self.allocator.free(m.provider);
            self.allocator.free(m.id);
            self.allocator.free(m.name);
        }
        self.allocator.free(self.models);
        for (self.thinking_levels) |level| self.allocator.free(level);
        self.allocator.free(self.thinking_levels);
    }
};

fn copySnapshot(a: std.mem.Allocator, original: Snapshot) !Snapshot {
    var result = original;
    result.allocator = a;
    var allocated: [14][]u8 = undefined;
    var count: usize = 0;
    errdefer for (allocated[0..count]) |bytes| a.free(bytes);
    inline for (.{ "model", "provider", "session_file", "session_id", "session_name", "thinking_level", "error_message", "attention", "pending_draft", "rejected_command_id", "accepted_command_id", "role", "kind", "content_status" }) |field| {
        const bytes = try a.dupe(u8, @field(original, field));
        allocated[count] = bytes;
        count += 1;
        @field(result, field) = bytes;
    }
    result.models = try a.alloc(Model, original.models.len);
    var model_count: usize = 0;
    errdefer {
        for (result.models[0..model_count]) |model| {
            a.free(model.provider);
            a.free(model.id);
            a.free(model.name);
        }
        a.free(result.models);
    }
    for (original.models, result.models) |model, *dest| {
        const provider = try a.dupe(u8, model.provider);
        errdefer a.free(provider);
        const id = try a.dupe(u8, model.id);
        errdefer a.free(id);
        const name = try a.dupe(u8, model.name);
        dest.* = .{ .provider = provider, .id = id, .name = name };
        model_count += 1;
    }
    result.thinking_levels = try a.alloc([]const u8, original.thinking_levels.len);
    var level_count: usize = 0;
    errdefer {
        for (result.thinking_levels[0..level_count]) |level| a.free(level);
        a.free(result.thinking_levels);
    }
    for (original.thinking_levels, result.thinking_levels) |level, *dest| {
        dest.* = try a.dupe(u8, level);
        level_count += 1;
    }
    return result;
}
const QueuedBytes = struct { data: []u8, command_id: ?u64 = null, bash: bool = false, stop: bool = false };
const Input = union(enum) { start, bytes: QueuedBytes, shutdown, force };
const Pending = struct { id: []u8, draft: []u8 };
const Block = struct { index: i64, id: storage.ContentId, length: u64 = 0 };
const Tool = struct {
    id: []u8,
    sequence: i64,
    activity: storage.Activity = .{},
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    status: []const u8 = "unknown",
    timestamp: i64 = 0,
    is_error: bool = false,
    content: ?storage.ContentId = null,
    length: u64 = 0,

    fn caption(self: *Tool, name: []const u8, args: Value) void {
        if (name.len > 0) {
            var size = @min(name.len, self.name.len);
            while (size > 0 and size < name.len and (name[size] & 0xc0) == 0x80) size -= 1;
            @memcpy(self.name[0..size], name[0..size]);
            self.name_len = @intCast(size);
        }
        if (args != .null or self.activity.len == 0) self.activity = session.toolActivity(self.name[0..self.name_len], args);
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    options_arena: std.heap.ArenaAllocator,
    mutex: *native.SDL_Mutex,
    thread: ?std.Thread = null,
    wake: [2]c_int,
    inputs: std.ArrayList(Input) = .empty,
    snapshot: ?Snapshot = null,
    state: Snapshot,
    closing: bool = false,
    accepting: bool = true,
    worker_done: bool = false,
    process: p.SpicaProcess = .{ .input = -1, .output = -1, .@"error" = -1, .exit_fd = -1, .pid = 0 },
    store: ?storage.Store = null,
    sink: Sink = undefined,
    next_id: u64 = 1,
    content_counter: u64 = 1,
    outgoing: std.ArrayList(u8) = .empty,
    write_offset: usize = 0,
    pending: std.ArrayList(Pending) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    sequence: i64 = 0,
    message_sequence: i64 = 0,
    message_timestamp: i64 = 0,
    last_entry_id: []const u8 = "",
    leaf_id: []const u8 = "",
    last_prompt: []const u8 = "",
    shutdown_deadline: ?u64 = null,
    stop_requested: bool = false,
    entries_inflight: bool = false,
    entries_again: bool = false,

    pub fn create(a: std.mem.Allocator, io: std.Io, options: Options) !*Runtime {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedRuntimeTarget;
        const self = try a.create(Runtime);
        errdefer a.destroy(self);
        const mutex = native.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer native.SDL_DestroyMutex(mutex);
        var wake: [2]c_int = undefined;
        if (p.spica_wake_create(&wake) != 0) return error.WakePipeCreation;
        errdefer {
            p.spica_close(wake[0]);
            p.spica_close(wake[1]);
        }
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const temp = arena.allocator();
        var owned = options;
        inline for (.{ "database_path", "project_path" }) |field| @field(owned, field) = try temp.dupeZ(u8, @field(options, field));
        inline for (.{ "node_path", "pi_entrypoint" }) |field| if (@field(options, field)) |path| {
            @field(owned, field) = try temp.dupeZ(u8, path);
        };
        if (options.resume_file) |file| owned.resume_file = try temp.dupeZ(u8, file);
        var state = try copySnapshot(a, .{ .allocator = a, .runtime_id = p.spica_runtime_id() });
        errdefer state.deinit();
        const last_entry = try a.dupe(u8, "");
        errdefer a.free(last_entry);
        const leaf = try a.dupe(u8, "");
        errdefer a.free(leaf);
        const last_prompt = try a.dupe(u8, "");
        errdefer a.free(last_prompt);
        if (state.runtime_id == 0) return error.RuntimeIdentityUnavailable;
        self.* = .{ .allocator = a, .io = io, .options = owned, .options_arena = arena, .mutex = mutex, .wake = wake, .state = state, .last_entry_id = last_entry, .leaf_id = leaf, .last_prompt = last_prompt };
        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }
    pub fn start(self: *Runtime) !void {
        try self.enqueue(.start);
    }
    pub fn sendPrompt(self: *Runtime, bytes: []const u8, behavior: Behavior) !u64 {
        if (bytes.len == 0 or bytes.len > 65536) return error.InvalidPrompt;
        return self.command(.{ .type = @tagName(behavior), .message = bytes }, bytes);
    }
    pub fn bash(self: *Runtime, bytes: []const u8) !void {
        _ = try self.command(.{ .type = "bash", .command = bytes }, null);
    }
    pub fn setModel(self: *Runtime, provider: []const u8, id: []const u8) !void {
        _ = try self.command(.{ .type = "set_model", .provider = provider, .modelId = id }, null);
    }
    pub fn newSession(self: *Runtime) !void {
        _ = try self.command(.{ .type = "new_session" }, null);
    }
    pub fn setSessionName(self: *Runtime, name: []const u8) !void {
        _ = try self.command(.{ .type = "set_session_name", .name = name }, null);
    }
    pub fn setThinkingLevel(self: *Runtime, level: []const u8) !void {
        _ = try self.command(.{ .type = "set_thinking_level", .level = level }, null);
    }
    pub fn stop(self: *Runtime) !void {
        // One queue item preserves ordering even with simultaneous UI producers.
        try self.enqueue(.{ .bytes = .{ .data = try self.allocator.dupe(u8, "{\"type\":\"clear_queue\"}\n{\"type\":\"abort\"}\n{\"type\":\"abort_bash\"}\n"), .stop = true } });
    }
    pub fn shutdown(self: *Runtime) !void {
        try self.enqueue(.shutdown);
    }
    pub fn forceTerminate(self: *Runtime) !void {
        try self.enqueue(.force);
    }
    pub fn takeSnapshot(self: *Runtime) ?Snapshot {
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        const result = self.snapshot;
        self.snapshot = null;
        return result;
    }
    pub fn isFinished(self: *Runtime) bool {
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        return self.worker_done;
    }
    /// Call only after isFinished; never joins an unresponsive child on the UI.
    pub fn destroy(self: *Runtime) !void {
        if (!self.isFinished()) return error.RuntimeStillRunning;
        self.thread.?.join();
        for (self.inputs.items) |input| if (input == .bytes) self.allocator.free(input.bytes.data);
        self.inputs.deinit(self.allocator);
        if (self.snapshot) |*snap| snap.deinit();
        self.state.deinit();
        self.options_arena.deinit();
        self.allocator.free(self.last_entry_id);
        self.allocator.free(self.leaf_id);
        self.allocator.free(self.last_prompt);
        self.outgoing.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        for (self.tools.items) |tool| self.allocator.free(tool.id);
        self.tools.deinit(self.allocator);
        for (self.pending.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.draft);
        }
        self.pending.deinit(self.allocator);
        p.spica_close(self.wake[0]);
        p.spica_close(self.wake[1]);
        native.SDL_DestroyMutex(self.mutex);
        const a = self.allocator;
        a.destroy(self);
    }
    fn enqueue(self: *Runtime, input: Input) !void {
        errdefer if (input == .bytes) self.allocator.free(input.bytes.data);
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        if (self.worker_done or (!self.accepting and input != .force)) return error.RuntimeClosed;
        if (self.inputs.items.len >= 128) return error.CommandQueueFull;
        try self.inputs.append(self.allocator, input);
        if (input == .shutdown) self.accepting = false;
        p.spica_wake(self.wake[1]);
    }
    fn command(self: *Runtime, value: anytype, draft: ?[]const u8) !u64 {
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        if (self.worker_done or !self.accepting) return error.RuntimeClosed;
        if (self.inputs.items.len >= 128) return error.CommandQueueFull;
        const token = self.next_id;
        const id = try std.fmt.allocPrint(self.allocator, "desktop-{d}", .{self.next_id});
        defer self.allocator.free(id);
        self.next_id += 1;
        const base = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(base);
        const line = try std.fmt.allocPrint(self.allocator, "{{\"id\":\"{s}\",{s}\n", .{ id, base[1..] });
        errdefer self.allocator.free(line);
        if (line.len > 128 * 1024) return error.CommandTooLarge;
        try self.inputs.ensureUnusedCapacity(self.allocator, 1);
        if (draft) |text| {
            if (self.pending.items.len >= 128) return error.CommandQueueFull;
            try self.pending.ensureUnusedCapacity(self.allocator, 1);
            const pending_id = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(pending_id);
            const pending_draft = try self.allocator.dupe(u8, text);
            self.pending.appendAssumeCapacity(.{ .id = pending_id, .draft = pending_draft });
        }
        self.inputs.appendAssumeCapacity(.{ .bytes = .{ .data = line, .command_id = token, .bash = std.mem.eql(u8, value.type, "bash") } });
        p.spica_wake(self.wake[1]);
        return token;
    }
    pub fn replace(self: *Runtime, target: *[]const u8, bytes: []const u8) !void {
        const bounded = if (target == &self.state.error_message or target == &self.state.attention) bytes[0..@min(bytes.len, 4096)] else bytes;
        const copy = try self.allocator.dupe(u8, bounded);
        self.allocator.free(target.*);
        target.* = copy;
    }
    fn publish(self: *Runtime) !void {
        self.state.revision += 1;
        const snap = try copySnapshot(self.allocator, self.state);
        native.SDL_LockMutex(self.mutex);
        const notify = self.snapshot == null;
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = snap;
        native.SDL_UnlockMutex(self.mutex);
        if (notify) {
            var notification = std.mem.zeroes(native.SDL_Event);
            notification.type = self.options.wake_event;
            _ = native.SDL_PushEvent(&notification);
        }
    }
    fn fail(self: *Runtime, err: anyerror) void {
        self.replace(&self.state.error_message, executables.errorMessage(err) orelse @errorName(err)) catch {};
        self.recoverDrafts() catch {};
        self.state.status = .failed;
        self.publish() catch {};
    }
    fn run(self: *Runtime) void {
        defer native.SDL_CleanupTLS();
        defer {
            native.SDL_LockMutex(self.mutex);
            self.accepting = false;
            self.worker_done = true;
            var unsent = self.inputs;
            self.inputs = .empty;
            native.SDL_UnlockMutex(self.mutex);
            for (unsent.items) |input| if (input == .bytes) {
                if (input.bytes.command_id) |token| self.rejectUnsent(token) catch {};
                self.allocator.free(input.bytes.data);
            };
            unsent.deinit(self.allocator);
            self.rejectOutstanding() catch {};
            self.publish() catch {};
            // Completion must wake even if allocation prevented a final snapshot.
            var notification = std.mem.zeroes(native.SDL_Event);
            notification.type = self.options.wake_event;
            _ = native.SDL_PushEvent(&notification);
        }
        self.store = storage.Store.init(self.allocator, self.options.database_path) catch |err| {
            self.fail(err);
            return;
        };
        defer self.store.?.deinit();
        self.sink = .{ .runtime = self };
        defer self.sink.deinit();
        var framer = protocol.Framer(Sink).init(self.allocator, &self.sink);
        defer framer.deinit();
        defer p.spica_process_dispose(&self.process);
        self.loop(&framer) catch |err| {
            // Finalize only the raw spool; never retry a reducer callback that failed.
            if (framer.scanner != null or framer.pending_cr) self.sink.quarantineFailure(framer.scanner != null, framer.pending_cr) catch {};
            self.fail(err);
            // Preserve ownership after failure; request orderly EOF, then allow an explicit force action.
            p.spica_close(self.process.input);
            self.process.input = -1;
            var failure_deadline: ?u64 = p.spica_monotonic_ms() + 5000;
            var reported_reap_failure = false;
            while (self.process.pid > 0) {
                var status: c_int = 0;
                const reaped = p.spica_process_reap(&self.process, &status);
                if (reaped == 1) break;
                var polling = self.process;
                if (reaped < 0) {
                    // Keep the pinned process owned, but do not spin on a ready pidfd.
                    polling.exit_fd = -1;
                    if (!reported_reap_failure) {
                        reported_reap_failure = true;
                        self.replace(&self.state.error_message, "Child reap failed; process ownership retained for explicit retry") catch {};
                        self.publish() catch {};
                    }
                }
                const timeout: c_int = if (failure_deadline) |deadline| @intCast(@min(1000, deadline -| p.spica_monotonic_ms())) else if (polling.exit_fd < 0) 1000 else -1;
                const bits = p.spica_process_poll(&polling, self.wake[0], 0, timeout);
                if (bits & 1 != 0) {
                    self.consumeWake();
                    self.processInputs() catch {};
                }
                self.drainDiscard();
                if (p.spica_process_reap(&self.process, &status) == 1) break;
                if (failure_deadline) |deadline| if (p.spica_monotonic_ms() >= deadline) {
                    failure_deadline = null;
                    self.state.status = .needs_force_stop;
                    self.publish() catch {};
                };
            }
        };
    }
    fn loop(self: *Runtime, framer: *protocol.Framer(Sink)) !void {
        while (true) {
            try self.processInputs();
            if (self.closing and self.process.pid == 0) {
                self.state.status = .exited;
                try self.publish();
                return;
            }
            if (self.closing and self.outgoing.items.len == 0 and self.process.input >= 0) {
                p.spica_close(self.process.input);
                self.process.input = -1;
            }
            var timeout: c_int = -1;
            if (self.shutdown_deadline) |deadline| timeout = @intCast(@min(5000, deadline -| p.spica_monotonic_ms()));
            const bits = p.spica_process_poll(&self.process, self.wake[0], @intFromBool(self.write_offset < self.outgoing.items.len), timeout);
            if (bits < 0) return error.ProcessPoll;
            if (bits & 1 != 0) self.consumeWake();
            if (bits & 2 != 0) try self.readStdout(framer);
            if (bits & 4 != 0) try self.readStderr();
            if (bits & 8 != 0) {
                const n = p.spica_process_write(self.process.input, self.outgoing.items.ptr + self.write_offset, self.outgoing.items.len - self.write_offset);
                if (n == -1) return error.ProcessInputClosed;
                if (n > 0) self.write_offset += @intCast(n);
                if (self.write_offset == self.outgoing.items.len) {
                    self.outgoing.clearRetainingCapacity();
                    self.write_offset = 0;
                }
            }
            if (self.closing and self.outgoing.items.len == 0 and self.process.input >= 0) {
                p.spica_close(self.process.input);
                self.process.input = -1;
            }
            if (bits & 16 != 0) {
                try self.readStdout(framer);
                try framer.eof();
                var status: c_int = 0;
                if (p.spica_process_reap(&self.process, &status) != 1) return error.ProcessWait;
                self.state.status = .exited;
                if (!self.closing) try self.replace(&self.state.error_message, "Pi exited unexpectedly; pending draft is recoverable");
                try self.publish();
                return;
            }
            if (self.shutdown_deadline) |deadline| if (p.spica_monotonic_ms() >= deadline) {
                self.shutdown_deadline = null;
                self.state.status = .needs_force_stop;
                try self.publish();
            };
        }
    }
    fn consumeWake(self: *Runtime) void {
        var b: [256]u8 = undefined;
        while (p.spica_process_read(self.wake[0], &b, b.len) > 0) {}
    }
    fn processInputs(self: *Runtime) !void {
        native.SDL_LockMutex(self.mutex);
        var inputs = self.inputs;
        self.inputs = .empty;
        native.SDL_UnlockMutex(self.mutex);
        defer {
            for (inputs.items) |input| if (input == .bytes) self.allocator.free(input.bytes.data);
            inputs.deinit(self.allocator);
        }
        for (inputs.items) |input| switch (input) {
            .start => if (self.process.pid == 0 and self.state.status == .stopped) {
                try self.launch();
            },
            .bytes => |queued| {
                if (self.process.pid == 0 or self.process.input < 0) {
                    try self.replace(&self.state.error_message, "Pi is not accepting commands; unsent draft retained");
                    if (queued.command_id) |token| try self.rejectUnsent(token);
                    try self.publish();
                } else {
                    if (self.outgoing.items.len + queued.data.len > 2 * 1024 * 1024) return error.OutgoingQueueFull;
                    try self.outgoing.appendSlice(self.allocator, queued.data);
                    if (queued.stop) self.stop_requested = true;
                    if (queued.bash) {
                        self.state.bash_running = true;
                        self.state.thinking_content_ref = null;
                        self.state.thinking_length = 0;
                        try self.publish();
                    }
                }
            },
            .shutdown => {
                self.closing = true;
                self.shutdown_deadline = p.spica_monotonic_ms() + 5000;
                self.state.status = .stopping;
                try self.publish();
            },
            .force => {
                if (p.spica_process_force(&self.process) != 0) {
                    self.state.status = .needs_force_stop;
                    try self.replace(&self.state.error_message, "Force termination failed; owned process retained. Retry Force explicitly.");
                    try self.publish();
                }
            },
        };
    }
    fn launch(self: *Runtime) !void {
        self.state.status = .starting;
        try self.publish();
        const paths = try executables.resolve(self.allocator, self.io, &self.process, self.options.node_path, self.options.pi_entrypoint);
        defer paths.deinit(self.allocator);
        const node = paths.node;
        const entry = paths.entry;
        if (p.spica_process_version(&self.process, node, entry) != 0) return error.PiVersionMismatchOrVerificationFailed;
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, self.options.project_path, self.allocator);
        defer self.allocator.free(cwd);
        self.options.project_path = try self.options_arena.allocator().dupeZ(u8, cwd);
        const resume_path = if (self.options.resume_file) |file| try std.Io.Dir.cwd().realPathFileAlloc(self.io, file, self.allocator) else null;
        defer if (resume_path) |file| self.allocator.free(file);
        if (p.spica_process_spawn(&self.process, node, entry, cwd, if (resume_path) |r| r.ptr else null, @intFromBool(self.options.trust_project)) != 0) return error.PiLaunchFailed;
        try self.requestState();
        try self.queue(.{ .type = "get_available_models" });
        try self.queue(.{ .type = "get_available_thinking_levels" });
    }
    fn requestState(self: *Runtime) !void {
        try self.queue(.{ .type = "get_state", .id = self.state.generation });
    }
    fn queue(self: *Runtime, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(bytes);
        try self.outgoing.appendSlice(self.allocator, bytes);
        try self.outgoing.append(self.allocator, '\n');
    }
    fn readStdout(self: *Runtime, framer: *protocol.Framer(Sink)) !void {
        var b: [65536]u8 = undefined;
        while (self.process.output >= 0) {
            const n = p.spica_process_read(self.process.output, &b, b.len);
            if (n == -2) break;
            if (n < 0) return error.ProcessOutputRead;
            if (n == 0) {
                p.spica_close(self.process.output);
                self.process.output = -1;
                break;
            }
            try framer.ingest(b[0..@intCast(n)]);
        }
    }
    fn readStderr(self: *Runtime) !void {
        var b: [4096]u8 = undefined;
        while (self.process.@"error" >= 0) {
            const n = p.spica_process_read(self.process.@"error", &b, b.len);
            if (n == -2) break;
            if (n < 0) return error.ProcessErrorRead;
            if (n == 0) {
                p.spica_close(self.process.@"error");
                self.process.@"error" = -1;
                break;
            }
            const id = try self.content(b[0..@intCast(n)], "text/plain");
            try self.store.?.addDiagnostic(self.state.session_file, self.state.runtime_id, "stderr", "Pi process stderr", id, 0);
        }
    }
    fn drainDiscard(self: *Runtime) void {
        var b: [4096]u8 = undefined;
        inline for (.{ "output", "error" }) |field| {
            const fd = @field(self.process, field);
            if (fd >= 0) {
                var n = p.spica_process_read(fd, &b, b.len);
                while (n > 0) {
                    const id = self.content(b[0..@intCast(n)], "application/octet-stream") catch null;
                    self.store.?.addDiagnostic(self.state.session_file, self.state.runtime_id, "post_failure_process_bytes", field, id, 0) catch {};
                    n = p.spica_process_read(fd, &b, b.len);
                }
                if (n == 0 or n == -1) {
                    p.spica_close(fd);
                    @field(self.process, field) = -1;
                }
            }
        }
    }
    pub fn newContentId(self: *Runtime) storage.ContentId {
        var id: storage.ContentId = undefined;
        std.mem.writeInt(u64, id[0..8], self.state.runtime_id, .little);
        std.mem.writeInt(u64, id[8..16], self.content_counter, .little);
        self.content_counter += 1;
        return id;
    }
    pub fn content(self: *Runtime, bytes: []const u8, mime: []const u8) !storage.ContentId {
        const id = self.newContentId();
        try self.store.?.beginContent(id, "utf-8", mime);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(bytes.len, offset + storage.chunk_size);
            try self.store.?.append(id, offset, bytes[offset..end], end == bytes.len);
            offset = end;
        }
        if (bytes.len == 0) try self.store.?.append(id, 0, "", true);
        return id;
    }
    fn offerRecovery(self: *Runtime, text: []const u8) !void {
        try self.replace(&self.state.pending_draft, text);
        if (text.len != 0) self.state.recovery_revision += 1;
    }

    fn recoverCancelledQueue(self: *Runtime, data: Value) !void {
        const steering = child(data, "steering");
        const follow_up = child(data, "followUp");
        if (steering != .array or follow_up != .array) return error.UnsupportedCancelledQueue;
        const count = steering.array.items.len + follow_up.array.items.len;
        if (count == 0) return;
        var draft = if (follow_up.array.items.len > 0) follow_up.array.items[follow_up.array.items.len - 1] else steering.array.items[steering.array.items.len - 1];
        // Prefer the newest locally acknowledged input if it was cancelled.
        // Pi's separate arrays do not encode cross-queue chronological order.
        inline for (.{ steering, follow_up }) |queue_value| {
            for (queue_value.array.items) |item| {
                if (item != .string) return error.UnsupportedCancelledQueue;
                if (std.mem.eql(u8, item.string, self.last_prompt)) draft = item;
            }
        }
        try self.offerRecovery(draft.string);
        try self.replace(&self.state.attention, "Cancelled queued messages retained in protocol cache");
    }

    fn recoverDrafts(self: *Runtime) !void {
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        try self.offerRecovery(if (self.pending.items.len > 0) self.pending.items[self.pending.items.len - 1].draft else self.last_prompt);
    }
    fn rejectUnsent(self: *Runtime, token: u64) !void {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "desktop-{d}", .{token});
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        try self.replace(&self.state.rejected_command_id, id);
        for (self.pending.items, 0..) |item, i| if (std.mem.eql(u8, id, item.id)) {
            try self.offerRecovery(item.draft);
            self.allocator.free(item.id);
            self.allocator.free(item.draft);
            _ = self.pending.orderedRemove(i);
            break;
        };
    }
    fn rejectOutstanding(self: *Runtime) !void {
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        if (self.pending.items.len > 0) {
            const latest = self.pending.items[self.pending.items.len - 1];
            try self.replace(&self.state.rejected_command_id, latest.id);
            try self.offerRecovery(latest.draft);
        }
        for (self.pending.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.draft);
        }
        self.pending.clearRetainingCapacity();
    }
    fn acknowledge(self: *Runtime, value: Value) !void {
        const id = string(value, "id");
        if (id.len == 0) return;
        native.SDL_LockMutex(self.mutex);
        defer native.SDL_UnlockMutex(self.mutex);
        for (self.pending.items, 0..) |item, i| if (std.mem.eql(u8, id, item.id)) {
            if (boolean(value, "success")) {
                try self.replace(&self.state.accepted_command_id, id);
                try self.replace(&self.last_prompt, item.draft);
                try self.replace(&self.state.pending_draft, "");
            } else {
                try self.replace(&self.state.rejected_command_id, id);
                try self.offerRecovery(item.draft);
            }
            self.allocator.free(item.id);
            self.allocator.free(item.draft);
            _ = self.pending.orderedRemove(i);
            break;
        };
    }
    pub fn visible(self: *Runtime, id: storage.ContentId, length: u64, role: []const u8, kind: []const u8, status: []const u8) !void {
        self.state.visible_content_ref = id;
        self.state.visible_length = length;
        self.state.visible_revision += 1;
        try self.replace(&self.state.role, role);
        try self.replace(&self.state.kind, kind);
        try self.replace(&self.state.content_status, status);
    }

    fn toolFor(self: *Runtime, call: []const u8, raw: storage.ContentId) !?*Tool {
        for (self.tools.items) |*tool| if (std.mem.eql(u8, tool.id, call)) return tool;
        if (call.len == 0 or call.len > 4096 or self.tools.items.len >= 128) {
            try self.inspect(raw, "unsupported_tool_budget", "Tool identity or concurrent tool budget unsupported; complete record retained");
            return null;
        }
        const id = try self.allocator.dupe(u8, call);
        errdefer self.allocator.free(id);
        self.sequence += 1;
        try self.tools.append(self.allocator, .{ .id = id, .sequence = self.sequence });
        return &self.tools.items[self.tools.items.len - 1];
    }

    fn toolRow(self: *Runtime, tool: *Tool, status: []const u8) !void {
        if (tool.content == null) tool.content = try self.content("", "text/markdown");
        tool.status = status;
        try self.store.?.putLiveRow(.{
            .runtime = self.state.runtime_id,
            .run_generation = self.state.generation,
            .local_sequence = tool.sequence,
            .content_index = 0,
            .row = .{
                .row_id = tool.id,
                .kind = "tool",
                .role = "toolResult",
                .revision = @intCast(self.state.revision),
                .title = tool.activity.slice(),
                .status = if (tool.is_error) "failed" else status,
                .content_ref = tool.content,
                .tool_call_id = tool.id,
                .is_error = tool.is_error,
                .timestamp = tool.timestamp,
            },
        });
    }

    fn projectTool(self: *Runtime, value: Value, raw: storage.ContentId) !void {
        const tool = (try self.toolFor(string(value, "toolCallId"), raw)) orelse return;
        const name = string(value, "toolName");
        const args = child(value, "args");
        // Partial results usually omit metadata; preserve the initial caption.
        tool.caption(name, args);
        const stamp = session.timestamp(value);
        if (stamp != 0 and (tool.timestamp == 0 or std.mem.eql(u8, tool.status, "unknown"))) tool.timestamp = stamp;
        const ended = std.mem.endsWith(u8, string(value, "type"), "_end");
        const result = if (ended) child(value, "result") else child(value, "partialResult");
        tool.is_error = tool.is_error or boolean(value, "isError") or boolean(result, "isError") or string(result, "errorMessage").len > 0;
        if (result != .null) {
            const body = try session.messageText(self.allocator, result);
            defer self.allocator.free(body);
            tool.content = try self.content(body, "text/markdown");
            tool.length = body.len;
        }
        const status = if (tool.is_error) "failed" else if (ended) "complete" else "running";
        try self.toolRow(tool, status);
        try self.visible(tool.content.?, tool.length, "toolResult", "tool", status);
    }
    fn clearThinkingLevels(self: *Runtime) void {
        for (self.state.thinking_levels) |level| self.allocator.free(level);
        self.allocator.free(self.state.thinking_levels);
        self.state.thinking_levels = &.{};
    }
    fn event(self: *Runtime, value: Value, raw: storage.ContentId) !void {
        const ty = string(value, "type");
        const data = child(value, "data");
        if (std.mem.eql(u8, ty, "response")) {
            const command_name = string(value, "command");
            // Pi handles RPC input concurrently. Replies queued before a successful
            // new_session must never import the outgoing history into its successor.
            if ((std.mem.eql(u8, command_name, "get_state") or std.mem.eql(u8, command_name, "get_entries")) and integer(value, "id") != self.state.generation) return;
            try self.acknowledge(value);
            if (!boolean(value, "success")) {
                if (std.mem.eql(u8, string(value, "command"), "bash")) self.state.bash_running = false;
                if (std.mem.eql(u8, string(value, "command"), "get_entries")) {
                    self.entries_inflight = false;
                    self.entries_again = false;
                }
                try self.replace(&self.state.error_message, string(value, "error"));
                try self.publish();
                return;
            }
            if (std.mem.eql(u8, command_name, "get_state")) {
                try self.replace(&self.state.session_file, string(data, "sessionFile"));
                try self.replace(&self.state.session_id, string(data, "sessionId"));
                try self.replace(&self.state.session_name, string(data, "sessionName"));
                try self.replace(&self.state.thinking_level, string(data, "thinkingLevel"));
                const model = child(data, "model");
                try self.replace(&self.state.model, string(model, "id"));
                try self.replace(&self.state.provider, string(model, "provider"));
                self.state.status = if (self.closing) .stopping else if (boolean(data, "isStreaming")) .streaming else .ready;
                if (self.state.session_file.len > 0) {
                    try self.persistSession();
                    try self.requestEntries();
                }
            } else if (std.mem.eql(u8, command_name, "clear_queue")) {
                try self.recoverCancelledQueue(data);
            } else if (std.mem.eql(u8, command_name, "get_available_models")) {
                const models = child(data, "models");
                var next_models: std.ArrayList(Model) = .empty;
                errdefer {
                    for (next_models.items) |m| {
                        self.allocator.free(m.provider);
                        self.allocator.free(m.id);
                        self.allocator.free(m.name);
                    }
                    next_models.deinit(self.allocator);
                }
                if (models == .array) for (models.array.items[0..@min(models.array.items.len, 256)]) |model| {
                    const provider = try self.allocator.dupe(u8, string(model, "provider"));
                    errdefer self.allocator.free(provider);
                    const id = try self.allocator.dupe(u8, string(model, "id"));
                    errdefer self.allocator.free(id);
                    const name = try self.allocator.dupe(u8, string(model, "name"));
                    errdefer self.allocator.free(name);
                    try next_models.append(self.allocator, .{ .provider = provider, .id = id, .name = name });
                };
                const owned_models = try next_models.toOwnedSlice(self.allocator);
                for (self.state.models) |m| {
                    self.allocator.free(m.provider);
                    self.allocator.free(m.id);
                    self.allocator.free(m.name);
                }
                self.allocator.free(self.state.models);
                self.state.models = owned_models;
                if (models == .array and models.array.items.len > 256) {
                    try self.inspect(raw, "model_display_budget", "Available model list exceeds first-pass display budget; complete list retained");
                    try self.replace(&self.state.attention, "Available model list exceeds first-pass display budget");
                }
            } else if (std.mem.eql(u8, command_name, "get_available_thinking_levels")) {
                const levels = child(data, "levels");
                if (levels != .array) return error.UnsupportedThinkingLevels;
                var next_levels: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (next_levels.items) |level| self.allocator.free(level);
                    next_levels.deinit(self.allocator);
                }
                for (levels.array.items[0..@min(levels.array.items.len, 256)]) |level| {
                    if (level != .string) return error.UnsupportedThinkingLevel;
                    const owned = try self.allocator.dupe(u8, level.string);
                    errdefer self.allocator.free(owned);
                    try next_levels.append(self.allocator, owned);
                }
                const owned_levels = try next_levels.toOwnedSlice(self.allocator);
                self.clearThinkingLevels();
                self.state.thinking_levels = owned_levels;
                if (levels.array.items.len > 256) try self.inspect(raw, "thinking_level_display_budget", "Complete supported thinking-level list retained in raw response");
            } else if (std.mem.eql(u8, command_name, "set_model")) {
                try self.replace(&self.state.model, string(data, "id"));
                try self.replace(&self.state.provider, string(data, "provider"));
                self.clearThinkingLevels();
                try self.requestState();
                try self.queue(.{ .type = "get_available_thinking_levels" });
            } else if (std.mem.eql(u8, command_name, "set_thinking_level") or std.mem.eql(u8, command_name, "set_session_name")) {
                try self.requestState();
            } else if (std.mem.eql(u8, command_name, "new_session")) {
                if (boolean(data, "cancelled")) {
                    try self.replace(&self.state.attention, "New session was cancelled; current thread retained");
                } else {
                    const generation = try std.math.add(i64, self.state.generation, 1);
                    try self.store.?.clearLiveGeneration(self.state.runtime_id, self.state.generation);
                    try self.replace(&self.last_entry_id, "");
                    try self.replace(&self.leaf_id, "");
                    try self.replace(&self.last_prompt, "");
                    try self.replace(&self.state.session_file, "");
                    try self.replace(&self.state.session_id, "");
                    try self.replace(&self.state.session_name, "");
                    try self.replace(&self.state.attention, "");
                    try self.replace(&self.state.error_message, "");
                    try self.replace(&self.state.content_status, "");
                    self.state.queued_count = 0;
                    self.state.bash_running = false;
                    self.stop_requested = false;
                    self.state.generation = generation;
                    self.state.last_ordinal = -1;
                    self.state.active_count = 0;
                    self.state.visible_active_ordinal = -1;
                    self.state.visible_content_ref = null;
                    self.state.visible_length = 0;
                    self.state.visible_revision +|= 1;
                    self.state.thinking_content_ref = null;
                    self.state.thinking_length = 0;
                    self.entries_inflight = false;
                    self.entries_again = false;
                    self.blocks.clearRetainingCapacity();
                    for (self.tools.items) |tool| self.allocator.free(tool.id);
                    self.tools.clearRetainingCapacity();
                    self.sequence = 0;
                    self.message_sequence = 0;
                    try self.requestState();
                    try self.queue(.{ .type = "get_available_thinking_levels" });
                }
            } else if (std.mem.eql(u8, command_name, "bash")) {
                self.state.bash_running = false;
                const output = string(data, "output");
                const id = try self.content(output, "text/plain");
                try self.visible(id, output.len, "bashExecution", "bash", "complete");
                try self.requestState();
            }
        } else if (std.mem.eql(u8, ty, "queue_update")) {
            const steering = child(value, "steering");
            const follow_up = child(value, "followUp");
            if (steering != .array or follow_up != .array) return error.UnsupportedQueueUpdate;
            self.state.queued_count = steering.array.items.len + follow_up.array.items.len;
        } else if (std.mem.eql(u8, ty, "agent_start")) {
            self.stop_requested = false;
            self.state.status = .streaming;
            try self.replace(&self.state.error_message, "");
        } else if (std.mem.eql(u8, ty, "agent_end")) {
            // A completed run can immediately yield to queued work. Ask Pi for
            // authoritative activity instead of leaving streaming latched or
            // prematurely treating a follow-up as a fresh prompt.
            if (!self.closing) try self.requestState();
        } else if (std.mem.eql(u8, ty, "agent_settled")) {
            self.state.status = if (self.closing) .stopping else .ready;
            if (!self.closing) try self.requestState();
        } else if (std.mem.eql(u8, ty, "message_start")) {
            const message = child(value, "message");
            if (std.mem.eql(u8, string(message, "role"), "assistant")) {
                self.blocks.clearRetainingCapacity();
                self.sequence += 1;
                self.message_sequence = self.sequence;
                self.message_timestamp = session.timestamp(message);
                self.state.thinking_content_ref = null;
                self.state.thinking_length = 0;
            } else if (std.mem.eql(u8, string(message, "role"), "user")) {
                self.sequence += 1;
                const text = try session.messageText(self.allocator, message);
                defer self.allocator.free(text);
                const id = try self.content(text, "text/markdown");
                try self.store.?.putLiveRow(.{ .runtime = self.state.runtime_id, .run_generation = self.state.generation, .local_sequence = self.sequence, .content_index = 0, .row = .{ .row_id = "live-user", .kind = "message", .role = "user", .revision = @intCast(self.state.revision), .status = "complete", .content_ref = id, .timestamp = session.timestamp(message) } });
                self.state.thinking_content_ref = null;
                self.state.thinking_length = 0;
                try self.visible(id, text.len, "user", "message", "complete");
            }
        } else if (std.mem.eql(u8, ty, "message_update")) {
            const update = child(value, "assistantMessageEvent");
            const update_type = string(update, "type");
            if (std.mem.eql(u8, update_type, "text_delta") or std.mem.eql(u8, update_type, "thinking_delta") or std.mem.eql(u8, update_type, "text_end") or std.mem.eql(u8, update_type, "thinking_end")) {
                const index = integer(update, "contentIndex");
                var found: ?usize = null;
                for (self.blocks.items, 0..) |block, i| if (block.index == index) {
                    found = i;
                    break;
                };
                const replacing = std.mem.endsWith(u8, update_type, "_end");
                if (found == null and self.blocks.items.len >= 256) {
                    try self.inspect(raw, "unsupported_content_budget", "Message exceeds 256 live content blocks");
                    return;
                }
                if (found == null) {
                    const id = self.newContentId();
                    try self.store.?.beginContent(id, "utf-8", "text/markdown");
                    try self.blocks.append(self.allocator, .{ .index = index, .id = id });
                    found = self.blocks.items.len - 1;
                }
                const block = &self.blocks.items[found.?];
                if (replacing) {
                    const text = string(update, "content");
                    block.id = try self.content(text, "text/markdown");
                    block.length = text.len;
                } else {
                    const delta = string(update, "delta");
                    var offset: usize = 0;
                    while (offset < delta.len) {
                        const end = @min(delta.len, offset + storage.chunk_size);
                        try self.store.?.append(block.id, block.length, delta[offset..end], false);
                        block.length += end - offset;
                        offset = end;
                    }
                }
                const thinking = std.mem.startsWith(u8, update_type, "thinking");
                if (thinking) {
                    self.state.thinking_content_ref = block.id;
                    self.state.thinking_length = block.length;
                } else try self.visible(block.id, block.length, "assistant", "message", "streaming");
                try self.store.?.putLiveRow(.{ .runtime = self.state.runtime_id, .run_generation = self.state.generation, .local_sequence = self.message_sequence, .content_index = index, .row = .{ .row_id = "live-assistant", .kind = if (thinking) "thinking" else "message", .role = "assistant", .revision = @intCast(self.state.revision), .status = "streaming", .content_ref = block.id, .timestamp = self.message_timestamp } });
            } else try self.inspect(raw, "unsupported_update", update_type);
        } else if (std.mem.eql(u8, ty, "message_end")) {
            const message = child(value, "message");
            const role = string(message, "role");
            if (std.mem.eql(u8, role, "assistant")) {
                const text = try session.messageText(self.allocator, message);
                defer self.allocator.free(text);
                const id = try self.content(text, "text/markdown");
                const source_stamp = session.timestamp(message);
                const stamp = if (source_stamp != 0) source_stamp else self.message_timestamp;
                try self.store.?.clearLiveMessage(self.state.runtime_id, self.state.generation, self.message_sequence);
                try self.store.?.putLiveRow(.{ .runtime = self.state.runtime_id, .run_generation = self.state.generation, .local_sequence = self.message_sequence, .content_index = 0, .row = .{ .row_id = "live-assistant", .kind = "message", .role = role, .revision = @intCast(self.state.revision), .status = if (string(message, "errorMessage").len > 0 or std.mem.eql(u8, string(message, "stopReason"), "error")) "failed" else "complete", .content_ref = id, .timestamp = stamp } });
                try self.visible(id, text.len, role, "message", "complete");
                const thinking = try session.thinkingText(self.allocator, message);
                defer self.allocator.free(thinking);
                self.state.thinking_content_ref = if (thinking.len > 0) try self.content(thinking, "text/markdown") else null;
                self.state.thinking_length = thinking.len;
                const blocks = child(message, "content");
                if (blocks == .array) for (blocks.array.items) |block| {
                    if (!std.mem.eql(u8, string(block, "type"), "toolCall")) continue;
                    const tool = (try self.toolFor(string(block, "id"), raw)) orelse continue;
                    tool.caption(string(block, "name"), child(block, "arguments"));
                    if (tool.timestamp == 0) tool.timestamp = stamp;
                    try self.toolRow(tool, tool.status);
                };
                const err = string(message, "errorMessage");
                const requested_abort = (self.stop_requested or self.closing) and std.mem.eql(u8, string(message, "stopReason"), "aborted");
                if (err.len > 0 and !requested_abort) {
                    try self.replace(&self.state.error_message, err);
                    try self.recoverDrafts();
                }
            }
        } else if (std.mem.startsWith(u8, ty, "tool_execution_")) {
            try self.projectTool(value, raw);
        } else if (std.mem.eql(u8, ty, "bash_execution_update")) {
            const delta = string(value, "delta");
            if (!std.mem.eql(u8, self.state.kind, "bash") or self.state.visible_content_ref == null) {
                const id = self.newContentId();
                try self.store.?.beginContent(id, "utf-8", "text/markdown");
                try self.visible(id, 0, "toolResult", "bash", "running");
            }
            var offset: usize = 0;
            while (offset < delta.len) {
                const end = @min(delta.len, offset + storage.chunk_size);
                try self.store.?.append(self.state.visible_content_ref.?, self.state.visible_length, delta[offset..end], false);
                self.state.visible_length += end - offset;
                offset = end;
            }
            self.state.visible_revision += 1;
        } else if (std.mem.eql(u8, ty, "extension_ui_request")) {
            try self.inspect(raw, "pending_extension_request", string(value, "method"));
            try self.replace(&self.state.attention, "Extension request pending: inspect retained protocol record; no response was invented");
        } else if (std.mem.eql(u8, ty, "extension_error")) {
            try self.replace(&self.state.error_message, string(value, "error"));
            try self.inspect(raw, "extension_error", self.state.error_message);
        } else {
            try self.inspect(raw, "unsupported_protocol", ty);
        }
        try self.publish();
    }
    pub fn inspect(self: *Runtime, raw: storage.ContentId, kind: []const u8, summary: []const u8) !void {
        try self.store.?.addDiagnostic(self.state.session_file, self.state.runtime_id, kind, summary[0..@min(summary.len, 2048)], raw, 0);
    }
    pub fn persistSession(self: *Runtime) !void {
        try self.store.?.putSession(.{ .session_file = self.state.session_file, .session_id = self.state.session_id, .project_id = self.options.project_path, .leaf_id = if (self.leaf_id.len > 0) self.leaf_id else null, .last_entry_id = if (self.last_entry_id.len > 0) self.last_entry_id else null });
    }
    pub fn requestEntries(self: *Runtime) !void {
        if (self.entries_inflight) {
            self.entries_again = true;
            return;
        }
        if (self.last_entry_id.len == 0) try self.queue(.{ .type = "get_entries", .id = self.state.generation }) else try self.queue(.{ .type = "get_entries", .id = self.state.generation, .since = self.last_entry_id });
        self.entries_inflight = true;
    }
};

test "live tool updates preserve captions timestamps output and failure state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/live-tools.sqlite", .{tmp.sub_path});
    defer allocator.free(db_path);
    var runtime: Runtime = .{
        .allocator = allocator,
        .io = undefined,
        .options = undefined,
        .options_arena = undefined,
        .mutex = undefined,
        .wake = undefined,
        .state = .{ .allocator = allocator, .runtime_id = 7, .role = "", .kind = "" },
        .store = try storage.Store.init(allocator, db_path),
    };
    defer runtime.store.?.deinit();
    defer {
        allocator.free(runtime.state.role);
        allocator.free(runtime.state.kind);
        allocator.free(runtime.state.content_status);
        for (runtime.tools.items) |tool| allocator.free(tool.id);
        runtime.tools.deinit(allocator);
    }
    const events = [_][]const u8{
        \\{"type":"tool_execution_start","toolCallId":"bash-1","toolName":"bash","args":{"command":"git status --short"},"timestamp":1234}
        ,
        \\{"type":"tool_execution_update","toolCallId":"bash-1","partialResult":{"content":[{"type":"text","text":"fatal: not a repository"}],"isError":true}}
        ,
        \\{"type":"tool_execution_end","toolCallId":"bash-1"}
        ,
    };
    for (events, 0..) |bytes, index| {
        const parsed = try std.json.parseFromSlice(Value, allocator, bytes, .{});
        defer parsed.deinit();
        try runtime.projectTool(parsed.value, @splat(0));
        const entries = try runtime.store.?.conversationEntries(allocator, "/live.jsonl", false, 7, 1);
        defer allocator.free(entries);
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqualStrings("bash git status --short", entries[0].activity[0..entries[0].activity_len]);
        try std.testing.expectEqual(@as(i64, 1234), entries[0].timestamp);
        try std.testing.expectEqual(@as(@TypeOf(entries[0].status), if (index == 0) .running else .failed), entries[0].status);
        if (index > 0) {
            const output = (try runtime.store.?.readChunk(allocator, entries[0].content_id, 0)).?;
            defer allocator.free(output);
            try std.testing.expectEqualStrings("fatal: not a repository", output);
        }
    }
    const tool = (try runtime.toolFor("pending-read", @splat(0))).?;
    const args = try std.json.parseFromSlice(Value, allocator, "{\"path\":\"README.md\"}", .{});
    defer args.deinit();
    tool.caption("read", args.value);
    try runtime.toolRow(tool, "unknown");
    const waiting = try runtime.store.?.conversationEntries(allocator, "/live.jsonl", false, 7, 1);
    defer allocator.free(waiting);
    try std.testing.expectEqual(.unknown, waiting[1].status);
    const start = try std.json.parseFromSlice(Value, allocator, "{\"type\":\"tool_execution_start\",\"toolCallId\":\"pending-read\"}", .{});
    defer start.deinit();
    try runtime.projectTool(start.value, @splat(0));
    const pending = try runtime.store.?.conversationEntries(allocator, "/live.jsonl", false, 7, 1);
    defer allocator.free(pending);
    try std.testing.expectEqualStrings("read README.md", pending[1].activity[0..pending[1].activity_len]);
    try std.testing.expectEqual(.running, pending[1].status);
    try std.testing.expectEqual(@as(i64, 0), pending[1].timestamp);
    const end = try std.json.parseFromSlice(Value, allocator, "{\"type\":\"tool_execution_end\",\"toolCallId\":\"pending-read\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"configuration\"}]}}", .{});
    defer end.deinit();
    try runtime.projectTool(end.value, @splat(0));
    const completed = try runtime.store.?.conversationEntries(allocator, "/live.jsonl", false, 7, 1);
    defer allocator.free(completed);
    try std.testing.expectEqual(.complete, completed[1].status);
    try std.testing.expectEqualStrings("complete", runtime.state.content_status);
}

pub fn child(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
pub fn string(value: Value, key: []const u8) []const u8 {
    const item = child(value, key);
    return if (item == .string) item.string else "";
}
pub fn boolean(value: Value, key: []const u8) bool {
    const item = child(value, key);
    return item == .bool and item.bool;
}
pub fn integer(value: Value, key: []const u8) i64 {
    const item = child(value, key);
    return if (item == .integer) item.integer else 0;
}

const Sink = struct {
    runtime: *Runtime,
    id: storage.ContentId = undefined,
    length: u64 = 0,
    index: u64 = 0,
    chunk: ?[]u8 = null,
    finalized: bool = false,
    pub fn deinit(self: *Sink) void {
        if (self.chunk) |bytes| self.runtime.allocator.free(bytes);
    }
    pub fn beginRecord(self: *Sink) !void {
        self.id = self.runtime.newContentId();
        self.length = 0;
        self.finalized = false;
        try self.runtime.store.?.beginContent(self.id, "utf-8", "application/json");
    }
    pub fn appendRecord(self: *Sink, bytes: []const u8) !void {
        try self.runtime.store.?.append(self.id, self.length, bytes, false);
        self.length += bytes.len;
    }
    pub fn rewindRecord(self: *Sink) !void {
        if (!self.finalized) {
            try self.runtime.store.?.append(self.id, self.length, "", true);
            self.finalized = true;
        }
        self.index = 0;
    }
    pub fn readRecordChunk(self: *Sink) !?[]const u8 {
        if (self.chunk) |bytes| self.runtime.allocator.free(bytes);
        self.chunk = try self.runtime.store.?.readChunk(self.runtime.allocator, self.id, self.index);
        self.index += 1;
        return self.chunk;
    }
    fn quarantineFailure(self: *Sink, has_record: bool, pending_cr: bool) !void {
        if (!has_record) try self.beginRecord();
        if (pending_cr and !self.finalized) try self.appendRecord("\r");
        try self.rewindRecord();
        try self.runtime.inspect(self.id, "quarantined_protocol", "Runtime failure interrupted raw record processing; no protocol replay");
    }
    pub fn onQuarantine(self: *Sink, source: anytype, reason: anytype) !void {
        _ = source;
        try self.runtime.inspect(self.id, "quarantined_protocol", @tagName(reason));
        try self.runtime.replace(&self.runtime.state.attention, "Quarantined malformed protocol record retained for inspection");
        try self.runtime.publish();
    }
    pub fn onValid(self: *Sink, source: anytype) !void {
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(self.runtime.allocator);
        while (prefix.items.len < 4096) {
            const part = (try source.next()) orelse break;
            try prefix.appendSlice(self.runtime.allocator, part);
        }
        const first = prefix.items;
        if (first.len == 0) return;
        if (std.mem.indexOf(u8, first[0..@min(first.len, 4096)], "\"command\":\"get_entries\"") != null and std.mem.indexOf(u8, first, "\"entries\":[") != null) {
            // The pinned pi serializer puts id first in the compact response header.
            // Check it before the streaming reducer can mutate canonical rows.
            const id_prefix = "{\"id\":";
            if (!std.mem.startsWith(u8, first, id_prefix)) return;
            const id_end = std.mem.indexOfScalarPos(u8, first, id_prefix.len, ',') orelse return;
            const generation = std.fmt.parseInt(i64, first[id_prefix.len..id_end], 10) catch return;
            if (generation != self.runtime.state.generation) return;
            self.runtime.entries_inflight = false;
            session.reconcile(self.runtime, source, first) catch |err| switch (err) {
                error.OutOfMemory, error.SqliteFailure => return err,
                else => {
                    self.runtime.entries_again = false;
                    try self.runtime.inspect(self.id, "unsupported_entries_shape", @errorName(err));
                    try self.runtime.replace(&self.runtime.state.attention, "Unsupported canonical entry shape retained for inspection");
                    try self.runtime.publish();
                    return;
                },
            };
            if (self.runtime.entries_again) {
                self.runtime.entries_again = false;
                try self.runtime.requestEntries();
            }
            try self.runtime.publish();
            return;
        }
        if (source.length > record_limit) {
            try self.runtime.inspect(self.id, "unsupported_oversized_record", "Record exceeds bounded reducer; complete raw bytes retained");
            try self.runtime.replace(&self.runtime.state.attention, "Oversized protocol record retained on disk for inspection");
            try self.runtime.publish();
            return;
        }
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.runtime.allocator);
        try bytes.appendSlice(self.runtime.allocator, first);
        while (try source.next()) |chunk| try bytes.appendSlice(self.runtime.allocator, chunk);
        const parsed = std.json.parseFromSlice(Value, self.runtime.allocator, bytes.items, .{ .allocate = .alloc_always, .max_value_len = record_limit }) catch {
            try self.runtime.inspect(self.id, "unsupported_protocol_shape", "Valid JSON exceeds supported reducer shape");
            return;
        };
        defer parsed.deinit();
        self.runtime.event(parsed.value, self.id) catch |err| switch (err) {
            error.OutOfMemory, error.SqliteFailure => return err,
            else => {
                try self.runtime.inspect(self.id, "unsupported_protocol_fields", @errorName(err));
                try self.runtime.replace(&self.runtime.state.attention, "Unsupported protocol fields retained for inspection");
                try self.runtime.publish();
            },
        };
    }
};

test "completed agents reconcile idle state while queued work remains streaming" {
    const allocator = std.testing.allocator;
    const mutex = native.SDL_CreateMutex() orelse return error.MutexCreation;
    defer native.SDL_DestroyMutex(mutex);
    var runtime: Runtime = .{
        .allocator = allocator,
        .io = undefined,
        .options = .{ .database_path = "", .project_path = "", .node_path = "", .pi_entrypoint = "", .wake_event = native.SDL_EVENT_USER },
        .options_arena = undefined,
        .mutex = mutex,
        .wake = undefined,
        .state = try copySnapshot(allocator, .{ .allocator = allocator, .status = .streaming }),
    };
    defer runtime.state.deinit();
    defer if (runtime.snapshot) |*snapshot| snapshot.deinit();
    defer runtime.outgoing.deinit(allocator);
    const events = [_][]const u8{
        \\{"type":"agent_end","messages":[]}
        ,
        \\{"type":"response","command":"get_state","id":1,"success":true,"data":{"isStreaming":true}}
        ,
        \\{"type":"agent_end","messages":[]}
        ,
        \\{"type":"response","command":"get_state","id":1,"success":true,"data":{"isStreaming":false}}
        ,
    };
    for (events, 0..) |bytes, index| {
        const parsed = try std.json.parseFromSlice(Value, allocator, bytes, .{});
        defer parsed.deinit();
        try runtime.event(parsed.value, @splat(0));
        try std.testing.expectEqual(if (index == events.len - 1) Status.ready else Status.streaming, runtime.snapshot.?.status);
    }
}
