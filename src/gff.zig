//! Bioware Aurora Generic File Format (GFF) V3.2 reader and writer.
//!
//! GFF is a label-addressed, type-tagged container used for many Aurora
//! engine resources (ARE, DLG, BIC, GIT, ...). A file is a tree of Structs
//! containing Fields containing primitive values, strings, blobs, sub-structs,
//! and lists of structs.
//!
//! Byte order: little-endian throughout.
//!
//! Physical layout (offsets stored in the 56-byte header):
//!   Header        (56 bytes)
//!   Struct Array  (StructCount × 12 bytes)
//!   Field Array   (FieldCount  × 12 bytes)
//!   Label Array   (LabelCount  × 16 bytes)
//!   Field Data    (FieldDataCount bytes – payload for complex fields)
//!   Field Indices (FieldIndicesCount bytes – DWORDs)
//!   List Indices  (ListIndicesCount bytes – packed List elements)
const std = @import("std");

// ============================================================================
// Constants & errors
// ============================================================================

pub const FILE_VERSION = "V3.2";
pub const HEADER_SIZE: u32 = 56;

pub const FormatError = error{
    /// The 4-byte FileType magic did not match the caller-supplied expectation.
    InvalidFileType,
    /// File version is not "V3.2".
    InvalidVersion,
    /// File is truncated, an offset points outside the buffer, or a
    /// declared section is inconsistent.
    InvalidFormat,
    /// Field type ID is not one of 0..=15.
    InvalidFieldType,
};

// ============================================================================
// Type definitions
// ============================================================================

/// Numeric Field Type IDs as defined in Table 3.4b of the spec.
pub const FieldType = enum(u32) {
    byte = 0,
    char = 1,
    word = 2,
    short = 3,
    dword = 4,
    int = 5,
    dword64 = 6,
    int64 = 7,
    float = 8,
    double = 9,
    exo_string = 10,
    res_ref = 11,
    exo_loc_string = 12,
    void_data = 13,
    @"struct" = 14,
    list = 15,
};

/// A 16-byte label as it appears on disk. Null-padded, possibly non-terminated.
pub const Label = [16]u8;

/// CResRef: a short, lowercase-by-convention resource name, max 16 bytes.
pub const ResRef = struct {
    len: u8,
    data: [16]u8,

    pub fn slice(self: *const ResRef) []const u8 {
        return self.data[0..self.len];
    }

    pub fn fromSlice(text: []const u8) ResRef {
        std.debug.assert(text.len <= 16);
        var r: ResRef = .{ .len = @intCast(text.len), .data = [_]u8{0} ** 16 };
        @memcpy(r.data[0..text.len], text);
        return r;
    }
};

/// One language/gender-tagged substring inside a CExoLocString.
pub const SubString = struct {
    /// 2 × LanguageID + Gender (0 = neutral/masculine, 1 = feminine).
    string_id: u32,
    /// UTF-8/ASCII payload. Owned.
    text: []u8,
};

/// Localized string: may reference dialog.tlk and/or carry embedded substrings.
pub const ExoLocString = struct {
    /// Index into dialog.tlk, or 0xFFFFFFFF for "no reference".
    string_ref: u32,
    /// Embedded substrings. Owned.
    substrings: std.ArrayList(SubString),

    pub fn deinit(self: *ExoLocString, alloc: std.mem.Allocator) void {
        for (self.substrings.items) |s| alloc.free(s.text);
        self.substrings.deinit(alloc);
    }
};

/// Tagged value of any GFF field. Slice/list payloads are owned by the GffFile.
pub const FieldValue = union(FieldType) {
    byte: u8,
    char: i8,
    word: u16,
    short: i16,
    dword: u32,
    int: i32,
    dword64: u64,
    int64: i64,
    float: f32,
    double: f64,
    exo_string: []u8,
    res_ref: ResRef,
    exo_loc_string: ExoLocString,
    void_data: []u8,
    @"struct": u32, // index into GffFile.structs
    list: []u32, // indices into GffFile.structs (owned)
};

/// A labelled value stored in some Struct.
pub const Field = struct {
    label_index: u32,
    value: FieldValue,
};

/// A Struct is a programmer-typed bag of Field references.
pub const Struct = struct {
    /// Programmer-defined type ID. The top-level struct uses 0xFFFFFFFF.
    type_id: u32,
    /// Indices into `GffFile.fields`. Owned.
    field_indices: []u32,
};

pub const FileType = enum(u32) {
    DLG = @bitCast([4]u8{ 'D', 'L', 'G', ' ' }),
    ARE = @bitCast([4]u8{ 'A', 'R', 'E', ' ' }),
    BIC = @bitCast([4]u8{ 'B', 'I', 'C', ' ' }),
    GIT = @bitCast([4]u8{ 'G', 'I', 'T', ' ' }),
    UTI = @bitCast([4]u8{ 'U', 'T', 'I', ' ' }),
    UTC = @bitCast([4]u8{ 'U', 'T', 'C', ' ' }),
    UTD = @bitCast([4]u8{ 'U', 'T', 'D', ' ' }),
    UTE = @bitCast([4]u8{ 'U', 'T', 'E', ' ' }),
    UTM = @bitCast([4]u8{ 'U', 'T', 'M', ' ' }),
    UTP = @bitCast([4]u8{ 'U', 'T', 'P', ' ' }),
    UTS = @bitCast([4]u8{ 'U', 'T', 'S', ' ' }),
    UTT = @bitCast([4]u8{ 'U', 'T', 'T', ' ' }),
    UTW = @bitCast([4]u8{ 'U', 'T', 'W', ' ' }),
    IFO = @bitCast([4]u8{ 'I', 'F', 'O', ' ' }),
    ITP = @bitCast([4]u8{ 'I', 'T', 'P', ' ' }),
    JRL = @bitCast([4]u8{ 'J', 'R', 'L', ' ' }),
    FAC = @bitCast([4]u8{ 'F', 'A', 'C', ' ' }),
    GFF = @bitCast([4]u8{ 'G', 'F', 'F', ' ' }),
    GUI = @bitCast([4]u8{ 'G', 'U', 'I', ' ' }),
    TST = @bitCast([4]u8{ 'T', 'S', 'T', ' ' }),
    _,

    pub fn toBytes(self: FileType) [4]u8 {
        return @bitCast(@intFromEnum(self));
    }

    pub fn fromBytes(bytes: [4]u8) FileType {
        return @enumFromInt(@as(u32, @bitCast(bytes)));
    }
};

// ============================================================================
// GffFile
// ============================================================================

pub const GffFile = struct {
    allocator: std.mem.Allocator,
    /// 4-character content-type identifier, e.g. "DLG ", "ARE ", "BIC ".
    file_type: [4]u8,
    /// structs[0] is the top-level struct.
    structs: std.ArrayList(Struct),
    fields: std.ArrayList(Field),
    labels: std.ArrayList(Label),

    pub const TOP_LEVEL_TYPE_ID: u32 = 0xFFFF_FFFF;

    /// Create an empty GffFile with a single top-level struct already in place.
    pub fn init(allocator: std.mem.Allocator, file_type: [4]u8) !GffFile {
        var self: GffFile = .{
            .allocator = allocator,
            .file_type = file_type,
            .structs = .empty,
            .fields = .empty,
            .labels = .empty,
        };
        // structs[0] = top-level
        try self.structs.append(allocator, .{
            .type_id = TOP_LEVEL_TYPE_ID,
            .field_indices = try allocator.alloc(u32, 0),
        });
        return self;
    }

    /// Create an empty GffFile WITHOUT a top-level struct, used by parse().
    /// Callers must populate `structs` via `parse` before use.
    pub fn initEmpty(allocator: std.mem.Allocator) GffFile {
        return .{
            .allocator = allocator,
            .file_type = [_]u8{ 0, 0, 0, 0 },
            .structs = .empty,
            .fields = .empty,
            .labels = .empty,
        };
    }

    pub fn deinit(self: *GffFile) void {
        for (self.structs.items) |s| self.allocator.free(s.field_indices);
        self.structs.deinit(self.allocator);

        for (self.fields.items) |*f| freeFieldValue(self.allocator, &f.value);
        self.fields.deinit(self.allocator);

        self.labels.deinit(self.allocator);
    }

    // ------------------------------------------------------------------ Builder

    pub fn topLevel(self: *GffFile) *Struct {
        return &self.structs.items[0];
    }

    /// Add a label, deduplicating against existing entries. Returns its index.
    pub fn addLabel(self: *GffFile, text: []const u8) !u32 {
        if (self.findLabel(text)) |idx| return idx;
        var lbl: Label = [_]u8{0} ** 16;
        const n = @min(text.len, 16);
        @memcpy(lbl[0..n], text[0..n]);
        try self.labels.append(self.allocator, lbl);
        return @intCast(self.labels.items.len - 1);
    }

    pub fn findLabel(self: *const GffFile, text: []const u8) ?u32 {
        const n = @min(text.len, 16);
        for (self.labels.items, 0..) |*lbl, i| {
            if (labelEqualsText(lbl, text[0..n])) return @intCast(i);
        }
        return null;
    }

    /// Append a new struct and return its index.
    pub fn addStruct(self: *GffFile, type_id: u32) !u32 {
        try self.structs.append(self.allocator, .{
            .type_id = type_id,
            .field_indices = try self.allocator.alloc(u32, 0),
        });
        return @intCast(self.structs.items.len - 1);
    }

    /// Append a new field and return its index.
    pub fn addField(self: *GffFile, label_index: u32, value: FieldValue) !u32 {
        try self.fields.append(self.allocator, .{
            .label_index = label_index,
            .value = value,
        });
        return @intCast(self.fields.items.len - 1);
    }

    /// Convenience: add a field with the given label/value and attach it to
    /// `struct_idx`. Label is deduplicated.
    pub fn addFieldToStruct(
        self: *GffFile,
        struct_idx: u32,
        label: []const u8,
        value: FieldValue,
    ) !void {
        const label_idx = try self.addLabel(label);
        const field_idx = try self.addField(label_idx, value);
        try self.appendFieldIndex(struct_idx, field_idx);
    }

    fn appendFieldIndex(self: *GffFile, struct_idx: u32, field_idx: u32) !void {
        const s = &self.structs.items[struct_idx];
        const old = s.field_indices;
        const new = try self.allocator.alloc(u32, old.len + 1);
        @memcpy(new[0..old.len], old);
        new[old.len] = field_idx;
        self.allocator.free(old);
        s.field_indices = new;
    }

    /// Lookup a field in `s` by label text. Returns null if missing.
    pub fn getField(
        self: *const GffFile,
        s: *const Struct,
        label: []const u8,
    ) ?*const Field {
        for (s.field_indices) |fi| {
            const f = &self.fields.items[fi];
            const lbl = &self.labels.items[f.label_index];
            if (labelEqualsText(lbl, label)) return f;
        }
        return null;
    }

    /// Deep-copy a struct (and everything reachable from it) from `src` into
    /// `self`. Returns the new struct index in `self`. All owned data is
    /// duplicated using `self.allocator`. Safe to call with `src == self`
    /// (the source subtree is not mutated).
    pub fn cloneStructInto(self: *GffFile, src: *const GffFile, src_idx: u32) std.mem.Allocator.Error!u32 {
        const src_struct = &src.structs.items[src_idx];
        const dst_idx = try self.addStruct(src_struct.type_id);
        // Snapshot field indices: src may equal self, so further appends could
        // realloc src.fields; capture lengths now.
        const n = src_struct.field_indices.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const fi = src.structs.items[src_idx].field_indices[i];
            const sf = src.fields.items[fi];
            const lbl_ptr = &src.labels.items[sf.label_index];
            const lbl_len = labelTextLen(lbl_ptr);
            // Copy label bytes onto a small stack buffer because addLabel
            // may realloc src.labels when src == self.
            var lbl_buf: [16]u8 = undefined;
            @memcpy(lbl_buf[0..lbl_len], lbl_ptr[0..lbl_len]);
            const new_value = try cloneFieldValue(self, src, sf.value);
            try self.addFieldToStruct(dst_idx, lbl_buf[0..lbl_len], new_value);
        }
        return dst_idx;
    }

    // ====================================================================== //
    // Parse                                                                    //
    // ====================================================================== //

    /// Parse a GFF file from raw bytes. The top-level struct (if any) is
    /// appended to `self.structs` along with everything else.
    ///
    /// If `expected_file_type` is provided, the 4-byte FileType field must
    /// match exactly or `InvalidFileType` is returned.
    pub fn parse(
        self: *GffFile,
        data: []const u8,
        expected_file_type: ?*const [4]u8,
    ) !void {
        if (data.len < HEADER_SIZE) return error.InvalidFormat;

        @memcpy(&self.file_type, data[0..4]);
        if (expected_file_type) |exp| {
            if (!std.mem.eql(u8, &self.file_type, exp)) return error.InvalidFileType;
        }
        if (!std.mem.eql(u8, data[4..8], FILE_VERSION)) return error.InvalidVersion;

        const struct_off = rd32(data, 8);
        const struct_count = rd32(data, 12);
        const field_off = rd32(data, 16);
        const field_count = rd32(data, 20);
        const label_off = rd32(data, 24);
        const label_count = rd32(data, 28);
        const fdata_off = rd32(data, 32);
        const fdata_count = rd32(data, 36);
        const findices_off = rd32(data, 40);
        const findices_cnt = rd32(data, 44);
        const lindices_off = rd32(data, 48);
        const lindices_cnt = rd32(data, 52);

        // Section bounds check.
        if (!sectionOk(data.len, struct_off, struct_count * 12)) return error.InvalidFormat;
        if (!sectionOk(data.len, field_off, field_count * 12)) return error.InvalidFormat;
        if (!sectionOk(data.len, label_off, label_count * 16)) return error.InvalidFormat;
        if (!sectionOk(data.len, fdata_off, fdata_count)) return error.InvalidFormat;
        if (!sectionOk(data.len, findices_off, findices_cnt)) return error.InvalidFormat;
        if (!sectionOk(data.len, lindices_off, lindices_cnt)) return error.InvalidFormat;

        const field_data = data[fdata_off..][0..fdata_count];
        const field_indices = data[findices_off..][0..findices_cnt];
        const list_indices = data[lindices_off..][0..lindices_cnt];

        // -- Labels ------------------------------------------------------------
        try self.labels.ensureTotalCapacity(self.allocator, label_count);
        var i: usize = 0;
        while (i < label_count) : (i += 1) {
            var lbl: Label = undefined;
            @memcpy(&lbl, data[label_off + i * 16 ..][0..16]);
            self.labels.appendAssumeCapacity(lbl);
        }

        // -- Fields ------------------------------------------------------------
        try self.fields.ensureTotalCapacity(self.allocator, field_count);
        i = 0;
        while (i < field_count) : (i += 1) {
            const base = field_off + i * 12;
            const ftype_raw = rd32(data, base + 0);
            const label_ix = rd32(data, base + 4);
            const dod = rd32(data, base + 8);
            if (ftype_raw > 15) return error.InvalidFieldType;
            if (label_ix >= label_count) return error.InvalidFormat;

            const ftype: FieldType = @enumFromInt(ftype_raw);
            const value = try self.decodeFieldValue(
                ftype,
                dod,
                field_data,
                field_indices,
                list_indices,
            );
            errdefer {
                var tmp = value;
                freeFieldValue(self.allocator, &tmp);
            }

            self.fields.appendAssumeCapacity(.{
                .label_index = label_ix,
                .value = value,
            });
        }

        // -- Structs -----------------------------------------------------------
        try self.structs.ensureTotalCapacity(self.allocator, struct_count);
        i = 0;
        while (i < struct_count) : (i += 1) {
            const base = struct_off + i * 12;
            const type_id = rd32(data, base + 0);
            const dod = rd32(data, base + 4);
            const fcount = rd32(data, base + 8);

            const indices: []u32 = blk: {
                if (fcount == 0) break :blk try self.allocator.alloc(u32, 0);
                if (fcount == 1) {
                    if (dod >= field_count) return error.InvalidFormat;
                    const arr = try self.allocator.alloc(u32, 1);
                    arr[0] = dod;
                    break :blk arr;
                }
                // fcount > 1: dod is a byte offset into field_indices
                if (dod + fcount * 4 > field_indices.len) return error.InvalidFormat;
                const arr = try self.allocator.alloc(u32, fcount);
                var j: usize = 0;
                while (j < fcount) : (j += 1) {
                    const idx = rd32(field_indices, dod + j * 4);
                    if (idx >= field_count) {
                        self.allocator.free(arr);
                        return error.InvalidFormat;
                    }
                    arr[j] = idx;
                }
                break :blk arr;
            };

            self.structs.appendAssumeCapacity(.{
                .type_id = type_id,
                .field_indices = indices,
            });
        }
    }

    fn decodeFieldValue(
        self: *GffFile,
        ftype: FieldType,
        dod: u32,
        field_data: []const u8,
        field_indices: []const u8,
        list_indices: []const u8,
    ) !FieldValue {
        _ = field_indices; // only used by struct decoding (handled in parse())
        return switch (ftype) {
            // ---- Simple types: value packed into dod -----------------------
            .byte => .{ .byte = @intCast(dod & 0xFF) },
            .char => .{ .char = @bitCast(@as(u8, @intCast(dod & 0xFF))) },
            .word => .{ .word = @intCast(dod & 0xFFFF) },
            .short => .{ .short = @bitCast(@as(u16, @intCast(dod & 0xFFFF))) },
            .dword => .{ .dword = dod },
            .int => .{ .int = @bitCast(dod) },
            .float => .{ .float = @bitCast(dod) },

            // ---- 8-byte simples stored in Field Data -----------------------
            .dword64 => blk: {
                if (dod + 8 > field_data.len) return error.InvalidFormat;
                break :blk .{ .dword64 = rd64(field_data, dod) };
            },
            .int64 => blk: {
                if (dod + 8 > field_data.len) return error.InvalidFormat;
                break :blk .{ .int64 = @bitCast(rd64(field_data, dod)) };
            },
            .double => blk: {
                if (dod + 8 > field_data.len) return error.InvalidFormat;
                break :blk .{ .double = @bitCast(rd64(field_data, dod)) };
            },

            // ---- Variable-length strings/blobs in Field Data ---------------
            .exo_string => blk: {
                if (dod + 4 > field_data.len) return error.InvalidFormat;
                const size = rd32(field_data, dod);
                if (dod + 4 + size > field_data.len) return error.InvalidFormat;
                const text = try self.allocator.dupe(u8, field_data[dod + 4 ..][0..size]);
                break :blk .{ .exo_string = text };
            },
            .res_ref => blk: {
                if (dod + 1 > field_data.len) return error.InvalidFormat;
                const size: u8 = field_data[dod];
                if (size > 16) return error.InvalidFormat;
                if (dod + 1 + size > field_data.len) return error.InvalidFormat;
                var r: ResRef = .{ .len = size, .data = [_]u8{0} ** 16 };
                @memcpy(r.data[0..size], field_data[dod + 1 ..][0..size]);
                break :blk .{ .res_ref = r };
            },
            .exo_loc_string => blk: {
                if (dod + 4 > field_data.len) return error.InvalidFormat;
                const total_size = rd32(field_data, dod);
                // total_size excludes the leading 4-byte size field itself.
                if (dod + 4 + total_size > field_data.len) return error.InvalidFormat;
                if (total_size < 8) return error.InvalidFormat;

                const string_ref = rd32(field_data, dod + 4);
                const sub_count = rd32(field_data, dod + 8);

                var loc: ExoLocString = .{
                    .string_ref = string_ref,
                    .substrings = .empty,
                };
                errdefer loc.deinit(self.allocator);

                var pos: usize = dod + 12;
                const end: usize = dod + 4 + total_size;
                var k: u32 = 0;
                while (k < sub_count) : (k += 1) {
                    if (pos + 8 > end) return error.InvalidFormat;
                    const sid = rd32(field_data, pos);
                    const slen = rd32(field_data, pos + 4);
                    if (pos + 8 + slen > end) return error.InvalidFormat;
                    const text = try self.allocator.dupe(u8, field_data[pos + 8 ..][0..slen]);
                    errdefer self.allocator.free(text);
                    try loc.substrings.append(self.allocator, .{
                        .string_id = sid,
                        .text = text,
                    });
                    pos += 8 + slen;
                }
                break :blk .{ .exo_loc_string = loc };
            },
            .void_data => blk: {
                if (dod + 4 > field_data.len) return error.InvalidFormat;
                const size = rd32(field_data, dod);
                if (dod + 4 + size > field_data.len) return error.InvalidFormat;
                const buf = try self.allocator.dupe(u8, field_data[dod + 4 ..][0..size]);
                break :blk .{ .void_data = buf };
            },

            // ---- Struct: dod is an index into the Struct array -------------
            .@"struct" => .{ .@"struct" = dod },

            // ---- List: dod is a byte offset into List Indices --------------
            .list => blk: {
                if (dod + 4 > list_indices.len) return error.InvalidFormat;
                const size = rd32(list_indices, dod);
                if (dod + 4 + size * 4 > list_indices.len) return error.InvalidFormat;
                const arr = try self.allocator.alloc(u32, size);
                var k: u32 = 0;
                while (k < size) : (k += 1) {
                    arr[k] = rd32(list_indices, dod + 4 + k * 4);
                }
                break :blk .{ .list = arr };
            },
        };
    }

    // ====================================================================== //
    // Serialize                                                                //
    // ====================================================================== //

    /// Serialize this GffFile to a newly allocated byte slice using a
    /// deterministic canonical layout. Caller owns the returned memory.
    pub fn serialize(self: *const GffFile, alloc: std.mem.Allocator) ![]u8 {
        // ---- Pass 1: compute layout, record per-field data offsets -------
        var field_data_offs = try alloc.alloc(u32, self.fields.items.len);
        defer alloc.free(field_data_offs);
        var list_offs = try alloc.alloc(u32, self.fields.items.len);
        defer alloc.free(list_offs);
        var struct_findices_offs = try alloc.alloc(u32, self.structs.items.len);
        defer alloc.free(struct_findices_offs);

        var fdata_size: u32 = 0;
        var lindices_size: u32 = 0;
        var findices_size: u32 = 0;

        for (self.fields.items, 0..) |*f, i| {
            field_data_offs[i] = 0;
            list_offs[i] = 0;
            switch (f.value) {
                .byte, .char, .word, .short, .dword, .int, .float, .@"struct" => {},
                .dword64, .int64, .double => {
                    field_data_offs[i] = fdata_size;
                    fdata_size += 8;
                },
                .exo_string => |s| {
                    field_data_offs[i] = fdata_size;
                    fdata_size += 4 + @as(u32, @intCast(s.len));
                },
                .res_ref => |r| {
                    field_data_offs[i] = fdata_size;
                    fdata_size += 1 + r.len;
                },
                .exo_loc_string => |loc| {
                    field_data_offs[i] = fdata_size;
                    var total: u32 = 8; // string_ref + count
                    for (loc.substrings.items) |s| total += 8 + @as(u32, @intCast(s.text.len));
                    fdata_size += 4 + total;
                },
                .void_data => |b| {
                    field_data_offs[i] = fdata_size;
                    fdata_size += 4 + @as(u32, @intCast(b.len));
                },
                .list => |arr| {
                    list_offs[i] = lindices_size;
                    lindices_size += 4 + 4 * @as(u32, @intCast(arr.len));
                },
            }
        }

        for (self.structs.items, 0..) |s, i| {
            struct_findices_offs[i] = 0;
            if (s.field_indices.len > 1) {
                struct_findices_offs[i] = findices_size;
                findices_size += 4 * @as(u32, @intCast(s.field_indices.len));
            }
        }

        // ---- Compute section offsets ------------------------------------
        const struct_count: u32 = @intCast(self.structs.items.len);
        const field_count: u32 = @intCast(self.fields.items.len);
        const label_count: u32 = @intCast(self.labels.items.len);

        const struct_off: u32 = HEADER_SIZE;
        const field_off: u32 = struct_off + struct_count * 12;
        const label_off: u32 = field_off + field_count * 12;
        const fdata_off: u32 = label_off + label_count * 16;
        const findices_off: u32 = fdata_off + fdata_size;
        const lindices_off: u32 = findices_off + findices_size;
        const total: usize = lindices_off + lindices_size;

        const out = try alloc.alloc(u8, total);
        errdefer alloc.free(out);
        @memset(out, 0);

        // ---- Header -----------------------------------------------------
        @memcpy(out[0..4], &self.file_type);
        @memcpy(out[4..8], FILE_VERSION);
        wr32(out, 8, struct_off);
        wr32(out, 12, struct_count);
        wr32(out, 16, field_off);
        wr32(out, 20, field_count);
        wr32(out, 24, label_off);
        wr32(out, 28, label_count);
        wr32(out, 32, fdata_off);
        wr32(out, 36, fdata_size);
        wr32(out, 40, findices_off);
        wr32(out, 44, findices_size);
        wr32(out, 48, lindices_off);
        wr32(out, 52, lindices_size);

        // ---- Labels -----------------------------------------------------
        for (self.labels.items, 0..) |lbl, i| {
            @memcpy(out[label_off + i * 16 ..][0..16], &lbl);
        }

        // ---- Structs ----------------------------------------------------
        for (self.structs.items, 0..) |s, i| {
            const base = struct_off + i * 12;
            wr32(out, base + 0, s.type_id);
            const fcount: u32 = @intCast(s.field_indices.len);
            const dod: u32 = switch (fcount) {
                0 => 0,
                1 => s.field_indices[0],
                else => struct_findices_offs[i],
            };
            wr32(out, base + 4, dod);
            wr32(out, base + 8, fcount);

            if (fcount > 1) {
                const fi_base = findices_off + struct_findices_offs[i];
                for (s.field_indices, 0..) |fi, j| {
                    wr32(out, fi_base + j * 4, fi);
                }
            }
        }

        // ---- Fields + Field Data + List Indices -------------------------
        for (self.fields.items, 0..) |*f, i| {
            const base = field_off + i * 12;
            wr32(out, base + 0, @intFromEnum(@as(FieldType, f.value)));
            wr32(out, base + 4, f.label_index);

            const dod: u32 = switch (f.value) {
                .byte => |v| v,
                .char => |v| @as(u8, @bitCast(v)),
                .word => |v| v,
                .short => |v| @as(u16, @bitCast(v)),
                .dword => |v| v,
                .int => |v| @bitCast(v),
                .float => |v| @bitCast(v),
                .dword64, .int64, .double, .exo_string, .res_ref, .exo_loc_string, .void_data => field_data_offs[i],
                .@"struct" => |idx| idx,
                .list => list_offs[i],
            };
            wr32(out, base + 8, dod);

            // Emit complex payloads.
            switch (f.value) {
                .byte, .char, .word, .short, .dword, .int, .float, .@"struct" => {},
                .dword64 => |v| wr64(out, fdata_off + field_data_offs[i], v),
                .int64 => |v| wr64(out, fdata_off + field_data_offs[i], @bitCast(v)),
                .double => |v| wr64(out, fdata_off + field_data_offs[i], @bitCast(v)),
                .exo_string => |s| {
                    const o = fdata_off + field_data_offs[i];
                    wr32(out, o, @intCast(s.len));
                    @memcpy(out[o + 4 ..][0..s.len], s);
                },
                .res_ref => |r| {
                    const o = fdata_off + field_data_offs[i];
                    out[o] = r.len;
                    @memcpy(out[o + 1 ..][0..r.len], r.data[0..r.len]);
                },
                .exo_loc_string => |loc| {
                    const o = fdata_off + field_data_offs[i];
                    var inner: u32 = 8;
                    for (loc.substrings.items) |ss| inner += 8 + @as(u32, @intCast(ss.text.len));
                    wr32(out, o, inner);
                    wr32(out, o + 4, loc.string_ref);
                    wr32(out, o + 8, @intCast(loc.substrings.items.len));
                    var pos: usize = o + 12;
                    for (loc.substrings.items) |ss| {
                        wr32(out, pos, ss.string_id);
                        wr32(out, pos + 4, @intCast(ss.text.len));
                        @memcpy(out[pos + 8 ..][0..ss.text.len], ss.text);
                        pos += 8 + ss.text.len;
                    }
                },
                .void_data => |b| {
                    const o = fdata_off + field_data_offs[i];
                    wr32(out, o, @intCast(b.len));
                    @memcpy(out[o + 4 ..][0..b.len], b);
                },
                .list => |arr| {
                    const o = lindices_off + list_offs[i];
                    wr32(out, o, @intCast(arr.len));
                    for (arr, 0..) |idx, k| wr32(out, o + 4 + k * 4, idx);
                },
            }
        }

        return out;
    }

    pub fn dump(self: *const GffFile, writer: anytype) !void {
        try writer.print("GFF File: {s}\n", .{self.file_type});
        try writer.print("Structs: {d}, Fields: {d}, Labels: {d}\n\n", .{
            self.structs.items.len,
            self.fields.items.len,
            self.labels.items.len,
        });

        for (self.structs.items, 0..) |s, i| {
            try writer.print("Struct[{d}] type_id=0x{X:0>8}, fields={d}\n", .{ i, s.type_id, s.field_indices.len });
            for (s.field_indices) |fi| {
                const f = &self.fields.items[fi];
                const label = self.labels.items[f.label_index];
                const label_str = std.mem.sliceTo(&label, 0);
                try writer.print("  [{d}] \"{s}\": ", .{ fi, label_str });
                try self.dumpFieldValue(writer, f.value);
                try writer.print("\n", .{});
            }
        }
    }

    fn dumpFieldValue(self: *const GffFile, writer: anytype, v: FieldValue) !void {
        _ = self;
        switch (v) {
            .byte => |val| try writer.print("BYTE({d})", .{val}),
            .char => |val| try writer.print("CHAR({d})", .{val}),
            .word => |val| try writer.print("WORD({d})", .{val}),
            .short => |val| try writer.print("SHORT({d})", .{val}),
            .dword => |val| try writer.print("DWORD({d})", .{val}),
            .int => |val| try writer.print("INT({d})", .{val}),
            .dword64 => |val| try writer.print("DWORD64({d})", .{val}),
            .int64 => |val| try writer.print("INT64({d})", .{val}),
            .float => |val| try writer.print("FLOAT({d:.6})", .{val}),
            .double => |val| try writer.print("DOUBLE({d:.6})", .{val}),
            .exo_string => |s| try writer.print("STRING(\"{s}\")", .{s}),
            .res_ref => |r| try writer.print("RESREF(\"{s}\")", .{r.slice()}),
            .exo_loc_string => |loc| {
                try writer.print("LOCSTRING(ref={d}, subs=[", .{loc.string_ref});
                for (loc.substrings.items, 0..) |ss, j| {
                    if (j > 0) try writer.print(", ", .{});
                    try writer.print("{{id={d}, \"{s}\"}}", .{ ss.string_id, ss.text });
                }
                try writer.print("])", .{});
            },
            .void_data => |b| try writer.print("VOID({d} bytes)", .{b.len}),
            .@"struct" => |idx| try writer.print("STRUCT({d})", .{idx}),
            .list => |arr| {
                try writer.print("LIST([", .{});
                for (arr, 0..) |idx, j| {
                    if (j > 0) try writer.print(", ", .{});
                    try writer.print("{d}", .{idx});
                }
                try writer.print("])", .{});
            },
        }
    }
};

// ============================================================================
// Internal helpers
// ============================================================================

fn freeFieldValue(alloc: std.mem.Allocator, v: *FieldValue) void {
    switch (v.*) {
        .exo_string => |s| alloc.free(s),
        .void_data => |b| alloc.free(b),
        .list => |a| alloc.free(a),
        .exo_loc_string => |*l| l.deinit(alloc),
        else => {},
    }
}

fn labelTextLen(lbl: *const Label) usize {
    var i: usize = 0;
    while (i < 16 and lbl[i] != 0) : (i += 1) {}
    return i;
}

/// Deep-clone a FieldValue from `src`'s allocator domain into `dst`'s. For
/// nested struct/list values, recursively clones the referenced subtrees via
/// `dst.cloneStructInto`.
fn cloneFieldValue(dst: *GffFile, src: *const GffFile, v: FieldValue) std.mem.Allocator.Error!FieldValue {
    return switch (v) {
        .byte,
        .char,
        .word,
        .short,
        .dword,
        .int,
        .dword64,
        .int64,
        .float,
        .double,
        .res_ref,
        => v,
        .exo_string => |s| FieldValue{ .exo_string = try dst.allocator.dupe(u8, s) },
        .void_data => |s| FieldValue{ .void_data = try dst.allocator.dupe(u8, s) },
        .exo_loc_string => |loc| blk: {
            var out: ExoLocString = .{ .string_ref = loc.string_ref, .substrings = .empty };
            errdefer out.deinit(dst.allocator);
            for (loc.substrings.items) |ss| {
                const text = try dst.allocator.dupe(u8, ss.text);
                errdefer dst.allocator.free(text);
                try out.substrings.append(dst.allocator, .{ .string_id = ss.string_id, .text = text });
            }
            break :blk FieldValue{ .exo_loc_string = out };
        },
        .@"struct" => |idx| FieldValue{ .@"struct" = try dst.cloneStructInto(src, idx) },
        .list => |arr| blk: {
            const new_arr = try dst.allocator.alloc(u32, arr.len);
            errdefer dst.allocator.free(new_arr);
            for (arr, 0..) |child, i| new_arr[i] = try dst.cloneStructInto(src, child);
            break :blk FieldValue{ .list = new_arr };
        },
    };
}

fn labelEqualsText(lbl: *const Label, text: []const u8) bool {
    const n = @min(text.len, 16);
    if (!std.mem.eql(u8, lbl[0..n], text[0..n])) return false;
    // Remaining label bytes must all be null.
    var i: usize = n;
    while (i < 16) : (i += 1) if (lbl[i] != 0) return false;
    return true;
}

fn sectionOk(buf_len: usize, off: u32, size: u32) bool {
    return @as(usize, off) + @as(usize, size) <= buf_len;
}

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}
inline fn rd64(data: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, data[off..][0..8], .little);
}
inline fn wr32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
inline fn wr64(buf: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], v, .little);
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "empty GFF round-trip" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, &"TST ".*);

    try t.expectEqual(@as(usize, 1), g2.structs.items.len);
    try t.expectEqual(GffFile.TOP_LEVEL_TYPE_ID, g2.structs.items[0].type_id);
    try t.expectEqual(@as(usize, 0), g2.fields.items.len);
}

test "simple field round-trip + byte-exact" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    try g.addFieldToStruct(0, "MyByte", .{ .byte = 0xAB });
    try g.addFieldToStruct(0, "MyInt", .{ .int = -123456 });
    try g.addFieldToStruct(0, "MyFloat", .{ .float = 3.14159 });

    const a = try g.serialize(gpa);
    defer gpa.free(a);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(a, null);

    try t.expectEqual(@as(usize, 3), g2.fields.items.len);
    const tl = &g2.structs.items[0];
    try t.expectEqual(@as(u8, 0xAB), g2.getField(tl, "MyByte").?.value.byte);
    try t.expectEqual(@as(i32, -123456), g2.getField(tl, "MyInt").?.value.int);
    try t.expectApproxEqAbs(@as(f32, 3.14159), g2.getField(tl, "MyFloat").?.value.float, 1e-5);

    const b = try g2.serialize(gpa);
    defer gpa.free(b);
    try t.expectEqualSlices(u8, a, b);
}

test "CExoString + CResRef round-trip" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    const hello = try gpa.dupe(u8, "hello world");
    try g.addFieldToStruct(0, "Greeting", .{ .exo_string = hello });
    try g.addFieldToStruct(0, "Greeting2", .{ .exo_string = try gpa.dupe(u8, "another") });
    try g.addFieldToStruct(0, "Template", .{ .res_ref = ResRef.fromSlice("nw_chicken") });

    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(bytes, null);

    const tl = &g2.structs.items[0];
    try t.expectEqualStrings("hello world", g2.getField(tl, "Greeting").?.value.exo_string);
    try t.expectEqualStrings("another", g2.getField(tl, "Greeting2").?.value.exo_string);
    const rr = g2.getField(tl, "Template").?.value.res_ref;
    try t.expectEqualStrings("nw_chicken", rr.slice());

    // Labels deduplicate text "Greeting" / "Greeting2" / "Template" — 3 entries.
    try t.expectEqual(@as(usize, 3), g2.labels.items.len);
}

test "CExoLocString round-trip" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var loc: ExoLocString = .{ .string_ref = 4242, .substrings = .empty };
    try loc.substrings.append(gpa, .{
        .string_id = 0, // English, neutral
        .text = try gpa.dupe(u8, "Hello"),
    });
    try loc.substrings.append(gpa, .{
        .string_id = 2 * 1 + 1, // French, feminine
        .text = try gpa.dupe(u8, "Bonjourâ"),
    });
    try g.addFieldToStruct(0, "Name", .{ .exo_loc_string = loc });

    const a = try g.serialize(gpa);
    defer gpa.free(a);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(a, null);

    const tl = &g2.structs.items[0];
    const loc2 = g2.getField(tl, "Name").?.value.exo_loc_string;
    try t.expectEqual(@as(u32, 4242), loc2.string_ref);
    try t.expectEqual(@as(usize, 2), loc2.substrings.items.len);
    try t.expectEqual(@as(u32, 0), loc2.substrings.items[0].string_id);
    try t.expectEqualStrings("Hello", loc2.substrings.items[0].text);
    try t.expectEqual(@as(u32, 3), loc2.substrings.items[1].string_id);
    try t.expectEqualStrings("Bonjourâ", loc2.substrings.items[1].text);

    const b = try g2.serialize(gpa);
    defer gpa.free(b);
    try t.expectEqualSlices(u8, a, b);
}

test "Void blob + 64-bit values round-trip" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    var blob: [256]u8 = undefined;
    for (&blob, 0..) |*p, i| p.* = @intCast(i & 0xFF);

    try g.addFieldToStruct(0, "Blob", .{ .void_data = try gpa.dupe(u8, &blob) });
    try g.addFieldToStruct(0, "Big", .{ .dword64 = 0xDEAD_BEEF_CAFE_BABE });
    try g.addFieldToStruct(0, "Neg64", .{ .int64 = -0x0102_0304_0506_0708 });
    try g.addFieldToStruct(0, "Pi", .{ .double = 3.141592653589793 });

    const a = try g.serialize(gpa);
    defer gpa.free(a);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(a, null);

    const tl = &g2.structs.items[0];
    try t.expectEqualSlices(u8, &blob, g2.getField(tl, "Blob").?.value.void_data);
    try t.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_BABE), g2.getField(tl, "Big").?.value.dword64);
    try t.expectEqual(@as(i64, -0x0102_0304_0506_0708), g2.getField(tl, "Neg64").?.value.int64);
    try t.expectApproxEqAbs(@as(f64, 3.141592653589793), g2.getField(tl, "Pi").?.value.double, 1e-12);

    const b = try g2.serialize(gpa);
    defer gpa.free(b);
    try t.expectEqualSlices(u8, a, b);
}

test "nested Struct + List round-trip" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();

    // Build 3 child structs, each holding two fields.
    var list_buf = try gpa.alloc(u32, 3);
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const sidx = try g.addStruct(@intCast(100 + k));
        try g.addFieldToStruct(sidx, "Index", .{ .int = @intCast(k) });
        try g.addFieldToStruct(sidx, "Name", .{
            .exo_string = try gpa.dupe(u8, "child"),
        });
        list_buf[k] = sidx;
    }
    try g.addFieldToStruct(0, "Children", .{ .list = list_buf });

    // Also embed a single nested struct.
    const inner = try g.addStruct(7);
    try g.addFieldToStruct(inner, "Inner", .{ .byte = 99 });
    try g.addFieldToStruct(0, "Nested", .{ .@"struct" = inner });

    const a = try g.serialize(gpa);
    defer gpa.free(a);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try g2.parse(a, null);

    const tl = &g2.structs.items[0];
    const children = g2.getField(tl, "Children").?.value.list;
    try t.expectEqual(@as(usize, 3), children.len);
    for (children, 0..) |sidx, i| {
        const s = &g2.structs.items[sidx];
        try t.expectEqual(@as(u32, @intCast(100 + i)), s.type_id);
        try t.expectEqual(@as(i32, @intCast(i)), g2.getField(s, "Index").?.value.int);
        try t.expectEqualStrings("child", g2.getField(s, "Name").?.value.exo_string);
    }
    const nested_idx = g2.getField(tl, "Nested").?.value.@"struct";
    const nested = &g2.structs.items[nested_idx];
    try t.expectEqual(@as(u32, 7), nested.type_id);
    try t.expectEqual(@as(u8, 99), g2.getField(nested, "Inner").?.value.byte);

    const b = try g2.serialize(gpa);
    defer gpa.free(b);
    try t.expectEqualSlices(u8, a, b);
}

test "version error" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "TST ".*);
    defer g.deinit();
    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    // Corrupt the version.
    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[4..8], "V3.1");

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try t.expectError(error.InvalidVersion, g2.parse(mut, null));
}

test "expected file type mismatch" {
    const gpa = t.allocator;
    var g = try GffFile.init(gpa, "DLG ".*);
    defer g.deinit();
    const bytes = try g.serialize(gpa);
    defer gpa.free(bytes);

    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    try t.expectError(error.InvalidFileType, g2.parse(bytes, &"ARE ".*));
}

test "truncated file" {
    const gpa = t.allocator;
    var g2 = GffFile.initEmpty(gpa);
    defer g2.deinit();
    var tiny: [10]u8 = undefined;
    try t.expectError(error.InvalidFormat, g2.parse(&tiny, null));
}
