//! gfx.zig — Renderer(Gpu): comptime-monomorphised 3D rendering
//!
//! Gpu backend contract:
//!   const Handle: type
//!   fn beginFrame(*Self) !bool
//!   fn endFrame(*Self) !void
//!   fn upload(*Self, verts: []const u8, v_size: u32, indices: []const u8, i_count: u32) !Handle
//!   fn release(*Self, Handle) void
//!   fn draw(*Self, Handle, mvp: Mat4, color: [4]f32) void

const math = @import("math.zig");
const geo = @import("geo.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

/// Standard interleaved vertex: position + color.
/// Fragment shader derives normals via dFdx/dFdy of world_pos.
pub const Vertex = extern struct {
    pos: [3]f32,
    color: [4]f32,
};

pub fn Renderer(comptime Gpu: type) type {
    const required = .{ "beginFrame", "endFrame", "upload", "release", "draw" };
    inline for (required) |name| {
        if (!@hasDecl(Gpu, name))
            @compileError("Gpu backend missing '" ++ name ++ "'");
    }

    return struct {
        const Self = @This();
        pub const Handle = Gpu.Handle;

        gpu: Gpu,
        view: Mat4 = Mat4.identity(),
        proj: Mat4 = Mat4.identity(),
        frust: geo.Frustum = undefined,

        pub fn init(gpu: Gpu) Self { return .{ .gpu = gpu }; }

        pub fn camera(self: *Self, eye: Vec3, target: Vec3, world_up: Vec3, fovy: f32, aspect: f32, near: f32, far: f32) void {
            self.view = Mat4.lookAt(eye, target, world_up);
            self.proj = math.perspective(fovy, aspect, near, far);
            const fwd = target.sub(eye).normalize();
            const rt = fwd.cross(world_up).normalize();
            const up = rt.cross(fwd);
            self.frust = geo.Frustum.fromCamera(eye, fwd, rt, up, fovy * 3.14159 / 180.0, aspect, near, far);
        }

        /// Optimised: set view from Euler angles, avoids trig twice.
        pub fn cameraEuler(self: *Self, pos: Vec3, yaw: f32, pitch: f32, eye_height: f32, fovy: f32, aspect: f32, near: f32, far: f32) void {
            self.view = Mat4.viewMatrix(pos, yaw, pitch, eye_height);
            self.proj = math.perspective(fovy, aspect, near, far);
            const sp = @sin(pitch);
            const cp = @cos(pitch);
            const sy = @sin(yaw);
            const cy = @cos(yaw);
            const eye = pos.add(Vec3.new(0, eye_height, 0));
            const fwd = Vec3.new(sy * cp, sp, -cy * cp).normalize();
            const rt = Vec3.new(cy, 0, sy);
            const up = rt.cross(fwd);
            self.frust = geo.Frustum.fromCamera(eye, fwd, rt, up, fovy * 3.14159 / 180.0, aspect, near, far);
        }

        pub fn beginFrame(self: *Self) !bool { return self.gpu.beginFrame(); }
        pub fn endFrame(self: *Self) !void { return self.gpu.endFrame(); }

        pub fn upload(self: *Self, verts: []const u8, v_size: u32, indices: []const u8, i_count: u32) !Handle {
            return self.gpu.upload(verts, v_size, indices, i_count);
        }

        pub fn release(self: *Self, h: Handle) void { self.gpu.release(h); }

        /// Frustum-culled draw.
        pub fn draw(self: *Self, handle: Handle, model: Mat4, box: math.AABB, color: [4]f32) void {
            if (!self.frust.containsAABB(box)) return;
            const mvp = self.proj.mul(self.view).mul(model);
            self.gpu.draw(handle, mvp, color);
        }

        /// Draw without culling (skybox, HUD).
        pub fn drawDirect(self: *Self, handle: Handle, model: Mat4, color: [4]f32) void {
            self.gpu.draw(handle, self.proj.mul(self.view).mul(model), color);
        }
    };
}
