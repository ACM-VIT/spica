const std = @import("std");
const c = @import("../native/bindings.zig").c;

pub const max_count = 8;
pub const max_clipboard_bytes = 32 * 1024 * 1024;
pub const max_clipboard_queue_bytes = 48 * 1024 * 1024;
pub const max_image_bytes = 4 * 1024 * 1024;
pub const max_draft_bytes = std.base64.standard.Encoder.calcSize(max_image_bytes);
pub const max_retained_bytes = 16 * 1024 * 1024;
pub const max_command_bytes = 8 * 1024 * 1024;
pub const Image = struct { type: []const u8 = "image", data: []const u8, mimeType: []const u8 };

/// Paths and prepared image payloads belong to one draft. Textures are created
/// and destroyed only by the UI; encoded data and pixels arrive from the worker.
pub const Item = struct {
    id: u64,
    name: []u8,
    path: ?[:0]u8 = null,
    size: ?u64 = null,
    image: ?Image = null,
    texture: ?*c.SDL_Texture = null,
    width: f32 = 0,
    height: f32 = 0,
    loading: bool = true,
    failure: ?anyerror = null,

    pub fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |path| allocator.free(path);
        if (self.image) |image| std.heap.page_allocator.free(image.data);
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
    }
};

pub const List = struct {
    items: std.ArrayList(Item) = .empty,
    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = .{};
    }
    pub fn bytes(self: List) usize {
        var total: usize = 0;
        for (self.items.items) |item| if (item.image) |image| {
            total += image.data.len;
        };
        return total;
    }
    pub fn ready(self: List) bool {
        for (self.items.items) |item| if (item.loading or item.failure != null) return false;
        return true;
    }
    pub fn remove(self: *List, allocator: std.mem.Allocator, index: usize) void {
        var item = self.items.orderedRemove(index);
        item.deinit(allocator);
    }
};

/// RPC has no generic file part. Give Pi an unambiguous absolute path that its
/// local read/bash tools can access; JSON quoting preserves spaces and newlines.
pub fn message(allocator: std.mem.Allocator, text: []const u8, items: []const Item) ![]u8 {
    var paths: [max_count][]const u8 = undefined;
    var count: usize = 0;
    for (items) |item| if (item.image == null) {
        paths[count] = item.path orelse return error.AttachmentNotReady;
        count += 1;
    };
    const body = if (text.len != 0) text else "Please inspect the attached files.";
    if (count == 0) return allocator.dupe(u8, body);
    const references = try std.json.Stringify.valueAlloc(allocator, paths[0..count], .{});
    defer allocator.free(references);
    return std.fmt.allocPrint(allocator, "{s}\n\nAttached local files (absolute paths; use your file tools to read them):\n{s}", .{ body, references });
}

/// Queue recovery supplies only Pi's message string. Restore images only when
/// it matches the retained submission, never onto an unrelated recovered draft.
pub fn recover(allocator: std.mem.Allocator, recovered: []const u8, text: ?[]const u8, accepted: *List, target: *List) ![]const u8 {
    if (accepted.items.items.len == 0 or target.items.items.len != 0) return recovered;
    const original = text orelse return recovered;
    const sent = try message(allocator, original, accepted.items.items);
    defer allocator.free(sent);
    if (!std.mem.eql(u8, sent, recovered)) return recovered;
    target.* = accepted.*;
    accepted.* = .{};
    return original;
}

pub const Request = struct {
    chat_id: u64,
    id: u64,
    path: ?[:0]u8 = null,
    clipboard: ?[]u8 = null,
    pub fn deinit(self: *Request) void {
        if (self.path) |path| std.heap.page_allocator.free(path);
        if (self.clipboard) |data| std.heap.page_allocator.free(data);
    }
};
pub const Prepared = struct {
    chat_id: u64,
    id: u64,
    size: u64 = 0,
    image: ?Image = null,
    thumbnail: c.SpicaImageResult = std.mem.zeroes(c.SpicaImageResult),
    failure: ?anyerror = null,
    pub fn deinit(self: *Prepared) void {
        if (self.image) |image| std.heap.page_allocator.free(image.data);
        c.spica_image_release(&self.thumbnail);
    }
};

extern fn spica_attachment_open(path: [*:0]const u8) c_int;
extern fn spica_clipboard_tiff_png(bytes: [*]const u8, size: usize, length: *usize) ?[*]u8;

pub fn prepare(io: std.Io, request: Request) !Prepared {
    const allocator = std.heap.page_allocator;
    var result: Prepared = .{ .chat_id = request.chat_id, .id = request.id };
    const original = if (request.clipboard) |data| data else blk: {
        const path = request.path orelse return error.InvalidAttachment;
        const handle = spica_attachment_open(path);
        if (handle < 0) return switch (handle) {
            -3 => error.FileNotFound,
            -2 => error.NotARegularFile,
            else => error.AttachmentRead,
        };
        const file = std.Io.File{ .handle = handle, .flags = .{ .nonblocking = true } };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotARegularFile;
        result.size = stat.size;
        // Probe signatures, not filenames. Unknown formats stay local files.
        var header: [12]u8 = undefined;
        const n = try file.readPositionalAll(io, &header, 0);
        if (mime(header[0..n]) == null) return result;
        if (stat.size > max_image_bytes) return error.ImageTooLarge;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(bytes);
        const length = try file.readPositionalAll(io, bytes, 0);
        if (length != bytes.len) return error.AttachmentChanged;
        break :blk bytes;
    };
    defer if (request.clipboard == null) allocator.free(original);
    var converted: ?[*]u8 = null;
    defer if (converted) |data| c.SDL_free(data);
    var source = original;
    if (@import("builtin").os.tag == .macos and request.clipboard != null and mime(source) == null) {
        var length: usize = 0;
        converted = spica_clipboard_tiff_png(source.ptr, source.len, &length) orelse return error.UnsupportedClipboardImage;
        source = converted.?[0..length];
    }
    if (source.len > max_image_bytes) return error.ImageTooLarge;
    result.size = source.len;
    const mime_type = mime(source) orelse return error.UnsupportedClipboardImage;
    if (c.spica_image_decode(source.ptr, source.len, 96, 64, 96 * 64 * 4, &result.thumbnail) != c.SPICA_IMAGE_OK) return error.ImagePreviewFailed;
    errdefer result.deinit();
    const data = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(source.len));
    _ = std.base64.standard.Encoder.encode(data, source);
    result.image = .{ .data = data, .mimeType = mime_type };
    return result;
}

fn mime(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

test "file references are JSON quoted and image bytes use the image field" {
    const a = std.testing.allocator;
    var items = [_]Item{
        .{ .id = 1, .name = undefined, .path = @constCast("/tmp/a \"quote\"\n.txt"), .loading = false },
        .{ .id = 2, .name = undefined, .image = .{ .data = "YWJj", .mimeType = "image/png" }, .loading = false },
    };
    const text = try message(a, "review", &items);
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "review\n\n"));
    const start = std.mem.indexOfScalar(u8, text, '[').?;
    var parsed = try std.json.parseFromSlice([][]const u8, a, text[start..], .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings(items[0].path.?, parsed.value[0]);
    try std.testing.expect(std.mem.indexOf(u8, text, "YWJj") == null);
}

test "image preparation preserves exact bytes and nonimages remain local paths" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const a = std.testing.allocator;
    const path = ".deps/src/sdl_image-release-3.4.6/test/sample.png";
    const original = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(max_image_bytes));
    defer a.free(original);
    var prepared = try prepare(std.testing.io, .{ .chat_id = 7, .id = 11, .path = @constCast(path) });
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u64, 7), prepared.chat_id);
    try std.testing.expectEqual(@as(u64, 11), prepared.id);
    try std.testing.expectEqualStrings("image/png", prepared.image.?.mimeType);
    try std.testing.expect(prepared.thumbnail.width <= 96 and prepared.thumbnail.height <= 64);
    const decoded = try a.alloc(u8, original.len);
    defer a.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, prepared.image.?.data);
    try std.testing.expectEqualSlices(u8, original, decoded);
    var file = try prepare(std.testing.io, .{ .chat_id = 8, .id = 12, .path = @constCast("README.md") });
    defer file.deinit();
    try std.testing.expect(file.image == null and file.thumbnail.pixels == null and file.size > 0);
    try std.testing.expectError(error.FileNotFound, prepare(std.testing.io, .{ .chat_id = 1, .id = 1, .path = @constCast("/nonexistent/spica-attachment") }));
    try std.testing.expectError(error.ImagePreviewFailed, prepare(std.testing.io, .{ .chat_id = 1, .id = 1, .clipboard = @constCast("\x89PNG\r\n\x1a\ncorrupt") }));
}

test "only matching Pi queue recovery moves accepted attachments" {
    const a = std.testing.allocator;
    var accepted: List = .{};
    defer accepted.deinit(a);
    var target: List = .{};
    defer target.deinit(a);
    try accepted.items.append(a, .{ .id = 1, .name = try a.dupe(u8, "doc"), .path = try a.dupeZ(u8, "/tmp/doc"), .loading = false });
    const sent = try message(a, "", accepted.items.items);
    defer a.free(sent);
    try std.testing.expectEqualStrings("different draft", try recover(a, "different draft", "", &accepted, &target));
    try std.testing.expectEqual(@as(usize, 1), accepted.items.items.len);
    try std.testing.expectEqualStrings("", try recover(a, sent, "", &accepted, &target));
    try std.testing.expectEqual(@as(usize, 0), accepted.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), target.items.items.len);
    target.remove(a, 0);
    try std.testing.expectEqual(@as(usize, 0), target.items.items.len);
}

extern fn mkfifo(path: [*:0]const u8, mode: c_uint) c_int;
test "named pipes are rejected without waiting for a writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/pipe", .{root}, 0);
    defer a.free(path);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(path, 0o600));
    try std.testing.expectError(error.NotARegularFile, prepare(std.testing.io, .{ .chat_id = 1, .id = 1, .path = path }));
}
