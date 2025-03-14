const std = @import("std");
const win32 = @import("win32").everything;

const FontFace = @import("FontFace.zig");
const XY = @import("xy.zig").XY;

const global = struct {
    var init_called: bool = false;
    var dwrite_factory: *win32.IDWriteFactory = undefined;
};

pub fn init() void {
    std.debug.assert(!global.init_called);
    global.init_called = true;
    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory,
            @ptrCast(&global.dwrite_factory),
        );
        if (hr < 0) fatalHr("DWriteCreateFactory", hr);
    }
}

pub const FontOptions = struct {
    size: f32,
    face: FontFace,
    pub const default: FontOptions = .{
        .size = 14.0,
        .face = FontFace.initUtf8("Cascadia Code") catch unreachable,
    };
    pub fn eql(self: *const FontOptions, other: *const FontOptions) bool {
        return self.size == other.size and self.face.eql(&other.face);
    }
    pub fn setSize(self: *FontOptions, size: f32) void {
        self.size = size;
    }
    pub fn parseSize(size_str: []const u8) !f32 {
        return std.fmt.parseFloat(f32, size_str);
    }
};

pub const Font = struct {
    // public field
    cell_size: XY(u16),

    text_format: *win32.IDWriteTextFormat,

    pub fn init(dpi: u32, options: *const FontOptions) Font {
        var text_format: *win32.IDWriteTextFormat = undefined;
        {
            const hr = global.dwrite_factory.CreateTextFormat(
                options.face.ptr(),
                null,
                .NORMAL, //weight
                .NORMAL, // style
                .NORMAL, // stretch
                win32.scaleDpi(f32, options.size, dpi),
                win32.L(""), // locale
                &text_format,
            );
            if (hr < 0) std.debug.panic(
                "CreateTextFormat '{}' height {d} failed, hresult=0x{x}",
                .{ std.unicode.fmtUtf16Le(options.face.slice()), options.size, @as(u32, @bitCast(hr)) },
            );
        }
        errdefer _ = text_format.IUnknown.Release();

        const cell_size: XY(u16) = blk: {
            var text_layout: *win32.IDWriteTextLayout = undefined;
            {
                const hr = global.dwrite_factory.CreateTextLayout(
                    win32.L("█"),
                    1,
                    text_format,
                    std.math.floatMax(f32),
                    std.math.floatMax(f32),
                    &text_layout,
                );
                if (hr < 0) fatalHr("CreateTextLayout", hr);
            }
            defer _ = text_layout.IUnknown.Release();

            var metrics: win32.DWRITE_TEXT_METRICS = undefined;
            {
                const hr = text_layout.GetMetrics(&metrics);
                if (hr < 0) fatalHr("GetMetrics", hr);
            }
            break :blk .{
                .x = @as(u16, @intFromFloat(@floor(metrics.width))),
                .y = @as(u16, @intFromFloat(@floor(metrics.height))),
            };
        };

        return .{
            .cell_size = cell_size,
            .text_format = text_format,
        };
    }

    pub fn deinit(self: *Font) void {
        _ = self.text_format.IUnknown.Release();
        self.* = undefined;
    }
};

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
