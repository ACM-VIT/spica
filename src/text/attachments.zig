//! Bounded, presentation-owned attachment storage.
//!
//! Adapted from the uncommitted UI prototype in t3-e1b8cef3.
//! Native drafts require complete bytes; metadata-only handoff stays outside this store.
//! The store owns a copy of every accepted metadata field and content buffer, and
//! releases content on removal so a rejected or removed file cannot pin the
//! store's byte budget forever.
const std = @import("std");
const contract = @import("../contract.zig");

pub const max_count: usize = 8;
pub const max_bytes: usize = 256 * 1024;
pub const max_metadata_bytes: usize = 4096;
pub const max_id_bytes: usize = 64;
pub const max_name_bytes: usize = 256;
pub const max_media_type_bytes: usize = 128;
pub const max_digest_bytes: usize = 128;

pub const Error = error{
    InvalidAttachment,
    AttachmentLimit,
    MetadataLimit,
    DuplicateAttachment,
    AttachmentNotFound,
    OutOfMemory,
};

const Slot = struct {
    used: bool = false,
    id: [max_id_bytes]u8 = undefined,
    id_len: usize = 0,
    name: [max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    media_type: [max_media_type_bytes]u8 = undefined,
    media_type_len: usize = 0,
    digest: [max_digest_bytes]u8 = undefined,
    digest_len: usize = 0,
    byte_length: u64 = 0,
    kind: contract.AttachmentKind = .file,
    content: ?[]u8 = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    slots: [max_count]Slot = @splat(.{}),
    count: usize = 0,
    declared_bytes: usize = 0,
    content_bytes: usize = 0,
    metadata_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (&self.slots) |*slot| {
            if (slot.content) |content| self.allocator.free(content);
            slot.content = null;
            slot.used = false;
        }
        self.count = 0;
        self.declared_bytes = 0;
        self.content_bytes = 0;
        self.metadata_bytes = 0;
    }

    pub fn clear(self: *Store) void {
        self.deinit();
    }

    pub fn add(self: *Store, attachment: contract.Attachment) Error!usize {
        try validate(attachment);
        if (self.indexOf(attachment.metadata.id.value) != null) return error.DuplicateAttachment;
        if (self.count == max_count) return error.AttachmentLimit;

        const declared = std.math.cast(usize, attachment.metadata.byte_length) orelse return error.AttachmentLimit;
        if (declared > max_bytes -| self.declared_bytes) return error.AttachmentLimit;
        const metadata = metadataSize(attachment.metadata);
        if (metadata > max_metadata_bytes -| self.metadata_bytes) return error.MetadataLimit;
        if (attachment.content.len > max_bytes -| self.content_bytes) return error.AttachmentLimit;

        var content: ?[]u8 = null;
        if (attachment.content.len != 0) {
            content = try self.allocator.alloc(u8, attachment.content.len);
            @memcpy(content.?, attachment.content);
        }
        errdefer if (content) |value| self.allocator.free(value);

        const index = self.freeIndex();
        const slot = &self.slots[index];
        slot.* = .{ .used = true, .byte_length = attachment.metadata.byte_length, .kind = attachment.metadata.kind, .content = content };
        slot.id_len = attachment.metadata.id.value.len;
        @memcpy(slot.id[0..slot.id_len], attachment.metadata.id.value);
        slot.name_len = attachment.metadata.name.len;
        @memcpy(slot.name[0..slot.name_len], attachment.metadata.name);
        slot.media_type_len = attachment.metadata.media_type.len;
        @memcpy(slot.media_type[0..slot.media_type_len], attachment.metadata.media_type);
        slot.digest_len = attachment.metadata.digest.len;
        @memcpy(slot.digest[0..slot.digest_len], attachment.metadata.digest);
        self.count += 1;
        self.declared_bytes += declared;
        self.content_bytes += attachment.content.len;
        self.metadata_bytes += metadata;
        return index;
    }

    pub fn remove(self: *Store, id: []const u8) Error!void {
        const index = self.indexOf(id) orelse return error.AttachmentNotFound;
        self.removeAt(index);
    }

    pub fn removeAt(self: *Store, index: usize) void {
        if (index >= self.slots.len or !self.slots[index].used) return;
        const slot = &self.slots[index];
        const declared = std.math.cast(usize, slot.byte_length) orelse 0;
        const metadata = metadataSizeSlot(slot);
        const stored = if (slot.content) |content| content.len else 0;
        if (slot.content) |content| self.allocator.free(content);
        slot.* = .{};
        self.count -= 1;
        self.declared_bytes -|= declared;
        self.content_bytes -|= stored;
        self.metadata_bytes -|= metadata;
    }

    pub fn indexOf(self: *const Store, id: []const u8) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (slot.used and std.mem.eql(u8, slot.id[0..slot.id_len], id)) return index;
        }
        return null;
    }

    pub fn get(self: *const Store, index: usize) ?contract.Attachment {
        if (index >= self.slots.len or !self.slots[index].used) return null;
        const slot = &self.slots[index];
        return .{ .metadata = .{
            .id = .{ .value = slot.id[0..slot.id_len] },
            .name = slot.name[0..slot.name_len],
            .media_type = slot.media_type[0..slot.media_type_len],
            .byte_length = slot.byte_length,
            .digest = slot.digest[0..slot.digest_len],
            .kind = slot.kind,
        }, .content = if (slot.content) |content| content else &.{} };
    }

    /// Copy the current compact view into a caller-owned request array.  The
    /// returned attachments borrow this Store until the next mutation.
    pub fn snapshot(self: *const Store, destination: []contract.Attachment) Error!usize {
        if (destination.len < self.count) return error.AttachmentLimit;
        var out: usize = 0;
        for (self.slots, 0..) |_, index| {
            if (self.get(index)) |attachment| {
                destination[out] = attachment;
                out += 1;
            }
        }
        return out;
    }

    fn freeIndex(self: *const Store) usize {
        for (self.slots, 0..) |slot, index| if (!slot.used) return index;
        unreachable;
    }
};

fn validate(attachment: contract.Attachment) Error!void {
    const metadata = attachment.metadata;
    if (metadata.id.value.len == 0 or metadata.id.value.len > max_id_bytes or
        metadata.name.len == 0 or metadata.name.len > max_name_bytes or
        metadata.media_type.len == 0 or metadata.media_type.len > max_media_type_bytes or
        metadata.digest.len == 0 or metadata.digest.len > max_digest_bytes or
        !std.unicode.utf8ValidateSlice(metadata.id.value) or
        !std.unicode.utf8ValidateSlice(metadata.name) or
        !std.unicode.utf8ValidateSlice(metadata.media_type) or
        !std.unicode.utf8ValidateSlice(metadata.digest)) return error.InvalidAttachment;
    const declared = std.math.cast(usize, metadata.byte_length) orelse return error.InvalidAttachment;
    if (declared > max_bytes or (attachment.content.len != declared) or
        attachment.content.len > max_bytes) return error.InvalidAttachment;
}

fn metadataSize(metadata: contract.AttachmentMetadata) usize {
    return metadata.id.value.len +| metadata.name.len +| metadata.media_type.len +| metadata.digest.len;
}

fn metadataSizeSlot(slot: *const Slot) usize {
    return slot.id_len +| slot.name_len +| slot.media_type_len +| slot.digest_len;
}

test "attachment store owns bounded content and reuses removed slots" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const attachment: contract.Attachment = .{ .metadata = .{
        .id = .{ .value = "a" },
        .name = "notes.txt",
        .media_type = "text/plain",
        .byte_length = 5,
        .digest = "digest",
    }, .content = "hello" };
    const first = try store.add(attachment);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqualStrings("hello", store.get(first).?.content);
    try store.remove("a");
    try std.testing.expectEqual(@as(usize, 0), store.count);
    try std.testing.expectEqual(@as(usize, 0), store.declared_bytes);
    try std.testing.expectEqual(@as(usize, 0), store.content_bytes);
    const second = try store.add(attachment);
    try std.testing.expectEqual(first, second);
}

test "attachment store refuses invalid, duplicate, metadata and aggregate limits" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const base: contract.Attachment = .{ .metadata = .{
        .id = .{ .value = "a" },
        .name = "a.txt",
        .media_type = "text/plain",
        .byte_length = 0,
        .digest = "d",
    } };
    try std.testing.expectError(error.InvalidAttachment, store.add(.{ .metadata = .{ .id = .{ .value = "" }, .name = "a", .media_type = "text/plain", .byte_length = 0, .digest = "d" } }));
    _ = try store.add(base);
    try std.testing.expectError(error.DuplicateAttachment, store.add(base));
    try std.testing.expectError(error.InvalidAttachment, store.add(.{ .metadata = .{ .id = .{ .value = "b" }, .name = "b", .media_type = "text/plain", .byte_length = 3, .digest = "d" }, .content = "x" }));
    var long_name: [max_name_bytes + 1]u8 = @splat('n');
    try std.testing.expectError(error.InvalidAttachment, store.add(.{ .metadata = .{ .id = .{ .value = "b" }, .name = &long_name, .media_type = "text/plain", .byte_length = 0, .digest = "d" } }));
    var metadata = base;
    metadata.metadata.id = .{ .value = "b" };
    metadata.metadata.name = &long_name;
    try std.testing.expectError(error.InvalidAttachment, store.add(metadata));
}

test "attachment allocation failure leaves admission transactional" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var store = Store.init(failing.allocator());
    defer store.deinit();
    try std.testing.expectError(error.OutOfMemory, store.add(.{ .metadata = .{
        .id = .{ .value = "file" },
        .name = "notes",
        .media_type = "application/octet-stream",
        .byte_length = 5,
        .digest = "sha256",
    }, .content = "hello" }));
    try std.testing.expectEqual(@as(usize, 0), store.count);
    try std.testing.expectEqual(@as(usize, 0), store.content_bytes);
}

/// One owned request and completion. All filesystem work stays off the App
/// thread. Caller must drain/release before another request; callback outlives
/// destroy/join. The fixed buffer includes one overflow byte to detect growth.
pub const Loader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: *anyopaque,
    notify: *const fn (*anyopaque) void,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    stopping: bool = false,
    busy: bool = false,
    pending: bool = false,
    ready: bool = false,
    path: [1024]u8 = undefined,
    path_len: usize = 0,
    limit: usize = 0,
    bytes: [max_bytes + 1]u8 = undefined,
    len: usize = 0,
    failure: ?anyerror = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, context: *anyopaque, notify: *const fn (*anyopaque) void) !*Loader {
        const self = try allocator.create(Loader);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .context = context, .notify = notify };
        self.thread = try std.Thread.spawn(.{ .allocator = allocator }, run, .{self});
        return self;
    }

    pub fn destroy(self: *Loader) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.?.join();
        self.allocator.destroy(self);
    }

    pub fn request(self: *Loader, path: []const u8, limit: usize) !void {
        if (!std.fs.path.isAbsolute(path) or path.len > self.path.len) return error.AbsoluteFilePathRequired;
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        if (self.busy) return error.Busy;
        @memcpy(self.path[0..path.len], path);
        self.path_len = path.len;
        self.limit = @min(limit, max_bytes);
        self.failure = null;
        self.len = 0;
        self.busy = true;
        self.pending = true;
        self.condition.signal(self.io);
    }

    /// Returned bytes borrow this Loader until release. No new request is
    /// admitted during that lifetime, including while App copies to its Store.
    pub fn completed(self: *Loader) bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock(self.io);
        return self.ready;
    }

    pub fn release(self: *Loader) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.ready = false;
        self.busy = false;
    }

    fn read(self: *Loader) !void {
        const path = self.path[0..self.path_len];
        // Refuse special files before opening (e.g. FIFOs). File kind is checked
        // again on the opened descriptor; this is a local user-selected path.
        const before = try std.Io.Dir.cwd().statFile(self.io, path, .{});
        if (before.kind != .file) return error.RegularFileRequired;
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.RegularFileRequired;
        if (stat.size > self.limit) return error.AttachmentLimit;
        self.len = try file.readPositionalAll(self.io, self.bytes[0 .. self.limit + 1], 0);
        if (self.len > self.limit) return error.AttachmentLimit;
        if (self.len != stat.size) return error.AttachmentChanged;
    }

    fn run(self: *Loader) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and !self.pending) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            self.pending = false;
            self.mutex.unlock(self.io);
            self.read() catch |err| {
                self.failure = err;
            };
            self.mutex.lockUncancelable(self.io);
            self.ready = true;
            self.mutex.unlock(self.io);
            self.notify(self.context);
        }
    }
};

test "workflow file loader owns request and detects budget errors before publication" {
    const TestWake = struct {
        event: std.Io.Event = .unset,
        fn notify(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.event.set(std.testing.io);
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(std.testing.io, "notes.txt", .{});
    try file.writeStreamingAll(std.testing.io, "café");
    file.close(std.testing.io);
    var directory: [4096]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &directory);
    var path_buffer: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/notes.txt", .{directory[0..n]});
    var wake: TestWake = .{};
    const loader = try Loader.create(std.testing.allocator, std.testing.io, &wake, TestWake.notify);
    defer loader.destroy();
    try loader.request(path, 5);
    // The native path draft may change while the worker owns its copy.
    @memset(path_buffer[0..path.len], 'x');
    try wake.event.wait(std.testing.io);
    try std.testing.expect(loader.completed());
    try std.testing.expect(loader.failure == null);
    try std.testing.expectEqualStrings("café", loader.bytes[0..loader.len]);
    try std.testing.expectError(error.Busy, loader.request("/another", 5));
    loader.release();
    wake.event.reset();
    const second = try std.fmt.bufPrint(&path_buffer, "{s}/notes.txt", .{directory[0..n]});
    try loader.request(second, 4);
    try wake.event.wait(std.testing.io);
    try std.testing.expect(loader.completed());
    try std.testing.expectEqual(error.AttachmentLimit, loader.failure.?);
    loader.release();
}

test "workflow attachment aggregate bytes and metadata remain bounded across removal" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const bytes = try std.testing.allocator.alloc(u8, max_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 42);
    _ = try store.add(.{ .metadata = .{ .id = .{ .value = "big" }, .name = "big.bin", .media_type = "application/octet-stream", .byte_length = bytes.len, .digest = "digest" }, .content = bytes });
    bytes[0] = 1;
    try std.testing.expectEqual(@as(u8, 42), store.get(0).?.content[0]);
    try std.testing.expectError(error.AttachmentLimit, store.add(.{ .metadata = .{ .id = .{ .value = "extra" }, .name = "extra", .media_type = "x", .byte_length = 1, .digest = "d" }, .content = "x" }));
    store.removeAt(0);
    try std.testing.expectEqual(@as(usize, 0), store.content_bytes);
    const name = "n" ** max_name_bytes;
    const media_type = "m" ** max_media_type_bytes;
    const digest = "d" ** max_digest_bytes;
    for (0..7) |i| {
        var id: [max_id_bytes]u8 = @splat('a');
        id[0] += @intCast(i);
        _ = try store.add(.{ .metadata = .{ .id = .{ .value = &id }, .name = name, .media_type = media_type, .byte_length = 0, .digest = digest } });
    }
    try std.testing.expectError(error.MetadataLimit, store.add(.{ .metadata = .{ .id = .{ .value = "z" ** max_id_bytes }, .name = name, .media_type = media_type, .byte_length = 0, .digest = digest } }));
    try std.testing.expectEqual(@as(usize, 7), store.count);
}
