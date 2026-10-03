#include "text.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_MODULE_H
#include FT_MULTIPLE_MASTERS_H
#include <hb-ot.h>
#include <hb.h>
#include <fribidi.h>
#include <linebreak.h>
#include <graphemebreak.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef __linux__
#include <fontconfig/fontconfig.h>
#elif defined(__APPLE__)
#include <CoreText/CoreText.h>
#endif

#define CHAR_LIMIT 8192u
#define BYTE_LIMIT 32768u
#define POSITION_LIMIT 16384u
#define CARET_LIMIT (CHAR_LIMIT * 2u + 2u)
#define FACE_LIMIT 12u
#define GLYPH_LIMIT 512u
#define RASTER_SIDE 256u
#define FONT_BYTES (4u * 1024u * 1024u)
#define LAYOUT_BYTES (2u * 1024u * 1024u)
#define GLYPH_BYTES (2u * 1024u * 1024u)

typedef struct {
    SpicaText *owner;
    FT_Face face;
    hb_font_t *font;
    FT_StreamRec stream;
    SDL_IOStream *io;
    char path[1024];
    long index;
    unsigned pins;
    uint64_t used;
    FT_Fixed normal_weight, bold_weight;
    unsigned weight_axis, axis_count;
    FT_Fixed coordinates[16];
    bool variable_bold, registered, tables_failed;
    unsigned active_x, active_y, active_style;
    float raster_scale_x, raster_scale_y;
} Face;
typedef struct {
    unsigned index;
    uint16_t face, raster_x, raster_y, style;
    uint16_t bucket, phase;
    SDL_Texture *texture;
    int left, top, width, height;
    size_t bytes;
    uint64_t used;
    float scale_x, scale_y;
    bool valid, colored;
} Glyph;
typedef struct {
    unsigned index;
    uint16_t face, style;
    float x, y, advance;
    uint32_t cluster;
} Position;
typedef struct {
    uint32_t byte;
    float x;
    uint16_t line;
    bool joins_next;
} Caret;
typedef struct {
    SpicaTextLine info;
    uint32_t first, count;
} Line;
typedef struct {
    unsigned start, end, face, style;
    hb_script_t script;
    FriBidiLevel level;
    unsigned visual;
} Run;

typedef union {
    max_align_t alignment;
    size_t bytes;
} Allocation;
struct SpicaTextLayout {
    SpicaText *owner;
    size_t allocation, length;
    unsigned size, line_count, glyph_count, caret_count;
    uint16_t faces;
    float height;
    Line *lines;
    Position *positions;
    Caret *carets;
};
typedef struct {
    SpicaTextLayout *layout;
    size_t length;
    uint64_t used;
    char bytes[128];
} Label;
struct SpicaText {
    SDL_Renderer *renderer;
    FT_Library library;
    struct FT_MemoryRec_ memory;
    hb_buffer_t *buffer;
    Face faces[FACE_LIMIT];
    unsigned mono;
    float render_scale_x, render_scale_y;
    Glyph glyphs[GLYPH_LIMIT];
    uint16_t glyph_slots[1024];
    unsigned tombstones;
    Label labels[16];
    size_t font_bytes, layout_bytes, glyph_bytes;
    uint64_t clock;
    unsigned live_layouts;
    Uint32 pixels[RASTER_SIDE * RASTER_SIDE];
    /* Reused for every layout. No per-glyph allocations on cache misses. */
    FriBidiChar chars[CHAR_LIMIT];
    uint32_t offsets[CHAR_LIMIT + 1];
    FriBidiCharType types[CHAR_LIMIT];
    FriBidiBracketType brackets[CHAR_LIMIT];
    FriBidiLevel levels[CHAR_LIMIT];
    FriBidiStrIndex visual[CHAR_LIMIT];
    unsigned visual_rank[CHAR_LIMIT];
    hb_script_t scripts[CHAR_LIMIT];
    uint16_t char_faces[CHAR_LIMIT], styles[CHAR_LIMIT];
    char breaks[CHAR_LIMIT], graphemes[CHAR_LIMIT];
    float advances[CHAR_LIMIT];
    Run runs[CHAR_LIMIT];
    Position positions[POSITION_LIMIT];
    Line lines[CHAR_LIMIT + 1];
    Caret carets[CARET_LIMIT];
#ifdef __linux__
    SDL_SharedObject *fontconfig;
    FcPattern *(*pattern_create)(void);
    void (*pattern_destroy)(FcPattern *);
    FcBool (*add_charset)(FcPattern *, const char *, const FcCharSet *);
    FcBool (*add_string)(FcPattern *, const char *, const FcChar8 *);
    FcBool (*add_integer)(FcPattern *, const char *, int);
    FcResult (*get_string)(const FcPattern *, const char *, int, FcChar8 **);
    FcResult (*get_integer)(const FcPattern *, const char *, int, int *);
    FcCharSet *(*charset_create)(void);
    FcBool (*charset_add)(FcCharSet *, FcChar32);
    void (*charset_destroy)(FcCharSet *);
    FcBool (*substitute)(FcConfig *, FcPattern *, FcMatchKind);
    void (*defaults)(FcPattern *);
    FcPattern *(*match)(FcConfig *, FcPattern *, FcResult *);
#endif
};

static bool error(const char *message) { return SDL_SetError("Text: %s", message); }
static void *font_alloc(FT_Memory memory, long bytes) {
    SpicaText *t = memory->user;
    if (bytes <= 0 || (size_t)bytes > FONT_BYTES - t->font_bytes ||
        sizeof(Allocation) > FONT_BYTES - t->font_bytes - (size_t)bytes)
        return NULL;
    Allocation *a = malloc(sizeof(*a) + (size_t)bytes);
    if (!a)
        return NULL;
    a->bytes = sizeof(*a) + (size_t)bytes;
    t->font_bytes += a->bytes;
    return a + 1;
}
static void font_free(FT_Memory memory, void *block) {
    if (!block)
        return;
    Allocation *a = (Allocation *)block - 1;
    ((SpicaText *)memory->user)->font_bytes -= a->bytes;
    free(a);
}
static void *font_realloc(FT_Memory memory, long old, long bytes, void *block) {
    (void)old;
    if (!block)
        return font_alloc(memory, bytes);
    if (bytes <= 0) {
        font_free(memory, block);
        return NULL;
    }
    SpicaText *t = memory->user;
    Allocation *a = (Allocation *)block - 1;
    size_t before = a->bytes, after = sizeof(*a) + (size_t)bytes;
    if (after > before && after - before > FONT_BYTES - t->font_bytes)
        return NULL;
    a = realloc(a, after);
    if (!a)
        return NULL;
    a->bytes = after;
    t->font_bytes = t->font_bytes - before + after;
    return a + 1;
}
typedef struct {
    SpicaText *owner;
    char data[];
} FontTable;
static void release_table(void *data) {
    FontTable *table = data;
    font_free(&table->owner->memory, table);
}
static hb_blob_t *reference_table(hb_face_t *face, hb_tag_t tag, void *data) {
    (void)face;
    Face *f = data;
    FT_ULong length = 0;
    if (tag == HB_TAG_NONE || FT_Load_Sfnt_Table(f->face, tag, 0, NULL, &length))
        return hb_blob_get_empty();
    if (!length)
        return hb_blob_get_empty();
    if (length > FONT_BYTES - sizeof(FontTable)) {
        f->tables_failed = true;
        return hb_blob_get_empty();
    }
    FontTable *table = font_alloc(&f->owner->memory, (long)(sizeof(*table) + length));
    if (!table) {
        f->tables_failed = true;
        return hb_blob_get_empty();
    }
    table->owner = f->owner;
    if (FT_Load_Sfnt_Table(f->face, tag, 0, (FT_Byte *)table->data, &length)) {
        release_table(table);
        f->tables_failed = true;
        return hb_blob_get_empty();
    }
    hb_blob_t *blob = hb_blob_create(table->data, (unsigned)length, HB_MEMORY_MODE_READONLY, table,
                                     release_table);
    if (hb_blob_get_length(blob) != length)
        f->tables_failed = true;
    return blob;
}
static bool reset_tables(Face *f) {
    hb_face_t *face = hb_face_create_for_tables(reference_table, f, NULL);
    if (face == hb_face_get_empty())
        return error("shaping face allocation failed");
    hb_face_set_index(face, (unsigned)f->face->face_index);
    hb_face_set_upem(face, f->face->units_per_EM ? f->face->units_per_EM : 2048);
    hb_face_set_glyph_count(face, (unsigned)f->face->num_glyphs);
    hb_font_set_face(f->font, face);
    hb_ot_font_set_funcs(f->font);
    hb_face_destroy(face);
    f->tables_failed = false;
    return true;
}
static unsigned long stream_read(FT_Stream stream, unsigned long offset, unsigned char *buffer,
                                 unsigned long count) {
    SDL_IOStream *io = stream->descriptor.pointer;
    if (SDL_SeekIO(io, (Sint64)offset, SDL_IO_SEEK_SET) < 0)
        return count ? 0 : 1;
    return count ? (unsigned long)SDL_ReadIO(io, buffer, count) : 0;
}
static unsigned glyph_hash(unsigned face, unsigned raster_x, unsigned raster_y, unsigned style,
                           unsigned index, unsigned phase) {
    uint32_t key = index * 2654435761u;
    key ^= face * 2246822519u;
    key ^= raster_x * 3266489917u;
    key ^= raster_y * 374761393u;
    key ^= style * 668265263u;
    key ^= phase * 1274126177u;
    return (key ^ (key >> 16)) & 1023u;
}
static void rebuild_glyph_slots(SpicaText *t) {
    memset(t->glyph_slots, 0, sizeof(t->glyph_slots));
    t->tombstones = 0;
    for (unsigned i = 0; i < GLYPH_LIMIT; ++i) {
        Glyph *g = &t->glyphs[i];
        if (!g->valid)
            continue;
        unsigned bucket =
            glyph_hash(g->face, g->raster_x, g->raster_y, g->style, g->index, g->phase);
        while (t->glyph_slots[bucket])
            bucket = (bucket + 1) & 1023u;
        g->bucket = (uint16_t)bucket;
        t->glyph_slots[bucket] = (uint16_t)(i + 1);
    }
}
static void clear_glyph(SpicaText *t, Glyph *g) {
    if (!g->valid)
        return;
    t->glyph_slots[g->bucket] = UINT16_MAX;
    ++t->tombstones;
    if (g->texture)
        SDL_DestroyTexture(g->texture);
    t->glyph_bytes -= g->bytes;
    memset(g, 0, sizeof(*g));
}
static void close_face(SpicaText *t, unsigned id) {
    Face *f = &t->faces[id];
    for (unsigned i = 0; i < GLYPH_LIMIT; ++i)
        if (t->glyphs[i].valid && t->glyphs[i].face == id)
            clear_glyph(t, &t->glyphs[i]);
    if (f->font)
        hb_font_destroy(f->font);
    if (f->face)
        FT_Done_Face(f->face);
    if (f->io)
        SDL_CloseIO(f->io);
    memset(f, 0, sizeof(*f));
}
static int open_face(SpicaText *t, const char *path, long index, bool registered) {
    if (!path || strlen(path) >= sizeof(t->faces[0].path) || index < 0)
        return error("invalid font path or face index"), -1;
    for (unsigned i = 0; i < FACE_LIMIT; ++i)
        if (t->faces[i].face && t->faces[i].index == index && !strcmp(t->faces[i].path, path)) {
            t->faces[i].registered |= registered;
            t->faces[i].used = ++t->clock;
            return (int)i;
        }
    unsigned id = FACE_LIMIT;
    for (unsigned i = 0; i < FACE_LIMIT; ++i) {
        if (!t->faces[i].face) {
            id = i;
            break;
        }
        if (!t->faces[i].registered && !t->faces[i].pins &&
            (id == FACE_LIMIT || t->faces[i].used < t->faces[id].used))
            id = i;
    }
    if (id == FACE_LIMIT)
        return error("all font slots are retained"), -1;
    close_face(t, id);
    Face *f = &t->faces[id];
    f->owner = t;
    f->io = SDL_IOFromFile(path, "rb");
    if (!f->io)
        return -1;
    Sint64 bytes = SDL_GetIOSize(f->io);
    if (bytes <= 0 || (uint64_t)bytes > ULONG_MAX)
        goto fail;
    f->stream.size = (unsigned long)bytes;
    f->stream.descriptor.pointer = f->io;
    f->stream.read = stream_read;
    FT_Open_Args args = {.flags = FT_OPEN_STREAM, .stream = &f->stream};
    if (FT_Open_Face(t->library, &args, index, &f->face))
        goto fail;
    if (FT_Select_Charmap(f->face, FT_ENCODING_UNICODE))
        goto fail;
    if (FT_Set_Pixel_Sizes(f->face, 0, 15) &&
        (!f->face->num_fixed_sizes || FT_Select_Size(f->face, 0)))
        goto fail;
    f->font = hb_font_create(hb_face_get_empty());
    if (!f->font || f->font == hb_font_get_empty())
        goto fail;
    if (!reset_tables(f))
        goto fail;
    /* Variation support is explicit; no synthesized bold/italic outlines. */
    FT_MM_Var *variation = NULL;
    if (!FT_Get_MM_Var(f->face, &variation)) {
        if (variation->num_axis <= 16) {
            f->axis_count = variation->num_axis;
            for (unsigned a = 0; a < variation->num_axis; ++a) {
                f->coordinates[a] = variation->axis[a].def;
                if (variation->axis[a].tag == FT_MAKE_TAG('w', 'g', 'h', 't')) {
                    f->weight_axis = a;
                    f->normal_weight = variation->axis[a].def;
                    f->bold_weight = 700 * 65536L;
                    if (f->bold_weight > variation->axis[a].maximum)
                        f->bold_weight = variation->axis[a].maximum;
                    f->variable_bold = f->bold_weight >= 600 * 65536L;
                }
            }
        }
        FT_Done_MM_Var(t->library, variation);
    }
    strcpy(f->path, path);
    f->index = index;
    f->registered = registered;
    f->used = ++t->clock;
    return (int)id;
fail:
    close_face(t, id);
    return error("font cannot be opened within the FreeType budget"), -1;
}
static bool face_style(const Face *f, unsigned style) {
    return (!(style & SPICA_TEXT_ITALIC) || (f->face->style_flags & FT_STYLE_FLAG_ITALIC)) &&
           (!(style & SPICA_TEXT_BOLD) || (f->face->style_flags & FT_STYLE_FLAG_BOLD) ||
            f->variable_bold);
}
static unsigned available_style(const Face *f, unsigned style) {
    /* Color emoji fonts commonly have only a regular face. Keep their color artwork when a
     * surrounding Markdown span requests an unavailable style, without synthesizing glyphs. */
    if (FT_HAS_COLOR(f->face) && !face_style(f, style))
        style &= ~(SPICA_TEXT_BOLD | SPICA_TEXT_ITALIC);
    return style;
}
static bool select_style(Face *f, unsigned style) {
    style = available_style(f, style) & (SPICA_TEXT_BOLD | SPICA_TEXT_ITALIC);
    if (!face_style(f, style))
        return error("requested font style is unavailable");
    if (f->active_style == style)
        return true;
    if (f->variable_bold) {
        f->coordinates[f->weight_axis] =
            style & SPICA_TEXT_BOLD ? f->bold_weight : f->normal_weight;
        if (FT_Set_Var_Design_Coordinates(f->face, f->axis_count, f->coordinates))
            return error("font variation selection failed");
        hb_variation_t weight = {HB_TAG('w', 'g', 'h', 't'),
                                 f->coordinates[f->weight_axis] / 65536.0f};
        hb_font_set_variations(f->font, &weight, 1);
    }
    f->active_x = f->active_y = 0;
    f->active_style = style;
    return true;
}
static bool activate(Face *f, unsigned raster_x, unsigned raster_y, unsigned style) {
    if (!select_style(f, style))
        return false;
    if (f->active_x == raster_x && f->active_y == raster_y)
        return true;
    f->raster_scale_x = f->raster_scale_y = 1.0f;
    /* 26.6 device-pixel sizes preserve fractional DPR instead of stretching
     * a logical-size bitmap. HarfBuzz shaping never mutates this FT size. */
    if (FT_Set_Char_Size(f->face, (FT_F26Dot6)raster_x, (FT_F26Dot6)raster_y, 72, 72)) {
        if (!f->face->num_fixed_sizes)
            return error("font size selection failed");
        unsigned best = 0;
        for (int i = 1; i < f->face->num_fixed_sizes; ++i)
            if (abs(f->face->available_sizes[i].y_ppem - (int)raster_y) <
                abs(f->face->available_sizes[best].y_ppem - (int)raster_y))
                best = (unsigned)i;
        if (FT_Select_Size(f->face, (int)best))
            return error("bitmap strike selection failed");
        f->raster_scale_x = (float)raster_x / f->face->available_sizes[best].x_ppem;
        f->raster_scale_y = (float)raster_y / f->face->available_sizes[best].y_ppem;
    }
    f->active_x = raster_x;
    f->active_y = raster_y;
    return true;
}
static bool ignorable(uint32_t c) {
    return c == 0x200c || c == 0x200d || c == 0x200b || c == 0x2060 ||
           (c >= 0xfe00 && c <= 0xfe0f) || (c >= 0xe0100 && c <= 0xe01ef) ||
           (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) || c == 0x061c ||
           c == 0x200e || c == 0x200f || c == 0xad;
}
static bool covers(Face *f, const FriBidiChar *chars, unsigned count, unsigned style) {
    if (!face_style(f, available_style(f, style)))
        return false;
    for (unsigned i = 0; i < count; ++i) {
        if (chars[i] == 0xfe0f && i && !FT_HAS_COLOR(f->face) &&
            FT_Face_GetCharVariantIsDefault(f->face, chars[i - 1], chars[i]) < 0)
            return false;
        if (!ignorable(chars[i]) && chars[i] != '\t' && chars[i] != '\n' && chars[i] != '\r' &&
            chars[i] != 0x2028 && chars[i] != 0x2029 && !FT_Get_Char_Index(f->face, chars[i]))
            return false;
    }
    return true;
}
#ifdef __linux__
static bool load_fontconfig(SpicaText *t) {
    if (t->fontconfig)
        return true;
    t->fontconfig = SDL_LoadObject("libfontconfig.so.1");
    if (!t->fontconfig)
        return false;
#define FC_LOAD(field, symbol)                                                                     \
    do {                                                                                           \
        SDL_FunctionPointer function = SDL_LoadFunction(t->fontconfig, symbol);                    \
        _Static_assert(sizeof(function) == sizeof(t->field), "function pointer size");             \
        memcpy(&t->field, &function, sizeof(function));                                            \
        if (!t->field)                                                                             \
            goto fail;                                                                             \
    } while (0)
    FC_LOAD(pattern_create, "FcPatternCreate");
    FC_LOAD(pattern_destroy, "FcPatternDestroy");
    FC_LOAD(add_charset, "FcPatternAddCharSet");
    FC_LOAD(add_string, "FcPatternAddString");
    FC_LOAD(add_integer, "FcPatternAddInteger");
    FC_LOAD(get_string, "FcPatternGetString");
    FC_LOAD(get_integer, "FcPatternGetInteger");
    FC_LOAD(charset_create, "FcCharSetCreate");
    FC_LOAD(charset_add, "FcCharSetAddChar");
    FC_LOAD(charset_destroy, "FcCharSetDestroy");
    FC_LOAD(substitute, "FcConfigSubstitute");
    FC_LOAD(defaults, "FcDefaultSubstitute");
    FC_LOAD(match, "FcFontMatch");
#undef FC_LOAD
    return true;
fail:
    SDL_UnloadObject(t->fontconfig);
    t->fontconfig = NULL;
    return false;
}
static int system_face(SpicaText *t, const FriBidiChar *chars, unsigned count, unsigned style) {
    if (!load_fontconfig(t))
        return -1;
    FcPattern *request = t->pattern_create();
    FcCharSet *set = t->charset_create();
    if (!request || !set) {
        if (request)
            t->pattern_destroy(request);
        if (set)
            t->charset_destroy(set);
        return -1;
    }
    bool ok = true;
    bool emoji = false;
    for (unsigned i = 0; i < count; ++i)
        if (chars[i] == 0xfe0f || (chars[i] >= 0x1f000 && chars[i] <= 0x1faff))
            emoji = true;
    for (unsigned i = 0; i < count; ++i)
        if (!ignorable(chars[i]) && chars[i] != '\t')
            ok &= t->charset_add(set, chars[i]) != 0;
    ok &= t->add_charset(request, FC_CHARSET, set) != 0;
    ok &= t->add_string(request, FC_FAMILY,
                        (const FcChar8 *)(emoji                          ? "emoji"
                                          : style & SPICA_TEXT_MONOSPACE ? "monospace"
                                                                         : "sans-serif")) != 0;
    ok &= t->add_integer(request, FC_WEIGHT,
                         style & SPICA_TEXT_BOLD ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR) != 0;
    ok &= t->add_integer(request, FC_SLANT,
                         style & SPICA_TEXT_ITALIC ? FC_SLANT_ITALIC : FC_SLANT_ROMAN) != 0;
    ok &= t->substitute(NULL, request, FcMatchPattern) != 0;
    t->defaults(request);
    FcResult result;
    FcPattern *match = ok ? t->match(NULL, request, &result) : NULL;
    int face = -1, index = 0;
    FcChar8 *path = NULL;
    if (match && t->get_string(match, FC_FILE, 0, &path) == FcResultMatch) {
        t->get_integer(match, FC_INDEX, 0, &index);
        face = open_face(t, (const char *)path, index, false);
    }
    if (match)
        t->pattern_destroy(match);
    t->charset_destroy(set);
    t->pattern_destroy(request);
    if (face >= 0 && !covers(&t->faces[face], chars, count, style))
        face = -1;
    return face;
}
#elif defined(__APPLE__)
/* CoreText's fallback choice is the macOS counterpart of the fontconfig match above. Without it, any
 * grapheme the bundled fonts lack (CJK, many symbols) failed layout, and the composer's failure
 * closed the app. CoreText names a file and a PostScript name; collections (.ttc, as CJK fonts
 * ship) need the face index, so the faces are probed for that name. */
static long collection_index(SpicaText *t, const char *path, const char *name) {
    FT_Face face;
    if (FT_New_Face(t->library, path, -1, &face))
        return -1;
    long count = face->num_faces;
    FT_Done_Face(face);
    for (long i = 0; i < count; ++i) {
        if (FT_New_Face(t->library, path, i, &face))
            continue;
        const char *candidate = FT_Get_Postscript_Name(face);
        bool match = candidate && !strcmp(candidate, name);
        FT_Done_Face(face);
        if (match)
            return i;
    }
    return -1;
}
static int open_system_font(SpicaText *t, CTFontRef font, const FriBidiChar *chars, unsigned count,
                            unsigned style) {
    CFCharacterSetRef set = CTFontCopyCharacterSet(font);
    bool coverable = set != NULL;
    for (unsigned i = 0; coverable && i < count; ++i)
        if (!ignorable(chars[i]) && chars[i] != '\t')
            coverable = CFCharacterSetIsLongCharacterMember(set, chars[i]);
    if (set)
        CFRelease(set);
    if (!coverable)
        return -1;
    CFURLRef url = CTFontCopyAttribute(font, kCTFontURLAttribute);
    CFStringRef postscript = CTFontCopyPostScriptName(font);
    char path[1024], name[256];
    int face = -1;
    if (url && postscript &&
        CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)) &&
        CFStringGetCString(postscript, name, sizeof(name), kCFStringEncodingUTF8)) {
        long index = collection_index(t, path, name);
        if (index >= 0)
            face = open_face(t, path, index, false);
    }
    if (postscript)
        CFRelease(postscript);
    if (url)
        CFRelease(url);
    if (face >= 0 && !covers(&t->faces[face], chars, count, style))
        face = -1;
    return face;
}
static int system_face(SpicaText *t, const FriBidiChar *chars, unsigned count, unsigned style) {
    bool emoji = false;
    for (unsigned i = 0; i < count; ++i)
        if (chars[i] == 0xfe0f || (chars[i] >= 0x1f000 && chars[i] <= 0x1faff))
            emoji = true;
    CFStringRef text = CFStringCreateWithBytes(NULL, (const UInt8 *)chars, count * sizeof(*chars),
                                               kCFStringEncodingUTF32LE, false);
    CTFontRef base = CTFontCreateWithName(emoji                          ? CFSTR("Apple Color Emoji")
                                          : style & SPICA_TEXT_MONOSPACE ? CFSTR("Menlo")
                                                                         : CFSTR("Helvetica"),
                                          15, NULL);
    CTFontSymbolicTraits traits = (style & SPICA_TEXT_BOLD ? kCTFontBoldTrait : 0) |
                                  (style & SPICA_TEXT_ITALIC ? kCTFontItalicTrait : 0);
    if (base && traits) {
        CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, traits, traits);
        if (styled) {
            CFRelease(base);
            base = styled;
        }
    }
    int face = -1;
    CTFontRef match =
        text && base ? CTFontCreateForString(base, text, CFRangeMake(0, CFStringGetLength(text)))
                     : NULL;
    if (match) {
        face = open_system_font(t, match, chars, count, style);
        CFRelease(match);
    }
    /* CoreText's first choice can be a font FreeType cannot read (on macOS 27 the PingFang UI faces
     * fail to open), so walk the rest of the same ordered cascade list. */
    CFArrayRef cascade = face < 0 && base ? CTFontCopyDefaultCascadeListForLanguages(base, NULL) : NULL;
    for (CFIndex i = 0; cascade && face < 0 && i < CFArrayGetCount(cascade); ++i) {
        CTFontRef font = CTFontCreateWithFontDescriptor(
            (CTFontDescriptorRef)CFArrayGetValueAtIndex(cascade, i), 15, NULL);
        if (font) {
            face = open_system_font(t, font, chars, count, style);
            CFRelease(font);
        }
    }
    if (cascade)
        CFRelease(cascade);
    if (base)
        CFRelease(base);
    if (text)
        CFRelease(text);
    return face;
}
#else
static int system_face(SpicaText *t, const FriBidiChar *chars, unsigned count, unsigned style) {
    (void)t;
    (void)chars;
    (void)count;
    (void)style;
    return -1;
}
#endif
static int select_face(SpicaText *t, unsigned start, unsigned end, unsigned style) {
    unsigned base = style & SPICA_TEXT_MONOSPACE ? t->mono : 0;
    if (base == FACE_LIMIT)
        return error("monospace font was not registered"), -1;
    if (covers(&t->faces[base], t->chars + start, end - start, style))
        return (int)base;
    Face *primary = &t->faces[base];
    for (unsigned pass = 0; pass < 2; ++pass) {
        for (unsigned i = 0; i < FACE_LIMIT; ++i) {
            Face *candidate = &t->faces[i];
            if (!candidate->face)
                continue;
            bool family = primary->face->family_name && candidate->face->family_name &&
                          !strcmp(primary->face->family_name, candidate->face->family_name);
            if (!pass && !family)
                continue;
            if (pass && !!FT_IS_FIXED_WIDTH(candidate->face) != !!(style & SPICA_TEXT_MONOSPACE))
                continue;
            if (covers(candidate, t->chars + start, end - start, style))
                return (int)i;
        }
    }
    int f = system_face(t, t->chars + start, end - start, style);
    if (f >= 0)
        return f;
    /* A proportional fallback is preferable to a missing script, but never
     * silently substitute it for an unavailable ASCII monospace style. */
    if (!covers(primary, t->chars + start, end - start, 0)) {
        for (unsigned i = 0; i < FACE_LIMIT; ++i)
            if (t->faces[i].face && covers(&t->faces[i], t->chars + start, end - start, style))
                return (int)i;
    }
    return error("no font covers the requested grapheme and style"), -1;
}

SpicaText *spica_text_create(SDL_Renderer *renderer, const char *font_path) {
    if (!renderer)
        return error("renderer is required"), NULL;
    SpicaText *t = calloc(1, sizeof(*t));
    if (!t)
        return error("engine allocation failed"), NULL;
    t->renderer = renderer;
    t->render_scale_x = t->render_scale_y = 1.0f;
    t->mono = FACE_LIMIT;
    t->memory = (struct FT_MemoryRec_){
        .user = t, .alloc = font_alloc, .free = font_free, .realloc = font_realloc};
    if (FT_New_Library(&t->memory, &t->library))
        goto fail;
    FT_Add_Default_Modules(t->library);
    t->buffer = hb_buffer_create();
    if (!t->buffer || !hb_buffer_allocation_successful(t->buffer) ||
        open_face(t, font_path, 0, true) != 0)
        goto fail;
    return t;
fail:
    spica_text_destroy(t);
    return NULL;
}
bool spica_text_set_monospace(SpicaText *t, const char *path) {
    if (!t || t->live_layouts)
        return error("register fonts before creating layouts");
    int id = open_face(t, path, 0, true);
    if (id < 0)
        return false;
    t->mono = (unsigned)id;
    return true;
}
bool spica_text_add_fallback(SpicaText *t, const char *path, long index) {
    if (!t || t->live_layouts)
        return error("register fonts before creating layouts");
    return open_face(t, path, index, true) >= 0;
}
void spica_text_destroy(SpicaText *t) {
    if (!t)
        return;
    for (unsigned i = 0; i < 16; ++i) {
        spica_text_layout_release(t->labels[i].layout);
        t->labels[i].layout = NULL;
    }
    if (t->live_layouts) {
        error("release retained layouts before destroying engine");
        return;
    }
    for (unsigned i = 0; i < FACE_LIMIT; ++i)
        close_face(t, i);
    if (t->buffer)
        hb_buffer_destroy(t->buffer);
    if (t->library)
        FT_Done_Library(t->library);
#ifdef __linux__
    if (t->fontconfig)
        SDL_UnloadObject(t->fontconfig);
#endif
    free(t);
}
bool spica_text_set_render_scale(SpicaText *t, float scale_x, float scale_y) {
    if (!t || !isfinite(scale_x) || !isfinite(scale_y) || scale_x <= 0 || scale_y <= 0 ||
        scale_x > 4 || scale_y > 4)
        return error("render scale must be finite and in (0, 4]");
    if (t->render_scale_x == scale_x && t->render_scale_y == scale_y)
        return true;
    for (unsigned i = 0; i < GLYPH_LIMIT; ++i)
        clear_glyph(t, &t->glyphs[i]);
    memset(t->glyph_slots, 0, sizeof(t->glyph_slots));
    t->tombstones = 0;
    t->render_scale_x = scale_x;
    t->render_scale_y = scale_y;
    return true;
}
bool spica_text_get_stats(const SpicaText *t, SpicaTextStats *out) {
    if (!t || !out)
        return false;
    *out = (SpicaTextStats){.fixed_cpu_bytes = sizeof(*t),
                            .font_bytes = t->font_bytes,
                            .layout_bytes = t->layout_bytes,
                            .glyph_bytes = t->glyph_bytes,
                            .live_layouts = t->live_layouts};
    for (unsigned i = 0; i < FACE_LIMIT; ++i)
        if (t->faces[i].face)
            ++out->face_count;
    for (unsigned i = 0; i < GLYPH_LIMIT; ++i)
        if (t->glyphs[i].valid)
            ++out->glyph_count;
    return true;
}
static bool decode(SpicaText *t, const char *s, size_t length, unsigned *out) {
    unsigned n = 0;
    for (size_t i = 0; i < length;) {
        if (n == CHAR_LIMIT)
            return error("visible layout exceeds 8192 codepoints");
        t->offsets[n] = (uint32_t)i;
        unsigned char b = (unsigned char)s[i++];
        uint32_t c;
        unsigned extra;
        if (b < 0x80) {
            c = b;
            extra = 0;
        } else if (b >= 0xc2 && b <= 0xdf) {
            c = b & 0x1f;
            extra = 1;
        } else if (b >= 0xe0 && b <= 0xef) {
            c = b & 0x0f;
            extra = 2;
        } else if (b >= 0xf0 && b <= 0xf4) {
            c = b & 7;
            extra = 3;
        } else
            return error("invalid UTF-8");
        if (extra > length - i)
            return error("incomplete UTF-8");
        for (unsigned j = 0; j < extra; ++j) {
            b = (unsigned char)s[i++];
            if ((b & 0xc0) != 0x80)
                return error("invalid UTF-8 continuation");
            c = (c << 6) | (b & 0x3f);
        }
        if ((extra == 1 && c < 0x80) || (extra == 2 && c < 0x800) || (extra == 3 && c < 0x10000) ||
            c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff) || c == 0)
            return error("invalid Unicode scalar value");
        t->chars[n++] = c;
    }
    t->offsets[n] = (uint32_t)length;
    *out = n;
    return true;
}
static bool boundary(SpicaText *t, unsigned n, size_t byte) {
    if (!byte || byte == t->offsets[n])
        return true;
    for (unsigned i = 1; i < n; ++i)
        if (t->offsets[i] == byte)
            return t->graphemes[i - 1] == GRAPHEMEBREAK_BREAK;
    return false;
}
static bool paragraph(SpicaText *t, unsigned start, unsigned end, FriBidiParType *base) {
    fribidi_get_bidi_types(t->chars + start, (FriBidiStrIndex)(end - start), t->types + start);
    fribidi_get_bracket_types(t->chars + start, (FriBidiStrIndex)(end - start), t->types + start,
                              t->brackets + start);
    *base = FRIBIDI_PAR_ON;
    if (end != start && !fribidi_get_par_embedding_levels_ex(t->types + start, t->brackets + start,
                                                             (FriBidiStrIndex)(end - start), base,
                                                             t->levels + start))
        return error("bidi paragraph resolution failed");
    return true;
}
static unsigned make_runs(SpicaText *t, unsigned start, unsigned end) {
    unsigned count = 0;
    for (unsigned i = start; i < end;) {
        unsigned j = i + 1;
        while (j < end && t->char_faces[j] == t->char_faces[i] && t->styles[j] == t->styles[i] &&
               t->scripts[j] == t->scripts[i] && t->levels[j] == t->levels[i] &&
               t->chars[j] != '\t' && t->chars[i] != '\t')
            ++j;
        t->runs[count++] = (Run){.start = i,
                                 .end = j,
                                 .face = t->char_faces[i],
                                 .style = t->styles[i],
                                 .script = t->scripts[i],
                                 .level = t->levels[i]};
        i = j;
    }
    return count;
}
static bool shape(SpicaText *t, Run run, unsigned line_start, unsigned line_end, unsigned size,
                  unsigned *count, hb_glyph_info_t **info, hb_glyph_position_t **positions) {
    Face *f = &t->faces[run.face];
    if (f->tables_failed && !reset_tables(f))
        return false;
    if (!select_style(f, run.style))
        return false;
    /* Table-based advances are independent of FT bitmap-strike metrics.
     * FT_Get_Advance is not supported by every bitmap-only color font. */
    hb_font_set_scale(f->font, (int)size * 64, (int)size * 64);
    hb_buffer_clear_contents(t->buffer);
    hb_buffer_set_cluster_level(t->buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
    hb_buffer_set_direction(t->buffer, run.level & 1 ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
    hb_buffer_set_script(t->buffer, run.script);
    hb_buffer_set_language(t->buffer, hb_language_from_string("und", -1));
    hb_buffer_set_flags(t->buffer,
                        (hb_buffer_flags_t)((run.start == line_start ? HB_BUFFER_FLAG_BOT : 0) |
                                            (run.end == line_end ? HB_BUFFER_FLAG_EOT : 0)));
    hb_buffer_add_utf32(t->buffer, t->chars + line_start, (int)(line_end - line_start),
                        run.start - line_start, (int)(run.end - run.start));
    hb_shape(f->font, t->buffer, NULL, 0);
    if (f->tables_failed)
        return error("shaping tables exceed the shared font budget");
    if (!hb_buffer_allocation_successful(t->buffer))
        return error("shaping allocation failed");
    *info = hb_buffer_get_glyph_infos(t->buffer, count);
    *positions = hb_buffer_get_glyph_positions(t->buffer, count);
    if (*count > POSITION_LIMIT)
        return error("shaped run exceeds glyph limit");
    for (unsigned i = 0; i < *count; ++i)
        if (!(*info)[i].codepoint && !ignorable(t->chars[line_start + (*info)[i].cluster]))
            return error("font shaping returned an unsupported glyph");
    return true;
}
static bool measure(SpicaText *t, unsigned start, unsigned end, unsigned size) {
    memset(t->advances + start, 0, (end - start) * sizeof(float));
    unsigned runs = make_runs(t, start, end);
    for (unsigned r = 0; r < runs; ++r) {
        Run run = t->runs[r];
        if (t->chars[run.start] == '\t') {
            t->advances[run.start] = size * 2.4f;
            continue;
        }
        unsigned count;
        hb_glyph_info_t *info;
        hb_glyph_position_t *pos;
        if (!shape(t, run, start, end, size, &count, &info, &pos))
            return false;
        for (unsigned g = 0; g < count; ++g)
            t->advances[start + info[g].cluster] += fabsf(pos[g].x_advance / 64.0f);
    }
    return true;
}
static int run_compare(const void *a, const void *b) {
    const Run *x = a, *y = b;
    return x->visual < y->visual ? -1 : x->visual > y->visual;
}
/* Builds visual glyph positions and grapheme carets for one final line. */
static bool line_shape(SpicaText *t, unsigned paragraph_start, unsigned start, unsigned end,
                       FriBidiParType base, unsigned size, unsigned line_index,
                       unsigned *glyph_count, unsigned *caret_count, float y) {
    for (unsigned i = start; i < end; ++i)
        t->visual[i] = (FriBidiStrIndex)i;
    if (end != start &&
        !fribidi_reorder_line(0, t->types + paragraph_start, (FriBidiStrIndex)(end - start),
                              (FriBidiStrIndex)(start - paragraph_start), base,
                              t->levels + paragraph_start, NULL, t->visual + paragraph_start))
        return error("bidi line ordering failed");
    unsigned runs = make_runs(t, start, end);
    for (unsigned i = start; i < end; ++i)
        t->visual_rank[t->visual[i]] = i;
    for (unsigned r = 0; r < runs; ++r) {
        t->runs[r].visual = end;
        for (unsigned i = t->runs[r].start; i < t->runs[r].end; ++i)
            if (t->visual_rank[i] < t->runs[r].visual)
                t->runs[r].visual = t->visual_rank[i];
    }
    qsort(t->runs, runs, sizeof(Run), run_compare);
    Line *line = &t->lines[line_index];
    *line = (Line){.info = {.byte_start = t->offsets[start],
                            .byte_end = t->offsets[end],
                            .y = y,
                            .height = size * 1.4f,
                            .baseline = size * 1.05f},
                   .first = *glyph_count};
    float x = 0;
    for (unsigned r = 0; r < runs; ++r) {
        Run run = t->runs[r];
        if (t->chars[run.start] == '\t') {
            float tab = size * 2.4f;
            float next = (floorf(x / tab) + 1) * tab;
            if (*caret_count + 2 > CARET_LIMIT)
                return error("caret limit exceeded");
            t->carets[(*caret_count)++] =
                (Caret){t->offsets[run.start], x, (uint16_t)line_index, true};
            t->carets[(*caret_count)++] =
                (Caret){t->offsets[run.end], next, (uint16_t)line_index, false};
            x = next;
            continue;
        }
        unsigned count;
        hb_glyph_info_t *info;
        hb_glyph_position_t *pos;
        if (!shape(t, run, start, end, size, &count, &info, &pos))
            return false;
        if (count > POSITION_LIMIT - *glyph_count)
            return error("layout glyph limit exceeded");
        for (unsigned g = 0; g < count;) {
            unsigned cluster = start + info[g].cluster;
            unsigned next = run.end;
            float begin = x;
            unsigned finish = g;
            while (finish < count && info[finish].cluster == info[g].cluster) {
                /* Monotone clusters let us recover the next logical cluster
                 * in linear time, even though RTL glyph order is reversed. */
                unsigned k = finish++;
                t->positions[(*glyph_count)++] =
                    (Position){.index = info[k].codepoint,
                               .face = (uint16_t)run.face,
                               .style = (uint16_t)run.style,
                               .x = x + pos[k].x_offset / 64.0f,
                               .y = -pos[k].y_offset / 64.0f,
                               .advance = fabsf(pos[k].x_advance / 64.0f),
                               .cluster = t->offsets[cluster]};
                x += fabsf(pos[k].x_advance / 64.0f);
            }
            if (run.level & 1) {
                if (g)
                    next = start + info[g - 1].cluster;
            } else if (finish < count)
                next = start + info[finish].cluster;
            unsigned graphemes = 1;
            for (unsigned c = cluster + 1; c < next; ++c)
                if (t->graphemes[c - 1] == GRAPHEMEBREAK_BREAK)
                    ++graphemes;
            unsigned part = 0;
            for (unsigned c = cluster; c <= next; ++c) {
                if (c != cluster && c != next && t->graphemes[c - 1] != GRAPHEMEBREAK_BREAK)
                    continue;
                if (*caret_count >= CARET_LIMIT)
                    return error("caret limit exceeded");
                float fraction = (float)part++ / graphemes;
                t->carets[(*caret_count)++] = (Caret){
                    t->offsets[c],
                    run.level & 1 ? x - (x - begin) * fraction : begin + (x - begin) * fraction,
                    (uint16_t)line_index, c != next};
            }
            g = finish;
        }
        hb_font_extents_t extents;
        if (!hb_font_get_h_extents(t->faces[run.face].font, &extents))
            return error("font has no horizontal line metrics");
        float ascent = extents.ascender / 64.0f;
        float descent = -extents.descender / 64.0f;
        if (ascent > line->info.baseline)
            line->info.baseline = ascent;
        if (ascent + descent + size * .15f > line->info.height)
            line->info.height = ascent + descent + size * .15f;
    }
    if (!runs) {
        if (*caret_count >= CARET_LIMIT)
            return error("caret limit exceeded");
        t->carets[(*caret_count)++] = (Caret){t->offsets[start], 0, (uint16_t)line_index, false};
    }
    line->count = *glyph_count - line->first;
    line->info.width = x;
    return true;
}
static bool hard_break(uint32_t c) { return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029; }

SpicaTextLayout *spica_text_layout_create_spans(SpicaText *t, const char *utf8, size_t length,
                                                float width, unsigned size, bool mono,
                                                const SpicaTextSpan *spans, size_t span_count) {
    if (!t || (!utf8 && length) || length > BYTE_LIMIT || !isfinite(width) || width <= 0 ||
        size < 8 || size > 64 || (!spans && span_count) || span_count > CHAR_LIMIT)
        return error("invalid layout parameters or visible byte limit exceeded"), NULL;
    unsigned n;
    if (!decode(t, utf8, length, &n))
        return NULL;
    set_graphemebreaks_utf32(t->chars, n, NULL, t->graphemes);
    set_linebreaks_utf32(t->chars, n, NULL, t->breaks);
    size_t previous = 0;
    for (size_t s = 0; s < span_count; ++s) {
        if (spans[s].byte_start < previous || spans[s].byte_end < spans[s].byte_start ||
            spans[s].byte_end > length || (spans[s].style & ~7u) ||
            !boundary(t, n, spans[s].byte_start) || !boundary(t, n, spans[s].byte_end))
            return error("style spans must be sorted, disjoint grapheme ranges"), NULL;
        previous = spans[s].byte_end;
    }
    size_t span = 0;
    hb_script_t last = HB_SCRIPT_LATIN;
    for (unsigned i = 0; i < n; ++i) {
        while (span < span_count && spans[span].byte_end <= t->offsets[i])
            ++span;
        t->styles[i] = (uint16_t)((mono ? SPICA_TEXT_MONOSPACE : 0) |
                                  (span < span_count && spans[span].byte_start <= t->offsets[i]
                                       ? spans[span].style
                                       : 0));
        hb_script_t script = hb_unicode_script(hb_unicode_funcs_get_default(), t->chars[i]);
        if (script == HB_SCRIPT_COMMON || script == HB_SCRIPT_INHERITED ||
            script == HB_SCRIPT_UNKNOWN)
            script = last;
        else
            last = script;
        t->scripts[i] = script;
    }
    /* Pin selected faces throughout scratch construction, so resolver eviction
     * cannot invalidate an earlier run. Transfer these pins to the layout. */
    uint16_t faces = 0;
    for (unsigned i = 0; i < n;) {
        unsigned end = i + 1;
        while (end < n && t->graphemes[end - 1] != GRAPHEMEBREAK_BREAK)
            ++end;
        int f = select_face(t, i, end, t->styles[i]);
        if (f < 0)
            goto fail;
        if (!(faces & (1u << f))) {
            faces |= (uint16_t)(1u << f);
            ++t->faces[f].pins;
        }
        for (unsigned c = i; c < end; ++c) {
            t->char_faces[c] = (uint16_t)f;
            t->styles[c] = (uint16_t)available_style(&t->faces[f], t->styles[c]);
        }
        i = end;
    }
    unsigned glyph_count = 0, caret_count = 0, line_count = 0, p = 0;
    float height = 0;
    do {
        unsigned end = p;
        while (end < n && !hard_break(t->chars[end]))
            ++end;
        FriBidiParType base;
        if (!paragraph(t, p, end, &base) || !measure(t, p, end, size))
            goto fail;
        unsigned start = p;
        do {
            unsigned stop = start, allowed = start;
            float used = 0;
            while (stop < end) {
                unsigned cluster_end = stop + 1;
                while (cluster_end < end && t->graphemes[cluster_end - 1] != GRAPHEMEBREAK_BREAK)
                    ++cluster_end;
                /* Never wrap inside a HarfBuzz ligature/cluster: its interior
                 * has no independent advance in paragraph measurement. */
                while (cluster_end < end && t->advances[cluster_end] == 0 &&
                       t->chars[cluster_end] != '\t' && !ignorable(t->chars[cluster_end]))
                    ++cluster_end;
                float advance = 0;
                for (unsigned c = stop; c < cluster_end; ++c)
                    advance += t->advances[c];
                if (used + advance > width && stop > start) {
                    if (allowed > start)
                        stop = allowed;
                    break;
                }
                used += advance;
                stop = cluster_end;
                if (t->breaks[stop - 1] == LINEBREAK_ALLOWBREAK ||
                    t->breaks[stop - 1] == LINEBREAK_MUSTBREAK)
                    allowed = stop;
            }
            unsigned before_glyphs = glyph_count, before_carets = caret_count;
            if (line_count >= CHAR_LIMIT + 1 ||
                !line_shape(t, p, start, stop, base, size, line_count, &glyph_count, &caret_count,
                            height))
                goto fail;
            /* Boundary shaping can change advance. Retry at an earlier legal
             * grapheme boundary rather than overflowing an otherwise-fit line. */
            while (t->lines[line_count].info.width > width && stop > start + 1) {
                unsigned smaller = stop - 1;
                while (smaller > start && t->graphemes[smaller - 1] != GRAPHEMEBREAK_BREAK)
                    --smaller;
                if (smaller == start)
                    break;
                stop = smaller;
                glyph_count = before_glyphs;
                caret_count = before_carets;
                if (!line_shape(t, p, start, stop, base, size, line_count, &glyph_count,
                                &caret_count, height))
                    goto fail;
            }
            height += t->lines[line_count++].info.height;
            start = stop;
        } while (start < end);
        if (end == n)
            break;
        p = end + 1;
        if (t->chars[end] == '\r' && p < n && t->chars[p] == '\n')
            ++p;
    } while (p <= n);
    size_t bytes = sizeof(SpicaTextLayout) + (size_t)line_count * sizeof(Line) +
                   (size_t)glyph_count * sizeof(Position) + (size_t)caret_count * sizeof(Caret);
    if (bytes > LAYOUT_BYTES - t->layout_bytes) {
        error("aggregate retained layout budget exhausted");
        goto fail;
    }
    SpicaTextLayout *layout = malloc(bytes);
    if (!layout) {
        error("retained layout allocation failed");
        goto fail;
    }
    *layout = (SpicaTextLayout){.owner = t,
                                .allocation = bytes,
                                .length = length,
                                .size = size,
                                .line_count = line_count,
                                .glyph_count = glyph_count,
                                .caret_count = caret_count,
                                .faces = faces,
                                .height = height};
    layout->lines = (Line *)(layout + 1);
    layout->positions = (Position *)(layout->lines + line_count);
    layout->carets = (Caret *)(layout->positions + glyph_count);
    memcpy(layout->lines, t->lines, line_count * sizeof(Line));
    memcpy(layout->positions, t->positions, glyph_count * sizeof(Position));
    memcpy(layout->carets, t->carets, caret_count * sizeof(Caret));
    t->layout_bytes += bytes;
    ++t->live_layouts;
    return layout;
fail:
    for (unsigned i = 0; i < FACE_LIMIT; ++i)
        if (faces & (1u << i))
            --t->faces[i].pins;
    return NULL;
}
SpicaTextLayout *spica_text_layout_create(SpicaText *t, const char *utf8, size_t length,
                                          float width, unsigned size, bool mono) {
    return spica_text_layout_create_spans(t, utf8, length, width, size, mono, NULL, 0);
}
SpicaTextLayout *spica_text_layout_create_styled(SpicaText *t, const char *utf8, size_t length,
                                                 float width, unsigned size, bool mono,
                                                 unsigned style) {
    SpicaTextSpan span = {0, length, style};
    return spica_text_layout_create_spans(t, utf8, length, width, size, mono, &span, 1);
}
void spica_text_layout_release(SpicaTextLayout *layout) {
    if (!layout)
        return;
    SpicaText *t = layout->owner;
    for (unsigned i = 0; i < FACE_LIMIT; ++i)
        if (layout->faces & (1u << i))
            --t->faces[i].pins;
    t->layout_bytes -= layout->allocation;
    --t->live_layouts;
    free(layout);
}
float spica_text_layout_height(const SpicaTextLayout *layout) {
    return layout ? layout->height : 0;
}
size_t spica_text_layout_line_count(const SpicaTextLayout *layout) {
    return layout ? layout->line_count : 0;
}
bool spica_text_layout_line(const SpicaTextLayout *layout, size_t index, SpicaTextLine *out) {
    if (!layout || !out || index >= layout->line_count)
        return false;
    *out = layout->lines[index].info;
    return true;
}
static Glyph *glyph(SpicaText *t, unsigned face, unsigned size, unsigned style, unsigned index,
                    unsigned phase) {
    style &= SPICA_TEXT_BOLD | SPICA_TEXT_ITALIC;
    Face *f = &t->faces[face];
    if (!FT_IS_SCALABLE(f->face))
        phase = 0;
    unsigned raster_x = (unsigned)fmaxf(1, roundf(size * t->render_scale_x * 64));
    unsigned raster_y = (unsigned)fmaxf(1, roundf(size * t->render_scale_y * 64));
    if (t->tombstones > 256)
        rebuild_glyph_slots(t);
    unsigned bucket = glyph_hash(face, raster_x, raster_y, style, index, phase);
    while (t->glyph_slots[bucket]) {
        unsigned id = t->glyph_slots[bucket];
        if (id != UINT16_MAX) {
            Glyph *g = &t->glyphs[id - 1];
            if (g->face == face && g->raster_x == raster_x && g->raster_y == raster_y &&
                g->style == style && g->index == index && g->phase == phase) {
                g->used = ++t->clock;
                return g;
            }
        }
        bucket = (bucket + 1) & 1023u;
    }
    Glyph *slot = NULL;
    for (unsigned i = 0; i < GLYPH_LIMIT; ++i)
        if (!t->glyphs[i].valid) {
            slot = &t->glyphs[i];
            break;
        }
    if (!activate(f, raster_x, raster_y, style))
        return NULL;
    FT_Vector offset = {(FT_Pos)phase * 16, 0};
    FT_Set_Transform(f->face, NULL, &offset);
    /* Vertical light hinting preserves the shaped horizontal advances. */
    if (FT_Load_Glyph(f->face, index, FT_LOAD_RENDER | FT_LOAD_COLOR | FT_LOAD_TARGET_LIGHT)) {
        error("glyph rasterization failed");
        return NULL;
    }
    FT_GlyphSlot ft = f->face->glyph;
    FT_Bitmap *b = &ft->bitmap;
    if (b->width > RASTER_SIDE || b->rows > RASTER_SIDE ||
        (b->pixel_mode != FT_PIXEL_MODE_GRAY && b->pixel_mode != FT_PIXEL_MODE_MONO &&
         b->pixel_mode != FT_PIXEL_MODE_BGRA && b->width && b->rows)) {
        error("unsupported glyph bitmap or raster cap exceeded");
        return NULL;
    }
    size_t bytes = (size_t)b->width * b->rows * 4;
    while (!slot || bytes > GLYPH_BYTES - t->glyph_bytes) {
        Glyph *oldest = NULL;
        for (unsigned i = 0; i < GLYPH_LIMIT; ++i)
            if (t->glyphs[i].valid && (!oldest || t->glyphs[i].used < oldest->used))
                oldest = &t->glyphs[i];
        if (!oldest) {
            error("glyph pixel budget exhausted");
            return NULL;
        }
        clear_glyph(t, oldest);
        if (!slot)
            slot = oldest;
    }
    SDL_Texture *texture = NULL;
    if (bytes) {
        for (unsigned y = 0; y < b->rows; ++y) {
            const unsigned char *row =
                b->buffer + (b->pitch >= 0 ? y : b->rows - 1 - y) * (size_t)abs(b->pitch);
            for (unsigned x = 0; x < b->width; ++x) {
                Uint8 red = 255, green = 255, blue = 255, alpha;
                if (b->pixel_mode == FT_PIXEL_MODE_BGRA) {
                    alpha = row[x * 4 + 3];
                    /* FreeType BGRA is premultiplied; SDL BLEND expects straight alpha. */
                    if (alpha) {
                        blue = (Uint8)((unsigned)row[x * 4] * 255 / alpha);
                        green = (Uint8)((unsigned)row[x * 4 + 1] * 255 / alpha);
                        red = (Uint8)((unsigned)row[x * 4 + 2] * 255 / alpha);
                    }
                } else if (b->pixel_mode == FT_PIXEL_MODE_GRAY)
                    alpha = b->num_grays > 1 ? (Uint8)((unsigned)row[x] * 255 / (b->num_grays - 1))
                                             : row[x];
                else
                    alpha = row[x / 8] & (0x80 >> (x % 8)) ? 255 : 0;
                t->pixels[(size_t)y * b->width + x] =
                    ((Uint32)red << 24) | ((Uint32)green << 16) | ((Uint32)blue << 8) | alpha;
            }
        }
        texture = SDL_CreateTexture(t->renderer, SDL_PIXELFORMAT_RGBA8888, SDL_TEXTUREACCESS_STATIC,
                                    (int)b->width, (int)b->rows);
        if (!texture)
            return NULL;
        if (!SDL_UpdateTexture(texture, NULL, t->pixels, (int)b->width * 4) ||
            !SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_BLEND) ||
            !SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_LINEAR)) {
            SDL_DestroyTexture(texture);
            return NULL;
        }
    }
    *slot = (Glyph){.index = index,
                    .face = (uint16_t)face,
                    .raster_x = (uint16_t)raster_x,
                    .raster_y = (uint16_t)raster_y,
                    .style = (uint16_t)style,
                    .phase = (uint16_t)phase,
                    .texture = texture,
                    .left = ft->bitmap_left,
                    .top = ft->bitmap_top,
                    .width = (int)b->width,
                    .height = (int)b->rows,
                    .bytes = bytes,
                    .used = ++t->clock,
                    .scale_x = f->raster_scale_x,
                    .scale_y = f->raster_scale_y,
                    .valid = true,
                    .colored = b->pixel_mode == FT_PIXEL_MODE_BGRA};
    bucket = glyph_hash(face, raster_x, raster_y, style, index, phase);
    while (t->glyph_slots[bucket] && t->glyph_slots[bucket] != UINT16_MAX)
        bucket = (bucket + 1) & 1023u;
    if (t->glyph_slots[bucket] == UINT16_MAX)
        --t->tombstones;
    slot->bucket = (uint16_t)bucket;
    t->glyph_slots[bucket] = (uint16_t)(slot - t->glyphs + 1);
    t->glyph_bytes += bytes;
    return slot;
}
typedef struct {
    int logical_w, logical_h;
    SDL_RendererLogicalPresentation presentation;
    float scale_x, scale_y;
    SDL_Rect viewport, clip;
    bool viewport_set, clipped;
} RasterView;

static bool restore_view(SDL_Renderer *renderer, const RasterView *view) {
    bool ok = view->presentation == SDL_LOGICAL_PRESENTATION_DISABLED ||
              SDL_SetRenderLogicalPresentation(renderer, view->logical_w, view->logical_h,
                                               view->presentation);
    if (!SDL_SetRenderScale(renderer, view->scale_x, view->scale_y))
        ok = false;
    if (!SDL_SetRenderViewport(renderer, view->viewport_set ? &view->viewport : NULL))
        ok = false;
    if (!SDL_SetRenderClipRect(renderer, view->clipped ? &view->clip : NULL))
        ok = false;
    return ok;
}

/* Raster glyphs are already device-sized. Blit in device coordinates so SDL's
 * software renderer cannot truncate a scaled bitmap's width or position. */
static bool device_view(SpicaText *t, RasterView *view) {
    SDL_Renderer *renderer = t->renderer;
    view->viewport_set = SDL_RenderViewportSet(renderer);
    view->clipped = SDL_RenderClipEnabled(renderer);
    if (!SDL_GetRenderLogicalPresentation(renderer, &view->logical_w, &view->logical_h,
                                          &view->presentation) ||
        !SDL_GetRenderScale(renderer, &view->scale_x, &view->scale_y) ||
        !SDL_GetRenderViewport(renderer, &view->viewport) ||
        (view->clipped && !SDL_GetRenderClipRect(renderer, &view->clip)))
        return false;
    SDL_FRect presentation = {0};
    if (view->presentation != SDL_LOGICAL_PRESENTATION_DISABLED) {
        if (!SDL_GetRenderLogicalPresentationRect(renderer, &presentation))
            return false;
    } else {
        int width, height;
        if (!SDL_GetCurrentRenderOutputSize(renderer, &width, &height))
            return false;
        presentation.w = (float)width;
        presentation.h = (float)height;
    }
    float sx = t->render_scale_x, sy = t->render_scale_y;
    SDL_Rect viewport = {
        (int)floorf(presentation.x + view->viewport.x * sx),
        (int)floorf(presentation.y + view->viewport.y * sy),
        view->viewport_set ? (int)ceilf(view->viewport.w * sx) : (int)ceilf(presentation.w),
        view->viewport_set ? (int)ceilf(view->viewport.h * sy) : (int)ceilf(presentation.h)};
    SDL_Rect clip = {0};
    if (view->clipped) {
        clip.x = (int)floorf(view->clip.x * sx);
        clip.y = (int)floorf(view->clip.y * sy);
        clip.w = (int)ceilf(view->clip.w * sx);
        clip.h = (int)ceilf(view->clip.h * sy);
    }
    if ((view->presentation != SDL_LOGICAL_PRESENTATION_DISABLED &&
         !SDL_SetRenderLogicalPresentation(renderer, 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED)) ||
        !SDL_SetRenderScale(renderer, 1, 1) || !SDL_SetRenderViewport(renderer, &viewport) ||
        !SDL_SetRenderClipRect(renderer, view->clipped ? &clip : NULL)) {
        restore_view(renderer, view);
        return false;
    }
    return true;
}

bool spica_text_layout_draw_colors(SpicaText *t, const SpicaTextLayout *layout, float x, float y,
                                   SDL_Color color, const SpicaTextColorSpan *spans,
                                   size_t span_count) {
    if (!t || !layout || layout->owner != t || !isfinite(x) || !isfinite(y) ||
        (!spans && span_count) || span_count > CHAR_LIMIT)
        return error("invalid layout draw");
    size_t previous = 0;
    for (size_t s = 0; s < span_count; ++s) {
        if (spans[s].byte_start < previous || spans[s].byte_end < spans[s].byte_start ||
            spans[s].byte_end > layout->length)
            return error("color spans must be sorted disjoint byte ranges");
        previous = spans[s].byte_end;
    }
    SDL_Rect clip;
    bool clipped = SDL_RenderClipEnabled(t->renderer);
    if (clipped && !SDL_GetRenderClipRect(t->renderer, &clip))
        return false;
    RasterView view;
    bool transformed = t->render_scale_x != 1 || t->render_scale_y != 1;
    if (transformed && !device_view(t, &view))
        return false;
    bool ok = true;
    for (unsigned l = 0; l < layout->line_count; ++l) {
        const Line *line = &layout->lines[l];
        if (clipped &&
            (y + line->info.y + line->info.height <= clip.y || y + line->info.y >= clip.y + clip.h))
            continue;
        for (unsigned i = line->first; i < line->first + line->count; ++i) {
            const Position *p = &layout->positions[i];
            /* Conservative ink bound avoids misses for combining/overhanging glyphs. */
            if (clipped && (x + p->x + layout->size * 4 < clip.x ||
                            x + p->x - layout->size * 4 > clip.x + clip.w))
                continue;
            float quarter = roundf((x + p->x) * t->render_scale_x * 4);
            float origin = floorf(quarter / 4);
            unsigned phase = (unsigned)(quarter - origin * 4);
            if (!FT_IS_SCALABLE(t->faces[p->face].face)) {
                origin = roundf((x + p->x) * t->render_scale_x);
                phase = 0;
            }
            Glyph *g = glyph(t, p->face, layout->size, p->style, p->index, phase);
            if (!g) {
                ok = false;
                goto finished;
            }
            if (!g->texture)
                continue;
            SDL_Color ink = color;
            size_t low = 0, high = span_count;
            while (low < high) {
                size_t middle = low + (high - low) / 2;
                if (spans[middle].byte_end <= p->cluster)
                    low = middle + 1;
                else
                    high = middle;
            }
            if (low < span_count && spans[low].byte_start <= p->cluster) {
                uint32_t rgba = spans[low].rgba;
                ink = (SDL_Color){(Uint8)(rgba >> 24), (Uint8)(rgba >> 16), (Uint8)(rgba >> 8),
                                  (Uint8)rgba};
            }
            if (!SDL_SetTextureColorMod(g->texture, g->colored ? 255 : ink.r,
                                        g->colored ? 255 : ink.g, g->colored ? 255 : ink.b) ||
                !SDL_SetTextureAlphaMod(g->texture, ink.a)) {
                ok = false;
                goto finished;
            }
            SDL_FRect dst = {
                origin + g->left * g->scale_x,
                roundf((y + line->info.y + line->info.baseline + p->y) * t->render_scale_y) -
                    g->top * g->scale_y,
                g->width * g->scale_x, g->height * g->scale_y};
            if (!SDL_RenderTexture(t->renderer, g->texture, NULL, &dst)) {
                ok = false;
                goto finished;
            }
        }
    }
finished:
    if (transformed && !restore_view(t->renderer, &view))
        ok = false;
    return ok;
}
bool spica_text_layout_draw(SpicaText *t, const SpicaTextLayout *layout, float x, float y,
                            SDL_Color color) {
    return spica_text_layout_draw_colors(t, layout, x, y, color, NULL, 0);
}
size_t spica_text_layout_hit_test(const SpicaTextLayout *layout, float x, float y) {
    if (!layout || !isfinite(x) || !isfinite(y))
        return 0;
    unsigned line = layout->line_count - 1;
    for (unsigned i = 0; i < layout->line_count; ++i)
        if (y < layout->lines[i].info.y + layout->lines[i].info.height) {
            line = i;
            break;
        }
    float distance = INFINITY;
    size_t byte = layout->lines[line].info.byte_start;
    for (unsigned i = 0; i < layout->caret_count; ++i) {
        const Caret *c = &layout->carets[i];
        if (c->line == line && fabsf(x - c->x) < distance) {
            distance = fabsf(x - c->x);
            byte = c->byte;
        }
    }
    return byte;
}
bool spica_text_layout_caret(const SpicaTextLayout *layout, size_t byte, SDL_FRect *out) {
    if (!layout || !out || byte > layout->length)
        return false;
    const Caret *best = NULL;
    for (unsigned i = 0; i < layout->caret_count; ++i) {
        const Caret *c = &layout->carets[i];
        if (c->byte <= byte && (!best || c->byte >= best->byte))
            best = c;
    }
    if (!best)
        return false;
    const SpicaTextLine *line = &layout->lines[best->line].info;
    *out = (SDL_FRect){best->x, line->y, 1, line->height};
    return true;
}
size_t spica_text_layout_selection_rects(const SpicaTextLayout *layout, size_t start_byte,
                                         size_t end_byte, SDL_FRect *out, size_t capacity) {
    if (!layout || start_byte >= end_byte || start_byte >= layout->length)
        return 0;
    if (end_byte > layout->length)
        end_byte = layout->length;
    size_t count = 0;
    SDL_FRect span = {0};
    bool pending = false;
    for (unsigned i = 0; i + 1 < layout->caret_count; ++i) {
        const Caret *a = &layout->carets[i], *b = &layout->carets[i + 1];
        /* Run/cluster endpoints can have two visual positions. Only original
         * grapheme edges connect them; never bridge an unrelated bidi run. */
        if (!a->joins_next || a->byte >= end_byte || b->byte <= start_byte)
            continue;
        float left = fminf(a->x, b->x), right = fmaxf(a->x, b->x);
        if (right <= left)
            continue;
        const SpicaTextLine *line = &layout->lines[a->line].info;
        if (pending && span.y == line->y && left <= span.x + span.w && right >= span.x) {
            float end = fmaxf(span.x + span.w, right);
            span.x = fminf(span.x, left);
            span.w = end - span.x;
            continue;
        }
        if (pending) {
            if (out && count < capacity)
                out[count] = span;
            ++count;
        }
        span = (SDL_FRect){left, line->y, right - left, line->height};
        pending = true;
    }
    if (pending) {
        if (out && count < capacity)
            out[count] = span;
        ++count;
    }
    return count;
}
bool spica_text_draw(SpicaText *t, const char *utf8, size_t length, float x, float baseline,
                     SDL_Color color) {
    if (!t || (!utf8 && length))
        return error("invalid label");
    if (length <= sizeof(t->labels[0].bytes)) {
        Label *slot = NULL;
        for (unsigned i = 0; i < 16; ++i) {
            Label *label = &t->labels[i];
            if (label->layout && label->length == length &&
                (!length || !memcmp(label->bytes, utf8, length))) {
                label->used = ++t->clock;
                return spica_text_layout_draw(
                    t, label->layout, x, baseline - label->layout->lines[0].info.baseline, color);
            }
            if (!slot || !label->layout || (slot->layout && label->used < slot->used))
                slot = label;
        }
        spica_text_layout_release(slot->layout);
        slot->layout = spica_text_layout_create(t, utf8, length, 1000000.0f, 15, false);
        if (!slot->layout)
            return false;
        slot->length = length;
        slot->used = ++t->clock;
        if (length)
            memcpy(slot->bytes, utf8, length);
        return spica_text_layout_draw(t, slot->layout, x,
                                      baseline - slot->layout->lines[0].info.baseline, color);
    }
    SpicaTextLayout *layout = spica_text_layout_create(t, utf8, length, 1000000.0f, 15, false);
    if (!layout)
        return false;
    bool ok =
        spica_text_layout_draw(t, layout, x, baseline - layout->lines[0].info.baseline, color);
    spica_text_layout_release(layout);
    return ok;
}
