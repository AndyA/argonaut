const OOM = error{OutOfMemory};

const IndexMap = std.StringHashMapUnmanaged(u32);

fn indexMapForNames(alloc: Allocator, names: []const []const u8) OOM!IndexMap {
    var index: IndexMap = .empty;
    if (names.len > 0) {
        try index.ensureTotalCapacity(alloc, @intCast(names.len));
        for (names, 0..) |n, i| {
            index.putAssumeCapacity(n, @intCast(i));
        }
    }
    return index;
}

pub const ObjectClass = struct {
    const Self = @This();

    index_map: IndexMap = .empty,
    names: []const []const u8,
    unescaped_names: []const []const u8,

    pub fn initFromShadow(alloc: Allocator, shadow: *const ShadowClass) !Self {
        const size = shadow.size();

        var names = try alloc.alloc([]const u8, size);
        errdefer alloc.free(names);
        var unescaped_names = try alloc.alloc([]const u8, names.len);
        errdefer alloc.free(unescaped_names);

        var class = shadow;
        while (class.size() > 0) : (class = class.parent.?) {
            assert(class.index < size);
            names[class.index] = class.name;
            unescaped_names[class.index] = try string.unescapeAlloc(class.name, alloc);
        }

        const self = Self{
            .index_map = try indexMapForNames(alloc, unescaped_names),
            .names = names,
            .unescaped_names = unescaped_names,
        };

        return self;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.unescaped_names) |s| alloc.free(s);
        alloc.free(self.unescaped_names);
        self.index_map.deinit(alloc);
        alloc.free(self.names);
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
    name: []const u8 = "$",
    next: NextMap = .empty,
    index: u32 = RootIndex,
    usage: usize = 0,

    pub fn size(self: *const Self) u32 {
        return self.index +% 1;
    }

    fn deinitContents(self: *Self, alloc: Allocator) void {
        var iter = self.next.valueIterator();
        while (iter.next()) |v| v.*.deinitNonRoot(alloc);
        if (self.object_class) |*class| class.deinit(alloc);
        self.next.deinit(alloc);
    }

    fn deinitNonRoot(self: *Self, alloc: Allocator) void {
        self.deinitContents(alloc);
        alloc.free(self.name);
        alloc.destroy(self);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        assert(self.size() == 0); // Must be root
        self.deinitContents(alloc);
        self.* = undefined;
    }

    pub fn startWalk(self: *Self) *Self {
        self.usage +|= 1;
        return self;
    }

    pub fn getNext(self: *Self, alloc: Allocator, name: []const u8) OOM!*Self {
        const slot = try self.next.getOrPutContextAdapted(alloc, name, ctx, ctx);
        if (!slot.found_existing) {
            const key_name = try alloc.dupe(u8, name);
            const next = try alloc.create(Self);
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

    pub fn getClass(self: *Self, alloc: Allocator) !*const ObjectClass {
        if (self.object_class == null)
            self.object_class = try ObjectClass.initFromShadow(alloc, self);

        return &self.object_class.?;
    }
};

test ShadowClass {
    const SC = ShadowClass;
    const alloc = std.testing.allocator;
    var root = SC{};
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
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const string = @import("string.zig");
