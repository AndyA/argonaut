pub const JSONNode = union(enum) {
    const Self = @This();

    null,
    boolean: bool,
    number: []const u8,
    string: []const u8,
    safe_string: []const u8, // needs no unescaping
    multi: []const Self,
    array: []const Self,
    object: []const Self,

    // The first element in an object's slice is its shadow class. This to minimise
    // the size of individual JSONNodes - most of which are the size of a slice.
    class: *const sc.ObjectClass,

    pub fn objectClass(self: Self) *const sc.ObjectClass {
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
            .string, .safe_string => |s| try w.print("\"{s}\"", .{s}),
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

test JSONNode {
    const alloc = std.testing.allocator;
    var root = sc.ShadowClass{};
    defer root.deinit(alloc);

    var pi = try root.getNext(alloc, "pi");
    var message = try pi.getNext(alloc, "message");
    var tags = try message.getNext(alloc, "tags");
    var checked = try tags.getNext(alloc, "checked");
    const class = try checked.getClass(alloc);

    const arr_body = [_]JSONNode{
        .{ .string = "zig" },
        .{ .safe_string = "json" },
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

const std = @import("std");
const assert = std.debug.assert;
const sc = @import("./shadow.zig");
