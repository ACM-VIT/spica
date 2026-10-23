//! Actual Codex+OpenCode process routing through one immutable NativeFactory.
const std = @import("std");
const c = @import("contract.zig");
const NativeFactory = @import("runtime/native_factory.zig").NativeFactory;
const Codex = @import("runtime/codex.zig").Runtime;
const OpenCode = @import("runtime/opencode.zig").Runtime;
extern "c" fn usleep(u32) c_int;
extern "c" fn readlink([*:0]const u8, [*]u8, usize) isize;

fn environment(a: std.mem.Allocator, account: []const u8, opencode: bool) ![]const [:0]const u8 {
    const values = try a.alloc([:0]const u8, if (opencode) 9 else 7);
    values[0] = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{account}, 0);
    values[1] = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{account}, 0);
    values[2] = try std.fmt.allocPrintSentinel(a, "XDG_CONFIG_HOME={s}/config", .{account}, 0);
    values[3] = try std.fmt.allocPrintSentinel(a, "XDG_CACHE_HOME={s}/cache", .{account}, 0);
    values[4] = try std.fmt.allocPrintSentinel(a, "XDG_STATE_HOME={s}/state", .{account}, 0);
    values[5] = "PATH=/usr/bin:/bin";
    if (opencode) {
        values[6] = try std.fmt.allocPrintSentinel(a, "OPENCODE_CONFIG_DIR={s}/config/opencode", .{account}, 0);
        values[7] = "OPENCODE_DISABLE_CLAUDE_CODE=1";
        values[8] = try std.fmt.allocPrintSentinel(a, "OPENCODE_TEST_HOME={s}", .{account}, 0);
    } else values[6] = try std.fmt.allocPrintSentinel(a, "CODEX_HOME={s}", .{account}, 0);
    return values;
}
fn verifyCwd(pid: c_int, cwd: []const u8) !void {
    var path: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&path, "/proc/{d}/cwd", .{pid}, 0);
    var target: [4096]u8 = undefined;
    const count = readlink(name.ptr, &target, target.len);
    if (count <= 0 or !std.mem.eql(u8, cwd, target[0..@intCast(count)])) return error.ProcessWorkspaceMismatch;
    std.debug.print("ASSERT actual process pid={d} cwd={s}\n", .{ pid, target[0..@intCast(count)] });
}
pub fn main(init: std.process.Init.Minimal) !void {
    var heap: std.heap.DebugAllocator(.{}) = .init;
    defer if (heap.deinit() != .ok) @panic("mixed factory consumer leaks");
    const backing = heap.allocator();
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len != 7) return error.ExpectedOpenCodeCodexWorkspaceOpenCodeAccountCodexAccountCodexWorkspace;
    if (std.mem.eql(u8, args[4], args[5])) return error.AccountsMustDiffer;
    const oc: c.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "opencode", .model_id = "big-pickle", .effort = "default", .account_ref = args[4], .workspace = .{ .value = "mixed-opencode-workspace" } };
    const cx: c.Selection = .{ .runtime_kind = "codex", .required_runtime_version = "0.163.0", .model_provider = "openai", .model_id = "gpt-6.1-sol", .effort = "medium", .account_ref = args[5], .workspace = .{ .value = "mixed-codex-workspace" } };
    const configs = [_]NativeFactory.Config{
        .{ .selection = oc, .executable = try a.dupeZ(u8, args[1]), .environment = try environment(a, oc.account_ref, true) },
        .{ .selection = cx, .executable = try a.dupeZ(u8, args[2]), .environment = try environment(a, cx.account_ref, false) },
    };
    var native: NativeFactory = .{ .configs = &configs };
    const factory = native.asFactory();
    const codex = try factory.create(backing, cx, args[6], .{ .value = "mixed-codex" }, null);
    defer {
        codex.shutdown();
        factory.destroy(backing, codex);
    }
    const opencode = try factory.create(backing, oc, args[3], .{ .value = "mixed-opencode" }, null);
    defer {
        opencode.shutdown();
        factory.destroy(backing, opencode);
    }
    const cr: *Codex = @ptrCast(@alignCast(codex.context));
    const oruntime: *OpenCode = @ptrCast(@alignCast(opencode.context));
    if (cr.wire.process.pid == oruntime.transport.process.pid) return error.NotSeparateProcesses;
    try verifyCwd(cr.wire.process.pid, args[6]);
    try verifyCwd(oruntime.transport.process.pid, args[3]);
    for (configs) |config| {
        std.debug.print("CONFIG runtime={s} account={s} executable={s}\n", .{ config.selection.runtime_kind, config.selection.account_ref, config.executable });
        for (config.environment) |value| std.debug.print("ENV {s} {s}\n", .{ config.selection.runtime_kind, value });
    }
    for (0..1500) |_| {
        try codex.pump();
        try opencode.pump();
        if (try opencode.poll(a)) |event| if (event.body == .failure or event.body == .disconnect) return error.OpenCodeHandshakeFailure;
        if (cr.disconnected) return error.CodexHandshakeFailure;
        if (cr.initialized and cr.pending == null and opencode.ready()) break;
        _ = usleep(10000);
    } else return error.MixedInitializeTimeout;
    if (!std.mem.eql(u8, oruntime.runtime_version, "2.1.4")) return error.OpenCodeVersionMismatch;
    if (codex.accountStatus().readiness != .unavailable) return error.UnexpectedIsolatedCodexAccount;
    std.debug.print("ASSERT actual Codex0.163.0 initialize+account/read: readiness=unavailable; supported isolated ChatGPT sign-in prerequisite, no Codex inference\n", .{});
    _ = try opencode.dispatch(a, .{ .open = .{ .create = .{ .session = .{ .value = "mixed-opencode" }, .effect = .{ .value = "mixed-open" }, .selection = oc } } });
    for (0..1500) |_| {
        try opencode.pump();
        if (try opencode.poll(a)) |event| switch (event.body) {
            .session => break,
            .failure, .disconnect => return error.OpenCodeSessionFailure,
            else => {},
        };
        _ = usleep(10000);
    } else return error.OpenCodeSessionTimeout;
    if (opencode.resolveSelection(oc).effective == null) return error.OpenCodeSelectionUnverified;
    _ = try opencode.dispatch(a, .{ .start = .{ .correlation = .{ .session = .{ .value = "mixed-opencode" }, .run = .{ .value = "mixed-live" }, .effect = .{ .value = "mixed-start" } }, .prompt = "Reply exactly SPICA_MIXED_FACTORY_OK. Do not use tools." } });
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..6000) |_| {
        try codex.pump();
        try opencode.pump();
        if (cr.disconnected) return error.CodexPeerDied;
        if (try opencode.poll(a)) |event| switch (event.body) {
            .chunk => |chunk| try text.writer.writeAll(chunk.text),
            .completed => {
                if (std.mem.indexOf(u8, text.written(), "SPICA_MIXED_FACTORY_OK") == null) return error.MixedTextMissing;
                std.debug.print("ASSERT OpenCode2.1.4 exact opencode/big-pickle completed while Codex peer remains live; text={s}\n", .{text.written()});
                return;
            },
            .failure, .disconnect => return error.MixedInferenceFailed,
            else => {},
        };
        _ = usleep(10000);
    }
    return error.MixedInferenceTimeout;
}
