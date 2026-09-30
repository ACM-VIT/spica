const std = @import("std");
const c = @import("../native/bindings.zig").c;
const storage = @import("../core/store.zig");
const content = @import("../content/worker.zig");
const DocumentView = @import("document.zig").View;
const theme = @import("theme.zig");

const Reasoning = struct {
    ready: content.Ready,
    view: DocumentView,
    fn deinit(self: *Reasoning) void {
        self.view.deinit();
        self.ready.deinit();
    }
};
const Loaded = struct {
    ready: content.Ready,
    view: DocumentView,
    texture: ?*c.SDL_Texture = null,
    image_width: f32 = 0,
    image_height: f32 = 0,
    reasoning: ?Reasoning = null,
    fn destroy(self: *Loaded, allocator: std.mem.Allocator) void {
        self.view.deinit();
        self.ready.deinit();
        if (self.reasoning) |*reasoning| reasoning.deinit();
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
        allocator.destroy(self);
    }
};
const Item = struct {
    entry: storage.ConversationEntry,
    top: f32 = 0,
    height: f32 = 100,
    expanded: bool = false,
    failed: bool = false,
    loaded: ?*Loaded = null,
};
pub const Disclosure = struct { ordinal: usize, bounds: c.SDL_FRect };

/// All message references, at most eight decoded documents, and only visible
/// native text shapes. Scrolling never changes the selected conversation.
pub const View = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    resident: [8]?usize = [_]?usize{null} ** 8,
    height: f32 = 0,
    viewport_scroll: f32 = 0,
    viewport_height: f32 = 0,
    wanted: ?usize = null,
    wanted_reasoning: bool = false,
    labels: [10]?*c.SpicaTextLayout = [_]?*c.SpicaTextLayout{null} ** 10,
    disclosures: [8]Disclosure = undefined,
    disclosure_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) View { return .{ .allocator = allocator }; }
    pub fn deinit(self: *View) void {
        self.clear();
        self.items.deinit(self.allocator);
        for (self.labels) |label_layout| if (label_layout) |layout| c.spica_text_layout_release(layout);
    }
    pub fn clear(self: *View) void {
        for (self.resident) |slot| if (slot) |index| self.items.items[index].loaded.?.destroy(self.allocator);
        self.items.clearRetainingCapacity();
        self.resident = [_]?usize{null} ** 8;
        self.height = 0;
        self.wanted = null;
    }
    pub fn invalidateLayouts(self: *View) void {
        for (self.resident) |slot| if (slot) |index| {
            const loaded = self.items.items[index].loaded.?;
            loaded.view.width = 0;
            if (loaded.reasoning) |*reasoning| reasoning.view.width = 0;
        };
    }
    fn reflow(self: *View) void {
        var top: f32 = 0;
        for (self.items.items) |*item| { item.top = top; top += item.height; }
        self.height = top;
    }
    pub fn update(self: *View, entries: []const storage.ConversationEntry) !void {
        if (self.items.items.len == entries.len) {
            var same_order = true;
            for (self.items.items, entries) |item, entry| if (item.entry.ordinal != entry.ordinal) { same_order = false; break; };
            if (same_order) {
                for (self.items.items, entries) |*item, entry| {
                    if (!std.meta.eql(item.entry.content_id, entry.content_id) or item.entry.length != entry.length) item.failed = false;
                    item.entry = entry;
                }
                self.wanted = null;
                return;
            }
        }
        var next: std.ArrayList(Item) = .empty;
        errdefer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, entries.len);
        var cursor: usize = 0;
        for (entries) |entry| {
            while (cursor < self.items.items.len and self.items.items[cursor].entry.ordinal < entry.ordinal) : (cursor += 1) {
                if (self.items.items[cursor].loaded) |loaded| loaded.destroy(self.allocator);
            }
            if (cursor < self.items.items.len and self.items.items[cursor].entry.ordinal == entry.ordinal) {
                var item = self.items.items[cursor];
                if (!std.meta.eql(item.entry.content_id, entry.content_id) or item.entry.length != entry.length) item.failed = false;
                item.entry = entry;
                next.appendAssumeCapacity(item);
                cursor += 1;
            } else next.appendAssumeCapacity(.{ .entry = entry, .height = @max(76, @as(f32, @floatFromInt(entry.length)) / 90 * 23 + 48) });
        }
        for (self.items.items[cursor..]) |item| if (item.loaded) |loaded| loaded.destroy(self.allocator);
        self.items.deinit(self.allocator);
        self.items = next;
        self.resident = [_]?usize{null} ** 8;
        var slot: usize = 0;
        for (self.items.items, 0..) |item, index| if (item.loaded != null) { self.resident[slot] = index; slot += 1; };
        self.reflow();
        self.wanted = null;
    }
    fn current(item: Item) bool {
        const loaded = item.loaded orelse return false;
        return std.meta.eql(loaded.ready.document.source_id, item.entry.content_id) and loaded.ready.document.source_length == item.entry.length;
    }
    fn currentReasoning(item: Item) bool {
        const loaded = item.loaded orelse return false;
        const reasoning = loaded.reasoning orelse return false;
        const reference = item.entry.reasoning orelse return false;
        return std.meta.eql(reasoning.ready.document.source_id, reference.content_ref) and reasoning.ready.document.source_length == reference.length;
    }
    pub fn request(self: *View, generation: u64) ?content.Request {
        const index = self.wanted orelse return null;
        const item = self.items.items[index];
        const ref = if (self.wanted_reasoning) item.entry.reasoning.? else storage.ReasoningReference{ .content_ref = item.entry.content_id, .length = item.entry.length };
        return .{ .generation = generation, .ordinal = item.entry.ordinal, .content_id = ref.content_ref, .published_length = ref.length, .role = switch (item.entry.role) { .user => .user, .assistant => .assistant, .tool => .tool, .bash => .bash, .system => .system } };
    }
    pub fn fail(self: *View, ordinal: usize) void {
        for (self.items.items) |*item| if (item.entry.ordinal == ordinal) { item.failed = true; return; };
    }
    pub fn accept(self: *View, renderer: *c.SDL_Renderer, ready: content.Ready) !void {
        var found: ?usize = null;
        for (self.items.items, 0..) |item, index| if (item.entry.ordinal == ready.ordinal) { found = index; break; };
        const index = found orelse { var discarded = ready; discarded.deinit(); return; };
        const item = &self.items.items[index];
        if (item.entry.reasoning) |reference| {
            if (std.meta.eql(reference.content_ref, ready.document.source_id) and reference.length == ready.document.source_length and item.loaded != null) {
                if (item.loaded.?.reasoning) |*old| old.deinit();
                item.loaded.?.reasoning = .{ .ready = ready, .view = DocumentView.init(self.allocator) };
                item.failed = false;
                return;
            }
        }
        if (!std.meta.eql(item.entry.content_id, ready.document.source_id) or item.entry.length != ready.document.source_length) { var discarded = ready; discarded.deinit(); return; }
        const loaded = self.allocator.create(Loaded) catch |err| { var discarded = ready; discarded.deinit(); return err; };
        loaded.* = .{ .ready = ready, .view = DocumentView.init(self.allocator) };
        errdefer loaded.destroy(self.allocator);
        if (ready.image.pixels != null) {
            const texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, ready.image.width, ready.image.height) orelse return error.ImageUpload;
            loaded.texture = texture;
            if (!c.SDL_UpdateTexture(texture, null, ready.image.pixels, ready.image.stride) or !c.SDL_SetTextureScaleMode(texture, c.SDL_SCALEMODE_LINEAR)) return error.ImageUpload;
            loaded.image_width = @floatFromInt(ready.image.width);
            loaded.image_height = @floatFromInt(ready.image.height);
            c.spica_image_release(&loaded.ready.image);
        }
        var free: ?usize = null;
        for (self.resident, 0..) |slot, i| if (slot == null or slot.? == index) { free = i; break; };
        if (free == null) {
            var farthest: f32 = -1;
            for (self.resident, 0..) |slot, i| {
                const distance = @abs(self.items.items[slot.?].top - self.viewport_scroll);
                if (distance > farthest) { farthest = distance; free = i; }
            }
            const evicted = &self.items.items[self.resident[free.?].?];
            evicted.loaded.?.destroy(self.allocator);
            evicted.loaded = null;
        }
        if (self.items.items[index].loaded) |old| old.destroy(self.allocator);
        self.items.items[index].loaded = loaded;
        self.items.items[index].failed = false;
        self.resident[free.?] = index;
    }
    pub fn toggle(self: *View, ordinal: usize) void {
        for (self.items.items) |*item| if (item.entry.ordinal == ordinal and item.entry.reasoning != null) {
            item.expanded = !item.expanded;
            item.failed = false;
            return;
        };
    }
    fn firstVisible(self: *const View, scroll: f32) usize {
        var low: usize = 0;
        var high = self.items.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const item = self.items.items[mid];
            if (item.top + item.height < scroll) low = mid + 1 else high = mid;
        }
        return low;
    }
    pub fn draw(self: *View, engine: *c.SpicaText, renderer: *c.SDL_Renderer, x: f32, y: f32, width: f32, viewport_height: f32, scroll: *f32, follow_bottom: bool, metrics: theme.Metrics, palette: theme.Palette, light: bool) !void {
        self.wanted = null;
        self.disclosure_count = 0;
        self.viewport_height = viewport_height;
        scroll.* = if (follow_bottom) @max(0, self.height - viewport_height) else @min(scroll.*, @max(0, self.height - viewport_height));
        for (self.resident) |slot| if (slot) |index| {
            const item = &self.items.items[index];
            if (item.top + item.height < scroll.* - 40 or item.top > scroll.* + viewport_height + 40) {
                item.loaded.?.view.releaseShapes();
                if (item.loaded.?.reasoning) |*reasoning| reasoning.view.releaseShapes();
            }
        };
        // Resolve estimated heights while preserving the reader's top message.
        const anchor = self.firstVisible(scroll.*);
        const offset = if (anchor < self.items.items.len) scroll.* - self.items.items[anchor].top else 0;
        for (0..10) |_| {
            var changed = false;
            var index = self.firstVisible(scroll.*);
            while (index < self.items.items.len and self.items.items[index].top <= scroll.* + viewport_height + 40) : (index += 1) {
                const item = &self.items.items[index];
                if (item.loaded) |loaded| {
                    if (loaded.ready.document.state == .rich) {
                        if (loaded.view.width != width) try loaded.view.rebuild(&loaded.ready.document, width);
                        try loaded.view.prepareRegion(engine, &loaded.ready.document, scroll.* - item.top - 30, viewport_height, metrics);
                        const image_height = if (loaded.texture != null) loaded.image_height * @min(1, width / loaded.image_width) + 20 else 0;
                        var reasoning_height: f32 = 0;
                        if (loaded.reasoning) |*reasoning| {
                            if (item.expanded and reasoning.ready.document.state == .rich) {
                                if (reasoning.view.width != width) try reasoning.view.rebuild(&reasoning.ready.document, width);
                                try reasoning.view.prepareRegion(engine, &reasoning.ready.document, scroll.* - item.top - 54 - loaded.view.height - image_height, viewport_height, metrics);
                                reasoning_height = reasoning.view.height + 24;
                            } else reasoning.view.releaseShapes();
                        }
                        const height = @max(76, loaded.view.height + image_height + reasoning_height + 48);
                        if (item.height != height) { item.height = height; changed = true; }
                    }
                }
            }
            if (!changed) break;
            self.reflow();
            scroll.* = if (follow_bottom) @max(0, self.height - viewport_height) else if (anchor < self.items.items.len) @max(0, self.items.items[anchor].top + offset) else 0;
        }
        self.viewport_scroll = scroll.*;
        var index = self.firstVisible(scroll.*);
        while (index < self.items.items.len and self.items.items[index].top <= scroll.* + viewport_height + 40) : (index += 1) {
            const item = &self.items.items[index];
            const top = y + item.top - scroll.*;
            const role_label: []const u8 = switch (item.entry.role) { .user => "You", .assistant => "Assistant", .tool => "Tool", .bash => "Bash", .system => "Retained record" };
            try self.label(engine, @intFromEnum(item.entry.role), role_label, x, top + 2, palette);
            if (item.entry.reasoning != null and self.disclosure_count < self.disclosures.len) {
                const disclosure: []const u8 = if (item.expanded) "Hide reasoning" else "Reasoning";
                try self.label(engine, if (item.expanded) 9 else 8, disclosure, x + width - 114, top + 2, palette);
                self.disclosures[self.disclosure_count] = .{ .ordinal = item.entry.ordinal, .bounds = .{ .x = x + width - 122, .y = top, .w = 122, .h = 26 } };
                self.disclosure_count += 1;
            }
            if (!item.failed and self.wanted == null) {
                if (!current(item.*)) {
                    self.wanted = index;
                    self.wanted_reasoning = false;
                } else if (item.expanded and !currentReasoning(item.*)) {
                    self.wanted = index;
                    self.wanted_reasoning = true;
                }
            }
            if (item.loaded) |loaded| {
                if (loaded.ready.document.state == .rich) {
                    try loaded.view.draw(engine, renderer, &loaded.ready.document, loaded.ready.highlights.items, x, top + 30, palette, light);
                    if (loaded.texture) |texture| {
                        const scale = @min(1, width / loaded.image_width);
                        const destination = c.SDL_FRect{ .x = x, .y = top + 30 + loaded.view.height + 12, .w = loaded.image_width * scale, .h = loaded.image_height * scale };
                        if (!c.SDL_RenderTexture(renderer, texture, null, &destination)) return error.ImageDraw;
                    }
                    if (item.expanded) {
                        const image_height = if (loaded.texture != null) loaded.image_height * @min(1, width / loaded.image_width) + 20 else 0;
                        if (loaded.reasoning) |*reasoning| {
                            try reasoning.view.draw(engine, renderer, &reasoning.ready.document, reasoning.ready.highlights.items, x, top + 54 + loaded.view.height + image_height, palette, light);
                        }
                    }
                } else try self.label(engine, 7, "Formatting unavailable; source retained", x, top + 34, palette);
            } else try self.label(engine, if (item.failed) 6 else 5, if (item.failed) "Unable to load message; source retained" else "Loading…", x, top + 34, palette);
        }
        if (self.height > viewport_height) {
            const thumb_height = @max(24, viewport_height * viewport_height / self.height);
            const thumb_y = y + (viewport_height - thumb_height) * scroll.* / @max(1, self.height - viewport_height);
            _ = c.SDL_SetRenderDrawColor(renderer, palette.border.r, palette.border.g, palette.border.b, 255);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = x + width - 3, .y = thumb_y, .w = 3, .h = thumb_height });
        }
    }
    fn label(self: *View, engine: *c.SpicaText, index: usize, text: []const u8, x: f32, y: f32, palette: theme.Palette) !void {
        if (self.labels[index] == null) self.labels[index] = c.spica_text_layout_create(engine, text.ptr, text.len, 384, 12, false) orelse return error.TextLayout;
        if (!c.spica_text_layout_draw(engine, self.labels[index].?, x, y, .{ .r = palette.muted.r, .g = palette.muted.g, .b = palette.muted.b, .a = 255 })) return error.TextDraw;
    }
};
