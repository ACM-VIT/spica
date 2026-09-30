const std = @import("std");
const catalog = @import("catalog.zig");
const sql = @import("search_sql.zig");
const source = @import("search_source.zig");
const c = sql.c;
const native = @import("../native/bindings.zig").c;
const allocator = std.heap.page_allocator;

const Normalized = struct {
    bytes: [65536]u8 = undefined,
    length: usize = 0,
    scalars: [65536]u32 = undefined,
    scalar_length: usize = 0,
    starts: [128]usize = undefined,
    ends: [128]usize = undefined,
    count: usize = 0,
    overflow: bool = false,
    fn callback(ctx: ?*anyopaque, _: c_int, bytes: [*c]const u8, length: c_int, _: c_int, _: c_int) callconv(.c) c_int {
        const self: *Normalized = @ptrCast(@alignCast(ctx.?));
        const text = bytes[0..@as(usize, @intCast(length))];
        if (self.length + text.len + 1 > self.bytes.len) { self.overflow = true; return c.SQLITE_TOOBIG; }
        if (self.length != 0) { self.bytes[self.length] = ' '; self.length += 1; self.scalars[self.scalar_length] = ' '; self.scalar_length += 1; }
        const start = self.scalar_length;
        const view = std.unicode.Utf8View.init(text) catch return c.SQLITE_ERROR;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |scalar| {
            self.scalars[self.scalar_length] = scalar;
            self.scalar_length += 1;
        }
        @memcpy(self.bytes[self.length..][0..text.len], text);
        self.length += text.len;
        if (self.count < self.starts.len) { self.starts[self.count] = start; self.ends[self.count] = self.scalar_length; self.count += 1; }
        return c.SQLITE_OK;
    }
    fn values(self: *const Normalized) []const u32 { return self.scalars[0..self.scalar_length]; }
};

pub const Engine = struct {
    db: sql.Db,
    tokenizer: ?*c.Fts5Tokenizer = null,
    methods: c.fts5_tokenizer = undefined,
    scratch: *Normalized,
    query: *Normalized,
    whole: ?*native.SpicaFuzzyQuery = null,
    terms: [128]?*native.SpicaFuzzyQuery = @splat(null),
    scope: catalog.Scope = .workspace,
    generation: u64 = 0,
    offset: usize = 0,
    raw: [256]u8 = undefined,
    raw_len: usize = 0,
    metadata_cursor: []u8 = &.{},
    vocab_cursor: []u8 = &.{},
    metadata_done: bool = false,
    vocabulary_done: bool = false,
    postings_done: bool = false,
    posting_cursor: i64 = 0,
    ranking_done: bool = false,
    ranking_cursor: []u8 = &.{},
    complete: bool = true,
    dirty: bool = false,
    indexing: bool = false,
    warning: ?anyerror = null,
    pub fn init(path: []const u8) !Engine {
        var db = try sql.Db.init(path);
        errdefer db.deinit();
        const scratch = try allocator.create(Normalized);
        errdefer allocator.destroy(scratch);
        const query = try allocator.create(Normalized);
        errdefer allocator.destroy(query);
        var self: Engine = .{ .db = db, .scratch = scratch, .query = query };
        errdefer {
            if (self.tokenizer) |tokenizer| self.methods.xDelete.?(tokenizer);
        }
        try source.init(&self.db);
        var api: ?*c.fts5_api = null;
        const get = try self.db.prepare("SELECT fts5(?1)");
        defer _ = c.sqlite3_finalize(get);
        if (c.sqlite3_bind_pointer(get, 1, @ptrCast(&api), "fts5_api_ptr", null) != c.SQLITE_OK or c.sqlite3_step(get) != c.SQLITE_ROW or api == null) return error.Fts5Unavailable;
        var context: ?*anyopaque = null;
        if (api.?.xFindTokenizer.?(api, "unicode61", &context, &self.methods) != c.SQLITE_OK) return error.Fts5Unavailable;
        var args = [_][*c]const u8{ "remove_diacritics", "2" };
        if (self.methods.xCreate.?(context, &args, 2, &self.tokenizer) != c.SQLITE_OK) return error.Fts5Unavailable;
        try self.db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS search_vocabulary USING fts5vocab(search_fts,'row'); CREATE VIRTUAL TABLE IF NOT EXISTS search_postings USING fts5vocab(search_fts,'instance'); CREATE TEMP TABLE accepted(ordinal INTEGER,term TEXT,class INTEGER,score REAL,PRIMARY KEY(ordinal,term)); CREATE TEMP TABLE hits(session_file TEXT,ordinal INTEGER,class INTEGER,score REAL,field INTEGER,rowid INTEGER,term TEXT,PRIMARY KEY(session_file,ordinal)); CREATE TEMP TABLE ranked(session_file TEXT PRIMARY KEY,class INTEGER,score REAL,titles INTEGER,paths INTEGER,rowid INTEGER,term TEXT); CREATE TEMP TABLE excerpts(session_file TEXT PRIMARY KEY,rowid INTEGER,term TEXT,class INTEGER,score REAL)");
        return self;
    }
    pub fn deinit(self: *Engine) void {
        self.clearScorers();
        if (self.tokenizer) |tokenizer| self.methods.xDelete.?(tokenizer);
        allocator.free(self.metadata_cursor);
        allocator.free(self.vocab_cursor);
        allocator.destroy(self.scratch);
        allocator.free(self.ranking_cursor);
        allocator.destroy(self.query);
        self.db.deinit();
    }
    fn clearScorers(self: *Engine) void {
        native.spica_fuzzy_destroy(self.whole); self.whole = null;
        for (&self.terms) |*term| { native.spica_fuzzy_destroy(term.*); term.* = null; }
    }
    fn normalize(self: *Engine, text: []const u8, target: *Normalized) !void {
        target.length = 0; target.scalar_length = 0; target.count = 0; target.overflow = false;
        if (self.methods.xTokenize.?(self.tokenizer, target, c.FTS5_TOKENIZE_QUERY, text.ptr, @intCast(text.len), Normalized.callback) != c.SQLITE_OK) return error.SearchTokenizationFailed;
    }
    pub fn begin(self: *Engine, scope: catalog.Scope, text: []const u8, offset: usize, generation: u64) !void {
        if (text.len > 256 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidSearchQuery;
        const reuse = self.generation != 0 and self.complete and !self.dirty and self.scope == scope and std.mem.eql(u8, self.raw[0..self.raw_len], text);
        self.scope = scope; self.offset = offset; self.generation = generation;
        if (reuse) return;
        self.clearScorers();
        @memcpy(self.raw[0..text.len], text); self.raw_len = text.len;
        try self.normalize(text, self.query);
        allocator.free(self.metadata_cursor); self.metadata_cursor = &.{};
        allocator.free(self.vocab_cursor); self.vocab_cursor = &.{};
        try self.db.exec("DELETE FROM accepted; DELETE FROM hits; DELETE FROM ranked; DELETE FROM excerpts");
        self.metadata_done = false; self.vocabulary_done = false;
        self.postings_done = false; self.posting_cursor = 0;
        self.ranking_done = false;
        allocator.free(self.ranking_cursor); self.ranking_cursor = &.{};
        self.complete = self.query.count == 0;
        self.dirty = false;
        if (self.complete) return;
        self.whole = native.spica_fuzzy_create(self.query.scalars[0..self.query.scalar_length].ptr, self.query.scalar_length) orelse return error.FuzzySearchFailed;
        for (0..self.query.count) |i| {
            const values = self.query.scalars[self.query.starts[i]..self.query.ends[i]];
            self.terms[i] = native.spica_fuzzy_create(values.ptr, values.len) orelse return error.FuzzySearchFailed;
        }
    }
    const Quality = struct { class: i64, score: f64 };
    fn quality(query: []const u32, scorer: ?*native.SpicaFuzzyQuery, candidate: []const u32, prefix: bool) !?Quality {
        if (std.mem.eql(u32, query, candidate)) return .{ .class = 3, .score = 100 };
        if (prefix and std.mem.startsWith(u32, candidate, query)) return .{ .class = 2, .score = 100 };
        if (query.len < 3) return null;
        var score: native.SpicaFuzzyScore = undefined;
        if (!native.spica_fuzzy_score(scorer, candidate.ptr, candidate.len, &score)) return error.FuzzySearchFailed;
        return if (score.subsequence or score.ratio >= 70) .{ .class = 1, .score = score.ratio } else null;
    }
    fn scoped(self: *Engine, stmt: *c.sqlite3_stmt, slot: c_int) !void { try sql.bindInt(stmt, slot, @intFromEnum(self.scope)); }
    pub fn step(self: *Engine) !bool {
        if (self.complete) return true;
        if (!self.metadata_done) try self.metadataStep()
        else if (!self.vocabulary_done) try self.vocabularyStep()
        else if (!self.postings_done) try self.postingStep()
        else if (!self.ranking_done) try self.rankingStep();
        self.complete = self.metadata_done and self.vocabulary_done and self.postings_done and self.ranking_done;
        if (self.complete and self.dirty) {
            var query: [256]u8 = undefined;
            @memcpy(query[0..self.raw_len], self.raw[0..self.raw_len]);
            try self.begin(self.scope, query[0..self.raw_len], self.offset, self.generation);
        }
        return self.complete;
    }
    fn metadataStep(self: *Engine) !void {
        const stmt = try self.db.prepare("SELECT i.session_file,i.title,i.cwd FROM session_index i LEFT JOIN workspace_chats w USING(session_file) WHERE i.session_file>?1 AND ((?2=0 AND w.session_file IS NOT NULL) OR (?2=1 AND w.archived=1) OR (?2=2 AND w.session_file IS NULL)) ORDER BY i.session_file LIMIT 128");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, self.metadata_cursor); try self.scoped(stmt, 2);
        var count: usize = 0;
        while (try row(stmt)) {
            count += 1;
            const path = sql.column(stmt, 0);
            const next = try allocator.dupe(u8, path); allocator.free(self.metadata_cursor); self.metadata_cursor = next;
            for (1..4) |field| {
                const text = if (field == 3) path else sql.column(stmt, @intCast(field));
                try self.normalize(text, self.scratch);
                if (try quality(self.query.values(), self.whole, self.scratch.values(), true)) |q| try self.addRank(path, q, field == 1);
            }
        }
        self.metadata_done = count < 128;
    }
    fn addRank(self: *Engine, path: []const u8, q: Quality, title: bool) !void {
        const stmt = try self.db.prepare("INSERT INTO ranked VALUES(?1,?2,?3,?4,?5,NULL,NULL) ON CONFLICT(session_file) DO UPDATE SET class=excluded.class,score=excluded.score,titles=excluded.titles,paths=excluded.paths,rowid=NULL,term=NULL WHERE (excluded.class,excluded.score,excluded.titles,excluded.paths)>(ranked.class,ranked.score,ranked.titles,ranked.paths)");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, path); try sql.bindInt(stmt, 2, q.class);
        if (c.sqlite3_bind_double(stmt, 3, q.score) != c.SQLITE_OK) return error.SqliteFailure;
        try sql.bindInt(stmt, 4, if (title) 1 else 0); try sql.bindInt(stmt, 5, if (title) 0 else 1); try sql.done(stmt);
    }
    fn vocabularyStep(self: *Engine) !void {
        const stmt = try self.db.prepare("SELECT term FROM search_vocabulary WHERE term>?1 ORDER BY term LIMIT 128");
        defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, self.vocab_cursor);
        var count: usize = 0;
        while (try row(stmt)) {
            count += 1;
            const word = sql.column(stmt, 0);
            const next = try allocator.dupe(u8, word); allocator.free(self.vocab_cursor); self.vocab_cursor = next;
            try self.normalize(word, self.scratch);
            for (0..self.query.count) |i| {
                const term = self.query.scalars[self.query.starts[i]..self.query.ends[i]];
                if (try quality(term, self.terms[i], self.scratch.values(), i + 1 == self.query.count)) |q| {
                    const accept = try self.db.prepare("INSERT INTO accepted VALUES(?1,?2,?3,?4)");
                    defer _ = c.sqlite3_finalize(accept);
                    try sql.bindInt(accept, 1, @intCast(i)); try sql.bindText(accept, 2, word); try sql.bindInt(accept, 3, q.class);
                    if (c.sqlite3_bind_double(accept, 4, q.score) != c.SQLITE_OK) return error.SqliteFailure;
                    try sql.done(accept);
                }
            }
        }
        self.vocabulary_done = count < 128;
    }
    fn postingStep(self: *Engine) !void {
        const bounds = try self.db.prepare("SELECT MAX(rowid) FROM (SELECT s.rowid FROM search_segments s LEFT JOIN workspace_chats w USING(session_file) LEFT JOIN search_sources x USING(session_file) WHERE s.rowid>?1 AND (s.generation=0 OR s.generation=x.generation) AND ((?2=0 AND w.session_file IS NOT NULL) OR (?2=1 AND w.archived=1) OR (?2=2 AND w.session_file IS NULL AND s.field!=2)) ORDER BY s.rowid LIMIT 128)");
        defer _ = c.sqlite3_finalize(bounds);
        try sql.bindInt(bounds, 1, self.posting_cursor); try self.scoped(bounds, 2);
        if (!try row(bounds) or c.sqlite3_column_type(bounds, 0) == c.SQLITE_NULL) { self.postings_done = true; return; }
        const end = c.sqlite3_column_int64(bounds, 0);
        const posting = try self.db.prepare("INSERT INTO hits SELECT s.session_file,a.ordinal,a.class,a.score,s.field,s.rowid,a.term FROM accepted a JOIN search_postings p ON p.term=a.term JOIN search_segments s ON s.rowid=p.doc LEFT JOIN workspace_chats w USING(session_file) LEFT JOIN search_sources x USING(session_file) WHERE s.rowid>?1 AND s.rowid<=?2 AND (s.generation=0 OR s.generation=x.generation) AND ((?3=0 AND w.session_file IS NOT NULL) OR (?3=1 AND w.archived=1) OR (?3=2 AND w.session_file IS NULL AND s.field!=2)) AND true ON CONFLICT(session_file,ordinal) DO UPDATE SET class=excluded.class,score=excluded.score,field=excluded.field,rowid=excluded.rowid,term=excluded.term WHERE (excluded.class,excluded.score,-excluded.field)>(hits.class,hits.score,-hits.field)");
        defer _ = c.sqlite3_finalize(posting);
        try sql.bindInt(posting, 1, self.posting_cursor); try sql.bindInt(posting, 2, end); try self.scoped(posting, 3); try sql.done(posting);
        const excerpt_hit = try self.db.prepare("INSERT INTO excerpts SELECT s.session_file,s.rowid,a.term,a.class,a.score FROM accepted a JOIN search_postings p ON p.term=a.term JOIN search_segments s ON s.rowid=p.doc JOIN workspace_chats w USING(session_file) JOIN search_sources x USING(session_file) WHERE s.rowid>?1 AND s.rowid<=?2 AND s.field=2 AND s.generation=x.generation AND (?3=0 OR (?3=1 AND w.archived=1)) ON CONFLICT(session_file) DO UPDATE SET rowid=excluded.rowid,term=excluded.term,class=excluded.class,score=excluded.score WHERE (excluded.class,excluded.score,-excluded.rowid)>(excerpts.class,excerpts.score,-excerpts.rowid)");
        defer _ = c.sqlite3_finalize(excerpt_hit);
        try sql.bindInt(excerpt_hit, 1, self.posting_cursor); try sql.bindInt(excerpt_hit, 2, end); try self.scoped(excerpt_hit, 3); try sql.done(excerpt_hit);
        self.posting_cursor = end;
    }
    fn rankingStep(self: *Engine) !void {
        const bounds = try self.db.prepare("SELECT MAX(session_file) FROM (SELECT DISTINCT session_file FROM hits WHERE session_file>?1 ORDER BY session_file LIMIT 128)");
        defer _ = c.sqlite3_finalize(bounds);
        try sql.bindText(bounds, 1, self.ranking_cursor);
        if (!try row(bounds) or c.sqlite3_column_type(bounds, 0) == c.SQLITE_NULL) { self.ranking_done = true; return; }
        const end = try allocator.dupe(u8, sql.column(bounds, 0));
        errdefer allocator.free(end);
        const aggregate = try self.db.prepare("INSERT INTO ranked SELECT session_file,MIN(class),AVG(score),SUM(field=0),SUM(field=1),(SELECT h.rowid FROM hits h WHERE h.session_file=hits.session_file AND h.field=2 LIMIT 1),(SELECT h.term FROM hits h WHERE h.session_file=hits.session_file AND h.field=2 LIMIT 1) FROM hits WHERE session_file>?2 AND session_file<=?3 GROUP BY session_file HAVING COUNT(*)=?1 ON CONFLICT(session_file) DO UPDATE SET class=excluded.class,score=excluded.score,titles=excluded.titles,paths=excluded.paths,rowid=excluded.rowid,term=excluded.term WHERE (excluded.class,excluded.score,excluded.titles,excluded.paths)>(ranked.class,ranked.score,ranked.titles,ranked.paths)");
        defer _ = c.sqlite3_finalize(aggregate);
        try sql.bindInt(aggregate, 1, @intCast(self.query.count)); try sql.bindText(aggregate, 2, self.ranking_cursor); try sql.bindText(aggregate, 3, end); try sql.done(aggregate);
        allocator.free(self.ranking_cursor); self.ranking_cursor = end;
    }
    pub fn page(self: *Engine, io: std.Io) !catalog.SearchPage {
        const empty = self.raw_len == 0 or std.mem.trim(u8, self.raw[0..self.raw_len], " \t\r\n").len == 0;
        const indexing = self.indexing and self.scope != .import_pi;
        // Partial rankings may change both order and identity. Never expose them
        // as actionable results while another lane or invalidation is pending.
        if (!empty and (!self.complete or self.dirty)) return .{
            .threads = &.{}, .scope = self.scope, .offset = self.offset, .more = false,
            .generation = self.generation, .searching = true,
            .indexing = indexing, .warning = if (self.scope == .import_pi) null else self.warning,
        };
        const stmt = try self.db.prepare("SELECT i.session_file,i.cwd,i.title,i.modified,COALESCE(w.archived,0),e.rowid,e.term FROM session_index i LEFT JOIN workspace_chats w USING(session_file) LEFT JOIN ranked r USING(session_file) LEFT JOIN excerpts e USING(session_file) WHERE ((?1=0 AND w.session_file IS NOT NULL) OR (?1=1 AND w.archived=1) OR (?1=2 AND w.session_file IS NULL)) AND (?2 OR r.session_file IS NOT NULL) ORDER BY CASE WHEN ?2 THEN 0 ELSE r.class END DESC,CASE WHEN ?2 THEN 0 ELSE r.score END DESC,CASE WHEN ?2 THEN 0 ELSE r.titles END DESC,CASE WHEN ?2 THEN 0 ELSE r.paths END DESC,i.modified DESC,i.session_file LIMIT 33 OFFSET ?3");
        defer _ = c.sqlite3_finalize(stmt);
        try self.scoped(stmt, 1); try sql.bindInt(stmt, 2, if (empty) 1 else 0); try sql.bindInt(stmt, 3, @intCast(self.offset));
        var threads: std.ArrayList(catalog.Thread) = .empty;
        errdefer { for (threads.items) |*thread| thread.deinit(); threads.deinit(allocator); }
        var more = false;
        while (try row(stmt)) {
            if (threads.items.len == 32) { more = true; break; }
            var thread: catalog.Thread = .{ .path = try allocator.dupeZ(u8, sql.column(stmt, 0)), .cwd = try allocator.dupeZ(u8, sql.column(stmt, 1)), .title = try allocator.dupe(u8, sql.column(stmt, 2)), .modified = c.sqlite3_column_int64(stmt, 3), .archived = c.sqlite3_column_int(stmt, 4) != 0 };
            errdefer thread.deinit();
            const file = std.Io.Dir.cwd().openFile(io, thread.path, .{}) catch null;
            thread.available = file != null;
            if (file) |f| f.close(io);
            if (c.sqlite3_column_type(stmt, 5) != c.SQLITE_NULL) thread.snippet = try self.excerpt(c.sqlite3_column_int64(stmt, 5), sql.column(stmt, 6));
            try threads.append(allocator, thread);
        }
        var warning: ?anyerror = if (self.scope == .import_pi) null else self.warning;
        if (warning == null and self.scope != .import_pi) {
            const incomplete = try self.db.prepare("SELECT 1 FROM workspace_chats w JOIN search_sources x USING(session_file) WHERE x.incomplete=1 AND (?1!=1 OR w.archived=1) LIMIT 1");
            defer _ = c.sqlite3_finalize(incomplete);
            try self.scoped(incomplete, 1);
            if (try row(incomplete)) warning = error.IncompleteSource;
        }
        return .{ .threads = try threads.toOwnedSlice(allocator), .scope = self.scope, .offset = self.offset, .generation = self.generation, .more = more and self.complete, .searching = !self.complete, .indexing = indexing, .warning = warning };
    }
    fn excerpt(self: *Engine, id: i64, term: []const u8) ![]u8 {
        const stmt = try self.db.prepare("SELECT text FROM search_segments WHERE rowid=?1"); defer _ = c.sqlite3_finalize(stmt);
        try sql.bindInt(stmt, 1, id); if (!try row(stmt)) return allocator.dupe(u8, "");
        const text = sql.column(stmt, 0);
        var find: Excerpt = .{ .term = term };
        if (self.methods.xTokenize.?(self.tokenizer, &find, c.FTS5_TOKENIZE_DOCUMENT, text.ptr, @intCast(text.len), Excerpt.callback) != c.SQLITE_OK) return error.SearchTokenizationFailed;
        if (!find.found) return allocator.dupe(u8, "");
        var start = if (find.start > 80) find.start - 80 else 0;
        while (start < text.len and text[start] & 0xc0 == 0x80) : (start += 1) {}
        var end = @min(text.len, start + 320);
        while (end > start and !std.unicode.utf8ValidateSlice(text[start..end])) : (end -= 1) {}
        return allocator.dupe(u8, text[start..end]);
    }
    pub fn syncMetadata(self: *Engine, after: []const u8) !?[]u8 {
        try self.db.exec("BEGIN IMMEDIATE");
        errdefer self.db.exec("ROLLBACK") catch {};
        const stmt = try self.db.prepare("SELECT i.session_file,i.title,i.cwd FROM session_index i WHERE i.session_file>?1 AND (NOT EXISTS(SELECT 1 FROM search_segments s WHERE s.session_file=i.session_file AND s.generation=0 AND s.field=0 AND s.text=i.title) OR NOT EXISTS(SELECT 1 FROM search_segments s WHERE s.session_file=i.session_file AND s.generation=0 AND s.field=1 AND s.text=i.cwd||' '||i.session_file)) ORDER BY i.session_file LIMIT 128"); defer _ = c.sqlite3_finalize(stmt);
        try sql.bindText(stmt, 1, after);
        var cursor: ?[]u8 = null; errdefer if (cursor) |v| allocator.free(v);
        while (try row(stmt)) {
            const path = sql.column(stmt, 0);
            const clear_fts = try self.db.prepare("DELETE FROM search_fts WHERE rowid IN (SELECT rowid FROM search_segments WHERE session_file=?1 AND generation=0)"); defer _ = c.sqlite3_finalize(clear_fts);
            try sql.bindText(clear_fts, 1, path); try sql.done(clear_fts);
            const clear = try self.db.prepare("DELETE FROM search_segments WHERE session_file=?1 AND generation=0"); defer _ = c.sqlite3_finalize(clear);
            try sql.bindText(clear, 1, path); try sql.done(clear);
            for (0..2) |field| {
                const insert = try self.db.prepare("INSERT INTO search_segments(session_file,generation,entry_id,field,text) VALUES(?1,0,'',?2,?3)"); defer _ = c.sqlite3_finalize(insert);
                try sql.bindText(insert, 1, path); try sql.bindInt(insert, 2, @intCast(field));
                const location = if (field == 1) try std.fmt.allocPrint(allocator, "{s} {s}", .{ sql.column(stmt, 2), path }) else null; defer if (location) |v| allocator.free(v);
                try sql.bindText(insert, 3, location orelse sql.column(stmt, 1)); try sql.done(insert);
                const fts = try self.db.prepare("INSERT INTO search_fts(rowid,text) SELECT rowid,text FROM search_segments WHERE rowid=?1"); defer _ = c.sqlite3_finalize(fts);
                try sql.bindInt(fts, 1, c.sqlite3_last_insert_rowid(self.db.handle)); try sql.done(fts);
            }
            if (cursor) |v| allocator.free(v); cursor = try allocator.dupe(u8, path);
        }
        try self.db.exec("COMMIT");
        if (cursor != null) self.dirty = true;
        return cursor;
    }
};
const Excerpt = struct {
    term: []const u8, start: usize = 0, found: bool = false,
    fn callback(ctx: ?*anyopaque, _: c_int, bytes: [*c]const u8, length: c_int, start: c_int, _: c_int) callconv(.c) c_int {
        const self: *Excerpt = @ptrCast(@alignCast(ctx.?));
        if (!self.found and std.mem.eql(u8, self.term, bytes[0..@as(usize,@intCast(length))])) { self.start = @intCast(start); self.found = true; }
        return c.SQLITE_OK;
    }
};
pub fn row(stmt: *c.sqlite3_stmt) !bool { const rc = c.sqlite3_step(stmt); if (rc == c.SQLITE_ROW) return true; if (rc == c.SQLITE_DONE) return false; return error.SqliteFailure; }

fn syncAll(engine: *Engine) !void {
    var cursor: []u8 = &.{};
    defer allocator.free(cursor);
    while (try engine.syncMetadata(cursor)) |next| {
        allocator.free(cursor); cursor = next;
    }
}
fn finishQuery(engine: *Engine, scope: catalog.Scope, query: []const u8, offset: usize, generation: u64) !catalog.SearchPage {
    try engine.begin(scope, query, offset, generation);
    while (!try engine.step()) {}
    return engine.page(std.testing.io);
}
fn seedBody(engine: *Engine, path: []const u8, text: []const u8, generation: i64) !void {
    const src = try engine.db.prepare("INSERT INTO search_sources(session_file,generation,size,mtime,identity,leaf,available,incomplete) VALUES(?1,?2,0,'0','0','leaf',1,0) ON CONFLICT(session_file) DO UPDATE SET generation=excluded.generation");
    defer _ = c.sqlite3_finalize(src);
    try sql.bindText(src, 1, path); try sql.bindInt(src, 2, generation); try sql.done(src);
    const segment = try engine.db.prepare("INSERT INTO search_segments(session_file,generation,entry_id,field,text) VALUES(?1,?2,'leaf',2,?3)");
    defer _ = c.sqlite3_finalize(segment);
    try sql.bindText(segment, 1, path); try sql.bindInt(segment, 2, generation); try sql.bindText(segment, 3, text); try sql.done(segment);
    const fts = try engine.db.prepare("INSERT INTO search_fts(rowid,text) SELECT rowid,text FROM search_segments WHERE rowid=?1");
    defer _ = c.sqlite3_finalize(fts);
    try sql.bindInt(fts, 1, c.sqlite3_last_insert_rowid(engine.db.handle)); try sql.done(fts);
    engine.dirty = true;
}

test "fuzzy library searches all metadata and paginates distinct scoped chats" {
    const store = @import("store.zig");
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{root, "search.sqlite"});
    defer std.testing.allocator.free(path);
    var db = try store.Store.init(allocator, path); defer db.deinit();
    const engine = try allocator.create(Engine); defer allocator.destroy(engine);
    engine.* = try Engine.init(path); defer engine.deinit();
    for (0..42) |i| {
        const name = try std.fmt.allocPrint(allocator, "/project/chat-{d:0>3}.jsonl", .{i});
        defer allocator.free(name);
        try db.enroll(.{ .session_file = name, .cwd = "/project", .title = "Sidebar settings panel", .modified = @intCast(1000-i) });
    }
    try db.enroll(.{ .session_file = "/project/exact.jsonl", .cwd = "/project", .title = "configuration", .modified = -100 });
    try db.enroll(.{ .session_file = "/project/weak.jsonl", .cwd = "/project", .title = "configuraton", .modified = 9999 });
    try db.putSessionIndex(.{ .session_file = "/outside/nonmember.jsonl", .cwd = "/outside", .title = "Sidebar settings panel", .modified = 99999 });
    try db.setArchived("/project/chat-041.jsonl", true);
    try syncAll(engine);
    var first = try finishQuery(engine, .workspace, "sbr stngs pnl", 0, 1); defer first.deinit();
    try std.testing.expectEqual(@as(usize, 32), first.threads.len);
    try std.testing.expect(first.more);
    try std.testing.expectEqualStrings("/project/chat-000.jsonl", first.threads[0].path);
    var second = try finishQuery(engine, .workspace, "sbr stngs pnl", 32, 2); defer second.deinit();
    try std.testing.expectEqual(@as(usize, 10), second.threads.len);
    try std.testing.expectEqualStrings("/project/chat-041.jsonl", second.threads[9].path);
    try std.testing.expect(second.threads[9].archived);
    var archives = try finishQuery(engine, .archives, "sbr stngs pnl", 0, 3); defer archives.deinit();
    try std.testing.expectEqual(@as(usize, 1), archives.threads.len);
    try std.testing.expectEqualStrings("/project/chat-041.jsonl", archives.threads[0].path);
    var imported = try finishQuery(engine, .import_pi, "sbr stngs pnl", 0, 4); defer imported.deinit();
    try std.testing.expectEqual(@as(usize, 1), imported.threads.len);
    try std.testing.expectEqualStrings("/outside/nonmember.jsonl", imported.threads[0].path);
    var ranked = try finishQuery(engine, .workspace, "configuration", 0, 5); defer ranked.deinit();
    try std.testing.expectEqualStrings("/project/exact.jsonl", ranked.threads[0].path);
    var typo = try finishQuery(engine, .archives, "setings", 0, 6); defer typo.deinit();
    try std.testing.expectEqualStrings("/project/chat-041.jsonl", typo.threads[0].path);
}

test "fuzzy postings preserve excerpts Unicode scope terms and generation replacement" {
    const store = @import("store.zig");
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{root, "search.sqlite"});
    defer std.testing.allocator.free(path);
    var db = try store.Store.init(allocator, path); defer db.deinit();
    const engine = try allocator.create(Engine); defer allocator.destroy(engine);
    engine.* = try Engine.init(path); defer engine.deinit();
    try db.enroll(.{ .session_file = "/a/member.jsonl", .cwd = "/a", .title = "Plain conversation", .modified = 10 });
    try db.putSessionIndex(.{ .session_file = "/b/nonmember.jsonl", .cwd = "/b", .title = "Other conversation", .modified = 20 });
    try syncAll(engine);
    try seedBody(engine, "/a/member.jsonl", "A real settings excerpt with CAFÉ and résumé", 1);
    try seedBody(engine, "/a/member.jsonl", "Another segment with lighthouse", 1);
    try seedBody(engine, "/b/nonmember.jsonl", "settings hidden nonmember", 1);
    var fuzzy = try finishQuery(engine, .workspace, "setings", 0, 1); defer fuzzy.deinit();
    try std.testing.expectEqual(@as(usize, 1), fuzzy.threads.len);
    try std.testing.expectEqualStrings("/a/member.jsonl", fuzzy.threads[0].path);
    try std.testing.expect(std.mem.indexOf(u8, fuzzy.threads[0].snippet, "settings") != null);
    var across = try finishQuery(engine, .workspace, "cafe lighthouse", 0, 2); defer across.deinit();
    try std.testing.expectEqualStrings("/a/member.jsonl", across.threads[0].path);
    var unicode = try finishQuery(engine, .workspace, "resme", 0, 3); defer unicode.deinit();
    try std.testing.expect(std.mem.indexOf(u8, unicode.threads[0].snippet, "résumé") != null);
    try db.setArchived("/a/member.jsonl", true); engine.dirty = true;
    var archived = try finishQuery(engine, .archives, "setings", 0, 4); defer archived.deinit();
    try std.testing.expect(archived.threads[0].archived);
    var injection = try finishQuery(engine, .workspace, "\" OR NEAR *", 0, 5); defer injection.deinit();
    try std.testing.expectEqual(@as(usize, 0), injection.threads.len);
    var punctuation = try finishQuery(engine, .workspace, "***", 0, 6); defer punctuation.deinit();
    try std.testing.expectEqual(@as(usize, 0), punctuation.threads.len);
    try engine.begin(.workspace, "setings", 0, 7);
    _ = try engine.step();
    try engine.begin(.workspace, "lighthouse", 0, 8);
    while (!try engine.step()) {}
    var replacement = try engine.page(std.testing.io); defer replacement.deinit();
    try std.testing.expectEqual(@as(u64, 8), replacement.generation);
    try std.testing.expect(!replacement.searching);
    try std.testing.expect(std.mem.indexOf(u8, replacement.threads[0].snippet, "lighthouse") != null);
    try seedBody(engine, "/a/member.jsonl", "Rewritten content without old words", 2);
    var removed = try finishQuery(engine, .workspace, "settings", 0, 9); defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 0), removed.threads.len);
}

test "in flight source publications rerank before exposing a stable generation" {
    const store = @import("store.zig");
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator); defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "search.sqlite" }); defer allocator.free(path);
    var db = try store.Store.init(allocator, path); defer db.deinit();
    const engine = try allocator.create(Engine); defer allocator.destroy(engine);
    engine.* = try Engine.init(path); defer engine.deinit();
    try db.enroll(.{ .session_file = "/offline/body.jsonl", .cwd = "/offline", .title = "Neutral", .modified = 1 });
    try db.enroll(.{ .session_file = "/offline/title.jsonl", .cwd = "/offline", .title = "settings", .modified = 2 });
    try syncAll(engine);
    try engine.begin(.workspace, "settings", 0, 41);
    _ = try engine.step();
    var partial = try engine.page(std.testing.io); defer partial.deinit();
    try std.testing.expect(partial.searching);
    try std.testing.expectEqual(@as(usize, 0), partial.threads.len);
    try std.testing.expect(!partial.more);
    // Publish a word after vocabulary scanning has passed its lexical position.
    while (!engine.vocabulary_done) _ = try engine.step();
    try seedBody(engine, "/offline/body.jsonl", "actual settings sentinel", 1);
    var steps: usize = 0;
    while (!try engine.step()) {
        steps += 1;
        try std.testing.expect(steps < 64);
    }
    var finished = try engine.page(std.testing.io); defer finished.deinit();
    try std.testing.expectEqual(@as(u64, 41), finished.generation);
    try std.testing.expect(!finished.searching);
    try std.testing.expectEqual(@as(usize, 2), finished.threads.len);
    try std.testing.expectEqualStrings("/offline/title.jsonl", finished.threads[0].path);
    try std.testing.expectEqualStrings("/offline/body.jsonl", finished.threads[1].path);
    try std.testing.expectEqualStrings("actual settings sentinel", finished.threads[1].snippet);
    try std.testing.expect(!finished.threads[1].available);
    // Unchanged metadata synchronization must not invalidate completed ranking.
    try std.testing.expectEqual(@as(?[]u8, null), try engine.syncMetadata(""));
    try std.testing.expect(!engine.dirty);
}

test "matching body excerpts survive stronger metadata ranking and archive scope" {
    const store = @import("store.zig");
    var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator); defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "search.sqlite" }); defer allocator.free(path);
    var db = try store.Store.init(allocator, path); defer db.deinit();
    const engine = try allocator.create(Engine); defer allocator.destroy(engine);
    engine.* = try Engine.init(path); defer engine.deinit();
    try db.enroll(.{ .session_file = "/offline/mixed.jsonl", .cwd = "/offline", .title = "settings", .modified = 1 });
    try db.setArchived("/offline/mixed.jsonl", true);
    try syncAll(engine);
    try seedBody(engine, "/offline/mixed.jsonl", "unrelated first segment", 1);
    try seedBody(engine, "/offline/mixed.jsonl", "The settings body sentinel", 1);
    try seedBody(engine, "/offline/mixed.jsonl", "A second settings body segment", 1);
    var page = try finishQuery(engine, .archives, "settings", 0, 1); defer page.deinit();
    try std.testing.expectEqual(@as(usize, 1), page.threads.len);
    try std.testing.expectEqualStrings("/offline/mixed.jsonl", page.threads[0].path);
    try std.testing.expect(page.threads[0].archived);
    try std.testing.expect(!page.threads[0].available);
    try std.testing.expectEqualStrings("The settings body sentinel", page.threads[0].snippet);
    var imported = try finishQuery(engine, .import_pi, "settings", 0, 2); defer imported.deinit();
    try std.testing.expectEqual(@as(usize, 0), imported.threads.len);
}
