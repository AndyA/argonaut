pub const PathNode = union(enum) {
    key: []const u8, // foo
    index: u32, // [3]
    wild, // [*]
    search, // ..
};
