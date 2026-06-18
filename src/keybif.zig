//! Bioware Aurora KEY/BIF file format reader and writer.
//!
//! KEY files are indexes that map resource names to their locations inside a
//! set of BIF archive files.  BIF files contain the raw resource data.
//!
//! Byte order: all multi-byte integers are little-endian.
//!
//! KEY layout:
//!   Header (64 bytes)
//!   File Table   (BIFCount × 12 bytes)
//!   Filename Table (variable – referenced by File Table entries)
//!   Key Table    (KeyCount  × 22 bytes)
//!
//! BIF layout:
//!   Header (20 bytes)
//!   Variable Resource Table (VarCount × 16 bytes)
//!   [Fixed Resource Table – not implemented by the engine]
//!   Variable Resource Data
const std = @import("std");

// ============================================================================
// Resource type constants
// ============================================================================

/// Resource type values used throughout the Aurora engine.
/// Values 0–2999, 9000–9999, and 0xFFFF are reserved by BioWare.
pub const ResType = enum(u16) {
    invalid = 0xFFFF,
    bmp = 1,
    tga = 3,
    wav = 4,
    plt = 6,
    ini = 7,
    txt = 10,
    mdl = 2002,
    nss = 2009,
    ncs = 2010,
    are = 2012,
    set = 2013,
    ifo = 2014,
    bic = 2015,
    wok = 2016,
    @"2da" = 2017,
    tlk = 2018,
    txi = 2022,
    git = 2023,
    uti = 2025,
    utc = 2027,
    dlg = 2029,
    itp = 2030,
    utt = 2032,
    dds = 2033,
    uts = 2035,
    ltr = 2036,
    gff = 2037,
    fac = 2038,
    ute = 2040,
    utd = 2042,
    utp = 2044,
    dft = 2045,
    gic = 2046,
    gui = 2047,
    utm = 2051,
    dwk = 2052,
    pwk = 2053,
    jrl = 2056,
    utw = 2058,
    ssf = 2060,
    ndb = 2064,
    ptm = 2065,
    ptt = 2066,
    mdx = 3008,
    _,

    // TODO: Fix this for erfs, all types are printing "unknown"
    pub fn toString(self: ResType) []const u8 {
        return std.enums.tagName(ResType, self) orelse "unknown";
    }
};

pub const FormatError = error{
    /// File magic ("KEY " / "BIFF") does not match.
    InvalidFileType,
    /// Version string ("V1  ") does not match.
    InvalidVersion,
    /// The data is truncated or an offset points outside the buffer.
    InvalidFormat,
};

// ============================================================================
// KEY File
// ============================================================================

/// In-memory representation of a Bioware Aurora KEY file.
///
/// Usage: `init` → `parse` (read) or build entries then `serialize` (write).
/// Always call `deinit` to release memory.
pub const KeyFile = struct {
    allocator: std.mem.Allocator,
    /// Years since 1900.
    build_year: u32,
    /// Days since January 1.
    build_day: u32,
    /// File Table – one entry per associated BIF archive.
    bif_entries: std.ArrayList(BifEntry),
    /// Key Table – one entry per resource across all BIFs.
    key_entries: std.ArrayList(KeyEntry),

    /// On-disk file type / version magic bytes.
    pub const FILE_TYPE = "KEY ";
    pub const FILE_VERSION = "V1  ";

    /// Describes one BIF archive associated with this KEY file.
    pub const BifEntry = struct {
        /// File size of the BIF archive in bytes.
        file_size: u32,
        /// Drive bitmask (bit 0 = HD0, the install directory).
        drives: u16,
        /// Relative path to the BIF, e.g. `"data\2da.bif"`.  Owned.
        filename: []u8,

        pub fn fileNameToString(self: *const BifEntry) []const u8 {
            return self.filename;
        }

        pub fn fileNameNormalized(self: *const BifEntry, allocator: std.mem.Allocator) ![]u8 {
            const trimmed = std.mem.sliceTo(self.filename, 0); // stop at first NUL
            const result = try allocator.dupe(u8, trimmed);
            std.mem.replaceScalar(u8, result, '\\', '/');
            return result;
        }

        pub fn readBytes(self: *const BifEntry, base_chitin_path: []const u8, io: std.Io) ![]u8 {
            std.debug.print("Path name {s}\n", .{base_chitin_path});
            const npath = try self.fileNameNormalized(std.heap.page_allocator);
            std.debug.print("Entry Path {s}\n", .{npath});

            const joined_path = std.Io.Dir.path.join(std.heap.page_allocator, &.{ base_chitin_path, npath }) catch return error.OutOfMemory;
            defer std.heap.page_allocator.free(joined_path);
            std.debug.print("Joined Path {s}\n", .{joined_path});

            return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, joined_path, std.heap.page_allocator, .unlimited);
        }

        // Convenience method to immediately link to associated BIF file
        pub fn bifFromEntry(entry: *const BifEntry, base_chitin_path: []const u8, io: std.Io) !BifFile {
            const bytes = try entry.readBytes(base_chitin_path, io);
            errdefer {
                //std.debug.print("Error reading BIF: {s}\n at path {s}\n", .{ @errorName(err), entry.filename });
                std.heap.page_allocator.free(bytes);
            }
            var bif = BifFile.init(std.heap.page_allocator);
            try bif.parse(bytes);
            return bif;
        }

        pub fn deinit(self: *BifEntry) void {
            self.allocator.free(self.filename);
        }
    };

    /// Describes one resource stored inside a BIF archive.
    pub const KeyEntry = struct {
        /// Resource name without extension, zero-padded to 16 bytes.
        res_ref: [16]u8,
        /// Resource type.
        res_type: ResType,
        /// Packed ID: `(bif_index << 20) | var_index_in_bif`.
        res_id: u32,

        /// Returns the resource name trimmed of zero padding.
        pub fn resRefSlice(self: *const KeyEntry) []const u8 {
            return std.mem.sliceTo(&self.res_ref, 0);
        }

        /// BIF File Table index encoded in `res_id`.
        pub fn bifIndex(self: *const KeyEntry) u32 {
            return self.res_id >> 20;
        }

        /// VariaFble resource index within the BIF encoded in `res_id`.
        pub fn varIndex(self: *const KeyEntry) u32 {
            return self.res_id & 0x000F_FFF;
        }

        pub fn getResourceName(self: *const KeyEntry) []const u8 {
            return self.resRefSlice();
        }

        pub fn getBiffForResId(self: *const KeyEntry, key_file: *KeyFile) *BifEntry {
            const bif_index = self.bifIndex();
            return &key_file.bif_entries.items[bif_index];
        }
    };

    pub fn init(allocator: std.mem.Allocator) KeyFile {
        return .{
            .allocator = allocator,
            .build_year = 0,
            .build_day = 0,
            .bif_entries = .empty,
            .key_entries = .empty,
        };
    }

    pub fn deinit(self: *KeyFile) void {
        for (self.bif_entries.items) |e| self.allocator.free(e.filename);
        self.bif_entries.deinit(self.allocator);
        self.key_entries.deinit(self.allocator);
    }

    pub fn scanForResourceByName(self: *KeyFile, name: []const u8, resType: ResType) !?*const anyopaque {
        var key: KeyEntry = undefined;
        for (self.key_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.resRefSlice(), name) and entry.res_type == resType) {
                key = entry.*;
                break;
            }
        }
        const bif = key.getBiffForResId(self);
        const bifFile = try bif.bifFromEntry();
        for (bifFile.resources.items) |*entry| {
            if (std.mem.eql(u8, entry.res_type, key.res_type) and std.mem.eql(u8, entry.res_ref, key.resRefSlice())) {
                switch (entry.res_type) {
                    .are => {
                        // TODO: Load ARE resource
                    },
                    .git => {
                        // TODO: Load GIT resource
                    },
                    .ut => {
                        // TODO: Load UT* resource
                    },
                    else => {
                        // TODO: Load other resource types
                    },
                }
            }
        }

        return null;
    }

    /// Parse a KEY file from its raw bytes.
    /// On error, call `deinit` to free any partial allocations.
    pub fn parse(self: *KeyFile, data: []const u8) !void {
        if (data.len < 64) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[0..4], FILE_TYPE)) return error.InvalidFileType;
        if (!std.mem.eql(u8, data[4..8], FILE_VERSION)) return error.InvalidVersion;

        const bif_count = rd32(data, 8);
        const key_count = rd32(data, 12);
        const file_table_off = rd32(data, 16);
        const key_table_off = rd32(data, 20);
        self.build_year = rd32(data, 24);
        self.build_day = rd32(data, 28);
        // data[32..64] = reserved

        // ---- File Table + Filename Table -----------------------------------
        var ft = file_table_off;
        for (0..bif_count) |_| {
            if (ft + 12 > data.len) return error.InvalidFormat;
            const file_size = rd32(data, ft + 0);
            const fname_off = rd32(data, ft + 4);
            const fname_size = rd16(data, ft + 8);
            const drives = rd16(data, ft + 10);
            ft += 12; //about:blank#blocked

            if (fname_off + fname_size > data.len) return error.InvalidFormat;
            const fname = try self.allocator.dupe(u8, data[fname_off..][0..fname_size]);
            errdefer self.allocator.free(fname);

            try self.bif_entries.append(self.allocator, .{
                .file_size = file_size,
                .drives = drives,
                .filename = fname,
            });
        }

        // ---- Key Table -----------------------------------------------------
        var kt = key_table_off;
        for (0..key_count) |_| {
            if (kt + 22 > data.len) return error.InvalidFormat;
            var entry: KeyEntry = undefined;
            entry.res_ref = data[kt..][0..16].*;
            entry.res_type = @enumFromInt(rd16(data, kt + 16));
            entry.res_id = rd32(data, kt + 18);
            kt += 22;
            try self.key_entries.append(self.allocator, entry);
        }
    }

    /// Serialize this KeyFile to a newly-allocated byte slice.
    /// Caller owns the returned memory.
    pub fn serialize(self: *const KeyFile, allocator: std.mem.Allocator) ![]u8 {
        const bif_count: u32 = @intCast(self.bif_entries.items.len);
        const key_count: u32 = @intCast(self.key_entries.items.len);

        var fname_total: u32 = 0;
        for (self.bif_entries.items) |e| fname_total += @intCast(e.filename.len);

        const header_size: u32 = 64;
        const file_table_off: u32 = header_size;
        const file_table_size: u32 = bif_count * 12;
        const fname_table_off: u32 = file_table_off + file_table_size;
        const key_table_off: u32 = fname_table_off + fname_total;
        const key_table_size: u32 = key_count * 22;
        const total: usize = key_table_off + key_table_size;

        const out = try allocator.alloc(u8, total);
        errdefer allocator.free(out);
        @memset(out, 0);

        // Header
        @memcpy(out[0..4], FILE_TYPE);
        @memcpy(out[4..8], FILE_VERSION);
        wr32(out, 8, bif_count);
        wr32(out, 12, key_count);
        wr32(out, 16, file_table_off);
        wr32(out, 20, key_table_off);
        wr32(out, 24, self.build_year);
        wr32(out, 28, self.build_day);
        // reserved bytes already zeroed

        // File Table + Filename Table
        var ft: usize = file_table_off;
        var fn_pos: usize = fname_table_off;
        for (self.bif_entries.items) |e| {
            wr32(out, ft + 0, e.file_size);
            wr32(out, ft + 4, @intCast(fn_pos));
            wr16(out, ft + 8, @intCast(e.filename.len));
            wr16(out, ft + 10, e.drives);
            ft += 12;

            @memcpy(out[fn_pos..][0..e.filename.len], e.filename);
            fn_pos += e.filename.len;
        }

        // Key Table
        var kt: usize = key_table_off;
        for (self.key_entries.items) |e| {
            @memcpy(out[kt..][0..16], &e.res_ref);
            wr16(out, kt + 16, @intFromEnum(e.res_type));
            wr32(out, kt + 18, e.res_id);
            kt += 22;
        }

        return out;
    }

    /// Find the first KeyEntry matching `res_ref` and `res_type`, or null.
    /// The returned pointer is valid until the key_entries list is mutated.
    pub fn findEntry(
        self: *const KeyFile,
        res_ref: []const u8,
        res_type: ResType,
    ) ?*const KeyEntry {
        for (self.key_entries.items) |*e| {
            if (e.res_type == res_type and
                std.mem.eql(u8, e.resRefSlice(), res_ref))
            {
                return e;
            }
        }
        return null;
    }

    pub fn dumpInfo(self: *const KeyFile) void {
        std.log.info("KeyFile info:", .{});
        std.log.info("  BIF entries: {d}", .{self.bif_entries.items.len});
        std.log.info("  Key entries: {d}", .{self.key_entries.items.len});

        std.log.info("  Build year: {d}, Build day: {d}", .{ self.build_year, self.build_day });

        std.log.info("BIF Table:", .{});
        std.log.info("+------------+------------+------------+--------------------------------+", .{});
        std.log.info("| Index      | File Size  | Drives     | Filename                       |", .{});
        std.log.info("+------------+------------+------------+--------------------------------+", .{});
        for (self.bif_entries.items, 0..) |e, i| {
            std.log.info("| {d:>10} | {d:>10} | {d:>10} | {s:<30} |", .{ i, e.file_size, e.drives, e.filename });
        }
        std.log.info("+------------+------------+------------+--------------------------------+", .{});

        std.log.info("Key Table:", .{});
        std.log.info("+------------+------------------+------------+------------+------------+", .{});
        std.log.info("| Index      | ResRef           | Type       | BIF Index  | Var Index  |", .{});
        std.log.info("+------------+------------------+------------+------------+------------+", .{});
        for (self.key_entries.items, 0..) |e, i| {
            var num_buf: [12]u8 = undefined;
            const type_str: []const u8 = std.enums.tagName(ResType, e.res_type) orelse
                std.fmt.bufPrint(&num_buf, "0x{x:0>4}", .{@intFromEnum(e.res_type)}) catch "?";
            std.log.info("| {d:>10} | {s:<16} | {s:>10} | {d:>10} | {d:>10} |", .{ i, e.resRefSlice(), type_str, e.bifIndex(), e.varIndex() });
        }
        std.log.info("+------------+------------------+------------+------------+------------+", .{});
    }
};

// ============================================================================
// BIF File
// ============================================================================

/// In-memory representation of a Bioware Aurora BIF archive.
///
/// Usage: `init` → `parse` (read) or build resources then `serialize` (write).
/// Always call `deinit` to release memory.
pub const BifFile = struct {
    allocator: std.mem.Allocator,
    /// Variable resource entries with their data.
    resources: std.ArrayList(VarResource),

    /// On-disk file type / version magic bytes.
    pub const FILE_TYPE = "BIFF";
    pub const FILE_VERSION = "V1  ";

    /// A variable-length resource stored in the BIF.
    pub const VarResource = struct {
        /// Packed ID: `(bif_index_or_0 << 20) | entry_index`.
        id: u32,
        /// Resource type.
        res_type: ResType,
        /// Raw resource bytes.  Owned.
        data: []u8,

        /// Variable resource index (lower 20 bits of `id`).
        pub fn index(self: *const VarResource) u32 {
            return self.id & 0x000F_FFFF;
        }

        /// Short file-extension form of the resource type, e.g. `"uti"`,
        /// `"2da"`, `"mdl"`. Returns `"unknown"` for `ResType` values that
        /// are not in the enum (this is a non-exhaustive enum). Use
        /// `descriptiveFileType` for a human-readable long-form name.
        pub fn fileExtension(self: *const VarResource) []const u8 {
            return self.res_type.toString();
        }

        /// Full / descriptive name of the resource file type, e.g.
        /// `"Item Blueprint (UTI)"`, `"2D Array (2DA)"`. Falls back to the
        /// short extension or a hex value for unknown types.
        pub fn descriptiveFileType(self: *const VarResource) []const u8 {
            return switch (self.res_type) {
                .bmp => "Windows Bitmap (BMP)",
                .tga => "Targa Image (TGA)",
                .wav => "Wave Audio (WAV)",
                .plt => "Packed Layered Texture (PLT)",
                .ini => "INI Config (INI)",
                .txt => "Plain Text (TXT)",
                .mdl => "Model (MDL)",
                .nss => "Script Source (NSS)",
                .ncs => "Compiled Script (NCS)",
                .are => "Area (ARE)",
                .set => "Tile Set (SET)",
                .ifo => "Module Info (IFO)",
                .bic => "Character (BIC)",
                .wok => "Walkmesh (WOK)",
                .@"2da" => "2D Array (2DA)",
                .tlk => "Talk Table (TLK)",
                .txi => "Texture Info (TXI)",
                .git => "Area Instance Layout (GIT)",
                .uti => "Item Blueprint (UTI)",
                .utc => "Creature Blueprint (UTC)",
                .dlg => "Dialog (DLG)",
                .itp => "Item Palette (ITP)",
                .utt => "Trigger Blueprint (UTT)",
                .dds => "DirectDraw Surface (DDS)",
                .uts => "Sound Blueprint (UTS)",
                .ltr => "Letter Combo Probabilities (LTR)",
                .gff => "Generic File Format (GFF)",
                .fac => "Faction (FAC)",
                .ute => "Encounter Blueprint (UTE)",
                .utd => "Door Blueprint (UTD)",
                .utp => "Placeable Blueprint (UTP)",
                .dft => "Default Values (DFT)",
                .gic => "Area Comments (GIC)",
                .gui => "GUI Layout (GUI)",
                .utm => "Store Blueprint (UTM)",
                .dwk => "Door Walkmesh (DWK)",
                .pwk => "Placeable Walkmesh (PWK)",
                .jrl => "Journal (JRL)",
                .utw => "Waypoint Blueprint (UTW)",
                .ssf => "Sound Set File (SSF)",
                .ndb => "Script Debugger Info (NDB)",
                .ptm => "Plot Manager (PTM)",
                .ptt => "Plot Wizard (PTT)",
                .mdx => "Model Extension (MDX)",
                .invalid => "Invalid",
                _ => "Unknown",
            };
        }

        pub fn bytesAsSlice(self: *const VarResource) ?[]const u8 {
            return self.data;
        }
    };

    pub fn init(allocator: std.mem.Allocator) BifFile {
        return .{
            .allocator = allocator,
            .resources = .empty,
        };
    }

    pub fn deinit(self: *BifFile) void {
        for (self.resources.items) |r| self.allocator.free(r.data);
        self.resources.deinit(self.allocator);
    }

    pub fn fromBifEntry(bif_entry: *const KeyFile.BifEntry) !*BifFile {
        // TODO: Load BIF file from disk
        const bif = BifFile.init(std.heap.page_allocator);
        const result = bif.parse(bif_entry.data);
        if (result) |err| return err;
        return bif;
    }

    /// Parse a BIF file from its raw bytes.
    /// On error, call `deinit` to free any partial allocations.
    pub fn parse(self: *BifFile, data: []const u8) !void {
        if (data.len < 20) return error.InvalidFormat;
        if (!std.mem.eql(u8, data[0..4], FILE_TYPE)) return error.InvalidFileType;
        if (!std.mem.eql(u8, data[4..8], FILE_VERSION)) return error.InvalidVersion;

        const var_count = rd32(data, 8);
        // data[12..16] = fixed_count (not implemented by engine – skip)
        const var_table_off = rd32(data, 16);

        // Variable Resource Table: 16 bytes per entry
        var pos: usize = var_table_off;
        for (0..var_count) |_| {
            if (pos + 16 > data.len) return error.InvalidFormat;

            const id = rd32(data, pos + 0);
            const offset = rd32(data, pos + 4);
            const file_size = rd32(data, pos + 8);
            const res_type = rd32(data, pos + 12);
            pos += 16;

            if (offset + file_size > data.len) return error.InvalidFormat;
            const res_data = try self.allocator.dupe(u8, data[offset..][0..file_size]);
            errdefer self.allocator.free(res_data);

            try self.resources.append(self.allocator, .{
                .id = id,
                .res_type = @enumFromInt(@as(u16, @truncate(res_type))),
                .data = res_data,
            });
        }
    }

    /// Serialize this BifFile to a newly-allocated byte slice.
    /// Caller owns the returned memory.
    pub fn serialize(self: *const BifFile, allocator: std.mem.Allocator) ![]u8 {
        const var_count: u32 = @intCast(self.resources.items.len);
        const var_table_off: u32 = 20;
        const var_table_size: u32 = var_count * 16;

        var data_total: usize = 0;
        for (self.resources.items) |r| data_total += r.data.len;

        const total: usize = var_table_off + var_table_size + data_total;
        const out = try allocator.alloc(u8, total);
        errdefer allocator.free(out);
        @memset(out, 0);

        // Header
        @memcpy(out[0..4], FILE_TYPE);
        @memcpy(out[4..8], FILE_VERSION);
        wr32(out, 8, var_count);
        wr32(out, 12, 0); // fixed_count = 0
        wr32(out, 16, var_table_off);

        // Variable Resource Table + Data
        var vt: usize = var_table_off;
        var dp: usize = var_table_off + var_table_size;
        for (self.resources.items) |r| {
            wr32(out, vt + 0, r.id);
            wr32(out, vt + 4, @intCast(dp));
            wr32(out, vt + 8, @intCast(r.data.len));
            wr32(out, vt + 12, @as(u32, @intFromEnum(r.res_type)));
            vt += 16;

            @memcpy(out[dp..][0..r.data.len], r.data);
            dp += r.data.len;
        }

        return out;
    }

    /// Return the data for the resource whose variable index matches `var_index`,
    /// or null if not found.
    pub fn getByIndex(self: *const BifFile, var_index: u32) ?[]const u8 {
        for (self.resources.items) |r| {
            if (r.index() == var_index) return r.data;
        }
        return null;
    }

    pub fn getResourceCount(self: *const BifFile) u32 {
        return @intCast(self.resources.items.len);
    }

    pub fn getResourceById(self: *const BifFile, id: u32) ?[]const u8 {
        for (self.resources.items) |r| {
            if (r.id == id) return r.data;
        }
        return null;
    }

    pub fn getResourceByIndex(self: *const BifFile, index: u32) ?[]const u8 {
        if (index >= self.resources.items.len) return null;
        return self.resources.items[index].data;
    }

    /// Look up the `VarResource` that a given `KeyFile.KeyEntry` points at.
    ///
    /// The KEY entry's `res_id` encodes `(bif_index << 20) | var_index`. This
    /// function uses only the low 20 bits (the var index inside *this* BIF) and
    /// also validates the resource type matches. Caller is responsible for
    /// ensuring `entry` actually belongs to this BIF (i.e. its `bifIndex()`
    /// matches the File Table slot that loaded this archive).
    ///
    /// Returns a pointer into `self.resources` (valid until the list is
    /// mutated), or `null` if no matching entry exists.
    pub fn getByKeyEntry(
        self: *const BifFile,
        entry: *const KeyFile.KeyEntry,
    ) ?*const VarResource {
        const want_index = entry.varIndex();
        for (self.resources.items) |*r| {
            if (r.index() == want_index and r.res_type == entry.res_type) {
                return r;
            }
        }
        return null;
    }

    /// Convenience wrapper: resolve `res_ref` + `res_type` against `key_file`
    /// first, then fetch the corresponding `VarResource` from this BIF.
    ///
    /// Returns `null` if either the KEY lookup fails or the BIF has no resource
    /// at the requested var index. The match is case-sensitive on `res_ref` (in
    /// line with `KeyFile.findEntry`).
    pub fn getByKeyName(
        self: *const BifFile,
        key_file: *const KeyFile,
        res_ref: []const u8,
        res_type: ResType,
    ) ?*const VarResource {
        const entry = key_file.findEntry(res_ref, res_type) orelse return null;
        return self.getByKeyEntry(entry);
    }

    pub fn dumpResourceTable(self: *const BifFile, writer: *std.Io.Writer) !void {
        try writer.print("+------------+------------+------------+------------+\n", .{});
        try writer.print("| Index      | ID         | Type       | Size       |\n", .{});
        try writer.print("+------------+------------+------------+------------+\n", .{});
        for (self.resources.items, 0..) |r, i| {
            // ResType is non-exhaustive; @tagName would panic on unknown values.
            var num_buf: [12]u8 = undefined;
            const type_str: []const u8 = std.enums.tagName(ResType, r.res_type) orelse
                std.fmt.bufPrint(&num_buf, "0x{x:0>4}", .{@intFromEnum(r.res_type)}) catch "?";
            try writer.print("| {d:>10} | {d:>10} | {s:>10} | {d:>10} |\n", .{
                i,
                r.id,
                type_str,
                r.data.len,
            });
        }
        try writer.print("+------------+------------+------------+------------+\n", .{});
        try writer.print("Total resources: {d}\n", .{self.resources.items.len});
    }
};

// ============================================================================
// Internal read/write helpers
// ============================================================================

inline fn rd16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .little);
}

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

inline fn wr16(buf: []u8, off: usize, val: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], val, .little);
}

inline fn wr32(buf: []u8, off: usize, val: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], val, .little);
}

// ============================================================================
// Tests
// ============================================================================

test "BIF round-trip" {
    const gpa = std.testing.allocator;

    var bif = BifFile.init(gpa);
    defer bif.deinit();

    const payload = "hello aurora";
    try bif.resources.append(gpa, .{
        .id = (0 << 20) | 0,
        .res_type = .txt,
        .data = try gpa.dupe(u8, payload),
    });

    const bytes = try bif.serialize(gpa);
    defer gpa.free(bytes);

    var bif2 = BifFile.init(gpa);
    defer bif2.deinit();
    try bif2.parse(bytes);

    try std.testing.expectEqual(@as(usize, 1), bif2.resources.items.len);
    try std.testing.expectEqualSlices(u8, payload, bif2.resources.items[0].data);
    try std.testing.expectEqual(ResType.txt, bif2.resources.items[0].res_type);
}

test "BIF multi-resource round-trip" {
    const gpa = std.testing.allocator;

    var bif = BifFile.init(gpa);
    defer bif.deinit();

    const payloads = [_][]const u8{ "first", "second resource data", "third" };
    for (payloads, 0..) |p, i| {
        try bif.resources.append(gpa, .{
            .id = @intCast(i),
            .res_type = .txt,
            .data = try gpa.dupe(u8, p),
        });
    }

    const bytes = try bif.serialize(gpa);
    defer gpa.free(bytes);

    var bif2 = BifFile.init(gpa);
    defer bif2.deinit();
    try bif2.parse(bytes);

    try std.testing.expectEqual(payloads.len, bif2.resources.items.len);
    for (payloads, 0..) |p, i| {
        try std.testing.expectEqualSlices(u8, p, bif2.resources.items[i].data);
    }
    try std.testing.expectEqualSlices(u8, payloads[1], bif2.getByIndex(1).?);
}

test "KEY round-trip" {
    const gpa = std.testing.allocator;

    var key = KeyFile.init(gpa);
    defer key.deinit();

    key.build_year = 104; // 2004
    key.build_day = 32;

    try key.bif_entries.append(gpa, .{
        .file_size = 65536,
        .drives = 1,
        .filename = try gpa.dupe(u8, "data\\2da.bif"),
    });

    var res_ref = [_]u8{0} ** 16;
    @memcpy(res_ref[0..7], "chicken");
    try key.key_entries.append(gpa, .{
        .res_ref = res_ref,
        .res_type = .@"2da",
        .res_id = (0 << 20) | 5,
    });

    const bytes = try key.serialize(gpa);
    defer gpa.free(bytes);

    var key2 = KeyFile.init(gpa);
    defer key2.deinit();
    try key2.parse(bytes);

    try std.testing.expectEqual(@as(usize, 1), key2.bif_entries.items.len);
    try std.testing.expectEqualStrings("data\\2da.bif", key2.bif_entries.items[0].filename);
    try std.testing.expectEqual(@as(u32, 65536), key2.bif_entries.items[0].file_size);
    try std.testing.expectEqual(@as(u16, 1), key2.bif_entries.items[0].drives);

    try std.testing.expectEqual(@as(usize, 1), key2.key_entries.items.len);
    try std.testing.expectEqualStrings("chicken", key2.key_entries.items[0].resRefSlice());
    try std.testing.expectEqual(ResType.@"2da", key2.key_entries.items[0].res_type);
    try std.testing.expectEqual(@as(u32, 5), key2.key_entries.items[0].varIndex());
    try std.testing.expectEqual(@as(u32, 0), key2.key_entries.items[0].bifIndex());

    try std.testing.expectEqual(@as(u32, 104), key2.build_year);
    try std.testing.expectEqual(@as(u32, 32), key2.build_day);
}

test "KEY findEntry" {
    const gpa = std.testing.allocator;

    var key = KeyFile.init(gpa);
    defer key.deinit();

    try key.bif_entries.append(gpa, .{
        .file_size = 0,
        .drives = 1,
        .filename = try gpa.dupe(u8, "data\\test.bif"),
    });

    var ref_a = [_]u8{0} ** 16;
    @memcpy(ref_a[0..5], "armor");
    var ref_b = [_]u8{0} ** 16;
    @memcpy(ref_b[0..6], "helmet");

    try key.key_entries.append(gpa, .{ .res_ref = ref_a, .res_type = .uti, .res_id = 0 });
    try key.key_entries.append(gpa, .{ .res_ref = ref_b, .res_type = .uti, .res_id = 1 });

    try std.testing.expect(key.findEntry("armor", .uti) != null);
    try std.testing.expect(key.findEntry("helmet", .uti) != null);
    try std.testing.expect(key.findEntry("armor", .utc) == null);
    try std.testing.expect(key.findEntry("shield", .uti) == null);
}

test "BIF getByKeyEntry / getByKeyName resolve via KeyFile" {
    const gpa = std.testing.allocator;

    // Build a KEY with two entries that point into BIF #0.
    var key = KeyFile.init(gpa);
    defer key.deinit();

    try key.bif_entries.append(gpa, .{
        .file_size = 0,
        .drives = 1,
        .filename = try gpa.dupe(u8, "data\\test.bif"),
    });

    var ref_a = [_]u8{0} ** 16;
    @memcpy(ref_a[0..5], "armor");
    var ref_b = [_]u8{0} ** 16;
    @memcpy(ref_b[0..6], "helmet");

    try key.key_entries.append(gpa, .{ .res_ref = ref_a, .res_type = .uti, .res_id = (0 << 20) | 0 });
    try key.key_entries.append(gpa, .{ .res_ref = ref_b, .res_type = .uti, .res_id = (0 << 20) | 2 });

    // Build the matching BIF with three resources; only var indices 0 and 2
    // are referenced by the KEY entries above. Var index 1 is a decoy.
    var bif = BifFile.init(gpa);
    defer bif.deinit();
    try bif.resources.append(gpa, .{ .id = 0, .res_type = .uti, .data = try gpa.dupe(u8, "ARMOR_DATA") });
    try bif.resources.append(gpa, .{ .id = 1, .res_type = .uti, .data = try gpa.dupe(u8, "DECOY") });
    try bif.resources.append(gpa, .{ .id = 2, .res_type = .uti, .data = try gpa.dupe(u8, "HELMET_DATA") });

    // By KeyEntry
    const armor_entry = key.findEntry("armor", .uti).?;
    const armor_res = bif.getByKeyEntry(armor_entry).?;
    try std.testing.expectEqualSlices(u8, "ARMOR_DATA", armor_res.data);

    // By name
    const helmet_res = bif.getByKeyName(&key, "helmet", .uti).?;
    try std.testing.expectEqualSlices(u8, "HELMET_DATA", helmet_res.data);

    // Missing name
    try std.testing.expect(bif.getByKeyName(&key, "shield", .uti) == null);

    // Wrong type still returns null even though the name exists.
    try std.testing.expect(bif.getByKeyName(&key, "armor", .utc) == null);
}

test "VarResource fileExtension / descriptiveFileType" {
    const gpa = std.testing.allocator;

    var bif = BifFile.init(gpa);
    defer bif.deinit();
    try bif.resources.append(gpa, .{ .id = 0, .res_type = .uti, .data = try gpa.dupe(u8, "x") });
    try bif.resources.append(gpa, .{ .id = 1, .res_type = .@"2da", .data = try gpa.dupe(u8, "y") });
    try bif.resources.append(gpa, .{
        .id = 2,
        .res_type = @enumFromInt(0x1234), // unknown enum tag
        .data = try gpa.dupe(u8, "z"),
    });

    try std.testing.expectEqualStrings("uti", bif.resources.items[0].fileExtension());
    try std.testing.expectEqualStrings("Item Blueprint (UTI)", bif.resources.items[0].descriptiveFileType());

    try std.testing.expectEqualStrings("2da", bif.resources.items[1].fileExtension());
    try std.testing.expectEqualStrings("2D Array (2DA)", bif.resources.items[1].descriptiveFileType());

    try std.testing.expectEqualStrings("unknown", bif.resources.items[2].fileExtension());
    try std.testing.expectEqualStrings("Unknown", bif.resources.items[2].descriptiveFileType());
}

test "invalid magic returns error" {
    const gpa = std.testing.allocator;

    var buf = [_]u8{0} ** 64;
    @memcpy(buf[0..4], "BAD!");
    @memcpy(buf[4..8], "V1  ");

    var key = KeyFile.init(gpa);
    defer key.deinit();
    try std.testing.expectError(error.InvalidFileType, key.parse(&buf));

    var bif = BifFile.init(gpa);
    defer bif.deinit();
    try std.testing.expectError(error.InvalidFileType, bif.parse(&buf));
}
