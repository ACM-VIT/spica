const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
const allocator = std.heap.page_allocator;
pub const Db = struct {
    handle: *c.sqlite3,
    pub fn init(path: []const u8) !Db {
        const name = try allocator.dupeZ(u8, path);
        defer allocator.free(name);
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(name.ptr, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_NOMUTEX, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteFailure;
        }
        var self: Db = .{ .handle = handle.? };
        errdefer self.deinit();
        _ = c.sqlite3_busy_timeout(self.handle, 5000);
        try self.exec("PRAGMA foreign_keys=ON; PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA cache_size=-256");
        return self;
    }
    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }
    pub fn exec(self: *Db, query: [*:0]const u8) !void {
        if (c.sqlite3_exec(self.handle, query, null, null, null) != c.SQLITE_OK) return error.SqliteFailure;
    }
    pub fn prepare(self: *Db, query: [*:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, query, -1, &stmt, null) != c.SQLITE_OK) return error.SqliteFailure;
        return stmt orelse error.SqliteFailure;
    }
};
pub fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));
    if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), transient) != c.SQLITE_OK) return error.SqliteFailure;
}
pub fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteFailure;
}
pub fn done(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteFailure;
}
pub fn column(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const n: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    if (n == 0) return "";
    return c.sqlite3_column_text(stmt, index)[0..n];
}
