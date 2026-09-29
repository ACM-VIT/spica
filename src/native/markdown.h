#ifndef SPICA_MARKDOWN_H
#define SPICA_MARKDOWN_H
#include <cmark-gfm.h>
#include <stddef.h>

typedef struct SpicaMarkdown SpicaMarkdown;
typedef enum {
    SPICA_RICH_OK = 0,
    SPICA_RICH_BUDGET_EXCEEDED,
    SPICA_RICH_INVALID_SOURCE,
    SPICA_RICH_OUT_OF_MEMORY
} SpicaRichResult;

SpicaRichResult spica_markdown_parse(const char *source, size_t length,
                                     size_t arena_limit, SpicaMarkdown **out);
cmark_node *spica_markdown_root(SpicaMarkdown *job);
void spica_markdown_release(SpicaMarkdown *job);
#endif
