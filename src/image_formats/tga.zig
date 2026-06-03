const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Errors ────────────────────────────────────────────────────────────────────

pub const TgaError = error{ InvalidHeader, UnsupportedFormat, InvalidData, OutOfBounds };

// ── ImageType ─────────────────────────────────────────────────────────────────

pub const ImageType = enum(u8) {
    none = 0,
    color_mapped = 1,
    true_color = 2,
    grayscale = 3,
    color_mapped_rle = 9,
    true_color_rle = 10,
    grayscale_rle = 11,
    _,
};

// ── TgaHeader ─────────────────────────────────────────────────────────────────

pub const TgaHeader = struct {
    id_length: u8 = 0,
    color_map_type: u8 = 0,
    image_type: ImageType = .true_color,
    color_map_origin: u16 = 0,
    color_map_length: u16 = 0,
    color_map_entry_size: u8 = 0,
    x_origin: i16 = 0,
    y_origin: i16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    bits_per_pixel: u8 = 24,
    image_descriptor: u8 = 0x20,

    pub fn isTopDown(self: TgaHeader) bool {
        return (self.image_descriptor >> 5) & 1 == 1;
    }

    pub fn attributeBits(self: TgaHeader) u4 {
        return @truncate(self.image_descriptor & 0x0F);
    }

    pub fn isRle(self: TgaHeader) bool {
        const v = @intFromEnum(self.image_type);
        return v == 9 or v == 10 or v == 11;
    }

    pub fn hasColorMap(self: TgaHeader) bool {
        return self.color_map_type == 1;
    }

    pub fn bytesPerPixel(self: TgaHeader) u8 {
        return self.bits_per_pixel / 8;
    }
};

// ── TgaFile ───────────────────────────────────────────────────────────────────

pub const TgaFile = struct {
    allocator: Allocator,
    header: TgaHeader = .{},
    id_data: []u8 = &.{},
    color_map: []u8 = &.{},
    /// Uncompressed, top-down, row-major pixel bytes.
    pixels: []u8 = &.{},

    pub fn init(allocator: Allocator) TgaFile {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TgaFile) void {
        if (self.id_data.len > 0) self.allocator.free(self.id_data);
        if (self.color_map.len > 0) self.allocator.free(self.color_map);
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        self.id_data = &.{};
        self.color_map = &.{};
        self.pixels = &.{};
    }

    pub fn pixelStride(self: *const TgaFile) usize {
        return @as(usize, self.header.width) * @as(usize, self.header.bytesPerPixel());
    }

    // ── Parse ─────────────────────────────────────────────────────────────────

    pub fn parse(self: *TgaFile, data: []const u8) !void {
        if (data.len < 18) return TgaError.InvalidHeader;

        self.header = .{
            .id_length = data[0],
            .color_map_type = data[1],
            .image_type = @enumFromInt(data[2]),
            .color_map_origin = rd16(data, 3),
            .color_map_length = rd16(data, 5),
            .color_map_entry_size = data[7],
            .x_origin = @bitCast(rd16(data, 8)),
            .y_origin = @bitCast(rd16(data, 10)),
            .width = rd16(data, 12),
            .height = rd16(data, 14),
            .bits_per_pixel = data[16],
            .image_descriptor = data[17],
        };

        const it = @intFromEnum(self.header.image_type);
        if (it != 0 and it != 1 and it != 2 and it != 3 and
            it != 9 and it != 10 and it != 11) return TgaError.UnsupportedFormat;

        var offset: usize = 18;

        // ID field
        const id_len: usize = self.header.id_length;
        if (offset + id_len > data.len) return TgaError.InvalidData;
        if (id_len > 0) {
            self.id_data = try self.allocator.dupe(u8, data[offset .. offset + id_len]);
        }
        errdefer {
            if (self.id_data.len > 0) {
                self.allocator.free(self.id_data);
                self.id_data = &.{};
            }
        }
        offset += id_len;

        // Color map
        if (self.header.hasColorMap()) {
            const cm_bytes = @as(usize, self.header.color_map_length) *
                (@as(usize, self.header.color_map_entry_size) / 8);
            if (offset + cm_bytes > data.len) return TgaError.InvalidData;
            if (cm_bytes > 0) {
                self.color_map = try self.allocator.dupe(u8, data[offset .. offset + cm_bytes]);
            }
            offset += cm_bytes;
        }
        errdefer {
            if (self.color_map.len > 0) {
                self.allocator.free(self.color_map);
                self.color_map = &.{};
            }
        }

        // Pixel data
        const w: usize = self.header.width;
        const h: usize = self.header.height;
        const bpp: usize = self.header.bytesPerPixel();
        const pixel_count = w * h;
        const pixel_bytes = pixel_count * bpp;

        if (pixel_bytes == 0) return;

        if (self.header.isRle()) {
            self.pixels = try self.allocator.alloc(u8, pixel_bytes);
            try decodeRle(data[offset..], self.header.bits_per_pixel, pixel_count, self.pixels);
        } else {
            if (offset + pixel_bytes > data.len) return TgaError.InvalidData;
            self.pixels = try self.allocator.dupe(u8, data[offset .. offset + pixel_bytes]);
        }
        errdefer {
            if (self.pixels.len > 0) {
                self.allocator.free(self.pixels);
                self.pixels = &.{};
            }
        }

        // Normalize to top-down.
        if (!self.header.isTopDown() and h > 1 and bpp > 0) {
            flipRows(self.pixels, w * bpp);
        }
    }

    // ── Serialize ─────────────────────────────────────────────────────────────

    pub fn serialize(self: *const TgaFile, allocator: Allocator) ![]u8 {
        const w: usize = self.header.width;
        const h: usize = self.header.height;
        const bpp: usize = self.header.bytesPerPixel();
        const stride = w * bpp;

        var out = std.ArrayList(u8).init(allocator);
        defer out.deinit();

        try writeHeader(&out, self.header);
        try out.appendSlice(self.id_data);
        try out.appendSlice(self.color_map);

        const need_flip = !self.header.isTopDown() and h > 1;

        if (self.header.isRle()) {
            if (need_flip) {
                const tmp = try allocator.dupe(u8, self.pixels);
                defer allocator.free(tmp);
                flipRows(tmp, stride);
                try encodeRle(tmp, self.header.bits_per_pixel, &out);
            } else {
                try encodeRle(self.pixels, self.header.bits_per_pixel, &out);
            }
        } else {
            if (need_flip) {
                const tmp = try allocator.dupe(u8, self.pixels);
                defer allocator.free(tmp);
                flipRows(tmp, stride);
                try out.appendSlice(tmp);
            } else {
                try out.appendSlice(self.pixels);
            }
        }

        return out.toOwnedSlice();
    }
};

// ── Header helpers ────────────────────────────────────────────────────────────

inline fn rd16(data: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, data[off..][0..2], .little);
}

fn writeHeader(out: *std.ArrayList(u8), h: TgaHeader) !void {
    var buf: [18]u8 = undefined;
    buf[0] = h.id_length;
    buf[1] = h.color_map_type;
    buf[2] = @intFromEnum(h.image_type);
    std.mem.writeInt(u16, buf[3..5], h.color_map_origin, .little);
    std.mem.writeInt(u16, buf[5..7], h.color_map_length, .little);
    buf[7] = h.color_map_entry_size;
    std.mem.writeInt(u16, buf[8..10], @as(u16, @bitCast(h.x_origin)), .little);
    std.mem.writeInt(u16, buf[10..12], @as(u16, @bitCast(h.y_origin)), .little);
    std.mem.writeInt(u16, buf[12..14], h.width, .little);
    std.mem.writeInt(u16, buf[14..16], h.height, .little);
    buf[16] = h.bits_per_pixel;
    buf[17] = h.image_descriptor;
    try out.appendSlice(&buf);
}

// ── Row-flip helper ───────────────────────────────────────────────────────────

fn flipRows(pixels: []u8, stride: usize) void {
    if (stride == 0 or pixels.len < stride * 2) return;
    const rows = pixels.len / stride;
    var top: usize = 0;
    var bot: usize = rows - 1;
    while (top < bot) : ({
        top += 1;
        bot -= 1;
    }) {
        const a = pixels[top * stride ..][0..stride];
        const b = pixels[bot * stride ..][0..stride];
        for (a, b) |*pa, *pb| {
            const tmp = pa.*;
            pa.* = pb.*;
            pb.* = tmp;
        }
    }
}

// ── RLE decode ────────────────────────────────────────────────────────────────

fn decodeRle(data: []const u8, bits_per_pixel: u8, pixel_count: usize, out: []u8) TgaError!void {
    const bpp: usize = bits_per_pixel / 8;
    var src: usize = 0;
    var written: usize = 0;

    while (written < pixel_count) {
        if (src >= data.len) return TgaError.InvalidData;
        const hdr = data[src];
        src += 1;
        const count: usize = (hdr & 0x7F) + 1;

        if (written + count > pixel_count) return TgaError.InvalidData;

        if (hdr & 0x80 != 0) {
            // Run packet.
            if (src + bpp > data.len) return TgaError.InvalidData;
            const pixel = data[src .. src + bpp];
            src += bpp;
            for (0..count) |_| {
                @memcpy(out[written * bpp ..][0..bpp], pixel);
                written += 1;
            }
        } else {
            // Raw packet.
            const bytes = count * bpp;
            if (src + bytes > data.len) return TgaError.InvalidData;
            @memcpy(out[written * bpp ..][0..bytes], data[src .. src + bytes]);
            src += bytes;
            written += count;
        }
    }
}

// ── RLE encode ────────────────────────────────────────────────────────────────

fn encodeRle(pixels: []const u8, bits_per_pixel: u8, out: *std.ArrayList(u8)) !void {
    const bpp: usize = bits_per_pixel / 8;
    if (bpp == 0 or pixels.len == 0) return;
    const pixel_count = pixels.len / bpp;

    var i: usize = 0;
    while (i < pixel_count) {
        // Count run of identical pixels.
        var run: usize = 1;
        while (run < 128 and i + run < pixel_count) {
            if (!std.mem.eql(u8, pixels[(i + run - 1) * bpp ..][0..bpp], pixels[(i + run) * bpp ..][0..bpp])) break;
            run += 1;
        }

        if (run > 1) {
            try out.append(@as(u8, 0x80) | @as(u8, @intCast(run - 1)));
            try out.appendSlice(pixels[i * bpp ..][0..bpp]);
            i += run;
        } else {
            // Count raw pixels until a run ≥2 begins.
            var raw: usize = 1;
            while (raw < 128 and i + raw < pixel_count) {
                if (i + raw + 1 < pixel_count and
                    std.mem.eql(u8, pixels[(i + raw) * bpp ..][0..bpp], pixels[(i + raw + 1) * bpp ..][0..bpp])) break;
                raw += 1;
            }
            try out.append(@as(u8, @intCast(raw - 1)));
            try out.appendSlice(pixels[i * bpp ..][0 .. raw * bpp]);
            i += raw;
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "TGA parse: minimal uncompressed 24-bit 2x2" {
    const alloc = std.testing.allocator;

    var buf: [30]u8 = undefined;
    @memset(&buf, 0);
    buf[2] = 2; // true_color
    buf[12] = 2; // width = 2
    buf[14] = 2; // height = 2
    buf[16] = 24;
    buf[17] = 0x20; // top-down
    const pix = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 128, 128, 128 };
    @memcpy(buf[18..], &pix);

    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try tga.parse(&buf);

    try std.testing.expectEqual(@as(u16, 2), tga.header.width);
    try std.testing.expectEqual(@as(u16, 2), tga.header.height);
    try std.testing.expectEqual(@as(u8, 24), tga.header.bits_per_pixel);
    try std.testing.expectEqual(ImageType.true_color, tga.header.image_type);
    try std.testing.expectEqualSlices(u8, &pix, tga.pixels);
}

test "TGA round-trip serialize -> parse" {
    const alloc = std.testing.allocator;

    var orig = TgaFile.init(alloc);
    defer orig.deinit();
    orig.header = .{
        .image_type = .true_color,
        .width = 2,
        .height = 2,
        .bits_per_pixel = 24,
        .image_descriptor = 0x20,
    };
    orig.pixels = try alloc.dupe(u8, &[_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 });

    const bytes = try orig.serialize(alloc);
    defer alloc.free(bytes);

    var tga2 = TgaFile.init(alloc);
    defer tga2.deinit();
    try tga2.parse(bytes);

    try std.testing.expectEqual(orig.header.width, tga2.header.width);
    try std.testing.expectEqual(orig.header.height, tga2.header.height);
    try std.testing.expectEqual(orig.header.bits_per_pixel, tga2.header.bits_per_pixel);
    try std.testing.expectEqualSlices(u8, orig.pixels, tga2.pixels);
}

test "TGA bottom-up normalization" {
    const alloc = std.testing.allocator;

    var buf: [30]u8 = undefined;
    @memset(&buf, 0);
    buf[2] = 2;
    buf[12] = 2;
    buf[14] = 2;
    buf[16] = 24;
    buf[17] = 0x00; // bottom-up
    // In file: row0=blue, row1=red  → after flip: row0=red, row1=blue
    const pix = [_]u8{ 255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255 };
    @memcpy(buf[18..], &pix);

    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try tga.parse(&buf);

    // Row0 was last in file (blue), becomes top after flip.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 0, 0, 255 }, tga.pixels[0..6]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255, 0, 0 }, tga.pixels[6..12]);
}

test "TGA RLE decode: run packet" {
    const alloc = std.testing.allocator;

    var buf: [22]u8 = undefined;
    @memset(&buf, 0);
    buf[2] = 10; // true_color_rle
    buf[12] = 2;
    buf[14] = 1;
    buf[16] = 24;
    buf[17] = 0x20;
    buf[18] = 0x81; // run, count-1=1 → repeat 2 times
    buf[19] = 1;
    buf[20] = 2;
    buf[21] = 3;

    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try tga.parse(&buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 1, 2, 3 }, tga.pixels);
}

test "TGA RLE decode: raw packet" {
    const alloc = std.testing.allocator;

    var buf: [25]u8 = undefined;
    @memset(&buf, 0);
    buf[2] = 10;
    buf[12] = 2;
    buf[14] = 1;
    buf[16] = 24;
    buf[17] = 0x20;
    buf[18] = 0x01; // raw, count-1=1 → 2 pixels
    buf[19] = 10;
    buf[20] = 20;
    buf[21] = 30;
    buf[22] = 40;
    buf[23] = 50;
    buf[24] = 60;

    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try tga.parse(&buf);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 40, 50, 60 }, tga.pixels);
}

test "TGA RLE round-trip" {
    const alloc = std.testing.allocator;

    const src_pixels = [_]u8{
        255, 0, 0, 255, 0, 0, // run of 2 identical red pixels
        0, 255, 0, 0, 0, 255, // 2 different pixels → raw
    };

    var orig = TgaFile.init(alloc);
    defer orig.deinit();
    orig.header = .{
        .image_type = .true_color_rle,
        .width = 2,
        .height = 2,
        .bits_per_pixel = 24,
        .image_descriptor = 0x20,
    };
    orig.pixels = try alloc.dupe(u8, &src_pixels);

    const bytes = try orig.serialize(alloc);
    defer alloc.free(bytes);

    var tga2 = TgaFile.init(alloc);
    defer tga2.deinit();
    try tga2.parse(bytes);

    try std.testing.expectEqualSlices(u8, &src_pixels, tga2.pixels);
}

test "TGA color-mapped parse" {
    const alloc = std.testing.allocator;

    const cm = [_]u8{ 255, 0, 0, 0, 255, 0 };
    const px = [_]u8{ 0, 1 };
    const total_size = 18 + cm.len + px.len;

    var buf: [total_size]u8 = undefined;
    @memset(&buf, 0);
    buf[1] = 1; // color map present
    buf[2] = 1; // color_mapped
    buf[5] = 2; // color_map_length = 2
    buf[7] = 24; // color_map_entry_size
    buf[12] = 2; // width
    buf[14] = 1; // height
    buf[16] = 8; // 8 bpp
    buf[17] = 0x20;
    @memcpy(buf[18..][0..cm.len], &cm);
    @memcpy(buf[18 + cm.len ..][0..px.len], &px);

    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try tga.parse(&buf);

    try std.testing.expectEqualSlices(u8, &cm, tga.color_map);
    try std.testing.expectEqualSlices(u8, &px, tga.pixels);
}

test "TGA 32-bit BGRA" {
    const alloc = std.testing.allocator;

    var buf: [26]u8 = undefined;
    @memset(&buf, 0);
    buf[2] = 2;
    buf[12] = 1;
    buf[14] = 2;
    buf[16] = 32;
    buf[17] = 0x20;
    const pix = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 128 };
    @memcpy(buf[18..], &pix);

    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try tga.parse(&buf);

    try std.testing.expectEqual(@as(u8, 4), tga.header.bytesPerPixel());
    try std.testing.expectEqualSlices(u8, &pix, tga.pixels);
}

test "TGA invalid header" {
    const alloc = std.testing.allocator;
    var tga = TgaFile.init(alloc);
    defer tga.deinit();
    try std.testing.expectError(TgaError.InvalidHeader, tga.parse(&[_]u8{0} ** 10));
}
