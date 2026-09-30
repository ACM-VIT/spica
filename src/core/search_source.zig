const std = @import("std");
const sql = @import("search_sql.zig");
const c = sql.c;
const allocator = std.heap.page_allocator;
const chunk_size = 65536;
const overlap = 512;

/// Derived search data lives beside, never in place of, authoritative records.
/// Schema creation is serialized with other search connections; unavailable FTS5
/// is an explicit initialization error, not a silently empty search index.
pub fn init(db: *sql.Db) !void {
    try db.exec("BEGIN IMMEDIATE");
    errdefer db.exec("ROLLBACK") catch {};
    try db.exec(
        "CREATE TABLE IF NOT EXISTS search_sources(session_file TEXT PRIMARY KEY,generation INTEGER NOT NULL DEFAULT 0,size INTEGER NOT NULL DEFAULT 0,mtime TEXT NOT NULL DEFAULT '',identity TEXT NOT NULL DEFAULT '',leaf TEXT NOT NULL DEFAULT '',available INTEGER NOT NULL DEFAULT 1,incomplete INTEGER NOT NULL DEFAULT 0);" ++
        "CREATE TABLE IF NOT EXISTS search_segments(rowid INTEGER PRIMARY KEY,session_file TEXT NOT NULL,generation INTEGER NOT NULL,entry_id TEXT NOT NULL,field INTEGER NOT NULL,text TEXT NOT NULL);" ++
        "CREATE INDEX IF NOT EXISTS search_segments_source ON search_segments(session_file,generation,rowid);" ++
        "CREATE TABLE IF NOT EXISTS search_graph(session_file TEXT NOT NULL,generation INTEGER NOT NULL,record INTEGER NOT NULL,entry_id TEXT NOT NULL,parent_id TEXT NOT NULL,eligible INTEGER NOT NULL,PRIMARY KEY(session_file,generation,entry_id));" ++
        "CREATE TABLE IF NOT EXISTS search_stage(rowid INTEGER PRIMARY KEY,session_file TEXT NOT NULL,generation INTEGER NOT NULL,record INTEGER NOT NULL,block INTEGER NOT NULL,part INTEGER NOT NULL,text TEXT NOT NULL);" ++
        "CREATE INDEX IF NOT EXISTS search_stage_source ON search_stage(session_file,generation,rowid);" ++
        "CREATE INDEX IF NOT EXISTS search_stage_record ON search_stage(session_file,generation,record,block);" ++
        "CREATE TABLE IF NOT EXISTS search_blocks(session_file TEXT NOT NULL,generation INTEGER NOT NULL,record INTEGER NOT NULL,block INTEGER NOT NULL,eligible INTEGER NOT NULL,PRIMARY KEY(session_file,generation,record,block));" ++
        "CREATE TABLE IF NOT EXISTS search_branch(session_file TEXT NOT NULL,generation INTEGER NOT NULL,entry_id TEXT NOT NULL,record INTEGER NOT NULL,PRIMARY KEY(session_file,generation,entry_id));" ++
        "CREATE INDEX IF NOT EXISTS search_branch_record ON search_branch(session_file,generation,record);",
    );
    db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(text,tokenize='unicode61 remove_diacritics 2')") catch return error.Fts5Unavailable;
    try db.exec("COMMIT");
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
            const n = @min(bytes.len, capacity - self.length);
            @memcpy(self.bytes[self.length..][0..n], bytes[0..n]);
            self.length += n;
            self.overflow = self.overflow or n != bytes.len;
        }
        fn value(self: *const @This()) []const u8 {
            return self.bytes[0..self.length];
        }
        fn set(self: *@This(), bytes: []const u8) void {
            self.reset();
            self.append(bytes);
        }
    };
}

const Key = enum { other, type, id, parentId, message, role, content, text, stopReason, errorMessage };
const Context = enum { root, message, content, block, ignored };
const Frame = struct { context: Context, object: bool, key: Key = .other, wants_key: bool = true };

/// The catalog Record scanner pattern, extended with disk-backed text tokens.
/// Metadata is bounded; no content string, message, or session is accumulated.
const Record = struct {
    scanner: std.json.Scanner,
    frames: [128]Frame = undefined,
    depth: usize = 0,
    valid: bool = true,
    complete: bool = false,
    has_bytes: bool = false,
    token: Bounded(4096) = .{},
    id: Bounded(4096) = .{},
    parent: Bounded(4096) = .{},
    kind: Bounded(64) = .{},
    role: Bounded(64) = .{},
    block_type: Bounded(64) = .{},
    stop_reason: Bounded(64) = .{},
    has_error: bool = false,
    has_tool_call: bool = false,
    block: i64 = 0,
    next_block: i64 = 1,
    part: i64 = 0,
    text: Bounded(chunk_size) = .{},
    // Retained seam bytes are not emitted again unless new text follows them.
    seam: usize = 0,

    fn reset(self: *Record) void {
        self.scanner = std.json.Scanner.initStreaming(allocator);
        self.depth = 0;
        self.valid = true;
        self.complete = false;
        self.has_bytes = false;
        self.block = 0;
        self.next_block = 1;
        self.part = 0;
        self.seam = 0;
        self.has_error = false;
        self.has_tool_call = false;
        inline for (.{ "token", "id", "parent", "kind", "role", "block_type", "stop_reason", "text" }) |name| @field(self, name).reset();
    }

    fn feed(self: *Record, indexer: *Indexer, bytes: []const u8) !void {
        self.has_bytes = self.has_bytes or bytes.len > 0;
        if (!self.valid) return;
        self.scanner.feedInput(bytes);
        try self.drain(indexer);
    }

    fn finish(self: *Record, indexer: *Indexer) !void {
        if (!self.has_bytes) return;
        if (self.valid) {
            self.scanner.endInput();
            try self.drain(indexer);
        }
        if (!self.valid or !self.complete or self.id.overflow or self.parent.overflow or self.kind.overflow or self.role.overflow) {
            indexer.warn(error.IncompleteSource);
            return;
        }
        if (std.mem.eql(u8, self.kind.value(), "session")) return;
        if (self.id.length == 0) {
            indexer.warn(error.MissingEntryId);
            return;
        }
        const stmt = try indexer.statement("INSERT OR IGNORE INTO search_graph(session_file,generation,record,entry_id,parent_id,eligible) VALUES(?1,?2,?3,?4,?5,?6)");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindInt(stmt, 3, indexer.record_number);
        try sql.bindText(stmt, 4, self.id.value());
        try sql.bindText(stmt, 5, self.parent.value());
        const final_assistant = std.mem.eql(u8, self.role.value(), "assistant") and
            !self.has_tool_call and !self.has_error and !self.stop_reason.overflow and
            (self.stop_reason.length == 0 or std.mem.eql(u8, self.stop_reason.value(), "stop") or std.mem.eql(u8, self.stop_reason.value(), "length"));
        const eligible = std.mem.eql(u8, self.kind.value(), "message") and
            (std.mem.eql(u8, self.role.value(), "user") or final_assistant);
        try sql.bindInt(stmt, 6, @intFromBool(eligible));
        // Duplicate graph IDs are ambiguous: never publish a guessed branch.
        try sql.done(stmt);
        if (c.sqlite3_changes(indexer.db.handle) == 0) {
            indexer.warn(error.DuplicateEntryId);
            indexer.graph_invalid = true;
            return;
        }
        indexer.leaf.set(self.id.value());
    }

    fn isText(self: *const Record) bool {
        if (self.depth == 0) return false;
        const frame = self.frames[self.depth - 1];
        if (frame.object and frame.wants_key) return false;
        return (frame.context == .message and frame.key == .content) or
            (frame.context == .block and frame.key == .text);
    }

    fn capture(self: *Record, indexer: *Indexer, bytes: []const u8) !void {
        if (self.isText()) {
            var remaining = bytes;
            while (remaining.len > 0) {
                const count = @min(remaining.len, chunk_size - self.text.length);
                self.text.append(remaining[0..count]);
                remaining = remaining[count..];
                if (self.text.length == chunk_size) try self.flush(indexer, false);
            }
        } else if (self.depth > 0) {
            const f = self.frames[self.depth - 1];
            if ((f.object and f.wants_key) or (f.context == .root and (f.key == .type or f.key == .id or f.key == .parentId)) or
                (f.context == .message and (f.key == .role or f.key == .stopReason or f.key == .errorMessage)) or (f.context == .block and f.key == .type)) self.token.append(bytes);
        }
    }

    fn flush(self: *Record, indexer: *Indexer, final: bool) !void {
        if (self.text.length <= self.seam) {
            if (final) {
                self.text.reset();
                self.seam = 0;
            }
            return;
        }
        var end = self.text.length;
        // Scanner tokens may be split inside a codepoint; only stage complete UTF-8.
        while (end > 0 and !std.unicode.utf8ValidateSlice(self.text.bytes[0..end])) : (end -= 1) {}
        if (end == 0) return error.InvalidUtf8;
        if (!final) {
            // Prefer a token boundary near the seam, retaining enough overlap
            // for every permitted 256-byte query (including Unicode queries).
            var boundary = end;
            while (boundary > end -| overlap) : (boundary -= 1) {
                if (std.ascii.isWhitespace(self.text.bytes[boundary - 1])) {
                    end = boundary;
                    break;
                }
            }
        }
        const stmt = try indexer.statement("INSERT INTO search_stage(session_file,generation,record,block,part,text) VALUES(?1,?2,?3,?4,?5,?6)");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindInt(stmt, 3, indexer.record_number);
        try sql.bindInt(stmt, 4, self.block);
        try sql.bindInt(stmt, 5, self.part);
        try sql.bindText(stmt, 6, self.text.bytes[0..end]);
        try sql.done(stmt);
        self.part += 1;
        if (final) {
            self.text.reset();
            self.seam = 0;
        } else {
            var start = end -| overlap;
            while (start > 0 and self.text.bytes[start] & 0xc0 == 0x80) : (start -= 1) {}
            const retained = self.text.length - start;
            std.mem.copyForwards(u8, self.text.bytes[0..retained], self.text.bytes[start..self.text.length]);
            self.text.length = retained;
            self.seam = end - start;
        }
    }

    fn blockEnd(self: *Record, indexer: *Indexer) !void {
        if (std.mem.eql(u8, self.block_type.value(), "toolCall")) self.has_tool_call = true;
        const stmt = try indexer.statement("INSERT INTO search_blocks(session_file,generation,record,block,eligible) VALUES(?1,?2,?3,?4,?5)");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindInt(stmt, 3, indexer.record_number);
        try sql.bindInt(stmt, 4, self.block);
        try sql.bindInt(stmt, 5, @intFromBool(std.mem.eql(u8, self.block_type.value(), "text") and !self.block_type.overflow));
        try sql.done(stmt);
        self.block = 0;
    }

    fn string(self: *Record, indexer: *Indexer) !void {
        if (self.depth == 0) return;
        const frame = &self.frames[self.depth - 1];
        if (frame.object and frame.wants_key) {
            frame.key = .other;
            if (!self.token.overflow) {
                inline for (std.meta.fields(Key)) |field| {
                    if (std.mem.eql(u8, self.token.value(), field.name)) frame.key = @enumFromInt(field.value);
                }
            }
            frame.wants_key = false;
        } else {
            if (self.isText()) try self.flush(indexer, true) else switch (frame.context) {
                .root => switch (frame.key) {
                    .id => self.id.set(self.token.value()),
                    .parentId => self.parent.set(self.token.value()),
                    .type => self.kind.set(self.token.value()),
                    else => {},
                },
                .message => switch (frame.key) {
                    .role => self.role.set(self.token.value()),
                    .stopReason => self.stop_reason.set(self.token.value()),
                    .errorMessage => self.has_error = self.token.length > 0 or self.token.overflow,
                    else => {},
                },
                .block => if (frame.key == .type) self.block_type.set(self.token.value()),
                else => {},
            }
            if (self.token.overflow) switch (frame.context) {
                .root => switch (frame.key) {
                    .id => self.id.overflow = true,
                    .parentId => self.parent.overflow = true,
                    .type => self.kind.overflow = true,
                    else => {},
                },
                .message => switch (frame.key) {
                    .role => self.role.overflow = true,
                    .stopReason => self.stop_reason.overflow = true,
                    .errorMessage => self.has_error = true,
                    else => {},
                },
                .block => if (frame.key == .type) { self.block_type.overflow = true; },
                else => {},
            };
            frame.wants_key = true;
        }
        self.token.reset();
    }

    fn drain(self: *Record, indexer: *Indexer) !void {
        while (true) {
            const token = self.scanner.next() catch |err| {
                if (err == error.BufferUnderrun) return;
                if (err == error.OutOfMemory) return err;
                self.valid = false;
                return;
            };
            switch (token) {
                .partial_string => |bytes| try self.capture(indexer, bytes),
                .partial_string_escaped_1 => |bytes| try self.capture(indexer, &bytes),
                .partial_string_escaped_2 => |bytes| try self.capture(indexer, &bytes),
                .partial_string_escaped_3 => |bytes| try self.capture(indexer, &bytes),
                .partial_string_escaped_4 => |bytes| try self.capture(indexer, &bytes),
                .string => |bytes| {
                    try self.capture(indexer, bytes);
                    try self.string(indexer);
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
                            self.block = self.next_block;
                            self.next_block += 1;
                            self.block_type.reset();
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
                    if (self.frames[self.depth].context == .block) try self.blockEnd(indexer);
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
};

const Phase = enum { idle, scan, branch, copy, publish, reclaim };

pub const Indexer = struct {
    io: std.Io,
    db: *sql.Db,
    record: *Record,
    path: ?[]u8 = null,
    file: ?std.Io.File = null,
    stat: std.Io.File.Stat = undefined,
    generation: i64 = 0,
    offset: u64 = 0,
    record_number: i64 = 0,
    copy_cursor: i64 = 0,
    phase: Phase = .idle,
    leaf: Bounded(4096) = .{},
    authoritative_leaf: Bounded(4096) = .{},
    authority_without_fingerprint: bool = false,
    cursor: Bounded(4096) = .{},
    warning: ?anyerror = null,
    incomplete: bool = false,
    graph_invalid: bool = false,
    reclaim_table: usize = 0,
    identity: [64]u8 = undefined,
    identity_length: usize = 0,
    mtime: [64]u8 = undefined,
    mtime_length: usize = 0,

    pub fn init(io: std.Io, db: *sql.Db) !Indexer {
        const record = try allocator.create(Record);
        record.reset();
        return .{ .io = io, .db = db, .record = record };
    }

    pub fn deinit(self: *Indexer) void {
        if (self.file) |file| file.close(self.io);
        if (self.path) |path| allocator.free(path);
        self.record.scanner.deinit();
        allocator.destroy(self.record);
        self.* = undefined;
    }

    fn warn(self: *Indexer, err: anyerror) void {
        self.warning = err;
        self.incomplete = true;
    }

    fn statement(self: *Indexer, query: [*:0]const u8) !*c.sqlite3_stmt {
        const stmt = try self.db.prepare(query);
        errdefer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, self.path.?);
        try sql.bindInt(stmt, 2, self.generation);
        return stmt;
    }

    fn sourceState(self: *Indexer, available: bool) !void {
        const stmt = try self.db.prepare("INSERT INTO search_sources(session_file,available,incomplete) VALUES(?1,?2,?3) ON CONFLICT(session_file) DO UPDATE SET available=excluded.available,incomplete=excluded.incomplete");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, self.path.?);
        try sql.bindInt(stmt, 2, @intFromBool(available));
        try sql.bindInt(stmt, 3, @intFromBool(self.incomplete));
        try sql.done(stmt);
    }

    const Authority = struct { leaf: Bounded(4096) = .{}, unfingerprinted: bool = false };

    fn authority(self: *Indexer) !Authority {
        const stmt = try self.db.prepare("SELECT leaf_id,file_identity FROM sessions WHERE session_file=?1 AND (file_identity='' OR (file_identity=?2 AND file_size=?3 AND file_mtime=?4))");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, self.path.?);
        try sql.bindText(stmt, 2, self.identity[0..self.identity_length]);
        try sql.bindInt(stmt, 3, @intCast(self.stat.size));
        try sql.bindInt(stmt, 4, self.stat.mtime.toMilliseconds());
        var result: Authority = .{};
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) {
            result.leaf.set(sql.column(stmt, 0));
            result.unfingerprinted = sql.column(stmt, 1).len == 0;
        } else if (rc != c.SQLITE_DONE) return error.SqliteFailure;
        if (result.leaf.overflow) return error.InvalidSource;
        return result;
    }

    /// False means unchanged or unavailable; warning distinguishes unavailable.
    /// An active scan must be stepped to completion before starting another.
    pub fn start(self: *Indexer, path: []const u8) !bool {
        if (self.phase != .idle) return error.IndexerBusy;
        const owned = try allocator.dupe(u8, path);
        if (self.path) |old| allocator.free(old);
        self.path = owned;
        self.warning = null;
        self.incomplete = false;
        self.graph_invalid = false;
        self.authoritative_leaf.reset();
        self.authority_without_fingerprint = false;
        self.leaf.reset();
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| {
            self.warn(err);
            try self.sourceState(false);
            return false;
        };
        errdefer file.close(self.io);
        const stat = file.stat(self.io) catch |err| {
            self.warn(err);
            try self.sourceState(false);
            file.close(self.io);
            return false;
        };
        if (stat.kind != .file or stat.size > std.math.maxInt(i64)) return error.InvalidSource;
        self.stat = stat;
        self.identity_length = (try std.fmt.bufPrint(&self.identity, "{d}", .{stat.inode})).len;
        self.mtime_length = (try std.fmt.bufPrint(&self.mtime, "{d}", .{stat.mtime.toNanoseconds()})).len;
        const selected = try self.authority();
        self.authoritative_leaf = selected.leaf;
        self.authority_without_fingerprint = selected.unfingerprinted;
        const current = try self.db.prepare("SELECT generation,size,mtime,identity,leaf,incomplete FROM search_sources WHERE session_file=?1");
        defer _ = c.sqlite3_finalize(current);
        try sql.bindText(current, 1, path);
        const rc = c.sqlite3_step(current);
        if (rc == c.SQLITE_ROW) {
            const same_fingerprint = c.sqlite3_column_int64(current, 0) > 0 and c.sqlite3_column_int64(current, 1) == stat.size and
                std.mem.eql(u8, sql.column(current, 2), self.mtime[0..self.mtime_length]) and
                std.mem.eql(u8, sql.column(current, 3), self.identity[0..self.identity_length]);
            if (same_fingerprint and self.authority_without_fingerprint and self.authoritative_leaf.length > 0) {
                const exists = try self.db.prepare("SELECT 1 FROM search_graph WHERE session_file=?1 AND generation=?2 AND entry_id=?3");
                defer _ = c.sqlite3_finalize(exists);
                try sql.bindText(exists, 1, path);
                try sql.bindInt(exists, 2, c.sqlite3_column_int64(current, 0));
                try sql.bindText(exists, 3, self.authoritative_leaf.value());
                const exists_rc = c.sqlite3_step(exists);
                if (exists_rc == c.SQLITE_DONE) {
                    // A live leaf can precede source persistence. Keep cached
                    // results explicitly stale instead of claiming freshness.
                    self.warn(error.SourceChanged);
                    try self.sourceState(true);
                    file.close(self.io);
                    return false;
                } else if (exists_rc != c.SQLITE_ROW) return error.SqliteFailure;
            }
            var expected = self.authoritative_leaf;
            if (same_fingerprint and expected.length == 0) {
                const persisted = try self.db.prepare("SELECT entry_id FROM search_graph WHERE session_file=?1 AND generation=?2 ORDER BY record DESC LIMIT 1");
                defer _ = c.sqlite3_finalize(persisted);
                try sql.bindText(persisted, 1, path);
                try sql.bindInt(persisted, 2, c.sqlite3_column_int64(current, 0));
                const persisted_rc = c.sqlite3_step(persisted);
                if (persisted_rc == c.SQLITE_ROW) expected.set(sql.column(persisted, 0)) else if (persisted_rc != c.SQLITE_DONE) return error.SqliteFailure;
            }
            const unchanged = same_fingerprint and std.mem.eql(u8, expected.value(), sql.column(current, 4));
            if (unchanged) {
                if (c.sqlite3_column_int(current, 5) != 0) self.warn(error.IncompleteSource);
                try self.sourceState(true);
                file.close(self.io);
                return false;
            }
        } else if (rc != c.SQLITE_DONE) return error.SqliteFailure;
        const next = try self.db.prepare("SELECT MAX(generation) FROM (SELECT generation FROM search_sources WHERE session_file=?1 UNION ALL SELECT MAX(generation) FROM search_graph WHERE session_file=?1 UNION ALL SELECT MAX(generation) FROM search_stage WHERE session_file=?1 UNION ALL SELECT MAX(generation) FROM search_segments WHERE session_file=?1)");
        defer _ = c.sqlite3_finalize(next);
        try sql.bindText(next, 1, path);
        if (c.sqlite3_step(next) != c.SQLITE_ROW) return error.SqliteFailure;
        self.generation = try std.math.add(i64, c.sqlite3_column_int64(next, 0), 1);
        self.record.scanner.deinit();
        self.record.reset();
        self.record_number = 0;
        self.offset = 0;
        self.copy_cursor = 0;
        self.reclaim_table = 0;
        try self.sourceState(true);
        self.file = file;
        self.phase = .scan;
        return true;
    }

    fn stable(self: *Indexer) !bool {
        const file = std.Io.Dir.cwd().openFile(self.io, self.path.?, .{}) catch |err| {
            self.warn(err);
            try self.sourceState(false);
            return false;
        };
        defer file.close(self.io);
        const stat = file.stat(self.io) catch |err| {
            self.warn(err);
            try self.sourceState(false);
            return false;
        };
        if (stat.inode != self.stat.inode or stat.size != self.stat.size or
            stat.mtime.toNanoseconds() != self.stat.mtime.toNanoseconds()) {
            self.warn(error.SourceChanged);
            try self.sourceState(true);
            return false;
        }
        return true;
    }

    /// Each invocation reads at most 64 KiB and commits its own bounded work.
    /// Branch traversal, segment publication staging, and reclamation also yield.
    pub fn step(self: *Indexer) !bool {
        if (self.phase == .idle) return true;
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer {
            self.db.exec("ROLLBACK") catch {};
            self.warn(error.IncompleteSource);
            if (self.file) |file| file.close(self.io);
            self.file = null;
            self.phase = .reclaim;
            self.reclaim_table = 0;
        }
        switch (self.phase) {
            .scan => try self.scan(),
            .branch => try self.branch(),
            .copy => try self.copy(),
            .publish => try self.publish(),
            .reclaim => try self.reclaim(),
            .idle => unreachable,
        }
        try self.db.exec("COMMIT");
        return self.phase == .idle;
    }

    fn scan(self: *Indexer) !void {
        if (self.offset < self.stat.size) {
            var buffer: [chunk_size]u8 = undefined;
            const count = self.file.?.readPositional(self.io, &.{buffer[0..@min(chunk_size, self.stat.size - self.offset)]}, self.offset) catch |err| {
                self.warn(err);
                try self.sourceState(false);
                self.file.?.close(self.io);
                self.file = null;
                self.phase = .reclaim;
                return;
            };
            if (count == 0) {
                self.warn(error.SourceChanged);
                self.file.?.close(self.io);
                self.file = null;
                try self.sourceState(true);
                self.phase = .reclaim;
                return;
            }
            self.offset += count;
            var start_offset: usize = 0;
            for (buffer[0..count], 0..) |byte, index| {
                if (byte != '\n') continue;
                try self.record.feed(self, buffer[start_offset..index]);
                try self.record.finish(self);
                self.record.scanner.deinit();
                self.record.reset();
                self.record_number += 1;
                start_offset = index + 1;
            }
            try self.record.feed(self, buffer[start_offset..count]);
            return;
        }
        try self.record.finish(self);
        self.file.?.close(self.io);
        self.file = null;
        if (!try self.stable()) {
            self.phase = .reclaim;
            return;
        }
        if (self.graph_invalid) {
            try self.sourceState(true);
            self.phase = .reclaim;
            return;
        }
        if (self.authoritative_leaf.length > 0) {
            var use_authority = true;
            if (self.authority_without_fingerprint) {
                const exists = try self.statement("SELECT 1 FROM search_graph WHERE session_file=?1 AND generation=?2 AND entry_id=?3");
                defer _ = c.sqlite3_finalize(exists);
                try sql.bindText(exists, 3, self.authoritative_leaf.value());
                const rc = c.sqlite3_step(exists);
                if (rc == c.SQLITE_DONE) use_authority = false else if (rc != c.SQLITE_ROW) return error.SqliteFailure;
            }
            if (use_authority) self.leaf.set(self.authoritative_leaf.value());
        }
        self.cursor.set(self.leaf.value());
        self.phase = .branch;
    }

    fn branch(self: *Indexer) !void {
        var count: usize = 0;
        while (self.cursor.length > 0 and count < 128) : (count += 1) {
            const visited = try self.statement("SELECT 1 FROM search_branch WHERE session_file=?1 AND generation=?2 AND entry_id=?3");
            defer _ = c.sqlite3_finalize(visited);
            try sql.bindText(visited, 3, self.cursor.value());
            const visited_rc = c.sqlite3_step(visited);
            if (visited_rc == c.SQLITE_ROW) {
                self.warn(error.ParentCycle);
                try self.sourceState(true);
                self.phase = .reclaim;
                return;
            }
            if (visited_rc != c.SQLITE_DONE) return error.SqliteFailure;
            const entry = try self.statement("SELECT record,parent_id FROM search_graph WHERE session_file=?1 AND generation=?2 AND entry_id=?3");
            defer _ = c.sqlite3_finalize(entry);
            try sql.bindText(entry, 3, self.cursor.value());
            const rc = c.sqlite3_step(entry);
            if (rc == c.SQLITE_DONE) {
                self.warn(error.MissingParent);
                try self.sourceState(true);
                self.phase = .reclaim;
                return;
            }
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;
            const insert = try self.statement("INSERT INTO search_branch(session_file,generation,entry_id,record) VALUES(?1,?2,?3,?4)");
            defer _ = c.sqlite3_finalize(insert);
            try sql.bindText(insert, 3, self.cursor.value());
            try sql.bindInt(insert, 4, c.sqlite3_column_int64(entry, 0));
            try sql.done(insert);
            self.cursor.set(sql.column(entry, 1));
        }
        if (self.cursor.length == 0) self.phase = .copy;
    }

    fn copy(self: *Indexer) !void {
        // A single chunk per step bounds FTS tokenization and content copying.
        const stmt = try self.statement("SELECT s.rowid,g.entry_id,s.text,(g.eligible=1 AND (s.block=0 OR b.eligible=1)) FROM search_stage s LEFT JOIN search_branch p ON p.session_file=s.session_file AND p.generation=s.generation AND p.record=s.record LEFT JOIN search_graph g ON g.session_file=p.session_file AND g.generation=p.generation AND g.entry_id=p.entry_id LEFT JOIN search_blocks b ON b.session_file=s.session_file AND b.generation=s.generation AND b.record=s.record AND b.block=s.block WHERE s.session_file=?1 AND s.generation=?2 AND s.rowid>?3 ORDER BY s.rowid LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindInt(stmt, 3, self.copy_cursor);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) {
            self.phase = .publish;
            return;
        }
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        self.copy_cursor = c.sqlite3_column_int64(stmt, 0);
        if (c.sqlite3_column_int(stmt, 3) != 1) return;
        const insert = try self.statement("INSERT INTO search_segments(session_file,generation,entry_id,field,text) VALUES(?1,?2,?3,2,?4)");
        defer _ = c.sqlite3_finalize(insert);
        try sql.bindText(insert, 3, sql.column(stmt, 1));
        try sql.bindText(insert, 4, sql.column(stmt, 2));
        try sql.done(insert);
        const fts = try self.db.prepare("INSERT INTO search_fts(rowid,text) VALUES(?1,?2)");
        defer _ = c.sqlite3_finalize(fts);
        try sql.bindInt(fts, 1, c.sqlite3_last_insert_rowid(self.db.handle));
        try sql.bindText(fts, 2, sql.column(stmt, 2));
        try sql.done(fts);
    }

    fn publish(self: *Indexer) !void {
        // Recheck after potentially long branch/FTS staging, not only after read.
        if (try self.stable()) {
            const selected = try self.authority();
            if (!std.mem.eql(u8, selected.leaf.value(), self.authoritative_leaf.value())) {
                self.warn(error.SourceChanged);
                try self.sourceState(true);
                self.phase = .reclaim;
                return;
            }
            const stmt = try self.statement("INSERT INTO search_sources(session_file,generation,size,mtime,identity,leaf,available,incomplete) VALUES(?1,?2,?3,?4,?5,?6,1,?7) ON CONFLICT(session_file) DO UPDATE SET generation=excluded.generation,size=excluded.size,mtime=excluded.mtime,identity=excluded.identity,leaf=excluded.leaf,available=1,incomplete=excluded.incomplete");
            defer _ = c.sqlite3_finalize(stmt);
            try sql.bindInt(stmt, 3, @intCast(self.stat.size));
            try sql.bindText(stmt, 4, self.mtime[0..self.mtime_length]);
            try sql.bindText(stmt, 5, self.identity[0..self.identity_length]);
            try sql.bindText(stmt, 6, self.leaf.value());
            try sql.bindInt(stmt, 7, @intFromBool(self.incomplete));
            try sql.done(stmt);
        }
        self.phase = .reclaim;
    }

    fn reclaim(self: *Indexer) !void {
        // Fixed row batches; old content is never deleted until the generation
        // pointer commits. Interrupted generations are reclaimed on the next run.
        const queries = [_][*:0]const u8{
            "DELETE FROM search_fts WHERE rowid IN (SELECT rowid FROM search_segments WHERE session_file=?1 AND generation<>0 AND generation<>COALESCE((SELECT generation FROM search_sources WHERE session_file=?1),0) LIMIT 16)",
            "DELETE FROM search_segments WHERE rowid IN (SELECT rowid FROM search_segments WHERE session_file=?1 AND generation<>0 AND generation<>COALESCE((SELECT generation FROM search_sources WHERE session_file=?1),0) LIMIT 16)",
            "DELETE FROM search_stage WHERE rowid IN (SELECT rowid FROM search_stage WHERE session_file=?1 LIMIT 16)",
            "DELETE FROM search_graph WHERE rowid IN (SELECT rowid FROM search_graph WHERE session_file=?1 AND generation<>COALESCE((SELECT generation FROM search_sources WHERE session_file=?1),0) LIMIT 128)",
            "DELETE FROM search_blocks WHERE rowid IN (SELECT rowid FROM search_blocks WHERE session_file=?1 LIMIT 128)",
            "DELETE FROM search_branch WHERE rowid IN (SELECT rowid FROM search_branch WHERE session_file=?1 AND generation<>COALESCE((SELECT generation FROM search_sources WHERE session_file=?1),0) LIMIT 128)",
        };
        // FTS and segments must advance together; otherwise an already deleted
        // FTS batch would repeatedly select the same undeleted segment row IDs.
        if (self.reclaim_table == 0) {
            for (queries[0..2]) |query| {
                const stmt = try self.db.prepare(query);
                defer _ = c.sqlite3_finalize(stmt);
                try sql.bindText(stmt, 1, self.path.?);
                try sql.done(stmt);
            }
            if (c.sqlite3_changes(self.db.handle) == 0) self.reclaim_table = 2;
            return;
        }
        const stmt = try self.db.prepare(queries[self.reclaim_table]);
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, self.path.?);
        try sql.done(stmt);
        if (c.sqlite3_changes(self.db.handle) == 0) self.reclaim_table += 1;
        if (self.reclaim_table == queries.len) self.phase = .idle;
    }
};

fn testDatabase() !sql.Db {
    var db = try sql.Db.init(":memory:");
    errdefer db.deinit();
    try db.exec("CREATE TABLE sessions(session_file TEXT PRIMARY KEY,leaf_id TEXT,file_identity TEXT,file_size INTEGER,file_mtime INTEGER)");
    try init(&db);
    return db;
}

fn testRun(indexer: *Indexer, path: []const u8) !void {
    try std.testing.expect(try indexer.start(path));
    while (!try indexer.step()) {}
}

fn testScalar(db: *sql.Db, query: [*:0]const u8) !i64 {
    const stmt = try db.prepare(query);
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteFailure;
    return c.sqlite3_column_int64(stmt, 0);
}

fn testMatches(db: *sql.Db, text: []const u8) !i64 {
    const stmt = try db.prepare("SELECT COUNT(DISTINCT s.entry_id) FROM search_fts JOIN search_segments s ON s.rowid=search_fts.rowid JOIN search_sources p ON p.session_file=s.session_file AND p.generation=s.generation WHERE search_fts MATCH ?1");
    defer _ = c.sqlite3_finalize(stmt);
    try sql.bindText(stmt, 1, text);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteFailure;
    return c.sqlite3_column_int64(stmt, 0);
}

test "canonical search traverses every entry kind and classifies out of order content" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data =
        "{\"type\":\"session\",\"id\":\"header\"}\n" ++
        "{\"id\":\"root\",\"parentId\":null,\"message\":{\"content\":[{\"text\":\"visibleprompt\",\"type\":\"text\"},{\"text\":\"hiddenreasoning\",\"type\":\"thinking\"},{\"text\":\"hiddenimage\",\"type\":\"image\"},{\"text\":\"hiddentool\",\"type\":\"toolCall\"}],\"role\":\"user\"},\"type\":\"message\"}\n" ++
        "{\"id\":\"discarded\",\"parentId\":\"root\",\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":\"abandonedbranch\"}}\n" ++
        "{\"id\":\"bridge\",\"parentId\":\"root\",\"type\":\"model_change\"}\n" ++
        "{\"id\":\"tool\",\"parentId\":\"bridge\",\"type\":\"message\",\"message\":{\"content\":\"tooloutput\",\"role\":\"toolResult\"}}\n" ++
        "{\"message\":{\"content\":\"visibleanswer\",\"role\":\"assistant\"},\"parentId\":\"tool\",\"id\":\"leaf\",\"type\":\"message\"}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.jsonl" });
    defer allocator.free(path);
    var db = try testDatabase();
    defer db.deinit();
    var indexer = try Indexer.init(io, &db);
    defer indexer.deinit();
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(?anyerror, null), indexer.warning);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "visibleprompt"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "visibleanswer"));
    inline for (.{ "hiddenreasoning", "hiddenimage", "hiddentool", "abandonedbranch", "tooloutput" }) |word| {
        try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, word));
    }
    try std.testing.expectEqual(@as(i64, 4), try testScalar(&db, "SELECT COUNT(*) FROM search_branch"));
    try std.testing.expect(!try indexer.start(path));
}

test "large Unicode text keeps boundary phrases late text and FTS snippets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const prefix = "{\"id\":\"large\",\"type\":\"message\",\"message\":{\"content\":[{\"text\":\"";
    try tmp.dir.writeFile(io, .{ .sub_path = "large.jsonl", .data = prefix });
    const file = try tmp.dir.openFile(io, "large.jsonl", .{ .mode = .read_write });
    defer file.close(io);
    var offset: u64 = prefix.len;
    var block: [4096]u8 = undefined;
    for (0..1024) |i| @memcpy(block[i * 4 ..][0..4], "猫 ");
    for (0..15) |_| {
        try file.writePositionalAll(io, &block, offset);
        offset += block.len;
    }
    // This phrase straddles the 64 KiB decoded text seam and must match whole.
    var padding: [4086]u8 = undefined;
    @memset(&padding, ' ');
    try file.writePositionalAll(io, &padding, offset);
    offset += padding.len;
    const boundary = "boundaryneedle résumé ";
    try file.writePositionalAll(io, boundary, offset);
    offset += boundary.len;
    for (0..5) |_| {
        try file.writePositionalAll(io, &block, offset);
        offset += block.len;
    }
    try file.writePositionalAll(io, " tailneedle \\u732b\",\"type\":\"text\"}],\"role\":\"assistant\"}}\n", offset);
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "large.jsonl" });
    defer allocator.free(path);
    var db = try testDatabase();
    defer db.deinit();
    var indexer = try Indexer.init(io, &db);
    defer indexer.deinit();
    try std.testing.expect(try indexer.start(path));
    while (indexer.phase == .scan) {
        const before = indexer.offset;
        _ = try indexer.step();
        try std.testing.expect(indexer.offset - before <= chunk_size);
    }
    while (!try indexer.step()) {}
    try std.testing.expectEqual(@as(?anyerror, null), indexer.warning);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "\"boundaryneedle resume\""));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "tailneedle"));
    const rows = try db.prepare("SELECT text FROM search_segments");
    defer _ = c.sqlite3_finalize(rows);
    while (true) {
        const rc = c.sqlite3_step(rows);
        if (rc == c.SQLITE_DONE) break;
        try std.testing.expectEqual(c.SQLITE_ROW, rc);
        const text = sql.column(rows, 0);
        try std.testing.expect(text.len <= chunk_size);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    }
    const snippet = try db.prepare("SELECT snippet(search_fts,0,'[',']','...',12) FROM search_fts WHERE search_fts MATCH 'tailneedle'");
    defer _ = c.sqlite3_finalize(snippet);
    try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(snippet));
    try std.testing.expect(std.mem.indexOf(u8, sql.column(snippet, 0), "[tailneedle]") != null);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT COUNT(*) FROM search_stage"));
}

test "malformed fragments never reach search and broken graphs retain the published branch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const valid = "{\"id\":\"good\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"retainedword\"}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data = valid ++
        "{\"id\":\"broken\",\"parentId\":\"good\",\"type\":\"message\",\"message\":{\"content\":\"badfragment\",\"role\":\"assistant\"},\"bad\":}\n" ++
        "{\"id\":\"partial\",\"type\":\"message\",\"message\":{\"content\":\"unfinishedfragment" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.jsonl" });
    defer allocator.free(path);
    var db = try testDatabase();
    defer db.deinit();
    var indexer = try Indexer.init(io, &db);
    defer indexer.deinit();
    try testRun(&indexer, path);
    try std.testing.expect(indexer.warning != null);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "retainedword"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "badfragment OR unfinishedfragment"));
    const published = try testScalar(&db, "SELECT generation FROM search_sources");
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data = valid ++
        "{\"id\":\"missing\",\"parentId\":\"absent\",\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":\"missingparentword\"}}\n" });
    try testRun(&indexer, path);
    try std.testing.expectEqual(error.MissingParent, indexer.warning.?);
    try std.testing.expectEqual(published, try testScalar(&db, "SELECT generation FROM search_sources"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "missingparentword"));
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data =
        "{\"id\":\"a\",\"parentId\":\"b\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"cycleword\"}}\n" ++
        "{\"id\":\"b\",\"parentId\":\"a\",\"type\":\"model_change\"}\n" });
    try testRun(&indexer, path);
    try std.testing.expectEqual(error.ParentCycle, indexer.warning.?);
    try std.testing.expectEqual(published, try testScalar(&db, "SELECT generation FROM search_sources"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "retainedword"));
    try tmp.dir.deleteFile(io, "source.jsonl");
    try std.testing.expect(!try indexer.start(path));
    try std.testing.expect(indexer.warning != null);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(&db, "SELECT available FROM search_sources"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "retainedword"));
}

test "fingerprinted and runtime leaves select canonical branches without stale rewrite authority" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data =
        "{\"id\":\"selected\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"selectedword\"}}\n" ++
        "{\"id\":\"last\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"lastword\"}}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.jsonl" });
    defer allocator.free(path);
    const file = try tmp.dir.openFile(io, "source.jsonl", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var identity: [64]u8 = undefined;
    const identity_text = try std.fmt.bufPrint(&identity, "{d}", .{stat.inode});
    var db = try testDatabase();
    defer db.deinit();
    const session = try db.prepare("INSERT INTO sessions VALUES(?1,'selected',?2,?3,?4)");
    defer _ = c.sqlite3_finalize(session);
    try sql.bindText(session, 1, path);
    try sql.bindText(session, 2, identity_text);
    try sql.bindInt(session, 3, @intCast(stat.size));
    try sql.bindInt(session, 4, stat.mtime.toMilliseconds());
    try sql.done(session);
    var indexer = try Indexer.init(io, &db);
    defer indexer.deinit();
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "selectedword"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "lastword"));
    try db.exec("UPDATE sessions SET leaf_id='last'");
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "selectedword"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "lastword"));
    try db.exec("UPDATE sessions SET leaf_id='selected',file_size=0");
    try std.testing.expect(!try indexer.start(path));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "lastword"));
    // Runtime selection has no importer fingerprint but is still authoritative
    // when the selected entry exists in the source's complete staged graph.
    try db.exec("UPDATE sessions SET file_identity='',file_mtime=0");
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "selectedword"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "lastword"));
    // An external rewrite may invalidate an un-fingerprinted runtime selection.
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data =
        "{\"id\":\"replacement\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"replacementword\"}}\n" });
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(?anyerror, null), indexer.warning);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "replacementword"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "selectedword"));
    try std.testing.expect(!try indexer.start(path));
}

test "staged generations are invisible and moving sources retain the previous index" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = "{\"id\":\"old\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"oldword\"}}\n";
    const replacement = "{\"id\":\"new\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"newword\"}}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data = old });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.jsonl" });
    defer allocator.free(path);
    var db = try testDatabase();
    defer db.deinit();
    var indexer = try Indexer.init(io, &db);
    defer indexer.deinit();
    try testRun(&indexer, path);
    const generation = try testScalar(&db, "SELECT generation FROM search_sources");
    // Ensure a different fingerprint even on coarse-timestamp filesystems.
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data = replacement ++ "\n" });
    try std.testing.expect(try indexer.start(path));
    while (indexer.phase != .publish) {
        _ = try indexer.step();
        try std.testing.expectEqual(generation, try testScalar(&db, "SELECT generation FROM search_sources"));
        try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "oldword"));
        try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "newword"));
    }
    // A writer modifies the file after all FTS staging, before publication.
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data = replacement ++ "\n\n" });
    while (!try indexer.step()) {}
    try std.testing.expectEqual(error.SourceChanged, indexer.warning.?);
    try std.testing.expectEqual(generation, try testScalar(&db, "SELECT generation FROM search_sources"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "oldword"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "newword"));
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "oldword"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "newword"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT COUNT(*) FROM search_fts"));
}

test "assistant tool preambles errors and aborted turns are not final answers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data =
        "{\"id\":\"u\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"visibleprompt\"}}\n" ++
        "{\"id\":\"p\",\"parentId\":\"u\",\"type\":\"message\",\"message\":{\"content\":[{\"text\":\"hiddenpreamble\",\"type\":\"text\"},{\"type\":\"toolCall\",\"id\":\"call\",\"name\":\"read\",\"arguments\":{}}],\"stopReason\":\"toolUse\",\"role\":\"assistant\"}}\n" ++
        "{\"id\":\"t\",\"parentId\":\"p\",\"type\":\"message\",\"message\":{\"role\":\"toolResult\",\"content\":\"hiddentoolresult\"}}\n" ++
        "{\"id\":\"e\",\"parentId\":\"t\",\"type\":\"message\",\"message\":{\"content\":\"hiddenerror\",\"role\":\"assistant\",\"stopReason\":\"error\"}}\n" ++
        "{\"id\":\"a\",\"parentId\":\"e\",\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"aborted\",\"content\":\"hiddenabort\"}}\n" ++
        "{\"id\":\"legacy\",\"parentId\":\"a\",\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"text\":\"hiddenlegacytool\",\"type\":\"text\"},{\"type\":\"toolCall\",\"id\":\"call2\"}]}}\n" ++
        "{\"id\":\"f\",\"parentId\":\"legacy\",\"type\":\"message\",\"message\":{\"content\":[{\"text\":\"visiblefinalanswer\",\"type\":\"text\"},{\"type\":\"thinking\",\"thinking\":\"hiddenreasoning\"}],\"role\":\"assistant\",\"stopReason\":\"stop\"}}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator); defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.jsonl" }); defer allocator.free(path);
    var db = try testDatabase(); defer db.deinit();
    var indexer = try Indexer.init(io, &db); defer indexer.deinit();
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "visibleprompt"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "visiblefinalanswer"));
    inline for (.{ "hiddenpreamble", "hiddentoolresult", "hiddenerror", "hiddenabort", "hiddenlegacytool", "hiddenreasoning" }) |word| {
        try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, word));
    }
}

test "runtime branch changes during staging cannot publish obsolete selection" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source.jsonl", .data =
        "{\"id\":\"first\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"firstbranchword\"}}\n" ++
        "{\"id\":\"last\",\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\"lastbranchword\"}}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator); defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "source.jsonl" }); defer allocator.free(path);
    var db = try testDatabase(); defer db.deinit();
    const selected = try db.prepare("INSERT INTO sessions VALUES(?1,'first','',0,0)"); defer _ = c.sqlite3_finalize(selected);
    try sql.bindText(selected, 1, path); try sql.done(selected);
    var indexer = try Indexer.init(io, &db); defer indexer.deinit();
    try testRun(&indexer, path);
    const generation = try testScalar(&db, "SELECT generation FROM search_sources");
    try db.exec("UPDATE sessions SET leaf_id='last'");
    try std.testing.expect(try indexer.start(path));
    while (indexer.phase != .publish) _ = try indexer.step();
    try db.exec("UPDATE sessions SET leaf_id='first'");
    while (!try indexer.step()) {}
    try std.testing.expectEqual(error.SourceChanged, indexer.warning.?);
    try std.testing.expectEqual(generation, try testScalar(&db, "SELECT generation FROM search_sources"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "firstbranchword"));
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "lastbranchword"));
    // A not-yet-persisted live leaf keeps the cache, but never marks it current.
    try db.exec("UPDATE sessions SET leaf_id='pending'");
    try std.testing.expect(!try indexer.start(path));
    try std.testing.expectEqual(error.SourceChanged, indexer.warning.?);
    try std.testing.expectEqual(@as(i64, 1), try testScalar(&db, "SELECT incomplete FROM search_sources"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "firstbranchword"));
    // Removing live authority returns to Pi's last valid non-header entry.
    try db.exec("DELETE FROM sessions");
    try testRun(&indexer, path);
    try std.testing.expectEqual(@as(i64, 0), try testMatches(&db, "firstbranchword"));
    try std.testing.expectEqual(@as(i64, 1), try testMatches(&db, "lastbranchword"));
}
