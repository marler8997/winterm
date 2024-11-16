const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const direct2d_dep = b.dependency("direct2d", .{});
    const win32_dep = direct2d_dep.builder.dependency("win32", .{});

    {
        const exe = b.addExecutable(.{
            .name = "winterm",
            .root_source_file = b.path("src/win32.zig"),
            .target = target,
            .optimize = optimize,
            .win32_manifest = b.path("res/win32.manifest"),
            //.single_threaded = true,
        });
        b.installArtifact(exe);

        exe.root_module.addImport("win32", win32_dep.module("zigwin32"));
        exe.root_module.addImport("ddui", direct2d_dep.module("ddui"));

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
}
