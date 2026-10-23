//! Installed OpenCode ACP consumer through the actual shared Adapter vtable.
//! Run only from tools/opencode-acp-smoke.py's disposable HOME/environment.
const std = @import("std");
const provider = @import("runtime/opencode.zig");
const transport = @import("runtime/transport.zig");
const c = @import("contract.zig");
extern "c" fn usleep(u32) c_int;
pub fn main(init: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.args.toSlice(a);
    if (args.len != 3 and args.len != 4) return error.ExpectedExecutableAndWorkspace;
    const executable = try a.dupeZ(u8, args[1]);
    const workspace = try a.dupeZ(u8, args[2]);
    const selection: c.Selection = .{ .runtime_kind = "opencode", .required_runtime_version = "2.1.4", .model_provider = "opencode", .model_id = "big-pickle", .effort = "default", .account_ref = "disposable-unsigned-in", .workspace = .{ .value = workspace } };
    var runtime: provider.Runtime = undefined;
    var process = try transport.Transport.init(a, .{ .argv = &.{ executable, "acp" }, .cwd = workspace });
    runtime.init(a, process, .{ .selection = selection, .instance = .{ .value = "disposable-smoke-instance" }, .account = .{ .reference = selection.account_ref, .readiness = .unknown } }) catch |err| {
        process.deinit();
        return err;
    };
    const adapter = runtime.asAdapter();
    defer adapter.shutdown();
    for (0..1000) |_| {
        try adapter.pump();
        _ = try adapter.poll(a);
        if (adapter.discover().capabilities[@intFromEnum(c.Capability.create)].status == .supported) break;
        _ = usleep(10000);
    } else return error.InitializeTimeout;
    _ = try adapter.dispatch(a, .{ .open = .{ .create = .{ .effect = .{ .value = "create" }, .session = .{ .value = "app-session" }, .selection = selection } } });
    for (0..1000) |_| {
        try adapter.pump();
        if (try adapter.poll(a)) |event| {
            if (event.body == .failure) return error.ProviderFailure;
            if (event.body == .session) {
                if (adapter.resolveSelection(selection).effective == null) return error.SelectionNotVerified;
                std.debug.print("PASS installed ACP through common Adapter: negotiated2.1.4, session={s}, exact model=opencode/big-pickle, account readiness unknown (no inference)\n", .{event.body.session.upstream.value});
                if (args.len == 3) return;
                _ = try adapter.dispatch(a, .{ .start = .{ .correlation = .{ .session = event.body.session.id, .run = .{ .value = "live-run" }, .effect = .{ .value = "live-start" } }, .prompt = "Reply with exactly SPICA_OK. Do not use tools." } });
                var observed_text = false;
                for (0..4000) |_| {
                    try adapter.pump();
                    if (try adapter.poll(a)) |response| switch (response.body) {
                        .chunk => |chunk| {
                            std.debug.print("LIVE chunk: {s}\n", .{chunk.text});
                            observed_text = observed_text or std.mem.indexOf(u8, chunk.text, "SPICA_OK") != null;
                        },
                        .completed => {
                            if (!observed_text) return error.MissingLiveText;
                            std.debug.print("PASS live common Adapter text+completion; explicit opencode/big-pickle; no subscription entitlement claim\n", .{});
                            return;
                        },
                        .failure, .disconnect => return error.LiveProviderFailed,
                        else => {},
                    };
                    _ = usleep(10000);
                }
                return error.LiveTimeout;
            }
        }
        _ = usleep(10000);
    }
    return error.SessionTimeout;
}
