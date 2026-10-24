# 011 — staged read-only workspace inspection

Status: review (staged backend/CLI slice only); this packet is not completion or acceptance of roadmap 011.

## Ownership and authorization

Parent: ShippingResume; worker: ShippingResume.WorkspaceInspect011 (reserved slot 2, no descendants). Actual model: openai-codex/gpt-6.1-sol; default tier, no fallback/advisor. Budget: 60 minutes / 200 soft requests. Private configuration inspected: Sol overrides, fallback disabled, 3 concurrency, 60-minute runtime.

Base: `04325d83a02e18e939bb8882ebc17041d19bc5c2`; branch `task/011-workspace-inspection`; private worktree `.artifacts/worktrees/011-workspace-inspection`. Initial index and working tree clean. This worker owns private exact-path checkpoints only; ShippingResume exclusively owns shared Git and ledger.

Owned new files: `src/domain/inspection.zig`, `src/domain/inspection_test.zig`, `src/domain/inspection_smoke.zig`, `tools/inspect-workspace`, this packet. `build.zig` may only gain dedicated inspection tests/build/run targets. Existing workspace capture/verify/path admission and process primitives are read-only reuse. No UI/provider/native/font edits, credentials, histories, services, external launches or user-root Git mutation. Disposable fixture Git initialization/commits alone are permitted.

Lead-approved ownership extension after the first dedicated compile: tiny `src/inspection_test.zig` and `src/inspection_smoke.zig` forwarding module roots only. Zig 0.16 otherwise refuses retained `workspace.zig -> types.zig -> ../contract.zig` imports outside the `src/domain` root. Dedicated targets use these roots; no normal domain/application target changes.

## Design and limits

Synchronous read-only backend for a worker or dedicated CLI, never the UI thread. Every query requires a captured WorkspaceBinding plus explicit requested absolute root; every diff requires a canonical owned relative path and staged/unstaged mode. Verify captured identity and requested checkout before inspection. Reuse workspace.capture/verify and validOwnedPath. Preserve raw porcelain NUL-delimited paths and rename source identities. Git is invoked directly with explicit argv, literal pathspecs, no optional locks, no external diff/textconv/fsmonitor. Bound operation wall time, scratch allocation, output bytes, diff bytes and changed-file count; overflow is refusal, never clipped success. Reject ambient Git override environment rather than inheriting authority-changing settings.

The callable `tools/inspect-workspace` delegates to an isolated Zig consumer, with the invocation environment explicitly passed to Zig I/O. JSON contains UTF-8 display strings (null for invalid UTF-8) plus lossless hex for raw path/diff bytes. CLI captures a root explicitly at invocation; long-lived consumers must retain their binding result until their queries end. No public/native UI wiring or external editor/terminal acceptance: those remain 009-dependent. No production `tools/check`, native/performance/provider runs.

Defaults: 4 MiB scratch, 128 KiB status/target-list output, 256 KiB diff, 2,048 files, 5 s whole-operation deadline including capture/verification. Hard configurable caps: 8 MiB scratch, 1 MiB output, 2 MiB diff, 8,192 files, 30 s. Return `StreamTooLong`, `FileLimit`, `OutOfMemory` or `InspectionTimeout`; no partial semantic success. Caller-owned result storage has explicit `deinit`. Existing identity capture retains its 16 KiB Git-output/4 KiB stderr limits. Deadline cancellation reaps its subprocess; it is cooperative OS I/O cancellation, not a hard real-time guarantee.

Benign `GIT_EDITOR`, `GIT_PAGER` and `GIT_TERMINAL_PROMPT` are allowed (fixed read-only commands never edit/prompt and disable paging); all other `GIT_*` variables are refused. Git executable resolution follows the explicit process environment/PATH convention, not an application sandbox. Repository paths are required to be checkout roots, not subdirectories. Diff accepts a single tracked, canonical owned relative file, including index deletions and literal pathspec punctuation; untracked content returns `UntrackedDiffUnavailable`. Existing symlink path components are conservatively refused. Capture currently requires a resolvable HEAD; unborn/broken repository metadata and unavailable Git remain explicit errors. Changed branch/HEAD/filesystem identity invalidates a retained binding. Before/after verification detects drift but does not make concurrent filesystem changes atomic.

Usage after `zig build build-workspace-inspection -Doptimize=ReleaseSafe`:

```sh
./tools/inspect-workspace /absolute/checkout status
./tools/inspect-workspace /absolute/checkout diff staged 'path with spaces'
./tools/inspect-workspace /absolute/checkout diff unstaged 'path with spaces'
```


## Evidence and acceptance scope

After cohesive implementation obtain the lead's serialized build lease. Run dedicated tests in Debug and ReleaseSafe plus actual CLI against two disposable Git repositories, including wrong/replaced binding, aliases, unusual paths, rename/deletion/untracked status, staged/unstaged diff, limits and cleanup. Save raw commands/results and manifest in `.artifacts/workspace011`. Check branch/HEAD/index and exact owned staged diff before checkpoints. Return source entrypoints, candidate SHA/diff identity, commands/results, attempts and limitations for review; no acceptance claim.

## Exercised candidate

Lead granted the serialized dedicated build lease. Both `zig build test-workspace-inspection build-workspace-inspection -Doptimize=Debug --summary all` and the same command with `-Doptimize=ReleaseSafe` passed: 6/6 steps, 11/11 tests each. The tests include retained wrong/replaced identity, actual directory replacement, HEAD drift, root aliases, canonical owned paths, status records, tracked staged/unstaged/deleted-file diffs, output/diff/file/allocation limits, malformed raw status and invalid time configuration. Imported retained contract declarations also contribute tests to the reported total.

`python3 .artifacts/workspace011/consumer_evidence.py` passed 22 recorded commands against two disposable Git roots and the actual tools launcher/installed ReleaseSafe consumer: root-isolated diff content, raw rename paths, newline/space/Unicode and actual non-UTF8 filename hex, staged deletion, untracked refusal, literal pathspec, symlink-root alias, non-Git, unavailable Git and ambient `GIT_DIR` refusal. A private invocation-only PATH shim exec'd `/usr/bin/sleep 30`; the 5 s operation deadline returned `InspectionTimeout` after 5.009 s, and the recorded owned PID no longer existed. Temporary roots were removed. This proves exercised subprocess cleanup, not general descendant-process sandboxing or hard-real-time completion.

Raw logs, evidence runner/result, candidate identity and manifest are under private `.artifacts/workspace011`. Earlier failure logs are retained: initial module-root compile, harmless inherited UI Git environment refusal, nested-fixture parent discovery, evidence-script status representation assumption, and missing consumer environment propagation. Repairs: approved module-root wrappers, safe UI-only environment allowlist, explicit nested-checkout refusal fixture, corrected evidence assertion, and explicit CLI I/O environment. No repeated identical failure. No native/UI/provider/performance checks or production `tools/check` were run.

Source entrypoints: `inspection.capture` / `inspection.inspect`; `inspection_smoke.main`; `tools/inspect-workspace`. Normal application/domain targets remain unchanged. Public/UI consumer and external-tool acceptance wait for safe 009 integration; this is not complete 011.
