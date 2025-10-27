pub const Node = union(enum) {
    const Self = @This();

    null,
    boolean: bool,
    number: []const u8,
    json_string: []const u8, // JSON escaped
    safe_string: []const u8, // needs no (un)escaping
    wild_string: []const u8, // requires escaping
    multi: []const Self,
    array: []const Self,
    object: []const Self,

    // The first element in an object's slice is its shadow class. This to minimise
    // the size of individual JSONNodes - most of which are the size of a slice.
    class: *const ObjectClass,

    pub fn objectClass(self: Self) *const ObjectClass {
        return switch (self) {
            .object => |o| blk: {
                assert(o.len >= 1);
                const class = o[0].class;
                assert(o.len == class.names.len + 1);
                break :blk class;
            },
            else => unreachable,
        };
    }

    pub fn objectSlice(self: Self) []const Self {
        return switch (self) {
            .object => |o| blk: {
                assert(o.len >= 1);
                break :blk o[1..];
            },
            else => unreachable,
        };
    }

    pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .null => try w.print("null", .{}),
            .boolean => |b| try w.print("{any}", .{b}),
            .number => |n| try w.print("{s}", .{n}),
            .json_string, .safe_string => |s| try w.print("\"{s}\"", .{s}),
            .wild_string => |s| try string.writeEscaped(s, w),
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
            .object => {
                const class = self.objectClass();
                const items = self.objectSlice();
                try w.print("{{", .{});
                for (class.names, 0..) |n, i| {
                    try w.print("\"{s}\":", .{n});
                    try items[i].format(w);
                    if (i < items.len - 1) try w.print(",", .{});
                }
                try w.print("}}", .{});
            },
            .class => unreachable,
        }
    }
};

test Node {
    const ShadowClass = @import("./shadow.zig").ShadowClass;
    const alloc = std.testing.allocator;
    var root = ShadowClass{};
    defer root.deinit(alloc);

    var pi = try root.getNext(alloc, "pi");
    var message = try pi.getNext(alloc, "message");
    var tags = try message.getNext(alloc, "tags");
    var checked = try tags.getNext(alloc, "checked");
    const class = try checked.getClass(alloc);

    const arr_body = [_]Node{
        .{ .json_string = "zig" },
        .{ .safe_string = "json" },
        .{ .json_string = "parser" },
    };

    const obj_body = [_]Node{
        .{ .class = class },
        .{ .number = "3.14" },
        .{ .json_string = "Hello!" },
        .{ .array = &arr_body },
        .{ .boolean = false },
    };

    const obj = Node{ .object = &obj_body };

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

const std = @import("std");
const assert = std.debug.assert;
const ObjectClass = @import("./shadow.zig").ObjectClass;
const string = @import("./string.zig");
