# 002: Repeatable build and fast core checks

Status: accepted
Owner: Astra coordinates; Infra002 owns implementation and sole Git role.
Base: 0d82092f0578310903d5ff49556acc820ed7179b on rewrite/native-agent-workspace; index/worktree clean before this record.
Dependencies: task 001 accepted; met.
Authorization: user explicitly requested continuation through all sixteen remaining roadmap tasks. The previous task-001-only stop applies to that historical batch, not this continuation. No unattended goal loop, scheduler, account/profile rewrite or blanket approval is authorized.

Scope: ROADMAP item 2 only: repeatable one-command build/check, pinned dependencies, Linux CI, separate temporary fixtures, Debug/ReleaseSafe and allocation-aware checks. Reuse retained build/test machinery; no restored legacy app or speculative dependency upgrades.

Implementation/Git allowlist: tools/check, build.zig, new src/core_test.zig, src/text/composer.zig (allocation regression only), new .github/workflows/check.yml, CONTRIBUTING.md, README.md, build/driver.py, build/driver_test.py, new docs/tasks/002-build-receipt.md. Evidence: .artifacts/infra002/. Native003 independently maps native/fake-harness seams and owns .artifacts/native003/ only. Astra owns this record, task 003 record and shared ledger index; no worker may stage these ledger changes yet.
Git owner: Infra002 only, exact implementation allowlist above. Freeze cohesive edits before relevant checks/checkpoints; no other worker mutates Git.

Discovery gate: identify current commands, pins, CI, test inventory and isolation/allocation regressions; report precise missing acceptance behavior and smallest exact-file candidate. Do not run build/lint/tests/formatters mid-flight. Worker budget: 30 minutes hard, 40 requests soft/60 forced yield, no grandchildren; verified gpt-6.1-sol only. Source mapping should be bounded so the same worker can implement after ownership assignment.

Acceptance: actual build/check commands in both safety modes, fast isolated core check, meaningful allocation/error regressions preserved, reproducible CI command, fresh temporary state and an exercised CLI smoke. Serialized verification after edits freeze; ./tools/check is mandatory integration. Small cohesive verified checkpoints throughout; before staging check branch/HEAD, clean index and exact staged diff. Never broad-stage, switch/reset/stash/push. Export actual diffs and raw evidence for Astra review.

Decisions: default ./tools/check covers Debug and ReleaseSafe with visible exercised/cached distinction; --core runs dependency-light core regressions using libunibreak/libc, not the whole SDL/parser/platform graph. Direct driver checks exact Zig pin. CI uses the existing checksum bootstrap and same local check entrypoint; host compiler/SQLite/desktop prerequisites remain non-hermetic and explicit. Existing temporary fixture isolation is sound; preserve it. Add meaningful allocation-failure/allocation-free editor regression rather than redundant wiring tests. Existing native --help/invalid-option paths provide CLI smoke without app feature changes.

Attempts: round 1 implementation, one core compile repair (hit-target dependency pulled SDL/Clay; removed from isolated core only and retained full-suite coverage). Astra inspected actual Infra002 header: openai-codex/gpt-6.1-sol, no fallback, medium/default, session 01a1693b-d5ed-730f-a6e9-7ab7d6e55987.

## Acceptance

Astra reviewed actual candidate diff, composer allocation ownership/test, driver regression context, raw core/full check output, CI tool checksum provenance, workflow syntax and configuration diffs. Accepted infrastructure source checkpoint e9ea99c38077233b503e55af20c91875c69b4426 follows core checkpoint 0767377bc244f39ebec7b844398a8208f773337b; receipt checkpoint 16bf57ac0d1f806ec9a341bdc74db0ddd19522cb. ./tools/check --core exercised 15/15 tests in each safety mode. ./tools/check exercised 47/48 native tests (one platform skip) plus 15 Python cases (two platform skips), per mode. Existing help passed in both modes; invalid CLI rejected. Compilation cache reuse is distinguished from test execution.

Additional explicitly authorized workflow paths: .omp/config.yml, docs/AGENT_LOOP.md and AGENTS.md. Checkpoint b3a7822758e7ea127e63be67e13a5160b4566d5b raises project ceiling to three and documents asynchronous pinned evaluation/isolated high-reasoning repair. Offline YAML/shell/config invariants checks passed; live concurrency reload is not claimed. Checkpoint 830f355fd4c79d8493ec8f3902369e4e87ae4bfe adds the user's two-line video-game/data-intensive performance principle below the AGENTS.md title; Astra inspected it.

Evidence: .artifacts/infra002/review-manifest.json, manifest.json, candidate.diff, final-candidate.diff, integration-1.log, core-results.json, integration-results.json, ci-syntax.log, config-check.log, zig-checksum-source.json, async-evaluation.diff and engineering-guidance.diff. Durable receipt: docs/tasks/002-build-receipt.md. One overwritten failed compile log is disclosed; no check was rerun to manufacture a reproduction.

Limits: remote CI/clean Ubuntu provisioning not executed; local dependency cache used without bootstrap/packages. System prerequisites remain non-hermetic; C/FFI dependencies are not sanitizer-covered by the Zig safety matrix. Native003 independently exercised the unchanged ReleaseSafe shell asynchronously after builds stopped; its task003 baseline records sampled RSS/PSS/CPU, real resize/Escape and absent frame telemetry, not a task002 performance improvement.

Final bookkeeping: Infra002 alone may checkpoint Astra's frozen task002/task003/index records and create the explicitly assigned task003 worktrees from that committed base. No dependent source before the acceptance/base checkpoint. User continuation remains authorized; task003 is next.
