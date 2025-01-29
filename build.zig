const std = @import("std");

const Textrender = enum {
    dwrite,
    truetype,
    schrift,
    celltype,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var textrender_opt = b.option(Textrender, "text", "select a text renderer");
    if (true == b.option(bool, "celltype", "equivalent of -Dtext=celltype")) {
        if (textrender_opt) |t| std.debug.panic(
            "cannot specify both {s} and {s} text renderers",
            .{ @tagName(t), @tagName(Textrender.celltype) },
        );
        textrender_opt = .celltype;
    }

    const win32_dep = b.dependency("win32", .{});
    const win32_mod = win32_dep.module("zigwin32");

    const ghostty_dep = b.dependency("ghostty", .{});
    const ghostty_terminal_mod = b.createModule(.{
        .root_source_file = ghostty_dep.path("src/terminal/main.zig"),
    });

    {
        const options = b.addOptions();
        options.addOption(Textrender, "textrender", textrender_opt orelse .dwrite);
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

        if (textrender_opt) |t| switch (t) {
            .dwrite => {},
            .truetype => {
                if (b.lazyDependency("truetype", .{})) |truetype_dep| {
                    exe.root_module.addImport("TrueType", truetype_dep.module("TrueType"));
                }
            },
            .schrift => {
                if (b.lazyDependency("schrift", .{})) |schrift_dep| {
                    exe.root_module.addImport("schrift", b.createModule(.{
                        .root_source_file = schrift_dep.path("schrift.zig"),
                    }));
                }
            },
            .celltype => if (b.lazyDependency("celltype", .{})) |celltype| {
                exe.root_module.addImport("celltype", celltype.module("celltype"));
            },
        };

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
