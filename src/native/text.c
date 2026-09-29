#include "text.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb-ft.h>
#include <hb.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define GLYPH_LIMIT 512

typedef struct {
    unsigned int index;
    SDL_Texture *texture;
    int left, top, width, height;
} Glyph;

struct SpicaText {
    SDL_Renderer *renderer;
    FT_Library library;
    FT_Face face;
    hb_font_t *font;
    hb_buffer_t *buffer;
    Glyph glyphs[GLYPH_LIMIT];
    unsigned count;
};

SpicaText *spica_text_create(SDL_Renderer *renderer, const char *font_path) {
    SpicaText *text = calloc(1, sizeof(*text));
    if (!text) return NULL;
    text->renderer = renderer;
    if (FT_Init_FreeType(&text->library)) goto fail;
    if (FT_New_Face(text->library, font_path, 0, &text->face)) goto fail;
    if (FT_Set_Pixel_Sizes(text->face, 0, 15)) goto fail;
    text->font = hb_ft_font_create_referenced(text->face);
    text->buffer = hb_buffer_create();
    if (!text->font || !text->buffer || !hb_buffer_allocation_successful(text->buffer)) goto fail;
    return text;
fail:
    spica_text_destroy(text);
    return NULL;
}

void spica_text_destroy(SpicaText *text) {
    if (!text) return;
    for (unsigned i = 0; i < text->count; ++i) SDL_DestroyTexture(text->glyphs[i].texture);
    if (text->buffer) hb_buffer_destroy(text->buffer);
    if (text->font) hb_font_destroy(text->font);
    if (text->face) FT_Done_Face(text->face);
    if (text->library) FT_Done_FreeType(text->library);
    free(text);
}

static Glyph *get_glyph(SpicaText *text, unsigned index) {
    for (unsigned i = 0; i < text->count; ++i)
        if (text->glyphs[i].index == index) return &text->glyphs[i];
    if (text->count == GLYPH_LIMIT || FT_Load_Glyph(text->face, index, FT_LOAD_RENDER)) return NULL;
    FT_GlyphSlot slot = text->face->glyph;
    FT_Bitmap *bitmap = &slot->bitmap;
    if (bitmap->width > 128 || bitmap->rows > 128) return NULL;
    Glyph *glyph = &text->glyphs[text->count];
    *glyph = (Glyph){.index = index, .left = slot->bitmap_left, .top = slot->bitmap_top,
                     .width = (int)bitmap->width, .height = (int)bitmap->rows};
    if (glyph->width && glyph->height) {
        glyph->texture = SDL_CreateTexture(text->renderer, SDL_PIXELFORMAT_RGBA8888,
                                           SDL_TEXTUREACCESS_STATIC, glyph->width, glyph->height);
        if (!glyph->texture) return NULL;
        size_t count = (size_t)glyph->width * glyph->height;
        Uint32 *pixels = malloc(count * sizeof(*pixels));
        if (!pixels) { SDL_DestroyTexture(glyph->texture); return NULL; }
        for (int y = 0; y < glyph->height; ++y) {
            const unsigned char *row = bitmap->buffer + y * bitmap->pitch;
            for (int x = 0; x < glyph->width; ++x) {
                unsigned char a = bitmap->pixel_mode == FT_PIXEL_MODE_GRAY ? row[x] :
                                  bitmap->pixel_mode == FT_PIXEL_MODE_MONO ?
                                  (row[x / 8] & (0x80 >> (x % 8)) ? 255 : 0) : 0;
                pixels[(size_t)y * glyph->width + x] = SDL_MapRGBA(
                    SDL_GetPixelFormatDetails(SDL_PIXELFORMAT_RGBA8888), NULL, 255, 255, 255, a);
            }
        }
        bool uploaded = SDL_UpdateTexture(glyph->texture, NULL, pixels, glyph->width * 4);
        free(pixels);
        if (!uploaded || !SDL_SetTextureBlendMode(glyph->texture, SDL_BLENDMODE_BLEND)) {
            SDL_DestroyTexture(glyph->texture);
            return NULL;
        }
    }
    ++text->count;
    return glyph;
}

bool spica_text_draw(SpicaText *text, const char *utf8, size_t length, float x, float baseline,
                     SDL_Color color) {
    if (length > INT_MAX) return false;
    hb_buffer_clear_contents(text->buffer);
    hb_buffer_add_utf8(text->buffer, utf8, (int)length, 0, (int)length);
    hb_buffer_guess_segment_properties(text->buffer);
    hb_shape(text->font, text->buffer, NULL, 0);
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(text->buffer, &count);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(text->buffer, &count);
    for (unsigned i = 0; i < count; ++i) {
        Glyph *glyph = get_glyph(text, info[i].codepoint);
        if (!glyph) return false;
        if (glyph->texture) {
            SDL_SetTextureColorMod(glyph->texture, color.r, color.g, color.b);
            SDL_FRect dst = { x + pos[i].x_offset / 64.0f + glyph->left,
                             baseline - pos[i].y_offset / 64.0f - glyph->top,
                             (float)glyph->width, (float)glyph->height };
            if (!SDL_RenderTexture(text->renderer, glyph->texture, NULL, &dst)) return false;
        }
        x += pos[i].x_advance / 64.0f;
        baseline -= pos[i].y_advance / 64.0f;
    }
    return true;
}
