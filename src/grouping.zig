pub const Entity = packed struct(u32) {
    isRoot: bool = false,
    isGroup: bool = false,
    isResource: bool = false,
    isFolder: bool = false,
};
