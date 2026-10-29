const std = @import("std");
const Id = @import("transcript.zig").Id;

pub const Action = enum { archive, restore, delete };
pub const Request = struct { id: Id, action: Action };
pub const Metadata = struct { id: Id, pinned: bool, settled: bool, snoozed_until: i64, sort_order: i64 = 0 };
pub const Restore = struct { id: Id, navigate: bool = false };
pub const UndoOperation = union(enum) { metadata: Metadata, restore: Restore };
pub const Undo = struct {
    operation: UndoOperation,
    expires_at: i64,
    label: [32]u8 = @splat(0),
    label_len: usize = 0,
};

/// One outstanding lifecycle request and one short-lived Undo claim. Domain
/// revisions/commands stay with App. Taking Undo consumes it before any await.
pub const State = struct {
    requested: ?Request = null,
    pending: bool = false,
    confirming: ?Id = null,
    confirm_delete_selected: bool = false,
    error_bytes: [160]u8 = @splat(0),
    error_len: usize = 0,
    undo: ?Undo = null,
    shortcut_claimed: bool = false,

    pub fn request(self: *State, id: Id, action: Action) void {
        if (self.pending or self.requested != null) return;
        self.error_len = 0;
        if (action == .delete) {
            self.confirming = id;
            self.confirm_delete_selected = false;
        } else self.requested = .{ .id = id, .action = action };
    }
    pub fn confirmDelete(self: *State) void {
        if (self.pending or self.requested != null) return;
        self.requested = .{ .id = self.confirming orelse return, .action = .delete };
    }
    pub fn take(self: *State) ?Request {
        if (self.pending) return null;
        const value = self.requested orelse return null;
        self.requested = null;
        self.pending = true;
        return value;
    }
    pub fn finish(self: *State, failure: ?[]const u8) void {
        self.pending = false;
        self.requested = null;
        if (failure) |message| {
            const value = @import("../text/utf8.zig").prefix(message, self.error_bytes.len);
            @memcpy(self.error_bytes[0..value.len], value);
            self.error_len = value.len;
        } else {
            self.confirming = null;
            self.error_len = 0;
        }
    }
    pub fn offerUndo(self: *State, operation: UndoOperation, label: []const u8, now: i64) void {
        var undo: Undo = .{ .operation = operation, .expires_at = now + 5000 };
        const value = @import("../text/utf8.zig").prefix(label, undo.label.len);
        @memcpy(undo.label[0..value.len], value);
        undo.label_len = value.len;
        self.undo = undo;
        self.shortcut_claimed = true;
    }
    pub fn takeUndo(self: *State, now: i64) ?UndoOperation {
        const undo = self.undo orelse return null;
        self.undo = null;
        self.shortcut_claimed = false;
        return if (now < undo.expires_at) undo.operation else null;
    }
    pub fn invalidateUndo(self: *State, id: Id) void {
        const undo = self.undo orelse return;
        const owner = switch (undo.operation) {
            .metadata => |metadata| metadata.id,
            .restore => |owner| owner.id,
        };
        if (owner.eql(id.slice())) {
            self.undo = null;
            self.shortcut_claimed = false;
        }
    }
};

test "sidebar lifecycle confirms deletion and retains bounded errors for retry" {
    var state: State = .{};
    const id = try Id.init("stable");
    state.request(id, .archive);
    try std.testing.expect(state.confirming == null);
    try std.testing.expectEqual(Action.archive, state.take().?.action);
    try std.testing.expect(state.take() == null);
    state.finish("Busy");
    try std.testing.expectEqualStrings("Busy", state.error_bytes[0..state.error_len]);
    state.request(id, .delete);
    try std.testing.expect(state.take() == null);
    try std.testing.expect(!state.confirm_delete_selected);
    state.confirmDelete();
    try std.testing.expectEqual(Action.delete, state.take().?.action);
    state.finish("Active runtime");
    try std.testing.expect(state.confirming != null);
    state.confirmDelete();
    try std.testing.expect(state.take() != null);
    state.finish(null);
    try std.testing.expect(state.confirming == null);
}

test "sidebar Undo restores exact flags expires and consumes once before await" {
    var state: State = .{};
    const id = try Id.init("stable");
    state.offerUndo(.{ .metadata = .{ .id = id, .pinned = true, .settled = false, .snoozed_until = 8765, .sort_order = -1024 } }, "Settled", 1000);
    const claim = state.takeUndo(5999).?.metadata;
    try std.testing.expect(claim.pinned and !claim.settled);
    try std.testing.expectEqual(@as(i64, 8765), claim.snoozed_until);
    try std.testing.expectEqual(@as(i64, -1024), claim.sort_order);
    try std.testing.expect(state.takeUndo(5999) == null);
    state.offerUndo(.{ .restore = .{ .id = id, .navigate = true } }, "Archived", 1000);
    try std.testing.expect(state.takeUndo(6000) == null);
}
