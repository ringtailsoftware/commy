const std = @import("std");
const config = @import("config.zig");
const zig_serial = @import("serial");
const ZVTerm = @import("zvterm").ZVTerm;

var original_termios: ?std.posix.termios = null;
const stdin_reader = std.io.getStdIn();
const stdout_writer = std.io.getStdOut().writer();

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
}

pub fn raw_mode_stop() void {
    stdout_writer.print(csi ++ "48;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }) catch {}; // bg
    stdout_writer.print(csi ++ "38;2;{d};{d};{d}m", .{ 0xFF, 0xFF, 0xFF }) catch {}; // fg

    if (original_termios) |termios| {
        std.posix.tcsetattr(stdin_reader.handle, .FLUSH, termios) catch {};
    }
    term.deinit();
    _ = stdout_writer.print("\n", .{}) catch 0;
}

fn redraw(portname:[]const u8, comm_desc:[]const u8) !void {
    try stdout_writer.print(csi ++ "?2026h", .{}); // stop updating
    try stdout_writer.print(csi ++ "?25l", .{}); // hide cursor

    for (0..term.height) |y| {
        try stdout_writer.print(csi ++ "{d};{d}H", .{ y + 1 + num_status_lines, 1 });
        for (0..term.width) |x| {
            const cell = term.getCell(x, y);
            if (cell.char) |ch| {
                try stdout_writer.print(csi ++ "48;2;{d};{d};{d}m", .{ cell.bg.rgba.r, cell.bg.rgba.g, cell.bg.rgba.b });
                try stdout_writer.print(csi ++ "38;2;{d};{d};{d}m", .{ cell.fg.rgba.r, cell.fg.rgba.g, cell.fg.rgba.b });

                try stdout_writer.print("{c}", .{ch});
            } else {
                try stdout_writer.print(csi ++ "48;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }); // bg
                try stdout_writer.print(csi ++ "38;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }); // fg
                try stdout_writer.print("{c}", .{' '});
            }
        }
    }

    // status line at the top
    try stdout_writer.print(csi ++ "{d};{d}H", .{ 1, 1 });
    try stdout_writer.print(csi ++ "48;2;{d};{d};{d}m", .{ 0xFF, 0xFF, 0xFF }); // bg
    try stdout_writer.print(csi ++ "38;2;{d};{d};{d}m", .{ 0x00, 0x00, 0x00 }); // fg
    for (0..term_width) |_| try stdout_writer.print(" ", .{});
    switch(opmode) {
        .Normal => try stdout_writer.print(csi ++ "{d};{d}HMenu:{{ctrl-a}} {s} {s}", .{ 1, 1, portname, comm_desc }),
        .Menu => try stdout_writer.print(csi ++ "{d};{d}HBack:{{esc}} Quit:{{q,\\,x}}", .{ 1, 1}),
        else => {},
    }

    // move cursor
    const cursorPos = term.getCursorPos();
    try stdout_writer.print(csi ++ "{d};{d}H", .{ cursorPos.y + 1 + num_status_lines, cursorPos.x + 1 });

    // show cursor
    try stdout_writer.print(csi ++ "?25h", .{});

    try stdout_writer.print(csi ++ "?2026l", .{}); // resume updating
}

pub fn hostcmdtrapper(data:[]const u8) !bool {
    const orig_opmode = opmode;
    for (data) |c| {
        switch(opmode) {
            .Normal => {    // see if ctrl-a is pressed
                if (c == std.ascii.control_code.soh) {
                    opmode = .Menu;
                }
            },
            .Menu => {
                switch(c) {
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
    var serial = std.fs.cwd().openFile(conf.portname, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("'{s}' does not exist\n", .{conf.portname});
            return;
        },
        error.DeviceBusy => {
            std.debug.print("'{s}' is busy\n", .{conf.portname});
            return;
        },
        else => return err,
    };

    defer serial.close();

    try zig_serial.configureSerialPort(serial, conf.serial_config);

    var comm_desc_buf:[64]u8 = undefined;
    const comm_desc = try conf.serial_config.bufPrint(&comm_desc_buf);

    try raw_mode_start();

    term = try ZVTerm.init(allocator, term_width, term_height - num_status_lines); // leave space for status lines
    termwriter = term.getWriter();

    defer raw_mode_stop();

    try redraw(conf.portname, comm_desc);

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

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const conf = config.parseCommandLine(allocator) catch {
        return;
    };

    if (conf) |cnf| {
        try commloop(allocator, cnf);
    }
}

