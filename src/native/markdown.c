#include "markdown.h"
#include "parse_arena.h"
#include <cmark-gfm-core-extensions.h>
#include <cmark-gfm-extension_api.h>
#include <stdint.h>
#include <stdlib.h>

struct SpicaMarkdown {
    SpicaParseArena arena;
    cmark_node *root;
};

SpicaRichResult spica_markdown_parse(const char *source, size_t length,
                                     size_t arena_limit, SpicaMarkdown **out) {
    if (out) *out = NULL;
    if (!out || (!source && length) || length > 1024u * 1024u ||
        !arena_limit || arena_limit > 8u * 1024u * 1024u)
        return SPICA_RICH_INVALID_SOURCE;
    // Registry allocations have persistent lifetime and are never inside the
    // job's setjmp guard. The content worker serializes this initialization.
    cmark_gfm_core_extensions_ensure_registered();
    SpicaMarkdown *job = malloc(sizeof(*job));
    if (!job) return SPICA_RICH_OUT_OF_MEMORY;
    jmp_buf failure;
    if (!spica_parse_arena_init(&job->arena, arena_limit, &failure)) {
        free(job);
        return SPICA_RICH_OUT_OF_MEMORY;
    }
    job->root = NULL;
    spica_parse_arena_activate(&job->arena);
    if (setjmp(failure)) {
        spica_parse_arena_release(&job->arena);
        free(job);
        return SPICA_RICH_BUDGET_EXCEEDED;
    }
    cmark_mem mem = {spica_parse_calloc, spica_parse_realloc, spica_parse_free};
    cmark_parser *parser = cmark_parser_new_with_mem(CMARK_OPT_DEFAULT, &mem);
    if (!parser) {
        spica_parse_arena_release(&job->arena);
        free(job);
        return SPICA_RICH_OUT_OF_MEMORY;
    }
    const char *names[] = {"table", "tasklist", "strikethrough", "autolink"};
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); ++i) {
        cmark_syntax_extension *extension = cmark_find_syntax_extension(names[i]);
        if (extension) cmark_parser_attach_syntax_extension(parser, extension);
    }
    for (size_t offset = 0; offset < length;) {
        size_t size = length - offset;
        if (size > 65536) size = 65536;
        cmark_parser_feed(parser, source + offset, size);
        offset += size;
    }
    job->root = cmark_parser_finish(parser);
    cmark_parser_free(parser);
    spica_parse_arena_deactivate();
    if (!job->root) {
        spica_markdown_release(job);
        return SPICA_RICH_INVALID_SOURCE;
    }
    *out = job;
    return SPICA_RICH_OK;
}

cmark_node *spica_markdown_root(SpicaMarkdown *job) {
    return job ? job->root : NULL;
}

void spica_markdown_release(SpicaMarkdown *job) {
    if (!job) return;
    // All parser/tree allocations live in the same arena. The caller only
    // uses nonallocating cmark_node getters while this handle remains alive.
    spica_parse_arena_release(&job->arena);
    free(job);
}
