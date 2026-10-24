const std = @import("std");
const script = @import("script.zig");
const design = @import("ui/design.zig");
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

fn moduleForRoot(root: []const u8) ![]u8 {
    return std.mem.concat(std.testing.allocator, u8, &.{
        "return {root=function(s) return ", root,
        " end,render_block=function(s) return {text='styled:'..s.text,format='plain'} end," ++
            "action=function(id,payload) return {kind='send',text=payload} end}",
    });
}

test "native design validates defaults, masks, every metric bound and finite conversion" {
    const defaults: design.Config = .{};
    try defaults.validate();
    var root = std.mem.zeroes(script.Root);
    try std.testing.expectEqualDeep(defaults, try design.Config.fromScript(&root));
    // Numeric backing slots without a presence bit must remain ignored.
    root.design.layout[0] = std.math.nan(f32);
    try std.testing.expectEqualDeep(defaults, try design.Config.fromScript(&root));
    root.design.layout_present = 1;
    try std.testing.expectError(error.InvalidDesign, design.Config.fromScript(&root));
    root.design.layout[0] = 272;
    root.design.colors_present = 1 << 10;
    try std.testing.expectError(error.InvalidDesign, design.Config.fromScript(&root));
    root.design.colors_present = 0;
    root.design.layout_present = 1 << 7;
    try std.testing.expectError(error.InvalidDesign, design.Config.fromScript(&root));
    inline for (std.meta.fields(design.Metrics), 0..) |field_info, i| {
        root.design.layout_present = @as(u32, 1) << i;
        for ([_]f32{ design.metric_min[i], design.metric_max[i] }) |value| {
            root.design.layout[i] = value;
            const config = try design.Config.fromScript(&root);
            try equal(value, @field(config.layout, field_info.name));
        }
        for ([_]f32{ design.metric_min[i] - 1, design.metric_max[i] + 1, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |value| {
            root.design.layout[i] = value;
            try std.testing.expectError(error.InvalidDesign, design.Config.fromScript(&root));
            var config = defaults;
            @field(config.layout, field_info.name) = value;
            try std.testing.expectError(error.InvalidDesign, config.validate());
        }
    }
}

test "Lua design and every node style field decode exactly while legacy modules retain defaults" {
    const source = try moduleForRoot(
        "{kind='column',id='root'," ++
            "design={colors={background='#010203',sidebar='#040506',surface='#070809',raised='#0a0b0c'," ++
            "border='#0d0e0f',foreground='#F0F1F2',muted='#818181',accent='#346BF1',accent_text='#FFFFFF',selection='#343a47'}," ++
            "layout={sidebar_width=300,content_width=960,header_height=64,composer_height=192,gutter=32,gap=16,radius=8}}," ++
            "style={width=4096,height=1,gap=0,padding=128,font_size=72,radius=64,background='#00aAfF',foreground='#fEfDfC'}," ++
            "children={{kind='text',id='unicode',text='héllo 世界',style={font_size=8}},{kind='composer',id='draft'}}}",
    );
    defer std.testing.allocator.free(source);
    var runtime = try script.Runtime.init(256 * 1024, 100000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, source, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(u32, 0x3ff), result.root.design.colors_present);
    try equal(@as(u32, 0x7f), result.root.design.layout_present);
    const config = try design.Config.fromScript(&result.root);
    try equal(@as(f32, 300), config.layout.sidebar_width);
    try equal(@as(f32, 192), config.layout.composer_height);
    try std.testing.expectEqualDeep(design.Color{ .r = 1, .g = 2, .b = 3 }, config.colors.background);
    try std.testing.expectEqualDeep(design.Color{ .r = 240, .g = 241, .b = 242 }, config.colors.foreground);
    const style = &result.root.nodes[0].style;
    try script.validateStyle(style);
    try equal(@as(u32, 255), style.present);
    try equal(@as(f32, 4096), style.width);
    try equal(@as(f32, 1), style.height);
    try equal(@as(f32, 0), style.gap);
    try equal(@as(f32, 128), style.padding);
    try equal(@as(f32, 72), style.font_size);
    try equal(@as(f32, 64), style.radius);
    try std.testing.expectEqualSlices(u8, &.{ 0, 170, 255 }, &style.background);
    try std.testing.expectEqualSlices(u8, &.{ 254, 253, 252 }, &style.foreground);
    try equal(@as(u32, script.abi.SPICA_STYLE_FONT_SIZE), result.root.nodes[1].style.present);
    try equal(@as(u32, 0), result.root.nodes[2].style.present);
    try std.testing.expectEqualStrings("héllo 世界", result.root.text[0..result.root.text_len]);
    try std.testing.expectEqualStrings("styled:héllo\x00世界", result.render.bytes[0..result.render.len]);
    // Reloading an existing module clears all optional configuration and style.
    try runtime.reload(2, good, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(u64, 2), result.generation);
    try std.testing.expectEqualDeep(design.Config{}, try design.Config.fromScript(&result.root));
    for (result.root.nodes[0..result.root.count]) |node| try equal(@as(u32, 0), node.style.present);
}

test "strict native, design and style failures preserve the entire installed visual result" {
    const valid = try moduleForRoot("{kind='native',id='native',design={colors={background='#090909'},layout={sidebar_width=280}},style={}}");
    defer std.testing.allocator.free(valid);
    var runtime = try script.Runtime.init(256 * 1024, 100000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, valid, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(c_int, 6), result.root.nodes[0].kind);
    try equal(@as(u16, std.math.maxInt(u16)), result.root.nodes[0].parent);
    try equal(@as(usize, 1), result.root.count);
    const last_root = result.root;
    const last_render = result.render;
    const invalid_roots = [_][]const u8{
        "{kind='native',id=''}",
        "{kind='native',id=123}",
        "{kind='native',id='x',children={}}",
        "{kind='column',id='outer',children={{kind='native',id='inner'}}}",
        "{kind='native',id='x',style={width=500}}",
        "{kind='native',id='x',design=1}",
        "{kind='native',id='x',design={unknown={}}}",
        "{kind='native',id='x',design={[1]={}}}",
        "{kind='native',id='x',design={colors=false}}",
        "{kind='native',id='x',design={colors={typo='#000000'}}}",
        "{kind='native',id='x',design={colors={background=123456}}}",
        "{kind='native',id='x',design={colors={background='#fff'}}}",
        "{kind='native',id='x',design={colors={background='#00000000'}}}",
        "{kind='native',id='x',design={colors={background='#gg0000'}}}",
        "{kind='native',id='x',design={colors={background='#000000\\0'}}}",
        "{kind='native',id='x',design={colors={background='#000000',foreground={}}}}",
        "{kind='native',id='x',design={layout={sidebar_width='280'}}}",
        "{kind='native',id='x',design={layout={sidebar_width=true}}}",
        "{kind='native',id='x',design={layout={sidebar_width=0/0}}}",
        "{kind='native',id='x',design={layout={sidebar_width=1/0}}}",
        "{kind='native',id='x',design={layout={sidebar_width=147.99}}}",
        "{kind='native',id='x',design={layout={sidebar_width=400.01}}}",
        "{kind='native',id='x',design={layout={content_width=399}}}",
        "{kind='native',id='x',design={layout={header_height=97}}}",
        "{kind='native',id='x',design={layout={composer_height=135}}}",
        "{kind='native',id='x',design={layout={gutter=49}}}",
        "{kind='native',id='x',design={layout={gap=3}}}",
        "{kind='native',id='x',design={layout={radius=25}}}",
        "{kind='native',id='x',design={layout={padding=24}}}",
        "{kind='column',id='x',children={{kind='text',id='y',design={}}}}",
        "{kind='text',id='x',style=1}",
        "{kind='text',id='x',style={unknown=1}}",
        "{kind='text',id='x',style={[1]=10}}",
        "{kind='text',id='x',style={width='500'}}",
        "{kind='text',id='x',style={width=0}}",
        "{kind='text',id='x',style={height=4097}}",
        "{kind='text',id='x',style={gap=-1}}",
        "{kind='text',id='x',style={padding=129}}",
        "{kind='text',id='x',style={font_size=7}}",
        "{kind='text',id='x',style={radius=65}}",
        "{kind='text',id='x',style={radius=0/0}}",
        "{kind='text',id='x',style={font_size=-1/0}}",
        "{kind='text',id='x',style={background='#01234z'}}",
        "{kind='text',id='x',style={foreground=0}}",
        "{kind='text',id='x',style={width=100,foreground='#fff'}}",
    };
    for (invalid_roots, 2..) |root, sequence| {
        const source = try moduleForRoot(root);
        defer std.testing.allocator.free(source);
        try runtime.reload(sequence, source, &input);
        try wait(&runtime, &result);
        try expect(result.status != 0);
        try equal(@as(u64, 1), result.generation);
        try std.testing.expectEqualDeep(last_root, result.root);
        try std.testing.expectEqualDeep(last_render, result.render);
    }
    // A failed staging candidate never replaces the active Lua VM either.
    try runtime.render(1000, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try equal(@as(u64, 1), result.generation);
    try std.testing.expectEqualDeep(last_root, result.root);
}

test "active design or renderer failure rolls back root style, design and text together" {
    const source =
        \\return {
        \\root=function(s)
        \\ local r={kind='text',id='x',text=s.text,style={font_size=20},design={layout={gap=16}}}
        \\ if s.text=='style' then r.style.font_size=0/0 end
        \\ if s.text=='design' then r.design.layout.gap='16' end
        \\ if s.text=='renderer' then r.design.layout.gap=24; r.style.font_size=30 end
        \\ return r end,
        \\render_block=function(s)
        \\ if s.text=='renderer' then return {format='plain',text={}} end
        \\ return {format='plain',text=s.text} end,
        \\action=function() return {kind='cancel'} end}
    ;
    var runtime = try script.Runtime.init(64 * 1024, 100000, null, null);
    defer runtime.deinit() catch unreachable;
    var input = try snapshot();
    var result: script.Result = undefined;
    try runtime.reload(1, source, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    const last_root = result.root;
    const last_render = result.render;
    for ([_][]const u8{ "style", "design", "renderer" }, 2..) |text, sequence| {
        input.text = try script.text(text);
        try runtime.render(sequence, &input);
        try wait(&runtime, &result);
        try expect(result.status != 0);
        try equal(@as(u64, 1), result.generation);
        try std.testing.expectEqualDeep(last_root, result.root);
        try std.testing.expectEqualDeep(last_render, result.render);
    }
    input.text = try script.text("recovered 世界");
    try runtime.render(100, &input);
    try wait(&runtime, &result);
    try equal(@as(c_int, 0), result.status);
    try std.testing.expectEqualStrings("recovered 世界", result.root.text[0..result.root.text_len]);
    try equal(@as(f32, 16), (try design.Config.fromScript(&result.root)).layout.gap);
}

test "native node style validation rejects unknown masks and finite out of range values" {
    var style = std.mem.zeroes(script.Style);
    try script.validateStyle(&style);
    style.width = std.math.nan(f32);
    try script.validateStyle(&style); // Omitted backing data is irrelevant.
    style.present = 256;
    try std.testing.expectError(error.InvalidStyle, script.validateStyle(&style));
    inline for (.{ "width", "height", "gap", "padding", "font_size", "radius" }, 0..) |name, i| {
        const low = [6]f32{ 1, 1, 0, 0, 8, 0 };
        const high = [6]f32{ 4096, 4096, 128, 128, 72, 64 };
        style.present = @as(u32, 1) << i;
        for ([_]f32{ low[i], high[i] }) |value| {
            @field(style, name) = value;
            try script.validateStyle(&style);
        }
        for ([_]f32{ low[i] - 1, high[i] + 1, std.math.nan(f32), std.math.inf(f32) }) |value| {
            @field(style, name) = value;
            try std.testing.expectError(error.InvalidStyle, script.validateStyle(&style));
        }
    }
}
