//! main.zig — FPS walker demo (SDL3 GPU · BVH · Quake physics)

const std = @import("std");
const sdl = @import("sdl3");
const eng = @import("engine");
const gpu_mod = @import("gpu_sdl3");

const Vec3 = eng.Vec3;
const Mat4 = eng.Mat4;
const AABB = eng.AABB;
const Ray  = eng.Ray;

const GpuBackend = gpu_mod.Gpu;
const Ren        = eng.Renderer(GpuBackend);

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

// ── Level brushes ─────────────────────────────────────────────────

const Brush = struct {
    aabb:     AABB,
    expanded: AABB,
    color:    [4]f32,

    pub fn bounds(self: Brush) AABB { return self.expanded; }

    pub fn hitDist(self: Brush, ray: Ray, max_t: f32) ?f32 {
        return ray.hitAABB(self.expanded, max_t);
    }

    pub fn hitNormal(self: Brush, ray: Ray, t: f32) eng.phys.Hit {
        const p = ray.at(t);
        var best_n = Vec3.zero();
        var best_d: f32 = std.math.floatMax(f32);
        for (0..3) |i| {
            const dlo = @abs(p.data[i] - self.expanded.lo.data[i]);
            if (dlo < best_d) {
                best_d         = dlo;
                best_n         = Vec3.zero();
                best_n.data[i] = -1;
            }
            const dhi = @abs(p.data[i] - self.expanded.hi.data[i]);
            if (dhi < best_d) {
                best_d         = dhi;
                best_n         = Vec3.zero();
                best_n.data[i] = 1;
            }
        }
        return .{ .normal = best_n, .dist = t };
    }
};

fn mkBrush(lo: [3]f32, hi: [3]f32, col: [4]f32) Brush {
    const a = AABB.new(
        Vec3{ .data = .{ lo[0], lo[1], lo[2] } },
        Vec3{ .data = .{ hi[0], hi[1], hi[2] } },
    );
    return .{ .aabb = a, .expanded = a.pad(0.3), .color = col };
}

const W = [4]f32{ 0.50, 0.44, 0.38, 1 };
const F = [4]f32{ 0.30, 0.34, 0.30, 1 };
const P = [4]f32{ 0.60, 0.52, 0.42, 1 };
const C = [4]f32{ 0.42, 0.42, 0.50, 1 };

const level = [_]Brush{
    mkBrush(.{ -15, -0.5, -15 }, .{  15,  0,   15  }, F),
    mkBrush(.{ -15,  0,  -15  }, .{ -14,  3,   15  }, W),
    mkBrush(.{  14,  0,  -15  }, .{  15,  3,   15  }, W),
    mkBrush(.{ -15,  0,  -15  }, .{  15,  3,  -14  }, W),
    mkBrush(.{ -15,  0,   14  }, .{  15,  3,   15  }, W),
    mkBrush(.{  -5,  0,   -5  }, .{  -4,  2.5, -4  }, P),
    mkBrush(.{   4,  0,   -5  }, .{   5,  2.5, -4  }, P),
    mkBrush(.{  -5,  0,    4  }, .{  -4,  2.5,  5  }, P),
    mkBrush(.{   4,  0,    4  }, .{   5,  2.5,  5  }, P),
    mkBrush(.{  -2,  0,   -2  }, .{   2,  1,    2  }, C),
    mkBrush(.{  -1,  1,   -1  }, .{   1,  1.6,  1  }, C),
};

// ── Physics world adapter ─────────────────────────────────────────

const World = struct {
    tree: *const eng.BVH(Brush),
    data: []const Brush,

    pub fn cast(self: World, origin: Vec3, dir: Vec3, max_d: f32) ?eng.phys.Hit {
        const ray = Ray{ .origin = origin, .dir = dir };
        const hit = self.tree.raycast(ray, max_d, Brush.hitDist) orelse return null;
        return self.data[hit.index].hitNormal(ray, hit.dist);
    }
};

// ── Entry ─────────────────────────────────────────────────────────

const win_w: i32 = 1280;
const win_h: i32 = 720;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });

    const win = try sdl.video.Window.init(
        "Engine Demo — click to capture mouse, ESC to release",
        win_w, win_h, .{},
    );
    defer win.deinit();

    const device = try sdl.gpu.Device.init(.{ .spirv = true }, true, null);

    var tree = try eng.BVH(Brush).init(&level, alloc);
    defer tree.deinit();

    var renderer = Ren.init(try GpuBackend.init(device, win, alloc));
    defer renderer.gpu.deinit();

    // ── Build geometry ────────────────────────────────────────────
    var all_verts   = std.ArrayListUnmanaged(eng.Vertex){};
    defer all_verts.deinit(alloc);
    var all_indices = std.ArrayListUnmanaged(u32){};
    defer all_indices.deinit(alloc);

    for (level) |b| {
        const bm   = gpu_mod.boxVertices(b.aabb, b.color);
        const base: u32 = @intCast(all_verts.items.len);
        try all_verts.appendSlice(alloc, &bm.verts);
        for (bm.indices) |idx| try all_indices.append(alloc, base + idx);
    }

    const handle = try renderer.upload(
        std.mem.sliceAsBytes(all_verts.items),
        @sizeOf(eng.Vertex),
        std.mem.sliceAsBytes(all_indices.items),
        @intCast(all_indices.items.len),
    );

    var level_aabb = level[0].aabb;
    for (level[1..]) |b| level_aabb = level_aabb.merge(b.aabb);

    // ── Game state ────────────────────────────────────────────────
    var player       = Player{ .pos = Vec3.new(0, 1.5, -8) };
    const world      = World{ .tree = &tree, .data = &level };
    var mouse_locked = false;
    var running      = true;

    while (running) {
        var mdx: f32 = 0;
        var mdy: f32 = 0;

        // ── Events ───────────────────────────────────────────────
        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => running = false,

                .key_down => |k| {
                    if (k.scancode) |sc| {
                        if (sc == .escape and mouse_locked) {
                            mouse_locked = false;
                            sdl.mouse.show()                            catch {};
                            sdl.mouse.setWindowRelativeMode(win, false) catch {};
                        }
                        if (sc == .escape and !mouse_locked) running = false;
                    }
                },

                .mouse_button_down => |m| {
                    if (m.button == .left and !mouse_locked) {
                        mouse_locked = true;
                        sdl.mouse.hide()                           catch {};
                        sdl.mouse.setWindowRelativeMode(win, true) catch {};
                    }
                },

                .mouse_motion => |m| {
                    // SDL3 Zig binding: xrel/yrel → x_rel/y_rel
                    if (mouse_locked) { mdx += m.x_rel; mdy += m.y_rel; }
                },

                else => {},
            }
        }

        // ── Look ─────────────────────────────────────────────────
        if (mouse_locked) {
            player.yaw  += mdx * 0.002;
            player.pitch = std.math.clamp(player.pitch + mdy * 0.002, -1.5, 1.5);
        }

        // ── Input ────────────────────────────────────────────────
        const keys    = sdl.keyboard.getState();
        const sc      = sdl.Scancode;
        const fwd_in: f32 = if (keys[@intFromEnum(sc.w)]) 1 else if (keys[@intFromEnum(sc.s)]) -1 else 0;
        const rgt_in: f32 = if (keys[@intFromEnum(sc.d)]) 1 else if (keys[@intFromEnum(sc.a)]) -1 else 0;
        const jump        = keys[@intFromEnum(sc.space)];

        // ── Physics ──────────────────────────────────────────────
        const dt: f32 = 1.0 / 60.0;
        player.step(world, eng.wishdir(fwd_in, rgt_in, player.yaw), jump, dt);

        // ── Render ───────────────────────────────────────────────
        if (try renderer.beginFrame()) {
            const aspect = @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(win_h));
            renderer.cameraEuler(
                player.pos, player.yaw, player.pitch, 0.6,
                90.0, aspect, 0.1, 100.0,
            );
            renderer.draw(handle, Mat4.identity(), level_aabb, .{ 1, 1, 1, 1 });
            try renderer.endFrame();
        }
    }
}
