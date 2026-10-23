# Deterministic fake adapter (core v1)

`src/contract.zig` is the typed adapter vocabulary; `src/runtime/fake.zig` implements it without UI, storage, network, authentication, inference, native tool execution or a scheduler. App IDs are distinct typed opaque string wrappers, not upstream session/turn/request/tool strings. The fixture author supplies immutable IDs and mappings; an EffectId in a script is **not evidence of committed intent**. The future domain owns allocation, durable authorization, approval validity, deduplication and reconciliation.

## Consumer API

Instantiate `fake.Runtime(queue_capacity, call_capacity).init(config, script)`. Capacities are compile-time inline storage ceilings; configured limits may lower them. No allocator is accepted and no runtime operation allocates. `discover`, `accountStatus` and `resolveSelection` return synthetic version/capability/account/selection evidence. Requested and effective identities remain separate; null effective means unverified, not fallback. An unavailable account, unknown/unsupported required capability, or unverified create selection rejects explicitly. The seam permits an effective selection different from requested so consumers can test mismatch policy; the domain must validate it before dispatching a run.

`openSession(.create)` is a distinct expected effectful call from `openSession(.existing)` and `attach`. Existing-session operations match the complete app/upstream session identity and optional exact cursor. Both cursor-bearing paths require replay support and never create a replacement. `start`, `respondApproval`, `cancel`, `message`, `inspect`, and `attach` are wrappers over the typed `dispatch(Request)` method. Effectful run requests require EffectId and RunId; approval replies additionally require ToolCallId and ApprovalId. Exact expectation matching includes every ID, prompt, digest, decision and selection field. No adapter-side policy invents a reply or retries a request. `message` models actual immediate delivery only; durable queued messages belong to the future domain.

Receipts report acknowledgment, rejection or ambiguous delivery, not completed application commands. Inspect receipts can report an unknown outcome and replay continuity separately. `live_approval` is optional positive exact action/session/request evidence, including scope/workspace/expiry; null or merely `inspection=active` never establishes that an old approval callback is live. No permission is granted automatically. The domain owns expiry and cancellation races.

## Script and clock

A script is a borrowed immutable array of `Step`: `expect{request,receipt}`, `emit(Observation)`, named `barrier`, absolute `at` fake-clock deadline, or explicit `native_action`. Dispatch consumes only an exact next expectation. `pump()` consumes emissions/actions until the next expectation, barrier, future deadline, error or end. `release(name)` consumes only the exact current barrier; `advance(time)` is monotonic and never pumps implicitly. Dispatch never pumps or schedules hidden work. Scripts can repeat events, reorder offsets/sequences, deny approval, cancel, fail, disconnect and retain ambiguous outcomes. The fake deliberately preserves duplicates and out-of-order data; domain reducers must decide what may append once.

Typed observation bodies include selection, session mapping, message/block-correlated UTF-8 byte chunks, tool start/outcome, exact scoped approval evidence, completion, authoritative cancellation with explicit tool-stop evidence, failure, disconnect and ambiguity. Correlation retains app effect/session/run/tool/approval IDs and upstream turn/request/tool IDs. Sequence is not a block ID. Usage accounting and coordinator hooks are unsupported; init rejects attempts to advertise them as supported. There is no placeholder usage/bridge operation. Native-action steps increment simulated X only; duplicate tool observations do not.

## Bounds and payload ownership

All script/config arrays and every nested string must remain immutable/alive until the runtime and **all returned views** are discarded. Observation and receipt strings borrow those immutable sources; they survive poll, subsequent pumping and slot reuse. Dispatch input strings only need to survive the call: a matched call log retains the byte-equal canonical script request, not caller pointers. Unknown account-status results borrow the supplied reference. Structural matching compares byte contents, not slice addresses.

Observation and call rings reuse fixed inline slots. `poll()` and `takeCall()` drain them independently. A full call ring rejects before consuming an expectation/counting a call. A full observation ring or insufficient queue byte quota returns `QueueFull` **without consuming the blocked emission**: drain and pump to resume. No events are dropped or implicitly spooled. Queue bytes count each retained fixed typed header plus every variable byte field, even though immutable script storage is borrowed. `frameBytes` uses saturating arithmetic and accounts all nested string fields. Frame and chunk checks happen before enqueue/dispatch and never allocate or truncate UTF-8. Oversized or unsupported scripted observations return explicit errors at the unchanged step; callers must stop/report, not expect automatic recovery. The caller-owned script's backing memory is outside the queue quota; script length/bytes must themselves be bounded by its owner. There is no hidden transcript copy, decoded-page cache, durable spool or subscriber queue.

`pending_requests` must be exactly one: dispatch is synchronous. Configured frame/chunk/queue/call limits must be finite and within inline capacities. Counters count **matched actual dispatches**, including rejected/unknown upstream receipts: O=create, S=start, A=approval reply, C=cancel, I=inspect, T=exact attach (either entrypoint), D=immediate message delivery. Invalid requests/mismatch/backpressure are rejected before dispatch, do not consume script or increment counters. X counts only explicit simulated native actions. Discovery/readiness/selection/poll have no effect counts.

## Checks and smoke

Import `runtime/fake_test.zig` only from `src/test.zig`. Focused checks need no native dependencies:

```sh
zig test src/test.zig --test-filter runtime.fake_test -O Debug
zig test src/test.zig --test-filter runtime.fake_test -O ReleaseSafe
```

Tests exercise Unicode and retained payloads, duplicates/reordering, approval/cancel/unknown outcomes, all O/S/A/C/I/T/D/X counts, exact identity matching, no retry/create fallback, byte/frame/chunk overflow and ring reuse, capability gating, readiness and unverified selection, barrier/clock failures and zero-allocation operation. Test-owned temporary payloads use `std.testing.allocator`; the adapter has no allocating path requiring an allocation-failure repair branch.

The task evidence contains a throwaway separately compiled module consumer, raw Debug/ReleaseSafe logs and source hashes. It dispatches Unicode stream → approval → response → simulated tool action → cancel → failure, inspecting actual polled typed observations and counters. This is adapter-only smoke, not a durable conversation, native UI integration, core scenario-matrix completion or acceptance claim.
