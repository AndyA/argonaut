const std = @import("std");
const JSONParser = @import("./parser.zig").JSONParser;
const Loader = @import("./loader.zig").Loader;

const Locator = struct {
    resource: []const u8,
    type: []const u8,
    scope: ?[]const u8,
};

const EditRate = struct {
    denominator: u32,
    numerator: u32,
};

const TechnicalMetadata = struct {
    audioChannelCount: ?u32,
    bbcAspectRatio: ?[]const u8,
    containerFormat: ?[]const u8,
    duration: ?u32,
    ebuAudioLayout: ?[]const u8,
    editRate: ?EditRate,
    formatDescription: ?[]const u8,
    md5Hash: ?[]const u8,
    startTimecodeEditUnits: ?u32,
};

const BytesObject = struct {
    locator: ?Locator,
    size: ?u64,
    technicalMetadata: ?TechnicalMetadata,
    type: []const u8,
};

const Source = struct {
    authority: []const u8,
    id: []const u8,
    type: []const u8,
};

const Document = struct {
    bytesObject: BytesObject,
    deleted: ?bool,
    source: Source,
    timestamp: []const u8,
};

const Change = struct {
    id: []const u8,
    operation: []const u8,
    sequencer: u64,
    document: Document,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = try JSONParser.init(alloc);
    defer p.deinit();

    const src = try std.fs.cwd().readFileAlloc("tmp/test-cdc.json", alloc, .unlimited);
    defer alloc.free(src);

    const node = try p.parseMultiToAssembly(src);

    const start = std.time.microTimestamp();
    const changes = try Loader([]const Change).load(node, alloc);
    const end = std.time.microTimestamp();

    const seconds = @as(f64, @floatFromInt(end - start)) / 1_000_000;

    std.debug.print("Loaded {d} in {d}s\n", .{ changes.len, seconds });

    // for (changes) |change| {
    //     std.debug.print("{s} {s} {d}\n", .{ change.id, change.operation, change.sequencer });
    // }
}
