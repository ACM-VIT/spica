# Spica — native agent workspace

A fresh rewrite branch using Spica's Zig/SDL3/Clay and Unicode text foundations. T3 Code is a behavior reference. The old Pi-specific application has been removed from this branch; the runnable starter is a foundation, not a working agent client yet.

## Start the development loop

```bash
cd /home/ashman/Documents/spica
./tools/agents
```

This starts the OMP Astra coordinator with Sol worker definitions. It uses your existing OMP accounts; no new profile or credentials are created. Read [the agent loop](docs/AGENT_LOOP.md) for model routing, resuming and task handoffs. The loop runs in the chat you start; no daemon or recurring paid runner is installed.

```bash
python3 build/driver.py          # build (existing local dependencies)
python3 build/driver.py run      # native starter window
./tools/check                   # formatting, build and regressions
./tools/eval-starter            # private desktop screenshot + Escape smoke check
```

For a clean machine, run `python3 build/bootstrap.py` first. Dependencies are pinned in deps.lock.json; see [CONTRIBUTING.md](CONTRIBUTING.md).

## What to build next

[ROADMAP.md](docs/ROADMAP.md) is the ordered backlog. Begin with core contracts and the deterministic fake-provider/evaluation harness. The first feature milestone is a persisted conversation with streaming, approval/cancel, restart and one minimal custom root. After that gate, add Codex with ChatGPT sign-in, then OpenCode v2; build app-owned delegation/review orchestration after runtime and workspace gates. These integrations are planned and are not connected by this scaffold.

The API should expose commands, queries, subscriptions and composable native UI/input primitives so people can share their own configuration. A full replacement root and custom renderers are required; built-in boards and other alternative interfaces are not deliverables. Runtime selection and API details remain open until the proof. See [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [provider/orchestration design](docs/PROVIDERS_AND_ORCHESTRATION.md).

[Task records](docs/tasks/README.md) retain decisions, ownership, attempts and evidence between sessions. [EVALUATION.md](docs/EVALUATION.md) defines verification and human checkpoints.

## Recovery

Branch: `rewrite/native-agent-workspace`. The original tree is preserved at `backup/pre-native-rewrite-20261023-df45702` (base `df457029`). Inspect old code with `git show backup/pre-native-rewrite-20261023-df45702:path/to/file`; do not switch or restore while workers are running. No remote branches or existing user data are changed by this setup.
