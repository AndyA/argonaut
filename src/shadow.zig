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

pub fn ObjectClass(comptime Context: type) type {
    return struct {
        const Self = @This();
        const SC = ShadowClass(Context);

        index_map: IndexMap = .empty,
        names: []const []const u8,
        safe_names: ?[]const []const u8,
        context: Context,

        pub fn initFromShadow(alloc: Allocator, shadow: *const SC) !Self {
            const size = shadow.size();

            var names = try alloc.alloc([]const u8, size);
            errdefer alloc.free(names);

            var class = shadow;
            var unsafe = false;
            while (class.size() > 0) : (class = class.parent.?) {
                assert(class.index < size);
                names[class.index] = class.name;
                if (!string.isEscaped(class.name)) unsafe = true;
            }

            const safe_names: ?[]const []const u8 = if (unsafe) blk: {
                var safe = try alloc.alloc([]const u8, names.len);
                for (names, 0..) |n, i| {
                    const out = try string.unescapeAlloc(n, alloc);
                    errdefer alloc.free(out);
                    safe[i] = out;
                }
                break :blk safe;
            } else null;

            const self = Self{
                .index_map = try indexMapForNames(alloc, safe_names orelse names),
                .names = names,
                .safe_names = safe_names,
                .context = if (@typeInfo(Context) == .void) {} else Context{},
            };

            if (@typeInfo(Context) != .void and @hasDecl(Context, "init"))
                try self.context.init(alloc);

            return self;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (@typeInfo(Context) != .void and @hasDecl(Context, "deinit"))
                self.context.deinit(alloc);

            if (self.safe_names) |safe| {
                for (safe) |s| alloc.free(s);
                alloc.free(safe);
            }
            self.index_map.deinit(alloc);
            alloc.free(self.names);
            self.* = undefined;
        }

        pub fn keys(self: Self) []const []const u8 {
            return self.safe_names orelse self.names;
        }

        pub fn get(self: Self, key: []const u8) ?u32 {
            return self.index_map.get(key);
        }
    };
}

pub fn ShadowClass(comptime Context: type) type {
    return struct {
        const Self = @This();
        pub const NextMap = std.StringHashMapUnmanaged(*Self);
        pub const OC = ObjectClass(Context);
        pub const RootIndex = std.math.maxInt(u32);
        const ctx = std.hash_map.StringContext{};

        parent: ?*const Self = null,
        object_class: ?OC = null,
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

        pub fn getClass(self: *Self, alloc: Allocator) !*const OC {
            if (self.object_class == null)
                self.object_class = try OC.initFromShadow(alloc, self);

            return &self.object_class.?;
        }
    };
}

test ShadowClass {
    const SC = ShadowClass(void);
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
