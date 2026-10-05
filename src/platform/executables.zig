const std = @import("std");
const builtin = @import("builtin");
pub const c = @cImport({
    @cInclude("../platform/process.h");
    @cInclude("stdlib.h");
});

const pi_suffix = "@earendil-works/pi-coding-agent/dist/bundle/cli.js";

pub const Executables = struct {
    node: [:0]u8,
    entry: [:0]u8,

    pub fn deinit(self: Executables, allocator: std.mem.Allocator) void {
        allocator.free(self.node);
        allocator.free(self.entry);
    }
};

// Only the fallback directories are OS-specific; discovery and ownership are shared.
fn fallbackDirectories(os: std.Target.Os.Tag) []const []const u8 {
    return switch (os) {
        .macos => &.{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" },
        .linux => &.{ "/usr/local/bin", "/usr/bin" },
        else => &.{},
    };
}

pub fn resolve(allocator: std.mem.Allocator, io: std.Io, process: *c.SpicaProcess, node: ?[]const u8, entry: ?[]const u8) !Executables {
    const path = if (c.getenv("PATH")) |value| std.mem.span(value) else null;
    return discover(allocator, io, process, node, entry, path, fallbackDirectories(builtin.os.tag));
}

fn discover(allocator: std.mem.Allocator, io: std.Io, process: *c.SpicaProcess, node_override: ?[]const u8, entry_override: ?[]const u8, path: ?[]const u8, fallbacks: []const []const u8) !Executables {
    const node = if (node_override) |value|
        (try candidate(allocator, io, value, false)) orelse return error.InvalidNodePath
    else
        (try find(allocator, io, "node", path, fallbacks, false)) orelse return error.NodeNotFound;
    errdefer allocator.free(node);
    if (entry_override) |value| {
        const entry = (try candidate(allocator, io, value, true)) orelse return error.InvalidPiEntryPath;
        return .{ .node = node, .entry = entry };
    }
    if (try find(allocator, io, "pi", path, fallbacks, true)) |entry| return .{ .node = node, .entry = entry };

    const npm = (try find(allocator, io, "npm", path, fallbacks, true)) orelse return error.PiEntryNotFound;
    defer allocator.free(npm);
    var output: [4096]u8 = undefined;
    var length: usize = 0;
    if (c.spica_process_npm_root(process, node, npm, &output, output.len, &length) != 0) return error.NpmGlobalLookupFailed;
    // Preserve spaces in directory names; reject diagnostics, multiple lines, and NULs.
    const root = std.mem.trimEnd(u8, output[0..length], "\r\n");
    if (!std.fs.path.isAbsolute(root) or std.mem.indexOfAny(u8, root, "\r\n\x00") != null) return error.NpmGlobalLookupFailed;
    const entry_path = try std.fs.path.join(allocator, &.{ root, pi_suffix });
    defer allocator.free(entry_path);
    const entry = (try candidate(allocator, io, entry_path, true)) orelse return error.PiEntryNotFound;
    return .{ .node = node, .entry = entry };
}

fn candidate(allocator: std.mem.Allocator, io: std.Io, path: []const u8, readable: bool) !?[:0]u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return null;
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    errdefer allocator.free(resolved);
    const dir = std.Io.Dir.cwd();
    const stat = dir.statFile(io, resolved, .{}) catch {
        allocator.free(resolved);
        return null;
    };
    if (stat.kind != .file) {
        allocator.free(resolved);
        return null;
    }
    dir.access(io, resolved, .{ .read = readable, .execute = !readable }) catch {
        allocator.free(resolved);
        return null;
    };
    return resolved;
}

fn javascript(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.mem.eql(u8, extension, ".js") or std.mem.eql(u8, extension, ".mjs") or std.mem.eql(u8, extension, ".cjs");
}

fn shimEntry(allocator: std.mem.Allocator, io: std.Io, shim: []const u8) !?[:0]u8 {
    // pnpm records its source path in a comment. Read metadata, never execute or
    // interpret the shell wrapper (including its environment changes and arguments).
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, shim, allocator, .limited(16384)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(bytes);
    const prefix = "# cmd-shim-target=";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const target = line[prefix.len..];
        if (!std.fs.path.isAbsolute(target) or !javascript(target)) return null;
        return candidate(allocator, io, target, true);
    }
    return null;
}

fn inDirectory(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, name: []const u8, js: bool) !?[:0]u8 {
    const joined = try std.fs.path.join(allocator, &.{ if (directory.len == 0) "." else directory, name });
    defer allocator.free(joined);
    const resolved = (try candidate(allocator, io, joined, js)) orelse return null;
    if (js and !javascript(resolved)) {
        defer allocator.free(resolved);
        return shimEntry(allocator, io, resolved);
    }
    return resolved;
}

fn find(allocator: std.mem.Allocator, io: std.Io, name: []const u8, path: ?[]const u8, fallbacks: []const []const u8, js: bool) !?[:0]u8 {
    if (path) |value| {
        var directories = std.mem.splitScalar(u8, value, ':');
        while (directories.next()) |directory| {
            if (try inDirectory(allocator, io, directory, name, js)) |resolved| return resolved;
        }
    }
    for (fallbacks) |directory| {
        if (try inDirectory(allocator, io, directory, name, js)) |resolved| return resolved;
    }
    return null;
}

pub fn errorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NodeNotFound => "Node was not found. Install Node or pass --node /path/to/node. Finder may not see nvm/fnm; launch Spica from your terminal or use explicit paths.",
        error.InvalidNodePath => "The --node path is not an executable file. Pass --node /path/to/node.",
        error.InvalidPiEntryPath => "The --pi-entry path is not a readable file. Pass --pi-entry /path/to/cli.js.",
        error.PiEntryNotFound => "Pi's JavaScript entry was not found. Install Pi 1.0.0 or pass --pi-entry /path/to/cli.js (and --node /path/to/node if needed). Unrecognized shell wrappers require an explicit JS entry.",
        error.NpmGlobalLookupFailed => "npm root -g failed or timed out. Pass --pi-entry /path/to/cli.js and, if needed, --node /path/to/node.",
        else => null,
    };
}

fn testFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8, executable: bool) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes, .flags = .{
        .permissions = .fromMode(if (executable) 0o755 else 0o644),
    } });
}

fn testProcess() c.SpicaProcess {
    return .{ .input = -1, .output = -1, .@"error" = -1, .exit_fd = -1, .pid = 0 };
}

test "executable overrides win and invalid overrides never fall back" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "custom node", "#!/bin/sh\nexit 0\n", true);
    try testFile(tmp.dir, "custom entry", "unused", false);
    const node = try tmp.dir.realPathFileAlloc(io, "custom node", a);
    defer a.free(node);
    const entry = try tmp.dir.realPathFileAlloc(io, "custom entry", a);
    defer a.free(entry);
    var process = testProcess();
    const found = try discover(a, io, &process, node, entry, null, &.{});
    defer found.deinit(a);
    try std.testing.expectEqualStrings(node, found.node);
    try std.testing.expectEqualStrings(entry, found.entry);
    try std.testing.expectError(error.InvalidNodePath, discover(a, io, &process, "", entry, null, &.{}));
    try std.testing.expectError(error.InvalidPiEntryPath, discover(a, io, &process, node, "", null, &.{}));
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
}

test "PATH precedes platform fallbacks, resolves symlinks and skips directories and shell shims" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bad/node");
    try testFile(tmp.dir, "bad/pi", "#!/bin/sh\nexit 0\n", true);
    try testFile(tmp.dir, "no execute/node", "unused", false);
    try testFile(tmp.dir, "version bin/node", "#!/bin/sh\nexit 0\n", true);
    try testFile(tmp.dir, "package/cli.js", "unused", false);
    try tmp.dir.symLink(io, "../package/cli.js", "version bin/pi", .{});
    try testFile(tmp.dir, "fallback/node", "#!/bin/sh\nexit 0\n", true);
    try tmp.dir.symLink(io, "../package/cli.js", "fallback/pi", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrint(a, "{s}/missing:{s}/bad:{s}/no execute:{s}/version bin", .{ root, root, root, root });
    defer a.free(path);
    const fallback = try std.fs.path.join(a, &.{ root, "fallback" });
    defer a.free(fallback);
    var process = testProcess();
    const found = try discover(a, io, &process, null, null, path, &.{fallback});
    defer found.deinit(a);
    try std.testing.expect(std.mem.endsWith(u8, found.node, "/version bin/node"));
    try std.testing.expect(std.mem.endsWith(u8, found.entry, "/package/cli.js"));
    const fallback_found = try discover(a, io, &process, null, null, null, &.{fallback});
    defer fallback_found.deinit(a);
    try std.testing.expect(std.mem.endsWith(u8, fallback_found.node, "/fallback/node"));
    const overridden = try discover(a, io, &process, fallback_found.node, found.entry, path, &.{fallback});
    defer overridden.deinit(a);
    try std.testing.expectEqualStrings(fallback_found.node, overridden.node);
    try std.testing.expectEqualStrings(found.entry, overridden.entry);
    try std.testing.expectError(error.NodeNotFound, discover(a, io, &process, null, null, null, &.{}));
    try std.testing.expectError(error.PiEntryNotFound, discover(a, io, &process, found.node, null, null, &.{}));
}

test "npm fallback uses resolved Node, global lookup and bounded output without a shell" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stand-in Node runs the stand-in JS files through sh, letting the test verify argv.
    try testFile(tmp.dir, "bin/node", "#!/bin/sh\nexec /bin/sh \"$@\"\n", true);
    try testFile(tmp.dir, "bin/npm-cli.js",
        \\#!/bin/sh
        \\[ "$1" = root ] && [ "$2" = -g ] && [ "$3" = --loglevel=error ] || exit 1
        \\printf '%s\n' "$(/usr/bin/dirname "$0")/global packages "
        \\
    , false);
    try tmp.dir.symLink(io, "npm-cli.js", "bin/npm", .{});
    try testFile(tmp.dir, "bin/global packages /" ++ pi_suffix, "#!/bin/sh\nprintf '1.0.0\\n'\n", false);
    const bin = try tmp.dir.realPathFileAlloc(io, "bin", a);
    defer a.free(bin);
    var process = testProcess();
    defer c.spica_process_dispose(&process);
    const found = try discover(a, io, &process, null, null, null, &.{bin});
    defer found.deinit(a);
    try std.testing.expect(std.mem.endsWith(u8, found.entry, "/global packages /" ++ pi_suffix));
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
    try std.testing.expectEqual(@as(c_int, 0), c.spica_process_version(&process, found.node, found.entry));
    try testFile(tmp.dir, "bin/npm-cli.js", "printf 'relative/package/path\\n'\n", false);
    try std.testing.expectError(error.NpmGlobalLookupFailed, discover(a, io, &process, null, null, bin, &.{}));
    try testFile(tmp.dir, "bin/npm-cli.js", "i=0; while [ $i -lt 5000 ]; do printf x; i=$((i+1)); done\n", false);
    try std.testing.expectError(error.NpmGlobalLookupFailed, discover(a, io, &process, null, null, bin, &.{}));
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
}

test "platform fallback lists are separate and discovery failures are actionable" {
    try std.testing.expectEqualStrings("/opt/homebrew/bin", fallbackDirectories(.macos)[0]);
    try std.testing.expectEqualStrings("/usr/local/bin", fallbackDirectories(.linux)[0]);
    try std.testing.expectEqual(@as(usize, 0), fallbackDirectories(.windows).len);
    try std.testing.expect(std.mem.indexOf(u8, errorMessage(error.NodeNotFound).?, "--node") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorMessage(error.PiEntryNotFound).?, "--pi-entry") != null);
}

test "pnpm target metadata resolves shim and entry symlinks without running the wrapper" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "node", "#!/bin/sh\nexit 0\n", true);
    try testFile(tmp.dir, "global packages/cli.js", "unused", false);
    try tmp.dir.symLink(io, "cli.js", "global packages/current.js", .{});
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const node = try tmp.dir.realPathFileAlloc(io, "node", a);
    defer a.free(node);
    const wrapper = try std.fmt.allocPrint(a, "#!/bin/sh\nprintf ran > \"{s}/executed\"\n# cmd-shim-target={s}/global packages/current.js\r\n", .{ root, root });
    defer a.free(wrapper);
    try testFile(tmp.dir, "bin/pi", wrapper, true);
    try tmp.dir.createDirPath(io, "path bin");
    try tmp.dir.symLink(io, "../bin/pi", "path bin/pi", .{});
    const path = try std.fs.path.join(a, &.{ root, "path bin" });
    defer a.free(path);
    var process = testProcess();
    const found = try discover(a, io, &process, node, null, path, &.{});
    defer found.deinit(a);
    try std.testing.expect(std.mem.endsWith(u8, found.entry, "/global packages/cli.js"));
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "executed", .{}));
    for ([_][]const u8{
        "#!/bin/sh\n# cmd-shim-target=$HOME/cli.js\n",
        "#!/bin/sh\n# cmd-shim-target=relative/cli.js\n",
        "#!/bin/sh\n# cmd-shim-target=/nonexistent/cli.js\n",
        "#!/bin/sh\n# cmd-shim-target=/bin/sh\n",
    }) |invalid| {
        try testFile(tmp.dir, "bin/pi", invalid, true);
        try std.testing.expectError(error.PiEntryNotFound, discover(a, io, &process, node, null, path, &.{}));
    }
}

test "timed-out npm lookup stays owned for explicit force and reap" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testFile(tmp.dir, "node", "#!/bin/sh\nexec /bin/sh \"$@\"\n", true);
    try testFile(tmp.dir, "npm-cli.js", "exec /bin/sleep 60\n", false);
    try tmp.dir.symLink(io, "npm-cli.js", "npm", .{});
    const bin = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(bin);
    var process = testProcess();
    defer {
        if (process.pid > 0) {
            _ = c.spica_process_force(&process);
            c.spica_close(process.output);
            c.spica_close(process.@"error");
            process.output = -1;
            process.@"error" = -1;
            _ = c.spica_process_poll(&process, -1, 0, 5000);
            var status: c_int = 0;
            _ = c.spica_process_reap(&process, &status);
        }
        c.spica_process_dispose(&process);
    }
    const started = c.spica_monotonic_ms();
    try std.testing.expectError(error.NpmGlobalLookupFailed, discover(a, io, &process, null, null, bin, &.{}));
    try std.testing.expect(c.spica_monotonic_ms() - started >= 4900);
    try std.testing.expect(process.pid > 0);
    try std.testing.expectEqual(@as(c_int, 0), c.spica_process_force(&process));
    c.spica_close(process.output);
    c.spica_close(process.@"error");
    process.output = -1;
    process.@"error" = -1;
    try std.testing.expect(c.spica_process_poll(&process, -1, 0, 5000) & 16 != 0);
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 1), c.spica_process_reap(&process, &status));
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
}
