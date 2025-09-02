//! Regression test for traversal termination
//!
//! Verifies that graph traversal algorithms terminate properly and don't suffer
//! from memory corruption bugs that can cause infinite output generation,
//! segmentation faults, or hanging CLI commands.

const std = @import("std");
const testing = std.testing;

const harness_mod = @import("../harness.zig");
const types = @import("../../core/types.zig");

const QueryHarness = harness_mod.QueryHarness;
const ContextBlock = types.ContextBlock;
const BlockId = types.BlockId;

test "traversal completes in reasonable time" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "termination_test");
    defer test_harness.deinit();

    // Create a simple test block
    const test_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://sample_function",
        .metadata_json = "{\"name\":\"sample_function\",\"type\":\"function\",\"codebase\":\"test_codebase\"}",
        .content = "pub fn sample_function() void { /* test content */ }",
    };

    try test_harness.query_engine.storage_engine.put_block(test_block);

    // Test that traversal completes quickly and doesn't hang
    const start_time = std.time.nanoTimestamp();
    const result = try test_harness.query_engine.traverse_outgoing(test_block.id, 5);
    const end_time = std.time.nanoTimestamp();
    defer result.deinit();

    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Critical regression test: traversal should complete quickly
    // The original bug caused 20+ second hangs
    try testing.expect(duration_ms < 100.0); // Should complete in under 100ms

    // Critical regression test: results should be bounded
    // The original bug caused thousands of corrupted results
    try testing.expect(result.blocks.len < 1000);

    // Critical regression test: depth values should not be corrupted
    // The original bug caused depth values like 2863311530
    for (result.depths) |depth| {
        try testing.expect(depth < 100); // Reasonable depth limit
    }
}

test "filter_traversal_by_codebase memory safety" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "filter_test");
    defer test_harness.deinit();

    // Create test blocks in different codebases
    const target_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://target",
        .metadata_json = "{\"name\":\"target\",\"type\":\"function\",\"codebase\":\"target_codebase\"}",
        .content = "target content",
    };

    const other_block = ContextBlock{
        .id = BlockId.generate(),
        .version = 1,
        .source_uri = "test://other",
        .metadata_json = "{\"name\":\"other\",\"type\":\"function\",\"codebase\":\"other_codebase\"}",
        .content = "other content",
    };

    try test_harness.query_engine.storage_engine.put_block(target_block);
    try test_harness.query_engine.storage_engine.put_block(other_block);

    // This is the critical test - workspace filtering should not cause use-after-free
    // The original bug was in filter_traversal_by_codebase: premature ArrayList.deinit() caused memory corruption
    // We test this through the public API that uses the same filtering internally
    const filtered_result = try test_harness.query_engine.traverse_outgoing_in_workspace(
        target_block.id,
        3,
        "target_codebase",
    );
    defer filtered_result.deinit();

    // Verify no memory corruption occurred:
    // 1. Function completed without segfault
    // 2. Depth values are not corrupted
    for (filtered_result.depths) |depth| {
        try testing.expect(depth < 1000); // Should be reasonable, not corrupted like 2863311530
    }

    // 3. Result count is reasonable
    try testing.expect(filtered_result.blocks.len < 1000);
}

test "workspace filtering performance" {
    var test_harness = try QueryHarness.init_and_startup(testing.allocator, "workspace_filter_test");
    defer test_harness.deinit();

    // Create multiple blocks to test filtering performance
    var block_ids: [10]BlockId = undefined;

    for (0..10) |i| {
        const block = ContextBlock{
            .id = BlockId.generate(),
            .version = 1,
            .source_uri = try std.fmt.allocPrint(testing.allocator, "test://block_{}", .{i}),
            .metadata_json = try std.fmt.allocPrint(testing.allocator, "{{\"name\":\"block_{}\",\"type\":\"function\",\"codebase\":\"test_codebase\"}}", .{i}),
            .content = try std.fmt.allocPrint(testing.allocator, "block {} content", .{i}),
        };
        defer testing.allocator.free(block.source_uri);
        defer testing.allocator.free(block.metadata_json);
        defer testing.allocator.free(block.content);

        block_ids[i] = block.id;
        try test_harness.query_engine.storage_engine.put_block(block);
    }

    // Test workspace-aware traversal (which uses filter_traversal_by_codebase internally)
    const start_time = std.time.nanoTimestamp();
    const result = try test_harness.query_engine.traverse_outgoing_in_workspace(block_ids[0], 3, "test_codebase");
    const end_time = std.time.nanoTimestamp();
    defer result.deinit();

    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Performance regression test: should complete quickly
    try testing.expect(duration_ms < 500.0);

    // Memory safety test: no corrupted values
    for (result.depths) |depth| {
        try testing.expect(depth < 100);
    }
}
