// demo/src/main.zig
const std = @import("std");
const sdl = @import("kami");
const math = sdl.math;
const Unit = math.Unit;
const Vec3 = math.Vec3;
const phys = @import("phys.zig");
const BVH = @import("bvh.zig").Tree;

const FPS_BUCKETS: usize = 501;
const HUD_PERCENTILE_INTERVAL: u32 = 30;

pub const Action = enum { jump, crouch, fire };

fn wishdir(angle: math.Angle, fwd: Unit, right: Unit) Vec3 {
    const sy = math.Angle.sin(angle.y);
    const cy = math.Angle.cos(angle.y);
    const fwd_v: Vec3 = .{ sy.mul(fwd).v, 0, cy.mul(fwd).neg().v };
    const rgt_v: Vec3 = .{ cy.mul(right).v, 0, sy.mul(right).v };
    return math.norm(fwd_v + rgt_v);
}

fn cameraView(angle: math.Angle, pos: Vec3, eye_h: Unit) [16]f32 {
    const ex = Unit.raw(pos[0]).flt();
    const ey = Unit.raw(pos[1]).flt() + eye_h.flt();
    const ez = Unit.raw(pos[2]).flt();
    const cy = math.Angle.cos(angle.y).flt();
    const sy = math.Angle.sin(angle.y).flt();
    const cp = math.Angle.cos(angle.x).flt();
    const sp = math.Angle.sin(angle.x).flt();

    return .{
        cy, sy * sp, -sy * cp, 0,
        0, cp, sp, 0,
        sy, -cy * sp, cy * cp, 0,
        -ex * cy - ez * sy,
        -ex * sy * sp - ey * cp + ez * cy * sp,
        ex * sy * cp - ey * sp - ez * cy * cp,
        1,
    };
}

pub const App = struct {
    alloc: std.mem.Allocator,
    dev: sdl.Device,
    scene: sdl.Scene,
    ui: sdl.Ui,
    level_bvh: BVH,
    render_verts: std.ArrayListUnmanaged(sdl.Scene.Vertex) = .{},
    render_indices: std.ArrayListUnmanaged(u32) = .{},
    mesh_h: sdl.Scene.Handle = 0,
    in: sdl.Input(Action),
    physics: phys.System,
    player_id: u32 = 0,
    last_time: u64 = 0,
    accumulator: f32 = 0.0,

    frame_times: [120]f32 = [_]f32{0.0166} ** 120,
    frame_idx: usize = 0,
    frame_sum: f32 = 0.0166 * 120,
    session_fps_hist: [FPS_BUCKETS]u32 = [_]u32{0} ** FPS_BUCKETS,
    session_fps_sum: [FPS_BUCKETS]f64 = [_]f64{0} ** FPS_BUCKETS,
    session_frame_count: u64 = 0,
    hud_frame_counter: u32 = HUD_PERCENTILE_INTERVAL,
    cached_low_fps: u32 = 0,
    cached_high_fps: u32 = 0,
    running: bool = true,

    pub fn init(alloc: std.mem.Allocator) !*App {
        const app = try alloc.create(App);
        errdefer alloc.destroy(app);

        app.* = .{
            .alloc = alloc,
            .dev = try sdl.Device.init("Runtime Engine", 1280, 720),
            .scene = undefined,
            .ui = undefined,
            .level_bvh = BVH.init(alloc),
            .in = sdl.Input(Action).init(),
            .physics = phys.System.init(alloc),
            .last_time = sdl.c.SDL_GetTicksNS(),
        };

        // --- Action Bindings & Input Setup ---
        app.in.sensitivity = 1.0; 
        app.in.bindKey(.jump, sdl.c.SDL_SCANCODE_SPACE);
        app.in.bindKey(.crouch, sdl.c.SDL_SCANCODE_LCTRL);
        app.in.bindMouse(.fire, sdl.c.SDL_BUTTON_LEFT);
        app.in.bindWheel(.jump, false);  // Scroll down
        app.in.bindWheel(.crouch, true); // Scroll up

        const vert_spv = @embedFile("shaders/triangle.vert.spv");
        const frag_spv = @embedFile("shaders/triangle.frag.spv");
        const ui_vert_spv = @embedFile("shaders/ui.vert.spv");
        const ui_frag_spv = @embedFile("shaders/ui.frag.spv");

        app.scene = try sdl.Scene.init(&app.dev, alloc, vert_spv, frag_spv);
        app.ui = try sdl.Ui.init(&app.dev, alloc, ui_vert_spv, ui_frag_spv);

        try app.build();
        try app.spawn();

        return app;
    }

    pub fn deinit(self: *App) void {
        self.physics.deinit();
        self.ui.deinit();
        self.scene.deinit();
        self.dev.deinit();
        self.level_bvh.deinit();
        self.render_verts.deinit(self.alloc);
        self.render_indices.deinit(self.alloc);
    }

    fn quad(self: *App, a: Vec3, b: Vec3, c: Vec3, d: Vec3, color: [4]f32) !void {
        try self.level_bvh.addTri(a, b, c);
        try self.level_bvh.addTri(a, c, d);
        const base: u32 = @intCast(self.render_verts.items.len);
        try self.render_verts.appendSlice(self.alloc, &.{
            .{ .pos = .{ a[0], a[1], a[2] }, .color = color },
            .{ .pos = .{ b[0], b[1], b[2] }, .color = color },
            .{ .pos = .{ c[0], c[1], c[2] }, .color = color },
            .{ .pos = .{ d[0], d[1], d[2] }, .color = color },
        });
        try self.render_indices.appendSlice(self.alloc, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }

    fn build(self: *App) !void {
        try self.quad(.{ Unit.fix(-500).v, 0, Unit.fix(500).v }, .{ Unit.fix(500).v, 0, Unit.fix(500).v }, .{ Unit.fix(500).v, 0, Unit.fix(-500).v }, .{ Unit.fix(-500).v, 0, Unit.fix(-500).v }, .{ 0.3, 0.3, 0.35, 1.0 });
        try self.quad(.{ Unit.fix(-5).v, 0, Unit.fix(-5).v }, .{ Unit.fix(5).v, 0, Unit.fix(-5).v }, .{ Unit.fix(5).v, Unit.fix(5).v, Unit.fix(-5).v }, .{ Unit.fix(-5).v, Unit.fix(5).v, Unit.fix(-5).v }, .{ 0.5, 0.2, 0.2, 1.0 });

        try self.level_bvh.build();
        self.mesh_h = try self.scene.upload(std.mem.sliceAsBytes(self.render_verts.items), std.mem.sliceAsBytes(self.render_indices.items));
    }

    fn spawn(self: *App) !void {
        self.player_id = try self.physics.add(.{ 0, Unit.fix(1.5).v, 0 });
    }

    fn record(self: *App, fps: f32) void {
        const clamped = @min(@max(fps, 0.0), @as(f32, @floatFromInt(FPS_BUCKETS - 1)));
        const idx: usize = @intFromFloat(@floor(clamped));
        self.session_fps_hist[idx] += 1;
        self.session_fps_sum[idx] += clamped;
        self.session_frame_count += 1;
    }

    fn percentile(self: *const App, fraction: f32, high: bool) f32 {
        if (self.session_frame_count == 0) return 0;
        const target: u64 = @max(1, @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.session_frame_count)) * fraction)));
        var accum: u64 = 0; var sum: f64 = 0;
        for (0..FPS_BUCKETS) |step| {
            const i: usize = if (high) FPS_BUCKETS - 1 - step else step;
            const c = self.session_fps_hist[i];
            if (c == 0) continue;
            if (accum + c >= target) {
                const need = target - accum;
                sum += (self.session_fps_sum[i] / @as(f64, @floatFromInt(c))) * @as(f64, @floatFromInt(need));
                accum += need; break;
            }
            sum += self.session_fps_sum[i]; accum += c;
        }
        if (accum == 0) return 0;
        return @floatCast(sum / @as(f64, @floatFromInt(accum)));
    }

    pub fn update(self: *App) !void {
        const now = sdl.c.SDL_GetTicksNS();
        var dt = @as(f32, @floatFromInt(now - self.last_time)) / 1_000_000_000.0;
        self.last_time = now;
        if (dt > 0.0) {
            self.frame_sum += dt - self.frame_times[self.frame_idx];
            self.frame_times[self.frame_idx] = dt;
            self.frame_idx = (self.frame_idx + 1) % self.frame_times.len;
            self.record(1.0 / dt);
        }
        if (dt > 0.25) dt = 0.25;
        self.accumulator += dt;
        
        self.in.update();
        if (self.in.quit) self.running = false;
        
        self.control();

        const fixed_dt = 1.0 / 60.0;
        while (self.accumulator >= fixed_dt) {
            self.in.tick();
            self.advance();
            self.accumulator -= fixed_dt;
        }
    }

    fn control(self: *App) void {
        if (self.in.keyPressed(sdl.c.SDL_SCANCODE_ESCAPE) and self.in.mouse_locked) {
            self.in.setLock(self.dev.window, false);
        }
        if (!self.in.mouse_locked and self.in.mousePressed(sdl.c.SDL_BUTTON_LEFT)) {
            self.in.setLock(self.dev.window, true);
        }

        if (self.in.mouse_locked) {
            self.physics.angles.items[self.player_id] = self.physics.angles.items[self.player_id]
                .addY(@intFromFloat(self.in.mouse_dx * 30.0))
                .addX(@intFromFloat(self.in.mouse_dy * 30.0))
                .clampPitch();
        }
    }

    fn advance(self: *App) void {
        // Only process player movement commands if the game window is locked
        const in_jump = self.in.consume(.jump, false) and self.in.mouse_locked;
        const in_crouch = self.in.consume(.crouch, self.in.key(sdl.c.SDL_SCANCODE_LCTRL)) and self.in.mouse_locked;
        const in_fire = self.in.consume(.fire, false) and self.in.mouse_locked;
        
        const w_val = if (self.in.key(sdl.c.SDL_SCANCODE_W) and self.in.mouse_locked) Unit.ONE else if (self.in.key(sdl.c.SDL_SCANCODE_S) and self.in.mouse_locked) Unit.ONE.neg() else Unit.ZERO;
        const d_val = if (self.in.key(sdl.c.SDL_SCANCODE_D) and self.in.mouse_locked) Unit.ONE else if (self.in.key(sdl.c.SDL_SCANCODE_A) and self.in.mouse_locked) Unit.ONE.neg() else Unit.ZERO;

        const angles = self.physics.angles.items[self.player_id];
        const wish_dir = wishdir(angles, w_val, d_val);

        const flags = self.physics.flags.items[self.player_id];
        const cfg = phys.Config{};
        
        const eye_h = if (flags.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
        var eye_pos = self.physics.pos.items[self.player_id];
        eye_pos[1] += eye_h.v;

        self.physics.step(
            &self.level_bvh,
            &.{.{ .wish = wish_dir, .jump = in_jump, .crouch = in_crouch, .fire = in_fire, .view_fwd = angles.forward(), .eye_pos = eye_pos }},
            Unit.fix(1.0 / 60.0), cfg,
        );
    }

    fn drawHud(self: *App, wf: f32, hf: f32) !void {
        if (self.in.mouse_locked) {
            try self.ui.drawRect(wf / 2.0 - 8.0, hf / 2.0 - 1.0, 16.0, 2.0, .{ 1, 1, 1, 0.7 });
            try self.ui.drawRect(wf / 2.0 - 1.0, hf / 2.0 - 8.0, 2.0, 16.0, .{ 1, 1, 1, 0.7 });
        } else {
            const cx = wf / 4.0; const cy = hf / 4.0;
            try self.ui.drawText(cx - 19.0 * 6.0, cy - 10.0, 2.0, "PRESS ESC TO UNLOCK", .{ 1, 1, 1, 1 });
            try self.ui.drawText(cx - 15.0 * 6.0, cy + 10.0, 2.0, "CLICK TO RESUME", .{ 1, 1, 1, 1 });
        }

        const hp = self.physics.health.items[self.player_id];
        const h_start = (wf / 2.0) - ((4.0 * 30.0 + 3.0 * 6.0) / 2.0);
        for (0..4) |i| {
            try self.ui.drawRect(h_start + @as(f32, @floatFromInt(i)) * 36.0, hf - 40.0, 30.0, 10.0, if (i < hp) [4]f32{ 0.1, 0.8, 0.3, 1.0 } else [4]f32{ 0.2, 0.2, 0.2, 0.5 });
        }

        self.hud_frame_counter += 1;
        if (self.hud_frame_counter >= HUD_PERCENTILE_INTERVAL) {
            self.hud_frame_counter = 0;
            self.cached_low_fps = @intFromFloat(self.percentile(0.01, false));
            self.cached_high_fps = @intFromFloat(self.percentile(0.01, true));
        }

        var fps_buf: [64]u8 = undefined;
        const fps_str = try std.fmt.bufPrint(&fps_buf, "FPS: {d} (1%L:{d} 1%H:{d})", .{ @as(u32, @intFromFloat(1.0 / @max(0.0001, self.frame_sum / @as(f32, @floatFromInt(self.frame_times.len))))), self.cached_low_fps, self.cached_high_fps });
        try self.ui.drawText((wf / 2.0) - (@as(f32, @floatFromInt(fps_str.len)) * 12.0) - 10.0, 10.0, 2.0, fps_str, .{ 0.4, 1.0, 0.4, 1.0 });

        var hbuf: [128]u8 = undefined;
        const pos = self.physics.pos.items[self.player_id];

        const vx = Unit.raw(self.physics.vel.items[self.player_id][0]).flt();
        const vz = Unit.raw(self.physics.vel.items[self.player_id][2]).flt();
        const speed = @sqrt(vx * vx + vz * vz);

        const info_str = try std.fmt.bufPrint(&hbuf, "POS: {d:.1} {d:.1} {d:.1} - {d:.1}", .{ Unit.raw(pos[0]).flt(), Unit.raw(pos[1]).flt(), Unit.raw(pos[2]).flt(), speed });
        try self.ui.drawText(10, 10, 2.0, info_str, .{ 0.8, 0.8, 0.4, 1.0 });
    }

    pub fn draw(self: *App) !void {
        if (try self.dev.beginFrame()) {
            const wf = @as(f32, @floatFromInt(self.dev.width));
            const hf = @as(f32, @floatFromInt(self.dev.height));

            try self.drawHud(wf, hf);

            const flags = self.physics.flags.items[self.player_id];
            const cfg = phys.Config{};
            
            const eye_h = if (flags.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
            const v = cameraView(self.physics.angles.items[self.player_id], self.physics.pos.items[self.player_id], eye_h);
            const vp = math.mulMat(math.persp(90.0, wf / hf, 0.1, 500.0), v);

            for (self.physics.rockets) |r| {
                if (!r.active) continue;
                const clip_w = vp[3] * Unit.raw(r.pos[0]).flt() + vp[7] * Unit.raw(r.pos[1]).flt() + vp[11] * Unit.raw(r.pos[2]).flt() + vp[15];
                if (clip_w > 0.1) {
                    const sx = ((vp[0] * Unit.raw(r.pos[0]).flt() + vp[4] * Unit.raw(r.pos[1]).flt() + vp[8] * Unit.raw(r.pos[2]).flt() + vp[12]) / clip_w + 1.0) * 0.5 * wf;
                    const sy = (1.0 - (vp[1] * Unit.raw(r.pos[0]).flt() + vp[5] * Unit.raw(r.pos[1]).flt() + vp[9] * Unit.raw(r.pos[2]).flt() + vp[13]) / clip_w) * 0.5 * hf;
                    const s1 = @max(2.0, 60.0 / clip_w);
                    const s2 = @max(1.0, 25.0 / clip_w);
                    try self.ui.drawRect(sx - s1 / 2.0, sy - s1 / 2.0, s1, s1, .{ 1.0, 0.4, 0.1, 0.7 });
                    try self.ui.drawRect(sx - s2 / 2.0, sy - s2 / 2.0, s2, s2, .{ 1.0, 1.0, 0.6, 1.0 });
                }
            }

            try self.ui.upload(self.dev.cmd.?);
            self.dev.beginRenderPass(self.scene.clear_color, true);
            self.scene.draw(self.mesh_h, vp);
            try self.ui.flush();
            self.dev.endFrame();
        }
    }
};

export var environ: ?[*]?[*:0]u8 = @ptrCast(@constCast(&[_]?[*:0]u8{null}));

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const app = try App.init(gpa.allocator());
    defer { app.deinit(); gpa.allocator().destroy(app); }
    while (app.running) {
        try app.update();
        try app.draw();
    }
}
