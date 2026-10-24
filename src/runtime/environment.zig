//! Explicit owned child environments. Never copy credentials between accounts.
const std = @import("std");
const c = @import("../contract.zig");

// Desktop keyring/session access and normal executable discovery for Codex.
// Deliberately omit provider API keys and the parent's CODEX_HOME.
const session_keys = [_][]const u8{ "HOME", "PATH", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "LANG", "LC_ALL", "SSH_AUTH_SOCK" };

/// Arena-owned snapshot, captured before the Host worker starts.
pub fn capture(a: std.mem.Allocator, environ: std.process.Environ) ![]const [:0]const u8 {
    var values: std.array_list.Managed([:0]const u8) = .init(a);
    for (session_keys) |key| {
        const value = environ.getPosix(key) orelse continue;
        if (value.len > 4096) return error.EnvironmentValueTooLong;
        try values.append(try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ key, value }, 0));
    }
    return values.toOwnedSlice();
}

/// Caller supplies arena/fixed-buffer ownership for the complete configuration.
pub fn build(a: std.mem.Allocator, kind: c.RuntimeKind, account: []const u8, session: []const [:0]const u8) ![]const [:0]const u8 {
    if (kind == .codex and session.len != 0) {
        if (session.len > session_keys.len) return error.EnvironmentLimit;
        const values = try a.alloc([:0]const u8, session.len + 1);
        for (session, 0..) |value, i| values[i] = try a.dupeZ(u8, value);
        values[session.len] = try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{account}, 0);
        return values;
    }
    const codex = kind == .codex;
    const values = try a.alloc([:0]const u8, if (codex) 7 else 9);
    values[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{account}, 0);
    values[1] = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{account}, 0);
    values[2] = try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{account}, 0);
    values[3] = try std.fmt.allocPrintSentinel(a, "XDG_CACHE_HOME={s}/cache", .{account}, 0);
    values[4] = try std.fmt.allocPrintSentinel(a, "XDG_STATE_HOME={s}/state", .{account}, 0);
    values[5] = if (codex) try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{account}, 0) else try std.fmt.allocPrintSentinel(a, "OPENCODE_CONFIG_DIR={s}/config/opencode", .{account}, 0);
    values[6] = "PATH=/usr/bin:/bin";
    if (!codex) {
        values[7] = try std.fmt.allocPrintSentinel(a, "OPENCODE_TEST_HOME={s}", .{account}, 0);
        values[8] = "OPENCODE_DISABLE_CLAUDE_CODE=1";
    }
    return values;
}

test "selected Codex home stays pinned while session environment is owned; OpenCode stays isolated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var home = [_:0]u8{ 'H', 'O', 'M', 'E', '=', '/', 'u' };
    const session: []const [:0]const u8 = &.{ &home, "PATH=/user/bin:/usr/bin", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" };
    const values = try build(a, .codex, "/chosen/账号", session);
    home[6] = 'x';
    try std.testing.expectEqualStrings("HOME=/u", values[0]);
    try std.testing.expectEqualStrings(session[2], values[2]);
    try std.testing.expectEqualStrings("CODEX_HOME=/chosen/账号", values[3]);
    const isolated = try build(a, .opencode, "/separate", session);
    try std.testing.expectEqualStrings("HOME=/separate", isolated[0]);
    try std.testing.expectEqualStrings("OPENCODE_TEST_HOME=/separate", isolated[7]);
}

test "session capture excludes API credentials and inherited Codex home" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = [_:null]?[*:0]const u8{ "HOME=/user", "PATH=/user/bin", "CODEX_HOME=/wrong", "OPENAI_API_KEY=fixture-secret", "DBUS_SESSION_BUS_ADDRESS=unix:path=/fixture/bus" };
    const values = try capture(arena.allocator(), .{ .block = .{ .slice = &entries } });
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("HOME=/user", values[0]);
    try std.testing.expectEqualStrings("PATH=/user/bin", values[1]);
    try std.testing.expectEqualStrings("DBUS_SESSION_BUS_ADDRESS=unix:path=/fixture/bus", values[2]);
}
