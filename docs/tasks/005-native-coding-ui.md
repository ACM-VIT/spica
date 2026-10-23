# 005: Useful native coding UI

Status: review — actual default/custom native coding conversation is integrated and exercised; Main acceptance remains pending.
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

## Actual native Host checkpoint and successor ownership

Private App checkpoint `b393a5c` is integrated as shared `67f942a`, atop
runtime review repair `610ebef`. `ShipLeadContinue` now owns shared Git and
integration; UIShip005 retains the exclusive private UI allocation.

Producer checks passed 50/50 native-root tests and 10/10 evaluator regressions.
Real private-desktop Unicode prompt, response/code, geometry-derived approval,
completed tool result, second-prompt cancellation and reopened retained state
passed at `.artifacts/ui005/host-native-cohesive/manifest.json`. The frozen
binary is `spica-exercised`, SHA256
`51b7d2ae5470b66f54cf0bfc23683f8cf198ad0ad0d4a954ff2c6b8bf1832a7f`;
source fingerprint is
`36ee58584bf2bbffcc3892d67d595a4d0cc7d9c05bbfcf2133ca71dcb32c4246`.
Successor source review inspected command receipt identity, copied projections,
subscription refresh and shutdown ownership. The reopened screenshot visibly
retains cancelled status, Unicode response, code and approved inspection output.
This is explicit-state native proof, not yet the assembled custom-root gate.

UIShip005 continues independent XDG default/disconnect, followed by actual Lua
root/renderer/current-generation action integration and last-good retention.
Previously passing smoke is preserved, not rerun for confirmation.

Default startup/shutdown checkpoint `da6719e` is integrated as `2ff3985`.
Absolute XDG data home, or the independent HOME fallback, selects
`spica-native/conversation`; explicit state override remains available and no
legacy history is discovered. Presentation is joined before Host, while SDL
and its wake context remain alive. Producer options tests passed 3/3 and the
new actual `--mode conversation --default-state` cohort passed with isolated
XDG data in `.artifacts/ui005/native-default-state/manifest.json`.

Successor also exercised the previously unexecuted
`.artifacts/ui005/approval-lifetime-smoke.py` on frozen `b393a5c` binary:
real deny, 720×480 resize, close with live approval, reopen interrupted,
disabled F7 and further Unicode editing all passed. Manifest and inspected
screenshots are in `.artifacts/ui005/approval-lifetime/`. This is additional
explicit-state boundary evidence, not a claim about the future Lua candidate.

UIShip005 subsequently hit its runtime cap, leaving clean private HEAD
`a04c1c32aec969bc8f7edd49e25a26e5a2108283` after immutable script/domain
dependency consumption. Main explicitly transferred slot2 and the exact private
UI allowlist to `ShipLeadContinue.NativeLuaBridge` (sol-repair); old writer is
stopped. Slot1 is now `ShipLeadContinue.NativeMeasure`, evidence-only, with
performance sampling barred until the assembled candidate and exclusive lease.

## Integrated actual custom frontend

Replacement checkpoint `d5698fd11399723059fe3052c13362f8d081792e` is integrated
as `fe6a0ff`; NativeLuaBridge completed and released slot2. Source review covered
immutable captured targets/revisions/selection and stable command identity,
installed-generation/root-epoch rejection, staging/result sequencing, error
recovery, absent-composer input and reserved-action shutdown. The relevant
producer checks passed native-root 53/53, options 4/4, evaluator 10/10 and the
additional input-guard regression 2/2; evidence is under
`.artifacts/ui005/lua-native-check/` and `.artifacts/ui005/lua-native-custom/`.

One final shared `./tools/check` passed both safety modes (99/100 native,
one skipped; Python 35 OK/two skipped; successful builds, format and CLI smoke).
The final shared ReleaseSafe actual custom cohort then passed without rebuilding:
`.artifacts/ship-continue-final/native-custom-ReleaseSafe/manifest.json`.
Its source fingerprint is
`15dff3f0c025497f46579d6e97a8075493e81f03caa4e064b1f0e3edbf14844c`;
binary SHA256 is
`5188e7a353a59db6be4a400b37813628b0982fe7c1148620c9a53ba566711599`.
Integrator inspected `initial-invalid-default.png`, `custom-render.png`,
`malformed-last-good.png` and `reopened.png` in that directory. They show usable
initial fallback, actual custom-rendered Host bytes, preserved last-good output
with visible error and retained approved tool output/cancelled status.

NativeMeasure holds slot1's exclusive sampling lease only after all builds and
smokes stopped; its paired default/custom measurements are recorded separately.
No real Codex/OpenCode, physical latency, large-history or rich arbitrary custom
renderer acceptance follows from this finite native proof.

## Exclusive paired baseline

NativeMeasure completed one sequential 115-second process per root on the frozen
ReleaseSafe binary above, after all builds/smokes stopped, then released the
lease. Both actual Host/root/render assertions passed. Raw manifests, process
samples, screenshots and commands are under
`.artifacts/ship-continue-measure/assembled-fe6a0ff-pair1-{default,custom}/repeat1/`;
the combined result is
`.artifacts/ship-continue-measure/assembled-fe6a0ff-pair1-summary.json`.
Integrator inspected both `seeded.png` captures: completed real Host Unicode/code
and approved tool content, default versus actual custom composition.

| Measured quantity | Default | Custom |
| --- | ---: | ---: |
| Active paint samples | 370 | 372 |
| Total-paint p50 / p95 / p99, ms | 5.009 / 6.050 / 7.166 | 4.987 / 5.932 / 7.386 |
| Frame-work p50 / p95 / p99, ms | 3.306 / 4.160 / 5.285 | 3.256 / 4.205 / 5.037 |
| Active covered tree CPU, weighted one-core % | 4.869 | 4.817 |
| Idle covered tree CPU / idle paints | 0% / 0 | 0% / 0 |
| Observed complete-sample tree RSS / PSS maximum, bytes | 223735808 / 87545856 | 225787904 / 89611264 |
| Complete tree samples / total | 410 / 421 | 414 / 421 |

The observed app tree had one process, including its worker-thread CPU. Native
frame/cache telemetry had no drops or accessor failures. All three settled
text-cache tails were identical within each root and below existing bounds.
Settled RSS growth was zero; PSS changed +1024 bytes default and -9216 custom.
No observed application failure or evidence-backed core repair was identified.

Limits are explicit: this is one finite paired workload, not repeated-run
confidence, large-history/cache saturation, physical latency, GPU-memory or
maximum-FPS acceptance. All 450 resize commands were delivered per root, but
input-helper cost stretched active phases to about 47.15/47.17 seconds; the
sampler missed 45 requested 250-ms intervals per root. Eighteen/eleven
`/proc/PID/stat` enumeration ENOENT errors caused eleven/seven incomplete samples;
there were no root-exit or member-read failures. Missing PID identities prevent
proving whether those were unrelated processes or transient descendants.
Partial samples are excluded from complete-sample CPU/memory summaries, not
silently promoted to complete tree peaks. Main retains final acceptance.
