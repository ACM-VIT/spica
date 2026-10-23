//! App-managed task values. Provider-native children are never inserted here.
const c = @import("contract.zig");
pub const Budget = struct {
    max_requests: u16 = 8,
    max_elapsed_ms: u64 = 300000,
    max_tokens: u64 = 100000,
    pub fn valid(self: Budget) bool {
        return self.max_requests > 0 and self.max_requests <= 32 and self.max_elapsed_ms > 0 and self.max_elapsed_ms <= 3600000 and self.max_tokens > 0 and self.max_tokens <= 1000000;
    }
};
pub const Packet = struct {
    purpose: []const u8,
    prompt: []const u8,
    selection: c.Selection,
    owned_paths: []const []const u8,
    acceptance: []const u8,
    result_location: []const u8,
    detached: bool = false,
    budget: Budget = .{},
};
pub const Disposition = enum { accepted, changes_requested, failed, blocked };
pub const Result = struct {
    candidate: []const u8,
    evidence: []const u8,
    summary: []const u8,
};
pub const Task = struct {
    id: c.RunId,
    parent: c.RunId,
    packet: Packet,
    result: ?Result,
    review: ?Disposition,
    requests: u16,
    input_tokens: u64,
    output_tokens: u64,
    cached_tokens: u64,
};
