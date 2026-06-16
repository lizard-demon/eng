// src/fmwk/mod.zig
pub const gfx = @import("gfx.zig");
pub const input = @import("input.zig");
pub const math = @import("math.zig");

pub const bsp = struct {
    pub const geom = @import("bsp/geom.zig");
    pub const tree = @import("bsp/tree.zig");
    pub const mesher = @import("bsp/mesher.zig");
};
