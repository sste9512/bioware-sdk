//! Bioware Aurora Item format (UTI blueprints + Item Structs in GIT/savegame).
//!
//! Reference: `Bioware_Aurora_Item_Format.pdf` sections 2.1–2.4.
//!
//! Public API:
//!   - `UtiFile`       — standalone UTI blueprint file (`"UTI "`).
//!   - `ItemStruct`    — typed marshaller for the Item GFF struct, usable in
//!                       any GFF (UTI top-level, GIT instance list, savegame,
//!                       BIC inventory). Variant-aware.
//!   - `ItemModel`     — `union(ModelType)` capturing the ModelType-conditional
//!                       fields (Tables 2.1.2.1–4).
//!   - `ItemProperty`  — typed nested struct (StructID 0) in PropertiesList.
const std = @import("std");
const gff = @import("gff.zig");

// ============================================================================
// Errors, enums, constants
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

pub const ModelType = enum(u8) {
    simple = 0,
    layered = 1,
    composite = 2,
    armor = 3,
};

/// Selects which optional field groups are read/written.
pub const ItemVariant = enum {
    /// UTI top-level: common + Comment / PaletteID.
    blueprint,
    /// Inside a GIT file: common + position/orientation.
    instance,
    /// Inside a SaveGame GIT: common + position/orientation + ObjectId/VarTable.
    game_instance,
    /// Inside an InventoryObject (BIC/savegame): common only.
    container,
};

pub const INVALID_OBJECT_ID: u32 = 0x7F00_0000;

// ============================================================================
// Internal helpers (read typed values out of a parsed GFF struct)
// ============================================================================

inline fn optByte(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8, default: u8) Error!u8 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .byte => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn optWord(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8, default: u16) Error!u16 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .word => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn optDword(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8, default: u32) Error!u32 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .dword => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn optInt(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8, default: i32) Error!i32 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .int => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn optFloat(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8, default: f32) Error!f32 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .float => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn optResRef(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!gff.ResRef {
    const f = g.getField(s, label) orelse return gff.ResRef{ .len = 0, .data = [_]u8{0} ** 16 };
    return switch (f.value) {
        .res_ref => |v| v,
        else => error.WrongFieldType,
    };
}
fn optExoStringDupe(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error![]u8 {
    const f = g.getField(s, label) orelse return arena.alloc(u8, 0);
    return switch (f.value) {
        .exo_string => |v| arena.dupe(u8, v),
        else => error.WrongFieldType,
    };
}
fn optExoLocDupe(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!gff.ExoLocString {
    var out: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    const f = g.getField(s, label) orelse return out;
    switch (f.value) {
        .exo_loc_string => |loc| {
            out.string_ref = loc.string_ref;
            for (loc.substrings.items) |ss| {
                try out.substrings.append(arena, .{
                    .string_id = ss.string_id,
                    .text = try arena.dupe(u8, ss.text),
                });
            }
            return out;
        },
        else => return error.WrongFieldType,
    }
}

inline fn reqByte(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!u8 {
    const f = g.getField(s, label) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .byte => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqWord(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!u16 {
    const f = g.getField(s, label) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .word => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqInt(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!i32 {
    const f = g.getField(s, label) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .int => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqResRef(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!gff.ResRef {
    const f = g.getField(s, label) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .res_ref => |v| v,
        else => error.WrongFieldType,
    };
}
fn reqExoStringDupe(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error![]u8 {
    const f = g.getField(s, label) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .exo_string => |v| arena.dupe(u8, v),
        else => error.WrongFieldType,
    };
}

/// Deep-clone an ExoLocString using `alloc`. Mirrors `area.cloneExoLoc`.
fn cloneExoLoc(alloc: std.mem.Allocator, src: gff.ExoLocString) !gff.ExoLocString {
    var out: gff.ExoLocString = .{ .string_ref = src.string_ref, .substrings = .empty };
    errdefer out.deinit(alloc);
    for (src.substrings.items) |ss| {
        const text = try alloc.dupe(u8, ss.text);
        errdefer alloc.free(text);
        try out.substrings.append(alloc, .{ .string_id = ss.string_id, .text = text });
    }
    return out;
}

// ============================================================================
// ItemProperty (StructID 0)
// ============================================================================

pub const ItemProperty = struct {
    pub const STRUCT_ID: u32 = 0;

    /// Per spec, "Always 100." Kept for round-trip fidelity.
    chance_appear: u8 = 100,
    /// Index into iprp_costtable.2da.
    cost_table: u8 = 0,
    /// Index into the selected cost table.
    cost_value: u16 = 0,
    /// 0xFF (== -1 cast to u8) means "no parameters".
    param1: u8 = 0xFF,
    param1_value: u8 = 0,
    /// Obsolete.
    param2: u8 = 0xFF,
    /// Obsolete.
    param2_value: u8 = 0,
    /// Index into itempropdefs.2da.
    property_name: u16 = 0,
    /// Index into the subtype 2da (0 if PropertyName has no SubTypeResRef).
    subtype: u16 = 0,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!ItemProperty {
        return .{
            .chance_appear = try optByte(g, s, "ChanceAppear", 100),
            .cost_table = try reqByte(g, s, "CostTable"),
            .cost_value = try reqWord(g, s, "CostValue"),
            .param1 = try optByte(g, s, "Param1", 0xFF),
            .param1_value = try optByte(g, s, "Param1Value", 0),
            .param2 = try optByte(g, s, "Param2", 0xFF),
            .param2_value = try optByte(g, s, "Param2Value", 0),
            .property_name = try reqWord(g, s, "PropertyName"),
            .subtype = try optWord(g, s, "Subtype", 0),
        };
    }

    pub fn writeIntoGff(self: ItemProperty, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "ChanceAppear", .{ .byte = self.chance_appear });
        try g.addFieldToStruct(struct_idx, "CostTable", .{ .byte = self.cost_table });
        try g.addFieldToStruct(struct_idx, "CostValue", .{ .word = self.cost_value });
        try g.addFieldToStruct(struct_idx, "Param1", .{ .byte = self.param1 });
        try g.addFieldToStruct(struct_idx, "Param1Value", .{ .byte = self.param1_value });
        try g.addFieldToStruct(struct_idx, "Param2", .{ .byte = self.param2 });
        try g.addFieldToStruct(struct_idx, "Param2Value", .{ .byte = self.param2_value });
        try g.addFieldToStruct(struct_idx, "PropertyName", .{ .word = self.property_name });
        try g.addFieldToStruct(struct_idx, "Subtype", .{ .word = self.subtype });
    }
};

// ============================================================================
// ItemModel — ModelType-conditional fields (Tables 2.1.2.1–4)
// ============================================================================

pub const SimpleModel = struct {
    model_part_1: u8 = 0,
};

pub const LayeredModel = struct {
    model_part_1: u8 = 0,
    cloth1_color: u8 = 0,
    cloth2_color: u8 = 0,
    leather1_color: u8 = 0,
    leather2_color: u8 = 0,
    metal1_color: u8 = 0,
    metal2_color: u8 = 0,
};

pub const CompositeModel = struct {
    model_part_1: u8 = 0,
    model_part_2: u8 = 0,
    model_part_3: u8 = 0,
};

pub const ArmorModel = struct {
    cloth1_color: u8 = 0,
    cloth2_color: u8 = 0,
    leather1_color: u8 = 0,
    leather2_color: u8 = 0,
    metal1_color: u8 = 0,
    metal2_color: u8 = 0,

    belt: u8 = 0,
    l_bicep: u8 = 0,
    l_farm: u8 = 0,
    l_foot: u8 = 0,
    l_hand: u8 = 0,
    l_shin: u8 = 0,
    l_shoul: u8 = 0,
    l_thigh: u8 = 0,
    neck: u8 = 0,
    pelvis: u8 = 0,
    r_bicep: u8 = 0,
    r_farm: u8 = 0,
    r_foot: u8 = 0,
    r_hand: u8 = 0,
    robe: u8 = 0,
    r_shin: u8 = 0,
    r_shoul: u8 = 0,
    r_thigh: u8 = 0,
    torso: u8 = 0,
};

pub const ItemModel = union(ModelType) {
    simple: SimpleModel,
    layered: LayeredModel,
    composite: CompositeModel,
    armor: ArmorModel,

    /// Sniff the ModelType from which conditional fields are present in `s`.
    /// Precedence: any ArmorPart_* → armor; ModelPart3 → composite; any
    /// *Color → layered; otherwise → simple.
    pub fn sniff(g: *const gff.GffFile, s: *const gff.Struct) ModelType {
        if (g.getField(s, "ArmorPart_Torso") != null or
            g.getField(s, "ArmorPart_Belt") != null or
            g.getField(s, "ArmorPart_Pelvis") != null or
            g.getField(s, "ArmorPart_Neck") != null or
            g.getField(s, "ArmorPart_Robe") != null) return .armor;
        if (g.getField(s, "ModelPart3") != null) return .composite;
        if (g.getField(s, "Cloth1Color") != null or
            g.getField(s, "Leather1Color") != null or
            g.getField(s, "Metal1Color") != null) return .layered;
        return .simple;
    }

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct, mt: ModelType) Error!ItemModel {
        return switch (mt) {
            .simple => .{ .simple = .{
                .model_part_1 = try optByte(g, s, "ModelPart1", 0),
            } },
            .layered => .{ .layered = .{
                .model_part_1 = try optByte(g, s, "ModelPart1", 0),
                .cloth1_color = try optByte(g, s, "Cloth1Color", 0),
                .cloth2_color = try optByte(g, s, "Cloth2Color", 0),
                .leather1_color = try optByte(g, s, "Leather1Color", 0),
                .leather2_color = try optByte(g, s, "Leather2Color", 0),
                .metal1_color = try optByte(g, s, "Metal1Color", 0),
                .metal2_color = try optByte(g, s, "Metal2Color", 0),
            } },
            .composite => .{ .composite = .{
                .model_part_1 = try optByte(g, s, "ModelPart1", 0),
                .model_part_2 = try optByte(g, s, "ModelPart2", 0),
                .model_part_3 = try optByte(g, s, "ModelPart3", 0),
            } },
            .armor => .{ .armor = .{
                .cloth1_color = try optByte(g, s, "Cloth1Color", 0),
                .cloth2_color = try optByte(g, s, "Cloth2Color", 0),
                .leather1_color = try optByte(g, s, "Leather1Color", 0),
                .leather2_color = try optByte(g, s, "Leather2Color", 0),
                .metal1_color = try optByte(g, s, "Metal1Color", 0),
                .metal2_color = try optByte(g, s, "Metal2Color", 0),
                .belt = try optByte(g, s, "ArmorPart_Belt", 0),
                .l_bicep = try optByte(g, s, "ArmorPart_LBicep", 0),
                .l_farm = try optByte(g, s, "ArmorPart_LFArm", 0),
                .l_foot = try optByte(g, s, "ArmorPart_LFoot", 0),
                .l_hand = try optByte(g, s, "ArmorPart_LHand", 0),
                .l_shin = try optByte(g, s, "ArmorPart_LShin", 0),
                .l_shoul = try optByte(g, s, "ArmorPart_LShoul", 0),
                .l_thigh = try optByte(g, s, "ArmorPart_LThigh", 0),
                .neck = try optByte(g, s, "ArmorPart_Neck", 0),
                .pelvis = try optByte(g, s, "ArmorPart_Pelvis", 0),
                .r_bicep = try optByte(g, s, "ArmorPart_RBicep", 0),
                .r_farm = try optByte(g, s, "ArmorPart_RFArm", 0),
                .r_foot = try optByte(g, s, "ArmorPart_RFoot", 0),
                .r_hand = try optByte(g, s, "ArmorPart_RHand", 0),
                .robe = try optByte(g, s, "ArmorPart_Robe", 0),
                .r_shin = try optByte(g, s, "ArmorPart_RShin", 0),
                .r_shoul = try optByte(g, s, "ArmorPart_RShoul", 0),
                .r_thigh = try optByte(g, s, "ArmorPart_RThigh", 0),
                .torso = try optByte(g, s, "ArmorPart_Torso", 0),
            } },
        };
    }

    pub fn writeIntoGff(self: ItemModel, g: *gff.GffFile, struct_idx: u32) !void {
        switch (self) {
            .simple => |m| {
                try g.addFieldToStruct(struct_idx, "ModelPart1", .{ .byte = m.model_part_1 });
            },
            .layered => |m| {
                // Fields emitted in alphabetical order for canonical output.
                try g.addFieldToStruct(struct_idx, "Cloth1Color", .{ .byte = m.cloth1_color });
                try g.addFieldToStruct(struct_idx, "Cloth2Color", .{ .byte = m.cloth2_color });
                try g.addFieldToStruct(struct_idx, "Leather1Color", .{ .byte = m.leather1_color });
                try g.addFieldToStruct(struct_idx, "Leather2Color", .{ .byte = m.leather2_color });
                try g.addFieldToStruct(struct_idx, "Metal1Color", .{ .byte = m.metal1_color });
                try g.addFieldToStruct(struct_idx, "Metal2Color", .{ .byte = m.metal2_color });
                try g.addFieldToStruct(struct_idx, "ModelPart1", .{ .byte = m.model_part_1 });
            },
            .composite => |m| {
                try g.addFieldToStruct(struct_idx, "ModelPart1", .{ .byte = m.model_part_1 });
                try g.addFieldToStruct(struct_idx, "ModelPart2", .{ .byte = m.model_part_2 });
                try g.addFieldToStruct(struct_idx, "ModelPart3", .{ .byte = m.model_part_3 });
            },
            .armor => |m| {
                try g.addFieldToStruct(struct_idx, "ArmorPart_Belt", .{ .byte = m.belt });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LBicep", .{ .byte = m.l_bicep });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LFArm", .{ .byte = m.l_farm });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LFoot", .{ .byte = m.l_foot });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LHand", .{ .byte = m.l_hand });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LShin", .{ .byte = m.l_shin });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LShoul", .{ .byte = m.l_shoul });
                try g.addFieldToStruct(struct_idx, "ArmorPart_LThigh", .{ .byte = m.l_thigh });
                try g.addFieldToStruct(struct_idx, "ArmorPart_Neck", .{ .byte = m.neck });
                try g.addFieldToStruct(struct_idx, "ArmorPart_Pelvis", .{ .byte = m.pelvis });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RBicep", .{ .byte = m.r_bicep });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RFArm", .{ .byte = m.r_farm });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RFoot", .{ .byte = m.r_foot });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RHand", .{ .byte = m.r_hand });
                try g.addFieldToStruct(struct_idx, "ArmorPart_Robe", .{ .byte = m.robe });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RShin", .{ .byte = m.r_shin });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RShoul", .{ .byte = m.r_shoul });
                try g.addFieldToStruct(struct_idx, "ArmorPart_RThigh", .{ .byte = m.r_thigh });
                try g.addFieldToStruct(struct_idx, "ArmorPart_Torso", .{ .byte = m.torso });
                try g.addFieldToStruct(struct_idx, "Cloth1Color", .{ .byte = m.cloth1_color });
                try g.addFieldToStruct(struct_idx, "Cloth2Color", .{ .byte = m.cloth2_color });
                try g.addFieldToStruct(struct_idx, "Leather1Color", .{ .byte = m.leather1_color });
                try g.addFieldToStruct(struct_idx, "Leather2Color", .{ .byte = m.leather2_color });
                try g.addFieldToStruct(struct_idx, "Metal1Color", .{ .byte = m.metal1_color });
                try g.addFieldToStruct(struct_idx, "Metal2Color", .{ .byte = m.metal2_color });
            },
        }
    }
};

// ============================================================================
// ItemStruct (variant-aware marshaller)
// ============================================================================

pub const ItemStruct = struct {
    // ---- Common (Table 2.1.1) ----
    add_cost: u32 = 0,
    base_item: i32 = 0,
    charges: u8 = 0,
    cost: u32 = 0,
    cursed: u8 = 0,
    desc_identified: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    description: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    loc_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    plot: u8 = 0,
    properties: []ItemProperty = &.{},
    stack_size: u16 = 1,
    stolen: u8 = 0,
    tag: []u8 = &.{},
    template_res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },

    // ---- ModelType-conditional (Tables 2.1.2.1–4) ----
    model: ItemModel = .{ .simple = .{} },

    // ---- Blueprint-only (Table 2.2) ----
    comment: ?[]u8 = null,
    palette_id: ?u8 = null,

    // ---- Instance-only (Table 2.3) ----
    x_orientation: ?f32 = null,
    y_orientation: ?f32 = null,
    x_position: ?f32 = null,
    y_position: ?f32 = null,
    z_position: ?f32 = null,

    // ---- Game-Instance only (Table 2.4) ----
    object_id: ?u32 = null,
    var_table: ?[]u32 = null,

    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: ItemVariant,
    ) Error!ItemStruct {
        return fromGffStructAs(arena, g, s, variant, ItemModel.sniff(g, s));
    }

    pub fn fromGffStructAs(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: ItemVariant,
        mt: ModelType,
    ) Error!ItemStruct {
        var out: ItemStruct = .{};

        // ---- Required common fields ----
        out.base_item = try reqInt(g, s, "BaseItem");
        out.tag = try reqExoStringDupe(arena, g, s, "Tag");
        out.template_res_ref = try reqResRef(g, s, "TemplateResRef");

        // ---- Optional common fields ----
        out.add_cost = try optDword(g, s, "AddCost", 0);
        out.charges = try optByte(g, s, "Charges", 0);
        out.cost = try optDword(g, s, "Cost", 0);
        out.cursed = try optByte(g, s, "Cursed", 0);
        out.desc_identified = try optExoLocDupe(arena, g, s, "DescIdentified");
        out.description = try optExoLocDupe(arena, g, s, "Description");
        out.loc_name = try optExoLocDupe(arena, g, s, "LocName");
        out.plot = try optByte(g, s, "Plot", 0);
        out.stack_size = try optWord(g, s, "StackSize", 1);
        out.stolen = try optByte(g, s, "Stolen", 0);

        // ---- ModelType-conditional ----
        out.model = try ItemModel.fromGffStruct(g, s, mt);

        // ---- PropertiesList ----
        if (g.getField(s, "PropertiesList")) |f| switch (f.value) {
            .list => |handles| {
                const props = try arena.alloc(ItemProperty, handles.len);
                for (handles, 0..) |h, i| {
                    if (h >= g.structs.items.len) return error.InvalidFormat;
                    props[i] = try ItemProperty.fromGffStruct(g, &g.structs.items[h]);
                }
                out.properties = props;
            },
            else => return error.WrongFieldType,
        };

        // ---- Variant-specific ----
        switch (variant) {
            .blueprint => {
                if (g.getField(s, "Comment")) |f| switch (f.value) {
                    .exo_string => |v| out.comment = try arena.dupe(u8, v),
                    else => return error.WrongFieldType,
                };
                if (g.getField(s, "PaletteID")) |f| switch (f.value) {
                    .byte => |v| out.palette_id = v,
                    else => return error.WrongFieldType,
                };
            },
            .instance, .game_instance => {
                if (g.getField(s, "XOrientation")) |_| out.x_orientation = try optFloat(g, s, "XOrientation", 0);
                if (g.getField(s, "YOrientation")) |_| out.y_orientation = try optFloat(g, s, "YOrientation", 0);
                if (g.getField(s, "XPosition")) |_| out.x_position = try optFloat(g, s, "XPosition", 0);
                if (g.getField(s, "YPosition")) |_| out.y_position = try optFloat(g, s, "YPosition", 0);
                if (g.getField(s, "ZPosition")) |_| out.z_position = try optFloat(g, s, "ZPosition", 0);

                if (variant == .game_instance) {
                    if (g.getField(s, "ObjectId")) |f| switch (f.value) {
                        .dword => |v| out.object_id = v,
                        else => return error.WrongFieldType,
                    };
                    if (g.getField(s, "VarTable")) |f| switch (f.value) {
                        .list => |v| out.var_table = try arena.dupe(u32, v),
                        else => return error.WrongFieldType,
                    };
                }
            },
            .container => {},
        }

        return out;
    }

    /// Emit this Item into the given GFF struct. Fields are written in
    /// alphabetical-by-label order so output is canonical & deterministic.
    /// `alloc` must be the same allocator that backs `g`.
    pub fn writeIntoGff(
        self: *const ItemStruct,
        alloc: std.mem.Allocator,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: ItemVariant,
    ) !void {
        try g.addFieldToStruct(struct_idx, "AddCost", .{ .dword = self.add_cost });

        // Armor model emits ArmorPart_* before BaseItem in alphabetical order.
        if (self.model == .armor) {
            try emitArmorParts(g, struct_idx, self.model.armor);
        }

        try g.addFieldToStruct(struct_idx, "BaseItem", .{ .int = self.base_item });
        try g.addFieldToStruct(struct_idx, "Charges", .{ .byte = self.charges });

        // Layered/Armor have Cloth/Leather/Metal colors here.
        switch (self.model) {
            .layered => |m| try emitColors(g, struct_idx, m.cloth1_color, m.cloth2_color, m.leather1_color, m.leather2_color, m.metal1_color, m.metal2_color),
            .armor => |m| try emitColors(g, struct_idx, m.cloth1_color, m.cloth2_color, m.leather1_color, m.leather2_color, m.metal1_color, m.metal2_color),
            else => {},
        }

        if (variant == .blueprint and self.comment != null) {
            try g.addFieldToStruct(struct_idx, "Comment", .{ .exo_string = try alloc.dupe(u8, self.comment.?) });
        }
        try g.addFieldToStruct(struct_idx, "Cost", .{ .dword = self.cost });
        try g.addFieldToStruct(struct_idx, "Cursed", .{ .byte = self.cursed });
        try g.addFieldToStruct(struct_idx, "DescIdentified", .{ .exo_loc_string = try cloneExoLoc(alloc, self.desc_identified) });
        try g.addFieldToStruct(struct_idx, "Description", .{ .exo_loc_string = try cloneExoLoc(alloc, self.description) });
        try g.addFieldToStruct(struct_idx, "LocName", .{ .exo_loc_string = try cloneExoLoc(alloc, self.loc_name) });

        // ModelPart fields (Simple, Layered, Composite).
        switch (self.model) {
            .simple => |m| try g.addFieldToStruct(struct_idx, "ModelPart1", .{ .byte = m.model_part_1 }),
            .layered => |m| try g.addFieldToStruct(struct_idx, "ModelPart1", .{ .byte = m.model_part_1 }),
            .composite => |m| {
                try g.addFieldToStruct(struct_idx, "ModelPart1", .{ .byte = m.model_part_1 });
                try g.addFieldToStruct(struct_idx, "ModelPart2", .{ .byte = m.model_part_2 });
                try g.addFieldToStruct(struct_idx, "ModelPart3", .{ .byte = m.model_part_3 });
            },
            .armor => {},
        }

        if (variant == .game_instance and self.object_id != null) {
            try g.addFieldToStruct(struct_idx, "ObjectId", .{ .dword = self.object_id.? });
        }
        if (variant == .blueprint and self.palette_id != null) {
            try g.addFieldToStruct(struct_idx, "PaletteID", .{ .byte = self.palette_id.? });
        }
        try g.addFieldToStruct(struct_idx, "Plot", .{ .byte = self.plot });

        // PropertiesList — always emitted (empty list when none).
        const phandles = try alloc.alloc(u32, self.properties.len);
        for (self.properties, 0..) |prop, i| {
            const pidx = try g.addStruct(ItemProperty.STRUCT_ID);
            try prop.writeIntoGff(g, pidx);
            phandles[i] = pidx;
        }
        try g.addFieldToStruct(struct_idx, "PropertiesList", .{ .list = phandles });
        try g.addFieldToStruct(struct_idx, "StackSize", .{ .word = self.stack_size });
        try g.addFieldToStruct(struct_idx, "Stolen", .{ .byte = self.stolen });
        try g.addFieldToStruct(struct_idx, "Tag", .{ .exo_string = try alloc.dupe(u8, self.tag) });
        try g.addFieldToStruct(struct_idx, "TemplateResRef", .{ .res_ref = self.template_res_ref });

        if ((variant == .instance or variant == .game_instance)) {
            if (variant == .game_instance and self.var_table != null) {
                try g.addFieldToStruct(struct_idx, "VarTable", .{ .list = try alloc.dupe(u32, self.var_table.?) });
            }
            if (self.x_orientation) |v| try g.addFieldToStruct(struct_idx, "XOrientation", .{ .float = v });
            if (self.x_position) |v| try g.addFieldToStruct(struct_idx, "XPosition", .{ .float = v });
            if (self.y_orientation) |v| try g.addFieldToStruct(struct_idx, "YOrientation", .{ .float = v });
            if (self.y_position) |v| try g.addFieldToStruct(struct_idx, "YPosition", .{ .float = v });
            if (self.z_position) |v| try g.addFieldToStruct(struct_idx, "ZPosition", .{ .float = v });
        }
    }
};

fn emitColors(
    g: *gff.GffFile,
    struct_idx: u32,
    c1: u8,
    c2: u8,
    l1: u8,
    l2: u8,
    m1: u8,
    m2: u8,
) !void {
    try g.addFieldToStruct(struct_idx, "Cloth1Color", .{ .byte = c1 });
    try g.addFieldToStruct(struct_idx, "Cloth2Color", .{ .byte = c2 });
    try g.addFieldToStruct(struct_idx, "Leather1Color", .{ .byte = l1 });
    try g.addFieldToStruct(struct_idx, "Leather2Color", .{ .byte = l2 });
    try g.addFieldToStruct(struct_idx, "Metal1Color", .{ .byte = m1 });
    try g.addFieldToStruct(struct_idx, "Metal2Color", .{ .byte = m2 });
}

fn emitArmorParts(g: *gff.GffFile, struct_idx: u32, m: ArmorModel) !void {
    try g.addFieldToStruct(struct_idx, "ArmorPart_Belt", .{ .byte = m.belt });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LBicep", .{ .byte = m.l_bicep });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LFArm", .{ .byte = m.l_farm });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LFoot", .{ .byte = m.l_foot });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LHand", .{ .byte = m.l_hand });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LShin", .{ .byte = m.l_shin });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LShoul", .{ .byte = m.l_shoul });
    try g.addFieldToStruct(struct_idx, "ArmorPart_LThigh", .{ .byte = m.l_thigh });
    try g.addFieldToStruct(struct_idx, "ArmorPart_Neck", .{ .byte = m.neck });
    try g.addFieldToStruct(struct_idx, "ArmorPart_Pelvis", .{ .byte = m.pelvis });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RBicep", .{ .byte = m.r_bicep });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RFArm", .{ .byte = m.r_farm });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RFoot", .{ .byte = m.r_foot });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RHand", .{ .byte = m.r_hand });
    try g.addFieldToStruct(struct_idx, "ArmorPart_Robe", .{ .byte = m.robe });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RShin", .{ .byte = m.r_shin });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RShoul", .{ .byte = m.r_shoul });
    try g.addFieldToStruct(struct_idx, "ArmorPart_RThigh", .{ .byte = m.r_thigh });
    try g.addFieldToStruct(struct_idx, "ArmorPart_Torso", .{ .byte = m.torso });
}

// ============================================================================
// InventoryObject (Items doc Section 3, StructID 0)
// ============================================================================

/// An InventoryObject is an embedded Item plus grid coordinates within the
/// owner's inventory. Used by `CreatureStruct.item_list` and any other
/// inventory-bearing struct (BIC, container placeable).
///
/// Always written/parsed with `ItemVariant.container` (common fields only —
/// position/orientation/ObjectId fields belong to the owner, not the item).
pub const InventoryObject = struct {
    pub const STRUCT_ID: u32 = 0;

    repos_pos_x: u8 = 0,
    repos_pos_y: u8 = 0,
    item: ItemStruct = .{},

    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
    ) Error!InventoryObject {
        return .{
            .repos_pos_x = try optByte(g, s, "Repos_PosX", 0),
            .repos_pos_y = try optByte(g, s, "Repos_PosY", 0),
            .item = try ItemStruct.fromGffStruct(arena, g, s, .container),
        };
    }

    pub fn writeIntoGff(
        self: *const InventoryObject,
        alloc: std.mem.Allocator,
        g: *gff.GffFile,
        struct_idx: u32,
    ) !void {
        // Embed the item's common fields (canonical alphabetical order is
        // handled by ItemStruct.writeIntoGff for its own fields). Then add
        // the two Repos_* coordinates. Final alphabetical re-ordering on
        // serialize would put Repos_PosX/PosY after PropertiesList; we emit
        // them last and let GffFile produce its own canonical ordering on
        // serialize (which it does, since field names are deduplicated by
        // label and the serializer iterates structs in index order).
        try self.item.writeIntoGff(alloc, g, struct_idx, .container);
        try g.addFieldToStruct(struct_idx, "Repos_PosX", .{ .byte = self.repos_pos_x });
        try g.addFieldToStruct(struct_idx, "Repos_PosY", .{ .byte = self.repos_pos_y });
    }
};

// ============================================================================
// UtiFile (standalone blueprint)
// ============================================================================

pub const UtiFile = struct {
    pub const FILE_TYPE = "UTI ";

    arena: std.heap.ArenaAllocator,
    item: ItemStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UtiFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UtiFile) void {
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtiFile {
        var self = UtiFile.init(parent_alloc);
        errdefer self.deinit();

        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        const tl = &g.structs.items[0];
        self.item = try ItemStruct.fromGffStruct(self.arena.allocator(), &g, tl, .blueprint);
        return self;
    }

    pub fn serialize(self: *const UtiFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.item.writeIntoGff(alloc, &g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "UTI defaults round-trip" {
    const gpa = t.allocator;
    var u = UtiFile.init(gpa);
    defer u.deinit();

    const bytes = try u.serialize(gpa);
    defer gpa.free(bytes);

    var u_out = try UtiFile.parse(gpa, bytes);
    defer u_out.deinit();

    try t.expectEqual(@as(i32, 0), u_out.item.base_item);
    try t.expectEqualStrings("", u_out.item.tag);
    try t.expectEqual(@as(u8, 0), u_out.item.template_res_ref.len);
    try t.expectEqual(ModelType.simple, std.meta.activeTag(u_out.item.model));
    try t.expectEqual(@as(usize, 0), u_out.item.properties.len);
}

test "UTI typed round-trip (composite) + byte-exact" {
    const gpa = t.allocator;
    var u = UtiFile.init(gpa);
    defer u.deinit();
    const a = u.arena.allocator();

    u.item.base_item = 37;
    u.item.tag = try a.dupe(u8, "longsword_001");
    u.item.template_res_ref = gff.ResRef.fromSlice("nw_wswls001");
    u.item.cost = 15;
    u.item.stack_size = 1;
    u.item.charges = 0;
    u.item.palette_id = 12;
    u.item.comment = try a.dupe(u8, "iconic blade");
    u.item.model = .{ .composite = .{ .model_part_1 = 1, .model_part_2 = 1, .model_part_3 = 1 } };

    const props = try a.alloc(ItemProperty, 2);
    props[0] = .{ .property_name = 6, .cost_table = 1, .cost_value = 1 }; // Enhancement Bonus +1
    props[1] = .{ .property_name = 16, .cost_table = 3, .cost_value = 3, .subtype = 8 }; // Damage Bonus +1d6 Fire
    u.item.properties = props;

    u.item.loc_name = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    try u.item.loc_name.substrings.append(a, .{ .string_id = 0, .text = try a.dupe(u8, "Iconic Longsword") });

    const buf1 = try u.serialize(gpa);
    defer gpa.free(buf1);

    var u_out = try UtiFile.parse(gpa, buf1);
    defer u_out.deinit();

    try t.expectEqual(@as(i32, 37), u_out.item.base_item);
    try t.expectEqualStrings("longsword_001", u_out.item.tag);
    try t.expectEqualStrings("nw_wswls001", u_out.item.template_res_ref.slice());
    try t.expectEqual(@as(u32, 15), u_out.item.cost);
    try t.expectEqual(@as(?u8, 12), u_out.item.palette_id);
    try t.expectEqualStrings("iconic blade", u_out.item.comment.?);
    try t.expectEqual(ModelType.composite, std.meta.activeTag(u_out.item.model));
    try t.expectEqual(@as(u8, 1), u_out.item.model.composite.model_part_3);
    try t.expectEqual(@as(usize, 2), u_out.item.properties.len);
    try t.expectEqual(@as(u16, 6), u_out.item.properties[0].property_name);
    try t.expectEqual(@as(u16, 16), u_out.item.properties[1].property_name);
    try t.expectEqual(@as(u16, 8), u_out.item.properties[1].subtype);

    const buf2 = try u_out.serialize(gpa);
    defer gpa.free(buf2);
    try t.expectEqualSlices(u8, buf1, buf2);
}

test "UTI armor round-trip + sniffing" {
    const gpa = t.allocator;
    var u = UtiFile.init(gpa);
    defer u.deinit();
    const a = u.arena.allocator();

    u.item.base_item = 16; // armor
    u.item.tag = try a.dupe(u8, "plate_001");
    u.item.template_res_ref = gff.ResRef.fromSlice("plate_001");
    u.item.model = .{ .armor = .{
        .torso = 5,
        .pelvis = 3,
        .belt = 1,
        .l_shoul = 7,
        .r_shoul = 7,
        .cloth1_color = 12,
        .metal1_color = 4,
    } };

    const buf = try u.serialize(gpa);
    defer gpa.free(buf);

    var u_out = try UtiFile.parse(gpa, buf);
    defer u_out.deinit();

    try t.expectEqual(ModelType.armor, std.meta.activeTag(u_out.item.model));
    try t.expectEqual(@as(u8, 5), u_out.item.model.armor.torso);
    try t.expectEqual(@as(u8, 12), u_out.item.model.armor.cloth1_color);
    try t.expectEqual(@as(u8, 4), u_out.item.model.armor.metal1_color);
}

test "UTI layered round-trip + sniffing" {
    const gpa = t.allocator;
    var u = UtiFile.init(gpa);
    defer u.deinit();
    const a = u.arena.allocator();

    u.item.base_item = 65; // helmet
    u.item.tag = try a.dupe(u8, "helm_001");
    u.item.template_res_ref = gff.ResRef.fromSlice("helm_001");
    u.item.model = .{ .layered = .{
        .model_part_1 = 5,
        .cloth1_color = 3,
        .cloth2_color = 0,
        .leather1_color = 8,
        .leather2_color = 1,
        .metal1_color = 12,
        .metal2_color = 0,
    } };

    const buf = try u.serialize(gpa);
    defer gpa.free(buf);

    var u_out = try UtiFile.parse(gpa, buf);
    defer u_out.deinit();

    try t.expectEqual(ModelType.layered, std.meta.activeTag(u_out.item.model));
    try t.expectEqual(@as(u8, 5), u_out.item.model.layered.model_part_1);
    try t.expectEqual(@as(u8, 12), u_out.item.model.layered.metal1_color);
}

test "ItemStruct as instance in a GIT" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    // Build the item inside a synthetic GIT.
    var item: ItemStruct = .{};
    item.base_item = 5;
    item.tag = try gpa.dupe(u8, "torch_a");
    defer gpa.free(item.tag);
    item.template_res_ref = gff.ResRef.fromSlice("nw_it_torch001");
    item.x_position = 12.5;
    item.y_position = -3.25;
    item.z_position = 0.0;
    item.x_orientation = 1.0;
    item.y_orientation = 0.0;

    const item_idx = try g.addStruct(0);
    try item.writeIntoGff(gpa, &g, item_idx, .instance);

    // List wrapping it.
    const handles = try gpa.alloc(u32, 1);
    handles[0] = item_idx;
    try g.addFieldToStruct(0, "List", .{ .list = handles });

    const buf = try g.serialize(gpa);
    defer gpa.free(buf);

    // Parse the GIT back, locate the item struct, decode it.
    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(buf, &"GIT ".*);
    const list_field = g2.getField(&g2.structs.items[0], "List").?;
    const item_struct = &g2.structs.items[list_field.value.list[0]];

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try ItemStruct.fromGffStruct(arena.allocator(), &g2, item_struct, .instance);

    try t.expectEqual(@as(i32, 5), decoded.base_item);
    try t.expectEqual(@as(?f32, 12.5), decoded.x_position);
    try t.expectEqual(@as(?f32, 1.0), decoded.x_orientation);

    // Blueprint-only fields must be absent.
    try t.expect(decoded.comment == null);
    try t.expect(decoded.palette_id == null);
}

test "ItemStruct as game_instance with ObjectId + VarTable" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var item: ItemStruct = .{};
    item.base_item = 1;
    item.tag = try gpa.dupe(u8, "x");
    defer gpa.free(item.tag);
    item.template_res_ref = gff.ResRef.fromSlice("x");
    item.object_id = 0x1234_5678;
    item.var_table = try gpa.alloc(u32, 0); // empty list, but present.
    defer gpa.free(item.var_table.?);
    item.x_position = 0;
    item.y_position = 0;
    item.z_position = 0;
    item.x_orientation = 1;
    item.y_orientation = 0;

    const idx = try g.addStruct(0);
    try item.writeIntoGff(gpa, &g, idx, .game_instance);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try ItemStruct.fromGffStruct(arena.allocator(), &g, &g.structs.items[idx], .game_instance);

    try t.expectEqual(@as(?u32, 0x1234_5678), decoded.object_id);
    try t.expect(decoded.var_table != null);
}

test "ItemProperty defaults: Param1 = 0xFF when absent" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "UTI ".*);
    defer g.deinit();

    // A property struct with only the required fields.
    const pidx = try g.addStruct(ItemProperty.STRUCT_ID);
    try g.addFieldToStruct(pidx, "CostTable", .{ .byte = 1 });
    try g.addFieldToStruct(pidx, "CostValue", .{ .word = 2 });
    try g.addFieldToStruct(pidx, "PropertyName", .{ .word = 6 });

    const prop = try ItemProperty.fromGffStruct(&g, &g.structs.items[pidx]);
    try t.expectEqual(@as(u8, 0xFF), prop.param1);
    try t.expectEqual(@as(u8, 0xFF), prop.param2);
    try t.expectEqual(@as(u8, 100), prop.chance_appear);
    try t.expectEqual(@as(u16, 0), prop.subtype);
}

test "wrong magic for UtiFile.parse" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "ARE ".*);
    defer g.deinit();
    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    try t.expectError(error.InvalidFileType, UtiFile.parse(gpa, bytes));
}

test "missing required fields" {
    const gpa = t.allocator;

    // 1) Missing BaseItem.
    {
        var g = try gff.GffFile.init(gpa, "UTI ".*);
        defer g.deinit();
        try g.addFieldToStruct(0, "Tag", .{ .exo_string = try gpa.dupe(u8, "x") });
        try g.addFieldToStruct(0, "TemplateResRef", .{ .res_ref = gff.ResRef.fromSlice("x") });
        const buf = try g.serialize(gpa);
        defer gpa.free(buf);
        try t.expectError(error.MissingRequiredField, UtiFile.parse(gpa, buf));
    }

    // 2) Missing TemplateResRef.
    {
        var g = try gff.GffFile.init(gpa, "UTI ".*);
        defer g.deinit();
        try g.addFieldToStruct(0, "BaseItem", .{ .int = 1 });
        try g.addFieldToStruct(0, "Tag", .{ .exo_string = try gpa.dupe(u8, "x") });
        const buf = try g.serialize(gpa);
        defer gpa.free(buf);
        try t.expectError(error.MissingRequiredField, UtiFile.parse(gpa, buf));
    }

    // 3) ItemProperty missing PropertyName.
    {
        var g = try gff.GffFile.init(gpa, "UTI ".*);
        defer g.deinit();
        try g.addFieldToStruct(0, "BaseItem", .{ .int = 1 });
        try g.addFieldToStruct(0, "Tag", .{ .exo_string = try gpa.dupe(u8, "x") });
        try g.addFieldToStruct(0, "TemplateResRef", .{ .res_ref = gff.ResRef.fromSlice("x") });

        const pidx = try g.addStruct(ItemProperty.STRUCT_ID);
        try g.addFieldToStruct(pidx, "CostTable", .{ .byte = 1 });
        try g.addFieldToStruct(pidx, "CostValue", .{ .word = 2 });
        const handles = try gpa.alloc(u32, 1);
        handles[0] = pidx;
        try g.addFieldToStruct(0, "PropertiesList", .{ .list = handles });

        const buf = try g.serialize(gpa);
        defer gpa.free(buf);
        try t.expectError(error.MissingRequiredField, UtiFile.parse(gpa, buf));
    }
}

test "ModelType sniffing precedence: armor wins over color fields" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "UTI ".*);
    defer g.deinit();
    try g.addFieldToStruct(0, "BaseItem", .{ .int = 16 });
    try g.addFieldToStruct(0, "Tag", .{ .exo_string = try gpa.dupe(u8, "armor") });
    try g.addFieldToStruct(0, "TemplateResRef", .{ .res_ref = gff.ResRef.fromSlice("armor") });
    try g.addFieldToStruct(0, "Cloth1Color", .{ .byte = 1 }); // would suggest "layered"
    try g.addFieldToStruct(0, "ArmorPart_Torso", .{ .byte = 2 }); // but armor wins.

    const buf = try g.serialize(gpa);
    defer gpa.free(buf);

    var u = try UtiFile.parse(gpa, buf);
    defer u.deinit();

    try t.expectEqual(ModelType.armor, std.meta.activeTag(u.item.model));
    try t.expectEqual(@as(u8, 2), u.item.model.armor.torso);
    try t.expectEqual(@as(u8, 1), u.item.model.armor.cloth1_color);
}

test "InventoryObject round-trip with embedded ItemStruct" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "BIC ".*);
    defer g.deinit();

    var inv: InventoryObject = .{ .repos_pos_x = 3, .repos_pos_y = 5 };
    inv.item.base_item = 7;
    inv.item.tag = try gpa.dupe(u8, "potion_heal");
    defer gpa.free(inv.item.tag);
    inv.item.template_res_ref = gff.ResRef.fromSlice("nw_it_mpotion001");
    inv.item.stack_size = 3;

    const idx = try g.addStruct(InventoryObject.STRUCT_ID);
    try inv.writeIntoGff(gpa, &g, idx);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try InventoryObject.fromGffStruct(arena.allocator(), &g, &g.structs.items[idx]);

    try t.expectEqual(@as(u8, 3), decoded.repos_pos_x);
    try t.expectEqual(@as(u8, 5), decoded.repos_pos_y);
    try t.expectEqual(@as(i32, 7), decoded.item.base_item);
    try t.expectEqualStrings("potion_heal", decoded.item.tag);
    try t.expectEqual(@as(u16, 3), decoded.item.stack_size);
}
