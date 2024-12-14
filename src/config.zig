const std = @import("std");
const yazap = @import("yazap");
const zig_serial = @import("serial");
const build_info = @import("build_info");

pub const Config = struct {
    portname: []u8,
    serial_config: zig_serial.SerialConfig,
    log_file: ?std.fs.File,
    local_echo: bool,
};

// parse command line and return an allocated Config
pub fn parseCommandLine(allocator: std.mem.Allocator) !?*Config {
    const App = yazap.App;
    const Arg = yazap.Arg;
    
    // default config
    var serial_config: zig_serial.SerialConfig = .{
        .baud_rate = 115200,
        .word_size = .eight,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    };

    var app = App.init(allocator, "commy", null);
    defer app.deinit();

    var root = app.rootCommand();

    root.setProperty(.help_on_empty_args);

    const version_opt = Arg.booleanOption("version", 'v', "Version");
    try root.addArg(version_opt);

    const list_opt = Arg.booleanOption("list", 'l', "List available serial ports");
    try root.addArg(list_opt);

    const echo_opt = Arg.booleanOption("echo", 'e', "Enable local echo");
    try root.addArg(echo_opt);

    const log_opt = Arg.singleValueOption("output", 'o', "Log to file");
    try root.addArg(log_opt);

    // extract parity, wordsize, stop and start possibilities from the enums and create cmdline opts
    var parityNames:[std.meta.fields(zig_serial.Parity).len][]const u8 = undefined;
    inline for (std.meta.fields(zig_serial.Parity), 0..) |f, i| {
        parityNames[i] = f.name;
    }
    const parity_opt = Arg.singleValueOptionWithValidValues("parity", 'p', "Parity", &parityNames);
    try root.addArg(parity_opt);

    var wordsizeNames:[std.meta.fields(zig_serial.WordSize).len][]const u8 = undefined;
    inline for (std.meta.fields(zig_serial.WordSize), 0..) |f, i| {
        wordsizeNames[i] = f.name;
    }
    const wordsize_opt = Arg.singleValueOptionWithValidValues("wordsize", 'w', "wordsize", &wordsizeNames);
    try root.addArg(wordsize_opt);

    var stopNames:[std.meta.fields(zig_serial.StopBits).len][]const u8 = undefined;
    inline for (std.meta.fields(zig_serial.StopBits), 0..) |f, i| {
        stopNames[i] = f.name;
    }
    const stop_opt = Arg.singleValueOptionWithValidValues("stop", 's', "stop", &stopNames);
    try root.addArg(stop_opt);

    var handshakeNames:[std.meta.fields(zig_serial.Handshake).len][]const u8 = undefined;
    inline for (std.meta.fields(zig_serial.Handshake), 0..) |f, i| {
        handshakeNames[i] = f.name;
    }
    const handshake_opt = Arg.singleValueOptionWithValidValues("flow", 'f', "flow", &handshakeNames);
    try root.addArg(handshake_opt);


    try root.addArg(Arg.positional("port", "serial port file", 1));
    try root.addArg(Arg.positional("speed", "baudrate", 2));

    const matches = try app.parseProcess();

    if (matches.containsArg("version")) {
        std.debug.print("https://github.com/ringtailsoftware/commy/{s}", .{build_info.git_commit});
        return null;
    }

    if (matches.containsArg("list")) {
        var iterator = try zig_serial.list();
        defer iterator.deinit();

        while (try iterator.next()) |port| {
            std.debug.print("{s}", .{port.file_name});
            if (!std.mem.eql(u8, port.file_name, port.display_name)) {
                std.debug.print(" ({s})", .{port.display_name});
            }
            std.debug.print("\n", .{});
        }

        return null;
    }

    if (matches.containsArg("parity")) {
        if (matches.getSingleValue("parity")) |s| {
            if (std.meta.stringToEnum(zig_serial.Parity, s)) |e| {
                serial_config.parity = e;
            } else {
                return null;
            }
        }
    }

    if (matches.containsArg("wordsize")) {
        if (matches.getSingleValue("wordsize")) |s| {
            if (std.meta.stringToEnum(zig_serial.WordSize, s)) |e| {
                serial_config.word_size = e;
            } else {
                return null;
            }
        }
    }

    if (matches.containsArg("stop")) {
        if (matches.getSingleValue("stop")) |s| {
            if (std.meta.stringToEnum(zig_serial.StopBits, s)) |e| {
                serial_config.stop_bits = e;
            } else {
                return null;
            }
        }
    }

    if (matches.containsArg("flow")) {
        if (matches.getSingleValue("flow")) |s| {
            if (std.meta.stringToEnum(zig_serial.Handshake, s)) |e| {
                serial_config.handshake = e;
            } else {
                return null;
            }
        }
    }


    if (matches.containsArg("speed")) {
        if (matches.getSingleValue("speed")) |speed| {
            serial_config.baud_rate = std.fmt.parseInt(u32, speed, 10) catch {
                std.debug.print("Bad speed {s}\n", .{speed});
                return null;
            };
        }
    }

    if (matches.containsArg("port")) {
        if (matches.getSingleValue("port")) |port| {
            const config = try allocator.create(Config);
            config.* = .{
                .portname = try allocator.dupe(u8, port),
                .serial_config = serial_config,
                .log_file = null,
                .local_echo = false,
            };

            // process options which only make sense if we have a port
            if (matches.containsArg("output")) {
                if (matches.getSingleValue("output")) |outputFilename| {
                    config.log_file = try std.fs.cwd().createFile(outputFilename, .{ .truncate = false });
                    try config.log_file.?.seekFromEnd(0); // append
                }
            }

            if (matches.containsArg("echo")) {
                config.local_echo = true;
            }

            return config;
        }
    }

    return null;
}
