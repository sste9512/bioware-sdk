const std = @import("std");
const Io = std.Io;

const bioware_sdk = @import("bioware_sdk");
const twoda = bioware_sdk.twoda;
const gff = bioware_sdk.gff;
const BifFile = bioware_sdk.BifFile;
const KeyFile = bioware_sdk.KeyFile;
const ErfFile = bioware_sdk.ErfFile;
const ErfFileType = bioware_sdk.ErfFileType;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    //  var gff_file = try gff.GffFile.init(std.heap.page_allocator);

    //  defer gff_file.deinit();
    //

    //  const result =  try gff_file.parse("data/characters/human_male.gff");

    //  _ = result;
    //
    const kotor_root_path = "/home/steveo/snap/steam/common/.local/share/Steam/steamapps/common/swkotor";
    //const kotor_root_path_fix = "/home/steveo/snap/steam/common/.local/share/Steam/steamapps/common/swkotor/";
    const kotor_data_path = try std.fs.path.join(std.heap.page_allocator, &.{ kotor_root_path, "/data" });
    defer std.heap.page_allocator.free(kotor_data_path);

    const key_path = try std.fs.path.join(std.heap.page_allocator, &.{ kotor_root_path, "/chitin.key" });
    defer std.heap.page_allocator.free(key_path);

    var keyfile = KeyFile.init(std.heap.page_allocator);
    defer keyfile.deinit();

    const keyBytes = try readFileBytes(std.heap.page_allocator, key_path, io);
    try keyfile.parse(keyBytes);

    keyfile.dumpInfo();

    var bif_file_from_entry = try keyfile.bif_entries.items[2].bifFromEntry(kotor_root_path, io);
    var bif_2 = try keyfile.bif_entries.items[3].bifFromEntry(kotor_root_path, io);
    defer bif_file_from_entry.deinit();
    defer bif_2.deinit();

    const erf_path = try std.fs.path.join(std.heap.page_allocator, &.{ kotor_root_path, "/TexturePacks/swpc_tex_gui.erf" });
    defer std.heap.page_allocator.free(erf_path);

    const erfBytes = try readFileBytes(std.heap.page_allocator, erf_path, io);
    defer std.heap.page_allocator.free(erfBytes);

    var erf = ErfFile.init(std.heap.page_allocator, .ERF);
    defer erf.deinit();

    try erf.parse(erfBytes);

    erf.dumpInfo();

    var stdout_buf1: [4096]u8 = undefined;
    var stdout1 = std.Io.File.stdout().writer(io, &stdout_buf1);
    try bif_file_from_entry.dumpResourceTable(&stdout1.interface);
    try bif_2.dumpResourceTable(&stdout1.interface);

    try stdout1.interface.flush();
}

fn readFileBytes(allocator: std.mem.Allocator, path: []const u8, io: std.Io) ![]u8 {
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .unlimited);

    // const buffer = try allocator.alloc(u8, size);
    // errdefer allocator.free(buffer);

    // const bytes_read = try file.readPositionalAll(io, buffer, 0);
    // if (bytes_read != size) {
    //     return error.UnexpectedEndOfFile;
    // }

    // return buffer;
}
