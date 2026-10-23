//! Single-owner, bounded, nonblocking JSONL process transport.
const std = @import("std");
pub const c = @cImport({
    @cInclude("../platform/process.h");
});
pub const Options = struct {
    argv: []const [:0]const u8,
    cwd: [:0]const u8,
    environment: ?[]const [:0]const u8 = null,
};
pub const Transport = struct {
    pub const frame_bytes = 262144;
    pub const queue_bytes = frame_bytes * 2;
    allocator: std.mem.Allocator,
    process: c.SpicaProcess = .{ .input = -1, .output = -1, .@"error" = -1, .exit_fd = -1, .pid = 0 },
    input: []u8,
    output: []u8,
    input_len: usize = 0,
    output_len: usize = 0,
    exited: bool = false,
    status: c_int = 0,
    pub fn init(allocator: std.mem.Allocator, options: Options) !Transport {
        if (options.argv.len == 0) return error.InvalidArguments;
        var self: Transport = .{ .allocator = allocator, .input = try allocator.alloc(u8, queue_bytes), .output = undefined };
        errdefer allocator.free(self.input);
        self.output = try allocator.alloc(u8, queue_bytes);
        errdefer allocator.free(self.output);
        const argv = try allocator.allocSentinel(?[*:0]const u8, options.argv.len, null);
        defer allocator.free(argv);
        for (options.argv, 0..) |arg, i| argv[i] = arg.ptr;
        var env: ?[:null]?[*:0]const u8 = null;
        defer if (env) |e| allocator.free(e);
        if (options.environment) |values| {
            env = try allocator.allocSentinel(?[*:0]const u8, values.len, null);
            for (values, 0..) |value, i| env.?[i] = value.ptr;
        }
        if (c.spica_process_spawn_env(&self.process, options.argv[0].ptr, @ptrCast(argv.ptr), options.cwd.ptr, if (env) |e| @ptrCast(e.ptr) else null) != 0) {
            if (self.process.pid > 0) {
                if (c.spica_process_force(&self.process) != 0) @panic("cannot stop failed provider spawn");
                while (c.spica_process_reap(&self.process, &self.status) == 0) _ = c.spica_process_poll(&self.process, -1, 0, 20);
                c.spica_process_dispose(&self.process);
            }
            return error.SpawnFailed;
        }
        return self;
    }
    pub fn send(self: *Transport, line: []const u8) !void {
        if (self.exited) return error.ProcessExited;
        if (line.len > frame_bytes) return error.FrameTooLarge;
        if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidFrame;
        if (line.len + 1 > self.input.len - self.input_len) return error.QueueFull;
        @memcpy(self.input[self.input_len..][0..line.len], line);
        self.input_len += line.len;
        self.input[self.input_len] = '\n';
        self.input_len += 1;
    }
    pub fn pump(self: *Transport) !void {
        if (self.exited) return;
        if (self.input_len > 0) {
            const n = c.spica_process_write(self.process.input, self.input.ptr, self.input_len);
            if (n == -1) return error.TransportWrite;
            if (n > 0) {
                const size: usize = @intCast(n);
                std.mem.copyForwards(u8, self.input[0 .. self.input_len - size], self.input[size..self.input_len]);
                self.input_len -= size;
            }
        }
        // Bounded drain per tick, including stderr, so neither pipe deadlocks.
        var scratch: [8192]u8 = undefined;
        for (0..16) |_| {
            const n = c.spica_process_read(self.process.@"error", &scratch, scratch.len);
            if (n == -1) return error.TransportRead;
            if (n <= 0) break;
        }
        for (0..16) |_| {
            if (self.output_len == self.output.len) break;
            const n = c.spica_process_read(self.process.output, self.output[self.output_len..].ptr, @min(8192, self.output.len - self.output_len));
            if (n == -1) return error.TransportRead;
            if (n <= 0) break;
            self.output_len += @intCast(n);
        }
        // Validate all complete and partial frames, not only the first frame.
        var start: usize = 0;
        for (self.output[0..self.output_len], 0..) |byte, i| if (byte == '\n') {
            if (i - start > frame_bytes) return error.FrameTooLarge;
            start = i + 1;
        };
        if (self.output_len - start > frame_bytes) return error.FrameTooLarge;
        const reaped = c.spica_process_reap(&self.process, &self.status);
        if (reaped < 0) return error.ReapFailed;
        self.exited = reaped == 1;
        if (self.exited and start != self.output_len) return error.TruncatedFrame;
    }
    pub fn poll(self: *Transport, allocator: std.mem.Allocator) !?[]const u8 {
        const end = std.mem.indexOfScalar(u8, self.output[0..self.output_len], '\n') orelse return null;
        const line = try allocator.dupe(u8, std.mem.trimEnd(u8, self.output[0..end], "\r"));
        std.mem.copyForwards(u8, self.output[0 .. self.output_len - end - 1], self.output[end + 1 .. self.output_len]);
        self.output_len -= end + 1;
        return line;
    }
    pub fn deinit(self: *Transport) void {
        if (self.process.pid > 0) {
            // Force only the tree owned by this runtime, and retain ownership on failure.
            if (c.spica_process_force(&self.process) != 0) @panic("cannot stop owned provider process");
            while (c.spica_process_reap(&self.process, &self.status) == 0) {
                _ = c.spica_process_poll(&self.process, -1, 0, 20);
            }
        }
        c.spica_process_dispose(&self.process);
        self.allocator.free(self.input);
        self.allocator.free(self.output);
    }
};
test "JSONL admission bounds" {
    var input: [16]u8 = undefined;
    var transport: Transport = .{ .allocator = std.testing.allocator, .input = &input, .output = &.{} };
    try transport.send("{}");
    try std.testing.expectEqualStrings("{}\n", input[0..3]);
    try std.testing.expectError(error.InvalidFrame, transport.send("a\nb"));
    try std.testing.expectError(error.QueueFull, transport.send("01234567890123"));
}
test "real process framing and ownership" {
    var transport = try Transport.init(std.testing.allocator, .{ .argv = &.{"/bin/cat"}, .cwd = "/tmp", .environment = &.{} });
    defer transport.deinit();
    try transport.send("{\"id\":1}");
    for (0..100) |_| {
        try transport.pump();
        if (try transport.poll(std.testing.allocator)) |line| {
            defer std.testing.allocator.free(line);
            try std.testing.expectEqualStrings("{\"id\":1}", line);
            return;
        }
        _ = c.spica_process_poll(&transport.process, -1, 0, 10);
    }
    return error.TestTimeout;
}
