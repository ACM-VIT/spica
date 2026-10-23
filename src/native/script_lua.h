#ifndef SPICA_SCRIPT_LUA_H
#define SPICA_SCRIPT_LUA_H
#include <stddef.h>
#include <stdint.h>
#define SPICA_SCRIPT_SOURCE 65536
#define SPICA_SCRIPT_TEXT 16384
#define SPICA_SCRIPT_RENDER 32768
#define SPICA_SCRIPT_ID 128
#define SPICA_SCRIPT_ACTIONS 8
#define SPICA_SCRIPT_NODES 64
/* Explicit byte lengths preserve NULs; no native pointers in public values. */
typedef struct {
    size_t len;
    char bytes[SPICA_SCRIPT_ID];
} SpicaScriptId;
typedef struct {
    size_t len;
    char bytes[SPICA_SCRIPT_TEXT];
} SpicaScriptText;
/* kind: column,row,text,button,composer,transcript = 0..5. Flat preorder;
 * parent=UINT16_MAX at root, text offsets refer to root's bounded pool. */
typedef struct {
    int kind;
    uint16_t parent;
    SpicaScriptId id, action;
    uint16_t text_offset, text_len;
} SpicaScriptNode;
typedef struct {
    size_t count, text_len;
    SpicaScriptNode nodes[SPICA_SCRIPT_NODES];
    char text[SPICA_SCRIPT_TEXT];
} SpicaScriptRoot;
typedef struct {
    size_t len;
    char bytes[SPICA_SCRIPT_RENDER];
    int format;
    SpicaScriptId language;
} SpicaScriptRender;
typedef struct {
    uint64_t revision;
    SpicaScriptText text;
} SpicaScriptSnapshot;
/* Captured by native input, not script. Consumer MUST retain these exact
 * targets/preconditions; never substitute the current selection on delivery. */
typedef struct {
    SpicaScriptId thread_id, run_id, approval_id, action_digest, selection;
    uint64_t revision;
} SpicaScriptActionContext;
/* Proposed only: kind send,cancel,approve,deny=1..4, never a Host receipt. */
typedef struct {
    int kind;
    SpicaScriptText text;
    SpicaScriptActionContext context;
} SpicaScriptIntent;
typedef struct {
    uint64_t sequence, generation;
    int kind, status;
    SpicaScriptRoot root;
    SpicaScriptRender render;
    SpicaScriptIntent intent;
    char error[256];
} SpicaScriptResult;
typedef struct SpicaScript SpicaScript;
typedef void (*SpicaScriptWake)(void *);
/* All Lua evaluation runs on one owned pthread. Wake is payload-free and called
 * outside Lua frames; App drains results on wake, never on an idle timer.
 * 0=accepted, 1=full, 2=invalid/disposed. Accepted actions have reserved result
 * slots: never coalesced/dropped. Reload/render slots coalesce independently. */
SpicaScript *spica_script_create(size_t vm_bytes, unsigned instruction_budget, SpicaScriptWake,
                                 void *);
/* Destroy returns 1 without disposing while action results remain unconsumed. */
int spica_script_destroy(SpicaScript *);
int spica_script_reload(SpicaScript *, uint64_t sequence, const char *, size_t,
                        const SpicaScriptSnapshot *);
int spica_script_render(SpicaScript *, uint64_t sequence, const SpicaScriptSnapshot *);
int spica_script_action(SpicaScript *, uint64_t sequence, uint64_t generation,
                        const SpicaScriptId *, const SpicaScriptText *,
                        const SpicaScriptActionContext *);
int spica_script_poll(SpicaScript *, SpicaScriptResult *);
#endif
