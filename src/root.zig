//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const twoda = @import("twoda.zig");
pub const TwoDA = twoda.TwoDA;
pub const ReadStatus = twoda.ReadStatus;
pub const ParseError = twoda.ParseError;
pub const BLANK_VALUE = twoda.BLANK_VALUE;
pub const VERSION_HEADER = twoda.VERSION_HEADER;

pub const keybif = @import("keybif.zig");
pub const KeyFile = keybif.KeyFile;
pub const BifFile = keybif.BifFile;
pub const ResType = keybif.ResType;
pub const FormatError = keybif.FormatError;

pub const gff = @import("gff.zig");
pub const GffFile = gff.GffFile;
pub const GffFieldType = gff.FieldType;
pub const GffFieldValue = gff.FieldValue;

pub const erf = @import("erf.zig");
pub const ErfFile = erf.ErfFile;
pub const ErfEntry = erf.ErfEntry;
pub const ErfFileType = erf.ErfFileType;
pub const ErfLanguage = erf.Language;
pub const LocalizedString = erf.LocalizedString;

pub const rim = @import("rim.zig");
pub const RimFile = rim.RimFile;
pub const RimKeyEntry = rim.RimKeyEntry;
pub const RimError = rim.RimError;

pub const area = @import("area.zig");
pub const AreFile = area.AreFile;
pub const GitFile = area.GitFile;
pub const GicFile = area.GicFile;

pub const item = @import("item.zig");
pub const UtiFile = item.UtiFile;
pub const ItemStruct = item.ItemStruct;
pub const ItemProperty = item.ItemProperty;
pub const ItemModel = item.ItemModel;
pub const ItemVariant = item.ItemVariant;
pub const ModelType = item.ModelType;

pub const tlk = @import("tlk.zig");
pub const TalkTable = tlk.TalkTable;
pub const TalkTableEntry = tlk.TalkTableEntry;
pub const TalkTableFlags = tlk.Flags;

pub const loc_string = @import("loc_string.zig");
pub const LocStringGender = loc_string.Gender;
pub const LocStringFetchResult = loc_string.FetchResult;

pub const ssf = @import("ssf.zig");
pub const SoundSet = ssf.SoundSet;
pub const SoundEntry = ssf.SoundEntry;
pub const SoundIndex = ssf.SoundIndex;

pub const mdl = @import("mdl.zig");
pub const MdlFile = mdl.MdlFile;
pub const MdlNode = mdl.Node;
pub const MdlNodeType = mdl.NodeType;
pub const MdlAnimation = mdl.Animation;
pub const MdlClassification = mdl.Classification;

pub const store = @import("store.zig");
pub const UtmFile = store.UtmFile;
pub const StoreStruct = store.StoreStruct;
pub const StoreVariant = store.StoreVariant;
pub const StoreContainer = store.StoreContainer;
pub const StoreContainerId = store.StoreContainerId;
pub const StoreItem = store.StoreItem;
pub const StoreBaseItem = store.StoreBaseItem;

pub const jrl = @import("jrl.zig");
pub const JrlFile = jrl.JrlFile;
pub const JournalCategory = jrl.JournalCategory;
pub const JournalEntry = jrl.JournalEntry;

pub const itp = @import("itp.zig");
pub const ItpFile = itp.ItpFile;
pub const PaletteNode = itp.PaletteNode;
pub const BranchNode = itp.BranchNode;
pub const CategoryNode = itp.CategoryNode;
pub const BlueprintNode = itp.BlueprintNode;

pub const encounter = @import("encounter.zig");
pub const UteFile = encounter.UteFile;
pub const EncounterStruct = encounter.EncounterStruct;
pub const EncounterVariant = encounter.EncounterVariant;
pub const EncounterCreature = encounter.EncounterCreature;
pub const GeometryPoint = encounter.GeometryPoint;
pub const SpawnPoint = encounter.SpawnPoint;

pub const waypoint = @import("waypoint.zig");
pub const UtwFile = waypoint.UtwFile;
pub const WaypointStruct = waypoint.WaypointStruct;
pub const WaypointVariant = waypoint.WaypointVariant;

pub const trigger = @import("trigger.zig");
pub const UttFile = trigger.UttFile;
pub const TriggerStruct = trigger.TriggerStruct;
pub const TriggerVariant = trigger.TriggerVariant;
pub const TriggerPoint = trigger.TriggerPoint;

pub const door_placeable = @import("door_placeable.zig");
pub const UtdFile = door_placeable.UtdFile;
pub const DoorStruct = door_placeable.DoorStruct;
pub const UtpFile = door_placeable.UtpFile;
pub const PlaceableStruct = door_placeable.PlaceableStruct;
pub const PlaceableInventoryItem = door_placeable.PlaceableInventoryItem;
pub const SituatedVariant = door_placeable.SituatedVariant;

pub const sound = @import("sound.zig");
pub const UtsFile = sound.UtsFile;
pub const SoundStruct = sound.SoundStruct;
pub const SoundVariant = sound.SoundVariant;
pub const SoundWaveEntry = sound.SoundEntry;

pub const fac = @import("fac.zig");
pub const FacFile = fac.FacFile;
pub const Faction = fac.Faction;
pub const FactionReputation = fac.Reputation;
pub const FactionStanding = fac.Standing;
pub const FACTION_NO_PARENT = fac.NO_PARENT;

pub const ifo = @import("ifo.zig");
pub const IfoFile = ifo.IfoFile;
pub const IfoStruct = ifo.IfoStruct;
pub const IfoVariant = ifo.IfoVariant;
pub const IfoAreaEntry = ifo.AreaEntry;
pub const IfoHakEntry = ifo.HakEntry;
pub const IfoCacheEntry = ifo.CacheEntry;
pub const IfoToken = ifo.Token;
pub const IfoTurdEntry = ifo.TurdEntry;
pub const IfoPersonalRep = ifo.PersonalRep;
pub const IfoMapData = ifo.MapData;

pub const resource_grouping = @import("services/resource_grouping.zig");
pub const ResourceId = resource_grouping.ResourceId;
pub const ResourceOrigin = resource_grouping.Origin;

pub const tga = @import("image_formats/tga.zig");
pub const TgaFile = tga.TgaFile;
pub const TgaHeader = tga.TgaHeader;
pub const TgaImageType = tga.ImageType;
pub const TgaError = tga.TgaError;

pub const dds = @import("image_formats/dds.zig");
pub const DdsFile = dds.DdsFile;
pub const DdsHeader = dds.DdsHeader;
pub const DdsPixelFormat = dds.DdsPixelFormat;
pub const DdsDxt10Header = dds.DdsDxt10Header;
pub const DdsPixelFormatEnum = dds.PixelFormat;
pub const DdsError = dds.DdsError;

pub const tpc = @import("image_formats/tpc.zig");
pub const TpcFile = tpc.TpcFile;
pub const TpcHeader = tpc.TpcHeader;
pub const TpcEncoding = tpc.Encoding;
pub const TpcCompression = tpc.Compression;
pub const TpcError = tpc.TpcError;

const Io = std.Io;
