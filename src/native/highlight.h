#ifndef SPICA_HIGHLIGHT_H
#define SPICA_HIGHLIGHT_H
#include <stddef.h>
#include <stdint.h>

typedef struct SpicaHighlight SpicaHighlight;
typedef enum {
    SPICA_HIGHLIGHT_OK,
    SPICA_HIGHLIGHT_UNSUPPORTED,
    SPICA_HIGHLIGHT_BUDGET_EXCEEDED,
    SPICA_HIGHLIGHT_INVALID_SOURCE,
    SPICA_HIGHLIGHT_GRAMMAR_ERROR,
    SPICA_HIGHLIGHT_OUT_OF_MEMORY
} SpicaHighlightResult;
/* Values express overlap priority: definitions/calls override generic
 * properties, property keys override strings, and comments override all. */
typedef enum {
    SPICA_TOKEN_NONE,
    SPICA_TOKEN_OPERATOR,
    SPICA_TOKEN_CONSTANT,
    SPICA_TOKEN_NUMBER,
    SPICA_TOKEN_KEYWORD,
    SPICA_TOKEN_TYPE,
    SPICA_TOKEN_STRING,
    SPICA_TOKEN_PROPERTY,
    SPICA_TOKEN_FUNCTION,
    SPICA_TOKEN_COMMENT
} SpicaTokenClass;
typedef struct {
    size_t byte_start, byte_end;
    uint32_t rgba; /* 0xRRGGBBAA */
    unsigned token_class;
} SpicaHighlightSpan;

/* Serialized content-worker-only: Tree-sitter and scanner allocators share
 * the C-only guarded arena with query scratch and output. Source is borrowed,
 * never modified; <=1 MiB. Limit is <=8 MiB including borrowed source bytes.
 * Only this job's grammar is loaded, then unloaded before return, including
 * exhaustion. Grammar directory contains libspica-tree-sitter-{zig,json,
 * javascript,python} with the platform .dll/.dylib/.so extension.
 * Unsupported languages return no job; render readable, uncolored monospace
 * with the original language label. */
SpicaHighlightResult spica_highlight_parse(const char *source, size_t length, const char *language,
                                           const char *grammar_directory, size_t arena_limit,
                                           SpicaHighlight **out);
const SpicaHighlightSpan *spica_highlight_spans(const SpicaHighlight *job);
size_t spica_highlight_span_count(const SpicaHighlight *job);
/* Includes the borrowed source bytes reserved against this job's limit. */
size_t spica_highlight_arena_used(const SpicaHighlight *job);
void spica_highlight_release(SpicaHighlight *job);
#endif
