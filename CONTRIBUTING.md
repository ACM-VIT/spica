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

For the fast, isolated editor/core regression loop, use
`python3 build/driver.py test-core -Doptimize=Debug --summary all`
and repeat with `-Doptimize=ReleaseSafe`. This target links only libc and the
locked libunibreak from `.deps` (it does not require SDL, fonts or a display).
It exercises the retained Unicode editing, bounded input and allocation-failure
checks with Zig's leak-aware test allocator. The full `test` target retains
native parser/image/text and platform regressions. Test executables run on every
invocation; compilation may be cached, and `--summary all` distinguishes the two.
Direct driver invocations reject any Zig version other than 0.16.0.

Formatting includes existing and new project-owned sources, and excludes dependencies/build output. It deliberately skips deleted files during rewrite work. Do not format vendored dependencies.

## Working in parallel

Use ./tools/agents for the Astra coordinator and the project Sol agents. Keep each task's ownership and acceptance gates in docs/tasks. Start with two concurrent workers; only independent paths proceed together. Workers make frequent small checkpoint commits after cohesive slices pass relevant checks; do not wait for the final milestone or review. In the shared checkout, one explicitly assigned Git owner stages exact owned paths and commits while the other workers avoid Git mutations; private assigned worktrees can checkpoint directly. Checkpoints are not acceptance. Final integration uses a frozen, reviewed candidate after workers stop. Commit the base before using isolated worktrees. Never commit personal OMP settings, sessions, private histories or auth data.

Use narrow tests during implementation and ./tools/check for integration. GUI work also needs inspected private-desktop screenshots and real input. Expensive profiling and repeated benchmark matrices are justified by an actual change or unresolved regression; they are not a mandatory loop for every edit. See docs/EVALUATION.md.

Linux CI is configured in `.github/workflows/check.yml`: it provisions the host
prerequisites, verifies the pinned Zig archive, installs clang-format 22.1.8,
runs `python3 build/bootstrap.py`, then runs the same `./tools/check` entrypoint.
The default check formats without mutation, builds and exercises the full suite
in Debug and ReleaseSafe (debug symbols retained), and runs the existing CLI
`--help` path with temporary HOME/XDG directories. `./tools/check --core` runs
only the isolated core target in both modes, without formatting/native startup.
Neither local check command downloads dependencies or installs packages.

On Ubuntu 24.04 the host packages are `build-essential cmake pkg-config autoconf
automake libtool libsqlite3-dev libx11-dev libxext-dev libxrandr-dev libxcursor-dev
libxi-dev libxfixes-dev libxss-dev libxtst-dev libwayland-dev libxkbcommon-dev
libegl1-mesa-dev libgl1-mesa-dev libdrm-dev libgbm-dev libpng-dev zlib1g-dev
libbz2-dev python3 python3-venv curl xz-utils`. Native source/font revisions and
hashes are locked, not every host dependency: SQLite (including FTS5), the
system compiler, desktop libraries and optional FreeType dependencies remain
host prerequisites. This is a repeatable supported-host build, not a hermetic
or bit-for-bit reproducible toolchain. Native C dependencies are built in Release;
the Debug/ReleaseSafe matrix applies to Zig application/tests, not C sanitizer
coverage. Existing bootstrap/SDK/platform tests use separate temporary roots;
SQLite fixtures synthesize their own history and never open user data.

Resolve project-source licensing/provenance before distributing this rewrite:
the inherited tree has no top-level license file. Do not infer a license from a
dependency or the reference application.
