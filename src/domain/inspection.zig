//! Synchronous worker/CLI inspection. No selected UI state and no mutation API.
const std = @import("std");
const workspace = @import("workspace.zig");
const types = @import("types.zig");
pub const WorkspaceBinding = types.WorkspaceBinding;
extern "c" var environ: [*:null]?[*:0]u8;

pub const Limits = struct {
    memory_bytes: usize = 4 * 1024 * 1024,
    output_bytes: usize = 128 * 1024,
    diff_bytes: usize = 256 * 1024,
    files: usize = 2048,
    milliseconds: u32 = 5000,
    fn validate(l: Limits) !void {
        if (l.memory_bytes == 0 or l.memory_bytes > 8 * 1024 * 1024 or l.output_bytes == 0 or l.output_bytes > 1024 * 1024 or l.diff_bytes == 0 or l.diff_bytes > 2 * 1024 * 1024 or l.files == 0 or l.files > 8192 or l.milliseconds == 0 or l.milliseconds > 30000) return error.InvalidLimits;
    }
};
pub const Entry = struct {
    index: u8,
    worktree: u8,
    path: []const u8,
    original_path: ?[]const u8 = null,
};
pub const Diff = struct { path: []const u8, staged: bool = false };
pub const Query = union(enum) { status, diff: Diff };
const Operation = union(enum) { capture, status, diff: Diff };
pub const Result = struct {
    memory: []u8,
    binding: ?WorkspaceBinding = null,
    entries: []const Entry = &.{},
    bytes: []const u8 = "",
    pub fn deinit(r: *Result, allocator: std.mem.Allocator) void {
        allocator.free(r.memory);
        r.* = undefined;
    }
};

/// Capture once at explicit selection, retain this result until all queries end.
/// Bounds the existing identity capture without establishing another convention.
pub fn capture(allocator: std.mem.Allocator, io: std.Io, root: []const u8, limits: Limits) !Result {
    return execute(allocator, io, null, root, .capture, limits);
}

/// A missing binding is a refusal, never permission to capture ambient authority.
pub fn inspect(allocator: std.mem.Allocator, io: std.Io, binding: ?WorkspaceBinding, requested_root: []const u8, query: Query, limits: Limits) !Result {
    if (binding == null) return error.MissingBinding;
    return execute(allocator, io, binding, requested_root, switch (query) {
        .status => .status,
        .diff => |d| .{ .diff = d },
    }, limits);
}

fn execute(allocator: std.mem.Allocator, io: std.Io, binding: ?WorkspaceBinding, root: []const u8, operation: Operation, limits: Limits) !Result {
    try limits.validate();
    if (root.len == 0 or root[0] != '/' or root.len > 4096 or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidRoot;
    // Existing workspace.capture inherits its environment. Refuse authority or
    // config overrides. These three UI-only settings cannot affect our fixed
    // read-only commands (pager disabled; no editor, transport or prompts).
    var env = environ;
    while (env[0]) |item| : (env += 1) {
        const variable = std.mem.span(item);
        if (!std.mem.startsWith(u8, variable, "GIT_")) continue;
        if (std.mem.startsWith(u8, variable, "GIT_EDITOR=") or std.mem.startsWith(u8, variable, "GIT_PAGER=") or std.mem.startsWith(u8, variable, "GIT_TERMINAL_PROMPT=")) continue;
        return error.GitEnvironmentOverride;
    }
    const memory = try allocator.alloc(u8, limits.memory_bytes);
    errdefer allocator.free(memory);
    var storage: [2]ExecuteCompletion = undefined;
    var select = std.Io.Select(ExecuteCompletion).init(io, &storage);
    defer select.cancelDiscard();
    try select.concurrent(.deadline, deadline, .{ io, limits.milliseconds });
    try select.concurrent(.work, work, .{ io, memory, binding, root, operation, limits });
    return switch (try select.await()) {
        .work => |result| try result,
        .deadline => return error.InspectionTimeout,
    };
}
const ExecuteCompletion = union(enum) { work: anyerror!Result, deadline: void };
fn deadline(io: std.Io, milliseconds: u32) void {
    std.Io.sleep(io, .fromMilliseconds(milliseconds), .awake) catch {};
}

pub const Wake = struct { context: *anyopaque, notify: *const fn (*anyopaque) void };
pub const Request = struct {
    /// UI-owned generation, changed whenever checkout or selected file changes.
    /// Consumers must discard completions from an earlier generation.
    revision: u64,
    binding: WorkspaceBinding,
    root: []const u8,
    query: Query,
};
pub const Completion = struct {
    revision: u64,
    query: enum { status, diff },
    result: anyerror!Result,

    pub fn deinit(self: *Completion, allocator: std.mem.Allocator) void {
        if (self.result) |value| {
            var owned = value;
            owned.deinit(allocator);
        } else |_| {}
        self.* = undefined;
    }
};

/// One request or undrained completion at a time. request copies all authority
/// and path bytes; callers may immediately release the source query page.
/// The worker never captures ambient authority, reads a store or touches SDL.
/// Successful drain transfers Result ownership, to be released by the caller.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake: Wake,
    limits: Limits,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    stopping: bool = false,
    active: bool = false,
    pending: ?Request = null,
    output: ?Completion = null,
    request_bytes: [64 * 1024]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, wake: Wake, limits: Limits) !*Worker {
        try limits.validate();
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .wake = wake, .limits = limits };
        self.thread = try std.Thread.spawn(.{ .allocator = allocator, .stack_size = 1024 * 1024 }, run, .{self});
        return self;
    }

    /// Joins any running bounded operation. Callback context must outlive join.
    /// A result that was never drained is disposed here.
    pub fn destroy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.?.join();
        if (self.output) |*value| value.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn request(self: *Worker, value: Request) error{ Busy, Closed, RequestBudget }!void {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Closed;
        if (self.active or self.pending != null or self.output != null) return error.Busy;
        var fixed = std.heap.FixedBufferAllocator.init(&self.request_bytes);
        const a = fixed.allocator();
        var owned = value;
        inline for (std.meta.fields(WorkspaceBinding)) |field| {
            if (field.type == []const u8) @field(owned.binding, field.name) = a.dupe(u8, @field(value.binding, field.name)) catch return error.RequestBudget;
        }
        owned.root = a.dupe(u8, value.root) catch return error.RequestBudget;
        if (value.query == .diff) owned.query.diff.path = a.dupe(u8, value.query.diff.path) catch return error.RequestBudget;
        self.pending = owned;
        self.condition.signal(self.io);
    }

    /// Busy/empty never consumes a completion. Inspect revision before painting;
    /// deinit stale successful completions just like displayed completions.
    pub fn drain(self: *Worker, out: *Completion) error{Busy}!bool {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        out.* = self.output orelse return false;
        self.output = null;
        return true;
    }

    fn run(self: *Worker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.pending == null) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const job = self.pending.?;
            self.pending = null;
            self.active = true;
            self.mutex.unlock(self.io);
            const result = inspect(self.allocator, self.io, job.binding, job.root, job.query, self.limits);
            self.mutex.lockUncancelable(self.io);
            self.output = .{ .revision = job.revision, .query = if (job.query == .status) .status else .diff, .result = result };
            self.active = false;
            self.mutex.unlock(self.io);
            self.wake.notify(self.wake.context);
        }
    }
};

fn work(io: std.Io, memory: []u8, binding: ?WorkspaceBinding, root: []const u8, operation: Operation, limits: Limits) anyerror!Result {
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const a = fixed.allocator();
    var result: Result = .{ .memory = memory };
    if (operation == .capture) {
        result.binding = try workspace.capture(a, io, root);
        return result;
    }
    const captured = binding.?;
    if (!try workspace.verify(a, io, captured)) return error.WorkspaceIdentityChanged;
    const requested = try workspace.capture(a, io, root);
    if (!types.adapter.equal(captured, requested)) return error.WrongCheckout;
    if (captured.non_git) return error.NotRepository;
    // A binding captured inside a repository is not authority for its parent.
    const top = try git(a, io, captured.canonical_root, &.{ "rev-parse", "--show-toplevel" }, 8192);
    if (top.len == 0 or top[top.len - 1] != '\n' or !std.mem.eql(u8, top[0 .. top.len - 1], captured.canonical_root)) return error.NotCheckoutRoot;
    switch (operation) {
        .capture => unreachable,
        .status => {
            result.bytes = try git(a, io, captured.canonical_root, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none", "--" }, limits.output_bytes);
            result.entries = try parseStatus(a, result.bytes, limits.files);
        },
        .diff => |d| {
            if (d.path.len > 4096 or std.mem.eql(u8, d.path, ".") or std.mem.indexOfScalar(u8, d.path, 0) != null or !try workspace.validOwnedPath(a, captured, d.path)) return error.InvalidOwnedPath;
            // Explicitly refuse untracked files; an empty diff must not pretend
            // their content was inspected. Deleted tracked paths remain valid.
            const tracked = try git(a, io, captured.canonical_root, if (captured.base_revision.len == 0)
                &.{ "ls-files", "-z", "--", d.path }
            else
                &.{ "ls-files", "--with-tree=HEAD", "-z", "--", d.path }, limits.output_bytes);
            if (tracked.len != d.path.len + 1 or !std.mem.eql(u8, tracked[0..tracked.len -| 1], d.path)) return error.UntrackedDiffUnavailable;
            result.bytes = if (d.staged)
                try git(a, io, captured.canonical_root, &.{ "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--", d.path }, limits.diff_bytes)
            else
                try git(a, io, captured.canonical_root, &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--", d.path }, limits.diff_bytes);
        },
    }
    // Detect identity drift across the command as well as before it. This is
    // not an OS sandbox or an atomic snapshot against a concurrent filesystem adversary.
    if (!try workspace.verify(a, io, captured)) return error.WorkspaceIdentityChanged;
    return result;
}

fn git(a: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8, limit: usize) ![]const u8 {
    var argv: [40][]const u8 = undefined;
    const prefix: []const []const u8 = &.{ "git", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", root };
    @memcpy(argv[0..prefix.len], prefix);
    if (args.len > argv.len - prefix.len) return error.InvalidArguments;
    @memcpy(argv[prefix.len..][0..args.len], args);
    const output = try std.process.run(a, io, .{ .argv = argv[0 .. prefix.len + args.len], .stdout_limit = .limited(limit), .stderr_limit = .limited(4096) });
    if (output.stdout.len > limit or output.stderr.len > 4096) return error.StreamTooLong;
    if (output.term != .exited or output.term.exited != 0) return error.GitCommandFailed;
    return output.stdout;
}

/// Porcelain v1 -z uses raw paths; rename records place destination first.
pub fn parseStatus(a: std.mem.Allocator, bytes: []const u8, max_files: usize) ![]const Entry {
    var entries: std.array_list.Managed(Entry) = .init(a);
    errdefer entries.deinit();
    var records = std.mem.splitScalar(u8, bytes, 0);
    while (records.next()) |record| {
        if (record.len == 0) {
            if (records.next() != null) return error.MalformedStatus;
            break;
        }
        if (record.len < 4 or record[2] != ' ') return error.MalformedStatus;
        if (entries.items.len == max_files) return error.FileLimit;
        var entry: Entry = .{ .index = record[0], .worktree = record[1], .path = record[3..] };
        if (record[0] == 'R' or record[0] == 'C' or record[1] == 'R' or record[1] == 'C') {
            entry.original_path = records.next() orelse return error.MalformedStatus;
            if (entry.original_path.?.len == 0) return error.MalformedStatus;
        }
        try entries.append(entry);
    }
    if (bytes.len != 0 and bytes[bytes.len - 1] != 0) return error.MalformedStatus;
    return entries.toOwnedSlice();
}
