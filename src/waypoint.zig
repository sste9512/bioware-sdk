//! Bioware Aurora Waypoint (UTW) file reader and writer.
//!
//! Waypoints are simple scripting anchors that can display map notes to
//! the player.  Stored as GFF V3.2 files with FileType "UTW " for blueprints;
//! embedded as WaypointStructs (StructID 5) in module GIT files for instances.
//!
//! Spec sections:
//!   2.1.1 Common fields (all variants)
//!   2.1.2 Blueprint-only fields (Comment, PaletteID, TemplateResRef)
//!   2.1.3 Instance-only fields (position, orientation, TemplateResRef)
//!
//! Memory: UtwFile owns an ArenaAllocator that backs every string, slice, and
//! loc-string copy. Call deinit() once to free everything.
const std = @import("std");
const gff = @import("gff.zig");

pub const FILE_TYPE = "UTW ";

// ============================================================================
// Errors / variant
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

/// Spec variant — selects which optional field blocks are present.
pub const WaypointVariant = enum {
    /// Standalone UTW blueprint file. Spec 2.1.1 + 2.1.2.
    blueprint,
    /// Waypoint instance inside a GIT file (StructID 5). Spec 2.1.1 + 2.1.3.
    instance,
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
// WaypointStruct
// ============================================================================

/// Typed GFF struct for a Waypoint object.  Used directly when reading/writing
/// waypoints embedded in GIT files; wrapped by UtwFile for standalone blueprints.
pub const WaypointStruct = struct {
    // ---- 2.1.1 common -------------------------------------------------------

    /// Index into waypoint.2da; controls toolset model only.
    appearance:       u8             = 0,
    /// Toolset-only localized description.
    description:      gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// 1 if the waypoint has a map note.
    has_map_note:     u8             = 0,
    /// Unused per spec — always blank.
    linked_to:        []u8           = &.{},
    /// Display name in the Waypoint palette.
    localized_name:   gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// Text shown when player mouses over the waypoint in the minimap.
    map_note:         gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// 1 if the map note is visible in game.
    map_note_enabled: u8             = 0,
    /// Tag (≤32 characters).
    tag:              []u8           = &.{},

    // ---- 2.1.2 blueprint-only -----------------------------------------------

    /// Module designer comment. null = field absent.
    comment:          ?[]u8          = null,
    /// Palette node ID. null = field absent.
    palette_id:       ?u8            = null,
    /// Blueprint: same as UTW filename. Instance: source blueprint ResRef.
    template_res_ref: gff.ResRef     = .{ .len = 0, .data = [_]u8{0} ** 16 },

    // ---- 2.1.3 instance-only ------------------------------------------------

    /// cos(bearing) component of facing direction. null = not present (blueprint).
    x_orientation: ?f32 = null,
    /// sin(bearing) component of facing direction. null = not present (blueprint).
    y_orientation: ?f32 = null,
    /// World x coordinate. null = not present (blueprint).
    x_position: ?f32 = null,
    /// World y coordinate.
    y_position: ?f32 = null,
    /// World z coordinate.
    z_position: ?f32 = null,

    // -------------------------------------------------------------------------

    /// Decode a WaypointStruct from a GFF struct node.
    /// All strings and loc-strings are deep-copied into `arena`.
    pub fn fromGffStruct(
        arena:   std.mem.Allocator,
        g:       *const gff.GffFile,
        s:       *const gff.Struct,
        variant: WaypointVariant,
    ) Error!WaypointStruct {
        var out: WaypointStruct = .{};

        // Common fields.
        out.appearance       = try optByte(g, s, "Appearance",      0);
        out.description      = try optExoLocDupe(arena, g, s, "Description");
        out.has_map_note     = try optByte(g, s, "HasMapNote",       0);
        out.linked_to        = try optExoStringDupe(arena, g, s, "LinkedTo");
        out.localized_name   = try optExoLocDupe(arena, g, s, "LocalizedName");
        out.map_note         = try optExoLocDupe(arena, g, s, "MapNote");
        out.map_note_enabled = try optByte(g, s, "MapNoteEnabled",   0);
        out.tag              = try optExoStringDupe(arena, g, s, "Tag");

        switch (variant) {
            .blueprint => {
                out.comment          = try optExoStringDupeOrNull(arena, g, s, "Comment");
                out.palette_id       = try optByteOrNull(g, s, "PaletteID");
                out.template_res_ref = try optResRef(g, s, "TemplateResRef");
            },
            .instance => {
                out.template_res_ref = try optResRef(g, s, "TemplateResRef");
                out.x_orientation    = try optFloat(g, s, "XOrientation", 1);
                out.y_orientation    = try optFloat(g, s, "YOrientation", 0);
                out.x_position       = try optFloat(g, s, "XPosition",    0);
                out.y_position       = try optFloat(g, s, "YPosition",    0);
                out.z_position       = try optFloat(g, s, "ZPosition",    0);
            },
        }
        return out;
    }

    /// Emit all fields into the GFF struct at `struct_idx` inside `g`.
    pub fn writeIntoGff(
        self:       *const WaypointStruct,
        g:          *gff.GffFile,
        struct_idx: u32,
        variant:    WaypointVariant,
    ) !void {
        // Common fields.
        try g.addFieldToStruct(struct_idx, "Appearance",     .{ .byte = self.appearance });
        try g.addFieldToStruct(struct_idx, "Description",    .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.description),
        });
        try g.addFieldToStruct(struct_idx, "HasMapNote",     .{ .byte = self.has_map_note });
        try g.addFieldToStruct(struct_idx, "LinkedTo",       .{ .exo_string = try g.allocator.dupe(u8, self.linked_to) });
        try g.addFieldToStruct(struct_idx, "LocalizedName",  .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.localized_name),
        });
        try g.addFieldToStruct(struct_idx, "MapNote",        .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.map_note),
        });
        try g.addFieldToStruct(struct_idx, "MapNoteEnabled", .{ .byte = self.map_note_enabled });
        try g.addFieldToStruct(struct_idx, "Tag",            .{ .exo_string = try g.allocator.dupe(u8, self.tag) });

        switch (variant) {
            .blueprint => {
                if (self.comment) |c|
                    try g.addFieldToStruct(struct_idx, "Comment",         .{ .exo_string = try g.allocator.dupe(u8, c) });
                if (self.palette_id) |v|
                    try g.addFieldToStruct(struct_idx, "PaletteID",       .{ .byte = v });
                try g.addFieldToStruct(struct_idx, "TemplateResRef",      .{ .res_ref = self.template_res_ref });
            },
            .instance => {
                try g.addFieldToStruct(struct_idx, "TemplateResRef",  .{ .res_ref = self.template_res_ref });
                try g.addFieldToStruct(struct_idx, "XOrientation",    .{ .float = self.x_orientation orelse 1 });
                try g.addFieldToStruct(struct_idx, "YOrientation",    .{ .float = self.y_orientation orelse 0 });
                try g.addFieldToStruct(struct_idx, "XPosition",       .{ .float = self.x_position    orelse 0 });
                try g.addFieldToStruct(struct_idx, "YPosition",       .{ .float = self.y_position    orelse 0 });
                try g.addFieldToStruct(struct_idx, "ZPosition",       .{ .float = self.z_position    orelse 0 });
            },
        }
    }
};

// ============================================================================
// UtwFile — standalone UTW blueprint container
// ============================================================================

/// Standalone waypoint blueprint.  Wraps a `.blueprint` WaypointStruct
/// together with the arena that owns its string/loc-string data.
///
/// Example:
/// ```zig
/// var utw = try UtwFile.parse(gpa, bytes);
/// defer utw.deinit();
/// utw.waypoint.has_map_note = 1;
/// const out = try utw.serialize(gpa);
/// defer gpa.free(out);
/// ```
pub const UtwFile = struct {
    arena:    std.heap.ArenaAllocator,
    waypoint: WaypointStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UtwFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UtwFile) void {
        self.arena.deinit();
    }

    /// Parse a UTW byte stream. Verifies the `"UTW "` magic and decodes
    /// the top-level struct as a blueprint waypoint.
    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtwFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = UtwFile.init(parent_alloc);
        errdefer out.deinit();
        out.waypoint = try WaypointStruct.fromGffStruct(
            out.arena.allocator(),
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    /// Encode this waypoint (as a blueprint) into a UTW byte stream.
    /// Caller owns the returned slice and must free it with `alloc`.
    pub fn serialize(self: *const UtwFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.waypoint.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty UTW round-trip" {
    const gpa = t.allocator;
    var utw = UtwFile.init(gpa);
    defer utw.deinit();

    const bytes = try utw.serialize(gpa);
    defer gpa.free(bytes);

    var utw2 = try UtwFile.parse(gpa, bytes);
    defer utw2.deinit();

    const w = &utw2.waypoint;
    try t.expectEqual(@as(u8, 0), w.appearance);
    try t.expectEqual(@as(u8, 0), w.has_map_note);
    try t.expectEqual(@as(u8, 0), w.map_note_enabled);
    try t.expectEqualStrings("", w.tag);
    try t.expect(w.comment == null);
    try t.expectEqual(@as(?u8, null), w.palette_id);
}

test "UTW common scalar fields round-trip" {
    const gpa = t.allocator;
    var utw = UtwFile.init(gpa);
    defer utw.deinit();

    const a = utw.arena.allocator();
    utw.waypoint.appearance       = 3;
    utw.waypoint.has_map_note     = 1;
    utw.waypoint.map_note_enabled = 1;
    utw.waypoint.tag              = try a.dupe(u8, "WP_BridgeNorth");
    utw.waypoint.template_res_ref = gff.ResRef.fromSlice("wp_bridge_n");

    const bytes = try utw.serialize(gpa);
    defer gpa.free(bytes);

    var utw2 = try UtwFile.parse(gpa, bytes);
    defer utw2.deinit();

    const w = &utw2.waypoint;
    try t.expectEqual(@as(u8, 3),  w.appearance);
    try t.expectEqual(@as(u8, 1),  w.has_map_note);
    try t.expectEqual(@as(u8, 1),  w.map_note_enabled);
    try t.expectEqualStrings("WP_BridgeNorth", w.tag);
    try t.expectEqualStrings("wp_bridge_n", w.template_res_ref.slice());
}

test "UTW LocalizedName / Description / MapNote round-trip" {
    const gpa = t.allocator;
    var utw = UtwFile.init(gpa);
    defer utw.deinit();

    const a = utw.arena.allocator();

    utw.waypoint.localized_name.string_ref = 100;
    try utw.waypoint.localized_name.substrings.append(a, .{
        .string_id = 0,
        .text      = try a.dupe(u8, "North Bridge"),
    });

    utw.waypoint.description.string_ref = 200;
    try utw.waypoint.description.substrings.append(a, .{
        .string_id = 0,
        .text      = try a.dupe(u8, "Leads to the northern district"),
    });

    utw.waypoint.map_note.string_ref = 300;
    try utw.waypoint.map_note.substrings.append(a, .{
        .string_id = 0,
        .text      = try a.dupe(u8, "North Bridge"),
    });

    const bytes = try utw.serialize(gpa);
    defer gpa.free(bytes);

    var utw2 = try UtwFile.parse(gpa, bytes);
    defer utw2.deinit();

    const w = &utw2.waypoint;
    try t.expectEqual(@as(u32, 100), w.localized_name.string_ref);
    try t.expectEqual(@as(usize, 1), w.localized_name.substrings.items.len);
    try t.expectEqualStrings("North Bridge", w.localized_name.substrings.items[0].text);

    try t.expectEqual(@as(u32, 200), w.description.string_ref);
    try t.expectEqualStrings("Leads to the northern district", w.description.substrings.items[0].text);

    try t.expectEqual(@as(u32, 300), w.map_note.string_ref);
    try t.expectEqualStrings("North Bridge", w.map_note.substrings.items[0].text);
}

test "UTW blueprint-only fields round-trip" {
    const gpa = t.allocator;
    var utw = UtwFile.init(gpa);
    defer utw.deinit();

    const a = utw.arena.allocator();
    utw.waypoint.comment          = try a.dupe(u8, "Patrol route anchor");
    utw.waypoint.palette_id       = 5;
    utw.waypoint.template_res_ref = gff.ResRef.fromSlice("wp_patrol01");

    const bytes = try utw.serialize(gpa);
    defer gpa.free(bytes);

    var utw2 = try UtwFile.parse(gpa, bytes);
    defer utw2.deinit();

    try t.expectEqualStrings("Patrol route anchor", utw2.waypoint.comment.?);
    try t.expectEqual(@as(?u8, 5), utw2.waypoint.palette_id);
    try t.expectEqualStrings("wp_patrol01", utw2.waypoint.template_res_ref.slice());
}

test "WaypointStruct instance variant round-trip" {
    const gpa = t.allocator;

    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var wp: WaypointStruct = .{};
    wp.tag              = try a.dupe(u8, "WP_Guard01");
    wp.template_res_ref = gff.ResRef.fromSlice("wp_guard");
    wp.x_orientation    = 0.7071; // ~45 degrees
    wp.y_orientation    = 0.7071;
    wp.x_position       = 15.5;
    wp.y_position       = 22.0;
    wp.z_position       = 1.0;

    const sidx = try g.addStruct(5); // StructID 5 per spec Table 2.1.3
    try wp.writeIntoGff(&g, sidx, .instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try WaypointStruct.fromGffStruct(
        arena2.allocator(), &g, &g.structs.items[sidx], .instance,
    );

    try t.expectEqualStrings("WP_Guard01", parsed.tag);
    try t.expectEqualStrings("wp_guard", parsed.template_res_ref.slice());
    try t.expectApproxEqAbs(@as(f32, 0.7071), parsed.x_orientation.?, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.7071), parsed.y_orientation.?, 0.001);
    try t.expectApproxEqAbs(@as(f32, 15.5),   parsed.x_position.?,    0.0001);
    try t.expectApproxEqAbs(@as(f32, 22.0),   parsed.y_position.?,    0.0001);
    try t.expectApproxEqAbs(@as(f32, 1.0),    parsed.z_position.?,    0.0001);
}

test "UTW map note presence preserved" {
    const gpa = t.allocator;

    // no map note
    {
        var utw = UtwFile.init(gpa);
        defer utw.deinit();
        utw.waypoint.has_map_note     = 0;
        utw.waypoint.map_note_enabled = 0;

        const bytes = try utw.serialize(gpa);
        defer gpa.free(bytes);
        var utw2 = try UtwFile.parse(gpa, bytes);
        defer utw2.deinit();
        try t.expectEqual(@as(u8, 0), utw2.waypoint.has_map_note);
        try t.expectEqual(@as(u8, 0), utw2.waypoint.map_note_enabled);
    }

    // with map note
    {
        var utw = UtwFile.init(gpa);
        defer utw.deinit();
        utw.waypoint.has_map_note     = 1;
        utw.waypoint.map_note_enabled = 1;

        const bytes = try utw.serialize(gpa);
        defer gpa.free(bytes);
        var utw2 = try UtwFile.parse(gpa, bytes);
        defer utw2.deinit();
        try t.expectEqual(@as(u8, 1), utw2.waypoint.has_map_note);
        try t.expectEqual(@as(u8, 1), utw2.waypoint.map_note_enabled);
    }
}

test "UTW byte-exact double serialize" {
    const gpa = t.allocator;
    var utw = UtwFile.init(gpa);
    defer utw.deinit();

    const a = utw.arena.allocator();
    utw.waypoint.appearance       = 2;
    utw.waypoint.has_map_note     = 1;
    utw.waypoint.map_note_enabled = 1;
    utw.waypoint.tag              = try a.dupe(u8, "WP_MapNote");
    utw.waypoint.template_res_ref = gff.ResRef.fromSlice("wp_mapnote01");
    utw.waypoint.comment          = try a.dupe(u8, "Shows cave entrance");
    utw.waypoint.palette_id       = 3;

    try utw.waypoint.map_note.substrings.append(a, .{
        .string_id = 0,
        .text      = try a.dupe(u8, "Cave Entrance"),
    });

    const bytes1 = try utw.serialize(gpa);
    defer gpa.free(bytes1);

    var utw2 = try UtwFile.parse(gpa, bytes1);
    defer utw2.deinit();
    const bytes2 = try utw2.serialize(gpa);
    defer gpa.free(bytes2);

    try t.expectEqualSlices(u8, bytes1, bytes2);
}

test "UTW wrong magic rejected" {
    const gpa = t.allocator;
    var utw = UtwFile.init(gpa);
    defer utw.deinit();

    const bytes = try utw.serialize(gpa);
    defer gpa.free(bytes);

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[0..4], "UTX ");

    try t.expectError(error.InvalidFileType, UtwFile.parse(gpa, mut));
}
