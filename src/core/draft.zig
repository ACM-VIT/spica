const std = @import("std");
const c = @import("../native/bindings.zig").c;
const allocator = std.heap.page_allocator;
const ModelPreferences = @import("model_preferences.zig");

pub const State = struct {
    draft: []const u8 = "",
    light: bool = false,
    font_size: u8 = 15,
    ui_scale: u16 = 100,
    chat_width: u16 = 768,
    projects: []const []const u8 = &.{},
    hidden_models: []const ModelPreferences.Identity = &.{},
};

const RawState = struct {
    draft: []const u8 = "",
    light: bool = false,
    font_size: std.json.Value = .null,
    ui_scale: std.json.Value = .null,
    chat_width: std.json.Value = .null,
    projects: []const []const u8 = &.{},
    hidden_models: []const ModelPreferences.Identity = &.{},
};

fn restoredNumber(comptime T: type, raw: std.json.Value, fallback: T, minimum: T, maximum: T) T {
    const number: f64 = switch (raw) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        .number_string => |value| std.fmt.parseFloat(f64, value) catch return fallback,
        else => return fallback,
    };
    if (std.math.isNan(number)) return fallback;
    if (number <= @as(f64, @floatFromInt(minimum))) return minimum;
    if (number >= @as(f64, @floatFromInt(maximum))) return maximum;
    return @intFromFloat(number);
}
pub const Restored = struct {
    parsed: ?std.json.Parsed(RawState) = null,
    pub fn value(self: Restored) State {
        const raw = if (self.parsed) |parsed| parsed.value else return .{};
        return .{
            .draft = raw.draft,
            .light = raw.light,
            .font_size = restoredNumber(u8, raw.font_size, 15, 12, 24),
            .ui_scale = restoredNumber(u16, raw.ui_scale, 100, 75, 175),
            .chat_width = restoredNumber(u16, raw.chat_width, 768, 560, 1120),
            .projects = raw.projects,
            .hidden_models = raw.hidden_models,
        };
    }
    pub fn deinit(self: *Restored) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};
pub fn restore(io: std.Io, path: []const u8) !Restored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(RawState, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.draft.len > 65536 or !std.unicode.utf8ValidateSlice(parsed.value.draft)) return error.InvalidDraft;
    if (parsed.value.projects.len > 64) return error.InvalidProjects;
    for (parsed.value.projects) |project| {
        if (project.len > 4096 or !std.unicode.utf8ValidateSlice(project)) return error.InvalidProjects;
    }
    try ModelPreferences.validate(parsed.value.hidden_models);
    return .{ .parsed = parsed };
}

pub const Writer = struct {
    mutex: *c.SDL_Mutex,
    condition: *c.SDL_Condition,
    thread: ?std.Thread = null,
    io: std.Io,
    path: []u8,
    temporary_path: []u8,
    wake_event: u32,
    pending: ?[]u8 = null,
    closing: bool = false,
    last_error: ?anyerror = null,

    pub fn create(io: std.Io, path: []const u8, wake_event: u32) !*Writer {
        const self = try allocator.create(Writer);
        errdefer allocator.destroy(self);
        const mutex = c.SDL_CreateMutex() orelse return error.MutexCreation;
        errdefer c.SDL_DestroyMutex(mutex);
        const condition = c.SDL_CreateCondition() orelse return error.ConditionCreation;
        errdefer c.SDL_DestroyCondition(condition);
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);
        const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
        errdefer allocator.free(temporary);
        self.* = .{ .mutex = mutex, .condition = condition, .io = io, .path = owned, .temporary_path = temporary, .wake_event = wake_event };
        self.thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run, .{self});
        return self;
    }

    pub fn submit(self: *Writer, state: State) !void {
        const bytes = try std.json.Stringify.valueAlloc(allocator, state, .{});
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.pending) |old| allocator.free(old);
        self.pending = bytes;
        c.SDL_SignalCondition(self.condition);
    }

    pub fn takeError(self: *Writer) ?anyerror {
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        const err = self.last_error;
        self.last_error = null;
        return err;
    }

    // Ordinary shutdown drains the final accepted draft write before joining.
    pub fn destroy(self: *Writer) void {
        c.SDL_LockMutex(self.mutex);
        self.closing = true;
        c.SDL_BroadcastCondition(self.condition);
        c.SDL_UnlockMutex(self.mutex);
        self.thread.?.join();
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        allocator.free(self.path);
        allocator.free(self.temporary_path);
        allocator.destroy(self);
    }

    fn write(self: *Writer, bytes: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, self.temporary_path, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
        try std.Io.Dir.cwd().rename(self.temporary_path, std.Io.Dir.cwd(), self.path, self.io);
    }

    fn run(self: *Writer) void {
        defer c.SDL_CleanupTLS();
        while (true) {
            c.SDL_LockMutex(self.mutex);
            while (self.pending == null and !self.closing) c.SDL_WaitCondition(self.condition, self.mutex);
            const bytes = self.pending orelse {
                c.SDL_UnlockMutex(self.mutex);
                return;
            };
            self.pending = null;
            c.SDL_UnlockMutex(self.mutex);
            defer allocator.free(bytes);
            self.write(bytes) catch |err| {
                c.SDL_LockMutex(self.mutex);
                const notify = self.last_error == null;
                self.last_error = err;
                c.SDL_UnlockMutex(self.mutex);
                if (notify) {
                    var event = std.mem.zeroes(c.SDL_Event);
                    event.type = self.wake_event;
                    _ = c.SDL_PushEvent(&event);
                }
            };
        }
    }
};

test "hidden model choices survive shutdown and reopen with independent identities" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/workspace.json", .{tmp.sub_path});
    defer a.free(path);
    var choices: ModelPreferences.Preferences = .{};
    defer choices.deinit(a);
    try choices.toggle(a, "google", "older-model");
    try choices.toggle(a, "openrouter", "same-model");
    const writer = try Writer.create(io, path, 0);
    try writer.submit(.{ .draft = "keep draft", .hidden_models = choices.items.items });
    writer.destroy();
    var restored = try restore(io, path);
    var reopened = try ModelPreferences.Preferences.restore(a, restored.value().hidden_models);
    defer reopened.deinit(a);
    try std.testing.expectEqualStrings("keep draft", restored.value().draft);
    restored.deinit();
    try std.testing.expect(reopened.hidden("google", "older-model"));
    try std.testing.expect(!reopened.hidden("other", "older-model"));
    try reopened.toggle(a, "google", "older-model");
    try std.testing.expect(!reopened.hidden("google", "older-model"));
    const second = try Writer.create(io, path, 0);
    try second.submit(.{ .hidden_models = reopened.items.items });
    second.destroy();
    var final = try restore(io, path);
    defer final.deinit();
    try std.testing.expectEqual(@as(usize, 1), final.value().hidden_models.len);
    try std.testing.expectEqualStrings("openrouter", final.value().hidden_models[0].provider);
}
