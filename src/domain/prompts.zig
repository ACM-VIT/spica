//! Single-writer durable uploads. At most four 64 KiB reservations; every
//! operation uses a primary-key lookup or visits only those four reservations.
const std = @import("std");
const store = @import("store.zig");
const t = @import("types.zig");
pub const max_bytes = 64 * 1024;
pub const chunk_bytes = 2048;
pub const max_uploads = 4;
pub const max_staged_bytes = max_uploads * max_bytes;
pub const Ref = t.PromptRef;

pub fn reference(id: []const u8, bytes: []const u8) Ref {
    return .{ .id = id, .byte_length = bytes.len, .sha256 = t.digest(bytes) };
}
pub fn validForDomain(ref: Ref) bool {
    return ref.id.len != 0 and ref.id.len <= 128 and ref.byte_length != 0 and ref.byte_length <= max_bytes;
}
fn matches(s: store.Statement, ref: Ref) !bool {
    return s.integer(0) == ref.byte_length and std.mem.eql(u8, try s.bytes(1), &ref.sha256);
}
/// Idempotent begin never resets an existing upload. Full staging requires an
/// explicit discard; admission cannot silently evict another in-progress send.
pub fn begin(db: *store.Store, ref: Ref) !void {
    if (!validForDomain(ref)) return error.InvalidPrompt;
    try db.begin();
    errdefer db.rollback() catch {};
    const s = try db.prepare("SELECT byte_length,digest FROM prompt_uploads WHERE id=?", &.{.{ .text = ref.id }});
    defer s.deinit();
    if (try s.step()) {
        if (!try matches(s, ref)) return error.PromptConflict;
    } else {
        const capacity = try db.prepare("SELECT count(*),coalesce(sum(byte_length),0) FROM prompt_uploads", &.{});
        defer capacity.deinit();
        if (!try capacity.step()) return error.Corrupt;
        if (capacity.integer(0) >= max_uploads or capacity.integer(1) + @as(i64, @intCast(ref.byte_length)) > max_staged_bytes) return error.PromptStagingFull;
        try db.execute("INSERT INTO prompt_uploads(id,byte_length,digest,received,complete) VALUES(?,?,?,0,0)", &.{ .{ .text = ref.id }, .{ .integer = @intCast(ref.byte_length) }, .{ .blob = &ref.sha256 } });
    }
    try db.commit();
}
/// Chunks may split a UTF-8 sequence. Completion validates the complete text.
/// Only exact chunk retries are accepted; gaps, overlap and reordering refuse.
pub fn append(db: *store.Store, ref: Ref, offset: usize, bytes: []const u8) !void {
    if (!validForDomain(ref) or bytes.len == 0 or bytes.len > chunk_bytes or offset > ref.byte_length or bytes.len > ref.byte_length - offset or offset % chunk_bytes != 0 or bytes.len != @min(chunk_bytes, ref.byte_length - offset)) return error.InvalidPrompt;
    try db.begin();
    errdefer db.rollback() catch {};
    const s = try db.prepare("SELECT byte_length,digest,received,complete FROM prompt_uploads WHERE id=?", &.{.{ .text = ref.id }});
    defer s.deinit();
    if (!try s.step()) return error.PromptIncomplete;
    if (!try matches(s, ref)) return error.PromptConflict;
    const received: usize = @intCast(s.integer(2));
    if (offset < received) {
        const existing = try db.prepare("SELECT bytes FROM prompt_chunks WHERE upload_id=? AND byte_offset=?", &.{ .{ .text = ref.id }, .{ .integer = @intCast(offset) } });
        defer existing.deinit();
        if (!try existing.step() or !std.mem.eql(u8, try existing.bytes(0), bytes)) return error.PromptConflict;
    } else {
        if (offset != received or s.integer(3) != 0) return error.PromptIncomplete;
        try db.execute("INSERT INTO prompt_chunks VALUES(?,?,?)", &.{ .{ .text = ref.id }, .{ .integer = @intCast(offset) }, .{ .blob = bytes } });
        try db.execute("UPDATE prompt_uploads SET received=received+? WHERE id=?", &.{ .{ .integer = @intCast(bytes.len) }, .{ .text = ref.id } });
    }
    try db.commit();
}
fn collect(s: store.Statement, ref: Ref, buffer: []u8) ![]const u8 {
    if (!validForDomain(ref) or buffer.len < ref.byte_length) return error.InvalidPrompt;
    var offset: usize = 0;
    var count: usize = 0;
    while (try s.step()) {
        const bytes = try s.bytes(1);
        count += 1;
        if (count > max_bytes / chunk_bytes or s.integer(0) != offset or bytes.len == 0 or bytes.len > chunk_bytes or bytes.len > ref.byte_length - offset or offset % chunk_bytes != 0 or bytes.len != @min(chunk_bytes, ref.byte_length - offset)) return error.InvalidPrompt;
        @memcpy(buffer[offset..][0..bytes.len], bytes);
        offset += bytes.len;
    }
    if (offset != ref.byte_length) return error.PromptIncomplete;
    const bytes = buffer[0..offset];
    if (!std.mem.eql(u8, &t.digest(bytes), &ref.sha256) or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidPrompt;
    return bytes;
}
/// Call inside the send transaction too: a complete marker alone is no proof.
pub fn read(db: *store.Store, ref: Ref, buffer: []u8) ![]const u8 {
    const s = try db.prepare("SELECT byte_length,digest,received,complete FROM prompt_uploads WHERE id=?", &.{.{ .text = ref.id }});
    defer s.deinit();
    if (!try s.step()) return error.PromptIncomplete;
    if (!try matches(s, ref)) return error.PromptConflict;
    if (s.integer(2) != ref.byte_length or s.integer(3) != 1) return error.PromptIncomplete;
    return readChunks(db, ref, buffer);
}
fn readChunks(db: *store.Store, ref: Ref, buffer: []u8) ![]const u8 {
    const s = try db.prepare("SELECT byte_offset,bytes FROM prompt_chunks WHERE upload_id=? ORDER BY byte_offset", &.{.{ .text = ref.id }});
    defer s.deinit();
    return collect(s, ref, buffer);
}
pub fn complete(db: *store.Store, ref: Ref, buffer: []u8) !void {
    try db.begin();
    errdefer db.rollback() catch {};
    const s = try db.prepare("SELECT byte_length,digest,received FROM prompt_uploads WHERE id=?", &.{.{ .text = ref.id }});
    defer s.deinit();
    if (!try s.step() or s.integer(2) != ref.byte_length) return error.PromptIncomplete;
    if (!try matches(s, ref)) return error.PromptConflict;
    _ = try readChunks(db, ref, buffer);
    try db.execute("UPDATE prompt_uploads SET complete=1 WHERE id=?", &.{.{ .text = ref.id }});
    try db.commit();
}
/// One explicit upload per operation; at most 32 normal chunks, 64 KiB. No
/// journal/history scan, and committed prompts live in transcript chunks only.
pub fn discard(db: *store.Store, id: []const u8) !void {
    try db.execute("DELETE FROM prompt_uploads WHERE id=?", &.{.{ .text = id }});
}
/// Release only the matching upload. A conflicting reference cannot erase it.
pub fn discardMatching(db: *store.Store, ref: Ref) !void {
    if (!validForDomain(ref)) return;
    try db.execute("DELETE FROM prompt_uploads WHERE id=? AND byte_length=? AND digest=?", &.{ .{ .text = ref.id }, .{ .integer = @intCast(ref.byte_length) }, .{ .blob = &ref.sha256 } });
}
/// Explicit user cleanup visits one of at most four reservations, by rowid.
pub fn discardOldest(db: *store.Store) !void {
    if (try db.scalar("SELECT count(*) FROM prompt_uploads") == 0) return error.NotFound;
    try db.exec("DELETE FROM prompt_uploads WHERE rowid=(SELECT rowid FROM prompt_uploads ORDER BY rowid LIMIT 1)");
}
pub fn readBlock(db: *store.Store, block: []const u8, ref: Ref, buffer: []u8) ![]const u8 {
    const s = try db.prepare("SELECT byte_offset,bytes FROM chunks WHERE block_id=? ORDER BY byte_offset", &.{.{ .text = block }});
    defer s.deinit();
    return collect(s, ref, buffer);
}

test "durable upload validates chunks digest UTF8 retry and bounded orphan cleanup across reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..n];
    var db = try store.Store.open(std.testing.io, path);
    defer db.close() catch {};
    var buffer: [max_bytes]u8 = undefined;
    // A code point straddles two raw chunks. It must survive reopen verbatim.
    const text = ("x" ** 2047) ++ "€" ++ ("\x01" ** 63486);
    try std.testing.expectEqual(max_bytes, text.len);
    const ref = reference("resume", text);
    try begin(&db, ref);
    try std.testing.expectError(error.PromptIncomplete, read(&db, ref, &buffer));
    try std.testing.expectError(error.PromptIncomplete, append(&db, ref, 2048, text[2048..4096]));
    try std.testing.expectError(error.InvalidPrompt, append(&db, ref, 0, text[0..2047]));
    try append(&db, ref, 0, text[0..2048]);
    try append(&db, ref, 0, text[0..2048]);
    try std.testing.expectError(error.PromptConflict, append(&db, ref, 0, "y" ** 2048));
    try std.testing.expectError(error.PromptIncomplete, complete(&db, ref, &buffer));
    try db.close();
    db = try store.Store.open(std.testing.io, path);
    try begin(&db, ref);
    var offset: usize = chunk_bytes;
    while (offset < text.len) : (offset += chunk_bytes) try append(&db, ref, offset, text[offset..@min(text.len, offset + chunk_bytes)]);
    try complete(&db, ref, &buffer);
    try complete(&db, ref, &buffer);
    try std.testing.expectEqualStrings(text, try read(&db, ref, &buffer));
    var conflict = ref;
    conflict.sha256[0] ^= 1;
    try std.testing.expectError(error.PromptConflict, begin(&db, conflict));
    try std.testing.expectError(error.PromptConflict, read(&db, conflict, &buffer));
    // Tampering with the durable bytes cannot be hidden by the complete flag.
    try db.execute("UPDATE prompt_chunks SET bytes=? WHERE upload_id='resume' AND byte_offset=0", &.{.{ .blob = "y" ** 2048 }});
    try std.testing.expectError(error.InvalidPrompt, read(&db, ref, &buffer));
    try discard(&db, ref.id);
    const invalid = reference("invalid", "\xf0\x9f");
    try begin(&db, invalid);
    try append(&db, invalid, 0, "\xf0\x9f");
    try std.testing.expectError(error.InvalidPrompt, complete(&db, invalid, &buffer));
    try discard(&db, invalid.id);
    const wrong_digest = reference("digest", "a");
    try begin(&db, wrong_digest);
    try append(&db, wrong_digest, 0, "b");
    try std.testing.expectError(error.InvalidPrompt, complete(&db, wrong_digest, &buffer));
    try discard(&db, wrong_digest.id);
    for ([_][]const u8{ "one", "two", "three", "four" }) |id| try begin(&db, reference(id, "x" ** max_bytes));
    try std.testing.expectEqual(@as(i64, max_staged_bytes), try db.scalar("SELECT sum(byte_length) FROM prompt_uploads"));
    try std.testing.expectError(error.PromptStagingFull, begin(&db, reference("five", "x")));
    try discard(&db, "two");
    try begin(&db, reference("five", "x"));
    try std.testing.expectEqual(@as(i64, max_uploads), try db.scalar("SELECT count(*) FROM prompt_uploads"));
    try std.testing.expectEqual(@as(i64, 0), try db.scalar("SELECT count(*) FROM prompt_chunks"));
    try std.testing.expectError(error.InvalidPrompt, begin(&db, reference("too-large", "x" ** (max_bytes + 1))));
}
