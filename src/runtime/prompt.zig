//! Dedicated Start serialization limits; ordinary frames/queues stay unchanged.
const std = @import("std");
const c = @import("../contract.zig");
pub const max_bytes = 64 * 1024;
// JSON can expand a raw control byte to six ASCII bytes. Metadata gets its own
// fixed allowance; a provider session with larger metadata refuses actionably.
pub const attachment_bytes = 256 * 1024;
// All text (prompt + attachments) may require six JSON bytes per input byte.
// Base64 images/PDFs require less (4/3). 4096 metadata bytes may also escape
// sixfold. 16 KiB bounds RPC/session/config keys and attachment wrappers.
pub const json_bytes = 6 * (max_bytes + attachment_bytes + 4096) + 16 * 1024;
pub fn validate(start: @FieldType(c.Request, "start")) !void {
    if (start.prompt_ref != null or (start.prompt.len == 0 and start.attachments.len == 0) or start.prompt.len > max_bytes or !std.unicode.utf8ValidateSlice(start.prompt)) return error.InvalidPrompt;
    try c.validateNativeAttachments(start.attachments, .{});
    for (start.attachments) |attachment| {
        if (attachment.content.len != attachment.metadata.byte_length or !c.attachmentDigestMatches(attachment)) return error.InvalidAttachment;
        if (std.mem.eql(u8, attachment.metadata.media_type, "text/plain") and !std.unicode.utf8ValidateSlice(attachment.content)) return error.InvalidAttachment;
    }
}
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const buffer = try allocator.alloc(u8, json_bytes);
    errdefer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &writer) catch return error.FrameTooLarge;
    // Return the allocation as well as length via a sentinel-free owned slice.
    return allocator.realloc(buffer, writer.buffered().len);
}

fn encodeFailure(allocator: std.mem.Allocator) !void {
    const bytes = try encode(allocator, .{ .text = "\x01" ** max_bytes });
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len <= json_bytes);
    try std.testing.expect(bytes.len > 6 * max_bytes);
}
test "bounded Start JSON encoding cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeFailure, .{});
}

fn testAttachment(content: []const u8, id: []const u8, digest: *[64]u8) c.Attachment {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
    digest.* = std.fmt.bytesToHex(hash, .lower);
    return .{ .metadata = .{ .id = .{ .value = id }, .name = "fixture.txt", .media_type = "text/plain", .byte_length = content.len, .digest = digest }, .content = content };
}

test "direct runtime Start validates attachment count bytes metadata kind duplicates digest and UTF8" {
    const Start = @FieldType(c.Request, "start");
    const base: Start = .{ .correlation = .{ .session = .{ .value = "s" } }, .prompt = "prompt" };
    var digest: [64]u8 = undefined;
    var attachment = testAttachment("café 世界", "a", &digest);
    var request = base;
    request.attachments = &.{attachment};
    try validate(request);
    const good = attachment;
    attachment.content = "\xff";
    request.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    attachment = testAttachment("\xff", "a", &digest);
    request.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    attachment.metadata.kind = .image;
    request.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    attachment.metadata.media_type = "image/png";
    request.attachments = &.{attachment};
    try validate(request); // Binary image bytes must never be UTF8-decoded.
    attachment.metadata.kind = .file;
    request.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    attachment = good;
    attachment.metadata.digest = "g" ** 64;
    request.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    attachment = good;
    attachment.metadata.name = "x" ** 257;
    request.attachments = &.{attachment};
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    attachment = good;
    request.attachments = &.{ attachment, attachment };
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    const many = [_]c.Attachment{good} ** 9;
    request.attachments = &many;
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    const big = "x" ** (128 * 1024 + 1);
    var d1: [64]u8 = undefined;
    var d2: [64]u8 = undefined;
    request.attachments = &.{ testAttachment(big, "1", &d1), testAttachment(big, "2", &d2) };
    try std.testing.expectError(error.InvalidAttachment, validate(request));
    var metadata: [8]c.Attachment = undefined;
    var hashes: [8][64]u8 = undefined;
    for (&metadata, 0..) |*item, i| {
        item.* = testAttachment("", &.{@as(u8, @intCast('a' + i))}, &hashes[i]);
        item.metadata.name = "n" ** 256;
        item.metadata.id.value = &([_]u8{@as(u8, @intCast('a' + i))} ** 128);
        item.metadata.media_type = "t" ** 128;
    }
    request.attachments = &metadata;
    try std.testing.expectError(error.InvalidAttachment, validate(request));
}

test "Start JSON allowance covers simultaneous worst case prompt and text attachment escaping" {
    const encoded = try encode(std.testing.allocator, .{ .prompt = "\x01" ** max_bytes, .text = "\x01" ** attachment_bytes });
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len > 6 * (max_bytes + attachment_bytes));
    try std.testing.expect(encoded.len <= json_bytes);
}
