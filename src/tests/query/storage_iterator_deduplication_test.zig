//! Storage iterator deduplication test
//!
//! Verifies that StorageEngine.iterate_all_blocks() returns each block
//! exactly once without duplicates. This addresses the issue where
//! find_by_name was returning duplicate results due to the iterator
//! yielding the same blocks multiple times.

const std = @import("std");

const harness_mod = @import("../harness.zig");
const context_block = @import("../../core/types.zig");
const parse_file_to_blocks = @import("../../ingestion/parse_file_to_blocks.zig");

const testing = std.testing;
const StorageHarness = harness_mod.StorageHarness;
const ContextBlock = context_block.ContextBlock;
const BlockId = context_block.BlockId;
const FileContent = parse_file_to_blocks.FileContent;
const ParseConfig = parse_file_to_blocks.ParseConfig;

test "storage iterator returns unique blocks only" {
    var test_harness = try StorageHarness.init_and_startup(testing.allocator, "iterator_dedup_test");
    defer test_harness.deinit();

    // Create test blocks with deterministic content
    const test_blocks = [_]ContextBlock{
        ContextBlock{
            .id = try BlockId.from_hex("00000000000000000000000000000001"),
            .version = 1,
            .source_uri = try testing.allocator.dupe(u8, "file://test1.zig#L1-5"),
            .metadata_json = try testing.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test1.zig:first_function\"}"),
            .content = try testing.allocator.dupe(u8, "pub fn first_function() void {}"),
        },
        ContextBlock{
            .id = try BlockId.from_hex("00000000000000000000000000000002"),
            .version = 1,
            .source_uri = try testing.allocator.dupe(u8, "file://test2.zig#L10-15"),
            .metadata_json = try testing.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test2.zig:second_function\"}"),
            .content = try testing.allocator.dupe(u8, "pub fn second_function() void {}"),
        },
        ContextBlock{
            .id = try BlockId.from_hex("00000000000000000000000000000003"),
            .version = 1,
            .source_uri = try testing.allocator.dupe(u8, "file://test3.zig#L20-25"),
            .metadata_json = try testing.allocator.dupe(u8, "{\"unit_type\":\"function\",\"unit_id\":\"test3.zig:third_function\"}"),
            .content = try testing.allocator.dupe(u8, "pub fn third_function() void {}"),
        },
    };

    // Cleanup allocated strings
    defer {
        for (test_blocks) |block| {
            testing.allocator.free(block.source_uri);
            testing.allocator.free(block.metadata_json);
            testing.allocator.free(block.content);
        }
    }

    // Store test blocks
    for (test_blocks) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Track seen blocks by BlockId to detect duplicates
    var seen_block_ids = std.AutoHashMap(BlockId, void).init(testing.allocator);
    defer seen_block_ids.deinit();

    // Track seen blocks by content hash to detect content duplication
    var seen_content_hashes = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen_content_hashes.deinit();

    // Iterate through all blocks and verify uniqueness
    var iterator = test_harness.storage_engine.iterate_all_blocks();
    var total_blocks_returned: u32 = 0;

    while (try iterator.next()) |block| {
        total_blocks_returned += 1;

        // Check for BlockId duplicates
        const id_was_present = try seen_block_ids.fetchPut(block.id, {});
        if (id_was_present != null) {
            std.debug.print("ERROR: Duplicate BlockId found: {any}\n", .{block.id});
            std.debug.print("Source URI: {s}\n", .{block.source_uri});
            try testing.expect(false); // Fail test on duplicate BlockId
        }

        // Check for content hash duplicates (different BlockIds with same content)
        const content_hash = std.hash_map.hashString(block.content);
        const content_was_present = try seen_content_hashes.fetchPut(content_hash, {});
        if (content_was_present != null) {
            std.debug.print("ERROR: Duplicate content hash found for BlockId: {any}\n", .{block.id});
            std.debug.print("Content: {s}\n", .{block.content});
            try testing.expect(false); // Fail test on duplicate content
        }
    }

    // Verify we got exactly the expected number of blocks
    try testing.expectEqual(@as(u32, test_blocks.len), total_blocks_returned);
    try testing.expectEqual(@as(u32, test_blocks.len), seen_block_ids.count());
    try testing.expectEqual(@as(u32, test_blocks.len), seen_content_hashes.count());
}

test "storage iterator consistency across multiple iterations" {
    var test_harness = try StorageHarness.init_and_startup(testing.allocator, "iterator_consistency_test");
    defer test_harness.deinit();

    // Create a larger set of test blocks to stress test the iterator
    var test_blocks = std.ArrayList(ContextBlock).init(testing.allocator);
    defer {
        for (test_blocks.items) |block| {
            testing.allocator.free(block.source_uri);
            testing.allocator.free(block.metadata_json);
            testing.allocator.free(block.content);
        }
        test_blocks.deinit();
    }

    // Generate test blocks programmatically
    const num_test_blocks = 50;
    var i: u32 = 0;
    while (i < num_test_blocks) : (i += 1) {
        const block = ContextBlock{
            .id = BlockId.from_u32(i + 100), // Offset to avoid conflicts with other tests
            .version = 1,
            .source_uri = try std.fmt.allocPrint(testing.allocator, "file://test_file_{d}.zig#L{d}-{d}", .{ i, i * 10, (i + 1) * 10 }),
            .metadata_json = try std.fmt.allocPrint(testing.allocator, "{{\"unit_type\":\"function\",\"unit_id\":\"test_file_{d}.zig:test_function_{d}\"}}", .{ i, i }),
            .content = try std.fmt.allocPrint(testing.allocator, "pub fn test_function_{d}() void {{}}", .{i}),
        };
        try test_blocks.append(block);
    }

    // Store all test blocks
    for (test_blocks.items) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Run iterator multiple times and verify consistent results
    const num_iterations = 3;
    var expected_block_ids: ?std.AutoHashMap(BlockId, void) = null;

    var iter_count: usize = 0;
    while (iter_count < num_iterations) : (iter_count += 1) {
        var current_iteration_ids = std.AutoHashMap(BlockId, void).init(testing.allocator);
        defer current_iteration_ids.deinit();

        var iterator = test_harness.storage_engine.iterate_all_blocks();
        var blocks_in_this_iteration: u32 = 0;

        while (try iterator.next()) |block| {
            blocks_in_this_iteration += 1;
            try current_iteration_ids.put(block.id, {});
        }

        // Verify consistent block count across iterations
        try testing.expectEqual(@as(u32, num_test_blocks), blocks_in_this_iteration);

        if (expected_block_ids == null) {
            // First iteration - save the block IDs as expected set
            expected_block_ids = std.AutoHashMap(BlockId, void).init(testing.allocator);
            var id_iter = current_iteration_ids.iterator();
            while (id_iter.next()) |entry| {
                try expected_block_ids.?.put(entry.key_ptr.*, {});
            }
        } else {
            // Subsequent iterations - verify identical set of BlockIds
            try testing.expectEqual(expected_block_ids.?.count(), current_iteration_ids.count());

            var expected_iter = expected_block_ids.?.iterator();
            while (expected_iter.next()) |entry| {
                try testing.expect(current_iteration_ids.contains(entry.key_ptr.*));
            }
        }
    }

    if (expected_block_ids) |*ids| {
        ids.deinit();
    }
}

test "storage iterator works correctly with parsed blocks" {
    var test_harness = try StorageHarness.init_and_startup(testing.allocator, "iterator_parsed_blocks_test");
    defer test_harness.deinit();

    // Use realistic parsed code to test iterator with actual ingestion pipeline
    const test_zig_content =
        \\const std = @import("std");
        \\
        \\pub fn unique_function_alpha() void {
        \\    const x = 42;
        \\}
        \\
        \\pub fn unique_function_beta() void {
        \\    const y = 24;
        \\}
        \\
        \\fn private_unique_function() void {
        \\    // Private function
        \\}
    ;

    var metadata_map = std.StringHashMap([]const u8).init(testing.allocator);
    defer metadata_map.deinit();

    const file_content = FileContent{
        .data = test_zig_content,
        .path = "iterator_test.zig",
        .content_type = "text/zig",
        .metadata = metadata_map,
        .timestamp_ns = @intCast(std.time.nanoTimestamp()),
    };

    const parse_config = ParseConfig{
        .include_function_bodies = true,
        .include_private = true,
        .include_tests = false,
        .max_function_body_size = 8192,
        .create_import_blocks = true, // Include imports to test more blocks
    };

    const blocks = try parse_file_to_blocks.parse_file_to_blocks(
        testing.allocator,
        file_content,
        "storage_dedup_test",
        parse_config,
    );
    defer testing.allocator.free(blocks);

    // Store parsed blocks
    for (blocks) |block| {
        try test_harness.storage_engine.put_block(block);
    }

    // Iterate and verify no duplicates in parsed blocks
    var seen_block_ids = std.AutoHashMap(BlockId, void).init(testing.allocator);
    defer seen_block_ids.deinit();

    var iterator = test_harness.storage_engine.iterate_all_blocks();
    var total_blocks: u32 = 0;

    while (try iterator.next()) |block| {
        total_blocks += 1;

        const was_present = try seen_block_ids.fetchPut(block.id, {});
        if (was_present != null) {
            std.debug.print("ERROR: Duplicate BlockId in parsed blocks: {any}\n", .{block.id});
            std.debug.print("Source: {s}\n", .{block.source_uri});
            std.debug.print("Metadata: {s}\n", .{block.metadata_json});
            try testing.expect(false);
        }
    }

    // Should find at least the 3 functions we defined (possibly more with imports)
    try testing.expect(total_blocks >= 3);
    try testing.expectEqual(total_blocks, seen_block_ids.count());

    // Verify the iterator returns exactly the number of blocks we stored
    try testing.expectEqual(@as(u32, blocks.len), total_blocks);
}
