pub const ObjectClass = struct {
    const Self = @This();
    pub const IndexMap = std.StringHashMapUnmanaged(u32);

    index_map: IndexMap = .empty,
    names: []const []const u8,

    pub fn init(alloc: std.mem.Allocator, shadow: *const ShadowClass) !Self {
        const size = shadow.size();

        var names = try alloc.alloc([]const u8, size);
        errdefer alloc.free(names);
        var index_map: ObjectClass.IndexMap = .empty;
        if (size > 0)
            try index_map.ensureTotalCapacity(alloc, size);

        var class: *const ShadowClass = shadow;
        while (class.size() > 0) : (class = class.parent.?) {
            assert(class.index < size);
            names[class.index] = class.name;
            index_map.putAssumeCapacity(class.name, class.index);
        }

        return Self{
            .index_map = index_map,
            .names = names,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.index_map.deinit(alloc);
        alloc.free(self.names);
    }
};

pub const ShadowClass = struct {
    const Self = @This();
    pub const NextMap = std.StringHashMapUnmanaged(Self);
    pub const RootIndex = std.math.maxInt(u32);
    const ctx = std.hash_map.StringContext{};

    parent: ?*const Self = null,
    object_class: ?ObjectClass = null,
    name: []const u8 = "$",
    next: NextMap = .empty,
    index: u32 = RootIndex,

    pub fn size(self: *const Self) u32 {
        return self.index +% 1;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        var iter = self.next.valueIterator();
        while (iter.next()) |v| {
            v.deinit(alloc);
        }
        if (self.object_class) |*class| {
            class.deinit(alloc);
        }
        if (self.size() > 0)
            alloc.free(self.name);
        self.next.deinit(alloc);
    }

    pub fn getNext(self: *Self, alloc: std.mem.Allocator, name: []const u8) !*Self {
        const slot = try self.next.getOrPutContextAdapted(alloc, name, ctx, ctx);
        if (!slot.found_existing) {
            const key_name = try alloc.dupe(u8, name);
            slot.key_ptr.* = key_name;
            slot.value_ptr.* = Self{
                .parent = self,
                .name = key_name,
                .index = self.index +% 1,
            };
        }
        return slot.value_ptr;
    }

    pub fn getClass(self: *Self, alloc: std.mem.Allocator) !*const ObjectClass {
        if (self.object_class == null)
            self.object_class = try ObjectClass.init(alloc, self);

        return &self.object_class.?;
    }
};

test ShadowClass {
    const alloc = std.testing.allocator;
    var root = ShadowClass{};
    defer root.deinit(alloc);

    try std.testing.expectEqual(root.name, "$");

    var foo1 = try root.getNext(alloc, "foo");
    try std.testing.expectEqual(foo1.index, 0);
    try std.testing.expectEqual(foo1.parent, &root);

    var bar1 = try foo1.getNext(alloc, "bar");
    try std.testing.expectEqual(bar1.index, 1);
    try std.testing.expectEqual(bar1.parent, foo1);

    var foo2 = try root.getNext(alloc, "foo");
    try std.testing.expectEqual(foo1, foo2);
    var bar2 = try foo2.getNext(alloc, "bar");
    try std.testing.expectEqual(bar1, bar2);

    const cls1 = try bar1.getClass(alloc);
    const cls2 = try bar2.getClass(alloc);

    try std.testing.expectEqual(cls1, cls2);

    const empty = try root.getClass(alloc);
    try std.testing.expectEqualDeep(0, empty.names.len);
}

pub const JSONNode = union(enum) {
    const Self = @This();

    null,
    boolean: bool,
    number: []const u8,
    string: []const u8,
    multi: []const Self,
    array: []const Self,
    object: []const Self,

    // The first element in an object's slice is its shadow class. This to minimise
    // the size of individual JSONNodes - most of which are the size of a slice.
    class: *const ObjectClass,

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null => try w.print("null", .{}),
            .boolean => |b| try w.print("{any}", .{b}),
            .number => |n| try w.print("{s}", .{n}),
            .string => |s| try w.print("\"{s}\"", .{s}),
            .multi => |m| {
                for (m) |item| {
                    try item.format(w);
                    try w.print("\n", .{});
                }
            },
            .array => |a| {
                try w.print("[", .{});
                for (a, 0..) |item, i| {
                    try item.format(w);
                    if (i < a.len - 1) try w.print(",", .{});
                }
                try w.print("]", .{});
            },
            .object => |o| {
                assert(o.len >= 1);
                const class = o[0].class;
                assert(o.len == class.names.len + 1);
                try w.print("{{", .{});
                for (class.names, 1..) |n, i| {
                    try w.print("\"{s}\":", .{n});
                    try o[i].format(w);
                    if (i < o.len - 1) try w.print(",", .{});
                }
                try w.print("}}", .{});
            },
            .class => unreachable,
        }
    }
};

test JSONNode {
    const alloc = std.testing.allocator;
    var root = ShadowClass{};
    defer root.deinit(alloc);

    var pi = try root.getNext(alloc, "pi");
    var message = try pi.getNext(alloc, "message");
    var tags = try message.getNext(alloc, "tags");
    var checked = try tags.getNext(alloc, "checked");
    const class = try checked.getClass(alloc);

    const arr_body = [_]JSONNode{
        .{ .string = "zig" },
        .{ .string = "json" },
        .{ .string = "parser" },
    };

    const obj_body = [_]JSONNode{
        .{ .class = class },
        .{ .number = "3.14" },
        .{ .string = "Hello!" },
        .{ .array = &arr_body },
        .{ .boolean = false },
    };

    const obj = JSONNode{ .object = &obj_body };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var w = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer w.deinit();
    try w.writer.print("{f}", .{obj});
    var output = w.toArrayList();
    defer output.deinit(alloc);
    try std.testing.expect(std.mem.eql(u8,
        \\{"pi":3.14,"message":"Hello!","tags":["zig","json","parser"],"checked":false}
    , output.items));
}

const ParserState = struct {
    const Self = @This();
    pub const NoMark = std.math.maxInt(u32);

    src: []const u8 = undefined,
    pos: u32 = 0,
    mark: u32 = NoMark,
    line: u32 = 1,
    col: u32 = 0,

    pub fn eof(self: *const Self) bool {
        assert(self.pos <= self.src.len);
        return self.pos == self.src.len;
    }

    pub fn peek(self: *const Self) u8 {
        assert(self.pos < self.src.len);
        return self.src[self.pos];
    }

    pub fn next(self: *Self) u8 {
        assert(self.pos < self.src.len);
        defer self.pos += 1;
        return self.src[self.pos];
    }

    pub fn view(self: *const Self) []const u8 {
        return self.src[self.pos..];
    }

    pub fn setMark(self: *Self) void {
        assert(self.mark == NoMark);
        self.mark = self.pos;
    }

    pub fn takeMarked(self: *Self) []const u8 {
        assert(self.mark != NoMark);
        defer self.mark = NoMark;
        return self.src[self.mark..self.pos];
    }

    pub fn skipSpace(self: *Self) void {
        while (true) {
            if (self.eof()) break;
            const nc = self.peek();
            if (!std.ascii.isWhitespace(nc)) break;
            if (nc == '\n') {
                @branchHint(.unlikely);
                self.line += 1;
                self.col = 0;
            }
            _ = self.next();
        }
    }

    pub fn skipDigits(self: *Self) void {
        while (true) {
            if (self.eof()) return;
            const nc = self.peek();
            if (!std.ascii.isDigit(nc)) break;
            _ = self.next();
        }
    }

    pub fn checkLiteral(self: *Self, comptime lit: []const u8) bool {
        if (!std.mem.eql(u8, lit, self.view())) {
            @branchHint(.unlikely);
            return false;
        }
        self.pos += lit.len;
        return true;
    }
};

pub const JSONParser = struct {
    const Self = @This();
    pub const NodeList = std.ArrayListUnmanaged(JSONNode);
    const Allocator = std.mem.Allocator;

    pub const Error = error{
        UnexpectedEndOfInput,
        SyntaxError,
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
    shadow_root: ShadowClass = .{},
    state: ParserState = .{},
    parsing: bool = false,
    assembly: NodeList = .empty,
    assembly_capacity: usize = 0,
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
            return Error.SyntaxError;
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
        const nc = self.state.next();
        if (nc == '-') {
            try self.checkEof();
            _ = self.state.next();
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
        const old_ptr = self.assembly.items.ptr;
        try self.assembly.ensureUnusedCapacity(self.assembly_alloc, nodes.len);

        // Track the maximum capacity so that if we give our assembly away we can
        // pre-size the replacement appropriately.
        self.assembly_capacity = @max(self.assembly_capacity, self.assembly.capacity);

        // If the assembly buffer has moved, restart the parser to correct pointers
        // into the buffer. This will tend to stop happening once the buffer has
        // grown large enough.
        if (self.assembly.items.ptr != old_ptr)
            return Error.RestartParser;

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

    fn parseWith(self: *Self, src: []const u8, comptime parser: ParseDepthFn) Error!JSONNode {
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

    fn parseWithAllocator(
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
        _ = try parser(self, src);
        return self.takeAssembly();
    }

    pub fn parseSingleToAssembly(self: *Self, src: []const u8) Error!JSONNode {
        return self.parseWith(src, Self.parseValue);
    }

    pub fn parseMultiToAssembly(self: *Self, src: []const u8) Error!JSONNode {
        return self.parseWith(src, Self.parseMulti);
    }

    pub fn parseSingleOwned(self: *Self, alloc: Allocator, src: []const u8) Error!NodeList {
        return self.parseWithAllocator(alloc, src, Self.parseSingleToAssembly);
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
    };

    for (cases) |case| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
        defer w.deinit();

        const res = try p.parseSingleToAssembly(case);
        try w.writer.print("{f}", .{res});
        var output = w.toArrayList();
        defer output.deinit(alloc);
        try std.testing.expect(std.mem.eql(u8, case, output.items));
    }

    for (cases) |case| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var w = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
        defer w.deinit();

        var res = try p.parseSingleOwned(alloc, case);

        defer res.deinit(alloc);
        try w.writer.print("{f}", .{res.items[0]});
        var output = w.toArrayList();
        defer output.deinit(alloc);
        try std.testing.expect(std.mem.eql(u8, case, output.items));
    }
}

pub fn main() !void {
    std.debug.print("Jelly!\n", .{});
}

const std = @import("std");
const assert = std.debug.assert;
