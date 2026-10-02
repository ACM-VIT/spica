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

## Development

```sh
zig build test
./zig-out/bin/spica --help
```

### Formatting and Git hooks

Use Zig **0.16.0**, clang-format **22.1.8**, and [Lefthook **2.1.16**](https://github.com/evilmartians/lefthook/releases/tag/v2.1.16).
Install Lefthook using its platform release or package manager and make it available on `PATH`.
clang-format can also be installed with `python3 -m pip install clang-format==22.1.8` in a virtual environment.

```sh
lefthook install
python3 tools/format.py          # format owned Zig, C, headers, and C++ files
python3 tools/format.py --check  # check without rewriting
lefthook run pre-push           # formatting, build, and regressions
```

Pre-push checks formatting, runs `zig build`, and runs `zig build test`; it never auto-formats.
Run `zig build deps` first on a fresh checkout. Hooks do not install native dependencies.
Checks run locally only through the pre-push hook; no GitHub Actions workflow is configured.

Enable format-on-save with `zig fmt` for Zig and clang-format for C/C++ in your editor.
The C/C++ style is defined in `.clang-format`; external/generated dependencies are excluded.
These are formatting checks, not a clang-tidy/static-analysis setup.

## Known Limits

- Memory use is not fully bounded: visited-chat state stays resident, up to four inactive idle Pi processes are kept warm, and running chats keep their own processes. The 32 MiB memory target has not been met.
- Drafts survive chat switching, but only the active application's draft is persisted across restarts.

---

<div align="center">

Made by <a href="https://acmvit.in/">ACM-VIT</a>

![Footer GIF](https://raw.githubusercontent.com/ACM-VIT/.github/master/profile/domains.gif)

</div>
