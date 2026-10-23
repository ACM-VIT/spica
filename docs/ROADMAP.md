# Native agent workspace: prioritized backlog

Implementation backlog. Bootstrap is separate; feature items below remain pending. Priority reflects dependencies and a useful daily coding workflow, not a commitment to full T3 feature parity. Linux first. One default coding interface; the public primitives let users build other interfaces in their own configuration.

## Build order

| Order | Deliverable | Owner | Depends on | Acceptance gate |
| --- | --- | --- | --- | --- |
| 1 / P0 | Pin reference revisions and define core contracts | Astra decides; Sol prepares evidence/spec | Nothing | Versioned task/thread/run IDs, commands/events, provider capabilities, effect ownership, acceptance scenarios; no conflicting state owners |
| 2 / P0 | Repeatable build and fast core checks | Sol infrastructure | 1 | One-command build/check; pinned dependencies; CI; fixtures use separate temporary data; debug symbols and allocation checks |
| 3 / P0 | Fake provider, native automation and initial metrics | Sol infrastructure + provider/UI lanes | 1–2 | Script streams/tool/approval/cancel/failure; operate/capture real UI; export revision-tagged metrics. Establish the native GPU path as the starting baseline; renderer experiments are deferred |
| 4 / P1 | Durable single conversation and execution state | Sol runtime | 1–3 | Prompt/stream/cancel/reopen; committed intent before external effects; command deduplication; explicit interrupted/unknown state after ambiguous crashes |
| 5 / P1 | Useful native coding UI | Sol UI, parallel with 4 | 1–3 | Unicode composer, selection, keyboard focus, streamed text/Markdown/code/tool blocks, bounded transcript; remains interactive while streaming |
| 6 / P1 | Minimal public API proof | Sol UI/SDK, alongside 5 | 1, 4–5 interfaces | Default UI uses public commands/queries; a small user module replaces the root and a renderer; invalid config retains last working UI; restart keeps durable work |
| 7 / P1 | One real provider | Sol provider | Fake-provider end-to-end gate 4–6 | Use its supported protocol and existing authentication; real stream/tool/approval/cancel/error flow works in a disposable project |
| 8 / P2 | Multiple projects/threads and background runs | Sol runtime/UI | 4–7 | Switch without losing draft/undo/selection/scroll; background run status remains accurate; per-thread model/options and workspace identity stay correct |
| 9 / P2 | Bounded history metadata and large rich documents | Sol runtime/text | Ownership foundations 4–6 | Paged history and geometry; stable anchors across distant jumps/reflow; large Markdown/code retains formatting/selection/source; real import succeeds. Reuse the retained 523,183-byte failure case; bounded decoded caches alone do not bound a linear history index |
| 10 / P2 | Workspace and Git ownership, useful change inspection | Sol integrations | 7–8 | Explicit checkout/branch/worktree association; show changed files and diff; no wrong-checkout commands; open external editor/terminal as needed |
| 11 / P2 | Reliable queueing, recovery and data portability | Sol runtime | 7–10 | Follow-ups, interruption and provider restart have defined behavior; pending approvals recover correctly; export/backup/migrations preserve history |
| 12 / P3 | Broaden and document extension primitives | Sol SDK | API proof 6 + daily-use feedback | Namespaced metadata, subscriptions, async jobs, input/focus/drag mechanics, native rendering primitives; type annotations, pinned modules and compatibility fixtures |
| 13 / P3 | Additional provider and tool-result integrations | Sol provider | Capability contracts + stable first provider | A second adapter demonstrates real capability differences; no provider branches spread through UI; unsupported actions are explicit |
| 14 / P3 | Performance hardening and soak workloads | Sol performance; Astra reviews tradeoffs | Baselines from 3, repeated at each affected change | Fixed release workloads; frame/latency percentiles, process-tree PSS, cache plateau, script overhead, crash/restart; investigate regressions against the established baseline |
| 15 / P4 | Linux release readiness | Sol packaging; Astra release review | Prior daily-use gates | Install/update/uninstall, config recovery, data upgrades/rollback strategy, fonts, keyboard/accessibility and physical desktop checks; reproducible release |

Items 4–6 form one shared fake-provider milestone; they are not three unrelated releases. Runtime and UI can proceed against agreed interfaces while the fake adapter/harness enables integration. One task can include several related files; do not delegate one model call per file or trivial edit.

Correctness, memory ownership and performance measurement start at P0. Item 14 is deeper optimization, not the first time performance is checked. API fundamentals start at item 6; item 12 adds breadth and stability after real use. At the API proof, select one scripting runtime using a small representative extension; Lua is the current illustrative candidate, while Astra's earlier QuickJS-NG suggestion remains unmeasured. Keep public contracts independent of that choice; do not build both bindings now.

## First executable milestone

Create a persisted task -> type a prompt -> fake streamed response/tool activity -> approval/cancel -> switch default/custom root -> restart -> verify retained state. Record actual UI evidence and baseline metrics. A small custom root is enough to establish expressiveness; no complete alternative workspace is required.

## Human checkpoints

1. After items 4–6: try typing, selection, scrolling, cancel, config failure and restart. Roughly ten minutes; return concrete friction and screenshots.
2. After item 7: perform one real coding task in a disposable project; compare observed files/processes with what the UI claims.
3. After items 8–11: use multiple threads and normal project work. Test large imported histories and a hand-written configuration before stabilizing SDK behavior.
4. Before item 15: inspect upgrade/recovery, physical display behavior and performance evidence. Platform support follows actual verification.

Agents continue independent tasks while feedback is pending. A dependent API/product decision waits for the decision; silence is not approval.

## Deferred work and non-goals

- Full native terminal emulator, embedded browser, remote/mobile clients, extra operating systems, marketplace and automatic plugin manager.
- Built-in boards, dashboards, alternative workflow modes and other opinionated interfaces. These are user/community code built from primitives, not a feature-parity target.
- A universal scheduler inside the new product before the existing development workflow is dependable.

## Parallel ownership

One Astra coordinator plus up to three Sol workers: runtime/storage, providers/workspaces, native UI/API. Start with one or two workers when interfaces overlap. An infrastructure/integration task temporarily occupies a Sol slot; it is not an unbounded additional team. Benchmarks acquire one exclusive slot independently of implementation concurrency.

Astra reviews boundaries, risky diffs and milestone integration; Sol handles implementation, local repair loops, evidence capture and routine integration mechanics. Shared-contract changes return to Astra before other workers depend on them. Worktrees begin at a committed, reviewed base; uncommitted parent edits are not copied into delegated worktrees.

Operating protocol: [agent loop](AGENT_LOOP.md). Architecture: [design constraints](ARCHITECTURE.md). Evaluation: [checks and checkpoints](EVALUATION.md).


SHM is deferred by the owner. Do not schedule it as a task or acceptance gate.
