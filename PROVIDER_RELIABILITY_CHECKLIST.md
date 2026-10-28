# Provider reliability review

This is the human review queue for the first usable provider connection. Please
comment on each item with `pass`, `fail`, or a short correction.

## Routing and connection

- [ ] Selecting **OpenCode** clears any previously selected Codex model before
  Send can become enabled.
- [ ] OpenCode uses its own account directory and never reads the Codex
  account directory.
- [ ] OpenCode model identities preserve the exact provider prefix advertised by
  ACP, including `opencode-free/glm-5.3-flash`.
- [ ] A saved Codex thread selection cannot route a prompt through Codex after
  the active connection is OpenCode.
- [ ] The selected runtime, provider prefix, model, effort, workspace, and
  account are visible before Send and remain unchanged through admission.

## First prompt acceptance

- [ ] With OpenCode selected and one known model, Send creates an OpenCode ACP
  session and `session/prompt`; no Codex process is started.
- [ ] A successful first prompt shows an accepted command, the same run/session
  correlation, streamed output, and a terminal completed state.
- [ ] Provider errors show the provider's diagnostic and retain the draft so it
  can be retried.
- [ ] Restarting the app does not silently switch runtime, account, provider
  prefix, or model.

## Human verification to perform

- [ ] Configure OpenCode with the real executable and a fresh isolated account
  directory.
- [ ] Confirm the catalog row reads `opencode-free / glm-5.3-flash` (or record
  the exact prefix shown by the provider).
- [ ] Send one harmless prompt such as `Reply with exactly: routing-ok`.
- [ ] Confirm the result is from GLM and that no ChatGPT/Codex usage-limit text
  appears.
- [ ] If it fails, copy the native diagnostic and record the selected runtime,
  provider prefix, model, account-directory basename, and workspace (never
  credentials or private history).

## Current automated evidence

- Debug and ReleaseSafe native integration: `354 passed, 2 skipped` per mode.
- OpenCode prefix parsing regression: `src/runtime/catalog.zig`.
- Runtime-switch stale-selection regression: `src/app.zig` and
  `src/ui/coding.zig`.
- Live-provider acceptance is still pending human review; offline fixtures do
  not prove a real GLM request.

## Interaction polish review

- [ ] Before Send, the composer shows the exact provider/model identity (for
  example `opencode-free / glm-5.3-flash`) without reopening the picker.
- [ ] Opening the model picker shows the same provider prefix and a readable
  readiness or sign-in reason for every row.
- [ ] When Send is disabled, the guidance names the next action instead of
  leaving the user with an inactive icon.
- [ ] Switching runtime or account clears the old selection immediately and
  keeps the composer focused on the new connection state.
- [ ] A failed provider request leaves the draft in place and exposes a
  copyable diagnostic that omits prompt contents and credentials.
