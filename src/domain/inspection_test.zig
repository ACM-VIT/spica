const std = @import("std");
const inspection = @import("inspection.zig");
const io = std.testing.io;
const a = std.testing.allocator;

const Fixture = struct {
    temporary: std.testing.TmpDir,
    root: []const u8,
    fn init() !Fixture {
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try temporary.dir.realPath(io, &path);
        const root = try a.dupe(u8, path[0..n]);
        errdefer a.free(root);
        try git(root, &.{ "init", "--initial-branch=fixture" });
        try temporary.dir.writeFile(io, .{ .sub_path = "file space λ\n.txt", .data = "base\n" });
        try temporary.dir.writeFile(io, .{ .sub_path = "deleted", .data = "deleted base\n" });
        try temporary.dir.writeFile(io, .{ .sub_path = "old name", .data = "rename content\n" });
        try temporary.dir.writeFile(io, .{ .sub_path = ":(glob)*", .data = "literal base\n" });
        try git(root, &.{ "add", "--", "." });
        try git(root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "base" });
        return .{ .temporary = temporary, .root = root };
    }
    fn deinit(f: *Fixture) void {
        a.free(f.root);
        f.temporary.cleanup();
    }
    fn write(f: *Fixture, path: []const u8, data: []const u8) !void {
        try f.temporary.dir.writeFile(io, .{ .sub_path = path, .data = data });
    }
};
fn git(root: []const u8, args: []const []const u8) !void {
    var argv: [24][]const u8 = undefined;
    argv[0..3].* = .{ "git", "-C", root };
    @memcpy(argv[3..][0..args.len], args);
    const output = try std.process.run(a, io, .{ .argv = argv[0 .. args.len + 3], .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
    defer a.free(output.stdout);
    defer a.free(output.stderr);
    if (output.term != .exited or output.term.exited != 0) return error.GitFixtureFailed;
}
fn entry(result: inspection.Result, path: []const u8) !inspection.Entry {
    for (result.entries) |e| if (std.mem.eql(u8, e.path, path)) return e;
    return error.MissingEntry;
}
fn expectContains(bytes: []const u8, text: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, text) != null);
}

test "requested roots, aliases and raw rename deletion untracked states stay separate" {
    var left = try Fixture.init();
    defer left.deinit();
    var right = try Fixture.init();
    defer right.deinit();
    try left.write("file space λ\n.txt", "left staged\n");
    try git(left.root, &.{ "add", "--", "file space λ\n.txt" });
    try left.write("file space λ\n.txt", "left unstaged\n");
    try left.write("untracked λ\n", "untracked left\n");
    try git(left.root, &.{ "mv", "--", "old name", "new λ\nname" });
    try git(left.root, &.{ "rm", "--", "deleted" });
    try right.write("file space λ\n.txt", "RIGHT ONLY\n");
    var captured = try inspection.capture(a, io, left.root, .{});
    defer captured.deinit(a);
    try std.testing.expectError(error.MissingBinding, inspection.inspect(a, io, null, left.root, .status, .{}));
    try std.testing.expectError(error.WrongCheckout, inspection.inspect(a, io, captured.binding, right.root, .status, .{}));
    const alias = try std.fmt.allocPrint(a, "{s}/../{s}", .{ left.root, std.fs.path.basename(left.root) });
    defer a.free(alias);
    var status = try inspection.inspect(a, io, captured.binding, alias, .status, .{});
    defer status.deinit(a);
    const modified = try entry(status, "file space λ\n.txt");
    try std.testing.expectEqual(@as(u8, 'M'), modified.index);
    try std.testing.expectEqual(@as(u8, 'M'), modified.worktree);
    const renamed = try entry(status, "new λ\nname");
    try std.testing.expectEqual(@as(u8, 'R'), renamed.index);
    try std.testing.expectEqualStrings("old name", renamed.original_path.?);
    try std.testing.expectEqual(@as(u8, 'D'), (try entry(status, "deleted")).index);
    try std.testing.expectEqual(@as(u8, '?'), (try entry(status, "untracked λ\n")).index);
    for ([_]bool{ true, false }) |staged| {
        var diff = try inspection.inspect(a, io, captured.binding, left.root, .{ .diff = .{ .path = "file space λ\n.txt", .staged = staged } }, .{});
        defer diff.deinit(a);
        try expectContains(diff.bytes, if (staged) "+left staged" else "+left unstaged");
        try std.testing.expect(std.mem.indexOf(u8, diff.bytes, "RIGHT ONLY") == null);
    }
    var deleted = try inspection.inspect(a, io, captured.binding, left.root, .{ .diff = .{ .path = "deleted", .staged = true } }, .{});
    defer deleted.deinit(a);
    try expectContains(deleted.bytes, "-deleted base");
    try std.testing.expectError(error.UntrackedDiffUnavailable, inspection.inspect(a, io, captured.binding, left.root, .{ .diff = .{ .path = "untracked λ\n" } }, .{}));
    var other = try inspection.capture(a, io, right.root, .{});
    defer other.deinit(a);
    var other_diff = try inspection.inspect(a, io, other.binding, right.root, .{ .diff = .{ .path = "file space λ\n.txt" } }, .{});
    defer other_diff.deinit(a);
    try expectContains(other_diff.bytes, "+RIGHT ONLY");
    try std.testing.expect(std.mem.indexOf(u8, other_diff.bytes, "left unstaged") == null);
}

test "literal pathspecs and canonical owned path admission" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(":(glob)*", "literal modified\n");
    try f.write("file space λ\n.txt", "not selected\n");
    var captured = try inspection.capture(a, io, f.root, .{});
    defer captured.deinit(a);
    var result = try inspection.inspect(a, io, captured.binding, f.root, .{ .diff = .{ .path = ":(glob)*" } }, .{});
    defer result.deinit(a);
    try expectContains(result.bytes, "+literal modified");
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "not selected") == null);
    try f.temporary.dir.symLink(io, "/tmp", "escape", .{});
    for ([_][]const u8{ "", ".", "../file", "/etc/passwd", "a//b", "a/./b", "escape/file", "a\x00b" }) |path| {
        try std.testing.expectError(error.InvalidOwnedPath, inspection.inspect(a, io, captured.binding, f.root, .{ .diff = .{ .path = path } }, .{}));
    }
    try f.temporary.dir.symLink(io, f.root, "alias", .{});
    const alias = try std.fmt.allocPrint(a, "{s}/alias", .{f.root});
    defer a.free(alias);
    var aliased = try inspection.inspect(a, io, captured.binding, alias, .status, .{});
    defer aliased.deinit(a);
    try std.testing.expect(aliased.entries.len == 4);
}

test "wrong replaced binding and repository subdirectories refuse explicitly" {
    var f = try Fixture.init();
    defer f.deinit();
    var captured = try inspection.capture(a, io, f.root, .{});
    defer captured.deinit(a);
    var changed = captured.binding.?;
    changed.filesystem_identity = "replaced";
    try std.testing.expectError(error.WorkspaceIdentityChanged, inspection.inspect(a, io, changed, f.root, .status, .{}));
    changed = captured.binding.?;
    changed.checkout_identity = "another checkout";
    try std.testing.expectError(error.WorkspaceIdentityChanged, inspection.inspect(a, io, changed, f.root, .status, .{}));
    try git(f.root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "advance" });
    try std.testing.expectError(error.WorkspaceIdentityChanged, inspection.inspect(a, io, captured.binding, f.root, .status, .{}));
    try f.temporary.dir.createDir(io, "nested", .default_dir);
    const nested = try std.fmt.allocPrint(a, "{s}/nested", .{f.root});
    defer a.free(nested);
    var subdirectory = try inspection.capture(a, io, nested, .{});
    defer subdirectory.deinit(a);
    try std.testing.expect(!subdirectory.binding.?.non_git);
    try std.testing.expectError(error.NotCheckoutRoot, inspection.inspect(a, io, subdirectory.binding, nested, .status, .{}));
    try std.testing.expectError(error.InvalidRoot, inspection.capture(a, io, "", .{}));
    try std.testing.expectError(error.InvalidRoot, inspection.capture(a, io, ".", .{}));
}

test "bounded outputs files allocation and time configuration refuse instead of clipping" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("untracked one", "one");
    try f.write("untracked two", "two");
    try f.write("file space λ\n.txt", "a long enough diff to exceed eight bytes\n");
    var captured = try inspection.capture(a, io, f.root, .{});
    defer captured.deinit(a);
    try std.testing.expectError(error.FileLimit, inspection.inspect(a, io, captured.binding, f.root, .status, .{ .files = 1 }));
    try std.testing.expectError(error.StreamTooLong, inspection.inspect(a, io, captured.binding, f.root, .status, .{ .output_bytes = 8 }));
    try std.testing.expectError(error.StreamTooLong, inspection.inspect(a, io, captured.binding, f.root, .{ .diff = .{ .path = "file space λ\n.txt" } }, .{ .diff_bytes = 8 }));
    try std.testing.expectError(error.OutOfMemory, inspection.capture(a, io, f.root, .{ .memory_bytes = 32 }));
    try std.testing.expectError(error.InvalidLimits, inspection.capture(a, io, f.root, .{ .milliseconds = 0 }));
    try std.testing.expectError(error.InvalidLimits, inspection.capture(a, io, f.root, .{ .milliseconds = 30001 }));
}

test "actual root replacement refuses retained identity before status" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "repo", .default_dir);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(io, &buffer);
    const root = try std.fmt.allocPrint(a, "{s}/repo", .{buffer[0..n]});
    defer a.free(root);
    try git(root, &.{ "init", "--initial-branch=fixture" });
    try git(root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "base" });
    var captured = try inspection.capture(a, io, root, .{});
    defer captured.deinit(a);
    try temporary.dir.rename("repo", temporary.dir, "old", io);
    try temporary.dir.createDir(io, "repo", .default_dir);
    try git(root, &.{ "init", "--initial-branch=fixture" });
    try git(root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "replacement" });
    try std.testing.expectError(error.WorkspaceIdentityChanged, inspection.inspect(a, io, captured.binding, root, .status, .{}));
}

test "NUL parser preserves raw bytes and rejects malformed or excess records" {
    const entries = try inspection.parseStatus(a, "R  new λ\n\x00old space\x00?? raw\xff\x00", 2);
    defer a.free(entries);
    try std.testing.expectEqualStrings("new λ\n", entries[0].path);
    try std.testing.expectEqualStrings("old space", entries[0].original_path.?);
    try std.testing.expectEqualStrings("raw\xff", entries[1].path);
    try std.testing.expectError(error.FileLimit, inspection.parseStatus(a, "?? one\x00?? two\x00", 1));
    try std.testing.expectError(error.MalformedStatus, inspection.parseStatus(a, "R  missing\x00", 5));
    try std.testing.expectError(error.MalformedStatus, inspection.parseStatus(a, "?? missing terminator", 5));
    try std.testing.expectError(error.MalformedStatus, inspection.parseStatus(a, "\x00?? trailing\x00", 5));
}

test "unborn capture staged inspection reopen and first commit identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(io, &path);
    const root = path[0..n];
    try git(root, &.{ "init", "--initial-branch=unborn-fixture" });
    var captured = try inspection.capture(a, io, root, .{});
    defer captured.deinit(a);
    const binding = captured.binding.?;
    try std.testing.expect(!binding.non_git);
    try std.testing.expectEqualStrings(root, binding.canonical_root);
    try std.testing.expect(binding.filesystem_identity.len != 0);
    const metadata = try std.fmt.allocPrint(a, "{s}/.git", .{root});
    defer a.free(metadata);
    try std.testing.expectEqualStrings(metadata, binding.repository_identity);
    try std.testing.expectEqualStrings(metadata, binding.checkout_identity);
    try std.testing.expectEqualStrings("unborn-fixture", binding.expected_branch);
    try std.testing.expectEqualStrings("", binding.base_revision);
    var fresh = try inspection.inspect(a, io, binding, root, .status, .{});
    defer fresh.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), fresh.entries.len);
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "first staged\n" });
    try git(root, &.{ "add", "--", "first" });
    var reopened = try inspection.capture(a, io, root, .{});
    defer reopened.deinit(a);
    try std.testing.expect(@import("types.zig").adapter.equal(binding, reopened.binding.?));
    var staged = try inspection.inspect(a, io, binding, root, .{ .diff = .{ .path = "first", .staged = true } }, .{});
    defer staged.deinit(a);
    try expectContains(staged.bytes, "+first staged");
    try temporary.dir.writeFile(io, .{ .sub_path = "first", .data = "first unstaged\n" });
    var unstaged = try inspection.inspect(a, io, binding, root, .{ .diff = .{ .path = "first" } }, .{});
    defer unstaged.deinit(a);
    try expectContains(unstaged.bytes, "+first unstaged");
    try git(root, &.{ "symbolic-ref", "HEAD", "refs/heads/replacement" });
    try std.testing.expectError(error.WorkspaceIdentityChanged, inspection.inspect(a, io, binding, root, .status, .{}));
    try git(root, &.{ "symbolic-ref", "HEAD", "refs/heads/unborn-fixture" });
    try git(root, &.{ "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "first" });
    try std.testing.expectError(error.WorkspaceIdentityChanged, inspection.inspect(a, io, binding, root, .status, .{}));
    try git(root, &.{ "checkout", "--detach" });
    var detached = try inspection.capture(a, io, root, .{});
    defer detached.deinit(a);
    try std.testing.expectEqualStrings("HEAD", detached.binding.?.expected_branch);
    try std.testing.expect(detached.binding.?.base_revision.len != 0);
    var detached_status = try inspection.inspect(a, io, detached.binding, root, .status, .{});
    defer detached_status.deinit(a);
}

test "malformed HEAD and missing branch objects are not unborn or non Git" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(io, &path);
    const root = path[0..n];
    try git(root, &.{ "init", "--initial-branch=fixture" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".git/refs/heads/fixture", .data = "1111111111111111111111111111111111111111\n" });
    try std.testing.expectError(error.NotRepository, inspection.capture(a, io, root, .{}));
    try temporary.dir.writeFile(io, .{ .sub_path = ".git/refs/heads/fixture", .data = "malformed\n" });
    try std.testing.expectError(error.NotRepository, inspection.capture(a, io, root, .{}));
    try temporary.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "1111111111111111111111111111111111111111\n" });
    try std.testing.expectError(error.NotRepository, inspection.capture(a, io, root, .{}));
    try temporary.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "malformed\n" });
    try std.testing.expectError(error.NotRepository, inspection.capture(a, io, root, .{}));
}
