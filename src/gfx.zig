const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;
const math = @import("math.zig");

pub const Vertex = extern struct {
    pos: [3]math.Unit,
    color: [4]f32,
};

const MeshSlot = struct {
    vbo: gpu.Buffer,
    ibo: gpu.Buffer,
    idx_count: u32,
};

pub const Renderer = struct {
    pub const Handle = u32;

    device: gpu.Device,
    window: sdl.video.Window,
    pipe_3d: gpu.GraphicsPipeline,
    pipe_2d: gpu.GraphicsPipeline,
    depth_tex: ?gpu.Texture = null,
    width: u32 = 0,
    height: u32 = 0,
    meshes: std.ArrayListUnmanaged(MeshSlot) = .{},
    alloc: std.mem.Allocator,
    cmd: ?gpu.CommandBuffer = null,
    render_pass: ?gpu.RenderPass = null,
    swapchain_tex: ?gpu.Texture = null,
    clear_color: [4]f32 = .{ 0.06, 0.07, 0.12, 1.0 },

    pub fn init(device: gpu.Device, window: sdl.video.Window, alloc: std.mem.Allocator, vert_spv: []const u8, frag_spv: []const u8) !Renderer {
        try device.claimWindow(window);
        const sc_fmt = try device.getSwapchainTextureFormat(window);

        const supports_depth32 = device.textureSupportsFormat(
            .depth32_float,
            .two_dimensional,
            .{ .depth_stencil_target = true }
        );
        const depth_fmt: gpu.TextureFormat = if (supports_depth32) .depth32_float else .depth16_unorm;

        const vert_shader = try device.createShader(.{
            .code = vert_spv,
            .entry_point = "main",
            .format = .{ .spirv = true },
            .stage = .vertex,
            .num_uniform_buffers = 1,
        });
        defer device.releaseShader(vert_shader);

        const frag_shader = try device.createShader(.{
            .code = frag_spv,
            .entry_point = "main",
            .format = .{ .spirv = true },
            .stage = .fragment,
        });
        defer device.releaseShader(frag_shader);

        const vert_desc = gpu.VertexBufferDescription{
            .slot = 0,
            .pitch = @sizeOf(Vertex),
            .input_rate = .vertex,
        };

        const attr_pos = gpu.VertexAttribute{
            .location = 0,
            .buffer_slot = 0,
            .format = .i32x3,
            .offset = @offsetOf(Vertex, "pos"),
        };

        const attr_col = gpu.VertexAttribute{
            .location = 1,
            .buffer_slot = 0,
            .format = .f32x4,
            .offset = @offsetOf(Vertex, "color"),
        };

        const target_desc = gpu.ColorTargetDescription{
            .format = sc_fmt,
        };

        var pipe_info = gpu.GraphicsPipelineCreateInfo{
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &.{vert_desc},
                .vertex_attributes = &.{ attr_pos, attr_col },
            },
            .rasterizer_state = .{
                .cull_mode = .back,
                .front_face = .counter_clockwise,
            },
            .depth_stencil_state = .{
                .compare = .less_or_equal,
                .enable_depth_test = true,
                .enable_depth_write = true,
            },
            .target_info = .{
                .color_target_descriptions = &.{target_desc},
                .depth_stencil_format = depth_fmt,
            },
        };

        const pipe_3d = try device.createGraphicsPipeline(pipe_info);

        pipe_info.depth_stencil_state.enable_depth_test = false;
        pipe_info.depth_stencil_state.enable_depth_write = false;
        pipe_info.rasterizer_state.cull_mode = .none;

        const pipe_2d = try device.createGraphicsPipeline(pipe_info);

        return .{
            .device = device,
            .window = window,
            .pipe_3d = pipe_3d,
            .pipe_2d = pipe_2d,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.device.waitForIdle() catch {};

        for (self.meshes.items) |m| {
            self.device.releaseBuffer(m.vbo);
            self.device.releaseBuffer(m.ibo);
        }

        self.meshes.deinit(self.alloc);

        if (self.depth_tex) |t| {
            self.device.releaseTexture(t);
        }

        self.device.releaseGraphicsPipeline(self.pipe_3d);
        self.device.releaseGraphicsPipeline(self.pipe_2d);
        self.device.releaseWindow(self.window);
        self.device.deinit();
    }

    pub fn beginFrame(self: *Renderer) !bool {
        self.cmd = try self.device.acquireCommandBuffer();

        const tex, const w, const h = try self.cmd.?.waitAndAcquireSwapchainTexture(self.window);
        self.swapchain_tex = tex orelse return false;

        if (w != self.width or h != self.height or self.depth_tex == null) {
            self.width = w;
            self.height = h;

            if (self.depth_tex) |dt| {
                self.device.releaseTexture(dt);
            }

            const supports_depth32 = self.device.textureSupportsFormat(
                .depth32_float,
                .two_dimensional,
                .{ .depth_stencil_target = true }
            );

            self.depth_tex = try self.device.createTexture(.{
                .format = if (supports_depth32) .depth32_float else .depth16_unorm,
                .usage = .{ .depth_stencil_target = true },
                .width = w,
                .height = h,
                .layer_count_or_depth = 1,
                .num_levels = 1,
            });
        }

        const color_target = gpu.ColorTargetInfo{
            .texture = self.swapchain_tex.?,
            .clear_color = .{
                .r = self.clear_color[0],
                .g = self.clear_color[1],
                .b = self.clear_color[2],
                .a = self.clear_color[3],
            },
            .load = .clear,
            .store = .store,
        };

        const depth_target = gpu.DepthStencilTargetInfo{
            .texture = self.depth_tex.?,
            .clear_depth = 1.0,
            .load = .clear,
            .store = .do_not_care,
            .stencil_load = .do_not_care,
            .stencil_store = .do_not_care,
            .cycle = false,
            .clear_stencil = 0,
        };

        self.render_pass = self.cmd.?.beginRenderPass(&.{color_target}, depth_target);

        return true;
    }

    pub fn endFrame(self: *Renderer) !void {
        if (self.render_pass) |rp| {
            rp.end();
        }
        self.render_pass = null;

        if (self.cmd) |cmd| {
            try cmd.submit();
        }
        self.cmd = null;
    }

    fn uploadBuffer(device: gpu.Device, data: []const u8, usage: gpu.BufferUsageFlags) !gpu.Buffer {
        const buf = try device.createBuffer(.{ .usage = usage, .size = @intCast(data.len) });
        const tbuf = try device.createTransferBuffer(.{ .usage = .upload, .size = @intCast(data.len) });

        const ptr = try device.mapTransferBuffer(tbuf, false);
        @memcpy(ptr[0..data.len], data);
        device.unmapTransferBuffer(tbuf);

        const cmd = try device.acquireCommandBuffer();
        const copy = cmd.beginCopyPass();

        copy.uploadToBuffer(
            .{ .transfer_buffer = tbuf, .offset = 0 },
            .{ .buffer = buf, .offset = 0, .size = @intCast(data.len) },
            false
        );

        copy.end();
        try cmd.submit();
        try device.waitForIdle();

        device.releaseTransferBuffer(tbuf);
        return buf;
    }

    pub fn upload(self: *Renderer, vert_bytes: []const u8, v_size: u32, idx_bytes: []const u8, i_count: u32) !Handle {
        _ = v_size;
        const h: Handle = @intCast(self.meshes.items.len);

        try self.meshes.append(self.alloc, .{
            .vbo = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true }),
            .ibo = try uploadBuffer(self.device, idx_bytes, .{ .index = true }),
            .idx_count = i_count,
        });

        return h;
    }

    pub fn updateMesh(self: *Renderer, handle: Handle, vert_bytes: []const u8, idx_bytes: []const u8, i_count: u32) !void {
        if (handle >= self.meshes.items.len) return;

        const new_vbo = try uploadBuffer(self.device, vert_bytes, .{ .vertex = true });
        const new_ibo = try uploadBuffer(self.device, idx_bytes, .{ .index = true });

        self.device.releaseBuffer(self.meshes.items[handle].vbo);
        self.device.releaseBuffer(self.meshes.items[handle].ibo);

        self.meshes.items[handle] = .{
            .vbo = new_vbo,
            .ibo = new_ibo,
            .idx_count = i_count,
        };
    }

    pub fn draw(self: *Renderer, handle: Handle, mvp: [16]f32, is_overlay: bool) void {
        if (handle >= self.meshes.items.len) return;

        const m = self.meshes.items[handle];
        if (m.idx_count == 0) return;

        const rp = self.render_pass orelse return;

        rp.bindGraphicsPipeline(if (is_overlay) self.pipe_2d else self.pipe_3d);
        rp.bindVertexBuffers(0, &.{.{ .buffer = m.vbo, .offset = 0 }});
        rp.bindIndexBuffer(.{ .buffer = m.ibo, .offset = 0 }, .indices_32bit);

        self.cmd.?.pushVertexUniformData(0, std.mem.asBytes(&mvp));
        rp.drawIndexedPrimitives(m.idx_count, 1, 0, 0, 0);
    }
};
