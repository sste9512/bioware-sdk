//! Bioware Aurora ITP (Palette) file reader and writer.
//!
//! ITP files use GFF (FileType "ITP ") and describe palette tree structures
//! used by the toolset and DM Client.  Three palette varieties share this
//! format: skeleton blueprint palettes (*pal.itp), standard/custom blueprint
//! palettes (*palstd.itp / *palcus.itp), and tileset palettes.
//!
//! The tree has three node kinds, discriminated at parse time by field presence:
//!   Branch    — no RESREF, no ID; may have LIST children (branches/categories)
//!   Category  — has ID byte; may have LIST children (blueprint/leaf nodes)
//!   Blueprint — has RESREF; leaf node (tileset "leaf" nodes also map here)
//!
//! Memory model: ItpFile owns an internal ArenaAllocator that backs every
//! string, slice, and node array.  Call deinit() once to free everything.
const std = @import("std");
const gff = @import("gff.zig");

pub const FILE_TYPE = "ITP ";

pub const Error = error{
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

// ============================================================================
// Node structs
// ============================================================================

/// Non-leaf node that groups categories or other branches.
pub const BranchNode = struct {
    /// STRREF DWORD — TLK index for display text; 0xFFFFFFFF = absent.
    str_ref: u32 = 0xFFFF_FFFF,
    /// NAME CExoString — inline display text (standard palette; mutually
    /// exclusive with str_ref in practice, but both are preserved).
    name: []u8 = &.{},
    /// DELETE_ME CExoString — convenience label (skeleton palette only).
    delete_me: []u8 = &.{},
    /// TYPE BYTE — display filter (0=if_not_empty, 1=never, 2=custom).
    /// null means the TYPE field is absent in the GFF struct.
    display_type: ?u8 = null,
    /// LIST — child Branch or Category nodes.
    children: []PaletteNode = &.{},
};

/// Palette category; identified by a numeric ID used when assigning blueprints.
pub const CategoryNode = struct {
    /// ID BYTE — palette node ID.
    id: u8 = 0,
    str_ref: u32 = 0xFFFF_FFFF,
    name: []u8 = &.{},
    delete_me: []u8 = &.{},
    display_type: ?u8 = null,
    /// LIST — child Blueprint (or leaf) nodes.
    children: []PaletteNode = &.{},
};

/// Blueprint leaf; also covers tileset leaf nodes.
pub const BlueprintNode = struct {
    str_ref: u32 = 0xFFFF_FFFF,
    name: []u8 = &.{},
    /// RESREF CResRef — the blueprint or tile resource reference.
    res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// CR FLOAT — challenge rating (creature blueprints only).
    cr: ?f32 = null,
    /// FACTION CExoString — faction name (creature blueprints only).
    faction: []u8 = &.{},
};

/// Recursive palette tree node.
pub const PaletteNode = union(enum) {
    branch: BranchNode,
    category: CategoryNode,
    blueprint: BlueprintNode,
};

// ============================================================================
// ItpFile
// ============================================================================

pub const ItpFile = struct {
    arena: std.heap.ArenaAllocator,

    /// GFF struct type_id used for all nodes in the MAIN list and their
    /// descendants.  0 = standard/custom blueprint palette; 1 = skeleton or
    /// tileset palette.
    node_struct_id: u32 = 1,

    /// NEXT_USEABLE_ID BYTE — present in skeleton palettes only.
    next_useable_id: ?u8 = null,
    /// RESTYPE WORD — present in skeleton palettes only.
    res_type: ?u16 = null,
    /// TILESETRESREF CResRef — present in skeleton tileset palettes only.
    tileset_res_ref: ?gff.ResRef = null,

    /// MAIN — top-level palette tree.
    nodes: []PaletteNode = &.{},

    pub fn init(parent_alloc: std.mem.Allocator) ItpFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *ItpFile) void {
        self.arena.deinit();
    }

    // ------------------------------------------------------------------ Parse

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!ItpFile {
        var self = ItpFile.init(parent_alloc);
        errdefer self.deinit();

        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        const a = self.arena.allocator();
        const tl = &g.structs.items[0];

        // Optional top-level fields.
        if (g.getField(tl, "NEXT_USEABLE_ID")) |f| switch (f.value) {
            .byte => |v| self.next_useable_id = v,
            else => return error.WrongFieldType,
        };
        if (g.getField(tl, "RESTYPE")) |f| switch (f.value) {
            .word => |v| self.res_type = v,
            else => return error.WrongFieldType,
        };
        if (g.getField(tl, "TILESETRESREF")) |f| switch (f.value) {
            .res_ref => |v| self.tileset_res_ref = v,
            else => return error.WrongFieldType,
        };

        // MAIN list.
        const mf = g.getField(tl, "MAIN") orelse return self;
        const handles = switch (mf.value) {
            .list => |v| v,
            else => return error.WrongFieldType,
        };
        if (handles.len == 0) return self;

        // Determine struct_id from first list element.
        if (handles[0] < g.structs.items.len)
            self.node_struct_id = g.structs.items[handles[0]].type_id;

        const nodes = try a.alloc(PaletteNode, handles.len);
        for (handles, 0..) |h, i| {
            if (h >= g.structs.items.len) return error.InvalidFormat;
            nodes[i] = try parseNode(a, &g, &g.structs.items[h]);
        }
        self.nodes = nodes;
        return self;
    }

    // --------------------------------------------------------------- Serialize

    pub fn serialize(self: *const ItpFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();

        if (self.next_useable_id) |v|
            try g.addFieldToStruct(0, "NEXT_USEABLE_ID", .{ .byte = v });
        if (self.res_type) |v|
            try g.addFieldToStruct(0, "RESTYPE", .{ .word = v });
        if (self.tileset_res_ref) |v|
            try g.addFieldToStruct(0, "TILESETRESREF", .{ .res_ref = v });

        const handles = try alloc.alloc(u32, self.nodes.len);
        for (self.nodes, 0..) |*node, i|
            handles[i] = try serializeNode(alloc, &g, node, self.node_struct_id);
        try g.addFieldToStruct(0, "MAIN", .{ .list = handles });

        return g.serialize(alloc);
    }

    /// Returns the arena allocator for building nodes programmatically.
    pub fn allocator(self: *ItpFile) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ============================================================================
// Parse helpers
// ============================================================================

fn parseNode(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!PaletteNode {
    if (g.getField(s, "RESREF") != null)
        return .{ .blueprint = try parseBlueprintNode(a, g, s) };
    if (g.getField(s, "ID") != null)
        return .{ .category = try parseCategoryNode(a, g, s) };
    return .{ .branch = try parseBranchNode(a, g, s) };
}

fn parseBranchNode(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!BranchNode {
    return .{
        .str_ref = (try rdDword(g, s, "STRREF")) orelse 0xFFFF_FFFF,
        .name = try rdStringDupe(a, g, s, "NAME"),
        .delete_me = try rdStringDupe(a, g, s, "DELETE_ME"),
        .display_type = try rdByte(g, s, "TYPE"),
        .children = try parseChildren(a, g, s),
    };
}

fn parseCategoryNode(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!CategoryNode {
    return .{
        .id = (try rdByte(g, s, "ID")) orelse 0,
        .str_ref = (try rdDword(g, s, "STRREF")) orelse 0xFFFF_FFFF,
        .name = try rdStringDupe(a, g, s, "NAME"),
        .delete_me = try rdStringDupe(a, g, s, "DELETE_ME"),
        .display_type = try rdByte(g, s, "TYPE"),
        .children = try parseChildren(a, g, s),
    };
}

fn parseBlueprintNode(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!BlueprintNode {
    var n = BlueprintNode{
        .str_ref = (try rdDword(g, s, "STRREF")) orelse 0xFFFF_FFFF,
        .name = try rdStringDupe(a, g, s, "NAME"),
        .faction = try rdStringDupe(a, g, s, "FACTION"),
    };
    if (g.getField(s, "RESREF")) |f| switch (f.value) {
        .res_ref => |v| n.res_ref = v,
        else => return error.WrongFieldType,
    };
    if (g.getField(s, "CR")) |f| switch (f.value) {
        .float => |v| n.cr = v,
        else => return error.WrongFieldType,
    };
    return n;
}

fn parseChildren(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]PaletteNode {
    const f = g.getField(s, "LIST") orelse return &.{};
    const handles = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    if (handles.len == 0) return &.{};
    const children = try a.alloc(PaletteNode, handles.len);
    for (handles, 0..) |h, i| {
        if (h >= g.structs.items.len) return error.InvalidFormat;
        children[i] = try parseNode(a, g, &g.structs.items[h]);
    }
    return children;
}

fn rdByte(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!?u8 {
    const f = g.getField(s, label) orelse return null;
    return switch (f.value) {
        .byte => |v| v,
        else => error.WrongFieldType,
    };
}

fn rdDword(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!?u32 {
    const f = g.getField(s, label) orelse return null;
    return switch (f.value) {
        .dword => |v| v,
        else => error.WrongFieldType,
    };
}

fn rdStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error![]u8 {
    const f = g.getField(s, label) orelse return &.{};
    return switch (f.value) {
        .exo_string => |v| a.dupe(u8, v),
        else => error.WrongFieldType,
    };
}

// ============================================================================
// Serialize helpers
// Fields are written in the same order for all node types (alphabetical by GFF
// label) so that serialize(parse(serialize(x))) == serialize(x).
// Order: CR, DELETE_ME, FACTION, ID, LIST, NAME, RESREF, STRREF, TYPE
// ============================================================================

fn serializeNode(alloc: std.mem.Allocator, g: *gff.GffFile, node: *const PaletteNode, struct_id: u32) !u32 {
    return switch (node.*) {
        .branch => |*b| serializeBranchNode(alloc, g, b, struct_id),
        .category => |*c| serializeCategoryNode(alloc, g, c, struct_id),
        .blueprint => |*bp| serializeBlueprintNode(alloc, g, bp, struct_id),
    };
}

fn serializeBranchNode(alloc: std.mem.Allocator, g: *gff.GffFile, b: *const BranchNode, struct_id: u32) !u32 {
    const sidx = try g.addStruct(struct_id);
    if (b.delete_me.len > 0)
        try g.addFieldToStruct(sidx, "DELETE_ME", .{ .exo_string = try alloc.dupe(u8, b.delete_me) });
    if (b.children.len > 0) {
        const h = try alloc.alloc(u32, b.children.len);
        for (b.children, 0..) |*c, i|
            h[i] = try serializeNode(alloc, g, c, struct_id);
        try g.addFieldToStruct(sidx, "LIST", .{ .list = h });
    }
    if (b.name.len > 0)
        try g.addFieldToStruct(sidx, "NAME", .{ .exo_string = try alloc.dupe(u8, b.name) });
    if (b.str_ref != 0xFFFF_FFFF)
        try g.addFieldToStruct(sidx, "STRREF", .{ .dword = b.str_ref });
    if (b.display_type) |v|
        try g.addFieldToStruct(sidx, "TYPE", .{ .byte = v });
    return sidx;
}

fn serializeCategoryNode(alloc: std.mem.Allocator, g: *gff.GffFile, c: *const CategoryNode, struct_id: u32) !u32 {
    const sidx = try g.addStruct(struct_id);
    if (c.delete_me.len > 0)
        try g.addFieldToStruct(sidx, "DELETE_ME", .{ .exo_string = try alloc.dupe(u8, c.delete_me) });
    try g.addFieldToStruct(sidx, "ID", .{ .byte = c.id });
    if (c.children.len > 0) {
        const h = try alloc.alloc(u32, c.children.len);
        for (c.children, 0..) |*ch, i|
            h[i] = try serializeNode(alloc, g, ch, struct_id);
        try g.addFieldToStruct(sidx, "LIST", .{ .list = h });
    }
    if (c.name.len > 0)
        try g.addFieldToStruct(sidx, "NAME", .{ .exo_string = try alloc.dupe(u8, c.name) });
    if (c.str_ref != 0xFFFF_FFFF)
        try g.addFieldToStruct(sidx, "STRREF", .{ .dword = c.str_ref });
    if (c.display_type) |v|
        try g.addFieldToStruct(sidx, "TYPE", .{ .byte = v });
    return sidx;
}

fn serializeBlueprintNode(alloc: std.mem.Allocator, g: *gff.GffFile, bp: *const BlueprintNode, struct_id: u32) !u32 {
    const sidx = try g.addStruct(struct_id);
    if (bp.cr) |v|
        try g.addFieldToStruct(sidx, "CR", .{ .float = v });
    if (bp.faction.len > 0)
        try g.addFieldToStruct(sidx, "FACTION", .{ .exo_string = try alloc.dupe(u8, bp.faction) });
    if (bp.name.len > 0)
        try g.addFieldToStruct(sidx, "NAME", .{ .exo_string = try alloc.dupe(u8, bp.name) });
    try g.addFieldToStruct(sidx, "RESREF", .{ .res_ref = bp.res_ref });
    if (bp.str_ref != 0xFFFF_FFFF)
        try g.addFieldToStruct(sidx, "STRREF", .{ .dword = bp.str_ref });
    return sidx;
}

// ============================================================================
// Tests
// ============================================================================

const tt = std.testing;

test "ITP empty round-trip" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    const bytes = try itp.serialize(gpa);
    defer gpa.free(bytes);

    var itp2 = try ItpFile.parse(gpa, bytes);
    defer itp2.deinit();

    try tt.expectEqual(@as(usize, 0), itp2.nodes.len);
}

test "ITP skeleton blueprint palette round-trip" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    itp.node_struct_id = 1;
    itp.next_useable_id = 5;
    itp.res_type = 2025;

    const a = itp.allocator();
    const nodes = try a.alloc(PaletteNode, 1);
    nodes[0] = .{ .branch = .{
        .str_ref = 100,
        .delete_me = try a.dupe(u8, "Weapons"),
    } };
    itp.nodes = nodes;

    const bytes = try itp.serialize(gpa);
    defer gpa.free(bytes);

    var itp2 = try ItpFile.parse(gpa, bytes);
    defer itp2.deinit();

    try tt.expectEqual(@as(u32, 1), itp2.node_struct_id);
    try tt.expectEqual(@as(?u8, 5), itp2.next_useable_id);
    try tt.expectEqual(@as(?u16, 2025), itp2.res_type);
    try tt.expectEqual(@as(usize, 1), itp2.nodes.len);
    try tt.expectEqualStrings("Weapons", itp2.nodes[0].branch.delete_me);
    try tt.expectEqual(@as(u32, 100), itp2.nodes[0].branch.str_ref);
}

test "ITP standard palette branch/category/blueprint tree" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    itp.node_struct_id = 0;

    const a = itp.allocator();

    // Build: branch → category(id=3) → blueprint
    const bp = try a.alloc(PaletteNode, 1);
    bp[0] = .{ .blueprint = .{
        .name = try a.dupe(u8, "Full Plate +4"),
        .res_ref = gff.ResRef.fromSlice("nw_aarcl014"),
    } };

    const cats = try a.alloc(PaletteNode, 1);
    cats[0] = .{ .category = .{
        .id = 3,
        .str_ref = 500,
        .children = bp,
    } };

    const branches = try a.alloc(PaletteNode, 1);
    branches[0] = .{ .branch = .{
        .name = try a.dupe(u8, "Armor"),
        .children = cats,
    } };
    itp.nodes = branches;

    const bytes = try itp.serialize(gpa);
    defer gpa.free(bytes);

    var itp2 = try ItpFile.parse(gpa, bytes);
    defer itp2.deinit();

    try tt.expectEqual(@as(u32, 0), itp2.node_struct_id);
    try tt.expectEqual(@as(usize, 1), itp2.nodes.len);

    const b2 = itp2.nodes[0].branch;
    try tt.expectEqualStrings("Armor", b2.name);
    try tt.expectEqual(@as(usize, 1), b2.children.len);

    const c2 = b2.children[0].category;
    try tt.expectEqual(@as(u8, 3), c2.id);
    try tt.expectEqual(@as(u32, 500), c2.str_ref);
    try tt.expectEqual(@as(usize, 1), c2.children.len);

    const bp2 = c2.children[0].blueprint;
    try tt.expectEqualStrings("Full Plate +4", bp2.name);
    try tt.expectEqualStrings("nw_aarcl014", bp2.res_ref.slice());
}

test "ITP tileset skeleton palette round-trip" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    itp.node_struct_id = 1;
    itp.next_useable_id = 3;
    itp.res_type = 2013;
    itp.tileset_res_ref = gff.ResRef.fromSlice("tcn01");

    const a = itp.allocator();
    const cats = try a.alloc(PaletteNode, 2);
    cats[0] = .{ .category = .{
        .id = 0,
        .str_ref = 63261,
        .delete_me = try a.dupe(u8, "Features"),
    } };
    cats[1] = .{ .category = .{
        .id = 2,
        .str_ref = 8282,
        .delete_me = try a.dupe(u8, "Terrain"),
    } };
    itp.nodes = cats;

    const bytes = try itp.serialize(gpa);
    defer gpa.free(bytes);

    var itp2 = try ItpFile.parse(gpa, bytes);
    defer itp2.deinit();

    try tt.expectEqual(@as(?u8, 3), itp2.next_useable_id);
    try tt.expectEqual(@as(?u16, 2013), itp2.res_type);
    try tt.expect(itp2.tileset_res_ref != null);
    try tt.expectEqualStrings("tcn01", itp2.tileset_res_ref.?.slice());

    try tt.expectEqual(@as(usize, 2), itp2.nodes.len);
    try tt.expectEqual(@as(u8, 0), itp2.nodes[0].category.id);
    try tt.expectEqual(@as(u32, 63261), itp2.nodes[0].category.str_ref);
    try tt.expectEqualStrings("Features", itp2.nodes[0].category.delete_me);
    try tt.expectEqual(@as(u8, 2), itp2.nodes[1].category.id);
    try tt.expectEqual(@as(u32, 8282), itp2.nodes[1].category.str_ref);
}

test "ITP blueprint node TYPE field round-trip" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    itp.node_struct_id = 1;
    const a = itp.allocator();
    const nodes = try a.alloc(PaletteNode, 2);
    nodes[0] = .{ .category = .{ .id = 0, .str_ref = 10, .display_type = 1 } };
    nodes[1] = .{ .category = .{ .id = 1, .str_ref = 20, .display_type = 2 } };
    itp.nodes = nodes;

    const bytes = try itp.serialize(gpa);
    defer gpa.free(bytes);

    var itp2 = try ItpFile.parse(gpa, bytes);
    defer itp2.deinit();

    try tt.expectEqual(@as(?u8, 1), itp2.nodes[0].category.display_type);
    try tt.expectEqual(@as(?u8, 2), itp2.nodes[1].category.display_type);
}

test "ITP blueprint creature fields round-trip" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    itp.node_struct_id = 0;
    const a = itp.allocator();
    const nodes = try a.alloc(PaletteNode, 1);
    nodes[0] = .{ .blueprint = .{
        .name = try a.dupe(u8, "Goblin"),
        .res_ref = gff.ResRef.fromSlice("nw_goblin001"),
        .cr = 0.25,
        .faction = try a.dupe(u8, "Hostile"),
    } };
    itp.nodes = nodes;

    const bytes = try itp.serialize(gpa);
    defer gpa.free(bytes);

    var itp2 = try ItpFile.parse(gpa, bytes);
    defer itp2.deinit();

    const bp = itp2.nodes[0].blueprint;
    try tt.expectEqualStrings("Goblin", bp.name);
    try tt.expectEqualStrings("nw_goblin001", bp.res_ref.slice());
    try tt.expect(bp.cr != null);
    try tt.expectApproxEqAbs(@as(f32, 0.25), bp.cr.?, 0.0001);
    try tt.expectEqualStrings("Hostile", bp.faction);
}

test "ITP byte-exact double serialize" {
    const gpa = tt.allocator;
    var itp = ItpFile.init(gpa);
    defer itp.deinit();

    itp.node_struct_id = 1;
    itp.next_useable_id = 4;
    itp.res_type = 2025;

    const a = itp.allocator();
    const bp_nodes = try a.alloc(PaletteNode, 1);
    bp_nodes[0] = .{ .blueprint = .{
        .res_ref = gff.ResRef.fromSlice("item001"),
        .str_ref = 999,
    } };
    const cats = try a.alloc(PaletteNode, 1);
    cats[0] = .{ .category = .{
        .id = 0,
        .str_ref = 200,
        .delete_me = try a.dupe(u8, "Armor"),
        .children = bp_nodes,
    } };
    itp.nodes = cats;

    const bytes1 = try itp.serialize(gpa);
    defer gpa.free(bytes1);

    var itp2 = try ItpFile.parse(gpa, bytes1);
    defer itp2.deinit();
    const bytes2 = try itp2.serialize(gpa);
    defer gpa.free(bytes2);

    try tt.expectEqualSlices(u8, bytes1, bytes2);
}

test "ITP node_struct_id preserved on round-trip" {
    const gpa = tt.allocator;

    for ([_]u32{ 0, 1 }) |struct_id| {
        var itp = ItpFile.init(gpa);
        defer itp.deinit();
        itp.node_struct_id = struct_id;
        const a = itp.allocator();
        const nodes = try a.alloc(PaletteNode, 1);
        nodes[0] = .{ .branch = .{ .str_ref = 42 } };
        itp.nodes = nodes;

        const bytes = try itp.serialize(gpa);
        defer gpa.free(bytes);

        var itp2 = try ItpFile.parse(gpa, bytes);
        defer itp2.deinit();
        try tt.expectEqual(struct_id, itp2.node_struct_id);
    }
}
