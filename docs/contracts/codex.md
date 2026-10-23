# Codex app-server adapter

Runtime target: installed `codex-cli 0.163.0`, app-server stdio JSONL. The schema
is generated with `codex app-server generate-json-schema --experimental --out DIR`;
experimental dynamicTools require `initialize.capabilities.experimentalApi=true`.
Protocol evidence is not authenticated inference or native Host acceptance.

## Ownership and common ABI

`src/runtime/adapter.zig` supplies a Host-owned vtable. Request inputs are borrowed
for one call; dispatch receipts and polled observations deep-copy strings into
the caller allocator. Discovery/account/selection metadata borrow runtime state.
`pump` is bounded and nonblocking; the domain worker, never the UI, owns pumping.
An acknowledged open/start request is not a successful upstream operation:
session and selection observations arrive after correlated upstream replies.
Host normalization must associate an open effect/session with the durable run
and map upstream content item identifiers onto its durable message/block IDs.

`transport.zig` owns one process tree through the existing platform boundary.
Per-child explicit environments isolate CODEX_HOME without mutating parent state.
JSONL frames are bounded to 256 KiB, input/output queues to 512 KiB each;
partial writes and reads are retained. Oversize/truncated frames and process loss
are errors, never successful completion. Runtime-retained identity/callback data
has a separate 1 MiB cap; observation queues contain at most 16 fixed frames.

## Account and selection

The account reference identifies an explicitly selected independent runtime account
directory, not application database credentials. `account/read` recognizes a
managed ChatGPT account; this does not prove model entitlement. The supported
explicit sign-in methods are `account/login/start` with `type:chatgpt` (browser)
or `type:chatgptDeviceCode`; the runtime owns token storage. `startLogin` exposes
that operation and retains its supported-flow result in `login`. No login starts
as a side effect of adapter initialization, and no OMP credentials are consulted.

Thread creation supplies model, provider, workspace, effort, workspace-write
sandbox and on-request approval. Provider/model fallback is explicitly disabled.
Reported thread identity is checked against requested model/provider/workspace/
effort. Unsupported message, replay and inspection surfaces reject explicitly.

`Config.cwd` is the canonical absolute provider working directory. Public
`Selection.workspace` remains an opaque durable workspace ID, never a pathname.
Host admission checks that workspace's persisted canonical root against the
startup provider root; provider selection checks retain all other explicit
metadata and preserve the admitted workspace ID in observations and approvals.
Approval RPCs are live-only; one-action accept/decline never approves a session.
Interrupted turns do not claim all external tools have stopped.

## Coordinator bridge gate

Configured dynamic tools use actual `thread/start.dynamicTools` registration and
server `item/tool/call` requests. `pollTool` returns typed request ID, call ID,
name, JSON arguments and application correlation. `respondTool` sends the
matching JSON-RPC response with contentItems/success. This is provider-internal
until the domain owner binds it to durable app commands and scoped authority.
`coordinator_bridge` remains unknown, not supported, until that actual integration
and a disposable authenticated invocation are exercised. No prompt-based bridge
or stand-in tool endpoint is provided.

## Native startup and sign-in

`src/main.zig` now creates final-address provider storage before Host startup,
passes the adapter/selection/root to the Host, and retains its context until
after Host destruction. The worker owns process shutdown; main then frees Codex
retained state without closing the transport twice. There is no fake fallback.
Only the explicit account directory supplies HOME/CODEX_HOME/XDG state; the
parent environment, credentials and histories are not copied.

```sh
zig-out/bin/spica --provider codex --workspace /absolute/disposable/project \
  --runtime-account-directory /absolute/isolated/codex \
  --model-provider openai --model gpt-6.1-sol --effort medium \
  --codex-auth status
```

Use `--codex-auth browser` or `device` with the same arguments to initiate the
supported flow. The actual runtime result is printed and the process keeps the
login transport alive for up to 120 seconds; incomplete/error flows fail rather
than reporting authentication. Omit `--codex-auth` to open the native app.
`--runtime-executable` accepts an absolute installed binary override.

Recovery evidence: `.artifacts/provider-recovery/native-build.log` and
`native-auth-status.log` exercise the actual Debug executable and isolated
account status (sign-in required). Browser/device completion, authenticated
inference and native provider desktop interactions remain unexercised.
