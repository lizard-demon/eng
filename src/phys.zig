//! phys.zig — Quake-style character controller, comptime-configured

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
            return Vec3.new(sy * cp, -sp, -cy * cp).normalize(); // -sp matches viewMatrix row 2
        }

        /// Advance one frame.  `world` is anything with `.cast(Vec3,Vec3,f32)->?Hit`.
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
                if (l < 1e-6) break;
                const dir = rem.scale(1.0 / l);
                const h = world.cast(self.pos, dir, @max(l, cfg.margin * 2)) orelse {
                    self.pos = self.pos.add(rem);
                    break;
                };
                self.pos = self.pos.add(rem.scale(@max(0, h.dist - cfg.margin) / l));
                if (rem.dot(h.normal) >= 0) break;
                if (h.normal.data[1] > cfg.slope_limit) self.grounded = true;
                rem = rem.sub(h.normal.scale(rem.dot(h.normal)));
                const vn = self.vel.dot(h.normal);
                if (vn < 0) self.vel = self.vel.sub(h.normal.scale(vn));
            }
        }
    };
}
