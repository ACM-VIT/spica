# 004: Durable single conversation and execution state

Status: running — source preparation reviewed; production implementation allocated after task003 acceptance.
Authorization: user continuation through remaining roadmap, with explicit instruction to keep independent Sol lanes moving and avoid unnecessary setup/checkpoint serialization.
Base: `3c18aac45d732f217bc9af98d466f3c569c8dd61`, tasks001–003 accepted. Assigned private worktree `.artifacts/worktrees/004-domain`, branch `task/004-domain`, must start from that exact committed base.
Owner: Astra owns decisions/acceptance; DomainRuntime004 now owns domain types/store/owner and private Git for the allowlist below, following DomainPrep004's clean runtime-cap handoff at `c0d7fb27a64558791824f7286f637cb611bd6289`. No competing domain writer. Infra002 remains sole shared Git integrator/publisher.

Scope: pin the smallest concrete reusable SQLite/platform boundary, new independent state location/schema and command/effect transaction design needed for one persisted fake conversation. Accepted core v1 is normative: IDs/revisions/dedup receipts, accepted-vs-completed, approvals, cancel, reopen, unknown outcomes without respawn, bounded queries/subscriptions. Do not read or migrate user history/credentials. No old application restoration.

Initial owned paths: ignored .artifacts/domain004/ only. All tracked files read-only. Parent shared Git owner remains Infra002; private task003 workers own their own branches. No Git mutations by DomainPrep004. It may read Fake003's published interface/source in .artifacts/worktrees/003-fake as evolving evidence, but cannot freeze or edit it. Shared types remain Fake003's single-owned contract.

Preparation deliverable: exact new/changed file allocation, schema/transaction ordering and failure-boundary map grounded in retained code; implementation-ready domain API for later UI consumer, no competing provider lifecycle owner. Identify concrete disk/allocation/crash/conflict tests and runnable fake-consumer smoke. Read source and run only nonmutating environment probes necessary to resolve SQLite/Zig/platform feasibility; no builds/lint/tests/formatters mid-flight, no packages/network/auth/inference. Distinguish observed reusable code from design proposal. Do not outsource top-level roadmap plan.

Budget: 30 minutes hard / 40-request soft; no grandchildren. Verify actual gpt-6.1-sol/high/no fallback header. Receipt .artifacts/domain004/preparation.md with source references, candidate identity, blockers and exact interfaces; no production commit expected in read-only preparation.

Acceptance later: persisted prompt/stream/approval/cancel/reopen and ambiguous recovery through actual command path in temporary isolated state, durable intent before external actions, no duplicate dispatch, bounded memory/query behavior and native UI integration via public seam. Task003 must be accepted before claiming task004 execution milestone. Independent preparation does not need to wait for sibling checkpoints.

## Reviewed implementation decision

Astra reviewed the source-backed preparation at `.artifacts/domain004/preparation.md`, including actual retained `SQLITE_TRANSIENT` helpers. Use its explicit separate state directory, one owner thread, durable command/receipt/effect transactions, immutable content chunks and bounded snapshot/subscription API. Do not invoke legacy cutover/validation or implicitly open any existing history. Host API is pinned as `create/destroy/submit/query/subscribe/unsubscribe/drain`; queued Ticket is not accepted Receipt. Output bytes belong to caller drain storage, never SQLite/adapter pointers. Native UI owns no dispatch or durable state. Initial bounded slot/page/snapshot limits in preparation are implementation bounds, not measured physical-memory promises.

Expiry ambiguity resolved by coordinator: adapter `ApprovalEvidence.expires_at` is optional absolute Unix epoch milliseconds (UTC), never monotonic ticks. Null advertises no expiry, not permission. Unknown/untrustworthy/expired authority fails closed; restart needs exact live evidence. Fake003 documented this at `3012c82086b29048c63bfa3758d03e57a2403f9f`.

Production allocation after task003 acceptance: DomainPrep004 owns new `src/domain.zig`, `src/domain/types.zig`, `src/domain/store.zig`, `src/domain/domain_test.zig`, `src/domain/smoke.zig`, `src/platform/store_fs.c`, `docs/contracts/durable-conversation.md`, `docs/tasks/004-domain-receipt.md`, and narrow `build.zig`/`src/test.zig` integration in its assigned private worktree. One owner avoids competing schema/reducer writers. No native app/main/options or shared adapter edits. UI lane proceeds against the pinned public seam independently; task004 must not wait for complete UI to exercise persisted conversation/crash behavior.

Use cohesive checkpoints: storage identity/transactions first, durable command/effect/reducer behavior next, public owner/query delivery and actual recovery evidence next. Each slice includes relevant meaningful tests/docs and executed checks before committing; no stubs, blind claim-based acceptance or end-only commit. Keep original/follow-up commits. Private Git allowlist is exactly the production allocation; shared integration owner remains Infra002. Whole frozen candidate gets integration checks and actual temporary-state fake-consumer/crash smoke; task004–006 UI milestone remains separate acceptance.

Native UI seam refinement: include `query.tools(run_id)`, bounded block descriptors on message rows with `next_block_cursor`, and `query.blocks(message_id,cursor)` continuation. Message paging specifies `older|newer` relative to stable ordinal/ID anchor within the same pinned snapshot. Nested descriptor bytes/rows count against page limits; source content is still fetched by explicit byte range. DomainPrep004 owns these projections/types; no second UI data/lifecycle owner.

Storage handoff: preserved types checkpoints42263bf/f3c986f and SQLite storagef32c5181 plus receipts47e07188/c0d7fb27. Actual isolated Debug/ReleaseSafe13/13 and storage consumer/reopen/abrupt before-after-COMMIT smoke passed, not public Host acceptance. Astra reviewed immutable storage diff and returned committed-range chunk dedup, recovery event/revision publication, newly created directory durability and integer-exhaustion findings to DomainRuntime004. Remaining reducers/async Host/query/subscription implementation stays authorized; no discarded work or repeated confirmation-only checks.

## Resumed shipping integration

ScriptShip006 is the serialized shared Git/integration owner for tasks004–006,
with Main retaining material contract decisions and final acceptance.
RuntimeShip004's immutable Host chain through `50b65b6` is integrated through
`690b96b`; its real recovery/consumer follow-up `f3e964a` is integrated as
`b39981d`. Source review covered real Host copied admission/drain ownership,
worker shutdown/backpressure, public projections, committed claims before fake
dispatch, and conservative recovery. No mutable sibling source was copied.

Raw public Host evidence is
`.artifacts/worktrees/004-domain/.artifacts/domain004/host-checks.json` and
`host-final-{Debug,ReleaseSafe}.log`: 19/19 tests per mode and real flow/abrupt
approval crash/recovery consumer output. Recovered runs are interrupted, pending
approval invalidated, exactly two effects retained without replay. Native App
proof remains a separate gate, not implied by headless checks.

Slot1 was explicitly re-reserved to RuntimeShip004 for concrete review closure:
terminal message incomplete finalization and changed-aggregate revision/event
coverage, plus its owned narrow Lua/native build/test-root integration. Preserve
same-candidate follow-up checkpoints and add focused actual Host/subscription
coverage; do not rerun old passing cohorts just to reconfirm them. No descendants.
