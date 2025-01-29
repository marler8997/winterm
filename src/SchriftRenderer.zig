const SchriftRenderer = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const schrift = @import("schrift");

const dwrite = @import("dwrite.zig");
const Error = @import("Error.zig");
const FontFace = @import("FontFace.zig");
const win32font = @import("win32font.zig");
const XY = @import("xy.zig").XY;

pub const needs_d3d_context = true;
pub const needs_direct2d = false;
pub const texture_access: enum { gpu, cpu } = .cpu;

d3d_context: *win32.ID3D11DeviceContext,
texture: *win32.ID3D11Texture2D,
arena: std.heap.ArenaAllocator,

pub fn init(
    d3d_context: *win32.ID3D11DeviceContext,
    d2d_factory: void,
    texture: *win32.ID3D11Texture2D,
) SchriftRenderer {
    _ = d2d_factory;
    return .{
        .d3d_context = d3d_context,
        .texture = texture,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
}
pub fn deinit(self: *SchriftRenderer) void {
    self.arena.deinit();
    self.* = undefined;
}

pub const FontOptions = struct {
    size: f32,
    face: FontFace,
    pub const default: FontOptions = .{
        .size = 14.0,
        .face = FontFace.initUtf8("CascadiaCode") catch unreachable,
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

    scale: f32,
    arena: std.heap.ArenaAllocator,
    mem: []const u8,
    info: schrift.TtfInfo,

    pub fn init(dpi: u32, options: *const FontOptions) Font {
        win32font.logFonts();

        var path_buf: [400]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "C:\\Windows\\Fonts\\{}.ttf",
            .{std.unicode.fmtUtf16Le(options.face.slice())},
        ) catch @panic("missing font");

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        const ttf_mem = blk: {
            const font = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
                error.FileNotFound => @panic("missing font"),
                else => |e| std.debug.panic(
                    "open font file '{s}' failed with {s}",
                    .{ path, @errorName(e) },
                ),
            };
            defer font.close();
            break :blk font.readToEndAlloc(arena.allocator(), std.math.maxInt(usize)) catch |e|
                std.debug.panic("read '{s}' failed with {s}", .{ path, @errorName(e) });
        };
        // no need to free, arena will be de-initialized

        const info = schrift.getTtfInfo(ttf_mem) catch |e| std.debug.panic(
            "{s} parse error: {s}",
            .{ path, @errorName(e) },
        );

        const dpi_factor: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
        const scale: f32 = dpi_factor * options.size;
        const cell_size = determineCellSize(ttf_mem, info, scale) catch |e| std.debug.panic(
            "{s} parse error: {s}",
            .{ path, @errorName(e) },
        );
        return .{
            .cell_size = cell_size,
            .scale = scale,
            .arena = arena,
            .mem = ttf_mem,
            .info = info,
        };
    }
    pub fn deinit(self: *Font) void {
        self.arena.deinit(); // frees self.mem
        self.* = undefined;
    }
};

pub fn determineCellSize(
    ttf_mem: []const u8,
    info: schrift.TtfInfo,
    font_size: f64,
) !XY(u16) {
    const test_chars = [_]u32{ '█', 'M', 'W' };
    for (test_chars) |test_char| {
        const glyph = schrift.lookupGlyph(ttf_mem, test_char) catch continue;
        if (glyph == 0) continue; // Skip missing glyphs
        const gm = schrift.gmetrics(ttf_mem, info, false, .{
            .x = font_size,
            .y = font_size,
        }, .{ .x = 0, .y = 0 }, glyph) catch |err| switch (err) {
            error.TtfBadTables,
            error.TtfNoHmtxTable,
            error.TtfBadHmtxTable,
            error.TtfNoLocaTable,
            error.TtfBadLocaTable,
            error.TtfNoGlyfTable,
            error.TtfBadOutline,
            error.TtfBadBbox,
            => |e| return e,
        };
        //std.log.info("char 0x{x} {}", .{ test_char, gm });
        return .{
            .x = @intCast(gm.min_width),
            .y = @intCast(gm.min_height),
        };
    }
    return error.FontMissingBoxMAndW;
}

pub fn render(
    self: *SchriftRenderer,
    font: Font,
    utf8: []const u8,
) void {
    var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
    {
        const hr = self.d3d_context.Map(&self.texture.ID3D11Resource, 0, .WRITE, 0, &mapped);
        if (hr < 0) fatalHr("MapStagingTexture", hr);
    }
    defer self.d3d_context.Unmap(&self.texture.ID3D11Resource, 0);

    const dest_len = @as(usize, font.cell_size.y) * @as(usize, mapped.RowPitch);
    const dest = @as([*]u8, @ptrCast(mapped.pData));

    const codepoint = std.unicode.utf8Decode(utf8) catch std.unicode.replacement_character;
    const gid = schrift.lookupGlyph(
        font.mem,
        codepoint,
    ) catch |err| switch (err) {
        error.TtfBadTables, error.TtfNoCmapTable, error.TtfBadCmapTable => |e| {
            std.log.warn("invalid ttf file: {s}", .{@errorName(e)});
            renderErrorGlyph(font.cell_size, dest, mapped.RowPitch);
            return;
        },
        error.TtfUnsupportedCmapFormat => {
            std.log.warn("unsupported ttf cmap table format", .{});
            renderErrorGlyph(font.cell_size, dest, mapped.RowPitch);
            return;
        },
        error.UnsupportedCharCode => {
            std.log.warn("unsupported char code {}", .{codepoint});
            renderErrorGlyph(font.cell_size, dest, mapped.RowPitch);
            return;
        },
    };
    const y_offset: i32 = blk: {
        const gm = schrift.gmetrics(font.mem, font.info, false, .{
            .x = font.scale,
            .y = font.scale,
        }, .{ .x = 0, .y = 0 }, gid) catch |err| {
            std.log.warn("gmetrics for glyph '{s}' failed with {s}", .{ utf8, @errorName(err) });
            break :blk 0;
        };
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        //std.log.info("Gmetrics '{s}' y_offset={}", .{ utf8, gm.y_offset });
        break :blk gm.y_offset;
    };
    _ = y_offset;

    schrift.render(
        self.arena.allocator(),
        font.mem,
        font.info,
        true,
        .{ .x = font.scale, .y = font.scale }, // scale
        .{ .x = 0, .y = 0 }, //@floatFromInt(y_offset) }, // offset
        dest[0..dest_len],
        mapped.RowPitch,
        .{ .x = font.cell_size.x, .y = font.cell_size.y },
        gid,
    ) catch |e| {
        std.log.err("schrift render codepoint {} failed with {s}", .{ codepoint, @errorName(e) });
        renderErrorGlyph(font.cell_size, dest, mapped.RowPitch);
    };
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = @min(@max((x - edge0) / (edge1 - edge0), 0.0), 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn renderErrorGlyph(
    size: XY(u16),
    out_alphas: [*]u8,
    stride: usize,
) void {
    // Draws a circle with diagonal crossed lines
    const line_thickness = 0.15;
    const circle_thickness = 0.12;
    const circle_radius = 0.77;

    for (0..size.y) |row| {
        const row_offset = row * stride;
        for (0..size.x) |col| {
            const x_norm = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(size.x)) * 2 - 1;
            const y_norm = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(size.y)) * 2 - 1;

            const dist_from_center = @sqrt(x_norm * x_norm + y_norm * y_norm);
            const dist_from_circle = @abs(dist_from_center - circle_radius);
            const dist_from_diag1 = @abs(y_norm - x_norm);
            const dist_from_diag2 = @abs(y_norm + x_norm);

            const circle_alpha = 1.0 - smoothstep(0, circle_thickness, dist_from_circle);
            const diag1_alpha = 1.0 - smoothstep(0, line_thickness, dist_from_diag1);
            const diag2_alpha = 1.0 - smoothstep(0, line_thickness, dist_from_diag2);

            const max_alpha = @max(circle_alpha, @max(diag1_alpha, diag2_alpha));

            out_alphas[row_offset + col] = @as(u8, @intFromFloat(max_alpha * 255.0));
        }
    }
}

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
