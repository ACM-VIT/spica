const std = @import("std");
const App = @import("app.zig").App;

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var app = try App.init(std.heap.page_allocator, threaded.io());
    defer app.deinit();
    try app.run();
}
