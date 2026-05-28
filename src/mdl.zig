//! Bioware Aurora Engine MDL (Model) file format reader and writer.
//!
//! MDL is a plain-text ASCII format produced by the Neverwinter Export
//! Scripts for 3DS Max.  It encodes a named model's complete node hierarchy
//! (geometry, lights, particle emitters, collision meshes) and zero or more
//! named animation sequences with per-node keyframe channels.
//!
//! Logical layout:
//!
//!   ```text
//!   File header lines     (newmodel, setsupermodel, classification, …)
//!   beginmodelgeom … endmodelgeom   (node tree)
//!   newanim … doneanim              (animation sections, repeated)
//!   donemodel
//!   ```
//!
//! Node types: dummy · trimesh · danglymesh · skin · emitter · light ·
//!             aabb · reference
//!
//! References: BioWare "Neverwinter Export" v1.1 guide.

const std = @import("std");

// ============================================================================
// Errors
// ============================================================================

pub const FormatError = error{
    /// Malformed keyword, missing token, or wrong token count.
    InvalidFormat,
    /// Node-type string not recognised.
    UnknownNodeType,
    /// Classification string not recognised.
    UnknownClassification,
};

// ============================================================================
// Enums
// ============================================================================

pub const Classification = enum {
    character,
    door,
    tile,
    item,
    effect,
    gui,
    tile_border,

    pub fn fromString(s: []const u8) ?Classification {
        if (eqlIc(s, "Character")) return .character;
        if (eqlIc(s, "Door")) return .door;
        if (eqlIc(s, "Tile")) return .tile;
        if (eqlIc(s, "Item")) return .item;
        if (eqlIc(s, "Effect")) return .effect;
        if (eqlIc(s, "Gui")) return .gui;
        if (eqlIc(s, "TileBorder")) return .tile_border;
        return null;
    }

    pub fn toString(self: Classification) []const u8 {
        return switch (self) {
            .character => "Character",
            .door => "Door",
            .tile => "Tile",
            .item => "Item",
            .effect => "Effect",
            .gui => "Gui",
            .tile_border => "TileBorder",
        };
    }
};

pub const NodeType = enum {
    dummy,
    trimesh,
    danglymesh,
    skin,
    emitter,
    light,
    aabb,
    reference,

    pub fn fromString(s: []const u8) ?NodeType {
        if (eqlIc(s, "dummy")) return .dummy;
        if (eqlIc(s, "trimesh")) return .trimesh;
        if (eqlIc(s, "danglymesh")) return .danglymesh;
        if (eqlIc(s, "skin")) return .skin;
        if (eqlIc(s, "emitter")) return .emitter;
        if (eqlIc(s, "light")) return .light;
        if (eqlIc(s, "aabb")) return .aabb;
        if (eqlIc(s, "reference")) return .reference;
        return null;
    }

    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .dummy => "dummy",
            .trimesh => "trimesh",
            .danglymesh => "danglymesh",
            .skin => "skin",
            .emitter => "emitter",
            .light => "light",
            .aabb => "aabb",
            .reference => "reference",
        };
    }
};

pub const FadingTileProp = enum(u8) {
    not_a_cap,
    fadeable,
    neighbour,
    base,

    pub fn fromString(s: []const u8) ?FadingTileProp {
        if (eqlIc(s, "Not a cap")) return .not_a_cap;
        if (eqlIc(s, "Fadeable")) return .fadeable;
        if (eqlIc(s, "Neighbour")) return .neighbour;
        if (eqlIc(s, "Base")) return .base;
        return null;
    }

    pub fn toString(self: FadingTileProp) []const u8 {
        return switch (self) {
            .not_a_cap => "Not a cap",
            .fadeable => "Fadeable",
            .neighbour => "Neighbour",
            .base => "Base",
        };
    }
};

pub const UpdateStyle = enum {
    fountain,
    explosion,
    single,
    lightning,

    pub fn fromString(s: []const u8) ?UpdateStyle {
        if (eqlIc(s, "Fountain")) return .fountain;
        if (eqlIc(s, "Explosion")) return .explosion;
        if (eqlIc(s, "Single")) return .single;
        if (eqlIc(s, "Lightning")) return .lightning;
        return null;
    }

    pub fn toString(self: UpdateStyle) []const u8 {
        return switch (self) {
            .fountain => "Fountain",
            .explosion => "Explosion",
            .single => "Single",
            .lightning => "Lightning",
        };
    }
};

pub const RenderStyle = enum {
    normal,
    linked,
    billboard_to_local_z,
    billboard_to_world_z,
    aligned_to_world_z,
    aligned_to_particle_dir,
    motion_blurred,

    pub fn fromString(s: []const u8) ?RenderStyle {
        if (eqlIc(s, "Normal")) return .normal;
        if (eqlIc(s, "Linked")) return .linked;
        if (eqlIc(s, "Billboard_to_LocalZ")) return .billboard_to_local_z;
        if (eqlIc(s, "Billboard_to_WorldZ")) return .billboard_to_world_z;
        if (eqlIc(s, "Aligned_to_WorldZ")) return .aligned_to_world_z;
        if (eqlIc(s, "Aligned_to_Particle_Dir")) return .aligned_to_particle_dir;
        if (eqlIc(s, "Motion_Blurred")) return .motion_blurred;
        return null;
    }

    pub fn toString(self: RenderStyle) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .linked => "Linked",
            .billboard_to_local_z => "Billboard_to_LocalZ",
            .billboard_to_world_z => "Billboard_to_WorldZ",
            .aligned_to_world_z => "Aligned_to_WorldZ",
            .aligned_to_particle_dir => "Aligned_to_Particle_Dir",
            .motion_blurred => "Motion_Blurred",
        };
    }
};

pub const BlendMode = enum {
    normal,
    punch_through,
    lighten,

    pub fn fromString(s: []const u8) ?BlendMode {
        if (eqlIc(s, "Normal")) return .normal;
        if (eqlIc(s, "Punch-Through")) return .punch_through;
        if (eqlIc(s, "Lighten")) return .lighten;
        return null;
    }

    pub fn toString(self: BlendMode) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .punch_through => "Punch-Through",
            .lighten => "Lighten",
        };
    }
};

// ============================================================================
// AuraPoly flags
// ============================================================================

pub const AuraPolyFlags = packed struct(u16) {
    render: bool = true,
    shadow: bool = true,
    beaming: bool = false,
    inherit_color: bool = false,
    rotate_texture: bool = false,
    _padding: u11 = 0,
};

// ============================================================================
// Geometry types
// ============================================================================

/// One triangular face: vertex indices, UV indices, smoothing group, material.
pub const Face = struct {
    verts: [3]u32,
    tverts: [3]u32,
    smooth_group: u32 = 1,
    mat_id: u32 = 0,
};

/// One bone influence on a vertex (up to 4 per vertex per Aurora spec).
pub const BoneWeight = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    weight: f32,

    pub fn setName(self: *BoneWeight, s: []const u8) void {
        @memset(&self.name, 0);
        const n = @min(s.len, 31);
        @memcpy(self.name[0..n], s[0..n]);
    }

    pub fn nameSlice(self: *const BoneWeight) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

/// Geometry arrays shared by trimesh / danglymesh / skin.
/// All slices are owned by `MdlFile.allocator`.
pub const MeshGeometry = struct {
    verts: [][3]f32,
    normals: [][3]f32,
    tverts: [][2]f32,
    faces: []Face,
    colors: ?[][4]f32 = null,
};

// ============================================================================
// Node structs
// ============================================================================

pub const NodeBase = struct {
    name: []u8,
    parent: []u8,
    position: [3]f32 = .{ 0, 0, 0 },
    orientation: [4]f32 = .{ 0, 0, 0, 1 },
    wirecolor: [3]f32 = .{ 1, 1, 1 },
};

pub const DanglyParams = struct {
    period: f32 = 1.0,
    tightness: f32 = 1.0,
    displacement: f32 = 0.025,
};

pub const TrimeshNode = struct {
    base: NodeBase,
    aura_poly: AuraPolyFlags = .{},
    fading_tile: FadingTileProp = .not_a_cap,
    alpha: f32 = 1.0,
    transparency_hint: u32 = 0,
    self_illum_color: [3]f32 = .{ 0, 0, 0 },
    scale_factor: f32 = 1.0,
    diffuse: [3]f32 = .{ 1, 1, 1 },
    ambient: [3]f32 = .{ 1, 1, 1 },
    bitmap: []u8,
    geometry: MeshGeometry,
};

pub const DanglyMeshNode = struct {
    mesh: TrimeshNode,
    dangly: DanglyParams = .{},
    constraints: []f32,
};

pub const SkinNode = struct {
    mesh: TrimeshNode,
    /// One slice per vertex; each inner slice holds up to 4 bone weights.
    bone_weights: [][]BoneWeight,
};

pub const LightNode = struct {
    base: NodeBase,
    color: [3]f32 = .{ 1, 1, 1 },
    radius: f32 = 5.0,
    multiplier: f32 = 1.0,
    is_dynamic: bool = false,
    affects_dynamic: bool = false,
    shadow: bool = false,
    fading: bool = true,
    priority: u8 = 3,
};

pub const EmitterNode = struct {
    base: NodeBase,
    birthrate: f32 = 0,
    life_exp: f32 = 1.0,
    size_start: f32 = 0,
    size_end: f32 = 0,
    color_start: [3]f32 = .{ 1, 1, 1 },
    color_end: [3]f32 = .{ 1, 1, 1 },
    alpha_start: f32 = 1.0,
    alpha_end: f32 = 0.0,
    velocity: f32 = 0,
    random_velocity: f32 = 0,
    acceleration: f32 = 0,
    spread: f32 = 0,
    fps: f32 = 0,
    render_order: u32 = 0,
    update_style: UpdateStyle = .fountain,
    render_style: RenderStyle = .normal,
    blend_mode: BlendMode = .normal,
    texture: []u8,
    x_size: f32 = 0,
    y_size: f32 = 0,
    bouncing: bool = false,
    detonate: bool = false,
    loop_single: bool = false,
    random_start_frame: bool = false,
};

// ============================================================================
// Node tagged union
// ============================================================================

pub const Node = union(NodeType) {
    dummy: NodeBase,
    trimesh: TrimeshNode,
    danglymesh: DanglyMeshNode,
    skin: SkinNode,
    emitter: EmitterNode,
    light: LightNode,
    aabb: NodeBase,
    reference: NodeBase,

    pub fn base(self: *const Node) *const NodeBase {
        return switch (self.*) {
            .dummy, .aabb, .reference => |*b| b,
            .trimesh => |*n| &n.base,
            .danglymesh => |*n| &n.mesh.base,
            .skin => |*n| &n.mesh.base,
            .emitter => |*n| &n.base,
            .light => |*n| &n.base,
        };
    }

    pub fn nodeName(self: *const Node) []const u8 {
        return self.base().name;
    }
};

// ============================================================================
// Animation types
// ============================================================================

pub const KeyframeValue = union(enum) {
    float: f32,
    vec3: [3]f32,
    quat: [4]f32,
};

pub const Keyframe = struct {
    time: f32,
    value: KeyframeValue,
};

pub const KeyChannel = struct {
    name: []u8,
    frames: []Keyframe,
};

pub const AnimNode = struct {
    node_type: NodeType,
    name: []u8,
    parent: []u8,
    channels: []KeyChannel,
};

pub const Animation = struct {
    name: []u8,
    length: f32,
    transtime: f32,
    anim_root: []u8,
    nodes: []AnimNode,
};

// ============================================================================
// MdlFile
// ============================================================================

pub const MdlFile = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    supermodel: []u8,
    classification: Classification,
    animation_scale: f32,
    dependency: []u8,
    nodes: std.ArrayList(Node),
    animations: std.ArrayList(Animation),

    pub fn init(allocator: std.mem.Allocator) MdlFile {
        return .{
            .allocator = allocator,
            .name = &[_]u8{},
            .supermodel = &[_]u8{},
            .classification = .character,
            .animation_scale = 1.0,
            .dependency = &[_]u8{},
            .nodes = std.ArrayList(Node).init(allocator),
            .animations = std.ArrayList(Animation).init(allocator),
        };
    }

    pub fn deinit(self: *MdlFile) void {
        for (self.nodes.items) |*n| freeNode(self.allocator, n);
        self.nodes.deinit();
        for (self.animations.items) |*a| freeAnimation(self.allocator, a);
        self.animations.deinit();
        if (self.name.len > 0) self.allocator.free(self.name);
        if (self.supermodel.len > 0) self.allocator.free(self.supermodel);
        if (self.dependency.len > 0) self.allocator.free(self.dependency);
    }

    pub fn addNode(self: *MdlFile, node: Node) !void {
        try self.nodes.append(node);
    }

    pub fn findNode(self: *const MdlFile, node_name: []const u8) ?*const Node {
        for (self.nodes.items) |*n| {
            if (std.mem.eql(u8, n.nodeName(), node_name)) return n;
        }
        return null;
    }

    pub fn addAnimation(self: *MdlFile, anim: Animation) !void {
        try self.animations.append(anim);
    }

    // ------------------------------------------------------------------ parse

    pub fn parse(self: *MdlFile, text: []const u8) (FormatError || std.mem.Allocator.Error)!void {
        var tok = Tokenizer.init(text);
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "filedependancy") or eqlIc(kw, "filedependency")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                if (self.dependency.len > 0) self.allocator.free(self.dependency);
                self.dependency = try self.allocator.dupe(u8, v);
                tok.skipLine();
            } else if (eqlIc(kw, "newmodel")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                if (self.name.len > 0) self.allocator.free(self.name);
                self.name = try self.allocator.dupe(u8, v);
                tok.skipLine();
            } else if (eqlIc(kw, "setsupermodel")) {
                _ = tok.nextToken() orelse return error.InvalidFormat; // repeated model name
                const v = tok.nextToken() orelse return error.InvalidFormat;
                if (self.supermodel.len > 0) self.allocator.free(self.supermodel);
                self.supermodel = try self.allocator.dupe(u8, v);
                tok.skipLine();
            } else if (eqlIc(kw, "classification")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                self.classification = Classification.fromString(v) orelse return error.UnknownClassification;
                tok.skipLine();
            } else if (eqlIc(kw, "setanimationscale")) {
                self.animation_scale = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "beginmodelgeom")) {
                tok.skipLine();
                try self.parseGeomSection(&tok);
            } else if (eqlIc(kw, "newanim")) {
                const anim_name = tok.nextToken() orelse return error.InvalidFormat;
                tok.skipLine();
                const anim = try self.parseAnim(&tok, anim_name);
                try self.animations.append(anim);
            } else if (eqlIc(kw, "donemodel")) {
                break;
            } else {
                tok.skipLine();
            }
        }
    }

    fn parseGeomSection(self: *MdlFile, tok: *Tokenizer) (FormatError || std.mem.Allocator.Error)!void {
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endmodelgeom")) {
                tok.skipLine();
                return;
            }
            if (eqlIc(kw, "node")) {
                const type_str = tok.nextToken() orelse return error.InvalidFormat;
                const node_name = tok.nextToken() orelse return error.InvalidFormat;
                tok.skipLine();
                const node = try self.parseNode(tok, type_str, node_name);
                try self.nodes.append(node);
            } else {
                tok.skipLine();
            }
        }
    }

    fn parseNode(self: *MdlFile, tok: *Tokenizer, type_str: []const u8, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!Node {
        const nt = NodeType.fromString(type_str) orelse return error.UnknownNodeType;
        return switch (nt) {
            .dummy => Node{ .dummy = try self.parseDummyLike(tok, node_name) },
            .aabb => Node{ .aabb = try self.parseDummyLike(tok, node_name) },
            .reference => Node{ .reference = try self.parseDummyLike(tok, node_name) },
            .trimesh => Node{ .trimesh = try self.parseTrimeshNode(tok, node_name) },
            .danglymesh => Node{ .danglymesh = try self.parseDanglyMeshNode(tok, node_name) },
            .skin => Node{ .skin = try self.parseSkinNode(tok, node_name) },
            .light => Node{ .light = try self.parseLightNode(tok, node_name) },
            .emitter => Node{ .emitter = try self.parseEmitterNode(tok, node_name) },
        };
    }

    fn parseDummyLike(self: *MdlFile, tok: *Tokenizer, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!NodeBase {
        var b: NodeBase = .{
            .name = try self.allocator.dupe(u8, node_name),
            .parent = try self.allocator.dupe(u8, ""),
        };
        errdefer freeNodeBase(self.allocator, &b);
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                return b;
            }
            try parseBaseKeyword(self.allocator, tok, kw, &b);
        }
        return error.InvalidFormat;
    }

    fn parseTrimeshNode(self: *MdlFile, tok: *Tokenizer, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!TrimeshNode {
        var n: TrimeshNode = .{
            .base = .{ .name = try self.allocator.dupe(u8, node_name), .parent = try self.allocator.dupe(u8, "") },
            .bitmap = try self.allocator.dupe(u8, ""),
            .geometry = emptyGeom(),
        };
        errdefer freeTrimeshNode(self.allocator, &n);
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                return n;
            }
            try parseMeshKeyword(self.allocator, tok, kw, &n);
        }
        return error.InvalidFormat;
    }

    fn parseDanglyMeshNode(self: *MdlFile, tok: *Tokenizer, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!DanglyMeshNode {
        var dn: DanglyMeshNode = .{
            .mesh = .{
                .base = .{ .name = try self.allocator.dupe(u8, node_name), .parent = try self.allocator.dupe(u8, "") },
                .bitmap = try self.allocator.dupe(u8, ""),
                .geometry = emptyGeom(),
            },
            .constraints = &.{},
        };
        errdefer freeDanglyMeshNode(self.allocator, &dn);
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                return dn;
            }
            if (eqlIc(kw, "period")) {
                dn.dangly.period = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "tightness")) {
                dn.dangly.tightness = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "displacement")) {
                dn.dangly.displacement = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "constraints")) {
                const count = try tok.nextInt(u32);
                tok.skipLine();
                if (dn.constraints.len > 0) self.allocator.free(dn.constraints);
                dn.constraints = &.{};
                dn.constraints = try self.allocator.alloc(f32, count);
                for (dn.constraints) |*c| {
                    c.* = try tok.nextFloat();
                    tok.skipLine();
                }
            } else {
                try parseMeshKeyword(self.allocator, tok, kw, &dn.mesh);
            }
        }
        return error.InvalidFormat;
    }

    fn parseSkinNode(self: *MdlFile, tok: *Tokenizer, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!SkinNode {
        var sn: SkinNode = .{
            .mesh = .{
                .base = .{ .name = try self.allocator.dupe(u8, node_name), .parent = try self.allocator.dupe(u8, "") },
                .bitmap = try self.allocator.dupe(u8, ""),
                .geometry = emptyGeom(),
            },
            .bone_weights = &.{},
        };
        errdefer freeSkinNode(self.allocator, &sn);
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                return sn;
            }
            if (eqlIc(kw, "weights")) {
                const count = try tok.nextInt(u32);
                tok.skipLine();
                // free old
                for (sn.bone_weights) |bw| if (bw.len > 0) self.allocator.free(bw);
                if (sn.bone_weights.len > 0) self.allocator.free(sn.bone_weights);
                sn.bone_weights = &.{};
                sn.bone_weights = try self.allocator.alloc([]BoneWeight, count);
                for (sn.bone_weights) |*bw_slice| bw_slice.* = &.{};
                var tmp = std.ArrayList(BoneWeight).init(self.allocator);
                defer tmp.deinit();
                for (sn.bone_weights) |*bw_slice| {
                    tmp.clearRetainingCapacity();
                    // Each line: up to 4 pairs of "bonename weight"; padding is "0 0".
                    var i: usize = 0;
                    while (i < 4) : (i += 1) {
                        const name_tok = tok.nextToken() orelse break;
                        const wt_tok = tok.nextToken() orelse return error.InvalidFormat;
                        const wt = std.fmt.parseFloat(f32, wt_tok) catch return error.InvalidFormat;
                        if (!std.mem.eql(u8, name_tok, "0")) {
                            var bw: BoneWeight = .{ .weight = wt };
                            bw.setName(name_tok);
                            try tmp.append(bw);
                        }
                    }
                    tok.skipLine();
                    bw_slice.* = try self.allocator.dupe(BoneWeight, tmp.items);
                }
            } else {
                try parseMeshKeyword(self.allocator, tok, kw, &sn.mesh);
            }
        }
        return error.InvalidFormat;
    }

    fn parseLightNode(self: *MdlFile, tok: *Tokenizer, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!LightNode {
        var n: LightNode = .{
            .base = .{ .name = try self.allocator.dupe(u8, node_name), .parent = try self.allocator.dupe(u8, "") },
        };
        errdefer freeNodeBase(self.allocator, &n.base);
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                return n;
            }
            if (eqlIc(kw, "color")) {
                n.color = try tok.nextVec3();
                tok.skipLine();
            } else if (eqlIc(kw, "radius")) {
                n.radius = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "multiplier")) {
                n.multiplier = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "isdynamic")) {
                n.is_dynamic = (try tok.nextInt(u8)) != 0;
                tok.skipLine();
            } else if (eqlIc(kw, "affectsdynamic")) {
                n.affects_dynamic = (try tok.nextInt(u8)) != 0;
                tok.skipLine();
            } else if (eqlIc(kw, "shadow")) {
                n.shadow = (try tok.nextInt(u8)) != 0;
                tok.skipLine();
            } else if (eqlIc(kw, "fadinglight")) {
                n.fading = (try tok.nextInt(u8)) != 0;
                tok.skipLine();
            } else if (eqlIc(kw, "priority")) {
                n.priority = try tok.nextInt(u8);
                tok.skipLine();
            } else {
                try parseBaseKeyword(self.allocator, tok, kw, &n.base);
            }
        }
        return error.InvalidFormat;
    }

    fn parseEmitterNode(self: *MdlFile, tok: *Tokenizer, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!EmitterNode {
        var n: EmitterNode = .{
            .base = .{ .name = try self.allocator.dupe(u8, node_name), .parent = try self.allocator.dupe(u8, "") },
            .texture = try self.allocator.dupe(u8, ""),
        };
        errdefer {
            freeNodeBase(self.allocator, &n.base);
            self.allocator.free(n.texture);
        }
        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                return n;
            }
            if (eqlIc(kw, "birthrate")) {
                n.birthrate = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "lifeexp")) {
                n.life_exp = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "startsize")) {
                n.size_start = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "endsize")) {
                n.size_end = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "startcolor")) {
                n.color_start = try tok.nextVec3();
                tok.skipLine();
            } else if (eqlIc(kw, "endcolor")) {
                n.color_end = try tok.nextVec3();
                tok.skipLine();
            } else if (eqlIc(kw, "startalpha")) {
                n.alpha_start = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "endalpha")) {
                n.alpha_end = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "velocity")) {
                n.velocity = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "randomvelocity")) {
                n.random_velocity = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "acceleration")) {
                n.acceleration = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "spread")) {
                n.spread = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "fps")) {
                n.fps = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "renderorder")) {
                n.render_order = try tok.nextInt(u32);
                tok.skipLine();
            } else if (eqlIc(kw, "update")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                n.update_style = UpdateStyle.fromString(v) orelse return error.InvalidFormat;
                tok.skipLine();
            } else if (eqlIc(kw, "render")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                n.render_style = RenderStyle.fromString(v) orelse return error.InvalidFormat;
                tok.skipLine();
            } else if (eqlIc(kw, "blend")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                n.blend_mode = BlendMode.fromString(v) orelse return error.InvalidFormat;
                tok.skipLine();
            } else if (eqlIc(kw, "texture")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                self.allocator.free(n.texture);
                n.texture = try self.allocator.dupe(u8, v);
                tok.skipLine();
            } else if (eqlIc(kw, "xsize")) {
                n.x_size = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "ysize")) {
                n.y_size = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "bounce")) {
                n.bouncing = (try tok.nextInt(u8)) != 0;
                tok.skipLine();
            } else if (eqlIc(kw, "detonate")) {
                n.detonate = (try tok.nextInt(u8)) != 0;
                tok.skipLine();
            } else {
                try parseBaseKeyword(self.allocator, tok, kw, &n.base);
            }
        }
        return error.InvalidFormat;
    }

    fn parseAnim(self: *MdlFile, tok: *Tokenizer, raw_name: []const u8) (FormatError || std.mem.Allocator.Error)!Animation {
        var anim: Animation = .{
            .name = try self.allocator.dupe(u8, raw_name),
            .length = 0,
            .transtime = 0.25,
            .anim_root = try self.allocator.dupe(u8, ""),
            .nodes = &.{},
        };
        errdefer freeAnimation(self.allocator, &anim);
        var an_list = std.ArrayList(AnimNode).init(self.allocator);
        defer an_list.deinit();

        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "doneanim")) {
                tok.skipLine();
                anim.nodes = try an_list.toOwnedSlice();
                return anim;
            }
            if (eqlIc(kw, "length")) {
                anim.length = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "transtime")) {
                anim.transtime = try tok.nextFloat();
                tok.skipLine();
            } else if (eqlIc(kw, "animroot")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                self.allocator.free(anim.anim_root);
                anim.anim_root = try self.allocator.dupe(u8, v);
                tok.skipLine();
            } else if (eqlIc(kw, "node")) {
                const type_str = tok.nextToken() orelse return error.InvalidFormat;
                const nname = tok.nextToken() orelse return error.InvalidFormat;
                tok.skipLine();
                const an = try self.parseAnimNode(tok, type_str, nname);
                try an_list.append(an);
            } else {
                tok.skipLine();
            }
        }
        return error.InvalidFormat;
    }

    fn parseAnimNode(self: *MdlFile, tok: *Tokenizer, type_str: []const u8, node_name: []const u8) (FormatError || std.mem.Allocator.Error)!AnimNode {
        const nt = NodeType.fromString(type_str) orelse return error.UnknownNodeType;
        var an: AnimNode = .{
            .node_type = nt,
            .name = try self.allocator.dupe(u8, node_name),
            .parent = try self.allocator.dupe(u8, ""),
            .channels = &.{},
        };
        errdefer freeAnimNode(self.allocator, &an);
        var ch_list = std.ArrayList(KeyChannel).init(self.allocator);
        defer ch_list.deinit();

        while (tok.nextToken()) |kw| {
            if (eqlIc(kw, "endnode")) {
                tok.skipLine();
                an.channels = try ch_list.toOwnedSlice();
                return an;
            }
            if (eqlIc(kw, "parent")) {
                const v = tok.nextToken() orelse return error.InvalidFormat;
                self.allocator.free(an.parent);
                an.parent = try self.allocator.dupe(u8, v);
                tok.skipLine();
            } else if (isKeyframeChannel(kw)) {
                const count = try tok.nextInt(u32);
                tok.skipLine();
                const ch = try self.parseKeyChannel(tok, kw, count);
                try ch_list.append(ch);
            } else {
                tok.skipLine();
            }
        }
        return error.InvalidFormat;
    }

    fn parseKeyChannel(self: *MdlFile, tok: *Tokenizer, ch_name: []const u8, count: u32) (FormatError || std.mem.Allocator.Error)!KeyChannel {
        const frames = try self.allocator.alloc(Keyframe, count);
        errdefer self.allocator.free(frames);
        for (frames) |*f| {
            f.time = try tok.nextFloat();
            if (isFloatChannel(ch_name)) {
                f.value = .{ .float = try tok.nextFloat() };
            } else if (isVec3Channel(ch_name)) {
                f.value = .{ .vec3 = try tok.nextVec3() };
            } else {
                f.value = .{ .quat = try tok.nextVec4() };
            }
            tok.skipLine();
        }
        return KeyChannel{ .name = try self.allocator.dupe(u8, ch_name), .frames = frames };
    }

    // --------------------------------------------------------------- serialize

    pub fn serialize(self: *const MdlFile, alloc: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.print("filedependancy {s}\n", .{self.dependency});
        try w.print("newmodel {s}\n", .{self.name});
        try w.print("setsupermodel {s} {s}\n", .{ self.name, self.supermodel });
        try w.print("classification {s}\n", .{self.classification.toString()});
        try w.print("setanimationscale {d:.6}\n\n", .{self.animation_scale});

        if (self.nodes.items.len > 0) {
            try w.print("beginmodelgeom {s}\n", .{self.name});
            for (self.nodes.items) |*node| try writeNode(w, node);
            try w.print("endmodelgeom {s}\n\n", .{self.name});
        }

        for (self.animations.items) |*anim| try writeAnimation(w, anim, self.name);

        try w.print("donemodel {s}\n", .{self.name});
        return buf.toOwnedSlice();
    }
};

// ============================================================================
// Serialize helpers
// ============================================================================

fn writeNode(w: anytype, node: *const Node) !void {
    const b = node.base();
    try w.print("  node {s} {s}\n", .{ @tagName(node.*), b.name });
    try w.print("    parent {s}\n", .{b.parent});
    try w.print("    position {d:.6} {d:.6} {d:.6}\n", .{ b.position[0], b.position[1], b.position[2] });
    try w.print("    orientation {d:.6} {d:.6} {d:.6} {d:.6}\n", .{ b.orientation[0], b.orientation[1], b.orientation[2], b.orientation[3] });
    try w.print("    wirecolor {d:.6} {d:.6} {d:.6}\n", .{ b.wirecolor[0], b.wirecolor[1], b.wirecolor[2] });

    switch (node.*) {
        .dummy, .aabb, .reference => {},
        .trimesh => |*n| try writeMeshFields(w, n),
        .danglymesh => |*n| {
            try writeMeshFields(w, &n.mesh);
            try w.print("    period {d:.6}\n", .{n.dangly.period});
            try w.print("    tightness {d:.6}\n", .{n.dangly.tightness});
            try w.print("    displacement {d:.6}\n", .{n.dangly.displacement});
            try w.print("    constraints {d}\n", .{n.constraints.len});
            for (n.constraints) |c| try w.print("      {d:.6}\n", .{c});
        },
        .skin => |*n| {
            try writeMeshFields(w, &n.mesh);
            try w.print("    weights {d}\n", .{n.bone_weights.len});
            for (n.bone_weights) |bw_slice| {
                var written: usize = 0;
                for (bw_slice) |bw| {
                    try w.print("{s} {d:.6} ", .{ bw.nameSlice(), bw.weight });
                    written += 1;
                }
                while (written < 4) : (written += 1) try w.print("0 0 ", .{});
                try w.print("\n", .{});
            }
        },
        .light => |*n| {
            try w.print("    color {d:.6} {d:.6} {d:.6}\n", .{ n.color[0], n.color[1], n.color[2] });
            try w.print("    radius {d:.6}\n", .{n.radius});
            try w.print("    multiplier {d:.6}\n", .{n.multiplier});
            try w.print("    isdynamic {d}\n", .{@as(u8, if (n.is_dynamic) 1 else 0)});
            try w.print("    affectsdynamic {d}\n", .{@as(u8, if (n.affects_dynamic) 1 else 0)});
            try w.print("    shadow {d}\n", .{@as(u8, if (n.shadow) 1 else 0)});
            try w.print("    fadinglight {d}\n", .{@as(u8, if (n.fading) 1 else 0)});
            try w.print("    priority {d}\n", .{n.priority});
        },
        .emitter => |*n| {
            try w.print("    birthrate {d:.6}\n", .{n.birthrate});
            try w.print("    lifeexp {d:.6}\n", .{n.life_exp});
            try w.print("    startsize {d:.6}\n", .{n.size_start});
            try w.print("    endsize {d:.6}\n", .{n.size_end});
            try w.print("    startcolor {d:.6} {d:.6} {d:.6}\n", .{ n.color_start[0], n.color_start[1], n.color_start[2] });
            try w.print("    endcolor {d:.6} {d:.6} {d:.6}\n", .{ n.color_end[0], n.color_end[1], n.color_end[2] });
            try w.print("    startalpha {d:.6}\n", .{n.alpha_start});
            try w.print("    endalpha {d:.6}\n", .{n.alpha_end});
            try w.print("    velocity {d:.6}\n", .{n.velocity});
            try w.print("    randomvelocity {d:.6}\n", .{n.random_velocity});
            try w.print("    acceleration {d:.6}\n", .{n.acceleration});
            try w.print("    spread {d:.6}\n", .{n.spread});
            try w.print("    fps {d:.6}\n", .{n.fps});
            try w.print("    renderorder {d}\n", .{n.render_order});
            try w.print("    update {s}\n", .{n.update_style.toString()});
            try w.print("    render {s}\n", .{n.render_style.toString()});
            try w.print("    blend {s}\n", .{n.blend_mode.toString()});
            try w.print("    texture {s}\n", .{n.texture});
            try w.print("    xsize {d:.6}\n", .{n.x_size});
            try w.print("    ysize {d:.6}\n", .{n.y_size});
            try w.print("    bounce {d}\n", .{@as(u8, if (n.bouncing) 1 else 0)});
            try w.print("    detonate {d}\n", .{@as(u8, if (n.detonate) 1 else 0)});
        },
    }
    try w.print("  endnode\n", .{});
}

fn writeMeshFields(w: anytype, n: *const TrimeshNode) !void {
    try w.print("    bitmap {s}\n", .{n.bitmap});
    try w.print("    render {d}\n", .{@as(u8, if (n.aura_poly.render) 1 else 0)});
    try w.print("    shadow {d}\n", .{@as(u8, if (n.aura_poly.shadow) 1 else 0)});
    try w.print("    beaming {d}\n", .{@as(u8, if (n.aura_poly.beaming) 1 else 0)});
    try w.print("    inheritcolor {d}\n", .{@as(u8, if (n.aura_poly.inherit_color) 1 else 0)});
    try w.print("    rotatetexture {d}\n", .{@as(u8, if (n.aura_poly.rotate_texture) 1 else 0)});
    try w.print("    alpha {d:.6}\n", .{n.alpha});
    try w.print("    transparencyhint {d}\n", .{n.transparency_hint});
    try w.print("    selfillumcolor {d:.6} {d:.6} {d:.6}\n", .{ n.self_illum_color[0], n.self_illum_color[1], n.self_illum_color[2] });
    try w.print("    scale {d:.6}\n", .{n.scale_factor});
    try w.print("    diffuse {d:.6} {d:.6} {d:.6}\n", .{ n.diffuse[0], n.diffuse[1], n.diffuse[2] });
    try w.print("    ambient {d:.6} {d:.6} {d:.6}\n", .{ n.ambient[0], n.ambient[1], n.ambient[2] });

    const g = &n.geometry;
    try w.print("    verts {d}\n", .{g.verts.len});
    for (g.verts) |v| try w.print("      {d:.6} {d:.6} {d:.6}\n", .{ v[0], v[1], v[2] });
    try w.print("    normals {d}\n", .{g.normals.len});
    for (g.normals) |v| try w.print("      {d:.6} {d:.6} {d:.6}\n", .{ v[0], v[1], v[2] });
    try w.print("    tverts {d}\n", .{g.tverts.len});
    for (g.tverts) |v| try w.print("      {d:.6} {d:.6}\n", .{ v[0], v[1] });
    try w.print("    faces {d}\n", .{g.faces.len});
    for (g.faces) |f| try w.print("      {d} {d} {d} {d} {d} {d} {d} {d}\n", .{ f.verts[0], f.verts[1], f.verts[2], f.smooth_group, f.mat_id, f.tverts[0], f.tverts[1], f.tverts[2] });
    if (g.colors) |cols| {
        try w.print("    colors {d}\n", .{cols.len});
        for (cols) |c| try w.print("      {d:.6} {d:.6} {d:.6} {d:.6}\n", .{ c[0], c[1], c[2], c[3] });
    }
}

fn writeAnimation(w: anytype, anim: *const Animation, model_name: []const u8) !void {
    try w.print("newanim {s} {s}\n", .{ anim.name, model_name });
    try w.print("  length {d:.6}\n", .{anim.length});
    try w.print("  transtime {d:.6}\n", .{anim.transtime});
    try w.print("  animroot {s}\n", .{anim.anim_root});
    for (anim.nodes) |*an| {
        try w.print("  node {s} {s}\n", .{ an.node_type.toString(), an.name });
        try w.print("    parent {s}\n", .{an.parent});
        for (an.channels) |*ch| {
            try w.print("    {s} {d}\n", .{ ch.name, ch.frames.len });
            for (ch.frames) |fr| switch (fr.value) {
                .float => |v| try w.print("      {d:.6} {d:.6}\n", .{ fr.time, v }),
                .vec3 => |v| try w.print("      {d:.6} {d:.6} {d:.6} {d:.6}\n", .{ fr.time, v[0], v[1], v[2] }),
                .quat => |v| try w.print("      {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{ fr.time, v[0], v[1], v[2], v[3] }),
            };
        }
        try w.print("  endnode\n", .{});
    }
    try w.print("doneanim {s} {s}\n\n", .{ anim.name, model_name });
}

// ============================================================================
// Parse helpers
// ============================================================================

fn parseBaseKeyword(alloc: std.mem.Allocator, tok: *Tokenizer, kw: []const u8, b: *NodeBase) (FormatError || std.mem.Allocator.Error)!void {
    if (eqlIc(kw, "parent")) {
        const v = tok.nextToken() orelse return error.InvalidFormat;
        alloc.free(b.parent);
        b.parent = try alloc.dupe(u8, v);
        tok.skipLine();
    } else if (eqlIc(kw, "position")) {
        b.position = try tok.nextVec3();
        tok.skipLine();
    } else if (eqlIc(kw, "orientation")) {
        b.orientation = try tok.nextVec4();
        tok.skipLine();
    } else if (eqlIc(kw, "wirecolor")) {
        b.wirecolor = try tok.nextVec3();
        tok.skipLine();
    } else {
        tok.skipLine();
    }
}

fn parseMeshKeyword(alloc: std.mem.Allocator, tok: *Tokenizer, kw: []const u8, n: *TrimeshNode) (FormatError || std.mem.Allocator.Error)!void {
    if (eqlIc(kw, "parent") or eqlIc(kw, "position") or
        eqlIc(kw, "orientation") or eqlIc(kw, "wirecolor"))
    {
        return parseBaseKeyword(alloc, tok, kw, &n.base);
    }
    if (eqlIc(kw, "bitmap")) {
        const v = tok.nextToken() orelse return error.InvalidFormat;
        alloc.free(n.bitmap);
        n.bitmap = try alloc.dupe(u8, v);
        tok.skipLine();
    } else if (eqlIc(kw, "render")) {
        n.aura_poly.render = (try tok.nextInt(u8)) != 0;
        tok.skipLine();
    } else if (eqlIc(kw, "shadow")) {
        n.aura_poly.shadow = (try tok.nextInt(u8)) != 0;
        tok.skipLine();
    } else if (eqlIc(kw, "beaming")) {
        n.aura_poly.beaming = (try tok.nextInt(u8)) != 0;
        tok.skipLine();
    } else if (eqlIc(kw, "inheritcolor")) {
        n.aura_poly.inherit_color = (try tok.nextInt(u8)) != 0;
        tok.skipLine();
    } else if (eqlIc(kw, "rotatetexture")) {
        n.aura_poly.rotate_texture = (try tok.nextInt(u8)) != 0;
        tok.skipLine();
    } else if (eqlIc(kw, "alpha")) {
        n.alpha = try tok.nextFloat();
        tok.skipLine();
    } else if (eqlIc(kw, "transparencyhint")) {
        n.transparency_hint = try tok.nextInt(u32);
        tok.skipLine();
    } else if (eqlIc(kw, "selfillumcolor")) {
        n.self_illum_color = try tok.nextVec3();
        tok.skipLine();
    } else if (eqlIc(kw, "scale")) {
        n.scale_factor = try tok.nextFloat();
        tok.skipLine();
    } else if (eqlIc(kw, "diffuse")) {
        n.diffuse = try tok.nextVec3();
        tok.skipLine();
    } else if (eqlIc(kw, "ambient")) {
        n.ambient = try tok.nextVec3();
        tok.skipLine();
    } else if (eqlIc(kw, "verts")) {
        const cnt = try tok.nextInt(u32);
        tok.skipLine();
        if (n.geometry.verts.len > 0) alloc.free(n.geometry.verts);
        n.geometry.verts = &.{};
        n.geometry.verts = try alloc.alloc([3]f32, cnt);
        for (n.geometry.verts) |*v| {
            v.* = try tok.nextVec3();
            tok.skipLine();
        }
    } else if (eqlIc(kw, "normals")) {
        const cnt = try tok.nextInt(u32);
        tok.skipLine();
        if (n.geometry.normals.len > 0) alloc.free(n.geometry.normals);
        n.geometry.normals = &.{};
        n.geometry.normals = try alloc.alloc([3]f32, cnt);
        for (n.geometry.normals) |*v| {
            v.* = try tok.nextVec3();
            tok.skipLine();
        }
    } else if (eqlIc(kw, "tverts")) {
        const cnt = try tok.nextInt(u32);
        tok.skipLine();
        if (n.geometry.tverts.len > 0) alloc.free(n.geometry.tverts);
        n.geometry.tverts = &.{};
        n.geometry.tverts = try alloc.alloc([2]f32, cnt);
        for (n.geometry.tverts) |*v| {
            v[0] = try tok.nextFloat();
            v[1] = try tok.nextFloat();
            tok.skipLine();
        }
    } else if (eqlIc(kw, "faces")) {
        const cnt = try tok.nextInt(u32);
        tok.skipLine();
        if (n.geometry.faces.len > 0) alloc.free(n.geometry.faces);
        n.geometry.faces = &.{};
        n.geometry.faces = try alloc.alloc(Face, cnt);
        for (n.geometry.faces) |*f| {
            f.verts[0] = try tok.nextInt(u32);
            f.verts[1] = try tok.nextInt(u32);
            f.verts[2] = try tok.nextInt(u32);
            f.smooth_group = try tok.nextInt(u32);
            f.mat_id = try tok.nextInt(u32);
            f.tverts[0] = try tok.nextInt(u32);
            f.tverts[1] = try tok.nextInt(u32);
            f.tverts[2] = try tok.nextInt(u32);
            tok.skipLine();
        }
    } else if (eqlIc(kw, "colors")) {
        const cnt = try tok.nextInt(u32);
        tok.skipLine();
        if (n.geometry.colors) |c| alloc.free(c);
        n.geometry.colors = null;
        const cols = try alloc.alloc([4]f32, cnt);
        n.geometry.colors = cols;
        for (cols) |*c| {
            c[0] = try tok.nextFloat();
            c[1] = try tok.nextFloat();
            c[2] = try tok.nextFloat();
            c[3] = try tok.nextFloat();
            tok.skipLine();
        }
    } else {
        tok.skipLine();
    }
}

fn isKeyframeChannel(kw: []const u8) bool {
    return isFloatChannel(kw) or isVec3Channel(kw) or isQuatChannel(kw);
}
fn isFloatChannel(kw: []const u8) bool {
    return eqlIc(kw, "alphakey") or eqlIc(kw, "scalekey");
}
fn isVec3Channel(kw: []const u8) bool {
    return eqlIc(kw, "positionkey") or eqlIc(kw, "colorkey") or
        eqlIc(kw, "selfillumcolorkey");
}
fn isQuatChannel(kw: []const u8) bool {
    return eqlIc(kw, "orientationkey");
}

// ============================================================================
// Free helpers
// ============================================================================

fn freeNodeBase(alloc: std.mem.Allocator, b: *NodeBase) void {
    alloc.free(b.name);
    alloc.free(b.parent);
}

fn freeMeshGeometry(alloc: std.mem.Allocator, g: *MeshGeometry) void {
    if (g.verts.len > 0) alloc.free(g.verts);
    if (g.normals.len > 0) alloc.free(g.normals);
    if (g.tverts.len > 0) alloc.free(g.tverts);
    if (g.faces.len > 0) alloc.free(g.faces);
    if (g.colors) |c| alloc.free(c);
}

fn freeTrimeshNode(alloc: std.mem.Allocator, n: *TrimeshNode) void {
    freeNodeBase(alloc, &n.base);
    alloc.free(n.bitmap);
    freeMeshGeometry(alloc, &n.geometry);
}

fn freeDanglyMeshNode(alloc: std.mem.Allocator, n: *DanglyMeshNode) void {
    freeTrimeshNode(alloc, &n.mesh);
    if (n.constraints.len > 0) alloc.free(n.constraints);
}

fn freeSkinNode(alloc: std.mem.Allocator, n: *SkinNode) void {
    freeTrimeshNode(alloc, &n.mesh);
    for (n.bone_weights) |bw| if (bw.len > 0) alloc.free(bw);
    if (n.bone_weights.len > 0) alloc.free(n.bone_weights);
}

fn freeNode(alloc: std.mem.Allocator, node: *Node) void {
    switch (node.*) {
        .dummy, .aabb, .reference => |*b| freeNodeBase(alloc, b),
        .trimesh => |*n| freeTrimeshNode(alloc, n),
        .danglymesh => |*n| freeDanglyMeshNode(alloc, n),
        .skin => |*n| freeSkinNode(alloc, n),
        .light => |*n| freeNodeBase(alloc, &n.base),
        .emitter => |*n| {
            freeNodeBase(alloc, &n.base);
            alloc.free(n.texture);
        },
    }
}

fn freeKeyChannel(alloc: std.mem.Allocator, ch: *KeyChannel) void {
    alloc.free(ch.name);
    alloc.free(ch.frames);
}

fn freeAnimNode(alloc: std.mem.Allocator, an: *AnimNode) void {
    alloc.free(an.name);
    alloc.free(an.parent);
    for (an.channels) |*ch| freeKeyChannel(alloc, ch);
    if (an.channels.len > 0) alloc.free(an.channels);
}

fn freeAnimation(alloc: std.mem.Allocator, anim: *Animation) void {
    alloc.free(anim.name);
    alloc.free(anim.anim_root);
    for (anim.nodes) |*an| freeAnimNode(alloc, an);
    if (anim.nodes.len > 0) alloc.free(anim.nodes);
}

// ============================================================================
// Tokenizer
// ============================================================================

const Tokenizer = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn skipToLineEnd(self: *Tokenizer) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn skipLine(self: *Tokenizer) void {
        self.skipToLineEnd();
    }

    /// Returns the next whitespace-delimited token, skipping blank lines and
    /// lines that start with '#'.
    fn nextToken(self: *Tokenizer) ?[]const u8 {
        while (true) {
            // skip spaces, tabs, carriage returns
            while (self.pos < self.src.len and
                (self.src[self.pos] == ' ' or self.src[self.pos] == '\t' or
                    self.src[self.pos] == '\r'))
                self.pos += 1;

            if (self.pos >= self.src.len) return null;

            if (self.src[self.pos] == '\n') {
                self.pos += 1;
                continue;
            }
            if (self.src[self.pos] == '#') {
                self.skipToLineEnd();
                continue;
            }

            const start = self.pos;
            while (self.pos < self.src.len and
                self.src[self.pos] != ' ' and self.src[self.pos] != '\t' and
                self.src[self.pos] != '\r' and self.src[self.pos] != '\n')
                self.pos += 1;

            return self.src[start..self.pos];
        }
    }

    fn nextFloat(self: *Tokenizer) FormatError!f32 {
        const tok = self.nextToken() orelse return error.InvalidFormat;
        return std.fmt.parseFloat(f32, tok) catch error.InvalidFormat;
    }

    fn nextInt(self: *Tokenizer, comptime T: type) FormatError!T {
        const tok = self.nextToken() orelse return error.InvalidFormat;
        return std.fmt.parseInt(T, tok, 10) catch error.InvalidFormat;
    }

    fn nextVec3(self: *Tokenizer) FormatError![3]f32 {
        return .{ try self.nextFloat(), try self.nextFloat(), try self.nextFloat() };
    }

    fn nextVec4(self: *Tokenizer) FormatError![4]f32 {
        return .{ try self.nextFloat(), try self.nextFloat(), try self.nextFloat(), try self.nextFloat() };
    }
};

// ============================================================================
// Internal utilities
// ============================================================================

fn emptyGeom() MeshGeometry {
    return .{ .verts = &.{}, .normals = &.{}, .tverts = &.{}, .faces = &.{} };
}

fn eqlIc(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

test "MDL empty model header round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "mymodel");
    m.supermodel = try gpa.dupe(u8, "NULL");
    m.classification = .character;
    m.animation_scale = 1.0;

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    try t.expectEqualStrings("mymodel", m2.name);
    try t.expectEqualStrings("NULL", m2.supermodel);
    try t.expectEqual(Classification.character, m2.classification);
    try t.expectEqual(@as(f32, 1.0), m2.animation_scale);
    try t.expectEqual(@as(usize, 0), m2.nodes.items.len);
    try t.expectEqual(@as(usize, 0), m2.animations.items.len);
}

test "MDL dummy node round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "testmdl");
    m.supermodel = try gpa.dupe(u8, "NULL");

    try m.addNode(Node{ .dummy = .{
        .name = try gpa.dupe(u8, "RootDummy"),
        .parent = try gpa.dupe(u8, "NULL"),
        .position = .{ 1.0, 2.0, 3.0 },
        .orientation = .{ 0.0, 0.0, 0.0, 1.0 },
        .wirecolor = .{ 0.5, 0.5, 0.5 },
    } });

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    try t.expectEqual(@as(usize, 1), m2.nodes.items.len);
    const nd = &m2.nodes.items[0];
    try t.expectEqual(NodeType.dummy, @as(NodeType, nd.*));
    try t.expectEqualStrings("RootDummy", nd.nodeName());
    try t.expectEqualStrings("NULL", nd.base().parent);
    try t.expectEqual(@as(f32, 1.0), nd.base().position[0]);
    try t.expectEqual(@as(f32, 2.0), nd.base().position[1]);
    try t.expectEqual(@as(f32, 3.0), nd.base().position[2]);
}

test "MDL trimesh node with geometry round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "geomtest");
    m.supermodel = try gpa.dupe(u8, "NULL");

    const verts = try gpa.dupe([3]f32, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } });
    const normals = try gpa.dupe([3]f32, &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } });
    const tverts = try gpa.dupe([2]f32, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } });
    const faces = try gpa.dupe(Face, &.{Face{ .verts = .{ 0, 1, 2 }, .tverts = .{ 0, 1, 2 }, .smooth_group = 1, .mat_id = 0 }});

    try m.addNode(Node{ .trimesh = .{
        .base = .{ .name = try gpa.dupe(u8, "Mesh01"), .parent = try gpa.dupe(u8, "RootDummy") },
        .bitmap = try gpa.dupe(u8, "my_texture"),
        .aura_poly = .{ .render = true, .shadow = true, .beaming = false, .inherit_color = false, .rotate_texture = true },
        .alpha = 0.75,
        .self_illum_color = .{ 0.1, 0.2, 0.3 },
        .geometry = .{ .verts = verts, .normals = normals, .tverts = tverts, .faces = faces },
    } });

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    try t.expectEqual(@as(usize, 1), m2.nodes.items.len);
    const tn = &m2.nodes.items[0].trimesh;
    try t.expectEqualStrings("Mesh01", tn.base.name);
    try t.expectEqualStrings("my_texture", tn.bitmap);
    try t.expectEqual(@as(f32, 0.75), tn.alpha);
    try t.expect(tn.aura_poly.rotate_texture);
    try t.expectEqual(@as(usize, 3), tn.geometry.verts.len);
    try t.expectEqual(@as(f32, 1.0), tn.geometry.verts[1][0]);
    try t.expectEqual(@as(usize, 1), tn.geometry.faces.len);
    try t.expectEqual(@as(u32, 1), tn.geometry.faces[0].verts[0]);
}

test "MDL danglymesh round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "danglytest");
    m.supermodel = try gpa.dupe(u8, "NULL");

    const verts = try gpa.dupe([3]f32, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 } });
    const norms = try gpa.dupe([3]f32, &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 } });
    const tvs = try gpa.dupe([2]f32, &.{ .{ 0, 0 }, .{ 1, 0 } });
    const faces: []Face = &.{};
    const constr = try gpa.dupe(f32, &.{ 255.0, 0.0 });

    try m.addNode(Node{ .danglymesh = .{
        .mesh = .{
            .base = .{ .name = try gpa.dupe(u8, "Hair"), .parent = try gpa.dupe(u8, "Head") },
            .bitmap = try gpa.dupe(u8, "hair_tex"),
            .geometry = .{ .verts = verts, .normals = norms, .tverts = tvs, .faces = faces },
        },
        .dangly = .{ .period = 2.5, .tightness = 0.5, .displacement = 0.1 },
        .constraints = constr,
    } });

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    try t.expectEqual(@as(usize, 1), m2.nodes.items.len);
    const dn = &m2.nodes.items[0].danglymesh;
    try t.expectEqualStrings("Hair", dn.mesh.base.name);
    try t.expectEqual(@as(f32, 2.5), dn.dangly.period);
    try t.expectEqual(@as(f32, 0.5), dn.dangly.tightness);
    try t.expectEqual(@as(usize, 2), dn.constraints.len);
    try t.expectEqual(@as(f32, 255.0), dn.constraints[0]);
    try t.expectEqual(@as(f32, 0.0), dn.constraints[1]);
}

test "MDL light node round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "lighttest");
    m.supermodel = try gpa.dupe(u8, "NULL");

    try m.addNode(Node{ .light = .{
        .base = .{ .name = try gpa.dupe(u8, "SunLight"), .parent = try gpa.dupe(u8, "RootDummy") },
        .color = .{ 1.0, 0.9, 0.8 },
        .radius = 10.0,
        .multiplier = 1.5,
        .is_dynamic = true,
        .affects_dynamic = true,
        .fading = true,
        .priority = 1,
    } });

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    const ln = &m2.nodes.items[0].light;
    try t.expectEqualStrings("SunLight", ln.base.name);
    try t.expectEqual(@as(f32, 10.0), ln.radius);
    try t.expectEqual(@as(f32, 1.5), ln.multiplier);
    try t.expect(ln.is_dynamic);
    try t.expectEqual(@as(u8, 1), ln.priority);
}

test "MDL emitter node round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "emtest");
    m.supermodel = try gpa.dupe(u8, "NULL");

    try m.addNode(Node{ .emitter = .{
        .base = .{ .name = try gpa.dupe(u8, "Sparks"), .parent = try gpa.dupe(u8, "Root") },
        .texture = try gpa.dupe(u8, "spark_tex"),
        .birthrate = 50.0,
        .life_exp = 0.5,
        .velocity = 2.0,
        .update_style = .fountain,
        .render_style = .normal,
        .blend_mode = .normal,
    } });

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    const en = &m2.nodes.items[0].emitter;
    try t.expectEqualStrings("Sparks", en.base.name);
    try t.expectEqualStrings("spark_tex", en.texture);
    try t.expectEqual(@as(f32, 50.0), en.birthrate);
    try t.expectEqual(UpdateStyle.fountain, en.update_style);
}

test "MDL animation with keyframe channels round-trip" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "animtest");
    m.supermodel = try gpa.dupe(u8, "NULL");

    // Build animation manually.
    const pos_frames = try gpa.dupe(Keyframe, &.{
        .{ .time = 0.0, .value = .{ .vec3 = .{ 0, 0, 0 } } },
        .{ .time = 1.0, .value = .{ .vec3 = .{ 0, 0, 5 } } },
    });
    const ori_frames = try gpa.dupe(Keyframe, &.{
        .{ .time = 0.0, .value = .{ .quat = .{ 0, 0, 0, 1 } } },
    });
    const alpha_frames = try gpa.dupe(Keyframe, &.{
        .{ .time = 0.0, .value = .{ .float = 1.0 } },
        .{ .time = 1.0, .value = .{ .float = 0.0 } },
    });

    const channels = try gpa.dupe(KeyChannel, &.{
        .{ .name = try gpa.dupe(u8, "positionkey"), .frames = pos_frames },
        .{ .name = try gpa.dupe(u8, "orientationkey"), .frames = ori_frames },
        .{ .name = try gpa.dupe(u8, "alphakey"), .frames = alpha_frames },
    });

    const anim_nodes = try gpa.dupe(AnimNode, &.{
        .{ .node_type = .dummy, .name = try gpa.dupe(u8, "Root"), .parent = try gpa.dupe(u8, "NULL"), .channels = channels },
    });

    const anim: Animation = .{
        .name = try gpa.dupe(u8, "walk"),
        .length = 1.0,
        .transtime = 0.25,
        .anim_root = try gpa.dupe(u8, "Root"),
        .nodes = anim_nodes,
    };
    try m.addAnimation(anim);

    const bytes = try m.serialize(gpa);
    defer gpa.free(bytes);

    var m2 = MdlFile.init(gpa);
    defer m2.deinit();
    try m2.parse(bytes);

    try t.expectEqual(@as(usize, 1), m2.animations.items.len);
    const a = &m2.animations.items[0];
    try t.expectEqualStrings("walk", a.name);
    try t.expectEqual(@as(f32, 1.0), a.length);
    try t.expectEqual(@as(f32, 0.25), a.transtime);
    try t.expectEqual(@as(usize, 1), a.nodes.len);

    const an = &a.nodes[0];
    try t.expectEqualStrings("Root", an.name);
    try t.expectEqual(@as(usize, 3), an.channels.len);
    try t.expectEqualStrings("positionkey", an.channels[0].name);
    try t.expectEqual(@as(usize, 2), an.channels[0].frames.len);
    try t.expectEqual(@as(f32, 5.0), an.channels[0].frames[1].value.vec3[2]);
    try t.expectEqualStrings("alphakey", an.channels[2].name);
    try t.expectEqual(@as(f32, 0.0), an.channels[2].frames[1].value.float);
}

test "MDL findNode" {
    const gpa = t.allocator;
    var m = MdlFile.init(gpa);
    defer m.deinit();

    m.name = try gpa.dupe(u8, "findtest");
    m.supermodel = try gpa.dupe(u8, "NULL");

    try m.addNode(Node{ .dummy = .{ .name = try gpa.dupe(u8, "Root"), .parent = try gpa.dupe(u8, "NULL") } });
    try m.addNode(Node{ .dummy = .{ .name = try gpa.dupe(u8, "Child"), .parent = try gpa.dupe(u8, "Root") } });

    try t.expect(m.findNode("Root") != null);
    try t.expect(m.findNode("Child") != null);
    try t.expectEqual(@as(?*const Node, null), m.findNode("Missing"));
}

test "MDL parse rejects unknown classification" {
    const gpa = t.allocator;
    const src =
        \\newmodel test
        \\setsupermodel test NULL
        \\classification Banana
        \\donemodel test
    ;
    var m = MdlFile.init(gpa);
    defer m.deinit();
    try t.expectError(error.UnknownClassification, m.parse(src));
}

test "MDL parse rejects unknown node type" {
    const gpa = t.allocator;
    const src =
        \\newmodel test
        \\setsupermodel test NULL
        \\classification Character
        \\beginmodelgeom test
        \\  node banana BadNode
        \\    parent NULL
        \\  endnode
        \\endmodelgeom test
        \\donemodel test
    ;
    var m = MdlFile.init(gpa);
    defer m.deinit();
    try t.expectError(error.UnknownNodeType, m.parse(src));
}
