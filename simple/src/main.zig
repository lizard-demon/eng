//! main.zig — unix style modern quake map viewer (bsp29/bsp2 + bspx + physics)

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
    n: vec3, d: f32,
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
    pub inline fn view(pos: vec3, yaw: f32, pitch: f32) mat4 {
        const cy = @cos(yaw);   const sy = @sin(yaw);
        const cp = @cos(pitch); const sp = @sin(pitch);
        return .{ .data = .{
            cy, sy * sp, -sy * cp, 0,
            0, cp, sp, 0,
            sy, -cy * sp, cy * cp, 0,
            -pos.data[0] * cy - pos.data[2] * sy,
            -pos.data[0] * sy * sp - pos.data[1] * cp + pos.data[2] * cy * sp,
            pos.data[0] * sy * cp - pos.data[1] * sp - pos.data[2] * cy * cp, 1,
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
pub const vert = extern struct { pos: [3]f32, uv: [2]f32, col: [4]f32 };

const mesh = struct { vbo: gpu.Buffer, ibo: gpu.Buffer, idx: u32 };

pub const render = struct {
    dev: gpu.Device, win: sdl.video.Window, pipe: gpu.GraphicsPipeline,
    depth: ?gpu.Texture = null, meshes: std.ArrayListUnmanaged(mesh) = .{},
    alloc: std.mem.Allocator, cmd: ?gpu.CommandBuffer = null, pass: ?gpu.RenderPass = null,
    clear: [4]f32 = .{ 0.04, 0.05, 0.09, 1.0 }, w: u32 = 0, h: u32 = 0,

    pub fn init(dev: gpu.Device, win: sdl.video.Window, alloc: std.mem.Allocator) !render {
        try dev.claimWindow(win);
        const vs = try dev.createShader(.{ .code = @embedFile("shaders/basic.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex, .num_uniform_buffers = 1 });
        const fs = try dev.createShader(.{ .code = @embedFile("shaders/basic.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment });
        defer { dev.releaseShader(vs); dev.releaseShader(fs); }

        const p = try dev.createGraphicsPipeline(.{
            .vertex_shader = vs, .fragment_shader = fs,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &.{.{ .slot = 0, .pitch = @sizeOf(vert), .input_rate = .vertex }},
                .vertex_attributes = &.{
                    .{ .location = 0, .buffer_slot = 0, .format = .f32x3, .offset = @offsetOf(vert, "pos") },
                    .{ .location = 1, .buffer_slot = 0, .format = .f32x2, .offset = @offsetOf(vert, "uv") },
                    .{ .location = 2, .buffer_slot = 0, .format = .f32x4, .offset = @offsetOf(vert, "col") },
                },
            },
            .rasterizer_state = .{ .cull_mode = .none, .front_face = .counter_clockwise },
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
        for (self.meshes.items) |m| { self.dev.releaseBuffer(m.vbo); self.dev.releaseBuffer(m.ibo); }
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
        const cp = cmd.beginCopyPass();
        cp.uploadToBuffer(.{ .transfer_buffer = tbuf, .offset = 0 }, .{ .buffer = buf, .offset = 0, .size = sz }, false);
        cp.end(); try cmd.submit(); try self.dev.waitForIdle();
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

// ── map parser (bsp29 + bsp2 + bspx) ─────────────────────────────────────────
pub const map = struct {
    pub const face_t = struct { p: u32, s: u32, e: u32, num_e: u32, tex: u32, light: i32 };
    pub const tinfo_t = struct { s: vec3, s_off: f32, t: vec3, t_off: f32 };
    pub const bspx_t = struct { name: [24]u8, ofs: u32, len: u32 };
    pub const model_t = struct { headnode: [4]i32 }; 
    pub const clipnode_t = struct { p: u32, f: i32, b: i32 };

    raw_ents: []const u8 = &[_]u8{},
    alloc: std.mem.Allocator,
    bsp2: bool = false,
    
    verts: std.ArrayListUnmanaged(vec3) = .{},
    planes: std.ArrayListUnmanaged(plane) = .{},
    edges: std.ArrayListUnmanaged([2]u32) = .{},
    surfedges: std.ArrayListUnmanaged(i32) = .{},
    faces: std.ArrayListUnmanaged(face_t) = .{},
    tinfos: std.ArrayListUnmanaged(tinfo_t) = .{},
    models: std.ArrayListUnmanaged(model_t) = .{},
    clipnodes: std.ArrayListUnmanaged(clipnode_t) = .{},
    ext_lumps: std.ArrayListUnmanaged(bspx_t) = .{},
    
    raw_light: []const u8 = &[_]u8{},
    raw_rgb: []const u8 = &[_]u8{},

    rverts: std.ArrayListUnmanaged(vert) = .{},
    ridx: std.ArrayListUnmanaged(u32) = .{},

    pub fn deinit(self: *map) void {
        self.verts.deinit(self.alloc); self.planes.deinit(self.alloc);
        self.edges.deinit(self.alloc); self.surfedges.deinit(self.alloc);
        self.faces.deinit(self.alloc); self.tinfos.deinit(self.alloc); 
        self.models.deinit(self.alloc); self.clipnodes.deinit(self.alloc);
        self.ext_lumps.deinit(self.alloc);
        self.rverts.deinit(self.alloc); self.ridx.deinit(self.alloc);
    }

    inline fn i32l(d: []const u8, o: usize) i32 { return std.mem.readInt(i32, d[o..o+4][0..4], .little); }
    inline fn u32l(d: []const u8, o: usize) u32 { return std.mem.readInt(u32, d[o..o+4][0..4], .little); }
    inline fn i16l(d: []const u8, o: usize) i16 { return std.mem.readInt(i16, d[o..o+2][0..2], .little); }
    inline fn u16l(d: []const u8, o: usize) u16 { return std.mem.readInt(u16, d[o..o+2][0..2], .little); }
    inline fn f32l(d: []const u8, o: usize) f32 { return @bitCast(u32l(d, o)); }

    pub fn load(self: *map, data: []const u8) !void {
        if (data.len < 160) return error.FileTooSmall;
        const magic = u32l(data, 0);
        self.bsp2 = magic == 0x32505342; // "BSP2"
        if (magic != 29 and !self.bsp2) return error.InvalidVersion;

        var eof_ofs: u32 = 0;
        var dirs: [15]struct { o: u32, l: u32 } = undefined;
        for (0..15) |i| {
            dirs[i] = .{ .o = u32l(data, 4 + i * 8), .l = u32l(data, 4 + i * 8 + 4) };
            if (dirs[i].o + dirs[i].l > eof_ofs) eof_ofs = dirs[i].o + dirs[i].l;
        }

        // 0: entities
        self.raw_ents = data[dirs[0].o .. dirs[0].o + dirs[0].l];

        // 3: vertices (SWIZZLED Z-UP to Y-UP)
        const v_dir = dirs[3]; var i: usize = 0; 
        while (i < v_dir.l) : (i += 12) {
            try self.verts.append(self.alloc, vec3.new(f32l(data, v_dir.o + i), f32l(data, v_dir.o + i + 8), -f32l(data, v_dir.o + i + 4)));
        }

        // 1: planes (SWIZZLED)
        const p_dir = dirs[1]; i = 0;
        const pstep: usize = 20;
        while (i < p_dir.l) : (i += pstep) {
            try self.planes.append(self.alloc, .{
                .n = vec3.new(f32l(data, p_dir.o + i), f32l(data, p_dir.o + i + 8), -f32l(data, p_dir.o + i + 4)),
                .d = f32l(data, p_dir.o + i + 12),
            });
        }

        // 12: edges
        const e_dir = dirs[12]; i = 0;
        const estep: usize = if (self.bsp2) 8 else 4;
        while (i < e_dir.l) : (i += estep) {
            const v0 = if (self.bsp2) u32l(data, e_dir.o + i) else u16l(data, e_dir.o + i);
            const v1 = if (self.bsp2) u32l(data, e_dir.o + i + 4) else u16l(data, e_dir.o + i + 2);
            try self.edges.append(self.alloc, .{ v0, v1 });
        }

        // 13: surfedges
        const se_dir = dirs[13]; i = 0;
        while (i < se_dir.l) : (i += 4) {
            try self.surfedges.append(self.alloc, i32l(data, se_dir.o + i));
        }

        // 6: texinfo (SWIZZLED)
        const t_dir = dirs[6]; i = 0;
        while (i < t_dir.l) : (i += 40) {
            try self.tinfos.append(self.alloc, .{
                .s = vec3.new(f32l(data, t_dir.o + i), f32l(data, t_dir.o + i + 8), -f32l(data, t_dir.o + i + 4)),
                .s_off = f32l(data, t_dir.o + i + 12),
                .t = vec3.new(f32l(data, t_dir.o + i + 16), f32l(data, t_dir.o + i + 24), -f32l(data, t_dir.o + i + 20)),
                .t_off = f32l(data, t_dir.o + i + 28),
            });
        }

        // 7: faces
        const f_dir = dirs[7]; i = 0;
        const fstep: usize = if (self.bsp2) 28 else 20;
        while (i < f_dir.l) : (i += fstep) {
            const ofs = f_dir.o + i;
            if (self.bsp2) {
                try self.faces.append(self.alloc, .{ .p = u32l(data, ofs), .s = u32l(data, ofs+4), .e = @bitCast(i32l(data, ofs+8)), .num_e = u32l(data, ofs+12), .tex = u32l(data, ofs+16), .light = i32l(data, ofs+24) });
            } else {
                try self.faces.append(self.alloc, .{ .p = u16l(data, ofs), .s = u16l(data, ofs+2), .e = @bitCast(i32l(data, ofs+4)), .num_e = u16l(data, ofs+8), .tex = u16l(data, ofs+10), .light = i32l(data, ofs+16) });
            }
        }

        // 9: clipnodes
        const c_dir = dirs[9]; i = 0;
        const cstep: usize = if (self.bsp2) 12 else 8;
        while (i < c_dir.l) : (i += cstep) {
            const ofs = c_dir.o + i;
            if (self.bsp2) {
                try self.clipnodes.append(self.alloc, .{ .p = u32l(data, ofs), .f = i32l(data, ofs+4), .b = i32l(data, ofs+8) });
            } else {
                try self.clipnodes.append(self.alloc, .{ .p = u32l(data, ofs), .f = i16l(data, ofs+4), .b = i16l(data, ofs+6) });
            }
        }

        // 14: models
        const m_dir = dirs[14]; i = 0;
        const mstep: usize = if (self.bsp2) 88 else 64; 
        while (i < m_dir.l) : (i += mstep) {
            const ofs = m_dir.o + i + 36; // skip bounding box and origin
            try self.models.append(self.alloc, .{ .headnode = .{
                i32l(data, ofs), i32l(data, ofs+4), i32l(data, ofs+8), i32l(data, ofs+12)
            }});
        }

        // 8: lightmaps
        self.raw_light = data[dirs[8].o .. dirs[8].o + dirs[8].l];

        // bspx extended lumps (RGBLIGHTING)
        if (eof_ofs + 8 <= data.len and u32l(data, eof_ofs) == 0x58505342) { // "BSPX"
            const num_lumps = u32l(data, eof_ofs + 4);
            var x_ofs = eof_ofs + 8;
            for (0..num_lumps) |_| {
                var name: [24]u8 = undefined;
                @memcpy(&name, data[x_ofs .. x_ofs + 24]);
                const lump = bspx_t{ .name = name, .ofs = u32l(data, x_ofs + 24), .len = u32l(data, x_ofs + 28) };
                try self.ext_lumps.append(self.alloc, lump);
                x_ofs += 32;
                if (std.mem.eql(u8, name[0..11], "RGBLIGHTING")) {
                    self.raw_rgb = data[lump.ofs .. lump.ofs + lump.len];
                }
            }
        }
    }

    pub fn build(self: *map) !void {
        self.rverts.clearRetainingCapacity();
        self.ridx.clearRetainingCapacity();

        for (self.faces.items) |f| {
            const start_idx: u32 = @intCast(self.rverts.items.len);
            const tinfo = self.tinfos.items[f.tex];
            
            const n = tinfo.s.cross(tinfo.t).norm();
            const shade = @max(0.1, n.dot(vec3.new(0.3, 0.8, -0.4).norm()));
            const color: [4]f32 = .{ shade * 0.8, shade * 0.8, shade * 0.8, 1.0 };

            for (0..f.num_e) |ei| {
                const se = self.surfedges.items[f.e + ei];
                const edge = self.edges.items[@abs(se)];
                const v_idx = if (se >= 0) edge[0] else edge[1];
                const pos = self.verts.items[v_idx];

                const u = (pos.dot(tinfo.s) + tinfo.s_off) / 16.0;
                const v = (pos.dot(tinfo.t) + tinfo.t_off) / 16.0;

                try self.rverts.append(self.alloc, .{
                    .pos = .{ pos.data[0], pos.data[1], pos.data[2] },
                    .uv = .{ u, v },
                    .col = color,
                });
            }

            if (f.num_e >= 3) {
                for (2..f.num_e) |ei| {
                    try self.ridx.appendSlice(self.alloc, &.{
                        start_idx,
                        start_idx + @as(u32, @intCast(ei - 1)),
                        start_idx + @as(u32, @intCast(ei)),
                    });
                }
            }
        }
    }

    pub fn get_spawn(self: *map) vec3 {
        // Break the entity string into { blocks }
        var it = std.mem.splitScalar(u8, self.raw_ents, '{');
        while (it.next()) |block| {
            if (std.mem.indexOf(u8, block, "\"classname\" \"info_player_start\"") != null) {
                if (std.mem.indexOf(u8, block, "\"origin\"")) |o_idx| {
                    if (std.mem.indexOfPos(u8, block, o_idx + 8, "\"")) |q1| {
                        if (std.mem.indexOfPos(u8, block, q1 + 1, "\"")) |q2| {
                            // Extract coordinates, handling arbitrary spacing
                            var coords = std.mem.tokenizeAny(u8, block[q1 + 1 .. q2], " \t");
                            const x = std.fmt.parseFloat(f32, coords.next() orelse "0") catch 0;
                            const y = std.fmt.parseFloat(f32, coords.next() orelse "0") catch 0;
                            const z = std.fmt.parseFloat(f32, coords.next() orelse "0") catch 0;
                            
                            // SWIZZLE! Quake is Z-Up. We need Y-Up.
                            return vec3.new(x, z, -y); 
                        }
                    }
                }
            }
        }
        return vec3.new(0, 0, 0); // Safe fallback if no spawn is found
    }

    pub fn trace(self: *map, start: vec3, dir: vec3, max: f32) ?struct { n: vec3, d: f32 } {
        if (self.clipnodes.items.len == 0 or self.models.items.len == 0) return null;
        var st = struct { frac: f32 = 1.0, norm: vec3 = vec3.zero(), hit: bool = false }{};
        
        const root = self.models.items[0].headnode[1]; 
        _ = self.trace_clip(root, 0, 1, start, start.add(dir.scale(max)), &st);
        
        return if (st.hit and st.frac < 1.0) .{ .n = st.norm, .d = st.frac * max } else null;
    }

    fn trace_clip(self: *map, node_id: i32, p1f: f32, p2f: f32, p1: vec3, p2: vec3, st: anytype) bool {
        if (st.frac <= p1f or node_id == -1) return true;
        if (node_id < 0) {
            if (p1f < st.frac) { st.frac = @max(0, p1f); st.hit = true; }
            return false;
        }

        const cn = self.clipnodes.items[@intCast(node_id)];
        const pl = self.planes.items[cn.p];
        const t1 = pl.dist(p1);
        const t2 = pl.dist(p2);

        if (t1 >= 0 and t2 >= 0) return self.trace_clip(cn.f, p1f, p2f, p1, p2, st);
        if (t1 < 0 and t2 < 0)   return self.trace_clip(cn.b, p1f, p2f, p1, p2, st);

        const ff = t1 >= t2;
        const near = if (ff) cn.f else cn.b;
        const far  = if (ff) cn.b else cn.f;
        const delta = t1 - t2;
        
        const frac: f32 = std.math.clamp(if (@abs(delta) > 1e-5) (if (ff) (t1 + 0.03125) / delta else (t1 - 0.03125) / delta) else 0, 0, 1);
        const midf = p1f + (p2f - p1f) * frac;
        const mid = vec3.lerp(p1, p2, frac);

        if (!self.trace_clip(near, p1f, midf, p1, mid, st)) return false;
        if (!self.trace_clip(far, midf, p2f, mid, p2, st)) {
            if (st.hit and st.norm.data[0] == 0 and st.norm.data[1] == 0 and st.norm.data[2] == 0) {
                st.norm = if (ff) pl.n else pl.n.neg();
            }
            return false;
        }
        return true;
    }
};

// ── player ──────────────────────────────────────────────────────────────────
pub const player = struct {
    pos: vec3 = vec3.new(0, 128, 0), vel: vec3 = vec3.zero(),
    yaw: f32 = 0, pitch: f32 = 0, ground: bool = false,

    pub fn step(self: *player, lvl: *map, wish: vec3, jump: bool, dt: f32) void {
        const gravity = 800.0; const jump_spd = 270.0; const max_spd = 320.0; 
        const accel = 10.0; const friction = 6.0;
        
        const gtrace = lvl.trace(self.pos, vec3.new(0, -1, 0), 0.25);
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
            const top = if (self.ground) max_spd * wl else @min(max_spd * wl, 30.0);
            const cur = vec3.new(self.vel.data[0], 0, self.vel.data[2]).dot(wn);
            self.vel = self.vel.add(wn.scale(@min(accel * max_spd * dt, @max(0, top - cur))));
        }

        var rem = self.vel.scale(dt);
        for (0..4) |_| {
            const l = rem.len(); if (l < 1e-3) break;
            const dir = rem.scale(1.0 / l);
            const h = lvl.trace(self.pos, dir, l + 0.1) orelse { self.pos = self.pos.add(rem); break; };
            const m = @max(0, h.d - 0.01);
            if (m > 0) { self.pos = self.pos.add(dir.scale(m)); rem = rem.sub(dir.scale(@min(m, l))); }
            self.pos = self.pos.add(h.n.scale(0.01)); 
            
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

    const win = try sdl.video.Window.init("modern quake viewer", 1280, 720, .{});
    defer win.deinit();
    
    var ctx = try render.init(try gpu.Device.init(.{ .spirv = true }, true, null), win, alloc);
    defer ctx.deinit();

    var lvl = map{ .alloc = alloc };
    defer lvl.deinit();
    
    if (std.fs.cwd().readFileAlloc(alloc, "start.bsp", 64 * 1024 * 1024)) |data| {
        defer alloc.free(data);
        lvl.load(data) catch |e| std.debug.print("map load failed: {}\n", .{e});
        try lvl.build();
    } else |_| {
        std.debug.print("no 'start.bsp' found. rendering empty space.\n", .{});
    }
    
    const id = try ctx.upmesh(lvl.rverts.items, lvl.ridx.items);
    
    var plr = player{ .pos = vec3.new(-1500,10,900) };
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
        const wish = vec3.new(@sin(plr.yaw), 0, -@cos(plr.yaw)).scale(fw)
                .add(vec3.new(@cos(plr.yaw), 0, @sin(plr.yaw)).scale(rt));
        
        plr.step(&lvl, wish, keys[@intFromEnum(sc.space)], 1.0 / 60.0);

        if (try ctx.begin()) {
            const eye_pos = plr.pos.add(vec3.new(0, 22.0, 0));
            const mvp = mat4.persp(70.0, 1280.0 / 720.0, 1.0, 8192.0).mul(mat4.view(eye_pos, plr.yaw, plr.pitch));
            ctx.draw(id, mvp);
            try ctx.end();
        }

        //if (try ctx.begin()) {
        //    const mvp = mat4.persp(90.0, 1280.0 / 720.0, 4.0, 8192.0).mul(mat4.view(plr.pos, plr.yaw, plr.pitch));
        //    ctx.draw(id, mvp);
        //    try ctx.end();
        //}
    }
}
