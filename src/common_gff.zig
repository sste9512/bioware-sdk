//! Common GFF Structures — BioWare Aurora Engine.
//!
//! Implements the shared sub-structures from Bioware_Aurora_CommonGFFStructs.pdf:
//!   §2  Location (StructID 1)
//!   §3  VarTable / Variable (StructID 0)
//!   §4  EffectsList / Effect (variable StructID)
//!   §5  EventQueue / Event (StructID 0xABCD)
//!   §6  ActionList / Action (StructID 0)
//!   §7  ScriptSituation and sub-structures
//!
//! None of these are standalone files; they are embedded in GFF resources
//! such as GIT, BIC, and saved games. All parsed heap allocations must be
//! backed by an arena allocator supplied by the caller.
//!
//! Undocumented EventData types (SpellScriptData, CombatAttackData,
//! BodyBagInfo, ForcedAction, ClientMessageData) are decoded as `.opaque`
//! and their payload is dropped on re-serialization — do not modify events
//! of those types and expect a clean round-trip.

const std = @import("std");
const gff = @import("gff.zig");

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
    InvalidVariableType,
    InvalidParameterType,
    InvalidStackElementType,
} || gff.FormatError || std.mem.Allocator.Error;

// ============================================================================
// Internal helpers
// ============================================================================

inline fn optByte(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u8) Error!u8 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .byte => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn optWord(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u16) Error!u16 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .word => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn optInt(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: i32) Error!i32 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .int => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn reqInt(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!i32 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .int => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn optFloat(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: f32) Error!f32 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .float => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn optDword(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u32) Error!u32 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .dword => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn reqDword(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!u32 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .dword => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn reqChar(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!i8 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .char => |v| v,
        else => error.WrongFieldType,
    };
}

fn optExoStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error![]u8 {
    const f = g.getField(s, l) orelse return a.dupe(u8, &.{});
    return switch (f.value) {
        .exo_string => |v| a.dupe(u8, v),
        else => error.WrongFieldType,
    };
}

fn reqExoStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error![]u8 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .exo_string => |v| a.dupe(u8, v),
        else => error.WrongFieldType,
    };
}

// ============================================================================
// §2 — Location Struct (StructID 1)
// ============================================================================

/// A world location: area reference, facing direction, and position.
/// GFF StructID 1.
pub const Location = struct {
    /// ObjectId of the area containing the location.
    area: u32 = 0,
    orientation_x: f32 = 0,
    orientation_y: f32 = 0,
    orientation_z: f32 = 0,
    position_x: f32 = 0,
    position_y: f32 = 0,
    position_z: f32 = 0,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!Location {
        return .{
            .area = try reqDword(g, s, "Area"),
            .orientation_x = try optFloat(g, s, "OrientationX", 0),
            .orientation_y = try optFloat(g, s, "OrientationY", 0),
            .orientation_z = try optFloat(g, s, "OrientationZ", 0),
            .position_x = try optFloat(g, s, "PositionX", 0),
            .position_y = try optFloat(g, s, "PositionY", 0),
            .position_z = try optFloat(g, s, "PositionZ", 0),
        };
    }

    pub fn writeIntoGff(self: *const Location, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Area", .{ .dword = self.area });
        try g.addFieldToStruct(struct_idx, "OrientationX", .{ .float = self.orientation_x });
        try g.addFieldToStruct(struct_idx, "OrientationY", .{ .float = self.orientation_y });
        try g.addFieldToStruct(struct_idx, "OrientationZ", .{ .float = self.orientation_z });
        try g.addFieldToStruct(struct_idx, "PositionX", .{ .float = self.position_x });
        try g.addFieldToStruct(struct_idx, "PositionY", .{ .float = self.position_y });
        try g.addFieldToStruct(struct_idx, "PositionZ", .{ .float = self.position_z });
    }
};

// ============================================================================
// §7 Sub-structures (declared before §3–§6 which reference them)
// ============================================================================

// §7 Table 7.5 — ScriptLocation (StructID 2, same fields as Location §2)
pub const ScriptLocation = struct {
    area: u32 = 0,
    orientation_x: f32 = 0,
    orientation_y: f32 = 0,
    orientation_z: f32 = 0,
    position_x: f32 = 0,
    position_y: f32 = 0,
    position_z: f32 = 0,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!ScriptLocation {
        return .{
            .area = try reqDword(g, s, "Area"),
            .orientation_x = try optFloat(g, s, "OrientationX", 0),
            .orientation_y = try optFloat(g, s, "OrientationY", 0),
            .orientation_z = try optFloat(g, s, "OrientationZ", 0),
            .position_x = try optFloat(g, s, "PositionX", 0),
            .position_y = try optFloat(g, s, "PositionY", 0),
            .position_z = try optFloat(g, s, "PositionZ", 0),
        };
    }

    pub fn writeIntoGff(self: *const ScriptLocation, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Area", .{ .dword = self.area });
        try g.addFieldToStruct(struct_idx, "OrientationX", .{ .float = self.orientation_x });
        try g.addFieldToStruct(struct_idx, "OrientationY", .{ .float = self.orientation_y });
        try g.addFieldToStruct(struct_idx, "OrientationZ", .{ .float = self.orientation_z });
        try g.addFieldToStruct(struct_idx, "PositionX", .{ .float = self.position_x });
        try g.addFieldToStruct(struct_idx, "PositionY", .{ .float = self.position_y });
        try g.addFieldToStruct(struct_idx, "PositionZ", .{ .float = self.position_z });
    }
};

// §7 Table 7.4 — ScriptEvent (StructID 1)
// All parameter sub-lists use StructID 105 with a "Parameter" field.
pub const ScriptEvent = struct {
    event_type: u16 = 0,
    int_params: []i32 = &.{},
    float_params: []f32 = &.{},
    string_params: [][]u8 = &.{},
    object_params: []u32 = &.{},

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!ScriptEvent {
        return .{
            .event_type = try optWord(g, s, "EventType", 0),
            .int_params = try parseParamListInt(arena, g, s),
            .float_params = try parseParamListFloat(arena, g, s),
            .string_params = try parseParamListString(arena, g, s),
            .object_params = try parseParamListObject(arena, g, s),
        };
    }

    pub fn writeIntoGff(self: *const ScriptEvent, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "EventType", .{ .word = self.event_type });
        try writeParamListInt(g, struct_idx, self.int_params);
        try writeParamListFloat(g, struct_idx, self.float_params);
        try writeParamListString(g, struct_idx, self.string_params);
        try writeParamListObject(g, struct_idx, self.object_params);
    }
};

fn parseParamListInt(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]i32 {
    const f = g.getField(s, "IntList") orelse return arena.alloc(i32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(i32, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optInt(g, &g.structs.items[idx], "Parameter", 0);
    return out;
}

fn parseParamListFloat(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]f32 {
    const f = g.getField(s, "FloatList") orelse return arena.alloc(f32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(f32, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optFloat(g, &g.structs.items[idx], "Parameter", 0);
    return out;
}

fn parseParamListString(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![][]u8 {
    const f = g.getField(s, "StringList") orelse return arena.alloc([]u8, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc([]u8, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optExoStringDupe(arena, g, &g.structs.items[idx], "Parameter");
    return out;
}

fn parseParamListObject(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]u32 {
    const f = g.getField(s, "ObjectList") orelse return arena.alloc(u32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(u32, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optDword(g, &g.structs.items[idx], "Parameter", 0);
    return out;
}

fn writeParamListInt(g: *gff.GffFile, parent_idx: u32, vals: []const i32) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(105);
        try g.addFieldToStruct(si, "Parameter", .{ .int = v });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "IntList", .{ .list = arr });
}

fn writeParamListFloat(g: *gff.GffFile, parent_idx: u32, vals: []const f32) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(105);
        try g.addFieldToStruct(si, "Parameter", .{ .float = v });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "FloatList", .{ .list = arr });
}

fn writeParamListString(g: *gff.GffFile, parent_idx: u32, vals: []const []u8) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(105);
        try g.addFieldToStruct(si, "Parameter", .{ .exo_string = try g.allocator.dupe(u8, v) });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "StringList", .{ .list = arr });
}

fn writeParamListObject(g: *gff.GffFile, parent_idx: u32, vals: []const u32) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(105);
        try g.addFieldToStruct(si, "Parameter", .{ .dword = v });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "ObjectList", .{ .list = arr });
}

// §7 Table 7.6 — ScriptTalent (StructID 3)
pub const ScriptTalent = struct {
    id: i32 = 0,
    type: i32 = 0,
    multi_class: u8 = 0,
    item: u32 = 0,
    item_property_index: i32 = 0,
    caster_level: u8 = 0,
    meta_type: u8 = 0,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!ScriptTalent {
        return .{
            .id = try optInt(g, s, "ID", 0),
            .type = try optInt(g, s, "Type", 0),
            .multi_class = try optByte(g, s, "MultiClass", 0),
            .item = try optDword(g, s, "Item", 0),
            .item_property_index = try optInt(g, s, "ItemPropertyIndex", 0),
            .caster_level = try optByte(g, s, "CasterLevel", 0),
            .meta_type = try optByte(g, s, "MetaType", 0),
        };
    }

    pub fn writeIntoGff(self: *const ScriptTalent, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "ID", .{ .int = self.id });
        try g.addFieldToStruct(struct_idx, "Type", .{ .int = self.type });
        try g.addFieldToStruct(struct_idx, "MultiClass", .{ .byte = self.multi_class });
        try g.addFieldToStruct(struct_idx, "Item", .{ .dword = self.item });
        try g.addFieldToStruct(struct_idx, "ItemPropertyIndex", .{ .int = self.item_property_index });
        try g.addFieldToStruct(struct_idx, "CasterLevel", .{ .byte = self.caster_level });
        try g.addFieldToStruct(struct_idx, "MetaType", .{ .byte = self.meta_type });
    }
};

// ============================================================================
// §4 — Effect Struct (variable StructID)
// ============================================================================

/// An active effect on a game object.
/// `struct_id` is preserved from the source GFF so round-trips are lossless.
pub const Effect = struct {
    /// Preserved on parse; written back on serialize. Defaults to 0.
    struct_id: u32 = 0,
    creator_id: u32 = 0,
    duration: f32 = 0,
    expire_day: u32 = 0,
    expire_time: u32 = 0,
    is_exposed: i32 = 0,
    is_icon_shown: i32 = 0,
    num_integers: i32 = 0,
    skip_on_load: u8 = 0,
    spell_id: u32 = 0,
    sub_type: u16 = 0,
    effect_type: u16 = 0,
    float_params: []f32 = &.{},
    int_params: []i32 = &.{},
    object_params: []u32 = &.{},
    string_params: [][]u8 = &.{},

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Effect {
        return .{
            .struct_id = s.type_id,
            .creator_id = try optDword(g, s, "CreatorId", 0),
            .duration = try optFloat(g, s, "Duration", 0),
            .expire_day = try optDword(g, s, "ExpireDay", 0),
            .expire_time = try optDword(g, s, "ExpireTime", 0),
            .is_exposed = try optInt(g, s, "IsExposed", 0),
            .is_icon_shown = try optInt(g, s, "IsIconShown", 0),
            .num_integers = try optInt(g, s, "NumIntegers", 0),
            .skip_on_load = try optByte(g, s, "SkipOnLoad", 0),
            .spell_id = try optDword(g, s, "SpellId", 0),
            .sub_type = try optWord(g, s, "SubType", 0),
            .effect_type = try optWord(g, s, "Type", 0),
            .float_params = try parseEffectFloatList(arena, g, s),
            .int_params = try parseEffectIntList(arena, g, s),
            .object_params = try parseEffectObjectList(arena, g, s),
            .string_params = try parseEffectStringList(arena, g, s),
        };
    }

    pub fn writeIntoGff(self: *const Effect, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "CreatorId", .{ .dword = self.creator_id });
        try g.addFieldToStruct(struct_idx, "Duration", .{ .float = self.duration });
        try g.addFieldToStruct(struct_idx, "ExpireDay", .{ .dword = self.expire_day });
        try g.addFieldToStruct(struct_idx, "ExpireTime", .{ .dword = self.expire_time });
        try g.addFieldToStruct(struct_idx, "IsExposed", .{ .int = self.is_exposed });
        try g.addFieldToStruct(struct_idx, "IsIconShown", .{ .int = self.is_icon_shown });
        try g.addFieldToStruct(struct_idx, "NumIntegers", .{ .int = self.num_integers });
        try g.addFieldToStruct(struct_idx, "SkipOnLoad", .{ .byte = self.skip_on_load });
        try g.addFieldToStruct(struct_idx, "SpellId", .{ .dword = self.spell_id });
        try g.addFieldToStruct(struct_idx, "SubType", .{ .word = self.sub_type });
        try g.addFieldToStruct(struct_idx, "Type", .{ .word = self.effect_type });
        try writeEffectFloatList(g, struct_idx, self.float_params);
        try writeEffectIntList(g, struct_idx, self.int_params);
        try writeEffectObjectList(g, struct_idx, self.object_params);
        try writeEffectStringList(g, struct_idx, self.string_params);
    }
};

fn parseEffectFloatList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]f32 {
    const f = g.getField(s, "FloatList") orelse return arena.alloc(f32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(f32, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optFloat(g, &g.structs.items[idx], "Value", 0);
    return out;
}

fn parseEffectIntList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]i32 {
    const f = g.getField(s, "IntList") orelse return arena.alloc(i32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(i32, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optInt(g, &g.structs.items[idx], "Value", 0);
    return out;
}

fn parseEffectObjectList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]u32 {
    const f = g.getField(s, "ObjectList") orelse return arena.alloc(u32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(u32, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optDword(g, &g.structs.items[idx], "Value", 0);
    return out;
}

fn parseEffectStringList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![][]u8 {
    const f = g.getField(s, "StringList") orelse return arena.alloc([]u8, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc([]u8, arr.len);
    for (arr, 0..) |idx, i| out[i] = try optExoStringDupe(arena, g, &g.structs.items[idx], "Value");
    return out;
}

fn writeEffectFloatList(g: *gff.GffFile, parent_idx: u32, vals: []const f32) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(4); // StructID 4
        try g.addFieldToStruct(si, "Value", .{ .float = v });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "FloatList", .{ .list = arr });
}

fn writeEffectIntList(g: *gff.GffFile, parent_idx: u32, vals: []const i32) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(3); // StructID 3
        try g.addFieldToStruct(si, "Value", .{ .int = v });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "IntList", .{ .list = arr });
}

fn writeEffectObjectList(g: *gff.GffFile, parent_idx: u32, vals: []const u32) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(6); // StructID 6
        try g.addFieldToStruct(si, "Value", .{ .dword = v });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "ObjectList", .{ .list = arr });
}

fn writeEffectStringList(g: *gff.GffFile, parent_idx: u32, vals: []const []u8) !void {
    if (vals.len == 0) return;
    const arr = try g.allocator.alloc(u32, vals.len);
    errdefer g.allocator.free(arr);
    for (vals, 0..) |v, i| {
        const si = try g.addStruct(5); // StructID 5
        try g.addFieldToStruct(si, "Value", .{ .exo_string = try g.allocator.dupe(u8, v) });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "StringList", .{ .list = arr });
}

/// Parse an EffectsList GFF List from a parent struct into a slice.
pub fn parseEffectsList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]Effect {
    const f = g.getField(s, "EffectList") orelse return arena.alloc(Effect, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Effect, arr.len);
    for (arr, 0..) |idx, i| out[i] = try Effect.fromGffStruct(arena, g, &g.structs.items[idx]);
    return out;
}

/// Write a slice of Effects as an EffectsList GFF List into `parent_idx`.
pub fn writeEffectsList(g: *gff.GffFile, parent_idx: u32, effects: []const Effect) !void {
    if (effects.len == 0) return;
    const arr = try g.allocator.alloc(u32, effects.len);
    errdefer g.allocator.free(arr);
    for (effects, 0..) |*e, i| {
        const si = try g.addStruct(e.struct_id);
        try e.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "EffectList", .{ .list = arr });
}

// ============================================================================
// §7 — StackElement, StackStruct, ScriptSituation
// ============================================================================

/// One element on the NWScript virtual machine stack.
/// The active tag determines the GFF Type code (see §7 Table 7.3b).
pub const StackElement = union(enum) {
    int_val: i32,
    float_val: f32,
    string_val: []u8,
    object_val: u32,
    effect: Effect,
    script_event: ScriptEvent,
    script_location: ScriptLocation,
    script_talent: ScriptTalent,
    item_property: Effect, // same GFF layout as Effect, StructID 4

    pub fn typeId(self: StackElement) i8 {
        return switch (self) {
            .int_val => 3,
            .float_val => 4,
            .string_val => 5,
            .object_val => 6,
            .effect => 10,
            .script_event => 11,
            .script_location => 12,
            .script_talent => 13,
            .item_property => 14,
        };
    }

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!StackElement {
        const tid = try reqChar(g, s, "Type");
        return switch (tid) {
            3 => .{ .int_val = try reqInt(g, s, "Value") },
            4 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                break :blk .{ .float_val = switch (f.value) {
                    .float => |v| v,
                    else => return error.WrongFieldType,
                } };
            },
            5 => .{ .string_val = try reqExoStringDupe(arena, g, s, "Value") },
            6 => .{ .object_val = try reqDword(g, s, "Value") },
            10 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .effect = try Effect.fromGffStruct(arena, g, &g.structs.items[idx]) };
            },
            11 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .script_event = try ScriptEvent.fromGffStruct(arena, g, &g.structs.items[idx]) };
            },
            12 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .script_location = try ScriptLocation.fromGffStruct(g, &g.structs.items[idx]) };
            },
            13 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .script_talent = try ScriptTalent.fromGffStruct(g, &g.structs.items[idx]) };
            },
            14 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .item_property = try Effect.fromGffStruct(arena, g, &g.structs.items[idx]) };
            },
            else => error.InvalidStackElementType,
        };
    }

    /// Write into an already-created struct at `struct_idx`.
    pub fn writeIntoGff(self: *const StackElement, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Type", .{ .char = self.typeId() });
        switch (self.*) {
            .int_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .int = v }),
            .float_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .float = v }),
            .string_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .exo_string = try g.allocator.dupe(u8, v) }),
            .object_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .dword = v }),
            .effect => |*e| {
                const si = try g.addStruct(0); // game engine StructID 0
                try e.writeIntoGff(g, si);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = si });
            },
            .script_event => |*se| {
                const si = try g.addStruct(1); // game engine StructID 1
                try se.writeIntoGff(g, si);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = si });
            },
            .script_location => |*sl| {
                const si = try g.addStruct(2); // game engine StructID 2
                try sl.writeIntoGff(g, si);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = si });
            },
            .script_talent => |*st| {
                const si = try g.addStruct(3); // game engine StructID 3
                try st.writeIntoGff(g, si);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = si });
            },
            .item_property => |*e| {
                const si = try g.addStruct(4); // game engine StructID 4
                try e.writeIntoGff(g, si);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = si });
            },
        }
    }
};

/// The NWScript virtual machine stack (§7 Table 7.2, StructID 0).
pub const StackStruct = struct {
    base_pointer: i32 = 0,
    stack_pointer: i32 = 0,
    total_size: i32 = 0,
    elements: []StackElement = &.{},

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!StackStruct {
        var out: StackStruct = .{
            .base_pointer = try optInt(g, s, "BasePointer", 0),
            .stack_pointer = try optInt(g, s, "StackPointer", 0),
            .total_size = try optInt(g, s, "TotalSize", 0),
        };
        const f = g.getField(s, "Stack") orelse return out;
        const arr = switch (f.value) {
            .list => |v| v,
            else => return error.WrongFieldType,
        };
        out.elements = try arena.alloc(StackElement, arr.len);
        for (arr, 0..) |idx, i| {
            out.elements[i] = try StackElement.fromGffStruct(arena, g, &g.structs.items[idx]);
        }
        return out;
    }

    pub fn writeIntoGff(self: *const StackStruct, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "BasePointer", .{ .int = self.base_pointer });
        try g.addFieldToStruct(struct_idx, "StackPointer", .{ .int = self.stack_pointer });
        try g.addFieldToStruct(struct_idx, "TotalSize", .{ .int = self.total_size });
        if (self.elements.len == 0) return;
        const arr = try g.allocator.alloc(u32, self.elements.len);
        errdefer g.allocator.free(arr);
        for (self.elements, 0..) |*elem, i| {
            // StructID of each stack element equals its index in the list (§7 Table 7.2).
            const si = try g.addStruct(@intCast(i));
            try elem.writeIntoGff(g, si);
            arr[i] = si;
        }
        try g.addFieldToStruct(struct_idx, "Stack", .{ .list = arr });
    }
};

/// NWScript virtual machine continuation (§7 Table 7.1, variable StructID).
/// `struct_id` is preserved for lossless round-trips; the spec recommends
/// writing this structure back exactly as it was read.
pub const ScriptSituation = struct {
    struct_id: u32 = 0,
    code_size: i32 = 0,
    code: []u8 = &.{},
    instruction_ptr: i32 = 0,
    secondary_ptr: i32 = 0,
    name: []u8 = &.{},
    stack_size: i32 = 0,
    stack: StackStruct = .{},

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!ScriptSituation {
        var out: ScriptSituation = .{
            .struct_id = s.type_id,
            .code_size = try optInt(g, s, "CodeSize", 0),
            .instruction_ptr = try optInt(g, s, "InstructionPtr", 0),
            .secondary_ptr = try optInt(g, s, "SecondaryPtr", 0),
            .stack_size = try optInt(g, s, "StackSize", 0),
            .name = try optExoStringDupe(arena, g, s, "Name"),
        };
        // Code is stored as a VOID blob.
        if (g.getField(s, "Code")) |cf| {
            out.code = switch (cf.value) {
                .void_data => |v| try arena.dupe(u8, v),
                else => return error.WrongFieldType,
            };
        }
        // Stack sub-struct.
        if (g.getField(s, "Stack")) |sf| {
            const idx = switch (sf.value) {
                .@"struct" => |v| v,
                else => return error.WrongFieldType,
            };
            out.stack = try StackStruct.fromGffStruct(arena, g, &g.structs.items[idx]);
        }
        return out;
    }

    pub fn writeIntoGff(self: *const ScriptSituation, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "CodeSize", .{ .int = self.code_size });
        try g.addFieldToStruct(struct_idx, "Code", .{ .void_data = try g.allocator.dupe(u8, self.code) });
        try g.addFieldToStruct(struct_idx, "InstructionPtr", .{ .int = self.instruction_ptr });
        try g.addFieldToStruct(struct_idx, "SecondaryPtr", .{ .int = self.secondary_ptr });
        try g.addFieldToStruct(struct_idx, "Name", .{ .exo_string = try g.allocator.dupe(u8, self.name) });
        try g.addFieldToStruct(struct_idx, "StackSize", .{ .int = self.stack_size });
        const stack_idx = try g.addStruct(0); // StackStruct StructID 0
        try self.stack.writeIntoGff(g, stack_idx);
        try g.addFieldToStruct(struct_idx, "Stack", .{ .@"struct" = stack_idx });
    }
};

// ============================================================================
// §3 — VarTable / Variable Struct (StructID 0)
// ============================================================================

/// Tagged value of a scripting variable (§3 Table 3.2).
pub const VariableValue = union(enum) {
    int_val: i32,
    float_val: f32,
    string_val: []u8,
    object_val: u32,
    location_val: Location,
};

/// One scripting variable from a VarTable list.
pub const Variable = struct {
    name: []u8,
    value: VariableValue,

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Variable {
        const name = try reqExoStringDupe(arena, g, s, "Name");
        const type_id = try reqDword(g, s, "Type");
        const value: VariableValue = switch (type_id) {
            1 => .{ .int_val = try reqInt(g, s, "Value") },
            2 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                break :blk .{ .float_val = switch (f.value) {
                    .float => |v| v,
                    else => return error.WrongFieldType,
                } };
            },
            3 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                break :blk .{ .string_val = switch (f.value) {
                    .exo_string => |v| try arena.dupe(u8, v),
                    else => return error.WrongFieldType,
                } };
            },
            4 => .{ .object_val = try reqDword(g, s, "Value") },
            5 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .location_val = try Location.fromGffStruct(g, &g.structs.items[idx]) };
            },
            else => return error.InvalidVariableType,
        };
        return .{ .name = name, .value = value };
    }

    pub fn writeIntoGff(self: *const Variable, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Name", .{ .exo_string = try g.allocator.dupe(u8, self.name) });
        const type_id: u32 = switch (self.value) {
            .int_val => 1,
            .float_val => 2,
            .string_val => 3,
            .object_val => 4,
            .location_val => 5,
        };
        try g.addFieldToStruct(struct_idx, "Type", .{ .dword = type_id });
        switch (self.value) {
            .int_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .int = v }),
            .float_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .float = v }),
            .string_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{
                .exo_string = try g.allocator.dupe(u8, v),
            }),
            .object_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .dword = v }),
            .location_val => |*loc| {
                const loc_idx = try g.addStruct(1); // Location StructID 1
                try loc.writeIntoGff(g, loc_idx);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = loc_idx });
            },
        }
    }
};

/// Parse a `VarTable` GFF List from `parent` into an arena-backed slice.
pub fn parseVarTable(arena: std.mem.Allocator, g: *const gff.GffFile, parent: *const gff.Struct) Error![]Variable {
    const f = g.getField(parent, "VarTable") orelse return arena.alloc(Variable, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Variable, arr.len);
    for (arr, 0..) |idx, i| out[i] = try Variable.fromGffStruct(arena, g, &g.structs.items[idx]);
    return out;
}

/// Write `vars` as a `VarTable` GFF List into `parent_idx`.
pub fn writeVarTable(g: *gff.GffFile, parent_idx: u32, vars: []const Variable) !void {
    if (vars.len == 0) return;
    const arr = try g.allocator.alloc(u32, vars.len);
    errdefer g.allocator.free(arr);
    for (vars, 0..) |*v, i| {
        const si = try g.addStruct(0); // Variable StructID 0
        try v.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "VarTable", .{ .list = arr });
}

// ============================================================================
// §5 — EventQueue / Event Struct (StructID 0xABCD)
// ============================================================================

/// EventData payload — covers all documented EventId types.
/// Undocumented types (SpellScriptData, CombatAttackData, etc.) decode to
/// `.opaque` and their GFF payload is not preserved on re-serialization.
pub const EventData = union(enum) {
    none,
    /// EventId 1 — TIMED_EVENT
    script_situation: ScriptSituation,
    /// EventId 4 — REMOVE_FROM_AREA (single BYTE "Value")
    byte_value: u8,
    /// EventId 5, 14 — APPLY_EFFECT / REMOVE_EFFECT
    effect: Effect,
    /// EventId 9 — PLAY_ANIMATION (single INT "Value")
    int_value: i32,
    /// EventId 10, 24 — SIGNAL_EVENT / SUMMON_CREATURE
    script_event: ScriptEvent,
    /// EventId 20 — BROADCAST_AOO (single DWORD "Value")
    dword_value: u32,
    /// EventIds 8, 15, 17, 18, 19, 21, 22 — undocumented; payload dropped on write.
    unknown,
};

/// Returns the GFF StructID used for EventData of the given EventId (§5 Table 5.2).
fn eventDataStructId(event_id: u32) u32 {
    return switch (event_id) {
        1 => 0x7777,
        4 => 0x9999,
        5, 14 => 0x1111,
        8, 19 => 0x6666,
        9 => 0x3333,
        10 => 0x4444,
        15, 21 => 0x2222,
        17 => 0x5555,
        18 => 0x8888,
        20 => 0xAAAA,
        22 => 0xCCCC,
        24 => 0xDDDD,
        else => 0,
    };
}

pub const Event = struct {
    caller_id: u32 = 0,
    day: u32 = 0,
    event_id: u32 = 0,
    object_id: u32 = 0,
    time: u32 = 0,
    data: EventData = .none,

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Event {
        const event_id = try optDword(g, s, "EventId", 0);
        const data = try decodeEventData(arena, g, s, event_id);
        return .{
            .caller_id = try optDword(g, s, "CallerId", 0),
            .day = try optDword(g, s, "Day", 0),
            .event_id = event_id,
            .object_id = try optDword(g, s, "ObjectId", 0),
            .time = try optDword(g, s, "Time", 0),
            .data = data,
        };
    }

    pub fn writeIntoGff(self: *const Event, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "CallerId", .{ .dword = self.caller_id });
        try g.addFieldToStruct(struct_idx, "Day", .{ .dword = self.day });
        try g.addFieldToStruct(struct_idx, "EventId", .{ .dword = self.event_id });
        try g.addFieldToStruct(struct_idx, "ObjectId", .{ .dword = self.object_id });
        try g.addFieldToStruct(struct_idx, "Time", .{ .dword = self.time });
        try writeEventData(g, struct_idx, self.event_id, self.data);
    }
};

fn decodeEventData(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, event_id: u32) Error!EventData {
    // Events with no EventData field.
    switch (event_id) {
        2, 3, 6, 7, 11, 12, 13, 16, 23, 25 => return .none,
        else => {},
    }
    const f = g.getField(s, "EventData") orelse return .none;
    const idx = switch (f.value) {
        .@"struct" => |v| v,
        else => return error.WrongFieldType,
    };
    const ds = &g.structs.items[idx];
    return switch (event_id) {
        1 => .{ .script_situation = try ScriptSituation.fromGffStruct(arena, g, ds) },
        4 => .{ .byte_value = try optByte(g, ds, "Value", 0) },
        5, 14 => .{ .effect = try Effect.fromGffStruct(arena, g, ds) },
        9 => .{ .int_value = try optInt(g, ds, "Value", 0) },
        10, 24 => .{ .script_event = try ScriptEvent.fromGffStruct(arena, g, ds) },
        20 => .{ .dword_value = try optDword(g, ds, "Value", 0) },
        else => .unknown, // 8, 15, 17, 18, 19, 21, 22 — undocumented
    };
}

fn writeEventData(g: *gff.GffFile, parent_idx: u32, event_id: u32, data: EventData) !void {
    const sid = eventDataStructId(event_id);
    switch (data) {
        .none, .unknown => return,
        .byte_value => |v| {
            const si = try g.addStruct(sid);
            try g.addFieldToStruct(si, "Value", .{ .byte = v });
            try g.addFieldToStruct(parent_idx, "EventData", .{ .@"struct" = si });
        },
        .int_value => |v| {
            const si = try g.addStruct(sid);
            try g.addFieldToStruct(si, "Value", .{ .int = v });
            try g.addFieldToStruct(parent_idx, "EventData", .{ .@"struct" = si });
        },
        .dword_value => |v| {
            const si = try g.addStruct(sid);
            try g.addFieldToStruct(si, "Value", .{ .dword = v });
            try g.addFieldToStruct(parent_idx, "EventData", .{ .@"struct" = si });
        },
        .effect => |*e| {
            const si = try g.addStruct(sid);
            try e.writeIntoGff(g, si);
            try g.addFieldToStruct(parent_idx, "EventData", .{ .@"struct" = si });
        },
        .script_event => |*se| {
            const si = try g.addStruct(sid);
            try se.writeIntoGff(g, si);
            try g.addFieldToStruct(parent_idx, "EventData", .{ .@"struct" = si });
        },
        .script_situation => |*ss| {
            const si = try g.addStruct(sid);
            try ss.writeIntoGff(g, si);
            try g.addFieldToStruct(parent_idx, "EventData", .{ .@"struct" = si });
        },
    }
}

/// Parse an `EventQueue` GFF List from `parent` into an arena-backed slice.
pub fn parseEventQueue(arena: std.mem.Allocator, g: *const gff.GffFile, parent: *const gff.Struct) Error![]Event {
    const f = g.getField(parent, "EventQueue") orelse return arena.alloc(Event, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Event, arr.len);
    for (arr, 0..) |idx, i| out[i] = try Event.fromGffStruct(arena, g, &g.structs.items[idx]);
    return out;
}

/// Write `events` as an `EventQueue` GFF List into `parent_idx`.
pub fn writeEventQueue(g: *gff.GffFile, parent_idx: u32, events: []const Event) !void {
    if (events.len == 0) return;
    const arr = try g.allocator.alloc(u32, events.len);
    errdefer g.allocator.free(arr);
    for (events, 0..) |*ev, i| {
        const si = try g.addStruct(0xABCD); // Event StructID
        try ev.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "EventQueue", .{ .list = arr });
}

// ============================================================================
// §6 — ActionList / Action Struct (StructID 0)
// ============================================================================

/// Tagged value of an Action parameter (§6 Table 6.3).
pub const ParameterValue = union(enum) {
    int_val: i32,
    float_val: f32,
    object_val: u32,
    string_val: []u8,
    script_situation: ScriptSituation,
};

/// One parameter in an Action's parameter list (StructID 1).
pub const Parameter = struct {
    value: ParameterValue,

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Parameter {
        const type_id = try reqDword(g, s, "Type");
        const value: ParameterValue = switch (type_id) {
            1 => .{ .int_val = try reqInt(g, s, "Value") },
            2 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                break :blk .{ .float_val = switch (f.value) {
                    .float => |v| v,
                    else => return error.WrongFieldType,
                } };
            },
            3 => .{ .object_val = try reqDword(g, s, "Value") },
            4 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                break :blk .{ .string_val = switch (f.value) {
                    .exo_string => |v| try arena.dupe(u8, v),
                    else => return error.WrongFieldType,
                } };
            },
            5 => blk: {
                const f = g.getField(s, "Value") orelse return error.MissingRequiredField;
                const idx = switch (f.value) {
                    .@"struct" => |v| v,
                    else => return error.WrongFieldType,
                };
                break :blk .{ .script_situation = try ScriptSituation.fromGffStruct(arena, g, &g.structs.items[idx]) };
            },
            else => return error.InvalidParameterType,
        };
        return .{ .value = value };
    }

    pub fn writeIntoGff(self: *const Parameter, g: *gff.GffFile, struct_idx: u32) !void {
        const type_id: u32 = switch (self.value) {
            .int_val => 1,
            .float_val => 2,
            .object_val => 3,
            .string_val => 4,
            .script_situation => 5,
        };
        try g.addFieldToStruct(struct_idx, "Type", .{ .dword = type_id });
        switch (self.value) {
            .int_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .int = v }),
            .float_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .float = v }),
            .object_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{ .dword = v }),
            .string_val => |v| try g.addFieldToStruct(struct_idx, "Value", .{
                .exo_string = try g.allocator.dupe(u8, v),
            }),
            .script_situation => |*ss| {
                const si = try g.addStruct(2); // ScriptSituation StructID 2 per §6 Table 6.3
                try ss.writeIntoGff(g, si);
                try g.addFieldToStruct(struct_idx, "Value", .{ .@"struct" = si });
            },
        }
    }
};

/// A queued game-object action (§6 Table 6.1, StructID 0).
/// Note: the GFF field name "Paramaters" is intentionally misspelled (spec §6).
pub const Action = struct {
    action_id: u32 = 0,
    group_action_id: u16 = 0,
    parameters: []Parameter = &.{},

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Action {
        const num_params = try optWord(g, s, "NumParams", 0);
        var params = try arena.alloc(Parameter, 0);
        if (num_params > 0) {
            const f = g.getField(s, "Paramaters") orelse return error.MissingRequiredField;
            const arr = switch (f.value) {
                .list => |v| v,
                else => return error.WrongFieldType,
            };
            params = try arena.alloc(Parameter, arr.len);
            for (arr, 0..) |idx, i| {
                params[i] = try Parameter.fromGffStruct(arena, g, &g.structs.items[idx]);
            }
        }
        return .{
            .action_id = try optDword(g, s, "ActionId", 0),
            .group_action_id = try optWord(g, s, "GroupActionId", 0),
            .parameters = params,
        };
    }

    pub fn writeIntoGff(self: *const Action, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "ActionId", .{ .dword = self.action_id });
        try g.addFieldToStruct(struct_idx, "GroupActionId", .{ .word = self.group_action_id });
        try g.addFieldToStruct(struct_idx, "NumParams", .{ .word = @intCast(self.parameters.len) });
        if (self.parameters.len == 0) return;
        const arr = try g.allocator.alloc(u32, self.parameters.len);
        errdefer g.allocator.free(arr);
        for (self.parameters, 0..) |*p, i| {
            const si = try g.addStruct(1); // Parameter StructID 1
            try p.writeIntoGff(g, si);
            arr[i] = si;
        }
        // Intentional misspelling: "Paramaters" — matches the GFF spec (§6).
        try g.addFieldToStruct(struct_idx, "Paramaters", .{ .list = arr });
    }
};

/// Parse an `ActionList` GFF List from `parent` into an arena-backed slice.
pub fn parseActionList(arena: std.mem.Allocator, g: *const gff.GffFile, parent: *const gff.Struct) Error![]Action {
    const f = g.getField(parent, "ActionList") orelse return arena.alloc(Action, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Action, arr.len);
    for (arr, 0..) |idx, i| out[i] = try Action.fromGffStruct(arena, g, &g.structs.items[idx]);
    return out;
}

/// Write `actions` as an `ActionList` GFF List into `parent_idx`.
pub fn writeActionList(g: *gff.GffFile, parent_idx: u32, actions: []const Action) !void {
    if (actions.len == 0) return;
    const arr = try g.allocator.alloc(u32, actions.len);
    errdefer g.allocator.free(arr);
    for (actions, 0..) |*a, i| {
        const si = try g.addStruct(0); // Action StructID 0
        try a.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "ActionList", .{ .list = arr });
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "Location round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    const loc = Location{
        .area = 0xDEAD,
        .orientation_x = 1.0,
        .orientation_y = 0.0,
        .orientation_z = 0.0,
        .position_x = 10.5,
        .position_y = -3.25,
        .position_z = 0.0,
    };
    const loc_idx = try g.addStruct(1);
    try loc.writeIntoGff(&g, loc_idx);
    try g.addFieldToStruct(0, "Loc", .{ .@"struct" = loc_idx });

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    const tl = &g2.structs.items[0];
    const f = g2.getField(tl, "Loc").?;
    const parsed = try Location.fromGffStruct(&g2, &g2.structs.items[f.value.@"struct"]);

    try t.expectEqual(@as(u32, 0xDEAD), parsed.area);
    try t.expectApproxEqAbs(@as(f32, 10.5), parsed.position_x, 1e-5);
    try t.expectApproxEqAbs(@as(f32, -3.25), parsed.position_y, 1e-5);
}

test "VarTable round-trip (all types)" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const vars = try a.alloc(Variable, 5);
    vars[0] = .{ .name = try a.dupe(u8, "MyInt"), .value = .{ .int_val = -42 } };
    vars[1] = .{ .name = try a.dupe(u8, "MyFloat"), .value = .{ .float_val = 3.14 } };
    vars[2] = .{ .name = try a.dupe(u8, "MyString"), .value = .{ .string_val = try a.dupe(u8, "hello") } };
    vars[3] = .{ .name = try a.dupe(u8, "MyObj"), .value = .{ .object_val = 0xCAFE } };
    vars[4] = .{ .name = try a.dupe(u8, "MyLoc"), .value = .{ .location_val = .{
        .area = 7,
        .position_x = 1.0,
        .position_y = 2.0,
        .position_z = 3.0,
        .orientation_x = 0,
        .orientation_y = 1,
        .orientation_z = 0,
    } } };

    try writeVarTable(&g, 0, vars);

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const out = try parseVarTable(arena2.allocator(), &g2, &g2.structs.items[0]);
    try t.expectEqual(@as(usize, 5), out.len);
    try t.expectEqualStrings("MyInt", out[0].name);
    try t.expectEqual(@as(i32, -42), out[0].value.int_val);
    try t.expectEqualStrings("MyFloat", out[1].name);
    try t.expectApproxEqAbs(@as(f32, 3.14), out[1].value.float_val, 1e-5);
    try t.expectEqualStrings("MyString", out[2].name);
    try t.expectEqualStrings("hello", out[2].value.string_val);
    try t.expectEqualStrings("MyObj", out[3].name);
    try t.expectEqual(@as(u32, 0xCAFE), out[3].value.object_val);
    try t.expectEqualStrings("MyLoc", out[4].name);
    try t.expectEqual(@as(u32, 7), out[4].value.location_val.area);
    try t.expectApproxEqAbs(@as(f32, 1.0), out[4].value.location_val.position_x, 1e-5);
}

test "Effect round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const floats = try a.dupe(f32, &.{ 1.5, 2.5 });
    const ints = try a.dupe(i32, &.{ 10, 20, 30 });
    const objs = try a.dupe(u32, &.{0xABCD});
    const strs = try a.alloc([]u8, 1);
    strs[0] = try a.dupe(u8, "fire");

    const eff = Effect{
        .struct_id = 99,
        .creator_id = 5,
        .duration = 12.0,
        .effect_type = 3,
        .sub_type = 1,
        .float_params = floats,
        .int_params = ints,
        .object_params = objs,
        .string_params = strs,
    };

    const effects = try a.alloc(Effect, 1);
    effects[0] = eff;
    try writeEffectsList(&g, 0, effects);

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const out = try parseEffectsList(arena2.allocator(), &g2, &g2.structs.items[0]);
    try t.expectEqual(@as(usize, 1), out.len);
    const e = &out[0];
    try t.expectEqual(@as(u32, 99), e.struct_id);
    try t.expectEqual(@as(u32, 5), e.creator_id);
    try t.expectApproxEqAbs(@as(f32, 12.0), e.duration, 1e-5);
    try t.expectEqual(@as(u16, 3), e.effect_type);
    try t.expectEqual(@as(u16, 1), e.sub_type);
    try t.expectEqual(@as(usize, 2), e.float_params.len);
    try t.expectApproxEqAbs(@as(f32, 1.5), e.float_params[0], 1e-5);
    try t.expectEqual(@as(usize, 3), e.int_params.len);
    try t.expectEqual(@as(i32, 20), e.int_params[1]);
    try t.expectEqual(@as(u32, 0xABCD), e.object_params[0]);
    try t.expectEqualStrings("fire", e.string_params[0]);
}

test "ActionList round-trip (int and string params)" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const params = try a.alloc(Parameter, 2);
    params[0] = .{ .value = .{ .int_val = 7 } };
    params[1] = .{ .value = .{ .string_val = try a.dupe(u8, "run") } };

    const actions = try a.alloc(Action, 1);
    actions[0] = .{ .action_id = 42, .group_action_id = 3, .parameters = params };

    try writeActionList(&g, 0, actions);

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const out = try parseActionList(arena2.allocator(), &g2, &g2.structs.items[0]);
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqual(@as(u32, 42), out[0].action_id);
    try t.expectEqual(@as(u16, 3), out[0].group_action_id);
    try t.expectEqual(@as(usize, 2), out[0].parameters.len);
    try t.expectEqual(@as(i32, 7), out[0].parameters[0].value.int_val);
    try t.expectEqualStrings("run", out[0].parameters[1].value.string_val);
}

test "ScriptSituation round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const code = try a.dupe(u8, "\x01\x02\x03\x04");
    const elems = try a.alloc(StackElement, 2);
    elems[0] = .{ .int_val = 99 };
    elems[1] = .{ .float_val = 1.5 };

    const ss = ScriptSituation{
        .struct_id = 0x7777,
        .code_size = 4,
        .code = code,
        .instruction_ptr = 2,
        .secondary_ptr = 0,
        .name = try a.dupe(u8, "my_script"),
        .stack_size = 8,
        .stack = .{
            .base_pointer = 0,
            .stack_pointer = 2,
            .total_size = 8,
            .elements = elems,
        },
    };

    const si = try g.addStruct(0x7777);
    try ss.writeIntoGff(&g, si);
    try g.addFieldToStruct(0, "SS", .{ .@"struct" = si });

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const tl = &g2.structs.items[0];
    const ssf = g2.getField(tl, "SS").?;
    const parsed = try ScriptSituation.fromGffStruct(arena2.allocator(), &g2, &g2.structs.items[ssf.value.@"struct"]);

    try t.expectEqual(@as(i32, 4), parsed.code_size);
    try t.expectEqual(@as(i32, 2), parsed.instruction_ptr);
    try t.expectEqualStrings("my_script", parsed.name);
    try t.expectEqualSlices(u8, "\x01\x02\x03\x04", parsed.code);
    try t.expectEqual(@as(usize, 2), parsed.stack.elements.len);
    try t.expectEqual(@as(i32, 99), parsed.stack.elements[0].int_val);
    try t.expectApproxEqAbs(@as(f32, 1.5), parsed.stack.elements[1].float_val, 1e-5);
}

test "EventQueue round-trip (none, byte, int, dword events)" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const events = try a.alloc(Event, 4);
    events[0] = .{ .caller_id = 1, .event_id = 2, .data = .none };
    events[1] = .{ .caller_id = 2, .event_id = 4, .data = .{ .byte_value = 0xAB } };
    events[2] = .{ .caller_id = 3, .event_id = 9, .data = .{ .int_value = -7 } };
    events[3] = .{ .caller_id = 4, .event_id = 20, .data = .{ .dword_value = 0xBEEF } };

    try writeEventQueue(&g, 0, events);

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const out = try parseEventQueue(arena2.allocator(), &g2, &g2.structs.items[0]);
    try t.expectEqual(@as(usize, 4), out.len);
    try t.expectEqual(@as(u32, 2), out[0].event_id);
    try t.expect(out[0].data == .none);
    try t.expectEqual(@as(u8, 0xAB), out[1].data.byte_value);
    try t.expectEqual(@as(i32, -7), out[2].data.int_value);
    try t.expectEqual(@as(u32, 0xBEEF), out[3].data.dword_value);
}

test "ScriptEvent round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const int_p = try a.dupe(i32, &.{ 1, 2 });
    const float_p = try a.dupe(f32, &.{0.5});
    const obj_p = try a.dupe(u32, &.{0xFF});
    const str_p = try a.alloc([]u8, 1);
    str_p[0] = try a.dupe(u8, "event_str");

    const se = ScriptEvent{
        .event_type = 42,
        .int_params = int_p,
        .float_params = float_p,
        .string_params = str_p,
        .object_params = obj_p,
    };

    const si = try g.addStruct(1);
    try se.writeIntoGff(&g, si);
    try g.addFieldToStruct(0, "SE", .{ .@"struct" = si });

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();

    const tl = &g2.structs.items[0];
    const sef = g2.getField(tl, "SE").?;
    const parsed = try ScriptEvent.fromGffStruct(arena2.allocator(), &g2, &g2.structs.items[sef.value.@"struct"]);

    try t.expectEqual(@as(u16, 42), parsed.event_type);
    try t.expectEqual(@as(usize, 2), parsed.int_params.len);
    try t.expectEqual(@as(i32, 1), parsed.int_params[0]);
    try t.expectEqual(@as(i32, 2), parsed.int_params[1]);
    try t.expectApproxEqAbs(@as(f32, 0.5), parsed.float_params[0], 1e-5);
    try t.expectEqualStrings("event_str", parsed.string_params[0]);
    try t.expectEqual(@as(u32, 0xFF), parsed.object_params[0]);
}

test "ScriptTalent round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    const st = ScriptTalent{
        .id = 5,
        .type = 2,
        .multi_class = 1,
        .item = 0xABCD,
        .item_property_index = 3,
        .caster_level = 10,
        .meta_type = 0,
    };
    const si = try g.addStruct(3);
    try st.writeIntoGff(&g, si);
    try g.addFieldToStruct(0, "ST", .{ .@"struct" = si });

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = gff.GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    const tl = &g2.structs.items[0];
    const stf = g2.getField(tl, "ST").?;
    const parsed = try ScriptTalent.fromGffStruct(&g2, &g2.structs.items[stf.value.@"struct"]);

    try t.expectEqual(@as(i32, 5), parsed.id);
    try t.expectEqual(@as(i32, 2), parsed.type);
    try t.expectEqual(@as(u8, 1), parsed.multi_class);
    try t.expectEqual(@as(u32, 0xABCD), parsed.item);
    try t.expectEqual(@as(i32, 3), parsed.item_property_index);
    try t.expectEqual(@as(u8, 10), parsed.caster_level);
}
