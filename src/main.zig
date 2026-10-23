const std = @import("std");
const App = @import("app.zig").App;
const options_module = @import("options.zig");
const c = @import("native/bindings.zig").c;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    const options = options_module.Options.parse(args) catch |err| {
        std.log.err("Invalid command line: {s}. Use --help for supported options.", .{@errorName(err)});
        return err;
    };
    if (options.help) {
        try std.Io.File.stdout().writeStreamingAll(threaded.io(), options_module.help);
        return;
    }
    var app = App.init(std.heap.page_allocator) catch |err| {
        std.log.err("Native foundation startup failed: {s}; SDL: {s}", .{ @errorName(err), c.SDL_GetError() });
        return err;
    };
    defer app.deinit();
    app.run(options.quit_after_ms) catch |err| {
        std.log.err("Native foundation stopped: {s}; SDL: {s}", .{ @errorName(err), c.SDL_GetError() });
        return err;
    };
}
