# Spica — native agent workspace

A fresh rewrite branch using Spica's Zig/SDL3/Clay and Unicode text foundations. T3 Code is a behavior reference. The native coding interface uses a durable Host with session-scoped fake, Codex app-server and OpenCode ACP factories; ordinary launch configures providers in the app and remembers the connection and per-thread model selection.

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

Launch normally—no provider flags are required:

```bash
zig-out/bin/spica
```

On first launch, choose **Codex** or **OpenCode**, confirm your existing project
folder, then **Connect & discover**. Codex reuses your existing login from
`$CODEX_HOME` (normally `~/.codex`); it does not need a second sign-in when that
account is already authorized. Existing saved account paths are kept exactly;
**Use existing Codex** switches an old isolated connection to the launch account
and discovers its models. **Advanced** lets you choose a different account.
Codex browser/device sign-in is available when the chosen account needs it.
OpenCode defaults to a separate managed directory. Sign-in and Refresh apply
the displayed provider/account/workspace fields before proceeding; you can
start Codex sign-in directly. Pending actions are visibly disabled and failures
appear inside the setup panel. OpenCode currently needs
an already authorized account directory selected in Advanced; its sign-in is
not implemented in Spica. Spica does not copy credentials or import existing histories.
Choose an actual model beside the composer after discovery, then its effort.
The app remembers successful connection settings and exact per-thread choices.
Later launches restore the configured workspace and discover models without
sending a prompt. **Connection** in the sidebar reopens setup.
Interrupted or uncertain old runs retain their status without blocking provider
setup. Open a new chat to continue; the old work is never automatically retried.

Enter sends, Shift+Enter inserts newline, F6 cancels, F7 allows the current live
approval, F8 denies, and Ctrl+Q closes. The sidebar supports loaded-thread title
search and project scope. Switching chats retains drafts, selection and undo.
Ordinary launch stores independent app state under
`$XDG_DATA_HOME/spica-native/conversation` (or
`$HOME/.local/share/spica-native/conversation`); `--state-directory` overrides it.

For offline testing, explicitly choose the synthetic provider:

```bash
zig-out/bin/spica --provider fake --state-directory /tmp/spica-disposable-conversation
./tools/eval-starter --mode conversation --output .artifacts/conversation-NEW
./tools/eval-provider-setup --output .artifacts/provider-setup/native-NEW
```

The provider-setup evaluator operates the actual app on a private desktop with
an isolated data directory and offline protocol fixtures. It tests fresh launch,
provider drafts, errors, device-code completion, model selection, Send and
restart, without external authentication or paid inference.

Select the minimal user module with `--lua-module examples/minimal.lua`. F5
reloads that file; F9 switches between its root/renderer and the native default.
Invalid initial configuration keeps the default; invalid reload keeps the
last-good custom composition. Reload/root switching never restarts accepted
provider work. The native composer and its approval/cancel controls are reused.
Lua receives a bounded immutable visible transcript, not history or Host pointers.
Custom Send actions pass captured targets/revisions and a stable command ID to
the same actual public Host. `./tools/eval-starter --mode custom` exercises this
bridge with real isolated-desktop input and temporary state.

Customize the full native conversation with the same presentation API:

```bash
zig-out/bin/spica --state-directory /tmp/spica-themed-conversation \
  --lua-module examples/t3-theme.lua
```

The example returns a `native` root with `design.colors` and `design.layout`.
Edit its colors, sidebar/content widths, spacing or corner radius, then press F5.
F9 restores the default presentation and switches back without restarting work.
Invalid settings retain the complete last working interface. Custom row/column
roots can also set node `style` values for size, spacing, font and paint.
Native consumers call `App.configurePresentation(Config)` on the App thread;
the settings are validated and copied together before painting. Lua is the local
configuration/scripting interface, in the spirit of editor configuration. The
[architecture](docs/ARCHITECTURE.md) explains the layers and remaining T3 parity
work; the [scripting contract](docs/contracts/scripting.md) lists exact fields and
bounds. `./tools/eval-starter --mode presentation` exercises native theme reload,
rejection, run preservation and restart through actual private-desktop input.

### Explicit native providers and mixed-runtime children

Codex targets app-server **0.163.0** and supported ChatGPT sign-in; OpenCode
targets **2.1.4** ACP. Create a disposable absolute workspace; explicit account directories remain supported.
Codex uses the selected account through its installed app-server, with app-owned
stdio/process lifetime. It does not take over another client’s running stdio server.
No credentials are copied and old histories are not imported.
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
composer. The adjacent effort control opens that model's actual options.
Sending starts real provider work in the selected workspace. **Connection** lets
you edit the configured paths, refresh discovery or initiate Codex sign-in; the
composer explains why sending is unavailable. Choose IDs from your actual
account's catalog; the example requires access to that model. Use plain launch with the same state directory after saving the connection
in the panel, or retain explicit launch arguments for a disposable CLI session. Temporary account/project/state
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

Start with the [native rewrite completion plan and checklist](docs/NATIVE_REWRITE_PLAN.md).
The 2026-10-26 source audit prioritizes diagnosable Codex Send, provider session
continuity, a reusable GUI-driving CLI and missing daily coding workflows.
It distinguishes existing implementation from end-to-end acceptance; it does
not claim the reported failed prompt has been reproduced or repaired.

[ROADMAP.md](docs/ROADMAP.md) is the ordered backlog. The durable conversation, protected custom-root bridge, native provider factories and bounded orchestration are implemented in the current shipping loop. Task records distinguish compiled/protocol/consumer evidence from live authenticated provider and human acceptance; absent Codex sign-in or model entitlement is not a successful mixed inference run.

The selected protected Lua 5.4.9 runtime exposes bounded root/renderer descriptors and explicit action proposals; native code owns actual public command admission. Users can replace the composition without owning durable work. Built-in boards and alternate workspace presets are not deliverables. See [the scripting contract](docs/contracts/scripting.md), [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [provider/orchestration design](docs/PROVIDERS_AND_ORCHESTRATION.md).

[Task records](docs/tasks/README.md) retain decisions, ownership, attempts and evidence between sessions. [EVALUATION.md](docs/EVALUATION.md) defines verification and human checkpoints.

## Recovery

Branch: `rewrite/native-agent-workspace`. The original tree is preserved at `backup/pre-native-rewrite-20261023-df45702` (base `df457029`). Inspect old code with `git show backup/pre-native-rewrite-20261023-df45702:path/to/file`; do not switch or restore while workers are running. No remote branches or existing user data are changed by this setup.
