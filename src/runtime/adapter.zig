//! Host-owned runtime interface. Inputs are borrowed for the call only.
//! dispatch/poll return deep-owned frames in the caller allocator; discover,
//! accountStatus and resolveSelection borrow immutable runtime-owned metadata.
const std = @import("std");
const c = @import("../contract.zig");
pub const ToolCall = struct { request_id_json: []const u8, call_id: []const u8, name: []const u8, arguments_json: []const u8, correlation: c.Correlation };
pub const Adapter = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        discover: *const fn (*anyopaque) c.Discovery,
        accountStatus: *const fn (*anyopaque) c.Account,
        resolveSelection: *const fn (*anyopaque, c.Selection) c.SelectionResult,
        dispatch: *const fn (*anyopaque, std.mem.Allocator, c.Request) anyerror!c.Receipt,
        pump: *const fn (*anyopaque) anyerror!void,
        poll: *const fn (*anyopaque, std.mem.Allocator) anyerror!?c.Observation,
        shutdown: *const fn (*anyopaque) void,
        pollTool: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!?ToolCall = null,
        respondTool: ?*const fn (*anyopaque, []const u8, bool, []const u8) anyerror!void = null,
        /// True when initialization finished, including definitive failure.
        /// Host retains a committed open claim while false; no open is retried.
        ready: ?*const fn (*anyopaque) bool = null,
    };
    pub fn discover(self: Adapter) c.Discovery { return self.vtable.discover(self.context); }
    pub fn accountStatus(self: Adapter) c.Account { return self.vtable.accountStatus(self.context); }
    pub fn resolveSelection(self: Adapter, selection: c.Selection) c.SelectionResult { return self.vtable.resolveSelection(self.context, selection); }
    pub fn dispatch(self: Adapter, allocator: std.mem.Allocator, request: c.Request) !c.Receipt { return self.vtable.dispatch(self.context, allocator, request); }
    pub fn pump(self: Adapter) !void { return self.vtable.pump(self.context); }
    pub fn poll(self: Adapter, allocator: std.mem.Allocator) !?c.Observation { return self.vtable.poll(self.context, allocator); }
    pub fn shutdown(self: Adapter) void { self.vtable.shutdown(self.context); }
    pub fn ready(self: Adapter) bool { return if (self.vtable.ready) |call| call(self.context) else true; }
    pub fn pollTool(self: Adapter, allocator: std.mem.Allocator) !?ToolCall {
        return if (self.vtable.pollTool) |call| call(self.context, allocator) else null;
    }
    pub fn respondTool(self: Adapter, request_id: []const u8, success: bool, result: []const u8) !void {
        const call = self.vtable.respondTool orelse return error.ToolBridgeUnsupported;
        return call(self.context, request_id, success, result);
    }
};

/// A session-scoped MCP endpoint owned by the Host, alive until shutdown.
pub const Bridge = struct { url: []const u8, token: []const u8 };
/// Metadata queries MUST NOT spawn a process or perform external IO. Unknown
/// readiness admits an open claim; the instance handshake remains authoritative.
/// create cleans every partial failure. Host calls shutdown once, then destroy;
/// destroy releases memory only and must not call shutdown again.
pub const Factory = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        discover: *const fn (*anyopaque, c.Selection) c.Discovery,
        accountStatus: *const fn (*anyopaque, c.Selection) c.Account,
        resolveSelection: *const fn (*anyopaque, c.Selection) c.SelectionResult,
        create: *const fn (*anyopaque, std.mem.Allocator, c.Selection, []const u8, c.RuntimeSessionId, ?Bridge) anyerror!Adapter,
        destroy: *const fn (*anyopaque, std.mem.Allocator, Adapter) void,
    };
    pub fn discover(self: Factory, selection: c.Selection) c.Discovery { return self.vtable.discover(self.context, selection); }
    pub fn accountStatus(self: Factory, selection: c.Selection) c.Account { return self.vtable.accountStatus(self.context, selection); }
    pub fn resolveSelection(self: Factory, selection: c.Selection) c.SelectionResult { return self.vtable.resolveSelection(self.context, selection); }
    pub fn create(self: Factory, allocator: std.mem.Allocator, selection: c.Selection, cwd: []const u8, session: c.RuntimeSessionId, bridge: ?Bridge) !Adapter { return self.vtable.create(self.context, allocator, selection, cwd, session, bridge); }
    pub fn destroy(self: Factory, allocator: std.mem.Allocator, instance: Adapter) void { self.vtable.destroy(self.context, allocator, instance); }
};
/// Copies every borrowed string in a contract frame; use an arena for disposal.
pub fn clone(allocator: std.mem.Allocator, value: anytype) !@TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => try allocator.dupe(u8, value),
        .optional => if (value) |v| try clone(allocator, v) else null,
        .@"struct" => blk: { var result: T = undefined; inline for (@typeInfo(T).@"struct".fields) |f| @field(result, f.name) = try clone(allocator, @field(value, f.name)); break :blk result; },
        .@"union" => blk: { inline for (@typeInfo(T).@"union".fields) |f| { if (std.meta.activeTag(value) == @field(std.meta.Tag(T), f.name)) break :blk @unionInit(T, f.name, try clone(allocator, @field(value, f.name))); } unreachable; },
        else => value,
    };
}
test "frames own nested strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    var bytes = [_]u8{'a'};
    const copied = try clone(arena.allocator(), c.Receipt{ .outcome = .rejected, .detail = &bytes });
    bytes[0] = 'b';
    try std.testing.expectEqualStrings("a", copied.detail);
}
