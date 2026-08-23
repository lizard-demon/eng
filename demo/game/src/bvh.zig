const std = @import("std");
const math = @import("kami").math;
const Unit = math.Unit;
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
    
    pub fn init(alloc: std.mem.Allocator) Tree { return .{ .alloc = alloc }; }
    pub fn deinit(s: *Tree) void { s.nodes.deinit(s.alloc); s.tris.deinit(s.alloc); s.tri_ids.deinit(s.alloc); }

    pub fn addTri(s: *Tree, a: Vec3, b: Vec3, c: Vec3) !void {
        const n = math.norm(math.cross(b - a, c - a));
        try s.tris.append(s.alloc, .{ .a = a, .b = b, .c = c, .n = n });
    }

    pub fn build(s: *Tree) !void {
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

    fn split(s: *Tree, e: []const Entry, start: u32, end: u32, bit: i32) !u32 {
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

    pub fn trace(s: *const Tree, start: Vec3, dir: Vec3, max_d: Unit) ?struct { normal: Vec3, dist: Unit } {
        if (s.nodes.items.len == 0) return null;
        
        const ro = start;
        const rd = dir;
        const inv_rd = math.invRay(rd);

        var t_min = max_d;
        var hit_n = Vec3{ 0, 1024, 0 };
        var hit = false;
        
        var stack: [256]u32 = undefined;
        var ptr: usize = 1;
        stack[0] = 0;

        while (ptr > 0) {
            ptr -= 1;
            const node = s.nodes.items[stack[ptr]];
            
            if (!math.rayAABB(ro, inv_rd, node.aabb.min, node.aabb.max, t_min)) continue;

            if (node.count > 0) {
                for (0..node.count) |i| {
                    const tri = s.tris.items[s.tri_ids.items[node.left + i]];
                    if (math.rayTri(ro, rd, tri.a, tri.b, tri.c)) |t| {
                        if (t.v < t_min.v) {
                            t_min = t; 
                            hit_n = tri.n; 
                            hit = true; 
                        }
                    }
                }
            } else if (ptr + 1 < stack.len) {
                stack[ptr] = node.left; 
                stack[ptr + 1] = node.right; 
                ptr += 2;
            }
        }
        
        if (hit) {
            return .{ .normal = hit_n, .dist = t_min };
        }
        return null;
    }
};
