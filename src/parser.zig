const Parser = @This();
pub const NodeList = std.ArrayListUnmanaged(Node);
const Allocator = std.mem.Allocator;

pub const Error = error{
    UnexpectedEndOfInput,
    SyntaxError,
    BadToken,
    MissingString,
    MissingKey,
    MissingQuotes,
    MissingComma,
    MissingColon,
    MissingDigits,
    JunkAfterInput,
    OutOfMemory,
    RestartParser,
    Overflow,
    InvalidCharacter,
    BadUnicodeEscape,
    CodepointTooLarge,
    Utf8CannotEncodeSurrogateHalf,
};

work_gpa: Allocator,
assembly_gpa: Allocator,
shadow_root: ShadowClass = .{},
state: ParserState = .{},
parsing: bool = false,
assembly: NodeList = .empty,
assembly_capacity: usize = 8192,
scratch: std.ArrayListUnmanaged(NodeList) = .empty,

pub fn init(work_gpa: Allocator) Parser {
    return Parser.initCustom(work_gpa, work_gpa);
}

pub fn initCustom(work_gpa: Allocator, assembly_gpa: Allocator) Parser {
    return Parser{
        .work_gpa = work_gpa,
        .assembly_gpa = assembly_gpa,
    };
}

pub fn deinit(self: *Parser) void {
    for (self.scratch.items) |*s| {
        s.deinit(self.work_gpa);
    }
    self.scratch.deinit(self.work_gpa);
    self.shadow_root.deinit(self.work_gpa);
    self.assembly.deinit(self.assembly_gpa);
    self.* = undefined;
}

pub fn setAssemblyAllocator(self: *Parser, gpa: Allocator) void {
    self.assembly.deinit(self.assembly_gpa);
    self.assembly = .empty;
    self.assembly_gpa = gpa;
}

pub fn takeAssembly(self: *Parser) Error!NodeList {
    defer self.assembly = .empty;
    return self.assembly;
}

fn checkEof(self: *const Parser) Error!void {
    if (self.state.eof()) {
        @branchHint(.unlikely);
        return Error.UnexpectedEndOfInput;
    }
}

fn checkMore(self: *Parser) Error!void {
    self.state.skipSpace();
    try self.checkEof();
}

fn checkDigits(self: *Parser) Error!void {
    const start = self.state.pos;
    self.state.skipDigits();
    if (self.state.pos == start) return Error.MissingDigits;
}

fn getScratch(self: *Parser, depth: u32) Error!*NodeList {
    while (self.scratch.items.len <= depth) {
        try self.scratch.append(self.work_gpa, .empty);
    }
    var scratch = &self.scratch.items[depth];
    scratch.items.len = 0;
    return scratch;
}

fn appendToAssembly(self: *Parser, nodes: []const Node) Error![]const Node {
    const start = self.assembly.items.len;
    const needed = self.assembly.items.len + nodes.len;
    if (self.assembly.capacity < needed) {
        const old_ptr = self.assembly.items.ptr;
        try self.assembly.ensureTotalCapacity(self.assembly_gpa, needed * 4);

        // Track the maximum capacity so that if we give our assembly away we can
        // pre-size the replacement appropriately.
        self.assembly_capacity = @max(self.assembly_capacity, self.assembly.capacity);

        // If the assembly buffer has moved, restart the parser to correct pointers
        // into the buffer. This will tend to stop happening once the buffer has
        // grown large enough.
        if (self.assembly.items.ptr != old_ptr) {
            return Error.RestartParser;
        }
    }

    self.assembly.appendSliceAssumeCapacity(nodes);

    return self.assembly.items[start..];
}

fn parseLiteral(
    self: *Parser,
    comptime lit: []const u8,
    comptime node: Node,
) Error!Node {
    if (!self.state.checkLiteral(lit)) {
        @branchHint(.unlikely);
        return Error.BadToken;
    }
    return node;
}

fn parseString(self: *Parser) Error!Node {
    var safe = true;
    _ = self.state.next();
    self.state.setMark();
    while (true) {
        if (self.state.eof()) {
            @branchHint(.unlikely);
            return Error.MissingQuotes;
        }
        const nc = self.state.next();
        if (nc == '\"') {
            @branchHint(.unlikely);
            break;
        }
        if (nc == '\\') {
            @branchHint(.unlikely);
            try self.checkEof();
            _ = self.state.next();
            safe = false;
        }
    }
    const marked = self.state.takeMarked();
    const body = marked[0 .. marked.len - 1];

    return if (safe) .{ .safe_string = body } else .{ .json_string = body };
}

fn parseKey(self: *Parser) Error![]const u8 {
    if (self.state.peek() != '"')
        return Error.MissingKey;
    const node = try self.parseString();
    return switch (node) {
        .safe_string, .json_string => |s| s,
        else => unreachable,
    };
}

fn parseNumber(self: *Parser) Error!Node {
    self.state.setMark();
    const nc = self.state.peek();
    if (nc == '-') {
        _ = self.state.next();
        try self.checkEof();
    }
    try self.checkDigits();
    if (!self.state.eof() and self.state.peek() == '.') {
        _ = self.state.next();
        try self.checkDigits();
    }
    if (!self.state.eof()) {
        @branchHint(.likely);
        const exp = self.state.peek();
        if (exp == 'E' or exp == 'e') {
            @branchHint(.unlikely);
            _ = self.state.next();
            try self.checkEof();
            const sgn = self.state.peek();
            if (sgn == '+' or sgn == '-') {
                @branchHint(.likely);
                _ = self.state.next();
            }
            try self.checkDigits();
        }
    }
    return .{ .number = self.state.takeMarked() };
}

fn parseArray(self: *Parser, depth: u32) Error!Node {
    _ = self.state.next();
    try self.checkMore();
    var scratch = try self.getScratch(depth);
    // Empty array is a special case
    if (self.state.peek() == ']') {
        _ = self.state.next();
    } else {
        while (true) {
            const node = try self.parseValue(depth + 1);
            try scratch.append(self.work_gpa, node);
            try self.checkMore();
            const nc = self.state.next();
            if (nc == ']') {
                break;
            }
            if (nc != ',') {
                @branchHint(.unlikely);
                return Error.MissingComma;
            }
            try self.checkMore();
        }
    }

    const items = try self.appendToAssembly(scratch.items);
    return .{ .array = items };
}

fn parseObject(self: *Parser, depth: u32) Error!Node {
    _ = self.state.next();
    try self.checkMore();

    var scratch = try self.getScratch(depth);
    // Make a space for the class
    try scratch.append(self.work_gpa, .{ .null = {} });
    var shadow = self.shadow_root.startWalk();

    // Empty object is a special case
    if (self.state.peek() == '}') {
        _ = self.state.next();
    } else {
        while (true) {
            const key = try self.parseKey();
            shadow = try shadow.getNext(self.work_gpa, key);
            try self.checkMore();
            if (self.state.next() != ':')
                return Error.MissingColon;

            const node = try self.parseValue(depth + 1);
            try scratch.append(self.work_gpa, node);
            try self.checkMore();
            const nc = self.state.next();
            if (nc == '}') break;
            if (nc != ',') {
                @branchHint(.unlikely);
                return Error.MissingComma;
            }
            try self.checkMore();
        }
    }

    // Plug the class in
    const class = try shadow.getClass(self.work_gpa);
    scratch.items[0] = .{ .class = class };

    const items = try self.appendToAssembly(scratch.items);
    return .{ .object = items };
}

fn parseValue(self: *Parser, depth: u32) Error!Node {
    try self.checkMore();
    const nc = self.state.peek();
    return switch (nc) {
        'n' => self.parseLiteral("null", .{ .null = {} }),
        'f' => self.parseLiteral("false", .{ .boolean = false }),
        't' => self.parseLiteral("true", .{ .boolean = true }),
        '"' => self.parseString(),
        '-', '0'...'9' => self.parseNumber(),
        '[' => self.parseArray(depth),
        '{' => self.parseObject(depth),
        else => return Error.SyntaxError,
    };
}

fn parseMultiNode(self: *Parser, depth: u32) Error!Node {
    var scratch = try self.getScratch(depth);
    while (true) {
        self.state.skipSpace();
        if (self.state.eof()) break;
        if (self.state.peek() == ',') {
            _ = self.state.next();
            self.state.skipSpace();
            if (self.state.eof()) break;
        }
        const node = try self.parseValue(depth + 1);
        try scratch.append(self.work_gpa, node);
    }

    const items = try self.appendToAssembly(scratch.items);
    return .{ .multi = items };
}

fn startParsing(self: *Parser, src: []const u8) void {
    assert(!self.parsing);
    self.state = ParserState{ .src = src };
    self.assembly.items.len = 0;
    self.parsing = true;
}

fn stopParsing(self: *Parser) void {
    assert(self.parsing);
    self.parsing = false;
}

fn checkForJunk(self: *Parser) Error!void {
    self.state.skipSpace();
    if (!self.state.eof())
        return Error.JunkAfterInput;
}

const ParseFn = fn (self: *Parser, src: []const u8) Error!Node;
const ParseDepthFn = fn (self: *Parser, depth: u32) Error!Node;

fn parseUsing(
    self: *Parser,
    src: []const u8,
    comptime parser: ParseDepthFn,
) Error!Node {
    try self.assembly.ensureTotalCapacity(self.work_gpa, self.assembly_capacity);

    RESTART: while (true) {
        self.startParsing(src);
        defer self.stopParsing();

        // A space for the root object
        try self.assembly.append(self.assembly_gpa, .{ .null = {} });

        const node = parser(self, 0) catch |err| {
            switch (err) {
                Error.RestartParser => continue :RESTART,
                else => return err,
            }
        };

        try self.checkForJunk();

        // Make the root the first item of the assembly
        self.assembly.items[0] = node;
        return node;
    }
}

fn parseWithAllocator(
    self: *Parser,
    alloc: Allocator,
    src: []const u8,
    comptime parser: ParseFn,
) Error!NodeList {
    const old_assembly = self.assembly;
    const old_alloc = self.assembly_gpa;
    defer {
        self.assembly = old_assembly;
        self.assembly_gpa = old_alloc;
    }
    self.assembly = .empty;
    self.assembly_gpa = alloc;
    errdefer self.assembly.deinit(alloc);
    _ = try parser(self, src);
    return self.takeAssembly();
}

pub fn parse(self: *Parser, src: []const u8) Error!Node {
    return self.parseUsing(src, parseValue);
}

pub fn parseMulti(self: *Parser, src: []const u8) Error!Node {
    return self.parseUsing(src, parseMultiNode);
}

pub fn parseOwned(self: *Parser, alloc: Allocator, src: []const u8) Error!NodeList {
    return self.parseWithAllocator(alloc, src, parse);
}

pub fn parseMultiOwned(self: *Parser, alloc: Allocator, src: []const u8) Error!NodeList {
    return self.parseWithAllocator(alloc, src, parseMulti);
}

test {
    const gpa = std.testing.allocator;
    var p = init(gpa);
    defer p.deinit();

    const cases = [_][]const u8{
        \\null
        ,
        \\"Hello, World"
        ,
        \\[1,2,3]
        ,
        \\{"tags":[1,2,3]}
        ,
        \\{"id":{"name":"Andy","email":"andy@example.com"}}
        ,
        \\[{"id":{"name":"Andy","email":"andy@example.com"}}]
        ,
        \\[{"id":{"name":"Andy","email":"andy@example.com"}},
        ++
            \\{"id":{"name":"Smoo","email":"smoo@example.com"}}]
        ,
        "1",
        "0",
        "1.2345",
        "1e30",
        "1e+30",
        "1.3e-30",
        "-1",
        "-0",
        "-1.2345",
        "-1e30",
        "-1e+30",
        "-1.3e-30",
    };

    for (cases) |case| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(gpa, &buf);
        defer w.deinit();

        const res = try p.parse(case);
        try w.writer.print("{f}", .{res});
        var output = w.toArrayList();
        defer output.deinit(gpa);
        try std.testing.expect(std.mem.eql(u8, case, output.items));
    }

    for (cases) |case| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(gpa, &buf);
        defer w.deinit();

        var res = try p.parseOwned(gpa, case);

        defer res.deinit(gpa);
        try w.writer.print("{f}", .{res.items[0]});
        var output = w.toArrayList();
        defer output.deinit(gpa);
        try std.testing.expect(std.mem.eql(u8, case, output.items));
    }
}

test {
    _ = @import("./shadow.zig");
    _ = @import("./node.zig");
    _ = @import("./ParserState.zig");
}

const std = @import("std");
const assert = std.debug.assert;
const ShadowClass = @import("./shadow.zig").ShadowClass;
const Node = @import("./node.zig").Node;
const ParserState = @import("./ParserState.zig");
