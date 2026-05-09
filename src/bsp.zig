//! bsp.zig — plane-based BSP world: editing, collision, mesh gen, undo
//!
//! The first brushless BSP editor core.  All geometry is defined purely
//! by a tree of splitting planes — no brushes, no CSG booleans.
//! Each plane folds space like origami, recursively partitioning the
//! world into solid and empty leaves.
//!
//! Node editing is direct: select any visible face to identify its
//! generating node, then translate/rotate/delete/swap/toggle it.
//! Full sequential undo via lightweight operation records.
//!
//! Layout uses MultiArrayList(Node) for cache-friendly SoA traversal.
//! Render geometry derives from the tree via exact CSG filtering.

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

    pub const SplitMode = enum { solid, empty };

    /// BSP node — one splitting plane, two children.
    pub const Node = struct {
        plane: u32, // index into planes[]
        front: u32, // child index or leaf sentinel  (positive half-space)
        back: u32, // child index or leaf sentinel  (negative half-space)
    };

    // ── Result types ──────────────────────────────────────────────

    pub const PickResult = struct {
        node: u32, // BSP node whose plane generated the clicked face
        t: f32, // ray parameter
        pos: Vec3, // world-space hit position
        normal: Vec3, // face normal at hit
    };

    pub const ParentInfo = struct {
        idx: u32,
        is_front: bool,
    };

    // ── Undo ──────────────────────────────────────────────────────
    // Each editor operation records its inverse.  Sequential LIFO undo.
    // Consecutive translates/rotates on the same plane coalesce so one
    // undo step reverts the entire drag.

    pub const EditOp = union(enum) {
        split: struct { parent: u32, is_front: bool, old_leaf: u32 },
        translate: struct { plane_idx: u32, old_dist: f32 },
        rotate: struct { plane_idx: u32, old_normal: Vec3, old_dist: f32 },
        swap: struct { node: u32 },
        toggle: struct { parent: u32, is_front: bool },
        delete: struct { parent: u32, is_front: bool, node_idx: u32 },
    };

    // ── Storage ───────────────────────────────────────────────────

    /// SoA node storage (cache-friendly).
    nodes: std.MultiArrayList(Node) = .{},
    /// Shared plane pool — nodes index into this.
    planes: std.ArrayListUnmanaged(Plane) = .{},
    alloc: std.mem.Allocator,

    /// Cached render geometry — rebuilt on each edit commit.
    render_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{},
    render_indices: std.ArrayListUnmanaged(u32) = .{},
    /// Per-triangle: which BSP node generated this face (for picking).
    face_nodes: std.ArrayListUnmanaged(u32) = .{},
    mesh_dirty: bool = true,

    /// Debug overlay — all splitting planes, depth-coloured.
    debug_verts: std.ArrayListUnmanaged(gfx.Vertex) = .{},
    debug_indices: std.ArrayListUnmanaged(u32) = .{},
    debug_dirty: bool = true,

    /// Currently selected node (null = nothing selected).
    selected_node: ?u32 = null,
    /// Undo history.
    undo_stack: std.ArrayListUnmanaged(EditOp) = .{},

    // ── lifecycle ─────────────────────────────────────────────────

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.alloc);
        self.planes.deinit(self.alloc);
        self.render_verts.deinit(self.alloc);
        self.render_indices.deinit(self.alloc);
        self.face_nodes.deinit(self.alloc);
        self.debug_verts.deinit(self.alloc);
        self.debug_indices.deinit(self.alloc);
        self.undo_stack.deinit(self.alloc);
    }

    pub fn markDirty(self: *Self) void {
        self.mesh_dirty = true;
        self.debug_dirty = true;
    }

    // ── construction ──────────────────────────────────────────────

    fn addPlane(self: *Self, p: Plane) !u32 {
        const idx: u32 = @intCast(self.planes.items.len);
        try self.planes.append(self.alloc, p);
        return idx;
    }

    fn addNode(self: *Self, plane: u32, front: u32, back: u32) !u32 {
        const idx: u32 = @intCast(self.nodes.len);
        try self.nodes.append(self.alloc, .{ .plane = plane, .front = front, .back = back });
        return idx;
    }

    /// Bootstrap with a horizontal ground plane at `height`.
    pub fn initGroundPlane(self: *Self, height: f32) !void {
        const pi = try self.addPlane(.{ .normal = Vec3.new(0, 1, 0), .dist = -height });
        _ = try self.addNode(pi, empty_leaf, solid_leaf);
        self.markDirty();
    }

    // ── editor split (with undo) ──────────────────────────────────

    const SplitInfo = struct { parent: u32, is_front: bool, old_leaf: u32 };

    /// Insert a plane through `point` with given `normal`.
    pub fn editorSplit(self: *Self, point: Vec3, normal: Vec3, mode: SplitMode) !bool {
        if (self.nodes.len == 0) return false;

        const n = if (mode == .empty) normal.neg() else normal;
        const dist = -n.dot(point);
        const pi = try self.addPlane(.{ .normal = n, .dist = dist });

        const info = try self.splitLeaf(0, point, pi, mode) orelse return false;
        try self.undo_stack.append(self.alloc, .{ .split = .{
            .parent = info.parent,
            .is_front = info.is_front,
            .old_leaf = info.old_leaf,
        } });
        self.markDirty();
        return true;
    }

    /// Walk from `node_idx` toward the leaf containing `point`.
    fn splitLeaf(self: *Self, node_idx: u32, point: Vec3, plane_idx: u32, mode: SplitMode) !?SplitInfo {
        if (isSolid(node_idx) or isEmpty(node_idx)) return null;

        const slice = self.nodes.slice();
        const plane = self.planes.items[slice.items(.plane)[node_idx]];
        const is_front = plane.distToPoint(point) >= 0;
        const child_val = if (is_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];

        if (isLeaf(child_val)) {
            if (mode == .solid and !isEmpty(child_val)) return null;
            if (mode == .empty and !isSolid(child_val)) return null;

            const f_child = if (mode == .solid) solid_leaf else empty_leaf;
            const b_child = if (mode == .solid) empty_leaf else solid_leaf;
            const nn = try self.addNode(plane_idx, f_child, b_child);

            const new_slice = self.nodes.slice();
            if (is_front) new_slice.items(.front)[node_idx] = nn else new_slice.items(.back)[node_idx] = nn;
            return .{ .parent = node_idx, .is_front = is_front, .old_leaf = child_val };
        }

        return self.splitLeaf(child_val, point, plane_idx, mode);
    }

    // ── node manipulation ─────────────────────────────────────────

    /// Slide a plane along its normal by `delta` units.
    /// Consecutive translates on the same plane coalesce into one undo step.
    pub fn translatePlane(self: *Self, node_idx: u32, delta: f32) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return;
        const pi = self.nodes.slice().items(.plane)[node_idx];

        const coalesce = if (self.undo_stack.items.len > 0)
            switch (self.undo_stack.items[self.undo_stack.items.len - 1]) {
                .translate => |t| t.plane_idx == pi,
                else => false,
            }
        else
            false;

        if (!coalesce) {
            try self.undo_stack.append(self.alloc, .{ .translate = .{
                .plane_idx = pi,
                .old_dist = self.planes.items[pi].dist,
            } });
        }
        self.planes.items[pi].dist -= delta;
        self.markDirty();
    }

    /// Re-orient a plane to `new_normal`, keeping it through its current
    /// reference point so the "crease" stays anchored in space.
    /// Consecutive rotates on the same plane coalesce.
    pub fn rotatePlane(self: *Self, node_idx: u32, new_normal: Vec3) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return;
        const pi = self.nodes.slice().items(.plane)[node_idx];
        const old = self.planes.items[pi];
        const ref_point = old.normal.scale(-old.dist);

        const coalesce = if (self.undo_stack.items.len > 0)
            switch (self.undo_stack.items[self.undo_stack.items.len - 1]) {
                .rotate => |r| r.plane_idx == pi,
                else => false,
            }
        else
            false;

        if (!coalesce) {
            try self.undo_stack.append(self.alloc, .{ .rotate = .{
                .plane_idx = pi,
                .old_normal = old.normal,
                .old_dist = old.dist,
            } });
        }
        self.planes.items[pi] = .{ .normal = new_normal, .dist = -new_normal.dot(ref_point) };
        self.markDirty();
    }

    /// Remove a node from the tree, promoting one of its children.
    /// `promote_front = true` keeps the front subtree, discards back.
    /// Cannot delete root (node 0).
    pub fn deleteNode(self: *Self, target: u32, promote_front: bool) !bool {
        if (target == 0 or isLeaf(target) or target >= self.nodes.len) return false;
        const parent = self.findParent(target) orelse return false;
        const slice = self.nodes.slice();
        const promoted = if (promote_front) slice.items(.front)[target] else slice.items(.back)[target];

        try self.undo_stack.append(self.alloc, .{ .delete = .{
            .parent = parent.idx,
            .is_front = parent.is_front,
            .node_idx = target,
        } });

        if (parent.is_front)
            slice.items(.front)[parent.idx] = promoted
        else
            slice.items(.back)[parent.idx] = promoted;

        if (self.selected_node) |sel| if (sel == target) {
            self.selected_node = null;
        };
        self.markDirty();
        return true;
    }

    /// Swap front and back children (flips inside/outside).
    pub fn swapChildren(self: *Self, node_idx: u32) !void {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return;
        try self.undo_stack.append(self.alloc, .{ .swap = .{ .node = node_idx } });
        const slice = self.nodes.slice();
        const tmp = slice.items(.front)[node_idx];
        slice.items(.front)[node_idx] = slice.items(.back)[node_idx];
        slice.items(.back)[node_idx] = tmp;
        self.markDirty();
    }

    /// Flip a direct-child leaf between solid and empty.
    /// Returns false if the specified child is not a leaf.
    pub fn toggleLeaf(self: *Self, node_idx: u32, toggle_front: bool) !bool {
        if (isLeaf(node_idx) or node_idx >= self.nodes.len) return false;
        const slice = self.nodes.slice();
        const child = if (toggle_front) slice.items(.front)[node_idx] else slice.items(.back)[node_idx];
        if (!isLeaf(child)) return false;

        try self.undo_stack.append(self.alloc, .{ .toggle = .{
            .parent = node_idx,
            .is_front = toggle_front,
        } });

        if (toggle_front)
            slice.items(.front)[node_idx] = if (isSolid(child)) empty_leaf else solid_leaf
        else
            slice.items(.back)[node_idx] = if (isSolid(child)) empty_leaf else solid_leaf;
        self.markDirty();
        return true;
    }

    // ── undo ──────────────────────────────────────────────────────

    pub fn canUndo(self: *const Self) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn undo(self: *Self) bool {
        if (self.undo_stack.items.len == 0) return false;
        const op = self.undo_stack.pop() orelse return false;
        switch (op) {
            .split => |s| {
                const slice = self.nodes.slice();
                if (s.is_front) slice.items(.front)[s.parent] = s.old_leaf else slice.items(.back)[s.parent] = s.old_leaf;
            },
            .translate => |t| {
                self.planes.items[t.plane_idx].dist = t.old_dist;
            },
            .rotate => |r| {
                self.planes.items[r.plane_idx].normal = r.old_normal;
                self.planes.items[r.plane_idx].dist = r.old_dist;
            },
            .swap => |s| {
                const slice = self.nodes.slice();
                const tmp = slice.items(.front)[s.node];
                slice.items(.front)[s.node] = slice.items(.back)[s.node];
                slice.items(.back)[s.node] = tmp;
            },
            .toggle => |t| {
                const slice = self.nodes.slice();
                const c = if (t.is_front) &slice.items(.front)[t.parent] else &slice.items(.back)[t.parent];
                c.* = if (isSolid(c.*)) empty_leaf else solid_leaf;
            },
            .delete => |d| {
                const slice = self.nodes.slice();
                if (d.is_front) slice.items(.front)[d.parent] = d.node_idx else slice.items(.back)[d.parent] = d.node_idx;
            },
        }
        self.selected_node = null;
        self.markDirty();
        return true;
    }

    // ── queries ───────────────────────────────────────────────────

    /// Walk from root to find which node has `target` as a child.
    pub fn findParent(self: *const Self, target: u32) ?ParentInfo {
        if (target == 0 or self.nodes.len == 0) return null;
        return self.findParentWalk(0, target);
    }

    fn findParentWalk(self: *const Self, current: u32, target: u32) ?ParentInfo {
        if (isLeaf(current)) return null;
        const s = self.nodes.slice();
        if (s.items(.front)[current] == target) return .{ .idx = current, .is_front = true };
        if (s.items(.back)[current] == target) return .{ .idx = current, .is_front = false };
        return self.findParentWalk(s.items(.front)[current], target) orelse
            self.findParentWalk(s.items(.back)[current], target);
    }

    pub fn nodeDepth(self: *const Self, target: u32) u32 {
        if (target == 0) return 0;
        var depth: u32 = 0;
        var cur = target;
        while (self.findParent(cur)) |p| {
            depth += 1;
            cur = p.idx;
        }
        return depth;
    }

    /// Count reachable nodes from root.
    pub fn liveNodeCount(self: *const Self) u32 {
        if (self.nodes.len == 0) return 0;
        return self.countFrom(0);
    }

    fn countFrom(self: *const Self, idx: u32) u32 {
        if (isLeaf(idx)) return 0;
        const s = self.nodes.slice();
        return 1 + self.countFrom(s.items(.front)[idx]) + self.countFrom(s.items(.back)[idx]);
    }

    /// Describe a child slot as a string tag for debug display.
    pub fn childTag(c: u32) []const u8 {
        if (isSolid(c)) return "SOLID";
        if (isEmpty(c)) return "EMPTY";
        return "node";
    }

    // ── ray picking ───────────────────────────────────────────────
    // Pick by ray-triangle against the rendered mesh, then look up the
    // generating BSP node via face_nodes[].  Pixel-perfect, zero cost
    // at edit-time, automatically respects occlusion.

    pub fn rayPick(self: *const Self, origin: Vec3, dir: Vec3) ?PickResult {
        if (self.render_indices.items.len < 3 or self.face_nodes.items.len == 0) return null;
        var best_t: f32 = std.math.inf(f32);
        var best_node: u32 = 0;
        var best_normal = Vec3.zero();

        const tris = self.render_indices.items.len / 3;
        for (0..tris) |ti| {
            const v0 = posVec(self.render_verts.items[self.render_indices.items[ti * 3]].pos);
            const v1 = posVec(self.render_verts.items[self.render_indices.items[ti * 3 + 1]].pos);
            const v2 = posVec(self.render_verts.items[self.render_indices.items[ti * 3 + 2]].pos);
            if (rayTriHit(origin, dir, v0, v1, v2)) |t| {
                if (t < best_t) {
                    best_t = t;
                    best_node = self.face_nodes.items[ti];
                    best_normal = v1.sub(v0).cross(v2.sub(v0)).normalize();
                }
            }
        }

        if (best_t < std.math.inf(f32))
            return .{
                .node = best_node,
                .t = best_t,
                .pos = origin.add(dir.scale(best_t)),
                .normal = best_normal,
            };
        return null;
    }

    inline fn posVec(p: [3]f32) Vec3 {
        return Vec3.new(p[0], p[1], p[2]);
    }

    /// Möller–Trumbore ray-triangle.
    fn rayTriHit(o: Vec3, d: Vec3, v0: Vec3, v1: Vec3, v2: Vec3) ?f32 {
        const e1 = v1.sub(v0);
        const e2 = v2.sub(v0);
        const h = d.cross(e2);
        const a = e1.dot(h);
        if (@abs(a) < 1e-7) return null;
        const f = 1.0 / a;
        const s = o.sub(v0);
        const u = f * s.dot(h);
        if (u < 0 or u > 1) return null;
        const q = s.cross(e1);
        const v = f * d.dot(q);
        if (v < 0 or u + v > 1) return null;
        const t = f * e2.dot(q);
        return if (t > 1e-5) t else null;
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
        self.face_nodes.clearRetainingCapacity();
        if (self.nodes.len == 0) return;
        var stack: [max_depth]ClipInfo = undefined;
        try self.meshNode(0, &stack, 0);
        self.mesh_dirty = false;
    }

    fn meshNode(self: *Self, idx: u32, stack: *[max_depth]ClipInfo, depth: usize) !void {
        if (isLeaf(idx)) return;

        const s = self.nodes.slice();
        const pi = s.items(.plane)[idx];
        const fc = s.items(.front)[idx];
        const bc = s.items(.back)[idx];
        const plane = self.planes.items[pi];

        // 1. Build massive base polygon on this node's plane
        var poly: [max_poly]Vec3 = undefined;
        var count: usize = 4;
        makeBasePoly(plane, base_size, poly[0..4]);

        // 2. Clip to ancestor bounding volume
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

        // 3. Push polygon through both subtrees to extract visible boundaries
        if (count >= 3)
            try self.filterFront(poly[0..count], fc, bc, plane, idx);

        // 4. Recurse
        if (depth < max_depth) {
            stack[depth] = .{ .plane = pi, .flip = false };
            try self.meshNode(fc, stack, depth + 1);
            stack[depth] = .{ .plane = pi, .flip = true };
            try self.meshNode(bc, stack, depth + 1);
        }
    }

    fn filterFront(self: *Self, verts: []const Vec3, front_node: u32, back_node: u32, split_plane: Plane, src: u32) !void {
        if (isSolid(front_node)) return self.filterBack(verts, back_node, split_plane, true, src);
        if (isEmpty(front_node)) return self.filterBack(verts, back_node, split_plane, false, src);

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[front_node]];
        var fv: [max_poly]Vec3 = undefined;
        var bv: [max_poly]Vec3 = undefined;
        const res = splitConvex(verts, plane, &fv, &bv);
        if (res.f >= 3) try self.filterFront(fv[0..res.f], s.items(.front)[front_node], back_node, split_plane, src);
        if (res.b >= 3) try self.filterFront(bv[0..res.b], s.items(.back)[front_node], back_node, split_plane, src);
    }

    fn filterBack(self: *Self, verts: []const Vec3, back_node: u32, split_plane: Plane, front_solid: bool, src: u32) !void {
        if (isSolid(back_node)) {
            if (!front_solid) try self.pushFace(verts, split_plane, false, src);
            return;
        }
        if (isEmpty(back_node)) {
            if (front_solid) try self.pushFace(verts, split_plane, true, src);
            return;
        }

        const s = self.nodes.slice();
        const plane = self.planes.items[s.items(.plane)[back_node]];
        var fv: [max_poly]Vec3 = undefined;
        var bv: [max_poly]Vec3 = undefined;
        const res = splitConvex(verts, plane, &fv, &bv);
        if (res.f >= 3) try self.filterBack(fv[0..res.f], s.items(.front)[back_node], split_plane, front_solid, src);
        if (res.b >= 3) try self.filterBack(bv[0..res.b], s.items(.back)[back_node], split_plane, front_solid, src);
    }

    fn pushFace(self: *Self, verts: []const Vec3, plane: Plane, flip: bool, src: u32) !void {
        if (verts.len < 3) return;
        const face_n = if (flip) plane.normal.neg() else plane.normal;
        const is_sel = self.selected_node != null and self.selected_node.? == src;
        const color = if (is_sel) selColor(face_n) else normalColor(face_n);
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
            try self.face_nodes.append(self.alloc, src);
        }
    }

    // ── debug overlay mesh ────────────────────────────────────────
    // Shows every splitting plane as a depth-coloured surface, clipped
    // to its actual spatial extent by ancestor planes.  Selected node
    // is bright red.  Both face windings are emitted so planes are
    // visible from either side despite back-face culling.

    pub fn rebuildDebugMesh(self: *Self) !void {
        self.debug_verts.clearRetainingCapacity();
        self.debug_indices.clearRetainingCapacity();
        if (self.nodes.len == 0) return;
        var stack: [max_depth]ClipInfo = undefined;
        try self.debugNode(0, &stack, 0);
        self.debug_dirty = false;
    }

    fn debugNode(self: *Self, idx: u32, stack: *[max_depth]ClipInfo, depth: usize) !void {
        if (isLeaf(idx)) return;

        const s = self.nodes.slice();
        const pi = s.items(.plane)[idx];
        const fc = s.items(.front)[idx];
        const bc = s.items(.back)[idx];
        const plane = self.planes.items[pi];

        var poly: [max_poly]Vec3 = undefined;
        var count: usize = 4;
        makeBasePoly(plane, base_size, poly[0..4]);

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

        if (count >= 3) {
            const is_sel = self.selected_node != null and self.selected_node.? == idx;
            const color = if (is_sel) [4]f32{ 1.0, 0.15, 0.05, 1.0 } else depthColor(depth);
            // Offset both directions to avoid z-fighting with BSP faces
            const off = plane.normal.scale(0.05);
            try self.pushDebugFace(poly[0..count], off, color);
            try self.pushDebugFace(poly[0..count], off.neg(), color);
        }

        if (depth < max_depth) {
            stack[depth] = .{ .plane = pi, .flip = false };
            try self.debugNode(fc, stack, depth + 1);
            stack[depth] = .{ .plane = pi, .flip = true };
            try self.debugNode(bc, stack, depth + 1);
        }
    }

    fn pushDebugFace(self: *Self, verts: []const Vec3, offset: Vec3, color: [4]f32) !void {
        if (verts.len < 3) return;
        const base: u32 = @intCast(self.debug_verts.items.len);
        for (verts) |v| {
            const p = v.add(offset);
            try self.debug_verts.append(self.alloc, .{
                .pos = .{ p.data[0], p.data[1], p.data[2] },
                .color = color,
            });
        }
        // Emit both winding orders → visible from either side
        for (2..verts.len) |i| {
            const ii: u32 = @intCast(i);
            try self.debug_indices.append(self.alloc, base);
            try self.debug_indices.append(self.alloc, base + ii - 1);
            try self.debug_indices.append(self.alloc, base + ii);
            try self.debug_indices.append(self.alloc, base);
            try self.debug_indices.append(self.alloc, base + ii);
            try self.debug_indices.append(self.alloc, base + ii - 1);
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
            if (d1 >= -split_eps and f < max_poly) {
                fv[f] = p1;
                f += 1;
            }
            if (d1 <= split_eps and b < max_poly) {
                bv[b] = p1;
                b += 1;
            }
            if ((d1 > split_eps and d2 < -split_eps) or (d1 < -split_eps and d2 > split_eps)) {
                const t = d1 / (d1 - d2);
                const mid = Vec3.lerp(p1, p2, t);
                if (f < max_poly) {
                    fv[f] = mid;
                    f += 1;
                }
                if (b < max_poly) {
                    bv[b] = mid;
                    b += 1;
                }
            }
        }
        return .{ .f = if (f >= 3) f else 0, .b = if (b >= 3) b else 0 };
    }

    fn clipConvex(verts: []const Vec3, plane: Plane, out: *[max_poly]Vec3) usize {
        if (verts.len < 3) return 0;
        var n: usize = 0;
        for (0..verts.len) |i| {
            const a = verts[i];
            const b = verts[(i + 1) % verts.len];
            const da = plane.distToPoint(a);
            const db = plane.distToPoint(b);
            if (da >= -split_eps) {
                if (n < max_poly) {
                    out[n] = a;
                    n += 1;
                }
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

    // ── colouring ─────────────────────────────────────────────────

    fn normalColor(n: Vec3) [4]f32 {
        const sun = Vec3.new(0.4, 0.7, -0.5).normalize();
        const d = @max(0.15, n.dot(sun));
        return .{ d * 0.55, d * 0.55, d * 0.6, 1.0 };
    }

    fn selColor(n: Vec3) [4]f32 {
        const sun = Vec3.new(0.4, 0.7, -0.5).normalize();
        const d = @max(0.3, n.dot(sun));
        return .{ d * 0.95, d * 0.35, d * 0.1, 1.0 };
    }

    fn depthColor(depth: usize) [4]f32 {
        const lut = [_][4]f32{
            .{ 0.80, 0.15, 0.10, 1.0 }, // red
            .{ 0.85, 0.50, 0.10, 1.0 }, // orange
            .{ 0.80, 0.80, 0.15, 1.0 }, // yellow
            .{ 0.20, 0.75, 0.20, 1.0 }, // green
            .{ 0.15, 0.70, 0.75, 1.0 }, // cyan
            .{ 0.20, 0.30, 0.85, 1.0 }, // blue
            .{ 0.60, 0.20, 0.80, 1.0 }, // purple
            .{ 0.80, 0.20, 0.70, 1.0 }, // magenta
        };
        return lut[depth % lut.len];
    }
};
