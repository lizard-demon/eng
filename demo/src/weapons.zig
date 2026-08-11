const std = @import("std");
const math = @import("kami").math;
const Unit = math.Unit;

pub const WeaponType = enum { pistol, shotgun, rifle, rocket };

pub const WeaponDef = struct {
    damage: u32,
    cooldown: Unit,
    auto: bool,
    proj_speed: Unit = Unit.ZERO,
    spray: []const [2]i32 = &.{},
    pellets: []const [2]i32 = &.{.{ 0, 0 }},
};

fn comptimeSpread(comptime N: usize, comptime spread: f32) [N][2]i32 {
    var res: [N][2]i32 = undefined;
    if (N == 1) { res[0] = .{ 0, 0 }; return res; }
    
    for (0..N) |i| {
        const r = @sqrt(@as(f32, @floatFromInt(i)) / (N - 1)) * spread * 1024.0;
        const t = @as(f32, @floatFromInt(i)) * 2.39996323; // Golden angle
        res[i] = .{ @intFromFloat(r * @cos(t)), @intFromFloat(r * @sin(t)) };
    }
    return res;
}

pub const AK_Pattern = [_][2]i32{ .{0,0}, .{0,-50}, .{-20,-100}, .{30,-140}, .{60,-160} };

pub const Weapons = std.EnumArray(WeaponType, WeaponDef).init(.{
    .pistol  = .{ .damage = 15, .cooldown = Unit.fix(0.2), .auto = false },
    .shotgun = .{ .damage = 8,  .cooldown = Unit.fix(0.8), .auto = false, .pellets = &comptimeSpread(9, 0.08) },
    .rifle   = .{ .damage = 25, .cooldown = Unit.fix(0.1), .auto = true,  .spray = &AK_Pattern },
    .rocket  = .{ .damage = 80, .cooldown = Unit.fix(1.2), .auto = false, .proj_speed = Unit.fix(25.0) },
});

pub const WeaponState = struct {
    id: WeaponType = .pistol,
    cd: Unit = Unit.ZERO,
    time: Unit = Unit.ZERO,
    spray_idx: usize = 0,

    pub fn tick(self: *@This(), dt: Unit) void {
        if (self.cd.v > 0) self.cd = self.cd.sub(dt);
        self.time = self.time.add(dt);
        if (self.time.v > Unit.fix(0.3).v) self.spray_idx = 0;
    }
};

pub const Shot = struct {
    dir: math.Vec3,
    speed: Unit,
    damage: u32,
};

/// Populates `out` with deterministic trajectory data.
pub fn fire(state: *WeaponState, base: math.Angle, want: bool, out: []Shot) usize {
    const def = Weapons.get(state.id);
    const can = if (def.auto) want else (want and state.time.v > def.cooldown.v);
    
    if (!can or state.cd.v > 0) return 0;
    state.cd = def.cooldown;
    state.time = Unit.ZERO;

    const recoil = if (def.spray.len > 0) def.spray[@min(state.spray_idx, def.spray.len - 1)] else .{ 0, 0 };
    if (def.spray.len > 0 and state.spray_idx < def.spray.len - 1) state.spray_idx += 1;

    for (def.pellets, 0..) |p, i| {
        out[i] = .{
            .dir = base.addX(recoil[0] + p[0]).addY(recoil[1] + p[1]).clampPitch().forward(),
            .speed = def.proj_speed,
            .damage = def.damage,
        };
    }

    return def.pellets.len;
}
