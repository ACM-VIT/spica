# Contributing to the rewrite

This branch starts a new native agent workspace. Read AGENTS.md and docs/ROADMAP.md. Linux is the currently exercised target; retaining macOS boundaries and tests does not establish macOS application support.

## Toolchain

The build uses Zig 0.16.0, clang-format 22.1.8, Python 3, a C/C++ compiler, CMake, make, pkg-config, autoconf, automake and libtool. SQLite development files with FTS5 and the desktop development libraries are needed by the native build. OMP is used to develop the application; Node/Pi are not application startup requirements.

```bash
python3 build/bootstrap.py
python3 build/driver.py
python3 build/driver.py test
python3 tools/format.py
./tools/check
```

bootstrap.py acquires checksum-locked sources and fonts from deps.lock.json into ignored .deps/. It may need network access on first use. Keep lockfile and build logic in sync. driver.py supplies macOS SDK handling; on Linux it invokes Zig directly. Build/test use the existing cache without reinstalling system packages. Optional Lefthook hooks in lefthook.yml run the same formatting/build/regression checks before push.

Formatting includes existing and new project-owned sources, and excludes dependencies/build output. It deliberately skips deleted files during rewrite work. Do not format vendored dependencies.

## Working in parallel

Use ./tools/agents for the Astra coordinator and the project Sol agents. Keep each task's ownership and acceptance gates in docs/tasks. Start with two concurrent workers; only independent paths proceed together. Workers return changes and evidence; integration and Git mutations are serialized after they stop. Commit the base before using isolated worktrees. Never commit personal OMP settings, sessions, private histories or auth data.

Use narrow tests during implementation and ./tools/check for integration. GUI work also needs inspected private-desktop screenshots and real input. Expensive profiling and repeated benchmark matrices are justified by an actual change or unresolved regression; they are not a mandatory loop for every edit. See docs/EVALUATION.md.

There is no CI configured in this initial scaffold; reproducible CI is an early P0 task in the roadmap. Resolve project-source licensing/provenance before distributing this rewrite: the inherited tree has no top-level license file. Do not infer a license from a dependency or the reference application.
