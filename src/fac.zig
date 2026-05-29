//! BioWare Aurora Faction System (FAC) file reader and writer.
//!
//! Faction information is stored in repute.fac in a module or savegame.
//! Uses BioWare's Generic File Format (GFF) with FileType "FAC ".
//!
//! Memory model: FacFile owns all strings and slices via its allocator.
//! Call deinit() once to free everything.
//!
//! §2.1   Top Level Struct   — FactionList + RepList
//! §2.1.2 Faction Struct     — FactionGlobal, FactionName, FactionParentID
//! §2.1.3 Reputation Struct  — FactionID1, FactionID2, FactionRep

const std = @import("std");
const gff = @import("gff.zig");

pub const FILE_TYPE = "FAC ";

/// Sentinel used by the four built-in factions (PC, Hostile, Commoner, Merchant)
/// to indicate they have no parent.
pub const NO_PARENT: u32 = 0xFFFF_FFFF;

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

// ============================================================================
// Public types
// ============================================================================

/// Standing thresholds as described in §2.1.3.
pub const Standing = enum {
    hostile, // FactionRep 0–10
    neutral, // FactionRep 11–89
    friendly, // FactionRep 90–100

    pub fn fromRep(rep: u32) Standing {
        if (rep <= 10) return .hostile;
        if (rep <= 89) return .neutral;
        return .friendly;
    }
};

/// One entry from the FactionList (§2.1.2, StructID = list index).
pub const Faction = struct {
    /// Name of the faction.
    name: []u8 = &.{},
    /// Index of parent faction; NO_PARENT (0xFFFFFFFF) for the four built-ins.
    parent_id: u32 = NO_PARENT,
    /// 1 = global effect flag; 0 = individual reactions only.
    global: u16 = 0,
};

/// One entry from the RepList (§2.1.3, StructID = list index).
/// Describes how Faction2 perceives Faction1.
pub const Reputation = struct {
    faction_id1: u32 = 0,
    faction_id2: u32 = 0,
    /// Raw reputation value 0–100.
    rep: u32 = 50,

    pub fn standing(self: Reputation) Standing {
        return Standing.fromRep(self.rep);
    }
};

/// In-memory representation of a repute.fac GFF file.
pub const FacFile = struct {
    allocator: std.mem.Allocator,
    factions: std.ArrayList(Faction),
    reputations: std.ArrayList(Reputation),

    pub fn init(allocator: std.mem.Allocator) FacFile {
        return .{
            .allocator = allocator,
            .factions = .empty,
            .reputations = .empty,
        };
    }

    pub fn deinit(self: *FacFile) void {
        const a = self.allocator;
        for (self.factions.items) |*f| a.free(f.name);
        self.factions.deinit(a);
        self.reputations.deinit(a);
    }

    // ------------------------------------------------------------------ Parse

    pub fn parse(self: *FacFile, data: []const u8) Error!void {
        const a = self.allocator;
        var g = gff.GffFile.initEmpty(a);
        defer g.deinit();
        try g.parse(data, FILE_TYPE);

        const tl = &g.structs.items[0];

        // FactionList
        if (g.getField(tl, "FactionList")) |fl| {
            const handles = switch (fl.value) {
                .list => |v| v,
                else => return error.WrongFieldType,
            };
            try self.factions.ensureTotalCapacity(a, handles.len);
            for (handles) |h| {
                if (h >= g.structs.items.len) return error.InvalidFormat;
                const faction = try parseFaction(a, &g, &g.structs.items[h]);
                self.factions.appendAssumeCapacity(faction);
            }
        }

        // RepList
        if (g.getField(tl, "RepList")) |rl| {
            const handles = switch (rl.value) {
                .list => |v| v,
                else => return error.WrongFieldType,
            };
            try self.reputations.ensureTotalCapacity(a, handles.len);
            for (handles) |h| {
                if (h >= g.structs.items.len) return error.InvalidFormat;
                const rep = try parseReputation(&g, &g.structs.items[h]);
                self.reputations.appendAssumeCapacity(rep);
            }
        }
    }

    // --------------------------------------------------------------- Serialize

    pub fn serialize(self: *const FacFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();

        // FactionList
        const faction_handles = try alloc.alloc(u32, self.factions.items.len);
        for (self.factions.items, 0..) |*faction, i| {
            const sidx = try g.addStruct(@intCast(i));
            faction_handles[i] = sidx;
            try g.addFieldToStruct(sidx, "FactionGlobal", .{ .word = faction.global });
            try g.addFieldToStruct(sidx, "FactionName", .{ .exo_string = try alloc.dupe(u8, faction.name) });
            try g.addFieldToStruct(sidx, "FactionParentID", .{ .dword = faction.parent_id });
        }
        try g.addFieldToStruct(0, "FactionList", .{ .list = faction_handles });

        // RepList
        const rep_handles = try alloc.alloc(u32, self.reputations.items.len);
        for (self.reputations.items, 0..) |*rep, i| {
            const sidx = try g.addStruct(@intCast(i));
            rep_handles[i] = sidx;
            try g.addFieldToStruct(sidx, "FactionID1", .{ .dword = rep.faction_id1 });
            try g.addFieldToStruct(sidx, "FactionID2", .{ .dword = rep.faction_id2 });
            try g.addFieldToStruct(sidx, "FactionRep", .{ .dword = rep.rep });
        }
        try g.addFieldToStruct(0, "RepList", .{ .list = rep_handles });

        return g.serialize(alloc);
    }

    // ----------------------------------------------------------------- Builder

    pub fn addFaction(self: *FacFile, faction: Faction) !void {
        try self.factions.append(self.allocator, faction);
    }

    pub fn addReputation(self: *FacFile, rep: Reputation) !void {
        try self.reputations.append(self.allocator, rep);
    }

    // ------------------------------------------------------------------ Lookup

    /// Find a faction by name. Returns null if not found.
    pub fn findFaction(self: *const FacFile, name: []const u8) ?*const Faction {
        for (self.factions.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// Find the reputation entry for how faction_id2 perceives faction_id1.
    /// Returns null if no matching entry exists.
    pub fn findReputation(self: *const FacFile, faction_id1: u32, faction_id2: u32) ?*const Reputation {
        for (self.reputations.items) |*r| {
            if (r.faction_id1 == faction_id1 and r.faction_id2 == faction_id2) return r;
        }
        return null;
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

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

fn optExoStringDupe(alloc: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, label: []const u8) Error![]u8 {
    const f = g.getField(s, label) orelse return alloc.alloc(u8, 0);
    return switch (f.value) {
        .exo_string => |v| alloc.dupe(u8, v),
        else => error.WrongFieldType,
    };
}

fn parseFaction(alloc: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!Faction {
    const name = try optExoStringDupe(alloc, g, s, "FactionName");
    errdefer alloc.free(name);
    return .{
        .name = name,
        .parent_id = try optDword(g, s, "FactionParentID", NO_PARENT),
        .global = try optWord(g, s, "FactionGlobal", 0),
    };
}

fn parseReputation(g: *const gff.GffFile, s: *const gff.Struct) Error!Reputation {
    return .{
        .faction_id1 = try optDword(g, s, "FactionID1", 0),
        .faction_id2 = try optDword(g, s, "FactionID2", 0),
        .rep = try optDword(g, s, "FactionRep", 50),
    };
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "FAC empty round-trip" {
    const gpa = t.allocator;
    var fac = FacFile.init(gpa);
    defer fac.deinit();

    const bytes = try fac.serialize(gpa);
    defer gpa.free(bytes);

    var fac2 = FacFile.init(gpa);
    defer fac2.deinit();
    try fac2.parse(bytes);

    try t.expectEqual(@as(usize, 0), fac2.factions.items.len);
    try t.expectEqual(@as(usize, 0), fac2.reputations.items.len);
}

test "FAC faction fields round-trip" {
    const gpa = t.allocator;
    var fac = FacFile.init(gpa);
    defer fac.deinit();

    try fac.addFaction(.{
        .name = try gpa.dupe(u8, "Guards"),
        .parent_id = NO_PARENT,
        .global = 1,
    });
    try fac.addFaction(.{
        .name = try gpa.dupe(u8, "Elite Guards"),
        .parent_id = 0,
        .global = 0,
    });

    const bytes = try fac.serialize(gpa);
    defer gpa.free(bytes);

    var fac2 = FacFile.init(gpa);
    defer fac2.deinit();
    try fac2.parse(bytes);

    try t.expectEqual(@as(usize, 2), fac2.factions.items.len);
    try t.expectEqualStrings("Guards", fac2.factions.items[0].name);
    try t.expectEqual(NO_PARENT, fac2.factions.items[0].parent_id);
    try t.expectEqual(@as(u16, 1), fac2.factions.items[0].global);
    try t.expectEqualStrings("Elite Guards", fac2.factions.items[1].name);
    try t.expectEqual(@as(u32, 0), fac2.factions.items[1].parent_id);
    try t.expectEqual(@as(u16, 0), fac2.factions.items[1].global);
}

test "FAC reputation fields round-trip" {
    const gpa = t.allocator;
    var fac = FacFile.init(gpa);
    defer fac.deinit();

    // Guards hostile to Player
    try fac.addReputation(.{ .faction_id1 = 0, .faction_id2 = 1, .rep = 5 });
    // Commoner neutral to Guards
    try fac.addReputation(.{ .faction_id1 = 1, .faction_id2 = 2, .rep = 50 });
    // Merchant friendly to Commoner
    try fac.addReputation(.{ .faction_id1 = 2, .faction_id2 = 3, .rep = 100 });

    const bytes = try fac.serialize(gpa);
    defer gpa.free(bytes);

    var fac2 = FacFile.init(gpa);
    defer fac2.deinit();
    try fac2.parse(bytes);

    try t.expectEqual(@as(usize, 3), fac2.reputations.items.len);
    try t.expectEqual(@as(u32, 0), fac2.reputations.items[0].faction_id1);
    try t.expectEqual(@as(u32, 1), fac2.reputations.items[0].faction_id2);
    try t.expectEqual(@as(u32, 5), fac2.reputations.items[0].rep);
    try t.expectEqual(Standing.hostile, fac2.reputations.items[0].standing());
    try t.expectEqual(Standing.neutral, fac2.reputations.items[1].standing());
    try t.expectEqual(Standing.friendly, fac2.reputations.items[2].standing());
}

test "FAC findFaction and findReputation" {
    const gpa = t.allocator;
    var fac = FacFile.init(gpa);
    defer fac.deinit();

    try fac.addFaction(.{ .name = try gpa.dupe(u8, "PC"), .parent_id = NO_PARENT });
    try fac.addFaction(.{ .name = try gpa.dupe(u8, "Hostile"), .parent_id = NO_PARENT });
    try fac.addReputation(.{ .faction_id1 = 1, .faction_id2 = 0, .rep = 0 });

    try t.expect(fac.findFaction("PC") != null);
    try t.expect(fac.findFaction("Hostile") != null);
    try t.expect(fac.findFaction("Missing") == null);

    const r = fac.findReputation(1, 0);
    try t.expect(r != null);
    try t.expectEqual(@as(u32, 0), r.?.rep);
    try t.expect(fac.findReputation(0, 1) == null);
}

test "FAC Standing thresholds" {
    try t.expectEqual(Standing.hostile, Standing.fromRep(0));
    try t.expectEqual(Standing.hostile, Standing.fromRep(10));
    try t.expectEqual(Standing.neutral, Standing.fromRep(11));
    try t.expectEqual(Standing.neutral, Standing.fromRep(89));
    try t.expectEqual(Standing.friendly, Standing.fromRep(90));
    try t.expectEqual(Standing.friendly, Standing.fromRep(100));
}

test "FAC byte-exact double serialize" {
    const gpa = t.allocator;
    var fac = FacFile.init(gpa);
    defer fac.deinit();

    try fac.addFaction(.{ .name = try gpa.dupe(u8, "PC"), .parent_id = NO_PARENT, .global = 0 });
    try fac.addFaction(.{ .name = try gpa.dupe(u8, "Hostile"), .parent_id = NO_PARENT, .global = 1 });
    try fac.addReputation(.{ .faction_id1 = 0, .faction_id2 = 1, .rep = 0 });
    try fac.addReputation(.{ .faction_id1 = 1, .faction_id2 = 0, .rep = 100 });

    const bytes1 = try fac.serialize(gpa);
    defer gpa.free(bytes1);

    var fac2 = FacFile.init(gpa);
    defer fac2.deinit();
    try fac2.parse(bytes1);

    const bytes2 = try fac2.serialize(gpa);
    defer gpa.free(bytes2);

    try t.expectEqualSlices(u8, bytes1, bytes2);
}
