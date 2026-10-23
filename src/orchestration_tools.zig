//! One schema source for Codex dynamic tools and the app-owned MCP endpoint.
const std = @import("std");
pub const Descriptor = struct { name: []const u8, description: []const u8, input_schema: []const u8 };
const packet_schema =
    \\{"type":"object","additionalProperties":false,"required":["purpose","prompt","selection","owned_paths","acceptance","result_location"],"properties":{"purpose":{"type":"string"},"prompt":{"type":"string"},"selection":{"type":"object","additionalProperties":false,"required":["runtime_kind","required_runtime_version","model_provider","model_id","effort","account_ref","workspace","capability_revision"],"properties":{"runtime_kind":{"type":"string"},"required_runtime_version":{"type":"string"},"model_provider":{"type":"string"},"model_id":{"type":"string"},"effort":{"type":"string"},"account_ref":{"type":"string"},"workspace":{"type":"object","additionalProperties":false,"required":["value"],"properties":{"value":{"type":"string"}}},"capability_revision":{"type":"integer"}}},"owned_paths":{"type":"array","maxItems":32,"items":{"type":"string"}},"acceptance":{"type":"string"},"result_location":{"type":"string"},"detached":{"type":"boolean"},"budget":{"type":"object","additionalProperties":false,"properties":{"max_requests":{"type":"integer","minimum":1,"maximum":32},"max_elapsed_ms":{"type":"integer","minimum":1,"maximum":3600000},"max_tokens":{"type":"integer","minimum":1,"maximum":1000000}}}}}
;
pub const descriptors = [_]Descriptor{
    .{ .name = "task.delegate", .description = "Create one app-owned child in an explicit registered workspace. No recursive fanout. Retry using the same request_key and identical packet; two active children maximum.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"packet\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"packet\":" ++ packet_schema ++ "}}" },
    .{ .name = "task.send", .description = "Send a bounded message to an owned child when its runtime supports messaging. Stable request_key deduplicates retries.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"task_id\",\"content\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"task_id\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}" },
    .{ .name = "task.cancel", .description = "Request cancellation of an owned child; acknowledgement is not proof its tools stopped. Stable request_key deduplicates retries.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"request_key\",\"task_id\",\"reason\"],\"properties\":{\"request_key\":{\"type\":\"string\"},\"task_id\":{\"type\":\"string\"},\"reason\":{\"type\":\"string\"}}}" },
    .{ .name = "task.wait", .description = "Read the current durable state and correlated result of an owned child. Returns pending without blocking generation; call again to observe a later state.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"task_id\"],\"properties\":{\"task_id\":{\"type\":\"string\"}}}" },
    .{ .name = "task.list", .description = "List this coordinator's app-owned children with explicit selections, state, observable usage, evidence and review disposition. Native provider children are excluded.", .input_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}" },
};
test "coordinator descriptors are valid bounded JSON schemas" {
    for (descriptors) |descriptor| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, descriptor.input_schema, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}
