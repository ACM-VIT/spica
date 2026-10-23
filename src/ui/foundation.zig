const c = @import("../native/bindings.zig").c;
const Layout = @import("clay.zig").Layout;
const LabelCache = @import("label_cache.zig").LabelCache;
const widgets = @import("widgets.zig");
const Color = @import("color.zig").Color;

/// Honest placeholder view. It exposes no simulated workspace controls.
pub const View = struct {
    labels: LabelCache = .{},

    pub fn deinit(self: *View) void {
        self.labels.deinit();
    }

    pub fn draw(self: *View, renderer: *c.SDL_Renderer, text: *c.SpicaText, bounds: Layout.Foundation) !void {
        const foreground = Color{ .r = 231, .g = 235, .b = 242 };
        const muted = Color{ .r = 157, .g = 168, .b = 186 };
        const accent = Color{ .r = 164, .g = 185, .b = 255 };
        if (!c.SDL_SetRenderDrawColor(renderer, 19, 22, 28, 255) or !c.SDL_RenderClear(renderer)) return error.CanvasDraw;
        const header = bounds.header;
        try self.labels.draw(text, "SPICA", header.x + 32, header.y + 26, 18, foreground);
        try self.labels.draw(text, "NATIVE FOUNDATION", header.x + 114, header.y + 29, 12, muted);
        const card = bounds.card;
        try widgets.panel(renderer, .{ .x = card.x, .y = card.y, .w = card.width, .h = card.height }, 14, .{ .r = 27, .g = 32, .b = 41 });
        const x = card.x + 32;
        const y = card.y + 32;
        try self.labels.draw(text, "REWRITE STARTER", x, y, 12, accent);
        try self.labels.draw(text, "A new workspace starts here.", x, y + 34, 28, foreground);
        try self.labels.draw(text, "Zig + SDL3 + Clay", x, y + 87, 16, foreground);
        try self.labels.draw(text, "Native GPU rendering and the portable Unicode text stack.", x, y + 118, 15, muted);
        try self.labels.draw(text, "Agent workspace features are still to come.", x, y + 147, 15, muted);
        try self.labels.draw(text, "Unicode  /  café · Ελληνικά · مرحبا", x, y + 203, 16, foreground);
        const footer = bounds.footer;
        try self.labels.drawFitted(renderer, text, "Foundation only  ·  Escape to close", footer.x + 32, footer.y + 20, footer.width - 64, 13, muted);
    }
};
