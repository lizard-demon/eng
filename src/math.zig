//! math.zig — SIMD linear algebra, column-major matrices
const std = @import("std");

pub const Vec3 = packed struct {
    data: @Vector(3, f32),
    pub inline fn new(x: f32, y: f32, z: f32) Vec3 { return .{ .data = .{ x, y, z } }; }
    pub inline fn zero() Vec3 { return .{ .data = @splat(0) }; }
    pub inline fn one() Vec3 { return .{ .data = @splat(1) }; }
    pub inline fn splat(s: f32) Vec3 { return .{ .data = @splat(s) }; }
    pub inline fn add(v: Vec3, o: Vec3) Vec3 { return .{ .data = v.data + o.data }; }
    pub inline fn sub(v: Vec3, o: Vec3) Vec3 { return .{ .data = v.data - o.data }; }
    pub inline fn mul(v: Vec3, o: Vec3) Vec3 { return .{ .data = v.data * o.data }; }
    pub inline fn neg(v: Vec3) Vec3 { return .{ .data = -v.data }; }
    pub inline fn scale(v: Vec3, s: f32) Vec3 { return .{ .data = v.data * @as(@Vector(3, f32), @splat(s)) }; }
    pub inline fn dot(v: Vec3, o: Vec3) f32 { return @reduce(.Add, v.data * o.data); }
    pub inline fn lengthSq(v: Vec3) f32 { return dot(v, v); }
    pub inline fn length(v: Vec3) f32 { return @sqrt(lengthSq(v)); }
    pub inline fn dist(a: Vec3, b: Vec3) f32 { return length(sub(a, b)); }
    pub inline fn normalize(v: Vec3) Vec3 { const l = length(v); return if (l > 0) scale(v, 1.0 / l) else v; }
    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3.new(
            a.data[1] * b.data[2] - a.data[2] * b.data[1],
            a.data[2] * b.data[0] - a.data[0] * b.data[2],
            a.data[0] * b.data[1] - a.data[1] * b.data[0],
        );
    }
    pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 { return add(a, sub(b, a).scale(t)); }
    pub inline fn min(a: Vec3, b: Vec3) Vec3 { return .{ .data = @min(a.data, b.data) }; }
    pub inline fn max(a: Vec3, b: Vec3) Vec3 { return .{ .data = @max(a.data, b.data) }; }
};

pub const AABB = packed struct {
    lo: Vec3,
    hi: Vec3,

    pub fn new(lo: Vec3, hi: Vec3) AABB { return .{ .lo = lo, .hi = hi }; }
    pub fn fromCenterSize(c: Vec3, s: Vec3) AABB {
        const h = Vec3.scale(s, 0.5);
        return .{ .lo = Vec3.sub(c, h), .hi = Vec3.add(c, h) };
    }
    pub fn intersects(a: AABB, b: AABB) bool {
        return a.lo.data[0] <= b.hi.data[0] and a.hi.data[0] >= b.lo.data[0] and
            a.lo.data[1] <= b.hi.data[1] and a.hi.data[1] >= b.lo.data[1] and
            a.lo.data[2] <= b.hi.data[2] and a.hi.data[2] >= b.lo.data[2];
    }
    pub fn containsPoint(a: AABB, p: Vec3) bool {
        return p.data[0] >= a.lo.data[0] and p.data[0] <= a.hi.data[0] and
            p.data[1] >= a.lo.data[1] and p.data[1] <= a.hi.data[1] and
            p.data[2] >= a.lo.data[2] and p.data[2] <= a.hi.data[2];
    }
    pub fn merge(a: AABB, b: AABB) AABB { return .{ .lo = Vec3.min(a.lo, b.lo), .hi = Vec3.max(a.hi, b.hi) }; }
    pub fn expand(a: AABB, p: Vec3) AABB { return .{ .lo = Vec3.min(a.lo, p), .hi = Vec3.max(a.hi, p) }; }
    pub fn center(a: AABB) Vec3 { return Vec3.scale(Vec3.add(a.lo, a.hi), 0.5); }
    pub fn pad(a: AABB, r: f32) AABB {
        const rv = Vec3.splat(r);
        return .{ .lo = Vec3.sub(a.lo, rv), .hi = Vec3.add(a.hi, rv) };
    }
    pub fn surfaceArea(a: AABB) f32 {
        const d = Vec3.sub(a.hi, a.lo);
        return 2.0 * (d.data[0] * d.data[1] + d.data[1] * d.data[2] + d.data[2] * d.data[0]);
    }
    pub fn transform(a: AABB, m: Mat4) AABB {
        const inf = std.math.floatMax(f32);
        var r = AABB{ .lo = Vec3.splat(inf), .hi = Vec3.splat(-inf) };
        for ([_]f32{ a.lo.data[0], a.hi.data[0] }) |x| {
            for ([_]f32{ a.lo.data[1], a.hi.data[1] }) |y| {
                for ([_]f32{ a.lo.data[2], a.hi.data[2] }) |z| {
                    r = r.expand(m.mulVec3(Vec3.new(x, y, z)));
                }
            }
        }
        return r;
    }

    pub const empty: AABB = .{
        .lo = Vec3{ .data = .{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) } },
        .hi = Vec3{ .data = .{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) } },
    };
};

pub const Mat4 = struct {
    data: [16]f32,

    pub inline fn identity() Mat4 {
        return .{ .data = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
    }

    pub inline fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        inline for (0..4) |c| {
            inline for (0..4) |row| {
                var s: f32 = 0;
                inline for (0..4) |k| s += a.data[k * 4 + row] * b.data[c * 4 + k];
                r.data[c * 4 + row] = s;
            }
        }
        return r;
    }

    pub inline fn mulVec(m: Mat4, v: Vec3) @Vector(4, f32) {
        return .{
            m.data[0] * v.data[0] + m.data[4] * v.data[1] + m.data[8]  * v.data[2] + m.data[12],
            m.data[1] * v.data[0] + m.data[5] * v.data[1] + m.data[9]  * v.data[2] + m.data[13],
            m.data[2] * v.data[0] + m.data[6] * v.data[1] + m.data[10] * v.data[2] + m.data[14],
            m.data[3] * v.data[0] + m.data[7] * v.data[1] + m.data[11] * v.data[2] + m.data[15],
        };
    }

    pub inline fn mulVec3(m: Mat4, v: Vec3) Vec3 {
        const r = mulVec(m, v);
        return Vec3.new(r[0], r[1], r[2]);
    }

    pub inline fn translate(v: Vec3) Mat4 {
        return .{ .data = .{ 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  v.data[0], v.data[1], v.data[2], 1 } };
    }

    pub inline fn scaling(v: Vec3) Mat4 {
        return .{ .data = .{ v.data[0], 0, 0, 0,  0, v.data[1], 0, 0,  0, 0, v.data[2], 0,  0, 0, 0, 1 } };
    }

    pub inline fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return .{ .data = .{
            s.data[0],   u.data[0],   -f.data[0],  0,
            s.data[1],   u.data[1],   -f.data[1],  0,
            s.data[2],   u.data[2],   -f.data[2],  0,
            -s.dot(eye), -u.dot(eye),  f.dot(eye),  1,
        } };
    }

    /// Direct Euler → view matrix (single trig evaluation).
    pub inline fn viewMatrix(pos: Vec3, yaw: f32, pitch: f32, eye_height: f32) Mat4 {
        const eye = Vec3.add(pos, Vec3.new(0, eye_height, 0));
        const cy = @cos(yaw);   const sy = @sin(yaw);
        const cp = @cos(pitch); const sp = @sin(pitch);
        return .{ .data = .{
            cy,
            sy * sp,
            -sy * cp,
            0,
            0,
            cp,
            sp,
            0,
            sy,
            -cy * sp,
            cy * cp,
            0,
            -eye.data[0] * cy  - eye.data[2] * sy,
            -eye.data[0] * sy * sp - eye.data[1] * cp + eye.data[2] * cy * sp,
             eye.data[0] * sy * cp - eye.data[1] * sp - eye.data[2] * cy * cp,
            1,
        } };
    }
};

pub inline fn perspective(fov: f32, asp: f32, near: f32, far: f32) Mat4 {
    const t = @tan(fov * std.math.pi / 360.0) * near;
    const r = t * asp;
    return .{ .data = .{
        near / r, 0,        0,                          0,
        0,        near / t, 0,                          0,
        0,        0,        -(far + near) / (far - near), -1,
        0,        0,        -(2 * far * near) / (far - near), 0,
    } };
}

pub inline fn wishdir(fwd: f32, right: f32, yaw: f32) Vec3 {
    const fwd_vec  = Vec3.new(@sin(yaw), 0, -@cos(yaw));
    const side_vec = Vec3.new(@cos(yaw), 0,  @sin(yaw));
    return Vec3.add(Vec3.scale(fwd_vec, fwd), Vec3.scale(side_vec, right));
}
