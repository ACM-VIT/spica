# App-owned orchestration execution

## Durable runtime seam

`Host.Options.adapter` supplies a main-owned runtime instance; the Host worker exclusively dispatches, pumps and polls it, then shuts it down before `Host.destroy` returns. Main must retain the instance and its immutable metadata through destruction. Optional `selection` supplies the native/default and Lua consumers with the same explicit runtime/model/effort/account selection; workspace IDs are captured from the command target, never a UI-global provider label.

Admission verifies runtime/version/capability revision and account readiness before committing external intent. An asynchronous create acknowledgement without a session retains the create effect in flight; it does not unblock start. Only correlated session evidence confirms that effect. On process loss existing recovery marks in-flight work unknown rather than respawning it.

Provider observations retain original upstream event identity and digest for duplicate/conflict admission. Run identity can be resolved from a durable session for open responses. Provider message/block IDs map transactionally to app-owned assistant blocks in schema version 2; opening a version-1 conversation migrates the mapping table without rewriting conversation history. Multiple upstream text blocks remain distinct. Tool-result chunks use tool correlation and contiguous offsets and resolve to one durable tool-result block; empty terminal completion reuses it.

Nonterminal tool updates may refine a pending tool's digest. Refinement invalidates pending approvals; resolved authority cannot be rewritten. A complete permission request binds the final action digest to the same session/run/tool before becoming actionable. No expiry or execution permission is fabricated.

## Evidence boundaries

These contracts describe the durable adapter integration slice, not completed task delegation or a live MCP bridge. Runtime installation, tool registration and unauthenticated handshake do not establish authenticated parent/child execution. Public task-tree commands, bounded scheduling and native task presentation remain task012 work until their actual implementation and consumer scenarios are recorded.
