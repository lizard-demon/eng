//! math.zig — zero-cost linear algebra
//!
//! Value types, inline methods, zero heap.  Composes via chaining:
//!   pos.add(vel.scale(dt))

const std = @import("std");

// ── Vec2 ──────────────────────────────────────────────────────────

pub const Vec2 = struct {
    v: [2]f32 = .{ 0, 0 },
    pub const zero = Vec2{};
    pub inline fn init(x: f32, y: f32) Vec2 { return .{ .v = .{ x, y } }; }
    pub inline fn add(a: Vec2, b: Vec2) Vec2 { return .{ .v = .{ a.v[0] + b.v[0], a.v[1] + b.v[1] } }; }
    pub inline fn sub(a: Vec2, b: Vec2) Vec2 { return .{ .v = .{ a.v[0] - b.v[0], a.v[1] - b.v[1] } }; }
    pub inline fn scale(a: Vec2, s: f32) Vec2 { return .{ .v = .{ a.v[0] * s, a.v[1] * s } }; }
    pub inline fn dot(a: Vec2, b: Vec2) f32 { return a.v[0] * b.v[0] + a.v[1] * b.v[1]; }
    pub inline fn lenSq(a: Vec2) f32 { return dot(a, a); }
    pub inline fn len(a: Vec2) f32 { return @sqrt(lenSq(a)); }
    pub inline fn norm(a: Vec2) Vec2 { const l = len(a); return if (l > 0) scale(a, 1 / l) else zero; }
};

// ── Vec3 ──────────────────────────────────────────────────────────

pub const Vec3 = struct {
    v: [3]f32 = .{ 0, 0, 0 },

    pub const zero = Vec3{};
    pub const up = Vec3{ .v = .{ 0, 1, 0 } };
    pub const right = Vec3{ .v = .{ 1, 0, 0 } };
    pub const forward = Vec3{ .v = .{ 0, 0, -1 } };

    pub inline fn init(x: f32, y: f32, z: f32) Vec3 { return .{ .v = .{ x, y, z } }; }
    pub inline fn splat(s: f32) Vec3 { return .{ .v = .{ s, s, s } }; }
    pub inline fn add(a: Vec3, b: Vec3) Vec3 { return .{ .v = .{ a.v[0] + b.v[0], a.v[1] + b.v[1], a.v[2] + b.v[2] } }; }
    pub inline fn sub(a: Vec3, b: Vec3) Vec3 { return .{ .v = .{ a.v[0] - b.v[0], a.v[1] - b.v[1], a.v[2] - b.v[2] } }; }
    pub inline fn mul(a: Vec3, b: Vec3) Vec3 { return .{ .v = .{ a.v[0] * b.v[0], a.v[1] * b.v[1], a.v[2] * b.v[2] } }; }
    pub inline fn scale(a: Vec3, s: f32) Vec3 { return .{ .v = .{ a.v[0] * s, a.v[1] * s, a.v[2] * s } }; }
    pub inline fn neg(a: Vec3) Vec3 { return .{ .v = .{ -a.v[0], -a.v[1], -a.v[2] } }; }

    pub inline fn dot(a: Vec3, b: Vec3) f32 { return a.v[0] * b.v[0] + a.v[1] * b.v[1] + a.v[2] * b.v[2]; }
    pub inline fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{ .v = .{
            a.v[1] * b.v[2] - a.v[2] * b.v[1],
            a.v[2] * b.v[0] - a.v[0] * b.v[2],
            a.v[0] * b.v[1] - a.v[1] * b.v[0],
        } };
    }

    pub inline fn lenSq(a: Vec3) f32 { return dot(a, a); }
    pub inline fn len(a: Vec3) f32 { return @sqrt(lenSq(a)); }
    pub inline fn norm(a: Vec3) Vec3 { const l = len(a); return if (l > 0) scale(a, 1 / l) else zero; }
    pub inline fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 { return add(a, sub(b, a).scale(t)); }
    pub inline fn vmin(a: Vec3, b: Vec3) Vec3 { return .{ .v = .{ @min(a.v[0], b.v[0]), @min(a.v[1], b.v[1]), @min(a.v[2], b.v[2]) } }; }
    pub inline fn vmax(a: Vec3, b: Vec3) Vec3 { return .{ .v = .{ @max(a.v[0], b.v[0]), @max(a.v[1], b.v[1]), @max(a.v[2], b.v[2]) } }; }
};

// ── Vec4 ──────────────────────────────────────────────────────────

pub const Vec4 = struct {
    v: [4]f32 = .{ 0, 0, 0, 0 },
    pub inline fn init(x: f32, y: f32, z: f32, w: f32) Vec4 { return .{ .v = .{ x, y, z, w } }; }
    pub inline fn fromVec3(p: Vec3, w: f32) Vec4 { return .{ .v = .{ p.v[0], p.v[1], p.v[2], w } }; }
    pub inline fn xyz(self: Vec4) Vec3 { return .{ .v = .{ self.v[0], self.v[1], self.v[2] } }; }
};

// ── Quat ──────────────────────────────────────────────────────────

pub const Quat = struct {
    v: [4]f32 = .{ 0, 0, 0, 1 }, // x, y, z, w

    pub const identity = Quat{};

    pub fn axisAngle(axis: Vec3, angle: f32) Quat {
        const ha = angle * 0.5;
        const s = @sin(ha);
        const a = axis.norm();
        return .{ .v = .{ a.v[0] * s, a.v[1] * s, a.v[2] * s, @cos(ha) } };
    }

    pub fn mulQ(a: Quat, b: Quat) Quat {
        return .{ .v = .{
            a.v[3] * b.v[0] + a.v[0] * b.v[3] + a.v[1] * b.v[2] - a.v[2] * b.v[1],
            a.v[3] * b.v[1] - a.v[0] * b.v[2] + a.v[1] * b.v[3] + a.v[2] * b.v[0],
            a.v[3] * b.v[2] + a.v[0] * b.v[1] - a.v[1] * b.v[0] + a.v[2] * b.v[3],
            a.v[3] * b.v[3] - a.v[0] * b.v[0] - a.v[1] * b.v[1] - a.v[2] * b.v[2],
        } };
    }

    pub fn rotate(q: Quat, p: Vec3) Vec3 {
        const u = Vec3{ .v = .{ q.v[0], q.v[1], q.v[2] } };
        const s = q.v[3];
        return u.scale(2 * u.dot(p)).add(p.scale(s * s - u.dot(u))).add(u.cross(p).scale(2 * s));
    }

    pub fn normalize(q: Quat) Quat {
        const l = @sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2] + q.v[3] * q.v[3]);
        return if (l > 0) .{ .v = .{ q.v[0] / l, q.v[1] / l, q.v[2] / l, q.v[3] / l } } else identity;
    }

    pub fn slerp(a: Quat, b_in: Quat, t: f32) Quat {
        var d = a.v[0] * b_in.v[0] + a.v[1] * b_in.v[1] + a.v[2] * b_in.v[2] + a.v[3] * b_in.v[3];
        var b = b_in;
        if (d < 0) {
            d = -d;
            b = .{ .v = .{ -b.v[0], -b.v[1], -b.v[2], -b.v[3] } };
        }
        if (d > 0.9995) return (Quat{ .v = .{
            a.v[0] + (b.v[0] - a.v[0]) * t, a.v[1] + (b.v[1] - a.v[1]) * t,
            a.v[2] + (b.v[2] - a.v[2]) * t, a.v[3] + (b.v[3] - a.v[3]) * t,
        } }).normalize();
        const theta = std.math.acos(std.math.clamp(d, -1, 1));
        const st = @sin(theta);
        const sa = @sin((1 - t) * theta) / st;
        const sb = @sin(t * theta) / st;
        return .{ .v = .{
            a.v[0] * sa + b.v[0] * sb, a.v[1] * sa + b.v[1] * sb,
            a.v[2] * sa + b.v[2] * sb, a.v[3] * sa + b.v[3] * sb,
        } };
    }

    pub fn toMat4(q: Quat) Mat4 {
        const x = q.v[0];
        const y = q.v[1];
        const z = q.v[2];
        const w = q.v[3];
        return .{ .m = .{
            .{ 1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y), 0 },
            .{ 2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x), 0 },
            .{ 2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y), 0 },
            .{ 0, 0, 0, 1 },
        } };
    }
};

// ── Mat4 ──────────────────────────────────────────────────────────

pub const Mat4 = struct {
    m: [4][4]f32 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } },

    pub const identity = Mat4{};

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        inline for (0..4) |i| inline for (0..4) |j| {
            r.m[i][j] = a.m[i][0] * b.m[0][j] + a.m[i][1] * b.m[1][j] +
                a.m[i][2] * b.m[2][j] + a.m[i][3] * b.m[3][j];
        };
        return r;
    }

    pub fn mulVec4(self: Mat4, v: Vec4) Vec4 {
        var r: [4]f32 = undefined;
        inline for (0..4) |i| {
            r[i] = self.m[i][0] * v.v[0] + self.m[i][1] * v.v[1] +
                self.m[i][2] * v.v[2] + self.m[i][3] * v.v[3];
        }
        return .{ .v = r };
    }

    pub fn xformPoint(self: Mat4, p: Vec3) Vec3 { return self.mulVec4(Vec4.fromVec3(p, 1)).xyz(); }
    pub fn xformDir(self: Mat4, d: Vec3) Vec3 { return self.mulVec4(Vec4.fromVec3(d, 0)).xyz(); }

    pub fn translate(t: Vec3) Mat4 {
        var r = identity;
        r.m[0][3] = t.v[0];
        r.m[1][3] = t.v[1];
        r.m[2][3] = t.v[2];
        return r;
    }

    pub fn scaling(s: Vec3) Mat4 {
        var r = identity;
        r.m[0][0] = s.v[0];
        r.m[1][1] = s.v[1];
        r.m[2][2] = s.v[2];
        return r;
    }

    pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy * 0.5);
        var r: Mat4 = .{ .m = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } } };
        r.m[0][0] = f / aspect;
        r.m[1][1] = f;
        r.m[2][2] = (far + near) / (near - far);
        r.m[2][3] = 2 * far * near / (near - far);
        r.m[3][2] = -1;
        return r;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, world_up: Vec3) Mat4 {
        const f = target.sub(eye).norm();
        const r = f.cross(world_up).norm();
        const u = r.cross(f);
        var mat = identity;
        mat.m[0] = .{ r.v[0], r.v[1], r.v[2], -r.dot(eye) };
        mat.m[1] = .{ u.v[0], u.v[1], u.v[2], -u.dot(eye) };
        mat.m[2] = .{ -f.v[0], -f.v[1], -f.v[2], f.dot(eye) };
        return mat;
    }

    pub fn transpose(self: Mat4) Mat4 {
        var r: Mat4 = undefined;
        inline for (0..4) |i| inline for (0..4) |j| {
            r.m[i][j] = self.m[j][i];
        };
        return r;
    }
};
