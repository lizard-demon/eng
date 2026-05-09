//! main.zig — FPS walker + professional brushless BSP editor
//!
//! Modes:
//!   SELECT — click faces to identify generating BSP node, navigate tree
//!   PLACE  — click to anchor, release to split (left=solid, right=empty)
//!   ADJUST — scroll to translate selected plane, R to rotate to look dir
//!
//! Controls:
//!   E         toggle editor (off ↔ select)
//!   Tab       cycle modes: select → place → adjust → select
//!   Z         undo last operation
//!   Delete    delete selected node (promote front child)
//!   Shift+Del delete selected node (promote back child)
//!   F         swap front/back children
//!   T         toggle front leaf (solid ↔ empty)
//!   Shift+T   toggle back leaf
//!   R         (adjust) rotate plane to current look direction
//!   G         toggle debug plane overlay
//!   Up/Dn     navigate to parent / back to child
//!   Left/Rt   navigate to front / back child
//!   Scroll    grid size (place, idle) | angle step (place, aiming) |
//!             translate delta (adjust)

const std = @import("std");
const sdl = @import("sdl3");
const eng = @import("engine");
const gpu_mod = @import("gpu_sdl3");
const Vec3 = eng.Vec3;
const Mat4 = eng.Mat4;
const Bsp = eng.Bsp;
const GpuBackend = gpu_mod.Gpu;
const Ren = eng.Renderer(GpuBackend);

const Player = eng.Body(.{
    .gravity = 12.0,
    .jump_speed = 5.0,
    .max_speed = 5.5,
    .air_speed = 1.0,
    .accel = 55.0,
    .friction = 6.0,
    .slope_limit = 0.707,
    .max_slides = 4,
    .radius = 0.3,
    .eye_height = 0.6,
});

// ── BSP physics adapter ───────────────────────────────────────────
const World = struct {
    bsp: *const Bsp,
    radius: f32,
    pub fn cast(self: World, origin: Vec3, dir: Vec3, max_d: f32) ?eng.phys.Hit {
        const r = self.bsp.trace(origin, dir, max_d, self.radius) orelse return null;
        return .{ .normal = r.normal, .dist = r.dist };
    }
};

// ── Editor ────────────────────────────────────────────────────────
const EditorMode = enum { off, select, place, adjust };

const Editor = struct {
    mode: EditorMode = .off,
    placing: bool = false,
    split_mode: Bsp.SplitMode = .solid,
    anchor: Vec3 = Vec3.zero(),
    grid_size: f32 = 1.0,
    angle_step: f32 = std.math.pi / 12.0,
    show_debug: bool = false,
    // Track the last selected child slot for tree navigation
    last_was_front: bool = true,
};

fn snapToGrid(v: Vec3, s: f32) Vec3 {
    return Vec3.new(
        @round(v.data[0] / s) * s,
        @round(v.data[1] / s) * s,
        @round(v.data[2] / s) * s,
    );
}

fn snapAngle(a: f32, step: f32) f32 {
    return @round(a / step) * step;
}

/// Background tint per mode — subtle visual state indicator.
fn modeClearColor(mode: EditorMode) [4]f32 {
    return switch (mode) {
        .off => .{ 0.06, 0.07, 0.12, 1.0 },
        .select => .{ 0.09, 0.06, 0.12, 1.0 },
        .place => .{ 0.06, 0.10, 0.08, 1.0 },
        .adjust => .{ 0.12, 0.09, 0.06, 1.0 },
    };
}

fn cycleMode(m: EditorMode) EditorMode {
    return switch (m) {
        .off => .select,
        .select => .place,
        .place => .adjust,
        .adjust => .select,
    };
}

// ── Entry ─────────────────────────────────────────────────────────
const win_w: i32 = 1280;
const win_h: i32 = 720;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try sdl.init(.{ .video = true, .events = true });
    defer sdl.quit(.{ .video = true, .events = true });

    const win = try sdl.video.Window.init(
        "BSP Editor — E=editor  Tab=mode  G=planes  Z=undo  Scroll=adjust",
        win_w,
        win_h,
        .{},
    );
    defer win.deinit();
    const device = try sdl.gpu.Device.init(.{ .spirv = true }, true, null);

    // ── BSP world ─────────────────────────────────────────────────
    var bsp = Bsp.init(alloc);
    defer bsp.deinit();
    try bsp.initGroundPlane(0);
    try bsp.rebuildMesh();

    // ── Renderer ──────────────────────────────────────────────────
    var renderer = Ren.init(try GpuBackend.init(device, win, alloc));
    defer renderer.gpu.deinit();

    const mesh_handle = try renderer.upload(
        std.mem.sliceAsBytes(bsp.render_verts.items),
        @sizeOf(eng.Vertex),
        std.mem.sliceAsBytes(bsp.render_indices.items),
        @intCast(bsp.render_indices.items.len),
    );
    var debug_handle: ?Ren.Handle = null;

    // ── Game state ────────────────────────────────────────────────
    var player = Player{ .pos = Vec3.new(0, 1.5, 0) };
    const world = World{ .bsp = &bsp, .radius = 0.3 };
    var mouse_locked = false;
    var editor = Editor{};
    var running = true;

    while (running) {
        var mdx: f32 = 0;
        var mdy: f32 = 0;
        const keys = sdl.keyboard.getState();
        const sc = sdl.Scancode;
        const shift = keys[@intFromEnum(sc.left_shift)];

        // ── events ────────────────────────────────────────────────
        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => running = false,

                .key_down => |k| {
                    if (k.scancode) |ksc| {
                        // ── global keys ───────────────────────────
                        if (ksc == .escape and mouse_locked) {
                            mouse_locked = false;
                            sdl.mouse.show() catch {};
                            sdl.mouse.setWindowRelativeMode(win, false) catch {};
                        }

                        if (!mouse_locked) continue;

                        // ── editor toggle & mode ──────────────────
                        if (ksc == .e) {
                            if (editor.mode == .off) {
                                editor.mode = .select;
                            } else {
                                editor.mode = .off;
                                editor.placing = false;
                                bsp.selected_node = null;
                                bsp.markDirty();
                            }
                        }
                        if (ksc == .tab and editor.mode != .off) {
                            editor.placing = false;
                            editor.mode = cycleMode(editor.mode);
                        }

                        // ── undo ──────────────────────────────────
                        if (ksc == .z and editor.mode != .off) {
                            _ = bsp.undo();
                        }

                        // ── delete ────────────────────────────────
                        if (ksc == .delete and bsp.selected_node != null) {
                            _ = bsp.deleteNode(bsp.selected_node.?, !shift) catch false;
                        }

                        // ── swap children ─────────────────────────
                        if (ksc == .f and bsp.selected_node != null) {
                            bsp.swapChildren(bsp.selected_node.?) catch {};
                        }

                        // ── toggle leaf ───────────────────────────
                        if (ksc == .t and bsp.selected_node != null) {
                            _ = bsp.toggleLeaf(bsp.selected_node.?, !shift) catch false;
                        }

                        // ── rotate to look dir (adjust mode) ──────
                        if (ksc == .r and editor.mode == .adjust and bsp.selected_node != null) {
                            bsp.rotatePlane(bsp.selected_node.?, player.lookDir()) catch {};
                        }

                        // ── debug overlay ─────────────────────────
                        if (ksc == .g) {
                            editor.show_debug = !editor.show_debug;
                            bsp.debug_dirty = true;
                        }

                        // ── tree navigation (select/adjust) ───────
                        if (editor.mode == .select or editor.mode == .adjust) {
                            if (bsp.selected_node) |sel| {
                                if (ksc == .up) {
                                    if (bsp.findParent(sel)) |p| {
                                        bsp.selected_node = p.idx;
                                        editor.last_was_front = p.is_front;
                                        bsp.markDirty();
                                    }
                                }
                                if (ksc == .down) {
                                    // Go back to the child we came from
                                    const s = bsp.nodes.slice();
                                    const child = if (editor.last_was_front) s.items(.front)[sel] else s.items(.back)[sel];
                                    if (!Bsp.isLeaf(child)) {
                                        bsp.selected_node = child;
                                        bsp.markDirty();
                                    }
                                }
                                if (ksc == .left) {
                                    const fc = bsp.nodes.slice().items(.front)[sel];
                                    if (!Bsp.isLeaf(fc)) {
                                        bsp.selected_node = fc;
                                        editor.last_was_front = true;
                                        bsp.markDirty();
                                    }
                                }
                                if (ksc == .right) {
                                    const bc = bsp.nodes.slice().items(.back)[sel];
                                    if (!Bsp.isLeaf(bc)) {
                                        bsp.selected_node = bc;
                                        editor.last_was_front = false;
                                        bsp.markDirty();
                                    }
                                }
                            }
                        }
                    }
                },

                .mouse_button_down => |m| {
                    if (!mouse_locked) {
                        if (m.button == .left or m.button == .right) {
                            mouse_locked = true;
                            sdl.mouse.hide() catch {};
                            sdl.mouse.setWindowRelativeMode(win, true) catch {};
                        }
                        continue;
                    }

                    switch (editor.mode) {
                        .off => {},

                        .select => {
                            if (m.button == .left) {
                                const eye = player.eyePos();
                                const dir = player.lookDir();
                                if (bsp.rayPick(eye, dir)) |pick| {
                                    bsp.selected_node = pick.node;
                                } else {
                                    bsp.selected_node = null;
                                }
                                bsp.markDirty();
                            }
                        },

                        .place => {
                            if ((m.button == .left or m.button == .right) and !editor.placing) {
                                editor.split_mode = if (m.button == .left) .solid else .empty;
                                const eye = player.eyePos();
                                const dir = player.lookDir();
                                if (bsp.trace(eye, dir, 200, 0)) |hit| {
                                    var anchor = eye.add(dir.scale(hit.dist));
                                    if (editor.split_mode == .solid)
                                        anchor = anchor.add(hit.normal.scale(0.01))
                                    else
                                        anchor = anchor.sub(hit.normal.scale(0.01));
                                    if (shift) anchor = snapToGrid(anchor, editor.grid_size);
                                    editor.anchor = anchor;
                                    editor.placing = true;
                                }
                            }
                        },

                        .adjust => {},
                    }
                },

                .mouse_button_up => |m| {
                    if (editor.mode == .place and editor.placing) {
                        const is_match = (m.button == .left and editor.split_mode == .solid) or
                            (m.button == .right and editor.split_mode == .empty);
                        if (is_match) {
                            var normal = player.lookDir();
                            if (shift) {
                                const snap_y = snapAngle(player.yaw, editor.angle_step);
                                const snap_p = snapAngle(player.pitch, editor.angle_step);
                                const cp = @cos(snap_p);
                                normal = Vec3.new(
                                    @sin(snap_y) * cp,
                                    -@sin(snap_p),
                                    -@cos(snap_y) * cp,
                                ).normalize();
                            }
                            _ = bsp.editorSplit(editor.anchor, normal, editor.split_mode) catch false;
                            editor.placing = false;
                        }
                    }
                },

                .mouse_wheel => |w| {
                    if (editor.mode == .off) continue;
                    if (w.y == 0) continue;

                    if (editor.mode == .adjust and bsp.selected_node != null) {
                        // Translate selected plane along its normal
                        const delta: f32 = if (w.y > 0) editor.grid_size else -editor.grid_size;
                        bsp.translatePlane(bsp.selected_node.?, delta) catch {};
                    } else if (editor.mode == .place) {
                        const f: f32 = if (w.y > 0) 0.5 else 2.0;
                        if (editor.placing) {
                            editor.angle_step = std.math.clamp(
                                editor.angle_step * f,
                                std.math.pi / 180.0,
                                std.math.pi / 4.0,
                            );
                        } else {
                            editor.grid_size = std.math.clamp(
                                editor.grid_size * f,
                                0.0625,
                                16.0,
                            );
                        }
                    } else if (editor.mode == .select) {
                        // In select mode, scroll adjusts grid for convenience
                        const f: f32 = if (w.y > 0) 0.5 else 2.0;
                        editor.grid_size = std.math.clamp(editor.grid_size * f, 0.0625, 16.0);
                    }
                },

                .mouse_motion => |m| {
                    if (mouse_locked) {
                        mdx += m.x_rel;
                        mdy += m.y_rel;
                    }
                },

                else => {},
            }
        }

        // ── look ──────────────────────────────────────────────────
        if (mouse_locked) {
            player.yaw += mdx * 0.002;
            player.pitch = std.math.clamp(player.pitch + mdy * 0.002, -1.5, 1.5);
        }

        // ── movement input ────────────────────────────────────────
        const fwd_in: f32 = if (keys[@intFromEnum(sc.w)]) 1 else if (keys[@intFromEnum(sc.s)]) @as(f32, -1) else 0;
        const rgt_in: f32 = if (keys[@intFromEnum(sc.d)]) 1 else if (keys[@intFromEnum(sc.a)]) @as(f32, -1) else 0;
        const jump = keys[@intFromEnum(sc.space)];

        // ── physics ───────────────────────────────────────────────
        const dt: f32 = 1.0 / 60.0;
        player.step(world, eng.wishdir(fwd_in, rgt_in, player.yaw), jump, dt);

        // ── mesh rebuild (between frames) ─────────────────────────
        if (bsp.mesh_dirty) {
            try bsp.rebuildMesh();
            if (bsp.render_indices.items.len > 0) {
                try renderer.gpu.updateMesh(
                    mesh_handle,
                    std.mem.sliceAsBytes(bsp.render_verts.items),
                    std.mem.sliceAsBytes(bsp.render_indices.items),
                    @intCast(bsp.render_indices.items.len),
                );
            }
        }

        if (editor.show_debug and bsp.debug_dirty) {
            try bsp.rebuildDebugMesh();
            if (bsp.debug_indices.items.len > 0) {
                if (debug_handle) |h| {
                    try renderer.gpu.updateMesh(
                        h,
                        std.mem.sliceAsBytes(bsp.debug_verts.items),
                        std.mem.sliceAsBytes(bsp.debug_indices.items),
                        @intCast(bsp.debug_indices.items.len),
                    );
                } else {
                    debug_handle = try renderer.upload(
                        std.mem.sliceAsBytes(bsp.debug_verts.items),
                        @sizeOf(eng.Vertex),
                        std.mem.sliceAsBytes(bsp.debug_indices.items),
                        @intCast(bsp.debug_indices.items.len),
                    );
                }
            }
        }

        // ── render ────────────────────────────────────────────────
        renderer.gpu.clear_color = modeClearColor(editor.mode);

        if (try renderer.beginFrame()) {
            const aspect = @as(f32, @floatFromInt(win_w)) / @as(f32, @floatFromInt(win_h));
            renderer.cameraEuler(
                player.pos,
                player.yaw,
                player.pitch,
                0.6,
                90.0,
                aspect,
                0.1,
                500.0,
            );
            renderer.drawDirect(mesh_handle, Mat4.identity(), .{ 1, 1, 1, 1 });
            if (editor.show_debug) {
                if (debug_handle) |h| renderer.drawDirect(h, Mat4.identity(), .{ 1, 1, 1, 1 });
            }
            try renderer.endFrame();
        }
    }
}
