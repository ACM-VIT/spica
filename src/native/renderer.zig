const builtin = @import("builtin");
const c = @import("bindings.zig").c;

/// Keep the native GPU texture path without eagerly loading the OpenGL driver
/// when Vulkan is available. SDL tries this ordered list until one succeeds;
/// OpenGL remains the GPU compatibility path, never the software renderer.
/// The caller owns destruction and reports SDL_GetError on failure.
pub fn createRenderer(window: *c.SDL_Window) error{RendererCreation}!*c.SDL_Renderer {
    const drivers: [*:0]const u8 = switch (builtin.os.tag) {
        .linux => "vulkan,opengl",
        .macos => "metal",
        else => @compileError("The native foundation currently supports Linux and macOS"),
    };
    return c.SDL_CreateRenderer(window, drivers) orelse error.RendererCreation;
}
