const std = @import("std");

const clock = @cImport({
    @cInclude("time.h");
});
pub const ClockMapping = struct {
    native_before_ns: u64,
    native_after_ns: u64,
    host_monotonic_ns: ?u64,
};

pub fn mapClock(get_native_ns: *const fn () callconv(.c) u64) ClockMapping {
    var host: clock.struct_timespec = undefined;
    const before = get_native_ns();
    const ok = clock.clock_gettime(clock.CLOCK_MONOTONIC, &host) == 0;
    const after = get_native_ns();
    return .{
        .native_before_ns = before,
        .native_after_ns = after,
        .host_monotonic_ns = if (ok) @as(u64, @intCast(host.tv_sec)) * 1000000000 + @as(u64, @intCast(host.tv_nsec)) else null,
    };
}

pub const Frame = struct {
    frame_id: u64,
    event_sequence: u64,
    paint_begin_ns: u64,
    present_begin_ns: u64,
    present_end_ns: u64,
    succeeded: bool,
};

/// Storage is allocated once, before the measured loop. Full buffers retain the
/// earliest samples and count every omitted attempt, including failed presents.
pub const Metrics = struct {
    storage: []Frame,
    count: usize = 0,
    attempts: u64 = 0,
    failures: u64 = 0,
    dropped: u64 = 0,
    begin_ns: u64 = 0,
    end_ns: u64 = 0,

    pub fn record(self: *Metrics, frame: Frame) void {
        self.attempts += 1;
        if (!frame.succeeded) self.failures += 1;
        if (self.count == self.storage.len) {
            self.dropped += 1;
            return;
        }
        self.storage[self.count] = frame;
        self.count += 1;
    }

    pub fn samples(self: *const Metrics) []const Frame {
        return self.storage[0..self.count];
    }
};

test "empty one sample failed present and bounded drop accounting" {
    var storage: [1]Frame = undefined;
    var metrics: Metrics = .{ .storage = &storage };
    try std.testing.expectEqual(@as(usize, 0), metrics.samples().len);
    const frame: Frame = .{ .frame_id = 1, .event_sequence = 0, .paint_begin_ns = 10, .present_begin_ns = 20, .present_end_ns = 30, .succeeded = true };
    metrics.record(frame);
    try std.testing.expectEqual(@as(usize, 1), metrics.samples().len);
    var failed = frame;
    failed.succeeded = false;
    metrics.record(failed);
    try std.testing.expectEqual(@as(u64, 2), metrics.attempts);
    try std.testing.expectEqual(@as(u64, 1), metrics.failures);
    try std.testing.expectEqual(@as(u64, 1), metrics.dropped);
    try std.testing.expectEqual(frame, metrics.samples()[0]);
}
