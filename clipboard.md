# Clipboard tests

Copy testing covered macOS and Linux, including Wayland and Xorg.

- macOS: a contributor reported successful manual testing. The Cocoa probe has not been run.
- Linux: build, formatting, and copy regressions passed. Two responses, both themes, Unicode, code spacing, feedback, and composer selection were checked.
- Wayland: native clipboard delivery passed; the updated app also launched successfully.
- Xorg: native clipboard delivery passed on a headless Xorg server. Xwayland checks also passed on the updated branch.

Native Linux probes compared three payloads: 65, 53, and 207,000 bytes.
The latest suite passed 113 Zig tests and 12 Python tests, with three skipped.

## Run

```sh
python3 build/driver.py test
python3 tools/verify_clipboard.py --driver wayland --library .deps/install/linux-x86_64/lib/libSDL3.so
python3 tools/verify_clipboard.py --driver x11 --library .deps/install/linux-x86_64/lib/libSDL3.so
```

Wayland needs `wl-paste` and a click or keypress in the probe window.
On macOS, use `--driver cocoa` with `.deps/install/macos-aarch64/lib/libSDL3.dylib`
(or `macos-x86_64` on Intel).
