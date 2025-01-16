const std = @import("std");

const Textrender = enum {
    dwrite,
    truetype,
    schrift,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const truetype_enabled = b.option(
        bool,
        "truetype",
        "Use https://codeberg.org/andrewrk/TrueType for text rendering",
    ) orelse false;
    const schrift_enabled = b.option(
        bool,
        "schrift",
        "Use libschrift for text rendering",
    ) orelse false;
    if (truetype_enabled and schrift_enabled) {
        std.log.err("cannot enable both truetype and schrift", .{});
        std.process.exit(0xff);
    }

    const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("zigwin32");

    const ghostty_dep = b.dependency("ghostty", .{});
    const ghostty_terminal_mod = b.createModule(.{
        .root_source_file = ghostty_dep.path("src/terminal/main.zig"),
    });

    {
        const options = b.addOptions();
        options.addOption(Textrender, "textrender", if (truetype_enabled)
            .truetype
        else
            (if (schrift_enabled) .schrift else .dwrite));

        const exe = b.addExecutable(.{
            .name = "winterm",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .win32_manifest = b.path("res/win32.manifest"),
            //.single_threaded = true,
        });
        exe.root_module.addOptions("build_options", options);
        b.installArtifact(exe);

        exe.root_module.addImport("win32", win32_mod);
        exe.root_module.addImport("ghostty_terminal", ghostty_terminal_mod);

        if (truetype_enabled) {
            if (b.lazyDependency("truetype", .{})) |truetype_dep| {
                exe.root_module.addImport("TrueType", truetype_dep.module("TrueType"));
            }
        }
        if (schrift_enabled) {
            if (b.lazyDependency("schrift", .{})) |schrift_dep| {
                exe.root_module.addImport("schrift", b.createModule(.{
                    .root_source_file = schrift_dep.path("schrift.zig"),
                }));
            }
        }

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
        const install = b.addInstallArtifact(exe, .{});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("testapp", "Run the testapp").dependOn(&run.step);
    }
}
