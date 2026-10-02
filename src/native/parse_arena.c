#include "parse_arena.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static SpicaParseArena *active;

typedef union {
    max_align_t alignment;
    size_t size;
} Header;

int spica_parse_arena_init(SpicaParseArena *arena, size_t limit, jmp_buf *failure) {
    if (!limit || limit > 8u * 1024u * 1024u || !failure)
        return 0;
    *arena =
        (SpicaParseArena){.memory = malloc(limit), .used = 0, .limit = limit, .failure = failure};
    return arena->memory != NULL;
}

void spica_parse_arena_activate(SpicaParseArena *arena) { active = arena; }
void spica_parse_arena_deactivate(void) { active = NULL; }
void spica_parse_arena_release(SpicaParseArena *arena) {
    if (active == arena)
        active = NULL;
    free(arena->memory);
    *arena = (SpicaParseArena){0};
}

static void fail(void) { longjmp(*active->failure, 1); }

void *spica_parse_calloc(size_t count, size_t size) {
    if (!active || (count && size > SIZE_MAX / count))
        fail();
    size_t payload = count * size;
    size_t align = _Alignof(Header);
    if (payload > SIZE_MAX - sizeof(Header) - (align - 1))
        fail();
    size_t total = (payload + sizeof(Header) + align - 1) & ~(align - 1);
    if (total > active->limit - active->used)
        fail();
    Header *header = (Header *)(active->memory + active->used);
    active->used += total;
    header->size = payload;
    void *result = header + 1;
    memset(result, 0, payload);
    return result;
}

void *spica_parse_realloc(void *ptr, size_t size) {
    if (!ptr)
        return spica_parse_calloc(1, size);
    size_t old_size = ((Header *)ptr)[-1].size;
    void *next = spica_parse_calloc(1, size);
    memcpy(next, ptr, old_size < size ? old_size : size);
    return next;
}

void spica_parse_free(void *ptr) { (void)ptr; }
