# 012: Bounded orchestration recovery and GUI CLI checkpoint

Status: review; implementation checkpoint, not native/provider acceptance.
Owner/Git owner: implementation worker in private worktree
`/home/ashman/.t3/worktrees/spica/t3-475f907b`, branch
`t3/orchestration-recovery-gui-cli`, committed base
`da08f3745eb4d419d96d09eae530f9162ccfd6f8`. No descendants.

Audited delegate/send/wait/cancel/list/catalog/result/review. Existing authenticated
factory tests cover the public bridges, exact selections, message retries/budget,
targeted cancellation, result/review and reopen. New checks reject ignored
cross-method fields before key reservation; prove byte-identical delegation
receipt replay after disk reopen with a claimed child open left unknown; and
select the newest coordinator turn deterministically. Explicit task references
retain original-parent authority within the same session. Keys remain
session-scoped; new work requires a new key. No ambiguous effects are retried.

Owned changes: `src/orchestration_tools.zig`, orchestration tests in
`src/domain/domain_test.zig`, the narrow `Owner.toolCall` seam in `src/domain.zig`
(plus its required formatter corrections), and `src/runtime/fake.zig`'s
compile-blocking shadowed capture rename. No `src/app.zig` changes.

`tools/spica-ui` now shares ordinary-input helpers, preserves action journals and
the private compositor across restart, waits on exact Send command/run/receipt
fields, and uses disposable workspaces. Scenarios include `second-turn`,
`oversized-send` (`rejected-send` alias), `workspace-diff`, `capability-refusal`,
`followup-refusal`, and `question-refusal`. Refusals are explicitly driver-level
unavailable-target checks; fake second turns do not prove upstream context.

Validation: seven focused orchestration tests pass in Debug and ReleaseSafe,
including the existing public factory/MCP result/review path. Fourteen offline
CLI tests pass; format and diff checks pass. Focused commands and raw Zig logs
are in ignored `.artifacts/orchestration-recovery-gui-cli/`; the final checkpoint
SHA and source fingerprint are recorded in its `task-ledger.json` before handoff.

Limitations: `./tools/check` stops at unchanged `src/app.zig:425`, referencing
absent `View.model_search_focused`. Native GUI scenarios/screenshots remain
unexecuted. The ordinary `test-domain` target omits libunibreak; focused checks
link the existing local library explicitly. The broader explicitly linked domain
run passed 50/54, with four session/factory failures outside the changed bridge
paths. No inference, credentials/history access, installation or performance
acceptance was attempted. `vd preflight` passed; no desktop session was started.
