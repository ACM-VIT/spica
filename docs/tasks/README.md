# Durable task ledger

One Markdown record per bounded task: NNN-short-name.md. Start a record before dispatch; keep its status current. ROADMAP.md is the dependency order, not a record of completed work.

Fields: status (ready/running/review/accepted/blocked), owner/model, base revision, owned paths, dependencies, scope, acceptance commands/scenarios, attempts with failures, result revision/diff, evidence, reviewer decision and remaining limitations. Include task/child session identifiers when available. On restart reconcile active OMP children and the working tree before redispatching; do not create duplicate workers.

Workers own only assigned paths. Astra directs integration and owns this ledger; a sole Sol integrator may receive the narrow local-Git exception in AGENTS.md after the other workers stop; workers return receipts for the coordinator to record. Mark accepted only after actual change/evidence review and affected integration checks. Keep large logs in ignored .artifacts/ rather than copying them into model context.

## Queue

- 000-bootstrap.md: branch/scaffold/OMP preparation.
- 001-contracts.md: first feature task; core IDs and versioned command/event/capability contracts, T3 reference pin and acceptance scenarios.
- 007-codex-adapter.md, 008-opencode-adapter.md and 012-app-orchestration.md are explicit future task packets; their prerequisites are unmet, so do not dispatch them yet.
- Subsequent records follow ROADMAP order with explicit dependencies; run independent infrastructure/UI groundwork beside contracts only when they do not invent competing interfaces.
