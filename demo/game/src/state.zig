const std = @import("std");
const kami = @import("kami");
const math = kami.math;
const Unit = math.Unit;
const Vec3 = math.Vec3;

pub const MAX_PLAYERS = 8;
pub const MAX_PROJECTILES = 32;
pub const MAX_IMPACTS = 64;

pub const Config = struct {
    gravity: Unit = Unit.fix(9.8),
    jump_speed: Unit = Unit.fix(5.0),
    max_speed: Unit = Unit.fix(6.0),
    crouch_speed: Unit = Unit.fix(2.0),
    stand_height: Unit = Unit.fix(0.8),
    stand_eye: Unit = Unit.fix(0.7),
    crouch_offset: Unit = Unit.fix(0.4), 
    
    head_radius: Unit = Unit.fix(0.15),
    body_radius: Unit = Unit.fix(0.35),
    knockback_scale: Unit = Unit.fix(0.2), 
    explosion_radius: Unit = Unit.fix(6.0),
    
    air_speed: Unit = Unit.fix(1.0),
    accel: Unit = Unit.fix(50.0),
    friction: Unit = Unit.fix(6.0),
    slope_limit: Unit = Unit.fix(0.707),
    max_slides: u32 = 4,
    radius: Unit = Unit.fix(0.3),
    ground_snap: Unit = Unit.fix(0.05),

    spark_life: Unit = Unit.fix(1.5),
    blood_life: Unit = Unit.fix(1.0),
    explosion_life: Unit = Unit.fix(3.0),
};

pub const Weapon = struct {
    pub const Type = enum { pistol, shotgun, rifle, rocket };

    pub const Def = struct {
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

    pub const ak_pattern = [_][2]i32{ .{0,0}, .{0,-50}, .{-20,-100}, .{30,-140}, .{60,-160} };

    pub const catalog = std.EnumArray(Type, Def).init(.{
        .pistol  = .{ .damage = 15, .cooldown = Unit.fix(0.2), .auto = false },
        .shotgun = .{ .damage = 8,  .cooldown = Unit.fix(0.8), .auto = false, .pellets = &comptimeSpread(9, 0.08) },
        .rifle   = .{ .damage = 25, .cooldown = Unit.fix(0.1), .auto = true,  .spray = &ak_pattern },
        .rocket  = .{ .damage = 80, .cooldown = Unit.fix(1.2), .auto = false, .proj_speed = Unit.fix(25.0) },
    });

    pub const Shot = struct { dir: Vec3, speed: Unit, damage: u32 };

    pub const State = struct {
        id: Type = .pistol,
        cd: Unit = Unit.ZERO,
        time: Unit = Unit.ZERO,
        recovery: Unit = Unit.ZERO,
        spray_idx: usize = 0,
        was_firing: bool = false,

        pub fn tick(self: *State, dt: Unit) void {
            const def = catalog.get(self.id);
            if (self.cd.v > 0) self.cd = self.cd.sub(dt);
            self.time = self.time.add(dt);
            
            if (!self.was_firing and self.spray_idx > 0) {
                self.recovery = self.recovery.add(dt);
                if (self.recovery.v >= def.cooldown.v) {
                    self.spray_idx -= 1;
                    self.recovery = self.recovery.sub(def.cooldown);
                }
            } else {
                self.recovery = Unit.ZERO;
            }
        }

        pub fn fire(self: *State, base: math.Angle, want: bool, out: []Shot) usize {
            const def = catalog.get(self.id);
            const is_new_press = want and !self.was_firing;
            self.was_firing = want;

            const trigger_pulled = if (def.auto) want else is_new_press;
            if (!trigger_pulled or self.cd.v > 0) return 0;
            
            self.cd = def.cooldown;
            self.time = Unit.ZERO;

            const recoil = if (def.spray.len > 0) def.spray[@min(self.spray_idx, def.spray.len - 1)] else .{ 0, 0 };
            if (def.spray.len > 0 and self.spray_idx < def.spray.len - 1) self.spray_idx += 1;

            for (def.pellets, 0..) |p, i| {
                out[i] = .{
                    .dir = base.addX(recoil[1] + p[1]).addY(recoil[0] + p[0]).clampPitch().forward(),
                    .speed = def.proj_speed,
                    .damage = def.damage,
                };
            }
            return def.pellets.len;
        }
    };
};

pub const Player = struct {
    pub const Flags = packed struct(u8) { grounded: bool = false, crouched: bool = false, _pad: u6 = 0 };
    pub const Input = struct {
        wish: Vec3 = .{ 0, 0, 0 }, 
        view_angle: math.Angle = .{}, 
        jump: bool = false, 
        crouch: bool = false, 
        fire: bool = false, 
    };
};

pub const Projectile = struct {
    active: bool = false, owner_id: usize = 0, pos: Vec3 = .{ 0, 0, 0 }, vel: Vec3 = .{ 0, 0, 0 }, damage: u32 = 0,
};

pub const Impact = struct {
    pub const Kind = enum(u8) { spark, blood, explosion };
    pos: Vec3 = .{ 0, 0, 0 },
    normal: Vec3 = .{ 0, 1024, 0 },
    life: Unit = Unit.ZERO,
    kind: Kind = .spark,
};

fn raySphere(ro: Vec3, rd: Vec3, center: Vec3, radius: Unit, max_t: Unit) ?Unit {
    const to_center = center - ro;
    const t = math.dot(to_center, rd);
    if (t.v < 0 or t.v > max_t.v) return null;
    
    const closest = ro + math.scale(rd, t);
    if (math.len(closest - center).v <= radius.v) {
        const hit_t = t.sub(radius);
        return if (hit_t.v < 0) Unit.ZERO else hit_t;
    }
    return null;
}

fn applyDamage(state: *Game, id: usize, dir: Vec3, damage: u32, cfg: Config) void {
    if (damage == 0) return;
    state.health[id] -|= damage;

    var push_dir = dir;
    push_dir[1] += Unit.fix(0.75).v; 
    push_dir = math.norm(push_dir);
    
    const kb_mag = cfg.knockback_scale.mul(Unit.fix(@floatFromInt(damage)));
    state.impulse[id] += math.scale(push_dir, kb_mag);
}

fn explode(state: *Game, ex_p: Vec3, cfg: Config, damage: u32) void {
    for (0..MAX_PLAYERS) |id| {
        if (!state.isActive(id)) continue;
        var center = state.pos[id];
        center[1] += Unit.fix(0.4).v;
        
        const push_vec = center - ex_p;
        const d = math.len(push_vec);
        if (d.v < cfg.explosion_radius.v and d.v > 0) {
            const falloff = Unit.ONE.sub(d.div(cfg.explosion_radius));
            const dmg_applied = @as(u32, @intCast((@as(u64, damage) * @as(u64, @intCast(@max(0, falloff.v)))) >> 10));
            applyDamage(state, id, math.norm(push_vec), dmg_applied, cfg);
        }
    }
}

fn ground(world: anytype, p: Vec3, cfg: Config) ?Vec3 {
    if (world.trace(p, .{ 0, Unit.ONE.neg().v, 0 }, cfg.ground_snap)) |h| {
        if (h.normal[1] > cfg.slope_limit.v) return h.normal;
    }
    return null;
}

fn crouch(world: anytype, p: *Vec3, v: *Vec3, f: *Player.Flags, want: bool, was_grounded: bool, cfg: Config) void {
    if (want) {
        if (!f.crouched) {
            f.crouched = true;
            p.*[1] += cfg.crouch_offset.v;
            if (!was_grounded) v.*[1] -= cfg.jump_speed.mul(Unit.fix(0.5)).v; 
        }
    } else if (f.crouched) {
        if (world.trace(p.*, .{ 0, Unit.ONE.v, 0 }, cfg.stand_height)) |_| return; 
        f.crouched = false;
    }
}

fn friction(v: *Vec3, g_norm: Vec3, cfg: Config, dt: Unit) void {
    const vn = math.dot(v.*, g_norm);
    if (vn.v < 0) v.* -= math.scale(g_norm, vn);
    const spd = math.len(.{ v.*[0], 0, v.*[2] });
    if (spd.v > 102) {
        const drop = spd.mul(cfg.friction.mul(dt));
        const horiz = math.scale(.{ v.*[0], 0, v.*[2] }, Unit.raw(@max(0, spd.v - drop.v)).div(spd));
        v.*[0] = horiz[0]; v.*[2] = horiz[2];
    } else {
        v.*[0] = 0; v.*[2] = 0;
    }
}

fn accel(v: *Vec3, wish: Vec3, grounded: bool, crouched: bool, cfg: Config, dt: Unit) void {
    const wl = math.len(wish);
    if (wl.v == 0) return;
    const active_max = if (crouched) cfg.crouch_speed else cfg.max_speed;
    const top = if (grounded) active_max.mul(wl) else Unit.raw(@min(active_max.mul(wl).v, cfg.air_speed.v));
    const add_spd = Unit.raw(@min(cfg.accel.mul(dt).v, @max(0, top.v - math.dot(.{ v.*[0], 0, v.*[2] }, wish).v)));
    v.* += math.scale(wish, add_spd);
}

fn clip(in: Vec3, n: Vec3) Vec3 {
    const b = math.dot(in, n);
    if (b.v >= 0) return in;
    const o = in - math.scale(n, b);
    const r = math.dot(o, n);
    return if (r.v < 0) o - math.scale(n, r) else o;
}

fn slide(world: anytype, p: *Vec3, v: *Vec3, dt: Unit, cfg: Config) void {
    const skin = Unit.raw(16); 
    var rem = math.scale(v.*, dt);
    
    for (0..cfg.max_slides) |_| {
        const l = math.len(rem);
        if (l.v < 2) break;
        const dir = math.norm(rem);
        
        if (world.trace(p.*, dir, l.add(skin))) |h| {
            const md = Unit.raw(@max(0, h.dist.v - skin.v));
            if (md.v > 0) { 
                p.* += math.scale(dir, md); 
                rem -= math.scale(dir, Unit.raw(@min(md.v, l.v))); 
            }
            p.* += math.scale(h.normal, Unit.raw(1)); 
            rem = clip(rem, h.normal); 
            v.* = clip(v.*, h.normal);
        } else {
            p.* += rem; break;
        }
    }
}

pub const Game = struct {
    active_mask: u8 = 0,
    pos: [MAX_PLAYERS]Vec3 = [_]Vec3{.{0,0,0}} ** MAX_PLAYERS,
    vel: [MAX_PLAYERS]Vec3 = [_]Vec3{.{0,0,0}} ** MAX_PLAYERS,
    impulse: [MAX_PLAYERS]Vec3 = [_]Vec3{.{0,0,0}} ** MAX_PLAYERS,
    angles: [MAX_PLAYERS]math.Angle = [_]math.Angle{.{}} ** MAX_PLAYERS,
    flags: [MAX_PLAYERS]Player.Flags = [_]Player.Flags{.{}} ** MAX_PLAYERS,
    health: [MAX_PLAYERS]u32 = [_]u32{256} ** MAX_PLAYERS,
    weapon_states: [MAX_PLAYERS]Weapon.State = [_]Weapon.State{.{}} ** MAX_PLAYERS,
    projectiles: [MAX_PROJECTILES]Projectile = [_]Projectile{.{}} ** MAX_PROJECTILES,
    
    impacts: [MAX_IMPACTS]Impact = [_]Impact{.{}} ** MAX_IMPACTS,
    impact_idx: usize = 0,

    pub inline fn isActive(self: *const Game, id: usize) bool {
        return (self.active_mask & (@as(u8, 1) << @intCast(id))) != 0;
    }

    pub fn spawnPlayer(self: *Game, p: Vec3) ?usize {
        for (0..MAX_PLAYERS) |i| {
            if (!self.isActive(i)) {
                self.active_mask |= @as(u8, 1) << @intCast(i);
                self.pos[i] = p;
                self.vel[i] = .{ 0, 0, 0 };
                self.impulse[i] = .{ 0, 0, 0 };
                self.angles[i] = .{};
                self.flags[i] = .{};
                self.health[i] = 256;
                self.weapon_states[i] = .{};
                return i;
            }
        }
        return null;
    }

    fn spawnImpact(self: *Game, p: Vec3, n: Vec3, kind: Impact.Kind, life: Unit) void {
        self.impacts[self.impact_idx] = .{ .pos = p, .normal = n, .life = life, .kind = kind };
        self.impact_idx = (self.impact_idx + 1) % MAX_IMPACTS;
    }

    pub fn step(self: *Game, world: anytype, inputs: []const Player.Input, dt: Unit, cfg: Config) void {
        
        for (&self.impacts) |*imp| {
            if (imp.life.v > 0) {
                imp.life = imp.life.sub(dt);
                if (imp.life.v < 0) imp.life = Unit.ZERO;
            }
        }

        for (0..MAX_PLAYERS) |current_id| {
            if (!self.isActive(current_id)) continue;
            
            const p = &self.pos[current_id];
            const v = &self.vel[current_id];
            const imp = &self.impulse[current_id];
            const f = &self.flags[current_id];
            const wp = &self.weapon_states[current_id];
            const in = inputs[current_id];
            
            f.grounded = false;
            var g_norm: Vec3 = .{ 0, Unit.ONE.v, 0 };
            
            if (ground(world, p.*, cfg)) |n| { f.grounded = true; g_norm = n; }
            
            if (in.jump and f.grounded and !f.crouched) { 
                v.*[1] = cfg.jump_speed.v; 
                f.grounded = false; 
            }
            
            if (imp.*[0] != 0 or imp.*[1] != 0 or imp.*[2] != 0) {
                v.* += imp.*;
                f.grounded = false;
                imp.* = .{ 0, 0, 0 };
            }
            
            crouch(world, p, v, f, in.crouch, f.grounded, cfg);
            
            const eye_h = if (f.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
            const eye_pos: Vec3 = .{ p.*[0], p.*[1] + eye_h.v, p.*[2] };
            
            wp.tick(dt);
            var shots: [32]Weapon.Shot = undefined;
            const shot_count = wp.fire(in.view_angle, in.fire, &shots);

            for (shots[0..shot_count]) |shot| {
                if (shot.speed.v == 0) {
                    var best_t = Unit.fix(500.0);
                    var hit_id: ?usize = null;
                    var is_head = false;
                    var hit_n = Vec3{ 0, 1024, 0 };
                    
                    if (world.trace(eye_pos, shot.dir, best_t)) |hit| {
                        best_t = hit.dist;
                        hit_n = hit.normal;
                    }
                    
                    for (0..MAX_PLAYERS) |t_id| {
                        if (t_id == current_id or !self.isActive(t_id)) continue;
                        
                        const tp = self.pos[t_id];
                        const tf = self.flags[t_id];
                        const t_eye_h = if (tf.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
                        
                        const head_pos: Vec3 = .{ tp[0], tp[1] + t_eye_h.v, tp[2] };
                        const body_pos: Vec3 = .{ tp[0], tp[1] + @divTrunc(t_eye_h.v, 2), tp[2] };
                        
                        if (raySphere(eye_pos, shot.dir, head_pos, cfg.head_radius, best_t)) |t| {
                            best_t = t; hit_id = t_id; is_head = true;
                            hit_n = math.norm(eye_pos + math.scale(shot.dir, t) - head_pos);
                        }
                        if (raySphere(eye_pos, shot.dir, body_pos, cfg.body_radius, best_t)) |t| {
                            best_t = t; hit_id = t_id; is_head = false;
                            hit_n = math.norm(eye_pos + math.scale(shot.dir, t) - body_pos);
                        }
                    }
                    
                    const hit_pos = eye_pos + math.scale(shot.dir, best_t);
                    if (hit_id) |id| {
                        applyDamage(self, id, shot.dir, if (is_head) shot.damage * 3 else shot.damage, cfg);
                        self.spawnImpact(hit_pos, hit_n, .blood, cfg.blood_life);
                    } else if (best_t.v < Unit.fix(500.0).v) {
                        self.spawnImpact(hit_pos, hit_n, .spark, cfg.spark_life);
                    }
                } else {
                    for (&self.projectiles) |*proj| {
                        if (!proj.active) {
                            proj.active = true;
                            proj.owner_id = current_id;
                            proj.pos = eye_pos;
                            proj.vel = math.scale(shot.dir, shot.speed);
                            proj.damage = shot.damage;
                            break;
                        }
                    }
                }
            }
            
            if (f.grounded) friction(v, g_norm, cfg, dt) else v.*[1] -= cfg.gravity.mul(dt).v;
            
            accel(v, in.wish, f.grounded, f.crouched, cfg, dt);
            slide(world, p, v, dt, cfg);
        }
        
        for (&self.projectiles) |*r| {
            if (!r.active) continue;
            const dist = math.len(r.vel).mul(dt);
            const dir = math.norm(r.vel);
            
            var hit_t = dist;
            var hit_n = Vec3{ 0, Unit.ONE.v, 0 };
            var exploded = false;
            
            if (world.trace(r.pos, dir, hit_t)) |hit| {
                hit_t = hit.dist;
                hit_n = hit.normal;
                exploded = true;
            }
            
            for (0..MAX_PLAYERS) |t_id| {
                if (t_id == r.owner_id or !self.isActive(t_id)) continue;
                
                const tp = self.pos[t_id];
                const tf = self.flags[t_id];
                const t_eye_h = if (tf.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
                
                const head_pos: Vec3 = .{ tp[0], tp[1] + t_eye_h.v, tp[2] };
                const body_pos: Vec3 = .{ tp[0], tp[1] + @divTrunc(t_eye_h.v, 2), tp[2] };
                
                if (raySphere(r.pos, dir, head_pos, cfg.head_radius, hit_t)) |t| {
                    hit_t = t; exploded = true; hit_n = math.norm(r.pos + math.scale(dir, t) - head_pos);
                }
                if (raySphere(r.pos, dir, body_pos, cfg.body_radius, hit_t)) |t| {
                    hit_t = t; exploded = true; hit_n = math.norm(r.pos + math.scale(dir, t) - body_pos);
                }
            }
            
            if (exploded) {
                r.active = false;
                const exact_hit = r.pos + math.scale(dir, hit_t);
                const ex_p = exact_hit + math.scale(hit_n, Unit.fix(0.1));
                
                self.spawnImpact(exact_hit, hit_n, .explosion, cfg.explosion_life);
                explode(self, ex_p, cfg, r.damage);
            } else {
                r.pos += math.scale(dir, dist);
            }
        }
    }
};
