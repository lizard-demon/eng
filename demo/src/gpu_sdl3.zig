//! gpu_sdl3.zig — SDL3 GPU backend (software-projected solid triangles)
//!
//! Fulfils the Gpu contract for gfx.Renderer.
//! Stores mesh data on CPU, projects per-frame via renderGeometry.
//! Back-face culling in screen space.  Drop-in for prototyping —
//! swap with an OpenGL / Vulkan / SDL_GPU backend for production.

const std = @import("std");
const sdl = @import("sdl3");
const eng = @import("engine");
const Vec3 = eng.Vec3;
const Vec4 = eng.Vec4;
const Mat4 = eng.Mat4;

pub const Gpu = struct {
    ren: sdl.render.Renderer,
    view: Mat4 = Mat4.identity,
    proj: Mat4 = Mat4.identity,
    vp_w: f32,
    vp_h: f32,
    meshes: std.ArrayListUnmanaged(MeshInfo) = .{},
    all_pos: std.ArrayListUnmanaged([3]f32) = .{},
    all_nrm: std.ArrayListUnmanaged([3]f32) = .{},
    all_idx: std.ArrayListUnmanaged(u32) = .{},
    alloc: std.mem.Allocator,

    const MeshInfo = struct { v_off: u32, idx_off: u32, idx_count: u32 };
    pub const Handle = u32;

    pub fn init(ren: sdl.render.Renderer, w: f32, h: f32, alloc: std.mem.Allocator) Gpu {
        return .{ .ren = ren, .vp_w = w, .vp_h = h, .alloc = alloc };
    }

    pub fn deinit(self: *Gpu) void {
        self.meshes.deinit(self.alloc);
        self.all_pos.deinit(self.alloc);
        self.all_nrm.deinit(self.alloc);
        self.all_idx.deinit(self.alloc);
    }

    // ── contract methods ──────────────────────────────────────────

    pub fn clear(self: *Gpu, c: [4]f32) void {
        self.ren.setDrawColor(.{
            .r = @intFromFloat(c[0] * 255),
            .g = @intFromFloat(c[1] * 255),
            .b = @intFromFloat(c[2] * 255),
            .a = @intFromFloat(c[3] * 255),
        }) catch {};
        self.ren.clear() catch {};
    }

    pub fn setCamera(self: *Gpu, view: Mat4, proj: Mat4) void {
        self.view = view;
        self.proj = proj;
    }

    pub fn upload(self: *Gpu, pos: [][3]f32, nrm: [][3]f32, idx: []u32) !Handle {
        const h: Handle = @intCast(self.meshes.items.len);
        const v_off: u32 = @intCast(self.all_pos.items.len);
        const idx_off: u32 = @intCast(self.all_idx.items.len);
        try self.all_pos.appendSlice(self.alloc, pos);
        try self.all_nrm.appendSlice(self.alloc, nrm);
        try self.all_idx.appendSlice(self.alloc, idx);
        try self.meshes.append(self.alloc, .{
            .v_off = v_off,
            .idx_off = idx_off,
            .idx_count = @intCast(idx.len),
        });
        return h;
    }

    pub fn release(_: *Gpu, _: Handle) void {} // static meshes in demo

    pub fn draw(self: *Gpu, handle: Handle, model: Mat4, color: [4]f32) void {
        if (handle >= self.meshes.items.len) return;
        const info = self.meshes.items[handle];
        const mvp = self.proj.mul(self.view.mul(model));
        const light = Vec3.init(0.3, 1.0, 0.5).norm();
        const zero_pt = sdl.rect.FPoint{ .x = 0, .y = 0 };

        var i: u32 = 0;
        while (i + 2 < info.idx_count) : (i += 3) {
            const base = info.idx_off;
            const idx0 = self.all_idx.items[base + i] + info.v_off;
            const idx1 = self.all_idx.items[base + i + 1] + info.v_off;
            const idx2 = self.all_idx.items[base + i + 2] + info.v_off;

            const sa = self.project(mvp, self.all_pos.items[idx0]) orelse continue;
            const sb = self.project(mvp, self.all_pos.items[idx1]) orelse continue;
            const sc = self.project(mvp, self.all_pos.items[idx2]) orelse continue;

            // Back-face cull (screen-space CW = front in Y-down coords)
            const cz = (sb[0] - sa[0]) * (sc[1] - sa[1]) - (sb[1] - sa[1]) * (sc[0] - sa[0]);
            if (cz >= 0) continue;

            // Flat shade from first-vertex normal
            const n = self.all_nrm.items[idx0];
            const shade = @max(0.15, n[0] * light.v[0] + n[1] * light.v[1] + n[2] * light.v[2]);
            const fc = sdl.pixels.FColor{
                .r = color[0] * shade,
                .g = color[1] * shade,
                .b = color[2] * shade,
                .a = color[3],
            };
            const verts = [3]sdl.render.Vertex{
                .{ .position = .{ .x = sa[0], .y = sa[1] }, .color = fc, .tex_coord = zero_pt },
                .{ .position = .{ .x = sb[0], .y = sb[1] }, .color = fc, .tex_coord = zero_pt },
                .{ .position = .{ .x = sc[0], .y = sc[1] }, .color = fc, .tex_coord = zero_pt },
            };
            self.ren.renderGeometry(null, &verts, null) catch {};
        }
    }

    // ── internal ──

    fn project(self: *const Gpu, mvp: Mat4, p: [3]f32) ?[2]f32 {
        const clip = mvp.mulVec4(Vec4.init(p[0], p[1], p[2], 1));
        if (clip.v[3] <= 0.01) return null;
        const nx = clip.v[0] / clip.v[3];
        const ny = clip.v[1] / clip.v[3];
        if (nx < -1.5 or nx > 1.5 or ny < -1.5 or ny > 1.5) return null;
        return .{ (nx + 1) * 0.5 * self.vp_w, (1 - ny) * 0.5 * self.vp_h };
    }
};

// ── helper: generate box mesh from AABB ───────────────────────────

pub const BoxMesh = struct { pos: [24][3]f32, nrm: [24][3]f32, idx: [36]u32 };

pub fn boxMesh(aabb: eng.AABB) BoxMesh {
    const mn = aabb.min.v;
    const mx = aabb.max.v;
    // Unit cube vertex positions per face (4 verts × 6 faces)
    const uv = [24][3]f32{
        // -Y
        .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 1 }, .{ 0, 0, 1 },
        // +Y
        .{ 0, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, 0 },
        // +Z
        .{ 0, 0, 1 }, .{ 1, 0, 1 }, .{ 1, 1, 1 }, .{ 0, 1, 1 },
        // -Z
        .{ 1, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 1, 0 },
        // -X
        .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 0, 1, 0 },
        // +X
        .{ 1, 0, 1 }, .{ 1, 0, 0 }, .{ 1, 1, 0 }, .{ 1, 1, 1 },
    };
    const face_n = [6][3]f32{
        .{ 0, -1, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 },
        .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 1, 0, 0 },
    };
    var r: BoxMesh = undefined;
    for (0..24) |i| {
        r.pos[i] = .{
            mn[0] + uv[i][0] * (mx[0] - mn[0]),
            mn[1] + uv[i][1] * (mx[1] - mn[1]),
            mn[2] + uv[i][2] * (mx[2] - mn[2]),
        };
        r.nrm[i] = face_n[i / 4];
    }
    r.idx = .{
        0,  1,  2,  0,  2,  3,  4,  5,  6,  4,  6,  7,
        8,  9,  10, 8,  10, 11, 12, 13, 14, 12, 14, 15,
        16, 17, 18, 16, 18, 19, 20, 21, 22, 20, 22, 23,
    };
    return r;
}
