# Spica — native agent workspace

A fresh rewrite branch using Spica's Zig/SDL3/Clay and Unicode text foundations. T3 Code is a behavior reference. The native coding interface uses a durable Host with session-scoped fake, Codex app-server and OpenCode ACP factories; real-provider use requires explicit runtime/account/model/workspace selection.

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

For a short manual test, send a Unicode prompt, exercise approval/cancel, then
create another chat from the sidebar and check that switching restores your draft.
Close and reopen with the same state directory to check retained output. The
default provider is a synthetic fixture; use an explicit real provider below for
an actual coding task.

Select the minimal user module with `--lua-module examples/minimal.lua`. F5
reloads that file; F9 switches between its root/renderer and the native default.
Invalid initial configuration keeps the default; invalid reload keeps the
last-good custom composition. Reload/root switching never restarts accepted
provider work. The native composer and its approval/cancel controls are reused.
Lua receives a bounded immutable visible transcript, not history or Host pointers.
Custom Send actions pass captured targets/revisions and a stable command ID to
the same actual public Host. `./tools/eval-starter --mode custom` exercises this
bridge with real isolated-desktop input and temporary state.

### Explicit native providers and mixed-runtime children

Codex targets app-server **0.163.0** and supported ChatGPT sign-in; OpenCode
targets **2.1.4** ACP. Create a disposable absolute workspace and use separate
managed account directories. No OMP credentials or old histories are imported.
For OpenCode alone, with an already authorized isolated OpenCode Go account:

```bash
zig-out/bin/spica --provider opencode \
  --runtime-executable /absolute/path/to/opencode \
  --runtime-account-directory /tmp/spica-opencode-account \
  --model-provider opencode-go --model gpt-6-luna --effort default \
  --workspace /tmp/spica-disposable-project \
  --state-directory /tmp/spica-opencode-conversation
```

Create the workspace directory first. Configured real runtimes discover their
models on launch without sending a prompt. An explicit `--model` / `--effort`
selection is retained exactly; without those flags, choose a model beside the
composer. The adjacent effort control cycles through that model's actual options.
Sending starts real provider work in the selected workspace. **Connection** lets
you edit the configured paths, refresh discovery or initiate Codex sign-in; the
composer explains why sending is unavailable. Choose IDs from your actual
account's catalog; the example requires access to that model. Reuse the same
arguments to reopen your test conversation. Temporary account/project/state
directories must remain available for that session.

For an OpenCode coordinator with an explicitly authorized Codex child runtime:

```bash
zig-out/bin/spica --provider opencode \
  --runtime-executable /absolute/path/to/opencode \
  --runtime-account-directory /tmp/spica-opencode-account \
  --model-provider opencode --model big-pickle --effort default \
  --workspace /tmp/spica-disposable-project \
  --state-directory /tmp/spica-mixed-conversation \
  --additional-provider codex \
  --additional-runtime-account-directory /tmp/spica-codex-account \
  --additional-model-provider openai \
  --additional-runtime-executable /usr/bin/codex
```

Use the actual absolute executable locations. Swap the primary and additional
providers for a Codex coordinator. Child packets name the authorized runtime,
model provider and canonical account directory, an explicit model/effort, and a
registered workspace. Model/effort are never silently copied or substituted.
The Host bounds one coordinator and two children with independent process state.

The workspace may be a newly initialized Git repository with no commit (`git init`
is sufficient). Spica retains its actual symbolic branch and checkout identity;
creating the first commit or changing that branch invalidates an earlier captured
workspace binding. Broken Git metadata remains an error, not a non-Git workspace.

Before Codex inference, sign in to the **same selected Codex directory**:

```bash
zig-out/bin/spica --provider codex \
  --runtime-account-directory /tmp/spica-codex-account \
  --model-provider openai --model gpt-6.1-sol --effort medium \
  --workspace /tmp/spica-disposable-project --codex-auth device
```

`browser` selects supported browser sign-in; `status` queries that isolated
account. Initiation prints the runtime's actual URL/code and waits up to two
minutes. A ready account and entitlement to the explicit model are prerequisites,
not inferred from installed software. The pinned OpenCode version needs explicit
`OPENCODE_CONFIG_DIR` and its installed home override `OPENCODE_TEST_HOME` to keep
global discovery within the selected account; native startup supplies both and
disables Claude configuration discovery. This is not a filesystem sandbox.
Cold concurrent OpenCode account bootstrap can fail on upstream SQLite locking;
failures remain visible rather than retrying external work.

For a clean machine, run `python3 build/bootstrap.py` first. Dependencies are pinned in deps.lock.json; see [CONTRIBUTING.md](CONTRIBUTING.md).
Both check commands use local dependencies only; the core target needs the locked
libunibreak, not SDL/fonts/a display. Linux CI bootstraps the locked sources before
running the same default check. Host prerequisites are documented, not vendored;
the build is not claimed to be hermetic.

### Installed-provider orchestration gate

Build the opt-in consumer with
`python3 build/driver.py build-orchestration-smoke -Doptimize=Debug`, then run
`zig-out/bin/orchestration-smoke CONFIG.json REPORT.json`. This performs real
inference: the first runtime coordinates one child per configured runtime through
the app's tools. It checks exact effective selections, child output, structured
result/review commands, and a read-only reopen without a provider factory.
It does not run as part of `./tools/check`.

Supply explicit absolute executable/account/workspace/state paths, actual model
IDs and supported efforts. The state directory must be fresh; the account
directories must already exist, and Codex must be signed in through its supported
flow. Existing credentials may be used only when explicitly authorized. No
credentials belong in this configuration or report. For example:

```json
{
  "workspace": "/tmp/spica-disposable-project",
  "state_directory": "/tmp/spica-orchestration-new-state",
  "candidate": "revision-and-source-fingerprint-under-test",
  "runtimes": [
    {
      "kind": "codex",
      "executable": "/usr/bin/codex",
      "account_directory": "/tmp/spica-codex-account",
      "model_provider": "openai",
      "model": "gpt-6.1-sol",
      "effort": "medium"
    },
    {
      "kind": "opencode",
      "executable": "/absolute/path/to/opencode",
      "account_directory": "/tmp/spica-opencode-account",
      "model_provider": "opencode",
      "model": "big-pickle",
      "effort": "default"
    }
  ]
}
```

Use one entry to exercise a single provider. The gate neither changes shared
accounts nor imports histories. It stops on failed/ambiguous runs and keeps their
durable state for inspection; a model listing alone never establishes access.

## What to build next

[ROADMAP.md](docs/ROADMAP.md) is the ordered backlog. The durable conversation, protected custom-root bridge, native provider factories and bounded orchestration are implemented in the current shipping loop. Task records distinguish compiled/protocol/consumer evidence from live authenticated provider and human acceptance; absent Codex sign-in or model entitlement is not a successful mixed inference run.

The selected protected Lua 5.4.9 runtime exposes bounded root/renderer descriptors and explicit action proposals; native code owns actual public command admission. Users can replace the composition without owning durable work. Built-in boards and alternate workspace presets are not deliverables. See [the scripting contract](docs/contracts/scripting.md), [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [provider/orchestration design](docs/PROVIDERS_AND_ORCHESTRATION.md).

[Task records](docs/tasks/README.md) retain decisions, ownership, attempts and evidence between sessions. [EVALUATION.md](docs/EVALUATION.md) defines verification and human checkpoints.

## Recovery

Branch: `rewrite/native-agent-workspace`. The original tree is preserved at `backup/pre-native-rewrite-20261023-df45702` (base `df457029`). Inspect old code with `git show backup/pre-native-rewrite-20261023-df45702:path/to/file`; do not switch or restore while workers are running. No remote branches or existing user data are changed by this setup.
