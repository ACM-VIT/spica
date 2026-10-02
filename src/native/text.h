#ifndef SPICA_TEXT_H
#define SPICA_TEXT_H
#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stddef.h>

/* Main-thread-only. Engine owns fonts/cache; layouts own immutable positions,
 * not textures. Release every layout before destroying its engine. Creation
 * rejects malformed UTF-8, missing fonts/glyphs, and exhausted budgets with an
 * SDL error; draws never reshape. Registration must precede live layouts.
 * Bounds: 32768 UTF-8 bytes, 8192 codepoints, 16384 glyphs/layout; aggregate
 * retained layouts 2 MiB; shared FreeType/HarfBuzz table allocations 4 MiB;
 * 512 LRU glyph entries /
 * 2 MiB texture pixels; 256x256 maximum raster; 12 lazily opened faces.
 * Font sizes 8..64 px; 16 legacy label layouts of at most 128 bytes each
 * (charged to the retained-layout cap). Engine scratch is fixed at creation.
 * External library metadata/driver memory is not this ledger. */
typedef struct SpicaText SpicaText;
typedef struct SpicaTextLayout SpicaTextLayout;
enum { SPICA_TEXT_BOLD = 1, SPICA_TEXT_ITALIC = 2, SPICA_TEXT_MONOSPACE = 4 };
typedef struct {
    size_t byte_start, byte_end;
    unsigned style;
} SpicaTextSpan;
typedef struct {
    size_t byte_start, byte_end;
    Uint32 rgba;
} SpicaTextColorSpan;
typedef struct {
    size_t byte_start, byte_end;
    float y, height, width, baseline;
} SpicaTextLine;
typedef struct {
    size_t fixed_cpu_bytes, font_bytes, layout_bytes, glyph_bytes;
    unsigned live_layouts, glyph_count, face_count;
} SpicaTextStats;

SpicaText *spica_text_create(SDL_Renderer *renderer, const char *font_path);
bool spica_text_set_monospace(SpicaText *engine, const char *font_path);
bool spica_text_add_fallback(SpicaText *engine, const char *font_path, long face_index);
void spica_text_destroy(SpicaText *engine);
bool spica_text_get_stats(const SpicaText *engine, SpicaTextStats *out);
/* Logical-coordinate-to-output-pixel factors, independently per axis. Default
 * 1/1; use output pixels / logical presentation dimensions for SDL STRETCH.
 * Call when the renderer output scale changes, before drawing. Factors must
 * be finite and in (0,4]; textures are evicted, retained layouts and all caret /
 * hit-test / selection coordinates stay unchanged. Rasterization uses device
 * sizes at 26.6 precision; antialiased ink origins snap to output-pixel edges.
 * Intended for a zero-origin SDL viewport / STRETCH logical presentation. */
bool spica_text_set_render_scale(SpicaText *engine, float scale_x, float scale_y);
/* Compatibility labels: 15 px, y is baseline. Prefer retained layouts. */
bool spica_text_draw(SpicaText *engine, const char *utf8, size_t length, float x, float baseline,
                     SDL_Color color);

SpicaTextLayout *spica_text_layout_create(SpicaText *engine, const char *utf8, size_t length,
                                          float width, unsigned pixel_size, bool monospace);
SpicaTextLayout *spica_text_layout_create_styled(SpicaText *engine, const char *utf8, size_t length,
                                                 float width, unsigned pixel_size, bool monospace,
                                                 unsigned style);
/* Spans must be sorted, disjoint, and on grapheme boundaries. Unspanned bytes
 * use the base face; MONOSPACE selects the registered mono face. No fake styles:
 * bold uses a real bold face or variable wght; italic requires a real italic. */
SpicaTextLayout *spica_text_layout_create_spans(SpicaText *engine, const char *utf8, size_t length,
                                                float width, unsigned pixel_size, bool monospace,
                                                const SpicaTextSpan *spans, size_t span_count);
void spica_text_layout_release(SpicaTextLayout *layout);
float spica_text_layout_height(const SpicaTextLayout *layout);
size_t spica_text_layout_line_count(const SpicaTextLayout *layout);
bool spica_text_layout_line(const SpicaTextLayout *layout, size_t index, SpicaTextLine *out);
/* Top-origin, respects existing SDL renderer clip; skips clipped lines/glyphs
 * before touching the raster cache. Scrolling retained layouts never shapes. */
bool spica_text_layout_draw(SpicaText *engine, const SpicaTextLayout *layout, float x, float y,
                            SDL_Color color);
/* Borrowed sorted/disjoint source-byte ranges; rgba is 0xRRGGBBAA.
 * A complete glyph uses the color at its source cluster's byte anchor. */
bool spica_text_layout_draw_colors(SpicaText *engine, const SpicaTextLayout *layout, float x,
                                   float y, SDL_Color default_color,
                                   const SpicaTextColorSpan *spans, size_t span_count);
/* Coordinates relative to layout top-left. Byte offsets are grapheme boundaries.
 * Ligature interior carets are distributed across constituent graphemes. */
size_t spica_text_layout_hit_test(const SpicaTextLayout *layout, float x, float y);
bool spica_text_layout_caret(const SpicaTextLayout *layout, size_t byte_offset, SDL_FRect *out);
/* Allocation-free visual spans for a logical [start_byte,end_byte) selection.
 * Partial graphemes expand to caret edges; ligatures use distributed interior
 * carets. Adjacent spans merge per line; bidi gaps stay separate; tabs count,
 * newline-only ranges have no ink span. Rectangles are logical, layout-relative.
 * Returns total required count, writing at most capacity entries; NULL out is
 * a count-only query. Invalid/empty ranges return zero, end clamps to length. */
size_t spica_text_layout_selection_rects(const SpicaTextLayout *layout, size_t start_byte,
                                         size_t end_byte, SDL_FRect *out, size_t capacity);
#endif
