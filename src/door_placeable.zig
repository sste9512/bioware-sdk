//! BioWare Aurora Door (UTD) and Placeable Object (UTP) GFF reader/writer.
//!
//! Spec: Bioware_Aurora_DoorPlaceableGFF.pdf
//!   §2   Shared Situated Object base (Tables 2.1–2.4)
//!   §3   Door-specific fields (Tables 3.1, 3.4)
//!   §4   Placeable Object fields (Tables 4.1, 4.4)
//!
//! Door blueprints → "UTD " files; instances → DoorStructs embedded in GIT.
//! Placeable blueprints → "UTP " files; instances → PlaceableStructs in GIT.
//!
//! Memory: *File wrappers own an ArenaAllocator. Call deinit() once to free all.

const std = @import("std");
const gff = @import("gff.zig");
const common = @import("common_gff.zig");
const item_mod = @import("item.zig");

pub const DOOR_FILE_TYPE = "UTD ";
pub const PLACEABLE_FILE_TYPE = "UTP ";

// ============================================================================
// Errors / Variant
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

/// Selects which optional field groups are present (spec §2.2–§2.4).
pub const SituatedVariant = enum {
    /// Standalone UTD/UTP blueprint file: §2.1 + §2.2.
    blueprint,
    /// Embedded in a toolset GIT: §2.1 + §2.3.
    instance,
    /// Embedded in a saved-game GIT: §2.1 + §2.3 + §2.4.
    game_instance,
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
inline fn optByteOrNull(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?u8 {
    const f = g.getField(s, l) orelse return null;
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
inline fn optShort(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: i16) Error!i16 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .short => |v| v,
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
inline fn optIntOrNull(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?i32 {
    const f = g.getField(s, l) orelse return null;
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
inline fn optDwordOrNull(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?u32 {
    const f = g.getField(s, l) orelse return null;
    return switch (f.value) {
        .dword => |v| v,
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
fn optExoStringDupeOrNull(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?[]u8 {
    const f = g.getField(s, l) orelse return null;
    return switch (f.value) {
        .exo_string => |v| try a.dupe(u8, v),
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

// ============================================================================
// Shared Situated parse/write (§2.1, §2.2, §2.3, §2.4)
//
// Both DoorStruct and PlaceableStruct carry identical common fields.
// Comptime T avoids duplicating all 40+ field assignments.
// ============================================================================

fn parseSituatedCommon(
    comptime T: type,
    out: *T,
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
    variant: SituatedVariant,
    emit_anim_state: bool, // false for placeable game_instance (field removed)
) Error!void {
    if (emit_anim_state)
        out.animation_state = try optByte(g, s, "AnimationState", 0);
    out.appearance = try optDword(g, s, "Appearance", 0);
    out.auto_remove_key = try optByte(g, s, "AutoRemoveKey", 0);
    out.close_lock_dc = try optByte(g, s, "CloseLockDC", 0);
    out.conversation = try optResRef(g, s, "Conversation");
    out.current_hp = try optShort(g, s, "CurrentHP", 0);
    out.description = try optExoLocDupe(arena, g, s, "Description");
    out.disarm_dc = try optByte(g, s, "DisarmDC", 0);
    out.faction = try optDword(g, s, "Faction", 0);
    out.fort = try optByte(g, s, "Fort", 0);
    out.hardness = try optByte(g, s, "Hardness", 0);
    out.hp = try optShort(g, s, "HP", 0);
    out.interruptable = try optByte(g, s, "Interruptable", 0);
    out.lockable = try optByte(g, s, "Lockable", 0);
    out.locked = try optByte(g, s, "Locked", 0);
    out.loc_name = try optExoLocDupe(arena, g, s, "LocName");
    out.on_closed = try optResRef(g, s, "OnClosed");
    out.on_damaged = try optResRef(g, s, "OnDamaged");
    out.on_death = try optResRef(g, s, "OnDeath");
    out.on_disarm = try optResRef(g, s, "OnDisarm");
    out.on_heartbeat = try optResRef(g, s, "OnHeartbeat");
    out.on_lock = try optResRef(g, s, "OnLock");
    out.on_melee_attacked = try optResRef(g, s, "OnMeleeAttacked");
    out.on_open = try optResRef(g, s, "OnOpen");
    out.on_spell_cast_at = try optResRef(g, s, "OnSpellCastAt");
    out.on_trap_triggered = try optResRef(g, s, "OnTrapTriggered");
    out.on_unlock = try optResRef(g, s, "OnUnlock");
    out.on_user_defined = try optResRef(g, s, "OnUserDefined");
    out.open_lock_dc = try optByte(g, s, "OpenLockDC", 0);
    out.plot = try optByte(g, s, "Plot", 0);
    out.portrait_id = try optWord(g, s, "PortraitId", 0);
    out.ref = try optByte(g, s, "Ref", 0);
    out.tag = try optExoStringDupe(arena, g, s, "Tag");
    out.template_res_ref = try optResRef(g, s, "TemplateResRef");
    out.trap_detectable = try optByte(g, s, "TrapDetectable", 0);
    out.trap_detect_dc = try optByte(g, s, "TrapDetectDC", 0);
    out.trap_disarmable = try optByte(g, s, "TrapDisarmable", 0);
    out.trap_flag = try optByte(g, s, "TrapFlag", 0);
    out.trap_one_shot = try optByte(g, s, "TrapOneShot", 0);
    out.trap_type = try optByte(g, s, "TrapType", 0);
    out.will = try optByte(g, s, "Will", 0);

    switch (variant) {
        .blueprint => {
            out.comment = try optExoStringDupeOrNull(arena, g, s, "Comment");
            out.palette_id = try optByteOrNull(g, s, "PaletteID");
        },
        .instance, .game_instance => {
            out.bearing = try optFloat(g, s, "Bearing", 0);
            out.x = try optFloat(g, s, "X", 0);
            out.y = try optFloat(g, s, "Y", 0);
            out.z = try optFloat(g, s, "Z", 0);
            if (variant == .game_instance) {
                out.action_list = try common.parseActionList(arena, g, s);
                out.animation_day = try optDword(g, s, "AnimationDay", 0);
                out.animation_time = try optDword(g, s, "AnimationTime", 0);
                out.effect_list = try common.parseEffectsList(arena, g, s);
                out.object_id = try optDwordOrNull(g, s, "ObjectId");
                out.var_table = try common.parseVarTable(arena, g, s);
            }
        },
    }
}

fn writeSituatedCommon(
    comptime T: type,
    self: *const T,
    g: *gff.GffFile,
    struct_idx: u32,
    variant: SituatedVariant,
    emit_anim_state: bool,
) !void {
    const a = g.allocator;
    if (emit_anim_state)
        try g.addFieldToStruct(struct_idx, "AnimationState", .{ .byte = self.animation_state });
    try g.addFieldToStruct(struct_idx, "Appearance", .{ .dword = self.appearance });
    try g.addFieldToStruct(struct_idx, "AutoRemoveKey", .{ .byte = self.auto_remove_key });
    try g.addFieldToStruct(struct_idx, "CloseLockDC", .{ .byte = self.close_lock_dc });
    try g.addFieldToStruct(struct_idx, "Conversation", .{ .res_ref = self.conversation });
    try g.addFieldToStruct(struct_idx, "CurrentHP", .{ .short = self.current_hp });
    try g.addFieldToStruct(struct_idx, "Description", .{ .exo_loc_string = try cloneExoLoc(a, self.description) });
    try g.addFieldToStruct(struct_idx, "DisarmDC", .{ .byte = self.disarm_dc });
    try g.addFieldToStruct(struct_idx, "Faction", .{ .dword = self.faction });
    try g.addFieldToStruct(struct_idx, "Fort", .{ .byte = self.fort });
    try g.addFieldToStruct(struct_idx, "Hardness", .{ .byte = self.hardness });
    try g.addFieldToStruct(struct_idx, "HP", .{ .short = self.hp });
    try g.addFieldToStruct(struct_idx, "Interruptable", .{ .byte = self.interruptable });
    try g.addFieldToStruct(struct_idx, "Lockable", .{ .byte = self.lockable });
    try g.addFieldToStruct(struct_idx, "Locked", .{ .byte = self.locked });
    try g.addFieldToStruct(struct_idx, "LocName", .{ .exo_loc_string = try cloneExoLoc(a, self.loc_name) });
    try g.addFieldToStruct(struct_idx, "OnClosed", .{ .res_ref = self.on_closed });
    try g.addFieldToStruct(struct_idx, "OnDamaged", .{ .res_ref = self.on_damaged });
    try g.addFieldToStruct(struct_idx, "OnDeath", .{ .res_ref = self.on_death });
    try g.addFieldToStruct(struct_idx, "OnDisarm", .{ .res_ref = self.on_disarm });
    try g.addFieldToStruct(struct_idx, "OnHeartbeat", .{ .res_ref = self.on_heartbeat });
    try g.addFieldToStruct(struct_idx, "OnLock", .{ .res_ref = self.on_lock });
    try g.addFieldToStruct(struct_idx, "OnMeleeAttacked", .{ .res_ref = self.on_melee_attacked });
    try g.addFieldToStruct(struct_idx, "OnOpen", .{ .res_ref = self.on_open });
    try g.addFieldToStruct(struct_idx, "OnSpellCastAt", .{ .res_ref = self.on_spell_cast_at });
    try g.addFieldToStruct(struct_idx, "OnTrapTriggered", .{ .res_ref = self.on_trap_triggered });
    try g.addFieldToStruct(struct_idx, "OnUnlock", .{ .res_ref = self.on_unlock });
    try g.addFieldToStruct(struct_idx, "OnUserDefined", .{ .res_ref = self.on_user_defined });
    try g.addFieldToStruct(struct_idx, "OpenLockDC", .{ .byte = self.open_lock_dc });
    try g.addFieldToStruct(struct_idx, "Plot", .{ .byte = self.plot });
    try g.addFieldToStruct(struct_idx, "PortraitId", .{ .word = self.portrait_id });
    try g.addFieldToStruct(struct_idx, "Ref", .{ .byte = self.ref });
    try g.addFieldToStruct(struct_idx, "Tag", .{ .exo_string = try a.dupe(u8, self.tag) });
    try g.addFieldToStruct(struct_idx, "TemplateResRef", .{ .res_ref = self.template_res_ref });
    try g.addFieldToStruct(struct_idx, "TrapDetectable", .{ .byte = self.trap_detectable });
    try g.addFieldToStruct(struct_idx, "TrapDetectDC", .{ .byte = self.trap_detect_dc });
    try g.addFieldToStruct(struct_idx, "TrapDisarmable", .{ .byte = self.trap_disarmable });
    try g.addFieldToStruct(struct_idx, "TrapFlag", .{ .byte = self.trap_flag });
    try g.addFieldToStruct(struct_idx, "TrapOneShot", .{ .byte = self.trap_one_shot });
    try g.addFieldToStruct(struct_idx, "TrapType", .{ .byte = self.trap_type });
    try g.addFieldToStruct(struct_idx, "Will", .{ .byte = self.will });

    switch (variant) {
        .blueprint => {
            if (self.comment) |c|
                try g.addFieldToStruct(struct_idx, "Comment", .{ .exo_string = try a.dupe(u8, c) });
            if (self.palette_id) |v|
                try g.addFieldToStruct(struct_idx, "PaletteID", .{ .byte = v });
        },
        .instance, .game_instance => {
            try g.addFieldToStruct(struct_idx, "Bearing", .{ .float = self.bearing orelse 0 });
            try g.addFieldToStruct(struct_idx, "X", .{ .float = self.x orelse 0 });
            try g.addFieldToStruct(struct_idx, "Y", .{ .float = self.y orelse 0 });
            try g.addFieldToStruct(struct_idx, "Z", .{ .float = self.z orelse 0 });
            if (variant == .game_instance) {
                try common.writeActionList(g, struct_idx, self.action_list);
                try g.addFieldToStruct(struct_idx, "AnimationDay", .{ .dword = self.animation_day });
                try g.addFieldToStruct(struct_idx, "AnimationTime", .{ .dword = self.animation_time });
                try common.writeEffectsList(g, struct_idx, self.effect_list);
                if (self.object_id) |id|
                    try g.addFieldToStruct(struct_idx, "ObjectId", .{ .dword = id });
                try common.writeVarTable(g, struct_idx, self.var_table);
            }
        },
    }
}

// ============================================================================
// DoorStruct  (§2.1 + §2.2/§2.3/§2.4 + §3.1 + §3.4)
// ============================================================================

pub const DoorStruct = struct {
    // ---- §2.1 common --------------------------------------------------------
    animation_state: u8 = 0,
    appearance: u32 = 0,
    auto_remove_key: u8 = 0,
    bearing: ?f32 = null,
    close_lock_dc: u8 = 0,
    conversation: gff.ResRef = EMPTY_RES_REF,
    current_hp: i16 = 0,
    description: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    disarm_dc: u8 = 0,
    faction: u32 = 0,
    fort: u8 = 0,
    hardness: u8 = 0,
    hp: i16 = 0,
    interruptable: u8 = 0,
    lockable: u8 = 0,
    locked: u8 = 0,
    loc_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    on_closed: gff.ResRef = EMPTY_RES_REF,
    on_damaged: gff.ResRef = EMPTY_RES_REF,
    on_death: gff.ResRef = EMPTY_RES_REF,
    on_disarm: gff.ResRef = EMPTY_RES_REF,
    on_heartbeat: gff.ResRef = EMPTY_RES_REF,
    on_lock: gff.ResRef = EMPTY_RES_REF,
    on_melee_attacked: gff.ResRef = EMPTY_RES_REF,
    on_open: gff.ResRef = EMPTY_RES_REF,
    on_spell_cast_at: gff.ResRef = EMPTY_RES_REF,
    on_trap_triggered: gff.ResRef = EMPTY_RES_REF,
    on_unlock: gff.ResRef = EMPTY_RES_REF,
    on_user_defined: gff.ResRef = EMPTY_RES_REF,
    open_lock_dc: u8 = 0,
    plot: u8 = 0,
    portrait_id: u16 = 0,
    ref: u8 = 0,
    tag: []u8 = &.{},
    template_res_ref: gff.ResRef = EMPTY_RES_REF,
    trap_detectable: u8 = 0,
    trap_detect_dc: u8 = 0,
    trap_disarmable: u8 = 0,
    trap_flag: u8 = 0,
    trap_one_shot: u8 = 0,
    trap_type: u8 = 0,
    will: u8 = 0,

    // ---- §2.2 blueprint-only ------------------------------------------------
    comment: ?[]u8 = null,
    palette_id: ?u8 = null,

    // ---- §2.3 instance-only -------------------------------------------------
    x: ?f32 = null,
    y: ?f32 = null,
    z: ?f32 = null,

    // ---- §2.4 game-instance-only --------------------------------------------
    action_list: []common.Action = &.{},
    animation_day: u32 = 0,
    animation_time: u32 = 0,
    effect_list: []common.Effect = &.{},
    object_id: ?u32 = null,
    var_table: []common.Variable = &.{},

    // ---- §3.1 door-specific -------------------------------------------------
    generic_type: u8 = 0,
    linked_to: []u8 = &.{},
    linked_to_flags: u8 = 0,
    load_screen_id: u16 = 0,
    on_click: gff.ResRef = EMPTY_RES_REF,
    on_fail_to_open: gff.ResRef = EMPTY_RES_REF,

    // ---- §3.4 door game-instance-only ---------------------------------------
    /// Obsolete field preserved for round-trip fidelity.
    secret_door_dc: u8 = 0,

    // -------------------------------------------------------------------------

    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: SituatedVariant,
    ) Error!DoorStruct {
        var out: DoorStruct = .{};
        try parseSituatedCommon(DoorStruct, &out, arena, g, s, variant, true);

        // §3.1
        out.generic_type = try optByte(g, s, "GenericType", 0);
        out.linked_to = try optExoStringDupe(arena, g, s, "LinkedTo");
        out.linked_to_flags = try optByte(g, s, "LinkedToFlags", 0);
        out.load_screen_id = try optWord(g, s, "LoadScreenID", 0);
        out.on_click = try optResRef(g, s, "OnClick");
        out.on_fail_to_open = try optResRef(g, s, "OnFailToOpen");

        if (variant == .game_instance)
            out.secret_door_dc = try optByte(g, s, "SecretDoorDC", 0);

        return out;
    }

    pub fn writeIntoGff(
        self: *const DoorStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: SituatedVariant,
    ) !void {
        try writeSituatedCommon(DoorStruct, self, g, struct_idx, variant, true);

        // §3.1 — interleaved alphabetically with common fields
        try g.addFieldToStruct(struct_idx, "GenericType", .{ .byte = self.generic_type });
        try g.addFieldToStruct(struct_idx, "LinkedTo", .{ .exo_string = try g.allocator.dupe(u8, self.linked_to) });
        try g.addFieldToStruct(struct_idx, "LinkedToFlags", .{ .byte = self.linked_to_flags });
        try g.addFieldToStruct(struct_idx, "LoadScreenID", .{ .word = self.load_screen_id });
        try g.addFieldToStruct(struct_idx, "OnClick", .{ .res_ref = self.on_click });
        try g.addFieldToStruct(struct_idx, "OnFailToOpen", .{ .res_ref = self.on_fail_to_open });

        if (variant == .game_instance)
            try g.addFieldToStruct(struct_idx, "SecretDoorDC", .{ .byte = self.secret_door_dc });
    }
};

// ============================================================================
// UtdFile — standalone door blueprint
// ============================================================================

pub const UtdFile = struct {
    arena: std.heap.ArenaAllocator,
    door: DoorStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UtdFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UtdFile) void {
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtdFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &DOOR_FILE_TYPE.*);

        var out = UtdFile.init(parent_alloc);
        errdefer out.deinit();
        out.door = try DoorStruct.fromGffStruct(out.arena.allocator(), &g, &g.structs.items[0], .blueprint);
        return out;
    }

    pub fn serialize(self: *const UtdFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, DOOR_FILE_TYPE.*);
        defer g.deinit();
        try self.door.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// PlaceableInventoryItem  (§4.1.3, §4.2.2)
// ============================================================================

/// An item slot in a Placeable's inventory (ItemList).
/// StructID = slot index in the list (spec §4.1).
pub const PlaceableInventoryItem = struct {
    repos_pos_x: u16 = 0,
    repos_pos_y: u16 = 0,
    /// Blueprint: ResRef of the UTI blueprint file for this item (§4.2.2).
    /// Ignored for instance/game_instance variants.
    inventory_res: gff.ResRef = EMPTY_RES_REF,
    /// Instance: the embedded item (container variant — no position fields).
    /// Null for blueprint variants.
    item: ?item_mod.ItemStruct = null,

    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: SituatedVariant,
    ) Error!PlaceableInventoryItem {
        var out: PlaceableInventoryItem = .{};
        out.repos_pos_x = try optWord(g, s, "Repos_PosX", 0);
        out.repos_pos_y = try optWord(g, s, "Repos_PosY", 0);
        switch (variant) {
            .blueprint => {
                out.inventory_res = try optResRef(g, s, "InventoryRes");
            },
            .instance, .game_instance => {
                out.item = try item_mod.ItemStruct.fromGffStruct(arena, g, s, .container);
            },
        }
        return out;
    }

    pub fn writeIntoGff(
        self: *const PlaceableInventoryItem,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: SituatedVariant,
    ) !void {
        switch (variant) {
            .blueprint => {
                try g.addFieldToStruct(struct_idx, "InventoryRes", .{ .res_ref = self.inventory_res });
            },
            .instance, .game_instance => {
                if (self.item) |*it|
                    try it.writeIntoGff(g.allocator, g, struct_idx, .container);
            },
        }
        try g.addFieldToStruct(struct_idx, "Repos_PosX", .{ .word = self.repos_pos_x });
        try g.addFieldToStruct(struct_idx, "Repos_PosY", .{ .word = self.repos_pos_y });
    }
};

// ============================================================================
// PlaceableStruct  (§2.1 + §2.2/§2.3/§2.4 + §4.1 + §4.4)
// ============================================================================

pub const PlaceableStruct = struct {
    // ---- §2.1 common --------------------------------------------------------
    animation_state: u8 = 0,
    appearance: u32 = 0,
    auto_remove_key: u8 = 0,
    bearing: ?f32 = null,
    close_lock_dc: u8 = 0,
    conversation: gff.ResRef = EMPTY_RES_REF,
    current_hp: i16 = 0,
    description: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    disarm_dc: u8 = 0,
    faction: u32 = 0,
    fort: u8 = 0,
    hardness: u8 = 0,
    hp: i16 = 0,
    interruptable: u8 = 0,
    lockable: u8 = 0,
    locked: u8 = 0,
    loc_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    on_closed: gff.ResRef = EMPTY_RES_REF,
    on_damaged: gff.ResRef = EMPTY_RES_REF,
    on_death: gff.ResRef = EMPTY_RES_REF,
    on_disarm: gff.ResRef = EMPTY_RES_REF,
    on_heartbeat: gff.ResRef = EMPTY_RES_REF,
    on_lock: gff.ResRef = EMPTY_RES_REF,
    on_melee_attacked: gff.ResRef = EMPTY_RES_REF,
    on_open: gff.ResRef = EMPTY_RES_REF,
    on_spell_cast_at: gff.ResRef = EMPTY_RES_REF,
    on_trap_triggered: gff.ResRef = EMPTY_RES_REF,
    on_unlock: gff.ResRef = EMPTY_RES_REF,
    on_user_defined: gff.ResRef = EMPTY_RES_REF,
    open_lock_dc: u8 = 0,
    plot: u8 = 0,
    portrait_id: u16 = 0,
    ref: u8 = 0,
    tag: []u8 = &.{},
    template_res_ref: gff.ResRef = EMPTY_RES_REF,
    trap_detectable: u8 = 0,
    trap_detect_dc: u8 = 0,
    trap_disarmable: u8 = 0,
    trap_flag: u8 = 0,
    trap_one_shot: u8 = 0,
    trap_type: u8 = 0,
    will: u8 = 0,

    // ---- §2.2 blueprint-only ------------------------------------------------
    comment: ?[]u8 = null,
    palette_id: ?u8 = null,

    // ---- §2.3 instance-only -------------------------------------------------
    x: ?f32 = null,
    y: ?f32 = null,
    z: ?f32 = null,

    // ---- §2.4 game-instance-only --------------------------------------------
    action_list: []common.Action = &.{},
    animation_day: u32 = 0,
    animation_time: u32 = 0,
    effect_list: []common.Effect = &.{},
    object_id: ?u32 = null,
    var_table: []common.Variable = &.{},

    // ---- §4.1 placeable-specific --------------------------------------------
    body_bag: u8 = 0,
    has_inventory: u8 = 0,
    item_list: []PlaceableInventoryItem = &.{},
    on_inv_disturbed: gff.ResRef = EMPTY_RES_REF,
    on_used: gff.ResRef = EMPTY_RES_REF,
    /// GFF label "Static" — renamed to avoid Zig reserved-keyword collision.
    is_static: u8 = 0,
    /// GFF label "Type" — obsolete, always 0.
    object_type: u8 = 0,
    useable: u8 = 0,

    // ---- §4.4 placeable game-instance-only ----------------------------------
    /// INT animation state replacing §2.1 AnimationState in savefiles.
    animation: ?i32 = null,
    die_when_empty: ?u8 = null,
    /// Obsolete. Always 0.
    ground_pile: ?u8 = null,
    light_state: ?u8 = null,
    portal: ?[]u8 = null,
    trap_creator: ?u32 = null,
    trap_faction: ?u32 = null,

    // -------------------------------------------------------------------------

    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: SituatedVariant,
    ) Error!PlaceableStruct {
        var out: PlaceableStruct = .{};

        // §4.4 replaces AnimationState with Animation in game saves.
        const is_game_save = (variant == .game_instance) and (g.getField(s, "Animation") != null);
        try parseSituatedCommon(PlaceableStruct, &out, arena, g, s, variant, !is_game_save);

        // §4.1
        out.body_bag = try optByte(g, s, "BodyBag", 0);
        out.has_inventory = try optByte(g, s, "HasInventory", 0);
        out.on_inv_disturbed = try optResRef(g, s, "OnInvDisturbed");
        out.on_used = try optResRef(g, s, "OnUsed");
        out.is_static = try optByte(g, s, "Static", 0);
        out.object_type = try optByte(g, s, "Type", 0);
        out.useable = try optByte(g, s, "Useable", 0);
        out.item_list = try parsePlaceableItems(arena, g, s, variant);

        if (variant == .game_instance) {
            out.animation = try optIntOrNull(g, s, "Animation");
            out.die_when_empty = try optByteOrNull(g, s, "DieWhenEmpty");
            out.ground_pile = try optByteOrNull(g, s, "GroundPile");
            out.light_state = try optByteOrNull(g, s, "LightState");
            out.portal = try optExoStringDupeOrNull(arena, g, s, "Portal");
            out.trap_creator = try optDwordOrNull(g, s, "TrapCreator");
            out.trap_faction = try optDwordOrNull(g, s, "TrapFaction");
        }

        return out;
    }

    pub fn writeIntoGff(
        self: *const PlaceableStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: SituatedVariant,
    ) !void {
        const a = g.allocator;
        // §4.4 game saves: Animation replaces AnimationState
        const emit_anim_state = !(variant == .game_instance and self.animation != null);
        try writeSituatedCommon(PlaceableStruct, self, g, struct_idx, variant, emit_anim_state);

        // §4.1
        try g.addFieldToStruct(struct_idx, "BodyBag", .{ .byte = self.body_bag });
        try g.addFieldToStruct(struct_idx, "HasInventory", .{ .byte = self.has_inventory });
        try g.addFieldToStruct(struct_idx, "OnInvDisturbed", .{ .res_ref = self.on_inv_disturbed });
        try g.addFieldToStruct(struct_idx, "OnUsed", .{ .res_ref = self.on_used });
        try g.addFieldToStruct(struct_idx, "Static", .{ .byte = self.is_static });
        try g.addFieldToStruct(struct_idx, "Type", .{ .byte = self.object_type });
        try g.addFieldToStruct(struct_idx, "Useable", .{ .byte = self.useable });

        try writePlaceableItems(g, struct_idx, self.item_list, variant);

        if (variant == .game_instance) {
            if (self.animation) |v|
                try g.addFieldToStruct(struct_idx, "Animation", .{ .int = v });
            if (self.die_when_empty) |v|
                try g.addFieldToStruct(struct_idx, "DieWhenEmpty", .{ .byte = v });
            if (self.ground_pile) |v|
                try g.addFieldToStruct(struct_idx, "GroundPile", .{ .byte = v });
            if (self.light_state) |v|
                try g.addFieldToStruct(struct_idx, "LightState", .{ .byte = v });
            if (self.portal) |v|
                try g.addFieldToStruct(struct_idx, "Portal", .{ .exo_string = try a.dupe(u8, v) });
            if (self.trap_creator) |v|
                try g.addFieldToStruct(struct_idx, "TrapCreator", .{ .dword = v });
            if (self.trap_faction) |v|
                try g.addFieldToStruct(struct_idx, "TrapFaction", .{ .dword = v });
        }
    }
};

fn parsePlaceableItems(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
    variant: SituatedVariant,
) Error![]PlaceableInventoryItem {
    const f = g.getField(s, "ItemList") orelse return arena.alloc(PlaceableInventoryItem, 0);
    const handles = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(PlaceableInventoryItem, handles.len);
    for (handles, 0..) |h, i|
        out[i] = try PlaceableInventoryItem.fromGffStruct(arena, g, &g.structs.items[h], variant);
    return out;
}

fn writePlaceableItems(
    g: *gff.GffFile,
    parent_idx: u32,
    items: []const PlaceableInventoryItem,
    variant: SituatedVariant,
) !void {
    if (items.len == 0) return;
    const handles = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(handles);
    for (items, 0..) |*it, i| {
        const sidx = try g.addStruct(@intCast(i)); // StructID = slot index per spec
        try it.writeIntoGff(g, sidx, variant);
        handles[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, "ItemList", .{ .list = handles });
}

// ============================================================================
// UtpFile — standalone placeable blueprint
// ============================================================================

pub const UtpFile = struct {
    arena: std.heap.ArenaAllocator,
    placeable: PlaceableStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UtpFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UtpFile) void {
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtpFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &PLACEABLE_FILE_TYPE.*);

        var out = UtpFile.init(parent_alloc);
        errdefer out.deinit();
        out.placeable = try PlaceableStruct.fromGffStruct(
            out.arena.allocator(),
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    pub fn serialize(self: *const UtpFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, PLACEABLE_FILE_TYPE.*);
        defer g.deinit();
        try self.placeable.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty UTD round-trip" {
    const gpa = t.allocator;
    var utd = UtdFile.init(gpa);
    defer utd.deinit();

    const bytes = try utd.serialize(gpa);
    defer gpa.free(bytes);
    var utd2 = try UtdFile.parse(gpa, bytes);
    defer utd2.deinit();

    try t.expectEqual(@as(u32, 0), utd2.door.appearance);
    try t.expectEqual(@as(u8, 0), utd2.door.locked);
    try t.expectEqual(@as(i16, 0), utd2.door.hp);
    try t.expect(utd2.door.comment == null);
    try t.expectEqual(@as(?u8, null), utd2.door.palette_id);
}

test "UTD common scalar fields round-trip" {
    const gpa = t.allocator;
    var utd = UtdFile.init(gpa);
    defer utd.deinit();
    const a = utd.arena.allocator();

    utd.door.appearance = 5;
    utd.door.hp = 50;
    utd.door.current_hp = 50;
    utd.door.hardness = 5;
    utd.door.locked = 1;
    utd.door.lockable = 1;
    utd.door.open_lock_dc = 20;
    utd.door.close_lock_dc = 15;
    utd.door.faction = 3;
    utd.door.fort = 4;
    utd.door.ref = 2;
    utd.door.will = 1;
    utd.door.trap_flag = 1;
    utd.door.trap_type = 2;
    utd.door.trap_detectable = 1;
    utd.door.trap_detect_dc = 10;
    utd.door.trap_disarmable = 1;
    utd.door.disarm_dc = 15;
    utd.door.tag = try a.dupe(u8, "DoorFront01");
    utd.door.template_res_ref = gff.ResRef.fromSlice("doorfront01");
    utd.door.on_open = gff.ResRef.fromSlice("door_open");
    utd.door.on_closed = gff.ResRef.fromSlice("door_close");
    utd.door.on_death = gff.ResRef.fromSlice("door_death");
    utd.door.on_heartbeat = gff.ResRef.fromSlice("door_hb");
    utd.door.comment = try a.dupe(u8, "Main entrance");
    utd.door.palette_id = 7;

    const bytes = try utd.serialize(gpa);
    defer gpa.free(bytes);
    var utd2 = try UtdFile.parse(gpa, bytes);
    defer utd2.deinit();
    const d = &utd2.door;

    try t.expectEqual(@as(u32, 5), d.appearance);
    try t.expectEqual(@as(i16, 50), d.hp);
    try t.expectEqual(@as(u8, 5), d.hardness);
    try t.expectEqual(@as(u8, 1), d.locked);
    try t.expectEqual(@as(u8, 20), d.open_lock_dc);
    try t.expectEqual(@as(u8, 3), d.trap_type);
    try t.expectEqualStrings("DoorFront01", d.tag);
    try t.expectEqualStrings("doorfront01", d.template_res_ref.slice());
    try t.expectEqualStrings("door_open", d.on_open.slice());
    try t.expectEqualStrings("Main entrance", d.comment.?);
    try t.expectEqual(@as(?u8, 7), d.palette_id);
}

test "UTD door-specific fields round-trip" {
    const gpa = t.allocator;
    var utd = UtdFile.init(gpa);
    defer utd.deinit();
    const a = utd.arena.allocator();

    utd.door.generic_type = 3;
    utd.door.linked_to = try a.dupe(u8, "WP_Exit");
    utd.door.linked_to_flags = 2;
    utd.door.load_screen_id = 12;
    utd.door.on_click = gff.ResRef.fromSlice("door_click");
    utd.door.on_fail_to_open = gff.ResRef.fromSlice("door_fail");

    const bytes = try utd.serialize(gpa);
    defer gpa.free(bytes);
    var utd2 = try UtdFile.parse(gpa, bytes);
    defer utd2.deinit();
    const d = &utd2.door;

    try t.expectEqual(@as(u8, 3), d.generic_type);
    try t.expectEqualStrings("WP_Exit", d.linked_to);
    try t.expectEqual(@as(u8, 2), d.linked_to_flags);
    try t.expectEqual(@as(u16, 12), d.load_screen_id);
    try t.expectEqualStrings("door_click", d.on_click.slice());
    try t.expectEqualStrings("door_fail", d.on_fail_to_open.slice());
}

test "DoorStruct instance variant round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var d: DoorStruct = .{};
    d.tag = try a.dupe(u8, "DoorWest");
    d.template_res_ref = gff.ResRef.fromSlice("nw_door_wood");
    d.appearance = 10;
    d.bearing = 1.5708;
    d.x = 20.0;
    d.y = 15.5;
    d.z = 0.0;

    const sidx = try g.addStruct(8);
    try d.writeIntoGff(&g, sidx, .instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try DoorStruct.fromGffStruct(arena2.allocator(), &g, &g.structs.items[sidx], .instance);

    try t.expectEqualStrings("DoorWest", parsed.tag);
    try t.expectEqualStrings("nw_door_wood", parsed.template_res_ref.slice());
    try t.expectEqual(@as(u32, 10), parsed.appearance);
    try t.expectApproxEqAbs(@as(f32, 1.5708), parsed.bearing.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 20.0), parsed.x.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 15.5), parsed.y.?, 0.0001);
    try t.expect(parsed.comment == null);
    try t.expect(parsed.palette_id == null);
}

test "UTD byte-exact double-serialize" {
    const gpa = t.allocator;
    var utd = UtdFile.init(gpa);
    defer utd.deinit();
    const a = utd.arena.allocator();

    utd.door.appearance = 2;
    utd.door.hp = 30;
    utd.door.current_hp = 30;
    utd.door.locked = 1;
    utd.door.tag = try a.dupe(u8, "DoorA");
    utd.door.generic_type = 1;
    utd.door.comment = try a.dupe(u8, "test");
    utd.door.palette_id = 1;

    const b1 = try utd.serialize(gpa);
    defer gpa.free(b1);
    var utd2 = try UtdFile.parse(gpa, b1);
    defer utd2.deinit();
    const b2 = try utd2.serialize(gpa);
    defer gpa.free(b2);
    try t.expectEqualSlices(u8, b1, b2);
}

test "UTD wrong magic rejected" {
    const gpa = t.allocator;
    var utd = UtdFile.init(gpa);
    defer utd.deinit();
    const bytes = try utd.serialize(gpa);
    defer gpa.free(bytes);

    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    @memcpy(bad[0..4], "UTX ");
    try t.expectError(error.InvalidFileType, UtdFile.parse(gpa, bad));
}

test "empty UTP round-trip" {
    const gpa = t.allocator;
    var utp = UtpFile.init(gpa);
    defer utp.deinit();

    const bytes = try utp.serialize(gpa);
    defer gpa.free(bytes);
    var utp2 = try UtpFile.parse(gpa, bytes);
    defer utp2.deinit();
    const p = &utp2.placeable;

    try t.expectEqual(@as(u32, 0), p.appearance);
    try t.expectEqual(@as(u8, 0), p.useable);
    try t.expectEqual(@as(u8, 0), p.has_inventory);
    try t.expectEqual(@as(usize, 0), p.item_list.len);
}

test "UTP placeable-specific fields round-trip" {
    const gpa = t.allocator;
    var utp = UtpFile.init(gpa);
    defer utp.deinit();
    const a = utp.arena.allocator();

    utp.placeable.appearance = 42;
    utp.placeable.useable = 1;
    utp.placeable.has_inventory = 1;
    utp.placeable.is_static = 0;
    utp.placeable.body_bag = 3;
    utp.placeable.hp = 25;
    utp.placeable.hardness = 2;
    utp.placeable.tag = try a.dupe(u8, "PlcChest01");
    utp.placeable.on_used = gff.ResRef.fromSlice("plc_used");
    utp.placeable.on_inv_disturbed = gff.ResRef.fromSlice("plc_disturb");
    utp.placeable.animation_state = 0;
    utp.placeable.comment = try a.dupe(u8, "treasure chest");
    utp.placeable.palette_id = 2;

    const bytes = try utp.serialize(gpa);
    defer gpa.free(bytes);
    var utp2 = try UtpFile.parse(gpa, bytes);
    defer utp2.deinit();
    const p = &utp2.placeable;

    try t.expectEqual(@as(u32, 42), p.appearance);
    try t.expectEqual(@as(u8, 1), p.useable);
    try t.expectEqual(@as(u8, 1), p.has_inventory);
    try t.expectEqual(@as(u8, 3), p.body_bag);
    try t.expectEqual(@as(i16, 25), p.hp);
    try t.expectEqualStrings("PlcChest01", p.tag);
    try t.expectEqualStrings("plc_used", p.on_used.slice());
    try t.expectEqualStrings("plc_disturb", p.on_inv_disturbed.slice());
    try t.expectEqualStrings("treasure chest", p.comment.?);
    try t.expectEqual(@as(?u8, 2), p.palette_id);
}

test "UTP blueprint ItemList round-trip" {
    const gpa = t.allocator;
    var utp = UtpFile.init(gpa);
    defer utp.deinit();
    const a = utp.arena.allocator();

    const items = try a.alloc(PlaceableInventoryItem, 2);
    items[0] = .{
        .repos_pos_x = 0,
        .repos_pos_y = 0,
        .inventory_res = gff.ResRef.fromSlice("nw_it_gold001"),
    };
    items[1] = .{
        .repos_pos_x = 1,
        .repos_pos_y = 0,
        .inventory_res = gff.ResRef.fromSlice("nw_it_mpotion001"),
    };
    utp.placeable.has_inventory = 1;
    utp.placeable.item_list = items;

    const bytes = try utp.serialize(gpa);
    defer gpa.free(bytes);
    var utp2 = try UtpFile.parse(gpa, bytes);
    defer utp2.deinit();
    const p = &utp2.placeable;

    try t.expectEqual(@as(usize, 2), p.item_list.len);
    try t.expectEqualStrings("nw_it_gold001", p.item_list[0].inventory_res.slice());
    try t.expectEqualStrings("nw_it_mpotion001", p.item_list[1].inventory_res.slice());
    try t.expectEqual(@as(u16, 0), p.item_list[0].repos_pos_x);
    try t.expectEqual(@as(u16, 1), p.item_list[1].repos_pos_x);
}

test "PlaceableStruct instance ItemList round-trip" {
    const gpa = t.allocator;
    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var p: PlaceableStruct = .{};
    p.tag = try a.dupe(u8, "PlcBox");
    p.appearance = 7;
    p.has_inventory = 1;
    p.x = 5.0;
    p.y = 10.0;
    p.z = 0.0;
    p.bearing = 0.0;

    const items = try a.alloc(PlaceableInventoryItem, 1);
    var inv_item: item_mod.ItemStruct = .{};
    inv_item.base_item = 12;
    inv_item.tag = try a.dupe(u8, "torch");
    inv_item.template_res_ref = gff.ResRef.fromSlice("nw_it_torch001");
    items[0] = .{ .repos_pos_x = 2, .repos_pos_y = 3, .item = inv_item };
    p.item_list = items;

    const sidx = try g.addStruct(9);
    try p.writeIntoGff(&g, sidx, .instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try PlaceableStruct.fromGffStruct(arena2.allocator(), &g, &g.structs.items[sidx], .instance);

    try t.expectEqualStrings("PlcBox", parsed.tag);
    try t.expectEqual(@as(u32, 7), parsed.appearance);
    try t.expectEqual(@as(usize, 1), parsed.item_list.len);
    try t.expectEqual(@as(u16, 2), parsed.item_list[0].repos_pos_x);
    try t.expectEqual(@as(u16, 3), parsed.item_list[0].repos_pos_y);
    try t.expectEqual(@as(i32, 12), parsed.item_list[0].item.?.base_item);
    try t.expectEqualStrings("torch", parsed.item_list[0].item.?.tag);
}

test "UTP wrong magic rejected" {
    const gpa = t.allocator;
    var utp = UtpFile.init(gpa);
    defer utp.deinit();
    const bytes = try utp.serialize(gpa);
    defer gpa.free(bytes);

    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    @memcpy(bad[0..4], "UTX ");
    try t.expectError(error.InvalidFileType, UtpFile.parse(gpa, bad));
}
