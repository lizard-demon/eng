//! fmwk.zig — Modular Monolithic BSP Engine, Immediate UI, and Editor
const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;

// ── Math & Geometry ───────────────────────────────────────────────
pub const math = struct {
    pub const Vec3 = packed struct {
        data: @Vector(3, f32),
        pub inline fn new(x: f32, y: f32, z: f32) Vec3 { return .{ .data = .{ x, y, z } }; }
        pub inline fn zero() Vec3 { return .{ .data = @splat(0) }; }
        pub inline fn one() Vec3 { return .{ .data = @splat(1) }; }
        pub inline fn splat(s: f32) Vec3 { return .{ .data = @splat(s) }; }
        pub inline fn add(v: Vec3, o: Vec3) Vec3 { return .{ .data = v.data + o.data }; }
        pub inline fn sub(v: Vec3, o: Vec3) Vec3 { return .{ .data = v.data - o.data }; }
        pub inline fn mul(v: Vec3, o: Vec3) Vec3 { return .{ .data = v.data * o.data }; }
        pub inline fn neg(v: Vec3) Vec3 { return .{ .data = -v.data }; }
        pub inline fn scale(v: Vec3, s: f32) Vec3 { return .{ .data = v.data * @as(@Vector(3, f32), @splat(s)) }; }
        pub inline fn dot(v: Vec3, o: Vec3) f32 { return @reduce(.Add, v.data * o.data); }
        pub inline fn lengthSq(v: Vec3) f32 { return dot(v, v); }
        pub inline fn length(v: Vec3) f32 { return @sqrt(lengthSq(v)); }
        pub inline fn dist(a: Vec3, b: Vec3) f32 { return length(sub(a, b)); }
        pub inline fn normalize(v: Vec3) Vec3 { const l = length(v); return if (l > 0) scale(v, 1.0 / l) else v; }
        pub inline fn cross(a: Vec3, b: Vec3) Vec3 { return Vec3.new(a.data[1]*b.data[2] - a.data[2]*b.data[1], a.data[2]*b.data[0] - a.data[0]*b.data[2], a.data[0]*b.data[1] - a.data[1]*b.data[0]); }
        pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 { return add(a, sub(b, a).scale(t)); }
        pub inline fn min(a: Vec3, b: Vec3) Vec3 { return .{ .data = @min(a.data, b.data) }; }
        pub inline fn max(a: Vec3, b: Vec3) Vec3 { return .{ .data = @max(a.data, b.data) }; }
    };
    pub const AABB = packed struct {
        lo: Vec3, hi: Vec3,
        pub fn new(lo: Vec3, hi: Vec3) AABB { return .{ .lo = lo, .hi = hi }; }
        pub fn expand(a: AABB, p: Vec3) AABB { return .{ .lo = Vec3.min(a.lo, p), .hi = Vec3.max(a.hi, p) }; }
        pub const empty = AABB{ .lo = Vec3.splat(std.math.floatMax(f32)), .hi = Vec3.splat(-std.math.floatMax(f32)) };
    };
    pub const Ray = struct { origin: Vec3, dir: Vec3, pub fn at(self: Ray, t: f32) Vec3 { return self.origin.add(self.dir.scale(t)); } };
    pub const Plane = struct { normal: Vec3, dist: f32, pub fn distToPoint(self: Plane, p: Vec3) f32 { return self.normal.dot(p) + self.dist; } };
    pub const Frustum = struct {
        planes: [6]Plane,
        pub fn fromCamera(eye: Vec3, fwd: Vec3, rt: Vec3, u: Vec3, fovy: f32, aspect: f32, near: f32, far: f32) Frustum {
            const hy = @tan(fovy * 0.5); const hx = hy * aspect; var p: [6]Plane = undefined;
            p[0] = .{ .normal = fwd, .dist = -(fwd.dot(eye) + near) }; p[1] = .{ .normal = fwd.neg(), .dist = fwd.dot(eye) + far };
            p[2] = .{ .normal = u.cross(fwd.add(rt.scale(hx))).normalize(), .dist = 0 }; p[3] = .{ .normal = fwd.sub(rt.scale(hx)).cross(u).normalize(), .dist = 0 };
            p[4] = .{ .normal = fwd.add(u.scale(hy)).cross(rt).normalize(), .dist = 0 }; p[5] = .{ .normal = rt.cross(fwd.sub(u.scale(hy))).normalize(), .dist = 0 };
            for (2..6) |i| p[i].dist = -p[i].normal.dot(eye); return .{ .planes = p };
        }
        pub fn containsAABB(self: Frustum, box: AABB) bool {
            for (self.planes) |p| {
                const pv = Vec3.new(if (p.normal.data[0]>=0) box.hi.data[0] else box.lo.data[0], if (p.normal.data[1]>=0) box.hi.data[1] else box.lo.data[1], if (p.normal.data[2]>=0) box.hi.data[2] else box.lo.data[2]);
                if (p.normal.dot(pv) + p.dist < 0) return false;
            } return true;
        }
    };
    pub const Mat4 = struct {
        data: [16]f32,
        pub inline fn identity() Mat4 { return .{ .data = .{ 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 } }; }
        pub inline fn mul(a: Mat4, b: Mat4) Mat4 {
            var r: Mat4 = undefined; inline for (0..4) |c| { inline for (0..4) |row| { var s: f32 = 0; inline for (0..4) |k| s += a.data[k*4 + row] * b.data[c*4 + k]; r.data[c*4 + row] = s; } } return r;
        }
        pub inline fn translate(v: Vec3) Mat4 { return .{ .data = .{ 1,0,0,0, 0,1,0,0, 0,0,1,0, v.data[0],v.data[1],v.data[2],1 } }; }
        pub inline fn viewMatrix(pos: Vec3, yaw: f32, pitch: f32, eye_height: f32) Mat4 {
            const eye = pos.add(Vec3.new(0, eye_height, 0)); const cy = @cos(yaw); const sy = @sin(yaw); const cp = @cos(pitch); const sp = @sin(pitch);
            return .{ .data = .{ cy, sy*sp, -sy*cp, 0, 0, cp, sp, 0, sy, -cy*sp, cy*cp, 0, -eye.data[0]*cy - eye.data[2]*sy, -eye.data[0]*sy*sp - eye.data[1]*cp + eye.data[2]*cy*sp, eye.data[0]*sy*cp - eye.data[1]*sp - eye.data[2]*cy*cp, 1 } };
        }
    };
    pub inline fn perspective(fov: f32, asp: f32, near: f32, far: f32) Mat4 { const t = @tan(fov * std.math.pi / 360.0) * near; const r = t * asp; return .{ .data = .{ near/r, 0, 0, 0, 0, near/t, 0, 0, 0, 0, -(far+near)/(far-near), -1, 0, 0, -(2*far*near)/(far-near), 0 } }; }
    pub inline fn ortho(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) Mat4 { return .{ .data = .{ 2.0/(r-l), 0, 0, 0, 0, 2.0/(t-b), 0, 0, 0, 0, -2.0/(f-n), 0, -(r+l)/(r-l), -(t+b)/(t-b), -(f+n)/(f-n), 1.0 } }; }
    pub inline fn wishdir(fwd: f32, right: f32, yaw: f32) Vec3 { return Vec3.add(Vec3.new(@sin(yaw),0,-@cos(yaw)).scale(fwd), Vec3.new(@cos(yaw),0,@sin(yaw)).scale(right)); }
};

// ── Physics ───────────────────────────────────────────────────────
pub const phys = struct {
    pub const Hit = struct { normal: math.Vec3, dist: f32 };
    pub const Config = struct { gravity: f32=9.8, jump_speed: f32=5.0, max_speed: f32=6.0, air_speed: f32=1.0, accel: f32=50.0, friction: f32=6.0, slope_limit: f32=0.707, max_slides: u32=4, radius: f32=0.3, eye_height: f32=0.6, ground_snap: f32=0.05 };
    pub fn Body(comptime cfg: Config) type {
        return struct {
            const Self = @This();
            pos: math.Vec3 = math.Vec3.zero(), vel: math.Vec3 = math.Vec3.zero(), grounded: bool = false, yaw: f32 = 0, pitch: f32 = 0,
            pub fn eyePos(self: Self) math.Vec3 { return self.pos.add(math.Vec3.new(0, cfg.eye_height, 0)); }
            pub fn lookDir(self: Self) math.Vec3 { return math.Vec3.new(@sin(self.yaw)*@cos(self.pitch), -@sin(self.pitch), -@cos(self.yaw)*@cos(self.pitch)).normalize(); }
            pub fn step(self: *Self, world: anytype, wish: math.Vec3, jump: bool, dt: f32) void {
                self.grounded = false; var g_norm = math.Vec3.new(0, 1, 0);
                if (world.cast(self.pos, math.Vec3.new(0, -1, 0), cfg.ground_snap)) |h| { if (h.normal.data[1] > cfg.slope_limit) { self.grounded = true; g_norm = h.normal; } }
                if (self.grounded) {
                    const vn = self.vel.dot(g_norm); if (vn < 0) self.vel = self.vel.sub(g_norm.scale(vn));
                    const spd = @sqrt(self.vel.data[0]*self.vel.data[0] + self.vel.data[2]*self.vel.data[2]);
                    if (spd > 0.1) { const f = @max(0, spd - spd*cfg.friction*dt) / spd; self.vel.data[0] *= f; self.vel.data[2] *= f; } else { self.vel.data[0]=0; self.vel.data[2]=0; }
                } else { self.vel.data[1] -= cfg.gravity * dt; }
                if (jump and self.grounded) { self.vel.data[1] = cfg.jump_speed; self.grounded = false; }
                const wl = @sqrt(wish.data[0]*wish.data[0] + wish.data[2]*wish.data[2]);
                if (wl > 0) {
                    const wn = wish.scale(1.0 / wl); const top = if (self.grounded) cfg.max_speed*wl else @min(cfg.max_speed*wl, cfg.air_speed);
                    self.vel = self.vel.add(wn.scale(@min(cfg.accel*dt, @max(0, top - math.Vec3.new(self.vel.data[0], 0, self.vel.data[2]).dot(wn)))));
                }
                var rem = self.vel.scale(dt);
                for (0..cfg.max_slides) |_| {
                    const l = rem.length(); if (l < 1e-5) break; const dir = rem.scale(1.0 / l);
                    const h = world.cast(self.pos, dir, l + 1e-3) orelse { self.pos = self.pos.add(rem); break; };
                    const md = @max(0, h.dist - 1e-5); if (md > 0) { self.pos = self.pos.add(dir.scale(md)); rem = rem.sub(dir.scale(@min(md, l))); }
                    self.pos = self.pos.add(h.normal.scale(1e-3));
                    rem = clip(rem, h.normal); self.vel = clip(self.vel, h.normal);
                }
            }
            fn clip(in: math.Vec3, n: math.Vec3) math.Vec3 { const b = in.dot(n); if (b >= 0) return in; var o = in.sub(n.scale(b)); const r = o.dot(n); return if (r < 0) o.sub(n.scale(r)) else o; }
        };
    }
};

// ── Immediate UI & Font ───────────────────────────────────────────
pub const ui = struct {
    pub const State = struct {
        mx: f32=0, my: f32=0, mdown: bool=false, hot: u32=0, active: u32=0, cx: f32=0, cy: f32=0,
        verts: std.ArrayListUnmanaged(gfx.Vertex) = .{}, indices: std.ArrayListUnmanaged(u32) = .{}, alloc: std.mem.Allocator,
        pub fn init(alloc: std.mem.Allocator) State { return .{ .alloc = alloc }; }
        pub fn deinit(self: *State) void { self.verts.deinit(self.alloc); self.indices.deinit(self.alloc); }
        pub fn begin(self: *State, in: *const Input) void {
            self.mx = if (!in.mouse_locked) in.mx else -1;
            self.my = if (!in.mouse_locked) in.my else -1;
            self.mdown = if (!in.mouse_locked) in.mdown_left else false;
            self.hot = 0; self.cx = 20; self.cy = 20;
            self.verts.clearRetainingCapacity(); self.indices.clearRetainingCapacity();
        }
        pub fn end(self: *State) void { if (!self.mdown) self.active = 0; }
        fn quad(self: *State, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
            const base: u32 = @intCast(self.verts.items.len);
            try self.verts.appendSlice(self.alloc, &.{ .{ .pos = .{x, y, 0}, .color = color }, .{ .pos = .{x+w, y, 0}, .color = color }, .{ .pos = .{x+w, y+h, 0}, .color = color }, .{ .pos = .{x, y+h, 0}, .color = color } });
            try self.indices.appendSlice(self.alloc, &.{ base, base+3, base+2, base, base+2, base+1 });
        }
        pub fn textAt(self: *State, x: f32, y: f32, str: []const u8, scale: f32, color: [4]f32) !void {
            var ox = x;
            for (str) |c| {
                if (c < 128) for (static_data.font[c], 0..) |row, py| for (0..5) |px| if (((row >> @as(u3, @intCast(4 - px))) & 1) != 0)
                    try self.quad(ox + @as(f32, @floatFromInt(px))*scale, y + @as(f32, @floatFromInt(py))*scale, scale, scale, color);
                ox += 6.0 * scale;
            }
        }
        pub fn text(self: *State, str: []const u8, scale: f32, color: [4]f32) !void { try self.textAt(self.cx, self.cy, str, scale, color); }
        pub fn crosshair(self: *State, x: f32, y: f32, size: f32, color: [4]f32) !void { try self.quad(x-size, y-1, size*2, 2, color); try self.quad(x-1, y-size, 2, size*2, color); }
        pub fn button(self: *State, id: u32, str: []const u8, scale: f32) !bool {
            const w = @as(f32, @floatFromInt(str.len)) * 6.0 * scale + scale * 2.0; const h = 5.0 * scale + scale * 4.0;
            if (self.mx >= self.cx and self.mx < self.cx + w and self.my >= self.cy and self.my < self.cy + h) { self.hot = id; if (self.active == 0 and self.mdown) self.active = id; }
            const clicked = !self.mdown and self.hot == id and self.active == id;
            const bg: [4]f32 = if (self.active == id) .{ 0.8, 0.4, 0.1, 1.0 } else if (self.hot == id) .{ 0.5, 0.5, 0.6, 1.0 } else .{ 0.2, 0.2, 0.25, 1.0 };
            try self.quad(self.cx, self.cy, w, h, bg);
            const ocx = self.cx; const ocy = self.cy; self.cx += scale * 1.5; self.cy += scale * 2.0; try self.text(str, scale, .{ 1, 1, 1, 1 }); self.cx = ocx; self.cy = ocy + h + 8.0;
            return clicked;
        }
    };
};

// ── Graphics & Rendering ──────────────────────────────────────────
pub const gfx = struct {
    pub const Vertex = extern struct { pos: [3]f32, color: [4]f32 };
    const MeshSlot = struct { vbo: gpu.Buffer, ibo: gpu.Buffer, idx_count: u32 };
    pub const Renderer = struct {
        pub const Handle = u32;
        device: gpu.Device, window: sdl.video.Window, pipeline: gpu.GraphicsPipeline, ui_pipeline: gpu.GraphicsPipeline, ui_handle: ?Handle = null,
        depth_tex: ?gpu.Texture = null, width: u32 = 0, height: u32 = 0, meshes: std.ArrayListUnmanaged(MeshSlot) = .{}, alloc: std.mem.Allocator,
        cmd: ?gpu.CommandBuffer = null, render_pass: ?gpu.RenderPass = null, swapchain_tex: ?gpu.Texture = null, clear_color: [4]f32 = .{ 0.06, 0.07, 0.12, 1.0 },
        view: math.Mat4 = math.Mat4.identity(), proj: math.Mat4 = math.Mat4.identity(), frust: math.Frustum = undefined,

        pub fn init(device: gpu.Device, window: sdl.video.Window, alloc: std.mem.Allocator) !Renderer {
            try device.claimWindow(window);
            const sc_fmt = try device.getSwapchainTextureFormat(window);
            const depth_fmt: gpu.TextureFormat = if (device.textureSupportsFormat(.depth32_float, .two_dimensional, .{ .depth_stencil_target = true })) .depth32_float else .depth16_unorm;
            const vert_shader = try device.createShader(.{ .code = @embedFile("shaders/triangle.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex, .num_uniform_buffers = 1 }); defer device.releaseShader(vert_shader);
            const frag_shader = try device.createShader(.{ .code = @embedFile("shaders/triangle.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment }); defer device.releaseShader(frag_shader);

            var pipe_info = gpu.GraphicsPipelineCreateInfo{
                .vertex_shader = vert_shader, .fragment_shader = frag_shader,
                .vertex_input_state = .{ .vertex_buffer_descriptions = &.{.{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = .vertex }}, .vertex_attributes = &.{ .{ .location = 0, .buffer_slot = 0, .format = .f32x3, .offset = @offsetOf(Vertex, "pos") }, .{ .location = 1, .buffer_slot = 0, .format = .f32x4, .offset = @offsetOf(Vertex, "color") } } },
                .rasterizer_state = .{ .cull_mode = .back, .front_face = .counter_clockwise },
                .depth_stencil_state = .{ .compare = .less_or_equal, .enable_depth_test = true, .enable_depth_write = true },
                .target_info = .{ .color_target_descriptions = &.{.{ .format = sc_fmt }}, .depth_stencil_format = depth_fmt },
            };
            const pipeline = try device.createGraphicsPipeline(pipe_info);
            pipe_info.depth_stencil_state.enable_depth_test = false; pipe_info.depth_stencil_state.enable_depth_write = false; pipe_info.rasterizer_state.cull_mode = .none;
            const ui_pipeline = try device.createGraphicsPipeline(pipe_info);

            return .{ .device = device, .window = window, .pipeline = pipeline, .ui_pipeline = ui_pipeline, .alloc = alloc };
        }
        pub fn deinit(self: *Renderer) void {
            self.device.waitForIdle() catch {}; for (self.meshes.items) |m| { self.device.releaseBuffer(m.vbo); self.device.releaseBuffer(m.ibo); }
            self.meshes.deinit(self.alloc); if (self.depth_tex) |t| self.device.releaseTexture(t);
            self.device.releaseGraphicsPipeline(self.pipeline); self.device.releaseGraphicsPipeline(self.ui_pipeline);
            self.device.releaseWindow(self.window); self.device.deinit();
        }
        pub fn cameraEuler(self: *Renderer, pos: math.Vec3, yaw: f32, pitch: f32, eye_height: f32, fovy: f32, aspect: f32, near: f32, far: f32) void {
            self.view = math.Mat4.viewMatrix(pos, yaw, pitch, eye_height); self.proj = math.perspective(fovy, aspect, near, far);
            const eye = pos.add(math.Vec3.new(0, eye_height, 0)); const fwd = math.Vec3.new(@sin(yaw)*@cos(pitch), -@sin(pitch), -@cos(yaw)*@cos(pitch)).normalize();
            const rt = math.Vec3.new(@cos(yaw), 0, @sin(yaw)); const up = rt.cross(fwd);
            self.frust = math.Frustum.fromCamera(eye, fwd, rt, up, fovy * std.math.pi / 180.0, aspect, near, far);
        }
        pub fn beginFrame(self: *Renderer) !bool {
            self.cmd = try self.device.acquireCommandBuffer();
            const tex, const w, const h = try self.cmd.?.waitAndAcquireSwapchainTexture(self.window); self.swapchain_tex = tex orelse return false;
            if (w != self.width or h != self.height or self.depth_tex == null) {
                self.width = w; self.height = h; if (self.depth_tex) |dt| self.device.releaseTexture(dt);
                self.depth_tex = try self.device.createTexture(.{ .format = if (self.device.textureSupportsFormat(.depth32_float, .two_dimensional, .{ .depth_stencil_target = true })) .depth32_float else .depth16_unorm, .usage = .{ .depth_stencil_target = true }, .width = w, .height = h, .layer_count_or_depth = 1, .num_levels = 1 });
            }
            self.render_pass = self.cmd.?.beginRenderPass(&.{.{ .texture = self.swapchain_tex.?, .clear_color = .{ .r = self.clear_color[0], .g = self.clear_color[1], .b = self.clear_color[2], .a = self.clear_color[3] }, .load = .clear, .store = .store }}, .{ .texture = self.depth_tex.?, .clear_depth = 1.0, .load = .clear, .store = .do_not_care, .stencil_load = .do_not_care, .stencil_store = .do_not_care, .cycle = false, .clear_stencil = 0 });
            self.render_pass.?.bindGraphicsPipeline(self.pipeline); return true;
        }
        pub fn endFrame(self: *Renderer) !void { if (self.render_pass) |rp| rp.end(); self.render_pass = null; if (self.cmd) |cmd| try cmd.submit(); self.cmd = null; }
        fn uploadBuffer(device: gpu.Device, data: []const u8, usage: gpu.BufferUsageFlags) !gpu.Buffer {
            const buf = try device.createBuffer(.{ .usage = usage, .size = @intCast(data.len) }); const tbuf = try device.createTransferBuffer(.{ .usage = .upload, .size = @intCast(data.len) });
            const ptr = try device.mapTransferBuffer(tbuf, false); @memcpy(ptr[0..data.len], data); device.unmapTransferBuffer(tbuf);
            const cmd = try device.acquireCommandBuffer(); const copy = cmd.beginCopyPass(); copy.uploadToBuffer(.{ .transfer_buffer = tbuf, .offset = 0 }, .{ .buffer = buf, .offset = 0, .size = @intCast(data.len) }, false); copy.end();
            try cmd.submit(); try device.waitForIdle(); device.releaseTransferBuffer(tbuf); return buf;
        }
        pub fn upload(self: *Renderer, vert_bytes: []const u8, v_size: u32, idx_bytes: []const u8, i_count: u32) !Handle {
            _ = v_size; const h: Handle = @intCast(self.meshes.items.len); try self.meshes.append(self.alloc, .{ .vbo = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true }), .ibo = try uploadBuffer(self.device, idx_bytes, .{ .index = true }), .idx_count = i_count }); return h;
        }
        pub fn updateMesh(self: *Renderer, handle: Handle, vert_bytes: []const u8, idx_bytes: []const u8, i_count: u32) !void {
            if (handle >= self.meshes.items.len) return; const new_vbo = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true }); const new_ibo = try uploadBuffer(self.device, idx_bytes, .{ .index = true });
            self.device.releaseBuffer(self.meshes.items[handle].vbo); self.device.releaseBuffer(self.meshes.items[handle].ibo); self.meshes.items[handle] = .{ .vbo = new_vbo, .ibo = new_ibo, .idx_count = i_count };
        }
        pub fn drawDirect(self: *Renderer, handle: Handle, model: math.Mat4, color: [4]f32) void {
            _ = color; if (handle >= self.meshes.items.len) return; const m = self.meshes.items[handle]; if (m.idx_count == 0) return; const rp = self.render_pass orelse return;
            rp.bindVertexBuffers(0, &.{.{ .buffer = m.vbo, .offset = 0 }}); rp.bindIndexBuffer(.{ .buffer = m.ibo, .offset = 0 }, .indices_32bit);
            const mvp = self.proj.mul(self.view).mul(model); self.cmd.?.pushVertexUniformData(0, std.mem.asBytes(&mvp)); rp.drawIndexedPrimitives(m.idx_count, 1, 0, 0, 0);
        }
        pub fn drawUI(self: *Renderer, handle: Handle, win_w: f32, win_h: f32) void {
            if (handle >= self.meshes.items.len) return; const m = self.meshes.items[handle]; if (m.idx_count == 0) return; const rp = self.render_pass orelse return;
            rp.bindGraphicsPipeline(self.ui_pipeline); rp.bindVertexBuffers(0, &.{.{ .buffer = m.vbo, .offset = 0 }}); rp.bindIndexBuffer(.{ .buffer = m.ibo, .offset = 0 }, .indices_32bit);
            const ortho_mvp = math.ortho(0, win_w, win_h, 0, -1, 1); self.cmd.?.pushVertexUniformData(0, std.mem.asBytes(&ortho_mvp)); rp.drawIndexedPrimitives(m.idx_count, 1, 0, 0, 0);
            rp.bindGraphicsPipeline(self.pipeline);
        }
    };
};

// ── BSP Editor Core ───────────────────────────────────────────────
pub const Bsp = struct {
    const Self = @This(); const Vec3 = math.Vec3; const Plane = math.Plane;
    pub const empty_leaf: u32 = 0xFFFF_FFFE; pub const solid_leaf: u32 = 0xFFFF_FFFF;
    pub inline fn isLeaf(i: u32) bool { return i >= empty_leaf; }
    pub inline fn isSolid(i: u32) bool { return i == solid_leaf; }
    pub inline fn isEmpty(i: u32) bool { return i == empty_leaf; }
    pub const SplitMode = enum { solid, empty }; pub const Node = struct { plane: u32, front: u32, back: u32 };
    pub const PickResult = struct { node: u32, t: f32, pos: Vec3, normal: Vec3 }; pub const ParentInfo = struct { idx: u32, is_front: bool };
    pub const EditOp = union(enum) { split: struct { parent: u32, is_front: bool, old_leaf: u32 }, translate: struct { plane_idx: u32, old_dist: f32 }, rotate: struct { plane_idx: u32, old_normal: Vec3, old_dist: f32 }, swap: struct { node: u32 }, toggle: struct { parent: u32, is_front: bool }, delete: struct { parent: u32, is_front: bool, node_idx: u32 } };

    nodes: std.MultiArrayList(Node) = .{}, planes: std.ArrayListUnmanaged(Plane) = .{}, alloc: std.mem.Allocator,
    render_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{}, render_indices: std.ArrayListUnmanaged(u32) = .{}, face_nodes: std.ArrayListUnmanaged(u32) = .{}, mesh_dirty: bool = true,
    debug_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{}, debug_indices: std.ArrayListUnmanaged(u32) = .{}, debug_dirty: bool = true,
    selected_node: ?u32 = null, undo_stack: std.ArrayListUnmanaged(EditOp) = .{},

    pub fn init(alloc: std.mem.Allocator) Self { return .{ .alloc = alloc }; }
    pub fn deinit(self: *Self) void { self.nodes.deinit(self.alloc); self.planes.deinit(self.alloc); self.render_verts.deinit(self.alloc); self.render_indices.deinit(self.alloc); self.face_nodes.deinit(self.alloc); self.debug_verts.deinit(self.alloc); self.debug_indices.deinit(self.alloc); self.undo_stack.deinit(self.alloc); }
    pub fn markDirty(self: *Self) void { self.mesh_dirty = true; self.debug_dirty = true; }
    fn addPlane(self: *Self, p: Plane) !u32 { const idx: u32 = @intCast(self.planes.items.len); try self.planes.append(self.alloc, p); return idx; }
    fn addNode(self: *Self, plane: u32, front: u32, back: u32) !u32 { const idx: u32 = @intCast(self.nodes.len); try self.nodes.append(self.alloc, .{ .plane = plane, .front = front, .back = back }); return idx; }
    pub fn initGroundPlane(self: *Self, height: f32) !void { const pi = try self.addPlane(.{ .normal = Vec3.new(0, 1, 0), .dist = -height }); _ = try self.addNode(pi, empty_leaf, solid_leaf); self.markDirty(); }

    pub fn editorSplit(self: *Self, point: Vec3, normal: Vec3, mode: SplitMode) !bool {
        if (self.nodes.len == 0) return false; const n = if (mode == .empty) normal.neg() else normal; const pi = try self.addPlane(.{ .normal = n, .dist = -n.dot(point) });
        const info = try self.splitLeaf(0, point, pi, mode) orelse return false; try self.undo_stack.append(self.alloc, .{ .split = .{ .parent = info.parent, .is_front = info.is_front, .old_leaf = info.old_leaf } });
        self.markDirty(); return true;
    }
    fn splitLeaf(self: *Self, node_idx: u32, point: Vec3, plane_idx: u32, mode: SplitMode) !?struct { parent: u32, is_front: bool, old_leaf: u32 } {
        if (isSolid(node_idx) or isEmpty(node_idx)) return null; const slice = self.nodes.slice(); const plane = self.planes.items[slice.items(.plane)[node_idx]]; const is_front = plane.distToPoint(point) >= 0; const child_val = if (is_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];
        if (isLeaf(child_val)) {
            if (mode == .solid and !isEmpty(child_val)) return null; if (mode == .empty and !isSolid(child_val)) return null;
            const nn = try self.addNode(plane_idx, if (mode == .solid) solid_leaf else empty_leaf, if (mode == .solid) empty_leaf else solid_leaf);
            if (is_front) slice.items(.front)[node_idx] = nn else slice.items(.back)[node_idx] = nn; return .{ .parent = node_idx, .is_front = is_front, .old_leaf = child_val };
        } return self.splitLeaf(child_val, point, plane_idx, mode);
    }
    pub fn translatePlane(self: *Self, node_idx: u32, delta: f32) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return; const pi = self.nodes.slice().items(.plane)[node_idx];
        if (!(if (self.undo_stack.items.len > 0) switch (self.undo_stack.items[self.undo_stack.items.len - 1]) { .translate => |t| t.plane_idx == pi, else => false } else false)) try self.undo_stack.append(self.alloc, .{ .translate = .{ .plane_idx = pi, .old_dist = self.planes.items[pi].dist } });
        self.planes.items[pi].dist -= delta; self.markDirty();
    }
    pub fn rotatePlane(self: *Self, node_idx: u32, new_normal: Vec3) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return; const pi = self.nodes.slice().items(.plane)[node_idx]; const old = self.planes.items[pi]; const ref_point = old.normal.scale(-old.dist);
        if (!(if (self.undo_stack.items.len > 0) switch (self.undo_stack.items[self.undo_stack.items.len - 1]) { .rotate => |r| r.plane_idx == pi, else => false } else false)) try self.undo_stack.append(self.alloc, .{ .rotate = .{ .plane_idx = pi, .old_normal = old.normal, .old_dist = old.dist } });
        self.planes.items[pi] = .{ .normal = new_normal, .dist = -new_normal.dot(ref_point) }; self.markDirty();
    }
    pub fn deleteNode(self: *Self, target: u32, promote_front: bool) !bool {
        if (target == 0 or isLeaf(target) or target >= self.nodes.len) return false; const parent = self.findParent(target) orelse return false; const slice = self.nodes.slice(); const promoted = if (promote_front) slice.items(.front)[target] else slice.items(.back)[target];
        try self.undo_stack.append(self.alloc, .{ .delete = .{ .parent = parent.idx, .is_front = parent.is_front, .node_idx = target } });
        if (parent.is_front) slice.items(.front)[parent.idx] = promoted else slice.items(.back)[parent.idx] = promoted; if (self.selected_node) |sel| if (sel == target) { self.selected_node = null; }; self.markDirty(); return true;
    }
    pub fn swapChildren(self: *Self, node_idx: u32) !void { if (isLeaf(node_idx) or node_idx >= self.nodes.len) return; try self.undo_stack.append(self.alloc, .{ .swap = .{ .node = node_idx } }); const slice = self.nodes.slice(); const tmp = slice.items(.front)[node_idx]; slice.items(.front)[node_idx] = slice.items(.back)[node_idx]; slice.items(.back)[node_idx] = tmp; self.markDirty(); }
    pub fn toggleLeaf(self: *Self, node_idx: u32, toggle_front: bool) !bool {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return false; const slice = self.nodes.slice(); const child = if (toggle_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx]; if (!isLeaf(child)) return false;
        try self.undo_stack.append(self.alloc, .{ .toggle = .{ .parent = node_idx, .is_front = toggle_front } });
        if (toggle_front) slice.items(.front)[node_idx] = if (isSolid(child)) empty_leaf else solid_leaf else slice.items(.back)[node_idx] = if (isSolid(child)) empty_leaf else solid_leaf; self.markDirty(); return true;
    }
    pub fn undo(self: *Self) bool {
        if (self.undo_stack.items.len == 0) return false; const op = self.undo_stack.pop() orelse return false;
        switch (op) {
            .split => |s| { const s_ = self.nodes.slice(); if (s.is_front) s_.items(.front)[s.parent] = s.old_leaf else s_.items(.back)[s.parent] = s.old_leaf; },
            .translate => |t| self.planes.items[t.plane_idx].dist = t.old_dist,
            .rotate => |r| { self.planes.items[r.plane_idx].normal = r.old_normal; self.planes.items[r.plane_idx].dist = r.old_dist; },
            .swap => |s| { const s_ = self.nodes.slice(); const tmp = s_.items(.front)[s.node]; s_.items(.front)[s.node] = s_.items(.back)[s.node]; s_.items(.back)[s.node] = tmp; },
            .toggle => |t| { const s_ = self.nodes.slice(); const c = if (t.is_front) &s_.items(.front)[t.parent] else &s_.items(.back)[t.parent]; c.* = if (isSolid(c.*)) empty_leaf else solid_leaf; },
            .delete => |d| { const s_ = self.nodes.slice(); if (d.is_front) s_.items(.front)[d.parent] = d.node_idx else s_.items(.back)[d.parent] = d.node_idx; },
        } self.selected_node = null; self.markDirty(); return true;
    }
    pub fn findParent(self: *const Self, target: u32) ?ParentInfo { if (target == 0 or self.nodes.len == 0) return null; return self.findParentWalk(0, target); }
    fn findParentWalk(self: *const Self, current: u32, target: u32) ?ParentInfo {
        if (isLeaf(current)) return null; const s = self.nodes.slice(); if (s.items(.front)[current] == target) return .{ .idx = current, .is_front = true }; if (s.items(.back)[current] == target) return .{ .idx = current, .is_front = false };
        return self.findParentWalk(s.items(.front)[current], target) orelse self.findParentWalk(s.items(.back)[current], target);
    }
    pub fn rayPick(self: *const Self, origin: Vec3, dir: Vec3) ?PickResult {
        if (self.render_indices.items.len < 3 or self.face_nodes.items.len == 0) return null; var best_t: f32 = std.math.inf(f32); var best_node: u32 = 0; var best_normal = Vec3.zero(); const tris = self.render_indices.items.len / 3;
        for (0..tris) |ti| {
            const v0 = posVec(self.render_verts.items[self.render_indices.items[ti * 3]].pos); const v1 = posVec(self.render_verts.items[self.render_indices.items[ti * 3 + 1]].pos); const v2 = posVec(self.render_verts.items[self.render_indices.items[ti * 3 + 2]].pos);
            const e1 = v1.sub(v0); const e2 = v2.sub(v0); const h = dir.cross(e2); const a = e1.dot(h); if (@abs(a) > 1e-7) {
                const f = 1.0 / a; const s = origin.sub(v0); const u = f * s.dot(h); if (u >= 0 and u <= 1) {
                    const q = s.cross(e1); const v = f * dir.dot(q); if (v >= 0 and u + v <= 1) {
                        const t = f * e2.dot(q); if (t > 1e-5 and t < best_t) { best_t = t; best_node = self.face_nodes.items[ti]; best_normal = v1.sub(v0).cross(v2.sub(v0)).normalize(); }
                    }
                }
            }
        } return if (best_t < std.math.inf(f32)) .{ .node = best_node, .t = best_t, .pos = origin.add(dir.scale(best_t)), .normal = best_normal } else null;
    }
    inline fn posVec(p: [3]f32) Vec3 { return Vec3.new(p[0], p[1], p[2]); }
    pub fn trace(self: *const Self, start: Vec3, dir: Vec3, max_d: f32, radius: f32) ?phys.Hit {
        if (self.nodes.len == 0) return null; const end = start.add(dir.scale(max_d)); var st = struct { fraction: f32 = 1.0, normal: Vec3 = Vec3.zero(), hit: bool = false }{}; _ = self.traceRec(0, 0, 1, start, end, radius, &st);
        return if (st.hit and st.fraction < 1.0) .{ .normal = st.normal, .dist = st.fraction * max_d } else null;
    }
    fn traceRec(self: *const Self, idx: u32, p1f: f32, p2f: f32, p1: Vec3, p2: Vec3, rad: f32, st: anytype) bool {
        if (st.fraction <= p1f) return true; if (isEmpty(idx)) return true; if (isSolid(idx)) return true;
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[idx]]; const fc = s.items(.front)[idx]; const bc = s.items(.back)[idx]; const t1 = plane.distToPoint(p1); const t2 = plane.distToPoint(p2);
        if (t1 >= rad and t2 >= rad) return self.traceRec(fc, p1f, p2f, p1, p2, rad, st); if (t1 < -rad and t2 < -rad) return self.traceRec(bc, p1f, p2f, p1, p2, rad, st);
        const ff = t1 >= t2; const near = if (ff) fc else bc; const far = if (ff) bc else fc; const d = t1 - t2; var frac: f32 = 0;
        if (@abs(d) > std.math.floatEpsAt(f32, @max(@abs(t1), @abs(t2)))) frac = std.math.clamp(if (ff) (t1 - rad - 0.001) / d else (t1 + rad + 0.001) / d, 0, 1);
        const midf = p1f + (p2f - p1f) * frac; const mid = Vec3.lerp(p1, p2, frac);
        if (!self.traceRec(near, p1f, midf, p1, mid, rad, st)) return false;
        if (self.sphereInSolid(far, mid, rad)) { if (midf < st.fraction) { st.fraction = @max(0, midf); st.normal = if (ff) plane.normal else plane.normal.neg(); st.hit = true; } return false; }
        return self.traceRec(far, midf, p2f, mid, p2, rad, st);
    }
    fn sphereInSolid(self: *const Self, idx: u32, p: Vec3, rad: f32) bool {
        if (isSolid(idx)) return true; if (isEmpty(idx)) return false;
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[idx]]; const d = plane.distToPoint(p);
        if (d > rad) return self.sphereInSolid(s.items(.front)[idx], p, rad); if (d < -rad) return self.sphereInSolid(s.items(.back)[idx], p, rad); return self.sphereInSolid(s.items(.front)[idx], p, rad) or self.sphereInSolid(s.items(.back)[idx], p, rad);
    }
    const ClipInfo = struct { plane: u32, flip: bool };
    pub fn rebuildMesh(self: *Self) !void { self.render_verts.clearRetainingCapacity(); self.render_indices.clearRetainingCapacity(); self.face_nodes.clearRetainingCapacity(); if (self.nodes.len == 0) return; var stack: [64]ClipInfo = undefined; try self.meshNode(0, &stack, 0); self.mesh_dirty = false; }
    fn meshNode(self: *Self, idx: u32, stack: *[64]ClipInfo, depth: usize) !void {
        if (isLeaf(idx)) return; const s = self.nodes.slice(); const pi = s.items(.plane)[idx]; const plane = self.planes.items[pi]; var poly: [48]Vec3 = undefined; var count: usize = 4;
        const n = plane.normal; const ref = if (@abs(n.data[1]) < 0.9) Vec3.new(0, 1, 0) else Vec3.new(1, 0, 0); const t1 = n.cross(ref).normalize(); const t2 = n.cross(t1).normalize(); const c = n.scale(-plane.dist);
        poly[0] = c.sub(t1.scale(2000)).sub(t2.scale(2000)); poly[1] = c.add(t1.scale(2000)).sub(t2.scale(2000)); poly[2] = c.add(t1.scale(2000)).add(t2.scale(2000)); poly[3] = c.sub(t1.scale(2000)).add(t2.scale(2000));
        for (stack[0..depth]) |a| { var cp = self.planes.items[a.plane]; if (a.flip) { cp.normal = cp.normal.neg(); cp.dist = -cp.dist; } var out: [48]Vec3 = undefined; count = clipConvex(poly[0..count], cp, &out); if (count < 3) break; @memcpy(poly[0..count], out[0..count]); }
        if (count >= 3) try self.filterFront(poly[0..count], s.items(.front)[idx], s.items(.back)[idx], plane, idx);
        if (depth < 64) { stack[depth] = .{ .plane = pi, .flip = false }; try self.meshNode(s.items(.front)[idx], stack, depth + 1); stack[depth] = .{ .plane = pi, .flip = true }; try self.meshNode(s.items(.back)[idx], stack, depth + 1); }
    }
    fn filterFront(self: *Self, verts: []const Vec3, fn_id: u32, bn_id: u32, split_plane: Plane, src: u32) !void {
        if (isSolid(fn_id)) return self.filterBack(verts, bn_id, split_plane, true, src); if (isEmpty(fn_id)) return self.filterBack(verts, bn_id, split_plane, false, src);
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[fn_id]]; var fv: [48]Vec3 = undefined; var bv: [48]Vec3 = undefined; const res = splitConvex(verts, plane, &fv, &bv);
        if (res.f >= 3) try self.filterFront(fv[0..res.f], s.items(.front)[fn_id], bn_id, split_plane, src); if (res.b >= 3) try self.filterFront(bv[0..res.b], s.items(.back)[fn_id], bn_id, split_plane, src);
    }
    fn filterBack(self: *Self, verts: []const Vec3, bn_id: u32, split_plane: Plane, fs_solid: bool, src: u32) !void {
        if (isSolid(bn_id)) { if (!fs_solid) try self.pushFace(verts, split_plane, false, src); return; } if (isEmpty(bn_id)) { if (fs_solid) try self.pushFace(verts, split_plane, true, src); return; }
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[bn_id]]; var fv: [48]Vec3 = undefined; var bv: [48]Vec3 = undefined; const res = splitConvex(verts, plane, &fv, &bv);
        if (res.f >= 3) try self.filterBack(fv[0..res.f], s.items(.front)[bn_id], split_plane, fs_solid, src); if (res.b >= 3) try self.filterBack(bv[0..res.b], s.items(.back)[bn_id], split_plane, fs_solid, src);
    }
    fn pushFace(self: *Self, verts: []const Vec3, plane: Plane, flip: bool, src: u32) !void {
        if (verts.len < 3) return; const face_n = if (flip) plane.normal.neg() else plane.normal; const is_sel = self.selected_node != null and self.selected_node.? == src;
        const min_d: f32 = if (is_sel) 0.3 else 0.15;
        const d = @max(min_d, face_n.dot(Vec3.new(0.4, 0.7, -0.5).normalize())); 
        const col = if (is_sel) [4]f32{ d*0.95, d*0.35, d*0.1, 1.0 } else [4]f32{ d*0.55, d*0.55, d*0.6, 1.0 }; const base: u32 = @intCast(self.render_verts.items.len);
        if (flip) { var i: usize = verts.len; while (i > 0) { i -= 1; try self.render_verts.append(self.alloc, .{ .pos = .{ verts[i].data[0], verts[i].data[1], verts[i].data[2] }, .color = col }); } } else { for (verts) |v| try self.render_verts.append(self.alloc, .{ .pos = .{ v.data[0], v.data[1], v.data[2] }, .color = col }); }
        for (2..verts.len) |i| { try self.render_indices.appendSlice(self.alloc, &.{ base, base + @as(u32, @intCast(i - 1)), base + @as(u32, @intCast(i)) }); try self.face_nodes.append(self.alloc, src); }
    }
    pub fn rebuildDebugMesh(self: *Self) !void { self.debug_verts.clearRetainingCapacity(); self.debug_indices.clearRetainingCapacity(); if (self.nodes.len == 0) return; var stack: [64]ClipInfo = undefined; try self.debugNode(0, &stack, 0); self.debug_dirty = false; }
    fn debugNode(self: *Self, idx: u32, stack: *[64]ClipInfo, depth: usize) !void {
        if (isLeaf(idx)) return; const s = self.nodes.slice(); const pi = s.items(.plane)[idx]; const plane = self.planes.items[pi]; var poly: [48]Vec3 = undefined; var count: usize = 4;
        const n = plane.normal; const ref = if (@abs(n.data[1]) < 0.9) Vec3.new(0, 1, 0) else Vec3.new(1, 0, 0); const t1 = n.cross(ref).normalize(); const t2 = n.cross(t1).normalize(); const c = n.scale(-plane.dist);
        poly[0] = c.sub(t1.scale(2000)).sub(t2.scale(2000)); poly[1] = c.add(t1.scale(2000)).sub(t2.scale(2000)); poly[2] = c.add(t1.scale(2000)).add(t2.scale(2000)); poly[3] = c.sub(t1.scale(2000)).add(t2.scale(2000));
        for (stack[0..depth]) |a| { var cp = self.planes.items[a.plane]; if (a.flip) { cp.normal = cp.normal.neg(); cp.dist = -cp.dist; } var out: [48]Vec3 = undefined; count = clipConvex(poly[0..count], cp, &out); if (count < 3) break; @memcpy(poly[0..count], out[0..count]); }
        if (count >= 3) {
            const lut = [_][4]f32{ .{ 0.8, 0.15, 0.1, 1.0 }, .{ 0.85, 0.5, 0.1, 1.0 }, .{ 0.8, 0.8, 0.15, 1.0 }, .{ 0.2, 0.75, 0.2, 1.0 }, .{ 0.15, 0.7, 0.75, 1.0 }, .{ 0.2, 0.3, 0.85, 1.0 }, .{ 0.6, 0.2, 0.8, 1.0 }, .{ 0.8, 0.2, 0.7, 1.0 } };
            const col = if (self.selected_node != null and self.selected_node.? == idx) [4]f32{ 1.0, 0.15, 0.05, 1.0 } else lut[depth % lut.len]; const off = plane.normal.scale(0.05);
            for ([2]Vec3{ off, off.neg() }) |o| {
                if (count < 3) continue; const base: u32 = @intCast(self.debug_verts.items.len); for (poly[0..count]) |v| { const p = v.add(o); try self.debug_verts.append(self.alloc, .{ .pos = .{ p.data[0], p.data[1], p.data[2] }, .color = col }); }
                for (2..count) |i| { const ii: u32 = @intCast(i); try self.debug_indices.appendSlice(self.alloc, &.{ base, base + ii - 1, base + ii, base, base + ii, base + ii - 1 }); }
            }
        }
        if (depth < 64) { stack[depth] = .{ .plane = pi, .flip = false }; try self.debugNode(s.items(.front)[idx], stack, depth + 1); stack[depth] = .{ .plane = pi, .flip = true }; try self.debugNode(s.items(.back)[idx], stack, depth + 1); }
    }
    fn splitConvex(verts: []const Vec3, plane: Plane, fv: *[48]Vec3, bv: *[48]Vec3) struct { f: usize, b: usize } {
        if (verts.len < 3) return .{ .f = 0, .b = 0 }; var f: usize = 0; var b: usize = 0; var dists: [48]f32 = undefined; var has_front = false; var has_back = false;
        for (verts, 0..) |v, i| { dists[i] = plane.distToPoint(v); if (dists[i] > 1e-4) has_front = true; if (dists[i] < -1e-4) has_back = true; }
        if (!has_back) { @memcpy(fv[0..verts.len], verts); return .{ .f = verts.len, .b = 0 }; } if (!has_front) { @memcpy(bv[0..verts.len], verts); return .{ .f = 0, .b = verts.len }; }
        for (0..verts.len) |i| {
            const p1 = verts[i]; const p2 = verts[(i + 1) % verts.len]; const d1 = dists[i]; const d2 = dists[(i + 1) % verts.len];
            if (d1 >= -1e-4 and f < 48) { fv[f] = p1; f += 1; } if (d1 <= 1e-4 and b < 48) { bv[b] = p1; b += 1; }
            if ((d1 > 1e-4 and d2 < -1e-4) or (d1 < -1e-4 and d2 > 1e-4)) { const mid = Vec3.lerp(p1, p2, d1 / (d1 - d2)); if (f < 48) { fv[f] = mid; f += 1; } if (b < 48) { bv[b] = mid; b += 1; } }
        } return .{ .f = if (f >= 3) f else 0, .b = if (b >= 3) b else 0 };
    }
    fn clipConvex(verts: []const Vec3, plane: Plane, out: *[48]Vec3) usize {
        if (verts.len < 3) return 0; var n: usize = 0;
        for (0..verts.len) |i| {
            const a = verts[i]; const b = verts[(i + 1) % verts.len]; const da = plane.distToPoint(a); const db = plane.distToPoint(b);
            if (da >= -1e-4) { if (n < 48) { out[n] = a; n += 1; } if (db < -1e-4 and n < 48) { out[n] = Vec3.lerp(a, b, da / (da - db)); n += 1; } } else if (db >= -1e-4 and n < 48) { out[n] = Vec3.lerp(a, b, da / (da - db)); n += 1; }
        } return if (n >= 3) n else 0;
    }
};

// ── Input Management ──────────────────────────────────────────────
pub const Input = struct {
    keys: []const bool = &[_]bool{},
    keys_just_pressed: [512]bool = [_]bool{false} ** 512,
    shift: bool = false,
    mx: f32 = 0, my: f32 = 0, mdx: f32 = 0, mdy: f32 = 0,
    mdown_left: bool = false, mdown_right: bool = false,
    m_just_pressed_left: bool = false, m_just_pressed_right: bool = false,
    m_just_released_left: bool = false, m_just_released_right: bool = false,
    scroll_y: f32 = 0,
    mouse_locked: bool = false,
    quit: bool = false,

    pub fn update(self: *Input, win: sdl.video.Window) void {
        self.mdx = 0; self.mdy = 0; self.scroll_y = 0;
        @memset(&self.keys_just_pressed, false);
        self.m_just_pressed_left = false; self.m_just_pressed_right = false;
        self.m_just_released_left = false; self.m_just_released_right = false;

        self.keys = sdl.keyboard.getState();
        self.shift = self.keys[@intFromEnum(sdl.Scancode.left_shift)];

        const mstate = sdl.mouse.getState();
        self.mdown_left = mstate[0].left; 
        self.mdown_right = mstate[0].right;
        self.mx = mstate[1]; 
        self.my = mstate[2];

        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => self.quit = true,
                .key_down => |k| if (k.scancode) |sc| { 
                    self.keys_just_pressed[@intFromEnum(sc)] = true; 
                    if (sc == .escape and self.mouse_locked) self.setLock(win, false);
                },
                .mouse_button_down => |m| {
                    if (m.button == .left) self.m_just_pressed_left = true;
                    if (m.button == .right) self.m_just_pressed_right = true;
                },
                .mouse_button_up => |m| {
                    if (m.button == .left) self.m_just_released_left = true;
                    if (m.button == .right) self.m_just_released_right = true;
                },
                .mouse_motion => |m| if (self.mouse_locked) { self.mdx += m.x_rel; self.mdy += m.y_rel; },
                .mouse_wheel => |w| self.scroll_y = w.y,
                else => {},
            }
        }
    }

    pub fn setLock(self: *Input, win: sdl.video.Window, lock: bool) void {
        self.mouse_locked = lock;
        if (lock) {
            sdl.mouse.hide() catch {};
            sdl.mouse.setWindowRelativeMode(win, true) catch {};
        } else {
            sdl.mouse.show() catch {};
            sdl.mouse.setWindowRelativeMode(win, false) catch {};
        }
    }

    pub fn pressed(self: *const Input, sc: sdl.Scancode) bool { return self.keys_just_pressed[@intFromEnum(sc)]; }
    pub fn held(self: *const Input, sc: sdl.Scancode) bool { return self.keys[@intFromEnum(sc)]; }
};

// ── Application Core ──────────────────────────────────────────────
pub const App = struct {
    alloc: std.mem.Allocator, win: sdl.video.Window, device: gpu.Device, renderer: gfx.Renderer,
    bsp: Bsp, gui: ui.State, input: Input, player: phys.Body(.{}),
    
    mesh_h: gfx.Renderer.Handle = 0, debug_h: ?gfx.Renderer.Handle = null,
    
    mode: EditorMode = .off, running: bool = true, placing: bool = false, show_dbg: bool = false, last_f: bool = true,
    split_mode: Bsp.SplitMode = .solid, anchor: math.Vec3 = math.Vec3.zero(), grid: f32 = 1.0, a_step: f32 = std.math.pi / 12.0,

    const EditorMode = enum { off, select, place, adjust };

    pub fn init(alloc: std.mem.Allocator) !App {
        try sdl.init(.{ .video = true, .events = true });
        const win = try sdl.video.Window.init("Monolithic BSP Engine", 1280, 720, .{});
        const device = try gpu.Device.init(.{ .spirv = true }, true, null);

        var bsp = Bsp.init(alloc);
        try bsp.initGroundPlane(0); try bsp.rebuildMesh();

        var renderer = try gfx.Renderer.init(device, win, alloc);
        const mh = try renderer.upload(std.mem.sliceAsBytes(bsp.render_verts.items), @sizeOf(gfx.Vertex), std.mem.sliceAsBytes(bsp.render_indices.items), @intCast(bsp.render_indices.items.len));

        return .{
            .alloc = alloc, .win = win, .device = device, .renderer = renderer, .bsp = bsp,
            .gui = ui.State.init(alloc), .input = Input{}, .player = .{ .pos = math.Vec3.new(0, 1.5, 0) },
            .mesh_h = mh,
        };
    }

    pub fn deinit(self: *App) void {
        self.gui.deinit(); self.renderer.deinit(); self.bsp.deinit();
        self.win.deinit(); sdl.quit(.{ .video = true, .events = true });
    }

    fn handleEditorInput(self: *App) void {
        const in = &self.input;
        if (!in.mouse_locked) return;
        
        if (in.pressed(.e)) { if (self.mode == .off) self.mode = .select else { self.mode = .off; self.placing = false; self.bsp.selected_node = null; self.bsp.markDirty(); } }
        if (in.pressed(.tab) and self.mode != .off) { self.placing = false; self.mode = switch (self.mode) { .off => .select, .select => .place, .place => .adjust, .adjust => .select }; }
        if (in.pressed(.z) and self.mode != .off) _ = self.bsp.undo();
        if (in.pressed(.delete) and self.bsp.selected_node != null) _ = self.bsp.deleteNode(self.bsp.selected_node.?, !in.shift) catch false;
        if (in.pressed(.f) and self.bsp.selected_node != null) self.bsp.swapChildren(self.bsp.selected_node.?) catch {};
        if (in.pressed(.t) and self.bsp.selected_node != null) _ = self.bsp.toggleLeaf(self.bsp.selected_node.?, !in.shift) catch false;
        if (in.pressed(.r) and self.mode == .adjust and self.bsp.selected_node != null) self.bsp.rotatePlane(self.bsp.selected_node.?, self.player.lookDir()) catch {};
        if (in.pressed(.g)) { self.show_dbg = !self.show_dbg; self.bsp.debug_dirty = true; }
        
        if ((self.mode == .select or self.mode == .adjust) and self.bsp.selected_node != null) {
            const sel = self.bsp.selected_node.?;
            if (in.pressed(.up)) if (self.bsp.findParent(sel)) |p| { self.bsp.selected_node = p.idx; self.last_f = p.is_front; self.bsp.markDirty(); };
            if (in.pressed(.down)) { const c = if (self.last_f) self.bsp.nodes.slice().items(.front)[sel] else self.bsp.nodes.slice().items(.back)[sel]; if (!Bsp.isLeaf(c)) { self.bsp.selected_node = c; self.bsp.markDirty(); } }
            if (in.pressed(.left)) { const fc = self.bsp.nodes.slice().items(.front)[sel]; if (!Bsp.isLeaf(fc)) { self.bsp.selected_node = fc; self.last_f = true; self.bsp.markDirty(); } }
            if (in.pressed(.right)) { const bc = self.bsp.nodes.slice().items(.back)[sel]; if (!Bsp.isLeaf(bc)) { self.bsp.selected_node = bc; self.last_f = false; self.bsp.markDirty(); } }
        }
        
        if (self.mode == .select and in.m_just_pressed_left) {
            if (self.bsp.rayPick(self.player.eyePos(), self.player.lookDir())) |p| self.bsp.selected_node = p.node else self.bsp.selected_node = null; self.bsp.markDirty();
        } else if (self.mode == .place and !self.placing and (in.m_just_pressed_left or in.m_just_pressed_right)) {
            self.split_mode = if (in.m_just_pressed_left) .solid else .empty;
            if (self.bsp.trace(self.player.eyePos(), self.player.lookDir(), 200, 0)) |hit| {
                self.anchor = self.player.eyePos().add(self.player.lookDir().scale(hit.dist));
                self.anchor = if (self.split_mode == .solid) self.anchor.add(hit.normal.scale(0.01)) else self.anchor.sub(hit.normal.scale(0.01));
                if (in.shift) self.anchor = math.Vec3.new(@round(self.anchor.data[0]/self.grid)*self.grid, @round(self.anchor.data[1]/self.grid)*self.grid, @round(self.anchor.data[2]/self.grid)*self.grid);
                self.placing = true;
            }
        }
        
        if (self.mode == .place and self.placing and ((in.m_just_released_left and self.split_mode == .solid) or (in.m_just_released_right and self.split_mode == .empty))) {
            var n = self.player.lookDir();
            if (in.shift) { const ry = @round(self.player.yaw/self.a_step)*self.a_step; const rp = @round(self.player.pitch/self.a_step)*self.a_step; n = math.Vec3.new(@sin(ry) * @cos(rp), -@sin(rp), -@cos(ry) * @cos(rp)).normalize(); }
            _ = self.bsp.editorSplit(self.anchor, n, self.split_mode) catch false; self.placing = false;
        }
        
        if (self.mode != .off and in.scroll_y != 0) {
            if (self.mode == .adjust and self.bsp.selected_node != null) { self.bsp.translatePlane(self.bsp.selected_node.?, if (in.scroll_y > 0) self.grid else -self.grid) catch {}; } 
            else { const f: f32 = if (in.scroll_y > 0) 0.5 else 2.0; if (self.mode == .place and self.placing) self.a_step = std.math.clamp(self.a_step * f, std.math.pi/180.0, std.math.pi/4.0) else self.grid = std.math.clamp(self.grid * f, 0.0625, 16.0); }
        }
    }

    pub fn update(self: *App) !void {
        self.input.update(self.win);
        if (self.input.quit) self.running = false;
        
        self.handleEditorInput();
        
        if (self.input.mouse_locked) { self.player.yaw += self.input.mdx * 0.002; self.player.pitch = std.math.clamp(self.player.pitch + self.input.mdy * 0.002, -1.5, 1.5); }
        
        const world = struct { b: *const Bsp, r: f32, pub fn cast(s: @This(), o: math.Vec3, d: math.Vec3, md: f32) ?phys.Hit { return s.b.trace(o, d, md, s.r); } }{ .b = &self.bsp, .r = 0.3 };
        const w_val = if (self.input.held(.w)) @as(f32, 1) else if (self.input.held(.s)) @as(f32, -1) else 0;
        const d_val = if (self.input.held(.d)) @as(f32, 1) else if (self.input.held(.a)) @as(f32, -1) else 0;
        self.player.step(world, math.wishdir(w_val, d_val, self.player.yaw), self.input.held(.space), 1.0 / 60.0);
        
        self.gui.begin(&self.input);
        var hbuf: [128]u8 = undefined;
        try self.gui.textAt(10, 10, try std.fmt.bufPrint(&hbuf, "MODE: {s} | POS: {d:.1} {d:.1} {d:.1}", .{ @tagName(self.mode), self.player.pos.data[0], self.player.pos.data[1], self.player.pos.data[2] }), 2.0, .{ 0.9, 0.9, 0.4, 1.0 });
        if (self.input.mouse_locked) { try self.gui.crosshair(1280.0/2.0, 720.0/2.0, 8.0, .{1,1,1,0.8}); } 
        else { self.gui.cy = 40; if (try self.gui.button(1, "SPAWN CUBE", 3.0)) std.debug.print("Spawned!\n", .{}); if (try self.gui.button(2, "QUIT", 3.0)) self.running = false; }
        self.gui.end();
        
        // Handle Mouse Lock
        if (!self.input.mouse_locked and (self.input.m_just_pressed_left or self.input.m_just_pressed_right)) {
            if (self.gui.hot == 0) self.input.setLock(self.win, true);
        }
        
        if (self.bsp.mesh_dirty) {
            try self.bsp.rebuildMesh();
            if (self.bsp.render_indices.items.len > 0) try self.renderer.updateMesh(self.mesh_h, std.mem.sliceAsBytes(self.bsp.render_verts.items), std.mem.sliceAsBytes(self.bsp.render_indices.items), @intCast(self.bsp.render_indices.items.len));
        }
        if (self.show_dbg and self.bsp.debug_dirty) {
            try self.bsp.rebuildDebugMesh();
            if (self.bsp.debug_indices.items.len > 0) {
                if (self.debug_h) |h| try self.renderer.updateMesh(h, std.mem.sliceAsBytes(self.bsp.debug_verts.items), std.mem.sliceAsBytes(self.bsp.debug_indices.items), @intCast(self.bsp.debug_indices.items.len))
                else self.debug_h = try self.renderer.upload(std.mem.sliceAsBytes(self.bsp.debug_verts.items), @sizeOf(gfx.Vertex), std.mem.sliceAsBytes(self.bsp.debug_indices.items), @intCast(self.bsp.debug_indices.items.len));
            }
        }
        if (self.gui.indices.items.len > 0) {
            if (self.renderer.ui_handle) |h| try self.renderer.updateMesh(h, std.mem.sliceAsBytes(self.gui.verts.items), std.mem.sliceAsBytes(self.gui.indices.items), @intCast(self.gui.indices.items.len))
            else self.renderer.ui_handle = try self.renderer.upload(std.mem.sliceAsBytes(self.gui.verts.items), @sizeOf(gfx.Vertex), std.mem.sliceAsBytes(self.gui.indices.items), @intCast(self.gui.indices.items.len));
        }
    }

    pub fn draw(self: *App) !void {
        self.renderer.clear_color = switch (self.mode) { .off => .{ 0.06, 0.07, 0.12, 1.0 }, .select => .{ 0.09, 0.06, 0.12, 1.0 }, .place => .{ 0.06, 0.10, 0.08, 1.0 }, .adjust => .{ 0.12, 0.09, 0.06, 1.0 } };
        if (try self.renderer.beginFrame()) {
            self.renderer.cameraEuler(self.player.pos, self.player.yaw, self.player.pitch, 0.6, 90.0, 1280.0 / 720.0, 0.1, 500.0);
            self.renderer.drawDirect(self.mesh_h, math.Mat4.identity(), .{ 1, 1, 1, 1 });
            if (self.show_dbg) if (self.debug_h) |h| self.renderer.drawDirect(h, math.Mat4.identity(), .{ 1, 1, 1, 1 });
            if (self.renderer.ui_handle) |h| self.renderer.drawUI(h, 1280.0, 720.0);
            try self.renderer.endFrame();
        }
    }
};

// ── Entry Point ───────────────────────────────────────────────────
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit(); 
    
    var app = try App.init(gpa.allocator());
    defer app.deinit();

    while (app.running) {
        try app.update();
        try app.draw();
    }
}

// ── Static Deferred Data ──────────────────────────────────────────
const static_data = struct {
    pub const font: [128][5]u8 = init: {
        var f = [_][5]u8{.{ 0, 0, 0, 0, 0 }} ** 128;
        f['!'] = .{ 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 };
        f['"'] = .{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000 };
        f['#'] = .{ 0b01010, 0b11111, 0b01010, 0b11111, 0b01010 };
        f['$'] = .{ 0b01110, 0b10100, 0b01110, 0b00101, 0b01110 };
        f['%'] = .{ 0b10001, 0b00010, 0b00100, 0b01000, 0b10001 };
        f['&'] = .{ 0b01000, 0b10100, 0b01000, 0b10101, 0b01101 };
        f['\''] = .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000 };
        f['('] = .{ 0b00010, 0b00100, 0b00100, 0b00100, 0b00010 };
        f[')'] = .{ 0b01000, 0b00100, 0b00100, 0b00100, 0b01000 };
        f['*'] = .{ 0b00000, 0b10101, 0b01110, 0b10101, 0b00000 };
        f['+'] = .{ 0b00000, 0b00100, 0b01110, 0b00100, 0b00000 };
        f[','] = .{ 0b00000, 0b00000, 0b00000, 0b00100, 0b01000 };
        f['-'] = .{ 0b00000, 0b00000, 0b01110, 0b00000, 0b00000 };
        f['.'] = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 };
        f['/'] = .{ 0b00001, 0b00010, 0b00100, 0b01000, 0b10000 };
        f['0'] = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 };
        f['1'] = .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b01110 };
        f['2'] = .{ 0b01110, 0b00001, 0b01110, 0b10000, 0b01110 };
        f['3'] = .{ 0b01110, 0b00001, 0b00110, 0b00001, 0b01110 };
        f['4'] = .{ 0b10001, 0b10001, 0b01111, 0b00001, 0b00001 };
        f['5'] = .{ 0b01111, 0b10000, 0b01110, 0b00001, 0b01110 };
        f['6'] = .{ 0b01110, 0b10000, 0b11110, 0b10001, 0b01110 };
        f['7'] = .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b00100 };
        f['8'] = .{ 0b01110, 0b10001, 0b01110, 0b10001, 0b01110 };
        f['9'] = .{ 0b01110, 0b10001, 0b01111, 0b00001, 0b01110 };
        f[':'] = .{ 0b00000, 0b00100, 0b00000, 0b00100, 0b00000 };
        f[';'] = .{ 0b00000, 0b00100, 0b00000, 0b00100, 0b01000 };
        f['<'] = .{ 0b00010, 0b00100, 0b01000, 0b00100, 0b00010 };
        f['='] = .{ 0b00000, 0b01110, 0b00000, 0b01110, 0b00000 };
        f['>'] = .{ 0b01000, 0b00100, 0b00010, 0b00100, 0b01000 };
        f['?'] = .{ 0b01110, 0b10001, 0b00010, 0b00100, 0b00100 };
        f['@'] = .{ 0b01110, 0b10001, 0b10101, 0b10111, 0b01110 };
        f['A'] = .{ 0b01110, 0b10001, 0b11111, 0b10001, 0b10001 };
        f['B'] = .{ 0b11110, 0b10001, 0b11110, 0b10001, 0b11110 };
        f['C'] = .{ 0b01110, 0b10001, 0b10000, 0b10001, 0b01110 };
        f['D'] = .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 };
        f['E'] = .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b11111 };
        f['F'] = .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b10000 };
        f['G'] = .{ 0b01110, 0b10000, 0b10011, 0b10001, 0b01110 };
        f['H'] = .{ 0b10001, 0b10001, 0b11111, 0b10001, 0b10001 };
        f['I'] = .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b01110 };
        f['J'] = .{ 0b00111, 0b00010, 0b00010, 0b10010, 0b01100 };
        f['K'] = .{ 0b10001, 0b10010, 0b11100, 0b10010, 0b10001 };
        f['L'] = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 };
        f['M'] = .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001 };
        f['N'] = .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001 };
        f['O'] = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 };
        f['P'] = .{ 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 };
        f['Q'] = .{ 0b01110, 0b10001, 0b10101, 0b10010, 0b01101 };
        f['R'] = .{ 0b11110, 0b10001, 0b11110, 0b10100, 0b10011 };
        f['S'] = .{ 0b01110, 0b10000, 0b01110, 0b00001, 0b01110 };
        f['T'] = .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100 };
        f['U'] = .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 };
        f['V'] = .{ 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 };
        f['W'] = .{ 0b10001, 0b10001, 0b10101, 0b11011, 0b10001 };
        f['X'] = .{ 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 };
        f['Y'] = .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100 };
        f['Z'] = .{ 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 };
        f['['] = .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01110 };
        f['\\'] = .{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00001 };
        f[']'] = .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b01110 };
        f['^'] = .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000 };
        f['_'] = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 };
        f['`'] = .{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000 };
        f['a'] = .{ 0b00000, 0b01110, 0b10001, 0b10011, 0b01101 };
        f['b'] = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b11110 };
        f['c'] = .{ 0b00000, 0b01110, 0b10000, 0b10000, 0b01110 };
        f['d'] = .{ 0b00001, 0b00001, 0b01111, 0b10001, 0b01111 };
        f['e'] = .{ 0b00000, 0b01110, 0b11111, 0b10000, 0b01110 };
        f['f'] = .{ 0b00110, 0b01000, 0b11110, 0b01000, 0b01000 };
        f['g'] = .{ 0b00000, 0b01111, 0b10001, 0b01111, 0b00001 };
        f['h'] = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001 };
        f['i'] = .{ 0b00100, 0b00000, 0b00100, 0b00100, 0b00100 };
        f['j'] = .{ 0b00010, 0b00000, 0b00010, 0b10010, 0b01100 };
        f['k'] = .{ 0b10000, 0b10000, 0b10010, 0b11100, 0b10010 };
        f['l'] = .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 };
        f['m'] = .{ 0b00000, 0b11010, 0b10101, 0b10101, 0b10101 };
        f['n'] = .{ 0b00000, 0b11110, 0b10001, 0b10001, 0b10001 };
        f['o'] = .{ 0b00000, 0b01110, 0b10001, 0b10001, 0b01110 };
        f['p'] = .{ 0b00000, 0b11110, 0b10001, 0b11110, 0b10000 };
        f['q'] = .{ 0b00000, 0b01111, 0b10001, 0b01111, 0b00001 };
        f['r'] = .{ 0b00000, 0b10110, 0b11000, 0b10000, 0b10000 };
        f['s'] = .{ 0b00000, 0b01110, 0b10000, 0b01110, 0b00001 };
        f['t'] = .{ 0b01000, 0b11100, 0b01000, 0b01000, 0b00110 };
        f['u'] = .{ 0b00000, 0b10001, 0b10001, 0b10001, 0b01111 };
        f['v'] = .{ 0b00000, 0b10001, 0b10001, 0b01010, 0b00100 };
        f['w'] = .{ 0b00000, 0b10001, 0b10101, 0b10101, 0b01010 };
        f['x'] = .{ 0b00000, 0b10001, 0b01010, 0b00100, 0b10001 };
        f['y'] = .{ 0b00000, 0b10001, 0b10001, 0b01111, 0b00001 };
        f['z'] = .{ 0b00000, 0b11111, 0b00100, 0b01000, 0b11111 };
        f['{'] = .{ 0b00110, 0b01000, 0b10000, 0b01000, 0b00110 };
        f['|'] = .{ 0b00100, 0b00100, 0b00000, 0b00100, 0b00100 };
        f['}'] = .{ 0b01100, 0b00010, 0b00001, 0b00010, 0b01100 };
        f['~'] = .{ 0b01010, 0b10101, 0b00000, 0b00000, 0b00000 };
        f[127] = .{ 0b11111, 0b11111, 0b11111, 0b11111, 0b11111 };
        break :init f;
    };
};
