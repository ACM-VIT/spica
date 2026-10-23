# 001: Core contracts and reference scenarios

Status: ready
Owner: Astra selects one Sol worker; Astra reviews decisions before dependents begin.
Base: current accepted bootstrap commit (record exact SHA before dispatch).
Owned paths: proposed docs/contracts/ and src/domain/ only; agree concrete files before dispatch. Do not edit renderer/build/runtime integration in parallel without ownership allocation.
Dependencies: bootstrap accepted.

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

Attempts: none.
Result/evidence: pending.
