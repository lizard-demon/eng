//! mesh.zig — mesh data, skeleton, animation clips, CPU skinning

const math = @import("math.zig");
const geo = @import("geo.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const AABB = math.AABB;

pub const max_joints = 128;

pub const Vertex = extern struct {
    pos: [3]f32 = .{ 0, 0, 0 },
    normal: [3]f32 = .{ 0, 1, 0 },
    uv: [2]f32 = .{ 0, 0 },
    joints: [4]u16 = .{ 0, 0, 0, 0 },
    weights: [4]f32 = .{ 1, 0, 0, 0 },
};

pub const Mesh = struct {
    vertices: []const Vertex,
    indices: []const u32,
    aabb: AABB,
    pub fn calcBounds(verts: []const Vertex) AABB {
        var box = AABB.empty;
        for (verts) |v| box = box.expand(Vec3{ .data = .{ v.pos[0], v.pos[1], v.pos[2] } });
        return box;
    }
};

pub const Joint = struct { parent: u16 = 0xFFFF, inv_bind: Mat4 = Mat4.identity() };

pub const Skeleton = struct {
    joints: []const Joint,
    pub fn resolve(self: Skeleton, local: []const Mat4, out: []Mat4) void {
        for (self.joints, 0..) |j, i| {
            const parent_m = if (j.parent == 0xFFFF) Mat4.identity() else out[j.parent];
            out[i] = parent_m.mul(local[i]);
        }
        for (self.joints, 0..) |j, i| out[i] = out[i].mul(j.inv_bind);
    }
};

pub const Keyframe = struct { time: f32 = 0, translation: Vec3 = Vec3.zero(), scale: Vec3 = Vec3.one() };

pub const Channel = struct {
    joint: u16,
    keys: []const Keyframe,
    pub fn sample(self: Channel, t: f32) Mat4 {
        if (self.keys.len == 0) return Mat4.identity();
        if (self.keys.len == 1 or t <= self.keys[0].time) return trs(self.keys[0]);
        const last = self.keys.len - 1;
        if (t >= self.keys[last].time) return trs(self.keys[last]);
        var i: usize = 0;
        while (i + 1 < self.keys.len and self.keys[i + 1].time < t) : (i += 1) {}
        const a = self.keys[i];
        const b = self.keys[i + 1];
        const blend = (t - a.time) / (b.time - a.time);
        return Mat4.translate(a.translation.lerp(b.translation, blend)).mul(Mat4.scaling(a.scale.lerp(b.scale, blend)));
    }
    fn trs(k: Keyframe) Mat4 { return Mat4.translate(k.translation).mul(Mat4.scaling(k.scale)); }
};

pub const Clip = struct {
    channels: []const Channel,
    duration: f32,
    pub fn sample(self: Clip, skel: Skeleton, t: f32, out: []Mat4) void {
        const wrapped = if (self.duration > 0) @mod(t, self.duration) else 0;
        for (out[0..skel.joints.len]) |*m| m.* = Mat4.identity();
        for (self.channels) |ch| if (ch.joint < skel.joints.len) { out[ch.joint] = ch.sample(wrapped); };
        skel.resolve(out, out);
    }
};
