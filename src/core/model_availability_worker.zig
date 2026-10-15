const std = @import("std");
const availability = @import("model_availability.zig");
const c = @import("../native/bindings.zig").c;
const p = @import("../platform/executables.zig").c;

/// Performs catalog discovery away from both the SDL thread and Pi's protocol
/// worker. Requests are coalesced so repeatedly opening the picker has one
/// bounded lookup in flight.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    wake_fd: c_int,
    mutex: *c.SDL_Mutex,
    condition: *c.SDL_Condition,
    thread: std.Thread,
    stopping: bool = false,
    requested: bool = false,
    result_ready: bool = false,
    result: ?[]u8 = null,
    active_event: ?*std.Io.Event = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, wake_fd: c_int) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer c.SDL_DestroyMutex(mutex);
        const condition = c.SDL_CreateCondition() orelse return error.ConditionCreation;
        errdefer c.SDL_DestroyCondition(condition);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .wake_fd = wake_fd,
            .mutex = mutex,
            .condition = condition,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, run, .{self});
        return self;
    }

    pub fn destroy(self: *Worker) void {
        c.SDL_LockMutex(self.mutex);
        self.stopping = true;
        self.requested = false;
        if (self.active_event) |event| event.set(self.io);
        c.SDL_SignalCondition(self.condition);
        c.SDL_UnlockMutex(self.mutex);
        self.thread.join();
        if (self.result) |bytes| self.allocator.free(bytes);
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn request(self: *Worker) !void {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.stopping) return error.WorkerStopped;
        self.requested = true;
        if (self.result) |bytes| self.allocator.free(bytes);
        self.result = null;
        self.result_ready = false;
        c.SDL_SignalCondition(self.condition);
    }

    pub fn take(self: *Worker) ?[]u8 {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (!self.result_ready) return null;
        const bytes = self.result;
        self.result = null;
        self.result_ready = false;
        return bytes;
    }

    fn run(self: *Worker) void {
        while (true) {
            c.SDL_LockMutex(self.mutex);
            while (!self.stopping and !self.requested) c.SDL_WaitCondition(self.condition, self.mutex);
            if (self.stopping) {
                c.SDL_UnlockMutex(self.mutex);
                return;
            }
            self.requested = false;
            c.SDL_UnlockMutex(self.mutex);

            const bytes = self.lookup(availability.resolve, .fromSeconds(5)) catch self.allocator.dupe(u8, "{\"providers\":[]}") catch null;

            c.SDL_LockMutex(self.mutex);
            if (self.stopping) {
                c.SDL_UnlockMutex(self.mutex);
                if (bytes) |owned| self.allocator.free(owned);
                return;
            }
            if (self.requested) {
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

    const Lookup = struct {
        worker: *Worker,
        resolve: *const fn (std.mem.Allocator, std.Io) anyerror![]u8,
        done: std.Io.Event = .unset,
        result: ?[]u8 = null,

        fn run(job: *Lookup) void {
            job.result = job.resolve(job.worker.allocator, job.worker.io) catch null;
            job.done.set(job.worker.io);
        }
    };

    fn lookup(self: *Worker, resolve: *const fn (std.mem.Allocator, std.Io) anyerror![]u8, timeout: std.Io.Duration) ![]u8 {
        var job: Lookup = .{ .worker = self, .resolve = resolve };
        c.SDL_LockMutex(self.mutex);
        if (self.stopping) {
            c.SDL_UnlockMutex(self.mutex);
            return error.WorkerStopped;
        }
        self.active_event = &job.done;
        c.SDL_UnlockMutex(self.mutex);
        defer {
            c.SDL_LockMutex(self.mutex);
            self.active_event = null;
            c.SDL_UnlockMutex(self.mutex);
        }
        var task = try self.io.concurrent(Lookup.run, .{&job});
        job.done.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = timeout } }) catch {};
        // Cancellation interrupts DNS, connect, TLS, headers and body I/O.
        // Await cancellation before releasing the stack job or its result.
        task.cancel(self.io);
        return job.result orelse self.allocator.dupe(u8, "{\"providers\":[]}");
    }
};
