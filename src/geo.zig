//! geo.zig — spatial primitives: AABB, Ray, Plane, Sphere, Frustum
//!
//! Standalone geometry with no backend coupling.

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

// ── AABB ──────────────────────────────────────────────────────────

pub const AABB = struct {
    min: Vec3 = Vec3.splat(std.math.floatMax(f32)),
    max: Vec3 = Vec3.splat(-std.math.floatMax(f32)),

    pub fn init(lo: Vec3, hi: Vec3) AABB { return .{ .min = lo, .max = hi }; }
    pub fn expand(self: AABB, p: Vec3) AABB { return .{ .min = self.min.vmin(p), .max = self.max.vmax(p) }; }
    pub fn merge(a: AABB, b: AABB) AABB { return .{ .min = a.min.vmin(b.min), .max = a.max.vmax(b.max) }; }
    pub fn center(self: AABB) Vec3 { return self.min.add(self.max).scale(0.5); }

    pub fn pad(self: AABB, r: f32) AABB {
        const rv = Vec3.splat(r);
        return .{ .min = self.min.sub(rv), .max = self.max.add(rv) };
    }

    pub fn halfArea(self: AABB) f32 {
        const d = self.max.sub(self.min);
        return d.v[0] * d.v[1] + d.v[1] * d.v[2] + d.v[2] * d.v[0];
    }

    pub fn intersects(a: AABB, b: AABB) bool {
        return a.min.v[0] <= b.max.v[0] and a.max.v[0] >= b.min.v[0] and
            a.min.v[1] <= b.max.v[1] and a.max.v[1] >= b.min.v[1] and
            a.min.v[2] <= b.max.v[2] and a.max.v[2] >= b.min.v[2];
    }

    pub fn containsPoint(self: AABB, p: Vec3) bool {
        return p.v[0] >= self.min.v[0] and p.v[0] <= self.max.v[0] and
            p.v[1] >= self.min.v[1] and p.v[1] <= self.max.v[1] and
            p.v[2] >= self.min.v[2] and p.v[2] <= self.max.v[2];
    }

    /// Conservative world-space AABB after affine transform.
    pub fn transform(self: AABB, mat: Mat4) AABB {
        var r = AABB{};
        for ([_]f32{ self.min.v[0], self.max.v[0] }) |x|
            for ([_]f32{ self.min.v[1], self.max.v[1] }) |y|
                for ([_]f32{ self.min.v[2], self.max.v[2] }) |z| {
                    r = r.expand(mat.xformPoint(Vec3.init(x, y, z)));
                };
        return r;
    }
};

// ── Ray ───────────────────────────────────────────────────────────

pub const Ray = struct {
    origin: Vec3,
    dir: Vec3,

    pub fn at(self: Ray, t: f32) Vec3 { return self.origin.add(self.dir.scale(t)); }

    pub fn hitAABB(self: Ray, box: AABB, max_t: f32) ?f32 {
        var tmin: f32 = 0;
        var tmax: f32 = max_t;
        for (0..3) |i| {
            if (@abs(self.dir.v[i]) < 1e-8) {
                if (self.origin.v[i] < box.min.v[i] or self.origin.v[i] > box.max.v[i]) return null;
            } else {
                const inv = 1.0 / self.dir.v[i];
                var t1 = (box.min.v[i] - self.origin.v[i]) * inv;
                var t2 = (box.max.v[i] - self.origin.v[i]) * inv;
                if (t1 > t2) {
                    const tmp = t1;
                    t1 = t2;
                    t2 = tmp;
                }
                tmin = @max(tmin, t1);
                tmax = @min(tmax, t2);
                if (tmin > tmax) return null;
            }
        }
        return tmin;
    }
};

// ── Plane / Sphere ────────────────────────────────────────────────

pub const Plane = struct {
    normal: Vec3,
    dist: f32,
    pub fn distToPoint(self: Plane, p: Vec3) f32 { return self.normal.dot(p) + self.dist; }
};

pub const Sphere = struct {
    center: Vec3,
    radius: f32,
    pub fn intersectsAABB(self: Sphere, box: AABB) bool {
        const c = self.center.vmax(box.min).vmin(box.max);
        return c.sub(self.center).lenSq() <= self.radius * self.radius;
    }
};

// ── Frustum ───────────────────────────────────────────────────────

pub const Frustum = struct {
    planes: [6]Plane,

    pub fn fromCamera(eye: Vec3, fwd: Vec3, rt: Vec3, u: Vec3, fovy: f32, aspect: f32, near: f32, far: f32) Frustum {
        const hy = @tan(fovy * 0.5);
        const hx = hy * aspect;
        var p: [6]Plane = undefined;
        p[0] = .{ .normal = fwd, .dist = -(fwd.dot(eye) + near) };
        p[1] = .{ .normal = fwd.neg(), .dist = fwd.dot(eye) + far };
        p[2] = .{ .normal = u.cross(fwd.add(rt.scale(hx))).norm(), .dist = 0 };
        p[3] = .{ .normal = fwd.sub(rt.scale(hx)).cross(u).norm(), .dist = 0 };
        p[4] = .{ .normal = fwd.add(u.scale(hy)).cross(rt).norm(), .dist = 0 };
        p[5] = .{ .normal = rt.cross(fwd.sub(u.scale(hy))).norm(), .dist = 0 };
        for (2..6) |i| p[i].dist = -p[i].normal.dot(eye);
        return .{ .planes = p };
    }

    pub fn containsAABB(self: Frustum, box: AABB) bool {
        for (self.planes) |p| {
            const pv = Vec3.init(
                if (p.normal.v[0] >= 0) box.max.v[0] else box.min.v[0],
                if (p.normal.v[1] >= 0) box.max.v[1] else box.min.v[1],
                if (p.normal.v[2] >= 0) box.max.v[2] else box.min.v[2],
            );
            if (p.normal.dot(pv) + p.dist < 0) return false;
        }
        return true;
    }

    pub fn containsSphere(self: Frustum, s: Sphere) bool {
        for (self.planes) |p| if (p.distToPoint(s.center) < -s.radius) return false;
        return true;
    }
};
