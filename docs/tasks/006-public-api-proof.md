# 006: Minimal public API proof

Status: review — selected protected Lua and actual native root/renderer/action proof integrated and exercised; Main acceptance remains pending.
Authorization: user continuation through roadmap002–017. Scope is a small replaceable root/renderer, public commands/queries, invalid-config retention and durable-work independence. No built-in alternate presets or two production scripting runtimes.
Base: accepted task003 `3c18aac45d732f217bc9af98d466f3c569c8dd61`; task004 Host gateway pinned in its packet, task005 native UI preparation/implementation concurrent.
Owner: Astra chooses runtime after evidence; Native003 performs bounded feasibility proof in ignored `.artifacts/api006/` only. All tracked files and other worktrees read-only; no Git mutation. Parent Git owner Infra002; DomainPrep004 owns domain gateway/types/build, NativeUI005 owns future native UI surface.

Proof: inspect already available Lua/QuickJS candidates and retained build/dependency patterns without installation/network. Use at most small throwaway consumer programs to compare representative root/renderer data exchange, command calls, error/invalid reload retention and bounded allocation/interrupt controls. Distinguish feasibility from real app bindings or accepted task006. Do not bind both runtimes in production. Pin exact available version/license and integration footprint; report unavailable candidates honestly. Scripting contract remains independent of runtime. No provider/auth/history access or automatic module downloads. Large performance jobs are unnecessary: first establish actual runnable controls and ownership; any timings are explicitly microbenchmarks, not app performance.

Deliver `.artifacts/api006/proof.md` and raw source/command/output evidence, implementation-ready narrow choice recommendation, missing prerequisites and real native integration acceptance plan. 20-minute hard/35-request soft, verified gpt-6.1-sol/no fallback, no grandchildren. No tracked commits for disposable proof. Actual smoke required if a candidate can be exercised with existing tools; no guessed benchmark claims. Production bindings require explicit selected-runtime/file allocation and cohesive verified checkpoints; default/custom root must use same public domain API without owning provider lifetime.

## Runtime decision and evidence

Select Lua5.4.9 only. `.artifacts/api006/proof.md`, actual `proof.c` and raw output establish a real embedded Lua consumer with bounded VM allocation, instruction hook, root/renderer descriptor exchange and last-good retention on rejected staged reload. Host was synthetic, so no actual durable/native acceptance is claimed. QuickJS was unavailable in scoped existing-tool probes; no speed superiority or exhaustive security isolation claim. Installed5.5 has a different lua_newstate ABI and must not be linked accidentally.

Official source: https://www.lua.org/ftp/lua-5.4.9.tar.gz, 373429bytes, SHA256 `2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6`. Matching official listing and actual downloaded archive/license evidence live in `.artifacts/api006/upstream-manifest.json`; exact integration map is `dependency-handoff.md`. Preserve archive MIT notice1994–2026; project-root distribution license remains a separate gate.

Production design must enforce distinct staging/render/action/closing/disposed phases; only current-generation explicit actions admit commands. Root/render remain pure even when active. Revoke capabilities before lua_close finalizers. All Lua allocation/errors/callbacks stay inside protected C boundary, never longjmp across Zig frames. Instruction hooks do not preempt C calls; exported C calls are bounded/nonblocking, not a sandbox guarantee. Public domain values remain runtime-neutral and u64 values marshal losslessly. Domain owner retains build.zig/src/test.zig; future scripting owner receives exact lock/bootstrap/shim/module paths separately. No dual runtime implementation.

## Production runtime allocation

Script006 (high Sol) owns one private runtime/dependency lane from published `81db41af608cb2b918378004ea5f4234557262c7`, worktree `.artifacts/worktrees/006-script`, branch `task/006-script`. Exact allowlist: `deps.lock.json`, `build/bootstrap.py`, `build/bootstrap_test.py`, `CONTRIBUTING.md`, new `docs/licenses/lua-5.4.9.txt`, `src/script.zig`, `src/native/script_lua.c`, `src/native/script_lua.h`, `src/script_test.zig`, `docs/contracts/scripting.md`, `docs/tasks/006-script-receipt.md`, `examples/minimal.lua`. No domain/native-root/build.zig/src/test.zig writes; DomainRuntime004 owns narrow link/test integration, NativeUI005 owns root/render/input integration. Runtime-neutral descriptor and callback details are pinned between those owners before they depend on fields; no competing Host.

Independent first slice is a real capped, protected VM/descriptor/action implementation plus locked source bootstrap, not a synthetic Host accepted as integration. Native bindings must use actual Host gateway; root/renderer consume bounded immutable visible snapshots and emit finite descriptors, never full histories or native pointers. Effectful callbacks only run for explicit current-generation actions. No allocation/error longjmp across Zig frames. Keep expensive scripting off the SDL thread; retained last-good output stays usable during evaluation, bounded queues coalesce superseded renders without losing action/command identity. Host/domain lifetime outlives scripts, shutdown/reload cannot cancel accepted work.

Use one selected runtime and one example replacing root and renderer, with meaningful reload/phase/budget/lifetime regressions and actual default/custom native proof before task006 acceptance. Commit cohesive working slices after checks, not end-only. Private dependency builds must not modify the shared read-only .deps symlink; compile the selected verified archive into an isolated prefix for standalone runtime checks, then coordinate shared dependency installation/linking only through integration owner. No system package installation/global configuration/network module fetch.

## Reviewed standalone implementation

Main reviewed dependency checkpoint `b3e8f976873fcd48faa4b3e9e98dd6ecbbe87dc1`
and runtime checkpoint `0df2098ae8346c19098c50ff7855de0dbe970d9a`: concrete ABI,
protected C evaluation, worker/admission/disposal paths, contract and actual
example consumer evidence. Standalone slice is approved for integration, not
native acceptance. Runtime entrypoints are `src/script.zig` and
`src/native/script_lua.c/h`; the immutable native handoff is documented in
`docs/contracts/scripting.md`, with the executable example `examples/minimal.lua`.

Evidence in `.artifacts/script006/`: five regressions passed in Debug and
ReleaseSafe, nine bootstrap tests passed, strict C warnings/format checks passed,
and the real example C consumer passed under ASan/UBSan (Lua archive itself not
instrumented). Raw logs and consumer source are enumerated in
`006-script-receipt.md`. No synthetic Host result establishes integration.

ScriptShip006 owns serialized shared Git integration for the union of task004–006
production paths and existing task records, without push authorization.
RuntimeShip004 retains private domain/build.zig/src/test.zig adaptation;
UIShip005 retains private native App/root/input integration. Main delegates
routine verified-candidate review/integration to ScriptShip006; material contract
decisions and final acceptance remain Main-owned. Native must admit current-
generation action proposals through the actual Host with captured immutable
targets and stable command IDs. Default/custom native operation, invalid reload
retention in the real App and durable restart remain the shared acceptance gate.


Integrated task006 checkpoints: `4f33f91`, `d4690d0`, `ef10ef2` (private sources
`b3e8f97`, `0df2098`, `3b4ed06`). Review follow-up removes only incidental license
wording assertion; focused LuaBootstrapTests 2/2 passed. Shared selected Lua prefix
prepared from verified local archive with source bootstrap, without network or
packages; `.artifacts/script006/shared-prefix-build.log`. No further broad checks
before actual app assembly.

Concrete integration review repair: `51722c6` integrated as `92473ee` revokes
completed but unconsumed old-generation action proposals atomically before VM
replacement; identities remain delivered as explicit failures with cleared
intents. New focused regression passed Debug/ReleaseSafe 1/1 each; evidence
`.artifacts/script006/queued-generation-revocation.log`. No ABI shape change or
new Host capability. Native still gates installed generation before admission.
Formatter-only native checkpoint `8944e7d` integrated as `1de4ab5`; strict C
syntax/warnings and formatting passed, preparing the final combined check.

## Successor integration allocation

`ShipLeadContinue` replaces the runtime-capped `ScriptShip006` as exclusive
shared Git/integration owner. Shared candidate `67f942a` already includes the
actual native default conversation App, runtime lifetime repairs and domain
review fixes. UIShip005 remains the only private App/root/input writer and owns
the upcoming actual Lua root, renderer and action bridge. The existing child
`ScriptShip006.HostScriptMeasure` retains reserved slot1 for a real standalone
Host+Lua consumer only; that evidence cannot replace the required frontend proof.
No fourth worker or duplicate native writer is authorized. Combined
`./tools/check`, actual assembled default/custom private-desktop interaction and
exclusive independent profiling follow the concrete native integration.

The stopped standalone consumer child released slot1 with only uncompiled,
unexercised evidence at `.artifacts/script006/host-consumer/`; no A01–A09
assertion is claimed passing. Main authorized successor slot reassignment.
`ShipLeadContinue.NativeMeasure` now owns evidence-only slot1, including optional
completion of that real consumer and later exclusive native measurements.
After UIShip005's runtime cap, Main explicitly transferred its existing private
native allowlist/slot2 to `ShipLeadContinue.NativeLuaBridge`; no additional
public API or runtime implementation is authorized.

## Actual native proof closure

`d5698fd` is integrated as `fe6a0ff`; `9227180` documents the native contract.
The real App consumes protected Lua root/renderer descriptors and explicit
captured-context action proposals through the same public Host as the default.
F5 stages reload; F9 switches composition without replacing Host. Native source
review fixes preserve reload errors until valid recovery and prevent editing an
omitted composer. Reserved action results are consumed before worker disposal.

Producer actual Debug custom input/reload/restart passed at
`.artifacts/ui005/lua-native-custom/manifest.json`. Final shared ReleaseSafe
custom proof also passed at
`.artifacts/ship-continue-final/native-custom-ReleaseSafe/manifest.json`; same
accepted run survives valid reload and root switching, malformed reload retains
last-good, later valid reload clears the error, and reopening retains tool output
and cancelled status. Integrator inspected all four relevant final screenshots.
The assembled `./tools/check` passed both safety modes; no repeat was needed.

Additional actual standalone Host/Lua consumer assertions A01–A09 passed Debug
at `.artifacts/ship-continue-measure/consumer-attempt2/manifest.json`.
The copied inherited consumer needed one expectation correction (seven root
nodes, not eight); no production runtime changed for that correction.
Standalone evidence supplements, rather than replaces, the actual frontend.
Independent measurement follows only under the explicit exclusive lease;
Main retains final milestone acceptance and subsequent adapter authorization.
