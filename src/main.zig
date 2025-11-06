pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    while (args.next()) |arg| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        var p = Parser.init(gpa);
        defer p.deinit();
        const src = try std.fs.cwd().readFileAlloc(arg, gpa, .unlimited);
        defer gpa.free(src);
        // std.debug.print("{s}\n", .{arg});
        std.debug.print("{s}: {d} bytes\n", .{ arg, src.len });
        // try p.assembly.ensureTotalCapacity(alloc, src.len);
        try benchmark(&p, src, 5);
        walkShadow(&p.shadow_root, 0);
    }
}

fn benchmark(p: *Parser, src: []const u8, times: usize) !void {
    for (1..times + 1) |i| {
        var timer = try std.time.Timer.start();
        _ = p.parseMulti(src) catch |err| {
            std.debug.print("{s} at line {d}, column {d} (...{s}...)\n", .{
                @errorName(err),
                p.state.line,
                p.state.col(),
                p.state.view()[0..30],
            });
            return err;
        };
        const elapsed = timer.read();
        const seconds = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000;
        const rate = @as(f64, @floatFromInt(src.len)) / seconds / 1_000_000;
        std.debug.print("  {d:>3}: {d:>8.3}s {d:>8.3} MB/s\n", .{ i, seconds, rate });
    }
}

fn walkShadow(shadow: *const ShadowClass, depth: u32) void {
    for (0..depth) |_| {
        std.debug.print("  ", .{});
    }
    if (shadow.object_class) |_| {
        std.debug.print("* ", .{});
    } else {
        std.debug.print("- ", .{});
    }
    std.debug.print("{s} ({d})\n", .{ shadow.name, shadow.usage });
    var iter = shadow.next.valueIterator();
    while (iter.next()) |next| {
        walkShadow(next.*, depth + 1);
    }
}

const std = @import("std");
const Parser = @import("./parser.zig");
const ShadowClass = @import("./shadow.zig").ShadowClass;

test {
    _ = @import("./parser.zig");
    _ = @import("./loader.zig");
    _ = @import("./string.zig");
}
