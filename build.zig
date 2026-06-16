const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3 = b.dependency("sdl3", .{
        .target  = target,
        .optimize = optimize,
        .c_sdl_preferred_linkage = .static,
        .main    = true,
    });

    // Expose the engine as a module for downstream consumers.
    _ = b.addModule("engine", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdl3",     .module = sdl3.module("sdl3") },
        },
    });
}
