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

pub const Font = struct {
    // public field
    cell_size: XY(u16),

    pub fn init(dpi: u32, size: f32, face: *const FontFace) Font {
        _ = face;
        const dpi_factor: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
        const scaled_size = dpi_factor * size;
        const height: f32 = @round(scaled_size);
        // TODO: make this configurable
        const width: f32 = @round(height / 1.618033988749);
        return .{ .cell_size = .{ .x = @intFromFloat(width), .y = @intFromFloat(height) } };
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
        celltype.default_weight,
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
