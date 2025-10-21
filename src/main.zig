const std = @import("std");
const JSONParser = @import("./parser.zig").JSONParser;

test {
    _ = @import("./parser.zig");
}

fn benchmark(p: *JSONParser, src: []const u8, times: usize) !void {
    for (1..times + 1) |i| {
        const start = std.time.microTimestamp();
        _ = p.parseMultiToAssembly(src) catch |err| {
            std.debug.print("{s} at line {d}, column {d} (...{s}...)\n", .{
                @errorName(err),
                p.state.line,
                p.state.col(),
                p.state.view()[0..30],
            });
            return err;
        };
        const end = std.time.microTimestamp();
        const seconds = @as(f64, @floatFromInt(end - start)) / 1_000_000;
        const rate = @as(f64, @floatFromInt(src.len)) / seconds / 1_000_000;
        std.debug.print("  {d:>3}: {d:>8.3}s {d:>8.3} MB/s\n", .{ i, seconds, rate });
    }
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    while (args.next()) |arg| {
        var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer gpa.deinit();
        const alloc = gpa.allocator();
        var p = try JSONParser.init(alloc);
        defer p.deinit();
        const src = try std.fs.cwd().readFileAlloc(arg, alloc, .unlimited);
        defer alloc.free(src);
        // std.debug.print("{s}\n", .{arg});
        std.debug.print("{s}: {d} bytes\n", .{ arg, src.len });
        // try p.assembly.ensureTotalCapacity(alloc, src.len);
        try benchmark(&p, src, 5);
    }
}
