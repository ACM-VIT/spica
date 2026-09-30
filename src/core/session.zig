const std = @import("std");
const storage = @import("store.zig");
const Value = std.json.Value;
const limit = 1024 * 1024;
fn child(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn text(v: Value, key: []const u8) []const u8 {
    const x = child(v, key);
    return if (x == .string) x.string else "";
}

/// Projects only display-bearing fields, retaining the authoritative JSON in a
/// separate disk content object. Tool calls/results remain distinct typed rows.
pub fn messageText(a: std.mem.Allocator, message: Value) ![]u8 {
    const content = child(message, "content");
    if (content == .string) return a.dupe(u8, content.string);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    if (content == .array) for (content.array.items) |block| {
        const ty = text(block, "type");
        if (std.mem.eql(u8, ty, "text")) try result.appendSlice(a, text(block, "text")) else if (std.mem.eql(u8, ty, "thinking")) continue else if (std.mem.eql(u8, ty, "toolCall")) {
            try result.appendSlice(a, "\n\nTool: ");
            try result.appendSlice(a, text(block, "name"));
            try result.appendSlice(a, "\n```json\n");
            const args = try std.json.Stringify.valueAlloc(a, child(block, "arguments"), .{});
            defer a.free(args);
            try result.appendSlice(a, args);
            try result.appendSlice(a, "\n```\n");
        } else if (std.mem.eql(u8, ty, "image")) {
            try result.appendSlice(a, "\n[Image content retained in authoritative record]\n");
        } else {
            try result.appendSlice(a, "\n[Unsupported content block: ");
            try result.appendSlice(a, ty);
            try result.appendSlice(a, "]\n");
        }
    };
    if (result.items.len == 0) {
        const output = text(message, "output");
        if (output.len != 0) try result.appendSlice(a, output);
        const err = text(message, "errorMessage");
        if (err.len != 0) try result.appendSlice(a, err);
    }
    return result.toOwnedSlice(a);
}

/// Reasoning has its own disk-backed disclosure, never the default message body.
pub fn thinkingText(a: std.mem.Allocator, message: Value) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    const content = child(message, "content");
    if (content == .array) for (content.array.items) |block| {
        if (!std.mem.eql(u8, text(block, "type"), "thinking")) continue;
        const thinking = text(block, "thinking");
        if (thinking.len == 0) continue;
        if (result.items.len > 0) try result.appendSlice(a, "\n\n");
        try result.appendSlice(a, thinking);
    };
    return result.toOwnedSlice(a);
}

/// Split the entries array directly from the spool. Never build a generic JSON
/// tree of the session history. One normal entry and a bounded envelope reside
/// in memory; oversized entries retain their complete disk-backed raw record.
pub fn reconcile(runtime: anytype, source: anytype, first: []const u8) !void {
    const a = runtime.allocator;
    const marker = "\"entries\":[";
    const begin = std.mem.indexOf(u8, first, marker) orelse return error.UnsupportedEntriesEnvelope;
    var envelope: std.ArrayList(u8) = .empty;
    defer envelope.deinit(a);
    try envelope.appendSlice(a, first[0 .. begin + marker.len]);
    var entry: std.ArrayList(u8) = .empty;
    defer entry.deinit(a);
    var raw_chunk: [storage.chunk_size]u8 = undefined;
    var raw_used: usize = 0;
    var raw_length: u64 = 0;
    var entry_raw: storage.ContentId = undefined;
    var chunk = first[begin + marker.len ..];
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var array_done = false;
    var oversized = false;
    var saw_entry = false;
    while (true) {
        for (chunk) |byte| {
            if (array_done) {
                if (envelope.items.len >= 65536) return error.UnsupportedEntriesEnvelope;
                try envelope.append(a, byte);
                continue;
            }
            if (depth == 0) {
                if (byte == ']') {
                    array_done = true;
                    try envelope.append(a, ']');
                    continue;
                }
                if (byte == ',' or std.ascii.isWhitespace(byte)) continue;
                if (byte != '{') return error.UnsupportedEntriesShape;
                depth = 1;
                in_string = false;
                escaped = false;
                oversized = false;
                entry.clearRetainingCapacity();
                try entry.append(a, byte);
                entry_raw = runtime.newContentId();
                try runtime.store.?.beginContent(entry_raw, "utf-8", "application/json");
                raw_chunk[0] = byte;
                raw_used = 1;
                raw_length = 0;
                continue;
            }
            raw_chunk[raw_used] = byte;
            raw_used += 1;
            if (raw_used == raw_chunk.len) {
                try runtime.store.?.append(entry_raw, raw_length, raw_chunk[0..raw_used], false);
                raw_length += raw_used;
                raw_used = 0;
            }
            if (!oversized) {
                if (entry.items.len < limit) try entry.append(a, byte) else oversized = true;
            }
            if (in_string) {
                if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') in_string = false;
            } else if (byte == '"') in_string = true else if (byte == '{' or byte == '[') depth += 1 else if (byte == '}' or byte == ']') {
                depth -= 1;
                if (depth == 0) {
                    saw_entry = true;
                    try runtime.store.?.append(entry_raw, raw_length, raw_chunk[0..raw_used], true);
                    if (oversized) try putOversizedEntry(runtime, entry.items, entry_raw) else try putEntry(runtime, entry.items, entry_raw);
                }
            }
        }
        chunk = (try source.next()) orelse break;
    }
    if (!array_done or depth != 0) return error.UnsupportedEntriesShape;
    const parsed = try std.json.parseFromSlice(Value, a, envelope.items, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const data = child(parsed.value, "data");
    const leaf = text(data, "leafId");
    try runtime.replace(&runtime.leaf_id, leaf);
    try runtime.persistSession();
    if (leaf.len > 0) try runtime.store.?.rebuildActivePath(runtime.state.session_file, leaf);
    runtime.state.active_count = try runtime.store.?.activeEntryCount(runtime.state.session_file);
    var visible_page = try runtime.store.?.lastDisplayableActiveEntry(a, runtime.state.session_file);
    defer visible_page.deinit();
    runtime.state.visible_active_ordinal = visible_page.next_cursor orelse -1;
    runtime.state.thinking_content_ref = null;
    runtime.state.thinking_length = 0;
    if (visible_page.rows.len > 0) {
        const row = visible_page.rows[0];
        const content = row.content_ref.?;
        var info = try runtime.store.?.contentInfo(a, content);
        defer info.deinit();
        try runtime.visible(content, info.total_length, row.role, row.kind, row.status);
        if (try runtime.store.?.referenceForEntry(runtime.state.session_file, row.row_id)) |reasoning| {
            runtime.state.thinking_content_ref = reasoning.content_ref;
            runtime.state.thinking_length = reasoning.length;
        }
    } else {
        runtime.state.visible_content_ref = null;
        runtime.state.visible_length = 0;
        runtime.state.visible_revision += 1;
    }
    if (saw_entry and runtime.state.status == .ready) {
        try runtime.store.?.clearLiveGeneration(runtime.state.runtime_id, runtime.state.generation);
        for (runtime.tools.items) |tool| runtime.allocator.free(tool.id);
        runtime.tools.clearRetainingCapacity();
    }
}

fn putEntry(runtime: anytype, bytes: []const u8, response_raw: storage.ContentId) !void {
    const a = runtime.allocator;
    const parsed = try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always, .max_value_len = limit });
    defer parsed.deinit();
    const value = parsed.value;
    const id = text(value, "id");
    const ty = text(value, "type");
    if (id.len == 0) {
        try runtime.inspect(response_raw, "unsupported_entry", "Canonical entry has no identity");
        return;
    }
    const raw = response_raw;
    const message = child(value, "message");
    const role = text(message, "role");
    var body: []u8 = undefined;
    const is_message = std.mem.eql(u8, ty, "message");
    if (is_message) body = try messageText(a, message) else if (text(value, "summary").len > 0) body = try a.dupe(u8, text(value, "summary")) else body = try std.fmt.allocPrint(a, "Session entry: {s}\n\n```json\n{s}\n```", .{ ty, bytes });
    defer a.free(body);
    const content = try runtime.content(body, "text/markdown");
    const kind = if (!is_message) "unsupported_entry" else if (std.mem.eql(u8, role, "toolResult")) "tool" else "message";
    const tool_id = text(message, "toolCallId");
    const error_value = child(message, "isError");
    runtime.state.last_ordinal += 1;
    const parent_id = text(value, "parentId");
    try runtime.store.?.putEntry(.{
        .session_file = runtime.state.session_file,
        .entry_id = id,
        .parent_id = if (parent_id.len > 0) parent_id else null,
        .append_ordinal = runtime.state.last_ordinal,
        .entry_type = ty,
        .raw_content_ref = raw,
        .row = .{ .row_id = id, .kind = kind, .role = role, .status = "complete", .content_ref = content, .tool_call_id = if (tool_id.len > 0) tool_id else null, .title = text(message, "toolName"), .is_error = error_value == .bool and error_value.bool },
    });
    if (is_message) {
        const thinking = try thinkingText(a, message);
        defer a.free(thinking);
        const reasoning: ?storage.ReasoningReference = if (thinking.len > 0)
            .{ .content_ref = try runtime.content(thinking, "text/markdown"), .length = thinking.len }
        else
            null;
        try runtime.store.?.putEntryReasoning(runtime.state.session_file, id, reasoning);
    }
    try runtime.replace(&runtime.last_entry_id, id);
}

fn rootString(prefix: []const u8, wanted: []const u8) []const u8 {
    var scanner = std.json.Scanner.initStreaming(std.heap.page_allocator);
    defer scanner.deinit();
    scanner.feedInput(prefix);
    var depth: usize = 0;
    var key = false;
    var matched = false;
    while (true) {
        const token = scanner.next() catch return "";
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                key = true;
            },
            .object_end, .array_end => {
                depth -|= 1;
                if (depth == 0) return "";
            },
            .string => |value| if (depth == 1) {
                if (key) {
                    matched = std.mem.eql(u8, value, wanted);
                    key = false;
                } else {
                    if (matched) return value;
                    key = true;
                }
            },
            .null, .true, .false, .number => {
                if (depth == 1) key = true;
            },
            else => {},
        }
    }
}

fn putOversizedEntry(runtime: anytype, prefix: []const u8, raw: storage.ContentId) !void {
    const id = rootString(prefix, "id");
    const ty = rootString(prefix, "type");
    const parent = rootString(prefix, "parentId");
    if (id.len == 0) {
        try runtime.inspect(raw, "unsupported_oversized_entry", "Oversized canonical entry lacks bounded identity metadata");
        return;
    }
    const body = "Display budget exceeded for this canonical entry. Complete authoritative JSON is retained on disk for inspection.";
    const content = try runtime.content(body, "text/markdown");
    runtime.state.last_ordinal += 1;
    try runtime.store.?.putEntry(.{
        .session_file = runtime.state.session_file,
        .entry_id = id,
        .parent_id = if (parent.len == 0) null else parent,
        .append_ordinal = runtime.state.last_ordinal,
        .entry_type = ty,
        .raw_content_ref = raw,
        .row = .{ .row_id = id, .kind = "unsupported_oversized_entry", .role = "", .status = "display_budget", .content_ref = content },
    });
    try runtime.replace(&runtime.last_entry_id, id);
    try runtime.inspect(raw, "unsupported_oversized_entry", body);
    try runtime.replace(&runtime.state.attention, body);
}
