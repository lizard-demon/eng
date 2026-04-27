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
    /// Below = solid, above = empty.
    pub fn initGroundPlane(self: *Self, height: f32) !void {
        const pi = try self.addPlane(.{
            .normal = Vec3.new(0, 1, 0),
            .dist = -height,
        });
        _ = try self.addNode(pi, empty_leaf, solid_leaf);
        self.mesh_dirty = true;
    }

    /// Editor split: insert a plane through `point` with given `normal`.
    /// The leaf containing `point` is split; the **front** child becomes
    /// solid (the side behind the surface from the player's viewpoint).
    /// Returns true if a split was performed.
    pub fn editorSplit(self: *Self, point: Vec3, normal: Vec3) !bool {
        if (self.nodes.len == 0) return false;
        const dist = -normal.dot(point);
        const pi = try self.addPlane(.{ .normal = normal, .dist = dist });
        const did = try self.splitLeaf(0, point, pi);
        if (did) self.mesh_dirty = true;
        return did;
    }

    /// Walk from `node_idx` toward the empty leaf containing `point`
    /// and replace it with a new internal node whose front = solid.
    fn splitLeaf(self: *Self, node_idx: u32, point: Vec3, plane_idx: u32) !bool {
        if (isSolid(node_idx) or isEmpty(node_idx)) return false;

        const slice = self.nodes.slice();
        const plane = self.planes.items[slice.items(.plane)[node_idx]];
        const d = plane.distToPoint(point);

        if (d >= 0) {
            const front = slice.items(.front)[node_idx];
            if (isEmpty(front)) {
                const nn = try self.addNode(plane_idx, solid_leaf, empty_leaf);
                self.nodes.slice().items(.front)[node_idx] = nn;
                return true;
            }
            return self.splitLeaf(front, point, plane_idx);
        } else {
            const back = slice.items(.back)[node_idx];
            if (isEmpty(back)) {
                const nn = try self.addNode(plane_idx, solid_leaf, empty_leaf);
                self.nodes.slice().items(.back)[node_idx] = nn;
                return true;
            }
            return self.splitLeaf(back, point, plane_idx);
        }
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

    /// Does a sphere at `p` with `radius` touch any solid in the
    /// subtree rooted at `idx`?
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

    // ── collision trace (Quake-1 style recursive hull check) ──────

    pub const TraceResult = struct { normal: Vec3, dist: f32 };

    const TraceState = struct {
        fraction: f32 = 1.0,
        normal: Vec3 = Vec3.zero(),
        hit: bool = false,
    };

    const trace_eps: f32 = 0.001;

    /// Trace a sphere from `start` along unit `dir` for up to `max_d`.
    /// `radius` = 0 for a point / hitscan trace.
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

    /// Returns `true` if the trace can continue (not blocked at this level).
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
        if (st.fraction <= p1f) return true; // already hit nearer
        if (isEmpty(idx)) return true;
        if (isSolid(idx)) return true; // start-in-solid; handled by parent

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[idx]];
        const fc = s.items(.front)[idx];
        const bc = s.items(.back)[idx];

        const t1 = plane.distToPoint(p1);
        const t2 = plane.distToPoint(p2);

        // ── entirely one side? ────────────────────────────────────
        if (t1 >= radius and t2 >= radius)
            return self.traceRecursive(fc, p1f, p2f, p1, p2, radius, st);
        if (t1 < -radius and t2 < -radius)
            return self.traceRecursive(bc, p1f, p2f, p1, p2, radius, st);

        // ── straddle — split segment at crossing ──────────────────
        const front_first = t1 >= t2;
        const near = if (front_first) fc else bc;
        const far = if (front_first) bc else fc;
        const delta = t1 - t2;

        var frac: f32 = 0;
        if (@abs(delta) > 1e-8) {
            frac = if (front_first)
                (t1 - radius - trace_eps) / delta
            else
                (t1 + radius + trace_eps) / delta;
        }
        frac = std.math.clamp(frac, 0, 1);

        const midf = p1f + (p2f - p1f) * frac;
        const mid = Vec3.lerp(p1, p2, frac);

        // trace near side
        if (!self.traceRecursive(near, p1f, midf, p1, mid, radius, st))
            return false;

        // check far side at crossing point
        if (self.sphereInSolid(far, mid, radius)) {
            if (midf < st.fraction) {
                st.fraction = @max(0, midf);
                st.normal = if (front_first) plane.normal else plane.normal.neg();
                st.hit = true;
            }
            return false;
        }

        // continue through far side
        return self.traceRecursive(far, midf, p2f, mid, p2, radius, st);
    }

    // ── render mesh generation ────────────────────────────────────

    const max_poly: usize = 48;
    const base_size: f32 = 2000.0;
    const max_depth: usize = 64;

    const ClipInfo = struct { plane: u32, flip: bool };

    /// Rebuild cached render geometry from the BSP.
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

        const fs = self.hasSolid(fc);
        const fe = self.hasEmpty(fc);
        const bs = self.hasSolid(bc);
        const be = self.hasEmpty(bc);

        // emit face where solid meets empty across this plane
        if (fs and be) try self.emitFace(pi, stack[0..depth], true);
        if (bs and fe) try self.emitFace(pi, stack[0..depth], false);

        if (depth < max_depth) {
            stack[depth] = .{ .plane = pi, .flip = false };
            try self.meshNode(fc, stack, depth + 1);
            stack[depth] = .{ .plane = pi, .flip = true };
            try self.meshNode(bc, stack, depth + 1);
        }
    }

    fn hasSolid(self: *const Self, idx: u32) bool {
        if (isSolid(idx)) return true;
        if (isEmpty(idx)) return false;
        const s = self.nodes.slice();
        return self.hasSolid(s.items(.front)[idx]) or
            self.hasSolid(s.items(.back)[idx]);
    }
    fn hasEmpty(self: *const Self, idx: u32) bool {
        if (isEmpty(idx)) return true;
        if (isSolid(idx)) return false;
        const s = self.nodes.slice();
        return self.hasEmpty(s.items(.front)[idx]) or
            self.hasEmpty(s.items(.back)[idx]);
    }

    fn emitFace(
        self: *Self,
        pi: u32,
        ancestors: []const ClipInfo,
        flip: bool,
    ) !void {
        const plane = self.planes.items[pi];

        // build large base quad on the splitting plane
        var poly: [max_poly]Vec3 = undefined;
        var count: usize = 4;
        makeBasePoly(plane, base_size, poly[0..4]);

        // clip against every ancestor constraint
        for (ancestors) |a| {
            var cp = self.planes.items[a.plane];
            if (a.flip) {
                cp.normal = cp.normal.neg();
                cp.dist = -cp.dist;
            }
            var out: [max_poly]Vec3 = undefined;
            count = clipConvex(poly[0..count], cp, &out);
            if (count < 3) return;
            @memcpy(poly[0..count], out[0..count]);
        }
        if (count < 3) return;

        const face_n = if (flip) plane.normal.neg() else plane.normal;
        const color = normalColor(face_n);
        const base: u32 = @intCast(self.render_verts.items.len);

        // emit vertices (reverse winding when flipped)
        if (flip) {
            var i: usize = count;
            while (i > 0) {
                i -= 1;
                try self.render_verts.append(self.alloc, .{
                    .pos = .{ poly[i].data[0], poly[i].data[1], poly[i].data[2] },
                    .color = color,
                });
            }
        } else {
            for (poly[0..count]) |v| {
                try self.render_verts.append(self.alloc, .{
                    .pos = .{ v.data[0], v.data[1], v.data[2] },
                    .color = color,
                });
            }
        }

        // fan triangulation
        for (2..count) |i| {
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

    /// Sutherland-Hodgman: clip convex polygon, keep front (dist ≥ 0).
    fn clipConvex(verts: []const Vec3, plane: Plane, out: *[max_poly]Vec3) usize {
        if (verts.len < 3) return 0;
        var n: usize = 0;
        for (0..verts.len) |i| {
            const a = verts[i];
            const b = verts[(i + 1) % verts.len];
            const da = plane.distToPoint(a);
            const db = plane.distToPoint(b);
            if (da >= 0) {
                if (n < max_poly) {
                    out[n] = a;
                    n += 1;
                }
                if (db < 0 and n < max_poly) {
                    out[n] = Vec3.lerp(a, b, da / (da - db));
                    n += 1;
                }
            } else if (db >= 0 and n < max_poly) {
                out[n] = Vec3.lerp(a, b, da / (da - db));
                n += 1;
            }
        }
        return n;
    }

    fn normalColor(n: Vec3) [4]f32 {
        const sun = Vec3.new(0.4, 0.7, -0.5).normalize();
        const d = @max(0.15, n.dot(sun));
        return .{ d * 0.55, d * 0.55, d * 0.6, 1.0 };
    }
};
