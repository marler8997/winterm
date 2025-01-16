const TrueTypeRenderer = @This();

const std = @import("std");
const win32 = @import("win32").everything;

// add back when we're on a compatible version
//const TrueType = @import("TrueType");
const TrueType = struct {};
const FontFace = @import("FontFace.zig");
const win32font = @import("win32font.zig");
const XY = @import("xy.zig").XY;

pub const needs_direct2d = false;

pub fn init(
    d2d_factory: void,
    texture: *win32.ID3D11Texture2D,
) TrueTypeRenderer {
    _ = d2d_factory;
    _ = texture;
    return .{};
}
pub fn deinit(self: *TrueTypeRenderer) void {
    //self.ttf.definit();
    self.* = undefined;
}

pub const Font = struct {
    //ttf: TrueType,
    cell_size: XY(u16),

    pub fn init(dpi: u32, size: f32, face: *const FontFace) Font {
        win32font.logFonts();

        var path_buf: [400]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "C:\\Windows\\Fonts\\{}.ttf",
            .{std.unicode.fmtUtf16Le(face.slice())},
        ) catch @panic("missing font");

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: leak until I lean whether the TrueType object needs this memory
        //defer arena.deinit();

        const content = blk: {
            const font = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => @panic("missing font"),
                else => |e| std.debug.panic(
                    "open font file '{s}' failed with {s}",
                    .{ path, @errorName(e) },
                ),
            };
            defer font.close();
            break :blk font.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
        };

        if (false) {
            const ttf = TrueType.load(content) catch |e| switch (e) {};
            _ = dpi;
            _ = size;
            return .{ .ttf = ttf, .cell_size = .{ .x = 20, .y = 35 } };
        }
        std.debug.panic("opened font '{s}' but TrueType don't work with zig 0.13.0", .{path});
    }
    pub fn deinit(self: *Font) void {
        self.* = undefined;
    }
};

pub fn render(
    self: *const TrueTypeRenderer,
    font: Font,
    utf8: []const u8,
) void {
    _ = self;
    _ = font;
    _ = utf8;
    @panic("todo");
}
