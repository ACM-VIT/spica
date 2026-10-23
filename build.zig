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

    // build/driver.py probes installed macOS SDKs and supplies SDKROOT/ZIG_LIBC
    // so native dependencies and Zig's bundled libc++ use a compatible SDK.
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    module.addOptions("build_options", options);
    if (target.result.os.tag == .linux) module.addRPathSpecial(b.fmt("$ORIGIN/../../{s}/lib", .{prefix}));
    foundationDependencies(b, module, prefix);
    libraryDependencies(b, module, prefix);
    scriptDependencies(b, module, prefix);
    const exe = b.addExecutable(.{ .name = "spica", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Spica").dependOn(&run.step);

    // Domain checks and the storage consumer have no SDL/text/display dependency.
    const domain_module = b.createModule(.{ .root_source_file = b.path("src/domain.zig"), .target = target, .optimize = optimize, .link_libc = true });
    storageDependencies(b, domain_module);
    const domain_tests = b.addTest(.{ .name = "domain-tests", .root_module = domain_module });
    const domain_run = b.addRunArtifact(domain_tests);
    domain_run.has_side_effects = true;
    b.step("test-domain", "Run isolated real-SQLite domain boundary regressions").dependOn(&domain_run.step);
    const smoke_module = b.createModule(.{ .root_source_file = b.path("src/domain/smoke.zig"), .target = target, .optimize = optimize, .link_libc = true });
    smoke_module.addImport("domain", domain_module);
    const domain_smoke = b.addExecutable(.{ .name = "domain-smoke", .root_module = smoke_module });
    const smoke_install = b.addInstallArtifact(domain_smoke, .{});
    b.step("build-domain-smoke", "Build the isolated storage consumer").dependOn(&smoke_install.step);
    const smoke_run = b.addRunArtifact(domain_smoke);
    if (b.args) |args| smoke_run.addArgs(args);
    b.step("domain-smoke", "Exercise the actual isolated SQLite storage consumer").dependOn(&smoke_run.step);

    // Core editing checks need Unicode segmentation, not the renderer/content stack.
    const core_module = b.createModule(.{ .root_source_file = b.path("src/core_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    core_module.addIncludePath(b.path(b.fmt("{s}/include", .{prefix})));
    core_module.addLibraryPath(b.path(b.fmt("{s}/lib", .{prefix})));
    core_module.linkSystemLibrary("unibreak", .{ .use_pkg_config = .no });
    const core_tests = b.addTest(.{ .name = "core-tests", .root_module = core_module });
    const core_run = b.addRunArtifact(core_tests);
    core_run.has_side_effects = true;
    b.step("test-core", "Run isolated core and Unicode editing regressions").dependOn(&core_run.step);

    const test_module = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    test_module.addOptions("build_options", options);
    foundationDependencies(b, test_module, prefix);
    libraryDependencies(b, test_module, prefix);
    scriptDependencies(b, test_module, prefix);
    test_module.addCSourceFile(.{ .file = b.path("src/native/parse_arena_test.c"), .flags = &.{ "-std=c11", "-O2" } });
    const tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run reusable native, Unicode, content, platform, and bootstrap regressions");
    const test_run = b.addRunArtifact(tests);
    // Reuse compiled artifacts, but exercise tests on every check invocation.
    test_run.has_side_effects = true;
    test_step.dependOn(&test_run.step);
    // SDL allocator hooks are process-global and must precede every SDL use.
    // Keep decoder allocation-failure probes independent of UI/text test order.
    const image_module = b.createModule(.{ .root_source_file = b.path("src/native/images_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    image_module.addIncludePath(b.path(b.fmt("{s}/include", .{prefix})));
    image_module.addIncludePath(b.path("src/native"));
    image_module.addLibraryPath(b.path(b.fmt("{s}/lib", .{prefix})));
    image_module.addRPath(b.path(b.fmt("{s}/lib", .{prefix})));
    image_module.addCSourceFile(.{ .file = b.path("src/native/images.c"), .flags = &.{ "-std=c11", "-O2" } });
    inline for (.{ "SDL3_image", "SDL3" }) |name| image_module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    const image_tests = b.addTest(.{ .name = "image-tests", .root_module = image_module });
    const image_run = b.addRunArtifact(image_tests);
    image_run.has_side_effects = true;
    test_step.dependOn(&image_run.step);

    const bootstrap_tests = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "build", "-p", "*_test.py" });
    bootstrap_tests.setEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1");
    test_step.dependOn(&bootstrap_tests.step);
}

fn foundationDependencies(b: *std.Build, module: *std.Build.Module, prefix: []const u8) void {
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/freetype2", .{prefix}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/harfbuzz", .{prefix}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/fribidi", .{prefix}) });
    module.addIncludePath(b.path("src/native"));
    module.addIncludePath(b.path(".deps/src/clay-b25a31c1a152915cd7dd6796e6592273e5a10aac"));
    inline for (.{ "clay", "text" }) |name| {
        module.addCSourceFile(.{ .file = b.path("src/native/" ++ name ++ ".c"), .flags = &.{ "-std=c11", "-O2" } });
    }
    module.addLibraryPath(b.path(b.fmt("{s}/lib", .{prefix})));
    module.addRPath(b.path(b.fmt("{s}/lib", .{prefix})));
    // Never let pkg-config substitute system versions for the pinned native builds.
    inline for (.{ "SDL3", "freetype", "harfbuzz", "unibreak", "fribidi" }) |name| {
        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    if (module.resolved_target.?.result.os.tag == .macos) {
        module.linkFramework("CoreText", .{});
        module.linkFramework("CoreFoundation", .{});
    }
}

// Library regressions retain the reusable content and OS boundaries. These
// are deliberately absent from the starter's executable dependency graph.
fn libraryDependencies(b: *std.Build, module: *std.Build.Module, prefix: []const u8) void {
    module.addIncludePath(b.path("src/platform"));
    inline for (.{ "parse_arena", "markdown", "highlight" }) |name| {
        module.addCSourceFile(.{ .file = b.path("src/native/" ++ name ++ ".c"), .flags = &.{ "-std=c11", "-O2" } });
    }
    module.addIncludePath(b.path(".deps/src/rapidfuzz-v3.3.4"));
    module.addCSourceFile(.{ .file = b.path("src/native/fuzzy.cpp"), .flags = &.{ "-std=c++17", "-O2" } });
    // Compile shared POSIX logic plus exactly one target-OS backend. The linker resolves
    // process_internal.h hooks to that backend; process.h stays the shared Zig-facing API.
    module.addCSourceFile(.{ .file = b.path("src/platform/process_posix.c"), .flags = &.{ "-std=c11", "-O2" } });
    const process_backend = switch (module.resolved_target.?.result.os.tag) {
        .linux => "src/platform/process_linux.c",
        .macos => "src/platform/process_macos.c",
        else => @panic("Process support requires Linux or macOS"),
    };
    module.addCSourceFile(.{ .file = b.path(process_backend), .flags = &.{ "-std=c11", "-O2" } });
    storageDependencies(b, module);
    module.addLibraryPath(b.path(b.fmt("{s}/lib", .{prefix})));
    module.addRPath(b.path(b.fmt("{s}/lib", .{prefix})));
    inline for (.{ "cmark-gfm-extensions", "cmark-gfm", "tree-sitter" }) |name| {
        // Link only the locked builds in .deps. With pkg-config on (Zig's default), any library that
        // also has a system install with a .pc file (Homebrew, apt, etc.) resolves to that copy
        // instead, and its directory can land ahead of .deps in the rpath. System copies are other
        // versions and lack the allocator hooks bootstrap.py configures, which crashes the
        // allocation-failure tests. Storage separately links the system SQLite dependency.
        module.linkSystemLibrary(name, .{ .use_pkg_config = .no });
    }
    module.addIncludePath(b.path(".deps/src/cmark-gfm-0.29.0.gfm.13/src"));
    module.addIncludePath(b.path(b.fmt(".deps/build/{s}-{s}/cmark-gfm/src", .{ @tagName(module.resolved_target.?.result.os.tag), @tagName(module.resolved_target.?.result.cpu.arch) })));
}

fn storageDependencies(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{ .file = b.path("src/platform/database.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-O2" } });
    module.addCSourceFile(.{ .file = b.path("src/platform/store_fs.c"), .flags = &.{ "-std=c11", "-O2" } });
    module.linkSystemLibrary("sqlite3", .{ .use_pkg_config = .no });
}

fn scriptDependencies(b: *std.Build, module: *std.Build.Module, prefix: []const u8) void {
    module.addIncludePath(b.path("src/native"));
    module.addIncludePath(b.path(b.fmt("{s}/include/lua54", .{prefix})));
    module.addCSourceFile(.{ .file = b.path("src/native/script_lua.c"), .flags = &.{ "-std=c11", "-O2" } });
    module.addObjectFile(b.path(b.fmt("{s}/lib/libspica-lua54.a", .{prefix})));
    module.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    if (module.resolved_target.?.result.os.tag == .linux) module.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
}
