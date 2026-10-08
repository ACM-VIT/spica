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

The model picker starts with Pi's configured models, then checks credential-specific model catalogs off the UI thread. OpenAI ChatGPT OAuth uses the signed-in account's model catalog; legacy OpenAI Codex OAuth uses its authenticated Codex catalog. Both respect server visibility and API support; an explicit identity-only OpenAI grant cannot use plan models. OpenAI API keys, Anthropic API keys, Google API keys, OpenRouter OAuth or API keys, and Groq API keys use their providers' authenticated model-list APIs. OpenRouter's account-filtered catalog excludes its batch-only variants because Pi uses interactive chat; Groq's catalog excludes inactive and non-text models. A successful complete list hides absent models without editing Pi's registry or changing the selected model. Expired OpenAI tokens refresh through Pi's credential lock. A temporary failure can reuse a successful catalog for up to five minutes, only for the identical credential; account/key changes and custom provider overrides invalidate it. Otherwise unknown availability preserves Pi's list. Startup and opening the picker refresh availability; no request runs during rendering. The short-lived helper emits IDs, timestamps, and opaque credential fingerprints, never credentials.

Access is checked separately for each provider: OpenRouter models use the OpenRouter account, independently of a ChatGPT subscription. The composer prefixes the selected model with its real provider so an OpenRouter route branded with an OpenAI model name cannot be mistaken for the OpenAI login. Older models remain available when the provider still lists them. Catalog membership does not guarantee that a request will pass credit, quota, prompt-size, or temporary rate limits.

If the selected model is confirmed unavailable, Spica preserves the selection and draft, displays a warning, and requires choosing an available model before sending. Opening the picker rereads credentials; logout removes that provider's entries, while an unreadable credential store or failed lookup remains unknown.

The picker has search at the top, **Active Models**, and a collapsible **Hidden Models** section with live counts. The quiet **Hide** and **Restore** text actions move rows immediately. Search filters both sections and opens matching hidden results; hidden models remain selectable. Ctrl+H toggles the highlighted model's visibility, and Ctrl+Shift+H expands/collapses hidden models. Each section scrolls independently, with arrow keys navigating both when expanded. Choices are saved by provider and model ID in Spica's workspace state, survive restarts, and never bypass credential filtering. The picker retains up to 4096 models so later providers are searchable beyond the old 256-entry cutoff. Normal use is `./zig-out/bin/spica --project .` after quitting any existing instance. `--data-dir` is for a separate workspace; a temporary directory is useful for isolated testing but is not required for the updates to persist.

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
