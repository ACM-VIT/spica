const std = @import("std");

pub const Options = struct {
    help: bool = false,
    quit_after_ms: ?u32 = null,
    metrics_output: ?[]const u8 = null,
    automation_output: ?[]const u8 = null,
    metrics_capacity: u32 = 8192,
    state_directory: ?[]const u8 = null,
    automation_live: ?[]const u8 = null,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--help")) {
                options.help = true;
            } else if (std.mem.eql(u8, flag, "--quit-after-ms")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.quit_after_ms = try std.fmt.parseInt(u32, args[index], 10);
            } else if (std.mem.eql(u8, flag, "--state-directory")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                options.state_directory = args[index];
            } else if (std.mem.eql(u8, flag, "--automation-live")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                options.automation_live = args[index];
            } else if (std.mem.eql(u8, flag, "--metrics-output") or std.mem.eql(u8, flag, "--automation-output")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                if (std.mem.eql(u8, flag, "--metrics-output")) options.metrics_output = args[index] else options.automation_output = args[index];
            } else if (std.mem.eql(u8, flag, "--metrics-capacity")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.metrics_capacity = try std.fmt.parseInt(u32, args[index], 10);
                if (options.metrics_capacity == 0 or options.metrics_capacity > 1048576) return error.InvalidCapacity;
            } else return error.UnknownOption;
        }
        return options;
    }
};

/// Native rewrite's independent namespace. No legacy discovery or migration.
pub fn defaultStateDirectory(allocator: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg_data_home) |root| {
        if (std.fs.path.isAbsolute(root)) return std.fs.path.join(allocator, &.{ root, "spica-native", "conversation" });
    }
    const root = home orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(root)) return error.HomeUnavailable;
    return std.fs.path.join(allocator, &.{ root, ".local", "share", "spica-native", "conversation" });
}

test "native default state path is independent and honors absolute XDG only" {
    const allocator = std.testing.allocator;
    const xdg = try defaultStateDirectory(allocator, "/temporary/data", "/temporary/home");
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/temporary/data/spica-native/conversation", xdg);
    const fallback = try defaultStateDirectory(allocator, "relative", "/temporary/home");
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("/temporary/home/.local/share/spica-native/conversation", fallback);
    try std.testing.expectError(error.HomeUnavailable, defaultStateDirectory(allocator, null, null));
}

pub const help =
    \\Spica — native coding workspace
    \\Usage: spica [--state-directory DIRECTORY] [--quit-after-ms MILLISECONDS]
    \\
    \\--state-directory overrides the independent durable fake-provider conversation.
    \\Default: $XDG_DATA_HOME/spica-native/conversation ($HOME/.local/share fallback).
    \\Enter sends; Shift+Enter inserts newline. F6 cancels; F7 allows; F8 denies.
    \\Escape dismisses local editing state. Ctrl+Q or window close exits.
    \\--quit-after-ms exits after a bounded smoke run (0 exits immediately).
    \\--automation-output PATH exports the read-only final native snapshot.
    \\--automation-live PATH enables bounded read-only painted snapshots (adds file I/O).
    \\--metrics-output PATH enables bounded frame timestamps and text-cache ledger.
    \\--metrics-capacity N bounds retained attempts (default 8192; max 1048576).
    \\Keep the checkout's .deps and assets; rebuild after moving the checkout.
    \\
;

test "smoke deadline is bounded and legacy runtime flags are rejected" {
    try std.testing.expect((try Options.parse(&.{"spica"})).quit_after_ms == null);
    try std.testing.expect((try Options.parse(&.{ "spica", "--help" })).help);
    try std.testing.expectEqual(@as(u32, 0), (try Options.parse(&.{ "spica", "--quit-after-ms", "0" })).quit_after_ms.?);
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--quit-after-ms" }));
    try std.testing.expectError(error.Overflow, Options.parse(&.{ "spica", "--quit-after-ms", "4294967296" }));
    try std.testing.expectError(error.Overflow, Options.parse(&.{ "spica", "--quit-after-ms", "-1" }));
    try std.testing.expectError(error.UnknownOption, Options.parse(&.{ "spica", "--pi-entry", "agent.js" }));
}

test "telemetry options require values and bounded capacity" {
    const options = try Options.parse(&.{ "spica", "--metrics-output", "frames.json", "--automation-output", "snapshot.json", "--metrics-capacity", "2" });
    try std.testing.expectEqualStrings("frames.json", options.metrics_output.?);
    try std.testing.expectEqual(@as(u32, 2), options.metrics_capacity);
    try std.testing.expectError(error.InvalidCapacity, Options.parse(&.{ "spica", "--metrics-capacity", "0" }));
    try std.testing.expectError(error.InvalidCapacity, Options.parse(&.{ "spica", "--metrics-capacity", "1048577" }));
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--automation-output" }));
}
