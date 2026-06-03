const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Errors ────────────────────────────────────────────────────────────────────

pub const DdsError = error{ InvalidMagic, InvalidHeader, InvalidData, UnsupportedFormat };

// ── Constants ─────────────────────────────────────────────────────────────────

pub const MAGIC: u32 = 0x20534444; // "DDS "

// dwFlags
pub const DDSD_CAPS: u32 = 0x00000001;
pub const DDSD_HEIGHT: u32 = 0x00000002;
pub const DDSD_WIDTH: u32 = 0x00000004;
pub const DDSD_PITCH: u32 = 0x00000008;
pub const DDSD_PIXELFORMAT: u32 = 0x00001000;
pub const DDSD_MIPMAPCOUNT: u32 = 0x00020000;
pub const DDSD_LINEARSIZE: u32 = 0x00080000;
pub const DDSD_DEPTH: u32 = 0x00800000;

// dwCaps
pub const DDSCAPS_COMPLEX: u32 = 0x00000008;
pub const DDSCAPS_TEXTURE: u32 = 0x00001000;
pub const DDSCAPS_MIPMAP: u32 = 0x00400000;

// dwCaps2
pub const DDSCAPS2_CUBEMAP: u32 = 0x00000200;
pub const DDSCAPS2_CUBEMAP_POSITIVEX: u32 = 0x00000400;
pub const DDSCAPS2_CUBEMAP_NEGATIVEX: u32 = 0x00000800;
pub const DDSCAPS2_CUBEMAP_POSITIVEY: u32 = 0x00001000;
pub const DDSCAPS2_CUBEMAP_NEGATIVEY: u32 = 0x00002000;
pub const DDSCAPS2_CUBEMAP_POSITIVEZ: u32 = 0x00004000;
pub const DDSCAPS2_CUBEMAP_NEGATIVEZ: u32 = 0x00008000;
pub const DDSCAPS2_CUBEMAP_ALL_FACES: u32 = 0x0000FC00;
pub const DDSCAPS2_VOLUME: u32 = 0x00200000;

// DDPF dwFlags
pub const DDPF_ALPHAPIXELS: u32 = 0x00000001;
pub const DDPF_ALPHA: u32 = 0x00000002;
pub const DDPF_FOURCC: u32 = 0x00000004;
pub const DDPF_RGB: u32 = 0x00000040;
pub const DDPF_YUV: u32 = 0x00000200;
pub const DDPF_LUMINANCE: u32 = 0x00020000;

// FourCC codes (LE u32)
pub const FOURCC_DXT1: u32 = fourcc("DXT1");
pub const FOURCC_DXT2: u32 = fourcc("DXT2");
pub const FOURCC_DXT3: u32 = fourcc("DXT3");
pub const FOURCC_DXT4: u32 = fourcc("DXT4");
pub const FOURCC_DXT5: u32 = fourcc("DXT5");
pub const FOURCC_BC4U: u32 = fourcc("BC4U");
pub const FOURCC_BC4S: u32 = fourcc("BC4S");
pub const FOURCC_ATI2: u32 = fourcc("ATI2");
pub const FOURCC_BC5U: u32 = fourcc("BC5U");
pub const FOURCC_BC5S: u32 = fourcc("BC5S");
pub const FOURCC_DX10: u32 = fourcc("DX10");

fn fourcc(s: *const [4]u8) u32 {
    return @as(u32, s[0]) |
        @as(u32, s[1]) << 8 |
        @as(u32, s[2]) << 16 |
        @as(u32, s[3]) << 24;
}

// ── PixelFormat ───────────────────────────────────────────────────────────────

pub const PixelFormat = enum {
    dxt1,
    dxt2,
    dxt3,
    dxt4,
    dxt5,
    bc4u,
    bc4s,
    bc5u,
    bc5s,
    dx10,
    bgra8,
    rgba8,
    rgb8,
    bgr8,
    rgb565,
    rgba5551,
    rgba4444,
    l8,
    l16,
    a8,
    a8l8,
    unknown,
};

// ── DdsPixelFormat ────────────────────────────────────────────────────────────

pub const DdsPixelFormat = struct {
    flags: u32 = DDPF_FOURCC,
    four_cc: u32 = FOURCC_DXT5,
    rgb_bit_count: u32 = 0,
    r_bit_mask: u32 = 0,
    g_bit_mask: u32 = 0,
    b_bit_mask: u32 = 0,
    a_bit_mask: u32 = 0,

    pub fn pixelFormat(self: DdsPixelFormat) PixelFormat {
        if (self.flags & DDPF_FOURCC != 0) {
            return switch (self.four_cc) {
                FOURCC_DXT1 => .dxt1,
                FOURCC_DXT2 => .dxt2,
                FOURCC_DXT3 => .dxt3,
                FOURCC_DXT4 => .dxt4,
                FOURCC_DXT5 => .dxt5,
                FOURCC_BC4U => .bc4u,
                FOURCC_BC4S => .bc4s,
                FOURCC_ATI2 => .bc5u,
                FOURCC_BC5U => .bc5u,
                FOURCC_BC5S => .bc5s,
                FOURCC_DX10 => .dx10,
                else => .unknown,
            };
        }
        if (self.flags & DDPF_RGB != 0) {
            return detectRgbFormat(self);
        }
        if (self.flags & DDPF_LUMINANCE != 0) {
            return if (self.flags & DDPF_ALPHAPIXELS != 0) .a8l8 else if (self.rgb_bit_count == 16) .l16 else .l8;
        }
        if (self.flags & DDPF_ALPHA != 0) return .a8;
        return .unknown;
    }

    fn detectRgbFormat(self: DdsPixelFormat) PixelFormat {
        return switch (self.rgb_bit_count) {
            32 => blk: {
                const has_alpha = self.flags & DDPF_ALPHAPIXELS != 0;
                if (has_alpha and self.r_bit_mask == 0x00FF0000 and self.b_bit_mask == 0x000000FF) break :blk .bgra8;
                if (has_alpha and self.r_bit_mask == 0x000000FF and self.b_bit_mask == 0x00FF0000) break :blk .rgba8;
                if (self.r_bit_mask == 0x00FF0000) break :blk .bgr8;
                break :blk .unknown;
            },
            24 => if (self.r_bit_mask == 0xFF0000) .bgr8 else if (self.r_bit_mask == 0x0000FF) .rgb8 else .unknown,
            16 => blk: {
                if (self.r_bit_mask == 0xF800) break :blk .rgb565;
                if (self.r_bit_mask == 0x7C00) break :blk .rgba5551;
                if (self.r_bit_mask == 0x0F00) break :blk .rgba4444;
                break :blk .unknown;
            },
            else => .unknown,
        };
    }
};

// ── DdsHeader ─────────────────────────────────────────────────────────────────

pub const DdsHeader = struct {
    flags: u32 = DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT,
    height: u32 = 0,
    width: u32 = 0,
    pitch_or_linear_size: u32 = 0,
    depth: u32 = 0,
    mip_map_count: u32 = 0,
    pixel_format: DdsPixelFormat = .{},
    caps: u32 = DDSCAPS_TEXTURE,
    caps2: u32 = 0,

    pub fn isCubemap(self: DdsHeader) bool {
        return self.caps2 & DDSCAPS2_CUBEMAP != 0;
    }

    pub fn isVolume(self: DdsHeader) bool {
        return self.caps2 & DDSCAPS2_VOLUME != 0;
    }

    pub fn mipCount(self: DdsHeader) u32 {
        return if (self.mip_map_count == 0) 1 else self.mip_map_count;
    }

    pub fn faceCount(self: DdsHeader) u32 {
        if (!self.isCubemap()) return 1;
        var n: u32 = 0;
        const mask = [_]u32{
            DDSCAPS2_CUBEMAP_POSITIVEX, DDSCAPS2_CUBEMAP_NEGATIVEX,
            DDSCAPS2_CUBEMAP_POSITIVEY, DDSCAPS2_CUBEMAP_NEGATIVEY,
            DDSCAPS2_CUBEMAP_POSITIVEZ, DDSCAPS2_CUBEMAP_NEGATIVEZ,
        };
        for (mask) |m| if (self.caps2 & m != 0) {
            n += 1;
        };
        return n;
    }
};

// ── DdsDxt10Header ────────────────────────────────────────────────────────────

pub const DdsDxt10Header = struct {
    dxgi_format: u32 = 0,
    resource_dimension: u32 = 3, // TEXTURE2D
    misc_flag: u32 = 0,
    array_size: u32 = 1,
    misc_flags2: u32 = 0,
};

// ── DdsFile ───────────────────────────────────────────────────────────────────

pub const DdsFile = struct {
    allocator: Allocator,
    header: DdsHeader = .{},
    dxt10: ?DdsDxt10Header = null,
    /// Raw texture data bytes (all mip levels, all faces).
    data: []u8 = &.{},

    pub fn init(allocator: Allocator) DdsFile {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DdsFile) void {
        if (self.data.len > 0) self.allocator.free(self.data);
        self.data = &.{};
    }

    // ── Parse ─────────────────────────────────────────────────────────────────

    pub fn parse(self: *DdsFile, raw: []const u8) !void {
        if (raw.len < 128) return DdsError.InvalidMagic;
        if (rd32(raw, 0) != MAGIC) return DdsError.InvalidMagic;
        if (rd32(raw, 4) != 124) return DdsError.InvalidHeader;

        self.header = .{
            .flags = rd32(raw, 8),
            .height = rd32(raw, 12),
            .width = rd32(raw, 16),
            .pitch_or_linear_size = rd32(raw, 20),
            .depth = rd32(raw, 24),
            .mip_map_count = rd32(raw, 28),
            .pixel_format = .{
                // ddspf at offset 76 (4 magic + 72 into header)
                .flags = rd32(raw, 76),
                .four_cc = rd32(raw, 80),
                .rgb_bit_count = rd32(raw, 84),
                .r_bit_mask = rd32(raw, 88),
                .g_bit_mask = rd32(raw, 92),
                .b_bit_mask = rd32(raw, 96),
                .a_bit_mask = rd32(raw, 100),
            },
            .caps = rd32(raw, 104 + 4), // offset 108 in file
            .caps2 = rd32(raw, 104 + 8), // offset 112 in file
        };

        if (rd32(raw, 76 + 4) != 32) return DdsError.InvalidHeader; // ddspf.dwSize

        var data_offset: usize = 128;

        if (self.header.pixel_format.four_cc == FOURCC_DX10) {
            if (raw.len < 148) return DdsError.InvalidHeader;
            self.dxt10 = DdsDxt10Header{
                .dxgi_format = rd32(raw, 128),
                .resource_dimension = rd32(raw, 132),
                .misc_flag = rd32(raw, 136),
                .array_size = rd32(raw, 140),
                .misc_flags2 = rd32(raw, 144),
            };
            data_offset = 148;
        }

        if (data_offset > raw.len) return DdsError.InvalidData;
        self.data = try self.allocator.dupe(u8, raw[data_offset..]);
        errdefer {
            self.allocator.free(self.data);
            self.data = &.{};
        }
    }

    // ── Serialize ─────────────────────────────────────────────────────────────

    pub fn serialize(self: *const DdsFile, allocator: Allocator) ![]u8 {
        const has_dxt10 = self.dxt10 != null;
        const total = 128 + (if (has_dxt10) @as(usize, 20) else 0) + self.data.len;
        const buf = try allocator.alloc(u8, total);

        wr32(buf, 0, MAGIC);
        wr32(buf, 4, 124); // dwSize

        const h = self.header;
        wr32(buf, 8, h.flags);
        wr32(buf, 12, h.height);
        wr32(buf, 16, h.width);
        wr32(buf, 20, h.pitch_or_linear_size);
        wr32(buf, 24, h.depth);
        wr32(buf, 28, h.mip_map_count);
        @memset(buf[32..76], 0); // dwReserved1[11]

        // DDS_PIXELFORMAT at offset 76 in file
        wr32(buf, 76, 32); // dwSize
        wr32(buf, 80, h.pixel_format.flags);
        wr32(buf, 84, h.pixel_format.four_cc);
        wr32(buf, 88, h.pixel_format.rgb_bit_count);
        wr32(buf, 92, h.pixel_format.r_bit_mask);
        wr32(buf, 96, h.pixel_format.g_bit_mask);
        wr32(buf, 100, h.pixel_format.b_bit_mask);
        wr32(buf, 104, h.pixel_format.a_bit_mask);

        // Remainder of DDS_HEADER after ddspf (caps at offset 108 in file)
        wr32(buf, 108, h.caps);
        wr32(buf, 112, h.caps2);
        wr32(buf, 116, 0); // dwCaps3
        wr32(buf, 120, 0); // dwCaps4
        wr32(buf, 124, 0); // dwReserved2

        var off: usize = 128;
        if (has_dxt10) {
            const dx = self.dxt10.?;
            wr32(buf, off + 0, dx.dxgi_format);
            wr32(buf, off + 4, dx.resource_dimension);
            wr32(buf, off + 8, dx.misc_flag);
            wr32(buf, off + 12, dx.array_size);
            wr32(buf, off + 16, dx.misc_flags2);
            off += 20;
        }

        @memcpy(buf[off..][0..self.data.len], self.data);
        return buf;
    }

    // ── Surface helpers ───────────────────────────────────────────────────────

    pub fn pixelFormat(self: *const DdsFile) PixelFormat {
        return self.header.pixel_format.pixelFormat();
    }

    pub fn isCompressed(self: *const DdsFile) bool {
        return switch (self.pixelFormat()) {
            .dxt1, .dxt2, .dxt3, .dxt4, .dxt5, .bc4u, .bc4s, .bc5u, .bc5s => true,
            else => false,
        };
    }

    /// Bytes per 4×4 compressed block, or bytes per pixel for uncompressed.
    pub fn blockBytes(self: *const DdsFile) u32 {
        return switch (self.pixelFormat()) {
            .dxt1, .bc4u, .bc4s => 8,
            .dxt2, .dxt3, .dxt4, .dxt5, .bc5u, .bc5s => 16,
            else => self.header.pixel_format.rgb_bit_count / 8,
        };
    }

    /// Byte size of one surface at the given mip level.
    pub fn surfaceSize(self: *const DdsFile, mip: u32) u32 {
        const w = @max(1, self.header.width >> @intCast(mip));
        const h = @max(1, self.header.height >> @intCast(mip));
        if (self.isCompressed()) {
            const blocks_w = (w + 3) / 4;
            const blocks_h = (h + 3) / 4;
            return blocks_w * blocks_h * self.blockBytes();
        } else {
            return w * h * self.blockBytes();
        }
    }

    /// Byte slice into `data` for the given face index and mip level.
    /// Face is 0 for non-cubemap textures. Mip 0 is the full-size surface.
    pub fn getSurface(self: *const DdsFile, face: u32, mip: u32) ![]const u8 {
        const face_count = self.header.faceCount();
        const mip_count = self.header.mipCount();
        if (face >= face_count or mip >= mip_count) return DdsError.OutOfBounds;

        // Compute size of one full face (all mips).
        var face_offset: usize = 0;
        for (0..face) |_| {
            for (0..mip_count) |m| face_offset += self.surfaceSize(@intCast(m));
        }
        // Advance through mip levels within the face.
        var mip_offset: usize = face_offset;
        for (0..mip) |m| mip_offset += self.surfaceSize(@intCast(m));

        const sz = self.surfaceSize(mip);
        if (mip_offset + sz > self.data.len) return DdsError.InvalidData;
        return self.data[mip_offset .. mip_offset + sz];
    }
};

// ── I/O helpers ───────────────────────────────────────────────────────────────

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

inline fn wr32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn makeDxt1Header(width: u32, height: u32, linear_size: u32) [128]u8 {
    var buf = [_]u8{0} ** 128;
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 124, .little);
    std.mem.writeInt(u32, buf[8..12], DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH |
        DDSD_PIXELFORMAT | DDSD_LINEARSIZE, .little);
    std.mem.writeInt(u32, buf[12..16], height, .little);
    std.mem.writeInt(u32, buf[16..20], width, .little);
    std.mem.writeInt(u32, buf[20..24], linear_size, .little);
    std.mem.writeInt(u32, buf[24..28], 0, .little); // depth
    std.mem.writeInt(u32, buf[28..32], 0, .little); // mipcount
    // ddspf at byte 76 in file (offset 72 into header)
    std.mem.writeInt(u32, buf[76..80], 32, .little); // dwSize
    std.mem.writeInt(u32, buf[80..84], DDPF_FOURCC, .little);
    std.mem.writeInt(u32, buf[84..88], FOURCC_DXT1, .little);
    // caps at offset 108
    std.mem.writeInt(u32, buf[108..112], DDSCAPS_TEXTURE, .little);
    return buf;
}

test "DDS parse: DXT1 header fields" {
    const alloc = std.testing.allocator;
    const pixel_data = [_]u8{0} ** 8; // 1 DXT1 block = 8 bytes for 4x4
    var buf: [128 + 8]u8 = undefined;
    const hdr = makeDxt1Header(4, 4, 8);
    @memcpy(buf[0..128], &hdr);
    @memcpy(buf[128..], &pixel_data);

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try dds.parse(&buf);

    try std.testing.expectEqual(@as(u32, 4), dds.header.width);
    try std.testing.expectEqual(@as(u32, 4), dds.header.height);
    try std.testing.expectEqual(PixelFormat.dxt1, dds.pixelFormat());
    try std.testing.expect(dds.isCompressed());
    try std.testing.expectEqual(@as(u32, 8), dds.blockBytes());
}

test "DDS round-trip serialize -> parse" {
    const alloc = std.testing.allocator;

    const pixel_data = [_]u8{ 0xAA, 0xBB } ** 8; // 16 bytes for DXT5 4x4
    var buf: [128 + 16]u8 = undefined;
    var hdr = [_]u8{0} ** 128;
    std.mem.writeInt(u32, hdr[0..4], MAGIC, .little);
    std.mem.writeInt(u32, hdr[4..8], 124, .little);
    std.mem.writeInt(u32, hdr[8..12], DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_LINEARSIZE, .little);
    std.mem.writeInt(u32, hdr[12..16], 4, .little);
    std.mem.writeInt(u32, hdr[16..20], 4, .little);
    std.mem.writeInt(u32, hdr[20..24], 16, .little);
    std.mem.writeInt(u32, hdr[76..80], 32, .little);
    std.mem.writeInt(u32, hdr[80..84], DDPF_FOURCC, .little);
    std.mem.writeInt(u32, hdr[84..88], FOURCC_DXT5, .little);
    std.mem.writeInt(u32, hdr[108..112], DDSCAPS_TEXTURE, .little);
    @memcpy(buf[0..128], &hdr);
    @memcpy(buf[128..], &pixel_data);

    var orig = DdsFile.init(alloc);
    defer orig.deinit();
    try orig.parse(&buf);

    const bytes = try orig.serialize(alloc);
    defer alloc.free(bytes);

    var dds2 = DdsFile.init(alloc);
    defer dds2.deinit();
    try dds2.parse(bytes);

    try std.testing.expectEqual(orig.header.width, dds2.header.width);
    try std.testing.expectEqual(orig.header.height, dds2.header.height);
    try std.testing.expectEqual(orig.pixelFormat(), dds2.pixelFormat());
    try std.testing.expectEqualSlices(u8, orig.data, dds2.data);
}

test "DDS DXT1 surfaceSize" {
    const alloc = std.testing.allocator;
    const pixel_data = [_]u8{0} ** 8;
    var buf: [128 + 8]u8 = undefined;
    @memcpy(buf[0..128], &makeDxt1Header(4, 4, 8));
    @memcpy(buf[128..], &pixel_data);

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try dds.parse(&buf);

    try std.testing.expectEqual(@as(u32, 8), dds.surfaceSize(0)); // 1×1 block × 8 bytes
}

test "DDS uncompressed BGRA8 surfaceSize" {
    const alloc = std.testing.allocator;
    // 2x2 BGRA8 = 16 bytes of pixel data
    var buf: [128 + 16]u8 = [_]u8{0} ** (128 + 16);
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 124, .little);
    std.mem.writeInt(u32, buf[8..12], DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_PITCH, .little);
    std.mem.writeInt(u32, buf[12..16], 2, .little); // height
    std.mem.writeInt(u32, buf[16..20], 2, .little); // width
    std.mem.writeInt(u32, buf[20..24], 8, .little); // pitch = 2 * 4
    std.mem.writeInt(u32, buf[76..80], 32, .little);
    std.mem.writeInt(u32, buf[80..84], DDPF_RGB | DDPF_ALPHAPIXELS, .little);
    std.mem.writeInt(u32, buf[84..88], 32, .little); // rgb_bit_count
    std.mem.writeInt(u32, buf[88..92], 0x00FF0000, .little); // r_mask (BGR: R is at 0x00FF0000)
    std.mem.writeInt(u32, buf[92..96], 0x0000FF00, .little); // g_mask
    std.mem.writeInt(u32, buf[96..100], 0x000000FF, .little); // b_mask
    std.mem.writeInt(u32, buf[100..104], 0xFF000000, .little); // a_mask
    std.mem.writeInt(u32, buf[108..112], DDSCAPS_TEXTURE, .little);

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try dds.parse(&buf);

    try std.testing.expectEqual(PixelFormat.bgra8, dds.pixelFormat());
    try std.testing.expectEqual(@as(u32, 16), dds.surfaceSize(0)); // 2*2*4 bytes
}

test "DDS DX10 extension header parsed" {
    const alloc = std.testing.allocator;
    var buf: [148 + 8]u8 = [_]u8{0} ** (148 + 8);
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 124, .little);
    std.mem.writeInt(u32, buf[8..12], DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_LINEARSIZE, .little);
    std.mem.writeInt(u32, buf[12..16], 4, .little);
    std.mem.writeInt(u32, buf[16..20], 4, .little);
    std.mem.writeInt(u32, buf[20..24], 8, .little);
    std.mem.writeInt(u32, buf[76..80], 32, .little);
    std.mem.writeInt(u32, buf[80..84], DDPF_FOURCC, .little);
    std.mem.writeInt(u32, buf[84..88], FOURCC_DX10, .little);
    std.mem.writeInt(u32, buf[108..112], DDSCAPS_TEXTURE, .little);
    // DX10 header at 128
    std.mem.writeInt(u32, buf[128..132], 71, .little); // DXGI_FORMAT_BC1_UNORM
    std.mem.writeInt(u32, buf[132..136], 3, .little); // TEXTURE2D
    std.mem.writeInt(u32, buf[136..140], 0, .little);
    std.mem.writeInt(u32, buf[140..144], 1, .little); // arraySize
    std.mem.writeInt(u32, buf[144..148], 0, .little);

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try dds.parse(&buf);

    try std.testing.expect(dds.dxt10 != null);
    try std.testing.expectEqual(@as(u32, 71), dds.dxt10.?.dxgi_format);
    try std.testing.expectEqual(@as(u32, 1), dds.dxt10.?.array_size);
}

test "DDS getSurface mip 0" {
    const alloc = std.testing.allocator;
    const pix = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var buf: [128 + 8]u8 = undefined;
    @memcpy(buf[0..128], &makeDxt1Header(4, 4, 8));
    @memcpy(buf[128..], &pix);

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try dds.parse(&buf);

    const surf = try dds.getSurface(0, 0);
    try std.testing.expectEqualSlices(u8, &pix, surf);
}

test "DDS getSurface out of bounds" {
    const alloc = std.testing.allocator;
    const pix = [_]u8{0} ** 8;
    var buf: [128 + 8]u8 = undefined;
    @memcpy(buf[0..128], &makeDxt1Header(4, 4, 8));
    @memcpy(buf[128..], &pix);

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try dds.parse(&buf);

    try std.testing.expectError(DdsError.OutOfBounds, dds.getSurface(1, 0));
    try std.testing.expectError(DdsError.OutOfBounds, dds.getSurface(0, 1));
}

test "DDS invalid magic" {
    const alloc = std.testing.allocator;
    var buf = [_]u8{0} ** 128;
    buf[0] = 0xFF; // bad magic

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try std.testing.expectError(DdsError.InvalidMagic, dds.parse(&buf));
}

test "DDS invalid header size" {
    const alloc = std.testing.allocator;
    var buf = [_]u8{0} ** 128;
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 99, .little); // wrong dwSize

    var dds = DdsFile.init(alloc);
    defer dds.deinit();
    try std.testing.expectError(DdsError.InvalidHeader, dds.parse(&buf));
}
