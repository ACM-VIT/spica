# Bounded history and rich-document paging

The domain remains the sole owner of canonical message/block metadata and content.
The native view never creates a second history database or resident linear index.
`Host.query.messages` seeks the existing `(thread_id, ordinal)` SQLite index,
with exclusive stable MessageId anchors and older/newer traversal. A missing
anchor returns `not_found`, not an implicit jump to a boundary. Continuations
retain the same query identity and snapshot. Exact content reads seek indexed
chunk offsets, including the at-most-2047-byte possible preceding chunk, rather
than walking every prior chunk. Store chunks are at most 2048 bytes.

The native consumer retains one selected message and eight canonical block
descriptors, with same-snapshot block continuation. The existing general-purpose
Transcript cache remains capped at three 64-KiB metadata pages plus one staging
page, and eight 16-KiB content pages. Native geometry is at most eight retained
rich tiles, not a height entry for each historical row. No total-history pixel
height or global scroll offset is promised: navigation uses IDs and rendered-byte
cursors. Ctrl+Alt+Home/End selects the oldest/latest message;
Ctrl+Alt+PageUp/PageDown and wheel movement at a viewport boundary traverse
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

Backward ranges inspect at most 8192 bytes and establish a proven Unicode
grapheme restart (block start, LF, or adjacent ASCII scalars excluding CRLF)
before using the retained libunibreak implementation. If bounded context cannot
prove a restart, the operation reports `DisplayBudget`, never invents a
scalar-only boundary inside an extended cluster. Same-projection PageUp reads
the existing spool; it does not reread/reparse canonical source.

Expired snapshots trigger one query-only fresh snapshot attempt from the captured
MessageId, canonical BlockId/ordinal and rendered-byte cursor. A changed/missing
anchor remains visible; repeat expiry stops with a notice until explicit
navigation. No durable command or provider effect is replayed during recovery.
Busy navigation retains one latest-wins pending intent rather than dropping it.
