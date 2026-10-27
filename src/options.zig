const std = @import("std");

pub const Options = struct {
    help: bool = false,
    quit_after_ms: ?u32 = null,
    metrics_output: ?[]const u8 = null,
    automation_output: ?[]const u8 = null,
    metrics_capacity: u32 = 8192,
    state_directory: ?[]const u8 = null,
    automation_live: ?[]const u8 = null,
    automation_session: ?[]const u8 = null,
    lua_module: ?[]const u8 = null,
    provider: enum { fake, codex, opencode } = .fake,
    /// Ordinary startup is configured in-app; explicit fake is a fixture opt-in.
    provider_explicit: bool = false,
    runtime_account_directory: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_provider: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    codex_auth: enum { none, status, browser, device } = .none,
    runtime_executable: ?[]const u8 = null,
    additional_provider: ?enum { codex, opencode } = null,
    additional_runtime_account_directory: ?[]const u8 = null,
    additional_model_provider: ?[]const u8 = null,
    additional_runtime_executable: ?[]const u8 = null,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--help")) {
                options.help = true;
            } else if (std.mem.eql(u8, flag, "--provider")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.provider_explicit = true;
                options.provider = std.meta.stringToEnum(@TypeOf(options.provider), args[index]) orelse return error.InvalidProvider;
            } else if (std.mem.eql(u8, flag, "--additional-provider")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                if (options.additional_provider != null) return error.DuplicateAdditionalProvider;
                options.additional_provider = std.meta.stringToEnum(@typeInfo(@FieldType(Options, "additional_provider")).optional.child, args[index]) orelse return error.InvalidProvider;
            } else if (std.mem.eql(u8, flag, "--additional-runtime-account-directory") or std.mem.eql(u8, flag, "--additional-model-provider") or std.mem.eql(u8, flag, "--additional-runtime-executable")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                if (std.mem.eql(u8, flag, "--additional-runtime-account-directory")) options.additional_runtime_account_directory = args[index] else if (std.mem.eql(u8, flag, "--additional-model-provider")) options.additional_model_provider = args[index] else options.additional_runtime_executable = args[index];
            } else if (std.mem.eql(u8, flag, "--runtime-executable")) {
                index += 1;
                if (index == args.len or !std.fs.path.isAbsolute(args[index])) return error.AbsoluteRuntimeExecutableRequired;
                options.runtime_executable = args[index];
            } else if (std.mem.eql(u8, flag, "--codex-auth")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.codex_auth = std.meta.stringToEnum(@TypeOf(options.codex_auth), args[index]) orelse return error.InvalidAuthMode;
            } else if (std.mem.eql(u8, flag, "--runtime-account-directory") or std.mem.eql(u8, flag, "--model") or std.mem.eql(u8, flag, "--model-provider") or std.mem.eql(u8, flag, "--effort") or std.mem.eql(u8, flag, "--workspace")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                if (std.mem.eql(u8, flag, "--runtime-account-directory")) options.runtime_account_directory = args[index] else if (std.mem.eql(u8, flag, "--model")) options.model = args[index] else if (std.mem.eql(u8, flag, "--model-provider")) options.model_provider = args[index] else if (std.mem.eql(u8, flag, "--effort")) options.effort = args[index] else options.workspace = args[index];
            } else if (std.mem.eql(u8, flag, "--quit-after-ms")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.quit_after_ms = try std.fmt.parseInt(u32, args[index], 10);
            } else if (std.mem.eql(u8, flag, "--lua-module")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                options.lua_module = args[index];
            } else if (std.mem.eql(u8, flag, "--state-directory")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                options.state_directory = args[index];
            } else if (std.mem.eql(u8, flag, "--automation-live")) {
                index += 1;
                if (index == args.len or args[index].len == 0) return error.MissingOptionValue;
                options.automation_live = args[index];
            } else if (std.mem.eql(u8, flag, "--automation-session")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                const value = args[index];
                if (value.len != 32) return error.InvalidAutomationSession;
                for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidAutomationSession;
                options.automation_session = value;
            } else if (std.mem.eql(u8, flag, "--metrics-output") or std.mem.eql(u8, flag, "--automation-output")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                if (std.mem.eql(u8, flag, "--metrics-output")) options.metrics_output = args[index] else options.automation_output = args[index];
            } else if (std.mem.eql(u8, flag, "--metrics-capacity")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.metrics_capacity = try std.fmt.parseInt(u32, args[index], 10);
                if (options.metrics_capacity == 0 or options.metrics_capacity > 1048576) return error.InvalidCapacity;
            } else return error.UnknownOption;
        }
        if (options.codex_auth != .none and options.provider != .codex and !options.help) return error.CodexAuthRequiresCodex;
        if (options.provider != .fake and !options.help) {
            if ((options.model == null) != (options.effort == null)) return error.CompleteInitialSelectionRequired;
            if (options.runtime_account_directory == null or options.model_provider == null or options.workspace == null) return error.ExplicitRuntimeSelectionRequired;
            if (!std.fs.path.isAbsolute(options.runtime_account_directory.?) or !std.fs.path.isAbsolute(options.workspace.?)) return error.AbsoluteRuntimePathsRequired;
        }
        if (!options.help) {
            if (options.automation_session != null and options.automation_live == null and options.automation_output == null) return error.AutomationExportRequired;
            if (options.additional_provider) |provider| {
                if (options.provider == .fake or std.mem.eql(u8, @tagName(provider), @tagName(options.provider))) return error.DistinctNativeProvidersRequired;
                if (options.additional_runtime_account_directory == null or options.additional_model_provider == null) return error.ExplicitAdditionalAccountRequired;
                if (!std.fs.path.isAbsolute(options.additional_runtime_account_directory.?)) return error.AbsoluteRuntimePathsRequired;
                if (std.mem.eql(u8, options.runtime_account_directory.?, options.additional_runtime_account_directory.?)) return error.SeparateRuntimeAccountsRequired;
            } else if (options.additional_runtime_account_directory != null or options.additional_model_provider != null or options.additional_runtime_executable != null) return error.AdditionalProviderRequired;
            if (options.additional_runtime_executable) |path| if (!std.fs.path.isAbsolute(path)) return error.AbsoluteRuntimeExecutableRequired;
        }
        return options;
    }
};

/// Native rewrite's independent namespace. No legacy discovery or migration.
pub fn defaultStateDirectory(allocator: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8) ![]u8 {
    if (xdg_data_home) |root| {
        if (std.fs.path.isAbsolute(root)) return std.fs.path.join(allocator, &.{ root, "spica-native", "conversation" });
    }
    const root = home orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(root)) return error.HomeUnavailable;
    return std.fs.path.join(allocator, &.{ root, ".local", "share", "spica-native", "conversation" });
}

test "native default state path is independent and honors absolute XDG only" {
    const allocator = std.testing.allocator;
    const xdg = try defaultStateDirectory(allocator, "/temporary/data", "/temporary/home");
    defer allocator.free(xdg);
    try std.testing.expectEqualStrings("/temporary/data/spica-native/conversation", xdg);
    const fallback = try defaultStateDirectory(allocator, "relative", "/temporary/home");
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("/temporary/home/.local/share/spica-native/conversation", fallback);
    try std.testing.expectError(error.HomeUnavailable, defaultStateDirectory(allocator, null, null));
}

pub const help =
    \\Spica — native coding workspace
    \\Usage: spica [--state-directory DIRECTORY] [--quit-after-ms MILLISECONDS]
    \\
    \\--state-directory overrides the independent durable application state.
    \\Default: $XDG_DATA_HOME/spica-native/conversation ($HOME/.local/share fallback).
    \\Enter sends; Shift+Enter inserts newline. F6 cancels; F7 allows; F8 denies.
    \\--lua-module PATH selects a custom Lua root/renderer. F5 reloads; F9 toggles default/custom.
    \\--provider fake|codex|opencode selects an explicit runtime (fake is a synthetic fixture).
    \\Ordinary launch opens in-app setup and restores saved provider settings.
    \\Real runtimes require --runtime-account-directory PATH --workspace PATH
    \\and --model-provider ID. Select discovered model/effort in the native picker;
    \\--model ID --effort VALUE optionally supplies an exact initial selection.
    \\Configured real runtimes discover models on launch without performing inference.
    \\The connection panel edits executable/account/workspace and refreshes discovery.
    \\Runtime account state is independent of the application database.
    \\--codex-auth status|browser|device queries/initiates supported isolated ChatGPT sign-in,
    \\prints the actual runtime response, then exits without opening the native UI.
    \\--runtime-executable PATH overrides /usr/bin/codex or /usr/bin/opencode.
    \\--additional-provider codex|opencode authorizes the other runtime for children.
    \\It requires --additional-runtime-account-directory PATH --additional-model-provider ID;
    \\--additional-runtime-executable PATH optionally selects its absolute executable.
    \\Runtime account directories must differ; child model/effort remain explicit in task packets.
    \\Escape dismisses local editing state. Ctrl+Q or window close exits.
    \\--quit-after-ms exits after a bounded smoke run (0 exits immediately).
    \\--automation-output PATH exports the read-only final native snapshot.
    \\--automation-live PATH enables bounded read-only painted snapshots (adds file I/O).
    \\--automation-session HEX supplies a 32-digit process nonce for correlated GUI testing.
    \\--metrics-output PATH enables bounded frame timestamps and text-cache ledger.
    \\--metrics-capacity N bounds retained attempts (default 8192; max 1048576).
    \\Development builds use checkout resources; Linux packages resolve resources beside the executable.
    \\
;

test "automation session identity is bounded and requires an observation export" {
    const nonce = "0123456789abcdef0123456789abcdef";
    const options = try Options.parse(&.{ "spica", "--automation-live", "/tmp/live.json", "--automation-session", nonce });
    try std.testing.expectEqualStrings(nonce, options.automation_session.?);
    try std.testing.expectError(error.AutomationExportRequired, Options.parse(&.{ "spica", "--automation-session", nonce }));
    try std.testing.expectError(error.InvalidAutomationSession, Options.parse(&.{ "spica", "--automation-session", "short" }));
    try std.testing.expectError(error.InvalidAutomationSession, Options.parse(&.{ "spica", "--automation-session", "z" ** 32 }));
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--automation-session" }));
}

test "smoke deadline is bounded and legacy runtime flags are rejected" {
    try std.testing.expect((try Options.parse(&.{"spica"})).quit_after_ms == null);
    try std.testing.expect((try Options.parse(&.{ "spica", "--help" })).help);
    try std.testing.expectEqual(@as(u32, 0), (try Options.parse(&.{ "spica", "--quit-after-ms", "0" })).quit_after_ms.?);
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--quit-after-ms" }));
    try std.testing.expectError(error.Overflow, Options.parse(&.{ "spica", "--quit-after-ms", "4294967296" }));
    try std.testing.expectError(error.Overflow, Options.parse(&.{ "spica", "--quit-after-ms", "-1" }));
    try std.testing.expectError(error.UnknownOption, Options.parse(&.{ "spica", "--pi-entry", "agent.js" }));
}

test "telemetry options require values and bounded capacity" {
    const options = try Options.parse(&.{ "spica", "--metrics-output", "frames.json", "--automation-output", "snapshot.json", "--metrics-capacity", "2" });
    try std.testing.expectEqualStrings("frames.json", options.metrics_output.?);
    try std.testing.expectEqual(@as(u32, 2), options.metrics_capacity);
    try std.testing.expectError(error.InvalidCapacity, Options.parse(&.{ "spica", "--metrics-capacity", "0" }));
    try std.testing.expectError(error.InvalidCapacity, Options.parse(&.{ "spica", "--metrics-capacity", "1048577" }));
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--automation-output" }));
}

test "custom module selection is explicit and requires a path" {
    try std.testing.expectEqualStrings("examples/minimal.lua", (try Options.parse(&.{ "spica", "--lua-module", "examples/minimal.lua" })).lua_module.?);
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--lua-module" }));
}

test "real runtime selection is explicit and account paths are absolute" {
    try std.testing.expectError(error.ExplicitRuntimeSelectionRequired, Options.parse(&.{ "spica", "--provider", "codex" }));
    try std.testing.expectError(error.InvalidProvider, Options.parse(&.{ "spica", "--provider", "other" }));
    const options = try Options.parse(&.{ "spica", "--provider", "codex", "--runtime-account-directory", "/tmp/account", "--workspace", "/tmp/project", "--model-provider", "openai", "--model", "gpt-6.1-sol", "--effort", "medium" });
    try std.testing.expectEqual(.codex, options.provider);
}

test "mixed runtime authorization requires distinct explicit account and provider" {
    const primary = [_][:0]const u8{ "spica", "--provider", "codex", "--runtime-account-directory", "/tmp/codex-account", "--workspace", "/tmp/project", "--model-provider", "openai", "--model", "coordinator-model", "--effort", "medium" };
    const mixed = try Options.parse(&(primary ++ .{ "--additional-provider", "opencode", "--additional-runtime-account-directory", "/tmp/opencode-account", "--additional-model-provider", "opencode" }));
    try std.testing.expectEqual(.opencode, mixed.additional_provider.?);
    try std.testing.expectEqualStrings("coordinator-model", mixed.model.?);
    try std.testing.expectError(error.ExplicitAdditionalAccountRequired, Options.parse(&(primary ++ .{ "--additional-provider", "opencode" })));
    try std.testing.expectError(error.DistinctNativeProvidersRequired, Options.parse(&(primary ++ .{ "--additional-provider", "codex" })));
    try std.testing.expectError(error.SeparateRuntimeAccountsRequired, Options.parse(&(primary ++ .{ "--additional-provider", "opencode", "--additional-runtime-account-directory", "/tmp/codex-account", "--additional-model-provider", "opencode" })));
    try std.testing.expectError(error.AdditionalProviderRequired, Options.parse(&(primary ++ .{ "--additional-runtime-account-directory", "/tmp/other" })));
    try std.testing.expectError(error.DuplicateAdditionalProvider, Options.parse(&(primary ++ .{ "--additional-provider", "opencode", "--additional-provider", "opencode" })));
    try std.testing.expectError(error.AbsoluteRuntimeExecutableRequired, Options.parse(&(primary ++ .{ "--additional-provider", "opencode", "--additional-runtime-account-directory", "/tmp/opencode-account", "--additional-model-provider", "opencode", "--additional-runtime-executable", "relative" })));
}

test "setup-only native startup leaves inference selection explicit" {
    const base = [_][:0]const u8{ "spica", "--provider", "codex", "--runtime-account-directory", "/tmp/account", "--workspace", "/tmp/project", "--model-provider", "openai" };
    const setup = try Options.parse(&base);
    try std.testing.expect(setup.model == null and setup.effort == null);
    try std.testing.expectEqual(.device, (try Options.parse(&(base ++ .{ "--codex-auth", "device" }))).codex_auth);
    try std.testing.expectError(error.CompleteInitialSelectionRequired, Options.parse(&(base ++ .{ "--model", "explicit-model" })));
    try std.testing.expectError(error.CompleteInitialSelectionRequired, Options.parse(&(base ++ .{ "--effort", "medium" })));
}

test "ordinary launch and explicit fixture provider remain distinct" {
    const ordinary = try Options.parse(&.{"spica"});
    try std.testing.expect(!ordinary.provider_explicit);
    try std.testing.expect(ordinary.model == null and ordinary.effort == null);
    const fixture_options = try Options.parse(&.{ "spica", "--provider", "fake" });
    try std.testing.expect(fixture_options.provider_explicit);
    try std.testing.expectEqual(.fake, fixture_options.provider);
    const real = try Options.parse(&.{ "spica", "--provider", "opencode", "--runtime-account-directory", "/tmp/账户", "--workspace", "/tmp/项目", "--model-provider", "opencode-go" });
    try std.testing.expect(real.provider_explicit);
    try std.testing.expect(real.model == null and real.effort == null);
}

test {
    _ = @import("startup.zig");
}
