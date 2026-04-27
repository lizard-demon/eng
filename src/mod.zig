//! mod.zig — engine re-exports
pub const math = @import("math.zig");
pub const geo = @import("geo.zig");
pub const mesh = @import("mesh.zig");
pub const phys = @import("phys.zig");
pub const Vec3 = math.Vec3;
pub const Mat4 = math.Mat4;
pub const AABB = math.AABB;
pub const Ray = geo.Ray;
pub const Plane = geo.Plane;
pub const Frustum = geo.Frustum;
pub const Vertex = @import("gfx.zig").Vertex;
pub const Bsp = @import("bsp.zig").Bsp;
pub fn Pool(comptime T: type, comptime cap: u16) type { return @import("pool.zig").Pool(T, cap); }
pub fn Renderer(comptime Gpu: type) type { return @import("gfx.zig").Renderer(Gpu); }
pub fn Body(comptime cfg: phys.Config) type { return phys.Body(cfg); }
pub const perspective = math.perspective;
pub const wishdir = math.wishdir;
