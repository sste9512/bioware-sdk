//! Bioware Aurora ERF (Encapsulated Resource File) format reader and writer.
//!
//! ERF packs multiple files into a single archive.  File types using this
//! format include: .erf, .hak, .mod, .nwm, .sav
//!
//! Byte order: little-endian throughout.
//!
//! Physical layout:
//!   Header               (160 bytes)
//!   Localized String List (LocalizedStringSize bytes, variable)
//!   Key List             (EntryCount × 24 bytes)
//!   Resource List        (EntryCount × 8 bytes)
//!   Resource Data        (raw packed file data, contiguous)
const std = @import("std");
const keybif = @import("keybif.zig");

pub const ResType = keybif.ResType;

pub const FormatError = error{
    /// File version is not "V1.0".
    InvalidVersion,
    /// Data is truncated or an offset points outside the buffer.
    InvalidFormat,
};

pub const HEADER_SIZE: u32 = 160;
pub const FILE_VERSION = "V1.0";

/// The 4-byte magic identifying what kind of ERF archive this is.
pub const ErfFileType = enum(u32) {
    ERF = @bitCast([4]u8{ 'E', 'R', 'F', ' ' }),
    MOD = @bitCast([4]u8{ 'M', 'O', 'D', ' ' }),
    SAV = @bitCast([4]u8{ 'S', 'A', 'V', ' ' }),
    HAK = @bitCast([4]u8{ 'H', 'A', 'K', ' ' }),
    NWM = @bitCast([4]u8{ 'N', 'W', 'M', ' ' }),
    _,

    pub fn toBytes(self: ErfFileType) [4]u8 {
        return @bitCast(@intFromEnum(self));
    }

    pub fn fromBytes(bytes: [4]u8) ErfFileType {
        return @enumFromInt(@as(u32, @bitCast(bytes)));
    }
};

/// Language IDs used in the Localized String List.
/// The value stored on disk = 2 × language_id + gender
/// (0 = neutral/masculine, 1 = feminine).
pub const Language = enum(u32) {
    english = 0,
    french = 1,
    german = 2,
    italian = 3,
    spanish = 4,
    polish = 5,
    korean = 128,
    chinese_traditional = 129,
    chinese_simplified = 130,
    japanese = 131,
    _,

    pub fn encode(lang: Language, feminine: bool) u32 {
        return @intFromEnum(lang) * 2 + @intFromBool(feminine);
    }

    pub fn decode(encoded: u32) struct { lang: Language, feminine: bool } {
        return .{
            .lang = @enumFromInt(encoded / 2),
            .feminine = (encoded & 1) != 0,
        };
    }
};

/// One entry in the Localized String List (ERF description block).
pub const LocalizedString = struct {
    /// Encoded as 2 × language_id + gender (0 = neutral/masculine, 1 = feminine).
    language_id: u32,
    /// Text content.  Owned.
    text: []u8,
};

/// One resource packed inside the ERF.
pub const ErfEntry = struct {
    /// Filename without extension, lower case, zero-padded to 16 bytes.
    res_ref: [16]u8,
    /// Resource type (file extension).
    res_type: ResType,
    /// Raw resource bytes.  Owned.
    data: []u8,

    /// Returns the resource name trimmed of zero padding.
    pub fn resRefSlice(self: *const ErfEntry) []const u8 {
        return std.mem.sliceTo(&self.res_ref, 0);
    }

    /// Prints resource information to stdout.
    ///
    /// Example output:
    /// Resource: creature.utc
    pub fn printInfo(self: *const ErfEntry) void {
        std.debug.print("Resource: {s}.{s}\n", .{ self.resRefSlice(), self.res_type.toString() });
    }
};

// ============================================================================
// ErfFile
// ============================================================================

pub const ErfFile = struct {
    allocator: std.mem.Allocator,
    /// 4-character file type, e.g. "ERF ", "MOD ", "HAK ".
    file_type: [4]u8,
    /// Years since 1900.
    build_year: u32,
    /// Days since January 1.
    build_day: u32,
    /// StrRef into dialog.tlk for the file description, or 0xFFFFFFFF.
    description_str_ref: u32,
    /// Localized description strings (used by .mod for module descriptions).
    localized_strings: std.ArrayList(LocalizedString),
    /// Packed resources, one per file stored in the archive.
    entries: std.ArrayList(ErfEntry),

    pub fn init(allocator: std.mem.Allocator, file_type: ErfFileType) ErfFile {
        return .{
            .allocator = allocator,
            .file_type = file_type.toBytes(),
            .build_year = 0,
            .build_day = 0,
            .description_str_ref = 0xFFFF_FFFF,
            .localized_strings = .empty,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *ErfFile) void {
        for (self.localized_strings.items) |s| self.allocator.free(s.text);
        self.localized_strings.deinit(self.allocator);
        for (self.entries.items) |e| self.allocator.free(e.data);
        self.entries.deinit(self.allocator);
    }

    // ------------------------------------------------------------------ Parse

    /// Parse an ERF archive from raw bytes.
    /// On error, call `deinit` to release any partial allocations.
    pub fn parse(self: *ErfFile, data: []const u8) !void {
        if (data.len < HEADER_SIZE) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[4..8], FILE_VERSION)) return error.InvalidVersion;

        @memcpy(&self.file_type, data[0..4]);

        const lang_count = rd32(data, 8);
        const loc_string_size = rd32(data, 12);
        const entry_count = rd32(data, 16);
        const off_loc = rd32(data, 20);
        const off_key = rd32(data, 24);
        const off_res = rd32(data, 28);
        self.build_year = rd32(data, 32);
        self.build_day = rd32(data, 36);
        self.description_str_ref = rd32(data, 40);
        // data[44..160] = Reserved (116 bytes, ignored)

        // Section bounds checks
        if (!sectionOk(data.len, off_loc, loc_string_size)) return error.InvalidFormat;
        if (!sectionOk(data.len, off_key, entry_count * 24)) return error.InvalidFormat;
        if (!sectionOk(data.len, off_res, entry_count * 8)) return error.InvalidFormat;

        // -- Localized String List --
        var pos: usize = off_loc;
        const str_end: usize = off_loc + loc_string_size;
        for (0..lang_count) |_| {
            if (pos + 8 > str_end) return error.InvalidFormat;
            const lang_id = rd32(data, pos);
            const str_size = rd32(data, pos + 4);
            pos += 8;
            if (pos + str_size > str_end) return error.InvalidFormat;
            const text = try self.allocator.dupe(u8, data[pos..][0..str_size]);
            errdefer self.allocator.free(text);
            try self.localized_strings.append(self.allocator, .{
                .language_id = lang_id,
                .text = text,
            });
            pos += str_size;
        }

        // -- Key List + Resource List --
        var kt: usize = off_key;
        var rt: usize = off_res;
        for (0..entry_count) |_| {
            // Key entry (24 bytes)
            var res_ref: [16]u8 = undefined;
            @memcpy(&res_ref, data[kt..][0..16]);
            // kt+16..20 = ResID (redundant, skip)
            const res_type: ResType = @enumFromInt(rd16(data, kt + 20));
            // kt+22..24 = Unused
            kt += 24;

            // Resource entry (8 bytes)
            const offset = rd32(data, rt + 0);
            const size = rd32(data, rt + 4);
            rt += 8;

            if (!sectionOk(data.len, offset, size)) return error.InvalidFormat;
            const entry_data = try self.allocator.dupe(u8, data[offset..][0..size]);
            errdefer self.allocator.free(entry_data);

            try self.entries.append(self.allocator, .{
                .res_ref = res_ref,
                .res_type = res_type,
                .data = entry_data,
            });
        }
    }

    // --------------------------------------------------------------- Serialize

    /// Serialize this ErfFile to a newly-allocated byte slice.
    /// Caller owns the returned memory.
    pub fn serialize(self: *const ErfFile, allocator: std.mem.Allocator) ![]u8 {
        const entry_count: u32 = @intCast(self.entries.items.len);
        const lang_count: u32 = @intCast(self.localized_strings.items.len);

        // Total size of the Localized String section
        var loc_string_size: u32 = 0;
        for (self.localized_strings.items) |s| {
            loc_string_size += 8 + @as(u32, @intCast(s.text.len));
        }

        const off_loc: u32 = HEADER_SIZE;
        const off_key: u32 = off_loc + loc_string_size;
        const off_res: u32 = off_key + entry_count * 24;
        const off_data: u32 = off_res + entry_count * 8;

        var data_total: usize = 0;
        for (self.entries.items) |e| data_total += e.data.len;

        const total: usize = off_data + data_total;
        const out = try allocator.alloc(u8, total);
        errdefer allocator.free(out);
        @memset(out, 0);

        // Header
        @memcpy(out[0..4], &self.file_type);
        @memcpy(out[4..8], FILE_VERSION);
        wr32(out, 8, lang_count);
        wr32(out, 12, loc_string_size);
        wr32(out, 16, entry_count);
        wr32(out, 20, off_loc);
        wr32(out, 24, off_key);
        wr32(out, 28, off_res);
        wr32(out, 32, self.build_year);
        wr32(out, 36, self.build_day);
        wr32(out, 40, self.description_str_ref);
        // out[44..160] already zeroed (Reserved)

        // Localized String List
        var sp: usize = off_loc;
        for (self.localized_strings.items) |s| {
            wr32(out, sp + 0, s.language_id);
            wr32(out, sp + 4, @intCast(s.text.len));
            @memcpy(out[sp + 8 ..][0..s.text.len], s.text);
            sp += 8 + s.text.len;
        }

        // Key List + Resource List + Resource Data
        var kt: usize = off_key;
        var rt: usize = off_res;
        var dp: usize = off_data;
        for (self.entries.items, 0..) |e, res_id| {
            // Key entry
            @memcpy(out[kt..][0..16], &e.res_ref);
            wr32(out, kt + 16, @intCast(res_id));
            wr16(out, kt + 20, @intFromEnum(e.res_type));
            // out[kt+22..kt+24] already zeroed (Unused)
            kt += 24;

            // Resource entry
            wr32(out, rt + 0, @intCast(dp));
            wr32(out, rt + 4, @intCast(e.data.len));
            rt += 8;

            @memcpy(out[dp..][0..e.data.len], e.data);
            dp += e.data.len;
        }

        return out;
    }

    // ----------------------------------------------------------------- Builder

    /// Add a resource to the archive.  `res_ref` must be ≤ 16 bytes, lower case.
    /// Takes ownership of `data` (caller must not free it afterwards).
    pub fn addEntry(
        self: *ErfFile,
        res_ref: []const u8,
        res_type: ResType,
        data: []u8,
    ) !void {
        std.debug.assert(res_ref.len <= 16);
        var ref: [16]u8 = [_]u8{0} ** 16;
        @memcpy(ref[0..res_ref.len], res_ref);
        try self.entries.append(self.allocator, .{
            .res_ref = ref,
            .res_type = res_type,
            .data = data,
        });
    }

    /// Add a localized description string.
    /// Takes ownership of `text` (caller must not free it afterwards).
    pub fn addLocalizedString(
        self: *ErfFile,
        language_id: u32,
        text: []u8,
    ) !void {
        try self.localized_strings.append(self.allocator, .{
            .language_id = language_id,
            .text = text,
        });
    }

    // ------------------------------------------------------------------ Query

    /// Find the first entry matching `res_ref` and `res_type`, or null.
    pub fn findEntry(
        self: *const ErfFile,
        res_ref: []const u8,
        res_type: ResType,
    ) ?*const ErfEntry {
        for (self.entries.items) |*e| {
            if (e.res_type == res_type and
                std.mem.eql(u8, e.resRefSlice(), res_ref))
            {
                return e;
            }
        }
        return null;
    }

    /// Return the first localized string for the given encoded language_id, or null.
    pub fn getLocalizedString(self: *const ErfFile, language_id: u32) ?[]const u8 {
        for (self.localized_strings.items) |s| {
            if (s.language_id == language_id) return s.text;
        }
        return null;
    }

    /// Prints ERF file information to stdout.
    ///
    /// Example output:
    /// ERF File: ERF
    /// Build Year: 123
    /// Build Day: 456
    /// Description StrRef: 789
    /// Localized Strings: 2
    /// Entries: 3
    /// Resource: creature.utc
    /// Resource: dialog.tlk
    /// Resource: module.mod
    pub fn dumpInfo(self: *const ErfFile) void {
        std.debug.print("ERF File: {s}\n", .{self.file_type});
        std.debug.print("Build Year: {}\n", .{self.build_year});
        std.debug.print("Build Day: {}\n", .{self.build_day});
        std.debug.print("Description StrRef: {}\n", .{self.description_str_ref});
        std.debug.print("Localized Strings: {}\n", .{self.localized_strings.items.len});
        std.debug.print("Entries: {}\n", .{self.entries.items.len});
        for (self.entries.items) |*e| {
            e.printInfo();
        }
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

fn sectionOk(buf_len: usize, off: u32, size: u32) bool {
    return @as(usize, off) + @as(usize, size) <= buf_len;
}

inline fn rd16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .little);
}

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

inline fn wr16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

inline fn wr32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty ERF round-trip" {
    const gpa = t.allocator;

    var erf = ErfFile.init(gpa, "ERF ".*);
    defer erf.deinit();

    const bytes = try erf.serialize(gpa);
    defer gpa.free(bytes);

    var erf2 = ErfFile.init(gpa, "ERF ".*);
    defer erf2.deinit();
    try erf2.parse(bytes);

    try t.expectEqualSlices(u8, "ERF ", &erf2.file_type);
    try t.expectEqual(@as(usize, 0), erf2.entries.items.len);
    try t.expectEqual(@as(usize, 0), erf2.localized_strings.items.len);
}

test "ERF entries round-trip" {
    const gpa = t.allocator;

    var erf = ErfFile.init(gpa, "HAK ".*);
    defer erf.deinit();

    erf.build_year = 104;
    erf.build_day = 200;

    try erf.addEntry("nw_chicken", .utc, try gpa.dupe(u8, "creature data here"));
    try erf.addEntry("my_script", .nss, try gpa.dupe(u8, "void main() {}"));
    try erf.addEntry("tileset01", .@"2da", try gpa.dupe(u8, "2DA V2.0\n"));

    const bytes = try erf.serialize(gpa);
    defer gpa.free(bytes);

    var erf2 = ErfFile.init(gpa, "HAK ".*);
    defer erf2.deinit();
    try erf2.parse(bytes);

    try t.expectEqualSlices(u8, "HAK ", &erf2.file_type);
    try t.expectEqual(@as(u32, 104), erf2.build_year);
    try t.expectEqual(@as(u32, 200), erf2.build_day);
    try t.expectEqual(@as(usize, 3), erf2.entries.items.len);

    try t.expectEqualStrings("nw_chicken", erf2.entries.items[0].resRefSlice());
    try t.expectEqual(ResType.utc, erf2.entries.items[0].res_type);
    try t.expectEqualSlices(u8, "creature data here", erf2.entries.items[0].data);

    try t.expectEqualStrings("my_script", erf2.entries.items[1].resRefSlice());
    try t.expectEqual(ResType.nss, erf2.entries.items[1].res_type);
    try t.expectEqualSlices(u8, "void main() {}", erf2.entries.items[1].data);

    // Byte-exact round-trip
    const bytes2 = try erf2.serialize(gpa);
    defer gpa.free(bytes2);
    try t.expectEqualSlices(u8, bytes, bytes2);
}

test "ERF localized strings round-trip" {
    const gpa = t.allocator;

    var erf = ErfFile.init(gpa, "MOD ".*);
    defer erf.deinit();

    erf.description_str_ref = 42;
    // English neutral (0 * 2 + 0 = 0), French feminine (1 * 2 + 1 = 3)
    try erf.addLocalizedString(Language.encode(.english, false), try gpa.dupe(u8, "My Module"));
    try erf.addLocalizedString(Language.encode(.french, true), try gpa.dupe(u8, "Mon Module"));

    const bytes = try erf.serialize(gpa);
    defer gpa.free(bytes);

    var erf2 = ErfFile.init(gpa, "MOD ".*);
    defer erf2.deinit();
    try erf2.parse(bytes);

    try t.expectEqual(@as(u32, 42), erf2.description_str_ref);
    try t.expectEqual(@as(usize, 2), erf2.localized_strings.items.len);
    try t.expectEqual(@as(u32, 0), erf2.localized_strings.items[0].language_id);
    try t.expectEqualStrings("My Module", erf2.localized_strings.items[0].text);
    try t.expectEqual(@as(u32, 3), erf2.localized_strings.items[1].language_id);
    try t.expectEqualStrings("Mon Module", erf2.localized_strings.items[1].text);

    try t.expectEqualStrings(
        "My Module",
        erf2.getLocalizedString(Language.encode(.english, false)).?,
    );
}

test "ERF findEntry" {
    const gpa = t.allocator;

    var erf = ErfFile.init(gpa, "ERF ".*);
    defer erf.deinit();

    try erf.addEntry("sword01", .uti, try gpa.dupe(u8, "item data"));
    try erf.addEntry("guard", .utc, try gpa.dupe(u8, "creature data"));

    try t.expect(erf.findEntry("sword01", .uti) != null);
    try t.expect(erf.findEntry("guard", .utc) != null);
    try t.expect(erf.findEntry("sword01", .utc) == null);
    try t.expect(erf.findEntry("missing", .uti) == null);
}

test "ERF invalid version" {
    const gpa = t.allocator;

    var erf = ErfFile.init(gpa, "ERF ".*);
    defer erf.deinit();
    const bytes = try erf.serialize(gpa);
    defer gpa.free(bytes);

    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[4..8], "V1.1");

    var erf2 = ErfFile.init(gpa, "ERF ".*);
    defer erf2.deinit();
    try t.expectError(error.InvalidVersion, erf2.parse(mut));
}

test "ERF truncated header" {
    const gpa = t.allocator;
    var tiny: [10]u8 = undefined;

    var erf = ErfFile.init(gpa, "ERF ".*);
    defer erf.deinit();
    try t.expectError(error.InvalidFormat, erf.parse(&tiny));
}

test "Language encode/decode" {
    const enc = Language.encode(.french, true);
    try t.expectEqual(@as(u32, 3), enc);
    const dec = Language.decode(enc);
    try t.expectEqual(Language.french, dec.lang);
    try t.expect(dec.feminine);

    const enc2 = Language.encode(.english, false);
    try t.expectEqual(@as(u32, 0), enc2);
    const dec2 = Language.decode(enc2);
    try t.expectEqual(Language.english, dec2.lang);
    try t.expect(!dec2.feminine);
}
