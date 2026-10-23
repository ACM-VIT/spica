# Durable conversation implementation

Core v1 remains normative. `src/domain/types.zig` provides the domain-only typed command, receipt, revision-position, bounded query and output values. Adapter IDs/selections are reused from `src/contract.zig`; adapter receipts are not domain receipts. UI projection decisions include bounded message block descriptors, same-snapshot block continuation, tools and older/newer stable-anchor traversal.

`types.encode(value,buffer)` uses fixed-buffer deterministic structural JSON (explicit tagged unions, null fields, declaration field order, exact string bytes). Its format is private versioned storage encoding, not a replacement public contract. It allocates nothing and fails before buffer overflow. Command envelope encoding includes target, version and precondition, not only payload. Dedup must compare exact bytes, not hash alone. Event positions order `(commit_sequence,event_index)`, preserving unseen same-revision events.

This checkpoint implements value encoding and ordering only. No Host/dispatcher/query execution is exposed by it and no persisted-conversation milestone is claimed. Integration of further executable slices remains under task004's assigned owner.

Focused check (no SDL/native dependencies): `zig test src/domain.zig -O Debug` and `-O ReleaseSafe`.

Event/receipt revisions use `AggregateRef`, including message/block/session/effect/tool identities; command `Target` remains constrained to mutation targets. Snapshot `QueryPage.expires_at` is host-monotonic milliseconds, not approval UTC expiry.

The private schema-v1 record encoding is deterministic structural JSON, not the length-prefixed candidate from preparation. Zig0.16 emits valid UTF-8 byte slices as JSON strings and invalid/partial sequences as numeric arrays; `types.decode` accepts both to byte slices with a caller-bounded allocator. NUL and split Unicode scalars roundtrip exactly; no normalization. Schema-version changes must migrate existing stored records transactionally under exclusive ownership or reject the version; field/tag renames are format changes, never silently reinterpreted. No migration beyond fresh-v1 creation is implemented.
