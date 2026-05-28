//! Bioware Aurora Creature format (UTC blueprints + Creature Structs in
//! GIT/savegame/BIC). Reference: `Bioware_Aurora_Creature_Format.pdf`.
//!
//! Public API
//! ----------
//!   - `UtcFile`        — standalone UTC blueprint file (`"UTC "`).
//!   - `CreatureStruct` — typed marshaller for a Creature GFF struct.
//!                        Variant-aware (blueprint / instance / game_instance).
//!   - Nested typed structs: `ClassEntry`, `FeatEntry`, `SkillEntry`,
//!     `SpecialAbility`, `Spell`, `EquippedItem`, `PersonalRep`,
//!     `Expression`, `Perception`, `SpellsPerDayEntry`.
//!
//! Variants and which spec sections they cover
//! -------------------------------------------
//!   | Variant         | Spec sections                | Notes                                      |
//!   | --------------- | ---------------------------- | ------------------------------------------ |
//!   | `blueprint`     | 2.1.1 + 2.2                  | Toolset-flavored Spell (Table 2.1.5).      |
//!   |                 |                              | EquippedItem has just `EquipRes`.          |
//!   | `instance`      | 2.1.1 + 2.3                  | EquippedItem embeds a full `item.ItemStruct` |
//!   |                 |                              | (`item.ItemVariant.container`).            |
//!   | `game_instance` | 2.1.1 + 2.3 + 2.5            | MemorizedSpell uses the game form          |
//!   |                 |                              | (Table 2.5.3). Many savegame-only fields.  |
//!
//! Memory ownership
//! ----------------
//! `CreatureStruct.fromGffStruct` takes two allocators:
//!   * `arena` — owns all string/list/loc-string copies. Typically an
//!               `ArenaAllocator` with the same lifetime as the decoded
//!               struct.
//!   * `preserve_alloc` — backs the optional `Preserved` sub-object that
//!                        holds deep-cloned opaque subtrees. Independent of
//!                        the arena so the inner `gff.GffFile` can be cleanly
//!                        `deinit`-ed.
//!
//! `CreatureStruct.deinit(preserve_alloc)` **must** be called when
//! `preserved != null`; otherwise the inner `gff.GffFile`'s allocations
//! leak. `UtcFile.deinit()` handles this automatically for top-level UTC
//! blueprints.
//!
//! Subtrees that are round-tripped opaquely (via `Preserved`)
//! ----------------------------------------------------------
//! These game-instance fields are not modelled schematically; they are
//! deep-cloned into a private `gff.GffFile` so they can be re-emitted
//! byte-equivalently:
//!   * `ActionList`        — Common GFF Section 6.
//!   * `EffectList`        — Common GFF Section 4.
//!   * `CombatInfo`        — StructID 51882.
//!   * `CombatRoundData`   — StructID 51930.
//!   * `VarTable`          — Common GFF Section 3.
//! `CreatureStruct.var_table` mirrors `Preserved.var_table_in_holder` for
//! caller convenience but is never freed separately.

const std = @import("std");
const gff = @import("gff.zig");
const item = @import("item.zig");

// ============================================================================
// Errors / enums / constants
// ============================================================================

/// Errors raised by the creature module. Composes with the underlying GFF
/// parser errors and any allocator failure.
///   * `MissingRequiredField` — a field listed as required by the spec was
///                              absent (e.g. `Tag`, `Appearance_Type`,
///                              `ClassList`, or variant-mandated `TemplateResRef`).
///   * `WrongFieldType`       — a field was found but its GFF type tag did
///                              not match the spec.
///   * `WrongStructId`        — a nested list element had a StructID other
///                              than the one mandated by the spec table.
///   * `TooFewClasses` /
///     `TooManyClasses`       — `ClassList` size outside the [1, 3] range
///                              required by Spec 2.1.1.
pub const Error = error{
    MissingRequiredField,
    WrongFieldType,
    WrongStructId,
    TooManyClasses,
    TooFewClasses,
} || gff.FormatError || std.mem.Allocator.Error;

/// Which spec variant a `CreatureStruct` represents. Selects required
/// fields, optional-field gating, and the schema of nested `Spell` /
/// `EquippedItem` elements.
pub const CreatureVariant = enum {
    /// UTC top-level blueprint. Spec 2.2.
    blueprint,
    /// Creature instance inside a GIT file. Spec 2.3.
    instance,
    /// Creature instance inside a savegame GIT or a BIC. Spec 2.5.
    game_instance,
};

/// Sentinel object id used by the engine when no object reference applies.
/// Spec 2.5: `INVALID_OBJECT_ID = 0x7F000000`.
pub const INVALID_OBJECT_ID: u32 = 0x7F00_0000;

/// StructID values for the nested list element types defined by the spec.
/// These are the values written into the GFF struct array and matched on
/// parse.
pub const StructId = struct {
    /// SkillList element. Spec 2.1.3.2.
    pub const skill: u32 = 0;
    /// FeatList element. Spec 2.1.3.1.
    pub const feat: u32 = 1;
    /// ClassList element. Spec 2.1.2.
    pub const class: u32 = 2;
    /// Spell entry in MemorizedListN / KnownListN. Spec 2.1.5 / 2.5.3 / 2.5.4.
    pub const spell: u32 = 3;
    /// SpecAbilityList element. Spec 2.1.3.3 / 2.1.5.
    pub const special_ability: u32 = 4;
    /// ExpressionList element. Spec 2.5 (Table 2.5.1).
    pub const expression: u32 = 5;
    /// PersonalRepList element. Spec 2.5.5 (`0xABED`).
    pub const personal_rep: u32 = 0xABED;
    /// SpellsPerDayList element. Spec 2.5.2 (`17767`).
    pub const spells_per_day: u32 = 17767;
    /// CombatInfo struct. Spec 2.5 (`51882`).
    pub const combat_info: u32 = 51882;
    /// CombatRoundData struct. Spec 2.5 (`51930`).
    pub const combat_round_data: u32 = 51930;
};

/// Equipped-item slot bit flags. Spec 2.1.1 `Equip_ItemList`: the slot flag
/// is written as the **StructID** of the EquippedItem element, not as a
/// labelled GFF field.
pub const EquipSlot = struct {
    /// Head slot.
    pub const head: u32 = 0x0001;
    /// Chest (armor body) slot.
    pub const chest: u32 = 0x0002;
    /// Boots slot.
    pub const boots: u32 = 0x0004;
    /// Arms (gloves/bracers) slot.
    pub const arms: u32 = 0x0008;
    /// Right-hand weapon slot.
    pub const right_hand: u32 = 0x0010;
    /// Left-hand weapon / shield slot.
    pub const left_hand: u32 = 0x0020;
    /// Cloak slot.
    pub const cloak: u32 = 0x0040;
    /// Left ring slot.
    pub const left_ring: u32 = 0x0080;
    /// Right ring slot.
    pub const right_ring: u32 = 0x0100;
    /// Neck / amulet slot.
    pub const neck: u32 = 0x0200;
    /// Belt slot.
    pub const belt: u32 = 0x0400;
    /// Arrows quiver slot.
    pub const arrows: u32 = 0x0800;
    /// Bullets pouch slot.
    pub const bullets: u32 = 0x1000;
    /// Bolts case slot.
    pub const bolts: u32 = 0x2000;
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
inline fn optChar(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: i8) Error!i8 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .char => |v| v,
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
inline fn optShort(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8, d: i16) Error!i16 {
    const f = g.getField(s, l) orelse return d;
    return switch (f.value) {
        .short => |v| v,
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
inline fn optResRef(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!gff.ResRef {
    const f = g.getField(s, l) orelse return gff.ResRef{ .len = 0, .data = [_]u8{0} ** 16 };
    return switch (f.value) {
        .res_ref => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqByte(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!u8 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .byte => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqWord(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!u16 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .word => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqInt(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!i32 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .int => |v| v,
        else => error.WrongFieldType,
    };
}
inline fn reqShort(g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error!i16 {
    const f = g.getField(s, l) orelse return error.MissingRequiredField;
    return switch (f.value) {
        .short => |v| v,
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
fn optExoStringDupe(a: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, l: []const u8) Error![]u8 {
    const f = g.getField(s, l) orelse return a.alloc(u8, 0);
    return switch (f.value) {
        .exo_string => |v| a.dupe(u8, v),
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

/// FeatList element. Spec 2.1.3.1 (StructID 1).
pub const FeatEntry = struct {
    pub const STRUCT_ID: u32 = StructId.feat;
    /// Index into `feat.2da`.
    feat: u16,
};

/// SkillList element. Spec 2.1.3.2 (StructID 0).
///
/// The element's **position** in the parent `skill_list` matches the row in
/// `skills.2da` one-to-one; the list should contain exactly as many
/// elements as `skills.2da` has rows.
pub const SkillEntry = struct {
    pub const STRUCT_ID: u32 = StructId.skill;
    /// Skill rank for the row identified by this element's list index.
    rank: u8,
};

/// SpecAbilityList element. Spec 2.1.3.3 / 2.1.5 (StructID 4).
pub const SpecialAbility = struct {
    pub const STRUCT_ID: u32 = StructId.special_ability;
    /// Index into `spells.2da`.
    spell: u16,
    /// Spell caster level at which this ability is cast.
    spell_caster_level: u8 = 0,
    /// Bit flags:
    ///   * `0x01` readied (always set by the toolset)
    ///   * `0x02` spontaneously cast
    ///   * `0x04` unlimited use
    spell_flags: u8 = 0,
};

/// PersonalRepList element. Spec 2.5.5 (StructID `0xABED`).
/// Records how this creature's reputation has been adjusted in the eyes of
/// another creature. Game-instance only.
pub const PersonalRep = struct {
    pub const STRUCT_ID: u32 = StructId.personal_rep;
    /// Reputation adjustment amount (e.g. −100 for an attack).
    amount: i32 = 0,
    /// Game day at which this adjustment was created.
    day: u32 = 0,
    /// 1 if the adjustment decays after a set time, 0 otherwise.
    decays: u8 = 0,
    /// Duration in seconds of the adjustment.
    duration: i32 = 0,
    /// Object ID of the other creature the adjustment applies to.
    object_id: u32 = INVALID_OBJECT_ID,
    /// Game time (within the day) at which this adjustment was created.
    time: u32 = 0,
};

/// ExpressionList element. Spec 2.5 Table 2.5.1 (StructID 5).
/// Game-instance only.
pub const Expression = struct {
    pub const STRUCT_ID: u32 = StructId.expression;
    /// Expression identifier.
    expression_id: i32 = 0,
    /// Free-form expression payload string.
    expression_string: []u8 = &[_]u8{},
};

/// PerceptionList element. Spec 2.5 Table 2.5.1 (StructID 0).
/// Game-instance only.
pub const Perception = struct {
    pub const STRUCT_ID: u32 = 0;
    /// Object ID of the perceived creature.
    object_id: u32 = INVALID_OBJECT_ID,
    /// Perception flag bits. The spec wording "BYTE 3" denotes a single
    /// BYTE storing up to 3 flag bits, not a 3-byte sequence.
    perception_data: u8 = 0,
};

/// SpellsPerDayList element. Spec 2.5.2 (StructID 17767).
/// Tracks remaining daily castings for spell-per-day classes (Bard, etc.).
/// Game-instance only.
pub const SpellsPerDayEntry = struct {
    pub const STRUCT_ID: u32 = StructId.spells_per_day;
    /// Number of spells left at the spell level identified by the
    /// element's index in `SpellsPerDayList` (0 = cantrips, 9 = level 9).
    num_spells_left: u8 = 0,
};

/// A spell entry in a class's `MemorizedListN` or `KnownListN`
/// (StructID 3). The on-disk schema depends on variant:
///
///   | Form                      | Fields written                        |
///   | ------------------------- | ------------------------------------- |
///   | Toolset / blueprint /     | `Spell` (WORD), `SpellFlags` (BYTE),  |
///   | instance (Spec 2.1.5)     | `SpellMetaMagic` (BYTE)               |
///   | Game memorized (2.5.3)    | `Spell`, `Ready` (INT),               |
///   |                           | `SpellMetaMagic` (SHORT)              |
///   | Game known (2.5.4)        | `Spell` only                          |
///
/// `spell_metamagic` is held as `i16` so a single field can carry either
/// the BYTE (toolset) or SHORT (game) form; the serializer narrows or
/// widens as appropriate. Metamagic bit values:
///   `0x00` none, `0x01` empower, `0x02` extend, `0x04` maximize,
///   `0x08` quicken, `0x10` silent, `0x20` still.
pub const Spell = struct {
    pub const STRUCT_ID: u32 = StructId.spell;
    /// Index into `spells.2da`.
    spell: u16 = 0,
    /// Toolset/blueprint/instance only: BYTE flag bits
    /// (`0x01` readied, `0x02` spontaneous, `0x04` unlimited use).
    /// Ignored when serialising the game memorized/known forms.
    spell_flags: u8 = 1,
    /// Metamagic flag bits. Width varies by variant; see the type-level
    /// doc-comment. Ignored when serialising the game known form.
    spell_metamagic: i16 = 0,
    /// Game memorized only: 1 if the spell is currently readied for casting.
    ready: ?i32 = null,
};

/// `Equip_ItemList` element. Spec 2.1.1 + 2.2 (blueprint) / 2.3 (instance).
///
/// The slot bit-flag (see `EquipSlot`) is encoded as the **StructID** of
/// this struct in the GFF, not as a labelled field. The body is
/// variant-dependent: blueprints carry just an `EquipRes` ResRef pointing
/// at the equipped item's UTI; instances embed the full item inline.
pub const EquippedItem = struct {
    /// Slot bit-flag (see `EquipSlot`). Used as the GFF StructID when
    /// serialised; populated from the StructID when parsed.
    slot: u32 = 0,
    /// Blueprint variant: ResRef of the UTI blueprint this slot is filled
    /// with. Required for `CreatureVariant.blueprint`, otherwise null.
    equip_res: ?gff.ResRef = null,
    /// Instance / game-instance variant: full embedded item, decoded via
    /// `item.ItemStruct.fromGffStruct(.., .container)`. Required for
    /// `CreatureVariant.instance` and `.game_instance`, otherwise null.
    item: ?item.ItemStruct = null,
};

/// ClassList element. Spec 2.1.2 + 2.5.2 (StructID 2).
///
/// A creature has 1–3 class entries. The shape of the entry varies along
/// two axes:
///
///   * **Preparation model.** Wizards / Clerics carry per-level
///     `MemorizedListN` lists (`memorized_lists`); Bards / Sorcerers carry
///     `KnownListN` lists (`known_lists`); non-caster classes carry neither.
///   * **Source variant.** Toolset / blueprint stores Spell entries with
///     `SpellFlags` + BYTE `SpellMetaMagic`; the game form omits flags and
///     promotes metamagic to SHORT for memorized spells (see `Spell`).
///
/// The 2.5.2 fields (`domain1`/`domain2`/`school`/`spells_per_day`) are
/// game-instance-only.
pub const ClassEntry = struct {
    pub const STRUCT_ID: u32 = StructId.class;
    /// Index into `classes.2da`.
    class: i32 = 0,
    /// Level in the class identified by `class`.
    class_level: i16 = 0,
    /// One `MemorizedListN` per spell level (N = 0..9). When non-null,
    /// **all ten** lists are emitted (most may be empty), matching how the
    /// toolset writes the structure. Null for classes that don't memorize.
    memorized_lists: ?[10][]Spell = null,
    /// One `KnownListN` per spell level (N = 0..9). Same all-or-nothing
    /// presence rule as `memorized_lists`. Null for classes without a
    /// spellbook (e.g. NPC wizards in the game form).
    known_lists: ?[10][]Spell = null,
    /// Cleric domain index into `domains.2da`. Game-instance only.
    domain1: ?u8 = null,
    /// Cleric secondary domain index into `domains.2da`. Game-instance only.
    domain2: ?u8 = null,
    /// Wizard school index into `spellschools.2da`. Game-instance only.
    school: ?u8 = null,
    /// 10 entries, one per spell level (0 = cantrips, 9 = level 9).
    /// Present only for spell-per-day classes (Bard, ...). Game-instance only.
    spells_per_day: ?[10]u8 = null,
};

/// Opaque deep-clones of game-instance subtrees not modelled
/// schematically by this module. Lets `CreatureStruct` round-trip those
/// subtrees byte-equivalently without ever interpreting them.
///
/// Backed by a private `gff.GffFile` (`holder`) with its own allocator; it
/// **must** be `deinit`-ed using the same allocator that was passed as
/// `preserve_alloc` to `CreatureStruct.fromGffStruct`. `CreatureStruct.deinit`
/// (and `UtcFile.deinit`) handle this for you.
pub const Preserved = struct {
    /// Private GFF file holding the cloned struct subtrees.
    holder: gff.GffFile,
    /// Struct indices in `holder` for `ActionList` elements (if present).
    action_list: ?[]u32 = null,
    /// Struct indices in `holder` for `EffectList` elements (if present).
    effect_list: ?[]u32 = null,
    /// Struct index in `holder` for the `CombatInfo` struct (if present).
    combat_info: ?u32 = null,
    /// Struct index in `holder` for the `CombatRoundData` struct (if present).
    combat_round_data: ?u32 = null,
    /// Indices in `holder` for elements of the source `VarTable` (Common
    /// GFF Section 3 schema). Mirrored by `CreatureStruct.var_table`.
    var_table_in_holder: ?[]u32 = null,

    /// Free the index arrays and the embedded holder GFF. `alloc` must
    /// match the `preserve_alloc` originally used to construct this object.
    pub fn deinit(self: *Preserved, alloc: std.mem.Allocator) void {
        if (self.action_list) |a| alloc.free(a);
        if (self.effect_list) |a| alloc.free(a);
        if (self.var_table_in_holder) |a| alloc.free(a);
        self.holder.deinit();
    }
};

// ============================================================================
// CreatureStruct
// ============================================================================

/// Typed view of a Creature GFF struct. Marshals all common (Spec 2.1.1)
/// fields plus the variant-specific blocks (Spec 2.2 blueprint,
/// 2.3 instance, 2.5 game-instance) gated by `CreatureVariant`.
///
/// Sub-objects:
///   * `class_list`, `feat_list`, `skill_list`, `spec_ability_list`,
///     `equip_item_list`, `item_list` — always-present (possibly empty) lists.
///   * `preserved` — opaque deep-clones of game-instance subtrees we don't
///     model schematically (see `Preserved`).
///
/// Lifetime: all string / list / loc-string slices are owned by the arena
/// passed to `fromGffStruct`. `preserved`, when non-null, is owned by the
/// `preserve_alloc` allocator and **must** be released via `deinit`.
pub const CreatureStruct = struct {
    // ---- 2.1.1 common ------------------------------------------------------
    /// Spec 2.1.1 — Index into `appearance.2da`.
    appearance_type: u16 = 0,
    /// Spec 2.1.1 — Index into `bodybag.2da`. Bodybag appearance used when
    /// the corpse fades after dropping items on death (only when
    /// `lootable == 0`).
    body_bag: u8 = 0,
    /// Spec 2.1.1 — Charisma ability score, before any bonuses/penalties.
    cha: u8 = 10,
    /// Spec 2.1.1 / 3.1 — Calculated Challenge Rating (additive component;
    /// see `cr_adjust` for the manual adjustment).
    challenge_rating: f32 = 0,
    /// Spec 2.1.1 / 2.1.2 — List of `ClassEntry`. Must contain between 1
    /// and 3 elements; enforced on parse.
    class_list: []ClassEntry = &[_]ClassEntry{},
    /// Spec 2.1.1 — Constitution ability score, before any bonuses/penalties.
    con: u8 = 10,
    /// Spec 2.1.1 — ResRef of the Conversation (DLG) run by
    /// `ActionStartConversation()`.
    conversation: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 / 3.1 — Manual adjustment added to `challenge_rating` to
    /// produce the final CR.
    cr_adjust: i32 = 0,
    /// Spec 2.1.1 / 3.4.3 — Current hit points, not counting bonuses. May
    /// be greater or less than `max_hit_points`.
    current_hit_points: i16 = 0,
    /// Spec 2.1.1 — Milliseconds before the corpse fades. Semantics depend
    /// on `lootable` (see spec).
    decay_time: u32 = 0,
    /// Spec 2.1.1 — Deity name (not used by the engine; scripts can read).
    deity: []u8 = &[_]u8{},
    /// Spec 2.1.1 — Examine description.
    description: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// Spec 2.1.1 — Dexterity ability score, before any bonuses/penalties.
    dex: u8 = 10,
    /// Spec 2.1.1 — 1 if this creature can be disarmed, 0 otherwise.
    disarmable: u8 = 0,
    /// Spec 2.1.1 — `Equip_ItemList`. Each element's slot bit-flag is
    /// encoded as its StructID; body schema depends on variant.
    equip_item_list: []EquippedItem = &[_]EquippedItem{},
    /// Spec 2.1.1 — Faction ID; index into `FactionList` in the module's
    /// `repute.fac`.
    faction_id: u16 = 0,
    /// Spec 2.1.1 / 2.1.3.1 — List of `FeatEntry`.
    feat_list: []FeatEntry = &[_]FeatEntry{},
    /// Spec 2.1.1 — Character first name.
    first_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// Spec 2.1.1 / 3.3 — Fortitude save bonus (added on top of base saves).
    /// On-disk label is lowercase `fortbonus`.
    fort_bonus: i16 = 0,
    /// Spec 2.1.1 — Index into `gender.2da`. 0 = male, 1 = female by
    /// hardcoded convention.
    gender: u8 = 0,
    /// Spec 2.1.1 — Good–Evil alignment axis, range 0..100
    /// (0 = most evil, 100 = most good).
    good_evil: u8 = 50,
    /// Spec 2.1.1 / 3.4.1 — Base maximum hit points (sum of rolled hit
    /// dice), not counting bonuses.
    hit_points: i16 = 0,
    /// Spec 2.1.1 — Intelligence ability score, before any
    /// bonuses/penalties. (Named `int_score` to avoid shadowing the
    /// builtin keyword `int`; on-disk label is `Int`.)
    int_score: u8 = 10,
    /// Spec 2.1.1 — 1 if a conversation with this creature can be
    /// interrupted.
    interruptable: u8 = 0,
    /// Spec 2.1.1 — 1 if the creature can never die.
    is_immortal: u8 = 0,
    /// Spec 2.1.1 — 1 if the creature is a player character.
    is_pc: u8 = 0,
    /// Spec 2.1.1 — `ItemList`: inventory objects in the creature's
    /// backpack. See Items document Section 3.
    item_list: []item.InventoryObject = &[_]item.InventoryObject{},
    /// Spec 2.1.1 — Character last name.
    last_name: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty },
    /// Spec 2.1.1 — Law–Chaos alignment axis, range 0..100
    /// (0 = most chaotic, 100 = most lawful).
    lawful_chaotic: u8 = 50,
    /// Spec 2.1.1 — 1 if the creature leaves a lootable corpse; 0 if it
    /// leaves a bodybag placeable instead.
    lootable: u8 = 0,
    /// Spec 2.1.1 / 3.4.2 — Maximum hit points after all bonuses.
    max_hit_points: i16 = 0,
    /// Spec 2.1.1 — Natural AC bonus.
    natural_ac: u8 = 0,
    /// Spec 2.1.1 — 1 if the creature cannot permanently ("chunky") die.
    no_perm_death: u8 = 0,
    /// Spec 2.1.1 — Index into `ranges.2da`. Spec mandates the value be in
    /// 9..13 (default 9).
    perception_range: u8 = 9,
    /// Spec 2.1.1 — Phenotype (only meaningful when the appearance row's
    /// MODELTYPE is "P"). 0 = normal, 1 = fat.
    phenotype: i32 = 0,
    /// Spec 2.1.1 — 1 if the creature is plot-essential.
    plot: u8 = 0,
    /// Spec 2.1.1 — Index into `portraits.2da`.
    portrait_id: u16 = 0,
    /// Spec 2.1.1 — Index into `racialtypes.2da`.
    race: u8 = 0,
    /// Spec 2.1.1 / 3.3 — Reflex save bonus. On-disk label is `refbonus`.
    ref_bonus: i16 = 0,
    /// Spec 2.1.1 — OnPhysicalAttacked event script ResRef.
    script_attacked: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnDamaged event script ResRef.
    script_damaged: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnDeath event script ResRef.
    script_death: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnConversation event script ResRef.
    script_dialogue: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnInventoryDisturbed event script ResRef.
    script_disturbed: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnEndCombatRound event script ResRef.
    script_end_round: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnHeartbeat event script ResRef.
    script_heartbeat: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnBlocked event script ResRef.
    script_on_blocked: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnPerception event script ResRef.
    script_on_notice: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnRested event script ResRef.
    script_rested: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnSpawnIn event script ResRef.
    script_spawn: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnSpellCastAt event script ResRef.
    script_spell_at: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 — OnUserDefined event script ResRef.
    /// On-disk label is `ScriptuserDefine` (the inconsistent casing is
    /// preserved on the wire).
    script_user_define: gff.ResRef = .{ .len = 0, .data = [_]u8{0} ** 16 },
    /// Spec 2.1.1 / 2.1.3.2 — `SkillList`. Index of each element maps 1:1
    /// to a row of `skills.2da`.
    skill_list: []SkillEntry = &[_]SkillEntry{},
    /// Spec 2.1.1 — Index into `soundset.2da`.
    sound_set_file: u16 = 0,
    /// Spec 2.1.1 / 2.1.3.3 — `SpecAbilityList`.
    spec_ability_list: []SpecialAbility = &[_]SpecialAbility{},
    /// Spec 2.1.1 — Index into `packages.2da`. Levelup package used by
    /// `LevelUpHenchman()`.
    starting_package: u8 = 0,
    /// Spec 2.1.1 — Strength ability score, before any bonuses/penalties.
    str: u8 = 10,
    /// Spec 2.1.1 — Subrace string (not used by the engine; scripts can
    /// read).
    subrace: []u8 = &[_]u8{},
    /// Spec 2.1.1 — Tag of this object.
    tag: []u8 = &[_]u8{},
    /// Spec 2.1.1 — Index into `tailmodel.2da`.
    tail: u8 = 0,
    /// Spec 2.1.1 — Index into `creaturespeed.2da`.
    walk_rate: i32 = 0,
    /// Spec 2.1.1 / 3.3 — Will save bonus. On-disk label is `willbonus`.
    will_bonus: i16 = 0,
    /// Spec 2.1.1 — Index into `wingmodel.2da`.
    wings: u8 = 0,

    // ---- 2.2 blueprint-only ------------------------------------------------
    /// Spec 2.2 — Module designer comment. Blueprint only.
    comment: ?[]u8 = null,
    /// Spec 2.2 — ID of the palette node this blueprint appears under.
    /// Blueprint only.
    palette_id: ?u8 = null,
    /// Spec 2.2 / 2.3 — ResRef of the blueprint this struct represents (or
    /// was created from, for instances).
    ///
    /// **Required** for `CreatureVariant.blueprint` and `.instance`;
    /// `writeIntoGff` will panic via `.?` if null. Optional for
    /// `.game_instance`.
    template_res_ref: ?gff.ResRef = null,

    // ---- 2.3 position/orientation (instance + game_instance) ---------------
    /// Spec 2.3 — X coordinate of the creature within its area. Instance /
    /// game-instance only.
    x_position: ?f32 = null,
    /// Spec 2.3 — Y coordinate within the area. Instance / game-instance only.
    y_position: ?f32 = null,
    /// Spec 2.3 — Z coordinate within the area. Instance / game-instance only.
    z_position: ?f32 = null,
    /// Spec 2.3 — X component of the orientation vector. Instance /
    /// game-instance only.
    x_orientation: ?f32 = null,
    /// Spec 2.3 — Y component of the orientation vector. Instance /
    /// game-instance only.
    y_orientation: ?f32 = null,

    // ---- 2.5 game_instance --------------------------------------------------
    // All fields in this block are Spec 2.5 Table 2.5.1 unless otherwise
    // noted, and are only parsed/emitted when the variant is `.game_instance`.

    /// Spec 2.5 — Character age (player characters only; 0 for NPCs).
    age: ?i32 = null,
    /// Spec 2.5 — Ambient animation state.
    ambient_anim_state: ?u8 = null,
    /// Spec 2.5 — Game day the current animation started on.
    animation_day: ?u32 = null,
    /// Spec 2.5 — Game time the current animation started at.
    animation_time: ?u32 = null,
    /// Spec 2.5 — Head appearance variant.
    appearance_head: ?u8 = null,
    /// Spec 2.5 — Object ID of the area containing this creature.
    area_id: ?u32 = null,
    /// Spec 2.5 — Right-foot armor part index.
    armor_part_r_foot: ?u8 = null,
    /// Spec 2.5 — Base attack bonus override (cached by the engine).
    base_attack_bonus: ?u8 = null,
    /// Spec 2.5 — Object ID of the bodybag placeable for this corpse.
    body_bag_id: ?u32 = null,
    /// Spec 2.5 — Index into `creaturesize.2da`; matches hardcoded engine
    /// constants.
    creature_size: ?i32 = null,
    /// Spec 2.5 — 1 if dead and still mouse-selectable, 0 otherwise.
    dead_selectable: ?u8 = null,
    /// Spec 2.5 — 1 if creature is in detect mode, 0 otherwise.
    detect_mode: ?u8 = null,
    /// Spec 2.5 — `ExpressionList` (StructID 5). Null when absent in source.
    expression_list: ?[]Expression = null,
    /// Spec 2.5 — Experience points (0 for non-PCs).
    experience: ?u32 = null,
    /// Spec 2.5 — Familiar's name.
    familiar_name: ?[]u8 = null,
    /// Spec 2.5 — Familiar type.
    familiar_type: ?i32 = null,
    /// Spec 2.5 — Fortitude save throw value (CHAR / i8).
    fort_save_throw: ?i8 = null,
    /// Spec 2.5 — Amount of gold being carried.
    gold: ?u32 = null,
    /// Spec 2.5 — 1 if the creature accepts commands, 0 otherwise.
    is_commandable: ?u8 = null,
    /// Spec 2.5 — 1 if the engine may destroy this object, 0 otherwise.
    is_destroyable: ?u8 = null,
    /// Spec 2.5 — 1 if the creature is a Dungeon Master, 0 otherwise.
    is_dm: ?u8 = null,
    /// Spec 2.5 — 1 if the creature can be raised from the dead, 0 otherwise.
    is_raiseable: ?u8 = null,
    /// Spec 2.5 — Listen-mode flag.
    listening: ?u8 = null,
    /// Spec 2.5 — Object ID of the master / owner (henchmen, familiars).
    master_id: ?u32 = null,
    /// Spec 2.5 — Class index queued for the next levelup. On-disk label
    /// is `MClassLevUpIn`.
    m_class_lev_up_in: ?u8 = null,
    /// Spec 2.5 — Object ID assigned by the engine to this creature.
    object_id: ?u32 = null,
    /// Spec 2.5 — BAB override (0 to use the normal calculated BAB).
    override_bab: ?u8 = null,
    /// Spec 2.5 — `PerceptionList` (StructID 0). Null when absent in source.
    perception_list: ?[]Perception = null,
    /// Spec 2.5 / 2.5.5 — `PersonalRepList` (StructID `0xABED`). Null when
    /// absent in source.
    personal_rep_list: ?[]PersonalRep = null,
    /// Spec 2.5 — 1 if the creature is currently polymorphed, 0 otherwise.
    pm_is_polymorphed: ?u8 = null,
    /// Spec 2.5 — Pre-game current HP snapshot.
    pregame_current: ?i16 = null,
    /// Spec 2.5 — Reflex save throw value (CHAR / i8).
    ref_save_throw: ?i8 = null,
    /// Spec 2.5 — Object ID of the placeable the creature is sitting on.
    sit_object: ?u32 = null,
    /// Spec 2.5 — Unspent skill points.
    skill_points: ?u16 = null,
    /// Spec 2.5 — 1 if the creature is in stealth mode, 0 otherwise.
    stealth_mode: ?u8 = null,
    /// Spec 2.5 — Caller-facing alias of `preserved.var_table_in_holder`.
    /// Non-null when the source had a `VarTable`; the slice is owned by
    /// `preserved` and **must not** be freed separately.
    var_table: ?[]u32 = null,
    /// Spec 2.5 — Will save throw value (CHAR / i8).
    will_save_throw: ?i8 = null,

    /// Opaque holder for game-instance pass-through subtrees
    /// (`ActionList`, `EffectList`, `CombatInfo`, `CombatRoundData`,
    /// `VarTable`). Allocated only when at least one of these is present
    /// in the source. **MUST** be `deinit`-ed via `CreatureStruct.deinit`
    /// when non-null.
    preserved: ?Preserved = null,

    /// Release the optional `preserved` sub-object (the rest is arena-owned
    /// and does not need explicit cleanup). `preserve_alloc` must match the
    /// allocator that was originally passed to `fromGffStruct`. Idempotent:
    /// safe to call when `preserved` is already null.
    pub fn deinit(self: *CreatureStruct, preserve_alloc: std.mem.Allocator) void {
        if (self.preserved) |*p| {
            p.deinit(preserve_alloc);
            self.preserved = null;
        }
    }

    /// Decode a Creature GFF struct into a typed `CreatureStruct`.
    ///
    /// Parameters:
    ///   * `arena`          — owns all returned string / list / loc-string
    ///                        slices. Typically an `ArenaAllocator` with
    ///                        the lifetime of the result.
    ///   * `preserve_alloc` — backs the optional `Preserved` sub-object.
    ///                        Must outlive the result; pass a long-lived
    ///                        allocator distinct from the arena.
    ///   * `g`, `s`         — source GFF file and the specific struct to
    ///                        decode (typically `&g.structs.items[0]` for a
    ///                        UTC top-level, or a child struct for an
    ///                        instance inside a GIT/savegame/BIC).
    ///   * `variant`        — selects required fields and nested schemas
    ///                        (see `CreatureVariant`).
    ///
    /// Required-field set:
    ///   * Always: `Tag`, `Appearance_Type`, `ClassList` (1..3 elements).
    ///   * `blueprint` / `instance`: also `TemplateResRef`.
    ///
    /// `preserve_alloc` only sees allocations when the source carries one
    /// of `ActionList`, `EffectList`, `CombatInfo`, `CombatRoundData`, or
    /// `VarTable` (game-instance variant only). Even on success the caller
    /// must invoke `deinit(preserve_alloc)` to release any holder GFF.
    ///
    /// Errors: see `Error`. Notably `TooFewClasses` / `TooManyClasses`
    /// when `class_list.len` is outside `[1, 3]`.
    pub fn fromGffStruct(
        arena: std.mem.Allocator,
        preserve_alloc: std.mem.Allocator,
        g: *const gff.GffFile,
        s: *const gff.Struct,
        variant: CreatureVariant,
    ) Error!CreatureStruct {
        var out: CreatureStruct = .{};
        errdefer out.deinit(preserve_alloc);

        out.tag = try reqExoStringDupe(arena, g, s, "Tag");
        out.appearance_type = try reqWord(g, s, "Appearance_Type");
        out.class_list = try parseClassList(arena, g, s, variant);
        if (out.class_list.len == 0) return error.TooFewClasses;
        if (out.class_list.len > 3) return error.TooManyClasses;
        if (variant == .blueprint or variant == .instance) {
            out.template_res_ref = try reqResRef(g, s, "TemplateResRef");
        } else if (g.getField(s, "TemplateResRef") != null) {
            out.template_res_ref = try optResRef(g, s, "TemplateResRef");
        }

        out.body_bag = try optByte(g, s, "BodyBag", 0);
        out.cha = try optByte(g, s, "Cha", 10);
        out.challenge_rating = try optFloat(g, s, "ChallengeRating", 0);
        out.con = try optByte(g, s, "Con", 10);
        out.conversation = try optResRef(g, s, "Conversation");
        out.cr_adjust = try optInt(g, s, "CRAdjust", 0);
        out.current_hit_points = try optShort(g, s, "CurrentHitPoints", 0);
        out.decay_time = try optDword(g, s, "DecayTime", 0);
        out.deity = try optExoStringDupe(arena, g, s, "Deity");
        out.description = try optExoLocDupe(arena, g, s, "Description");
        out.dex = try optByte(g, s, "Dex", 10);
        out.disarmable = try optByte(g, s, "Disarmable", 0);
        out.faction_id = try optWord(g, s, "FactionID", 0);
        out.first_name = try optExoLocDupe(arena, g, s, "FirstName");
        out.fort_bonus = try optShort(g, s, "fortbonus", 0);
        out.gender = try optByte(g, s, "Gender", 0);
        out.good_evil = try optByte(g, s, "GoodEvil", 50);
        out.hit_points = try optShort(g, s, "HitPoints", 0);
        out.int_score = try optByte(g, s, "Int", 10);
        out.interruptable = try optByte(g, s, "Interruptable", 0);
        out.is_immortal = try optByte(g, s, "IsImmortal", 0);
        out.is_pc = try optByte(g, s, "IsPC", 0);
        out.last_name = try optExoLocDupe(arena, g, s, "LastName");
        out.lawful_chaotic = try optByte(g, s, "LawfulChaotic", 50);
        out.lootable = try optByte(g, s, "Lootable", 0);
        out.max_hit_points = try optShort(g, s, "MaxHitPoints", 0);
        out.natural_ac = try optByte(g, s, "NaturalAC", 0);
        out.no_perm_death = try optByte(g, s, "NoPermDeath", 0);
        out.perception_range = try optByte(g, s, "PerceptionRange", 9);
        out.phenotype = try optInt(g, s, "Phenotype", 0);
        out.plot = try optByte(g, s, "Plot", 0);
        out.portrait_id = try optWord(g, s, "PortraitId", 0);
        out.race = try optByte(g, s, "Race", 0);
        out.ref_bonus = try optShort(g, s, "refbonus", 0);
        out.script_attacked = try optResRef(g, s, "ScriptAttacked");
        out.script_damaged = try optResRef(g, s, "ScriptDamaged");
        out.script_death = try optResRef(g, s, "ScriptDeath");
        out.script_dialogue = try optResRef(g, s, "ScriptDialogue");
        out.script_disturbed = try optResRef(g, s, "ScriptDisturbed");
        out.script_end_round = try optResRef(g, s, "ScriptEndRound");
        out.script_heartbeat = try optResRef(g, s, "ScriptHeartbeat");
        out.script_on_blocked = try optResRef(g, s, "ScriptOnBlocked");
        out.script_on_notice = try optResRef(g, s, "ScriptOnNotice");
        out.script_rested = try optResRef(g, s, "ScriptRested");
        out.script_spawn = try optResRef(g, s, "ScriptSpawn");
        out.script_spell_at = try optResRef(g, s, "ScriptSpellAt");
        out.script_user_define = try optResRef(g, s, "ScriptuserDefine");
        out.sound_set_file = try optWord(g, s, "SoundSetFile", 0);
        out.starting_package = try optByte(g, s, "StartingPackage", 0);
        out.str = try optByte(g, s, "Str", 10);
        out.subrace = try optExoStringDupe(arena, g, s, "Subrace");
        out.tail = try optByte(g, s, "Tail", 0);
        out.walk_rate = try optInt(g, s, "WalkRate", 0);
        out.will_bonus = try optShort(g, s, "willbonus", 0);
        out.wings = try optByte(g, s, "Wings", 0);

        out.feat_list = try parseFeatList(arena, g, s);
        out.skill_list = try parseSkillList(arena, g, s);
        out.spec_ability_list = try parseSpecAbilityList(arena, g, s);
        out.equip_item_list = try parseEquipItemList(arena, g, s, variant);
        out.item_list = try parseItemList(arena, g, s);

        if (variant == .blueprint) {
            if (g.getField(s, "Comment")) |_| out.comment = try optExoStringDupe(arena, g, s, "Comment");
            if (g.getField(s, "PaletteID")) |_| out.palette_id = try optByte(g, s, "PaletteID", 0);
        }
        if (variant == .instance or variant == .game_instance) {
            if (g.getField(s, "XPosition")) |_| out.x_position = try optFloat(g, s, "XPosition", 0);
            if (g.getField(s, "YPosition")) |_| out.y_position = try optFloat(g, s, "YPosition", 0);
            if (g.getField(s, "ZPosition")) |_| out.z_position = try optFloat(g, s, "ZPosition", 0);
            if (g.getField(s, "XOrientation")) |_| out.x_orientation = try optFloat(g, s, "XOrientation", 0);
            if (g.getField(s, "YOrientation")) |_| out.y_orientation = try optFloat(g, s, "YOrientation", 0);
        }
        if (variant == .game_instance) {
            try parseGameInstanceFields(arena, &out, g, s);
            try preserveGameFields(preserve_alloc, &out, g, s);
        }
        return out;
    }

    /// Append every field of this CreatureStruct to the GFF struct at
    /// `struct_idx` inside `g`. Field labels are emitted in
    /// alphabetical-by-label order so output is canonical & deterministic
    /// (same convention as `item.zig`).
    ///
    /// Allocations use `g.allocator`, which the caller's `gff.GffFile`
    /// owns; the resulting GFF can be `serialize`-d without further setup.
    ///
    /// Variant invariants (violations cause a runtime panic via `.?` or
    /// missing-field assertions):
    ///   * `.blueprint` and `.instance` require `template_res_ref != null`.
    ///   * `.blueprint` requires every `EquippedItem.equip_res` to be set.
    ///   * `.instance` / `.game_instance` require every `EquippedItem.item`
    ///     to be set.
    ///
    /// For the `.game_instance` variant any non-null `preserved` subtrees
    /// (`ActionList`, `EffectList`, `CombatInfo`, `CombatRoundData`,
    /// `VarTable`) are deep-cloned back into `g` from `preserved.holder`.
    pub fn writeIntoGff(
        self: *const CreatureStruct,
        g: *gff.GffFile,
        struct_idx: u32,
        variant: CreatureVariant,
    ) !void {
        try emitCommon(self, g, struct_idx, variant);
        try emitVariantSpecific(self, g, struct_idx, variant);
    }
};

// ============================================================================
// Parse helpers
// ============================================================================

fn parseClassList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, variant: CreatureVariant) Error![]ClassEntry {
    const f = g.getField(s, "ClassList") orelse return error.MissingRequiredField;
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(ClassEntry, arr.len);
    for (arr, 0..) |child_idx, i| {
        const cs = &g.structs.items[child_idx];
        if (cs.type_id != ClassEntry.STRUCT_ID) return error.WrongStructId;
        var entry: ClassEntry = .{
            .class = try reqInt(g, cs, "Class"),
            .class_level = try reqShort(g, cs, "ClassLevel"),
        };
        var has_mem = false;
        var has_known = false;
        var n: u8 = 0;
        while (n < 10) : (n += 1) {
            var buf: [16]u8 = undefined;
            const ml = std.fmt.bufPrint(&buf, "MemorizedList{d}", .{n}) catch unreachable;
            if (g.getField(cs, ml) != null) has_mem = true;
            var buf2: [16]u8 = undefined;
            const kl = std.fmt.bufPrint(&buf2, "KnownList{d}", .{n}) catch unreachable;
            if (g.getField(cs, kl) != null) has_known = true;
        }
        if (has_mem) {
            var lists: [10][]Spell = undefined;
            n = 0;
            while (n < 10) : (n += 1) {
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "MemorizedList{d}", .{n}) catch unreachable;
                lists[n] = try parseSpellList(arena, g, cs, label, variant, true);
            }
            entry.memorized_lists = lists;
        }
        if (has_known) {
            var lists: [10][]Spell = undefined;
            n = 0;
            while (n < 10) : (n += 1) {
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "KnownList{d}", .{n}) catch unreachable;
                lists[n] = try parseSpellList(arena, g, cs, label, variant, false);
            }
            entry.known_lists = lists;
        }
        if (variant == .game_instance) {
            if (g.getField(cs, "Domain1")) |_| entry.domain1 = try optByte(g, cs, "Domain1", 0);
            if (g.getField(cs, "Domain2")) |_| entry.domain2 = try optByte(g, cs, "Domain2", 0);
            if (g.getField(cs, "School")) |_| entry.school = try optByte(g, cs, "School", 0);
            if (g.getField(cs, "SpellsPerDayList")) |spd_field| {
                const spd_arr = switch (spd_field.value) {
                    .list => |a| a,
                    else => return error.WrongFieldType,
                };
                var spd: [10]u8 = [_]u8{0} ** 10;
                const m = @min(spd_arr.len, 10);
                var k: usize = 0;
                while (k < m) : (k += 1) {
                    const child = &g.structs.items[spd_arr[k]];
                    spd[k] = try optByte(g, child, "NumSpellsLeft", 0);
                }
                entry.spells_per_day = spd;
            }
        }
        out[i] = entry;
    }
    return out;
}

fn parseSpellList(arena: std.mem.Allocator, g: *const gff.GffFile, parent: *const gff.Struct, label: []const u8, variant: CreatureVariant, is_memorized: bool) Error![]Spell {
    const f = g.getField(parent, label) orelse return arena.alloc(Spell, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Spell, arr.len);
    for (arr, 0..) |idx, i| {
        const ss = &g.structs.items[idx];
        if (ss.type_id != Spell.STRUCT_ID) return error.WrongStructId;
        var sp: Spell = .{ .spell = try reqWord(g, ss, "Spell") };
        if (variant == .game_instance) {
            if (is_memorized) {
                sp.ready = try optInt(g, ss, "Ready", 0);
                sp.spell_metamagic = try optShort(g, ss, "SpellMetaMagic", 0);
            }
        } else {
            sp.spell_flags = try optByte(g, ss, "SpellFlags", 1);
            sp.spell_metamagic = @intCast(try optByte(g, ss, "SpellMetaMagic", 0));
        }
        out[i] = sp;
    }
    return out;
}

fn parseFeatList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]FeatEntry {
    const f = g.getField(s, "FeatList") orelse return arena.alloc(FeatEntry, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(FeatEntry, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        if (cs.type_id != FeatEntry.STRUCT_ID) return error.WrongStructId;
        out[i] = .{ .feat = try reqWord(g, cs, "Feat") };
    }
    return out;
}

fn parseSkillList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]SkillEntry {
    const f = g.getField(s, "SkillList") orelse return arena.alloc(SkillEntry, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(SkillEntry, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        if (cs.type_id != SkillEntry.STRUCT_ID) return error.WrongStructId;
        out[i] = .{ .rank = try optByte(g, cs, "Rank", 0) };
    }
    return out;
}

fn parseSpecAbilityList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]SpecialAbility {
    const f = g.getField(s, "SpecAbilityList") orelse return arena.alloc(SpecialAbility, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(SpecialAbility, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        if (cs.type_id != SpecialAbility.STRUCT_ID) return error.WrongStructId;
        out[i] = .{
            .spell = try reqWord(g, cs, "Spell"),
            .spell_caster_level = try optByte(g, cs, "SpellCasterLevel", 0),
            .spell_flags = try optByte(g, cs, "SpellFlags", 0),
        };
    }
    return out;
}

fn parseEquipItemList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct, variant: CreatureVariant) Error![]EquippedItem {
    const f = g.getField(s, "Equip_ItemList") orelse return arena.alloc(EquippedItem, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(EquippedItem, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        var eq: EquippedItem = .{ .slot = cs.type_id };
        switch (variant) {
            .blueprint => eq.equip_res = try reqResRef(g, cs, "EquipRes"),
            .instance, .game_instance => eq.item = try item.ItemStruct.fromGffStruct(arena, g, cs, .container),
        }
        out[i] = eq;
    }
    return out;
}

fn parseItemList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error![]item.InventoryObject {
    const f = g.getField(s, "ItemList") orelse return arena.alloc(item.InventoryObject, 0);
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(item.InventoryObject, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        out[i] = try item.InventoryObject.fromGffStruct(arena, g, cs);
    }
    return out;
}

fn parseExpressionList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!?[]Expression {
    const f = g.getField(s, "ExpressionList") orelse return null;
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Expression, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        out[i] = .{
            .expression_id = try optInt(g, cs, "ExpressionId", 0),
            .expression_string = try optExoStringDupe(arena, g, cs, "ExpressionString"),
        };
    }
    return out;
}

fn parsePerceptionList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!?[]Perception {
    const f = g.getField(s, "PerceptionList") orelse return null;
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(Perception, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        out[i] = .{
            .object_id = try optDword(g, cs, "ObjectId", INVALID_OBJECT_ID),
            .perception_data = try optByte(g, cs, "PerceptionData", 0),
        };
    }
    return out;
}

fn parsePersonalRepList(arena: std.mem.Allocator, g: *const gff.GffFile, s: *const gff.Struct) Error!?[]PersonalRep {
    const f = g.getField(s, "PersonalRepList") orelse return null;
    const arr = switch (f.value) {
        .list => |a| a,
        else => return error.WrongFieldType,
    };
    const out = try arena.alloc(PersonalRep, arr.len);
    for (arr, 0..) |idx, i| {
        const cs = &g.structs.items[idx];
        out[i] = .{
            .amount = try optInt(g, cs, "Amount", 0),
            .day = try optDword(g, cs, "Day", 0),
            .decays = try optByte(g, cs, "Decays", 0),
            .duration = try optInt(g, cs, "Duration", 0),
            .object_id = try optDword(g, cs, "ObjectId", INVALID_OBJECT_ID),
            .time = try optDword(g, cs, "Time", 0),
        };
    }
    return out;
}

fn parseGameInstanceFields(arena: std.mem.Allocator, out: *CreatureStruct, g: *const gff.GffFile, s: *const gff.Struct) Error!void {
    if (g.getField(s, "Age")) |_| out.age = try optInt(g, s, "Age", 0);
    if (g.getField(s, "AmbientAnimState")) |_| out.ambient_anim_state = try optByte(g, s, "AmbientAnimState", 0);
    if (g.getField(s, "AnimationDay")) |_| out.animation_day = try optDword(g, s, "AnimationDay", 0);
    if (g.getField(s, "AnimationTime")) |_| out.animation_time = try optDword(g, s, "AnimationTime", 0);
    if (g.getField(s, "Appearance_Head")) |_| out.appearance_head = try optByte(g, s, "Appearance_Head", 0);
    if (g.getField(s, "AreaId")) |_| out.area_id = try optDword(g, s, "AreaId", 0);
    if (g.getField(s, "ArmorPart_RFoot")) |_| out.armor_part_r_foot = try optByte(g, s, "ArmorPart_RFoot", 0);
    if (g.getField(s, "BaseAttackBonus")) |_| out.base_attack_bonus = try optByte(g, s, "BaseAttackBonus", 0);
    if (g.getField(s, "BodyBagId")) |_| out.body_bag_id = try optDword(g, s, "BodyBagId", 0);
    if (g.getField(s, "CreatureSize")) |_| out.creature_size = try optInt(g, s, "CreatureSize", 0);
    if (g.getField(s, "DeadSelectable")) |_| out.dead_selectable = try optByte(g, s, "DeadSelectable", 0);
    if (g.getField(s, "DetectMode")) |_| out.detect_mode = try optByte(g, s, "DetectMode", 0);
    if (g.getField(s, "Experience")) |_| out.experience = try optDword(g, s, "Experience", 0);
    if (g.getField(s, "FamiliarName")) |_| out.familiar_name = try optExoStringDupe(arena, g, s, "FamiliarName");
    if (g.getField(s, "FamiliarType")) |_| out.familiar_type = try optInt(g, s, "FamiliarType", 0);
    if (g.getField(s, "FortSaveThrow")) |_| out.fort_save_throw = try optChar(g, s, "FortSaveThrow", 0);
    if (g.getField(s, "Gold")) |_| out.gold = try optDword(g, s, "Gold", 0);
    if (g.getField(s, "IsCommandable")) |_| out.is_commandable = try optByte(g, s, "IsCommandable", 0);
    if (g.getField(s, "IsDestroyable")) |_| out.is_destroyable = try optByte(g, s, "IsDestroyable", 0);
    if (g.getField(s, "IsDM")) |_| out.is_dm = try optByte(g, s, "IsDM", 0);
    if (g.getField(s, "IsRaiseable")) |_| out.is_raiseable = try optByte(g, s, "IsRaiseable", 0);
    if (g.getField(s, "Listening")) |_| out.listening = try optByte(g, s, "Listening", 0);
    if (g.getField(s, "MasterID")) |_| out.master_id = try optDword(g, s, "MasterID", 0);
    if (g.getField(s, "MClassLevUpIn")) |_| out.m_class_lev_up_in = try optByte(g, s, "MClassLevUpIn", 0);
    if (g.getField(s, "ObjectId")) |_| out.object_id = try optDword(g, s, "ObjectId", 0);
    if (g.getField(s, "OverrideBAB")) |_| out.override_bab = try optByte(g, s, "OverrideBAB", 0);
    if (g.getField(s, "PM_IsPolymorphed")) |_| out.pm_is_polymorphed = try optByte(g, s, "PM_IsPolymorphed", 0);
    if (g.getField(s, "PregameCurrent")) |_| out.pregame_current = try optShort(g, s, "PregameCurrent", 0);
    if (g.getField(s, "RefSaveThrow")) |_| out.ref_save_throw = try optChar(g, s, "RefSaveThrow", 0);
    if (g.getField(s, "SitObject")) |_| out.sit_object = try optDword(g, s, "SitObject", 0);
    if (g.getField(s, "SkillPoints")) |_| out.skill_points = try optWord(g, s, "SkillPoints", 0);
    if (g.getField(s, "StealthMode")) |_| out.stealth_mode = try optByte(g, s, "StealthMode", 0);
    if (g.getField(s, "WillSaveThrow")) |_| out.will_save_throw = try optChar(g, s, "WillSaveThrow", 0);

    out.expression_list = try parseExpressionList(arena, g, s);
    out.perception_list = try parsePerceptionList(arena, g, s);
    out.personal_rep_list = try parsePersonalRepList(arena, g, s);
}

fn preserveGameFields(preserve_alloc: std.mem.Allocator, out: *CreatureStruct, g: *const gff.GffFile, s: *const gff.Struct) Error!void {
    const has_action = g.getField(s, "ActionList") != null;
    const has_effect = g.getField(s, "EffectList") != null;
    const has_ci = g.getField(s, "CombatInfo") != null;
    const has_crd = g.getField(s, "CombatRoundData") != null;
    const has_vt = g.getField(s, "VarTable") != null;
    if (!has_action and !has_effect and !has_ci and !has_crd and !has_vt) return;

    var holder = try gff.GffFile.init(preserve_alloc, [_]u8{ 'C', 'P', 'R', 'V' });
    errdefer holder.deinit();
    // We will hand `holder` off to `Preserved` below; until then it's owned here.

    var action_list_copy: ?[]u32 = null;
    var effect_list_copy: ?[]u32 = null;
    var combat_info_idx: ?u32 = null;
    var crd_idx: ?u32 = null;
    var var_table_copy: ?[]u32 = null;
    errdefer if (action_list_copy) |a| preserve_alloc.free(a);
    errdefer if (effect_list_copy) |a| preserve_alloc.free(a);
    errdefer if (var_table_copy) |a| preserve_alloc.free(a);

    if (g.getField(s, "ActionList")) |f| switch (f.value) {
        .list => |arr| {
            const copy = try preserve_alloc.alloc(u32, arr.len);
            action_list_copy = copy;
            for (arr, 0..) |idx, i| copy[i] = try holder.cloneStructInto(g, idx);
        },
        else => return error.WrongFieldType,
    };
    if (g.getField(s, "EffectList")) |f| switch (f.value) {
        .list => |arr| {
            const copy = try preserve_alloc.alloc(u32, arr.len);
            effect_list_copy = copy;
            for (arr, 0..) |idx, i| copy[i] = try holder.cloneStructInto(g, idx);
        },
        else => return error.WrongFieldType,
    };
    if (g.getField(s, "CombatInfo")) |f| switch (f.value) {
        .@"struct" => |idx| combat_info_idx = try holder.cloneStructInto(g, idx),
        else => return error.WrongFieldType,
    };
    if (g.getField(s, "CombatRoundData")) |f| switch (f.value) {
        .@"struct" => |idx| crd_idx = try holder.cloneStructInto(g, idx),
        else => return error.WrongFieldType,
    };
    if (g.getField(s, "VarTable")) |f| switch (f.value) {
        .list => |arr| {
            const copy = try preserve_alloc.alloc(u32, arr.len);
            var_table_copy = copy;
            for (arr, 0..) |idx, i| copy[i] = try holder.cloneStructInto(g, idx);
        },
        else => return error.WrongFieldType,
    };

    out.var_table = var_table_copy;
    out.preserved = .{
        .holder = holder,
        .action_list = action_list_copy,
        .effect_list = effect_list_copy,
        .combat_info = combat_info_idx,
        .combat_round_data = crd_idx,
        .var_table_in_holder = var_table_copy,
    };
}

// ============================================================================
// Serialize helpers — alphabetical-by-label
// ============================================================================

fn emitCommon(self: *const CreatureStruct, g: *gff.GffFile, idx: u32, variant: CreatureVariant) !void {
    const a = g.allocator;
    try g.addFieldToStruct(idx, "Appearance_Type", .{ .word = self.appearance_type });
    try g.addFieldToStruct(idx, "BodyBag", .{ .byte = self.body_bag });
    try g.addFieldToStruct(idx, "Cha", .{ .byte = self.cha });
    try g.addFieldToStruct(idx, "ChallengeRating", .{ .float = self.challenge_rating });
    try writeClassList(g, idx, self.class_list, variant);
    try g.addFieldToStruct(idx, "Con", .{ .byte = self.con });
    try g.addFieldToStruct(idx, "Conversation", .{ .res_ref = self.conversation });
    try g.addFieldToStruct(idx, "CRAdjust", .{ .int = self.cr_adjust });
    try g.addFieldToStruct(idx, "CurrentHitPoints", .{ .short = self.current_hit_points });
    try g.addFieldToStruct(idx, "DecayTime", .{ .dword = self.decay_time });
    try g.addFieldToStruct(idx, "Deity", .{ .exo_string = try a.dupe(u8, self.deity) });
    try g.addFieldToStruct(idx, "Description", .{ .exo_loc_string = try cloneExoLoc(a, self.description) });
    try g.addFieldToStruct(idx, "Dex", .{ .byte = self.dex });
    try g.addFieldToStruct(idx, "Disarmable", .{ .byte = self.disarmable });
    try writeEquipItemList(g, idx, self.equip_item_list, variant);
    try g.addFieldToStruct(idx, "FactionID", .{ .word = self.faction_id });
    try writeFeatList(g, idx, self.feat_list);
    try g.addFieldToStruct(idx, "FirstName", .{ .exo_loc_string = try cloneExoLoc(a, self.first_name) });
    try g.addFieldToStruct(idx, "fortbonus", .{ .short = self.fort_bonus });
    try g.addFieldToStruct(idx, "Gender", .{ .byte = self.gender });
    try g.addFieldToStruct(idx, "GoodEvil", .{ .byte = self.good_evil });
    try g.addFieldToStruct(idx, "HitPoints", .{ .short = self.hit_points });
    try g.addFieldToStruct(idx, "Int", .{ .byte = self.int_score });
    try g.addFieldToStruct(idx, "Interruptable", .{ .byte = self.interruptable });
    try g.addFieldToStruct(idx, "IsImmortal", .{ .byte = self.is_immortal });
    try g.addFieldToStruct(idx, "IsPC", .{ .byte = self.is_pc });
    try writeItemList(g, idx, self.item_list);
    try g.addFieldToStruct(idx, "LastName", .{ .exo_loc_string = try cloneExoLoc(a, self.last_name) });
    try g.addFieldToStruct(idx, "LawfulChaotic", .{ .byte = self.lawful_chaotic });
    try g.addFieldToStruct(idx, "Lootable", .{ .byte = self.lootable });
    try g.addFieldToStruct(idx, "MaxHitPoints", .{ .short = self.max_hit_points });
    try g.addFieldToStruct(idx, "NaturalAC", .{ .byte = self.natural_ac });
    try g.addFieldToStruct(idx, "NoPermDeath", .{ .byte = self.no_perm_death });
    try g.addFieldToStruct(idx, "PerceptionRange", .{ .byte = self.perception_range });
    try g.addFieldToStruct(idx, "Phenotype", .{ .int = self.phenotype });
    try g.addFieldToStruct(idx, "Plot", .{ .byte = self.plot });
    try g.addFieldToStruct(idx, "PortraitId", .{ .word = self.portrait_id });
    try g.addFieldToStruct(idx, "Race", .{ .byte = self.race });
    try g.addFieldToStruct(idx, "refbonus", .{ .short = self.ref_bonus });
    try g.addFieldToStruct(idx, "ScriptAttacked", .{ .res_ref = self.script_attacked });
    try g.addFieldToStruct(idx, "ScriptDamaged", .{ .res_ref = self.script_damaged });
    try g.addFieldToStruct(idx, "ScriptDeath", .{ .res_ref = self.script_death });
    try g.addFieldToStruct(idx, "ScriptDialogue", .{ .res_ref = self.script_dialogue });
    try g.addFieldToStruct(idx, "ScriptDisturbed", .{ .res_ref = self.script_disturbed });
    try g.addFieldToStruct(idx, "ScriptEndRound", .{ .res_ref = self.script_end_round });
    try g.addFieldToStruct(idx, "ScriptHeartbeat", .{ .res_ref = self.script_heartbeat });
    try g.addFieldToStruct(idx, "ScriptOnBlocked", .{ .res_ref = self.script_on_blocked });
    try g.addFieldToStruct(idx, "ScriptOnNotice", .{ .res_ref = self.script_on_notice });
    try g.addFieldToStruct(idx, "ScriptRested", .{ .res_ref = self.script_rested });
    try g.addFieldToStruct(idx, "ScriptSpawn", .{ .res_ref = self.script_spawn });
    try g.addFieldToStruct(idx, "ScriptSpellAt", .{ .res_ref = self.script_spell_at });
    try g.addFieldToStruct(idx, "ScriptuserDefine", .{ .res_ref = self.script_user_define });
    try writeSkillList(g, idx, self.skill_list);
    try g.addFieldToStruct(idx, "SoundSetFile", .{ .word = self.sound_set_file });
    try writeSpecAbilityList(g, idx, self.spec_ability_list);
    try g.addFieldToStruct(idx, "StartingPackage", .{ .byte = self.starting_package });
    try g.addFieldToStruct(idx, "Str", .{ .byte = self.str });
    try g.addFieldToStruct(idx, "Subrace", .{ .exo_string = try a.dupe(u8, self.subrace) });
    try g.addFieldToStruct(idx, "Tag", .{ .exo_string = try a.dupe(u8, self.tag) });
    try g.addFieldToStruct(idx, "Tail", .{ .byte = self.tail });
    try g.addFieldToStruct(idx, "WalkRate", .{ .int = self.walk_rate });
    try g.addFieldToStruct(idx, "willbonus", .{ .short = self.will_bonus });
    try g.addFieldToStruct(idx, "Wings", .{ .byte = self.wings });
}

fn emitVariantSpecific(self: *const CreatureStruct, g: *gff.GffFile, idx: u32, variant: CreatureVariant) !void {
    const a = g.allocator;
    switch (variant) {
        .blueprint => {
            if (self.comment) |c| try g.addFieldToStruct(idx, "Comment", .{ .exo_string = try a.dupe(u8, c) });
            if (self.palette_id) |p| try g.addFieldToStruct(idx, "PaletteID", .{ .byte = p });
            try g.addFieldToStruct(idx, "TemplateResRef", .{ .res_ref = self.template_res_ref.? });
        },
        .instance => {
            try g.addFieldToStruct(idx, "TemplateResRef", .{ .res_ref = self.template_res_ref.? });
            if (self.x_orientation) |v| try g.addFieldToStruct(idx, "XOrientation", .{ .float = v });
            if (self.x_position) |v| try g.addFieldToStruct(idx, "XPosition", .{ .float = v });
            if (self.y_orientation) |v| try g.addFieldToStruct(idx, "YOrientation", .{ .float = v });
            if (self.y_position) |v| try g.addFieldToStruct(idx, "YPosition", .{ .float = v });
            if (self.z_position) |v| try g.addFieldToStruct(idx, "ZPosition", .{ .float = v });
        },
        .game_instance => try emitGameInstance(self, g, idx, a),
    }
}

fn emitGameInstance(self: *const CreatureStruct, g: *gff.GffFile, idx: u32, a: std.mem.Allocator) !void {
    // Alphabetical block. Optional fields only emitted when set.
    // ActionList is preserved if present.
    if (self.preserved) |p| if (p.action_list) |arr| try writePreservedList(g, idx, "ActionList", &p, arr);
    if (self.age) |v| try g.addFieldToStruct(idx, "Age", .{ .int = v });
    if (self.ambient_anim_state) |v| try g.addFieldToStruct(idx, "AmbientAnimState", .{ .byte = v });
    if (self.animation_day) |v| try g.addFieldToStruct(idx, "AnimationDay", .{ .dword = v });
    if (self.animation_time) |v| try g.addFieldToStruct(idx, "AnimationTime", .{ .dword = v });
    if (self.appearance_head) |v| try g.addFieldToStruct(idx, "Appearance_Head", .{ .byte = v });
    if (self.area_id) |v| try g.addFieldToStruct(idx, "AreaId", .{ .dword = v });
    if (self.armor_part_r_foot) |v| try g.addFieldToStruct(idx, "ArmorPart_RFoot", .{ .byte = v });
    if (self.base_attack_bonus) |v| try g.addFieldToStruct(idx, "BaseAttackBonus", .{ .byte = v });
    if (self.body_bag_id) |v| try g.addFieldToStruct(idx, "BodyBagId", .{ .dword = v });
    if (self.preserved) |p| if (p.combat_info) |c| {
        const new_idx = try g.cloneStructInto(&p.holder, c);
        try g.addFieldToStruct(idx, "CombatInfo", .{ .@"struct" = new_idx });
    };
    if (self.preserved) |p| if (p.combat_round_data) |c| {
        const new_idx = try g.cloneStructInto(&p.holder, c);
        try g.addFieldToStruct(idx, "CombatRoundData", .{ .@"struct" = new_idx });
    };
    if (self.creature_size) |v| try g.addFieldToStruct(idx, "CreatureSize", .{ .int = v });
    if (self.dead_selectable) |v| try g.addFieldToStruct(idx, "DeadSelectable", .{ .byte = v });
    if (self.detect_mode) |v| try g.addFieldToStruct(idx, "DetectMode", .{ .byte = v });
    if (self.preserved) |p| if (p.effect_list) |arr| try writePreservedList(g, idx, "EffectList", &p, arr);
    if (self.experience) |v| try g.addFieldToStruct(idx, "Experience", .{ .dword = v });
    try writeExpressionListIfPresent(g, idx, self.expression_list, a);
    if (self.familiar_name) |v| try g.addFieldToStruct(idx, "FamiliarName", .{ .exo_string = try a.dupe(u8, v) });
    if (self.familiar_type) |v| try g.addFieldToStruct(idx, "FamiliarType", .{ .int = v });
    if (self.fort_save_throw) |v| try g.addFieldToStruct(idx, "FortSaveThrow", .{ .char = v });
    if (self.gold) |v| try g.addFieldToStruct(idx, "Gold", .{ .dword = v });
    if (self.is_commandable) |v| try g.addFieldToStruct(idx, "IsCommandable", .{ .byte = v });
    if (self.is_destroyable) |v| try g.addFieldToStruct(idx, "IsDestroyable", .{ .byte = v });
    if (self.is_dm) |v| try g.addFieldToStruct(idx, "IsDM", .{ .byte = v });
    if (self.is_raiseable) |v| try g.addFieldToStruct(idx, "IsRaiseable", .{ .byte = v });
    if (self.listening) |v| try g.addFieldToStruct(idx, "Listening", .{ .byte = v });
    if (self.master_id) |v| try g.addFieldToStruct(idx, "MasterID", .{ .dword = v });
    if (self.m_class_lev_up_in) |v| try g.addFieldToStruct(idx, "MClassLevUpIn", .{ .byte = v });
    if (self.object_id) |v| try g.addFieldToStruct(idx, "ObjectId", .{ .dword = v });
    if (self.override_bab) |v| try g.addFieldToStruct(idx, "OverrideBAB", .{ .byte = v });
    try writePerceptionListIfPresent(g, idx, self.perception_list);
    try writePersonalRepListIfPresent(g, idx, self.personal_rep_list);
    if (self.pm_is_polymorphed) |v| try g.addFieldToStruct(idx, "PM_IsPolymorphed", .{ .byte = v });
    if (self.pregame_current) |v| try g.addFieldToStruct(idx, "PregameCurrent", .{ .short = v });
    if (self.ref_save_throw) |v| try g.addFieldToStruct(idx, "RefSaveThrow", .{ .char = v });
    if (self.sit_object) |v| try g.addFieldToStruct(idx, "SitObject", .{ .dword = v });
    if (self.skill_points) |v| try g.addFieldToStruct(idx, "SkillPoints", .{ .word = v });
    if (self.stealth_mode) |v| try g.addFieldToStruct(idx, "StealthMode", .{ .byte = v });
    if (self.template_res_ref) |v| try g.addFieldToStruct(idx, "TemplateResRef", .{ .res_ref = v });
    if (self.preserved) |p| if (p.var_table_in_holder) |arr| try writePreservedList(g, idx, "VarTable", &p, arr);
    if (self.will_save_throw) |v| try g.addFieldToStruct(idx, "WillSaveThrow", .{ .char = v });
    if (self.x_orientation) |v| try g.addFieldToStruct(idx, "XOrientation", .{ .float = v });
    if (self.x_position) |v| try g.addFieldToStruct(idx, "XPosition", .{ .float = v });
    if (self.y_orientation) |v| try g.addFieldToStruct(idx, "YOrientation", .{ .float = v });
    if (self.y_position) |v| try g.addFieldToStruct(idx, "YPosition", .{ .float = v });
    if (self.z_position) |v| try g.addFieldToStruct(idx, "ZPosition", .{ .float = v });
}

fn writePreservedList(g: *gff.GffFile, parent_idx: u32, label: []const u8, p: *const Preserved, holder_indices: []const u32) !void {
    const new_arr = try g.allocator.alloc(u32, holder_indices.len);
    errdefer g.allocator.free(new_arr);
    for (holder_indices, 0..) |hidx, i| {
        new_arr[i] = try g.cloneStructInto(&p.holder, hidx);
    }
    try g.addFieldToStruct(parent_idx, label, .{ .list = new_arr });
}

fn writeClassList(g: *gff.GffFile, parent_idx: u32, classes: []const ClassEntry, variant: CreatureVariant) !void {
    const arr = try g.allocator.alloc(u32, classes.len);
    errdefer g.allocator.free(arr);
    for (classes, 0..) |c, i| {
        const ci = try g.addStruct(ClassEntry.STRUCT_ID);
        arr[i] = ci;
        try g.addFieldToStruct(ci, "Class", .{ .int = c.class });
        try g.addFieldToStruct(ci, "ClassLevel", .{ .short = c.class_level });
        if (c.memorized_lists) |lists| {
            var n: u8 = 0;
            while (n < 10) : (n += 1) {
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "MemorizedList{d}", .{n}) catch unreachable;
                try writeSpellList(g, ci, label, lists[n], variant, true);
            }
        }
        if (c.known_lists) |lists| {
            var n: u8 = 0;
            while (n < 10) : (n += 1) {
                var buf: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "KnownList{d}", .{n}) catch unreachable;
                try writeSpellList(g, ci, label, lists[n], variant, false);
            }
        }
        if (variant == .game_instance) {
            if (c.domain1) |v| try g.addFieldToStruct(ci, "Domain1", .{ .byte = v });
            if (c.domain2) |v| try g.addFieldToStruct(ci, "Domain2", .{ .byte = v });
            if (c.school) |v| try g.addFieldToStruct(ci, "School", .{ .byte = v });
            if (c.spells_per_day) |spd| {
                const spd_arr = try g.allocator.alloc(u32, spd.len);
                errdefer g.allocator.free(spd_arr);
                for (spd, 0..) |val, k| {
                    const sidx = try g.addStruct(StructId.spells_per_day);
                    spd_arr[k] = sidx;
                    try g.addFieldToStruct(sidx, "NumSpellsLeft", .{ .byte = val });
                }
                try g.addFieldToStruct(ci, "SpellsPerDayList", .{ .list = spd_arr });
            }
        }
    }
    try g.addFieldToStruct(parent_idx, "ClassList", .{ .list = arr });
}

fn writeSpellList(g: *gff.GffFile, parent_idx: u32, label: []const u8, spells: []const Spell, variant: CreatureVariant, is_memorized: bool) !void {
    const arr = try g.allocator.alloc(u32, spells.len);
    errdefer g.allocator.free(arr);
    for (spells, 0..) |sp, i| {
        const si = try g.addStruct(Spell.STRUCT_ID);
        arr[i] = si;
        try g.addFieldToStruct(si, "Spell", .{ .word = sp.spell });
        if (variant == .game_instance) {
            if (is_memorized) {
                if (sp.ready) |r| try g.addFieldToStruct(si, "Ready", .{ .int = r });
                try g.addFieldToStruct(si, "SpellMetaMagic", .{ .short = sp.spell_metamagic });
            }
        } else {
            try g.addFieldToStruct(si, "SpellFlags", .{ .byte = sp.spell_flags });
            try g.addFieldToStruct(si, "SpellMetaMagic", .{ .byte = @intCast(sp.spell_metamagic) });
        }
    }
    try g.addFieldToStruct(parent_idx, label, .{ .list = arr });
}

fn writeFeatList(g: *gff.GffFile, parent_idx: u32, feats: []const FeatEntry) !void {
    const arr = try g.allocator.alloc(u32, feats.len);
    errdefer g.allocator.free(arr);
    for (feats, 0..) |feat, i| {
        const fi = try g.addStruct(FeatEntry.STRUCT_ID);
        arr[i] = fi;
        try g.addFieldToStruct(fi, "Feat", .{ .word = feat.feat });
    }
    try g.addFieldToStruct(parent_idx, "FeatList", .{ .list = arr });
}

fn writeSkillList(g: *gff.GffFile, parent_idx: u32, skills: []const SkillEntry) !void {
    const arr = try g.allocator.alloc(u32, skills.len);
    errdefer g.allocator.free(arr);
    for (skills, 0..) |sk, i| {
        const si = try g.addStruct(SkillEntry.STRUCT_ID);
        arr[i] = si;
        try g.addFieldToStruct(si, "Rank", .{ .byte = sk.rank });
    }
    try g.addFieldToStruct(parent_idx, "SkillList", .{ .list = arr });
}

fn writeSpecAbilityList(g: *gff.GffFile, parent_idx: u32, abilities: []const SpecialAbility) !void {
    const arr = try g.allocator.alloc(u32, abilities.len);
    errdefer g.allocator.free(arr);
    for (abilities, 0..) |sa, i| {
        const si = try g.addStruct(SpecialAbility.STRUCT_ID);
        arr[i] = si;
        try g.addFieldToStruct(si, "Spell", .{ .word = sa.spell });
        try g.addFieldToStruct(si, "SpellCasterLevel", .{ .byte = sa.spell_caster_level });
        try g.addFieldToStruct(si, "SpellFlags", .{ .byte = sa.spell_flags });
    }
    try g.addFieldToStruct(parent_idx, "SpecAbilityList", .{ .list = arr });
}

fn writeEquipItemList(g: *gff.GffFile, parent_idx: u32, items: []const EquippedItem, variant: CreatureVariant) !void {
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |eq, i| {
        const ei = try g.addStruct(eq.slot);
        arr[i] = ei;
        switch (variant) {
            .blueprint => try g.addFieldToStruct(ei, "EquipRes", .{ .res_ref = eq.equip_res.? }),
            .instance, .game_instance => try eq.item.?.writeIntoGff(g.allocator, g, ei, .container),
        }
    }
    try g.addFieldToStruct(parent_idx, "Equip_ItemList", .{ .list = arr });
}

fn writeItemList(g: *gff.GffFile, parent_idx: u32, items: []const item.InventoryObject) !void {
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |inv, i| {
        const ii = try g.addStruct(item.InventoryObject.STRUCT_ID);
        arr[i] = ii;
        try inv.writeIntoGff(g.allocator, g, ii);
    }
    try g.addFieldToStruct(parent_idx, "ItemList", .{ .list = arr });
}

fn writeExpressionListIfPresent(g: *gff.GffFile, parent_idx: u32, list: ?[]Expression, a: std.mem.Allocator) !void {
    const items = list orelse return;
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |ex, i| {
        const ei = try g.addStruct(Expression.STRUCT_ID);
        arr[i] = ei;
        try g.addFieldToStruct(ei, "ExpressionId", .{ .int = ex.expression_id });
        try g.addFieldToStruct(ei, "ExpressionString", .{ .exo_string = try a.dupe(u8, ex.expression_string) });
    }
    try g.addFieldToStruct(parent_idx, "ExpressionList", .{ .list = arr });
}

fn writePerceptionListIfPresent(g: *gff.GffFile, parent_idx: u32, list: ?[]Perception) !void {
    const items = list orelse return;
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |p, i| {
        const pi = try g.addStruct(Perception.STRUCT_ID);
        arr[i] = pi;
        try g.addFieldToStruct(pi, "ObjectId", .{ .dword = p.object_id });
        try g.addFieldToStruct(pi, "PerceptionData", .{ .byte = p.perception_data });
    }
    try g.addFieldToStruct(parent_idx, "PerceptionList", .{ .list = arr });
}

fn writePersonalRepListIfPresent(g: *gff.GffFile, parent_idx: u32, list: ?[]PersonalRep) !void {
    const items = list orelse return;
    const arr = try g.allocator.alloc(u32, items.len);
    errdefer g.allocator.free(arr);
    for (items, 0..) |pr, i| {
        const ri = try g.addStruct(PersonalRep.STRUCT_ID);
        arr[i] = ri;
        try g.addFieldToStruct(ri, "Amount", .{ .int = pr.amount });
        try g.addFieldToStruct(ri, "Day", .{ .dword = pr.day });
        try g.addFieldToStruct(ri, "Decays", .{ .byte = pr.decays });
        try g.addFieldToStruct(ri, "Duration", .{ .int = pr.duration });
        try g.addFieldToStruct(ri, "ObjectId", .{ .dword = pr.object_id });
        try g.addFieldToStruct(ri, "Time", .{ .dword = pr.time });
    }
    try g.addFieldToStruct(parent_idx, "PersonalRepList", .{ .list = arr });
}

// ============================================================================
// UtcFile
// ============================================================================

/// Standalone UTC blueprint container. Wraps a `.blueprint`-variant
/// `CreatureStruct` together with the arena that owns its string/list data.
///
/// A typical workflow:
/// ```zig
/// var utc = try creature.UtcFile.parse(gpa, bytes);
/// defer utc.deinit();
/// // ... read or mutate utc.creature ...
/// const out = try utc.serialize(gpa);
/// defer gpa.free(out);
/// ```
pub const UtcFile = struct {
    /// Spec-mandated 4-byte GFF FileType for blueprint creatures.
    pub const FILE_TYPE = "UTC ";

    /// Arena that owns every string / list / loc-string slice referenced
    /// by `creature`.
    arena: std.heap.ArenaAllocator,
    /// Long-lived allocator used to back the optional
    /// `creature.preserved` sub-object (UTC blueprints rarely use it, but
    /// the field exists for symmetry with game-instance variants).
    parent_alloc: std.mem.Allocator,
    /// The decoded / to-be-encoded creature blueprint.
    creature: CreatureStruct = .{},

    /// Build an empty `UtcFile` ready to be populated.
    pub fn init(parent_alloc: std.mem.Allocator) UtcFile {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
            .parent_alloc = parent_alloc,
        };
    }

    /// Release every resource owned by this file. Order matters: any
    /// `Preserved` holder is freed first (it is backed by `parent_alloc`,
    /// not by the arena) before the arena itself is destroyed.
    pub fn deinit(self: *UtcFile) void {
        self.creature.deinit(self.parent_alloc);
        self.arena.deinit();
    }

    /// Parse a UTC byte stream. Verifies the `"UTC "` file-type magic and
    /// decodes the top-level struct (struct 0) as a blueprint creature.
    /// Errors: see `Error` and `gff.FormatError`.
    pub fn parse(parent_alloc: std.mem.Allocator, data: []const u8) Error!UtcFile {
        var g = gff.GffFile.initEmpty(parent_alloc);
        defer g.deinit();
        try g.parse(data, &FILE_TYPE.*);

        var out = UtcFile.init(parent_alloc);
        errdefer out.deinit();
        out.creature = try CreatureStruct.fromGffStruct(
            out.arena.allocator(),
            parent_alloc,
            &g,
            &g.structs.items[0],
            .blueprint,
        );
        return out;
    }

    /// Encode `creature` (as a blueprint) into a fresh UTC byte stream.
    /// The caller owns the returned slice and must free it with `alloc`.
    pub fn serialize(self: *const UtcFile, alloc: std.mem.Allocator) ![]u8 {
        var g = try gff.GffFile.init(alloc, FILE_TYPE.*);
        defer g.deinit();
        try self.creature.writeIntoGff(&g, 0, .blueprint);
        return g.serialize(alloc);
    }
};
