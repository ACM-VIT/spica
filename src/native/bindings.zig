pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("clay.h");
    @cInclude("text.h");
    @cInclude("images.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("highlight.h");
    @cInclude("fuzzy.h");
});
