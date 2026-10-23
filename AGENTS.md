# Spica native workspace rewrite

Read README.md, docs/ROADMAP.md and your task record before working. This branch is a new application foundation, not the old Pi chat client. Do not restore deleted application code wholesale to make a check pass.

## Product boundaries

- Linux first; Zig 0.16, SDL3, Clay and the retained native text/content libraries. Keep OS mechanics behind platform boundaries.
- One useful default coding interface, composed through public primitives. Users can replace the root, renderers, commands, input and styling. Do not add built-in kanban boards or alternate workspace presets.
- Domain execution owns projects, threads, runs and durable commands/events. UI state and configuration reload must not own provider lifetimes.
- Keep scripting contracts independent of runtime choice; select one runtime with a small proof before adding bindings. Lua and QuickJS are candidates, not commitments.
- GPU rendering is the starting path. SHM investigation is deferred and is not a task or acceptance gate.
- Do not read or migrate existing Spica/T3 histories or credentials implicitly. Fixtures use temporary, separate state. OMP is the development harness, not a selected product provider backend.

## Agent workflow

The main OMP chat is GPT-6 Astra: coordinate, decide interfaces, inspect actual changes and evidence. GPT-6.1 Sol workers implement, investigate, run checks, collect UI/performance evidence and repair failures. See docs/AGENT_LOOP.md and project agents in .omp/.

Start with two workers; at most three. Assign explicit file ownership and acceptance gates; shared contracts have one owner. Shared checkout workers do not stage, commit, switch branches or edit another worker's paths during feature work. After all other workers stop and the candidate is reviewed, Astra may assign one Sol integration packet with exact paths/base/branch for targeted staging, a local commit and affected checks. This exception uses existing task authorization; it does not grant push, destructive Git actions or broad cleanup rights. Astra serializes and reviews integration. Worktrees must start from a committed base; uncommitted files are not inherited. Keep a task record in docs/tasks before dispatch and update it before finishing.

Use bounded briefs and 100–250 word receipts with changed paths, checks, evidence and limitations. Read source/diffs where review matters; do not use worker confidence as evidence. Keep repairs with the same worker; escalate after three substantive failed attempts. Do not weaken checks, accept new visual baselines or increase performance budgets silently. Do not spawn a new model call for every trivial file or poll active children repeatedly.

## Implementation and evaluation

Think like a game developer building a data-intensive app for low-end hardware: compact data, explicit ownership, reusable buffers, bounded working sets and incremental work. Keep history on disk; decode and shape visible content. Keep idle event-driven and heavy work off the UI thread. Avoid unnecessary abstraction.

Run ./tools/check for integration. Run relevant narrower tests while implementing. Preserve meaningful Unicode, parser, allocation-failure and platform regressions. Use Debug/ReleaseSafe and leak-aware test allocators; instrument C/FFI paths when investigating memory faults. Passing checks is not a proof of memory safety.

For rendered UI changes, operate the actual app on the private desktop and inspect screenshots. Use the virtual-desktop skill / vd, never the user's active desktop. Separate input testing from internal state mutation. Write evidence to ignored .artifacts/ with revision, command/build mode, scenario and limitations. Do not commit private chats, credentials or generated histories.

Serialize benchmarks; do not run them during builds, recordings or profiling. Record sample counts, p50/p95/p99, CPU, process-tree PSS and bounded-cache behavior when implemented. Present-call duration and screenshots do not measure physical input-to-photon latency. Investigate regressions instead of averaging them away.

Keep changes cohesive and reviewable. Preserve provenance of reused code. No pushing, deployment, package installation or ongoing paid background scheduler is part of a normal feature task.
