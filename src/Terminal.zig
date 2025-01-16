const Terminal = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const ghostty = struct {
    const terminal = @import("ghostty_terminal");
};
const Error = @import("Error.zig");
const GridPos = @import("GridPos.zig");
const main = @import("main.zig");
const PagedMem = @import("pagedmem.zig").PagedMem;
const render = @import("d3d11.zig");
const Screen = @import("Screen.zig");
const XY = @import("xy.zig").XY;

const vtlog = std.log.scoped(.vt);

// true if the terminal has been updated in some way that
// it needs to update the screen
dirty: bool = true,
cursor_dirty: bool = true,
high_surrogate: ?u16 = null,
input: PagedMem(std.mem.page_size) = .{},
buffer: PagedMem(std.mem.page_size) = .{},
cursor: GridPos = .{ .row = 0, .col = 0 },
scroll_pos: usize = 0,
cursor_visible: bool = true,
parser: ghostty.terminal.Parser = .{},

fn nextRowWrap(row_count: u16, row: u16) u16 {
    std.debug.assert(row < row_count);
    return if (row + 1 == row_count) 0 else row + 1;
}

fn cellIndexFromRow(cell_count: GridPos, top: u16, row: u16) usize {
    std.debug.assert(row < cell_count.row);
    const row_index = blk: {
        const i = @as(usize, top) + @as(usize, row);
        break :blk i - (if (i >= cell_count.row) cell_count.row else 0);
    };
    return @as(usize, row_index) * @as(usize, cell_count.col);
}

fn cellIndexFromPos(cell_count: GridPos, top: u16, pos: GridPos) usize {
    std.debug.assert(pos.col < cell_count.col);
    return cellIndexFromRow(cell_count, top, pos.row) + pos.col;
}

fn isUtf8Extension(c: u8) bool {
    return (c & 0b1100_0000) == 0b1000_0000;
}

fn clearCellSlice(cells: []Screen.Cell) void {
    @memset(cells, .{ .codepoint = null, .background = 0, .foreground = 0 });
}
fn saveCellSliceToBuffer(self: *Terminal, cells: []const Screen.Cell) void {
    _ = self;
    _ = cells;
    std.log.info("todo: save cells to buffer (maybe we make this configurable?)", .{});
}

fn saveCellsToBuffer(self: *Terminal, cells: []const Screen.Cell, top: u16, count: u16) void {
    _ = self;
    _ = cells;
    _ = top;
    _ = count;
    std.log.info("todo: save cells to buffer (maybe we make this configurable?)", .{});
}

// returns true if the size was changed
pub fn resize(
    self: *Terminal,
    screen_allocator: std.mem.Allocator,
    screen: *Screen,
    cell_count: GridPos,
) error{OutOfMemory}!bool {
    if (screen.row_count == cell_count.row and screen.col_count == cell_count.col) return false;

    if (screen.col_count != cell_count.col) @panic("todo: support resizing width");

    const old_cell_count: u32 = @as(u32, screen.row_count) * @as(u32, screen.col_count);
    const new_cell_count: u32 = @as(u32, cell_count.row) * @as(u32, cell_count.col);

    if (old_cell_count >= new_cell_count) {
        const save_len: u16 = @intCast(old_cell_count - new_cell_count);
        self.saveCellsToBuffer(screen.cells, screen.top, save_len);

        // works because we checked above that the old/new col count is the same
        //const save_row_count = @divTrunc(save_len, cell_count.col);

        // {
        //     //const i = cellIndexFromRow(screen.cellCount(), screen.top, 0);
        //     ~~~
        //     screen.saveCellsToBuffer(
        //     screen.saveCellsToBuffer(screen.cells[0..save_len]);

        // const next_line_start = blk: {
        //     var offset: usize = save_len;
        //     const limit = @divTrunc(offset + cell_count.col - 1, cell_count.col);
        //     while (offset < limit) {
        //         if (screen.cells.codepoint == '\n') break :blk offset + 1;
        //     }
        //     break :blk limit;
        // };

        if (true) @panic("here");

        // const next_line_start = @divTrunc(save_len + cell_count.col - 1, cell_count.col);
        // const move_len = new_cell_count - next_line_start;
        // std.mem.copyForwards(
        //     screen.cells[0..move_len],
        //     screen.cells[next_line_start..][0..move_len],
        // );
        // if (!allocator.resize(screen.cells, new_cell_count)) @panic("todo?");
        // screen.cells.len = new_cell_count;
        return;
    } else {
        @panic("here");
    }

    _ = screen_allocator;
    std.debug.panic(
        "todo: implement Screen.resize (from row/cols {}/{} to {}/{})",
        .{ self.row_count, self.col_count, cell_count.row, cell_count.col },
    );
}

pub fn handleChildProcessOutput(self: *Terminal, hwnd: win32.HWND, screen: *Screen, data: []const u8) void {
    std.debug.assert(data.len > 0);
    for (data) |c| {
        const actions = self.parser.next(c);
        for (actions) |maybe_action| {
            if (maybe_action) |a| self.doAction(hwnd, screen, a);
        }
    }
}

fn doAction(
    self: *Terminal,
    hwnd: win32.HWND,
    screen: *Screen,
    action: ghostty.terminal.Parser.Action,
) void {
    std.debug.assert(screen.top < screen.row_count);
    std.debug.assert(self.cursor.col < screen.col_count);
    std.debug.assert(self.cursor.row < screen.row_count);

    switch (action) {
        .print => |codepoint| {
            screen.cells[cellIndexFromPos(screen.cellCount(), screen.top, self.cursor)] = .{
                .codepoint = codepoint,
                .background = 0,
                .foreground = 0xffffffff,
            };
            const next_col = self.cursor.col + 1;
            if (next_col == screen.col_count) {
                @panic("todo");
            } else {
                self.cursor.col = next_col;
                // just assuming this for now
                self.dirty = true;
            }
            var utf8_buf: [7]u8 = undefined;
            const utf8_len: u3 = blk: {
                break :blk std.unicode.utf8Encode(
                    codepoint,
                    &utf8_buf,
                ) catch {
                    utf8_buf[0] = '?';
                    utf8_buf[1] = '?';
                    break :blk 2;
                };
            };
            const utf8 = utf8_buf[0..utf8_len];
            // self.bufferPrint("{s}", .{utf8_buf[0..utf8_len]});
            vtlog.debug(
                "print \"{s}\" {} 0x{1x}: cursor now at row={} col={}",
                .{ utf8, codepoint, self.cursor.row, self.cursor.col },
            );
        },
        .execute => |control_code| switch (control_code) {
            8 => {
                if (self.cursor.col == 0) @panic("todo");
                self.cursor.col -= 1;
                vtlog.debug("\\b cursor now at col {}", .{self.cursor.col});
                self.cursor_dirty = true;
            },
            '\n' => {
                if (self.cursor.row + 1 == screen.row_count) {
                    const top_index = cellIndexFromRow(screen.cellCount(), screen.top, 0);
                    const top_row_cells = screen.cells[top_index..][0..screen.col_count];
                    self.saveCellSliceToBuffer(top_row_cells);
                    clearCellSlice(top_row_cells);
                    screen.top = nextRowWrap(screen.row_count, screen.top);
                    self.dirty = true;
                } else {
                    const new_cursor: GridPos = .{ .row = self.cursor.row + 1, .col = 0 };
                    self.cursor = new_cursor;
                    self.cursor_dirty = true;
                }
                vtlog.debug("\\n new row is {}", .{self.cursor.row});
            },
            '\r' => {
                const new_cursor: GridPos = .{ .row = self.cursor.row, .col = 0 };
                const moved = !new_cursor.eql(self.cursor);
                vtlog.debug("\\r ({s})", .{if (moved) "moved" else "already there"});
                self.cursor = new_cursor;
                self.cursor_dirty = moved;
            },
            else => std.log.err(
                "todo: handle control code {} (0x{0x}) \"{}\"",
                .{ control_code, std.zig.fmtEscapes(&[_]u8{control_code}) },
            ),
        },
        .csi_dispatch => |csi| self.handleCsiDispatch(screen, csi) catch |e| {
            std.log.err("failed to handle csi dispatch {} with {s}", .{ csi, @errorName(e) });
        },
        // .esc_dispatch
        .osc_dispatch => |osc| self.handleOscDispatch(hwnd, osc) catch |e| {
            std.log.err("failed to handle osc dispatch {} with {s}", .{ osc, @errorName(e) });
        },
        else => std.log.err("todo: handle {}", .{action}),
    }
}

fn handleCsiDispatch(self: *Terminal, screen: *Screen, csi: ghostty.terminal.Parser.Action.CSI) !void {
    switch (csi.final) {
        'H' => {
            if (csi.intermediates.len > 0) return error.UnexpectedIntermediates;
            if (csi.params.len == 0) {
                const moved = (self.cursor.row != 0) or (self.cursor.col != 0);
                vtlog.debug("cursor home ({s})", .{if (moved) "moved" else "already there"});
                self.cursor = .{ .row = 0, .col = 0 };
                self.cursor_dirty = moved;
            } else if (csi.params.len == 2) {
                const row_num, const col_num = .{ csi.params[0], csi.params[1] };
                if (row_num == 0) std.debug.panic("row can be 0?", .{});
                if (col_num == 0) std.debug.panic("row can be 0?", .{});
                const row = row_num - 1;
                const col = col_num - 1;
                const moved = (self.cursor.row != row) or (self.cursor.col != col);
                vtlog.debug(
                    "cursor move row {} col {} ({s})",
                    .{ row, col, if (moved) "moved" else "already there" },
                );
                self.cursor = .{ .row = row, .col = col };
                self.cursor_dirty = moved;
            } else return error.UnexpectedParams;
        },
        'J' => {
            if (csi.intermediates.len > 0) return error.UnexpectedIntermediates;
            // Get the erase mode parameter, defaulting to 0 if no params
            const mode = if (csi.params.len > 0) csi.params[0] else 0;
            switch (mode) {
                0 => {
                    std.log.err("todo: clear screen from cursor down", .{});
                },
                1 => {
                    std.log.err("todo: clear screen from cursor up", .{});
                },
                2 => {
                    vtlog.debug(
                        "clear screen (len={} cursor={} scroll={})",
                        .{ self.buffer.len, self.cursor, self.scroll_pos },
                    );
                    if (self.buffer.len != self.scroll_pos) {
                        self.buffer.len = self.scroll_pos;
                        self.dirty = true;
                    }
                    self.cursor = .{ .row = 0, .col = 0 };
                    self.dirty = true;
                },
                else => {
                    std.log.warn("unknown clear screen mode {}", .{mode});
                },
            }
        },
        'K' => {
            if (csi.intermediates.len > 0) return error.UnexpectedIntermediates;
            switch (csi.params.len) {
                0 => {
                    const index = cellIndexFromPos(screen.cellCount(), screen.top, self.cursor);
                    vtlog.debug("erase line from {} to {}", .{ self.cursor.col, screen.col_count });
                    for (self.cursor.col..screen.col_count, 0..) |_, offset| {
                        screen.cells[index + offset] = .{
                            .codepoint = null,
                            .background = 0,
                            .foreground = 0,
                        };
                    }
                },
                else => return error.Todo,
            }
        },
        'X' => {
            if (csi.intermediates.len > 0) return error.UnexpectedIntermediates;
            if (csi.params.len != 1) return error.UnexpectedParams;
            vtlog.debug("erase {} characters", .{csi.params[0]});
            for (0..csi.params[0]) |i| {
                const index = cellIndexFromPos(
                    screen.cellCount(),
                    screen.top,
                    .{ .row = self.cursor.row, .col = self.cursor.col + @as(u16, @intCast(i)) },
                );
                screen.cells[index] = .{
                    .codepoint = null,
                    .background = 0,
                    .foreground = 0,
                };
            }
        },
        'h' => {
            if (!std.mem.eql(u8, &.{'?'}, csi.intermediates)) return error.UnexpectedIntermediates;
            if (std.mem.eql(u16, &.{25}, csi.params)) {
                self.setCursorVisible(true);
                return;
            }
            return error.TodoParams;
        },
        'l' => {
            // cmd.exe will send "\x1b[25l" even thoug it says it will send "\x1b[?25l"
            if (csi.intermediates.len != 0 and !std.mem.eql(u8, &.{'?'}, csi.intermediates)) return error.UnexpectedIntermediates;
            if (std.mem.eql(u16, &.{25}, csi.params)) {
                self.setCursorVisible(false);
                return;
            }
            return error.TodoParams;
        },
        else => return error.Todo,
    }
}

fn setCursorVisible(self: *Terminal, visible: bool) void {
    const changed = (self.cursor_visible != visible);
    vtlog.debug(
        "cursor visible: {} ({s})",
        .{ visible, if (changed) "changed" else "no change" },
    );
    self.cursor_visible = visible;
    self.cursor_dirty = changed;
}

fn handleOscDispatch(self: *Terminal, hwnd: win32.HWND, osc: ghostty.terminal.osc.Command) !void {
    _ = self;
    switch (osc) {
        .change_window_title => |title| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const err: ?Error = blk: {
                const title_w = std.unicode.wtf8ToWtf16LeAllocZ(
                    arena.allocator(),
                    title,
                ) catch |e| break :blk .{
                    .what = "decode window title",
                    .code = .{ .zig = e },
                };
                if (0 == win32.SetWindowTextW(hwnd, title_w)) break :blk .{
                    .what = "SetWindowText",
                    .code = .{ .win32 = win32.GetLastError() },
                };
                break :blk null;
            };
            if (err) |e| std.log.err("{}", .{e});
        },
        else => return error.todo,
    }
}

// pub fn backspace(self: *Terminal) void {
//     if (self.child_process) |child_process| {
//         const pty = child_process.pty orelse return self.appendError("pty closed", .{});
//         pty.writer().writeAll("\x7f") catch |e| {
//             self.appendError(
//                 "write backspace failed with {s}",
//                 .{@errorName(e)},
//             );
//         };
//         return;
//     }

//     @panic("todo");
//     // if (self.input.len == 0) return;
//     // if (self.input.getByte(self.input.len - 1) == '\n') return false;
//     // var new_len: usize = self.input.len;
//     // while (true) {
//     //     new_len -= 1;
//     //     if (!isUtf8Extension(self.input.getByte(new_len)))
//     //         break;
//     //     if (new_len == 0) break;
//     // }
//     // const modified = (new_len != self.input.len);
//     // self.dirty = self.dirty or modified;
//     // self.input.len = new_len;
//     // return modified;
// }

pub const Key = enum {
    // zig fmt: off
    up, down, right, left,
    // zig fmt: on
    pub fn escapeSequence(self: Key) [:0]const u8 {
        return switch (self) {
            .up => "\x1b[A",
            .down => "\x1b[B",
            .left => "\x1b[D",
            .right => "\x1b[C",
        };
    }
};

// pub fn addInput(self: *Terminal, utf8: []const u8) void {
//     std.debug.assert(utf8.len > 0);
//     if (self.child_process) |child_process| {
//         const pty = child_process.pty orelse return self.appendError("pty closed", .{});
//         return pty.writer().writeAll(utf8) catch |e| self.appendError(
//             "write failed with {s}",
//             .{@errorName(e)},
//         );
//     }

//     var copied: usize = 0;
//     while (copied < utf8.len) {
//         const read_buf = self.input.getReadBuf() catch |e| oom(e);
//         std.debug.assert(read_buf.len > 0);
//         const copy_len = @min(utf8.len - copied, read_buf.len);
//         @memcpy(read_buf[0..copy_len], utf8[copied..][0..copy_len]);
//         copied += copy_len;
//         self.input.finishRead(copy_len);
//     }
//     // we'll just assume this is true for now
//     self.dirty = true;
// }

fn bufferPrint(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    _ = fmt;
    _ = args;
    std.log.info("TODO: buffer print", .{});
    // const row_offset: usize = blk_row_offset: {
    //     var buffer_it = CodepointIterator{
    //         .slice = self.buffer.sliceAll(),
    //         .index = self.scroll_pos,
    //     };
    //     const rows_passed = blk_rows_passed: {
    //         for (0..self.cursor.row) |i| {
    //             while (true) {
    //                 const c = buffer_it.next() orelse break :blk_rows_passed i;
    //                 if (c == '\n') break;
    //             }
    //         }
    //         break :blk_rows_passed self.cursor.row;
    //     };
    //     if (rows_passed < self.cursor.row) {
    //         std.debug.assert(buffer_it.index == self.buffer.len);
    //         const len = self.cursor.row - rows_passed;
    //         for (0..len) |_| {
    //             self.buffer.writer().writeByte('\n') catch |e| oom(e);
    //         }
    //         buffer_it.index += len;
    //     }
    //     break :blk_row_offset buffer_it.index;
    // };

    // const buffer_offset: usize = blk: {
    //     var buffer_it = CodepointIterator{
    //         .slice = self.buffer.sliceAll(),
    //         .index = row_offset,
    //     };
    //     for (0..self.cursor.col) |_| {
    //         const c = buffer_it.next() orelse @panic("todo");
    //         if (c == '\n') @panic("todo");
    //     }
    //     break :blk buffer_it.index;
    // };

    // if (false) {
    //     std.io.getStdErr().writer().print(
    //         "PRINTING scroll={} buffer_len={} cursor row={} col={} row_offset={} buffer_offset={}:\n---\n",
    //         .{
    //             self.scroll_pos,
    //             self.buffer.len,
    //             self.cursor.row,
    //             self.cursor.col,
    //             row_offset,
    //             buffer_offset,
    //         },
    //     ) catch unreachable;
    //     std.io.getStdErr().writer().print(fmt, args) catch unreachable;
    //     std.io.getStdErr().writer().print("\n---\n", .{}) catch unreachable;
    // }

    // if (buffer_offset == self.buffer.len) {
    //     const len_before = self.buffer.len;
    //     self.buffer.writer().print(fmt, args) catch |e| oom(e);
    //     if (len_before == self.buffer.len) {
    //         return;
    //     }

    //     {
    //         var buffer_it = CodepointIterator{
    //             .slice = self.buffer.sliceAll(),
    //             .index = len_before,
    //         };
    //         while (buffer_it.next()) |c| {
    //             if (c == '\n') @panic("todo");
    //             self.cursor.col += 1;
    //         }
    //     }
    // } else {
    //     @panic("todo");
    // }

    // // TODO: only mark the terminal as dirty if the new data is in view
    // self.dirty = true;
}

fn appendError(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    if (self.buffer.len > 0 and self.buffer.lastByte() != '\n') {
        self.bufferPrint("\n", .{});
    }
    self.bufferPrint("error: " ++ fmt ++ "\n", args);
}

// pub fn flushInput(self: *Terminal, hwnd: win32.HWND, col_count: u16, row_count: u16) void {
//     var err: Error = undefined;
//     self.flushInput2(hwnd, col_count, row_count, &err) catch {
//         self.appendError("{}", .{err});
//     };
// }

// fn flushInput2(
//     self: *Terminal,
//     hwnd: win32.HWND,
//     col_count: u16,
//     row_count: u16,
//     out_err: *Error,
// ) error{Error}!void {
//     const command_start = self.input.scanBackwardsScalar(self.input.len, '\n');

//     if (self.child_process) |child_process| {
//         self.input.writer().writeAll("\r\n") catch |e| oom(e);
//         self.dirty = true;
//         const pty = child_process.pty orelse {
//             self.appendError("pty closed", .{});
//             return;
//         };
//         // TODO: coalesce this into bigger writes?
//         var next: usize = command_start;
//         while (next < self.input.len) : (next += 1) {
//             pty.writer().writeByte(
//                 self.input.getByte(next),
//             ) catch |e| return self.appendError("WriteToPty failed with {s}", .{@errorName(e)});
//         }
//         return;
//     }

//     // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
//     @panic("here");
// }

const Wtf16Iterator = struct {
    slice: PagedMem(std.mem.page_size).Slice,
    index: usize,
    pub const Entry = struct {
        value: ?u16,
    };
    pub fn next(self: *Wtf16Iterator) ?Entry {
        if (self.index >= self.slice.len) return null;
        const result = self.slice.utf8DecodeUtf16Le(
            self.index,
        ) catch {
            self.index += 1;
            return .{ .value = null };
        };
        self.index = result.end;
        return .{ .value = result.value };
    }
};

const CodepointIterator = struct {
    slice: PagedMem(std.mem.page_size).Slice,
    index: usize,
    pub fn next(self: *CodepointIterator) ?u21 {
        if (self.index >= self.slice.len) return null;
        const result = self.slice.utf8DecodeUtf16Le(
            self.index,
        ) catch {
            self.index += 1;
            return std.unicode.replacement_character;
        };
        self.index = result.end;
        const value = result.value orelse return std.unicode.replacement_character;
        if (std.unicode.utf16IsHighSurrogate(value)) @panic("todo");
        if (std.unicode.utf16IsLowSurrogate(value)) @panic("todo");
        return value;
    }
};

// TODO: create a countGlyphs instead
fn countCodepoints(
    paged_mem: PagedMem(std.mem.page_size),
    start: usize,
    limit: usize,
) usize {
    std.debug.assert(start <= limit);
    std.debug.assert(limit <= paged_mem.len);
    var it = CodepointIterator{
        .slice = paged_mem.sliceTo(limit),
        .index = start,
    };
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    return count;
}

// pub fn updateScreen(self: *Terminal, screen: *const Screen) void {
//     _ = self;
//     _ = screen;

//     if (screen.top != 0) @panic("todo");

//     for (0..screen.row_count) |row| {

//     }

//     std.log.err("TODO: implement updateScreen", .{});
//     //@panic("todo");
// }

fn updateTodo(self: *Terminal, screen: *const Screen) void {
    if (!self.dirty) return;
    defer self.dirty = false;

    const command_start: usize = self.input.scanBackwardsScalar(self.input.len, '\n');
    const command_glyph_count: usize = countCodepoints(self.input, command_start, self.input.len);
    const command_row_count: usize = if (screen.col_count == 0) 0 else @min(screen.row_count, @divTrunc(
        command_glyph_count + @as(usize, screen.col_count) - 1,
        @as(usize, screen.col_count),
    ));
    const buffer_row_count = screen.row_count - command_row_count;
    const buffer_start: usize = blk: {
        const skip_last_newline = (self.scroll_pos > 0 and
            self.buffer.getByte(self.scroll_pos - 1) == '\n');
        var buffer_index = self.buffer.scanBackwardsScalar(
            self.scroll_pos - @as(usize, if (skip_last_newline) 1 else 0),
            '\n',
        );
        var lines_scanned: usize = 1;
        while (buffer_index > 0 and lines_scanned < buffer_row_count) {
            buffer_index = self.buffer.scanBackwardsScalar(buffer_index - 1, '\n');
            lines_scanned += 1;
        }
        break :blk buffer_index;
    };
    var buffer_it = CodepointIterator{
        .slice = self.buffer.sliceAll(),
        .index = buffer_start,
    };
    var command_it = CodepointIterator{
        .slice = self.input.sliceAll(),
        .index = command_start,
    };

    for (0..screen.row_count) |row_index| {
        const row_offset = @as(usize, screen.col_count) * row_index;
        const row_cells = screen.cells.items[row_offset..][0..screen.col_count];
        var found_newline = false;
        if (row_index < buffer_row_count) {
            for (row_cells, 0..) |*cell, col_index| {
                // if (found_cursor_buffer_pos == null) {
                //     if (buffer_it.index == self.cursor.buffer_pos) {
                //         found_cursor_buffer_pos = .{ .x = @intCast(col), .y = @intCast(row) };
                //     }
                //     //const at_cursor = !found_cursor_buffer_pos and (
                //     //found_cursor = found_cursor or at_cursor;
                // }
                const codepoint: u21 = blk: {
                    if (found_newline) break :blk ' ';
                    if (buffer_it.next()) |cp| {
                        if (cp == '\n') {
                            found_newline = true;
                            break :blk ' ';
                        }
                        break :blk cp;
                    }
                    break :blk ' ';
                };
                const Rgb = struct { r: u8, g: u8, b: u8 };
                const normal_bg: Rgb = .{ .r = 0, .g = 0, .b = 0 };
                const normal_fg: Rgb = .{ .r = 255, .g = 255, .b = 255 };
                const at_cursor = (self.cursor.row == row_index and self.cursor.col == col_index);
                const render_cursor = (at_cursor and self.cursor_visible);

                const cell_bg: Rgb = if (render_cursor) normal_fg else normal_bg;
                const cell_fg: Rgb = if (render_cursor) normal_bg else normal_fg;

                cell.* = .{
                    .codepoint = codepoint,
                    .background = render.Color.initRgba(cell_bg.r, cell_bg.g, cell_bg.b, 0),
                    .foreground = render.Color.initRgba(cell_fg.r, cell_fg.g, cell_fg.b, 255),
                };
            }
        } else {
            for (row_cells) |*cell| {
                const codepoint = command_it.next() orelse ' ';
                cell.* = .{
                    .codepoint = codepoint,
                    .background = render.Color.initRgba(0, 0, 0, 0),
                    .foreground = render.Color.initRgb(255, 255, 255),
                };
            }
        }
    }
}

pub fn lerpInt(comptime T: type, start: T, end: T, t: f32) T {
    return start + @as(T, @intFromFloat(@as(f32, @floatFromInt(end - start)) * t));
}

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
