# Development with OMP

Run `./tools/agents`: Astra (`gpt-6-astra`, high thinking) owns consequential decisions and milestone review; the designated Sol integration lead owns routine decomposition, delegation and integration. Sol workers implement, investigate, measure and repair. Fresh startup authorizes only [001-contracts](tasks/001-contracts.md), through review and checkpoint, then stops unless later user direction expands scope. The current user-authorized shipping continuation covers the remaining roadmap; read its current ledger and true prerequisites. Read root AGENTS.md, architecture/roadmap and the current task record.

`./tools/agents "Focus task 001 on reference scenarios"` adds your message. `--continue`, `--resume [id]`, `--restore [id]`, `--session`, `--fork` and foreign-session imports inject no startup text. `--help` is offline. The launcher uses this checkout as cwd and existing global accounts/environment; it adds no profile, approval override, scheduler or restart loop.

## Roles and budgets

Astra retains consequential contract/scope decisions and milestone acceptance, reviewing actual source and evidence rather than routine compiler turns. The designated Sol integration lead owns routine decomposition, dependencies, delegation, integration and the current shared ledger, and may allocate or reassign free slots without fresh Astra authorization. Delegate implementation, scouting, checks, interaction, measurement, repair and mechanical integration only to project `gpt-6.1-sol` agents: `task` (medium), `sol-measure` (medium), `sol-repair` (high). No alternative worker models, inherited-model selection, fallback or advisors. Inspect actual resolved identity; stop/cancel a non-Sol worker and record the mismatch.

`task.maxRecursionDepth: -1` permits unlimited delegation depth, not unlimited parallelism. Each project worker definition must explicitly include the `task` tool and a `spawns` allowlist containing only `task`, `sol-measure` and `sol-repair`. Do not bypass the native same-type self-recursion guard; delegate to another allowed Sol type when necessary.

Default aggregate active concurrency is two when no independent third lane exists; the ceiling is three Sol workers across the entire tree, INCLUDING the integration lead and waiting parents. OMP `task.maxConcurrency: 3` is session-scoped, not a proven tree-global guarantee. Before every spawn the lead inspects registered worker state and existing jobs, reconciles ownership to prevent duplicates, and reserves free slots explicitly in packets. Descendants may use only inherited reserved slots and scopes/owned paths that are subsets of the parent's delegation; never independently fan out. The lead may reassign slots only after prior workers finish or are cancelled. Assign one writer per interface/output. Shared Git ownership is never inherited: retain exactly one explicitly designated shared Git/integration owner. Return child completion/evidence through its parent.

Ownership and dependencies, not available slots, determine dispatch. Each worker has a 60-minute hard limit and 200-request soft budget, forced yield at 300 requests; packets may be smaller. These finite limits were explicitly raised by the user for the current shipping loop; existing private worktrees must receive the authorized project configuration before replacement dispatch. Explicit thinking avoids classification calls; worker tier is `default`. Prewalk, advisors, speculation, completion probes, warming, autolearn and automatic continuations are disabled; the launcher disables titles. Retries, compaction and global extensions can still add requests: these are not exact cost caps. Never add paid background loops or setup-test inference except an explicitly user-requested live delegation smoke.

## Ownership and integration

Every independent feature gets a named branch and exclusive private worktree from a recorded committed base; future fresh branches start at the latest reviewed integration. Before dispatch record branch, base HEAD, dirty paths and owners. Private isolation does not transfer shared ownership: assign disjoint source, receipt and artifact paths, with one writer per interface/shared output. Freeze each evaluated candidate, not unrelated source work. Large correctness evaluations may run asynchronously on a pinned committed candidate while independent development continues. Acceptance and dependent gates wait for required evidence; verified slices can checkpoint without waiting for unrelated larger evaluations. Performance sampling is exclusive versus builds, recordings and profilers, but not source edits or review.

Make frequent small, descriptive checkpoint commits throughout implementation and repair, after each cohesive working slice and its relevant checks. Do not wait for the whole task/milestone or Astra's final review. Keep implementation, tests and related docs together; preserve separate follow-up fix commits. No arbitrary commit quota, padding, automatic amend/squash or known-broken checkpoints. Committing is not acceptance.

Task packets assign exactly one active Sol Git owner in a shared checkout and an exact path allowlist. Before each checkpoint verify branch/HEAD, a clean index before targeted staging, and the exact staged diff; stop on unrelated staged changes or candidate drift. Freeze owned candidate files during their checks/commit; other workers may edit disjoint paths but cannot mutate Git. Transfer Git ownership explicitly for another worker's checkpoint. Without that role, return a verified slice for serialized handoff. An assigned private worktree permits direct commits of owned slices. Local checkpoints use existing task authorization, without fresh permission. Never broadly stage, include others' unfinished files, push, switch branches, stash, reset or prune. Final integration is serialized with the integrating feature's writers stopped and the full integration candidate frozen/reviewed; unrelated private feature work may continue.

Worktrees inherit only their recorded committed base, not uncommitted work. Keep OMP automatic apply disabled. After source/evidence review and stopped feature writers, the sole shared Git/integration lead integrates each completed future feature with `git merge --no-ff <feature-branch>` into `rewrite/native-agent-workspace`, using a meaningful merge message. The user authorizes these local merges without fresh permission. The lead resolves conflicts, runs combined checks and actual changed-path smoke, and records the integration commit. Preserve the existing cherry-picked historical tail as-is: do not reconstruct old history or merge already-landed old branches merely to manufacture a graph. No push, reset, stash, history rewrite or branch switching.

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

Astra reads the actual diff, surrounding source, tests and raw evidence, including error/cleanup paths and rendered interactions, for consequential decisions and milestone review. Sol owns routine review, compiler/test repair and integration; Astra rechecks unresolved material objections and the tested milestone candidate. Accepted requires reviewed evidence and affected integration checks. The lead updates the checkpoint/current table with candidate, owners, findings, remaining budget and next eligible task. After each verified integration continue the next eligible user-authorized roadmap feature, respecting real provider/auth/workspace prerequisites; absent Codex authentication does not block independent work such as task010 ownership-foundations 4–6. Escalate consequential decisions or exhausted/blocked packets, not routine compiler turns. No unattended scheduler or restart loop.

## Evidence and runtime limits

Use private `virtual-desktop` / `vd` for actual app screenshots and input checks; keep generated evidence in ignored `.artifacts/`, with candidate, command/build mode, scenarios and limitations. Screenshots/present duration do not measure physical latency. Never include private histories or credentials.

Validated offline against installed OMP v18.10.4 docs/settings; available source is v17.4.0. Sol pinning does not prevent credential/extension fallback before a first request. Headless OMP children internally force `tools.approvalMode: yolo`; prompts do not sandbox tools. No live provider, account, v18 task, worktree or GUI behavior is established by setup checks. Consult [OMP_REFERENCE.md](OMP_REFERENCE.md) only for extended syntax, lifecycle, isolation, provenance, model/approval limitations and offline verification details.
