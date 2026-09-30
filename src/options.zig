const std = @import("std");

pub const Options = struct {
    data_dir: ?[]const u8 = null,
    fixture: bool = false,
    renderer: enum { native, software } = .native,
    capture: ?[]const u8 = null,
    quit_after_ms: ?u32 = null,
    light: bool = false,
    help: bool = false,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--help")) options.help = true
            else if (std.mem.eql(u8, flag, "--light")) options.light = true
            else if (std.mem.eql(u8, flag, "--data-dir") or std.mem.eql(u8, flag, "--renderer") or std.mem.eql(u8, flag, "--fixture") or std.mem.eql(u8, flag, "--capture") or std.mem.eql(u8, flag, "--quit-after")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                const value = args[index];
                if (std.mem.eql(u8, flag, "--data-dir")) options.data_dir = value
                else if (std.mem.eql(u8, flag, "--capture")) options.capture = value
                else if (std.mem.eql(u8, flag, "--quit-after")) options.quit_after_ms = try std.fmt.parseInt(u32, value, 10)
                else if (std.mem.eql(u8, flag, "--fixture")) {
                    if (!std.mem.eql(u8, value, "resource")) return error.UnknownFixture;
                    options.fixture = true;
                } else {
                    if (std.mem.eql(u8, value, "native")) options.renderer = .native
                    else if (std.mem.eql(u8, value, "software")) options.renderer = .software
                    else return error.UnknownRenderer;
                }
            } else return error.UnknownOption;
        }
        if (options.fixture and options.data_dir == null) return error.FixtureRequiresIsolatedDataDirectory;
        return options;
    }
};

pub const help =
    \\Spica — native pi control plane
    \\Usage: spica [--data-dir PATH] [--renderer native|software] [--light]
    \\             [--fixture resource --data-dir ISOLATED_PATH]
    \\             [--capture PNG_PATH] [--quit-after MILLISECONDS]
    \\
    \\Resource scene: disk-backed Markdown, code, tables, mixed scripts, and PNG.
    \\PageUp/PageDown select saved fixture messages; wheel scrolls the current message.
    \\Ctrl+L switches light/dark. Composer supports multiline editing and durable drafts.
    \\No pi process is launched by the resource scene; there is no prompt replay.
    \\
;
