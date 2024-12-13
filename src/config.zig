const std = @import("std");
const yazap = @import("yazap");
const zig_serial = @import("serial");

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

    const list_opt = Arg.booleanOption("list", 'l', "List available serial ports");
    try root.addArg(list_opt);

    const echo_opt = Arg.booleanOption("echo", 'e', "Enable local echo");
    try root.addArg(echo_opt);

    const log_opt = Arg.singleValueOption("output", 'o', "Log to file");
    try root.addArg(log_opt);

    try root.addArg(Arg.positional("port", "serial port file", 1));
    try root.addArg(Arg.positional("speed", "baudrate", 2));

    const matches = try app.parseProcess();

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
