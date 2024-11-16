const std = @import("std");
const XY = @import("xy.zig").XY;
const render = @import("d3d11.zig");

pub const Cell = struct {
    codepoint: u21,
    background: render.Color,
    foreground: render.Color,
};

col_count: u16 = 0,
row_count: u16 = 0,
cells: std.ArrayListUnmanaged(Cell) = .{},
