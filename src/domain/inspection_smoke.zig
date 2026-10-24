//! Real isolated command-line consumer, intentionally independent of native UI.
const std = @import("std");
const inspection = @import("inspection.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    run(a, io, args) catch |err| {
        const message = try std.json.Stringify.valueAlloc(a, .{ .ok = false, .refusal = @errorName(err) }, .{});
        try std.Io.File.stdout().writeStreamingAll(io, message);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        std.process.exit(1);
    };
}
fn run(a: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len < 3) return error.UsageExpectedAbsoluteRootStatusOrDiffStagedOrUnstagedPath;
    var captured = try inspection.capture(a, io, args[1], .{});
    defer captured.deinit(a);
    const query: inspection.Query = if (std.mem.eql(u8, args[2], "status") and args.len == 3)
        .status
    else if (std.mem.eql(u8, args[2], "diff") and args.len == 5)
        .{ .diff = .{ .staged = if (std.mem.eql(u8, args[3], "staged")) true else if (std.mem.eql(u8, args[3], "unstaged")) false else return error.InvalidDiffMode, .path = args[4] } }
    else
        return error.InvalidArguments;
    var result = try inspection.inspect(a, io, captured.binding, args[1], query, .{});
    defer result.deinit(a);
    const DisplayEntry = struct { index: [1]u8, worktree: [1]u8, path: ?[]const u8, path_hex: []const u8, original_path: ?[]const u8, original_path_hex: ?[]const u8 };
    const entries = try a.alloc(DisplayEntry, result.entries.len);
    for (entries, result.entries) |*out, entry| out.* = .{
        .index = .{entry.index},
        .worktree = .{entry.worktree},
        .path = utf8(entry.path),
        .path_hex = try std.fmt.allocPrint(a, "{x}", .{entry.path}),
        .original_path = if (entry.original_path) |path| utf8(path) else null,
        .original_path_hex = if (entry.original_path) |path| try std.fmt.allocPrint(a, "{x}", .{path}) else null,
    };
    const binding = captured.binding.?;
    const json = try std.json.Stringify.valueAlloc(a, .{
        .ok = true,
        .root = utf8(binding.canonical_root),
        .root_hex = try std.fmt.allocPrint(a, "{x}", .{binding.canonical_root}),
        .repository = utf8(binding.repository_identity),
        .checkout = utf8(binding.checkout_identity),
        .branch = utf8(binding.expected_branch),
        .revision = binding.base_revision,
        .entries = entries,
        .diff = if (query == .diff) utf8(result.bytes) else null,
        .diff_hex = if (query == .diff) try std.fmt.allocPrint(a, "{x}", .{result.bytes}) else null,
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(io, json);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
fn utf8(bytes: []const u8) ?[]const u8 {
    return if (std.unicode.utf8ValidateSlice(bytes)) bytes else null;
}
