const std = @import("std");
const math = @import("fmwk/math.zig");
const Unit = math.Unit;

pub const Config = struct {
    gravity: Unit = Unit.fix(9.8),
    jump_speed: Unit = Unit.fix(5.0),
    max_speed: Unit = Unit.fix(6.0),
    air_speed: Unit = Unit.fix(1.0),
    accel: Unit = Unit.fix(50.0),
    friction: Unit = Unit.fix(6.0),
    slope_limit: Unit = Unit.fix(0.707),
    max_slides: u32 = 4,
    radius: Unit = Unit.fix(0.3),
    ground_snap: Unit = Unit.fix(0.05),
};

pub const Flags = packed struct(u8) {
    grounded: bool = false,
    _pad: u7 = 0,
};

pub const InputState = struct { wish: [3]Unit, jump: bool };

pub const System = struct {
    pos: std.ArrayListUnmanaged([3]Unit) = .{},
    vel: std.ArrayListUnmanaged([3]Unit) = .{},
    angles: std.ArrayListUnmanaged(math.Angle) = .{},
    flags: std.ArrayListUnmanaged(Flags) = .{},
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) System {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *System) void {
        self.pos.deinit(self.alloc);
        self.vel.deinit(self.alloc);
        self.angles.deinit(self.alloc);
        self.flags.deinit(self.alloc);
    }

    pub fn add(self: *System, p: [3]Unit) !u32 {
        const id: u32 = @intCast(self.pos.items.len);
        try self.pos.append(self.alloc, p);
        try self.vel.append(self.alloc, .{ Unit.ZERO, Unit.ZERO, Unit.ZERO });
        try self.angles.append(self.alloc, .{});
        try self.flags.append(self.alloc, .{});
        return id;
    }

    pub fn step(self: *System, world: anytype, inputs: []const InputState, dt: Unit, cfg: Config) void {
        for (self.pos.items, self.vel.items, self.flags.items, inputs) |*p, *v, *f, in| {
            f.grounded = false;
            var g_norm = [3]Unit{ Unit.ZERO, Unit.ONE, Unit.ZERO };

            if (world.trace(p.*, .{ Unit.ZERO, Unit.ONE.neg(), Unit.ZERO }, cfg.ground_snap, cfg.radius)) |h| {
                if (h.normal[1].v > cfg.slope_limit.v) {
                    f.grounded = true;
                    g_norm = h.normal;
                }
            }

            if (f.grounded) {
                const vn = Unit.dot3(v.*, g_norm);
                if (vn.v < 0) {
                    v.* = Unit.sub3(v.*, Unit.scale3(g_norm, vn));
                }
                const spd = Unit.len3(.{ v[0], Unit.ZERO, v[2] });
                if (spd.v > 102) {
                    const drop = spd.mul(cfg.friction.mul(dt));
                    const sf = Unit.raw(@max(0, spd.v - drop.v)).div(spd);
                    v[0] = v[0].mul(sf);
                    v[2] = v[2].mul(sf);
                } else {
                    v[0] = Unit.ZERO;
                    v[2] = Unit.ZERO;
                }
            } else {
                v[1] = v[1].sub(cfg.gravity.mul(dt));
            }

            if (in.jump and f.grounded) {
                v[1] = cfg.jump_speed;
                f.grounded = false;
            }

            const wl = Unit.len3(in.wish);
            if (wl.v > 0) {
                const top = if (f.grounded) cfg.max_speed.mul(wl) else Unit.raw(@min(cfg.max_speed.mul(wl).v, cfg.air_speed.v));
                const cur = Unit.dot3(.{ v[0], Unit.ZERO, v[2] }, in.wish);
                const add_spd = Unit.raw(@min(cfg.accel.mul(dt).v, @max(0, top.v - cur.v)));
                v.* = Unit.add3(v.*, Unit.scale3(in.wish, add_spd));
            }

            var rem = Unit.scale3(v.*, dt);

            for (0..cfg.max_slides) |_| {
                const l = Unit.len3(rem);
                if (l.v < 2) break;

                const dir = Unit.norm3(rem);
                const trace_res = world.trace(p.*, dir, l.add(Unit.raw(1)), cfg.radius);

                if (trace_res) |h| {
                    const md = Unit.raw(@max(0, h.dist.v - 1));
                    if (md.v > 0) {
                        p.* = Unit.add3(p.*, Unit.scale3(dir, md));
                        rem = Unit.sub3(rem, Unit.scale3(dir, Unit.raw(@min(md.v, l.v))));
                    }
                    
                    p.* = Unit.add3(p.*, Unit.scale3(h.normal, Unit.raw(1)));
                    rem = clip(rem, h.normal);
                    v.* = clip(v.*, h.normal);
                } else {
                    p.* = Unit.add3(p.*, rem);
                    break;
                }
            }
        }
    }

    fn clip(in: [3]Unit, n: [3]Unit) [3]Unit {
        const b = Unit.dot3(in, n);
        if (b.v >= 0) return in;
        const o = Unit.sub3(in, Unit.scale3(n, b));
        const r = Unit.dot3(o, n);
        return if (r.v < 0) Unit.sub3(o, Unit.scale3(n, r)) else o;
    }
};
