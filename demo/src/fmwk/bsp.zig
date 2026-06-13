const std = @import("std");

pub fn BspCore(comptime Vertex: type) type {
    return struct {
        const Self = @This();
        const V3 = @Vector(3, f32);

        inline fn vAdd(a: [3]f32, b: [3]f32) [3]f32 {
            return @as([3]f32, @as(V3, a) + @as(V3, b));
        }

        inline fn vSub(a: [3]f32, b: [3]f32) [3]f32 {
            return @as([3]f32, @as(V3, a) - @as(V3, b));
        }

        inline fn vScale(a: [3]f32, s: f32) [3]f32 {
            return @as([3]f32, @as(V3, a) * @as(V3, @splat(s)));
        }

        inline fn vDot(a: [3]f32, b: [3]f32) f32 {
            return @reduce(.Add, @as(V3, a) * @as(V3, b));
        }

        inline fn vCross(a: [3]f32, b: [3]f32) [3]f32 {
            return .{
                a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0],
            };
        }

        inline fn vNorm(a: [3]f32) [3]f32 {
            const l = @sqrt(vDot(a, a));
            if (l > 0) {
                return vScale(a, 1.0 / l);
            }
            return a;
        }

        inline fn vLerp(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
            return vAdd(a, vScale(vSub(b, a), t));
        }

        pub const empty_leaf: u32 = 0xFFFF_FFFE;
        pub const solid_leaf: u32 = 0xFFFF_FFFF;

        pub inline fn isLeaf(i: u32) bool {
            return i >= empty_leaf;
        }

        pub inline fn isSolid(i: u32) bool {
            return i == solid_leaf;
        }

        pub inline fn isEmpty(i: u32) bool {
            return i == empty_leaf;
        }

        pub const SplitMode = enum { solid, empty };

        pub const Node = struct {
            plane: u32,
            front: u32,
            back: u32,
        };

        pub const Plane = struct {
            normal: [3]f32,
            dist: f32,

            inline fn distToPoint(self: Plane, p: [3]f32) f32 {
                return vDot(self.normal, p) + self.dist;
            }
        };

        nodes: std.MultiArrayList(Node) = .{},
        planes: std.ArrayListUnmanaged(Plane) = .{},
        alloc: std.mem.Allocator,
        render_verts: std.ArrayListUnmanaged(Vertex) = .{},
        render_indices: std.ArrayListUnmanaged(u32) = .{},

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.alloc);
            self.planes.deinit(self.alloc);
            self.render_verts.deinit(self.alloc);
            self.render_indices.deinit(self.alloc);
        }

        fn addPlane(self: *Self, p: Plane) !u32 {
            const idx: u32 = @intCast(self.planes.items.len);
            try self.planes.append(self.alloc, p);
            return idx;
        }

        fn addNode(self: *Self, plane: u32, front: u32, back: u32) !u32 {
            const idx: u32 = @intCast(self.nodes.len);
            try self.nodes.append(self.alloc, .{
                .plane = plane,
                .front = front,
                .back = back,
            });
            return idx;
        }

        pub fn initGroundPlane(self: *Self, height: f32) !void {
            const pi = try self.addPlane(.{
                .normal = .{ 0, 1, 0 },
                .dist = -height,
            });
            _ = try self.addNode(pi, empty_leaf, solid_leaf);
        }

        pub fn split(self: *Self, point: [3]f32, normal: [3]f32, mode: SplitMode) !void {
            if (self.nodes.len == 0) return;

            const n = if (mode == .empty) vScale(normal, -1.0) else normal;
            const pi = try self.addPlane(.{ .normal = n, .dist = -vDot(n, point) });

            try self.splitLeaf(0, point, pi, mode);
        }

        fn splitLeaf(self: *Self, node_idx: u32, point: [3]f32, plane_idx: u32, mode: SplitMode) !void {
            if (isSolid(node_idx) or isEmpty(node_idx)) return;

            const slice = self.nodes.slice();
            const plane = self.planes.items[slice.items(.plane)[node_idx]];
            const is_front = plane.distToPoint(point) >= 0;

            const child_val = if (is_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];

            if (isLeaf(child_val)) {
                if (mode == .solid and !isEmpty(child_val)) return;
                if (mode == .empty and !isSolid(child_val)) return;

                const front_leaf = if (mode == .solid) solid_leaf else empty_leaf;
                const back_leaf = if (mode == .solid) empty_leaf else solid_leaf;

                const nn = try self.addNode(plane_idx, front_leaf, back_leaf);

                if (is_front) {
                    slice.items(.front)[node_idx] = nn;
                } else {
                    slice.items(.back)[node_idx] = nn;
                }
                return;
            }

            try self.splitLeaf(child_val, point, plane_idx, mode);
        }

        pub fn trace(self: *const Self, start: [3]f32, dir: [3]f32, max_d: f32, radius: f32) ?struct { normal: [3]f32, dist: f32 } {
            if (self.nodes.len == 0) return null;

            const end = vAdd(start, vScale(dir, max_d));
            var st = struct { fraction: f32 = 1.0, normal: [3]f32 = .{ 0, 0, 0 }, hit: bool = false }{};

            _ = self.traceRec(0, 0, 1, start, end, radius, &st);

            if (st.hit and st.fraction < 1.0) {
                return .{
                    .normal = st.normal,
                    .dist = st.fraction * max_d,
                };
            }

            return null;
        }

        fn traceRec(self: *const Self, idx: u32, p1f: f32, p2f: f32, p1: [3]f32, p2: [3]f32, rad: f32, st: anytype) bool {
            if (st.fraction <= p1f) return true;
            if (isEmpty(idx)) return true;
            if (isSolid(idx)) return true;

            const s = self.nodes.slice();
            const plane = self.planes.items[s.items(.plane)[idx]];
            const fc = s.items(.front)[idx];
            const bc = s.items(.back)[idx];

            const t1 = plane.distToPoint(p1);
            const t2 = plane.distToPoint(p2);

            if (t1 >= rad and t2 >= rad) {
                return self.traceRec(fc, p1f, p2f, p1, p2, rad, st);
            }
            if (t1 < -rad and t2 < -rad) {
                return self.traceRec(bc, p1f, p2f, p1, p2, rad, st);
            }

            const ff = t1 >= t2;
            const near = if (ff) fc else bc;
            const far = if (ff) bc else fc;
            const d = t1 - t2;

            var frac: f32 = 0;
            if (@abs(d) > std.math.floatEpsAt(f32, @max(@abs(t1), @abs(t2)))) {
                if (ff) {
                    frac = std.math.clamp((t1 - rad - 0.001) / d, 0, 1);
                } else {
                    frac = std.math.clamp((t1 + rad + 0.001) / d, 0, 1);
                }
            }

            const midf = p1f + (p2f - p1f) * frac;
            const mid = vLerp(p1, p2, frac);

            if (!self.traceRec(near, p1f, midf, p1, mid, rad, st)) {
                return false;
            }

            if (self.sphereInSolid(far, mid, rad)) {
                if (midf < st.fraction) {
                    st.fraction = @max(0, midf);
                    st.normal = if (ff) plane.normal else vScale(plane.normal, -1.0);
                    st.hit = true;
                }
                return false;
            }

            return self.traceRec(far, midf, p2f, mid, p2, rad, st);
        }

        fn sphereInSolid(self: *const Self, idx: u32, p: [3]f32, rad: f32) bool {
            if (isSolid(idx)) return true;
            if (isEmpty(idx)) return false;

            const s = self.nodes.slice();
            const plane = self.planes.items[s.items(.plane)[idx]];
            const d = plane.distToPoint(p);

            if (d > rad) {
                return self.sphereInSolid(s.items(.front)[idx], p, rad);
            }
            if (d < -rad) {
                return self.sphereInSolid(s.items(.back)[idx], p, rad);
            }

            return self.sphereInSolid(s.items(.front)[idx], p, rad) or self.sphereInSolid(s.items(.back)[idx], p, rad);
        }

        const ClipInfo = struct {
            plane: u32,
            flip: bool,
        };

        pub fn rebuildMesh(self: *Self) !void {
            self.render_verts.clearRetainingCapacity();
            self.render_indices.clearRetainingCapacity();

            if (self.nodes.len == 0) return;

            var stack: [64]ClipInfo = undefined;
            try self.meshNode(0, &stack, 0);
        }

        fn meshNode(self: *Self, idx: u32, stack: *[64]ClipInfo, depth: usize) !void {
            if (isLeaf(idx)) return;

            const s = self.nodes.slice();
            const pi = s.items(.plane)[idx];
            const plane = self.planes.items[pi];

            var poly: [48][3]f32 = undefined;
            var count: usize = 4;

            const n = plane.normal;
            const ref = if (@abs(n[1]) < 0.9) [3]f32{ 0, 1, 0 } else [3]f32{ 1, 0, 0 };

            const t1 = vNorm(vCross(n, ref));
            const t2 = vNorm(vCross(n, t1));
            const c = vScale(n, -plane.dist);

            poly[0] = vSub(vSub(c, vScale(t1, 2000)), vScale(t2, 2000));
            poly[1] = vSub(vAdd(c, vScale(t1, 2000)), vScale(t2, 2000));
            poly[2] = vAdd(vAdd(c, vScale(t1, 2000)), vScale(t2, 2000));
            poly[3] = vAdd(vSub(c, vScale(t1, 2000)), vScale(t2, 2000));

            for (stack[0..depth]) |a| {
                var cp = self.planes.items[a.plane];
                if (a.flip) {
                    cp.normal = vScale(cp.normal, -1.0);
                    cp.dist = -cp.dist;
                }

                var out: [48][3]f32 = undefined;
                count = clipConvex(poly[0..count], cp, &out);

                if (count < 3) {
                    break;
                }
                @memcpy(poly[0..count], out[0..count]);
            }

            if (count >= 3) {
                try self.filterFront(poly[0..count], s.items(.front)[idx], s.items(.back)[idx], plane);
            }

            if (depth < 64) {
                stack[depth] = .{ .plane = pi, .flip = false };
                try self.meshNode(s.items(.front)[idx], stack, depth + 1);

                stack[depth] = .{ .plane = pi, .flip = true };
                try self.meshNode(s.items(.back)[idx], stack, depth + 1);
            }
        }

        fn filterFront(self: *Self, verts: []const [3]f32, fn_id: u32, bn_id: u32, split_plane: Plane) !void {
            if (isSolid(fn_id)) {
                return self.filterBack(verts, bn_id, split_plane, true);
            }
            if (isEmpty(fn_id)) {
                return self.filterBack(verts, bn_id, split_plane, false);
            }

            const s = self.nodes.slice();
            const plane = self.planes.items[s.items(.plane)[fn_id]];

            var fv: [48][3]f32 = undefined;
            var bv: [48][3]f32 = undefined;
            const res = splitConvex(verts, plane, &fv, &bv);

            if (res.f >= 3) {
                try self.filterFront(fv[0..res.f], s.items(.front)[fn_id], bn_id, split_plane);
            }
            if (res.b >= 3) {
                try self.filterFront(bv[0..res.b], s.items(.back)[fn_id], bn_id, split_plane);
            }
        }

        fn filterBack(self: *Self, verts: []const [3]f32, bn_id: u32, split_plane: Plane, fs_solid: bool) !void {
            if (isSolid(bn_id)) {
                if (!fs_solid) {
                    try self.pushFace(verts, split_plane, false);
                }
                return;
            }
            if (isEmpty(bn_id)) {
                if (fs_solid) {
                    try self.pushFace(verts, split_plane, true);
                }
                return;
            }

            const s = self.nodes.slice();
            const plane = self.planes.items[s.items(.plane)[bn_id]];

            var fv: [48][3]f32 = undefined;
            var bv: [48][3]f32 = undefined;
            const res = splitConvex(verts, plane, &fv, &bv);

            if (res.f >= 3) {
                try self.filterBack(fv[0..res.f], s.items(.front)[bn_id], split_plane, fs_solid);
            }
            if (res.b >= 3) {
                try self.filterBack(bv[0..res.b], s.items(.back)[bn_id], split_plane, fs_solid);
            }
        }

        fn pushFace(self: *Self, verts: []const [3]f32, plane: Plane, flip: bool) !void {
            if (verts.len < 3) return;

            const face_n = if (flip) vScale(plane.normal, -1.0) else plane.normal;
            
            // Simple directional lighting
            const d = @max(0.15, vDot(face_n, vNorm(.{ 0.4, 0.7, -0.5 })));
            const col = [4]f32{ d * 0.55, d * 0.55, d * 0.6, 1.0 };

            const base: u32 = @intCast(self.render_verts.items.len);

            if (flip) {
                var i: usize = verts.len;
                while (i > 0) {
                    i -= 1;
                    try self.render_verts.append(self.alloc, .{ .pos = verts[i], .color = col });
                }
            } else {
                for (verts) |v| {
                    try self.render_verts.append(self.alloc, .{ .pos = v, .color = col });
                }
            }

            for (2..verts.len) |i| {
                try self.render_indices.appendSlice(self.alloc, &.{
                    base,
                    base + @as(u32, @intCast(i - 1)),
                    base + @as(u32, @intCast(i)),
                });
            }
        }

        fn splitConvex(verts: []const [3]f32, plane: Plane, fv: *[48][3]f32, bv: *[48][3]f32) struct { f: usize, b: usize } {
            if (verts.len < 3) {
                return .{ .f = 0, .b = 0 };
            }

            var f: usize = 0;
            var b: usize = 0;
            var dists: [48]f32 = undefined;
            var has_front = false;
            var has_back = false;

            for (verts, 0..) |v, i| {
                dists[i] = plane.distToPoint(v);
                if (dists[i] > 1e-4) has_front = true;
                if (dists[i] < -1e-4) has_back = true;
            }

            if (!has_back) {
                @memcpy(fv[0..verts.len], verts);
                return .{ .f = verts.len, .b = 0 };
            }
            if (!has_front) {
                @memcpy(bv[0..verts.len], verts);
                return .{ .f = 0, .b = verts.len };
            }

            for (0..verts.len) |i| {
                const p1 = verts[i];
                const p2 = verts[(i + 1) % verts.len];
                const d1 = dists[i];
                const d2 = dists[(i + 1) % verts.len];

                if (d1 >= -1e-4 and f < 48) {
                    fv[f] = p1;
                    f += 1;
                }
                if (d1 <= 1e-4 and b < 48) {
                    bv[b] = p1;
                    b += 1;
                }

                if ((d1 > 1e-4 and d2 < -1e-4) or (d1 < -1e-4 and d2 > 1e-4)) {
                    const mid = vLerp(p1, p2, d1 / (d1 - d2));
                    if (f < 48) {
                        fv[f] = mid;
                        f += 1;
                    }
                    if (b < 48) {
                        bv[b] = mid;
                        b += 1;
                    }
                }
            }

            return .{
                .f = if (f >= 3) f else 0,
                .b = if (b >= 3) b else 0,
            };
        }

        fn clipConvex(verts: []const [3]f32, plane: Plane, out: *[48][3]f32) usize {
            if (verts.len < 3) return 0;
            var n: usize = 0;

            for (0..verts.len) |i| {
                const a = verts[i];
                const b = verts[(i + 1) % verts.len];
                const da = plane.distToPoint(a);
                const db = plane.distToPoint(b);

                if (da >= -1e-4) {
                    if (n < 48) {
                        out[n] = a;
                        n += 1;
                    }
                    if (db < -1e-4 and n < 48) {
                        out[n] = vLerp(a, b, da / (da - db));
                        n += 1;
                    }
                } else if (db >= -1e-4 and n < 48) {
                    out[n] = vLerp(a, b, da / (da - db));
                    n += 1;
                }
            }

            if (n >= 3) {
                return n;
            }
            return 0;
        }
    };
}
