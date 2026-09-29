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
        if (number != 0 and number != 1) return error.UnsupportedSchema;
        if (number == 0) {
            try self.exec("BEGIN IMMEDIATE");
            errdefer self.exec("ROLLBACK") catch {};
            try self.exec(schema);
            try self.exec("PRAGMA user_version=1");
            try self.exec("COMMIT");
        }
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
            try bindText(stmt, 1, session_file);
            try bindInt(stmt, 2, @intCast(runtime));
            try bindText(stmt, 3, kind);
            try bindText(stmt, 4, summary);
            try bindOptionalId(stmt, 5, raw_content_ref);
            try bindInt(stmt, 6, timestamp);
            try done(stmt);
        }
        {
            const stmt = try self.prepare("DELETE FROM diagnostics WHERE session_file=?1 AND diagnostic_id NOT IN (SELECT diagnostic_id FROM diagnostics WHERE session_file=?1 ORDER BY diagnostic_id DESC LIMIT 1000)");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, session_file);
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

const schema: [*:0]const u8 =
    "CREATE TABLE sessions(session_file TEXT PRIMARY KEY,session_id TEXT NOT NULL,project_id TEXT NOT NULL,display_name TEXT NOT NULL DEFAULT '',leaf_id TEXT,last_entry_id TEXT,file_identity TEXT NOT NULL DEFAULT '',file_size INTEGER NOT NULL DEFAULT 0,file_mtime INTEGER NOT NULL DEFAULT 0,diagnostic_evictions INTEGER NOT NULL DEFAULT 0);" ++
    "CREATE TABLE content_objects(content_id BLOB PRIMARY KEY CHECK(length(content_id)=16),encoding TEXT NOT NULL,mime_type TEXT NOT NULL,total_length INTEGER NOT NULL DEFAULT 0 CHECK(total_length>=0),next_index INTEGER NOT NULL DEFAULT 0 CHECK(next_index>=0),sealed INTEGER NOT NULL DEFAULT 0 CHECK(sealed IN (0,1)));" ++
    "CREATE TABLE content_chunks(content_id BLOB NOT NULL REFERENCES content_objects(content_id) ON DELETE CASCADE,chunk_index INTEGER NOT NULL CHECK(chunk_index>=0),payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=65536),PRIMARY KEY(content_id,chunk_index));" ++
    "CREATE TABLE entries(session_file TEXT NOT NULL REFERENCES sessions(session_file) ON DELETE CASCADE,entry_id TEXT NOT NULL,parent_id TEXT,append_ordinal INTEGER NOT NULL,entry_type TEXT NOT NULL,raw_content_ref BLOB,row_id TEXT NOT NULL,kind TEXT NOT NULL,role TEXT NOT NULL,revision INTEGER NOT NULL,title TEXT NOT NULL,status TEXT NOT NULL,content_ref BLOB,tool_call_id TEXT,is_error INTEGER NOT NULL,expanded INTEGER NOT NULL,timestamp INTEGER NOT NULL,PRIMARY KEY(session_file,entry_id),UNIQUE(session_file,append_ordinal));" ++
    "CREATE INDEX entries_parent ON entries(session_file,parent_id);" ++
    "CREATE TABLE live_rows(runtime INTEGER NOT NULL,run_generation INTEGER NOT NULL,local_sequence INTEGER NOT NULL,content_index INTEGER NOT NULL,row_id TEXT NOT NULL,kind TEXT NOT NULL,role TEXT NOT NULL,revision INTEGER NOT NULL,title TEXT NOT NULL,status TEXT NOT NULL,content_ref BLOB,tool_call_id TEXT,is_error INTEGER NOT NULL,expanded INTEGER NOT NULL,timestamp INTEGER NOT NULL,PRIMARY KEY(runtime,run_generation,local_sequence,content_index));" ++
    "CREATE TABLE active_path(session_file TEXT NOT NULL REFERENCES sessions(session_file) ON DELETE CASCADE,leaf_id TEXT NOT NULL,ordinal INTEGER NOT NULL,entry_id TEXT NOT NULL,PRIMARY KEY(session_file,leaf_id,ordinal));" ++
    "CREATE TABLE diagnostics(diagnostic_id INTEGER PRIMARY KEY,session_file TEXT NOT NULL REFERENCES sessions(session_file) ON DELETE CASCADE,runtime INTEGER NOT NULL,kind TEXT NOT NULL,summary TEXT NOT NULL,raw_content_ref BLOB,timestamp INTEGER NOT NULL);" ++
    "CREATE INDEX diagnostics_session ON diagnostics(session_file,diagnostic_id);";
