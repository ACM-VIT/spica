const std = @import("std");
const App = @import("app.zig").App;
const options_module = @import("options.zig");
const c = @import("native/bindings.zig").c;
const telemetry = @import("native/metrics.zig");
const Host = @import("domain.zig").Host;
const Wake = @import("app.zig").Wake;

fn exportJson(io: std.Io, path: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{ .whitespace = .indent_2 });
    defer std.heap.page_allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn exportIdentity(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator)) |existing| return existing else |err| {
        if (err != error.FileNotFound) return err;
    }
    // Resolve parent symlinks even when the output does not exist yet.
    const parent = std.fs.path.dirname(path) orelse ".";
    const real_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);
    return std.fs.path.resolve(allocator, &.{ real_parent, std.fs.path.basename(path) });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    const options = options_module.Options.parse(args) catch |err| {
        std.log.err("Invalid command line: {s}. Use --help for supported options.", .{@errorName(err)});
        return err;
    };
    if (options.help) {
        try std.Io.File.stdout().writeStreamingAll(threaded.io(), options_module.help);
        return;
    }
    const exports = [_]?[]const u8{ options.metrics_output, options.automation_output, options.automation_live };
    for (exports, 0..) |path, index| {
        if (path) |value| {
            const identity = try exportIdentity(threaded.io(), arena.allocator(), value);
            for (exports[index + 1 ..]) |other| if (other) |other_value| {
                const other_identity = try exportIdentity(threaded.io(), arena.allocator(), other_value);
                if (std.mem.eql(u8, identity, other_identity)) return error.ExportPathsMustDiffer;
            };
        }
    }
    var app = App.init(std.heap.page_allocator) catch |err| {
        std.log.err("Native foundation startup failed: {s}; SDL: {s}", .{ @errorName(err), c.SDL_GetError() });
        return err;
    };
    defer app.deinit();
    var wake = Wake{ .event_type = c.SDL_RegisterEvents(1) };
    if (wake.event_type == 0) return error.UserEventRegistration;
    var host: ?*Host = null;
    defer if (host) |value| value.destroy();
    if (options.state_directory) |directory| {
        host = try Host.create(std.heap.page_allocator, threaded.io(), .{ .state_directory = directory, .wake = Wake.notify, .wake_context = &wake });
        const dir = try std.Io.Dir.cwd().openDir(threaded.io(), directory, .{});
        defer dir.close(threaded.io());
        var workspace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const workspace_length = try dir.realPath(threaded.io(), &workspace_buffer);
        const spool = try dir.createFile(threaded.io(), ".ui-projection", .{ .read = true });
        errdefer spool.close(threaded.io());
        // Derived content is descriptor-owned and disappears even after a crash.
        try dir.deleteFile(threaded.io(), ".ui-projection");
        try app.connect(threaded.io(), host.?, spool, &wake, workspace_buffer[0..workspace_length]);
    }
    if (options.automation_live) |path| try app.enableLive(threaded.io(), path);
    const storage: []telemetry.Frame = if (options.metrics_output != null)
        try std.heap.page_allocator.alloc(telemetry.Frame, options.metrics_capacity)
    else
        &.{};
    defer if (options.metrics_output != null) std.heap.page_allocator.free(storage);
    const cache_storage: []telemetry.CacheChange = if (options.metrics_output != null)
        try std.heap.page_allocator.alloc(telemetry.CacheChange, @min(options.metrics_capacity, 256))
    else
        &.{};
    defer if (options.metrics_output != null) std.heap.page_allocator.free(cache_storage);
    if (options.metrics_output != null) app.metrics = .{ .storage = storage, .cache_storage = cache_storage };
    const mapping = if (options.metrics_output != null) telemetry.mapClock(c.SDL_GetTicksNS) else null;
    const run_result = app.run(options.quit_after_ms);
    if (run_result) |_| {} else |err| std.log.err("Native run failed before export: {s}", .{@errorName(err)});
    // All allocation, serialization and file I/O happen after run's end boundary.
    if (options.automation_output) |path| try exportJson(threaded.io(), path, app.snapshot);
    if (options.metrics_output) |path| {
        var stats: c.SpicaTextStats = undefined;
        const stats_ok = c.spica_text_get_stats(app.text, &stats);
        const metrics = &app.metrics.?;
        try exportJson(threaded.io(), path, .{
            .version = 2,
            .clock = "SDL_GetTicksNS monotonic nanoseconds",
            .clock_mapping = mapping,
            .begin_ns = metrics.begin_ns,
            .end_ns = metrics.end_ns,
            .capacity = metrics.storage.len,
            .attempts = metrics.attempts,
            .failures = metrics.failures,
            .dropped = metrics.dropped,
            .successful_presents = app.frames,
            .frames = metrics.samples(),
            .cache_observations = metrics.cacheSamples(),
            .cache_observations_dropped = metrics.cache_dropped,
            .cache_observation_failures = metrics.cache_observation_failures,
            .snapshot = app.snapshot,
            .renderer = std.mem.span(c.SDL_GetRendererName(app.renderer)),
            .video = std.mem.span(c.SDL_GetCurrentVideoDriver()),
            .hardware_acceleration = "not established by renderer name",
            .text_stats = if (stats_ok) @as(?c.SpicaTextStats, stats) else null,
            .text_stats_scope = "per-present and changed event-boundary ledgers plus final ledger; excludes transient between-boundary peaks, external metadata and driver memory",
            .run_error = if (run_result) |_| @as(?[]const u8, null) else |err| @errorName(err),
        });
    }
    run_result catch |err| {
        std.log.err("Native foundation stopped: {s}; SDL: {s}", .{ @errorName(err), c.SDL_GetError() });
        return err;
    };
}

test {
    _ = @import("ui/coding.zig");
    _ = @import("app.zig");
    _ = @import("ui/transcript.zig");
}
