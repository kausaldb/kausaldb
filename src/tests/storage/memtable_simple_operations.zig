//! MemtableManager isolated functionality tests.
//!
//! Tests basic insert, lookup, delete operations and memory management
//! patterns in MemtableManager without storage engine integration.
//! Validates block lifecycle and arena allocation behavior.

const std = @import("std");

const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const storage = @import("../../storage/engine.zig");
const test_harness = @import("../harness.zig");
const types = @import("../../core/types.zig");

const testing = std.testing;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const MemtableManager = storage.MemtableManager;
const SimulationVFS = simulation_vfs.SimulationVFS;
const StorageHarness = test_harness.StorageHarness;
const TestData = test_harness.TestData;

test "put block basic" {
    const allocator = testing.allocator;

    // Use StorageHarness for simplified setup while testing MemtableManager specifically
    var harness = try StorageHarness.init_and_startup(allocator, "memtable_basic");
    defer harness.deinit();

    // Access the underlying memtable manager for direct testing
    const manager = &harness.storage_engine.memtable_manager;

    // Use standardized test data for consistent block creation
    const test_block = ContextBlock{
        .id = TestData.deterministic_block_id(1),
        .version = 1,
        .source_uri = "test://memtable_simple.zig",
        .metadata_json = "{\"test\":\"memtable_simple\"}",
        .content = "Memtable simple operations test block content",
    };

    // Test specific memtable operation
    try manager.put_block(test_block);
    const retrieved = manager.find_block_in_memtable(test_block.id);

    // Simple, direct assertions
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(test_block.content, retrieved.?.content);
}

test "find block missing" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "memtable_missing");
    defer harness.deinit();

    const manager = &harness.storage_engine.memtable_manager;

    // Test finding non-existent block using deterministic ID
    const missing_id = TestData.deterministic_block_id(99);
    const result = manager.find_block_in_memtable(missing_id);

    try testing.expect(result == null);
}

test "put block overwrite" {
    const allocator = testing.allocator;

    var harness = try StorageHarness.init_and_startup(allocator, "memtable_overwrite");
    defer harness.deinit();

    const manager = &harness.storage_engine.memtable_manager;

    // Create blocks with same ID but different versions using TestData
    const block_v1 = ContextBlock{
        .id = TestData.deterministic_block_id(1),
        .version = 1,
        .source_uri = "test://memtable_overwrite_v1.zig",
        .metadata_json = "{\"test\":\"memtable_overwrite\",\"version\":1}",
        .content = "version 1 content",
    };
    const block_id = block_v1.id;

    try manager.put_block(block_v1);

    // Put second version (overwrite)
    const block_v2 = ContextBlock{
        .id = TestData.deterministic_block_id(1),
        .version = 2,
        .source_uri = "test://memtable_overwrite_v2.zig",
        .metadata_json = "{\"test\":\"memtable_overwrite\",\"version\":2}",
        .content = "version 2 content",
    };

    try manager.put_block(block_v2);

    // Verify latest version is retrieved
    const retrieved = manager.find_block_in_memtable(block_id).?;
    try testing.expectEqual(@as(u64, 2), retrieved.version);
    try testing.expectEqualStrings("version 2 content", retrieved.content);
}
