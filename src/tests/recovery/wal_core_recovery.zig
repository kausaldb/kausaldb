//! Core WAL Recovery Tests
//!
//! Consolidated tests for Write-Ahead Log recovery functionality covering:
//! - Basic recovery operations and restart scenarios
//! - Operation replay and consistency validation
//! - Empty directory and clean startup handling
//! - Normal WAL processing without corruption
//!
//! This file consolidates core functionality from:
//! - wal.zig (basic recovery)
//! - wal_operations_recovery.zig (operations replay)
//! - wal_segmentation.zig (segment management)

const std = @import("std");

const golden_master = @import("../../testing/golden_master.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const storage = @import("../../storage/engine.zig");
const test_harness = @import("../harness.zig");
const types = @import("../../core/types.zig");

const testing = std.testing;

const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageEngine = storage.StorageEngine;
const TestData = test_harness.TestData;
const StorageHarness = test_harness.StorageHarness;

//
// Basic WAL Recovery Tests
//

test "wal recovery with empty directory" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_empty_data");
    defer harness.deinit();

    // Empty directory should start cleanly
    const initial_block_count = harness.storage_engine.block_count();
    try testing.expect(initial_block_count == 0);
}

test "wal recovery preserves data after restart" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_restart_data");
    defer harness.deinit();

    // Add test data
    const test_block = try TestData.create_test_block(allocator, 1);
    defer TestData.cleanup_test_block(allocator, test_block);

    try harness.storage_engine.put_block(test_block);

    // Restart storage engine (simulates crash/restart)
    try harness.restart_storage_engine();

    // Verify data was recovered
    const recovered_block = try harness.storage_engine.find_block(test_block.id, .query_engine);
    try testing.expect(recovered_block != null);

    const block_data = recovered_block.?.read(.query_engine);
    try testing.expectEqualStrings(test_block.content, block_data.content);
}

test "wal recovery handles multiple operations correctly" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_multi_ops");
    defer harness.deinit();

    // Create multiple test blocks
    const block1 = try TestData.create_test_block(allocator, 1);
    defer TestData.cleanup_test_block(allocator, block1);
    const block2 = try TestData.create_test_block(allocator, 2);
    defer TestData.cleanup_test_block(allocator, block2);
    const block3 = try TestData.create_test_block(allocator, 3);
    defer TestData.cleanup_test_block(allocator, block3);

    // Add blocks sequentially
    try harness.storage_engine.put_block(block1);
    try harness.storage_engine.put_block(block2);
    try harness.storage_engine.put_block(block3);

    // Restart to trigger recovery
    try harness.restart_storage_engine();

    // All blocks should be recovered
    try testing.expect((try harness.storage_engine.find_block(block1.id, .query_engine)) != null);
    try testing.expect((try harness.storage_engine.find_block(block2.id, .query_engine)) != null);
    try testing.expect((try harness.storage_engine.find_block(block3.id, .query_engine)) != null);

    const recovered_count = harness.storage_engine.block_count();
    try testing.expect(recovered_count == 3);
}

//
// WAL Segmentation and Large Dataset Tests
//

test "wal recovery across segment boundaries" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_segments");
    defer harness.deinit();

    // Add enough blocks to force WAL segmentation
    var added_blocks: u32 = 0;
    while (added_blocks < 100) {
        const content = try std.fmt.allocPrint(allocator, "content_{d}", .{added_blocks});
        defer allocator.free(content);

        const filename = try std.fmt.allocPrint(allocator, "file_{d}.zig", .{added_blocks});
        defer allocator.free(filename);

        const block = try TestData.create_test_block_with_content(allocator, added_blocks, content);
        defer TestData.cleanup_test_block(allocator, block);
        try harness.storage_engine.put_block(block);
        added_blocks += 1;
    }

    // Restart to trigger multi-segment recovery
    try harness.restart_storage_engine();

    // Verify all blocks recovered
    const recovered_count = harness.storage_engine.block_count();
    try testing.expect(recovered_count == added_blocks);
}

test "wal operations replay maintains consistency" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_replay_consistency");
    defer harness.deinit();

    // Create two blocks and add edge between them
    const block1 = try TestData.create_test_block_with_content(allocator, 1, "function init() {}");
    defer TestData.cleanup_test_block(allocator, block1);
    const block2 = try TestData.create_test_block_with_content(allocator, 2, "function cleanup() {}");
    defer TestData.cleanup_test_block(allocator, block2);

    try harness.storage_engine.put_block(block1);
    try harness.storage_engine.put_block(block2);

    const edge = GraphEdge{
        .source_id = block1.id,
        .target_id = block2.id,
        .edge_type = EdgeType.calls,
    };
    try harness.storage_engine.put_edge(edge);

    // Restart and verify consistency
    try harness.restart_storage_engine();

    // Verify both blocks were recovered
    const recovered_block1 = try harness.storage_engine.find_block(block1.id, .query_engine);
    try testing.expect(recovered_block1 != null);
    const recovered_block2 = try harness.storage_engine.find_block(block2.id, .query_engine);
    try testing.expect(recovered_block2 != null);

    // Verify edge was recovered too
    const outgoing_edges = harness.storage_engine.find_outgoing_edges(block1.id);
    try testing.expect(outgoing_edges.len > 0);

    // Verify edge points to the correct target
    try testing.expect(std.mem.eql(u8, &outgoing_edges[0].edge.target_id.bytes, &block2.id.bytes));
}

//
// WAL Recovery Performance and Stress Tests
//

test "wal recovery performance under load" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "wal_performance");
    defer harness.deinit();

    const start_time = std.time.nanoTimestamp();

    // Add significant number of blocks to test recovery performance
    var i: u32 = 0;
    while (i < 500) {
        const content = try std.fmt.allocPrint(allocator, "performance_test_content_{d}", .{i});
        defer allocator.free(content);

        const filename = try std.fmt.allocPrint(allocator, "perf_{d}.zig", .{i});
        defer allocator.free(filename);

        const block = try TestData.create_test_block_with_content(allocator, i, content);
        defer TestData.cleanup_test_block(allocator, block);
        try harness.storage_engine.put_block(block);
        i += 1;
    }

    const write_time = std.time.nanoTimestamp() - start_time;

    // Measure recovery time
    const recovery_start = std.time.nanoTimestamp();
    try harness.restart_storage_engine();
    const recovery_time = std.time.nanoTimestamp() - recovery_start;

    // Recovery should be reasonably fast (less than 10x write time)
    try testing.expect(recovery_time < write_time * 10);

    // Verify all data recovered
    const recovered_count = harness.storage_engine.block_count();
    try testing.expect(recovered_count == i);
}
