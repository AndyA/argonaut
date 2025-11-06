const OOM = error{OutOfMemory};

const IndexMap = std.StringHashMapUnmanaged(u32);

fn indexMapForNames(gpa: Allocator, names: []const []const u8) OOM!IndexMap {
    var index: IndexMap = .empty;
    if (names.len > 0) {
        try index.ensureTotalCapacity(gpa, @intCast(names.len));
        for (names, 0..) |n, i|
            index.putAssumeCapacity(n, @intCast(i));
    }
    return index;
}

pub const ObjectClass = struct {
    const Self = @This();

    index_map: IndexMap = .empty,
    names: []const []const u8,
    unescaped_names: []const []const u8,

    pub fn initFromShadow(gpa: Allocator, shadow: *const ShadowClass) !Self {
        const size = shadow.size();

        var names = try gpa.alloc([]const u8, size);
        errdefer gpa.free(names);
        var unescaped_names = try gpa.alloc([]const u8, names.len);
        errdefer gpa.free(unescaped_names);

        var class = shadow;
        while (class.size() > 0) : (class = class.parent.?) {
            assert(class.index < size);
            names[class.index] = class.name;
            unescaped_names[class.index] = try string.unescapeAlloc(class.name, gpa);
        }

        const self = Self{
            .index_map = try indexMapForNames(gpa, unescaped_names),
            .names = names,
            .unescaped_names = unescaped_names,
        };

        return self;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        for (self.unescaped_names) |s| gpa.free(s);
        gpa.free(self.unescaped_names);
        self.index_map.deinit(gpa);
        gpa.free(self.names);
        self.* = undefined;
    }

    pub fn get(self: Self, key: []const u8) ?u32 {
        return self.index_map.get(key);
    }
};

pub const ShadowClass = struct {
    const Self = @This();
    pub const NextMap = std.StringHashMapUnmanaged(*Self);
    pub const RootIndex = std.math.maxInt(u32);
    const ctx = std.hash_map.StringContext{};

    parent: ?*const Self = null,
    object_class: ?ObjectClass = null,
    name: []const u8 = "$", // not normally referred to
    next: NextMap = .empty,
    index: u32 = RootIndex,
    usage: usize = 0,

    pub fn size(self: *const Self) u32 {
        return self.index +% 1;
    }

    fn deinitContents(self: *Self, gpa: Allocator) void {
        var iter = self.next.valueIterator();
        while (iter.next()) |v| v.*.deinitNonRoot(gpa);
        if (self.object_class) |*class| class.deinit(gpa);
        self.next.deinit(gpa);
    }

    fn deinitNonRoot(self: *Self, gpa: Allocator) void {
        self.deinitContents(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        assert(self.size() == 0); // Must be root
        self.deinitContents(gpa);
        self.* = undefined;
    }

    pub fn startWalk(self: *Self) *Self {
        self.usage +|= 1;
        return self;
    }

    pub fn getNext(self: *Self, gpa: Allocator, name: []const u8) OOM!*Self {
        const slot = try self.next.getOrPutContextAdapted(gpa, name, ctx, ctx);
        if (!slot.found_existing) {
            const key_name = try gpa.dupe(u8, name);
            const next = try gpa.create(Self);
            next.* = .{
                .parent = self,
                .name = key_name,
                .index = self.size(),
            };
            slot.key_ptr.* = key_name;
            slot.value_ptr.* = next;
        }
        return slot.value_ptr.*.startWalk();
    }

    pub fn getClass(self: *Self, gpa: Allocator) !*const ObjectClass {
        if (self.object_class == null)
            self.object_class = try ObjectClass.initFromShadow(gpa, self);

        return &self.object_class.?;
    }
};

test ShadowClass {
    const SC = ShadowClass;
    const gpa = std.testing.allocator;
    var root = SC{};
    defer root.deinit(gpa);

    try std.testing.expectEqual(root.name, "$");

    var foo1 = try root.getNext(gpa, "foo");
    try std.testing.expectEqual(foo1.index, 0);
    try std.testing.expectEqual(foo1.parent, &root);

    var bar1 = try foo1.getNext(gpa, "bar");
    try std.testing.expectEqual(bar1.index, 1);
    try std.testing.expectEqual(bar1.parent, foo1);

    var foo2 = try root.getNext(gpa, "foo");
    try std.testing.expectEqual(foo1, foo2);
    var bar2 = try foo2.getNext(gpa, "bar");
    try std.testing.expectEqual(bar1, bar2);

    const cls1 = try bar1.getClass(gpa);
    const cls2 = try bar2.getClass(gpa);

    try std.testing.expectEqual(cls1, cls2);

    const empty = try root.getClass(gpa);
    try std.testing.expectEqualDeep(0, empty.names.len);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const string = @import("string.zig");
