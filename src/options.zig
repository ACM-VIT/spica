const std = @import("std");

pub const Options = struct {
    data_dir: ?[]const u8 = null,
    fixture: bool = false,
    renderer: enum { native, software } = .software,
    capture: ?[]const u8 = null,
    quit_after_ms: ?u32 = null,
    light: bool = false,
    help: bool = false,
    project: []const u8 = ".",
    node_path: []const u8 = "/usr/bin/node",
    pi_entrypoint: []const u8 = "/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js",
    resume_file: ?[]const u8 = null,
    trust_project: ?bool = null,

    pub fn parse(args: []const [:0]const u8) !Options {
        var options: Options = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--help")) options.help = true else if (std.mem.eql(u8, flag, "--light")) options.light = true else if (std.mem.eql(u8, flag, "--trust-project") or std.mem.eql(u8, flag, "--no-project-resources")) {
                if (options.trust_project != null) return error.ConflictingTrustChoice;
                options.trust_project = std.mem.eql(u8, flag, "--trust-project");
            } else if (std.mem.eql(u8, flag, "--data-dir") or std.mem.eql(u8, flag, "--renderer") or std.mem.eql(u8, flag, "--fixture") or std.mem.eql(u8, flag, "--capture") or std.mem.eql(u8, flag, "--quit-after") or std.mem.eql(u8, flag, "--project") or std.mem.eql(u8, flag, "--node") or std.mem.eql(u8, flag, "--pi-entry") or std.mem.eql(u8, flag, "--resume")) {
                index += 1;
                if (index == args.len) return error.MissingOptionValue;
                const value = args[index];
                if (std.mem.eql(u8, flag, "--data-dir")) options.data_dir = value else if (std.mem.eql(u8, flag, "--capture")) options.capture = value else if (std.mem.eql(u8, flag, "--project")) options.project = value else if (std.mem.eql(u8, flag, "--node")) options.node_path = value else if (std.mem.eql(u8, flag, "--pi-entry")) options.pi_entrypoint = value else if (std.mem.eql(u8, flag, "--resume")) options.resume_file = value else if (std.mem.eql(u8, flag, "--quit-after")) options.quit_after_ms = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, flag, "--fixture")) {
                    if (!std.mem.eql(u8, value, "resource")) return error.UnknownFixture;
                    options.fixture = true;
                } else {
                    if (std.mem.eql(u8, value, "native")) options.renderer = .native else if (std.mem.eql(u8, value, "software")) options.renderer = .software else return error.UnknownRenderer;
                }
            } else return error.UnknownOption;
        }
        if (options.fixture and options.data_dir == null) return error.FixtureRequiresIsolatedDataDirectory;
        if (options.fixture and (options.resume_file != null or options.trust_project != null)) return error.FixtureCannotStartRuntime;
        return options;
    }
};

pub const help =
    \\Spica — native pi control plane
    \\Usage: spica [--project PATH] [--data-dir PATH] [--renderer software|native]
    \\             [--node NODE_PATH] [--pi-entry PI_JS_PATH] [--resume SESSION_FILE]
    \\             [--trust-project|--no-project-resources] [--light]
    \\             [--fixture resource --data-dir ISOLATED_PATH]
    \\             [--capture PNG_PATH] [--quit-after MILLISECONDS]
    \\
    \\Software is the lower-residency default. Neither backend has passed the 32 MiB gate.
    \\Pi starts automatically. Project resources are disabled unless --trust-project is given.
    \\The real-process first-pass demo is Linux-only, pinned to pi 0.87.1.
    \\Executable defaults match a system Node and npm installation.
    \\Use --node and --pi-entry for another installation. --resume is explicit, not replay.
    \\Checkout demo libraries, fonts and themes resolve independently of the launch directory.
    \\Keep the checkout's .deps and assets directories; rebuild after moving the checkout.
    \\Project resources may run code: --trust-project opts in; --no-project-resources opts out.
    \\
    \\The sidebar discovers existing pi threads across project folders and legacy Spica sessions.
    \\Select a thread to resume it in its own folder; + creates a new session without deleting history.
    \\New sessions use pi's normal configured storage, shared with the pi CLI.
    \\Stop active work before switching threads. Ctrl+P retries a failed pi startup.
    \\The first prompt's first line names an unnamed pi session; explicit resume keeps it.
    \\Enter sends; Shift+Enter inserts a newline; Ctrl+Enter also sends.
    \\While running, input is a follow-up; click that control to choose steering instead.
    \\Ctrl+B switches Prompt/Bash; Ctrl+M opens actual configured models.
    \\Thinking choices come from pi; each assistant's Reasoning disclosure keeps its answer visible.
    \\Ctrl+. clears queues and aborts agent/Bash work. Close requests graceful shutdown.
    \\Cancelled queue text stays on disk; an empty editor recovers one cancelled message.
    \\Large multiline tool output uses visible text segments, not an unbounded layout.
    \\If pi will not exit, Force requires an explicit choice (also Ctrl+Shift+Esc).
    \\Wheel and PageUp/PageDown scroll the full conversation, including previous prompts.
    \\Scrolling upward stops auto-follow; scrolling to the bottom or clicking the current thread resumes it.
    \\The sidebar has its own wheel scroll. Ctrl+L switches light/dark; Ctrl+R reloads theme/history.
    \\Composer supports Unicode multiline editing, selection, undo and durable drafts.
    \\
    \\Resource scene: disk-backed Markdown, code, tables, mixed scripts, and PNG.
    \\No pi process is launched by the resource scene; there is no prompt replay.
    \\External Linux baseline: tools/measure_process.py --pid PID --label LABEL --output FILE
    \\
;
