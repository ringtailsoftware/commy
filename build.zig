const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "commy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    var opt = b.addOptions();
    opt.addOption([]const u8, "git_commit", b.option([]const u8, "git_commit", "Current git commit") orelse "");
    exe.root_module.addImport("build_info", opt.createModule());

    const yazap = b.dependency("yazap", .{});
    exe.root_module.addImport("yazap", yazap.module("yazap"));

    const zvterm = b.dependency("zvterm", .{});
    exe.root_module.addImport("zvterm", zvterm.module("zvterm"));

    const serial = b.dependency("serial", .{});
    exe.root_module.addImport("serial", serial.module("serial"));

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
