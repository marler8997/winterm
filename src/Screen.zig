const Screen = @This();

const std = @import("std");
const XY = @import("xy.zig").XY;
const GridPos = @import("GridPos.zig");

pub const Cell = struct {
    // TODO: we should have a utf8 grapheme instead
    codepoint: ?u21,
    background: u32,
    foreground: u32,
};

row_count: u16,
col_count: u16,
top: u16,
cells: []Cell,

pub fn init(allocator: std.mem.Allocator, size: GridPos) error{OutOfMemory}!Screen {
    return .{
        .col_count = size.col,
        .row_count = size.row,
        .top = 0,
        .cells = try allocator.alloc(Cell, size.count()),
    };
}

pub fn cellCount(self: *const Screen) GridPos {
    return .{ .row = self.row_count, .col = self.col_count };
}

pub fn clear(self: *const Screen) void {
    for (self.cells) |*cell| {
        cell.* = .{
            .codepoint = null,
            .background = 0,
            .foreground = 0,
        };
    }
}

pub fn resize(self: *Screen, allocator: std.mem.Allocator, cell_count: GridPos) error{OutOfMemory}!bool {
    if (self.row_count == cell_count.row and self.col_count == cell_count.col) return true;
    _ = allocator;
    std.debug.panic(
        "todo: implement Screen.resize (from row/cols {}/{} to {}/{})",
        .{ self.row_count, self.col_count, cell_count.row, cell_count.col },
    );
}
