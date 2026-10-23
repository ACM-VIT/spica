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
    second.shutdown();
}
