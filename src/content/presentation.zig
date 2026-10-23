const std = @import("std");
const markdown = @import("markdown.zig");
const unicode_breaks = @cImport({
    @cInclude("graphemebreak.h");
});

pub const source_limit = markdown.max_source_bytes;
pub const spool_limit = 8 * 1024 * 1024;
pub const scratch_bytes = 16 * 1024 * 1024;
pub const tile_bytes = 32768;
pub const tile_runs = 256;
const header_bytes = 52;
pub const page_text_bytes = 4096;
pub const Cursor = struct { block: u32, byte: u32 = 0 };
const block_bytes = 52;
const run_bytes = 28;
// Retained cmark/Tree-sitter allocator hooks are process-global, not thread-local.
// All presentation instances serialize their guarded C parser work.
var parse_mutex: std.Io.Mutex = .init;

pub const Key = struct { source: markdown.ContentId, revision: u64, generation: u64 };
pub const Header = struct {
    key: Key,
    state: markdown.State,
    block_count: u32,
    run_count: u32,
    text_bytes: u32,
    metadata_bytes: u32,
    text_offset: u64,
    metadata_offset: u64,
};
pub const Block = struct {
    index: u32,
    kind: markdown.BlockKind,
    start: u32,
    end: u32,
    first_run: u32,
    end_run: u32,
    heading: u32,
    flags: u32,
    number: i32,
    columns: u32,
    info_start: u32,
    info_len: u32,
};
pub const Span = struct { start: u32, end: u32, kind: markdown.RunKind, flags: u32 };
pub const Tile = struct {
    key: Key,
    block: Block,
    state: enum { rich, display_budget },
    text: [tile_bytes]u8 = undefined,
    len: usize = 0,
    spans: [tile_runs]Span = undefined,
    span_count: usize = 0,
    language: [128]u8 = undefined,
    language_len: usize = 0,
    next_block: ?u32 = null,
    start_byte: u32 = 0,
    next: ?Cursor = null,
    previous: ?Cursor = null,

    pub fn bytes(self: *const Tile) []const u8 {
        return self.text[0..self.len];
    }
};

// Bounds backing storage, including arena metadata and allocation overlap.
// This wrapper lives for one job; only the allocator-neutral State is retained.
const ProjectionAllocator = struct {
    parent: std.mem.Allocator,
    used: *usize,

    fn allocator(self: *ProjectionAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ProjectionAllocator = @ptrCast(@alignCast(context));
        if (len > scratch_bytes - self.used.*) return null;
        const result = self.parent.rawAlloc(len, alignment, ra) orelse return null;
        self.used.* += len;
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *ProjectionAllocator = @ptrCast(@alignCast(context));
        if (len > scratch_bytes - (self.used.* - memory.len)) return false;
        if (!self.parent.rawResize(memory, alignment, len, ra)) return false;
        self.used.* = self.used.* - memory.len + len;
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *ProjectionAllocator = @ptrCast(@alignCast(context));
        if (len > scratch_bytes - (self.used.* - memory.len)) return null;
        const result = self.parent.rawRemap(memory, alignment, len, ra) orelse return null;
        self.used.* = self.used.* - memory.len + len;
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ProjectionAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ra);
        self.used.* -= memory.len;
    }
};

/// Worker-only derived file. The file is disposable presentation data, never
/// canonical content. Caller supplies an already-open private temporary file.
/// All parse/C work and disk reads remain off the renderer thread.
pub const Projector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    scratch: std.heap.ArenaAllocator.State = .init,
    scratch_reserved: usize = 0,
    header: ?Header = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !Projector {
        return .{ .allocator = allocator, .io = io, .file = file };
    }

    pub fn deinit(self: *Projector) void {
        self.scratch.promote(self.allocator).deinit();
        self.file.close(self.io);
    }

    pub fn project(self: *Projector, key: Key, source: []const u8) !Header {
        // Stale file bytes are never published as the new revision on failure.
        self.header = null;
        if (source.len > source_limit) return error.SourceBudget;
        var budget = ProjectionAllocator{ .parent = self.allocator, .used = &self.scratch_reserved };
        var arena = self.scratch.promote(budget.allocator());
        defer {
            // Retain only capacity actually demanded by preceding jobs. All
            // Document/C pointers are gone before the arena is reset.
            _ = arena.reset(.retain_capacity);
            self.scratch = arena.state;
        }
        var doc = blk: {
            parse_mutex.lockUncancelable(self.io);
            defer parse_mutex.unlock(self.io);
            break :blk try markdown.parse(arena.allocator(), key.source, source);
        };
        defer doc.deinit();
        var sink = Sink{ .io = self.io, .file = self.file };
        try doc.serialize(&sink);
        try sink.flush();
        try self.file.setLength(self.io, sink.offset);
        var raw: [header_bytes]u8 = undefined;
        try self.read(&raw, 0);
        if (!std.mem.eql(u8, raw[0..4], "SPMD") or number(&raw, 4) != 1 or !std.mem.eql(u8, raw[8..24], &key.source)) return error.InvalidProjection;
        const blocks = number(&raw, 36);
        const runs = number(&raw, 40);
        const text_length = number(&raw, 44);
        const metadata_length = number(&raw, 48);
        const text_offset = header_bytes + @as(u64, blocks) * block_bytes + @as(u64, runs) * run_bytes;
        const metadata_offset = text_offset + text_length;
        if (metadata_offset + metadata_length != sink.offset) return error.InvalidProjection;
        const result = Header{ .key = key, .state = std.enums.fromInt(markdown.State, number(&raw, 32)) orelse return error.InvalidProjection, .block_count = blocks, .run_count = runs, .text_bytes = text_length, .metadata_bytes = metadata_length, .text_offset = text_offset, .metadata_offset = metadata_offset };
        self.header = result;
        return result;
    }

    /// Fixed-size rendered ranges in the immutable spool, never reparsed source
    /// fragments. Metadata stays on disk; style lookup is logarithmic.
    pub fn tile(self: *Projector, key: Key, first_block: u32, out: *Tile) !void {
        return self.page(key, .{ .block = first_block }, out);
    }

    pub fn page(self: *Projector, key: Key, cursor: Cursor, out: *Tile) !void {
        const header = self.header orelse return error.NoProjection;
        if (!std.meta.eql(header.key, key)) return error.StaleProjection;
        if (header.state != .rich) return error.DisplayBudget;
        var index = cursor.block;
        var block: Block = undefined;
        while (index < header.block_count) : (index += 1) {
            block = try self.readBlock(index);
            if (renderable(block.kind)) break;
        }
        if (index >= header.block_count) return error.EndOfProjection;
        const start = if (index == cursor.block) cursor.byte else 0;
        const length = block.end - block.start;
        if (start > length) return error.InvalidCursor;
        out.* = .{ .key = key, .block = block, .state = .rich, .start_byte = start };
        var amount: usize = @min(page_text_bytes, length - start);
        // One lookahead scalar makes arbitrary byte anchors fail explicitly and
        // page ends scalar-safe. Prefer complete lines when they fit.
        var lookahead: usize = @min(amount + 4, length - start);
        try self.read(out.text[0..lookahead], header.text_offset + block.start + start);
        while (lookahead > amount and !std.unicode.utf8ValidateSlice(out.text[0..lookahead])) lookahead -= 1;
        if (amount != 0 and out.text[0] & 0xc0 == 0x80) return error.InvalidCursor;
        if (amount < length - start) {
            while (amount > 0 and out.text[amount] & 0xc0 == 0x80) amount -= 1;
            if (std.mem.lastIndexOfScalar(u8, out.text[0..amount], '\n')) |newline| amount = newline + 1;
            var breaks: [page_text_bytes + 4]u8 = undefined;
            unicode_breaks.set_graphemebreaks_utf8(out.text[0..lookahead].ptr, lookahead, null, @ptrCast(&breaks));
            while (amount > 0 and breaks[amount - 1] != unicode_breaks.GRAPHEMEBREAK_BREAK) amount -= 1;
            if (amount == 0) return error.DisplayBudget;
        }
        if (!std.unicode.utf8ValidateSlice(out.text[0..amount])) return error.InvalidProjection;
        out.len = amount;
        if (start + amount < length) {
            out.next = .{ .block = index, .byte = start + @as(u32, @intCast(amount)) };
        } else if (index + 1 < header.block_count) out.next = .{ .block = index + 1 };
        out.next_block = if (out.next) |next| next.block else null;
        out.previous = try self.before(.{ .block = index, .byte = start });
        if (block.first_run > block.end_run or block.end_run > header.run_count) return error.InvalidProjection;
        var low = block.first_run;
        var high = block.end_run;
        const absolute = block.start + start;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const raw = try self.readRun(middle);
            if (number(&raw, 8) <= absolute) low = middle + 1 else high = middle;
        }
        while (low < block.end_run) : (low += 1) {
            const raw = try self.readRun(low);
            const run_start = number(&raw, 4);
            if (run_start >= absolute + out.len) break;
            if (out.span_count == tile_runs) {
                // End before the unadmitted run, retaining its exact next cursor.
                out.len = run_start - absolute;
                out.next = .{ .block = index, .byte = start + @as(u32, @intCast(out.len)) };
                out.next_block = index;
                break;
            }
            const run_end = @min(number(&raw, 8), absolute + @as(u32, @intCast(out.len)));
            if (run_end <= absolute or run_end <= run_start) return error.InvalidProjection;
            out.spans[out.span_count] = .{ .start = @max(run_start, absolute) - absolute, .end = run_end - absolute, .kind = std.enums.fromInt(markdown.RunKind, number(&raw, 0)) orelse return error.InvalidProjection, .flags = number(&raw, 12) };
            out.span_count += 1;
        }
        if (block.info_len != 0) {
            if (block.info_len > out.language.len or @as(u64, block.info_start) + block.info_len > header.metadata_bytes) return error.InvalidProjection;
            try self.read(out.language[0..block.info_len], header.metadata_offset + block.info_start);
            out.language_len = block.info_len;
        }
    }

    /// Locate a preceding bounded range without retaining a document-wide index.
    pub fn before(self: *Projector, cursor: Cursor) !?Cursor {
        var index = cursor.block;
        if (cursor.byte != 0) {
            const block = try self.readBlock(index);
            if (cursor.byte > block.end - block.start) return error.InvalidCursor;
            var start = cursor.byte - @min(cursor.byte, page_text_bytes);
            var bytes: [page_text_bytes + 4]u8 = undefined;
            const amount = cursor.byte - start;
            try self.read(bytes[0..amount], self.header.?.text_offset + block.start + start);
            var advance: u32 = 0;
            while (advance < amount and bytes[advance] & 0xc0 == 0x80) : (advance += 1) {}
            start += advance;
            return .{ .block = index, .byte = start };
        }
        while (index != 0) {
            index -= 1;
            const block = try self.readBlock(index);
            if (!renderable(block.kind)) continue;
            return if (block.end > block.start) try self.before(.{ .block = index, .byte = block.end - block.start }) else .{ .block = index };
        }
        return null;
    }

    fn readRun(self: *Projector, index: u32) ![run_bytes]u8 {
        var raw: [run_bytes]u8 = undefined;
        try self.read(&raw, header_bytes + @as(u64, self.header.?.block_count) * block_bytes + @as(u64, index) * run_bytes);
        return raw;
    }

    fn readBlock(self: *Projector, index: u32) !Block {
        const header = self.header.?;
        var raw: [block_bytes]u8 = undefined;
        try self.read(&raw, header_bytes + @as(u64, index) * block_bytes);
        const start = number(&raw, 8);
        const end = number(&raw, 12);
        if (start > end or end > header.text_bytes) return error.InvalidProjection;
        return .{ .index = index, .kind = std.enums.fromInt(markdown.BlockKind, number(&raw, 0)) orelse return error.InvalidProjection, .start = start, .end = end, .first_run = number(&raw, 16), .end_run = number(&raw, 20), .heading = number(&raw, 24), .flags = number(&raw, 28), .number = @bitCast(number(&raw, 32)), .columns = number(&raw, 36), .info_start = number(&raw, 44), .info_len = number(&raw, 48) };
    }

    fn read(self: *Projector, buffer: []u8, offset: u64) !void {
        if (try self.file.readPositionalAll(self.io, buffer, offset) != buffer.len) return error.InvalidProjection;
    }
};

fn number(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn renderable(kind: markdown.BlockKind) bool {
    return switch (kind) {
        .paragraph, .heading, .code, .html, .rule, .table_row => true,
        else => false,
    };
}
const Sink = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    written: u64 = 0,
    buffer: [64 * 1024]u8 = undefined,
    used: usize = 0,

    pub fn write(self: *Sink, bytes: []const u8) !void {
        if (bytes.len > spool_limit - self.offset) return error.SpoolBudget;
        var remaining = bytes;
        while (remaining.len != 0) {
            if (self.used == 0 and remaining.len >= self.buffer.len) {
                try self.file.writePositionalAll(self.io, remaining, self.written);
                self.written += remaining.len;
                break;
            }
            const amount = @min(remaining.len, self.buffer.len - self.used);
            @memcpy(self.buffer[self.used..][0..amount], remaining[0..amount]);
            self.used += amount;
            remaining = remaining[amount..];
            if (self.used == self.buffer.len) try self.flush();
        }
        self.offset += bytes.len;
    }

    fn flush(self: *Sink) !void {
        if (self.used == 0) return;
        try self.file.writePositionalAll(self.io, self.buffer[0..self.used], self.written);
        self.written += self.used;
        self.used = 0;
    }
};

pub const Wake = struct { context: *anyopaque, notify: *const fn (*anyopaque) void };
pub const PageRequest = struct { key: Key, first_block: u32, start_byte: u32 = 0, backward: bool = false, last: bool = false };
pub const Completion = union(enum) { projected: Header, tile: Tile, failure: struct { key: Key, reason: anyerror } };
const PendingSource = struct { key: Key, slot: u1, len: usize };
const WorkerStorage = struct { sources: [2][source_limit]u8, output: Completion };

/// One parse at a time, one coalesced latest source and one requested visible
/// tile. Fixed result storage requires drain before publication can continue.
/// No SDL/provider/store access; callback lifetime must cover destroy/join.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    projector: Projector,
    storage: *WorkerStorage,
    wake: Wake,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    stopping: bool = false,
    active_slot: ?u1 = null,
    pending: ?PendingSource = null,
    requested: ?PageRequest = null,
    output_ready: bool = false,

    /// File ownership transfers only on success.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, wake: Wake) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const storage = try allocator.create(WorkerStorage);
        errdefer allocator.destroy(storage);
        const projector = try Projector.init(allocator, io, file);
        self.* = .{ .allocator = allocator, .io = io, .projector = projector, .storage = storage, .wake = wake };
        self.thread = try std.Thread.spawn(.{ .allocator = allocator, .stack_size = 1024 * 1024 }, run, .{self});
        return self;
    }

    pub fn destroy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.?.join();
        self.projector.deinit();
        self.allocator.destroy(self.storage);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn submit(self: *Worker, key: Key, source: []const u8) error{ Busy, Closed, SourceBudget }!void {
        if (source.len > source_limit) return error.SourceBudget;
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Closed;
        const slot: u1 = if (self.active_slot) |active| active ^ 1 else 0;
        @memcpy(self.storage.sources[slot][0..source.len], source);
        self.pending = .{ .key = key, .slot = slot, .len = source.len };
        self.condition.signal(self.io);
    }

    pub fn request(self: *Worker, value: PageRequest) error{ Busy, Closed }!void {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Closed;
        self.requested = value;
        self.condition.signal(self.io);
    }

    /// Caller provides the bounded output destination. Borrowed file/AST/worker
    /// pointers never escape. Busy/empty never consumes a pending completion.
    pub fn drain(self: *Worker, out: *Completion) error{Busy}!bool {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        if (!self.output_ready) return false;
        switch (self.storage.output) {
            .projected => |header| out.* = .{ .projected = header },
            .failure => |failure| out.* = .{ .failure = failure },
            .tile => |*value| out.* = .{ .tile = value.* },
        }
        self.output_ready = false;
        self.condition.signal(self.io);
        return true;
    }

    fn run(self: *Worker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and (self.output_ready or (self.pending == null and self.requested == null))) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const source = self.pending;
            const request_value = if (source == null) self.requested else null;
            if (source) |job| {
                self.pending = null;
                self.active_slot = job.slot;
            } else self.requested = null;
            self.mutex.unlock(self.io);
            if (source) |job| {
                const header = self.projector.project(job.key, self.storage.sources[job.slot][0..job.len]) catch |err| {
                    self.storage.output = .{ .failure = .{ .key = job.key, .reason = err } };
                    self.publish();
                    continue;
                };
                self.storage.output = .{ .projected = header };
                self.publish();
            } else if (request_value) |request_job| {
                self.storage.output = .{ .tile = undefined };
                var cursor = Cursor{ .block = request_job.first_block, .byte = request_job.start_byte };
                const result = blk: {
                    if (request_job.last) {
                        const header = self.projector.header orelse break :blk error.NoProjection;
                        cursor = (self.projector.before(.{ .block = header.block_count }) catch |err| break :blk err) orelse break :blk error.EndOfProjection;
                    } else if (request_job.backward) {
                        cursor = (self.projector.before(cursor) catch |err| break :blk err) orelse break :blk error.EndOfProjection;
                    }
                    break :blk self.projector.page(request_job.key, cursor, &self.storage.output.tile);
                };
                result catch |err| {
                    self.storage.output = .{ .failure = .{ .key = request_job.key, .reason = err } };
                    self.publish();
                    continue;
                };
                self.publish();
            }
        }
    }

    fn publish(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.active_slot = null;
        self.output_ready = true;
        self.mutex.unlock(self.io);
        self.wake.notify(self.wake.context);
    }
};

fn tempProjector() !Projector {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "projection", .{ .read = true });
    errdefer file.close(std.testing.io);
    // Unlink now: the owned descriptor survives, crash cannot leave derived files.
    try temporary.dir.deleteFile(std.testing.io, "projection");
    return Projector.init(std.testing.allocator, std.testing.io, file);
}

test "real GFM projection pages retain styles code and distinct source identity" {
    var projector = try tempProjector();
    defer projector.deinit();
    const key = Key{ .source = @splat(1), .revision = 7, .generation = 3 };
    const header = try projector.project(key, "# Heading\n\n**bold** and *soft*\n\n```zig\nconst x = 1;\n```\n");
    try std.testing.expectEqual(markdown.State.rich, header.state);
    var tile: Tile = undefined;
    try projector.tile(key, 0, &tile);
    try std.testing.expectEqual(markdown.BlockKind.heading, tile.block.kind);
    try std.testing.expectEqualStrings("Heading\n", tile.bytes());
    try projector.tile(key, tile.next_block.?, &tile);
    try std.testing.expectEqualStrings("bold and soft\n", tile.bytes());
    try std.testing.expect(tile.span_count >= 3);
    try std.testing.expect(tile.spans[0].flags & 2 != 0);
    try projector.tile(key, tile.next_block.?, &tile);
    try std.testing.expectEqual(markdown.BlockKind.code, tile.block.kind);
    try std.testing.expectEqualStrings("zig", tile.language[0..tile.language_len]);
    try std.testing.expectEqualStrings("const x = 1;\n", tile.bytes());
    var stale = key;
    stale.revision += 1;
    try std.testing.expectError(error.StaleProjection, projector.tile(stale, 0, &tile));
}

test "projection budget and malformed source never expose previous rich revision" {
    var projector = try tempProjector();
    defer projector.deinit();
    const key = Key{ .source = @splat(2), .revision = 1, .generation = 1 };
    _ = try projector.project(key, "healthy");
    const header = try projector.project(key, "a\x00b");
    try std.testing.expectEqual(markdown.State.display_budget, header.state);
    var tile: Tile = undefined;
    try std.testing.expectError(error.DisplayBudget, projector.tile(key, 0, &tile));
}

const TestWake = struct {
    event: std.Io.Event = .unset,
    fn notify(context: *anyopaque) void {
        const self: *TestWake = @ptrCast(@alignCast(context));
        self.event.set(std.testing.io);
    }
};

test "serialized worker publishes owned projection and requested visible tile" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "worker", .{ .read = true });
    try temporary.dir.deleteFile(std.testing.io, "worker");
    var wake: TestWake = .{};
    const worker = Worker.create(std.testing.allocator, std.testing.io, file, .{ .context = &wake, .notify = TestWake.notify }) catch |err| {
        file.close(std.testing.io);
        return err;
    };
    defer worker.destroy();
    const key = Key{ .source = @splat(3), .revision = 1, .generation = 1 };
    var admitted = false;
    for (0..1000) |_| {
        worker.submit(key, "**worker**") catch |err| switch (err) {
            error.Busy => {
                try std.Thread.yield();
                continue;
            },
            else => return err,
        };
        admitted = true;
        break;
    }
    try std.testing.expect(admitted);
    try wake.event.wait(std.testing.io);
    var result: Completion = undefined;
    try drainReady(worker, &result);
    try std.testing.expectEqual(key.revision, result.projected.key.revision);
    wake.event.reset();
    var requested = false;
    for (0..1000) |_| {
        worker.request(.{ .key = key, .first_block = 0 }) catch |err| switch (err) {
            error.Busy => {
                try std.Thread.yield();
                continue;
            },
            else => return err,
        };
        requested = true;
        break;
    }
    try std.testing.expect(requested);
    try wake.event.wait(std.testing.io);
    try drainReady(worker, &result);
    try std.testing.expectEqualStrings("worker\n", result.tile.bytes());
}

fn drainReady(worker: *Worker, result: *Completion) !void {
    for (0..1000) |_| {
        const ready = worker.drain(result) catch {
            try std.Thread.yield();
            continue;
        };
        try std.testing.expect(ready);
        return;
    }
    return error.WorkerContended;
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "allocation", .{ .read = true });
    try temporary.dir.deleteFile(std.testing.io, "allocation");
    var wake: TestWake = .{};
    const worker = Worker.create(allocator, std.testing.io, file, .{ .context = &wake, .notify = TestWake.notify }) catch |err| {
        file.close(std.testing.io);
        return err;
    };
    worker.destroy();
}

test "worker initialization allocation failures release scratch file and thread ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "projection arena is demand backed and reuses warmed capacity" {
    var projector = try tempProjector();
    defer projector.deinit();
    try std.testing.expectEqual(@as(usize, 0), projector.scratch_reserved);
    const key = Key{ .source = @splat(3), .revision = 1, .generation = 1 };
    _ = try projector.project(key, "**healthy** and `code`\n");
    const warmed = projector.scratch_reserved;
    try std.testing.expect(warmed > 0 and warmed < 64 * 1024);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    projector.allocator = failing.allocator();
    for (0..10) |_| _ = try projector.project(key, "**healthy** and `code`\n");
    try std.testing.expectEqual(warmed, projector.scratch_reserved);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "projection backing cap charges overlap and releases rejected allocations" {
    var used: usize = 0;
    var budget = ProjectionAllocator{ .parent = std.testing.allocator, .used = &used };
    const allocator = budget.allocator();
    const first = try allocator.alloc(u8, scratch_bytes);
    try std.testing.expectEqual(scratch_bytes, used);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(!allocator.resize(first, scratch_bytes + 1));
    allocator.free(first);
    try std.testing.expectEqual(@as(usize, 0), used);
    const next = try allocator.alloc(u8, 32);
    allocator.free(next);
    try std.testing.expectEqual(@as(usize, 0), used);
}

fn projectAllocationProbe(allocator: std.mem.Allocator) !void {
    var projector = try tempProjector();
    projector.allocator = allocator;
    defer projector.deinit();
    const key = Key{ .source = @splat(4), .revision = 1, .generation = 1 };
    _ = projector.project(key, "# heading\n\n**bold** and *soft* with `code`\n") catch |err| {
        try std.testing.expect(projector.header == null);
        return err;
    };
}

test "projection allocation failure invalidates header and frees demanded arena" {
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..16) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        projectAllocationProbe(failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
            continue;
        };
        // Arena reset is explicitly best-effort: its preheat allocation may
        // fail after the valid document is serialized. That is not job failure.
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        successes += 1;
    }
    try std.testing.expect(failures > 0 and successes > 0);
}

test "large single code block pages exact bytes styles and distant cursors" {
    var projector = try tempProjector();
    defer projector.deinit();
    const source = try std.testing.allocator.alloc(u8, 523183);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..7], "```zig\n");
    const line = "const retained = \"é 👩‍💻\";\n";
    var written: usize = 7;
    while (written + line.len + 5 <= source.len) {
        @memcpy(source[written..][0..line.len], line);
        written += line.len;
    }
    @memset(source[written .. source.len - 5], ' ');
    @memcpy(source[source.len - 5 ..], "\n```\n");
    const key = Key{ .source = @splat(10), .revision = 1, .generation = 1 };
    const header = try projector.project(key, source);
    try std.testing.expectEqual(markdown.State.rich, header.state);
    var tile_value: Tile = undefined;
    var cursor: Cursor = .{ .block = 0 };
    var compared: usize = 0;
    var pages: usize = 0;
    var distant: ?Cursor = null;
    while (true) {
        try projector.page(key, cursor, &tile_value);
        try std.testing.expectEqual(.rich, tile_value.state);
        try std.testing.expect(tile_value.len > 0 and tile_value.len <= page_text_bytes);
        try std.testing.expectEqual(markdown.BlockKind.code, tile_value.block.kind);
        try std.testing.expectEqualStrings("zig", tile_value.language[0..tile_value.language_len]);
        // cmark adds a terminating newline to the final code line.
        const remaining = source.len - 11 - compared;
        const exact = @min(remaining, tile_value.len);
        try std.testing.expectEqualSlices(u8, source[7 + compared ..][0..exact], tile_value.bytes()[0..exact]);
        try std.testing.expectEqual(markdown.RunKind.code, tile_value.spans[0].kind);
        compared += exact;
        pages += 1;
        if (pages == 80) distant = .{ .block = tile_value.block.index, .byte = tile_value.start_byte };
        cursor = tile_value.next orelse break;
    }
    try std.testing.expect(pages > 100);
    try std.testing.expectEqual(source.len - 11, compared);
    try projector.page(key, distant.?, &tile_value);
    try std.testing.expectEqual(distant.?.byte, tile_value.start_byte);
    const previous = tile_value.previous.?;
    try std.testing.expect(previous.byte < distant.?.byte);
    try projector.page(key, previous, &tile_value);
    try std.testing.expectEqualSlices(u8, source[7 + previous.byte ..][0..tile_value.len], tile_value.bytes());
    try std.testing.expect(projector.scratch_reserved <= scratch_bytes);
    try std.testing.expectError(error.InvalidCursor, projector.page(key, .{ .block = 0, .byte = header.text_bytes + 1 }, &tile_value));
}

test "rich range pagination preserves dense formatting without a linear resident index" {
    var projector = try tempProjector();
    defer projector.deinit();
    const source = try std.testing.allocator.alloc(u8, 12000);
    defer std.testing.allocator.free(source);
    for (0..2000) |index| @memcpy(source[index * 6 ..][0..6], "**b** ");
    const key = Key{ .source = @splat(11), .revision = 1, .generation = 1 };
    _ = try projector.project(key, source);
    var tile_value: Tile = undefined;
    var cursor: Cursor = .{ .block = 0 };
    var bytes: usize = 0;
    while (true) {
        try projector.page(key, cursor, &tile_value);
        try std.testing.expect(tile_value.len != 0);
        try std.testing.expect(tile_value.span_count <= tile_runs);
        for (tile_value.spans[0..tile_value.span_count]) |span| {
            try std.testing.expect(span.end <= tile_value.len);
        }
        bytes += tile_value.len;
        cursor = tile_value.next orelse break;
    }
    try std.testing.expectEqual(@as(usize, 4000), bytes);
}
