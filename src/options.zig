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
    \\The real-process application is Linux-only, pinned to Pi 1.0.0.
    \\Executable defaults match a system Node and npm installation.
    \\Use --node and --pi-entry for another installation. --resume is explicit, not replay.
    \\Checkout demo libraries, fonts and themes resolve independently of the launch directory.
    \\Keep the checkout's .deps and assets directories; rebuild after moving the checkout.
    \\Project resources may run code: --trust-project opts in; --no-project-resources opts out.
    \\
    \\The sidebar contains only active workspace chats; historical pi sessions are not enrolled.
    \\Import Pi chat searches nonmembers and continues the original source after durable enrollment.
    \\The first accepted prompt enrolls a new chat; empty drafts never accumulate workspace members.
    \\New and newly enrolled chats reveal their folder and selected row without expanding other folders.
    \\Ctrl/Cmd+K searches titles, folders and full user/final-assistant text with RapidFuzz fuzzy matching.
    \\Search includes closed chats; History shows conversations whose tabs have been closed.
    \\Closing a saved tab keeps its source files and moves it to History. Reopen continues that session.
    \\Stop running prompts before closing their tabs. Ctrl/Cmd+W closes the selected tab.
    \\Click a chat to reopen it; folder headers only expand/collapse their chat list.
    \\Click the folder control inside the composer to pick a recent folder or browse. Recent folders are saved newest first.
    \\Ctrl/Cmd+T or Ctrl/Cmd+N opens a plain chat. Sending without a folder uses the app-owned tmp workspace.
    \\Reopening keeps the selected chat title visible while its history loads.
    \\Long messages and table cells render in bounded visible segments without truncating retained text.
    \\SQLite membership and content live in app/history.sqlite; legacy cache databases migrate via backup.
    \\Source files remain original resume sources; unavailable chats retain metadata and cached search.
    \\Search waits for a complete ranking before allowing Open, Close tab/Reopen, or paging.
    \\New sessions use pi's normal configured storage, shared with the pi CLI.
    \\Switch chats or create a new thread while prompts run; background chats keep their own Pi process.
    \\Returning to a running chat reconnects its existing process and restores its draft.
    \\Stop applies to the selected chat; closing Spica shuts down all owned chat processes.
    \\Ctrl+P retries a failed pi startup.
    \\Switching to another folder disables trusted project resources for that runtime.
    \\The first prompt's first line names an unnamed pi session; explicit resume keeps it.
    \\Enter sends; Shift+Enter inserts a newline; Ctrl+Enter also sends.
    \\While running, input is a follow-up; click that control to choose steering instead.
    \\The composer only sends prompts, never direct shell commands. Ctrl+M opens configured models.
    \\Thinking choices come from pi; each assistant's Reasoning disclosure keeps its answer visible.
    \\Prompts use bubbles; answers stay plain. Timestamps are source times in UTC, not estimated durations.
    \\File reads, changes and commands collapse into activity summaries; failed calls remain visible.
    \\Expand an activity group, then a named tool to read its output; reasoning has its own disclosure.
    \\Collapsed output is not decoded or shaped. Decoded text, metadata and thumbnails share a 16 MiB cache.
    \\Offscreen entries are evicted first; text layouts and glyphs have separate hard budgets.
    \\Ctrl+. clears queues and aborts agent/Bash work. Close requests graceful shutdown.
    \\Cancelled queue text stays on disk; an empty editor recovers one cancelled message.
    \\Large multiline tool output uses visible text segments, not an unbounded layout.
    \\If pi will not exit, Force requires an explicit choice (also Ctrl+Shift+Esc).
    \\Wheel and PageUp/PageDown scroll the full conversation, including previous prompts.
    \\Scrolling upward stops auto-follow; Jump to latest or clicking the current thread resumes it.
    \\Vertical and horizontal tabs share folder groups and their own wheel scroll. Ctrl+B hides/shows it; Ctrl/Cmd+R refreshes theme/library.
    \\Settings / Ctrl+, switches tab layouts and opens appearance: text 12–24px, UI scale 75–175%, reading width 560–1120px.
    \\Settings > Animations toggles short tab entrances and sidebar sliding; Off applies immediately.
    \\Dark/light themes, tab layout, animations, appearance values, and recent folders persist across restarts.
    \\UI scale changes layout and hit targets; text rasterizes at native output DPI.
    \\Ctrl+Plus/Minus or Ctrl+wheel zooms; Ctrl+0 resets UI scale to 100%.
    \\Ctrl+L also switches dark/light. Settings has Reset and Done; Escape closes it.
    \\Composer supports Unicode multiline editing, selection, undo and durable drafts.
    \\Ctrl+Left/Right moves by word; add Shift to select. Ctrl+Backspace/Delete removes a word.
    \\Home/End moves to visual line edges; Ctrl+Home/End moves to document edges.
    \\
    \\Resource scene: disk-backed Markdown, code, tables, mixed scripts, and PNG.
    \\No pi process is launched by the resource scene; there is no prompt replay.
    \\External Linux baseline: tools/measure_process.py --pid PID --label LABEL --output FILE
    \\Measure the desktop and its pi/Node child separately; the desktop RSS is not total application cost.
    \\
;
