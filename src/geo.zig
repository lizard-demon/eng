//! geo.zig — spatial queries: Ray, Plane, Frustum

const std = @import("std");
const math = @import("math.zig");
const Vec3 = math.Vec3;
const AABB = math.AABB;

pub const Ray = struct {
    origin: Vec3,
    dir: Vec3,
    pub fn at(self: Ray, t: f32) Vec3 { return self.origin.add(self.dir.scale(t)); }
    pub fn hitAABB(self: Ray, box: AABB, max_t: f32) ?f32 {
        var tmin: f32 = 0;
        var tmax: f32 = max_t;
        for (0..3) |i| {
            if (@abs(self.dir.data[i]) < 1e-8) {
                if (self.origin.data[i] < box.lo.data[i] or self.origin.data[i] > box.hi.data[i]) return null;
            } else {
                const inv = 1.0 / self.dir.data[i];
                var t1 = (box.lo.data[i] - self.origin.data[i]) * inv;
                var t2 = (box.hi.data[i] - self.origin.data[i]) * inv;
                if (t1 > t2) { const tmp = t1; t1 = t2; t2 = tmp; }
                tmin = @max(tmin, t1);
                tmax = @min(tmax, t2);
                if (tmin > tmax) return null;
            }
        }
        return tmin;
    }
};

pub const Plane = struct {
    normal: Vec3,
    dist: f32,
    pub fn distToPoint(self: Plane, p: Vec3) f32 { return self.normal.dot(p) + self.dist; }
    pub fn rayIntersect(self: Plane, ro: Vec3, rd: Vec3) ?f32 {
        const den = self.normal.dot(rd);
        if (@abs(den) < 1e-7) return null;
        const t = -(self.normal.dot(ro) + self.dist) / den;
        return if (t >= 0) t else null;
    }
};

pub const Frustum = struct {
    planes: [6]Plane,

    pub fn fromCamera(eye: Vec3, fwd: Vec3, rt: Vec3, u: Vec3, fovy: f32, aspect: f32, near: f32, far: f32) Frustum {
        const hy = @tan(fovy * 0.5);
        const hx = hy * aspect;
        var p: [6]Plane = undefined;
        p[0] = .{ .normal = fwd, .dist = -(fwd.dot(eye) + near) };
        p[1] = .{ .normal = fwd.neg(), .dist = fwd.dot(eye) + far };
        p[2] = .{ .normal = u.cross(fwd.add(rt.scale(hx))).normalize(), .dist = 0 };
        p[3] = .{ .normal = fwd.sub(rt.scale(hx)).cross(u).normalize(), .dist = 0 };
        p[4] = .{ .normal = fwd.add(u.scale(hy)).cross(rt).normalize(), .dist = 0 };
        p[5] = .{ .normal = rt.cross(fwd.sub(u.scale(hy))).normalize(), .dist = 0 };
        for (2..6) |i| p[i].dist = -p[i].normal.dot(eye);
        return .{ .planes = p };
    }

    pub fn containsAABB(self: Frustum, box: AABB) bool {
        for (self.planes) |p| {
            const pv = Vec3.new(
                if (p.normal.data[0] >= 0) box.hi.data[0] else box.lo.data[0],
                if (p.normal.data[1] >= 0) box.hi.data[1] else box.lo.data[1],
                if (p.normal.data[2] >= 0) box.hi.data[2] else box.lo.data[2],
            );
            if (p.normal.dot(pv) + p.dist < 0) return false;
        }
        return true;
    }
};
