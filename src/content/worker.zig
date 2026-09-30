const std = @import("std");
const c = @import("../native/bindings.zig").c;
const Store = @import("../core/store.zig").Store;
const ContentId = @import("../core/store.zig").ContentId;
const md = @import("markdown.zig");
const fixture = @import("../diagnostics/fixture.zig");
const allocator = std.heap.page_allocator;

pub const Role = enum { user, assistant, tool, bash, system };
pub fn roleFor(role: []const u8, kind: []const u8) Role {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "bashExecution") or std.mem.eql(u8, kind, "bash")) return .bash;
    if (std.mem.eql(u8, role, "toolResult") or std.mem.eql(u8, kind, "tool")) return .tool;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    return .system;
}

pub const Request = struct {
    generation: u64,
    conversation: bool = false,
    runtime_id: u64 = 0,
    run_generation: i64 = 0,
    ordinal: usize = 0,
    session_file: []const u8 = fixture.session_file,
    content_id: ?ContentId = null,
    published_length: ?u64 = null,
    role: Role = .assistant,
};
const OwnedRequest = struct {
    value: Request,
    session_storage: ?[]u8 = null,
    fn deinit(self: *OwnedRequest) void {
        if (self.session_storage) |bytes| allocator.free(bytes);
    }
};
pub const Highlight = struct { start: u32, end: u32, token_class: c_uint };
pub const Ready = struct {
    generation: u64,
    ordinal: usize,
    role: Role = .assistant,
    document: md.Document,
    image: c.SpicaImageResult = std.mem.zeroes(c.SpicaImageResult),
    image_status: c.SpicaImageStatus = c.SPICA_IMAGE_OK,
    highlights: std.ArrayList(Highlight) = .empty,
    highlight_limited: bool = false,
    pub fn deinit(self: *Ready) void {
        self.document.deinit();
        c.spica_image_release(&self.image);
        self.highlights.deinit(allocator);
    }
};
pub const Conversation = struct {
    generation: u64,
    entries: []@import("../core/store.zig").ConversationEntry,
    pub fn deinit(self: *Conversation) void {
        allocator.free(self.entries);
    }
};
pub const Result = union(enum) {
    ready: Ready,
    conversation: Conversation,
    failure: struct { err: anyerror, generation: ?u64 },
    pub fn deinit(self: *Result) void {
        switch (self.*) {
            .ready => |*value| value.deinit(),
            .conversation => |*value| value.deinit(),
            .failure => {},
        }
    }
};

// One coalesced viewport request and one ownership-transfer result. A revision
// superseding an in-flight parse discards that result before it can reach SDL.
pub const Worker = struct {
    mutex: *c.SDL_Mutex,
    condition: *c.SDL_Condition,
    thread: ?std.Thread = null,
    io: std.Io,
    database_path: [:0]u8,
    fixture_mode: bool,
    wake_event: u32,
    closing: bool = false,
    pending: ?OwnedRequest = null,
    result: ?Result = null,
    latest_generation: u64 = 0,

    pub fn create(io: std.Io, database_path: []const u8, fixture_mode: bool, wake_event: u32) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer c.SDL_DestroyMutex(mutex);
        const condition = c.SDL_CreateCondition() orelse return error.ConditionCreation;
        errdefer c.SDL_DestroyCondition(condition);
        const path = try allocator.dupeZ(u8, database_path);
        errdefer allocator.free(path);
        self.* = .{ .mutex = mutex, .condition = condition, .io = io, .database_path = path, .fixture_mode = fixture_mode, .wake_event = wake_event };
        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, threadMain, .{self});
        return self;
    }

    pub fn destroy(self: *Worker) void {
        c.SDL_LockMutex(self.mutex);
        self.closing = true;
        c.SDL_BroadcastCondition(self.condition);
        c.SDL_UnlockMutex(self.mutex);
        if (self.thread) |thread| thread.join();
        if (self.pending) |*pending| pending.deinit();
        if (self.result) |*result| result.deinit();
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        allocator.free(self.database_path);
        allocator.destroy(self);
    }

    pub fn request(self: *Worker, value: Request) !void {
        var owned: OwnedRequest = .{ .value = value };
        if (value.content_id == null) {
            owned.session_storage = try allocator.dupe(u8, value.session_file);
            owned.value.session_file = owned.session_storage.?;
        }
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        self.latest_generation = value.generation;
        if (self.pending) |*previous| previous.deinit();
        self.pending = owned;
        c.SDL_SignalCondition(self.condition);
    }

    pub fn take(self: *Worker) ?Result {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        const result = self.result;
        self.result = null;
        c.SDL_SignalCondition(self.condition);
        return result;
    }

    fn publish(self: *Worker, result_value: Result, generation: ?u64) void {
        var value = result_value;
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.closing or (generation != null and generation.? != self.latest_generation)) {
            value.deinit();
            return;
        }
        while (self.result != null and !self.closing) c.SDL_WaitCondition(self.condition, self.mutex);
        if (self.closing or (generation != null and generation.? != self.latest_generation)) {
            value.deinit();
            return;
        }
        self.result = value;
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = self.wake_event;
        // An SDL queue failure cannot leave the GUI sleeping forever.
        if (!c.SDL_PushEvent(&event)) {
            std.log.err("content notification: {s}", .{c.SDL_GetError()});
        }
    }

    fn threadMain(self: *Worker) void {
        self.run() catch |err| self.publish(.{ .failure = .{ .err = err, .generation = null } }, null);
        c.SDL_CleanupTLS();
    }

    fn run(self: *Worker) !void {
        if (self.fixture_mode) {
            var writer = try Store.init(allocator, self.database_path);
            defer writer.deinit();
            var page = try writer.pageEntries(allocator, fixture.session_file, -1, 1);
            defer page.deinit();
            if (page.rows.len == 0) try fixture.seed(&writer, allocator, self.io);
        }
        // Real runtimes are the sole initializer/writer. A viewport request is
        // published only after that owner has committed the referenced source.
        var reader: ?Store = null;
        defer if (reader) |*db| db.deinit();
        while (true) {
            c.SDL_LockMutex(self.mutex);
            while (self.pending == null and !self.closing) c.SDL_WaitCondition(self.condition, self.mutex);
            if (self.closing) {
                c.SDL_UnlockMutex(self.mutex);
                return;
            }
            var owned = self.pending.?;
            self.pending = null;
            c.SDL_UnlockMutex(self.mutex);
            defer owned.deinit();
            const value = owned.value;
            if (reader == null) {
                reader = Store.openReadOnly(allocator, self.database_path) catch |err| {
                    self.publish(.{ .failure = .{ .err = err, .generation = value.generation } }, value.generation);
                    continue;
                };
            }
            if (value.conversation) {
                const entries = reader.?.conversationEntries(allocator, value.session_file, self.fixture_mode, value.runtime_id, value.run_generation) catch |err| {
                    self.publish(.{ .failure = .{ .err = err, .generation = value.generation } }, value.generation);
                    continue;
                };
                self.publish(.{ .conversation = .{ .generation = value.generation, .entries = entries } }, value.generation);
                continue;
            }
            const loaded = load(&reader.?, value, self.fixture_mode) catch |err| {
                self.publish(.{ .failure = .{ .err = err, .generation = value.generation } }, value.generation);
                continue;
            };
            self.publish(.{ .ready = loaded }, value.generation);
        }
    }

    fn readSource(db: *Store, id: ContentId, limit: u64) ![]u8 {
        var info = try db.contentInfo(allocator, id);
        defer info.deinit();
        if (info.total_length > limit) return error.DisplayBudget;
        const source = try allocator.alloc(u8, @intCast(info.total_length));
        errdefer allocator.free(source);
        var offset: usize = 0;
        var index: u64 = 0;
        while (try db.readChunk(allocator, id, index)) |chunk| : (index += 1) {
            defer allocator.free(chunk);
            if (chunk.len > source.len - offset) return error.CorruptCache;
            @memcpy(source[offset..][0..chunk.len], chunk);
            offset += chunk.len;
        }
        if (offset != source.len) return error.CorruptCache;
        return source;
    }

    fn readPublishedSource(db: *Store, id: ContentId, length: u64) ![]u8 {
        const source = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(source);
        var offset: usize = 0;
        var index: u64 = 0;
        while (offset < source.len) : (index += 1) {
            const chunk = (try db.readPublishedChunk(allocator, id, index, offset, length)) orelse return error.UnpublishedContent;
            defer allocator.free(chunk);
            if (chunk.len == 0 or chunk.len > source.len - offset) return error.CorruptCache;
            @memcpy(source[offset..][0..chunk.len], chunk);
            offset += chunk.len;
        }
        return source;
    }

    fn load(db: *Store, value: Request, fixture_mode: bool) !Ready {
        var role = value.role;
        const id = value.content_id orelse blk: {
            var page = if (fixture_mode) try db.pageEntries(allocator, value.session_file, @as(i64, @intCast(value.ordinal)) - 1, 1) else try db.pageActiveEntries(allocator, value.session_file, @as(i64, @intCast(value.ordinal)) - 1, 1);
            defer page.deinit();
            if (page.rows.len == 0) return error.ContentNotFound;
            role = roleFor(page.rows[0].role, page.rows[0].kind);
            break :blk page.rows[0].content_ref orelse return error.ContentNotFound;
        };
        const length = value.published_length orelse blk: {
            var info = try db.contentInfo(allocator, id);
            defer info.deinit();
            break :blk info.total_length;
        };
        if (length > md.max_source_bytes) return .{
            .generation = value.generation,
            .ordinal = value.ordinal,
            .role = role,
            .document = .{ .allocator = allocator, .source_id = id, .source_length = length, .state = .display_budget },
        };
        const source = if (value.published_length != null) try readPublishedSource(db, id, length) else try readSource(db, id, md.max_source_bytes);
        defer allocator.free(source);
        var ready: Ready = .{
            .generation = value.generation,
            .ordinal = value.ordinal,
            .role = role,
            .document = if (role == .tool or role == .bash) .{ .allocator = allocator, .source_id = id, .source_length = length } else try md.parse(allocator, id, source),
        };
        errdefer ready.deinit();
        if (role == .tool or role == .bash) {
            try ready.document.text.appendSlice(allocator, source);
            try ready.document.blocks.append(allocator, .{ .kind = .code, .parent = null, .text_start = 0, .text_end = @intCast(source.len), .first_run = 0, .end_run = 0 });
        }
        for (ready.document.blocks.items) |block| {
            if (block.kind != .code) continue;
            const info = ready.document.metadata.items[block.info.start..][0..block.info.len];
            const end = std.mem.indexOfAny(u8, info, " \t\r\n") orelse info.len;
            if (end > 32) continue;
            var language: [33]u8 = undefined;
            @memcpy(language[0..end], info[0..end]);
            language[end] = 0;
            const code = ready.document.text.items[block.text_start..block.text_end];
            var job: ?*c.SpicaHighlight = null;
            const status = c.spica_highlight_parse(code.ptr, code.len, &language, (@import("build_options").native_library_dir ++ "\x00").ptr, md.parse_arena_bytes, &job);
            if (status == c.SPICA_HIGHLIGHT_UNSUPPORTED) continue;
            if (status != c.SPICA_HIGHLIGHT_OK) {
                ready.highlight_limited = true;
                continue;
            }
            defer c.spica_highlight_release(job);
            const count = c.spica_highlight_span_count(job);
            const spans = c.spica_highlight_spans(job);
            if (count > 16384 - ready.highlights.items.len) {
                ready.highlight_limited = true;
                continue;
            }
            for (spans[0..count]) |span| try ready.highlights.append(allocator, .{
                .start = block.text_start + @as(u32, @intCast(span.byte_start)),
                .end = block.text_start + @as(u32, @intCast(span.byte_end)),
                .token_class = span.token_class,
            });
        }
        if (fixture_mode and value.ordinal == fixture.message_count - 1) {
            const image_source = try readSource(db, fixture.image_id, 2 * 1024 * 1024);
            defer allocator.free(image_source);
            ready.image_status = c.spica_image_decode(image_source.ptr, image_source.len, 512, 256, 2 * 1024 * 1024, &ready.image);
        }
        return ready;
    }
};
