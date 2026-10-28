//! One-writer SQLite boundary. No legacy paths, provider calls, UI or automatic retries.
const std = @import("std");
const t = @import("types.zig");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
extern fn spica_database_bind_text(?*c.sqlite3_stmt, c_int, [*]const u8, c_int) c_int;
extern fn spica_database_bind_blob(?*c.sqlite3_stmt, c_int, [*]const u8, c_int) c_int;
extern fn spica_store_sync_ancestry([*:0]const u8) c_int;

pub const Error = error{ Busy, Full, OutOfMemory, Corrupt, UnsupportedStore, Storage, Limit, Conflict, InvalidText, Closed };
pub const application_id = 0x53504334;
pub const schema_version = 13;
pub const Value = union(enum) { null, integer: i64, text: []const u8, blob: []const u8 };

pub const Statement = struct {
    raw: *c.sqlite3_stmt,
    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.raw);
    }
    pub fn step(self: Statement) Error!bool {
        return switch (c.sqlite3_step(self.raw)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |rc| translate(rc),
        };
    }
    pub fn integer(self: Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.raw, column);
    }
    /// Borrowed until next step/finalize. Empty is distinct from SQL NULL via isNull.
    pub fn bytes(self: Statement, column: c_int) Error![]const u8 {
        const ptr = c.sqlite3_column_blob(self.raw, column);
        const len = c.sqlite3_column_bytes(self.raw, column);
        if (len < 0) return error.Corrupt;
        if (ptr == null) {
            if (c.sqlite3_errcode(c.sqlite3_db_handle(self.raw)) == c.SQLITE_NOMEM) return error.OutOfMemory;
            if (len != 0) return error.Corrupt;
            return "";
        }
        return @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
    }
    pub fn isNull(self: Statement, column: c_int) bool {
        return c.sqlite3_column_type(self.raw, column) == c.SQLITE_NULL;
    }
};

pub const Store = struct {
    database: *c.sqlite3,
    lock: std.Io.File,
    io: std.Io,
    in_transaction: bool = false,
    closed: bool = false,

    /// The explicit directory is the only location touched. Caller owns this value
    /// on one thread; the advisory lock excludes a second cooperative owner.
    pub fn open(io: std.Io, state_dir: []const u8) !Store {
        if (std.mem.indexOfScalar(u8, state_dir, 0) != null) return error.InvalidPath;
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{ .permissions = .fromMode(0o700) });
        defer dir.close(io);
        const lock = try dir.createFile(io, "owner.lock", .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) });
        errdefer lock.close(io);
        var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try dir.realPath(io, &directory);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/conversation.sqlite3", .{directory[0..n]});
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOFOLLOW, null);
        errdefer if (db) |database| {
            _ = c.sqlite3_close(database);
        };
        try check(rc);
        const database = db orelse return error.Storage;
        try check(c.sqlite3_extended_result_codes(database, 1));
        try check(c.sqlite3_busy_timeout(database, 100));
        var result: Store = .{ .database = database, .lock = lock, .io = io };
        const identity = try result.scalar("PRAGMA application_id");
        const version = try result.scalar("PRAGMA user_version");
        const tables = try result.scalar("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'");
        const fresh = identity == 0 and version == 0 and tables == 0;
        // Do not mutate unknown/legacy databases, including user_version=6.
        if (!fresh and (identity != application_id or version < 1 or version > schema_version)) return error.UnsupportedStore;
        if (!fresh) {
            if (try result.scalar("SELECT schema_version FROM meta WHERE singleton=1") != version) return error.Corrupt;
            // Attachment tables are introduced by the v7 migration below;
            // older accepted stores must reach that migration first.
            if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN('meta','commands','projects','workspaces','sessions','threads','runs','messages','blocks','chunks','tools','approvals','effects','observations','events')") != 15) return error.Corrupt;
        }
        // WAL initialization precedes readers and the writer's first transaction.
        {
            var statement = try result.prepare("PRAGMA journal_mode=WAL", &.{});
            defer statement.deinit();
            if (!try statement.step() or !std.mem.eql(u8, try statement.bytes(0), "wal")) return error.Storage;
        }
        try result.exec("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA mmap_size=0; PRAGMA cache_size=-2048; PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=256");
        if (try result.scalar("PRAGMA foreign_keys") != 1 or try result.scalar("PRAGMA synchronous") != 2) return error.Storage;
        if (fresh) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec(schema);
            try result.exec("PRAGMA application_id=1397769012; PRAGMA user_version=1");
            // Keep the constant and on-disk application identity in lockstep.
            if (try result.scalar("PRAGMA application_id") != application_id) return error.Corrupt;
            try result.exec("COMMIT");
        }
        if (fresh or version == 1) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec("CREATE TABLE runtime_blocks(session_id TEXT NOT NULL REFERENCES sessions(id),upstream_message TEXT NOT NULL,upstream_block TEXT NOT NULL,block_id TEXT NOT NULL UNIQUE REFERENCES blocks(id),PRIMARY KEY(session_id,upstream_message,upstream_block)); UPDATE meta SET schema_version=2 WHERE singleton=1; PRAGMA user_version=2");
            try result.exec("COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='runtime_blocks'") != 1) return error.Corrupt;
        if (fresh or version < 3) {
            try result.exec("PRAGMA foreign_keys=OFF; BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK; PRAGMA foreign_keys=ON") catch {};
            try result.exec(task_schema);
            try result.exec("UPDATE meta SET schema_version=3 WHERE singleton=1; PRAGMA user_version=3; COMMIT; PRAGMA foreign_keys=ON");
        }
        // Commands record intent; only successful explicit configuration is
        // restored. Two supported runtime keys bound retained setup state.
        try result.exec("CREATE TABLE IF NOT EXISTS runtime_configurations(runtime_kind TEXT PRIMARY KEY CHECK(runtime_kind IN('codex','opencode')),configuration BLOB NOT NULL CHECK(length(configuration)<=32768))");
        if (fresh or version < 4) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec("CREATE TABLE IF NOT EXISTS runtime_preferences(singleton INTEGER PRIMARY KEY CHECK(singleton=1),active_runtime_kind TEXT NOT NULL REFERENCES runtime_configurations(runtime_kind)); INSERT OR IGNORE INTO runtime_preferences SELECT 1,runtime_kind FROM runtime_configurations ORDER BY runtime_kind DESC LIMIT 1; UPDATE meta SET schema_version=4 WHERE singleton=1; PRAGMA user_version=4; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='runtime_preferences'") != 1) return error.Corrupt;
        if (fresh or version < 5) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec(prompt_schema);
            try result.exec("UPDATE meta SET schema_version=5 WHERE singleton=1; PRAGMA user_version=5; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN('prompt_uploads','prompt_chunks')") != 2) return error.Corrupt;
        if (fresh or version < 6) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name='title'") == 0)
                try result.exec("ALTER TABLE threads ADD COLUMN title TEXT NOT NULL DEFAULT ''");
            try result.exec("UPDATE meta SET schema_version=6 WHERE singleton=1; PRAGMA user_version=6; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name='title'") != 1) return error.Corrupt;
        if (fresh or version < 7) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec(attachment_schema);
            try result.exec("UPDATE meta SET schema_version=7 WHERE singleton=1; PRAGMA user_version=7; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN('attachments','attachment_refs')") != 2) return error.Corrupt;
        if (fresh or version < 8) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec(question_schema);
            try result.exec("UPDATE meta SET schema_version=8 WHERE singleton=1; PRAGMA user_version=8; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='questions'") != 1) return error.Corrupt;
        if (fresh or version < 9) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            // The migration preserves all thread revisions and accepted work.
            // Negative creation ordinals put new threads first without reading history.
            if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name='pinned'") == 0) {
                if (try result.scalar("SELECT coalesce(max(rowid),0) FROM threads") > @divTrunc(std.math.maxInt(i64), 1024)) return error.Limit;
                try result.exec("ALTER TABLE threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN(0,1)); ALTER TABLE threads ADD COLUMN settled INTEGER NOT NULL DEFAULT 0 CHECK(settled IN(0,1)); ALTER TABLE threads ADD COLUMN snoozed_until INTEGER NOT NULL DEFAULT 0 CHECK(snoozed_until>=0); ALTER TABLE threads ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0; UPDATE threads SET sort_order=-rowid*1024");
            }
            try result.exec("UPDATE meta SET schema_version=9 WHERE singleton=1; PRAGMA user_version=9; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name IN('pinned','settled','snoozed_until','sort_order')") != 4) return error.Corrupt;
        try result.exec("CREATE INDEX IF NOT EXISTS threads_sidebar_order ON threads(-pinned,sort_order,id); CREATE INDEX IF NOT EXISTS threads_project_sidebar_order ON threads(project_id,-pinned,sort_order,id); CREATE INDEX IF NOT EXISTS threads_sidebar_move ON threads(sort_order,id)");
        if (fresh or version < 10) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            // Old histories have no trustworthy wall clock; zero stays unknown.
            if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name='created_at_ms'") == 0)
                try result.exec("ALTER TABLE threads ADD COLUMN created_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(created_at_ms>=0); ALTER TABLE threads ADD COLUMN last_user_message_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(last_user_message_at_ms>=0); ALTER TABLE threads ADD COLUMN updated_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(updated_at_ms>=0)");
            try result.exec("UPDATE meta SET schema_version=10 WHERE singleton=1; PRAGMA user_version=10; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name IN('created_at_ms','last_user_message_at_ms','updated_at_ms')") != 3) return error.Corrupt;
        if (fresh or version < 11) {
            try result.exec("BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK") catch {};
            try result.exec("CREATE TABLE IF NOT EXISTS presentation_state(key TEXT PRIMARY KEY CHECK(length(key) BETWEEN 1 AND 128),value BLOB NOT NULL CHECK(length(value)<=4096)); UPDATE meta SET schema_version=11 WHERE singleton=1; PRAGMA user_version=11; COMMIT");
        } else if (try result.scalar("SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='presentation_state'") != 1) return error.Corrupt;
        if (fresh or version < 12) {
            // Input ownership is immutable provenance. Rebuild the two small
            // input tables so every row carries its thread directly; a join
            // mismatch aborts the migration before any old table is dropped.
            try result.exec("PRAGMA foreign_keys=OFF; BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK; PRAGMA foreign_keys=ON") catch {};
            if (try result.scalar("SELECT count(*) FROM approvals") != try result.scalar("SELECT count(*) FROM approvals a JOIN runs r ON r.id=a.run_id WHERE r.thread_id IS NOT NULL")) return error.Corrupt;
            if (try result.scalar("SELECT count(*) FROM questions") != try result.scalar("SELECT count(*) FROM questions q JOIN runs r ON r.id=q.run_id WHERE r.thread_id IS NOT NULL")) return error.Corrupt;
            try result.exec(input_owner_migration);
            try result.exec("UPDATE meta SET schema_version=12 WHERE singleton=1; PRAGMA user_version=12; COMMIT; PRAGMA foreign_keys=ON");
        } else if (try result.scalar("SELECT count(*) FROM pragma_table_info('approvals') WHERE name='thread_id'") != 1 or try result.scalar("SELECT count(*) FROM pragma_table_info('questions') WHERE name='thread_id'") != 1) return error.Corrupt;
        if (fresh or version < 13) {
            try result.exec("PRAGMA foreign_keys=OFF; BEGIN IMMEDIATE");
            errdefer result.exec("ROLLBACK; PRAGMA foreign_keys=ON") catch {};
            if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name='root_key'") == 0) try result.exec("ALTER TABLE threads ADD COLUMN root_key BLOB");
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const rows = try result.prepare("SELECT t.id,w.binding FROM threads t JOIN workspaces w ON w.id=t.workspace_id", &.{});
            defer rows.deinit();
            var seen: i64 = 0;
            while (try rows.step()) {
                const binding = t.decode(t.WorkspaceBinding, try rows.bytes(1), arena.allocator()) catch return error.Corrupt;
                if (binding.canonical_root.len == 0 or !std.unicode.utf8ValidateSlice(binding.canonical_root)) return error.Corrupt;
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(binding.canonical_root, &digest, .{});
                try result.execute("UPDATE threads SET root_key=? WHERE id=?", &.{ .{ .blob = &digest }, .{ .text = try rows.bytes(0) } });
                seen += 1;
            }
            if (seen != try result.scalar("SELECT count(*) FROM threads")) return error.Corrupt;
            if (try result.scalar("SELECT count(*) FROM threads WHERE root_key IS NULL OR length(root_key)<>32") != 0) return error.Corrupt;
            try result.exec("UPDATE meta SET schema_version=13 WHERE singleton=1; PRAGMA user_version=13; COMMIT; PRAGMA foreign_keys=ON");
        } else if (try result.scalar("SELECT count(*) FROM pragma_table_info('threads') WHERE name='root_key'") != 1 or try result.scalar("SELECT count(*) FROM threads WHERE root_key IS NULL OR length(root_key)<>32") != 0) return error.Corrupt;
        // Staging budgets exclude sent history; lookup by attachment must not
        // scan all message refs for every historical row in the thread.
        try result.exec("CREATE INDEX IF NOT EXISTS attachment_refs_by_attachment ON attachment_refs(attachment_id)");
        try result.exec("CREATE TABLE IF NOT EXISTS thread_selections(thread_id TEXT PRIMARY KEY REFERENCES threads(id),selection BLOB NOT NULL CHECK(length(selection)<=16384))");
        // The implicit rowid suffix supports latest selection/status lookups
        // without scanning completed runs from other threads.
        try result.exec("CREATE INDEX IF NOT EXISTS runs_by_thread ON runs(thread_id)");
        try result.exec("CREATE INDEX IF NOT EXISTS threads_root_order ON threads(root_key,-pinned,sort_order,id); CREATE INDEX IF NOT EXISTS threads_root_project_order ON threads(root_key,project_id,-pinned,sort_order,id)");
        try result.exec("CREATE TRIGGER IF NOT EXISTS threads_root_immutable BEFORE UPDATE OF root_key ON threads WHEN NEW.root_key IS NULL OR length(NEW.root_key)<>32 OR NEW.root_key<>OLD.root_key BEGIN SELECT RAISE(ABORT,'thread root key immutable'); END;");
        try result.exec("CREATE INDEX IF NOT EXISTS runs_snooze_pending ON runs(thread_id) WHERE state IN('queued','starting','awaiting_approval','awaiting_question'); CREATE INDEX IF NOT EXISTS approvals_pending_thread ON approvals(thread_id) WHERE state='pending'; CREATE INDEX IF NOT EXISTS questions_pending_thread ON questions(thread_id) WHERE state='pending'; CREATE INDEX IF NOT EXISTS approvals_by_run ON approvals(run_id,id); CREATE INDEX IF NOT EXISTS questions_by_run ON questions(run_id,id)");
        try result.exec("CREATE TRIGGER IF NOT EXISTS approvals_owner_insert BEFORE INSERT ON approvals WHEN (SELECT thread_id FROM runs WHERE id=NEW.run_id) IS NULL OR NEW.thread_id<>(SELECT thread_id FROM runs WHERE id=NEW.run_id) BEGIN SELECT RAISE(ABORT,'approval thread owner mismatch'); END; CREATE TRIGGER IF NOT EXISTS questions_owner_insert BEFORE INSERT ON questions WHEN (SELECT thread_id FROM runs WHERE id=NEW.run_id) IS NULL OR NEW.thread_id<>(SELECT thread_id FROM runs WHERE id=NEW.run_id) BEGIN SELECT RAISE(ABORT,'question thread owner mismatch'); END; CREATE TRIGGER IF NOT EXISTS approvals_owner_immutable BEFORE UPDATE OF run_id,thread_id ON approvals WHEN NEW.run_id<>OLD.run_id OR NEW.thread_id<>OLD.thread_id OR NEW.thread_id<>(SELECT thread_id FROM runs WHERE id=NEW.run_id) BEGIN SELECT RAISE(ABORT,'approval thread owner immutable'); END; CREATE TRIGGER IF NOT EXISTS questions_owner_immutable BEFORE UPDATE OF run_id,thread_id ON questions WHEN NEW.run_id<>OLD.run_id OR NEW.thread_id<>OLD.thread_id OR NEW.thread_id<>(SELECT thread_id FROM runs WHERE id=NEW.run_id) BEGIN SELECT RAISE(ABORT,'question thread owner immutable'); END;");
        // Only diagnostic observations enter this index; streamed content never
        // accumulates in the run-status lookup. Correlation was normalized by Owner.
        try result.exec("CREATE INDEX IF NOT EXISTS observation_diagnostics ON observations(session_id,json_extract(CAST(correlation AS TEXT),'$.run.value'),commit_sequence DESC) WHERE evidence IS NOT NULL");
        const dir_z = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory[0..n]});
        if (spica_store_sync_ancestry(dir_z.ptr) != 0) return error.Storage;
        // Bounds per row and SQL statement, not a claimed total C/RSS/disk ceiling.
        _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_LENGTH, 1024 * 1024);
        _ = c.sqlite3_limit(database, c.SQLITE_LIMIT_SQL_LENGTH, 64 * 1024);
        try result.installChangeJournal();
        return result;
    }
    /// Save successful setup and active routing atomically. The catalog and
    /// per-thread selections are separate state and are never inferred here.
    pub fn saveRuntimeConfiguration(self: *Store, kind: []const u8, configuration: []const u8) !void {
        try self.begin();
        errdefer self.rollback() catch {};
        try self.execute("INSERT INTO runtime_configurations VALUES(?,?) ON CONFLICT(runtime_kind) DO UPDATE SET configuration=excluded.configuration", &.{ .{ .text = kind }, .{ .blob = configuration } });
        try self.execute("INSERT INTO runtime_preferences VALUES(1,?) ON CONFLICT(singleton) DO UPDATE SET active_runtime_kind=excluded.active_runtime_kind", &.{.{ .text = kind }});
        try self.commit();
    }
    /// Opaque UI-owned values, deliberately outside the execution journal.
    pub fn savePresentation(self: *Store, key: []const u8, value: []const u8) Error!void {
        if (key.len == 0 or key.len > 128 or value.len > 4096) return error.Limit;
        if (!std.unicode.utf8ValidateSlice(key) or std.mem.indexOfScalar(u8, key, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        try self.execute("INSERT INTO presentation_state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", &.{ .{ .text = key }, .{ .blob = value } });
    }
    pub fn loadPresentation(self: *Store, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        if (key.len == 0 or key.len > 128) return error.Limit;
        if (!std.unicode.utf8ValidateSlice(key) or std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidText;
        const statement = try self.prepare("SELECT value FROM presentation_state WHERE key=?", &.{.{ .text = key }});
        defer statement.deinit();
        if (!try statement.step()) return null;
        const bytes = try statement.bytes(0);
        if (bytes.len > 4096) return error.Corrupt;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidText;
        return try allocator.dupe(u8, bytes);
    }
    pub fn close(self: *Store) Error!void {
        if (self.closed) return;
        if (self.in_transaction) try self.rollback();
        try check(c.sqlite3_close(self.database));
        self.closed = true;
        self.lock.close(self.io);
    }
    pub fn prepare(self: *Store, sql: [:0]const u8, values: []const Value) Error!Statement {
        if (self.closed) return error.Closed;
        var ptr: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(self.database, sql.ptr, @intCast(sql.len + 1), &ptr, null));
        const statement = ptr orelse return error.Storage;
        errdefer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_bind_parameter_count(statement) != values.len) return error.Limit;
        for (values, 1..) |value, index| {
            const i: c_int = @intCast(index);
            const rc = switch (value) {
                .null => c.sqlite3_bind_null(statement, i),
                .integer => |v| c.sqlite3_bind_int64(statement, i, v),
                .text => |v| if (v.len > std.math.maxInt(c_int)) return error.Limit else spica_database_bind_text(statement, i, v.ptr, @intCast(v.len)),
                .blob => |v| if (v.len > std.math.maxInt(c_int)) return error.Limit else spica_database_bind_blob(statement, i, v.ptr, @intCast(v.len)),
            };
            try check(rc);
        }
        return .{ .raw = statement };
    }
    pub fn exec(self: *Store, sql: [:0]const u8) Error!void {
        if (self.closed) return error.Closed;
        const rc = c.sqlite3_exec(self.database, sql.ptr, null, null, null);
        self.in_transaction = c.sqlite3_get_autocommit(self.database) == 0;
        try check(rc);
    }
    pub fn execute(self: *Store, sql: [:0]const u8, values: []const Value) Error!void {
        const statement = try self.prepare(sql, values);
        defer statement.deinit();
        defer self.in_transaction = c.sqlite3_get_autocommit(self.database) == 0;
        if (try statement.step()) return error.Storage;
    }
    pub fn scalar(self: *Store, sql: [:0]const u8) Error!i64 {
        const statement = try self.prepare(sql, &.{});
        defer statement.deinit();
        if (!try statement.step()) return error.Corrupt;
        return statement.integer(0);
    }
    pub fn begin(self: *Store) Error!void {
        if (self.in_transaction) return error.Conflict;
        try self.exec("BEGIN IMMEDIATE");
        try self.exec("DELETE FROM aggregate_changes");
        self.in_transaction = true;
    }
    pub fn commit(self: *Store) Error!void {
        if (!self.in_transaction) return error.Conflict;
        self.exec("COMMIT") catch |err| {
            // FULL/IOERR/NOMEM may have rolled back automatically. COMMIT BUSY
            // can leave the transaction active. Caller must not infer rejection.
            self.in_transaction = c.sqlite3_get_autocommit(self.database) == 0;
            return err;
        };
        self.in_transaction = false;
    }
    pub fn rollback(self: *Store) Error!void {
        if (c.sqlite3_get_autocommit(self.database) != 0) {
            self.in_transaction = false;
            return;
        }
        try self.exec("ROLLBACK");
        self.in_transaction = false;
    }
    pub fn nextSequence(self: *Store) Error!u64 {
        if (!self.in_transaction) return error.Conflict;
        const current = try self.scalar("SELECT next_sequence FROM meta WHERE singleton=1");
        if (current <= 0 or current == std.math.maxInt(i64)) return error.Limit;
        try self.execute("UPDATE meta SET next_sequence=? WHERE singleton=1", &.{.{ .integer = current + 1 }});
        return @intCast(current);
    }
    pub fn position(self: *Store) Error!t.EventPosition {
        const statement = try self.prepare("SELECT last_sequence,last_index FROM meta WHERE singleton=1", &.{});
        defer statement.deinit();
        if (!try statement.step()) return error.Corrupt;
        return .{ .commit_sequence = @intCast(statement.integer(0)), .event_index = @intCast(statement.integer(1)) };
    }
    /// Dedup precedes aggregate revision checks. Caller copies returned receipt
    /// into its owned output buffer while the statement is alive.
    pub fn lookupCommand(self: *Store, command_id: []const u8, canonical: []const u8, output: []u8) Error!?[]const u8 {
        const statement = try self.prepare("SELECT canonical,receipt FROM commands WHERE command_id=?", &.{.{ .text = command_id }});
        defer statement.deinit();
        if (!try statement.step()) return null;
        if (!std.mem.eql(u8, canonical, try statement.bytes(0))) return error.Conflict;
        const receipt = try statement.bytes(1);
        if (receipt.len > output.len) return error.Limit;
        @memcpy(output[0..receipt.len], receipt);
        return output[0..receipt.len];
    }
    pub fn recordCommand(self: *Store, id: []const u8, canonical: []const u8, receipt: []const u8, sequence: u64) Error!void {
        if (!self.in_transaction or sequence > std.math.maxInt(i64)) return error.Conflict;
        const hash = t.digest(canonical);
        try self.execute("INSERT INTO commands(command_id,canonical,digest,receipt,commit_sequence) VALUES(?,?,?,?,?)", &.{ .{ .text = id }, .{ .blob = canonical }, .{ .blob = &hash }, .{ .blob = receipt }, .{ .integer = @intCast(sequence) } });
    }
    pub fn appendEvent(self: *Store, event: t.Event) Error!void {
        if (!self.in_transaction or event.position.commit_sequence > std.math.maxInt(i64) or event.aggregate_revision > std.math.maxInt(i64)) return error.Conflict;
        var target_buffer: [1024]u8 = undefined;
        const target = t.encode(event.aggregate, &target_buffer) catch return error.Limit;
        try self.execute("INSERT INTO events(sequence,event_index,event_id,aggregate,revision,kind,command_id,effect_id,payload) VALUES(?,?,?,?,?,?,?,?,?)", &.{
            .{ .integer = @intCast(event.position.commit_sequence) },              .{ .integer = event.position.event_index },
            .{ .text = event.event_id.value },                                     .{ .blob = target },
            .{ .integer = @intCast(event.aggregate_revision) },                    .{ .text = event.kind },
            if (event.causation_command_id) |id| .{ .text = id.value } else .null, if (event.effect_id) |id| .{ .text = id.value } else .null,
            .{ .blob = event.payload },
        });
        try self.execute("UPDATE meta SET last_sequence=?,last_index=? WHERE singleton=1", &.{ .{ .integer = @intCast(event.position.commit_sequence) }, .{ .integer = event.position.event_index } });
    }
    const aggregates = .{
        .{ "projects", "project" },   .{ "workspaces", "workspace" },
        .{ "threads", "thread" },     .{ "runs", "run" },
        .{ "sessions", "session" },   .{ "messages", "message" },
        .{ "blocks", "block" },       .{ "tools", "tool" },
        .{ "approvals", "approval" }, .{ "effects", "effect" },
    };
    /// Connection-local and transactional: no schema migration, history scan or
    /// retained per-history index. One entry per aggregate actually touched.
    fn installChangeJournal(self: *Store) Error!void {
        try self.exec("CREATE TEMP TABLE aggregate_changes(kind TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(kind,id)) WITHOUT ROWID");
        inline for (aggregates) |entry| {
            try self.exec("CREATE TEMP TRIGGER changes_insert_" ++ entry[0] ++ " AFTER INSERT ON main." ++ entry[0] ++ " BEGIN INSERT INTO aggregate_changes VALUES('" ++ entry[1] ++ "',NEW.id,NEW.revision) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision; END");
            try self.exec("CREATE TEMP TRIGGER changes_update_" ++ entry[0] ++ " AFTER UPDATE ON main." ++ entry[0] ++ " BEGIN INSERT INTO aggregate_changes VALUES('" ++ entry[1] ++ "',NEW.id,NEW.revision) ON CONFLICT(kind,id) DO UPDATE SET revision=excluded.revision; END");
        }
    }
    fn changedAggregate(kind: []const u8, key: []const u8) Error!t.AggregateRef {
        inline for (@typeInfo(t.AggregateRef).@"union".fields) |field| {
            if (std.mem.eql(u8, kind, field.name)) return @unionInit(t.AggregateRef, field.name, .{ .value = key });
        }
        return error.Corrupt;
    }
    pub fn committedRevisions(self: *Store, allocator: std.mem.Allocator) Error![]const t.CommittedRevision {
        const count = try self.scalar("SELECT count(*) FROM aggregate_changes");
        const result = try allocator.alloc(t.CommittedRevision, @intCast(count));
        const s = try self.prepare("SELECT kind,id,revision FROM aggregate_changes ORDER BY kind,id", &.{});
        defer s.deinit();
        var index: usize = 0;
        while (try s.step()) : (index += 1) {
            const key = try allocator.dupe(u8, try s.bytes(1));
            result[index] = .{ .target = try changedAggregate(try s.bytes(0), key), .revision = @intCast(s.integer(2)) };
        }
        return result;
    }
    /// Explicit semantic events win. Fill only missing final aggregate revisions
    /// in this transaction, preserving a single contiguous position ordering.
    pub fn publishChanges(self: *Store, sequence: u64, causation: ?t.CommandId) Error!void {
        if (!self.in_transaction) return error.Conflict;
        const s = try self.prepare("SELECT kind,id,revision FROM aggregate_changes ORDER BY kind,id", &.{});
        defer s.deinit();
        while (try s.step()) {
            const aggregate = try changedAggregate(try s.bytes(0), try s.bytes(1));
            var target_buffer: [1024]u8 = undefined;
            const target = t.encode(aggregate, &target_buffer) catch return error.Limit;
            const exists = try self.prepare("SELECT 1 FROM events WHERE sequence=? AND aggregate=? AND revision=?", &.{ .{ .integer = @intCast(sequence) }, .{ .blob = target }, .{ .integer = s.integer(2) } });
            const already_published = blk: {
                defer exists.deinit();
                break :blk try exists.step();
            };
            if (already_published) continue;
            const position_value = try self.position();
            const index = if (position_value.commit_sequence == sequence) std.math.add(u32, position_value.event_index, 1) catch return error.Limit else 0;
            var id_buffer: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&id_buffer, "change:{d}:{d}", .{ sequence, index }) catch return error.Limit;
            try self.appendEvent(.{ .event_id = .{ .value = name }, .position = .{ .commit_sequence = sequence, .event_index = index }, .aggregate = aggregate, .aggregate_revision = @intCast(s.integer(2)), .kind = "AggregateChanged", .causation_command_id = causation, .payload = "" });
        }
    }
    /// Chunk, byte length, upstream dedup/cursor and public event are committed
    /// by the caller's single transaction. This method never advances on failure.
    pub fn appendChunk(self: *Store, block: []const u8, offset: u64, bytes: []const u8) Error!enum { appended, duplicate } {
        if (!self.in_transaction or offset > std.math.maxInt(i64) or bytes.len > 2048) return error.Limit;
        const statement = try self.prepare("SELECT committed_bytes,revision FROM blocks WHERE id=?", &.{.{ .text = block }});
        defer statement.deinit();
        if (!try statement.step()) return error.Conflict;
        const length: u64 = @intCast(statement.integer(0));
        if (bytes.len == 0 and offset <= length) return .duplicate;
        if (offset < length) {
            if (bytes.len > length - offset) return error.Conflict;
            const existing = try self.prepare("SELECT byte_offset,bytes FROM chunks WHERE block_id=? AND byte_offset<=? ORDER BY byte_offset DESC LIMIT 1", &.{ .{ .text = block }, .{ .integer = @intCast(offset) } });
            defer existing.deinit();
            if (!try existing.step()) return error.Corrupt;
            const first = existing.integer(0);
            const range = try self.prepare("SELECT byte_offset,bytes FROM chunks WHERE block_id=? AND byte_offset>=? AND byte_offset<? ORDER BY byte_offset", &.{ .{ .text = block }, .{ .integer = first }, .{ .integer = @intCast(offset + bytes.len) } });
            defer range.deinit();
            var matched: usize = 0;
            while (try range.step()) {
                const chunk_start: u64 = @intCast(range.integer(0));
                const chunk = try range.bytes(1);
                if (chunk_start > offset + matched) return error.Corrupt;
                const skip: usize = @intCast(offset + matched - chunk_start);
                if (skip > chunk.len) return error.Corrupt;
                const count = @min(chunk.len - skip, bytes.len - matched);
                if (!std.mem.eql(u8, chunk[skip..][0..count], bytes[matched..][0..count])) return error.Conflict;
                matched += count;
                if (matched == bytes.len) return .duplicate;
            }
            return error.Corrupt;
        }
        if (offset != length) return error.Conflict;
        if (bytes.len == 0) return .duplicate;
        const end = std.math.add(u64, offset, bytes.len) catch return error.Limit;
        if (end > std.math.maxInt(i64)) return error.Limit;
        if (statement.integer(1) == std.math.maxInt(i64)) return error.Limit;
        try self.execute("INSERT INTO chunks(block_id,byte_offset,bytes) VALUES(?,?,?)", &.{ .{ .text = block }, .{ .integer = @intCast(offset) }, .{ .blob = bytes } });
        try self.execute("UPDATE blocks SET committed_bytes=?,revision=revision+1 WHERE id=?", &.{ .{ .integer = @intCast(end) }, .{ .text = block } });
        return .appended;
    }
    pub fn claim(self: *Store, effect: []const u8, owner: []const u8) Error!bool {
        if (!self.in_transaction) return error.Conflict;
        const exhausted = try self.prepare("SELECT 1 FROM effects WHERE id=? AND state='planned' AND revision=9223372036854775807", &.{.{ .text = effect }});
        defer exhausted.deinit();
        if (try exhausted.step()) return error.Limit;
        try self.execute("UPDATE effects SET state='in_flight',claim_owner=?,revision=revision+1 WHERE id=? AND state='planned' AND EXISTS(SELECT 1 FROM runs r WHERE r.id=effects.run_id AND (effects.read_only=1 OR r.state IN('queued','starting','streaming','awaiting_approval') OR (effects.kind='cancel' AND r.state='cancel_requested'))) AND (depends_on IS NULL OR EXISTS(SELECT 1 FROM effects d WHERE d.id=effects.depends_on AND d.state='confirmed'))", &.{ .{ .text = owner }, .{ .text = effect } });
        return c.sqlite3_changes(self.database) == 1;
    }
    /// Recovery is conservative: no lease/clock grants permission to replay a call.
    /// Planned and withdrawn effects remain unchanged; nothing is externally called.
    pub fn recoverClaims(self: *Store) Error!void {
        if (!self.in_transaction) return error.Conflict;
        const affected = try self.prepare(
            "SELECT 'effect',id,revision FROM effects WHERE state='in_flight' UNION ALL SELECT 'approval',id,revision FROM approvals WHERE live_epoch IS NOT NULL UNION ALL SELECT 'run',id,revision FROM runs WHERE state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested') OR (EXISTS(SELECT 1 FROM effects e WHERE e.run_id=runs.id AND e.state='in_flight') AND state NOT IN('completed','cancelled','failed')) UNION ALL SELECT 'tool',t.id,t.revision FROM tools t JOIN runs r ON r.id=t.run_id WHERE t.outcome='pending' AND r.state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested','unknown','interrupted')",
            &.{},
        );
        defer affected.deinit();
        var sequence: ?u64 = null;
        var index: u32 = 0;
        while (try affected.step()) {
            const revision = affected.integer(2);
            if (revision == std.math.maxInt(i64)) return error.Limit;
            if (sequence == null) sequence = try self.nextSequence();
            const kind = try affected.bytes(0);
            const key = try affected.bytes(1);
            const aggregate: t.AggregateRef = if (std.mem.eql(u8, kind, "effect")) .{ .effect = .{ .value = key } } else if (std.mem.eql(u8, kind, "approval")) .{ .approval = .{ .value = key } } else if (std.mem.eql(u8, kind, "tool")) .{ .tool = .{ .value = key } } else .{ .run = .{ .value = key } };
            var event_id: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&event_id, "recovery:{d}:{d}", .{ sequence.?, index }) catch return error.Limit;
            try self.appendEvent(.{ .event_id = .{ .value = name }, .position = .{ .commit_sequence = sequence.?, .event_index = index }, .aggregate = aggregate, .aggregate_revision = @intCast(revision + 1), .kind = "RecoveryUnknown", .payload = "" });
            index = std.math.add(u32, index, 1) catch return error.Limit;
        }
        try self.exec("UPDATE runs SET state='unknown',revision=revision+1 WHERE EXISTS(SELECT 1 FROM effects e WHERE e.run_id=runs.id AND e.state='in_flight') AND state NOT IN('completed','cancelled','failed')");
        try self.exec("UPDATE runs SET state='interrupted',revision=revision+1 WHERE state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested')");
        try self.exec("UPDATE tools SET outcome='unknown',revision=revision+1 WHERE outcome='pending' AND EXISTS(SELECT 1 FROM runs r WHERE r.id=tools.run_id AND r.state IN('unknown','interrupted'))");
        try self.exec("UPDATE effects SET state='unknown',outcome='crash_after_claim',revision=revision+1 WHERE state='in_flight'");
        try self.exec("UPDATE approvals SET state=CASE WHEN state='pending' THEN 'invalidated' ELSE state END,live_epoch=NULL,revision=revision+1 WHERE live_epoch IS NOT NULL");
    }
};

pub fn check(rc: c_int) Error!void {
    if (rc != c.SQLITE_OK) return translate(rc);
}
fn translate(rc: c_int) Error {
    return switch (rc & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.Corrupt,
        c.SQLITE_CONSTRAINT => error.Conflict,
        c.SQLITE_TOOBIG, c.SQLITE_RANGE => error.Limit,
        else => error.Storage,
    };
}

const schema =
    \\CREATE TABLE meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),schema_version INTEGER NOT NULL,next_sequence INTEGER NOT NULL CHECK(next_sequence>0),last_sequence INTEGER NOT NULL,last_index INTEGER NOT NULL);
    \\INSERT INTO meta VALUES(1,1,1,0,0);
    \\CREATE TABLE commands(command_id TEXT PRIMARY KEY,canonical BLOB NOT NULL,digest BLOB NOT NULL CHECK(length(digest)=32),receipt BLOB NOT NULL,commit_sequence INTEGER NOT NULL);
    \\CREATE TABLE projects(id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0),display_name TEXT NOT NULL);
    \\CREATE TABLE workspaces(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),binding BLOB NOT NULL);
    \\CREATE TABLE sessions(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,workspace_id TEXT NOT NULL REFERENCES workspaces(id),selection BLOB NOT NULL,instance_id TEXT,upstream_session TEXT,cursor BLOB,continuity TEXT NOT NULL DEFAULT 'unknown');
    \\CREATE TABLE threads(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,project_id TEXT NOT NULL REFERENCES projects(id),workspace_id TEXT NOT NULL REFERENCES workspaces(id),session_id TEXT REFERENCES sessions(id),root_key BLOB CHECK(root_key IS NULL OR length(root_key)=32),next_ordinal INTEGER NOT NULL DEFAULT 0);
    \\CREATE TABLE runs(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,thread_id TEXT NOT NULL REFERENCES threads(id),session_id TEXT NOT NULL REFERENCES sessions(id),state TEXT NOT NULL CHECK(state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested','completed','cancelled','failed','interrupted','unknown')),requested BLOB NOT NULL,effective BLOB,upstream_turn TEXT,cancel_cause TEXT,unresolved_tools INTEGER NOT NULL DEFAULT 0);
    \\CREATE UNIQUE INDEX one_active_run ON runs(thread_id) WHERE state IN('queued','starting','streaming','awaiting_approval','awaiting_question','cancel_requested');
    \\CREATE TABLE messages(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,thread_id TEXT NOT NULL REFERENCES threads(id),run_id TEXT NOT NULL REFERENCES runs(id),ordinal INTEGER NOT NULL,role TEXT NOT NULL CHECK(role IN('user','assistant','tool')),incomplete INTEGER NOT NULL,UNIQUE(thread_id,ordinal));
    \\CREATE TABLE blocks(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,message_id TEXT NOT NULL REFERENCES messages(id),ordinal INTEGER NOT NULL,kind TEXT NOT NULL,committed_bytes INTEGER NOT NULL DEFAULT 0 CHECK(committed_bytes>=0),tool_id TEXT,UNIQUE(message_id,ordinal));
    \\CREATE TABLE chunks(block_id TEXT NOT NULL REFERENCES blocks(id),byte_offset INTEGER NOT NULL CHECK(byte_offset>=0),bytes BLOB NOT NULL,PRIMARY KEY(block_id,byte_offset));
    \\CREATE TABLE tools(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,run_id TEXT NOT NULL REFERENCES runs(id),session_id TEXT NOT NULL REFERENCES sessions(id),upstream_tool TEXT NOT NULL,name TEXT NOT NULL,action_digest BLOB NOT NULL,outcome TEXT NOT NULL,result_block TEXT REFERENCES blocks(id),UNIQUE(session_id,upstream_tool));
    \\CREATE TABLE approvals(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,run_id TEXT NOT NULL REFERENCES runs(id),thread_id TEXT NOT NULL REFERENCES threads(id),session_id TEXT NOT NULL REFERENCES sessions(id),tool_id TEXT NOT NULL REFERENCES tools(id),workspace_id TEXT NOT NULL REFERENCES workspaces(id),upstream_request TEXT NOT NULL,action_digest BLOB NOT NULL,scope BLOB NOT NULL,expires_at INTEGER,state TEXT NOT NULL,decision TEXT,live_epoch TEXT,reply_effect TEXT UNIQUE);
    \\CREATE TABLE effects(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,run_id TEXT NOT NULL REFERENCES runs(id),session_id TEXT NOT NULL REFERENCES sessions(id),kind TEXT NOT NULL CHECK(kind IN('create_session','start','approval_reply','cancel','inspect','attach')),read_only INTEGER NOT NULL DEFAULT 0,request BLOB NOT NULL,digest BLOB NOT NULL CHECK(length(digest)=32),state TEXT NOT NULL CHECK(state IN('planned','in_flight','withdrawn','confirmed','failed','unknown')),depends_on TEXT REFERENCES effects(id),approval_id TEXT UNIQUE REFERENCES approvals(id),command_id TEXT NOT NULL,claim_owner TEXT,outcome TEXT NOT NULL DEFAULT '',evidence BLOB);
    \\CREATE UNIQUE INDEX one_effect ON effects(run_id,kind) WHERE kind IN('create_session','start','cancel');
    \\CREATE UNIQUE INDEX one_reconcile_call ON effects(command_id,kind) WHERE kind IN('inspect','attach');
    \\CREATE INDEX pending_effect ON effects(state,id);
    \\CREATE TABLE observations(session_id TEXT NOT NULL REFERENCES sessions(id),upstream_event TEXT NOT NULL,runtime_version TEXT NOT NULL,correlation BLOB NOT NULL,digest BLOB NOT NULL,evidence BLOB,cursor BLOB,commit_sequence INTEGER NOT NULL,PRIMARY KEY(session_id,upstream_event));
    \\CREATE TABLE events(sequence INTEGER NOT NULL,event_index INTEGER NOT NULL CHECK(event_index>=0),event_id TEXT NOT NULL UNIQUE,aggregate BLOB NOT NULL,revision INTEGER NOT NULL,kind TEXT NOT NULL,command_id TEXT,effect_id TEXT,payload BLOB NOT NULL,PRIMARY KEY(sequence,event_index));
    \\CREATE INDEX aggregate_events ON events(aggregate,sequence,event_index);
;

const task_schema =
    \\CREATE TABLE tasks(run_id TEXT PRIMARY KEY REFERENCES runs(id),parent_run TEXT NOT NULL REFERENCES runs(id),packet BLOB NOT NULL,detached INTEGER NOT NULL,created_at INTEGER,requests INTEGER NOT NULL DEFAULT 1,input_tokens INTEGER NOT NULL DEFAULT 0,output_tokens INTEGER NOT NULL DEFAULT 0,cached_tokens INTEGER NOT NULL DEFAULT 0,result BLOB,review TEXT);
    \\CREATE INDEX task_parent ON tasks(parent_run);
    \\CREATE TABLE bridge_calls(session_id TEXT NOT NULL REFERENCES sessions(id),request_key TEXT NOT NULL,method TEXT NOT NULL,digest BLOB NOT NULL,command BLOB NOT NULL,PRIMARY KEY(session_id,request_key));
    \\CREATE TABLE effects_v3(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,run_id TEXT NOT NULL REFERENCES runs(id),session_id TEXT NOT NULL REFERENCES sessions(id),kind TEXT NOT NULL CHECK(kind IN('create_session','start','approval_reply','cancel','inspect','attach','message')),read_only INTEGER NOT NULL DEFAULT 0,request BLOB NOT NULL,digest BLOB NOT NULL CHECK(length(digest)=32),state TEXT NOT NULL CHECK(state IN('planned','in_flight','withdrawn','confirmed','failed','unknown')),depends_on TEXT REFERENCES effects_v3(id),approval_id TEXT UNIQUE REFERENCES approvals(id),command_id TEXT NOT NULL,claim_owner TEXT,outcome TEXT NOT NULL DEFAULT '',evidence BLOB);
    \\INSERT INTO effects_v3 SELECT * FROM effects;
    \\DROP TABLE effects;
    \\ALTER TABLE effects_v3 RENAME TO effects;
    \\CREATE UNIQUE INDEX one_effect ON effects(run_id,kind) WHERE kind IN('create_session','start','cancel');
    \\CREATE UNIQUE INDEX one_reconcile_call ON effects(command_id,kind) WHERE kind IN('inspect','attach');
    \\CREATE INDEX pending_effect ON effects(state,id);
;

const prompt_schema =
    \\CREATE TABLE IF NOT EXISTS prompt_uploads(id TEXT PRIMARY KEY CHECK(length(id) BETWEEN 1 AND 128),byte_length INTEGER NOT NULL CHECK(byte_length BETWEEN 1 AND 65536),digest BLOB NOT NULL CHECK(length(digest)=32),received INTEGER NOT NULL CHECK(received BETWEEN 0 AND byte_length),complete INTEGER NOT NULL CHECK(complete IN(0,1)));
    \\CREATE TABLE IF NOT EXISTS prompt_chunks(upload_id TEXT NOT NULL REFERENCES prompt_uploads(id) ON DELETE CASCADE,byte_offset INTEGER NOT NULL CHECK(byte_offset BETWEEN 0 AND 65535),bytes BLOB NOT NULL CHECK(length(bytes) BETWEEN 1 AND 2048),PRIMARY KEY(upload_id,byte_offset));
;

const attachment_schema =
    \\CREATE TABLE IF NOT EXISTS attachments(id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0),thread_id TEXT NOT NULL REFERENCES threads(id),name TEXT NOT NULL,media_type TEXT NOT NULL,byte_length INTEGER NOT NULL CHECK(byte_length BETWEEN 0 AND 262144),digest TEXT NOT NULL CHECK(length(digest)=64),kind TEXT NOT NULL CHECK(kind IN('file','image')),content BLOB NOT NULL);
    \\CREATE TABLE IF NOT EXISTS attachment_refs(message_id TEXT NOT NULL REFERENCES messages(id),attachment_id TEXT NOT NULL REFERENCES attachments(id),ordinal INTEGER NOT NULL CHECK(ordinal>=0),PRIMARY KEY(message_id,attachment_id),UNIQUE(message_id,ordinal));
    \\CREATE INDEX IF NOT EXISTS attachments_by_thread ON attachments(thread_id,id);
;

const question_schema =
    \\CREATE TABLE IF NOT EXISTS questions(id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0),run_id TEXT NOT NULL REFERENCES runs(id),thread_id TEXT NOT NULL REFERENCES threads(id),session_id TEXT NOT NULL REFERENCES sessions(id),question BLOB NOT NULL CHECK(length(question)<=16384),expires_at INTEGER,state TEXT NOT NULL CHECK(state IN('pending','resolved','invalidated')),answer BLOB,live_epoch TEXT,reply_effect TEXT UNIQUE);
    \\CREATE INDEX IF NOT EXISTS questions_by_run ON questions(run_id,id);
;

const input_owner_migration =
    \\CREATE TABLE approvals_v12(id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0),run_id TEXT NOT NULL REFERENCES runs(id),thread_id TEXT NOT NULL REFERENCES threads(id),session_id TEXT NOT NULL REFERENCES sessions(id),tool_id TEXT NOT NULL REFERENCES tools(id),workspace_id TEXT NOT NULL REFERENCES workspaces(id),upstream_request TEXT NOT NULL,action_digest BLOB NOT NULL,scope BLOB NOT NULL,expires_at INTEGER,state TEXT NOT NULL,decision TEXT,live_epoch TEXT,reply_effect TEXT UNIQUE);
    \\INSERT INTO approvals_v12 SELECT a.id,a.revision,a.run_id,r.thread_id,a.session_id,a.tool_id,a.workspace_id,a.upstream_request,a.action_digest,a.scope,a.expires_at,a.state,a.decision,a.live_epoch,a.reply_effect FROM approvals a JOIN runs r ON r.id=a.run_id;
    \\CREATE TABLE questions_v12(id TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>0),run_id TEXT NOT NULL REFERENCES runs(id),thread_id TEXT NOT NULL REFERENCES threads(id),session_id TEXT NOT NULL REFERENCES sessions(id),question BLOB NOT NULL CHECK(length(question)<=16384),expires_at INTEGER,state TEXT NOT NULL CHECK(state IN('pending','resolved','invalidated')),answer BLOB,live_epoch TEXT,reply_effect TEXT UNIQUE);
    \\INSERT INTO questions_v12 SELECT q.id,q.revision,q.run_id,r.thread_id,q.session_id,q.question,q.expires_at,q.state,q.answer,q.live_epoch,q.reply_effect FROM questions q JOIN runs r ON r.id=q.run_id;
    \\DROP TABLE approvals;
    \\ALTER TABLE approvals_v12 RENAME TO approvals;
    \\DROP TABLE questions;
    \\ALTER TABLE questions_v12 RENAME TO questions;
    \\CREATE INDEX approvals_by_run ON approvals(run_id,id);
    \\CREATE INDEX questions_by_run ON questions(run_id,id);
;
