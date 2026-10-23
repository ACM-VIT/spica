# Architecture direction

Status: design constraints for the rewrite, not implemented public APIs. The starter retains native libraries and a runnable shell. Do not mistake their presence for implemented domain or extension layers.

## Boundaries

- Domain: stable project/thread/run/message IDs, revisioned commands/events, durable intent, completion receipts and capability checks. Own execution with no UI attached.
- Agent runtimes: deterministic fake first, Codex with ChatGPT sign-in first real adapter, then OpenCode v2. Each runtime owns its model/provider communication and tool execution; adapters normalize lifecycle, capability and permission events. Keep runtime sessions distinct from the model/provider selected inside them. See PROVIDERS_AND_ORCHESTRATION.md.
- Orchestration: an application-owned parent/child task tree dispatches through those adapters, enforces budgets/ownership and records review handoffs. It can run with no UI attached; view/config changes do not own its lifetime. Define contracts at task 001, implement the bounded scheduler after runtime and workspace gates.
- Storage: SQLite behind a small boundary; new application state separate from old Spica/T3 data. Migrations, export and explicit imports are tested work. Retained database code is a reusable implementation candidate, not the new schema.
- Native host: SDL window/input/presentation, Clay layout, retained shaping/rasterization/Unicode/content libraries. Measure and bound caches and queue work. A page cache alone does not bound metadata or document geometry.
- Extension host: versioned commands, read-only queries/subscriptions, lifecycle and native layout/input/render descriptions. No private structs or raw native pointers. Default UI uses the same public API as users.

## Customization proof

Allow full root replacement, individual message/tool renderers, styling, command/keymap/menu registration, local view state and versioned namespaced metadata. Offer rows/columns/splits, virtual data sources, editor/text/Markdown/code surfaces, overlays, semantic input/focus and scoped drawing. Users compose their own workflows from these parts. Do not encode a fixed list of supported workspace types or introduce mandatory chat/sidebar geometry into the public contracts.

Pick one script runtime by building one representative module. Require visible-only query/render behavior, small overhead and useful type/docs tooling. Neither Lua nor QuickJS is selected yet; do not implement two binding systems.

Config reload is transactional: stage pure definitions, validate, atomically activate registrations and dispose the old generation. Staging cannot dispatch commands/start jobs. Reject stale callbacks; cancel ephemeral jobs from disposed generations. Accepted durable execution survives reload. Retain the last working UI after an invalid config and provide a clean-start option. Trusted dotfiles are not a security sandbox; untrusted plugins need a separate design/process boundary.

Paged queries use a bounded-lifetime snapshot/cursor and stable ID anchors. Expired/invalid cursors request refresh rather than silently mixing pages. Notify views when newer revisions exist. Overwriting mutations carry expected_revision and return conflicts. Verify update-during-pagination and stale interaction scenarios before freezing the SDK.

## Ownership and effects

One owner for task execution, durable state and provider children. Commit intent before an external action; correlate effects/results and deduplicate commands. A crash with an ambiguous external result recovers to interrupted/unknown state rather than blindly repeating the action. UI metadata and extension callbacks cannot grant execution authority. Workspace/checkout identity travels with execution; it is not inferred from the current view.

Cancellation, provider exit and approval state need explicit transitions. Bound queues and apply backpressure instead of building unbounded streamed copies. Preserve original content and Unicode semantics when limiting presentation work.

## Reference and provenance

Spica retained base: df457029 (full Git object and recovery branch retain exact source). T3 behavior reference: https://github.com/pingdotgg/t3code . Pin a specific reference revision and acceptance scenarios in task 001 before designing feature contracts. There is no local T3 checkout supplied by this scaffold. Reuse behavior selectively; inspect and preserve source licenses before copying code. The inherited Spica root has no license file, which must be resolved before distribution.

Keep renderer investigations independent of the domain/API. GPU/native rendering is the initial path; SHM research is deferred by the owner and is not a release gate.

## Explicit product scope

Codex (including supported ChatGPT sign-in), OpenCode, and a bounded app-owned coordinator/worker workflow are requested product features. OMP remains the development harness. The initial app orchestrator supports delegate/message/wait/cancel, results, review disposition, explicit runtime/model/workspace selection and recovery. Cross-runtime execution follows the two adapter gates. A universal unattended automation platform is not required. See [integration design and verified sources](PROVIDERS_AND_ORCHESTRATION.md).
