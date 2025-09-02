//! Workspace filtering validation for QueryEngine operations.
//!
//! Tests that workspace filtering correctly isolates query results by codebase,
//! ensuring users can scope queries to specific projects without cross-workspace
//! pollution in search results.

const std = @import("std");
const testing = std.testing;

const harness = @import("../harness.zig");
const context_block = @import("../../core/types.zig");

const ContextBlock = context_block.ContextBlock;
const BlockId = context_block.BlockId;

test "workspace filtering isolates query results by codebase" {
    var test_harness = try harness.QueryHarness.init_and_startup(testing.allocator, "workspace_filtering_test");
    defer test_harness.deinit();

    // Create two blocks with same function name but different codebases
    const kausal_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.storage_harness.allocator.dupe(u8, "file://kausaldb/src/main.zig#L1-10"),
        .metadata_json = try test_harness.storage_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"main.zig:init\",\"codebase\":\"kausaldb\"}"),
        .content = try test_harness.storage_harness.allocator.dupe(u8, "pub fn init() {}"),
    };
    defer harness.TestData.cleanup_test_block(test_harness.storage_harness.allocator, kausal_block);

    const limbo_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.storage_harness.allocator.dupe(u8, "file://limbo/src/db.zig#L1-10"),
        .metadata_json = try test_harness.storage_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"db.zig:init\",\"codebase\":\"limbo\"}"),
        .content = try test_harness.storage_harness.allocator.dupe(u8, "pub fn init() {}"),
    };
    defer harness.TestData.cleanup_test_block(test_harness.storage_harness.allocator, limbo_block);

    // Store both blocks
    try test_harness.storage().put_block(kausal_block);
    try test_harness.storage().put_block(limbo_block);

    // Query for "init" function in kausaldb workspace only
    const kausal_results = try test_harness.query_engine.find_by_name("kausaldb", "function", "init");
    defer kausal_results.deinit();

    // Query for "init" function in limbo workspace only
    const limbo_results = try test_harness.query_engine.find_by_name("limbo", "function", "init");
    defer limbo_results.deinit();

    // Verify workspace isolation - each query returns only 1 result from correct codebase
    try testing.expectEqual(@as(u32, 1), kausal_results.total_matches);
    try testing.expectEqual(@as(u32, 1), limbo_results.total_matches);

    // Verify correct blocks returned for each workspace
    const kausal_returned_id = kausal_results.results[0].block.extract().id;
    const limbo_returned_id = limbo_results.results[0].block.extract().id;

    try testing.expect(std.mem.eql(u8, &kausal_returned_id.bytes, &kausal_block.id.bytes));
    try testing.expect(std.mem.eql(u8, &limbo_returned_id.bytes, &limbo_block.id.bytes));
}

test "workspace filtering handles nonexistent codebase" {
    var test_harness = try harness.QueryHarness.init_and_startup(testing.allocator, "nonexistent_test");
    defer test_harness.deinit();

    // Create block in known codebase
    const block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.storage_harness.allocator.dupe(u8, "file://kausaldb/src/test.zig#L1-5"),
        .metadata_json = try test_harness.storage_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test.zig:test_func\",\"codebase\":\"kausaldb\"}"),
        .content = try test_harness.storage_harness.allocator.dupe(u8, "pub fn test_func() {}"),
    };
    defer harness.TestData.cleanup_test_block(test_harness.storage_harness.allocator, block);

    try test_harness.storage().put_block(block);

    // Query for function in nonexistent codebase
    const results = try test_harness.query_engine.find_by_name("nonexistent", "function", "test_func");
    defer results.deinit();

    // Should return no results
    try testing.expectEqual(@as(u32, 0), results.total_matches);
    try testing.expectEqual(@as(usize, 0), results.results.len);
}

test "workspace filtering skips blocks with malformed metadata" {
    var test_harness = try harness.QueryHarness.init_and_startup(testing.allocator, "malformed_test");
    defer test_harness.deinit();

    // Block missing codebase field
    const malformed_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.storage_harness.allocator.dupe(u8, "file://test.zig#L1-5"),
        .metadata_json = try test_harness.storage_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test.zig:bad_func\"}"), // Missing codebase
        .content = try test_harness.storage_harness.allocator.dupe(u8, "pub fn bad_func() {}"),
    };
    defer harness.TestData.cleanup_test_block(test_harness.storage_harness.allocator, malformed_block);

    // Valid block with codebase
    const valid_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = try test_harness.storage_harness.allocator.dupe(u8, "file://kausaldb/src/good.zig#L1-5"),
        .metadata_json = try test_harness.storage_harness.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"good.zig:good_func\",\"codebase\":\"kausaldb\"}"),
        .content = try test_harness.storage_harness.allocator.dupe(u8, "pub fn good_func() {}"),
    };
    defer harness.TestData.cleanup_test_block(test_harness.storage_harness.allocator, valid_block);

    try test_harness.storage().put_block(malformed_block);
    try test_harness.storage().put_block(valid_block);

    // Query should skip malformed block and return only valid one
    const results = try test_harness.query_engine.find_by_name("kausaldb", "function", "good_func");
    defer results.deinit();

    try testing.expectEqual(@as(u32, 1), results.total_matches);
    const returned_id = results.results[0].block.extract().id;
    try testing.expect(std.mem.eql(u8, &returned_id.bytes, &valid_block.id.bytes));
}
