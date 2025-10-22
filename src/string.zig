pub fn isSafe(str: []const u8) bool {
    return std.mem.findScalar(u8, str, '\\') == null;
}

test isSafe {
    try std.testing.expect(isSafe("Hello"));
    try std.testing.expect(!isSafe("\\\"Hello\\\""));
}

const Error = error{BadUnicodeEscape};

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
                const cp = try std.fmt.parseInt(u21, str[i_pos .. i_pos + 4], 16);
                i_pos += 4;
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
                const cp = try std.fmt.parseInt(u21, str[i_pos .. i_pos + 4], 16);
                i_pos += 4;
                const utf8_len = try std.unicode.utf8CodepointSequenceLength(cp);
                assert(o_pos + utf8_len <= buf.len);
                _ = try std.unicode.utf8Encode(cp, buf[o_pos..]);
                o_pos += utf8_len;
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
    };

    for (cases) |case| {
        var buf: [100]u8 = undefined;
        const len = try unescapeToBuffer(case.in, &buf);
        try std.testing.expectEqualDeep(case.out, buf[0..len]);
    }
}

const std = @import("std");
const assert = std.debug.assert;
