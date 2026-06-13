const V3 = @Vector(3, f32);

pub inline fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return @as([3]f32, @as(V3, a) + @as(V3, b));
}

pub inline fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return @as([3]f32, @as(V3, a) - @as(V3, b));
}

pub inline fn scale(a: [3]f32, s: f32) [3]f32 {
    return @as([3]f32, @as(V3, a) * @as(V3, @splat(s)));
}

pub inline fn dot(a: [3]f32, b: [3]f32) f32 {
    return @reduce(.Add, @as(V3, a) * @as(V3, b));
}

pub inline fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub inline fn normalize(a: [3]f32) [3]f32 {
    const l = @sqrt(dot(a, a));
    if (l > 0) {
        return scale(a, 1.0 / l);
    }
    return a;
}

pub inline fn identity() [16]f32 {
    return .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

pub inline fn mul(a: [16]f32, b: [16]f32) [16]f32 {
    var r: [16]f32 = undefined;
    inline for (0..4) |c| {
        inline for (0..4) |row| {
            var s: f32 = 0;
            inline for (0..4) |k| {
                s += a[k * 4 + row] * b[c * 4 + k];
            }
            r[c * 4 + row] = s;
        }
    }
    return r;
}

pub inline fn view(pos: [3]f32, yaw: f32, pitch: f32, eye_h: f32) [16]f32 {
    const eye = add(pos, .{ 0, eye_h, 0 });
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    
    return .{
        cy, sy * sp, -sy * cp, 0,
        0, cp, sp, 0,
        sy, -cy * sp, cy * cp, 0,
        -eye[0] * cy - eye[2] * sy,
        -eye[0] * sy * sp - eye[1] * cp + eye[2] * cy * sp,
        eye[0] * sy * cp - eye[1] * sp - eye[2] * cy * cp,
        1,
    };
}

pub inline fn persp(fov: f32, asp: f32, near: f32, far: f32) [16]f32 {
    const pi = 3.14159265358979323846;
    const t = @tan(fov * pi / 360.0) * near;
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

pub inline fn wishdir(fwd: f32, right: f32, yaw: f32) [3]f32 {
    const forward_vec = scale(.{ @sin(yaw), 0, -@cos(yaw) }, fwd);
    const right_vec = scale(.{ @cos(yaw), 0, @sin(yaw) }, right);
    return add(forward_vec, right_vec);
}
