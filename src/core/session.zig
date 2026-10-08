const std = @import("std");
const storage = @import("store.zig");
const Value = std.json.Value;
const limit = @import("attachments.zig").max_command_bytes;
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
        if (std.mem.eql(u8, ty, "text")) try result.appendSlice(a, text(block, "text")) else if (std.mem.eql(u8, ty, "thinking") or std.mem.eql(u8, ty, "toolCall")) continue else if (std.mem.eql(u8, ty, "image")) {
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
    }
    const err = text(message, "errorMessage");
    if (err.len != 0 and !std.mem.eql(u8, result.items, err)) {
        if (result.items.len > 0) try result.appendSlice(a, "\n\n");
        try result.appendSlice(a, err);
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

pub fn toolActivity(name: []const u8, args: Value) storage.Activity {
    var activity: storage.Activity = .{};
    activity.append(if (name.len > 0) name else "Tool");
    inline for (.{ "command", "path", "file_path", "filePath", "target", "url", "query", "pattern" }) |key| {
        const target = text(args, key);
        if (target.len > 0) {
            activity.append(" ");
            var prefix_len = @min(target.len, activity.bytes.len);
            while (prefix_len > 0 and prefix_len < target.len and (target[prefix_len] & 0xc0) == 0x80) prefix_len -= 1;
            var start: usize = 0;
            var cursor: usize = 0;
            while (cursor < prefix_len and activity.len < activity.bytes.len) : (cursor += 1) {
                if (!std.ascii.isWhitespace(target[cursor])) continue;
                activity.append(target[start..cursor]);
                if (activity.len > 0 and activity.bytes[activity.len - 1] != ' ') activity.append(" ");
                start = cursor + 1;
            }
            activity.append(target[start..cursor]);
            break;
        }
    }
    return activity;
}

/// Pi message timestamps are Unix milliseconds. Canonical envelopes also carry
/// UTC ISO dates; keep unknown timestamps zero instead of inventing elapsed time.
pub fn timestamp(value: Value) i64 {
    const stamp = child(value, "timestamp");
    if (stamp == .integer) return stamp.integer;
    if (stamp != .string) return 0;
    const s = stamp.string;
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return 0;
    var year = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) return 0;
    var end: usize = 19;
    var millis: i64 = 0;
    if (s[end] == '.') {
        end += 1;
        const begin = end;
        while (end < s.len and std.ascii.isDigit(s[end])) : (end += 1) {
            if (end - begin < 3) millis = millis * 10 + s[end] - '0';
        }
        if (end == begin) return 0;
        if (end - begin == 1) millis *= 100 else if (end - begin == 2) millis *= 10;
    }
    if (end >= s.len or s[end] != 'Z' or end + 1 != s.len) return 0;
    year -= if (month <= 2) @as(i64, 1) else 0;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const days = era * 146097 + year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year - 719468;
    return ((days * 24 + hour) * 3600 + minute * 60 + second) * 1000 + millis;
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
    const parent_id = text(value, "parentId");
    var activity = toolActivity(text(message, "toolName"), child(message, "args"));
    if (std.mem.eql(u8, role, "toolResult") and tool_id.len > 0) {
        if (try runtime.store.?.toolActivity(runtime.state.session_file, tool_id)) |matched| activity = matched;
    } else if (std.mem.eql(u8, role, "bashExecution")) {
        activity = toolActivity("bash", message);
    } else activity = .{};
    const failed = (error_value == .bool and error_value.bool) or text(message, "errorMessage").len > 0 or std.mem.eql(u8, text(message, "stopReason"), "error");
    const message_timestamp = timestamp(message);
    const stamp = if (message_timestamp != 0) message_timestamp else timestamp(value);
    runtime.state.last_ordinal += 1;
    try runtime.store.?.putEntry(.{
        .session_file = runtime.state.session_file,
        .entry_id = id,
        .parent_id = if (parent_id.len > 0) parent_id else null,
        .append_ordinal = runtime.state.last_ordinal,
        .entry_type = ty,
        .raw_content_ref = raw,
        .row = .{ .row_id = id, .kind = kind, .role = role, .status = if (failed) "failed" else "complete", .content_ref = content, .tool_call_id = if (tool_id.len > 0) tool_id else null, .title = activity.slice(), .is_error = failed, .timestamp = stamp },
    });
    if (is_message) try runtime.store.?.linkLiveEntry(runtime.state.session_file, id, runtime.state.runtime_id, runtime.state.generation);
    if (is_message) {
        const thinking = try thinkingText(a, message);
        defer a.free(thinking);
        const reasoning: ?storage.ReasoningReference = if (thinking.len > 0)
            .{ .content_ref = try runtime.content(thinking, "text/markdown"), .length = thinking.len }
        else
            null;
        try runtime.store.?.putEntryReasoning(runtime.state.session_file, id, reasoning);
        const blocks = child(message, "content");
        if (std.mem.eql(u8, role, "assistant") and blocks == .array) for (blocks.array.items) |block| {
            if (!std.mem.eql(u8, text(block, "type"), "toolCall")) continue;
            const call = text(block, "id");
            if (call.len == 0 or call.len > 4096) continue;
            const metadata_id = storage.toolMetadataId(call);
            const caption = toolActivity(text(block, "name"), child(block, "arguments"));
            runtime.state.last_ordinal += 1;
            try runtime.store.?.putEntry(.{
                .session_file = runtime.state.session_file,
                .entry_id = &metadata_id,
                .parent_id = id,
                .append_ordinal = runtime.state.last_ordinal,
                .entry_type = "tool_call",
                .row = .{ .row_id = &metadata_id, .kind = "tool_metadata", .role = "toolCall", .title = caption.slice(), .tool_call_id = call, .timestamp = stamp },
            });
        };
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

test "canonical tool results retain targets and failures without polluting assistant prose" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/tool-metadata.sqlite", .{tmp.sub_path});
    defer allocator.free(db_path);
    const Runtime = @import("runtime.zig").Runtime;
    var runtime: Runtime = .{
        .allocator = allocator,
        .io = undefined,
        .options = undefined,
        .options_arena = undefined,
        .mutex = undefined,
        .wake = undefined,
        .state = .{ .allocator = allocator, .runtime_id = 42, .session_file = "/session.jsonl" },
        .store = try storage.Store.init(allocator, db_path),
    };
    defer runtime.store.?.deinit();
    defer allocator.free(runtime.last_entry_id);
    try runtime.store.?.putSession(.{ .session_file = runtime.state.session_file, .session_id = "session", .project_id = "project", .leaf_id = "result" });
    const assistant =
        \\{"id":"assistant","type":"message","timestamp":"2026-01-01T00:00:00.123Z","message":{"role":"assistant","content":[{"type":"text","text":"Inspecting the configuration."},{"type":"toolCall","id":"read-config","name":"read","arguments":{"path":"src/config.zig"}}]}}
    ;
    const result =
        \\{"id":"result","parentId":"assistant","type":"message","message":{"role":"toolResult","toolCallId":"read-config","toolName":"read","timestamp":1767225600456,"isError":true,"content":[{"type":"text","text":"Permission denied"}]}}
    ;
    const raw_assistant: storage.ContentId = @splat(240);
    const raw_result: storage.ContentId = @splat(241);
    try runtime.store.?.beginContent(raw_assistant, "utf-8", "application/json");
    try runtime.store.?.append(raw_assistant, 0, assistant, true);
    try runtime.store.?.beginContent(raw_result, "utf-8", "application/json");
    try runtime.store.?.append(raw_result, 0, result, true);
    try putEntry(&runtime, assistant, raw_assistant);
    try putEntry(&runtime, result, raw_result);
    try runtime.store.?.rebuildActivePath(runtime.state.session_file, "result");
    const entries = try runtime.store.?.conversationEntries(allocator, runtime.state.session_file, false, 0, 0);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    const prose = (try runtime.store.?.readChunk(allocator, entries[0].content_id, 0)).?;
    defer allocator.free(prose);
    try std.testing.expectEqualStrings("Inspecting the configuration.", prose);
    try std.testing.expectEqualStrings("read src/config.zig", entries[1].activity[0..entries[1].activity_len]);
    try std.testing.expectEqual(.failed, entries[1].status);
    try std.testing.expectEqual(@as(i64, 1767225600123), entries[0].timestamp);
    try std.testing.expectEqual(@as(i64, 1767225600456), entries[1].timestamp);
    const retained = (try runtime.store.?.readChunk(allocator, raw_assistant, 0)).?;
    defer allocator.free(retained);
    try std.testing.expectEqualStrings(assistant, retained);
}

test "tool activity truncation preserves UTF8 and flattens multiline commands" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Value, allocator, "{\"command\":\"echo one\\n  echo two\"}", .{});
    defer parsed.deinit();
    const command = toolActivity("bash", parsed.value);
    try std.testing.expectEqualStrings("bash echo one echo two", command.slice());
    var buffer: [194]u8 = @splat('a');
    buffer[191] = 0xe2;
    buffer[192] = 0x82;
    buffer[193] = 0xac;
    var activity: storage.Activity = .{};
    activity.append(&buffer);
    try std.testing.expectEqual(@as(u8, 191), activity.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(activity.slice()));
}

test "streaming canonical overlap preserves repeated equal prompts and live assistant" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/overlap.sqlite", .{tmp.sub_path});
    defer a.free(db_path);
    const Runtime = @import("runtime.zig").Runtime;
    var runtime: Runtime = .{
        .allocator = a,
        .io = undefined,
        .options = .{ .database_path = db_path, .project_path = "/project", .node_path = "", .pi_entrypoint = "", .wake_event = 0 },
        .options_arena = undefined,
        .mutex = undefined,
        .wake = undefined,
        .state = .{ .allocator = a, .runtime_id = 42, .status = .streaming, .session_file = "/session.jsonl", .role = "", .kind = "", .content_status = "" },
        .store = try storage.Store.init(a, db_path),
    };
    defer runtime.store.?.deinit();
    defer {
        a.free(runtime.last_entry_id);
        a.free(runtime.leaf_id);
        a.free(runtime.state.role);
        a.free(runtime.state.kind);
        a.free(runtime.state.content_status);
    }
    try runtime.persistSession();
    const stamps = [_]i64{ 100, 100, 200 };
    var prompt_ids: [3]storage.ContentId = undefined;
    for (stamps, 0..) |stamp, i| {
        prompt_ids[i] = try runtime.content("Again", "text/markdown");
        try runtime.store.?.putLiveRow(.{
            .runtime = 42,
            .run_generation = 1,
            .local_sequence = @intCast(i + 1),
            .content_index = 0,
            .row = .{ .row_id = "live-user", .kind = "message", .role = "user", .status = "complete", .timestamp = stamp, .content_ref = prompt_ids[i] },
        });
    }
    const assistant = try runtime.content("Working", "text/markdown");
    try runtime.store.?.putLiveRow(.{
        .runtime = 42,
        .run_generation = 1,
        .local_sequence = 4,
        .content_index = 0,
        .row = .{ .row_id = "live-assistant", .kind = "message", .role = "assistant", .status = "streaming", .timestamp = 300, .content_ref = assistant },
    });
    const responses = [_][]const u8{
        \\{"data":{"entries":[{"id":"first","type":"message","message":{"role":"user","timestamp":100,"content":"Again"}}],"leafId":"first"}}
        ,
        // Re-importing the same canonical ID cannot consume the second equal
        // prompt, even when both prompts have the same timestamp.
        \\{"data":{"entries":[{"id":"first","type":"message","message":{"role":"user","timestamp":100,"content":"Again"}}],"leafId":"first"}}
        ,
        \\{"data":{"entries":[{"id":"second","parentId":"first","type":"message","message":{"role":"user","timestamp":100,"content":"Again"}}],"leafId":"second"}}
        ,
        \\{"data":{"entries":[{"id":"third","parentId":"second","type":"message","message":{"role":"user","timestamp":200,"content":"Again"}}],"leafId":"third"}}
        ,
    };
    var reader = try storage.Store.openReadOnly(a, db_path);
    defer reader.deinit();
    const Source = struct {
        fn next(_: *@This()) !?[]const u8 {
            return null;
        }
    };
    var source: Source = .{};
    for (responses, 0..) |response, step| {
        try reconcile(&runtime, &source, response);
        const transcript = try reader.conversationEntries(a, runtime.state.session_file, false, 42, 1);
        defer a.free(transcript);
        try std.testing.expectEqual(@as(usize, 4), transcript.len);
        for (transcript[0..3]) |entry| {
            try std.testing.expectEqual(.user, entry.role);
            const body = (try reader.readChunk(a, entry.content_id, 0)).?;
            defer a.free(body);
            try std.testing.expectEqualStrings("Again", body);
        }
        const canonical_count: usize = if (step < 2) 1 else step;
        for (transcript[0..canonical_count], 0..) |entry, ordinal| try std.testing.expectEqual(ordinal, entry.ordinal);
        for (transcript[canonical_count..3], canonical_count..) |entry, i| {
            try std.testing.expectEqual(storage.live_ordinal_base + (i + 1) * 512, entry.ordinal);
            try std.testing.expectEqualSlices(u8, &prompt_ids[i], &entry.content_id);
        }
        try std.testing.expectEqual(.assistant, transcript[3].role);
        try std.testing.expectEqual(storage.live_ordinal_base + 4 * 512, transcript[3].ordinal);
        try std.testing.expectEqualSlices(u8, &assistant, &transcript[3].content_id);
        try std.testing.expectEqual(.running, transcript[3].status);
    }
}
