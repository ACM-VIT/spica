# Task004 domain receipt — bounded implementation slice

Status: review of concrete types/storage slices; **task004 acceptance incomplete**. Private `task/004-domain`, base `3c18aac45d732f217bc9af98d466f3c569c8dd61`. Checkpoints: `42263bf44f212efb654c939a662bd2803d2d4814` (domain values), `f3c986f05fe8ceb7a1d3aef471fc957b8812fb5f` (aggregate/byte-codec review repairs), `f32c5181b08175a447c682e31b2233cf260040f2` (SQLite storage). Receipt checkpoint recorded in ignored manifest. No uncommitted implementation candidate remains.

Owned changes: domain root/types/store/tests/storage consumer, directory-sync C helper, narrow build/test wiring and implementation docs. Fixed review findings: distinct content/effect aggregate IDs; explicit monotonic snapshot expiry; byte-exact partial-UTF8/NUL encoding/decoding and stored-format migration rule. Real storage provides separate identity/lock/WAL/FULL transactions, exact receipt dedup primitives, atomic events/chunks, conservative claims/recovery and legacy rejection.

Checks: `zig build test-domain build-domain-smoke -Doptimize=Debug --summary all` and ReleaseSafe each **13/13 passed**. Actual binaries passed storage consumer/reopen and abrupt `_exit(73/74)` before/after COMMIT in both modes; repeated delivery retained one project/receipt/event. Evidence: private `.artifacts/domain004/checks.json`, check/smoke logs, per-mode `consumer.json`, exported checkpoint diffs. One initial fixture-name compiler error repaired locally; no substantive failed repair loop. Full native integration checks not run.

Remaining authorized work requires another bounded slice: production command reducers/approval/cancel/reconcile, immutable per-run fake scenario owner, async Host and bounded query/subscription execution, public command-path conversation/crash smoke. No Host stub or duplicate-external-call acceptance claim. Actual Sol/high/no-fallback; default requested tier, resolved tier/usage unavailable; initial header evidence remains shared `.artifacts/domain004/session-header.json`.

## DomainRuntime004 continuation

Inherited exact clean `c0d7fb27a64558791824f7286f637cb611bd6289` and all five preserved commits; the recovery inventory and original 13/13 Debug/ReleaseSafe storage/crash evidence were read, not rerun merely to confirm them. Initial focused base diff SHA256 `935b818b4b2a02d11e43e52df73aed344947c7868cde7ae628ea9e065402e2df`.

First continuation slice implements real internal project/workspace/thread/send/approval/cancel/evidence-reconcile reducers, byte-exact durable receipts with dedup-before-revision, immutable planned requests and committed claim return boundary. Queued cancel withdraws without dispatch; recovery leaves ambiguity unknown. Assigned storage objections addressed: bounded indexed committed-range replay across chunk boundaries; atomic recovery effect/approval/run revision events; state-directory ancestor fsync; explicit revision exhaustion rejection in chunk/claim/recovery and run mutation reducers. No async Host or adapter execution acceptance is claimed.

Affected checks after this slice: `zig build test-domain -Doptimize=Debug --summary all` and `zig build test-domain -Doptimize=ReleaseSafe --summary all`: **16/16 pass each**. New tests exercise real reducers without SQL fixture insertion for project/workspace/thread/send/cancel/reconcile, original-receipt replay after changes, canonical arbitrary invalid-UTF8/NUL prompt bytes, claim/recovery nonreplay, range replay, and overflow. Three compiler iterations fixed Zig shadow declarations and an anonymous-result type locally; no substantive failed runtime repair loop. Raw own-model source/provenance: ignored `.artifacts/domain004/runtime-header.json` (Sol/high/no fallback, default tier; usage unavailable). Public gateway conversation/crash smoke, async bounded queries/subscriptions and fake execution remain open.

Second cohesive continuation slice: internal adapter delivery/observation reduction, exact observation dedup, content/tool result persistence, approval digest/epoch/UTC checks, cancel-vs-queued-reply withdrawal, no terminal/unknown lifecycle revival, cursor+session revision events. Exact final affected commands: `zig fmt src/domain.zig src/domain/store.zig src/domain/domain_test.zig`; `zig build test-domain -Doptimize=Debug --summary all`; `zig build test-domain -Doptimize=ReleaseSafe --summary all`. Both safety modes **17/17 pass** (Debug 475ms tests, ReleaseSafe 434ms tests). No adapter calls, UI interaction, performance sampling or new abrupt-crash smoke ran; predecessor storage evidence remains separately scoped.

Finding dispositions: committed-range replay fixed with subrange/combined replay tests; recovery bulk mutation now atomically emits exact effect/approval/run events (test checks effect/run projections; approval query implemented but specific approval-recovery regression remains open); newly created directory ancestry sync implemented and exercised by temporary store opens, but no power-loss fault test; i64 revision guards cover implemented chunk/claim/recovery/reducer mutations, not future Host/projection paths. Observation-ID allocation/mapping, exhaustive changed-aggregate event coverage, immutable fake scenario, bounded Host/query/subscription execution and public-gateway conversation/crash acceptance are still open. No task004 acceptance claim. The 40-request soft-budget notice required wrapping this successful slice rather than beginning an unverified Host. NativeUI005 and Script006 were explicitly told that planned signatures are not an implemented Host.

## RuntimeShip004 shipping continuation

Status: review, not native milestone acceptance. Recovered clean private
`task/004-domain` HEAD `9088964156a2a9d2e126fb6652aa6122f2eae6dd`,
preserving every predecessor checkpoint and source change. Dependency checkpoint
`50b65b6` ships asynchronous `Host`, pinned projections, bounded queues,
read-only snapshot transactions, subscriptions and actual fake dispatch after
committed claims. Native executable linkage now includes retained content/storage.

The follow-up slice adds public temporary-state smoke and conservative reopen
reduction: active runs without ambiguous claims become interrupted; in-flight
claims remain unknown; approvals invalidate and pending tools become unknown,
with atomic revision events. Subscription tests cover ordered replay, tiny-drain
retention and stale unsubscribe generations.

Executed `python3 .artifacts/domain004/check_host.py`: internally runs
`zig build test-domain build-domain-smoke -Doptimize=Debug --summary all` and
ReleaseSafe, **19/19 tests pass each**. Both actual binaries complete prompt,
Unicode/code stream, allow/tool completion and second-run cancellation; deliberate
`_exit(75)` at durable approval reopens interrupted with invalidated authority and
exactly two original effects. Existing claim-ambiguity tests cover unknown/no-replay.

Evidence manifest: ignored `.artifacts/domain004/host-checks.json`,
`host-final-{Debug,ReleaseSafe}.log`, and per-mode `host-{flow,crash,recover}-*.log`.
No UI/performance or power-loss acceptance claimed. Exhaustive changed-aggregate
event coverage, terminal message incomplete-flag finalization and native consumer
integration still warrant lead review. No substantive failed repairs; available
model `openai-codex/gpt-6.1-sol`; resolved tier/usage unavailable; no descendants.
