const std = @import("std");

pub const Options = struct {
    help: bool = false,
    quit_after_ms: ?u32 = null,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--help")) {
                options.help = true;
            } else if (std.mem.eql(u8, flag, "--quit-after-ms")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                options.quit_after_ms = try std.fmt.parseInt(u32, args[index], 10);
            } else return error.UnknownOption;
        }
        return options;
    }
};

pub const help =
    \\Spica — native workspace foundation
    \\Usage: spica [--help] [--quit-after-ms MILLISECONDS]
    \\
    \\A starter window built with Zig, SDL3, Clay, and the retained Unicode text stack.
    \\Uses SDL's native GPU renderer. Escape or the window close button quits.
    \\--quit-after-ms exits after a bounded smoke run (0 exits immediately).
    \\The agent workspace is not implemented yet. No provider or data store is opened.
    \\Keep the checkout's .deps and assets; rebuild after moving the checkout.
    \\
;

test "smoke deadline is bounded and legacy runtime flags are rejected" {
    try std.testing.expect((try Options.parse(&.{"spica"})).quit_after_ms == null);
    try std.testing.expect((try Options.parse(&.{ "spica", "--help" })).help);
    try std.testing.expectEqual(@as(u32, 0), (try Options.parse(&.{ "spica", "--quit-after-ms", "0" })).quit_after_ms.?);
    try std.testing.expectError(error.MissingOptionValue, Options.parse(&.{ "spica", "--quit-after-ms" }));
    try std.testing.expectError(error.Overflow, Options.parse(&.{ "spica", "--quit-after-ms", "4294967296" }));
    try std.testing.expectError(error.Overflow, Options.parse(&.{ "spica", "--quit-after-ms", "-1" }));
    try std.testing.expectError(error.UnknownOption, Options.parse(&.{ "spica", "--pi-entry", "agent.js" }));
}
