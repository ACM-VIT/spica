const std = @import("std");
const edit = @import("edit.zig");

pub const max_bytes = 64 * 1024;
pub const max_groups = 256;
pub const source_budget = 192 * 1024;
pub const max_pieces = 2048;
// Two extra staging slots let an over-limit edit fail transactionally even
// when undo has temporarily used all of its reserved split-piece capacity.
const piece_capacity = max_pieces + 2 * max_groups + 2;

pub const GroupKind = enum { typing, paste, ime };
pub const Direction = enum { backward, forward };
pub const Range = struct { start: usize, end: usize };
const Piece = struct { offset: usize, len: usize };
const Position = struct { caret: usize, anchor: usize };
const Group = struct {
    start: usize,
    removed: Piece,
    inserted: Piece,
    before: Position,
    after: Position,
    kind: GroupKind,
};
const Interval = struct { start: usize, end: usize, destination: usize = 0 };
const Storage = struct {
    source: [2][source_budget]u8,
    pieces: [2][piece_capacity]Piece,
    intervals: [piece_capacity + 2 * max_groups]Interval,
    history: [max_groups]Group,
    text: [max_bytes]u8,
    graphemes: [max_bytes]u8,
    words: [max_bytes]u8,
};

/// A bounded UTF-8 piece table. All memory is reserved by init; editing never
/// allocates. Sources are immutable within each generation and append-only.
/// Under source pressure a live-range compaction replaces the generation,
/// evicting oldest undo groups as necessary. This is not a disk-backed draft.
/// Active text is limited to 64 KiB, editing to 2048 coalesced pieces, and undo
/// to 256 groups; source generations are each at most 192 KiB. `storageBytes`
/// includes both generations and all scratch/metadata, not allocator overhead.
/// The table and history are authoritative; `text` is reusable segmentation
/// scratch, never an undo snapshot. Caret and anchor are logical byte offsets.
pub const Composer = struct {
    pub const storageBytes = @sizeOf(Storage);

    allocator: std.mem.Allocator,
    storage: *Storage,
    source_index: u1 = 0,
    piece_index: u1 = 0,
    source_used: usize = 0,
    piece_count: usize = 0,
    group_count: usize = 0,
    applied_groups: usize = 0,
    typing_open: bool = false,
    len: usize = 0,
    caret: usize = 0,
    anchor: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Composer {
        return .{ .allocator = allocator, .storage = try allocator.create(Storage) };
    }

    pub fn deinit(self: *Composer) void {
        self.allocator.destroy(self.storage);
        self.* = undefined;
    }

    /// Restore replaces the document atomically and clears undo/redo.
    pub fn setText(self: *Composer, bytes: []const u8) !void {
        if (bytes.len > max_bytes) return error.TextTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        @memcpy(self.storage.source[self.source_index][0..bytes.len], bytes);
        self.source_used = bytes.len;
        self.piece_count = @intFromBool(bytes.len != 0);
        if (bytes.len != 0) self.storage.pieces[self.piece_index][0] = .{ .offset = 0, .len = bytes.len };
        self.len = bytes.len;
        self.caret = bytes.len;
        self.anchor = bytes.len;
        self.group_count = 0;
        self.applied_groups = 0;
        self.typing_open = false;
        self.refresh();
    }

    pub fn selection(self: *const Composer) Range {
        return .{ .start = @min(self.caret, self.anchor), .end = @max(self.caret, self.anchor) };
    }

    pub fn materialize(self: *const Composer, buffer: []u8) ![]const u8 {
        if (buffer.len < self.len) return error.InsufficientBuffer;
        self.copyRange(.{ .start = 0, .end = self.len }, buffer[0..self.len]);
        return buffer[0..self.len];
    }

    /// Copies logical source order, never visual bidi ordering.
    pub fn copySelection(self: *const Composer, buffer: []u8) ![]const u8 {
        const range = self.selection();
        const size = range.end - range.start;
        if (buffer.len < size) return error.InsufficientBuffer;
        self.copyRange(range, buffer[0..size]);
        return buffer[0..size];
    }

    /// Borrowed logical text; valid until the next edit or restore.
    pub fn textBytes(self: *const Composer) []const u8 {
        return self.storage.text[0..self.len];
    }

    /// A grapheme-aligned rendering window around the logical caret. This is a
    /// view into the complete editor, not a truncation of its authoritative text.
    pub fn viewportRange(self: *const Composer, byte_limit: usize) Range {
        const breaks = self.storage.graphemes[0..self.len];
        var start = self.caret -| (byte_limit / 2);
        while (!edit.isBoundary(breaks, start)) start -= 1;
        var end = @min(self.len, start + byte_limit);
        while (!edit.isBoundary(breaks, end)) end -= 1;
        return .{ .start = start, .end = end };
    }

    pub fn setCaret(self: *Composer, byte_offset: usize, extend: bool) void {
        var at = @min(byte_offset, self.len);
        const breaks = self.storage.graphemes[0..self.len];
        while (!edit.isBoundary(breaks, at)) at -= 1;
        self.caret = at;
        if (!extend) self.anchor = at;
        self.typing_open = false;
    }

    pub fn selectAll(self: *Composer) void {
        self.anchor = 0;
        self.caret = self.len;
        self.typing_open = false;
    }

    pub fn moveGrapheme(self: *Composer, direction: Direction, extend: bool) void {
        self.move(direction, extend, false);
    }

    /// Moves to the next word start or previous word start, treating whitespace
    /// as a separator rather than a separate stop. Punctuation remains segmented.
    pub fn moveWord(self: *Composer, direction: Direction, extend: bool) void {
        self.move(direction, extend, true);
    }

    fn move(self: *Composer, direction: Direction, extend: bool, word: bool) void {
        const range = self.selection();
        if (!extend and range.start != range.end) {
            self.setCaret(if (direction == .backward) range.start else range.end, false);
            return;
        }
        const at = if (word) self.wordBoundary(direction) else if (direction == .backward)
            edit.previousBoundary(self.storage.graphemes[0..self.len], self.caret)
        else
            edit.nextBoundary(self.storage.graphemes[0..self.len], self.caret);
        self.setCaret(at, extend);
    }

    fn wordSegmentBoundary(self: *const Composer, direction: Direction, offset: usize) usize {
        const words = self.storage.words[0..self.len];
        const graphemes = self.storage.graphemes[0..self.len];
        var at = if (direction == .backward) edit.previousBoundary(words, offset) else edit.nextBoundary(words, offset);
        while (!edit.isBoundary(graphemes, at)) {
            at = if (direction == .backward) edit.previousBoundary(words, at) else edit.nextBoundary(words, at);
        }
        return at;
    }

    fn wordBoundary(self: *const Composer, direction: Direction) usize {
        const text = self.textBytes();
        const graphemes = self.storage.graphemes[0..self.len];
        var at = self.caret;
        if (direction == .forward) {
            if (at < self.len and !edit.whitespaceAt(text, at)) at = self.wordSegmentBoundary(.forward, at);
            while (at < self.len and edit.whitespaceAt(text, at)) at = edit.nextBoundary(graphemes, at);
        } else {
            while (at > 0) {
                const previous = edit.previousBoundary(graphemes, at);
                if (!edit.whitespaceAt(text, previous)) break;
                at = previous;
            }
            if (at > 0) at = self.wordSegmentBoundary(.backward, at);
        }
        return at;
    }

    pub fn insert(self: *Composer, bytes: []const u8, kind: GroupKind) !void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        try self.replace(self.selection(), bytes, kind);
    }

    pub fn backspace(self: *Composer) !void {
        var range = self.selection();
        if (range.start == range.end) range.start = edit.previousBoundary(self.storage.graphemes[0..self.len], self.caret);
        try self.replace(range, "", .paste);
    }

    pub fn deleteForward(self: *Composer) !void {
        var range = self.selection();
        if (range.start == range.end) range.end = edit.nextBoundary(self.storage.graphemes[0..self.len], self.caret);
        try self.replace(range, "", .paste);
    }

    pub fn deleteWord(self: *Composer, direction: Direction) !void {
        var range = self.selection();
        if (range.start == range.end) {
            const at = self.wordBoundary(direction);
            if (direction == .backward) range.start = at else range.end = at;
        }
        try self.replace(range, "", .paste);
    }

    fn replace(self: *Composer, range: Range, bytes: []const u8, kind: GroupKind) !void {
        const removed_len = range.end - range.start;
        if (removed_len == 0 and bytes.len == 0) return;
        if (bytes.len > max_bytes - (self.len - removed_len)) return error.TextTooLarge;
        // Reserve a non-adjacent placeholder to preflight the worst-case piece
        // count. There are no fallible operations or allocations after this.
        const staged = self.stage(range, .{ .offset = source_budget + 1, .len = bytes.len });
        if (staged > max_pieces) return error.PieceLimit;
        const before: Position = .{ .caret = self.caret, .anchor = self.anchor };
        self.group_count = self.applied_groups; // discard the redo branch
        var removed_reference = self.contiguousRange(range);
        const needed = bytes.len + if (removed_reference == null) removed_len else @as(usize, 0);
        if (self.reserveSource(needed)) removed_reference = self.contiguousRange(range);
        const removed: Piece = removed_reference orelse blk: {
            const piece: Piece = .{ .offset = self.source_used, .len = removed_len };
            self.copyRange(range, self.storage.source[self.source_index][self.source_used..][0..removed_len]);
            self.source_used += removed_len;
            break :blk piece;
        };
        const inserted: Piece = .{ .offset = self.source_used, .len = bytes.len };
        @memcpy(self.storage.source[self.source_index][self.source_used..][0..bytes.len], bytes);
        self.source_used += bytes.len;
        self.apply(range, inserted);
        self.caret = range.start + bytes.len;
        // Inserting a combining mark or deleting a separator can join clusters.
        // Keep the insertion endpoint on a complete cluster in the new text.
        while (!edit.isBoundary(self.storage.graphemes[0..self.len], self.caret)) self.caret += 1;
        self.anchor = self.caret;
        const after: Position = .{ .caret = self.caret, .anchor = self.anchor };
        if (kind == .typing and self.typing_open and removed_len == 0 and self.group_count != 0) {
            const last = &self.storage.history[self.group_count - 1];
            if (last.kind == .typing and last.removed.len == 0 and
                last.start + last.inserted.len == range.start and
                last.inserted.offset + last.inserted.len == inserted.offset and
                last.after.caret == before.caret and before.caret == before.anchor)
            {
                last.inserted.len += inserted.len;
                last.after = after;
                self.applied_groups = self.group_count;
                return;
            }
        }
        if (self.group_count == max_groups) self.evictOldest();
        self.storage.history[self.group_count] = .{
            .start = range.start,
            .removed = removed,
            .inserted = inserted,
            .before = before,
            .after = after,
            .kind = kind,
        };
        self.group_count += 1;
        self.applied_groups = self.group_count;
        self.typing_open = kind == .typing and removed_len == 0;
    }

    pub fn undo(self: *Composer) bool {
        if (self.applied_groups == 0) return false;
        const group = self.storage.history[self.applied_groups - 1];
        self.apply(.{ .start = group.start, .end = group.start + group.inserted.len }, group.removed);
        self.caret = group.before.caret;
        self.anchor = group.before.anchor;
        self.applied_groups -= 1;
        self.typing_open = false;
        return true;
    }

    pub fn redo(self: *Composer) bool {
        if (self.applied_groups == self.group_count) return false;
        const group = self.storage.history[self.applied_groups];
        self.apply(.{ .start = group.start, .end = group.start + group.removed.len }, group.inserted);
        self.caret = group.after.caret;
        self.anchor = group.after.anchor;
        self.applied_groups += 1;
        self.typing_open = false;
        return true;
    }

    /// Reuse existing immutable bytes when the removed logical range is also
    /// one contiguous source range; only fragmented deletions need a copy.
    fn contiguousRange(self: *const Composer, range: Range) ?Piece {
        if (range.start == range.end) return .{ .offset = 0, .len = 0 };
        var logical: usize = 0;
        var reference: ?Piece = null;
        for (self.storage.pieces[self.piece_index][0..self.piece_count]) |piece| {
            const start = @max(range.start, logical);
            const end = @min(range.end, logical + piece.len);
            if (start < end) {
                const offset = piece.offset + start - logical;
                if (reference) |*previous| {
                    if (previous.offset + previous.len != offset) return null;
                    previous.len += end - start;
                } else {
                    reference = .{ .offset = offset, .len = end - start };
                }
            }
            logical += piece.len;
            if (logical >= range.end) break;
        }
        return reference;
    }

    fn copyRange(self: *const Composer, range: Range, destination: []u8) void {
        var logical: usize = 0;
        var written: usize = 0;
        for (self.storage.pieces[self.piece_index][0..self.piece_count]) |piece| {
            const start = @max(range.start, logical);
            const end = @min(range.end, logical + piece.len);
            if (start < end) {
                const offset = piece.offset + start - logical;
                const size = end - start;
                @memcpy(destination[written..][0..size], self.storage.source[self.source_index][offset..][0..size]);
                written += size;
            }
            logical += piece.len;
            if (logical >= range.end) break;
        }
        std.debug.assert(written == destination.len);
    }

    fn appendPiece(destination: []Piece, count: *usize, piece: Piece) void {
        if (piece.len == 0) return;
        if (count.* != 0) {
            const last = &destination[count.* - 1];
            if (last.offset + last.len == piece.offset) {
                last.len += piece.len;
                return;
            }
        }
        std.debug.assert(count.* < destination.len);
        destination[count.*] = piece;
        count.* += 1;
    }

    fn stage(self: *Composer, range: Range, inserted: Piece) usize {
        const destination = &self.storage.pieces[self.piece_index ^ 1];
        var count: usize = 0;
        var logical: usize = 0;
        var added = false;
        for (self.storage.pieces[self.piece_index][0..self.piece_count]) |piece| {
            const end = logical + piece.len;
            if (logical < range.start) {
                appendPiece(destination, &count, .{ .offset = piece.offset, .len = @min(end, range.start) - logical });
            }
            if (!added and end >= range.start) {
                appendPiece(destination, &count, inserted);
                added = true;
            }
            if (end > range.end) {
                const start = @max(logical, range.end);
                appendPiece(destination, &count, .{ .offset = piece.offset + start - logical, .len = end - start });
            }
            logical = end;
        }
        if (!added) appendPiece(destination, &count, inserted);
        return count;
    }

    fn apply(self: *Composer, range: Range, inserted: Piece) void {
        self.piece_count = self.stage(range, inserted);
        self.piece_index ^= 1;
        self.len = self.len - (range.end - range.start) + inserted.len;
        self.refresh();
    }

    fn refresh(self: *Composer) void {
        const text = self.storage.text[0..self.len];
        self.copyRange(.{ .start = 0, .end = self.len }, text);
        edit.analyzeValidUtf8(text, &self.storage.graphemes, &self.storage.words);
    }

    fn evictOldest(self: *Composer) void {
        std.debug.assert(self.group_count != 0 and self.applied_groups != 0);
        std.mem.copyForwards(Group, self.storage.history[0 .. self.group_count - 1], self.storage.history[1..self.group_count]);
        self.group_count -= 1;
        self.applied_groups -= 1;
        self.typing_open = false;
    }

    fn intervalLess(_: void, a: Interval, b: Interval) bool {
        return a.start < b.start;
    }

    fn liveIntervals(self: *Composer) struct { count: usize, bytes: usize } {
        var count: usize = 0;
        for (self.storage.pieces[self.piece_index][0..self.piece_count]) |piece| {
            self.storage.intervals[count] = .{ .start = piece.offset, .end = piece.offset + piece.len };
            count += 1;
        }
        for (self.storage.history[0..self.group_count]) |group| {
            for ([_]Piece{ group.removed, group.inserted }) |piece| {
                if (piece.len == 0) continue;
                self.storage.intervals[count] = .{ .start = piece.offset, .end = piece.offset + piece.len };
                count += 1;
            }
        }
        std.sort.heap(Interval, self.storage.intervals[0..count], {}, intervalLess);
        var merged: usize = 0;
        for (0..count) |i| {
            const interval = self.storage.intervals[i];
            if (merged != 0 and self.storage.intervals[merged - 1].end >= interval.start) {
                self.storage.intervals[merged - 1].end = @max(self.storage.intervals[merged - 1].end, interval.end);
            } else {
                self.storage.intervals[merged] = interval;
                merged += 1;
            }
        }
        var bytes: usize = 0;
        for (self.storage.intervals[0..merged]) |*interval| {
            interval.destination = bytes;
            bytes += interval.end - interval.start;
        }
        return .{ .count = merged, .bytes = bytes };
    }

    fn relocate(self: *Composer, piece: *Piece, count: usize) void {
        if (piece.len == 0) return;
        var low: usize = 0;
        var high = count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.storage.intervals[mid].start <= piece.offset) low = mid + 1 else high = mid;
        }
        std.debug.assert(low != 0);
        const interval = self.storage.intervals[low - 1];
        std.debug.assert(piece.offset + piece.len <= interval.end);
        piece.offset = interval.destination + piece.offset - interval.start;
    }

    fn reserveSource(self: *Composer, needed: usize) bool {
        if (needed <= source_budget - self.source_used) return false;
        var live = self.liveIntervals();
        while (live.bytes + needed > source_budget) {
            self.evictOldest();
            live = self.liveIntervals();
        }
        const next = self.source_index ^ 1;
        for (self.storage.intervals[0..live.count]) |interval| {
            @memcpy(self.storage.source[next][interval.destination..][0 .. interval.end - interval.start], self.storage.source[self.source_index][interval.start..interval.end]);
        }
        for (self.storage.pieces[self.piece_index][0..self.piece_count]) |*piece| self.relocate(piece, live.count);
        for (self.storage.history[0..self.group_count]) |*group| {
            self.relocate(&group.removed, live.count);
            self.relocate(&group.inserted, live.count);
        }
        self.source_index = next;
        self.source_used = live.bytes;
        return true;
    }
};

fn expectText(composer: *const Composer, expected: []const u8) !void {
    var buffer: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try composer.materialize(&buffer));
}

test "multiline grapheme deletion and selection replacement restore exact selections" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    const original = "a\ne\u{301}🇺🇸👩‍💻";
    try composer.setText(original);
    try composer.backspace();
    try expectText(&composer, "a\ne\u{301}🇺🇸");
    try composer.backspace();
    try expectText(&composer, "a\ne\u{301}");
    try composer.backspace();
    try expectText(&composer, "a\n");
    try std.testing.expect(composer.undo());
    try expectText(&composer, "a\ne\u{301}");
    composer.setCaret(2, false);
    try composer.deleteForward();
    try expectText(&composer, "a\n");
    try std.testing.expect(composer.undo());
    composer.setCaret(2, false);
    composer.moveGrapheme(.forward, true);
    try composer.insert("中\n文", .paste);
    try expectText(&composer, "a\n中\n文");
    try std.testing.expect(composer.undo());
    try expectText(&composer, "a\ne\u{301}");
    try std.testing.expectEqual(@as(usize, 2), composer.anchor);
    try std.testing.expectEqual(@as(usize, "a\ne\u{301}".len), composer.caret);
    try std.testing.expect(composer.redo());
    try expectText(&composer, "a\n中\n文");
}

test "joins across edits snap caret to the new cluster without corrupting undo" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    try composer.setText("e\n\u{301}X");
    composer.setCaret(2, false);
    try composer.backspace();
    try expectText(&composer, "e\u{301}X");
    try std.testing.expectEqual(@as(usize, "e\u{301}".len), composer.caret);
    try std.testing.expect(composer.undo());
    try expectText(&composer, "e\n\u{301}X");
    try std.testing.expectEqual(@as(usize, 2), composer.caret);
    try composer.setText("\u{301}X");
    composer.setCaret(0, false);
    try composer.insert("e", .typing);
    try expectText(&composer, "e\u{301}X");
    try std.testing.expectEqual(@as(usize, "e\u{301}".len), composer.caret);
    try std.testing.expect(composer.undo());
    try expectText(&composer, "\u{301}X");
    try std.testing.expectEqual(@as(usize, 0), composer.caret);
}

test "contiguous typing groups while paste and IME commits are atomic" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    try composer.insert("e", .typing);
    try composer.insert("\u{301}", .typing);
    try composer.insert("\n", .typing);
    try composer.insert("two\nlines", .paste);
    try composer.insert("日本語", .ime);
    try expectText(&composer, "e\u{301}\ntwo\nlines日本語");
    try std.testing.expect(composer.undo());
    try expectText(&composer, "e\u{301}\ntwo\nlines");
    try std.testing.expect(composer.undo());
    try expectText(&composer, "e\u{301}\n");
    try std.testing.expect(composer.undo());
    try expectText(&composer, "");
    try std.testing.expect(!composer.undo());
    try std.testing.expect(composer.redo());
    try expectText(&composer, "e\u{301}\n");
    try std.testing.expect(composer.redo());
    try std.testing.expect(composer.redo());
    try expectText(&composer, "e\u{301}\ntwo\nlines日本語");
    composer.moveGrapheme(.backward, false);
    try composer.insert("!", .typing);
    try std.testing.expect(composer.undo());
    try expectText(&composer, "e\u{301}\ntwo\nlines日本語");
}

test "logical bidi copy and grapheme selection preserve complete clusters" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    const text = "hello שלום e\u{301}世界";
    try composer.setText(text);
    composer.selectAll();
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(text, try composer.copySelection(&buffer));
    composer.setCaret("hello שלום e".len, false);
    try std.testing.expectEqual(@as(usize, "hello שלום ".len), composer.caret);
    composer.moveGrapheme(.forward, true);
    try std.testing.expectEqualStrings("e\u{301}", try composer.copySelection(&buffer));
}

test "word movement skips Unicode whitespace without splitting combining or emoji clusters" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    const prefix = "\t\u{a0}";
    const text = prefix ++ "e\u{301}  שלום\n👩‍💻\u{3000}";
    try composer.setText(text);
    composer.setCaret(0, false);
    composer.moveWord(.forward, false);
    try std.testing.expectEqual(@as(usize, prefix.len), composer.caret);
    composer.moveWord(.forward, true);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("e\u{301}  ", try composer.copySelection(&buffer));
    composer.moveWord(.forward, false);
    try std.testing.expectEqual(@as(usize, (prefix ++ "e\u{301}  ").len), composer.caret);
    composer.setCaret(text.len, false);
    composer.moveWord(.backward, true);
    try std.testing.expectEqualStrings("👩‍💻\u{3000}", try composer.copySelection(&buffer));
    composer.moveWord(.backward, true);
    try std.testing.expectEqualStrings("שלום\n👩‍💻\u{3000}", try composer.copySelection(&buffer));
    composer.setCaret(0, false);
    composer.moveWord(.backward, true);
    try std.testing.expectEqual(@as(usize, 0), composer.caret);
}

test "word deletion restores Unicode text and reversed selections on undo" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    const text = "e\u{301} \t👩‍💻\nשלום";
    const word_end = "e\u{301} \t".len;
    try composer.setText(text);
    composer.setCaret(0, false);
    try composer.deleteWord(.forward);
    try expectText(&composer, "👩‍💻\nשלום");
    try std.testing.expect(composer.undo());
    try expectText(&composer, text);
    try std.testing.expectEqual(@as(usize, 0), composer.caret);
    composer.setCaret(word_end, false);
    try composer.deleteWord(.backward);
    try expectText(&composer, "👩‍💻\nשלום");
    try std.testing.expect(composer.undo());
    try std.testing.expectEqual(@as(usize, word_end), composer.caret);
    composer.setCaret(text.len, false);
    composer.moveWord(.backward, true);
    const before = composer.selection();
    try composer.deleteWord(.forward);
    try expectText(&composer, "e\u{301} \t👩‍💻\n");
    try std.testing.expect(composer.undo());
    try expectText(&composer, text);
    try std.testing.expectEqual(before.start, composer.caret);
    try std.testing.expectEqual(before.end, composer.anchor);
    try std.testing.expect(composer.redo());
    try expectText(&composer, "e\u{301} \t👩‍💻\n");
    composer.setCaret(0, false);
    try composer.deleteWord(.backward);
    try expectText(&composer, "e\u{301} \t👩‍💻\n");
}

test "rejected UTF8 and byte limits leave document selection and undo intact" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    try composer.setText("restored");
    composer.selectAll();
    try std.testing.expectError(error.InvalidUtf8, composer.insert("\xff", .ime));
    try expectText(&composer, "restored");
    try std.testing.expectEqual(@as(usize, 0), composer.anchor);
    try std.testing.expectEqual(@as(usize, 8), composer.caret);
    try std.testing.expect(!composer.undo());
    try composer.insert("valid", .paste);
    try std.testing.expectError(error.InvalidUtf8, composer.setText("\xc0\x80"));
    try expectText(&composer, "valid");
    try std.testing.expect(composer.undo());
    try expectText(&composer, "restored");
    var full: [max_bytes]u8 = undefined;
    @memset(&full, 'a');
    try composer.setText(&full);
    try std.testing.expectError(error.TextTooLarge, composer.insert("b", .typing));
    try expectText(&composer, &full);
    try std.testing.expect(!composer.undo());
    try std.testing.expectError(error.InsufficientBuffer, composer.materialize(full[0..10]));
    composer.selectAll();
    try composer.insert("short", .paste);
    try std.testing.expect(composer.undo());
    try expectText(&composer, &full);
}

test "source-pressure compaction retains valid bounded undo ranges" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    var payload: [32 * 1024]u8 = undefined;
    @memset(&payload, '0');
    try composer.setText(&payload);
    for (0..40) |i| {
        @memset(&payload, 'A' + @as(u8, @intCast(i % 26)));
        composer.selectAll();
        try composer.insert(&payload, .paste);
        try expectText(&composer, &payload);
    }
    const retained = composer.applied_groups;
    try std.testing.expect(retained > 0 and retained < 40);
    for (0..retained) |i| {
        try std.testing.expect(composer.undo());
        @memset(&payload, 'A' + @as(u8, @intCast((38 - i) % 26)));
        try expectText(&composer, &payload);
    }
    try std.testing.expect(!composer.undo());
    for (0..retained) |i| {
        try std.testing.expect(composer.redo());
        @memset(&payload, 'A' + @as(u8, @intCast((40 - retained + i) % 26)));
        try expectText(&composer, &payload);
    }
}

test "fragmentation failure is atomic and retained undo remains usable" {
    var composer = try Composer.init(std.testing.allocator);
    defer composer.deinit();
    try composer.setText("ab");
    for (0..max_pieces - 2) |_| {
        composer.setCaret(1, false);
        try composer.insert("x", .paste);
    }
    composer.setCaret(1, false);
    var before: [max_bytes]u8 = undefined;
    const expected = try composer.materialize(&before);
    try std.testing.expectError(error.PieceLimit, composer.insert("y", .paste));
    try expectText(&composer, expected);
    try std.testing.expectEqual(@as(usize, 1), composer.caret);
    try std.testing.expect(composer.undo());
    var after: [max_bytes]u8 = undefined;
    const undone = try composer.materialize(&after);
    try std.testing.expectEqualStrings(expected[0 .. expected.len - 2], undone[0 .. undone.len - 1]);
    try std.testing.expectEqual(@as(u8, 'b'), undone[undone.len - 1]);
    try std.testing.expect(composer.redo());
    try expectText(&composer, expected);
}
