# Native rewrite audit and recovery plan — 2026-10-26

Status: planning complete; documentation reviewed for local checkpoint. User
requests a grounded approach, implementation checklist,
misalignments, investigation of unsuccessful Send, and a CLI for GUI interaction.
This task produces a plan; it does not authorize claiming the reported failure
fixed or the remaining application implemented.

Base: `5bbdd5f`, branch `rewrite/native-agent-workspace`, initially clean index and
worktree. Reference: local T3 `eb1510d2493cbf28600432d5193cc22a1af8f3d8`.
Parent Astra owns decisions and documentation draft/review. Two T3-owned
Codex/gpt-6.1-sol workers, medium/default, audit read-only with no descendants:

- `native-rewrite-plan-20261026-send-audit`: prompt path, admission/provider
  failures and evidence; owns only ignored `.artifacts/rewrite-plan/send-audit.md`.
- `native-rewrite-plan-20261026-parity-audit`: local reference, native feature
  gaps and GUI automation; owns only ignored `.artifacts/rewrite-plan/parity-audit.md`.

Both task IDs use prefix
`node:delegated-task:command%3Amcp%3Acd3ef5ca-3ed3-4df0-835a-4ef8a74c41fb%3Adelegate-task%3A`
followed by the names above. Resolved identities match the packets. Neither
worker initially owns Git. A final Sol documentation checkpoint owner will be
designated with an exact allowlist after review; no concurrent Git writers.

Acceptance: inspect actual source and pinned reference; distinguish historical
evidence from current reproduction; deliver ordered, dependency-aware checklist
with observable gates and proposed CLI contract; reconcile stale roadmap claims.
No new provider inference, account/history access, installation, push, benchmark
or native UI mutation is needed for this documentation task. No runtime checks
or live failure reproduction may be claimed from this audit.

Both audit workers completed. Parent inspected their reports and the actual
Host admission, native readiness/receipt, adapter session methods, automation
schema and evaluator code. Source confirms fresh sessions for ordinary sends
and the composer/start-frame size mismatch. The user clarified Codex; no symptom
or diagnostic was provided, so the incident remains undiagnosed. Current
orchestration result/review/catalog source supersedes older deferred wording;
the plan explicitly preserves that distinction.

Deliverable: `docs/NATIVE_REWRITE_PLAN.md`, with six phased checklists, native
ownership boundaries, missing/partial workflows, proposed GUI CLI semantics and
acceptance discipline. README/ROADMAP/task index link the plan; ROADMAP and
architecture correct stale blanket-pending, Lua-selection and account defaults.
No product code changed. Draft ownership freezes for Sol final documentation
review/checkpoint with allowlist: README.md, docs/ROADMAP.md,
docs/ARCHITECTURE.md, docs/NATIVE_REWRITE_PLAN.md, docs/tasks/README.md,
docs/tasks/013-native-rewrite-plan.md. No other worker may mutate Git.

Final documentation checkpoint ownership: sole active Sol, no descendants, exact
six-path allowlist above. Verified branch `rewrite/native-agent-workspace`, base
HEAD `5bbdd5ff605883ac8047217434c6eb585bfaa80f` and empty index before review;
the six candidate paths were the only working-tree changes. Reviewed the actual
candidate, both ignored source audits, current Host/session admission, adapter
create/start calls, composer/frame accounting, startup defaults and orchestration
tool definitions. Verified the pinned local T3 reference HEAD. Corrected wording
to distinguish session creation from prompt submission and selected-runtime
account access from credential copying; retained the newer `d6b5c5e`
result/review/catalog implementation distinction.

Documentation validation: all 20 relative Markdown links in the six-file
candidate resolve; whitespace checks cover tracked changes and both new files.
Exact-path staged review confirmed only the six allowed documentation paths,
with no staged whitespace errors, for the single local checkpoint,
`docs: record native rewrite completion plan and source audit`. That commit
contains this ledger and identifies the checkpoint; its SHA is returned in the
handoff receipt. No product code, runtime checks, GUI, builds, accounts, histories,
inference, installs or push. Planning is complete; implementation checkboxes and
live Codex failure diagnosis/acceptance remain open.
