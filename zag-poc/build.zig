const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Build the bootstrap compiler (Zig -> C)
    const bootstrap_exe = b.addExecutable(.{
        .name    = "zagc_bootstrap",
        .root_source_file = b.path("src/main.zig"),
        .target  = target,
        .optimize = optimize,
    });
    
    // We can also install the bootstrap compiler for debugging if needed, 
    // but the main goal is the self-hosted one.
    // b.installArtifact(bootstrap_exe);

    // 2. Run the bootstrap compiler to build the self-hosted compiler
    const run_bootstrap = b.addRunArtifact(bootstrap_exe);
    run_bootstrap.addArg("build");
    run_bootstrap.addFileArg(b.path("selfhost/zagc.zag"));
    
    // zagc build outputs to <stem>.out by default, so selfhost/zagc.zag -> selfhost/zagc.zag.out
    // We can just set the CWD to the project root so it finds everything correctly
    
    // 3. Install the resulting binary
    const install_selfhosted = b.addInstallBinFile(
        b.path("zagc"),
        "zagc"
    );
    install_selfhosted.step.dependOn(&run_bootstrap.step);
    
    b.getInstallStep().dependOn(&install_selfhosted.step);

    // Add a run step for the installed self-hosted compiler
    const run_step = b.step("run", "Run zagc (self-hosted)");
    const run_exe = b.addRunArtifact(bootstrap_exe); // just run the bootstrap one for now if user types `zig build run`
    if (b.args) |a| run_exe.addArgs(a);
    run_step.dependOn(&run_exe.step);
}
