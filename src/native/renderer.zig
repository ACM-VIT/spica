const builtin = @import("builtin");
const c = @import("bindings.zig").c;

/// Keep platform GPU selection explicit. The Vulkan candidate retained memory
/// across repeated Linux resizes despite a stable application text ledger;
/// retain the established OpenGL path until that growth is understood.
/// The caller owns destruction and reports SDL_GetError on failure.
pub fn createRenderer(window: *c.SDL_Window) error{RendererCreation}!*c.SDL_Renderer {
    const drivers: [*:0]const u8 = switch (builtin.os.tag) {
        .linux => "opengl",
        .macos => "metal",
        else => @compileError("The native foundation currently supports Linux and macOS"),
    };
    return c.SDL_CreateRenderer(window, drivers) orelse error.RendererCreation;
}
