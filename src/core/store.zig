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

pub const SessionIndexEntry = struct {
    session_file: []const u8,
    cwd: []const u8,
    title: []const u8,
    modified: i64,
};

pub const SessionIndexPage = struct {
    arena: std.heap.ArenaAllocator,
    entries: []SessionIndexEntry,

    pub fn deinit(self: *SessionIndexPage) void {
        self.arena.deinit();
        self.* = undefined;
    }
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
pub const ConversationEntry = struct {
    ordinal: usize,
    role: enum { user, assistant, tool, bash, system },
    content_id: ContentId,
    length: u64,
    reasoning: ?ReasoningReference = null,
    activity: [192]u8 = [_]u8{0} ** 192,
    activity_len: u8 = 0,
    status: enum { complete, running, failed, unknown } = .unknown,
    /// Unix milliseconds, or zero when the source supplies no timestamp.
    timestamp: i64 = 0,
};
pub const live_ordinal_base: usize = std.math.maxInt(usize) / 2;

pub const Activity = struct {
    bytes: [192]u8 = [_]u8{0} ** 192,
    len: u8 = 0,

    pub fn append(self: *Activity, text: []const u8) void {
        var size = @min(text.len, self.bytes.len - self.len);
        while (size > 0 and size < text.len and (text[size] & 0xc0) == 0x80) size -= 1;
        @memcpy(self.bytes[self.len..][0..size], text[0..size]);
        self.len += @intCast(size);
    }

    pub fn slice(self: *const Activity) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Tool-call IDs are canonical identities. Hidden derived entries use the
/// existing entry primary key, so result linkage never scans message bodies.
pub fn toolMetadataId(call: []const u8) [75]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(call, &digest, .{});
    var id: [75]u8 = undefined;
    @memcpy(id[0..11], "spica-tool:");
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        id[11 + i * 2] = hex[byte >> 4];
        id[12 + i * 2] = hex[byte & 15];
    }
    return id;
}

pub const Store = struct {
    db: *c.sqlite3,

    pub fn init(allocator: std.mem.Allocator, database_path: []const u8) !Store {
        if (database_path.len == 0 or database_path.len > max_key or std.mem.indexOfScalar(u8, database_path, 0) != null) return error.InvalidPath;
        const path = try allocator.dupeZ(u8, database_path);
        defer allocator.free(path);
        // Workers may open a brand-new database together. Serialize WAL setup
        // as well as migrations; SQLite's lock upgrade can otherwise fail before
        // busy_timeout applies, leaving the catalog unavailable until restart.
        const initialization_mutex = c.sqlite3_mutex_alloc(c.SQLITE_MUTEX_STATIC_APP1);
        c.sqlite3_mutex_enter(initialization_mutex);
        defer c.sqlite3_mutex_leave(initialization_mutex);
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteFailure;
        }
        var self: Store = .{ .db = handle.? };
        errdefer self.deinit();
        _ = c.sqlite3_busy_timeout(self.db, 5000);
        try self.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA cache_size=-256;");
        // Serialize schema inspection with migrations on other worker connections.
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const version = try self.prepare("PRAGMA user_version");
        const rc_version = c.sqlite3_step(version);
        const number: c_int = if (rc_version == c.SQLITE_ROW) c.sqlite3_column_int(version, 0) else -1;
        _ = c.sqlite3_finalize(version);
        if (number < 0) return error.SqliteFailure;
        if (number > 6) return error.UnsupportedSchema;
        if (number == 0) {
            try self.exec(schema);
            try self.exec("PRAGMA user_version=3");
        }
        if (number == 1) {
            try self.exec("ALTER TABLE diagnostics RENAME TO diagnostics_v1; CREATE TABLE diagnostics(diagnostic_id INTEGER PRIMARY KEY,session_file TEXT REFERENCES sessions(session_file) ON DELETE CASCADE,runtime INTEGER NOT NULL,kind TEXT NOT NULL,summary TEXT NOT NULL,raw_content_ref BLOB,timestamp INTEGER NOT NULL); INSERT INTO diagnostics SELECT * FROM diagnostics_v1; DROP TABLE diagnostics_v1; CREATE INDEX diagnostics_session ON diagnostics(session_file,diagnostic_id); PRAGMA user_version=2;");
        }
        if (number == 1 or number == 2) {
            try self.exec(reasoning_schema);
            try self.exec("PRAGMA user_version=3");
        }
        if (number < 4) {
            try self.exec("CREATE TABLE IF NOT EXISTS session_index(session_file TEXT PRIMARY KEY,cwd TEXT NOT NULL,title TEXT NOT NULL,modified INTEGER NOT NULL); PRAGMA user_version=4;");
        }
        if (number < 5) {
            try self.exec("CREATE TABLE workspace_chats(session_file TEXT PRIMARY KEY,archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1))); PRAGMA user_version=5;");
        }
        if (number < 6) {
            try self.exec(live_entry_links_schema);
            try self.exec("PRAGMA user_version=6");
        }
        try self.exec("COMMIT");
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

    /// Membership commits are acknowledged only after FULL-synchronous COMMIT.
    /// Discovery and runtime persistence remain membership-neutral.
    pub fn enroll(self: *Store, entry: SessionIndexEntry) !void {
        try self.exec("PRAGMA synchronous=FULL");
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        try self.putSessionIndex(entry);
        const stmt = try self.prepare("INSERT INTO workspace_chats(session_file,archived) VALUES(?1,0) ON CONFLICT(session_file) DO NOTHING");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, entry.session_file);
        try done(stmt);
        try self.exec("COMMIT");
    }

    pub fn setArchived(self: *Store, path: []const u8, archived: bool) !void {
        try field(path, max_key);
        try self.exec("PRAGMA synchronous=FULL");
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        const stmt = try self.prepare("UPDATE workspace_chats SET archived=?2 WHERE session_file=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        try bindInt(stmt, 2, if (archived) 1 else 0);
        try done(stmt);
        if (c.sqlite3_changes(self.db) != 1) return error.NotWorkspaceMember;
        try self.exec("COMMIT");
    }

    pub fn workspaceState(self: *Store, path: []const u8) !?bool {
        try field(path, max_key);
        const stmt = try self.prepare("SELECT archived FROM workspace_chats WHERE session_file=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        return c.sqlite3_column_int(stmt, 0) != 0;
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

    /// Discovery metadata never writes sessions: leaf, source fingerprint, and
    /// imported transcript state remain exclusively owned by the importer.
    pub fn putSessionIndex(self: *Store, entry: SessionIndexEntry) !void {
        try field(entry.session_file, max_key);
        try field(entry.cwd, max_key);
        try field(entry.title, max_label);
        const stmt = try self.prepare("INSERT INTO session_index(session_file,cwd,title,modified) VALUES(?1,?2,?3,?4) ON CONFLICT(session_file) DO UPDATE SET cwd=excluded.cwd,title=excluded.title,modified=excluded.modified");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, entry.session_file);
        try bindText(stmt, 2, entry.cwd);
        try bindText(stmt, 3, entry.title);
        try bindInt(stmt, 4, entry.modified);
        try done(stmt);
    }

    pub fn putSessionIndexPage(self: *Store, entries: []const SessionIndexEntry) !void {
        if (entries.len > max_page_rows) return error.InvalidLimit;
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.exec("ROLLBACK") catch {};
        for (entries) |entry| try self.putSessionIndex(entry);
        try self.exec("COMMIT");
    }

    /// Keyset pages include imported sessions outside today's discovery roots.
    pub fn pageSessionIndex(self: *Store, allocator: std.mem.Allocator, after: []const u8) !SessionIndexPage {
        try field(after, max_key);
        const stmt = try self.prepare("SELECT session_file,cwd,title,modified FROM (SELECT session_file,cwd,title,modified FROM session_index UNION ALL SELECT s.session_file,s.project_id,CASE WHEN s.display_name='' THEN 'Untitled session' ELSE s.display_name END,s.file_mtime FROM sessions s WHERE NOT EXISTS(SELECT 1 FROM session_index i WHERE i.session_file=s.session_file)) WHERE session_file>?1 ORDER BY session_file LIMIT 128");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, after);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var entries: std.ArrayList(SessionIndexEntry) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;
            try entries.append(a, .{
                .session_file = try columnText(a, stmt, 0, max_key),
                .cwd = try columnText(a, stmt, 1, max_key),
                .title = try columnText(a, stmt, 2, max_label),
                .modified = c.sqlite3_column_int64(stmt, 3),
            });
        }
        return .{ .arena = arena, .entries = try entries.toOwnedSlice(a) };
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

    pub fn toolActivity(self: *Store, session_file: []const u8, call: []const u8) !?Activity {
        const id = toolMetadataId(call);
        const stmt = try self.prepare("SELECT title FROM entries WHERE session_file=?1 AND entry_id=?2 AND entry_type='tool_call'");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, &id);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteFailure;
        var activity: Activity = .{};
        if (c.sqlite3_column_text(stmt, 0)) |title| activity.append(std.mem.span(title));
        return activity;
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
    /// Only compact references reside in the viewport; message bodies stay on disk.
    pub fn conversationEntries(self: *Store, allocator: std.mem.Allocator, session_file: []const u8, fixture_mode: bool, runtime: u64, generation: i64) ![]ConversationEntry {
        try field(session_file, max_key);
        const stmt = try self.prepare(if (fixture_mode)
            "SELECT e.append_ordinal,e.role,e.content_ref,o.total_length,r.content_ref,r.length,e.title,e.status,e.is_error,e.timestamp FROM entries e JOIN content_objects o ON o.content_id=e.content_ref LEFT JOIN entry_reasoning r ON r.session_file=e.session_file AND r.entry_id=e.entry_id WHERE e.session_file=?1 AND e.entry_type='message' ORDER BY e.append_ordinal"
        else
            "SELECT p.ordinal,e.role,e.content_ref,o.total_length,r.content_ref,r.length,e.title,e.status,e.is_error,e.timestamp FROM sessions s JOIN active_path p ON p.session_file=s.session_file AND p.leaf_id=s.leaf_id JOIN entries e ON e.session_file=p.session_file AND e.entry_id=p.entry_id JOIN content_objects o ON o.content_id=e.content_ref LEFT JOIN entry_reasoning r ON r.session_file=e.session_file AND r.entry_id=e.entry_id WHERE s.session_file=?1 AND ((e.entry_type='message' AND e.role IN ('user','assistant','toolResult','bashExecution')) OR (e.kind='unsupported_oversized_entry' AND e.status='display_budget')) ORDER BY p.ordinal");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        var entries: std.ArrayList(ConversationEntry) = .empty;
        errdefer entries.deinit(allocator);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteFailure;
            const bytes = c.sqlite3_column_text(stmt, 1);
            const role = if (bytes) |p| std.mem.span(p) else "";
            const reasoning = try columnId(stmt, 4);
            const metadata = conversationMetadata(stmt, 6);
            try entries.append(allocator, .{
                .ordinal = @intCast(c.sqlite3_column_int64(stmt, 0)),
                .role = if (std.mem.eql(u8, role, "user")) .user else if (std.mem.eql(u8, role, "assistant")) .assistant else if (std.mem.eql(u8, role, "toolResult")) .tool else if (std.mem.eql(u8, role, "bashExecution")) .bash else .system,
                .content_id = (try columnId(stmt, 2)) orelse return error.CorruptCache,
                .length = @intCast(c.sqlite3_column_int64(stmt, 3)),
                .reasoning = if (reasoning) |id| .{ .content_ref = id, .length = @intCast(c.sqlite3_column_int64(stmt, 5)) } else null,
                .activity = metadata.activity,
                .activity_len = metadata.activity_len,
                .status = metadata.status,
                .timestamp = metadata.timestamp,
            });
        }
        if (!fixture_mode and runtime != 0) {
            if (runtime > std.math.maxInt(i64)) return error.LengthOverflow;
            const live = try self.prepare("SELECT l.local_sequence,l.content_index,l.role,l.content_ref,o.total_length,l.title,l.status,l.is_error,l.timestamp FROM live_rows l JOIN content_objects o ON o.content_id=l.content_ref WHERE l.runtime=?1 AND l.run_generation=?2 AND l.kind!='thinking' AND NOT EXISTS (SELECT 1 FROM live_entry_links k JOIN sessions s ON s.session_file=k.session_file JOIN active_path p ON p.session_file=s.session_file AND p.leaf_id=s.leaf_id AND p.entry_id=k.entry_id WHERE k.runtime=l.runtime AND k.run_generation=l.run_generation AND k.local_sequence=l.local_sequence AND k.content_index=l.content_index AND k.session_file=?3) ORDER BY l.local_sequence,l.content_index");
            defer _ = c.sqlite3_finalize(live);
            try bindInt(live, 1, @intCast(runtime));
            try bindInt(live, 2, generation);
            try bindText(live, 3, session_file);
            while (true) {
                const rc = c.sqlite3_step(live);
                if (rc == c.SQLITE_DONE) break;
                if (rc != c.SQLITE_ROW) return error.SqliteFailure;
                const bytes = c.sqlite3_column_text(live, 2);
                const role = if (bytes) |p| std.mem.span(p) else "";
                const sequence: usize = @intCast(c.sqlite3_column_int64(live, 0));
                const index: usize = @intCast(c.sqlite3_column_int64(live, 1));
                const metadata = conversationMetadata(live, 5);
                try entries.append(allocator, .{
                    .ordinal = live_ordinal_base + sequence * 512 + index,
                    .role = if (std.mem.eql(u8, role, "user")) .user else if (std.mem.eql(u8, role, "assistant")) .assistant else if (std.mem.eql(u8, role, "toolResult")) .tool else if (std.mem.eql(u8, role, "bashExecution")) .bash else .system,
                    .content_id = (try columnId(live, 3)) orelse return error.CorruptCache,
                    .length = @intCast(c.sqlite3_column_int64(live, 4)),
                    .activity = metadata.activity,
                    .activity_len = metadata.activity_len,
                    .status = metadata.status,
                    .timestamp = metadata.timestamp,
                });
            }
        }
        return entries.toOwnedSlice(allocator);
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

    /// Associate one completed live message with its canonical identity. Timestamp,
    /// role and full content must agree; equal text alone never retires a prompt.
    /// The unique canonical key makes repeated entry imports idempotent, including
    /// legitimate equal prompts sharing a millisecond timestamp.
    pub fn linkLiveEntry(self: *Store, session_file: []const u8, entry_id: []const u8, runtime: u64, generation: i64) !void {
        try field(session_file, max_key);
        try field(entry_id, max_key);
        if (runtime > std.math.maxInt(i64)) return error.LengthOverflow;
        const stmt = try self.prepare(
            "INSERT INTO live_entry_links(runtime,run_generation,local_sequence,content_index,session_file,entry_id) " ++
                "SELECT l.runtime,l.run_generation,l.local_sequence,l.content_index,e.session_file,e.entry_id FROM entries e " ++
                "JOIN content_objects canonical ON canonical.content_id=e.content_ref " ++
                "JOIN live_rows l ON l.runtime=?3 AND l.run_generation=?4 AND l.role=e.role AND l.timestamp=e.timestamp " ++
                "JOIN content_objects live ON live.content_id=l.content_ref " ++
                "WHERE e.session_file=?1 AND e.entry_id=?2 AND e.entry_type='message' AND e.role IN ('user','assistant') AND e.timestamp>0 " ++
                "AND l.kind='message' AND l.status IN ('complete','failed') AND canonical.sealed=1 AND live.sealed=1 " ++
                "AND canonical.total_length=live.total_length AND canonical.next_index=live.next_index " ++
                "AND NOT EXISTS (SELECT 1 FROM content_chunks x LEFT JOIN content_chunks y ON y.content_id=l.content_ref AND y.chunk_index=x.chunk_index WHERE x.content_id=e.content_ref AND (y.payload IS NULL OR x.payload!=y.payload)) " ++
                "AND NOT EXISTS (SELECT 1 FROM live_entry_links k WHERE k.runtime=l.runtime AND k.run_generation=l.run_generation AND ((k.local_sequence=l.local_sequence AND k.content_index=l.content_index) OR (k.session_file=e.session_file AND k.entry_id=e.entry_id))) " ++
                "ORDER BY l.local_sequence,l.content_index LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, session_file);
        try bindText(stmt, 2, entry_id);
        try bindInt(stmt, 3, @intCast(runtime));
        try bindInt(stmt, 4, generation);
        try done(stmt);
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
    pub fn clearLiveMessage(self: *Store, runtime: u64, generation: i64, sequence: i64) !void {
        if (runtime > std.math.maxInt(i64)) return error.LengthOverflow;
        const stmt = try self.prepare("DELETE FROM live_rows WHERE runtime=?1 AND run_generation=?2 AND local_sequence=?3");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt(stmt, 1, @intCast(runtime));
        try bindInt(stmt, 2, generation);
        try bindInt(stmt, 3, sequence);
        try done(stmt);
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

fn conversationMetadata(stmt: *c.sqlite3_stmt, start: c_int) ConversationEntry {
    var metadata: ConversationEntry = .{ .ordinal = 0, .role = .system, .content_id = undefined, .length = 0 };
    var activity: Activity = .{};
    if (c.sqlite3_column_text(stmt, start)) |title| activity.append(std.mem.span(title));
    metadata.activity = activity.bytes;
    metadata.activity_len = activity.len;
    const status = if (c.sqlite3_column_text(stmt, start + 1)) |s| std.mem.span(s) else "";
    metadata.status = if (c.sqlite3_column_int(stmt, start + 2) != 0 or std.mem.eql(u8, status, "failed"))
        .failed
    else if (std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "streaming"))
        .running
    else if (std.mem.eql(u8, status, "complete"))
        .complete
    else
        .unknown;
    metadata.timestamp = c.sqlite3_column_int64(stmt, start + 3);
    return metadata;
}

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

const live_entry_links_schema =
    "CREATE TABLE live_entry_links(runtime INTEGER NOT NULL,run_generation INTEGER NOT NULL,local_sequence INTEGER NOT NULL,content_index INTEGER NOT NULL,session_file TEXT NOT NULL,entry_id TEXT NOT NULL,PRIMARY KEY(runtime,run_generation,local_sequence,content_index),UNIQUE(runtime,run_generation,session_file,entry_id),FOREIGN KEY(runtime,run_generation,local_sequence,content_index) REFERENCES live_rows(runtime,run_generation,local_sequence,content_index) ON DELETE CASCADE,FOREIGN KEY(session_file,entry_id) REFERENCES entries(session_file,entry_id) ON DELETE CASCADE);";

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
    const transcript = try store.conversationEntries(allocator, path, false, 0, 0);
    defer allocator.free(transcript);
    try std.testing.expectEqual(@as(usize, 3), transcript.len);
    try std.testing.expectEqual(.user, transcript[0].role);
    try std.testing.expectEqual(.assistant, transcript[1].role);
    try std.testing.expectEqual(.user, transcript[2].role);
    try std.testing.expectEqual(@as(usize, 2), transcript[2].ordinal);
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
    const context_transcript = try store.conversationEntries(allocator, path, false, 0, 0);
    defer allocator.free(context_transcript);
    try std.testing.expectEqual(@as(usize, 2), context_transcript.len);
    try std.testing.expectEqualSlices(u8, &inactive_ref, &context_transcript[1].content_id);
    try store.putLiveRow(.{ .runtime = 1, .run_generation = 4, .local_sequence = 1, .content_index = 0, .row = .{ .row_id = "prompt", .kind = "message", .role = "user", .content_ref = display_ref } });
    try store.putLiveRow(.{ .runtime = 1, .run_generation = 4, .local_sequence = 2, .content_index = 0, .row = .{ .row_id = "reasoning", .kind = "thinking", .role = "assistant", .content_ref = raw_ref } });
    try store.putLiveRow(.{ .runtime = 1, .run_generation = 4, .local_sequence = 2, .content_index = 1, .row = .{ .row_id = "partial", .kind = "message", .role = "assistant", .content_ref = display_ref } });
    const streaming = try store.conversationEntries(allocator, path, false, 1, 4);
    defer allocator.free(streaming);
    try std.testing.expectEqual(@as(usize, 4), streaming.len);
    try std.testing.expectEqual(.user, streaming[2].role);
    try std.testing.expectEqual(.assistant, streaming[3].role);
    try std.testing.expectEqualSlices(u8, &display_ref, &streaming[3].content_id);
    try store.clearLiveMessage(1, 4, 2);
    try store.putLiveRow(.{ .runtime = 1, .run_generation = 4, .local_sequence = 2, .content_index = 0, .row = .{ .row_id = "completed", .kind = "message", .role = "assistant", .content_ref = inactive_ref } });
    const completed = try store.conversationEntries(allocator, path, false, 1, 4);
    defer allocator.free(completed);
    try std.testing.expectEqual(@as(usize, 4), completed.len);
    try std.testing.expectEqualSlices(u8, &display_ref, &completed[2].content_id);
    try std.testing.expectEqualSlices(u8, &inactive_ref, &completed[3].content_id);
    const other_generation = try store.conversationEntries(allocator, path, false, 1, 5);
    defer allocator.free(other_generation);
    try std.testing.expectEqual(@as(usize, 2), other_generation.len);
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
        try store.exec("DROP TABLE live_entry_links; DROP TABLE workspace_chats; DROP TABLE session_index; DROP TABLE entry_reasoning; PRAGMA user_version=2;");
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

test "discovery index migration and metadata refresh preserve resumable chat and source fingerprint" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer a.free(db_path);
    const path = "/outside-discovery/original.jsonl";
    const raw_ref: ContentId = @splat(61);
    const body_ref: ContentId = @splat(62);
    {
        var db = try Store.init(a, db_path);
        defer db.deinit();
        try db.putSession(.{
            .session_file = path,
            .session_id = "original-id",
            .project_id = "/original-project",
            .display_name = "Imported title",
            .leaf_id = "answer",
            .last_entry_id = "answer",
            .file_identity = "original-fingerprint",
            .file_size = 1234,
            .file_mtime = 5678,
        });
        try db.append(raw_ref, 0, "{\"id\":\"answer\",\"source\":\"unchanged\"}", true);
        try db.append(body_ref, 0, "The original answer", true);
        try db.putEntry(.{
            .session_file = path,
            .entry_id = "answer",
            .append_ordinal = 0,
            .entry_type = "message",
            .raw_content_ref = raw_ref,
            .row = .{ .row_id = "answer", .kind = "message", .role = "assistant", .content_ref = body_ref },
        });
        try db.rebuildActivePath(path, "answer");
        try db.exec("DROP TABLE live_entry_links; DROP TABLE workspace_chats; DROP TABLE session_index; PRAGMA user_version=3;");
    }
    {
        var db = try Store.init(a, db_path);
        defer db.deinit();
        var existing = try db.pageSessionIndex(a, "");
        defer existing.deinit();
        try std.testing.expectEqual(@as(usize, 1), existing.entries.len);
        try std.testing.expectEqualStrings(path, existing.entries[0].session_file);
        try std.testing.expectEqualStrings("/original-project", existing.entries[0].cwd);
        try db.putSessionIndexPage(&.{.{ .session_file = path, .cwd = "/original-project", .title = "Discovered title", .modified = 9000 }});
    }
    {
        var reader = try Store.openReadOnly(a, db_path);
        defer reader.deinit();
        var indexed = try reader.pageSessionIndex(a, "");
        defer indexed.deinit();
        try std.testing.expectEqual(@as(usize, 1), indexed.entries.len);
        try std.testing.expectEqualStrings("Discovered title", indexed.entries[0].title);
        try std.testing.expectEqual(@as(i64, 9000), indexed.entries[0].modified);
        const stmt = try reader.prepare("SELECT session_id,leaf_id,last_entry_id,file_identity,file_size,file_mtime FROM sessions WHERE session_file=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, path);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        for ([_][]const u8{ "original-id", "answer", "answer", "original-fingerprint" }, 0..) |expected, i| {
            try std.testing.expectEqualStrings(expected, std.mem.span(c.sqlite3_column_text(stmt, @intCast(i)).?));
        }
        try std.testing.expectEqual(@as(i64, 1234), c.sqlite3_column_int64(stmt, 4));
        try std.testing.expectEqual(@as(i64, 5678), c.sqlite3_column_int64(stmt, 5));
        var visible = try reader.lastDisplayableActiveEntry(a, path);
        defer visible.deinit();
        try std.testing.expectEqual(@as(usize, 1), visible.rows.len);
        try std.testing.expectEqualStrings("answer", visible.rows[0].row_id);
        const body = (try reader.readChunk(a, visible.rows[0].content_ref.?, 0)).?;
        defer a.free(body);
        try std.testing.expectEqualStrings("The original answer", body);
        const raw = (try reader.readChunk(a, raw_ref, 0)).?;
        defer a.free(raw);
        try std.testing.expectEqualStrings("{\"id\":\"answer\",\"source\":\"unchanged\"}", raw);
    }
}

test "session index keyset pages keep imported sessions beyond the discovery page boundary" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer a.free(db_path);
    {
        var db = try Store.init(a, db_path);
        defer db.deinit();
        for (0..130) |i| {
            const path = try std.fmt.allocPrint(a, "/external/session-{d:0>3}.jsonl", .{i});
            defer a.free(path);
            if (i < 128) {
                try db.putSessionIndex(.{ .session_file = path, .cwd = "/indexed-project", .title = "Indexed chat", .modified = @intCast(i) });
            } else {
                try db.putSession(.{ .session_file = path, .session_id = path, .project_id = "/imported-project", .display_name = "Imported chat" });
            }
        }
    }
    var reader = try Store.openReadOnly(a, db_path);
    defer reader.deinit();
    var first = try reader.pageSessionIndex(a, "");
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 128), first.entries.len);
    try std.testing.expectEqualStrings("/external/session-000.jsonl", first.entries[0].session_file);
    try std.testing.expectEqualStrings("/external/session-127.jsonl", first.entries[127].session_file);
    var next = try reader.pageSessionIndex(a, first.entries[127].session_file);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 2), next.entries.len);
    try std.testing.expectEqualStrings("/external/session-128.jsonl", next.entries[0].session_file);
    try std.testing.expectEqualStrings("/external/session-129.jsonl", next.entries[1].session_file);
    try std.testing.expectEqualStrings("/imported-project", next.entries[0].cwd);
    try std.testing.expectEqualStrings("Imported chat", next.entries[1].title);
    var end = try reader.pageSessionIndex(a, next.entries[1].session_file);
    defer end.deinit();
    try std.testing.expectEqual(@as(usize, 0), end.entries.len);
}

test "v4 histories remain nonmembers and archive state survives enrollment and reopen" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/history.sqlite", .{tmp.sub_path});
    defer a.free(db_path);
    const entry: SessionIndexEntry = .{ .session_file = "/original/source.jsonl", .cwd = "/project", .title = "Original", .modified = 123 };
    {
        var db = try Store.init(a, db_path);
        defer db.deinit();
        try db.putSessionIndex(entry);
        try db.exec("DROP TABLE live_entry_links; DROP TABLE workspace_chats; PRAGMA user_version=4");
    }
    {
        var db = try Store.init(a, db_path);
        defer db.deinit();
        try std.testing.expectEqual(@as(?bool, null), try db.workspaceState(entry.session_file));
        try std.testing.expectError(error.NotWorkspaceMember, db.setArchived(entry.session_file, true));
        try db.enroll(entry);
        try std.testing.expectEqual(@as(?bool, false), try db.workspaceState(entry.session_file));
        try db.setArchived(entry.session_file, true);
        try db.enroll(entry);
        try std.testing.expectEqual(@as(?bool, true), try db.workspaceState(entry.session_file));
    }
    {
        var db = try Store.init(a, db_path);
        defer db.deinit();
        try std.testing.expectEqual(@as(?bool, true), try db.workspaceState(entry.session_file));
        try db.setArchived(entry.session_file, false);
        var page = try db.pageSessionIndex(a, "");
        defer page.deinit();
        try std.testing.expectEqualStrings(entry.session_file, page.entries[0].session_file);
        try std.testing.expectEqualStrings(entry.title, page.entries[0].title);
    }
    var reader = try Store.openReadOnly(a, db_path);
    defer reader.deinit();
    try std.testing.expectEqual(@as(?bool, false), try reader.workspaceState(entry.session_file));
}

test "database cutover copies uncheckpointed WAL and rejects unsupported destinations" {
    const cutover = struct {
        extern fn spica_database_cutover(destination: [*:0]const u8, legacy: [*:0]const u8, temporary: [*:0]const u8, directory: [*:0]const u8) c_int;
    }.spica_database_cutover;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer a.free(directory);
    const legacy = try std.fmt.allocPrintSentinel(a, "{s}/legacy.sqlite", .{directory}, 0);
    defer a.free(legacy);
    const destination = try std.fmt.allocPrintSentinel(a, "{s}/durable.sqlite", .{directory}, 0);
    defer a.free(destination);
    const temporary = try std.fmt.allocPrintSentinel(a, "{s}/staging.sqlite", .{directory}, 0);
    defer a.free(temporary);
    const path = "/outside/original.jsonl";
    const raw: ContentId = @splat(73);
    var source = try Store.init(a, legacy);
    defer source.deinit();
    try source.exec("PRAGMA wal_autocheckpoint=0");
    try source.putSession(.{ .session_file = path, .session_id = "original", .project_id = "/project", .leaf_id = "leaf", .file_identity = "identity", .file_size = 512, .file_mtime = 99 });
    try source.putSessionIndex(.{ .session_file = path, .cwd = "/project", .title = "Original", .modified = 99 });
    try source.append(raw, 0, "canonical raw source", true);
    try source.exec("DROP TABLE live_entry_links; DROP TABLE workspace_chats; PRAGMA user_version=4");
    try std.testing.expectEqual(@as(c_int, 0), cutover(destination, legacy, temporary, directory));
    {
        var copied = try Store.init(a, destination);
        defer copied.deinit();
        const bytes = (try copied.readChunk(a, raw, 0)).?;
        defer a.free(bytes);
        try std.testing.expectEqualStrings("canonical raw source", bytes);
        try std.testing.expectEqual(@as(?bool, null), try copied.workspaceState(path));
        const statement = try copied.prepare("SELECT leaf_id,file_identity,file_size,file_mtime FROM sessions WHERE session_file=?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, path);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        try std.testing.expectEqualStrings("leaf", std.mem.span(c.sqlite3_column_text(statement, 0).?));
        try std.testing.expectEqualStrings("identity", std.mem.span(c.sqlite3_column_text(statement, 1).?));
        try std.testing.expectEqual(@as(i64, 512), c.sqlite3_column_int64(statement, 2));
        try std.testing.expectEqual(@as(i64, 99), c.sqlite3_column_int64(statement, 3));
        try copied.exec("PRAGMA user_version=999");
    }
    try std.testing.expect(cutover(destination, legacy, temporary, directory) != 0);
    var unchanged = try Store.openReadOnly(a, legacy);
    defer unchanged.deinit();
    const bytes = (try unchanged.readChunk(a, raw, 0)).?;
    defer a.free(bytes);
    try std.testing.expectEqualStrings("canonical raw source", bytes);
}

test "v5 migration preserves messages and links expire with their live generation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/v5-overlap.sqlite", .{tmp.sub_path});
    defer a.free(db_path);
    const path = "/project/migration-session.jsonl";
    const canonical: ContentId = @splat(81);
    const live: ContentId = @splat(82);
    {
        var store = try Store.init(a, db_path);
        defer store.deinit();
        try store.putSession(.{ .session_file = path, .session_id = "migration", .project_id = "/project", .leaf_id = "prompt" });
        try store.append(canonical, 0, "Repeat", true);
        try store.append(live, 0, "Repeat", true);
        try store.putEntry(.{
            .session_file = path,
            .entry_id = "prompt",
            .append_ordinal = 0,
            .entry_type = "message",
            .row = .{ .row_id = "prompt", .kind = "message", .role = "user", .status = "complete", .timestamp = 100, .content_ref = canonical },
        });
        try store.rebuildActivePath(path, "prompt");
        try store.putLiveRow(.{ .runtime = 7, .run_generation = 1, .local_sequence = 1, .content_index = 0, .row = .{ .row_id = "live-user", .kind = "message", .role = "user", .status = "complete", .timestamp = 100, .content_ref = live } });
        try store.exec("DROP TABLE live_entry_links; PRAGMA user_version=5");
    }
    var store = try Store.init(a, db_path);
    defer store.deinit();
    try store.linkLiveEntry(path, "prompt", 7, 1);
    const migrated = try store.conversationEntries(a, path, false, 7, 1);
    defer a.free(migrated);
    try std.testing.expectEqual(@as(usize, 1), migrated.len);
    try std.testing.expectEqualSlices(u8, &canonical, &migrated[0].content_id);
    const body = (try store.readChunk(a, migrated[0].content_id, 0)).?;
    defer a.free(body);
    try std.testing.expectEqualStrings("Repeat", body);
    try store.clearLiveGeneration(7, 1);
    // Reusing the tuple demonstrates that its link was cascaded away; no old
    // association may hide a distinct prompt in the new live state.
    try store.putLiveRow(.{ .runtime = 7, .run_generation = 1, .local_sequence = 1, .content_index = 0, .row = .{ .row_id = "live-user", .kind = "message", .role = "user", .status = "complete", .timestamp = 200, .content_ref = live } });
    try store.linkLiveEntry(path, "prompt", 7, 1);
    const repeated = try store.conversationEntries(a, path, false, 7, 1);
    defer a.free(repeated);
    try std.testing.expectEqual(@as(usize, 2), repeated.len);
    try std.testing.expectEqual(@as(i64, 100), repeated[0].timestamp);
    try std.testing.expectEqual(@as(i64, 200), repeated[1].timestamp);
    try std.testing.expectEqualSlices(u8, &live, &repeated[1].content_id);
}
