const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_portaudio = b.dependency("portaudio", .{});

    const lib_portaudio = dep_portaudio.artifact("portaudio");

    const exe = b.addExecutable(.{
        .name = "wanc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(lib_portaudio);

    b.installArtifact(exe);

    const run_command = b.addRunArtifact(exe);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_command.addArgs(args);
    }
    const run_step = b.step("run", "run the application");
    run_step.dependOn(&run_command.step);
}
