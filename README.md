# Spica

Spica is an experimental native coding workspace for Linux, built with Zig
0.16, SDL3 and Clay. This branch is the native rewrite.

With the development dependencies already available, build and open it:

```sh
python3 build/driver.py -Doptimize=ReleaseSafe
./zig-out/bin/spica
```

No provider, account or workspace flags are required. In **Connection**, choose
Codex or OpenCode, select your project with **Choose folder…** (Ctrl+O), then
**Connect & discover**. The current folder is suggested initially. Choose a
model beside the composer before sending. Connections, model choices and chats
are saved in Spica's own application state and restored on the next launch.

Codex uses your normal `~/.codex` account by default. **Use my ChatGPT login**
selects that account explicitly if an older saved connection points elsewhere.
You can also sign in with a browser or device code inside Connection. An
API-key account is identified separately from a ChatGPT login. OpenCode
discovers its available free models; an existing paid-provider account can be
selected through **Advanced → Account folder**. Spica does not copy credentials
or import other applications' chats.

Enter sends, Shift+Enter inserts a newline, and F6 stops the current run.
**Advanced** exposes executable and account overrides when needed; command-line
flags remain available for development and automation (`spica --help`).

Run `./tools/check` for Debug and ReleaseSafe integration checks. Private-desktop
workflow evidence belongs under ignored `.artifacts/`, with fixture and live
provider results identified separately.
