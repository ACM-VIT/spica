const std = @import("std");
const App = @import("app.zig").App;
const options_module = @import("options.zig");
const c = @import("native/bindings.zig").c;
const telemetry = @import("native/metrics.zig");
const Host = @import("domain.zig").Host;
const Wake = @import("app.zig").Wake;
const contract = @import("contract.zig");
const common = @import("runtime/adapter.zig");
const transport = @import("runtime/transport.zig");
const Codex = @import("runtime/codex.zig");
const NativeFactory = @import("runtime/native_factory.zig").NativeFactory;

/// Final-address storage outlives the Host worker that exclusively owns IO.
const NativeProvider = struct {
    selection: ?contract.Selection = null,
    workspace_root: ?[]const u8 = null,
    factory: ?NativeFactory = null,

    fn init(self: *NativeProvider, a: std.mem.Allocator, io: std.Io, options: options_module.Options) !void {
        if (options.provider == .fake) return;
        const workspace_dir = try std.Io.Dir.cwd().openDir(io, options.workspace.?, .{});
        defer workspace_dir.close(io);
        const workspace = try std.Io.Dir.cwd().realPathFileAlloc(io, options.workspace.?, a);
        self.workspace_root = workspace;
        // Independent runtime-owned state only; never inherit credentials or history.
        try std.Io.Dir.cwd().createDirPath(io, options.runtime_account_directory.?);
        const account = try std.Io.Dir.cwd().realPathFileAlloc(io, options.runtime_account_directory.?, a);
        if (std.mem.eql(u8, workspace, account)) return error.AccountDirectoryIsWorkspace;
        self.selection = .{ .runtime_kind = @tagName(options.provider), .required_runtime_version = if (options.provider == .codex) "0.163.0" else "2.1.4", .model_provider = options.model_provider.?, .model_id = options.model.?, .effort = options.effort.?, .account_ref = account, .workspace = .{ .value = workspace } };
        const environment = try a.alloc([:0]const u8, 6);
        environment[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{account}, 0);
        environment[1] = try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{account}, 0);
        environment[2] = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{account}, 0);
        environment[3] = try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{account}, 0);
        environment[4] = try std.fmt.allocPrintSentinel(a, "XDG_CACHE_HOME={s}/cache", .{account}, 0);
        environment[5] = "PATH=/usr/bin:/bin";
        const executable = try a.dupeZ(u8, options.runtime_executable orelse if (options.provider == .codex) "/usr/bin/codex" else "/usr/bin/opencode");
        self.factory = .{ .selection = self.selection.?, .executable = executable, .environment = environment };
    }
    fn authenticate(self: *NativeProvider, a: std.mem.Allocator, io: std.Io, mode: @FieldType(options_module.Options, "codex_auth")) !void {
        const factory = if (self.factory) |*value| value.asFactory() else return error.CodexAuthRequiresCodex;
        const adapter = try factory.create(a, self.selection.?, self.workspace_root.?, .{ .value = "authentication" }, null);
        defer factory.destroy(a, adapter);
        defer adapter.shutdown();
        const runtime: *Codex.Runtime = @ptrCast(@alignCast(adapter.context));
        const start = transport.c.spica_monotonic_ms();
        while (!runtime.initialized or runtime.pending != null) {
            try runtime.pump();
            if (runtime.disconnected) return error.ProviderDisconnected;
            if (transport.c.spica_monotonic_ms() - start > 15000) return error.InitializeTimeout;
            _ = transport.c.spica_process_poll(&runtime.wire.process, -1, @intFromBool(runtime.wire.input_len != 0), 20);
        }
        if (mode == .status) {
            try std.Io.File.stdout().writeStreamingAll(io, if (runtime.readiness == .ready) "ChatGPT account ready in selected isolated state.\n" else "ChatGPT sign-in required in selected isolated state.\n");
            return;
        }
        try runtime.startLogin(mode == .device);
        var printed = false;
        const login_start = transport.c.spica_monotonic_ms();
        while (transport.c.spica_monotonic_ms() - login_start < 120000) {
            try runtime.pump();
            if (!printed and runtime.login.len != 0) {
                try std.Io.File.stdout().writeStreamingAll(io, runtime.login);
                try std.Io.File.stdout().writeStreamingAll(io, "\nComplete this supported ChatGPT sign-in; waiting up to 120 seconds.\n");
                printed = true;
            }
            if (runtime.readiness == .ready) return;
            if (runtime.diagnostic.len != 0) {
                try std.Io.File.stderr().writeStreamingAll(io, runtime.diagnostic);
                return error.SignInFailed;
            }
            if (runtime.disconnected) return error.ProviderDisconnected;
            _ = transport.c.spica_process_poll(&runtime.wire.process, -1, @intFromBool(runtime.wire.input_len != 0), 20);
        }
        return error.SignInIncomplete;
    }
};

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
    const provider = try arena.allocator().create(NativeProvider);
    provider.* = .{};
    try provider.init(arena.allocator(), threaded.io(), options);
    if (options.codex_auth != .none) {
        try provider.authenticate(std.heap.page_allocator, threaded.io(), options.codex_auth);
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
    defer app.disconnect();
    {
        const directory = options.state_directory orelse try options_module.defaultStateDirectory(arena.allocator(), init.environ.getPosix("XDG_DATA_HOME"), init.environ.getPosix("HOME"));
        host = try Host.create(std.heap.page_allocator, threaded.io(), .{ .state_directory = directory, .wake = Wake.notify, .wake_context = &wake, .factory = if (provider.factory) |*factory| factory.asFactory() else null, .selection = provider.selection, .workspace_root = provider.workspace_root });
        const dir = try std.Io.Dir.cwd().openDir(threaded.io(), directory, .{});
        defer dir.close(threaded.io());
        var workspace_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const workspace_length = try dir.realPath(threaded.io(), &workspace_buffer);
        const spool = try dir.createFile(threaded.io(), ".ui-projection", .{ .read = true });
        errdefer spool.close(threaded.io());
        // Derived content is descriptor-owned and disappears even after a crash.
        try dir.deleteFile(threaded.io(), ".ui-projection");
        try app.connect(threaded.io(), host.?, spool, &wake, if (provider.selection) |selection| selection.workspace.value else workspace_buffer[0..workspace_length]);
    }
    if (options.lua_module) |path| try app.configureLua(threaded.io(), path, &wake);
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
