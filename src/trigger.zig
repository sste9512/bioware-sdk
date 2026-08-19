//! Bioware Aurora Trigger (UTT) file reader and writer.
//!
//! Triggers define polygonal regions for area transitions, traps, and scripted
//! events. Stored as GFF V3.2 files with FileType "UTT " for blueprints;
//! embedded as TriggerStructs (StructID 1) in module GIT files for instances.
//!
//! Spec sections:
//!   2.1   Common fields (all variants)
//!   2.2   Blueprint-only fields (Comment, PaletteID)
//!   2.3   Instance-only fields (Geometry, position, orientation)
//!
//! Memory: UttFile owns an ArenaAllocator that backs every string, slice, and
//! loc-string copy. Call deinit() once to free everything.
const std = @import("std");
const gff = @import("gff.zig");

pub const FILE_TYPE = "UTT ";

// ============================================================================
// Errors / variant
// ============================================================================

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

/// Spec variant — selects which optional field blocks are present.
pub const TriggerVariant = enum {
    /// Standalone UTT blueprint file. Spec 2.1 + 2.2.
    blueprint,
    /// Trigger instance inside a GIT file (StructID 1). Spec 2.1 + 2.3.
    instance,
};

// ============================================================================
// Sub-struct
// ============================================================================

/// Geometry vertex — spec Table 2.3.2, StructID 3.
/// GFF field names are PointX/PointY/PointZ (not X/Y/Z).
/// Coordinates are relative to the trigger's own position.
pub const TriggerPoint = struct {
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
// TriggerStruct
// ============================================================================

/// Typed GFF struct for a Trigger object.  Use directly for GIT-embedded
/// instances; wrap with UttFile for standalone blueprints.
pub const TriggerStruct = struct {
    // ---- 2.1 common ---------------------------------------------------------

    /// Unused area-transition key removal flag.
    auto_remove_key: u8 = 0,
    /// Index into cursors.2da.
    cursor: u8 = 0,
    /// Disarm DC for trap triggers.
    disarm_dc: u8 = 0,
    /// Faction ID (Faction.fac) — trap fires only for hostile factions.
    faction: u32 = 0,
    /// Height in metres of the in-game highlight effect.
    highlight_height: f32 = 0,
    /// Unused area-transition key tag.
    key_name: []u8 = &.{},
    /// Destination tag for area transitions.
    linked_to: []u8 = &.{},
    /// 0=none, 1=links to Door, 2=links to Waypoint.
    linked_to_flags: u8 = 0,
    /// loadscreens.2da index for area transitions.
    load_screen_id: u16 = 0,
    /// Toolset palette name; not shown in game.
    localized_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    on_click: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_disarm: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    on_trap_triggered: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// portraits.2da index.
    portrait_id: u16 = 0,
    script_heartbeat: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    script_on_enter: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    script_on_exit: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    script_user_define: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Tag (≤32 characters).
    tag: []u8 = &.{},
    /// Blueprint: same as UTT filename. Instance: source blueprint ResRef.
    template_res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    trap_detectable: u8 = 0,
    trap_detect_dc: u8 = 0,
    trap_disarmable: u8 = 0,
    trap_flag: u8 = 0,
    trap_one_shot: u8 = 0,
    /// traps.2da index.
    trap_type: u8 = 0,
    /// 0=Generic, 1=Area Transition, 2=Trap.  GFF label is "Type", type INT.
    trigger_type: i32 = 0,

    // ---- 2.2 blueprint-only -------------------------------------------------

    /// Module designer comment. null = field absent.
    comment: ?[]u8 = null,
    /// Palette node ID. null = field absent.
    palette_id: ?u8 = null,

    // ---- 2.3 instance-only --------------------------------------------------

    /// Polygon vertices (relative to trigger position).
    geometry: []TriggerPoint = &.{},
    /// X component of orientation — spec says should always be 0.
    x_orientation: ?f32 = null,
    /// Y component of orientation — spec says should always be 0.
    y_orientation: ?f32 = null,
    /// World x position. null = not present (blueprint).
    x_position: ?f32 = null,
    y_position: ?f32 = null,
    z_position: ?f32 = null,

    // -------------------------------------------------------------------------

    /// Decode a TriggerStruct from a GFF struct node.
    /// All strings and loc-strings are deep-copied into `arena`.
    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: TriggerVariant,
    ) Error!TriggerStruct {
        var out: TriggerStruct = .{};

        // Common fields.
        out.auto_remove_key = try optByte(g, s, "AutoRemoveKey", 0);
        out.cursor = try optByte(g, s, "Cursor", 0);
        out.disarm_dc = try optByte(g, s, "DisarmDC", 0);
        out.faction = try optDword(g, s, "Faction", 0);
        out.highlight_height = try optFloat(g, s, "HighlightHeight", 0);
        out.key_name = try optExoStringDupe(arena, g, s, "KeyName");
        out.linked_to = try optExoStringDupe(arena, g, s, "LinkedTo");
        out.linked_to_flags = try optByte(g, s, "LinkedToFlags", 0);
        out.load_screen_id = try optWord(g, s, "LoadScreenID", 0);
        out.localized_name = try optExoLocDupe(arena, g, s, "LocalizedName");
        out.on_click = try optResRef(g, s, "OnClick");
        out.on_disarm = try optResRef(g, s, "OnDisarm");
        out.on_trap_triggered = try optResRef(g, s, "OnTrapTriggered");
        out.portrait_id = try optWord(g, s, "PortraitId", 0);
        out.script_heartbeat = try optResRef(g, s, "ScriptHeartbeat");
        out.script_on_enter = try optResRef(g, s, "ScriptOnEnter");
        out.script_on_exit = try optResRef(g, s, "ScriptOnExit");
        out.script_user_define = try optResRef(g, s, "ScriptUserDefine");
        out.tag = try optExoStringDupe(arena, g, s, "Tag");
        out.template_res_ref = try optResRef(g, s, "TemplateResRef");
        out.trap_detectable = try optByte(g, s, "TrapDetectable", 0);
        out.trap_detect_dc = try optByte(g, s, "TrapDetectDC", 0);
        out.trap_disarmable = try optByte(g, s, "TrapDisarmable", 0);
        out.trap_flag = try optByte(g, s, "TrapFlag", 0);
        out.trap_one_shot = try optByte(g, s, "TrapOneShot", 0);
        out.trap_type = try optByte(g, s, "TrapType", 0);
        out.trigger_type = try optInt(g, s, "Type", 0);

        switch (variant) {
            .blueprint => {
                out.comment = try optExoStringDupeOrNull(arena, g, s, "Comment");
                out.palette_id = try optByteOrNull(g, s, "PaletteID");
            },
            .instance => {
                out.geometry = try parseGeometry(arena, g, s);
                out.x_orientation = try optFloat(g, s, "XOrientation", 0);
                out.y_orientation = try optFloat(g, s, "YOrientation", 0);
                out.x_position = try optFloat(g, s, "XPosition", 0);
                out.y_position = try optFloat(g, s, "YPosition", 0);
                out.z_position = try optFloat(g, s, "ZPosition", 0);
            },
        }
        return out;
    }

    /// Emit all fields into the GFF struct at `struct_idx` inside `g`.
    pub fn writeIntoGff(
        self: *const TriggerStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: TriggerVariant,
    ) !void {
        try g.addFieldToStruct(struct_idx, "AutoRemoveKey", .{ .byte = self.auto_remove_key });
        try g.addFieldToStruct(struct_idx, "Cursor", .{ .byte = self.cursor });
        try g.addFieldToStruct(struct_idx, "DisarmDC", .{ .byte = self.disarm_dc });
        try g.addFieldToStruct(struct_idx, "Faction", .{ .dword = self.faction });
        try g.addFieldToStruct(struct_idx, "HighlightHeight", .{ .float = self.highlight_height });
        try g.addFieldToStruct(struct_idx, "KeyName", .{ .exo_string = try g.allocator.dupe(u8, self.key_name) });
        try g.addFieldToStruct(struct_idx, "LinkedTo", .{ .exo_string = try g.allocator.dupe(u8, self.linked_to) });
        try g.addFieldToStruct(struct_idx, "LinkedToFlags", .{ .byte = self.linked_to_flags });
        try g.addFieldToStruct(struct_idx, "LoadScreenID", .{ .word = self.load_screen_id });
        try g.addFieldToStruct(struct_idx, "LocalizedName", .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.localized_name),
        });
        try g.addFieldToStruct(struct_idx, "OnClick", .{ .res_ref = self.on_click });
        try g.addFieldToStruct(struct_idx, "OnDisarm", .{ .res_ref = self.on_disarm });
        try g.addFieldToStruct(struct_idx, "OnTrapTriggered", .{ .res_ref = self.on_trap_triggered });
        try g.addFieldToStruct(struct_idx, "PortraitId", .{ .word = self.portrait_id });
        try g.addFieldToStruct(struct_idx, "ScriptHeartbeat", .{ .res_ref = self.script_heartbeat });
        try g.addFieldToStruct(struct_idx, "ScriptOnEnter", .{ .res_ref = self.script_on_enter });
        try g.addFieldToStruct(struct_idx, "ScriptOnExit", .{ .res_ref = self.script_on_exit });
        try g.addFieldToStruct(struct_idx, "ScriptUserDefine", .{ .res_ref = self.script_user_define });
        try g.addFieldToStruct(struct_idx, "Tag", .{ .exo_string = try g.allocator.dupe(u8, self.tag) });
        try g.addFieldToStruct(struct_idx, "TemplateResRef", .{ .res_ref = self.template_res_ref });
        try g.addFieldToStruct(struct_idx, "TrapDetectable", .{ .byte = self.trap_detectable });
        try g.addFieldToStruct(struct_idx, "TrapDetectDC", .{ .byte = self.trap_detect_dc });
        try g.addFieldToStruct(struct_idx, "TrapDisarmable", .{ .byte = self.trap_disarmable });
        try g.addFieldToStruct(struct_idx, "TrapFlag", .{ .byte = self.trap_flag });
        try g.addFieldToStruct(struct_idx, "TrapOneShot", .{ .byte = self.trap_one_shot });
        try g.addFieldToStruct(struct_idx, "TrapType", .{ .byte = self.trap_type });
        try g.addFieldToStruct(struct_idx, "Type", .{ .int = self.trigger_type });

        switch (variant) {
            .blueprint => {
                if (self.comment) |c|
                    try g.addFieldToStruct(struct_idx, "Comment", .{ .exo_string = try g.allocator.dupe(u8, c) });
                if (self.palette_id) |v|
                    try g.addFieldToStruct(struct_idx, "PaletteID", .{ .byte = v });
            },
            .instance => {
                try writeGeometry(g, struct_idx, self.geometry);
                try g.addFieldToStruct(struct_idx, "XOrientation", .{ .float = self.x_orientation orelse 0 });
                try g.addFieldToStruct(struct_idx, "YOrientation", .{ .float = self.y_orientation orelse 0 });
                try g.addFieldToStruct(struct_idx, "XPosition", .{ .float = self.x_position orelse 0 });
                try g.addFieldToStruct(struct_idx, "YPosition", .{ .float = self.y_position orelse 0 });
                try g.addFieldToStruct(struct_idx, "ZPosition", .{ .float = self.z_position orelse 0 });
            },
        }
    }
};

// ============================================================================
// Geometry helpers
// ============================================================================

fn parseGeometry(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
) Error![]TriggerPoint {
    const f = g.getField(s, "Geometry") orelse return arena.alloc(TriggerPoint, 0);
    const arr = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(TriggerPoint, arr.len);
    for (arr, 0..) |idx, i| {
        const ps = &g.structs.items[idx];
        out[i] = .{
            .x = try optFloat(g, ps, "PointX", 0),
            .y = try optFloat(g, ps, "PointY", 0),
            .z = try optFloat(g, ps, "PointZ", 0),
        };
    }
    return out;
}

fn writeGeometry(g: *gff.GffFile, parent_idx: u32, points: []const TriggerPoint) !void {
    if (points.len == 0) return;
    const arr = try g.allocator.alloc(u32, points.len);
    errdefer g.allocator.free(arr);
    for (points, 0..) |p, i| {
        const sidx = try g.addStruct(3); // StructID 3 per spec Table 2.3.2
        try g.addFieldToStruct(sidx, "PointX", .{ .float = p.x });
        try g.addFieldToStruct(sidx, "PointY", .{ .float = p.y });
        try g.addFieldToStruct(sidx, "PointZ", .{ .float = p.z });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, "Geometry", .{ .list = arr });
}

// ============================================================================
// UttFile — standalone UTT blueprint container
// ============================================================================

/// Standalone trigger blueprint.  Wraps a `.blueprint` TriggerStruct together
/// with the arena that owns its string/loc-string data.
///
/// Example:
/// ```zig
/// var utt = try UttFile.parse(gpa, bytes);
/// defer utt.deinit();
/// utt.trigger.trigger_type = 1; // Area Transition
/// const out = try utt.serialize(gpa);
/// defer gpa.free(out);
/// ```
pub const UttFile = struct {
    arena: std.heap.ArenaAllocator,
    trigger: TriggerStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UttFile {
        return .{ .arena = std.heap.ArenaAllocator.init(parent_alloc) };
    }

    pub fn deinit(self: *UttFile) void {
        self.arena.deinit();
    }

    /// Parse a UTT byte stream. Verifies the `"UTT "` magic and decodes
    /// the top-level struct as a blueprint trigger.
    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UttFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = UttFile.init(parent_alloc);
        errdefer out.deinit();
        out.trigger = try TriggerStruct.fromGffStruct(
            out.arena.allocator(),
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    /// Encode this trigger (as a blueprint) into a UTT byte stream.
    /// Caller owns the returned slice and must free it with `alloc`.
    pub fn serialize(self: *const UttFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.trigger.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty UTT round-trip" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    const bytes = try utt.serialize(gpa);
    defer gpa.free(bytes);

    var utt2 = try UttFile.parse(gpa, bytes);
    defer utt2.deinit();

    const tr = &utt2.trigger;
    try t.expectEqual(@as(i32, 0), tr.trigger_type);
    try t.expectEqual(@as(u8, 0), tr.trap_flag);
    try t.expectEqual(@as(u8, 0), tr.cursor);
    try t.expectEqual(@as(u32, 0), tr.faction);
    try t.expect(tr.comment == null);
    try t.expectEqual(@as(?u8, null), tr.palette_id);
}

test "UTT common scalar fields round-trip" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    const a = utt.arena.allocator();
    utt.trigger.trigger_type = 2; // Trap
    utt.trigger.trap_flag = 1;
    utt.trigger.trap_detectable = 1;
    utt.trigger.trap_detect_dc = 15;
    utt.trigger.trap_disarmable = 1;
    utt.trigger.disarm_dc = 20;
    utt.trigger.trap_one_shot = 0;
    utt.trigger.trap_type = 3;
    utt.trigger.cursor = 1;
    utt.trigger.faction = 5;
    utt.trigger.highlight_height = 2.5;
    utt.trigger.linked_to_flags = 0;
    utt.trigger.load_screen_id = 12;
    utt.trigger.portrait_id = 7;
    utt.trigger.auto_remove_key = 0;
    utt.trigger.tag = try a.dupe(u8, "TrapBridge01");
    utt.trigger.template_res_ref = gff.ResRef.fromSlice("trapbridge01");
    utt.trigger.linked_to = try a.dupe(u8, "WP_Dest");

    const bytes = try utt.serialize(gpa);
    defer gpa.free(bytes);

    var utt2 = try UttFile.parse(gpa, bytes);
    defer utt2.deinit();

    const tr = &utt2.trigger;
    try t.expectEqual(@as(i32, 2), tr.trigger_type);
    try t.expectEqual(@as(u8, 1), tr.trap_flag);
    try t.expectEqual(@as(u8, 1), tr.trap_detectable);
    try t.expectEqual(@as(u8, 15), tr.trap_detect_dc);
    try t.expectEqual(@as(u8, 1), tr.trap_disarmable);
    try t.expectEqual(@as(u8, 20), tr.disarm_dc);
    try t.expectEqual(@as(u8, 3), tr.trap_type);
    try t.expectEqual(@as(u8, 1), tr.cursor);
    try t.expectEqual(@as(u32, 5), tr.faction);
    try t.expectApproxEqAbs(@as(f32, 2.5), tr.highlight_height, 0.0001);
    try t.expectEqual(@as(u16, 12), tr.load_screen_id);
    try t.expectEqual(@as(u16, 7), tr.portrait_id);
    try t.expectEqualStrings("TrapBridge01", tr.tag);
    try t.expectEqualStrings("trapbridge01", tr.template_res_ref.slice());
    try t.expectEqualStrings("WP_Dest", tr.linked_to);
}

test "UTT script ResRef fields round-trip" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    utt.trigger.on_click = gff.ResRef.fromSlice("trig_click");
    utt.trigger.on_disarm = gff.ResRef.fromSlice("trig_disarm");
    utt.trigger.on_trap_triggered = gff.ResRef.fromSlice("trig_trap");
    utt.trigger.script_heartbeat = gff.ResRef.fromSlice("trig_hb");
    utt.trigger.script_on_enter = gff.ResRef.fromSlice("trig_enter");
    utt.trigger.script_on_exit = gff.ResRef.fromSlice("trig_exit");
    utt.trigger.script_user_define = gff.ResRef.fromSlice("trig_udef");

    const bytes = try utt.serialize(gpa);
    defer gpa.free(bytes);

    var utt2 = try UttFile.parse(gpa, bytes);
    defer utt2.deinit();

    const tr = &utt2.trigger;
    try t.expectEqualStrings("trig_click", tr.on_click.slice());
    try t.expectEqualStrings("trig_disarm", tr.on_disarm.slice());
    try t.expectEqualStrings("trig_trap", tr.on_trap_triggered.slice());
    try t.expectEqualStrings("trig_hb", tr.script_heartbeat.slice());
    try t.expectEqualStrings("trig_enter", tr.script_on_enter.slice());
    try t.expectEqualStrings("trig_exit", tr.script_on_exit.slice());
    try t.expectEqualStrings("trig_udef", tr.script_user_define.slice());
}

test "UTT blueprint-only fields round-trip" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    const a = utt.arena.allocator();
    utt.trigger.comment = try a.dupe(u8, "Bridge area transition");
    utt.trigger.palette_id = 4;

    const bytes = try utt.serialize(gpa);
    defer gpa.free(bytes);

    var utt2 = try UttFile.parse(gpa, bytes);
    defer utt2.deinit();

    try t.expectEqualStrings("Bridge area transition", utt2.trigger.comment.?);
    try t.expectEqual(@as(?u8, 4), utt2.trigger.palette_id);
}

test "UTT LocalizedName round-trip" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    const a = utt.arena.allocator();
    utt.trigger.localized_name.string_ref = 42;
    try utt.trigger.localized_name.substrings.append(a, .{
        .string_id = 0,
        .text = try a.dupe(u8, "Hidden Trap"),
    });

    const bytes = try utt.serialize(gpa);
    defer gpa.free(bytes);

    var utt2 = try UttFile.parse(gpa, bytes);
    defer utt2.deinit();

    try t.expectEqual(@as(u32, 42), utt2.trigger.localized_name.string_ref);
    try t.expectEqual(@as(usize, 1), utt2.trigger.localized_name.substrings.items.len);
    try t.expectEqualStrings("Hidden Trap", utt2.trigger.localized_name.substrings.items[0].text);
}

test "TriggerStruct instance variant round-trip" {
    const gpa = t.allocator;

    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var tr: TriggerStruct = .{};
    tr.tag = try a.dupe(u8, "TR_AreaTrans");
    tr.trigger_type = 1; // Area Transition
    tr.linked_to_flags = 2; // Waypoint
    tr.linked_to = try a.dupe(u8, "WP_Destination");
    tr.template_res_ref = gff.ResRef.fromSlice("tr_bridge");
    tr.x_position = 5.0;
    tr.y_position = 10.0;
    tr.z_position = 0.0;
    tr.x_orientation = 0.0;
    tr.y_orientation = 0.0;

    const geom = try a.alloc(TriggerPoint, 4);
    geom[0] = .{ .x = -1, .y = -1, .z = 0 };
    geom[1] = .{ .x = 1, .y = -1, .z = 0 };
    geom[2] = .{ .x = 1, .y = 1, .z = 0 };
    geom[3] = .{ .x = -1, .y = 1, .z = 0 };
    tr.geometry = geom;

    const sidx = try g.addStruct(1); // StructID 1 per spec Table 2.3.1
    try tr.writeIntoGff(&g, sidx, .instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const parsed = try TriggerStruct.fromGffStruct(
        arena2.allocator(),
        &g,
        &g.structs.items[sidx],
        .instance,
    );

    try t.expectEqualStrings("TR_AreaTrans", parsed.tag);
    try t.expectEqual(@as(i32, 1), parsed.trigger_type);
    try t.expectEqual(@as(u8, 2), parsed.linked_to_flags);
    try t.expectEqualStrings("WP_Destination", parsed.linked_to);
    try t.expectApproxEqAbs(@as(f32, 5.0), parsed.x_position.?, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 10.0), parsed.y_position.?, 0.0001);

    try t.expectEqual(@as(usize, 4), parsed.geometry.len);
    try t.expectApproxEqAbs(@as(f32, -1), parsed.geometry[0].x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, -1), parsed.geometry[0].y, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 1), parsed.geometry[2].x, 0.0001);
    try t.expectApproxEqAbs(@as(f32, 1), parsed.geometry[2].y, 0.0001);
}

test "UTT byte-exact double serialize" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    const a = utt.arena.allocator();
    utt.trigger.trigger_type = 2;
    utt.trigger.trap_flag = 1;
    utt.trigger.trap_detectable = 1;
    utt.trigger.trap_detect_dc = 10;
    utt.trigger.trap_disarmable = 1;
    utt.trigger.disarm_dc = 15;
    utt.trigger.trap_type = 1;
    utt.trigger.faction = 2;
    utt.trigger.tag = try a.dupe(u8, "TrapPit");
    utt.trigger.template_res_ref = gff.ResRef.fromSlice("trappit01");
    utt.trigger.script_on_enter = gff.ResRef.fromSlice("trap_enter");
    utt.trigger.on_trap_triggered = gff.ResRef.fromSlice("trap_fired");
    utt.trigger.comment = try a.dupe(u8, "Pit trap");
    utt.trigger.palette_id = 2;

    const bytes1 = try utt.serialize(gpa);
    defer gpa.free(bytes1);

    var utt2 = try UttFile.parse(gpa, bytes1);
    defer utt2.deinit();
    const bytes2 = try utt2.serialize(gpa);
    defer gpa.free(bytes2);

    try t.expectEqualSlices(u8, bytes1, bytes2);
}

test "UTT wrong magic rejected" {
    const gpa = t.allocator;
    var utt = UttFile.init(gpa);
    defer utt.deinit();

    const bytes = try utt.serialize(gpa);
    defer gpa.free(bytes);

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[0..4], "UTX ");

    try t.expectError(error.InvalidFileType, UttFile.parse(gpa, mut));
}
