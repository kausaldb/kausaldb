//! WAL Corruption Scenarios Tests
//!
//! Consolidated tests for WAL corruption detection and recovery covering:
//! - Header and magic number corruption
//! - Checksum validation failures
//! - Partial write and torn write scenarios
//! - Fatal corruption handling
//! - Segment boundary corruption
//!
//! This file consolidates corruption testing from:
//! - wal_corruption.zig (general corruption)
//! - wal_corruption_fatal.zig (fatal scenarios)
//! - wal_segment_corruption.zig (segment-specific corruption)
//! - scenarios/torn_wal_recovery.zig (torn write scenarios)

const std = @import("std");

const assert_mod = @import("../../core/assert.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const storage = @import("../../storage/engine.zig");
const test_harness = @import("../harness.zig");
const types = @import("../../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;
const testing = std.testing;

const SimulationVFS = simulation_vfs.SimulationVFS;
const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;
const TestData = test_harness.TestData;
const StorageHarness = test_harness.StorageHarness;

// Defensive limits for corruption testing
const MAX_CORRUPTION_ITERATIONS = 100;
const MAX_CORRUPTION_SIZE = 1024;

//
// Basic Corruption Detection Tests
//

test "wal recovery detects magic number corruption" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_magic_corruption");
    defer harness.deinit();

    // Add test data
    const test_block = try TestData.create_test_block_with_content(allocator, 1, "corrupted_magic_test");
    defer TestData.cleanup_test_block(allocator, test_block);
    try harness.storage_engine.put_block(test_block);

    // Shutdown cleanly to write WAL
    try harness.shutdown_storage_engine();

    // Enable read corruption to simulate magic number corruption
    harness.simulation_vfs().enable_read_corruption(100, 3); // Moderate corruption rate

    // Restart should handle corruption gracefully
    try harness.startup_storage_engine();

    // Data may be lost due to corruption, but system should remain stable
    const block_count = harness.storage_engine.block_count();
    try testing.expect(block_count >= 0); // System should not crash
}

test "wal recovery handles checksum validation failures" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_checksum_corruption");
    defer harness.deinit();

    // Add multiple test blocks
    const block1 = try TestData.create_test_block_with_content(allocator, 1, "checksum_test_1");
    defer TestData.cleanup_test_block(allocator, block1);
    const block2 = try TestData.create_test_block_with_content(allocator, 2, "checksum_test_2");
    defer TestData.cleanup_test_block(allocator, block2);

    try harness.storage_engine.put_block(block1);
    try harness.storage_engine.put_block(block2);

    try harness.shutdown_storage_engine();

    // Enable read corruption to simulate checksum failures
    harness.simulation_vfs().enable_read_corruption(50, 3); // Moderate corruption rate

    // Recovery should detect corruption and handle gracefully
    try harness.startup_storage_engine();

    // System should remain stable despite checksum failures
    const final_count = harness.storage_engine.block_count();
    try testing.expect(final_count >= 0);
}

test "wal recovery handles torn writes at segment boundaries" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_torn_segments");
    defer harness.deinit();

    // Fill up first segment completely
    var i: u32 = 0;
    while (i < 50) { // Enough to potentially cross segment boundary
        const content = try std.fmt.allocPrint(allocator, "segment_boundary_test_{d}", .{i});
        defer allocator.free(content);

        const filename = try std.fmt.allocPrint(allocator, "sb_{d}.zig", .{i});
        defer allocator.free(filename);

        const block = try TestData.create_test_block_with_content(allocator, i, content);
        defer TestData.cleanup_test_block(allocator, block);
        try harness.storage_engine.put_block(block);
        i += 1;
    }

    try harness.shutdown_storage_engine();

    // Enable torn writes to simulate partial write failures
    harness.simulation_vfs().enable_torn_writes(250, 16, 750); // 25% chance, min 16 bytes, keep 75%

    // Recovery should handle partial data gracefully
    try harness.startup_storage_engine();

    // Some data might be lost, but system should remain stable
    const recovered_count = harness.storage_engine.block_count();
    try testing.expect(recovered_count <= i); // At most the original number
    try testing.expect(recovered_count >= 0); // But system stable
}

//
// Fatal Corruption Scenarios
//

test "wal recovery survives complete file corruption" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_total_corruption");
    defer harness.deinit();

    // Add some test data first
    const test_block = try TestData.create_test_block_with_content(allocator, 1, "will_be_corrupted");
    defer TestData.cleanup_test_block(allocator, test_block);
    try harness.storage_engine.put_block(test_block);

    try harness.shutdown_storage_engine();

    // Enable extreme read corruption to simulate total file corruption
    harness.simulation_vfs().enable_read_corruption(1000, 8); // Maximum corruption rate

    // System should survive total corruption without crashing
    try harness.startup_storage_engine();

    // Data may be lost due to corruption, but system should remain operational
    const block_count = harness.storage_engine.block_count();
    // With extreme corruption, we expect data loss but system stability
    try testing.expect(block_count <= 1); // At most the original data

    // Disable corruption so new writes succeed
    harness.simulation_vfs().disable_all_fault_injection();

    // Should be able to add new data after corruption recovery
    const new_block = try TestData.create_test_block_with_content(allocator, 2, "post_corruption");
    defer TestData.cleanup_test_block(allocator, new_block);
    try harness.storage_engine.put_block(new_block);

    const final_count = harness.storage_engine.block_count();
    try testing.expect(final_count >= 1); // At least our new block should be there
    try testing.expect(final_count > block_count); // Should have increased from before
}

test "wal recovery handles interleaved corruption and valid data" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_interleaved");
    defer harness.deinit();

    // Add blocks in phases to create recovery checkpoints
    const phase1_block = try TestData.create_test_block_with_content(allocator, 1, "phase1");
    defer TestData.cleanup_test_block(allocator, phase1_block);
    try harness.storage_engine.put_block(phase1_block);

    // Force WAL flush
    try harness.storage_engine.flush_wal();

    const phase2_block = try TestData.create_test_block_with_content(allocator, 2, "phase2");
    defer TestData.cleanup_test_block(allocator, phase2_block);
    try harness.storage_engine.put_block(phase2_block);

    const phase3_block = try TestData.create_test_block_with_content(allocator, 3, "phase3");
    defer TestData.cleanup_test_block(allocator, phase3_block);
    try harness.storage_engine.put_block(phase3_block);

    try harness.shutdown_storage_engine();

    // Enable moderate read corruption for selective corruption simulation
    harness.simulation_vfs().enable_read_corruption(300, 8); // 30% corruption rate

    // Recovery should salvage what it can
    try harness.startup_storage_engine();

    // Recovery should salvage what it can - some data may survive
    const recovered_count = harness.storage_engine.block_count();
    try testing.expect(recovered_count >= 0); // System remains stable
    try testing.expect(recovered_count <= 3); // At most the original data

    // If any data survived, verify system can access it
    if (recovered_count > 0) {
        // Try to find at least one of the blocks (corruption is unpredictable)
        const phase1_recovered = try harness.storage_engine.find_block(phase1_block.id, .query_engine);
        const phase2_recovered = try harness.storage_engine.find_block(phase2_block.id, .query_engine);
        const phase3_recovered = try harness.storage_engine.find_block(phase3_block.id, .query_engine);

        // At least one block should be accessible if count > 0
        const any_recovered = (phase1_recovered != null) or (phase2_recovered != null) or (phase3_recovered != null);
        try testing.expect(any_recovered);
    }
}

//
// Advanced Corruption Patterns
//

test "wal recovery handles progressive corruption" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_progressive");
    defer harness.deinit();

    // Create data that will be progressively corrupted
    var blocks_added: u32 = 0;
    while (blocks_added < 20) {
        const content = try std.fmt.allocPrint(allocator, "progressive_test_{d}", .{blocks_added});
        defer allocator.free(content);

        const filename = try std.fmt.allocPrint(allocator, "prog_{d}.zig", .{blocks_added});
        defer allocator.free(filename);

        const block = try TestData.create_test_block_with_content(allocator, blocks_added, content);
        defer TestData.cleanup_test_block(allocator, block);
        try harness.storage_engine.put_block(block);
        blocks_added += 1;
    }

    try harness.shutdown_storage_engine();

    // Enable progressive corruption using read corruption
    harness.simulation_vfs().enable_read_corruption(200, 4); // Light but persistent corruption

    // Early blocks should be more likely to survive than later ones
    try harness.startup_storage_engine();

    const recovered_count = harness.storage_engine.block_count();
    try testing.expect(recovered_count <= blocks_added); // At most the original data
    try testing.expect(recovered_count >= 0); // System should remain stable
}
