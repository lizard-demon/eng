//! bvh.zig — generic SAH-based BVH
//!
//! BVH(T) indexes any type T that has `pub fn bounds(self) AABB`.
//! SAH construction · stack-based traversal · raycast + frustum queries.
//!
//!   const Tree = eng.BVH(MyCollider);
//!   var tree = try Tree.init(&colliders, alloc);
//!   const hit = tree.raycast(ray, 100, MyCollider.hitDist);

const std = @import("std");
const geo = @import("geo.zig");
const AABB = geo.AABB;

pub fn BVH(comptime T: type) type {
    if (!@hasDecl(T, "bounds"))
        @compileError("BVH item type must expose `pub fn bounds(self) AABB`");

    return struct {
        const Self = @This();
        pub const max_stack = 64;
        const sah_bins = 8;
        const leaf_max = 8;
        const traverse_cost: f32 = 0.3;

        pub const Node = struct {
            box: AABB,
            /// Leaf: start index into `indices`.  Internal: right-child node index.
            first: u32,
            /// >0 → leaf item count.  0 → internal (left child = this+1).
            count: u16,
        };

        pub const RayHit = struct { index: u32, dist: f32 };

        nodes: std.ArrayListUnmanaged(Node) = .{},
        indices: std.ArrayListUnmanaged(u32) = .{},
        items: []const T,
        alloc: std.mem.Allocator,

        // ── build ─────────────────────────────────────────────────

        pub fn init(items: []const T, alloc: std.mem.Allocator) !Self {
            var self = Self{ .items = items, .alloc = alloc };
            if (items.len == 0) return self;
            try self.indices.ensureTotalCapacity(alloc, items.len);
            for (0..items.len) |i| self.indices.appendAssumeCapacity(@intCast(i));
            try self.buildNode(0, @intCast(items.len));
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.alloc);
            self.indices.deinit(self.alloc);
        }

        fn buildNode(self: *Self, start: u32, count: u32) !void {
            var box = self.items[self.indices.items[start]].bounds();
            for (start + 1..start + count) |i|
                box = box.merge(self.items[self.indices.items[i]].bounds());

            if (count <= leaf_max or self.findSplit(start, count, box) == null) {
                try self.nodes.append(self.alloc, .{ .box = box, .first = start, .count = @intCast(count) });
                return;
            }
            const sp = self.findSplit(start, count, box).?;

            // Lomuto partition — simple, correct, branchless-friendly.
            var lo = start;
            for (start..start + count) |i| {
                if (self.items[self.indices.items[i]].bounds().center().v[sp.axis] < sp.pos) {
                    std.mem.swap(u32, &self.indices.items[lo], &self.indices.items[i]);
                    lo += 1;
                }
            }
            if (lo == start or lo == start + count) {
                try self.nodes.append(self.alloc, .{ .box = box, .first = start, .count = @intCast(count) });
                return;
            }

            const ni = self.nodes.items.len;
            try self.nodes.append(self.alloc, .{ .box = box, .first = 0, .count = 0 });
            try self.buildNode(start, lo - start); // left child → ni+1
            self.nodes.items[ni].first = @intCast(self.nodes.items.len); // right child
            try self.buildNode(lo, start + count - lo);
        }

        const Split = struct { axis: u32, pos: f32 };

        fn findSplit(self: *Self, start: u32, count: u32, box: AABB) ?Split {
            const pa = box.halfArea();
            if (pa <= 0) return null;
            var best_cost: f32 = @as(f32, @floatFromInt(count));
            var best: ?Split = null;
            for (0..3) |axis| {
                const range = box.max.v[axis] - box.min.v[axis];
                if (range <= 1e-6) continue;
                const step = range / @as(f32, @floatFromInt(sah_bins));
                for (0..sah_bins) |bin| {
                    const pos = box.min.v[axis] + step * (@as(f32, @floatFromInt(bin)) + 0.5);
                    var lb = AABB{};
                    var lc: u32 = 0;
                    var rb = AABB{};
                    var rc: u32 = 0;
                    for (start..start + count) |i| {
                        const ib = self.items[self.indices.items[i]].bounds();
                        if (ib.center().v[axis] < pos) {
                            lb = lb.merge(ib);
                            lc += 1;
                        } else {
                            rb = rb.merge(ib);
                            rc += 1;
                        }
                    }
                    if (lc == 0 or rc == 0) continue;
                    const cost = traverse_cost +
                        (lb.halfArea() / pa) * @as(f32, @floatFromInt(lc)) +
                        (rb.halfArea() / pa) * @as(f32, @floatFromInt(rc));
                    if (cost < best_cost) {
                        best_cost = cost;
                        best = .{ .axis = @intCast(axis), .pos = pos };
                    }
                }
            }
            return best;
        }

        // ── queries ───────────────────────────────────────────────

        /// Find closest ray hit.  `hitFn(item, Ray, max_t) -> ?f32`.
        pub fn raycast(
            self: *const Self,
            ray: geo.Ray,
            max_t: f32,
            comptime hitFn: fn (T, geo.Ray, f32) ?f32,
        ) ?RayHit {
            if (self.nodes.items.len == 0) return null;
            var best: ?RayHit = null;
            var best_t = max_t;
            var stack: [max_stack]u32 = undefined;
            var sp: u32 = 1;
            stack[0] = 0;
            while (sp > 0) {
                sp -= 1;
                const ni = stack[sp];
                const node = self.nodes.items[ni];
                if (ray.hitAABB(node.box, best_t) == null) continue;
                if (node.count > 0) {
                    for (node.first..node.first + node.count) |i| {
                        if (hitFn(self.items[self.indices.items[i]], ray, best_t)) |t| {
                            if (t < best_t) {
                                best_t = t;
                                best = .{ .index = self.indices.items[i], .dist = t };
                            }
                        }
                    }
                } else if (sp + 2 <= max_stack) {
                    stack[sp] = @intCast(ni + 1);
                    sp += 1;
                    stack[sp] = node.first;
                    sp += 1;
                }
            }
            return best;
        }

        /// Lazy frustum-query iterator — yields item indices inside the frustum.
        pub const FrustumIter = struct {
            bvh: *const Self,
            fr: geo.Frustum,
            stack: [max_stack]u32 = undefined,
            sp: u32 = 0,
            leaf_cur: u32 = 0,
            leaf_end: u32 = 0,

            pub fn next(self: *FrustumIter) ?u32 {
                while (true) {
                    if (self.leaf_cur < self.leaf_end) {
                        const idx = self.bvh.indices.items[self.leaf_cur];
                        self.leaf_cur += 1;
                        return idx;
                    }
                    if (self.sp == 0) return null;
                    self.sp -= 1;
                    const ni = self.stack[self.sp];
                    const node = self.bvh.nodes.items[ni];
                    if (!self.fr.containsAABB(node.box)) continue;
                    if (node.count > 0) {
                        self.leaf_cur = node.first;
                        self.leaf_end = node.first + node.count;
                    } else if (self.sp + 2 <= max_stack) {
                        self.stack[self.sp] = @intCast(ni + 1);
                        self.sp += 1;
                        self.stack[self.sp] = node.first;
                        self.sp += 1;
                    }
                }
            }
        };

        pub fn queryFrustum(self: *const Self, fr: geo.Frustum) FrustumIter {
            var it = FrustumIter{ .bvh = self, .fr = fr };
            if (self.nodes.items.len > 0) {
                it.stack[0] = 0;
                it.sp = 1;
            }
            return it;
        }
    };
}
