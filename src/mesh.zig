//! mesh.zig — mesh data, skeleton, animation clips, CPU skinning
//!
//! Pure data — no GPU state.  Upload via your Renderer backend.
//! Supports full skeletal animation pipeline:
//!   Clip.sample → local-space joint matrices → Skeleton.resolve → final skin matrices

const math = @import("math.zig");
const geo = @import("geo.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;

pub const max_joints = 128;

// ── Vertex ────────────────────────────────────────────────────────

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
    bounds: geo.AABB,

    pub fn calcBounds(verts: []const Vertex) geo.AABB {
        var box = geo.AABB{};
        for (verts) |v| box = box.expand(Vec3{ .v = v.pos });
        return box;
    }
};

// ── Skeleton ──────────────────────────────────────────────────────

pub const Joint = struct {
    parent: u16 = 0xFFFF, // root sentinel
    inv_bind: Mat4 = Mat4.identity,
};

pub const Skeleton = struct {
    joints: []const Joint,

    /// Turn local-space transforms into final skin matrices (in-place ok).
    pub fn resolve(self: Skeleton, local: []const Mat4, out: []Mat4) void {
        for (self.joints, 0..) |j, i| {
            const parent = if (j.parent == 0xFFFF) Mat4.identity else out[j.parent];
            out[i] = parent.mul(local[i]);
        }
        for (self.joints, 0..) |j, i| out[i] = out[i].mul(j.inv_bind);
    }
};

// ── Animation ─────────────────────────────────────────────────────

pub const Keyframe = struct {
    time: f32 = 0,
    translation: Vec3 = Vec3.zero,
    rotation: Quat = Quat.identity,
    scale: Vec3 = Vec3.init(1, 1, 1),
};

pub const Channel = struct {
    joint: u16,
    keys: []const Keyframe,

    pub fn sample(self: Channel, t: f32) Mat4 {
        if (self.keys.len == 0) return Mat4.identity;
        const last = self.keys.len - 1;
        if (self.keys.len == 1 or t <= self.keys[0].time) return trs(self.keys[0]);
        if (t >= self.keys[last].time) return trs(self.keys[last]);

        var i: usize = 0;
        while (i + 1 < self.keys.len and self.keys[i + 1].time < t) : (i += 1) {}

        const a = self.keys[i];
        const b = self.keys[i + 1];
        const blend = (t - a.time) / (b.time - a.time);
        return Mat4.translate(a.translation.lerp(b.translation, blend))
            .mul(Quat.slerp(a.rotation, b.rotation, blend).toMat4())
            .mul(Mat4.scaling(a.scale.lerp(b.scale, blend)));
    }

    fn trs(k: Keyframe) Mat4 {
        return Mat4.translate(k.translation).mul(k.rotation.toMat4()).mul(Mat4.scaling(k.scale));
    }
};

pub const Clip = struct {
    channels: []const Channel,
    duration: f32,

    /// Sample animation at time `t`, write final skin matrices into `out`.
    pub fn sample(self: Clip, skel: Skeleton, t: f32, out: []Mat4) void {
        const wrapped = if (self.duration > 0) @mod(t, self.duration) else 0;
        for (out[0..skel.joints.len]) |*m| m.* = Mat4.identity;
        for (self.channels) |ch|
            if (ch.joint < skel.joints.len) {
                out[ch.joint] = ch.sample(wrapped);
            };
        skel.resolve(out, out);
    }
};

// ── CPU skinning ──────────────────────────────────────────────────

pub fn skin(
    verts: []const Vertex,
    joints: []const Mat4,
    out_pos: [][3]f32,
    out_nrm: [][3]f32,
) void {
    for (verts, 0..) |v, i| {
        var pos = Vec3.zero;
        var nrm = Vec3.zero;
        for (0..4) |j| {
            const w = v.weights[j];
            if (w <= 0) continue;
            const m = joints[v.joints[j]];
            pos = pos.add(m.xformPoint(Vec3{ .v = v.pos }).scale(w));
            nrm = nrm.add(m.xformDir(Vec3{ .v = v.normal }).scale(w));
        }
        out_pos[i] = pos.v;
        out_nrm[i] = nrm.norm().v;
    }
}
