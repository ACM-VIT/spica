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

SpicaRichResult spica_markdown_parse(const char *source, size_t length, size_t arena_limit,
                                     SpicaMarkdown **out);
cmark_node *spica_markdown_root(SpicaMarkdown *job);
/* Pinned cmark's public C-string getters may allocate. These borrowed ranges
 * read the exact locked node representation without allocating after the guard. */
typedef struct {
    const char *data;
    size_t length;
} SpicaMarkdownBytes;
SpicaMarkdownBytes spica_markdown_literal(cmark_node *node);
SpicaMarkdownBytes spica_markdown_fence_info(cmark_node *node);
SpicaMarkdownBytes spica_markdown_url(cmark_node *node);
void spica_markdown_release(SpicaMarkdown *job);
#endif
