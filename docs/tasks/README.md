# Durable task ledger

## CURRENT

| task | parent/worker | status | branch/worktree | HEAD | blocker | integration commit |
| --- | --- | --- | --- | --- | --- | --- |
| 007/008/012 milestone | Main / RuntimeFactoryLead (slot2; sole shared Git/integration owner) | implementation review | `rewrite/native-agent-workspace` / shared checkout | `5b6cfb3` | Authenticated Codex inference/mixed delegation requires Codex authentication; not a blocker for independent work | `5b6cfb3` (current integrated milestone) |
| 012 producer | RuntimeFactoryLead / completed private producer | source already integrated | `task/012-orchestration` / `.artifacts/worktrees/012-orchestration` | `58fe1a1` | none for landed source | source integrated through `5b6cfb3` |
| lead workflow policy | RuntimeFactoryLead / RuntimeFactoryLead.LeadWorkflowPolicy (slot1) | review; frozen private policy candidate | `task/lead-workflow-policy` / `.artifacts/worktrees/lead-workflow-policy` | base `5b6cfb3`; actual checkpoint in worker receipt | none | pending lead review/no-ff merge |
| 010 bounded history | RuntimeFactoryLead / RuntimeFactoryLead.BoundedHistory010 (slot3) | running | `task/010-bounded-history` / `.artifacts/worktrees/010-bounded-history` | initial `5b6cfb3` | none; ownership-foundations 4–6 eligible without Codex auth | pending |

Snapshot at dispatch from committed `5b6cfb3`; checkpoint receipts identify later private heads. The lead updates this table after each reviewed merge; no future SHA is predicted. Historical ownership below is not a current slot reservation or Git/publication grant.

## Operating contract

The Sol integration lead owns routine decomposition/delegation/integration and this current ledger, may allocate/reassign free slots without fresh Astra authorization, and inspects registered worker state/jobs before every spawn to prevent duplicates. Astra retains consequential decisions and milestone review, not routine compiler turns. At most three active Sol workers across the whole tree INCLUDING the lead/waiting parents; descendants inherit only explicitly reserved slots and subset scopes/paths. Preserve one writer per interface/output and exactly one shared Git/integration owner; private Git applies only to owned slices. Actual `gpt-6.1-sol` only, no inherited model, fallback or advisors; stop on mismatch/unavailability. Each worker: 60 minutes, 200 requests soft, 300 forced yield (or smaller packet limits).

Every independent feature uses a named branch/private worktree from a recorded committed base; future fresh branches use the latest reviewed integration. Preserve frequent cohesive verified checkpoints and follow-up fixes. After review and stopped feature writers, the lead performs user-authorized `git merge --no-ff <feature-branch>` into `rewrite/native-agent-workspace` with a meaningful message, resolves conflicts, and runs combined checks plus actual changed-path smoke. Preserve existing cherry-picked history as-is; do not merge already-landed old branches to manufacture a graph. No push, reset, stash, history rewrite or branch switching. After each verified integration continue the next eligible authorized roadmap feature under true provider/auth/workspace prerequisites; missing Codex authentication does not block independent task010. No unattended scheduler.

## Ledger format

One Markdown record per bounded task: NNN-short-name.md. Start a record before dispatch; keep its status current. ROADMAP.md is the dependency order, not a record of completed work.

Fields: status (ready/running/review/accepted/blocked), owner/model, base/head revisions and checkpoint SHAs/checks, owned paths and current Git owner, dependencies, scope, acceptance commands/scenarios, attempts with failures, result revision/diff, evidence, reviewer decision and remaining limitations. Include task/child session identifiers when available. On restart reconcile active OMP children and the working tree before redispatching; do not create duplicate workers.

Workers own only assigned paths. The designated Sol lead directs routine integration and maintains the current ledger; other workers update only explicitly assigned records/index slices. Task packets assign one shared Git owner for frequent verified checkpoints under AGENTS.md. Final integration waits for stopped feature writers and review; workers return receipts for the lead to record. Mark accepted only after actual change/evidence review and affected integration checks, with consequential decisions/milestone acceptance retained by Astra. Keep large logs in ignored .artifacts/ rather than copying them into model context.

## Queue

- 000-bootstrap.md: branch/scaffold/OMP preparation.
- [001-contracts.md](001-contracts.md): accepted at 0d82092f0578310903d5ff49556acc820ed7179b; [core contract v1](../contracts/core.md), [reference scenarios](../contracts/scenarios.md) and [immutable source evidence](../contracts/references.md). Documentation only; domain/fake-adapter implementation and live runtime validation remain separate gates.
- [002-build-checks.md](002-build-checks.md): accepted; Debug/ReleaseSafe checks, isolated core regressions, tool pins and Linux CI configuration. Remote CI/clean-host execution remain explicitly unexercised.
- [003-fake-harness.md](003-fake-harness.md): accepted at `3c18aac45d732f217bc9af98d466f3c569c8dd61`; frozen fake/native repairs, combined Debug/ReleaseSafe checks, actual native smoke and independent asynchronous measurements reviewed.
- [004-durable-conversation.md](004-durable-conversation.md), [005-native-coding-ui.md](005-native-coding-ui.md) and [006-public-api-proof.md](006-public-api-proof.md): review — integrated runnable default/custom native fake-provider conversation, actual reload/restart proof and assembled Debug/ReleaseSafe checks passed. Final evidence review remains Main-owned; the shared milestone is not marked accepted.
- [007-codex-adapter.md](007-codex-adapter.md), [008-opencode-adapter.md](008-opencode-adapter.md), [012-app-orchestration.md](012-app-orchestration.md): current integrated implementation milestone at `5b6cfb3`, in review. Actual isolated OpenCode inference/MCP delegation/results/reopen and native allow/deny were exercised; Codex handshake/device sign-in initiation does not establish authenticated Codex inference or mixed delegation.
- 009 projects/threads/background runs and 011 workspace/Git identity: evaluate true prerequisites; task010 bounded history is now running independently (see CURRENT).
- 013 queueing/recovery/portability follows its actual runtime/workspace dependencies, not a blanket Codex-auth gate.
- 014 extension primitives, 015 explicitly demanded further integrations, 016 performance/soak and 017 Linux release readiness: pending acceptance/dependency gates. Item 015 does not authorize inventing an additional provider.

## Historical continuation authorization

After task 001 acceptance, the user explicitly requested completion of all sixteen remaining roadmap tasks. This supersedes the earlier startup-only boundary for this continuation, not the historical task 001 receipt. Subsequent user direction requires RSS/PSS/CPU/frame-time/FPS verification, private worktrees where useful, asynchronous larger evaluations and optional high-reasoning Sol repairs. Project ceiling is now three after ownership/config review; use two unless a genuinely independent third lane exists. No unattended goal loop, scheduler, blanket approval or account/profile rewrite.

Continuation base: 0d82092f0578310903d5ff49556acc820ed7179b, rewrite/native-agent-workspace, initially clean. Infra002 is sole shared Git/integration owner; Fake003/NativeHarness003 own disjoint private task003 worktrees, with Native003 as asynchronous evaluator. DomainPrep004 owns future domain types/store/owner integration; NativeUI005 prepares native UI independently. Astra owns task records/index and reviews actual diffs/evidence. Performance measurements exclude competing builds/recordings/profilers only during bounded sampled windows; release leases between cohorts for queued builds. Independent edits/builds/correctness checks otherwise run concurrently. Real entitlement, credentials, human checkpoints and distribution licensing remain explicit gates; mocks or missing prerequisites cannot count as acceptance.

Historical publication authorization/evidence (not a current push grant): the user previously requested checkpoint pushes to `thinkter/spica`. Verified origin identity/permission and nonforce HTTPS publication of `cb96d258a605d2905ad7125e7f1448b3bc6651e3` to `refs/heads/rewrite/native-agent-workspace` were recorded in `.artifacts/infra002/push-checkpoint.json`. SSH publickey authentication failed; invocation-local HTTPS helper succeeded without remote/global configuration changes. Pre-push checks passed. The current operating contract prohibits pushes and supersedes the former Infra002 publication ownership.

Domain ownership recovery: DomainPrep004 stopped at its runtime cap with clean private `004-domain` HEAD `c0d7fb27a64558791824f7286f637cb611bd6289`, five preserved types/storage checkpoints. No code-failure escalation or discarded changes. DomainRuntime004 (high Sol) now owns the same domain allowlist/candidate and remaining reducer/Host implementation; read-only inventory `.artifacts/infra002/004-recovery.json`. NativeUI005 continues independently; TextBudget005's retained-text fix was reviewed for dependency integration.

## Historical resumed feature shipping — 2026-10-23

User requested immediate Sol feature continuation after enabling nested delegation. Harness checkpoint `cbeea74` permits explicit cross-type Sol spawning with unlimited configured depth; live `NestedSmoke -> MeasureChild -> RepairLeaf` executed `SPICA_NESTED_DEPTH_3_OK`. Three aggregate active worker slots remain the operating ceiling.

At that historical dispatch, exclusive private owners were `RuntimeShip004` in `.artifacts/worktrees/004-domain` (recovered clean `9088964`), `UIShip005` in `.artifacts/worktrees/005-ui`, and `ScriptShip006` in `.artifacts/worktrees/006-script`. Those three slots had no descendant reservations; each retained private Git only for assigned paths, with no shared integration/push owner then assigned. These are superseded ownership records, not current reservations. Native/UI/runtime contracts remained those pinned in tasks004–006. Workers coordinated bounded builds and exclusive performance sampling. Actual native/durable/custom-root acceptance was pending, not implied by dispatch or checkpoint commits.

## Historical serialized feature integration ownership

Main assigned ScriptShip006 the sole shared Git/integration role for the union of
task004/005/006 production allowlists and their existing task records/index.
RuntimeShip004 and UIShip005 remain exclusive private writers; no pushes are
authorized. Main delegates routine review/integration of verified cohesive
producer checkpoints; material semantic/ownership changes and final acceptance
remain Main-owned.

Main reviewed standalone dependency/runtime checkpoints `b3e8f97` and `0df2098`
for integration. Actual default/custom native+durable proof remains unaccepted.
The integrator preserves predecessor coordination edits and applies explicit
immutable task006 checkpoints; domain owns its private build/test adaptation.
Final combined checks/native smoke wait for the assembled real app candidate;
profiling runs separately after builds stop.

Task006 integrated as `4f33f91` (locked dependency), `d4690d0` (protected runtime)
and `ef10ef2` (behavioral bootstrap test review fix), preserving private source
checkpoints `b3e8f97`, `0df2098`, `3b4ed06`. Focused follow-up LuaBootstrapTests:
2 passed; no broad repeat. Shared Lua prefix prepared only from the already
verified local archive; log `.artifacts/script006/shared-prefix-build.log`.
Prefix mutation ownership released after completion.

Slot accounting: RuntimeShip004 remains slot1; UIShip005's yielded slot2 was
explicitly re-reserved to the same worker for preserving/checkpointing its
verified native candidate and continuing actual Host integration; ScriptShip006
holds slot3 and shared Git. No descendants or fourth active worker authorized.

Reviewed domain chain through `50b65b6` integrated through `690b96b`; verified
Host recovery/public consumer follow-up `f3e964a` integrated as `b39981d`.
Preserved UI sequence through `d5838e3` integrated through `134b622`; see the
task004/task005 records for source-to-integrated SHAs and scoped evidence.
Native default/custom Host milestone remains in progress, not accepted.

RuntimeShip004's yielded slot1 was explicitly re-reserved to the same session
for terminal message finalization, changed-aggregate event coverage and narrow
build/test integration. Slot2 UIShip005 is wiring actual Host to the native App;
slot3 ScriptShip006 remains sole shared Git owner/coordinator. No fourth worker
or descendants are active. Isolated private correctness builds may run
concurrently; only performance excludes all builds/recordings/profilers.
Shared dependency-prefix mutation requires explicit exclusive ownership.

## Historical integration lead recovery

`ShipLeadContinue` replaces runtime-capped ScriptShip006 as exclusive shared
Git/integration owner for the exact task004–006 union and these records. Shared
base is `67f942a904368e2840493500dc7936ae90f4915e`, clean on recovery:
runtime repair `37ba691` already integrated as `610ebef`, actual native Host App
`b393a5c` already integrated as `67f942a`. Preserve these checkpoints.
UIShip005 retains slot2/private UI ownership for independent XDG startup,
disconnect and Lua bridge; existing HostScriptMeasure retains slot1 for its
standalone actual Host/Lua evidence. Successor occupies slot3; no duplicate
workers. Default native conversation passed real private-desktop interaction and
restart; actual custom-root integration and combined checks remain outstanding.

Next verified default checkpoint `da6719e` integrated as `2ff3985`, with actual
isolated-XDG native default flow/reopen evidence; additional explicit-state
deny/resize/approval-revocation smoke passed. UIShip005 then runtime-capped after
clean private `a04c1c3` dependency consumption. Main explicitly reassigned its
exact native private allowlist/slot2 to `ShipLeadContinue.NativeLuaBridge`.
Stopped HostScriptMeasure released slot1 without compiling its consumer;
`ShipLeadContinue.NativeMeasure` now owns evidence-only slot1 and waits for an
exclusive assembled-candidate measurement lease. Successor remains slot3/shared
Git owner. No fourth active worker, pushes or competing production writers.

## Runnable default/custom candidate

`ShipLeadContinue.NativeLuaBridge` finished private checkpoint `d5698fd`,
integrated as shared `fe6a0ff`; slot2 released with no further source/build work.
`9227180` records the exercised native scripting contract. One assembled
`./tools/check` passed Debug/ReleaseSafe and the final shared ReleaseSafe actual
custom cohort passed at
`.artifacts/ship-continue-final/native-custom-ReleaseSafe/manifest.json`.
The integrator inspected initial fallback, custom-render, malformed-last-good
and reopened screenshots; task004–006 now await Main review rather than native
implementation. NativeMeasure's slot1 exclusive paired-cohort lease was granted
only after builds and smoke stopped. No performance success is implied before
its raw results arrive; no pushes, packages or new API breadth were introduced.

Final shared ReleaseSafe custom smoke passed without rebuilding. Exclusive
paired default/custom baseline then completed and released the sampling lease;
raw combined metrics are
`.artifacts/ship-continue-measure/assembled-fe6a0ff-pair1-summary.json`.
Task005 records frame counts/percentiles, covered tree CPU/RSS/PSS, identical
settled cache tails and explicit `/proc`/sampling limitations. Both producer and
measurement workers are finished; no builds, apps or profilers remain running.
Tasks004–006 remain `review`: Main has reviewed the automated fake-provider
milestone; the human checkpoint and explicitly unexercised gates remain open.

## Main-reviewed automated fake-provider milestone

Main reviewed frozen production candidate `fe6a0ff` with evidence/record HEAD
`48acc5c`: final `candidate.json`, actual `tools-check.log` results,
`custom-render.png`/`reopened.png`, and native main startup/state and
disconnect/Host-destroy-before-SDL ordering. Main's prior review covered the
protected Lua C lifecycle/admission/protection and ABI; the integrator reviewed
native integration source. This records the automated tasks004–006 milestone
only, not whole-roadmap or product acceptance.

The roadmap's human typing/selection/scroll/cancel/config-failure/restart
checkpoint remains pending. No live Codex/OpenCode, physical latency or
large-history soak is established. The one paired baseline retains its
incomplete `/proc` samples and missed sampling intervals; no absolute peak or
repeated-run confidence is claimed.

Existing usage is `python3 build/driver.py run`; custom module selection is
documented for the executable as `zig-out/bin/spica --lua-module examples/minimal.lua`.
No unverified driver argument-passthrough syntax is implied.
Final smoke and both measurement manifests record successful `vd clean`:
`/tmp/nui-t8lkri2v`, `/tmp/nui-u2w764wp`, `/tmp/nui-qwxplu07` stopped;
evidence files retained. Producer/measurement receipts report no owned running
builds, apps or profilers. No scenario/check was repeated for this review record.
