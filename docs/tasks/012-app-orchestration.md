# 012: App-owned coordinator/worker execution

Status: running — user explicitly requested production orchestration alongside Codex/OpenCode after the reviewed automated fake/native milestone.
Owner: OrchestratorShip012 owns domain/runtime orchestration, shared adapter vocabulary and native task presentation; CodexShip007 owns transport/build and serialized shared integration.
Base: `301e8e35899f9c1aeb2005b220e72c55c9fa178f`. Own `src/domain.zig`, `src/domain/*`, `src/contract.zig`, new `src/orchestration*`, `src/app.zig`, `src/ui/coding.zig`, native task-tree modules, this task record and orchestration contracts.
Dependencies: implement the minimum real background-run and workspace-identity prerequisites from roadmap009/011 within this lane before live orchestration acceptance. Fake-only durability first, Codex-only next, mixed Codex/OpenCode after both concrete adapters; no unsupported delegation claims.

Scope: implement the bounded orchestration contract in docs/PROVIDERS_AND_ORCHESTRATION.md: app-managed task tree, delegate/send/wait/cancel/list, durable IDs/dispatch, real coordinator tool bridge, explicit runtime/model/effort/account/workspace, result/evidence handoff and review disposition. Keep provider-native children distinguishable. Expose state/actions through public primitives, independent of the UI.

Acceptance: fake-only duplicate/out-of-order/failure/approval/cancel/budget/crash scenarios first; Codex-only parent/child workflow next; then one coordinator dispatching to Codex and OpenCode. Verify no duplicate external work after ambiguous restarts, no wrong-checkout writes, no intentional model substitution, finite concurrency and parent/child cancellation policy. Usage accounts for the complete observable tree without duplicate notifications. Reconfigure/reload the view while work survives. Inspect actual UI evidence and candidate changes.

No universal automation language, timer runner, extra providers or automatic publication in this task.
Attempts/result/evidence: bounded registry/task/HTTP/native implementation is checkpointed below; Astra retains acceptance.

Current continuation: RuntimeFactoryLead.DomainRegistryFinish owns reserved
slot1 in the existing private012 worktree, preserving the predecessor's frozen
dirty source at base `368481b`. RuntimeFactoryLead retains sole shared Git
integration; native/provider consumer is reserved slot3. Original domain owner
froze the source explicitly before transfer. User-authorized finite budgets:
60 minutes, 200 requests soft, 300 forced; private project configuration must
match before replacement dispatch. Factory ABI `04e7cb7` and concrete native
factory `9a1d025` are shared prerequisites, not task-tree acceptance.

Recovered private checkpoints `9a822cc`, `b888373`, `12b7475`, `00a8ed6`,
`236a6e2` are integrated by the sole shared Git owner. Fake and native providers
use the same three-entry registry; committed opens wait for handshake at most
15 seconds and are dispatched once. Failure/recovery never replays ambiguous
work. Endpoint authentication and immutable request-key envelopes bind tools to
their actual parent session; explicit results/reviews remain public commands.

Real loopback HTTP/dynamic callback tests cover auth failure, valid initialize/
list/call, deduplicated delegate/send, bounded requests, cancellation before
open, partial-create unknown, independent three-instance pumping, results and
reopen. Temporary Git/linked-worktree cases cover real filesystem/repository/
checkout identity, cross-coordinator owned-path conflicts, shared Git metadata
and symlink escapes. Focused domain suite passed 29/29 in Debug and ReleaseSafe.

Native task rows use public queries, retain exact cancel revisions, and show
persisted result summaries. Actual installed OpenCode Host4 task/result was
rendered, survived custom-root F5 reload/F9 restore without a provider restart;
the reopened deterministic two-child fixture's first pointer cancellation
became unknown while the second stayed interrupted (not live-cancel proof).
Raw checks/screenshots/ownership receipt:
`.artifacts/worktrees/012-orchestration/.artifacts/orchestration012/domain-finish.txt`.
Authenticated Codex inference and mixed live Codex/OpenCode delegation still
require the user's supported isolated ChatGPT sign-in/entitlement.
