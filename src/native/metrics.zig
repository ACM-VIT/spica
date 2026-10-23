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

pub const TextStats = struct {
    fixed_cpu_bytes: usize,
    font_bytes: usize,
    layout_bytes: usize,
    glyph_bytes: usize,
    live_layouts: u32,
    glyph_count: u32,
    face_count: u32,
};

pub const CacheChange = struct {
    event_sequence: u64,
    time_ns: u64,
    before: TextStats,
    after: TextStats,
};

pub const Frame = struct {
    frame_id: u64,
    event_sequence: u64,
    paint_begin_ns: u64,
    present_begin_ns: u64,
    present_end_ns: u64,
    succeeded: bool,
    text_stats: ?TextStats = null,
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
    cache_storage: []CacheChange = &.{},
    cache_count: usize = 0,
    cache_dropped: u64 = 0,
    cache_observation_failures: u64 = 0,

    pub fn observeCache(self: *Metrics, sequence: u64, time_ns: u64, before: ?TextStats, after: ?TextStats) void {
        if (before == null or after == null) {
            self.cache_observation_failures += 1;
            return;
        }
        if (std.meta.eql(before.?, after.?)) return;
        if (self.cache_count == self.cache_storage.len) {
            self.cache_dropped += 1;
            return;
        }
        self.cache_storage[self.cache_count] = .{ .event_sequence = sequence, .time_ns = time_ns, .before = before.?, .after = after.? };
        self.cache_count += 1;
    }

    pub fn cacheSamples(self: *const Metrics) []const CacheChange {
        return self.cache_storage[0..self.cache_count];
    }

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

test "event-boundary cache changes retain exact before after and explicit loss" {
    var changes: [1]CacheChange = undefined;
    var metrics: Metrics = .{ .storage = &.{}, .cache_storage = &changes };
    const before: TextStats = .{ .fixed_cpu_bytes = 1, .font_bytes = 2, .layout_bytes = 3, .glyph_bytes = 4, .live_layouts = 1, .glyph_count = 1, .face_count = 1 };
    metrics.observeCache(1, 10, before, before);
    try std.testing.expectEqual(@as(usize, 0), metrics.cacheSamples().len);
    var after = before;
    after.layout_bytes += 100;
    metrics.observeCache(2, 20, before, after);
    try std.testing.expectEqual(@as(usize, 1), metrics.cacheSamples().len);
    try std.testing.expectEqual(after.layout_bytes, metrics.cacheSamples()[0].after.layout_bytes);
    metrics.observeCache(3, 30, after, before);
    try std.testing.expectEqual(@as(u64, 1), metrics.cache_dropped);
    metrics.observeCache(4, 40, null, before);
    try std.testing.expectEqual(@as(u64, 1), metrics.cache_observation_failures);
}
