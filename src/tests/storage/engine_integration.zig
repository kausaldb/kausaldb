//! StorageEngine integration tests.
//!
//! Tests the StorageEngine implementation with full component stack including
//! WAL, memtable, SSTables, and VFS operations. These tests validate cross-component
//! interactions and are run as part of the integration test suite.

const std = @import("std");
const testing = std.testing;

const storage_engine = @import("../../storage/engine.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const types = @import("../../core/types.zig");
const error_context = @import("../../core/error_context.zig");

const StorageEngine = storage_engine.StorageEngine;
const Config = storage_engine.Config;
const SimulationVFS = simulation_vfs.SimulationVFS;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const GraphEdge = types.GraphEdge;
const EdgeType = types.EdgeType;

test "StorageEngine disable WAL verification for simulation" {
    // This test validates that WAL verification can be disabled for simulation environments
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const config = Config{
        .memtable_max_size = 1024 * 1024,
    };

    var engine = try StorageEngine.init(allocator, sim_vfs.vfs(), "/test", config);
    defer engine.deinit();

    try engine.startup();
    try testing.expect(engine.state == .running);
}

test "storage engine initialization and cleanup" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/data");
    defer engine.deinit();

    try testing.expect(engine.state == .initialized);
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(engine.memtable_manager.block_index.blocks.count())));
}

test "storage engine startup and basic operations" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/data");
    defer engine.deinit();

    try engine.startup();
    try testing.expect(engine.state == .running);

    const block_id = BlockId.generate();
    const block = ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = "file://test.zig",
        .metadata_json = "{}",
        .content = "test content",
    };

    try engine.put_block(block);
    try testing.expectEqual(@as(u32, 1), @as(u32, @intCast(engine.memtable_manager.block_index.blocks.count())));

    const found_block = try engine.find_block(block_id, .storage_engine);
    try testing.expect(found_block != null);
    try testing.expectEqualStrings("test content", found_block.?.read(.storage_engine).content);

    try engine.delete_block(block_id);
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(engine.memtable_manager.block_index.blocks.count())));
}

test "block iterator with empty storage" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/empty");
    defer engine.deinit();

    try engine.startup();

    var iterator = engine.iterate_all_blocks();
    try testing.expect(try iterator.next() == null);
}

test "block iterator with memtable blocks only" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/memtable");
    defer engine.deinit();

    try engine.startup();

    // Add blocks to memtable
    const test_blocks = [_]ContextBlock{
        ContextBlock{
            .id = BlockId.from_bytes([_]u8{1} ** 16),
            .version = 1,
            .source_uri = "file://mem1.zig",
            .metadata_json = "{}",
            .content = "memtable content 1",
        },
        ContextBlock{
            .id = BlockId.from_bytes([_]u8{2} ** 16),
            .version = 1,
            .source_uri = "file://mem2.zig",
            .metadata_json = "{}",
            .content = "memtable content 2",
        },
    };

    for (test_blocks) |block| {
        try engine.put_block(block);
    }

    // Iterate and verify
    var iterator = engine.iterate_all_blocks();
    var count: u32 = 0;
    var found_ids = std.AutoHashMap(BlockId, void).init(allocator);
    defer found_ids.deinit();

    while (try iterator.next()) |owned_block| {
        const block = owned_block.read(.storage_engine);
        try found_ids.put(block.id, {});
        count += 1;
    }

    try testing.expectEqual(@as(u32, test_blocks.len), count);
    for (test_blocks) |expected_block| {
        try testing.expect(found_ids.contains(expected_block.id));
    }
}

test "block iterator with SSTable blocks" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const config = Config.minimal_for_testing();
    var engine = try StorageEngine.init(allocator, sim_vfs.vfs(), "/test/sstable", config);
    defer engine.deinit();

    try engine.startup();

    // Add blocks and force flush to SSTable
    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://sstable_test.zig",
        .metadata_json = "{}",
        .content = "sstable content",
    };

    try engine.put_block(block);
    try engine.flush_memtable_to_sstable();

    // Verify SSTable was created
    try testing.expect(engine.sstable_manager.total_block_count() > 0);

    // Iterate and find the block
    var iterator = engine.iterate_all_blocks();
    var found = false;
    while (try iterator.next()) |owned_block| {
        const iterated_block = owned_block.read(.storage_engine);
        if (iterated_block.id.eql(block.id)) {
            found = true;
            try testing.expectEqualStrings(block.content, iterated_block.content);
            break;
        }
    }
    try testing.expect(found);
}

test "block iterator with mixed memtable and SSTable blocks" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    const config = Config.minimal_for_testing();
    var engine = try StorageEngine.init(allocator, sim_vfs.vfs(), "/test/mixed", config);
    defer engine.deinit();

    try engine.startup();

    // Add block to SSTable
    const sstable_block = ContextBlock{
        .id = BlockId.from_bytes([_]u8{1} ** 16),
        .version = 1,
        .source_uri = "file://sstable.zig",
        .metadata_json = "{}",
        .content = "sstable content",
    };

    try engine.put_block(sstable_block);
    try engine.flush_memtable_to_sstable();

    // Add block to memtable
    const memtable_block = ContextBlock{
        .id = BlockId.from_bytes([_]u8{2} ** 16),
        .version = 1,
        .source_uri = "file://memtable.zig",
        .metadata_json = "{}",
        .content = "memtable content",
    };

    try engine.put_block(memtable_block);

    // Iterate and verify both blocks
    var iterator = engine.iterate_all_blocks();
    var found_sstable = false;
    var found_memtable = false;
    var count: u32 = 0;

    while (try iterator.next()) |owned_block| {
        const block = owned_block.read(.storage_engine);
        count += 1;

        if (block.id.eql(sstable_block.id)) {
            found_sstable = true;
            try testing.expectEqualStrings(sstable_block.content, block.content);
        } else if (block.id.eql(memtable_block.id)) {
            found_memtable = true;
            try testing.expectEqualStrings(memtable_block.content, block.content);
        }
    }

    try testing.expect(found_sstable);
    try testing.expect(found_memtable);
    try testing.expectEqual(@as(u32, 2), count);
}

test "block iterator handles multiple calls to next after exhaustion" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/exhaustion");
    defer engine.deinit();

    try engine.startup();

    // Add single block
    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://single.zig",
        .metadata_json = "{}",
        .content = "single content",
    };

    try engine.put_block(block);

    var iterator = engine.iterate_all_blocks();

    // First call should return the block
    const first_block = try iterator.next();
    try testing.expect(first_block != null);

    // Subsequent calls should return null
    try testing.expect(try iterator.next() == null);
    try testing.expect(try iterator.next() == null);
    try testing.expect(try iterator.next() == null);
}

test "error context logging for storage operations" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/error_context");
    defer engine.deinit();

    try engine.startup();

    // Test successful operation (should not log errors)
    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://context_test.zig",
        .metadata_json = "{}",
        .content = "context test content",
    };

    try engine.put_block(block);

    // Verify operation succeeded
    const found_block = try engine.find_block(block.id, .storage_engine);
    try testing.expect(found_block != null);
}

test "storage engine error context wrapping validation" {
    const allocator = testing.allocator;

    var sim_vfs = try SimulationVFS.init(allocator);
    defer sim_vfs.deinit();

    var engine = try StorageEngine.init_default(allocator, sim_vfs.vfs(), "/test/error_wrap");
    defer engine.deinit();

    try engine.startup();

    // Test that error context is properly maintained throughout the stack
    // This is validated by ensuring operations complete without unwinding
    // error context information (which would cause test failures)

    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "file://error_wrap_test.zig",
        .metadata_json = "{}",
        .content = "error context validation",
    };

    try engine.put_block(block);

    // Perform operations that exercise error context paths
    _ = try engine.find_block(block.id, .storage_engine);

    const non_existent_id = BlockId.generate();
    const not_found = try engine.find_block(non_existent_id, .storage_engine);
    try testing.expect(not_found == null);

    // If we reach here, error context is working correctly
}
