# 008: OpenCode v2 adapter

Status: running — parallel adapter implementation authorized explicitly by user; live parity acceptance follows concrete Codex/conformance evidence.
Owner: OpenCodeShip008 owns only OpenCode-specific adapter/protocol/fixture code and this task record; no shared Git mutation. CodexShip007 owns common transport/build and serialized checkpoints.
Base: `301e8e35899f9c1aeb2005b220e72c55c9fa178f`, shared checkout. Own `src/runtime/opencode*`, OpenCode-specific fixture/smoke files and `docs/contracts/opencode.md`; do not edit common/domain/native files.
Dependencies: reviewed automated fake/native milestone and pinned core contracts. Consume the adapter interface published by CodexShip007; report actual v2 capability differences, never assume parity or claim live acceptance before execution.

Scope: use the pinned OpenCode v2 interface. Evaluate ACP first; use the v2 API for demonstrated gaps, keeping protocol differences inside the adapter. The observed local CLI is v2.1.4; v1 server examples are not a contract. Respect explicit provider/model/account/workspace selection and existing supported authentication flows.

Acceptance: negotiated capabilities, session start/resume, streamed text/tool activity, permission routing, cancellation and error/exit behavior; same application conformance scenarios as Codex where supported. Capture real differences instead of claiming parity. Verify the orchestrator host-tool bridge. Do not change the user's shared background service, account activation or global configuration for a fixture. Missing capabilities return explicit errors.

Attempts/result/evidence: native integration evidence is recorded below; final acceptance remains Astra's review.

Current continuation: RuntimeFactoryLead.NativeBridgeConsumer holds reserved
slot3 for actual provider/MCP/native consumer work; RuntimeFactoryLead retains
sole shared Git ownership. OpenCodeShip008's finite inference handoff is
`365b59e`; factory/registration integration is `9a1d025`. Helper tests passed
4/4 and runtime tests 13/13 in Debug and ReleaseSafe, raw evidence under
`.artifacts/provider-factory/opencode-bridge/`. Actual endpoint tool acceptance
remains separate. User-authorized finite budgets: 60 minutes, 200 requests soft,
300 forced; no extra descendants or background scheduler.

Actual provider/factory/bridge checkpoints: `8d5df8d`, `efe442f`, `4682481`.
Installed ACP 2.1.4 negotiated exact `opencode/big-pickle` with isolated managed
state. Two actual sessions/process IDs and finite buffers remained independent:
cancel/shutdown/destroy first, then second completed `SPICA_FACTORY_SURVIVOR`;
failed-process creation was cleaned with the DebugAllocator. Corrected `/tmp`
workspace cohort evidence: `consumer/factory-manifest-5.json`, `factory-run-5.log`
under `.artifacts/provider-factory/`.

Real Host4 MCP Code Mode callback created one durable child, produced
`SPICA_MCP_CHILD_OK`, committed its observed public structured result, and
reopened the exact task/result without restarting a provider. Raw command,
binary/environment/source identities and rows: `consumer/host-manifest-4.json`,
`host-run-4.log`, `host-durable-4.json`. Earlier schema-error and no-callback
cohorts remain evidence, not relabeled passes. Codex/OpenCode simultaneous
handshake/OpenCode inference passed in a single explicitly mixed factory;
Codex was unsigned and performed no inference. Native desktop and live
permission interaction are separate remaining evidence gates.
