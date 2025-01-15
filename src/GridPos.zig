const GridPos = @This();

row: u16,
col: u16,

pub fn count(self: GridPos) u32 {
    return @as(u32, self.row) * @as(u32, self.col);
}

pub fn eql(self: GridPos, other: GridPos) bool {
    return self.row == other.row and self.col == other.col;
}
