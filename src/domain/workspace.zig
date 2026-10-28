//! Captures actual checkout identity; never trusts a display label as cwd.
const std = @import("std");
const t = @import("types.zig");
const c = @cImport({
    @cInclude("sys/stat.h");
});
/// Returns owned output, or null only for Git's explicit "missing ref" status.
fn gitRef(allocator: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8, allow_missing: bool) !?[]const u8 {
    var argv: [12][]const u8 = undefined;
    argv[0] = "git";
    argv[1] = "-C";
    argv[2] = root;
    if (args.len > argv.len - 3) return error.Limit;
    @memcpy(argv[3..][0..args.len], args);
    const result = try std.process.run(allocator, io, .{ .argv = argv[0 .. args.len + 3], .stdout_limit = .limited(16384), .stderr_limit = .limited(4096) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited) return error.NotRepository;
    if (allow_missing and result.term.exited == 1) return null;
    if (result.term.exited != 0) return error.NotRepository;
    return try allocator.dupe(u8, std.mem.trimEnd(u8, result.stdout, "\r\n"));
}
fn git(allocator: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8) ![]const u8 {
    return (try gitRef(allocator, io, root, args, false)).?;
}
fn gitMarkerRoot(allocator: std.mem.Allocator, root: []const u8) !?[]const u8 {
    var ancestor = root;
    while (true) {
        const marker = try std.fmt.allocPrintSentinel(allocator, "{s}/.git", .{ancestor}, 0);
        defer allocator.free(marker);
        var identity: c.struct_stat = undefined;
        if (c.lstat(marker, &identity) == 0) return ancestor;
        if (std.c._errno().* != @intFromEnum(std.c.E.NOENT)) return error.WorkspaceUnavailable;
        ancestor = std.fs.path.dirname(ancestor) orelse return null;
    }
}
pub fn capture(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !t.WorkspaceBinding {
    const directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try directory.realPath(io, &buffer);
    const canonical = try allocator.dupe(u8, buffer[0..n]);
    errdefer allocator.free(canonical);
    const path = try allocator.dupeZ(u8, canonical);
    defer allocator.free(path);
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
    errdefer allocator.free(binding.filesystem_identity);
    const marker_root = try gitMarkerRoot(allocator, canonical);
    const common = git(allocator, io, canonical, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" }) catch |err| switch (err) {
        error.NotRepository => {
            if (marker_root != null) return error.NotRepository;
            return binding;
        },
        else => return err,
    };
    binding.repository_identity = common;
    errdefer allocator.free(common);
    if (marker_root) |expected_root| {
        // Git discovery can skip a damaged nested .git and find a parent repo.
        // Never substitute that parent's checkout for the requested identity.
        const top = try git(allocator, io, canonical, &.{ "rev-parse", "--show-toplevel" });
        defer allocator.free(top);
        if (!std.mem.eql(u8, top, expected_root)) return error.NotRepository;
    }
    binding.checkout_identity = try git(allocator, io, canonical, &.{ "rev-parse", "--absolute-git-dir" });
    errdefer allocator.free(binding.checkout_identity);
    binding.base_revision = git(allocator, io, canonical, &.{ "rev-parse", "--verify", "HEAD^{commit}" }) catch |err| switch (err) {
        error.NotRepository => blk: {
            // A failed HEAD lookup alone does not prove an unborn repository:
            // require a valid symbolic branch whose ref is genuinely absent.
            const ref = try git(allocator, io, canonical, &.{ "symbolic-ref", "--quiet", "HEAD" });
            defer allocator.free(ref);
            if (!std.mem.startsWith(u8, ref, "refs/heads/")) return error.NotRepository;
            const checked = try git(allocator, io, canonical, &.{ "check-ref-format", ref });
            defer allocator.free(checked);
            if (try gitRef(allocator, io, canonical, &.{ "show-ref", "--verify", "--quiet", ref }, true)) |resolved| {
                allocator.free(resolved);
                return error.NotRepository;
            }
            break :blk "";
        },
        else => return err,
    };
    errdefer if (binding.base_revision.len != 0) allocator.free(binding.base_revision);
    binding.expected_branch = if (binding.base_revision.len == 0)
        try git(allocator, io, canonical, &.{ "symbolic-ref", "--quiet", "--short", "HEAD" })
    else
        try git(allocator, io, canonical, &.{ "rev-parse", "--abbrev-ref", "HEAD" });
    binding.non_git = false;
    return binding;
}
pub fn verify(allocator: std.mem.Allocator, io: std.Io, binding: t.WorkspaceBinding) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const actual = try capture(arena.allocator(), io, binding.canonical_root);
    return t.adapter.equal(actual, binding);
}

/// Continued execution belongs to the checkout and symbolic branch, rather
/// than the revision captured when the workspace was registered. Snapshot
/// consumers retain strict verify; detached HEAD remains revision-bound.
pub fn verifyCheckout(allocator: std.mem.Allocator, io: std.Io, binding: t.WorkspaceBinding) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var actual = try capture(arena.allocator(), io, binding.canonical_root);
    if (!binding.non_git and !actual.non_git and binding.expected_branch.len != 0 and
        !std.mem.eql(u8, binding.expected_branch, "HEAD")) actual.base_revision = binding.base_revision;
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
