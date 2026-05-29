//! BioWare Aurora Module Information (IFO) GFF reader/writer.
//!
//! Spec: Bioware_Aurora_IFO_Format.pdf
//!   §2.1  Fields created by toolset (all modules)
//!   §2.2  Fields created by game (savegames only)
//!   §3    Common list/struct definitions (areas, cache, hak paks)
//!   §4    Save-game list/struct definitions (EventQueue, Tokens, TURDs)
//!
//! Every NWN module or savegame ERF contains a "module.ifo" file with
//! FileType "IFO ". IfoFile wraps the top-level GFF struct.
//!
//! Limitations:
//!   - Mod_PlayerList (§4.2) is not decoded; the Player Struct format
//!     merits its own spec document. The field is silently ignored on
//!     parse and omitted on serialize.
//!   - Deprecated/unused lists (Mod_CutsceneList, Mod_Expan_List,
//!     Mod_GVar_List, Creature List) are neither read nor written.
//!
//! Memory: IfoFile owns an ArenaAllocator. Call deinit() once to free all.
//!
//! An IFO file is a module InFOrmation file. Every NWN module (.MOD or .NWM) or savegame (.SAV) is an Encapsulated Resource File (ERF) that contains an IFO file called "module.ifo".
//! The IFO file type is in BioWare's Generic File Format (GFF) and it is assumed that the reader has some familiarity with GFF.
//!  Many of the GFF Fields in an IFO file make references to 2-Dimensional Array (2DA) files, so it is also assumed that the reader is familiar with the 2DA format.
//! In the GFF header of an IFO file, the FileType value is "IFO ".

const std = @import("std");
const gff = @import("gff.zig");
const common = @import("common_gff.zig");

pub const FILE_TYPE = "IFO ";

// ============================================================================
// Errors / Variant
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

/// Drives which optional field groups are written.
/// Parsing is always tolerant (all fields optional; defaults applied).
pub const IfoVariant = enum {
    /// Written by toolset: §2.1 fields only.
    toolset,
    /// Written by game: §2.1 + §2.2 fields.
    savegame,
};

// ============================================================================
// Internal helpers
// ============================================================================

const EMPTY_RES_REF: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 };

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
inline fn optDword(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u32) Error!u32 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .dword => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn optDword64(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u64) Error!u64 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .dword64 => |v| v,
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
inline fn optResRef(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!gff.ResRef {
    const f = g.getField(s, l) orelse return EMPTY_RES_REF;
    return switch (f.value) {
        .res_ref => |v| v,
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
fn optVoidDataDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error![]u8 {
    const f = g.getField(s, l) orelse return a.dupe(u8, &.{});
    return switch (f.value) {
        .void_data => |v| a.dupe(u8, v),
        else => error.WrongFieldType,
    };
}
fn optExoLocDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!gff.ExoLocString {
    var out: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    const f = g.getField(s, l) orelse return out;
    switch (f.value) {
        .exo_loc_string => |loc| {
            out.string_ref = loc.string_ref;
            for (loc.substrings.items) |ss|
                try out.substrings.append(a, .{ .string_id = ss.string_id, .text = try a.dupe(u8, ss.text) });
        },
        else => return error.WrongFieldType,
    }
    return out;
}
fn cloneExoLoc(a: std.mem.Allocator, src: gff.ExoLocString) !gff.ExoLocString {
    var out: gff.ExoLocString = .{ .string_ref = src.string_ref, .substrings = .empty };
    errdefer out.deinit(a);
    for (src.substrings.items) |ss| {
        const text = try a.dupe(u8, ss.text);
        errdefer a.free(text);
        try out.substrings.append(a, .{ .string_id = ss.string_id, .text = text });
    }
    return out;
}

// Mod_VarTable uses a different label than common.parseVarTable ("VarTable").
fn parseModVarTable(arena: std.mem.Allocator, g: *const gff.GffFile, parent: *const gff.Struct) Error![]common.Variable {
    const f = g.getField(parent, "Mod_VarTable") orelse return arena.alloc(common.Variable, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(common.Variable, arr.len);
    for (arr, 0..) |idx, i| out[i] = try common.Variable.fromGffStruct(arena, g, &g.structs.items[idx]);
    return out;
}
fn writeModVarTable(g: *gff.GffFile, parent_idx: u32, vars: []const common.Variable) !void {
    if (vars.len == 0) return;
    const arr = try g.allocator.alloc(u32, vars.len);
    errdefer g.allocator.free(arr);
    for (vars, 0..) |*v, i| {
        const si = try g.addStruct(0);
        try v.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_VarTable", .{ .list = arr });
}

// ============================================================================
// §3.1  AreaEntry  (StructID 6)
// ============================================================================

pub const AreaEntry = struct {
    pub const STRUCT_ID: u32 = 6;

    /// ResRef of the area (must have .are, .git, .gic counterparts).
    area_name: gff.ResRef = EMPTY_RES_REF,
    /// ObjectID of the area. Present in savegames; absent in toolset output.
    object_id: ?u32 = null,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!AreaEntry {
        const obj = if (g.getField(s, "ObjectId")) |f| switch (f.value) {
            .dword => |v| @as(?u32, v),
            else => return error.WrongFieldType,
        } else null;
        return .{
            .area_name = try optResRef(g, s, "AreaName"),
            .object_id = obj,
        };
    }

    pub fn writeIntoGff(self: AreaEntry, g: *gff.GffFile, struct_idx: u32, is_save: bool) !void {
        try g.addFieldToStruct(struct_idx, "AreaName", .{ .res_ref = self.area_name });
        if (is_save) {
            if (self.object_id) |id|
                try g.addFieldToStruct(struct_idx, "ObjectId", .{ .dword = id });
        }
    }
};

// ============================================================================
// §3.2  CacheEntry  (StructID 9)
// ============================================================================

pub const CacheEntry = struct {
    pub const STRUCT_ID: u32 = 9;

    res_ref: gff.ResRef = EMPTY_RES_REF,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!CacheEntry {
        return .{ .res_ref = try optResRef(g, s, "ResRef") };
    }
    pub fn writeIntoGff(self: CacheEntry, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "ResRef", .{ .res_ref = self.res_ref });
    }
};

// ============================================================================
// §3.3  HakEntry  (StructID 8)
// ============================================================================

pub const HakEntry = struct {
    pub const STRUCT_ID: u32 = 8;

    mod_hak: []u8 = &.{},

    pub fn fromGffStruct(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!HakEntry {
        return .{ .mod_hak = try optExoStringDupe(a, g, s, "Mod_Hak") };
    }
    pub fn writeIntoGff(self: HakEntry, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Mod_Hak", .{ .exo_string = try g.allocator.dupe(u8, self.mod_hak) });
    }
};

// ============================================================================
// §4.3  Token  (StructID 7)
// ============================================================================

pub const Token = struct {
    pub const STRUCT_ID: u32 = 7;

    number: u32 = 0,
    value: []u8 = &.{},

    pub fn fromGffStruct(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Token {
        return .{
            .number = try optDword(g, s, "Mod_TokensNumber", 0),
            .value = try optExoStringDupe(a, g, s, "Mod_TokensValue"),
        };
    }
    pub fn writeIntoGff(self: Token, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Mod_TokensNumber", .{ .dword = self.number });
        try g.addFieldToStruct(struct_idx, "Mod_TokensValue", .{ .exo_string = try g.allocator.dupe(u8, self.value) });
    }
};

// ============================================================================
// §4.4  PersonalRep  (StructID 47787)
// ============================================================================

pub const PersonalRep = struct {
    pub const STRUCT_ID: u32 = 47787;

    amount: i32 = 0,
    day: u32 = 0,
    decays: u8 = 0,
    duration: i32 = 0,
    obj_id: u32 = 0,
    time: u32 = 0,

    pub fn fromGffStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!PersonalRep {
        return .{
            .amount = try optInt(g, s, "TURD_PR_Amount", 0),
            .day = try optDword(g, s, "TURD_PR_Day", 0),
            .decays = try optByte(g, s, "TURD_PR_Decays", 0),
            .duration = try optInt(g, s, "TURD_PR_Duration", 0),
            .obj_id = try optDword(g, s, "TURD_PR_ObjId", 0),
            .time = try optDword(g, s, "TURD_PR_Time", 0),
        };
    }
    pub fn writeIntoGff(self: PersonalRep, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "TURD_PR_Amount", .{ .int = self.amount });
        try g.addFieldToStruct(struct_idx, "TURD_PR_Day", .{ .dword = self.day });
        try g.addFieldToStruct(struct_idx, "TURD_PR_Decays", .{ .byte = self.decays });
        try g.addFieldToStruct(struct_idx, "TURD_PR_Duration", .{ .int = self.duration });
        try g.addFieldToStruct(struct_idx, "TURD_PR_ObjId", .{ .dword = self.obj_id });
        try g.addFieldToStruct(struct_idx, "TURD_PR_Time", .{ .dword = self.time });
    }
};

// ============================================================================
// §4.4  MapData  (StructID 0, nested in Mod_MapDataList)
// ============================================================================

pub const MapData = struct {
    pub const STRUCT_ID: u32 = 0;

    mod_map_data: []u8 = &.{},
    mod_map_num_areas: i32 = 0,

    pub fn fromGffStruct(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!MapData {
        return .{
            .mod_map_data = try optVoidDataDupe(a, g, s, "Mod_MapData"),
            .mod_map_num_areas = try optInt(g, s, "ModMapNumAreas", 0),
        };
    }
    pub fn writeIntoGff(self: MapData, g: *gff.GffFile, struct_idx: u32) !void {
        const data = try g.allocator.dupe(u8, self.mod_map_data);
        try g.addFieldToStruct(struct_idx, "Mod_MapData", .{ .void_data = data });
        try g.addFieldToStruct(struct_idx, "ModMapNumAreas", .{ .int = self.mod_map_num_areas });
    }
};

// ============================================================================
// §4.4  TurdEntry  (StructID 13634816)
// ============================================================================

pub const TurdEntry = struct {
    pub const STRUCT_ID: u32 = 13634816;

    effect_list: []common.Effect = &.{},
    map_areas_data: []u8 = &.{},
    map_data_list: []MapData = &.{},
    area_id: u32 = 0,
    calendar_day: u32 = 0,
    community_name: []u8 = &.{},
    first_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    last_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    orient_x: f32 = 0,
    orient_y: f32 = 0,
    orient_z: f32 = 0,
    personal_rep: []PersonalRep = &.{},
    player_id: u32 = 0,
    position_x: f32 = 0,
    position_y: f32 = 0,
    position_z: f32 = 0,
    rep_list: []i32 = &.{},
    time_of_day: u32 = 0,
    var_table: []common.Variable = &.{},

    pub fn fromGffStruct(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!TurdEntry {
        var out: TurdEntry = .{};
        out.effect_list = try common.parseEffectsList(arena, g, s);
        out.map_areas_data = try optVoidDataDupe(arena, g, s, "Mod_MapAreasData");
        out.map_data_list = try parseMapDataList(arena, g, s);
        out.area_id = try optDword(g, s, "TURD_AreaId", 0);
        out.calendar_day = try optDword(g, s, "TURD_CalendarDay", 0);
        out.community_name = try optExoStringDupe(arena, g, s, "TURD_CommntyName");
        out.first_name = try optExoLocDupe(arena, g, s, "TURD_FirstName");
        out.last_name = try optExoLocDupe(arena, g, s, "TURD_LastName");
        out.orient_x = try optFloat(g, s, "TURD_OrientatX", 0);
        out.orient_y = try optFloat(g, s, "TURD_OrientatY", 0);
        out.orient_z = try optFloat(g, s, "TURD_OrientatZ", 0);
        out.personal_rep = try parsePersonalRep(arena, g, s);
        out.player_id = try optDword(g, s, "TURD_PlayerID", 0);
        out.position_x = try optFloat(g, s, "TURD_PositionX", 0);
        out.position_y = try optFloat(g, s, "TURD_PositionY", 0);
        out.position_z = try optFloat(g, s, "TURD_PositionZ", 0);
        out.rep_list = try parseRepList(arena, g, s);
        out.time_of_day = try optDword(g, s, "TURD_TimeOfDay", 0);
        out.var_table = try common.parseVarTable(arena, g, s);
        return out;
    }

    pub fn writeIntoGff(self: *const TurdEntry, g: *gff.GffFile, struct_idx: u32) !void {
        const a = g.allocator;
        try common.writeEffectsList(g, struct_idx, self.effect_list);
        try g.addFieldToStruct(struct_idx, "Mod_MapAreasData", .{ .void_data = try a.dupe(u8, self.map_areas_data) });
        try writeMapDataList(g, struct_idx, self.map_data_list);
        try g.addFieldToStruct(struct_idx, "TURD_AreaId", .{ .dword = self.area_id });
        try g.addFieldToStruct(struct_idx, "TURD_CalendarDay", .{ .dword = self.calendar_day });
        try g.addFieldToStruct(struct_idx, "TURD_CommntyName", .{ .exo_string = try a.dupe(u8, self.community_name) });
        try g.addFieldToStruct(struct_idx, "TURD_FirstName", .{ .exo_loc_string = try cloneExoLoc(a, self.first_name) });
        try g.addFieldToStruct(struct_idx, "TURD_LastName", .{ .exo_loc_string = try cloneExoLoc(a, self.last_name) });
        try g.addFieldToStruct(struct_idx, "TURD_OrientatX", .{ .float = self.orient_x });
        try g.addFieldToStruct(struct_idx, "TURD_OrientatY", .{ .float = self.orient_y });
        try g.addFieldToStruct(struct_idx, "TURD_OrientatZ", .{ .float = self.orient_z });
        try writePersonalRep(g, struct_idx, self.personal_rep);
        try g.addFieldToStruct(struct_idx, "TURD_PlayerID", .{ .dword = self.player_id });
        try g.addFieldToStruct(struct_idx, "TURD_PositionX", .{ .float = self.position_x });
        try g.addFieldToStruct(struct_idx, "TURD_PositionY", .{ .float = self.position_y });
        try g.addFieldToStruct(struct_idx, "TURD_PositionZ", .{ .float = self.position_z });
        try writeRepList(g, struct_idx, self.rep_list);
        try g.addFieldToStruct(struct_idx, "TURD_TimeOfDay", .{ .dword = self.time_of_day });
        try common.writeVarTable(g, struct_idx, self.var_table);
    }
};

fn parseMapDataList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]MapData {
    const f = g.getField(s, "Mod_MapDataList") orelse return arena.alloc(MapData, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(MapData, arr.len);
    for (arr, 0..) |h, i| out[i] = try MapData.fromGffStruct(arena, g, &g.structs.items[h]);
    return out;
}
fn writeMapDataList(g: *gff.GffFile, parent_idx: u32, items: []const MapData) !void {
    if (items.len == 0) return;
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |*m, i| {
        const si = try g.addStruct(MapData.STRUCT_ID);
        try m.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_MapDataList", .{ .list = arr });
}

fn parsePersonalRep(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]PersonalRep {
    const f = g.getField(s, "TURD_PersonalRep") orelse return arena.alloc(PersonalRep, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(PersonalRep, arr.len);
    for (arr, 0..) |h, i| out[i] = try PersonalRep.fromGffStruct(g, &g.structs.items[h]);
    return out;
}
fn writePersonalRep(g: *gff.GffFile, parent_idx: u32, reps: []const PersonalRep) !void {
    if (reps.len == 0) return;
    const arr = try g.allocator.alloc(u32, reps.len);
    errdefer g.allocator.free(arr);
    for (reps, 0..) |*r, i| {
        const si = try g.addStruct(PersonalRep.STRUCT_ID);
        try r.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "TURD_PersonalRep", .{ .list = arr });
}

fn parseRepList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]i32 {
    const f = g.getField(s, "TURD_RepList") orelse return arena.alloc(i32, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(i32, arr.len);
    for (arr, 0..) |h, i| out[i] = try optInt(g, &g.structs.items[h], "TURD_RepAmount", 0);
    return out;
}
fn writeRepList(g: *gff.GffFile, parent_idx: u32, reps: []const i32) !void {
    if (reps.len == 0) return;
    const arr = try g.allocator.alloc(u32, reps.len);
    errdefer g.allocator.free(arr);
    for (reps, 0..) |amt, i| {
        const si = try g.addStruct(43962);
        try g.addFieldToStruct(si, "TURD_RepAmount", .{ .int = amt });
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "TURD_RepList", .{ .list = arr });
}

// ============================================================================
// IfoStruct — top-level GFF struct
// ============================================================================

pub const IfoStruct = struct {
    // ---- §2.1 toolset fields ------------------------------------------------

    /// Expansion pack bit flags. Bit 0 = XP1, Bit 1 = XP2.
    expansion_pack: u16 = 0,
    area_list: []AreaEntry = &.{},
    cache_nss_list: []CacheEntry = &.{},
    /// Deprecated; always 2.
    creator_id: i32 = 2,
    custom_tlk: []u8 = &.{},
    dawn_hour: u8 = 6,
    description: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    dusk_hour: u8 = 18,
    entry_area: gff.ResRef = EMPTY_RES_REF,
    entry_dir_x: f32 = 1,
    entry_dir_y: f32 = 0,
    entry_x: f32 = 0,
    entry_y: f32 = 0,
    entry_z: f32 = 0,
    /// Obsolete; kept for round-trip. If hak_list is non-empty, prefer that.
    mod_hak: []u8 = &.{},
    hak_list: []HakEntry = &.{},
    /// Arbitrary 16-byte (toolset) or 32-byte (game) binary module ID.
    mod_id: []u8 = &.{},
    is_save_game: u8 = 0,
    min_game_ver: []u8 = &.{},
    min_per_hour: u8 = 2,
    name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    on_acquire_item: gff.ResRef = EMPTY_RES_REF,
    on_activate_item: gff.ResRef = EMPTY_RES_REF,
    on_client_enter: gff.ResRef = EMPTY_RES_REF,
    on_client_leave: gff.ResRef = EMPTY_RES_REF,
    on_cutscene_abort: gff.ResRef = EMPTY_RES_REF,
    on_heartbeat: gff.ResRef = EMPTY_RES_REF,
    on_mod_load: gff.ResRef = EMPTY_RES_REF,
    /// Deprecated.
    on_mod_start: gff.ResRef = EMPTY_RES_REF,
    on_player_death: gff.ResRef = EMPTY_RES_REF,
    on_player_dying: gff.ResRef = EMPTY_RES_REF,
    on_player_equip_item: gff.ResRef = EMPTY_RES_REF,
    on_player_level_up: gff.ResRef = EMPTY_RES_REF,
    on_player_rest: gff.ResRef = EMPTY_RES_REF,
    on_player_unequip_item: gff.ResRef = EMPTY_RES_REF,
    on_player_respawn: gff.ResRef = EMPTY_RES_REF,
    on_unacquire_item: gff.ResRef = EMPTY_RES_REF,
    on_user_defined: gff.ResRef = EMPTY_RES_REF,
    start_day: u8 = 1,
    start_hour: u8 = 0,
    start_month: u8 = 1,
    start_movie: gff.ResRef = EMPTY_RES_REF,
    start_year: u32 = 0,
    tag: []u8 = &.{},
    /// Always 3 per spec.
    version: u32 = 3,
    xp_scale: u8 = 100,

    // ---- §2.2 savegame-only fields ------------------------------------------

    event_queue: []common.Event = &.{},
    /// ID for next Effect object.
    effect_next_id: u64 = 0,
    is_nwm_file: u8 = 0,
    next_char_id_0: u32 = 0,
    next_char_id_1: u32 = 0,
    next_obj_id_0: u32 = 0,
    next_obj_id_1: u32 = 0,
    nwm_res_name: []u8 = &.{},
    tokens: []Token = &.{},
    turd_list: []TurdEntry = &.{},
    mod_var_table: []common.Variable = &.{},

    // -------------------------------------------------------------------------

    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
    ) Error!IfoStruct {
        var out: IfoStruct = .{};

        // §2.1
        out.expansion_pack = try optWord(g, s, "Expansion_Pack", 0);
        out.area_list = try parseAreaList(arena, g, s);
        out.cache_nss_list = try parseCacheList(arena, g, s);
        out.creator_id = try optInt(g, s, "Mod_Creator_ID", 2);
        out.custom_tlk = try optExoStringDupe(arena, g, s, "Mod_CustomTlk");
        out.dawn_hour = try optByte(g, s, "Mod_DawnHour", 6);
        out.description = try optExoLocDupe(arena, g, s, "Mod_Description");
        out.dusk_hour = try optByte(g, s, "Mod_DuskHour", 18);
        out.entry_area = try optResRef(g, s, "Mod_Entry_Area");
        out.entry_dir_x = try optFloat(g, s, "Mod_Entry_Dir_X", 1);
        out.entry_dir_y = try optFloat(g, s, "Mod_Entry_Dir_Y", 0);
        out.entry_x = try optFloat(g, s, "Mod_Entry_X", 0);
        out.entry_y = try optFloat(g, s, "Mod_Entry_Y", 0);
        out.entry_z = try optFloat(g, s, "Mod_Entry_Z", 0);
        out.mod_hak = try optExoStringDupe(arena, g, s, "Mod_Hak");
        out.hak_list = try parseHakList(arena, g, s);
        out.mod_id = try optVoidDataDupe(arena, g, s, "Mod_ID");
        out.is_save_game = try optByte(g, s, "Mod_IsSaveGame", 0);
        out.min_game_ver = try optExoStringDupe(arena, g, s, "Mod_MinGameVer");
        out.min_per_hour = try optByte(g, s, "Mod_MinPerHour", 2);
        out.name = try optExoLocDupe(arena, g, s, "Mod_Name");
        out.on_acquire_item = try optResRef(g, s, "Mod_OnAcquirItem");
        out.on_activate_item = try optResRef(g, s, "Mod_OnActvtItem");
        out.on_client_enter = try optResRef(g, s, "Mod_OnClientEntr");
        out.on_client_leave = try optResRef(g, s, "Mod_OnClientLeav");
        out.on_cutscene_abort = try optResRef(g, s, "Mod_OnCutsnAbort");
        out.on_heartbeat = try optResRef(g, s, "Mod_OnHeartbeat");
        out.on_mod_load = try optResRef(g, s, "Mod_OnModLoad");
        out.on_mod_start = try optResRef(g, s, "Mod_OnModStart");
        out.on_player_death = try optResRef(g, s, "Mod_OnPlrDeath");
        out.on_player_dying = try optResRef(g, s, "Mod_OnPlrDying");
        out.on_player_equip_item = try optResRef(g, s, "Mod_OnPlrEqItm");
        out.on_player_level_up = try optResRef(g, s, "Mod_OnPlrLvlUp");
        out.on_player_rest = try optResRef(g, s, "Mod_OnPlrRest");
        out.on_player_unequip_item = try optResRef(g, s, "Mod_OnPlrUnEqItm");
        out.on_player_respawn = try optResRef(g, s, "Mod_OnSpawnBtnDn");
        out.on_unacquire_item = try optResRef(g, s, "Mod_OnUnAcreItem");
        out.on_user_defined = try optResRef(g, s, "Mod_OnUsrDefined");
        out.start_day = try optByte(g, s, "Mod_StartDay", 1);
        out.start_hour = try optByte(g, s, "Mod_StartHour", 0);
        out.start_month = try optByte(g, s, "Mod_StartMonth", 1);
        out.start_movie = try optResRef(g, s, "Mod_StartMovie");
        out.start_year = try optDword(g, s, "Mod_StartYear", 0);
        out.tag = try optExoStringDupe(arena, g, s, "Mod_Tag");
        out.version = try optDword(g, s, "Mod_Version", 3);
        out.xp_scale = try optByte(g, s, "Mod_XPScale", 100);

        // §2.2 savegame
        out.event_queue = try common.parseEventQueue(arena, g, s);
        out.effect_next_id = try optDword64(g, s, "Mod_Effect_NxtId", 0);
        out.is_nwm_file = try optByte(g, s, "Mod_IsNWMFile", 0);
        out.next_char_id_0 = try optDword(g, s, "Mod_NextCharId0", 0);
        out.next_char_id_1 = try optDword(g, s, "Mod_NextCharId1", 0);
        out.next_obj_id_0 = try optDword(g, s, "Mod_NextObjId0", 0);
        out.next_obj_id_1 = try optDword(g, s, "Mod_NextObjId1", 0);
        out.nwm_res_name = try optExoStringDupe(arena, g, s, "Mod_NWMResName");
        out.tokens = try parseTokenList(arena, g, s);
        out.turd_list = try parseTurdList(arena, g, s);
        out.mod_var_table = try parseModVarTable(arena, g, s);

        return out;
    }

    pub fn writeIntoGff(
        self: *const IfoStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: IfoVariant,
    ) !void {
        const a = g.allocator;
        const is_save = (variant == .savegame);

        // §2.1 — alphabetical by GFF label
        try writeAreaList(g, struct_idx, self.area_list, is_save);
        try writeCacheList(g, struct_idx, self.cache_nss_list);
        try g.addFieldToStruct(struct_idx, "Expansion_Pack", .{ .word = self.expansion_pack });
        try g.addFieldToStruct(struct_idx, "Mod_Creator_ID", .{ .int = self.creator_id });
        try g.addFieldToStruct(struct_idx, "Mod_CustomTlk", .{ .exo_string = try a.dupe(u8, self.custom_tlk) });
        try g.addFieldToStruct(struct_idx, "Mod_DawnHour", .{ .byte = self.dawn_hour });
        try g.addFieldToStruct(struct_idx, "Mod_Description", .{ .exo_loc_string = try cloneExoLoc(a, self.description) });
        try g.addFieldToStruct(struct_idx, "Mod_DuskHour", .{ .byte = self.dusk_hour });
        try g.addFieldToStruct(struct_idx, "Mod_Entry_Area", .{ .res_ref = self.entry_area });
        try g.addFieldToStruct(struct_idx, "Mod_Entry_Dir_X", .{ .float = self.entry_dir_x });
        try g.addFieldToStruct(struct_idx, "Mod_Entry_Dir_Y", .{ .float = self.entry_dir_y });
        try g.addFieldToStruct(struct_idx, "Mod_Entry_X", .{ .float = self.entry_x });
        try g.addFieldToStruct(struct_idx, "Mod_Entry_Y", .{ .float = self.entry_y });
        try g.addFieldToStruct(struct_idx, "Mod_Entry_Z", .{ .float = self.entry_z });
        if (self.mod_hak.len > 0)
            try g.addFieldToStruct(struct_idx, "Mod_Hak", .{ .exo_string = try a.dupe(u8, self.mod_hak) });
        try writeHakList(g, struct_idx, self.hak_list);
        if (self.mod_id.len > 0)
            try g.addFieldToStruct(struct_idx, "Mod_ID", .{ .void_data = try a.dupe(u8, self.mod_id) });
        try g.addFieldToStruct(struct_idx, "Mod_IsSaveGame", .{ .byte = self.is_save_game });
        try g.addFieldToStruct(struct_idx, "Mod_MinGameVer", .{ .exo_string = try a.dupe(u8, self.min_game_ver) });
        try g.addFieldToStruct(struct_idx, "Mod_MinPerHour", .{ .byte = self.min_per_hour });
        try g.addFieldToStruct(struct_idx, "Mod_Name", .{ .exo_loc_string = try cloneExoLoc(a, self.name) });
        try g.addFieldToStruct(struct_idx, "Mod_OnAcquirItem", .{ .res_ref = self.on_acquire_item });
        try g.addFieldToStruct(struct_idx, "Mod_OnActvtItem", .{ .res_ref = self.on_activate_item });
        try g.addFieldToStruct(struct_idx, "Mod_OnClientEntr", .{ .res_ref = self.on_client_enter });
        try g.addFieldToStruct(struct_idx, "Mod_OnClientLeav", .{ .res_ref = self.on_client_leave });
        try g.addFieldToStruct(struct_idx, "Mod_OnCutsnAbort", .{ .res_ref = self.on_cutscene_abort });
        try g.addFieldToStruct(struct_idx, "Mod_OnHeartbeat", .{ .res_ref = self.on_heartbeat });
        try g.addFieldToStruct(struct_idx, "Mod_OnModLoad", .{ .res_ref = self.on_mod_load });
        try g.addFieldToStruct(struct_idx, "Mod_OnModStart", .{ .res_ref = self.on_mod_start });
        try g.addFieldToStruct(struct_idx, "Mod_OnPlrDeath", .{ .res_ref = self.on_player_death });
        try g.addFieldToStruct(struct_idx, "Mod_OnPlrDying", .{ .res_ref = self.on_player_dying });
        try g.addFieldToStruct(struct_idx, "Mod_OnPlrEqItm", .{ .res_ref = self.on_player_equip_item });
        try g.addFieldToStruct(struct_idx, "Mod_OnPlrLvlUp", .{ .res_ref = self.on_player_level_up });
        try g.addFieldToStruct(struct_idx, "Mod_OnPlrRest", .{ .res_ref = self.on_player_rest });
        try g.addFieldToStruct(struct_idx, "Mod_OnPlrUnEqItm", .{ .res_ref = self.on_player_unequip_item });
        try g.addFieldToStruct(struct_idx, "Mod_OnSpawnBtnDn", .{ .res_ref = self.on_player_respawn });
        try g.addFieldToStruct(struct_idx, "Mod_OnUnAcreItem", .{ .res_ref = self.on_unacquire_item });
        try g.addFieldToStruct(struct_idx, "Mod_OnUsrDefined", .{ .res_ref = self.on_user_defined });
        try g.addFieldToStruct(struct_idx, "Mod_StartDay", .{ .byte = self.start_day });
        try g.addFieldToStruct(struct_idx, "Mod_StartHour", .{ .byte = self.start_hour });
        try g.addFieldToStruct(struct_idx, "Mod_StartMonth", .{ .byte = self.start_month });
        try g.addFieldToStruct(struct_idx, "Mod_StartMovie", .{ .res_ref = self.start_movie });
        try g.addFieldToStruct(struct_idx, "Mod_StartYear", .{ .dword = self.start_year });
        try g.addFieldToStruct(struct_idx, "Mod_Tag", .{ .exo_string = try a.dupe(u8, self.tag) });
        try g.addFieldToStruct(struct_idx, "Mod_Version", .{ .dword = self.version });
        try g.addFieldToStruct(struct_idx, "Mod_XPScale", .{ .byte = self.xp_scale });

        // §2.2 savegame-only
        if (is_save) {
            try common.writeEventQueue(g, struct_idx, self.event_queue);
            if (self.effect_next_id != 0)
                try g.addFieldToStruct(struct_idx, "Mod_Effect_NxtId", .{ .dword64 = self.effect_next_id });
            try g.addFieldToStruct(struct_idx, "Mod_IsNWMFile", .{ .byte = self.is_nwm_file });
            try g.addFieldToStruct(struct_idx, "Mod_NextCharId0", .{ .dword = self.next_char_id_0 });
            try g.addFieldToStruct(struct_idx, "Mod_NextCharId1", .{ .dword = self.next_char_id_1 });
            try g.addFieldToStruct(struct_idx, "Mod_NextObjId0", .{ .dword = self.next_obj_id_0 });
            try g.addFieldToStruct(struct_idx, "Mod_NextObjId1", .{ .dword = self.next_obj_id_1 });
            try g.addFieldToStruct(struct_idx, "Mod_NWMResName", .{ .exo_string = try a.dupe(u8, self.nwm_res_name) });
            try writeTokenList(g, struct_idx, self.tokens);
            try writeTurdList(g, struct_idx, self.turd_list);
            try writeModVarTable(g, struct_idx, self.mod_var_table);
        }
    }
};

// ============================================================================
// List parse/write helpers
// ============================================================================

fn parseAreaList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]AreaEntry {
    const f = g.getField(s, "Mod_Area_List") orelse return arena.alloc(AreaEntry, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(AreaEntry, arr.len);
    for (arr, 0..) |h, i| out[i] = try AreaEntry.fromGffStruct(g, &g.structs.items[h]);
    return out;
}
fn writeAreaList(g: *gff.GffFile, parent_idx: u32, areas: []const AreaEntry, is_save: bool) !void {
    if (areas.len == 0) return;
    const arr = try g.allocator.alloc(u32, areas.len);
    errdefer g.allocator.free(arr);
    for (areas, 0..) |ae, i| {
        const si = try g.addStruct(AreaEntry.STRUCT_ID);
        try ae.writeIntoGff(g, si, is_save);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_Area_List", .{ .list = arr });
}

fn parseCacheList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]CacheEntry {
    const f = g.getField(s, "Mod_CacheNSSList") orelse return arena.alloc(CacheEntry, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(CacheEntry, arr.len);
    for (arr, 0..) |h, i| out[i] = try CacheEntry.fromGffStruct(g, &g.structs.items[h]);
    return out;
}
fn writeCacheList(g: *gff.GffFile, parent_idx: u32, entries: []const CacheEntry) !void {
    if (entries.len == 0) return;
    const arr = try g.allocator.alloc(u32, entries.len);
    errdefer g.allocator.free(arr);
    for (entries, 0..) |ce, i| {
        const si = try g.addStruct(CacheEntry.STRUCT_ID);
        try ce.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_CacheNSSList", .{ .list = arr });
}

fn parseHakList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]HakEntry {
    const f = g.getField(s, "Mod_HakList") orelse return arena.alloc(HakEntry, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(HakEntry, arr.len);
    for (arr, 0..) |h, i| out[i] = try HakEntry.fromGffStruct(arena, g, &g.structs.items[h]);
    return out;
}
fn writeHakList(g: *gff.GffFile, parent_idx: u32, entries: []const HakEntry) !void {
    if (entries.len == 0) return;
    const arr = try g.allocator.alloc(u32, entries.len);
    errdefer g.allocator.free(arr);
    for (entries, 0..) |*he, i| {
        const si = try g.addStruct(HakEntry.STRUCT_ID);
        try he.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_HakList", .{ .list = arr });
}

fn parseTokenList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]Token {
    const f = g.getField(s, "Mod_Tokens") orelse return arena.alloc(Token, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Token, arr.len);
    for (arr, 0..) |h, i| out[i] = try Token.fromGffStruct(arena, g, &g.structs.items[h]);
    return out;
}
fn writeTokenList(g: *gff.GffFile, parent_idx: u32, tokens: []const Token) !void {
    if (tokens.len == 0) return;
    const arr = try g.allocator.alloc(u32, tokens.len);
    errdefer g.allocator.free(arr);
    for (tokens, 0..) |tok, i| {
        const si = try g.addStruct(Token.STRUCT_ID);
        try tok.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_Tokens", .{ .list = arr });
}

fn parseTurdList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]TurdEntry {
    const f = g.getField(s, "Mod_TURDList") orelse return arena.alloc(TurdEntry, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(TurdEntry, arr.len);
    for (arr, 0..) |h, i| out[i] = try TurdEntry.fromGffStruct(arena, g, &g.structs.items[h]);
    return out;
}
fn writeTurdList(g: *gff.GffFile, parent_idx: u32, turds: []const TurdEntry) !void {
    if (turds.len == 0) return;
    const arr = try g.allocator.alloc(u32, turds.len);
    errdefer g.allocator.free(arr);
    for (turds, 0..) |*td, i| {
        const si = try g.addStruct(TurdEntry.STRUCT_ID);
        try td.writeIntoGff(g, si);
        arr[i] = si;
    }
    try g.addFieldToStruct(parent_idx, "Mod_TURDList", .{ .list = arr });
}

// ============================================================================
// IfoFile — standalone "IFO " GFF wrapper
// ============================================================================

pub const IfoFile = struct {
    arena: std.heap.ArenaAllocator,
    module: IfoStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) IfoFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *IfoFile) void {
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!IfoFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = IfoFile.init(parent_alloc);
        errdefer out.deinit();
        out.module = try IfoStruct.fromGffStruct(out.arena.allocator(), &g, &g.structs.items[0]);
        return out;
    }

    pub fn serialize(self: *const IfoFile, alloc: std.mem.Allocator) ![]u8 {
        const variant: IfoVariant = if (self.module.is_save_game != 0) .savegame else .toolset;
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.module.writeIntoGff(&g, 0, variant);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty IFO round-trip (toolset defaults)" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();
    const m = &ifo2.module;

    try t.expectEqual(@as(i32, 2), m.creator_id);
    try t.expectEqual(@as(u32, 3), m.version);
    try t.expectEqual(@as(u8, 6), m.dawn_hour);
    try t.expectEqual(@as(u8, 18), m.dusk_hour);
    try t.expectEqual(@as(u8, 2), m.min_per_hour);
    try t.expectEqual(@as(usize, 0), m.area_list.len);
    try t.expectEqual(@as(usize, 0), m.hak_list.len);
    try t.expectEqual(@as(u8, 0), m.is_save_game);
}

test "IFO scalar fields round-trip" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const a = ifo.arena.allocator();

    ifo.module.expansion_pack = 1;
    ifo.module.dawn_hour = 5;
    ifo.module.dusk_hour = 19;
    ifo.module.min_per_hour = 4;
    ifo.module.start_day = 15;
    ifo.module.start_month = 3;
    ifo.module.start_hour = 8;
    ifo.module.start_year = 1372;
    ifo.module.xp_scale = 75;
    ifo.module.tag = try a.dupe(u8, "MyModule");
    ifo.module.custom_tlk = try a.dupe(u8, "my_custom");
    ifo.module.min_game_ver = try a.dupe(u8, "1.69");
    ifo.module.entry_area = gff.ResRef.fromSlice("start_area");
    ifo.module.entry_x = 10.5;
    ifo.module.entry_y = 20.0;
    ifo.module.entry_z = 0.0;
    ifo.module.entry_dir_x = 0.0;
    ifo.module.entry_dir_y = 1.0;

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();
    const m = &ifo2.module;

    try t.expectEqual(@as(u16, 1), m.expansion_pack);
    try t.expectEqual(@as(u8, 5), m.dawn_hour);
    try t.expectEqual(@as(u8, 19), m.dusk_hour);
    try t.expectEqual(@as(u8, 4), m.min_per_hour);
    try t.expectEqual(@as(u8, 15), m.start_day);
    try t.expectEqual(@as(u8, 3), m.start_month);
    try t.expectEqual(@as(u8, 8), m.start_hour);
    try t.expectEqual(@as(u32, 1372), m.start_year);
    try t.expectEqual(@as(u8, 75), m.xp_scale);
    try t.expectEqualStrings("MyModule", m.tag);
    try t.expectEqualStrings("my_custom", m.custom_tlk);
    try t.expectEqualStrings("1.69", m.min_game_ver);
    try t.expectEqualStrings("start_area", m.entry_area.slice());
    try t.expectApproxEqAbs(@as(f32, 10.5), m.entry_x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 1.0), m.entry_dir_y, 0.0001);
}

test "IFO script event ResRef fields round-trip" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();

    ifo.module.on_acquire_item = gff.ResRef.fromSlice("mod_acqitem");
    ifo.module.on_activate_item = gff.ResRef.fromSlice("mod_actvitem");
    ifo.module.on_client_enter = gff.ResRef.fromSlice("mod_enter");
    ifo.module.on_client_leave = gff.ResRef.fromSlice("mod_leave");
    ifo.module.on_heartbeat = gff.ResRef.fromSlice("mod_hb");
    ifo.module.on_mod_load = gff.ResRef.fromSlice("mod_load");
    ifo.module.on_player_death = gff.ResRef.fromSlice("mod_death");
    ifo.module.on_player_level_up = gff.ResRef.fromSlice("mod_lvlup");
    ifo.module.on_player_rest = gff.ResRef.fromSlice("mod_rest");
    ifo.module.on_player_respawn = gff.ResRef.fromSlice("mod_spawn");
    ifo.module.on_unacquire_item = gff.ResRef.fromSlice("mod_unacq");
    ifo.module.on_user_defined = gff.ResRef.fromSlice("mod_udef");

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();
    const m = &ifo2.module;

    try t.expectEqualStrings("mod_acqitem", m.on_acquire_item.slice());
    try t.expectEqualStrings("mod_enter", m.on_client_enter.slice());
    try t.expectEqualStrings("mod_hb", m.on_heartbeat.slice());
    try t.expectEqualStrings("mod_load", m.on_mod_load.slice());
    try t.expectEqualStrings("mod_death", m.on_player_death.slice());
    try t.expectEqualStrings("mod_lvlup", m.on_player_level_up.slice());
    try t.expectEqualStrings("mod_spawn", m.on_player_respawn.slice());
    try t.expectEqualStrings("mod_udef", m.on_user_defined.slice());
}

test "IFO area and hak lists round-trip" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const a = ifo.arena.allocator();

    const areas = try a.alloc(AreaEntry, 2);
    areas[0] = .{ .area_name = gff.ResRef.fromSlice("start") };
    areas[1] = .{ .area_name = gff.ResRef.fromSlice("dungeon01") };
    ifo.module.area_list = areas;

    const haks = try a.alloc(HakEntry, 2);
    haks[0] = .{ .mod_hak = try a.dupe(u8, "premium") };
    haks[1] = .{ .mod_hak = try a.dupe(u8, "hak_extra") };
    ifo.module.hak_list = haks;

    const cache = try a.alloc(CacheEntry, 1);
    cache[0] = .{ .res_ref = gff.ResRef.fromSlice("nw_c2_default1") };
    ifo.module.cache_nss_list = cache;

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();
    const m = &ifo2.module;

    try t.expectEqual(@as(usize, 2), m.area_list.len);
    try t.expectEqualStrings("start", m.area_list[0].area_name.slice());
    try t.expectEqualStrings("dungeon01", m.area_list[1].area_name.slice());

    try t.expectEqual(@as(usize, 2), m.hak_list.len);
    try t.expectEqualStrings("premium", m.hak_list[0].mod_hak);
    try t.expectEqualStrings("hak_extra", m.hak_list[1].mod_hak);

    try t.expectEqual(@as(usize, 1), m.cache_nss_list.len);
    try t.expectEqualStrings("nw_c2_default1", m.cache_nss_list[0].res_ref.slice());
}

test "IFO Mod_ID binary round-trip" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const a = ifo.arena.allocator();

    const id_bytes = [16]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    ifo.module.mod_id = try a.dupe(u8, &id_bytes);

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();

    try t.expectEqualSlices(u8, &id_bytes, ifo2.module.mod_id);
}

test "IFO savegame fields round-trip (Mod_Effect_NxtId, tokens, var table)" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const a = ifo.arena.allocator();

    ifo.module.is_save_game = 1;
    ifo.module.effect_next_id = 0xCAFE_BABE_1234_5678;
    ifo.module.is_nwm_file = 0;
    ifo.module.next_char_id_0 = 100;
    ifo.module.next_char_id_1 = 0;
    ifo.module.next_obj_id_0 = 200;
    ifo.module.next_obj_id_1 = 1;
    ifo.module.nwm_res_name = try a.dupe(u8, "mymod");

    const tokens = try a.alloc(Token, 2);
    tokens[0] = .{ .number = 10001, .value = try a.dupe(u8, "PlayerName") };
    tokens[1] = .{ .number = 10002, .value = try a.dupe(u8, "GuildName") };
    ifo.module.tokens = tokens;

    const vars = try a.alloc(common.Variable, 1);
    vars[0] = .{ .name = try a.dupe(u8, "nKillCount"), .value = .{ .int_val = 42 } };
    ifo.module.mod_var_table = vars;

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();
    const m = &ifo2.module;

    try t.expectEqual(@as(u8, 1), m.is_save_game);
    try t.expectEqual(@as(u64, 0xCAFE_BABE_1234_5678), m.effect_next_id);
    try t.expectEqual(@as(u32, 100), m.next_char_id_0);
    try t.expectEqual(@as(u32, 200), m.next_obj_id_0);
    try t.expectEqual(@as(u32, 1), m.next_obj_id_1);
    try t.expectEqualStrings("mymod", m.nwm_res_name);

    try t.expectEqual(@as(usize, 2), m.tokens.len);
    try t.expectEqual(@as(u32, 10001), m.tokens[0].number);
    try t.expectEqualStrings("PlayerName", m.tokens[0].value);
    try t.expectEqual(@as(u32, 10002), m.tokens[1].number);

    try t.expectEqual(@as(usize, 1), m.mod_var_table.len);
    try t.expectEqualStrings("nKillCount", m.mod_var_table[0].name);
    try t.expectEqual(@as(i32, 42), m.mod_var_table[0].value.int_val);
}

test "IFO TURD round-trip" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const a = ifo.arena.allocator();

    ifo.module.is_save_game = 1;

    const turds = try a.alloc(TurdEntry, 1);
    var td: TurdEntry = .{};
    td.area_id = 0x1234;
    td.calendar_day = 7;
    td.time_of_day = 1200;
    td.player_id = 0xABCD;
    td.community_name = try a.dupe(u8, "StevePlayer");
    td.first_name = .{ .string_ref = 0, .substrings = .empty };
    try td.first_name.substrings.append(a, .{ .string_id = 0, .text = try a.dupe(u8, "Steve") });
    td.position_x = 5.0;
    td.position_y = 10.0;
    td.position_z = 0.0;
    td.orient_x = 0.707;
    td.orient_y = 0.707;
    td.orient_z = 0.0;
    const reps = try a.alloc(i32, 3);
    reps[0] = 50;
    reps[1] = 75;
    reps[2] = 25;
    td.rep_list = reps;
    turds[0] = td;
    ifo.module.turd_list = turds;

    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);
    var ifo2 = try IfoFile.parse(gpa, bytes);
    defer ifo2.deinit();
    const m = &ifo2.module;

    try t.expectEqual(@as(usize, 1), m.turd_list.len);
    const t0 = &m.turd_list[0];
    try t.expectEqual(@as(u32, 0x1234), t0.area_id);
    try t.expectEqual(@as(u32, 7), t0.calendar_day);
    try t.expectEqual(@as(u32, 0xABCD), t0.player_id);
    try t.expectEqualStrings("StevePlayer", t0.community_name);
    try t.expectApproxEqAbs(@as(f32, 5.0), t0.position_x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 10.0), t0.position_y, 0.0001);
    try t.expectEqual(@as(usize, 3), t0.rep_list.len);
    try t.expectEqual(@as(i32, 50), t0.rep_list[0]);
    try t.expectEqual(@as(i32, 75), t0.rep_list[1]);
    try t.expectEqual(@as(usize, 1), t0.first_name.substrings.items.len);
    try t.expectEqualStrings("Steve", t0.first_name.substrings.items[0].text);
}

test "IFO byte-exact double-serialize" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const a = ifo.arena.allocator();

    ifo.module.expansion_pack = 3;
    ifo.module.tag = try a.dupe(u8, "TestMod");
    ifo.module.dawn_hour = 7;
    ifo.module.dusk_hour = 20;
    ifo.module.start_year = 1372;
    ifo.module.entry_area = gff.ResRef.fromSlice("area01");
    ifo.module.on_mod_load = gff.ResRef.fromSlice("mod_load");
    const areas = try a.alloc(AreaEntry, 1);
    areas[0] = .{ .area_name = gff.ResRef.fromSlice("area01") };
    ifo.module.area_list = areas;

    const b1 = try ifo.serialize(gpa);
    defer gpa.free(b1);
    var ifo2 = try IfoFile.parse(gpa, b1);
    defer ifo2.deinit();
    const b2 = try ifo2.serialize(gpa);
    defer gpa.free(b2);
    try t.expectEqualSlices(u8, b1, b2);
}

test "IFO wrong magic rejected" {
    const gpa = t.allocator;
    var ifo = IfoFile.init(gpa);
    defer ifo.deinit();
    const bytes = try ifo.serialize(gpa);
    defer gpa.free(bytes);

    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    @memcpy(bad[0..4], "IFX ");
    try t.expectError(error.InvalidFileType, IfoFile.parse(gpa, bad));
}
