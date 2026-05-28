//! Bioware Aurora Encounter (UTE) file reader and writer.
//!
//! Encounters define a polygonal region that spawns creatures when hostile
//! factions enter it.  Stored as GFF V3.2 files with FileType "UTE " for
//! blueprints; embedded as EncounterStructs in module GIT files for instances.
//!
//! Spec sections:
//!   2.1   Common fields (all variants)
//!   2.1.2 EncounterCreature sub-struct
//!   2.2   Blueprint-only fields (Comment, PaletteID)
//!   2.3   Instance-only fields (Geometry, SpawnPointList, position)
//!
//! Memory: UteFile owns an ArenaAllocator that backs every string, slice, and
//! loc-string copy. Call deinit() once to free everything.
const std = @import("std");
const gff = @import("gff.zig");

pub const FILE_TYPE = "UTE ";

// ============================================================================
// Errors / variant
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

/// Spec variant — selects which optional field blocks are present.
pub const EncounterVariant = enum {
    /// Standalone UTE blueprint file. Spec 2.1 + 2.2.
    blueprint,
    /// Encounter instance inside a GIT file. Spec 2.1 + 2.3.
    instance,
};

// ============================================================================
// Sub-structs
// ============================================================================

/// EncounterCreature element — spec Table 2.1.2, StructID 0.
pub const EncounterCreature = struct {
    /// Row in appearance.2da (stored for performance).
    appearance: i32 = 0,
    /// Challenge Rating (stored for performance).
    cr: f32 = 0,
    /// ResRef of the creature blueprint (UTC file) to spawn.
    res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// 1 if only one copy may be alive in the encounter at a time.
    single_spawn: u8 = 0,
};

/// Geometry vertex — spec Table 2.3.2, StructID 1.
/// Coordinates are relative to the encounter's own (XPosition, YPosition, ZPosition).
pub const GeometryPoint = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

/// Explicit spawn point — spec Table 2.3.3, StructID 0.
pub const SpawnPoint = struct {
    /// Bearing in radians, counterclockwise from north.
    orientation: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
};

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

inline fn optByteOrNull(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?u8 {
    const f = g.getField(s, l) orelse return null;
    return switch (f.value) {
        .byte => |v| v,
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

inline fn optResRef(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!gff.ResRef {
    const f = g.getField(s, l) orelse return .{ .len = 0, .data = [_]u8{0} ** 16 };
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
            for (loc.substrings.items) |ss| {
                const text = try a.dupe(u8, ss.text);
                try out.substrings.append(a, .{ .string_id = ss.string_id, .text = text });
            }
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
// EncounterStruct
// ============================================================================

/// Typed GFF struct for an Encounter object.  Used directly when reading/writing
/// encounters embedded in GIT files; wrapped by UteFile for standalone blueprints.
pub const EncounterStruct = struct {
    // ---- 2.1.1 common -------------------------------------------------------

    /// 1 = active; 0 = must be activated via scripting.
    active: u8 = 1,
    /// Creatures this encounter can spawn.
    creature_list: []EncounterCreature = &.{},
    /// Obsolete — mirrors encdifficulty.2da VALUE for DifficultyIndex.
    difficulty: i32 = 0,
    /// Index into encdifficulty.2da.
    difficulty_index: i32 = 0,
    /// Faction ID from Faction.fac; only hostile factions fire the encounter.
    faction: u32 = 0,
    /// Toolset display name. Not shown in game.
    localized_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// Maximum simultaneous spawns (toolset: 1–8).
    max_creatures: i32 = 1,
    on_entered: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_exhausted: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_exit: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_heartbeat: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_user_defined: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// 1 if only player characters (still hostile) can fire the encounter.
    player_only: u8 = 0,
    /// Recommended (soft-minimum) spawn count.
    rec_creatures: i32 = 1,
    /// 1 if the encounter respawns.
    reset: u8 = 0,
    /// Seconds before respawn.
    reset_time: i32 = 0,
    /// Times to respawn; -1 = infinite.
    respawns: i32 = 0,
    /// 0 = continuous; 1 = single-shot.
    spawn_option: i32 = 0,
    /// Tag (≤32 characters).
    tag: []u8 = &.{},
    /// Blueprint: same as filename. Instance: ResRef of the source blueprint.
    template_res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },

    // ---- 2.2 blueprint-only -------------------------------------------------

    /// Module designer comment. null = field absent.
    comment: ?[]u8 = null,
    /// Palette node ID. null = field absent.
    palette_id: ?u8 = null,

    // ---- 2.3 instance-only --------------------------------------------------

    /// Polygon vertices defining the encounter region (relative coordinates).
    geometry: []GeometryPoint = &.{},
    /// Explicit creature spawn locations (optional; empty = engine-chosen).
    spawn_point_list: []SpawnPoint = &.{},
    /// World position of the encounter in the area. null = not present (blueprint).
    x_position: ?f32 = null,
    y_position: ?f32 = null,
    z_position: ?f32 = null,

    // -------------------------------------------------------------------------

    /// Decode an EncounterStruct from a GFF struct node.
    /// All strings and list slices are allocated from `arena`.
    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: EncounterVariant,
    ) Error!EncounterStruct {
        var out: EncounterStruct = .{};

        // Common fields.
        out.active = try optByte(g, s, "Active", 1);
        out.creature_list = try parseCreatureList(arena, g, s);
        out.difficulty = try optInt(g, s, "Difficulty", 0);
        out.difficulty_index = try optInt(g, s, "DifficultyIndex", 0);
        out.faction = try optDword(g, s, "Faction", 0);
        out.localized_name = try optExoLocDupe(arena, g, s, "LocalizedName");
        out.max_creatures = try optInt(g, s, "MaxCreatures", 1);
        out.on_entered = try optResRef(g, s, "OnEntered");
        out.on_exhausted = try optResRef(g, s, "OnExhausted");
        out.on_exit = try optResRef(g, s, "OnExit");
        out.on_heartbeat = try optResRef(g, s, "OnHeartbeat");
        out.on_user_defined = try optResRef(g, s, "OnUserDefined");
        out.player_only = try optByte(g, s, "PlayerOnly", 0);
        out.rec_creatures = try optInt(g, s, "RecCreatures", 1);
        out.reset = try optByte(g, s, "Reset", 0);
        out.reset_time = try optInt(g, s, "ResetTime", 0);
        out.respawns = try optInt(g, s, "Respawns", 0);
        out.spawn_option = try optInt(g, s, "SpawnOption", 0);
        out.tag = try optExoStringDupe(arena, g, s, "Tag");
        out.template_res_ref = try optResRef(g, s, "TemplateResRef");

        switch (variant) {
            .blueprint => {
                out.comment = try optExoStringDupeOrNull(arena, g, s, "Comment");
                out.palette_id = try optByteOrNull(g, s, "PaletteID");
            },
            .instance => {
                out.geometry = try parseGeometry(arena, g, s);
                out.spawn_point_list = try parseSpawnPoints(arena, g, s);
                out.x_position = try optFloat(g, s, "XPosition", 0);
                out.y_position = try optFloat(g, s, "YPosition", 0);
                out.z_position = try optFloat(g, s, "ZPosition", 0);
            },
        }
        return out;
    }

    /// Emit all fields into the GFF struct at `struct_idx` inside `g`.
    pub fn writeIntoGff(
        self: *const EncounterStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: EncounterVariant,
    ) !void {
        try g.addFieldToStruct(struct_idx, "Active", .{ .byte = self.active });
        try writeCreatureList(g, struct_idx, self.creature_list);
        try g.addFieldToStruct(struct_idx, "Difficulty", .{ .int = self.difficulty });
        try g.addFieldToStruct(struct_idx, "DifficultyIndex", .{ .int = self.difficulty_index });
        try g.addFieldToStruct(struct_idx, "Faction", .{ .dword = self.faction });
        try g.addFieldToStruct(struct_idx, "LocalizedName", .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.localized_name),
        });
        try g.addFieldToStruct(struct_idx, "MaxCreatures", .{ .int = self.max_creatures });
        try g.addFieldToStruct(struct_idx, "OnEntered", .{ .res_ref = self.on_entered });
        try g.addFieldToStruct(struct_idx, "OnExhausted", .{ .res_ref = self.on_exhausted });
        try g.addFieldToStruct(struct_idx, "OnExit", .{ .res_ref = self.on_exit });
        try g.addFieldToStruct(struct_idx, "OnHeartbeat", .{ .res_ref = self.on_heartbeat });
        try g.addFieldToStruct(struct_idx, "OnUserDefined", .{ .res_ref = self.on_user_defined });
        try g.addFieldToStruct(struct_idx, "PlayerOnly", .{ .byte = self.player_only });
        try g.addFieldToStruct(struct_idx, "RecCreatures", .{ .int = self.rec_creatures });
        try g.addFieldToStruct(struct_idx, "Reset", .{ .byte = self.reset });
        try g.addFieldToStruct(struct_idx, "ResetTime", .{ .int = self.reset_time });
        try g.addFieldToStruct(struct_idx, "Respawns", .{ .int = self.respawns });
        try g.addFieldToStruct(struct_idx, "SpawnOption", .{ .int = self.spawn_option });
        try g.addFieldToStruct(struct_idx, "Tag", .{ .exo_string = try g.allocator.dupe(u8, self.tag) });
        try g.addFieldToStruct(struct_idx, "TemplateResRef", .{ .res_ref = self.template_res_ref });

        switch (variant) {
            .blueprint => {
                if (self.comment) |c|
                    try g.addFieldToStruct(struct_idx, "Comment", .{ .exo_string = try g.allocator.dupe(u8, c) });
                if (self.palette_id) |v|
                    try g.addFieldToStruct(struct_idx, "PaletteID", .{ .byte = v });
            },
            .instance => {
                try writeGeometry(g, struct_idx, self.geometry);
                try writeSpawnPoints(g, struct_idx, self.spawn_point_list);
                try g.addFieldToStruct(struct_idx, "XPosition", .{ .float = self.x_position orelse 0 });
                try g.addFieldToStruct(struct_idx, "YPosition", .{ .float = self.y_position orelse 0 });
                try g.addFieldToStruct(struct_idx, "ZPosition", .{ .float = self.z_position orelse 0 });
            },
        }
    }
};

// ============================================================================
// List parse helpers
// ============================================================================

fn parseCreatureList(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
) Error![]EncounterCreature {
    const f = g.getField(s, "CreatureList") orelse return arena.alloc(EncounterCreature, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(EncounterCreature, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        out[i] = .{
            .appearance = try optInt(g, cs, "Appearance", 0),
            .cr = try optFloat(g, cs, "CR", 0),
            .res_ref = try optResRef(g, cs, "ResRef"),
            .single_spawn = try optByte(g, cs, "SingleSpawn", 0),
        };
    }
    return out;
}

fn parseGeometry(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
) Error![]GeometryPoint {
    const f = g.getField(s, "Geometry") orelse return arena.alloc(GeometryPoint, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(GeometryPoint, arr.len);
    for (arr, 0..) |idx, i| {
        const ps = &g.structs.items[idx];
        out[i] = .{
            .x = try optFloat(g, ps, "X", 0),
            .y = try optFloat(g, ps, "Y", 0),
            .z = try optFloat(g, ps, "Z", 0),
        };
    }
    return out;
}

fn parseSpawnPoints(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
) Error![]SpawnPoint {
    const f = g.getField(s, "SpawnPointList") orelse return arena.alloc(SpawnPoint, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(SpawnPoint, arr.len);
    for (arr, 0..) |idx, i| {
        const ps = &g.structs.items[idx];
        out[i] = .{
            .orientation = try optFloat(g, ps, "Orientation", 0),
            .x = try optFloat(g, ps, "X", 0),
            .y = try optFloat(g, ps, "Y", 0),
            .z = try optFloat(g, ps, "Z", 0),
        };
    }
    return out;
}

// ============================================================================
// List serialize helpers
// ============================================================================

fn writeCreatureList(g: *gff.GffFile, parent_idx: u32, creatures: []const EncounterCreature) !void {
    const arr = try g.allocator.alloc(u32, creatures.len);
    errdefer g.allocator.free(arr);
    for (creatures, 0..) |c, i| {
        const sidx = try g.addStruct(0); // StructID 0 per spec Table 2.1.2
        try g.addFieldToStruct(sidx, "Appearance", .{ .int = c.appearance });
        try g.addFieldToStruct(sidx, "CR", .{ .float = c.cr });
        try g.addFieldToStruct(sidx, "ResRef", .{ .res_ref = c.res_ref });
        try g.addFieldToStruct(sidx, "SingleSpawn", .{ .byte = c.single_spawn });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, "CreatureList", .{ .list = arr });
}

fn writeGeometry(g: *gff.GffFile, parent_idx: u32, points: []const GeometryPoint) !void {
    if (points.len == 0) return;
    const arr = try g.allocator.alloc(u32, points.len);
    errdefer g.allocator.free(arr);
    for (points, 0..) |p, i| {
        const sidx = try g.addStruct(1); // StructID 1 per spec Table 2.3.2
        try g.addFieldToStruct(sidx, "X", .{ .float = p.x });
        try g.addFieldToStruct(sidx, "Y", .{ .float = p.y });
        try g.addFieldToStruct(sidx, "Z", .{ .float = p.z });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, "Geometry", .{ .list = arr });
}

fn writeSpawnPoints(g: *gff.GffFile, parent_idx: u32, points: []const SpawnPoint) !void {
    if (points.len == 0) return;
    const arr = try g.allocator.alloc(u32, points.len);
    errdefer g.allocator.free(arr);
    for (points, 0..) |p, i| {
        const sidx = try g.addStruct(0); // StructID 0 per spec Table 2.3.3
        try g.addFieldToStruct(sidx, "Orientation", .{ .float = p.orientation });
        try g.addFieldToStruct(sidx, "X", .{ .float = p.x });
        try g.addFieldToStruct(sidx, "Y", .{ .float = p.y });
        try g.addFieldToStruct(sidx, "Z", .{ .float = p.z });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, "SpawnPointList", .{ .list = arr });
}

// ============================================================================
// UteFile — standalone UTE blueprint container
// ============================================================================

/// Standalone encounter blueprint.  Wraps a `.blueprint` EncounterStruct
/// together with the arena that owns its string/list/loc-string data.
///
/// Example:
/// ```zig
/// var ute = try UteFile.parse(gpa, bytes);
/// defer ute.deinit();
/// ute.encounter.faction = 3;
/// const out = try ute.serialize(gpa);
/// defer gpa.free(out);
/// ```
pub const UteFile = struct {
    arena: std.heap.ArenaAllocator,
    encounter: EncounterStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UteFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UteFile) void {
        self.arena.deinit();
    }

    /// Parse a UTE byte stream.  Verifies the `"UTE "` magic and decodes
    /// the top-level struct as a blueprint encounter.
    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UteFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = UteFile.init(parent_alloc);
        errdefer out.deinit();
        out.encounter = try EncounterStruct.fromGffStruct(
            out.arena.allocator(),
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    /// Encode this encounter (as a blueprint) into a UTE byte stream.
    /// Caller owns the returned slice and must free it with `alloc`.
    pub fn serialize(self: *const UteFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.encounter.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty UTE round-trip" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const bytes = try ute.serialize(gpa);
    defer gpa.free(bytes);

    var ute2 = try UteFile.parse(gpa, bytes);
    defer ute2.deinit();

    try t.expectEqual(@as(u8, 1), ute2.encounter.active);
    try t.expectEqual(@as(usize, 0), ute2.encounter.creature_list.len);
    try t.expectEqual(@as(i32, 0), ute2.encounter.difficulty);
    try t.expectEqual(@as(u32, 0), ute2.encounter.faction);
    try t.expectEqual(@as(i32, 1), ute2.encounter.max_creatures);
    try t.expectEqual(@as(?u8, null), ute2.encounter.palette_id);
    try t.expect(ute2.encounter.comment == null);
}

test "UTE common fields round-trip" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const a = ute.arena.allocator();
    ute.encounter.active = 0;
    ute.encounter.tag = try a.dupe(u8, "EncounterGoblin");
    ute.encounter.template_res_ref = gff.ResRef.fromSlice("gobenc001");
    ute.encounter.faction = 3;
    ute.encounter.difficulty = 5;
    ute.encounter.difficulty_index = 2;
    ute.encounter.max_creatures = 4;
    ute.encounter.rec_creatures = 2;
    ute.encounter.player_only = 1;
    ute.encounter.reset = 1;
    ute.encounter.reset_time = 300;
    ute.encounter.respawns = -1;
    ute.encounter.spawn_option = 1;
    ute.encounter.on_entered = gff.ResRef.fromSlice("enc_enter");
    ute.encounter.on_exhausted = gff.ResRef.fromSlice("enc_exhaust");
    ute.encounter.on_exit = gff.ResRef.fromSlice("enc_exit");
    ute.encounter.on_heartbeat = gff.ResRef.fromSlice("enc_hb");
    ute.encounter.on_user_defined = gff.ResRef.fromSlice("enc_udef");

    const bytes = try ute.serialize(gpa);
    defer gpa.free(bytes);

    var ute2 = try UteFile.parse(gpa, bytes);
    defer ute2.deinit();

    const e = &ute2.encounter;
    try t.expectEqual(@as(u8, 0), e.active);
    try t.expectEqualStrings("EncounterGoblin", e.tag);
    try t.expectEqualStrings("gobenc001", e.template_res_ref.slice());
    try t.expectEqual(@as(u32, 3), e.faction);
    try t.expectEqual(@as(i32, 5), e.difficulty);
    try t.expectEqual(@as(i32, 2), e.difficulty_index);
    try t.expectEqual(@as(i32, 4), e.max_creatures);
    try t.expectEqual(@as(i32, 2), e.rec_creatures);
    try t.expectEqual(@as(u8, 1), e.player_only);
    try t.expectEqual(@as(u8, 1), e.reset);
    try t.expectEqual(@as(i32, 300), e.reset_time);
    try t.expectEqual(@as(i32, -1), e.respawns);
    try t.expectEqual(@as(i32, 1), e.spawn_option);
    try t.expectEqualStrings("enc_enter", e.on_entered.slice());
    try t.expectEqualStrings("enc_exhaust", e.on_exhausted.slice());
    try t.expectEqualStrings("enc_exit", e.on_exit.slice());
    try t.expectEqualStrings("enc_hb", e.on_heartbeat.slice());
    try t.expectEqualStrings("enc_udef", e.on_user_defined.slice());
}

test "UTE creature list round-trip" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const a = ute.arena.allocator();
    const creatures = try a.alloc(EncounterCreature, 2);
    creatures[0] = .{ .appearance = 6, .cr = 1.0, .res_ref = gff.ResRef.fromSlice("nw_goblin001"), .single_spawn = 0 };
    creatures[1] = .{ .appearance = 7, .cr = 0.5, .res_ref = gff.ResRef.fromSlice("nw_goblin002"), .single_spawn = 1 };
    ute.encounter.creature_list = creatures;

    const bytes = try ute.serialize(gpa);
    defer gpa.free(bytes);

    var ute2 = try UteFile.parse(gpa, bytes);
    defer ute2.deinit();

    try t.expectEqual(@as(usize, 2), ute2.encounter.creature_list.len);
    const c0 = ute2.encounter.creature_list[0];
    try t.expectEqual(@as(i32, 6), c0.appearance);
    try t.expectApproxEqAbs(@as(f32, 1.0), c0.cr, 0.0001);
    try t.expectEqualStrings("nw_goblin001", c0.res_ref.slice());
    try t.expectEqual(@as(u8, 0), c0.single_spawn);
    const c1 = ute2.encounter.creature_list[1];
    try t.expectEqual(@as(i32, 7), c1.appearance);
    try t.expectApproxEqAbs(@as(f32, 0.5), c1.cr, 0.0001);
    try t.expectEqualStrings("nw_goblin002", c1.res_ref.slice());
    try t.expectEqual(@as(u8, 1), c1.single_spawn);
}

test "UTE blueprint-only fields round-trip" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const a = ute.arena.allocator();
    ute.encounter.comment = try a.dupe(u8, "Spawns goblins near the bridge");
    ute.encounter.palette_id = 12;

    const bytes = try ute.serialize(gpa);
    defer gpa.free(bytes);

    var ute2 = try UteFile.parse(gpa, bytes);
    defer ute2.deinit();

    try t.expectEqualStrings("Spawns goblins near the bridge", ute2.encounter.comment.?);
    try t.expectEqual(@as(?u8, 12), ute2.encounter.palette_id);
}

test "UTE LocalizedName round-trip" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const a = ute.arena.allocator();
    ute.encounter.localized_name.string_ref = 99;
    try ute.encounter.localized_name.substrings.append(a, .{
        .string_id = 0,
        .text = try a.dupe(u8, "Goblin Ambush"),
    });

    const bytes = try ute.serialize(gpa);
    defer gpa.free(bytes);

    var ute2 = try UteFile.parse(gpa, bytes);
    defer ute2.deinit();

    try t.expectEqual(@as(u32, 99), ute2.encounter.localized_name.string_ref);
    try t.expectEqual(@as(usize, 1), ute2.encounter.localized_name.substrings.items.len);
    try t.expectEqualStrings("Goblin Ambush", ute2.encounter.localized_name.substrings.items[0].text);
}

test "EncounterStruct instance variant round-trip" {
    const gpa = t.allocator;

    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var enc: EncounterStruct = .{};
    enc.tag = try a.dupe(u8, "EncBridge");
    enc.x_position = 10.0;
    enc.y_position = 20.0;
    enc.z_position = 0.5;

    const geom = try a.alloc(GeometryPoint, 3);
    geom[0] = .{ .x = -2, .y = -2, .z = 0 };
    geom[1] = .{ .x = 2, .y = -2, .z = 0 };
    geom[2] = .{ .x = 0, .y = 2, .z = 0 };
    enc.geometry = geom;

    const spawns = try a.alloc(SpawnPoint, 1);
    spawns[0] = .{ .orientation = 1.5708, .x = 10.5, .y = 20.5, .z = 0 };
    enc.spawn_point_list = spawns;

    const sidx = try g.addStruct(0);
    try enc.writeIntoGff(&g, sidx, .instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try EncounterStruct.fromGffStruct(
        arena2.allocator(),
        &g,
        &g.structs.items[sidx],
        .instance,
    );

    try t.expectEqualStrings("EncBridge", parsed.tag);
    try t.expectApproxEqAbs(@as(f32, 10.0), parsed.x_position.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 20.0), parsed.y_position.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 0.5), parsed.z_position.?, 0.0001);

    try t.expectEqual(@as(usize, 3), parsed.geometry.len);
    try t.expectApproxEqAbs(@as(f32, -2), parsed.geometry[0].x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 2), parsed.geometry[1].x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 0), parsed.geometry[2].x, 0.0001);

    try t.expectEqual(@as(usize, 1), parsed.spawn_point_list.len);
    try t.expectApproxEqAbs(@as(f32, 1.5708), parsed.spawn_point_list[0].orientation, 0.001);
    try t.expectApproxEqAbs(@as(f32, 10.5), parsed.spawn_point_list[0].x, 0.0001);
}

test "UTE byte-exact double serialize" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const a = ute.arena.allocator();
    ute.encounter.tag = try a.dupe(u8, "TestEnc");
    ute.encounter.template_res_ref = gff.ResRef.fromSlice("testenc001");
    ute.encounter.faction = 5;
    ute.encounter.max_creatures = 3;
    ute.encounter.rec_creatures = 2;
    ute.encounter.comment = try a.dupe(u8, "test comment");
    ute.encounter.palette_id = 1;

    const creatures = try a.alloc(EncounterCreature, 1);
    creatures[0] = .{ .appearance = 9, .cr = 2.0, .res_ref = gff.ResRef.fromSlice("nw_orc001"), .single_spawn = 0 };
    ute.encounter.creature_list = creatures;

    const bytes1 = try ute.serialize(gpa);
    defer gpa.free(bytes1);

    var ute2 = try UteFile.parse(gpa, bytes1);
    defer ute2.deinit();
    const bytes2 = try ute2.serialize(gpa);
    defer gpa.free(bytes2);

    try t.expectEqualSlices(u8, bytes1, bytes2);
}

test "UTE wrong magic rejected" {
    const gpa = t.allocator;
    var ute = UteFile.init(gpa);
    defer ute.deinit();

    const bytes = try ute.serialize(gpa);
    defer gpa.free(bytes);

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[0..4], "UTA ");

    try t.expectError(error.InvalidFileType, UteFile.parse(gpa, mut));
}
