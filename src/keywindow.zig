const std = @import("std");

// sliding window keybuffer to spot multi-char sequences in input
pub const KeyWindow = struct {
    const Self = @This();
    window: [4]u8,
    holding: u8, // how many valid bytes in window

    pub fn init() Self {
        return Self{
            .window = undefined,
            .holding = 0,
        };
    }

    pub fn push(self: *Self, c: u8) void {
        if (self.holding < self.window.len) {
            self.window[self.holding] = c;
            self.holding += 1;
        } else {
            std.mem.copyForwards(u8, self.window[0 .. self.holding - 1], self.window[1..]);
            self.window[self.window.len - 1] = c;
        }
    }

    pub fn clear(self: *Self) void {
        self.holding = 0;
    }

    pub fn match(self: *const Self, s: []const u8) bool {
        if (self.holding < s.len) {
            return false;
        }
        return std.mem.containsAtLeast(u8, &self.window, 1, s);
    }
};
