const std = @import("std");

pub const Identity = struct { provider: []const u8, id: []const u8 };
pub const max_entries = 4096;
const byte_limit = 256 * 1024;

pub fn contains(items: []const Identity, provider: []const u8, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.provider, provider) and std.mem.eql(u8, item.id, id)) return true;
    }
    return false;
}

pub fn validate(items: []const Identity) !void {
    if (items.len > max_entries) return error.ModelPreferenceBudget;
    var bytes: usize = 0;
    for (items) |item| {
        if (item.provider.len == 0 or item.provider.len > 256 or item.id.len == 0 or item.id.len > 1024 or
            !std.unicode.utf8ValidateSlice(item.provider) or !std.unicode.utf8ValidateSlice(item.id)) return error.InvalidModelPreference;
        bytes += item.provider.len + item.id.len;
    }
    if (bytes > byte_limit) return error.ModelPreferenceBudget;
}

/// Owns only identities chosen by the user, independently of runtime snapshots.
pub const Preferences = struct {
    items: std.ArrayList(Identity) = .empty,

    pub fn restore(allocator: std.mem.Allocator, items: []const Identity) !Preferences {
        try validate(items);
        var result: Preferences = .{};
        errdefer result.deinit(allocator);
        for (items) |item| if (!contains(result.items.items, item.provider, item.id)) {
            try result.toggle(allocator, item.provider, item.id);
        };
        return result;
    }

    pub fn deinit(self: *Preferences, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            allocator.free(item.provider);
            allocator.free(item.id);
        }
        self.items.deinit(allocator);
    }

    pub fn hidden(self: *const Preferences, provider: []const u8, id: []const u8) bool {
        return contains(self.items.items, provider, id);
    }

    pub fn toggle(self: *Preferences, allocator: std.mem.Allocator, provider: []const u8, id: []const u8) !void {
        for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.provider, provider) and std.mem.eql(u8, item.id, id)) {
                const removed = self.items.orderedRemove(index);
                allocator.free(removed.provider);
                allocator.free(removed.id);
                return;
            }
        }
        try validate(&.{.{ .provider = provider, .id = id }});
        var bytes = provider.len + id.len;
        for (self.items.items) |item| bytes += item.provider.len + item.id.len;
        if (self.items.items.len == max_entries or bytes > byte_limit) return error.ModelPreferenceBudget;
        const owned_provider = try allocator.dupe(u8, provider);
        errdefer allocator.free(owned_provider);
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        try self.items.append(allocator, .{ .provider = owned_provider, .id = owned_id });
    }
};
