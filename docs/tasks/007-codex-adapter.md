# 007: Codex with ChatGPT sign-in

Status: blocked — prerequisite feature gates are not implemented; do not dispatch yet.
Owner: Sol adapter worker; Astra reviews identity, permissions and lifecycle.
Base/owned paths: record the exact accepted base and allocate concrete adapter/fixture paths before dispatch.
Dependencies: contracts 001 and the shared fake-provider/persistence/UI/API milestone (ROADMAP 2–6).

Scope: implement the pinned Codex app-server adapter and supported ChatGPT sign-in/session handling from docs/PROVIDERS_AND_ORCHESTRATION.md. Validate installed-version schema rather than assuming the newest docs match it. Keep account state separate from histories/config and preserve explicit model/effort/workspace identity.

Acceptance: synthetic framing/error/capability tests; disposable-project stream, tool approval, cancellation, completion and reopen; honest auth/permission/model errors; application IDs map to upstream sessions. Verify the supported coordinator host-tool/MCP bridge before claiming app delegation works. Record real inference usage and exact commands; no scraping the ChatGPT website or copying OMP credentials. Live account use is a separate acceptance run, not a configuration-validation shortcut.

Attempts/result/evidence: none; future task packet.
