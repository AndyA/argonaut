pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var p = Parser.init(gpa);
    defer p.deinit();

    const src = try std.fs.cwd().readFileAlloc("tmp/array.json", gpa, .unlimited);

    {
        var timer = try std.time.Timer.start();
        const node = try p.parse(src);
        const changes = try Loader([]const Change).load(node, gpa);
        const elapsed = timer.read();

        const seconds = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000;

        std.debug.print("Loaded {d} in {d}s\n", .{ changes.len, seconds });
    }
    // var w_buf: [128 * 1024]u8 = undefined;
    // var w = std.fs.File.stdout().writer(&w_buf);

    // const root = Node{ .array = node.multi };
    // try w.interface.print("{f}", .{root});

    // try w.interface.flush();

    // const parsed = try std.json.parseFromSliceLeaky([]const Change, alloc, src, .{});
    // defer parsed.deinit();

    // for (changes) |change| {
    //     std.debug.print("{s} {any} {d}\n", .{ change.id, change.operation, change.sequencer });
    // }
}

const Change = struct {
    id: []const u8,
    operation: enum { insert, update, delete },
    sequencer: u64,
    document: struct {
        bytesObject: struct {
            locator: ?struct {
                resource: []const u8,
                type: []const u8,
                scope: ?[]const u8,
            },
            size: ?u64,
            technicalMetadata: ?struct {
                audioChannelCount: ?u32,
                bbcAspectRatio: ?enum {
                    @"12F12C",
                    @"12P16C",
                    @"14P16B",
                    @"16F16A",
                    @"16F16B",
                    @"16F16C",
                    @"16P12",
                },
                containerFormat: ?enum {
                    @"mpeg/ps",
                    @"mxf/op1a",
                    @"mxf/opatom",
                    @"qt/cont",
                    @"riff/avi",
                    @"riff/wave",
                },
                duration: ?u32,
                ebuAudioLayout: ?enum { EBU_R123_16c, EBU_R123_4b, EBU_R48_2a },
                editRate: ?struct { denominator: u32, numerator: u32 },
                formatDescription: ?[]const u8,
                md5Hash: ?[]const u8,
                startTimecodeEditUnits: ?u32,
            },
            type: enum {
                browse_audio,
                browse_video,
                primary_audio,
                primary_subtitles,
                primary_video,
            },
        },
        deleted: bool = false,
        source: struct {
            authority: []const u8,
            id: []const u8,
            type: enum { item, package },
        },
        timestamp: []const u8,
    },
};

const std = @import("std");
const Parser = @import("./parser.zig");
const Node = @import("./node.zig").Node;
const Loader = @import("./loader.zig").Loader;
