//! Application resources are owned, bounded paths. Packaged builds resolve
//! from the executable's directory, never from the launch working directory.
const std = @import("std");

pub const Directories = struct {
    fonts: []const u8,
    assets: []const u8,
    libraries: []const u8,
};

pub const Path = struct {
    const capacity = std.Io.Dir.max_path_bytes;
    bytes: [capacity]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Path) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }

    // Normalize absolute POSIX paths lexically. The OS executable-path API
    // already follows executable symlinks; resources need not exist yet.
    fn normalized(parts: []const []const u8) !Path {
        if (parts.len == 0 or parts[0].len == 0 or parts[0][0] != '/') return error.InvalidResourcePath;
        var result: Path = .{};
        result.bytes[0] = '/';
        result.len = 1;
        for (parts, 0..) |part, index| {
            if (part.len >= capacity) return error.ResourcePathTooLong;
            if (std.mem.indexOfScalar(u8, part, 0) != null or (index != 0 and std.fs.path.isAbsolutePosix(part))) return error.InvalidResourcePath;
            var segments = std.mem.splitScalar(u8, part, '/');
            while (segments.next()) |segment| {
                if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
                if (std.mem.eql(u8, segment, "..")) {
                    while (result.len > 1 and result.bytes[result.len - 1] != '/') result.len -= 1;
                    if (result.len > 1) result.len -= 1;
                    continue;
                }
                const separator: usize = @intFromBool(result.len != 1);
                if (separator + segment.len > capacity - 1 - result.len) return error.ResourcePathTooLong;
                if (separator != 0) {
                    result.bytes[result.len] = '/';
                    result.len += 1;
                }
                @memcpy(result.bytes[result.len..][0..segment.len], segment);
                result.len += segment.len;
            }
        }
        result.bytes[result.len] = 0;
        return result;
    }
};

pub const Paths = struct {
    fonts: Path,
    assets: Path,
    libraries: Path,

    /// Development directories must be explicit absolute paths from the build.
    /// Packaged builds use the process executable path and ignore those inputs.
    pub fn resolve(io: std.Io, relocatable: bool, development: Directories) !Paths {
        if (!relocatable) return .{
            .fonts = try Path.normalized(&.{development.fonts}),
            .assets = try Path.normalized(&.{development.assets}),
            .libraries = try Path.normalized(&.{development.libraries}),
        };
        var executable: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try std.process.executableDirPath(io, &executable);
        return fromExecutableDirectory(executable[0..len]);
    }

    /// Pure counterpart of resolve, useful for validating package layouts.
    /// Layout: bin/spica, lib/, share/spica/{fonts,assets}/.
    pub fn fromExecutableDirectory(directory: []const u8) !Paths {
        return .{
            .fonts = try Path.normalized(&.{ directory, "..", "share/spica/fonts" }),
            .assets = try Path.normalized(&.{ directory, "..", "share/spica/assets" }),
            .libraries = try Path.normalized(&.{ directory, "..", "lib" }),
        };
    }
};

test "resource paths resolve relocated unicode and spaces independently of cwd" {
    const paths = try Paths.fromExecutableDirectory("/opt/Spica 世界/release/./bin//");
    try std.testing.expectEqualStrings("/opt/Spica 世界/release/share/spica/fonts", paths.fonts.slice());
    try std.testing.expectEqualStrings("/opt/Spica 世界/release/share/spica/assets", paths.assets.slice());
    try std.testing.expectEqualStrings("/opt/Spica 世界/release/lib", paths.libraries.slice());
    try std.testing.expectEqual(@as(u8, 0), paths.fonts.bytes[paths.fonts.len]);
    const moved = try Paths.fromExecutableDirectory("/another launch/../moved/package/bin");
    try std.testing.expectEqualStrings("/moved/package/share/spica/fonts", moved.fonts.slice());
    const root = try Paths.fromExecutableDirectory("/bin");
    try std.testing.expectEqualStrings("/lib", root.libraries.slice());
}

test "resource development paths own their bytes and reject invalid or overflowing paths" {
    var font_directory = "/source/.deps/fonts".*;
    const paths = try Paths.resolve(std.testing.io, false, .{
        .fonts = &font_directory,
        .assets = "/source/assets/./",
        .libraries = "/source/native/../lib",
    });
    font_directory[1] = 'X';
    try std.testing.expectEqualStrings("/source/.deps/fonts", paths.fonts.slice());
    try std.testing.expectEqualStrings("/source/assets", paths.assets.slice());
    try std.testing.expectEqualStrings("/source/lib", paths.libraries.slice());
    try std.testing.expectError(error.InvalidResourcePath, Paths.fromExecutableDirectory("relative/bin"));
    try std.testing.expectError(error.InvalidResourcePath, Paths.fromExecutableDirectory(""));
    try std.testing.expectError(error.InvalidResourcePath, Paths.fromExecutableDirectory("/bad\x00/bin"));
    try std.testing.expectError(error.InvalidResourcePath, Paths.resolve(std.testing.io, false, .{ .fonts = "fonts", .assets = "/assets", .libraries = "/lib" }));
    const too_long = "/" ++ ("x" ** (std.Io.Dir.max_path_bytes - 6)) ++ "/bin";
    try std.testing.expectError(error.ResourcePathTooLong, Paths.fromExecutableDirectory(too_long));
}

test "resource runtime lookup uses the executable directory and ignores development paths" {
    var executable: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executableDirPath(std.testing.io, &executable);
    const expected = try Paths.fromExecutableDirectory(executable[0..len]);
    const actual = try Paths.resolve(std.testing.io, true, .{ .fonts = "ignored", .assets = "ignored", .libraries = "ignored" });
    try std.testing.expectEqualStrings(expected.fonts.slice(), actual.fonts.slice());
    try std.testing.expectEqualStrings(expected.assets.slice(), actual.assets.slice());
    try std.testing.expectEqualStrings(expected.libraries.slice(), actual.libraries.slice());
}
