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
