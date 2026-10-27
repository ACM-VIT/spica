//! Bounded display text for retained provider diagnostics. Raw evidence stays
//! with the caller; the returned slice owns bytes in the caller's output.
const std = @import("std");
const utf8 = @import("utf8.zig");
const fallback = "Provider failed. Copy diagnostics (Ctrl+Shift+C) for details.";
const input_limit = 8192;

fn copy(output: []u8, text: []const u8) []const u8 {
    const valid = if (std.unicode.utf8ValidateSlice(text)) text else fallback;
    const bytes = utf8.prefix(valid, output.len);
    @memcpy(output[0..bytes.len], bytes);
    // Keep the notice on one line and never send control bytes to a label.
    for (output[0..bytes.len]) |*byte| if (byte.* < 0x20 or byte.* == 0x7f) {
        byte.* = ' ';
    };
    return output[0..bytes.len];
}

// Check nesting before the DOM parser. Escaped quotes and braces in strings
// do not count. Both the scan and allocation budget are independent of history.
fn shallow(input: []const u8) bool {
    if (input.len > input_limit) return false;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (input) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                depth += 1;
                if (depth > 8) return false;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return !quoted and depth == 0;
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(name) else null;
}

fn extract(allocator: std.mem.Allocator, input: []const u8, depth: usize) ?[]const u8 {
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len == 0) return null;
    if (text[0] != '{' and text[0] != '[' and text[0] != '"') return text;
    if (depth == 3 or !shallow(text)) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{ .allocate = .alloc_always, .max_value_len = input_limit }) catch return null;
    // All nodes live in the fixed scratch allocator until the final copy.
    if (value == .string) return extract(allocator, value.string, depth + 1);
    if (field(value, "message")) |message| if (message == .string and message.string.len != 0) return message.string;
    if (field(value, "failure")) |failure| {
        if (field(failure, "detail")) |detail| if (detail == .string) return extract(allocator, detail.string, depth + 1);
    }
    for ([_][]const u8{ "disconnect", "ambiguous" }) |kind| {
        if (field(value, kind)) |detail| {
            if (field(detail, "reason")) |reason| if (reason == .string and reason.string.len != 0) return reason.string;
        }
    }
    return null;
}

pub fn readable(input: []const u8, output: []u8) []const u8 {
    if (input.len > input_limit) return copy(output, fallback);
    var scratch: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    return copy(output, extract(fixed.allocator(), input, 0) orelse fallback);
}

test "provider diagnostic display decodes nested messages and owns Unicode output" {
    var output: [128]u8 = undefined;
    const nested = "{\"failure\":{\"code\":\"failed\",\"detail\":\"{\\\"message\\\":\\\"Quota exhausted café 世界\\\",\\\"codexErrorInfo\\\":{\\\"other\\\":1}}\"}}";
    try std.testing.expectEqualStrings("Quota exhausted café 世界", readable(nested, &output));
    try std.testing.expectEqualStrings("Login expired", readable("{\"failure\":{\"detail\":\"Login expired\"}}", &output));
    try std.testing.expectEqualStrings("lost", readable("{\"disconnect\":{\"reason\":\"lost\"}}", &output));
    try std.testing.expectEqualStrings("Retry soon", readable("{\"message\":\"Retry\\nsoon\"}", &output));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("caf", readable("café", &tiny));
    try std.testing.expectEqualStrings("", readable("message", output[0..0]));
}

test "provider diagnostic display refuses malformed deep oversized and exhausted JSON" {
    var output: [128]u8 = undefined;
    const cases = [_][]const u8{
        "{\"failure\":",
        "{\"failure\":{\"detail\":\"{bad\"}}",
        "{\"message\":27}",
        "{\"message\":\"\\ud800\"}",
        "[[[[[[[[[0]]]]]]]]]",
        "[" ++ ("0," ** 4095) ++ "0]",
        "[" ++ ("{}," ** 2000) ++ "{}]",
    };
    for (cases) |input| try std.testing.expectEqualStrings(fallback, readable(input, &output));
    try std.testing.expectEqualStrings("escaped { [ \\\"", readable("{\"message\":\"escaped { [ \\\\\\\"\"}", &output));
}
