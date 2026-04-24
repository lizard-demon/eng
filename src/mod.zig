//! mod.zig — public re-exports for the game engine framework
//!
//! Everything comptime-generic. No vtables. No runtime overhead.
//!
//!   const eng = @import("engine");
//!   const Renderer = eng.Renderer(MyGpuBackend);
//!   const Player   = eng.Body(.{ .gravity = 12 });

pub const math = @import("math.zig");
pub const geo = @import("geo.zig");
pub const mesh = @import("mesh.zig");
pub const phys = @import("phys.zig");

// ── frequently-used types ─────────────────────────────────────────

pub const Vec2 = math.Vec2;
pub const Vec3 = math.Vec3;
pub const Vec4 = math.Vec4;
pub const Mat4 = math.Mat4;
pub const Quat = math.Quat;

pub const AABB = geo.AABB;
pub const Ray = geo.Ray;
pub const Frustum = geo.Frustum;
pub const Plane = geo.Plane;
pub const Sphere = geo.Sphere;

// ── comptime generics ─────────────────────────────────────────────

pub fn BVH(comptime T: type) type { return @import("bvh.zig").BVH(T); }
pub fn Pool(comptime T: type, comptime cap: u16) type { return @import("pool.zig").Pool(T, cap); }
pub fn Renderer(comptime Gpu: type) type { return @import("gfx.zig").Renderer(Gpu); }
pub fn Body(comptime cfg: phys.Config) type { return phys.Body(cfg); }
