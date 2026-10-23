# Spica — native agent workspace

A fresh rewrite branch using Spica's Zig/SDL3/Clay and Unicode text foundations. T3 Code is a behavior reference. The native coding interface connects to an independent durable fake-provider Host; real Codex/OpenCode adapters are not connected.

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

The default native coding UI opens its independent fake-provider conversation:

```bash
zig-out/bin/spica --state-directory /tmp/spica-disposable-conversation
./tools/eval-starter --mode conversation --output .artifacts/conversation-NEW
```

Enter sends, Shift+Enter inserts newline, F6 cancels, F7 allows the current live
approval, F8 denies, and Ctrl+Q closes. Reopening that directory retains committed
output and run status. Ordinary launch uses `$XDG_DATA_HOME/spica-native/conversation`
(or `$HOME/.local/share/spica-native/conversation`); legacy histories are never
discovered or migrated. `--state-directory` selects isolated state explicitly.

Select the minimal user module with `--lua-module examples/minimal.lua`. F5
reloads that file; F9 switches between its root/renderer and the native default.
Invalid initial configuration keeps the default; invalid reload keeps the
last-good custom composition. Reload/root switching never restarts accepted
provider work. The native composer and its approval/cancel controls are reused.
Lua receives a bounded immutable visible transcript, not history or Host pointers.
Custom Send actions pass captured targets/revisions and a stable command ID to
the same actual public Host. `./tools/eval-starter --mode custom` exercises this
bridge with real isolated-desktop input and temporary state.

For a clean machine, run `python3 build/bootstrap.py` first. Dependencies are pinned in deps.lock.json; see [CONTRIBUTING.md](CONTRIBUTING.md).
Both check commands use local dependencies only; the core target needs the locked
libunibreak, not SDL/fonts/a display. Linux CI bootstraps the locked sources before
running the same default check. Host prerequisites are documented, not vendored;
the build is not claimed to be hermetic.

## What to build next

[ROADMAP.md](docs/ROADMAP.md) is the ordered backlog. Begin with core contracts and the deterministic fake-provider/evaluation harness. The first feature milestone is a persisted conversation with streaming, approval/cancel, restart and one minimal custom root. After that gate, add Codex with ChatGPT sign-in, then OpenCode v2; build app-owned delegation/review orchestration after runtime and workspace gates. These integrations are planned and are not connected by this scaffold.

The selected protected Lua 5.4.9 runtime exposes bounded root/renderer descriptors and explicit action proposals; native code owns actual public command admission. Users can replace the composition without owning durable work. Built-in boards and alternate workspace presets are not deliverables. See [the scripting contract](docs/contracts/scripting.md), [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [provider/orchestration design](docs/PROVIDERS_AND_ORCHESTRATION.md).

[Task records](docs/tasks/README.md) retain decisions, ownership, attempts and evidence between sessions. [EVALUATION.md](docs/EVALUATION.md) defines verification and human checkpoints.

## Recovery

Branch: `rewrite/native-agent-workspace`. The original tree is preserved at `backup/pre-native-rewrite-20261023-df45702` (base `df457029`). Inspect old code with `git show backup/pre-native-rewrite-20261023-df45702:path/to/file`; do not switch or restore while workers are running. No remote branches or existing user data are changed by this setup.
