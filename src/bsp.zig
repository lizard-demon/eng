//! bsp.zig — plane-based BSP world: runtime editing, exact collision, mesh gen
//!
//! Replaces bvh.zig + Brush architecture.  All collision is plane-exact:
//! no Minkowski expansion, no ghost seams, no AABB padding.
//!
//! Layout uses MultiArrayList(Node) for cache-friendly SoA traversal.
//! Render geometry derives directly from the tree on each edit commit.

const std = @import("std");
const math = @import("math.zig");
const geo = @import("geo.zig");
const gfx = @import("gfx.zig");
const Vec3 = math.Vec3;
const AABB = math.AABB;
const Plane = geo.Plane;

pub const Bsp = struct {
    const Self = @This();

    // ── leaf sentinels (stored in child slots) ────────────────────
    pub const empty_leaf: u32 = 0xFFFF_FFFE;
    pub const solid_leaf: u32 = 0xFFFF_FFFF;

    pub inline fn isLeaf(i: u32) bool { return i >= empty_leaf; }
    pub inline fn isSolid(i: u32) bool { return i == solid_leaf; }
    pub inline fn isEmpty(i: u32) bool { return i == empty_leaf; }

    pub const SplitMode = enum {
        solid, // Target empty space, add a solid volume
        empty, // Target solid space, carve an empty volume
    };

    /// BSP node — one splitting plane, two children.
    pub const Node = struct {
        plane: u32, // index into planes[]
        front: u32, // child index or leaf sentinel  (positive half-space)
        back: u32, // child index or leaf sentinel  (negative half-space)
    };

    /// SoA node storage (cache-friendly).
    nodes: std.MultiArrayList(Node) = .{},
    /// Shared plane pool — nodes index into this.
    planes: std.ArrayListUnmanaged(Plane) = .{},
    alloc: std.mem.Allocator,

    /// Cached render geometry — rebuilt on each edit commit.
    render_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{},
    render_indices: std.ArrayListUnmanaged(u32) = .{},
    mesh_dirty: bool = true,

    // ── lifecycle ─────────────────────────────────────────────────

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.alloc);
        self.planes.deinit(self.alloc);
        self.render_verts.deinit(self.alloc);
        self.render_indices.deinit(self.alloc);
    }

    // ── construction ──────────────────────────────────────────────

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

    /// Bootstrap with a horizontal ground plane at `height`.
    pub fn initGroundPlane(self: *Self, height: f32) !void {
        const pi = try self.addPlane(.{
            .normal = Vec3.new(0, 1, 0),
            .dist = -height,
        });
        _ = try self.addNode(pi, empty_leaf, solid_leaf);
        self.mesh_dirty = true;
    }

    /// Editor split: insert a plane through `point` with given `normal`.
    /// Editor split: insert a plane through `point` with given `normal`.
    pub fn editorSplit(self: *Self, point: Vec3, normal: Vec3, mode: SplitMode) !bool {
        if (self.nodes.len == 0) return false;
        
        // Invert the normal for carving so the new empty space is created 
        // on the correct side of the splitting plane relative to the player.
        const n = if (mode == .empty) normal.neg() else normal;
        
        const dist = -n.dot(point);
        const pi = try self.addPlane(.{ .normal = n, .dist = dist });
        const did = try self.splitLeaf(0, point, pi, mode);
        if (did) self.mesh_dirty = true;
        return did;
    }

    /// Walk from `node_idx` toward the leaf containing `point`.
    fn splitLeaf(self: *Self, node_idx: u32, point: Vec3, plane_idx: u32, mode: SplitMode) !bool {
        if (isSolid(node_idx) or isEmpty(node_idx)) return false;

        const slice = self.nodes.slice();
        const plane = self.planes.items[slice.items(.plane)[node_idx]];
        const d = plane.distToPoint(point);
        const is_front = d >= 0;

        const child_val = if (is_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];

        if (isLeaf(child_val)) {
            if (mode == .solid and !isEmpty(child_val)) return false;
            if (mode == .empty and !isSolid(child_val)) return false;

            const f_child = if (mode == .solid) solid_leaf else empty_leaf;
            const b_child = if (mode == .solid) empty_leaf else solid_leaf;

            const nn = try self.addNode(plane_idx, f_child, b_child);

            const new_slice = self.nodes.slice();
            if (is_front) {
                new_slice.items(.front)[node_idx] = nn;
            } else {
                new_slice.items(.back)[node_idx] = nn;
            }
            return true;
        }

        return self.splitLeaf(child_val, point, plane_idx, mode);
    }

    // ── point classification ──────────────────────────────────────

    pub fn pointInSolid(self: *const Self, p: Vec3) bool {
        if (self.nodes.len == 0) return false;
        return self.classifyPoint(0, p);
    }

    fn classifyPoint(self: *const Self, idx: u32, p: Vec3) bool {
        if (isSolid(idx)) return true;
        if (isEmpty(idx)) return false;
        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[idx]];
        return if (plane.distToPoint(p) >= 0)
            self.classifyPoint(s.items(.front)[idx], p)
        else
            self.classifyPoint(s.items(.back)[idx], p);
    }

    fn sphereInSolid(self: *const Self, idx: u32, p: Vec3, radius: f32) bool {
        if (isSolid(idx)) return true;
        if (isEmpty(idx)) return false;
        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[idx]];
        const d = plane.distToPoint(p);
        if (d > radius) return self.sphereInSolid(s.items(.front)[idx], p, radius);
        if (d < -radius) return self.sphereInSolid(s.items(.back)[idx], p, radius);
        return self.sphereInSolid(s.items(.front)[idx], p, radius) or
            self.sphereInSolid(s.items(.back)[idx], p, radius);
    }

    // ── collision trace ───────────────────────────────────────────

    pub const TraceResult = struct { normal: Vec3, dist: f32 };

    const TraceState = struct {
        fraction: f32 = 1.0,
        normal: Vec3 = Vec3.zero(),
        hit: bool = false,
    };

    const trace_eps: f32 = 0.001;

    pub fn trace(
        self: *const Self,
        start: Vec3,
        dir: Vec3,
        max_d: f32,
        radius: f32,
    ) ?TraceResult {
        if (self.nodes.len == 0) return null;
        const end = start.add(dir.scale(max_d));
        var st = TraceState{};
        _ = self.traceRecursive(0, 0, 1, start, end, radius, &st);
        if (st.hit and st.fraction < 1.0)
            return .{ .normal = st.normal, .dist = st.fraction * max_d };
        return null;
    }

    fn traceRecursive(
        self: *const Self,
        idx: u32,
        p1f: f32,
        p2f: f32,
        p1: Vec3,
        p2: Vec3,
        radius: f32,
        st: *TraceState,
    ) bool {
        if (st.fraction <= p1f) return true; 
        if (isEmpty(idx)) return true;
        if (isSolid(idx)) return true;

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[idx]];
        const fc = s.items(.front)[idx];
        const bc = s.items(.back)[idx];

        const t1 = plane.distToPoint(p1);
        const t2 = plane.distToPoint(p2);

        if (t1 >= radius and t2 >= radius)
            return self.traceRecursive(fc, p1f, p2f, p1, p2, radius, st);
        if (t1 < -radius and t2 < -radius)
            return self.traceRecursive(bc, p1f, p2f, p1, p2, radius, st);

        const front_first = t1 >= t2;
        const near = if (front_first) fc else bc;
        const far = if (front_first) bc else fc;
        const delta = t1 - t2;

        var frac: f32 = 0;

        // Dynamically scaled epsilon based on distance from plane
        const eps = std.math.floatEpsAt(f32, @max(@abs(t1), @abs(t2)));

        if (@abs(delta) > eps) {
            frac = if (front_first)
                (t1 - radius - trace_eps) / delta
            else
                (t1 + radius + trace_eps) / delta;
        }
        frac = std.math.clamp(frac, 0, 1);

        const midf = p1f + (p2f - p1f) * frac;
        const mid = Vec3.lerp(p1, p2, frac);

        if (!self.traceRecursive(near, p1f, midf, p1, mid, radius, st))
            return false;

        if (self.sphereInSolid(far, mid, radius)) {
            if (midf < st.fraction) {
                st.fraction = @max(0, midf);
                st.normal = if (front_first) plane.normal else plane.normal.neg();
                st.hit = true;
            }
            return false;
        }

        return self.traceRecursive(far, midf, p2f, mid, p2, radius, st);
    }

    // ── render mesh generation (Exact CSG Filtering) ──────────────

    const max_poly: usize = 48;
    const base_size: f32 = 2000.0;
    const max_depth: usize = 64;
    const split_eps: f32 = 1e-4;

    const ClipInfo = struct { plane: u32, flip: bool };

    pub fn rebuildMesh(self: *Self) !void {
        self.render_verts.clearRetainingCapacity();
        self.render_indices.clearRetainingCapacity();
        if (self.nodes.len == 0) return;
        var stack: [max_depth]ClipInfo = undefined;
        try self.meshNode(0, &stack, 0);
        self.mesh_dirty = false;
    }

    fn meshNode(
        self: *Self,
        idx: u32,
        stack: *[max_depth]ClipInfo,
        depth: usize,
    ) !void {
        if (isLeaf(idx)) return;

        const s = self.nodes.slice();
        const pi = s.items(.plane)[idx];
        const fc = s.items(.front)[idx];
        const bc = s.items(.back)[idx];
        const plane = self.planes.items[pi];

        // 1. Build massive base polygon
        var poly: [max_poly]Vec3 = undefined;
        var count: usize = 4;
        makeBasePoly(plane, base_size, poly[0..4]);

        // 2. Clip to node bounding volume
        for (stack[0..depth]) |a| {
            var cp = self.planes.items[a.plane];
            if (a.flip) {
                cp.normal = cp.normal.neg();
                cp.dist = -cp.dist;
            }
            var out: [max_poly]Vec3 = undefined;
            count = clipConvex(poly[0..count], cp, &out);
            if (count < 3) break;
            @memcpy(poly[0..count], out[0..count]);
        }

        // 3. Exact CSG Filtering: push poly down both subtrees to extract visible boundaries
        if (count >= 3) {
            try self.filterFront(poly[0..count], fc, bc, plane);
        }

        // Recurse
        if (depth < max_depth) {
            stack[depth] = .{ .plane = pi, .flip = false };
            try self.meshNode(fc, stack, depth + 1);
            stack[depth] = .{ .plane = pi, .flip = true };
            try self.meshNode(bc, stack, depth + 1);
        }
    }

    /// Pushes polygon fragments down the Front subtree to resolve Solid/Empty front state
    fn filterFront(self: *Self, verts: []const Vec3, front_node: u32, back_node: u32, split_plane: Plane) !void {
        if (isSolid(front_node)) {
            try self.filterBack(verts, back_node, split_plane, true);
            return;
        }
        if (isEmpty(front_node)) {
            try self.filterBack(verts, back_node, split_plane, false);
            return;
        }

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[front_node]];
        var fv: [max_poly]Vec3 = undefined;
        var bv: [max_poly]Vec3 = undefined;
        const res = splitConvex(verts, plane, &fv, &bv);

        if (res.f >= 3) try self.filterFront(fv[0..res.f], s.items(.front)[front_node], back_node, split_plane);
        if (res.b >= 3) try self.filterFront(bv[0..res.b], s.items(.back)[front_node], back_node, split_plane);
    }

    /// Pushes fragments down the Back subtree to match boundaries.
    /// Emits face only if Front and Back differ (Solid vs Empty).
    fn filterBack(self: *Self, verts: []const Vec3, back_node: u32, split_plane: Plane, front_is_solid: bool) !void {
        if (isSolid(back_node)) {
            if (!front_is_solid) {
                // Front=Empty, Back=Solid -> face points Front
                try self.pushRenderFace(verts, split_plane, false);
            }
            return;
        }
        if (isEmpty(back_node)) {
            if (front_is_solid) {
                // Front=Solid, Back=Empty -> face points Back (flipped)
                try self.pushRenderFace(verts, split_plane, true);
            }
            return;
        }

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[back_node]];
        var fv: [max_poly]Vec3 = undefined;
        var bv: [max_poly]Vec3 = undefined;
        const res = splitConvex(verts, plane, &fv, &bv);

        if (res.f >= 3) try self.filterBack(fv[0..res.f], s.items(.front)[back_node], split_plane, front_is_solid);
        if (res.b >= 3) try self.filterBack(bv[0..res.b], s.items(.back)[back_node], split_plane, front_is_solid);
    }

    fn pushRenderFace(self: *Self, verts: []const Vec3, plane: Plane, flip: bool) !void {
        if (verts.len < 3) return;
        const face_n = if (flip) plane.normal.neg() else plane.normal;
        const color = normalColor(face_n);
        const base: u32 = @intCast(self.render_verts.items.len);

        if (flip) {
            var i: usize = verts.len;
            while (i > 0) {
                i -= 1;
                try self.render_verts.append(self.alloc, .{
                    .pos = .{ verts[i].data[0], verts[i].data[1], verts[i].data[2] },
                    .color = color,
                });
            }
        } else {
            for (verts) |v| {
                try self.render_verts.append(self.alloc, .{
                    .pos = .{ v.data[0], v.data[1], v.data[2] },
                    .color = color,
                });
            }
        }

        for (2..verts.len) |i| {
            try self.render_indices.append(self.alloc, base);
            try self.render_indices.append(self.alloc, base + @as(u32, @intCast(i - 1)));
            try self.render_indices.append(self.alloc, base + @as(u32, @intCast(i)));
        }
    }

    // ── polygon helpers ───────────────────────────────────────────

    fn makeBasePoly(plane: Plane, size: f32, out: []Vec3) void {
        const n = plane.normal;
        const ref: Vec3 = if (@abs(n.data[1]) < 0.9) Vec3.new(0, 1, 0) else Vec3.new(1, 0, 0);
        const t1 = n.cross(ref).normalize();
        const t2 = n.cross(t1).normalize();
        const c = n.scale(-plane.dist);
        out[0] = c.sub(t1.scale(size)).sub(t2.scale(size));
        out[1] = c.add(t1.scale(size)).sub(t2.scale(size));
        out[2] = c.add(t1.scale(size)).add(t2.scale(size));
        out[3] = c.sub(t1.scale(size)).add(t2.scale(size));
    }

    /// Sutherland-Hodgman: exact bi-directional split
    fn splitConvex(verts: []const Vec3, plane: Plane, fv: *[max_poly]Vec3, bv: *[max_poly]Vec3) struct { f: usize, b: usize } {
        if (verts.len < 3) return .{ .f = 0, .b = 0 };
        var f: usize = 0;
        var b: usize = 0;

        var dists: [max_poly]f32 = undefined;
        var has_front = false;
        var has_back = false;
        for (verts, 0..) |v, i| {
            dists[i] = plane.distToPoint(v);
            if (dists[i] > split_eps) has_front = true;
            if (dists[i] < -split_eps) has_back = true;
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

            if (d1 >= -split_eps and f < max_poly) { fv[f] = p1; f += 1; }
            if (d1 <= split_eps and b < max_poly) { bv[b] = p1; b += 1; }

            if ((d1 > split_eps and d2 < -split_eps) or (d1 < -split_eps and d2 > split_eps)) {
                const t = d1 / (d1 - d2);
                const mid = Vec3.lerp(p1, p2, t);
                if (f < max_poly) { fv[f] = mid; f += 1; }
                if (b < max_poly) { bv[b] = mid; b += 1; }
            }
        }
        return .{ .f = if (f >= 3) f else 0, .b = if (b >= 3) b else 0 };
    }

    /// Sutherland-Hodgman: clip convex polygon, keep front (dist ≥ -eps).
    fn clipConvex(verts: []const Vec3, plane: Plane, out: *[max_poly]Vec3) usize {
        if (verts.len < 3) return 0;
        var n: usize = 0;
        for (0..verts.len) |i| {
            const a = verts[i];
            const b = verts[(i + 1) % verts.len];
            const da = plane.distToPoint(a);
            const db = plane.distToPoint(b);
            if (da >= -split_eps) {
                if (n < max_poly) { out[n] = a; n += 1; }
                if (db < -split_eps and n < max_poly) {
                    out[n] = Vec3.lerp(a, b, da / (da - db));
                    n += 1;
                }
            } else if (db >= -split_eps and n < max_poly) {
                out[n] = Vec3.lerp(a, b, da / (da - db));
                n += 1;
            }
        }
        return if (n >= 3) n else 0;
    }

    fn normalColor(n: Vec3) [4]f32 {
        const sun = Vec3.new(0.4, 0.7, -0.5).normalize();
        const d = @max(0.15, n.dot(sun));
        return .{ d * 0.55, d * 0.55, d * 0.6, 1.0 };
    }
};
