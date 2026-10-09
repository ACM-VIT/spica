<div align="center">

![ACM-VIT Banner](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/acm_gif_banner.gif)

<h2>Spica</h2>

<p>A native desktop client for <a href="https://github.com/earendil-works/pi">Pi</a>, built with Zig and SDL3.</p>

</div>

## Features

- Project folders, chat import, archives, and fuzzy full-message search.
- Switch chats while prompts run in the background.
- Markdown, code highlighting, images, and Unicode editing.

Import continues the original Pi session; archiving does not delete it.

<img width="1813" height="1187" alt="image" src="https://github.com/user-attachments/assets/6892b4eb-ef3a-43cf-a70c-c642789d5347" />


## Setup

**Linux only for now. macOS and Windows testing has not been added; support is unverified.**

Requires Zig **0.16.0**, Node.js **22.19.0+**, npm, Python **3.12+**, CMake, Make, a C/C++ toolchain, pkg-config, SQLite development files with FTS5 support, and the platform-specific development libraries required by SDL3.

From the repository root:

```sh
npm install -g @earendil-works/pi-coding-agent@1.0.0
zig build deps
zig build
./zig-out/bin/spica --project /path/to/project
```

Configure provider credentials through Pi. Dependencies are pinned in [`deps.lock.json`](./deps.lock.json); keep `.deps/` and `assets/` with the checkout and rebuild after moving it.

Spica honors `--node` and `--pi-entry` first. Otherwise it searches absolute directories in `PATH` for Node and Pi's JavaScript entry (following executable symlinks and reading pnpm's `cmd-shim-target` metadata), then platform bin directories: `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin` on macOS; `/usr/local/bin` and `/usr/bin` on Linux. Empty and relative `PATH` entries are ignored so an untrusted launch directory cannot supply code during discovery or version verification; project-local tools require explicit overrides. If Pi is still missing, it checks the global package directory from `npm root -g`, running npm with the resolved Node executable. Discovery runs off the UI thread; the npm lookup has a five-second timeout and bounded output. Shell wrappers are never executed during discovery.

Terminal launches normally pick up nvm/fnm through `PATH`. Finder launches may not see those installations; launch from your terminal or use explicit paths. Older pnpm shims without target metadata and other unrecognized wrappers may also need an override:

```sh
# npm (including nvm and fnm)
./zig-out/bin/spica --node "$(which node)" \
  --pi-entry "$(npm root -g)/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
# pnpm
./zig-out/bin/spica --node "$(which node)" \
  --pi-entry "$(pnpm ls -g --parseable @earendil-works/pi-coding-agent | tail -1)/dist/bundle/cli.js"
```

Conversation text supports click-drag selection within a message, including wrapped prose and code blocks. Shift-click or Shift+arrow keys extend the selection; Cmd/Ctrl+A selects the focused message and Cmd/Ctrl+C copies its rendered text. Home/End move within a line, and Cmd/Ctrl+Home/End move to the message boundaries. On macOS, Cmd+Left/Right move to line edges and Option+Left/Right move by word. Cmd/Ctrl+V pastes into the composer, where normal editing shortcuts remain available. Escape clears message selection. Selection is cleared when the selected message changes or leaves the decoded cache.

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
