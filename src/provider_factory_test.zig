const std = @import("std");
const c = @import("contract.zig");
const native = @import("runtime/native_factory.zig");
const fixture = "src/runtime/factory_process_fixture.sh";
const selection: c.Selection = .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "test-model", .effort = "medium", .account_ref = "/tmp/spica-test-account", .workspace = .{ .value = "opaque-workspace" } };

test "factory metadata is side effect free and exact" {
    var config: native.NativeFactory = .{ .selection = selection, .executable = "/does/not/exist", .environment = &.{} };
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

test "two concrete sessions retain independent processes and cancellation ownership" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), fixture, std.testing.allocator);
    defer std.testing.allocator.free(executable);
    const terminated = try std.testing.allocator.dupeZ(u8, executable);
    defer std.testing.allocator.free(terminated);
    var config: native.NativeFactory = .{ .selection = selection, .executable = terminated, .environment = &.{} };
    const factory = config.asFactory();
    const first = try factory.create(std.testing.allocator, selection, "/tmp", .{ .value = "first" }, null);
    defer factory.destroy(std.testing.allocator, first);
    const second = try factory.create(std.testing.allocator, selection, "/tmp", .{ .value = "second" }, null);
    defer factory.destroy(std.testing.allocator, second);
    const Codex = @import("runtime/codex.zig");
    const left: *Codex.Runtime = @ptrCast(@alignCast(first.context));
    const right: *Codex.Runtime = @ptrCast(@alignCast(second.context));
    try std.testing.expect(first.context != second.context);
    try std.testing.expect(left.wire.process.pid != right.wire.process.pid);
    try std.testing.expectEqualStrings("first", left.config.instance);
    try std.testing.expectEqualStrings("second", right.config.instance);
    first.shutdown();
    try std.testing.expect(right.wire.process.pid > 0);
    try std.testing.expect(!right.wire.exited);
    try right.wire.send("{\"other_session\":\"still-alive\"}");
    var received = false;
    for (0..100) |_| {
        try right.wire.pump();
        while (try right.wire.poll(std.testing.allocator)) |line| {
            defer std.testing.allocator.free(line);
            if (std.mem.eql(u8, line, "{\"other_session\":\"still-alive\"}")) received = true;
        }
        if (received) break;
        _ = @import("runtime/transport.zig").c.spica_process_poll(&right.wire.process, -1, 0, 10);
    }
    try std.testing.expect(received);
    second.shutdown();
}

fn failedCreation(a: std.mem.Allocator) !void {
    for ([_][]const u8{ "codex", "opencode" }) |kind| {
        var chosen = selection;
        chosen.runtime_kind = kind;
        chosen.required_runtime_version = if (std.mem.eql(u8, kind, "codex")) "0.163.0" else "2.1.4";
        var config: native.NativeFactory = .{ .selection = chosen, .executable = "/does/not/exist", .environment = &.{} };
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
