//! main.zig — FPS walker + runtime BSP editor (SDL3 GPU · exact plane collision)
const std = @import("std");
const sdl = @import("sdl3");
const eng = @import("engine");
const gpu_mod = @import("gpu_sdl3");
const Vec3 = eng.Vec3;
const Mat4 = eng.Mat4;
const Bsp = eng.Bsp;
const GpuBackend = gpu_mod.Gpu;
const Ren = eng.Renderer(GpuBackend);

const Player = eng.Body(.{
    .gravity     = 12.0,
    .jump_speed  = 5.0,
    .max_speed   = 5.5,
    .air_speed   = 1.0,
    .accel       = 55.0,
    .friction    = 6.0,
    .margin      = 0.02,
    .slope_limit = 0.707,
    .max_slides  = 4,
    .radius      = 0.3,
    .eye_height  = 0.6,
});

// ── BSP physics adapter (duck-types for Body.step) ────────────────
const World = struct {
    bsp: *const Bsp,
    radius: f32,
    pub fn cast(self: World, origin: Vec3, dir: Vec3, max_d: f32) ?eng.phys.Hit {
        const r = self.bsp.trace(origin, dir, max_d, self.radius) orelse return null;
        return .{ .normal = r.normal, .dist = r.dist };
    }
};

// ── Editor state ──────────────────────────────────────────────────
const Editor = struct {
    active: bool = false,
    placing: bool = false,
    anchor: Vec3 = Vec3.zero(),
    grid_size: f32 = 1.0,
    angle_step: f32 = std.math.pi / 12.0, // 15°
};

fn snapToGrid(v: Vec3, s: f32) Vec3 {
    return Vec3.new(
        @round(v.data[0] / s) * s,
        @round(v.data[1] / s) * s,
        @round(v.data[2] / s) * s,
    );
}
fn snapAngle(a: f32, step: f32) f32 {
    return @round(a / step) * step;
}

// ── Entry ─────────────────────────────────────────────────────────
const win_w: i32 = 1280;
const win_h: i32 = 720;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });

    const win = try sdl.video.Window.init(
        "BSP Editor — E=editor  click=split  shift=snap  scroll=grid",
        win_w, win_h, .{},
    );
    defer win.deinit();
    const device = try sdl.gpu.Device.init(.{ .spirv = true }, true, null);

    // ── BSP world ─────────────────────────────────────────────────
    var bsp = Bsp.init(alloc);
    defer bsp.deinit();

    try bsp.initGroundPlane(0);
    try bsp.rebuildMesh();

    // ── Renderer ──────────────────────────────────────────────────
    var renderer = Ren.init(try GpuBackend.init(device, win, alloc));
    defer renderer.gpu.deinit();

    const mesh_handle = try renderer.upload(
        std.mem.sliceAsBytes(bsp.render_verts.items),
        @sizeOf(eng.Vertex),
        std.mem.sliceAsBytes(bsp.render_indices.items),
        @intCast(bsp.render_indices.items.len),
    );

    // ── Game state ────────────────────────────────────────────────
    var player = Player{ .pos = Vec3.new(0, 1.5, 0) };
    const world = World{ .bsp = &bsp, .radius = 0.3 };
    var mouse_locked = false;
    var editor = Editor{};
    var running = true;

    while (running) {
        var mdx: f32 = 0;
        var mdy: f32 = 0;

        // ── keyboard state (polled once per frame) ────────────────
        const keys = sdl.keyboard.getState();
        const sc   = sdl.Scancode;
        const shift = keys[@intFromEnum(sc.left_shift)];

        // ── events ────────────────────────────────────────────────
        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => running = false,

                .key_down => |k| {
                    if (k.scancode) |ksc| {
                        if (ksc == .escape and mouse_locked) {
                            mouse_locked = false;
                            sdl.mouse.show() catch {};
                            sdl.mouse.setWindowRelativeMode(win, false) catch {};
                        }
                        if (ksc == .e and mouse_locked) {
                            editor.active = !editor.active;
                            editor.placing = false;
                        }
                    }
                },

                .mouse_button_down => |m| {
                    if (m.button == .left) {
                        if (!mouse_locked) {
                            mouse_locked = true;
                            sdl.mouse.hide() catch {};
                            sdl.mouse.setWindowRelativeMode(win, true) catch {};
                        } else if (editor.active and !editor.placing) {
                            // hitscan from eye along look direction
                            const eye = player.eyePos();
                            const dir = player.lookDir();
                            if (bsp.trace(eye, dir, 200, 0)) |hit| {
                                var anchor = eye.add(dir.scale(hit.dist));
                                // push slightly into empty side
                                anchor = anchor.add(hit.normal.scale(0.01));
                                if (shift) anchor = snapToGrid(anchor, editor.grid_size);
                                editor.anchor = anchor;
                                editor.placing = true;
                            }
                        }
                    }
                },

                .mouse_button_up => |m| {
                    if (m.button == .left and editor.placing) {
                        var normal = player.lookDir();
                        if (shift) {
                             const snap_y = snapAngle(player.yaw,   editor.angle_step);
                             const snap_p = snapAngle(player.pitch, editor.angle_step);
                             const cp = @cos(snap_p);
                             normal = Vec3.new(
                                 @sin(snap_y) * cp,
                                 -@sin(snap_p),      // -sin(pitch), consistent with lookDir fix
                                 -@cos(snap_y) * cp,
                             ).normalize();
                        }
                        _ = bsp.editorSplit(editor.anchor, normal) catch false;
                        editor.placing = false;
                    }
                },

                .mouse_wheel => |w| {
                    if (editor.active and w.y != 0) {
                        const f: f32 = if (w.y > 0) 0.5 else 2.0;
                        if (editor.placing) {
                            editor.angle_step = std.math.clamp(
                                editor.angle_step * f,
                                std.math.pi / 180.0,
                                std.math.pi / 4.0,
                            );
                        } else {
                            editor.grid_size = std.math.clamp(
                                editor.grid_size * f,
                                0.0625,
                                16.0,
                            );
                        }
                    }
                },

                .mouse_motion => |m| {
                    if (mouse_locked) { mdx += m.x_rel; mdy += m.y_rel; }
                },

                else => {},
            }
        }

        // ── look ──────────────────────────────────────────────────
        if (mouse_locked) {
            player.yaw += mdx * 0.002;
            player.pitch = std.math.clamp(player.pitch + mdy * 0.002, -1.5, 1.5);
        }

        // ── movement input ────────────────────────────────────────
        const fwd_in: f32 = if (keys[@intFromEnum(sc.w)] ) 1 else if (keys[@intFromEnum(sc.s)] ) @as(f32, -1) else 0;
        const rgt_in: f32 = if (keys[@intFromEnum(sc.d)] ) 1 else if (keys[@intFromEnum(sc.a)] ) @as(f32, -1) else 0;
        const jump = keys[@intFromEnum(sc.space)];

        // ── physics ───────────────────────────────────────────────
        const dt: f32 = 1.0 / 60.0;
        player.step(world, eng.wishdir(fwd_in, rgt_in, player.yaw), jump, dt);

        // ── mesh rebuild (between frames) ─────────────────────────
        if (bsp.mesh_dirty) {
            try bsp.rebuildMesh();
            if (bsp.render_indices.items.len > 0) {
                try renderer.gpu.updateMesh(
                    mesh_handle,
                    std.mem.sliceAsBytes(bsp.render_verts.items),
                    std.mem.sliceAsBytes(bsp.render_indices.items),
                    @intCast(bsp.render_indices.items.len),
                );
            }
        }

        // ── render ────────────────────────────────────────────────
        if (try renderer.beginFrame()) {
            const aspect = @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(win_h));
            renderer.cameraEuler(
                player.pos, player.yaw, player.pitch, 0.6,
                90.0, aspect, 0.1, 500.0,
            );
            renderer.drawDirect(mesh_handle, Mat4.identity(), .{ 1, 1, 1, 1 });
            try renderer.endFrame();
        }
    }
}
