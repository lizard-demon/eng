const std = @import("std");
const math = @import("../math.zig");
const Unit = math.Unit;
const geom = @import("geom.zig");
const Tree = @import("tree.zig").Tree;

const Plane = geom.Plane;
const Poly = geom.Poly;

pub fn Mesher(comptime Vertex: type) type {
    return struct {
        const Self = @This();
        const ClipInfo = struct { plane: u32, flip: bool };

        verts: std.ArrayListUnmanaged(Vertex) = .{},
        indices: std.ArrayListUnmanaged(u32) = .{},
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.verts.deinit(self.alloc);
            self.indices.deinit(self.alloc);
        }

        pub fn build(self: *Self, tree: *const Tree) !void {
            self.verts.clearRetainingCapacity();
            self.indices.clearRetainingCapacity();
            if (tree.nodes.len == 0) return;

            var stack: [64]ClipInfo = undefined;
            try self.meshNode(tree, 0, &stack, 0);
        }

        fn meshNode(self: *Self, tree: *const Tree, idx: u32, stack: []ClipInfo, depth: usize) !void {
            if (Tree.isLeaf(idx)) return;

            const s = tree.nodes.slice();
            const pi = s.items(.plane)[idx];
            const plane = tree.planes.items[pi];

            var poly = Poly.initInfinite(plane, Unit.fix(2000.0));

            for (stack[0..depth]) |a| {
                var cp = tree.planes.items[a.plane];
                if (a.flip) {
                    cp.normal = Unit.scale3(cp.normal, Unit.ONE.neg());
                    cp.dist = cp.dist.neg();
                }
                poly = poly.clip(cp);
                if (poly.len < 3) break;
            }

            if (poly.len >= 3) {
                try self.filterFront(tree, poly, s.items(.front)[idx], s.items(.back)[idx], plane);
            }

            if (depth < 64) {
                stack[depth] = .{ .plane = pi, .flip = false };
                try self.meshNode(tree, s.items(.front)[idx], stack, depth + 1);

                stack[depth] = .{ .plane = pi, .flip = true };
                try self.meshNode(tree, s.items(.back)[idx], stack, depth + 1);
            }
        }

        fn filterFront(self: *Self, tree: *const Tree, poly: Poly, fn_id: u32, bn_id: u32, split_plane: Plane) !void {
            if (Tree.isSolid(fn_id)) return self.filterBack(tree, poly, bn_id, split_plane, true);
            if (Tree.isEmpty(fn_id)) return self.filterBack(tree, poly, bn_id, split_plane, false);

            const plane = tree.planes.items[tree.nodes.slice().items(.plane)[fn_id]];
            const res = poly.split(plane);

            if (res.f.len >= 3) try self.filterFront(tree, res.f, tree.nodes.slice().items(.front)[fn_id], bn_id, split_plane);
            if (res.b.len >= 3) try self.filterFront(tree, res.b, tree.nodes.slice().items(.back)[fn_id], bn_id, split_plane);
        }

        fn filterBack(self: *Self, tree: *const Tree, poly: Poly, bn_id: u32, split_plane: Plane, fs_solid: bool) !void {
            if (Tree.isSolid(bn_id)) {
                if (!fs_solid) try self.pushFace(poly, split_plane, false);
                return;
            }
            if (Tree.isEmpty(bn_id)) {
                if (fs_solid) try self.pushFace(poly, split_plane, true);
                return;
            }

            const plane = tree.planes.items[tree.nodes.slice().items(.plane)[bn_id]];
            const res = poly.split(plane);

            if (res.f.len >= 3) try self.filterBack(tree, res.f, tree.nodes.slice().items(.front)[bn_id], split_plane, fs_solid);
            if (res.b.len >= 3) try self.filterBack(tree, res.b, tree.nodes.slice().items(.back)[bn_id], split_plane, fs_solid);
        }

        fn pushFace(self: *Self, poly: Poly, plane: Plane, flip: bool) !void {
            if (poly.len < 3) return;

            const face_n = if (flip) Unit.scale3(plane.normal, Unit.ONE.neg()) else plane.normal;
            const light_dir = Unit.norm3(.{ Unit.fix(0.4), Unit.fix(0.7), Unit.fix(-0.5) });
            const d_raw = Unit.dot3(face_n, light_dir);
            const d = @max(0.15, d_raw.flt());
            
            const col = [4]f32{ d * 0.55, d * 0.55, d * 0.6, 1.0 };
            const base: u32 = @intCast(self.verts.items.len);

            if (flip) {
                var i: usize = poly.len;
                while (i > 0) {
                    i -= 1;
                    try self.verts.append(self.alloc, .{ 
                        .pos = poly.verts[i], 
                        .color = col 
                    });
                }
            } else {
                for (0..poly.len) |i| {
                    try self.verts.append(self.alloc, .{ 
                        .pos = poly.verts[i], 
                        .color = col 
                    });
                }
            }

            for (2..poly.len) |i| {
                try self.indices.appendSlice(self.alloc, &.{
                    base, base + @as(u32, @intCast(i - 1)), base + @as(u32, @intCast(i)),
                });
            }
        }
    };
}
