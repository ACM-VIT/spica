const std = @import("std");
const App = @import("app.zig").App;
const options_module = @import("options.zig");
const c = @import("native/bindings.zig").c;
const telemetry = @import("native/metrics.zig");

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
    if (options.metrics_output) |metrics_path| if (options.automation_output) |automation_path| {
        const metrics_resolved = try exportIdentity(threaded.io(), arena.allocator(), metrics_path);
        const automation_resolved = try exportIdentity(threaded.io(), arena.allocator(), automation_path);
        if (std.mem.eql(u8, metrics_resolved, automation_resolved)) return error.ExportPathsMustDiffer;
    };
    var app = App.init(std.heap.page_allocator) catch |err| {
        std.log.err("Native foundation startup failed: {s}; SDL: {s}", .{ @errorName(err), c.SDL_GetError() });
        return err;
    };
    defer app.deinit();
    const storage: []telemetry.Frame = if (options.metrics_output != null)
        try std.heap.page_allocator.alloc(telemetry.Frame, options.metrics_capacity)
    else
        &.{};
    defer if (options.metrics_output != null) std.heap.page_allocator.free(storage);
    if (options.metrics_output != null) app.metrics = .{ .storage = storage };
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
            .version = 1,
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
            .snapshot = app.snapshot,
            .renderer = std.mem.span(c.SDL_GetRendererName(app.renderer)),
            .video = std.mem.span(c.SDL_GetCurrentVideoDriver()),
            .hardware_acceleration = "not established by renderer name",
            .text_stats = if (stats_ok) @as(?c.SpicaTextStats, stats) else null,
            .text_stats_scope = "per-present ledger plus final ledger; cache changes only during paint in this native shell; excludes external metadata and driver memory; no eviction or miss counters",
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
}
