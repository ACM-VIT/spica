#ifndef SPICA_FUZZY_H
#define SPICA_FUZZY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SpicaFuzzyQuery SpicaFuzzyQuery;
typedef struct {
    double ratio;
    bool subsequence;
} SpicaFuzzyScore;

/* Inputs are Unicode codepoints normalized by the caller. The query owns its
 * caches; candidates are borrowed for scoring. NULL is valid for empty input.
 * Ratio is RapidFuzz's similarity directly, on a 0..100 scale. */
SpicaFuzzyQuery *spica_fuzzy_create(const uint32_t *text, size_t length);
/* Returns false on invalid arguments or an exception, leaving out unchanged. */
bool spica_fuzzy_score(const SpicaFuzzyQuery *query, const uint32_t *candidate, size_t length,
                       SpicaFuzzyScore *out);
void spica_fuzzy_destroy(SpicaFuzzyQuery *query);

#ifdef __cplusplus
}
#endif

#endif
