//! gpu_sdl3.zig — SDL3 GPU backend fulfilling gfx.Renderer(Gpu) contract

const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;
const eng = @import("engine");
const Mat4 = eng.Mat4;

const vert_spv = @embedFile("shaders/triangle.vert.spv");
const frag_spv = @embedFile("shaders/triangle.frag.spv");

const MeshInfo = struct { idx_offset: u32, idx_count: u32, vtx_offset: i32 };

pub const Gpu = struct {
    pub const Handle = u32;

    device:        gpu.Device,
    window:        sdl.video.Window,
    pipeline:      gpu.GraphicsPipeline,
    depth_tex:     ?gpu.Texture = null,
    width:         u32 = 0,
    height:        u32 = 0,

    vbo:    ?gpu.Buffer = null,
    ibo:    ?gpu.Buffer = null,
    meshes: std.ArrayListUnmanaged(MeshInfo) = .{},
    alloc:  std.mem.Allocator,

    cmd:           ?gpu.CommandBuffer = null,
    render_pass:   ?gpu.RenderPass    = null,
    swapchain_tex: ?gpu.Texture       = null,

    // ── init ──────────────────────────────────────────────────────

    pub fn init(device: gpu.Device, window: sdl.video.Window, alloc: std.mem.Allocator) !Gpu {
        try device.claimWindow(window);
        const sc_fmt = try device.getSwapchainTextureFormat(window);

        const depth_fmt: gpu.TextureFormat =
            if (device.textureSupportsFormat(
                    .depth32_float, .two_dimensional, .{ .depth_stencil_target = true }))
                .depth32_float
            else
                .depth16_unorm;

        const vert_shader = try device.createShader(.{
            .code                = vert_spv,
            .entry_point         = "main",
            .format              = .{ .spirv = true },
            .stage               = .vertex,
            .num_uniform_buffers = 1,
        });
        defer device.releaseShader(vert_shader);

        const frag_shader = try device.createShader(.{
            .code        = frag_spv,
            .entry_point = "main",
            .format      = .{ .spirv = true },
            .stage       = .fragment,
        });
        defer device.releaseShader(frag_shader);

        const pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader   = vert_shader,
            .fragment_shader = frag_shader,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &.{.{
                    .slot       = 0,
                    .pitch      = @sizeOf(eng.Vertex),
                    .input_rate = .vertex,
                }},
                .vertex_attributes = &.{
                    .{ .location = 0, .buffer_slot = 0, .format = .f32x3,
                       .offset = @offsetOf(eng.Vertex, "pos") },
                    .{ .location = 1, .buffer_slot = 0, .format = .f32x4,
                       .offset = @offsetOf(eng.Vertex, "color") },
                },
            },
            .rasterizer_state = .{
                .cull_mode  = .back,
                .front_face = .counter_clockwise,
            },
            .depth_stencil_state = .{
                .compare            = .less_or_equal,
                .enable_depth_test  = true,
                .enable_depth_write = true,
            },
            .target_info = .{
                .color_target_descriptions = &.{.{ .format = sc_fmt }},
                .depth_stencil_format      = depth_fmt,
            },
        });

        return .{
            .device   = device,
            .window   = window,
            .pipeline = pipeline,
            .alloc    = alloc,
        };
    }

    // ── deinit ────────────────────────────────────────────────────

    pub fn deinit(self: *Gpu) void {
        self.device.waitForIdle() catch {};
        self.meshes.deinit(self.alloc);
        if (self.vbo)       |b| self.device.releaseBuffer(b);
        if (self.ibo)       |b| self.device.releaseBuffer(b);
        if (self.depth_tex) |t| self.device.releaseTexture(t);
        self.device.releaseGraphicsPipeline(self.pipeline);
        self.device.releaseWindow(self.window);
        self.device.deinit();
    }

    // ── helpers ───────────────────────────────────────────────────

    /// Create a depth texture.  layer_count_or_depth and num_levels must
    /// be >= 1 — SDL3 asserts on 0.
    fn makeDepthTexture(self: *Gpu, w: u32, h: u32) !gpu.Texture {
        const depth_fmt: gpu.TextureFormat =
            if (self.device.textureSupportsFormat(
                    .depth32_float, .two_dimensional, .{ .depth_stencil_target = true }))
                .depth32_float
            else
                .depth16_unorm;
        return self.device.createTexture(.{
            .format               = depth_fmt,
            .usage                = .{ .depth_stencil_target = true },
            .width                = w,
            .height               = h,
            .layer_count_or_depth = 1,
            .num_levels           = 1,
        });
    }

    fn uploadBuffer(device: gpu.Device, data: []const u8, usage: gpu.BufferUsageFlags) !gpu.Buffer {
        const sz: u32 = @intCast(data.len);
        const buf  = try device.createBuffer(.{ .usage = usage, .size = sz });
        const tbuf = try device.createTransferBuffer(.{ .usage = .upload, .size = sz });
        const ptr  = try device.mapTransferBuffer(tbuf, false);
        @memcpy(ptr[0..data.len], data);
        device.unmapTransferBuffer(tbuf);

        const cmd  = try device.acquireCommandBuffer();
        const copy = cmd.beginCopyPass();
        copy.uploadToBuffer(
            .{ .transfer_buffer = tbuf, .offset = 0 },
            .{ .buffer = buf, .offset = 0, .size = sz },
            false,
        );
        copy.end();
        try cmd.submit();
        try device.waitForIdle();
        device.releaseTransferBuffer(tbuf);
        return buf;
    }

    // ── Contract methods ──────────────────────────────────────────

    pub fn upload(
        self:       *Gpu,
        vert_bytes: []const u8,
        v_size:     u32,
        idx_bytes:  []const u8,
        i_count:    u32,
    ) !Handle {
        _ = v_size;
        const h: Handle = @intCast(self.meshes.items.len);
        const vb = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true });
        const ib = try uploadBuffer(self.device, idx_bytes,  .{ .index  = true });
        if (self.vbo) |old| self.device.releaseBuffer(old);
        if (self.ibo) |old| self.device.releaseBuffer(old);
        self.vbo = vb;
        self.ibo = ib;
        try self.meshes.append(self.alloc, .{
            .idx_offset = 0,
            .idx_count  = i_count,
            .vtx_offset = 0,
        });
        return h;
    }

    pub fn release(self: *Gpu, _: Handle) void { _ = self; }

    pub fn beginFrame(self: *Gpu) !bool {
        self.cmd = try self.device.acquireCommandBuffer();
        const tex, const w, const h =
            try self.cmd.?.waitAndAcquireSwapchainTexture(self.window);
        self.swapchain_tex = tex orelse return false;

        // Recreate depth texture whenever the window is resized.
        if (w != self.width or h != self.height or self.depth_tex == null) {
            self.width  = w;
            self.height = h;
            if (self.depth_tex) |dt| self.device.releaseTexture(dt);
            self.depth_tex = try self.makeDepthTexture(w, h);
        }

        self.render_pass = self.cmd.?.beginRenderPass(
            &.{gpu.ColorTargetInfo{
                .texture     = self.swapchain_tex.?,
                .clear_color = .{ .r = 0.06, .g = 0.07, .b = 0.12, .a = 1 },
                .load        = .clear,
                .store       = .store,
            }},
            gpu.DepthStencilTargetInfo{
                .texture       = self.depth_tex.?,
                .clear_depth   = 1.0,
                .load          = .clear,
                .store         = .do_not_care,
                .stencil_load  = .do_not_care,
                .stencil_store = .do_not_care,
                .cycle         = false,
                .clear_stencil = 0,
            },
        );

        const rp = self.render_pass.?;
        rp.bindGraphicsPipeline(self.pipeline);
        if (self.vbo) |vb| rp.bindVertexBuffers(0, &.{.{ .buffer = vb, .offset = 0 }});
        if (self.ibo) |ib| rp.bindIndexBuffer(.{ .buffer = ib, .offset = 0 }, .indices_32bit);
        return true;
    }

    pub fn endFrame(self: *Gpu) !void {
        if (self.render_pass) |rp| rp.end();
        self.render_pass = null;
        if (self.cmd) |cmd| try cmd.submit();
        self.cmd = null;
    }

    pub fn draw(self: *Gpu, handle: Handle, mvp: Mat4, color: [4]f32) void {
        _ = color;
        if (handle >= self.meshes.items.len) return;
        const info = self.meshes.items[handle];
        const cmd  = self.cmd          orelse return;
        const rp   = self.render_pass  orelse return;
        cmd.pushVertexUniformData(0, std.mem.asBytes(&mvp));
        rp.drawIndexedPrimitives(info.idx_count, 1, info.idx_offset, info.vtx_offset, 0);
    }
};

// ── Box mesh helper ───────────────────────────────────────────────

pub fn boxVertices(aabb: eng.AABB, color: [4]f32) struct {
    verts:   [24]eng.Vertex,
    indices: [36]u32,
} {
    const mn = aabb.lo.data;
    const mx = aabb.hi.data;
    const uv = [24][3]f32{
        .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 }, // -Y
        .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 }, // +Y
        .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 }, // +Z
        .{ 1, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 }, // -Z
        .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 }, // -X
        .{ 1, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 }, // +X
    };
    var verts: [24]eng.Vertex = undefined;
    for (0..24) |i| {
        verts[i] = .{
            .pos = .{
                mn[0] + uv[i][0] * (mx[0] - mn[0]),
                mn[1] + uv[i][1] * (mx[1] - mn[1]),
                mn[2] + uv[i][2] * (mx[2] - mn[2]),
            },
            .color = color,
        };
    }
    return .{
        .verts   = verts,
        .indices = .{
             0,  1,  2,  0,  2,  3,
             4,  5,  6,  4,  6,  7,
             8,  9, 10,  8, 10, 11,
            12, 13, 14, 12, 14, 15,
            16, 17, 18, 16, 18, 19,
            20, 21, 22, 20, 22, 23,
        },
    };
}
