# Development with OMP

Run `./tools/agents`: Astra (`gpt-6-astra`, high thinking) coordinates and reviews; Sol workers implement, investigate, measure and repair. Fresh startup authorizes only [001-contracts](tasks/001-contracts.md), through review and checkpoint, then stops. An additional user message overrides or steers that scope. Read root AGENTS.md, architecture/roadmap and the current task record. The roadmap is dependency context, not authorization to start every task.

`./tools/agents "Focus task 001 on reference scenarios"` adds your message. `--continue`, `--resume [id]`, `--restore [id]`, `--session`, `--fork` and foreign-session imports inject no startup text. `--help` is offline. The launcher uses this checkout as cwd and existing global accounts/environment; it adds no profile, approval override, scheduler or restart loop.

## Roles and budgets

Astra owns decomposition, contracts, dependencies, decisions, shared ledger index and acceptance. Delegate all implementation, scouting, checks, interaction, measurement, repair and mechanical integration to project Sol agents: `task` (medium), `sol-measure` (medium), `sol-repair` (high). No alternative worker models, advisors or grandchildren. Inspect actual resolved identity; cancel a non-Sol worker and record the mismatch.

Default concurrency is two; raise project configuration to three only for independent ownership. Each worker has a 30-minute hard limit and 40-request soft budget, forced yield at 60 requests; packets may be smaller. Explicit thinking avoids classification calls; worker tier is `default`. Prewalk, advisors, speculation, completion probes, warming, autolearn and automatic continuations are disabled; the launcher disables titles. Retries, compaction and global extensions can still add requests: these are not exact cost caps. Never add paid background loops or setup-test inference.

## Ownership and integration

Before dispatch record branch, base HEAD, dirty paths and owners. Shared checkout is default; ownership is not filesystem isolation. Assign disjoint source, receipt and artifact paths; one writer owns each interface and shared output. Freeze candidates during review/measurement; serialize benchmarks after competing builds stop.

Ordinary workers never stage, commit, switch branches, stash, reset, prune or edit outside ownership. There is ONE exception: Astra may explicitly assign a sole Sol `task` worker an integration packet after every other worker is quiescent and Astra has reviewed the frozen candidate. Record exact owned paths, base SHA, branch, candidate diff/new-file hashes, reviewed findings and affected checks. That packet permits only targeted staging of those paths, a local commit and affected checks within the existing user-authorized feature/milestone. Verify the index contains only owned paths; stop on unrelated staged changes or candidate drift. No push, branch switching, reset, stash or destructive operation is permitted. This exception grants no further implementation scope. Routine local commits/worktree creation within already authorized feature work need no fresh permission.

Worktrees start from a recorded committed base; uncommitted work is not inherited by our workflow. Consult the reference before isolation: OMP can capture dirty snapshots and branch integration can stash/commit. Keep automatic apply disabled.

## Packets, repair and review

Use `docs/tasks/README.md` and real records such as `docs/tasks/001-contracts.md`. States: `ready`, `running`, `review`, `accepted`, `blocked`; optionally record `repair` rounds. Reconcile existing children and checkout on resume to avoid duplicates. Before dispatch record outcome, authorized scope, dependencies, owned paths, immutable interfaces, base/branch/candidate identity, acceptance scenarios/checks, budget, attempts and receipt/manifest paths.

Minimal OMP batch syntax (example only):

```json
{
  "context": "Shared checkout; ordinary worker, no Git mutations. Follow docs/AGENT_LOOP.md.",
  "tasks": [{
    "name": "Contracts001",
    "agent": "task",
    "task": "Complete docs/tasks/001-contracts.md within its assigned paths and budget; yield a receipt.",
    "solutionSpace": "Contracts and reference scenarios only; follow the packet's fixed boundaries."
  }]
}
```

Model settings belong in agent/config definitions, not task JSON. Retain agent/job IDs; let results arrive asynchronously. Keep same-candidate repairs with the existing worker. Escalate after three substantive failed repairs, repeated identical failure, invalid evidence, changed contracts/ownership/scope or exhausted budget. Never weaken acceptance.

Yield a 100–250 word receipt, with raw evidence on disk:

```text
001-contracts; status: review (or blocked)
Base SHA; branch; focused diff SHA-256 and new-file hashes
Changed paths/behavior; exact checks and results; evidence manifest
Findings/limitations; repair count; elapsed time; available usage
Requested/actual model, thinking, tier; agent/job IDs (unknown if unavailable)
```

Astra reads the actual diff, surrounding source, tests and raw evidence, including error/cleanup paths and rendered interactions. Sol repairs precise findings; Astra rechecks unresolved objections and the tested candidate. Accepted requires reviewed evidence and affected integration checks. Update checkpoint with candidate, owners, findings, remaining budget and next eligible task; stop at the authorized boundary.

## Evidence and runtime limits

Use private `virtual-desktop` / `vd` for actual app screenshots and input checks; keep generated evidence in ignored `.artifacts/`, with candidate, command/build mode, scenarios and limitations. Screenshots/present duration do not measure physical latency. Never include private histories or credentials.

Validated offline against installed OMP v18.10.4 docs/settings; available source is v17.4.0. Sol pinning does not prevent credential/extension fallback before a first request. Headless OMP children internally force `tools.approvalMode: yolo`; prompts do not sandbox tools. No live provider, account, v18 task, worktree or GUI behavior is established by setup checks. Consult [OMP_REFERENCE.md](OMP_REFERENCE.md) only for extended syntax, lifecycle, isolation, provenance, model/approval limitations and offline verification details.
