//! Loopback-only, bounded JSON-response Streamable HTTP transport. The Host
//! worker owns all sockets; this module never dispatches domain work itself.
const std = @import("std");
const common = @import("runtime/adapter.zig");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
});
pub const Server = struct {
    const Client = struct {
        fd: c_int = -1,
        input: [65536]u8 = undefined,
        used: usize = 0,
        output: [65536]u8 = undefined,
        output_len: usize = 0,
        sent: usize = 0,
        waiting: bool = false,
        opened_ms: i64 = 0,
    };
    const Binding = struct { session: []const u8 = "", token: []const u8 = "" };
    fd: c_int,
    port: u16,
    clients: [4]Client = @splat(.{}),
    bindings: [3]Binding = @splat(.{}),
    pub const Invocation = struct { client: usize, session: []const u8, json: []const u8 };
    pub fn init() !Server {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketUnavailable;
        errdefer _ = c.close(fd);
        try nonblocking(fd);
        var address = std.mem.zeroes(c.struct_sockaddr_in);
        address.sin_family = c.AF_INET;
        address.sin_addr.s_addr = c.htonl(c.INADDR_LOOPBACK);
        address.sin_port = 0;
        if (c.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or c.listen(fd, 4) != 0) return error.BindUnavailable;
        var size: c.socklen_t = @sizeOf(@TypeOf(address));
        if (c.getsockname(fd, @ptrCast(&address), &size) != 0) return error.BindUnavailable;
        return .{ .fd = fd, .port = c.ntohs(address.sin_port) };
    }
    fn nonblocking(fd: c_int) !void {
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
        const nonblock: c_int = @bitCast(@as(std.posix.O, .{ .NONBLOCK = true }));
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0 or std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.SocketUnavailable;
    }
    pub fn deinit(self: *Server) void {
        for (&self.clients) |*client| close(client);
        _ = c.close(self.fd);
    }
    fn close(client: *Client) void {
        if (client.fd >= 0) _ = c.close(client.fd);
        client.* = .{};
    }
    pub fn bindSession(self: *Server, allocator: std.mem.Allocator, session: []const u8, token: []const u8) !common.Bridge {
        if (session.len == 0 or token.len != 32) return error.InvalidSessionBinding;
        for (self.bindings) |binding| if (std.mem.eql(u8, binding.session, session)) return error.DuplicateSessionBinding;
        for (&self.bindings) |*binding| if (binding.session.len == 0) {
            const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp/{s}", .{ self.port, session });
            binding.* = .{ .session = session, .token = token };
            return .{ .url = url, .token = token };
        };
        return error.BridgeCapacity;
    }
    pub fn unbindSession(self: *Server, session: []const u8) void {
        for (&self.bindings) |*binding| if (std.mem.eql(u8, binding.session, session)) {
            binding.* = .{};
        };
    }
    pub fn respond(self: *Server, index: usize, status: u16, body: []const u8) !void {
        const client = &self.clients[index];
        const output = try std.fmt.bufPrint(&client.output, "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, if (status == 200) @as([]const u8, "OK") else "Response", body.len, body });
        client.output_len = output.len;
        client.sent = 0;
        client.waiting = false;
    }
    pub fn poll(self: *Server, allocator: std.mem.Allocator, now_ms: i64) !?Invocation {
        // At most four accepted clients and one read/write per client per pump.
        const accepted = c.accept(self.fd, null, null);
        if (accepted >= 0) {
            var admitted = false;
            for (&self.clients) |*client| if (client.fd < 0) {
                nonblocking(accepted) catch {
                    _ = c.close(accepted);
                    return error.SocketUnavailable;
                };
                client.* = .{ .fd = accepted, .opened_ms = now_ms };
                admitted = true;
                break;
            };
            if (!admitted) _ = c.close(accepted);
        }
        for (&self.clients, 0..) |*client, index| {
            if (client.fd < 0) continue;
            if (now_ms - client.opened_ms > 10000) {
                close(client);
                continue;
            }
            if (client.output_len != 0) {
                const n = c.send(client.fd, client.output[client.sent..client.output_len].ptr, client.output_len - client.sent, c.MSG_NOSIGNAL);
                if (n > 0) client.sent += @intCast(n);
                if (client.sent == client.output_len) close(client);
                continue;
            }
            if (client.waiting) continue;
            if (client.used == client.input.len) {
                try self.respond(index, 413, "{}");
                continue;
            }
            const n = c.recv(client.fd, client.input[client.used..].ptr, client.input.len - client.used, 0);
            if (n == 0) {
                close(client);
                continue;
            }
            if (n < 0) continue;
            client.used += @intCast(n);
            const bytes = client.input[0..client.used];
            const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
                if (client.used > 8192) try self.respond(index, 431, "{}");
                continue;
            };
            var lines = std.mem.splitSequence(u8, bytes[0..header_end], "\r\n");
            const first = lines.next() orelse {
                try self.respond(index, 400, "{}");
                continue;
            };
            var words = std.mem.splitScalar(u8, first, ' ');
            const method = words.next() orelse "";
            const path = words.next() orelse "";
            if (!std.mem.eql(u8, method, "POST")) {
                try self.respond(index, 405, "{}");
                continue;
            }
            var length: ?usize = null;
            var token: []const u8 = "";
            var bad = false;
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                    bad = true;
                    break;
                };
                const name = line[0..colon];
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                    if (length != null) {
                        bad = true;
                        break;
                    }
                    length = std.fmt.parseInt(usize, value, 10) catch {
                        bad = true;
                        break;
                    };
                } else if (std.ascii.eqlIgnoreCase(name, "Authorization")) {
                    if (token.len != 0 or !std.mem.startsWith(u8, value, "Bearer ")) {
                        bad = true;
                        break;
                    }
                    token = value[7..];
                } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                    bad = true;
                    break;
                }
            }
            if (bad or length == null) {
                try self.respond(index, 400, "{}");
                continue;
            }
            if (length.? > client.input.len - header_end - 4) {
                try self.respond(index, 413, "{}");
                continue;
            }
            const end = header_end + 4 + length.?;
            if (client.used < end) continue;
            var session: ?[]const u8 = null;
            for (self.bindings) |binding| {
                if (binding.session.len == 0 or !std.mem.startsWith(u8, path, "/mcp/") or !std.mem.eql(u8, path[5..], binding.session)) continue;
                if (token.len == 32 and binding.token.len == 32 and std.crypto.timing_safe.eql([32]u8, token[0..32].*, binding.token[0..32].*)) session = binding.session;
            }
            if (session == null) {
                try self.respond(index, 401, "{}");
                continue;
            }
            client.waiting = true;
            return .{ .client = index, .session = session.?, .json = try allocator.dupe(u8, bytes[header_end + 4 .. end]) };
        }
        return null;
    }
};
