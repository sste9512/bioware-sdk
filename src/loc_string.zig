//! CExoLocString — BioWare Aurora Localized String helpers.
//!
//! Implements the full §5 fetch procedure from
//! Bioware_Aurora_LocalizedStrings_Format.pdf:
//!
//!   1. Get the user's language + gender.
//!   2. Try the embedded substring matching lang + gender.
//!   3. Try the TalkTable via the LocString's StrRef.
//!   4–5. If searching is off, return not-found.
//!   6. Scan for fallback languages in spec order:
//!      English → French → German → Italian → Spanish.
//!
//! The data structure (`gff.ExoLocString`, `gff.SubString`) lives in
//! gff.zig. The language enum and string_id encoding live in erf.zig.
//! This module ties them together and provides a `fetch` function that
//! correctly handles the distinction between "found but blank" and
//! "not found at all" (§5 note).

const std = @import("std");
const gff = @import("gff.zig");
const erf = @import("erf.zig");
const tlk = @import("tlk.zig");

// ============================================================================
// Re-exports
// ============================================================================

/// Language IDs from §2 Table. Value on disk = `2 × language_id + gender`.
pub const Language = erf.Language;

// ============================================================================
// Gender
// ============================================================================

/// §3 — gender associated with a localized substring.
/// Neutral text is stored as masculine (0).
pub const Gender = enum(u1) {
    male = 0,
    female = 1,
};

// ============================================================================
// String-ID encoding/decoding  (§4)
// ============================================================================

/// Encode `(language, gender)` into the on-disk string_id stored in
/// `gff.SubString.string_id`: `2 × language_id + gender`.
pub fn stringId(lang: Language, gender: Gender) u32 {
    return erf.Language.encode(lang, gender == .female);
}

/// Decode a `gff.SubString.string_id` back to language and gender.
pub fn decodeStringId(id: u32) struct { lang: Language, gender: Gender } {
    const d = erf.Language.decode(id);
    return .{ .lang = d.lang, .gender = if (d.feminine) .female else .male };
}

// ============================================================================
// FetchResult  (§5 note)
// ============================================================================

/// Result of `fetch`. The spec requires distinguishing between a
/// deliberately-blank string (found = true, text = "") and a string
/// that could not be resolved at all (found = false).
pub const FetchResult = struct {
    text: []const u8,
    found: bool,

    pub const not_found: FetchResult = .{ .text = "", .found = false };
};

// ============================================================================
// Fetch procedure  (§5)
// ============================================================================

/// Spec §5 step-6 fallback language order.
const FALLBACK_ORDER = [_]Language{
    .english, .french, .german, .italian, .spanish,
};

/// Fetch text for a `gff.ExoLocString`, implementing the full six-step
/// procedure from §5.
///
/// Arguments:
///   `loc`       — the ExoLocString to resolve.
///   `lang`      — user's display language (obtained from the TalkTable).
///   `gender`    — display gender (e.g. player character's gender).
///   `tlk_table` — the gender-appropriate TalkTable already selected by the
///                 caller (dialog.tlk for masculine/neutral, dialogf.tlk for
///                 feminine). May be null when no TalkTable is available.
///   `searching` — whether to fall back to other embedded languages (§5 §4).
///                 True by default; set false only in special cases.
///
/// Returns `FetchResult.found == false` when no text could be resolved.
pub fn fetch(
    loc: gff.ExoLocString,
    lang: Language,
    gender: Gender,
    tlk_table: ?*const tlk.TalkTable,
    searching: bool,
) FetchResult {
    // §5 Step 2: embedded substring matching user's language + gender.
    const target_id = stringId(lang, gender);
    for (loc.substrings.items) |ss| {
        if (ss.string_id == target_id) return .{ .text = ss.text, .found = true };
    }

    // §5 Step 3: TalkTable lookup via the LocString's StrRef.
    if (tlk_table) |table| {
        if (table.getString(loc.string_ref)) |s| return .{ .text = s, .found = true };
    }

    // §5 Steps 4–5: searching disabled → fail.
    if (!searching) return FetchResult.not_found;

    // §5 Step 6: scan fallback languages in spec order, skipping the
    // user's own language. Try the requested gender first, then the
    // opposite, so a masculine-only entry can satisfy a feminine query.
    for (FALLBACK_ORDER) |fb_lang| {
        if (fb_lang == lang) continue;
        for ([_]Gender{ gender, opposite(gender) }) |g| {
            const fb_id = stringId(fb_lang, g);
            for (loc.substrings.items) |ss| {
                if (ss.string_id == fb_id) return .{ .text = ss.text, .found = true };
            }
        }
    }

    return FetchResult.not_found;
}

fn opposite(g: Gender) Gender {
    return if (g == .male) .female else .male;
}

// ============================================================================
// Builder helpers
// ============================================================================

/// Append an embedded substring for `(lang, gender)` to `loc`.
/// Duplicates `text` using `alloc`; the caller owns the arena that backs `loc`.
pub fn addSubstring(
    loc: *gff.ExoLocString,
    alloc: std.mem.Allocator,
    lang: Language,
    gender: Gender,
    text: []const u8,
) !void {
    const id = stringId(lang, gender);
    const owned = try alloc.dupe(u8, text);
    errdefer alloc.free(owned);
    try loc.substrings.append(alloc, .{ .string_id = id, .text = owned });
}

/// Return the embedded text for `(lang, gender)`, or null if absent.
pub fn getSubstring(loc: *const gff.ExoLocString, lang: Language, gender: Gender) ?[]const u8 {
    const target = stringId(lang, gender);
    for (loc.substrings.items) |ss| {
        if (ss.string_id == target) return ss.text;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "stringId encoding matches spec §4" {
    // string_id = 2 × language_id + gender
    try t.expectEqual(@as(u32, 0), stringId(.english, .male));   // 2×0 + 0
    try t.expectEqual(@as(u32, 1), stringId(.english, .female)); // 2×0 + 1
    try t.expectEqual(@as(u32, 2), stringId(.french,  .male));   // 2×1 + 0
    try t.expectEqual(@as(u32, 3), stringId(.french,  .female)); // 2×1 + 1
    try t.expectEqual(@as(u32, 256), stringId(.korean,  .male));   // 2×128
    try t.expectEqual(@as(u32, 263), stringId(.japanese, .female)); // 2×131+1
}

test "decodeStringId round-trips" {
    const cases = [_]struct { lang: Language, gender: Gender }{
        .{ .lang = .english,  .gender = .male   },
        .{ .lang = .english,  .gender = .female },
        .{ .lang = .german,   .gender = .female },
        .{ .lang = .japanese, .gender = .male   },
    };
    for (cases) |c| {
        const id = stringId(c.lang, c.gender);
        const d = decodeStringId(id);
        try t.expectEqual(c.lang,   d.lang);
        try t.expectEqual(c.gender, d.gender);
    }
}

test "fetch §5 step 2 — exact embedded match" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);

    try addSubstring(&loc, gpa, .english, .male,   "Hello");
    try addSubstring(&loc, gpa, .english, .female, "Hello (f)");

    const r = fetch(loc, .english, .male, null, true);
    try t.expect(r.found);
    try t.expectEqualStrings("Hello", r.text);

    const rf = fetch(loc, .english, .female, null, true);
    try t.expect(rf.found);
    try t.expectEqualStrings("Hello (f)", rf.text);
}

test "fetch §5 step 3 — TalkTable fallback" {
    const gpa = t.allocator;

    var tab = tlk.TalkTable.init(gpa);
    defer tab.deinit();
    _ = try tab.addEntry(.{
        .flags = .{ .text_present = true },
        .text  = try gpa.dupe(u8, "from-tlk"),
    });

    // loc has no embedded strings, but StrRef 0 is valid in the TLK.
    var loc: gff.ExoLocString = .{ .string_ref = 0, .substrings = .empty };
    defer loc.deinit(gpa);

    const r = fetch(loc, .english, .male, &tab, true);
    try t.expect(r.found);
    try t.expectEqualStrings("from-tlk", r.text);
}

test "fetch §5 step 5 — searching disabled stops after TLK miss" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);
    // Embed a German string — normally a fallback, but not when searching=false.
    try addSubstring(&loc, gpa, .german, .male, "Hallo");

    const r = fetch(loc, .english, .male, null, false);
    try t.expect(!r.found);
    try t.expectEqualStrings("", r.text);
}

test "fetch §5 step 6 — fallback language scan order" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);

    // Only Spanish and German embedded — German should win (comes first in spec order).
    try addSubstring(&loc, gpa, .spanish, .male, "Hola");
    try addSubstring(&loc, gpa, .german,  .male, "Hallo");

    const r = fetch(loc, .english, .male, null, true);
    try t.expect(r.found);
    try t.expectEqualStrings("Hallo", r.text); // German is before Spanish in fallback order
}

test "fetch §5 step 6 — fallback tries opposite gender" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);

    // French masculine only — should be returned when fetching feminine.
    try addSubstring(&loc, gpa, .french, .male, "Bonjour");

    const r = fetch(loc, .english, .female, null, true);
    try t.expect(r.found);
    try t.expectEqualStrings("Bonjour", r.text);
}

test "fetch — invalid StrRef and no substrings returns not-found" {
    const loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    const r = fetch(loc, .english, .male, null, true);
    try t.expect(!r.found);
    try t.expectEqualStrings("", r.text);
}

test "fetch — blank text is found=true" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);

    // Deliberately blank English string.
    try addSubstring(&loc, gpa, .english, .male, "");

    const r = fetch(loc, .english, .male, null, true);
    try t.expect(r.found);
    try t.expectEqualStrings("", r.text);
}

test "addSubstring / getSubstring helpers" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);

    try addSubstring(&loc, gpa, .english, .male,   "Hi");
    try addSubstring(&loc, gpa, .french,  .female, "Salut");

    try t.expectEqualStrings("Hi",    getSubstring(&loc, .english, .male).?);
    try t.expectEqualStrings("Salut", getSubstring(&loc, .french,  .female).?);
    try t.expect(getSubstring(&loc, .german, .male) == null);
}

test "fetch §5 skips user's own language in fallback scan" {
    const gpa = t.allocator;
    var loc: gff.ExoLocString = .{ .string_ref = 0xFFFF_FFFF, .substrings = .empty };
    defer loc.deinit(gpa);

    // English female embedded, but we're looking for English male — no exact match.
    // In the fallback scan, English is skipped (it's the user's language).
    // French male exists — should be returned instead.
    try addSubstring(&loc, gpa, .english, .female, "Hello (f)");
    try addSubstring(&loc, gpa, .french,  .male,   "Bonjour");

    const r = fetch(loc, .english, .male, null, true);
    try t.expect(r.found);
    try t.expectEqualStrings("Bonjour", r.text);
}
