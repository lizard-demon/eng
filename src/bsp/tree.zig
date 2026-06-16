const std = @import("std");
const math = @import("../math.zig");
const Unit = math.Unit;
const Plane = @import("geom.zig").Plane;

pub const Tree = struct {
    pub const empty_leaf: u32 = 0xFFFF_FFFE;
    pub const solid_leaf: u32 = 0xFFFF_FFFF;

    pub inline fn isLeaf(i: u32) bool { return i >= empty_leaf; }
    pub inline fn isSolid(i: u32) bool { return i == solid_leaf; }
    pub inline fn isEmpty(i: u32) bool { return i == empty_leaf; }

    pub const SplitMode = enum { solid, empty };

    pub const Node = struct { plane: u32, front: u32, back: u32 };

    nodes: std.MultiArrayList(Node) = .{},
    planes: std.ArrayListUnmanaged(Plane) = .{},
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Tree {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.alloc);
        self.planes.deinit(self.alloc);
    }

    fn addPlane(self: *Tree, p: Plane) !u32 {
        const idx: u32 = @intCast(self.planes.items.len);
        try self.planes.append(self.alloc, p);
        return idx;
    }

    fn addNode(self: *Tree, plane: u32, front: u32, back: u32) !u32 {
        const idx: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.alloc, .{ .plane = plane, .front = front, .back = back });
        return idx;
    }

    pub fn initGroundPlane(self: *Tree, height: Unit) !void {
        const pi = try self.addPlane(.{ .normal = .{ Unit.ZERO, Unit.ONE, Unit.ZERO }, .dist = height.neg() });
        _ = try self.addNode(pi, empty_leaf, solid_leaf);
    }

    pub fn split(self: *Tree, point: [3]Unit, normal: [3]Unit, mode: SplitMode) !void {
        if (self.nodes.len == 0) return;
        const n = if (mode == .empty) Unit.scale3(normal, Unit.ONE.neg()) else normal;
        const pi = try self.addPlane(.{ .normal = n, .dist = Unit.dot3(n, point).neg() });
        try self.splitLeaf(0, point, pi, mode);
    }

    fn splitLeaf(self: *Tree, node_idx: u32, point: [3]Unit, plane_idx: u32, mode: SplitMode) !void {
        if (isSolid(node_idx) or isEmpty(node_idx)) return;

        const slice = self.nodes.slice();
        const plane = self.planes.items[slice.items(.plane)[node_idx]];
        const is_front = plane.distToPoint(point).v >= 0;
        const child_val = if (is_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];

        if (isLeaf(child_val)) {
            if (mode == .solid and !isEmpty(child_val)) return;
            if (mode == .empty and !isSolid(child_val)) return;

            const front_leaf = if (mode == .solid) solid_leaf else empty_leaf;
            const back_leaf = if (mode == .solid) empty_leaf else solid_leaf;
            const nn = try self.addNode(plane_idx, front_leaf, back_leaf);

            if (is_front) { slice.items(.front)[node_idx] = nn; } else { slice.items(.back)[node_idx] = nn; }
            return;
        }
        try self.splitLeaf(child_val, point, plane_idx, mode);
    }

    pub fn trace(self: *const Tree, start: [3]Unit, dir: [3]Unit, max_d: Unit, radius: Unit) ?struct { normal: [3]Unit, dist: Unit } {
        if (self.nodes.len == 0) return null;

        const end = Unit.add3(start, Unit.scale3(dir, max_d));
        var st = struct { fraction: Unit = Unit.ONE, normal: [3]Unit = .{ Unit.ZERO, Unit.ZERO, Unit.ZERO }, hit: bool = false }{};

        _ = self.traceRec(0, Unit.ZERO, Unit.ONE, start, end, radius, &st);

        if (st.hit and st.fraction.v < 1024) {
            return .{ .normal = st.normal, .dist = st.fraction.mul(max_d) };
        }
        return null;
    }

    fn traceRec(self: *const Tree, idx: u32, p1f: Unit, p2f: Unit, p1: [3]Unit, p2: [3]Unit, rad: Unit, st: anytype) bool {
        if (st.fraction.v <= p1f.v) return true;
        if (isEmpty(idx)) return true;
        if (isSolid(idx)) return true;

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[idx]];
        const fc = s.items(.front)[idx];
        const bc = s.items(.back)[idx];

        const t1 = plane.distToPoint(p1);
        const t2 = plane.distToPoint(p2);

        if (t1.v >= rad.v and t2.v >= rad.v) return self.traceRec(fc, p1f, p2f, p1, p2, rad, st);
        if (t1.v < -rad.v and t2.v < -rad.v) return self.traceRec(bc, p1f, p2f, p1, p2, rad, st);

        const ff = t1.v >= t2.v;
        const near = if (ff) fc else bc;
        const far = if (ff) bc else fc;
        const d = t1.sub(t2);

        var num: i32 = 0;
        const den: i32 = if (d.v < 0) -d.v else d.v;

        if (den > 0) {
            num = if (ff) t1.v - rad.v - 1 else -(t1.v + rad.v + 1);
            if (num < 0) num = 0;
            if (num > den) num = den;
        }

        const midf = Unit.raw(p1f.v + @as(i32, @intCast(if (den == 0) 0 else @divTrunc(@as(i64, p2f.v - p1f.v) * num, den))));
        const mid = Unit.lerp(p1, p2, num, den);

        if (!self.traceRec(near, p1f, midf, p1, mid, rad, st)) return false;

        if (self.sphereInSolid(far, mid, rad)) {
            if (midf.v < st.fraction.v) {
                st.fraction = Unit.raw(@max(0, midf.v));
                st.normal = if (ff) plane.normal else Unit.scale3(plane.normal, Unit.ONE.neg());
                st.hit = true;
            }
            return false;
        }
        return self.traceRec(far, midf, p2f, mid, p2, rad, st);
    }

    fn sphereInSolid(self: *const Tree, idx: u32, p: [3]Unit, rad: Unit) bool {
        if (isSolid(idx)) return true;
        if (isEmpty(idx)) return false;

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[idx]];
        const d = plane.distToPoint(p);

        if (d.v > rad.v) return self.sphereInSolid(s.items(.front)[idx], p, rad);
        if (d.v < -rad.v) return self.sphereInSolid(s.items(.back)[idx], p, rad);

        return self.sphereInSolid(s.items(.front)[idx], p, rad) or self.sphereInSolid(s.items(.back)[idx], p, rad);
    }
};
