pub const LoaderError = error{
    TypeMismatch,
    ArraySizeMismatch,
    MissingField,
};

pub fn Loader(comptime T: type) type {
    comptime {
        switch (@typeInfo(T)) {
            .optional => |info| {
                const ChildLoader = Loader(info.child);
                return struct {
                    pub const Type = T;

                    pub fn load(node: JSONNode, alloc: Allocator) !T {
                        return switch (node) {
                            .null => null,
                            else => try ChildLoader.load(node, alloc),
                        };
                    }

                    pub fn destroy(value: *T, alloc: Allocator) void {
                        if (value.*) |*v| {
                            ChildLoader.destroy(v, alloc);
                        }
                        value.* = undefined;
                    }
                };
            },
            .bool => |info| {
                _ = info;
                return struct {
                    pub const Type = T;

                    pub fn load(node: JSONNode, _: Allocator) !T {
                        return switch (node) {
                            .boolean => |b| b,
                            else => LoaderError.TypeMismatch,
                        };
                    }

                    pub fn destroy(value: *T, _: Allocator) void {
                        value.* = undefined;
                    }
                };
            },
            .int => |info| {
                _ = info;
                return struct {
                    pub const Type = T;

                    pub fn load(node: JSONNode, _: Allocator) !T {
                        return switch (node) {
                            .number => |n| std.fmt.parseInt(T, n, 10),
                            else => LoaderError.TypeMismatch,
                        };
                    }

                    pub fn destroy(value: *T, _: Allocator) void {
                        value.* = undefined;
                    }
                };
            },
            .float => |info| {
                _ = info;
                return struct {
                    pub const Type = T;

                    pub fn load(node: JSONNode, _: Allocator) !T {
                        return switch (node) {
                            .number => |n| std.fmt.parseFloat(T, n),
                            else => LoaderError.TypeMismatch,
                        };
                    }

                    pub fn destroy(value: *T, _: Allocator) void {
                        value.* = undefined;
                    }
                };
            },
            .array => |info| {
                const ChildLoader = Loader(info.child);
                return struct {
                    pub const Type = T;

                    pub fn load(node: JSONNode, alloc: Allocator) !T {
                        return switch (node) {
                            .array => |a| blk: {
                                var size = a.len;
                                if (a.len != info.len)
                                    break :blk LoaderError.ArraySizeMismatch;
                                if (info.sentinel_ptr != null) size += 1;
                                var arr: T = undefined;
                                for (a, 0..) |item, i| {
                                    arr[i] = try ChildLoader.load(item, alloc);
                                }
                                if (info.sentinel()) |s| {
                                    arr.len -= 1;
                                    arr[arr.len] = s;
                                }
                                return arr;
                            },
                            else => LoaderError.TypeMismatch,
                        };
                    }

                    pub fn destroy(value: *T, alloc: Allocator) void {
                        for (value) |*item| {
                            ChildLoader.destroy(@constCast(item), alloc);
                        }
                        value.* = undefined;
                    }
                };
            },
            .pointer => |info| {
                const ChildLoader = Loader(info.child);
                switch (info.size) {
                    .slice => {
                        return struct {
                            pub const Type = T;

                            pub fn load(node: JSONNode, alloc: Allocator) !T {
                                return switch (node) {
                                    .array => |a| {
                                        var size = a.len;
                                        if (info.sentinel_ptr != null) size += 1;
                                        var arr = try alloc.alloc(info.child, size);
                                        errdefer alloc.free(arr);
                                        for (a, 0..) |item, i| {
                                            arr[i] = try ChildLoader.load(item, alloc);
                                        }
                                        if (info.sentinel()) |s| {
                                            arr.len -= 1;
                                            arr[arr.len] = s;
                                        }
                                        return arr;
                                    },
                                    .string => |a| {
                                        if (info.child != u8)
                                            return LoaderError.TypeMismatch;
                                        var size = a.len;
                                        if (info.sentinel_ptr != null) size += 1;
                                        var arr = try alloc.alloc(info.child, size);
                                        errdefer alloc.free(arr);
                                        @memcpy(arr[0..a.len], a);
                                        if (info.sentinel()) |s| {
                                            arr.len -= 1;
                                            arr[arr.len] = s;
                                        }
                                        return arr;
                                    },
                                    else => LoaderError.TypeMismatch,
                                };
                            }

                            pub fn destroy(value: *T, alloc: Allocator) void {
                                for (value.*) |*item| {
                                    ChildLoader.destroy(@constCast(item), alloc);
                                }
                                alloc.free(value.*);
                                value.* = undefined;
                            }
                        };
                    },
                    .one => {
                        return struct {
                            pub const Type = T;

                            pub fn load(node: JSONNode, alloc: Allocator) !T {
                                const obj = try alloc.create(info.child);
                                errdefer alloc.destroy(obj);
                                obj.* = try ChildLoader.load(node, alloc);
                                return obj;
                            }

                            pub fn destroy(value: *T, alloc: Allocator) void {
                                ChildLoader.destroy(value.*, alloc);
                                alloc.free(value.*);
                                value.* = undefined;
                            }
                        };
                    },
                    else => @compileError("Unhandled pointer type " ++ @typeName(T)),
                }
            },
            .@"struct" => |info| {
                var child_loaders: [info.fields.len]type = undefined;
                for (info.fields, 0..) |field, i| {
                    child_loaders[i] = Loader(field.type);
                }
                const ChildLoaders = child_loaders;

                return struct {
                    pub const Type = T;

                    pub fn load(node: JSONNode, alloc: Allocator) !T {
                        return switch (node) {
                            .object => |o| {
                                assert(o.len >= 1);
                                const class = o[0].class;
                                assert(o.len == class.names.len + 1);
                                const values = o[1..];
                                var obj: T = undefined;
                                inline for (info.fields, 0..) |field, i| {
                                    if (class.get(field.name)) |idx| {
                                        const value = try ChildLoaders[i].load(values[idx], alloc);
                                        @field(obj, field.name) = value;
                                    } else if (field.defaultValue()) |def| {
                                        // TODO what happens when we try to destroy
                                        // a constant?
                                        @field(obj, field.name) = def;
                                    } else if (@typeInfo(field.type) == .optional) {
                                        @field(obj, field.name) = null;
                                    } else {
                                        return LoaderError.MissingField;
                                    }
                                }

                                return obj;
                            },
                            else => LoaderError.TypeMismatch,
                        };
                    }

                    pub fn destroy(value: *T, alloc: Allocator) void {
                        inline for (info.fields, 0..) |field, i| {
                            const item = @field(value.*, field.name);
                            const optional = @typeInfo(field.type) == .optional;
                            if (!optional or item != null) {
                                ChildLoaders[i].destroy(@constCast(&item), alloc);
                            }
                        }
                        value.* = undefined;
                    }
                };
            },
            else => @compileError("Unhandled type " ++ @typeName(T)),
        }
    }
}

fn TestCase(
    comptime Type: type,
    comptime json_v: []const u8,
    comptime want_v: Type,
) type {
    comptime {
        return struct {
            pub const T = Type;
            pub const json = json_v;
            pub const want = want_v;
        };
    }
}

test Loader {
    const alloc = std.testing.allocator;
    var p = try JSONParser.init(alloc);
    defer p.deinit();

    const XY = struct { x: i32, y: i32 };
    const XYZ1 = struct { x: i32, y: i32, z: i32 = 0 };
    const XYZ2 = struct { x: i32, y: i32, z: ?i32 };
    const Info = struct { name: []const u8, tags: ?[]const []const u8 };

    const cases = .{
        TestCase(usize, "123", 123),
        TestCase(?usize, "null", null),
        TestCase([]const u8, "\"Hello\"", "Hello"),
        TestCase(
            [3]i32,
            "[1, -2, 3]",
            .{ 1, -2, 3 },
        ),
        TestCase(
            []const i32,
            "[1, -2, 3]",
            &[_]i32{ 1, -2, 3 },
        ),
        TestCase(
            XY,
            "{\"x\":100, \"y\":200}",
            .{ .x = 100, .y = 200 },
        ),
        TestCase(
            XYZ1,
            "{\"x\":100, \"y\":200}",
            .{ .x = 100, .y = 200, .z = 0 },
        ),
        TestCase(
            XYZ1,
            "{\"z\": 300, \"x\":100, \"y\":200}",
            .{ .x = 100, .y = 200, .z = 300 },
        ),
        TestCase(
            XYZ2,
            "{\"x\":100, \"y\":200}",
            .{ .x = 100, .y = 200, .z = null },
        ),
        TestCase(
            XYZ2,
            "{\"z\": 300, \"x\":100, \"y\":200}",
            .{ .x = 100, .y = 200, .z = 300 },
        ),
        TestCase(
            Info,
            "{\"name\":\"Andy\"}",
            .{ .name = "Andy", .tags = null },
        ),
        TestCase(
            Info,
            "{\"name\":\"Andy\", \"tags\":[\"zig\", \"zag\"]}",
            .{ .name = "Andy", .tags = &.{ "zig", "zag" } },
        ),
    };

    inline for (cases) |case| {
        const L = Loader(case.T);
        const node = try p.parseToAssembly(case.json);
        var got = try L.load(node, alloc);
        defer L.destroy(&got, alloc);
        try std.testing.expectEqualDeep(case.want, got);
    }
}

test {
    // const T = []u8;
    // @compileLog(@typeInfo(T));
}

const std = @import("std");
const assert = std.debug.assert;

const JSONNode = @import("./node.zig").JSONNode;
const JSONParser = @import("./parser.zig").JSONParser;
const Allocator = std.mem.Allocator;
