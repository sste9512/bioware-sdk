const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Errors ────────────────────────────────────────────────────────────────────

pub const TpcError = error{ InvalidHeader, InvalidData, OutOfBounds };

// ── Encoding ──────────────────────────────────────────────────────────────────

/// Pixel encoding field from the TPC header.
///
/// When data_size == 0 the data is uncompressed (grey/rgb/rgba/bgra).
/// When data_size > 0 the data is block-compressed:
///   rgb  → DXT1   (8 bytes per 4×4 block)
///   rgba → DXT5  (16 bytes per 4×4 block)
pub const Encoding = enum(u8) {
    grey = 1,
    rgb = 2,
    rgba = 4,
    bgra = 12,
    _,
};

/// Resolved compression mode (derived from encoding + data_size).
pub const Compression = enum { none, dxt1, dxt5 };

// ── TpcHeader ─────────────────────────────────────────────────────────────────

pub const TpcHeader = struct {
    data_size: u32 = 0,
    width: u16 = 0,
    height: u16 = 0,
    encoding: Encoding = .rgba,
    mip_map_count: u8 = 1,
};

// ── TpcFile ───────────────────────────────────────────────────────────────────

pub const TpcFile = struct {
    allocator: Allocator,
    header: TpcHeader = .{},
    /// Raw, unmodified pixel data — all faces (face-major), all mips per face.
    data: []u8 = &.{},
    /// TXI key-value text appended after pixel data; may be empty.
    txi_data: []u8 = &.{},

    pub fn init(allocator: Allocator) TpcFile {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TpcFile) void {
        if (self.data.len > 0) self.allocator.free(self.data);
        if (self.txi_data.len > 0) self.allocator.free(self.txi_data);
        self.data = &.{};
        self.txi_data = &.{};
    }

    // ── Geometry helpers ──────────────────────────────────────────────────────

    pub fn compression(self: *const TpcFile) Compression {
        if (self.header.data_size == 0) return .none;
        return switch (self.header.encoding) {
            .rgb => .dxt1,
            .rgba => .dxt5,
            else => .none,
        };
    }

    /// Cube maps are identified by height == 6 × width.
    pub fn isCubemap(self: *const TpcFile) bool {
        return self.header.height == @as(u16, self.header.width) * 6;
    }

    pub fn faceCount(self: *const TpcFile) u32 {
        return if (self.isCubemap()) 6 else 1;
    }

    pub fn mipCount(self: *const TpcFile) u32 {
        return if (self.header.mip_map_count == 0) 1 else @as(u32, self.header.mip_map_count);
    }

    /// Height of a single face (header.height / faceCount).
    pub fn layerHeight(self: *const TpcFile) u16 {
        const fc = self.faceCount();
        return if (fc == 0) self.header.height else @intCast(self.header.height / fc);
    }

    pub fn bytesPerPixel(self: *const TpcFile) u32 {
        return switch (self.header.encoding) {
            .grey => 1,
            .rgb => 3,
            .rgba => 4,
            .bgra => 4,
            _ => 0,
        };
    }

    /// Byte size of one face at mip level `mip`.
    pub fn mipSize(self: *const TpcFile, mip: u32) u32 {
        const w = @max(1, @as(u32, self.header.width) >> @intCast(mip));
        const h = @max(1, @as(u32, self.layerHeight()) >> @intCast(mip));
        return switch (self.compression()) {
            .none => w * h * self.bytesPerPixel(),
            .dxt1 => @max(1, (w + 3) / 4) * @max(1, (h + 3) / 4) * 8,
            .dxt5 => @max(1, (w + 3) / 4) * @max(1, (h + 3) / 4) * 16,
        };
    }

    /// Total size of all mip levels for one face.
    pub fn faceTotalSize(self: *const TpcFile) u32 {
        var total: u32 = 0;
        for (0..self.mipCount()) |m| total += self.mipSize(@intCast(m));
        return total;
    }

    /// Total size of all pixel data (all faces × all mips).
    pub fn totalDataSize(self: *const TpcFile) u32 {
        return self.faceCount() * self.faceTotalSize();
    }

    // ── Parse ─────────────────────────────────────────────────────────────────

    pub fn parse(self: *TpcFile, raw: []const u8) !void {
        if (raw.len < 128) return TpcError.InvalidHeader;

        self.header = .{
            .data_size = rd32(raw, 0),
            .width = rd16(raw, 8),
            .height = rd16(raw, 10),
            .encoding = @enumFromInt(raw[12]),
            .mip_map_count = raw[13],
        };

        // Compute expected data size.
        const expected = self.totalDataSize();
        if (128 + expected > raw.len) return TpcError.InvalidData;

        // Pixel data.
        self.data = try self.allocator.dupe(u8, raw[128 .. 128 + expected]);
        errdefer {
            self.allocator.free(self.data);
            self.data = &.{};
        }

        // TXI data: everything after pixel data, stripped of leading/trailing nulls.
        const txi_raw = raw[128 + expected ..];
        const txi_trimmed = std.mem.trimRight(u8, std.mem.trimLeft(u8, txi_raw, &.{0}), &.{0});
        if (txi_trimmed.len > 0) {
            self.txi_data = try self.allocator.dupe(u8, txi_trimmed);
        }
        errdefer {
            if (self.txi_data.len > 0) {
                self.allocator.free(self.txi_data);
                self.txi_data = &.{};
            }
        }
    }

    // ── Serialize ─────────────────────────────────────────────────────────────

    pub fn serialize(self: *const TpcFile, allocator: Allocator) ![]u8 {
        const total = 128 + self.data.len + self.txi_data.len;
        const buf = try allocator.alloc(u8, total);

        wr32(buf, 0, self.header.data_size);
        wr32(buf, 4, 0); // reserved float
        wr16(buf, 8, self.header.width);
        wr16(buf, 10, self.header.height);
        buf[12] = @intFromEnum(self.header.encoding);
        buf[13] = self.header.mip_map_count;
        @memset(buf[14..128], 0); // reserved

        @memcpy(buf[128..][0..self.data.len], self.data);
        if (self.txi_data.len > 0) {
            @memcpy(buf[128 + self.data.len ..][0..self.txi_data.len], self.txi_data);
        }
        return buf;
    }

    // ── Surface access ────────────────────────────────────────────────────────

    /// Return a slice into `data` for the given face and mip level.
    ///
    /// For non-cubemap textures face must be 0.
    /// Layout in `data`: face-major — all mip levels of face 0 first,
    /// then all mip levels of face 1, etc.
    pub fn getSurface(self: *const TpcFile, face: u32, mip: u32) ![]const u8 {
        if (face >= self.faceCount() or mip >= self.mipCount()) return TpcError.OutOfBounds;

        const face_base = face * self.faceTotalSize();
        var mip_off: u32 = 0;
        for (0..mip) |m| mip_off += self.mipSize(@intCast(m));

        const offset = face_base + mip_off;
        const sz = self.mipSize(mip);
        if (offset + sz > self.data.len) return TpcError.InvalidData;
        return self.data[offset .. offset + sz];
    }
};

// ── I/O helpers ───────────────────────────────────────────────────────────────

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

// ── Tests ─────────────────────────────────────────────────────────────────────

fn makeHeader(w: u16, h: u16, enc: u8, mips: u8, data_size: u32) [128]u8 {
    var buf = [_]u8{0} ** 128;
    std.mem.writeInt(u32, buf[0..4], data_size, .little);
    std.mem.writeInt(u16, buf[8..10], w, .little);
    std.mem.writeInt(u16, buf[10..12], h, .little);
    buf[12] = enc;
    buf[13] = mips;
    return buf;
}

test "TPC parse: greyscale uncompressed 4x4" {
    const alloc = std.testing.allocator;
    const pixels = [_]u8{128} ** 16; // 4*4*1 bytes
    var buf: [128 + 16]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 1, 1, 0));
    @memcpy(buf[128..], &pixels);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expectEqual(@as(u16, 4), tpc.header.width);
    try std.testing.expectEqual(@as(u16, 4), tpc.header.height);
    try std.testing.expectEqual(Encoding.grey, tpc.header.encoding);
    try std.testing.expectEqual(Compression.none, tpc.compression());
    try std.testing.expectEqual(@as(u32, 16), tpc.totalDataSize());
    try std.testing.expectEqualSlices(u8, &pixels, tpc.data);
}

test "TPC parse: DXT1 compressed 4x4" {
    const alloc = std.testing.allocator;
    // DXT1 4x4 = 1 block = 8 bytes; encoding=2, dataSize=8
    const block = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 1, 2, 3, 4 };
    var buf: [128 + 8]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 2, 1, 8));
    @memcpy(buf[128..], &block);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expectEqual(Compression.dxt1, tpc.compression());
    try std.testing.expectEqual(@as(u32, 8), tpc.mipSize(0));
    try std.testing.expectEqualSlices(u8, &block, tpc.data);
}

test "TPC parse: DXT5 compressed 4x4" {
    const alloc = std.testing.allocator;
    // DXT5 4x4 = 1 block = 16 bytes; encoding=4, dataSize=16
    const block = [_]u8{0xFF} ** 16;
    var buf: [128 + 16]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 4, 1, 16));
    @memcpy(buf[128..], &block);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expectEqual(Compression.dxt5, tpc.compression());
    try std.testing.expectEqual(@as(u32, 16), tpc.mipSize(0));
}

test "TPC isCubemap detection" {
    const alloc = std.testing.allocator;
    // 4×24 → height == 6 * width → cubemap
    const face_bytes: u32 = 4 * 4 * 4; // rgba 4x4 per face
    const total: u32 = face_bytes * 6;
    var buf: [128 + face_bytes * 6]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 24, 4, 1, 0));
    @memset(buf[128..], 0xAB);
    // Trim buffer to exactly total
    _ = total;

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expect(tpc.isCubemap());
    try std.testing.expectEqual(@as(u32, 6), tpc.faceCount());
    try std.testing.expectEqual(@as(u16, 4), tpc.layerHeight());
}

test "TPC mipSize at multiple levels (DXT1)" {
    const alloc = std.testing.allocator;
    // 8x8 DXT1, 3 mips (8x8=8, 4x4=8, 2x2=8 min block)
    // sizes: mip0 = (8+3)/4*(8+3)/4*8 = 2*2*8=32, mip1=1*1*8=8, mip2=1*1*8=8 → total=48
    const total: u32 = 32 + 8 + 8;
    var buf: [128 + 48]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(8, 8, 2, 3, total));
    @memset(buf[128..], 0);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expectEqual(@as(u32, 32), tpc.mipSize(0));
    try std.testing.expectEqual(@as(u32, 8), tpc.mipSize(1));
    try std.testing.expectEqual(@as(u32, 8), tpc.mipSize(2));
    try std.testing.expectEqual(@as(u32, total), tpc.totalDataSize());
}

test "TPC getSurface returns correct slice" {
    const alloc = std.testing.allocator;
    const pix = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 8 bytes DXT1 4x4
    var buf: [128 + 8]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 2, 1, 8));
    @memcpy(buf[128..], &pix);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    const surf = try tpc.getSurface(0, 0);
    try std.testing.expectEqualSlices(u8, &pix, surf);
}

test "TPC TXI data extraction" {
    const alloc = std.testing.allocator;
    const pixels = [_]u8{200} ** 16;
    const txi_text = "cube 1\nbumpmapped 1\n";
    var buf: [128 + 16 + txi_text.len]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 1, 1, 0));
    @memcpy(buf[128..144], &pixels);
    @memcpy(buf[144..], txi_text);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expectEqualSlices(u8, txi_text, tpc.txi_data);
}

test "TPC round-trip serialize -> parse" {
    const alloc = std.testing.allocator;
    const pixels = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 };

    var orig = TpcFile.init(alloc);
    defer orig.deinit();
    orig.header = .{
        .data_size = 0,
        .width = 2,
        .height = 2,
        .encoding = .rgb,
        .mip_map_count = 1,
    };
    orig.data = try alloc.dupe(u8, &pixels);

    const bytes = try orig.serialize(alloc);
    defer alloc.free(bytes);

    var tpc2 = TpcFile.init(alloc);
    defer tpc2.deinit();
    try tpc2.parse(bytes);

    try std.testing.expectEqual(orig.header.width, tpc2.header.width);
    try std.testing.expectEqual(orig.header.height, tpc2.header.height);
    try std.testing.expectEqual(orig.header.encoding, tpc2.header.encoding);
    try std.testing.expectEqual(orig.header.mip_map_count, tpc2.header.mip_map_count);
    try std.testing.expectEqualSlices(u8, orig.data, tpc2.data);
}

test "TPC getSurface out of bounds" {
    const alloc = std.testing.allocator;
    const pix = [_]u8{0} ** 16;
    var buf: [128 + 16]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 4, 1, 0));
    @memcpy(buf[128..], &pix);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try tpc.parse(&buf);

    try std.testing.expectError(TpcError.OutOfBounds, tpc.getSurface(1, 0));
    try std.testing.expectError(TpcError.OutOfBounds, tpc.getSurface(0, 1));
}

test "TPC truncated data returns error" {
    const alloc = std.testing.allocator;
    // Header says 4x4 rgba (16 bytes needed) but only 4 bytes of data.
    var buf: [128 + 4]u8 = undefined;
    @memcpy(buf[0..128], &makeHeader(4, 4, 4, 1, 0));
    @memset(buf[128..], 0);

    var tpc = TpcFile.init(alloc);
    defer tpc.deinit();
    try std.testing.expectError(TpcError.InvalidData, tpc.parse(&buf));
}
