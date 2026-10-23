# OpenCode 2.1.4 ACP adapter

`src/runtime/opencode.zig` consumes the installed `opencode v2.1.4` ACP protocol 1, not v1 HTTP APIs. Source: <https://dev.opencode.ai/v2/docs/cli/acp/> (observed 2026-10-23). `opencode acp` starts its own private server and exits on stdin close; it does not attach to the user's background service. The adapter uses the Host-owned common `Adapter` and `Transport` interface. Initialize the runtime at its final address, since bounded fixed allocators refer to inline buffers. Config metadata remains immutable/alive until shutdown. Inputs are borrowed for dispatch only; receipts/observations are deeply copied into the caller allocator. Host owns process shutdown, including on errors.

## Selection and lifecycle

The application supplies `Config.cwd` as an absolute process workspace separately from `Selection.workspace`, which is the opaque durable database workspace ID. Before open the configured selection may carry a placeholder workspace; create compares every other selection field and adopts the actual requested opaque ID. It never treats that ID as a filesystem path. The Host binds its configured workspace root to the durable workspace's canonical root before dispatch. Exact runtime version, provider/model, effort and runtime-owned account reference remain explicit. Runtime version/protocol are negotiated; model selection is applied through `session/set_config_option` and checked against returned `configOptions`. No effective selection is claimed before successful configuration. A model listing does not establish account readiness. Unsigned-in disposable smoke reports unknown even if the explicit free model responds; explicit attempts with unknown readiness do not claim authentication or entitlement. No OMP credentials or existing histories are read.

Open/create acknowledgement precedes asynchronous session observation. Start is forbidden until that observation. Resume requires negotiated `sessionCapabilities.resume`, preserves upstream ID and exact workspace, and never falls back to create. Cursor replay, inspection, mid-turn messaging and usage normalization are unsupported. `session/update` text uses UTF-8 byte offsets; tool events retain upstream tool IDs. Unknown notifications are ignored, unknown client requests get method-not-found; malformed/cross-session messages and mismatched replies fail closed. Errors are failures, not completion. Cancellation acknowledgement is not completion: only the upstream cancelled stop reason emits cancellation, with tools-stopped unproven. Process exit emits disconnect with unknown continuity; it never triggers automatic replay.

Protocol frames are limited to 64 KiB, separately from durable observations (4096 bytes) and content pieces (2048 bytes). One fixed 64 KiB decoded-payload buffer retains text or canonical serialized tool content; polls drain it before reading another upstream frame. Text pieces end at valid UTF-8 boundaries with contiguous byte offsets. Up to three incomplete trailing scalar bytes are carried into the next text update; invalid UTF-8 or completion with an incomplete scalar fails explicitly. Each piece receives a distinct instance/sequence event identity. Direct frame admission while pieces remain returns backpressure without consuming the new frame.

Tool result pieces use ordinary chunk observations with correlation.tool/upstream_tool and chunk.block equal to the upstream toolCallId, offsets beginning at zero. The Host maps these to one durable tool_result block. After the complete canonical ACP content is emitted, exactly one empty-result tool_completed observation closes that same block; it must not create a duplicate result block or truncate the content. Retained session metadata is bounded to 32 KiB and turn/permission metadata to 16 KiB. Transport supplies bounded JSONL queues. Each poll emits at most one piece or processes one upstream frame. Shutdown is idempotent and owns only the spawned provider process tree.

A transport pump error is terminal protocol evidence even when the process has
not yet been reaped. The adapter retains and returns the original error, marks
readiness terminal, and performs no subsequent transport IO. Standalone callers
that poll receive one correlated disconnect with unknown continuity after any
already-decoded text pieces; no completion or proven process exit is invented.
The Host instead handles the thrown pump error itself, durably rejects a pending
open or marks an active operation ambiguous, then shuts down and destroys its
factory instance without polling a duplicate diagnostic.

## Permissions and real bridge semantics

`session/request_permission` carries JSON-RPC request ID, session, tool call and offered options. The adapter hashes the complete request, binds approval to session/run/tool/digest, uses only the actual offered `allow_once`/`reject_once` option IDs, rejects stale/duplicate responses, and never selects `allow_always`. Scope comes from the upstream title; no upstream expiry is invented. The domain's fail-closed handling of absent expiry remains applicable.

OpenCode accepts stdio or HTTP `mcpServers` in `session/new` and `session/resume`. `Config.mcp_servers` accepts the serialized ACP array from the actual application MCP owner. This is NOT an ACP tool-call response channel: OpenCode does not support MCP-over-ACP. HTTP registration forwards explicit headers; integration policies still apply. MCP servers are scoped to the private process but shared by sessions in the same workspace directory. Registering a URL or command alone does not prove the app tool bridge: `coordinator_bridge` stays unsupported until the application implements and exercises an actual MCP endpoint and durable host-tool claims. No mock delegation bridge or fictional cross-runtime parity is provided.

`src/runtime/opencode_bridge.zig.serialize(allocator, common.Bridge)` returns an
allocator-owned ACP array containing exactly one HTTP server named `spica`, its
session-scoped URL, and `headers: [{name: "Authorization", value: "Bearer <token>"}]`.
The factory retains this JSON until runtime shutdown and frees it on failure or
destroy; the helper borrows URL/token only while serializing. JSON escaping is
performed by the standard encoder, without an intermediate bearer allocation.
The Host, not the helper, creates/authenticates/serves and shuts down the endpoint.
Installed binary v2.1.4 SHA256
`ca9b3ee262e33bb4e7aa0e1230dc61086a474c8c8016b980081d0719712fd2e7`
contains the actual ACP schema: HTTP discriminator, `name`, `url`, and a headers
array of `{name,value}` objects (not a headers map). Raw schema extraction is
under `.artifacts/provider-factory/opencode-bridge/installed-schema.txt`.

Focused `src/opencode_bridge_test.zig` tests exact registration, escaped input
ownership and every allocation failure. `src/opencode_test.zig` additionally
checks identical registration on create/resume, retained config through shutdown,
invalid array/JSON errors, and readiness after initialization success/failure.
The common Adapter readiness hook holds durable open dispatch during ACP
initialization; an RPC error, version mismatch or process exit ends that wait and
allows the Host to reject the open instead of stalling.

Serializer/unit checks alone do not establish real MCP consumption. The actual
installed consumer attempt 4 now records an authenticated `task.delegate` claim,
one actual OpenCode child completion (`SPICA_MCP_CHILD_OK`), an explicit public
structured result and exact task/result retention across Host shutdown/reopen.
Raw commands, isolated environment, candidate hashes and durable rows are in
`.artifacts/provider-factory/consumer/host-manifest-4.json`, `host-run-4.log`
and `host-durable-4.json`. This is not a live permission roundtrip, Codex
inference, cross-runtime delegated execution or broad parity claim.

`src/opencode_smoke_host.zig` is the actual NativeFactory consumer, not the old
singleton-adapter seam. It creates isolated project/workspace/thread state, asks
installed OpenCode to call the application's MCP `task.delegate`, and reads the
real child through public task/content queries. After completion it records an
explicit public `task_result` using the observed child text (structured results
are not automatically synthesized from provider prose), then verifies one exact
task/result after Host shutdown and read-only reopen. Its executable arguments
are `OPENCODE_EXECUTABLE WORKSPACE ACCOUNT_DIRECTORY STATE_DIRECTORY`.

Installed OpenCode defaults MCP tools to Code Mode. The model invokes them
through `execute` under the `tools.spica` namespace (the catalog preserves the
original `task.delegate` tool name); they are not directly callable model tools.
The consumer allows this actual Code Mode wrapper but forbids shell, filesystem
and native subagent substitutes. Attempt 3 connected all five actual MCP tools
but its prompt incorrectly prohibited `execute`, so it produced no callback;
that failed cohort is preserved, not counted as endpoint or bridge success.

`src/opencode_factory_smoke.zig` independently exercises two actual per-session
factory processes and buffers with the same explicit account/selection. It
initializes the parent before starting the second process, as the Host does,
cancels and destroys the first, then requires actual completion from the second.
It also opens `/bin/false` through the factory and checks terminal rejection and
allocator-clean shutdown/destroy. This does not establish simultaneous cold
account initialization support: that cohort produced startup failures, retained
in `.artifacts/provider-factory/consumer/factory-run-2.log` and `factory-run-3.log`.
Installed server logs identify `SQLiteError: database is locked` (attempt 2) and
concurrent schema bootstrap failing because `account_state` already exists
(attempt 3). No production retry or hidden serialization is added. Exact
consumer commands and isolated environments are recorded in that evidence
directory's per-attempt manifests. The earlier attempt 4 process-lifetime cohort
used a disposable directory nested in the checkout, so it is not evidence of
non-Git workspace isolation; subsequent cohorts use explicit `/tmp` workspaces.

## Supported authentication and evidence

Use an isolated runtime-owned HOME and XDG state, then run the supported `opencode auth login` (or terminal flow `opencode acp --login`) interactively in that same environment. Reconnect and initialize after successful login. Do not use `auth export`, copy OMP secrets, switch global accounts, or modify shared services/config. Product subscription inference remains gated on the user's isolated sign-in and entitlement; an optional explicit free-provider prompt is separate evidence, never subscription parity.

For this exact installed version, HOME/XDG alone does **not** control all global
discovery: `Global.home` is `OPENCODE_TEST_HOME ?? os.homedir()`. The native
launcher and factory consumers bind `OPENCODE_TEST_HOME` to the explicitly selected
account, `OPENCODE_CONFIG_DIR` to its `config/opencode`, and set
`OPENCODE_DISABLE_CLAUDE_CODE=1`. This version-pinned test-home override is not a
claim of a broader supported authentication API or filesystem sandbox.
Installed `ConfigDiscovery` derives global `.agents` from that same home;
the Claude switch does not disable `.agents`, but the explicit home confines
its global root. Coding-workspace project configuration remains enabled.
System `/etc/opencode` discovery is not disabled. Source offsets and the binary
hash are retained in `consumer/installed-isolation.txt` under the evidence root.

`src/opencode_mixed_smoke.zig` uses one factory configured for both native
runtimes with distinct accounts and workspaces. It checks actual process cwd,
Codex initialize/account-read status and the OpenCode handshake/selection before
requesting only explicit free-provider OpenCode inference. An unavailable
isolated ChatGPT account is a supported user sign-in prerequisite, not evidence
of Codex inference or cross-runtime delegated execution.

`tools/opencode-acp-smoke.py` creates disposable HOME/XDG/workspace, strips credential and OpenCode override environment variables, and records raw JSONL and stderr under `.artifacts/opencode-acp`. It exercises initialize, invalid relative cwd, create, resume, mismatched workspace, unavailable model, cancel and close against the installed runtime. Set `SPICA_OPENCODE_CONSUMER` to the built `src/opencode_smoke.zig` executable to exercise the actual shared Adapter vtable in the same isolated environment. `SPICA_OPENCODE_LIVE=1` additionally requests an explicitly selected `opencode/big-pickle` tiny prompt, retaining either actual streamed output or the actual provider error. Default smoke makes no inference claim. `src/opencode_test.zig` contains synthetic permission, identity, streaming, cancellation and error regressions, separate from installed protocol evidence.
