const std = @import("std");
const sdl = @import("sdl3");

pub const Input = struct {
    keys_held: []const bool = &[_]bool{},
    keys_pressed: [512]bool = [_]bool{false} ** 512,
    keys_released: [512]bool = [_]bool{false} ** 512,

    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_dx: i32 = 0,
    mouse_dy: i32 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,

    mouse_held: [5]bool = [_]bool{false} ** 5,
    mouse_pressed: [5]bool = [_]bool{false} ** 5,
    mouse_released: [5]bool = [_]bool{false} ** 5,
    
    mouse_locked: bool = false,

    quit: bool = false,

    pub fn init() Input {
        return .{};
    }

    pub fn update(self: *Input) void {
        self.mouse_dx = 0;
        self.mouse_dy = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
        
        @memset(&self.keys_pressed, false);
        @memset(&self.keys_released, false);
        @memset(&self.mouse_pressed, false);
        @memset(&self.mouse_released, false);

        self.keys_held = sdl.keyboard.getState();
        
        const mstate = sdl.mouse.getState();
        self.mouse_held[0] = mstate[0].left;
        self.mouse_held[1] = mstate[0].middle;
        self.mouse_held[2] = mstate[0].right;
        self.mouse_held[3] = mstate[0].side1;
        self.mouse_held[4] = mstate[0].side2;
        
        self.mouse_x = @intFromFloat(mstate[1]);
        self.mouse_y = @intFromFloat(mstate[2]);

        while (sdl.events.poll()) |ev| switch (ev) {
            .quit => self.quit = true,
            
            .key_down => |k| if (k.scancode) |sc| {
                self.keys_pressed[@intFromEnum(sc)] = true;
            },
            .key_up => |k| if (k.scancode) |sc| {
                self.keys_released[@intFromEnum(sc)] = true;
            },
            
            .mouse_button_down => |m| {
                const idx = buttonToIndex(m.button);
                if (idx < 5) self.mouse_pressed[idx] = true;
            },
            .mouse_button_up => |m| {
                const idx = buttonToIndex(m.button);
                if (idx < 5) self.mouse_released[idx] = true;
            },
            
            .mouse_motion => |m| if (self.mouse_locked) {
                self.mouse_dx += @intFromFloat(m.x_rel);
                self.mouse_dy += @intFromFloat(m.y_rel);
            },
            
            .mouse_wheel => |w| {
                self.scroll_x += @intFromFloat(w.x);
                self.scroll_y += @intFromFloat(w.y);
            },
            
            else => {},
        };
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

    pub fn key(self: *const Input, sc: sdl.Scancode) bool {
        return self.keys_held[@intFromEnum(sc)];
    }

    pub fn keyPressed(self: *const Input, sc: sdl.Scancode) bool {
        return self.keys_pressed[@intFromEnum(sc)];
    }

    pub fn keyReleased(self: *const Input, sc: sdl.Scancode) bool {
        return self.keys_released[@intFromEnum(sc)];
    }

    pub fn mouse(self: *const Input, btn: sdl.mouse.Button) bool {
        const idx = buttonToIndex(btn);
        return if (idx < 5) self.mouse_held[idx] else false;
    }

    pub fn mousePressed(self: *const Input, btn: sdl.mouse.Button) bool {
        const idx = buttonToIndex(btn);
        return if (idx < 5) self.mouse_pressed[idx] else false;
    }

    pub fn mouseReleased(self: *const Input, btn: sdl.mouse.Button) bool {
        const idx = buttonToIndex(btn);
        return if (idx < 5) self.mouse_released[idx] else false;
    }

    fn buttonToIndex(btn: sdl.mouse.Button) usize {
        return switch (btn) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .x1 => 3,
            .x2 => 4,
            else => 999, 
        };
    }
};
