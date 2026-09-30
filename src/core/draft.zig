const std = @import("std");
const c = @import("../native/bindings.zig").c;
const allocator = std.heap.page_allocator;

pub const State = struct { draft: []const u8 = "", selected_message: usize = 199, light: bool = false };
pub const Restored = struct {
    parsed: ?std.json.Parsed(State) = null,
    pub fn value(self: Restored) State { return if (self.parsed) |parsed| parsed.value else .{}; }
    pub fn deinit(self: *Restored) void { if (self.parsed) |parsed| parsed.deinit(); }
};
pub fn restore(io: std.Io, path: []const u8) !Restored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024)) catch |err| switch (err) { error.FileNotFound => return .{}, else => return err };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(State, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.draft.len > 65536 or !std.unicode.utf8ValidateSlice(parsed.value.draft)) return error.InvalidDraft;
    return .{ .parsed = parsed };
}

pub const Writer = struct {
    mutex: *c.SDL_Mutex,
    condition: *c.SDL_Condition,
    thread: ?std.Thread = null,
    io: std.Io,
    path: []u8,
    temporary_path: []u8,
    wake_event: u32,
    pending: ?[]u8 = null,
    closing: bool = false,
    last_error: ?anyerror = null,

    pub fn create(io: std.Io, path: []const u8, wake_event: u32) !*Writer {
        const self = try allocator.create(Writer);
        errdefer allocator.destroy(self);
        const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer c.SDL_DestroyMutex(mutex);
        const condition = c.SDL_CreateCondition() orelse return error.ConditionCreation;
        errdefer c.SDL_DestroyCondition(condition);
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        errdefer allocator.free(temporary);
        self.* = .{ .mutex = mutex, .condition = condition, .io = io, .path = owned, .temporary_path = temporary, .wake_event = wake_event };
        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    pub fn submit(self: *Writer, state: State) !void {
        const bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.pending) |old| allocator.free(old);
        self.pending = bytes;
        c.SDL_SignalCondition(self.condition);
    }

    pub fn takeError(self: *Writer) ?anyerror {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        const err = self.last_error;
        self.last_error = null;
        return err;
    }

    // Ordinary shutdown drains the final accepted draft write before joining.
    pub fn destroy(self: *Writer) void {
        c.SDL_LockMutex(self.mutex);
        self.closing = true;
        c.SDL_BroadcastCondition(self.condition);
        c.SDL_UnlockMutex(self.mutex);
        self.thread.?.join();
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        allocator.free(self.path);
        allocator.free(self.temporary_path);
        allocator.destroy(self);
    }

    fn write(self: *Writer, bytes: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, self.temporary_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
        try std.Io.Dir.cwd().rename(self.temporary_path, std.Io.Dir.cwd(), self.path, self.io);
    }

    fn run(self: *Writer) void {
        defer c.SDL_CleanupTLS();
        while (true) {
            c.SDL_LockMutex(self.mutex);
            while (self.pending == null and !self.closing) c.SDL_WaitCondition(self.condition, self.mutex);
            const bytes = self.pending orelse {
                c.SDL_UnlockMutex(self.mutex);
                return;
            };
            self.pending = null;
            c.SDL_UnlockMutex(self.mutex);
            defer allocator.free(bytes);
            self.write(bytes) catch |err| {
                c.SDL_LockMutex(self.mutex);
                const notify = self.last_error == null;
                self.last_error = err;
                c.SDL_UnlockMutex(self.mutex);
                if (notify) {
                    var event = std.mem.zeroes(c.SDL_Event);
                    event.type = self.wake_event;
                    _ = c.SDL_PushEvent(&event);
                }
            };
        }
    }
};
