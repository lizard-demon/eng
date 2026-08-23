const std = @import("std");
const sdl = @import("kami");
const math = sdl.math;
const Unit = math.Unit;
const Vec3 = math.Vec3;
const State = @import("state.zig");
const BVH = @import("bvh.zig").Tree;

const FPS_BUCKETS: usize = 501;
const HUD_PERCENTILE_INTERVAL: u32 = 30;

pub const Action = enum { jump, crouch, fire };
pub const AppState = enum { main_menu, settings, loading, playing };

pub const UiState = struct {
    hot: usize = 0,
    active: usize = 0,
    bind_waiting: ?Action = null,
};

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

fn projectPos(vp: [16]f32, pos: Vec3, wf: f32, hf: f32) ?[3]f32 {
    const px = Unit.raw(pos[0]).flt();
    const py = Unit.raw(pos[1]).flt();
    const pz = Unit.raw(pos[2]).flt();
    const clip_w = vp[3] * px + vp[7] * py + vp[11] * pz + vp[15];
    
    if (clip_w <= 0.1) return null;
    
    const sx = ((vp[0] * px + vp[4] * py + vp[8] * pz + vp[12]) / clip_w + 1.0) * 0.5 * wf;
    const sy = (1.0 - (vp[1] * px + vp[5] * py + vp[9] * pz + vp[13]) / clip_w) * 0.5 * hf;
    
    return .{ sx, sy, clip_w };
}

fn transformMVP(vp: [16]f32, pos: Vec3, radius: f32) [16]f32 {
    var out = vp;
    const px = Unit.raw(pos[0]).flt();
    const py = Unit.raw(pos[1]).flt();
    const pz = Unit.raw(pos[2]).flt();

    out[0] *= radius; out[1] *= radius; out[2] *= radius; out[3] *= radius;
    out[4] *= radius; out[5] *= radius; out[6] *= radius; out[7] *= radius;
    out[8] *= radius; out[9] *= radius; out[10] *= radius; out[11] *= radius;

    out[12] = vp[0] * px + vp[4] * py + vp[8]  * pz + vp[12];
    out[13] = vp[1] * px + vp[5] * py + vp[9]  * pz + vp[13];
    out[14] = vp[2] * px + vp[6] * py + vp[10] * pz + vp[14];
    out[15] = vp[3] * px + vp[7] * py + vp[11] * pz + vp[15];

    return out;
}

pub const App = struct {
    alloc: std.mem.Allocator,
    dev: sdl.Device,
    scene: sdl.Scene,
    ui: sdl.Ui,
    level_bvh: BVH,
    render_verts: std.ArrayListUnmanaged(sdl.Scene.Vertex) = .{},
    render_indices: std.ArrayListUnmanaged(u32) = .{},
    
    app_state: AppState = .main_menu,
    ui_state: UiState = .{},
    next_map: usize = 0,
    
    mesh_h: sdl.Scene.Handle = 0,
    head_sphere_h: sdl.Scene.Handle = 0,
    body_sphere_h: sdl.Scene.Handle = 0,
    
    in: sdl.Input(Action),
    state: State.Game = .{},
    player_id: usize = 0,
    
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
            .last_time = sdl.c.SDL_GetTicksNS(),
        };

        app.in.sensitivity = 1.0; 
        app.in.bindKey(.jump, sdl.c.SDL_SCANCODE_SPACE);
        app.in.bindKey(.crouch, sdl.c.SDL_SCANCODE_LCTRL);
        app.in.bindMouse(.fire, sdl.c.SDL_BUTTON_LEFT);

        const vert_spv = @embedFile("shaders/triangle.vert.spv");
        const frag_spv = @embedFile("shaders/triangle.frag.spv");
        const ui_vert_spv = @embedFile("shaders/ui.vert.spv");
        const ui_frag_spv = @embedFile("shaders/ui.frag.spv");

        app.scene = try sdl.Scene.init(&app.dev, alloc, vert_spv, frag_spv);
        app.ui = try sdl.Ui.init(&app.dev, alloc, ui_vert_spv, ui_frag_spv);

        return app;
    }

    pub fn deinit(self: *App) void {
        self.ui.deinit();
        self.scene.deinit();
        self.dev.deinit();
        self.level_bvh.deinit();
        self.render_verts.deinit(self.alloc);
        self.render_indices.deinit(self.alloc);
    }

    // ============================================================================
    // CORE SYSTEMS
    // ============================================================================

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

        switch (self.app_state) {
            .settings => try self.updateSettings(),
            .loading => try self.doLoadMap(),
            .playing => try self.updatePlaying(),
            else => {},
        }
    }

    fn updateSettings(self: *App) !void {
        // Evaluate keybindings safely outside of the immediate UI render phase
        if (self.ui_state.bind_waiting) |action| {
            if (self.in.keyPressed(sdl.c.SDL_SCANCODE_ESCAPE)) {
                self.ui_state.bind_waiting = null;
            } else {
                var iter = self.in.keys_pressed.iterator(.{});
                if (iter.next()) |sc_idx| {
                    self.clearBind(action);
                    self.in.bindKey(action, @intCast(sc_idx));
                    self.ui_state.bind_waiting = null;
                }
                for (0..5) |btn_idx| {
                    if (self.in.mousePressed(@intCast(btn_idx))) {
                        self.clearBind(action);
                        const sdl_btn: u8 = switch (btn_idx) { 0=>1, 1=>2, 2=>3, 3=>4, 4=>5, else=>0 };
                        self.in.bindMouse(action, sdl_btn);
                        self.ui_state.bind_waiting = null;
                    }
                }
            }
            // Consume input to prevent instant-activation of buttons behind the bind frame
            self.in.keys_pressed = std.StaticBitSet(512).initEmpty();
            @memset(&self.in.mouse_pressed, false);
        }
    }

    fn updatePlaying(self: *App) !void {
        if (self.in.keyPressed(sdl.c.SDL_SCANCODE_ESCAPE) and self.in.mouse_locked) {
            self.in.setLock(self.dev.window, false);
            self.app_state = .main_menu;
            return;
        }
        
        if (!self.in.mouse_locked and self.in.mousePressed(sdl.c.SDL_BUTTON_LEFT)) {
            self.in.setLock(self.dev.window, true);
        }

        if (self.in.mouse_locked) {
            self.state.angles[self.player_id] = self.state.angles[self.player_id]
                .addY(@intFromFloat(self.in.mouse_dx * 30.0))
                .addX(@intFromFloat(self.in.mouse_dy * 30.0))
                .clampPitch();

            if (self.in.keyPressed(sdl.c.SDL_SCANCODE_1)) self.state.weapon_states[self.player_id].id = .pistol;
            if (self.in.keyPressed(sdl.c.SDL_SCANCODE_2)) self.state.weapon_states[self.player_id].id = .shotgun;
            if (self.in.keyPressed(sdl.c.SDL_SCANCODE_3)) self.state.weapon_states[self.player_id].id = .rifle;
            if (self.in.keyPressed(sdl.c.SDL_SCANCODE_4)) self.state.weapon_states[self.player_id].id = .rocket;
        }

        const fixed_dt = 1.0 / 60.0;
        while (self.accumulator >= fixed_dt) {
            self.in.tick();
            
            const w_val = if (self.in.key(sdl.c.SDL_SCANCODE_W) and self.in.mouse_locked) Unit.ONE else if (self.in.key(sdl.c.SDL_SCANCODE_S) and self.in.mouse_locked) Unit.ONE.neg() else Unit.ZERO;
            const d_val = if (self.in.key(sdl.c.SDL_SCANCODE_D) and self.in.mouse_locked) Unit.ONE else if (self.in.key(sdl.c.SDL_SCANCODE_A) and self.in.mouse_locked) Unit.ONE.neg() else Unit.ZERO;

            const angles = self.state.angles[self.player_id];
            
            var inputs = [_]State.Player.Input{.{}} ** State.MAX_PLAYERS;
            inputs[self.player_id] = .{
                .wish = wishdir(angles, w_val, d_val),
                .jump = self.in.consume(.jump, false) and self.in.mouse_locked,
                .crouch = self.in.consume(.crouch, self.in.key(sdl.c.SDL_SCANCODE_LCTRL)) and self.in.mouse_locked,
                .fire = self.in.consume(.fire, self.in.mouse(sdl.c.SDL_BUTTON_LEFT)) and self.in.mouse_locked,
                .view_angle = angles,
            };

            self.state.step(&self.level_bvh, &inputs, Unit.fix(1.0 / 60.0), State.Config{});
            self.accumulator -= fixed_dt;
        }
    }

    pub fn draw(self: *App) !void {
        if (try self.dev.beginFrame()) {
            const wf = @as(f32, @floatFromInt(self.dev.width));
            const hf = @as(f32, @floatFromInt(self.dev.height));

            switch (self.app_state) {
                .playing => try self.drawPlaying(wf, hf),
                else => {
                    if (self.app_state == .main_menu) try self.drawMenu(wf, hf);
                    if (self.app_state == .settings) try self.drawSettings(wf, hf);
                    
                    try self.ui.upload(self.dev.cmd.?);
                    self.dev.beginRenderPass(.{ 0.03, 0.03, 0.03, 1.0 }, false);
                    try self.ui.flush();
                    self.dev.endFrame();
                },
            }
        }
    }

    // ============================================================================
    // MAP LOADING & GEOMETRY
    // ============================================================================
    
    fn doLoadMap(self: *App) !void {
        // Complete teardown ensures absolutely zero memory leaks across map reloads
        self.scene.deinit();
        self.level_bvh.deinit();
        self.render_verts.clearRetainingCapacity();
        self.render_indices.clearRetainingCapacity();
        
        const vert_spv = @embedFile("shaders/triangle.vert.spv");
        const frag_spv = @embedFile("shaders/triangle.frag.spv");
        self.scene = try sdl.Scene.init(&self.dev, self.alloc, vert_spv, frag_spv);
        self.level_bvh = BVH.init(self.alloc);
        
        if (self.next_map == 0) {
            // Brutalist Architecture
            try self.box(.{0, Unit.fix(-2).v, 0}, Unit.fix(50), Unit.fix(2), Unit.fix(50), .{0.15, 0.15, 0.15, 1.0}); 
            try self.box(.{0, Unit.fix(20).v, 0}, Unit.fix(50), Unit.fix(2), Unit.fix(50), .{0.05, 0.05, 0.05, 1.0});
            
            try self.box(.{0, Unit.fix(10).v, Unit.fix(-52).v}, Unit.fix(50), Unit.fix(12), Unit.fix(2), .{0.8, 0.1, 0.1, 1.0}); // Red Accent Wall
            try self.box(.{0, Unit.fix(10).v, Unit.fix(52).v}, Unit.fix(50), Unit.fix(12), Unit.fix(2), .{0.2, 0.2, 0.2, 1.0});
            try self.box(.{Unit.fix(-52).v, Unit.fix(10).v, 0}, Unit.fix(2), Unit.fix(12), Unit.fix(50), .{0.2, 0.2, 0.2, 1.0});
            try self.box(.{Unit.fix(52).v, Unit.fix(10).v, 0}, Unit.fix(2), Unit.fix(12), Unit.fix(50), .{0.2, 0.2, 0.2, 1.0});
            
            try self.box(.{0, Unit.fix(4).v, 0}, Unit.fix(4), Unit.fix(4), Unit.fix(4), .{0.15, 0.15, 0.15, 1.0});
            try self.box(.{Unit.fix(-20).v, Unit.fix(6).v, Unit.fix(20).v}, Unit.fix(6), Unit.fix(0.5), Unit.fix(6), .{0.3, 0.3, 0.3, 1.0});
            try self.box(.{Unit.fix(20).v, Unit.fix(8).v, Unit.fix(-20).v}, Unit.fix(6), Unit.fix(0.5), Unit.fix(6), .{0.3, 0.3, 0.3, 1.0});
        }

        try self.level_bvh.build();
        self.mesh_h = try self.scene.upload(std.mem.sliceAsBytes(self.render_verts.items), std.mem.sliceAsBytes(self.render_indices.items));
        
        self.head_sphere_h = try self.buildSphere(.{ 0.9, 0.9, 0.9, 1.0 });
        self.body_sphere_h = try self.buildSphere(.{ 0.5, 0.5, 0.5, 1.0 });

        // Reset Engine State
        self.state = State.Game{};
        self.player_id = self.state.spawnPlayer(.{ 0, Unit.fix(2).v, Unit.fix(-40).v }) orelse 0;
        
        // Target Dummies
        _ = self.state.spawnPlayer(.{ Unit.fix(-20).v, Unit.fix(8).v, Unit.fix(20).v });
        _ = self.state.spawnPlayer(.{ Unit.fix(20).v, Unit.fix(10).v, Unit.fix(-20).v });
        _ = self.state.spawnPlayer(.{ Unit.fix(0).v, Unit.fix(10).v, Unit.fix(0).v });

        self.app_state = .playing;
        self.in.setLock(self.dev.window, true);
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

    fn box(self: *App, center: Vec3, hx: Unit, hy: Unit, hz: Unit, color: [4]f32) !void {
        const x = hx.v; const y = hy.v; const z = hz.v;
        const p0 = center + Vec3{-x, -y, -z};
        const p1 = center + Vec3{ x, -y, -z};
        const p2 = center + Vec3{ x,  y, -z};
        const p3 = center + Vec3{-x,  y, -z};
        const p4 = center + Vec3{-x, -y,  z};
        const p5 = center + Vec3{ x, -y,  z};
        const p6 = center + Vec3{ x,  y,  z};
        const p7 = center + Vec3{-x,  y,  z};
        
        try self.quad(p3, p2, p1, p0, color);
        try self.quad(p4, p5, p6, p7, color);
        try self.quad(p7, p6, p2, p3, color);
        try self.quad(p0, p1, p5, p4, color);
        try self.quad(p7, p3, p0, p4, color);
        try self.quad(p2, p6, p5, p1, color);
    }

    fn buildSphere(self: *App, color: [4]f32) !sdl.Scene.Handle {
        var verts: std.ArrayListUnmanaged(sdl.Scene.Vertex) = .{};
        defer verts.deinit(self.alloc);
        var inds: std.ArrayListUnmanaged(u32) = .{};
        defer inds.deinit(self.alloc);

        const lat_count = 12;
        const lon_count = 16;
        for (0..lat_count + 1) |lat| {
            const theta = std.math.pi * @as(f32, @floatFromInt(lat)) / @as(f32, @floatFromInt(lat_count));
            const sin_theta = @sin(theta);
            const cos_theta = @cos(theta);

            for (0..lon_count + 1) |lon| {
                const phi = 2.0 * std.math.pi * @as(f32, @floatFromInt(lon)) / @as(f32, @floatFromInt(lon_count));
                const x = sin_theta * @cos(phi);
                const y = cos_theta;
                const z = sin_theta * @sin(phi);

                try verts.append(self.alloc, .{
                    .pos = .{ @intFromFloat(x * 1024.0), @intFromFloat(y * 1024.0), @intFromFloat(z * 1024.0) },
                    .color = color,
                });
            }
        }
        for (0..lat_count) |lat| {
            for (0..lon_count) |lon| {
                const first = @as(u32, @intCast(lat * (lon_count + 1) + lon));
                const second = first + lon_count + 1;
                try inds.appendSlice(self.alloc, &.{ first, second, first + 1, second, second + 1, first + 1 });
            }
        }
        return self.scene.upload(std.mem.sliceAsBytes(verts.items), std.mem.sliceAsBytes(inds.items));
    }

    // ============================================================================
    // IMMEDIATE MODE UI WIDGETS
    // ============================================================================
    fn clearBind(self: *App, action: Action) void {
        for (&self.in.key_lut) |*a| {
            if (a.* == action) {
                a.* = null;
            }
        }
        for (&self.in.mouse_lut) |*a| {
            if (a.* == action) {
                a.* = null;
            }
        }
    }
    
    fn doButton(self: *App, id: usize, text: []const u8, x: f32, y: f32, w: f32, h: f32) !bool {
        const hover = self.in.mouse_x >= x and self.in.mouse_x <= x + w and self.in.mouse_y >= y and self.in.mouse_y <= y + h;
        if (hover) self.ui_state.hot = id;
        
        var clicked = false;
        if (self.ui_state.active == id) {
            if (self.in.mouseReleased(sdl.c.SDL_BUTTON_LEFT)) {
                if (hover) clicked = true;
                self.ui_state.active = 0;
            }
        } else if (self.ui_state.hot == id) {
            if (self.in.mousePressed(sdl.c.SDL_BUTTON_LEFT)) {
                self.ui_state.active = id;
            }
        }
        
        const active = self.ui_state.active == id;
        const hot = self.ui_state.hot == id;
        
        const bg: [4]f32 = if (active) .{1, 1, 1, 1} else if (hot) .{0.8, 0.1, 0.1, 1} else .{0, 0, 0, 1};
        const fg: [4]f32 = if (active) .{0, 0, 0, 1} else if (hot) .{1, 1, 1, 1} else .{1, 1, 1, 1};
        
        try self.ui.drawRect(x, y, w, h, bg);
        if (!active and !hot) {
            try self.ui.drawRect(x, y, w, 2.0, fg);
            try self.ui.drawRect(x, y+h-2.0, w, 2.0, fg);
            try self.ui.drawRect(x, y, 2.0, h, fg);
            try self.ui.drawRect(x+w-2.0, y, 2.0, h, fg);
        }
        
        const scale = 2.0;
        const tw = @as(f32, @floatFromInt(text.len)) * 6.0 * scale;
        try self.ui.drawText(x + (w - tw)/2.0, y + (h - 5.0*scale)/2.0, scale, text, fg);
        
        return clicked;
    }

    // ============================================================================
    // MENU RENDERING
    // ============================================================================

    fn drawMenu(self: *App, wf: f32, hf: f32) !void {
        self.ui_state.hot = 0;
        
        const title = "K A M I";
        const t_scale = 8.0;
        const tw = @as(f32, @floatFromInt(title.len)) * 6.0 * t_scale;
        try self.ui.drawText(wf/2.0 - tw/2.0, hf/4.0, t_scale, title, .{1, 1, 1, 1});
        
        const bw = 300.0;
        const bh = 50.0;
        const bx = wf/2.0 - bw/2.0;
        var by = hf/2.0;
        
        if (try self.doButton(1, "START ARENA", bx, by, bw, bh)) {
            self.app_state = .loading;
            self.next_map = 0;
        }
        by += bh + 20.0;
        
        if (try self.doButton(2, "SETTINGS", bx, by, bw, bh)) {
            self.app_state = .settings;
            self.ui_state.bind_waiting = null;
        }
        by += bh + 20.0;
        
        if (try self.doButton(3, "QUIT", bx, by, bw, bh)) {
            self.running = false;
        }
    }

    fn drawSettings(self: *App, wf: f32, hf: f32) !void {
        self.ui_state.hot = 0;
        
        const title = "SETTINGS";
        const t_scale = 6.0;
        const tw = @as(f32, @floatFromInt(title.len)) * 6.0 * t_scale;
        try self.ui.drawText(wf/2.0 - tw/2.0, 50.0, t_scale, title, .{1, 1, 1, 1});
        
        const bw = 400.0;
        const bh = 40.0;
        const bx = wf/2.0 - bw/2.0;
        var by: f32 = 180.0;
        
        var buf: [64]u8 = undefined;
        const sens_str = try std.fmt.bufPrint(&buf, "SENSITIVITY: {d:.2}", .{self.in.sensitivity});
        if (try self.doButton(10, sens_str, bx, by, bw, bh)) {
            self.in.sensitivity = if (self.in.sensitivity > 4.9) 0.5 else self.in.sensitivity + 0.5;
        }
        by += bh + 20.0;
        
        inline for (std.meta.fields(Action), 0..) |field, idx| {
            const action = @as(Action, @enumFromInt(field.value));
            var bind_name: []const u8 = "UNBOUND";
            
            if (self.ui_state.bind_waiting != null and self.ui_state.bind_waiting.? == action) {
                bind_name = "WAITING...";
            } else {
                for (self.in.key_lut, 0..) |a, sc| {
                    if (a != null and a.? == action) {
                        bind_name = std.mem.span(sdl.c.SDL_GetScancodeName(@intCast(sc)));
                        break;
                    }
                }
                for (self.in.mouse_lut, 0..) |a, btn| {
                    if (a != null and a.? == action) {
                        bind_name = switch (btn) { 0=>"M_LEFT", 1=>"M_MIDDLE", 2=>"M_RIGHT", 3=>"M_X1", 4=>"M_X2", else=>"M_AUX" };
                        break;
                    }
                }
            }
            
            var action_up: [16]u8 = undefined;
            for (field.name, 0..) |c, i| action_up[i] = std.ascii.toUpper(c);
            
            const btn_str = try std.fmt.bufPrint(&buf, "{s}: {s}", .{action_up[0..field.name.len], bind_name});
            if (try self.doButton(20 + idx, btn_str, bx, by, bw, bh)) {
                self.ui_state.bind_waiting = action;
            }
            by += bh + 20.0;
        }
        
        if (try self.doButton(99, "BACK", bx, hf - 100.0, bw, bh)) {
            self.app_state = .main_menu;
            self.ui_state.bind_waiting = null;
        }
    }

    // ============================================================================
    // GAMEPLAY RENDERING
    // ============================================================================

    fn drawPlaying(self: *App, wf: f32, hf: f32) !void {
        if (self.in.mouse_locked) {
            try self.ui.drawRect(wf / 2.0 - 8.0, hf / 2.0 - 1.0, 16.0, 2.0, .{ 1, 1, 1, 0.7 });
            try self.ui.drawRect(wf / 2.0 - 1.0, hf / 2.0 - 8.0, 2.0, 16.0, .{ 1, 1, 1, 0.7 });
        } else {
            const cx = wf / 4.0; const cy = hf / 4.0;
            try self.ui.drawText(cx - 19.0 * 6.0, cy - 10.0, 2.0, "PRESS ESC TO MENU", .{ 1, 1, 1, 1 });
            try self.ui.drawText(cx - 15.0 * 6.0, cy + 10.0, 2.0, "CLICK TO RESUME", .{ 1, 1, 1, 1 });
        }

        const hp = @as(f32, @floatFromInt(self.state.health[self.player_id]));
        const max_hp = 256.0;
        const hp_pct = @max(0.0, hp / max_hp);
        const w = 240.0;
        try self.ui.drawRect(wf / 2.0 - w / 2.0, hf - 40.0, w, 15.0, .{ 0.2, 0.2, 0.2, 0.5 });
        try self.ui.drawRect(wf / 2.0 - w / 2.0, hf - 40.0, w * hp_pct, 15.0, .{ 0.8, 0.1, 0.1, 1.0 });

        self.hud_frame_counter += 1;
        if (self.hud_frame_counter >= HUD_PERCENTILE_INTERVAL) {
            self.hud_frame_counter = 0;
            self.cached_low_fps = @intFromFloat(self.percentile(0.01, false));
            self.cached_high_fps = @intFromFloat(self.percentile(0.01, true));
        }

        var buf: [64]u8 = undefined;
        const fps_str = try std.fmt.bufPrint(&buf, "FPS: {d} (1%L:{d} 1%H:{d})", .{ @as(u32, @intFromFloat(1.0 / @max(0.0001, self.frame_sum / @as(f32, @floatFromInt(self.frame_times.len))))), self.cached_low_fps, self.cached_high_fps });
        try self.ui.drawText((wf / 2.0) - (@as(f32, @floatFromInt(fps_str.len)) * 12.0) - 10.0, 10.0, 2.0, fps_str, .{ 0.4, 1.0, 0.4, 1.0 });

        const flags = self.state.flags[self.player_id];
        const cfg = State.Config{};
        const eye_h = if (flags.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
        const v = cameraView(self.state.angles[self.player_id], self.state.pos[self.player_id], eye_h);
        const vp = math.mulMat(math.persp(90.0, wf / hf, 0.1, 500.0), v);

        for (self.state.projectiles) |r| {
            if (!r.active) continue;
            if (projectPos(vp, r.pos, wf, hf)) |proj| {
                const s1 = @max(2.0, 60.0 / proj[2]);
                const s2 = @max(1.0, 25.0 / proj[2]);
                try self.ui.drawRect(proj[0] - s1 / 2.0, proj[1] - s1 / 2.0, s1, s1, .{ 1.0, 0.4, 0.1, 0.7 });
                try self.ui.drawRect(proj[0] - s2 / 2.0, proj[1] - s2 / 2.0, s2, s2, .{ 1.0, 1.0, 0.6, 1.0 });
            }
        }

        for (self.state.impacts) |imp| {
            if (imp.life.v <= 0) continue;
            if (projectPos(vp, imp.pos, wf, hf)) |proj| {
                const life_f = imp.life.flt();
                var base_size: f32 = 0;
                var color: [4]f32 = .{ 0, 0, 0, life_f };
                
                switch (imp.kind) {
                    .spark => { base_size = 15.0; color[0] = 1.0; color[1] = 0.8; color[2] = 0.2; },
                    .blood => { base_size = 25.0; color[0] = 0.8; color[1] = 0.1; color[2] = 0.1; },
                    .explosion => { base_size = 80.0; color[0] = 1.0; color[1] = 0.4; color[2] = 0.1; },
                }
                const size = @max(1.0, base_size / proj[2]) * (0.5 + 0.5 * life_f);
                try self.ui.drawRect(proj[0] - size / 2.0, proj[1] - size / 2.0, size, size, color);
            }
        }

        try self.ui.upload(self.dev.cmd.?);
        
        self.dev.beginRenderPass(self.scene.clear_color, true);
        self.scene.draw(self.mesh_h, vp);
        
        for (0..State.MAX_PLAYERS) |id| {
            if (!self.state.isActive(id) or id == self.player_id) continue;
            
            const tp = self.state.pos[id];
            const tf = self.state.flags[id];
            const t_eye_h = if (tf.crouched) cfg.stand_eye.sub(cfg.crouch_offset) else cfg.stand_eye;
            
            const head_pos: Vec3 = .{ tp[0], tp[1] + t_eye_h.v, tp[2] };
            const body_pos: Vec3 = .{ tp[0], tp[1] + @divTrunc(t_eye_h.v, 2), tp[2] };

            self.scene.draw(self.head_sphere_h, transformMVP(vp, head_pos, cfg.head_radius.flt()));
            self.scene.draw(self.body_sphere_h, transformMVP(vp, body_pos, cfg.body_radius.flt()));
        }

        try self.ui.flush();
        self.dev.endFrame();
    }
    
    // ============================================================================
    // STATISTICS
    // ============================================================================
    
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
