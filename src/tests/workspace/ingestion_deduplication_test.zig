//! Storage deduplication validation for KausalDB.
//!
//! Tests that duplicate blocks are properly handled at the storage layer,
//! ensuring data integrity and preventing pollution of search results.

const std = @import("std");
const testing = std.testing;

const harness = @import("../harness.zig");
const context_block = @import("../../core/types.zig");

const ContextBlock = context_block.ContextBlock;
const BlockId = context_block.BlockId;

test "storage deduplication prevents duplicate blocks with same ID" {
    var test_harness = try harness.StorageHarness.init_and_startup(testing.allocator, "storage_dedup_test");
    defer test_harness.deinit();

    // Create identical block
    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.allocator.dupe(u8, "file://test.zig#L1-5"),
        .metadata_json = try test_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test.zig:test_func\",\"codebase\":\"test\"}"),
        .content = try test_harness.allocator.dupe(u8, "pub fn test_func() {}"),
    };

    // Store same block multiple times (simulating duplicate ingestion)
    try test_harness.storage_engine.put_block(block);

    try test_harness.storage_engine.put_block(block);
    try test_harness.storage_engine.put_block(block);

    // Create query harness to test search results
    var query_harness = try harness.QueryHarness.init_and_startup(testing.allocator, "dedup_query_test");
    defer query_harness.deinit();

    // Store the same block in query harness
    try query_harness.storage().put_block(block);
    try query_harness.storage().put_block(block);

    // Query should return only one result despite multiple puts
    const results = try query_harness.query_engine.find_by_name("test", "function", "test_func");
    defer results.deinit();

    try testing.expectEqual(@as(u32, 1), results.total_matches);
}

test "blocks with different IDs are stored separately" {
    var test_harness = try harness.StorageHarness.init_and_startup(testing.allocator, "different_ids_test");
    defer test_harness.deinit();

    // Create blocks with same content but different IDs
    const block1 = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.allocator.dupe(u8, "file://test1.zig#L1-5"),
        .metadata_json = try test_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test1.zig:same_func\",\"codebase\":\"test\"}"),
        .content = try test_harness.allocator.dupe(u8, "pub fn same_func() {}"),
    };

    const block2 = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.allocator.dupe(u8, "file://test2.zig#L1-5"),
        .metadata_json = try test_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test2.zig:same_func\",\"codebase\":\"test\"}"),
        .content = try test_harness.allocator.dupe(u8, "pub fn same_func() {}"),
    };

    try test_harness.storage_engine.put_block(block1);
    try test_harness.storage_engine.put_block(block2);

    // Create query harness to verify both blocks are findable
    var query_harness = try harness.QueryHarness.init_and_startup(testing.allocator, "two_blocks_test");
    defer query_harness.deinit();

    try query_harness.storage().put_block(block1);
    try query_harness.storage().put_block(block2);

    // Query should return both results since they have different IDs
    const results = try query_harness.query_engine.find_by_name("test", "function", "same_func");
    defer results.deinit();

    try testing.expectEqual(@as(u32, 2), results.total_matches);
}

test "block updates replace existing blocks correctly" {
    var test_harness = try harness.StorageHarness.init_and_startup(testing.allocator, "block_update_test");
    defer test_harness.deinit();

    const block_id = BlockId.generate();

    // Create initial block
    const initial_block = ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = try test_harness.allocator.dupe(u8, "file://update.zig#L1-5"),
        .metadata_json = try test_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"update.zig:evolving_func\",\"codebase\":\"test\"}"),
        .content = try test_harness.allocator.dupe(u8, "pub fn evolving_func() { // v1 }"),
    };

    // Create updated block with same ID
    const updated_block = ContextBlock{
        .id = block_id,
        .version = 2,
        .source_uri = try test_harness.allocator.dupe(u8, "file://update.zig#L1-8"),
        .metadata_json = try test_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"update.zig:evolving_func\",\"codebase\":\"test\"}"),
        .content = try test_harness.allocator.dupe(u8, "pub fn evolving_func() { // v2 - updated }"),
    };

    try test_harness.storage_engine.put_block(initial_block);
    try test_harness.storage_engine.put_block(updated_block);

    // Create query harness to verify only updated version exists
    var query_harness = try harness.QueryHarness.init_and_startup(testing.allocator, "update_query_test");
    defer query_harness.deinit();

    try query_harness.storage().put_block(initial_block);
    try query_harness.storage().put_block(updated_block);

    const results = try query_harness.query_engine.find_by_name("test", "function", "evolving_func");
    defer results.deinit();

    try testing.expectEqual(@as(u32, 1), results.total_matches);

    // Verify it's the updated version
    const returned_block = results.results[0].block.extract();
    try testing.expectEqual(@as(u64, 2), returned_block.version);
    try testing.expect(std.mem.indexOf(u8, returned_block.content, "v2 - updated") != null);
}

test "empty metadata handles deduplication gracefully" {
    var test_harness = try harness.StorageHarness.init_and_startup(testing.allocator, "empty_metadata_test");
    defer test_harness.deinit();

    const block_id = BlockId.generate();

    // Create block with minimal metadata
    const minimal_block = ContextBlock{
        .id = block_id,
        .version = 1,
        .source_uri = try test_harness.allocator.dupe(u8, "file://minimal.zig#L1-3"),
        .metadata_json = try test_harness.allocator.dupe(u8, "{}"),
        .content = try test_harness.allocator.dupe(u8, "// minimal content"),
    };

    // Store it multiple times
    try test_harness.storage_engine.put_block(minimal_block);
    try test_harness.storage_engine.put_block(minimal_block);

    // Should still be deduplicated by block ID
    const found_block = try test_harness.storage_engine.find_block(block_id, .query_engine);
    try testing.expect(found_block != null);

    // Verify content is correct
    const extracted = found_block.?.extract();
    try testing.expect(std.mem.eql(u8, extracted.content, "// minimal content"));
}
