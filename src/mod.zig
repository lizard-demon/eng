// src/mod.zig — kami: a minimal single-file SDL3 GPU engine
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
const std = @import("std");

inline fn cStruct(comptime T: type, fields: anytype) T {
    var res = std.mem.zeroes(T);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |f| {
        const DestT = @TypeOf(@field(res, f.name));
        const ValT = @TypeOf(@field(fields, f.name));
        if (comptime @typeInfo(DestT) == .int and (@typeInfo(ValT) == .int or @typeInfo(ValT) == .comptime_int)) {
            @field(res, f.name) = @intCast(@field(fields, f.name));
        } else {
            @field(res, f.name) = @field(fields, f.name);
        }
    }
    return res;
}

// ============================================================================
// 1. DEVICE: Window, Swapchain, Command Context, and Resource Factories
// ============================================================================
pub const Device = struct {
    window: *c.SDL_Window,
    gpu: *c.SDL_GPUDevice,
    depth_tex: ?*c.SDL_GPUTexture = null,
    cmd: ?*c.SDL_GPUCommandBuffer = null,
    pass: ?*c.SDL_GPURenderPass = null,
    sc_format: c.SDL_GPUTextureFormat,
    cur_sc_tex: ?*c.SDL_GPUTexture = null,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(title: [:0]const u8, w: i32, h: i32) !Device {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return error.InitFailed;
        const win = c.SDL_CreateWindow(title.ptr, w, h, c.SDL_WINDOW_RESIZABLE) orelse return error.WindowFailed;
        const gpu = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse return error.DeviceFailed;
        if (!c.SDL_ClaimWindowForGPUDevice(gpu, win)) return error.ClaimFailed;

        _ = c.SDL_SetGPUSwapchainParameters(gpu, win, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_IMMEDIATE);
        return .{ .window = win, .gpu = gpu, .sc_format = c.SDL_GetGPUSwapchainTextureFormat(gpu, win) };
    }

    pub fn deinit(self: *Device) void {
        _ = c.SDL_WaitForGPUIdle(self.gpu);
        if (self.depth_tex) |dt| c.SDL_ReleaseGPUTexture(self.gpu, dt);
        c.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
        c.SDL_DestroyGPUDevice(self.gpu);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn beginFrame(self: *Device) !bool {
        self.cmd = c.SDL_AcquireGPUCommandBuffer(self.gpu) orelse return false;
        var uw: u32 = 0; var uh: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(self.cmd.?, self.window, &self.cur_sc_tex, &uw, &uh)) {
            _ = c.SDL_CancelGPUCommandBuffer(self.cmd.?);
            self.cmd = null; return false;
        }

        if (self.depth_tex == null or self.width != uw or self.height != uh) {
            if (self.depth_tex) |d| c.SDL_ReleaseGPUTexture(self.gpu, d);
            self.width = uw; self.height = uh;
            self.depth_tex = c.SDL_CreateGPUTexture(self.gpu, &cStruct(c.SDL_GPUTextureCreateInfo, .{
                .type = c.SDL_GPU_TEXTURETYPE_2D, .format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
                .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET, .width = uw, .height = uh,
                .layer_count_or_depth = 1, .num_levels = 1,
            }));
        }
        return true;
    }

    pub fn beginRenderPass(self: *Device, clear_color: [4]f32, use_depth: bool) void {
        var color_tgt = cStruct(c.SDL_GPUColorTargetInfo, .{
            .texture = self.cur_sc_tex, .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_STORE,
            .clear_color = c.SDL_FColor{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] },
        });
        var depth_tgt = cStruct(c.SDL_GPUDepthStencilTargetInfo, .{
            .texture = self.depth_tex, .clear_depth = 1.0,
            .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        });
        self.pass = c.SDL_BeginGPURenderPass(self.cmd.?, &color_tgt, 1, if (use_depth) &depth_tgt else null);
    }

    pub fn endFrame(self: *Device) void {
        if (self.pass) |p| c.SDL_EndGPURenderPass(p);
        if (self.cmd) |cmd| _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        self.pass = null; self.cmd = null; self.cur_sc_tex = null;
    }

    pub fn createPipeline(self: *Device, cfg: PipelineCfg) !*c.SDL_GPUGraphicsPipeline {
        const vs = c.SDL_CreateGPUShader(self.gpu, &cStruct(c.SDL_GPUShaderCreateInfo, .{ .code = cfg.vert_spv.ptr, .code_size = cfg.vert_spv.len, .entrypoint = "main", .format = c.SDL_GPU_SHADERFORMAT_SPIRV, .stage = c.SDL_GPU_SHADERSTAGE_VERTEX, .num_uniform_buffers = 1 })) orelse return error.ShaderFailed;
        defer c.SDL_ReleaseGPUShader(self.gpu, vs);
        const fs = c.SDL_CreateGPUShader(self.gpu, &cStruct(c.SDL_GPUShaderCreateInfo, .{ .code = cfg.frag_spv.ptr, .code_size = cfg.frag_spv.len, .entrypoint = "main", .format = c.SDL_GPU_SHADERFORMAT_SPIRV, .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT, .num_uniform_buffers = 0, .num_samplers = @as(u32, if (cfg.blend) 1 else 0) })) orelse return error.ShaderFailed;
        defer c.SDL_ReleaseGPUShader(self.gpu, fs);

        var v_desc = c.SDL_GPUVertexBufferDescription{ .slot = 0, .pitch = cfg.vertex_stride, .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 };
        var pipe_info = cStruct(c.SDL_GPUGraphicsPipelineCreateInfo, .{
            .vertex_shader = vs, .fragment_shader = fs, .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .vertex_input_state = cStruct(c.SDL_GPUVertexInputState, .{ .vertex_buffer_descriptions = &v_desc, .num_vertex_buffers = 1, .vertex_attributes = cfg.attributes.ptr, .num_vertex_attributes = cfg.attributes.len }),
            .rasterizer_state = cStruct(c.SDL_GPURasterizerState, .{ .cull_mode = if (cfg.depth_test) c.SDL_GPU_CULLMODE_BACK else c.SDL_GPU_CULLMODE_NONE, .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, .fill_mode = c.SDL_GPU_FILLMODE_FILL }),
            .depth_stencil_state = cStruct(c.SDL_GPUDepthStencilState, .{ .enable_depth_test = cfg.depth_test, .enable_depth_write = cfg.depth_test, .compare_op = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL }),
        });
        var target = cStruct(c.SDL_GPUColorTargetDescription, .{ .format = self.sc_format });
        if (cfg.blend) {
            target.blend_state = cStruct(c.SDL_GPUColorTargetBlendState, .{ .enable_blend = true, .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA, .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, .color_blend_op = c.SDL_GPU_BLENDOP_ADD, .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE, .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO, .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD });
        }
        pipe_info.target_info = cStruct(c.SDL_GPUGraphicsPipelineTargetInfo, .{ .color_target_descriptions = &target, .num_color_targets = 1, .has_depth_stencil_target = cfg.depth_test, .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT });
        return c.SDL_CreateGPUGraphicsPipeline(self.gpu, &pipe_info) orelse error.PipelineFailed;
    }

    pub fn createTexture(self: *Device, width: u32, height: u32, format: c.SDL_GPUTextureFormat, pixels: []const u8) !*c.SDL_GPUTexture {
        const tex = c.SDL_CreateGPUTexture(self.gpu, &cStruct(c.SDL_GPUTextureCreateInfo, .{ .type = c.SDL_GPU_TEXTURETYPE_2D, .format = format, .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER, .width = width, .height = height, .layer_count_or_depth = 1, .num_levels = 1 })) orelse return error.TexFailed;
        const tbuf = c.SDL_CreateGPUTransferBuffer(self.gpu, &cStruct(c.SDL_GPUTransferBufferCreateInfo, .{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = pixels.len })) orelse return error.TransferFailed;
        defer c.SDL_ReleaseGPUTransferBuffer(self.gpu, tbuf);

        const ptr = c.SDL_MapGPUTransferBuffer(self.gpu, tbuf, false) orelse return error.MapFailed;
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..pixels.len], pixels);
        c.SDL_UnmapGPUTransferBuffer(self.gpu, tbuf);

        const cmd = c.SDL_AcquireGPUCommandBuffer(self.gpu) orelse return error.CmdFailed;
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return error.CopyPassFailed;
        var loc = cStruct(c.SDL_GPUTextureTransferInfo, .{ .transfer_buffer = tbuf });
        var reg = cStruct(c.SDL_GPUTextureRegion, .{ .texture = tex, .w = width, .h = height, .d = 1 });

        c.SDL_UploadToGPUTexture(copy_pass, &loc, &reg, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return tex;
    }

    pub fn createSampler(self: *Device, min_f: c.SDL_GPUFilter, mag_f: c.SDL_GPUFilter, mip_m: c.SDL_GPUSamplerMipmapMode) !*c.SDL_GPUSampler {
        return c.SDL_CreateGPUSampler(self.gpu, &cStruct(c.SDL_GPUSamplerCreateInfo, .{ .min_filter = min_f, .mag_filter = mag_f, .mipmap_mode = mip_m, .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE, .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE })) orelse error.SamplerFailed;
    }
};

// ============================================================================
// 2. RESOURCES: Buffers, Streaming Buffers, Pipeline Config
// ============================================================================
fn uploadBytes(dev: *Device, transfer: *c.SDL_GPUTransferBuffer, pass: *c.SDL_GPUCopyPass, dst: *c.SDL_GPUBuffer, bytes: []const u8, cycle: bool) !void {
    const p = c.SDL_MapGPUTransferBuffer(dev.gpu, transfer, cycle) orelse return error.MapFailed;
    @memcpy(@as([*]u8, @ptrCast(p))[0..bytes.len], bytes);
    c.SDL_UnmapGPUTransferBuffer(dev.gpu, transfer);

    var loc = cStruct(c.SDL_GPUTransferBufferLocation, .{ .transfer_buffer = transfer });
    var reg = cStruct(c.SDL_GPUBufferRegion, .{ .buffer = dst, .size = bytes.len });
    c.SDL_UploadToGPUBuffer(pass, &loc, &reg, cycle);
}

inline fn pushUniform(cmd: *c.SDL_GPUCommandBuffer, slot: u32, data: anytype) void {
    c.SDL_PushGPUVertexUniformData(cmd, slot, &data, @sizeOf(@TypeOf(data)));
}

pub const PipelineCfg = struct {
    vert_spv: []const u8, frag_spv: []const u8,
    vertex_stride: u32, attributes: []const c.SDL_GPUVertexAttribute,
    depth_test: bool = true, blend: bool = false,
};

pub const Buffer = struct {
    handle: *c.SDL_GPUBuffer,
    usage: c.SDL_GPUBufferUsageFlags,
    size: u32,

    pub fn create(dev: *Device, data: []const u8, usage: c.SDL_GPUBufferUsageFlags) !Buffer {
        const handle = c.SDL_CreateGPUBuffer(dev.gpu, &cStruct(c.SDL_GPUBufferCreateInfo, .{ .usage = usage, .size = data.len })) orelse return error.BufferFailed;
        const tbuf = c.SDL_CreateGPUTransferBuffer(dev.gpu, &cStruct(c.SDL_GPUTransferBufferCreateInfo, .{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = data.len })) orelse return error.TransferFailed;

        const cmd = c.SDL_AcquireGPUCommandBuffer(dev.gpu) orelse return error.CmdFailed;
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return error.CopyFailed;
        try uploadBytes(dev, tbuf, copy_pass, handle, data, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);

        c.SDL_ReleaseGPUTransferBuffer(dev.gpu, tbuf);
        return .{ .handle = handle, .usage = usage, .size = @intCast(data.len) };
    }
    pub fn destroy(self: Buffer, dev: *Device) void { c.SDL_ReleaseGPUBuffer(dev.gpu, self.handle); }
};

pub const Stream = struct {
    handle: ?*c.SDL_GPUBuffer = null,
    transfer: ?*c.SDL_GPUTransferBuffer = null,
    cap: usize = 0,
    usage: c.SDL_GPUBufferUsageFlags,

    pub fn init(usage: c.SDL_GPUBufferUsageFlags) Stream { return .{ .usage = usage }; }
    pub fn deinit(self: *Stream, dev: *Device) void {
        if (self.handle) |h| c.SDL_ReleaseGPUBuffer(dev.gpu, h);
        if (self.transfer) |t| c.SDL_ReleaseGPUTransferBuffer(dev.gpu, t);
        self.handle = null; self.transfer = null; self.cap = 0;
    }
    fn ensure(self: *Stream, dev: *Device, needed: usize) !void {
        if (self.handle != null and needed <= self.cap) return;
        const new_cap = ((needed + needed / 2) + 4095) / 4096 * 4096;

        const nh = c.SDL_CreateGPUBuffer(dev.gpu, &cStruct(c.SDL_GPUBufferCreateInfo, .{ .usage = self.usage, .size = new_cap })) orelse return error.BufferFailed;
        const nt = c.SDL_CreateGPUTransferBuffer(dev.gpu, &cStruct(c.SDL_GPUTransferBufferCreateInfo, .{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = new_cap })) orelse { c.SDL_ReleaseGPUBuffer(dev.gpu, nh); return error.TransferFailed; };

        if (self.handle) |h| c.SDL_ReleaseGPUBuffer(dev.gpu, h);
        if (self.transfer) |t| c.SDL_ReleaseGPUTransferBuffer(dev.gpu, t);
        self.handle = nh; self.transfer = nt; self.cap = new_cap;
    }
    pub fn upload(self: *Stream, dev: *Device, copy_pass: *c.SDL_GPUCopyPass, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.ensure(dev, bytes.len);
        try uploadBytes(dev, self.transfer.?, copy_pass, self.handle.?, bytes, true);
    }
};

// ============================================================================
// 3. ENGINE SYSTEMS: Input, Scene, UI
// ============================================================================
pub fn Input(comptime Action: type) type {
    const Mask = std.meta.Int(.unsigned, @max(8, @typeInfo(Action).@"enum".fields.len));

    return struct {
        keys_held: [*c]const bool = null,
        keys_pressed: std.StaticBitSet(512) = std.StaticBitSet(512).initEmpty(),
        keys_released: std.StaticBitSet(512) = std.StaticBitSet(512).initEmpty(),
        
        // Upgraded to f32 to retain SDL3 sub-pixel precision
        mouse_x: f32 = 0, mouse_y: f32 = 0, 
        mouse_dx: f32 = 0, mouse_dy: f32 = 0, 
        scroll_x: f32 = 0, scroll_y: f32 = 0,
        
        mouse_held: [5]bool = [_]bool{false} ** 5, mouse_pressed: [5]bool = [_]bool{false} ** 5, mouse_released: [5]bool = [_]bool{false} ** 5,
        mouse_locked: bool = false, quit: bool = false,

        sensitivity: f32 = 1.0,

        // --- Action LUTs & Buffers ---
        key_lut: [512]?Action = .{null} ** 512,
        mouse_lut: [5]?Action = .{null} ** 5,
        wheel_lut: [2]?Action = .{null} ** 2, // 0 = Up, 1 = Down
        
        pending: Mask = 0,
        current: Mask = 0,
        prev: Mask = 0,

        pub fn init() @This() { return .{}; }
        
        pub fn bindKey(self: *@This(), a: Action, sc: c.SDL_Scancode) void { self.key_lut[@intCast(sc)] = a; }
        pub fn bindMouse(self: *@This(), a: Action, btn: u8) void { self.mouse_lut[button(btn)] = a; }
        pub fn bindWheel(self: *@This(), a: Action, up: bool) void { self.wheel_lut[if (up) 0 else 1] = a; }

        inline fn trigger(self: *@This(), a: Action) void {
            self.pending |= (@as(Mask, 1) << @intFromEnum(a));
        }

        pub inline fn tick(self: *@This()) void {
            self.prev = self.current;
            self.current = self.pending;
            self.pending = 0;
        }

        pub inline fn consume(self: *@This(), a: Action, held: bool) bool {
            const mask = @as(Mask, 1) << @intFromEnum(a);
            if (((self.current | self.prev) & mask) != 0) {
                self.current &= ~mask;
                self.prev &= ~mask;
                return true;
            }
            return held;
        }

        pub fn update(self: *@This()) void {
            self.mouse_dx = 0; self.mouse_dy = 0; self.scroll_x = 0; self.scroll_y = 0;
            self.keys_pressed = std.StaticBitSet(512).initEmpty(); self.keys_released = std.StaticBitSet(512).initEmpty();
            @memset(&self.mouse_pressed, false); @memset(&self.mouse_released, false);
            self.keys_held = c.SDL_GetKeyboardState(null);

            var mx: f32 = 0; var my: f32 = 0;
            const mstate = c.SDL_GetMouseState(&mx, &my);
            self.mouse_held = .{ (mstate & c.SDL_BUTTON_LMASK) != 0, (mstate & c.SDL_BUTTON_MMASK) != 0, (mstate & c.SDL_BUTTON_RMASK) != 0, (mstate & c.SDL_BUTTON_X1MASK) != 0, (mstate & c.SDL_BUTTON_X2MASK) != 0 };
            
            // Retain raw float pixel coords
            self.mouse_x = mx; 
            self.mouse_y = my;

            var ev: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&ev)) {
                switch (ev.type) {
                    c.SDL_EVENT_QUIT => self.quit = true,
                    c.SDL_EVENT_KEY_DOWN => { 
                        const idx: usize = @intCast(ev.key.scancode); 
                        if (idx < 512 and !ev.key.repeat) { 
                            self.keys_pressed.set(idx);
                            if (self.key_lut[idx]) |a| self.trigger(a);
                        }
                    },
                    c.SDL_EVENT_KEY_UP => { 
                        const idx: usize = @intCast(ev.key.scancode); 
                        if (idx < 512) self.keys_released.set(idx); 
                    },
                    c.SDL_EVENT_MOUSE_BUTTON_DOWN => { 
                        const idx = button(ev.button.button); 
                        if (idx < 5) {
                            self.mouse_pressed[idx] = true;
                            if (self.mouse_lut[idx]) |a| self.trigger(a);
                        }
                    },
                    c.SDL_EVENT_MOUSE_BUTTON_UP => { 
                        const idx = button(ev.button.button); 
                        if (idx < 5) self.mouse_released[idx] = true; 
                    },
                    c.SDL_EVENT_MOUSE_MOTION => if (self.mouse_locked) { 
                        // Absorb high-precision float deltas scaled by user sensitivity
                        self.mouse_dx += ev.motion.xrel * self.sensitivity; 
                        self.mouse_dy += ev.motion.yrel * self.sensitivity; 
                    },
                    c.SDL_EVENT_MOUSE_WHEEL => { 
                        self.scroll_x += ev.wheel.x; 
                        self.scroll_y += ev.wheel.y;
                        if (ev.wheel.y > 0) { if (self.wheel_lut[0]) |a| self.trigger(a); }
                        else if (ev.wheel.y < 0) { if (self.wheel_lut[1]) |a| self.trigger(a); }
                    },
                    else => {},
                }
            }
        }

        pub fn setLock(self: *@This(), win: *c.SDL_Window, lock: bool) void {
            self.mouse_locked = lock;
            if (lock) { _ = c.SDL_HideCursor(); _ = c.SDL_SetWindowRelativeMouseMode(win, true); }
            else { _ = c.SDL_ShowCursor(); _ = c.SDL_SetWindowRelativeMouseMode(win, false); }
        }
        
        pub fn key(self: *const @This(), sc: c.SDL_Scancode) bool { return if (self.keys_held) |k| k[@intCast(sc)] else false; }
        pub fn keyPressed(self: *const @This(), sc: c.SDL_Scancode) bool { return self.keys_pressed.isSet(@intCast(sc)); }
        pub fn keyReleased(self: *const @This(), sc: c.SDL_Scancode) bool { return self.keys_released.isSet(@intCast(sc)); }
        pub fn mouse(self: *const @This(), btn: u8) bool { const idx = button(btn); return if (idx < 5) self.mouse_held[idx] else false; }
        pub fn mousePressed(self: *const @This(), btn: u8) bool { const idx = button(btn); return if (idx < 5) self.mouse_pressed[idx] else false; }
        pub fn mouseReleased(self: *const @This(), btn: u8) bool { const idx = button(btn); return if (idx < 5) self.mouse_released[idx] else false; }
        
        fn button(btn: u8) usize { return switch (btn) { c.SDL_BUTTON_LEFT => 0, c.SDL_BUTTON_MIDDLE => 1, c.SDL_BUTTON_RIGHT => 2, c.SDL_BUTTON_X1 => 3, c.SDL_BUTTON_X2 => 4, else => 999 }; }
    };
}

pub const Scene = struct {
    pub const Vertex = extern struct { pos: [3]i32, color: [4]f32 };
    pub const Handle = u32;

    dev: *Device,
    pipe: *c.SDL_GPUGraphicsPipeline,
    meshes: std.ArrayListUnmanaged(struct { vbo: Buffer, ibo: Buffer, idx_count: u32 }) = .{},
    alloc: std.mem.Allocator,
    clear_color: [4]f32 = .{ 0.06, 0.07, 0.12, 1.0 },

    pub fn init(dev: *Device, alloc: std.mem.Allocator, vert_spv: []const u8, frag_spv: []const u8) !Scene {
        const attrs = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_INT3, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "color") }
        };
        const pipe = try dev.createPipeline(.{ .vert_spv = vert_spv, .frag_spv = frag_spv, .vertex_stride = @sizeOf(Vertex), .attributes = &attrs, .depth_test = true });
        return .{ .dev = dev, .pipe = pipe, .alloc = alloc };
    }

    pub fn deinit(self: *Scene) void {
        for (self.meshes.items) |m| { m.vbo.destroy(self.dev); m.ibo.destroy(self.dev); }
        self.meshes.deinit(self.alloc);
        c.SDL_ReleaseGPUGraphicsPipeline(self.dev.gpu, self.pipe);
    }

    pub fn upload(self: *Scene, vert_bytes: []const u8, idx_bytes: []const u8) !Handle {
        const h: Handle = @intCast(self.meshes.items.len);
        try self.meshes.append(self.alloc, .{
            .vbo = try Buffer.create(self.dev, vert_bytes, c.SDL_GPU_BUFFERUSAGE_VERTEX),
            .ibo = try Buffer.create(self.dev, idx_bytes, c.SDL_GPU_BUFFERUSAGE_INDEX),
            .idx_count = @intCast(idx_bytes.len / @sizeOf(u32)),
        });
        return h;
    }

    pub fn draw(self: *Scene, handle: Handle, mvp: [16]f32) void {
        if (handle >= self.meshes.items.len) return;
        const m = self.meshes.items[handle];
        if (m.idx_count == 0) return;
        const rp = self.dev.pass orelse return;

        c.SDL_BindGPUGraphicsPipeline(rp, self.pipe);
        const v_bind = [_]c.SDL_GPUBufferBinding{.{ .buffer = m.vbo.handle, .offset = 0 }};
        c.SDL_BindGPUVertexBuffers(rp, 0, &v_bind, 1);
        const i_bind = c.SDL_GPUBufferBinding{ .buffer = m.ibo.handle, .offset = 0 };
        c.SDL_BindGPUIndexBuffer(rp, &i_bind, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

        pushUniform(self.dev.cmd.?, 0, mvp);
        c.SDL_DrawGPUIndexedPrimitives(rp, m.idx_count, 1, 0, 0, 0);
    }
};

const font = struct {
    const pixels: [128 * 5 * 5 * 4]u8 = init: {
        @setEvalBranchQuota(100000);
        var f = [_][5]u8{.{ 0, 0, 0, 0, 0 }} ** 128;
        f['!']=.{0b00100,0b00100,0b00100,0b00000,0b00100}; f['"']=.{0b01010,0b01010,0b00000,0b00000,0b00000};
        f['#']=.{0b01010,0b11111,0b01010,0b11111,0b01010}; f['$']=.{0b01110,0b10100,0b01110,0b00101,0b01110};
        f['%']=.{0b10001,0b00010,0b00100,0b01000,0b10001}; f['&']=.{0b01000,0b10100,0b01000,0b10101,0b01101};
        f['\'']=.{0b00100,0b00100,0b00000,0b00000,0b00000}; f['(']=.{0b00010,0b00100,0b00100,0b00100,0b00010};
        f[')']=.{0b01000,0b00100,0b00100,0b00100,0b01000}; f['*']=.{0b00000,0b10101,0b01110,0b10101,0b00000};
        f['+']=.{0b00000,0b00100,0b01110,0b00100,0b00000}; f[',']=.{0b00000,0b00000,0b00000,0b00100,0b01000};
        f['-']=.{0b00000,0b00000,0b01110,0b00000,0b00000}; f['.']=.{0b00000,0b00000,0b00000,0b00000,0b00100};
        f['/']=.{0b00001,0b00010,0b00100,0b01000,0b10000}; f['0']=.{0b01110,0b10001,0b10001,0b10001,0b01110};
        f['1']=.{0b00100,0b01100,0b00100,0b00100,0b01110}; f['2']=.{0b01110,0b00001,0b01110,0b10000,0b01110};
        f['3']=.{0b01110,0b00001,0b00110,0b00001,0b01110}; f['4']=.{0b10001,0b10001,0b01111,0b00001,0b00001};
        f['5']=.{0b01111,0b10000,0b01110,0b00001,0b01110}; f['6']=.{0b01110,0b10000,0b11110,0b10001,0b01110};
        f['7']=.{0b11111,0b00001,0b00010,0b00100,0b00100}; f['8']=.{0b01110,0b10001,0b01110,0b10001,0b01110};
        f['9']=.{0b01110,0b10001,0b01111,0b00001,0b01110}; f[':']=.{0b00000,0b00100,0b00000,0b00100,0b00000};
        f[';']=.{0b00000,0b00100,0b00000,0b00100,0b01000}; f['<']=.{0b00010,0b00100,0b01000,0b00100,0b00010};
        f['=']=.{0b00000,0b01110,0b00000,0b01110,0b00000}; f['>']=.{0b01000,0b00100,0b00010,0b00100,0b01000};
        f['?']=.{0b01110,0b10001,0b00010,0b00100,0b00100}; f['@']=.{0b01110,0b10001,0b10101,0b10111,0b01110};
        f['A']=.{0b01110,0b10001,0b11111,0b10001,0b10001}; f['B']=.{0b11110,0b10001,0b11110,0b10001,0b11110};
        f['C']=.{0b01110,0b10001,0b10000,0b10001,0b01110}; f['D']=.{0b11110,0b10001,0b10001,0b10001,0b11110};
        f['E']=.{0b11111,0b10000,0b11110,0b10000,0b11111}; f['F']=.{0b11111,0b10000,0b11110,0b10000,0b10000};
        f['G']=.{0b01110,0b10000,0b10011,0b10001,0b01110}; f['H']=.{0b10001,0b10001,0b11111,0b10001,0b10001};
        f['I']=.{0b01110,0b00100,0b00100,0b00100,0b01110}; f['J']=.{0b00111,0b00010,0b00010,0b10010,0b01100};
        f['K']=.{0b10001,0b10010,0b11100,0b10010,0b10001}; f['L']=.{0b10000,0b10000,0b10000,0b10000,0b11111};
        f['M']=.{0b10001,0b11011,0b10101,0b10001,0b10001}; f['N']=.{0b10001,0b11001,0b10101,0b10011,0b10001};
        f['O']=.{0b01110,0b10001,0b10001,0b10001,0b01110}; f['P']=.{0b11110,0b10001,0b11110,0b10000,0b10000};
        f['Q']=.{0b01110,0b10001,0b10101,0b10010,0b01101}; f['R']=.{0b11110,0b10001,0b11110,0b10100,0b10011};
        f['S']=.{0b01110,0b10000,0b01110,0b00001,0b01110}; f['T']=.{0b11111,0b00100,0b00100,0b00100,0b00100};
        f['U']=.{0b10001,0b10001,0b10001,0b10001,0b01110}; f['V']=.{0b10001,0b10001,0b10001,0b01010,0b00100};
        f['W']=.{0b10001,0b10001,0b10101,0b11011,0b10001}; f['X']=.{0b10001,0b01010,0b00100,0b01010,0b10001};
        f['Y']=.{0b10001,0b01010,0b00100,0b00100,0b00100}; f['Z']=.{0b00000,0b11111,0b00100,0b01000,0b11111};
        f['[']=.{0b01110,0b01000,0b01000,0b01000,0b01110}; f['\\']=.{0b10000,0b01000,0b00100,0b00010,0b00001};
        f[']']=.{0b01110,0b00010,0b00010,0b00010,0b01110}; f['^']=.{0b00100,0b01010,0b10001,0b00000,0b00000};
        f['_']=.{0b00000,0b00000,0b00000,0b00000,0b11111}; f['`']=.{0b01000,0b00100,0b00000,0b00000,0b00000};
        f['a']=.{0b00000,0b01110,0b10001,0b10011,0b01101}; f['b']=.{0b10000,0b10000,0b11110,0b10001,0b11110};
        f['c']=.{0b00000,0b01110,0b10000,0b10000,0b01110}; f['d']=.{0b00001,0b00001,0b01111,0b10001,0b01111};
        f['e']=.{0b00000,0b01110,0b11111,0b10000,0b01110}; f['f']=.{0b00110,0b01000,0b11110,0b01000,0b01000};
        f['g']=.{0b00000,0b01111,0b10001,0b01111,0b00001}; f['h']=.{0b10000,0b10000,0b11110,0b10001,0b10001};
        f['i']=.{0b00100,0b00000,0b00100,0b00100,0b00100}; f['j']=.{0b00010,0b00000,0b00010,0b10010,0b01100};
        f['k']=.{0b10000,0b10000,0b10010,0b11100,0b10010}; f['l']=.{0b01100,0b00100,0b00100,0b00100,0b01110};
        f['m']=.{0b00000,0b11010,0b10101,0b10101,0b10101}; f['n']=.{0b00000,0b11110,0b10001,0b10001,0b10001};
        f['o']=.{0b00000,0b01110,0b10001,0b10001,0b01110}; f['p']=.{0b00000,0b11110,0b10001,0b11110,0b10000};
        f['q']=.{0b00000,0b01111,0b10001,0b01111,0b00001}; f['r']=.{0b00000,0b10110,0b11000,0b10000,0b10000};
        f['s']=.{0b00000,0b01110,0b10000,0b01110,0b00001}; f['t']=.{0b01000,0b11100,0b01000,0b01000,0b00110};
        f['u']=.{0b00000,0b10001,0b10001,0b10001,0b01111}; f['v']=.{0b00000,0b10001,0b10001,0b01010,0b00100};
        f['w']=.{0b00000,0b10001,0b10101,0b10101,0b01010}; f['x']=.{0b00000,0b10001,0b01010,0b00100,0b10001};
        f['y']=.{0b00000,0b10001,0b10001,0b01111,0b00001}; f['z']=.{0b00000,0b11111,0b00100,0b01000,0b11111};
        f['{']=.{0b00110,0b01000,0b10000,0b01000,0b00110}; f['|']=.{0b00100,0b00100,0b00000,0b00100,0b00100};
        f['}']=.{0b01100,0b00010,0b00001,0b00010,0b01100}; f['~']=.{0b01010,0b10101,0b00000,0b00000,0b00000};
        f[127]=.{0b11111,0b11111,0b11111,0b11111,0b11111};

        var px = [_]u8{0} ** (128 * 5 * 5 * 4);
        for (0..128) |ch| {
            for (0..5) |y| {
                const row = f[ch][y];
                for (0..5) |x| {
                    const idx = (y * 640 + ch * 5 + x) * 4;
                    px[idx] = 255; px[idx+1] = 255; px[idx+2] = 255;
                    px[idx+3] = if (((row >> @intCast(4 - x)) & 1) == 1) 255 else 0;
                }
            }
        }
        break :init px;
    };
    const char_uv: [128][2]f32 = init: {
        var t: [128][2]f32 = undefined;
        for (0..128) |ch| { const base: f32 = @floatFromInt(ch * 5); t[ch] = .{ base / 640.0, (base + 5.0) / 640.0 }; }
        break :init t;
    };
};

pub const Ui = struct {
    pub const Vertex = extern struct { pos: [2]f32, uv: [2]f32, color: [4]f32 };

    dev: *Device,
    pipe: *c.SDL_GPUGraphicsPipeline,
    atlas_tex: *c.SDL_GPUTexture,
    atlas_sampler: *c.SDL_GPUSampler,

    verts: std.ArrayListUnmanaged(Vertex) = .{},
    indices: std.ArrayListUnmanaged(u32) = .{},
    vbo: Stream, ibo: Stream,
    idx_count: u32 = 0, alloc: std.mem.Allocator,

    pub fn init(dev: *Device, alloc: std.mem.Allocator, vert_spv: []const u8, frag_spv: []const u8) !Ui {
        const attrs = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "color") }
        };
        const pipe = try dev.createPipeline(.{ .vert_spv = vert_spv, .frag_spv = frag_spv, .vertex_stride = @sizeOf(Vertex), .attributes = &attrs, .depth_test = false, .blend = true });
        const tex = try dev.createTexture(640, 5, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, &font.pixels);
        const sampler = try dev.createSampler(c.SDL_GPU_FILTER_NEAREST, c.SDL_GPU_FILTER_NEAREST, c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST);

        return .{
            .dev = dev, .pipe = pipe, .alloc = alloc, .atlas_tex = tex, .atlas_sampler = sampler,
            .vbo = Stream.init(c.SDL_GPU_BUFFERUSAGE_VERTEX), .ibo = Stream.init(c.SDL_GPU_BUFFERUSAGE_INDEX),
        };
    }

    pub fn deinit(self: *Ui) void {
        self.verts.deinit(self.alloc); self.indices.deinit(self.alloc);
        self.vbo.deinit(self.dev); self.ibo.deinit(self.dev);
        c.SDL_ReleaseGPUSampler(self.dev.gpu, self.atlas_sampler);
        c.SDL_ReleaseGPUTexture(self.dev.gpu, self.atlas_tex);
        c.SDL_ReleaseGPUGraphicsPipeline(self.dev.gpu, self.pipe);
    }

    fn pushQuad(self: *Ui, tl: Vertex, tr: Vertex, bl: Vertex, br: Vertex) !void {
        const base: u32 = @intCast(self.verts.items.len);
        try self.verts.appendSlice(self.alloc, &.{ tl, tr, bl, br });
        try self.indices.appendSlice(self.alloc, &.{ base + 0, base + 1, base + 2, base + 1, base + 3, base + 2 });
    }

    pub fn drawText(self: *Ui, x: f32, y: f32, scale: f32, text: []const u8, color: [4]f32) !void {
        var cx = x;
        for (text) |ch| {
            if (ch > 127) continue;
            const uv = font.char_uv[ch];
            const sz = 5.0 * scale;
            try self.pushQuad(
                .{ .pos = .{ cx, y }, .uv = .{ uv[0], 0.0 }, .color = color },
                .{ .pos = .{ cx + sz, y }, .uv = .{ uv[1], 0.0 }, .color = color },
                .{ .pos = .{ cx, y + sz }, .uv = .{ uv[0], 1.0 }, .color = color },
                .{ .pos = .{ cx + sz, y + sz }, .uv = .{ uv[1], 1.0 }, .color = color },
            );
            cx += 6.0 * scale;
        }
    }

    pub fn drawRect(self: *Ui, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
        const u = font.char_uv[127][0] + (2.0 / 640.0);
        try self.pushQuad(
            .{ .pos = .{ x, y }, .uv = .{ u, 0.5 }, .color = color },
            .{ .pos = .{ x + w, y }, .uv = .{ u, 0.5 }, .color = color },
            .{ .pos = .{ x, y + h }, .uv = .{ u, 0.5 }, .color = color },
            .{ .pos = .{ x + w, y + h }, .uv = .{ u, 0.5 }, .color = color },
        );
    }

    pub fn upload(self: *Ui, cmd: *c.SDL_GPUCommandBuffer) !void {
        self.idx_count = @intCast(self.indices.items.len);
        if (self.idx_count == 0) return;
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return error.CopyPassFailed;
        try self.vbo.upload(self.dev, copy_pass, std.mem.sliceAsBytes(self.verts.items));
        try self.ibo.upload(self.dev, copy_pass, std.mem.sliceAsBytes(self.indices.items));
        c.SDL_EndGPUCopyPass(copy_pass);
    }

    pub fn flush(self: *Ui) !void {
        if (self.idx_count == 0) {
            self.verts.clearRetainingCapacity(); self.indices.clearRetainingCapacity(); return;
        }
        const rp = self.dev.pass orelse return;
        c.SDL_BindGPUGraphicsPipeline(rp, self.pipe);

        const v_bind = [_]c.SDL_GPUBufferBinding{.{ .buffer = self.vbo.handle.?, .offset = 0 }};
        c.SDL_BindGPUVertexBuffers(rp, 0, &v_bind, 1);
        const i_bind = c.SDL_GPUBufferBinding{ .buffer = self.ibo.handle.?, .offset = 0 };
        c.SDL_BindGPUIndexBuffer(rp, &i_bind, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

        const sb_bind = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = self.atlas_tex, .sampler = self.atlas_sampler }};
        c.SDL_BindGPUFragmentSamplers(rp, 0, &sb_bind, 1);

        pushUniform(self.dev.cmd.?, 0, math.ortho(0, @floatFromInt(self.dev.width), @floatFromInt(self.dev.height), 0, -1, 1));
        c.SDL_DrawGPUIndexedPrimitives(rp, self.idx_count, 1, 0, 0, 0);

        self.verts.clearRetainingCapacity(); self.indices.clearRetainingCapacity();
    }
};

// ============================================================================
// 4. MATH
// ============================================================================
pub const math = struct {
    // --- GENERIC EPSILON FOR INTEGER ROUNDING ERRORS ---
    // Increased from 16 to fully prevent clipping through walls at grazing angles
    pub const EPSILON: i64 = 64; 

    pub const Vec3 = @Vector(3, i32);

    pub const Unit = extern struct {
        v: i32 = 0,
        pub const ZERO = Unit{ .v = 0 };
        pub const ONE = Unit{ .v = 1024 };
        pub inline fn fix(f: f32) Unit { return .{ .v = @intFromFloat(f * 1024.0) }; }
        pub inline fn raw(i: i32) Unit { return .{ .v = i }; }

        pub inline fn flt(self: Unit) f32 { return @as(f32, @floatFromInt(self.v)) * 0.0009765625; }
        pub inline fn add(self: Unit, b: Unit) Unit { return .{ .v = self.v + b.v }; }
        pub inline fn sub(self: Unit, b: Unit) Unit { return .{ .v = self.v - b.v }; }
        pub inline fn mul(self: Unit, b: Unit) Unit { return .{ .v = @intCast((@as(i64, self.v) * b.v) >> 10) }; }
        pub inline fn div(self: Unit, b: Unit) Unit { return .{ .v = @intCast(@divTrunc(@as(i64, self.v) << 10, b.v)) }; }
        pub inline fn neg(self: Unit) Unit { return .{ .v = -self.v }; }
        pub inline fn abs(self: Unit) Unit { return .{ .v = if (self.v < 0) -self.v else self.v }; }
        pub inline fn pow(self: Unit, exp: i32) Unit {
            if (exp == 0) return ONE;
            if (exp < 0) return ONE.div(self.pow(-exp));
            var base = self;
            var p: u32 = @intCast(exp);
            var res = ONE;
            while (p > 0) {
                if (p & 1 != 0) res = res.mul(base);
                base = base.mul(base);
                p >>= 1;
            }
            return res;
        }
        pub inline fn fastFrac(num: i32, den: i32) Unit {
            if (den == 0) return ZERO;
            return raw(@intCast(@divTrunc(@as(i64, num) << 10, den)));
        }
    };

    pub inline fn scale(a: Vec3, s: Unit) Vec3 {
        const prod = @as(@Vector(3, i64), a) * @as(@Vector(3, i64), @splat(s.v));
        // FIX: Add 512 for round-to-nearest to eliminate negative-axis drift
        return @truncate((prod + @as(@Vector(3, i64), @splat(512))) >> @as(@Vector(3, u6), @splat(10)));
    }
    
    pub inline fn dot(a: Vec3, b: Vec3) Unit {
        const prod = @reduce(.Add, @as(@Vector(3, i64), a) * @as(@Vector(3, i64), b));
        // FIX: Add 512 for round-to-nearest
        return Unit.raw(@intCast((prod + 512) >> 10));
    }
    
    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        // FIX: Add 512 for round-to-nearest
        return .{
            @intCast(((@as(i64, a[1]) * b[2] - @as(i64, a[2]) * b[1]) + 512) >> 10),
            @intCast(((@as(i64, a[2]) * b[0] - @as(i64, a[0]) * b[2]) + 512) >> 10),
            @intCast(((@as(i64, a[0]) * b[1] - @as(i64, a[1]) * b[0]) + 512) >> 10),
        };
    }
    
    pub inline fn lerp(a: Vec3, b: Vec3, num: i32, den: i32) Vec3 {
        if (den == 0) return a;
        const a64: @Vector(3, i64) = a;
        const b64: @Vector(3, i64) = b;
        return @truncate(a64 + (((b64 - a64) * @as(@Vector(3, i64), @splat(num))) / @as(@Vector(3, i64), @splat(den))));
    }
    const inv_sq_lut: [256]u16 = init: {
        @setEvalBranchQuota(10_000);
        var arr: [256]u16 = undefined;
        for (256..512) |i| {
            const val = @as(f64, @floatFromInt(i));
            arr[i - 256] = @intFromFloat(@round((1.0 / std.math.sqrt(val)) * 32768.0));
        }
        break :init arr;
    };

    /// Pre-computes the inverse ray direction for branchless AABB slab tests.
    /// Safely handles division by zero using maxInt to simulate infinity.
    pub inline fn invRay(rd: Vec3) Vec3 {
        var inv: Vec3 = undefined;
        inline for (0..3) |i| inv[i] = if (rd[i] == 0) std.math.maxInt(i32) else @intCast(@divTrunc(@as(i64, 1) << 30, rd[i]));
        return inv;
    }

    /// Fast Branchless AABB Slab Test. All internal math is 64-bit to prevent overflow.
    pub inline fn rayAABB(ro: Vec3, inv_rd: Vec3, min_box: Vec3, max_box: Vec3, max_t: Unit) bool {
        const ro64 = @as(@Vector(3, i64), ro);
        const inv64 = @as(@Vector(3, i64), inv_rd);
        
        // FIX: Pad the AABB by the generic EPSILON to absorb integer division 
        // truncation error and prevent interval inversion on perfectly flat planes.
        const pad = @as(@Vector(3, i64), @splat(EPSILON));
        const min64 = @as(@Vector(3, i64), min_box) - pad;
        const max64 = @as(@Vector(3, i64), max_box) + pad;

        const t0 = (min64 - ro64) * inv64;
        const t1 = (max64 - ro64) * inv64;

        const t_near = @reduce(.Max, @min(t0, t1));
        const t_far  = @reduce(.Min, @max(t0, t1));

        // Right shift by 20 to convert the (1<<30) scaled inverse back to Q22.10
        return t_near <= t_far and (t_near >> 20) < max_t.v;
    }
    
    /// Exact integer Möller-Trumbore intersection. Uses 64-bit unscaled volume determinants.
    pub inline fn rayTri(ro: Vec3, rd: Vec3, v0: Vec3, v1: Vec3, v2: Vec3) ?Unit {
        const ro64 = @as(@Vector(3, i64), ro);
        const rd64 = @as(@Vector(3, i64), rd);
        const ta = @as(@Vector(3, i64), v0);
        const tb = @as(@Vector(3, i64), v1);
        const tc = @as(@Vector(3, i64), v2);

        const e1 = tb - ta;
        const e2 = tc - ta;

        const h = @Vector(3, i64){ rd64[1]*e2[2] - rd64[2]*e2[1], rd64[2]*e2[0] - rd64[0]*e2[2], rd64[0]*e2[1] - rd64[1]*e2[0] };
        const det = @reduce(.Add, e1 * h);
        
        // Backface culling eliminates the need for negative det branches
        if (det <= 0) return null; 

        // Expand the barycentric bounds check by EPSILON scaled appropriately 
        // for the cubic determinant size, closing microscopic edge seams perfectly.
        const edge_eps = EPSILON * 8192; 

        const sv = ro64 - ta;
        const u = @reduce(.Add, sv * h);
        if (u < -edge_eps or u > det + edge_eps) return null;

        const q = @Vector(3, i64){ sv[1]*e1[2] - sv[2]*e1[1], sv[2]*e1[0] - sv[0]*e1[2], sv[0]*e1[1] - sv[1]*e1[0] };
        const v_val = @reduce(.Add, rd64 * q);
        if (v_val < -edge_eps or u + v_val > det + edge_eps) return null;

        const t_unscaled = @reduce(.Add, e2 * q);

        // Safe i128 casting to prevent overflow on very large level geometry
        const t: i64 = @intCast(@divTrunc(@as(i128, t_unscaled) << 10, @as(i128, det)));
        if (t > 0) return Unit.raw(@intCast(t));
        return null;
    }
    
    pub inline fn lenSq(a: Vec3) i64 {
        const a64: @Vector(3, i64) = a;
        return @reduce(.Add, a64 * a64);
    }
    pub inline fn len(a: Vec3) Unit {
        const d = lenSq(a);
        return if (d <= 0) Unit.ZERO else Unit.raw(@intCast(std.math.sqrt(@as(u64, @intCast(d)))));
    }
    pub inline fn norm(a: Vec3) Vec3 {
        const d = @as(u64, @intCast(@max(0, lenSq(a))));
        if (d == 0) return .{ 0, 0, 0 };
        const b = 63 - @clz(d);
        const is_odd = b & 1;
        const shift = @as(i32, b) - 8;
        const mantissa: usize = @intCast(if (shift >= 0) d >> @intCast(shift) else d << @intCast(-shift));
        var inv_len: u32 = inv_sq_lut[mantissa - 256];
        if (is_odd == 1) inv_len = @intCast((@as(u64, inv_len) * 46340) >> 16);

        const scale_shift: u6 = @intCast(1 + (@as(u32, b) >> 1));
        return @truncate((@as(@Vector(3, i64), a) * @as(@Vector(3, i64), @splat(inv_len))) >> @as(@Vector(3, u6), @splat(scale_shift)));
    }

    pub inline fn mulMat(a: [16]f32, b: [16]f32) [16]f32 {
        var r: [16]f32 = undefined;
        inline for (0..4) |col| {
            inline for (0..4) |row| {
                var s: f32 = 0;
                inline for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
                r[col * 4 + row] = s;
            }
        }
        return r;
    }
    pub inline fn persp(fov: f32, asp: f32, near: f32, far: f32) [16]f32 {
        const t = std.math.tan(fov * std.math.pi / 360.0) * near;
        const r = t * asp;
        return .{
            near / r, 0, 0, 0,
            0, near / t, 0, 0,
            0, 0, -(far + near) / (far - near), -1,
            0, 0, -(2 * far * near) / (far - near), 0,
        };
    }
    pub inline fn ortho(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) [16]f32 {
        return .{
            2.0 / (r - l), 0, 0, 0,
            0, 2.0 / (t - b), 0, 0,
            0, 0, -2.0 / (f - n), 0,
            -(r + l) / (r - l), -(t + b) / (t - b), -(f + n) / (f - n), 1.0,
        };
    }

    /// A yaw/pitch orientation stored as two u16 angle units, wrapping automatically.
    pub const Angle = packed struct(u64) {
        x: u16 = 0,
        y: u16 = 0,
        scale_pad: u32 = 0,
        const lut: [16385]i16 = init: {
            @setEvalBranchQuota(1_000_000);
            var arr: [16385]i16 = undefined;
            for (0..16385) |i| {
                const rad = @as(f64, @floatFromInt(i)) * (std.math.pi / 32768.0);
                arr[i] = @intFromFloat(@round(std.math.sin(rad) * 1024.0));
            }
            break :init arr;
        };
        pub inline fn sin(val: u16) Unit {
            const quad: u2 = @truncate(val >> 14);
            const rem = val & 0x3FFF;
            return Unit.raw(switch (quad) {
                0 => lut[rem],
                1 => lut[16384 - rem],
                2 => -lut[rem],
                3 => -lut[16384 - rem],
            });
        }
        pub inline fn cos(val: u16) Unit {
            const quad: u2 = @truncate(val >> 14);
            const rem = val & 0x3FFF;
            return Unit.raw(switch (quad) {
                0 => lut[16384 - rem],
                1 => -lut[rem],
                2 => -lut[16384 - rem],
                3 => lut[rem],
            });
        }
        pub inline fn addX(self: Angle, offset: i32) Angle {
            var n = self;
            n.x +%= @as(u16, @truncate(@as(u32, @bitCast(offset))));
            return n;
        }
        pub inline fn addY(self: Angle, offset: i32) Angle {
            var n = self;
            n.y +%= @as(u16, @truncate(@as(u32, @bitCast(offset))));
            return n;
        }
        pub inline fn clampPitch(self: Angle) Angle {
            var n = self;
            if (n.x > 16384 and n.x < 32768) n.x = 16384;
            if (n.x < 49152 and n.x >= 32768) n.x = 49152;
            return n;
        }
        pub fn forward(self: Angle) Vec3 {
            const cp = cos(self.x);
            const sp = sin(self.x);
            const cy = cos(self.y);
            const sy = sin(self.y);
            return .{ cp.mul(sy).v, sp.neg().v, cp.mul(cy).neg().v };
        }
    };
};
