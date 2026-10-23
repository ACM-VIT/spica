# Durable conversation implementation

Core v1 remains normative. `src/domain/types.zig` provides the domain-only typed command, receipt, revision-position, bounded query and output values. Adapter IDs/selections are reused from `src/contract.zig`; adapter receipts are not domain receipts. UI projection decisions include bounded message block descriptors, same-snapshot block continuation, tools and older/newer stable-anchor traversal.

`types.encode(value,buffer)` uses fixed-buffer deterministic structural JSON (explicit tagged unions, null fields, declaration field order, exact string bytes). Its format is private versioned storage encoding, not a replacement public contract. It allocates nothing and fails before buffer overflow. Command envelope encoding includes target, version and precondition, not only payload. Dedup must compare exact bytes, not hash alone. Event positions order `(commit_sequence,event_index)`, preserving unseen same-revision events.

`Host` in `src/domain.zig` is the asynchronous public boundary: `create(allocator,io,Options)`, `destroy`, `submit`, `query`, `subscribe`, `unsubscribe`, `drain`. Admission copies requests and returns a Ticket, not an accepted receipt. A dedicated event-driven thread owns SQLite and fake dispatch. `Options` requires an explicit state directory and optionally a thread-safe wake callback/context. `drain(outputs,storage)` relocates all slices to caller storage; insufficient storage retains the queued frame.

Focused check (system SQLite/libc only; no SDL/native text dependencies): `zig build test-domain -Doptimize=Debug` and `-Doptimize=ReleaseSafe`.

Event/receipt revisions use `AggregateRef`, including message/block/session/effect/tool identities; command `Target` remains constrained to mutation targets. Snapshot `QueryPage.expires_at` is host-monotonic milliseconds, not approval UTC expiry.

The private schema-v1 record encoding is deterministic structural JSON, not the length-prefixed candidate from preparation. Zig0.16 emits valid UTF-8 byte slices as JSON strings and invalid/partial sequences as numeric arrays; `types.decode` accepts both to byte slices with a caller-bounded allocator. NUL and split Unicode scalars roundtrip exactly; no normalization. Schema-version changes must migrate existing stored records transactionally under exclusive ownership or reject the version; field/tag renames are format changes, never silently reinterpreted. No migration beyond fresh-v1 creation is implemented.

## Independent SQLite storage boundary

`domain.store.Store.open(io,state_dir)` opens only the explicit `conversation.sqlite3` under an exclusive, nontruncating `owner.lock`. It initializes fresh schema-v1/application identity under one transaction, checks foreign-key/FULL synchronous/WAL settings and syncs the directory. Foreign/legacy/newer schema identities reject without cutover/import. The C transient bind wrappers are reused; returned statement bytes borrow SQLite until step/finalize, whereas command lookup copies receipts into caller-owned storage.

One thread owns Store. `begin/commit/rollback`, `nextSequence`, `recordCommand`, `appendEvent`, `appendChunk`, `claim` and `recoverClaims` are internal production storage primitives, not UI commands. Exact envelope lookup precedes reducer revision checks; altered same-ID bytes conflict. Canonical receipts and entity/event writes share transactions. Rejected commands can consume a sequence without advancing the last event position. Chunk offsets reject conflicting overlaps/gaps and preserve all bytes including NUL and split Unicode scalars. Claims persist before any future dispatcher call; recovery changes in-flight to unknown, never back to planned; withdrawn remains nondispatchable. Cancellation/terminal run state prevents new effect claims (cancel/read-only requests have explicit exceptions). Reducers must append normalized lifecycle/recovery events in the same transaction; storage primitives do not fabricate them.

`zig build test-domain -Doptimize=Debug` (also ReleaseSafe) executes actual temporary-SQLite regressions without SDL/dependencies. `zig build build-domain-smoke -Doptimize=Debug` builds `zig-out/bin/domain-smoke`. Its arguments are `STATE_DIR write|read|crash-uncommitted|crash-committed NAME`. The storage-only consumer records one synthetic project command/receipt/event, verifies exact redelivery and deliberately `_exit`s before/after COMMIT (73/74). It is **not** the Host/fake conversation command path, approval implementation or no-duplicate-external-call proof.

The command reducer accepts project/workspace/thread/send, approval reply, cancellation and explicit evidence-based reconciliation in one transaction with receipt/event persistence. Planned effects contain exact immutable typed requests. `Owner.claimNext` commits its claim before returning a request; recovery makes claimed effects unknown and never replays them. Cancellation before any dispatch withdraws effects; after possible dispatch it journals a separate cancel intent. Approval requires matching current connection epoch, digest and unexpired UTC authority; reopen invalidates live authority.

Committed range replay compares indexed chunks over the requested bounded byte range, including different chunk boundaries; a replay extending beyond committed bytes is rejected rather than speculatively appended. Recovery increments revisions and emits exact effect/approval/run aggregate events atomically. New-store directory durability syncs the absolute state directory and every ancestor to root, including parent entries created by nested directory creation. This is fsync ordering, not an exercised power-loss guarantee.

The Host executes a fixed fake-v1 conversation: committed open/start, Unicode/code response, tool approval, allow/deny result or cancellation. Every adapter call uses the accepted bounded fake adapter after a committed claim. Recovery never replays claimed effects or resumes an old run; persisted authority is invalidated. The fake scenario derives tool/approval identities from durable run identity; provider calls are not owned by a UI/script.

`Owner.delivered` persists receipt evidence separately from lifecycle completion; a create acknowledgement without session identity becomes unknown, not permission to start. `Owner.observe` commits bounded chunk/tool/approval/lifecycle observations with identity/digest dedup and session cursor events. It retains exact content bytes and never revives terminal/unknown runs from late completion/cancellation. The caller must retain the complete observation until commit succeeds. Approval authority is connection-epoch scoped and UTC-expiring; cancellation withdraws an accepted but not yet dispatched reply.

Queries cover every `types.Query` projection, including tools, same-snapshot message/block continuation, older/newer ordinal traversal and exact content ranges. Two read-only SQLite transactions pin ephemeral views; generation/TTL/query-bound cursors reject stale reuse. Root queries replace the oldest snapshot when full. Pages enforce row/encoded nested-byte limits; requests/results/subscriptions are fixed-slot bounded. Subscriptions replay durable ordered events and fail closed with `resync_required` on excess batch/lag. Physical SQLite/C allocator/RSS/WAL bounds and power-loss behavior are not established by process-crash tests.

## Public consumer evidence entrypoint

`zig build test-domain build-domain-smoke -Doptimize=Debug --summary all`
(also ReleaseSafe) runs the public Host consumer and subscription regressions.
The isolated executable accepts `STATE_DIR host-flow fixture`,
`STATE_DIR host-crash-approval fixture` (deliberate `_exit(75)`), and
`STATE_DIR host-recover fixture`. Use fresh separate directories for flow and crash.
Flow exercises real command admission/receipts, streamed bytes, tool approval and
cancellation. Recovery replays exact setup/send command IDs, requires one
interrupted run, invalidated non-live approval and exactly two original effects.
In-flight claims recover unknown; otherwise nonterminal runs recover interrupted;
pending tools recover unknown with revision events. No ambiguous effect is replayed.
The native UI/custom-root integration gate remains owned by the integration lead.
