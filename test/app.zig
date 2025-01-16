const std = @import("std");
const win32 = @import("win32").everything;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (false) {
        for (0..26) |row| {
            const str = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
            for (0..87 - row) |_| {
                const offset = row % str.len;
                try stdout.writeAll(str[offset..][0..1]);
            }
            try stdout.writeAll("\n");
        }
    }

    if (false) {
        try stdout.writeAll("TestAppStdout\n");
        try stderr.writeAll("TestAppStderr\n");
        try stdout.writeAll("FOO: this line should start with BAR not FOO\rBAR\n");
        try stdout.writeAll("BAR: this line should start with FOO not BAR\rFOO\n");
        const clear_screen = "\x1b[2J";
        try stdout.writeAll(clear_screen);
    }

    // test large scrollback
    if (false) {
        for (0..100) |i| {
            try stdout.print("Line {d} of original output\n", .{i});
        }

        // Save cursor position
        try stdout.writeAll("\x1b[s");

        // Move cursor to top of screen
        try stdout.writeAll("\x1b[H");

        // Insert some new content at the beginning
        try stdout.writeAll("\x1b[31m"); // Red text
        try stdout.writeAll("=== INSERTED AT TOP ===\n");
        try stdout.writeAll("This content was added after the initial output\n");
        try stdout.writeAll("Notice how we can manipulate the terminal buffer\n");
        try stdout.writeAll("=== END INSERTED CONTENT ===\n");
        try stdout.writeAll("\x1b[0m"); // Reset color

        // Restore cursor position
        try stdout.writeAll("\x1b[u");

        // Add something at the end to show we returned
        try stdout.writeAll("\nBack at the bottom!\n");
    }
    if (false) {
        for (0..1000) |_| {
            try stdout.writeAll("\x1b[10000A"); // Try to move up 10000 lines
        }
    }
    if (false) {
        for (0..400) |i| {
            try stdout.print("Line {d:0>6} of original output\n", .{i});
        }

        // Sleep briefly to let terminal catch up
        //try std.time.sleep(1 * std.time.ns_per_s);

        // Attempt to scroll viewport to the very top of buffer
        // Using different methods to test what works:

        // Method 1: Using relative scroll
        try stdout.writeAll("\x1b[10000A"); // Try to move up 10000 lines

        // Method 2: Using absolute positioning within the buffer
        // Note: This might only work within the viewport, not the full buffer
        try stdout.writeAll("\x1b[1;1H");

        // Method 3: Using scrollback buffer navigation
        // This is more terminal-dependent but might work in some terminals
        try stdout.writeAll("\x1b[3J"); // Clear scrollback
        try stdout.writeAll("\x1b]1337;CurrentDir=?\x07"); // Query current directory (forces some terminals to scroll)

        // Try to write at the current position
        try stdout.writeAll("\x1b[31m"); // Red text
        try stdout.print("\n=== ATTEMPTING TO INSERT AT POSITION {d} ===\n", .{0});
        try stdout.writeAll("If you can see this, we successfully wrote to buffer\n");
        try stdout.writeAll("Testing buffer manipulation...\n");
        try stdout.writeAll("=== END TEST CONTENT ===\n");
        try stdout.writeAll("\x1b[0m"); // Reset color

        // Add a marker at the end to show we're done
        try stdout.writeAll("\x1b[10000B"); // Try to move back down
        try stdout.writeAll("\nTest completed - check if content was inserted at top!\n");
    }
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
