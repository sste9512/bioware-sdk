//! Bioware Aurora Area File formats: ARE, GIT, and GIC.
//!
//! All three are GFF V3.2 files (see `gff.zig`). This module provides
//! strongly-typed wrappers that map every documented top-level field to a
//! native Zig value while still allowing access to per-instance GFF Structs
//! that aren't fully covered by this PDF (Creature/Door/Encounter/...).
//!
//! Memory model: each file owns an internal `std.heap.ArenaAllocator` that
//! backs every string, list, and substring it returns. Call `deinit` once to
//! free everything.
//!
//! Round-trip discipline: `serialize` deterministically rebuilds a fresh
//! GffFile from the typed fields, so `parse → serialize → parse → serialize`
//! is byte-exact. Unknown fields in the input are NOT preserved (v1 limit).
const std = @import("std");
const gff = @import("gff.zig");

// ============================================================================
// Shared error type
// ============================================================================

pub const Error = error{
    /// A required documented field was absent from the GFF.
    MissingRequiredField,
    /// A field was present but with the wrong type tag.
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

// ============================================================================
// Internal helpers: read typed values out of a parsed GFF struct
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
fn optListDupe(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error![]u32 {
    const f = g.getField(s, label) orelse return arena.alloc(u32, 0);
    return switch (f.value) {
        .list => |v| arena.dupe(u32, v),
        else => error.WrongFieldType,
    };
}
fn requireStruct(g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error!*const gff.Struct {
    const f = g.getField(s, label) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .@"struct" => |idx| &g.structs.items[idx],
        else => error.WrongFieldType,
    };
}

// ============================================================================
// AreaTile (StructID 1, used inside ARE Tile_List)
// ============================================================================

pub const AreaTile = struct {
    pub const STRUCT_ID: u32 = 1;

    anim_loop_1: i32 = 0,
    anim_loop_2: i32 = 0,
    anim_loop_3: i32 = 0,
    height: i32 = 0,
    id: i32 = 0,
    main_light_1: u8 = 0,
    main_light_2: u8 = 0,
    orientation: i32 = 0,
    src_light_1: u8 = 0,
    src_light_2: u8 = 0,

    fn fromStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!AreaTile {
        return .{
            .anim_loop_1 = try optInt(g, s, "Tile_AnimLoop1", 0),
            .anim_loop_2 = try optInt(g, s, "Tile_AnimLoop2", 0),
            .anim_loop_3 = try optInt(g, s, "Tile_AnimLoop3", 0),
            .height = try optInt(g, s, "Tile_Height", 0),
            .id = try optInt(g, s, "Tile_ID", 0),
            .main_light_1 = try optByte(g, s, "Tile_MainLight1", 0),
            .main_light_2 = try optByte(g, s, "Tile_MainLight2", 0),
            .orientation = try optInt(g, s, "Tile_Orientation", 0),
            .src_light_1 = try optByte(g, s, "Tile_SrcLight1", 0),
            .src_light_2 = try optByte(g, s, "Tile_SrcLight2", 0),
        };
    }

    fn writeInto(self: AreaTile, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "Tile_AnimLoop1", .{ .int = self.anim_loop_1 });
        try g.addFieldToStruct(struct_idx, "Tile_AnimLoop2", .{ .int = self.anim_loop_2 });
        try g.addFieldToStruct(struct_idx, "Tile_AnimLoop3", .{ .int = self.anim_loop_3 });
        try g.addFieldToStruct(struct_idx, "Tile_Height", .{ .int = self.height });
        try g.addFieldToStruct(struct_idx, "Tile_ID", .{ .int = self.id });
        try g.addFieldToStruct(struct_idx, "Tile_MainLight1", .{ .byte = self.main_light_1 });
        try g.addFieldToStruct(struct_idx, "Tile_MainLight2", .{ .byte = self.main_light_2 });
        try g.addFieldToStruct(struct_idx, "Tile_Orientation", .{ .int = self.orientation });
        try g.addFieldToStruct(struct_idx, "Tile_SrcLight1", .{ .byte = self.src_light_1 });
        try g.addFieldToStruct(struct_idx, "Tile_SrcLight2", .{ .byte = self.src_light_2 });
    }

    /// Pretty-print a single tile's fields as `key=value` pairs.
    pub fn print(self: AreaTile, w: *std.Io.Writer) !void {
        try w.print(
            "AreaTile{{ id={d}, height={d}, orientation={d}, anim_loops=[{d},{d},{d}], main_light=[{d},{d}], src_light=[{d},{d}] }}",
            .{
                self.id,
                self.height,
                self.orientation,
                self.anim_loop_1,
                self.anim_loop_2,
                self.anim_loop_3,
                self.main_light_1,
                self.main_light_2,
                self.src_light_1,
                self.src_light_2,
            },
        );
    }
};

// ============================================================================
// ARE file
// ============================================================================

pub const AreFile = struct {
    pub const FILE_TYPE = "ARE ";

    pub const FLAG_INTERIOR: u32 = 0x0001;
    pub const FLAG_UNDERGROUND: u32 = 0x0002;
    pub const FLAG_NATURAL: u32 = 0x0004;

    arena: std.heap.ArenaAllocator,

    chance_lightning: i32 = 0,
    chance_rain: i32 = 0,
    chance_snow: i32 = 0,
    comments: []u8 = &.{},
    creator_id: i32 = -1,
    day_night_cycle: u8 = 0,
    flags: u32 = 0,
    height: i32 = 0,
    id: i32 = -1,
    is_night: u8 = 0,
    lighting_scheme: u8 = 0,
    load_screen_id: u16 = 0,
    mod_listen_check: i32 = 0,
    mod_spot_check: i32 = 0,
    moon_ambient_color: u32 = 0,
    moon_diffuse_color: u32 = 0,
    moon_fog_amount: u8 = 0,
    moon_fog_color: u32 = 0,
    moon_shadows: u8 = 0,
    name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    no_rest: u8 = 0,
    on_enter: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_exit: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_heartbeat: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_user_defined: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    player_vs_player: u8 = 0,
    res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    sky_box: u8 = 0,
    shadow_opacity: u8 = 0,
    sun_ambient_color: u32 = 0,
    sun_diffuse_color: u32 = 0,
    sun_fog_amount: u8 = 0,
    sun_fog_color: u32 = 0,
    sun_shadows: u8 = 0,
    tag: []u8 = &.{},
    tile_list: []AreaTile = &.{},
    tile_set: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    version: u32 = 1,
    width: i32 = 0,
    wind_power: i32 = 0,

    pub fn init(parent_alloc: std.mem.Allocator) AreFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *AreFile) void {
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!AreFile {
        var self = AreFile.init(parent_alloc);
        errdefer self.deinit();

        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        const a = self.arena.allocator();
        const tl = &g.structs.items[0];

        self.chance_lightning = try optInt(&g, tl, "ChanceLightning", 0);
        self.chance_rain = try optInt(&g, tl, "ChangeRain", 0);
        self.chance_snow = try optInt(&g, tl, "ChanceSnow", 0);
        self.comments = try optExoStringDupe(a, &g, tl, "Comments");
        self.creator_id = try optInt(&g, tl, "Creator_ID", -1);
        self.day_night_cycle = try optByte(&g, tl, "DayNightCycle", 0);
        self.flags = try optDword(&g, tl, "Flags", 0);
        self.height = try optInt(&g, tl, "Height", 0);
        self.id = try optInt(&g, tl, "ID", -1);
        self.is_night = try optByte(&g, tl, "IsNight", 0);
        self.lighting_scheme = try optByte(&g, tl, "LightingScheme", 0);
        self.load_screen_id = try optWord(&g, tl, "LoadScreenID", 0);
        self.mod_listen_check = try optInt(&g, tl, "ModListenCheck", 0);
        self.mod_spot_check = try optInt(&g, tl, "ModSpotCheck", 0);
        self.moon_ambient_color = try optDword(&g, tl, "MoonAmbientColor", 0);
        self.moon_diffuse_color = try optDword(&g, tl, "MoodDiffuseColor", 0);
        self.moon_fog_amount = try optByte(&g, tl, "MoonFogAmount", 0);
        self.moon_fog_color = try optDword(&g, tl, "MoonFogColor", 0);
        self.moon_shadows = try optByte(&g, tl, "MoonShadows", 0);
        self.name = try optExoLocDupe(a, &g, tl, "Name");
        self.no_rest = try optByte(&g, tl, "NoRest", 0);
        self.on_enter = try optResRef(&g, tl, "OnEnter");
        self.on_exit = try optResRef(&g, tl, "OnExit");
        self.on_heartbeat = try optResRef(&g, tl, "OnHeartbeat");
        self.on_user_defined = try optResRef(&g, tl, "OnUserDefined");
        self.player_vs_player = try optByte(&g, tl, "PlayerVsPlayer", 0);
        self.res_ref = try optResRef(&g, tl, "ResRef");
        self.sky_box = try optByte(&g, tl, "SkyBox", 0);
        self.shadow_opacity = try optByte(&g, tl, "ShadowOpacity", 0);
        self.sun_ambient_color = try optDword(&g, tl, "SunAmbientColor", 0);
        self.sun_diffuse_color = try optDword(&g, tl, "SunDiffuseColor", 0);
        self.sun_fog_amount = try optByte(&g, tl, "SunFogAmount", 0);
        self.sun_fog_color = try optDword(&g, tl, "SunFogColor", 0);
        self.sun_shadows = try optByte(&g, tl, "SunShadows", 0);
        self.tag = try optExoStringDupe(a, &g, tl, "Tag");
        self.tile_set = try optResRef(&g, tl, "TileSet");
        self.version = try optDword(&g, tl, "Version", 1);
        self.width = try optInt(&g, tl, "Width", 0);
        self.wind_power = try optInt(&g, tl, "WindPower", 0);

        // Tile_List
        if (g.getField(tl, "Tile_List")) |f| switch (f.value) {
            .list => |handles| {
                const tiles = try a.alloc(AreaTile, handles.len);
                for (handles, 0..) |h, i| {
                    if (h >= g.structs.items.len) return error.InvalidFormat;
                    tiles[i] = try AreaTile.fromStruct(&g, &g.structs.items[h]);
                }
                self.tile_list = tiles;
            },
            else => return error.WrongFieldType,
        };

        return self;
    }

    pub fn serialize(self: *const AreFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();

        try g.addFieldToStruct(0, "ChanceLightning", .{ .int = self.chance_lightning });
        try g.addFieldToStruct(0, "ChangeRain", .{ .int = self.chance_rain });
        try g.addFieldToStruct(0, "ChanceSnow", .{ .int = self.chance_snow });
        try g.addFieldToStruct(0, "Comments", .{ .exo_string = try alloc.dupe(u8, self.comments) });
        try g.addFieldToStruct(0, "Creator_ID", .{ .int = self.creator_id });
        try g.addFieldToStruct(0, "DayNightCycle", .{ .byte = self.day_night_cycle });
        try g.addFieldToStruct(0, "Flags", .{ .dword = self.flags });
        try g.addFieldToStruct(0, "Height", .{ .int = self.height });
        try g.addFieldToStruct(0, "ID", .{ .int = self.id });
        try g.addFieldToStruct(0, "IsNight", .{ .byte = self.is_night });
        try g.addFieldToStruct(0, "LightingScheme", .{ .byte = self.lighting_scheme });
        try g.addFieldToStruct(0, "LoadScreenID", .{ .word = self.load_screen_id });
        try g.addFieldToStruct(0, "ModListenCheck", .{ .int = self.mod_listen_check });
        try g.addFieldToStruct(0, "ModSpotCheck", .{ .int = self.mod_spot_check });
        try g.addFieldToStruct(0, "MoonAmbientColor", .{ .dword = self.moon_ambient_color });
        try g.addFieldToStruct(0, "MoodDiffuseColor", .{ .dword = self.moon_diffuse_color });
        try g.addFieldToStruct(0, "MoonFogAmount", .{ .byte = self.moon_fog_amount });
        try g.addFieldToStruct(0, "MoonFogColor", .{ .dword = self.moon_fog_color });
        try g.addFieldToStruct(0, "MoonShadows", .{ .byte = self.moon_shadows });
        try g.addFieldToStruct(0, "Name", .{ .exo_loc_string = try cloneExoLoc(alloc, self.name) });
        try g.addFieldToStruct(0, "NoRest", .{ .byte = self.no_rest });
        try g.addFieldToStruct(0, "OnEnter", .{ .res_ref = self.on_enter });
        try g.addFieldToStruct(0, "OnExit", .{ .res_ref = self.on_exit });
        try g.addFieldToStruct(0, "OnHeartbeat", .{ .res_ref = self.on_heartbeat });
        try g.addFieldToStruct(0, "OnUserDefined", .{ .res_ref = self.on_user_defined });
        try g.addFieldToStruct(0, "PlayerVsPlayer", .{ .byte = self.player_vs_player });
        try g.addFieldToStruct(0, "ResRef", .{ .res_ref = self.res_ref });
        try g.addFieldToStruct(0, "SkyBox", .{ .byte = self.sky_box });
        try g.addFieldToStruct(0, "ShadowOpacity", .{ .byte = self.shadow_opacity });
        try g.addFieldToStruct(0, "SunAmbientColor", .{ .dword = self.sun_ambient_color });
        try g.addFieldToStruct(0, "SunDiffuseColor", .{ .dword = self.sun_diffuse_color });
        try g.addFieldToStruct(0, "SunFogAmount", .{ .byte = self.sun_fog_amount });
        try g.addFieldToStruct(0, "SunFogColor", .{ .dword = self.sun_fog_color });
        try g.addFieldToStruct(0, "SunShadows", .{ .byte = self.sun_shadows });
        try g.addFieldToStruct(0, "Tag", .{ .exo_string = try alloc.dupe(u8, self.tag) });

        // Tile_List
        const handles = try alloc.alloc(u32, self.tile_list.len);
        for (self.tile_list, 0..) |tile, i| {
            const sidx = try g.addStruct(AreaTile.STRUCT_ID);
            try tile.writeInto(&g, sidx);
            handles[i] = sidx;
        }
        try g.addFieldToStruct(0, "Tile_List", .{ .list = handles });

        try g.addFieldToStruct(0, "TileSet", .{ .res_ref = self.tile_set });
        try g.addFieldToStruct(0, "Version", .{ .dword = self.version });
        try g.addFieldToStruct(0, "Width", .{ .int = self.width });
        try g.addFieldToStruct(0, "WindPower", .{ .int = self.wind_power });

        return g.serialize(alloc);
    }

    // -------- BGR color helpers -------------------------------------------
    pub const Rgb = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn print(self: Rgb, w: *std.Io.Writer) !void {
            try w.print("rgb({d},{d},{d}) #{x:0>2}{x:0>2}{x:0>2}", .{
                self.r, self.g, self.b, self.r, self.g, self.b,
            });
        }
    };

    /// Decode a BGR-packed DWORD into separate R/G/B bytes. On disk the bytes
    /// appear as `R G B 0`, so as a little-endian u32 the R is in the low byte.
    pub fn rgbFromBgr(v: u32) Rgb {
        return .{
            .r = @intCast(v & 0xFF),
            .g = @intCast((v >> 8) & 0xFF),
            .b = @intCast((v >> 16) & 0xFF),
        };
    }
    pub fn bgrFromRgb(r: u8, g: u8, b: u8) u32 {
        return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
    }

    /// Pretty-print the entire ARE header to `w`, one field per line.
    /// Tile_List is summarised (count + first few tiles); pass `verbose=true`
    /// to dump every tile.
    pub fn print(self: *const AreFile, w: *std.Io.Writer, verbose: bool) !void {
        try w.print("AreFile {{\n", .{});
        try w.print("  res_ref            = \"{s}\"\n", .{self.res_ref.slice()});
        try w.print("  tag                = \"{s}\"\n", .{self.tag});
        try w.writeAll("  name               = ");
        try printExoLoc(w, self.name);
        try w.writeByte('\n');
        try w.print("  comments           = \"{s}\"\n", .{self.comments});
        try w.print("  version            = {d}\n", .{self.version});
        try w.print("  id                 = {d}\n", .{self.id});
        try w.print("  creator_id         = {d}\n", .{self.creator_id});
        try w.print("  flags              = 0x{x:0>8} (interior={}, underground={}, natural={})\n", .{
            self.flags,
            (self.flags & FLAG_INTERIOR) != 0,
            (self.flags & FLAG_UNDERGROUND) != 0,
            (self.flags & FLAG_NATURAL) != 0,
        });
        try w.print("  size (W x H)       = {d} x {d}\n", .{ self.width, self.height });
        try w.print("  tile_set           = \"{s}\"\n", .{self.tile_set.slice()});
        try w.print("  day_night_cycle    = {d}, is_night = {d}, lighting_scheme = {d}\n", .{
            self.day_night_cycle, self.is_night, self.lighting_scheme,
        });
        try w.print("  load_screen_id     = {d}\n", .{self.load_screen_id});
        try w.print("  no_rest            = {d}, player_vs_player = {d}\n", .{ self.no_rest, self.player_vs_player });
        try w.print("  sky_box            = {d}, shadow_opacity = {d}\n", .{ self.sky_box, self.shadow_opacity });
        try w.print("  mod_listen / spot  = {d} / {d}\n", .{ self.mod_listen_check, self.mod_spot_check });
        try w.print("  wind_power         = {d}\n", .{self.wind_power});
        try w.print("  weather chances    = lightning={d}, rain={d}, snow={d}\n", .{
            self.chance_lightning, self.chance_rain, self.chance_snow,
        });
        try w.writeAll("  sun                = ");
        try printBgrColor(w, "ambient", self.sun_ambient_color);
        try w.writeAll(", ");
        try printBgrColor(w, "diffuse", self.sun_diffuse_color);
        try w.writeAll(", ");
        try printBgrColor(w, "fog", self.sun_fog_color);
        try w.print(", fog_amount={d}, shadows={d}\n", .{ self.sun_fog_amount, self.sun_shadows });
        try w.writeAll("  moon               = ");
        try printBgrColor(w, "ambient", self.moon_ambient_color);
        try w.writeAll(", ");
        try printBgrColor(w, "diffuse", self.moon_diffuse_color);
        try w.writeAll(", ");
        try printBgrColor(w, "fog", self.moon_fog_color);
        try w.print(", fog_amount={d}, shadows={d}\n", .{ self.moon_fog_amount, self.moon_shadows });
        try w.print("  on_enter           = \"{s}\"\n", .{self.on_enter.slice()});
        try w.print("  on_exit            = \"{s}\"\n", .{self.on_exit.slice()});
        try w.print("  on_heartbeat       = \"{s}\"\n", .{self.on_heartbeat.slice()});
        try w.print("  on_user_defined    = \"{s}\"\n", .{self.on_user_defined.slice()});
        try w.print("  tile_list          = {d} tile(s)\n", .{self.tile_list.len});
        const limit: usize = if (verbose) self.tile_list.len else @min(self.tile_list.len, 8);
        for (self.tile_list[0..limit], 0..) |tile, i| {
            try w.print("    [{d}] ", .{i});
            try tile.print(w);
            try w.writeByte('\n');
        }
        if (!verbose and self.tile_list.len > limit)
            try w.print("    ... ({d} more)\n", .{self.tile_list.len - limit});
        try w.writeAll("}\n");
    }
};

// ============================================================================
// GIT file
// ============================================================================

pub const Weather = enum(u8) { clear = 0, rain = 1, snow = 2, _ };

pub const AreaProperties = struct {
    pub const STRUCT_ID: u32 = 100;

    ambient_snd_day: i32 = 0,
    ambient_snd_day_vol: i32 = 0,
    ambient_snd_night: i32 = 0,
    ambient_snd_nit_vol: i32 = 0,
    env_audio: i32 = 0,
    music_battle: i32 = 0,
    music_day: i32 = 0,
    music_delay: i32 = 0,
    music_night: i32 = 0,

    fn fromStruct(g: *const gff.GffFile, s: *const gff.Struct) Error!AreaProperties {
        return .{
            .ambient_snd_day = try optInt(g, s, "AmbientSndDay", 0),
            .ambient_snd_day_vol = try optInt(g, s, "AmbientSndDayVol", 0),
            .ambient_snd_night = try optInt(g, s, "AmbientSndNight", 0),
            .ambient_snd_nit_vol = try optInt(g, s, "AmbientSndNitVol", 0),
            .env_audio = try optInt(g, s, "EnvAudio", 0),
            .music_battle = try optInt(g, s, "MusicBattle", 0),
            .music_day = try optInt(g, s, "MusicDay", 0),
            .music_delay = try optInt(g, s, "MusicDelay", 0),
            .music_night = try optInt(g, s, "MusicNight", 0),
        };
    }

    fn writeInto(self: AreaProperties, g: *gff.GffFile, struct_idx: u32) !void {
        try g.addFieldToStruct(struct_idx, "AmbientSndDay", .{ .int = self.ambient_snd_day });
        try g.addFieldToStruct(struct_idx, "AmbientSndDayVol", .{ .int = self.ambient_snd_day_vol });
        try g.addFieldToStruct(struct_idx, "AmbientSndNight", .{ .int = self.ambient_snd_night });
        try g.addFieldToStruct(struct_idx, "AmbientSndNitVol", .{ .int = self.ambient_snd_nit_vol });
        try g.addFieldToStruct(struct_idx, "EnvAudio", .{ .int = self.env_audio });
        try g.addFieldToStruct(struct_idx, "MusicBattle", .{ .int = self.music_battle });
        try g.addFieldToStruct(struct_idx, "MusicDay", .{ .int = self.music_day });
        try g.addFieldToStruct(struct_idx, "MusicDelay", .{ .int = self.music_delay });
        try g.addFieldToStruct(struct_idx, "MusicNight", .{ .int = self.music_night });
    }

    pub fn print(self: AreaProperties, w: *std.Io.Writer) !void {
        try w.print("AreaProperties {{\n", .{});
        try w.print("  music   day={d}, night={d}, battle={d}, delay={d}\n", .{
            self.music_day, self.music_night, self.music_battle, self.music_delay,
        });
        try w.print("  ambient day={d} (vol {d}), night={d} (vol {d})\n", .{
            self.ambient_snd_day,   self.ambient_snd_day_vol,
            self.ambient_snd_night, self.ambient_snd_nit_vol,
        });
        try w.print("  env_audio={d}\n", .{self.env_audio});
        try w.writeAll("}\n");
    }
};

/// A handle pointing to one of the original GFF Structs stored in the GIT's
/// raw struct array. Use `git.getStruct(handle)` to inspect it.
pub const InstanceHandle = u32;

pub const GitFile = struct {
    pub const FILE_TYPE = "GIT ";

    pub const StructIds = struct {
        pub const item: u32 = 0;
        pub const trigger: u32 = 1;
        pub const creature: u32 = 4;
        pub const waypoint: u32 = 5;
        pub const sound: u32 = 6;
        pub const encounter: u32 = 7;
        pub const door: u32 = 8;
        pub const placeable: u32 = 9;
        pub const store: u32 = 11;
        pub const area_effect: u32 = 13;
    };

    arena: std.heap.ArenaAllocator,

    /// The full underlying GFF, kept alive so callers can inspect each
    /// instance Struct (Creature/Door/...) by handle. Reset and rebuilt by
    /// `serialize`. Owned by `arena`'s parent allocator (the user-supplied
    /// allocator); `deinit` releases it explicitly.
    gff_storage: ?gff.GffFile = null,

    area_properties: AreaProperties = .{},

    creatures: []InstanceHandle = &.{},
    doors: []InstanceHandle = &.{},
    encounters: []InstanceHandle = &.{},
    items: []InstanceHandle = &.{},
    placeables: []InstanceHandle = &.{},
    sounds: []InstanceHandle = &.{},
    stores: []InstanceHandle = &.{},
    triggers: []InstanceHandle = &.{},
    waypoints: []InstanceHandle = &.{},

    // SaveGame-only optional fields.
    area_effects: ?[]InstanceHandle = null,
    current_weather: ?Weather = null,
    var_table: ?[]InstanceHandle = null,
    weather_started: ?u8 = null,

    pub fn init(parent_alloc: std.mem.Allocator) GitFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *GitFile) void {
        if (self.gff_storage) |*g| g.deinit();
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!GitFile {
        var self = GitFile.init(parent_alloc);
        errdefer self.deinit();

        var g = gff.GffFile.initEmpty(parent_alloc);
        errdefer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        const a = self.arena.allocator();
        const tl = &g.structs.items[0];

        // AreaProperties is documented as always present.
        const ap_struct = requireStruct(&g, tl, "AreaProperties") catch |e| switch (e) {
            error.MissingRequiredField, error.WrongFieldType => return e,
            else => return e,
        };
        self.area_properties = try AreaProperties.fromStruct(&g, ap_struct);

        self.creatures = try optListDupe(a, &g, tl, "Creature List");
        self.doors = try optListDupe(a, &g, tl, "Door List");
        self.encounters = try optListDupe(a, &g, tl, "Encounter List");
        self.items = try optListDupe(a, &g, tl, "List");
        self.placeables = try optListDupe(a, &g, tl, "Placeable List");
        self.sounds = try optListDupe(a, &g, tl, "SoundList");
        self.stores = try optListDupe(a, &g, tl, "StoreList");
        self.triggers = try optListDupe(a, &g, tl, "TriggerList");
        self.waypoints = try optListDupe(a, &g, tl, "WaypointList");

        // SaveGame additions: only set if present.
        if (g.getField(tl, "AreaEffectList")) |f| switch (f.value) {
            .list => |v| self.area_effects = try a.dupe(u32, v),
            else => return error.WrongFieldType,
        };
        if (g.getField(tl, "CurrentWeather")) |f| switch (f.value) {
            .byte => |v| self.current_weather = @enumFromInt(v),
            else => return error.WrongFieldType,
        };
        if (g.getField(tl, "VarTable")) |f| switch (f.value) {
            .list => |v| self.var_table = try a.dupe(u32, v),
            else => return error.WrongFieldType,
        };
        if (g.getField(tl, "WeatherStarted")) |f| switch (f.value) {
            .byte => |v| self.weather_started = v,
            else => return error.WrongFieldType,
        };

        self.gff_storage = g;
        return self;
    }

    pub fn serialize(self: *GitFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();

        // AreaProperties always comes from the typed value.
        const ap_idx = try g.addStruct(AreaProperties.STRUCT_ID);
        try self.area_properties.writeInto(&g, ap_idx);
        try g.addFieldToStruct(0, "AreaProperties", .{ .@"struct" = ap_idx });

        // Each typed list references a subset of src's struct array. We only
        // clone the ones we actually reference; nested structs are cloned
        // recursively by cloneStruct/cloneFieldValue.
        const src_opt: ?*const gff.GffFile = if (self.gff_storage) |*x| x else null;

        try emitList(alloc, &g, src_opt, "Creature List", self.creatures);
        try emitList(alloc, &g, src_opt, "Door List", self.doors);
        try emitList(alloc, &g, src_opt, "Encounter List", self.encounters);
        try emitList(alloc, &g, src_opt, "List", self.items);
        try emitList(alloc, &g, src_opt, "Placeable List", self.placeables);
        try emitList(alloc, &g, src_opt, "SoundList", self.sounds);
        try emitList(alloc, &g, src_opt, "StoreList", self.stores);
        try emitList(alloc, &g, src_opt, "TriggerList", self.triggers);
        try emitList(alloc, &g, src_opt, "WaypointList", self.waypoints);

        if (self.area_effects) |v|
            try emitList(alloc, &g, src_opt, "AreaEffectList", v);
        if (self.current_weather) |w|
            try g.addFieldToStruct(0, "CurrentWeather", .{ .byte = @intFromEnum(w) });
        if (self.var_table) |v|
            try emitList(alloc, &g, src_opt, "VarTable", v);
        if (self.weather_started) |w|
            try g.addFieldToStruct(0, "WeatherStarted", .{ .byte = w });

        return g.serialize(alloc);
    }

    /// Resolve an instance handle to its underlying GFF Struct (read-only).
    pub fn getStruct(self: *const GitFile, handle: InstanceHandle) ?*const gff.Struct {
        const g = if (self.gff_storage) |*x| x else return null;
        if (handle >= g.structs.items.len) return null;
        return &g.structs.items[handle];
    }

    /// Access the underlying GFF (e.g. to read individual instance fields).
    pub fn underlying(self: *const GitFile) ?*const gff.GffFile {
        return if (self.gff_storage) |*x| x else null;
    }

    /// Pretty-print GIT contents: instance-list counts plus AreaProperties.
    /// Per-instance fields can be inspected via `getStruct(handle)`.
    pub fn print(self: *const GitFile, w: *std.Io.Writer) !void {
        try w.print("GitFile {{\n", .{});
        try w.writeAll("  ");
        try self.area_properties.print(w);
        try w.print("  creatures   = {d}\n", .{self.creatures.len});
        try w.print("  doors       = {d}\n", .{self.doors.len});
        try w.print("  encounters  = {d}\n", .{self.encounters.len});
        try w.print("  items       = {d}\n", .{self.items.len});
        try w.print("  placeables  = {d}\n", .{self.placeables.len});
        try w.print("  sounds      = {d}\n", .{self.sounds.len});
        try w.print("  stores      = {d}\n", .{self.stores.len});
        try w.print("  triggers    = {d}\n", .{self.triggers.len});
        try w.print("  waypoints   = {d}\n", .{self.waypoints.len});
        if (self.area_effects) |v| try w.print("  area_effects    = {d}\n", .{v.len});
        if (self.var_table) |v| try w.print("  var_table       = {d}\n", .{v.len});
        if (self.current_weather) |wx| {
            const name: []const u8 = switch (wx) {
                .clear => "clear",
                .rain => "rain",
                .snow => "snow",
                _ => "unknown",
            };
            try w.print("  current_weather = {s} ({d})\n", .{ name, @intFromEnum(wx) });
        }
        if (self.weather_started) |b| try w.print("  weather_started = {d}\n", .{b});
        try w.writeAll("}\n");
    }

    /// Dump every instance handle across all lists, resolving the `Tag` and
    /// `ResRef` fields from the underlying GFF where available. `limit_per_list`
    /// caps the number of entries shown per list (0 = unlimited).
    pub fn printInstances(self: *const GitFile, w: *std.Io.Writer, limit_per_list: usize) !void {
        try w.writeAll("GitFile instances {\n");
        try printInstanceList(w, self, "creatures", self.creatures, limit_per_list);
        try printInstanceList(w, self, "doors", self.doors, limit_per_list);
        try printInstanceList(w, self, "encounters", self.encounters, limit_per_list);
        try printInstanceList(w, self, "items", self.items, limit_per_list);
        try printInstanceList(w, self, "placeables", self.placeables, limit_per_list);
        try printInstanceList(w, self, "sounds", self.sounds, limit_per_list);
        try printInstanceList(w, self, "stores", self.stores, limit_per_list);
        try printInstanceList(w, self, "triggers", self.triggers, limit_per_list);
        try printInstanceList(w, self, "waypoints", self.waypoints, limit_per_list);
        if (self.area_effects) |v|
            try printInstanceList(w, self, "area_effects", v, limit_per_list);
        if (self.var_table) |v|
            try printInstanceList(w, self, "var_table", v, limit_per_list);
        try w.writeAll("}\n");
    }
};

fn printInstanceList(
    w: *std.Io.Writer,
    git: *const GitFile,
    label: []const u8,
    handles: []const InstanceHandle,
    limit_per_list: usize,
) !void {
    try w.print("  {s:<13} ({d}):\n", .{ label, handles.len });
    const limit: usize = if (limit_per_list == 0) handles.len else @min(handles.len, limit_per_list);
    for (handles[0..limit], 0..) |h, i| {
        try w.print("    [{d}] handle={d}", .{ i, h });
        if (git.getStruct(h)) |s| {
            try w.print(", type_id={d}", .{s.type_id});
            const ul = git.underlying().?;
            if (ul.getField(s, "Tag")) |f| switch (f.value) {
                .exo_string => |str| try w.print(", Tag=\"{s}\"", .{str}),
                else => {},
            };
            if (ul.getField(s, "ResRef")) |f| switch (f.value) {
                .res_ref => |rr| try w.print(", ResRef=\"{s}\"", .{rr.slice()}),
                else => {},
            };
            if (ul.getField(s, "TemplateResRef")) |f| switch (f.value) {
                .res_ref => |rr| try w.print(", TemplateResRef=\"{s}\"", .{rr.slice()}),
                else => {},
            };
        } else {
            try w.writeAll(", <unresolved>");
        }
        try w.writeByte('\n');
    }
    if (handles.len > limit)
        try w.print("    ... ({d} more)\n", .{handles.len - limit});
}

// ============================================================================
// GIC file
// ============================================================================

pub const Comment = struct {
    /// Maximum body length emitted by `print` before ellipsis truncation.
    pub const PRINT_TRUNCATE: usize = 80;

    comment: []u8 = &.{},

    pub fn print(self: Comment, w: *std.Io.Writer) !void {
        if (self.comment.len <= PRINT_TRUNCATE) {
            try w.print("Comment{{ \"{s}\" }}", .{self.comment});
        } else {
            try w.print("Comment{{ \"{s}...\" ({d} bytes total) }}", .{
                self.comment[0..PRINT_TRUNCATE], self.comment.len,
            });
        }
    }
};

pub const GicFile = struct {
    pub const FILE_TYPE = "GIC ";

    arena: std.heap.ArenaAllocator,

    creatures: []Comment = &.{},
    doors: []Comment = &.{},
    encounters: []Comment = &.{},
    items: []Comment = &.{},
    placeables: []Comment = &.{},
    sounds: []Comment = &.{},
    stores: []Comment = &.{},
    triggers: []Comment = &.{},
    waypoints: []Comment = &.{},

    pub fn init(parent_alloc: std.mem.Allocator) GicFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *GicFile) void {
        self.arena.deinit();
    }

    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!GicFile {
        var self = GicFile.init(parent_alloc);
        errdefer self.deinit();

        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        const a = self.arena.allocator();
        const tl = &g.structs.items[0];

        self.creatures = try readCommentList(a, &g, tl, "Creature List");
        self.doors = try readCommentList(a, &g, tl, "Door List");
        self.encounters = try readCommentList(a, &g, tl, "Encounter List");
        self.items = try readCommentList(a, &g, tl, "List");
        self.placeables = try readCommentList(a, &g, tl, "Placeable List");
        self.sounds = try readCommentList(a, &g, tl, "SoundList");
        self.stores = try readCommentList(a, &g, tl, "StoreList");
        self.triggers = try readCommentList(a, &g, tl, "TriggerList");
        self.waypoints = try readCommentList(a, &g, tl, "WaypointList");

        return self;
    }

    pub fn serialize(self: *const GicFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();

        try writeCommentList(alloc, &g, "Creature List", self.creatures);
        try writeCommentList(alloc, &g, "Door List", self.doors);
        try writeCommentList(alloc, &g, "Encounter List", self.encounters);
        try writeCommentList(alloc, &g, "List", self.items);
        try writeCommentList(alloc, &g, "Placeable List", self.placeables);
        try writeCommentList(alloc, &g, "SoundList", self.sounds);
        try writeCommentList(alloc, &g, "StoreList", self.stores);
        try writeCommentList(alloc, &g, "TriggerList", self.triggers);
        try writeCommentList(alloc, &g, "WaypointList", self.waypoints);

        return g.serialize(alloc);
    }

    /// Pretty-print the GIC comment lists. `verbose=true` dumps every comment
    /// body; otherwise only the count + first three are shown per list.
    pub fn print(self: *const GicFile, w: *std.Io.Writer, verbose: bool) !void {
        try w.print("GicFile {{\n", .{});
        try printCommentList(w, "creatures", self.creatures, verbose);
        try printCommentList(w, "doors", self.doors, verbose);
        try printCommentList(w, "encounters", self.encounters, verbose);
        try printCommentList(w, "items", self.items, verbose);
        try printCommentList(w, "placeables", self.placeables, verbose);
        try printCommentList(w, "sounds", self.sounds, verbose);
        try printCommentList(w, "stores", self.stores, verbose);
        try printCommentList(w, "triggers", self.triggers, verbose);
        try printCommentList(w, "waypoints", self.waypoints, verbose);
        try w.writeAll("}\n");
    }
};

fn readCommentList(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    tl: *const gff.Struct,
    label: []const u8,
) Error![]Comment {
    const f = g.getField(tl, label) orelse return arena.alloc(Comment, 0);
    return switch (f.value) {
        .list => |handles| blk: {
            const out = try arena.alloc(Comment, handles.len);
            for (handles, 0..) |h, i| {
                if (h >= g.structs.items.len) return error.InvalidFormat;
                out[i] = .{ .comment = try optExoStringDupe(arena, g, &g.structs.items[h], "Comment") };
            }
            break :blk out;
        },
        else => error.WrongFieldType,
    };
}

fn writeCommentList(
    alloc: std.mem.Allocator,
    g: *gff.GffFile,
    label: []const u8,
    comments: []const Comment,
) !void {
    const handles = try alloc.alloc(u32, comments.len);
    for (comments, 0..) |c, i| {
        // GIC instance structs all share the same StructID as the corresponding
        // GIT list, but the schema is a single CExoString. The spec doesn't
        // pin a specific StructID for these wrappers; we use 0 by convention.
        const sidx = try g.addStruct(0);
        try g.addFieldToStruct(sidx, "Comment", .{ .exo_string = try alloc.dupe(u8, c.comment) });
        handles[i] = sidx;
    }
    try g.addFieldToStruct(0, label, .{ .list = handles });
}

// ============================================================================
// Cross-cutting helpers
// ============================================================================

/// Deep-clone an ExoLocString into a different allocator. Used by serialize()
/// to hand the value off to a fresh GffFile that owns its own allocations.
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

/// Emit one of GIT's instance-list fields. Deep-clones every referenced
/// struct from `src` (if any) into `dst`, then attaches a `.list` field at
/// `dst.structs[0]` whose entries are the new struct indices.
fn emitList(
    alloc: std.mem.Allocator,
    dst: *gff.GffFile,
    src_opt: ?*const gff.GffFile,
    label: []const u8,
    handles: []const u32,
) !void {
    const out = try alloc.alloc(u32, handles.len);
    errdefer alloc.free(out);
    if (src_opt) |src| {
        for (handles, 0..) |h, i| {
            if (h >= src.structs.items.len) return error.InvalidFormat;
            out[i] = try cloneStruct(alloc, dst, src, h);
        }
    } else {
        // No source GFF — handles are meaningless. Treat as empty.
        if (handles.len != 0) return error.InvalidFormat;
    }
    try dst.addFieldToStruct(0, label, .{ .list = out });
}

/// Deep-clone Struct `src_index` from `src` into `dst`. Returns the new index.
/// Recursively clones any Struct/List field values it references.
const CloneError = std.mem.Allocator.Error || error{InvalidFormat};

fn cloneStruct(
    alloc: std.mem.Allocator,
    dst: *gff.GffFile,
    src: *const gff.GffFile,
    src_index: usize,
) CloneError!u32 {
    const src_struct = src.structs.items[src_index];
    const new_idx = try dst.addStruct(src_struct.type_id);

    for (src_struct.field_indices) |fi| {
        const src_field = src.fields.items[fi];
        const lbl = src.labels.items[src_field.label_index];
        // Determine label length (null-padded to 16).
        var nlen: usize = 16;
        while (nlen > 0 and lbl[nlen - 1] == 0) : (nlen -= 1) {}
        const label = lbl[0..nlen];

        const new_value: gff.FieldValue = try cloneFieldValue(alloc, dst, src, src_field.value);
        try dst.addFieldToStruct(new_idx, label, new_value);
    }
    return new_idx;
}

fn cloneFieldValue(
    alloc: std.mem.Allocator,
    dst: *gff.GffFile,
    src: *const gff.GffFile,
    v: gff.FieldValue,
) CloneError!gff.FieldValue {
    return switch (v) {
        .byte, .char, .word, .short, .dword, .int, .float, .dword64, .int64, .double, .res_ref => v,
        .exo_string => |s| .{ .exo_string = try alloc.dupe(u8, s) },
        .void_data => |b| .{ .void_data = try alloc.dupe(u8, b) },
        .exo_loc_string => |loc| .{ .exo_loc_string = try cloneExoLoc(alloc, loc) },
        .@"struct" => |idx| .{ .@"struct" = try cloneStruct(alloc, dst, src, idx) },
        .list => |arr| blk: {
            const out = try alloc.alloc(u32, arr.len);
            errdefer alloc.free(out);
            for (arr, 0..) |sidx, i| out[i] = try cloneStruct(alloc, dst, src, sidx);
            break :blk .{ .list = out };
        },
    };
}

// ============================================================================
// Pretty-print helpers (shared across structs)
// ============================================================================

fn printExoLoc(w: *std.Io.Writer, loc: gff.ExoLocString) !void {
    try w.print("ExoLoc{{ ref={d}", .{loc.string_ref});
    if (loc.substrings.items.len == 0) {
        try w.writeAll(", <no substrings> }");
        return;
    }
    try w.print(", {d} substring(s)", .{loc.substrings.items.len});
    const first = loc.substrings.items[0];
    try w.print(", first[id={d}]=\"{s}\"", .{ first.string_id, first.text });
    try w.writeAll(" }");
}

fn printBgrColor(w: *std.Io.Writer, label: []const u8, v: u32) !void {
    try w.print("{s}=", .{label});
    try AreFile.rgbFromBgr(v).print(w);
}

fn printCommentList(w: *std.Io.Writer, label: []const u8, comments: []const Comment, verbose: bool) !void {
    try w.print("  {s:<11} = {d} comment(s)\n", .{ label, comments.len });
    const limit: usize = if (verbose) comments.len else @min(comments.len, 3);
    for (comments[0..limit], 0..) |c, i| {
        try w.print("    [{d}] ", .{i});
        try c.print(w);
        try w.writeByte('\n');
    }
    if (!verbose and comments.len > limit)
        try w.print("    ... ({d} more)\n", .{comments.len - limit});
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "ARE empty defaults round-trip" {
    const gpa = t.allocator;
    var a = AreFile.init(gpa);
    defer a.deinit();

    const bytes = try a.serialize(gpa);
    defer gpa.free(bytes);

    var b = try AreFile.parse(gpa, bytes);
    defer b.deinit();

    try t.expectEqual(@as(i32, 0), b.width);
    try t.expectEqual(@as(i32, -1), b.creator_id);
    try t.expectEqual(@as(u32, 1), b.version);
    try t.expectEqual(@as(usize, 0), b.tile_list.len);
}

test "ARE typed round-trip + byte-exact" {
    const gpa = t.allocator;
    var a = AreFile.init(gpa);
    defer a.deinit();

    a.width = 12;
    a.height = 8;
    a.flags = AreFile.FLAG_INTERIOR | AreFile.FLAG_NATURAL;
    a.day_night_cycle = 1;
    a.version = 7;
    a.tile_set = gff.ResRef.fromSlice("tdc01");
    a.on_enter = gff.ResRef.fromSlice("mod_on_enter");

    const arena = a.arena.allocator();
    a.tag = try arena.dupe(u8, "tutorial_town");
    a.comments = try arena.dupe(u8, "first area built");

    a.name = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    try a.name.substrings.append(arena, .{
        .string_id = 0,
        .text = try arena.dupe(u8, "Tutorial Town"),
    });

    const tiles = try arena.alloc(AreaTile, 4);
    for (tiles, 0..) |*tile, i| {
        tile.* = .{ .id = @intCast(10 + i), .orientation = @intCast(i % 4), .height = 0 };
    }
    a.tile_list = tiles;

    const buf1 = try a.serialize(gpa);
    defer gpa.free(buf1);

    var a2 = try AreFile.parse(gpa, buf1);
    defer a2.deinit();

    try t.expectEqual(@as(i32, 12), a2.width);
    try t.expectEqual(@as(i32, 8), a2.height);
    try t.expectEqual(AreFile.FLAG_INTERIOR | AreFile.FLAG_NATURAL, a2.flags);
    try t.expectEqual(@as(u8, 1), a2.day_night_cycle);
    try t.expectEqual(@as(u32, 7), a2.version);
    try t.expectEqualStrings("tdc01", a2.tile_set.slice());
    try t.expectEqualStrings("mod_on_enter", a2.on_enter.slice());
    try t.expectEqualStrings("tutorial_town", a2.tag);
    try t.expectEqualStrings("first area built", a2.comments);
    try t.expectEqual(@as(usize, 1), a2.name.substrings.items.len);
    try t.expectEqualStrings("Tutorial Town", a2.name.substrings.items[0].text);
    try t.expectEqual(@as(usize, 4), a2.tile_list.len);
    try t.expectEqual(@as(i32, 13), a2.tile_list[3].id);

    const buf2 = try a2.serialize(gpa);
    defer gpa.free(buf2);
    try t.expectEqualSlices(u8, buf1, buf2);
}

test "ARE BGR helpers" {
    const v = AreFile.bgrFromRgb(255, 128, 64);
    const rgb = AreFile.rgbFromBgr(v);
    try t.expectEqual(@as(u8, 255), rgb.r);
    try t.expectEqual(@as(u8, 128), rgb.g);
    try t.expectEqual(@as(u8, 64), rgb.b);
    // On-disk byte layout: R G B 0
    try t.expectEqual(@as(u32, 255 | (128 << 8) | (64 << 16)), v);
}

test "GIT empty + AreaProperties only" {
    const gpa = t.allocator;
    var g = GitFile.init(gpa);
    defer g.deinit();
    g.area_properties.music_day = 5;
    g.area_properties.env_audio = 2;

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = try GitFile.parse(gpa, bytes);
    defer g2.deinit();

    try t.expectEqual(@as(i32, 5), g2.area_properties.music_day);
    try t.expectEqual(@as(i32, 2), g2.area_properties.env_audio);
    try t.expectEqual(@as(usize, 0), g2.creatures.len);
}

test "GIT instance handles round-trip" {
    const gpa = t.allocator;

    // Build a GIT from scratch by directly constructing a GFF with 2 creatures
    // and 1 door, then serialize and parse via GitFile.
    var raw = try gff.GffFile.init(gpa, GitFile.FILE_TYPE.*);
    defer raw.deinit();

    // AreaProperties (required).
    const ap = try raw.addStruct(AreaProperties.STRUCT_ID);
    try raw.addFieldToStruct(ap, "MusicDay", .{ .int = 1 });
    try raw.addFieldToStruct(0, "AreaProperties", .{ .@"struct" = ap });

    // 2 creatures + 1 door.
    const c1 = try raw.addStruct(GitFile.StructIds.creature);
    try raw.addFieldToStruct(c1, "Tag", .{ .exo_string = try gpa.dupe(u8, "goblin01") });
    const c2 = try raw.addStruct(GitFile.StructIds.creature);
    try raw.addFieldToStruct(c2, "Tag", .{ .exo_string = try gpa.dupe(u8, "goblin02") });
    const d1 = try raw.addStruct(GitFile.StructIds.door);
    try raw.addFieldToStruct(d1, "Tag", .{ .exo_string = try gpa.dupe(u8, "exit_door") });

    const creatures = try gpa.alloc(u32, 2);
    creatures[0] = c1;
    creatures[1] = c2;
    try raw.addFieldToStruct(0, "Creature List", .{ .list = creatures });

    const doors = try gpa.alloc(u32, 1);
    doors[0] = d1;
    try raw.addFieldToStruct(0, "Door List", .{ .list = doors });

    const buf1 = try raw.serialize(gpa);
    defer gpa.free(buf1);

    var git = try GitFile.parse(gpa, buf1);
    defer git.deinit();

    try t.expectEqual(@as(usize, 2), git.creatures.len);
    try t.expectEqual(@as(usize, 1), git.doors.len);

    // Inspect a creature via the handle.
    const cs = git.getStruct(git.creatures[0]).?;
    const tag_field = git.underlying().?.getField(cs, "Tag").?;
    try t.expectEqualStrings("goblin01", tag_field.value.exo_string);

    // Round-trip must be byte-stable.
    const buf2 = try git.serialize(gpa);
    defer gpa.free(buf2);

    var git2 = try GitFile.parse(gpa, buf2);
    defer git2.deinit();
    const buf3 = try git2.serialize(gpa);
    defer gpa.free(buf3);
    try t.expectEqualSlices(u8, buf2, buf3);
}

test "GIT SaveGame fields" {
    const gpa = t.allocator;
    var g = GitFile.init(gpa);
    defer g.deinit();

    g.current_weather = .rain;
    g.weather_started = 1;
    const a = g.arena.allocator();
    g.area_effects = try a.alloc(u32, 0);
    g.var_table = try a.alloc(u32, 0);

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = try GitFile.parse(gpa, bytes);
    defer g2.deinit();

    try t.expectEqual(@as(?Weather, .rain), g2.current_weather);
    try t.expectEqual(@as(?u8, 1), g2.weather_started);
    try t.expect(g2.area_effects != null);
    try t.expect(g2.var_table != null);
}

test "GIC round-trip" {
    const gpa = t.allocator;
    var g = GicFile.init(gpa);
    defer g.deinit();

    const a = g.arena.allocator();
    const creatures = try a.alloc(Comment, 3);
    creatures[0] = .{ .comment = try a.dupe(u8, "first creature comment") };
    creatures[1] = .{ .comment = try a.dupe(u8, "") };
    creatures[2] = .{ .comment = try a.dupe(u8, "third one") };
    g.creatures = creatures;

    const doors = try a.alloc(Comment, 1);
    doors[0] = .{ .comment = try a.dupe(u8, "door comment") };
    g.doors = doors;

    const buf1 = try g.serialize(gpa);
    defer gpa.free(buf1);

    var g2 = try GicFile.parse(gpa, buf1);
    defer g2.deinit();

    try t.expectEqual(@as(usize, 3), g2.creatures.len);
    try t.expectEqualStrings("first creature comment", g2.creatures[0].comment);
    try t.expectEqualStrings("", g2.creatures[1].comment);
    try t.expectEqualStrings("third one", g2.creatures[2].comment);
    try t.expectEqual(@as(usize, 1), g2.doors.len);
    try t.expectEqualStrings("door comment", g2.doors[0].comment);

    const buf2 = try g2.serialize(gpa);
    defer gpa.free(buf2);
    try t.expectEqualSlices(u8, buf1, buf2);
}

test "wrong magic" {
    const gpa = t.allocator;
    var a = AreFile.init(gpa);
    defer a.deinit();
    const are_bytes = try a.serialize(gpa);
    defer gpa.free(are_bytes);

    try t.expectError(error.InvalidFileType, GitFile.parse(gpa, are_bytes));
    try t.expectError(error.InvalidFileType, GicFile.parse(gpa, are_bytes));
}

test "pretty-print smoke (AreaTile / AreFile / AreaProperties / GitFile / Comment / GicFile)" {
    const gpa = t.allocator;

    var buf: [4096]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);

    const tile: AreaTile = .{ .id = 42, .height = 1, .orientation = 2 };
    try tile.print(&aw);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "id=42") != null);

    var are = AreFile.init(gpa);
    defer are.deinit();
    are.width = 3;
    are.height = 4;
    are.flags = AreFile.FLAG_INTERIOR;
    aw = std.Io.Writer.fixed(&buf);
    try are.print(&aw, false);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "AreFile {") != null);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "interior=true") != null);

    aw = std.Io.Writer.fixed(&buf);
    const ap: AreaProperties = .{ .music_day = 7, .env_audio = 1 };
    try ap.print(&aw);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "day=7") != null);

    var git = GitFile.init(gpa);
    defer git.deinit();
    git.current_weather = .rain;
    aw = std.Io.Writer.fixed(&buf);
    try git.print(&aw);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "GitFile {") != null);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "current_weather = rain") != null);

    const c: Comment = .{ .comment = @constCast("hello") };
    aw = std.Io.Writer.fixed(&buf);
    try c.print(&aw);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "hello") != null);

    // Long-comment truncation
    var long_buf: [256]u8 = undefined;
    @memset(&long_buf, 'x');
    const long: Comment = .{ .comment = &long_buf };
    aw = std.Io.Writer.fixed(&buf);
    try long.print(&aw);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "...") != null);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "256 bytes total") != null);

    var gic = GicFile.init(gpa);
    defer gic.deinit();
    aw = std.Io.Writer.fixed(&buf);
    try gic.print(&aw, false);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "GicFile {") != null);

    // Rgb.print
    aw = std.Io.Writer.fixed(&buf);
    try (AreFile.Rgb{ .r = 255, .g = 128, .b = 64 }).print(&aw);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "rgb(255,128,64)") != null);
    try t.expect(std.mem.indexOf(u8, aw.buffered(), "#ff8040") != null);
}

test "GitFile.printInstances resolves Tag from underlying GFF" {
    const gpa = t.allocator;

    var raw = try gff.GffFile.init(gpa, GitFile.FILE_TYPE.*);
    defer raw.deinit();

    const ap = try raw.addStruct(AreaProperties.STRUCT_ID);
    try raw.addFieldToStruct(0, "AreaProperties", .{ .@"struct" = ap });

    const c1 = try raw.addStruct(GitFile.StructIds.creature);
    try raw.addFieldToStruct(c1, "Tag", .{ .exo_string = try gpa.dupe(u8, "goblin01") });
    try raw.addFieldToStruct(c1, "TemplateResRef", .{ .res_ref = gff.ResRef.fromSlice("g_goblin") });
    const creatures = try gpa.alloc(u32, 1);
    creatures[0] = c1;
    try raw.addFieldToStruct(0, "Creature List", .{ .list = creatures });

    const bytes = try raw.serialize(gpa);
    defer gpa.free(bytes);

    var git = try GitFile.parse(gpa, bytes);
    defer git.deinit();

    var buf: [2048]u8 = undefined;
    var aw = std.Io.Writer.fixed(&buf);
    try git.printInstances(&aw, 0);

    const out = aw.buffered();
    try t.expect(std.mem.indexOf(u8, out, "creatures") != null);
    try t.expect(std.mem.indexOf(u8, out, "Tag=\"goblin01\"") != null);
    try t.expect(std.mem.indexOf(u8, out, "TemplateResRef=\"g_goblin\"") != null);
}

test "GIT missing AreaProperties" {
    const gpa = t.allocator;

    // Build a "GIT " file that omits AreaProperties.
    var raw = try gff.GffFile.init(gpa, GitFile.FILE_TYPE.*);
    defer raw.deinit();
    try raw.addFieldToStruct(0, "Creature List", .{ .list = try gpa.alloc(u32, 0) });

    const bytes = try raw.serialize(gpa);
    defer gpa.free(bytes);

    try t.expectError(error.MissingRequiredField, GitFile.parse(gpa, bytes));
}
