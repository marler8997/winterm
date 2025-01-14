const std = @import("std");
const win32 = @import("win32").everything;

pub fn main() !void {
    std.log.info("here", .{});
    try std.io.getStdOut().writer().writeAll("TestAppStdout\n");
    try std.io.getStdErr().writer().writeAll("TestAppStderr\n");
    try std.io.getStdOut().writer().writeAll("FOO: this line should start with BAR not FOO\rBAR\n");
    try std.io.getStdOut().writer().writeAll("BAR: this line should start with FOO not BAR\rFOO\n");
    const clear_screen = "\x1b[2J";
    try std.io.getStdOut().writer().writeAll(clear_screen);
}

pub const std_options: std.Options = .{
    .logFn = log,
};
fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const scope_suffix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    const log_file = openLog();
    defer log_file.close();

    // TODO: maybe we should also log to OutputDebug?
    var bw = std.io.bufferedWriter(log_file.writer());
    {
        var time: win32.SYSTEMTIME = undefined;
        win32.GetSystemTime(&time);
        bw.writer().print(
            "{:0>2}:{:0>2}:{:0>2}.{:0>3}|{}|{}|" ++ level_txt ++ scope_suffix ++ "|",
            .{
                time.wHour,                  time.wMinute,               time.wSecond, time.wMilliseconds,
                win32.GetCurrentProcessId(), win32.GetCurrentThreadId(),
            },
        ) catch |err| std.debug.panic("log failed with {s}", .{@errorName(err)});
    }
    bw.writer().print(format ++ "\n", args) catch |err| std.debug.panic("log failed with {s}", .{@errorName(err)});
    bw.flush() catch |err| std.debug.panic("flush log file failed with {s}", .{@errorName(err)});
}

fn openLog() std.fs.File {
    while (true) {
        const handle = win32.CreateFileW(
            win32.L("C:\\temp\\log.txt"),
            .{
                //.FILE_WRITE_DATA = 1,
                .FILE_APPEND_DATA = 1,
                //.FILE_WRITE_EA = 1,
                //.FILE_WRITE_ATTRIBUTES = 1,
                //.READ_CONTROL = 1,
                //.SYNCHRONIZE = 1,
            },
            .{ .READ = 1 },
            null,
            .OPEN_ALWAYS,
            .{ .FILE_ATTRIBUTE_NORMAL = 1 },
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) switch (win32.GetLastError()) {
            .ERROR_SHARING_VIOLATION => {
                // try again
                win32.Sleep(1);
                continue;
            },
            else => |e| std.debug.panic("CreateFile failed, error={}", .{e.fmt()}),
        };
        return .{ .handle = handle };
    }
}
