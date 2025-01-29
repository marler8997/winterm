const CodefontRenderer = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const celltype = @import("celltype");

const XY = @import("xy.zig").XY;

const FontFace = @import("FontFace.zig");

pub const needs_d3d_context = true;
pub const needs_direct2d = false;
pub const texture_access: enum { gpu, cpu } = .cpu;

d3d_context: *win32.ID3D11DeviceContext,
texture: *win32.ID3D11Texture2D,

pub fn init(
    d3d_context: *win32.ID3D11DeviceContext,
    d2d_factory: void,
    texture: *win32.ID3D11Texture2D,
) CodefontRenderer {
    _ = d2d_factory;
    return .{ .d3d_context = d3d_context, .texture = texture };
}

pub fn deinit(self: CodefontRenderer) void {
    _ = self;
}

const default_aspect_ratio = 0.5;

const FontSize = struct {
    height: f32,
    aspect_ratio: f32,
    pub fn eql(self: FontSize, other: FontSize) bool {
        return self.height == other.height and self.aspect_ratio == other.aspect_ratio;
    }
};

pub const FontOptions = struct {
    size: FontSize,
    pub const default: FontOptions = .{
        .size = .{ .height = 16, .aspect_ratio = default_aspect_ratio },
    };
    pub fn eql(self: *const FontOptions, other: *const FontOptions) bool {
        return self.size.eql(other.size);
    }
    pub fn setSize(self: *FontOptions, size: FontSize) void {
        self.size = size;
    }
    pub fn parseSize(size_str: []const u8) !FontSize {
        const sep_index = std.mem.indexOfScalar(u8, size_str, ':') orelse size_str.len;
        const height_str = size_str[0..sep_index];
        const height = try std.fmt.parseFloat(f32, height_str);
        const aspect_ratio: f32 = blk: {
            if (sep_index == size_str.len) break :blk default_aspect_ratio;
            const ar_str = size_str[sep_index + 1 ..];
            break :blk try std.fmt.parseFloat(f32, ar_str);
        };
        return .{ .height = height, .aspect_ratio = aspect_ratio };
    }
};

pub const Font = struct {
    // public field
    cell_size: XY(u16),

    pub fn init(dpi: u32, options: *const FontOptions) Font {
        const dpi_factor: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
        const height: u16 = @intFromFloat(@round(dpi_factor * options.size.height));
        const width: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(height)) * options.size.aspect_ratio));
        std.log.info(
            "font size {d}:{d} > {}x{} at dpi {}",
            .{ options.size.height, options.size.aspect_ratio, width, height, dpi },
        );
        return .{ .cell_size = .{ .x = width, .y = height } };
    }
    pub fn deinit(self: Font) void {
        _ = self;
    }
};

pub fn render(self: *CodefontRenderer, font: Font, utf8: []const u8) void {
    var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
    {
        const hr = self.d3d_context.Map(&self.texture.ID3D11Resource, 0, .WRITE, 0, &mapped);
        if (hr < 0) fatalHr("MapStagingTexture", hr);
    }
    defer self.d3d_context.Unmap(&self.texture.ID3D11Resource, 0);

    const dest = @as([*]u8, @ptrCast(mapped.pData));

    const stroke_width = celltype.calcStrokeWidth(
        u16,
        font.cell_size.x,
        font.cell_size.y,
        // we want a little thicker than the default I think
        celltype.default_weight * 1.5,
    );
    const config: celltype.Config = .{};
    const bytes_rendered = celltype.renderText(
        &config,
        u16,
        font.cell_size.x,
        font.cell_size.y,
        stroke_width,
        dest,
        mapped.RowPitch,
        .{ .output_precleared = false },
        utf8,
    ) catch |e| switch (e) {
        error.Utf8Decode => std.debug.panic(
            "cannot render invalid utf8 '{}'",
            .{std.zig.fmtEscapes(utf8)},
        ),
    };
    std.debug.assert(bytes_rendered == utf8.len);
}

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
