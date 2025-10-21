pub const JSONParser = struct {
    const Self = @This();
    pub const NodeList = std.ArrayListUnmanaged(JSONNode);
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
        JunkAfterInput,
        OutOfMemory,
        RestartParser,
    };

    work_alloc: Allocator,
    assembly_alloc: Allocator,
    shadow_root: sc.ShadowClass = .{},
    state: ParserState = .{},
    parsing: bool = false,
    assembly: NodeList = .empty,
    assembly_capacity: usize = 8192,
    scratch: std.ArrayListUnmanaged(NodeList) = .empty,

    pub fn init(work_alloc: Allocator) !Self {
        return Self.initCustom(work_alloc, work_alloc);
    }

    pub fn initCustom(work_alloc: Allocator, assembly_alloc: Allocator) !Self {
        return Self{
            .work_alloc = work_alloc,
            .assembly_alloc = assembly_alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.scratch.items) |*s| {
            s.deinit(self.work_alloc);
        }
        self.scratch.deinit(self.work_alloc);
        self.shadow_root.deinit(self.work_alloc);
        self.assembly.deinit(self.assembly_alloc);
    }

    pub fn setAssemblyAllocator(self: *Self, alloc: Allocator) void {
        self.assembly.deinit(self.assembly_alloc);
        self.assembly = .empty;
        self.assembly_alloc = alloc;
    }

    fn checkEof(self: *const Self) Error!void {
        if (self.state.eof()) {
            @branchHint(.unlikely);
            return Error.UnexpectedEndOfInput;
        }
    }

    fn checkMore(self: *Self) Error!void {
        self.state.skipSpace();
        try self.checkEof();
    }

    fn parseLiteral(
        self: *Self,
        comptime lit: []const u8,
        comptime node: JSONNode,
    ) Error!JSONNode {
        if (!self.state.checkLiteral(lit)) {
            @branchHint(.unlikely);
            return Error.BadToken;
        }
        return node;
    }

    fn parseStringBody(self: *Self) Error![]const u8 {
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
            }
        }
        const marked = self.state.takeMarked();
        return marked[0 .. marked.len - 1];
    }

    fn parseKey(self: *Self) Error![]const u8 {
        if (self.state.next() != '"')
            return Error.MissingKey;
        return self.parseStringBody();
    }

    fn parseString(self: *Self) Error!JSONNode {
        _ = self.state.next();
        const marked = try self.parseStringBody();
        return .{ .string = marked };
    }

    fn checkDigits(self: *Self) Error!void {
        try self.checkEof();
        self.state.skipDigits();
    }

    fn parseNumber(self: *Self) Error!JSONNode {
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

    fn getScratch(self: *Self, depth: u32) Error!*NodeList {
        while (self.scratch.items.len <= depth) {
            try self.scratch.append(self.work_alloc, .empty);
        }
        var scratch = &self.scratch.items[depth];
        scratch.items.len = 0;
        return scratch;
    }

    fn appendToAssembly(self: *Self, nodes: []const JSONNode) Error![]const JSONNode {
        const start = self.assembly.items.len;
        const needed = self.assembly.items.len + nodes.len;
        if (self.assembly.capacity < needed) {
            const old_ptr = self.assembly.items.ptr;
            try self.assembly.ensureTotalCapacity(self.assembly_alloc, needed * 4);

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

    fn parseArray(self: *Self, depth: u32) Error!JSONNode {
        _ = self.state.next();
        try self.checkMore();
        var scratch = try self.getScratch(depth);
        // Empty array is a special case
        if (self.state.peek() == ']') {
            _ = self.state.next();
        } else {
            while (true) {
                const node = try self.parseValue(depth + 1);
                try scratch.append(self.work_alloc, node);
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

    fn parseObject(self: *Self, depth: u32) Error!JSONNode {
        _ = self.state.next();
        try self.checkMore();

        var scratch = try self.getScratch(depth);
        // Make a space for the class
        try scratch.append(self.work_alloc, .{ .null = {} });
        var shadow = &self.shadow_root;

        // Empty object is a special case
        if (self.state.peek() == '}') {
            _ = self.state.next();
        } else {
            while (true) {
                const key = try self.parseKey();
                shadow = try shadow.getNext(self.work_alloc, key);
                try self.checkMore();
                if (self.state.next() != ':')
                    return Error.MissingColon;

                try self.checkMore();
                const node = try self.parseValue(depth + 1);
                try scratch.append(self.work_alloc, node);
                try self.checkMore();
                const nc = self.state.next();
                if (nc == '}') {
                    break;
                }
                if (nc != ',') {
                    @branchHint(.unlikely);
                    return Error.MissingComma;
                }
                try self.checkMore();
            }
        }

        // Plug the class in
        const class = try shadow.getClass(self.work_alloc);
        scratch.items[0] = .{ .class = class };

        const items = try self.appendToAssembly(scratch.items);
        return .{ .object = items };
    }

    fn parseValue(self: *Self, depth: u32) Error!JSONNode {
        self.state.skipSpace();
        try self.checkEof();
        const nc = self.state.peek();
        const node: JSONNode = switch (nc) {
            'n' => try self.parseLiteral("null", .{ .null = {} }),
            'f' => try self.parseLiteral("false", .{ .boolean = false }),
            't' => try self.parseLiteral("true", .{ .boolean = true }),
            '"' => try self.parseString(),
            '-', '0'...'9' => try self.parseNumber(),
            '[' => try self.parseArray(depth),
            '{' => try self.parseObject(depth),
            else => return Error.SyntaxError,
        };

        return node;
    }

    fn parseMulti(self: *Self, depth: u32) Error!JSONNode {
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
            try scratch.append(self.work_alloc, node);
        }

        const items = try self.appendToAssembly(scratch.items);
        return .{ .multi = items };
    }

    fn startParsing(self: *Self, src: []const u8) void {
        assert(!self.parsing);
        self.state = ParserState{};
        self.state.src = src;
        self.assembly.items.len = 0;
        self.parsing = true;
    }

    fn stopParsing(self: *Self) void {
        assert(self.parsing);
        self.parsing = false;
    }

    fn checkForJunk(self: *Self) Error!void {
        self.state.skipSpace();
        if (!self.state.eof())
            return Error.JunkAfterInput;
    }

    pub fn takeAssembly(self: *Self) Error!NodeList {
        defer self.assembly = .empty;
        return self.assembly;
    }

    const ParseFn = fn (self: *Self, src: []const u8) Error!JSONNode;
    const ParseDepthFn = fn (self: *Self, depth: u32) Error!JSONNode;

    inline fn parseUsing(
        self: *Self,
        src: []const u8,
        comptime parser: ParseDepthFn,
    ) Error!JSONNode {
        try self.assembly.ensureTotalCapacity(self.work_alloc, self.assembly_capacity);

        RETRY: while (true) {
            self.startParsing(src);
            defer self.stopParsing();

            // A space for the root object
            try self.assembly.append(self.assembly_alloc, .{ .null = {} });

            const node = parser(self, 0) catch |err| {
                switch (err) {
                    Error.RestartParser => continue :RETRY,
                    else => return err,
                }
            };

            try self.checkForJunk();

            // Make the root the first item of the assembly
            self.assembly.items[0] = node;
            return node;
        }
    }

    inline fn parseWithAllocator(
        self: *Self,
        alloc: Allocator,
        src: []const u8,
        comptime parser: ParseFn,
    ) Error!NodeList {
        const old_assembly = self.assembly;
        const old_alloc = self.assembly_alloc;
        defer {
            self.assembly = old_assembly;
            self.assembly_alloc = old_alloc;
        }
        self.assembly = .empty;
        self.assembly_alloc = alloc;
        errdefer self.assembly.deinit(alloc);
        _ = try parser(self, src);
        return self.takeAssembly();
    }

    pub fn parseToAssembly(self: *Self, src: []const u8) Error!JSONNode {
        return self.parseUsing(src, Self.parseValue);
    }

    pub fn parseMultiToAssembly(self: *Self, src: []const u8) Error!JSONNode {
        return self.parseUsing(src, Self.parseMulti);
    }

    pub fn parseOwned(self: *Self, alloc: Allocator, src: []const u8) Error!NodeList {
        return self.parseWithAllocator(alloc, src, Self.parseToAssembly);
    }

    pub fn parseMultiOwned(self: *Self, alloc: Allocator, src: []const u8) Error!NodeList {
        return self.parseWithAllocator(alloc, src, Self.parseMultiToAssembly);
    }
};

test JSONParser {
    const alloc = std.testing.allocator;
    var p = try JSONParser.init(alloc);
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
        var w = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
        defer w.deinit();

        const res = try p.parseToAssembly(case);
        try w.writer.print("{f}", .{res});
        var output = w.toArrayList();
        defer output.deinit(alloc);
        try std.testing.expect(std.mem.eql(u8, case, output.items));
    }

    for (cases) |case| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
        defer w.deinit();

        var res = try p.parseOwned(alloc, case);

        defer res.deinit(alloc);
        try w.writer.print("{f}", .{res.items[0]});
        var output = w.toArrayList();
        defer output.deinit(alloc);
        try std.testing.expect(std.mem.eql(u8, case, output.items));
    }
}

test {
    _ = @import("./shadow.zig");
    _ = @import("./node.zig");
    _ = @import("./parser_state.zig");
}

const std = @import("std");
const assert = std.debug.assert;
const sc = @import("./shadow.zig");
const JSONNode = @import("./node.zig").JSONNode;
const ParserState = @import("./parser_state.zig").ParserState;
