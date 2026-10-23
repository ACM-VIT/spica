const std = @import("std");
const script = @import("script.zig");
const c = @cImport({
    @cInclude("unistd.h");
});
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const good =
    \\return {
    \\root=function(s) return {kind='column',id='root',children={
    \\{kind='text',id='revision',text=s.revision},
    \\{kind='transcript',id='history'}, {kind='composer',id='draft'},
    \\{kind='button',id='send-button',text='Send',action='send'}}} end,
    \\render_block=function(s) return {text='custom:'..s.text,format='plain'} end,
    \\action=function(id,payload) return {kind='send',text=payload} end }
;
var wakes = std.atomic.Value(u32).init(0);
fn wake(_: ?*anyopaque) callconv(.c) void {
    _ = wakes.fetchAdd(1, .monotonic);
}
fn wait(runtime: *script.Runtime, result: *script.Result) !void {
    for (0..10000) |_| {
        if (runtime.poll(result)) return;
        _ = c.usleep(1000);
    }
    return error.WorkerTimeout;
}
fn snapshot() !script.Snapshot {
    return .{ .revision = std.math.maxInt(u64), .text = try script.text("héllo\x00世界") };
}

test "real Lua composition, lossless u64/bytes, protected failures retain last good" {
    var runtime = try script.Runtime.init(256 * 1024, 100000, wake, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, good, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(u64, 1), result.generation);
    try equal(@as(usize, 5), result.root.count);
    try std.testing.expectEqualStrings("18446744073709551615", result.root.text[0..20]);
    const expected = "custom:héllo\x00世界";
    try std.testing.expectEqualStrings(expected, result.render.bytes[0..result.render.len]);
    try expect(wakes.load(.monotonic) > 0);
    const invalid = [_][]const u8{
        "not valid Lua!",
        "error('staging failure')",
        "host.submit({})",
        "while true do end",
        "local a={} while true do a[#a+1]=a end",
        "setmetatable({}, {__gc=function() while true do end end})",
        "return {root=function() return {kind='unknown',id='bad'} end, action=function()end}",
        "return {root=function() host.submit({}) end, render_block=function()end, action=function()end}",
        "return {root=function() local t={kind='column',id='x'} t.children={t}; return t end, action=function()end}",
    };
    for (invalid, 2..) |source, sequence| {
        try runtime.reload(sequence, source, &input);
        try wait(&runtime, &result);
        try expect(result.status != 0);
        try equal(@as(u64, 1), result.generation);
        try equal(@as(usize, 5), result.root.count);
        try std.testing.expectEqualStrings(expected, result.render.bytes[0..result.render.len]);
        try runtime.render(sequence + 100, &input);
        try wait(&runtime, &result);
        try equal(@as(c_int, 0), result.status);
        try equal(@as(u64, 1), result.generation);
    }
    try runtime.reload(200, good, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(u64, 2), result.generation);
    const id = try script.id("send");
    const payload = try script.text("exact\x00payload");
    var context = std.mem.zeroes(script.ActionContext);
    context.thread_id = try script.id("original-thread");
    context.revision = std.math.maxInt(u64);
    try runtime.action(201, 1, &id, &payload, &context);
    try wait(&runtime, &result);
    try expect(result.status != 0);
    try equal(@as(c_int, 0), result.intent.kind);
    try runtime.action(202, 2, &id, &payload, &context);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(c_int, 1), result.intent.kind);
    try std.testing.expectEqualStrings("exact\x00payload", result.intent.text.bytes[0..result.intent.text.len]);
    try equal(std.math.maxInt(u64), result.intent.context.revision);
    try std.testing.expectEqualStrings("original-thread", result.intent.context.thread_id.bytes[0..result.intent.context.thread_id.len]);
}

test "finite action slots retain every accepted identity and refuse early disposal" {
    var runtime = try script.Runtime.init(256 * 1024, 100000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, good, &input);
    try wait(&runtime, &result);
    const id = try script.id("send");
    const payload = try script.text("payload");
    const context = std.mem.zeroes(script.ActionContext);
    for (0..8) |i| try runtime.action(i + 10, 1, &id, &payload, &context);
    try std.testing.expectError(error.QueueFull, runtime.action(99, 1, &id, &payload, &context));
    try std.testing.expectError(error.PendingActions, runtime.deinit());
    for (0..8) |i| {
        try wait(&runtime, &result);
        try equal(@as(u64, i + 10), result.sequence);
        try equal(@as(c_int, 0), result.status);
    }
    for (0..1000) |i| try runtime.render(i + 100, &input);
    while (true) {
        try wait(&runtime, &result);
        if (result.sequence == 1099) break;
    }
    try equal(@as(c_int, 0), result.status);
}

test "state allocation failure is protected and cleaned" {
    var runtime = try script.Runtime.init(64, 10000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, good, &input);
    try wait(&runtime, &result);
    try expect(result.status != 0);
    try equal(@as(u64, 0), result.generation);
    try equal(@as(usize, 0), result.root.count);
}

test "active render and action failures preserve output and revoke proposals" {
    const source =
        \\return {
        \\root=function(s)
        \\ if s.text == 'render-error' then error('render failed') end
        \\ if s.text == 'render-loop' then while true do end end
        \\ if s.text == 'render-oom' then local t='x'; while true do t=t..t end end
        \\ return {kind='button',id='button',action='go',text='retained'} end,
        \\render_block=function(s) return {format='plain',text='retained renderer'} end,
        \\action=function(id,p)
        \\ if p == 'loop' then while true do end end
        \\ if p == 'oom' then local t='x'; while true do t=t..t end end
        \\ if p == 'partial' then return {kind='send',text={}} end
        \\ if p == 'effect' then host.submit({}) end
        \\ return {kind='cancel'} end }
    ;
    var runtime = try script.Runtime.init(64 * 1024, 100000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, source, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    for ([_][]const u8{ "render-error", "render-loop", "render-oom" }, 2..) |value, sequence| {
        input.text = try script.text(value);
        try runtime.render(sequence, &input);
        try wait(&runtime, &result);
        try expect(result.status != 0);
        try equal(@as(u64, 1), result.generation);
        try std.testing.expectEqualStrings("retained", result.root.text[0..result.root.text_len]);
        try std.testing.expectEqualStrings("retained renderer", result.render.bytes[0..result.render.len]);
    }
    const id = try script.id("go");
    const context = std.mem.zeroes(script.ActionContext);
    for ([_][]const u8{ "loop", "oom", "partial", "effect" }, 10..) |value, sequence| {
        const payload = try script.text(value);
        try runtime.action(sequence, 1, &id, &payload, &context);
        try wait(&runtime, &result);
        try expect(result.status != 0);
        try equal(@as(c_int, 0), result.intent.kind);
        try equal(@as(usize, 0), result.intent.text.len);
    }
    const payload = try script.text("");
    const unknown = try script.id("not-declared");
    try runtime.action(20, 1, &unknown, &payload, &context);
    try wait(&runtime, &result);
    try expect(result.status != 0);
    try runtime.action(21, 2, &id, &payload, &context);
    try wait(&runtime, &result);
    try expect(result.status != 0);
    try runtime.action(22, 1, &id, &payload, &context);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(c_int, 2), result.intent.kind);
}

test "descriptor allocation boundaries and forbidden finalizer capabilities" {
    var runtime = try script.Runtime.init(64 * 1024, 100000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    const invalid = [_][]const u8{
        "return {root=function()return {kind='column',id='x',children={{kind='text',id='x'}}}end,render_block=function()end,action=function()end}",
        "return {root=function()return {kind='text',id='x',children={}}end,render_block=function()end,action=function()end}",
        "local t='x'; while true do t=t..t end",
        "return {root=function()return {kind='text',id='x',text={}}end,render_block=function()end,action=function()end}",
        "assert(setmetatable == nil and getmetatable == nil); error('no finalizers')",
        "assert(pcall == nil and xpcall == nil and coroutine == nil and debug == nil); error('no budget escape')",
    };
    for (invalid, 1..) |source, sequence| {
        try runtime.reload(sequence, source, &input);
        try wait(&runtime, &result);
        try expect(result.status != 0);
        try equal(@as(u64, 0), result.generation);
    }
    try runtime.reload(100, good, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(u64, 1), result.generation);
    var invalid_snapshot = input;
    invalid_snapshot.text.len = script.abi.SPICA_SCRIPT_TEXT + 1;
    try std.testing.expectError(error.InvalidInput, runtime.render(101, &invalid_snapshot));
    var invalid_id = try script.id("go");
    invalid_id.len = script.abi.SPICA_SCRIPT_ID + 1;
    const payload = try script.text("");
    const context = std.mem.zeroes(script.ActionContext);
    try std.testing.expectError(error.InvalidInput, runtime.action(102, 1, &invalid_id, &payload, &context));
}

fn waitWakes(count: u32) !void {
    for (0..10000) |_| {
        if (wakes.load(.acquire) >= count) return;
        _ = c.usleep(1000);
    }
    return error.WorkerTimeout;
}

test "successful reload revokes completed but unconsumed action proposals" {
    wakes.store(0, .release);
    var runtime = try script.Runtime.init(256 * 1024, 100000, wake, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, good, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try waitWakes(1);
    const action_id = try script.id("send");
    const payload = try script.text("must not escape old generation");
    const context = std.mem.zeroes(script.ActionContext);
    try runtime.action(2, 1, &action_id, &payload, &context);
    try waitWakes(2); // Action completed, but its proposal is still owned by VM.
    try runtime.reload(3, good, &input);
    try waitWakes(3); // Successful replacement revoked the queued old proposal.
    try expect(runtime.poll(&result));
    try equal(@as(u64, 2), result.sequence);
    try equal(@as(u64, 1), result.generation);
    try expect(result.status != 0);
    try equal(@as(c_int, 0), result.intent.kind);
    try equal(@as(usize, 0), result.intent.text.len);
    try expect(runtime.poll(&result));
    try equal(@as(u64, 3), result.sequence);
    try equal(@as(u64, 2), result.generation);
    try equal(@as(c_int, 0), result.status);
}
