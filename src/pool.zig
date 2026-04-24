//! pool.zig — fixed-capacity generational entity pool
//!
//! Pool(T, cap) gives stable handles with use-after-free detection.
//! No heap — fixed array on the stack / in the struct.
//!
//!   var enemies = eng.Pool(Enemy, 256){};
//!   const h = enemies.add(.{ .hp = 100 }).?;
//!   enemies.get(h).?.hp -= 25;
//!   enemies.remove(h);
//!   // enemies.get(h) → null  (generation mismatch)

const std = @import("std");

pub fn Pool(comptime T: type, comptime capacity: u16) type {
    return struct {
        const Self = @This();

        pub const Handle = packed struct(u32) { index: u16, gen: u16 };
        pub const nil: Handle = .{ .index = std.math.maxInt(u16), .gen = 0 };

        items: [capacity]T = undefined,
        alive: std.StaticBitSet(capacity) = std.StaticBitSet(capacity).initEmpty(),
        gen: [capacity]u16 = [_]u16{0} ** capacity,
        count: u16 = 0,

        pub fn add(self: *Self, item: T) ?Handle {
            for (0..capacity) |i| {
                if (!self.alive.isSet(i)) {
                    self.items[i] = item;
                    self.alive.set(i);
                    self.count += 1;
                    return .{ .index = @intCast(i), .gen = self.gen[i] };
                }
            }
            return null;
        }

        pub fn remove(self: *Self, h: Handle) void {
            if (h.index >= capacity or h.gen != self.gen[h.index]) return;
            self.alive.unset(h.index);
            self.gen[h.index] +%= 1;
            self.count -= 1;
        }

        pub fn get(self: *Self, h: Handle) ?*T {
            if (h.index >= capacity or !self.alive.isSet(h.index) or h.gen != self.gen[h.index]) return null;
            return &self.items[h.index];
        }

        pub fn getConst(self: *const Self, h: Handle) ?*const T {
            if (h.index >= capacity or !self.alive.isSet(h.index) or h.gen != self.gen[h.index]) return null;
            return &self.items[h.index];
        }

        pub const Iterator = struct {
            pool: *Self,
            cursor: u16 = 0,
            pub fn next(it: *Iterator) ?struct { handle: Handle, ptr: *T } {
                while (it.cursor < capacity) {
                    const i = it.cursor;
                    it.cursor += 1;
                    if (it.pool.alive.isSet(i))
                        return .{
                            .handle = .{ .index = i, .gen = it.pool.gen[i] },
                            .ptr = &it.pool.items[i],
                        };
                }
                return null;
            }
        };

        pub fn iter(self: *Self) Iterator { return .{ .pool = self }; }
    };
}
