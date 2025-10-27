pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc);
    defer p.deinit();

    const src = try std.fs.cwd().readFileAlloc("tmp/test-cdc.json", alloc, .unlimited);
    defer alloc.free(src);

    const node = try p.parseMulti(src);

    const start = std.time.microTimestamp();
    const changes = try Loader([]const Change).load(node, alloc);
    const end = std.time.microTimestamp();

    const seconds = @as(f64, @floatFromInt(end - start)) / 1_000_000;

    std.debug.print("Loaded {d} in {d}s\n", .{ changes.len, seconds });

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
const Loader = @import("./loader.zig").Loader;
