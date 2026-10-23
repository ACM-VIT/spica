# Task005 native UI implementation record

Status: first retained editor slice under review, not task005 acceptance. Base `3c18aac45d732f217bc9af98d466f3c569c8dd61`; private branch `task/005-ui`. Production allocation is recorded in parent task005 packet; no domain/build paths are changed here.

This slice replaces the foundation card with a native Unicode draft surface. It uses the existing bounded Composer, retained EditorView/text engine, Clay arena, clipboard and selection geometry. Ordinary SDL text, grapheme/word navigation, selection, paste/cut/copy, undo/redo, vertical/line-edge movement, focus, local Escape and Ctrl+Q lifecycle are wired. Domain is deliberately not connected in this slice; no fake conversation/control or provider lifecycle is fabricated. Enter preserves the draft with an explicit unavailable notice; Shift+Enter inserts newline. The visible disconnected status is temporary integration state, not the task005 deliverable or accepted product behavior.

Explicit automation output v2 includes bounded draft bytes, caret/anchor/focus/preedit/revision and actual painted composer bounds; exporting draft text requires the existing explicit `--automation-output` option. Treat generated exports as private. `tools/eval-starter --mode editor` exercises real private-vd Unicode input, OS clipboard, undo/redo, selection deletion/undo, local Escape and focus exclusion, then Ctrl+Q. It does not inject internal text or domain state.

Evidence belongs to ignored `.artifacts/ui005/`; exact checks/results and checkpoint identity are supplied in the final worker receipt. The editor scenario establishes no streaming, durable command, approval, cancellation, restart, replacement-root, memory plateau or physical latency acceptance. Those gates still require subsequent domain integration and complete rendered evidence. Platform IME is not established by ordinary Unicode text input.


## Exercised checks and unresolved blocker

Debug build passed after correcting one Color type mismatch. Direct `zig test` rooted at main with the existing native dependencies exercised15tests (new Unicode/rejected-edit test plus retained Composer/label/edit regressions), all passed. `zig fmt` on changed owned Zig files made no changes. Python runner boundary regressions passed7tests before the editor-mode addition; this is not claimed as coverage of that new path.

Actual `./tools/eval-starter --mode editor --optimize Debug` **failed**, preserved at parent `.artifacts/ui005/editor-first/`. Real `vd text` typed `hello é שלום 👩‍💻`; native exited `EditorLayout`, SDL `Text: shaping tables exceed the shared font budget`. Last painted export ends at woman scalar; exact subsequent failing prefix is not established. The next ctrl+a consequently found no application. This is a retained native-text repair boundary (`src/native/text.c:203–230,842–864`; existing emoji regression `src/native/text_test.zig:174–225`), not a passing Unicode scenario. No font budget increase, emoji removal, suppression or failing-cohort rerun. Coordinator authorized a verified controller checkpoint with this unresolved acceptance blocker and a separate retained-C repair owner. No durable send, streaming or transcript acceptance is claimed.

Failure source fingerprint `6d01ff1029615b8e78a2c8409e38a2b471a66d49d17e971499710092051e42e3`; binary `3d398c607e8271aae0e70c08a0d44a9f2c17988dd52ec6ffe876462efa5aa317`, Debug. Source preparation/identity evidence remains parent `.artifacts/ui005/preparation.md` and manifest. Current controller still needs event-boundary text-cache observations for uncommon out-of-paint re-layout, exact pointer/IME and streaming checks; no idle cache plateau is asserted.

## Controller review repair and bounded query-cache slice

Review fixes separate remembered editor focus from window activation, preserve manual wheel scroll until an explicit edit/caret navigation requests reveal, retain unchanged preedit shaping and release on clear/deinit, and reject embedded NUL clipboard selection before invoking SDL. Existing App expected-admission error handling remains the only boundary; new read-only counters make rejected edits observable. Native chord automation now holds/releases actual `wtype` modifiers because installed `vd key` accepts one keysym, not `ctrl+a` syntax.

New `src/ui/transcript.zig` is a bounded public-query consumer: three32-row/64KiB metadata pages plus one transactional staging buffer; eight16KiB exact source pages; stable ID/byte scroll anchors, source-versus-rendered selections, explicit snapshot identity and ordered-position invalidation. All nested domain slices are copied into fixed storage before drain reuse. It has no store/provider imports, linear history geometry or global event set. It is tested as a data primitive; not yet connected to rendered domain output.

Frozen narrow checks:27/27 native-root tests and8/8 evaluator boundary tests passed. Actual new `--mode capacity` Debug private-vd cohort passed at `.artifacts/ui005/capacity-review/manifest.json`: OS clipboard paste fills64KiB, oversized paste reports one TextTooLarge without exit, undo returns empty draft, Ctrl+Q is observed. Inspected `rejected.png` (full retained draft/local notice) and `after.png` (undo restored empty draft). This new ASCII boundary scenario is not a rerun or replacement of the unresolved full Unicode cohort. No streaming/durable/UI milestone acceptance follows.

## Rich projection worker slice and repaired actual Unicode cohort

Consumed reviewed native text repair `ee4e207387cbdc9ee9c158481f340920ffe8596d` as local `81d7606`; retained C/test remain dependency-owned, not edited by UI. With corrected chord transport and remembered focus repair, the full original editor scenario passed on the changed candidate at `.artifacts/ui005/editor-repaired/manifest.json`. Inspected `after.png`: combining mark/Hebrew/ZWJ emoji, multiline draft and native selection visible. Export preserves exact `hello é שלום 👩‍💻\nsecond line`, caret1/anchor0, focused=true, no admission errors;47frames, font ledger940097bytes. This supersedes the old candidate failure only for this exercised cohort, not domain/UI milestone acceptance.

New `src/content/presentation.zig` reuses real Markdown.parse and existing SPMD serialization. A pointer-stable worker owns one parse at a time, two fixed source buffers (active/latest pending), one pending visible-block request and one owned completion. A process-wide presentation mutex serializes retained global C allocation hooks. Derived data uses a caller-provided private temporary file capped8MiB; serialization buffers64KiB, visible reads copy one complete semantic block and bounded style records, with explicit stale-generation/source/layout budgets rather than parsing arbitrary source fragments. Parsed Document/AST never reaches UI. File/parser work stays on worker; Wake is payload-free and shutdown joins before release. Caller must handle nonblocking Busy and keep callback alive through destroy.

Direct real-C worker tests passed4/4 in Debug and4/4 ReleaseSafe: GFM heading/emphasis/code+language projection, source/rendered identity and stale revision rejection, malformed/display-budget invalidation, asynchronous publish/drain and allocator-failure cleanup. Whole-source parsing remains bounded/off-thread, not falsely described as visible-only parse. Default app has not yet connected this worker or transcript to a real Host; code highlighting, rich native drawing and public command controls still require the integration slice. No mock domain substitute or permanent raw-text fallback is supplied.

## Event-boundary cache accounting

Native metrics schema v2 now observes ledger changes around ordinary event dispatch as well as after presents. The optional bounded change buffer records before/after stats and event timestamp/sequence; unchanged events allocate/store nothing, overflow/accessor failures are explicit, and evaluator idle-tail state merges both sources. This removes the old inaccurate paint-only cache-mutation assumption. Worker/parser memory and transient between-boundary peaks remain excluded. Final narrow checks passed29/29native-root tests (including an actual software-renderer native re-layout inside key dispatch, observing0->1live layouts) and10/10evaluator tests. Actual changed-candidate full Unicode editor input passed at `.artifacts/ui005/editor-cache-boundaries/` with schema2, zero cache drops/failures and no observed out-of-paint changes in that particular cohort; screenshot inspected. This is not a performance cohort or physical memory plateau claim.

## Recovered native rich surface and command intent slice

Resumed private checkpoint `c391f6621659033f9ff9ea15b379b7ae9f0c5773` with a clean index/worktree. The root now retains eight native semantic tiles from real presentation-worker completions, with Markdown emphasis/inline-code faces, heading sizes, fenced-code panels, rendered-byte pointer selection/copy and transcript scrolling. Layouts are reused for unchanged content identity/width and released on eviction/shutdown. Selection is explicitly rendered projection, not canonical source. A real C Markdown -> projection -> native software-renderer regression covers drawing, geometry reuse, selection and transactional rejection.

The replaceable root exposes bounded send/cancel/allow/deny intents, gated by host-published capabilities/state; drafts are not cleared by presentation. Painted control rectangles and enabled state are exported through the existing read-only automation snapshot. Controls intentionally remain disabled until the concrete Host is connected: no mocked commands, provider state or synthetic conversation were introduced. Main/App still require the next real Host lifecycle/query/stream integration slice; these controls alone are not useful-workspace or task005 acceptance. Check results and candidate identity are recorded with the checkpoint handoff.

Focused checks: `zig fmt` on the five changed owned Zig modules passed. Direct pinned-native `zig test` rooted at `src/main.zig` plus real Markdown C dependencies passed **35/35**; one test-expectation repair preserved the parser's real trailing newline rather than changing production output. Exact command/raw passing log: parent `.artifacts/ui005/run-rich-native-check.py` and `.artifacts/ui005/rich-native/native-root.log`. Actual `./tools/eval-starter --mode editor --optimize Debug --output /home/ashman/Documents/spica/.artifacts/ui005/rich-native-editor` passed; `after.png` inspected, Unicode multiline selection and disabled native controls visible. The source-only test expectation repair followed this desktop capture; production sources were unchanged afterward. This is ordinary native input proof, not proof of real Host controls/streaming.

Runtime published concrete dependency `50b65b6` (required chain `27bc827`, `9088964`, `50b65b6` from its `c0d7fb2` ancestor) only at this packet's request boundary. It is **not yet consumed** by this UI branch. Next owner must explicitly integrate that chain, wire main-owned Host plus SDL wake/drain and borrowed-output copying, retain App-owned command identities across root replacement, feed actual bounded metadata/content through the existing worker into `View.admitTile`, gate controls from real run/approval projections, and exercise actual prompt/stream/approval/cancel/reopen on private desktop. Syntax coloring, distant history paging, generation-driven live automation, resize reflow of retained rich tiles, and full Lua-root integration remain unexercised/incomplete; no milestone acceptance asserted.

## Actual durable native Host integration

Checkpoint `d5838e3` retained the preceding verified surface. Explicitly consumed concrete domain/storage chain through `50b65b6` (local `0ae9b63`) and restart repair `f3e964a` (local `214e6df`), rather than copying mutable sources. Main owns Host lifetime; App owns mutation identity/admission, one bounded query, copied IDs/revisions/digest and public subscription refresh. One serialized content worker feeds up to eight retained native tiles; reflow uses retained bounded rendered bytes/style spans. Optional live read-only automation exports actual painted generation/control geometry/status and bounded transcript. No provider/store imports in coding root.

Actual `tools/eval-starter --mode conversation --optimize Debug --output /home/ashman/Documents/spica/.artifacts/ui005/host-native-cohesive` passed: real Unicode prompt/Enter -> response/code/live approval -> geometry-derived allow click -> completed tool result -> second prompt -> cancel click -> reopen retains thread/run IDs, cancelled status and approved tool output. Earlier `.artifacts/ui005/host-native-first` preserves an installed `vd click` missing-helper failure; `.artifacts/ui005/host-native-pointer` proves the repaired private-session packaged helper path. No user desktop or history was accessed. Reopened screenshot inspected. Fixed fake adapter emits a bounded burst, not paced-token performance evidence.

Focused checks: native Debug build passed after correcting the Zig Dir API; direct root with actual C/SQLite dependencies passed **50/50**, Python evaluator regressions **10/10**, formatting passed. Raw root command/log is parent `.artifacts/ui005/run-rich-native-check.py` / `host-native-check/native-root.log`. One narrow-check harness flag repair (`_DEFAULT_SOURCE`, matching build integration) was needed; production native build already had it. No broad suite or performance claim.

Behavior reference inspected at exact T3 pin `eb1510d2493cbf28600432d5193cc22a1af8f3d8`: `apps/web/src/components/chat/ComposerPrimaryActions.tsx:112-154` preserves composer focus and gates Send/Interrupt; `ComposerPendingApprovalPanel.tsx:74-87` bounds detail and rejects non-resumable approval; `MessagesTimeline.tsx:1217-1221` records streaming-history geometry hazards. Native equivalents reuse retained primitives; no React/Effect architecture copied. Current slice is explicit-state opt-in; next separately authorized slice adds new independent XDG native default plus root-before-Host teardown. Lua root bridge, syntax token colors, distant history paging and independent performance evidence remain incomplete.

## Independent default conversation and shutdown ordering

The next separately authorized slice makes ordinary launch useful: the new
`$XDG_DATA_HOME/spica-native/conversation` namespace (absolute XDG only), with
`$HOME/.local/share` fallback, never discovers or migrates legacy application
histories. Explicit `--state-directory` overrides it. `App.disconnect` joins its
presentation worker before main destroys Host; SDL/wake remain alive through
both joins. App teardown remains idempotent.

Focused `zig test src/options.zig` passed3/3, including absolute XDG/fallback/error
cases. Actual new `tools/eval-starter --mode conversation --default-state
--optimize Debug --output /home/ashman/Documents/spica/.artifacts/ui005/native-default-state`
passed the real prompt/allow/tool/cancel/reopen flow **without a state-directory
argument**, with XDG_DATA_HOME isolated below evidence output. All other evaluator
modes now pass explicit disposable state too, so no test opens user histories.
Formatting passed. Lua bridge remains the next separate slice.

## Native Lua root, renderer and action bridge

Replacement worker recovered clean private candidate
`a04c1c32aec969bc8f7edd49e25a26e5a2108283`, focused-diff SHA256
`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
That immutable candidate already consumes the selected protected Lua dependency,
queued-generation revocation, runtime formatting and domain terminal/revision
repairs; no mutable sibling source or additional dependency cherry-pick is used.

`--lua-module PATH`, F5 reload and F9 default/custom switching operate in the
actual App. A bounded Clay preorder consumes runtime root descriptors; retained
native composer/transcript/input are reused. The renderer consumes only copied,
bounded Host-visible transcript bytes. Lua execution remains on its protected
C worker. Native input retains immutable thread/run/approval/digest/workspace,
all relevant revisions, draft revision, installed generation/root epoch and a
stable command ID before delayed execution. Proposals are generation/context
checked and passed to the actual public Host, never treated as command receipts.
Main still owns Host outside both compositions; shutdown drains reserved action
results before joining Lua, then presentation, then Host while SDL/wake live.

New inline regressions cover native generation/root-epoch rejection before Host
access, captured-context tampering and bounded copied UTF-8 visible snapshots.
The existing evaluator gains the custom cohort rather than a second runner.
Initial compile failure (callback C calling convention and local-name shadowing)
is preserved by tool artifact147; both issues were repaired locally.

Focused Debug native build passed; direct real-C/SQLite/Lua native-root checks
passed53/53, options4/4, evaluator10/10. After review, absent-composer input is
guarded; its additional focused native regression passed2/2 (including root
import), and the actual changed candidate was rebuilt by the custom evaluator.
Exact commands/raw logs: parent `.artifacts/ui005/lua-native-check/` and
`run-lua-native-check.py`, `check-lua-input-guard.py`.

Actual `./tools/eval-starter --mode custom --optimize Debug --output
/home/ashman/Documents/spica/.artifacts/ui005/lua-native-custom` passed every
assertion. Inspected `initial-invalid-default.png`, `custom-render.png`,
`malformed-last-good.png` and `reopened.png`: real Unicode prompt, custom heading
and renderer prefix, actual Host response/code, same accepted run over valid
reload/default switch, malformed reload retention/error, physical painted
approval/cancel and retained approved tool output/cancelled status on restart.
The manifest records physical vd commands separately from deliberate module-file
changes; no internal input mutation or standalone consumer substitutes proof.
Source fingerprint `3fab96b8e8ded5c30530229e1f6b6689372052f0fd23d2d9c7a3422a7d4cc2f4`;
Debug binary `0999ffd394bbcadb3a62dbee4e9733087e21984a803806d9914ab0a9a4c8b350`.
No passing prior default cohort was repeated. Full assembled check/performance
and coordinator acceptance remain parent-owned.