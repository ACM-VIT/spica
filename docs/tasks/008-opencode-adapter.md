# 008: OpenCode v2 adapter

Status: blocked — prerequisite feature gates are not implemented; do not dispatch yet.
Owner: Sol adapter worker; Astra reviews transport/capability differences.
Base/owned paths: record the exact accepted base and allocate concrete adapter/fixture paths before dispatch.
Dependencies: contracts 001, fake conformance harness and Codex adapter gate 007. Read-only fixture preparation can proceed earlier only with assigned paths and frozen contracts.

Scope: use the pinned OpenCode v2 interface. Evaluate ACP first; use the v2 API for demonstrated gaps, keeping protocol differences inside the adapter. The observed local CLI is v2.1.4; v1 server examples are not a contract. Respect explicit provider/model/account/workspace selection and existing supported authentication flows.

Acceptance: negotiated capabilities, session start/resume, streamed text/tool activity, permission routing, cancellation and error/exit behavior; same application conformance scenarios as Codex where supported. Capture real differences instead of claiming parity. Verify the orchestrator host-tool bridge. Do not change the user's shared background service, account activation or global configuration for a fixture. Missing capabilities return explicit errors.

Attempts/result/evidence: none; future task packet.
