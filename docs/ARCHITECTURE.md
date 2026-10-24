# Architecture direction

Status: the durable Host, provider adapters, bounded native conversation and protected Lua root/action bridge are implemented. Shared presentation settings, native-root themes and custom-node styles are implemented and verified through native input. The task ledger records checks, resource measurements and limitations; future surfaces are identified separately.

## T3-compatible presentation

T3 Code is the default interaction and visual reference. Native implementation is Zig/SDL3/Clay; React, the DOM and Electron are not part of Spica's renderer. Reference source is pinned at `eb1510d2493cbf28600432d5193cc22a1af8f3d8` under ignored `.artifacts/references/t3code` (MIT). Compare component behavior as well as screenshots: sidebar hierarchy and selected rows, thread header, message/tool/code blocks, composer, provider menus, dialogs, focus and keyboard states. A similar shell does not establish complete feature parity.

The system has five ownership layers:

1. **Durable Host:** owns projects, registered checkouts, threads, commands, runs, approvals and provider processes. Its public commands and paged queries remain usable with no window or script attached.
2. **Bounded projection:** `Conversation` consumes Host pages and presentation-worker output. It copies borrowed values into bounded visible metadata/content, retains stable history anchors, and supplies read-only snapshots. It never loads complete history just to paint a frame.
3. **Presentation contract:** `ui/design.zig` defines by-value colors and layout metrics. Script descriptors declare semantic node IDs, bounded styles and explicit action IDs. The default shell and custom roots consume these values through the same Clay/text/input primitives. This first expansion shares settings and primitives; it does not yet represent every native component as a replaceable descriptor node.
4. **Native presentation:** Clay computes rectangles; retained text/content libraries shape and render visible text; `View` owns transient focus, selection, menus, per-thread drafts and scroll. Pointer actions use painted rectangles. These lifetimes are separate from Host execution.
5. **Lua configuration:** the protected worker produces validated descriptors and action proposals, serving the requested Neovim-like local scripting model. The standalone `native` root customizes the complete default screen; row/column roots replace composition. Native admission retains exact captured targets, revisions and command identity. Lua files are selected explicitly, edited locally and reloaded with F5. External UI transport is outside this request.

Layout/theme reload is atomic with the visual result: reject invalid values and preserve the complete previous root, renderer and settings. F9 switches the installed custom presentation off and restores default settings; it does not restart providers or accepted runs. Settings are bounded values, with no per-frame configuration parsing, arbitrary native pointers or additional idle polling.

Current expansion scope is the main conversation shell, shared colors/layout, custom-node sizing/spacing/paint, and a runnable native-theme module. Full component slots, command/keymap registration, project search, editable durable titles and change-inspection panels require subsequent contracts and acceptance scenarios. Full terminal emulation and an embedded browser remain deferred. Unsupported backend capabilities must not appear as functional controls.

Rendered changes require source-based comparison, actual private-desktop input/screenshots, Debug/ReleaseSafe integration checks and serialized frame/CPU/process-tree RSS/PSS measurements. Existing budgets are preserved. Measurements establish the tested machine/workload only, not physical input latency or low-end hardware acceptance.

## Boundaries

- Domain: stable project/thread/run/message IDs, revisioned commands/events, durable intent, completion receipts and capability checks. Own execution with no UI attached.
- Agent runtimes: deterministic fake first, Codex with ChatGPT sign-in first real adapter, then OpenCode v2. Each runtime owns its model/provider communication and tool execution; adapters normalize lifecycle, capability and permission events. Keep runtime sessions distinct from the model/provider selected inside them. See PROVIDERS_AND_ORCHESTRATION.md.
- Orchestration: an application-owned parent/child task tree dispatches through those adapters, enforces budgets/ownership and records review handoffs. It can run with no UI attached; view/config changes do not own its lifetime. Define contracts at task 001, implement the bounded scheduler after runtime and workspace gates.
- Storage: SQLite behind a small boundary; new application state separate from old Spica/T3 data. Migrations, export and explicit imports are tested work. Retained database code is a reusable implementation candidate, not the new schema.
- Native host: SDL window/input/presentation, Clay layout, retained shaping/rasterization/Unicode/content libraries. Measure and bound caches and queue work. A page cache alone does not bound metadata or document geometry.
- Extension host: versioned commands, read-only queries/subscriptions, lifecycle and native layout/input/render descriptions. No private structs or raw native pointers. Default UI uses the same public API as users.

## Customization proof

Allow full root replacement, individual message/tool renderers, styling, command/keymap/menu registration, local view state and versioned namespaced metadata. Offer rows/columns/splits, virtual data sources, editor/text/Markdown/code surfaces, overlays, semantic input/focus and scoped drawing. Users compose their own workflows from these parts. Do not encode a fixed list of supported workspace types or introduce mandatory chat/sidebar geometry into the public contracts.

Lua 5.4.9 was selected by the protected root/renderer/action proof. Keep its concrete binding behind the runtime-independent native descriptor contract; do not introduce a second interpreter for UI parity. Visible-only snapshots, bounded allocation/instruction budgets and native-owned action admission remain required. See [the scripting contract](contracts/scripting.md).

Config reload is transactional: stage pure definitions, validate, atomically activate registrations and dispose the old generation. Staging cannot dispatch commands/start jobs. Reject stale callbacks; cancel ephemeral jobs from disposed generations. Accepted durable execution survives reload. Retain the last working UI after an invalid config and provide a clean-start option. Trusted dotfiles are not a security sandbox; untrusted plugins need a separate design/process boundary.

Paged queries use a bounded-lifetime snapshot/cursor and stable ID anchors. Expired/invalid cursors request refresh rather than silently mixing pages. Notify views when newer revisions exist. Overwriting mutations carry expected_revision and return conflicts. Verify update-during-pagination and stale interaction scenarios before freezing the SDK.

## Ownership and effects

One owner for task execution, durable state and provider children. Commit intent before an external action; correlate effects/results and deduplicate commands. A crash with an ambiguous external result recovers to interrupted/unknown state rather than blindly repeating the action. UI metadata and extension callbacks cannot grant execution authority. Workspace/checkout identity travels with execution; it is not inferred from the current view.

Cancellation, provider exit and approval state need explicit transitions. Bound queues and apply backpressure instead of building unbounded streamed copies. Preserve original content and Unicode semantics when limiting presentation work.

## Reference and provenance

Spica retained base: df457029 (full Git object and recovery branch retain exact source). T3 behavior reference: https://github.com/pingdotgg/t3code, pinned locally as described above. Reuse behavior selectively; inspect and preserve source licenses before copying code. The inherited Spica root has no license file, which must be resolved before distribution.

Keep renderer investigations independent of the domain/API. GPU/native rendering is the initial path; SHM research is deferred by the owner and is not a release gate.

## Explicit product scope

Codex (including supported ChatGPT sign-in), OpenCode, and a bounded app-owned coordinator/worker workflow are requested product features. OMP remains the development harness. The initial app orchestrator supports delegate/message/wait/cancel, results, review disposition, explicit runtime/model/workspace selection and recovery. Cross-runtime execution follows the two adapter gates. A universal unattended automation platform is not required. See [integration design and verified sources](PROVIDERS_AND_ORCHESTRATION.md).
