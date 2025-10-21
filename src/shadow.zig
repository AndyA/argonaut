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

const std = @import("std");
const assert = std.debug.assert;
