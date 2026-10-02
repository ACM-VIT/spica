<div align="center">

![ACM-VIT Banner](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/acm_gif_banner.gif)

<h2>Spica</h2>

<p>A native desktop client for <a href="https://github.com/earendil-works/pi">Pi</a>, built with Zig and SDL3.</p>

<a href="https://acmvit.in/">
  <img alt="Made by ACM-VIT" src="https://img.shields.io/badge/MADE%20BY-ACM%20VIT-orange?style=flat-square&logo=acm" />
</a>

</div>

## Features

- Project folders, chat import, archives, and fuzzy full-message search.
- Switch chats while prompts run in the background.
- Markdown, code highlighting, images, and Unicode editing.

Import continues the original Pi session; archiving does not delete it.

## Setup

**Linux only for now. macOS and Windows testing has not been added; support is unverified.**

Requires Zig **0.16.0**, Node.js **22.19.0+**, npm, Python 3, CMake, Make, a C/C++ toolchain, pkg-config, SQLite development files with FTS5, and X11/Wayland development libraries for SDL3.

From the repository root:

```sh
npm install -g @earendil-works/pi-coding-agent@1.0.0
zig build deps
zig build
./zig-out/bin/spica --project /path/to/project
```

Configure provider credentials through Pi. Dependencies are pinned in [`deps.lock.json`](./deps.lock.json); keep `.deps/` and `assets/` with the checkout and rebuild after moving it.

Spica defaults to `/usr/bin/node` and `/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js`. Use `--node` and `--pi-entry` if your installation differs.

## Controls

| Action | Control |
| --- | --- |
| New chat | Ctrl+N / folder **+** |
| Search chats | Ctrl+K |
| Import / archive browser | Sidebar |
| Send / newline | Enter / Shift+Enter |
| Stop selected chat | Ctrl+. |
| Model / appearance | Ctrl+M / Ctrl+, |

Restore an archived chat before sending. Switching chats leaves work running; closing Spica shuts down all its chat processes.

Project resources are disabled by default because they can execute code. Enable them only for trusted projects with `--trust-project`. Use `--data-dir` for isolated application data.

## Development

```sh
zig build test
./zig-out/bin/spica --help
```

## Known Limits

- Memory use is not fully bounded: visited-chat state stays resident, up to four inactive idle Pi processes are kept warm, and running chats keep their own processes. The 32 MiB memory target has not been met.
- Drafts survive chat switching, but only the active application's draft is persisted across restarts.

---

<div align="center">

Made by <a href="https://acmvit.in/">ACM-VIT</a>

![Footer GIF](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/domains.gif)

</div>
