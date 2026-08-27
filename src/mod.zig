// src/mod.zig - kami
//! 
//! A minimal, single-file SDL3 GPU engine module.
//! 
//! This module provides a streamlined abstraction over the modern explicit SDL3 GPU API.
//! It includes systems for window lifecycle management, VRAM resource allocation via
//! arenas, unified input polling, 3D scene batching, 2D immediate-mode UI rendering, 
//! and deterministic fixed-point mathematics.

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const std = @import("std");

/// Helper to zero-initialize and safely cast struct fields for C interop.
/// In Zig, C structs must be strictly initialized, but C APIs often expect
/// zeroed memory for unassigned fields and specific integer sizes.
inline fn c_obj(comptime T: type, fields: anytype) T {
    var res = std.mem.zeroes(T);
    
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |f| {
        const D = @TypeOf(@field(res, f.name));
        const V = @TypeOf(@field(fields, f.name));
        
        // Automatically cast integer types (e.g., comptime_int to i32/u32)
        if (comptime @typeInfo(D) == .int and (@typeInfo(V) == .int or @typeInfo(V) == .comptime_int)) {
            @field(res, f.name) = @intCast(@field(fields, f.name));
        } else {
            @field(res, f.name) = @field(fields, f.name);
        }
    }
    
    return res;
}

// ============================================================================
// 1. GPU + Window - Management
// ============================================================================
pub const core = struct {
    /// Manages the SDL3 window, GPU context, and frame lifecycle.
    /// SDL3's GPU API is a modern, explicit graphics abstraction (similar to Vulkan/WebGPU).
    /// It requires acquiring command buffers, explicitly managing memory transfers,
    /// and defining render passes.
    pub const Device = struct {
        /// The main application window presented to the OS.
        window:     *c.SDL_Window,
        
        /// The core SDL3 GPU device context used to create all other GPU resources.
        gpu:        *c.SDL_GPUDevice,
        
        /// Depth texture, automatically managed and resized to match the window.
        /// Used for Z-buffering in 3D scenes so objects occlude correctly.
        depth_tex:  ?*c.SDL_GPUTexture       = null,
        
        /// The active command buffer. GPU commands are recorded here on the CPU,
        /// and then submitted to the GPU in a batch at the end of the frame.
        cmd:        ?*c.SDL_GPUCommandBuffer = null,
        
        /// The active render pass. A render pass defines where drawing operations 
        /// output their pixels (e.g., to the screen and a depth buffer).
        pass:       ?*c.SDL_GPURenderPass    = null,
        
        /// The texture currently acquired from the swapchain to be presented to the screen.
        cur_sc_tex: ?*c.SDL_GPUTexture       = null,
        
        /// The pixel format of the swapchain (e.g., RGBA8), queried at initialization.
        sc_format:  c.SDL_GPUTextureFormat,
        
        /// Internal tracking of the current window width to detect resizes.
        width:      u32                      = 0,
        
        /// Internal tracking of the current window height to detect resizes.
        height:     u32                      = 0,

        /// Initializes the SDL video subsystem, creates a resizable window, 
        /// and sets up the modern explicit GPU device.
        pub fn init(title: [:0]const u8, w: i32, h: i32) !@This() {
            if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) {
                return error.SdlInitFailed;
            }

            const win = c.SDL_CreateWindow(title.ptr, w, h, c.SDL_WINDOW_RESIZABLE) orelse {
                return error.WindowCreationFailed;
            };
                
            // Require SPIR-V shader format. This allows cross-platform compilation later.
            const gpu = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, true, null) orelse {
                return error.GpuDeviceCreationFailed;
            };
                
            // The GPU device must "claim" the window to draw to it via a Swapchain.
            if (!c.SDL_ClaimWindowForGPUDevice(gpu, win)) {
                return error.WindowClaimFailed;
            }

            // Configure the swapchain for Standard Dynamic Range (SDR) and Immediate presentation (V-Sync off).
            _ = c.SDL_SetGPUSwapchainParameters(
                gpu, 
                win, 
                c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, 
                c.SDL_GPU_PRESENTMODE_IMMEDIATE
            );

            return .{
                .window    = win,
                .gpu       = gpu,
                .sc_format = c.SDL_GetGPUSwapchainTextureFormat(gpu, win),
            };
        }

        /// Blocks the CPU until the GPU finishes all pending work, releases all resources, 
        /// and safely shuts down SDL. Must be called on exit to prevent driver crashes.
        pub fn deinit(self: *@This()) void {
            _ = c.SDL_WaitForGPUIdle(self.gpu);

            if (self.depth_tex) |dt| {
                c.SDL_ReleaseGPUTexture(self.gpu, dt);
            }

            c.SDL_ReleaseWindowFromGPUDevice(self.gpu, self.window);
            c.SDL_DestroyGPUDevice(self.gpu);
            c.SDL_DestroyWindow(self.window);
            c.SDL_Quit();
        }

        /// Begins a new frame. Acquires a command buffer to record instructions, 
        /// and grabs the next available swapchain texture to draw onto.
        pub fn beginFrame(self: *@This()) !bool {
            self.cmd = c.SDL_AcquireGPUCommandBuffer(self.gpu) orelse {
                return error.AcquireCommandBufferFailed;
            };

            var uw: u32 = 0; 
            var uh: u32 = 0;
            
            // The swapchain provides the texture that will actually be shown on the monitor.
            if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(self.cmd.?, self.window, &self.cur_sc_tex, &uw, &uh)) {
                _ = c.SDL_CancelGPUCommandBuffer(self.cmd.?);
                self.cmd = null; 
                return false;
            }

            // Handle window resizing: Recreate the depth buffer if the swapchain dimensions changed.
            if (self.depth_tex == null or self.width != uw or self.height != uh) {
                if (self.depth_tex) |d| {
                    c.SDL_ReleaseGPUTexture(self.gpu, d);
                }
                
                self.width  = uw; 
                self.height = uh;
                
                const depth_info = c_obj(c.SDL_GPUTextureCreateInfo, .{
                    .type                 = c.SDL_GPU_TEXTURETYPE_2D, 
                    .format               = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
                    .usage                = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET, 
                    .width                = uw, 
                    .height               = uh,
                    .layer_count_or_depth = 1, 
                    .num_levels           = 1,
                });
                
                self.depth_tex = c.SDL_CreateGPUTexture(self.gpu, &depth_info) orelse {
                    return error.DepthTextureCreationFailed;
                };
            }
            return true;
        }

        /// Starts a render pass targeting the acquired swapchain texture.
        /// This clears the screen to a specific color and prepares the GPU for draw calls.
        pub fn beginRenderPass(self: *@This(), clear_color: [4]f32, use_depth: bool) void {
            var color_tgt = c_obj(c.SDL_GPUColorTargetInfo, .{
                .texture     = self.cur_sc_tex, 
                .load_op     = c.SDL_GPU_LOADOP_CLEAR,
                .store_op    = c.SDL_GPU_STOREOP_STORE,
                .clear_color = c.SDL_FColor{ 
                    .r = clear_color[0],
                    .g = clear_color[1], 
                    .b = clear_color[2],
                    .a = clear_color[3],
                },
            });
            
            var depth_tgt = c_obj(c.SDL_GPUDepthStencilTargetInfo, .{
                .texture     = self.depth_tex, 
                .clear_depth = 1.0,
                .load_op     = c.SDL_GPU_LOADOP_CLEAR, 
                .store_op    = c.SDL_GPU_STOREOP_DONT_CARE,
            });
            
            self.pass = c.SDL_BeginGPURenderPass(
                self.cmd.?, 
                &color_tgt, 
                1, 
                if (use_depth) &depth_tgt else null
            );
        }

        /// Ends the current render pass and submits the recorded command buffer to the GPU.
        /// This executes the frame and pushes it to the display.
        pub fn endFrame(self: *@This()) void {
            if (self.pass) |p| {
                c.SDL_EndGPURenderPass(p);
            }
            if (self.cmd) |cmd| {
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            }
            
            self.pass       = null; 
            self.cmd        = null; 
            self.cur_sc_tex = null;
        }

        /// Compiles SPIR-V shader code and constructs a Graphics Pipeline state object.
        /// In modern APIs, state like blending, depth testing, and vertex layouts are baked 
        /// upfront into pipelines for driver efficiency, rather than set dynamically.
        pub fn createPipeline(self: *@This(), cfg: memory.PipelineCfg) !*c.SDL_GPUGraphicsPipeline {
            const vs_info = c_obj(c.SDL_GPUShaderCreateInfo, .{ 
                .code                = cfg.vert_spv.ptr, 
                .code_size           = cfg.vert_spv.len, 
                .entrypoint          = "main", 
                .format              = c.SDL_GPU_SHADERFORMAT_SPIRV, 
                .stage               = c.SDL_GPU_SHADERSTAGE_VERTEX, 
                .num_uniform_buffers = 1,
            });
            
            const vs = c.SDL_CreateGPUShader(self.gpu, &vs_info) orelse {
                return error.VertexShaderCompilationFailed;
            };
            defer c.SDL_ReleaseGPUShader(self.gpu, vs);

            const fs_info = c_obj(c.SDL_GPUShaderCreateInfo, .{ 
                .code                = cfg.frag_spv.ptr, 
                .code_size           = cfg.frag_spv.len, 
                .entrypoint          = "main", 
                .format              = c.SDL_GPU_SHADERFORMAT_SPIRV, 
                .stage               = c.SDL_GPU_SHADERSTAGE_FRAGMENT, 
                .num_uniform_buffers = 0, 
                .num_samplers        = @as(u32, if (cfg.blend) 1 else 0),
            });
            
            const fs = c.SDL_CreateGPUShader(self.gpu, &fs_info) orelse {
                return error.FragmentShaderCompilationFailed;
            };
            defer c.SDL_ReleaseGPUShader(self.gpu, fs);

            var v_desc = c.SDL_GPUVertexBufferDescription{ 
                .slot               = 0, 
                .pitch              = cfg.vertex_stride, 
                .input_rate         = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, 
                .instance_step_rate = 0,
            };
            
            var target = c_obj(c.SDL_GPUColorTargetDescription, .{
                .format = self.sc_format,
            });
            
            // Alpha blending configuration for 2D UI elements
            if (cfg.blend) {
                target.blend_state = c_obj(c.SDL_GPUColorTargetBlendState, .{ 
                    .enable_blend          = true, 
                    .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA, 
                    .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, 
                    .color_blend_op        = c.SDL_GPU_BLENDOP_ADD, 
                    .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE, 
                    .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO, 
                    .alpha_blend_op        = c.SDL_GPU_BLENDOP_ADD,
                });
            }

            var pipe_info = c_obj(c.SDL_GPUGraphicsPipelineCreateInfo, .{
                .vertex_shader      = vs, 
                .fragment_shader    = fs, 
                .primitive_type     = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
                
                .vertex_input_state = c_obj(c.SDL_GPUVertexInputState, .{ 
                    .vertex_buffer_descriptions = &v_desc, 
                    .num_vertex_buffers         = 1, 
                    .vertex_attributes          = cfg.attributes.ptr, 
                    .num_vertex_attributes      = cfg.attributes.len,
                }),
                
                .rasterizer_state = c_obj(c.SDL_GPURasterizerState, .{ 
                    .cull_mode  = if (cfg.depth_test) c.SDL_GPU_CULLMODE_BACK else c.SDL_GPU_CULLMODE_NONE, 
                    .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE, 
                    .fill_mode  = c.SDL_GPU_FILLMODE_FILL,
                }),
                
                .depth_stencil_state = c_obj(c.SDL_GPUDepthStencilState, .{ 
                    .enable_depth_test  = cfg.depth_test, 
                    .enable_depth_write = cfg.depth_test, 
                    .compare_op         = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
                }),
                
                .target_info = c_obj(c.SDL_GPUGraphicsPipelineTargetInfo, .{ 
                    .color_target_descriptions = &target, 
                    .num_color_targets         = 1, 
                    .has_depth_stencil_target  = cfg.depth_test, 
                    .depth_stencil_format      = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
                }),
            });
            
            return c.SDL_CreateGPUGraphicsPipeline(self.gpu, &pipe_info) orelse error.PipelineCreationFailed;
        }

        /// Creates a 2D GPU texture and synchronously uploads pixel data to it.
        /// Modern GPUs require a "Transfer Buffer" (staging memory) to move CPU data to fast VRAM.
        pub fn createTexture(self: *@This(), width: u32, height: u32, format: c.SDL_GPUTextureFormat, pixels: []const u8) !*c.SDL_GPUTexture {
            const tex_info = c_obj(c.SDL_GPUTextureCreateInfo, .{ 
                .type                 = c.SDL_GPU_TEXTURETYPE_2D, 
                .format               = format, 
                .usage                = c.SDL_GPU_TEXTUREUSAGE_SAMPLER, 
                .width                = width, 
                .height               = height, 
                .layer_count_or_depth = 1, 
                .num_levels           = 1,
            });
            
            const tex = c.SDL_CreateGPUTexture(self.gpu, &tex_info) orelse {
                return error.TextureCreationFailed;
            };
            
            // 1. Create a transfer buffer (CPU-visible memory that the GPU can pull from).
            const transfer_info = c_obj(c.SDL_GPUTransferBufferCreateInfo, .{ 
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, 
                .size  = pixels.len,
            });
            
            const tbuf = c.SDL_CreateGPUTransferBuffer(self.gpu, &transfer_info) orelse {
                return error.TransferBufferCreationFailed;
            };
            defer c.SDL_ReleaseGPUTransferBuffer(self.gpu, tbuf);

            // 2. Map the transfer buffer to CPU space and copy the raw pixel bytes into it.
            const ptr = c.SDL_MapGPUTransferBuffer(self.gpu, tbuf, false) orelse {
                return error.TransferBufferMapFailed;
            };
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..pixels.len], pixels);
            c.SDL_UnmapGPUTransferBuffer(self.gpu, tbuf);

            // 3. Command the GPU to copy from the transfer buffer into the final texture VRAM.
            const cmd = c.SDL_AcquireGPUCommandBuffer(self.gpu) orelse {
                return error.AcquireCommandBufferFailed;
            };
            
            const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
                return error.CopyPassFailed;
            };
            
            var loc = c_obj(c.SDL_GPUTextureTransferInfo, .{
                .transfer_buffer = tbuf,
            });
            
            var reg = c_obj(c.SDL_GPUTextureRegion, .{
                .texture = tex,
                .w       = width,
                .h       = height,
                .d       = 1,
            });

            c.SDL_UploadToGPUTexture(copy_pass, &loc, &reg, false);
            c.SDL_EndGPUCopyPass(copy_pass);
            
            // 4. Submit the work immediately.
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            
            return tex;
        }

        /// Creates a Sampler, which instructs the GPU how to read (sample) texture pixels 
        /// (e.g., nearest-neighbor for pixel art, or linear filtering for smooth scaling).
        pub fn createSampler(self: *@This(), min_f: c.SDL_GPUFilter, mag_f: c.SDL_GPUFilter, mip_m: c.SDL_GPUSamplerMipmapMode) !*c.SDL_GPUSampler {
            const sampler_info = c_obj(c.SDL_GPUSamplerCreateInfo, .{ 
                .min_filter     = min_f, 
                .mag_filter     = mag_f, 
                .mipmap_mode    = mip_m, 
                .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE, 
                .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            });
            
            return c.SDL_CreateGPUSampler(self.gpu, &sampler_info) orelse error.SamplerCreationFailed;
        }
    };
};

// ============================================================================
// 2. GPU Pipeline Memory Management
// ============================================================================
pub const memory = struct {
    /// Configuration parameters for creating a graphics pipeline.
    pub const PipelineCfg = struct {
        vert_spv:      []const u8, 
        frag_spv:      []const u8,
        vertex_stride: u32, 
        attributes:    []const c.SDL_GPUVertexAttribute,
        depth_test:    bool = true, 
        blend:         bool = false,
    };

    /// A dynamic GPU memory allocator that manages a growing buffer in VRAM.
    /// Uses a geometric expansion algorithm (Carmack-style) to minimize reallocations
    /// when appending new mesh data or UI geometry dynamically.
    pub const GpuArena = struct {
        handle:   ?*c.SDL_GPUBuffer         = null, 
        transfer: ?*c.SDL_GPUTransferBuffer = null, 
        cap:      usize                     = 0, 
        usage:    c.SDL_GPUBufferUsageFlags, 
        len:      usize                     = 0,
        
        /// Initializes an empty arena meant for a specific usage (e.g. Vertex or Index buffer).
        pub fn init(usage: c.SDL_GPUBufferUsageFlags) @This() { 
            return .{
                .usage = usage,
            }; 
        }
        
        /// Frees the underlying GPU resources.
        pub fn deinit(self: *@This(), dev: *core.Device) void {
            if (self.handle) |h| {
                c.SDL_ReleaseGPUBuffer(dev.gpu, h);
            }
            
            if (self.transfer) |t| {
                c.SDL_ReleaseGPUTransferBuffer(dev.gpu, t);
            }
            
            self.* = init(self.usage);
        }
        
        /// Pushes byte data onto the GPU buffer. If the buffer is full, it allocates 
        /// a larger buffer on the GPU and maps it. Returns the offset index where the data begins.
        pub fn push(self: *@This(), dev: *core.Device, copy_pass: *c.SDL_GPUCopyPass, bytes: []const u8) !u32 {
            if (bytes.len == 0) {
                return @intCast(self.len);
            }
            
            const needed = self.len + bytes.len;
            
            // Carmack geometric expansion (1.5x scaling + page alignment) + 16MB minimum to avoid resets
            if (needed > self.cap) {
                const new_cap = (needed + (needed >> 1) + 4095) & ~@as(usize, 4095);
                self.cap = @max(new_cap, 1024 * 1024 * 16); 
                
                const nh_info = c_obj(c.SDL_GPUBufferCreateInfo, .{
                    .usage = self.usage,
                    .size  = self.cap,
                });
                
                const nh = c.SDL_CreateGPUBuffer(dev.gpu, &nh_info) orelse {
                    return error.BufferOom;
                };
                
                const nt_info = c_obj(c.SDL_GPUTransferBufferCreateInfo, .{
                    .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                    .size  = self.cap,
                });
                
                const nt = c.SDL_CreateGPUTransferBuffer(dev.gpu, &nt_info) orelse {
                    return error.TransferOom;
                };
                
                if (self.handle) |oh| { 
                    if (self.len > 0) {
                        var src_loc = c_obj(c.SDL_GPUBufferLocation, .{ .buffer = oh, .offset = 0 });
                        var dst_loc = c_obj(c.SDL_GPUBufferLocation, .{ .buffer = nh, .offset = 0 });
                        c.SDL_CopyGPUBufferToBuffer(copy_pass, &src_loc, &dst_loc, @intCast(self.len), false);
                    }
                    c.SDL_ReleaseGPUBuffer(dev.gpu, oh); 
                    c.SDL_ReleaseGPUTransferBuffer(dev.gpu, self.transfer.?); 
                }
                
                self.handle   = nh; 
                self.transfer = nt;
            }

            // Upload through transfer staging memory
            const ptr = c.SDL_MapGPUTransferBuffer(dev.gpu, self.transfer.?, false) orelse {
                return error.TransferMapFailed;
            };
            
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
            c.SDL_UnmapGPUTransferBuffer(dev.gpu, self.transfer.?);
            
            var loc = c_obj(c.SDL_GPUTransferBufferLocation, .{
                .transfer_buffer = self.transfer.?,
            });
            
            var reg = c_obj(c.SDL_GPUBufferRegion, .{
                .buffer = self.handle.?,
                .size   = bytes.len,
                .offset = self.len, // Clean direct passing, casting handled correctly by c_obj loop
            });
            
            c.SDL_UploadToGPUBuffer(copy_pass, &loc, &reg, false);
            
            const offset = self.len;
            self.len    += bytes.len;
            
            return @intCast(offset);
        }
        
        /// Resets the logical length to 0, allowing buffer space to be reused next frame.
        pub fn reset(self: *@This()) void { 
            self.len = 0; 
        }
    };

    /// Pushes tiny amounts of uniform data (like an MVP matrix) directly to the shader
    /// without needing a dedicated uniform buffer. Highly efficient for per-draw constants.
    pub inline fn pushUniform(cmd: *c.SDL_GPUCommandBuffer, slot: u32, data: anytype) void {
        c.SDL_PushGPUVertexUniformData(cmd, slot, &data, @sizeOf(@TypeOf(data)));
    }
};

// ============================================================================
// 3. ENGINE SYSTEMS: Input, Scene, UI
// ============================================================================
pub const systems = struct {
    /// A type-safe input polling system that maps SDL scancodes to a generic Action Enum.
    /// Tracks current frame presses, releases, holds, and mouse motions using bitsets for speed.
    pub fn Input(comptime Action: type) type {
        return struct {
            pub const MouseState = packed struct(u8) {
                left:   bool = false,
                middle: bool = false,
                right:  bool = false,
                x1:     bool = false,
                x2:     bool = false,
                _pad:   u3   = 0,
                
                pub inline fn get(self: MouseState, btn: u8) bool {
                    return switch (btn) {
                        c.SDL_BUTTON_LEFT   => self.left,
                        c.SDL_BUTTON_MIDDLE => self.middle,
                        c.SDL_BUTTON_RIGHT  => self.right,
                        c.SDL_BUTTON_X1     => self.x1,
                        c.SDL_BUTTON_X2     => self.x2,
                        else                => false,
                    };
                }
                
                pub inline fn set(self: *MouseState, btn: u8, val: bool) void {
                    switch (btn) {
                        c.SDL_BUTTON_LEFT   => self.left   = val,
                        c.SDL_BUTTON_MIDDLE => self.middle = val,
                        c.SDL_BUTTON_RIGHT  => self.right  = val,
                        c.SDL_BUTTON_X1     => self.x1     = val,
                        c.SDL_BUTTON_X2     => self.x2     = val,
                        else                => {},
                    }
                }
            };

            keys_held:    [*c]const bool      = null,
            k_press:      [512]bool           = .{false} ** 512,
            k_rel:        [512]bool           = .{false} ** 512,
            
            mouse_x:      f32                 = 0,
            mouse_y:      f32                 = 0, 
            mouse_dx:     f32                 = 0,
            mouse_dy:     f32                 = 0, 
            scroll_x:     f32                 = 0,
            scroll_y:     f32                 = 0,
            
            m_held:       MouseState          = .{},
            m_press:      MouseState          = .{},
            m_rel:        MouseState          = .{},
            
            mouse_locked: bool                = false, 
            quit:         bool                = false,
            sensitivity:  f32                 = 1.0,

            key_lut:      [512]?Action        = .{null} ** 512,
            mouse_lut:    [6]?Action          = .{null} ** 6,
            wheel_lut:    [2]?Action          = .{null} ** 2, // 0 = Up, 1 = Down
            
            pending:      std.EnumSet(Action) = std.EnumSet(Action).initEmpty(), 
            current:      std.EnumSet(Action) = std.EnumSet(Action).initEmpty(), 
            prev:         std.EnumSet(Action) = std.EnumSet(Action).initEmpty(),

            pub fn init() @This() {
                return .{};
            }
            
            /// Binds an SDL Scancode to a user-defined Action Enum.
            pub fn bindKey(s: *@This(), a: Action, sc: c.SDL_Scancode) void {
                s.key_lut[@intCast(sc)] = a;
            }
            
            /// Binds a Mouse button (1=Left, 2=Middle, 3=Right, 4=X1, 5=X2) to an Action.
            pub fn bindMouse(s: *@This(), a: Action, btn: u8) void {
                if (btn < 6) s.mouse_lut[btn] = a;
            }
            
            /// Binds mouse wheel direction to an Action.
            pub fn bindWheel(s: *@This(), a: Action, up: bool) void {
                s.wheel_lut[if (up) 0 else 1] = a;
            }

            inline fn trigger(s: *@This(), a: Action) void { 
                s.pending.insert(a);
            }

            /// Advances the input state logic. Must be called every frame *before* update().
            pub inline fn tick(s: *@This()) void {
                s.prev    = s.current; 
                s.current = s.pending; 
                s.pending = std.EnumSet(Action).initEmpty();
            }

            /// Consumes an action, preventing it from being registered multiple times.
            pub inline fn consume(s: *@This(), a: Action, held: bool) bool {
                if (s.current.contains(a) or s.prev.contains(a)) {
                    s.current.remove(a); 
                    s.prev.remove(a); 
                    return true;
                }
                return held;
            }

            /// Polls the SDL event queue and updates all internal input arrays.
            pub fn update(s: *@This()) void {
                s.mouse_dx = 0;
                s.mouse_dy = 0;
                s.scroll_x = 0;
                s.scroll_y = 0;
                
                s.k_press  = .{false} ** 512;
                s.k_rel    = .{false} ** 512; 
                s.m_press  = .{};
                s.m_rel    = .{};
                
                s.keys_held  = c.SDL_GetKeyboardState(null);
                const mstate = c.SDL_GetMouseState(&s.mouse_x, &s.mouse_y);
                
                s.m_held = @bitCast(@as(u8, @truncate(mstate)));

                var ev: c.SDL_Event = undefined;
                while (c.SDL_PollEvent(&ev)) {
                    switch (ev.type) {
                        c.SDL_EVENT_QUIT => {
                            s.quit = true;
                        },
                        
                        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                            const idx: usize = @intCast(ev.key.scancode); 
                            
                            if (idx > 511) {
                                continue;
                            }
                            
                            if (ev.type == c.SDL_EVENT_KEY_DOWN and !ev.key.repeat) { 
                                s.k_press[idx] = true; 
                                
                                if (s.key_lut[idx]) |a| {
                                    s.trigger(a);
                                } 
                            }
                            
                            if (ev.type == c.SDL_EVENT_KEY_UP) {
                                s.k_rel[idx] = true;
                            }
                        },
                        
                        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => { 
                            const is_down = ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
                            
                            if (is_down) {
                                s.m_press.set(ev.button.button, true);
                                
                                const idx = ev.button.button;
                                if (idx < 6) {
                                    if (s.mouse_lut[idx]) |a| {
                                        s.trigger(a);
                                    }
                                }
                            } else {
                                s.m_rel.set(ev.button.button, true);
                            }
                        },
                        
                        c.SDL_EVENT_MOUSE_MOTION => {
                            if (s.mouse_locked) { 
                                s.mouse_dx += ev.motion.xrel * s.sensitivity; 
                                s.mouse_dy += ev.motion.yrel * s.sensitivity; 
                            }
                        },
                        
                        c.SDL_EVENT_MOUSE_WHEEL => { 
                            s.scroll_x += ev.wheel.x; 
                            s.scroll_y += ev.wheel.y;
                            
                            if (ev.wheel.y > 0) { 
                                if (s.wheel_lut[0]) |a| {
                                    s.trigger(a);
                                } 
                            } else if (ev.wheel.y < 0) { 
                                if (s.wheel_lut[1]) |a| {
                                    s.trigger(a);
                                } 
                            }
                        },
                        else => {},
                    }
                }
            }

            /// Locks the mouse into the center of the window (ideal for FPS cameras).
            pub fn setLock(s: *@This(), win: *c.SDL_Window, lock: bool) void {
                s.mouse_locked = lock;
                if (lock) {
                    _ = c.SDL_HideCursor();
                } else {
                    _ = c.SDL_ShowCursor();
                }
                _ = c.SDL_SetWindowRelativeMouseMode(win, lock);
            }
            
            pub fn key(s: *const @This(), sc: c.SDL_Scancode) bool {
                if (s.keys_held) |k| {
                    return k[@intCast(sc)];
                }
                return false;
            }
            
            pub fn keyPressed(s: *const @This(), sc: c.SDL_Scancode) bool {
                return s.k_press[@intCast(sc)];
            }
            
            pub fn keyReleased(s: *const @This(), sc: c.SDL_Scancode) bool {
                return s.k_rel[@intCast(sc)];
            }
            
            pub fn mouse(s: *const @This(), btn: u8) bool {
                return s.m_held.get(btn);
            }
            
            pub fn mousePressed(s: *const @This(), btn: u8) bool {
                return s.m_press.get(btn);
            }
            
            pub fn mouseReleased(s: *const @This(), btn: u8) bool {
                return s.m_rel.get(btn);
            }
        };
    }

    /// A 3D Scene manager representing a static world containing discrete meshes.
    /// Wraps vertex buffer uploads, bindings, and index-based draw calls.
    pub const Scene = struct {
        pub const Vertex = extern struct {
            pos:   [3]i32,
            color: [4]f32,
        };
        pub const Mesh = struct {
            v_off:   u32,
            i_off:   u32,
            i_count: u32,
        };
        pub const Handle = usize;

        dev:         *core.Device,
        pipe:        *c.SDL_GPUGraphicsPipeline,
        vbo:         memory.GpuArena, 
        ibo:         memory.GpuArena,
        meshes:      std.ArrayListUnmanaged(Mesh) = .{},
        alloc:       std.mem.Allocator,
        clear_color: [4]f32                       = .{ 0.06, 0.07, 0.12, 1.0 },

        /// Initializes a generic 3D pipeline with depth testing.
        pub fn init(dev: *core.Device, alloc: std.mem.Allocator, vert_spv: []const u8, frag_spv: []const u8) !@This() {
            const attrs = [_]c.SDL_GPUVertexAttribute{
                .{
                    .location    = 0,
                    .buffer_slot = 0,
                    .format      = c.SDL_GPU_VERTEXELEMENTFORMAT_INT3,
                    .offset      = @offsetOf(Vertex, "pos"),
                },
                .{
                    .location    = 1,
                    .buffer_slot = 0,
                    .format      = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                    .offset      = @offsetOf(Vertex, "color"),
                }
            };
            
            const pipe = try dev.createPipeline(.{ 
                .vert_spv      = vert_spv, 
                .frag_spv      = frag_spv, 
                .vertex_stride = @sizeOf(Vertex), 
                .attributes    = &attrs, 
                .depth_test    = true,
            });
            
            return .{ 
                .dev   = dev, 
                .pipe  = pipe, 
                .alloc = alloc, 
                .vbo   = memory.GpuArena.init(c.SDL_GPU_BUFFERUSAGE_VERTEX), 
                .ibo   = memory.GpuArena.init(c.SDL_GPU_BUFFERUSAGE_INDEX),
            };
        }

        pub fn deinit(s: *@This()) void {
            s.vbo.deinit(s.dev); 
            s.ibo.deinit(s.dev);
            s.meshes.deinit(s.alloc);
            
            c.SDL_ReleaseGPUGraphicsPipeline(s.dev.gpu, s.pipe);
        }

        /// Uploads vertex and index data directly to VRAM in one copy pass.
        /// Returns a Handle that can be used to render this mesh later.
        pub fn upload(s: *@This(), vert_bytes: []const u8, idx_bytes: []const u8) !Handle {
            const cmd = c.SDL_AcquireGPUCommandBuffer(s.dev.gpu) orelse {
                return error.AcquireCommandBufferFailed;
            };
            const pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
                return error.CopyPassFailed;
            };
            
            const v_off = try s.vbo.push(s.dev, pass, vert_bytes);
            const i_off = try s.ibo.push(s.dev, pass, idx_bytes);
            
            c.SDL_EndGPUCopyPass(pass);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            
            const handle = s.meshes.items.len;
            
            try s.meshes.append(s.alloc, .{ 
                .v_off   = v_off, 
                .i_off   = i_off, 
                .i_count = @intCast(idx_bytes.len / 4),
            });
            
            return handle;
        }

        /// Dispatches a draw call for a specific mesh handle using the provided MVP matrix.
        pub fn draw(s: *@This(), handle: Handle, mvp: [16]f32) void {
            if (handle >= s.meshes.items.len) {
                return;
            }
            
            const m = s.meshes.items[handle];
            if (m.i_count == 0) {
                return;
            }
            
            const rp = s.dev.pass orelse {
                return;
            };

            c.SDL_BindGPUGraphicsPipeline(rp, s.pipe);
            
            const v_bind = [_]c.SDL_GPUBufferBinding{.{ .buffer = s.vbo.handle.?, .offset = m.v_off }};
            c.SDL_BindGPUVertexBuffers(rp, 0, &v_bind, 1);
            
            const i_bind = c.SDL_GPUBufferBinding{ .buffer = s.ibo.handle.?, .offset = m.i_off };
            c.SDL_BindGPUIndexBuffer(rp, &i_bind, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

            memory.pushUniform(s.dev.cmd.?, 0, mvp);
            c.SDL_DrawGPUIndexedPrimitives(rp, m.i_count, 1, 0, 0, 0);
        }
    };

    /// 5x5 Bitmap font encoded in compile-time evaluated bits. 
    /// Expanded at comptime into an uncompressed RGBA texture map for rendering.
    const font = struct {
        const pixels: [128 * 5 * 5 * 4]u8 = init: {
            @setEvalBranchQuota(100000);
            var f = [_][5]u8{.{ 0, 0, 0, 0, 0 }} ** 128;
            
            f['!']  = .{ 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 };
            f['"']  = .{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000 };
            f['#']  = .{ 0b01010, 0b11111, 0b01010, 0b11111, 0b01010 };
            f['$']  = .{ 0b01110, 0b10100, 0b01110, 0b00101, 0b01110 };
            f['%']  = .{ 0b10001, 0b00010, 0b00100, 0b01000, 0b10001 };
            f['&']  = .{ 0b01000, 0b10100, 0b01000, 0b10101, 0b01101 };
            f['\''] = .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000 };
            f['(']  = .{ 0b00010, 0b00100, 0b00100, 0b00100, 0b00010 };
            f[')']  = .{ 0b01000, 0b00100, 0b00100, 0b00100, 0b01000 };
            f['*']  = .{ 0b00000, 0b10101, 0b01110, 0b10101, 0b00000 };
            f['+']  = .{ 0b00000, 0b00100, 0b01110, 0b00100, 0b00000 };
            f[',']  = .{ 0b00000, 0b00000, 0b00000, 0b00100, 0b01000 };
            f['-']  = .{ 0b00000, 0b00000, 0b01110, 0b00000, 0b00000 };
            f['.']  = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 };
            f['/']  = .{ 0b00001, 0b00010, 0b00100, 0b01000, 0b10000 };
            f['0']  = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 };
            f['1']  = .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b01110 };
            f['2']  = .{ 0b01110, 0b00001, 0b01110, 0b10000, 0b01110 };
            f['3']  = .{ 0b01110, 0b00001, 0b00110, 0b00001, 0b01110 };
            f['4']  = .{ 0b10001, 0b10001, 0b01111, 0b00001, 0b00001 };
            f['5']  = .{ 0b01111, 0b10000, 0b01110, 0b00001, 0b01110 };
            f['6']  = .{ 0b01110, 0b10000, 0b11110, 0b10001, 0b01110 };
            f['7']  = .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b00100 };
            f['8']  = .{ 0b01110, 0b10001, 0b01110, 0b10001, 0b01110 };
            f['9']  = .{ 0b01110, 0b10001, 0b01111, 0b00001, 0b01110 };
            f[':']  = .{ 0b00000, 0b00100, 0b00000, 0b00100, 0b00000 };
            f[';']  = .{ 0b00000, 0b00100, 0b00000, 0b00100, 0b01000 };
            f['<']  = .{ 0b00010, 0b00100, 0b01000, 0b00100, 0b00010 };
            f['=']  = .{ 0b00000, 0b01110, 0b00000, 0b01110, 0b00000 };
            f['>']  = .{ 0b01000, 0b00100, 0b00010, 0b00100, 0b01000 };
            f['?']  = .{ 0b01110, 0b10001, 0b00010, 0b00100, 0b00100 };
            f['@']  = .{ 0b01110, 0b10001, 0b10101, 0b10111, 0b01110 };
            f['A']  = .{ 0b01110, 0b10001, 0b11111, 0b10001, 0b10001 };
            f['B']  = .{ 0b11110, 0b10001, 0b11110, 0b10001, 0b11110 };
            f['C']  = .{ 0b01110, 0b10001, 0b10000, 0b10001, 0b01110 };
            f['D']  = .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 };
            f['E']  = .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b11111 };
            f['F']  = .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b10000 };
            f['G']  = .{ 0b01110, 0b10000, 0b10011, 0b10001, 0b01110 };
            f['H']  = .{ 0b10001, 0b10001, 0b11111, 0b10001, 0b10001 };
            f['I']  = .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b01110 };
            f['J']  = .{ 0b00111, 0b00010, 0b00010, 0b10010, 0b01100 };
            f['K']  = .{ 0b10001, 0b10010, 0b11100, 0b10010, 0b10001 };
            f['L']  = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 };
            f['M']  = .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001 };
            f['N']  = .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001 };
            f['O']  = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 };
            f['P']  = .{ 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 };
            f['Q']  = .{ 0b01110, 0b10001, 0b10101, 0b10010, 0b01101 };
            f['R']  = .{ 0b11110, 0b10001, 0b11110, 0b10100, 0b10011 };
            f['S']  = .{ 0b01110, 0b10000, 0b01110, 0b00001, 0b01110 };
            f['T']  = .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100 };
            f['U']  = .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 };
            f['V']  = .{ 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 };
            f['W']  = .{ 0b10001, 0b10001, 0b10101, 0b11011, 0b10001 };
            f['X']  = .{ 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 };
            f['Y']  = .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100 };
            f['Z']  = .{ 0b00000, 0b11111, 0b00100, 0b01000, 0b11111 };
            f['[']  = .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01110 };
            f['\\'] = .{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00001 };
            f[']']  = .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b01110 };
            f['^']  = .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000 };
            f['_']  = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 };
            f['`']  = .{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000 };
            f['a']  = .{ 0b00000, 0b01110, 0b10001, 0b10011, 0b01101 };
            f['b']  = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b11110 };
            f['c']  = .{ 0b00000, 0b01110, 0b10000, 0b10000, 0b01110 };
            f['d']  = .{ 0b00001, 0b00001, 0b01111, 0b10001, 0b01111 };
            f['e']  = .{ 0b00000, 0b01110, 0b11111, 0b10000, 0b01110 };
            f['f']  = .{ 0b00110, 0b01000, 0b11110, 0b01000, 0b01000 };
            f['g']  = .{ 0b00000, 0b01111, 0b10001, 0b01111, 0b00001 };
            f['h']  = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001 };
            f['i']  = .{ 0b00100, 0b00000, 0b00100, 0b00100, 0b00100 };
            f['j']  = .{ 0b00010, 0b00000, 0b00010, 0b10010, 0b01100 };
            f['k']  = .{ 0b10000, 0b10000, 0b10010, 0b11100, 0b10010 };
            f['l']  = .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 };
            f['m']  = .{ 0b00000, 0b11010, 0b10101, 0b10101, 0b10101 };
            f['n']  = .{ 0b00000, 0b11110, 0b10001, 0b10001, 0b10001 };
            f['o']  = .{ 0b00000, 0b01110, 0b10001, 0b10001, 0b01110 };
            f['p']  = .{ 0b00000, 0b11110, 0b10001, 0b11110, 0b10000 };
            f['q']  = .{ 0b00000, 0b01111, 0b10001, 0b01111, 0b00001 };
            f['r']  = .{ 0b00000, 0b10110, 0b11000, 0b10000, 0b10000 };
            f['s']  = .{ 0b00000, 0b01110, 0b10000, 0b01110, 0b00001 };
            f['t']  = .{ 0b01000, 0b11100, 0b01000, 0b01000, 0b00110 };
            f['u']  = .{ 0b00000, 0b10001, 0b10001, 0b10001, 0b01111 };
            f['v']  = .{ 0b00000, 0b10001, 0b10001, 0b01010, 0b00100 };
            f['w']  = .{ 0b00000, 0b10001, 0b10101, 0b10101, 0b01010 };
            f['x']  = .{ 0b00000, 0b10001, 0b01010, 0b00100, 0b10001 };
            f['y']  = .{ 0b00000, 0b10001, 0b10001, 0b01111, 0b00001 };
            f['z']  = .{ 0b00000, 0b11111, 0b00100, 0b01000, 0b11111 };
            f['{']  = .{ 0b00110, 0b01000, 0b10000, 0b01000, 0b00110 };
            f['|']  = .{ 0b00100, 0b00100, 0b00000, 0b00100, 0b00100 };
            f['}']  = .{ 0b01100, 0b00010, 0b00001, 0b00010, 0b01100 };
            f['~']  = .{ 0b01010, 0b10101, 0b00000, 0b00000, 0b00000 };
            f[127]  = .{ 0b11111, 0b11111, 0b11111, 0b11111, 0b11111 };

            var px = [_]u8{0} ** (128 * 5 * 5 * 4);
            
            for (0..128) |ch| {
                for (0..5) |y| {
                    const row = f[ch][y];
                    for (0..5) |x| {
                        const idx = (y * 640 + ch * 5 + x) * 4;
                        @as(*[4]u8, @ptrCast(&px[idx])).* = .{
                            255,
                            255,
                            255,
                            if (((row >> @intCast(4 - x)) & 1) == 1) 255 else 0,
                        };
                    }
                }
            }
            
            break :init px;
        };
        
        // Pre-calculate UV coordinates mapping ASCII to the texture slice.
        const char_uv: [128][2]f32 = init: {
            var t: [128][2]f32 = undefined;
            for (0..128) |ch| { 
                const base: f32 = @floatFromInt(ch * 5); 
                t[ch] = .{
                    base / 640.0,
                    (base + 5.0) / 640.0,
                }; 
            }
            break :init t;
        };
    };

    /// 2D User Interface batcher.
    /// Queues up text and rectangle draws during the frame into a dynamic arena buffer,
    /// then flushes them all to the GPU in a single draw call at the end of the frame.
    pub const Ui = struct {
        pub const Vertex = extern struct {
            pos:   [2]f32,
            uv:    [2]f32,
            color: [4]f32,
        };

        dev:           *core.Device, 
        pipe:          *c.SDL_GPUGraphicsPipeline,
        atlas_tex:     *c.SDL_GPUTexture, 
        atlas_sampler: *c.SDL_GPUSampler,

        verts:         std.ArrayListUnmanaged(Vertex) = .{},
        indices:       std.ArrayListUnmanaged(u32)    = .{},
        
        vbo:           memory.GpuArena, 
        ibo:           memory.GpuArena,
        alloc:         std.mem.Allocator,

        pub fn init(dev: *core.Device, alloc: std.mem.Allocator, vert_spv: []const u8, frag_spv: []const u8) !@This() {
            const attrs = [_]c.SDL_GPUVertexAttribute{
                .{
                    .location    = 0,
                    .buffer_slot = 0,
                    .format      = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                    .offset      = @offsetOf(Vertex, "pos"),
                },
                .{
                    .location    = 1,
                    .buffer_slot = 0,
                    .format      = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                    .offset      = @offsetOf(Vertex, "uv"),
                },
                .{
                    .location    = 2,
                    .buffer_slot = 0,
                    .format      = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                    .offset      = @offsetOf(Vertex, "color"),
                }
            };
            
            const pipe = try dev.createPipeline(.{ 
                .vert_spv      = vert_spv, 
                .frag_spv      = frag_spv, 
                .vertex_stride = @sizeOf(Vertex), 
                .attributes    = &attrs, 
                .depth_test    = false, 
                .blend         = true,
            });
            
            const tex = try dev.createTexture(640, 5, c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, &font.pixels);
            
            // Nearest filtering prevents the blocky font from blurring when scaled up.
            const sampler = try dev.createSampler(
                c.SDL_GPU_FILTER_NEAREST, 
                c.SDL_GPU_FILTER_NEAREST, 
                c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST
            );

            return .{
                .dev           = dev, 
                .pipe          = pipe, 
                .alloc         = alloc, 
                .atlas_tex     = tex, 
                .atlas_sampler = sampler,
                .vbo           = memory.GpuArena.init(c.SDL_GPU_BUFFERUSAGE_VERTEX), 
                .ibo           = memory.GpuArena.init(c.SDL_GPU_BUFFERUSAGE_INDEX),
            };
        }

        pub fn deinit(s: *@This()) void {
            s.verts.deinit(s.alloc); 
            s.indices.deinit(s.alloc);
            
            s.vbo.deinit(s.dev); 
            s.ibo.deinit(s.dev);
            
            c.SDL_ReleaseGPUSampler(s.dev.gpu, s.atlas_sampler);
            c.SDL_ReleaseGPUTexture(s.dev.gpu, s.atlas_tex);
            c.SDL_ReleaseGPUGraphicsPipeline(s.dev.gpu, s.pipe);
        }

        fn pushQuad(s: *@This(), tl: Vertex, tr: Vertex, bl: Vertex, br: Vertex) !void {
            const base: u32 = @intCast(s.verts.items.len);
            
            try s.verts.appendSlice(s.alloc, &.{ tl, tr, bl, br });
            try s.indices.appendSlice(s.alloc, &.{
                base,     base + 1, base + 2,
                base + 1, base + 3, base + 2,
            });
        }

        /// Queues a string to be drawn onto the screen.
        pub fn drawText(s: *@This(), x: f32, y: f32, scale: f32, text: []const u8, color: [4]f32) !void {
            var cx = x;
            
            for (text) |ch| {
                if (ch > 127) {
                    continue; // ASCII only
                }
                
                const uv = font.char_uv[ch];
                const sz = 5.0 * scale;
                
                try s.pushQuad(
                    .{
                        .pos   = .{ cx, y },
                        .uv    = .{ uv[0], 0.0 },
                        .color = color,
                    },
                    .{
                        .pos   = .{ cx + sz, y },
                        .uv    = .{ uv[1], 0.0 },
                        .color = color,
                    },
                    .{
                        .pos   = .{ cx, y + sz },
                        .uv    = .{ uv[0], 1.0 },
                        .color = color,
                    },
                    .{
                        .pos   = .{ cx + sz, y + sz },
                        .uv    = .{ uv[1], 1.0 },
                        .color = color,
                    },
                );
                
                cx += 6.0 * scale; // Spacing logic
            }
        }

        /// Queues a colored solid rectangle.
        pub fn drawRect(s: *@This(), x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
            const u = font.char_uv[127][0] + (2.0 / 640.0); // Sample a solid white pixel from the atlas
            
            try s.pushQuad(
                .{
                    .pos   = .{ x, y },
                    .uv    = .{ u, 0.5 },
                    .color = color,
                },
                .{
                    .pos   = .{ x + w, y },
                    .uv    = .{ u, 0.5 },
                    .color = color,
                },
                .{
                    .pos   = .{ x, y + h },
                    .uv    = .{ u, 0.5 },
                    .color = color,
                },
                .{
                    .pos   = .{ x + w, y + h },
                    .uv    = .{ u, 0.5 },
                    .color = color,
                },
            );
        }

        /// Uploads all dynamically queued UI vertices to the GPU arena.
        /// Must be called after all draws but BEFORE `beginRenderPass`.
        pub fn upload(s: *@This(), cmd: *c.SDL_GPUCommandBuffer) !void {
            if (s.indices.items.len == 0) {
                return;
            }
            
            const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
                return error.CopyPassFailed;
            };
            
            s.vbo.reset(); 
            s.ibo.reset();
            
            _ = try s.vbo.push(s.dev, copy_pass, std.mem.sliceAsBytes(s.verts.items));
            _ = try s.ibo.push(s.dev, copy_pass, std.mem.sliceAsBytes(s.indices.items));
            
            c.SDL_EndGPUCopyPass(copy_pass);
        }

        /// Submits the single massive UI drawcall and clears the dynamic arrays.
        /// Must be called DURING an active `beginRenderPass`.
        pub fn flush(s: *@This()) void {
            const idx_count = @as(u32, @intCast(s.indices.items.len));
            if (idx_count == 0) {
                return;
            }
            
            const rp = s.dev.pass orelse {
                return;
            };
            
            c.SDL_BindGPUGraphicsPipeline(rp, s.pipe);
            
            const vb = [_]c.SDL_GPUBufferBinding{.{ .buffer = s.vbo.handle.?, .offset = 0 }};
            c.SDL_BindGPUVertexBuffers(rp, 0, &vb, 1);
            
            c.SDL_BindGPUIndexBuffer(rp, &.{ .buffer = s.ibo.handle.?, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
            
            const sb = [_]c.SDL_GPUTextureSamplerBinding{.{ .texture = s.atlas_tex, .sampler = s.atlas_sampler }};
            c.SDL_BindGPUFragmentSamplers(rp, 0, &sb, 1);
            
            // Orthographic projection fits the screen dimensions (1 unit = 1 pixel)
            const ortho_matrix = math.ortho(
                0,
                @floatFromInt(s.dev.width),
                @floatFromInt(s.dev.height),
                0,
                -1,
                1
            );
            
            memory.pushUniform(s.dev.cmd.?, 0, ortho_matrix);
            c.SDL_DrawGPUIndexedPrimitives(rp, idx_count, 1, 0, 0, 0);

            s.verts.clearRetainingCapacity(); 
            s.indices.clearRetainingCapacity();
        }
    };
};

// Top-level aliases for easy access natively mirroring standard engine implementations
pub const Device = core.Device;
pub const Scene = systems.Scene;
pub const Ui = systems.Ui;
pub const Input = systems.Input;

// ============================================================================
// 4. MATH: Fixed-point primitives and fast integer abstractions 
// ============================================================================
pub const math = struct {
    /// Optimized software math library prioritizing deterministic integer and fixed-point operations.
    pub const EPSILON: i64  = 64; 
    pub const Vec3          = @Vector(3, i32);

    /// Converts a float to 10-bit fractional fixed-point.
    pub inline fn fix(f: f32) i32 {
        return @intFromFloat(f * 1024.0);
    }
    
    /// Converts a 10-bit fractional fixed-point back to float.
    pub inline fn flt(i: i32) f32 {
        return @as(f32, @floatFromInt(i)) * 0.0009765625;
    }
    
    /// Multiplies two fixed point values.
    pub inline fn mul(a: i32, b: i32) i32 {
        return @intCast((@as(i64, a) * b) >> 10);
    }
    
    /// Divides two fixed point values.
    pub inline fn div(a: i32, b: i32) i32 {
        return @intCast(@divTrunc(@as(i64, a) << 10, b));
    }

    /// Unit abstraction wrapper to explicitly type system scalar units from raw i32
    pub const Unit = struct {
        v: i32,
        pub const ZERO = Unit{ .v = 0 };
        pub const ONE = Unit{ .v = 1024 };

        pub inline fn fix(f: f32) Unit { return .{ .v = math.fix(f) }; }
        pub inline fn raw(i: i32) Unit { return .{ .v = i }; }
        pub inline fn flt(u: Unit) f32 { return math.flt(u.v); }
        
        pub inline fn mul(a: Unit, b: Unit) Unit { return .{ .v = math.mul(a.v, b.v) }; }
        pub inline fn div(a: Unit, b: Unit) Unit { return .{ .v = math.div(a.v, b.v) }; }
        pub inline fn add(a: Unit, b: Unit) Unit { return .{ .v = a.v + b.v }; }
        pub inline fn sub(a: Unit, b: Unit) Unit { return .{ .v = a.v - b.v }; }
        pub inline fn neg(a: Unit) Unit { return .{ .v = -a.v }; }
    };

    /// Scales a vector by a fixed point integer.
    pub inline fn scale(a: Vec3, s: Unit) Vec3 {
        const prod = @as(@Vector(3, i64), a) * @as(@Vector(3, i64), @splat(s.v));
        return @truncate((prod + @as(@Vector(3, i64), @splat(512))) >> @as(@Vector(3, u6), @splat(10)));
    }
    
    pub inline fn dot(a: Vec3, b: Vec3) Unit {
        const prod = @reduce(.Add, @as(@Vector(3, i64), a) * @as(@Vector(3, i64), b));
        return .{ .v = @intCast((prod + 512) >> 10) };
    }
    
    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            @intCast(((@as(i64, a[1]) * b[2] - @as(i64, a[2]) * b[1]) + 512) >> 10),
            @intCast(((@as(i64, a[2]) * b[0] - @as(i64, a[0]) * b[2]) + 512) >> 10),
            @intCast(((@as(i64, a[0]) * b[1] - @as(i64, a[1]) * b[0]) + 512) >> 10),
        };
    }
    
    pub inline fn lenSq(a: Vec3) i64 {
        const a64: @Vector(3, i64) = a;
        return @reduce(.Add, a64 * a64);
    }
    
    pub inline fn len(a: Vec3) Unit {
        const d = lenSq(a);
        if (d <= 0) {
            return Unit.ZERO;
        }
        return .{ .v = @intCast(std.math.sqrt(@as(u64, @intCast(d)))) };
    }

    /// Quake-style integer fast inverse square root using Count-Leading-Zeros (clz).
    const inv_sq_lut: [256]u16 = init: {
        @setEvalBranchQuota(10_000);
        var arr: [256]u16 = undefined;
        
        for (256..512) |i| {
            arr[i - 256] = @intFromFloat(@round((1.0 / std.math.sqrt(@as(f64, @floatFromInt(i)))) * 32768.0));
        }
        
        break :init arr;
    };

    /// Normalizes a vector rapidly using the clz-based fast inverse square root lookup.
    pub inline fn norm(a: Vec3) Vec3 {
        const d = @as(u64, @intCast(@max(0, lenSq(a))));
        if (d == 0) {
            return .{ 0, 0, 0 };
        }
        
        const b     = 63 - @clz(d);
        const shift = @as(i32, b) - 8;
        
        const mantissa: usize = @intCast(if (shift >= 0) d >> @intCast(shift) else d << @intCast(-shift));
        
        var inv_len: u32 = inv_sq_lut[mantissa - 256];
        if ((b & 1) == 1) {
            inv_len = @intCast((@as(u64, inv_len) * 46340) >> 16);
        }
        
        return @truncate(
            (@as(@Vector(3, i64), a) * @as(@Vector(3, i64), @splat(inv_len))) >> 
            @as(@Vector(3, u6), @splat(@as(u6, @intCast(1 + (@as(u32, b) >> 1)))))
        );
    }

    /// Matrix multiplication standard float logic (primarily for MVP generation).
    pub inline fn mulMat(a: [16]f32, b: [16]f32) [16]f32 {
        var r: [16]f32 = undefined;
        
        inline for (0..4) |col| {
            inline for (0..4) |row| {
                var s: f32 = 0;
                inline for (0..4) |k| {
                    s += a[k * 4 + row] * b[col * 4 + k];
                }
                r[col * 4 + row] = s;
            }
        }
        
        return r;
    }
    
    /// Generates a standard floating-point 4x4 perspective projection matrix.
    pub inline fn persp(fov: f32, asp: f32, near: f32, far: f32) [16]f32 {
        const t = std.math.tan(fov * std.math.pi / 360.0) * near;
        const r = t * asp;
        
        return .{ 
            near / r, 0,        0,                                0, 
            0,        near / t, 0,                                0, 
            0,        0,       -(far + near) / (far - near),     -1, 
            0,        0,       -(2 * far * near) / (far - near),  0, 
        };
    }
    
    /// Generates a standard floating-point orthographic projection matrix.
    pub inline fn ortho(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) [16]f32 {
        return .{ 
            2.0 / (r - l),      0,                  0,                  0, 
            0,                  2.0 / (t - b),      0,                  0, 
            0,                  0,                 -2.0 / (f - n),      0, 
           -(r + l) / (r - l), -(t + b) / (t - b), -(f + n) / (f - n),  1.0, 
        };
    }

    /// Represent angles purely as wrapped integers, removing the need for float fmod routines.
    pub const Angle = packed struct(u64) {
        x:    u16 = 0, 
        y:    u16 = 0, 
        _pad: u32 = 0,
        
        const lut: [16385]i16 = init: {
            @setEvalBranchQuota(1_000_000);
            var arr: [16385]i16 = undefined;
            
            for (0..16385) |i| {
                arr[i] = @intFromFloat(@round(std.math.sin(@as(f64, @floatFromInt(i)) * (std.math.pi / 32768.0)) * 1024.0));
            }
            
            break :init arr;
        };
        
        pub inline fn sin(val: u16) Unit {
            const rem = val & 0x3FFF;
            return .{ .v = switch (@as(u2, @truncate(val >> 14))) { 
                0 =>  lut[rem], 
                1 =>  lut[16384 - rem], 
                2 => -lut[rem], 
                3 => -lut[16384 - rem],
            } };
        }
        
        pub inline fn cos(val: u16) Unit {
            const rem = val & 0x3FFF;
            return .{ .v = switch (@as(u2, @truncate(val >> 14))) { 
                0 =>  lut[16384 - rem], 
                1 => -lut[rem], 
                2 => -lut[16384 - rem], 
                3 =>  lut[rem],
            } };
        }
        
        pub inline fn addX(s: @This(), offset: i32) @This() { 
            var n = s; 
            n.x +%= @as(u16, @truncate(@as(u32, @bitCast(offset)))); 
            return n; 
        }
        
        pub inline fn addY(s: @This(), offset: i32) @This() { 
            var n = s; 
            n.y +%= @as(u16, @truncate(@as(u32, @bitCast(offset)))); 
            return n; 
        }
        
        pub inline fn clampPitch(s: @This()) @This() {
            var n = s;
            
            if (n.x > 16384 and n.x < 32768) {
                n.x = 16384;
            }
            
            if (n.x < 49152 and n.x >= 32768) {
                n.x = 49152;
            }
            
            return n;
        }
        
        /// Produces a fixed-point forward vector based on current rotation logic.
        pub fn forward(s: @This()) Vec3 {
            const cp = cos(s.x); 
            const sp = sin(s.x);
            const cy = cos(s.y); 
            const sy = sin(s.y);
            
            return .{
                 cp.mul(sy).v,
                -sp.v,
                -cp.mul(cy).v,
            };
        }
    };
};
