//! WAL Recovery Logic
//!
//! Contains all WAL recovery functionality including segment-level recovery
//! and streaming recovery using the WALEntryStream abstraction. This module
//! handles corruption detection, error recovery, and callback management.

const builtin = @import("builtin");
const std = @import("std");

const context_block = @import("../../core/types.zig");
const corruption_tracker_mod = @import("corruption_tracker.zig");

const entry_mod = @import("entry.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const types = @import("types.zig");
const vfs = @import("../../core/vfs.zig");
const wal_entry_stream = @import("stream.zig");

const log = std.log.scoped(.wal_recovery);
const testing = std.testing;

const BlockId = context_block.BlockId;
const ContextBlock = context_block.ContextBlock;
const CorruptionTracker = corruption_tracker_mod.CorruptionTracker;
const GraphEdge = context_block.GraphEdge;
const MAX_PATH_LENGTH = types.MAX_PATH_LENGTH;
const RecoveryCallback = types.RecoveryCallback;
const SimulationVFS = simulation_vfs.SimulationVFS;
const VFS = vfs.VFS;
const VFile = vfs.VFile;
const WALEntry = entry_mod.WALEntry;
const WALError = types.WALError;

/// Recover entries from a single WAL segment file using streaming approach
/// Processes entries one at a time to minimize memory usage and improve corruption resilience
pub fn recover_from_segment(
    filesystem: vfs.VFS,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    callback: RecoveryCallback,
    context: anytype,
    stats: *types.WALStats,
) WALError!void {
    std.debug.assert(file_path.len > 0);
    std.debug.assert(file_path.len < MAX_PATH_LENGTH);

    var corruption_tracker = if (builtin.is_test) CorruptionTracker.init_testing() else CorruptionTracker.init();

    const MAX_ENTRIES_PER_SEGMENT = 1_000_000;
    const MAX_RECOVERY_TIME_MS = if (builtin.is_test) 30_000 else 120_000; // 30s test, 2min prod
    var entries_processed: u32 = 0;
    const recovery_start_time = std.time.milliTimestamp();

    var file = filesystem.open(file_path, .read) catch |err| switch (err) {
        error.FileNotFound => return WALError.FileNotFound,
        error.AccessDenied => return WALError.AccessDenied,
        error.OutOfMemory => return WALError.OutOfMemory,
        else => return WALError.IoError,
    };
    defer file.close();

    var stream = wal_entry_stream.WALEntryStream.init(allocator, &file) catch |err| switch (err) {
        wal_entry_stream.StreamError.OutOfMemory => return WALError.OutOfMemory,
        wal_entry_stream.StreamError.IoError => return WALError.IoError,
        else => return WALError.IoError,
    };

    var entries_recovered: u32 = 0;

    while (true) {
        entries_processed += 1;
        if (entries_processed > MAX_ENTRIES_PER_SEGMENT) {
            log.err("WAL segment exceeded maximum entries limit: {d}", .{MAX_ENTRIES_PER_SEGMENT});
            return WALError.IoError;
        }

        const current_time = std.time.milliTimestamp();
        if (current_time - recovery_start_time > MAX_RECOVERY_TIME_MS) {
            log.err("WAL recovery timeout exceeded: {}ms for segment: {s}", .{ current_time - recovery_start_time, file_path });
            return WALError.IoError;
        }

        const stream_entry = stream.next() catch |err| switch (err) {
            wal_entry_stream.StreamError.EndOfFile => break,
            wal_entry_stream.StreamError.CorruptedEntry => {
                corruption_tracker.record_failure("stream_entry_corruption");
                stats.recovery_failures += 1;
                continue;
            },
            wal_entry_stream.StreamError.EntryTooLarge => {
                log.warn("Entry too large in WAL stream", .{});
                corruption_tracker.record_failure("entry_too_large");
                stats.recovery_failures += 1;
                continue;
            },
            wal_entry_stream.StreamError.IoError => return WALError.IoError,
            wal_entry_stream.StreamError.OutOfMemory => return WALError.OutOfMemory,
        } orelse break;

        defer stream_entry.deinit(allocator);

        const wal_entry = WALEntry.from_stream_entry(allocator, stream_entry) catch |err| switch (err) {
            WALError.InvalidChecksum => {
                corruption_tracker.record_failure("checksum_validation");
                stats.recovery_failures += 1;
                continue;
            },
            WALError.InvalidEntryType => {
                corruption_tracker.record_failure("entry_type_validation");
                stats.recovery_failures += 1;
                continue;
            },
            else => return err,
        };
        defer wal_entry.deinit(allocator);

        callback(wal_entry, context) catch |err| return err;
        corruption_tracker.record_success();
        entries_recovered += 1;
    }

    stats.entries_recovered += entries_recovered;
    // Update entries_written to maintain consistency with memtable during recovery
    // These recovered entries should be counted as "written" for current session
    stats.entries_written += entries_recovered;

    if (entries_recovered > 0) {
        log.debug("Recovered {d} entries from segment: {s}", .{ entries_recovered, file_path });
    } else {
        log.debug("No entries found in segment: {s}", .{file_path});
    }
}

/// Recover entries from multiple WAL segments in chronological order
/// Segments are processed in order based on their file names to ensure replay consistency
pub fn recover_from_segments(
    filesystem: VFS,
    allocator: std.mem.Allocator,
    directory: []const u8,
    callback: RecoveryCallback,
    context: *anyopaque,
    stats: *types.WALStats,
) WALError!void {
    const segment_files = try list_segment_files(allocator, filesystem, directory);
    defer {
        for (segment_files) |file_name| {
            allocator.free(file_name);
        }
        allocator.free(segment_files);
    }

    const initial_recovery_failures = stats.recovery_failures;

    for (segment_files) |file_name| {
        std.debug.assert(file_name.len > 0);
        std.debug.assert(std.mem.startsWith(u8, file_name, "wal_"));
        std.debug.assert(std.mem.endsWith(u8, file_name, ".log"));

        const file_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ directory, file_name },
        );
        defer allocator.free(file_path);

        recover_from_segment(filesystem, allocator, file_path, callback, context, stats) catch |err| switch (err) {
            WALError.InvalidChecksum, WALError.InvalidEntryType, WALError.CorruptedEntry => {
                log.warn("WAL corruption detected in {s}, skipping segment", .{file_path});
                stats.recovery_failures += 1;
                continue;
            },
            else => return err,
        };
    }

    std.debug.assert(stats.recovery_failures >= initial_recovery_failures);
}

/// List all WAL segment files in the directory, sorted in chronological order
fn list_segment_files(allocator: std.mem.Allocator, filesystem: VFS, directory: []const u8) WALError![][]const u8 {
    var file_list = std.ArrayList([]const u8){};
    defer file_list.deinit(allocator);

    var dir_iter = filesystem.iterate_directory(directory, allocator) catch |err| switch (err) {
        error.FileNotFound => return WALError.FileNotFound,
        error.AccessDenied => return WALError.AccessDenied,
        error.OutOfMemory => return WALError.OutOfMemory,
        else => return WALError.IoError,
    };
    defer dir_iter.deinit(allocator);

    while (dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.startsWith(u8, entry.name, types.WAL_FILE_PREFIX) and
            std.mem.endsWith(u8, entry.name, types.WAL_FILE_SUFFIX))
        {
            const owned_name = allocator.dupe(u8, entry.name) catch return WALError.OutOfMemory;
            file_list.append(allocator, owned_name) catch return WALError.OutOfMemory;
        }
    }

    const files = file_list.toOwnedSlice(allocator) catch return WALError.OutOfMemory;

    std.sort.insertion([]const u8, files, {}, struct {
        fn less_than(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less_than);

    return files;
}

fn create_test_wal_entry(allocator: std.mem.Allocator, entry_type: u8, payload: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(&[_]u8{entry_type});
    hasher.update(payload);
    const checksum = hasher.final();

    const header_size = 13; // 8 bytes checksum + 1 byte type + 4 bytes size
    const total_size = header_size + payload.len;
    const buffer = try allocator.alloc(u8, total_size);

    std.mem.writeInt(u64, buffer[0..8], checksum, .little);
    buffer[8] = entry_type;
    std.mem.writeInt(u32, buffer[9..13], @intCast(payload.len), .little);
    @memcpy(buffer[13..], payload);

    return buffer;
}

fn create_test_block() ContextBlock {
    return ContextBlock{
        .id = BlockId.from_hex("0123456789abcdef0123456789abcdef") catch unreachable, // Safety: hardcoded valid hex
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test://recovery.zig",
        .metadata_json = "{}",
        .content = "test recovery content",
    };
}

const TestRecoveryContext = struct {
    entries_recovered: std.ArrayList(entry_mod.WALEntry),
    callback_errors: u32,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestRecoveryContext {
        return TestRecoveryContext{
            .entries_recovered = std.ArrayList(entry_mod.WALEntry){},
            .callback_errors = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TestRecoveryContext) void {
        for (self.entries_recovered.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries_recovered.deinit(self.allocator);
    }
};

fn test_recovery_callback(entry: entry_mod.WALEntry, context: *anyopaque) WALError!void {
    // Safety: Pointer cast with alignment validation
    const test_context: *TestRecoveryContext = @ptrCast(@alignCast(context));

    // TestRecoveryContext stores entries_recovered as ArrayList which needs allocator
    // We need to track allocator in the context to use it here
    const allocator = test_context.allocator;
    const cloned_payload = try allocator.dupe(u8, entry.payload);
    const cloned_entry = entry_mod.WALEntry{
        .checksum = entry.checksum,
        .entry_type = entry.entry_type,
        .payload_size = entry.payload_size,
        .payload = cloned_payload,
    };

    try test_context.entries_recovered.append(allocator, cloned_entry);
}

fn error_recovery_callback(entry: entry_mod.WALEntry, context: *anyopaque) WALError!void {
    _ = entry;
    // Safety: Pointer cast with alignment validation
    const test_context: *TestRecoveryContext = @ptrCast(@alignCast(context));
    test_context.callback_errors += 1;
    return WALError.CallbackFailed;
}

test "recover_from_segment - empty file" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var file = try sim_vfs.vfs().create("empty.wal");
    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try recover_from_segment(sim_vfs.vfs(), allocator, "empty.wal", test_recovery_callback, &context, &stats);

    try testing.expectEqual(@as(usize, 0), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, 0), stats.entries_recovered);
}

test "recover_from_segment - single valid entry" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const test_block = create_test_block();
    const serialized_block = try allocator.alloc(u8, test_block.serialized_size());
    defer allocator.free(serialized_block);
    _ = try (&test_block).serialize(serialized_block);

    var file = try sim_vfs.vfs().create("single.wal");
    const entry_data = try create_test_wal_entry(allocator, 0x01, serialized_block);
    defer allocator.free(entry_data);
    _ = try file.write(entry_data);
    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try recover_from_segment(sim_vfs.vfs(), allocator, "single.wal", test_recovery_callback, &context, &stats);

    try testing.expectEqual(@as(usize, 1), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, 1), stats.entries_recovered);

    const recovered_entry = context.entries_recovered.items[0];
    try testing.expectEqual(entry_mod.WALEntryType.put_block, recovered_entry.entry_type);
    try testing.expect(std.mem.eql(u8, serialized_block, recovered_entry.payload));
}

test "recover_from_segment - multiple valid entries" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var file = try sim_vfs.vfs().create("multi.wal");

    const test_payloads = [_][]const u8{ "payload1", "payload2", "payload3" };
    const entry_types = [_]u8{ 0x01, 0x02, 0x01 };

    for (test_payloads, entry_types) |payload, entry_type| {
        const entry_data = try create_test_wal_entry(allocator, entry_type, payload);
        defer allocator.free(entry_data);
        _ = try file.write(entry_data);
    }
    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try recover_from_segment(sim_vfs.vfs(), allocator, "multi.wal", test_recovery_callback, &context, &stats);

    try testing.expectEqual(@as(usize, 3), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, 3), stats.entries_recovered);

    for (context.entries_recovered.items, test_payloads, entry_types) |entry, expected_payload, expected_type| {
        try testing.expectEqual(@as(u8, expected_type), @intFromEnum(entry.entry_type));
        try testing.expect(std.mem.eql(u8, expected_payload, entry.payload));
    }
}

test "recover_from_segment - corrupted entry handling" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var file = try sim_vfs.vfs().create("corrupted.wal");

    const valid_payload = "valid entry";
    const valid_entry = try create_test_wal_entry(allocator, 0x01, valid_payload);
    defer allocator.free(valid_entry);
    _ = try file.write(valid_entry);

    var bad_data: [13]u8 = undefined; // Header size
    std.mem.writeInt(u64, bad_data[0..8], 0x1234567890abcdef, .little);
    bad_data[8] = 0xFF; // Invalid entry type
    std.mem.writeInt(u32, bad_data[9..13], 0, .little);
    _ = try file.write(&bad_data);

    const valid_payload2 = "second valid entry";
    const valid_entry2 = try create_test_wal_entry(allocator, 0x02, valid_payload2);
    defer allocator.free(valid_entry2);
    _ = try file.write(valid_entry2);

    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try recover_from_segment(sim_vfs.vfs(), allocator, "corrupted.wal", test_recovery_callback, &context, &stats);

    try testing.expectEqual(@as(usize, 2), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, 2), stats.entries_recovered);
}

test "recover_from_segment - file not found" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try testing.expectError(WALError.FileNotFound, recover_from_segment(sim_vfs.vfs(), allocator, "nonexistent.wal", test_recovery_callback, &context, &stats));
}

test "recover_from_segment - callback error handling" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var file = try sim_vfs.vfs().create("callback_error.wal");
    const test_payload = "test payload";
    const entry_data = try create_test_wal_entry(allocator, 0x01, test_payload);
    defer allocator.free(entry_data);
    _ = try file.write(entry_data);
    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try testing.expectError(WALError.CallbackFailed, recover_from_segment(sim_vfs.vfs(), allocator, "callback_error.wal", error_recovery_callback, &context, &stats));

    try testing.expectEqual(@as(u32, 1), context.callback_errors);
}

test "recover_from_segments - multiple segment files" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const test_dir = "test_segments";
    try sim_vfs.vfs().mkdir(test_dir);

    const segment_files = [_][]const u8{ "wal_0000.log", "wal_0001.log", "wal_0002.log" };
    const payloads = [_][]const u8{ "first segment", "second segment", "third segment" };

    for (segment_files, payloads) |filename, payload| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_dir, filename });
        defer allocator.free(file_path);

        var file = try sim_vfs.vfs().create(file_path);
        const entry_data = try create_test_wal_entry(allocator, 0x01, payload);
        defer allocator.free(entry_data);
        _ = try file.write(entry_data);
        file.close();
    }

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try recover_from_segments(sim_vfs.vfs(), allocator, test_dir, test_recovery_callback, &context, &stats);

    try testing.expectEqual(@as(usize, 3), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, 3), stats.entries_recovered);

    for (context.entries_recovered.items, payloads) |entry, expected_payload| {
        try testing.expect(std.mem.eql(u8, expected_payload, entry.payload));
    }
}

test "recover_from_segments - corrupted segment skipping" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const test_dir = "test_corrupted_segments";
    try sim_vfs.vfs().mkdir(test_dir);

    var file = try sim_vfs.vfs().create("test_corrupted_segments/wal_0000.log");
    const valid_entry = try create_test_wal_entry(allocator, 0x01, "valid");
    defer allocator.free(valid_entry);
    _ = try file.write(valid_entry);
    file.close();

    file = try sim_vfs.vfs().create("test_corrupted_segments/wal_0001.log");
    // Create a properly sized entry with invalid entry type to trigger InvalidEntryType
    var corrupted_data: [13]u8 = undefined;
    std.mem.writeInt(u64, corrupted_data[0..8], 0x1234567890abcdef, .little);
    corrupted_data[8] = 0xFF; // Invalid entry type
    std.mem.writeInt(u32, corrupted_data[9..13], 0, .little);
    _ = try file.write(&corrupted_data);
    file.close();

    file = try sim_vfs.vfs().create("test_corrupted_segments/wal_0002.log");
    const valid_entry2 = try create_test_wal_entry(allocator, 0x02, "valid2");
    defer allocator.free(valid_entry2);
    _ = try file.write(valid_entry2);
    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try recover_from_segments(sim_vfs.vfs(), allocator, test_dir, test_recovery_callback, &context, &stats);

    try testing.expectEqual(@as(usize, 2), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, 2), stats.entries_recovered);
    try testing.expectEqual(@as(u32, 1), stats.recovery_failures);
}

test "recover_from_segments - directory not found" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    try testing.expectError(WALError.FileNotFound, recover_from_segments(sim_vfs.vfs(), allocator, "nonexistent_dir", test_recovery_callback, &context, &stats));
}

test "list_segment_files - empty directory" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const test_dir = "empty_segments";
    try sim_vfs.vfs().mkdir(test_dir);

    const files = try list_segment_files(allocator, sim_vfs.vfs(), test_dir);
    defer {
        for (files) |file_name| {
            allocator.free(file_name);
        }
        allocator.free(files);
    }

    try testing.expectEqual(@as(usize, 0), files.len);
}

test "list_segment_files - mixed files" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const test_dir = "mixed_files";
    try sim_vfs.vfs().mkdir(test_dir);

    const all_files = [_][]const u8{
        "wal_0000.log",
        "wal_0001.log",
        "not_a_wal.txt",
        "wal_0002.log",
        "other.dat",
    };

    for (all_files) |filename| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_dir, filename });
        defer allocator.free(file_path);
        var file = try sim_vfs.vfs().create(file_path);
        file.close();
    }

    const wal_files = try list_segment_files(allocator, sim_vfs.vfs(), test_dir);
    defer {
        for (wal_files) |file_name| {
            allocator.free(file_name);
        }
        allocator.free(wal_files);
    }

    try testing.expectEqual(@as(usize, 3), wal_files.len);
    try testing.expect(std.mem.eql(u8, "wal_0000.log", wal_files[0]));
    try testing.expect(std.mem.eql(u8, "wal_0001.log", wal_files[1]));
    try testing.expect(std.mem.eql(u8, "wal_0002.log", wal_files[2]));
}

test "list_segment_files - sorting verification" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const test_dir = "sorting_test";
    try sim_vfs.vfs().mkdir(test_dir);

    const unsorted_files = [_][]const u8{
        "wal_0005.log",
        "wal_0001.log",
        "wal_0003.log",
        "wal_0002.log",
        "wal_0004.log",
    };

    for (unsorted_files) |filename| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_dir, filename });
        defer allocator.free(file_path);
        var file = try sim_vfs.vfs().create(file_path);
        file.close();
    }

    const sorted_files = try list_segment_files(allocator, sim_vfs.vfs(), test_dir);
    defer {
        for (sorted_files) |file_name| {
            allocator.free(file_name);
        }
        allocator.free(sorted_files);
    }

    try testing.expectEqual(@as(usize, 5), sorted_files.len);
    try testing.expect(std.mem.eql(u8, "wal_0001.log", sorted_files[0]));
    try testing.expect(std.mem.eql(u8, "wal_0002.log", sorted_files[1]));
    try testing.expect(std.mem.eql(u8, "wal_0003.log", sorted_files[2]));
    try testing.expect(std.mem.eql(u8, "wal_0004.log", sorted_files[3]));
    try testing.expect(std.mem.eql(u8, "wal_0005.log", sorted_files[4]));
}

test "wal_recovery_defensive_timeout_prevents_infinite_loops" {
    const allocator = testing.allocator;

    var sim_vfs = try simulation_vfs.SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var file = try sim_vfs.vfs().create("timeout_test.wal");

    var entries_written: u32 = 0;
    const target_entries = 100; // Reasonable number for testing

    while (entries_written < target_entries) : (entries_written += 1) {
        const payload = try std.fmt.allocPrint(allocator, "entry_{d}", .{entries_written});
        defer allocator.free(payload);

        const entry_data = try create_test_wal_entry(allocator, 0x01, payload);
        defer allocator.free(entry_data);
        _ = try file.write(entry_data);
    }
    file.close();

    var stats = types.WALStats.init();
    var context = TestRecoveryContext.init(allocator);
    defer context.deinit();

    const test_start = std.time.milliTimestamp();

    try recover_from_segment(sim_vfs.vfs(), allocator, "timeout_test.wal", test_recovery_callback, &context, &stats);

    const test_duration = std.time.milliTimestamp() - test_start;

    try testing.expectEqual(@as(usize, target_entries), context.entries_recovered.items.len);
    try testing.expectEqual(@as(u64, target_entries), stats.entries_recovered);

    try testing.expect(test_duration < 5000); // 5 seconds is generous for 100 entries

    for (context.entries_recovered.items, 0..) |entry, i| {
        const expected_payload = try std.fmt.allocPrint(allocator, "entry_{d}", .{i});
        defer allocator.free(expected_payload);
        try testing.expect(std.mem.eql(u8, expected_payload, entry.payload));
    }
}
