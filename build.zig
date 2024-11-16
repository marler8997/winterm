const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("zigwin32");

    {
        const exe = b.addExecutable(.{
            .name = "winterm",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .win32_manifest = b.path("res/win32.manifest"),
            //.single_threaded = true,
        });
        b.installArtifact(exe);

        exe.root_module.addImport("win32", win32_mod);

        exe.subsystem = .Windows;
        exe.addIncludePath(b.path("res"));
        exe.addWin32ResourceFile(.{
            .file = b.path("res/winterm.rc"),
        });

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run.addArgs(args);
        }

        b.step("run", "Run the app").dependOn(&run.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "testapp",
            .root_source_file = b.path("test/app.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        exe.root_module.addImport("win32", win32_mod);
        b.installArtifact(exe);
    }
}
