pub const ObjectClass = struct {
    const Self = @This();
    pub const IndexMap = std.StringHashMapUnmanaged(u32);

    index_map: IndexMap = .empty,
    names: []const []const u8,

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

    pub fn isRoot(self: *const Self) bool {
        return self.index == RootIndex;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        var iter = self.next.valueIterator();
        while (iter.next()) |v| {
            v.deinit(alloc);
        }
        if (self.object_class) |*class| {
            class.deinit(alloc);
        }
        if (!self.isRoot())
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
        if (self.object_class != null) {
            return &self.object_class.?;
        }

        const size = self.index +% 1;

        var names = try alloc.alloc([]const u8, size);
        errdefer alloc.free(names);
        var index_map: ObjectClass.IndexMap = .empty;
        try index_map.ensureTotalCapacity(alloc, size);

        var class: *const Self = self;
        while (!class.isRoot()) : (class = class.parent.?) {
            assert(class.index >= 0 and class.index < size);
            names[class.index] = class.name;
            index_map.putAssumeCapacity(class.name, class.index);
        }

        self.object_class = ObjectClass{
            .index_map = index_map,
            .names = names,
        };

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
}

pub const JSONNode = union(enum) {
    const Self = @This();

    null,
    false,
    true,
    number: []const u8,
    string: []const u8,
    array: []const Self,
    object: []const Self,

    // The first element in an object's slice is its shadow class. This is an
    // attempt to minimise the size of individual JSONNodes - most of which
    // are the size of a slice.
    class: *const ObjectClass,

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null => try w.print("null", .{}),
            .false => try w.print("false", .{}),
            .true => try w.print("true", .{}),
            .number => |n| try w.print("{s}", .{n}),
            .string => |s| try w.print("\"{s}\"", .{s}),
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
        .{ .false = {} },
    };

    const obj = JSONNode{ .object = &obj_body };
    std.debug.print("{f}\n", .{obj});
}

pub fn main() !void {
    std.debug.print("Jelly!\n", .{});
}

const std = @import("std");
const assert = std.debug.assert;
