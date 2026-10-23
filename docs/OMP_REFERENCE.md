# OMP extended reference

Read [AGENT_LOOP.md](AGENT_LOOP.md) for ordinary operation. Consult this reference only for syntax, isolation, provenance or runtime limitations.

Run `./tools/agents` from this checkout. It starts the installed OMP with
`gpt-6-astra` at `high` thinking for coordination/review and loads the compact
[coordinator policy](../.omp/coordinator.md). A fresh session attaches
[the startup brief](../.omp/start.md) to the first user message. Its default scope is only task 001 contracts/reference scenarios through review/checkpoint, then stop; an additional user message overrides or steers that scope. For example:

```sh
./tools/agents
./tools/agents "Work on task 001 contracts"
./tools/agents --continue
./tools/agents --resume SESSION_ID
./tools/agents --resume                 # OMP's picker
./tools/agents --restore SESSION_ID     # explicit interrupted-work recovery
./tools/agents --help                   # offline, does not start OMP
```

`--continue`, `-c`, `--resume`, `-r`, `--session`, `--restore`, `--fork` and
foreign-session imports pass through without adding startup text. Other flags
and messages pass through unchanged; flags after `--` are literal messages.
The coordinator policy is applied on resumed runs too. Project `autoResume`
is false, so an ordinary launch is fresh. There is no launcher restart loop,
scheduler, `--goal`, approval flag or profile selection. Explicit extra OMP flags
can change the run; they are not an enforcement boundary.

The launcher changes cwd to its own checkout root so `.omp/config.yml` is found.
It uses the existing default environment and global OMP accounts, including
multiaccount routing; it does not write global settings, replace account pools,
set credential variables or create a profile. Existing `OMP_PROFILE`, `PI_PROFILE`
or `PI_CODING_AGENT_DIR` environment choices still apply: the launcher does not
hide them or invent an account configuration. Model IDs are exact bare selectors
(`gpt-6-astra`, `gpt-6.1-sol`); OMP selects their concrete provider using its existing
catalog/preferences. No provider/account availability has been verified by a
model request.

## Roles and bounds

Astra owns architecture, decomposition, contracts, dependencies, risk decisions,
source/diff/evidence review and acceptance. Delegate **all** implementation,
scouting, tests, interaction checks, measurements, repairs and mechanical
integration to these project agents:

| Agent | Purpose | Explicit model | Thinking |
| --- | --- | --- | --- |
| `task` | Implementation and mechanical integration; default task agent | `gpt-6.1-sol` | `medium` |
| `sol-measure` | Investigation, interaction and performance evidence | `gpt-6.1-sol` | `medium` |
| `sol-repair` | Difficult repair of concrete findings | `gpt-6.1-sol` | `high` |

Definitions live in `.omp/agents/*.md`. YAML frontmatter uses `name`,
`description`, `model`, `thinking-level`, `tools`, `prewalk`, `advisor`; the required
identity fields are strings. OMP normalizes kebab-case keys. Each agent pins Sol
in both frontmatter and project `task.agentModelOverrides`, which takes precedence
over frontmatter. The project `task` definition overrides the bundled default.
Do not put `model`, T3 `target.options`, `clientRequestId` or `isolation:"worktree"`
in task JSON. Provider/model options and T3 backing-thread APIs are not OMP task
fields. Astra is the main CLI session, not a child agent frontmatter trick.

Two workers may run concurrently. Raise `.omp/config.yml`'s
`task.maxConcurrency` to three only after confirming independent ownership and
cheap integration; do not exceed three in this workflow. All three worker types
share that pool. `task.maxRecursionDepth: 1` prevents grandchildren. Each run has
a 30-minute hard runtime and 40-request soft budget, with forced yield at 1.5 times
the request budget. Each packet may set a smaller working budget. The three failed
repair policy below is a workflow rule, separate from OMP's missing-yield reminders
and provider retries. Worker service tier is explicitly `default`, not Astra's tier.
Thinking is explicit rather than `auto`, avoiding task difficulty classifier calls.

Project settings also disable prewalk/advisors, speculative launch, completion
probes, cache warming, autolearn, automatic post-compaction continuation and goal
continuation modes. The launcher disables title generation. This bounds ordinary
work without promising an exact token/cost cap: provider retries, compaction or
global extensions may still make additional requests. Do not add `session_stop`
continuations or a scheduler. Stop at the current authorized milestone/batch,
acceptance, exhausted budget or a decision that needs the user.

## Shared checkout ownership

The default is **one shared checkout**, with `task.isolation.enabled: false`.
Before dispatch, establish branch, HEAD, dirty paths, current ledger and ownership.
Assign disjoint paths, including task artifacts, to each worker; freeze overlapping
interfaces and state owners until their current writer finishes. One coordinator
writes the shared task index. Workers write only their assigned receipt/manifests.
Path ownership is a coordination rule, not OS-enforced isolation.

Use the frequent-checkpoint policy in [AGENT_LOOP.md](AGENT_LOOP.md). Shared checkout packets assign exactly one active Sol Git owner and an exact path allowlist; other workers cannot mutate Git. Private assigned worktrees may commit owned slices directly. Check relevant behavior and the exact staged diff before each small local checkpoint, without waiting for final review. Record checkpoint SHAs and keep review fixes as follow-up commits. Checkpoints are not acceptance. Freeze candidate files during checks/commit and the full candidate during review/final integration. Never broadly stage or include another worker's unfinished changes; no push, branch switching, stash, reset, prune or edits outside ownership.

OMP supports isolation and `omp worktree add`; nothing here creates a worktree.
For an isolated task within the existing user-authorized scope, first make the intended source,
configuration and task contracts available in a **recorded committed
base**, then record that SHA in the packet. The assigned shared Git owner may make that local checkpoint under
the commit policy. Routine local commits and worktree creation
within authorized feature work need no fresh permission. Only then enable `task.isolation.enabled`, choose
`isolation.backend` (`rcopy` uses git worktrees when available), and use per-item
`isolated: true`. Keep `task.isolation.apply: false` until reviewed integration is
authorized. These settings are not T3's `isolation:"worktree"` option.

Unlike the T3 brief, OMP v18 documents capture of uncommitted snapshots (capped at
1 GiB per repository) and several copy/overlay backends. Do not assume dirty work
is absent, or that a backend always materializes just HEAD. The committed-base
requirement above is our reproducibility rule; verify the isolated candidate and
actual backend. Branch merge mode can commit/cherry-pick and temporarily stash
parent changes; its temporary stash behavior is excluded from the narrow integration exception
and is unsuitable for this shared dirty checkout.

## Durable ledger and task packets

Keep the ledger under `docs/tasks/`: `README.md` as the index, `<ID>.md` for the
packet/receipt/review history, and `<ID>/` for its evidence manifest and selected
logs/screenshots/traces (large generated artifacts may be referenced outside Git).
If the ledger is absent, Astra creates the index when beginning authorized work.
Do not invent accepted work or modify another owner's ledger while preparing setup. The first feature record is `docs/tasks/001-contracts.md`.
The index records ID, desired outcome, dependencies, state, assigned worker/runtime
ID, owned paths, candidate identity, budget and next action. States are
`ready`, `running`, `review`, `accepted`, `blocked`; optional `repair` records a repair round.

Before each dispatch, Astra writes a compact packet, usually 200-500 words:

```text
ID / observable outcome / user-authorized milestone:
Base SHA / branch / candidate dirty-diff identity:
Dependencies / owned source and artifact paths / interfaces that cannot change:
Relevant entrypoints and narrow context:
Required behavior and invariants / non-goals:
Acceptance scenarios / exact required checks / interaction evidence:
Working budget (<=30 minutes, <=40 requests) / repair attempts already used:
Receipt and evidence-manifest paths:
Stop/escalate conditions:
```

OMP v18's batch schema is `{ context, tasks: [...] }`. Each item includes `task`
and `solutionSpace` (how open-ended the design/cause is); `agent` and stable `name`
are optional but explicit here. Example shape, **not an instruction to launch**:

```json
{
  "context": "Spica shared checkout. Follow docs/AGENT_LOOP.md; Contracts001 is sole Git owner for its assigned paths; checkpoint verified slices. Read docs/tasks/001-contracts.md.",
  "tasks": [
    {
      "name": "Contracts001",
      "agent": "task",
      "task": "Complete docs/tasks/001-contracts.md within its ownership and budget. Return the required receipt/evidence, including failures.",
      "solutionSpace": "Design fixed in the packet; implementation details open."
    }
  ]
}
```

`effort` is absent because `task.enableEffort` is false; OMP's optional `lo|med|hi`
hints are relative to model support, not literal `medium|high`. `isolated` is absent
while isolation is disabled. `outputSchema` and `schemaMode` are optional per item;
use `outputSchema` (never legacy `schema`) if machine validation is needed. A text
receipt is sufficient by default. OMP's dynamically advertised schema is the runtime
authority when configuration changes.

Let OMP deliver background results. Retain the returned agent/job IDs in the
ledger; do useful independent coordination or `wait` when blocked rather than
polling. Read full `agent://<id>` output or `history://<id>` transcript when needed.
For same-candidate repair, message the owned existing worker with
`write {path:"agent://<id>", content:"original packet reference; findings; unresolved objections; new bounded repair scope"}`.
OMP can revive parked workers; this is different from T3's fresh delegated-round
rule. Never restart a budget-exhausted worker indefinitely. A fresh worker gets the
original packet, current candidate, prior findings/responses and remaining objections.
Cancel using the returned `proc://<jobId>/kill` (or agent ID where applicable), and
record the reason. Interactive Agent Hub (`Alt+A`) shows model, usage and status.

## Local repair, review and checkpoint

Sol implements -> checks -> diagnoses -> repairs -> checks affected behavior ->
yields. Keep routine compile failures and measurement-tool fixes in that run.
Escalate after **three substantive failed repair attempts**, a repeated identical
failure, ownership/shared-contract changes, ambiguous recovery, invalid evidence
conditions or exhausted scope/time/request budget. Include failures and partial
findings; never weaken an acceptance criterion to obtain a pass.

A worker's inline result is normally 100-250 words, with raw evidence on disk:

```text
001-contracts; status: review / blocked:
Base/head and checkpoint SHAs; branch/workspace; remaining diff/new-file hashes:
Behavior changed and why; changed paths / source entrypoints:
Checks: exact command, exit/result, named assertion, evidence-manifest path:
Open findings / limitations / shared-interface changes:
Substantive repair count; elapsed time; available requests/tokens/cost:
Requested and actual provider/model/thinking/tier; OMP agent/job IDs:
```

Do not truncate a material failure to meet the word target. OMP results may expose
`resolvedModelIdentity`, `resolvedThinkingLevel`, `resolvedModelIsFallback`, usage,
requests and artifact paths; record available values and mark missing ones unknown.
Subscription allowance and API-equivalent cost are separate; do not fabricate a
savings percentage or cost when telemetry is absent.

Astra reviews the **actual focused diff, necessary surrounding source, tests and
raw evidence**. Trace input through state, side effects and persistence/rendering;
inspect cleanup/error paths and rendered interaction evidence for visible changes.
Read risk-heavy ownership/FFI, persistence, cancellation/approval, workspace identity
and API/reload changes separately. A worker's summary or test exit code alone is
not acceptance. Return findings with severity, precise file/line, mechanism,
expected behavior and reproduction. Sol repairs; Astra rechecks affected paths and
all unresolved objections. Delegate mechanical integration/cross-feature checks to
Sol; do not take over the implementation to save a review round.

Accept only the frozen candidate actually tested and reviewed. Update task state,
review dispositions and a compact checkpoint: accepted base/candidate identity,
active IDs and owners, open findings, remaining budget, decisions and next eligible
tasks. This source-backed ledger supports recovery without copying whole chats.
Stop and hand control back when the current milestone is complete or blocked.

## Local evidence and limits

Prepared against `omp v18.10.4` at `/home/ashman/.bun/bin/omp` on 2026-10-23.
The binary serves its embedded local docs through the non-inference command
`omp read omp://<name>`. Relevant exact doc excerpts, line numbers and full-doc
hashes are retained in [.omp/evidence/local-omp.md](../.omp/evidence/local-omp.md).
Use these to recheck syntax after an OMP update:

- `omp --help`, `omp agents --help`, `omp worktree --help`: CLI flags, project
  agents and worktree support.
- `omp read omp://task-agent-discovery.md`: frontmatter; project-first discovery;
  model override precedence; tier/account independence; parent spawn/depth guards.
- `omp read omp://tools/task.md`: required `solutionSpace`, batch wire shape,
  isolation switch/backend, async lifecycle, result identities, limits and built-in
  child approval behavior. It names the implementing `src/task/{types,discovery,
  structured-subagent,executor,worktree}.ts` files.
- `omp read omp://settings.md`: project cwd scope and YAML precedence; CLI
  `omp config set/reset` writes **global** settings, so do not use it for this setup.
- `omp read omp://cli-reference.md` and `system-prompt-customization.md`: session
  flags, attachments and append prompt behavior.

A second local source tree exists at
`/home/ashman/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent`, but its
`package.json` is **17.4.0**, not the executable's version. Its actual
`src/task/agents.ts:106` parser and `src/task/discovery.ts:70` discovery function
are useful offline cross-checks, not proof of v18 runtime execution. In particular
that source lacks v18's required `solutionSpace` and uses an older isolation key.
Its `src/discovery/helpers.ts:256` parses frontmatter, and
`src/config/model-resolver.ts:1454-1515` documents and implements auth fallback to the parent model.
The v18 embedded discovery docs also mention auth fallback when resolving tiers.

**Model limitation:** pinning Sol and clearing the known retry chains prevents
intentional inheritance, but does not prove fail-closed model routing. OMP/global
extensions and credential fallback can change the resolved model. Before trusting
a run, inspect its actual model badge/identity; cancel and record any non-Sol
worker. A worker's own stop instruction cannot prevent a first incorrectly routed
request. This setup does not claim a hard pre-inference model firewall. Provider
availability and routing were deliberately not tested through paid inference or
credential-store inspection.

**Approval limitation:** no automatic approval override is added to project config
or the launcher; main-session approval behavior remains the existing OMP policy.
However v18 `tools/task.md`, Flow step 12, explicitly says core forces
`tools.approvalMode: yolo` inside headless children because they have no confirmation
UI. Prompt ownership and budgets do not sandbox shell access or external effects.
If per-child interactive approvals are required, OMP's built-in task runtime needs
a separate enforcement solution; adding an approval flag here cannot supply it.

Offline verification checks YAML/settings via the v18 CLI, parses/discovers project
agents through the available older source (clearly version-limited), checks shell
syntax and `--help`, and uses a stub OMP executable to test argv/cwd and resumed
launches without model calls. No live provider/account usability, v18 task execution,
worktree creation, GUI run, or paid coordinator/worker pilot is claimed.

## Project virtual desktop discovery

Installed v18 `omp read omp://skills.md` documents native `.omp/skills/<name>/SKILL.md` discovery, explicit name/description frontmatter, native priority 100 (above Codex priority 70), and inheritance by task children. The project skill points to installed `~/.local/bin/vd`; it does not install software or touch the user's display. Check discovery again after updates. Offline source discovery uses v17.4.0 and cannot prove v18 execution.
