# 005: Useful native coding UI

Status: independent source preparation; production edits depend on accepted task003 and pinned task004 public API, not task004 completion.
Authorization: user requested remaining roadmap tasks and concurrent independent Sol work. No new preset, provider backend, scripting choice or orchestration scope.
Owner: Astra decides interfaces/acceptance; NativeUI005 maps retained native UI primitives and owns its assigned implementation after the dependency gate.
Base: task003 frozen fake3012c820/native repairce4fd533 pending shared integration. Runtime source preparation is `.artifacts/domain004/preparation.md`; its Host API is a proposal until Astra pins it.

Design: one default coding interface with bounded transcript and Unicode composer, native selection/keyboard focus, streamed Markdown/code/tool content, approval/cancel controls and accurate persisted run state. UI invokes domain commands/queries/subscriptions only; it never owns adapter lifetime or external dispatch. Lifetime of domain Host outlives replaceable roots. Native SDL event wake bridges domain output without polling idle. No alternate workspace preset.

Preparation ownership: `.artifacts/ui005/` only; all tracked files and other private worktrees read-only. No Git changes, builds/tests/formatters or UI measurements during source mapping. Parent Git owner Infra002. Map existing composer/input/text/content and retained layout/rendering entrypoints, precise file split and minimal glue consuming proposed Host submit/query/subscribe/drain. Establish actual missing primitives, widget geometry and automation surfaces, allocation/virtualization bounds and concrete private-desktop real-input acceptance scenarios. Do not implement mocked domain behavior or rebuild existing text libraries.

Production acceptance: useful actual composer and transcript, Unicode/selection/focus/scroll, bounded visible decoding/layout, streaming remains interactive, approvals and cancellation through durable commands, actual private-desktop captures/input/performance evidence. Shared milestones004–006 additionally prove restart and replaceable root; task005 cannot silently substitute headless tests.

Packet bounds: verified gpt-6.1-sol; no grandchildren; 30-minute hard/40-request soft preparation. Deliver `.artifacts/ui005/preparation.md` with source-backed exact ownership proposal and source limitations. No production checkpoint expected for read-only mapping. Future private implementation commits cohesive code/tests/docs after relevant checks; no checkpoint handshake for independent work.
