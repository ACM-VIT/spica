# Evaluation and owner checkpoints

## Available now

./tools/check runs formatting, native build and retained regression suites. The local system has perf, heaptrack, Valgrind, wf-recorder, GDB and the private-desktop requirements installed (checked 2026-10-23). No package installation is required for the initial local loop. Check versions and kernel permissions when a specific profiler is needed. CI, domain scenarios, semantic UI automation and frame telemetry remain P0 implementation tasks.

Use the installed virtual-desktop skill / vd for GUI checks:

`./tools/eval-starter` builds the current native starter, captures it, sends Escape through real input, verifies the window closes, and cleans up its private desktop. It rejects source/binary changes during the run and writes the build log, screenshot, app log and revision/source/binary manifest to .artifacts/starter/. Stop competing source writers/builds before using it. Inspect the screenshot yourself; the script establishes lifecycle and capture, not visual correctness. This starter-specific check is replaced/extended as interactive features arrive.

```bash
vd preflight
mkdir -p .artifacts
s=$(vd start --width 1280 --height 800)
trap 'vd clean "$s"' EXIT
vd run "$s" --bg -- "$PWD/zig-out/bin/spica"
vd windows "$s"
vd shot "$s" "$PWD/.artifacts/starter.png"
vd clean "$s"
```

Create .artifacts/ first and use the observed window ID/geometry for vd text/click/key. Inspect screenshots, resize and exercise normal input when relevant. Stop the owned desktop even if a check fails. This isolates the display, not filesystem/network access; synthetic fixtures must also have separate state directories. Do not fall back to controlling the owner's main display.

## Build the feature harness next

Implement a deterministic fake provider with stream fragmentation, tool/approval, cancellation, error/exit and fake clock scenarios. Add commands to inspect semantic UI IDs and export bounded telemetry; screenshots alone cannot assert domain state. Run input through the ordinary event path. Verify persisted work after restart, duplicate commands, allocation/disk failure, and ambiguous external outcomes.

Record each evaluation manifest: revision and dirty diff identifier, toolchain/build mode, fixture/seed, renderer/resolution/scale, command, assertions, sample count, logs and screenshot/recording paths. .artifacts/ is ignored; keep private histories and credentials outside shareable evidence. Task records link evidence and state limitations.

## Performance and memory

Start baseline telemetry in P0: bounded stage traces for input, domain processing, layout, shaping, draw submission and present-call blocking. Export p50/p95/p99/worst plus sample/drop counts. Track frame intervals only during active work; idle need not manufacture frames. Present-call timing is not physical display latency.

Use release builds with symbols, fixed synthetic data and repeated paired baseline/candidate workloads: startup, warm idle, typing during streaming, scroll, large rich message, many threads, resize, repeated open/close and soak. Fix renderer, scale and dimensions. Serialize runs and avoid concurrent builds/profilers/recorders. Diagnose separately. Capture process-tree PSS and per-process CPU/RSS, queue depth and cache occupancy/evictions; GPU allocation is a separate measure. tools/measure_process.py currently samples ONE Linux process, not the whole tree and not GPU memory.

Keep source/formatting correctness when limiting memory. Debug/ReleaseSafe, leak-aware allocators, allocation failure tests and selected ASan/UBSan C/FFI harnesses detect classes of errors. Coverage of one harness does not establish whole-program memory safety. Add targeted fuzzing for protocol/config/parsers. No performance gain or memory ceiling is claimed by this scaffold.

## When Ashman should use it

1. First useful build: after fake-provider streaming/tool approval/cancel/reopen and one small custom root pass together. Try typing, selection, scroll, cancel, broken config and restart for about ten minutes.
2. First real provider: do one coding task in a disposable checkout; compare actual files/processes with UI claims.
3. Daily use: multiple threads, preserved drafts/scroll and explicit workspaces; import a large history and hand-write a configuration before stabilizing SDK behavior.
4. Release: upgrades/data recovery, physical display frame pacing, IME/clipboard/scaling/accessibility and packaging. Headless checks cannot establish physical latency or cross-platform support.

Agents continue independent work while waiting for feedback; dependent design decisions wait. Each checkpoint supplies the runnable revision, exact actions, known limitations and evidence.
