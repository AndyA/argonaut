pub const LoaderError = error{
    TypeMismatch,
    ArraySizeMismatch,
    TupleSizeMismatch,
    MissingField,
    UnknownEnumValue,
};

fn isOptional(field: std.builtin.Type.StructField) bool {
    return field.default_value_ptr != null or @typeInfo(field.type) == .optional;
}

pub fn Loader(comptime T: type) type {
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
            };
        },
        .bool => {
            return struct {
                pub const Type = T;

                pub fn load(node: JSONNode, _: Allocator) !T {
                    return switch (node) {
                        .boolean => |b| b,
                        else => LoaderError.TypeMismatch,
                    };
                }
            };
        },
        .int => {
            return struct {
                pub const Type = T;

                pub fn load(node: JSONNode, _: Allocator) !T {
                    return switch (node) {
                        .number, .safe_string, .string => |n| std.fmt.parseInt(T, n, 10) catch |err| {
                            std.debug.print("{s}: \"{s}\"\n", .{ @errorName(err), n });
                            return err;
                        },
                        else => LoaderError.TypeMismatch,
                    };
                }
            };
        },
        .float => {
            return struct {
                pub const Type = T;

                pub fn load(node: JSONNode, _: Allocator) !T {
                    return switch (node) {
                        .number, .safe_string, .string => |n| std.fmt.parseFloat(T, n),
                        else => LoaderError.TypeMismatch,
                    };
                }
            };
        },
        .array => |info| {
            const ChildLoader = Loader(info.child);
            return struct {
                pub const Type = T;

                pub fn load(node: JSONNode, alloc: Allocator) !T {
                    switch (node) {
                        .array, .multi => |a| {
                            var size = a.len;
                            if (a.len != info.len)
                                return LoaderError.ArraySizeMismatch;
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
                        else => {
                            return LoaderError.TypeMismatch;
                        },
                    }
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
                            switch (node) {
                                .array, .multi => |a| {
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
                                .string, .safe_string => |str| {
                                    if (info.child != u8)
                                        return LoaderError.TypeMismatch;

                                    const size = str.len;
                                    const adj = if (info.sentinel_ptr == null) 0 else 1;

                                    var arr: []u8 = undefined;

                                    switch (node) {
                                        .string => {
                                            const enc_len = try string.unescapedLength(str);
                                            arr = try alloc.alloc(u8, enc_len + adj);
                                            errdefer alloc.free(arr);
                                            _ = try string.unescapeToBuffer(str, arr);
                                        },
                                        .safe_string => {
                                            arr = try alloc.alloc(u8, size + adj);
                                            @memcpy(arr[0..str.len], str);
                                        },
                                        else => unreachable,
                                    }

                                    if (info.sentinel()) |s| {
                                        arr.len -= 1;
                                        arr[arr.len] = s;
                                    }

                                    return arr;
                                },
                                else => {
                                    return LoaderError.TypeMismatch;
                                },
                            }
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
                    };
                },
                else => @compileError("Unhandled pointer type " ++ @typeName(T)),
            }
        },
        .@"struct" => |info| {
            var child_loaders: [info.fields.len]type = undefined;
            var required_len: usize = 0;
            for (info.fields, 0..) |field, i| {
                child_loaders[i] = Loader(field.type);
                if (!isOptional(field))
                    required_len = i + 1;
            }
            const ChildLoaders = child_loaders;
            const min_tuple_len = required_len;

            return struct {
                pub const Type = T;

                pub fn load(node: JSONNode, alloc: Allocator) !T {
                    switch (node) {
                        .object => |o| {
                            assert(o.len >= 1);
                            assert(o[0] == .class);
                            const class = o[0].class;
                            assert(o.len == class.names.len + 1);
                            const values = o[1..];
                            var obj: T = undefined;
                            inline for (info.fields, 0..) |field, i| {
                                if (class.get(field.name)) |idx| {
                                    const value = try ChildLoaders[i].load(values[idx], alloc);
                                    @field(obj, field.name) = value;
                                } else if (field.defaultValue()) |def| {
                                    @field(obj, field.name) = def;
                                } else if (@typeInfo(field.type) == .optional) {
                                    @field(obj, field.name) = null;
                                } else {
                                    std.debug.print("Missing field {s} in {f}\n", .{ field.name, node });
                                    return LoaderError.MissingField;
                                }
                            }

                            return obj;
                        },
                        .array => |a| {
                            if (a.len < min_tuple_len or a.len > info.fields.len)
                                return LoaderError.TupleSizeMismatch;
                            var obj: T = undefined;
                            inline for (info.fields, 0..) |field, i| {
                                if (i < a.len) {
                                    const value = try ChildLoaders[i].load(a[i], alloc);
                                    @field(obj, field.name) = value;
                                } else if (field.defaultValue()) |def| {
                                    @field(obj, field.name) = def;
                                } else if (@typeInfo(field.type) == .optional) {
                                    @field(obj, field.name) = null;
                                } else unreachable;
                            }
                            return obj;
                        },
                        else => {
                            return LoaderError.TypeMismatch;
                        },
                    }
                }
            };
        },
        .@"enum" => |info| {
            var kv: [info.fields.len]struct { []const u8, info.tag_type } = undefined;
            for (info.fields, 0..) |field, i| {
                kv[i] = .{ field.name, @intCast(field.value) };
            }
            const map = StaticStringMap(info.tag_type).initComptime(kv);
            return struct {
                pub const Type = T;

                pub fn load(node: JSONNode, alloc: Allocator) !T {
                    const tag = switch (node) {
                        .string => |str| blk: {
                            const enc_len = try string.unescapedLength(str);
                            const arr = try alloc.alloc(u8, enc_len);
                            defer alloc.free(arr);
                            _ = try string.unescapeToBuffer(str, arr);
                            break :blk map.get(arr);
                        },
                        .safe_string => |str| map.get(str),
                        else => {
                            return LoaderError.TypeMismatch;
                        },
                    };
                    if (tag) |t| return @enumFromInt(t);
                    return LoaderError.UnknownEnumValue;
                }
            };
        },
        else => @compileError("Unhandled type " ++ @typeName(T)),
    }
}

fn tc(
    comptime Type: type,
    comptime json_v: []const u8,
    comptime want_v: Type,
) type {
    return struct {
        pub const T = Type;
        pub const json = json_v;
        pub const want = want_v;
    };
}

test Loader {
    var p = try JSONParser.init(std.testing.allocator);
    defer p.deinit();

    const XY = struct { x: i32, y: i32 };
    const XYZdefault = struct { x: i32, y: i32, z: i32 = 0 };
    const XYZoptional = struct { x: i32, y: i32, z: ?i32 };
    const Info = struct { name: []const u8, tags: ?[]const []const u8 };
    const DefStr = struct { name: []const u8 = "Me!" };
    const InfoDot = struct {
        info: Info,
        pt: XYZoptional,
        name: DefStr,
    };

    const SizeEnum = enum { S, M, L, XL, XXL };
    const EscapeEnum = enum { @"\n", @"\t", @"\r" };
    const SnackTuple = struct { []const u8, u32, ?[]const []const u8 };

    const cases = .{
        tc(usize, "123", 123),
        tc(usize, "\"123\"", 123),
        tc(?usize, "null", null),
        tc(?usize, "123", 123),

        tc([]const u8,
            \\"Hello"
        , "Hello"),

        tc([]const u8,
            \\"Hello\n"
        , "Hello\n"),
        tc(
            [3]i32,
            \\[1, -2, 3]
        ,
            .{ 1, -2, 3 },
        ),
        tc(
            []const i32,
            \\[1, -2, 3]
        ,
            &[_]i32{ 1, -2, 3 },
        ),
        tc(
            []const u8,
            \\[1, 2, 3]
        ,
            &[_]u8{ 1, 2, 3 },
        ),
        tc(
            XY,
            \\{"x":100, "y":200}
        ,
            .{ .x = 100, .y = 200 },
        ),
        tc(
            XYZdefault,
            \\{"x": 100, "y": 200}
        ,
            .{ .x = 100, .y = 200, .z = 0 },
        ),
        tc(
            XYZdefault,
            \\{"z": 300, "x": 100, "y": 200}
        ,
            .{ .x = 100, .y = 200, .z = 300 },
        ),
        tc(
            XYZoptional,
            \\{"x": 100, "y": 200}
        ,
            .{ .x = 100, .y = 200, .z = null },
        ),
        tc(
            XYZoptional,
            \\{"z": 300, "x": 100, "y": 200}
        ,
            .{ .x = 100, .y = 200, .z = 300 },
        ),
        tc(
            Info,
            \\{"name": "Andy"}
        ,
            .{ .name = "Andy", .tags = null },
        ),
        tc(
            Info,
            \\{"name": "Andy", "tags" :["zig", "zag"]}
        ,
            .{ .name = "Andy", .tags = &.{ "zig", "zag" } },
        ),
        tc(
            struct { @"\n": bool },
            \\{"\n": true}
        ,
            .{ .@"\n" = true },
        ),
        tc(DefStr,
            \\{}
        , .{ .name = "Me!" }),
        tc(DefStr,
            \\{ "ignored": true }
        , .{ .name = "Me!" }),
        tc(
            InfoDot,
            \\{
            \\  "pt": {"x": 100, "y": 200},
            \\  "info": {"name": "Andy", "tags": ["zig", "zag"]},
            \\  "name": {}
            \\}
        ,
            .{
                .info = .{ .name = "Andy", .tags = &.{ "zig", "zag" } },
                .pt = .{ .x = 100, .y = 200, .z = null },
                .name = .{ .name = "Me!" },
            },
        ),
        tc(SizeEnum,
            \\"S"
        , .S),
        tc([]const SizeEnum,
            \\["S", "M", "XXL"]
        , &[_]SizeEnum{ .S, .M, .XXL }),
        tc(EscapeEnum,
            \\"\n"
        , .@"\n"),
        tc([]const EscapeEnum,
            \\["\n", "\t", "\r"]
        , &[_]EscapeEnum{ .@"\n", .@"\t", .@"\r" }),
        tc(SnackTuple,
            \\["pies", 3]
        , .{ "pies", 3, null }),
        tc(SnackTuple,
            \\["pies", 3, ["meat", "tattie"]]
        , .{ "pies", 3, &.{ "meat", "tattie" } }),
    };

    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const node = try p.parse(case.json);
        const got = try Loader(case.T).load(node, alloc);

        try std.testing.expectEqualDeep(case.want, got);
    }
}

test {
    // const T = []u8;
    // @compileLog(@typeInfo(T));
}

const std = @import("std");
const assert = std.debug.assert;
const StaticStringMap = std.static_string_map.StaticStringMap;
const Allocator = std.mem.Allocator;

const JSONNode = @import("./node.zig").JSONNode;
const JSONParser = @import("./parser.zig").JSONParser;
const string = @import("./string.zig");
