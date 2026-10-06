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

/* Unicode case folding can expand one scalar into up to three scalars.
 * out must have room for three values; returns the number written. */
size_t spica_fuzzy_case_fold(uint32_t scalar, uint32_t out[3]);

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
