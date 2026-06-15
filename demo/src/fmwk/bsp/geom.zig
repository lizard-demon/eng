const std = @import("std");
const math = @import("../math.zig");
const Unit = math.Unit;

pub const Plane = struct {
    normal: [3]Unit,
    dist: Unit,

    pub inline fn distToPoint(self: Plane, p: [3]Unit) Unit {
        return Unit.dot3(self.normal, p).add(self.dist);
    }
};

pub const Poly = struct {
    verts: [48][3]Unit = undefined,
    len: usize = 0,

    pub fn initInfinite(plane: Plane, size: Unit) Poly {
        var poly = Poly{ .len = 4 };
        const n = plane.normal;
        
        const ref = if (n[1].abs().v < 921)
            [3]Unit{ Unit.ZERO, Unit.ONE, Unit.ZERO } 
        else 
            [3]Unit{ Unit.ONE, Unit.ZERO, Unit.ZERO };

        const t1 = Unit.norm3(Unit.cross3(n, ref));
        const t2 = Unit.norm3(Unit.cross3(n, t1));
        const c = Unit.scale3(n, plane.dist.neg());

        poly.verts[0] = Unit.sub3(Unit.sub3(c, Unit.scale3(t1, size)), Unit.scale3(t2, size));
        poly.verts[1] = Unit.sub3(Unit.add3(c, Unit.scale3(t1, size)), Unit.scale3(t2, size));
        poly.verts[2] = Unit.add3(Unit.add3(c, Unit.scale3(t1, size)), Unit.scale3(t2, size));
        poly.verts[3] = Unit.add3(Unit.sub3(c, Unit.scale3(t1, size)), Unit.scale3(t2, size));

        return poly;
    }

    pub fn clip(self: *const Poly, plane: Plane) Poly {
        var out = Poly{};
        if (self.len < 3) return out;

        for (0..self.len) |i| {
            const a = self.verts[i];
            const b = self.verts[(i + 1) % self.len];
            
            const da = plane.distToPoint(a);
            const db = plane.distToPoint(b);

            if (da.v >= -1) {
                if (out.len < 48) {
                    out.verts[out.len] = a;
                    out.len += 1;
                }
                if (db.v < -1 and out.len < 48) {
                    // Replaced low-precision unit quantization with exact interpolation
                    out.verts[out.len] = Unit.lerp(a, b, da.v, da.v - db.v);
                    out.len += 1;
                }
            } else if (db.v >= -1 and out.len < 48) {
                out.verts[out.len] = Unit.lerp(a, b, da.v, da.v - db.v);
                out.len += 1;
            }
        }
        return if (out.len >= 3) out else Poly{};
    }

    pub const SplitResult = struct { f: Poly, b: Poly };

    pub fn split(self: *const Poly, plane: Plane) SplitResult {
        var res = SplitResult{ .f = Poly{}, .b = Poly{} };
        if (self.len < 3) return res;

        var dists: [48]Unit = undefined;
        var has_front = false;
        var has_back = false;

        for (0..self.len) |i| {
            dists[i] = plane.distToPoint(self.verts[i]);
            if (dists[i].v > 1) has_front = true;
            if (dists[i].v < -1) has_back = true;
        }

        if (!has_back) return .{ .f = self.*, .b = Poly{} };
        if (!has_front) return .{ .f = Poly{}, .b = self.* };

        for (0..self.len) |i| {
            const p1 = self.verts[i];
            const p2 = self.verts[(i + 1) % self.len];
            const d1 = dists[i];
            const d2 = dists[(i + 1) % self.len];

            if (d1.v >= -1 and res.f.len < 48) {
                res.f.verts[res.f.len] = p1;
                res.f.len += 1;
            }
            if (d1.v <= 1 and res.b.len < 48) {
                res.b.verts[res.b.len] = p1;
                res.b.len += 1;
            }

            if ((d1.v > 1 and d2.v < -1) or (d1.v < -1 and d2.v > 1)) {
                // Exact interpolation
                const mid = Unit.lerp(p1, p2, d1.v, d1.v - d2.v);
                
                if (res.f.len < 48) { res.f.verts[res.f.len] = mid; res.f.len += 1; }
                if (res.b.len < 48) { res.b.verts[res.b.len] = mid; res.b.len += 1; }
            }
        }

        if (res.f.len < 3) res.f.len = 0;
        if (res.b.len < 3) res.b.len = 0;
        return res;
    }
};
