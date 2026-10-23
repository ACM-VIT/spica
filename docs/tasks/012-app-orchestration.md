# 012: App-owned coordinator/worker execution

Status: blocked — prerequisite feature gates are not implemented; do not dispatch yet.
Owner: Sol domain/runtime worker with separately owned adapter/UI work; Astra reviews state/effect ownership.
Base/owned paths: record accepted base and exact owners before dispatch.
Dependencies: contracts 001 and fake scenarios 003; Codex 007, background runs 009 and workspace/Git identity 011 for the first live gate. Mixed-runtime acceptance also requires OpenCode 008. Do not dispatch from numeric priority alone.

Scope: implement the bounded orchestration contract in docs/PROVIDERS_AND_ORCHESTRATION.md: app-managed task tree, delegate/send/wait/cancel/list, durable IDs/dispatch, real coordinator tool bridge, explicit runtime/model/effort/account/workspace, result/evidence handoff and review disposition. Keep provider-native children distinguishable. Expose state/actions through public primitives, independent of the UI.

Acceptance: fake-only duplicate/out-of-order/failure/approval/cancel/budget/crash scenarios first; Codex-only parent/child workflow next; then one coordinator dispatching to Codex and OpenCode. Verify no duplicate external work after ambiguous restarts, no wrong-checkout writes, no intentional model substitution, finite concurrency and parent/child cancellation policy. Usage accounts for the complete observable tree without duplicate notifications. Reconfigure/reload the view while work survives. Inspect actual UI evidence and candidate changes.

No universal automation language, timer runner, extra providers or automatic publication in this task.
Attempts/result/evidence: none; future task packet.
