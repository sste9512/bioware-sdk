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

const Io = std.Io;
