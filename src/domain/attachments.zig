//! Durable attachment validation and provider support policy.
//! Binary bodies live in the attachment table, never command/event journals.
const std = @import("std");
const c = @import("../contract.zig");

pub const max_count: usize = 8;
pub const max_bytes: usize = 256 * 1024;
pub const max_metadata_bytes: usize = 4096;
pub const max_name_bytes: usize = 256;
pub const max_media_type_bytes: usize = 128;
pub const max_digest_bytes: usize = 64;
pub const max_id_bytes: usize = 128;

pub const Error = error{ InvalidAttachment, DigestMismatch, UnsupportedAttachment, AttachmentLimit };

pub fn validate(attachment: c.Attachment, require_content: bool) Error!void {
    c.validateNativeAttachments(&.{attachment}, .{}) catch return error.InvalidAttachment;
    if (require_content and attachment.content.len != attachment.metadata.byte_length) return error.InvalidAttachment;
    if (require_content and std.mem.eql(u8, attachment.metadata.media_type, "text/plain") and !std.unicode.utf8ValidateSlice(attachment.content)) return error.InvalidAttachment;
    if (!supported(attachment.metadata.media_type, attachment.metadata.kind, .codex) and !supported(attachment.metadata.media_type, attachment.metadata.kind, .opencode)) return error.UnsupportedAttachment;
}

pub const Provider = enum { codex, opencode };

pub fn supported(media_type: []const u8, kind: c.AttachmentKind, provider: Provider) bool {
    if ((kind == .image) != std.mem.startsWith(u8, media_type, "image/")) return false;
    if (provider == .codex) {
        return std.mem.eql(u8, media_type, "text/plain") or
            std.mem.eql(u8, media_type, "image/png") or
            std.mem.eql(u8, media_type, "image/jpeg") or
            std.mem.eql(u8, media_type, "image/gif") or
            std.mem.eql(u8, media_type, "image/webp");
    }
    return std.mem.eql(u8, media_type, "text/plain") or
        std.mem.eql(u8, media_type, "application/pdf") or
        std.mem.eql(u8, media_type, "image/png") or
        std.mem.eql(u8, media_type, "image/jpeg") or
        std.mem.eql(u8, media_type, "image/gif") or
        std.mem.eql(u8, media_type, "image/webp");
}

pub fn metadataBytes(m: c.AttachmentMetadata) usize {
    return m.id.value.len +| m.name.len +| m.media_type.len +| m.digest.len;
}

pub fn digestMatches(attachment: c.Attachment) bool {
    return c.attachmentDigestMatches(attachment);
}
