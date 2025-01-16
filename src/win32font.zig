const std = @import("std");
const win32 = @import("win32").everything;

pub fn logFonts() void {
    const fonts_path = "C:\\Windows\\Fonts";
    var fonts_dir = std.fs.openDirAbsolute(fonts_path, .{ .iterate = true }) catch |e| std.debug.panic(
        "open fonts dir failed with {s}",
        .{@errorName(e)},
    );
    defer fonts_dir.close();
    var iterator = fonts_dir.iterate();
    while (iterator.next() catch |e| std.debug.panic(
        "dir iterate failed with {s}",
        .{@errorName(e)},
    )) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".ttf")) {
            std.debug.print("{s}\n", .{entry.name});
        }
    }
}
