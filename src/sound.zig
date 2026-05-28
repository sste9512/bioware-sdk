//! BioWare Aurora Sound Object (UTS) GFF reader/writer.
//!
//! Spec: Bioware_Aurora_SoundObject_Format.pdf
//!   §2.1  Common fields (all variants)
//!   §2.2  Blueprint-only fields (Comment, PaletteID)
//!   §2.3  Instance fields (XPosition/YPosition/ZPosition, GeneratedType)
//!   §2.4  Game-instance fields (ActionList, ObjectId, VarTable)
//!
//! Sound blueprints are stored as GFF files with extension UTS and FileType
//! "UTS ". Sound instances live as SoundStructs in module GIT files.
//!
//! Memory: UtsFile owns an ArenaAllocator. Call deinit() once to free all.

const std    = @import("std");
const gff    = @import("gff.zig");
const common = @import("common_gff.zig");

pub const FILE_TYPE = "UTS ";

// ============================================================================
// Errors / variant
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

/// Which optional field blocks are present.
pub const SoundVariant = enum {
    /// Standalone UTS blueprint file. Spec §2.1 + §2.2.
    blueprint,
    /// Instance embedded in a GIT file. Spec §2.1 + §2.3.
    instance,
    /// Instance in a savegame GIT file. Spec §2.1 + §2.3 + §2.4.
    game_instance,
};

// ============================================================================
// Sub-struct
// ============================================================================

/// One wave file entry in a Sound's wave list (§2.1 "Sounds" List, StructID 0).
pub const SoundEntry = struct {
    res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
};

// ============================================================================
// Internal helpers
// ============================================================================

inline fn optByte(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u8) Error!u8 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .byte => |v| v,
        else  => error.WrongFieldType,
    };
}

inline fn optByteOrNull(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?u8 {
    const f = g.getField(s, l) orelse return null;
    return switch (f.value) {
        .byte => |v| v,
        else  => error.WrongFieldType,
    };
}

inline fn optDword(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: u32) Error!u32 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .dword => |v| v,
        else   => error.WrongFieldType,
    };
}

inline fn optFloat(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: f32) Error!f32 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .float => |v| v,
        else   => error.WrongFieldType,
    };
}

inline fn optResRef(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!gff.ResRef {
    const f = g.getField(s, l) orelse return .{ .len = 0, .data = [_]u8{0} ** 16 };
    return switch (f.value) {
        .res_ref => |v| v,
        else     => error.WrongFieldType,
    };
}

fn optExoStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error![]u8 {
    const f = g.getField(s, l) orelse return a.dupe(u8, &.{});
    return switch (f.value) {
        .exo_string => |v| a.dupe(u8, v),
        else        => error.WrongFieldType,
    };
}

fn optExoStringDupeOrNull(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?[]u8 {
    const f = g.getField(s, l) orelse return null;
    return switch (f.value) {
        .exo_string => |v| try a.dupe(u8, v),
        else        => error.WrongFieldType,
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
// Sounds wave list helpers
// ============================================================================

fn parseSoundsList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]SoundEntry {
    const f = g.getField(s, "Sounds") orelse return arena.alloc(SoundEntry, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else  => return error.WrongFieldType,
    };
    const out = try arena.alloc(SoundEntry, arr.len);
    for (arr, 0..) |idx, i| {
        out[i] = .{ .res_ref = try optResRef(g, &g.structs.items[idx], "Sound") };
    }
    return out;
}

fn writeSoundsList(g: *gff.GffFile, parent_idx: u32, sounds: []const SoundEntry) !void {
    if (sounds.len == 0) return;
    const arr = try g.allocator.alloc(u32, sounds.len);
    errdefer g.allocator.free(arr);
    for (sounds, 0..) |s, i| {
        const sidx = try g.addStruct(0); // StructID 0 per spec §2.1
        try g.addFieldToStruct(sidx, "Sound", .{ .res_ref = s.res_ref });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, "Sounds", .{ .list = arr });
}

// ============================================================================
// SoundStruct
// ============================================================================

/// Typed GFF struct for a Sound object.  Use directly for GIT-embedded
/// instances; wrap with UtsFile for standalone blueprint files.
pub const SoundStruct = struct {
    // ---- §2.1 common --------------------------------------------------------

    active:           u8  = 0,
    continuous:       u8  = 0,
    elevation:        f32 = 0,
    /// Bitmask: bit N = play during hour N. Bit 0 = 00h00, bit 14 = 14h00, etc.
    hours:            u32 = 0,
    /// Milliseconds between waves (ignored when Continuous=1).
    interval:         u32 = 0,
    /// ±millisecond jitter added to Interval each play (ignored when Continuous=1).
    interval_vrtn:    u32 = 0,
    /// Toolset palette name; not shown in game.
    loc_name:         gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    looping:          u8  = 0,
    max_distance:     f32 = 0,
    min_distance:     f32 = 0,
    /// Octave pitch jitter per play (0–1.0). Ignored when Continuous=1.
    pitch_variation:  f32 = 0,
    positional:       u8  = 0,
    /// Index into prioritygroups.2da.
    priority:         u8  = 0,
    /// 1 = random wave order; 0 = sequential. Ignored when Continuous=1.
    random:           u8  = 0,
    /// 1 = XYZ jitters by RandomRangeX/Y each play. Ignored when Positional=0.
    random_position:  u8  = 0,
    random_range_x:   f32 = 0,
    random_range_y:   f32 = 0,
    /// Ordered list of WAV ResRefs to play.
    sounds:           []SoundEntry = &.{},
    /// Tag (≤32 characters).
    tag:              []u8 = &.{},
    /// Blueprint: same as UTS filename. Instance: source blueprint ResRef.
    template_res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// 0=time-specific (use Hours), 1=Day, 2=Night, 3=Always.
    times:            u8  = 0,
    /// 0 (min) to 127 (full).
    volume:           u8  = 0,
    /// ±volume jitter per play, 0–127. Ignored when Continuous=1.
    volume_vrtn:      u8  = 0,

    // ---- §2.2 blueprint-only ------------------------------------------------

    /// Module designer comment. null = field absent.
    comment:    ?[]u8 = null,
    /// Palette node ID. null = field absent.
    palette_id: ?u8   = null,

    // ---- §2.3 instance-only -------------------------------------------------

    /// 0 = manually placed, 1 = auto-generated ambient. null = blueprint.
    generated_type: ?u8  = null,
    x_position:     ?f32 = null,
    y_position:     ?f32 = null,
    z_position:     ?f32 = null,

    // ---- §2.4 game-instance-only --------------------------------------------

    action_list: []common.Action   = &.{},
    /// Game engine object ID. INVALID_OBJECT_ID = 0x7f000000. null = not a game instance.
    object_id:   ?u32              = null,
    var_table:   []common.Variable = &.{},

    // -------------------------------------------------------------------------

    /// Decode a SoundStruct from a GFF struct node.
    /// All strings and loc-strings are deep-copied into `arena`.
    pub fn fromGffStruct(
        arena:   std.mem.Allocator,
        g:       *const gff.GffFile,
        s:       *const gff.Struct,
        variant: SoundVariant,
    ) Error!SoundStruct {
        var out: SoundStruct = .{};

        // §2.1 common
        out.active          = try optByte(g, s,  "Active",          0);
        out.continuous      = try optByte(g, s,  "Continuous",      0);
        out.elevation       = try optFloat(g, s, "Elevation",       0);
        out.hours           = try optDword(g, s, "Hours",           0);
        out.interval        = try optDword(g, s, "Interval",        0);
        out.interval_vrtn   = try optDword(g, s, "IntervalVrtn",    0);
        out.loc_name        = try optExoLocDupe(arena, g, s, "LocName");
        out.looping         = try optByte(g, s,  "Looping",         0);
        out.max_distance    = try optFloat(g, s, "MaxDistance",     0);
        out.min_distance    = try optFloat(g, s, "MinDistance",     0);
        out.pitch_variation = try optFloat(g, s, "PitchVariation",  0);
        out.positional      = try optByte(g, s,  "Positional",      0);
        out.priority        = try optByte(g, s,  "Priority",        0);
        out.random          = try optByte(g, s,  "Random",          0);
        out.random_position = try optByte(g, s,  "RandomPosition",  0);
        out.random_range_x  = try optFloat(g, s, "RandomRangeX",   0);
        out.random_range_y  = try optFloat(g, s, "RandomRangeY",   0);
        out.sounds          = try parseSoundsList(arena, g, s);
        out.tag             = try optExoStringDupe(arena, g, s, "Tag");
        out.template_res_ref = try optResRef(g, s, "TemplateResRef");
        out.times           = try optByte(g, s,  "Times",           0);
        out.volume          = try optByte(g, s,  "Volume",          0);
        out.volume_vrtn     = try optByte(g, s,  "VolumeVrtn",      0);

        switch (variant) {
            .blueprint => {
                out.comment    = try optExoStringDupeOrNull(arena, g, s, "Comment");
                out.palette_id = try optByteOrNull(g, s, "PaletteID");
            },
            .instance, .game_instance => {
                out.generated_type = try optByte(g, s,  "GeneratedType", 0);
                out.x_position     = try optFloat(g, s, "XPosition",     0);
                out.y_position     = try optFloat(g, s, "YPosition",     0);
                out.z_position     = try optFloat(g, s, "ZPosition",     0);

                if (variant == .game_instance) {
                    out.action_list = try common.parseActionList(arena, g, s);
                    out.object_id   = try optDword(g, s, "ObjectId", 0x7f000000);
                    out.var_table   = try common.parseVarTable(arena, g, s);
                }
            },
        }
        return out;
    }

    /// Emit all fields into the GFF struct at `struct_idx` inside `g`.
    pub fn writeIntoGff(
        self:       *const SoundStruct,
        g:          *gff.GffFile,
        struct_idx: u32,
        variant:    SoundVariant,
    ) !void {
        // §2.1 common
        try g.addFieldToStruct(struct_idx, "Active",         .{ .byte  = self.active });
        try g.addFieldToStruct(struct_idx, "Continuous",     .{ .byte  = self.continuous });
        try g.addFieldToStruct(struct_idx, "Elevation",      .{ .float = self.elevation });
        try g.addFieldToStruct(struct_idx, "Hours",          .{ .dword = self.hours });
        try g.addFieldToStruct(struct_idx, "Interval",       .{ .dword = self.interval });
        try g.addFieldToStruct(struct_idx, "IntervalVrtn",   .{ .dword = self.interval_vrtn });
        try g.addFieldToStruct(struct_idx, "LocName",        .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.loc_name),
        });
        try g.addFieldToStruct(struct_idx, "Looping",        .{ .byte  = self.looping });
        try g.addFieldToStruct(struct_idx, "MaxDistance",    .{ .float = self.max_distance });
        try g.addFieldToStruct(struct_idx, "MinDistance",    .{ .float = self.min_distance });
        try g.addFieldToStruct(struct_idx, "PitchVariation", .{ .float = self.pitch_variation });
        try g.addFieldToStruct(struct_idx, "Positional",     .{ .byte  = self.positional });
        try g.addFieldToStruct(struct_idx, "Priority",       .{ .byte  = self.priority });
        try g.addFieldToStruct(struct_idx, "Random",         .{ .byte  = self.random });
        try g.addFieldToStruct(struct_idx, "RandomPosition", .{ .byte  = self.random_position });
        try g.addFieldToStruct(struct_idx, "RandomRangeX",   .{ .float = self.random_range_x });
        try g.addFieldToStruct(struct_idx, "RandomRangeY",   .{ .float = self.random_range_y });
        try writeSoundsList(g, struct_idx, self.sounds);
        try g.addFieldToStruct(struct_idx, "Tag",            .{ .exo_string = try g.allocator.dupe(u8, self.tag) });
        try g.addFieldToStruct(struct_idx, "TemplateResRef", .{ .res_ref = self.template_res_ref });
        try g.addFieldToStruct(struct_idx, "Times",          .{ .byte  = self.times });
        try g.addFieldToStruct(struct_idx, "Volume",         .{ .byte  = self.volume });
        try g.addFieldToStruct(struct_idx, "VolumeVrtn",     .{ .byte  = self.volume_vrtn });

        switch (variant) {
            .blueprint => {
                if (self.comment) |c|
                    try g.addFieldToStruct(struct_idx, "Comment",   .{ .exo_string = try g.allocator.dupe(u8, c) });
                if (self.palette_id) |v|
                    try g.addFieldToStruct(struct_idx, "PaletteID", .{ .byte = v });
            },
            .instance, .game_instance => {
                try g.addFieldToStruct(struct_idx, "GeneratedType", .{ .byte  = self.generated_type orelse 0 });
                try g.addFieldToStruct(struct_idx, "XPosition",     .{ .float = self.x_position orelse 0 });
                try g.addFieldToStruct(struct_idx, "YPosition",     .{ .float = self.y_position orelse 0 });
                try g.addFieldToStruct(struct_idx, "ZPosition",     .{ .float = self.z_position orelse 0 });

                if (variant == .game_instance) {
                    try common.writeActionList(g, struct_idx, self.action_list);
                    try g.addFieldToStruct(struct_idx, "ObjectId", .{ .dword = self.object_id orelse 0x7f000000 });
                    try common.writeVarTable(g, struct_idx, self.var_table);
                }
            },
        }
    }
};

// ============================================================================
// UtsFile — standalone UTS blueprint container
// ============================================================================

/// Standalone sound blueprint.  Wraps a `.blueprint` SoundStruct together
/// with the arena that owns its string/loc-string data.
///
/// Example:
/// ```zig
/// var uts = try UtsFile.parse(gpa, bytes);
/// defer uts.deinit();
/// uts.sound.active = 1;
/// const out = try uts.serialize(gpa);
/// defer gpa.free(out);
/// ```
pub const UtsFile = struct {
    arena: std.heap.ArenaAllocator,
    sound: SoundStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UtsFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UtsFile) void {
        self.arena.deinit();
    }

    /// Parse a UTS byte stream. Verifies the `"UTS "` magic and decodes
    /// the top-level struct as a blueprint sound.
    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtsFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = UtsFile.init(parent_alloc);
        errdefer out.deinit();
        out.sound = try SoundStruct.fromGffStruct(
            out.arena.allocator(),
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    /// Encode this sound (as a blueprint) into a UTS byte stream.
    /// Caller owns the returned slice and must free it with `alloc`.
    pub fn serialize(self: *const UtsFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.sound.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty UTS round-trip" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const bytes = try uts.serialize(gpa);
    defer gpa.free(bytes);

    var uts2 = try UtsFile.parse(gpa, bytes);
    defer uts2.deinit();

    const s = &uts2.sound;
    try t.expectEqual(@as(u8, 0), s.active);
    try t.expectEqual(@as(u8, 0), s.continuous);
    try t.expectEqual(@as(u8, 0), s.looping);
    try t.expectEqual(@as(u32, 0), s.hours);
    try t.expect(s.comment == null);
    try t.expectEqual(@as(?u8, null), s.palette_id);
    try t.expectEqual(@as(usize, 0), s.sounds.len);
}

test "UTS common scalar fields round-trip" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const a = uts.arena.allocator();
    uts.sound.active          = 1;
    uts.sound.continuous      = 0;
    uts.sound.looping         = 1;
    uts.sound.random          = 1;
    uts.sound.positional      = 1;
    uts.sound.priority        = 3;
    uts.sound.times           = 3;
    uts.sound.volume          = 80;
    uts.sound.volume_vrtn     = 10;
    uts.sound.elevation       = 2.5;
    uts.sound.max_distance    = 20.0;
    uts.sound.min_distance    = 5.0;
    uts.sound.pitch_variation = 0.25;
    uts.sound.interval        = 1000;
    uts.sound.interval_vrtn   = 200;
    uts.sound.hours           = 0b0000_1111_1111_0000; // hours 4–11
    uts.sound.random_position = 1;
    uts.sound.random_range_x  = 3.0;
    uts.sound.random_range_y  = 4.0;
    uts.sound.tag             = try a.dupe(u8, "SND_Ambience01");
    uts.sound.template_res_ref = gff.ResRef.fromSlice("snd_ambience01");

    const bytes = try uts.serialize(gpa);
    defer gpa.free(bytes);

    var uts2 = try UtsFile.parse(gpa, bytes);
    defer uts2.deinit();

    const s = &uts2.sound;
    try t.expectEqual(@as(u8, 1),    s.active);
    try t.expectEqual(@as(u8, 1),    s.looping);
    try t.expectEqual(@as(u8, 1),    s.random);
    try t.expectEqual(@as(u8, 1),    s.positional);
    try t.expectEqual(@as(u8, 3),    s.priority);
    try t.expectEqual(@as(u8, 3),    s.times);
    try t.expectEqual(@as(u8, 80),   s.volume);
    try t.expectEqual(@as(u8, 10),   s.volume_vrtn);
    try t.expectApproxEqAbs(@as(f32, 2.5),  s.elevation,       0.0001);
    try t.expectApproxEqAbs(@as(f32, 20.0), s.max_distance,    0.0001);
    try t.expectApproxEqAbs(@as(f32, 5.0),  s.min_distance,    0.0001);
    try t.expectApproxEqAbs(@as(f32, 0.25), s.pitch_variation, 0.0001);
    try t.expectEqual(@as(u32, 1000), s.interval);
    try t.expectEqual(@as(u32, 200),  s.interval_vrtn);
    try t.expectEqual(@as(u32, 0b0000_1111_1111_0000), s.hours);
    try t.expectEqual(@as(u8, 1),    s.random_position);
    try t.expectApproxEqAbs(@as(f32, 3.0), s.random_range_x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 4.0), s.random_range_y, 0.0001);
    try t.expectEqualStrings("SND_Ambience01", s.tag);
    try t.expectEqualStrings("snd_ambience01", s.template_res_ref.slice());
}

test "UTS sounds wave list round-trip" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const a = uts.arena.allocator();
    const entries = try a.alloc(SoundEntry, 3);
    entries[0] = .{ .res_ref = gff.ResRef.fromSlice("amb_birds01") };
    entries[1] = .{ .res_ref = gff.ResRef.fromSlice("amb_birds02") };
    entries[2] = .{ .res_ref = gff.ResRef.fromSlice("amb_wind01") };
    uts.sound.sounds = entries;

    const bytes = try uts.serialize(gpa);
    defer gpa.free(bytes);

    var uts2 = try UtsFile.parse(gpa, bytes);
    defer uts2.deinit();

    try t.expectEqual(@as(usize, 3), uts2.sound.sounds.len);
    try t.expectEqualStrings("amb_birds01", uts2.sound.sounds[0].res_ref.slice());
    try t.expectEqualStrings("amb_birds02", uts2.sound.sounds[1].res_ref.slice());
    try t.expectEqualStrings("amb_wind01",  uts2.sound.sounds[2].res_ref.slice());
}

test "UTS blueprint-only fields round-trip" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const a = uts.arena.allocator();
    uts.sound.comment    = try a.dupe(u8, "Exterior ambient loop");
    uts.sound.palette_id = 7;

    const bytes = try uts.serialize(gpa);
    defer gpa.free(bytes);

    var uts2 = try UtsFile.parse(gpa, bytes);
    defer uts2.deinit();

    try t.expectEqualStrings("Exterior ambient loop", uts2.sound.comment.?);
    try t.expectEqual(@as(?u8, 7), uts2.sound.palette_id);
}

test "UTS LocName round-trip" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const a = uts.arena.allocator();
    uts.sound.loc_name.string_ref = 100;
    try uts.sound.loc_name.substrings.append(a, .{
        .string_id = 0,
        .text      = try a.dupe(u8, "Forest Ambience"),
    });

    const bytes = try uts.serialize(gpa);
    defer gpa.free(bytes);

    var uts2 = try UtsFile.parse(gpa, bytes);
    defer uts2.deinit();

    try t.expectEqual(@as(u32, 100), uts2.sound.loc_name.string_ref);
    try t.expectEqual(@as(usize, 1), uts2.sound.loc_name.substrings.items.len);
    try t.expectEqualStrings("Forest Ambience", uts2.sound.loc_name.substrings.items[0].text);
}

test "SoundStruct instance variant round-trip" {
    const gpa = t.allocator;

    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s: SoundStruct = .{};
    s.active          = 1;
    s.looping         = 1;
    s.positional      = 1;
    s.volume          = 100;
    s.max_distance    = 15.0;
    s.min_distance    = 2.0;
    s.tag             = try a.dupe(u8, "SND_Waterfall");
    s.template_res_ref = gff.ResRef.fromSlice("snd_waterfall");
    s.generated_type  = 0;
    s.x_position      = 12.5;
    s.y_position      = 8.0;
    s.z_position      = 0.0;

    const entries = try a.alloc(SoundEntry, 1);
    entries[0] = .{ .res_ref = gff.ResRef.fromSlice("waterfall01") };
    s.sounds = entries;

    const sidx = try g.addStruct(0); // Sound instance StructID not specified; 0 conventional
    try s.writeIntoGff(&g, sidx, .instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try SoundStruct.fromGffStruct(
        arena2.allocator(), &g, &g.structs.items[sidx], .instance,
    );

    try t.expectEqual(@as(u8, 1),   parsed.active);
    try t.expectEqual(@as(u8, 1),   parsed.looping);
    try t.expectEqual(@as(u8, 100), parsed.volume);
    try t.expectEqualStrings("SND_Waterfall", parsed.tag);
    try t.expectEqualStrings("snd_waterfall", parsed.template_res_ref.slice());
    try t.expectEqual(@as(?u8, 0),  parsed.generated_type);
    try t.expectApproxEqAbs(@as(f32, 12.5), parsed.x_position.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 8.0),  parsed.y_position.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 0.0),  parsed.z_position.?, 0.0001);
    try t.expectEqual(@as(usize, 1), parsed.sounds.len);
    try t.expectEqualStrings("waterfall01", parsed.sounds[0].res_ref.slice());
    // Blueprint-only fields absent
    try t.expect(parsed.comment == null);
    try t.expect(parsed.palette_id == null);
}

test "SoundStruct game_instance variant round-trip" {
    const gpa = t.allocator;

    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var s: SoundStruct = .{};
    s.active       = 1;
    s.tag          = try a.dupe(u8, "SND_Save");
    s.generated_type = 0;
    s.x_position   = 1.0;
    s.y_position   = 2.0;
    s.z_position   = 0.0;
    s.object_id    = 0x0000_0042;

    const vars = try a.alloc(common.Variable, 1);
    vars[0] = .{ .name = try a.dupe(u8, "PlayCount"), .value = .{ .int_val = 5 } };
    s.var_table = vars;

    const sidx = try g.addStruct(0);
    try s.writeIntoGff(&g, sidx, .game_instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try SoundStruct.fromGffStruct(
        arena2.allocator(), &g, &g.structs.items[sidx], .game_instance,
    );

    try t.expectEqual(@as(?u32, 0x42), parsed.object_id);
    try t.expectEqual(@as(usize, 1),   parsed.var_table.len);
    try t.expectEqualStrings("PlayCount", parsed.var_table[0].name);
    try t.expectEqual(@as(i32, 5),     parsed.var_table[0].value.int_val);
}

test "UTS byte-exact double serialize" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const a = uts.arena.allocator();
    uts.sound.active          = 1;
    uts.sound.looping         = 1;
    uts.sound.positional      = 0;
    uts.sound.priority        = 2;
    uts.sound.times           = 3;
    uts.sound.volume          = 90;
    uts.sound.max_distance    = 40.0;
    uts.sound.min_distance    = 1.0;
    uts.sound.interval        = 500;
    uts.sound.tag             = try a.dupe(u8, "SND_Rain");
    uts.sound.template_res_ref = gff.ResRef.fromSlice("snd_rain");
    uts.sound.comment         = try a.dupe(u8, "Rain loop");
    uts.sound.palette_id      = 1;

    const entries = try a.alloc(SoundEntry, 2);
    entries[0] = .{ .res_ref = gff.ResRef.fromSlice("rain_heavy") };
    entries[1] = .{ .res_ref = gff.ResRef.fromSlice("rain_light") };
    uts.sound.sounds = entries;

    const bytes1 = try uts.serialize(gpa);
    defer gpa.free(bytes1);

    var uts2 = try UtsFile.parse(gpa, bytes1);
    defer uts2.deinit();
    const bytes2 = try uts2.serialize(gpa);
    defer gpa.free(bytes2);

    try t.expectEqualSlices(u8, bytes1, bytes2);
}

test "UTS wrong magic rejected" {
    const gpa = t.allocator;
    var uts = UtsFile.init(gpa);
    defer uts.deinit();

    const bytes = try uts.serialize(gpa);
    defer gpa.free(bytes);

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[0..4], "UTX ");

    try t.expectError(error.InvalidFileType, UtsFile.parse(gpa, mut));
}
