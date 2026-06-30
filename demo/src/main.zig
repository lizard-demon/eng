const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;

const fmwk = @import("engine");
const gfx = fmwk.gfx;
const input = fmwk.input;

const phys = @import("phys.zig");
const ui = @import("ui.zig");

const Unit = fmwk.math.Unit;
const Tree = fmwk.bsp.tree.Tree;
const Mesher = fmwk.bsp.mesher.Mesher;

pub const App = struct {
    const Ui = ui.State(gfx.Vertex);
    const LevelMesher = Mesher(gfx.Vertex);

    alloc: std.mem.Allocator,
    win: sdl.video.Window,
    device: gpu.Device,
    renderer: gfx.Renderer,

    level_tree: Tree,
    level_mesher: LevelMesher,
    mesh_h: gfx.Renderer.Handle = 0,
    ui_mesh_h: ?gfx.Renderer.Handle = null,

    gui: Ui,
    in: input.Input,

    physics: phys.System,
    player_id: u32 = 0,

    running: bool = true,

    pub fn init(alloc: std.mem.Allocator) !App {
        try sdl.init(.{ .video = true, .events = true });
        const win = try sdl.video.Window.init("Runtime Engine", 1280, 720, .{});
        const device = try gpu.Device.init(.{ .spirv = true }, true, null);

        const vert_spv = @embedFile("shaders/triangle.vert.spv");
        const frag_spv = @embedFile("shaders/triangle.frag.spv");

        var app = App{
            .alloc = alloc,
            .win = win,
            .device = device,
            .renderer = try gfx.Renderer.init(device, win, alloc, vert_spv, frag_spv),
            .level_tree = Tree.init(alloc),
            .level_mesher = LevelMesher.init(alloc),
            .gui = Ui.init(alloc),
            .in = input.Input.init(),
            .physics = phys.System.init(alloc),
        };

        try app.buildLevel();
        try app.initPlayer();

        return app;
    }

    pub fn deinit(self: *App) void {
        self.gui.deinit();
        self.physics.deinit();
        self.renderer.deinit();
        self.level_mesher.deinit();
        self.level_tree.deinit();
        self.win.deinit();
        sdl.quit(.{ .video = true, .events = true });
    }

    fn buildLevel(self: *App) !void {
        try self.level_tree.initGroundPlane(Unit.ZERO);
        try self.level_tree.split(.{ Unit.ZERO, Unit.ZERO, Unit.fix(10) }, .{ Unit.ZERO, Unit.ZERO, Unit.ONE.neg() }, .solid);
        try self.level_tree.split(.{ Unit.ZERO, Unit.ZERO, Unit.fix(-10) }, .{ Unit.ZERO, Unit.ZERO, Unit.ONE }, .solid);
        try self.level_tree.split(.{ Unit.fix(10), Unit.ZERO, Unit.ZERO }, .{ Unit.ONE.neg(), Unit.ZERO, Unit.ZERO }, .solid);
        try self.level_tree.split(.{ Unit.fix(-10), Unit.ZERO, Unit.ZERO }, .{ Unit.ONE, Unit.ZERO, Unit.ZERO }, .solid);
        
        try self.level_mesher.build(&self.level_tree);

        self.mesh_h = try self.renderer.upload(
            std.mem.sliceAsBytes(self.level_mesher.verts.items),
            @sizeOf(gfx.Vertex),
            std.mem.sliceAsBytes(self.level_mesher.indices.items),
            @intCast(self.level_mesher.indices.items.len)
        );
    }

    fn initPlayer(self: *App) !void {
        self.player_id = try self.physics.add(.{ Unit.ZERO, Unit.fix(1.5), Unit.ZERO });
    }

    pub fn update(self: *App) !void {
        self.in.update();
        if (self.in.quit) self.running = false;

        self.handleInput();
        self.updatePhysics();
        try self.updateUi();
    }

    fn handleInput(self: *App) void {
        if (self.in.keyPressed(.escape) and self.in.mouse_locked) {
            self.in.setLock(self.win, false);
        }

        if (!self.in.mouse_locked and self.in.mousePressed(.left) and self.gui.hot == 0) {
            self.in.setLock(self.win, true);
        }
    }

    fn updatePhysics(self: *App) void {
        if (self.in.mouse_locked) {
            self.physics.angles.items[self.player_id] = self.physics.angles.items[self.player_id]
                .addY(self.in.mouse_dx * 30)
                .addX(self.in.mouse_dy * 30)
                .clampPitch();
        }

        const w_val = if (self.in.key(.w)) Unit.ONE else if (self.in.key(.s)) Unit.ONE.neg() else Unit.ZERO;
        const d_val = if (self.in.key(.d)) Unit.ONE else if (self.in.key(.a)) Unit.ONE.neg() else Unit.ZERO;
        const wish_dir = self.physics.angles.items[self.player_id].wishdir(w_val, d_val);
        
        self.physics.step(
            &self.level_tree, 
            &.{.{ .wish = wish_dir, .jump = self.in.key(.space) }}, 
            Unit.fix(1.0 / 60.0), 
            .{}
        );
    }

    fn updateUi(self: *App) !void {
        self.gui.begin(&self.in);
        
        var hbuf: [128]u8 = undefined;
        const pos = self.physics.pos.items[self.player_id];
        const info_str = try std.fmt.bufPrint(
            &hbuf, "POS: {d:.1} {d:.1} {d:.1}",
            .{ pos[0].flt(), pos[1].flt(), pos[2].flt() }
        );
        try self.gui.textAt(10, 10, info_str, 2.0, .{ 0.9, 0.9, 0.4, 1.0 });

        if (self.in.mouse_locked) {
            try self.gui.crosshair(1280.0 / 2.0, 720.0 / 2.0, 8.0, .{ 1, 1, 1, 0.8 });
        } else {
            self.gui.cy = 40;
            if (try self.gui.button(1, "RESUME", 3.0)) self.in.setLock(self.win, true);
            if (try self.gui.button(2, "QUIT", 3.0)) self.running = false;
        }
        self.gui.end();

        if (self.gui.indices.items.len > 0) {
            const v_bytes = std.mem.sliceAsBytes(self.gui.verts.items);
            const i_bytes = std.mem.sliceAsBytes(self.gui.indices.items);
            const i_count: u32 = @intCast(self.gui.indices.items.len);

            if (self.ui_mesh_h) |h| {
                try self.renderer.updateMesh(h, v_bytes, i_bytes, i_count);
            } else {
                self.ui_mesh_h = try self.renderer.upload(v_bytes, @sizeOf(gfx.Vertex), i_bytes, i_count);
            }
        }
    }

    pub fn draw(self: *App) !void {
        self.renderer.clear_color = .{ 0.06, 0.07, 0.12, 1.0 };

        if (try self.renderer.beginFrame()) {
            const p = Unit.persp(90.0, 1280.0 / 720.0, 0.1, 500.0);
            const v = self.physics.angles.items[self.player_id].view(
                self.physics.pos.items[self.player_id], 
                Unit.fix(0.6)
            );

            self.renderer.draw(self.mesh_h, Unit.mulMat(p, v), false);

            if (self.ui_mesh_h) |h| {
                self.renderer.draw(h, Unit.ortho(0, 1280.0, 720.0, 0, -1, 1), true);
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
