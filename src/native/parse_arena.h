#ifndef SPICA_PARSE_ARENA_H
#define SPICA_PARSE_ARENA_H
#include <setjmp.h>
#include <stddef.h>

typedef struct {
    unsigned char *memory;
    size_t used;
    size_t limit;
    jmp_buf *failure;
} SpicaParseArena;

int spica_parse_arena_init(SpicaParseArena *arena, size_t limit, jmp_buf *failure);
void spica_parse_arena_release(SpicaParseArena *arena);
void spica_parse_arena_activate(SpicaParseArena *arena);
void spica_parse_arena_deactivate(void);
void *spica_parse_calloc(size_t count, size_t size);
void *spica_parse_realloc(void *ptr, size_t size);
void spica_parse_free(void *ptr);
#endif
