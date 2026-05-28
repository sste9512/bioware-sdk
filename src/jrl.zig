//! Bioware Aurora Journal System (JRL) file reader and writer.
//!
//! Journal files use the Generic File Format (GFF) with FileType "JRL ".
//! module.jrl stores quest categories and their numbered entries.
//!
//! Memory model: JrlFile owns all strings and slices via its allocator.
//! Call deinit() once to free everything.  Every []u8 and ExoLocString
//! stored in JournalCategory / JournalEntry must be allocated by that
//! same allocator (zero-length frees are always safe per the Allocator spec).
const std = @import("std");
const gff = @import("gff.zig");

pub const FILE_TYPE = "JRL ";

pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
} || gff.FormatError || std.mem.Allocator.Error;

// ============================================================================
// Public types
// ============================================================================

pub const JournalEntry = struct {
    id: u32 = 0,
    end: bool = false,
    /// Localized text shown in the player's journal.
    text: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
};

pub const JournalCategory = struct {
    tag: []u8 = &.{},
    comment: []u8 = &.{},
    name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    picture: u16 = 0xFFFF,
    /// 0 = Highest … 4 = Lowest
    priority: u32 = 2,
    xp: u32 = 0,
    entries: []JournalEntry = &.{},
};

/// In-memory representation of a module.jrl GFF file.
pub const JrlFile = struct {
    allocator: std.mem.Allocator,
    categories: std.ArrayList(JournalCategory),

    pub fn init(allocator: std.mem.Allocator) JrlFile {
        return .{
            .allocator = allocator,
            .categories = .empty,
        };
    }

    pub fn deinit(self: *JrlFile) void {
        const a = self.allocator;
        for (self.categories.items) |*cat| freeCategory(a, cat);
        self.categories.deinit(a);
    }

    // ------------------------------------------------------------------ Parse

    pub fn parse(self: *JrlFile, data: []const u8) Error!void {
        const a = self.allocator;
        var g = gff.GffFile.initEmpty(a);
        defer g.deinit();
        try g.parse(data, FILE_TYPE);

        const tl = &g.structs.items[0];
        const cf = g.getField(tl, "Categories") orelse return;
        const handles = switch (cf.value) {
            .list => |v| v,
            else => return error.WrongFieldType,
        };

        try self.categories.ensureTotalCapacity(a, handles.len);
        for (handles) |h| {
            if (h >= g.structs.items.len) return error.InvalidFormat;
            const cat = try parseCategory(a, &g, &g.structs.items[h]);
            self.categories.appendAssumeCapacity(cat);
        }
    }

    // --------------------------------------------------------------- Serialize

    pub fn serialize(self: *const JrlFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();

        const cat_handles = try alloc.alloc(u32, self.categories.items.len);
        for (self.categories.items, 0..) |*cat, ci| {
            const sidx = try g.addStruct(@intCast(ci));
            cat_handles[ci] = sidx;
            try writeCategoryInto(alloc, &g, sidx, cat);
        }
        try g.addFieldToStruct(0, "Categories", .{ .list = cat_handles });

        return g.serialize(alloc);
    }

    // ----------------------------------------------------------------- Builder

    pub fn addCategory(self: *JrlFile, cat: JournalCategory) !void {
        try self.categories.append(self.allocator, cat);
    }

    // ------------------------------------------------------------------ Lookup

    pub fn findCategory(self: *const JrlFile, tag: []const u8) ?*const JournalCategory {
        for (self.categories.items) |*cat| {
            if (std.mem.eql(u8, cat.tag, tag)) return cat;
        }
        return null;
    }
};

// ============================================================================
// Internal helpers: read typed values out of a parsed GFF struct
// ============================================================================

inline fn optWord(
    g: *const gff.GffFile,
    s: *const gff.Struct,
    label: []const u8,
    default: u16,
) Error!u16 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .word => |v| v,
        else => error.WrongFieldType,
    };
}

inline fn optDword(
    g: *const gff.GffFile,
    s: *const gff.Struct,
    label: []const u8,
    default: u32,
) Error!u32 {
    const f = g.getField(s, label) orelse return default;
    return switch (f.value) {
        .dword => |v| v,
        else => error.WrongFieldType,
    };
}

fn optExoStringDupe(
    alloc: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
    label: []const u8,
) Error![]u8 {
    const f = g.getField(s, label) orelse return alloc.alloc(u8, 0);
    return switch (f.value) {
        .exo_string => |v| alloc.dupe(u8, v),
        else => error.WrongFieldType,
    };
}

fn optExoLocDupe(
    alloc: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
    label: []const u8,
) Error!gff.ExoLocString {
    var out: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    const f = g.getField(s, label) orelse return out;
    switch (f.value) {
        .exo_loc_string => |loc| {
            out.string_ref = loc.string_ref;
            errdefer out.deinit(alloc);
            for (loc.substrings.items) |ss| {
                const text = try alloc.dupe(u8, ss.text);
                errdefer alloc.free(text);
                try out.substrings.append(alloc, .{
                    .string_id = ss.string_id,
                    .text = text,
                });
            }
            return out;
        },
        else => return error.WrongFieldType,
    }
}

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
// Internal helpers: parse / free / write compound structures
// ============================================================================

fn freeCategory(alloc: std.mem.Allocator, cat: *JournalCategory) void {
    alloc.free(cat.tag);
    alloc.free(cat.comment);
    cat.name.deinit(alloc);
    for (cat.entries) |*e| e.text.deinit(alloc);
    alloc.free(cat.entries);
}

fn parseEntries(
    alloc: std.mem.Allocator,
    g: *const gff.GffFile,
    cs: *const gff.Struct,
) Error![]JournalEntry {
    const f = g.getField(cs, "EntryList") orelse return &.{};
    const handles = switch (f.value) {
        .list => |v| v,
        else => return error.WrongFieldType,
    };

    const entries = try alloc.alloc(JournalEntry, handles.len);
    var n: usize = 0;
    errdefer {
        for (entries[0..n]) |*e| e.text.deinit(alloc);
        alloc.free(entries);
    }

    for (handles, 0..) |h, i| {
        if (h >= g.structs.items.len) return error.InvalidFormat;
        const es = &g.structs.items[h];
        entries[i] = .{
            .id = try optDword(g, es, "ID", 0),
            .end = (try optWord(g, es, "End", 0)) != 0,
            .text = try optExoLocDupe(alloc, g, es, "Text"),
        };
        n += 1;
    }
    return entries;
}

fn parseCategory(
    alloc: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
) Error!JournalCategory {
    const tag = try optExoStringDupe(alloc, g, s, "Tag");
    errdefer alloc.free(tag);

    const comment = try optExoStringDupe(alloc, g, s, "Comment");
    errdefer alloc.free(comment);

    var name = try optExoLocDupe(alloc, g, s, "Name");
    errdefer name.deinit(alloc);

    const picture = try optWord(g, s, "Picture", 0xFFFF);
    const priority = try optDword(g, s, "Priority", 2);
    const xp = try optDword(g, s, "XP", 0);

    const entries = try parseEntries(alloc, g, s);
    errdefer {
        for (entries) |*e| e.text.deinit(alloc);
        alloc.free(entries);
    }

    return .{
        .tag = tag,
        .comment = comment,
        .name = name,
        .picture = picture,
        .priority = priority,
        .xp = xp,
        .entries = entries,
    };
}

fn writeCategoryInto(
    alloc: std.mem.Allocator,
    g: *gff.GffFile,
    sidx: u32,
    cat: *const JournalCategory,
) !void {
    try g.addFieldToStruct(sidx, "Comment", .{ .exo_string = try alloc.dupe(u8, cat.comment) });

    const entry_handles = try alloc.alloc(u32, cat.entries.len);
    for (cat.entries, 0..) |*entry, ei| {
        const esidx = try g.addStruct(@intCast(ei));
        entry_handles[ei] = esidx;
        try g.addFieldToStruct(esidx, "End", .{ .word = if (entry.end) 1 else 0 });
        try g.addFieldToStruct(esidx, "ID", .{ .dword = entry.id });
        try g.addFieldToStruct(esidx, "Text", .{ .exo_loc_string = try cloneExoLoc(alloc, entry.text) });
    }
    try g.addFieldToStruct(sidx, "EntryList", .{ .list = entry_handles });

    try g.addFieldToStruct(sidx, "Name", .{ .exo_loc_string = try cloneExoLoc(alloc, cat.name) });
    try g.addFieldToStruct(sidx, "Picture", .{ .word = cat.picture });
    try g.addFieldToStruct(sidx, "Priority", .{ .dword = cat.priority });
    try g.addFieldToStruct(sidx, "Tag", .{ .exo_string = try alloc.dupe(u8, cat.tag) });
    try g.addFieldToStruct(sidx, "XP", .{ .dword = cat.xp });
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "JRL empty round-trip" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    const bytes = try jrl.serialize(gpa);
    defer gpa.free(bytes);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes);

    try t.expectEqual(@as(usize, 0), jrl2.categories.items.len);
}

test "JRL single category scalar fields" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    try jrl.addCategory(.{
        .tag = try gpa.dupe(u8, "quest_main"),
        .comment = try gpa.dupe(u8, "Main quest"),
        .picture = 0xFFFF,
        .priority = 1,
        .xp = 500,
    });

    const bytes = try jrl.serialize(gpa);
    defer gpa.free(bytes);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes);

    try t.expectEqual(@as(usize, 1), jrl2.categories.items.len);
    const cat = &jrl2.categories.items[0];
    try t.expectEqualStrings("quest_main", cat.tag);
    try t.expectEqualStrings("Main quest", cat.comment);
    try t.expectEqual(@as(u16, 0xFFFF), cat.picture);
    try t.expectEqual(@as(u32, 1), cat.priority);
    try t.expectEqual(@as(u32, 500), cat.xp);
}

test "JRL category name loc-string round-trip" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    var cat: JournalCategory = .{ .tag = try gpa.dupe(u8, "c1") };
    cat.name.string_ref = 42;
    try cat.name.substrings.append(gpa, .{
        .string_id = 0,
        .text = try gpa.dupe(u8, "Main Quest"),
    });
    try jrl.addCategory(cat);

    const bytes = try jrl.serialize(gpa);
    defer gpa.free(bytes);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes);

    const cat2 = &jrl2.categories.items[0];
    try t.expectEqual(@as(u32, 42), cat2.name.string_ref);
    try t.expectEqual(@as(usize, 1), cat2.name.substrings.items.len);
    try t.expectEqualStrings("Main Quest", cat2.name.substrings.items[0].text);
}

test "JRL category with entries" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    const entries = try gpa.alloc(JournalEntry, 2);
    entries[0] = .{ .id = 10, .end = false };
    entries[0].text.string_ref = 100;
    entries[1] = .{ .id = 20, .end = true };
    entries[1].text.string_ref = 200;

    try jrl.addCategory(.{
        .tag = try gpa.dupe(u8, "qst"),
        .entries = entries,
    });

    const bytes = try jrl.serialize(gpa);
    defer gpa.free(bytes);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes);

    const cat = &jrl2.categories.items[0];
    try t.expectEqual(@as(usize, 2), cat.entries.len);
    try t.expectEqual(@as(u32, 10), cat.entries[0].id);
    try t.expectEqual(false, cat.entries[0].end);
    try t.expectEqual(@as(u32, 100), cat.entries[0].text.string_ref);
    try t.expectEqual(@as(u32, 20), cat.entries[1].id);
    try t.expectEqual(true, cat.entries[1].end);
    try t.expectEqual(@as(u32, 200), cat.entries[1].text.string_ref);
}

test "JRL multiple categories order preserved" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    try jrl.addCategory(.{ .tag = try gpa.dupe(u8, "alpha"), .priority = 0 });
    try jrl.addCategory(.{ .tag = try gpa.dupe(u8, "beta"), .priority = 1 });
    try jrl.addCategory(.{ .tag = try gpa.dupe(u8, "gamma"), .priority = 2 });

    const bytes = try jrl.serialize(gpa);
    defer gpa.free(bytes);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes);

    try t.expectEqual(@as(usize, 3), jrl2.categories.items.len);
    try t.expectEqualStrings("alpha", jrl2.categories.items[0].tag);
    try t.expectEqualStrings("beta", jrl2.categories.items[1].tag);
    try t.expectEqualStrings("gamma", jrl2.categories.items[2].tag);
}

test "JRL ExoLocString multiple substrings" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    var cat: JournalCategory = .{ .tag = try gpa.dupe(u8, "multi") };
    try cat.name.substrings.append(gpa, .{ .string_id = 0, .text = try gpa.dupe(u8, "English") });
    try cat.name.substrings.append(gpa, .{ .string_id = 2, .text = try gpa.dupe(u8, "French") });
    try jrl.addCategory(cat);

    const bytes = try jrl.serialize(gpa);
    defer gpa.free(bytes);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes);

    const cat2 = &jrl2.categories.items[0];
    try t.expectEqual(@as(usize, 2), cat2.name.substrings.items.len);
    try t.expectEqual(@as(u32, 0), cat2.name.substrings.items[0].string_id);
    try t.expectEqualStrings("English", cat2.name.substrings.items[0].text);
    try t.expectEqual(@as(u32, 2), cat2.name.substrings.items[1].string_id);
    try t.expectEqualStrings("French", cat2.name.substrings.items[1].text);
}

test "JRL byte-exact double serialize" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    var cat: JournalCategory = .{
        .tag = try gpa.dupe(u8, "q1"),
        .comment = try gpa.dupe(u8, "First quest"),
        .priority = 0,
        .xp = 150,
    };
    cat.name.string_ref = 55;

    const entries = try gpa.alloc(JournalEntry, 1);
    entries[0] = .{ .id = 5, .end = true };
    cat.entries = entries;
    try jrl.addCategory(cat);

    const bytes1 = try jrl.serialize(gpa);
    defer gpa.free(bytes1);

    var jrl2 = JrlFile.init(gpa);
    defer jrl2.deinit();
    try jrl2.parse(bytes1);

    const bytes2 = try jrl2.serialize(gpa);
    defer gpa.free(bytes2);

    try t.expectEqualSlices(u8, bytes1, bytes2);
}

test "JRL findCategory" {
    const gpa = t.allocator;
    var jrl = JrlFile.init(gpa);
    defer jrl.deinit();

    try jrl.addCategory(.{ .tag = try gpa.dupe(u8, "quest_a"), .priority = 1 });
    try jrl.addCategory(.{ .tag = try gpa.dupe(u8, "quest_b"), .priority = 2 });

    const found = jrl.findCategory("quest_b");
    try t.expect(found != null);
    try t.expectEqual(@as(u32, 2), found.?.priority);

    try t.expectEqual(@as(?*const JournalCategory, null), jrl.findCategory("quest_x"));
}
