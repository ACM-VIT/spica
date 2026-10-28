//! OS folder chooser. Its callback owns a reference independently of the UI;
//! closing the app while the chooser is open cannot retain an App pointer.
const std = @import("std");
const c = @import("../native/bindings.zig").c;

pub const Request = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u8) = .init(2),
    ready: std.atomic.Value(bool) = .init(false),
    state: enum { selected, cancelled, failed } = .cancelled,
    bytes: [4096:0]u8 = undefined,
    len: usize = 0,

    pub fn open(allocator: std.mem.Allocator, window: *c.SDL_Window, initial: []const u8) !*Request {
        const self = try allocator.create(Request);
        self.* = .{ .allocator = allocator };
        if (initial.len >= self.bytes.len or std.mem.indexOfScalar(u8, initial, 0) != null) {
            allocator.destroy(self);
            return error.InvalidFolderPath;
        }
        @memcpy(self.bytes[0..initial.len], initial);
        self.bytes[initial.len] = 0;
        c.SDL_ShowOpenFolderDialog(callback, self, window, &self.bytes, false);
        return self;
    }

    pub fn release(self: *Request) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }

    /// Borrow only after the callback publishes all result bytes.
    pub fn result(self: *Request) ?union(enum) { selected: []const u8, cancelled, failed } {
        if (!self.ready.load(.acquire)) return null;
        return switch (self.state) {
            .selected => .{ .selected = self.bytes[0..self.len] },
            .cancelled => .cancelled,
            .failed => .failed,
        };
    }

    fn complete(self: *Request, paths: [*c]const [*c]const u8) void {
        self.state = .cancelled;
        if (paths == null) {
            self.state = .failed;
        } else if (paths[0] != null) {
            // Bound foreign strings before copying; never shorten a folder.
            const path = paths[0];
            var len: usize = 0;
            while (len < self.bytes.len and path[len] != 0) : (len += 1) {}
            if (len == self.bytes.len or !std.fs.path.isAbsolute(path[0..len]) or !std.unicode.utf8ValidateSlice(path[0..len])) {
                self.state = .failed;
            } else {
                @memcpy(self.bytes[0..len], path[0..len]);
                self.bytes[len] = 0;
                self.len = len;
                self.state = .selected;
            }
        }
        self.ready.store(true, .release);
    }

    fn callback(context: ?*anyopaque, paths: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const self: *Request = @ptrCast(@alignCast(context.?));
        self.complete(paths);
        // Wake the event-driven UI even if SDL used a platform worker thread.
        var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_USER;
        _ = c.SDL_PushEvent(&event);
        self.release();
    }
};

test "folder callback owns its result and survives closing the requesting UI" {
    const request = try std.testing.allocator.create(Request);
    request.* = .{ .allocator = std.testing.allocator };
    try std.testing.expect(request.result() == null);
    const path = "/tmp/project 世界".*;
    // Supply a terminated foreign string, then change it after completion.
    var terminated: [path.len + 1:0]u8 = undefined;
    @memcpy(terminated[0..path.len], &path);
    terminated[path.len] = 0;
    const paths = [_][*c]const u8{ &terminated, null };
    request.complete(&paths);
    terminated[1] = 'X';
    try std.testing.expectEqualStrings("/tmp/project 世界", request.result().?.selected);
    request.release();
    request.release();

    const abandoned = try std.testing.allocator.create(Request);
    abandoned.* = .{ .allocator = std.testing.allocator };
    abandoned.release();
    abandoned.complete(null);
    try std.testing.expect(abandoned.result().? == .failed);
    abandoned.release();
}

test "folder cancellation and invalid paths never replace the current workspace" {
    var request: Request = .{ .allocator = std.testing.allocator };
    const empty = [_][*c]const u8{null};
    request.complete(&empty);
    try std.testing.expect(request.result().? == .cancelled);
    const invalid = [_][*c]const u8{ "relative/folder", null };
    request.complete(&invalid);
    try std.testing.expect(request.result().? == .failed);
}
