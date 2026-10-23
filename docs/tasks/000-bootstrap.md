# 000: Rewrite bootstrap

Status: accepted
Owner: setup coordinator; Sol native-foundation and OMP-setup workers.
Base: df457029, preserved at backup/pre-native-rewrite-20261023-df45702.
Branch: rewrite/native-agent-workspace.
Scope: remove old app flow, retain reusable libraries/build tooling, build a runnable starter, configure OMP development roles and seed architecture/backlog/evaluation/ledger.
Acceptance: ./tools/check; offline OMP configuration/launcher checks; inspect a screenshot of the newly built native starter on a private desktop; clean up the desktop; commit the reviewed scaffold.
Result: native starter and OMP development scaffold prepared on this branch; bootstrap commit is the accepted base for task 001.

Retained: Unicode editing/shaping, native text/Markdown/images/highlighting/fuzzy/arena libraries, reusable UI helpers, POSIX/database boundaries, pinned dependencies, assets and meaningful regressions. Removed: old Pi runtime/protocol/storage/search/application features and app-specific UI flow. No legacy application data is opened.

Checks: ./tools/check passed; worker Debug and ReleaseSafe build/test runs passed (46 native tests passed, one skipped; 12 Python tests passed, two skipped). OMP offline checks passed: 17 launcher argv/cwd cases, 30 project settings, three agent parses, task examples and project skill discovery. V18 docs/settings are current installed evidence; parser source is v17.4 and does not establish live v18 inference behavior.

Visual evidence: .artifacts/starter/starter.png inspected; OpenGL/Wayland native foundation visible with Unicode labels. Real Escape input closed the window; private desktop cleaned up. ./tools/eval-starter rebuilds first and emits source/binary fingerprints plus command and log in .artifacts/starter/manifest.json. Integration check output: .artifacts/bootstrap/check.log.

Review: separate Sol source review found one P2 in the original smoke helper: stale binary could be associated with current source. Fixed by building before capture, checking source consistency and rejecting source/binary drift. Corrected evaluation passed. No other concrete native findings. Parent reviewed OMP startup/agent definitions; resolved conflicting no-commit vs Sol-integration rules and shortened the operational guide to 806 words.

Setup task IDs: spica-rewrite-native-foundation-r1; spica-rewrite-native-review-r1; spica-rewrite-omp-setup-r1 and r2. All setup workers are finished; no ongoing runner is installed.
Limitations: no domain/provider/config SDK implemented; no CI or frame telemetry yet; no model calls needed to validate the launcher; no measured performance improvement claim.
