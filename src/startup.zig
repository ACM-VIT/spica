//! Ordinary launch prepares editable defaults, without account or runtime IO.
const std = @import("std");
const c = @import("contract.zig");

/// Strings belong to allocator and must outlive App/Host. Only executable
/// metadata and the actual cwd are inspected; account directories stay untouched.
pub fn defaults(allocator: std.mem.Allocator, io: std.Io, state_directory: []const u8, path: ?[]const u8, home: ?[]const u8, codex_home: ?[]const u8) ![2]c.RuntimeSetup {
    if (!std.fs.path.isAbsolute(state_directory)) return error.AbsoluteStateDirectoryRequired;
    const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    return .{
        .{ .runtime_kind = .codex, .executable = try executable(allocator, io, .codex, path, home), .account_directory = try codexAccount(allocator, state_directory, workspace, home, codex_home), .workspace_root = workspace, .model_provider = "openai" },
        .{ .runtime_kind = .opencode, .executable = try executable(allocator, io, .opencode, path, home), .account_directory = try std.fs.path.join(allocator, &.{ state_directory, "accounts", "opencode" }), .workspace_root = workspace, .model_provider = "opencode" },
    };
}

/// Resolve path syntax only; never create/read an account or inspect its auth.
/// Empty CODEX_HOME follows Codex's normal HOME fallback. Relative overrides
/// are made absolute against the launch cwd before crossing the Host boundary.
pub fn codexAccount(a: std.mem.Allocator, state: []const u8, cwd: []const u8, home: ?[]const u8, override: ?[]const u8) ![]const u8 {
    if (override) |value| if (value.len != 0) return std.fs.path.resolve(a, &.{ cwd, value });
    if (home) |value| if (std.fs.path.isAbsolute(value)) return std.fs.path.resolve(a, &.{ value, ".codex" });
    return std.fs.path.join(a, &.{ state, "accounts", "codex" });
}

fn installed(io: std.Io, candidate: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return false;
    if (stat.kind != .file) return false;
    std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch return false;
    return true;
}

/// Prefer PATH, then documented user-install locations. Missing software leaves
/// an absolute, editable path in setup; installed software never implies auth.
pub fn executable(allocator: std.mem.Allocator, io: std.Io, kind: c.RuntimeKind, path: ?[]const u8, home: ?[]const u8) ![]const u8 {
    const name = @tagName(kind);
    if (path) |search| {
        var entries = std.mem.splitScalar(u8, search, ':');
        while (entries.next()) |entry| {
            const candidate = try std.fs.path.join(allocator, &.{ if (entry.len == 0) "." else entry, name });
            defer allocator.free(candidate);
            if (try installed(io, candidate)) return std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator);
        }
    }
    if (home) |root| {
        if (std.fs.path.isAbsolute(root)) {
            const locations: []const []const u8 = if (kind == .opencode) &.{ ".opencode/bin", ".local/bin", ".npm-global/bin" } else &.{ ".local/bin", ".npm-global/bin", "bin" };
            for (locations) |location| {
                const candidate = try std.fs.path.join(allocator, &.{ root, location, name });
                defer allocator.free(candidate);
                if (try installed(io, candidate)) return std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator);
            }
        }
    }
    return std.fs.path.join(allocator, &.{ "/usr/bin", name });
}

test "startup defaults preserve canonical cwd and separate managed Unicode account paths without creating them" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const state = try std.fs.path.join(allocator, &.{ root, "独立 state" });
    const setups = try defaults(allocator, std.testing.io, state, "", null, null);
    try std.testing.expectEqual(.codex, setups[0].runtime_kind);
    try std.testing.expectEqual(.opencode, setups[1].runtime_kind);
    try std.testing.expectEqualStrings(try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator), setups[0].workspace_root);
    try std.testing.expectEqualStrings(setups[0].workspace_root, setups[1].workspace_root);
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ state, "accounts", "codex" }), setups[0].account_directory);
    try std.testing.expect(!std.mem.eql(u8, setups[0].account_directory, setups[1].account_directory));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, state, .{}));
    try std.testing.expectError(error.AbsoluteStateDirectoryRequired, defaults(allocator, std.testing.io, "relative", null, null, null));
}

test "executable discovery prefers usable PATH files and recognizes OpenCode home installation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try temporary.dir.createDirPath(io, "路径 bin");
    try temporary.dir.createDirPath(io, ".opencode/bin");
    try temporary.dir.createDirPath(io, "nonexec");
    for ([_][]const u8{ "路径 bin/opencode", ".opencode/bin/opencode", "nonexec/opencode" }, 0..) |item, i| {
        const file = try temporary.dir.createFile(io, item, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(if (i == 2) 0o600 else 0o700));
    }
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    const path = try std.fmt.allocPrint(allocator, "{s}/missing:{s}/nonexec:{s}/路径 bin", .{ root, root, root });
    try std.testing.expectEqualStrings(try temporary.dir.realPathFileAlloc(io, "路径 bin/opencode", allocator), try executable(allocator, io, .opencode, path, root));
    try std.testing.expectEqualStrings(try temporary.dir.realPathFileAlloc(io, ".opencode/bin/opencode", allocator), try executable(allocator, io, .opencode, "/no/such/bin", root));
    try std.testing.expectEqualStrings("/usr/bin/codex", try executable(allocator, io, .codex, "/no/such/bin", "/no/such/home"));
}

test "Codex auth home precedence resolves Unicode overrides without reading or creating accounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/custom/账号", try codexAccount(a, "/state", "/launch", "/user", "/custom/账号"));
    try std.testing.expectEqualStrings("/user/.codex", try codexAccount(a, "/state", "/launch", "/user", ""));
    try std.testing.expectEqualStrings("/state/accounts/codex", try codexAccount(a, "/state", "/launch", "relative", null));
    try std.testing.expectEqualStrings("/launch/relative/账号", try codexAccount(a, "/state", "/launch", "/user", "relative/账号"));
    const setups = try defaults(a, std.testing.io, "/state", "", "/user", "/custom/账号");
    try std.testing.expectEqualStrings("/custom/账号", setups[0].account_directory);
    try std.testing.expectEqualStrings("/state/accounts/opencode", setups[1].account_directory);
}
