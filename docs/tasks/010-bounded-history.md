# 010: Bounded history metadata and large rich documents

Status: running; review/acceptance remains with Main.

## Assignment and identity

Base: `5b6cfb3d5b9949cc4d12e42049bda88a5f0230f9`; branch: `task/010-bounded-history`; private worktree: `.artifacts/worktrees/010-bounded-history`. Initial HEAD/base verified; clean index/worktree; initial focused diff SHA256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

Owner: RuntimeFactoryLead.BoundedHistory010, reserved slot3, no descendants. RuntimeFactoryLead is sole shared Git/integration owner; this worker may make exact-owned private checkpoints. Actual model: gpt-6.1-sol; tier default; no advisors/fallback. Project effective worker overrides pin gpt-6.1-sol, default tier, 60 minute runtime and 200/300 request budget. The current user operating contract supersedes historical per-child reservation wording.

Owned paths: `src/content/*`, `src/ui/transcript.zig`, `src/ui/coding.zig` history-only seams (explicit parent extension), `src/domain/store.zig`, `src/domain/types.zig`, `src/domain.zig` only for history paging; `src/app.zig` only captured history/scroll integration; affected bounded history tests; `src/test.zig` single App test import (explicit parent extension); this task record and relevant history contracts. No provider/runtime/options/main/.omp/shared task index changes. Task012 remains intact.

## Acceptance

- Reuse public Host queries and durable paging; no UI-owned execution or second persistence convention.
- Paged metadata and geometry, stable logical anchors across distant jumps and reflow, fixed working sets rather than a resident linear history index.
- Large Markdown/code preserves exact source, formatting and selection. Locate and import the original retained 523,183-byte failure source if reachable; record provenance or exact missing prerequisite without substituting fabricated identity.
- Leak-aware/regression coverage for page boundaries, cursors, stable anchors and errors.
- Private native UI interaction/screenshots for changed behavior; no user's display. Finite performance measurement only after builds stop and explicit parent lease; document measured working-set bounds and limitations, never infer physical latency from screenshots.
- Preserve prior fake/native/provider Host architecture and integration.

## Checks and evidence

Evidence directory: `.artifacts/history010/` within this worktree, including immutable candidate identities, commands/results, source provenance, interaction screenshots and manifest. Cohesive candidate first; no midflight builds/tests/formatters. Run focused checks after edits, repair locally at most three substantive failures (stop on repeated identical failure or scope ambiguity), checkpoint verified cohesive slices frequently. Parent reviews immutable feature branch for `git merge --no-ff` integration; checkpoints do not imply acceptance.

## Initial investigation

Existing transcript already has three copied metadata pages and eight content pages, and presentation spools immutable projections to disk. Investigation must identify remaining history/geometry and oversized semantic-block gaps rather than merely adding another visible cache.

## Implementation contract

History uses the existing SQLite `(thread_id, ordinal)` and `(block_id, byte_offset)` indexes and Host snapshot cursors. Predicates seek indexed columns directly rather than computing on every historical row. Missing message anchors fail explicitly. The native consumer retains one selected message and eight canonical block descriptors, continuing block pages on the same snapshot. No history-wide in-memory metadata or geometry table is introduced.

Immutable SPMD projection files retain the existing format and fixed record addressing. Rendered-byte cursors page oversized semantic blocks without reparsing source fragments. A native range is at most 4096 rendered bytes and 256 style spans, with exact clipped style offsets. The original canonical source and rendered projection remain separate. Ctrl+Alt+Home/End jumps to oldest/latest message; Ctrl+Alt+PageUp/PageDown and wheel boundaries navigate document/history ranges without stealing composer shortcuts. Reflow preserves the top visible grapheme/caret offset within retained geometry.

Original retained fixture discovery: exact 523183-byte search under repository `.artifacts` found no file; repository docs reference the failure but provide no source path/hash. Backup tracked tree has no retained import fixture. A broader Documents/tmp exact-size discovery was cancelled at 30 seconds without a result; no private histories or account material were imported. Subsequent discovery is constrained to known repository/Spica evidence. Any generated stress source is labeled separately and is not evidence of the original failure's identity.

## Checkpoints and review repairs

- `4dea903`: initial indexed metadata/rich range implementation; Debug/ReleaseSafe `test test-domain` each 141 native pass/2 skip, 4 image pass, 30 domain pass; Python35/2skip. ReleaseSafe application builds. These initial runs did **not** exercise App tests because the historical test root did not import App.
- First review repair cohort: backward grapheme-safe bounded lookbehind with explicit budget failure, same-projection backward reuse, coalesced busy navigation, distinct active-window history chords, one-shot query-only expired snapshot recovery, and source-scoped rendered selection across native page eviction with worker-owned whole-range copy. Permanent App test registration now exercises existing and new App tests.
- `python3 build/driver.py test test-domain -Doptimize=Debug --summary all` and ReleaseSafe each pass 151 native/2 skip, 4 image, 30 domain; Python35/2skip. ReleaseSafe application builds. Raw logs `app-debug.log`, `app-safe.log`, `repaired-native-build.log`.

Stable initial candidate interaction/performance evidence is `.artifacts/history010/manifest-initial.json`: actual fake send/F7 approval completed, generated 523183-byte Markdown/code imported exactly into canonical chunks (SHA256 `5016cda8a678b43d6d6117e22a5154700c6db9409fb68556d0e737793f43377f`), 100002 message rows, native oldest/latest jumps and return to identical rendered tail, 760px reflow. Parent granted/released exclusive sampling lease; 24/24 complete process-tree samples over13.75s report PSS first73225216,last73229312,growth4096 bytes. This is a time-plateau at large history, not growth-versus-history-size or physical input latency. Initial pointer IPC screenshot did not show a highlight and is **not** selection proof. Revised actual selection interaction remains separately recorded.
