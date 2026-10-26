//! One schema source for Codex dynamic tools and the app-owned MCP endpoint.
const std = @import("std");
const orchestration = @import("orchestration.zig");
/// The canonical form is shared by both transports and the durable request-key
/// digest. Validate the method's exact fields before reserving any command.
pub const Arguments = struct {
    request_key: ?[]const u8 = null,
    packet: ?orchestration.Packet = null,
    task_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    candidate: ?[]const u8 = null,
    evidence: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    disposition: ?[]const u8 = null,
};

pub fn parseArguments(allocator: std.mem.Allocator, name: []const u8, json: []const u8) !Arguments {
    if (json.len > 16384) return error.Limit;
    const required: []const []const u8 = if (std.mem.eql(u8, name, "task.delegate"))
        &.{ "request_key", "packet" }
    else if (std.mem.eql(u8, name, "task.send"))
        &.{ "request_key", "task_id", "content" }
    else if (std.mem.eql(u8, name, "task.cancel"))
        &.{ "request_key", "task_id", "reason" }
    else if (std.mem.eql(u8, name, "task.result"))
        &.{ "request_key", "task_id", "candidate", "evidence", "summary" }
    else if (std.mem.eql(u8, name, "task.review"))
        &.{ "request_key", "task_id", "candidate", "evidence", "disposition" }
    else if (std.mem.eql(u8, name, "task.wait"))
        &.{"task_id"}
    else if (std.mem.eql(u8, name, "task.list") or std.mem.eql(u8, name, "task.catalog"))
        &.{}
    else
        return error.UnsupportedTool;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
    if (value != .object or value.object.count() != required.len) return error.InvalidToolArguments;
    for (required) |key| {
        const field = value.object.get(key) orelse return error.InvalidToolArguments;
        if (std.mem.eql(u8, key, "packet")) {
            if (field != .object) return error.InvalidToolArguments;
        } else {
            if (field != .string or field.string.len == 0) return error.InvalidToolArguments;
            if (std.mem.eql(u8, key, "request_key") and field.string.len > 256) return error.InvalidToolArguments;
            if (std.mem.eql(u8, key, "disposition") and std.meta.stringToEnum(orchestration.Disposition, field.string) == null) return error.InvalidToolArguments;
        }
    }
    return std.json.parseFromValueLeaky(Arguments, allocator, value, .{ .allocate = .alloc_always });
}

pub const Descriptor = struct { name: []const u8, description: []const u8, input_schema: []const u8 };
const packet_schema =
    \\{"type":"object","additionalProperties":false,"required":["purpose","prompt","selection","owned_paths","acceptance","result_location"],"properties":{"purpose":{"type":"string"},"prompt":{"type":"string"},"selection":{"type":"object","additionalProperties":false,"required":["runtime_kind","required_runtime_version","model_provider","model_id","effort","account_ref","workspace","capability_revision"],"properties":{"runtime_kind":{"type":"string"},"required_runtime_version":{"type":"string"},"model_provider":{"type":"string"},"model_id":{"type":"string"},"effort":{"type":"string"},"account_ref":{"type":"string"},"workspace":{"type":"object","additionalProperties":false,"required":["value"],"properties":{"value":{"type":"string"}}},"capability_revision":{"type":"integer"}}},"owned_paths":{"type":"array","maxItems":32,"items":{"type":"string"}},"acceptance":{"type":"string"},"result_location":{"type":"string"},"detached":{"type":"boolean"},"budget":{"type":"object","additionalProperties":false,"properties":{"max_requests":{"type":"integer","minimum":1,"maximum":32},"max_elapsed_ms":{"type":"integer","minimum":1,"maximum":3600000},"max_tokens":{"type":"integer","minimum":1,"maximum":1000000}}}}}
;
pub const descriptors = [_]Descriptor{
    .{ .name = "task.delegate", .description = "Create one app-owned child in an explicit registered workspace. No recursive fanout. Retry using the same session-scoped request_key and identical packet, including after restart. New work requires a new key; two active children maximum.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"packet\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"packet\":" ++ packet_schema ++ "}}" },
    .{ .name = "task.send", .description = "Send a bounded message to an owned child when its runtime supports messaging. Stable request_key deduplicates retries.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"task_id\",\"content\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"task_id\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}" },
    .{ .name = "task.cancel", .description = "Request cancellation of an owned child; acknowledgement is not proof its tools stopped. Stable request_key deduplicates retries.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"task_id\",\"reason\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"task_id\":{\"type\":\"string\"},\"reason\":{\"type\":\"string\"}}}" },
    .{ .name = "task.wait", .description = "Read the current durable state and correlated result of an owned child. Reads an explicitly owned task across coordinator turns. Interrupted or unknown work is never replayed; this does not block generation.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"task_id\"],\"properties\":{\"task_id\":{\"type\":\"string\"}}}" },
    .{ .name = "task.list", .description = "List the current coordinator turn's app-owned children with explicit selections, state, observable usage, evidence and review disposition. Native provider children are excluded.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}" },
    .{ .name = "task.catalog", .description = "Discover the bounded model catalog currently loaded by Spica, including exact runtime, provider, model and effort identities. This is a snapshot, not an entitlement claim.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}" },
    .{ .name = "task.result", .description = "Submit a child's explicit candidate, evidence and summary after it reaches a terminal state. The parent coordinator remains the authority; provider text is never accepted implicitly.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"task_id\",\"candidate\",\"evidence\",\"summary\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"task_id\":{\"type\":\"string\"},\"candidate\":{\"type\":\"string\"},\"evidence\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"}}}" },
    .{ .name = "task.review", .description = "Record a review disposition for a submitted child result. Candidate and evidence must match the stored result exactly.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"task_id\",\"candidate\",\"evidence\",\"disposition\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"task_id\":{\"type\":\"string\"},\"candidate\":{\"type\":\"string\"},\"evidence\":{\"type\":\"string\"},\"disposition\":{\"type\":\"string\",\"enum\":[\"accepted\",\"changes_requested\",\"failed\",\"blocked\"]}}}" },
};
test "coordinator descriptors are valid bounded JSON schemas" {
    for (descriptors) |descriptor| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, descriptor.input_schema, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}

test "tool methods reject ignored cross-method fields nulls and invalid dispositions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { name: []const u8, json: []const u8 }{
        .{ .name = "task.list", .json = "{\"task_id\":\"child\"}" },
        .{ .name = "task.catalog", .json = "{\"request_key\":\"ignored\"}" },
        .{ .name = "task.wait", .json = "{\"task_id\":\"child\",\"content\":\"ignored\"}" },
        .{ .name = "task.wait", .json = "{\"task_id\":null}" },
        .{ .name = "task.send", .json = "{\"request_key\":\"key\",\"task_id\":\"child\",\"content\":\"message\",\"reason\":null}" },
        .{ .name = "task.cancel", .json = "{\"request_key\":\"key\",\"task_id\":\"child\",\"reason\":\"\"}" },
        .{ .name = "task.result", .json = "{\"request_key\":\"key\",\"task_id\":\"child\",\"candidate\":\"sha\",\"evidence\":\"log\"}" },
        .{ .name = "task.review", .json = "{\"request_key\":\"key\",\"task_id\":\"child\",\"candidate\":\"sha\",\"evidence\":\"log\",\"disposition\":\"maybe\"}" },
    };
    for (cases) |case| try std.testing.expectError(error.InvalidToolArguments, parseArguments(allocator, case.name, case.json));
    try std.testing.expectError(error.UnsupportedTool, parseArguments(allocator, "task.unknown", "{}"));
    _ = try parseArguments(allocator, "task.list", "{}");
    _ = try parseArguments(allocator, "task.catalog", "{}");
    const args = try parseArguments(allocator, "task.wait", "{\"task_id\":\"child\"}");
    try std.testing.expectEqualStrings("child", args.task_id.?);
}
