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

const Locator = struct {
    resource: []const u8,
    type: []const u8,
    scope: ?[]const u8,
};

const EditRate = struct {
    denominator: u32,
    numerator: u32,
};

const BBCAspectRatio = enum {
    @"16F16A",
    @"12F12C",
    @"16F16C",
    @"14P16B",
    @"12P16C",
    @"16P12",
    @"16F16B",
};

const ContainerFormat = enum {
    @"mpeg/ps",
    @"riff/wave",
    @"qt/cont",
    @"mxf/opatom",
    @"mxf/op1a",
    @"riff/avi",
};

const EbuAudioLayout = enum {
    EBU_R123_16c,
    EBU_R123_4b,
    EBU_R48_2a,
};

const TechnicalMetadata = struct {
    audioChannelCount: ?u32,
    bbcAspectRatio: ?BBCAspectRatio,
    containerFormat: ?ContainerFormat,
    duration: ?u32,
    ebuAudioLayout: ?EbuAudioLayout,
    editRate: ?EditRate,
    formatDescription: ?[]const u8,
    md5Hash: ?[]const u8,
    startTimecodeEditUnits: ?u32,
};

const ObjectType = enum {
    browse_audio,
    browse_video,
    primary_audio,
    primary_subtitles,
    primary_video,
};

const BytesObject = struct {
    locator: ?Locator,
    size: ?u64,
    technicalMetadata: ?TechnicalMetadata,
    type: ObjectType,
};

const SourceType = enum {
    item,
    package,
};

const Source = struct {
    authority: []const u8,
    id: []const u8,
    type: SourceType,
};

const Document = struct {
    bytesObject: BytesObject,
    deleted: bool = false,
    source: Source,
    timestamp: []const u8,
};

const ChangeType = enum {
    insert,
    update,
    delete,
};

const Change = struct {
    id: []const u8,
    operation: ChangeType,
    sequencer: u64,
    document: Document,
};

const std = @import("std");
const Parser = @import("./parser.zig");
const Loader = @import("./loader.zig").Loader;
