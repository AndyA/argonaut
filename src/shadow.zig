const OOM = error{OutOfMemory};

const IndexMap = std.StringHashMapUnmanaged(u32);

fn indexMapForNames(names: []const []const u8, alloc: std.mem.Allocator) OOM!IndexMap {
    var index: IndexMap = .empty;
    if (names.len > 0) {
        try index.ensureTotalCapacity(alloc, @intCast(names.len));
        for (names, 0..) |n, i| {
            index.putAssumeCapacity(n, @intCast(i));
        }
    }
    return index;
}

pub const SafeObjectClass = struct {
    const Self = @This();

    index_map: IndexMap = .empty,
    names: []const []const u8,
    buffer: []u8,

    pub fn initFromNames(alloc: std.mem.Allocator, unsafe_names: []const []const u8) !Self {
        var buf_size: usize = 0;
        for (unsafe_names) |n| {
            buf_size += try string.unescapedLength(n);
        }

        var buffer = try alloc.alloc(u8, buf_size);
        errdefer alloc.free(buffer);

        var names = try alloc.alloc([]const u8, unsafe_names.len);
        errdefer alloc.free(names);

        var buf_pos: usize = 0;
        for (unsafe_names, 0..) |n, i| {
            const enc_len = try string.unescapeToBuffer(n, buffer[buf_pos..]);
            const next_pos = buf_pos + enc_len;
            const name = buffer[buf_pos..next_pos];
            buf_pos = next_pos;
            names[i] = name;
        }

        return Self{
            .index_map = try indexMapForNames(names, alloc),
            .names = names,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.index_map.deinit(alloc);
        alloc.free(self.names);
        alloc.free(self.buffer);
        self.* = undefined;
    }

    pub fn get(self: Self, key: []const u8) ?u32 {
        return self.index_map.get(key);
    }
};

pub const ObjectClass = struct {
    const Self = @This();

    index_map: IndexMap = .empty,
    names: []const []const u8,
    safe: ?SafeObjectClass = null,

    pub fn initFromShadow(alloc: std.mem.Allocator, shadow: *const ShadowClass) !Self {
        const size = shadow.size();

        var names = try alloc.alloc([]const u8, size);
        errdefer alloc.free(names);

        var class = shadow;
        var is_safe = true;
        while (class.size() > 0) : (class = class.parent.?) {
            assert(class.index < size);
            names[class.index] = class.name;
            if (!string.isSafe(class.name)) is_safe = false;
        }

        var safe: ?SafeObjectClass = null;
        if (!is_safe) safe = try SafeObjectClass.initFromNames(alloc, names);

        return Self{
            .index_map = try indexMapForNames(names, alloc),
            .names = names,
            .safe = safe,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        if (self.safe) |*s| {
            s.deinit(alloc);
        }
        self.index_map.deinit(alloc);
        alloc.free(self.names);
        self.* = undefined;
    }

    pub fn get(self: Self, key: []const u8) ?u32 {
        if (self.safe) |s| {
            return s.get(key);
        }
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

    pub fn size(self: *const Self) u32 {
        return self.index +% 1;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        var iter = self.next.valueIterator();
        while (iter.next()) |v| {
            v.*.deinit(alloc);
        }
        if (self.object_class) |*class| {
            class.deinit(alloc);
        }
        self.next.deinit(alloc);
        if (self.size() > 0) {
            alloc.free(self.name);
            alloc.destroy(self);
        } else {
            self.* = undefined;
        }
    }

    pub fn getNext(self: *Self, alloc: std.mem.Allocator, name: []const u8) OOM!*Self {
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
        return slot.value_ptr.*;
    }

    pub fn getClass(self: *Self, alloc: std.mem.Allocator) !*const ObjectClass {
        if (self.object_class == null)
            self.object_class = try ObjectClass.initFromShadow(alloc, self);

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
const string = @import("string.zig");
