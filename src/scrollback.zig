const std = @import("std");
const ZVTerm = @import("zvterm").ZVTerm;

pub const ScrollbackFrame = struct {
    const Self = @This();

    cells: []ZVTerm.Cell,
    width: usize,
    height: usize,
    cursorPos: ZVTerm.ZVCursorPos,

    pub fn setup(self: *Self, allocator: std.mem.Allocator, width: usize, height: usize) !void {
        self.cells = try allocator.alloc(ZVTerm.Cell, width * height);
        self.width = width;
        self.height = height;
    }

    pub fn copyFromTerm(self: *Self, term: *ZVTerm) void {
        self.cursorPos = term.getCursorPos();
        for (0..term.height) |y| {
            for (0..term.width) |x| {
                self.cells[y * term.width + x] = term.getCell(x, y);
            }
        }
    }
};

pub const Scrollback = struct {
    const Self = @This();

    width: usize,
    height: usize,
    frames: []ScrollbackFrame,
    scrollDepth: usize,
    oldest: usize, // index for oldest frame
    wr: usize, // write index for new frame

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize, scrollDepth: usize) !Self {
        const frs = try allocator.alloc(ScrollbackFrame, scrollDepth);
        for (frs) |*f| {
            try ScrollbackFrame.setup(f, allocator, width, height);
        }

        return Self{
            .width = width,
            .height = height,
            .scrollDepth = scrollDepth,
            .frames = frs,
            .oldest = 0,
            .wr = 0,
        };
    }

    // write a frame into the buffer
    pub fn pushTerm(self: *Self, term: *ZVTerm) void {
        self.frames[self.wr].copyFromTerm(term);
        // if next write will overwrite oldest, advance oldest
        if (((self.wr + 1) % self.scrollDepth) == self.oldest) {
            self.oldest = (self.oldest + 1) % self.scrollDepth;
        }
        // setup next write index
        self.wr = (self.wr + 1) % self.scrollDepth;
    }

    pub fn getNumStoredFrames(self: *Self) usize {
        if (self.wr == self.oldest) {
            return 0;
        }
        if (self.wr > self.oldest) {
            return self.wr - self.oldest;
        } else {
            return (self.scrollDepth - self.oldest) + self.wr;
        }
    }

    // 0 = now, 1 = back one step, etc.
    pub fn getFrameN(self: *Self, n: usize) ?*const ScrollbackFrame {
        std.debug.assert(self.scrollDepth > 0);
        if (self.getNumStoredFrames() > n) {
            const off = (self.wr + (self.scrollDepth - (1 + n))) % self.scrollDepth;
            return &self.frames[off];
        } else {
            return null;
        }
    }
};
