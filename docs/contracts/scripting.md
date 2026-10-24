# Selected scripting boundary

Lua 5.4.9 is the only production interpreter. `src/script.zig` wraps the owned
pthread implementation in `src/native/script_lua.c`; `script_lua.h` is the concrete
runtime-neutral native descriptor/admission ABI. Link only the locked isolated
`libspica-lua54.a` and its `include/lua54` headers, plus libc, math and pthreads.
The dependency bootstrap checkpoint is `b3e8f976873fcd48faa4b3e9e98dd6ecbbe87dc1`.

## Consumer and ownership

Create a Runtime with a per-VM allocation cap and instruction budget. Reload
copies at most 64 KiB of source and a bounded immutable visible snapshot; render
copies only a snapshot. Each has one independently coalescing pending slot and
shares one coalescing visual-result slot. Sequence numbers belong to the native
consumer: discard obsolete visual requests/results as appropriate. Successful
reload increments generation; failed staging or rendering returns the previous
complete root and renderer, with an error. Initial failure has generation zero
and no root: native keeps its default composition. A custom configuration must
export `root(snapshot)`, `render_block(snapshot)`, and `action(id,payload)`.
`examples/minimal.lua` replaces both root and renderer with native primitives.

Root is a flat preorder tree of at most 64 nodes and depth eight, with unique
nonempty semantic IDs, parent indexes and a 16 KiB text pool. Kinds are column,
row, text, button, composer, transcript (0–5), and native (6). Only column/row have children.
Buttons declare nonempty action IDs. Renderer text is at most 32 KiB with plain,
markdown or code format (0–2) and optional language. All strings have explicit
byte lengths, including embedded NULs; consumers must use lengths, not strlen.
Revision enters Lua as an unsigned decimal string, never a floating-point or
signed Lua integer. All native generations, sequences and preconditions stay u64.

## Shared presentation configuration

`src/ui/design.zig` defines the runtime-independent, allocation-free native
`Config { colors: Palette = .{}, layout: Metrics = .{} }`. Colors are opaque
`ui/color.zig.Color` RGB bytes; metrics are finite f32 values. `Config.validate()`
rejects invalid metrics. `Config.fromScript(*const script.Root)` validates native
presence masks and all supplied numeric values before copying optional fields
into a default Config. Invalid native descriptors return `InvalidDesign`.
This contract does not depend on a scripting language or provider runtime.

The optional **root-only** Lua field `design` accepts only `colors` and `layout`.
Both groups are optional plain tables. Their permitted fields are:

| Palette field | Default |
| --- | --- |
| background | `#0a0a0a` |
| sidebar | `#000000` |
| surface | `#111111` |
| raised | `#111111` |
| border | `#191919` |
| foreground | `#f5f5f5` |
| muted | `#818181` |
| accent | `#346bf1` |
| accent_text | `#ffffff` |
| selection | `#343a47` |

These are direct RGB values from T3 Code's MIT-licensed
`packages/shared/src/themePalettes.ts`, `T3_CODE_DARK_THEME_COLORS`, pinned at
`eb1510d2493cbf28600432d5193cc22a1af8f3d8`. The corresponding roles are canvas,
sidebar, surface, surfaceRaised, border, text, textMuted, messageAction,
messageActionForeground and terminalSelection. This is a bounded subset of its
roles, not its complete theme engine.

| Metrics field | Default | Inclusive range |
| --- | --- | --- |
| sidebar_width | 272 | 148–400 |
| content_width | 880 | 400–1600 |
| header_height | 56 | 48–96 |
| composer_height | 160 | 136–240 |
| gutter | 24 | 12–48 |
| gap | 12 | 4–32 |
| radius | 16 | 0–24 |

All color values must be actual Lua strings of exactly seven bytes, `#RRGGBB`;
hex digits are case insensitive. Short hex, alpha, names and numeric colors are
rejected. All metric/style numbers must be actual Lua numbers, finite and within
the specified range. Numeric strings and booleans are rejected without coercion.
Unknown fields and nonstring keys anywhere inside design, colors, layout or
style are rejected. Omitted fields use defaults; nil is omission in a Lua table.

`{kind='native', id='workspace', design={...}}` is a standalone root: exactly one
node with a required nonempty ID and no children. It retains the complete default
coding interface, native Send, provider controls, approval/cancel and native
content rendering. A native root rejects any nonempty node style; use `design`
for this root. `style={}` is allowed. `render_block` and `action` functions are
still required and their outputs retain the existing validation rules, but a
native root does not install the custom visible-text renderer or intercept
native controls. See runnable [t3-theme.lua](../../examples/t3-theme.lua):

```sh
zig-out/bin/spica --state-directory /tmp/spica-theme-demo \
  --lua-module examples/t3-theme.lua
```

Design applies to native or custom composition while the module is active.
F9 switches to the default Config when inactive. Failed reload or render preserves
the **entire** last-good root, renderer, styles and design, with an error; failed
reload does not advance generation. This includes failure after a candidate's
root/design has parsed successfully but its renderer fails. Domain execution and
previously accepted Host work keep their lifetimes.

## Per-node style and native ABI

The six custom primitive kinds accept optional `style={...}`:

| Field | Type | Inclusive range | Presence bit |
| --- | --- | --- | --- |
| width | number | 1–4096 | 1 |
| height | number | 1–4096 | 2 |
| gap | number | 0–128 | 4 |
| padding | number | 0–128 | 8 |
| font_size | number | 8–72 | 16 |
| radius | number | 0–64 | 32 |
| background | `#RRGGBB` | opaque RGB | 64 |
| foreground | `#RRGGBB` | opaque RGB | 128 |

Width/height are requested dimensions; native clipping still bounds the visible
viewport. Padding is uniform. Each supplied value overrides the corresponding
primitive default, while omitted values retain existing layout/paint behavior.
Container gap controls children; font size and foreground apply to native text
within the styled primitive. Background and radius apply to its painted surface.
Unknown properties fail rather than being silently ignored.

`SpicaScriptNode.style` is a `SpicaScriptStyle`: `uint32_t present`, followed by
six `float` members named width, height, gap, padding, font_size, radius, followed
by `uint8_t background[3], foreground[3]` in RGB order. `SPICA_STYLE_*` macros
define the table's bits. `script.Style` aliases this value and
`script.validateStyle()` rejects unknown bits, nonfinite and out-of-range supplied
values. Absent backing slots are ignored, including zero-filled numbers.

`SpicaScriptRoot.design` is `SpicaScriptDesign`: `uint32_t colors_present,
layout_present`, `uint8_t colors[10][3]`, and `float layout[7]`. Color/layout index
and mask bit order match the Palette/Metrics tables above. These structures own
all data by value; the fixed existing node/text/depth/queue bounds remain.
Bindings must validate descriptors before conversion or installation and install
the resulting Config atomically with the successful visual result.

An external transport for editing these runtime-independent values is **pending**.
No network endpoint, remote client, subscription protocol or credential access is
shipped by this API slice. The local Lua binding is the implemented adapter.

Native input captures the displayed generation, declared action ID, payload,
and exact ActionContext (thread/run/approval/digest/selection/revision). Accepted
actions reserve one of eight result slots until polled: no action is coalesced,
and QueueFull means no admission. Worker execution rejects obsolete generations
and undeclared IDs. Successful actions return a proposed send/cancel/approve/deny
intent (1–4), NOT a command receipt. Their results have kind 3; visual reload and
render results have kinds 1 and 2. Never install an action result as a visual tree.
Poll also rechecks generation under the same mutex as successful reload
revocation, before handing a proposal to native ownership. A completed but
unconsumed old-generation action becomes an explicit failure with its identity
preserved and intent cleared. Native handoff is the linearization boundary;
reload does not revoke proposals already handed off or accepted durable work.

**Actual Host admission remains native-owned.** On wake, drain results on the
App thread. Recheck current installed generation before admitting a successful
action intent, retain the originally captured targets/preconditions, assign a
stable command identity, and invoke the real public Host gateway. Do not resolve
current selection at result delivery, treat script queue acceptance as Host
acceptance, retry a command with a fresh identity, or mutate provider lifetime on
configuration reload. Root and renderer use visible snapshots only, never full
history/native pointers or hidden Host queries. No synthetic Host proves this
integration. Default/custom native UI and durable-work proof remain integration
acceptance gates owned by the native/domain lanes.

## Protected execution and lifetime

All Lua API operations, allocation, parsing and descriptor validation stay in C;
all potentially throwing evaluation occurs inside lua_pcall. Zig callbacks are
never on the Lua stack. The sole wake callback is payload-free, after publication,
outside Lua frames and the queue mutex. It must be nonblocking, must not destroy
or join the worker, and its context must outlive successful Runtime disposal.
Caller serializes destruction against every API user. Destroy refuses while any
accepted action result remains unconsumed; drain first. A successful destroy
stops pending visual work, joins the worker and then releases queues.

Phases are staging, rendering, explicit action, idle, closing and disposed.
There is no Host object or effectful Lua callback at any phase: only explicit
action result delivery can reach native admission. Close marks closing BEFORE
lua_close and disposed afterward. Only the base library is opened; loading,
files, printing, GC controls, protected calls and metatable access/creation are
removed. No package, coroutine, debug, OS, IO or other libraries are opened.
In particular user finalizers cannot be created: upstream Lua disables hooks in
__gc, so permitting them would invalidate bounded shutdown. This restriction is
intentional, not a claim that a hook can interrupt finalizers.

Instruction hooks bound Lua bytecode and cannot preempt C calls. Exposed base
operations act only on capped VM values and have no blocking external effects;
this is not an OS isolation or hard wall-clock sandbox guarantee. Staging keeps
the old VM until the candidate and its first root/renderer succeed: peak Lua
allocation is at most twice the selected per-VM cap, plus fixed native queues,
worker stack and interpreter C stack. The implementation rejects caps above
64 MiB and budgets below 1000. Allocation failure, invalid descriptors, script
errors and instruction exhaustion return bounded errors and preserve last-good
output; failed script evaluation does not roll back arbitrary Lua module-local
mutations in the current VM. Domain-owned accepted work outlives all scripts.

## Native proof consumer

The native App selects a module explicitly with `--lua-module PATH`; F5 stages
that file again, and F9 switches between the installed custom composition and
the default. Neither operation replaces Host. Initial module failure leaves the
default usable; reload failure preserves the installed generation, root and
renderer while reporting the error. A successful later reload clears that error.
While staging, snapshot refresh cannot supersede the staging result.

Root descriptors drive a bounded preorder layout in the existing Clay arena.
Composer and transcript nodes reuse retained native primitives; omitting the
composer also disables hidden composer text/keyboard admission. The minimal
example's plain renderer consumes copied UTF-8 from the bounded retained visible
transcript, not a new history query or borrowed projection storage. This proof
does not establish arbitrary rich custom-renderer or large-history behavior.

Native admission captures thread/run/approval/digest/workspace identities,
relevant revisions, draft revision, installed generation, root-switch epoch and
stable command ID before queuing an explicit action. Delivery rejects changed
contexts, obsolete generations and root-switch epochs before touching Host.
Default native approval/cancel controls remain available in the reused composer.
Shutdown consumes reserved action results while Host and wake storage still
exist, then joins Lua, presentation and Host before destroying SDL.

Actual native input/reload/restart evidence is
`.artifacts/ui005/lua-native-custom/manifest.json`, source checkpoint
`d5698fd11399723059fe3052c13362f8d081792e` (shared `fe6a0ff`).
This is frontend proof, unlike the earlier standalone consumers; milestone
acceptance still requires the assembled checks, measurements and Main review.
