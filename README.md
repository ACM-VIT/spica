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

Use **Settings → Connect a provider**, or **Connect a provider** in the model picker, to choose a provider and its sign-in method. For browser sign-in, use **Open browser**; paste a code or redirect URL only if needed. API keys and authorization codes are masked, with an 8192-byte UTF-8 input limit. Credentials stay in Pi's normal credential store, shared with the Pi CLI. Models refresh after connection without replacing the current chat. Stop any active chat run before connecting.

Authentication runs in a dedicated Pi SDK helper without loading extensions. Provider dialogs accept prompts only from this helper, never from chat extensions. Extension-defined authentication handlers are not loaded by the helper. Pi extensions remain trusted code with access to credential files; this isolates the UI channel, not the operating-system account.

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
