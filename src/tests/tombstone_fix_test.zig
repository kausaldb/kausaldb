//! Simple test to verify tombstone sequence shadowing fix.
//!
//! Validates that tombstones shadow blocks based on sequence/sequence comparison,
//! not just block ID existence.

const std = @import("std");
const testing = std.testing;

// Core types
const types = @import("../core/types.zig");
const engine = @import("../storage/engine.zig");

// Test infrastructure
const SimulationVFS = @import("../sim/simulation_vfs.zig").SimulationVFS;

// Type aliases
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const StorageEngine = engine.StorageEngine;

test "tombstone sequence shadowing fix: newer sequence survive deletion" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/tombstone_test");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    const block_id = BlockId.generate();

    // Add sequence 2
    const block_v2 = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test.zig",
        .metadata_json = "{}",
        .content = "sequence 2 content",
    };
    try storage_engine.put_block(block_v2);

    // Delete block - creates tombstone with deletion_sequence = 0
    try storage_engine.delete_block(block_id);

    // Add sequence 5 - this should NOT be shadowed because sequence 5 > deletion_sequence 0
    const block_v5 = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test.zig",
        .metadata_json = "{}",
        .content = "sequence 5 content",
    };
    try storage_engine.put_block(block_v5);

    // Should find sequence 5 because it's not shadowed
    const found = try storage_engine.find_block(block_id, .query_engine);
    try testing.expect(found != null);
    try testing.expectEqualStrings("sequence 5 content", found.?.read(.temporary).content);
    try testing.expect(found.?.read(.temporary).sequence == 5);
}

test "tombstone sequence shadowing fix: older sequence are shadowed" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/tombstone_test2");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    const block_id = BlockId.generate();

    // Add sequence 10
    const block_v10 = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test.zig",
        .metadata_json = "{}",
        .content = "sequence 10 content",
    };
    try storage_engine.put_block(block_v10);

    // Force to SSTable
    try storage_engine.flush_memtable_to_sstable();

    // Delete block - creates tombstone with deletion_sequence = 0
    try storage_engine.delete_block(block_id);

    // Force tombstone to SSTable
    try storage_engine.flush_memtable_to_sstable();

    // Now add an old sequence that should be shadowed
    // We need to simulate recovery adding an old block from WAL
    // For this test, we'll add it directly and then compact to test compaction logic
    const block_v_old = ContextBlock{
        .id = block_id,
        .sequence = 0, // Much less than deletion_sequence 0 from tombstone
        .source_uri = "test.zig",
        .metadata_json = "{}",
        .content = "old sequence content",
    };
    try storage_engine.put_block(block_v_old);
    try storage_engine.flush_memtable_to_sstable();

    // Force compaction - old sequence should be filtered out by tombstone
    try storage_engine.sstable_manager.check_and_run_compaction();

    // Should not find any block because old sequence is shadowed
    const found = try storage_engine.find_block(block_id, .query_engine);
    try testing.expect(found == null);
}

test "tombstone sequence shadowing fix: memtable blocks respect tombstones" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var storage_engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/tombstone_test3");
    defer storage_engine.deinit();
    try storage_engine.startup();
    defer storage_engine.shutdown() catch {};

    const block_id = BlockId.generate();

    // Add sequence 1
    const block_v1 = ContextBlock{
        .id = block_id,
        .sequence = 0, // Storage engine will assign the actual global sequence
        .source_uri = "test.zig",
        .metadata_json = "{}",
        .content = "sequence 1 content",
    };
    try storage_engine.put_block(block_v1);

    // Delete - creates tombstone with deletion_sequence = 0
    try storage_engine.delete_block(block_id);

    // Block should not be found because sequence 1 > deletion_sequence 0 is false,
    // so tombstone shadows it
    const found = try storage_engine.find_block(block_id, .query_engine);
    try testing.expect(found == null);
}
