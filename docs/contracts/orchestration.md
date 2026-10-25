# App-owned orchestration execution

## Durable runtime seam

`Host.Options.factory` supplies immutable, side-effect-free runtime metadata and creates one final-address adapter per committed runtime session. The default deterministic fake backend uses the same factory/registry path as native providers, not a separate effect dispatcher. The Host worker exclusively creates, dispatches, pumps and polls a fixed registry of three instances (coordinator plus two children). Exact runtime/version/model/effort/account/workspace selection is retained per entry. Unknown readiness permits an authoritative handshake; unavailable metadata rejects admission. Open waits for adapter readiness, at most 15 seconds, and is sent once. Acknowledgement without session evidence leaves create in flight and start blocked.

Host calls adapter shutdown exactly once, keeps the authenticated endpoint bound through shutdown, then unbinds and invokes factory destroy for memory disposal. Failed create must clean partial resources; Host removes its endpoint binding. Terminal or ambiguous process ownership is released without resetting durable unknown claims. Reopening never respawns recovered work or replays ambiguous mutations.

## Task tree and transport

Public commands delegate/send/cancel, submit explicit candidate/evidence/summary results and record candidate-bound review dispositions. Task list/wait queries return bounded durable snapshots; wait is a nonblocking status/result poll, not a new provider request. Coordinator tools `task.delegate`, `task.send`, `task.wait`, `task.cancel`, `task.list`, `task.catalog`, `task.result`, and `task.review` share those operations through one owner. `task.catalog` is a bounded snapshot of currently loaded model identities; it does not grant entitlement or silently choose a model. Result and review calls use the authenticated parent session, child ownership check, request-key idempotency and optimistic revision path. Mutation request keys persist the original envelope and optimistic revision; equal retries return the original receipt, conflicting retries fail. Caller authority derives from the authenticated session and mutations/read queries can address only that coordinator's children. Result/evidence submission is explicit; provider completion text is not fabricated into a verified result.

Session-specific loopback HTTP endpoints accept authenticated JSON-response MCP POSTs. Initialize uses protocol `2025-03-26`; tools/list and tools/call use the same descriptor source as Codex dynamic tools. Initialized notification returns HTTP 202; no SSE is advertised. Tokens and endpoint bindings are session-owned, bounded and removed after shutdown. Codex pollTool/respondTool invokes the same durable owner path.

Schema 3 adds task packets, usage, result/review and bridge request identities. Migration from schema 1/2 preserves existing conversation/event identities. Runtime upstream block/event mappings remain transactional; duplicate observations require equal digests. Pending tool action refinement invalidates pending approvals; resolved authority is immutable.

An approval with no provider expiry remains explicitly session-bound, not immortal: admission requires the same live Host epoch, pending permission identity/action digest and a run still awaiting approval. An actual supplied expiry is enforced. Recovery invalidates pending approvals; terminal/ambiguous run state cannot grant them. No upstream expiry or local execution authority is fabricated from a missing timestamp.

## Workspace and evidence boundaries

Workspace registration captures real canonical filesystem identity plus Git common directory, checkout directory, branch and base revision. Dispatch rechecks the recorded binding before open/start/message so a changed checkout cannot silently receive work. Task packets require finite request/time/token budgets, explicit owned paths, acceptance and result location. The app owns task lifetimes rather than replaceable presentation/configuration.

Token budgets apply only to cumulative usage counters actually observed from the adapter. Current native Codex/OpenCode adapters do not provide usage observations; the view's “observed tokens 0” is not proof of zero consumption or zero billing. Finite request and elapsed-time limits still apply independently. Missing upstream usage is never synthesized into charge accounting.

Tests and installed-provider receipts establish only their recorded scenarios. No live Codex parent-child claim is justified without isolated ChatGPT authentication; installation, discovery or a handshake alone is not orchestration evidence.
