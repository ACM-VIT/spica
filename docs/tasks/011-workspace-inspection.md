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

Benign `GIT_EDITOR`, `GIT_PAGER` and `GIT_TERMINAL_PROMPT` are allowed (fixed read-only commands never edit/prompt and disable paging); all other `GIT_*` variables are refused. Git executable resolution follows the explicit process environment/PATH convention, not an application sandbox. Repository paths are required to be checkout roots, not subdirectories. Diff accepts a single tracked, canonical owned relative file, including index deletions and literal pathspec punctuation; untracked content returns `UntrackedDiffUnavailable`. Existing symlink path components are conservatively refused. Capture supports a valid unborn symbolic branch with an absent branch ref: `non_git=false`, actual common/git-directory identities and branch, and empty `base_revision`. Staged diff uses the actual index without requiring HEAD in that state. Malformed metadata, missing referenced objects, detached missing HEAD and unavailable Git remain explicit errors. First commit or changed branch/HEAD/filesystem identity invalidates a retained binding. Before/after verification detects drift but does not make concurrent filesystem changes atomic.

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

## Shared staged-slice integration

ShippingResume reviewed the actual backend, tests, consumer, wrappers and build
wiring, then no-ff integrated producer `be5cf90` as shared `09365daa65a19f13732d00a184b66c1e8400f8d8`.
The first shared `./tools/check` stopped at formatting. The sole source correction
was Zig's spacing normalization around the saturating slice bound in
`inspection.zig`; no semantic change or failed-check suppression.

The changed candidate (shared base `09365daa`, binary diff SHA256
`7c1986edf46057200555b2aad9eb133d66995575c309dfab73541cdd91816686`)
passed `./tools/check`: formatting 94 files, Debug/ReleaseSafe executable builds
and CLI smoke, each 156 native tests/two skips plus four image tests, Python 35
tests/two skips. Dedicated inspection test/build targets passed 11/11 in both
modes. The actual integrated CLI repeated 22 disposable-root commands, including
non-UTF8 paths, exact per-root staged/unstaged diffs and a 5.007-second deadline
with no remaining owned subprocess; temporary roots were cleaned.

Exact commands, hashes and logs are shared
`.artifacts/shipping-resume/integrated-repaired-checks.json`; changed-path consumer
evidence is `consumer-result.json` and `consumer-raw.log` alongside it. The first
formatting failure is preserved as `integrated-0.log`. These checks cover the
shared recovered tooling and staged 011 backend only: task009 and its separate
partial FreeType remediation were **not** merged or accepted. No native desktop,
provider or performance attempt occurred. Full 011 public/UI/external-tool
acceptance remains 009-dependent.

## Unborn repository startup repair

Current focused owner/Git owner: UnbornWorkspaceFix; evidence worker:
UnbornStartupMeasure (ignored artifacts only). Actual model:
openai-codex/gpt-6.1-sol, no fallback/advisor. Scope is solely valid unborn
repository capture/verify, affected inspection/tests and launch documentation;
no task009/FreeType work. Private branch `task/fix-unborn-workspace`, worktree
`.artifacts/worktrees/fix-unborn-workspace`, recorded clean base
`e21fa8d08062444ae46dc0bc568483b8f88de4ae`.

The reported native startup traces are ground truth; the unchanged failing app
was not rerun. Capture proves an absent symbolic branch ref rather than treating
any failed HEAD lookup as unborn. Subprocess output buffers are freed explicitly.
Regression scenarios use real disposable Git repositories for fresh/staged
capture, reopen, staged/unstaged inspection, branch replacement, first commit,
detached HEAD and malformed/missing-object refusal. Existing byte codec and
public capture signature remain unchanged.

Focused commands `zig build test-workspace-inspection build-workspace-inspection
-Doptimize=Debug --summary all` and the corresponding `ReleaseSafe` command
passed 13/13 tests each; `zig build -Doptimize=ReleaseSafe --summary all` built the
native candidate. Logs and exact commands:
`.artifacts/worktrees/fix-unborn-workspace/.artifacts/repair1/focused.json`.
One substantive repair followed the initial focused run: Git discovery skipped
a malformed nested `.git/HEAD` and found the parent checkout. Capture now checks
the nearest actual `.git` marker against Git's discovered top-level root, refusing
that wrong-checkout substitution. The initial failure log is preserved at
`.artifacts/worktrees/fix-unborn-workspace/.artifacts/focused-0.log`; its test
unexpected-success result also reported leaked result storage (not a successful
capture ownership claim). Repaired runs have no reported leaks.

Checkpoint `60e83b1f32ac1b86e1d67f43ee2fc692ef0c7df5` was frozen for the actual
native evidence worker. ReleaseSafe binary SHA256:
`e22f9f0ffd06dc6f908c032b7c227b27e116e6f19bec474da3c9c7ef658f90d1`.
The single actual isolated Wayland/OpenGL run passed loaded conversation, real
OpenCode 2.1.4 `opencode/big-pickle`, effort `default`, benign prompt completed
with `OK`, clean shutdown and same durable thread/run after restart.
The installed absolute runtime was `/home/ashman/.opencode/bin/opencode`.
The disposable workspace received `git init` only, no seed commit. Every `.git`
file hash stayed unchanged through prompt, restart and desktop cleanup; symbolic
HEAD stayed `refs/heads/main`, HEAD verification remained exit128, refs/status
empty. Both app exits were zero with no surviving owned processes.

Raw manifest, exact argv/commands/environment, logs and reviewed ready/prompt/
reopened screenshots:
`.artifacts/unborn-startup/feature-60e83b1/manifest.json`.
The fix owner reviewed those three screenshots and recorded assertions. This
is actual fixed-path evidence, not a repeated run of the reported failing app.
No X11/physical-latency, unrelated task009/FreeType or authenticated Codex claim.

After actual source/diff/evidence review, producer evidence checkpoint `52b28cc`
was no-ff integrated as `0a55e41ba41e86f8b6d930f3cd5ae8b1c4e3af77`.
The assembled shared `./tools/check` passed once: formatting94 files, normal
`build/driver.py` Debug/ReleaseSafe executable builds, each156 native passes/
two skips plus four image tests, Python35/two skips and CLI help smoke.
Exact command/result and raw log:
`.artifacts/worktrees/fix-unborn-workspace/.artifacts/integration-check.json`.
This refreshed the actual shared `zig-out/bin/spica` using normal builds:
ReleaseSafe SHA256
`c87d76409640dcb70d6676f40c34f3eae0ce157969214d2baa3b12dae647a522`.
The refreshed shared binary then passed one actual startup-only smoke (no
duplicate inference prompt): fresh `git init` workspace, visible Ready
conversation/active composer, clean close/reopen of the same durable thread,
zero admission errors, both exits zero and no surviving owned processes.
All `.git` hashes remained unchanged through startup/restart/cleanup, with
`refs/heads/main`, unresolved HEAD, empty refs and clean status.
Reviewed shared ready/reopened screenshots and exact evidence:
`.artifacts/unborn-startup/integrated-0a55e41/manifest.json`.

The development executable in the shared branch now carries the exercised fix.
No seed commit, fabricated revision, non-Git fallback, user-root/account mutation,
or unrelated roadmap/native-library change was used. Status remains review;
Astra retains acceptance. Sole source repair count: one. LSP was unavailable
(`xd://lsp`: no such tool); bounded source reference searches established affected
field consumers and preserved the public capture signature/byte codec.
