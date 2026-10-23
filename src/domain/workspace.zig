//! Captures actual checkout identity; never trusts a display label as cwd.
const std = @import("std");
const t = @import("types.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
});
fn git(allocator: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8) ![]const u8 {
    var argv: [12][]const u8 = undefined;
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = root;
    if (args.len > argv.len - 3) return error.Limit;
    @memcpy(argv[3..][0..args.len], args);
    const result = try std.process.run(allocator, io, .{ .argv = argv[0 .. args.len + 3], .stdout_limit = .limited(16384), .stderr_limit = .limited(4096) });
    if (result.term != .exited or result.term.exited != 0) return error.NotRepository;
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}
pub fn capture(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !t.WorkspaceBinding {
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try directory.realPath(io, &buffer);
    const canonical = try allocator.dupe(u8, buffer[0..n]);
    const path = try allocator.dupeZ(u8, canonical);
    var identity: c.struct_stat = undefined;
    if (c.stat(path, &identity) != 0) return error.WorkspaceUnavailable;
    var binding: t.WorkspaceBinding = .{
        .canonical_root = canonical,
        .filesystem_identity = try std.fmt.allocPrint(allocator, "{d}:{d}", .{ identity.st_dev, identity.st_ino }),
        .repository_identity = "",
        .checkout_identity = canonical,
        .expected_branch = "",
        .base_revision = "",
        .non_git = true,
    };
    const common = git(allocator, io, canonical, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }) catch |err| switch (err) {
        error.NotRepository => return binding,
        else => return err,
    };
    binding.repository_identity = common;
    binding.checkout_identity = try git(allocator, io, canonical, &.{ "rev-parse", "--absolute-git-dir" });
    binding.base_revision = try git(allocator, io, canonical, &.{ "rev-parse", "--verify", "HEAD" });
    binding.expected_branch = try git(allocator, io, canonical, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    binding.non_git = false;
    return binding;
}
pub fn verify(allocator: std.mem.Allocator, io: std.Io, binding: t.WorkspaceBinding) !bool {
    const actual = try capture(allocator, io, binding.canonical_root);
    return t.adapter.equal(actual, binding);
}

/// Ownership paths are canonical relative names. Existing symlink components
/// cannot turn an admitted path into authority outside the registered checkout.
pub fn validOwnedPath(allocator: std.mem.Allocator, binding: t.WorkspaceBinding, path: []const u8) !bool {
    if (std.mem.eql(u8, path, ".")) return true;
    if (path.len == 0 or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    var length: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        length += part.len;
        const absolute = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ binding.canonical_root, path[0..length] }, 0);
        var identity: c.struct_stat = undefined;
        if (c.lstat(absolute, &identity) == 0 and (identity.st_mode & c.S_IFMT) == c.S_IFLNK) return false;
        length += 1;
    }
    return true;
}
fn contains(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or
        (std.mem.startsWith(u8, child, parent) and child.len > parent.len and child[parent.len] == '/');
}
pub fn ownershipOverlaps(allocator: std.mem.Allocator, left: t.WorkspaceBinding, left_path: []const u8, right: t.WorkspaceBinding, right_path: []const u8) !bool {
    const left_git = std.mem.eql(u8, left_path, ".") or contains(".git", left_path);
    const right_git = std.mem.eql(u8, right_path, ".") or contains(".git", right_path);
    if (!left.non_git and !right.non_git and left_git and right_git and std.mem.eql(u8, left.repository_identity, right.repository_identity)) return true;
    const absolute_left = if (std.mem.eql(u8, left_path, ".")) left.canonical_root else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ left.canonical_root, left_path });
    const absolute_right = if (std.mem.eql(u8, right_path, ".")) right.canonical_root else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ right.canonical_root, right_path });
    return contains(absolute_left, absolute_right) or contains(absolute_right, absolute_left);
}
