//! main.zig — unix style monolithic bsp editor

const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;

// ── math ────────────────────────────────────────────────────────────────────
pub const vec3 = packed struct {
    data: @Vector(3, f32),
    pub inline fn new(x: f32, y: f32, z: f32) vec3 { return .{ .data = .{ x, y, z } }; }
    pub inline fn zero() vec3 { return .{ .data = @splat(0) }; }
    pub inline fn add(a: vec3, b: vec3) vec3 { return .{ .data = a.data + b.data }; }
    pub inline fn sub(a: vec3, b: vec3) vec3 { return .{ .data = a.data - b.data }; }
    pub inline fn scale(v: vec3, s: f32) vec3 { return .{ .data = v.data * @as(@Vector(3, f32), @splat(s)) }; }
    pub inline fn dot(a: vec3, b: vec3) f32 { return @reduce(.Add, a.data * b.data); }
    pub inline fn len(v: vec3) f32 { return @sqrt(dot(v, v)); }
    pub inline fn norm(v: vec3) vec3 { const l = len(v); return if (l > 0) scale(v, 1.0 / l) else v; }
    pub inline fn cross(a: vec3, b: vec3) vec3 {
        return new(a.data[1] * b.data[2] - a.data[2] * b.data[1], a.data[2] * b.data[0] - a.data[0] * b.data[2], a.data[0] * b.data[1] - a.data[1] * b.data[0]);
    }
    pub inline fn lerp(a: vec3, b: vec3, t: f32) vec3 { return add(a, sub(b, a).scale(t)); }
    pub inline fn neg(v: vec3) vec3 { return .{ .data = -v.data }; }
};

pub const plane = struct {
    n: vec3,
    d: f32,
    pub fn dist(self: plane, p: vec3) f32 { return self.n.dot(p) + self.d; }
};

pub const mat4 = struct {
    data: [16]f32,
    pub inline fn ident() mat4 { return .{ .data = .{ 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 } }; }
    pub inline fn mul(a: mat4, b: mat4) mat4 {
        var r: mat4 = undefined;
        inline for (0..4) |c| {
            inline for (0..4) |row| {
                var s: f32 = 0;
                inline for (0..4) |k| s += a.data[k * 4 + row] * b.data[c * 4 + k];
                r.data[c * 4 + row] = s;
            }
        }
        return r;
    }
    pub inline fn view(pos: vec3, yaw: f32, pitch: f32, height: f32) mat4 {
        const eye = pos.add(vec3.new(0, height, 0));
        const cy = @cos(yaw);   const sy = @sin(yaw);
        const cp = @cos(pitch); const sp = @sin(pitch);
        return .{ .data = .{
            cy, sy * sp, -sy * cp, 0,
            0, cp, sp, 0,
            sy, -cy * sp, cy * cp, 0,
            -eye.data[0] * cy - eye.data[2] * sy,
            -eye.data[0] * sy * sp - eye.data[1] * cp + eye.data[2] * cy * sp,
            eye.data[0] * sy * cp - eye.data[1] * sp - eye.data[2] * cy * cp, 1,
        } };
    }
    pub inline fn persp(fov: f32, asp: f32, near: f32, far: f32) mat4 {
        const t = @tan(fov * std.math.pi / 360.0) * near;
        return .{ .data = .{
            near / (t * asp), 0, 0, 0,
            0, near / t, 0, 0,
            0, 0, -(far + near) / (far - near), -1,
            0, 0, -(2 * far * near) / (far - near), 0,
        } };
    }
};

// ── render ──────────────────────────────────────────────────────────────────
pub const vert = extern struct { pos: [3]f32, col: [4]f32 };

const mesh = struct { vbo: gpu.Buffer, ibo: gpu.Buffer, idx: u32 };

pub const render = struct {
    dev: gpu.Device,
    win: sdl.video.Window,
    pipe: gpu.GraphicsPipeline,
    depth: ?gpu.Texture = null,
    meshes: std.ArrayListUnmanaged(mesh) = .{},
    alloc: std.mem.Allocator,
    cmd: ?gpu.CommandBuffer = null,
    pass: ?gpu.RenderPass = null,
    clear: [4]f32 = .{ 0.06, 0.07, 0.12, 1.0 },
    w: u32 = 0, h: u32 = 0,

    pub fn init(dev: gpu.Device, win: sdl.video.Window, alloc: std.mem.Allocator) !render {
        try dev.claimWindow(win);
        const vs = try dev.createShader(.{ .code = @embedFile("shaders/triangle.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex, .num_uniform_buffers = 1 });
        const fs = try dev.createShader(.{ .code = @embedFile("shaders/triangle.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment });
        defer { dev.releaseShader(vs); dev.releaseShader(fs); }

        const p = try dev.createGraphicsPipeline(.{
            .vertex_shader = vs, .fragment_shader = fs,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &.{.{ .slot = 0, .pitch = @sizeOf(vert), .input_rate = .vertex }},
                .vertex_attributes = &.{
                    .{ .location = 0, .buffer_slot = 0, .format = .f32x3, .offset = @offsetOf(vert, "pos") },
                    .{ .location = 1, .buffer_slot = 0, .format = .f32x4, .offset = @offsetOf(vert, "col") },
                },
            },
            .rasterizer_state = .{ .cull_mode = .back, .front_face = .counter_clockwise },
            .depth_stencil_state = .{ .compare = .less_or_equal, .enable_depth_test = true, .enable_depth_write = true },
            .target_info = .{
                .color_target_descriptions = &.{.{ .format = try dev.getSwapchainTextureFormat(win) }},
                .depth_stencil_format = if (dev.textureSupportsFormat(.depth32_float, .two_dimensional, .{ .depth_stencil_target = true })) .depth32_float else .depth16_unorm,
            },
        });
        return .{ .dev = dev, .win = win, .pipe = p, .alloc = alloc };
    }

    pub fn deinit(self: *render) void {
        self.dev.waitForIdle() catch {};
        for (self.meshes.items) |m| {
            self.dev.releaseBuffer(m.vbo);
            self.dev.releaseBuffer(m.ibo);
        }
        self.meshes.deinit(self.alloc);
        if (self.depth) |d| self.dev.releaseTexture(d);
        self.dev.releaseGraphicsPipeline(self.pipe);
        self.dev.deinit();
    }

    fn upbuf(self: *render, data: []const u8, usage: gpu.BufferUsageFlags) !gpu.Buffer {
        const sz: u32 = @intCast(data.len);
        const buf = try self.dev.createBuffer(.{ .usage = usage, .size = sz });
        const tbuf = try self.dev.createTransferBuffer(.{ .usage = .upload, .size = sz });
        @memcpy((try self.dev.mapTransferBuffer(tbuf, false))[0..data.len], data);
        self.dev.unmapTransferBuffer(tbuf);
        const cmd = try self.dev.acquireCommandBuffer();
        const copy = cmd.beginCopyPass();
        copy.uploadToBuffer(.{ .transfer_buffer = tbuf, .offset = 0 }, .{ .buffer = buf, .offset = 0, .size = sz }, false);
        copy.end();
        try cmd.submit();
        try self.dev.waitForIdle();
        self.dev.releaseTransferBuffer(tbuf);
        return buf;
    }

    pub fn upmesh(self: *render, verts: []const vert, idcs: []const u32) !u32 {
        const id: u32 = @intCast(self.meshes.items.len);
        try self.meshes.append(self.alloc, .{
            .vbo = try self.upbuf(std.mem.sliceAsBytes(verts), .{ .vertex = true }),
            .ibo = try self.upbuf(std.mem.sliceAsBytes(idcs), .{ .index = true }),
            .idx = @intCast(idcs.len),
        });
        return id;
    }

    pub fn modmesh(self: *render, id: u32, verts: []const vert, idcs: []const u32) !void {
        if (id >= self.meshes.items.len) return;
        const nvbo = try self.upbuf(std.mem.sliceAsBytes(verts), .{ .vertex = true });
        const nibo = try self.upbuf(std.mem.sliceAsBytes(idcs), .{ .index = true });
        self.dev.releaseBuffer(self.meshes.items[id].vbo);
        self.dev.releaseBuffer(self.meshes.items[id].ibo);
        self.meshes.items[id] = .{ .vbo = nvbo, .ibo = nibo, .idx = @intCast(idcs.len) };
    }

    pub fn begin(self: *render) !bool {
        self.cmd = try self.dev.acquireCommandBuffer();
        const tex, const w, const h = try self.cmd.?.waitAndAcquireSwapchainTexture(self.win);
        if (tex == null) return false;
        if (w != self.w or h != self.h or self.depth == null) {
            self.w = w; self.h = h;
            if (self.depth) |dt| self.dev.releaseTexture(dt);
            self.depth = try self.dev.createTexture(.{ .format = if (self.dev.textureSupportsFormat(.depth32_float, .two_dimensional, .{ .depth_stencil_target = true })) .depth32_float else .depth16_unorm, .usage = .{ .depth_stencil_target = true }, .width = w, .height = h, .layer_count_or_depth = 1, .num_levels = 1 });
        }
        self.pass = self.cmd.?.beginRenderPass(
            &.{.{ .texture = tex.?, .clear_color = .{ .r = self.clear[0], .g = self.clear[1], .b = self.clear[2], .a = self.clear[3] }, .load = .clear, .store = .store }},
            .{ .texture = self.depth.?, .clear_depth = 1.0, .load = .clear, .store = .do_not_care, .stencil_load = .do_not_care, .stencil_store = .do_not_care, .cycle = false, .clear_stencil = 0 },
        );
        self.pass.?.bindGraphicsPipeline(self.pipe);
        return true;
    }

    pub fn draw(self: *render, id: u32, mvp: mat4) void {
        if (id >= self.meshes.items.len or self.meshes.items[id].idx == 0) return;
        self.pass.?.bindVertexBuffers(0, &.{.{ .buffer = self.meshes.items[id].vbo, .offset = 0 }});
        self.pass.?.bindIndexBuffer(.{ .buffer = self.meshes.items[id].ibo, .offset = 0 }, .indices_32bit);
        self.cmd.?.pushVertexUniformData(0, std.mem.asBytes(&mvp));
        self.pass.?.drawIndexedPrimitives(self.meshes.items[id].idx, 1, 0, 0, 0);
    }

    pub fn end(self: *render) !void {
        if (self.pass) |rp| rp.end();
        if (self.cmd) |cmd| try cmd.submit();
        self.cmd = null; self.pass = null;
    }
};

// ── bsp csg ─────────────────────────────────────────────────────────────────
pub const bsp = struct {
    pub const node = struct { p: u32, f: u32, b: u32 };
    pub const clip = struct { p: u32, f: bool };
    
    pub const empty: u32 = 0xFFFF_FFFE;
    pub const solid: u32 = 0xFFFF_FFFF;
    pub inline fn is_leaf(i: u32) bool { return i >= empty; }
    pub inline fn is_solid(i: u32) bool { return i == solid; }
    pub inline fn is_empty(i: u32) bool { return i == empty; }

    nodes: std.MultiArrayList(node) = .{},
    planes: std.ArrayListUnmanaged(plane) = .{},
    alloc: std.mem.Allocator,
    
    rverts: std.ArrayListUnmanaged(vert) = .{},
    ridx: std.ArrayListUnmanaged(u32) = .{},
    faces: std.ArrayListUnmanaged(u32) = .{},
    dirty: bool = true,
    sel: ?u32 = null,

    pub fn deinit(self: *bsp) void {
        self.nodes.deinit(self.alloc);
        self.planes.deinit(self.alloc);
        self.rverts.deinit(self.alloc);
        self.ridx.deinit(self.alloc);
        self.faces.deinit(self.alloc);
    }

    pub fn init(self: *bsp, height: f32) !void {
        try self.planes.append(self.alloc, .{ .n = vec3.new(0, 1, 0), .d = -height });
        try self.nodes.append(self.alloc, .{ .p = 0, .f = empty, .b = solid });
    }

    pub fn trace(self: *bsp, start: vec3, dir: vec3, max: f32, r: f32) ?struct { n: vec3, d: f32 } {
        if (self.nodes.len == 0) return null;
        var st = struct { frac: f32 = 1.0, norm: vec3 = vec3.zero(), hit: bool = false }{};
        _ = self.trace_rec(0, 0, 1, start, start.add(dir.scale(max)), r, &st);
        return if (st.hit and st.frac < 1.0) .{ .n = st.norm, .d = st.frac * max } else null;
    }

    fn trace_rec(self: *bsp, id: u32, p1f: f32, p2f: f32, p1: vec3, p2: vec3, r: f32, st: anytype) bool {
        if (st.frac <= p1f or is_empty(id) or is_solid(id)) return true;
        const s = self.nodes.slice();
        const pl = self.planes.items[s.items(.p)[id]];
        const fc = s.items(.f)[id];
        const bc = s.items(.b)[id];
        const t1 = pl.dist(p1);
        const t2 = pl.dist(p2);

        if (t1 >= r and t2 >= r) return self.trace_rec(fc, p1f, p2f, p1, p2, r, st);
        if (t1 < -r and t2 < -r) return self.trace_rec(bc, p1f, p2f, p1, p2, r, st);

        const ff = t1 >= t2;
        const near = if (ff) fc else bc;
        const far = if (ff) bc else fc;
        const delta = t1 - t2;
        const frac: f32 = std.math.clamp(if (@abs(delta) > 1e-5) (if (ff) (t1 - r - 0.001) / delta else (t1 + r + 0.001) / delta) else 0, 0, 1);
        const midf = p1f + (p2f - p1f) * frac;
        const mid = vec3.lerp(p1, p2, frac);

        if (!self.trace_rec(near, p1f, midf, p1, mid, r, st)) return false;
        if (self.in_solid(far, mid, r)) {
            if (midf < st.frac) { st.frac = @max(0, midf); st.norm = if (ff) pl.n else pl.n.neg(); st.hit = true; }
            return false;
        }
        return self.trace_rec(far, midf, p2f, mid, p2, r, st);
    }
    
    fn in_solid(self: *bsp, id: u32, p: vec3, r: f32) bool {
        if (is_solid(id)) return true;
        if (is_empty(id)) return false;
        const s = self.nodes.slice();
        const d = self.planes.items[s.items(.p)[id]].dist(p);
        if (d > r) return self.in_solid(s.items(.f)[id], p, r);
        if (d < -r) return self.in_solid(s.items(.b)[id], p, r);
        return self.in_solid(s.items(.f)[id], p, r) or self.in_solid(s.items(.b)[id], p, r);
    }

    pub fn mesh(self: *bsp) !void {
        self.rverts.clearRetainingCapacity(); self.ridx.clearRetainingCapacity(); self.faces.clearRetainingCapacity();
        if (self.nodes.len == 0) return;
        var stack: [64]clip = undefined;
        try self.mesh_node(0, &stack, 0);
        self.dirty = false;
    }

    fn mesh_node(self: *bsp, id: u32, stack: []clip, depth: usize) !void {
        if (is_leaf(id)) return;
        const s = self.nodes.slice();
        const pi = s.items(.p)[id];
        const pl = self.planes.items[pi];

        var poly: [48]vec3 = undefined;
        var count = base_poly(pl, 2000.0, poly[0..4]);
        
        for (stack[0..depth]) |a| {
            var cp = self.planes.items[a.p];
            if (a.f) { cp.n = cp.n.neg(); cp.d = -cp.d; }
            var out: [48]vec3 = undefined;
            count = clip_poly(poly[0..count], cp, &out);
            if (count < 3) break;
            @memcpy(poly[0..count], out[0..count]);
        }

        if (count >= 3) try self.filt_f(poly[0..count], s.items(.f)[id], s.items(.b)[id], pl, id);
        
        if (depth < 64) {
            stack[depth] = .{ .p = pi, .f = false }; try self.mesh_node(s.items(.f)[id], stack, depth + 1);
            stack[depth] = .{ .p = pi, .f = true }; try self.mesh_node(s.items(.b)[id], stack, depth + 1);
        }
    }

    fn filt_f(self: *bsp, verts: []const vec3, fid: u32, bid: u32, p: plane, src: u32) !void {
        if (is_solid(fid)) return self.filt_b(verts, bid, p, true, src);
        if (is_empty(fid)) return self.filt_b(verts, bid, p, false, src);
        const pl = self.planes.items[self.nodes.slice().items(.p)[fid]];
        var fv: [48]vec3 = undefined; var bv: [48]vec3 = undefined;
        const res = split(verts, pl, &fv, &bv);
        if (res.f >= 3) try self.filt_f(fv[0..res.f], self.nodes.slice().items(.f)[fid], bid, p, src);
        if (res.b >= 3) try self.filt_f(bv[0..res.b], self.nodes.slice().items(.b)[fid], bid, p, src);
    }

    fn filt_b(self: *bsp, verts: []const vec3, bid: u32, p: plane, fsol: bool, src: u32) !void {
        if (is_solid(bid)) { if (!fsol) try self.push_face(verts, p, false, src); return; }
        if (is_empty(bid)) { if (fsol) try self.push_face(verts, p, true, src); return; }
        const pl = self.planes.items[self.nodes.slice().items(.p)[bid]];
        var fv: [48]vec3 = undefined; var bv: [48]vec3 = undefined;
        const res = split(verts, pl, &fv, &bv);
        if (res.f >= 3) try self.filt_b(fv[0..res.f], self.nodes.slice().items(.f)[bid], p, fsol, src);
        if (res.b >= 3) try self.filt_b(bv[0..res.b], self.nodes.slice().items(.b)[bid], p, fsol, src);
    }

    fn push_face(self: *bsp, verts: []const vec3, p: plane, flip: bool, src: u32) !void {
        _ = p;
        if (verts.len < 3) return;
        const col: [4]f32 = if (self.sel == src) .{0.95,0.35,0.1,1} else .{0.55,0.55,0.6,1};
        const base: u32 = @intCast(self.rverts.items.len);
        for (0..verts.len) |i| try self.rverts.append(self.alloc, .{ .pos = (if (flip) verts[verts.len - 1 - i] else verts[i]).data, .col = col });
        for (2..verts.len) |i| {
            try self.ridx.appendSlice(self.alloc, &.{ base, base + @as(u32, @intCast(i - 1)), base + @as(u32, @intCast(i)) });
            try self.faces.append(self.alloc, src);
        }
    }

    fn base_poly(p: plane, sz: f32, out: []vec3) usize {
        const ref = if (@abs(p.n.data[1]) < 0.9) vec3.new(0, 1, 0) else vec3.new(1, 0, 0);
        const t1 = p.n.cross(ref).norm();
        const t2 = p.n.cross(t1).norm();
        const c = p.n.scale(-p.d);
        out[0] = c.sub(t1.scale(sz)).sub(t2.scale(sz));
        out[1] = c.add(t1.scale(sz)).sub(t2.scale(sz));
        out[2] = c.add(t1.scale(sz)).add(t2.scale(sz));
        out[3] = c.sub(t1.scale(sz)).add(t2.scale(sz));
        return 4;
    }

    fn split(verts: []const vec3, p: plane, fv: *[48]vec3, bv: *[48]vec3) struct { f: usize, b: usize } {
        var f: usize = 0; var b: usize = 0; var dists: [48]f32 = undefined;
        var has_f = false; var has_b = false;
        for (verts, 0..) |v, i| { dists[i] = p.dist(v); if (dists[i] > 1e-4) has_f = true; if (dists[i] < -1e-4) has_b = true; }
        if (!has_b) { @memcpy(fv[0..verts.len], verts); return .{ .f = verts.len, .b = 0 }; }
        if (!has_f) { @memcpy(bv[0..verts.len], verts); return .{ .f = 0, .b = verts.len }; }
        for (0..verts.len) |i| {
            const p1 = verts[i]; const p2 = verts[(i + 1) % verts.len];
            const d1 = dists[i]; const d2 = dists[(i + 1) % verts.len];
            if (d1 >= -1e-4 and f < 48) { fv[f] = p1; f += 1; }
            if (d1 <= 1e-4 and b < 48) { bv[b] = p1; b += 1; }
            if ((d1 > 1e-4 and d2 < -1e-4) or (d1 < -1e-4 and d2 > 1e-4)) {
                const mid = vec3.lerp(p1, p2, d1 / (d1 - d2));
                if (f < 48) { fv[f] = mid; f += 1; }
                if (b < 48) { bv[b] = mid; b += 1; }
            }
        }
        return .{ .f = if (f >= 3) f else 0, .b = if (b >= 3) b else 0 };
    }

    fn clip_poly(verts: []const vec3, p: plane, out: *[48]vec3) usize {
        var n: usize = 0;
        for (0..verts.len) |i| {
            const a = verts[i]; const b = verts[(i + 1) % verts.len];
            const da = p.dist(a); const db = p.dist(b);
            if (da >= -1e-4) {
                if (n < 48) { out[n] = a; n += 1; }
                if (db < -1e-4 and n < 48) { out[n] = vec3.lerp(a, b, da / (da - db)); n += 1; }
            } else if (db >= -1e-4 and n < 48) {
                out[n] = vec3.lerp(a, b, da / (da - db)); n += 1;
            }
        }
        return if (n >= 3) n else 0;
    }
};

// ── player ──────────────────────────────────────────────────────────────────
pub const player = struct {
    pos: vec3 = vec3.new(0, 1.5, 0), vel: vec3 = vec3.zero(),
    yaw: f32 = 0, pitch: f32 = 0, ground: bool = false,

    pub fn step(self: *player, tree: *bsp, wish: vec3, jump: bool, dt: f32) void {
        const radius = 0.3; const gravity = 12.0; const jump_spd = 5.0; const max_spd = 5.5; const accel = 55.0; const friction = 6.0;
        
        const gtrace = tree.trace(self.pos, vec3.new(0, -1, 0), 0.05, radius);
        self.ground = false; var gnorm = vec3.new(0, 1, 0);
        if (gtrace) |h| { if (h.n.data[1] > 0.707) { self.ground = true; gnorm = h.n; } }

        if (self.ground) {
            const vn = self.vel.dot(gnorm); if (vn < 0) self.vel = self.vel.sub(gnorm.scale(vn));
            const spd = @sqrt(self.vel.data[0] * self.vel.data[0] + self.vel.data[2] * self.vel.data[2]);
            if (spd > 0.1) {
                const drop = spd * friction * dt; const f = @max(0, spd - drop) / spd;
                self.vel.data[0] *= f; self.vel.data[2] *= f;
            } else { self.vel.data[0] = 0; self.vel.data[2] = 0; }
        } else { self.vel.data[1] -= gravity * dt; }

        if (jump and self.ground) { self.vel.data[1] = jump_spd; self.ground = false; }

        const wl = @sqrt(wish.data[0] * wish.data[0] + wish.data[2] * wish.data[2]);
        if (wl > 0) {
            const wn = wish.scale(1.0 / wl);
            const top = if (self.ground) max_spd * wl else @min(max_spd * wl, 1.0);
            const cur = vec3.new(self.vel.data[0], 0, self.vel.data[2]).dot(wn);
            self.vel = self.vel.add(wn.scale(@min(accel * dt, @max(0, top - cur))));
        }

        var rem = self.vel.scale(dt);
        for (0..4) |_| {
            const l = rem.len(); if (l < 1e-5) break;
            const dir = rem.scale(1.0 / l);
            const h = tree.trace(self.pos, dir, l + 1e-3, radius) orelse { self.pos = self.pos.add(rem); break; };
            const m = @max(0, h.d - 1e-5);
            if (m > 0) { self.pos = self.pos.add(dir.scale(m)); rem = rem.sub(dir.scale(@min(m, l))); }
            self.pos = self.pos.add(h.n.scale(1e-3));
            
            const backoff = rem.dot(h.n); if (backoff < 0) rem = rem.sub(h.n.scale(backoff));
            const vb = self.vel.dot(h.n); if (vb < 0) self.vel = self.vel.sub(h.n.scale(vb));
        }
    }
};

// ── main ────────────────────────────────────────────────────────────────────
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });

    const win = try sdl.video.Window.init("bsp monolith", 1280, 720, .{});
    defer win.deinit();
    
    var tree = bsp{ .alloc = alloc }; 
    defer tree.deinit();
    try tree.init(0); try tree.mesh();
    
    var ctx = try render.init(try gpu.Device.init(.{ .spirv = true }, true, null), win, alloc);
    defer ctx.deinit();
    
    const id = try ctx.upmesh(tree.rverts.items, tree.ridx.items);
    
    var plr = player{};
    var run = true;
    var lock = false;

    while (run) {
        const keys = sdl.keyboard.getState();
        const sc = sdl.Scancode;
        var dx: f32 = 0; var dy: f32 = 0;

        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => run = false,
                .key_down => |k| {
                    if (k.scancode == .escape) { lock = false; sdl.mouse.show() catch {}; sdl.mouse.setWindowRelativeMode(win, false) catch {}; }
                },
                .mouse_button_down => {
                    if (!lock) { lock = true; sdl.mouse.hide() catch {}; sdl.mouse.setWindowRelativeMode(win, true) catch {}; }
                },
                .mouse_motion => |m| { if (lock) { dx += m.x_rel; dy += m.y_rel; } },
                else => {},
            }
        }

        if (lock) {
            plr.yaw += dx * 0.002;
            plr.pitch = std.math.clamp(plr.pitch + dy * 0.002, -1.5, 1.5);
        }

        const fw: f32 = if (keys[@intFromEnum(sc.w)]) 1 else if (keys[@intFromEnum(sc.s)]) @as(f32, -1) else 0;
        const rt: f32 = if (keys[@intFromEnum(sc.d)]) 1 else if (keys[@intFromEnum(sc.a)]) @as(f32, -1) else 0;
        const wish = vec3.new(@sin(plr.yaw), 0, -@cos(plr.yaw)).scale(fw).add(vec3.new(@cos(plr.yaw), 0, @sin(plr.yaw)).scale(rt));
        
        plr.step(&tree, wish, keys[@intFromEnum(sc.space)], 1.0 / 60.0);

        if (tree.dirty) {
            try tree.mesh();
            try ctx.modmesh(id, tree.rverts.items, tree.ridx.items);
        }

        if (try ctx.begin()) {
            const mvp = mat4.persp(90.0, 1280.0 / 720.0, 0.1, 500.0).mul(mat4.view(plr.pos, plr.yaw, plr.pitch, 0.6));
            ctx.draw(id, mvp);
            try ctx.end();
        }
    }
}
