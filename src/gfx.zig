//! gfx.zig — Renderer(Gpu): comptime-monomorphised 3D rendering
//!
//! Like Canvas(Backend) for 2D, Renderer(Gpu) adds camera + frustum
//! culling on top of a raw GPU backend — all resolved at comptime.
//!
//! Gpu backend contract (any struct with these methods):
//!   const Handle: type
//!   fn clear(*Self, [4]f32) void
//!   fn setCamera(*Self, view: Mat4, proj: Mat4) void
//!   fn upload(*Self, pos: [][3]f32, nrm: [][3]f32, idx: []u32) !Handle
//!   fn release(*Self, Handle) void
//!   fn draw(*Self, Handle, model: Mat4, color: [4]f32) void

const math = @import("math.zig");
const geo = @import("geo.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub fn Renderer(comptime Gpu: type) type {
    const required = .{ "clear", "setCamera", "upload", "release", "draw" };
    inline for (required) |name| {
        if (!@hasDecl(Gpu, name))
            @compileError("Gpu backend missing required method: '" ++ name ++ "'");
    }

    return struct {
        const Self = @This();
        pub const Handle = Gpu.Handle;

        gpu: Gpu,
        view: Mat4 = Mat4.identity,
        proj: Mat4 = Mat4.identity,
        frust: geo.Frustum = undefined,

        pub fn init(gpu: Gpu) Self { return .{ .gpu = gpu }; }

        /// Set camera.  Computes view + projection + frustum in one call.
        pub fn camera(
            self: *Self,
            eye: Vec3,
            target: Vec3,
            world_up: Vec3,
            fovy: f32,
            aspect: f32,
            near: f32,
            far: f32,
        ) void {
            self.view = Mat4.lookAt(eye, target, world_up);
            self.proj = Mat4.perspective(fovy, aspect, near, far);
            const fwd = target.sub(eye).norm();
            const rt = fwd.cross(world_up).norm();
            const up = rt.cross(fwd);
            self.frust = geo.Frustum.fromCamera(eye, fwd, rt, up, fovy, aspect, near, far);
            self.gpu.setCamera(self.view, self.proj);
        }

        /// Draw with automatic frustum culling.  `bounds` is world-space AABB.
        pub fn draw(self: *Self, handle: Handle, model: Mat4, bounds: geo.AABB, color: [4]f32) void {
            if (!self.frust.containsAABB(bounds)) return;
            self.gpu.draw(handle, model, color);
        }

        /// Draw without culling (skybox, HUD, overlays).
        pub fn drawDirect(self: *Self, handle: Handle, model: Mat4, color: [4]f32) void {
            self.gpu.draw(handle, model, color);
        }

        // ── pass-through ──

        pub fn clear(self: *Self, c: [4]f32) void { self.gpu.clear(c); }
        pub fn upload(self: *Self, p: [][3]f32, n: [][3]f32, i: []u32) !Handle {
            return self.gpu.upload(p, n, i);
        }
        pub fn release(self: *Self, h: Handle) void { self.gpu.release(h); }
    };
}
