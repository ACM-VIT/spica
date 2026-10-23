# 003-fake receipt

Status: review, not acceptance. Private branch `task/003-fake`; base `d2e4e9250c9c9dd7cfde8ce2d68c8d5c9040f28b`; implementation checkpoint `d91fa8d` (typed seam, runtime, tests and API documentation). This receipt is a separate evidence checkpoint. No uncommitted implementation candidate remains. Frozen implementation diff SHA256: `c2bfc463a7b1cb1e8484bdd1a991227ef425887cdef7f7586471ec24785acf79`.

Changed entrypoints: `src/contract.zig`, `src/runtime/fake.zig`, `src/runtime/fake_test.zig`, import-only `src/test.zig`, and `docs/contracts/fake-adapter.md`. Implemented typed correlations/selections, exact create/attach, synchronous operation dispatch, deterministic scripts/barriers/clock, reusable bounded rings, borrowed payload lifetime, explicit unavailable/ambiguous outcomes and O/S/A/C/I/T/D/X counters.

Checks: `zig fmt` on the four owned Zig paths completed. `zig test src/test.zig --test-filter runtime.fake_test -O Debug` and `-O ReleaseSafe`: 7/7 passed each. `zig run .artifacts/fake003/consumer.zig -O Debug` and `-O ReleaseSafe`: both passed real Unicode stream → approval → response → simulated tool action → cancel → failure, counts O0/S1/A1/C1/I0/T0/D0/X1.

Evidence: private `.artifacts/fake003/manifest.json`, `candidate.diff`, both `test-*.log`, both `smoke-*.log`, throwaway consumer and hash-identical module copies. No build/test failures; one implementation attempt; review refinements landed before checkpoint. Full combined integration remains Infra002's check after Astra review. No domain persistence, live provider, native UI, usage or coordinator acceptance is claimed.

Actual session header: manifest path; `openai-codex/gpt-6.1-sol`, fallback=false, medium; assigned default tier (runtime tier unavailable), agent Fake003/session `01a1694b-8615-77cc-abf8-77e1d20c63d0`. Usage totals unavailable.
