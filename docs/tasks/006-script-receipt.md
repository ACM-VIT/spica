# 006 script runtime receipt

Status: review; standalone implementation complete, native/Host integration not accepted.
Private branch `task/006-script`, allocated base `81db41af608cb2b918378004ea5f4234557262c7`.
Preserved dependency checkpoint `b3e8f976873fcd48faa4b3e9e98dd6ecbbe87dc1`;
implementation candidate is the commit containing this receipt. Resume found no
previous receipt, four untracked runtime/example paths, and a clean index.

Entrypoints: `src/script.zig`, `src/native/script_lua.c/h`, `src/script_test.zig`,
`examples/minimal.lua`, `docs/contracts/scripting.md`. Protected C-only Lua 5.4.9,
owned worker, capped VM, finite descriptors, last-good staged reload, generation
and declared-action gates, captured immutable targets, bounded/coalesced visual
work and reserved action results. No direct Host or effectful Lua callback.
Dependency/descriptor/Host-admission interfaces sent directly to RuntimeShip004
and UIShip005. Native App must reject obsolete-generation action results and
admit proposals through the actual Host with stable IDs and captured targets.

Checks (from this worktree; isolated prefix, never the read-only .deps symlink):
- `zig test src/script_test.zig src/native/script_lua.c -I src/native -I /home/ashman/Documents/spica/.artifacts/script006/deps/install/linux-x86_64/include/lua54 /home/ashman/Documents/spica/.artifacts/script006/deps/install/linux-x86_64/lib/libspica-lua54.a -lc -lm -lpthread -O Debug`: all 5 passed.
- Same command with `-O ReleaseSafe`: all 5 passed.
- `python3 -m unittest discover -s build -p bootstrap_test.py`: 9 passed.
- `cc -std=c11 -Wall -Wextra -Werror -fsyntax-only` with the same two includes on `src/native/script_lua.c`: passed.
- `zig fmt --check src/script.zig src/script_test.zig`: passed after formatting the test source.
- Actual `examples/minimal.lua` C consumer compiled with `-fsanitize=address,undefined`, same isolated Lua archive, `-lm -pthread`: root, custom renderer, captured send proposal, infinite-loop reload retention and shutdown passed; no sanitizer diagnostic. Archive itself is not sanitizer-instrumented.

Raw evidence/source/commands: repository-root `.artifacts/script006/consumer-debug.log`,
`consumer-release-bootstrap.log`, `example-consumer.c`, `example-consumer.log`.
Release log includes the initial formatting-only failure; final example log records
successful formatting. First Debug invocation exposed a Zig name-shadow compile
error, repaired by renaming the action parameter; one substantive repair, no
weakened test. Regression coverage includes active render/action OOM/instruction
errors, partial intent clearing, phase effect attempts, forbidden finalizers and
budget escape capabilities, descriptor/input bounds, stale/undeclared actions,
lossless u64/NUL bytes, finite queue identities and disposal refusal.

No native window/default-custom/durable Host proof, performance claim or overall
task006 acceptance. Those require shared integration outside this lane's exact
allowlist. Build lease coordinated with RuntimeShip004/UIShip005, released after
this cohort. Requested/resolved model gpt-6.1-sol; tier default; no descendants,
no fallback/advisors; detailed token usage unavailable. Worker ScriptShip006.

## Review follow-up

Main approved standalone checkpoint `0df2098ae8346c19098c50ff7855de0dbe970d9a`
for integration, not native acceptance. Removed the incidental license wording
assertion from LuaBootstrapTests; behavioral cache/artifact recovery and archive
checksum coverage remain. Focused `python3 -m unittest
bootstrap_test.LuaBootstrapTests` from `build/`: 2 passed in 0.029s; raw
`.artifacts/script006/bootstrap-review-fix.log`. No broad checks repeated.

## Queued proposal revocation review repair

Integration review found a concrete lifetime gap: an already-completed action
proposal could remain unconsumed across successful reload. Poll now linearizes
proposal handoff against the reload generation mutex; replacement revokes queued
old-generation proposals before closing the old VM. Their result identities are
delivered as failures with cleared intent, never dropped. No ABI shape change.
Proposals already handed off/native accepted durable work remain independent.

New focused regression explicitly completes an action, reloads successfully
without consuming that result, then proves old intent clearing and new visual
generation retention. Debug and ReleaseSafe each 1/1 passed with
`--test-filter \"successful reload revokes\"`; formatting passed. Exact commands and
raw evidence `.artifacts/script006/queued-generation-revocation.log`. No old
passing cohorts rerun. Native still rechecks installed generation before Host.
