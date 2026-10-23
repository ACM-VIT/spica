# Spica — native agent workspace

A fresh rewrite branch using Spica's Zig/SDL3/Clay and Unicode text foundations. T3 Code is a behavior reference. The old Pi-specific application has been removed. The current native draft surface is not a connected agent client; domain integration and rendered acceptance remain in progress.

## Start the development loop

```bash
cd /home/ashman/Documents/spica
./tools/agents
```

This starts the OMP Astra coordinator with Sol worker definitions. It uses your existing OMP accounts; no new profile or credentials are created. Read [the agent loop](docs/AGENT_LOOP.md) for model routing, resuming and task handoffs. The loop runs in the chat you start; no daemon or recurring paid runner is installed.

```bash
python3 build/driver.py          # build (existing local dependencies)
python3 build/driver.py run      # native starter window
./tools/check                   # formatting, Debug/ReleaseSafe builds + regressions + CLI smoke
./tools/check --core            # isolated Unicode/core checks in both safety modes
./tools/eval-starter --mode editor # private Unicode/clipboard/focus input scenario
```

For the native durable fake-provider coding flow, explicitly choose separate state:

```bash
zig-out/bin/spica --state-directory /tmp/spica-disposable-conversation
./tools/eval-starter --mode conversation --output .artifacts/conversation-NEW
```

Enter sends, Shift+Enter inserts newline, F6 cancels, F7 allows the current live
approval, F8 denies, and Ctrl+Q closes. Reopening that directory retains committed
output and run status. Without `--state-directory`, only the local draft editor
opens; no existing history is discovered or migrated.

For a clean machine, run `python3 build/bootstrap.py` first. Dependencies are pinned in deps.lock.json; see [CONTRIBUTING.md](CONTRIBUTING.md).
Both check commands use local dependencies only; the core target needs the locked
libunibreak, not SDL/fonts/a display. Linux CI bootstraps the locked sources before
running the same default check. Host prerequisites are documented, not vendored;
the build is not claimed to be hermetic.

## What to build next

[ROADMAP.md](docs/ROADMAP.md) is the ordered backlog. Begin with core contracts and the deterministic fake-provider/evaluation harness. The first feature milestone is a persisted conversation with streaming, approval/cancel, restart and one minimal custom root. After that gate, add Codex with ChatGPT sign-in, then OpenCode v2; build app-owned delegation/review orchestration after runtime and workspace gates. These integrations are planned and are not connected by this scaffold.

The API should expose commands, queries, subscriptions and composable native UI/input primitives so people can share their own configuration. A full replacement root and custom renderers are required; built-in boards and other alternative interfaces are not deliverables. Runtime selection and API details remain open until the proof. See [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [provider/orchestration design](docs/PROVIDERS_AND_ORCHESTRATION.md).

[Task records](docs/tasks/README.md) retain decisions, ownership, attempts and evidence between sessions. [EVALUATION.md](docs/EVALUATION.md) defines verification and human checkpoints.

## Recovery

Branch: `rewrite/native-agent-workspace`. The original tree is preserved at `backup/pre-native-rewrite-20261023-df45702` (base `df457029`). Inspect old code with `git show backup/pre-native-rewrite-20261023-df45702:path/to/file`; do not switch or restore while workers are running. No remote branches or existing user data are changed by this setup.
