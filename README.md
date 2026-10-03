<div align="center">

![ACM-VIT Banner](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/acm_gif_banner.gif)

<h2>Spica</h2>

<p>A native desktop client for <a href="https://github.com/earendil-works/pi">Pi</a>, built with Zig and SDL3.</p>

</div>

## Features

- Folder-grouped vertical or horizontal tabs, chat import, History, and fuzzy full-message search.
- Switch chats while prompts run in the background.
- Markdown, code highlighting, images, and Unicode editing.

The + opens a plain chat at the right end. Its composer has a folder control with recently opened folders first and a Browse option. Choosing a folder moves the draft into that group; the + on a folder creates a draft inside it. Changing a draft's folder keeps its text, selection, and undo history. Sending without choosing a folder groups the chat under `tmp`. Switch tab layouts in Settings. Horizontal tabs scroll with a trackpad, mouse wheel, or arrows only when they exceed the window width. Closing a tab selects its visible neighbor. Closing a saved tab keeps it in History; reopening continues the original Pi session.

Ctrl/Cmd+T (or Ctrl/Cmd+N) opens a tab; Ctrl/Cmd+W closes it. Stop a running prompt before closing its tab.

Vertical folder rows show their + only on hover. Settings > Animations toggles short tab entrance and sidebar slide transitions. Off takes effect immediately, and the preference persists across restarts.

<img width="1813" height="1187" alt="image" src="https://github.com/user-attachments/assets/6892b4eb-ef3a-43cf-a70c-c642789d5347" />


## Setup

**Linux only for now. macOS and Windows testing has not been added; support is unverified.**

Requires Zig **0.16.0**, Node.js **22.19.0+**, npm, Python **3.12+**, CMake, Make, a C/C++ toolchain, pkg-config, SQLite development files with FTS5, and X11/Wayland development libraries for SDL3.

From the repository root:

```sh
npm install -g @earendil-works/pi-coding-agent@1.0.0
zig build deps
zig build
./zig-out/bin/spica --project /path/to/project
```

Configure provider credentials through Pi. Dependencies are pinned in [`deps.lock.json`](./deps.lock.json); keep `.deps/` and `assets/` with the checkout and rebuild after moving it.

Spica defaults to `/usr/bin/node` and `/usr/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js`. Use `--node` and `--pi-entry` if your installation differs.

## Development

Read [CONTRIBUTING.md](./CONTRIBUTING.md) before making changes. It lists required tools,
first-time setup, formatting commands, and the client-side pre-push checks.
Contributors must install **Lefthook 2.1.16** and run `lefthook install` once per clone.
Formatting, compilation/type checking, and regressions must pass before pushing.

---

<div align="center">

Made by <a href="https://acmvit.in/">ACM-VIT</a>

![Footer GIF](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/domains.gif)

</div>
