const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Errors ────────────────────────────────────────────────────────────────────

pub const WokError = error{ InvalidHeader, InvalidData, OutOfBounds };

// ── Magic ─────────────────────────────────────────────────────────────────────

/// Canonical file-type magic per the KOTOR WOK spec.
pub const MAGIC_TYPE: *const [4]u8 = "BWM ";
/// Canonical file-version magic per the KOTOR WOK spec.
pub const MAGIC_VERSION: *const [4]u8 = "V1.0";
/// Legacy lowercase magic accepted on parse for backwards compatibility
/// with older fixtures produced by this library before the spec-fix.
const LEGACY_MAGIC: *const [8]u8 = "bwm v1.0";

// ── Enums ─────────────────────────────────────────────────────────────────────

pub const MeshType = enum(u32) {
    placeable_door = 0,
    area = 1,
    _,
};

pub const SurfaceMaterial = enum(u32) {
    invalid = 0,
    dirt = 1,
    obscuring = 2,
    grass = 3,
    stone = 4,
    wood = 5,
    water = 6,
    nonwalkable = 7,
    transparent = 8,
    carpet = 9,
    metal = 10,
    puddles = 11,
    swamp = 12,
    mud = 13,
    leaves = 14,
    lava = 15,
    bottomless = 16,
    deep_water = 17,
    door = 18,
    snow = 19,
    sand = 20,
    _,
};

// ── Supporting structs ────────────────────────────────────────────────────────

pub const WokHeader = struct {
    mesh_type: MeshType = .area,
    /// Spec offset 12, 48 opaque bytes. Preserved verbatim for byte-
    /// identical round-trip; the engine does not read these.
    reserved: [48]u8 = [_]u8{0} ** 48,
    /// Spec offset 60. The wiki notes "doesn't actually do anything?".
    position: [3]f32 = [_]f32{0} ** 3,
    vertex_count: u32 = 0,
    vertex_offset: u32 = 0,
    face_count: u32 = 0,
    face_offset: u32 = 0,
    walk_type_offset: u32 = 0,
    normal_offset: u32 = 0,
    plane_dist_offset: u32 = 0,
    aabb_count: u32 = 0,
    aabb_offset: u32 = 0,
    /// Opaque u32 at spec offset 108. Preserved verbatim.
    unknown_108: u32 = 0,
    adj_count: u32 = 0,
    adj_offset: u32 = 0,
    edge_count: u32 = 0,
    edge_offset: u32 = 0,
    perimeter_count: u32 = 0,
    perimeter_offset: u32 = 0,
};

pub const Face = struct {
    vert_indices: [3]u32,
    material: SurfaceMaterial,
    normal: [3]f32,
    plane_dist: f32,
};

pub const Adjacency = struct { edges: [3]i32 };

pub const EdgeLoop = struct {
    edge_index: i32,
    /// Index into the module's layout file. -1 if this edge does not
    /// transition to another walkmesh.
    transition: i32,
};

pub const Perimeter = struct {
    /// Cumulative ending edge index of one perimeter loop in the
    /// edges array (NOT a count of edges).
    final_edge_index: i32,
};

/// AABB-node split-plane bitmask (spec offset 32).
/// 0 indicates a leaf node (set when `face_index != -1`).
pub const AabbPlaneFlags = packed struct(u32) {
    pos_x: bool = false, // 0x01
    pos_y: bool = false, // 0x02
    pos_z: bool = false, // 0x04
    _padding: u29 = 0,

    pub fn fromU32(v: u32) AabbPlaneFlags {
        return @bitCast(v);
    }
    pub fn toU32(self: AabbPlaneFlags) u32 {
        return @bitCast(self);
    }
};

pub const AabbNode = struct {
    min: [3]f32,
    max: [3]f32,
    /// -1 for internal nodes, non-negative index into the face array for leaves.
    face_index: i32,
    /// Wiki note: "Always = 4". Preserved verbatim.
    unknown_28: i32 = 4,
    /// Split-plane bitmask. 0 when `face_index != -1`.
    most_significant_plane: AabbPlaneFlags = .{},
    left_child: i32,
    right_child: i32,
};

// ── WokFile ───────────────────────────────────────────────────────────────────

pub const WokFile = struct {
    allocator: Allocator,
    header: WokHeader = .{},
    vertices: [][3]f32 = &.{},
    faces: []Face = &.{},
    adjacencies: []Adjacency = &.{},
    edge_loops: []EdgeLoop = &.{},
    perimeters: []Perimeter = &.{},
    aabb_nodes: []AabbNode = &.{},

    pub fn init(allocator: Allocator) WokFile {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WokFile) void {
        if (self.vertices.len > 0) self.allocator.free(self.vertices);
        if (self.faces.len > 0) self.allocator.free(self.faces);
        if (self.adjacencies.len > 0) self.allocator.free(self.adjacencies);
        if (self.edge_loops.len > 0) self.allocator.free(self.edge_loops);
        if (self.perimeters.len > 0) self.allocator.free(self.perimeters);
        if (self.aabb_nodes.len > 0) self.allocator.free(self.aabb_nodes);
        self.vertices = &.{};
        self.faces = &.{};
        self.adjacencies = &.{};
        self.edge_loops = &.{};
        self.perimeters = &.{};
        self.aabb_nodes = &.{};
    }

    // ── Parse ─────────────────────────────────────────────────────────────────

    pub fn parse(self: *WokFile, data: []const u8) !void {
        if (data.len < 136) return WokError.InvalidHeader;
        if (!isValidMagic(data[0..8])) return WokError.InvalidHeader;

        var reserved: [48]u8 = undefined;
        @memcpy(&reserved, data[12..60]);

        self.header = .{
            .mesh_type = @enumFromInt(rd32(data, 8)),
            .reserved = reserved,
            .position = .{ rdf32(data, 60), rdf32(data, 64), rdf32(data, 68) },
            .vertex_count = rd32(data, 72),
            .vertex_offset = rd32(data, 76),
            .face_count = rd32(data, 80),
            .face_offset = rd32(data, 84),
            .walk_type_offset = rd32(data, 88),
            .normal_offset = rd32(data, 92),
            .plane_dist_offset = rd32(data, 96),
            .aabb_count = rd32(data, 100),
            .aabb_offset = rd32(data, 104),
            .unknown_108 = rd32(data, 108),
            .adj_count = rd32(data, 112),
            .adj_offset = rd32(data, 116),
            .edge_count = rd32(data, 120),
            .edge_offset = rd32(data, 124),
            .perimeter_count = rd32(data, 128),
            .perimeter_offset = rd32(data, 132),
        };

        const h = &self.header;

        // Vertices (12 bytes each).
        try checkBounds(data.len, h.vertex_offset, h.vertex_count * 12);
        if (h.vertex_count > 0) {
            self.vertices = try self.allocator.alloc([3]f32, h.vertex_count);
            errdefer {
                self.allocator.free(self.vertices);
                self.vertices = &.{};
            }
            for (self.vertices, 0..) |*v, i| {
                const b: usize = h.vertex_offset + i * 12;
                v.* = .{ rdf32(data, b), rdf32(data, b + 4), rdf32(data, b + 8) };
            }
        }

        // Faces: four separate arrays in the file combined into []Face.
        if (h.face_count > 0) {
            try checkBounds(data.len, h.face_offset, h.face_count * 12);
            try checkBounds(data.len, h.walk_type_offset, h.face_count * 4);
            try checkBounds(data.len, h.normal_offset, h.face_count * 12);
            try checkBounds(data.len, h.plane_dist_offset, h.face_count * 4);
            self.faces = try self.allocator.alloc(Face, h.face_count);
            errdefer {
                self.allocator.free(self.faces);
                self.faces = &.{};
            }
            for (self.faces, 0..) |*f, i| {
                const vi: usize = h.face_offset + i * 12;
                const mt: usize = h.walk_type_offset + i * 4;
                const nm: usize = h.normal_offset + i * 12;
                const pd: usize = h.plane_dist_offset + i * 4;
                f.* = .{
                    .vert_indices = .{ rd32(data, vi), rd32(data, vi + 4), rd32(data, vi + 8) },
                    .material = @enumFromInt(rd32(data, mt)),
                    .normal = .{ rdf32(data, nm), rdf32(data, nm + 4), rdf32(data, nm + 8) },
                    .plane_dist = rdf32(data, pd),
                };
            }
        }

        // Adjacencies (12 bytes = 3×i32 each).
        if (h.adj_count > 0) {
            try checkBounds(data.len, h.adj_offset, h.adj_count * 12);
            self.adjacencies = try self.allocator.alloc(Adjacency, h.adj_count);
            errdefer {
                self.allocator.free(self.adjacencies);
                self.adjacencies = &.{};
            }
            for (self.adjacencies, 0..) |*a, i| {
                const b: usize = h.adj_offset + i * 12;
                a.* = .{ .edges = .{ rdi32(data, b), rdi32(data, b + 4), rdi32(data, b + 8) } };
            }
        }

        // Edge loops (8 bytes each).
        if (h.edge_count > 0) {
            try checkBounds(data.len, h.edge_offset, h.edge_count * 8);
            self.edge_loops = try self.allocator.alloc(EdgeLoop, h.edge_count);
            errdefer {
                self.allocator.free(self.edge_loops);
                self.edge_loops = &.{};
            }
            for (self.edge_loops, 0..) |*e, i| {
                const b: usize = h.edge_offset + i * 8;
                e.* = .{ .edge_index = rdi32(data, b), .transition = rdi32(data, b + 4) };
            }
        }

        // Perimeters (4 bytes each).
        if (h.perimeter_count > 0) {
            try checkBounds(data.len, h.perimeter_offset, h.perimeter_count * 4);
            self.perimeters = try self.allocator.alloc(Perimeter, h.perimeter_count);
            errdefer {
                self.allocator.free(self.perimeters);
                self.perimeters = &.{};
            }
            for (self.perimeters, 0..) |*p, i| {
                p.* = .{ .final_edge_index = rdi32(data, h.perimeter_offset + i * 4) };
            }
        }

        // AABB nodes (44 bytes each).
        if (h.aabb_count > 0) {
            try checkBounds(data.len, h.aabb_offset, h.aabb_count * 44);
            self.aabb_nodes = try self.allocator.alloc(AabbNode, h.aabb_count);
            errdefer {
                self.allocator.free(self.aabb_nodes);
                self.aabb_nodes = &.{};
            }
            for (self.aabb_nodes, 0..) |*n, i| {
                const b: usize = h.aabb_offset + i * 44;
                n.* = .{
                    .min = .{ rdf32(data, b), rdf32(data, b + 4), rdf32(data, b + 8) },
                    .max = .{ rdf32(data, b + 12), rdf32(data, b + 16), rdf32(data, b + 20) },
                    .face_index = rdi32(data, b + 24),
                    .unknown_28 = rdi32(data, b + 28),
                    .most_significant_plane = AabbPlaneFlags.fromU32(rd32(data, b + 32)),
                    .left_child = rdi32(data, b + 36),
                    .right_child = rdi32(data, b + 40),
                };
            }
        }
    }

    // ── Serialize ─────────────────────────────────────────────────────────────

    pub fn serialize(self: *const WokFile, allocator: Allocator) ![]u8 {
        const vc = self.vertices.len;
        const fc = self.faces.len;

        const vert_sz = vc * 12;
        const face_sz = fc * 12;
        const wtype_sz = fc * 4;
        const norm_sz = fc * 12;
        const pdist_sz = fc * 4;
        const adj_sz = self.adjacencies.len * 12;
        const edge_sz = self.edge_loops.len * 8;
        const peri_sz = self.perimeters.len * 4;
        const aabb_sz = self.aabb_nodes.len * 44;

        const total = 136 + vert_sz + face_sz + wtype_sz + norm_sz +
            pdist_sz + adj_sz + edge_sz + peri_sz + aabb_sz;
        const buf = try allocator.alloc(u8, total);

        // Header.
        @memcpy(buf[0..4], MAGIC_TYPE);
        @memcpy(buf[4..8], MAGIC_VERSION);
        wr32(buf, 8, @intFromEnum(self.header.mesh_type));
        @memcpy(buf[12..60], &self.header.reserved);
        for (self.header.position, 0..) |v, i| wrf32(buf, 60 + i * 4, v);

        // Compute and write offsets.
        var off: usize = 136;
        const v_off: usize = off;
        off += vert_sz;
        const f_off: usize = off;
        off += face_sz;
        const wt_off: usize = off;
        off += wtype_sz;
        const nm_off: usize = off;
        off += norm_sz;
        const pd_off: usize = off;
        off += pdist_sz;
        const aj_off: usize = off;
        off += adj_sz;
        const ed_off: usize = off;
        off += edge_sz;
        const pe_off: usize = off;
        off += peri_sz;
        const ab_off: usize = off;

        wr32(buf, 72, @intCast(vc));
        wr32(buf, 76, @intCast(v_off));
        wr32(buf, 80, @intCast(fc));
        wr32(buf, 84, @intCast(f_off));
        wr32(buf, 88, @intCast(wt_off));
        wr32(buf, 92, @intCast(nm_off));
        wr32(buf, 96, @intCast(pd_off));
        wr32(buf, 100, @intCast(self.aabb_nodes.len));
        wr32(buf, 104, @intCast(ab_off));
        wr32(buf, 108, self.header.unknown_108);
        wr32(buf, 112, @intCast(self.adjacencies.len));
        wr32(buf, 116, @intCast(aj_off));
        wr32(buf, 120, @intCast(self.edge_loops.len));
        wr32(buf, 124, @intCast(ed_off));
        wr32(buf, 128, @intCast(self.perimeters.len));
        wr32(buf, 132, @intCast(pe_off));

        // Vertices.
        for (self.vertices, 0..) |v, i| {
            const b = v_off + i * 12;
            wrf32(buf, b, v[0]);
            wrf32(buf, b + 4, v[1]);
            wrf32(buf, b + 8, v[2]);
        }

        // Faces (4 interleaved sections written separately).
        for (self.faces, 0..) |f, i| {
            const vi = f_off + i * 12;
            const mt = wt_off + i * 4;
            const nm = nm_off + i * 12;
            const pd = pd_off + i * 4;
            wr32(buf, vi, f.vert_indices[0]);
            wr32(buf, vi + 4, f.vert_indices[1]);
            wr32(buf, vi + 8, f.vert_indices[2]);
            wr32(buf, mt, @intFromEnum(f.material));
            wrf32(buf, nm, f.normal[0]);
            wrf32(buf, nm + 4, f.normal[1]);
            wrf32(buf, nm + 8, f.normal[2]);
            wrf32(buf, pd, f.plane_dist);
        }

        // Adjacencies.
        for (self.adjacencies, 0..) |a, i| {
            const b = aj_off + i * 12;
            wri32(buf, b, a.edges[0]);
            wri32(buf, b + 4, a.edges[1]);
            wri32(buf, b + 8, a.edges[2]);
        }

        // Edge loops.
        for (self.edge_loops, 0..) |e, i| {
            const b = ed_off + i * 8;
            wri32(buf, b, e.edge_index);
            wri32(buf, b + 4, e.transition);
        }

        // Perimeters.
        for (self.perimeters, 0..) |p, i| {
            wri32(buf, pe_off + i * 4, p.final_edge_index);
        }

        // AABB nodes.
        for (self.aabb_nodes, 0..) |n, i| {
            const b = ab_off + i * 44;
            wrf32(buf, b, n.min[0]);
            wrf32(buf, b + 4, n.min[1]);
            wrf32(buf, b + 8, n.min[2]);
            wrf32(buf, b + 12, n.max[0]);
            wrf32(buf, b + 16, n.max[1]);
            wrf32(buf, b + 20, n.max[2]);
            wri32(buf, b + 24, n.face_index);
            wri32(buf, b + 28, n.unknown_28);
            wr32(buf, b + 32, n.most_significant_plane.toU32());
            wri32(buf, b + 36, n.left_child);
            wri32(buf, b + 40, n.right_child);
        }

        return buf;
    }

    /// Returns true for materials that are considered walkable.
    pub fn isWalkable(material: SurfaceMaterial) bool {
        return switch (material) {
            .invalid, .nonwalkable, .lava, .bottomless => false,
            else => true,
        };
    }
};

// ── I/O helpers ───────────────────────────────────────────────────────────────

inline fn rd32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

inline fn rdi32(data: []const u8, off: usize) i32 {
    return @bitCast(rd32(data, off));
}

inline fn rdf32(data: []const u8, off: usize) f32 {
    return @bitCast(rd32(data, off));
}

inline fn wr32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

inline fn wri32(buf: []u8, off: usize, v: i32) void {
    wr32(buf, off, @bitCast(v));
}

inline fn wrf32(buf: []u8, off: usize, v: f32) void {
    wr32(buf, off, @bitCast(v));
}

fn isValidMagic(s: *const [8]u8) bool {
    // Canonical: "BWM " + "V1.0".
    if (std.mem.eql(u8, s[0..4], MAGIC_TYPE) and std.mem.eql(u8, s[4..8], MAGIC_VERSION)) return true;
    // Legacy lowercase fixture support.
    if (std.mem.eql(u8, s, LEGACY_MAGIC)) return true;
    return false;
}

fn checkBounds(data_len: usize, offset: u32, size: u32) WokError!void {
    const end: u64 = @as(u64, offset) + @as(u64, size);
    if (end > @as(u64, data_len)) return WokError.InvalidData;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn makeMinHeader(face_count: u32, vertex_count: u32) [136]u8 {
    var buf = [_]u8{0} ** 136;
    @memcpy(buf[0..8], "bwm v1.0");
    std.mem.writeInt(u32, buf[8..12], 1, .little); // area
    const v_off: u32 = 136;
    const f_off: u32 = v_off + vertex_count * 12;
    const wt_off: u32 = f_off + face_count * 12;
    const nm_off: u32 = wt_off + face_count * 4;
    const pd_off: u32 = nm_off + face_count * 12;
    std.mem.writeInt(u32, buf[72..76], vertex_count, .little);
    std.mem.writeInt(u32, buf[76..80], v_off, .little);
    std.mem.writeInt(u32, buf[80..84], face_count, .little);
    std.mem.writeInt(u32, buf[84..88], f_off, .little);
    std.mem.writeInt(u32, buf[88..92], wt_off, .little);
    std.mem.writeInt(u32, buf[92..96], nm_off, .little);
    std.mem.writeInt(u32, buf[96..100], pd_off, .little);
    return buf;
}

fn al32(buf: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(&b);
}

fn ali32(buf: *std.ArrayList(u8), v: i32) !void {
    try al32(buf, @bitCast(v));
}
fn alf32(buf: *std.ArrayList(u8), v: f32) !void {
    try al32(buf, @bitCast(v));
}

test "WOK header parse" {
    const alloc = std.testing.allocator;
    const hdr = makeMinHeader(2, 3);
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(&hdr);
    // Data padding: 3 verts + 2 faces × 4 sections.
    try buf.appendNTimes(0, 3 * 12 + 2 * 12 + 2 * 4 + 2 * 12 + 2 * 4);

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try wok.parse(buf.items);

    try std.testing.expectEqual(MeshType.area, wok.header.mesh_type);
    try std.testing.expectEqual(@as(u32, 3), wok.header.vertex_count);
    try std.testing.expectEqual(@as(u32, 2), wok.header.face_count);
}

test "WOK vertices parse" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(&makeMinHeader(0, 2));
    try alf32(&buf, 1.0);
    try alf32(&buf, 2.0);
    try alf32(&buf, 3.0);
    try alf32(&buf, 4.0);
    try alf32(&buf, 5.0);
    try alf32(&buf, 6.0);

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try wok.parse(buf.items);

    try std.testing.expectEqual(@as(f32, 1.0), wok.vertices[0][0]);
    try std.testing.expectEqual(@as(f32, 3.0), wok.vertices[0][2]);
    try std.testing.expectEqual(@as(f32, 4.0), wok.vertices[1][0]);
}

test "WOK faces parse" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(&makeMinHeader(1, 3));
    try buf.appendNTimes(0, 36); // 3 verts
    try al32(&buf, 0);
    try al32(&buf, 1);
    try al32(&buf, 2); // vert indices
    try al32(&buf, 3); // material=grass
    try alf32(&buf, 0.0);
    try alf32(&buf, 0.0);
    try alf32(&buf, 1.0); // normal
    try alf32(&buf, -5.0); // plane_dist

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try wok.parse(buf.items);

    const f = wok.faces[0];
    try std.testing.expectEqual(@as(u32, 0), f.vert_indices[0]);
    try std.testing.expectEqual(@as(u32, 2), f.vert_indices[2]);
    try std.testing.expectEqual(SurfaceMaterial.grass, f.material);
    try std.testing.expectEqual(@as(f32, 1.0), f.normal[2]);
    try std.testing.expectEqual(@as(f32, -5.0), f.plane_dist);
}

test "WOK adjacencies parse" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var hdr = makeMinHeader(1, 3);
    const adj_off: u32 = 136 + 3 * 12 + 1 * 12 + 1 * 4 + 1 * 12 + 1 * 4;
    std.mem.writeInt(u32, hdr[112..116], 1, .little);
    std.mem.writeInt(u32, hdr[116..120], adj_off, .little);
    try buf.appendSlice(&hdr);
    try buf.appendNTimes(0, 3 * 12 + 1 * 12 + 1 * 4 + 1 * 12 + 1 * 4); // verts + face sections
    try ali32(&buf, 0);
    try ali32(&buf, 5);
    try ali32(&buf, -1);

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try wok.parse(buf.items);

    try std.testing.expectEqual(@as(i32, 0), wok.adjacencies[0].edges[0]);
    try std.testing.expectEqual(@as(i32, 5), wok.adjacencies[0].edges[1]);
    try std.testing.expectEqual(@as(i32, -1), wok.adjacencies[0].edges[2]);
}

test "WOK AABB nodes parse" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var hdr = makeMinHeader(0, 0);
    const ab_off: u32 = 136;
    std.mem.writeInt(u32, hdr[100..104], 1, .little);
    std.mem.writeInt(u32, hdr[104..108], ab_off, .little);
    try buf.appendSlice(&hdr);
    try alf32(&buf, -1.0);
    try alf32(&buf, -2.0);
    try alf32(&buf, -3.0);
    try alf32(&buf, 1.0);
    try alf32(&buf, 2.0);
    try alf32(&buf, 3.0);
    try ali32(&buf, 7);
    try ali32(&buf, 4);
    try ali32(&buf, 0);
    try ali32(&buf, -1);
    try ali32(&buf, -1);

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try wok.parse(buf.items);

    const n = wok.aabb_nodes[0];
    try std.testing.expectEqual(@as(f32, -1.0), n.min[0]);
    try std.testing.expectEqual(@as(f32, 3.0), n.max[2]);
    try std.testing.expectEqual(@as(i32, 7), n.face_index);
    try std.testing.expectEqual(@as(i32, -1), n.right_child);
}

test "WOK round-trip serialize -> parse" {
    const alloc = std.testing.allocator;

    var orig = WokFile.init(alloc);
    defer orig.deinit();
    orig.header = .{ .mesh_type = .area, .position = .{ 1.0, 2.0, 0.0 } };
    orig.vertices = try alloc.alloc([3]f32, 2);
    orig.vertices[0] = .{ 0.0, 0.0, 0.0 };
    orig.vertices[1] = .{ 1.0, 0.0, 0.0 };
    orig.faces = try alloc.alloc(Face, 1);
    orig.faces[0] = .{ .vert_indices = .{ 0, 1, 0 }, .material = .grass, .normal = .{ 0, 0, 1 }, .plane_dist = 0.0 };
    orig.adjacencies = try alloc.alloc(Adjacency, 1);
    orig.adjacencies[0] = .{ .edges = .{ -1, -1, -1 } };

    const bytes = try orig.serialize(alloc);
    defer alloc.free(bytes);

    var wok2 = WokFile.init(alloc);
    defer wok2.deinit();
    try wok2.parse(bytes);

    try std.testing.expectEqual(orig.header.mesh_type, wok2.header.mesh_type);
    try std.testing.expectEqual(orig.header.position[0], wok2.header.position[0]);
    try std.testing.expectEqual(@as(usize, 2), wok2.vertices.len);
    try std.testing.expectEqual(orig.vertices[1][0], wok2.vertices[1][0]);
    try std.testing.expectEqual(orig.faces[0].material, wok2.faces[0].material);
    try std.testing.expectEqual(orig.adjacencies[0].edges[0], wok2.adjacencies[0].edges[0]);
}

test "WOK isWalkable" {
    try std.testing.expect(!WokFile.isWalkable(.nonwalkable));
    try std.testing.expect(!WokFile.isWalkable(.invalid));
    try std.testing.expect(!WokFile.isWalkable(.lava));
    try std.testing.expect(!WokFile.isWalkable(.bottomless));
    try std.testing.expect(WokFile.isWalkable(.grass));
    try std.testing.expect(WokFile.isWalkable(.stone));
    try std.testing.expect(WokFile.isWalkable(.door));
}

test "WOK edge loops and perimeters" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var hdr = makeMinHeader(0, 0);
    const edge_off: u32 = 136;
    const peri_off: u32 = edge_off + 2 * 8;
    std.mem.writeInt(u32, hdr[120..124], 2, .little);
    std.mem.writeInt(u32, hdr[124..128], edge_off, .little);
    std.mem.writeInt(u32, hdr[128..132], 1, .little);
    std.mem.writeInt(u32, hdr[132..136], peri_off, .little);
    try buf.appendSlice(&hdr);
    try ali32(&buf, 3);
    try ali32(&buf, 0);
    try ali32(&buf, 6);
    try ali32(&buf, -1);
    try ali32(&buf, 4);

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try wok.parse(buf.items);

    try std.testing.expectEqual(@as(i32, 3), wok.edge_loops[0].edge_index);
    try std.testing.expectEqual(@as(i32, 0), wok.edge_loops[0].room);
    try std.testing.expectEqual(@as(i32, -1), wok.edge_loops[1].room);
    try std.testing.expectEqual(@as(i32, 4), wok.perimeters[0].edge_count);
}

test "WOK truncated data returns error" {
    const alloc = std.testing.allocator;
    // Header says 10 vertices but only 4 bytes of data after header.
    var hdr = makeMinHeader(0, 10);
    var buf: [140]u8 = undefined;
    @memcpy(buf[0..136], &hdr);
    @memset(buf[136..], 0);

    var wok = WokFile.init(alloc);
    defer wok.deinit();
    try std.testing.expectError(WokError.InvalidData, wok.parse(&buf));
}
