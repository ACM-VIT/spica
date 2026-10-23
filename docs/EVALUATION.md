# Evaluation and owner checkpoints

## Correctness and native lifecycle

`./tools/check` runs formatting, native builds and retained regressions. Native metrics tests are inline in `src/native/metrics.zig` (`zig test src/native/metrics.zig -lc`); task003 integration owner adds the aggregate import. Synthetic process-boundary tests are discovered under `build/measure_process_test.py` (`python3 -m unittest discover -s build -p measure_process_test.py`). These tests do not establish rendered or resource behavior.

`./tools/eval-starter --output .artifacts/starter-NEW` builds ReleaseSafe, creates a private 1280×800 vd desktop, captures before/after screenshots, sends real Escape, checks the native close observation and bounded telemetry accounting, and cleans its owned desktop in `finally`. Inspect both screenshots yourself. Outputs must be fresh (old native exports are rejected). No user desktop, histories, credentials, provider or network inference is used. `vd preflight` diagnoses missing desktop requirements; do not install dependencies or fall back to the user's desktop during evaluation.

The read-only `--automation-output PATH` native option exports schema v1: generation, successful frame ID, ordinary-dispatch event sequence, resize-event count, logical window and renderer-output dimensions, running/close reason and the actual `window.close` lifecycle target with Escape. There is deliberately no fake composer/control or invented clickable title-bar rectangle. Origin is `ordinary_sdl_event_path_unverified_source`: SDL dispatch cannot authenticate physical input. Runner command records separately establish vd real input versus direct state mutation. Generation advances on geometry/scale events, not on domain state (none exists).

Export paths must differ (normalized paths and parent symlink resolution checked before SDL startup). The runner retries missing/partially written JSON only until its fixed export deadline; neither file existence nor a partial parse can satisfy an assertion. `build/eval_starter_test.py` exercises missing clock, cache overflow/missing ledger, drop labeling, partial-export retry/deadline and carried idle-tail cache bounds against real summary/validation functions.

## Frozen binaries and finite measurement

Default runner builds before launching. Alternatively explicitly pin **both** current source and binary fingerprints (from a prior manifest); no build occurs in this mode:

```bash
./tools/eval-starter --binary /absolute/frozen/spica \
  --binary-sha256 BINARY_SHA256 --source-sha256 SOURCE_SHA256 \
  --output .artifacts/smoke-frozen-NEW
./tools/eval-starter --mode measure --binary /absolute/frozen/spica \
  --binary-sha256 BINARY_SHA256 --source-sha256 SOURCE_SHA256 \
  --output .artifacts/resources-repeat1-NEW
```

Record external frozen binary build mode/provenance separately; the runner does not infer it from a filename. Source SHA256 covers Git-visible src/, assets/, build/, tools/, build.zig, build.zig.zon and deps.lock.json, including untracked candidate source. Manifest records HEAD, dirty status, exact command arrays/results, fingerprints, Zig version, private desktop environment, window identity and cleanup. Source/binary drift rejects the cohort. `passed` establishes exercised lifecycle/instrumentation only, **not acceptance or performance budgets**. Raw manifest, samples.json, actions.json, automation.json, native.json, app/compositor logs and before/after.png remain ignored under the chosen output directory.

Measurement defaults implement the allocated protocol: 10s warmup, 15s idle, three cycles of 15s active real compositor resize then 15s settled idle; total 115s. Active demand alternates 1000×680 / 1100×740 at 10Hz; requested/delivered action timestamps are separate from native resize-event counts (SDL may emit multiple geometry events per command). `--warmup`, `--phase-seconds`, `--cycles` and `--interval` permit explicitly labeled finite smoke cohorts, not silently shortened acceptance. Native deadline is measured duration +60s. `--disable-metrics` allows same-binary opt-in overhead comparison; frame data is then unavailable, not zero. Repeat three fresh processes for the allocated repeated cohort. Serialize performance sampling against builds, profilers, recordings and other performance runs; independent source editing/checks need not wait except during that quiet window. Screenshots occur outside resource phases. Compositor command overhead and sampler acquisition can perturb results.

## Frame telemetry schema v1

Native `--metrics-output PATH [--metrics-capacity N]` opts into one preallocated sample buffer (default 8192 attempts, range 1..1048576). Default app remains dirty/event-driven and does not manufacture idle frames. No per-frame heap allocation or file export occurs in instrumentation. Full storage retains earliest samples and increments `dropped`; attempts = retained + dropped, and failure counts include dropped failed present calls. Failed presents are never successful frames. Export/JSON allocation happens after native run end, before teardown; errors remain explicit. The interval includes native SDL work, not resource phase capture/export.

Raw frames contain frame_id, triggering event_sequence, paint_begin_ns, present_begin_ns, present_end_ns and succeeded. Clock is SDL_GetTicksNS monotonic; an observed bracket maps native timestamps to host CLOCK_MONOTONIC, with bracket width reported as uncertainty. Host phases never use wall-clock epochs. Native begin/end bound the run, runner phases bound each workload. For successful samples in each phase, report:

- frame work = present_begin − paint_begin: CPU-side size/scale/layout/shaping/draw submission, **not GPU execution**;
- present-call = present_end − present_begin: SDL API blocking, **not scanout**;
- total paint = present_end − paint_begin;
- successful return intervals only within that phase, never spanning idle phases;
- achieved phase FPS = observed successful presents / actual phase duration, not lifetime frame count;
- nearest-rank p50/p95/p99/worst with N and null empty values; N<100 warning;
- work and total counts >16.667ms, >33.333ms, >50ms; return intervals >150ms separately for 100ms demand, **not missed 60Hz frames**.

Drops invalidate a full-cohort percentile/FPS claim: achieved_fps and distributions become null, while sampled_fps_lower_bound and exact successful_presents_run_total remain separately labeled. Required complete-cohort evaluation fails on drops, missing clock mapping, missing ledger or exceeded existing cache bounds rather than reporting passed. Explicit --disable-metrics runs label metrics unavailable; they only establish the requested disabled-instrumentation comparison. 10Hz demand does not measure render capacity. No software timestamp/screenshot proves physical input-to-photon latency. SDL renderer/video names and actual logical/output geometry are exported; `opengl` alone does not prove hardware acceleration.

Existing SpicaTextStats counters export fixed_cpu_bytes, font_bytes, layout_bytes, glyph_bytes, live_layouts, glyph_count, face_count after every present and at shutdown. The accessor only copies the existing ledger, outside the measured paint/present interval; records share the bounded frame buffer. Concrete bounds are 4MiB font tables, 2MiB retained layouts, 512 glyph entries/2MiB glyph pixels and 12 faces. Settled-tail summaries validate the latest preceding state plus every state change during the tail. This native shell mutates its cache only during paint, so carrying a measured state through event-driven idle is valid without a periodic timer/redraw. Drops or missing boundary state fail this claim. Future cache mutation outside paint must add its own observation hook before reusing this inference. The ledger excludes external metadata, driver memory and full VRAM; no miss/eviction counters exist. Domain/layout substages and history/typing/streaming behavior remain later tasks.

## Process-tree schema v2

```bash
python3 tools/measure_process.py --pid PID --label synthetic-idle \
  --settle 0 --seconds 15 --interval 0.25 --output .artifacts/process.json
```

Whole-tree membership is re-enumerated per sample, keyed by PID + stat starttime ticks, with known parent identity. Stat identities are rechecked around smaps/status reads. Root disappearance/reuse ends collection explicitly, not an all-zero plateau. New children and exited/unreadable child CPU boundaries are unknown; only identity-matched nonnegative utime+stime deltas count, without cumulative waited-child double counting. CPU percent is percent of **one core**, may exceed 100%, and is reported for covered intervals with completeness. Unobserved child prefixes/tails and short-lived descendants cannot be recovered.

Raw rows preserve per-member ticks, context switches, RSS/PSS/anonymous memory, read errors, monotonic acquisition start/duration, scheduled cadence, lateness and skipped intervals. Missing/permission/parse/identity errors never become zero memory. Partial readable sums remain marked incomplete; complete-only distributions cannot establish a complete peak when coverage is missing. Enumeration errors are separately marked `stage: enumeration` (including unrelated process races); known-member errors live in that member's errors array. This conservative global discovery uncertainty can reduce complete sample count.


Lifecycle `passed` is independent of `resource_coverage`. Every resource phase explicitly reports complete/incomplete sample counts, skipped/missing intervals, conservative coverage status and observed-complete-sample peak scope. Unrelated /proc enumeration races remain recorded and may exclude otherwise readable app samples. A passing lifecycle run never establishes complete tree CPU/peak coverage or captures all short-lived descendants.
Tree RSS sums double-count shared mappings/pages. PSS sums proportional residency; neither is system or GPU allocation accounting. Summaries retain complete-only first/median/p95/p99/worst/last/growth, membership and acquisition distributions plus per-identity covered CPU/context-switch intervals. Runner separates warmup/idle/active/settled summaries, final ≤5s settled tails, sampled peaks and first→last settled median growth. Observed sampled peak is not an absolute ceiling; 250ms sampling misses shorter peaks. Do not introduce arbitrary new memory/performance budgets or average away regressions.

## Later acceptance

Fake adapter tests are not durable workspace acceptance. Persisted prompt/stream/tool approval/cancel/reopen, actual composer/focus/scroll, configuration failure and a small custom root wait for domain/UI tasks. Later workloads reuse identity, phase and raw telemetry evidence. Physical display pacing, IME/accessibility and cross-platform validation remain explicit gates, not headless claims.
