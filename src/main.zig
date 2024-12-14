const std = @import("std");
const config = @import("config.zig");
const zig_serial = @import("serial");
const ZVTerm = @import("zvterm").ZVTerm;
const builtin = @import("builtin");

const c = @cImport({
    if (builtin.target.os.tag == .windows) {
        @cInclude("windows.h");
    }
});

var original_termios: ?std.posix.termios = null;

const OpMode = enum {
    Normal,
    Menu,
    Quit,
};

var term: *ZVTerm = undefined;
var termwriter: ZVTerm.TermWriter.Writer = undefined;
var term_width: usize = 80;
var term_height: usize = 24;
const num_status_lines = 1;
const csi = "\x1b[";
var opmode:OpMode = .Normal;

pub fn raw_mode_start() !void {
    if (builtin.target.os.tag != .windows) {
        const stdin_reader = std.io.getStdIn();
        const handle = stdin_reader.handle;
        var termios = try std.posix.tcgetattr(handle);
        original_termios = termios;

        termios.iflag.BRKINT = false;
        termios.iflag.ICRNL = false;
        termios.iflag.INPCK = false;
        termios.iflag.ISTRIP = false;
        termios.iflag.IXON = false;
        termios.oflag.OPOST = false;
        termios.lflag.ECHO = false;
        termios.lflag.ICANON = false;
        termios.lflag.IEXTEN = false;
        termios.lflag.ISIG = false;
        termios.cflag.CSIZE = .CS8;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;

        try std.posix.tcsetattr(handle, .FLUSH, termios);

        var ws: std.posix.winsize = undefined;
        const err = std.posix.system.ioctl(stdin_reader.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(err) != .SUCCESS) {
            return error.GetTerminalSizeErr;
        }
        term_width = ws.ws_col;
        term_height = ws.ws_row;
    } else {
        var csbi:std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const stdouth = try std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE);
        _ = std.os.windows.kernel32.GetConsoleScreenBufferInfo(stdouth, &csbi);
        term_width = @intCast(csbi.srWindow.Right - csbi.srWindow.Left + 1);
        term_height = @intCast(csbi.srWindow.Bottom - csbi.srWindow.Top + 1);

        const ENABLE_PROCESSED_INPUT:u16 = 0x0001;
        const ENABLE_MOUSE_INPUT:u16 = 0x0010;
        const ENABLE_WINDOW_INPUT:u16 = 0x0008;

        const stdinh = try std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE);
        var oldMode:std.os.windows.DWORD = undefined;
        _ = std.os.windows.kernel32.GetConsoleMode(stdinh, &oldMode);
        const newMode = oldMode & ~ENABLE_MOUSE_INPUT & ~ENABLE_WINDOW_INPUT & ~ENABLE_PROCESSED_INPUT;
        _ = std.os.windows.kernel32.SetConsoleMode(stdinh, newMode);
    }
}

pub fn raw_mode_stop() void {
    const stdin_reader = std.io.getStdIn();
    const stdout_writer = std.io.getStdOut().writer();

    stdout_writer.print(csi ++ "48;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }) catch {}; // bg
    stdout_writer.print(csi ++ "38;2;{d};{d};{d}m", .{ 0xFF, 0xFF, 0xFF }) catch {}; // fg

    if (original_termios) |termios| {
        std.posix.tcsetattr(stdin_reader.handle, .FLUSH, termios) catch {};
    }
    term.deinit();
    _ = stdout_writer.print("\n", .{}) catch 0;
}

fn redraw(portname:[]const u8, comm_desc:[]const u8) !void {
    const stdout_writer = std.io.getStdOut().writer();
    var buf = std.io.bufferedWriter(stdout_writer);
    var writer = buf.writer();

    try writer.print(csi ++ "?2026h", .{}); // stop updating
    try writer.print(csi ++ "?25l", .{}); // hide cursor

    // avoid changing colours unless we need to
    var prevFg:?ZVTerm.Cell.RGBACol = null;
    var prevBg:?ZVTerm.Cell.RGBACol = null;

    for (0..term.height) |y| {
        try writer.print(csi ++ "{d};{d}H", .{ y + 1 + num_status_lines, 1 });
        for (0..term.width) |x| {
            const cell = term.getCell(x, y);
            if (cell.char) |ch| {
                if (prevBg == null or prevBg.?.raw != cell.bg.raw) {
                    try writer.print(csi ++ "48;2;{d};{d};{d}m", .{ cell.bg.rgba.r, cell.bg.rgba.g, cell.bg.rgba.b });
                    prevBg = cell.bg;
                }
                if (prevFg == null or prevFg.?.raw != cell.fg.raw) {
                    try writer.print(csi ++ "38;2;{d};{d};{d}m", .{ cell.fg.rgba.r, cell.fg.rgba.g, cell.fg.rgba.b });
                    prevFg = cell.fg;
                }

                try writer.print("{c}", .{ch});
            } else {
                try writer.print(csi ++ "48;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }); // bg
                try writer.print(csi ++ "38;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }); // fg
                prevBg = ZVTerm.Cell.RGBACol {.raw=0};
                prevFg = ZVTerm.Cell.RGBACol {.raw=0};
                try writer.print("{c}", .{' '});
            }
        }
    }

    // status line at the top
    try writer.print(csi ++ "{d};{d}H", .{ 1, 1 });
    try writer.print(csi ++ "48;2;{d};{d};{d}m", .{ 0xFF, 0xFF, 0xFF }); // bg
    try writer.print(csi ++ "38;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }); // fg
    for (0..term_width) |_| try writer.print(" ", .{});
    switch(opmode) {
        .Normal => try writer.print(csi ++ "{d};{d}HMenu:{{ctrl-a}} {s} {s}", .{ 1, 1, portname, comm_desc }),
        .Menu => try writer.print(csi ++ "{d};{d}HBack:{{esc}} Quit:{{q,\\,x}}", .{ 1, 1}),
        else => {},
    }

    // move cursor
    const cursorPos = term.getCursorPos();
    try writer.print(csi ++ "{d};{d}H", .{ cursorPos.y + 1 + num_status_lines, cursorPos.x + 1 });

    // show cursor
    try writer.print(csi ++ "?25h", .{});

    try writer.print(csi ++ "?2026l", .{}); // resume updating

    try buf.flush();
}

pub fn hostcmdtrapper(data:[]const u8) !bool {
    const orig_opmode = opmode;
    for (data) |ch| {
        switch(opmode) {
            .Normal => {    // see if ctrl-a is pressed
                if (ch == std.ascii.control_code.soh) {
                    opmode = .Menu;
                }
            },
            .Menu => {
                switch(ch) {
                    'q','\\','x' => opmode = .Quit,
                    std.ascii.control_code.esc => opmode = .Normal,
                    else => {},
                }
            },
            else => {},
        }
    }
    return opmode != orig_opmode;   // needs redraw
}

pub fn commloop(allocator: std.mem.Allocator, conf:*const config.Config) !void {
    const stdin_reader = std.io.getStdIn();

    var serial = std.fs.cwd().openFile(conf.portname, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("'{s}' does not exist\n", .{conf.portname});
            return;
        },
        error.DeviceBusy => {
            std.debug.print("'{s}' is busy\n", .{conf.portname});
            return;
        },
        error.AccessDenied => {
            std.debug.print("Access denied '{s}'\n", .{conf.portname});
            return;
        },
        else => return err,
    };

    defer serial.close();

    try zig_serial.configureSerialPort(serial, conf.serial_config);

    var comm_desc_buf:[64]u8 = undefined;
    const comm_desc = try std.fmt.bufPrint(&comm_desc_buf, "{}", .{conf.serial_config});

    try raw_mode_start();
    
    term = try ZVTerm.init(allocator, term_width, term_height - num_status_lines); // leave space for status lines
    termwriter = term.getWriter();

    defer if (builtin.target.os.tag != .windows) raw_mode_stop();

    try redraw(conf.portname, comm_desc);

    if (builtin.target.os.tag == .windows) {
        // https://stackoverflow.com/questions/19955617/win32-read-from-stdin-with-timeout
        // https://gist.github.com/technoscavenger/7ffb72acdee9ff32daf85bec1c35d5d8
        const WSA_WAIT_TIMEOUT = 0x102;
        const WSA_WAIT_EVENT_0 = 0;
        const KEY_EVENT = 0x0001;
        const MAXDWORD = 0xffffffff;
        const stdinh = try std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE);

        var commTimeouts:c.COMMTIMEOUTS = undefined;
        _ = c.GetCommTimeouts (serial.handle, &commTimeouts);
        commTimeouts.ReadIntervalTimeout = MAXDWORD;
        commTimeouts.ReadTotalTimeoutMultiplier = 0;
        commTimeouts.ReadTotalTimeoutConstant = 1; // blocks for this long
        commTimeouts.WriteTotalTimeoutMultiplier = 0;
        commTimeouts.WriteTotalTimeoutConstant = 0;
        _ = c.SetCommTimeouts (serial.handle, &commTimeouts);

        outer: while (opmode != .Quit) {
            const handles = [_]std.os.windows.HANDLE{
                stdinh,
                serial.handle,
            };
            const array = handles[0..handles.len].*;
            const res = std.os.windows.ws2_32.WSAWaitForMultipleEvents(handles.len, &array, 0, 1000, 1);

            switch(res) {
                WSA_WAIT_TIMEOUT => {},
                WSA_WAIT_EVENT_0 => {   // stdinh
                    var input_records: [4096]c.INPUT_RECORD = undefined;
                    var num_events_read: u32 = 0;
                    const result = c.ReadConsoleInputW(stdinh, &input_records, @intCast(input_records.len), &num_events_read);
                    if (result != std.os.windows.TRUE) {
                        const err = std.os.windows.kernel32.GetLastError();
                        std.debug.print("Failed to read console {}\n", .{err});
                        opmode = .Quit;
                        continue :outer;
                    }

                    // synthesise keys for cursors (and possibly others)
                    const Keymap = struct {
                        keycode: u32,
                        data: []const u8,
                    };

                    const keymap = [_]Keymap{
                        .{ .keycode = 38, .data = "\x1b[A" },   // up
                        .{ .keycode = 40, .data = "\x1b[B" },  // down
                        .{ .keycode = 37, .data = "\x1b[D" },   // left
                        .{ .keycode = 39, .data = "\x1b[C" },  // right
                    //    .{ .keycode = 33, .data = "\x1b[5~" },  // page up
                    //    .{ .keycode = 34, .data = "\x1b[6~" }, // page down
                    };

                    for (input_records[0..num_events_read]) |record| {
                        if (record.EventType == KEY_EVENT) {
                            const keyEvent = record.Event.KeyEvent;
                            if (keyEvent.bKeyDown != 0) {
                                // std.debug.print("Key down: {d} (code: {})\n", .{ (keyEvent.uChar.AsciiChar), keyEvent.wVirtualKeyCode });
                                var count:usize = 1;
                                var buf:[16]u8 = undefined;
                                buf[0] = keyEvent.uChar.AsciiChar;

                                for (keymap) |km| {
                                    if (km.keycode == keyEvent.wVirtualKeyCode) {
                                        //_ = master_pt.write(km.data) catch {};
                                        std.mem.copyForwards(u8, &buf, km.data);
                                        count = km.data.len;
                                        break;
                                    }
                                }

                                if (try hostcmdtrapper(buf[0..count])) {
                                    try redraw(conf.portname, comm_desc);
                                }

                                switch(opmode) {
                                    .Normal => {
                                        _ = try serial.writeAll(buf[0..count]);
                                        if (conf.local_echo) {
                                            _ = try termwriter.writeAll(buf[0..count]);
                                            // if logging, store what got typed
                                            if (conf.log_file) |log_file| {
                                                _ = try log_file.writeAll(buf[0..count]);
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }
                    }

                },
                WSA_WAIT_EVENT_0 + 1 => {   // serial.handle
                    var buf: [4096]u8 = undefined;
                    var count:std.os.windows.DWORD = undefined;
                    
                    if (c.ReadFile(serial.handle, &buf, 4096, &count, 0) > 0 and count > 0) {
                        _ = try termwriter.writeAll(buf[0..count]);
                        if (term.damage) {
                            term.damage = false;
                            try redraw(conf.portname, comm_desc);
                        }
                        if (conf.log_file) |log_file| {
                            _ = try log_file.writeAll(buf[0..count]);
                        }
                    } else {
                        //opmode = .Quit;
                    }

                },
                else => {},
            }
        }
    } else {    // mac and linux, use poll
        outer: while (opmode != .Quit) {
            var fds = [_]std.posix.pollfd{
                .{
                    .fd = serial.handle,
                    .events = std.posix.POLL.IN,
                    .revents = undefined,
                },
                .{
                    .fd = stdin_reader.handle,
                    .events = std.posix.POLL.IN,
                    .revents = undefined,
                },
            };
            const ready = std.posix.poll(&fds, 1000) catch 0;
            if (ready > 0) {
                // serial read
                if (fds[0].revents == std.posix.POLL.IN) {
                    var buf: [4096]u8 = undefined;
                    const count = serial.read(&buf) catch 0;
                    if (count > 0) {
                        _ = try termwriter.writeAll(buf[0..count]);
                        if (term.damage) {
                            term.damage = false;
                            try redraw(conf.portname, comm_desc);
                        }
                        if (conf.log_file) |log_file| {
                            _ = try log_file.writeAll(buf[0..count]);
                        }
                    } else {
                        opmode = .Quit;
                    }
                }
                // stdin read
                if (fds[1].revents == std.posix.POLL.IN) {
                    var buf: [4096]u8 = undefined;
                    const count = stdin_reader.read(&buf) catch 0;
                    if (count > 0) {
                        if (try hostcmdtrapper(buf[0..count])) {
                            try redraw(conf.portname, comm_desc);
                        }

                        switch(opmode) {
                            .Normal => {
                                _ = try serial.writeAll(buf[0..count]);
                                if (conf.local_echo) {
                                    _ = try termwriter.writeAll(buf[0..count]);
                                    // if logging, store what got typed
                                    if (conf.log_file) |log_file| {
                                        _ = try log_file.writeAll(buf[0..count]);
                                    }
                                }
                            },
                            else => {},
                        }
                    } else {
                        opmode = .Quit;
                        continue :outer;
                    }
                }
            }
        }
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const conf = config.parseCommandLine(allocator) catch {
        return;
    };

    if (conf) |cnf| {
        try commloop(allocator, cnf);
    }
}

