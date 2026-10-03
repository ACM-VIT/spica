const std = @import("std");
const c = @import("../native/bindings.zig").c;
const storage = @import("../core/store.zig");
const content = @import("../content/worker.zig");
const DocumentView = @import("document.zig").View;
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const resident_slots = 256;
const decoded_cache_bytes = 16 * 1024 * 1024;
const body_padding: f32 = 16;
const item_gap: f32 = 16;
const footer_gap: f32 = 8;
const footer_height: f32 = 22;
const scrollbar_gutter: f32 = 12;

fn arrayBytes(array: anytype) usize {
    return array.capacity * @sizeOf(@TypeOf(array.items[0]));
}
fn readyBytes(ready: *const content.Ready) usize {
    return @sizeOf(content.Ready) + arrayBytes(&ready.document.blocks) + arrayBytes(&ready.document.runs) +
        arrayBytes(&ready.document.text) + arrayBytes(&ready.document.metadata) + arrayBytes(&ready.highlights);
}
fn viewBytes(view: *const DocumentView) usize {
    return arrayBytes(&view.boxes) + arrayBytes(&view.color_scratch);
}

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
    image_bytes: usize = 0,
    reasoning: ?Reasoning = null,
    fn retainedBytes(self: *const Loaded) usize {
        var bytes = @sizeOf(Loaded) + readyBytes(&self.ready) + viewBytes(&self.view) + self.image_bytes;
        if (self.reasoning) |*reasoning| bytes += readyBytes(&reasoning.ready) + viewBytes(&reasoning.view);
        return bytes;
    }
    fn destroy(self: *Loaded, allocator: std.mem.Allocator) void {
        self.view.deinit();
        self.ready.deinit();
        if (self.reasoning) |*reasoning| reasoning.deinit();
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
        allocator.destroy(self);
    }
};
const ActivityKind = enum { read, change, command, other };
const Item = struct {
    entry: storage.ConversationEntry,
    top: f32 = 0,
    height: f32 = 100,
    body_height: f32 = 40,
    reasoning_height: f32 = 0,
    expanded: bool = false,
    output_expanded: bool = false,
    activity_expanded: bool = false,
    activity_owner: ?usize = null,
    activity_end: usize = 0,
    failures: usize = 0,
    running: ?usize = null,
    activity_kind: ActivityKind = .other,
    failed: bool = false,
    loaded: ?*Loaded = null,
};
pub const Toggle = struct { ordinal: usize, kind: enum { reasoning, activity, output } };
pub const Disclosure = struct { toggle: Toggle, bounds: c.SDL_FRect };
const Caption = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    size: c_uint = 0,
    layout: ?*c.SpicaTextLayout = null,
    used: u64 = 0,
};

/// Compact references plus a byte-bounded decoded cache; only visible native
/// text shapes. Dense short messages do not compete for eight fixed slots.
pub const View = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    resident: [resident_slots]?usize = [_]?usize{null} ** resident_slots,
    height: f32 = 0,
    viewport_scroll: f32 = 0,
    viewport_height: f32 = 0,
    wanted: ?usize = null,
    wanted_reasoning: bool = false,
    captions: [48]Caption = [_]Caption{.{}} ** 48,
    caption_clock: u64 = 0,
    disclosures: [32]Disclosure = undefined,
    disclosure_count: usize = 0,
    draw_top: f32 = 0,

    pub fn init(allocator: std.mem.Allocator) View {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *View) void {
        self.clear();
        self.items.deinit(self.allocator);
        for (&self.captions) |*cached| if (cached.layout) |layout| c.spica_text_layout_release(layout);
    }
    pub fn clear(self: *View) void {
        for (self.resident) |slot| if (slot) |index| self.items.items[index].loaded.?.destroy(self.allocator);
        self.items.clearRetainingCapacity();
        self.resident = [_]?usize{null} ** resident_slots;
        self.height = 0;
        self.wanted = null;
        self.wanted_reasoning = false;
    }
    pub fn invalidateLayouts(self: *View) void {
        for (self.resident) |slot| if (slot) |index| {
            const loaded = self.items.items[index].loaded.?;
            loaded.view.width = 0;
            if (loaded.reasoning) |*reasoning| reasoning.view.width = 0;
        };
    }
    fn isTool(item: *const Item) bool {
        return item.entry.role == .tool or item.entry.role == .bash;
    }
    fn bodyVisible(self: *const View, index: usize) bool {
        const item = &self.items.items[index];
        if (!isTool(item)) return item.entry.length != 0;
        const owner = item.activity_owner.?;
        return item.entry.length != 0 and (owner == index or self.items.items[owner].activity_expanded) and
            (self.items.items[owner].activity_end == owner + 1 or self.items.items[owner].activity_expanded) and item.output_expanded;
    }
    fn activityKind(item: *const Item) ActivityKind {
        const activity = item.entry.activity[0..item.entry.activity_len];
        if (std.mem.startsWith(u8, activity, "read ")) return .read;
        if (std.mem.startsWith(u8, activity, "edit ") or std.mem.startsWith(u8, activity, "write ")) return .change;
        if (std.mem.startsWith(u8, activity, "bash ") or item.entry.role == .bash) return .command;
        return .other;
    }
    fn regroup(self: *View) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            const first = &self.items.items[index];
            first.activity_owner = null;
            if (!isTool(first)) {
                index += 1;
                continue;
            }
            var end = index;
            var failures: usize = 0;
            var running: ?usize = null;
            var kind = activityKind(first);
            while (end < self.items.items.len and isTool(&self.items.items[end])) : (end += 1) {
                self.items.items[end].activity_owner = index;
                if (self.items.items[end].entry.status == .failed) failures += 1;
                if (self.items.items[end].entry.status == .running) running = end;
                if (activityKind(&self.items.items[end]) != kind) kind = .other;
            }
            first.activity_end = end;
            first.failures = failures;
            first.running = running;
            first.activity_kind = kind;
            index = end;
        }
        self.reflow();
    }
    fn reflow(self: *View) void {
        var top: f32 = 0;
        for (self.items.items, 0..) |*item, index| {
            if (item.activity_owner) |owner| {
                const group = &self.items.items[owner];
                const grouped = group.activity_end > owner + 1;
                const shown = index == owner or group.activity_expanded;
                const header: f32 = if (grouped and index == owner) 36 else 0;
                item.height = if (!shown) 0 else if (grouped and !group.activity_expanded) header + 8 else header + 36 +
                    (if (self.bodyVisible(index)) item.body_height + 16 else @as(f32, 0));
            } else {
                const thought_height: f32 = if (item.entry.reasoning != null) 36 + (if (item.expanded) item.reasoning_height else @as(f32, 0)) else 0;
                item.height = if (item.entry.length == 0) thought_height else self.bodyTop(index) + item.body_height +
                    (if (hasTimestamp(item)) footer_gap + footer_height else @as(f32, 0)) + body_padding + item_gap;
            }
            item.top = top;
            top += item.height;
        }
        self.height = top;
    }
    fn updateEntry(item: *Item, entry: storage.ConversationEntry) void {
        if (!std.meta.eql(item.entry.content_id, entry.content_id) or item.entry.length != entry.length or
            !std.meta.eql(item.entry.reasoning, entry.reasoning)) item.failed = false;
        item.entry = entry;
        if (entry.reasoning == null) {
            item.expanded = false;
            item.reasoning_height = 0;
            if (item.loaded) |loaded| {
                if (loaded.reasoning) |*reasoning| reasoning.deinit();
                loaded.reasoning = null;
            }
        }
    }
    pub fn update(self: *View, entries: []const storage.ConversationEntry) !void {
        if (self.items.items.len == entries.len) {
            var same_order = true;
            for (self.items.items, entries) |item, entry| if (item.entry.ordinal != entry.ordinal) {
                same_order = false;
                break;
            };
            if (same_order) {
                for (self.items.items, entries) |*item, entry| updateEntry(item, entry);
                self.regroup();
                self.wanted = null;
                self.wanted_reasoning = false;
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
                updateEntry(&item, entry);
                next.appendAssumeCapacity(item);
                cursor += 1;
            } else next.appendAssumeCapacity(.{ .entry = entry, .body_height = @max(32, @as(f32, @floatFromInt(entry.length)) / 90 * 23) });
        }
        for (self.items.items[cursor..]) |item| if (item.loaded) |loaded| loaded.destroy(self.allocator);
        self.items.deinit(self.allocator);
        self.items = next;
        self.resident = [_]?usize{null} ** resident_slots;
        var slot: usize = 0;
        for (self.items.items, 0..) |item, index| if (item.loaded != null) {
            self.resident[slot] = index;
            slot += 1;
        };
        self.regroup();
        self.wanted = null;
        self.wanted_reasoning = false;
    }
    fn current(item: *const Item) bool {
        const loaded = item.loaded orelse return false;
        return std.meta.eql(loaded.ready.document.source_id, item.entry.content_id) and loaded.ready.document.source_length == item.entry.length;
    }
    fn currentReasoning(item: *const Item) bool {
        const loaded = item.loaded orelse return false;
        const reasoning = loaded.reasoning orelse return false;
        const reference = item.entry.reasoning orelse return false;
        return std.meta.eql(reasoning.ready.document.source_id, reference.content_ref) and reasoning.ready.document.source_length == reference.length;
    }
    pub fn request(self: *View, generation: u64) ?content.Request {
        const index = self.wanted orelse return null;
        const item = &self.items.items[index];
        const ref = if (self.wanted_reasoning)
            item.entry.reasoning orelse return null
        else
            storage.ReasoningReference{ .content_ref = item.entry.content_id, .length = item.entry.length };
        return .{ .generation = generation, .ordinal = item.entry.ordinal, .content_id = ref.content_ref, .published_length = ref.length, .role = switch (item.entry.role) {
            .user => .user,
            .assistant => .assistant,
            .tool => .tool,
            .bash => .bash,
            .system => .system,
        } };
    }
    pub fn fail(self: *View, ordinal: usize) void {
        for (self.items.items) |*item| if (item.entry.ordinal == ordinal) {
            item.failed = true;
            return;
        };
    }
    fn cacheBytes(self: *const View) usize {
        var bytes: usize = 0;
        for (self.resident) |slot| if (slot) |index| {
            bytes += self.items.items[index].loaded.?.retainedBytes();
        };
        return bytes;
    }
    fn evict(self: *View, slot: usize) void {
        const item = &self.items.items[self.resident[slot].?];
        item.loaded.?.destroy(self.allocator);
        item.loaded = null;
        self.resident[slot] = null;
    }
    fn evictionSlot(self: *const View, protected: ?usize) ?usize {
        var farthest: f32 = -1;
        var selected: ?usize = null;
        for (self.resident, 0..) |slot, i| {
            const index = slot orelse continue;
            if (protected != null and index == protected.?) continue;
            const item = &self.items.items[index];
            const offscreen = item.height == 0 or item.top + item.height < self.viewport_scroll or item.top > self.viewport_scroll + self.viewport_height;
            const distance = @abs(item.top - self.viewport_scroll - self.viewport_height / 2) + (if (offscreen) @as(f32, 1000000000) else 0);
            if (distance > farthest) {
                farthest = distance;
                selected = i;
            }
        }
        return selected;
    }
    fn makeRoom(self: *View, incoming: usize, protected: ?usize) !void {
        if (incoming > decoded_cache_bytes) return error.DecodedDocumentBudget;
        var bytes = self.cacheBytes();
        while (bytes + incoming > decoded_cache_bytes) {
            const slot = self.evictionSlot(protected) orelse return error.DecodedDocumentBudget;
            bytes -= self.items.items[self.resident[slot].?].loaded.?.retainedBytes();
            self.evict(slot);
        }
    }
    pub fn accept(self: *View, renderer: *c.SDL_Renderer, ready: content.Ready) !void {
        var found: ?usize = null;
        for (self.items.items, 0..) |item, index| if (item.entry.ordinal == ready.ordinal) {
            found = index;
            break;
        };
        const index = found orelse {
            var discarded = ready;
            discarded.deinit();
            return;
        };
        const item = &self.items.items[index];
        if (item.entry.reasoning) |reference| {
            if (std.meta.eql(reference.content_ref, ready.document.source_id) and reference.length == ready.document.source_length and item.loaded != null) {
                if (item.loaded.?.reasoning) |*old| old.deinit();
                item.loaded.?.reasoning = null;
                self.makeRoom(readyBytes(&ready), index) catch |err| {
                    var discarded = ready;
                    discarded.deinit();
                    item.failed = true;
                    return err;
                };
                item.loaded.?.reasoning = .{ .ready = ready, .view = DocumentView.init(self.allocator) };
                item.failed = false;
                return;
            }
        }
        if (!std.meta.eql(item.entry.content_id, ready.document.source_id) or item.entry.length != ready.document.source_length) {
            var discarded = ready;
            discarded.deinit();
            return;
        }
        if (self.items.items[index].loaded) |old| {
            old.destroy(self.allocator);
            self.items.items[index].loaded = null;
            for (&self.resident) |*slot| if (slot.* != null and slot.*.? == index) {
                slot.* = null;
                break;
            };
        }
        const image_bytes = if (ready.image.pixels != null) @as(usize, @intCast(ready.image.width)) * @as(usize, @intCast(ready.image.height)) * 4 else 0;
        self.makeRoom(readyBytes(&ready) + @sizeOf(Loaded) + image_bytes, null) catch |err| {
            var discarded = ready;
            discarded.deinit();
            item.failed = true;
            return err;
        };
        const loaded = self.allocator.create(Loaded) catch |err| {
            var discarded = ready;
            discarded.deinit();
            return err;
        };
        loaded.* = .{ .ready = ready, .view = DocumentView.init(self.allocator), .image_bytes = image_bytes };
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
        for (self.resident, 0..) |slot, i| if (slot == null or slot.? == index) {
            free = i;
            break;
        };
        if (free == null) {
            free = self.evictionSlot(null) orelse return error.DecodedDocumentBudget;
            self.evict(free.?);
        }
        self.items.items[index].loaded = loaded;
        self.items.items[index].failed = false;
        self.resident[free.?] = index;
    }
    pub fn toggle(self: *View, target: Toggle) void {
        for (self.items.items) |*item| if (item.entry.ordinal == target.ordinal) {
            switch (target.kind) {
                .reasoning => if (item.entry.reasoning != null) {
                    item.expanded = !item.expanded;
                },
                .activity => item.activity_expanded = !item.activity_expanded,
                .output => item.output_expanded = !item.output_expanded,
            }
            item.failed = false;
            self.reflow();
            return;
        };
    }
    fn firstVisible(self: *const View, scroll: f32) usize {
        var low: usize = 0;
        var high = self.items.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const item = &self.items.items[mid];
            if (item.top + item.height < scroll) low = mid + 1 else high = mid;
        }
        return low;
    }
    fn nextVisible(self: *const View, index: usize) usize {
        if (self.items.items[index].activity_owner) |owner| {
            const group = &self.items.items[owner];
            if (!group.activity_expanded) return group.activity_end;
        }
        return index + 1;
    }
    fn hasTimestamp(item: *const Item) bool {
        return !isTool(item) and item.entry.length != 0 and item.entry.timestamp > 0 and item.entry.timestamp <= std.math.maxInt(i64) / 1000000;
    }
    fn bodyWidth(item: *const Item, width: f32) f32 {
        return @max(1, if (item.entry.role == .user) width * 0.8 - 2 * body_padding else if (isTool(item)) width - 28 else width);
    }
    fn bodyTop(self: *const View, index: usize) f32 {
        const item = &self.items.items[index];
        if (item.entry.role == .user) return body_padding;
        if (item.activity_owner) |owner| return 36 + (if (owner == index and self.items.items[owner].activity_end > owner + 1) @as(f32, 36) else 0);
        return if (item.entry.reasoning != null) 36 + (if (item.expanded) item.reasoning_height else @as(f32, 0)) else 4;
    }
    fn disclosure(self: *View, target: Toggle, bounds: c.SDL_FRect) void {
        if (self.disclosure_count == self.disclosures.len) return;
        const top = @max(bounds.y, self.draw_top);
        const bottom = @min(bounds.y + bounds.h, self.draw_top + self.viewport_height);
        if (bottom <= top) return;
        self.disclosures[self.disclosure_count] = .{ .toggle = target, .bounds = .{ .x = bounds.x, .y = top, .w = bounds.w, .h = bottom - top } };
        self.disclosure_count += 1;
    }

    pub fn draw(self: *View, engine: *c.SpicaText, renderer: *c.SDL_Renderer, x: f32, y: f32, viewport_width: f32, viewport_height: f32, scroll: *f32, follow_bottom: bool, metrics: theme.Metrics, palette: theme.Palette, light: bool) !void {
        const width = @max(1, viewport_width - scrollbar_gutter);
        self.wanted = null;
        self.wanted_reasoning = false;
        self.disclosure_count = 0;
        self.draw_top = y;
        self.viewport_height = viewport_height;
        scroll.* = if (follow_bottom) @max(0, self.height - viewport_height) else @min(scroll.*, @max(0, self.height - viewport_height));
        for (self.resident) |slot| if (slot) |index| {
            const item = &self.items.items[index];
            if (!self.bodyVisible(index) or item.top + item.height < scroll.* - 40 or item.top > scroll.* + viewport_height + 40) item.loaded.?.view.releaseShapes();
            if (item.loaded.?.reasoning) |*reasoning| if (!item.expanded or item.top + item.height < scroll.* - 40 or item.top > scroll.* + viewport_height + 40) reasoning.view.releaseShapes();
        };
        const anchor = self.firstVisible(scroll.*);
        const offset = if (anchor < self.items.items.len) scroll.* - self.items.items[anchor].top else 0;
        for (0..10) |_| {
            var changed = false;
            var index = self.firstVisible(scroll.*);
            while (index < self.items.items.len and self.items.items[index].top <= scroll.* + viewport_height + 40) : (index = self.nextVisible(index)) {
                const item = &self.items.items[index];
                if (item.height == 0) continue;
                const loaded = item.loaded orelse continue;
                const body_width = bodyWidth(item, width);
                var reasoning_height: f32 = 0;
                if (loaded.reasoning) |*reasoning| {
                    if (item.expanded and reasoning.ready.document.state == .rich) {
                        if (reasoning.view.width != width - 20) try reasoning.view.rebuild(&reasoning.ready.document, width - 20);
                        try reasoning.view.prepareRegion(engine, &reasoning.ready.document, scroll.* - item.top - 36, viewport_height, metrics);
                        reasoning_height = reasoning.view.height + 16;
                    }
                }
                if (self.bodyVisible(index) and loaded.ready.document.state == .rich) {
                    if (loaded.view.width != body_width) try loaded.view.rebuild(&loaded.ready.document, body_width);
                    try loaded.view.prepareRegion(engine, &loaded.ready.document, scroll.* - item.top - self.bodyTop(index), viewport_height, metrics);
                }
                const image_height = if (loaded.texture != null) loaded.image_height * @min(1, body_width / loaded.image_width) + 20 else 0;
                const body_height = if (loaded.ready.document.state == .rich) loaded.view.height + image_height else 28;
                if (self.bodyVisible(index) and item.body_height != body_height) {
                    item.body_height = body_height;
                    changed = true;
                }
                if (item.reasoning_height != reasoning_height) {
                    item.reasoning_height = reasoning_height;
                    changed = true;
                }
            }
            if (!changed) break;
            self.reflow();
            scroll.* = if (follow_bottom) @max(0, self.height - viewport_height) else if (anchor < self.items.items.len) @max(0, self.items.items[anchor].top + offset) else 0;
        }
        self.viewport_scroll = scroll.*;
        var previous_clip: c.SDL_Rect = undefined;
        _ = c.SDL_GetRenderClipRect(renderer, &previous_clip);
        var content_clip = previous_clip;
        content_clip.w = @max(0, @min(previous_clip.x + previous_clip.w, @as(c_int, @intFromFloat(x + width))) - previous_clip.x);
        _ = c.SDL_SetRenderClipRect(renderer, &content_clip);
        defer _ = c.SDL_SetRenderClipRect(renderer, &previous_clip);
        var index = self.firstVisible(scroll.*);
        while (index < self.items.items.len and self.items.items[index].top <= scroll.* + viewport_height + 40) : (index = self.nextVisible(index)) {
            const item = &self.items.items[index];
            if (item.height == 0) continue;
            const top = y + item.top - scroll.*;
            var body_x = x;
            const body_width = bodyWidth(item, width);
            if (item.entry.role == .user) {
                const bubble_x = x + width * 0.2;
                try widgets.panel(renderer, .{ .x = bubble_x, .y = top, .w = width * 0.8, .h = item.height - item_gap }, 12, palette.raised);
                body_x = bubble_x + body_padding;
            }
            if (item.activity_owner) |owner| {
                const group = &self.items.items[owner];
                const grouped = group.activity_end > owner + 1;
                if (grouped and owner == index) {
                    var buffer: [256]u8 = undefined;
                    const noun: []const u8 = switch (group.activity_kind) {
                        .read => "file reads",
                        .change => "file changes",
                        .command => "commands",
                        .other => "tool calls",
                    };
                    const summary = if (group.running) |running| std.fmt.bufPrint(&buffer, "{d} {s} · Running {s}", .{ group.activity_end - owner, noun, self.items.items[running].entry.activity[0..self.items.items[running].entry.activity_len] }) catch "Tools running" else if (group.failures != 0)
                        std.fmt.bufPrint(&buffer, "{d} {s} · {d} failed", .{ group.activity_end - owner, noun, group.failures }) catch unreachable
                    else
                        std.fmt.bufPrint(&buffer, "{d} {s}", .{ group.activity_end - owner, noun }) catch unreachable;
                    try self.chevron(renderer, x + 2, top + 10, group.activity_expanded, palette.muted);
                    try self.caption(engine, renderer, summary, x + 22, top + 8, width - 22, 13, if (group.failures != 0) palette.error_color else palette.muted);
                    self.disclosure(.{ .ordinal = item.entry.ordinal, .kind = .activity }, .{ .x = x, .y = top, .w = width, .h = 32 });
                }
                if (grouped and !group.activity_expanded) continue;
                const row_top = top + (if (grouped and owner == index) @as(f32, 36) else 0);
                const state: []const u8 = switch (item.entry.status) {
                    .running => "Running",
                    .complete => "Done",
                    .failed => "Failed",
                    .unknown => if (item.entry.length == 0) "Pending" else "Recorded",
                };
                const state_color = switch (item.entry.status) {
                    .failed => palette.error_color,
                    .running => palette.accent,
                    else => palette.muted,
                };
                try self.chevron(renderer, x + 8, row_top + 10, item.output_expanded, state_color);
                const activity = if (item.entry.activity_len != 0) item.entry.activity[0..item.entry.activity_len] else if (item.entry.role == .bash) "Bash command" else "Tool call";
                try self.caption(engine, renderer, activity, x + 28, row_top + 7, width - 104, 13, state_color);
                try self.caption(engine, renderer, state, x + width - 66, row_top + 7, 66, 11, state_color);
                self.disclosure(.{ .ordinal = item.entry.ordinal, .kind = .output }, .{ .x = x, .y = row_top, .w = width, .h = 32 });
                body_x = x + 28;
            }
            if (item.entry.reasoning != null) {
                try self.chevron(renderer, x + 2, top + 10, item.expanded, palette.muted);
                try self.caption(engine, renderer, "Reasoning", x + 22, top + 8, width - 22, 12, palette.muted);
                self.disclosure(.{ .ordinal = item.entry.ordinal, .kind = .reasoning }, .{ .x = x, .y = top, .w = width, .h = 32 });
            }
            const visible_body = self.bodyVisible(index);
            if (!item.failed and self.wanted == null) {
                if ((visible_body or item.expanded) and !current(item)) {
                    self.wanted = index;
                    self.wanted_reasoning = false;
                } else if (item.expanded and item.entry.reasoning != null and !currentReasoning(item)) {
                    self.wanted = index;
                    self.wanted_reasoning = true;
                }
            }
            if (item.loaded) |loaded| {
                if (item.expanded) if (loaded.reasoning) |*reasoning| {
                    try reasoning.view.draw(engine, renderer, &reasoning.ready.document, reasoning.ready.highlights.items, x + 20, top + 36, palette, light);
                    _ = c.SDL_SetRenderDrawColor(renderer, palette.border.r, palette.border.g, palette.border.b, 255);
                    _ = c.SDL_RenderLine(renderer, x + 6, top + 36, x + 6, top + 36 + reasoning.view.height);
                };
                if (visible_body) {
                    const body_y = top + self.bodyTop(index);
                    if (loaded.ready.document.state == .rich) {
                        try loaded.view.draw(engine, renderer, &loaded.ready.document, loaded.ready.highlights.items, body_x, body_y, palette, light);
                        if (loaded.texture) |texture| {
                            const scale = @min(1, body_width / loaded.image_width);
                            const destination = c.SDL_FRect{ .x = body_x, .y = body_y + loaded.view.height + 12, .w = loaded.image_width * scale, .h = loaded.image_height * scale };
                            if (!c.SDL_RenderTexture(renderer, texture, null, &destination)) return error.ImageDraw;
                        }
                    } else try self.caption(engine, renderer, "Formatting unavailable; source retained", body_x, body_y, body_width, 12, palette.error_color);
                }
            } else if (visible_body or item.expanded) try self.caption(engine, renderer, if (item.failed) "Unable to load message; source retained" else "Loading…", body_x, top + self.bodyTop(index), body_width, 12, palette.muted);
            if (hasTimestamp(item)) {
                var date: c.SDL_DateTime = undefined;
                if (c.SDL_TimeToDateTime(item.entry.timestamp * 1000000, &date, false)) {
                    var buffer: [64]u8 = undefined;
                    const stamp = std.fmt.bufPrint(&buffer, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ date.year, @as(u32, @intCast(date.month)), @as(u32, @intCast(date.day)), @as(u32, @intCast(date.hour)), @as(u32, @intCast(date.minute)) }) catch unreachable;
                    try self.caption(engine, renderer, stamp, body_x, top + self.bodyTop(index) + item.body_height + footer_gap, body_width, 10, palette.muted);
                }
            }
        }
        // Drawing can grow retained syntax-color scratch.
        try self.makeRoom(0, null);
        _ = c.SDL_SetRenderClipRect(renderer, &previous_clip);
        if (self.height > viewport_height) {
            const thumb_height = @min(viewport_height, @max(24, viewport_height * viewport_height / self.height));
            const thumb_y = y + (viewport_height - thumb_height) * scroll.* / @max(1, self.height - viewport_height);
            _ = c.SDL_SetRenderDrawColor(renderer, palette.border.r, palette.border.g, palette.border.b, 255);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = x + viewport_width - 3, .y = thumb_y, .w = 3, .h = thumb_height });
        }
    }
    fn chevron(_: *View, renderer: *c.SDL_Renderer, x: f32, y: f32, expanded: bool, color: theme.Color) !void {
        _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255);
        if (expanded) {
            if (!c.SDL_RenderLine(renderer, x, y, x + 4, y + 4) or !c.SDL_RenderLine(renderer, x + 4, y + 4, x + 8, y)) return error.IconDraw;
        } else if (!c.SDL_RenderLine(renderer, x + 2, y - 2, x + 6, y + 2) or !c.SDL_RenderLine(renderer, x + 6, y + 2, x + 2, y + 6)) return error.IconDraw;
    }
    fn caption(self: *View, engine: *c.SpicaText, renderer: *c.SDL_Renderer, text: []const u8, x: f32, y: f32, width: f32, size: c_uint, color: theme.Color) !void {
        if (width <= 0) return;
        self.caption_clock += 1;
        var end = @min(text.len, 256);
        while (end > 0 and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
        const bytes = text[0..end];
        var replacement = &self.captions[0];
        var layout: ?*c.SpicaTextLayout = null;
        for (&self.captions) |*cached| {
            if (cached.layout != null and cached.size == size and std.mem.eql(u8, cached.bytes[0..cached.len], bytes)) {
                cached.used = self.caption_clock;
                layout = cached.layout;
                break;
            }
            if (cached.layout == null or cached.used < replacement.used) replacement = cached;
        }
        if (layout == null) {
            if (replacement.layout) |old| c.spica_text_layout_release(old);
            replacement.layout = null;
            const created = c.spica_text_layout_create(engine, bytes.ptr, bytes.len, 4000, size, false) orelse return error.TextLayout;
            replacement.* = .{ .len = bytes.len, .size = size, .layout = created, .used = self.caption_clock };
            @memcpy(replacement.bytes[0..bytes.len], bytes);
            layout = created;
        }
        var previous: c.SDL_Rect = undefined;
        _ = c.SDL_GetRenderClipRect(renderer, &previous);
        const clip = c.SDL_Rect{ .x = @max(previous.x, @as(c_int, @intFromFloat(x))), .y = @max(previous.y, @as(c_int, @intFromFloat(y))), .w = 0, .h = 0 };
        var intersection = clip;
        intersection.w = @max(0, @min(previous.x + previous.w, @as(c_int, @intFromFloat(x + width))) - clip.x);
        intersection.h = @max(0, @min(previous.y + previous.h, @as(c_int, @intFromFloat(y + @as(f32, @floatFromInt(size)) + 8))) - clip.y);
        _ = c.SDL_SetRenderClipRect(renderer, &intersection);
        defer _ = c.SDL_SetRenderClipRect(renderer, &previous);
        if (!c.spica_text_layout_draw(engine, layout.?, x, y, .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 })) return error.TextDraw;
    }
};

test "removing expanded reasoning preserves the answer across conversation updates" {
    const alloc = std.testing.allocator;
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const surface = c.SDL_CreateSurface(640, 400, c.SDL_PIXELFORMAT_RGBA8888) orelse return error.Surface;
    defer c.SDL_DestroySurface(surface);
    const renderer = c.SDL_CreateSoftwareRenderer(surface) orelse return error.Renderer;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.spica_text_create(renderer, ".deps/install/fonts/Inter.ttf") orelse return error.Font;
    defer c.spica_text_destroy(engine);
    const clip = c.SDL_Rect{ .x = 0, .y = 0, .w = 640, .h = 400 };
    try std.testing.expect(c.SDL_SetRenderClipRect(renderer, &clip));
    const theme_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/theme.json", alloc, .limited(16384));
    defer alloc.free(theme_bytes);
    const appearance = try theme.parse(alloc, theme_bytes);
    const md = @import("../content/markdown.zig");
    const answer = "The answer is retained.";
    const thought = "Earlier reasoning.";
    const answer_id: storage.ContentId = @splat(1);
    const thought_id: storage.ContentId = @splat(2);
    const user_id: storage.ContentId = @splat(3);
    for ([_]bool{ false, true }) |append_message| {
        var view = View.init(alloc);
        defer view.deinit();
        var entries = [_]storage.ConversationEntry{
            .{ .ordinal = 0, .role = .assistant, .content_id = answer_id, .length = answer.len, .reasoning = .{ .content_ref = thought_id, .length = thought.len } },
            .{ .ordinal = 1, .role = .user, .content_id = user_id, .length = 12 },
        };
        try view.update(entries[0..1]);
        try view.accept(renderer, .{ .generation = 1, .ordinal = 0, .document = try md.parse(alloc, answer_id, answer) });
        view.toggle(.{ .ordinal = 0, .kind = .reasoning });
        var scroll: f32 = 0;
        try view.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, appearance.dark, false);
        const reasoning_request = view.request(2) orelse return error.MissingReasoningRequest;
        try std.testing.expectEqual(thought_id, reasoning_request.content_id.?);
        try view.accept(renderer, .{ .generation = 2, .ordinal = 0, .document = try md.parse(alloc, thought_id, thought) });
        try view.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, appearance.dark, false);
        const expanded_height = view.items.items[0].height;
        entries[0].reasoning = null;
        try view.update(entries[0..if (append_message) @as(usize, 2) else 1]);
        try view.draw(engine, renderer, 0, 0, 640, 400, &scroll, false, appearance.metrics, appearance.dark, false);
        try std.testing.expect(view.items.items[0].height < expanded_height);
        try std.testing.expect(std.mem.indexOf(u8, view.items.items[0].loaded.?.ready.document.text.items, answer) != null);
        if (append_message) {
            const next = view.request(3) orelse return error.MissingUserRequest;
            try std.testing.expectEqual(user_id, next.content_id.?);
            try std.testing.expectEqual(content.Role.user, next.role);
        } else try std.testing.expectEqual(@as(?content.Request, null), view.request(3));
    }
}
