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
#define SPICA_SCRIPT_COLORS 15
#define SPICA_SCRIPT_METRICS 7
/* Bit order matches the named fields below. Omitted fields retain defaults. */
#define SPICA_STYLE_WIDTH (1u << 0)
#define SPICA_STYLE_HEIGHT (1u << 1)
#define SPICA_STYLE_GAP (1u << 2)
#define SPICA_STYLE_PADDING (1u << 3)
#define SPICA_STYLE_FONT_SIZE (1u << 4)
#define SPICA_STYLE_RADIUS (1u << 5)
#define SPICA_STYLE_BACKGROUND (1u << 6)
#define SPICA_STYLE_FOREGROUND (1u << 7)
typedef struct {
    uint32_t present;
    float width, height, gap, padding, font_size, radius;
    uint8_t background[3], foreground[3];
} SpicaScriptStyle;
/* colors: background,sidebar,surface,raised,border,foreground,muted,accent,
 * accent_text,selection,sidebar_active,sidebar_hover,sidebar_muted,
 * sidebar_border,danger. layout: sidebar_width,content_width,header_height,
 * composer_height,gutter,gap,radius. Native consumers validate before use. */
typedef struct {
    uint32_t colors_present, layout_present;
    uint8_t colors[SPICA_SCRIPT_COLORS][3];
    float layout[SPICA_SCRIPT_METRICS];
} SpicaScriptDesign;
/* Explicit byte lengths preserve NULs; no native pointers in public values. */
typedef struct {
    size_t len;
    char bytes[SPICA_SCRIPT_ID];
} SpicaScriptId;
typedef struct {
    size_t len;
    char bytes[SPICA_SCRIPT_TEXT];
} SpicaScriptText;
/* kind: column,row,text,button,composer,transcript,native = 0..6. Native is
 * standalone root only, retaining full native controls. Flat preorder;
 * parent=UINT16_MAX at root, text offsets refer to root's bounded pool. */
typedef struct {
    int kind;
    uint16_t parent;
    SpicaScriptId id, action;
    uint16_t text_offset, text_len;
    SpicaScriptStyle style;
} SpicaScriptNode;
typedef struct {
    size_t count, text_len;
    SpicaScriptNode nodes[SPICA_SCRIPT_NODES];
    char text[SPICA_SCRIPT_TEXT];
    SpicaScriptDesign design;
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
