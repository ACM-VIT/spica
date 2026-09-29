const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const deps = b.step("deps", "Acquire and build locked native dependencies");
    const bootstrap = b.addSystemCommand(&.{ "python3", "build/bootstrap.py" });
    deps.dependOn(&bootstrap.step);

    const exe = b.addExecutable(.{
        .name = "spica",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const prefix = b.fmt(".deps/install/{s}-{s}", .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) });
    exe.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    exe.root_module.addIncludePath(.{ .cwd_relative = "src/native" });
    exe.root_module.addIncludePath(.{ .cwd_relative = ".deps/src/clay-b25a31c1a152915cd7dd6796e6592273e5a10aac" });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/native/clay.c"), .flags = &.{ "-std=c11", "-O2" } });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/native/text.c"), .flags = &.{ "-std=c11", "-O2" } });
    exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    exe.root_module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    exe.root_module.linkSystemLibrary("SDL3", .{});
    exe.root_module.linkSystemLibrary("freetype", .{});
    exe.root_module.linkSystemLibrary("harfbuzz", .{});
    exe.root_module.linkSystemLibrary("unibreak", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run Spica").dependOn(&run.step);
    const tests = b.step("test", "Run protocol, storage, theme, and Unicode regressions");
    inline for (.{ "src/core/protocol_test.zig", "src/core/store_test.zig", "src/ui/theme.zig", "src/text/edit.zig" }) |path| {
        const test_artifact = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        if (std.mem.eql(u8, path, "src/text/edit.zig")) {
            test_artifact.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
            test_artifact.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
            test_artifact.root_module.linkSystemLibrary("unibreak", .{});
        }
        if (std.mem.eql(u8, path, "src/core/store_test.zig"))
            test_artifact.root_module.linkSystemLibrary("sqlite3", .{});
        tests.dependOn(&b.addRunArtifact(test_artifact).step);
    }
}
