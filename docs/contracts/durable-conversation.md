# Durable conversation implementation

Core v1 remains normative. `src/domain/types.zig` provides the domain-only typed command, receipt, revision-position, bounded query and output values. Adapter IDs/selections are reused from `src/contract.zig`; adapter receipts are not domain receipts. UI projection decisions include bounded message block descriptors, same-snapshot block continuation, tools and older/newer stable-anchor traversal.

`types.encode(value,buffer)` uses fixed-buffer deterministic structural JSON (explicit tagged unions, null fields, declaration field order, exact string bytes). Its format is private versioned storage encoding, not a replacement public contract. It allocates nothing and fails before buffer overflow. Command envelope encoding includes target, version and precondition, not only payload. Dedup must compare exact bytes, not hash alone. Event positions order `(commit_sequence,event_index)`, preserving unseen same-revision events.

This checkpoint implements value encoding and ordering only. No Host/dispatcher/query execution is exposed by it and no persisted-conversation milestone is claimed. Integration of further executable slices remains under task004's assigned owner.

Focused check (no SDL/native dependencies): `zig test src/domain.zig -O Debug` and `-O ReleaseSafe`.
