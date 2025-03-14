const ChildProcess = @This();

const std = @import("std");
const win32 = @import("win32").everything;

const Error = @import("Error.zig");
const GridPos = @import("GridPos.zig");

pty: ?Pty,
read: win32.HANDLE,
thread: std.Thread,
job: win32.HANDLE,
process_handle: win32.HANDLE,

const Pty = struct {
    write: win32.HANDLE,
    hpcon: win32.HPCON,
    pub fn deinit(self: *Pty) void {
        win32.ClosePseudoConsole(self.hpcon);
        win32.closeHandle(self.write);
    }
    pub fn writer(self: Pty) FileWriter {
        return .{ .context = self.write };
    }
};

const FileWriter = std.io.Writer(
    win32.HANDLE,
    std.os.windows.WriteFileError,
    writeFile,
);
fn writeFile(handle: win32.HANDLE, bytes: []const u8) std.os.windows.WriteFileError!usize {
    return try std.os.windows.WriteFile(handle, bytes, null);
}

// this must be called before calling join
pub fn closePty(self: *ChildProcess) void {
    if (self.pty) |*pty| {
        pty.deinit();
        self.pty = null;
    }
}

// closePty must be called before calling this method, and after closePty, the
// main thread must flush the MessageQueue to unblock the read thread in case it
// is blocking on SendMessage.
pub fn join(self: *ChildProcess) void {
    // pty should have already been closed by closePty
    std.debug.assert(self.pty == null);
    win32.closeHandle(self.process_handle);
    win32.closeHandle(self.job);
    self.thread.join();
    win32.closeHandle(self.read);
    self.* = undefined;
}

// Start a child process attached to a win32 pseudo-console (ConPty).
//
// allocator is only used for temporary storage of attributes to start
// the process, the memory will be cleaned up before returning.
//
// application_name and command_line are simply forwarded to CreateProcess as the
// first two parameters. note that command_line being mutable is not a mistake, for some
// reason windows requires this be mutable.
//
// As far as I know, there's no way to asynchronously read from ConPty...so...this
// function will start its own thread where it will read input from the pseudo-console
// with a stack-allocated buffer (sized with std.mem.page_size).  When it reads data,
// it will response by calling SendMessage on the given hwnd with the given hwnd_msg and
// data that was read.
//
// size.row and size.col must both be > 0, the pseudo-console will fail otherwise.
pub fn startConPtyWin32(
    out_err: *Error,
    allocator: std.mem.Allocator,
    application_name: ?[*:0]const u16,
    command_line: ?[*:0]u16,
    hwnd: win32.HWND,
    hwnd_msg: u32,
    hwnd_msg_result: win32.LRESULT,
    cell_count: GridPos,
) error{Error}!ChildProcess {
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
    var pty_handles_closed = false;
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
        .{ hwnd, hwnd_msg, hwnd_msg_result, our_read },
    ) catch |e| return out_err.setZig("CreateReadConsoleThread", e);
    errdefer thread.join();

    var hpcon: win32.HPCON = undefined;
    {
        const hr = win32.CreatePseudoConsole(
            .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
            pty_read,
            pty_write,
            0,
            @ptrCast(&hpcon),
        );
        // important to close these here so our thread won't get stuck
        // if CreatePseudoConsole fails
        win32.closeHandle(pty_read);
        win32.closeHandle(pty_write);
        pty_handles_closed = true;
        if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
    }
    errdefer win32.ClosePseudoConsole(hpcon);

    var attr_list_size: usize = undefined;
    std.debug.assert(0 == win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size));
    switch (win32.GetLastError()) {
        win32.ERROR_INSUFFICIENT_BUFFER => {},
        else => return out_err.setWin32("GetProcAttrsSize", win32.GetLastError()),
    }
    const attr_list = allocator.alloc(
        u8,
        attr_list_size,
    ) catch return out_err.setZig("AllocProcAttrs", error.OutOfMemory);
    defer allocator.free(attr_list);

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
        application_name,
        command_line,
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
        if (suspend_count == -1) return out_err.setWin32(.{
            "ResumeThread",
            win32.GetLastError(),
        });
    }

    return .{
        .pty = .{
            .write = our_write,
            .hpcon = hpcon,
        },
        .read = our_read,
        .thread = thread,
        .job = job,
        .process_handle = process_info.hProcess.?,
    };
}

pub fn resize(self: *const ChildProcess, out_err: *Error, size: GridPos) error{Error}!void {
    const pty = self.pty orelse return;
    const hr = win32.ResizePseudoConsole(
        pty.hpcon,
        .{ .X = @intCast(size.col), .Y = @intCast(size.row) },
    );
    if (hr < 0) return out_err.setHresult("ResizePseudoConsole", hr);
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

fn readConsoleThread(
    hwnd: win32.HWND,
    hwnd_msg: u32,
    hwnd_msg_result: win32.LRESULT,
    read: win32.HANDLE,
) void {
    while (true) {
        var buffer: [4096]u8 = undefined;
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
            else => |e| std.debug.panic("todo: handle error {}", .{e}),
        };
        if (read_len == 0) {
            @panic("possible for ReadFile to return 0 bytes?");
        }
        std.debug.assert(hwnd_msg_result == win32.SendMessageW(
            hwnd,
            hwnd_msg,
            @intFromPtr(&buffer),
            read_len,
        ));
    }
}
