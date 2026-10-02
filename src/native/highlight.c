#include "highlight.h"
#include "parse_arena.h"
#include <tree_sitter/api.h>
#include <SDL3/SDL_loadso.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_CAPTURES 16384u
#define MAX_EVENTS (2u * MAX_CAPTURES)
#define MAX_SOURCE (1024u * 1024u)
#define MAX_ARENA (8u * 1024u * 1024u)
#if defined(_WIN32)
#define GRAMMAR_SUFFIX ".dll"
#elif defined(__APPLE__)
#define GRAMMAR_SUFFIX ".dylib"
#else
#define GRAMMAR_SUFFIX ".so"
#endif

typedef struct {
    uint32_t byte;
    uint16_t token;
    int16_t delta;
} Event;
struct SpicaHighlight {
    SpicaParseArena arena;
    SDL_SharedObject *grammar;
    SpicaHighlightSpan *spans;
    size_t count;
    size_t source_length;
};

/* Curated structural queries for the exact locked grammars. Naming-convention
 * regexes, Lua predicates, local-scope predicates and editor directives from
 * upstream queries are deliberately absent, never silently accepted. */
static const char zig_query[] =
    "(comment) @comment\n"
    "[(string) (multiline_string) (character)] @string\n"
    "[(integer) (float)] @number\n"
    "[(boolean) \"null\" \"undefined\" \"unreachable\"] @constant\n"
    "(builtin_type) @type\n"
    "(parameter type: (identifier) @type)\n"
    "(function_declaration name: (identifier) @function)\n"
    "(call_expression function: (identifier) @function)\n"
    "(call_expression function: (field_expression member: (identifier) @function))\n"
    "(builtin_identifier) @function\n"
    "(container_field name: (identifier) @property)\n"
    "(field_initializer . (identifier) @property)\n"
    "((identifier) @constant (#eq? @constant \"_\"))\n"
    "[\"asm\" \"defer\" \"errdefer\" \"test\" \"error\" \"const\" \"var\" "
    "\"struct\" \"union\" \"enum\" \"opaque\" \"fn\" \"return\" \"if\" \"else\" "
    "\"switch\" \"for\" \"while\" \"break\" \"continue\" \"try\" \"catch\" "
    "\"pub\" \"inline\" \"noinline\" \"extern\" \"comptime\" \"packed\" "
    "\"export\" \"threadlocal\" \"and\" \"or\" \"orelse\"] @keyword\n"
    "[\"=\" \"+\" \"-\" \"*\" \"/\" \"==\" \"!=\" \"<\" \">\" \"!\"] @operator\n";
static const char python_query[] =
    "(comment) @comment\n(string) @string\n[(integer) (float)] @number\n"
    "[(none) (true) (false)] @constant\n"
    "(function_definition name: (identifier) @function)\n"
    "(class_definition name: (identifier) @type)\n"
    "(call function: (identifier) @function)\n"
    "(call function: (attribute attribute: (identifier) @function))\n"
    "(attribute attribute: (identifier) @property)\n"
    "(type (identifier) @type)\n"
    "((identifier) @constant (#any-of? @constant \"__name__\" \"__debug__\"))\n"
    "[\"as\" \"assert\" \"async\" \"await\" \"break\" \"class\" \"continue\" "
    "\"def\" \"del\" \"elif\" \"else\" \"except\" \"finally\" \"for\" \"from\" "
    "\"global\" \"if\" \"import\" \"lambda\" \"nonlocal\" \"pass\" \"raise\" "
    "\"return\" \"try\" \"while\" \"with\" \"yield\" \"match\" \"case\"] @keyword\n"
    "[\"+\" \"-\" \"*\" \"/\" \"=\" \"==\" \"!=\" \"and\" \"or\" \"not\" \"in\" \"is\"] "
    "@operator\n";
static const char javascript_query[] =
    "(comment) @comment\n[(string) (template_string) (regex)] @string\n"
    "(number) @number\n[(true) (false) (null) (undefined)] @constant\n"
    "(property_identifier) @property\n"
    "(function_declaration name: (identifier) @function)\n"
    "(function_expression name: (identifier) @function)\n"
    "(method_definition name: (property_identifier) @function)\n"
    "(call_expression function: (identifier) @function)\n"
    "(call_expression function: (member_expression property: (property_identifier) @function))\n"
    "(class_declaration name: (identifier) @type)\n"
    "[\"async\" \"await\" \"break\" \"case\" \"catch\" \"class\" \"const\" "
    "\"continue\" \"debugger\" \"default\" \"delete\" \"do\" \"else\" \"export\" "
    "\"extends\" \"finally\" \"for\" \"from\" \"function\" \"if\" \"import\" "
    "\"in\" \"instanceof\" \"let\" \"new\" \"return\" \"static\" \"switch\" "
    "\"throw\" \"try\" \"typeof\" \"var\" \"void\" \"while\" \"with\" \"yield\"] @keyword\n"
    "[\"=\" \"+\" \"-\" \"*\" \"/\" \"==\" \"===\" \"!=\" \"!==\" \"=>\" \"&&\" \"||\"] "
    "@operator\n";
static const char json_query[] =
    "(pair key: (string) @property)\n(string) @string\n(number) @number\n"
    "[(true) (false) (null)] @constant\n(comment) @comment\n";

typedef struct {
    const char *name, *symbol, *query;
} Grammar;
static const Grammar grammars[] = {
    {"zig", "tree_sitter_zig", zig_query},
    {"json", "tree_sitter_json", json_query},
    {"javascript", "tree_sitter_javascript", javascript_query},
    {"python", "tree_sitter_python", python_query},
};
static bool name_equal(const char *left, const char *right) {
    if (!left)
        return false;
    while (*left && *right) {
        unsigned char c = (unsigned char)*left++;
        if (c >= 'A' && c <= 'Z')
            c += 'a' - 'A';
        if (c != (unsigned char)*right++)
            return false;
    }
    return !*left && !*right;
}
static const Grammar *grammar_for(const char *language) {
    if (name_equal(language, "js"))
        return &grammars[2];
    if (name_equal(language, "py"))
        return &grammars[3];
    for (size_t i = 0; i < sizeof(grammars) / sizeof(*grammars); ++i)
        if (name_equal(language, grammars[i].name))
            return &grammars[i];
    return NULL;
}
static void *arena_malloc(size_t size) { return spica_parse_calloc(1, size); }
static bool string_equal(const TSQuery *query, uint32_t id, const char *text) {
    uint32_t length;
    const char *value = ts_query_string_value_for_id(query, id, &length);
    return value && length == strlen(text) && !memcmp(value, text, length);
}
/* Fail closed even if a future query accidentally introduces another predicate. */
static bool predicates_match(const TSQuery *query, const TSQueryMatch *match, const char *source,
                             size_t length) {
    uint32_t count;
    const TSQueryPredicateStep *steps =
        ts_query_predicates_for_pattern(query, match->pattern_index, &count);
    for (uint32_t i = 0; i < count;) {
        uint32_t end = i;
        while (end < count && steps[end].type != TSQueryPredicateStepTypeDone)
            ++end;
        if (end == count || end - i < 3 || steps[i].type != TSQueryPredicateStepTypeString ||
            steps[i + 1].type != TSQueryPredicateStepTypeCapture)
            return false;
        bool eq = string_equal(query, steps[i].value_id, "eq?");
        bool any = string_equal(query, steps[i].value_id, "any-of?");
        if ((!eq && !any) || (eq && end - i != 3))
            return false;
        for (uint32_t k = i + 2; k < end; ++k)
            if (steps[k].type != TSQueryPredicateStepTypeString)
                return false;
        bool found_capture = false;
        for (uint16_t j = 0; j < match->capture_count; ++j) {
            if (match->captures[j].index != steps[i + 1].value_id)
                continue;
            found_capture = true;
            TSNode node = match->captures[j].node;
            uint32_t start = ts_node_start_byte(node), stop = ts_node_end_byte(node);
            if (start > stop || stop > length)
                return false;
            bool matched = false;
            for (uint32_t k = i + 2; k < end; ++k) {
                uint32_t size;
                const char *text = ts_query_string_value_for_id(query, steps[k].value_id, &size);
                if (text && stop - start == size && !memcmp(source + start, text, size))
                    matched = true;
            }
            if (!matched)
                return false;
        }
        if (!found_capture)
            return false;
        i = end + 1;
    }
    return true;
}
static unsigned token_class(const TSQuery *query, uint32_t capture) {
    static const char *names[] = {"",     "operator", "constant", "number",   "keyword",
                                  "type", "string",   "property", "function", "comment"};
    uint32_t length;
    const char *name = ts_query_capture_name_for_id(query, capture, &length);
    for (unsigned i = 1; i < sizeof(names) / sizeof(*names); ++i)
        if (length == strlen(names[i]) && !memcmp(name, names[i], length))
            return i;
    return SPICA_TOKEN_NONE;
}
static uint32_t token_color(unsigned token) {
    static const uint32_t colors[] = {0,          0xc0caf5ff, 0xff9e64ff, 0xff9e64ff, 0xbb9af7ff,
                                      0x2ac3deff, 0x9ece6aff, 0x73dacaff, 0x7aa2f7ff, 0x7f8c9aff};
    return colors[token];
}
/* In-place heapsort avoids libc sort implementations' untracked scratch. */
static void sift(Event *events, size_t root, size_t count) {
    for (;;) {
        size_t child = root * 2 + 1;
        if (child >= count)
            return;
        if (child + 1 < count && events[child].byte < events[child + 1].byte)
            ++child;
        if (events[root].byte >= events[child].byte)
            return;
        Event saved = events[root];
        events[root] = events[child];
        events[child] = saved;
        root = child;
    }
}
static void sort_events(Event *events, size_t count) {
    for (size_t i = count / 2; i; --i)
        sift(events, i - 1, count);
    for (size_t i = count; i > 1; --i) {
        Event saved = events[0];
        events[0] = events[i - 1];
        events[i - 1] = saved;
        sift(events, 0, i - 1);
    }
}
static void finish_spans(SpicaHighlight *job, Event *events, size_t count) {
    sort_events(events, count);
    job->spans = spica_parse_calloc(count ? count : 1, sizeof(*job->spans));
    int active[SPICA_TOKEN_COMMENT + 1] = {0};
    uint32_t previous = 0;
    unsigned selected = 0;
    for (size_t i = 0; i < count;) {
        uint32_t position = events[i].byte;
        if (position > previous && selected) {
            if (job->count && job->spans[job->count - 1].byte_end == previous &&
                job->spans[job->count - 1].token_class == selected)
                job->spans[job->count - 1].byte_end = position;
            else
                job->spans[job->count++] =
                    (SpicaHighlightSpan){previous, position, token_color(selected), selected};
        }
        do {
            active[events[i].token] += events[i].delta;
            ++i;
        } while (i < count && events[i].byte == position);
        selected = SPICA_TOKEN_COMMENT;
        while (selected && !active[selected])
            --selected;
        previous = position;
    }
}
static void unload_grammar(SpicaHighlight *job) {
    if (job->grammar)
        SDL_UnloadObject(job->grammar);
    job->grammar = NULL;
}

SpicaHighlightResult spica_highlight_parse(const char *source, size_t length, const char *language,
                                           const char *grammar_directory, size_t arena_limit,
                                           SpicaHighlight **out) {
    if (out)
        *out = NULL;
    if (!out || (!source && length) || length > MAX_SOURCE || !grammar_directory || !arena_limit ||
        arena_limit > MAX_ARENA)
        return SPICA_HIGHLIGHT_INVALID_SOURCE;
    const Grammar *grammar = grammar_for(language);
    if (!grammar)
        return SPICA_HIGHLIGHT_UNSUPPORTED;
    if (length >= arena_limit)
        return SPICA_HIGHLIGHT_BUDGET_EXCEEDED;
    char path[4096];
    int written = snprintf(path, sizeof(path), "%s/libspica-tree-sitter-%s" GRAMMAR_SUFFIX,
                           grammar_directory, grammar->name);
    if (written < 0 || (size_t)written >= sizeof(path))
        return SPICA_HIGHLIGHT_GRAMMAR_ERROR;
    SpicaHighlight *job = calloc(1, sizeof(*job));
    if (!job)
        return SPICA_HIGHLIGHT_OUT_OF_MEMORY;
    job->source_length = length;
    /* Grammar DSOs have static parser tables and no allocating constructors.
     * Python scanner allocation uses TREE_SITTER_REUSE_ALLOCATOR and the same
     * libtree-sitter ts_current_* pointers installed below. */
    job->grammar = SDL_LoadObject(path);
    if (!job->grammar) {
        free(job);
        return SPICA_HIGHLIGHT_GRAMMAR_ERROR;
    }
    /* Grammar exports use the native C ABI, not SDL's own SDLCALL ABI. */
    const TSLanguage *(*language_fn)(void) =
        (const TSLanguage *(*)(void))SDL_LoadFunction(job->grammar, grammar->symbol);
    if (!language_fn) {
        unload_grammar(job);
        free(job);
        return SPICA_HIGHLIGHT_GRAMMAR_ERROR;
    }
    jmp_buf failure;
    if (!spica_parse_arena_init(&job->arena, arena_limit - length, &failure)) {
        unload_grammar(job);
        free(job);
        return SPICA_HIGHLIGHT_OUT_OF_MEMORY;
    }
    if (setjmp(failure)) {
        /* No destructors touch potentially interrupted Tree-sitter state. All
         * parser, scanner, query, cursor, event and output heaps are this arena. */
        spica_highlight_release(job);
        return SPICA_HIGHLIGHT_BUDGET_EXCEEDED;
    }
    spica_parse_arena_activate(&job->arena);
    ts_set_allocator(arena_malloc, spica_parse_calloc, spica_parse_realloc, spica_parse_free);
    TSParser *parser = ts_parser_new();
    if (!ts_parser_set_language(parser, language_fn())) {
        spica_highlight_release(job);
        return SPICA_HIGHLIGHT_GRAMMAR_ERROR;
    }
    TSTree *tree = ts_parser_parse_string(parser, NULL, source ? source : "", (uint32_t)length);
    if (!tree) {
        spica_highlight_release(job);
        return SPICA_HIGHLIGHT_INVALID_SOURCE;
    }
    uint32_t error_offset;
    TSQueryError error;
    TSQuery *query = ts_query_new(language_fn(), grammar->query, (uint32_t)strlen(grammar->query),
                                  &error_offset, &error);
    if (!query) {
        spica_highlight_release(job);
        return SPICA_HIGHLIGHT_GRAMMAR_ERROR;
    }
    uint32_t capture_count = ts_query_capture_count(query);
    unsigned *classes = spica_parse_calloc(capture_count, sizeof(*classes));
    for (uint32_t i = 0; i < capture_count; ++i)
        classes[i] = token_class(query, i);
    TSQueryCursor *cursor = ts_query_cursor_new();
    ts_query_cursor_set_match_limit(cursor, 256);
    ts_query_cursor_exec(cursor, query, ts_tree_root_node(tree));
    Event *events = spica_parse_calloc(MAX_EVENTS, sizeof(*events));
    size_t event_count = 0;
    TSQueryMatch match;
    while (ts_query_cursor_next_match(cursor, &match)) {
        if (!predicates_match(query, &match, source, length))
            continue;
        for (uint16_t i = 0; i < match.capture_count; ++i) {
            unsigned token = classes[match.captures[i].index];
            if (!token)
                continue;
            uint32_t start = ts_node_start_byte(match.captures[i].node);
            uint32_t end = ts_node_end_byte(match.captures[i].node);
            if (start >= end || end > length)
                continue;
            if (event_count == MAX_EVENTS) {
                spica_highlight_release(job);
                return SPICA_HIGHLIGHT_BUDGET_EXCEEDED;
            }
            events[event_count++] = (Event){start, (uint16_t)token, 1};
            events[event_count++] = (Event){end, (uint16_t)token, -1};
        }
    }
    if (ts_query_cursor_did_exceed_match_limit(cursor)) {
        spica_highlight_release(job);
        return SPICA_HIGHLIGHT_BUDGET_EXCEEDED;
    }
    finish_spans(job, events, event_count);
    ts_query_cursor_delete(cursor);
    ts_query_delete(query);
    ts_tree_delete(tree);
    ts_parser_delete(parser);
    spica_parse_arena_deactivate();
    unload_grammar(job);
    *out = job;
    return SPICA_HIGHLIGHT_OK;
}
const SpicaHighlightSpan *spica_highlight_spans(const SpicaHighlight *job) {
    return job ? job->spans : NULL;
}
size_t spica_highlight_span_count(const SpicaHighlight *job) { return job ? job->count : 0; }
size_t spica_highlight_arena_used(const SpicaHighlight *job) {
    return job ? job->source_length + job->arena.used : 0;
}
void spica_highlight_release(SpicaHighlight *job) {
    if (!job)
        return;
    spica_parse_arena_release(&job->arena);
    unload_grammar(job);
    free(job);
}
