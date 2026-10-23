# Bounded history and rich-document paging

The domain remains the sole owner of canonical message/block metadata and content.
The native view never creates a second history database or resident linear index.
`Host.query.messages` seeks the existing `(thread_id, ordinal)` SQLite index,
with exclusive stable MessageId anchors and older/newer traversal. A missing
anchor returns `not_found`, not an implicit jump to a boundary. Continuations
retain the same query identity and snapshot. Exact content reads seek the greatest
indexed chunk offset at or before the range start, then seek forward from that
actual offset. Queries select only rowid/offset/length metadata and use read-only
SQLite incremental blob reads into the bounded requested output, never materialize
the entire blob through `Statement.bytes`. Imported chunk lengths remain readable,
including an interior range in a single 523183-byte chunk; no fixed chunk-size
assumption or history scan is used. Current `Store.appendChunk` still admits at
most2048 bytes and the writer SQL value limit remains1MiB; the schema itself does
not encode that representation limit. The16MiB external-schema stress regression
raises the writer limit **only in its explicit test importer**, not production.

The native consumer retains one selected message and eight canonical block
descriptors, with same-snapshot block continuation. The existing general-purpose
Transcript cache remains capped at three 64-KiB metadata pages plus one staging
page, and eight 16-KiB content pages. Native geometry is at most eight retained
rich tiles, not a height entry for each historical row. No total-history pixel
height or global scroll offset is promised: navigation uses IDs and rendered-byte
cursors. Alt+Home/End selects the oldest/latest message;
Alt+PageUp/PageDown and wheel movement at a viewport boundary traverse
rich ranges or adjacent messages. These explicit history chords require an
active window and do not steal composer Ctrl+Home/End caret/selection semantics.
Selecting latest resumes follow mode; browsing older ranges does not let new
output steal the viewport.

Markdown is parsed once per source/revision in the presentation worker, using the
existing bounded parser and disposable SPMD spool. SPMD stores fixed-width block
and style records on disk; a tile seeks its block and binary-searches intersecting
style runs. Oversized code/paragraph blocks are not replaced by plain text or
silently dropped. Each tile contains at most 4096 rendered bytes and 256 clipped
style runs. Forward boundaries prefer lines and preserve extended graphemes.
The canonical source remains distinct and exact; rendered selection addresses the
rendered projection, not Markdown syntax offsets. Selection endpoints retain
source/revision and absolute rendered-byte offsets across native page eviction;
Shift+click extends into an adjacent page of that same canonical rich block.
Visible geometry clips those logical endpoints and survives reflow. Ctrl+C
copies the complete selected rendered range through the presentation worker's
spool read, not just the current tile (64-KiB clipboard cap; over-budget copy
fails explicitly, never truncates). Cross-canonical-block selection is not
advertised. Top-visible caret/relative-pixel anchors are captured before reflow
and restored after it. Source/revision/generation plus semantic block and
rendered-byte offset distinguish tile identities.

Limits are explicit, not a claim of unlimited document support: canonical rich
source at most 1 MiB, parser arena 8 MiB, projection scratch backing 16 MiB,
disposable spool 8 MiB. The worker has two fixed source slots and one completion;
no parser/SQLite/provider work moves into draw. Native text has its existing
aggregate layout/glyph/font budgets. Process allocator/SQLite/driver overhead is
outside these source-level ledgers. Task010 evidence distinguishes observed
whole-process bounds from these designed caps and does not infer physical latency
from screenshots.

The projection worker computes exact Unicode grapheme boundaries once per complete
renderable semantic layout range using retained libunibreak and capped scratch.
A compact one-bit-per-rendered-byte boundary map is appended to the same
disposable SPMD spool (at most262145 bytes at the2MiB rendered cap, charged to the
8MiB spool budget). No boundary/history-wide array is retained in UI or Projector.
Forward, arbitrary-anchor and backward ranges read at most514 bitmap bytes per
4096-byte window. Long CJK/Arabic/RI/ZWJ documents do not need ASCII/newline sync;
only an actual over-budget extended cluster fails explicitly. Semantic range
starts/ends reset boundary context exactly as independent native layouts do
(the current Markdown walker also terminates every renderable range with LF).
Adjacent RI/ZWJ semantic-edge regressions preserve those independent boundaries.
Same-projection
PageUp reads the existing spool; it does not reread/reparse canonical source.

Expired snapshots trigger one query-only fresh snapshot attempt from the captured
MessageId, canonical BlockId/ordinal and rendered-byte cursor. A changed/missing
anchor remains visible; repeat expiry stops with a notice until explicit
navigation. No durable command or provider effect is replayed during recovery.
Busy navigation retains one latest-wins pending intent rather than dropping it.

`Coding.ThreadHistory` is the bounded per-thread handoff to task009: stable
message/block IDs, canonical block ordinal/revision, semantic/rendered-byte cursor,
relative viewport pixels and optional source-scoped selection endpoints. A root
publishes this from actual top-visible geometry. Setting `history_restore` after
swapping a retained position makes the native consumer query that same canonical
block, restore its rendered cursor and selection, and reject old generations;
it does not reload latest merely because old geometry was evicted. Task009 owns
the finite context roster/swap; combined thread-switch interaction requires the
integrated candidate, not either isolated feature's claim.
