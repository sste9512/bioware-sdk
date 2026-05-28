//! Bioware Aurora Talk Table (`dialog.tlk`) format reader and writer.
//!
//! A talk table is the engine's localized-string database. Every
//! user-visible string is stored under an integer StringRef (StrRef);
//! per-language `dialog.tlk` / `dialogf.tlk` files contain the masculine
//! / feminine translations.
//!
//! Byte order: little-endian throughout.
//!
//! Physical layout (Spec 3.1):
//!
//!   ```text
//!   Header                (20 bytes)
//!   String Data Table     (StringCount × 40 bytes for V3.0,
//!                          StringCount × 36 bytes for pre-V3.0)
//!   String Entry Table    (variable; raw text bytes referenced by
//!                          OffsetToString + StringSize in each entry)
//!   ```
//!
//! Versions:
//!   * `V3.0` — full layout (read + write).
//!   * pre-3.0 — accepted on read; `SoundLength` is absent and treated
//!     as 0.0 (Spec §3.3 note). This module always writes `V3.0`.
const std = @import("std");
const erf = @import("erf.zig");
const gff = @import("gff.zig");

// ============================================================================
// Constants & enums
// ============================================================================

pub const FormatError = error{
    /// Magic is not "TLK ".
    InvalidFileType,
    /// Version is neither "V3.0" nor a recognised pre-3.0 string.
    InvalidVersion,
    /// Truncated buffer or out-of-range offset/size.
    InvalidFormat,
    /// Recognised pre-3.0 version but the parser reached an unexpected
    /// state. Reserved for future use.
    UnsupportedVersion,
};

pub const HEADER_SIZE: u32 = 20;
pub const ENTRY_SIZE_V3: u32 = 40;
pub const ENTRY_SIZE_PRE_V3: u32 = 36;
pub const FILE_TYPE = "TLK ";
pub const VERSION_V3 = "V3.0";

/// On-disk version. Read-only mode may produce `pre_v3_0`; serialize
/// always writes `v3_0`.
pub const Version = enum { v3_0, pre_v3_0 };

/// Talk table language IDs. Same set as ERF localized-string language IDs
/// (Spec Table 3.2.2 ↔ ERF Localized String list), so this is a direct
/// alias of `erf.Language`. Note: TLK uses the bare language ID; ERF
/// encodes gender into the low bit (see `erf.Language.encode`).
pub const Language = erf.Language;

/// Spec Table 3.3.2 — flag bits inside `TalkTableEntry.flags`.
pub const Flags = packed struct(u32) {
    /// `0x0001` — text is stored for this StrRef. If unset, the text is
    /// an empty string regardless of `OffsetToString` / `StringSize`.
    text_present: bool = false,
    /// `0x0002` — `sound_res_ref` is meaningful. If unset, the sound
    /// ResRef is treated as empty.
    sound_present: bool = false,
    /// `0x0004` — `sound_length` is meaningful. If unset, sound length
    /// is treated as 0.0.
    sound_length_present: bool = false,
    _padding: u29 = 0,

    pub fn fromU32(v: u32) Flags {
        return @bitCast(v);
    }
    pub fn toU32(self: Flags) u32 {
        return @bitCast(self);
    }
};

/// Sentinel returned by `getString` for "no text". Matches Spec §2.2.
pub const INVALID_STRREF: u32 = 0xFFFF_FFFF;
/// Mask applied to a StrRef before lookup. Spec §2.2: only the low 24
/// bits index the table; upper bits are reserved (e.g. alt-TLK bit).
pub const STRREF_MASK: u32 = 0x00FF_FFFF;
/// Spec §2.4 — when this bit is set in a StrRef, the lookup should be
/// directed to the module's alternate talk table (caller's
/// responsibility; this module does not auto-route).
pub const STRREF_ALT_BIT: u32 = 0x0100_0000;

// ============================================================================
// TalkTableEntry
// ============================================================================

/// One row of the String Data Table. Spec Table 3.3.1.
pub const TalkTableEntry = struct {
    flags: Flags = .{},
    /// 16-byte ResRef of the wave file associated with this string.
    /// Trailing bytes are zero-padded.
    sound_res_ref: [16]u8 = [_]u8{0} ** 16,
    /// Spec: "not used".
    volume_variance: u32 = 0,
    /// Spec: "not used".
    pitch_variance: u32 = 0,
    /// Duration in seconds of the associated sound. Read as 0.0 when the
    /// source file is pre-V3.0 or `flags.sound_length_present` is unset.
    sound_length: f32 = 0.0,
    /// Owned text. Empty when `flags.text_present == false`.
    text: []u8 = &[_]u8{},

    /// Returns the sound ResRef trimmed of zero padding.
    pub fn soundResRefSlice(self: *const TalkTableEntry) []const u8 {
        return std.mem.sliceTo(&self.sound_res_ref, 0);
    }
};

// ============================================================================
// TalkTable
// ============================================================================

/// In-memory talk table. Owns every entry's `text` slice via `allocator`.
/// const sdk = @import("bioware_sdk");

// var tab = sdk.TalkTable.init(gpa);
// defer tab.deinit();
// try tab.parse(bytes);

// if (tab.getString(strref)) |s| std.debug.print("{s}\n", .{s});

// // ExoLocString fallback:
// const text = sdk.tlk.resolveExoLoc(loc, preferred_language_id, &tab);
pub const TalkTable = struct {
    allocator: std.mem.Allocator,
    /// Spec 3.2.1 — language of the strings in this table.
    language: Language = .english,
    /// One element per StrRef. `entries.items[n]` is StrRef `n`.
    entries: std.ArrayList(TalkTableEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) TalkTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TalkTable) void {
        for (self.entries.items) |e| self.allocator.free(e.text);
        self.entries.deinit(self.allocator);
    }

    // ------------------------------------------------------------------ Parse

    /// Parse a TLK buffer. Accepts `V3.0` and pre-3.0 layouts; on pre-3.0
    /// every entry's `sound_length` is set to 0.0 (Spec §3.3 note).
    /// On error, partial allocations are released by `deinit`.
    pub fn parse(self: *TalkTable, data: []const u8) (FormatError || std.mem.Allocator.Error)!void {
        if (data.len < HEADER_SIZE) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[0..4], FILE_TYPE)) return error.InvalidFileType;

        const version: Version = if (std.mem.eql(u8, data[4..8], VERSION_V3))
            .v3_0
        else if (looksLikePreV3(data[4..8]))
            .pre_v3_0
        else
            return error.InvalidVersion;

        self.language = @enumFromInt(rd32(data, 8));
        const string_count = rd32(data, 12);
        const string_entries_offset = rd32(data, 16);

        const entry_size: u32 = switch (version) {
            .v3_0 => ENTRY_SIZE_V3,
            .pre_v3_0 => ENTRY_SIZE_PRE_V3,
        };

        // Header + StringDataTable must fit in the buffer.
        if (!sectionOk(data.len, HEADER_SIZE, string_count *% entry_size)) return error.InvalidFormat;
        if (string_entries_offset < HEADER_SIZE + string_count * entry_size) return error.InvalidFormat;
        if (string_entries_offset > data.len) return error.InvalidFormat;

        try self.entries.ensureTotalCapacity(self.allocator, string_count);

        var i: u32 = 0;
        while (i < string_count) : (i += 1) {
            const base: usize = HEADER_SIZE + i * entry_size;
            var e: TalkTableEntry = .{};
            e.flags = Flags.fromU32(rd32(data, base));
            @memcpy(&e.sound_res_ref, data[base + 4 ..][0..16]);
            e.volume_variance = rd32(data, base + 20);
            e.pitch_variance = rd32(data, base + 24);
            const off_to_string = rd32(data, base + 28);
            const string_size = rd32(data, base + 32);
            e.sound_length = switch (version) {
                .v3_0 => rdf32(data, base + 36),
                .pre_v3_0 => 0.0,
            };

            if (e.flags.text_present) {
                const start: usize = @as(usize, string_entries_offset) + @as(usize, off_to_string);
                if (!sectionOk(data.len, @intCast(start), string_size)) return error.InvalidFormat;
                e.text = try self.allocator.dupe(u8, data[start..][0..string_size]);
            }
            self.entries.appendAssumeCapacity(e);
        }
    }

    // --------------------------------------------------------------- Serialize

    /// Encode this table as a `V3.0` TLK byte stream. Caller owns the
    /// returned slice and must free it with `alloc`.
    pub fn serialize(self: *const TalkTable, alloc: std.mem.Allocator) ![]u8 {
        const string_count: u32 = @intCast(self.entries.items.len);
        const string_data_size: u32 = string_count * ENTRY_SIZE_V3;
        const string_entries_offset: u32 = HEADER_SIZE + string_data_size;

        var text_total: usize = 0;
        for (self.entries.items) |e| if (e.flags.text_present) {
            text_total += e.text.len;
        };

        const total: usize = string_entries_offset + text_total;
        const out = try alloc.alloc(u8, total);
        errdefer alloc.free(out);
        @memset(out, 0);

        // Header
        @memcpy(out[0..4], FILE_TYPE);
        @memcpy(out[4..8], VERSION_V3);
        wr32(out, 8, @intFromEnum(self.language));
        wr32(out, 12, string_count);
        wr32(out, 16, string_entries_offset);

        // String data table + string entry table.
        var text_cursor: u32 = 0;
        for (self.entries.items, 0..) |e, i| {
            const base: usize = HEADER_SIZE + i * ENTRY_SIZE_V3;
            wr32(out, base, e.flags.toU32());
            @memcpy(out[base + 4 ..][0..16], &e.sound_res_ref);
            wr32(out, base + 20, e.volume_variance);
            wr32(out, base + 24, e.pitch_variance);

            if (e.flags.text_present) {
                wr32(out, base + 28, text_cursor);
                wr32(out, base + 32, @intCast(e.text.len));
                const dst_start: usize = string_entries_offset + text_cursor;
                @memcpy(out[dst_start..][0..e.text.len], e.text);
                text_cursor += @intCast(e.text.len);
            } else {
                // text_present unset: write zero offset/size for cleanliness
                // (engine ignores both fields).
                wr32(out, base + 28, 0);
                wr32(out, base + 32, 0);
            }
            wrf32(out, base + 36, e.sound_length);
        }

        return out;
    }

    // ----------------------------------------------------------------- Builder

    /// Append `entry` to the end of the table. Takes ownership of
    /// `entry.text` (caller must not free it afterwards). Returns the
    /// new entry's StrRef.
    pub fn addEntry(self: *TalkTable, entry: TalkTableEntry) !u32 {
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, entry);
        return idx;
    }

    // ------------------------------------------------------------------ Lookup

    /// Resolve a StrRef to its text. Returns null when:
    ///   * `strref == INVALID_STRREF`,
    ///   * the masked StrRef is outside the table, or
    ///   * the entry's `text_present` flag is unset.
    ///
    /// The high byte of `strref` is masked off per Spec §2.2; the
    /// `STRREF_ALT_BIT` is *not* auto-routed (see `STRREF_ALT_BIT`).
    pub fn getString(self: *const TalkTable, strref: u32) ?[]const u8 {
        if (strref == INVALID_STRREF) return null;
        const idx = strref & STRREF_MASK;
        if (idx >= self.entries.items.len) return null;
        const e = &self.entries.items[idx];
        if (!e.flags.text_present) return null;
        return e.text;
    }

    /// Pretty-print summary to stdout for debugging.
    pub fn dumpInfo(self: *const TalkTable) void {
        std.debug.print("TalkTable: language={s} count={}\n", .{
            std.enums.tagName(Language, self.language) orelse "unknown",
            self.entries.items.len,
        });
    }
};

// ============================================================================
// ExoLocString resolver
// ============================================================================

/// Resolve a `gff.ExoLocString` to a string view.
///
/// Resolution order:
///   1. The `loc.substrings` element whose `string_id` equals
///      `preferred_string_id`, if any.
///   2. `tlk.getString(loc.string_ref)`, if `tlk` is non-null.
///   3. The first available substring (any language), if any.
///   4. `null`.
///
/// Kept as a free function so the dependency arrow points
/// `tlk → gff` only.
pub fn resolveExoLoc(
    loc: gff.ExoLocString,
    preferred_string_id: u32,
    tlk: ?*const TalkTable,
) ?[]const u8 {
    for (loc.substrings.items) |ss| {
        if (ss.string_id == preferred_string_id) return ss.text;
    }
    if (tlk) |table| if (table.getString(loc.string_ref)) |s| return s;
    if (loc.substrings.items.len > 0) return loc.substrings.items[0].text;
    return null;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn sectionOk(buf_len: usize, off: u32, size: u32) bool {
    return @as(usize, off) + @as(usize, size) <= buf_len;
}

fn looksLikePreV3(s: *const [4]u8) bool {
    // Pre-3.0 versions seen in the wild use "V1.0" / "V2.0".
    if (s[0] != 'V') return false;
    if (s[2] != '.') return false;
    if (s[3] != '0' and s[3] != '1') return false;
    return std.ascii.isDigit(s[1]);
}

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}
inline fn rdf32(data: []const u8, off: usize) f32 {
    return @bitCast(rd32(data, off));
}
inline fn wr32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
inline fn wrf32(buf: []u8, off: usize, v: f32) void {
    wr32(buf, off, @bitCast(v));
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "Flags round-trip via u32" {
    const f: Flags = .{ .text_present = true, .sound_length_present = true };
    try t.expectEqual(@as(u32, 0x0005), f.toU32());
    const f2 = Flags.fromU32(0x0007);
    try t.expect(f2.text_present);
    try t.expect(f2.sound_present);
    try t.expect(f2.sound_length_present);
}

test "empty TLK round-trip" {
    const gpa = t.allocator;

    var tab = TalkTable.init(gpa);
    defer tab.deinit();
    tab.language = .french;

    const bytes = try tab.serialize(gpa);
    defer gpa.free(bytes);

    var tab2 = TalkTable.init(gpa);
    defer tab2.deinit();
    try tab2.parse(bytes);

    try t.expectEqual(Language.french, tab2.language);
    try t.expectEqual(@as(usize, 0), tab2.entries.items.len);
    try t.expectEqual(@as(usize, HEADER_SIZE), bytes.len);
}

test "TLK three-entry byte-exact round-trip" {
    const gpa = t.allocator;

    var tab = TalkTable.init(gpa);
    defer tab.deinit();
    tab.language = .english;

    // Entry 0: text + sound + length.
    var e0: TalkTableEntry = .{
        .flags = .{ .text_present = true, .sound_present = true, .sound_length_present = true },
        .sound_length = 1.5,
        .text = try gpa.dupe(u8, "Hello world"),
    };
    @memcpy(e0.sound_res_ref[0..7], "snd_hi0");

    // Entry 1: text only.
    const e1: TalkTableEntry = .{
        .flags = .{ .text_present = true },
        .text = try gpa.dupe(u8, "Just text."),
    };

    // Entry 2: sound only (no text).
    var e2: TalkTableEntry = .{
        .flags = .{ .sound_present = true },
    };
    @memcpy(e2.sound_res_ref[0..6], "snd_no");

    _ = try tab.addEntry(e0);
    _ = try tab.addEntry(e1);
    _ = try tab.addEntry(e2);

    const bytes = try tab.serialize(gpa);
    defer gpa.free(bytes);

    var tab2 = TalkTable.init(gpa);
    defer tab2.deinit();
    try tab2.parse(bytes);

    try t.expectEqual(@as(usize, 3), tab2.entries.items.len);
    try t.expectEqualStrings("Hello world", tab2.entries.items[0].text);
    try t.expectEqualStrings("snd_hi0", tab2.entries.items[0].soundResRefSlice());
    try t.expectEqual(@as(f32, 1.5), tab2.entries.items[0].sound_length);
    try t.expectEqualStrings("Just text.", tab2.entries.items[1].text);
    try t.expectEqual(@as(usize, 0), tab2.entries.items[2].text.len);
    try t.expectEqualStrings("snd_no", tab2.entries.items[2].soundResRefSlice());

    const bytes2 = try tab2.serialize(gpa);
    defer gpa.free(bytes2);
    try t.expectEqualSlices(u8, bytes, bytes2);
}

test "TLK getString masking and out-of-range" {
    const gpa = t.allocator;

    var tab = TalkTable.init(gpa);
    defer tab.deinit();

    _ = try tab.addEntry(.{
        .flags = .{ .text_present = true },
        .text = try gpa.dupe(u8, "zero"),
    });
    _ = try tab.addEntry(.{ .flags = .{} }); // text_present unset
    _ = try tab.addEntry(.{
        .flags = .{ .text_present = true },
        .text = try gpa.dupe(u8, "two"),
    });

    try t.expectEqualStrings("zero", tab.getString(0).?);
    try t.expectEqualStrings("two", tab.getString(2).?);
    try t.expectEqual(@as(?[]const u8, null), tab.getString(1));
    try t.expectEqual(@as(?[]const u8, null), tab.getString(99));
    try t.expectEqual(@as(?[]const u8, null), tab.getString(INVALID_STRREF));

    // High-byte masking: 0x01000002 -> entry 2.
    try t.expectEqualStrings("two", tab.getString(STRREF_ALT_BIT | 2).?);
    // 0xFF000000 alone (after masking, idx == 0) -> entry 0.
    try t.expectEqualStrings("zero", tab.getString(0xFF000000).?);
}

test "TLK pre-3.0 read fallback" {
    const gpa = t.allocator;

    // Hand-craft a pre-3.0 buffer: 1 entry, text "ok", no SoundLength.
    const string_count: u32 = 1;
    const entries_off: u32 = HEADER_SIZE + string_count * ENTRY_SIZE_PRE_V3;
    const text = "ok";
    const total: usize = entries_off + text.len;
    const buf = try gpa.alloc(u8, total);
    defer gpa.free(buf);
    @memset(buf, 0);

    @memcpy(buf[0..4], "TLK ");
    @memcpy(buf[4..8], "V1.0");
    wr32(buf, 8, @intFromEnum(Language.english));
    wr32(buf, 12, string_count);
    wr32(buf, 16, entries_off);

    // String Data Element (36 bytes, no SoundLength).
    const base: usize = HEADER_SIZE;
    wr32(buf, base, @as(u32, 0x0001)); // TEXT_PRESENT
    // bytes 4..20 sound_res_ref (zeroed)
    wr32(buf, base + 20, 0); // volume
    wr32(buf, base + 24, 0); // pitch
    wr32(buf, base + 28, 0); // off_to_string
    wr32(buf, base + 32, @intCast(text.len)); // string_size
    @memcpy(buf[entries_off..][0..text.len], text);

    var tab = TalkTable.init(gpa);
    defer tab.deinit();
    try tab.parse(buf);
    try t.expectEqual(@as(usize, 1), tab.entries.items.len);
    try t.expectEqualStrings("ok", tab.entries.items[0].text);
    try t.expectEqual(@as(f32, 0.0), tab.entries.items[0].sound_length);
}

test "TLK rejects bad magic and bad version" {
    const gpa = t.allocator;

    var tab = TalkTable.init(gpa);
    defer tab.deinit();
    const bytes = try tab.serialize(gpa);
    defer gpa.free(bytes);

    const bad_magic = try gpa.dupe(u8, bytes);
    defer gpa.free(bad_magic);
    @memcpy(bad_magic[0..4], "XXX ");
    var tab1 = TalkTable.init(gpa);
    defer tab1.deinit();
    try t.expectError(error.InvalidFileType, tab1.parse(bad_magic));

    const bad_ver = try gpa.dupe(u8, bytes);
    defer gpa.free(bad_ver);
    @memcpy(bad_ver[4..8], "Z9.9");
    var tab2 = TalkTable.init(gpa);
    defer tab2.deinit();
    try t.expectError(error.InvalidVersion, tab2.parse(bad_ver));
}

test "resolveExoLoc precedence" {
    const gpa = t.allocator;

    // Build a TalkTable with one entry.
    var tab = TalkTable.init(gpa);
    defer tab.deinit();
    _ = try tab.addEntry(.{
        .flags = .{ .text_present = true },
        .text = try gpa.dupe(u8, "fallback-from-tlk"),
    });

    // Build a loc with one substring (string_id 1).
    var loc: gff.ExoLocString = .{ .string_ref = 0, .substrings = .empty };
    defer loc.deinit(gpa);
    try loc.substrings.append(gpa, .{ .string_id = 1, .text = try gpa.dupe(u8, "from-substring-1") });

    // Preferred id = 1 → substring wins.
    try t.expectEqualStrings("from-substring-1", resolveExoLoc(loc, 1, &tab).?);

    // Preferred id = 2 not present → falls back to TLK string_ref=0.
    try t.expectEqualStrings("fallback-from-tlk", resolveExoLoc(loc, 2, &tab).?);

    // No TLK, preferred id absent → returns first substring (any language).
    try t.expectEqualStrings("from-substring-1", resolveExoLoc(loc, 999, null).?);

    // Empty loc, no TLK → null.
    var empty: gff.ExoLocString = .{ .string_ref = 0, .substrings = .empty };
    defer empty.deinit(gpa);
    try t.expectEqual(@as(?[]const u8, null), resolveExoLoc(empty, 0, null));
}
