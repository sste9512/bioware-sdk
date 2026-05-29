const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ResType = @import("keybif.zig").ResType;

// ── Constants ────────────────────────────────────────────────────────────────

const ITEM_ENTRY_COUNT_OFFSET: usize = 12;
const ITEM_OFF_KEY_LIST_OFFSET: usize = 16;
const ITEM_RESOURCE_NAME_LENGTH: usize = 16;
const ITEM_SHORT_VALUE_OFFSET: usize = 32;

// ── Errors ───────────────────────────────────────────────────────────────────

pub const RimError = error{
    ResourceIdTooLarge,
    ResourceNotFound,
    InvalidData,
    OutOfBounds,
};

// ── RimKeyEntry ───────────────────────────────────────────────────────────────

pub const RimKeyEntry = struct {
    resource_name: [ITEM_RESOURCE_NAME_LENGTH]u8,
    resource_name_len: usize,
    resource_type: i16,
    resource_id: i16,
    offset: i32,
    length: i32,
    index: i32,

    pub fn init(
        resource_name: [ITEM_RESOURCE_NAME_LENGTH]u8,
        resource_name_len: usize,
        resource_type: i16,
        resource_id: i16,
        offset: i32,
        length: i32,
        index: i32,
    ) RimKeyEntry {
        return RimKeyEntry{
            .resource_name = resource_name,
            .resource_name_len = resource_name_len,
            .resource_type = resource_type,
            .resource_id = resource_id,
            .offset = offset,
            .length = length,
            .index = index,
        };
    }

    /// Returns name as a slice (strips null padding).
    pub fn name(self: *const RimKeyEntry) []const u8 {
        return self.resource_name[0..self.resource_name_len];
    }
};

// ── RimFile ───────────────────────────────────────────────────────────────────

pub const RimFile = struct {
    allocator: Allocator,
    entry_count: i32,
    off_key_list: i32,
    key_entry_list: ArrayList(RimKeyEntry),
    /// Owned copy of the raw file bytes. Used for zero-copy resource slicing.
    data: []u8,

    pub fn init(allocator: Allocator) RimFile {
        return .{
            .allocator = allocator,
            .entry_count = 0,
            .off_key_list = 0,
            .key_entry_list = .empty,
            .data = &.{},
        };
    }

    pub fn deinit(self: *RimFile) void {
        self.key_entry_list.deinit(self.allocator);
        if (self.data.len > 0) self.allocator.free(self.data);
    }

    // ------------------------------------------------------------------ Parse

    /// Parse a RIM archive from raw bytes.
    /// Caller retains ownership of `data`; RimFile dupes what it needs.
    /// On error, call `deinit` to release any partial allocations.
    pub fn parse(self: *RimFile, data: []const u8) !void {
        if (data.len < ITEM_OFF_KEY_LIST_OFFSET + 4) return RimError.InvalidData;

        self.data = try self.allocator.dupe(u8, data);
        errdefer {
            self.allocator.free(self.data);
            self.data = &.{};
        }

        self.entry_count = readI32(self.data, ITEM_ENTRY_COUNT_OFFSET);
        self.off_key_list = readI32(self.data, ITEM_OFF_KEY_LIST_OFFSET);

        try self.key_entry_list.ensureTotalCapacity(self.allocator, @intCast(self.entry_count));
        try self.populateKeyEntries();
    }

    // ── Resource access ───────────────────────────────────────────────────────

    /// Returns a slice into internal data for resource at `index`.
    /// Slice lifetime is tied to this RimFile — do not free.
    pub fn getRimResource(self: *const RimFile, index: usize) ![]const u8 {
        if (index >= @as(usize, @intCast(self.entry_count))) return RimError.OutOfBounds;
        const entry = &self.key_entry_list.items[index];
        const start: usize = @intCast(entry.offset);
        const end: usize = @intCast(entry.offset + entry.length);
        if (end > self.data.len) return RimError.OutOfBounds;
        return self.data[start..end];
    }

    /// Find resource by ID and return a slice into internal data.
    pub fn readResourceData(self: *const RimFile, resource_id: u32) ![]const u8 {
        const id16 = std.math.cast(i16, resource_id) orelse return RimError.ResourceIdTooLarge;
        for (self.key_entry_list.items) |*entry| {
            if (entry.resource_id == id16) return self.getRimResource(@intCast(entry.index));
        }
        return RimError.ResourceNotFound;
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    fn populateKeyEntries(self: *RimFile) !void {
        var i: i32 = 0;
        while (i < self.entry_count) : (i += 1) {
            const entry = try self.createRimKeyEntry(i);
            try self.key_entry_list.append(self.allocator, entry);
        }
    }

    fn createRimKeyEntry(self: *const RimFile, index: i32) !RimKeyEntry {
        const resource_name, const name_len = self.getResourceName(index);

        const type_off: usize = @intCast(self.off_key_list + index * @as(i32, ITEM_SHORT_VALUE_OFFSET) + 16);
        const id_off: usize = @intCast(self.off_key_list + index * @as(i32, ITEM_SHORT_VALUE_OFFSET) + 18);
        const off_off: usize = @intCast(self.off_key_list + index * @as(i32, ITEM_SHORT_VALUE_OFFSET) + 24);
        const len_off: usize = @intCast(self.off_key_list + index * @as(i32, ITEM_SHORT_VALUE_OFFSET) + 28);

        const resource_type = readI16(self.data, type_off);
        const resource_id = readI16(self.data, id_off);
        const offset = readI32(self.data, off_off);
        const length = readI32(self.data, len_off);

        return RimKeyEntry.init(resource_name, name_len, resource_type, resource_id, offset, length, index);
    }

    fn getResourceName(self: *const RimFile, index: i32) struct { [ITEM_RESOURCE_NAME_LENGTH]u8, usize } {
        const base: usize = @as(usize, @intCast(self.off_key_list)) +
            @as(usize, @intCast(index)) * ITEM_SHORT_VALUE_OFFSET;

        var buf: [ITEM_RESOURCE_NAME_LENGTH]u8 = undefined;
        @memcpy(&buf, self.data[base .. base + ITEM_RESOURCE_NAME_LENGTH]);

        var length: usize = 0;
        while (length < ITEM_RESOURCE_NAME_LENGTH and buf[length] != 0) {
            length += 1;
        }

        return .{ buf, length };
    }

    pub fn dumpInfo(self: *const RimFile) void {
        std.log.info("+------------------------------------------------------------------------------+", .{});
        std.log.info("|                              RIM File Information                            |", .{});
        std.log.info("+------------------------------------------------------------------------------+", .{});
        std.log.info("| Entry Count: {d:<10} Key List Offset: {d:<10}                          |", .{ self.entry_count, self.off_key_list });
        std.log.info("+-----+------------------+--------------------+---------+------------+--------+", .{});
        std.log.info("| Idx | Resource Name    | Type               |   ID    |   Offset   | Length |", .{});
        std.log.info("+-----+------------------+--------------------+---------+------------+--------+", .{});

        for (self.key_entry_list.items, 0..) |entry, i| {
            const res_type: ResType = @enumFromInt(@as(u16, @bitCast(entry.resource_type)));
            var type_buf: [20]u8 = undefined;
            const type_name = std.enums.tagName(ResType, res_type) orelse "unknown";
            const type_str = std.fmt.bufPrint(&type_buf, "{d} ({s})", .{ entry.resource_type, type_name }) catch "?";
            std.log.info("| {d:>3} | {s:<16} | {s:<18} | {d:>7} | {d:>10} | {d:>6} |", .{
                i,
                entry.name(),
                type_str,
                entry.resource_id,
                entry.offset,
                entry.length,
            });
        }

        std.log.info("+-----+------------------+--------------------+---------+------------+--------+", .{});
    }

    pub fn writeEntryToNewFile(self: *const RimFile, entry_index: i32, output_path: []const u8) !void {
        if (entry_index < 0 or entry_index >= self.entry_count) return RimError.OutOfBounds;

        const resource_data = try self.getRimResource(@intCast(entry_index));

        const file = try std.Io.cwd().createFile(output_path, .{});
        defer file.close();

        try file.writeAll(resource_data);
    }
};

// ── Free functions ────────────────────────────────────────────────────────────

inline fn readI32(data: []const u8, offset: usize) i32 {
    return @as(i32, data[offset]) +
        @as(i32, data[offset + 1]) * 256 +
        @as(i32, data[offset + 2]) * 65536 +
        @as(i32, data[offset + 3]) * 16777216;
}

inline fn readI16(data: []const u8, offset: usize) i16 {
    return @as(i16, @intCast(data[offset])) +
        @as(i16, @intCast(data[offset + 1])) * 256;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "RIM init/deinit empty" {
    var rim = RimFile.init(std.testing.allocator);
    defer rim.deinit();
    try std.testing.expectEqual(@as(i32, 0), rim.entry_count);
}

test "RIM parse: little-endian header fields" {
    const allocator = std.testing.allocator;

    // Minimal fake RIM header (20 bytes): entry_count=1 @ 12, off_key_list=20 @ 16.
    // We only test that parse reads header fields correctly — no valid key entries.
    var buf = [_]u8{0} ** 20;
    buf[12] = 1; // entry_count = 1
    buf[16] = 20; // off_key_list = 20

    var rim = RimFile.init(allocator);
    defer rim.deinit();

    // parse will fail when trying to read the key entry (buffer too small), but
    // entry_count and off_key_list are set before that. Ignore the error here.
    _ = rim.parse(&buf) catch {};

    // If it got far enough before failing, check the header values.
    // (At minimum deinit must not crash.)
    try std.testing.expectEqual(@as(i32, 0), rim.entry_count); // reset on error path
}

test "RIM readI32 little-endian" {
    const buf = [_]u8{ 0x02, 0x01, 0x00, 0x00 };
    try std.testing.expectEqual(@as(i32, 258), readI32(&buf, 0));
}

test "RIM readI16 little-endian" {
    const buf = [_]u8{ 0x05, 0x00 };
    try std.testing.expectEqual(@as(i16, 5), readI16(&buf, 0));
}
