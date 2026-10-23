# 007: Codex with ChatGPT sign-in

Status: running — user explicitly requested production Codex, OpenCode and orchestration in parallel after the reviewed automated fake/native milestone.
Owner: CodexShip007 owns Codex, common transport/adapter plumbing and build/startup integration; sole shared Git owner for explicitly assigned checkpoint paths. Astra retains contract decisions and final acceptance.
Base: `301e8e35899f9c1aeb2005b220e72c55c9fa178f`, shared checkout. Own `src/runtime/codex*`, `src/runtime/transport*`, `src/runtime/adapter.zig`, existing `src/platform/process*`, `build.zig`, `src/test.zig`, `src/main.zig`, `src/options.zig`, this task record and Codex-specific contract/fixture files.
Dependencies: automated milestone004–006 reviewed; human feedback and live account entitlement remain distinct gates, not blockers to implementation. Publish common adapter interface directly to OpenCodeShip008 and OrchestratorShip012 before callers depend on it.

Scope: implement the pinned Codex app-server adapter and supported ChatGPT sign-in/session handling from docs/PROVIDERS_AND_ORCHESTRATION.md. Validate installed-version schema rather than assuming the newest docs match it. Keep account state separate from histories/config and preserve explicit model/effort/workspace identity.

Acceptance: synthetic framing/error/capability tests; disposable-project stream, tool approval, cancellation, completion and reopen; honest auth/permission/model errors; application IDs map to upstream sessions. Verify the supported coordinator host-tool/MCP bridge before claiming app delegation works. Record real inference usage and exact commands; no scraping the ChatGPT website or copying OMP credentials. Live account use is a separate acceptance run, not a configuration-validation shortcut.

Attempts/result/evidence: none; future task packet.

## Recovery checkpoint — ProviderLeadRecover

Recovered private `task/007-codex` at `38043e9`; preserved and checkpointed the
previously checked protocol candidate as `0f644f0` without rerunning its installed
handshake/account probe. Its unpublished options candidate remains preserved.
Shared integrations: common transport `96d7f40`, Codex/OpenCode producer union
`7f17b88` (OpenCode `845eb97` + `5ecdc01`), measured presentation repair
`2d1b64e` from verified `841ab0e`, checked Host seam `e42be01` from `368481b`.
Main's existing allocation records were retained.

The current followup adds optional common tool-call polling/responses, real
Codex forwarding and correlation tests, and separates absolute `Config.cwd`
from opaque public workspace IDs. Focused Codex check: 3 passed, 1 intentionally
skipped installed probe; prior real protocol evidence is not confirmation-rerun.

Native startup candidate consumes explicit provider/account/model/effort/root,
retains runtime until Host destruction, supplies isolated environment, and
supports bounded browser/device sign-in plus status. Actual Debug build passed;
actual native isolated status reported sign-in required. Options 5/5 passed;
`zig build test-domain` passed with the domain owner's authorized workspace-root/
unknown-readiness guard fragment. Logs: `.artifacts/provider-recovery/`.

OpenCodeShip008 owns the matching Config.cwd/provider/actual Host consumer
followup in reserved slot3; OrchestratorShip012 owns task schema/bridge/MCP in
slot1. Neither runtime-only proof nor compilation is native workflow acceptance.
Combined tools/check, actual provider desktop smoke, completed ChatGPT sign-in,
authenticated inference and durable app-task dynamic-call/MCP acceptance remain
open. No credentials, private account history or model entitlement were copied
or claimed. Requested/resolved model: openai-codex/gpt-6.1-sol; default tier.

## Session factory recovery — RuntimeFactoryLead

The common ABI now exposes side-effect-free factory metadata and session-scoped
creation with exact selection, absolute cwd, durable session ID and optional
Host-owned authenticated MCP endpoint. Unknown pre-instance readiness is not
authentication evidence. A successful create transfers one adapter to the Host;
the Host shuts it down exactly once before factory memory-only destruction.
Failed creation retains no process or allocation. Registry/native integration
and actual provider bridge acceptance are tracked separately from this seam.
Focused common-seam check: `zig build test-domain` exited 0.

Concrete factory candidate allocates a final-address adapter and dedicated
bounded transport per session; each instance retains its own selection, cwd,
session identity and tool metadata. A two-instance `/bin/cat` process fixture
proved distinct process IDs/context and stopping one leaves the other owned
instance intact; failed spawn/exact-selection rejection used the leak-aware
test allocator. `zig test src/provider_factory_test.zig
src/platform/process_posix.c src/platform/process_linux.c -lc -I src -I
src/platform`: 6/6 passed. This is process-lifetime evidence, not authenticated
provider cancellation/inference or native task acceptance. Raw observed output:
`.artifacts/provider-factory/factory-check.log`.

Current owner RuntimeFactoryLead holds slot2 and sole shared Git integration.
The user-authorized finite worker budgets are 60 minutes, 200 requests soft,
300 forced; project configuration is propagated before replacement dispatch.
Native startup remains an identified candidate until the domain factory seam
and actual provider/native checks are assembled; checkpointing the concrete
factory alone is not acceptance.

Follow-up factory coverage adds an actual surviving-session pipe exchange
after stopping its peer and exhaustive allocation-failure injection for both
Codex and OpenCode creation with tool/endpoint metadata. Same focused command:
7/7 passed with the leak-aware allocator. This still does not substitute for a
provider turn cancellation or authenticated native workflow.

Pre-open discovery distinguishes compiled protocol support from negotiated
readiness: implemented create/start/stream operations are supported metadata
without process IO; account/effective selection remain unknown until handshake.
Unsupported messaging is not advertised. A focused metadata regression confirms
this admission contract; the same 7-test consumer command passed.

The real-process independence scenario now runs through **both** concrete
factories, including OpenCode's final-address inline allocator ownership. Each
surviving instance exchanges a pipe frame after its peer stops; teardown is
also protected on failed test assertions. Focused consumer: 7/7 passed.

Published domain factory/registry seam `9a822cc` is integrated with the actual
native startup candidate: Host receives the held factory rather than a
precreated singleton, including the ordinary conversation path. `zig build
-Doptimize=Debug` passed on the assembled seam. Explicit native provider flags
and isolated Codex auth handling are preserved; actual mixed runtime account
configuration and provider/desktop consumer evidence remain distinct work.

Mixed startup now accepts one explicitly authorized additional native runtime
and separate canonical managed account. The bounded factory routes by exact
runtime/version/model-provider/account identity; child model and effort remain
explicit and are retained unchanged for handshake verification. Native options
6/6, mixed factory/lifetime tests 8/8, and the Debug native build passed.
OpenCode's pinned installed home override and explicit config directory are
set separately from Codex's managed home; neither authorizes another tool's auth.

Native auth status now preserves a real account/read RPC diagnostic instead of
mislabeling that failure as ordinary missing sign-in. Debug native build passed;
the actual executable driven by a synthetic app-server error fixture exited 1,
printed the supplied diagnostic and `AccountStatusFailed`, and did not print
“sign-in required.” Reproduction/evidence:
`.artifacts/provider-factory/native-auth/error.py` and `account-error.log`.

Actual rebuilt native `--codex-auth device` initiated the supported ChatGPT
device flow in a fresh managed account and printed a real verification URL and
user code. With no interactive sign-in, it exited `SignInIncomplete` at its
120-second bound; this is a usable initiation, not authenticated inference.
Raw command/candidate/output: `.artifacts/provider-factory/native-auth/manifest.json`
and `device.log`. The same mixed factory also ran installed Codex initialize/
account-read and real OpenCode inference simultaneously with distinct account
roots and verified `/proc` cwd identities; see consumer `mixed-manifest-2.json`
and `mixed-run-2.log`. Codex remained signed out and performed no inference.

Assembled integration gate: formatting checked 89 sources; Debug native build,
124/126 Zig tests (2 intentionally skipped), Python 35 tests (2 skipped) and
native CLI smoke passed. ReleaseSafe initially exposed the MCP fortified-header
C-import failure; the owner replaced the unnecessary header with `std.c.fcntl`
without disabling fortify (`4dabfc3`). The affected ReleaseSafe native build,
same 124/126 Zig tests, Python tests and CLI smoke then all exited 0. Raw gate
and repair provenance: `.artifacts/provider-factory/final-check.log`,
`final-check-failure.json`, `release-check.log`, `release-check.json`.

Final allocation coverage also injects every allocator failure through successful
owned process spawn and subsequent runtime initialization, rather than stopping
at missing-executable failure. Both concrete factories clean partial transport/
runtime allocations and process ownership. Focused factory consumer: 9/9 passed
with the leak-aware allocator; no real provider inference in this fixture.
