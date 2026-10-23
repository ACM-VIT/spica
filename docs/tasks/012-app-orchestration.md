# 012: App-owned coordinator/worker execution

Status: running — user explicitly requested production orchestration alongside Codex/OpenCode after the reviewed automated fake/native milestone.
Owner: OrchestratorShip012 owns domain/runtime orchestration, shared adapter vocabulary and native task presentation; CodexShip007 owns transport/build and serialized shared integration.
Base: `301e8e35899f9c1aeb2005b220e72c55c9fa178f`. Own `src/domain.zig`, `src/domain/*`, `src/contract.zig`, new `src/orchestration*`, `src/app.zig`, `src/ui/coding.zig`, native task-tree modules, this task record and orchestration contracts.
Dependencies: implement the minimum real background-run and workspace-identity prerequisites from roadmap009/011 within this lane before live orchestration acceptance. Fake-only durability first, Codex-only next, mixed Codex/OpenCode after both concrete adapters; no unsupported delegation claims.

Scope: implement the bounded orchestration contract in docs/PROVIDERS_AND_ORCHESTRATION.md: app-managed task tree, delegate/send/wait/cancel/list, durable IDs/dispatch, real coordinator tool bridge, explicit runtime/model/effort/account/workspace, result/evidence handoff and review disposition. Keep provider-native children distinguishable. Expose state/actions through public primitives, independent of the UI.

Acceptance: fake-only duplicate/out-of-order/failure/approval/cancel/budget/crash scenarios first; Codex-only parent/child workflow next; then one coordinator dispatching to Codex and OpenCode. Verify no duplicate external work after ambiguous restarts, no wrong-checkout writes, no intentional model substitution, finite concurrency and parent/child cancellation policy. Usage accounts for the complete observable tree without duplicate notifications. Reconfigure/reload the view while work survives. Inspect actual UI evidence and candidate changes.

No universal automation language, timer runner, extra providers or automatic publication in this task.
Attempts/result/evidence: none; future task packet.

Current continuation: RuntimeFactoryLead.DomainRegistryFinish owns reserved
slot1 in the existing private012 worktree, preserving the predecessor's frozen
dirty source at base `368481b`. RuntimeFactoryLead retains sole shared Git
integration; native/provider consumer is reserved slot3. Original domain owner
froze the source explicitly before transfer. User-authorized finite budgets:
60 minutes, 200 requests soft, 300 forced; private project configuration must
match before replacement dispatch. Factory ABI `04e7cb7` and concrete native
factory `9a1d025` are shared prerequisites, not task-tree acceptance.
