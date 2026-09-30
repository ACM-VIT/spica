#ifndef SPICA_IMAGES_H
#define SPICA_IMAGES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SPICA_IMAGE_JOB_LIMIT (48u * 1024u * 1024u)

typedef enum {
    SPICA_IMAGE_OK = 0,
    SPICA_IMAGE_INVALID_ARGUMENT,
    SPICA_IMAGE_UNSUPPORTED,
    SPICA_IMAGE_CORRUPT,
    SPICA_IMAGE_BUDGET_EXCEEDED,
    SPICA_IMAGE_OUT_OF_MEMORY,
    SPICA_IMAGE_SDL_ALLOCATOR_UNAVAILABLE,
    SPICA_IMAGE_CODEC_ALLOCATIONS_UNTRACKED,
    SPICA_IMAGE_DECODER_ERROR
} SpicaImageStatus;

typedef struct {
    /* The caller owns source bytes throughout this call; failure never alters them. */
    uint8_t *pixels;             /* RGBA32 (native byte order), tightly packed. */
    size_t byte_length;
    int width, height, stride;
    int source_width, source_height;
    const char *mime_type;       /* Static string; no allocation or release. */
    size_t peak_tracked_bytes;   /* SDL + result allocations, NOT codec-private heaps. */
    bool codec_allocations_untracked;
} SpicaImageResult;

/* MUST be called before any other SDL call/SDL allocation, on application
 * startup, not from the content worker after SDL_Init. A preexisting SDL
 * allocation cannot be detected and would make replacing its allocator unsafe.
 * Install once; do not subsequently replace SDL's memory functions. */
bool spica_image_install_sdl_allocator(void);

/* Decode PNG, JPEG, GIF (first frame), or WebP from caller-owned bytes. Both
 * dimensions must be positive. No upscaling. thumbnail_limit caps transferable
 * pixels (e.g. 2 MiB). The pinned GIF decoder uses SDL allocations, so it
 * can run in strict mode. PNG/libpng+zlib, JPEG/libjpeg and WebP/libwebp have
 * private allocator paths not controllable through SDL_SetMemoryFunctions:
 * strict mode (allow_untracked_codec=false) refuses them with
 * CODEC_ALLOCATIONS_UNTRACKED. Opt-in bounds only SDL allocations and result
 * to 48 MiB; it CANNOT guarantee the inclusive 48 MiB transient cap.
 * Build-time codec allocator plumbing is required for that claim.
 * Calls are serialized on the content worker; no other SDL allocations may
 * be made on that thread while this call is active. A successful result owns
 * only its display-sized pixels, never the full decoded surface. */
SpicaImageStatus spica_image_decode(const uint8_t *source, size_t length,
                                    int max_width, int max_height,
                                    size_t thumbnail_limit,
                                    bool allow_untracked_codec,
                                    SpicaImageResult *out);
void spica_image_release(SpicaImageResult *result);

#endif
