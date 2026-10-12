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

pub fn verify(process: *c.SpicaProcess, node: [:0]const u8, entry: [:0]const u8, version: []u8, length: *usize) !void {
    length.* = 0;
    return switch (c.spica_process_version(process, node.ptr, entry.ptr, version.ptr, version.len, length)) {
        c.SPICA_PROCESS_OK => {},
        c.SPICA_PROCESS_VERSION_MISMATCH, c.SPICA_PROCESS_OUTPUT_OVERFLOW => error.PiVersionMismatch,
        c.SPICA_PROCESS_SPAWN_FAILED => error.PiVerifierLaunchFailed,
        c.SPICA_PROCESS_TIMED_OUT => error.PiVerifierTimedOut,
        else => error.PiVerifierFailed,
    };
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
    // Discovery must not load code from the launch directory: empty and relative
    // PATH entries can select files controlled by an untrusted project. Explicit
    // --node/--pi-entry overrides still go through candidate directly.
    if (!std.fs.path.isAbsolute(directory)) return null;
    const joined = try std.fs.path.join(allocator, &.{ directory, name });
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

pub const Failure = struct {
    node: []const u8 = "",
    entry: []const u8 = "",
    version: []const u8 = "",
};

const Shown = struct {
    bytes: []const u8,

    pub fn format(self: Shown, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const limit = 240;
        var index: usize = 0;
        while (index < self.bytes.len and index < limit) {
            const byte = self.bytes[index];
            if (byte >= 0x80) {
                const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
                if (length > 0 and index + length <= self.bytes.len and std.unicode.utf8ValidateSlice(self.bytes[index .. index + length])) {
                    try writer.writeAll(self.bytes[index .. index + length]);
                    index += length;
                    continue;
                }
            }
            try writer.writeByte(if (byte < 0x20 or byte == 0x7f or byte >= 0x80) '?' else byte);
            index += 1;
        }
        if (index < self.bytes.len) try writer.writeAll("...");
    }
};

fn shown(bytes: []const u8) Shown {
    return .{ .bytes = bytes };
}

pub fn describe(allocator: std.mem.Allocator, err: anyerror, failure: Failure) !?[]u8 {
    const version = std.mem.trim(u8, failure.version, " \t\r\n");
    return switch (err) {
        error.InvalidNodePath => try std.fmt.allocPrint(allocator, "--node {f} is not an executable file. Pass --node /path/to/node.", .{shown(failure.node)}),
        error.InvalidPiEntryPath => try std.fmt.allocPrint(allocator, "--pi-entry {f} is not a readable file. Pass --pi-entry /path/to/cli.js.", .{shown(failure.entry)}),
        error.PiVersionMismatch => if (version.len == 0)
            try std.fmt.allocPrint(allocator, "Pi 1.0.0 required; {f} printed no version. Pass --pi-entry /path/to/cli.js. Node: {f}", .{ shown(failure.entry), shown(failure.node) })
        else
            try std.fmt.allocPrint(allocator, "Pi 1.0.0 required, found {f} at {f}. Pass --pi-entry /path/to/cli.js. Node: {f}", .{ shown(version), shown(failure.entry), shown(failure.node) }),
        error.PiVerifierLaunchFailed => try std.fmt.allocPrint(allocator, "Could not run Node at {f} to check Pi. Pass --node /path/to/node. Pi entry: {f}", .{ shown(failure.node), shown(failure.entry) }),
        error.PiVerifierFailed => try std.fmt.allocPrint(allocator, "Pi version check exited with an error. Check --node {f} and --pi-entry {f}.", .{ shown(failure.node), shown(failure.entry) }),
        error.PiVerifierTimedOut => try std.fmt.allocPrint(allocator, "Pi version check timed out after 5s; Force stop it, then check --node {f} and --pi-entry {f}.", .{ shown(failure.node), shown(failure.entry) }),
        else => null,
    };
}

pub fn errorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NodeNotFound => "Node was not found. Install Node or pass --node /path/to/node. Finder may not see nvm/fnm; launch Spica from your terminal or use explicit paths.",
        error.InvalidNodePath => "The --node path is not an executable file. Pass --node /path/to/node.",
        error.InvalidPiEntryPath => "The --pi-entry path is not a readable file. Pass --pi-entry /path/to/cli.js.",
        error.PiEntryNotFound => "Pi's JavaScript entry was not found. Install Pi 1.0.0 or pass --pi-entry /path/to/cli.js (and --node /path/to/node if needed). Unrecognized shell wrappers require an explicit JS entry.",
        error.NpmGlobalLookupFailed => "npm root -g failed or timed out. Pass --pi-entry /path/to/cli.js and, if needed, --node /path/to/node.",
        error.PiVersionMismatch => "Pi 1.0.0 is required but a different version was found. Install Pi 1.0.0 or pass --pi-entry /path/to/cli.js.",
        error.PiVerifierLaunchFailed => "Node could not be started to check Pi's version. Pass --node /path/to/node.",
        error.PiVerifierFailed => "Pi's version check failed. Pass --pi-entry /path/to/cli.js and, if needed, --node /path/to/node.",
        error.PiVerifierTimedOut => "Pi's version check did not finish within 5 seconds; it is still owned and can be force stopped. Check --node and --pi-entry.",
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

test "automatic discovery skips project-controlled empty and relative PATH entries" {
    const posix = @cImport({
        @cInclude("unistd.h");
    });
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Stand-in Node executes the fixture entries through sh, as in the npm test.
    try testFile(tmp.dir, "project/node", "#!/bin/sh\nexec /bin/sh \"$@\"\n", true);
    try tmp.dir.symLink(io, "payload.js", "project/pi", .{});
    try tmp.dir.symLink(io, "payload.js", "project/npm", .{});
    try tmp.dir.createDirPath(io, "project/bin");
    inline for (.{ "node", "pi", "npm" }) |name| {
        try tmp.dir.symLink(io, "../" ++ name, "project/bin/" ++ name, .{});
    }
    try testFile(tmp.dir, "installed/node", "#!/bin/sh\nexec /bin/sh \"$@\"\n", true);
    try testFile(tmp.dir, "installed/cli.js", "printf '1.0.0\\n'\n", false);
    try tmp.dir.symLink(io, "cli.js", "installed/pi", .{});
    try tmp.dir.symLink(io, "cli.js", "installed/npm", .{});
    const installed = try tmp.dir.realPathFileAlloc(io, "installed", a);
    defer a.free(installed);
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const payload = try std.fmt.allocPrint(a, "printf ran > \"{s}/executed\"\nprintf '1.0.0\\n'\n", .{project});
    defer a.free(payload);
    try testFile(tmp.dir, "project/payload.js", payload, false);
    const original_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    defer a.free(original_cwd);
    // Restore the process-wide cwd before any other test or fixture cleanup.
    try std.testing.expectEqual(@as(c_int, 0), posix.chdir(project));
    defer std.debug.assert(posix.chdir(original_cwd) == 0);
    var process = testProcess();
    defer c.spica_process_dispose(&process);
    var version_length: usize = 0;
    for ([_][]const u8{ "", ".", "bin", "./bin", "../project/bin", ":.", ".:", "::" }) |unsafe_path| {
        inline for (.{ "node", "pi", "npm" }) |name| {
            const js = !std.mem.eql(u8, name, "node");
            const unsafe = try find(a, io, name, unsafe_path, &.{}, js);
            defer if (unsafe) |value| a.free(value);
            try std.testing.expect(unsafe == null);
            const expected = (try inDirectory(a, io, installed, name, js)).?;
            defer a.free(expected);
            const fallback = (try find(a, io, name, unsafe_path, &.{installed}, js)).?;
            defer a.free(fallback);
            try std.testing.expectEqualStrings(expected, fallback);
        }
        const mixed_path = try std.fmt.allocPrint(a, "{s}:{s}", .{ unsafe_path, installed });
        defer a.free(mixed_path);
        const found = try discover(a, io, &process, null, null, mixed_path, &.{});
        defer found.deinit(a);
        try std.testing.expect(std.mem.endsWith(u8, found.node, "/installed/node"));
        try std.testing.expect(std.mem.endsWith(u8, found.entry, "/installed/cli.js"));
        try std.testing.expectEqual(@as(c_int, c.SPICA_PROCESS_OK), c.spica_process_version(&process, found.node, found.entry, null, 0, &version_length));
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "project/executed", .{}));
    // Project-local tools remain available when explicitly selected by the user.
    const overridden = try discover(a, io, &process, "node", "pi", "", &.{});
    defer overridden.deinit(a);
    try std.testing.expect(std.mem.endsWith(u8, overridden.node, "/project/node"));
    try std.testing.expect(std.mem.endsWith(u8, overridden.entry, "/project/payload.js"));
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
    var version_length: usize = 0;
    const found = try discover(a, io, &process, null, null, null, &.{bin});
    defer found.deinit(a);
    try std.testing.expect(std.mem.endsWith(u8, found.entry, "/global packages /" ++ pi_suffix));
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
    try std.testing.expectEqual(@as(c_int, c.SPICA_PROCESS_OK), c.spica_process_version(&process, found.node, found.entry, null, 0, &version_length));
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
