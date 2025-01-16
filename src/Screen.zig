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
