# Codex, OpenCode and app-owned orchestration

Status: requested product scope and implementation plan. No adapter, login flow, scheduler or live model session was implemented by this document change. The current executable remains the native starter. Updated 2026-10-23.

## Integration decisions

| Layer | Initial direction | Gate |
| --- | --- | --- |
| Codex | Local `codex app-server` over stdio JSONL; use supported account/sign-in operations | Pin the CLI/schema, verify authentication, stream/approval/cancel/resume in a disposable project |
| OpenCode | Version 2; ACP is the first adapter candidate, use the v2 API only for demonstrated gaps | Negotiate exact capabilities and validate the installed version; do not reuse v1 HTTP examples |
| App orchestrator | Application-owned parent/child task state dispatches through the adapters | Fake-only scenarios first, Codex-only next, then cross-runtime |
| OMP | Development harness used to build and review this application | Preserve the existing Astra/Sol project setup |

Codex is the first real runtime after the fake-provider milestone. OpenCode is the second explicit runtime target, moved ahead of general SDK expansion. Basic orchestration is now explicit product scope, with contracts defined early and live execution gated on runtime/workspace correctness. Keep the Linux native UI independent of these transports; no JS application runtime is required just to call a JSON protocol from Zig.

## Verified integration entrypoints

On this machine, read-only help/version checks found `codex-cli 0.163.0` and `opencode v2.1.4`. These are observed versions, not dependency pins or proven account access. No auth files were read, servers started, credentials changed, logins performed or inference requested.

Codex documentation describes app-server stdio JSONL, connection initialization, thread/turn lifecycle and interruption. Its account API includes managed ChatGPT browser/device sign-in. The adapter should use supported sign-in/session handling and report the selected account/workspace without copying raw credentials into app histories or dotfiles. Subscription availability and a model listing do not establish usable entitlement. Sources: [app-server](https://learn.chatgpt.com/docs/app-server), [authentication](https://learn.chatgpt.com/docs/auth).

OpenCode v2 documents `opencode acp`, existing provider credentials, session creation/resumption, configurable model selection, streamed updates, permission requests and cancellation. Its CLI also exposes a v2 server/API. ACP is a proposed starting choice; validate the required surface before binding the application to it. Sources: [v2 ACP](https://dev.opencode.ai/v2/docs/cli/acp/), [v2 API](https://dev.opencode.ai/v2/docs/api), [v2 CLI](https://dev.opencode.ai/v2/docs/cli/).

## Shared adapter contract to define in task 001

Separate three identities: runtime instance (Codex/OpenCode), runtime-owned session/thread, and selected model/provider. Persist opaque upstream IDs alongside application IDs, version and account/profile references. Do not infer identity from a display label or the active UI tab.

Define discovery/version/capability reporting, account readiness, model/options selection, session start/resume, prompt/stream, permission/approval response, cancellation, completion and disconnect/recovery. Surface unavailable operations and transport/model mismatches explicitly. Keep original provider event identifiers for diagnostics; normalize only the events the application can faithfully represent.

Bound framing, pending requests, queues and streamed content. Correlate request/event/turn IDs; distinguish accepted requests from completed effects. Capture raw synthetic protocol fixtures and exact schema revisions. Unknown events must not crash the UI or silently turn a failed run into success. Unsupported resume/steer/review/usage behavior is a capability result, not an invented implementation.

Authentication remains owned by the supported runtime or an explicitly designed sign-in flow. A user selecting one backend/account does not authorize silently reading another tool's credentials or migrating its sessions. OMP account pooling is not automatically inherited by product adapters. Keep account/profile selection explicit and avoid changing shared runtime state merely to evaluate a fixture.

## App-owned coordinator and workers

The app orchestrator owns the delegation tree and durable dispatch decisions. Runtimes own model generation and their tool processes. Distinguish provider-native children reported by an adapter from app-managed tasks; never duplicate or double-count them.

Initial public command concepts (names illustrative, not implemented):

- `task.delegate`, `task.send`, `task.wait`, `task.cancel`, `task.list`.
- `run.start`, `run.inspect`, `run.cancel` with explicit runtime/model/options/account/workspace references.
- Review results: accepted, changes requested, failed or blocked; correlate them to the exact candidate/evidence.

A coordinator must have a real host-tool bridge to these commands. Task 001 identifies a supported runtime tool/MCP extension point; adapter tasks verify it against the pinned version. Do not treat a prompt saying "delegate" as an implementation, and do not scrape terminal prose to detect requests. Capability-gate the bridge if a required runtime surface is experimental or absent.

Each child receives a bounded task packet: parent/task IDs, purpose, owned paths, workspace/branch/base, runtime/model/effort/account reference, acceptance scenarios, budget and evidence/result location. A result links the actual candidate and checks. A configurable Astra-coordinator/Sol-worker policy is one user workflow; model names are not hardcoded into the scheduler.

Start with two concurrent children, no recursive fan-out, and a finite task/request/time budget. Aggregate available usage across the tree without treating cached input, native children or repeated notifications as new work. Distinguish recorded usage/cost estimates from actual subscription billing; enforce the bounds the runtime can observe and label the others best effort. Stop on unexpected model fallback rather than intentionally replacing a worker with a different model.

Use disjoint owned files or explicitly assigned worktrees. Path ownership alone does not isolate shell access. Serialize staging/commits and workspace-changing operations. Provider permission requests stay pending until the applicable policy answers them; delegation does not grant execution rights. Freeze a candidate for review and performance measurement.

Default parent cancellation requests cancellation of attached children; explicit detached work has separate ownership/lifecycle. Closing a view or reloading configuration does not cancel accepted work. Persist parent/child relationships, dispatch intent and upstream session mappings before effects; reconcile saved state after restart. An ambiguous spawn/result recovers as unknown/interrupted, without automatically repeating it.

## Acceptance sequence

1. Fake-only: two children complete out of order; one fails and is repaired/reviewed. Verify duplicate delegate handling, pending approval, cancellation propagation, detached ownership, budget exhaustion and crash/restart without duplicate dispatch.
2. Codex-only: real parent/child sessions with the host-tool bridge, recorded model/options/workspace, streamed activity, approval/cancel and checked results in a disposable project.
3. Mixed runtimes: one parent delegates to both Codex and OpenCode; preserve capability differences, permission routing and independent failure/cancel/resume behavior. Do not expand to more providers before this passes.
4. Native UI: expose task tree, progress, results and review through public queries/commands. Custom layouts can replace the presentation without changing execution ownership. Measure the complete runtime process tree and record functional screenshots separately from timings.

No unattended recurring runner, public deployment, account switching policy, additional provider or universal workflow language is implied by this scope. Source-guided implementation begins with the pinned T3 checkout and contract review in task 001.
