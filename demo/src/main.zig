const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;

const math = @import("fmwk/math.zig");
const phys = @import("fmwk/phys.zig");
const gfx = @import("fmwk/gfx.zig");
const ui = @import("fmwk/ui.zig");
const bsp = @import("fmwk/bsp.zig");

pub const Input = struct {
    keys: []const bool = &[_]bool{},
    keys_just_pressed: [512]bool = [_]bool{false} ** 512,
    mx: f32 = 0,
    my: f32 = 0,
    mdx: f32 = 0,
    mdy: f32 = 0,
    mdown_left: bool = false,
    m_just_pressed_left: bool = false,
    mouse_locked: bool = false,
    quit: bool = false,

    pub fn update(self: *Input, win: sdl.video.Window) void {
        self.mdx = 0;
        self.mdy = 0;

        @memset(&self.keys_just_pressed, false);
        self.m_just_pressed_left = false;

        self.keys = sdl.keyboard.getState();

        const mstate = sdl.mouse.getState();
        self.mdown_left = mstate[0].left;
        self.mx = mstate[1];
        self.my = mstate[2];

        while (sdl.events.poll()) |ev| {
            switch (ev) {
                .quit => self.quit = true,
                .key_down => |k| {
                    if (k.scancode) |sc| {
                        self.keys_just_pressed[@intFromEnum(sc)] = true;
                        if (sc == .escape and self.mouse_locked) {
                            self.setLock(win, false);
                        }
                    }
                },
                .mouse_button_down => |m| {
                    if (m.button == .left) {
                        self.m_just_pressed_left = true;
                    }
                },
                .mouse_motion => |m| {
                    if (self.mouse_locked) {
                        self.mdx += m.x_rel;
                        self.mdy += m.y_rel;
                    }
                },
                else => {},
            }
        }
    }

    pub fn setLock(self: *Input, win: sdl.video.Window, lock: bool) void {
        self.mouse_locked = lock;
        if (lock) {
            sdl.mouse.hide() catch {};
            sdl.mouse.setWindowRelativeMode(win, true) catch {};
        } else {
            sdl.mouse.show() catch {};
            sdl.mouse.setWindowRelativeMode(win, false) catch {};
        }
    }

    pub fn held(self: *const Input, sc: sdl.Scancode) bool {
        return self.keys[@intFromEnum(sc)];
    }
};

pub const App = struct {
    const Ui = ui.UiState(gfx.Vertex);
    const Bsp = bsp.BspCore(gfx.Vertex);

    alloc: std.mem.Allocator,
    win: sdl.video.Window,
    device: gpu.Device,
    renderer: gfx.Renderer,
    engine_bsp: Bsp,
    gui: Ui,
    input: Input,
    player: phys.Body(.{}),
    mesh_h: gfx.Renderer.Handle = 0,
    running: bool = true,

    pub fn init(alloc: std.mem.Allocator) !App {
        try sdl.init(.{ .video = true, .events = true });

        const win = try sdl.video.Window.init("Runtime Engine", 1280, 720, .{});
        const device = try gpu.Device.init(.{ .spirv = true }, true, null);

        var level_bsp = Bsp.init(alloc);
        try level_bsp.initGroundPlane(0);
        
        // Programmatic level builder demonstration (a simple box)
        try level_bsp.split(.{ 0, 0, 10 }, .{ 0, 0, -1 }, .solid); // North Wall
        try level_bsp.split(.{ 0, 0, -10 }, .{ 0, 0, 1 }, .solid); // South Wall
        try level_bsp.split(.{ 10, 0, 0 }, .{ -1, 0, 0 }, .solid); // East Wall
        try level_bsp.split(.{ -10, 0, 0 }, .{ 1, 0, 0 }, .solid); // West Wall
        
        try level_bsp.rebuildMesh();

        var renderer = try gfx.Renderer.init(device, win, alloc);

        const mh = try renderer.upload(
            std.mem.sliceAsBytes(level_bsp.render_verts.items),
            @sizeOf(gfx.Vertex),
            std.mem.sliceAsBytes(level_bsp.render_indices.items),
            @intCast(level_bsp.render_indices.items.len)
        );

        return .{
            .alloc = alloc,
            .win = win,
            .device = device,
            .renderer = renderer,
            .engine_bsp = level_bsp,
            .gui = Ui.init(alloc),
            .input = Input{},
            .player = .{ .pos = .{ 0, 1.5, 0 } },
            .mesh_h = mh,
        };
    }

    pub fn deinit(self: *App) void {
        self.gui.deinit();
        self.renderer.deinit();
        self.engine_bsp.deinit();
        self.win.deinit();
        sdl.quit(.{ .video = true, .events = true });
    }

    pub fn update(self: *App) !void {
        self.input.update(self.win);

        if (self.input.quit) {
            self.running = false;
        }

        if (self.input.mouse_locked) {
            self.player.yaw += self.input.mdx * 0.002;
            self.player.pitch = std.math.clamp(self.player.pitch + self.input.mdy * 0.002, -1.5, 1.5);
        }

        var w_val: f32 = 0;
        if (self.input.held(.w)) {
            w_val = 1;
        } else if (self.input.held(.s)) {
            w_val = -1;
        }

        var d_val: f32 = 0;
        if (self.input.held(.d)) {
            d_val = 1;
        } else if (self.input.held(.a)) {
            d_val = -1;
        }

        const wish_dir = math.wishdir(w_val, d_val, self.player.yaw);
        self.player.step(&self.engine_bsp, wish_dir, self.input.held(.space), 1.0 / 60.0);

        self.gui.begin(&self.input);

        var hbuf: [128]u8 = undefined;
        const info_str = try std.fmt.bufPrint(
            &hbuf,
            "POS: {d:.1} {d:.1} {d:.1}",
            .{ self.player.pos[0], self.player.pos[1], self.player.pos[2] }
        );

        try self.gui.textAt(10, 10, info_str, 2.0, .{ 0.9, 0.9, 0.4, 1.0 });

        if (self.input.mouse_locked) {
            try self.gui.crosshair(1280.0 / 2.0, 720.0 / 2.0, 8.0, .{ 1, 1, 1, 0.8 });
        } else {
            self.gui.cy = 40;
            if (try self.gui.button(1, "RESUME", 3.0)) {
                self.input.setLock(self.win, true);
            }
            if (try self.gui.button(2, "QUIT", 3.0)) {
                self.running = false;
            }
        }
        self.gui.end();

        if (!self.input.mouse_locked and self.input.m_just_pressed_left) {
            if (self.gui.hot == 0) {
                self.input.setLock(self.win, true);
            }
        }

        if (self.gui.indices.items.len > 0) {
            if (self.renderer.ui_handle) |h| {
                try self.renderer.updateMesh(
                    h,
                    std.mem.sliceAsBytes(self.gui.verts.items),
                    std.mem.sliceAsBytes(self.gui.indices.items),
                    @intCast(self.gui.indices.items.len)
                );
            } else {
                self.renderer.ui_handle = try self.renderer.upload(
                    std.mem.sliceAsBytes(self.gui.verts.items),
                    @sizeOf(gfx.Vertex),
                    std.mem.sliceAsBytes(self.gui.indices.items),
                    @intCast(self.gui.indices.items.len)
                );
            }
        }
    }

    pub fn draw(self: *App) !void {
        self.renderer.clear_color = .{ 0.06, 0.07, 0.12, 1.0 };

        if (try self.renderer.beginFrame()) {
            const p = math.persp(90.0, 1280.0 / 720.0, 0.1, 500.0);
            const v = math.view(self.player.pos, self.player.yaw, self.player.pitch, 0.6);
            const mvp = math.mul(p, v);

            self.renderer.drawDirect(self.mesh_h, mvp);

            if (self.renderer.ui_handle) |h| {
                const ortho = math.ortho(0, 1280.0, 720.0, 0, -1, 1);
                self.renderer.drawUI(h, ortho);
            }

            try self.renderer.endFrame();
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator());
    defer app.deinit();

    while (app.running) {
        try app.update();
        try app.draw();
    }
}
