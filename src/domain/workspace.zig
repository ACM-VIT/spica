//! Captures actual checkout identity; never trusts a display label as cwd.
const std = @import("std");
const t = @import("types.zig");
const c = @cImport({ @cInclude("sys/stat.h"); });
fn git(allocator: std.mem.Allocator, io: std.Io, root: []const u8, args: []const []const u8) ![]const u8 {
    var argv: [12][]const u8 = undefined;
    argv[0] = "git"; argv[1] = "-C"; argv[2] = root;
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
        .filesystem_identity = try std.fmt.allocPrint(allocator, "{d}:{d}", .{identity.st_dev, identity.st_ino}),
        .repository_identity = "", .checkout_identity = canonical,
        .expected_branch = "", .base_revision = "", .non_git = true,
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
