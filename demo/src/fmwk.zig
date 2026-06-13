const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;

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
        pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
            return Vec3.new(a.data[1]*b.data[2] - a.data[2]*b.data[1], a.data[2]*b.data[0] - a.data[0]*b.data[2], a.data[0]*b.data[1] - a.data[1]*b.data[0]);
        }
        pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 { return add(a, sub(b, a).scale(t)); }
        pub inline fn min(a: Vec3, b: Vec3) Vec3 { return .{ .data = @min(a.data, b.data) }; }
        pub inline fn max(a: Vec3, b: Vec3) Vec3 { return .{ .data = @max(a.data, b.data) }; }
    };

    pub const AABB = packed struct {
        lo: Vec3, hi: Vec3,
        pub fn new(lo: Vec3, hi: Vec3) AABB { return .{ .lo = lo, .hi = hi }; }
        pub fn expand(a: AABB, p: Vec3) AABB { return .{ .lo = Vec3.min(a.lo, p), .hi = Vec3.max(a.hi, p) }; }
        pub const empty: AABB = .{
            .lo = Vec3{ .data = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) } },
            .hi = Vec3{ .data = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) } },
        };
    };

    pub const Mat4 = struct {
        data: [16]f32,
        pub inline fn identity() Mat4 { return .{ .data = .{ 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 } }; }
        pub inline fn mul(a: Mat4, b: Mat4) Mat4 {
            var r: Mat4 = undefined;
            inline for (0..4) |c| {
                inline for (0..4) |row| {
                    var s: f32 = 0;
                    inline for (0..4) |k| s += a.data[k*4 + row] * b.data[c*4 + k];
                    r.data[c*4 + row] = s;
                }
            }
            return r;
        }
        pub inline fn translate(v: Vec3) Mat4 {
            return .{ .data = .{ 1,0,0,0, 0,1,0,0, 0,0,1,0, v.data[0],v.data[1],v.data[2],1 } };
        }
        pub inline fn scaling(v: Vec3) Mat4 {
            return .{ .data = .{ v.data[0],0,0,0, 0,v.data[1],0,0, 0,0,v.data[2],0, 0,0,0,1 } };
        }
        pub inline fn viewMatrix(pos: Vec3, yaw: f32, pitch: f32, eye_height: f32) Mat4 {
            const eye = Vec3.add(pos, Vec3.new(0, eye_height, 0));
            const cy = @cos(yaw);   const sy = @sin(yaw);
            const cp = @cos(pitch); const sp = @sin(pitch);
            return .{ .data = .{
                cy, sy*sp, -sy*cp, 0,
                0, cp, sp, 0,
                sy, -cy*sp, cy*cp, 0,
                -eye.data[0]*cy - eye.data[2]*sy,
                -eye.data[0]*sy*sp - eye.data[1]*cp + eye.data[2]*cy*sp,
                 eye.data[0]*sy*cp - eye.data[1]*sp - eye.data[2]*cy*cp, 1,
            } };
        }
    };

    pub inline fn perspective(fov: f32, asp: f32, near: f32, far: f32) Mat4 {
        const t = @tan(fov * std.math.pi / 360.0) * near;
        const r = t * asp;
        return .{ .data = .{
            near/r, 0, 0, 0,
            0, near/t, 0, 0,
            0, 0, -(far+near)/(far-near), -1,
            0, 0, -(2*far*near)/(far-near), 0,
        } };
    }

    pub inline fn ortho(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) Mat4 {
        return .{ .data = .{
            2.0/(r-l), 0, 0, 0,
            0, 2.0/(t-b), 0, 0,
            0, 0, -2.0/(f-n), 0,
            -(r+l)/(r-l), -(t+b)/(t-b), -(f+n)/(f-n), 1.0,
        } };
    }

    pub inline fn wishdir(fwd: f32, right: f32, yaw: f32) Vec3 {
        const fwd_vec  = Vec3.new(@sin(yaw), 0, -@cos(yaw));
        const side_vec = Vec3.new(@cos(yaw), 0,  @sin(yaw));
        return Vec3.add(Vec3.scale(fwd_vec, fwd), Vec3.scale(side_vec, right));
    }
};

pub const geo = struct {
    pub const Ray = struct {
        origin: math.Vec3, dir: math.Vec3,
        pub fn at(self: Ray, t: f32) math.Vec3 { return self.origin.add(self.dir.scale(t)); }
    };
    pub const Plane = struct {
        normal: math.Vec3, dist: f32,
        pub fn distToPoint(self: Plane, p: math.Vec3) f32 { return self.normal.dot(p) + self.dist; }
    };
    pub const Frustum = struct {
        planes: [6]Plane,
        pub fn fromCamera(eye: math.Vec3, fwd: math.Vec3, rt: math.Vec3, u: math.Vec3, fovy: f32, aspect: f32, near: f32, far: f32) Frustum {
            const hy = @tan(fovy * 0.5); const hx = hy * aspect; var p: [6]Plane = undefined;
            p[0] = .{ .normal = fwd, .dist = -(fwd.dot(eye) + near) }; p[1] = .{ .normal = fwd.neg(), .dist = fwd.dot(eye) + far };
            p[2] = .{ .normal = u.cross(fwd.add(rt.scale(hx))).normalize(), .dist = 0 }; p[3] = .{ .normal = fwd.sub(rt.scale(hx)).cross(u).normalize(), .dist = 0 };
            p[4] = .{ .normal = fwd.add(u.scale(hy)).cross(rt).normalize(), .dist = 0 }; p[5] = .{ .normal = rt.cross(fwd.sub(u.scale(hy))).normalize(), .dist = 0 };
            for (2..6) |i| p[i].dist = -p[i].normal.dot(eye);
            return .{ .planes = p };
        }
        pub fn containsAABB(self: Frustum, box: math.AABB) bool {
            for (self.planes) |p| {
                const pv = math.Vec3.new(if (p.normal.data[0]>=0) box.hi.data[0] else box.lo.data[0], if (p.normal.data[1]>=0) box.hi.data[1] else box.lo.data[1], if (p.normal.data[2]>=0) box.hi.data[2] else box.lo.data[2]);
                if (p.normal.dot(pv) + p.dist < 0) return false;
            }
            return true;
        }
    };
};

pub const phys = struct {
    pub const Hit = struct { normal: math.Vec3, dist: f32 };
    pub const Config = struct { gravity: f32=9.8, jump_speed: f32=5.0, max_speed: f32=6.0, air_speed: f32=1.0, accel: f32=50.0, friction: f32=6.0, slope_limit: f32=0.707, max_slides: u32=4, radius: f32=0.3, eye_height: f32=0.6, ground_snap: f32=0.05 };
    pub fn Body(comptime cfg: Config) type {
        return struct {
            const Self = @This();
            pos: math.Vec3 = math.Vec3.zero(), vel: math.Vec3 = math.Vec3.zero(), grounded: bool = false, yaw: f32 = 0, pitch: f32 = 0,
            pub fn eyePos(self: Self) math.Vec3 { return self.pos.add(math.Vec3.new(0, cfg.eye_height, 0)); }
            pub fn lookDir(self: Self) math.Vec3 {
                const sp = @sin(self.pitch); const cp = @cos(self.pitch); const sy = @sin(self.yaw); const cy = @cos(self.yaw);
                return math.Vec3.new(sy*cp, -sp, -cy*cp).normalize();
            }
            pub fn step(self: *Self, world: anytype, wish: math.Vec3, jump: bool, dt: f32) void {
                const ground_trace = world.cast(self.pos, math.Vec3.new(0, -1, 0), cfg.ground_snap);
                self.grounded = false; var ground_normal = math.Vec3.new(0, 1, 0);
                if (ground_trace) |h| { if (h.normal.data[1] > cfg.slope_limit) { self.grounded = true; ground_normal = h.normal; } }
                if (self.grounded) {
                    const vn = self.vel.dot(ground_normal); if (vn < 0) self.vel = self.vel.sub(ground_normal.scale(vn));
                    const spd = @sqrt(self.vel.data[0]*self.vel.data[0] + self.vel.data[2]*self.vel.data[2]);
                    if (spd > 0.1) { const drop = spd*cfg.friction*dt; const f = @max(0, spd-drop)/spd; self.vel.data[0] *= f; self.vel.data[2] *= f; } else { self.vel.data[0]=0; self.vel.data[2]=0; }
                } else { self.vel.data[1] -= cfg.gravity * dt; }
                if (jump and self.grounded) { self.vel.data[1] = cfg.jump_speed; self.grounded = false; }
                const wl = @sqrt(wish.data[0]*wish.data[0] + wish.data[2]*wish.data[2]);
                if (wl > 0) {
                    const wn = wish.scale(1.0 / wl); const top = if (self.grounded) cfg.max_speed*wl else @min(cfg.max_speed*wl, cfg.air_speed);
                    const cur = math.Vec3.new(self.vel.data[0], 0, self.vel.data[2]).dot(wn); const add = @min(cfg.accel*dt, @max(0, top-cur)); self.vel = self.vel.add(wn.scale(add));
                }
                self.slideMove(world, self.vel.scale(dt));
            }
            fn slideMove(self: *Self, world: anytype, delta: math.Vec3) void {
                var rem = delta;
                for (0..cfg.max_slides) |_| {
                    const l = rem.length(); const pos_mag = @max(@abs(self.pos.data[0]), @max(@abs(self.pos.data[1]), @abs(self.pos.data[2])));
                    const eps = std.math.floatEpsAt(f32, @max(1.0, pos_mag)); const margin = eps * 8192.0;
                    if (l < eps) break; const dir = rem.scale(1.0 / l);
                    const h = world.cast(self.pos, dir, l + margin) orelse { self.pos = self.pos.add(rem); break; };
                    const move_dist = @max(0, h.dist - eps);
                    if (move_dist > 0) { self.pos = self.pos.add(dir.scale(move_dist)); rem = rem.sub(dir.scale(@min(move_dist, l))); }
                    self.pos = self.pos.add(h.normal.scale(margin)); rem = clipVelocity(rem, h.normal); self.vel = clipVelocity(self.vel, h.normal);
                }
            }
            fn clipVelocity(in: math.Vec3, normal: math.Vec3) math.Vec3 {
                const backoff = in.dot(normal); if (backoff >= 0) return in; var out = in.sub(normal.scale(backoff));
                const res = out.dot(normal); if (res < 0) out = out.sub(normal.scale(res)); return out;
            }
        };
    }
};

pub const gfx = struct {
    pub const Vertex = extern struct { pos: [3]f32, color: [4]f32 };
    const MeshSlot = struct { vbo: gpu.Buffer, ibo: gpu.Buffer, idx_count: u32 };
    pub const Renderer = struct {
        pub const Handle = u32;
        device: gpu.Device, window: sdl.video.Window, pipeline: gpu.GraphicsPipeline, ui_pipeline: gpu.GraphicsPipeline,
        ui_handle: ?Handle = null,
        depth_tex: ?gpu.Texture = null, width: u32 = 0, height: u32 = 0, meshes: std.ArrayListUnmanaged(MeshSlot) = .{},
        alloc: std.mem.Allocator, cmd: ?gpu.CommandBuffer = null, render_pass: ?gpu.RenderPass = null,
        swapchain_tex: ?gpu.Texture = null, clear_color: [4]f32 = .{ 0.06, 0.07, 0.12, 1.0 },
        view: math.Mat4 = math.Mat4.identity(), proj: math.Mat4 = math.Mat4.identity(), frust: geo.Frustum = undefined,

        pub fn init(device: gpu.Device, window: sdl.video.Window, alloc: std.mem.Allocator) !Renderer {
            try device.claimWindow(window);
            const sc_fmt = try device.getSwapchainTextureFormat(window);
            const depth_fmt: gpu.TextureFormat = if (device.textureSupportsFormat(.depth32_float, .two_dimensional, .{ .depth_stencil_target = true })) .depth32_float else .depth16_unorm;
            const vert_shader = try device.createShader(.{ .code = @embedFile("shaders/triangle.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex, .num_uniform_buffers = 1 }); defer device.releaseShader(vert_shader);
            const frag_shader = try device.createShader(.{ .code = @embedFile("shaders/triangle.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment }); defer device.releaseShader(frag_shader);

            const v_attrs = [2]gpu.VertexAttribute{ .{ .location = 0, .buffer_slot = 0, .format = .f32x3, .offset = @offsetOf(Vertex, "pos") }, .{ .location = 1, .buffer_slot = 0, .format = .f32x4, .offset = @offsetOf(Vertex, "color") } };
            const v_desc = [1]gpu.VertexBufferDescription{.{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = .vertex }};
            const c_desc = [1]gpu.ColorTargetDescription{.{ .format = sc_fmt }};

            var pipe_info = gpu.GraphicsPipelineCreateInfo{
                .vertex_shader = vert_shader, .fragment_shader = frag_shader,
                .vertex_input_state = .{ .vertex_buffer_descriptions = &v_desc, .vertex_attributes = &v_attrs },
                .rasterizer_state = .{ .cull_mode = .back, .front_face = .counter_clockwise },
                .depth_stencil_state = .{ .compare = .less_or_equal, .enable_depth_test = true, .enable_depth_write = true },
                .target_info = .{ .color_target_descriptions = &c_desc, .depth_stencil_format = depth_fmt },
            };
            const pipeline = try device.createGraphicsPipeline(pipe_info);
            
            pipe_info.depth_stencil_state.enable_depth_test = false;
            pipe_info.depth_stencil_state.enable_depth_write = false;
            pipe_info.rasterizer_state.cull_mode = .none;
            const ui_pipeline = try device.createGraphicsPipeline(pipe_info);

            return .{ .device = device, .window = window, .pipeline = pipeline, .ui_pipeline = ui_pipeline, .alloc = alloc };
        }

        pub fn deinit(self: *Renderer) void {
            self.device.waitForIdle() catch {};
            for (self.meshes.items) |m| { self.device.releaseBuffer(m.vbo); self.device.releaseBuffer(m.ibo); }
            self.meshes.deinit(self.alloc);
            if (self.depth_tex) |t| self.device.releaseTexture(t);
            self.device.releaseGraphicsPipeline(self.pipeline);
            self.device.releaseGraphicsPipeline(self.ui_pipeline);
            self.device.releaseWindow(self.window); self.device.deinit();
        }

        pub fn cameraEuler(self: *Renderer, pos: math.Vec3, yaw: f32, pitch: f32, eye_height: f32, fovy: f32, aspect: f32, near: f32, far: f32) void {
            self.view = math.Mat4.viewMatrix(pos, yaw, pitch, eye_height); self.proj = math.perspective(fovy, aspect, near, far);
            const sp = @sin(pitch); const cp = @cos(pitch); const sy = @sin(yaw); const cy = @cos(yaw);
            const eye = pos.add(math.Vec3.new(0, eye_height, 0)); const fwd = math.Vec3.new(sy*cp, -sp, -cy*cp).normalize();
            const rt = math.Vec3.new(cy, 0, sy); const up = rt.cross(fwd);
            self.frust = geo.Frustum.fromCamera(eye, fwd, rt, up, fovy * 3.14159 / 180.0, aspect, near, far);
        }

        pub fn beginFrame(self: *Renderer) !bool {
            self.cmd = try self.device.acquireCommandBuffer();
            const tex, const w, const h = try self.cmd.?.waitAndAcquireSwapchainTexture(self.window);
            self.swapchain_tex = tex orelse return false;
            if (w != self.width or h != self.height or self.depth_tex == null) {
                self.width = w; self.height = h; if (self.depth_tex) |dt| self.device.releaseTexture(dt);
                const depth_fmt: gpu.TextureFormat = if (self.device.textureSupportsFormat(.depth32_float, .two_dimensional, .{ .depth_stencil_target = true })) .depth32_float else .depth16_unorm;
                self.depth_tex = try self.device.createTexture(.{ .format = depth_fmt, .usage = .{ .depth_stencil_target = true }, .width = w, .height = h, .layer_count_or_depth = 1, .num_levels = 1 });
            }
            self.render_pass = self.cmd.?.beginRenderPass(&.{.{ .texture = self.swapchain_tex.?, .clear_color = .{ .r = self.clear_color[0], .g = self.clear_color[1], .b = self.clear_color[2], .a = self.clear_color[3] }, .load = .clear, .store = .store }}, .{ .texture = self.depth_tex.?, .clear_depth = 1.0, .load = .clear, .store = .do_not_care, .stencil_load = .do_not_care, .stencil_store = .do_not_care, .cycle = false, .clear_stencil = 0 });
            self.render_pass.?.bindGraphicsPipeline(self.pipeline);
            return true;
        }

        pub fn endFrame(self: *Renderer) !void {
            if (self.render_pass) |rp| rp.end(); self.render_pass = null;
            if (self.cmd) |cmd| try cmd.submit(); self.cmd = null;
        }

        fn uploadBuffer(device: gpu.Device, data: []const u8, usage: gpu.BufferUsageFlags) !gpu.Buffer {
            const sz: u32 = @intCast(data.len); const buf = try device.createBuffer(.{ .usage = usage, .size = sz });
            const tbuf = try device.createTransferBuffer(.{ .usage = .upload, .size = sz }); const ptr = try device.mapTransferBuffer(tbuf, false);
            @memcpy(ptr[0..data.len], data); device.unmapTransferBuffer(tbuf);
            const cmd = try device.acquireCommandBuffer(); const copy = cmd.beginCopyPass();
            copy.uploadToBuffer(.{ .transfer_buffer = tbuf, .offset = 0 }, .{ .buffer = buf, .offset = 0, .size = sz }, false); copy.end();
            try cmd.submit(); try device.waitForIdle(); device.releaseTransferBuffer(tbuf); return buf;
        }

        pub fn upload(self: *Renderer, vert_bytes: []const u8, v_size: u32, idx_bytes: []const u8, i_count: u32) !Handle {
            _ = v_size; const h: Handle = @intCast(self.meshes.items.len);
            try self.meshes.append(self.alloc, .{ .vbo = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true }), .ibo = try uploadBuffer(self.device, idx_bytes, .{ .index = true }), .idx_count = i_count });
            return h;
        }

        pub fn updateMesh(self: *Renderer, handle: Handle, vert_bytes: []const u8, idx_bytes: []const u8, i_count: u32) !void {
            if (handle >= self.meshes.items.len) return;
            const new_vbo = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true }); const new_ibo = try uploadBuffer(self.device, idx_bytes, .{ .index = true });
            self.device.releaseBuffer(self.meshes.items[handle].vbo); self.device.releaseBuffer(self.meshes.items[handle].ibo);
            self.meshes.items[handle] = .{ .vbo = new_vbo, .ibo = new_ibo, .idx_count = i_count };
        }

        pub fn drawDirect(self: *Renderer, handle: Handle, model: math.Mat4, color: [4]f32) void {
            _ = color; if (handle >= self.meshes.items.len) return; const m = self.meshes.items[handle]; if (m.idx_count == 0) return;
            const rp = self.render_pass orelse return;
            rp.bindVertexBuffers(0, &.{.{ .buffer = m.vbo, .offset = 0 }}); rp.bindIndexBuffer(.{ .buffer = m.ibo, .offset = 0 }, .indices_32bit);
            const mvp = self.proj.mul(self.view).mul(model); self.cmd.?.pushVertexUniformData(0, std.mem.asBytes(&mvp));
            rp.drawIndexedPrimitives(m.idx_count, 1, 0, 0, 0);
        }

        pub fn drawUI(self: *Renderer, handle: Handle, win_w: f32, win_h: f32) void {
            if (handle >= self.meshes.items.len) return; const m = self.meshes.items[handle]; if (m.idx_count == 0) return;
            const rp = self.render_pass orelse return;
            rp.bindGraphicsPipeline(self.ui_pipeline);
            rp.bindVertexBuffers(0, &.{.{ .buffer = m.vbo, .offset = 0 }}); rp.bindIndexBuffer(.{ .buffer = m.ibo, .offset = 0 }, .indices_32bit);
            
            const ortho_mvp = math.ortho(0, win_w, win_h, 0, -1, 1);
            self.cmd.?.pushVertexUniformData(0, std.mem.asBytes(&ortho_mvp));
            rp.drawIndexedPrimitives(m.idx_count, 1, 0, 0, 0);
            rp.bindGraphicsPipeline(self.pipeline);
        }
    };
};

pub const Bsp = struct {
    const Self = @This(); const Vec3 = math.Vec3; const Plane = geo.Plane;
    pub const empty_leaf: u32 = 0xFFFF_FFFE; pub const solid_leaf: u32 = 0xFFFF_FFFF;
    pub inline fn isLeaf(i: u32) bool { return i >= empty_leaf; }
    pub inline fn isSolid(i: u32) bool { return i == solid_leaf; }
    pub inline fn isEmpty(i: u32) bool { return i == empty_leaf; }
    pub const SplitMode = enum { solid, empty };
    pub const Node = struct { plane: u32, front: u32, back: u32 };
    pub const PickResult = struct { node: u32, t: f32, pos: Vec3, normal: Vec3 };
    pub const ParentInfo = struct { idx: u32, is_front: bool };
    pub const EditOp = union(enum) { split: struct { parent: u32, is_front: bool, old_leaf: u32 }, translate: struct { plane_idx: u32, old_dist: f32 }, rotate: struct { plane_idx: u32, old_normal: Vec3, old_dist: f32 }, swap: struct { node: u32 }, toggle: struct { parent: u32, is_front: bool }, delete: struct { parent: u32, is_front: bool, node_idx: u32 } };

    nodes: std.MultiArrayList(Node) = .{}, planes: std.ArrayListUnmanaged(Plane) = .{}, alloc: std.mem.Allocator,
    render_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{}, render_indices: std.ArrayListUnmanaged(u32) = .{}, face_nodes: std.ArrayListUnmanaged(u32) = .{}, mesh_dirty: bool = true,
    debug_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{}, debug_indices: std.ArrayListUnmanaged(u32) = .{}, debug_dirty: bool = true,
    selected_node: ?u32 = null, undo_stack: std.ArrayListUnmanaged(EditOp) = .{},

    pub fn init(alloc: std.mem.Allocator) Self { return .{ .alloc = alloc }; }
    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.alloc); self.planes.deinit(self.alloc); self.render_verts.deinit(self.alloc); self.render_indices.deinit(self.alloc); self.face_nodes.deinit(self.alloc); self.debug_verts.deinit(self.alloc); self.debug_indices.deinit(self.alloc); self.undo_stack.deinit(self.alloc);
    }
    pub fn markDirty(self: *Self) void { self.mesh_dirty = true; self.debug_dirty = true; }
    fn addPlane(self: *Self, p: Plane) !u32 { const idx: u32 = @intCast(self.planes.items.len); try self.planes.append(self.alloc, p); return idx; }
    fn addNode(self: *Self, plane: u32, front: u32, back: u32) !u32 { const idx: u32 = @intCast(self.nodes.len); try self.nodes.append(self.alloc, .{ .plane = plane, .front = front, .back = back }); return idx; }
    pub fn initGroundPlane(self: *Self, height: f32) !void { const pi = try self.addPlane(.{ .normal = Vec3.new(0, 1, 0), .dist = -height }); _ = try self.addNode(pi, empty_leaf, solid_leaf); self.markDirty(); }

    pub fn editorSplit(self: *Self, point: Vec3, normal: Vec3, mode: SplitMode) !bool {
        if (self.nodes.len == 0) return false; const n = if (mode == .empty) normal.neg() else normal; const pi = try self.addPlane(.{ .normal = n, .dist = -n.dot(point) });
        const info = try self.splitLeaf(0, point, pi, mode) orelse return false; try self.undo_stack.append(self.alloc, .{ .split = .{ .parent = info.parent, .is_front = info.is_front, .old_leaf = info.old_leaf } });
        self.markDirty(); return true;
    }
    const SplitInfo = struct { parent: u32, is_front: bool, old_leaf: u32 };
    fn splitLeaf(self: *Self, node_idx: u32, point: Vec3, plane_idx: u32, mode: SplitMode) !?SplitInfo {
        if (isSolid(node_idx) or isEmpty(node_idx)) return null;
        const slice = self.nodes.slice(); const plane = self.planes.items[slice.items(.plane)[node_idx]]; const is_front = plane.distToPoint(point) >= 0; const child_val = if (is_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];
        if (isLeaf(child_val)) {
            if (mode == .solid and !isEmpty(child_val)) return null; if (mode == .empty and !isSolid(child_val)) return null;
            const f_child = if (mode == .solid) solid_leaf else empty_leaf; const b_child = if (mode == .solid) empty_leaf else solid_leaf;
            const nn = try self.addNode(plane_idx, f_child, b_child); if (is_front) slice.items(.front)[node_idx] = nn else slice.items(.back)[node_idx] = nn;
            return .{ .parent = node_idx, .is_front = is_front, .old_leaf = child_val };
        }
        return self.splitLeaf(child_val, point, plane_idx, mode);
    }

    pub fn translatePlane(self: *Self, node_idx: u32, delta: f32) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return; const pi = self.nodes.slice().items(.plane)[node_idx];
        const coalesce = if (self.undo_stack.items.len > 0) switch (self.undo_stack.items[self.undo_stack.items.len - 1]) { .translate => |t| t.plane_idx == pi, else => false } else false;
        if (!coalesce) try self.undo_stack.append(self.alloc, .{ .translate = .{ .plane_idx = pi, .old_dist = self.planes.items[pi].dist } });
        self.planes.items[pi].dist -= delta; self.markDirty();
    }
    pub fn rotatePlane(self: *Self, node_idx: u32, new_normal: Vec3) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return; const pi = self.nodes.slice().items(.plane)[node_idx]; const old = self.planes.items[pi]; const ref_point = old.normal.scale(-old.dist);
        const coalesce = if (self.undo_stack.items.len > 0) switch (self.undo_stack.items[self.undo_stack.items.len - 1]) { .rotate => |r| r.plane_idx == pi, else => false } else false;
        if (!coalesce) try self.undo_stack.append(self.alloc, .{ .rotate = .{ .plane_idx = pi, .old_normal = old.normal, .old_dist = old.dist } });
        self.planes.items[pi] = .{ .normal = new_normal, .dist = -new_normal.dot(ref_point) }; self.markDirty();
    }
    pub fn deleteNode(self: *Self, target: u32, promote_front: bool) !bool {
        if (target == 0 or isLeaf(target) or target >= self.nodes.len) return false; const parent = self.findParent(target) orelse return false; const slice = self.nodes.slice(); const promoted = if (promote_front) slice.items(.front)[target] else slice.items(.back)[target];
        try self.undo_stack.append(self.alloc, .{ .delete = .{ .parent = parent.idx, .is_front = parent.is_front, .node_idx = target } });
        if (parent.is_front) slice.items(.front)[parent.idx] = promoted else slice.items(.back)[parent.idx] = promoted;
        if (self.selected_node) |sel| if (sel == target) { self.selected_node = null; }; self.markDirty(); return true;
    }
    pub fn swapChildren(self: *Self, node_idx: u32) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return; try self.undo_stack.append(self.alloc, .{ .swap = .{ .node = node_idx } }); const slice = self.nodes.slice(); const tmp = slice.items(.front)[node_idx]; slice.items(.front)[node_idx] = slice.items(.back)[node_idx]; slice.items(.back)[node_idx] = tmp; self.markDirty();
    }
    pub fn toggleLeaf(self: *Self, node_idx: u32, toggle_front: bool) !bool {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return false; const slice = self.nodes.slice(); const child = if (toggle_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx]; if (!isLeaf(child)) return false;
        try self.undo_stack.append(self.alloc, .{ .toggle = .{ .parent = node_idx, .is_front = toggle_front } });
        if (toggle_front) slice.items(.front)[node_idx] = if (isSolid(child)) empty_leaf else solid_leaf else slice.items(.back)[node_idx] = if (isSolid(child)) empty_leaf else solid_leaf;
        self.markDirty(); return true;
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
        }
        self.selected_node = null; self.markDirty(); return true;
    }
    pub fn findParent(self: *const Self, target: u32) ?ParentInfo { if (target == 0 or self.nodes.len == 0) return null; return self.findParentWalk(0, target); }
    fn findParentWalk(self: *const Self, current: u32, target: u32) ?ParentInfo {
        if (isLeaf(current)) return null; const s = self.nodes.slice();
        if (s.items(.front)[current] == target) return .{ .idx = current, .is_front = true };
        if (s.items(.back)[current] == target) return .{ .idx = current, .is_front = false };
        return self.findParentWalk(s.items(.front)[current], target) orelse self.findParentWalk(s.items(.back)[current], target);
    }

    pub fn rayPick(self: *const Self, origin: Vec3, dir: Vec3) ?PickResult {
        if (self.render_indices.items.len < 3 or self.face_nodes.items.len == 0) return null; var best_t: f32 = std.math.inf(f32); var best_node: u32 = 0; var best_normal = Vec3.zero(); const tris = self.render_indices.items.len / 3;
        for (0..tris) |ti| {
            const v0 = posVec(self.render_verts.items[self.render_indices.items[ti * 3]].pos); const v1 = posVec(self.render_verts.items[self.render_indices.items[ti * 3 + 1]].pos); const v2 = posVec(self.render_verts.items[self.render_indices.items[ti * 3 + 2]].pos);
            if (rayTriHit(origin, dir, v0, v1, v2)) |t| { if (t < best_t) { best_t = t; best_node = self.face_nodes.items[ti]; best_normal = v1.sub(v0).cross(v2.sub(v0)).normalize(); } }
        }
        if (best_t < std.math.inf(f32)) return .{ .node = best_node, .t = best_t, .pos = origin.add(dir.scale(best_t)), .normal = best_normal }; return null;
    }
    inline fn posVec(p: [3]f32) Vec3 { return Vec3.new(p[0], p[1], p[2]); }
    fn rayTriHit(o: Vec3, d: Vec3, v0: Vec3, v1: Vec3, v2: Vec3) ?f32 {
        const e1 = v1.sub(v0); const e2 = v2.sub(v0); const h = d.cross(e2); const a = e1.dot(h); if (@abs(a) < 1e-7) return null;
        const f = 1.0 / a; const s = o.sub(v0); const u = f * s.dot(h); if (u < 0 or u > 1) return null; const q = s.cross(e1); const v = f * d.dot(q); if (v < 0 or u + v > 1) return null; const t = f * e2.dot(q); return if (t > 1e-5) t else null;
    }

    pub const TraceResult = struct { normal: Vec3, dist: f32 };
    const TraceState = struct { fraction: f32 = 1.0, normal: Vec3 = Vec3.zero(), hit: bool = false };
    const trace_eps: f32 = 0.001;

    pub fn trace(self: *const Self, start: Vec3, dir: Vec3, max_d: f32, radius: f32) ?TraceResult {
        if (self.nodes.len == 0) return null; const end = start.add(dir.scale(max_d)); var st = TraceState{}; _ = self.traceRecursive(0, 0, 1, start, end, radius, &st);
        if (st.hit and st.fraction < 1.0) return .{ .normal = st.normal, .dist = st.fraction * max_d }; return null;
    }
    fn traceRecursive(self: *const Self, idx: u32, p1f: f32, p2f: f32, p1: Vec3, p2: Vec3, radius: f32, st: *TraceState) bool {
        if (st.fraction <= p1f) return true; if (isEmpty(idx)) return true; if (isSolid(idx)) return true;
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[idx]]; const fc = s.items(.front)[idx]; const bc = s.items(.back)[idx]; const t1 = plane.distToPoint(p1); const t2 = plane.distToPoint(p2);
        if (t1 >= radius and t2 >= radius) return self.traceRecursive(fc, p1f, p2f, p1, p2, radius, st); if (t1 < -radius and t2 < -radius) return self.traceRecursive(bc, p1f, p2f, p1, p2, radius, st);
        const front_first = t1 >= t2; const near = if (front_first) fc else bc; const far = if (front_first) bc else fc; const delta = t1 - t2; var frac: f32 = 0; const eps = std.math.floatEpsAt(f32, @max(@abs(t1), @abs(t2)));
        if (@abs(delta) > eps) frac = if (front_first) (t1 - radius - trace_eps) / delta else (t1 + radius + trace_eps) / delta; frac = std.math.clamp(frac, 0, 1);
        const midf = p1f + (p2f - p1f) * frac; const mid = Vec3.lerp(p1, p2, frac);
        if (!self.traceRecursive(near, p1f, midf, p1, mid, radius, st)) return false;
        if (self.sphereInSolid(far, mid, radius)) { if (midf < st.fraction) { st.fraction = @max(0, midf); st.normal = if (front_first) plane.normal else plane.normal.neg(); st.hit = true; } return false; }
        return self.traceRecursive(far, midf, p2f, mid, p2, radius, st);
    }
    fn sphereInSolid(self: *const Self, idx: u32, p: Vec3, radius: f32) bool {
        if (isSolid(idx)) return true; if (isEmpty(idx)) return false;
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[idx]]; const d = plane.distToPoint(p);
        if (d > radius) return self.sphereInSolid(s.items(.front)[idx], p, radius); if (d < -radius) return self.sphereInSolid(s.items(.back)[idx], p, radius);
        return self.sphereInSolid(s.items(.front)[idx], p, radius) or self.sphereInSolid(s.items(.back)[idx], p, radius);
    }

    const max_poly: usize = 48; const base_size: f32 = 2000.0; const max_depth: usize = 64; const split_eps: f32 = 1e-4; const ClipInfo = struct { plane: u32, flip: bool };
    pub fn rebuildMesh(self: *Self) !void {
        self.render_verts.clearRetainingCapacity(); self.render_indices.clearRetainingCapacity(); self.face_nodes.clearRetainingCapacity();
        if (self.nodes.len == 0) return; var stack: [max_depth]ClipInfo = undefined; try self.meshNode(0, &stack, 0); self.mesh_dirty = false;
    }
    fn meshNode(self: *Self, idx: u32, stack: *[max_depth]ClipInfo, depth: usize) !void {
        if (isLeaf(idx)) return;
        const s = self.nodes.slice(); const pi = s.items(.plane)[idx]; const fc = s.items(.front)[idx]; const bc = s.items(.back)[idx]; const plane = self.planes.items[pi];
        var poly: [max_poly]Vec3 = undefined; var count: usize = 4; makeBasePoly(plane, base_size, poly[0..4]);
        for (stack[0..depth]) |a| {
            var cp = self.planes.items[a.plane]; if (a.flip) { cp.normal = cp.normal.neg(); cp.dist = -cp.dist; } var out: [max_poly]Vec3 = undefined; count = clipConvex(poly[0..count], cp, &out); if (count < 3) break; @memcpy(poly[0..count], out[0..count]);
        }
        if (count >= 3) try self.filterFront(poly[0..count], fc, bc, plane, idx);
        if (depth < max_depth) { stack[depth] = .{ .plane = pi, .flip = false }; try self.meshNode(fc, stack, depth + 1); stack[depth] = .{ .plane = pi, .flip = true }; try self.meshNode(bc, stack, depth + 1); }
    }
    fn filterFront(self: *Self, verts: []const Vec3, front_node: u32, back_node: u32, split_plane: Plane, src: u32) !void {
        if (isSolid(front_node)) return self.filterBack(verts, back_node, split_plane, true, src); if (isEmpty(front_node)) return self.filterBack(verts, back_node, split_plane, false, src);
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[front_node]]; var fv: [max_poly]Vec3 = undefined; var bv: [max_poly]Vec3 = undefined; const res = splitConvex(verts, plane, &fv, &bv);
        if (res.f >= 3) try self.filterFront(fv[0..res.f], s.items(.front)[front_node], back_node, split_plane, src); if (res.b >= 3) try self.filterFront(bv[0..res.b], s.items(.back)[front_node], back_node, split_plane, src);
    }
    fn filterBack(self: *Self, verts: []const Vec3, back_node: u32, split_plane: Plane, front_solid: bool, src: u32) !void {
        if (isSolid(back_node)) { if (!front_solid) try self.pushFace(verts, split_plane, false, src); return; } if (isEmpty(back_node)) { if (front_solid) try self.pushFace(verts, split_plane, true, src); return; }
        const s = self.nodes.slice(); const plane = self.planes.items[s.items(.plane)[back_node]]; var fv: [max_poly]Vec3 = undefined; var bv: [max_poly]Vec3 = undefined; const res = splitConvex(verts, plane, &fv, &bv);
        if (res.f >= 3) try self.filterBack(fv[0..res.f], s.items(.front)[back_node], split_plane, front_solid, src); if (res.b >= 3) try self.filterBack(bv[0..res.b], s.items(.back)[back_node], split_plane, front_solid, src);
    }
    fn pushFace(self: *Self, verts: []const Vec3, plane: Plane, flip: bool, src: u32) !void {
        if (verts.len < 3) return; const face_n = if (flip) plane.normal.neg() else plane.normal; const is_sel = self.selected_node != null and self.selected_node.? == src; const color = if (is_sel) selColor(face_n) else normalColor(face_n); const base: u32 = @intCast(self.render_verts.items.len);
        if (flip) { var i: usize = verts.len; while (i > 0) { i -= 1; try self.render_verts.append(self.alloc, .{ .pos = .{ verts[i].data[0], verts[i].data[1], verts[i].data[2] }, .color = color }); } } else { for (verts) |v| try self.render_verts.append(self.alloc, .{ .pos = .{ v.data[0], v.data[1], v.data[2] }, .color = color }); }
        for (2..verts.len) |i| { try self.render_indices.append(self.alloc, base); try self.render_indices.append(self.alloc, base + @as(u32, @intCast(i - 1))); try self.render_indices.append(self.alloc, base + @as(u32, @intCast(i))); try self.face_nodes.append(self.alloc, src); }
    }
    pub fn rebuildDebugMesh(self: *Self) !void {
        self.debug_verts.clearRetainingCapacity(); self.debug_indices.clearRetainingCapacity(); if (self.nodes.len == 0) return; var stack: [max_depth]ClipInfo = undefined; try self.debugNode(0, &stack, 0); self.debug_dirty = false;
    }
    fn debugNode(self: *Self, idx: u32, stack: *[max_depth]ClipInfo, depth: usize) !void {
        if (isLeaf(idx)) return;
        const s = self.nodes.slice(); const pi = s.items(.plane)[idx]; const fc = s.items(.front)[idx]; const bc = s.items(.back)[idx]; const plane = self.planes.items[pi]; var poly: [max_poly]Vec3 = undefined; var count: usize = 4; makeBasePoly(plane, base_size, poly[0..4]);
        for (stack[0..depth]) |a| { var cp = self.planes.items[a.plane]; if (a.flip) { cp.normal = cp.normal.neg(); cp.dist = -cp.dist; } var out: [max_poly]Vec3 = undefined; count = clipConvex(poly[0..count], cp, &out); if (count < 3) break; @memcpy(poly[0..count], out[0..count]); }
        if (count >= 3) {
            const is_sel = self.selected_node != null and self.selected_node.? == idx; const color = if (is_sel) [4]f32{ 1.0, 0.15, 0.05, 1.0 } else depthColor(depth); const off = plane.normal.scale(0.05); try self.pushDebugFace(poly[0..count], off, color); try self.pushDebugFace(poly[0..count], off.neg(), color);
        }
        if (depth < max_depth) { stack[depth] = .{ .plane = pi, .flip = false }; try self.debugNode(fc, stack, depth + 1); stack[depth] = .{ .plane = pi, .flip = true }; try self.debugNode(bc, stack, depth + 1); }
    }
    fn pushDebugFace(self: *Self, verts: []const Vec3, offset: Vec3, color: [4]f32) !void {
        if (verts.len < 3) return; const base: u32 = @intCast(self.debug_verts.items.len); for (verts) |v| { const p = v.add(offset); try self.debug_verts.append(self.alloc, .{ .pos = .{ p.data[0], p.data[1], p.data[2] }, .color = color }); }
        for (2..verts.len) |i| { const ii: u32 = @intCast(i); try self.debug_indices.append(self.alloc, base); try self.debug_indices.append(self.alloc, base + ii - 1); try self.debug_indices.append(self.alloc, base + ii); try self.debug_indices.append(self.alloc, base); try self.debug_indices.append(self.alloc, base + ii); try self.debug_indices.append(self.alloc, base + ii - 1); }
    }
    fn makeBasePoly(plane: Plane, size: f32, out: []Vec3) void {
        const n = plane.normal; const ref: Vec3 = if (@abs(n.data[1]) < 0.9) Vec3.new(0, 1, 0) else Vec3.new(1, 0, 0); const t1 = n.cross(ref).normalize(); const t2 = n.cross(t1).normalize(); const c = n.scale(-plane.dist);
        out[0] = c.sub(t1.scale(size)).sub(t2.scale(size)); out[1] = c.add(t1.scale(size)).sub(t2.scale(size)); out[2] = c.add(t1.scale(size)).add(t2.scale(size)); out[3] = c.sub(t1.scale(size)).add(t2.scale(size));
    }
    fn splitConvex(verts: []const Vec3, plane: Plane, fv: *[max_poly]Vec3, bv: *[max_poly]Vec3) struct { f: usize, b: usize } {
        if (verts.len < 3) return .{ .f = 0, .b = 0 }; var f: usize = 0; var b: usize = 0; var dists: [max_poly]f32 = undefined; var has_front = false; var has_back = false;
        for (verts, 0..) |v, i| { dists[i] = plane.distToPoint(v); if (dists[i] > split_eps) has_front = true; if (dists[i] < -split_eps) has_back = true; }
        if (!has_back) { @memcpy(fv[0..verts.len], verts); return .{ .f = verts.len, .b = 0 }; } if (!has_front) { @memcpy(bv[0..verts.len], verts); return .{ .f = 0, .b = verts.len }; }
        for (0..verts.len) |i| {
            const p1 = verts[i]; const p2 = verts[(i + 1) % verts.len]; const d1 = dists[i]; const d2 = dists[(i + 1) % verts.len];
            if (d1 >= -split_eps and f < max_poly) { fv[f] = p1; f += 1; } if (d1 <= split_eps and b < max_poly) { bv[b] = p1; b += 1; }
            if ((d1 > split_eps and d2 < -split_eps) or (d1 < -split_eps and d2 > split_eps)) { const mid = Vec3.lerp(p1, p2, d1 / (d1 - d2)); if (f < max_poly) { fv[f] = mid; f += 1; } if (b < max_poly) { bv[b] = mid; b += 1; } }
        }
        return .{ .f = if (f >= 3) f else 0, .b = if (b >= 3) b else 0 };
    }
    fn clipConvex(verts: []const Vec3, plane: Plane, out: *[max_poly]Vec3) usize {
        if (verts.len < 3) return 0; var n: usize = 0;
        for (0..verts.len) |i| {
            const a = verts[i]; const b = verts[(i + 1) % verts.len]; const da = plane.distToPoint(a); const db = plane.distToPoint(b);
            if (da >= -split_eps) { if (n < max_poly) { out[n] = a; n += 1; } if (db < -split_eps and n < max_poly) { out[n] = Vec3.lerp(a, b, da / (da - db)); n += 1; } } else if (db >= -split_eps and n < max_poly) { out[n] = Vec3.lerp(a, b, da / (da - db)); n += 1; }
        }
        return if (n >= 3) n else 0;
    }
    fn normalColor(n: Vec3) [4]f32 { const sun = Vec3.new(0.4, 0.7, -0.5).normalize(); const d = @max(0.15, n.dot(sun)); return .{ d * 0.55, d * 0.55, d * 0.6, 1.0 }; }
    fn selColor(n: Vec3) [4]f32 { const sun = Vec3.new(0.4, 0.7, -0.5).normalize(); const d = @max(0.3, n.dot(sun)); return .{ d * 0.95, d * 0.35, d * 0.1, 1.0 }; }
    fn depthColor(depth: usize) [4]f32 { const lut = [_][4]f32{ .{ 0.8, 0.15, 0.1, 1.0 }, .{ 0.85, 0.5, 0.1, 1.0 }, .{ 0.8, 0.8, 0.15, 1.0 }, .{ 0.2, 0.75, 0.2, 1.0 }, .{ 0.15, 0.7, 0.75, 1.0 }, .{ 0.2, 0.3, 0.85, 1.0 }, .{ 0.6, 0.2, 0.8, 1.0 }, .{ 0.8, 0.2, 0.7, 1.0 } }; return lut[depth % lut.len]; }
};
