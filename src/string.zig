const Error = error{
    Overflow,
    InvalidCharacter,
    BadUnicodeEscape,
    CodepointTooLarge,
    Utf8CannotEncodeSurrogateHalf,
};

fn nextEscape(str: []const u8) usize {
    for (str, 0..) |c, i|
        if (c < 0x20 or c == 0x7f or c == '\\') return i;
    return str.len;
}

pub fn needsEscape(str: []const u8) bool {
    return nextEscape(str) != str.len;
}

pub fn writeEscaped(str: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var slice = str;
    while (slice.len > 0) {
        const safe_len = nextEscape(slice);
        if (safe_len > 0) {
            try w.print("{s}", .{slice[0..safe_len]});
            slice = slice[safe_len..];
            continue;
        }
        assert(slice.len > 0);
        switch (slice[0]) {
            '\\' => try w.print("\\\\", .{}),
            0x08 => try w.print("\\b", .{}),
            0x0c => try w.print("\\f", .{}),
            0x0a => try w.print("\\n", .{}),
            0x0d => try w.print("\\r", .{}),
            0x09 => try w.print("\\t", .{}),
            else => |c| try w.print("\\u{x:>04}", .{c}),
        }
        slice = slice[1..];
    }
}

pub fn isSurrogateHigh(cp: u21) bool {
    return cp >= 0xd800 and cp < 0xdc00;
}

pub fn isSurrogateLow(cp: u21) bool {
    return cp >= 0xdc00 and cp < 0xe000;
}

pub fn decodeSurrogatePair(cp_high: u21, cp_low: u21) u21 {
    assert(isSurrogateHigh(cp_high));
    assert(isSurrogateLow(cp_low));
    return ((cp_high & 0x03ff) << 10) + (cp_low & 0x3ff) + 0x10000;
}

test decodeSurrogatePair {
    try std.testing.expectEqual(0x10000, decodeSurrogatePair(0xd800, 0xdc00));
    try std.testing.expectEqual(0x1f603, decodeSurrogatePair(0xd83d, 0xde03));
    try std.testing.expectEqual(0x10ffff, decodeSurrogatePair(0xdbff, 0xdfff));
}

pub fn unescapedLength(str: []const u8) !usize {
    var i_pos: usize = 0;
    var o_len: usize = 0;
    while (i_pos != str.len) {
        const nc = str[i_pos];
        i_pos += 1;
        if (nc == '\\') {
            assert(i_pos != str.len);
            const ec = str[i_pos];
            i_pos += 1;
            if (ec == 'u') {
                if (i_pos > str.len - 4)
                    return Error.BadUnicodeEscape;
                var cp = try std.fmt.parseInt(u21, str[i_pos .. i_pos + 4], 16);
                i_pos += 4;
                if (isSurrogateLow(cp))
                    return Error.Utf8CannotEncodeSurrogateHalf;
                if (isSurrogateHigh(cp)) {
                    if (i_pos <= str.len - 1 and str[i_pos] != '\\')
                        return Error.Utf8CannotEncodeSurrogateHalf;
                    if (i_pos <= str.len - 2 and str[i_pos + 1] != 'u')
                        return Error.Utf8CannotEncodeSurrogateHalf;
                    if (i_pos > str.len - 6)
                        return Error.BadUnicodeEscape;
                    const cp_low = try std.fmt.parseInt(u21, str[i_pos + 2 .. i_pos + 6], 16);
                    i_pos += 6;
                    if (!isSurrogateLow((cp_low)))
                        return Error.Utf8CannotEncodeSurrogateHalf;
                    cp = decodeSurrogatePair(cp, cp_low);
                }
                o_len += try std.unicode.utf8CodepointSequenceLength(cp);
            } else {
                o_len += 1;
            }
        } else {
            o_len += 1;
        }
    }
    return o_len;
}

pub fn unescapeToBuffer(str: []const u8, buf: []u8) !usize {
    var i_pos: usize = 0;
    var o_pos: usize = 0;
    while (i_pos != str.len) {
        const nc = str[i_pos];
        i_pos += 1;
        if (nc == '\\') {
            assert(i_pos != str.len);
            const ec = str[i_pos];
            i_pos += 1;
            if (ec == 'u') {
                if (i_pos > str.len - 4)
                    return Error.BadUnicodeEscape;
                var cp = try std.fmt.parseInt(u21, str[i_pos .. i_pos + 4], 16);
                i_pos += 4;
                if (isSurrogateLow(cp))
                    return Error.Utf8CannotEncodeSurrogateHalf;
                if (isSurrogateHigh(cp)) {
                    if (i_pos <= str.len - 1 and str[i_pos] != '\\')
                        return Error.Utf8CannotEncodeSurrogateHalf;
                    if (i_pos <= str.len - 2 and str[i_pos + 1] != 'u')
                        return Error.Utf8CannotEncodeSurrogateHalf;
                    if (i_pos > str.len - 6)
                        return Error.BadUnicodeEscape;
                    const cp_low = try std.fmt.parseInt(u21, str[i_pos + 2 .. i_pos + 6], 16);
                    i_pos += 6;
                    if (!isSurrogateLow((cp_low)))
                        return Error.Utf8CannotEncodeSurrogateHalf;
                    cp = decodeSurrogatePair(cp, cp_low);
                }
                o_pos += try std.unicode.utf8Encode(cp, buf[o_pos..]);
            } else {
                const rc = switch (ec) {
                    '\"', '\\', '/' => |c| c,
                    'b' => 0x08,
                    'f' => 0x0c,
                    'n' => 0x0a,
                    'r' => 0x0d,
                    't' => 0x09,
                    else => return Error.BadUnicodeEscape,
                };
                assert(o_pos < buf.len);
                buf[o_pos] = rc;
                o_pos += 1;
            }
        } else {
            assert(o_pos < buf.len);
            buf[o_pos] = nc;
            o_pos += 1;
        }
    }
    return o_pos;
}

pub fn unescapeAlloc(str: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const out_len = try unescapedLength(str);
    const out = try alloc.alloc(u8, out_len);
    errdefer alloc.free(out);
    _ = try unescapeToBuffer(str, out);
    return out;
}

const TestCase = struct { in: []const u8, out: []const u8 };
fn tc(in: []const u8, out: []const u8) TestCase {
    return .{ .in = in, .out = out };
}

test unescapeToBuffer {
    const cases = [_]TestCase{
        tc("Hello", "Hello"),
        tc("\\\\", "\\"),
        tc("\\n", "\n"),
        tc("\\\"Hello\\\"", "\"Hello\""),
        tc("\\uffe9", "\u{ffe9}"),
        tc("Hello\\uffe9now", "Hello\u{ffe9}now"),
        tc("\\udbff\\udfff", "\u{10ffff}"),
    };

    for (cases) |case| {
        var buf: [100]u8 = @splat(0);
        const len = try unescapeToBuffer(case.in, &buf);

        try std.testing.expectEqual(len, unescapedLength(case.in));
        try std.testing.expectEqualDeep(case.out, buf[0..len]);
    }
}

const std = @import("std");
const assert = std.debug.assert;
