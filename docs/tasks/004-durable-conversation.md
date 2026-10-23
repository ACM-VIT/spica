# 004: Durable single conversation and execution state

Status: running — independent read-only implementation preparation; production implementation waits for accepted task003 interfaces and checks.
Authorization: user continuation through remaining roadmap, with explicit instruction to keep independent Sol lanes moving and avoid unnecessary setup/checkpoint serialization.
Base: d2e4e9250c9c9dd7cfde8ce2d68c8d5c9040f28b; tasks001/002 accepted, task003 fake/native implementation runs independently in private worktrees.
Owner: Astra owns decisions/acceptance; DomainPrep004 (Sol high repair specialist) performs bounded storage/recovery source preparation. No competing domain writer.

Scope: pin the smallest concrete reusable SQLite/platform boundary, new independent state location/schema and command/effect transaction design needed for one persisted fake conversation. Accepted core v1 is normative: IDs/revisions/dedup receipts, accepted-vs-completed, approvals, cancel, reopen, unknown outcomes without respawn, bounded queries/subscriptions. Do not read or migrate user history/credentials. No old application restoration.

Initial owned paths: ignored .artifacts/domain004/ only. All tracked files read-only. Parent shared Git owner remains Infra002; private task003 workers own their own branches. No Git mutations by DomainPrep004. It may read Fake003's published interface/source in .artifacts/worktrees/003-fake as evolving evidence, but cannot freeze or edit it. Shared types remain Fake003's single-owned contract.

Preparation deliverable: exact new/changed file allocation, schema/transaction ordering and failure-boundary map grounded in retained code; implementation-ready domain API for later UI consumer, no competing provider lifecycle owner. Identify concrete disk/allocation/crash/conflict tests and runnable fake-consumer smoke. Read source and run only nonmutating environment probes necessary to resolve SQLite/Zig/platform feasibility; no builds/lint/tests/formatters mid-flight, no packages/network/auth/inference. Distinguish observed reusable code from design proposal. Do not outsource top-level roadmap plan.

Budget: 30 minutes hard / 40-request soft; no grandchildren. Verify actual gpt-6.1-sol/high/no fallback header. Receipt .artifacts/domain004/preparation.md with source references, candidate identity, blockers and exact interfaces; no production commit expected in read-only preparation.

Acceptance later: persisted prompt/stream/approval/cancel/reopen and ambiguous recovery through actual command path in temporary isolated state, durable intent before external actions, no duplicate dispatch, bounded memory/query behavior and native UI integration via public seam. Task003 must be accepted before claiming task004 execution milestone. Independent preparation does not need to wait for sibling checkpoints.
