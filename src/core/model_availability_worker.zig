const std = @import("std");
const executables = @import("../platform/executables.zig");
const c = @import("../native/bindings.zig").c;
const build_options = @import("build_options");

const p = executables.c;

const Job = struct {
    node: []u8,
    entry: []u8,
    previous: []u8,
};

pub const Result = struct { bytes: ?[]u8 };

/// Runs credential discovery away from the Pi I/O worker. Requests are
/// coalesced, so repeated picker opens keep at most one pending lookup.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake_fd: c_int,
    mutex: *c.SDL_Mutex,
    condition: *c.SDL_Condition,
    thread: std.Thread,
    stopping: bool = false,
    job: ?Job = null,
    result_ready: bool = false,
    result: ?[]u8 = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, wake_fd: c_int) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer c.SDL_DestroyMutex(mutex);
        const condition = c.SDL_CreateCondition() orelse return error.ConditionCreation;
        errdefer c.SDL_DestroyCondition(condition);
        self.* = .{ .allocator = allocator, .io = io, .wake_fd = wake_fd, .mutex = mutex, .condition = condition, .thread = undefined };
        self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, run, .{self});
        return self;
    }

    pub fn destroy(self: *Worker) void {
        c.SDL_LockMutex(self.mutex);
        self.stopping = true;
        c.SDL_SignalCondition(self.condition);
        c.SDL_UnlockMutex(self.mutex);
        self.thread.join();
        if (self.job) |job| self.freeJob(job);
        if (self.result) |bytes| self.allocator.free(bytes);
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn request(self: *Worker, node: []const u8, entry: []const u8, previous: []const u8) !void {
        const job: Job = .{
            .node = try self.allocator.dupe(u8, node),
            .entry = try self.allocator.dupe(u8, entry),
            .previous = try self.allocator.dupe(u8, previous),
        };
        errdefer {
            self.allocator.free(job.node);
            self.allocator.free(job.entry);
            self.allocator.free(job.previous);
        }
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.stopping) return error.WorkerStopped;
        if (self.job) |old| self.freeJob(old);
        if (self.result) |bytes| self.allocator.free(bytes);
        self.result = null;
        self.result_ready = false;
        self.job = job;
        c.SDL_SignalCondition(self.condition);
    }

    pub fn take(self: *Worker) ?Result {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (!self.result_ready) return null;
        const result: Result = .{ .bytes = self.result };
        self.result = null;
        self.result_ready = false;
        return result;
    }

    fn run(self: *Worker) void {
        while (true) {
            c.SDL_LockMutex(self.mutex);
            while (!self.stopping and self.job == null) c.SDL_WaitCondition(self.condition, self.mutex);
            if (self.stopping) {
                c.SDL_UnlockMutex(self.mutex);
                return;
            }
            const job = self.job.?;
            self.job = null;
            c.SDL_UnlockMutex(self.mutex);

            const bytes = self.lookup(job);
            self.freeJob(job);

            c.SDL_LockMutex(self.mutex);
            if (self.stopping) {
                c.SDL_UnlockMutex(self.mutex);
                if (bytes) |owned| self.allocator.free(owned);
                return;
            }
            // A newer request supersedes this result before it reaches the UI.
            if (self.job != null) {
                c.SDL_UnlockMutex(self.mutex);
                if (bytes) |owned| self.allocator.free(owned);
                continue;
            }
            self.result = bytes;
            self.result_ready = true;
            c.SDL_UnlockMutex(self.mutex);
            p.spica_wake(self.wake_fd);
        }
    }

    fn lookup(self: *Worker, job: Job) ?[]u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = &.{ job.node, build_options.model_availability_helper, job.entry, job.previous },
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(8) } },
        }) catch return null;
        self.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return null;
        }
        return result.stdout;
    }

    fn freeJob(self: *Worker, job: Job) void {
        self.allocator.free(job.node);
        self.allocator.free(job.entry);
        self.allocator.free(job.previous);
    }
};
