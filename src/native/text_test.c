/* Probe collection-name resolution without exposing the helper in the public API. */
#include "text.c"

int main(void) {
    SpicaText text = {0};
    if (FT_Init_FreeType(&text.library))
        return 1;
    CTFontRef font = CTFontCreateWithName(CFSTR("Menlo-Bold"), 15, NULL);
    CFURLRef url = font ? CTFontCopyAttribute(font, kCTFontURLAttribute) : NULL;
    CFStringRef postscript = font ? CTFontCopyPostScriptName(font) : NULL;
    char path[1024], name[256];
    int result = 2;
    if (url && postscript &&
        CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof(path)) &&
        CFStringGetCString(postscript, name, sizeof(name), kCFStringEncodingUTF8)) {
        long index = collection_index(&text, path, name);
        FT_Face face = NULL;
        if (index >= 0 && !FT_New_Face(text.library, path, index, &face)) {
            const char *selected = FT_Get_Postscript_Name(face);
            if (face->num_faces > 1 && selected && !strcmp(selected, name) &&
                collection_index(&text, path, "Spica-Nonexistent-Font-Face") == -1 &&
                collection_index(&text, "/Spica-Nonexistent-Font.ttc", name) == -1)
                result = 0;
            FT_Done_Face(face);
        }
    }
    if (postscript)
        CFRelease(postscript);
    if (url)
        CFRelease(url);
    if (font)
        CFRelease(font);
    FT_Done_FreeType(text.library);
    return result;
}
