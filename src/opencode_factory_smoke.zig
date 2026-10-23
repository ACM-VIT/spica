//! Installed ACP factory ownership consumer; no mock transport or MCP endpoint.
const std = @import("std");
const c = @import("contract.zig");
const common = @import("runtime/adapter.zig");
const NativeFactory = @import("runtime/native_factory.zig").NativeFactory;
const OpenCode = @import("runtime/opencode.zig").Runtime;
extern "c" fn usleep(u32) c_int;

fn tick(adapter: common.Adapter, a: std.mem.Allocator) !?c.Observation {
    try adapter.pump();
    return adapter.poll(a);
}
fn open(adapter: common.Adapter, a: std.mem.Allocator, selection: c.Selection, id: []const u8) !void {
    for (0..1500) |_| {
        if (try tick(adapter, a)) |event| {
            if (event.body == .failure or event.body == .disconnect) {
                std.debug.print("INITIALIZATION {any}\n", .{event.body});
                return error.InitializationFailed;
            }
        }
        if (adapter.ready()) break;
        _ = usleep(10000);
    } else return error.InitializeTimeout;
    _ = try adapter.dispatch(a, .{ .open = .{ .create = .{ .effect = .{ .value = id }, .session = .{ .value = id }, .selection = selection } } });
    for (0..1500) |_| {
        if (try tick(adapter, a)) |event| switch (event.body) {
            .session => {
                if (adapter.resolveSelection(selection).effective == null) return error.SelectionNotVerified;
                std.debug.print("SESSION {s} upstream={s}\n", .{ id, event.body.session.upstream.value });
                return;
            },
            .failure, .disconnect => return error.OpenFailed,
            else => {},
        };
        _ = usleep(10000);
    }
    return error.OpenTimeout;
}
pub fn main(init: std.process.Init.Minimal) !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer if (heap.deinit() != .ok) @panic("factory consumer leaked allocations");
    const backing = heap.allocator();
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len != 4) return error.ExpectedExecutableWorkspaceAccount;
    const cwd = args[2];
    const environment = try a.alloc([:0]const u8, 9);
    environment[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{args[3]}, 0);
    environment[1] = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{args[3]}, 0);
    environment[2] = try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{args[3]}, 0);
    environment[3] = try std.fmt.allocPrintSentinel(a, "XDG_CACHE_HOME={s}/cache", .{args[3]}, 0);
    environment[4] = try std.fmt.allocPrintSentinel(a, "XDG_STATE_HOME={s}/state", .{args[3]}, 0);
    environment[5] = "PATH=/usr/bin:/bin";
    environment[6] = try std.fmt.allocPrintSentinel(a, "OPENCODE_CONFIG_DIR={s}/config/opencode", .{args[3]}, 0);
    environment[7] = "OPENCODE_DISABLE_CLAUDE_CODE=1";
    // Installed v2.1.4's Global.home explicitly uses this override, not HOME.
    environment[8] = try std.fmt.allocPrintSentinel(a, "OPENCODE_TEST_HOME={s}", .{args[3]}, 0);
    const selection: c.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "opencode", .model_id = "big-pickle", .effort = "default", .account_ref = args[3], .workspace = .{ .value = "factory-disposable" } };
    var native: NativeFactory = .{ .configs = &.{.{ .selection = selection, .executable = try a.dupeZ(u8, args[1]), .environment = environment }} };
    const factory = native.asFactory();
    const first = try factory.create(backing, selection, cwd, .{ .value = "factory-first" }, null);
    var first_live = true;
    defer if (first_live) {
        first.shutdown();
        factory.destroy(backing, first);
    };
    try open(first, a, selection, "factory-first");
    const second = try factory.create(backing, selection, cwd, .{ .value = "factory-second" }, null);
    defer {
        second.shutdown();
        factory.destroy(backing, second);
    }
    const one: *OpenCode = @ptrCast(@alignCast(first.context));
    const two: *OpenCode = @ptrCast(@alignCast(second.context));
    if (one == two or one.transport.process.pid <= 0 or one.transport.process.pid == two.transport.process.pid) return error.ProcessesNotIndependent;
    std.debug.print("PROCESSES first={d} second={d}; buffers first={x} second={x}\n", .{ one.transport.process.pid, two.transport.process.pid, @intFromPtr(&one.storage), @intFromPtr(&two.storage) });
    try open(second, a, selection, "factory-second");
    const correlation: c.Correlation = .{ .session = .{ .value = "factory-first" }, .run = .{ .value = "cancel-run" }, .effect = .{ .value = "first-start" } };
    _ = try first.dispatch(a, .{ .start = .{ .correlation = correlation, .prompt = "Write a very long explanation of the integers from 1 to 1000. Do not use tools." } });
    _ = try first.dispatch(a, .{ .cancel = .{ .correlation = correlation, .reason = "factory isolation smoke" } });
    var cancelled = false;
    for (0..2000) |_| {
        if (try tick(first, a)) |event| switch (event.body) {
            .cancelled => {
                cancelled = true;
                break;
            },
            .failure, .disconnect => return error.CancelledProviderFailed,
            else => {},
        };
        _ = usleep(10000);
    }
    if (!cancelled) return error.CancellationNotObserved;
    first.shutdown();
    factory.destroy(backing, first);
    first_live = false;
    std.debug.print("ASSERT first cancellation observed; first process shutdown/destroy; second remains owned\n", .{});
    _ = try second.dispatch(a, .{ .start = .{ .correlation = .{ .session = .{ .value = "factory-second" }, .run = .{ .value = "survivor-run" }, .effect = .{ .value = "second-start" } }, .prompt = "Reply exactly SPICA_FACTORY_SURVIVOR. Do not use tools." } });
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..6000) |_| {
        if (try tick(second, a)) |event| switch (event.body) {
            .chunk => |chunk| try text.writer.writeAll(chunk.text),
            .completed => {
                if (std.mem.indexOf(u8, text.written(), "SPICA_FACTORY_SURVIVOR") == null) return error.MissingSurvivorText;
                std.debug.print("ASSERT second process completed after first destruction; text={s}\n", .{text.written()});
                break;
            },
            .failure, .disconnect => return error.SurvivorFailed,
            else => {},
        };
        _ = usleep(10000);
    } else return error.SurvivorTimeout;
    var failing: NativeFactory = .{ .configs = &.{.{ .selection = selection, .executable = "/bin/false", .environment = environment }} };
    const failed_factory = failing.asFactory();
    const failed = try failed_factory.create(backing, selection, cwd, .{ .value = "failed-process" }, null);
    defer {
        failed.shutdown();
        failed_factory.destroy(backing, failed);
    }
    for (0..200) |_| {
        _ = tick(failed, a) catch break;
        if (failed.ready()) break;
        _ = usleep(10000);
    }
    if (!failed.ready()) return error.FailedProcessNeverReady;
    _ = failed.dispatch(a, .{ .open = .{ .create = .{ .effect = .{ .value = "failed-open" }, .session = .{ .value = "failed-process" }, .selection = selection } } }) catch {
        std.debug.print("ASSERT failed process rejects open and is shutdown/destroy owned; DebugAllocator checks cleanup at exit\n", .{});
        return;
    };
    return error.FailedProcessAcceptedOpen;
}
