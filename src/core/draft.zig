const std = @import("std");
const builtin = @import("builtin");
const c = @import("../native/bindings.zig").c;
const allocator = std.heap.page_allocator;

pub const max_drafts = 64;
pub const max_draft_bytes = 64 * 1024;
const max_path_bytes = 4096;
pub const max_projects = 64;
const max_backups = 10;
// JSON may escape each draft byte as six (\u00XX); the bound only limits reads.
const max_state_bytes = 512 * 1024 + (max_draft_bytes + max_projects * max_path_bytes + max_drafts * (max_draft_bytes + 2 * max_path_bytes)) * 6;

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

    pub fn valid(self: Entry) bool {
        if (self.text.len == 0 or self.text.len > max_draft_bytes or !std.unicode.utf8ValidateSlice(self.text)) return false;
        if (self.session.len > max_path_bytes or self.cwd.len > max_path_bytes) return false;
        return self.session.len != 0 or self.cwd.len != 0;
    }
};

pub const State = struct {
    draft: []const u8 = "",
    drafts: []const Entry = &.{},
    light: bool = false,
    font_size: u8 = 15,
    ui_scale: u16 = 100,
    chat_width: u16 = 768,
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

fn validPath(bytes: []const u8) bool {
    return bytes.len != 0 and bytes.len <= max_path_bytes and std.unicode.utf8ValidateSlice(bytes);
}

// Absent fields default to empty; a present field of the wrong type rejects the entry.
fn entryFrom(raw: std.json.Value) ?Entry {
    if (raw != .object) return null;
    var entry: Entry = .{};
    inline for (.{ "session", "cwd", "text" }) |name| if (raw.object.get(name)) |field| {
        if (field != .string) return null;
        @field(entry, name) = field.string;
    };
    return if (entry.valid()) entry else null;
}

pub const Restored = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    state: State = .{},
    // The old single draft belongs to whichever chat opens at startup.
    legacy_draft: []const u8 = "",
    // Invalid draft and project entries are skipped so everything else still loads.
    skipped: usize = 0,
    // The saved file could not be read. It was moved to `<path>.invalid` so the
    // next write cannot replace it, and defaults were used instead.
    unreadable: ?anyerror = null,
    pub fn value(self: Restored) State {
        return self.state;
    }
    pub fn deinit(self: *Restored) void {
        if (self.parsed) |parsed| parsed.deinit();
    }
};

pub fn restore(io: std.Io, path: []const u8) !Restored {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_state_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.StreamTooLong => return setAside(io, path, err),
        else => return err,
    };
    defer allocator.free(bytes);
    return load(bytes) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => setAside(io, path, err),
    };
}

fn setAside(io: std.Io, path: []const u8, err: anyerror) !Restored {
    for (0..max_backups) |attempt| {
        const backup = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "{s}.invalid", .{path})
        else
            try std.fmt.allocPrint(allocator, "{s}.invalid.{d}", .{ path, attempt });
        defer allocator.free(backup);
        if (std.Io.Dir.cwd().openFile(io, backup, .{})) |existing| {
            existing.close(io);
            if (attempt + 1 < max_backups) continue;
        } else |open_err| if (open_err != error.FileNotFound) return err;
        // Without a preserved copy, starting would let the next write discard it.
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), backup, io) catch return err;
        return .{ .unreadable = err };
    }
    unreachable;
}

fn load(bytes: []const u8) !Restored {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkspace;
    const root = parsed.value.object;
    const arena = parsed.arena.allocator();
    var restored: Restored = .{ .parsed = parsed };
    const state = &restored.state;
    if (root.get("light")) |raw| state.light = raw == .bool and raw.bool;
    state.font_size = restoredNumber(u8, root.get("font_size") orelse .null, 15, 12, 24);
    state.ui_scale = restoredNumber(u16, root.get("ui_scale") orelse .null, 100, 75, 175);
    state.chat_width = restoredNumber(u16, root.get("chat_width") orelse .null, 768, 560, 1120);
    if (root.get("projects")) |raw| if (raw == .array) {
        const projects = try arena.alloc([]const u8, @min(raw.array.items.len, max_projects));
        var kept: usize = 0;
        for (raw.array.items) |item| {
            if (kept == projects.len or item != .string or !validPath(item.string)) {
                restored.skipped += 1;
                continue;
            }
            projects[kept] = item.string;
            kept += 1;
        }
        state.projects = projects[0..kept];
    } else {
        restored.skipped += 1;
    };
    // Single draft written before drafts were keyed by chat.
    if (root.get("drafts") == null) if (root.get("draft")) |raw| {
        if (raw == .string and raw.string.len <= max_draft_bytes and std.unicode.utf8ValidateSlice(raw.string)) restored.legacy_draft = raw.string else restored.skipped += 1;
    };
    if (root.get("drafts")) |raw| if (raw == .array) {
        const drafts = try arena.alloc(Entry, @min(raw.array.items.len, max_drafts));
        var kept: usize = 0;
        for (raw.array.items) |item| {
            if (item == .object) if (item.object.get("text")) |text| if (text == .string and text.string.len == 0) continue;
            const entry = entryFrom(item) orelse {
                restored.skipped += 1;
                continue;
            };
            var duplicate = false;
            for (drafts[0..kept]) |existing| duplicate = duplicate or existing.matches(entry.session, entry.cwd);
            if (kept == drafts.len or duplicate) {
                restored.skipped += 1;
                continue;
            }
            drafts[kept] = entry;
            kept += 1;
        }
        state.drafts = drafts[0..kept];
    } else {
        restored.skipped += 1;
    };
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
    written: ?[]u8 = null,
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
        if (bytes.len >= max_state_bytes) {
            allocator.free(bytes);
            return error.WorkspaceTooLarge;
        }
        c.SDL_LockMutex(self.mutex);
        defer c.SDL_UnlockMutex(self.mutex);
        if (self.pending) |old| allocator.free(old);
        self.pending = null;
        if (self.written) |written| if (std.mem.eql(u8, written, bytes)) {
            allocator.free(bytes);
            return;
        };
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
        // Nothing can display an error once the application is closing.
        if (self.last_error) |err| std.log.err("final workspace write: {s}", .{@errorName(err)});
        c.SDL_DestroyCondition(self.condition);
        c.SDL_DestroyMutex(self.mutex);
        if (self.written) |written| allocator.free(written);
        allocator.free(self.path);
        allocator.free(self.temporary_path);
        allocator.destroy(self);
    }

    fn write(self: *Writer, bytes: []const u8) !void {
        const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
        const file = try std.Io.Dir.cwd().createFile(self.io, self.temporary_path, .{ .permissions = permissions });
        defer file.close(self.io);
        // Drafts can hold pasted secrets; also tightens a stale temporary file.
        if (builtin.os.tag != .windows) try file.setPermissions(self.io, .fromMode(0o600));
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
            if (self.write(bytes)) {
                c.SDL_LockMutex(self.mutex);
                if (self.written) |old| allocator.free(old);
                self.written = bytes;
                c.SDL_UnlockMutex(self.mutex);
            } else |err| {
                allocator.free(bytes);
                c.SDL_LockMutex(self.mutex);
                const notify = self.last_error == null;
                self.last_error = err;
                c.SDL_UnlockMutex(self.mutex);
                if (notify) {
                    var event = std.mem.zeroes(c.SDL_Event);
                    event.type = self.wake_event;
                    _ = c.SDL_PushEvent(&event);
                }
            }
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

test "older builds can read the active draft while newer builds ignore it" {
    const state = State{ .draft = "active", .drafts = &.{.{ .cwd = "/p", .text = "active" }} };
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"draft\":\"active\"") != null);
    var restored = try restoreBytes(bytes);
    defer restored.deinit();
    try std.testing.expectEqualStrings("", restored.legacy_draft);
    try std.testing.expectEqual(@as(usize, 1), restored.value().drafts.len);
}

test "an oversized draft in an older workspace is skipped" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try bytes.appendSlice(std.testing.allocator, "{\"font_size\":20,\"draft\":\"");
    try bytes.appendNTimes(std.testing.allocator, 'x', max_draft_bytes + 1);
    try bytes.appendSlice(std.testing.allocator, "\"}");
    var restored = try restoreBytes(bytes.items);
    defer restored.deinit();
    try std.testing.expectEqualStrings("", restored.legacy_draft);
    try std.testing.expectEqual(@as(usize, 1), restored.skipped);
    try std.testing.expectEqual(@as(u8, 20), restored.value().font_size);
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
    try std.testing.expectEqual(@as(usize, 3), restored.skipped);
}

test "entries of the wrong type are skipped without losing settings" {
    var restored = try restoreBytes(
        \\{"light":"yes","font_size":"big","chat_width":900,
        \\ "projects":["/p",7,"",{"x":1},"/q"],
        \\ "draft":["legacy"],
        \\ "drafts":[{"cwd":"/p","text":5},{"cwd":["/p"],"text":"a"},"text",{"session":"/s/a.jsonl","text":"kept","extra":true}]}
    );
    defer restored.deinit();
    const value = restored.value();
    try std.testing.expect(restored.unreadable == null);
    try std.testing.expect(!value.light);
    try std.testing.expectEqual(@as(u8, 15), value.font_size);
    try std.testing.expectEqual(@as(u16, 900), value.chat_width);
    try std.testing.expectEqual(@as(usize, 2), value.projects.len);
    try std.testing.expectEqualStrings("/q", value.projects[1]);
    try std.testing.expectEqual(@as(usize, 1), value.drafts.len);
    try std.testing.expectEqualStrings("kept", value.drafts[0].text);
    try std.testing.expectEqual(@as(usize, 6), restored.skipped);
}

test "an unreadable workspace is kept aside and defaults are used" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const corrupt = "{\"drafts\":[{\"cwd\":\"/p\",\"text\":\"unsaved";
    try tmp.dir.writeFile(io, .{ .sub_path = "workspace.json", .data = corrupt });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);

    var restored = try restore(io, path);
    defer restored.deinit();
    try std.testing.expect(restored.unreadable != null);
    try std.testing.expectEqual(@as(usize, 0), restored.value().drafts.len);
    try std.testing.expectEqual(@as(u8, 15), restored.value().font_size);
    const kept = try tmp.dir.readFileAlloc(io, "workspace.json.invalid", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings(corrupt, kept);

    // The original is gone, so the next start is clean rather than unreadable again.
    var next = try restore(io, path);
    defer next.deinit();
    try std.testing.expect(next.unreadable == null);
}

test "an earlier unreadable workspace backup is never replaced" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);

    for ([_][]const u8{ "{first", "{second" }) |corrupt| {
        try tmp.dir.writeFile(io, .{ .sub_path = "workspace.json", .data = corrupt });
        var restored = try restore(io, path);
        defer restored.deinit();
        try std.testing.expect(restored.unreadable != null);
    }
    for ([_][2][]const u8{ .{ "workspace.json.invalid", "{first" }, .{ "workspace.json.invalid.1", "{second" } }) |backup| {
        const kept = try tmp.dir.readFileAlloc(io, backup[0], std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(kept);
        try std.testing.expectEqualStrings(backup[1], kept);
    }
}

test "an unreadable workspace still starts once every backup name is taken" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);

    for (0..max_backups + 1) |round| {
        var buffer: [16]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = "workspace.json", .data = try std.fmt.bufPrint(&buffer, "{{broken {d}", .{round}) });
        var restored = try restore(io, path);
        defer restored.deinit();
        try std.testing.expect(restored.unreadable != null);
    }
    const first = try tmp.dir.readFileAlloc(io, "workspace.json.invalid", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{broken 0", first);
    var last_name: [32]u8 = undefined;
    const last = try tmp.dir.readFileAlloc(io, try std.fmt.bufPrint(&last_name, "workspace.json.invalid.{d}", .{max_backups - 1}), std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(last);
    var expected: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{broken {d}", .{max_backups}), last);
}

test "a workspace that cannot be opened stays in place" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "workspace.json", .data = "{\"font_size\":20}" });
    const file = try tmp.dir.openFile(io, "workspace.json", .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0));
    defer file.setPermissions(io, .fromMode(0o600)) catch {};
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);

    if (restore(io, path)) |opened| {
        var restored = opened;
        restored.deinit();
        return error.SkipZigTest;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "workspace.json.invalid", .{}));
    try file.setPermissions(io, .fromMode(0o600));
    (try tmp.dir.openFile(io, "workspace.json", .{})).close(io);
}

test "saved workspace files are private to the user" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);
    const writer = try Writer.create(io, path, 0);
    try writer.submit(.{ .drafts = &.{.{ .cwd = "/p", .text = "secret" }} });
    writer.destroy();
    const stat = try tmp.dir.statFile(io, "workspace.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "a workspace the reader would reject is never written" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);
    const session = try std.testing.allocator.alloc(u8, max_state_bytes / 6 + 1);
    defer std.testing.allocator.free(session);
    @memset(session, 1);
    const writer = try Writer.create(io, path, 0);
    defer writer.destroy();
    try std.testing.expectError(error.WorkspaceTooLarge, writer.submit(.{ .drafts = &.{.{ .session = session, .text = "draft" }} }));
}

test "a save that would not change the file is skipped" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "workspace.json" });
    defer std.testing.allocator.free(path);
    const writer = try Writer.create(io, path, 0);
    const first = State{ .drafts = &.{.{ .cwd = "/p", .text = "same" }} };
    try writer.submit(first);
    var waited: u32 = 0;
    while (waited < 500) : (waited += 1) {
        c.SDL_LockMutex(writer.mutex);
        const done = writer.written != null;
        c.SDL_UnlockMutex(writer.mutex);
        if (done) break;
        c.SDL_Delay(10);
    } else return error.TestUnexpectedResult;
    try tmp.dir.deleteFile(io, "workspace.json");
    try writer.submit(first);
    writer.destroy();
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "workspace.json", .{}));

    const changed = try Writer.create(io, path, 0);
    try changed.submit(.{ .drafts = &.{.{ .cwd = "/p", .text = "changed" }} });
    changed.destroy();
    (try tmp.dir.openFile(io, "workspace.json", .{})).close(io);
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
