//! Bounded asynchronous configuration VM. No Lua stack/API enters Zig.
//! Native App owns Host admission, command IDs, drain routing and last-good UI.
const std = @import("std");
pub const abi = @cImport({
    @cInclude("script_lua.h");
});
pub const Root = abi.SpicaScriptRoot;
pub const Render = abi.SpicaScriptRender;
pub const Snapshot = abi.SpicaScriptSnapshot;
pub const ActionContext = abi.SpicaScriptActionContext;
pub const Result = abi.SpicaScriptResult;
pub const Id = abi.SpicaScriptId;
pub const Text = abi.SpicaScriptText;
pub const Style = abi.SpicaScriptStyle;
pub const AdmissionError = error{ QueueFull, InvalidInput };

/// Native transport validation; absent fields do not override primitive defaults.
pub fn validateStyle(style: *const Style) error{InvalidStyle}!void {
    if (style.present & ~@as(u32, 255) != 0) return error.InvalidStyle;
    const values = [6]f32{ style.width, style.height, style.gap, style.padding, style.font_size, style.radius };
    const minimum = [6]f32{ 1, 1, 0, 0, 8, 0 };
    const maximum = [6]f32{ 4096, 4096, 128, 128, 72, 64 };
    for (values, minimum, maximum, 0..) |value, low, high, i| {
        if (style.present & (@as(u32, 1) << @intCast(i)) != 0 and
            (!std.math.isFinite(value) or value < low or value > high))
            return error.InvalidStyle;
    }
}

pub const Runtime = struct {
    handle: *abi.SpicaScript,

    pub fn init(vm_bytes: usize, instructions: c_uint, wake: abi.SpicaScriptWake, context: ?*anyopaque) error{OutOfMemory}!Runtime {
        return .{ .handle = abi.spica_script_create(vm_bytes, instructions, wake, context) orelse return error.OutOfMemory };
    }

    /// Refuses disposal until every accepted action result has been consumed.
    /// Caller serializes lifetime against all other API users.
    pub fn deinit(self: *Runtime) error{PendingActions}!void {
        if (abi.spica_script_destroy(self.handle) != 0) return error.PendingActions;
        self.* = undefined;
    }

    pub fn reload(self: *Runtime, sequence: u64, source: []const u8, snapshot: *const Snapshot) AdmissionError!void {
        try admitted(abi.spica_script_reload(self.handle, sequence, source.ptr, source.len, snapshot));
    }

    pub fn render(self: *Runtime, sequence: u64, snapshot: *const Snapshot) AdmissionError!void {
        try admitted(abi.spica_script_render(self.handle, sequence, snapshot));
    }

    pub fn action(self: *Runtime, sequence: u64, generation: u64, action_id: *const Id, payload: *const Text, context: *const ActionContext) AdmissionError!void {
        try admitted(abi.spica_script_action(self.handle, sequence, generation, action_id, payload, context));
    }

    /// Call in response to the payload-free worker wake; never idle-poll.
    pub fn poll(self: *Runtime, out: *Result) bool {
        return abi.spica_script_poll(self.handle, out) != 0;
    }
};

fn admitted(status: c_int) AdmissionError!void {
    switch (status) {
        0 => {},
        1 => return error.QueueFull,
        else => return error.InvalidInput,
    }
}

pub fn id(value: []const u8) error{TooLong}!Id {
    if (value.len > abi.SPICA_SCRIPT_ID) return error.TooLong;
    var result: Id = std.mem.zeroes(Id);
    result.len = value.len;
    @memcpy(result.bytes[0..value.len], value);
    return result;
}

pub fn text(value: []const u8) error{TooLong}!Text {
    if (value.len > abi.SPICA_SCRIPT_TEXT) return error.TooLong;
    var result: Text = std.mem.zeroes(Text);
    result.len = value.len;
    @memcpy(result.bytes[0..value.len], value);
    return result;
}
