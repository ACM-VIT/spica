const std = @import("std");
const c = @import("contract.zig");
const native = @import("runtime/native_factory.zig");
const fixture = "src/runtime/factory_process_fixture.sh";
const selection: c.Selection = .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "test-model", .effort = "medium", .account_ref = "/tmp/spica-test-account", .workspace = .{ .value = "opaque-workspace" } };

test "factory metadata is side effect free and exact" {
    var config: native.NativeFactory = .{ .configs = &.{.{ .selection = selection, .executable = "/does/not/exist", .environment = &.{} }} };
    const factory = config.asFactory();
    try std.testing.expectEqual(.unknown, factory.accountStatus(selection).readiness);
    try std.testing.expectEqual(.unknown, factory.resolveSelection(selection).readiness);
    try std.testing.expectEqual(.supported, factory.discover(selection).capabilities[@intFromEnum(c.Capability.create)].status);
    try std.testing.expectEqual(.unsupported, factory.discover(selection).capabilities[@intFromEnum(c.Capability.message)].status);
    var other = selection;
    other.account_ref = "/another/account";
    try std.testing.expectEqual(.unavailable, factory.accountStatus(other).readiness);
    try std.testing.expectError(error.SelectionUnavailable, factory.create(std.testing.allocator, other, "/tmp", .{ .value = "rejected" }, null));
    try std.testing.expectError(error.SpawnFailed, factory.create(std.testing.allocator, selection, "/tmp", .{ .value = "failed" }, null));
}

fn independentSessions(comptime kind: enum { codex, opencode }) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), fixture, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const terminated = try std.testing.allocator.dupeZ(u8, executable);
    defer std.testing.allocator.free(terminated);
    var chosen = selection;
    chosen.runtime_kind = @tagName(kind);
    chosen.required_runtime_version = if (kind == .codex) "0.163.0" else "2.1.4";
    var config: native.NativeFactory = .{ .configs = &.{.{ .selection = chosen, .executable = terminated, .environment = &.{} }} };
    const factory = config.asFactory();
    const first = try factory.create(std.testing.allocator, chosen, "/tmp", .{ .value = "first" }, null);
    defer factory.destroy(std.testing.allocator, first);
    var first_stopped = false;
    defer if (!first_stopped) first.shutdown();
    const second = try factory.create(std.testing.allocator, chosen, "/tmp", .{ .value = "second" }, null);
    defer factory.destroy(std.testing.allocator, second);
    defer second.shutdown();
    const Runtime = if (kind == .codex) @import("runtime/codex.zig").Runtime else @import("runtime/opencode.zig").Runtime;
    const left: *Runtime = @ptrCast(@alignCast(first.context));
    const right: *Runtime = @ptrCast(@alignCast(second.context));
    const left_wire = if (kind == .codex) left.wire else &left.transport;
    const right_wire = if (kind == .codex) right.wire else &right.transport;
    try std.testing.expect(first.context != second.context);
    try std.testing.expect(left_wire.process.pid != right_wire.process.pid);
    try std.testing.expectEqualStrings("first", if (kind == .codex) left.config.instance else left.config.instance.value);
    try std.testing.expectEqualStrings("second", if (kind == .codex) right.config.instance else right.config.instance.value);
    first.shutdown();
    first_stopped = true;
    try std.testing.expect(right_wire.process.pid > 0);
    try std.testing.expect(!right_wire.exited);
    try right_wire.send("{\"other_session\":\"still-alive\"}");
    var received = false;
    for (0..100) |_| {
        try right_wire.pump();
        while (try right_wire.poll(std.testing.allocator)) |line| {
            defer std.testing.allocator.free(line);
            if (std.mem.eql(u8, line, "{\"other_session\":\"still-alive\"}")) received = true;
        }
        if (received) break;
        _ = @import("runtime/transport.zig").c.spica_process_poll(&right_wire.process, -1, 0, 10);
    }
    try std.testing.expect(received);
}

test "two concrete sessions retain independent processes and cancellation ownership" {
    try independentSessions(.codex);
    try independentSessions(.opencode);
}

fn failedCreation(a: std.mem.Allocator) !void {
    for ([_][]const u8{ "codex", "opencode" }) |kind| {
        var chosen = selection;
        chosen.runtime_kind = kind;
        chosen.required_runtime_version = if (std.mem.eql(u8, kind, "codex")) "0.163.0" else "2.1.4";
        var config: native.NativeFactory = .{ .configs = &.{.{ .selection = chosen, .executable = "/does/not/exist", .environment = &.{} }} };
        const factory = config.asFactory();
        const adapter = factory.create(a, chosen, "/tmp", .{ .value = "allocation-failure" }, .{ .url = "http://127.0.0.1/mcp/session", .token = "isolated-fixture" }) catch |err| {
            if (err == error.SpawnFailed) continue;
            return err;
        };
        adapter.shutdown();
        factory.destroy(a, adapter);
        return error.UnexpectedSpawn;
    }
}

test "factory cleans every partial allocation failure for both providers" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failedCreation, .{});
}

fn spawnedCreation(a: std.mem.Allocator, executable: [:0]const u8) !void {
    for ([_][]const u8{ "codex", "opencode" }) |kind| {
        var chosen = selection;
        chosen.runtime_kind = kind;
        chosen.required_runtime_version = if (std.mem.eql(u8, kind, "codex")) "0.163.0" else "2.1.4";
        var config: native.NativeFactory = .{ .configs = &.{.{ .selection = chosen, .executable = executable, .environment = &.{} }} };
        const factory = config.asFactory();
        const adapter = try factory.create(a, chosen, "/tmp", .{ .value = "post-spawn-allocation" }, .{ .url = "http://127.0.0.1/mcp/session", .token = "isolated-fixture" });
        defer factory.destroy(a, adapter);
        defer adapter.shutdown();
    }
}

test "factory cleans allocation failure after successful owned process spawn" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const path = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), fixture, std.testing.allocator);
    defer std.testing.allocator.free(path);
    const executable = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(executable);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, spawnedCreation, .{executable});
}

test "mixed factory authorizes runtime account provider and retains explicit child model effort" {
    var secondary = selection;
    secondary.runtime_kind = "opencode";
    secondary.required_runtime_version = "2.1.4";
    secondary.model_provider = "opencode";
    secondary.account_ref = "/tmp/separate-opencode-account";
    var config: native.NativeFactory = .{ .configs = &.{
        .{ .selection = selection, .executable = "/does/not/exist", .environment = &.{} },
        .{ .selection = secondary, .executable = "/does/not/exist", .environment = &.{} },
    } };
    const factory = config.asFactory();
    var child = secondary;
    child.model_id = "explicit-child-model";
    child.effort = "low";
    child.workspace.value = "child-workspace";
    try std.testing.expectEqual(.unknown, factory.resolveSelection(child).readiness);
    try std.testing.expectEqualStrings("explicit-child-model", factory.resolveSelection(child).requested.model_id);
    try std.testing.expectEqualStrings("low", factory.resolveSelection(child).requested.effort);
    try std.testing.expectError(error.SpawnFailed, factory.create(std.testing.allocator, child, "/tmp", .{ .value = "mixed-child" }, null));
    child.account_ref = selection.account_ref;
    try std.testing.expectEqual(.unavailable, factory.resolveSelection(child).readiness);
    child = secondary;
    child.model_provider = "unauthorized-provider";
    try std.testing.expectEqual(.unavailable, factory.resolveSelection(child).readiness);
    child = secondary;
    child.model_id = "";
    try std.testing.expectEqual(.unavailable, factory.resolveSelection(child).readiness);
    child = secondary;
    child.account_ref = "";
    try std.testing.expectEqual(.unavailable, factory.resolveSelection(child).readiness);
    child = secondary;
    child.runtime_kind = "unconfigured";
    try std.testing.expectEqual(.unavailable, factory.resolveSelection(child).readiness);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const path = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), fixture, std.testing.allocator);
    defer std.testing.allocator.free(path);
    const executable = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(executable);
    config.configs = &.{
        .{ .selection = selection, .executable = executable, .environment = &.{} },
        .{ .selection = secondary, .executable = executable, .environment = &.{} },
    };
    child = secondary;
    child.model_id = "explicit-child-model";
    child.effort = "low";
    const codex = try factory.create(std.testing.allocator, selection, "/tmp", .{ .value = "mixed-codex" }, null);
    defer factory.destroy(std.testing.allocator, codex);
    defer codex.shutdown();
    const opencode = try factory.create(std.testing.allocator, child, "/tmp", .{ .value = "mixed-opencode" }, null);
    defer factory.destroy(std.testing.allocator, opencode);
    defer opencode.shutdown();
    const runtime: *@import("runtime/opencode.zig").Runtime = @ptrCast(@alignCast(opencode.context));
    try std.testing.expect(c.equal(runtime.selection, child));
    try std.testing.expect(codex.vtable != opencode.vtable);
}
