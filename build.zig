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
    const win32_mod = win32_dep.module("win32");

    // we fetch ghostty ourselves instead of in build.zig.zon because we don't
    // want to download all its dependencies.  This would be fixed if/when zig
    // fixes lazy dependencies.
    //const ghostty_dep = b.dependency("ghostty", .{});
    const ghostty_dep = ZigFetch.create(b, .{
        .url = "git+https://github.com/ghostty-org/ghostty#4ab3754a59d09b59b36c0f8c865e8dc7ab3dea7b",
        .hash = "ghostty-1.1.3-5UdBC1KW6QILH6XsgWigz3g9wwEcyrvtTFYOxFnog_sE",
    });
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

const ZigFetchOptions = struct {
    url: []const u8,
    hash: []const u8,
};
const ZigFetch = struct {
    step: std.Build.Step,
    url: []const u8,
    hash: []const u8,

    already_fetched: bool,
    pkg_path_dont_use_me_directly: []const u8,
    lazy_fetch_stdout: std.Build.LazyPath,
    generated_directory: std.Build.GeneratedFile,
    pub fn create(b: *std.Build, opt: ZigFetchOptions) *ZigFetch {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "fetch", opt.url });
        const fetch = b.allocator.create(ZigFetch) catch @panic("OOM");
        const pkg_path = b.pathJoin(&.{
            b.graph.global_cache_root.path.?,
            "p",
            opt.hash,
        });
        const already_fetched = if (std.fs.cwd().access(pkg_path, .{}))
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => |e| std.debug.panic("access '{s}' failed with {s}", .{ pkg_path, @errorName(e) }),
        };
        fetch.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("zig fetch {s}", .{opt.url}),
                .owner = b,
                .makeFn = make,
            }),
            .url = b.allocator.dupe(u8, opt.url) catch @panic("OOM"),
            .hash = b.allocator.dupe(u8, opt.hash) catch @panic("OOM"),
            .pkg_path_dont_use_me_directly = pkg_path,
            .already_fetched = already_fetched,
            .lazy_fetch_stdout = run.captureStdOut(),
            .generated_directory = .{
                .step = &fetch.step,
            },
        };
        if (!already_fetched) {
            fetch.step.dependOn(&run.step);
        }
        return fetch;
    }
    pub fn getLazyPath(self: *const ZigFetch) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated_directory } };
    }
    pub fn path(self: *ZigFetch, sub_path: []const u8) std.Build.LazyPath {
        return self.getLazyPath().path(self.step.owner, sub_path);
    }
    fn make(step: *std.Build.Step, opt: std.Build.Step.MakeOptions) !void {
        _ = opt;
        const b = step.owner;
        const fetch: *ZigFetch = @fieldParentPtr("step", step);
        if (!fetch.already_fetched) {
            const sha = blk: {
                var file = try std.fs.openFileAbsolute(fetch.lazy_fetch_stdout.getPath(b), .{});
                defer file.close();
                break :blk try file.readToEndAlloc(b.allocator, 999);
            };
            const sha_stripped = std.mem.trimRight(u8, sha, "\r\n");
            if (!std.mem.eql(u8, sha_stripped, fetch.hash)) return step.fail(
                "hash mismatch: declared {s} but the fetched package has {s}",
                .{ fetch.hash, sha_stripped },
            );
        }
        fetch.generated_directory.path = fetch.pkg_path_dont_use_me_directly;
    }
};
