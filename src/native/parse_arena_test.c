#include "parse_arena.h"
#include <string.h>

int spica_parse_arena_probe(void) {
    jmp_buf failure;
    SpicaParseArena arena;
    if (!spica_parse_arena_init(&arena, 256, &failure)) return 0;
    spica_parse_arena_activate(&arena);
    if (setjmp(failure)) {
        spica_parse_arena_release(&arena);
        return 0;
    }
    char *first = spica_parse_calloc(1, 8);
    memcpy(first, "keepme!", 8);
    char *grown = spica_parse_realloc(first, 40);
    int passed = memcmp(grown, "keepme!", 8) == 0;
    spica_parse_arena_release(&arena);
    return passed;
}
