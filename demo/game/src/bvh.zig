const std = @import("std");
const math = @import("kami").math;
const Vec3 = math.Vec3;

const AABB = struct {
    min: Vec3 = @splat(std.math.maxInt(i32)),
    max: Vec3 = @splat(std.math.minInt(i32)),
    inline fn grow(s: *AABB, p: Vec3) void { s.min = @min(s.min, p); s.max = @max(s.max, p); }
};

const Tri = struct { a: Vec3, b: Vec3, c: Vec3, n: Vec3 };
const Node = struct { aabb: AABB = .{}, left: u32 = 0, right: u32 = 0, count: u32 = 0 };
const Entry = struct { code: u32, id: u32 };

fn expand(v: u32) u32 {
    var x = v & 0x3ff;
    x = (x | (x << 16)) & 0x30000ff;
    x = (x | (x << 8)) & 0x300f00f;
    x = (x | (x << 4)) & 0x30c30c3;
    return (x | (x << 2)) & 0x9249249;
}

pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .{},
    tris: std.ArrayListUnmanaged(Tri) = .{},
    tri_ids: std.ArrayListUnmanaged(u32) = .{},
    alloc: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator) @This() { return .{ .alloc = alloc }; }
    pub fn deinit(s: *@This()) void { s.nodes.deinit(s.alloc); s.tris.deinit(s.alloc); s.tri_ids.deinit(s.alloc); }

    pub fn addTri(s: *@This(), a: Vec3, b: Vec3, c: Vec3) !void {
        try s.tris.append(s.alloc, .{ .a = a, .b = b, .c = c, .n = math.norm(math.cross(b - a, c - a)) });
    }

    pub fn build(s: *@This()) !void {
        s.nodes.clearRetainingCapacity(); s.tri_ids.clearRetainingCapacity();
        if (s.tris.items.len == 0) return;

        var b = AABB{};
        for (s.tris.items) |t| { b.grow(t.a); b.grow(t.b); b.grow(t.c); }
        var ext = b.max - b.min;
        inline for (0..3) |i| { if (ext[i] == 0) ext[i] = 1; } 

        var entries = try std.ArrayListUnmanaged(Entry).initCapacity(s.alloc, s.tris.items.len);
        defer entries.deinit(s.alloc);

        for (s.tris.items, 0..) |t, i| {
            const cx = @as(i32, @intCast(@divTrunc(@as(i64, t.a[0]) + t.b[0] + t.c[0], 3)));
            const cy = @as(i32, @intCast(@divTrunc(@as(i64, t.a[1]) + t.b[1] + t.c[1], 3)));
            const cz = @as(i32, @intCast(@divTrunc(@as(i64, t.a[2]) + t.b[2] + t.c[2], 3)));

            const nx = @as(u32, @intCast(@max(0, @min(1023, @divTrunc(@as(i64, cx - b.min[0]) * 1023, ext[0])))));
            const ny = @as(u32, @intCast(@max(0, @min(1023, @divTrunc(@as(i64, cy - b.min[1]) * 1023, ext[1])))));
            const nz = @as(u32, @intCast(@max(0, @min(1023, @divTrunc(@as(i64, cz - b.min[2]) * 1023, ext[2])))));

            entries.appendAssumeCapacity(.{ .code = (expand(nx)<<2) | (expand(ny)<<1) | expand(nz), .id = @intCast(i) });
        }

        std.mem.sortUnstable(Entry, entries.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool { return x.code < y.code; }
        }.lt);

        for (entries.items) |e| try s.tri_ids.append(s.alloc, e.id);
        _ = try s.split(entries.items, 0, @intCast(entries.items.len), 29);
    }

    fn split(s: *@This(), e: []const Entry, start: u32, end: u32, bit: i32) !u32 {
        const idx: u32 = @intCast(s.nodes.items.len);
        try s.nodes.append(s.alloc, .{});
        var b = AABB{};
        for (start..end) |i| { const t = s.tris.items[s.tri_ids.items[i]]; b.grow(t.a); b.grow(t.b); b.grow(t.c); }

        var cur_bit = bit;
        var pivot = start;
        while (cur_bit >= 0) : (cur_bit -= 1) {
            const mask = @as(u32, 1) << @intCast(cur_bit);
            pivot = start;
            while (pivot < end and (e[pivot].code & mask) == 0) pivot += 1;
            if (pivot > start and pivot < end) break;
        }

        if (cur_bit < 0 or end - start <= 4) {
            s.nodes.items[idx] = .{ .aabb = b, .left = start, .count = end - start };
        } else {
            const left_child = try s.split(e, start, pivot, cur_bit - 1);
            const right_child = try s.split(e, pivot, end, cur_bit - 1);
            s.nodes.items[idx] = .{ .aabb = b, .left = left_child, .right = right_child, .count = 0 };
        }
        return idx;
    }

    pub fn trace(s: *const @This(), ro: Vec3, rd: Vec3, max_d: i32) ?struct { normal: Vec3, dist: i32 } {
        if (s.nodes.items.len == 0) return null;
        
        var inv_rd: Vec3 = undefined;
        inline for (0..3) |i| inv_rd[i] = if (rd[i] == 0) std.math.maxInt(i32) else @intCast(@divTrunc(@as(i64, 1) << 30, rd[i]));

        var t_min = max_d;
        var hit_n = Vec3{ 0, 1024, 0 };
        var hit = false;
        
        var stack: [256]u32 = undefined;
        var ptr: usize = 1;
        stack[0] = 0;

        while (ptr > 0) {
            ptr -= 1;
            const node = s.nodes.items[stack[ptr]];
            
            // Fast SIMD AABB test
            const pad = @as(@Vector(3, i64), @splat(math.EPSILON));
            const min64 = @as(@Vector(3, i64), node.aabb.min) - pad;
            const max64 = @as(@Vector(3, i64), node.aabb.max) + pad;
            const t0 = (min64 - @as(@Vector(3, i64), ro)) * @as(@Vector(3, i64), inv_rd);
            const t1 = (max64 - @as(@Vector(3, i64), ro)) * @as(@Vector(3, i64), inv_rd);
            const t_near = @reduce(.Max, @min(t0, t1));
            const t_far  = @reduce(.Min, @max(t0, t1));
            
            if (t_near > t_far or (t_near >> 20) >= t_min) continue;

            if (node.count > 0) {
                for (0..node.count) |i| {
                    const tri = s.tris.items[s.tri_ids.items[node.left + i]];
                    
                    const ro64 = @as(@Vector(3, i64), ro);
                    const rd64 = @as(@Vector(3, i64), rd);
                    const ta = @as(@Vector(3, i64), tri.a);
                    
                    const e1 = @as(@Vector(3, i64), tri.b) - ta;
                    const e2 = @as(@Vector(3, i64), tri.c) - ta;
                    const h = @Vector(3, i64){ rd64[1]*e2[2] - rd64[2]*e2[1], rd64[2]*e2[0] - rd64[0]*e2[2], rd64[0]*e2[1] - rd64[1]*e2[0] };
                    const det = @reduce(.Add, e1 * h);
                    
                    if (det <= 0) continue; 
                    const edge_eps = math.EPSILON * 8192; 

                    const sv = ro64 - ta;
                    const u = @reduce(.Add, sv * h);
                    if (u < -edge_eps or u > det + edge_eps) continue;

                    const q = @Vector(3, i64){ sv[1]*e1[2] - sv[2]*e1[1], sv[2]*e1[0] - sv[0]*e1[2], sv[0]*e1[1] - sv[1]*e1[0] };
                    const v_val = @reduce(.Add, rd64 * q);
                    if (v_val < -edge_eps or u + v_val > det + edge_eps) continue;

                    const t_unscaled = @reduce(.Add, e2 * q);
                    const t = @as(i32, @intCast(@divTrunc(@as(i128, t_unscaled) << 10, @as(i128, det))));
                    
                    if (t > 0 and t < t_min) {
                        t_min = t; 
                        hit_n = tri.n; 
                        hit = true; 
                    }
                }
            } else if (ptr + 1 < stack.len) {
                stack[ptr] = node.left; 
                stack[ptr + 1] = node.right; 
                ptr += 2;
            }
        }
        
        return if (hit) .{ .normal = hit_n, .dist = t_min } else null;
    }
};
