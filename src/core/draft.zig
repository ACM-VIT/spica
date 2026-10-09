const std = @import("std");
const c = @import("../native/bindings.zig").c;
const allocator = std.heap.page_allocator;

pub const max_drafts = 64;
pub const max_draft_bytes = 64 * 1024;
const max_path_bytes = 4096;
// JSON may escape each draft byte as six (\u00XX); the bound only limits reads.
const max_state_bytes = 512 * 1024 + max_drafts * (max_draft_bytes + 2 * max_path_bytes) * 6;

// A chat with a durable Pi session is keyed by that session file. An unsent new
// thread has no durable identity, so its draft is keyed by its project folder.
pub const Entry = struct {
    session: []const u8 = "",
    cwd: []const u8 = "",
    text: []const u8 = "",

    pub fn matches(self: Entry, session: []const u8, cwd: []const u8) bool {
        if (session.len != 0) return std.mem.eql(u8, self.session, session);
        return self.session.len == 0 and std.mem.eql(u8, self.cwd, cwd);
    }

    fn valid(self: Entry) bool {
        if (self.text.len == 0 or self.text.len > max_draft_bytes or !std.unicode.utf8ValidateSlice(self.text)) return false;
        if (self.session.len > max_path_bytes or self.cwd.len > max_path_bytes) return false;
        return self.session.len != 0 or self.cwd.len != 0;
    }
};

pub const State = struct {
    drafts: []const Entry = &.{},
    light: bool = false,
    font_size: u8 = 15,
    ui_scale: u16 = 100,
    chat_width: u16 = 768,
    projects: []const []const u8 = &.{},
};

const RawState = struct {
    // Single draft written before drafts were keyed by chat.
    draft: []const u8 = "",
    drafts: []const Entry = &.{},
    light: bool = false,
    font_size: std.json.Value = .null,
    ui_scale: std.json.Value = .null,
    chat_width: std.json.Value = .null,
    projects: []const []const u8 = &.{},
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
    drafts: []const Entry = &.{},
    // The old single draft belongs to whichever chat opens at startup.
    legacy_draft: []const u8 = "",
    // Invalid draft entries are skipped so settings and other drafts still load.
    skipped: usize = 0,
    pub fn value(self: Restored) State {
        const raw = if (self.parsed) |parsed| parsed.value else return .{};
        return .{
            .drafts = self.drafts,
            .light = raw.light,
            .font_size = restoredNumber(u8, raw.font_size, 15, 12, 24),
            .ui_scale = restoredNumber(u16, raw.ui_scale, 100, 75, 175),
            .chat_width = restoredNumber(u16, raw.chat_width, 768, 560, 1120),
            .projects = raw.projects,
        };
    }
    pub fn deinit(self: *Restored) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};
pub fn restore(io: std.Io, path: []const u8) !Restored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_state_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(RawState, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.projects.len > 64) return error.InvalidProjects;
    for (parsed.value.projects) |project| {
        if (project.len > 4096 or !std.unicode.utf8ValidateSlice(project)) return error.InvalidProjects;
    }
    var restored: Restored = .{ .parsed = parsed };
    const legacy = parsed.value.draft;
    if (legacy.len <= max_draft_bytes and std.unicode.utf8ValidateSlice(legacy)) restored.legacy_draft = legacy else restored.skipped += 1;
    const raw_drafts = parsed.value.drafts;
    const drafts = try parsed.arena.allocator().alloc(Entry, @min(raw_drafts.len, max_drafts));
    var kept: usize = 0;
    for (raw_drafts) |entry| {
        var duplicate = false;
        for (drafts[0..kept]) |existing| duplicate = duplicate or existing.matches(entry.session, entry.cwd);
        if (kept == drafts.len or duplicate or !entry.valid()) {
            restored.skipped += 1;
            continue;
        }
        drafts[kept] = entry;
        kept += 1;
    }
    restored.drafts = drafts[0..kept];
    return restored;
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

fn restoreBytes(bytes: []const u8) !Restored {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "workspace.json", .data = bytes });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);
    return restore(io, path);
}

test "keyed drafts round-trip with settings" {
    const state = State{
        .drafts = &.{ .{ .session = "/s/a.jsonl", .cwd = "/p", .text = "alpha" }, .{ .cwd = "/p", .text = "new thread ✓" } },
        .light = true,
        .font_size = 18,
        .projects = &.{"/p"},
    };
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
    defer std.testing.allocator.free(bytes);
    var restored = try restoreBytes(bytes);
    defer restored.deinit();
    const value = restored.value();
    try std.testing.expectEqual(@as(usize, 2), value.drafts.len);
    try std.testing.expectEqualStrings("alpha", value.drafts[0].text);
    try std.testing.expect(value.drafts[0].matches("/s/a.jsonl", "/other"));
    try std.testing.expect(!value.drafts[0].matches("", "/p"));
    try std.testing.expect(value.drafts[1].matches("", "/p"));
    try std.testing.expect(!value.drafts[1].matches("/s/a.jsonl", "/p"));
    try std.testing.expectEqualStrings("new thread ✓", value.drafts[1].text);
    try std.testing.expect(value.light);
    try std.testing.expectEqual(@as(u8, 18), value.font_size);
    try std.testing.expectEqual(@as(usize, 0), restored.skipped);
}

test "the single draft of older workspaces is still restored" {
    var restored = try restoreBytes("{\"draft\":\"legacy\",\"light\":true,\"projects\":[\"/p\"]}");
    defer restored.deinit();
    try std.testing.expectEqualStrings("legacy", restored.legacy_draft);
    try std.testing.expectEqual(@as(usize, 0), restored.value().drafts.len);
    try std.testing.expect(restored.value().light);
    try std.testing.expectEqual(@as(usize, 1), restored.value().projects.len);
}

test "invalid draft entries are skipped without losing settings" {
    var oversized: std.ArrayList(u8) = .empty;
    defer oversized.deinit(std.testing.allocator);
    try oversized.appendSlice(std.testing.allocator, "{\"font_size\":20,\"draft\":\"");
    try oversized.appendNTimes(std.testing.allocator, 'x', max_draft_bytes + 1);
    try oversized.appendSlice(std.testing.allocator, "\",\"drafts\":[{\"cwd\":\"/p\",\"text\":\"kept\"},{\"cwd\":\"/p\",\"text\":\"duplicate\"},{\"text\":\"no key\"},{\"cwd\":\"/q\",\"text\":\"\"},{\"cwd\":\"/q\",\"text\":\"");
    try oversized.appendNTimes(std.testing.allocator, 'y', max_draft_bytes + 1);
    try oversized.appendSlice(std.testing.allocator, "\"}]}");
    var restored = try restoreBytes(oversized.items);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u8, 20), restored.value().font_size);
    try std.testing.expectEqualStrings("", restored.legacy_draft);
    try std.testing.expectEqual(@as(usize, 1), restored.value().drafts.len);
    try std.testing.expectEqualStrings("kept", restored.value().drafts[0].text);
    try std.testing.expectEqual(@as(usize, 5), restored.skipped);
}

test "a failed write is reported" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing", "workspace.json" });
    defer std.testing.allocator.free(path);
    const writer = try Writer.create(io, path, 0);
    defer writer.destroy();
    try writer.submit(.{ .drafts = &.{.{ .cwd = "/p", .text = "kept in memory" }} });
    var waited: u32 = 0;
    const err = while (waited < 500) : (waited += 1) {
        if (writer.takeError()) |err| break err;
        c.SDL_Delay(10);
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(error.FileNotFound, err);
}
