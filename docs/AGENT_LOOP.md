# Development with OMP

Run `./tools/agents`: Astra (`gpt-6-astra`, high thinking) coordinates and reviews; Sol workers implement, investigate, measure and repair. Fresh startup authorizes only [001-contracts](tasks/001-contracts.md), through review and checkpoint, then stops. An additional user message overrides or steers that scope. Read root AGENTS.md, architecture/roadmap and the current task record. The roadmap is dependency context, not authorization to start every task.

`./tools/agents "Focus task 001 on reference scenarios"` adds your message. `--continue`, `--resume [id]`, `--restore [id]`, `--session`, `--fork` and foreign-session imports inject no startup text. `--help` is offline. The launcher uses this checkout as cwd and existing global accounts/environment; it adds no profile, approval override, scheduler or restart loop.

## Roles and budgets

Astra owns decomposition, contracts, dependencies, decisions, shared ledger index and acceptance. Delegate all implementation, scouting, checks, interaction, measurement, repair and mechanical integration to project Sol agents: `task` (medium), `sol-measure` (medium), `sol-repair` (high). No alternative worker models or advisors. Inspect actual resolved identity; cancel a non-Sol worker and record the mismatch.

`task.maxRecursionDepth: -1` permits unlimited delegation depth, not unlimited parallelism. Each project worker definition must explicitly include the `task` tool and a `spawns` allowlist containing only `task`, `sol-measure` and `sol-repair`. Do not bypass the native same-type self-recursion guard; delegate to another allowed Sol type when necessary.

Default aggregate active concurrency is two when no independent third lane exists; the ceiling is three Sol workers across the entire tree, INCLUDING waiting parents. OMP `task.maxConcurrency: 3` is session-scoped, not a proven tree-global guarantee. Astra reserves slots before dispatch and passes explicit reservations in packets; children may delegate only within those pre-reserved slots, never independently fan out. Descendant scopes must be subsets of the delegating worker's owned paths; divide ownership to avoid concurrent writers. Shared Git ownership is not inherited: only Astra's explicitly designated single Git owner may mutate Git. Return child completion/evidence to its parent for propagation to Astra; release slots only when workers finish or are cancelled.

Ownership and dependencies, not available slots, determine dispatch. Each worker has a 30-minute hard limit and 40-request soft budget, forced yield at 60 requests; packets may be smaller. Explicit thinking avoids classification calls; worker tier is `default`. Prewalk, advisors, speculation, completion probes, warming, autolearn and automatic continuations are disabled; the launcher disables titles. Retries, compaction and global extensions can still add requests: these are not exact cost caps. Never add paid background loops or setup-test inference except an explicitly user-requested live delegation smoke.

## Ownership and integration

Before dispatch record branch, base HEAD, dirty paths and owners. Shared checkout is default; ownership is not filesystem isolation. Assign disjoint source, receipt and artifact paths; one writer owns each interface and shared output. Freeze each evaluated candidate, not unrelated source work. Large correctness evaluations may run asynchronously on a pinned committed candidate in an assigned private worktree while independent development continues. Acceptance and dependent gates wait for required evidence; verified slices can checkpoint without waiting for unrelated larger evaluations. Performance sampling is exclusive versus builds, recordings and profilers, but not source edits or review.

Make frequent small, descriptive checkpoint commits throughout implementation and repair, after each cohesive working slice and its relevant checks. Do not wait for the whole task/milestone or Astra's final review. Keep implementation, tests and related docs together; preserve separate follow-up fix commits. No arbitrary commit quota, padding, automatic amend/squash or known-broken checkpoints. Committing is not acceptance.

Task packets assign exactly one active Sol Git owner in a shared checkout and an exact path allowlist. Before each checkpoint verify branch/HEAD, a clean index before targeted staging, and the exact staged diff; stop on unrelated staged changes or candidate drift. Freeze owned candidate files during their checks/commit; other workers may edit disjoint paths but cannot mutate Git. Transfer Git ownership explicitly for another worker's checkpoint. Without that role, return a verified slice for serialized handoff. An assigned private worktree permits direct commits of owned slices. Local checkpoints use existing task authorization, without fresh permission. Never broadly stage, include others' unfinished files, push, switch branches, stash, reset or prune. Final integration is serialized with all writers stopped and the full candidate reviewed.

Worktrees start from a recorded committed base; uncommitted work is not inherited by our workflow. Consult the reference before isolation: OMP can capture dirty snapshots and branch integration can stash/commit. Keep automatic apply disabled.

## Packets, repair and review

Use `docs/tasks/README.md` and real records such as `docs/tasks/001-contracts.md`. States: `ready`, `running`, `review`, `accepted`, `blocked`; optionally record `repair` rounds. Reconcile existing children and checkout on resume to avoid duplicates. Before dispatch record outcome, authorized scope, dependencies, owned paths, immutable interfaces, base/branch/candidate identity, acceptance scenarios/checks, budget, attempts, commit checkpoints/Git owner, parent and reserved slots (including any descendant allowance), and receipt/manifest paths.

Minimal OMP batch syntax (example only):

```json
{
  "context": "Shared checkout; Contracts001 is the sole Git owner for its assigned paths. Checkpoint verified slices under docs/AGENT_LOOP.md.",
  "tasks": [{
    "name": "Contracts001",
    "agent": "task",
    "task": "Complete docs/tasks/001-contracts.md within its assigned paths and budget; yield a receipt.",
    "solutionSpace": "Contracts and reference scenarios only; follow the packet's fixed boundaries."
  }]
}
```

Model settings belong in agent/config definitions, not task JSON. Retain agent/job IDs; let results arrive asynchronously. Findings identify the exact candidate SHA, reproduction command and raw evidence. Keep same-candidate repairs with the existing owner when practical; assign an isolated repair candidate and explicit ownership to a high-thinking `sol-repair` worker when needed. Escalate after three substantive failed repairs, repeated identical failure, invalid evidence, changed contracts/ownership/scope or exhausted budget. Never weaken acceptance.

Yield a 100–250 word receipt, with raw evidence on disk:

```text
001-contracts; status: review (or blocked)
Base/head and checkpoint SHAs; branch; remaining diff/new-file hashes
Changed paths/behavior; exact checks and results; evidence manifest
Findings/limitations; repair count; elapsed time; available usage
Requested/actual model, thinking, tier; agent/job IDs (unknown if unavailable)
```

Astra reads the actual diff, surrounding source, tests and raw evidence, including error/cleanup paths and rendered interactions. Sol repairs precise findings; Astra rechecks unresolved objections and the tested candidate. Accepted requires reviewed evidence and affected integration checks. Update checkpoint with candidate, owners, findings, remaining budget and next eligible task; stop at the authorized boundary.

## Evidence and runtime limits

Use private `virtual-desktop` / `vd` for actual app screenshots and input checks; keep generated evidence in ignored `.artifacts/`, with candidate, command/build mode, scenarios and limitations. Screenshots/present duration do not measure physical latency. Never include private histories or credentials.

Validated offline against installed OMP v18.10.4 docs/settings; available source is v17.4.0. Sol pinning does not prevent credential/extension fallback before a first request. Headless OMP children internally force `tools.approvalMode: yolo`; prompts do not sandbox tools. No live provider, account, v18 task, worktree or GUI behavior is established by setup checks. Consult [OMP_REFERENCE.md](OMP_REFERENCE.md) only for extended syntax, lifecycle, isolation, provenance, model/approval limitations and offline verification details.
