# Durable task ledger

## CURRENT

| task | parent/worker | status | branch/worktree | HEAD | blocker | integration commit |
| --- | --- | --- | --- | --- | --- | --- |
| shared integration snapshot | Main / ShippingResume (slot1; sole shared Git owner) | reviewing preserved009 and independent cancellation/acceptance tooling | `rewrite/native-agent-workspace` / shared checkout | `aa83996` (ownership checkpoint) | final009 native gate requires complete safe remediation; no Codex authentication claim | `04325d83` (bounded history no-ff merge) |
| 007/008/012 source milestone | Main / completed RuntimeFactoryLead producers | implementation review | `rewrite/native-agent-workspace` / shared source milestone | `5b6cfb3` (feature source, not latest shared HEAD) | Authenticated Codex inference/mixed delegation requires Codex authentication; not a blocker for independent work | `5b6cfb3` |
| 012 producer | RuntimeFactoryLead / completed private producer | source already integrated | `task/012-orchestration` / `.artifacts/worktrees/012-orchestration` | `58fe1a1` | none for landed source | source integrated through `5b6cfb3` |
| lead workflow policy | RuntimeFactoryLead / completed LeadWorkflowPolicy | reviewed, no-ff integrated | `task/lead-workflow-policy` / `.artifacts/worktrees/lead-workflow-policy` | `3371025` | none; offline policy/launcher checks passed | `7a73d9d` |
| 010 bounded history | RuntimeFactoryLead / completed history producers | integrated; cross-feature009 interaction still gated | `task/010-bounded-history` / `.artifacts/worktrees/010-bounded-history` | `36de5610f0aaabb653c76510737476b5383b37c0` | original fixture unlocated;009 combined Unicode/reflow proof blocked by native crash | `04325d83` |
| 009 projects/threads | ShippingResume; FreeTypeResume stopped by provider safeguard | typed cancellation policy checkpoint checked; separate partial defensive remediation preserved | `task/009-projects-threads` / `.artifacts/worktrees/009-projects-threads` | `89ade11` plus uncommitted native/build diff `5c5b46bb…` | `cyber_policy` interrupted repair; new full-FT failure test failed, last C edit not executed; no native/library acceptance | not integrated into shared branch |
| 009/010 acceptance tooling | ShippingResume / ShippingResume.AcceptanceHarness (slot3; no descendants) | recovering runnable frozen-candidate scenarios; no native execution lease | `task/009-acceptance-resume` / `.artifacts/worktrees/009-acceptance-resume` | `04325d83a02e18e939bb8882ebc17041d19bc5c2` (base) | checked patched-library handoff required before full Unicode/two-root/history execution | not integrated |
| 011 read-only workspace inspection backend | ShippingResume / ShippingResume.WorkspaceInspect011 (reassigned slot2; no descendants) | independently authorized staged implementation, not011 completion | `task/011-workspace-inspection` / `.artifacts/worktrees/011-workspace-inspection` | `04325d83a02e18e939bb8882ebc17041d19bc5c2` (reviewed source base) | native/public UI wiring and full011 acceptance remain009-dependent; backend/actual two-root CLI consumer proceeds | not integrated |

Recorded dispatch bases: task010/policy `5b6cfb3`, task009 `abb334d`. Policy was reviewed and merged with `--no-ff` as `7a73d9d`; six-file policy/model/budget assertions and offline `./tools/agents --help` passed (no repeated live nested smoke or source build for this policy-only merge). Task010 and task009 implement independently eligible features in separate private branches; their app/UI concerns are explicitly partitioned and coordinated before reviewed conflict resolution. Future checkpoints update actual HEADs, never predict SHAs. Historical ownership below is not a current slot reservation or Git/publication grant.

Quota-stop recovery: provider returned `usage_limit_reached` after exhausted retries; Main cancelled the still-registered lead rather than retrying or changing models/accounts. Resume only with available authorized Sol capacity, reconciling registered workers before assigning one integration owner. Private009 source and combined checks are preserved at `fb2ae86`; passing checks do not override the observed native crash. Handoff: private009 `.artifacts/projects009-finish/final-candidate.json`. New crash evidence: `.artifacts/projects009-freetype/native-after/{failure-evidence.json,core-stack.log,core-371873}` in that worktree. It used verified patched FreeType `b2c7…` and still failed; do not replay the crash merely to confirm or merge009 as complete. Native worker reports owned app/desktop cleanup; no new inference or acceptance claimed. ShippingResume preserves Main's intentional recovery ledger edit in the resumed ownership checkpoint.

Resume reconciliation: actual shared branch/HEAD matched the recorded snapshot; the sole dirty tracked path was Main's intentional recovery edit to this ledger, preserved here. Registered historical workers are parked/aborted; only ShippingResume, FreeTypeResume and the explicitly reserved acceptance child are active Sol workers. Existing process jobs contained FreeTypeResume and exited services, with no prior builds/apps requiring recovery. ShippingResume owns shared Git, this ledger and integration/acceptance tooling only; FreeTypeResume exclusively owns the assigned private009 native/build/test repair paths and private checkpoints. The acceptance child owns only `tools/eval-projects`, `docs/tasks/009-acceptance.md` and ignored acceptance artifacts in its separate branch. No fourth worker/descendants, shared dependency mutation, new inference or known-failing native rerun is authorized. Root and new private acceptance configuration pin actual `gpt-6.1-sol`, 60 minutes and 200 soft requests; no inherited model/fallback/advisor.

Repair interruption: FreeTypeResume diagnosed ignored `af_reverse_character_map_new` construction failure before successful autohint metrics publication and prepared a pinned defensive error-propagation patch. Its focused suite failed at the new test's `complete_metrics` assertion (`resume/focused.log`); the subsequent C-test edit was rejected before execution with provider `cyber_policy`. Preserve the four changed native/build paths and original cores; no denial rephrasing, replacement worker, failure-trigger construction, account/model switching or success claim. Main permits defensive review/ordinary functional verification only. Full `./tools/check`, repaired-library native acceptance and009 merge remain gated; passing reduced checks cannot replace them.

Main separately authorized ShippingResume to own only private009 `src/app.zig` and `src/ui/coding.zig` plus directly relevant inline tests: explicit captured run/task kind, ID and revision restores existing `.run_cancel` versus `.task_cancel` payload policy. Existing task IDs identify child runs, so both retain the existing run target; this fixes a policy/validation bypass, not an established wrong-ID failure. No task target/API or mutation endpoint is added. Private009 Git is now serialized under ShippingResume after the repair stop. Native-only diagnostic checks omit the Python step containing the interrupted new failure test using a temporary wrapper, leave production `build.zig` unchanged, and are explicitly not full acceptance. Native Cancel task may use one Main-authorized minimal real OpenCode `big-pickle` delegation/cancel cohort if reachable; no fake coordinator capability or direct database mutation may manufacture that UI gate.

Cancellation checkpoint `89ade11` contains only the two authorized App/UI paths and the serialized task009 receipt; no partial FreeType change was staged. Debug/ReleaseSafe native-only diagnostics each passed172 native tests/two skips plus four image tests; raw logs/commands are private009 `.artifacts/projects009-cancel/`. The temporary wrapper is retained there as `native-wrapper.zig.txt`, removed from the build root; production graph unchanged. Remaining private native/build binary diff SHA256 is `5c5b46bb3ed091a0506019c486f7407f0253576356f5356e3888b7b8e7420ae8`.

Main explicitly authorized the independent011 backend slice despite the blocked009 native gate: captured identity/status/staged+unstaged diff, bounded output and real two-disposable-workspace CLI consumer, no Git mutations on user roots or provider/native edits. Slot2 was reassigned only after the repair stopped and registered jobs showed no running repair job; AcceptanceHarness retains slot3 and ShippingResume slot1. The new worker owns exact backend/tests/consumer/build targets and its own task011 record in the named private branch. This is useful staged implementation, not a claim of completed011 or satisfied009-dependent UI acceptance.

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
