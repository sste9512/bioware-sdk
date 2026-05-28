//! Bioware Aurora Store (merchant) format. Reference:
//! `Bioware_Aurora_Store_Format.pdf`.
//!
//! Public API
//! ----------
//!   - `UtmFile`     — standalone UTM blueprint file (`"UTM "`).
//!   - `StoreStruct` — typed marshaller for a Store GFF struct, variant-aware
//!                     (blueprint / instance / game_instance).
//!   - Nested typed structs: `StoreContainer`, `StoreItem`, `StoreBaseItem`.
//!
//! Variants and which spec sections they cover
//! -------------------------------------------
//!   | Variant         | Spec sections        | Notes                          |
//!   | --------------- | -------------------- | ------------------------------ |
//!   | `blueprint`     | 2.1 + 2.2            | UTM top-level (`"UTM "`).      |
//!   | `instance`      | 2.1 + 2.3            | Store inside a module GIT file.|
//!   | `game_instance` | 2.1 + 2.3 + 2.4      | Savegame GIT. Adds ObjectId,   |
//!   |                 |                      | opaquely-preserved VarTable.   |
//!
//! Memory ownership
//! ----------------
//! `StoreStruct.fromGffStruct` uses two allocators:
//!   * `arena`          — owns every string / list / loc-string copy.
//!   * `preserve_alloc` — backs the optional `Preserved` sub-object that
//!                        holds the deep-cloned `VarTable` subtree (game-
//!                        instance only).
//!
//! `StoreStruct.deinit(preserve_alloc)` must be called when `preserved` is
//! non-null. `UtmFile.deinit` handles that automatically.

const std = @import("std");
const gff = @import("gff.zig");
const item = @import("item.zig");

// ============================================================================
// Errors / enums / constants
// ============================================================================

/// Errors raised by the store module. Composes with the underlying GFF
/// parser errors, the `item` module's errors, and any allocator failure.
pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
    WrongStructId,
} || gff.FormatError || std.mem.Allocator.Error;

/// Spec variant of a `StoreStruct`. Selects required-field set and
/// variant-specific field blocks.
pub const StoreVariant = enum {
    /// UTM top-level blueprint. Spec 2.2.
    blueprint,
    /// Store instance inside a module's GIT file. Spec 2.3.
    instance,
    /// Store instance inside a savegame GIT. Spec 2.4.
    game_instance,
};

/// Sentinel object id used by the engine when no object reference applies.
/// Spec 2.4: `INVALID_OBJECT_ID = 0x7F000000`.
pub const INVALID_OBJECT_ID: u32 = 0x7F00_0000;

/// StructID values used by Store nested lists.
pub const StructId = struct {
    /// `StoreBaseItem` (used in `WillNotBuy`/`WillOnlyBuy`). Spec 2.1.5.
    pub const store_base_item: u32 = 0x17E4D;
    /// `VarTable` element. Common GFF Section 3.
    pub const var_table: u32 = 0;
};

/// Spec 2.1.2 — fixed StructIDs for the five `StoreList` containers. Each
/// container holds the items belonging to one logical category.
pub const StoreContainerId = enum(u32) {
    armor = 0,
    misc = 1,
    potions = 2,
    rings = 3,
    weapons = 4,
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
    const f = g.getField(s, l) orelse return gff.ResRef{ .len = 0, .data = [_]u8{0} ** 16 };
    return switch (f.value) {
        .res_ref => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqResRef(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!gff.ResRef {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .res_ref => |v| v,
        else => error.WrongFieldType,
    };
}
fn reqExoStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error![]u8 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .exo_string => |v| a.dupe(u8, v),
        else => error.WrongFieldType,
    };
}
fn optExoStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!?[]u8 {
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
                try out.substrings.append(a, .{ .string_id = ss.string_id, .text = try a.dupe(u8, ss.text) });
            }
            return out;
        },
        else => return error.WrongFieldType,
    }
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
// Nested typed structs
// ============================================================================

/// `WillNotBuy`/`WillOnlyBuy` element. Spec 2.1.5 (StructID `0x17E4D`).
pub const StoreBaseItem = struct {
    pub const STRUCT_ID: u32 = StructId.store_base_item;
    /// Index into `baseitems.2da`.
    base_item: i32 = 0,
};

/// One item-for-sale inside a `StoreContainer`. Wraps `item.InventoryObject`
/// with the spec-2.1.4 store-only `Infinite` BYTE extension.
pub const StoreItem = struct {
    /// Embedded inventory object (blueprint or instance, per the parent
    /// `StoreVariant`). Carries the item's blueprint plus `Repos_PosX/Y`.
    inv: item.InventoryObject = .{},
    /// Spec 2.1.4 — `Infinite` BYTE. `null` ⇒ field is absent on disk; the
    /// engine treats absence as 0. A value of 1 means infinite supply.
    infinite: ?u8 = null,
};

/// One of the five fixed-StructID containers under `StoreList`.
/// Spec 2.1.2 / 2.1.3. A `StoreStruct` always carries all five (possibly
/// empty) in `StoreContainerId` order.
pub const StoreContainer = struct {
    /// Container category. Determines the on-disk StructID of this element.
    id: StoreContainerId,
    /// Items for sale in this container.
    items: []StoreItem = &[_]StoreItem{},
};

/// Opaque deep-clone of the game-instance `VarTable` subtree (Common GFF
/// Section 3). Allows byte-equivalent round-trip without modelling
/// VarTable schematically.
pub const Preserved = struct {
    holder: gff.GffFile,
    /// Struct indices in `holder` for the source `VarTable` elements.
    var_table_in_holder: ?[]u32 = null,

    /// Release the index array and the embedded holder GFF.
    pub fn deinit(self: *Preserved, alloc: std.mem.Allocator) void {
        if (self.var_table_in_holder) |a| alloc.free(a);
        self.holder.deinit();
    }
};

// ============================================================================
// StoreStruct
// ============================================================================

/// Typed view of a Store GFF struct. Marshals the Spec 2.1.1 common block
/// plus the variant-specific blocks (2.2 blueprint, 2.3 instance,
/// 2.4 game-instance) gated by `StoreVariant`.
///
/// Lifetime: all string / list / loc-string slices are owned by the arena
/// passed to `fromGffStruct`. `preserved`, when non-null, is owned by
/// `preserve_alloc` and **must** be released via `deinit`.
pub const StoreStruct = struct {
    // ---- 2.1.1 common ------------------------------------------------------

    /// Spec 2.1.1 — 1 if this is a black-market store (will buy stolen
    /// items); 0 otherwise.
    black_market: u8 = 0,
    /// Spec 2.1.1 — When `black_market == 1`, percentage of normal cost
    /// the store pays for stolen items.
    bm_mark_down: i32 = 0,
    /// Spec 2.1.1 — `-1` if the store won't identify items; else the
    /// identify price in gold.
    identify_price: i32 = -1,
    /// Spec 2.1.1 — Localized store name shown in the toolset palette and
    /// in-game.
    loc_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// Spec 2.1.1 — Sell markdown percentage. Items the store sells are
    /// priced at `normal_cost * mark_down / 100`. Usually ≥ 100.
    mark_down: i32 = 100,
    /// Spec 2.1.1 — Buy markup percentage. The store pays
    /// `normal_cost * mark_up / 100` when buying. Usually ≤ 100.
    mark_up: i32 = 100,
    /// Spec 2.1.1 — `-1` for no cap; else the maximum gold the store will
    /// pay for any single item.
    max_buy_price: i32 = -1,
    /// Spec 2.1.1 — OnOpenStore event script ResRef.
    on_open_store: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnStoreClosed event script ResRef.
    on_store_closed: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — For blueprints, equal to the UTM filename. For
    /// instances, ResRef of the blueprint the instance was created from.
    res_ref: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — `-1` for infinite gold; else the store's current gold
    /// pool used to pay for items bought from players.
    store_gold: i32 = -1,
    /// Spec 2.1.1 / 2.1.2 — Always five containers in
    /// `StoreContainerId` order. Lists may be empty.
    store_list: [5]StoreContainer = .{
        .{ .id = .armor },
        .{ .id = .misc },
        .{ .id = .potions },
        .{ .id = .rings },
        .{ .id = .weapons },
    },
    /// Spec 2.1.1 — Tag of this object. Up to 32 characters per spec.
    tag: []u8 = &[_]u8{},
    /// Spec 2.1.1 — BaseItem types the store refuses to buy. If non-empty,
    /// the engine ignores `will_only_buy`.
    will_not_buy: []StoreBaseItem = &[_]StoreBaseItem{},
    /// Spec 2.1.1 — BaseItem types the store will buy (others rejected).
    /// Ignored when `will_not_buy` is non-empty.
    will_only_buy: []StoreBaseItem = &[_]StoreBaseItem{},

    // ---- 2.2 blueprint-only ------------------------------------------------

    /// Spec 2.2 — Module designer comment. Blueprint only.
    comment: ?[]u8 = null,
    /// Spec 2.2 — Palette node ID this blueprint appears under. On-disk
    /// label is `ID`. Blueprint only.
    palette_id: ?u8 = null,

    // ---- 2.3 instance + game_instance --------------------------------------

    /// Spec 2.3 — ResRef of the blueprint this instance was created from.
    template_res_ref: ?gff.ResRef = null,
    /// Spec 2.3 — X coordinate within the area. Instance / game-instance.
    x_position: ?f32 = null,
    /// Spec 2.3 — Y coordinate within the area. Instance / game-instance.
    y_position: ?f32 = null,
    /// Spec 2.3 — Z coordinate within the area. Instance / game-instance.
    z_position: ?f32 = null,
    /// Spec 2.3 — X component of the orientation vector.
    x_orientation: ?f32 = null,
    /// Spec 2.3 — Y component of the orientation vector.
    y_orientation: ?f32 = null,

    // ---- 2.4 game_instance only --------------------------------------------

    /// Spec 2.4 — Engine-assigned object ID for this store instance.
    object_id: ?u32 = null,
    /// Spec 2.4 — Mirror of `preserved.var_table_in_holder` (slice owned by
    /// `preserved`; never freed separately).
    var_table: ?[]u32 = null,

    /// Opaque holder for the game-instance `VarTable` subtree. Allocated
    /// only when the source carries a `VarTable`. **MUST** be `deinit`-ed
    /// via `StoreStruct.deinit` when non-null.
    preserved: ?Preserved = null,

    /// Release the optional `preserved` sub-object. `preserve_alloc` must
    /// match the allocator originally passed to `fromGffStruct`.
    /// Idempotent: safe to call when `preserved` is already null.
    pub fn deinit(self: *StoreStruct, preserve_alloc: std.mem.Allocator) void {
        if (self.preserved) |*p| {
            p.deinit(preserve_alloc);
            self.preserved = null;
        }
    }

    /// Decode a Store GFF struct into a typed `StoreStruct`.
    ///
    /// Required fields: `ResRef`, `Tag`. For `.instance` / `.game_instance`,
    /// also `TemplateResRef` and the five position/orientation floats.
    /// For `.game_instance`, also `ObjectId`.
    ///
    /// Missing `StoreList` containers default to empty (no error). The
    /// `WillNotBuy` / `WillOnlyBuy` lists default to empty when absent.
    ///
    /// `preserve_alloc` only allocates when the source carries a
    /// `VarTable` (game-instance variant only). Even on success the caller
    /// must invoke `deinit(preserve_alloc)` to release any holder GFF.
    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        preserve_alloc: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: StoreVariant,
    ) Error!StoreStruct {
        var out: StoreStruct = .{};
        errdefer out.deinit(preserve_alloc);

        // ---- common fields ----
        out.black_market = try optByte(g, s, "BlackMarket", 0);
        out.bm_mark_down = try optInt(g, s, "BM_MarkDown", 0);
        out.identify_price = try optInt(g, s, "IdentifyPrice", -1);
        out.loc_name = try optExoLocDupe(arena, g, s, "LocName");
        out.mark_down = try optInt(g, s, "MarkDown", 100);
        out.mark_up = try optInt(g, s, "MarkUp", 100);
        out.max_buy_price = try optInt(g, s, "MaxBuyPrice", -1);
        out.on_open_store = try optResRef(g, s, "OnOpenStore");
        out.on_store_closed = try optResRef(g, s, "OnStoreClosed");
        out.res_ref = try reqResRef(g, s, "ResRef");
        out.store_gold = try optInt(g, s, "StoreGold", -1);
        out.tag = try reqExoStringDupe(arena, g, s, "Tag");
        out.will_not_buy = try parseStoreBaseItemList(arena, g, s, "WillNotBuy");
        out.will_only_buy = try parseStoreBaseItemList(arena, g, s, "WillOnlyBuy");
        try parseStoreList(arena, &out, g, s, variant);

        // ---- variant blocks ----
        if (variant == .blueprint) {
            out.comment = try optExoStringDupe(arena, g, s, "Comment");
            out.palette_id = try optByteOrNull(g, s, "ID");
        }
        if (variant == .instance or variant == .game_instance) {
            out.template_res_ref = try reqResRef(g, s, "TemplateResRef");
            out.x_position = try optFloat(g, s, "XPosition", 0);
            out.y_position = try optFloat(g, s, "YPosition", 0);
            out.z_position = try optFloat(g, s, "ZPosition", 0);
            out.x_orientation = try optFloat(g, s, "XOrientation", 0);
            out.y_orientation = try optFloat(g, s, "YOrientation", 0);
        }
        if (variant == .game_instance) {
            const oid = g.getField(s, "ObjectId") orelse return error.MissingRequiredField;
            out.object_id = switch (oid.value) {
                .dword => |v| v,
                else => return error.WrongFieldType,
            };
            try preserveGameFields(preserve_alloc, &out, g, s);
        }
        return out;
    }

    /// Emit every field of this StoreStruct into the GFF struct at
    /// `struct_idx` inside `g`. Fields can be emitted in any order — the
    /// `gff.GffFile.serialize` pass produces canonical alphabetical layout.
    ///
    /// Variant invariants:
    ///   * `.instance` / `.game_instance` require `template_res_ref != null`
    ///     and all five position/orientation floats non-null.
    ///   * `.game_instance` requires `object_id != null`.
    pub fn writeIntoGff(
        self: *const StoreStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: StoreVariant,
    ) !void {
        // Common fields.
        try g.addFieldToStruct(struct_idx, "BlackMarket", .{ .byte = self.black_market });
        try g.addFieldToStruct(struct_idx, "BM_MarkDown", .{ .int = self.bm_mark_down });
        try g.addFieldToStruct(struct_idx, "IdentifyPrice", .{ .int = self.identify_price });
        try g.addFieldToStruct(struct_idx, "LocName", .{
            .exo_loc_string = try cloneExoLoc(g.allocator, self.loc_name),
        });
        try g.addFieldToStruct(struct_idx, "MarkDown", .{ .int = self.mark_down });
        try g.addFieldToStruct(struct_idx, "MarkUp", .{ .int = self.mark_up });
        try g.addFieldToStruct(struct_idx, "MaxBuyPrice", .{ .int = self.max_buy_price });
        try g.addFieldToStruct(struct_idx, "OnOpenStore", .{ .res_ref = self.on_open_store });
        try g.addFieldToStruct(struct_idx, "OnStoreClosed", .{ .res_ref = self.on_store_closed });
        try g.addFieldToStruct(struct_idx, "ResRef", .{ .res_ref = self.res_ref });
        try g.addFieldToStruct(struct_idx, "StoreGold", .{ .int = self.store_gold });
        try writeStoreList(g, struct_idx, &self.store_list, variant);
        try g.addFieldToStruct(struct_idx, "Tag", .{ .exo_string = try g.allocator.dupe(u8, self.tag) });
        try writeStoreBaseItemList(g, struct_idx, "WillNotBuy", self.will_not_buy);
        try writeStoreBaseItemList(g, struct_idx, "WillOnlyBuy", self.will_only_buy);

        // Variant blocks.
        if (variant == .blueprint) {
            if (self.comment) |c| {
                try g.addFieldToStruct(struct_idx, "Comment", .{ .exo_string = try g.allocator.dupe(u8, c) });
            }
            if (self.palette_id) |v| try g.addFieldToStruct(struct_idx, "ID", .{ .byte = v });
        }
        if (variant == .instance or variant == .game_instance) {
            try g.addFieldToStruct(struct_idx, "TemplateResRef", .{ .res_ref = self.template_res_ref.? });
            try g.addFieldToStruct(struct_idx, "XPosition", .{ .float = self.x_position.? });
            try g.addFieldToStruct(struct_idx, "YPosition", .{ .float = self.y_position.? });
            try g.addFieldToStruct(struct_idx, "ZPosition", .{ .float = self.z_position.? });
            try g.addFieldToStruct(struct_idx, "XOrientation", .{ .float = self.x_orientation.? });
            try g.addFieldToStruct(struct_idx, "YOrientation", .{ .float = self.y_orientation.? });
        }
        if (variant == .game_instance) {
            try g.addFieldToStruct(struct_idx, "ObjectId", .{ .dword = self.object_id.? });
            if (self.preserved) |p| if (p.var_table_in_holder) |handles| {
                const new_arr = try g.allocator.alloc(u32, handles.len);
                errdefer g.allocator.free(new_arr);
                for (handles, 0..) |hidx, i| {
                    new_arr[i] = try g.cloneStructInto(&p.holder, hidx);
                }
                try g.addFieldToStruct(struct_idx, "VarTable", .{ .list = new_arr });
            };
        }
    }
};

// ============================================================================
// StoreList / StoreContainer / StoreItem
// ============================================================================

fn parseStoreList(
    arena: std.mem.Allocator,
    out: *StoreStruct,
    g: *const gff.GffFile,
    s: *const gff.Struct,
    variant: StoreVariant,
) Error!void {
    const f = g.getField(s, "StoreList") orelse return;
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    // Each container is identified by its StructID (0..4).
    for (arr) |idx| {
        const cs = &g.structs.items[idx];
        const cid: StoreContainerId = switch (cs.type_id) {
            0 => .armor,
            1 => .misc,
            2 => .potions,
            3 => .rings,
            4 => .weapons,
            else => return error.WrongStructId,
        };
        const slot: usize = @intFromEnum(cid);
        out.store_list[slot] = .{
            .id = cid,
            .items = try parseStoreItems(arena, g, cs, variant),
        };
    }
}

fn parseStoreItems(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    container_struct: *const gff.Struct,
    variant: StoreVariant,
) Error![]StoreItem {
    const f = g.getField(container_struct, "ItemList") orelse return arena.alloc(StoreItem, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(StoreItem, arr.len);
    for (arr, 0..) |idx, i| {
        const is = &g.structs.items[idx];
        out[i] = .{
            .inv = item.InventoryObject.fromGffStruct(arena, g, is) catch |e| switch (e) {
                error.MissingRequiredField, error.WrongFieldType => |x| return x,
                else => |x| return x,
            },
            .infinite = try optByteOrNull(g, is, "Infinite"),
        };
        _ = variant; // Variant is reflected in the embedded item's tables.
    }
    return out;
}

fn writeStoreList(
    g: *gff.GffFile,
    parent_idx: u32,
    containers: *const [5]StoreContainer,
    variant: StoreVariant,
) !void {
    var handles: [5]u32 = undefined;
    for (containers, 0..) |c, slot| {
        const cidx = try g.addStruct(@intFromEnum(c.id));
        try writeStoreItems(g, cidx, c.items, variant);
        handles[slot] = cidx;
    }
    const arr = try g.allocator.alloc(u32, 5);
    errdefer g.allocator.free(arr);
    @memcpy(arr, handles[0..]);
    try g.addFieldToStruct(parent_idx, "StoreList", .{ .list = arr });
}

fn writeStoreItems(
    g: *gff.GffFile,
    container_idx: u32,
    items: []const StoreItem,
    variant: StoreVariant,
) !void {
    _ = variant;
    if (items.len == 0) return;
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |sit, i| {
        // Spec 2.1.3: each InventoryObject's StructID equals its index in the
        // parent ItemList. `addStruct` returns the new struct's array index
        // (unrelated to `type_id`), so we explicitly set `type_id = i`.
        const sidx = try g.addStruct(@as(u32, @intCast(i)));
        try sit.inv.writeIntoGff(g.allocator, g, sidx);
        if (sit.infinite) |v| try g.addFieldToStruct(sidx, "Infinite", .{ .byte = v });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(container_idx, "ItemList", .{ .list = arr });
}

// ============================================================================
// WillNotBuy / WillOnlyBuy
// ============================================================================

fn parseStoreBaseItemList(
    arena: std.mem.Allocator,
    g: *const gff.GffFile,
    s: *const gff.Struct,
    label: []const u8,
) Error![]StoreBaseItem {
    const f = g.getField(s, label) orelse return arena.alloc(StoreBaseItem, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(StoreBaseItem, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        if (cs.type_id != StoreBaseItem.STRUCT_ID) return error.WrongStructId;
        const bi_field = g.getField(cs, "BaseItem") orelse return error.MissingRequiredField;
        out[i] = .{
            .base_item = switch (bi_field.value) {
                .int => |v| v,
                else => return error.WrongFieldType,
            },
        };
    }
    return out;
}

fn writeStoreBaseItemList(
    g: *gff.GffFile,
    parent_idx: u32,
    label: []const u8,
    items: []const StoreBaseItem,
) !void {
    if (items.len == 0) {
        // Emit empty list (spec says either list may be empty; preserving the
        // label keeps round-trips byte-stable for files that include it).
        const empty = try g.allocator.alloc(u32, 0);
        try g.addFieldToStruct(parent_idx, label, .{ .list = empty });
        return;
    }
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |bi, i| {
        const sidx = try g.addStruct(StoreBaseItem.STRUCT_ID);
        try g.addFieldToStruct(sidx, "BaseItem", .{ .int = bi.base_item });
        arr[i] = sidx;
    }
    try g.addFieldToStruct(parent_idx, label, .{ .list = arr });
}

// ============================================================================
// Preserved game-instance subtrees (VarTable)
// ============================================================================

fn preserveGameFields(
    preserve_alloc: std.mem.Allocator,
    out: *StoreStruct,
    g: *const gff.GffFile,
    s: *const gff.Struct,
) Error!void {
    const f = g.getField(s, "VarTable") orelse return;
    var holder = try gff.GffFile.init(preserve_alloc, [_]u8{ 0, 0, 0, 0 });
    errdefer holder.deinit();

    const var_table_copy: []u32 = switch (f.value) {
        .list => |arr| blk: {
            const copy = try preserve_alloc.alloc(u32, arr.len);
            errdefer preserve_alloc.free(copy);
            for (arr, 0..) |idx, i| copy[i] = try holder.cloneStructInto(g, idx);
            break :blk copy;
        },
        else => return error.WrongFieldType,
    };
    out.preserved = .{
        .holder = holder,
        .var_table_in_holder = var_table_copy,
    };
    out.var_table = var_table_copy;
}

// ============================================================================
// UtmFile
// ============================================================================

/// Standalone UTM blueprint container. Wraps a `.blueprint`-variant
/// `StoreStruct` together with the arena that owns its string/list data.
///
/// Typical workflow:
/// ```zig
/// var utm = try store.UtmFile.parse(gpa, bytes);
/// defer utm.deinit();
/// // ... read or mutate utm.store ...
/// const out = try utm.serialize(gpa);
/// defer gpa.free(out);
/// ```
pub const UtmFile = struct {
    /// Spec-mandated 4-byte GFF FileType for store blueprints.
    pub const FILE_TYPE = "UTM ";

    /// Arena that owns every string / list / loc-string slice referenced
    /// by `store`.
    arena: std.heap.ArenaAllocator,
    /// Long-lived allocator used to back `store.preserved`.
    parent_alloc: std.mem.Allocator,
    /// The decoded / to-be-encoded store blueprint.
    store: StoreStruct = .{},

    pub fn init(parent_alloc: std.mem.Allocator) UtmFile {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
            .parent_alloc = parent_alloc,
        };
    }

    /// Release every resource owned by this file. `Preserved` (if any) is
    /// freed first since it is backed by `parent_alloc`, then the arena.
    pub fn deinit(self: *UtmFile) void {
        self.store.deinit(self.parent_alloc);
        self.arena.deinit();
    }

    /// Parse a UTM byte stream. Verifies the `"UTM "` magic and decodes
    /// the top-level struct as a blueprint store.
    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtmFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = UtmFile.init(parent_alloc);
        errdefer out.deinit();
        out.store = try StoreStruct.fromGffStruct(
            out.arena.allocator(),
            parent_alloc,
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    /// Encode `store` (as a blueprint) into a fresh UTM byte stream. The
    /// caller owns the returned slice and must free it with `alloc`.
    pub fn serialize(self: *const UtmFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.store.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

fn mkResRef(s: []const u8) gff.ResRef {
    var r: gff.ResRef = .{ .len = @intCast(s.len), .data = [_]u8{0} ** 16 };
    @memcpy(r.data[0..s.len], s);
    return r;
}

test "empty UTM round-trip" {
    const gpa = t.allocator;

    var utm = UtmFile.init(gpa);
    defer utm.deinit();

    var tag_buf = [_]u8{ 'm', 'y', 's', 't', 'o', 'r', 'e' };
    utm.store.tag = tag_buf[0..];
    utm.store.res_ref = mkResRef("mystore");

    const bytes = try utm.serialize(gpa);
    defer gpa.free(bytes);

    var utm2 = try UtmFile.parse(gpa, bytes);
    defer utm2.deinit();

    try t.expectEqualStrings("mystore", utm2.store.tag);
    try t.expectEqual(@as(usize, 5), utm2.store.store_list.len);
    inline for (0..5) |i| {
        try t.expectEqual(@as(usize, 0), utm2.store.store_list[i].items.len);
    }
    try t.expectEqual(@as(usize, 0), utm2.store.will_not_buy.len);
    try t.expectEqual(@as(usize, 0), utm2.store.will_only_buy.len);
    try t.expectEqual(@as(i32, 100), utm2.store.mark_up);
    try t.expectEqual(@as(i32, -1), utm2.store.store_gold);
}

test "populated UTM byte-exact round-trip" {
    const gpa = t.allocator;

    var utm = UtmFile.init(gpa);
    defer utm.deinit();

    var tag_buf = [_]u8{ 'b', 'l', 'a', 'c', 'k', 's', 'm', 'i', 't', 'h' };
    utm.store.tag = tag_buf[0..];
    utm.store.res_ref = mkResRef("smithy01");
    utm.store.black_market = 1;
    utm.store.bm_mark_down = 60;
    utm.store.mark_up = 50;
    utm.store.mark_down = 120;
    utm.store.identify_price = 25;
    utm.store.max_buy_price = 5000;
    utm.store.store_gold = 1000;
    utm.store.on_open_store = mkResRef("smith_open");
    utm.store.on_store_closed = mkResRef("smith_close");

    var comment_buf = [_]u8{ 'd', 'e', 'm', 'o' };
    utm.store.comment = comment_buf[0..];
    utm.store.palette_id = 7;

    // Put one item in Weapons (StructID 4) with infinite=1 and one in Armor
    // (StructID 0) without the Infinite field.
    var weapons_items = [_]StoreItem{
        .{ .inv = .{ .item = blk: {
            var it: item.ItemStruct = .{};
            it.template_res_ref = mkResRef("nw_wswbs001");
            it.tag = "";
            break :blk it;
        } }, .infinite = 1 },
    };
    var armor_items = [_]StoreItem{
        .{ .inv = .{ .item = blk: {
            var it: item.ItemStruct = .{};
            it.template_res_ref = mkResRef("nw_aarcl001");
            it.tag = "";
            break :blk it;
        } }, .infinite = null },
    };
    utm.store.store_list[@intFromEnum(StoreContainerId.weapons)].items = weapons_items[0..];
    utm.store.store_list[@intFromEnum(StoreContainerId.armor)].items = armor_items[0..];

    var will_not_buy = [_]StoreBaseItem{ .{ .base_item = 42 } };
    utm.store.will_not_buy = will_not_buy[0..];

    const bytes = try utm.serialize(gpa);
    defer gpa.free(bytes);

    var utm2 = try UtmFile.parse(gpa, bytes);
    defer utm2.deinit();

    try t.expectEqualStrings("blacksmith", utm2.store.tag);
    try t.expectEqual(@as(u8, 1), utm2.store.black_market);
    try t.expectEqual(@as(i32, 60), utm2.store.bm_mark_down);
    try t.expectEqual(@as(i32, 50), utm2.store.mark_up);
    try t.expectEqual(@as(i32, 120), utm2.store.mark_down);
    try t.expectEqual(@as(i32, 25), utm2.store.identify_price);
    try t.expectEqual(@as(i32, 5000), utm2.store.max_buy_price);
    try t.expectEqual(@as(i32, 1000), utm2.store.store_gold);
    try t.expectEqualStrings("smith_open", utm2.store.on_open_store.data[0..utm2.store.on_open_store.len]);
    try t.expectEqualStrings("demo", utm2.store.comment.?);
    try t.expectEqual(@as(?u8, 7), utm2.store.palette_id);

    const weapons = utm2.store.store_list[@intFromEnum(StoreContainerId.weapons)];
    try t.expectEqual(@as(usize, 1), weapons.items.len);
    try t.expectEqual(@as(?u8, 1), weapons.items[0].infinite);
    try t.expectEqualStrings(
        "nw_wswbs001",
        weapons.items[0].inv.item.template_res_ref.data[0..weapons.items[0].inv.item.template_res_ref.len],
    );

    const armor = utm2.store.store_list[@intFromEnum(StoreContainerId.armor)];
    try t.expectEqual(@as(usize, 1), armor.items.len);
    try t.expectEqual(@as(?u8, null), armor.items[0].infinite);

    try t.expectEqual(@as(usize, 1), utm2.store.will_not_buy.len);
    try t.expectEqual(@as(i32, 42), utm2.store.will_not_buy[0].base_item);

    // Byte-exact second-round serialization.
    const bytes2 = try utm2.serialize(gpa);
    defer gpa.free(bytes2);
    try t.expectEqualSlices(u8, bytes, bytes2);
}

test "UTM WillOnlyBuy round-trip" {
    const gpa = t.allocator;

    var utm = UtmFile.init(gpa);
    defer utm.deinit();

    var tag_buf = [_]u8{ 'a', 'l', 'c' };
    utm.store.tag = tag_buf[0..];
    utm.store.res_ref = mkResRef("alc01");
    var only = [_]StoreBaseItem{ .{ .base_item = 7 }, .{ .base_item = 8 } };
    utm.store.will_only_buy = only[0..];

    const bytes = try utm.serialize(gpa);
    defer gpa.free(bytes);

    var utm2 = try UtmFile.parse(gpa, bytes);
    defer utm2.deinit();

    try t.expectEqual(@as(usize, 0), utm2.store.will_not_buy.len);
    try t.expectEqual(@as(usize, 2), utm2.store.will_only_buy.len);
    try t.expectEqual(@as(i32, 7), utm2.store.will_only_buy[0].base_item);
    try t.expectEqual(@as(i32, 8), utm2.store.will_only_buy[1].base_item);
}

test "UTM wrong magic rejected" {
    const gpa = t.allocator;

    var utm = UtmFile.init(gpa);
    defer utm.deinit();
    var tag_buf = [_]u8{'x'};
    utm.store.tag = tag_buf[0..];
    utm.store.res_ref = mkResRef("x");

    const bytes = try utm.serialize(gpa);
    defer gpa.free(bytes);

    // Mutate the magic bytes.
    const mut = try gpa.dupe(u8, bytes);
    defer gpa.free(mut);
    @memcpy(mut[0..4], "UTQ ");

    try t.expectError(error.InvalidFileType, UtmFile.parse(gpa, mut));
}

test "StoreStruct instance + game_instance round-trip" {
    const gpa = t.allocator;

    // Build an instance store inside a synthetic GFF and round-trip the
    // StoreStruct directly (no UtmFile wrapper, since instances live inside
    // GIT files in real usage).
    var g = try gff.GffFile.init(gpa, "GIT ".*);
    defer g.deinit();

    var instance: StoreStruct = .{};
    var tag_buf = [_]u8{ 'g', 'i', 't', 's', 't', 'o', 'r', 'e' };
    instance.tag = tag_buf[0..];
    instance.res_ref = mkResRef("storeblueprint");
    instance.template_res_ref = mkResRef("storeblueprint");
    instance.x_position = 1.0;
    instance.y_position = 2.0;
    instance.z_position = 3.0;
    instance.x_orientation = 0.5;
    instance.y_orientation = -0.5;

    const idx = try g.addStruct(0);
    try instance.writeIntoGff(&g, idx, .instance);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var parsed = try StoreStruct.fromGffStruct(arena.allocator(), gpa, &g, &g.structs.items[idx], .instance);
    defer parsed.deinit(gpa);

    try t.expectEqualStrings("gitstore", parsed.tag);
    try t.expectEqual(@as(?f32, 1.0), parsed.x_position);
    try t.expectEqual(@as(?f32, -0.5), parsed.y_orientation);
    try t.expectEqualStrings(
        "storeblueprint",
        parsed.template_res_ref.?.data[0..parsed.template_res_ref.?.len],
    );

    // game_instance variant: round-trip an ObjectId through a second GFF.
    var g2 = try gff.GffFile.init(gpa, "GIT ".*);
    defer g2.deinit();
    var gi: StoreStruct = .{};
    gi.tag = tag_buf[0..];
    gi.res_ref = mkResRef("storeblueprint");
    gi.template_res_ref = mkResRef("storeblueprint");
    gi.x_position = 0;
    gi.y_position = 0;
    gi.z_position = 0;
    gi.x_orientation = 1;
    gi.y_orientation = 0;
    gi.object_id = 0x1234;

    const gi_idx = try g2.addStruct(0);
    try gi.writeIntoGff(&g2, gi_idx, .game_instance);

    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    var gi_parsed = try StoreStruct.fromGffStruct(arena2.allocator(), gpa, &g2, &g2.structs.items[gi_idx], .game_instance);
    defer gi_parsed.deinit(gpa);

    try t.expectEqual(@as(?u32, 0x1234), gi_parsed.object_id);
}
