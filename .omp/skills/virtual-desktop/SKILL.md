---
name: virtual-desktop
description: Test Spica on a private Linux desktop with installed vd, inspect actual screenshots and input without disturbing the user display.
---

Use installed `~/.local/bin/vd`; read `vd help` / `vd help COMMAND` for current syntax. Do not install or use the user's active desktop.

```bash
vd preflight
s=$(vd start --width 1280 --height 800)
trap 'vd clean "$s"' EXIT
vd run "$s" --bg -- /absolute/path/to/app
vd windows "$s"
vd shot "$s" /absolute/path/to/.artifacts/before.png
vd key "$s" WINDOW_ID Escape
```

Wait for a window; use observed IDs/coordinates. Save screenshots/logs before cleanup and inspect screenshots. Prefer `./tools/eval-starter` for the existing starter scenario and Escape check; inspect its manifest and outputs. Use temporary app state; never migrate private histories. Wayland only; isolation is not a filesystem sandbox. GPU is default; software `--renderer pixman` must be labeled. Recording is not frame timing or physical latency evidence. On failure inspect session logs; never fall back to the user display. Clean only your own session. Full installed guidance: `/home/ashman/.codex/skills/virtual-desktop/SKILL.md`.
