const Terminal = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const ghostty = struct {
    const terminal = @import("ghostty_terminal");
};
const Error = @import("Error.zig");
const main = @import("main.zig");
const PagedMem = @import("pagedmem.zig").PagedMem;
const render = @import("d3d11.zig");
const Screen = @import("Screen.zig");
const wmapp = @import("wmapp.zig");
const XY = @import("xy.zig").XY;

// true if the terminal has been updated in some way that
// it needs to update the screen
dirty: bool = true,
high_surrogate: ?u16 = null,
input: PagedMem(std.mem.page_size) = .{},
buffer: PagedMem(std.mem.page_size) = .{},

child_process: ?ChildProcess = null,

const ChildProcess = struct {
    pty: ?Pty,
    read: win32.HANDLE,
    thread: std.Thread,
    job: win32.HANDLE,
    process_handle: win32.HANDLE,
    parser: ghostty.terminal.Parser,
};
const Pty = struct {
    write: win32.HANDLE,
    hpcon: win32.HPCON,
    pub fn deinit(self: *Pty) void {
        win32.ClosePseudoConsole(self.hpcon);
        win32.closeHandle(self.write);
    }
};

// this must be called before calling joinChildProcess
pub fn closePty(self: *Terminal, process_handle: win32.HANDLE) void {
    const child_process = &(self.child_process.?);
    std.debug.assert(child_process.process_handle == process_handle);

    if (child_process.pty) |*pty| {
        pty.deinit();
        child_process.pty = null;
    }
}

// closePty must be called before calling this method, and after closePty, the
// main thread must flush the MessageQueue to unblock the read thread in case it
// is blocking on SendMessage.
pub fn joinChildProcess(self: *Terminal, process_handle: win32.HANDLE) void {
    const child_process = &(self.child_process.?);
    std.debug.assert(child_process.process_handle == process_handle);
    // pty should have already been closed by closePty
    std.debug.assert(child_process.pty == null);
    win32.closeHandle(child_process.process_handle);
    win32.closeHandle(child_process.job);
    child_process.thread.join();
    win32.closeHandle(child_process.read);
    self.child_process.? = undefined;
    self.child_process = null;
}

fn isUtf8Extension(c: u8) bool {
    return (c & 0b1100_0000) == 0b1000_0000;
}

pub fn onChildProcessData(self: *Terminal, data: []const u8) void {
    std.debug.assert(data.len > 0);
    const child_process = &(self.child_process orelse std.debug.panic(
        "got child process data without a child process: {}",
        .{std.zig.fmtEscapes(data)},
    ));
    for (data) |c| {
        const actions = child_process.parser.next(c);
        for (actions) |maybe_action| {
            if (maybe_action) |a| self.doAction(a);
        }
    }
}

fn doAction(self: *Terminal, action: ghostty.terminal.Parser.Action) void {
    switch (action) {
        .print => |codepoint| {
            var utf8_buf: [7]u8 = undefined;
            const utf8_len: u3 = std.unicode.utf8Encode(
                codepoint,
                &utf8_buf,
            ) catch |e| std.debug.panic(
                "todo: handle invalid codepoint {} (0x{0x}) ({s})",
                .{ codepoint, @errorName(e) },
            );
            self.buffer.writer().writeAll(utf8_buf[0..utf8_len]) catch |e| oom(e);
            // TODO: don't mark as dirty if the end of the buffer
            //       is not in view
            self.dirty = true;
        },
        .execute => |control_code| switch (control_code) {
            '\n' => {
                self.buffer.writer().writeByte('\n') catch |e| oom(e);
                // TODO: don't mark as dirty if the end of the buffer
                //       is not in view
                self.dirty = true;
            },
            else => std.log.info(
                "todo: handle control code {} (0x{0x}) \"{}\"",
                .{ control_code, std.zig.fmtEscapes(&[_]u8{control_code}) },
            ),
        },
        else => std.log.info("todo: perform action {}", .{action}),
    }
}

pub fn updateColRowCounts(self: *Terminal, col_count: u16, row_count: u16) void {
    self.dirty = true;
    const child_process = self.child_process orelse return;
    const pty = child_process.pty orelse return;
    const hr = win32.ResizePseudoConsole(
        pty.hpcon,
        .{ .X = @intCast(col_count), .Y = @intCast(row_count) },
    );
    if (hr < 0) fatalHr("ResizePseudoConsole", hr);
}

pub fn backspace(self: *Terminal) bool {
    if (self.input.len == 0) return false;
    if (self.input.getByte(self.input.len - 1) == '\n') return false;
    var new_len: usize = self.input.len;
    while (true) {
        new_len -= 1;
        if (!isUtf8Extension(self.input.getByte(new_len)))
            break;
        if (new_len == 0) break;
    }
    const modified = (new_len != self.input.len);
    self.dirty = self.dirty or modified;
    self.input.len = new_len;
    return modified;
}

pub fn addInput(self: *Terminal, utf8: []const u8) void {
    std.debug.assert(utf8.len > 0);
    var copied: usize = 0;
    while (copied < utf8.len) {
        const read_buf = self.input.getReadBuf() catch |e| oom(e);
        std.debug.assert(read_buf.len > 0);
        const copy_len = @min(utf8.len - copied, read_buf.len);
        @memcpy(read_buf[0..copy_len], utf8[copied..][0..copy_len]);
        copied += copy_len;
        self.input.finishRead(copy_len);
    }
    self.dirty = true;
}

fn appendError(self: *Terminal, comptime fmt: []const u8, args: anytype) void {
    if (self.buffer.len > 0 and self.buffer.lastByte() != '\n') {
        self.buffer.writeByte('\n') catch |e| oom(e);
    }
    self.buffer.writer().print(fmt ++ "\n", args) catch |e| oom(e);
}

pub fn execute(self: *Terminal, hwnd: win32.HWND, col_count: u16, row_count: u16) void {
    var err: Error = undefined;
    self.execute2(hwnd, col_count, row_count, &err) catch {
        self.appendError("error: {}", .{err});
    };
}
pub fn execute2(self: *Terminal, hwnd: win32.HWND, col_count: u16, row_count: u16, out_err: *Error) error{Error}!void {
    const command_start = self.input.scanBackwardsScalar(self.input.len, '\n');

    if (self.child_process) |child_process| {
        self.input.writeByte('\r') catch |e| oom(e);
        self.input.writeByte('\n') catch |e| oom(e);
        self.dirty = true;
        const pty = child_process.pty orelse {
            self.appendError("error: pty closed", .{});
            return;
        };
        var next: usize = command_start;
        while (next < self.input.len) : (next += 1) {
            const b = [_]u8{self.input.getByte(next)};
            var written: u32 = undefined;
            if (0 == win32.WriteFile(
                pty.write,
                &b,
                1,
                &written,
                null,
            )) std.debug.panic("WriteFile failed, error={}", .{win32.GetLastError().fmt()});
            std.debug.assert(written == 1);
        }
        return;
    }

    const command_limit = self.input.len;
    if (command_start == command_limit) {
        // beep?
        // show a temporary error message?
        std.log.info("no command to execute", .{});
        return;
    }
    self.input.writeByte('\n') catch |e| oom(e);
    self.dirty = true;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const command_utf16: [:0]u16 = blk: {
        var al: std.ArrayListUnmanaged(u16) = .{};
        defer al.deinit(arena.allocator());
        var it = Wtf16Iterator{
            .slice = self.input.sliceTo(command_limit),
            .index = command_start,
        };
        if (self.buffer.len > 0 and self.buffer.lastByte() != '\n') {
            self.buffer.writeByte('\n') catch |e| oom(e);
        }
        self.buffer.writer().writeAll("> ") catch |e| oom(e);
        while (true) {
            const save_pos = it.index;
            const entry = it.next() orelse break;
            for (save_pos..it.index) |i| {
                self.buffer.writeByte(self.input.getByte(i)) catch |e| oom(e);
            }
            const value = entry.value orelse return out_err.setZig("DecodeCommand", error.InvalidUtf8);
            al.append(arena.allocator(), value) catch |e| oom(e);
        }
        self.buffer.writeByte('\n') catch |e| oom(e);
        break :blk al.toOwnedSliceSentinel(arena.allocator(), 0) catch |e| oom(e);
    };

    const command_stripped = std.mem.trim(u16, command_utf16, &[_]u16{ ' ', '\t', '\r' });
    if (std.mem.eql(u16, command_stripped, win32.L("exit"))) {
        win32.PostQuitMessage(0);
        return;
    }
    if (std.mem.eql(u16, command_stripped, win32.L("test"))) {
        for (0..20) |i| {
            self.buffer.writer().print(
                "Winterm is comming ({})...\n",
                .{i},
            ) catch |e| oom(e);
        }
        return;
    }

    var pty_handles_closed = false;

    var sec_attr: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .bInheritHandle = 1,
        .lpSecurityDescriptor = null,
    };

    var pty_read: win32.HANDLE = undefined;
    var our_write: win32.HANDLE = undefined;
    if (0 == win32.CreatePipe(@ptrCast(&pty_read), @ptrCast(&our_write), &sec_attr, 0)) return out_err.setWin32(
        "CreateInputPipe",
        win32.GetLastError(),
    );
    defer if (!pty_handles_closed) win32.closeHandle(pty_read);
    errdefer win32.closeHandle(our_write);

    var our_read: win32.HANDLE = undefined;
    var pty_write: win32.HANDLE = undefined;
    if (0 == win32.CreatePipe(@ptrCast(&our_read), @ptrCast(&pty_write), &sec_attr, 0)) return out_err.setWin32(
        "CreateOutputPipe",
        win32.GetLastError(),
    );

    try setInherit(out_err, our_write, false);
    try setInherit(out_err, our_read, false);

    // start the thread before creating the console since
    // closing the console is what could cause the thread to stop
    const thread = std.Thread.spawn(
        .{},
        readConsoleThread,
        .{ hwnd, our_read },
    ) catch |e| return out_err.setZig("CreateReadConsoleThread", e);
    errdefer thread.join();

    var hpcon: win32.HPCON = undefined;
    {
        const hr = win32.CreatePseudoConsole(
            .{ .X = @intCast(col_count), .Y = @intCast(row_count) },
            pty_read,
            pty_write,
            0,
            @ptrCast(&hpcon),
        );
        if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
        win32.closeHandle(pty_read);
        win32.closeHandle(pty_write);
        pty_handles_closed = true;
    }
    errdefer win32.ClosePseudoConsole(hpcon);

    var attr_list_size: usize = undefined;
    std.debug.assert(0 == win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size));
    switch (win32.GetLastError()) {
        win32.ERROR_INSUFFICIENT_BUFFER => {},
        else => return out_err.setWin32("GetProcAttrsSize", win32.GetLastError()),
    }
    const attr_list = arena.allocator().alloc(
        u8,
        attr_list_size,
    ) catch return out_err.setZig("AllocProcAttrs", error.OutOfMemory);
    // no need to free, the arena will free it for us
    var second_attr_list_size: usize = attr_list_size;
    if (0 == win32.InitializeProcThreadAttributeList(
        attr_list.ptr,
        1,
        0,
        &second_attr_list_size,
    )) return out_err.setWin32("InitProcAttrs", win32.GetLastError());
    defer win32.DeleteProcThreadAttributeList(attr_list.ptr);
    std.debug.assert(second_attr_list_size == attr_list_size);
    if (0 == win32.UpdateProcThreadAttribute(
        attr_list.ptr,
        0,
        win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        hpcon,
        @sizeOf(@TypeOf(hpcon)),
        null,
        null,
    )) return out_err.setWin32("UpdateProcThreadAttribute", win32.GetLastError());

    var startup_info = win32.STARTUPINFOEXW{
        .StartupInfo = .{
            .cb = @sizeOf(win32.STARTUPINFOEXW),
            .hStdError = null,
            .hStdOutput = null,
            .hStdInput = null,
            // USESTDHANDLES is important, otherwise the child process can
            // inherit our handles and end up having IO hooked up to one of
            // our ancestor processes instead of our pseudo terminal. Setting
            // the actual handle values to null seems to work in that the child
            // process will be hooked up to the PTY.
            .dwFlags = .{ .USESTDHANDLES = 1 },
            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        },
        .lpAttributeList = attr_list.ptr,
    };
    var process_info: win32.PROCESS_INFORMATION = undefined;
    if (0 == win32.CreateProcessW(
        null,
        command_utf16,
        null,
        null,
        0, // inherit handles
        .{
            .CREATE_SUSPENDED = 1,
            // Adding this causes output not to work?
            //.CREATE_NO_WINDOW = 1,
            .EXTENDED_STARTUPINFO_PRESENT = 1,
        },
        null,
        null,
        &startup_info.StartupInfo,
        &process_info,
    )) return out_err.setWin32("CreateProcess", win32.GetLastError());
    defer win32.closeHandle(process_info.hThread.?);
    errdefer win32.closeHandle(process_info.hProcess.?);

    // The job object allows us to automatically kill our child process
    // if our process dies.
    // TODO: should we cache/reuse this?
    const job = win32.CreateJobObjectW(null, null) orelse return out_err.setWin32(
        "CreateJobObject",
        win32.GetLastError(),
    );
    errdefer win32.closeHandle(job);

    {
        var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (0 == win32.SetInformationJobObject(
            job,
            win32.JobObjectExtendedLimitInformation,
            &info,
            @sizeOf(@TypeOf(info)),
        )) return out_err.setWin32(
            "SetInformationJobObject",
            win32.GetLastError(),
        );
    }

    if (0 == win32.AssignProcessToJobObject(
        job,
        process_info.hProcess,
    )) return out_err.setWin32(
        "AssignProcessToJobObject",
        win32.GetLastError(),
    );

    {
        const suspend_count = win32.ResumeThread(process_info.hThread);
        if (suspend_count == -1) return self.appendError(.{
            .what = "ResumeThread",
            .code = .{ .win32 = win32.GetLastError() },
        });
    }

    self.child_process = .{
        .pty = .{
            .write = our_write,
            .hpcon = hpcon,
        },
        .read = our_read,
        .thread = thread,
        .job = job,
        .process_handle = process_info.hProcess.?,
        .parser = .{},
    };
}

fn readConsoleThread(
    hwnd: win32.HWND,
    read: win32.HANDLE,
) void {
    while (true) {
        var buffer: [std.mem.page_size]u8 = undefined;
        var read_len: u32 = undefined;
        if (0 == win32.ReadFile(
            read,
            &buffer,
            buffer.len,
            &read_len,
            null,
        )) switch (win32.GetLastError()) {
            .ERROR_BROKEN_PIPE => {
                std.log.info("console output closed", .{});
                return;
            },
            .ERROR_HANDLE_EOF => {
                @panic("todo: eof");
            },
            .ERROR_NO_DATA => {
                @panic("todo: nodata");
            },
            else => |e| std.debug.panic("todo: handle error {}", .{e.fmt()}),
        };
        if (read_len == 0) {
            @panic("possible for ReadFile to return 0 bytes?");
        }
        std.debug.assert(wmapp.CHILD_PROCESS_DATA_RESULT == win32.SendMessageW(
            hwnd,
            wmapp.CHILD_PROCESS_DATA,
            @intFromPtr(&buffer),
            read_len,
        ));
    }
}

fn setInherit(out_err: *Error, handle: win32.HANDLE, enable: bool) error{Error}!void {
    if (0 == win32.SetHandleInformation(
        handle,
        @bitCast(win32.HANDLE_FLAGS{ .INHERIT = 1 }),
        .{ .INHERIT = if (enable) 1 else 0 },
    )) return out_err.setWin32(
        "SetHandleInformation",
        win32.GetLastError(),
    );
}

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

pub fn update(self: *Terminal, screen: *const Screen) void {
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
        const skip_last_newline = (self.buffer.len > 0 and self.buffer.getByte(self.buffer.len - 1) == '\n');
        var buffer_index = self.buffer.scanBackwardsScalar(
            self.buffer.len - @as(usize, if (skip_last_newline) 1 else 0),
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
        const row = screen.cells.items[row_offset..][0..screen.col_count];
        var found_newline = false;
        if (row_index < buffer_row_count) {
            for (row) |*cell| {
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
                const progress: f32 = if (buffer_row_count == 1) 1.0 else @as(f32, @floatFromInt(row_index)) / @as(f32, @floatFromInt(buffer_row_count - 1));
                const ice_r = 185;
                const ice_g = 232;
                const ice_b = 234;
                const bg = render.Color.initRgb(19, 19, 19);
                const fg = render.Color.initRgb(
                    70 + @as(u8, @intFromFloat(@as(f32, ice_r - 70) * progress)),
                    70 + @as(u8, @intFromFloat(@as(f32, ice_g - 70) * progress)),
                    70 + @as(u8, @intFromFloat(@as(f32, ice_b - 70) * progress)),
                );
                cell.* = .{
                    .codepoint = codepoint,
                    .background = bg,
                    .foreground = fg,
                };
            }
        } else {
            for (row) |*cell| {
                const codepoint = command_it.next() orelse ' ';
                cell.* = .{
                    .codepoint = codepoint,
                    .background = render.Color.initRgb(19, 19, 19),
                    .foreground = render.Color.initRgb(185, 232, 234),
                };
            }
        }
    }
}
fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
