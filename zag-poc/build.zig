const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name    = "zagc",
        .root_source_file = b.path("src/main.zig"),
        .target  = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |a| run_cmd.addArgs(a);
    const run_step = b.step("run", "Run zagc");
    run_step.dependOn(&run_cmd.step);
}
