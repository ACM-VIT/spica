# 001: Core contracts and reference scenarios

Status: accepted
Owner: Astra coordinates/reviews; Contracts001 and References001 are the two Sol workers.
Base: 59f708f5280a5344c295d6a2ddc0ecd7bc5b44ad on rewrite/native-agent-workspace; clean index/worktree before dispatch. Bootstrap e6e32ef is accepted in 000-bootstrap.md; subsequent scope/workflow commits are included in this candidate.
Owned paths: Contracts001 owns docs/contracts/core.md, docs/contracts/scenarios.md and docs/tasks/001-contract-receipt.md. References001 owns docs/contracts/references.md and docs/tasks/001-reference-receipt.md. Astra owns this record and docs/tasks/README.md. Ignored evidence is disjoint under .artifacts/contracts001/ and .artifacts/references001/.
Dependencies: bootstrap accepted; met. No dependent roadmap task is authorized.

Scope:
- Pin the chosen T3 reference revision and behavior scenarios, without copying private data or assuming source licensing.
- Define stable project/thread/run/message IDs, revisioned commands/events and provider capabilities. Include app-owned parent/child task IDs, runtime-instance/session IDs, model/effort/account references, workspace ownership and review disposition; keep runtime identity separate from its internal model provider.
- Define persistence/effect/approval/cancel/crash ownership and workspace identity. Completion receipt distinguishes accepted intent from completed effect.
- Agree minimal fake adapter and UI query/subscription seams so two workers can implement against the same contract. Codex/ChatGPT sign-in and OpenCode v2 are the first two real runtime targets; inspect the pinned T3 source for adapter/orchestration reference behavior.
- Define delegate/message/wait/cancel/list and coordinator-tool bridge requirements, parent cancellation/child detach policy, cumulative subtree budgets and unknown-result recovery. A prompt alone does not implement delegation; identify the version-supported host-tool/MCP hook for each runtime.
- Use docs/PROVIDERS_AND_ORCHESTRATION.md for verified integration entrypoints and uncertainty. Do not implement live adapters or run paid experiments in this contracts-only task.

Acceptance:
- One readable contract and state transition table covers create/send/stream/tool approval/cancel/reopen and ambiguous effect recovery.
- Define duplicate command, stale mutation and pagination invalidation behavior. Include concurrent child completions, duplicate delegation, model fallback mismatch, unavailable capabilities and restart without re-spawning unknown work.
- Propose the smallest meaningful contract regression scenarios and implement only what this task owns.
- Astra inspects source/diff and approves or returns specific interface changes before dependent implementation.

Commit cadence: make small local commits as cohesive contract/scenario slices are verified; do not wait for the entire task or final review. Assign the single shared Git owner and concrete path allowlist before dispatch, then report checkpoint SHAs. Checkpoint commits do not imply acceptance.

## Dispatch and acceptance packet

- Authorized candidate: documentation-only contracts and reference scenarios. No runtime implementation, domain scaffolding, build/renderer edits, live inference, authentication changes, package installation or private-history access.
- Contracts001 is the sole initial Git owner, allowed to stage only its three owned documentation paths. References001 cannot mutate Git until an explicit ownership transfer. Astra ledger changes remain unstaged until final integration is explicitly allocated.
- Each worker has a 30-minute hard limit / 40-request soft budget (60 forced yield), no grandchildren. Requested model: gpt-6.1-sol; resolved identity must be checked. Checkpoint cohesive verified slices promptly, not only at final acceptance; commits are not acceptance.
- Shared contract: contract version 1; domain owns durable intent/state and app-managed child tree; adapters own runtime transport and upstream mappings; UI consumes queries/subscriptions. IDs, cancellation, budgets and unknown-effect recovery have one specification owner, Contracts001. References001 supplies evidence and capability constraints, not a competing API.
- Reference worker pins immutable T3 source, inspects adapter/orchestration behavior and licensing without copying implementation, and identifies version-supported Codex/OpenCode host-tool/MCP entrypoints with explicit uncertainty. Contract worker may draft existing constraints concurrently, but must consume the pinned evidence before freezing interfaces.
- Acceptance retains every scope/scenario item above. Deliver one readable contract/state-transition table, reference provenance and minimal regression scenarios with concrete preconditions/actions/oracles, clearly marked as specifications rather than implemented runtime tests.
- Checks: workers skip build/lint/tests/formatters mid-flight; inspect documentation links and source evidence for cohesive checkpoints. After both candidates stop and Astra reviews the actual changes, one Git owner runs ./tools/check once and an offline contract/scenario consistency smoke. No visual/runtime behavior change is claimed.
- Receipt paths are the owned docs/tasks files; manifests/raw source/check outputs stay in the disjoint ignored evidence directories. Record exact source pins, commands, checkpoint SHAs, findings, model identity and limitations.

Attempts: round 1; OMP jobs/agents Contracts001 and References001. Astra inspected both resolved session headers: openai-codex/gpt-6.1-sol, no fallback, medium thinking, default tier. Initial contract checkpoints: 4bb50f5a5715c324f41684c8e622e78673080b2d (core), b2dea40850dcc9d7ea38b99d507a12b889a18d76 (seams/scenarios), aa00abbc40ec2695a4871df38d3eaa104a4b1741 (source alignment).

Review round 1: Astra read the actual new contracts/scenarios and focused diff, immutable reference document, source manifests, and upstream transaction, receipt replay, bridge/capability, permission and recovery source. Four contract clarifications returned to the same owner: late content must not revive cancelled/terminal runs; withdrawn start effects need a durable nondispatchable state; query/subscription/wait positions need consistent transaction/event-index semantics and split-batch coverage; task-budget counting must explicitly include or exclude root.

Git ownership: Contracts001 relinquished at aa00abb with clean index; Astra transferred to References001 for its two owned files, then back at 71fa815. Reference checkpoints: 2156a685dfd2f742391cda90bcee9bfec5356835 (source evidence) and 71fa815a753fa8089b11f0982ee35b247c93511f (receipt). Same-owner repair checkpoint: 749e3b9257e9e8f90a65b26b9c916028883e40fa. Integration receipt checkpoint: c88219100d57d54065dd13f9f9263351818b6ac9. Contracts001 is the sole final Git owner, authorized to commit only Astra's two frozen ledger files after checking the index and exact staged diff.

## Acceptance checkpoint

Astra accepts task 001's documentation-only deliverable. Reviewed [core v1](../contracts/core.md), [twelve scenario families](../contracts/scenarios.md), [immutable source evidence](../contracts/references.md), both slice receipts, actual new-file/repair diffs and relevant upstream source. All four review findings are resolved in 749e3b9: late content preserves cancellation/terminal state; withdrawn effects cannot dispatch after restart; pair positions preserve same-transaction events; descendant budgets exclude the root explicitly. No dependent implementation is accepted or authorized.

Frozen contract candidate tested: 749e3b9257e9e8f90a65b26b9c916028883e40fa; contract source hashes unchanged through checks. Final pre-ledger HEAD c88219100d57d54065dd13f9f9263351818b6ac9 adds only the verified receipt. Focused contract/receipt base-diff SHA-256: f0b383561513ab633c3beef047bdf1ee2cfcaed46e878f6e2efe6ad727a7d67f. The commit containing this acceptance record is the final ledger checkpoint; its parent is c882191, avoiding a self-referential SHA.

Checks reviewed:
- `./tools/check` ran once on the frozen candidate, exit 0; formatting checked 50 files; build/check entrypoint completed; reported Python suite ran 14 tests, two skipped. No separate native test count is asserted by this run's log.
- Offline documentation smoke exited 0: 16 relative links/anchors, twelve ordered scenario IDs, seven acceptance-map rows, three immutable reference pins and unchanged candidate hashes. This is documentation consistency, not fake-domain execution.
- Reference inspection captured 33 public source files and checked 25 immutable links plus six source assertions. T3 pin eb1510d2493cbf28600432d5193cc22a1af8f3d8; Codex 0.163.0 pin 83086188ae0614bd882818ff1aa23f3194962012; OpenCode v2.1.4 pin 68bc26b7da1990ce10ffecfbc1e09eb13aa5d824. Licensing/provenance and live-capability uncertainty remain explicit.

Evidence: `.artifacts/contracts001/integration-manifest.json`, `tools-check.log`, `documentation-smoke.log`, `integration-command.txt`, `review.diff`, `repair-1.diff`; `.artifacts/references001/manifest.json`, `sources.json`, `supplemental-sources.json`, `excerpts.json`, `checkpoint.json`, `review.diff`. Durable worker receipts: [contracts](001-contract-receipt.md), [references](001-reference-receipt.md). Temporary smoke executable removed; ignored source/evidence retained.

Limits and stop: one review-repair round, no failed integration checks; two reference acquisition failures recovered without changing scope. Both workers ran as verified Sol, medium/default, and stopped; cumulative token/cost usage unavailable, no further budget authorized. No domain code, adapters, scheduler, live auth/inference, runtime bridge invocation, UI changes or measured performance claim. Regression scenarios remain specifications for later implementation. Next dependency-eligible roadmap item is 2 (build/check infrastructure), but no dependent task may start under this authorization.
