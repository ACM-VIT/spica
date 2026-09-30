const std = @import("std");
const App = @import("app.zig").App;
const options_module = @import("options.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    const options = options_module.Options.parse(args) catch |err| {
        std.log.err("Invalid command line: {s}. Use --help for supported options.", .{@errorName(err)});
        return err;
    };
    if (options.help) {
        try std.Io.File.stdout().writeStreamingAll(io, options_module.help);
        return;
    }
    var app = App.init(std.heap.page_allocator, io, init.environ, options) catch |err| {
        std.log.err("Spica startup failed: {s}; data directory: {s}", .{ @errorName(err), options.data_dir orelse "platform default" });
        return err;
    };
    defer app.deinit();
    try app.run();
}
