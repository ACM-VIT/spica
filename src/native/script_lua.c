#include "script_lua.h"
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if LUA_VERSION_NUM != 504 || LUA_VERSION_RELEASE_NUM != 50409
#error Selected Lua 5.4.9 headers are required
#endif

typedef enum { STAGING, RENDERING, ACTION, IDLE, CLOSING, DISPOSED } Phase;
typedef struct {
    lua_State *L;
    size_t used, cap;
    unsigned fuel, budget;
    Phase phase;
    const char *source;
    size_t source_len;
    const SpicaScriptSnapshot *snapshot;
    const SpicaScriptId *action;
    const SpicaScriptText *payload;
    SpicaScriptResult *out;
} VM;
typedef struct {
    uint64_t sequence, generation;
    SpicaScriptId id;
    SpicaScriptText payload;
    SpicaScriptActionContext context;
} ActionRequest;
struct SpicaScript {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    pthread_t thread;
    int stop, reload_pending, render_pending, visual_ready;
    size_t cap;
    unsigned budget;
    uint64_t reload_sequence, render_sequence, generation;
    char source[SPICA_SCRIPT_SOURCE];
    size_t source_len;
    SpicaScriptSnapshot reload_snapshot, render_snapshot;
    ActionRequest actions[SPICA_SCRIPT_ACTIONS];
    size_t action_head, action_count, outstanding;
    SpicaScriptResult results[SPICA_SCRIPT_ACTIONS], visual;
    size_t result_head, result_count;
    SpicaScriptWake wake;
    void *wake_context;
};
static void *vm_alloc(void *ud, void *ptr, size_t old, size_t n) {
    VM *v = ud;
    if (!ptr) old = 0;
    if (!n) { free(ptr); v->used -= old; return NULL; }
    if (n > old && n - old > v->cap - v->used) return NULL;
    void *next = realloc(ptr, n);
    if (next) v->used = v->used - old + n;
    return next;
}
static VM *vm(lua_State *L) { return *(VM **)lua_getextraspace(L); }
static void hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    VM *v = vm(L);
    if (v->fuel <= 1000) luaL_error(L, "instruction budget");
    v->fuel -= 1000;
}
static void close_vm(VM *v) {
    if (!v->L) return;
    v->phase = CLOSING; /* Revoke before Lua runs any finalization. */
    v->snapshot = NULL; v->action = NULL; v->payload = NULL; v->out = NULL;
    lua_close(v->L);
    v->L = NULL;
    v->phase = DISPOSED;
    if (v->used != 0) abort();
}
static int fail(lua_State *L, const char *message) { return luaL_error(L, "%s", message); }
static void plain_table(lua_State *L, int index) {
    if (!lua_istable(L, index) || lua_getmetatable(L, index)) fail(L, "plain table required");
}
static void field(lua_State *L, int index, const char *name) {
    index = lua_absindex(L, index);
    lua_pushstring(L, name);
    lua_rawget(L, index);
}
static size_t bytes(lua_State *L, int index, char *out, size_t cap, int optional) {
    if (optional && lua_isnil(L, index)) return 0;
    if (lua_type(L, index) != LUA_TSTRING) fail(L, "byte string required");
    size_t n;
    const char *s = lua_tolstring(L, index, &n);
    if (n > cap) fail(L, "descriptor byte bound");
    memcpy(out, s, n);
    return n;
}
static void id_field(lua_State *L, int index, const char *key, SpicaScriptId *out, int optional) {
    field(L, index, key);
    out->len = bytes(L, -1, out->bytes, sizeof(out->bytes), optional);
    lua_pop(L, 1);
}
static int enum_field(lua_State *L, int index, const char *key, const char *const *names, int count) {
    field(L, index, key);
    int answer = -1;
    for (int i = 0; i < count; ++i) {
        size_t len = 0;
        const char *value = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &len) : NULL;
        if (value && len == strlen(names[i]) && !memcmp(value, names[i], len)) answer = i;
    }
    lua_pop(L, 1);
    if (answer < 0) fail(L, "unknown descriptor kind");
    return answer;
}
static void node(lua_State *L, int index, SpicaScriptRoot *root, uint16_t parent, unsigned depth) {
    static const char *const kinds[] = {"column", "row", "text", "button", "composer", "transcript"};
    index = lua_absindex(L, index);
    plain_table(L, index);
    if (depth > 8 || root->count == SPICA_SCRIPT_NODES) fail(L, "tree bound");
    uint16_t current = (uint16_t)root->count++;
    SpicaScriptNode *n = &root->nodes[current];
    n->parent = parent;
    n->kind = enum_field(L, index, "kind", kinds, 6);
    id_field(L, index, "id", &n->id, 0);
    if (!n->id.len) fail(L, "empty semantic id");
    for (size_t i = 0; i < current; ++i)
        if (root->nodes[i].id.len == n->id.len && !memcmp(root->nodes[i].id.bytes, n->id.bytes, n->id.len)) fail(L, "duplicate semantic id");
    id_field(L, index, "action", &n->action, n->kind != 3);
    if (n->kind == 3 && !n->action.len) fail(L, "empty action id");
    field(L, index, "text");
    n->text_offset = (uint16_t)root->text_len;
    n->text_len = (uint16_t)bytes(L, -1, root->text + root->text_len, SPICA_SCRIPT_TEXT - root->text_len, 1);
    root->text_len += n->text_len;
    lua_pop(L, 1);
    field(L, index, "children");
    if (!lua_isnil(L, -1)) {
        plain_table(L, -1);
        if (n->kind > 1) fail(L, "leaf has children");
        size_t count = lua_rawlen(L, -1);
        if (count > SPICA_SCRIPT_NODES) fail(L, "child bound");
        for (size_t i = 1; i <= count; ++i) {
            lua_rawgeti(L, -1, (lua_Integer)i);
            node(L, -1, root, current, depth + 1);
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}
static void push_snapshot(lua_State *L, const SpicaScriptSnapshot *s) {
    char revision[21];
    snprintf(revision, sizeof(revision), "%llu", (unsigned long long)s->revision);
    lua_createtable(L, 0, 2);
    lua_pushstring(L, revision); lua_setfield(L, -2, "revision");
    lua_pushlstring(L, s->text.bytes, s->text.len); lua_setfield(L, -2, "text");
}
static int render_call(lua_State *L) {
    VM *v = vm(L);
    if (v->phase != STAGING && v->phase != RENDERING) return fail(L, "render phase required");
    lua_getfield(L, LUA_REGISTRYINDEX, "module");
    field(L, -1, "root");
    if (!lua_isfunction(L, -1)) return fail(L, "root function required");
    push_snapshot(L, v->snapshot);
    lua_call(L, 1, 1);
    node(L, -1, &v->out->root, UINT16_MAX, 1);
    lua_pop(L, 1);
    field(L, -1, "render_block");
    if (!lua_isfunction(L, -1)) return fail(L, "render_block function required");
    push_snapshot(L, v->snapshot);
    lua_call(L, 1, 1);
    plain_table(L, -1);
    static const char *const formats[] = {"plain", "markdown", "code"};
    v->out->render.format = enum_field(L, -1, "format", formats, 3);
    id_field(L, -1, "language", &v->out->render.language, 1);
    field(L, -1, "text");
    v->out->render.len = bytes(L, -1, v->out->render.bytes, SPICA_SCRIPT_RENDER, 0);
    return 0;
}
static int initialize(lua_State *L) {
    VM *v = vm(L);
    if (v->phase != STAGING) return fail(L, "staging phase required");
    luaL_requiref(L, "_G", luaopen_base, 1);
    lua_pop(L, 1);
    /* No metatable/finalizer creation: upstream disables instruction hooks in
     * __gc. Removing this capability is required for bounded shutdown, not a
     * claim that instruction hooks can interrupt finalizers or C calls. */
    const char *removed[] = {"load", "loadfile", "dofile", "collectgarbage", "print", "warn", "pcall", "xpcall", "setmetatable", "getmetatable", NULL};
    for (int i = 0; removed[i]; ++i) { lua_pushnil(L); lua_setglobal(L, removed[i]); }
    if (luaL_loadbufferx(L, v->source, v->source_len, "configuration", "t") != LUA_OK) return lua_error(L);
    lua_call(L, 0, 1);
    plain_table(L, -1);
    field(L, -1, "action");
    if (!lua_isfunction(L, -1)) return fail(L, "action function required");
    lua_pop(L, 1);
    lua_setfield(L, LUA_REGISTRYINDEX, "module");
    return render_call(L);
}
static int action_call(lua_State *L) {
    VM *v = vm(L);
    if (v->phase != ACTION) return fail(L, "action phase required");
    lua_getfield(L, LUA_REGISTRYINDEX, "module");
    field(L, -1, "action");
    lua_pushlstring(L, v->action->bytes, v->action->len);
    lua_pushlstring(L, v->payload->bytes, v->payload->len);
    lua_call(L, 2, 1);
    plain_table(L, -1);
    static const char *const kinds[] = {"send", "cancel", "approve", "deny"};
    v->out->intent.kind = enum_field(L, -1, "kind", kinds, 4) + 1;
    field(L, -1, "text");
    v->out->intent.text.len = bytes(L, -1, v->out->intent.text.bytes, SPICA_SCRIPT_TEXT, 1);
    return 0;
}
static int protected_call(VM *v, lua_CFunction function) {
    v->fuel = v->budget;
    lua_sethook(v->L, hook, LUA_MASKCOUNT, 1000);
    lua_pushcfunction(v->L, function);
    int status = lua_pcall(v->L, 0, 0, 0);
    if (status != LUA_OK) {
        const char *error = lua_type(v->L, -1) == LUA_TSTRING ? lua_tostring(v->L, -1) : "Lua failure";
        snprintf(v->out->error, sizeof(v->out->error), "%s", error);
    }
    lua_settop(v->L, 0);
    v->phase = IDLE;
    return status;
}
static int valid_snapshot(const SpicaScriptSnapshot *s) { return s && s->text.len <= SPICA_SCRIPT_TEXT; }
static int valid_id(const SpicaScriptId *s) { return s->len <= SPICA_SCRIPT_ID; }
static void *worker(void *ud) {
    SpicaScript *s = ud;
    VM active = {0};
    SpicaScriptRoot last_root = {0};
    SpicaScriptRender last_render = {0};
    /* All large copies are worker-local or fixed owned queue slots. */
    for (;;) {
        int kind;
        ActionRequest request = {0};
        SpicaScriptSnapshot snapshot = {0};
        char source[SPICA_SCRIPT_SOURCE];
        size_t source_len = 0;
        SpicaScriptResult result = {0};
        pthread_mutex_lock(&s->mutex);
        while (!s->stop && !s->action_count && !s->reload_pending && !s->render_pending)
            pthread_cond_wait(&s->condition, &s->mutex);
        if (s->stop && !s->action_count) { pthread_mutex_unlock(&s->mutex); break; }
        if (s->action_count) {
            kind = 3; request = s->actions[s->action_head];
            s->action_head = (s->action_head + 1) % SPICA_SCRIPT_ACTIONS; --s->action_count;
            result.sequence = request.sequence;
        } else if (s->reload_pending) {
            kind = 1; source_len = s->source_len; memcpy(source, s->source, source_len);
            snapshot = s->reload_snapshot; result.sequence = s->reload_sequence; s->reload_pending = 0;
        } else {
            kind = 2; snapshot = s->render_snapshot; result.sequence = s->render_sequence; s->render_pending = 0;
        }
        pthread_mutex_unlock(&s->mutex);
        result.kind = kind; result.generation = s->generation;
        if (kind == 1) {
            VM candidate = {.cap=s->cap, .budget=s->budget, .phase=STAGING, .source=source, .source_len=source_len, .snapshot=&snapshot, .out=&result};
            candidate.L = lua_newstate(vm_alloc, &candidate);
            if (candidate.L) {
                *(VM **)lua_getextraspace(candidate.L) = &candidate;
                result.status = protected_call(&candidate, initialize);
            } else { result.status = LUA_ERRMEM; snprintf(result.error, sizeof(result.error), "VM allocation failed"); }
            if (!result.status && s->generation != UINT64_MAX) {
                close_vm(&active); active = candidate;
                *(VM **)lua_getextraspace(active.L) = &active;
                lua_setallocf(active.L, vm_alloc, &active);
                ++s->generation; result.generation = s->generation; last_root = result.root; last_render = result.render;
            } else { if (!result.status) result.status = LUA_ERRRUN; close_vm(&candidate); }
        } else if (!active.L) { result.status = LUA_ERRRUN; snprintf(result.error, sizeof(result.error), "no active module"); }
        else if (kind == 2) {
            active.phase = RENDERING; active.snapshot = &snapshot; active.out = &result;
            result.status = protected_call(&active, render_call);
            if (!result.status) { last_root = result.root; last_render = result.render; }
        } else {
            int declared = 0;
            for (size_t i = 0; i < last_root.count; ++i) {
                SpicaScriptId *id = &last_root.nodes[i].action;
                if (id->len && id->len == request.id.len && !memcmp(id->bytes, request.id.bytes, id->len)) declared = 1;
            }
            if (request.generation != s->generation || !declared) {
                result.status = LUA_ERRRUN; snprintf(result.error, sizeof(result.error), "stale or undeclared action");
            } else {
                active.phase = ACTION; active.action = &request.id; active.payload = &request.payload; active.out = &result;
                result.status = protected_call(&active, action_call);
                result.intent.context = request.context;
            }
        }
        if (result.status) { result.root = last_root; result.render = last_render; memset(&result.intent, 0, sizeof(result.intent)); }
        pthread_mutex_lock(&s->mutex);
        if (kind == 3) {
            size_t slot = (s->result_head + s->result_count++) % SPICA_SCRIPT_ACTIONS;
            s->results[slot] = result;
        } else { s->visual = result; s->visual_ready = 1; }
        pthread_mutex_unlock(&s->mutex);
        if (s->wake) s->wake(s->wake_context);
    }
    close_vm(&active);
    return NULL;
}
SpicaScript *spica_script_create(size_t cap, unsigned budget, SpicaScriptWake wake, void *context) {
    if (!cap || cap > 64 * 1024 * 1024 || budget < 1000) return NULL;
    SpicaScript *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->cap = cap; s->budget = budget; s->wake = wake; s->wake_context = context;
    if (pthread_mutex_init(&s->mutex, NULL)) { free(s); return NULL; }
    if (pthread_cond_init(&s->condition, NULL)) { pthread_mutex_destroy(&s->mutex); free(s); return NULL; }
    if (pthread_create(&s->thread, NULL, worker, s)) { pthread_cond_destroy(&s->condition); pthread_mutex_destroy(&s->mutex); free(s); return NULL; }
    return s;
}
int spica_script_destroy(SpicaScript *s) {
    if (!s) return 0;
    pthread_mutex_lock(&s->mutex);
    if (s->outstanding) { pthread_mutex_unlock(&s->mutex); return 1; }
    s->stop = 1; pthread_cond_signal(&s->condition); pthread_mutex_unlock(&s->mutex);
    pthread_join(s->thread, NULL);
    pthread_cond_destroy(&s->condition); pthread_mutex_destroy(&s->mutex); free(s);
    return 0;
}
int spica_script_reload(SpicaScript *s, uint64_t sequence, const char *source, size_t len, const SpicaScriptSnapshot *snapshot) {
    if (!s || !source || len > SPICA_SCRIPT_SOURCE || !valid_snapshot(snapshot)) return 2;
    pthread_mutex_lock(&s->mutex);
    if (s->stop) { pthread_mutex_unlock(&s->mutex); return 2; }
    memcpy(s->source, source, len); s->source_len = len; s->reload_snapshot = *snapshot;
    s->reload_sequence = sequence; s->reload_pending = 1;
    pthread_cond_signal(&s->condition); pthread_mutex_unlock(&s->mutex); return 0;
}
int spica_script_render(SpicaScript *s, uint64_t sequence, const SpicaScriptSnapshot *snapshot) {
    if (!s || !valid_snapshot(snapshot)) return 2;
    pthread_mutex_lock(&s->mutex);
    if (s->stop) { pthread_mutex_unlock(&s->mutex); return 2; }
    s->render_snapshot = *snapshot; s->render_sequence = sequence; s->render_pending = 1;
    pthread_cond_signal(&s->condition); pthread_mutex_unlock(&s->mutex); return 0;
}
int spica_script_action(SpicaScript *s, uint64_t sequence, uint64_t generation, const SpicaScriptId *id, const SpicaScriptText *text, const SpicaScriptActionContext *context) {
    if (!s || !id || !text || !context || !valid_id(id) || !id->len || text->len > SPICA_SCRIPT_TEXT || !valid_id(&context->thread_id) || !valid_id(&context->run_id) || !valid_id(&context->approval_id) || !valid_id(&context->action_digest) || !valid_id(&context->selection)) return 2;
    pthread_mutex_lock(&s->mutex);
    if (s->stop) { pthread_mutex_unlock(&s->mutex); return 2; }
    if (s->outstanding == SPICA_SCRIPT_ACTIONS) { pthread_mutex_unlock(&s->mutex); return 1; }
    size_t slot = (s->action_head + s->action_count++) % SPICA_SCRIPT_ACTIONS;
    s->actions[slot] = (ActionRequest){.sequence=sequence, .generation=generation, .id=*id, .payload=*text, .context=*context};
    ++s->outstanding;
    pthread_cond_signal(&s->condition); pthread_mutex_unlock(&s->mutex); return 0;
}
int spica_script_poll(SpicaScript *s, SpicaScriptResult *out) {
    if (!s || !out) return 0;
    pthread_mutex_lock(&s->mutex);
    int found = 1;
    if (s->result_count) { *out = s->results[s->result_head]; s->result_head = (s->result_head + 1) % SPICA_SCRIPT_ACTIONS; --s->result_count; --s->outstanding; }
    else if (s->visual_ready) { *out = s->visual; s->visual_ready = 0; }
    else found = 0;
    pthread_mutex_unlock(&s->mutex); return found;
}
