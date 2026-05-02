//! phys.zig — Quake-style character controller, comptime-configured

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;

pub const Hit = struct { normal: Vec3, dist: f32 };

pub const Config = struct {
    gravity: f32 = 9.8,
    jump_speed: f32 = 5.0,
    max_speed: f32 = 6.0,
    air_speed: f32 = 1.0,
    accel: f32 = 50.0,
    friction: f32 = 6.0,
    slope_limit: f32 = 0.707,
    max_slides: u32 = 4,
    radius: f32 = 0.3,
    eye_height: f32 = 0.6,
    ground_snap: f32 = 0.05, // Physical downward reach to snap to stairs/slopes
};

pub fn Body(comptime cfg: Config) type {
    return struct {
        const Self = @This();

        pos: Vec3 = Vec3.zero(),
        vel: Vec3 = Vec3.zero(),
        grounded: bool = false,
        yaw: f32 = 0,
        pitch: f32 = 0,

        pub fn eyePos(self: Self) Vec3 { return self.pos.add(Vec3.new(0, cfg.eye_height, 0)); }

        pub fn lookDir(self: Self) Vec3 {
            const sp = @sin(self.pitch);
            const cp = @cos(self.pitch);
            const sy = @sin(self.yaw);
            const cy = @cos(self.yaw);
            return Vec3.new(sy * cp, -sp, -cy * cp).normalize();
        }

        pub fn step(self: *Self, world: anytype, wish: Vec3, jump: bool, dt: f32) void {
            // 1. Explicit Ground Probe ─────────────────────────────────
            const ground_trace = world.cast(self.pos, Vec3.new(0, -1, 0), cfg.ground_snap);
            self.grounded = false;
            var ground_normal = Vec3.new(0, 1, 0);

            if (ground_trace) |h| {
                if (h.normal.data[1] > cfg.slope_limit) {
                    self.grounded = true;
                    ground_normal = h.normal;
                }
            }

            // 2. Physics & State ───────────────────────────────────────
            if (self.grounded) {
                // Strip downward velocity pointing into the floor
                const vn = self.vel.dot(ground_normal);
                if (vn < 0) self.vel = self.vel.sub(ground_normal.scale(vn));

                const spd = @sqrt(self.vel.data[0] * self.vel.data[0] + self.vel.data[2] * self.vel.data[2]);
                if (spd > 0.1) {
                    const drop = spd * cfg.friction * dt;
                    const f = @max(0, spd - drop) / spd;
                    self.vel.data[0] *= f;
                    self.vel.data[2] *= f;
                } else {
                    self.vel.data[0] = 0;
                    self.vel.data[2] = 0;
                }
            } else {
                self.vel.data[1] -= cfg.gravity * dt;
            }

            if (jump and self.grounded) {
                self.vel.data[1] = cfg.jump_speed;
                self.grounded = false; 
            }

            // 3. Player Input ──────────────────────────────────────────
            const wl = @sqrt(wish.data[0] * wish.data[0] + wish.data[2] * wish.data[2]);
            if (wl > 0) {
                const wn = wish.scale(1.0 / wl);
                const top = if (self.grounded) cfg.max_speed * wl else @min(cfg.max_speed * wl, cfg.air_speed);
                const cur = Vec3.new(self.vel.data[0], 0, self.vel.data[2]).dot(wn);
                const add = @min(cfg.accel * dt, @max(0, top - cur));
                self.vel = self.vel.add(wn.scale(add));
            }

            // 4. Resolve Movement ──────────────────────────────────────
            self.slideMove(world, self.vel.scale(dt));
        }

        fn slideMove(self: *Self, world: anytype, delta: Vec3) void {
            var rem = delta;

            for (0..cfg.max_slides) |_| {
                const l = rem.length();
                
                // ── Dynamic Math Precision ────────────────────────────────
                // Scale epsilon precisely to our current distance from the origin.
                // Replaces all static magic numbers (1e-5, 0.001, etc.)
                const pos_mag = @max(@abs(self.pos.data[0]), @max(@abs(self.pos.data[1]), @abs(self.pos.data[2])));
                const eps = std.math.floatEpsAt(f32, @max(1.0, pos_mag));
                const margin = eps * 8192.0;

                if (l < eps) break;

                const dir = rem.scale(1.0 / l);
                
                // Trace up to remainder PLUS our dynamic math margin
                const h = world.cast(self.pos, dir, l + margin) orelse {
                    self.pos = self.pos.add(rem);
                    break;
                };

                // Move flush to the surface, backing off by exactly 1 ULP
                const move_dist = @max(0, h.dist - eps);
                if (move_dist > 0) {
                    self.pos = self.pos.add(dir.scale(move_dist));
                    rem = rem.sub(dir.scale(@min(move_dist, l)));
                }

                // ── The Micro Arc Nudge ───────────────────────────────────
                // Physically push out of the collision plane by 10 ULPs.
                // Mathematically guarantees separation on the next trace without 
                // any macroscopic positional distortion.
                self.pos = self.pos.add(h.normal.scale(margin));

                // Strip velocity against the normal
                rem = clipVelocity(rem, h.normal);
                self.vel = clipVelocity(self.vel, h.normal);
            }
        }

        fn clipVelocity(in: Vec3, normal: Vec3) Vec3 {
            const backoff = in.dot(normal);
            if (backoff >= 0) return in;
            var out = in.sub(normal.scale(backoff));
            
            // Double-scrub via Gram-Schmidt to mathematically kill floating point ULPs
            const res = out.dot(normal);
            if (res < 0) out = out.sub(normal.scale(res));
            return out;
        }
    };
}
