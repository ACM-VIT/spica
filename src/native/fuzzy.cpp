#include "fuzzy.h"

#include <rapidfuzz/distance/LCSseq.hpp>
#include <rapidfuzz/fuzz.hpp>

struct SpicaFuzzyQuery {
    size_t length;
    rapidfuzz::fuzz::CachedRatio<uint32_t> ratio;
    rapidfuzz::CachedLCSseq<uint32_t> lcs;

    SpicaFuzzyQuery(const uint32_t *first, size_t count)
        : length(count), ratio(first, first + count), lcs(first, first + count) {}
};

/* Keep empty ranges valid even when the caller passes NULL: the library may
 * subtract its iterators. No input buffer is copied by the wrapper. */
static constexpr uint32_t empty_input = 0;

extern "C" SpicaFuzzyQuery *spica_fuzzy_create(const uint32_t *text, size_t length) {
    if (!text && length)
        return nullptr;
    if (!length)
        text = &empty_input;
    try {
        return new SpicaFuzzyQuery(text, length);
    } catch (...) {
        return nullptr;
    }
}

extern "C" bool spica_fuzzy_score(const SpicaFuzzyQuery *query, const uint32_t *candidate,
                                  size_t length, SpicaFuzzyScore *out) {
    if (!query || !out || (!candidate && length))
        return false;
    if (!length)
        candidate = &empty_input;
    try {
        const uint32_t *last = candidate + length;
        const double ratio = query->ratio.similarity(candidate, last);
        const bool subsequence = query->lcs.similarity(candidate, last) == query->length;
        *out = {ratio, subsequence};
        return true;
    } catch (...) {
        return false;
    }
}

extern "C" void spica_fuzzy_destroy(SpicaFuzzyQuery *query) { delete query; }
