const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    // On aarch64 clay.h includes arm_neon.h, which Zig's C translator cannot parse.
    // SIMD only affects clay.c's implementation, which is compiled separately and keeps it.
    if (builtin.cpu.arch == .aarch64) @cDefine("CLAY_DISABLE_SIMD", "1");
    @cInclude("clay.h");
    @cInclude("text.h");
    @cInclude("images.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("highlight.h");
    @cInclude("fuzzy.h");
});
