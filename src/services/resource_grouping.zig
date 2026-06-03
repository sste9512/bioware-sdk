//! Resource identity for the BioWare Aurora Engine resource file system.
//!
//! Provides `ResourceId` — a fully value-typed, allocation-free struct that
//! uniquely identifies a game resource and records its provenance.
//!
//! ## Aurora resource hierarchy
//!
//!   chitin.key + *.bif     KEY/BIF — global game archive (top level)
//!   *.mod / *.hak / *.sav  ERF — self-contained module/hak/savegame archives
//!   *.rim                  RIM — per-area resource bundles
//!   *.are / *.git / *.uts  Individual GFF files on the host filesystem
//!   Embedded GFF resources  Items in creature inventories, etc.
//!
//! ## Parent-child relationships
//!
//! The `parent` pointer is set only for GFF-embedded resources (e.g. an item
//! inside a creature's `ItemList` field).  For archive-level containment (BIF
//! inside KEY, entries inside ERF/RIM) the container is described by the
//! `Origin` variant rather than the parent chain.
//!
//! Arena-allocate both parent and child in the same arena so lifetimes align.

const std = @import("std");
const keybif = @import("../keybif.zig");
const erf_mod = @import("../erf.zig");
const rim_mod = @import("../rim.zig");

/// Re-export so callers need only import this module.
pub const ResType = keybif.ResType;

// ============================================================================
// Origin
// ============================================================================

/// Describes where a resource's bytes came from.
///
/// All `[]const u8` fields **borrow** the string — the caller is responsible
/// for keeping the backing memory alive for at least as long as the
/// `ResourceId` is used.
pub const Origin = union(enum) {
    /// Raw bytes only; no known container.
    raw,

    /// Loaded directly from a file on the host filesystem.
    file_system: struct {
        path: []const u8,
    },

    /// Indexed by a KEY file, stored in a BIF archive.
    key_bif: struct {
        key_path: []const u8,
        /// Relative BIF path as stored in the KEY, e.g. `"data/2da.bif"`.
        bif_filename: []const u8,
        bif_index: u32,
        var_index: u32,
    },

    /// Entry in an ERF/MOD/HAK/SAV archive.
    erf_archive: struct {
        path: []const u8,
        entry_index: u32,
    },

    /// Entry in a RIM archive.
    rim_archive: struct {
        path: []const u8,
        entry_index: u32,
        resource_id: i16,
    },

    /// Resource embedded inside a GFF list field of a parent resource (e.g.
    /// an item in a creature's `ItemList`).
    embedded: struct {
        /// Name of the GFF list field in the parent that contains this resource.
        field_label: []const u8,
        /// Position of this resource within that list.
        element_index: u32,
    },
};

// ============================================================================
// ResourceId
// ============================================================================

/// Uniquely identifies a single game resource and records its provenance.
///
/// `ResourceId` is a fully value-typed struct with no internal allocation.
/// String slices inside `origin` are borrowed from the caller.  The optional
/// `parent` pointer is valid only for embedded resources and must outlive this
/// `ResourceId` (use arena allocation for both).
pub const ResourceId = struct {
    /// Resource name without extension, zero-padded to 16 bytes.
    res_ref: [16]u8 = [_]u8{0} ** 16,
    /// Actual byte length of the name stored in `res_ref`.
    res_ref_len: u8 = 0,
    /// Resource type (file format).
    res_type: ResType = .invalid,
    /// Where the resource bytes came from.
    origin: Origin = .raw,
    /// Non-null only for GFF-embedded resources.  The pointed-to `ResourceId`
    /// must outlive this one.
    parent: ?*const ResourceId = null,

    // -- Queries --------------------------------------------------------------

    /// Returns the resource name as a trimmed slice (no null padding).
    pub fn resRefSlice(self: *const ResourceId) []const u8 {
        return self.res_ref[0..self.res_ref_len];
    }

    /// Returns the file extension for this resource type (e.g. `".uts"`).
    /// Returns `""` for unknown/invalid types.
    pub fn extension(self: *const ResourceId) []const u8 {
        return extensionForResType(self.res_type);
    }

    /// Returns true when this resource is embedded inside a parent GFF struct.
    pub fn isEmbedded(self: *const ResourceId) bool {
        return self.origin == .embedded;
    }

    /// Returns the embedding depth: 0 for top-level resources, 1 for a
    /// resource embedded one level deep, and so on.
    pub fn depth(self: *const ResourceId) usize {
        var d: usize = 0;
        var cur: ?*const ResourceId = self.parent;
        while (cur) |p| {
            d += 1;
            cur = p.parent;
        }
        return d;
    }

    /// Walks the parent chain and returns the root ancestor.
    /// Returns `self` when there is no parent.
    pub fn rootAncestor(self: *const ResourceId) *const ResourceId {
        var cur: *const ResourceId = self;
        while (cur.parent) |p| cur = p;
        return cur;
    }

    /// Shallow equality: same `res_ref` bytes, same `res_type`, and same
    /// `Origin` variant tag.  Does not compare path strings or entry indices.
    pub fn eql(self: *const ResourceId, other: *const ResourceId) bool {
        if (self.res_ref_len != other.res_ref_len) return false;
        if (!std.mem.eql(u8, self.res_ref[0..self.res_ref_len], other.res_ref[0..other.res_ref_len])) return false;
        if (self.res_type != other.res_type) return false;
        return std.meta.activeTag(self.origin) == std.meta.activeTag(other.origin);
    }

    pub fn format(
        self: ResourceId,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("ResourceId{{ \"{s}\" ({s})", .{
            self.resRefSlice(),
            self.res_type.toString(),
        });
        switch (self.origin) {
            .raw => try writer.writeAll(" [raw]"),
            .file_system => |o| try writer.print(" [fs: {s}]", .{o.path}),
            .key_bif => |o| try writer.print(" [key: {s} / bif[{d}] var {d}]", .{ o.key_path, o.bif_index, o.var_index }),
            .erf_archive => |o| try writer.print(" [erf: {s}[{d}]]", .{ o.path, o.entry_index }),
            .rim_archive => |o| try writer.print(" [rim: {s}[{d}]]", .{ o.path, o.entry_index }),
            .embedded => |o| try writer.print(" [embedded: {s}[{d}]]", .{ o.field_label, o.element_index }),
        }
        try writer.writeByte('}');
    }
};

// ============================================================================
// Constructors
// ============================================================================

/// Construct a `ResourceId` for raw bytes with no known container.
pub fn fromBytes(res_ref: []const u8, res_type: ResType) ResourceId {
    var id = ResourceId{ .res_type = res_type, .origin = .raw };
    const n = @min(res_ref.len, 16);
    @memcpy(id.res_ref[0..n], res_ref[0..n]);
    id.res_ref_len = @intCast(n);
    return id;
}

/// Construct a `ResourceId` for a file on the host filesystem.
///
/// The `res_ref` is taken from the filename stem (truncated to 16 chars);
/// the `res_type` is inferred from the file extension.  `path` is borrowed
/// — the caller must keep it alive.
pub fn fromPath(path: []const u8) ResourceId {
    const basename = std.fs.path.basename(path);
    const ext = std.fs.path.extension(basename);
    const stem_len = basename.len - ext.len;
    const stem = basename[0..stem_len];

    var id = ResourceId{
        .res_type = resTypeFromExtension(ext),
        .origin = .{ .file_system = .{ .path = path } },
    };
    const n = @min(stem.len, 16);
    @memcpy(id.res_ref[0..n], stem[0..n]);
    id.res_ref_len = @intCast(n);
    return id;
}

/// Construct a `ResourceId` from a KEY file entry plus its BIF container.
///
/// `key_path` and `bif_entry.filename` are borrowed — keep them alive.
pub fn fromKeyEntry(
    entry: keybif.KeyFile.KeyEntry,
    key_path: []const u8,
    bif_entry: keybif.KeyFile.BifEntry,
) ResourceId {
    var id = ResourceId{
        .res_type = entry.res_type,
        .origin = .{ .key_bif = .{
            .key_path = key_path,
            .bif_filename = bif_entry.filename,
            .bif_index = entry.bifIndex(),
            .var_index = entry.varIndex(),
        } },
    };
    @memcpy(&id.res_ref, &entry.res_ref);
    id.res_ref_len = @intCast(std.mem.sliceTo(&entry.res_ref, 0).len);
    return id;
}

/// Construct a `ResourceId` from an ERF/MOD/HAK/SAV archive entry.
///
/// `archive_path` is borrowed — keep it alive.
pub fn fromErfEntry(
    entry: erf_mod.ErfEntry,
    archive_path: []const u8,
    entry_index: u32,
) ResourceId {
    var id = ResourceId{
        .res_type = entry.res_type,
        .origin = .{ .erf_archive = .{
            .path = archive_path,
            .entry_index = entry_index,
        } },
    };
    @memcpy(&id.res_ref, &entry.res_ref);
    id.res_ref_len = @intCast(std.mem.sliceTo(&entry.res_ref, 0).len);
    return id;
}

/// Construct a `ResourceId` from a RIM archive entry.
///
/// `rim_path` is borrowed — keep it alive.
pub fn fromRimEntry(
    entry: rim_mod.RimKeyEntry,
    rim_path: []const u8,
    entry_index: u32,
) ResourceId {
    const rt: ResType = @enumFromInt(@as(u16, @bitCast(entry.resource_type)));
    var id = ResourceId{
        .res_type = rt,
        .origin = .{ .rim_archive = .{
            .path = rim_path,
            .entry_index = entry_index,
            .resource_id = entry.resource_id,
        } },
    };
    const n = entry.resource_name_len;
    @memcpy(id.res_ref[0..n], entry.resource_name[0..n]);
    id.res_ref_len = @intCast(n);
    return id;
}

/// Return a copy of `self` tagged as a GFF-embedded child of `parent`.
///
/// `field_label` names the GFF list field in the parent that contains this
/// resource (e.g. `"ItemList"`); `element_index` is the position in that list.
/// `parent` is borrowed — it must outlive the returned `ResourceId`.
pub fn withParent(
    self: ResourceId,
    parent: *const ResourceId,
    field_label: []const u8,
    element_index: u32,
) ResourceId {
    var id = self;
    id.origin = .{ .embedded = .{
        .field_label = field_label,
        .element_index = element_index,
    } };
    id.parent = parent;
    return id;
}

// ============================================================================
// Extension ↔ ResType helpers
// ============================================================================

const EXT_TABLE: []const struct { ext: []const u8, rt: ResType } = &.{
    .{ .ext = "bmp", .rt = .bmp },
    .{ .ext = "tga", .rt = .tga },
    .{ .ext = "wav", .rt = .wav },
    .{ .ext = "plt", .rt = .plt },
    .{ .ext = "ini", .rt = .ini },
    .{ .ext = "txt", .rt = .txt },
    .{ .ext = "mdl", .rt = .mdl },
    .{ .ext = "nss", .rt = .nss },
    .{ .ext = "ncs", .rt = .ncs },
    .{ .ext = "are", .rt = .are },
    .{ .ext = "set", .rt = .set },
    .{ .ext = "ifo", .rt = .ifo },
    .{ .ext = "bic", .rt = .bic },
    .{ .ext = "wok", .rt = .wok },
    .{ .ext = "2da", .rt = .@"2da" },
    .{ .ext = "tlk", .rt = .tlk },
    .{ .ext = "txi", .rt = .txi },
    .{ .ext = "git", .rt = .git },
    .{ .ext = "uti", .rt = .uti },
    .{ .ext = "utc", .rt = .utc },
    .{ .ext = "dlg", .rt = .dlg },
    .{ .ext = "itp", .rt = .itp },
    .{ .ext = "utt", .rt = .utt },
    .{ .ext = "dds", .rt = .dds },
    .{ .ext = "uts", .rt = .uts },
    .{ .ext = "ltr", .rt = .ltr },
    .{ .ext = "gff", .rt = .gff },
    .{ .ext = "fac", .rt = .fac },
    .{ .ext = "ute", .rt = .ute },
    .{ .ext = "utd", .rt = .utd },
    .{ .ext = "utp", .rt = .utp },
    .{ .ext = "dft", .rt = .dft },
    .{ .ext = "gic", .rt = .gic },
    .{ .ext = "gui", .rt = .gui },
    .{ .ext = "utm", .rt = .utm },
    .{ .ext = "dwk", .rt = .dwk },
    .{ .ext = "pwk", .rt = .pwk },
    .{ .ext = "jrl", .rt = .jrl },
    .{ .ext = "utw", .rt = .utw },
    .{ .ext = "ssf", .rt = .ssf },
    .{ .ext = "ndb", .rt = .ndb },
    .{ .ext = "ptm", .rt = .ptm },
    .{ .ext = "ptt", .rt = .ptt },
    .{ .ext = "mdx", .rt = .mdx },
};

/// Map a file extension (with or without a leading `.`) to `ResType`.
/// Comparison is case-insensitive.  Returns `.invalid` for unknown extensions.
pub fn resTypeFromExtension(ext: []const u8) ResType {
    const e = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
    if (e.len == 0) return .invalid;
    for (EXT_TABLE) |pair| {
        if (std.ascii.eqlIgnoreCase(e, pair.ext)) return pair.rt;
    }
    return .invalid;
}

/// Return the file extension (with leading `.`) for a given `ResType`.
/// Returns `""` for unknown or `.invalid` types.
pub fn extensionForResType(rt: ResType) []const u8 {
    return switch (rt) {
        .bmp => ".bmp",
        .tga => ".tga",
        .wav => ".wav",
        .plt => ".plt",
        .ini => ".ini",
        .txt => ".txt",
        .mdl => ".mdl",
        .nss => ".nss",
        .ncs => ".ncs",
        .are => ".are",
        .set => ".set",
        .ifo => ".ifo",
        .bic => ".bic",
        .wok => ".wok",
        .@"2da" => ".2da",
        .tlk => ".tlk",
        .txi => ".txi",
        .git => ".git",
        .uti => ".uti",
        .utc => ".utc",
        .dlg => ".dlg",
        .itp => ".itp",
        .utt => ".utt",
        .dds => ".dds",
        .uts => ".uts",
        .ltr => ".ltr",
        .gff => ".gff",
        .fac => ".fac",
        .ute => ".ute",
        .utd => ".utd",
        .utp => ".utp",
        .dft => ".dft",
        .gic => ".gic",
        .gui => ".gui",
        .utm => ".utm",
        .dwk => ".dwk",
        .pwk => ".pwk",
        .jrl => ".jrl",
        .utw => ".utw",
        .ssf => ".ssf",
        .ndb => ".ndb",
        .ptm => ".ptm",
        .ptt => ".ptt",
        .mdx => ".mdx",
        else => "",
    };
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "fromBytes — raw origin, res_ref and res_type" {
    const id = fromBytes("appearance", .@"2da");
    try t.expectEqualStrings("appearance", id.resRefSlice());
    try t.expectEqual(ResType.@"2da", id.res_type);
    try t.expect(id.origin == .raw);
    try t.expect(id.parent == null);
    try t.expect(!id.isEmbedded());
    try t.expectEqual(@as(usize, 0), id.depth());
}

test "fromPath — filesystem origin, res_type inferred from extension" {
    const id = fromPath("/game/override/snd_birds01.uts");
    try t.expectEqualStrings("snd_birds01", id.resRefSlice());
    try t.expectEqual(ResType.uts, id.res_type);
    try t.expect(id.origin == .file_system);
    try t.expectEqualStrings("/game/override/snd_birds01.uts", id.origin.file_system.path);
    try t.expectEqualStrings(".uts", id.extension());
    try t.expect(!id.isEmbedded());
}

test "fromKeyEntry — bif_index and var_index preserved" {
    var ref = [_]u8{0} ** 16;
    @memcpy(ref[0..10], "appearance");
    const key_entry = keybif.KeyFile.KeyEntry{
        .res_ref = ref,
        .res_type = .@"2da",
        .res_id = (2 << 20) | 42,
    };
    // BifEntry.filename is []u8 — use a mutable local buffer.
    var fn_buf = "data/templates.bif".*;
    const bif_entry = keybif.KeyFile.BifEntry{
        .file_size = 0,
        .drives = 0,
        .filename = &fn_buf,
    };

    const id = fromKeyEntry(key_entry, "/game/chitin.key", bif_entry);
    try t.expectEqualStrings("appearance", id.resRefSlice());
    try t.expectEqual(ResType.@"2da", id.res_type);
    try t.expect(id.origin == .key_bif);
    try t.expectEqual(@as(u32, 2), id.origin.key_bif.bif_index);
    try t.expectEqual(@as(u32, 42), id.origin.key_bif.var_index);
    try t.expectEqualStrings("/game/chitin.key", id.origin.key_bif.key_path);
    try t.expectEqualStrings("data/templates.bif", id.origin.key_bif.bif_filename);
}

test "fromErfEntry — archive_path and entry_index preserved" {
    var ref = [_]u8{0} ** 16;
    @memcpy(ref[0..9], "module001");
    var empty_data = [_]u8{};
    const entry = erf_mod.ErfEntry{
        .res_ref = ref,
        .res_type = .ifo,
        .data = &empty_data,
    };

    const id = fromErfEntry(entry, "/saves/game1.sav", 3);
    try t.expectEqualStrings("module001", id.resRefSlice());
    try t.expectEqual(ResType.ifo, id.res_type);
    try t.expect(id.origin == .erf_archive);
    try t.expectEqual(@as(u32, 3), id.origin.erf_archive.entry_index);
    try t.expectEqualStrings("/saves/game1.sav", id.origin.erf_archive.path);
}

test "fromRimEntry — resource_id and name preserved" {
    var name_buf = [_]u8{0} ** 16;
    @memcpy(name_buf[0..11], "mainmenu001");
    const entry = rim_mod.RimKeyEntry.init(
        name_buf,
        11,
        @bitCast(@as(u16, @intFromEnum(ResType.git))),
        7,
        0,
        0,
        0,
    );

    const id = fromRimEntry(entry, "/rims/mainmenu.rim", 0);
    try t.expectEqualStrings("mainmenu001", id.resRefSlice());
    try t.expectEqual(ResType.git, id.res_type);
    try t.expect(id.origin == .rim_archive);
    try t.expectEqual(@as(i16, 7), id.origin.rim_archive.resource_id);
    try t.expectEqual(@as(u32, 0), id.origin.rim_archive.entry_index);
    try t.expectEqualStrings("/rims/mainmenu.rim", id.origin.rim_archive.path);
}

test "withParent — depth=1, rootAncestor is parent, isEmbedded=true" {
    const parent = fromBytes("pc_char", .utc);
    const child = fromBytes("sword001", .uti);
    const embedded = withParent(child, &parent, "ItemList", 2);

    try t.expect(embedded.isEmbedded());
    try t.expectEqual(@as(usize, 1), embedded.depth());
    try t.expectEqual(&parent, embedded.rootAncestor());
    try t.expectEqualStrings("ItemList", embedded.origin.embedded.field_label);
    try t.expectEqual(@as(u32, 2), embedded.origin.embedded.element_index);
    // res_ref and res_type are preserved from child
    try t.expectEqualStrings("sword001", embedded.resRefSlice());
    try t.expectEqual(ResType.uti, embedded.res_type);
}

test "withParent chained — depth=2, rootAncestor is grandparent" {
    const grandparent = fromBytes("k_endar_m28aa", .git);
    const parent_raw = fromBytes("pc_hero", .utc);
    const embedded_par = withParent(parent_raw, &grandparent, "Creature List", 0);
    const child = fromBytes("bnd_hdgr001", .uti);
    const doubly = withParent(child, &embedded_par, "ItemList", 1);

    try t.expectEqual(@as(usize, 2), doubly.depth());
    try t.expectEqual(&grandparent, doubly.rootAncestor());
}

test "eql — same identity vs differing res_type and origin tag" {
    const a = fromBytes("sword001", .uti);
    const b = fromBytes("sword001", .uti);
    const c = fromBytes("sword001", .utc); // different res_type
    const d = fromPath("/game/sword001.uti"); // different origin tag

    try t.expect(a.eql(&b));
    try t.expect(!a.eql(&c));
    try t.expect(!a.eql(&d));
}

test "resTypeFromExtension and extensionForResType round-trip" {
    const cases = [_]struct { ext: []const u8, rt: ResType }{
        .{ .ext = ".uts", .rt = .uts },
        .{ .ext = ".are", .rt = .are },
        .{ .ext = ".git", .rt = .git },
        .{ .ext = ".uti", .rt = .uti },
        .{ .ext = ".2da", .rt = .@"2da" },
        .{ .ext = ".tlk", .rt = .tlk },
        .{ .ext = ".ifo", .rt = .ifo },
        .{ .ext = ".utm", .rt = .utm },
    };
    for (cases) |c| {
        try t.expectEqual(c.rt, resTypeFromExtension(c.ext));
        try t.expectEqualStrings(c.ext, extensionForResType(c.rt));
    }
    // case-insensitive lookup
    try t.expectEqual(ResType.wav, resTypeFromExtension(".WAV"));
    try t.expectEqual(ResType.uts, resTypeFromExtension("UTS"));
    // unknown extension
    try t.expectEqual(ResType.invalid, resTypeFromExtension(".xyz"));
    try t.expectEqualStrings("", extensionForResType(.invalid));
}
