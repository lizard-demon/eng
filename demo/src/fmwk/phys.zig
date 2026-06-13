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
    ground_snap: f32 = 0.05,
};

pub fn Body(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        const V3 = @Vector(3, f32);

        pos: [3]f32 = .{ 0, 0, 0 },
        vel: [3]f32 = .{ 0, 0, 0 },
        yaw: f32 = 0,
        pitch: f32 = 0,
        grounded: bool = false,

        pub fn eyePos(self: Self) [3]f32 {
            return .{ self.pos[0], self.pos[1] + cfg.eye_height, self.pos[2] };
        }

        pub fn lookDir(self: Self) [3]f32 {
            const f = .{
                @sin(self.yaw) * @cos(self.pitch),
                -@sin(self.pitch),
                -@cos(self.yaw) * @cos(self.pitch),
            };
            const l = @sqrt(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
            return .{ f[0] / l, f[1] / l, f[2] / l };
        }

        pub fn step(self: *Self, world: anytype, wish: [3]f32, jump: bool, dt: f32) void {
            self.grounded = false;
            var g_norm: [3]f32 = .{ 0, 1, 0 };

            if (world.trace(self.pos, .{ 0, -1, 0 }, cfg.ground_snap, cfg.radius)) |h| {
                if (h.normal[1] > cfg.slope_limit) {
                    self.grounded = true;
                    g_norm = h.normal;
                }
            }

            if (self.grounded) {
                const vn = @reduce(.Add, @as(V3, self.vel) * @as(V3, g_norm));
                if (vn < 0) {
                    self.vel = @as([3]f32, @as(V3, self.vel) - @as(V3, g_norm) * @as(V3, @splat(vn)));
                }

                const spd = @sqrt(self.vel[0] * self.vel[0] + self.vel[2] * self.vel[2]);
                if (spd > 0.1) {
                    const f = @max(0, spd - spd * cfg.friction * dt) / spd;
                    self.vel[0] *= f;
                    self.vel[2] *= f;
                } else {
                    self.vel[0] = 0;
                    self.vel[2] = 0;
                }
            } else {
                self.vel[1] -= cfg.gravity * dt;
            }

            if (jump and self.grounded) {
                self.vel[1] = cfg.jump_speed;
                self.grounded = false;
            }

            const wl = @sqrt(wish[0] * wish[0] + wish[2] * wish[2]);
            if (wl > 0) {
                const wn: V3 = @as(V3, wish) / @as(V3, @splat(wl));
                const top = if (self.grounded) cfg.max_speed * wl else @min(cfg.max_speed * wl, cfg.air_speed);
                const cur = @reduce(.Add, @as(V3, .{ self.vel[0], 0, self.vel[2] }) * wn);
                const add = @min(cfg.accel * dt, @max(0, top - cur));
                self.vel = @as([3]f32, @as(V3, self.vel) + wn * @as(V3, @splat(add)));
            }

            var rem = @as(V3, self.vel) * @as(V3, @splat(dt));

            for (0..cfg.max_slides) |_| {
                const l = @sqrt(@reduce(.Add, rem * rem));
                if (l < 1e-5) {
                    break;
                }

                const dir: [3]f32 = @as([3]f32, rem / @as(V3, @splat(l)));
                const trace_res = world.trace(self.pos, dir, l + 1e-3, cfg.radius);

                if (trace_res) |h| {
                    const md = @max(0, h.dist - 1e-5);
                    if (md > 0) {
                        self.pos = @as([3]f32, @as(V3, self.pos) + @as(V3, dir) * @as(V3, @splat(md)));
                        rem -= @as(V3, dir) * @as(V3, @splat(@min(md, l)));
                    }

                    self.pos = @as([3]f32, @as(V3, self.pos) + @as(V3, h.normal) * @as(V3, @splat(1e-3)));
                    rem = clip(rem, h.normal);
                    self.vel = clip(@as(V3, self.vel), h.normal);
                } else {
                    self.pos = @as([3]f32, @as(V3, self.pos) + rem);
                    break;
                }
            }
        }

        fn clip(in: V3, n_arr: [3]f32) [3]f32 {
            const n: V3 = n_arr;
            const b = @reduce(.Add, in * n);
            if (b >= 0) {
                return @as([3]f32, in);
            }
            const o = in - n * @as(V3, @splat(b));
            const r = @reduce(.Add, o * n);
            if (r < 0) {
                return @as([3]f32, o - n * @as(V3, @splat(r)));
            }
            return @as([3]f32, o);
        }
    };
}
