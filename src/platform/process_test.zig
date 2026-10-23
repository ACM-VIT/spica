const std = @import("std");
const c = @cImport({
    @cInclude("process.h");
});

const empty = c.SpicaProcess{ .input = -1, .output = -1, .@"error" = -1, .exit_fd = -1, .pid = 0 };

fn finish(process: *c.SpicaProcess) void {
    if (process.pid > 0) {
        _ = c.spica_process_force(process);
        const deadline = c.spica_monotonic_ms() + 2000;
        var status: c_int = 0;
        while (process.pid > 0 and c.spica_monotonic_ms() < deadline) {
            _ = c.spica_process_poll(process, -1, 0, 10);
            _ = c.spica_process_reap(process, &status);
        }
    }
    c.spica_process_dispose(process);
}

test "generic POSIX child roundtrips Unicode bytes and reports exit without a runtime" {
    var process = empty;
    defer finish(&process);
    var argv = [_:null]?[*:0]const u8{"/bin/cat"};
    try std.testing.expectEqual(@as(c_int, 0), c.spica_process_spawn(&process, "/bin/cat", @ptrCast(&argv), "/"));
    const source = "café · مرحبا\n";
    try std.testing.expectEqual(@as(c_long, source.len), c.spica_process_write(process.input, source, source.len));
    c.spica_close(process.input);
    process.input = -1;
    var output: [128]u8 = undefined;
    var length: usize = 0;
    const deadline = c.spica_monotonic_ms() + 2000;
    var status: c_int = 0;
    while (c.spica_monotonic_ms() < deadline) {
        const events = c.spica_process_poll(&process, -1, 0, 20);
        try std.testing.expect(events >= 0);
        const count = c.spica_process_read(process.output, output[length..].ptr, output.len - length);
        if (count > 0) length += @intCast(count);
        if (events & 16 != 0 and c.spica_process_reap(&process, &status) == 1) break;
    }
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expectEqualStrings(source, output[0..length]);
}

test "generic POSIX spawn failure retains no descriptors and an owned child can be stopped" {
    var process = empty;
    defer finish(&process);
    var missing = [_:null]?[*:0]const u8{"/spica-test-missing-executable"};
    try std.testing.expectEqual(@as(c_int, -1), c.spica_process_spawn(&process, missing[0].?, @ptrCast(&missing), "/"));
    try std.testing.expectEqual(empty, process);
    var argv = [_:null]?[*:0]const u8{"/bin/cat"};
    try std.testing.expectEqual(@as(c_int, 0), c.spica_process_spawn(&process, "/bin/cat", @ptrCast(&argv), "/"));
    try std.testing.expectEqual(@as(c_int, 0), c.spica_process_force(&process));
    const deadline = c.spica_monotonic_ms() + 2000;
    var status: c_int = 0;
    while (process.pid > 0 and c.spica_monotonic_ms() < deadline) {
        _ = c.spica_process_poll(&process, -1, 0, 20);
        _ = c.spica_process_reap(&process, &status);
    }
    try std.testing.expectEqual(@as(c_int, 0), process.pid);
    try std.testing.expect(status != 0);
}
