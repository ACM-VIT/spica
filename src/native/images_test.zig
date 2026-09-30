const std = @import("std");
const c = @cImport({ @cInclude("images.h"); });

// A 1x1 opaque red RGBA PNG with a stored zlib block and valid checksums.
const tiny_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x10, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff,
    0x00, 0xff, 0x00, 0x00, 0xff, 0x05, 0x00, 0x01,
    0xff, 0xfa, 0x5c, 0x88, 0xd1, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
    0x82,
};

fn decode(source: []const u8, output: *c.SpicaImageResult) c.SpicaImageStatus {
    return c.spica_image_decode(source.ptr, source.len, 16, 16, 1024, output);
}

fn expectStatus(want: c.SpicaImageStatus, got: c.SpicaImageStatus) !void {
    try std.testing.expectEqual(want, got);
}

test "tiny PNG decodes in inclusive mode to original-sized owned RGBA pixels" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    var output: c.SpicaImageResult = undefined;
    try expectStatus(c.SPICA_IMAGE_OK, decode(&tiny_png, &output));
    defer c.spica_image_release(&output);
    try std.testing.expectEqual(@as(c_int, 1), output.width);
    try std.testing.expectEqual(@as(c_int, 1), output.height);
    try std.testing.expectEqual(@as(usize, 4), output.byte_length);
    try std.testing.expectEqualStrings("image/png", std.mem.span(output.mime_type));
    try std.testing.expect(output.peak_tracked_bytes <= c.SPICA_IMAGE_JOB_LIMIT);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, output.pixels[0..4]);
}

test "corrupt bytes, over-budget dimensions and recovery preserve caller source" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    var output: c.SpicaImageResult = undefined;
    var corrupted = tiny_png;
    corrupted[58] ^= 0x80; // IDAT CRC; decoder must reject, not produce pixels.
    const retained = corrupted;
    try expectStatus(c.SPICA_IMAGE_DECODER_ERROR, decode(&corrupted, &output));
    try std.testing.expect(output.pixels == null);
    try std.testing.expectEqualSlices(u8, &retained, &corrupted);
    var oversized = tiny_png;
    oversized[18] = 0x10; // forged 4097 x 4097 IHDR is rejected before decode.
    oversized[22] = 0x10;
    try expectStatus(c.SPICA_IMAGE_BUDGET_EXCEEDED, decode(&oversized, &output));
    try std.testing.expect(output.pixels == null);
    try expectStatus(c.SPICA_IMAGE_OK, decode(&tiny_png, &output));
    c.spica_image_release(&output);
}

test "all four native codecs include resident encoded bytes and recover after denial" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    const examples = .{
        .{ ".deps/src/sdl_image-release-3.4.6/test/sample.png", "image/png" },
        .{ ".deps/src/sdl_image-release-3.4.6/test/sample.jpg", "image/jpeg" },
        .{ ".deps/src/sdl_image-release-3.4.6/test/palette.gif", "image/gif" },
        .{ ".deps/src/sdl_image-release-3.4.6/test/sample.webp", "image/webp" },
    };
    // Leave less than a decoder's working set, even for a 1x1 image. Padding
    // remains caller-owned and is not presented as a forged image dimension.
    const padded = try std.testing.allocator.alloc(u8, c.SPICA_IMAGE_JOB_LIMIT - 512);
    defer std.testing.allocator.free(padded);
    inline for (examples) |example| {
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, example[0], std.testing.allocator, .limited(2 * 1024 * 1024));
        defer std.testing.allocator.free(source);
        var output: c.SpicaImageResult = undefined;
        @memset(padded, 0);
        @memcpy(padded[0..source.len], source);
        try expectStatus(c.SPICA_IMAGE_BUDGET_EXCEEDED, decode(padded, &output));
        try std.testing.expect(output.pixels == null);
        try std.testing.expectEqualSlices(u8, source, padded[0..source.len]);
        try expectStatus(c.SPICA_IMAGE_OK, decode(source, &output));
        try std.testing.expectEqualStrings(example[1], std.mem.span(output.mime_type));
        try std.testing.expect(output.width <= 16 and output.height <= 16);
        try std.testing.expect(output.byte_length <= 1024);
        c.spica_image_release(&output);
    }
}

test "animated GIF returns red first frame without upscaling" {
    try std.testing.expect(c.spica_image_install_sdl_allocator());
    // Two 1x1 frames: opaque red, then black. Shared two-entry color table.
    const gif = [_]u8{
        'G', 'I', 'F', '8', '9', 'a', 1, 0, 1, 0, 0x80, 0, 0,
        255, 0, 0, 0, 0, 0,
        0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0,
        0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x4c, 0x01, 0,
        0x3b,
    };
    var output: c.SpicaImageResult = undefined;
    try expectStatus(c.SPICA_IMAGE_OK, decode(&gif, &output));
    defer c.spica_image_release(&output);
    try std.testing.expectEqual(@as(c_int, 1), output.width);
    try std.testing.expectEqual(@as(c_int, 1), output.height);
    try std.testing.expectEqual(@as(usize, 4), output.byte_length);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, output.pixels[0..4]);
}
