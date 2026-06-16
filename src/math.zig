const std = @import("std");

pub const Unit = extern struct {
    v: i32 = 0,

    pub const ZERO = Unit{ .v = 0 };
    pub const ONE = Unit{ .v = 1024 };

    pub inline fn fix(f: f32) Unit { return .{ .v = @intFromFloat(f * 1024.0) }; }
    pub inline fn raw(i: i32) Unit { return .{ .v = i }; }
    
    pub inline fn flt(self: Unit) f32 { return @as(f32, @floatFromInt(self.v)) * 0.0009765625; }

    pub inline fn add(self: Unit, b: Unit) Unit { return .{ .v = self.v + b.v }; }
    pub inline fn sub(self: Unit, b: Unit) Unit { return .{ .v = self.v - b.v }; }
    pub inline fn mul(self: Unit, b: Unit) Unit { return .{ .v = @intCast((@as(i64, self.v) * b.v) >> 10) }; }
    pub inline fn div(self: Unit, b: Unit) Unit { return .{ .v = @intCast(@divTrunc(@as(i64, self.v) << 10, b.v)) }; }
    pub inline fn neg(self: Unit) Unit { return .{ .v = -self.v }; }
    pub inline fn abs(self: Unit) Unit { return .{ .v = if (self.v < 0) -self.v else self.v }; }

    pub inline fn add3(a: [3]Unit, b: [3]Unit) [3]Unit {
        return .{ a[0].add(b[0]), a[1].add(b[1]), a[2].add(b[2]) };
    }
    pub inline fn sub3(a: [3]Unit, b: [3]Unit) [3]Unit {
        return .{ a[0].sub(b[0]), a[1].sub(b[1]), a[2].sub(b[2]) };
    }
    pub inline fn scale3(a: [3]Unit, s: Unit) [3]Unit {
        return .{ a[0].mul(s), a[1].mul(s), a[2].mul(s) };
    }
    pub inline fn dot3(a: [3]Unit, b: [3]Unit) Unit {
        return a[0].mul(b[0]).add(a[1].mul(b[1])).add(a[2].mul(b[2]));
    }
    pub inline fn cross3(a: [3]Unit, b: [3]Unit) [3]Unit {
        return .{
            a[1].mul(b[2]).sub(a[2].mul(b[1])),
            a[2].mul(b[0]).sub(a[0].mul(b[2])),
            a[0].mul(b[1]).sub(a[1].mul(b[0])),
        };
    }

    pub inline fn lerp(a: [3]Unit, b: [3]Unit, num: i32, den: i32) [3]Unit {
        if (den == 0) return a;
        return .{
            raw(a[0].v + @as(i32, @intCast(@divTrunc(@as(i64, b[0].v - a[0].v) * num, den)))),
            raw(a[1].v + @as(i32, @intCast(@divTrunc(@as(i64, b[1].v - a[1].v) * num, den)))),
            raw(a[2].v + @as(i32, @intCast(@divTrunc(@as(i64, b[2].v - a[2].v) * num, den)))),
        };
    }

    const inv_sq_lut: [256]u16 = init: {
        var arr: [256]u16 = undefined;
        for (256..512) |i| {
            const val = @as(f64, @floatFromInt(i));
            arr[i - 256] = @intFromFloat(@round((1.0 / std.math.sqrt(val)) * 32768.0));
        }
        break :init arr;
    };

    pub inline fn lenSq3(a: [3]Unit) i64 {
        return @as(i64, a[0].v)*a[0].v + @as(i64, a[1].v)*a[1].v + @as(i64, a[2].v)*a[2].v;
    }

    pub inline fn len3(a: [3]Unit) Unit {
        const d = lenSq3(a);
        return if (d <= 0) ZERO else raw(@intCast(std.math.sqrt(@as(u64, @intCast(d))))); 
    }

    pub inline fn norm3(a: [3]Unit) [3]Unit {
        const d = @as(u64, @intCast(@max(0, lenSq3(a))));
        if (d == 0) return .{ ZERO, ZERO, ZERO };

        const b = 63 - @clz(d);
        const is_odd = b & 1;
        const shift = @as(i32, b) - 8;

        const mantissa: usize = @intCast(if (shift >= 0) d >> @intCast(shift) else d << @intCast(-shift));
        var inv_len: u32 = inv_sq_lut[mantissa - 256];
        if (is_odd == 1) inv_len = @intCast((@as(u64, inv_len) * 46340) >> 16);

        const scale_shift = 1 + (@as(u32, b) >> 1);
        
        return .{
            raw(@intCast((@as(i64, a[0].v) * inv_len) >> @intCast(scale_shift))),
            raw(@intCast((@as(i64, a[1].v) * inv_len) >> @intCast(scale_shift))),
            raw(@intCast((@as(i64, a[2].v) * inv_len) >> @intCast(scale_shift))),
        };
    }

    pub inline fn mulMat(a: [16]f32, b: [16]f32) [16]f32 {
        var r: [16]f32 = undefined;
        inline for (0..4) |c| {
            inline for (0..4) |row| {
                var s: f32 = 0;
                inline for (0..4) |k| s += a[k * 4 + row] * b[c * 4 + k];
                r[c * 4 + row] = s;
            }
        }
        return r;
    }

    pub inline fn persp(fov: f32, asp: f32, near: f32, far: f32) [16]f32 {
        const t = @tan(fov * 3.1415926535 / 360.0) * near;
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
};

pub const Angle = packed struct(u64) {
    x: u16 = 0,
    y: u16 = 0,
    scale: u32 = 0,

    const lut: [16385]i16 = init: {
        @setEvalBranchQuota(20000);
        var arr: [16385]i16 = undefined;
        for (0..16385) |i| {
            const rad = @as(f64, @floatFromInt(i)) * (std.math.pi / 32768.0);
            arr[i] = @intFromFloat(@round(@sin(rad) * 1024.0));
        }
        break :init arr;
    };

    pub inline fn sin(val: u16) Unit {
        const quad: u2 = @truncate(val >> 14);
        const rem = val & 0x3FFF;
        return Unit.raw(switch (quad) {
            0 => lut[rem],
            1 => lut[16384 - rem],
            2 => -lut[rem],
            3 => -lut[16384 - rem],
        });
    }

    pub inline fn cos(val: u16) Unit {
        const quad: u2 = @truncate(val >> 14);
        const rem = val & 0x3FFF;
        return Unit.raw(switch (quad) {
            0 => lut[16384 - rem],
            1 => -lut[rem],
            2 => -lut[16384 - rem],
            3 => lut[rem],
        });
    }

    pub inline fn addX(self: Angle, offset: i32) Angle {
        var n = self;
        n.x +%= @as(u16, @truncate(@as(u32, @bitCast(offset))));
        return n;
    }

    pub inline fn addY(self: Angle, offset: i32) Angle {
        var n = self;
        n.y +%= @as(u16, @truncate(@as(u32, @bitCast(offset))));
        return n;
    }

    pub inline fn clampPitch(self: Angle) Angle {
        var n = self;
        if (n.x > 16384 and n.x < 32768) n.x = 16384;
        if (n.x < 49152 and n.x >= 32768) n.x = 49152;
        return n;
    }

    pub inline fn wishdir(self: Angle, fwd: Unit, right: Unit) [3]Unit {
        const sy = sin(self.y);
        const cy = cos(self.y);
        const fwd_v = [3]Unit{ sy.mul(fwd), Unit.ZERO, cy.mul(fwd).neg() };
        const rgt_v = [3]Unit{ cy.mul(right), Unit.ZERO, sy.mul(right) };
        return Unit.norm3(Unit.add3(fwd_v, rgt_v));
    }

    pub inline fn view(self: Angle, pos: [3]Unit, eye_h: Unit) [16]f32 {
        const ex = pos[0].flt();
        const ey = pos[1].add(eye_h).flt();
        const ez = pos[2].flt();

        const cy = cos(self.y).flt();
        const sy = sin(self.y).flt();
        const cp = cos(self.x).flt();
        const sp = sin(self.x).flt();
        
        return .{
            cy, sy * sp, -sy * cp, 0,
            0, cp, sp, 0,
            sy, -cy * sp, cy * cp, 0,
            -ex * cy - ez * sy,
            -ex * sy * sp - ey * cp + ez * cy * sp,
            ex * sy * cp - ey * sp - ez * cy * cp,
            1,
        };
    }
};
