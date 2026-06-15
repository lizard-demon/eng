const std = @import("std");
const math = @import("math.zig");

const font: [128][5]u8 = init: {
    var f = [_][5]u8{.{ 0, 0, 0, 0, 0 }} ** 128;
    f['!'] = .{ 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 };
    f['"'] = .{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000 };
    f['#'] = .{ 0b01010, 0b11111, 0b01010, 0b11111, 0b01010 };
    f['$'] = .{ 0b01110, 0b10100, 0b01110, 0b00101, 0b01110 };
    f['%'] = .{ 0b10001, 0b00010, 0b00100, 0b01000, 0b10001 };
    f['&'] = .{ 0b01000, 0b10100, 0b01000, 0b10101, 0b01101 };
    f['\''] = .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000 };
    f['('] = .{ 0b00010, 0b00100, 0b00100, 0b00100, 0b00010 };
    f[')'] = .{ 0b01000, 0b00100, 0b00100, 0b00100, 0b01000 };
    f['*'] = .{ 0b00000, 0b10101, 0b01110, 0b10101, 0b00000 };
    f['+'] = .{ 0b00000, 0b00100, 0b01110, 0b00100, 0b00000 };
    f[','] = .{ 0b00000, 0b00000, 0b00000, 0b00100, 0b01000 };
    f['-'] = .{ 0b00000, 0b00000, 0b01110, 0b00000, 0b00000 };
    f['.'] = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 };
    f['/'] = .{ 0b00001, 0b00010, 0b00100, 0b01000, 0b10000 };
    f['0'] = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 };
    f['1'] = .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b01110 };
    f['2'] = .{ 0b01110, 0b00001, 0b01110, 0b10000, 0b01110 };
    f['3'] = .{ 0b01110, 0b00001, 0b00110, 0b00001, 0b01110 };
    f['4'] = .{ 0b10001, 0b10001, 0b01111, 0b00001, 0b00001 };
    f['5'] = .{ 0b01111, 0b10000, 0b01110, 0b00001, 0b01110 };
    f['6'] = .{ 0b01110, 0b10000, 0b11110, 0b10001, 0b01110 };
    f['7'] = .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b00100 };
    f['8'] = .{ 0b01110, 0b10001, 0b01110, 0b10001, 0b01110 };
    f['9'] = .{ 0b01110, 0b10001, 0b01111, 0b00001, 0b01110 };
    f[':'] = .{ 0b00000, 0b00100, 0b00000, 0b00100, 0b00000 };
    f[';'] = .{ 0b00000, 0b00100, 0b00000, 0b00100, 0b01000 };
    f['<'] = .{ 0b00010, 0b00100, 0b01000, 0b00100, 0b00010 };
    f['='] = .{ 0b00000, 0b01110, 0b00000, 0b01110, 0b00000 };
    f['>'] = .{ 0b01000, 0b00100, 0b00010, 0b00100, 0b01000 };
    f['?'] = .{ 0b01110, 0b10001, 0b00010, 0b00100, 0b00100 };
    f['@'] = .{ 0b01110, 0b10001, 0b10101, 0b10111, 0b01110 };
    f['A'] = .{ 0b01110, 0b10001, 0b11111, 0b10001, 0b10001 };
    f['B'] = .{ 0b11110, 0b10001, 0b11110, 0b10001, 0b11110 };
    f['C'] = .{ 0b01110, 0b10001, 0b10000, 0b10001, 0b01110 };
    f['D'] = .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 };
    f['E'] = .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b11111 };
    f['F'] = .{ 0b11111, 0b10000, 0b11110, 0b10000, 0b10000 };
    f['G'] = .{ 0b01110, 0b10000, 0b10011, 0b10001, 0b01110 };
    f['H'] = .{ 0b10001, 0b10001, 0b11111, 0b10001, 0b10001 };
    f['I'] = .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b01110 };
    f['J'] = .{ 0b00111, 0b00010, 0b00010, 0b10010, 0b01100 };
    f['K'] = .{ 0b10001, 0b10010, 0b11100, 0b10010, 0b10001 };
    f['L'] = .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 };
    f['M'] = .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001 };
    f['N'] = .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001 };
    f['O'] = .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 };
    f['P'] = .{ 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 };
    f['Q'] = .{ 0b01110, 0b10001, 0b10101, 0b10010, 0b01101 };
    f['R'] = .{ 0b11110, 0b10001, 0b11110, 0b10100, 0b10011 };
    f['S'] = .{ 0b01110, 0b10000, 0b01110, 0b00001, 0b01110 };
    f['T'] = .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100 };
    f['U'] = .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 };
    f['V'] = .{ 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 };
    f['W'] = .{ 0b10001, 0b10001, 0b10101, 0b11011, 0b10001 };
    f['X'] = .{ 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 };
    f['Y'] = .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100 };
    f['Z'] = .{ 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 };
    f['['] = .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01110 };
    f['\\'] = .{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00001 };
    f[']'] = .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b01110 };
    f['^'] = .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000 };
    f['_'] = .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 };
    f['`'] = .{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000 };
    f['a'] = .{ 0b00000, 0b01110, 0b10001, 0b10011, 0b01101 };
    f['b'] = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b11110 };
    f['c'] = .{ 0b00000, 0b01110, 0b10000, 0b10000, 0b01110 };
    f['d'] = .{ 0b00001, 0b00001, 0b01111, 0b10001, 0b01111 };
    f['e'] = .{ 0b00000, 0b01110, 0b11111, 0b10000, 0b01110 };
    f['f'] = .{ 0b00110, 0b01000, 0b11110, 0b01000, 0b01000 };
    f['g'] = .{ 0b00000, 0b01111, 0b10001, 0b01111, 0b00001 };
    f['h'] = .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001 };
    f['i'] = .{ 0b00100, 0b00000, 0b00100, 0b00100, 0b00100 };
    f['j'] = .{ 0b00010, 0b00000, 0b00010, 0b10010, 0b01100 };
    f['k'] = .{ 0b10000, 0b10000, 0b10010, 0b11100, 0b10010 };
    f['l'] = .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 };
    f['m'] = .{ 0b00000, 0b11010, 0b10101, 0b10101, 0b10101 };
    f['n'] = .{ 0b00000, 0b11110, 0b10001, 0b10001, 0b10001 };
    f['o'] = .{ 0b00000, 0b01110, 0b10001, 0b10001, 0b01110 };
    f['p'] = .{ 0b00000, 0b11110, 0b10001, 0b11110, 0b10000 };
    f['q'] = .{ 0b00000, 0b01111, 0b10001, 0b01111, 0b00001 };
    f['r'] = .{ 0b00000, 0b10110, 0b11000, 0b10000, 0b10000 };
    f['s'] = .{ 0b00000, 0b01110, 0b10000, 0b01110, 0b00001 };
    f['t'] = .{ 0b01000, 0b11100, 0b01000, 0b01000, 0b00110 };
    f['u'] = .{ 0b00000, 0b10001, 0b10001, 0b10001, 0b01111 };
    f['v'] = .{ 0b00000, 0b10001, 0b10001, 0b01010, 0b00100 };
    f['w'] = .{ 0b00000, 0b10001, 0b10101, 0b10101, 0b01010 };
    f['x'] = .{ 0b00000, 0b10001, 0b01010, 0b00100, 0b10001 };
    f['y'] = .{ 0b00000, 0b10001, 0b10001, 0b01111, 0b00001 };
    f['z'] = .{ 0b00000, 0b11111, 0b00100, 0b01000, 0b11111 };
    f['{'] = .{ 0b00110, 0b01000, 0b10000, 0b01000, 0b00110 };
    f['|'] = .{ 0b00100, 0b00100, 0b00000, 0b00100, 0b00100 };
    f['}'] = .{ 0b01100, 0b00010, 0b00001, 0b00010, 0b01100 };
    f['~'] = .{ 0b01010, 0b10101, 0b00000, 0b00000, 0b00000 };
    f[127] = .{ 0b11111, 0b11111, 0b11111, 0b11111, 0b11111 };
    break :init f;
};

pub fn UiState(comptime Vertex: type) type {
    return struct {
        const Self = @This();

        mx: f32 = 0,
        my: f32 = 0,
        mdown: bool = false,
        hot: u32 = 0,
        active: u32 = 0,
        cx: f32 = 0,
        cy: f32 = 0,

        verts: std.ArrayListUnmanaged(Vertex) = .{},
        indices: std.ArrayListUnmanaged(u32) = .{},
        alloc: std.mem.Allocator,

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            self.verts.deinit(self.alloc);
            self.indices.deinit(self.alloc);
        }

        pub fn begin(self: *Self, in: anytype) void {
            if (!in.mouse_locked) {
                self.mx = @floatFromInt(in.mouse_x);
                self.my = @floatFromInt(in.mouse_y);
                self.mdown = in.mouse(.left);
            } else {
                self.mx = -1;
                self.my = -1;
                self.mdown = false;
            }
            self.hot = 0;
            self.cx = 20;
            self.cy = 20;
            self.verts.clearRetainingCapacity();
            self.indices.clearRetainingCapacity();
        }

        pub fn end(self: *Self) void {
            if (!self.mdown) {
                self.active = 0;
            }
        }

        fn quad(self: *Self, x: f32, y: f32, w: f32, h: f32, c: [4]f32) !void {
            const b: u32 = @intCast(self.verts.items.len);
            
            const ix = math.Unit.fix(x);
            const iy = math.Unit.fix(y);
            const iw = math.Unit.fix(w);
            const ih = math.Unit.fix(h);

            try self.verts.appendSlice(self.alloc, &.{
                .{ .pos = .{ ix, iy, math.Unit.ZERO }, .color = c },
                .{ .pos = .{ ix.add(iw), iy, math.Unit.ZERO }, .color = c },
                .{ .pos = .{ ix.add(iw), iy.add(ih), math.Unit.ZERO }, .color = c },
                .{ .pos = .{ ix, iy.add(ih), math.Unit.ZERO }, .color = c },
            });
            try self.indices.appendSlice(self.alloc, &.{
                b, b + 3, b + 2,
                b, b + 2, b + 1,
            });
        }

        pub fn textAt(self: *Self, x: f32, y: f32, str: []const u8, scale: f32, color: [4]f32) !void {
            var ox = x;
            for (str) |c| {
                if (c < 128) {
                    for (font[c], 0..) |row, py| {
                        for (0..5) |px| {
                            const bit = (row >> @as(u3, @intCast(4 - px))) & 1;
                            if (bit != 0) {
                                const px_f32 = @as(f32, @floatFromInt(px));
                                const py_f32 = @as(f32, @floatFromInt(py));
                                try self.quad(ox + px_f32 * scale, y + py_f32 * scale, scale, scale, color);
                            }
                        }
                    }
                }
                ox += 6.0 * scale;
            }
        }

        pub fn text(self: *Self, str: []const u8, scale: f32, color: [4]f32) !void {
            try self.textAt(self.cx, self.cy, str, scale, color);
        }

        pub fn crosshair(self: *Self, x: f32, y: f32, size: f32, color: [4]f32) !void {
            try self.quad(x - size, y - 1, size * 2, 2, color);
            try self.quad(x - 1, y - size, 2, size * 2, color);
        }

        pub fn button(self: *Self, id: u32, str: []const u8, scale: f32) !bool {
            const w = @as(f32, @floatFromInt(str.len)) * 6.0 * scale + scale * 2.0;
            const h = 5.0 * scale + scale * 4.0;

            if (self.mx >= self.cx and self.mx < self.cx + w and self.my >= self.cy and self.my < self.cy + h) {
                self.hot = id;
                if (self.active == 0 and self.mdown) {
                    self.active = id;
                }
            }

            const clicked = !self.mdown and self.hot == id and self.active == id;

            var bg: [4]f32 = .{ 0.2, 0.2, 0.25, 1.0 };
            if (self.active == id) {
                bg = .{ 0.8, 0.4, 0.1, 1.0 };
            } else if (self.hot == id) {
                bg = .{ 0.5, 0.5, 0.6, 1.0 };
            }

            try self.quad(self.cx, self.cy, w, h, bg);

            const ocx = self.cx;
            const ocy = self.cy;
            self.cx += scale * 1.5;
            self.cy += scale * 2.0;

            try self.text(str, scale, .{ 1, 1, 1, 1 });

            self.cx = ocx;
            self.cy = ocy + h + 8.0;

            return clicked;
        }
    };
}
