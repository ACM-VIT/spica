const std = @import("std");
const App = @import("app.zig").App;

pub fn main() !void {
    var app = try App.init(std.heap.page_allocator);
    defer app.deinit();
    try app.run();
}
