const std = @import("std");

// One C boundary for the derived cache. This connection belongs to the core writer;
// readers open their own read-only connection rather than sharing its statements.
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ContentId = [16]u8;
pub const chunk_size: usize = 64 * 1024;
pub const max_page_rows: u32 = 128;
const max_key: usize = 4096;
const max_label: usize = 2048;

pub const Session = struct {
    session_file: []const u8,
    session_id: []const u8,
    project_id: []const u8,
    display_name: []const u8 = "",
    leaf_id: ?[]const u8 = null,
    last_entry_id: ?[]const u8 = null,
    file_identity: []const u8 = "",
    file_size: i64 = 0,
    file_mtime: i64 = 0,
};

pub const Row = struct {
    row_id: []const u8,
    kind: []const u8,
    role: []const u8,
    revision: i64 = 0,
    title: []const u8 = "",
    status: []const u8 = "",
    content_ref: ?ContentId = null,
    tool_call_id: ?[]const u8 = null,
    is_error: bool = false,
    expanded: bool = false,
    timestamp: i64 = 0,
};

pub const Entry = struct {
    session_file: []const u8,
    entry_id: []const u8,
    parent_id: ?[]const u8 = null,
    append_ordinal: i64,
    entry_type: []const u8,
    raw_content_ref: ?ContentId = null,
    row: Row,
};

pub const ReasoningReference = struct {
    content_ref: ContentId,
    length: u64,
};

pub const LiveRow = struct {
    runtime: u64,
    run_generation: i64,
    local_sequence: i64,
    content_index: i64,
    row: Row,
};

pub const RowPage = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,
    next_cursor: ?i64,
    next_content_index: ?i64,
    pub fn deinit(self: *RowPage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ContentInfo = struct {
    allocator: std.mem.Allocator,
    encoding: []const u8,
    mime_type: []const u8,
    total_length: u64,

    pub fn deinit(self: *ContentInfo) void {
        self.allocator.free(self.encoding);
        self.allocator.free(self.mime_type);
        self.* = undefined;
    }
};

pub const Store = struct {
    db: *c.sqlite3,

    pub fn init(allocator: std.mem.Allocator, database_path: []const u8) !Store {
        if (database_path.len == 0 or database_path.len > max_key or std.mem.indexOfScalar(u8, database_path, 0) != null) return error.InvalidPath;
        const path = try allocator.dupeZ(u8, database_path);
        defer allocator.free(path);
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteFailure;
        }
        var self: Store = .{ .db = handle.? };
        errdefer self.deinit();
        try self.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA cache_size=-256;");
        const version = try self.prepare("PRAGMA user_version");
        const rc_version = c.sqlite3_step(version);
        const number: c_int = if (rc_version == c.SQLITE_ROW) c.sqlite3_column_int(version, 0) else -1;
        _ = c.sqlite3_finalize(version);
        if (number < 0) return error.SqliteFailure;
        if (number != 0 and number != 1 and number != 2 and number != 3) return error.UnsupportedSchema;
        if (number == 0) {
            try self.exec("BEGIN IMMEDIATE");
            errdefer self.exec("ROLLBACK") catch {};
            try self.exec(schema);
            try self.exec("PRAGMA user_version=3");
            try self.exec("COMMIT");
        }
        if (number == 1) {
            try self.exec("BEGIN IMMEDIATE");
            errdefer self.exec("ROLLBACK") catch {};
            try self.exec("ALTER TABLE diagnostics RENAME TO diagnostics_v1; CREATE TABLE diagnostics(diagnostic_id INTEGER PRIMARY KEY,session_file TEXT REFERENCES sessions(session_file) ON DELETE CASCADE,runtime INTEGER NOT NULL,kind TEXT NOT NULL,summary TEXT NOT NULL,raw_content_ref BLOB,timestamp INTEGER NOT NULL); INSERT INTO diagnostics SELECT * FROM diagnostics_v1; DROP TABLE diagnostics_v1; CREATE INDEX diagnostics_session ON diagnostics(session_file,diagnostic_id); PRAGMA user_version=2;");
            try self.exec("COMMIT");
        }
        if (number == 1 or number == 2) {
            try self.exec("BEGIN IMMEDIATE");
            errdefer self.exec("ROLLBACK") catch {};
            try self.exec(reasoning_schema);
            try self.exec("PRAGMA user_version=3");
            try self.exec("COMMIT");
        }
        return self;
    }

    pub fn openReadOnly(allocator: std.mem.Allocator, database_path: []const u8) !Store {
        if (database_path.len == 0 or database_path.len > max_key or std.mem.indexOfScalar(u8, database_path, 0) != null) return error.InvalidPath;
        const path = try allocator.dupeZ(u8, database_path);
        defer allocator.free(path);
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteFailure;
        }
        var self: Store = .{ .db = handle.? };
        errdefer self.deinit();
        try self.exec("PRAGMA query_only=ON; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA cache_size=-256;");
        return self;
    }

    pub fn deinit(self: *Store) void {
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
    }

    // Borrowed until the next SQLite call on this writer connection.
    pub fn lastError(self: *Store) []const u8 {
        return std.mem.span(c.sqlite3_errmsg(self.db));
    }

    pub fn beginContent(self: *Store, id: ContentId, encoding: []const u8, mime_type: []const u8) !void {
        try field(encoding, max_label);
        try field(mime_type, max_label);
        const stmt = try self.prepare("INSERT INTO content_objects(content_id,encoding,mime_type) VALUES(?1,?2,?3)");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        try bindText(stmt, 2, encoding);
        try bindText(stmt, 3, mime_type);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailure;
    }

    // One append call owns no more than a single 64 KiB chunk. The offset is the
    // encoded byte offset; a failed append does not advance it. final seals even
    // a zero-byte object. The transaction keeps metadata and bytes inseparable.
    pub fn append(self: *Store, id: ContentId, offset: u64, bytes: []const u8, final: bool) !void {
        if (bytes.len > chunk_size) return error.ChunkTooLarge;
        if (offset > std.math.maxInt(i64) or @as(u64, @intCast(bytes.len)) > @as(u64, std.math.maxInt(i64)) - offset) return error.LengthOverflow;
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        var current: i64 = 0;
        var next_index: i64 = 0;
        var sealed = false;
        var found = false;
        {
            const stmt = try self.prepare("SELECT total_length,next_index,sealed FROM content_objects WHERE content_id=?1");
            defer _ = c.sqlite3_finalize(stmt);
            try bindId(stmt, 1, id);
            const result = c.sqlite3_step(stmt);
            if (result == c.SQLITE_ROW) {
                found = true;
                current = c.sqlite3_column_int64(stmt, 0);
                next_index = c.sqlite3_column_int64(stmt, 1);
                sealed = c.sqlite3_column_int(stmt, 2) != 0;
            } else if (result != c.SQLITE_DONE) return error.SqliteFailure;
        }
        if (sealed) return error.AlreadySealed;
        if (offset != @as(u64, @intCast(current))) return error.NonContiguous;
        if (!found) {
            const stmt = try self.prepare("INSERT INTO content_objects(content_id,encoding,mime_type) VALUES(?1,'binary','application/octet-stream')");
            defer _ = c.sqlite3_finalize(stmt);
            try bindId(stmt, 1, id);
            try done(stmt);
        }
        if (bytes.len != 0) {
            const stmt = try self.prepare("INSERT INTO content_chunks(content_id,chunk_index,payload) VALUES(?1,?2,?3)");
            defer _ = c.sqlite3_finalize(stmt);
            try bindId(stmt, 1, id);
            try bindInt(stmt, 2, next_index);
            try bindBlob(stmt, 3, bytes);
            try done(stmt);
            next_index += 1;
        }
        {
            const stmt = try self.prepare("UPDATE content_objects SET total_length=?2,next_index=?3,sealed=?4 WHERE content_id=?1");
            defer _ = c.sqlite3_finalize(stmt);
            try bindId(stmt, 1, id);
            try bindInt(stmt, 2, @intCast(offset + @as(u64, @intCast(bytes.len))));
            try bindInt(stmt, 3, next_index);
            try bindInt(stmt, 4, if (final) 1 else 0);
            try done(stmt);
        }
        try self.exec("COMMIT");
    }

    pub fn cancelContent(self: *Store, id: ContentId) !void {
        const stmt = try self.prepare("DELETE FROM content_objects WHERE content_id=?1 AND sealed=0");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        try done(stmt);
    }

    pub fn contentInfo(self: *Store, allocator: std.mem.Allocator, id: ContentId) !ContentInfo {
        const stmt = try self.prepare("SELECT encoding,mime_type,total_length,sealed FROM content_objects WHERE content_id=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.ContentNotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        if (c.sqlite3_column_int(stmt, 3) == 0) return error.UnsealedContent;
        const length = c.sqlite3_column_int64(stmt, 2);
        if (length < 0) return error.CorruptCache;
        const encoding = try columnText(allocator, stmt, 0, max_label);
        errdefer allocator.free(encoding);
        const mime_type = try columnText(allocator, stmt, 1, max_label);
        return .{ .allocator = allocator, .encoding = encoding, .mime_type = mime_type, .total_length = @intCast(length) };
    }

    // Null denotes the end of a sealed object. An unsealed or cancelled object
    // is never exposed as complete, even if some chunks have reached disk.
    pub fn readChunk(self: *Store, allocator: std.mem.Allocator, id: ContentId, index: u64) !?[]u8 {
        if (index > std.math.maxInt(i64)) return error.InvalidChunk;
        var next_index: i64 = 0;
        {
            const stmt = try self.prepare("SELECT sealed,next_index FROM content_objects WHERE content_id=?1");
            defer _ = c.sqlite3_finalize(stmt);
            try bindId(stmt, 1, id);
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) return error.ContentNotFound;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;
            if (c.sqlite3_column_int(stmt, 0) == 0) return error.UnsealedContent;
            next_index = c.sqlite3_column_int64(stmt, 1);
        }
        if (next_index < 0) return error.CorruptCache;
        if (index >= @as(u64, @intCast(next_index))) return null;
        const stmt = try self.prepare("SELECT payload FROM content_chunks WHERE content_id=?1 AND chunk_index=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        try bindInt(stmt, 2, @intCast(index));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.CorruptCache;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        const size: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (size == 0 or size > chunk_size) return error.CorruptCache;
        const ptr = c.sqlite3_column_blob(stmt, 0) orelse return error.CorruptCache;
        const bytes: [*]const u8 = @ptrCast(ptr);
        return try allocator.dupe(u8, bytes[0..size]);
    }

    /// Reads the immutable prefix advertised by a runtime snapshot, including
    /// unsealed live objects. Chunk indices are storage indices (an append may
    /// be shorter than 64 KiB). Returns null exactly at the published watermark.
    pub fn readPublishedChunk(self: *Store, allocator: std.mem.Allocator, id: ContentId, index: u64, published_offset: u64, published_length: u64) !?[]u8 {
        if (index > std.math.maxInt(i64) or published_length > std.math.maxInt(i64)) return error.InvalidChunk;
        if (published_offset >= published_length) return null;
        const stmt = try self.prepare("SELECT payload,(SELECT total_length FROM content_objects WHERE content_id=?1) FROM content_chunks WHERE content_id=?1 AND chunk_index=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        try bindInt(stmt, 2, @intCast(index));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        const total = c.sqlite3_column_int64(stmt, 1);
        if (total < 0 or @as(u64, @intCast(total)) < published_length) return error.UnpublishedContent;
        const stored: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (stored == 0 or stored > chunk_size) return error.CorruptCache;
        const size: usize = @intCast(@min(stored, published_length - published_offset));
        const ptr: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0) orelse return error.CorruptCache);
        return try allocator.dupe(u8, ptr[0..size]);
    }

    pub fn putSession(self: *Store, session: Session) !void {
        try field(session.session_file, max_key);
        try field(session.session_id, max_key);
        try field(session.project_id, max_key);
        try field(session.display_name, max_label);
        try optionalField(session.leaf_id, max_key);
        try optionalField(session.last_entry_id, max_key);
        try field(session.file_identity, max_key);
        const stmt = try self.prepare("INSERT INTO sessions(session_file,session_id,project_id,display_name,leaf_id,last_entry_id,file_identity,file_size,file_mtime) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(session_file) DO UPDATE SET session_id=excluded.session_id,project_id=excluded.project_id,display_name=excluded.display_name,leaf_id=excluded.leaf_id,last_entry_id=excluded.last_entry_id,file_identity=excluded.file_identity,file_size=excluded.file_size,file_mtime=excluded.file_mtime");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session.session_file);
        try bindText(stmt, 2, session.session_id);
        try bindText(stmt, 3, session.project_id);
        try bindText(stmt, 4, session.display_name);
        try bindOptionalText(stmt, 5, session.leaf_id);
        try bindOptionalText(stmt, 6, session.last_entry_id);
        try bindText(stmt, 7, session.file_identity);
        try bindInt(stmt, 8, session.file_size);
        try bindInt(stmt, 9, session.file_mtime);
        try done(stmt);
    }

    pub fn putEntry(self: *Store, entry: Entry) !void {
        try field(entry.session_file, max_key);
        try field(entry.entry_id, max_key);
        try optionalField(entry.parent_id, max_key);
        try field(entry.entry_type, max_label);
        try checkRow(entry.row);
        const stmt = try self.prepare("INSERT INTO entries(session_file,entry_id,parent_id,append_ordinal,entry_type,raw_content_ref,row_id,kind,role,revision,title,status,content_ref,tool_call_id,is_error,expanded,timestamp) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17) ON CONFLICT(session_file,entry_id) DO UPDATE SET parent_id=excluded.parent_id,entry_type=excluded.entry_type,raw_content_ref=excluded.raw_content_ref,row_id=excluded.row_id,kind=excluded.kind,role=excluded.role,revision=excluded.revision,title=excluded.title,status=excluded.status,content_ref=excluded.content_ref,tool_call_id=excluded.tool_call_id,is_error=excluded.is_error,expanded=excluded.expanded,timestamp=excluded.timestamp");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, entry.session_file);
        try bindText(stmt, 2, entry.entry_id);
        try bindOptionalText(stmt, 3, entry.parent_id);
        try bindInt(stmt, 4, entry.append_ordinal);
        try bindText(stmt, 5, entry.entry_type);
        try bindOptionalId(stmt, 6, entry.raw_content_ref);
        try bindRow(stmt, 7, entry.row);
        try done(stmt);
    }

    pub fn pageEntries(self: *Store, allocator: std.mem.Allocator, session_file: []const u8, after_ordinal: i64, limit: u32) !RowPage {
        if (limit == 0 or limit > max_page_rows) return error.InvalidLimit;
        try field(session_file, max_key);
        const stmt = try self.prepare("SELECT row_id,kind,role,revision,title,status,content_ref,tool_call_id,is_error,expanded,timestamp,append_ordinal,NULL FROM entries WHERE session_file=?1 AND append_ordinal>?2 ORDER BY append_ordinal LIMIT ?3");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindInt(stmt, 2, after_ordinal);
        try bindInt(stmt, 3, limit);
        return self.collectRows(allocator, stmt);
    }

    // The cursor belongs to the selected branch, not the canonical append log.
    // Resolve the persisted leaf so readers never mix cached paths for old leaves.
    pub fn pageActiveEntries(self: *Store, allocator: std.mem.Allocator, session_file: []const u8, after_path_ordinal: i64, limit: u32) !RowPage {
        if (limit == 0 or limit > max_page_rows) return error.InvalidLimit;
        try field(session_file, max_key);
        const stmt = try self.prepare("SELECT e.row_id,e.kind,e.role,e.revision,e.title,e.status,e.content_ref,e.tool_call_id,e.is_error,e.expanded,e.timestamp,p.ordinal,NULL FROM sessions AS s JOIN active_path AS p ON p.session_file=s.session_file AND p.leaf_id=s.leaf_id JOIN entries AS e ON e.session_file=p.session_file AND e.entry_id=p.entry_id WHERE s.session_file=?1 AND p.ordinal>?2 ORDER BY p.ordinal LIMIT ?3");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindInt(stmt, 2, after_path_ordinal);
        try bindInt(stmt, 3, limit);
        return self.collectRows(allocator, stmt);
    }

    pub fn activeEntryCount(self: *Store, session_file: []const u8) !i64 {
        try field(session_file, max_key);
        const stmt = try self.prepare("SELECT COUNT(*) FROM sessions AS s JOIN active_path AS p ON p.session_file=s.session_file AND p.leaf_id=s.leaf_id WHERE s.session_file=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteFailure;
        return c.sqlite3_column_int64(stmt, 0);
    }

    pub fn lastDisplayableActiveEntry(self: *Store, allocator: std.mem.Allocator, session_file: []const u8) !RowPage {
        // Context metadata also has source content; only conversation rows and
        // explicit display-budget placeholders belong on the default chat surface.
        try field(session_file, max_key);
        const stmt = try self.prepare("SELECT e.row_id,e.kind,e.role,e.revision,e.title,e.status,e.content_ref,e.tool_call_id,e.is_error,e.expanded,e.timestamp,p.ordinal,NULL FROM sessions AS s JOIN active_path AS p ON p.session_file=s.session_file AND p.leaf_id=s.leaf_id JOIN entries AS e ON e.session_file=p.session_file AND e.entry_id=p.entry_id WHERE s.session_file=?1 AND e.content_ref IS NOT NULL AND ((e.entry_type='message' AND e.role IN ('assistant','user','toolResult','bashExecution')) OR (e.kind='unsupported_oversized_entry' AND e.status='display_budget')) ORDER BY p.ordinal DESC LIMIT 1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        return self.collectRows(allocator, stmt);
    }

    pub fn putEntryReasoning(self: *Store, session_file: []const u8, entry_id: []const u8, reference: ?ReasoningReference) !void {
        try field(session_file, max_key);
        try field(entry_id, max_key);
        if (reference) |ref| {
            if (ref.length > std.math.maxInt(i64)) return error.LengthOverflow;
            const stmt = try self.prepare("INSERT INTO entry_reasoning(session_file,entry_id,content_ref,length) VALUES(?1,?2,?3,?4) ON CONFLICT(session_file,entry_id) DO UPDATE SET content_ref=excluded.content_ref,length=excluded.length");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, session_file);
            try bindText(stmt, 2, entry_id);
            try bindId(stmt, 3, ref.content_ref);
            try bindInt(stmt, 4, @intCast(ref.length));
            try done(stmt);
        } else {
            const stmt = try self.prepare("DELETE FROM entry_reasoning WHERE session_file=?1 AND entry_id=?2");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, session_file);
            try bindText(stmt, 2, entry_id);
            try done(stmt);
        }
    }

    pub fn referenceForEntry(self: *Store, session_file: []const u8, entry_id: []const u8) !?ReasoningReference {
        try field(session_file, max_key);
        try field(entry_id, max_key);
        const stmt = try self.prepare("SELECT content_ref,length FROM entry_reasoning WHERE session_file=?1 AND entry_id=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, entry_id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        const length = c.sqlite3_column_int64(stmt, 1);
        if (length < 0) return error.CorruptCache;
        return .{ .content_ref = (try columnId(stmt, 0)) orelse return error.CorruptCache, .length = @intCast(length) };
    }

    pub fn putLiveRow(self: *Store, row: LiveRow) !void {
        try checkRow(row.row);
        if (row.runtime > std.math.maxInt(i64)) return error.LengthOverflow;
        const stmt = try self.prepare("INSERT INTO live_rows(runtime,run_generation,local_sequence,content_index,row_id,kind,role,revision,title,status,content_ref,tool_call_id,is_error,expanded,timestamp) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15) ON CONFLICT(runtime,run_generation,local_sequence,content_index) DO UPDATE SET row_id=excluded.row_id,kind=excluded.kind,role=excluded.role,revision=excluded.revision,title=excluded.title,status=excluded.status,content_ref=excluded.content_ref,tool_call_id=excluded.tool_call_id,is_error=excluded.is_error,expanded=excluded.expanded,timestamp=excluded.timestamp");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt(stmt, 1, @intCast(row.runtime));
        try bindInt(stmt, 2, row.run_generation);
        try bindInt(stmt, 3, row.local_sequence);
        try bindInt(stmt, 4, row.content_index);
        try bindRow(stmt, 5, row.row);
        try done(stmt);
    }

    pub fn pageLiveRows(self: *Store, allocator: std.mem.Allocator, runtime: u64, generation: i64, after_sequence: i64, after_content_index: i64, limit: u32) !RowPage {
        if (limit == 0 or limit > max_page_rows) return error.InvalidLimit;
        if (runtime > std.math.maxInt(i64)) return error.LengthOverflow;
        const stmt = try self.prepare("SELECT row_id,kind,role,revision,title,status,content_ref,tool_call_id,is_error,expanded,timestamp,local_sequence,content_index FROM live_rows WHERE runtime=?1 AND run_generation=?2 AND (local_sequence>?3 OR (local_sequence=?3 AND content_index>?4)) ORDER BY local_sequence,content_index LIMIT ?5");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt(stmt, 1, @intCast(runtime));
        try bindInt(stmt, 2, generation);
        try bindInt(stmt, 3, after_sequence);
        try bindInt(stmt, 4, after_content_index);
        try bindInt(stmt, 5, limit);
        return self.collectRows(allocator, stmt);
    }

    pub fn clearLiveGeneration(self: *Store, runtime: u64, generation: i64) !void {
        if (runtime > std.math.maxInt(i64)) return error.LengthOverflow;
        const stmt = try self.prepare("DELETE FROM live_rows WHERE runtime=?1 AND run_generation=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt(stmt, 1, @intCast(runtime));
        try bindInt(stmt, 2, generation);
        try done(stmt);
    }

    pub fn rebuildActivePath(self: *Store, session_file: []const u8, leaf_id: []const u8) !void {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        try self.clearActivePath(session_file, leaf_id);
        const stmt = try self.prepare("WITH RECURSIVE branch(entry_id,parent_id,depth) AS (SELECT entry_id,parent_id,0 FROM entries WHERE session_file=?1 AND entry_id=?2 UNION ALL SELECT e.entry_id,e.parent_id,b.depth+1 FROM entries e JOIN branch b ON e.entry_id=b.parent_id WHERE e.session_file=?1 AND b.depth<100000) INSERT INTO active_path(session_file,leaf_id,ordinal,entry_id) SELECT ?1,?2,(SELECT MAX(depth) FROM branch)-depth,entry_id FROM branch");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, leaf_id);
        try done(stmt);
        try self.exec("COMMIT");
    }

    pub fn clearActivePath(self: *Store, session_file: []const u8, leaf_id: []const u8) !void {
        try field(session_file, max_key);
        try field(leaf_id, max_key);
        const stmt = try self.prepare("DELETE FROM active_path WHERE session_file=?1 AND leaf_id=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, leaf_id);
        try done(stmt);
    }

    pub fn putActivePath(self: *Store, session_file: []const u8, leaf_id: []const u8, ordinal: i64, entry_id: []const u8) !void {
        try field(session_file, max_key);
        try field(leaf_id, max_key);
        try field(entry_id, max_key);
        const stmt = try self.prepare("INSERT INTO active_path(session_file,leaf_id,ordinal,entry_id) VALUES(?1,?2,?3,?4)");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, leaf_id);
        try bindInt(stmt, 3, ordinal);
        try bindText(stmt, 4, entry_id);
        try done(stmt);
    }

    pub fn pageActivePath(self: *Store, allocator: std.mem.Allocator, session_file: []const u8, leaf_id: []const u8, after_ordinal: i64, limit: u32) !RowPage {
        if (limit == 0 or limit > max_page_rows) return error.InvalidLimit;
        try field(session_file, max_key);
        try field(leaf_id, max_key);
        const stmt = try self.prepare("SELECT e.row_id,e.kind,e.role,e.revision,e.title,e.status,e.content_ref,e.tool_call_id,e.is_error,e.expanded,e.timestamp,p.ordinal,NULL FROM active_path AS p JOIN entries AS e ON e.session_file=p.session_file AND e.entry_id=p.entry_id WHERE p.session_file=?1 AND p.leaf_id=?2 AND p.ordinal>?3 ORDER BY p.ordinal LIMIT ?4");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, leaf_id);
        try bindInt(stmt, 3, after_ordinal);
        try bindInt(stmt, 4, limit);
        return self.collectRows(allocator, stmt);
    }

    pub fn addDiagnostic(self: *Store, session_file: []const u8, runtime: u64, kind: []const u8, summary: []const u8, raw_content_ref: ?ContentId, timestamp: i64) !void {
        try field(session_file, max_key);
        try field(kind, max_label);
        try field(summary, max_label);
        if (runtime > std.math.maxInt(i64)) return error.LengthOverflow;
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        {
            const stmt = try self.prepare("INSERT INTO diagnostics(session_file,runtime,kind,summary,raw_content_ref,timestamp) VALUES(?1,?2,?3,?4,?5,?6)");
            defer _ = c.sqlite3_finalize(stmt);
            try bindOptionalText(stmt, 1, if (session_file.len == 0) null else session_file);
            try bindInt(stmt, 2, @intCast(runtime));
            try bindText(stmt, 3, kind);
            try bindText(stmt, 4, summary);
            try bindOptionalId(stmt, 5, raw_content_ref);
            try bindInt(stmt, 6, timestamp);
            try done(stmt);
        }
        {
            const stmt = try self.prepare("DELETE FROM diagnostics WHERE session_file IS ?1 AND diagnostic_id NOT IN (SELECT diagnostic_id FROM diagnostics WHERE session_file IS ?1 ORDER BY diagnostic_id DESC LIMIT 1000)");
            defer _ = c.sqlite3_finalize(stmt);
            try bindOptionalText(stmt, 1, if (session_file.len == 0) null else session_file);
            try done(stmt);
        }
        {
            const stmt = try self.prepare("UPDATE sessions SET diagnostic_evictions=diagnostic_evictions+?2 WHERE session_file=?1");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, session_file);
            try bindInt(stmt, 2, c.sqlite3_changes(self.db));
            try done(stmt);
        }
        try self.exec("COMMIT");
    }

    fn collectRows(self: *Store, allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !RowPage {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        var cursor: ?i64 = null;
        var content_index: ?i64 = null;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;
            try rows.append(a, .{
                .row_id = try columnText(a, stmt, 0, max_key),
                .kind = try columnText(a, stmt, 1, max_label),
                .role = try columnText(a, stmt, 2, max_label),
                .revision = c.sqlite3_column_int64(stmt, 3),
                .title = try columnText(a, stmt, 4, max_label),
                .status = try columnText(a, stmt, 5, max_label),
                .content_ref = try columnId(stmt, 6),
                .tool_call_id = if (c.sqlite3_column_type(stmt, 7) == c.SQLITE_NULL) null else try columnText(a, stmt, 7, max_key),
                .is_error = c.sqlite3_column_int(stmt, 8) != 0,
                .expanded = c.sqlite3_column_int(stmt, 9) != 0,
                .timestamp = c.sqlite3_column_int64(stmt, 10),
            });
            cursor = c.sqlite3_column_int64(stmt, 11);
            content_index = if (c.sqlite3_column_type(stmt, 12) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 12);
        }
        return .{ .arena = arena, .rows = try rows.toOwnedSlice(a), .next_cursor = cursor, .next_content_index = content_index };
    }

    fn prepare(self: *Store, sql: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailure;
        return stmt orelse error.SqliteFailure;
    }

    fn exec(self: *Store, sql: [*:0]const u8) !void {
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) return error.SqliteFailure;
    }
};

fn field(value: []const u8, max: usize) !void {
    if (value.len > max or std.mem.indexOfScalar(u8, value, 0) != null) return error.FieldTooLarge;
}
fn optionalField(value: ?[]const u8, max: usize) !void {
    if (value) |v| try field(v, max);
}
const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));
fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), transient) != c.SQLITE_OK) return error.SqliteFailure;
}
fn bindBlob(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), transient) != c.SQLITE_OK) return error.SqliteFailure;
}
fn bindOptionalText(stmt: *c.sqlite3_stmt, index: c_int, value: ?[]const u8) !void {
    if (value) |v| try bindText(stmt, index, v);
}
fn bindId(stmt: *c.sqlite3_stmt, index: c_int, id: ContentId) !void {
    try bindBlob(stmt, index, &id);
}
fn bindOptionalId(stmt: *c.sqlite3_stmt, index: c_int, id: ?ContentId) !void {
    if (id) |v| try bindId(stmt, index, v);
}
fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteFailure;
}
fn done(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailure;
}
fn checkRow(row: Row) !void {
    try field(row.row_id, max_key);
    try field(row.kind, max_label);
    try field(row.role, max_label);
    try field(row.title, max_label);
    try field(row.status, max_label);
    try optionalField(row.tool_call_id, max_key);
}
fn bindRow(stmt: *c.sqlite3_stmt, start: c_int, row: Row) !void {
    try bindText(stmt, start, row.row_id);
    try bindText(stmt, start + 1, row.kind);
    try bindText(stmt, start + 2, row.role);
    try bindInt(stmt, start + 3, row.revision);
    try bindText(stmt, start + 4, row.title);
    try bindText(stmt, start + 5, row.status);
    try bindOptionalId(stmt, start + 6, row.content_ref);
    try bindOptionalText(stmt, start + 7, row.tool_call_id);
    try bindInt(stmt, start + 8, if (row.is_error) 1 else 0);
    try bindInt(stmt, start + 9, if (row.expanded) 1 else 0);
    try bindInt(stmt, start + 10, row.timestamp);
}
fn columnText(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, index: c_int, max: usize) ![]const u8 {
    const size: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    if (size > max) return error.CorruptCache;
    if (size == 0) return allocator.dupe(u8, "");
    const ptr = c.sqlite3_column_text(stmt, index);
    if (ptr == null) return error.CorruptCache;
    return allocator.dupe(u8, ptr[0..size]);
}
fn columnId(stmt: *c.sqlite3_stmt, index: c_int) !?ContentId {
    if (c.sqlite3_column_type(stmt, index) == c.SQLITE_NULL) return null;
    if (c.sqlite3_column_bytes(stmt, index) != 16) return error.CorruptCache;
    const ptr = c.sqlite3_column_blob(stmt, index) orelse return error.CorruptCache;
    const bytes: [*]const u8 = @ptrCast(ptr);
    var id: ContentId = undefined;
    @memcpy(&id, bytes[0..16]);
    return id;
}

const reasoning_schema =
    "CREATE TABLE entry_reasoning(session_file TEXT NOT NULL,entry_id TEXT NOT NULL,content_ref BLOB NOT NULL CHECK(length(content_ref)=16),length INTEGER NOT NULL CHECK(length>=0),PRIMARY KEY(session_file,entry_id),FOREIGN KEY(session_file,entry_id) REFERENCES entries(session_file,entry_id) ON DELETE CASCADE);";

const schema: [*:0]const u8 =
    "CREATE TABLE sessions(session_file TEXT PRIMARY KEY,session_id TEXT NOT NULL,project_id TEXT NOT NULL,display_name TEXT NOT NULL DEFAULT '',leaf_id TEXT,last_entry_id TEXT,file_identity TEXT NOT NULL DEFAULT '',file_size INTEGER NOT NULL DEFAULT 0,file_mtime INTEGER NOT NULL DEFAULT 0,diagnostic_evictions INTEGER NOT NULL DEFAULT 0);" ++
    "CREATE TABLE content_objects(content_id BLOB PRIMARY KEY CHECK(length(content_id)=16),encoding TEXT NOT NULL,mime_type TEXT NOT NULL,total_length INTEGER NOT NULL DEFAULT 0 CHECK(total_length>=0),next_index INTEGER NOT NULL DEFAULT 0 CHECK(next_index>=0),sealed INTEGER NOT NULL DEFAULT 0 CHECK(sealed IN (0,1)));" ++
    "CREATE TABLE content_chunks(content_id BLOB NOT NULL REFERENCES content_objects(content_id) ON DELETE CASCADE,chunk_index INTEGER NOT NULL CHECK(chunk_index>=0),payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=65536),PRIMARY KEY(content_id,chunk_index));" ++
    "CREATE TABLE entries(session_file TEXT NOT NULL REFERENCES sessions(session_file) ON DELETE CASCADE,entry_id TEXT NOT NULL,parent_id TEXT,append_ordinal INTEGER NOT NULL,entry_type TEXT NOT NULL,raw_content_ref BLOB,row_id TEXT NOT NULL,kind TEXT NOT NULL,role TEXT NOT NULL,revision INTEGER NOT NULL,title TEXT NOT NULL,status TEXT NOT NULL,content_ref BLOB,tool_call_id TEXT,is_error INTEGER NOT NULL,expanded INTEGER NOT NULL,timestamp INTEGER NOT NULL,PRIMARY KEY(session_file,entry_id),UNIQUE(session_file,append_ordinal));" ++
    "CREATE INDEX entries_parent ON entries(session_file,parent_id);" ++
    "CREATE TABLE live_rows(runtime INTEGER NOT NULL,run_generation INTEGER NOT NULL,local_sequence INTEGER NOT NULL,content_index INTEGER NOT NULL,row_id TEXT NOT NULL,kind TEXT NOT NULL,role TEXT NOT NULL,revision INTEGER NOT NULL,title TEXT NOT NULL,status TEXT NOT NULL,content_ref BLOB,tool_call_id TEXT,is_error INTEGER NOT NULL,expanded INTEGER NOT NULL,timestamp INTEGER NOT NULL,PRIMARY KEY(runtime,run_generation,local_sequence,content_index));" ++
    "CREATE TABLE active_path(session_file TEXT NOT NULL REFERENCES sessions(session_file) ON DELETE CASCADE,leaf_id TEXT NOT NULL,ordinal INTEGER NOT NULL,entry_id TEXT NOT NULL,PRIMARY KEY(session_file,leaf_id,ordinal));" ++
    "CREATE TABLE diagnostics(diagnostic_id INTEGER PRIMARY KEY,session_file TEXT REFERENCES sessions(session_file) ON DELETE CASCADE,runtime INTEGER NOT NULL,kind TEXT NOT NULL,summary TEXT NOT NULL,raw_content_ref BLOB,timestamp INTEGER NOT NULL);" ++
    "CREATE INDEX diagnostics_session ON diagnostics(session_file,diagnostic_id);" ++
    reasoning_schema;

test "active branch paging and visible content ignore later inactive appends" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer allocator.free(db_path);
    var store = try Store.init(allocator, db_path);
    defer store.deinit();
    const path = "/project/branch-session.jsonl";
    try store.putSession(.{ .session_file = path, .session_id = "branch-session", .project_id = "project", .leaf_id = "active-leaf" });
    const display_ref: ContentId = @splat(17);
    const raw_ref: ContentId = @splat(18);
    const inactive_ref: ContentId = @splat(19);
    try store.append(display_ref, 0, "Active decoded\ncontent", true);
    try store.append(raw_ref, 0, "{\"content\":\"Active decoded\\ncontent\"}", true);
    try store.append(inactive_ref, 0, "Inactive tail", true);
    const ids = [_][]const u8{ "root", "active-answer", "active-leaf", "inactive-tail" };
    const parents = [_]?[]const u8{ null, "root", "active-answer", "root" };
    const roles = [_][]const u8{ "user", "assistant", "user", "assistant" };
    for (ids, parents, roles, 0..) |id, parent, role, ordinal| {
        try store.putEntry(.{
            .session_file = path,
            .entry_id = id,
            .parent_id = parent,
            .append_ordinal = @intCast(ordinal),
            .entry_type = "message",
            .raw_content_ref = raw_ref,
            .row = .{ .row_id = id, .kind = "message", .role = role, .status = "complete", .content_ref = if (ordinal == 3) inactive_ref else display_ref },
        });
    }
    try store.rebuildActivePath(path, "active-leaf");
    try std.testing.expectEqual(@as(i64, 3), try store.activeEntryCount(path));
    var first = try store.pageActiveEntries(allocator, path, -1, 2);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 2), first.rows.len);
    try std.testing.expectEqualStrings("root", first.rows[0].row_id);
    try std.testing.expectEqualStrings("active-answer", first.rows[1].row_id);
    try std.testing.expectEqual(@as(?i64, 1), first.next_cursor);
    var next = try store.pageActiveEntries(allocator, path, first.next_cursor.?, 2);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 1), next.rows.len);
    try std.testing.expectEqualStrings("active-leaf", next.rows[0].row_id);
    try std.testing.expectEqual(@as(?i64, 2), next.next_cursor);
    var exhausted = try store.pageActiveEntries(allocator, path, next.next_cursor.?, 2);
    defer exhausted.deinit();
    try std.testing.expectEqual(@as(usize, 0), exhausted.rows.len);
    var visible = try store.lastDisplayableActiveEntry(allocator, path);
    defer visible.deinit();
    try std.testing.expectEqual(@as(usize, 1), visible.rows.len);
    try std.testing.expectEqualStrings("active-leaf", visible.rows[0].row_id);
    const selected_ref = visible.rows[0].content_ref.?;
    try std.testing.expectEqualSlices(u8, &display_ref, &selected_ref);
    const selected = (try store.readChunk(allocator, selected_ref, 0)).?;
    defer allocator.free(selected);
    try std.testing.expectEqualStrings("Active decoded\ncontent", selected);
    const raw = (try store.readChunk(allocator, raw_ref, 0)).?;
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("{\"content\":\"Active decoded\\ncontent\"}", raw);

    // Switching leaves must not expose the cached path for the old branch.
    try store.putSession(.{ .session_file = path, .session_id = "branch-session", .project_id = "project", .leaf_id = "inactive-tail" });
    try store.rebuildActivePath(path, "inactive-tail");
    try std.testing.expectEqual(@as(i64, 2), try store.activeEntryCount(path));
    var switched = try store.pageActiveEntries(allocator, path, -1, 2);
    defer switched.deinit();
    try std.testing.expectEqual(@as(usize, 2), switched.rows.len);
    try std.testing.expectEqualStrings("root", switched.rows[0].row_id);
    try std.testing.expectEqualStrings("inactive-tail", switched.rows[1].row_id);
    var switched_visible = try store.lastDisplayableActiveEntry(allocator, path);
    defer switched_visible.deinit();
    try std.testing.expectEqualStrings("inactive-tail", switched_visible.rows[0].row_id);
    const switched_ref = switched_visible.rows[0].content_ref.?;
    try std.testing.expectEqualSlices(u8, &inactive_ref, &switched_ref);
    try std.testing.expectError(error.InvalidLimit, store.pageActiveEntries(allocator, path, -1, max_page_rows + 1));

    // Context entries retain inspectable source content but must not replace chat.
    try store.putEntry(.{
        .session_file = path,
        .entry_id = "model-context",
        .parent_id = "inactive-tail",
        .append_ordinal = 4,
        .entry_type = "model_change",
        .raw_content_ref = raw_ref,
        .row = .{ .row_id = "model-context", .kind = "unsupported_entry", .role = "", .status = "complete", .content_ref = raw_ref },
    });
    try store.putEntry(.{
        .session_file = path,
        .entry_id = "thinking-context",
        .parent_id = "model-context",
        .append_ordinal = 5,
        .entry_type = "thinking_level_change",
        .raw_content_ref = raw_ref,
        .row = .{ .row_id = "thinking-context", .kind = "unsupported_entry", .role = "", .status = "complete", .content_ref = raw_ref },
    });
    try store.putSession(.{ .session_file = path, .session_id = "branch-session", .project_id = "project", .leaf_id = "thinking-context" });
    try store.rebuildActivePath(path, "thinking-context");
    try std.testing.expectEqual(@as(i64, 4), try store.activeEntryCount(path));
    var context_visible = try store.lastDisplayableActiveEntry(allocator, path);
    defer context_visible.deinit();
    try std.testing.expectEqual(@as(usize, 1), context_visible.rows.len);
    try std.testing.expectEqualStrings("inactive-tail", context_visible.rows[0].row_id);
    try std.testing.expectEqual(@as(?i64, 1), context_visible.next_cursor);
    var context_page = try store.pageActiveEntries(allocator, path, 1, 2);
    defer context_page.deinit();
    try std.testing.expectEqual(@as(usize, 2), context_page.rows.len);
    try std.testing.expectEqualStrings("model-context", context_page.rows[0].row_id);
    try std.testing.expectEqualStrings("thinking-context", context_page.rows[1].row_id);
    const retained_context = context_page.rows[1].content_ref.?;
    try std.testing.expectEqualSlices(u8, &raw_ref, &retained_context);

    try store.putEntry(.{
        .session_file = path,
        .entry_id = "startup-context",
        .append_ordinal = 6,
        .entry_type = "model_change",
        .raw_content_ref = raw_ref,
        .row = .{ .row_id = "startup-context", .kind = "unsupported_entry", .role = "", .status = "complete", .content_ref = raw_ref },
    });
    try store.putSession(.{ .session_file = path, .session_id = "branch-session", .project_id = "project", .leaf_id = "startup-context" });
    try store.rebuildActivePath(path, "startup-context");
    var startup_visible = try store.lastDisplayableActiveEntry(allocator, path);
    defer startup_visible.deinit();
    try std.testing.expectEqual(@as(usize, 0), startup_visible.rows.len);
    try std.testing.expectEqual(@as(?i64, null), startup_visible.next_cursor);
}

test "v2 migration preserves active chat and separately retained reasoning and raw source" {
    const projection = @import("session.zig");
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer allocator.free(db_path);
    const raw_json = "{\"id\":\"answer\",\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"Check branch\\nprivately\"},{\"type\":\"text\",\"text\":\"Final answer\"},{\"type\":\"thinking\",\"thinking\":\"Then verify\"}]}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    const message = parsed.value.object.get("message").?;
    const body = try projection.messageText(allocator, message);
    defer allocator.free(body);
    const thinking = try projection.thinkingText(allocator, message);
    defer allocator.free(thinking);
    try std.testing.expectEqualStrings("Final answer", body);
    try std.testing.expectEqualStrings("Check branch\nprivately\n\nThen verify", thinking);
    const path = "/project/reasoning-session.jsonl";
    const body_ref: ContentId = @splat(31);
    const raw_ref: ContentId = @splat(32);
    const thinking_ref: ContentId = @splat(33);
    const other_ref: ContentId = @splat(34);
    {
        var store = try Store.init(allocator, db_path);
        defer store.deinit();
        // These are the actual v2 tables, populated before the v3-only relation.
        try store.exec("DROP TABLE entry_reasoning; PRAGMA user_version=2;");
        try store.putSession(.{ .session_file = path, .session_id = "reasoning", .project_id = "project", .leaf_id = "context" });
        try store.append(body_ref, 0, body, true);
        try store.append(raw_ref, 0, raw_json, true);
        try store.append(thinking_ref, 0, thinking, true);
        try store.append(other_ref, 0, "Unrelated branch reasoning", true);
        try store.putEntry(.{
            .session_file = path,
            .entry_id = "answer",
            .append_ordinal = 0,
            .entry_type = "message",
            .raw_content_ref = raw_ref,
            .row = .{ .row_id = "answer", .kind = "message", .role = "assistant", .content_ref = body_ref },
        });
        try store.putEntry(.{
            .session_file = path,
            .entry_id = "context",
            .parent_id = "answer",
            .append_ordinal = 1,
            .entry_type = "model_change",
            .raw_content_ref = raw_ref,
            .row = .{ .row_id = "context", .kind = "unsupported_entry", .role = "", .content_ref = raw_ref },
        });
        try store.putEntry(.{
            .session_file = path,
            .entry_id = "inactive",
            .append_ordinal = 2,
            .entry_type = "message",
            .raw_content_ref = raw_ref,
            .row = .{ .row_id = "inactive", .kind = "message", .role = "assistant", .content_ref = other_ref },
        });
        try store.rebuildActivePath(path, "context");
    }
    {
        var store = try Store.init(allocator, db_path);
        defer store.deinit();
        try std.testing.expectEqual(@as(i64, 2), try store.activeEntryCount(path));
        try std.testing.expect((try store.referenceForEntry(path, "answer")) == null);
        try store.putEntryReasoning(path, "answer", .{ .content_ref = thinking_ref, .length = thinking.len });
        try store.putEntryReasoning(path, "inactive", .{ .content_ref = other_ref, .length = "Unrelated branch reasoning".len });
    }
    {
        var reader = try Store.openReadOnly(allocator, db_path);
        defer reader.deinit();
        var visible = try reader.lastDisplayableActiveEntry(allocator, path);
        defer visible.deinit();
        try std.testing.expectEqual(@as(usize, 1), visible.rows.len);
        try std.testing.expectEqualStrings("answer", visible.rows[0].row_id);
        try std.testing.expectEqual(@as(?i64, 0), visible.next_cursor);
        const answer = (try reader.readChunk(allocator, visible.rows[0].content_ref.?, 0)).?;
        defer allocator.free(answer);
        try std.testing.expectEqualStrings("Final answer", answer);
        const reference = (try reader.referenceForEntry(path, visible.rows[0].row_id)).?;
        try std.testing.expectEqual(@as(u64, thinking.len), reference.length);
        try std.testing.expectEqualSlices(u8, &thinking_ref, &reference.content_ref);
        const retained_thinking = (try reader.readChunk(allocator, reference.content_ref, 0)).?;
        defer allocator.free(retained_thinking);
        try std.testing.expectEqualStrings(thinking, retained_thinking);
        const stmt = try reader.prepare("SELECT raw_content_ref FROM entries WHERE session_file=?1 AND entry_id='answer'");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        const retained_raw_ref = (try columnId(stmt, 0)).?;
        try std.testing.expectEqualSlices(u8, &raw_ref, &retained_raw_ref);
        const retained_raw = (try reader.readChunk(allocator, retained_raw_ref, 0)).?;
        defer allocator.free(retained_raw);
        try std.testing.expectEqualStrings(raw_json, retained_raw);
    }
    {
        var store = try Store.init(allocator, db_path);
        defer store.deinit();
        try store.putEntryReasoning(path, "answer", null);
        try std.testing.expect((try store.referenceForEntry(path, "answer")) == null);
        // Clearing a derived disclosure must not delete its authoritative source.
        const retained_raw = (try store.readChunk(allocator, raw_ref, 0)).?;
        defer allocator.free(retained_raw);
        try std.testing.expectEqualStrings(raw_json, retained_raw);
    }
}
