# Contributing to Spica

## Supported development environment

Linux is the currently verified platform. Native Windows and macOS support is not yet verified.
Run commands from the repository root.

## Required tools

| Tool | Requirement | Purpose |
| --- | --- | --- |
| Zig | **0.16.0** | Application compilation, type checking, tests, and `zig fmt` |
| clang-format | **22.1.8** | C/C++ and header formatting |
| Lefthook | **2.1.16** | Client-side pre-push hook |
| Python | **3.12+** | Dependency bootstrap and formatting driver |
| Node.js | **22.19.0+** | Pi runtime |
| npm | Available on `PATH` | Install Pi |
| Pi coding agent | **1.0.0** | Chat runtime |
| Git | Available on `PATH` | Checkout and source enumeration for formatting |
| CMake, Make, C/C++ toolchain, pkg-config | Available on `PATH` | Build native dependencies |
| Autoconf, Automake, libtool | Available on `PATH` | Build libunibreak |
| SQLite development files | With FTS5 support | Storage and search |
| X11/Wayland development libraries | For SDL3 | Linux windowing support |

Install system build prerequisites using your distribution's package manager.
Native library/font sources and checksums are pinned in `deps.lock.json`; the bootstrap downloads and builds them under `.deps/`.
The initial dependency build needs network access.

Install [Lefthook 2.1.16](https://github.com/evilmartians/lefthook/releases/tag/v2.1.16) using its platform release or a package manager and put it on `PATH`.
clang-format 22.1.8 can be installed in a Python virtual environment:

```sh
python3 -m venv ~/.cache/spica-format-venv
. ~/.cache/spica-format-venv/bin/activate
python3 -m pip install clang-format==22.1.8
```

Keep that environment active when running checks or pushing if it supplies your formatter.

## First-time setup

```sh
npm install -g @earendil-works/pi-coding-agent@1.0.0
lefthook install
zig build deps
zig build
zig build test
./zig-out/bin/spica --help
./zig-out/bin/spica --project /path/to/project
```

Configure provider credentials through Pi to use models. Building and running regressions does not require provider credentials or model calls.
On macOS, replace `zig build [args]` with `python3 build/driver.py [args]`
to select an SDK compatible with both the native compiler and Zig.
Use `mise exec --` if mise supplies the tools.
Spica discovers Node and Pi through `PATH`, platform bin directories, then `npm root -g`.
Use `--node /path/to/node` and `--pi-entry /path/to/cli.js` to override discovery (for example, nvm/fnm installations unavailable to Finder or shell wrappers without recognized target metadata).
Keep `.deps/` and `assets/` with the checkout and rebuild after moving it.

## Checks required before pushing

Install the hook once per clone with `lefthook install`; cloning alone does not activate Git hooks.
The only configured hook is **pre-push**, and it runs on your own machine:

```sh
lefthook run pre-push
```

It checks all three commands:

```sh
python3 tools/format.py --check
zig build
zig build test
```

All must pass before pushing. A failure blocks the push. The hook does not install dependencies or modify source files.
There is no GitHub Actions workflow for these checks and no pre-commit hook.
Hooks can be bypassed, so contributors remain responsible for passing checks.

**Type checking:** Zig performs compile-time type checking as part of `zig build`; `zig build test` also compiles the regression code before running it.
The build compiles the native C/C++ sources as well. There is no separate typechecker command or configured clang-tidy/static-analysis pass.
Passing these checks does not replace exercising the behavior changed by your contribution.
For UI changes, launch the app and inspect the actual interaction; report platform and verification details in your pull request.
For assistant-response clipboard changes, follow [CLIPBOARD_TESTING.md](CLIPBOARD_TESTING.md) for native delivery checks and the macOS test procedure.

## Formatting

```sh
python3 tools/format.py          # apply formatting
python3 tools/format.py --check  # check without changing files
```

The driver formats tracked, project-owned Zig/C/C++ sources and headers, plus the Zig build files.
It excludes external/generated dependency sources. Zig uses `zig fmt`; C/C++ uses `.clang-format`.
Enable the same formatters on save in your editor. Keep broad formatting-only changes separate from behavioral changes.

## Local verification snapshot

When this guide was added, the local Linux pre-push run passed all three checks:
formatting for 53 owned source/build files, `zig build` (including compiler type checking),
and `zig build test`. The built executable also completed `./zig-out/bin/spica --help` successfully.
This records a local check, not a GitHub CI result or proof of interactive UI/platform support.
Rerun the checks for your own changes; this snapshot is not a guarantee for later commits.
