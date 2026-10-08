# Assistant response clipboard verification

The automated UI regressions use SDL's dummy driver. They cover response identity,
readable Markdown, painted controls, feedback, and composer behavior, but cannot
prove delivery through the native desktop clipboard. Run the native probe and
manual checks below on the operating system being verified.

The contributor reported successful manual copy-button testing on macOS. The
Cocoa probe below has not been run from the Linux development machine; record
its output separately from manual app results.
Windows is outside this test procedure: the application currently has no Windows
process backend.

## macOS setup

Use a real Mac logged into a graphical desktop session. Read [CONTRIBUTING.md](CONTRIBUTING.md)
and install its pinned tools, including Zig **0.16.0**, clang-format **22.1.8**,
Python **3.12+**, and the native build tools. Xcode or Command Line Tools must be
installed (`xcode-select --install` if needed). Node/Pi and provider credentials
are unnecessary for the resource fixture used here.

Start with a fresh checkout of the PR branch:

```sh
git clone --branch copy-buttion --single-branch https://github.com/monabji/spica.git spica-copy-test
cd spica-copy-test
git rev-parse HEAD
sw_vers
uname -m
zig version
clang-format --version
python3 --version
```

Keep the commit hash, macOS version, and architecture with the results. Run:

```sh
python3 build/driver.py deps
python3 tools/format.py --check
python3 build/driver.py
python3 build/driver.py test
./zig-out/bin/spica --help
```

The dependency build needs network access and can take time. Use the macOS driver,
which chooses an installed SDK accepted by both native and Zig compilers. If it
reports that no compatible SDK is available, update Xcode/Command Line Tools or
provide a compatible `SDKROOT`; do not mark a failed build as a clipboard pass.

## Native Cocoa clipboard probe

Save any clipboard content you need first. This probe temporarily replaces text
with synthetic samples and attempts to restore the previous text; it does not
preserve non-text clipboard formats or promise restoration after a crash.

On Apple silicon (`uname -m` reports `arm64`):

```sh
python3 tools/verify_clipboard.py --driver cocoa --library .deps/install/macos-aarch64/lib/libSDL3.dylib
```

On an Intel Mac (`uname -m` reports `x86_64`):

```sh
python3 tools/verify_clipboard.py --driver cocoa --library .deps/install/macos-x86_64/lib/libSDL3.dylib
```

Expected output for the pinned SDL build:

```text
SDL version 3004016; native driver cocoa
PASS cocoa case 1: 65 bytes
PASS cocoa case 2: 53 bytes
PASS cocoa case 3: 207000 bytes
```

All three cases and a zero exit status are required. The probe calls the same
`SDL_SetClipboardText` API used by the app on the main thread, overwrites and
releases its original buffer, then compares the result from a separate `pbpaste`
process. It tests mixed scripts, emoji/combining accents, newlines/tabs/code
spaces, repeated copies, and text above the composer's 64 KiB limit. The sender
pumps SDL events while another process reads deferred clipboard data.

This probes the native SDL boundary. The application regressions separately test
Markdown projection, button clicks, and feedback; the manual checks connect those
layers in the real app. Do not substitute a dummy driver or an in-process
clipboard read for the Cocoa result.

## Manual app checks

Launch the freshly built executable with isolated fixture data:

```sh
SPICA_COPY_DATA=$(mktemp -d "${TMPDIR:-/tmp}/spica-copy-test.XXXXXX")
./zig-out/bin/spica --fixture resource --data-dir "$SPICA_COPY_DATA" --renderer software
```

This starts no Pi process or model call. Open TextEdit and use **Format → Make
Plain Text**. For each copied response, paste into TextEdit with Cmd+V and also
inspect the clipboard from Terminal using `pbpaste`.

| Check | Required result |
| --- | --- |
| Copy two different assistant responses | Each paste contains only its selected answer; the second replaces the first. |
| Markdown, code, lists, tables | Readable text; code spaces and newlines survive; list/task meaning and table separators survive. No Markdown fences or link destination metadata. |
| Unicode | Arabic, accents, combining marks, and emoji survive without replacement characters or truncation. |
| UI decorations | No Copy/Copied labels, timestamps, reasoning headers/content, tool output, or neighboring messages in the payload. |
| Feedback | “Copied” lasts about 1.8 seconds and returns to the icon while the app is idle; the transcript does not move. |
| Composer | Select existing draft text, click Copy, then paste. Copy preserves the draft and selection; normal Cmd+C/Cmd+V still works. |
| Scrolling/resizing | Old and newly visible answers remain independently copyable; clipped/offscreen controls do not activate. |
| Themes and scale | Repeat in dark/light themes and at normal/large UI scale. If available, try Retina and a non-Retina external display. |
| Close after copy | After a successful external paste, close the app and paste again; record whether clipboard text persists. |

Repeat the UI checks with the native renderer as a separate run:

```sh
./zig-out/bin/spica --fixture resource --data-dir "$SPICA_COPY_DATA" --renderer native
```

If you already have Pi credentials configured, optionally test a real streaming
answer too. Copy must use a current parsed revision or show “Copy failed” while
that revision is unavailable; retry once the answer completes. The regressions
also exercise an actual SDL failure return and malformed UTF-8 rejection.

If a check fails, save the command output, commit hash, macOS/architecture, renderer,
display setup, and a description of the smallest failing response. Report the
probe's exit status and each failed manual row. A screenshot helps for rendering
or feedback; avoid including private response or clipboard content in reports.

## Linux native probe

Local Linux verification passed all three payloads on Wayland (`wl-paste` after
real window input), X11 through Xwayland, and standalone Xorg 1.21.1.24 using a
headless dummy video driver with SDL's native `x11` backend. Each X11 test used a
separate SDL reader process. The sizes were 65, 53, and 207,000 bytes. These
results verify native clipboard delivery; the headless Xorg run does not verify
manual button interaction on a physical Xorg desktop.

Use the same locked shared library with a real native driver:

```sh
python3 tools/verify_clipboard.py --driver x11 --library .deps/install/linux-x86_64/lib/libSDL3.so
python3 tools/verify_clipboard.py --driver wayland --library .deps/install/linux-x86_64/lib/libSDL3.so
```

X11 uses a fresh SDL reader process without an in-memory clipboard cache.
Wayland requires `wl-paste` and a real click/key in the blue verification window
to provide a compositor input serial. A timeout, reader failure, or mismatch is
a failed/unverified result, even if `SDL_SetClipboardText` returned success.

The API's UTF-8 and main-thread contract is documented in
[SDL_SetClipboardText](https://wiki.libsdl.org/SDL3/SDL_SetClipboardText).
