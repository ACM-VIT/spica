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
row, text, button, composer, transcript (0–5). Only column/row have children.
Buttons declare nonempty action IDs. Renderer text is at most 32 KiB with plain,
markdown or code format (0–2) and optional language. All strings have explicit
byte lengths, including embedded NULs; consumers must use lengths, not strlen.
Revision enters Lua as an unsigned decimal string, never a floating-point or
signed Lua integer. All native generations, sequences and preconditions stay u64.

Native input captures the displayed generation, declared action ID, payload,
and exact ActionContext (thread/run/approval/digest/selection/revision). Accepted
actions reserve one of eight result slots until polled: no action is coalesced,
and QueueFull means no admission. Worker execution rejects obsolete generations
and undeclared IDs. Successful actions return a proposed send/cancel/approve/deny
intent (1–4), NOT a command receipt. Their results have kind 3; visual reload and
render results have kinds 1 and 2. Never install an action result as a visual tree.

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
