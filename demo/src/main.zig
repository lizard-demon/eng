//! main.zig — FPS walker demo
//!
//! Shows every framework module working together:
//!   math · geo · BVH · phys · gfx.Renderer · Pool
//! All wired through comptime generics, zero vtables.
//
const std = @import("std");
const sdl = @import("sdl3");
const eng = @import("engine");
const gpu_mod = @import("gpu_sdl3");

const Vec3 = eng.Vec3;
const Mat4 = eng.Mat4;
const AABB = eng.AABB;
const Ray = eng.Ray;

// ── types ─────────────────────────────────────────────────────────

const Gpu = gpu_mod.Gpu;
const Ren = eng.Renderer(Gpu); // comptime-monomorphised 3D renderer

const Player = eng.Body(.{
    .gravity = 12.0,
    .jump_speed = 5.0,
    .max_speed = 5.5,
    .air_speed = 1.0,
    .accel = 55.0,
    .friction = 6.0,
    .margin = 0.02,
    .slope_limit = 0.707,
    .max_slides = 4,
    .radius = 0.3,
});

// ── level geometry ────────────────────────────────────────────────

const Brush = struct {
    aabb: AABB,
    expanded: AABB, // padded by player radius for swept-sphere collision
    color: [4]f32,

    pub fn bounds(self: Brush) AABB { return self.expanded; }

    pub fn hitDist(self: Brush, ray: Ray, max_t: f32) ?f32 {
        return ray.hitAABB(self.expanded, max_t);
    }

    pub fn hitNormal(self: Brush, ray: Ray, t: f32) eng.phys.Hit {
        const p = ray.at(t);
        var best_n = Vec3.zero;
        var best_d: f32 = std.math.floatMax(f32);
        for (0..3) |i| {
            const dlo = @abs(p.v[i] - self.expanded.min.v[i]);
            if (dlo < best_d) {
                best_d = dlo;
                best_n = Vec3.zero;
                best_n.v[i] = -1;
            }
            const dhi = @abs(p.v[i] - self.expanded.max.v[i]);
            if (dhi < best_d) {
                best_d = dhi;
                best_n = Vec3.zero;
                best_n.v[i] = 1;
            }
        }
        return .{ .normal = best_n, .dist = t };
    }
};

fn brush(lo: [3]f32, hi: [3]f32, color: [4]f32) Brush {
    const a = AABB.init(Vec3{ .v = lo }, Vec3{ .v = hi });
    return .{ .aabb = a, .expanded = a.pad(0.3), .color = color };
}

const W = [4]f32{ 0.50, 0.44, 0.38, 1 }; // walls
const F = [4]f32{ 0.30, 0.34, 0.30, 1 }; // floor
const P = [4]f32{ 0.60, 0.52, 0.42, 1 }; // pillars
const C = [4]f32{ 0.42, 0.42, 0.50, 1 }; // center

const level = [_]Brush{
    brush(.{ -15, -0.5, -15 }, .{ 15, 0, 15 }, F), // floor
    brush(.{ -15, 0, -15 }, .{ -14, 3, 15 }, W), // L wall
    brush(.{ 14, 0, -15 }, .{ 15, 3, 15 }, W), // R wall
    brush(.{ -15, 0, -15 }, .{ 15, 3, -14 }, W), // back wall
    brush(.{ -15, 0, 14 }, .{ 15, 3, 15 }, W), // front wall
    brush(.{ -5, 0, -5 }, .{ -4, 2.5, -4 }, P),
    brush(.{ 4, 0, -5 }, .{ 5, 2.5, -4 }, P),
    brush(.{ -5, 0, 4 }, .{ -4, 2.5, 5 }, P),
    brush(.{ 4, 0, 4 }, .{ 5, 2.5, 5 }, P),
    brush(.{ -2, 0, -2 }, .{ 2, 1, 2 }, C), // center block
    brush(.{ -1, 1, -1 }, .{ 1, 1.6, 1 }, C), // top tier
};

// ── physics world adapter (fulfils Body's anytype contract) ───────

const World = struct {
    tree: *const eng.BVH(Brush),
    data: []const Brush,

    pub fn cast(self: World, origin: Vec3, dir: Vec3, max_d: f32) ?eng.phys.Hit {
        const ray = Ray{ .origin = origin, .dir = dir };
        const hit = self.tree.raycast(ray, max_d, Brush.hitDist) orelse return null;
        return self.data[hit.index].hitNormal(ray, hit.dist);
    }
};

// ── entry ─────────────────────────────────────────────────────────

const win_w: i32 = 1280;
const win_h: i32 = 720;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });

    const win = try sdl.video.Window.init("Engine Demo — WASD+Mouse+Space", win_w, win_h, .{});
    defer win.deinit();
    const ren = try sdl.render.Renderer.init(win, null);
    defer ren.deinit();

    // BVH
    var tree = try eng.BVH(Brush).init(&level, alloc);
    defer tree.deinit();

    // GPU + Renderer
    var renderer = Ren.init(Gpu.init(ren, @floatFromInt(win_w), @floatFromInt(win_h), alloc));
    defer renderer.gpu.deinit();

    // Upload one mesh per brush (individual colors)
    var handles: [level.len]Gpu.Handle = undefined;
    for (level, 0..) |b, i| {
        var bm = gpu_mod.boxMesh(b.aabb);
        handles[i] = try renderer.upload(&bm.pos, &bm.nrm, &bm.idx);
    }

    // Player + world
    var player = Player{ .pos = Vec3.init(0, 3, 0) };
    const world = World{ .tree = &tree, .data = &level };

    sdl.mouse.hide() catch {};

    var last_mx: f32 = @as(f32, @floatFromInt(@divTrunc(win_w, 2)));
    var last_my: f32 = @as(f32, @floatFromInt(@divTrunc(win_h, 2)));
    var running = true;

    while (running) {
        // ── events ───────────────────────────────────────────────
        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => running = false,
                else => {},
            }
        }

        // ── mouse look (poll + warp-to-center) ──────────────────
        _, const mx, const my = sdl.mouse.getState();
        const cx: f32 = @as(f32, @floatFromInt(@divTrunc(win_w, 2)));
        const cy: f32 = @as(f32, @floatFromInt(@divTrunc(win_h, 2)));
        player.yaw += (mx - last_mx) * 0.003;
        player.pitch = std.math.clamp(player.pitch - (my - last_my) * 0.003, -1.5, 1.5);
        last_mx = mx;
        last_my = my;
        // Warp cursor back near center to prevent edge-lock
        if (@abs(mx - cx) > 200 or @abs(my - cy) > 150) {
            sdl.mouse.warpInWindow(win, cx, cy);
            last_mx = cx;
            last_my = cy;
        }

        // ── input ────────────────────────────────────────────────
        const keys = sdl.keyboard.getState();
        const sc = sdl.Scancode;
        const fwd: f32 = if (keys[@intFromEnum(sc.w)]) 1 else if (keys[@intFromEnum(sc.s)]) -1 else 0;
        const rgt: f32 = if (keys[@intFromEnum(sc.d)]) 1 else if (keys[@intFromEnum(sc.a)]) -1 else 0;
        const jump = keys[@intFromEnum(sc.space)];
        if (keys[@intFromEnum(sc.escape)]) running = false;

        // ── physics ──────────────────────────────────────────────
        const dt: f32 = 1.0 / 60.0; // vsync assumed; swap for real timing
        player.step(world, player.wishDir(fwd, rgt), jump, dt);

        // ── render ───────────────────────────────────────────────
        renderer.clear(.{ 0.06, 0.07, 0.12, 1 });

        const eye = player.eyePos();
        const look = player.lookDir();
        renderer.camera(eye, eye.add(look), Vec3.up, 1.22, //
            @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(win_h)), 0.1, 100);

        // Frustum-culled draw via BVH iterator
        var query = tree.queryFrustum(renderer.frust);
        while (query.next()) |idx| {
            renderer.gpu.draw(handles[idx], Mat4.identity, level[idx].color);
        }

        // Crosshair
        const cw = sdl.pixels.Color{ .r = 200, .g = 200, .b = 200, .a = 180 };
        ren.setDrawColor(cw) catch {};
        ren.renderLine(.{ .x = cx - 10, .y = cy }, .{ .x = cx - 4, .y = cy }) catch {};
        ren.renderLine(.{ .x = cx + 4, .y = cy }, .{ .x = cx + 10, .y = cy }) catch {};
        ren.renderLine(.{ .x = cx, .y = cy - 10 }, .{ .x = cx, .y = cy - 4 }) catch {};
        ren.renderLine(.{ .x = cx, .y = cy + 4 }, .{ .x = cx, .y = cy + 10 }) catch {};

        ren.present() catch {};
    }
}
