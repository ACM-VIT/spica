const std = @import("std");
const store = @import("../core/store.zig");

pub const session_file = "fixture:resource";
pub const image_id: store.ContentId = [_]u8{0xf1} ** 16;
pub const message_count = 200;
pub const response =
    \\## A native, disk-backed conversation
    \\
    \\The viewport reads **only the current page**. Cold messages stay in SQLite; text is shaped once per width and reused while scrolling.
    \\
    \\| Subsystem | Ownership | Budget |
    \\|:--|:--|--:|
    \\| Markdown | content worker | 8 MiB scratch |
    \\| Images | content worker | 48 MiB inclusive |
    \\| Warm idle | whole process | 32 MiB |
    \\
    \\```zig
    \\const ready = queue.take();
    \\defer ready.release();
    \\if (ready.revision == visible.revision) {
    \\    renderer.draw(ready);
    \\}
    \\```
    \\
    \\> Preserve the source. A display budget is not permission to lose content.
    \\
    \\- [x] Parse GFM with cmark
    \\- [x] Bound decoder allocations
    \\- [ ] Prove the whole-process resource gate
    \\
    \\Mixed scripts: Arabic العربية and Latin. Combining accents: café. Emoji: 👩‍💻 🇮🇳.
    \\
;

pub fn contentId(ordinal: usize) store.ContentId {
    var id = [_]u8{0} ** 16;
    std.mem.writeInt(u64, id[0..8], @intCast(ordinal + 1), .little);
    id[15] = 0xf0;
    return id;
}

pub fn seed(db: *store.Store, allocator: std.mem.Allocator, io: std.Io) !void {
    // A fresh isolated fixture database only; never seed the user's sessions.
    for (0..20) |index| {
        var name: [64]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, "fixture:resource:{d}", .{index});
        try db.putSession(.{ .session_file = file, .session_id = file, .project_id = "fixture", .display_name = file });
    }
    try db.putSession(.{ .session_file = session_file, .session_id = "resource", .project_id = "fixture", .display_name = "Resource acceptance scene" });
    for (0..message_count) |ordinal| {
        var buffer: [2048]u8 = undefined;
        const source = if (ordinal == message_count - 1) response else try std.fmt.bufPrint(&buffer, "### Message {d}\n\nA saved conversation should not become a resident object tree. This entry is read from the chunk store only when selected. **Stable identities** keep repeated text distinct.\n\n```python\nfor entry in visible:\n    draw(entry)\n```\n\n| Item | State |\n|---|---|\n| History | persisted |\n\n{d}\n", .{ ordinal + 1, ordinal });
        const id = contentId(ordinal);
        try db.beginContent(id, "utf-8", "text/markdown");
        try db.append(id, 0, source, true);
        var row_buffer: [32]u8 = undefined;
        const row_id = try std.fmt.bufPrint(&row_buffer, "message:{d}", .{ordinal});
        try db.putEntry(.{ .session_file = session_file, .entry_id = row_id, .append_ordinal = @intCast(ordinal), .entry_type = "message", .row = .{ .row_id = row_id, .kind = "message", .role = if (ordinal % 2 == 0) "user" else "assistant", .content_ref = id } });
    }
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, @import("build_options").asset_directory ++ "/resource.png", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(encoded);
    try db.beginContent(image_id, "binary", "image/png");
    var offset: usize = 0;
    while (offset < encoded.len) {
        const end = @min(encoded.len, offset + store.chunk_size);
        try db.append(image_id, offset, encoded[offset..end], end == encoded.len);
        offset = end;
    }
}
