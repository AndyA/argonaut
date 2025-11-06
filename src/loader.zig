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
                pub fn load(node: Node, gpa: Allocator) !T {
                    return switch (node) {
                        .null => null,
                        else => try ChildLoader.load(node, gpa),
                    };
                }
            };
        },
        .bool => {
            return struct {
                pub fn load(node: Node, _: Allocator) !T {
                    return switch (node) {
                        .boolean => |b| b,
                        else => LoaderError.TypeMismatch,
                    };
                }
            };
        },
        .int => {
            return struct {
                pub fn load(node: Node, _: Allocator) !T {
                    return switch (node) {
                        .number, .safe_string, .json_string, .wild_string => |n| blk: {
                            break :blk try std.fmt.parseInt(T, n, 10);
                        },
                        else => LoaderError.TypeMismatch,
                    };
                }
            };
        },
        .float => {
            return struct {
                pub fn load(node: Node, _: Allocator) !T {
                    return switch (node) {
                        .number, .safe_string, .json_string, .wild_string => |n| blk: {
                            break :blk std.fmt.parseFloat(T, n);
                        },
                        else => LoaderError.TypeMismatch,
                    };
                }
            };
        },
        .array => |info| {
            const ChildLoader = Loader(info.child);
            return struct {
                pub fn load(node: Node, gpa: Allocator) !T {
                    switch (node) {
                        .array, .multi => |a| {
                            var size = a.len;
                            if (a.len != info.len)
                                return LoaderError.ArraySizeMismatch;
                            if (info.sentinel_ptr != null) size += 1;
                            var arr: T = undefined;
                            for (a, 0..) |item, i| {
                                arr[i] = try ChildLoader.load(item, gpa);
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
                        pub fn load(node: Node, gpa: Allocator) !T {
                            switch (node) {
                                .array, .multi => |a| {
                                    var size = a.len;
                                    if (info.sentinel_ptr != null) size += 1;
                                    var arr = try gpa.alloc(info.child, size);
                                    errdefer gpa.free(arr);
                                    for (a, 0..) |item, i| {
                                        arr[i] = try ChildLoader.load(item, gpa);
                                    }
                                    if (info.sentinel()) |s| {
                                        arr.len -= 1;
                                        arr[arr.len] = s;
                                    }
                                    return arr;
                                },
                                .json_string, .safe_string, .wild_string => |str| {
                                    if (info.child != u8)
                                        return LoaderError.TypeMismatch;

                                    const size = str.len;
                                    const adj = if (info.sentinel_ptr == null) 0 else 1;

                                    var out: []u8 = undefined;

                                    switch (node) {
                                        .json_string => {
                                            const out_len = try string.unescapedLength(str);
                                            out = try gpa.alloc(u8, out_len + adj);
                                            _ = string.unescapeToBuffer(str, out) catch unreachable;
                                        },
                                        .safe_string, .wild_string => {
                                            out = try gpa.alloc(u8, size + adj);
                                            @memcpy(out[0..str.len], str);
                                        },
                                        else => unreachable,
                                    }

                                    if (info.sentinel()) |s| {
                                        out.len -= 1;
                                        out[out.len] = s;
                                    }

                                    return out;
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
                        pub fn load(node: Node, gpa: Allocator) !T {
                            const obj = try gpa.create(info.child);
                            errdefer gpa.destroy(obj);
                            obj.* = try ChildLoader.load(node, gpa);
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
                pub fn load(node: Node, gpa: Allocator) !T {
                    switch (node) {
                        .object => {
                            const class = node.objectClass();
                            const values = node.objectSlice();
                            var obj: T = undefined;
                            inline for (info.fields, ChildLoaders) |field, CL| {
                                if (class.get(field.name)) |idx| {
                                    const value = try CL.load(values[idx], gpa);
                                    @field(obj, field.name) = value;
                                } else if (field.defaultValue()) |def| {
                                    @field(obj, field.name) = def;
                                } else if (@typeInfo(field.type) == .optional) {
                                    @field(obj, field.name) = null;
                                } else {
                                    std.debug.print(
                                        "Missing field {s} in {f}\n",
                                        .{ field.name, node },
                                    );
                                    return LoaderError.MissingField;
                                }
                            }

                            return obj;
                        },
                        .array => |a| {
                            if (a.len < min_tuple_len or a.len > info.fields.len)
                                return LoaderError.TupleSizeMismatch;
                            var obj: T = undefined;
                            inline for (info.fields, ChildLoaders, 0..) |field, CL, i| {
                                if (i < a.len) {
                                    const value = try CL.load(a[i], gpa);
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
                pub fn load(node: Node, gpa: Allocator) !T {
                    const tag = try switch (node) {
                        .json_string => |str| blk: {
                            const out = try string.unescapeAlloc(str, gpa);
                            defer gpa.free(out);
                            break :blk map.get(out);
                        },
                        .safe_string, .wild_string => |str| map.get(str),
                        else => LoaderError.TypeMismatch,
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
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();

    const XY = struct { x: i32, y: i32 };
    const XYZdefault = struct { x: i32, y: i32, z: i32 = 0 };
    const XYZoptional = struct { x: i32, y: i32, z: ?i32 };
    const Info = struct { name: []const u8, tags: ?[]const []const u8 };
    const DefStr = struct { name: []const u8 = "Me!" };
    const InfoDot = struct { info: Info, pt: XYZoptional, name: DefStr };
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
        const gpa = arena.allocator();

        const node = try p.parse(case.json);
        const got = try Loader(case.T).load(node, gpa);

        try std.testing.expectEqualDeep(case.want, got);
    }
}

const std = @import("std");
const assert = std.debug.assert;
const StaticStringMap = std.static_string_map.StaticStringMap;
const Allocator = std.mem.Allocator;

const Node = @import("./node.zig").Node;
const Parser = @import("./parser.zig");
const string = @import("./string.zig");
