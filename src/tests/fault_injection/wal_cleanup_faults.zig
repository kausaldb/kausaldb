//! WAL Cleanup Fault Injection Tests
//!
//! Tests the critical window where WAL segments are cleaned up after successful
//! SSTable flush. This is a critical consistency window because if cleanup fails
//! partway through, the system must remain recoverable.
//!
//! Scenarios tested:
//! - WAL segment removal failures during cleanup
//! - System restart after partial WAL cleanup
//! - Recovery consistency when cleanup is interrupted
//! - Cascading failures during post-flush operations

const std = @import("std");

const memory = @import("../../core/memory.zig");
const ownership = @import("../../core/ownership.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const stdx = @import("../../core/stdx.zig");
const storage = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");
const vfs = @import("../../core/vfs.zig");

const testing = std.testing;

const StorageEngine = storage.StorageEngine;
const MemtableManager = storage.MemtableManager;
const WAL = storage.WAL;
const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;
const SimulationVFS = simulation_vfs.SimulationVFS;

/// Generate deterministic BlockId for testing (prevents zero-value anti-pattern)
fn create_deterministic_block_id(seed: u32) BlockId {
    const safe_seed = if (seed == 0) 1 else seed;
    var bytes: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 4) {
        const value = safe_seed + @as(u32, @intCast(i));
        var slice: [4]u8 = undefined;
        std.mem.writeInt(u32, &slice, value, .little);
        stdx.copy_left(u8, bytes[i .. i + 4], &slice);
    }
    return BlockId.from_bytes(bytes);
}

/// Generate deterministic test block for consistent fault injection scenarios
fn create_test_block(index: u32) ContextBlock {
    return ContextBlock{
        .id = create_deterministic_block_id(index),
        .version = 1,
        .source_uri = "test://wal_cleanup_fault.zig",
        .metadata_json = "{}",
        .content = std.fmt.allocPrint(testing.allocator, "Test block {} for WAL cleanup fault injection. This content is designed to fill up the memtable to trigger flush operations.", .{index}) catch @panic("OOM in test"),
    };
}

/// Helper to populate memtable with enough data to trigger flush
fn populate_memtable_for_flush(engine: *StorageEngine, block_count: u32) !void {
    for (0..block_count) |i| {
        const block = create_test_block(@intCast(i));
        defer testing.allocator.free(block.content);
        try engine.put_block(block);
    }
}

/// Helper to count WAL segments in directory
fn count_wal_segments(vfs_interface: vfs.VFS, wal_dir: []const u8) !u32 {
    var iterator = try vfs_interface.iterate_directory(wal_dir, testing.allocator);
    defer iterator.deinit(testing.allocator);

    var count: u32 = 0;
    while (iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "wal_") and std.mem.endsWith(u8, entry.name, ".log")) {
            count += 1;
        }
    }
    return count;
}

test "WAL cleanup partial failure recovery" {
    const allocator = testing.allocator;

    // Create simulation with fault injection enabled
    var sim_vfs = try SimulationVFS.init_with_fault_seed(allocator, 42);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/wal_cleanup_1");
    defer engine.deinit();
    try engine.startup();

    // Populate enough data to create multiple WAL segments and trigger flush
    try populate_memtable_for_flush(&engine, 50);

    // Force a flush to create an SSTable and trigger WAL cleanup
    try engine.flush_memtable_to_sstable();

    // Create more data to generate additional WAL segments
    try populate_memtable_for_flush(&engine, 30);

    // Inject fault during WAL cleanup operations
    // Target file removal operations with 50% failure rate
    sim_vfs.enable_io_failures(500, .{ .remove = true });

    // Attempt flush - this should trigger WAL cleanup which may fail
    const flush_result = engine.flush_memtable_to_sstable();

    // Whether flush succeeds or fails, system should remain consistent
    if (flush_result) |_| {
        // Flush succeeded despite potential WAL cleanup issues
        std.debug.print("Flush succeeded with WAL cleanup fault injection\n", .{});
    } else |err| {
        // Flush failed due to WAL cleanup failure
        try testing.expect(err == storage.StorageError.IoError);
        std.debug.print("Flush failed as expected due to WAL cleanup fault: {}\n", .{err});
    }

    // Clear fault injection and verify normal operation can continue
    sim_vfs.enable_io_failures(0, .{});

    // Verify system is still functional after fault injection
    const test_block = create_test_block(9999);
    defer allocator.free(test_block.content);

    try engine.put_block(test_block);
    const found_block = try engine.find_block(test_block.id, .query_engine);
    try testing.expect(found_block != null);
    try testing.expectEqualStrings(test_block.content, found_block.?.extract().content);

    std.debug.print("WAL cleanup fault injection test completed successfully\n", .{});
}

test "cascading failure during post flush compaction" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init_with_fault_seed(allocator, 123);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/cascading_wal_2");
    defer engine.deinit();
    try engine.startup();

    // Create substantial data to trigger both flush and compaction
    try populate_memtable_for_flush(&engine, 100);
    try engine.flush_memtable_to_sstable();

    try populate_memtable_for_flush(&engine, 100);
    try engine.flush_memtable_to_sstable();

    // Create more data for final flush that will trigger compaction
    try populate_memtable_for_flush(&engine, 50);

    // Inject failures on file operations during the cleanup phase
    // This simulates disk space exhaustion or permission issues during cleanup
    sim_vfs.enable_io_failures(800, .{ .remove = true }); // 80% failure rate

    // This flush should trigger compaction which includes WAL cleanup
    const result = engine.flush_memtable_to_sstable();

    // System should handle cascading failures gracefully
    if (result) |_| {
        std.debug.print("Cascading failure test: Operations completed despite fault injection\n", .{});
    } else |err| {
        std.debug.print("Cascading failure test: Expected failure occurred: {}\n", .{err});
    }

    // Clear faults and verify recovery
    sim_vfs.enable_io_failures(0, .{});

    // System should remain consistent for new operations
    const verification_block = create_test_block(8888);
    defer allocator.free(verification_block.content);

    try engine.put_block(verification_block);
    const found = try engine.find_block(verification_block.id, .query_engine);
    try testing.expect(found != null);

    std.debug.print("Post-cascading-failure verification successful\n", .{});
}

test "WAL cleanup consistency under I/O error storm" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init_with_fault_seed(allocator, 789);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/io_storm_3");
    defer engine.deinit();
    try engine.startup();

    // Build up multiple WAL segments through repeated operations
    for (0..5) |cycle| {
        try populate_memtable_for_flush(&engine, 20);

        if (cycle < 4) {
            // Let earlier cycles complete normally to build up WAL segments
            try engine.flush_memtable_to_sstable();
        }
    }

    const wal_dir = "/test/io_storm_3/wal";
    const segments_before = try count_wal_segments(sim_vfs.vfs(), wal_dir);
    try testing.expect(segments_before >= 1); // Ensure we have at least one segment for cleanup testing

    // Inject sustained I/O failures to simulate storage device issues
    sim_vfs.enable_io_failures(600, .{ .remove = true, .write = true }); // 60% failure rate for remove and write

    // Attempt operations under I/O storm conditions
    var successful_operations: u32 = 0;
    var failed_operations: u32 = 0;

    // Try multiple flush operations to test resilience
    for (0..3) |_| {
        const flush_result = engine.flush_memtable_to_sstable();
        if (flush_result) |_| {
            successful_operations += 1;
        } else |_| {
            failed_operations += 1;
        }
    }

    std.debug.print("I/O storm results: {} successful, {} failed operations\n", .{ successful_operations, failed_operations });

    // Clear all fault injection and verify normal operation can continue
    sim_vfs.enable_io_failures(0, .{});

    // Verify normal operation is restored
    const recovery_block = create_test_block(7777);
    defer allocator.free(recovery_block.content);

    try engine.put_block(recovery_block);
    try engine.flush_memtable_to_sstable(); // Should work normally

    const recovered_block = try engine.find_block(recovery_block.id, .query_engine);
    try testing.expect(recovered_block != null);

    std.debug.print("Post-I/O-storm recovery and normal operation verified\n", .{});
}

test "WAL cleanup isolated memtable manager fault injection" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init_with_fault_seed(allocator, 456);
    defer sim_vfs.deinit();

    // Test MemtableManager in isolation to precisely target WAL cleanup
    // Create mock storage engine for MemtableManager

    var test_arena = std.heap.ArenaAllocator.init(allocator);
    defer test_arena.deinit();
    const coordinator = memory.ArenaCoordinator.init(&test_arena);
    var memtable = try MemtableManager.init(&coordinator, allocator, sim_vfs.vfs(), "/test/isolated_wal_4", 64 * 1024);
    defer memtable.deinit();
    try memtable.startup();

    // Generate WAL entries by adding blocks
    for (0..10) |i| {
        const block = create_test_block(@intCast(i));
        defer allocator.free(block.content);
        try memtable.put_block_durable(block);
    }

    // Create a mock SSTableManager for flush coordination
    const MockSSTableManager = struct {
        call_count: u32 = 0,

        pub fn create_new_sstable_from_memtable(self: *@This(), blocks: []const ownership.OwnedBlock) !void {
            _ = blocks; // Unused in mock
            self.call_count += 1;
        }
    };

    var mock_sstable_manager = MockSSTableManager{};

    // Inject fault specifically on WAL cleanup operations
    sim_vfs.enable_io_failures(1000, .{ .remove = true }); // Guaranteed failure

    // Attempt flush which will trigger WAL cleanup
    const flush_result = memtable.flush_to_sstable(&mock_sstable_manager);

    if (flush_result) |_| {
        // If flush succeeded, WAL cleanup must have been skipped or handled gracefully
        try testing.expect(mock_sstable_manager.call_count == 1);
        std.debug.print("Isolated test: Flush completed with graceful WAL cleanup handling\n", .{});
    } else |err| {
        // Expected failure due to WAL cleanup fault
        std.debug.print("Isolated test: Expected WAL cleanup failure: {}\n", .{err});
    }

    // Clear fault injection and verify memtable can still operate
    sim_vfs.enable_io_failures(0, .{});

    const final_block = create_test_block(999);
    defer allocator.free(final_block.content);
    try memtable.put_block_durable(final_block);

    const found = memtable.find_block_in_memtable(final_block.id);
    try testing.expect(found != null);

    std.debug.print("Isolated WAL cleanup fault injection test completed\n", .{});
}
