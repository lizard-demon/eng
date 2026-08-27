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
    pub const Type = enum { pistol, shotgun, rifle, rocket, knife };

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
        .knife   = .{ .damage = 40, .cooldown = Unit.fix(0.8), .auto = true },
    });

    pub const Shot = struct { dir: Vec3, speed: Unit, damage: u32 };

    pub const State = struct {
        id: Type = .pistol,
        cd: Unit = Unit.ZERO,
        time: Unit = Unit.ZERO,
        recovery: Unit = Unit.ZERO,
        spray_idx: usize = 0,
        was_firing: bool = false,

        pub fn tick(self: *@This(), dt: Unit) void {
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

        pub fn fire(self: *@This(), base: math.Angle, want: bool, out: []Shot) usize {
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

fn isBackstab(atk_angle: math.Angle, vic_angle: math.Angle, atk_pos: Vec3, vic_pos: Vec3) bool {
    const fwd_a = atk_angle.forward();
    const fwd_t = vic_angle.forward();
    
    const to_target = math.norm(vic_pos - atk_pos);

    const facing_back = math.dot(fwd_a, fwd_t).v > -200; 
    const positioned_behind = math.dot(to_target, fwd_t).v > -200;

    return facing_back and positioned_behind;
}

fn raySphere(ro: Vec3, rd: Vec3, center: Vec3, radius: Unit, max_t: Unit) ?Unit {
    const to_center = center - ro;
    const t = math.dot(to_center, rd);
    
    if (t.v < 0) return null; // Sphere is behind the ray
    
    const closest = ro + math.scale(rd, t);
    if (math.len(closest - center).v <= radius.v) {
        const hit_t = t.sub(radius);
        if (hit_t.v > max_t.v) return null; 
        
        return if (hit_t.v < 0) Unit.ZERO else hit_t;
    }
    return null;
}

fn traceWorld(state: *const Game, world: anytype, ro: Vec3, rd: Vec3, max_d: Unit, ignore_id: usize, collide_players: bool, cfg: Config) ?struct { normal: Vec3, dist: i32 } {
    var best_t = max_d;
    var hit_n: ?Vec3 = null;

    if (world.trace(ro, rd, best_t.v)) |hit| {
        best_t = Unit.raw(hit.dist);
        hit_n = hit.normal;
    }

    // Minkowski sweep player spheres
    if (collide_players) {
        const combined_body = cfg.body_radius.add(cfg.body_radius);
        const combined_head = cfg.head_radius.add(cfg.body_radius);

        for (0..MAX_PLAYERS) |t_id| {
            if (t_id == ignore_id or !state.isActive(t_id)) continue;
            
            const tp = state.core.pos[t_id];
            const tf = state.core.flags[t_id];
            const t_eye_h = if (tf.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
            
            const head_pos: Vec3 = .{ tp[0], tp[1] + t_eye_h.v, tp[2] };
            const body_pos: Vec3 = .{ tp[0], tp[1] + @divTrunc(t_eye_h.v, 2), tp[2] };
            
            if (raySphere(ro, rd, head_pos, combined_head, best_t)) |t| {
                best_t = t;
                hit_n = math.norm(ro + math.scale(rd, t) - head_pos);
            }
            if (raySphere(ro, rd, body_pos, combined_body, best_t)) |t| {
                best_t = t;
                hit_n = math.norm(ro + math.scale(rd, t) - body_pos);
            }
        }
    }

    if (hit_n) |n| {
        return .{ .normal = n, .dist = best_t.v };
    }
    return null;
}

fn applyDamage(state: *Game, id: usize, dir: Vec3, damage: u32, cfg: Config) void {
    if (damage == 0) return;
    state.core.health[id] -|= damage;

    var push_dir = dir;
    push_dir[1] += Unit.fix(0.75).v; 
    push_dir = math.norm(push_dir);
    
    const kb_mag = cfg.knockback_scale.mul(Unit.fix(@floatFromInt(damage)));
    state.core.impulse[id] += math.scale(push_dir, kb_mag);
}

fn explode(state: *Game, ex_p: Vec3, cfg: Config, damage: u32) void {
    for (0..MAX_PLAYERS) |id| {
        if (!state.isActive(id)) continue;
        var center = state.core.pos[id];
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

fn ground(state: *const Game, world: anytype, p: Vec3, ignore_id: usize, cfg: Config) ?Vec3 {
    if (traceWorld(state, world, p, .{ 0, Unit.ONE.neg().v, 0 }, cfg.ground_snap, ignore_id, true, cfg)) |h| {
        if (h.normal[1] > cfg.slope_limit.v) return h.normal;
    }
    return null;
}

fn crouch(state: *const Game, world: anytype, p: *Vec3, v: *Vec3, f: *Player.Flags, want: bool, was_grounded: bool, ignore_id: usize, cfg: Config) void {
    if (want) {
        if (!f.crouched) {
            f.crouched = true;
            p.*[1] += cfg.crouch_offset.v;
            if (!was_grounded) v.*[1] -= cfg.jump_speed.mul(Unit.fix(0.5)).v; 
        }
    } else if (f.crouched) {
        if (traceWorld(state, world, p.*, .{ 0, Unit.ONE.v, 0 }, cfg.stand_height, ignore_id, true, cfg)) |_| return; 
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

fn slide(state: *const Game, world: anytype, p: *Vec3, v: *Vec3, dt: Unit, ignore_id: usize, collide_players: bool, cfg: Config) void {
    const skin = Unit.raw(16); 
    var rem = math.scale(v.*, dt);
    
    for (0..cfg.max_slides) |_| {
        const l = math.len(rem);
        if (l.v < 2) break;
        const dir = math.norm(rem);
        
        if (traceWorld(state, world, p.*, dir, l.add(skin), ignore_id, collide_players, cfg)) |h| {
            const md = Unit.raw(@max(0, h.dist - skin.v));
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
    pub const Core = struct {
        active_mask: u8 = 0,
        pos: [MAX_PLAYERS]Vec3 = [_]Vec3{.{0,0,0}} ** MAX_PLAYERS,
        vel: [MAX_PLAYERS]Vec3 = [_]Vec3{.{0,0,0}} ** MAX_PLAYERS,
        impulse: [MAX_PLAYERS]Vec3 = [_]Vec3{.{0,0,0}} ** MAX_PLAYERS,
        angles: [MAX_PLAYERS]math.Angle = [_]math.Angle{.{}} ** MAX_PLAYERS,
        flags: [MAX_PLAYERS]Player.Flags = [_]Player.Flags{.{}} ** MAX_PLAYERS,
        health: [MAX_PLAYERS]u32 = [_]u32{256} ** MAX_PLAYERS,
        weapon_states: [MAX_PLAYERS]Weapon.State = [_]Weapon.State{.{}} ** MAX_PLAYERS,
        projectiles: [MAX_PROJECTILES]Projectile = [_]Projectile{.{}} ** MAX_PROJECTILES,
    };

    core: Core = .{},
    
    // Unsimulated / Visual State 
    impacts: [MAX_IMPACTS]Impact = [_]Impact{.{}} ** MAX_IMPACTS,
    impact_idx: usize = 0,

    pub inline fn isActive(self: *const Game, id: usize) bool {
        return (self.core.active_mask & (@as(u8, 1) << @intCast(id))) != 0;
    }

    pub fn spawnPlayer(self: *Game, p: Vec3) ?usize {
        for (0..MAX_PLAYERS) |i| {
            if (!self.isActive(i)) {
                self.core.active_mask |= @as(u8, 1) << @intCast(i);
                self.core.pos[i] = p;
                self.core.vel[i] = .{ 0, 0, 0 };
                self.core.impulse[i] = .{ 0, 0, 0 };
                self.core.angles[i] = .{};
                self.core.flags[i] = .{};
                self.core.health[i] = 256;
                self.core.weapon_states[i] = .{};
                self.core.weapon_states[i].id = .knife; // Default to knife
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
            
            const p = &self.core.pos[current_id];
            const v = &self.core.vel[current_id];
            const imp = &self.core.impulse[current_id];
            const f = &self.core.flags[current_id];
            const wp = &self.core.weapon_states[current_id];
            const in = inputs[current_id];
            
            f.grounded = false;
            var g_norm: Vec3 = .{ 0, Unit.ONE.v, 0 };
            
            if (ground(self, world, p.*, current_id, cfg)) |n| { f.grounded = true; g_norm = n; }
            
            if (in.jump and f.grounded and !f.crouched) { 
                v.*[1] = cfg.jump_speed.v; 
                f.grounded = false; 
            }
            
            if (imp.*[0] != 0 or imp.*[1] != 0 or imp.*[2] != 0) {
                v.* += imp.*;
                f.grounded = false;
                imp.* = .{ 0, 0, 0 };
            }
            
            crouch(self, world, p, v, f, in.crouch, f.grounded, current_id, cfg);
            
            const eye_h = if (f.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
            const eye_pos: Vec3 = .{ p.*[0], p.*[1] + eye_h.v, p.*[2] };
            
            wp.tick(dt);
            var shots: [32]Weapon.Shot = undefined;
            const shot_count = wp.fire(in.view_angle, in.fire, &shots);

            for (shots[0..shot_count]) |shot| {
                if (wp.id == .knife) {
                    const melee_range = Unit.fix(1.5);
                    const melee_radius = Unit.fix(0.25);
                    
                    var hit_id: ?usize = null;
                    var best_t = melee_range;

                    for (0..MAX_PLAYERS) |t_id| {
                        if (t_id == current_id or !self.isActive(t_id)) continue;
                        
                        const tp = self.core.pos[t_id];
                        const tf = self.core.flags[t_id];
                        const t_eye_h = if (tf.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
                        const body_pos: Vec3 = .{ tp[0], tp[1] + @divTrunc(t_eye_h.v, 2), tp[2] };

                        const combined_radius = cfg.body_radius.add(melee_radius);

                        if (raySphere(eye_pos, shot.dir, body_pos, combined_radius, best_t)) |t| {
                            best_t = t; 
                            hit_id = t_id;
                        }
                    }

                    if (hit_id) |id| {
                        const is_bs = isBackstab(in.view_angle, self.core.angles[id], p.*, self.core.pos[id]);
                        const dmg = if (is_bs) shot.damage * 10 else shot.damage;
                        
                        applyDamage(self, id, shot.dir, dmg, cfg);
                        self.spawnImpact(eye_pos + math.scale(shot.dir, best_t), .{0,1024,0}, .blood, cfg.blood_life);
                    }
                    continue;
                }
                
                if (shot.speed.v == 0) {
                    var best_t = Unit.fix(500.0);
                    var hit_id: ?usize = null;
                    var is_head = false;
                    var hit_n = Vec3{ 0, 1024, 0 };
                    
                    if (world.trace(eye_pos, shot.dir, best_t.v)) |hit| {
                        best_t = Unit.raw(hit.dist);
                        hit_n = hit.normal;
                    }
                    
                    for (0..MAX_PLAYERS) |t_id| {
                        if (t_id == current_id or !self.isActive(t_id)) continue;
                        
                        const tp = self.core.pos[t_id];
                        const tf = self.core.flags[t_id];
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
                    for (&self.core.projectiles) |*proj| {
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
            slide(self, world, p, v, dt, current_id, true, cfg);
        }
        
        // Projectile Step
        for (&self.core.projectiles) |*r| {
            if (!r.active) continue;
            const dist = math.len(r.vel).mul(dt);
            const dir = math.norm(r.vel);
            
            var hit_t = dist;
            var hit_n = Vec3{ 0, Unit.ONE.v, 0 };
            var exploded = false;
            
            if (world.trace(r.pos, dir, hit_t.v)) |hit| {
                hit_t = Unit.raw(hit.dist);
                hit_n = hit.normal;
                exploded = true;
            }
            
            for (0..MAX_PLAYERS) |t_id| {
                if (t_id == r.owner_id or !self.isActive(t_id)) continue;
                
                const tp = self.core.pos[t_id];
                const tf = self.core.flags[t_id];
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

        // Post-Movement Player-to-Player Spherical Rejection
        for (0..MAX_PLAYERS) |i| {
            if (!self.isActive(i)) continue;
            for (i + 1..MAX_PLAYERS) |j| {
                if (!self.isActive(j)) continue;
                
                const diff = self.core.pos[i] - self.core.pos[j];
                // Removed diff[1] = 0 to allow true 360 spherical collision (sliding over/under)
                
                const dist = math.len(diff);
                const min_dist = cfg.body_radius.mul(Unit.fix(2.0));
                
                if (dist.v > 0 and dist.v < min_dist.v) {
                    const overlap = min_dist.sub(dist);
                    // Increased repulsion factor slightly to prevent getting stuck
                    const push = math.scale(diff, overlap.div(dist).mul(Unit.fix(0.6)));
                    
                    var push_i = push;
                    var push_j: Vec3 = .{ -push[0], -push[1], -push[2] };
                    
                    slide(self, world, &self.core.pos[i], &push_i, Unit.ONE, i, false, cfg);
                    slide(self, world, &self.core.pos[j], &push_j, Unit.ONE, j, false, cfg);
                }
            }
        }
    }
};
