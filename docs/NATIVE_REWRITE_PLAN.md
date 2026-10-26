# Native T3 rewrite: workflow-first completion plan

Audit date: 2026-10-26. Native source: `5bbdd5f`. T3 behavior reference:
`eb1510d2493cbf28600432d5193cc22a1af8f3d8`, inspected locally under
`.artifacts/references/t3code`. This is a source-based plan, not a new runtime
acceptance report. The user identified **Codex** as the provider whose prompt
failed; the symptom, running binary and failure stage are still unknown.

## Approach

Continue the existing native foundation. Keep Zig 0.16, SDL3, Clay, retained
Unicode/content libraries, SQLite, the durable Host and the protected Lua bridge.
Translate T3's useful behavior into native components; do not port its React/DOM
implementation or start another shell rewrite.

Make the unit of completion a user workflow: choose a project, send, see progress,
answer a request, inspect the result, continue the conversation, close and reopen.
Implement each workflow through public Host commands/queries, the real provider
adapter, and native input. A backend API or screenshot alone does not finish it.

Preserve these ownership boundaries:

1. Host owns durable commands, projects, checkout bindings, threads, sessions,
   runs, approvals and child processes; accepted work outlives UI reloads.
2. Adapters translate capabilities and correlated provider events. Provider
   differences stay explicit; UI does not gain provider-process ownership.
3. Presentation workers decode/shape bounded visible content. History stays on
   disk; navigation and catalog search use pages, not ever-growing arrays.
4. Native view owns focus, drafts, selection, menus and scroll. Lua describes
   composition/actions; native admission owns execution authority.
5. Test tooling delivers ordinary input and observes outcomes. It does not
   maintain a second conversation engine.

## What exists, and what is misaligned

These are source findings at the audit revision. Historical evidence in task
records is useful but has not been rerun for this planning task.

- **Substantial foundation exists:** durable intent/receipts, fake provider,
  Codex/OpenCode adapters, native composer, paged rich content, multiple thread
  views, explicit model selection, protected scripting and bounded orchestration.
  Preserve and test these instead of scheduling their wholesale replacement.
- **Conversation history is not provider context continuity.** Every ordinary
  `thread_send` currently allocates a fresh session and plans `.open.create`
  (`src/domain.zig`, thread-send admission). Codex uses `thread/start`; OpenCode
  uses `session/new`; the subsequent `turn/start` or `session/prompt` supplies
  only the current prompt as conversation input.
  Restore support exists but this path does not select it. A visible two-turn
  transcript therefore does not establish that the second turn sees the first.
  This is a first-priority correctness gap.
- **Prompt limits disagree.** `src/text/composer.zig` accepts 64 KiB; Host rejects
  an accounted provider start frame over 4,096 bytes (`src/domain.zig`,
  `src/contract.zig:frameBytes`). IDs/header consume part of that limit. UI can
  show Send enabled and then report generic `admission_limit`. This is a proven
  source mismatch, not the proven cause of this user's failed Codex prompt.
- **Connected is not successful inference.** Existing-account/model discovery
  has historical native evidence. It does not prove entitlement, provider turn
  startup, streamed output or a real file change. Accepted command receipts also
  precede provider execution. Each stage needs a separate observable outcome.
- **Bounded lists currently limit discoverability.** The view holds 32 models,
  eight efforts and 32 thread cards. Sidebar search filters loaded metadata.
  Keep bounded resident pages, but make older threads and additional models
  reachable through paged search. Do not silently substitute a model.
- **Ordinary coding workflows remain absent/partial:** editable durable titles,
  queued follow-ups/steering, structured provider questions, file/image intake,
  full-history search, native changed-files/diff inspection and external-tool
  handoff. Existing image libraries and run state `queued` do not implement those
  user workflows. Workspace inspection currently has a backend/CLI foundation.
- **Orchestration source is ahead of some receipts.** Current source includes
  provider-facing result/review/catalog tools (`src/orchestration_tools.zig`,
  checkpoint `d6b5c5e`), while older task prose still calls them deferred. Audit
  the current bridge, then verify provider-driven use. Do not reimplement them
  based on old status prose. Codex/mixed live execution remains a separate gate.
- **Customization is a proof, not full component replacement.** Theme/root and
  bounded renderer/action support exist; full component slots, command/keymap
  registration and extension compatibility remain subsequent work.
- **Status documents drifted.** ROADMAP called everything pending and Lua
  unselected; architecture still described all accounts as isolated despite the
  existing-Codex-login default. Historical “running” task labels do not identify
  current workers. Use a current workflow acceptance index with revision-tagged
  evidence rather than interpreting a checkpoint as product acceptance.

Pinned T3 reference examples: `apps/web/src/components/chat/useComposerSend.ts`,
`ComposerPrimaryActions.tsx`, `QueuedRunsControl.tsx`,
`ComposerPendingUserInputPanel.tsx`, `ComposerAttachmentStrip.tsx`,
`sidebar/SidebarThreadRow.tsx`, `files/FileBrowserPanel.tsx`, and
`search/ProjectContentSearchDialog.tsx`. Compare behavior, failure handling,
keyboard/focus and loading states as well as appearance. This is selected native
coding-workflow parity, not a promise to reproduce every T3 feature.

## Ordered implementation checklist

Unchecked items are future acceptance work, including revalidation of existing
implementation. They do not all mean the underlying code is absent.

### A. Make Codex Send diagnosable and reliable — first delivery

- [ ] Capture exact binary/source/build identity and the failing stage: input
  ignored, disabled, command rejected, accepted/start failed, stuck, or terminal
  result missing. Record prompt byte count; content is opt-in.
- [ ] Expose bounded command ID, receipt/rejection reason, run/session/turn IDs
  and first actionable provider diagnostic alongside existing readiness/focus
  observations. Show a useful error in the GUI, with a copyable diagnostic report.
- [ ] Reproduce each stage with offline protocol fixtures, including expired
  auth, unavailable model, disconnect, startup failure and error after acceptance.
  Preserve draft on rejection and newer draft text when an earlier send resolves.
- [ ] Align composer/preflight/Host/provider size contracts. First provide an
  accurate actionable refusal; then design bounded prompt storage/reference or
  chunk transport for useful coding prompts. Review memory/protocol budgets
  explicitly instead of silently raising the 4 KiB limit.
- [ ] Verify click and Enter each produce exactly one accepted command/run;
  empty Send is disabled; Shift+Enter/IME/Unicode/paste preserve intended text.
  Test exact accounted-frame boundaries, including multibyte UTF-8.
- [ ] Run a separately authorized installed-Codex task in a disposable project:
  actual native Send, streamed response, independently verified file effect,
  error/cancel behavior and restart. Reuse only the selected authorized account;
  no history import or automatic external-inference retries.

Gate: every failed Send has an identifiable stage and visible recovery route;
an installed Codex success proves actual requested work. If entitlement prevents
the live gate, record it as blocked and continue independent offline work.

### B. Make a conversation actually continue

- [ ] Decide durable upstream session binding per thread, including exact
  runtime/account/workspace identity and rules for model/effort changes.
  Prefer supported resume/continuation; never silently create a contextless
  replacement session when resumption fails.
- [ ] Implement session reuse/resume through Host effects and adapter contracts,
  preserving deduplication, process ownership and unknown-outcome recovery.
  Decide explicit fork/new-chat behavior for incompatible selection changes.
- [ ] Prove a second turn uses information supplied only in the first turn,
  both while running and after application restart. Verify upstream session
  correlation deterministically; a plausible model answer alone is insufficient.
- [ ] Cover provider death, missing upstream session, pending approval,
  cancellation races, changed checkout and crash after an external effect.
  Never automatically replay ambiguous work.

Gate: one native thread is a coherent conversation; retained visual history and
provider context agree, with an explicit recovery path when they cannot.

### C. Extract the GUI-driving CLI — alongside A after observation contract

- [ ] Extract shared private-desktop target/input/wait/manifest helpers from
  `tools/eval-starter`, `tools/eval-provider-setup` and `tools/eval-projects`.
- [ ] Implement the CLI contract below and deterministic failure exit codes.
- [ ] Add missing semantic target coverage for menus, history, background runs
  and task controls; include freshness/session/command correlation.
- [ ] Port one Send/restart and one failure scenario to the shared CLI, keeping
  existing regression assertions intact. Remove duplicated helpers only after
  equivalent behavior is established.

Gate: one command runs an offline real-GUI scenario and leaves a small actionable
failure packet. Domain-only tests remain separately labeled.

### D. Finish the daily coding loop

- [ ] Paged project/thread/model discovery and search; durable title editing;
  explicit archive/delete semantics with appropriate recovery if added.
- [ ] Switch chats/projects during active work without losing draft, undo,
  selection, scroll, exact provider choice or background status.
- [ ] Integrate bounded changed-file list and selected-file diff using the
  existing workspace inspector on a worker. Bind every result/action to its
  captured checkout; reject stale/wrong-checkout requests.
- [ ] Add explicit external editor/terminal open and file-context selection.
  Define project-content search independently from transcript search.
- [ ] Specify bounded follow-up queue, edit/cancel/order and restart behavior.
  Add steering only where provider capability supports its defined semantics.
- [ ] Add typed structured-question responses, distinct from permission
  allow/deny, with expiry, keyboard navigation and exact request correlation.
- [ ] Define bounded attachment storage/lifetime and capability negotiation;
  implement visible add/remove/error/preview and supported provider transport.
- [ ] Compare native conversation/tool/code/error/approval states with the pinned
  T3 reference at multiple sizes using actual private-desktop input/screenshots.

Gate: complete a small coding task, inspect changes, ask a contextual follow-up,
switch projects, return and reopen without losing work or target identity.

### E. Complete recovery, orchestration and data portability

- [ ] Audit current delegate/message/wait/cancel/result/review/catalog paths;
  prove coordinator use of app tools, exact child model/options/workspace,
  bounded concurrency/budgets, useful native progress and targeted cancellation.
- [ ] Separate fake, Codex-only, OpenCode-only and mixed-runtime acceptance.
  Unsupported capability and unavailable account/quota stay explicit.
- [ ] Exercise shutdown/crash/restart with queued follow-ups, live child tasks,
  outstanding questions/approvals and partially delivered effects.
- [ ] Define versioned export/backup/import and migration/rollback fixtures.
  Never import existing Spica/T3 histories or credentials implicitly.
- [ ] Validate large rich-history import, distant jumps, reflow, copy/selection
  and cache plateau. Obtain the missing original 523,183-byte fixture through
  explicit authorization or record an explicit acceptance-scope revision;
  generated content is a separate test, not a provenance substitute.

Gate: recovery remains honest and data remains usable without duplicate effects;
one failed child does not corrupt unrelated work or its parent's identity.

### F. Stabilize customization, performance and release

- [ ] Expand public component/input/keymap/command/subscription primitives only
  against working native workflows; version the Lua-independent contracts and
  test stale callbacks, allocation failures and last-good reload.
- [ ] At every affected slice run narrower checks, then `./tools/check` for
  integration in Debug/ReleaseSafe; preserve Unicode/parser/platform/leak tests.
- [ ] For rendered changes inspect actual private-desktop interactions/screenshots.
  On frozen candidates serialize performance cohorts against builds/profiling:
  samples, p50/p95/p99, CPU, whole process-tree RSS/PSS, cache plateaus, telemetry
  coverage and instrumentation overhead. Keep existing budgets; investigate
  regressions. Include provider child processes in real-runtime workloads.
- [ ] Validate on identified low-end Linux hardware; machine-specific paint
  measurements do not prove physical input-to-photon latency or universal speed.
- [ ] Complete install/update/uninstall, data upgrades/recovery, fonts,
  accessibility/keyboard and physical-desktop checks; resolve source licensing
  and preserve reused-code provenance before distribution.

Full terminal emulation, embedded browser, mobile/remote clients, more operating
systems, marketplace, built-in boards and unattended scheduling remain deferred.
GPU rendering stays the starting path; SHM is not a gate.

## Proposed GUI CLI contract

The commands below are a design, **not commands implemented by this task**.
Start with a small Python wrapper around existing `vd` and read-only snapshots;
an application command server/socket is unnecessary for the first useful version.

```text
spica-ui launch --private --provider fake --output .artifacts/gui/example
spica-ui attach --session <private-vd-session> --window <id> --observations <path>
spica-ui snapshot
spica-ui targets
spica-ui text --target composer.input --file <fixture.txt>
spica-ui click command.send
spica-ui key Return
spica-ui wait --command <id> --receipt accepted --timeout 15s
spica-ui wait --run <new-run-id> --state completed --timeout 30s
spica-ui screenshot --output <path.png>
spica-ui scenario send-restart --provider fake --output <fresh-directory>
spica-ui stop
```

Launch creates isolated app state and a private desktop; it does not silently
build, authenticate or invoke a real provider. Attach validates the intended
session/window/process/candidate. Input commands resolve semantic targets from
the latest painted bounds, validate enabled/visible state, translate through
actual compositor geometry and deliver ordinary pointer/keyboard/clipboard input.
After resize/layout change, resolve again. Do not write the database, call Host
Send directly or mutate internal UI state and label it GUI interaction.

Extend the bounded observation schema with process/session nonce, observation and
layout revision, command receipt/reason, exact selected provider identity with
account reference redacted, workspace binding revision and provider error class.
Publish atomically; tolerate unavailable observations. An event-driven idle app
need not repaint just because a client polls. No permanent polling/file export is
enabled in ordinary launch. Draft/transcript payload export must be opt-in and
redacted in routine reports.

Each action records before/after observations and input timestamps. Outcomes are
separate: input delivered → GUI changed → command accepted/rejected → run
terminal → expected file/result verified. Match the captured thread and newly
correlated run; an old completed run cannot satisfy a new wait. Use bounded
timeouts and distinct failures for missing/disabled/stale target, timeout,
admission rejection, provider failure and assertion failure. Save last snapshot,
screenshot and redacted diagnostic on failure. Never retry Send automatically
after an unknown outcome.

Existing `--automation-live` and `--automation-output` export read-only snapshots;
they are not an existing control server. Preserve separate labels for ordinary
desktop input, synthetic protocol events and stopped-app crash-fixture mutation.
Record source SHA, binary hash, build mode, scenario, provider kind, input method,
receipt/run IDs, expected artifact and limitations in ignored `.artifacts/`.

## Execution and acceptance discipline

First implementation packet: A plus the minimal C observation/driver slice.
Second: B, with its public session contract agreed before adapter changes.
Then D, E and F; independent fixture/UI work can continue while a live provider
gate is blocked. Performance and ownership checks apply throughout, not just F.

Start two Sol workers with disjoint ownership: Host/provider/session contracts
have one owner; native observations/CLI/UI have another. Astra reviews interfaces,
actual diffs and evidence. Use reviewed committed bases for private worktrees;
exactly one designated Sol Git owner in a shared checkout. Checkpoint cohesive
tested slices, record SHAs, and serialize final integration after writers freeze.

For each workflow track separately: source present, automated tests, offline GUI,
installed provider metadata/auth, live execution, and human acceptance. Every
passed cell needs candidate and evidence; unavailable is not passed. This plan's
checkboxes remain open until their named gates are met. Historical task receipts
remain intact and do not substitute for current failing-workflow acceptance.
