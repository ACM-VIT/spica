# Spica native workspace rewrite

Build Spica like a video game engine for a data-intensive application: data-oriented layouts, explicit ownership, bounded memory, and incremental work.
Performance is a primary acceptance requirement: target low-end hardware and prove responsiveness/frame times, CPU cost, and whole-process-tree RSS/PSS with measurements, not architectural claims.

Read README.md, docs/ROADMAP.md and your task record before working. This branch is a new application foundation, not the old Pi chat client. Do not restore deleted application code wholesale to make a check pass.

## Product boundaries

- Linux first; Zig 0.16, SDL3, Clay and the retained native text/content libraries. Keep OS mechanics behind platform boundaries.
- One useful default coding interface, composed through public primitives. Users can replace the root, renderers, commands, input and styling. Do not add built-in kanban boards or alternate workspace presets.
- Product scope includes Codex with supported ChatGPT sign-in, OpenCode v2 and app-owned coordinator/worker orchestration. Define the shared contracts early; implement adapters and orchestration in ROADMAP order. See docs/PROVIDERS_AND_ORCHESTRATION.md.
- Domain execution owns projects, threads, runs and durable commands/events. UI state and configuration reload must not own provider lifetimes.
- Keep scripting contracts independent of runtime choice; select one runtime with a small proof before adding bindings. Lua and QuickJS are candidates, not commitments.
- GPU rendering is the starting path. SHM investigation is deferred and is not a task or acceptance gate.
- Do not read or migrate existing Spica/T3 histories or credentials implicitly. Fixtures use temporary, separate state. OMP is the development harness, not a selected product provider backend.

## Agent workflow

The main OMP chat is GPT-6 Astra: coordinate, decide interfaces, inspect actual changes and evidence. GPT-6.1 Sol workers implement, investigate, run checks, collect UI/performance evidence and repair failures. See docs/AGENT_LOOP.md and project agents in .omp/.

Start with two workers; at most three. Assign explicit file ownership and acceptance gates; shared contracts have one owner. Make frequent, small, descriptive checkpoint commits after each cohesive working slice and its relevant checks. Do not wait for the whole milestone or Astra's final review; checkpoint commits do not imply acceptance. Keep code and its tests together; use follow-up commits for fixes, without padding commit counts or rewriting existing history.

In a shared checkout, task packets designate exactly one active Sol Git owner with an explicit path allowlist. Only that owner stages/commits; verify branch/HEAD, a clean index before staging, and that the staged diff contains only the intended owned change. Other workers can continue disjoint edits but must not mutate Git; freeze owned candidate files while checking/committing. Transfer Git ownership explicitly for their checkpoints. In an assigned private worktree, workers commit their own slices directly. Local checkpoint commits use existing task authorization and need no fresh permission. Do not use broad staging, include another worker's unfinished changes, push, switch branches, stash, reset or prune. Freeze the full candidate and serialize final integration after workers stop and Astra reviews it. Worktrees start from a recorded committed base. Record checkpoint SHAs, checks and ownership in the task ledger before handoff.

Use bounded briefs and 100–250 word receipts with changed paths, checks, evidence and limitations. Read source/diffs where review matters; do not use worker confidence as evidence. Keep repairs with the same worker; escalate after three substantive failed attempts. Do not weaken checks, accept new visual baselines or increase performance budgets silently. Do not spawn a new model call for every trivial file or poll active children repeatedly.

## Implementation and evaluation

Think like a game developer building a data-intensive app for low-end hardware: compact data, explicit ownership, reusable buffers, bounded working sets and incremental work. Keep history on disk; decode and shape visible content. Keep idle event-driven and heavy work off the UI thread. Avoid unnecessary abstraction.

Run ./tools/check for integration. Run relevant narrower tests while implementing. Preserve meaningful Unicode, parser, allocation-failure and platform regressions. Use Debug/ReleaseSafe and leak-aware test allocators; instrument C/FFI paths when investigating memory faults. Passing checks is not a proof of memory safety.

For rendered UI changes, operate the actual app on the private desktop and inspect screenshots. Use the virtual-desktop skill / vd, never the user's active desktop. Separate input testing from internal state mutation. Write evidence to ignored .artifacts/ with revision, command/build mode, scenario and limitations. Do not commit private chats, credentials or generated histories.

Serialize benchmarks; do not run them during builds, recordings or profiling. Record sample counts, p50/p95/p99, CPU, process-tree PSS and bounded-cache behavior when implemented. Present-call duration and screenshots do not measure physical input-to-photon latency. Investigate regressions instead of averaging them away.

Keep changes cohesive and reviewable. Preserve provenance of reused code. No pushing, deployment, package installation or ongoing paid background scheduler is part of a normal feature task.
