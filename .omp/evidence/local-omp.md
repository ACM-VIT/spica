# Local OMP evidence

Collected 2026-10-23 from `/home/ashman/.bun/bin/omp` (`omp v18.10.4`).
Embedded docs are local binary assets; `omp read omp://...` performs no model inference.
Full-document SHA-256 values below identify the exact output from which excerpts were selected.
Source-path references inside these docs refer to the OMP build source, not Spica.

## omp://task-agent-discovery.md

Full output SHA-256: `01f87021cf9db50931074f8f42981f8209667091bf546a20c084a27c5aaaaab9`

Lines 28-49:

```text
28:
29: - required `name`, `description`, and `systemPrompt`
30: - optional `tools`, `spawns`, prioritized `model` list, `thinkingLevel`, `output`, `blocking`, `autoloadSkills`, `readSummarize`, `prewalk`, `advisor`
31: - `source`: `"bundled" | "user" | "project"` (extension agents are tagged with their extension root's project/user level)
32: - optional `filePath`
33:
34: Parsing comes from frontmatter via `parseAgentFields()` (`src/discovery/helpers.ts`):
35:
36: - missing/non-string `name` or `description` => invalid (`null`), caller treats as parse failure
37: - `main` and `sub` are reserved names (checked after trimming and lowercasing); definitions using them are invalid
38: - `tools` accepts CSV or array; legacy tool aliases are normalized and `yield` is auto-added. An explicit `tools: []` therefore grants `yield`, not the default toolset.
39: - `spawns` accepts `*`, CSV, or array
40: - backward-compat behavior: if `spawns` missing but `tools` includes `task`, `spawns` becomes `*`
41: - `output` is passed through as opaque schema data
42: - `read-summarize: false` (normalized to `readSummarize`) disables structural summaries for the subagent's `read` tool — `runSubprocess` applies a `read.summarize.enabled: false` override on the child's isolated settings (`src/task/executor.ts`). `scout` ships with it disabled. When absent, the child inherits the parent's read-summary setting.
43: - `model` accepts one selector, CSV, or an array. Entries are tried in order after role aliases are expanded.
44: - `thinking-level` / `thinking` selects the agent's configured effort. When `task.enableEffort` (default `false`) exposes it, a task item's coarse `effort` (`lo`, `med`, `hi`) takes precedence at launch. OMP maps that hint to the selected model's lowest, middle, or highest supported effort, then clamps it to `task.maxEffort` (default `max`). The ceiling is carried across retry-fallback model switches. If the selected model has no supported effort at or below the ceiling, the spawn fails; models without a controllable effort surface instead fall back to their normal selector.
45: - `blocking: true` makes the parent wait for that agent even when async task execution is enabled
46: - `autoloadSkills` names skills from the parent session to inject before the first child prompt; unknown names are ignored
47: - `prewalk: true` starts the subagent on its resolved model and hands off to the default prewalk target (the `smol` role) at its first edit/write, exactly like the session-level `--prewalk`; a string value (e.g. `prewalk: "@smol"` or `prewalk: "openai/gpt-5-mini"`) picks a custom target. The `task.agentPrewalk` settings record (agent name → `"on"` / `"off"` / pattern, configured per agent from the `/agents` hub via its prewalk strip) overrides the frontmatter. Resolution happens in `runSubprocess` (`src/task/executor.ts`). An unavailable target is skipped instead of failing the spawn. A resolved target is skipped only when both its model identity and its effective thinking mode/level match the starting selection after model clamping; a same-model effort downgrade is a real hand-off and still arms and switches at the first edit/write.
48: - `advisor: true` pairs spawned sessions of the agent with an advisor running the model resolved for the `advisor` role; a string value (e.g. `advisor: "deepseek/deepseek-v4-flash"` or `advisor: "@smol:high"`) sets an explicit advisor model pattern (optional `:level` suffix), applied as the spawned session's `modelRoles.advisor`. The `task.agentAdvisor` settings record (agent name → `"on"` / `"off"` / pattern, configured per agent from the `/agents` hub via its advisor strip) overrides the frontmatter. Resolution happens in `runSubprocess` (`src/task/executor.ts`); subagents default to no advisor, and the effective opt-in is persisted in `session_init` so cold revival restores it.
49:
```

Lines 53-87:

```text
53:
54: Give the agent a role alias in frontmatter, then dispatch it by name. For model routing, task dispatch sets only `agent`; it does not set a worker model:
55:
56: `~/.omp/agent/agents/reviewer.md`:
57:
58: ```md
59: ---
60: name: reviewer
61: description: Review a change for correctness.
62: model: "@review"
63: ---
64:
65: Review the assigned change and report concrete findings.
66: ```
67:
68: Set the role mapping in `~/.omp/agent/config.yml`:
69:
70: ```yaml
71: modelRoles:
72:   review: openai/gpt-5.4:high
73: ```
74:
75: `@review` resolves through `modelRoles.review`. Each `modelRoles.<role>` value stores a concrete model selector and may append a thinking suffix such as `:high` (`src/config/model-resolver.ts`). Changing that mapping affects subsequent task resolutions without editing agent definitions. Task/eval preflight reloads the current global, project, and explicit overlay settings before rediscovering agents, so agent files and their role aliases added during a live session resolve from one refreshed configuration state.
76:
77: With the default batched task schema, supply shared `context` and per-item `task` and `solutionSpace`. `solutionSpace` describes how open-ended the assignment is, rather than its size. Set `agent` only when choosing a non-default agent:
78:
79: ```json
80: {
81:   "context": "Review the current change in this repository.",
82:   "tasks": [
83:     {
84:       "agent": "reviewer",
85:       "task": "Report concrete correctness findings.",
86:       "solutionSpace": "Review cause and failure modes are open; no known defect."
87:     }
```

Lines 163-186:

```text
163: Claude-dialect plugin agents discard their frontmatter `model` so Claude aliases are not misread as OMP selectors. This applies to foreign Claude roots and packages whose manifest declares the Claude format, including OMP installs or `--plugin-dir` roots. OMP-native and Agent-Plugins-standard packages retain their model selectors.
164:
165: ## Merge and collision rules
166:
167: Discovery uses first-wins dedup by exact `agent.name`:
168:
169: - A `Set<string>` tracks seen names.
170: - Loaded agents are flattened in directory order and kept only if name unseen.
171: - Bundled agents are filtered against the same set and only added if still unseen.
172:
173: Implications:
174:
175: - Project `.omp` overrides user `.omp`.
176: - Earlier extension roots override later extension roots, Claude marketplace plugins, and bundled agents.
177: - Non-bundled agents override bundled agents with the same name.
178: - Name matching is case-sensitive (`Task` and `task` are distinct).
179: - Within one directory, markdown files are read in lexicographic filename order before dedup.
180:
181: ## Invalid/missing agent file behavior
182:
183: Per directory (`loadAgentsFromDir`):
184:
185: - unreadable/missing directory: treated as empty (`readdir(...).catch(() => [])`)
186: - file read or parse failure: warning logged, file skipped
```

Lines 222-257:

```text
222:
223: For task dispatch, model precedence is:
224:
225: 1. `task.agentModelOverrides[agentName]`
226: 2. the agent frontmatter's prioritized `model` list
227: 3. the parent's active model, then its configured/default model fallback
228:
229: Role aliases in either of the first two sources are expanded through `modelRoles`. The shared eval bridge can also supply an invocation-local model override ahead of the settings override; the task wire schema does not expose that field.
230:
231: After policy resolution, the `before_subagent_spawn` extension hook runs once for the actual dispatch. It can block the spawn or replace the resolved model patterns; a routing note is carried into progress metadata.
232:
233: The `Alt+P` task model pick is session-only; saving a model in `/agents` replaces that runtime selection for the current session and persists the new value for future sessions.
234:
235: Compaction triggers are separate from model and service-tier selection: an exact, case-sensitive
236: `task.agentCompactionThresholdOverrides[agentName]` entry (`90000` or `"80%"`) replaces the
237: `compaction.threshold*` settings for that agent only; agents without an entry, including agents it
238: spawns, use the main session's thresholds. See [Settings](./settings.md#context-compaction-and-memory).
239:
240: Request budgets follow the same exact-name pattern: a `task.agentSoftRequestBudget[agentName]` entry
241: (a non-negative integer) is that agent's soft request budget, replacing both `task.softRequestBudget`
242: and the bundled scout/sonic ceiling, so it can raise a budget the global setting can only lower; `0`
243: disables that agent's guard, and `null` clears an entry from a lower settings layer. Agents without an
244: entry keep the global setting capped by their bundled ceiling. See [task](./tools/task.md#limits--caps).
245:
246: Service-tier precedence is independent of model selection: an exact, case-sensitive
247: `task.agentServiceTierOverrides[agentName]` entry overrides `tier.subagent`; an absent entry preserves
248: the global behavior. `inherit` snapshots the parent session's live per-family tiers (including
249: `/fast` changes) for the next spawn. The child session resolves a concrete value against the model
250: it finally settles on — after auth fallback and after patterns only the session can resolve, such as
251: extension-registered models — and populates only that model's provider family when the family
252: supports the value, so same-family retry fallbacks retain the tier and cross-family fallbacks never
253: inherit it. The resolved map is persisted with the child's session, even when it is empty, so a
254: parked agent revived after a restart keeps its per-agent tier instead of re-deriving
255: `tier.subagent`. The entry is looked up by task/eval dispatch only; Vibe workers launched through
256: the same executor keep `tier.subagent`. Service tiers are configuration-only; agent frontmatter and
257: the task/eval wire formats do not expose a tier field or automatic Fast policy.
```

Lines 306-335:

```text
306:
307: `resolveEffectiveSubagentPolicy()` checks `task.disabledAgents` after resolving the agent. A disabled name fails preflight and lists enabled alternatives when available.
308:
309: ### Parent spawn policy
310:
311: The resolver checks `session.getSessionSpawns()`:
312:
313: - `"*"` (also `true`, `null`, or absent) => allow any; omitted `agent` defaults to `task`
314: - `""` or `false` => deny all
315: - CSV list => allow only listed names; omitted `agent` defaults to its first name
316:
317: If denied: `Cannot spawn '...'. Allowed: ...`.
318:
319: ### Blocked self-recursion env guard
320:
321: `PI_BLOCKED_AGENT` (or the internal request override) rejects an attempt to spawn the same blocked agent before discovery.
322:
323: ### Recursion-depth gating
324:
325: `task.maxRecursionDepth` defaults to `2`; a negative value disables the cap. The shared policy rejects a spawn when the current task depth has already reached the cap. When a child reaches the cap, `runSubprocess` also removes `task` from its tool list and sets its spawn policy empty.
326:
327: For an explicit agent tool list, `runSubprocess` auto-adds `task` when `spawns` is declared and depth permits it. The legacy `exec` entry expands to `bash` plus `eval` when an eval backend is available. A list containing `task` or `bash` also gains `wait` unless the parent requires an exact restricted tool list; tool construction still omits `wait` when there is no async, IRC, or service wake source. Outbound peer messaging requires `write` in the child tool list and IRC enabled; inbound steering does not.
328:
329: ## Plan mode behavior
330:
331: When parent plan mode is enabled, `resolveEffectiveSubagentPolicy()` builds an `effectiveAgent` before launching subprocesses:
332:
333: - prepends the plan-mode subagent system prompt
334: - restricts tools to `read`, `grep`, `glob`, and `web_search`, plus `ast_grep` when the agent's own tool list declares it
335: - clears child spawns
```

## omp://tools/task.md

Full output SHA-256: `c842c8ba7ab9e80b45e38b69b1df37c3ffe813cb7f35bcae749ebac4c7de44ec`

Lines 32-56:

```text
32:
33: The wire schema is shape-swapped by `task.batch` (default on). One unit of work is `{ name?, agent?, task, solutionSpace, effort?, outputSchema?, schemaMode?, tools?, isolated? }`. `isolated` exists only when `task.isolation.enabled` is true **and plan mode is disabled**; `effort` requires `task.enableEffort=true` (default off), and `tools` requires `eval.tools.enabled` (default on).
34:
35: - **Batch shape** (`task.batch` on): `{ context, tasks: item[] }` — one subagent per item, all run under the same fan-out rules; there is no top-level agent field. `context` is **required** shared background rendered into every spawned subagent's system prompt (`CONTEXT` section); `agent`, `outputSchema`, and `schemaMode` are per item. `effort` is added only when its setting enables it; `isolated` additionally requires plan mode to be disabled.
36: - **Flat shape** (`task.batch` off): `{ ...item }` — exactly one spawn per call. Shared background goes into a `local://` file (e.g. `local://ctx.md`) that each spawn's `task` references; subagents share the parent's `local://` root.
37:
38: | Field | Type | Required | Description |
39: | --- | --- | --- | --- |
40: | `context` | `string` | Yes (batch) | Shared background prepended to every spawn of the call via the subagent system prompt. Rejected when `task.batch` is off. |
41: | `tasks` | `array` | Yes (batch) | One task item per subagent. Provided names must be unique within the call (case-insensitive). Rejected when `task.batch` is off. |
42: | `name` | `string` | No | Stable agent name — becomes the registry/IRC id. The prompt requests CamelCase, at most 32 characters; the wire schema only requires a string. Defaults to a generated AdjectiveNoun name and is uniquified per session by `AgentOutputManager`. Item field in batch shape, top-level in flat shape. |
43: | `agent` | `string` | No | Agent type to run this item (e.g. `scout`). Defaults to the spawn policy's default agent (usually `task`); items in one batch call may use different agent types. Item field in batch shape, top-level in flat shape. |
44: | `task` | `string` | Yes | The work — complete, self-contained instructions. Empty-after-trim is rejected. Item field in batch shape, top-level in flat shape. |
45: | `solutionSpace` | `string` | Yes | How open-ended the child's problem is: whether the fix or design is given, or which causes or designs remain open (e.g. `one fix: rename, names given`; `deadlock cause open, no repro`). Volume of work does not widen it. Rides the child's first prompt into the `auto` thinking classifier as its sole input — the judge sees this field, not the `task` text; ignored when the child's thinking selector is not `auto` or `effort` overrides it. Blank or missing values fall back to classifying the `task` text: the schema advertises it as required, but the tool's lenient argument validation still spawns a call that omits it. Item field in batch shape, top-level in flat shape. |
46: | `effort` | `"lo" \| "med" \| "hi"` | No | Present only with `task.enableEffort=true`. Per-spawn thinking effort, mapped onto the resolved model's supported range (lowest/middle/highest level it tops out at, e.g. `high`/`xhigh`/`max`). Overrides the agent's default selector, including `auto`; omitting it keeps the agent's configured selector — automatic per-prompt classification only for agents configured `auto` (e.g. the bundled `task`); `scout`/`sonic` configure `medium`. Item field in batch shape, top-level in flat shape. |
47: | `outputSchema` | JSON Schema (`object \| boolean \| string \| null` at the coarse wire-validation layer) | No | Invocation-specific structured-output contract. Takes precedence over agent frontmatter `output` and the inherited parent session schema. Item field in batch shape, top-level in flat shape. |
48: | `schemaMode` | `"permissive" \| "strict"` | No | Validation mode for the effective output schema. Overrides the parent mode; defaults to `permissive`. After schema-retry exhaustion, permissive mode can accept invalid payloads with a warning; strict mode fails. Invalid caller schemas fail preflight in either mode. |
49: | `tools` | `string[]` | No | Named tools already defined in the parent's Python or JS eval kernel. Present when `eval.tools.enabled=true`; child calls execute in the parent kernel, not the child's. Rejected in plan mode. Item field in batch shape, top-level in flat shape. |
50: | `isolated` | `boolean` | No | Run in an isolated workspace and capture patches/branch changes. Present only when `task.isolation.enabled` is true and plan mode is disabled. Kept-alive task agents retain their workspace through idle/parked transitions and can be revived; release captures final changes and cleans the workspace. |
51:
52: There is no wire label field: the one-line UI label shown in the TUI/registry is generated automatically from the `task` text by the tiny/title model (fire-and-forget), so callers never provide it.
53:
54: Users can tag models with `^` in the composer. The resulting session-local `m1`, `m2`, … pseudonyms are accepted as `agent` by task, eval `agent()`, and `workpool()`; each uses the bundled task template pinned to the tagged selector. See [user-tagged model agents](../task-agent-discovery.md#user-tagged-model-agents) for persistence, boundaries, and precedence.
55:
56: Runtime stays permissive: the flat form is accepted even while `task.batch` is on (internal callers such as the commit flow's `analyze_files`, and stale transcripts). The model only ever sees one shape.
```

Lines 72-86:

```text
72:
73: `SingleResult` includes:
74: - identity: `index`, `id`, `agent`, `agentSource`, `task`, `description`, optional `assignment` (internal payload names; the wire fields are `name`/`agent`/`task`)
75: - status: `exitCode`, optional `error`, optional `aborted`, optional `abortReason`, optional `retryFailure`
76: - output: `output`, `stderr`, `truncated`, `durationMs`, `tokens`, `requests`, optional `contextTokens`/`contextWindow`, `usage`
77: - model: optional `modelOverride`, `modelRole`, `resolvedModel`, `resolvedModelIdentity`, `resolvedThinkingLevel`, `resolvedModelIsFallback`, `resolvedModelRoute`, `advisor`
78: - structured result: optional `structuredOutput` with schema source/mode, validation status, parsed `data`, and validation `error`
79: - artifact metadata: `outputPath?`, `isolated?`, `patchPath?`, `hasRootChanges?`, `branchName?`, `branchBaseSha?`, `nestedPatches?`, `nestedPatchPaths?`, `outputMeta?`
80: - extracted tool data: `extractedToolData?` from registered subprocess tool handlers such as `yield`
81:
82: Artifacts and side channels:
83: - Every subagent with an artifacts dir writes `<id>.md`; `agent://<id>` resolves to that file.
84: - Structured payloads with a `data` value also write `<id>.json`, even when schema-invalid. JSON-path reads prefer this sidecar and fall back to parsing `<id>.md`; a later output without structured data removes a stale sidecar.
85: - A subagent's own children are dot-qualified (`<id>.<child>`); `agent://<id>.<child>` reads that nested output. A slash path is always JSON extraction: `agent://<id>/<key>/<index>/…` extracts that value from a JSON output (e.g. `agent://<id>.<child>/reports/0/data`).
86: - Each subagent gets `<id>.jsonl` session history when the parent persists artifacts; `history://<id>` renders it as a concise transcript (works for live and parked agents).
```

Lines 105-108:

```text
105: 10. Artifacts dir comes from the parent session file when available, otherwise a temp dir. When the session is executing an approved plan, the plan reference is handed to the subagent.
106: 11. Non-isolated spawns call `runSubprocess(...)` with parent cwd. Isolated spawns run in their workspace and capture root/nested patches or a branch. Successful changes apply only when `task.isolation.apply=true`; failed capture/merge paths preserve recovery artifacts. Kept-alive runs transfer workspace cleanup to the lifecycle owner rather than tearing it down at completion.
107: 12. `runSubprocess(...)` creates a child agent session with an isolated settings snapshot (parent settings inherited — `async.enabled` and `bash.autoBackground.enabled` are **inherited** from the parent, not force-disabled; `tier.openai`/`tier.anthropic`/`tier.google` are first re-resolved through `tier.subagent`, then the child session resolves an exact `task.agentServiceTierOverrides[agentName]` entry handed over by task/eval dispatch against its final model and persists the result; `tools.approvalMode` is forced to `yolo` because headless subagents have no UI to confirm prompts against; `advisor.enabled` is forced off unless the spawn opts in per agent; per-spawn overrides may disable read summarization and clear extra workspace roots for isolated runs), child `agentId` equal to the allocated id, child internal URL router/`AgentOutputManager`, output schema, the shared `context` (batch calls) in the system prompt's `CONTEXT` section, and the IRC peer roster in the system prompt.
108:     An exact `task.agentAccountPools[agentName]` entry is installed on the child's provider session right after the parent's account affinity is copied, and the child's model registry enforces it on every key lookup, so for each listed provider the child, its side requests, and subagents it spawns without their own entry authenticate only with those OAuth accounts; vibe workers and revived agents take the live entry. See [Task agent discovery](../task-agent-discovery.md#model-and-structured-output-precedence).
```

Lines 125-130:

```text
125:   - off — single spawn per call; `tasks`/`context` are rejected and removed from the schema, with the same conditional `effort`/`isolated` fields.
126: - Speculative launch (`task.speculativeLaunch`, default on; batch mode only) — while a `{ context, tasks[] }` call streams, the tool's stream session (`src/task/speculative-launch.ts`) starts each item's `SpawnRun` as soon as that item's JSON object closes (`context` must already have closed), and starts the remainder when the call finishes streaming. Dispatch adopts runs whose normalized spawn params still match; an invalid finished call, launched items that differ from the finished call, a blocking hook, or an aborted turn aborts every launched run. Launches need host authorization (`authorizeLaunch`): auto-allowed `task` approval and no extension `tool_call`/`tool_result`/approval lifecycle handlers.
127: - Isolation is enabled with `task.isolation.enabled`; `isolation.backend` selects `auto`, `apfs`, `btrfs`, `zfs`, `reflink`, `overlayfs`, `projfs`, `block-clone`, or `rcopy`, and the PAL resolves the actual backend with fallback.
128: - Isolation merge strategy: `task.isolation.merge` selects patch mode (capture/apply root patches) or branch mode (commit to `omp/task/<id>`, cherry-pick into parent). `task.isolation.apply=false` retains captured changes without applying them; nested repositories get separate patch artifacts.
129: - Eval-defined tools: `tools` resolves names across the parent's retained Python/JS kernels. Unknown names, disabled sharing, or the same name defined in both kernels fail preflight; these tools are not available in plan mode.
130: - Agent source precedence is first-wins by exact name: project `.omp/agents`; user `.omp/agent/agents`; OMP extension-package `agents/` roots in CLI → project settings → user settings → installed npm/link plugin order; Claude marketplace plugin agents (project before user); then bundled (`scout`, `reviewer`, `security-reviewer`, `task`, `sonic`).
```

Lines 156-166:

```text
156: - Tool mode: `approval="exec"`, `strict=false`, `lenientArgValidation=true`, `loadMode="essential"`.
157: - Per-spawn effort is opt-in: `task.enableEffort` defaults to `false`; when false, `effort` is omitted from the dynamic model-facing schema.
158: - Concurrency: `task.maxConcurrency` defaults to `32`; `0` means unlimited. One session-scoped `Semaphore` is resized from the live setting before every acquire/release and bounds every `SpawnRun` across task calls, including sync and speculative runs.
159: - Isolation baseline: each repository's uncommitted snapshot is capped at `1 GiB` (`ISOLATION_BASELINE_MAX_CONTENT_BYTES` in `task/worktree.ts`). Oversized snapshots fail before spawning rather than buffering unbounded content.
160: - Idle TTL: `task.agentIdleTtlMs`, default `420_000` ms (7 min); `<= 0` disables parking and keeps idle sessions live until exit.
161: - Per-subagent output truncation: `MAX_OUTPUT_BYTES = 500_000` and `MAX_OUTPUT_LINES = 5000` in `packages/coding-agent/src/task/types.ts` (overridable via `PI_TASK_MAX_OUTPUT_BYTES` / `PI_TASK_MAX_OUTPUT_LINES`). Full raw output is still written to `<id>.md`.
162: - Progress coalescing: `PROGRESS_COALESCE_MS = 150`; recent-output tail: `RECENT_OUTPUT_TAIL_BYTES = 8 * 1024` (last 8 non-empty lines).
163: - Missing-`yield` reminder retries: `MAX_YIELD_RETRIES = 3` in `packages/coding-agent/src/task/executor.ts`.
164: - Soft request budget: `task.softRequestBudget` defaults to 200 requests (`0` disables). Crossing it injects a wrap-up notice when `task.softRequestBudgetNotice` is enabled; at 1.5× the budget the run is force-stopped to yield partial findings. Bundled scout/sonic agents cap it at 100; the setting can lower that cap but not raise it. An exact-name `task.agentSoftRequestBudget` entry (`lead: 400`) replaces both for that agent, in either direction; `0` there disables its guard.
165: - Hard wall clock: `task.maxRuntimeMs` applies to every spawn; default `0` disables it.
166: - Recursion depth: `task.maxRecursionDepth` defaults to `2`; negative values disable the cap. The tool registry and shared preflight enforce it, and `runSubprocess(...)` strips child `task` access at max depth.
```

## omp://settings.md

Full output SHA-256: `aa514a15540f13386bebeadd6eb00eec97adae95f32b83fd36b76ca8a4d69125`

Lines 15-30:

```text
15: | Scope             | Path                                                  | Read behavior                                                                                                                            | Write behavior                                                                                                                                                                   |
16: | ----------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
17: | Global            | `~/.omp/agent/config.yml` (or existing `config.yaml`) | The main persistent settings file. `config.yml` is the canonical write target; an existing `config.yaml` is loaded and updated in place. | `/settings`, `omp config set`, and `omp config reset` write here.                                                                                                                |
18: | Global legacy     | `~/.omp/agent/settings.json`                          | Considered for migration only when neither main YAML filename exists. | Not written; renamed to `settings.json.bak` after a non-empty migrated YAML file is successfully saved. |
19: | Project           | `<cwd>/.omp/config.yml` (plus `.omp/settings.json`)   | Loaded when the process working directory has a non-empty `.omp/`.                                                                       | Settings commands do not write arbitrary project keys. With `modelRoleStorage: project`, model-selector role assignments update only `modelRoles` here; edit other keys by hand. |
20: | Project legacy    | `<cwd>/.omp/settings.json`                            | Still read; project `config.yml` is merged on top of it.                                                                                 | Not written by settings commands.                                                                                                                                                |
21: | CLI overlay       | Any file passed with `--config <file>`                | Loaded after global and project settings, for that one process. Repeatable.                                                              | Never persisted.                                                                                                                                                                 |
22: | Runtime overrides | In-memory only                                        | Set by settings overrides such as `--approval-mode`, role flags, and feature env vars. | Never persisted. |
23:
24: The global paths above describe the default profile. `omp --profile work` selects `~/.omp/profiles/work/agent` instead, isolating settings, auth, sessions, and caches. `OMP_PROFILE` also selects a profile; `PI_PROFILE` is its compatibility fallback only when `OMP_PROFILE` is absent. An explicit `--profile` wins over both, and `--profile default` selects the default profile.
25:
26: `PI_CODING_AGENT_DIR` relocates the default profile's agent directory, including `config.yml` and its agent data. Named profiles derive their own agent directory and ignore this override. Use `omp config path` (or `omp --profile work config path`) to print the active settings directory.
27:
28: On Linux and macOS, configured `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` can redirect data/state/cache when the corresponding `omp` directories exist. Named profiles require the corresponding `omp/profiles/<name>` directory. This does not move `config.yml`: it stays under the active agent directory, while `agent.db` and other categorized data may live elsewhere. `omp config init-xdg` creates the base directories but does not migrate files or set environment variables.
29:
30: Native project settings are intentionally scoped to the process working directory's `.omp/` folder — settings discovery does **not** walk ancestor directories looking for the nearest `.omp/`. Other discovery providers (Claude, Codex, Gemini, Cursor, OpenCode) can also contribute project-level settings from their own files; those are read-only from `omp` settings commands and can be turned off by provider id (see [Provider and source disabling](#provider-and-source-disabling)).
```

Lines 94-110:

```text
94: ### Where writes go
95:
96: `omp config set`, `omp config reset`, `/settings`, and persistent runtime settings changes write the global main YAML file under the active agent directory. Runtime-only overrides are not saved. Settings commands do not write arbitrary keys to `<cwd>/.omp/config.yml`. Model-role assignment or clearing with `modelRoleStorage: project` updates only the affected roles there; missing project roles fall back to global roles. To create another project-local override, edit the project file directly (see [Project-local config](#project-local-config)).
97:
98: Saves are debounced and re-read the file under a lock. Disjoint external edits are preserved. If an external writer changed the same global setting or model role after a local change was staged, the stale local change is skipped with a warning rather than overwriting the newer file value.
99:
100: Saves through a symlinked main config preserve the link and update its resolved target. Targets containing `.` or `..` follow the operating system's rules: Windows collapses those segments before following intermediate links, while POSIX traverses each component on disk. A target such as `alias/../config.yml` can therefore name different files on the two platforms.
101:
102: ### Live file changes
103:
104: Interactive sessions and RPC/RPC-UI hosts watch the main global file, project settings sources, and config overlays. Changes are reloaded after a short debounce, preserving runtime overrides. A layer that fails to parse or validate keeps its last good values and logs a warning; other valid layers can still refresh. Live reload does not move the invalid file to a `.broken-*` backup.
105:
106: Symlinked configs follow edits to their target and replacement of any intermediate file or directory symlink, including profile links. After a link switches targets, subsequent edits to the new target are watched too.
107:
108: Reloading changes the settings values available to consumers; startup-only work is not rerun. Provider-source switches take effect on the next discovery pass. Task/eval dispatch also reloads persisted settings before resolving a subagent's policy.
109:
110: Routing changes to `modelRoles`, `retry.fallbackChains`, and `task.agentModelOverrides` apply to subsequent subagent launches and fallback decisions without restarting the host. `auth.accountPolicies` and `retry.usageReservePct` also update the long-lived account router for subsequent credential selection and quota checks. Reloading does not restart running subagents or switch a healthy active session's model; explicit runtime overrides still take precedence.
```

## omp://cli-reference.md

Full output SHA-256: `f019198740f6e75fb4ed9402afde8600fff51d5f4b4cfc51e198f19eccc6f6a4`

Lines 55-65:

```text
55: Argument handling:
56:
57: - `@<path>` attaches a file or image to the initial message.
58: - Outside protocol modes, non-TTY stdin is read to EOF automatically as prompt
59:   text; do not add a `-` marker. Piped input or a non-TTY stdin selects print mode
60:   when `--mode` is omitted. Without stdin text, an argv prompt or attachment is
61:   required.
62: - Stdin text, text attachments, and the first positional message are combined
63:   into the initial prompt; remaining positional messages are sent as later turns.
64: - `--` ends flag parsing; everything after it is literal message text, even if it
65:   looks like a flag.
```

Lines 84-98:

```text
84: | Flag | Description |
85: | --- | --- |
86: | `--continue`, `-c` | Continue the previous session. |
87: | `--resume [id]`, `-r`, `--session [id]` | Resume a session by ID prefix or path, or open the picker when no value is given. |
88: | `--restore [id]` | Resume a session as `--resume` does, then go on with what its last process left unfinished when it crashed or was killed: the interrupted turn and the subagents it was running. Interactive only; takes no prompt. See [session operations](./session-operations-export-share-fork-resume.md#cli---restore). |
89: | `--fork <session>` | Fork a saved session (by ID prefix or path) into a new session. See [session operations](./session-operations-export-share-fork-resume.md). |
90: | `--from-claude` | Import a Claude Code session into OMP. |
91: | `--from-codex` | Import a Codex session into OMP. |
92: | `--export <session>` | Export a session file to HTML and exit. |
93: | `--no-title` | Disable title auto-generation (equivalent to the `PI_NO_TITLE` [environment variable](./environment-variables.md)). |
94:
95: `--continue`, `--resume`, `--restore`, `--fork`, and foreign-session imports require
96: persistence and cannot use `--no-session`. `--from-claude` and `--from-codex`
97: are mutually exclusive and cannot be combined with `--continue`, `--resume`,
98: or `--fork`.
```

Lines 165-169:

```text
165: | Flag | Description |
166: | --- | --- |
167: | `--system-prompt <text\|file>` | Plain-text system prompt override (default: coding assistant prompt). See [system prompt customization](./system-prompt-customization.md). |
168: | `--system-prompt-template <path>` | Strictly read `<path>` as a Handlebars system-prompt template; mutually exclusive with `--system-prompt`. See [system prompt customization](./system-prompt-customization.md). |
169: | `--append-system-prompt <text\|file>` | Append plain text or file contents to the system prompt. |
```

## omp://extensions.md

Full output SHA-256: `a5ab0b713ebb3cedba8282a949eb79aaf83846477d9d77f173be96998374ceb1`

Lines 480-488:

```text
480:
481: - `input`
482: - `before_agent_start`
483: - `before_provider_request` — receives `{ payload }`; return the replacement payload itself (not `{ payload }`). Handlers chain. Provider transports must invoke `onPayload`; `devin-agent` does not.
484: - `after_provider_response` — notification before response-body consumption: `{ status, headers, requestId?, metadata? }`. Provider request/response handlers receive the model used for that request in `ctx.model`.
485: - `context` — receives conversation messages and may return `{ messages }`; replacements chain without rewriting persisted history
486: - `agent_start` / `agent_end` — agent loop lifecycle notification; `agent_end` remains notification-only
487: - `session_stop` — main-session stop hook, awaited before settle. Advisory `{ continue: true, additionalContext }` requests are capped at 8 continuations. Explicit `{ decision: "block", reason }` refusals take precedence over advisory requests, do not consume that allowance, and remain blocking until the hook allows completion or the operator interrupts. A refusal without a reason receives a diagnostic continuation rather than permission to finish. This event never fires for task/subagent sessions and defers until agent-owned background jobs are fully idle (`#hasPendingAsyncWake` in `session/agent-session.ts`).
488: - `cache_warming_decision` — fired before each prompt-cache warming refresh with the warmer's economics (`warmCost`, `missCost`, `continuationProbability`, `action`). Return `{ action: "warm" | "stop" }` to override; the last handler returning an action wins, handler failures or answers slower than 2 seconds leave the warmer's decision standing, and a `"stop"` override ends warming until the next real request. Only the main agent loop warms; task/subagent sessions never fire this. The refresh itself replays the real request through the same provider path, so `before_provider_request` and `after_provider_response` fire for it too; a replacement payload must stay byte-identical to the real one for the refresh to hit the cache.
```

Lines 562-565:

```text
562: ### Subagent lifecycle
563:
564: - `before_subagent_spawn` → `{ model?: string | string[]; block?: boolean; reason?: string; note?: string }`. Fires in the parent session exactly once per spawned child (`task`, eval `agent()`, workpool workers), at dispatch before the child resolves its model — never during a frontend's validation preflight, so stateful routers (round-robin, quota) advance once per child. The event carries `agent`, `invocationKind`, `modelRole` (the pre-expansion role alias, when any), the expanded `patterns` core would use, and an optional stable `spawnKey`. A returned `model` replaces the spawn's attempt-ordered patterns while keeping the role identity, so the remaining entries become the child's retry fallback chain; handlers run in extension order and the last returned `model` wins, along with its `note`, which the task UI shows as the spawn's routing reason on live, async, and settled rows. `block: true` refuses the spawn with `reason`. Cancelling the spawn releases an awaiting handler (its result is discarded and pending `ctx.ui` dialogs close) instead of holding the spawn until the handler timeout.
565:
```

## Offline checks

- Installed v18 CLI: all 30 project keys recognized; effective values match project YAML (owned record entries checked independently of global entries).
- Older local npm source v17.4.0: actual `parseAgent` and `discoverAgents` loaded `task`, `sol-measure`, `sol-repair` as project agents, all with model `["gpt-6.1-sol"]`, medium/high thinking, no child task tool, prewalk/advisor false. Extension-package discovery was scoped to explicit empty roots for this cross-check only; no launcher discovery/profile setting was changed.
- `bash -n tools/agents` and `./tools/agents --help`: pass.
- Stub OMP: 17 argv/cwd cases pass; default fresh attachment, exact passthrough of continuation/resume/import flags and message spacing, no startup attachment on restored sessions, no added profile/approval flags.
- No paid model calls, credential/auth-database inspection, worktrees, staging or commits performed.
- No v18 live task/model/account/GUI behavior is claimed.

## Round 2 offline verification (2026-10-23)

- `bash -n tools/agents` and `./tools/agents --help`: pass. Stub OMP: 17 exact argv/cwd cases pass, including fresh launch, supplied message, literal `--`, continuation/resume/restore/import, and unchanged user flags. No model executable was invoked by those launch tests.
- Installed v18 CLI `omp config get <key> --json`: all 30 project setting keys match YAML; project map entries compared independently of inherited entries. Config was unchanged.
- Available v17.4.0 source `parseAgent`: all three project agents parse with exact Sol model and medium/high thinking; none has the child task tool. `loadSkillsFromDir` actually discovers `.omp/skills/virtual-desktop/SKILL.md` without warnings. This is a source-version-limited scanner check, not a v18 live session claim.
- Both documentation task JSON examples parse and reference `001-contracts.md`; guide is 806 whitespace-delimited words (limit 950); status examples agree with ledger. Startup explicitly limits default scope to task 001 through review/checkpoint.
- No inference calls, account/auth changes, staging, commits, worktrees or GUI actions performed.

### Installed v18 skill discovery evidence

`omp read omp://skills.md` (non-inference), full document SHA-256: `bfda04157b83f45768969ab3717045e686ce5c7eafacb5fc8950474188125460`. Relevant numbered excerpts:

```text
27: For conventional provider roots (native/Claude/Codex/Agents/plugins), skills are discovered as **one level under `skills/`**:
69:   - native `.omp` provider skill discovery (`requireDescription: true`)
91: 1. `native` (priority 100) — `.omp` user/project skills via `src/discovery/builtin.ts`
153: Task tool subagents receive the session's discovered/provided skills list via normal session creation; there is no per-task skill pinning override.
```

The project skill uses explicit name/description and installed `~/.local/bin/vd`; no installation or global skill edit was needed.
