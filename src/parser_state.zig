pub const ParserState = struct {
    const Self = @This();
    pub const NoMark = std.math.maxInt(u32);

    src: []const u8 = undefined,
    pos: u32 = 0,
    mark: u32 = NoMark,
    line: u32 = 1,
    line_start: u32 = 0,

    pub fn eof(self: *const Self) bool {
        assert(self.pos <= self.src.len);
        return self.pos == self.src.len;
    }

    pub fn col(self: *const Self) u32 {
        return self.pos - self.line_start;
    }

    pub fn peek(self: *const Self) u8 {
        assert(self.pos < self.src.len);
        return self.src[self.pos];
    }

    pub fn next(self: *Self) u8 {
        assert(self.pos < self.src.len);
        defer self.pos += 1;
        return self.src[self.pos];
    }

    pub fn view(self: *const Self) []const u8 {
        return self.src[self.pos..];
    }

    pub fn setMark(self: *Self) void {
        assert(self.mark == NoMark);
        self.mark = self.pos;
    }

    pub fn takeMarked(self: *Self) []const u8 {
        assert(self.mark != NoMark);
        defer self.mark = NoMark;
        return self.src[self.mark..self.pos];
    }

    pub fn skipSpace(self: *Self) void {
        while (true) {
            if (self.eof()) break;
            const nc = self.peek();
            if (!std.ascii.isWhitespace(nc)) break;
            if (nc == '\n') {
                @branchHint(.unlikely);
                self.line += 1;
                self.line_start = self.pos;
            }
            _ = self.next();
        }
    }

    pub fn skipDigits(self: *Self) void {
        while (true) {
            if (self.eof()) return;
            const nc = self.peek();
            if (!std.ascii.isDigit(nc)) break;
            _ = self.next();
        }
    }

    pub fn checkLiteral(self: *Self, comptime lit: []const u8) bool {
        const end: u32 = self.pos + @as(u32, lit.len);
        if (end > self.src.len) {
            @branchHint(.unlikely);
            return false;
        }
        if (!std.mem.eql(u8, lit, self.src[self.pos..end])) {
            @branchHint(.unlikely);
            return false;
        }
        self.pos = end;
        return true;
    }
};

const std = @import("std");
const assert = std.debug.assert;
