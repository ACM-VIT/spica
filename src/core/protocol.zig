const std = @import("std");

/// A framed stdout record is a JSON object followed by LF (optionally preceded
/// by CR). No effects should be published before onValid returns successfully.
/// The spool supplied by the caller is authoritative for raw bytes: it can
/// write to 64 KiB disk chunks and need only keep one chunk resident.
///
/// Sink must provide:
///   beginRecord(self) !void
///   appendRecord(self, bytes: []const u8) !void
///   rewindRecord(self) !void
///   readRecordChunk(self) !?[]const u8
///   onValid(self, source: *Source) !void
///   onQuarantine(self, source: *Source, reason: Reason) !void
/// `source.next()` iterates raw JSON in spool order; returned slices last until
/// the next `next()` call. Callbacks must finish reading before returning. A
/// callback owns committing/rejecting its spool generation; callback failures
/// propagate rather than silently discarding a record. Call deinit after EOF.
/// Ingest/EOF must be serialized per runtime; instantiate one framer per stdout.
pub fn Framer(comptime Sink: type) type {
    return struct {
        const Self = @This();
        pub const chunk_size: usize = 64 * 1024;
        pub const max_depth: usize = 128;
        pub const Reason = enum { malformed_json, invalid_root, excessive_depth, interrupted_record };

        pub const Source = struct {
            sink: *Sink,
            length: u64,

            pub fn next(self: *Source) !?[]const u8 {
                return self.sink.readRecordChunk();
            }
        };

        allocator: std.mem.Allocator,
        sink: *Sink,
        scanner: ?std.json.Scanner = null,
        length: u64 = 0,
        pending_cr: bool = false,
        rejected: ?Reason = null,
        saw_root: bool = false,
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, sink: *Sink) Self {
            return .{ .allocator = allocator, .sink = sink };
        }

        pub fn deinit(self: *Self) void {
            if (self.scanner) |*scanner| scanner.deinit();
            self.scanner = null;
        }

        /// Frame before scanning: U+2028/U+2029 are UTF-8 bytes, not delimiters.
        /// This does not copy or retain caller input beyond the current call.
        pub fn ingest(self: *Self, bytes: []const u8) !void {
            if (self.closed) return error.EndOfStream;
            var remaining = bytes;
            while (remaining.len != 0) {
                const lf = std.mem.indexOfScalar(u8, remaining, '\n');
                var part = remaining[0 .. lf orelse remaining.len];
                if (self.pending_cr) {
                    // Only the CR immediately before an LF is a framing byte.
                    if (part.len != 0 or lf == null) try self.feed("\r");
                    self.pending_cr = false;
                }
                if (part.len != 0 and part[part.len - 1] == '\r') {
                    part = part[0 .. part.len - 1];
                    self.pending_cr = true;
                }
                try self.feed(part);
                if (lf) |index| {
                    try self.finish();
                    remaining = remaining[index + 1 ..];
                } else break;
            }
        }

        /// EOF is not a delimiter. Even a syntactically complete JSON object
        /// without LF is interrupted, so it must not publish protocol effects.
        pub fn eof(self: *Self) !void {
            if (self.closed) return;
            self.closed = true;
            if (self.pending_cr) {
                try self.feed("\r");
                self.pending_cr = false;
            }
            if (self.scanner != null) try self.deliver(.interrupted_record);
        }

        fn start(self: *Self) !void {
            if (self.scanner != null) return;
            try self.sink.beginRecord();
            self.scanner = std.json.Scanner.initStreaming(self.allocator);
            self.length = 0;
            self.rejected = null;
            self.saw_root = false;
        }

        fn feed(self: *Self, bytes: []const u8) !void {
            if (bytes.len == 0) return;
            try self.start();
            var remaining = bytes;
            while (remaining.len != 0) {
                const size = @min(remaining.len, chunk_size);
                const chunk = remaining[0..size];
                try self.sink.appendRecord(chunk);
                self.length = try std.math.add(u64, self.length, @as(u64, @intCast(size)));
                if (self.rejected == null) try self.scan(chunk);
                remaining = remaining[size..];
            }
        }

        fn scan(self: *Self, chunk: []const u8) !void {
            const scanner = &self.scanner.?;
            scanner.feedInput(chunk);
            try self.scanTokens();
        }

        fn scanTokens(self: *Self) !void {
            const scanner = &self.scanner.?;
            while (true) {
                const token = scanner.next() catch |err| switch (err) {
                    error.BufferUnderrun => return,
                    error.OutOfMemory => return err,
                    else => {
                        self.rejected = .malformed_json;
                        return;
                    },
                };
                if (!self.saw_root) {
                    self.saw_root = true;
                    if (token != .object_begin) {
                        self.rejected = .invalid_root;
                        return;
                    }
                }
                if (scanner.stackHeight() > max_depth) {
                    self.rejected = .excessive_depth;
                    return;
                }
                if (token == .end_of_document) return;
            }
        }

        fn finish(self: *Self) !void {
            self.pending_cr = false;
            try self.start(); // An empty line is a malformed framed record.
            var reason = self.rejected;
            if (reason == null) {
                const scanner = &self.scanner.?;
                scanner.endInput();
                while (true) {
                    const token = scanner.next() catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => {
                            reason = .malformed_json;
                            break;
                        },
                    };
                    if (!self.saw_root) {
                        self.saw_root = true;
                        if (token != .object_begin) {
                            reason = .invalid_root;
                            break;
                        }
                    }
                    if (scanner.stackHeight() > max_depth) {
                        reason = .excessive_depth;
                        break;
                    }
                    if (token == .end_of_document) break;
                }
            }
            try self.deliver(reason);
        }

        fn deliver(self: *Self, reason: ?Reason) !void {
            try self.sink.rewindRecord();
            var source: Source = .{ .sink = self.sink, .length = self.length };
            if (reason) |why| {
                try self.sink.onQuarantine(&source, why);
            } else {
                try self.sink.onValid(&source);
            }
            self.scanner.?.deinit();
            self.scanner = null;
            self.length = 0;
            self.rejected = null;
            self.saw_root = false;
        }
    };
}
