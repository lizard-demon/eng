const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;

const math = @import("fmwk/math.zig");
const phys = @import("fmwk/phys.zig");
const gfx = @import("fmwk/gfx.zig");
const ui = @import("fmwk/ui.zig");
const input = @import("fmwk/input.zig");

const Unit = math.Unit;

const Tree = @import("fmwk/bsp/tree.zig").Tree;
const Mesher = @import("fmwk/bsp/mesher.zig").Mesher;

pub const App = struct {
    const Ui = ui.UiState(gfx.Vertex);
    const LevelMesher = Mesher(gfx.Vertex);

    alloc: std.mem.Allocator,
    win: sdl.video.Window,
    device: gpu.Device,
    renderer: gfx.Renderer,
    
    level_tree: Tree,
    level_mesher: LevelMesher,
    
    gui: Ui,
    in: input.Input,
    
    physics: phys.System,
    player_id: u32 = 0,
    
    mesh_h: gfx.Renderer.Handle = 0,
    running: bool = true,

    pub fn init(alloc: std.mem.Allocator) !App {
        try sdl.init(.{ .video = true, .events = true });

        const win = try sdl.video.Window.init("Runtime Engine", 1280, 720, .{});
        const device = try gpu.Device.init(.{ .spirv = true }, true, null);

        var tree = Tree.init(alloc);
        try tree.initGroundPlane(Unit.ZERO);
        
        try tree.split(.{ Unit.ZERO, Unit.ZERO, Unit.fix(10) }, .{ Unit.ZERO, Unit.ZERO, Unit.ONE.neg() }, .solid);
        try tree.split(.{ Unit.ZERO, Unit.ZERO, Unit.fix(-10) }, .{ Unit.ZERO, Unit.ZERO, Unit.ONE }, .solid);
        try tree.split(.{ Unit.fix(10), Unit.ZERO, Unit.ZERO }, .{ Unit.ONE.neg(), Unit.ZERO, Unit.ZERO }, .solid);
        try tree.split(.{ Unit.fix(-10), Unit.ZERO, Unit.ZERO }, .{ Unit.ONE, Unit.ZERO, Unit.ZERO }, .solid);
        
        var mesher = LevelMesher.init(alloc);
        try mesher.build(&tree);

        var renderer = try gfx.Renderer.init(device, win, alloc);
        const mh = try renderer.upload(
            std.mem.sliceAsBytes(mesher.verts.items),
            @sizeOf(gfx.Vertex),
            std.mem.sliceAsBytes(mesher.indices.items),
            @intCast(mesher.indices.items.len)
        );

        var physics = phys.System.init(alloc);
        const player_id = try physics.add(.{ Unit.ZERO, Unit.fix(1.5), Unit.ZERO });

        return .{
            .alloc = alloc,
            .win = win,
            .device = device,
            .renderer = renderer,
            .level_tree = tree,
            .level_mesher = mesher,
            .gui = Ui.init(alloc),
            .in = input.Input.init(),
            .physics = physics,
            .player_id = player_id,
            .mesh_h = mh,
        };
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

    pub fn update(self: *App) !void {
        self.in.update();

        if (self.in.quit) {
            self.running = false;
        }

        if (self.in.keyPressed(.escape)) {
            if (self.in.mouse_locked) {
                self.in.setLock(self.win, false);
            }
        }

        if (self.in.mouse_locked) {
            self.physics.angles.items[self.player_id] = self.physics.angles.items[self.player_id]
                .addY(self.in.mouse_dx * 30)
                .addX(self.in.mouse_dy * 30)
                .clampPitch(); // Encapsulated math function protects from flipping upside down
        }

        var w_val = Unit.ZERO;
        if (self.in.key(.w)) w_val = Unit.ONE else if (self.in.key(.s)) w_val = Unit.ONE.neg();

        var d_val = Unit.ZERO;
        if (self.in.key(.d)) d_val = Unit.ONE else if (self.in.key(.a)) d_val = Unit.ONE.neg();

        const wish_dir = self.physics.angles.items[self.player_id].wishdir(w_val, d_val);
        
        self.physics.step(
            &self.level_tree, 
            &.{.{ .wish = wish_dir, .jump = self.in.key(.space) }}, 
            Unit.fix(1.0 / 60.0), 
            .{}
        );

        self.gui.begin(&self.in);
        var hbuf: [128]u8 = undefined;
        const info_str = try std.fmt.bufPrint(
            &hbuf,
            "POS: {d:.1} {d:.1} {d:.1}",
            .{ 
                self.physics.pos.items[self.player_id][0].flt(),
                self.physics.pos.items[self.player_id][1].flt(), 
                self.physics.pos.items[self.player_id][2].flt()
            }
        );

        try self.gui.textAt(10, 10, info_str, 2.0, .{ 0.9, 0.9, 0.4, 1.0 });

        if (self.in.mouse_locked) {
            try self.gui.crosshair(1280.0 / 2.0, 720.0 / 2.0, 8.0, .{ 1, 1, 1, 0.8 });
        } else {
            self.gui.cy = 40;
            if (try self.gui.button(1, "RESUME", 3.0)) {
                self.in.setLock(self.win, true);
            }
            if (try self.gui.button(2, "QUIT", 3.0)) {
                self.running = false;
            }
        }
        self.gui.end();

        if (!self.in.mouse_locked and self.in.mousePressed(.left)) {
            if (self.gui.hot == 0) {
                self.in.setLock(self.win, true);
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
            const p = Unit.persp(90.0, 1280.0 / 720.0, 0.1, 500.0);
            const v = self.physics.angles.items[self.player_id].view(
                self.physics.pos.items[self.player_id], 
                Unit.fix(0.6)
            );
            const mvp = Unit.mulMat(p, v);

            self.renderer.drawDirect(self.mesh_h, mvp);

            if (self.renderer.ui_handle) |h| {
                const ortho = Unit.ortho(0, 1280.0, 720.0, 0, -1, 1);
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
