const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,

        .ext_image = true,
        .ext_net = true,
        .ext_ttf = true,
        .main = true,

        .c_sdl_preferred_linkage = .static,
    });

    const engine_dep = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine", .module = engine_dep.module("engine") },
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
        },
    });

    mod.addImport("gpu_sdl3", b.createModule(.{
        .root_source_file = b.path("src/gpu_sdl3.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine", .module = engine_dep.module("engine") },
            .{ .name = "sdl3", .module = sdl3.module("sdl3") },
        },
    }));

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the demo").dependOn(&run.step);
}
