# bioware-sdk

Zig library for reading and writing file formats used by BioWare's Aurora / Odyssey engine games (Neverwinter Nights, KOTOR, Jade Empire).

## Status

Work in progress. See `src/root.zig` for the current public API surface.

## Supported File Types

### Archive / Container Formats

| Extension(s)      | Module                    | Description                                                             |
| ------------------ | -------------------------- | ------------------------------------------------------------------------ |
| `.key` / `.bif`    | `src/keybif.zig`          | KEY index + BIF archive pair; maps resource names to raw resource data. |
| `.erf` `.hak` `.mod` `.nwm` `.sav` | `src/erf.zig`  | Encapsulated Resource File — packs multiple resources into one archive. |
| `.rim`             | `src/rim.zig`              | RIM resource archive (used for module/area packaging).                  |

### Generic File Format (GFF) and GFF-based Resources

GFF is a generic label/type-tagged tree container (`src/gff.zig`) used as the backing format for most game object and world data files below.

| Extension | Module                     | Description                                                       |
| --------- | -------------------------- | ------------------------------------------------------------------- |
| `.2da`    | `src/twoda.zig`            | 2-Dimensional Array — plain-text tabular rules/data file.          |
| `.are`, `.git`, `.gic` | `src/area.zig`  | Area static data (ARE), area instance list (GIT), area comments (GIC). |
| `.uti`    | `src/item.zig`             | Item blueprints + Item structs embedded in GIT/inventories.        |
| `.utc`    | `src/creature.zig`         | Creature blueprints + Creature structs (GIT/savegame/BIC).         |
| `.utd`    | `src/door_placeable.zig`   | Door blueprints + Door structs.                                    |
| `.utp`    | `src/door_placeable.zig`   | Placeable object blueprints + Placeable structs.                   |
| `.ute`    | `src/encounter.zig`        | Encounter blueprints + Encounter structs.                          |
| `.utt`    | `src/trigger.zig`          | Trigger blueprints + Trigger structs.                              |
| `.uts`    | `src/sound.zig`            | Sound object blueprints + Sound structs.                           |
| `.utw`    | `src/waypoint.zig`         | Waypoint blueprints + Waypoint structs.                            |
| `.utm`    | `src/store.zig`            | Store (merchant) blueprints + Store structs.                       |
| `.fac`    | `src/fac.zig`              | Faction list and faction-to-faction reputation table.              |
| `.jrl`    | `src/jrl.zig`              | Journal/quest categories and entries.                              |
| `.itp`    | `src/itp.zig`              | Toolset palette tree (categories/blueprints).                      |
| `.ifo`    | `src/ifo.zig`              | Module information (`module.ifo`), embedded in ERF/SAV archives.   |
| n/a       | `src/common_gff.zig`       | Shared GFF sub-structures (Location, VarTable, EffectsList, EventQueue, ActionList, ScriptSituation) embedded in other GFF resources. |

### Localization / Text

| Extension | Module               | Description                                                    |
| --------- | -------------------- | ---------------------------------------------------------------- |
| `.tlk`    | `src/tlk.zig`        | Talk table — global string reference table (dialog.tlk).       |
| n/a       | `src/loc_string.zig` | CExoLocString fetch logic (language/gender fallback resolution). |

### Audio

| Extension | Module        | Description                                                        |
| --------- | -------------- | --------------------------------------------------------------------- |
| `.ssf`    | `src/ssf.zig` | Sound Set File — maps creature vocal/combat actions to sounds + TLK entries. |

### 3D / World Geometry

| Extension | Module        | Description                                                              |
| --------- | -------------- | --------------------------------------------------------------------------- |
| `.mdl`    | `src/mdl.zig` | Model — node hierarchy (geometry, lights, emitters, collision) + animations. |
| `.wok`    | `src/wok.zig` | Walkmesh — walkable/collision surface mesh (BWM format).                    |

### Image Formats

| Extension | Module                        | Description                                             |
| --------- | ------------------------------ | ---------------------------------------------------------- |
| `.tga`    | `src/image_formats/tga.zig`   | Truevision TGA image.                                    |
| `.dds`    | `src/image_formats/dds.zig`   | DirectDraw Surface image (incl. DXT/BC compressed).      |
| `.tpc`    | `src/image_formats/tpc.zig`   | BioWare TPC texture (uncompressed or DXT1/DXT5 compressed). |

## Project Layout

- `src/root.zig` — public API re-exports.
- `src/main.zig` — sample/dev entry point exercising the library against a game install.
- `src/capabilities/` — capability interfaces (identification, loading, image conversion) — in progress.
- `src/services/` — higher-level services (resource grouping, resource mod system) — in progress.

## Building

```sh
zig build
```

Requires Zig `0.16.0` or newer (see `build.zig.zon`).
