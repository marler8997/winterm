const std = @import("std");
const win32 = @import("win32").everything;
const win32ext = @import("win32ext.zig");
const c = @cImport({
    @cInclude("ResourceNames.h");
});

const FontFace = @import("FontFace.zig");
const render = @import("d3d11.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const windowmsg = @import("windowmsg.zig");
const wmapp = @import("wmapp.zig");
const XY = @import("xy.zig").XY;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const window_style_ex = win32.WINDOW_EX_STYLE{
    .APPWINDOW = 1,
    //.ACCEPTFILES = 1,
    .NOREDIRECTIONBITMAP = render.NOREDIRECTIONBITMAP,
};
const window_style = win32.WS_OVERLAPPEDWINDOW;

const global = struct {
    var icons: Icons = undefined;
    var state: ?State = null;

    var font_face: FontFace = getDefaultFontFace();
    var font_size: f32 = 14.0;
    var font: ?Font = null;

    var screen_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var screen: Screen = .{};

    var terminal: Terminal = .{};
    var execute_shell_on_wm_size = true;
    var exit_when_child_exits = true;
};

const State = struct {
    hwnd: win32.HWND,
    render_state: render.WindowState,
    last_sizing_edge: ?win32.WPARAM = null,
    bounds: ?WindowBounds = null,
};
fn stateFromHwnd(hwnd: win32.HWND) *State {
    std.debug.assert(hwnd == global.state.?.hwnd);
    return &global.state.?;
}

fn getDefaultFontFace() FontFace {
    const default_wide = win32.L("Cascadia Code");
    var result: FontFace = .{ .buf = undefined, .len = default_wide.len };
    @memcpy(result.buf[0..default_wide.len], default_wide);
    result.buf[default_wide.len] = 0;
    return result;
}

fn getFont(dpi: u32, size: f32, face: *const FontFace) render.Font {
    if (global.font) |*font| {
        if (font.dpi == dpi and font.size == size and font.face.eql(face))
            return font.render_object;
        font.render_object.deinit();
        global.font = null;
    }
    global.font = .{
        .dpi = dpi,
        .size = size,
        .face = face.*,
        .render_object = render.Font.init(dpi, size, face),
    };
    return global.font.?.render_object;
}

const Font = struct {
    dpi: u32,
    size: f32,
    face: FontFace,
    render_object: render.Font,
};

fn calcWindowRect(
    dpi: u32,
    bounding_rect: win32.RECT,
    maybe_edge: ?win32.WPARAM,
    cell_size: XY(i32),
) win32.RECT {
    const client_inset = getClientInset(dpi);
    const bounding_client_size: XY(i32) = .{
        .x = (bounding_rect.right - bounding_rect.left) - client_inset.x,
        .y = (bounding_rect.bottom - bounding_rect.top) - client_inset.y,
    };
    const trim: XY(i32) = .{
        .x = @mod(bounding_client_size.x, cell_size.x),
        .y = @mod(bounding_client_size.y, cell_size.y),
    };
    const Adjustment = enum { low, high, both };
    const adjustments: XY(Adjustment) = if (maybe_edge) |edge| switch (edge) {
        win32.WMSZ_LEFT => .{ .x = .low, .y = .both },
        win32.WMSZ_RIGHT => .{ .x = .high, .y = .both },
        win32.WMSZ_TOP => .{ .x = .both, .y = .low },
        win32.WMSZ_TOPLEFT => .{ .x = .low, .y = .low },
        win32.WMSZ_TOPRIGHT => .{ .x = .high, .y = .low },
        win32.WMSZ_BOTTOM => .{ .x = .both, .y = .high },
        win32.WMSZ_BOTTOMLEFT => .{ .x = .low, .y = .high },
        win32.WMSZ_BOTTOMRIGHT => .{ .x = .high, .y = .high },
        else => .{ .x = .both, .y = .both },
    } else .{ .x = .both, .y = .both };

    return .{
        .left = bounding_rect.left + switch (adjustments.x) {
            .low => trim.x,
            .high => 0,
            .both => @divTrunc(trim.x, 2),
        },
        .top = bounding_rect.top + switch (adjustments.y) {
            .low => trim.y,
            .high => 0,
            .both => @divTrunc(trim.y, 2),
        },
        .right = bounding_rect.right - switch (adjustments.x) {
            .low => 0,
            .high => trim.x,
            .both => @divTrunc(trim.x + 1, 2),
        },
        .bottom = bounding_rect.bottom - switch (adjustments.y) {
            .low => 0,
            .high => trim.y,
            .both => @divTrunc(trim.y + 1, 2),
        },
    };
}

fn getClientInset(dpi: u32) XY(i32) {
    var rect: win32.RECT = .{
        .left = 0,
        .top = 0,
        .right = 0,
        .bottom = 0,
    };
    if (0 == win32.AdjustWindowRectExForDpi(
        &rect,
        window_style,
        0,
        window_style_ex,
        dpi,
    )) fatalWin32(
        "AdjustWindowRect",
        win32.GetLastError(),
    );
    return .{
        .x = rect.right - rect.left,
        .y = rect.bottom - rect.top,
    };
}

const WindowPlacementOptions = struct {
    left: ?i32 = null,
    top: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

const WindowPlacement = struct {
    dpi: XY(u32),
    size: XY(i32),
    pos: XY(i32),
    pub fn default(opt: WindowPlacementOptions) WindowPlacement {
        return .{
            .dpi = .{
                .x = 96,
                .y = 96,
            },
            .pos = .{
                .x = if (opt.left) |left| left else win32.CW_USEDEFAULT,
                .y = if (opt.top) |top| top else win32.CW_USEDEFAULT,
            },
            .size = .{
                .x = win32.CW_USEDEFAULT,
                .y = win32.CW_USEDEFAULT,
            },
        };
    }
};

fn calcWindowPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: XY(i32),
    opt: WindowPlacementOptions,
) WindowPlacement {
    var result = WindowPlacement.default(opt);

    const monitor = maybe_monitor orelse return result;

    const work_rect: win32.RECT = blk: {
        var info: win32.MONITORINFO = undefined;
        info.cbSize = @sizeOf(win32.MONITORINFO);
        if (0 == win32.GetMonitorInfoW(monitor, &info)) {
            std.log.warn("GetMonitorInfo failed with {}", .{win32.GetLastError().fmt()});
            return result;
        }
        break :blk info.rcWork;
    };

    const work_size: XY(i32) = .{
        .x = @intCast(work_rect.right - work_rect.left),
        .y = @intCast(work_rect.bottom - work_rect.top),
    };
    std.log.debug(
        "monitor work topleft={},{} size={}x{}",
        .{ work_rect.left, work_rect.top, work_size.x, work_size.y },
    );

    const wanted_size: XY(i32) = .{
        .x = win32.scaleDpi(i32, @as(i32, @intCast(opt.width orelse 900)), result.dpi.x),
        .y = win32.scaleDpi(i32, @as(i32, @intCast(opt.height orelse 700)), result.dpi.y),
    };
    const bounding_size: XY(i32) = .{
        .x = @min(wanted_size.x, work_size.x),
        .y = @min(wanted_size.y, work_size.y),
    };
    const bouding_rect: win32.RECT = rectIntFromSize(.{
        .left = work_rect.left + @divTrunc(work_size.x - bounding_size.x, 2),
        .top = work_rect.top + @divTrunc(work_size.y - bounding_size.y, 2),
        .width = bounding_size.x,
        .height = bounding_size.y,
    });
    const adjusted_rect: win32.RECT = calcWindowRect(
        dpi,
        bouding_rect,
        null,
        cell_size,
    );
    result.pos = .{
        .x = if (opt.left) |left| left else adjusted_rect.left,
        .y = if (opt.top) |top| top else adjusted_rect.top,
    };
    result.size = .{
        .x = adjusted_rect.right - adjusted_rect.left,
        .y = adjusted_rect.bottom - adjusted_rect.top,
    };
    return result;
}

fn rectIntFromSize(args: struct { left: i32, top: i32, width: i32, height: i32 }) win32.RECT {
    return .{
        .left = args.left,
        .top = args.top,
        .right = args.left + args.width,
        .bottom = args.top + args.height,
    };
}

fn setWindowPosRect(hwnd: win32.HWND, rect: win32.RECT) void {
    if (0 == win32.SetWindowPos(
        hwnd,
        null, // ignored via NOZORDER
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        .{ .NOZORDER = 1 },
    )) fatalWin32("SetWindowPos", win32.GetLastError());
}

pub export fn wWinMain(
    hinstance: win32.HINSTANCE,
    _: ?win32.HINSTANCE,
    cmdline: [*:0]u16,
    cmdshow: c_int,
) c_int {
    _ = hinstance;
    _ = cmdline;
    _ = cmdshow;

    var opt_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var opt: struct {
        shader: ?[:0]const u8 = null,
        window_placement: WindowPlacementOptions = .{},
    } = .{};

    {
        var it = std.process.ArgIterator.initWithAllocator(opt_arena.allocator()) catch |e| oom(e);
        defer it.deinit();
        std.debug.assert(it.skip()); // skip the executable name
        while (it.next()) |arg| {
            if (false) {
                //
            } else if (std.mem.eql(u8, arg, "--shader")) {
                const str = it.next() orelse std.debug.panic("missing argument for --shader", .{});
                opt.shader = opt_arena.allocator().dupeZ(u8, str) catch |e| oom(e);
            } else if (std.mem.eql(u8, arg, "--no-shell")) {
                global.execute_shell_on_wm_size = false;
                global.exit_when_child_exits = false;
            } else if (std.mem.eql(u8, arg, "--left")) {
                const str = it.next() orelse std.debug.panic("missing argument for --left", .{});
                opt.window_placement.left = std.fmt.parseInt(i32, str, 10) catch std.debug.panic(
                    "--left cmdline option '{s}' is not a number",
                    .{str},
                );
            } else if (std.mem.eql(u8, arg, "--top")) {
                const str = it.next() orelse std.debug.panic("missing argument for --top", .{});
                opt.window_placement.top = std.fmt.parseInt(i32, str, 10) catch std.debug.panic(
                    "--top cmdline option '{s}' is not a number",
                    .{str},
                );
            } else if (std.mem.eql(u8, arg, "--font")) {
                @panic("todo");
                //     const font = it.next() orelse fatal("missing argument for --font", .{});
                //     // HACK! std converts from wtf16 to wtf8...and we convert back to wtf16 here!
                //     global.font_face_name = try std.unicode.wtf8ToWtf16LeAllocZ(arena, font);
            } else {
                std.debug.panic("unknown cmdline option '{s}'", .{arg});
            }
        }
    }

    render.init(.{ .shader = opt.shader });
    opt_arena.deinit();

    const maybe_monitor: ?win32.HMONITOR = blk: {
        break :blk win32.MonitorFromPoint(
            .{
                .x = opt.window_placement.left orelse 0,
                .y = opt.window_placement.top orelse 0,
            },
            win32.MONITOR_DEFAULTTOPRIMARY,
        ) orelse {
            std.log.warn("MonitorFromPoint failed with {}", .{win32.GetLastError().fmt()});
            break :blk null;
        };
    };

    const dpi: XY(u32) = blk: {
        const monitor = maybe_monitor orelse break :blk .{ .x = 96, .y = 96 };
        var dpi: XY(u32) = undefined;
        const hr = win32.GetDpiForMonitor(
            monitor,
            win32.MDT_EFFECTIVE_DPI,
            &dpi.x,
            &dpi.y,
        );
        if (hr < 0) {
            std.log.warn("GetDpiForMonitor failed, hresult=0x{x}", .{@as(u32, @bitCast(hr))});
            break :blk .{ .x = 96, .y = 96 };
        }
        std.log.debug("primary monitor dpi {}x{}", .{ dpi.x, dpi.y });
        break :blk dpi;
    };

    global.icons = getIcons(dpi);
    const cell_size = getFont(@max(dpi.x, dpi.y), global.font_size, &global.font_face).getCellSize(i32);
    const placement = calcWindowPlacement(
        maybe_monitor,
        @max(dpi.x, dpi.y),
        cell_size,
        opt.window_placement,
    );

    const CLASS_NAME = win32.L("WintermWindow");

    {
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            //.style = .{ .VREDRAW = 1, .HREDRAW = 1 },
            .style = .{},
            .lpfnWndProc = WndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = global.icons.large,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = CLASS_NAME,
            .hIconSm = global.icons.small,
        };
        if (0 == win32.RegisterClassExW(&wc)) fatalWin32(
            "RegisterClass",
            win32.GetLastError(),
        );
    }

    const hwnd = win32.CreateWindowExW(
        window_style_ex,
        CLASS_NAME,
        win32.L("WinTerm"),
        window_style,
        placement.pos.x,
        placement.pos.y,
        placement.size.x,
        placement.size.y,
        null, // parent window
        null, // menu
        win32.GetModuleHandleW(null),
        null, // WM_CREATE user data
    ) orelse fatalWin32("CreateWindow", win32.GetLastError());

    {
        // TODO: maybe use DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 if applicable
        // see https://stackoverflow.com/questions/57124243/winforms-dark-title-bar-on-windows-10
        //int attribute = DWMWA_USE_IMMERSIVE_DARK_MODE;
        const dark_value: c_int = 1;
        const hr = win32.DwmSetWindowAttribute(
            hwnd,
            win32.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value,
            @sizeOf(@TypeOf(dark_value)),
        );
        if (hr < 0) std.log.warn(
            "DwmSetWindowAttribute for dark={} failed, error={}",
            .{ dark_value, win32.GetLastError() },
        );
    }

    if (0 == win32.UpdateWindow(hwnd)) fatalWin32("UpdateWindow", win32.GetLastError());
    _ = win32.ShowWindow(hwnd, .{ .SHOWNORMAL = 1 });

    // try some things to bring our window to the top
    const HWND_TOP: ?win32.HWND = null;
    _ = win32.SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, .{ .NOMOVE = 1, .NOSIZE = 1 });
    _ = win32.SetForegroundWindow(hwnd);
    _ = win32.BringWindowToTop(hwnd);

    while (true) {
        const child_process_handle = blk: {
            while (true) {
                if (global.terminal.child_process) |*p| break :blk p.process_handle;
                var msg: win32.MSG = undefined;
                const result = win32.GetMessageW(&msg, null, 0, 0);
                if (result < 0) fatalWin32("GetMessage", win32.GetLastError());
                if (result == 0) onWmQuit(msg.wParam);
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }
        };

        var handles = [1]win32.HANDLE{child_process_handle};
        const wait_result = win32.MsgWaitForMultipleObjectsEx(
            1,
            &handles,
            win32.INFINITE,
            win32.QS_ALLINPUT,
            .{ .ALERTABLE = 1, .INPUTAVAILABLE = 1 },
        );

        if (wait_result == 0) {
            global.terminal.closePty(child_process_handle);
            flushMessages();
            global.terminal.joinChildProcess(child_process_handle);
            win32.invalidateHwnd(hwnd);
            if (global.exit_when_child_exits) {
                win32.PostQuitMessage(0);
            }
        } else std.debug.assert(wait_result == 1);

        flushMessages();
    }
}

pub fn flushMessages() void {
    var msg: win32.MSG = undefined;
    while (true) {
        const result = win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE);
        if (result < 0) fatalWin32("PeekMessage", win32.GetLastError());
        if (result == 0) break;
        if (msg.message == win32.WM_QUIT) onWmQuit(msg.wParam);
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

fn onWmQuit(wparam: win32.WPARAM) noreturn {
    if (std.math.cast(u32, wparam)) |exit_code| {
        std.log.info("quit {}", .{exit_code});
        win32.ExitProcess(exit_code);
    }
    std.log.info("quit {} (0xffffffff)", .{wparam});
    win32.ExitProcess(0xffffffff);
}

fn WndProc(
    hwnd: win32.HWND,
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(std.os.windows.WINAPI) win32.LRESULT {
    switch (msg) {
        win32.WM_CREATE => {
            std.debug.assert(global.state == null);
            global.state = .{
                .hwnd = hwnd,
                .render_state = render.WindowState.init(hwnd),
            };
            std.debug.assert(&(global.state.?) == stateFromHwnd(hwnd));
            return 0;
        },
        win32.WM_CLOSE, win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        // win32.WM_MOUSEMOVE => {
        //     const point = win32ext.pointFromLparam(lparam);
        //     const state = &global.state;
        //     if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
        //         win32.invalidateHwnd(hwnd);
        //     }
        // },
        // win32.WM_LBUTTONDOWN => {
        //     const point = ddui.pointFromLparam(lparam);
        //     const state = &global.state;
        //     if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
        //         win32.invalidateHwnd(hwnd);
        //     }
        //     state.mouse.setLeftDown();
        // },
        // win32.WM_LBUTTONUP => {
        //     const point = ddui.pointFromLparam(lparam);
        //     const state = &global.state;
        //     if (state.mouse.updateTarget(targetFromPoint(&state.layout, point))) {
        //         win32.invalidateHwnd(hwnd);
        //     }
        //     // if (state.mouse.setLeftUp()) |target| switch (target) {
        //     //     .new_window_button => newWindow(),
        //     // };
        // },
        win32.WM_DISPLAYCHANGE => {
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_SIZING => {
            stateFromHwnd(hwnd).last_sizing_edge = wparam;
            return 0;
        },
        win32.WM_EXITSIZEMOVE => {
            const state = stateFromHwnd(hwnd);
            state.bounds = null;
            updateWindowSize(hwnd, state.last_sizing_edge, &state.bounds);
            state.last_sizing_edge = null;
            return 0;
        },
        win32.WM_SIZE => {
            const client_size: XY(u16) = .{
                .x = win32.loword(lparam),
                .y = win32.hiword(lparam),
            };

            const do_sanity_check = true;
            if (do_sanity_check) {
                const client_size2 = getClientSize(u16, hwnd);
                std.debug.assert(client_size.x == client_size2.x);
                std.debug.assert(client_size.y == client_size2.y);
            }

            const dpi = win32.dpiFromHwnd(hwnd);
            const font = getFont(dpi, global.font_size, &global.font_face);
            const cell_size = font.getCellSize(u16);
            const col_count: u16 = @intCast(@divTrunc(client_size.x + cell_size.x - 1, cell_size.x));
            const row_count: u16 = @intCast(@divTrunc(client_size.y + cell_size.y - 1, cell_size.y));
            const cell_count: usize = @as(usize, col_count) * @as(usize, row_count);
            global.screen.cells.ensureTotalCapacity(global.screen_arena.allocator(), cell_count) catch |e| oom(e);
            global.screen.cells.items.len = cell_count;
            global.screen.col_count = col_count;
            global.screen.row_count = row_count;
            global.terminal.updateColRowCounts(col_count, row_count);
            // we wait until we have a size to start the terminal
            // because CreatePseudoConsole fails if the size is 0, which,
            // seem silly
            if (global.execute_shell_on_wm_size) {
                global.terminal.addInput("C:\\Windows\\System32\\cmd.exe");
                global.terminal.flushInput(hwnd, global.screen.col_count, global.screen.row_count);
                global.execute_shell_on_wm_size = false;
            }
            win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_PAINT => {
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            const font = getFont(dpi, global.font_size, &global.font_face);
            global.terminal.update(&global.screen);
            render.paint(hwnd, &state.render_state, font, &global.screen);
            return 0;
        },
        win32.WM_GETDPISCALEDSIZE => {
            const inout_size: *win32.SIZE = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const new_dpi: u32 = @intCast(0xffffffff & wparam);
            // we don't want to update the font with the new dpi until after
            // the dpi change is effective, so, we get the cell size from the current font/dpi
            // and re-scale it based on the new dpi ourselves
            const current_dpi = win32.dpiFromHwnd(hwnd);
            const font = getFont(current_dpi, global.font_size, &global.font_face);
            const current_cell_size_i32 = font.getCellSize(i32);
            const current_cell_size: XY(f32) = .{
                .x = @floatFromInt(current_cell_size_i32.x),
                .y = @floatFromInt(current_cell_size_i32.y),
            };
            const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / @as(f32, @floatFromInt(current_dpi));
            const rescaled_cell_size: XY(i32) = .{
                .x = @intFromFloat(@round(current_cell_size.x * scale)),
                .y = @intFromFloat(@round(current_cell_size.y * scale)),
            };
            const new_rect = calcWindowRect(
                new_dpi,
                .{
                    .left = 0,
                    .top = 0,
                    .right = inout_size.cx,
                    .bottom = inout_size.cy,
                },
                win32.WMSZ_BOTTOMRIGHT,
                rescaled_cell_size,
            );
            inout_size.* = .{
                .cx = new_rect.right,
                .cy = new_rect.bottom,
            };
            return 1;
        },
        win32.WM_DPICHANGED => {
            const state = stateFromHwnd(hwnd);
            const dpi = win32.dpiFromHwnd(hwnd);
            if (dpi != win32.hiword(wparam)) @panic("unexpected hiword dpi");
            if (dpi != win32.loword(wparam)) @panic("unexpected loword dpi");
            const rect: *win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            setWindowPosRect(hwnd, rect.*);
            state.bounds = null;
            return 0;
        },
        win32.WM_KEYDOWN => {
            // NOTE: we only handle characters that we don't receive in WM_CHAR
            const key: Terminal.Key = switch (wparam) {
                @intFromEnum(win32.VK_LEFT) => .left,
                @intFromEnum(win32.VK_UP) => .up,
                @intFromEnum(win32.VK_RIGHT) => .right,
                @intFromEnum(win32.VK_DOWN) => .down,
                else => return 0,
            };
            const was_dirty = global.terminal.dirty;
            global.terminal.keyDown(key);
            if (!was_dirty and global.terminal.dirty) win32.invalidateHwnd(hwnd);
            return 0;
        },
        win32.WM_CHAR => switch (wparam) {
            @intFromEnum(win32.VK_BACK) => {
                if (global.terminal.backspace()) {
                    win32.invalidateHwnd(hwnd);
                }
                return 0;
            },
            @intFromEnum(win32.VK_RETURN) => {
                global.terminal.flushInput(hwnd, global.screen.col_count, global.screen.row_count);
                win32.invalidateHwnd(hwnd);
                return 0;
            },
            else => |char_wparam| {
                const char: u16 = std.math.cast(u16, char_wparam) orelse std.debug.panic(
                    "unexpected WM_CHAR {}",
                    .{char_wparam},
                );
                const input_log = std.log.scoped(.input);
                const maybe_high_surrogate = global.terminal.high_surrogate;
                global.terminal.high_surrogate = null;
                if (std.unicode.utf16IsHighSurrogate(char)) {
                    if (maybe_high_surrogate) |high_surrogate| {
                        input_log.warn(
                            "high surrogate: {} discarded (followed by another high surrogate)",
                            .{high_surrogate},
                        );
                    }
                    input_log.info("high surrogate: {} set", .{char});
                    global.terminal.high_surrogate = char;
                    return 0;
                }

                const codepoint: u21 = blk: {
                    if (maybe_high_surrogate) |high_surrogate| {
                        const pair = [2]u16{ high_surrogate, char };
                        if (std.unicode.utf16DecodeSurrogatePair(&pair)) |cp| {
                            input_log.info(
                                "surrogate pair: {} {} to codepoint {}",
                                .{ high_surrogate, char, cp },
                            );
                            break :blk cp;
                        } else |e| switch (e) {
                            error.ExpectedSecondSurrogateHalf => {
                                input_log.warn(
                                    "high surrogate: {} discarded (followed by non-surrogate)",
                                    .{high_surrogate},
                                );
                            },
                        }
                    }
                    break :blk char;
                };

                var utf8_buf: [7]u8 = undefined;
                const len: u3 = std.unicode.utf8Encode(codepoint, &utf8_buf) catch |e| switch (e) {
                    error.Utf8CannotEncodeSurrogateHalf,
                    error.CodepointTooLarge,
                    => {
                        std.log.warn(
                            "failed to encode {} (0x{0x}) with {s}",
                            .{ codepoint, @errorName(e) },
                        );
                        return 0;
                    },
                };
                var high_surrogate_str_buf: [50]u8 = undefined;
                const high_surrogate_str: []const u8 = if (maybe_high_surrogate) |h|
                    (std.fmt.bufPrint(&high_surrogate_str_buf, "{} ", .{h}) catch unreachable)
                else
                    "";
                const utf8 = utf8_buf[0..len];
                input_log.debug(
                    "WM_CHAR {s}{} cp={} \"{}\"",
                    .{ high_surrogate_str, char, codepoint, std.zig.fmtEscapes(utf8) },
                );
                global.terminal.addInput(utf8);
                win32.invalidateHwnd(hwnd);
                return 0;
            },
        },
        wmapp.CHILD_PROCESS_DATA => {
            const buffer: [*]const u8 = @ptrFromInt(wparam);
            const len: usize = @bitCast(lparam);
            std.debug.assert(len > 0);
            global.terminal.onChildProcessData(buffer[0..len]);
            if (global.terminal.dirty)
                win32.invalidateHwnd(hwnd);
            return wmapp.CHILD_PROCESS_DATA_RESULT;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const WindowBounds = struct {
    token: win32.RECT,
    rect: win32.RECT,
};

fn updateWindowSize(
    hwnd: win32.HWND,
    edge: ?win32.WPARAM,
    bounds_ref: *?WindowBounds,
) void {
    const dpi = win32.dpiFromHwnd(hwnd);
    const font = getFont(dpi, global.font_size, &global.font_face);
    const cell_size = font.getCellSize(i32);

    var window_rect: win32.RECT = undefined;
    if (0 == win32.GetWindowRect(hwnd, &window_rect)) fatalWin32(
        "GetWindowRect",
        win32.GetLastError(),
    );

    const restored_bounds: ?win32.RECT = blk: {
        if (bounds_ref.*) |b| {
            if (std.meta.eql(b.token, window_rect)) {
                break :blk b.rect;
            }
        }
        break :blk null;
    };
    const bounds = if (restored_bounds) |b| b else window_rect;
    const new_rect = calcWindowRect(
        dpi,
        bounds,
        edge,
        cell_size,
    );
    bounds_ref.* = .{
        .token = new_rect,
        .rect = if (restored_bounds) |b| b else new_rect,
    };
    setWindowPosRect(hwnd, new_rect);
}

fn getClientSize(comptime T: type, hwnd: win32.HWND) XY(T) {
    var rect: win32.RECT = undefined;
    if (0 == win32.GetClientRect(hwnd, &rect)) fatalWin32("GetClientRect", win32.GetLastError());
    std.debug.assert(rect.left == 0);
    std.debug.assert(rect.top == 0);
    return .{ .x = @intCast(rect.right), .y = @intCast(rect.bottom) };
}

fn colorrefFromShade(shade: u8) u32 {
    return (@as(u32, shade) << 0) | (@as(u32, shade) << 8) | (@as(u32, shade) << 16);
}

const Icons = struct {
    small: win32.HICON,
    large: win32.HICON,
};
fn getIcons(dpi: XY(u32)) Icons {
    const small_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXSMICON), dpi.x);
    const small_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYSMICON), dpi.y);
    const large_x = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CXICON), dpi.x);
    const large_y = win32.GetSystemMetricsForDpi(@intFromEnum(win32.SM_CYICON), dpi.y);
    std.log.debug("icons small={}x{} large={}x{} at dpi {}x{}", .{
        small_x, small_y,
        large_x, large_y,
        dpi.x,   dpi.y,
    });
    const small = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(c.ID_ICON_WINTERM),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    ) orelse fatalWin32("LoadImage for small icon", win32.GetLastError());
    const large = win32.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(c.ID_ICON_WINTERM),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    ) orelse fatalWin32("LoadImage for large icon", win32.GetLastError());
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}

threadlocal var thread_is_panicing = false;

pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    if (!thread_is_panicing) {
        thread_is_panicing = true;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const msg_z: [:0]const u8 = if (std.fmt.allocPrintZ(
            arena.allocator(),
            "{s}",
            .{msg},
        )) |msg_z| msg_z else |_| "failed allocate error message";
        _ = win32.MessageBoxA(null, msg_z, "WinTerm Panic!", .{ .ICONASTERISK = 1 });
    }
    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

fn fatalWin32(what: []const u8, err: win32.WIN32_ERROR) noreturn {
    std.debug.panic("{s} failed with {}", .{ what, err.fmt() });
}
fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
