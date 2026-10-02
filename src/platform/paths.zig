const std = @import("std");
const builtin = @import("builtin");

extern fn spica_database_cutover(destination: [*:0]const u8, legacy: [*:0]const u8, temporary: [*:0]const u8, directory: [*:0]const u8) c_int;

pub const Paths = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data: []u8,
    cache: []u8,
    database: []u8,
    state: []u8,
    lock_file: std.Io.File,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, override: ?[]const u8) !Paths {
        const roots = if (override) |root| .{
            try std.fs.path.join(allocator, &.{ root, "app" }),
            try std.fs.path.join(allocator, &.{ root, "cache" }),
        } else try defaultRoots(allocator, environ);
        errdefer {
            allocator.free(roots[0]);
            allocator.free(roots[1]);
        }
        try std.Io.Dir.cwd().createDirPath(io, roots[0]);
        try std.Io.Dir.cwd().createDirPath(io, roots[1]);
        const lock_path = try std.fs.path.join(allocator, &.{ roots[0], "instance.lock" });
        defer allocator.free(lock_path);
        const lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false });
        errdefer lock_file.close(io);
        if (!try lock_file.tryLock(io, .exclusive)) return error.DataDirectoryAlreadyInUse;
        const database = try std.fs.path.join(allocator, &.{ roots[0], "history.sqlite" });
        errdefer allocator.free(database);
        const legacy = try std.fs.path.join(allocator, &.{ roots[1], "history.sqlite" });
        defer allocator.free(legacy);
        const temporary = try std.fs.path.join(allocator, &.{ roots[0], "history.sqlite.migrating" });
        defer allocator.free(temporary);
        const destination_z = try allocator.dupeZ(u8, database);
        defer allocator.free(destination_z);
        const legacy_z = try allocator.dupeZ(u8, legacy);
        defer allocator.free(legacy_z);
        const temporary_z = try allocator.dupeZ(u8, temporary);
        defer allocator.free(temporary_z);
        const directory_z = try allocator.dupeZ(u8, roots[0]);
        defer allocator.free(directory_z);
        if (spica_database_cutover(destination_z, legacy_z, temporary_z, directory_z) != 0) return error.DatabaseMigrationFailed;
        const state = try std.fs.path.join(allocator, &.{ roots[0], "workspace.json" });
        return .{ .allocator = allocator, .io = io, .data = roots[0], .cache = roots[1], .database = database, .state = state, .lock_file = lock_file };
    }

    pub fn deinit(self: *Paths) void {
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.allocator.free(self.data);
        self.allocator.free(self.cache);
        self.allocator.free(self.database);
        self.allocator.free(self.state);
    }

    fn variable(allocator: std.mem.Allocator, environ: std.process.Environ, key: []const u8) !?[]u8 {
        return environ.getAlloc(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => return err,
        };
    }

    fn defaultRoots(allocator: std.mem.Allocator, environ: std.process.Environ) ![2][]u8 {
        if (builtin.os.tag == .windows) {
            const base = (try variable(allocator, environ, "LOCALAPPDATA")) orelse return error.MissingLocalAppData;
            defer allocator.free(base);
            const data = try std.fs.path.join(allocator, &.{ base, "Spica", "Data" });
            errdefer allocator.free(data);
            return .{ data, try std.fs.path.join(allocator, &.{ base, "Spica", "Cache" }) };
        }
        const home = (try variable(allocator, environ, "HOME")) orelse return error.MissingHomeDirectory;
        defer allocator.free(home);
        if (builtin.os.tag == .macos) {
            const data = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Spica" });
            errdefer allocator.free(data);
            return .{ data, try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "Spica" }) };
        }
        const data_base = (try variable(allocator, environ, "XDG_DATA_HOME")) orelse try std.fs.path.join(allocator, &.{ home, ".local", "share" });
        defer allocator.free(data_base);
        const cache_base = (try variable(allocator, environ, "XDG_CACHE_HOME")) orelse try std.fs.path.join(allocator, &.{ home, ".cache" });
        defer allocator.free(cache_base);
        const data = try std.fs.path.join(allocator, &.{ data_base, "spica" });
        errdefer allocator.free(data);
        return .{ data, try std.fs.path.join(allocator, &.{ cache_base, "spica" }) };
    }
};
