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
    margin: f32 = 0.02,
    slope_limit: f32 = 0.707,
    max_slides: u32 = 4,
    radius: f32 = 0.3,
    eye_height: f32 = 0.6,
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
            if (self.grounded) {
                const spd = @sqrt(self.vel.data[0] * self.vel.data[0] + self.vel.data[2] * self.vel.data[2]);
                if (spd > 0.1) {
                    const f = @max(0, spd - spd * cfg.friction * dt) / spd;
                    self.vel.data[0] *= f;
                    self.vel.data[2] *= f;
                } else {
                    self.vel.data[0] = 0;
                    self.vel.data[2] = 0;
                }
            }
            if (!self.grounded) self.vel.data[1] -= cfg.gravity * dt;
            if (jump and self.grounded) self.vel.data[1] = cfg.jump_speed;

            const wl = @sqrt(wish.data[0] * wish.data[0] + wish.data[2] * wish.data[2]);
            if (wl > 0) {
                const wn = wish.scale(1.0 / wl);
                const top = if (self.grounded) cfg.max_speed * wl else @min(cfg.max_speed * wl, cfg.air_speed);
                const cur = Vec3.new(self.vel.data[0], 0, self.vel.data[2]).dot(wn);
                const add = @min(cfg.accel * dt, @max(0, top - cur));
                self.vel = self.vel.add(wn.scale(add));
            }
            self.slideMove(world, self.vel.scale(dt));
        }

        fn slideMove(self: *Self, world: anytype, delta: Vec3) void {
            var rem = delta;
            self.grounded = false;

            for (0..cfg.max_slides) |_| {
                const l = rem.length();
                
                // ── Noise Floor ───────────────────────────────────────────
                // Use Zig's native epsilon to dynamically calculate the noise floor
                // based on world position. Prevents micro-slides.
                const pos_mag = @max(@abs(self.pos.data[0]), @max(@abs(self.pos.data[1]), @abs(self.pos.data[2])));
                const eps = std.math.floatEpsAt(f32, @max(1.0, pos_mag)) * 10.0;
                if (l < eps) break;

                const dir = rem.scale(1.0 / l);
                
                // Trace up to the remaining length PLUS the margin to catch grazing hits
                const h = world.cast(self.pos, dir, l + cfg.margin) orelse {
                    self.pos = self.pos.add(rem);
                    break;
                };

                // Move precisely to the hit point, minus a tiny mathematical offset
                const move_dist = @max(0, h.dist - eps);
                if (move_dist > 0) {
                    self.pos = self.pos.add(dir.scale(move_dist));
                    const move_l = @min(move_dist, l);
                    rem = rem.sub(dir.scale(move_l));
                }

                if (h.normal.data[1] > cfg.slope_limit) self.grounded = true;

                // ── The Arc Nudge ─────────────────────────────────────────
                // Physically pop the player out of the collision plane by `margin`.
                // 1. Escapes the t=0 floating point deadzone loop.
                // 2. Accumulates over multi-plane hits to seamlessly push the 
                //    player in an arc *around* sharp convex Minkowski spikes.
                self.pos = self.pos.add(h.normal.scale(cfg.margin));

                rem = clipVelocity(rem, h.normal);
                self.vel = clipVelocity(self.vel, h.normal);
            }
        }

        fn clipVelocity(in: Vec3, normal: Vec3) Vec3 {
            const backoff = in.dot(normal);
            if (backoff >= 0) return in;
            var out = in.sub(normal.scale(backoff));
            
            // Double-scrub via Gram-Schmidt to mathematically kill all ULP drift
            const res = out.dot(normal);
            if (res < 0) out = out.sub(normal.scale(res));
            return out;
        }
    };
}
