fn LitOp(comptime VT: anytype) type {
    return struct { value: VT };
}

fn BinOp(comptime NT: type, comptime oper: []const u8) type {
    return struct {
        pub const op = oper;
        lhs: *const NT,
        rhs: *const NT,
    };
}

const ImplLitFloat = struct {
    pub fn eval(node: *const LitFloat, ctx: anytype) anyerror!f64 {
        _ = ctx;
        return node.value;
    }
};

const ImplAddOp = struct {
    pub fn eval(node: *const AddOp, ctx: anytype) anyerror!f64 {
        return try node.lhs.eval(ctx) + try node.rhs.eval(ctx);
    }
};

const ImplMulOp = struct {
    pub fn eval(node: *const MulOp, ctx: anytype) anyerror!f64 {
        return try node.lhs.eval(ctx) * try node.rhs.eval(ctx);
    }
};

const LitInt = LitOp(i64);
const LitFloat = LitOp(f64);
const AddOp = BinOp(Node, "+");
const MulOp = BinOp(Node, "*");

const Node = union(enum) {
    // int: LiteralInt,
    float: LitFloat,
    add_op: AddOp,
    mul_op: MulOp,

    pub fn eval(self: *const Node, ctx: anytype) anyerror!f64 {
        var rv: f64 = undefined;
        try ctx.despatch("eval", self, .{}, &rv);
        return rv;
    }
};

const Type = std.builtin.Type;

fn Expr(comptime NT: type, comptime implementations: []const type) type {
    comptime {
        const node_info = @typeInfo(NT).@"union";
        var despatcher_fields: [node_info.fields.len]Type.StructField = undefined;
        var type_names: [node_info.fields.len][]const u8 = undefined;

        // Despatcher is a struct with a field for each node type
        // Each field is a struct with the appropriate impl for each method

        for (node_info.fields, 0..) |field, field_idx| {
            var method_fields: [node_info.decls.len]Type.StructField = undefined;
            // Loop over decls
            DECL: for (node_info.decls, 0..) |node_decl, node_decl_idx| {
                for (implementations) |impl| {
                    const impl_info = @typeInfo(impl).@"struct";
                    IMPL: for (impl_info.decls) |impl_decl| {
                        if (!std.mem.eql(u8, node_decl.name, impl_decl.name))
                            continue :IMPL;
                        const impl_fn = @field(impl, node_decl.name);
                        const impl_fn_info = @typeInfo(@TypeOf(impl_fn)).@"fn";
                        if (impl_fn_info.params.len < 1) continue :IMPL;
                        if (impl_fn_info.params[0].type) |ft| {
                            switch (@typeInfo(ft)) {
                                .pointer => |ptr| {
                                    if (ptr.child != field.type) continue :IMPL;

                                    const method_field = Type.StructField{
                                        .name = impl_decl.name,
                                        .type = @TypeOf(impl_fn),
                                        .default_value_ptr = impl_fn,
                                        .is_comptime = true,
                                        .alignment = @alignOf(@TypeOf(&impl_fn)),
                                    };

                                    method_fields[node_decl_idx] = method_field;
                                    continue :DECL;
                                },
                                else => continue :IMPL,
                            }
                        }
                    }
                }
                @compileError("No implementation for " ++ node_decl.name ++
                    " on " ++ @typeName(field.type));
            }

            const NodeVTable = @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &method_fields,
                .decls = &[_]Type.Declaration{},
                .is_tuple = false,
            } });

            despatcher_fields[field_idx] = Type.StructField{
                .name = field.name,
                .type = NodeVTable,
                .default_value_ptr = &NodeVTable{},
                .is_comptime = true,
                .alignment = @alignOf(@TypeOf(usize)),
            };

            type_names[field_idx] = field.name;
        }

        const Despatcher = @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &despatcher_fields,
            .decls = &[_]Type.Declaration{},
            .is_tuple = false,
        } });

        const despatcher = Despatcher{};
        const type_map = type_names;

        return struct {
            const Self = @This();

            pub fn despatch(
                self: Self,
                comptime method: []const u8,
                node: *const NT,
                params: anytype,
                rv: anytype,
            ) anyerror!void {
                const type_idx = @intFromEnum(node.*);
                switch (type_idx) {
                    inline 0...type_map.len - 1 => |idx| {
                        const type_name = type_map[idx];
                        const node_vtable = @field(despatcher, type_name);
                        const node_value = @field(node, type_name);
                        const impl_fn = @field(node_vtable, method);
                        rv.* = try @call(.auto, impl_fn, .{ &node_value, self } ++ params);
                    },
                    else => unreachable,
                }
            }
        };
    }
}

test Expr {
    // const node = Node{ .float = LiteralFloat{ .value = 3.14 } };
    const node = Node{ .add_op = AddOp{
        .lhs = &Node{ .mul_op = MulOp{
            .lhs = &Node{ .float = LitFloat{ .value = 1.3 } },
            .rhs = &Node{ .float = LitFloat{ .value = 2.1 } },
        } },
        .rhs = &Node{ .float = LitFloat{ .value = 7.0 } },
    } };

    const expr = Expr(Node, &.{
        ImplLitFloat,
        ImplAddOp,
        ImplMulOp,
    }){};

    const res = try node.eval(expr);
    try std.testing.expect(res == 1.3 * 2.1 + 7.0);
}

const std = @import("std");
