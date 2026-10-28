# Ordinary launch and provider usability repair

User report: native Spica is unusable because Codex authentication fails,
OpenCode sends appear to hit Codex usage limits, and ordinary launch seems to
require provider/workspace flags.

Acceptance:

- The normal development binary opens with no application flags and presents
  in-app provider/project setup; saved connection failures remain recoverable.
- Users can choose a project folder in the app. Cancelling or failing the OS
  chooser preserves the current path and offers the editable field as fallback.
- Ordinary Codex setup selects the normal ChatGPT account home rather than an
  inherited coding-harness account. Explicit saved/edited accounts stay exact.
- The installed Codex 0.164.0 handshake works through tested compatibility with
  0.163.0. Unknown protocol versions remain explicit errors.
- Selecting OpenCode prevents a stale Codex selection/action from sending.
  Verify exact model identity, three turns and restart/resume, distinguishing
  installed-provider evidence from synthetic fixtures.
- Run relevant native/fixture regressions, `./tools/check`, and operate the
  rendered app on a private desktop. Preserve input-driven screenshots and
  redacted receipts in `.artifacts/usability-repair/`.

Ownership: provider worker owns startup and Codex runtime/catalog/factory;
OpenCode worker owns its protocol fixture and tests; integration owns App,
presentation, platform folder chooser, automation observations and these docs.
Git ownership transfers explicitly between checkpoints. No user histories or
credentials are migrated. Auth metadata probes do not establish inference or
entitlement; only the advertised free OpenCode endpoint is used for live turns.
