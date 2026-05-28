//! Bioware Aurora Sound Set File (SSF) format reader and writer.
//!
//! A soundset pairs each of a creature's vocal/combat actions with a sound
//! file to play and a dialog.tlk string to display.  Forty-nine fixed entry
//! slots are defined by the game engine (Table 6 of the spec), though the
//! format supports any count.
//!
//! Byte order: little-endian throughout.
//!
//! Physical layout:
//!
//!   ```text
//!   Header       (40 bytes: FileType[4] + FileVersion[4] + EntryCount[4]
//!                            + TableOffset[4] + Padding[24])
//!   Entry Table  (EntryCount × 4 bytes  — byte offsets from start of file
//!                                         to each data object)
//!   Data Table   (EntryCount × 20 bytes — ResRef[16] + StringRef[4])
//!   ```
const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const FILE_TYPE = "SSF ";
pub const FILE_VERSION = "V1.0";

pub const HEADER_SIZE: u32 = 40;
/// Size of one entry in the Entry Table (a u32 byte offset).
pub const ENTRY_TABLE_ENTRY_SIZE: u32 = 4;
/// Size of one data object: ResRef (16) + StringRef (4).
pub const DATA_OBJECT_SIZE: u32 = 20;

/// Sentinel stored in `SoundEntry.string_ref` meaning "no text".
pub const INVALID_STRREF: u32 = 0xFFFF_FFFF;

/// Total number of named soundset slots defined by the Aurora engine.
pub const STANDARD_ENTRY_COUNT: u32 = 49;

pub const FormatError = error{
    /// Magic bytes are not "SSF ".
    InvalidFileType,
    /// Version string is not "V1.0".
    InvalidVersion,
    /// Buffer is truncated or a computed offset is out of range.
    InvalidFormat,
};

// ============================================================================
// SoundIndex — named entry positions (spec Table 6, 0-based)
// ============================================================================

/// Named indices for the 49 standard soundset slots.
/// The integer value equals the 0-based index into the Entry/Data tables.
pub const SoundIndex = enum(u8) {
    attack = 0,
    battlecry_1 = 1,
    battlecry_2 = 2,
    battlecry_3 = 3,
    heal_me = 4,
    help = 5,
    enemies_sighted = 6,
    flee = 7,
    taunt = 8,
    guard_me = 9,
    hold = 10,
    attack_grunt_1 = 11,
    attack_grunt_2 = 12,
    attack_grunt_3 = 13,
    pain_grunt_1 = 14,
    pain_grunt_2 = 15,
    pain_grunt_3 = 16,
    near_death = 17,
    death = 18,
    poisoned = 19,
    spell_failed = 20,
    weapon_ineffective = 21,
    follow_me = 22,
    look_here = 23,
    group_party = 24,
    move_over = 25,
    pick_lock = 26,
    search = 27,
    go_stealthy = 28,
    can_do = 29,
    cannot_do = 30,
    task_complete = 31,
    encumbered = 32,
    selected = 33,
    hello = 34,
    yes = 35,
    no = 36,
    stop = 37,
    rest = 38,
    bored = 39,
    goodbye = 40,
    thank_you = 41,
    laugh = 42,
    cuss = 43,
    cheer = 44,
    something_to_say = 45,
    good_idea = 46,
    bad_idea = 47,
    threaten = 48,
};

// ============================================================================
// SoundEntry
// ============================================================================

/// One data object in the SSF Data Table.
pub const SoundEntry = struct {
    /// Name of the `.wav` resource to play (no extension, ≤16 chars).
    /// Trailing bytes are zero-padded on disk.
    res_ref: [16]u8 = [_]u8{0} ** 16,
    /// Index into `dialog.tlk`.  `INVALID_STRREF` (0xFFFFFFFF) means no text.
    string_ref: u32 = INVALID_STRREF,

    /// Returns the ResRef trimmed of zero padding.
    pub fn resRefSlice(self: *const SoundEntry) []const u8 {
        return std.mem.sliceTo(&self.res_ref, 0);
    }

    /// Copy `name` into `res_ref`, truncating at 16 chars and zero-padding.
    pub fn setResRef(self: *SoundEntry, name: []const u8) void {
        @memset(&self.res_ref, 0);
        const n = @min(name.len, 16);
        @memcpy(self.res_ref[0..n], name[0..n]);
    }
};

// ============================================================================
// SoundSet
// ============================================================================

/// In-memory SSF soundset.  Owns its entry list via `allocator`.
///
/// Example — build and serialize a standard 49-entry soundset:
///
///   ```zig
///   var ss = SoundSet.init(gpa);
///   defer ss.deinit();
///   try ss.initStandard();
///   ss.getEntry(.attack).?.setResRef("pmf_atk");
///   ss.getEntry(.attack).?.string_ref = 1234;
///   const bytes = try ss.serialize(gpa);
///   defer gpa.free(bytes);
///   ```
pub const SoundSet = struct {
    allocator: std.mem.Allocator,
    /// One element per slot; `entries.items[n]` corresponds to entry index `n`.
    entries: std.ArrayList(SoundEntry),

    pub fn init(allocator: std.mem.Allocator) SoundSet {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(SoundEntry).init(allocator),
        };
    }

    pub fn deinit(self: *SoundSet) void {
        self.entries.deinit();
    }

    // ------------------------------------------------------------------ Parse

    /// Parse an SSF byte buffer ("V1.0" version string).
    pub fn parse(self: *SoundSet, data: []const u8) (FormatError || std.mem.Allocator.Error)!void {
        if (data.len < HEADER_SIZE) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[0..4], FILE_TYPE)) return error.InvalidFileType;
        if (!std.mem.eql(u8, data[4..8], FILE_VERSION)) return error.InvalidVersion;

        const entry_count = rd32(data, 8);
        const table_offset = rd32(data, 12);

        // Entry Table must fit inside the buffer.
        const entry_table_size = entry_count *% ENTRY_TABLE_ENTRY_SIZE;
        if (!sectionOk(data.len, table_offset, entry_table_size)) return error.InvalidFormat;

        try self.entries.ensureTotalCapacity(entry_count);

        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const et_off: usize = @as(usize, table_offset) + @as(usize, i) * ENTRY_TABLE_ENTRY_SIZE;
            const data_off = rd32(data, et_off);

            if (!sectionOk(data.len, data_off, DATA_OBJECT_SIZE)) return error.InvalidFormat;

            var e: SoundEntry = .{};
            @memcpy(&e.res_ref, data[data_off..][0..16]);
            e.string_ref = rd32(data, @as(usize, data_off) + 16);
            self.entries.appendAssumeCapacity(e);
        }
    }

    // --------------------------------------------------------------- Serialize

    /// Encode this soundset as an SSF byte stream.  Caller owns the returned
    /// slice and must free it with `alloc`.
    pub fn serialize(self: *const SoundSet, alloc: std.mem.Allocator) ![]u8 {
        const entry_count: u32 = @intCast(self.entries.items.len);
        const table_offset: u32 = HEADER_SIZE;
        const entry_table_size: u32 = entry_count * ENTRY_TABLE_ENTRY_SIZE;
        const data_table_offset: u32 = table_offset + entry_table_size;
        const total: usize = @as(usize, data_table_offset) + @as(usize, entry_count) * DATA_OBJECT_SIZE;

        const out = try alloc.alloc(u8, total);
        errdefer alloc.free(out);
        @memset(out, 0);

        // Header
        @memcpy(out[0..4], FILE_TYPE);
        @memcpy(out[4..8], FILE_VERSION);
        wr32(out, 8, entry_count);
        wr32(out, 12, table_offset);
        // bytes 16..39 remain zero (padding)

        // Entry Table and Data Table written together.
        for (self.entries.items, 0..) |e, i| {
            const data_off: u32 = data_table_offset + @as(u32, @intCast(i)) * DATA_OBJECT_SIZE;
            // Write byte offset into Entry Table slot.
            wr32(out, @as(usize, table_offset) + i * ENTRY_TABLE_ENTRY_SIZE, data_off);
            // Write data object.
            @memcpy(out[data_off..][0..16], &e.res_ref);
            wr32(out, @as(usize, data_off) + 16, e.string_ref);
        }

        return out;
    }

    // ----------------------------------------------------------------- Builder

    /// Append `entry` and return its index.
    pub fn addEntry(self: *SoundSet, entry: SoundEntry) !u32 {
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(entry);
        return idx;
    }

    /// Fill `entries` with `STANDARD_ENTRY_COUNT` blank entries (empty ResRef,
    /// `INVALID_STRREF`), ready to be populated for a standard NWN soundset.
    pub fn initStandard(self: *SoundSet) !void {
        try self.entries.ensureTotalCapacity(STANDARD_ENTRY_COUNT);
        var i: u32 = 0;
        while (i < STANDARD_ENTRY_COUNT) : (i += 1) {
            self.entries.appendAssumeCapacity(.{});
        }
    }

    // ------------------------------------------------------------------ Lookup

    /// Return a mutable pointer to the named slot, or null if the entry list
    /// is shorter than the slot index.
    pub fn getEntry(self: *SoundSet, slot: SoundIndex) ?*SoundEntry {
        const i: usize = @as(usize, @intFromEnum(slot));
        if (i >= self.entries.items.len) return null;
        return &self.entries.items[i];
    }

    /// Return a const pointer to the named slot, or null.
    pub fn getEntryConst(self: *const SoundSet, slot: SoundIndex) ?*const SoundEntry {
        const i: usize = @as(usize, @intFromEnum(slot));
        if (i >= self.entries.items.len) return null;
        return &self.entries.items[i];
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

fn sectionOk(buf_len: usize, off: u32, size: u32) bool {
    return @as(usize, off) + @as(usize, size) <= buf_len;
}

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

inline fn wr32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty SSF round-trip" {
    const gpa = t.allocator;

    var ss = SoundSet.init(gpa);
    defer ss.deinit();

    const bytes = try ss.serialize(gpa);
    defer gpa.free(bytes);

    // An empty soundset serializes to exactly the 40-byte header.
    try t.expectEqual(@as(usize, HEADER_SIZE), bytes.len);

    var ss2 = SoundSet.init(gpa);
    defer ss2.deinit();
    try ss2.parse(bytes);

    try t.expectEqual(@as(usize, 0), ss2.entries.items.len);
}

test "SSF single-entry round-trip" {
    const gpa = t.allocator;

    var ss = SoundSet.init(gpa);
    defer ss.deinit();

    var e: SoundEntry = .{ .string_ref = 42 };
    e.setResRef("pmf_attack1");
    _ = try ss.addEntry(e);

    const bytes = try ss.serialize(gpa);
    defer gpa.free(bytes);

    var ss2 = SoundSet.init(gpa);
    defer ss2.deinit();
    try ss2.parse(bytes);

    try t.expectEqual(@as(usize, 1), ss2.entries.items.len);
    try t.expectEqualStrings("pmf_attack1", ss2.entries.items[0].resRefSlice());
    try t.expectEqual(@as(u32, 42), ss2.entries.items[0].string_ref);
}

test "SSF standard 49-entry byte-exact round-trip" {
    const gpa = t.allocator;

    var ss = SoundSet.init(gpa);
    defer ss.deinit();
    try ss.initStandard();
    try t.expectEqual(@as(usize, STANDARD_ENTRY_COUNT), ss.entries.items.len);

    ss.getEntry(.attack).?.setResRef("pmf_atk");
    ss.getEntry(.attack).?.string_ref = 1000;
    ss.getEntry(.death).?.setResRef("pmf_die");
    // death string_ref left as INVALID_STRREF

    const bytes = try ss.serialize(gpa);
    defer gpa.free(bytes);

    var ss2 = SoundSet.init(gpa);
    defer ss2.deinit();
    try ss2.parse(bytes);

    try t.expectEqual(@as(usize, STANDARD_ENTRY_COUNT), ss2.entries.items.len);

    const atk = ss2.getEntryConst(.attack).?;
    try t.expectEqualStrings("pmf_atk", atk.resRefSlice());
    try t.expectEqual(@as(u32, 1000), atk.string_ref);

    const die = ss2.getEntryConst(.death).?;
    try t.expectEqualStrings("pmf_die", die.resRefSlice());
    try t.expectEqual(INVALID_STRREF, die.string_ref);

    // Second serialization must be byte-for-byte identical.
    const bytes2 = try ss2.serialize(gpa);
    defer gpa.free(bytes2);
    try t.expectEqualSlices(u8, bytes, bytes2);
}

test "SSF rejects bad magic and bad version" {
    const gpa = t.allocator;

    var ss = SoundSet.init(gpa);
    defer ss.deinit();
    const bytes = try ss.serialize(gpa);
    defer gpa.free(bytes);

    const bad_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(bad_magic);
    @memcpy(bad_magic[0..4], "ERF ");
    var ss1 = SoundSet.init(gpa);
    defer ss1.deinit();
    try t.expectError(error.InvalidFileType, ss1.parse(bad_magic));

    const bad_ver = try gpa.dupe(u8, bytes);
    defer gpa.free(bad_ver);
    @memcpy(bad_ver[4..8], "V2.0");
    var ss2 = SoundSet.init(gpa);
    defer ss2.deinit();
    try t.expectError(error.InvalidVersion, ss2.parse(bad_ver));
}

test "SSF rejects truncated buffer" {
    const gpa = t.allocator;
    // A buffer shorter than HEADER_SIZE must fail.
    const short = [_]u8{0} ** 10;
    var ss = SoundSet.init(gpa);
    defer ss.deinit();
    try t.expectError(error.InvalidFormat, ss.parse(&short));
}

test "SoundEntry.setResRef truncates at 16 chars" {
    var e: SoundEntry = .{};
    e.setResRef("abcdefghijklmnopqrstuvwxyz"); // 26 chars → truncated
    try t.expectEqualStrings("abcdefghijklmnop", e.resRefSlice());
}

test "SSF getEntry returns null for out-of-range slot" {
    const gpa = t.allocator;
    var ss = SoundSet.init(gpa);
    defer ss.deinit();
    // Empty soundset — every named slot is out of range.
    try t.expectEqual(@as(?*SoundEntry, null), ss.getEntry(.attack));
    try t.expectEqual(@as(?*SoundEntry, null), ss.getEntry(.threaten));
}
