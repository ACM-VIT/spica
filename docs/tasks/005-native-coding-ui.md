# 005: Useful native coding UI

Status: running — source preparation reviewed; native implementation allocated concurrently with task004.
Authorization: user requested remaining roadmap tasks and concurrent independent Sol work. No new preset, provider backend, scripting choice or orchestration scope.
Owner: Astra decides interfaces/acceptance; NativeUI005 maps retained native UI primitives and owns its assigned implementation after the dependency gate.
Base: accepted task003 `3c18aac45d732f217bc9af98d466f3c569c8dd61`. Assigned private worktree `.artifacts/worktrees/005-ui`, branch `task/005-ui`, starts at that committed base. Task004 Host gateway and bounded projection fields are pinned in its packet; DomainPrep004 publishes concrete types.

Design: one default coding interface with bounded transcript and Unicode composer, native selection/keyboard focus, streamed Markdown/code/tool content, approval/cancel controls and accurate persisted run state. UI invokes domain commands/queries/subscriptions only; it never owns adapter lifetime or external dispatch. Lifetime of domain Host outlives replaceable roots. Native SDL event wake bridges domain output without polling idle. No alternate workspace preset.

Preparation ownership: `.artifacts/ui005/` only; all tracked files and other private worktrees read-only. No Git changes, builds/tests/formatters or UI measurements during source mapping. Parent Git owner Infra002. Map existing composer/input/text/content and retained layout/rendering entrypoints, precise file split and minimal glue consuming proposed Host submit/query/subscribe/drain. Establish actual missing primitives, widget geometry and automation surfaces, allocation/virtualization bounds and concrete private-desktop real-input acceptance scenarios. Do not implement mocked domain behavior or rebuild existing text libraries.

Production acceptance: useful actual composer and transcript, Unicode/selection/focus/scroll, bounded visible decoding/layout, streaming remains interactive, approvals and cancellation through durable commands, actual private-desktop captures/input/performance evidence. Shared milestones004–006 additionally prove restart and replaceable root; task005 cannot silently substitute headless tests.

Packet bounds: verified gpt-6.1-sol; no grandchildren; 30-minute hard/40-request soft preparation. Deliver `.artifacts/ui005/preparation.md` with source-backed exact ownership proposal and source limitations. No production checkpoint expected for read-only mapping. Future private implementation commits cohesive code/tests/docs after relevant checks; no checkpoint handshake for independent work.

## Reviewed production allocation

Astra reviewed `.artifacts/ui005/preparation.md` and retained EditorView geometry. Reuse the existing composer, text engine, Markdown parser, highlighter, Clay arena and hit/clip primitives. Implement one default coding root with the preparation's finite transcript/worker caches, exact source versus rendered-selection distinction, ordinary SDL text/keyboard/pointer input, controls and authoritative domain status. No provider/store imports in UI. App holds outstanding command identity across replaceable roots; main owns Host lifetime, joins before SDL/context destruction.

NativeUI005 owns private Git and exactly: existing `src/main.zig`, `src/app.zig`, `src/options.zig`, `src/ui/clay.zig`, `src/ui/editor_view.zig`, `src/ui/clipboard.zig`, `src/native/automation.zig`, `src/native/metrics.zig`; new `src/ui/coding.zig`, `src/ui/transcript.zig`, `src/content/presentation.zig`; obsolete `src/ui/foundation.zig` removal after all callers cut over; `tools/eval-starter`, `build/eval_starter_test.py`, `docs/EVALUATION.md`, `README.md`, `docs/tasks/005-ui-receipt.md`. Inline meaningful tests in owned modules. No domain/build/test-root or retained C/parser/composer changes without explicit transfer. DomainPrep004 owns narrow dependency/test imports in build.zig/src/test.zig.

Live automation is bounded read-only, derived from actual painted target geometry and current generation; no input/state mutation endpoint. Extend existing evaluator, not a duplicate runner. Preserve frame/resource evidence; text-cache changes outside paint require explicit observation rather than carrying stale state. Escape is local editing dismissal, Ctrl+Q/window-close lifecycle; update runner intentionally.

First working slice: retained composer/controller/render/focus with real-input proof. Next: bounded transcript/rich worker/approval/cancel and Host result integration. Final: actual temporary-state streaming interaction, bounded memory/cache evidence and restart integration. Commit each cohesive verified slice without end-only batching or unrelated setup handshakes. Source edits proceed while concrete domain types are published; consume reviewed dependency checkpoints, never copied mutable sibling files or mock domain replacements. All source/checkpoint integration remains explicit under Infra002; relevant checks freeze owned candidates, not independent workers.

## Resumed shipping integration

ScriptShip006 owns serialized shared integration of the task004–006 allowlists;
UIShip005 remains private UI writer/Git owner. Preserved native checkpoints
`17ff30c`, `374bace`, `6ff9472`, `c391f66`, `d5838e3` are integrated as
`40f158b`, `b378d30`, `4e088b0`, `e3c6fb9`, `134b622`. Duplicate domain/text
dependency cherry-picks were intentionally omitted; accepted text repairs stay
in the shared tree.

Reviewed rich-surface source/receipt includes retained native tile lifetime,
rendered-byte selection, bounded command intents and actual painted automation
controls. Producer evidence: 35/35 focused native tests and actual private
desktop Unicode editor smoke in `.artifacts/ui005/rich-native/` and
`.artifacts/ui005/rich-native-editor/`. This slice intentionally has disabled
controls until actual Host hookup; it is not task005 acceptance.

After yielding its verified candidate, slot2 was explicitly re-reserved to the
same UIShip005 session, which checkpointed it as `d5838e3` without rerunning the
passing editor smoke. It consumed immutable domain chain through `50b65b6` and
continues the real App/main Host wake/drain/query/command bridge, then minimal
Lua custom-root/renderer/action integration. Domain owns build.zig/src/test.zig;
no duplicate Host, providers, store or copied mutable sibling source.
