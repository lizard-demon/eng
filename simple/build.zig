const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl3 = b.dependency("sdl3", .{
        .target  = target,
        .optimize = optimize,
        .c_sdl_preferred_linkage = .static,
        .main    = true,
    });

    const engine_dep = b.dependency("engine", .{
        .target  = target,
        .optimize = optimize,
    });

    const gpu_mod = b.createModule(.{
        .root_source_file = b.path("src/gpu_sdl3.zig"),
        .target  = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine", .module = engine_dep.module("engine") },
            .{ .name = "sdl3",   .module = sdl3.module("sdl3") },
        },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target  = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine",   .module = engine_dep.module("engine") },
            .{ .name = "sdl3",     .module = sdl3.module("sdl3") },
            .{ .name = "gpu_sdl3", .module = gpu_mod },
        },
    });

    const exe = b.addExecutable(.{ .name = "demo", .root_module = mod });

    // ── Shader compilation ────────────────────────────────────────
    // glslc does not infer stage from .glsl extension; -fshader-stage
    // must be passed explicitly.  The exe compile step depends on all
    // shader steps so @embedFile("shaders/…spv") always finds the files.
    inline for (.{
        .{ .name = "triangle.vert", .stage = "vertex"   },
        .{ .name = "triangle.frag", .stage = "fragment" },
    }) |s| {
        const glslc = b.addSystemCommand(&.{
            "glslc",
            "-fshader-stage=" ++ s.stage,
            "src/shaders/" ++ s.name ++ ".glsl",
            "-o",
            "src/shaders/" ++ s.name ++ ".spv",
        });
        glslc.setCwd(b.path("."));
        // Exe compilation depends on shaders existing for @embedFile.
        exe.step.dependOn(&glslc.step);
    }

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the demo").dependOn(&run.step);

    // Standalone `zig build shaders` still works for manual recompilation.
    const shaders_step = b.step("shaders", "Compile GLSL → SPIR-V only");
    inline for (.{
        .{ .name = "triangle.vert", .stage = "vertex"   },
        .{ .name = "triangle.frag", .stage = "fragment" },
    }) |s| {
        const glslc = b.addSystemCommand(&.{
            "glslc",
            "-fshader-stage=" ++ s.stage,
            "shaders/" ++ s.name ++ ".glsl",
            "-o",
            "shaders/" ++ s.name ++ ".spv",
        });
        glslc.setCwd(b.path("."));
        shaders_step.dependOn(&glslc.step);
    }
}
