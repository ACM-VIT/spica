//! Standalone storage-boundary consumer, not the unfinished Host conversation gate.
//! Abrupt modes deliberately bypass Zig defers to exercise SQLite recovery.
const std = @import("std");
const domain = @import("domain");
const Store = domain.store.Store;
const t = domain.types;
extern "c" fn _exit(status: c_int) noreturn;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len != 4) return error.UsageExpectedStateDirectoryModeAndName;
    var store = try Store.open(io, args[1]);
    defer store.close() catch @panic("storage consumer close failed");
    const mode = args[2];
    const command: t.CommandEnvelope = .{ .command_id = .{ .value = "storage-smoke-command" }, .target = .absent, .expected_revision = .absent, .payload = .{ .project_create = .{ .display_name = args[3] } } };
    var canonical_buffer: [64 * 1024]u8 = undefined;
    const canonical = try t.encode(command, &canonical_buffer);
    var receipt_buffer: [4096]u8 = undefined;
    if (std.mem.eql(u8, mode, "read")) {
        const receipt = try store.lookupCommand(command.command_id.value, canonical, &receipt_buffer);
        try std.Io.File.stdout().writeStreamingAll(io, receipt orelse "absent");
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }
    const crash_before = std.mem.eql(u8, mode, "crash-uncommitted");
    const crash_after = std.mem.eql(u8, mode, "crash-committed");
    if (!crash_before and !crash_after and !std.mem.eql(u8, mode, "write")) return error.UnknownMode;
    // Exact redelivery returns the original bytes, not new IDs/revisions/events.
    if (try store.lookupCommand(command.command_id.value, canonical, &receipt_buffer)) |receipt| {
        try std.Io.File.stdout().writeStreamingAll(io, receipt);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return;
    }
    try store.begin();
    errdefer store.rollback() catch {};
    const sequence = try store.nextSequence();
    const project = t.ProjectId{ .value = "storage-smoke-project" };
    try store.execute("INSERT INTO projects(id,revision,display_name) VALUES(?,1,?)", &.{ .{ .text = project.value }, .{ .text = args[3] } });
    const revisions = [_]t.CommittedRevision{.{ .target = .{ .project = project }, .revision = 1 }};
    const receipt: t.Receipt = .{ .command_id = command.command_id, .outcome = .accepted, .entity_ids = .{ .project = project }, .committed_revisions = &revisions, .commit_sequence = sequence };
    const receipt_bytes = try t.encode(receipt, &receipt_buffer);
    try store.recordCommand(command.command_id.value, canonical, receipt_bytes, sequence);
    try store.appendEvent(.{ .event_id = .{ .value = "storage-smoke-event" }, .position = .{ .commit_sequence = sequence }, .aggregate = .{ .project = project }, .aggregate_revision = 1, .kind = "ProjectCreated", .causation_command_id = command.command_id, .payload = "{}" });
    if (crash_before) _exit(73);
    try store.commit();
    if (crash_after) _exit(74);
    try std.Io.File.stdout().writeStreamingAll(io, receipt_bytes);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
