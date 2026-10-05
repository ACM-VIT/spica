const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bootstrap = b.addSystemCommand(&.{ "python3", "build/bootstrap.py" });
    b.step("deps", "Acquire and build locked native dependencies").dependOn(&bootstrap.step);
    const prefix = b.fmt(".deps/install/{s}-{s}", .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) });
    const options = b.addOptions();
    options.addOption([]const u8, "native_library_dir", b.path(b.fmt("{s}/lib", .{prefix})).getPath(b));
    options.addOption([]const u8, "asset_directory", b.path("assets").getPath(b));
    options.addOption([]const u8, "font_directory", b.path(".deps/install/fonts").getPath(b));

    // macOS 27 SDK: Zig 0.16 cannot build its bundled libc++ ("use of undeclared identifier
    // 'INFINITY'"). The SDK's math.h leaves INFINITY to float.h when clang modules are on, and
    // Zig's float.h does not provide it under -std=c++23. Point Zig at the 26.x SDK instead:
    //   zig libc > macos-26.libc, replace the MacOSX27.0.sdk paths with
    //   /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk, then set env var ZIG_LIBC to that file.
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    module.addOptions("build_options", options);
    if (target.result.os.tag == .linux) module.addRPathSpecial(b.fmt("$ORIGIN/../../{s}/lib", .{prefix}));
    nativeDependencies(b, module, prefix);
    const exe = b.addExecutable(.{ .name = "spica", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Spica").dependOn(&run.step);

    const test_module = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    test_module.addOptions("build_options", options);
    nativeDependencies(b, test_module, prefix);
    test_module.addCSourceFile(.{ .file = b.path("src/native/parse_arena_test.c"), .flags = &.{ "-std=c11", "-O2" } });
    const tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run protocol, storage, Unicode, Markdown, image, and highlighting regressions");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const bootstrap_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "build", "-p", "*_test.py" });
    bootstrap_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    test_step.dependOn(&bootstrap_tests.step);
}

fn nativeDependencies(b: *std.Build, module: *std.Build.Module, prefix: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/freetype2", .{prefix}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/harfbuzz", .{prefix}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/fribidi", .{prefix}) });
    module.addIncludePath(b.path("src/native"));
    module.addIncludePath(b.path(".deps/src/clay-b25a31c1a152915cd7dd6796e6592273e5a10aac"));
    module.addIncludePath(b.path(".deps/src/rapidfuzz-v3.3.4"));
    inline for (.{ "clay", "text", "parse_arena", "markdown", "images", "highlight" }) |name| {
        module.addCSourceFile(.{ .file = b.path("src/native/" ++ name ++ ".c"), .flags = &.{ "-std=c11", "-O2" } });
    }
    module.addCSourceFile(.{ .file = b.path("src/native/fuzzy.cpp"), .flags = &.{ "-std=c++17", "-O2" } });
    module.addCSourceFile(.{ .file = b.path("src/platform/process.c"), .flags = &.{ "-std=c11", "-O2" } });
    module.addCSourceFile(.{ .file = b.path("src/platform/database.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-O2" } });
    module.addLibraryPath(b.path(b.fmt("{s}/lib", .{prefix})));
    module.addRPath(b.path(b.fmt("{s}/lib", .{prefix})));
    inline for (.{ "SDL3_image", "SDL3", "freetype", "harfbuzz", "unibreak", "fribidi", "cmark-gfm-extensions", "cmark-gfm", "tree-sitter", "sqlite3" }) |name| {
        // Link only the locked builds in .deps. With pkg-config on (Zig's default), any library that
        // also has a system install with a .pc file (Homebrew, apt, etc.) resolves to that copy
        // instead, and its directory can land ahead of .deps in the rpath. System copies are other
        // versions and lack the allocator hooks bootstrap.py configures, which crashes the
        // allocation-failure tests. Libraries not built into .deps (sqlite3) still resolve from the
        // standard system library directories.
        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    // text.c finds fallback fonts through CoreText on macOS (fontconfig, loaded at runtime, on Linux).
    if (module.resolved_target.?.result.os.tag == .macos) {
        module.linkFramework("CoreText", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    module.addIncludePath(b.path(".deps/src/cmark-gfm-0.29.0.gfm.13/src"));
    module.addIncludePath(b.path(b.fmt(".deps/build/{s}-{s}/cmark-gfm/src", .{ @tagName(module.resolved_target.?.result.os.tag), @tagName(module.resolved_target.?.result.cpu.arch) })));
}
