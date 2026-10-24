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
        if (std.mem.eql(u8, kind, "codex")) {
            const runtime: *@import("runtime/codex.zig").Runtime = @ptrCast(@alignCast(adapter.context));
            try std.testing.expectEqualStrings("task_delegate", runtime.config.tools[0].name);
            try std.testing.expectEqualStrings("task.delegate", runtime.config.tool_bindings[0].application_name);
            try std.testing.expectEqualStrings("task_delegate", runtime.config.tool_bindings[0].wire_name);
        }
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

test "refreshed catalog is exact and rejects stale model effort account and provider" {
    var config: native.NativeFactory = .{ .configs = &.{.{ .selection = selection, .executable = "/does/not/exist", .environment = &.{} }}, .catalog_authoritative = true };
    config.catalog_models[0] = .{ .selection = selection, .supported_efforts = &.{ "medium", "high" }, .display_name = "Protocol model", .readiness = .unavailable, .reason = "Actual account unready" };
    config.catalog_count = 1;
    const factory = config.asFactory();
    try std.testing.expectEqual(.unavailable, factory.accountStatus(selection).readiness);
    config.catalog_models[0].readiness = .ready;
    try std.testing.expectEqual(.ready, factory.accountStatus(selection).readiness);
    var other = selection;
    other.effort = "high";
    try std.testing.expectEqual(.ready, factory.accountStatus(other).readiness);
    other.effort = "unnegotiated";
    try std.testing.expectEqual(.unavailable, factory.accountStatus(other).readiness);
    other = selection;
    other.model_id = "stale-model";
    try std.testing.expectEqual(.unavailable, factory.accountStatus(other).readiness);
    other = selection;
    other.account_ref = "/unauthorized";
    try std.testing.expectEqual(.unavailable, factory.accountStatus(other).readiness);
    other = selection;
    other.model_provider = "unauthorized";
    try std.testing.expectEqual(.unavailable, factory.accountStatus(other).readiness);
    config.catalog_count = 0;
    try std.testing.expectEqual(.unavailable, factory.accountStatus(selection).readiness);
}

fn configuredSetup(allocator: std.mem.Allocator, workspace: []const u8, account: []const u8) !void {
    var native_factory: native.NativeFactory = .{ .configs = &.{} };
    const factory = native_factory.asFactory();
    const setup: c.RuntimeSetup = .{ .runtime_kind = .codex, .executable = "/not/a/provider", .account_directory = account, .workspace_root = workspace, .model_provider = "openai" };
    try factory.runtimeAction(allocator, std.testing.io, .{ .configure = setup });
    // Replacing a setup repeatedly must release operation paths and keep the
    // previous generation intact on any partial allocation failure.
    try factory.runtimeAction(allocator, std.testing.io, .{ .configure = setup });
    try std.testing.expectEqualStrings(workspace, factory.runtimeStatus().workspace_root);
    try std.testing.expectEqualStrings(account, native_factory.configs[0].selection.account_ref);
    try std.testing.expectEqual(@as(usize, 0), factory.models().len);
    try std.testing.expect(native_factory.catalog_authoritative);
    var selected = native_factory.configs[0].selection;
    selected.model_id = "unrefreshed";
    selected.effort = "medium";
    try std.testing.expectEqual(.unavailable, factory.accountStatus(selected).readiness);
}

test "runtime setup releases operation paths under allocation failure and repeated replacement" {
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    var account = std.testing.tmpDir(.{});
    defer account.cleanup();
    const root = try workspace.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const account_root = try account.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(account_root);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, configuredSetup, .{ root, account_root });
}

test "failed explicit setup invalidates catalog admission without replacing authorization" {
    var native_factory: native.NativeFactory = .{ .configs = &.{.{ .selection = selection, .executable = "/does/not/exist", .environment = &.{} }} };
    const factory = native_factory.asFactory();
    try std.testing.expectError(error.AbsoluteRuntimePathsRequired, factory.runtimeAction(std.testing.allocator, std.testing.io, .{ .configure = .{ .runtime_kind = .codex, .executable = "relative", .account_directory = "/unused", .workspace_root = "/unused", .model_provider = "openai" } }));
    try std.testing.expectEqualStrings(selection.account_ref, native_factory.configs[0].selection.account_ref);
    try std.testing.expectEqual(.unavailable, factory.accountStatus(selection).readiness);
}

test {
    _ = @import("runtime/codex_test.zig");
    _ = @import("opencode_test.zig");
    _ = @import("opencode_bridge_test.zig");
}

const setup_fixture = "build/provider_setup_fixture.py";

fn fixtureExecutable(allocator: std.mem.Allocator) ![:0]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, setup_fixture, allocator);
}

test "metadata refresh prioritizes active provider and isolates a disconnected inactive runtime" {
    const allocator = std.testing.allocator;
    const executable = try fixtureExecutable(allocator);
    defer allocator.free(executable);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const environment = [_][:0]const u8{try std.fmt.allocPrintSentinel(allocator, "HOME={s}", .{root}, 0)};
    defer allocator.free(environment[0]);
    for ([_]c.RuntimeKind{ .codex, .opencode }) |active| {
        var codex = selection;
        codex.model_id = "";
        codex.effort = "";
        codex.workspace.value = root;
        var opencode = codex;
        opencode.runtime_kind = "opencode";
        opencode.required_runtime_version = "2.1.4";
        opencode.model_provider = "opencode";
        opencode.account_ref = "/unused-separate-fixture-account";
        const configs = [_]native.NativeFactory.Config{
            .{ .selection = if (active == .codex) opencode else codex, .executable = "/no/such/inactive-runtime", .environment = &environment },
            .{ .selection = if (active == .codex) codex else opencode, .executable = executable, .environment = &environment },
        };
        var configured: native.NativeFactory = .{ .configs = &configs, .status = .{ .runtime_kind = @tagName(active), .workspace_root = root, .configuration = configs[1].setup() } };
        const factory = configured.asFactory();
        try factory.runtimeAction(allocator, std.testing.io, .refresh);
        const status = factory.runtimeStatus();
        try std.testing.expectEqualStrings(@tagName(active), status.runtime_kind);
        try std.testing.expectEqual(active, status.configuration.?.runtime_kind);
        try std.testing.expectEqual(@as(usize, 1), factory.models().len);
        try std.testing.expectEqualStrings(@tagName(active), factory.models()[0].selection.runtime_kind);
        try std.testing.expectEqualStrings(if (active == .codex) "setup-codex" else "setup-opencode", factory.models()[0].selection.model_id);
        try std.testing.expectEqualStrings(root, status.workspace_root);
        // A broken active provider must remain broken; the healthy inactive one
        // cannot supply a misleading fallback catalog or account status.
        configured.owned_configs[0] = configs[0];
        configured.owned_configs[0].executable = executable;
        configured.owned_configs[1] = configs[1];
        configured.owned_configs[1].executable = "/no/such/active-runtime";
        configured.configs = &configured.owned_configs;
        try std.testing.expectError(error.SpawnFailed, factory.runtimeAction(allocator, std.testing.io, .refresh));
        try std.testing.expectEqual(@as(usize, 0), factory.models().len);
        try std.testing.expectEqualStrings(@tagName(active), factory.runtimeStatus().runtime_kind);
        try std.testing.expectEqual(.unavailable, factory.runtimeStatus().readiness);
    }
}

test "active OpenCode status remains its own when both concrete catalogs are available" {
    const allocator = std.testing.allocator;
    const executable = try fixtureExecutable(allocator);
    defer allocator.free(executable);
    var workspace = std.testing.tmpDir(.{});
    defer workspace.cleanup();
    const root = try workspace.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var codex = selection;
    codex.workspace.value = root;
    var opencode = codex;
    opencode.runtime_kind = "opencode";
    opencode.required_runtime_version = "2.1.4";
    opencode.model_provider = "opencode";
    opencode.account_ref = "/unused-separate-fixture-account";
    const environment = [_][:0]const u8{try std.fmt.allocPrintSentinel(allocator, "HOME={s}", .{root}, 0)};
    defer allocator.free(environment[0]);
    var configured: native.NativeFactory = .{ .configs = &.{
        .{ .selection = codex, .executable = executable, .environment = &environment },
        .{ .selection = opencode, .executable = executable, .environment = &environment },
    }, .status = .{ .runtime_kind = "opencode", .workspace_root = root } };
    const factory = configured.asFactory();
    try factory.runtimeAction(allocator, std.testing.io, .refresh);
    try std.testing.expectEqual(@as(usize, 2), factory.models().len);
    try std.testing.expectEqualStrings("opencode", factory.models()[0].selection.runtime_kind);
    try std.testing.expectEqualStrings("codex", factory.models()[1].selection.runtime_kind);
    try std.testing.expectEqual(factory.models()[0].readiness, factory.runtimeStatus().readiness);
    try std.testing.expectEqualStrings(factory.models()[0].reason, factory.runtimeStatus().reason);
}

test "saved setup restoration owns fields without touching missing account state or starting providers" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const account = try std.fs.path.join(allocator, &.{ root, "账户-not-created" });
    const absent_workspace = try std.fs.path.join(allocator, &.{ root, "workspace-not-created" });
    var provider = [_]u8{ 'o', 'p', 'e', 'n', 'a', 'i' };
    var setup: c.RuntimeSetup = .{ .runtime_kind = .codex, .executable = try fixtureExecutable(allocator), .account_directory = account, .workspace_root = root, .model_provider = &provider };
    var configured: native.NativeFactory = .{ .configs = &.{} };
    const factory = configured.asFactory();
    try factory.runtimeAction(std.testing.allocator, std.testing.io, .{ .restore = setup });
    provider[0] = 'x';
    try std.testing.expectEqualStrings("openai", factory.runtimeStatus().configuration.?.model_provider);
    try std.testing.expectEqualStrings(account, factory.runtimeStatus().configuration.?.account_directory);
    try std.testing.expectEqual(@as(usize, 0), factory.models().len);
    try std.testing.expect(configured.login_instance == null);
    try std.testing.expect(!factory.runtimeStatus().login_pending);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, account, .{}));
    setup.workspace_root = absent_workspace;
    try std.testing.expectError(error.RuntimeWorkspaceUnavailable, factory.runtimeAction(std.testing.allocator, std.testing.io, .{ .restore = setup }));
    try std.testing.expectEqualStrings(absent_workspace, factory.runtimeStatus().workspace_root);
    try std.testing.expectEqualStrings(absent_workspace, factory.runtimeStatus().configuration.?.workspace_root);
    setup.executable = "/no/such/saved-runtime";
    try std.testing.expectError(error.RuntimeExecutableUnavailable, factory.runtimeAction(std.testing.allocator, std.testing.io, .{ .restore = setup }));
    try std.testing.expectEqualStrings(setup.executable, factory.runtimeStatus().configuration.?.executable);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, account, .{}));
}

test "pending sign-in survives refresh rejection and completes through setup polling" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const account = try std.fs.path.join(allocator, &.{ root, "fixture-account" });
    var configured: native.NativeFactory = .{ .configs = &.{} };
    const factory = configured.asFactory();
    defer if (factory.vtable.shutdownSetup) |shutdown| shutdown(factory.context);
    try factory.runtimeAction(std.testing.allocator, std.testing.io, .{ .configure = .{ .runtime_kind = .codex, .executable = try fixtureExecutable(allocator), .account_directory = account, .workspace_root = root, .model_provider = "openai" } });
    try factory.runtimeAction(std.testing.allocator, std.testing.io, .{ .login = .{ .runtime_kind = .codex, .mode = .device } });
    try std.testing.expect(factory.runtimeStatus().login_pending);
    const started = @import("runtime/transport.zig").c.spica_monotonic_ms();
    var saw_url = false;
    var completed = false;
    while (@import("runtime/transport.zig").c.spica_monotonic_ms() - started < 5000) {
        _ = factory.vtable.pumpSetup.?(factory.context);
        const status = factory.runtimeStatus();
        if (status.login_pending and status.login.len != 0) {
            saw_url = true;
            const url = try allocator.dupe(u8, status.login);
            try std.testing.expect(std.mem.indexOf(u8, url, "https://example.invalid/spica-fixture") != null);
            const instance = configured.login_instance.?.context;
            try std.testing.expectError(error.RuntimeBusy, factory.runtimeAction(std.testing.allocator, std.testing.io, .refresh));
            try std.testing.expectEqual(instance, configured.login_instance.?.context);
            try std.testing.expect(factory.runtimeStatus().login_pending);
            try std.testing.expectEqualStrings(url, factory.runtimeStatus().login);
            try std.testing.expectEqual(status.readiness, factory.runtimeStatus().readiness);
        }
        if (!status.login_pending) {
            try std.testing.expectEqual(.ready, status.readiness);
            completed = true;
            break;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect(saw_url and completed);
    try std.testing.expectEqual(@as(usize, 0), factory.models().len);
    try factory.runtimeAction(std.testing.allocator, std.testing.io, .refresh);
    try std.testing.expectEqual(@as(usize, 1), factory.models().len);
    try std.testing.expectEqual(.ready, factory.runtimeStatus().readiness);
}

const domain = @import("domain.zig");

fn setupOutput(host: *domain.Host, ticket: domain.types.Ticket, allocator: std.mem.Allocator) !domain.types.Output {
    const backing = try allocator.alloc(u8, 262144);
    for (0..5000) |_| {
        var outputs: [1]domain.types.Output = undefined;
        const drained = host.drain(&outputs, backing);
        if (drained.output_count == 0) {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
            continue;
        }
        const actual = switch (outputs[0]) {
            .query_page => |value| value.ticket,
            .command_receipt => |value| value.ticket,
            .failure => return error.HostFailure,
            else => continue,
        };
        try std.testing.expectEqual(ticket, actual);
        return outputs[0];
    }
    return error.HostTimeout;
}
fn setupStatus(host: *domain.Host, allocator: std.mem.Allocator) !domain.types.RuntimeStatus {
    return (try setupOutput(host, try host.query(.runtime_status), allocator)).query_page.page.items[0].runtime_status;
}

fn expectConfigurations(actual: []const c.RuntimeSetup, expected: []const c.RuntimeSetup) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected) |wanted| {
        var found = false;
        for (actual) |setup| {
            if (setup.runtime_kind != wanted.runtime_kind) continue;
            try std.testing.expect(c.equal(wanted, setup));
            found = true;
        }
        try std.testing.expect(found);
    }
}

test "saved active provider is deterministic across two runtimes and explicit CLI startup takes precedence" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    const state = try std.fs.path.join(allocator, &.{ root, "state" });
    try temporary.dir.createDirPath(io, "项目 codex");
    try temporary.dir.createDirPath(io, "项目 opencode");
    const codex: c.RuntimeSetup = .{ .runtime_kind = .codex, .executable = try fixtureExecutable(allocator), .account_directory = try std.fs.path.join(allocator, &.{ root, "账户 codex" }), .workspace_root = try temporary.dir.realPathFileAlloc(io, "项目 codex", allocator), .model_provider = "openai" };
    const opencode: c.RuntimeSetup = .{ .runtime_kind = .opencode, .executable = codex.executable, .account_directory = try std.fs.path.join(allocator, &.{ root, "账户 opencode" }), .workspace_root = try temporary.dir.realPathFileAlloc(io, "项目 opencode", allocator), .model_provider = "opencode" };
    {
        var database = try domain.store.Store.open(io, state);
        defer database.close() catch {};
        try database.saveRuntimeConfiguration("codex", try std.json.Stringify.valueAlloc(allocator, codex, .{}));
        try database.saveRuntimeConfiguration("opencode", try std.json.Stringify.valueAlloc(allocator, opencode, .{}));
        try database.saveRuntimeConfiguration("codex", try std.json.Stringify.valueAlloc(allocator, codex, .{}));
        try std.testing.expectEqual(@as(i64, 2), try database.scalar("SELECT count(*) FROM runtime_configurations"));
        try std.testing.expectEqual(@as(i64, 1), try database.scalar("SELECT count(*) FROM runtime_preferences WHERE active_runtime_kind='codex'"));
    }
    {
        var configured: native.NativeFactory = .{ .configs = &.{} };
        const host = try domain.Host.create(std.testing.allocator, io, .{ .state_directory = state, .setup_factory = configured.asFactory() });
        defer host.destroy();
        const status = try setupStatus(host, allocator);
        try std.testing.expectEqualStrings("codex", status.runtime_kind);
        try std.testing.expectEqualStrings(codex.workspace_root, status.workspace_root);
        try std.testing.expectEqualStrings(codex.workspace_root, status.binding.?.canonical_root);
        try std.testing.expect(c.equal(codex, status.configuration.?));
        try expectConfigurations(status.configurations, &.{ codex, opencode });
        try std.testing.expectEqual(@as(usize, 2), configured.configs.len);
        try std.testing.expectEqual(@as(usize, 0), configured.catalog_count);
        try std.testing.expect(configured.login_instance == null);
        for (configured.configs) |config| try std.testing.expect(config.selection.model_id.len == 0 and config.selection.effort.len == 0);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, codex.account_directory, .{}));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, opencode.account_directory, .{}));
        var changed_opencode = opencode;
        changed_opencode.executable = "/custom/opencode-executable";
        changed_opencode.account_directory = try std.fs.path.join(allocator, &.{ root, "changed-opencode-account" });
        const saved = try setupOutput(host, try host.submit(.{ .command_id = .{ .value = "activate-opencode" }, .target = .absent, .expected_revision = .absent, .payload = .{ .runtime_configure = changed_opencode } }), allocator);
        try std.testing.expectEqual(.accepted, saved.command_receipt.receipt.outcome);
        const next = try setupStatus(host, allocator);
        try std.testing.expect(c.equal(changed_opencode, next.configuration.?));
        try expectConfigurations(next.configurations, &.{ codex, changed_opencode });
        // Earlier public status remains owned after factory replacement.
        try std.testing.expect(c.equal(codex, status.configuration.?));
        try std.testing.expectEqualStrings(codex.workspace_root, status.workspace_root);
        try expectConfigurations(status.configurations, &.{ codex, opencode });
        // Cycle the retained configuration buffers and status scratch again;
        // previously returned nested paths must keep their original values.
        const restored = try setupOutput(host, try host.submit(.{ .command_id = .{ .value = "restore-opencode" }, .target = .absent, .expected_revision = .absent, .payload = .{ .runtime_configure = opencode } }), allocator);
        try std.testing.expectEqual(.accepted, restored.command_receipt.receipt.outcome);
        try expectConfigurations((try setupStatus(host, allocator)).configurations, &.{ codex, opencode });
        try expectConfigurations(status.configurations, &.{ codex, opencode });
        try expectConfigurations(next.configurations, &.{ codex, changed_opencode });
    }
    {
        var configured: native.NativeFactory = .{ .configs = &.{} };
        const host = try domain.Host.create(std.testing.allocator, io, .{ .state_directory = state, .setup_factory = configured.asFactory() });
        defer host.destroy();
        const status = try setupStatus(host, allocator);
        try std.testing.expectEqualStrings("opencode", status.runtime_kind);
        try std.testing.expect(c.equal(opencode, status.configuration.?));
        try expectConfigurations(status.configurations, &.{ codex, opencode });
    }
    {
        var explicit = selection;
        explicit.workspace.value = codex.workspace_root;
        explicit.account_ref = codex.account_directory;
        explicit.model_id = "exact-explicit-model";
        explicit.effort = "high";
        var configured: native.NativeFactory = .{ .configs = &.{.{ .selection = explicit, .executable = try allocator.dupeZ(u8, codex.executable), .environment = &.{} }}, .status = .{ .runtime_kind = "codex", .workspace_root = codex.workspace_root, .configuration = codex } };
        const host = try domain.Host.create(std.testing.allocator, io, .{ .state_directory = state, .setup_factory = configured.asFactory(), .factory = configured.asFactory(), .selection = explicit, .workspace_root = codex.workspace_root, .restore_configuration = false });
        defer host.destroy();
        try std.testing.expect(c.equal(codex, (try setupStatus(host, allocator)).configuration.?));
        try std.testing.expectEqual(@as(usize, 1), configured.configs.len);
        try std.testing.expect(c.equal(explicit, host.selectionFor(explicit.workspace)));
    }
    {
        // An explicit fixture launch also ignores saved native settings.
        var configured: native.NativeFactory = .{ .configs = &.{} };
        const host = try domain.Host.create(std.testing.allocator, io, .{ .state_directory = state, .setup_factory = configured.asFactory(), .restore_configuration = false });
        defer host.destroy();
        try std.testing.expect((try setupStatus(host, allocator)).configuration == null);
        try std.testing.expectEqual(@as(usize, 0), configured.configs.len);
    }
}

test "broken saved setup remains visible with original fields and never silently falls back" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    const state = try std.fs.path.join(allocator, &.{ root, "state" });
    const setup: c.RuntimeSetup = .{ .runtime_kind = .codex, .executable = "/no/such/runtime", .account_directory = try std.fs.path.join(allocator, &.{ root, "never-created-account" }), .workspace_root = try std.fs.path.join(allocator, &.{ root, "missing-workspace" }), .model_provider = "openai" };
    const inactive: c.RuntimeSetup = .{ .runtime_kind = .opencode, .executable = try fixtureExecutable(allocator), .account_directory = try std.fs.path.join(allocator, &.{ root, "inactive-account" }), .workspace_root = root, .model_provider = "opencode" };
    for ([_]bool{ false, true }) |malformed| {
        {
            var database = try domain.store.Store.open(io, state);
            defer database.close() catch {};
            try database.saveRuntimeConfiguration("opencode", try std.json.Stringify.valueAlloc(allocator, inactive, .{}));
            try database.saveRuntimeConfiguration("codex", if (malformed) "{broken-json" else try std.json.Stringify.valueAlloc(allocator, setup, .{}));
        }
        var configured: native.NativeFactory = .{ .configs = &.{} };
        const host = try domain.Host.create(std.testing.allocator, io, .{ .state_directory = state, .setup_factory = configured.asFactory() });
        defer host.destroy();
        const status = try setupStatus(host, allocator);
        try std.testing.expectEqualStrings("codex", status.runtime_kind);
        try std.testing.expectEqual(.unavailable, status.readiness);
        try std.testing.expect(status.reason.len != 0);
        try std.testing.expect(status.binding == null);
        try std.testing.expect(!status.login_pending);
        if (!malformed) {
            try std.testing.expect(c.equal(setup, status.configuration.?));
            try std.testing.expectEqualStrings(setup.workspace_root, status.workspace_root);
            try expectConfigurations(status.configurations, &.{ inactive, setup });
        } else {
            try std.testing.expect(status.configuration == null);
            try expectConfigurations(status.configurations, &.{inactive});
        }
        const models = (try setupOutput(host, try host.query(.{ .models = .{ .workspace = .{ .value = "not-registered" } } }), allocator)).query_page.page.items;
        try std.testing.expectEqual(@as(usize, 0), models.len);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, setup.account_directory, .{}));
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, inactive.account_directory, .{}));
    }
}
