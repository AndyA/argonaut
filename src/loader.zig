pub const LoaderError = error{
    TypeMismatch,
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
                            .array => |a| {
                                var size = a.len;
                                if (info.sentinel_ptr != null) size += 1;
                                var arr = alloc.alloc(T, size);
                                errdefer alloc.free(arr);
                                for (a, 0..) |item, i| {
                                    arr[i] = try ChildLoader.load(item, alloc);
                                }
                                if (info.sentinel()) |s| {
                                    arr[arr.len - 1] = s;
                                }
                                return arr;
                            },
                            .string => |s| str: {
                                if (info.child != u8)
                                    break :str LoaderError.TypeMismatch;
                                _ = s;
                            },
                            else => LoaderError.TypeMismatch,
                        };
                    }

                    pub fn destroy(value: *T, alloc: Allocator) void {
                        for (value) |item| {
                            ChildLoader.destroy(item, alloc);
                        }
                        alloc.free(value);
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

    const cases = .{
        TestCase(usize, "123", 123),
        TestCase(?usize, "null", null),
    };

    inline for (cases) |case| {
        const L = Loader(case.T);
        const node = try p.parseToAssembly(case.json);
        var got = try L.load(node, alloc);
        defer L.destroy(&got, alloc);
        try std.testing.expectEqualDeep(case.want, got);
    }
}

const std = @import("std");
const JSONNode = @import("./node.zig").JSONNode;
const JSONParser = @import("./parser.zig").JSONParser;
const Allocator = std.mem.Allocator;
