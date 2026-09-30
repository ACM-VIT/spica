#include "images.h"
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <limits.h>
#include <stdalign.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* SDL hooks apply to the entire process. Only allocations on the active
 * content-worker thread count toward its current job. The header lets a free
 * on another thread release a previously charged allocation safely. */
typedef union {
    struct { size_t size; bool charged; } record;
    max_align_t alignment;
} Allocation;
#if defined(_MSC_VER)
#define SPICA_THREAD_LOCAL __declspec(thread)
#else
#define SPICA_THREAD_LOCAL _Thread_local
#endif
static SPICA_THREAD_LOCAL bool active_job;
static atomic_size_t charged_live;
static atomic_size_t peak_live;
static atomic_bool hit_limit;
static bool hooks_installed;

static bool charge(size_t bytes) {
    size_t live = atomic_load(&charged_live);
    do {
        if (bytes > SPICA_IMAGE_JOB_LIMIT - live) {
            atomic_store(&hit_limit, true);
            return false;
        }
    } while (!atomic_compare_exchange_weak(&charged_live, &live, live + bytes));
    size_t peak = atomic_load(&peak_live);
    while (live + bytes > peak &&
           !atomic_compare_exchange_weak(&peak_live, &peak, live + bytes)) {}
    return true;
}

static void *SDLCALL image_malloc(size_t size) {
    if (size > SIZE_MAX - sizeof(Allocation)) {
        if (active_job) atomic_store(&hit_limit, true);
        return NULL;
    }
    size_t total = sizeof(Allocation) + size;
    bool charged = active_job;
    if (charged && !charge(total)) return NULL;
    Allocation *block = malloc(total);
    if (!block) {
        if (charged) atomic_fetch_sub(&charged_live, total);
        return NULL;
    }
    block->record.size = total;
    block->record.charged = charged;
    return block + 1;
}

static void *SDLCALL image_calloc(size_t count, size_t size) {
    if (size && count > SIZE_MAX / size) {
        if (active_job) atomic_store(&hit_limit, true);
        return NULL;
    }
    size_t bytes = count * size;
    void *ptr = image_malloc(bytes);
    if (ptr) memset(ptr, 0, bytes);
    return ptr;
}

static void SDLCALL image_free(void *ptr) {
    if (!ptr) return;
    Allocation *block = (Allocation *)ptr - 1;
    if (block->record.charged)
        atomic_fetch_sub(&charged_live, block->record.size);
    free(block);
}

static void *SDLCALL image_realloc(void *ptr, size_t size) {
    if (!ptr) return image_malloc(size);
    if (!size) { image_free(ptr); return NULL; }
    if (size > SIZE_MAX - sizeof(Allocation)) {
        if (active_job) atomic_store(&hit_limit, true);
        return NULL;
    }
    Allocation *old = (Allocation *)ptr - 1;
    size_t before = old->record.size;
    size_t after = sizeof(Allocation) + size;
    bool was_charged = old->record.charged;
    bool charged = was_charged || active_job;
    size_t extra = !was_charged && charged ? after : (charged && after > before ? after - before : 0);
    if (extra && !charge(extra)) return NULL;
    Allocation *replacement = realloc(old, after);
    if (!replacement) {
        if (extra) atomic_fetch_sub(&charged_live, extra);
        return NULL;
    }
    replacement->record.size = after;
    replacement->record.charged = charged;
    if (was_charged && after < before) atomic_fetch_sub(&charged_live, before - after);
    return replacement + 1;
}

bool spica_image_install_sdl_allocator(void) {
    if (hooks_installed) return true;
    SDL_malloc_func m, original_m;
    SDL_calloc_func c, original_c;
    SDL_realloc_func r, original_r;
    SDL_free_func f, original_f;
    SDL_GetOriginalMemoryFunctions(&original_m, &original_c, &original_r, &original_f);
    SDL_GetMemoryFunctions(&m, &c, &r, &f);
    if (m != original_m || c != original_c || r != original_r || f != original_f)
        return false;
    if (!SDL_SetMemoryFunctions(image_malloc, image_calloc, image_realloc, image_free))
        return false;
    hooks_installed = true;
    return true;
}

static uint32_t be16(const uint8_t *p) { return ((uint32_t)p[0] << 8) | p[1]; }
static uint32_t be32(const uint8_t *p) { return (be16(p) << 16) | be16(p + 2); }
static uint32_t le16(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
static uint32_t le24(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16); }

/* Return an advertised size without invoking any decoder allocation. The
 * decoder still validates the complete file; this is only a budget preflight. */
static SpicaImageStatus dimensions(const uint8_t *p, size_t n,
                                   int *width, int *height, const char **mime,
                                   const char **type) {
    uint32_t w = 0, h = 0;
    if (n >= 8 && !memcmp(p, "\x89PNG\r\n\x1a\n", 8)) {
        *mime = "image/png"; *type = "PNG";
        if (n < 24 || be32(p + 8) != 13 || memcmp(p + 12, "IHDR", 4)) return SPICA_IMAGE_CORRUPT;
        w = be32(p + 16); h = be32(p + 20);
    } else if (n >= 6 && (!memcmp(p, "GIF87a", 6) || !memcmp(p, "GIF89a", 6))) {
        *mime = "image/gif"; *type = "GIF";
        if (n < 10) return SPICA_IMAGE_CORRUPT;
        w = le16(p + 6); h = le16(p + 8);
    } else if (n >= 12 && !memcmp(p, "RIFF", 4) && !memcmp(p + 8, "WEBP", 4)) {
        *mime = "image/webp"; *type = "WEBP";
        if (n < 30) return SPICA_IMAGE_CORRUPT;
        if (!memcmp(p + 12, "VP8X", 4)) {
            w = le24(p + 24) + 1; h = le24(p + 27) + 1;
        } else if (!memcmp(p + 12, "VP8L", 4)) {
            if (n < 25 || p[20] != 0x2f) return SPICA_IMAGE_CORRUPT;
            w = 1 + (uint32_t)p[21] + (((uint32_t)p[22] & 0x3f) << 8);
            h = 1 + ((uint32_t)p[22] >> 6) + ((uint32_t)p[23] << 2) + (((uint32_t)p[24] & 0xf) << 10);
        } else if (!memcmp(p + 12, "VP8 ", 4)) {
            if (n < 30 || p[23] != 0x9d || p[24] != 0x01 || p[25] != 0x2a)
                return SPICA_IMAGE_CORRUPT;
            w = le16(p + 26) & 0x3fff; h = le16(p + 28) & 0x3fff;
        } else return SPICA_IMAGE_CORRUPT;
    } else if (n >= 2 && p[0] == 0xff && p[1] == 0xd8) {
        *mime = "image/jpeg"; *type = "JPG";
        size_t offset = 2;
        while (offset < n) {
            if (p[offset++] != 0xff) return SPICA_IMAGE_CORRUPT;
            while (offset < n && p[offset] == 0xff) ++offset;
            if (offset >= n) return SPICA_IMAGE_CORRUPT;
            uint8_t marker = p[offset++];
            if (marker == 0xd9 || marker == 0xda) return SPICA_IMAGE_CORRUPT;
            if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
            if (n - offset < 2) return SPICA_IMAGE_CORRUPT;
            size_t segment = be16(p + offset);
            if (segment < 2 || segment > n - offset) return SPICA_IMAGE_CORRUPT;
            if ((marker >= 0xc0 && marker <= 0xc3) ||
                (marker >= 0xc5 && marker <= 0xc7) ||
                (marker >= 0xc9 && marker <= 0xcb) ||
                (marker >= 0xcd && marker <= 0xcf)) {
                if (segment < 7) return SPICA_IMAGE_CORRUPT;
                h = be16(p + offset + 3); w = be16(p + offset + 5);
                break;
            }
            offset += segment;
        }
    } else return SPICA_IMAGE_UNSUPPORTED;
    if (!w || !h) return SPICA_IMAGE_CORRUPT;
    if (w > INT_MAX || h > INT_MAX || (uint64_t)w * h > SPICA_IMAGE_JOB_LIMIT / 4)
        return SPICA_IMAGE_BUDGET_EXCEEDED;
    *width = (int)w; *height = (int)h;
    return SPICA_IMAGE_OK;
}

SpicaImageStatus spica_image_decode(const uint8_t *source, size_t length,
                                    int max_width, int max_height,
                                    size_t thumbnail_limit,
                                    bool allow_untracked_codec,
                                    SpicaImageResult *out) {
    if (!out) return SPICA_IMAGE_INVALID_ARGUMENT;
    *out = (SpicaImageResult){0};
    if (!source || !length || max_width <= 0 || max_height <= 0 ||
        !thumbnail_limit || thumbnail_limit > SPICA_IMAGE_JOB_LIMIT)
        return SPICA_IMAGE_INVALID_ARGUMENT;
    if (!hooks_installed) return SPICA_IMAGE_SDL_ALLOCATOR_UNAVAILABLE;
    int width = 0, height = 0;
    const char *mime = NULL, *type = NULL;
    SpicaImageStatus status = dimensions(source, length, &width, &height, &mime, &type);
    if (status != SPICA_IMAGE_OK) return status;
    out->source_width = width; out->source_height = height;
    out->mime_type = mime;
    out->codec_allocations_untracked = strcmp(type, "GIF") != 0;
    if (out->codec_allocations_untracked && !allow_untracked_codec)
        return SPICA_IMAGE_CODEC_ALLOCATIONS_UNTRACKED;
    if (atomic_load(&charged_live)) return SPICA_IMAGE_SDL_ALLOCATOR_UNAVAILABLE;

    /* Aspect-preserving, integer-only, downscale-or-original fit. */
    int target_width = width, target_height = height;
    if (width > max_width || height > max_height) {
        if ((uint64_t)width * max_height > (uint64_t)height * max_width) {
            target_width = max_width;
            target_height = (int)((uint64_t)height * max_width / width);
        } else {
            target_height = max_height;
            target_width = (int)((uint64_t)width * max_height / height);
        }
        if (!target_width) target_width = 1;
        if (!target_height) target_height = 1;
    }
    if ((uint64_t)target_width * target_height > thumbnail_limit / 4)
        return SPICA_IMAGE_BUDGET_EXCEEDED;
    size_t bytes = (size_t)target_width * target_height * 4;
    /* SDL_IOFromConstMem takes size_t, but decoder paths may cast lengths
     * or seek through signed offsets. Reject inputs outside int range. */
    if (length > INT_MAX) return SPICA_IMAGE_BUDGET_EXCEEDED;

    SDL_IOStream *io = NULL;
    SDL_Surface *surface = NULL, *destination = NULL;
    uint8_t *pixels = NULL;
    atomic_store(&hit_limit, false);
    atomic_store(&peak_live, 0);
    active_job = true;
    io = SDL_IOFromConstMem(source, length);
    if (!io) goto failure;
    surface = IMG_LoadTyped_IO(io, false, type);
    if (!surface) goto failure;
    if (surface->w != width || surface->h != height || !surface->pixels || surface->pitch <= 0) {
        status = SPICA_IMAGE_CORRUPT;
        goto cleanup;
    }
    /* Pixel allocation is manually charged alongside SDL allocations; output
     * is detached from the job before handoff and freed by release(). */
    if (!charge(bytes)) goto failure;
    pixels = malloc(bytes);
    if (!pixels) {
        atomic_fetch_sub(&charged_live, bytes);
        status = SPICA_IMAGE_OUT_OF_MEMORY;
        goto cleanup;
    }
    memset(pixels, 0, bytes);
    destination = SDL_CreateSurfaceFrom(target_width, target_height,
                                         SDL_PIXELFORMAT_RGBA32, pixels, target_width * 4);
    if (!destination) goto failure;
    if (!SDL_SetSurfaceBlendMode(surface, SDL_BLENDMODE_NONE) ||
        !SDL_BlitSurfaceScaled(surface, NULL, destination, NULL, SDL_SCALEMODE_LINEAR)) goto failure;
    SDL_DestroySurface(destination); destination = NULL;
    SDL_DestroySurface(surface); surface = NULL;
    SDL_CloseIO(io); io = NULL;
    atomic_fetch_sub(&charged_live, bytes);
    active_job = false;
    if (atomic_load(&charged_live)) {
        free(pixels);
        return SPICA_IMAGE_SDL_ALLOCATOR_UNAVAILABLE;
    }
    out->pixels = pixels;
    out->byte_length = bytes;
    out->width = target_width; out->height = target_height;
    out->stride = target_width * 4;
    out->peak_tracked_bytes = atomic_load(&peak_live);
    return SPICA_IMAGE_OK;

failure:
    status = atomic_load(&hit_limit) ? SPICA_IMAGE_BUDGET_EXCEEDED : SPICA_IMAGE_DECODER_ERROR;
cleanup:
    if (destination) SDL_DestroySurface(destination);
    if (surface) SDL_DestroySurface(surface);
    if (io) SDL_CloseIO(io);
    if (pixels) { free(pixels); atomic_fetch_sub(&charged_live, bytes); }
    active_job = false;
    return status;
}

void spica_image_release(SpicaImageResult *result) {
    if (!result) return;
    free(result->pixels);
    *result = (SpicaImageResult){0};
}
