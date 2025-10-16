pub const ShadowProperty = struct {
    const Self = @This();
    const NextMap = std.StringHashMapUnmanaged(Self);

    ancestor: ?*const Self,
    name: []const u8,
    next: NextMap = .{},
    index: u32,

    pub fn initRoot() !Self {
        return Self{
            .ancestor = null,
            .name = "$",
            .index = std.math.maxInt(u32),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        var iter = self.next.valueIterator();
        while (iter.next()) |v| {
            v.deinit(allocator);
        }
        self.next.deinit(allocator);
    }

    pub fn getNext(self: *Self, allocator: std.mem.Allocator, name: []const u8) !*Self {
        const gop = try self.next.getOrPut(allocator, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = Self{
                .ancestor = self,
                .name = name,
                .index = self.index +% 1,
            };
        }
        return gop.value_ptr;
    }
};

test ShadowProperty {
    const alloc = std.testing.allocator;
    var root = try ShadowProperty.initRoot();
    defer root.deinit(alloc);

    try std.testing.expectEqual(root.name, "$");

    var foo1 = try root.getNext(alloc, "foo");
    try std.testing.expectEqual(foo1.index, 0);
    try std.testing.expectEqual(foo1.ancestor, &root);

    const bar1 = try foo1.getNext(alloc, "bar");
    try std.testing.expectEqual(bar1.index, 1);
    try std.testing.expectEqual(bar1.ancestor, foo1);

    var foo2 = try root.getNext(alloc, "foo");
    try std.testing.expectEqual(foo1, foo2);
    const bar2 = try foo2.getNext(alloc, "bar");
    try std.testing.expectEqual(bar1, bar2);
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
    class: *const ShadowProperty,

    fn format_object(
        o: []const Self,
        w: *std.Io.Writer,
        class: *const ShadowProperty,
    ) std.Io.Writer.Error!void {
        if (class.index > 0) {
            assert(class.ancestor != null);
            try format_object(o, w, class.ancestor.?);
            try w.print(",", .{});
        }
        try w.print("\"{s}\":", .{class.name});
        try o[class.index].format(w);
    }

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
                assert(class.index == o.len - 2);
                try w.print("{{", .{});
                try format_object(o[1..], w, class);
                try w.print("}}", .{});
            },
            .class => unreachable,
        }
    }
};

test JSONNode {
    const alloc = std.testing.allocator;
    var root = try ShadowProperty.initRoot();
    defer root.deinit(alloc);

    var pi = try root.getNext(alloc, "pi");
    var message = try pi.getNext(alloc, "message");
    var tags = try message.getNext(alloc, "tags");
    const checked = try tags.getNext(alloc, "checked");

    const arr_body = [_]JSONNode{
        .{ .string = "zig" },
        .{ .string = "json" },
        .{ .string = "parser" },
    };

    const obj_body = [_]JSONNode{
        .{ .class = checked },
        .{ .number = "3.14" },
        .{ .string = "Hello!" },
        .{ .array = &arr_body },
        .{ .false = {} },
    };

    const obj = JSONNode{ .object = &obj_body };
    std.debug.print("{f}\n", .{obj});
}

pub fn main() !void {
    var r_buf: [256]u8 = undefined;
    var r = std.fs.File.stdin().reader(&r_buf);

    while (true) {
        const res = try r.interface.takeDelimiter('\n');
        if (res) |ln| {
            std.debug.print("Line: \"{s}\"\n", .{ln});
        } else {
            break;
        }
    }

    std.debug.print("Done!\n", .{});
}

const std = @import("std");
const assert = std.debug.assert;
