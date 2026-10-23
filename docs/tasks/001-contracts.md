# 001: Core contracts and reference scenarios

Status: ready
Owner: Astra selects one Sol worker; Astra reviews decisions before dependents begin.
Base: current accepted bootstrap commit (record exact SHA before dispatch).
Owned paths: proposed docs/contracts/ and src/domain/ only; agree concrete files before dispatch. Do not edit renderer/build/runtime integration in parallel without ownership allocation.
Dependencies: bootstrap accepted.

Scope:
- Pin the chosen T3 reference revision and behavior scenarios, without copying private data or assuming source licensing.
- Define stable project/thread/run/message IDs, revisioned commands/events and provider capabilities.
- Define persistence/effect/approval/cancel/crash ownership and workspace identity. Completion receipt distinguishes accepted intent from completed effect.
- Agree minimal fake adapter and UI query/subscription seams so two workers can implement against the same contract.

Acceptance:
- One readable contract and state transition table covers create/send/stream/tool approval/cancel/reopen and ambiguous effect recovery.
- Define duplicate command, stale mutation and pagination invalidation behavior.
- Propose the smallest meaningful contract regression scenarios and implement only what this task owns.
- Astra inspects source/diff and approves or returns specific interface changes before dependent implementation.

Attempts: none.
Result/evidence: pending.
