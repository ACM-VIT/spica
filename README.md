<div align="center">

![ACM-VIT Banner](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/acm_gif_banner.gif)

<h2>Spica</h2>

<p>A native desktop workspace for the Pi coding agent, built with Zig and SDL3.</p>

<p>
  <a href="https://acmvit.in/" target="_blank">
    <img alt="made-by-acm" src="https://img.shields.io/badge/MADE%20BY-ACM%20VIT-orange?style=flat-square&logo=acm&link=acmvit.in" />
  </a>
</p>

</div>

---

## Table of Contents

- [About](#about)
- [Tech Stack](#tech-stack)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Project Layout](#project-layout)
- [Development](#development)
- [Current Limitations](#current-limitations)
- [Contributing](#contributing)

---

## About

Spica provides a desktop interface for [Pi](https://github.com/earendil-works/pi): project folders, conversations, streamed answers, tool activity, and model controls without a browser-based UI.

- **Intentional workspace:** only explicitly imported conversations and chats with an accepted prompt become workspace members.
- **Original-session import:** continue an existing Pi conversation without copying, moving, or deleting its source file.
- **Fuzzy chat search:** search titles, folders, and complete user/final-assistant text, including archived conversations.
- **Archive and restore:** keep history and drafts while removing a chat from active navigation.
- **Background work:** switch conversations or create a new thread while another chat's Pi process keeps running.
- **Native rendering:** Unicode editing, Markdown, code highlighting, tables, images, appearance settings, and zoom.

Conversation history stays on disk; the desktop loads and shapes the visible content. Project resources are opt-in because they may execute code.

## Tech Stack

- **Application:** Zig 0.16.0 with native C/C++ boundaries.
- **Windowing and rendering:** SDL3, SDL3_image, and Clay.
- **Text:** FreeType, HarfBuzz, FriBidi, and libunibreak.
- **Content:** cmark-gfm and Tree-sitter.
- **Storage and search:** SQLite with FTS5 and RapidFuzz C++.
- **Agent runtime:** Pi 0.87.1, running as an owned Node.js child process over RPC.

Native source archives and fonts are pinned in [`deps.lock.json`](./deps.lock.json).

## Getting Started

### Prerequisites

The current real-process application is supported on **Linux**.

Install:

- Zig **0.16.0**.
- Python 3, CMake, Make, a C/C++ toolchain, and pkg-config.
- SQLite development headers and a SQLite library with **FTS5 enabled**.
- X11/Wayland development libraries required to build SDL3 for your desktop.
- Node.js **22.19.0 or newer** and npm for Pi.

### Build and run

From the repository root:

```sh
npm install -g @earendil-works/pi-coding-agent@0.87.1
zig build deps
zig build
./zig-out/bin/spica --project /absolute/path/to/your/project
```

`zig build deps` downloads, verifies, and builds the pinned native dependencies under `.deps/`. Configure your provider credentials through Pi before sending model prompts; Spica uses Pi's configuration rather than a separate credential store.

The default runtime paths are `/usr/bin/node` and `/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js`. If your Node/npm installation uses different locations, supply them explicitly:

```sh
./zig-out/bin/spica \
  --node /absolute/path/to/node \
  --pi-entry /absolute/path/to/pi-coding-agent/dist/bundle/cli.js \
  --project /absolute/path/to/your/project
```

Keep `.deps/` and `assets/` with the checkout. Rebuild after moving the checkout; this is not a standalone packaged binary.

## Usage

| Action | Control |
| --- | --- |
| Create a thread in the current folder | New thread / Ctrl+N |
| Create a thread in another project | That folder's **+** |
| Find active or archived conversations | Search chats / Ctrl+K; Cmd+K is also recognized |
| Enroll an existing Pi conversation | Import Pi chat |
| Browse archived conversations | Archives |
| Send a prompt | Enter / Ctrl+Enter |
| Insert a newline | Shift+Enter |
| Stop the selected chat's work and clear its queues | Ctrl+. |
| Select a configured model | Ctrl+M |
| Open appearance settings | Settings / Ctrl+, |
| Refresh the library and theme | Ctrl+R; Cmd+R is also recognized |

Opening an archived conversation does not restore it; use **Restore** before sending. Navigation does not stop running chats. Closing Spica shuts down all its owned chat processes.

Project resources are disabled by default. Enable them only for a trusted project:

```sh
./zig-out/bin/spica --project /absolute/path/to/trusted/project --trust-project
```

For isolated application data, use `--data-dir`. Membership, cached content, and derived search live in `app/history.sqlite` under that override; original Pi session files remain in Pi's configured storage.

```sh
./zig-out/bin/spica --data-dir /tmp/spica-demo --project /absolute/path/to/project
./zig-out/bin/spica --help
```

## Project Layout

| Path | Responsibility |
| --- | --- |
| [`src/app.zig`](./src/app.zig) | Application lifecycle, navigation, and chat ownership |
| [`src/core/`](./src/core/) | Pi RPC, session projection, SQLite storage, discovery, and search |
| [`src/ui/`](./src/ui/) | Sidebar, transcript, library modal, settings, and widgets |
| [`src/text/`](./src/text/) | Unicode composer editing |
| [`src/content/`](./src/content/) | Content loading and Markdown processing |
| [`src/native/`](./src/native/) | Native rendering and dependency adapters |
| [`src/platform/`](./src/platform/) | Process ownership, paths, and durable database migration |
| [`assets/`](./assets/) | Theme and application resources |
| [`build/bootstrap.py`](./build/bootstrap.py) | Locked native dependency acquisition and build |
| [`tools/`](./tools/) | Development and measurement utilities |

## Development

Build the application and run the regression suite from the repository root:

```sh
zig build
zig build test
```

Run the app through Zig while forwarding CLI arguments:

```sh
zig build run -- --project /absolute/path/to/project
```

Exercise UI changes in the actual application with isolated data. Measure the desktop and its Pi/Node children separately; desktop RSS alone is not the total application cost.

## Current Limitations

- The real Pi process integration is Linux-only; other platforms are not advertised as supported.
- Software rendering is the default. Neither renderer has passed the project's 32 MiB memory target.
- Up to four inactive idle Pi processes are kept warm, in addition to the selected chat. Busy chats remain alive, so concurrent work increases resource use.
- Visited-chat metadata and drafts currently remain in memory for the application session. This state is not yet a bounded disk-backed cache for thousands of visited chats.
- Per-chat drafts survive navigation within the running app; the existing disk writer persists the active application draft, not every parked chat's draft across restarts.

## Contributing

Keep changes focused, run the relevant regressions, and include the native scenario used to verify a behavioral change. Prefer compact data, explicit ownership, bounded working sets, and incremental work.

Do not commit provider credentials, personal Pi sessions, local databases, or generated dependency/build directories. Preserve original session data and keep OS-specific mechanics behind the platform boundary.

---

<div align="center">

Crafted with love by <a href="https://acmvit.in/" target="_blank">ACM-VIT</a>

![Footer GIF](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/domains.gif)

</div>
