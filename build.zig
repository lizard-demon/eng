const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the kami module
    const kami_mod = b.addModule("kami", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    kami_mod.linkSystemLibrary("SDL3", .{});

    // Create the executable using the new root_module API
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    exe.root_module.addImport("kami", kami_mod);
    exe.linkSystemLibrary("SDL3");
    exe.linkLibC();

    // Compile GLSL to SPIR-V in-place for @embedFile
    const shaders = .{ "triangle.vert", "triangle.frag", "ui.vert", "ui.frag" };
    inline for (shaders) |shader| {
        const cmd = b.addSystemCommand(&.{"glslc"});
        cmd.addArg(b.fmt("demo/src/shaders/{s}", .{shader})); // Removed .glsl
        cmd.addArg("-o");
        cmd.addArg(b.fmt("demo/src/shaders/{s}.spv", .{shader}));
        exe.step.dependOn(&cmd.step);
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);
}
