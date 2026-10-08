/* Cocoa screenshot clipboards commonly expose TIFF. Normalize that representation
 * on the content worker; Pi and the bounded native preview decoder accept PNG. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <SDL3/SDL.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

uint8_t *spica_clipboard_tiff_png(const uint8_t *bytes, size_t size, size_t *length) {
    const size_t byte_limit = 4u * 1024u * 1024u;
    *length = 0;
    if (!bytes || !size || size > 32u * 1024u * 1024u)
        return NULL;
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, bytes, (CFIndex)size, kCFAllocatorNull);
    if (!data)
        return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    CFRelease(data);
    if (!source)
        return NULL;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    int64_t width = 0, height = 0;
    if (properties) {
        CFTypeRef w = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
        CFTypeRef h = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
        if (w && h && CFGetTypeID(w) == CFNumberGetTypeID() &&
            CFGetTypeID(h) == CFNumberGetTypeID()) {
            CFNumberGetValue(w, kCFNumberSInt64Type, &width);
            CFNumberGetValue(h, kCFNumberSInt64Type, &height);
        }
        CFRelease(properties);
    }
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
        width > (int64_t)(8u * 1024u * 1024u) / height) {
        CFRelease(source);
        return NULL;
    }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image)
        return NULL;
    CFMutableDataRef png = CFDataCreateMutable(NULL, 0);
    CGImageDestinationRef destination =
        png ? CGImageDestinationCreateWithData(png, CFSTR("public.png"), 1, NULL) : NULL;
    uint8_t *result = NULL;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        if (CGImageDestinationFinalize(destination)) {
            CFIndex count = CFDataGetLength(png);
            if (count > 0 && (size_t)count <= byte_limit) {
                result = SDL_malloc((size_t)count);
                if (result) {
                    memcpy(result, CFDataGetBytePtr(png), (size_t)count);
                    *length = (size_t)count;
                }
            }
        }
        CFRelease(destination);
    }
    if (png)
        CFRelease(png);
    CGImageRelease(image);
    return result;
}
