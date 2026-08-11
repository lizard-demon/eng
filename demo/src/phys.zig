const std = @import("std");
const kami = @import("kami");
const math = kami.math;
const Unit = math.Unit;
const Vec3 = math.Vec3;

pub const Config = struct {
    gravity: Unit = Unit.fix(9.8),
    jump_speed: Unit = Unit.fix(5.0),
    max_speed: Unit = Unit.fix(6.0),
    crouch_speed: Unit = Unit.fix(2.0),
    
    // --- 1.6 Authentic Hull Settings ---
    stand_height: Unit = Unit.fix(0.8),
    stand_eye: Unit = Unit.fix(0.7),
    crouch_offset: Unit = Unit.fix(0.4), 
    
    air_speed: Unit = Unit.fix(1.0),
    accel: Unit = Unit.fix(50.0),
    friction: Unit = Unit.fix(6.0),
    slope_limit: Unit = Unit.fix(0.707),
    max_slides: u32 = 4,
    radius: Unit = Unit.fix(0.3),
    ground_snap: Unit = Unit.fix(0.05),
    rocket_speed: Unit = Unit.fix(25.0),
    explosion_radius: Unit = Unit.fix(5.0),
    explosion_force: Unit = Unit.fix(14.0),
    fire_cooldown: Unit = Unit.fix(0.6),
};

pub const Flags = packed struct(u8) {
    grounded: bool = false, crouched: bool = false, _pad: u6 = 0,
};

pub const InputState = struct {
    wish: Vec3, jump: bool, crouch: bool, fire: bool = false, view_fwd: Vec3 = .{ 0, 0, 0 }, eye_pos: Vec3 = .{ 0, 0, 0 },
};

pub const Rocket = struct {
    active: bool = false, pos: Vec3 = .{ 0, 0, 0 }, vel: Vec3 = .{ 0, 0, 0 },
};

fn ground(world: anytype, p: Vec3, cfg: Config) ?Vec3 {
    if (world.trace(p, .{ 0, Unit.ONE.neg().v, 0 }, cfg.ground_snap)) |h| {
        if (h.normal[1] > cfg.slope_limit.v) return h.normal;
    }
    return null;
}

fn crouch(world: anytype, p: *Vec3, v: *Vec3, f: *Flags, want: bool, was_grounded: bool, cfg: Config) void {
    if (want) {
        if (!f.crouched) {
            f.crouched = true;
            p.*[1] += cfg.crouch_offset.v;
            
            if (!was_grounded) {
                v.*[1] -= cfg.jump_speed.mul(Unit.fix(0.5)).v; 
            }
        }
    } else if (f.crouched) {
        if (world.trace(p.*, .{ 0, Unit.ONE.v, 0 }, cfg.stand_height)) |_| {
            return; 
        }
        
        f.crouched = false;
    }
}

fn fire(rockets: *[8]Rocket, timer: *Unit, cfg: Config, want: bool, eye_pos: Vec3, view_fwd: Vec3) void {
    if (!want or timer.v > 0) return;
    timer.* = cfg.fire_cooldown;
    for (rockets) |*r| {
        if (!r.active) { r.active = true; r.pos = eye_pos; r.vel = math.scale(view_fwd, cfg.rocket_speed); break; }
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
            
            const n = h.normal;
            
            p.* += math.scale(n, Unit.raw(1)); 
            
            rem = clip(rem, n); 
            v.* = clip(v.*, n);
        } else {
            p.* += rem; 
            break;
        }
    }
}
fn explode(sys: *System, ex_p: Vec3, cfg: Config) void {
    // Note: We now apply force to sys.impulse instead of sys.vel directly.
    for (sys.pos.items, sys.impulse.items, sys.health.items) |*pp, *p_imp, *ph| {
        var center = pp.*;
        center[1] += Unit.fix(0.5).v;
        var push_dir = center - ex_p;
        const d = math.len(push_dir);
        if (d.v < cfg.explosion_radius.v and d.v > 0) {
            ph.* -|= 1;
            push_dir = math.norm(push_dir);
            var force = math.scale(push_dir, cfg.explosion_force.mul(Unit.ONE.sub(d.div(cfg.explosion_radius))));
            
            // Authentic classic pop-up bias so explosions at your feet always lift you
            force[1] += Unit.fix(2.0).v;
            
            p_imp.* += force;
        }
    }
}

pub const System = struct {
    pos: std.ArrayListUnmanaged(Vec3) = .{},
    vel: std.ArrayListUnmanaged(Vec3) = .{},
    
    // --- Universal Damage Knockback Buffer ---
    // Any external system (hitscan, zombies, triggers) can write knockback to this array.
    // It gets perfectly integrated inside the physics loop without race conditions.
    impulse: std.ArrayListUnmanaged(Vec3) = .{}, 
    
    angles: std.ArrayListUnmanaged(math.Angle) = .{},
    flags: std.ArrayListUnmanaged(Flags) = .{},
    health: std.ArrayListUnmanaged(u32) = .{},
    alloc: std.mem.Allocator,
    rockets: [8]Rocket = [_]Rocket{.{}} ** 8,
    fire_timer: Unit = Unit.ZERO,

    pub fn init(alloc: std.mem.Allocator) System { return .{ .alloc = alloc }; }
    pub fn deinit(self: *System) void {
        self.pos.deinit(self.alloc); 
        self.vel.deinit(self.alloc); 
        self.impulse.deinit(self.alloc);
        self.angles.deinit(self.alloc);
        self.flags.deinit(self.alloc); 
        self.health.deinit(self.alloc);
    }

    pub fn add(self: *System, p: Vec3) !u32 {
        const id: u32 = @intCast(self.pos.items.len);
        try self.pos.append(self.alloc, p); 
        try self.vel.append(self.alloc, .{ 0, 0, 0 });
        try self.impulse.append(self.alloc, .{ 0, 0, 0 });
        try self.angles.append(self.alloc, .{}); 
        try self.flags.append(self.alloc, .{}); 
        try self.health.append(self.alloc, 4);
        return id;
    }

    pub fn step(self: *System, world: anytype, inputs: []const InputState, dt: Unit, cfg: Config) void {
        if (self.fire_timer.v > 0) self.fire_timer = self.fire_timer.sub(dt);
        
        for (self.pos.items, self.vel.items, self.impulse.items, self.flags.items, inputs) |*p, *v, *imp, *f, in| {
            f.grounded = false;
            var g_norm: Vec3 = .{ 0, Unit.ONE.v, 0 };
            
            if (ground(world, p.*, cfg)) |n| { f.grounded = true; g_norm = n; }
            
            const started_grounded = f.grounded;
            
            // 1. Evaluate Jump First
            // Overwrites v.y with the jump speed.
            if (in.jump and started_grounded and !f.crouched) { 
                v.*[1] = cfg.jump_speed.v; 
                f.grounded = false; 
            }
            
            // 2. Apply Generic Damage Knockback / Impulses
            // Because this is applied AFTER the jump check, damage knockback will 
            // flawlessly stack with your jump velocity on the exact same frame.
            if (imp.*[0] != 0 or imp.*[1] != 0 or imp.*[2] != 0) {
                v.* += imp.*;
                if (imp.*[1] > 0) f.grounded = false;
                imp.* = .{ 0, 0, 0 }; // Consume the impulse
            }
            
            // 3. Evaluate Crouch 
            crouch(world, p, v, f, in.crouch, started_grounded, cfg);
            
            fire(&self.rockets, &self.fire_timer, cfg, in.fire, in.eye_pos, in.view_fwd);
            
            if (started_grounded) friction(v, g_norm, cfg, dt) else v.*[1] -= cfg.gravity.mul(dt).v;
            
            accel(v, in.wish, f.grounded, f.crouched, cfg, dt);
            slide(world, p, v, dt, cfg);
        }
        
        for (&self.rockets) |*r| {
            if (!r.active) continue;
            const dist = math.len(r.vel).mul(dt);
            const dir = math.norm(r.vel);
            if (world.trace(r.pos, dir, dist)) |hit| {
                r.active = false;
                explode(self, r.pos + math.scale(dir, hit.dist) + math.scale(hit.normal, Unit.fix(0.1)), cfg);
            } else {
                r.pos += math.scale(dir, dist);
            }
        }
    }
};
