const std = @import("std");
const c = @import("../native/bindings.zig").c;
const allocator = std.heap.page_allocator;
const storage = @import("store.zig");

pub const Thread = struct {
    path: [:0]u8,
    cwd: [:0]u8,
    title: []u8,
    /// Authoritative file modification time, in Unix milliseconds.
    modified: i64,
    available: bool = true,

    fn deinit(self: *Thread) void {
        allocator.free(self.path);
        allocator.free(self.cwd);
        allocator.free(self.title);
    }
};

pub const Folder = struct {
    cwd: []const u8,
    first_row: usize,
    row_count: usize,
};
pub const SidebarRow = union(enum) { folder: usize, thread: usize };

pub const Catalog = struct {
    threads: []Thread,
    folders: []Folder,
    rows: []SidebarRow,
    warning: ?anyerror = null,

    pub fn deinit(self: *Catalog) void {
        for (self.threads) |*thread| thread.deinit();
        allocator.free(self.folders);
        allocator.free(self.rows);
        allocator.free(self.threads);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    ready: Catalog,
    failure: anyerror,

    fn deinit(self: *Result) void {
        if (self.* == .ready) self.ready.deinit();
    }
};

/// Refresh requests coalesce; an unread result is replaced by the newest scan.
/// Environment capture is allocation-only. All filesystem IO runs on this worker.
pub const Worker = struct {
    mutex: *c.SDL_Mutex,
    condition: *c.SDL_Condition,
    thread: ?std.Thread = null,
    io: std.Io,
    environment: std.process.Environ.Map,
    legacy_dir: []u8,
    database_path: []u8,
    wake_event: u32,
    pending: bool = true,
    closing: bool = false,
    result: ?Result = null,

    pub fn create(io: std.Io, environ: std.process.Environ, legacy_dir: []const u8, database_path: []const u8, wake_event: u32) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer c.SDL_DestroyMutex(mutex);
        const condition = c.SDL_CreateCondition() orelse return error.ConditionCreation;
        errdefer c.SDL_DestroyCondition(condition);
        var environment = try environ.createMap(allocator);
        errdefer environment.deinit();
        const legacy = try allocator.dupe(u8, legacy_dir);
        errdefer allocator.free(legacy);
        const database = try allocator.dupe(u8, database_path);
        errdefer allocator.free(database);
        self.* = .{ .mutex = mutex, .condition = condition, .io = io, .environment = environment, .legacy_dir = legacy, .database_path = database, .wake_event = wake_event };
        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    pub fn refresh(self: *Worker) void {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        self.pending = true;
        c.SDL_SignalCondition(self.condition);
    }

    pub fn take(self: *Worker) ?Result {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        const result = self.result;
        self.result = null;
        return result;
    }

    pub fn destroy(self: *Worker) void {
        c.SDL_LockMutex(self.mutex);
        self.closing = true;
        c.SDL_BroadcastCondition(self.condition);
        c.SDL_UnlockMutex(self.mutex);
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit();
        self.environment.deinit();
        allocator.free(self.legacy_dir);
        allocator.free(self.database_path);
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        allocator.destroy(self);
    }

    fn run(self: *Worker) void {
        defer c.SDL_CleanupTLS();
        while (true) {
            c.SDL_LockMutex(self.mutex);
            while (!self.pending and !self.closing) c.SDL_WaitCondition(self.condition, self.mutex);
            if (self.closing) {
                c.SDL_UnlockMutex(self.mutex);
                return;
            }
            self.pending = false;
            c.SDL_UnlockMutex(self.mutex);
            var result: Result = if (discover(self.io, &self.environment, self.legacy_dir, self.database_path)) |catalog|
                .{ .ready = catalog }
            else |err|
                .{ .failure = err };
            c.SDL_LockMutex(self.mutex);
            if (self.closing) {
                result.deinit();
                c.SDL_UnlockMutex(self.mutex);
                return;
            }
            if (self.result) |*previous| previous.deinit();
            self.result = result;
            var event = std.mem.zeroes(c.SDL_Event);
            event.type = self.wake_event;
            _ = c.SDL_PushEvent(&event);
            c.SDL_UnlockMutex(self.mutex);
        }
    }
};

fn nonempty(environment: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = environment.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn expandPath(path: []const u8, home: ?[]const u8) ![]u8 {
    if (home) |base| {
        if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, base);
        if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(allocator, &.{ base, path[2..] });
    }
    if (std.mem.startsWith(u8, path, "file://")) {
        const uri = std.Uri.parse(path) catch return allocator.dupe(u8, path);
        if (uri.host) |host| {
            if (!std.mem.eql(u8, host.percent_encoded, "localhost")) return allocator.dupe(u8, path);
        }
        return std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(uri.path, .formatRaw)});
    }
    return allocator.dupe(u8, path);
}

fn discover(io: std.Io, environment: *const std.process.Environ.Map, legacy_dir: []const u8, database_path: ?[]const u8) !Catalog {
    var threads: std.ArrayList(Thread) = .empty;
    errdefer {
        for (threads.items) |*thread| thread.deinit();
        threads.deinit(allocator);
    }
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    var warning: ?anyerror = null;
    var store: ?storage.Store = if (database_path) |path| storage.Store.init(allocator, path) catch |err| blk: {
        warning = err;
        break :blk null;
    } else null;
    defer if (store) |*db| db.deinit();
    if (store) |*db| try loadIndexed(io, db, &threads, &seen, &warning);
    const home = nonempty(environment, "HOME");
    const agent = if (nonempty(environment, "PI_CODING_AGENT_DIR")) |path|
        try expandPath(path, home)
    else if (home) |path|
        try std.fs.path.join(allocator, &.{ path, ".pi", "agent" })
    else
        null;
    defer if (agent) |path| allocator.free(path);
    if (agent) |path| {
        const sessions = try std.fs.path.join(allocator, &.{ path, "sessions" });
        defer allocator.free(sessions);
        try scanRoot(io, sessions, &threads, &seen, &warning);
        // pi also permits a global settings.json sessionDir. The environment
        // wins for new sessions, but both roots may contain existing threads.
        if (try settingsSessionDir(io, path)) |custom| {
            defer allocator.free(custom);
            const expanded = try expandPath(custom, home);
            defer allocator.free(expanded);
            try scanRoot(io, expanded, &threads, &seen, &warning);
        }
    }
    if (nonempty(environment, "PI_CODING_AGENT_SESSION_DIR")) |path| {
        const expanded = try expandPath(path, home);
        defer allocator.free(expanded);
        try scanRoot(io, expanded, &threads, &seen, &warning);
    }
    try scanRoot(io, legacy_dir, &threads, &seen, &warning);
    if (store) |*db| {
        var page: [storage.max_page_rows]storage.SessionIndexEntry = undefined;
        var offset: usize = 0;
        while (offset < threads.items.len) {
            const count = @min(page.len, threads.items.len - offset);
            for (threads.items[offset..][0..count], page[0..count]) |thread, *entry| {
                entry.* = .{ .session_file = thread.path, .cwd = thread.cwd, .title = thread.title, .modified = thread.modified };
            }
            db.putSessionIndexPage(page[0..count]) catch |err| {
                warning = err;
            };
            offset += count;
        }
    }
    std.mem.sort(Thread, threads.items, {}, struct {
        fn less(_: void, a: Thread, b: Thread) bool {
            if (a.modified != b.modified) return a.modified > b.modified;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    const owned = try threads.toOwnedSlice(allocator);
    errdefer {
        for (owned) |*thread| thread.deinit();
        allocator.free(owned);
    }
    return try groupThreads(owned, warning);
}

fn loadIndexed(io: std.Io, db: *storage.Store, threads: *std.ArrayList(Thread), seen: *std.StringHashMap(void), warning: *?anyerror) !void {
    var cursor: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(cursor);
    while (true) {
        var page = try db.pageSessionIndex(allocator, cursor);
        defer page.deinit();
        if (page.entries.len == 0) return;
        for (page.entries) |entry| {
            // Cached metadata remains visible if its original source is offline;
            // reopening reports that explicitly rather than creating a thread.
            var thread = (try readThread(io, entry.session_file, warning)) orelse try indexedThread(entry);
            errdefer thread.deinit();
            try seen.put(thread.path, {});
            try threads.append(allocator, thread);
        }
        const next = try allocator.dupe(u8, page.entries[page.entries.len - 1].session_file);
        allocator.free(cursor);
        cursor = next;
    }
}

fn indexedThread(entry: storage.SessionIndexEntry) !Thread {
    const path = try allocator.dupeZ(u8, entry.session_file);
    errdefer allocator.free(path);
    const cwd = try allocator.dupeZ(u8, entry.cwd);
    errdefer allocator.free(cwd);
    return .{
        .path = path,
        .cwd = cwd,
        .title = try allocator.dupe(u8, entry.title),
        .modified = entry.modified,
        .available = false,
    };
}

fn groupThreads(threads: []Thread, warning: ?anyerror) !Catalog {
    const indices = try allocator.alloc(usize, threads.len);
    defer allocator.free(indices);
    for (indices, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, indices, threads, struct {
        fn less(items: []Thread, a: usize, b: usize) bool {
            const order = std.mem.order(u8, items[a].cwd, items[b].cwd);
            return if (order == .eq) a < b else order == .lt;
        }
    }.less);
    var folders: std.ArrayList(Folder) = .empty;
    defer folders.deinit(allocator);
    var rows: std.ArrayList(SidebarRow) = .empty;
    defer rows.deinit(allocator);
    for (indices) |index| {
        const cwd = threads[index].cwd;
        if (folders.items.len == 0 or !std.mem.eql(u8, folders.items[folders.items.len - 1].cwd, cwd)) {
            try rows.append(allocator, .{ .folder = folders.items.len });
            try folders.append(allocator, .{ .cwd = cwd, .first_row = rows.items.len - 1, .row_count = 1 });
        }
        try rows.append(allocator, .{ .thread = index });
        folders.items[folders.items.len - 1].row_count += 1;
    }
    const owned_folders = try folders.toOwnedSlice(allocator);
    errdefer allocator.free(owned_folders);
    return .{ .threads = threads, .folders = owned_folders, .rows = try rows.toOwnedSlice(allocator), .warning = warning };
}

fn settingsSessionDir(io: std.Io, agent: []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ agent, "settings.json" });
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var bytes: [65537]u8 = undefined;
    const length = file.readPositionalAll(io, &bytes, 0) catch return null;
    if (length == bytes.len) return null;
    const parsed = std.json.parseFromSlice(struct { sessionDir: ?[]const u8 = null }, allocator, bytes[0..length], .{ .ignore_unknown_fields = true, .max_value_len = 65536 }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer parsed.deinit();
    const custom = parsed.value.sessionDir orelse return null;
    return if (custom.len == 0) null else try allocator.dupe(u8, custom);
}

fn scanRoot(io: std.Io, root: []const u8, threads: *std.ArrayList(Thread), seen: *std.StringHashMap(void), warning: *?anyerror) !void {
    var directories: std.ArrayList([]u8) = .empty;
    defer {
        for (directories.items) |path| allocator.free(path);
        directories.deinit(allocator);
    }
    const owned_root = try allocator.dupe(u8, root);
    directories.append(allocator, owned_root) catch |err| {
        allocator.free(owned_root);
        return err;
    };
    var index: usize = 0;
    while (index < directories.items.len) : (index += 1) {
        const path = directories.items[index];
        var directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) warning.* = err;
            continue;
        };
        defer directory.close(io);
        var iterator = directory.iterate();
        while (iterator.next(io) catch |err| blk: {
            warning.* = err;
            break :blk null;
        }) |entry| {
            if (entry.kind == .directory) {
                const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
                directories.append(allocator, child_path) catch |err| {
                    allocator.free(child_path);
                    return err;
                };
                continue;
            }
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const canonical = directory.realPathFileAlloc(io, entry.name, allocator) catch |err| {
                warning.* = err;
                continue;
            };
            defer allocator.free(canonical);
            if (seen.contains(canonical)) continue;
            var thread = (try readThread(io, canonical, warning)) orelse continue;
            errdefer thread.deinit();
            try seen.put(thread.path, {});
            try threads.append(allocator, thread);
        }
    }
}

fn Bounded(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        length: usize = 0,
        overflow: bool = false,

        fn reset(self: *@This()) void {
            self.length = 0;
            self.overflow = false;
        }

        fn append(self: *@This(), bytes: []const u8) void {
            const count = @min(bytes.len, capacity - self.length);
            @memcpy(self.bytes[self.length..][0..count], bytes[0..count]);
            self.length += count;
            self.overflow = self.overflow or count != bytes.len;
        }

        fn value(self: *const @This()) []const u8 {
            // A bounded prefix may end in the middle of a UTF-8 codepoint.
            var end = self.length;
            while (end > 0 and !std.unicode.utf8ValidateSlice(self.bytes[0..end])) : (end -= 1) {}
            return self.bytes[0..end];
        }
    };
}

const title_limit = 256;
const Key = enum { other, type, cwd, name, message, role, content, text };
const Context = enum { root, message, content, block, ignored };
const Frame = struct { context: Context, object: bool, key: Key = .other, wants_key: bool = true };

/// Projects only metadata while validating each complete JSONL record. String
/// tokens (including huge images/tool output) are streamed, never accumulated.
/// Both parser nesting and captured metadata have fixed bounds.
const Record = struct {
    scanner: std.json.Scanner,
    frames: [128]Frame = undefined,
    depth: usize = 0,
    valid: bool = true,
    complete: bool = false,
    token_text: Bounded(65536) = .{},
    kind: Bounded(32) = .{},
    cwd: Bounded(65536) = .{},
    name: Bounded(title_limit) = .{},
    role: Bounded(32) = .{},
    prompt: Bounded(title_limit) = .{},
    block_type: Bounded(32) = .{},
    block_text: Bounded(title_limit) = .{},

    fn init(self: *Record) void {
        self.scanner = std.json.Scanner.initStreaming(allocator);
        self.depth = 0;
        self.valid = true;
        self.complete = false;
        inline for (.{ "token_text", "kind", "cwd", "name", "role", "prompt", "block_type", "block_text" }) |field| {
            @field(self, field).reset();
        }
    }

    fn feed(self: *Record, bytes: []const u8) !void {
        if (!self.valid) return;
        self.scanner.feedInput(bytes);
        try self.drain();
    }

    fn finish(self: *Record) !void {
        if (!self.valid) return;
        self.scanner.endInput();
        try self.drain();
    }

    fn drain(self: *Record) !void {
        while (true) {
            const token = self.scanner.next() catch |err| {
                if (err == error.BufferUnderrun) return;
                if (err == error.OutOfMemory) return err;
                self.valid = false;
                return;
            };
            switch (token) {
                .partial_string => |bytes| self.capture(bytes),
                .partial_string_escaped_1 => |bytes| self.capture(&bytes),
                .partial_string_escaped_2 => |bytes| self.capture(&bytes),
                .partial_string_escaped_3 => |bytes| self.capture(&bytes),
                .partial_string_escaped_4 => |bytes| self.capture(&bytes),
                .string => |bytes| {
                    self.capture(bytes);
                    self.string(self.token_text.value());
                    self.token_text.reset();
                },
                .object_begin, .array_begin => {
                    if (self.depth == self.frames.len) {
                        self.valid = false;
                        return;
                    }
                    const object = token == .object_begin;
                    var context: Context = .ignored;
                    if (self.depth == 0) {
                        if (!object) self.valid = false;
                        context = .root;
                    } else {
                        const parent = &self.frames[self.depth - 1];
                        if (parent.context == .root and parent.key == .message and object) context = .message;
                        if (parent.context == .message and parent.key == .content and !object) context = .content;
                        if (parent.context == .content and object) {
                            context = .block;
                            self.block_type.reset();
                            self.block_text.reset();
                        }
                        parent.wants_key = true;
                    }
                    self.frames[self.depth] = .{ .context = context, .object = object };
                    self.depth += 1;
                },
                .object_end, .array_end => {
                    if (self.depth == 0) {
                        self.valid = false;
                        return;
                    }
                    self.depth -= 1;
                    if (self.frames[self.depth].context == .block and std.mem.eql(u8, self.block_type.value(), "text")) {
                        if (self.prompt.length > 0) self.prompt.append(" ");
                        self.prompt.append(self.block_text.value());
                    }
                },
                .number, .null, .true, .false => if (self.depth > 0) {
                    self.frames[self.depth - 1].wants_key = true;
                },
                .end_of_document => {
                    self.complete = true;
                    return;
                },
                else => {},
            }
            if (!self.valid) return;
        }
    }

    fn capture(self: *Record, bytes: []const u8) void {
        if (self.depth == 0) return;
        const frame = self.frames[self.depth - 1];
        // Ignore irrelevant values, retaining only short keys and metadata.
        if (frame.object and frame.wants_key or
            frame.context == .root and (frame.key == .type or frame.key == .cwd or frame.key == .name) or
            frame.context == .message and (frame.key == .role or frame.key == .content) or
            frame.context == .block and (frame.key == .type or frame.key == .text))
            self.token_text.append(bytes);
    }

    fn string(self: *Record, bytes: []const u8) void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        if (frame.object and frame.wants_key) {
            frame.key = .other;
            inline for (std.meta.fields(Key)) |field| {
                if (std.mem.eql(u8, bytes, field.name)) frame.key = @enumFromInt(field.value);
            }
            frame.wants_key = false;
            return;
        }
        switch (frame.context) {
            .root => switch (frame.key) {
                .type => self.kind.append(bytes),
                .cwd => {
                    self.cwd.append(bytes);
                    self.cwd.overflow = self.cwd.overflow or self.token_text.overflow;
                },
                .name => self.name.append(bytes),
                else => {},
            },
            .message => switch (frame.key) {
                .role => self.role.append(bytes),
                .content => self.prompt.append(bytes),
                else => {},
            },
            .block => switch (frame.key) {
                .type => self.block_type.append(bytes),
                .text => self.block_text.append(bytes),
                else => {},
            },
            else => {},
        }
        frame.wants_key = true;
    }
};

const Metadata = struct {
    cwd: ?[:0]u8 = null,
    name: ?[]u8 = null,
    prompt: ?[]u8 = null,

    fn deinit(self: *Metadata) void {
        if (self.cwd) |bytes| allocator.free(bytes);
        if (self.name) |bytes| allocator.free(bytes);
        if (self.prompt) |bytes| allocator.free(bytes);
    }

    fn accept(self: *Metadata, record: *const Record) !void {
        if (!record.valid or !record.complete) return;
        const kind = record.kind.value();
        if (self.cwd == null) {
            const cwd = record.cwd.value();
            if (!std.mem.eql(u8, kind, "session") or cwd.len == 0 or record.cwd.overflow or std.mem.indexOfScalar(u8, cwd, 0) != null) return;
            self.cwd = try allocator.dupeZ(u8, cwd);
        } else if (std.mem.eql(u8, kind, "session_info")) {
            const name = std.mem.trim(u8, record.name.value(), " \t\r\n");
            const owned = if (name.len == 0) null else try allocator.dupe(u8, name);
            if (self.name) |old| allocator.free(old);
            self.name = owned;
        } else if (self.prompt == null and std.mem.eql(u8, kind, "message") and std.mem.eql(u8, record.role.value(), "user")) {
            const prompt = std.mem.trim(u8, record.prompt.value(), " \t\r\n");
            if (prompt.len > 0) self.prompt = try allocator.dupe(u8, prompt);
        }
    }
};

fn readThread(io: std.Io, path: []const u8, warning: *?anyerror) !?Thread {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err != error.FileNotFound) warning.* = err;
        return null;
    };
    defer file.close(io);
    const stat = file.stat(io) catch |err| {
        warning.* = err;
        return null;
    };
    if (stat.kind != .file) return null;
    var metadata: Metadata = .{};
    defer metadata.deinit();
    // Keep the two 64 KiB metadata buffers and parser state off the worker
    // stack. In-place reset also avoids large aggregate temporaries in Debug.
    const record = try allocator.create(Record);
    defer allocator.destroy(record);
    record.init();
    defer record.scanner.deinit();
    var buffer: [16384]u8 = undefined;
    var offset: u64 = 0;
    // Read only the size observed at scan start, rather than chase a live writer.
    while (offset < stat.size) {
        const count = file.readPositional(io, &.{buffer[0..@min(buffer.len, stat.size - offset)]}, offset) catch |err| {
            warning.* = err;
            return null;
        };
        if (count == 0) break;
        offset += count;
        var start: usize = 0;
        for (buffer[0..count], 0..) |byte, index| {
            if (byte != '\n') continue;
            try record.feed(buffer[start..index]);
            try record.finish();
            try metadata.accept(record);
            record.scanner.deinit();
            record.init();
            start = index + 1;
        }
        try record.feed(buffer[start..count]);
    }
    try record.finish();
    try metadata.accept(record);
    const cwd = metadata.cwd orelse return null;
    const owned_path = try allocator.dupeZ(u8, path);
    errdefer allocator.free(owned_path);
    const title = if (metadata.name) |name| blk: {
        metadata.name = null;
        break :blk name;
    } else if (metadata.prompt) |prompt| blk: {
        metadata.prompt = null;
        break :blk prompt;
    } else try allocator.dupe(u8, "Untitled session");
    metadata.cwd = null;
    return .{ .path = owned_path, .cwd = cwd, .title = title, .modified = stat.mtime.toMilliseconds() };
}

fn testWrite(directory: std.Io.Dir, path: []const u8, bytes: []const u8, modified: i64) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(path)) |parent| try directory.createDirPath(io, parent);
    try directory.writeFile(io, .{ .sub_path = path, .data = bytes });
    const file = try directory.openFile(io, path, .{});
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, modified) * std.time.ns_per_ms) } });
}

fn testDiscoverOnWorker(io: std.Io, environment: *const std.process.Environ.Map, legacy_dir: []const u8) !Catalog {
    const Scan = struct {
        io: std.Io,
        environment: *const std.process.Environ.Map,
        legacy_dir: []const u8,
        result: Result = undefined,

        fn run(self: *@This()) void {
            self.result = if (discover(self.io, self.environment, self.legacy_dir, null)) |catalog|
                .{ .ready = catalog }
            else |err|
                .{ .failure = err };
        }
    };
    var scan: Scan = .{ .io = io, .environment = environment, .legacy_dir = legacy_dir };
    // Metadata parsing must fit the production worker, not just the test
    // runner's much larger main-thread stack.
    const thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, Scan.run, .{&scan});
    thread.join();
    return switch (scan.result) {
        .ready => |catalog| catalog,
        .failure => |err| err,
    };
}

test "catalog discovers all cwd folders and legacy sessions, orders by file recency, and isolates broken records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", root);
    try testWrite(tmp.dir, ".pi/agent/sessions/--first--/a.jsonl",
        "{\"type\":\"session\",\"cwd\":\"/projects/first\"}\n" ++
        "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"data\":\"unused\"},{\"text\":\"First \\\\ request\",\"type\":\"text\"}]}}\n" ++
        "{\"type\":\"session_info\",\"name\":\"Old name\"}\n" ++
        "not JSON\n" ++
        "{\"type\":\"session_info\",\"name\":\"  Latest name  \"}\n" ++
        "{\"type\":\"session_info\",\"name\":\"Interrupted", 1000);
    try testWrite(tmp.dir, ".pi/agent/sessions/--second--/b.jsonl",
        "{\"cwd\":\"/elsewhere/second\",\"type\":\"session\"}\r\n" ++
        "{\"type\":\"message\",\"message\":{\"content\":\"Second prompt\",\"role\":\"user\"}}\n" ++
        "{\"type\":\"session_info\",\"name\":\"Discarded name\"}\n" ++
        "{\"type\":\"session_info\",\"name\":\"\"}\n", 3000);
    try testWrite(tmp.dir, "legacy/c.jsonl", "{\"type\":\"session\",\"cwd\":\"/legacy/project\"}\n", 2000);
    try testWrite(tmp.dir, ".pi/agent/sessions/--broken--/bad.jsonl", "{\"type\":\"session\",\"cwd\":", 4000);
    const legacy = try std.fs.path.join(std.testing.allocator, &.{ root, "legacy" });
    defer std.testing.allocator.free(legacy);
    var catalog = try testDiscoverOnWorker(io, &environment, legacy);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 3), catalog.threads.len);
    try std.testing.expectEqualStrings("/elsewhere/second", catalog.threads[0].cwd);
    try std.testing.expectEqualStrings("Second prompt", catalog.threads[0].title);
    try std.testing.expectEqual(@as(i64, 3000), catalog.threads[0].modified);
    try std.testing.expectEqualStrings("/legacy/project", catalog.threads[1].cwd);
    try std.testing.expectEqualStrings("Untitled session", catalog.threads[1].title);
    try std.testing.expectEqualStrings("/projects/first", catalog.threads[2].cwd);
    try std.testing.expectEqualStrings("Latest name", catalog.threads[2].title);
}

test "catalog honors agent/session directory overrides and settings, deduplicates roots, and tolerates absence" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", root);
    try environment.put("PI_CODING_AGENT_DIR", "~/custom-agent");
    try environment.put("PI_CODING_AGENT_SESSION_DIR", "~/custom-sessions");
    try testWrite(tmp.dir, "custom-agent/settings.json", "{\"sessionDir\":\"~/configured\",\"other\":true}", 0);
    try testWrite(tmp.dir, "custom-agent/sessions/--cwd--/a.jsonl", "{\"type\":\"session\",\"cwd\":\"/agent\"}\n", 1000);
    try testWrite(tmp.dir, "custom-sessions/b.jsonl", "{\"type\":\"session\",\"cwd\":\"/override\"}\n", 2000);
    try testWrite(tmp.dir, "configured/c.jsonl", "{\"type\":\"session\",\"cwd\":\"/settings\"}\n", 3000);
    const legacy = try std.fs.path.join(std.testing.allocator, &.{ root, "custom-sessions", "." });
    defer std.testing.allocator.free(legacy);
    var catalog = try discover(io, &environment, legacy, null);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 3), catalog.threads.len);
    try std.testing.expectEqualStrings("/settings", catalog.threads[0].cwd);
    try std.testing.expectEqualStrings("/override", catalog.threads[1].cwd);
    try std.testing.expectEqualStrings("/agent", catalog.threads[2].cwd);
    try environment.put("HOME", "/does-not-exist/spica-catalog-test");
    try environment.put("PI_CODING_AGENT_DIR", "");
    try environment.put("PI_CODING_AGENT_SESSION_DIR", "");
    var absent = try discover(io, &environment, "/does-not-exist/spica-catalog-test/legacy", null);
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), absent.threads.len);
}

test "catalog streams oversized prompts and attachments, recovers after invalid nesting, and has no folder cap" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("HOME", root);
    try environment.put("PI_CODING_AGENT_SESSION_DIR", root);
    const file = try tmp.dir.createFile(io, "huge.jsonl", .{});
    {
        defer file.close(io);
        try file.writeStreamingAll(io, "{\"type\":\"session\",\"cwd\":\"/huge\"}\n{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"");
        var chunk: [16384]u8 = undefined;
        @memset(&chunk, 'x');
        for (0..256) |_| try file.writeStreamingAll(io, &chunk);
        try file.writeStreamingAll(io, "\"}}\n{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"image\",\"data\":\"");
        for (0..256) |_| try file.writeStreamingAll(io, &chunk);
        try file.writeStreamingAll(io, "\"}]}}\n");
        try file.writeStreamingAll(io, "{\"ignored\":");
        const nesting: [256]u8 = @splat('[');
        try file.writeStreamingAll(io, &nesting);
        try file.writeStreamingAll(io, "\n{\"type\":\"session_info\",\"name\":\"Preserved after huge records\"}\n");
        try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(5000 * std.time.ns_per_ms) } });
    }
    for (0..140) |index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "folder-{d}/thread.jsonl", .{index});
        defer std.testing.allocator.free(path);
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"type\":\"session\",\"cwd\":\"/project-{d}\"}}\n", .{index});
        defer std.testing.allocator.free(bytes);
        try testWrite(tmp.dir, path, bytes, @intCast(index));
    }
    var catalog = try discover(io, &environment, root, null);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 141), catalog.threads.len);
    try std.testing.expectEqualStrings("/huge", catalog.threads[0].cwd);
    try std.testing.expectEqualStrings("Preserved after huge records", catalog.threads[0].title);
    for (catalog.threads[1..], 0..) |thread, index| {
        const cwd = try std.fmt.allocPrint(std.testing.allocator, "/project-{d}", .{139 - index});
        defer std.testing.allocator.free(cwd);
        try std.testing.expectEqualStrings(cwd, thread.cwd);
    }
    // A clear restores the first prompt even though it exceeded the display
    // budget by orders of magnitude; the authoritative file remains complete.
    const append = try tmp.dir.openFile(io, "huge.jsonl", .{ .mode = .read_write });
    defer append.close(io);
    const before = try append.stat(io);
    try append.writePositionalAll(io, "{\"type\":\"session_info\",\"name\":\"\"}\n", before.size);
    var refreshed = try discover(io, &environment, root, null);
    defer refreshed.deinit();
    const expected: [title_limit]u8 = @splat('x');
    try std.testing.expectEqualStrings(&expected, refreshed.threads[0].title);
    const after = try append.stat(io);
    try std.testing.expectEqual(before.size + "{\"type\":\"session_info\",\"name\":\"\"}\n".len, after.size);
}

test "catalog restart retains indexed and imported sessions outside current discovery roots" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const db_path = try std.fs.path.join(a, &.{ root, "history.sqlite" });
    defer a.free(db_path);
    const legacy = try std.fs.path.join(a, &.{ root, "missing-legacy" });
    defer a.free(legacy);
    const indexed_path = try std.fs.path.join(a, &.{ root, ".pi", "agent", "sessions", "a.jsonl" });
    defer a.free(indexed_path);
    const imported_path = try std.fs.path.join(a, &.{ root, "external", "b.jsonl" });
    defer a.free(imported_path);
    try testWrite(tmp.dir, ".pi/agent/sessions/a.jsonl",
        "{\"type\":\"session\",\"cwd\":\"/first-project\"}\n" ++
        "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"Original first prompt\"}}\n", 1000);
    try testWrite(tmp.dir, "external/b.jsonl",
        "{\"type\":\"session\",\"cwd\":\"/second-project\"}\n" ++
        "{\"type\":\"session_info\",\"name\":\"Original external chat\"}\n", 2000);
    {
        var db = try storage.Store.init(a, db_path);
        defer db.deinit();
        try db.putSession(.{ .session_file = imported_path, .session_id = "external-id", .project_id = "/second-project", .leaf_id = "original-leaf" });
    }
    var environment = std.process.Environ.Map.init(a);
    defer environment.deinit();
    try environment.put("HOME", root);
    {
        var catalog = try discover(io, &environment, legacy, db_path);
        defer catalog.deinit();
        try std.testing.expectEqual(@as(usize, 2), catalog.threads.len);
        try std.testing.expectEqualStrings(imported_path, catalog.threads[0].path);
        try std.testing.expectEqualStrings("/second-project", catalog.threads[0].cwd);
        try std.testing.expectEqualStrings("Original external chat", catalog.threads[0].title);
        try std.testing.expectEqualStrings(indexed_path, catalog.threads[1].path);
        try std.testing.expect(catalog.threads[0].available and catalog.threads[1].available);
    }
    // Neither source is under the new default root. Reopening must still use
    // its original source path and cwd, not a newly created session.
    try environment.put("HOME", "/does-not-exist/spica-catalog-restart");
    {
        var restarted = try discover(io, &environment, legacy, db_path);
        defer restarted.deinit();
        try std.testing.expectEqual(@as(usize, 2), restarted.threads.len);
        try std.testing.expectEqualStrings(imported_path, restarted.threads[0].path);
        try std.testing.expectEqualStrings(indexed_path, restarted.threads[1].path);
        try std.testing.expectEqualStrings("Original first prompt", restarted.threads[1].title);
        try std.testing.expectEqual(@as(usize, 2), restarted.folders.len);
        try std.testing.expectEqualStrings("/first-project", restarted.folders[0].cwd);
        try std.testing.expectEqualStrings("/second-project", restarted.folders[1].cwd);
    }
    try tmp.dir.deleteFile(io, "external/b.jsonl");
    {
        var offline = try discover(io, &environment, legacy, db_path);
        defer offline.deinit();
        try std.testing.expectEqual(@as(usize, 2), offline.threads.len);
        try std.testing.expectEqualStrings(imported_path, offline.threads[0].path);
        try std.testing.expectEqualStrings("Original external chat", offline.threads[0].title);
        try std.testing.expect(!offline.threads[0].available);
        try std.testing.expect(offline.threads[1].available);
    }
}
