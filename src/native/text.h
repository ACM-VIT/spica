#ifndef SPICA_TEXT_H
#define SPICA_TEXT_H
#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct SpicaText SpicaText;
SpicaText *spica_text_create(SDL_Renderer *renderer, const char *font_path);
void spica_text_destroy(SpicaText *text);
bool spica_text_draw(SpicaText *text, const char *utf8, size_t length, float x, float baseline,
                     SDL_Color color);
#endif
