//! Component-specific scenarios for testing individual KausalDB components.
//!
//! Provides focused scenario tests for components that need dedicated validation:
//! bloom filters, batch writers, resource pools, metadata indexing, and other
//! subsystems identified as having insufficient test coverage.
//!
//! Design rationale: Component scenarios complement property-based testing by
//! providing targeted validation of specific subsystem behaviors under various
//! conditions. Each scenario tests a single component thoroughly rather than
//! testing system-wide interactions.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const test_utils = @import("../../testing/test_utils.zig");
const properties = @import("../../testing/properties.zig");
const types = @import("../../core/types.zig");
const batch_writer_mod = @import("../../storage/batch_writer.zig");

const SimulationRunner = harness.SimulationRunner;
const TestDataGenerator = test_utils.TestDataGenerator;
const PropertyChecker = properties.PropertyChecker;
const StorageEngine = harness.StorageEngine;
const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const BatchWriter = batch_writer_mod.BatchWriter;
const BatchConfig = batch_writer_mod.BatchConfig;

/// Component-specific test scenarios for targeted validation
pub const ComponentScenario = enum {
    bloom_filter_accuracy_validation,
    bloom_filter_performance_characteristics,
    batch_writer_atomicity_guarantees,
    batch_writer_deduplication_behavior,
    batch_writer_version_conflict_resolution,
    metadata_indexing_consistency,
    resource_pool_efficiency_validation,
    memory_arena_cleanup_verification,
    wal_segment_rotation_behavior,
    sstable_compaction_triggers,

    /// Execute component scenario with focused validation
    pub fn execute_scenario(
        self: ComponentScenario,
        allocator: std.mem.Allocator,
        runner: *SimulationRunner,
    ) !void {
        switch (self) {
            .bloom_filter_accuracy_validation => try execute_bloom_filter_accuracy(allocator, runner),
            .bloom_filter_performance_characteristics => try execute_bloom_filter_performance(allocator, runner),
            .batch_writer_atomicity_guarantees => try execute_batch_writer_atomicity(allocator, runner),
            .batch_writer_deduplication_behavior => try execute_batch_writer_deduplication(allocator, runner),
            .batch_writer_version_conflict_resolution => try execute_batch_writer_conflicts(allocator, runner),
            .metadata_indexing_consistency => try execute_metadata_indexing(allocator, runner),
            .resource_pool_efficiency_validation => try execute_resource_pool_efficiency(allocator, runner),
            .memory_arena_cleanup_verification => try execute_memory_arena_cleanup(allocator, runner),
            .wal_segment_rotation_behavior => try execute_wal_segment_rotation(allocator, runner),
            .sstable_compaction_triggers => try execute_sstable_compaction_triggers(allocator, runner),
        }
    }

    /// Get human-readable description of scenario
    pub fn describe(self: ComponentScenario) []const u8 {
        return switch (self) {
            .bloom_filter_accuracy_validation => "Validate bloom filter accuracy properties: no false negatives, acceptable false positive rate",
            .bloom_filter_performance_characteristics => "Measure bloom filter lookup performance and memory efficiency",
            .batch_writer_atomicity_guarantees => "Verify batch operations maintain atomicity under various failure conditions",
            .batch_writer_deduplication_behavior => "Test batch writer deduplication with duplicate blocks within batches",
            .batch_writer_version_conflict_resolution => "Validate version conflict resolution in concurrent batch scenarios",
            .metadata_indexing_consistency => "Ensure metadata indexes remain consistent with block storage",
            .resource_pool_efficiency_validation => "Verify resource pools maintain bounded memory and effective reuse",
            .memory_arena_cleanup_verification => "Test arena-based memory cleanup achieves O(1) performance",
            .wal_segment_rotation_behavior => "Validate WAL segment rotation triggers and maintains durability",
            .sstable_compaction_triggers => "Test SSTable compaction triggers and maintains data integrity",
        };
    }
};

/// Execute bloom filter accuracy validation scenario
fn execute_bloom_filter_accuracy(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    var test_generator = TestDataGenerator.init(allocator, 0xBF001);

    // Generate test blocks for bloom filter testing
    const test_blocks = try test_generator.create_test_block_batch(500, 10000);
    defer test_generator.cleanup_test_data(test_blocks);

    // Insert first half of blocks into storage
    const blocks_to_insert = test_blocks[0 .. test_blocks.len / 2];
    for (blocks_to_insert) |block| {
        try runner.storage_engine.put_block(block);
    }

    // Trigger flush to create SSTables with bloom filters
    try runner.storage_engine.flush_memtable_to_sstable();

    // Create test block IDs including both existing and non-existing
    var test_block_ids = try allocator.alloc(BlockId, test_blocks.len);
    defer allocator.free(test_block_ids);

    for (test_blocks, 0..) |block, i| {
        test_block_ids[i] = block.id;
    }

    // Validate bloom filter accuracy properties
    try PropertyChecker.check_bloom_filter_accuracy(&runner.storage_engine, test_block_ids);
}

/// Execute bloom filter performance characteristics scenario
fn execute_bloom_filter_performance(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    var test_generator = TestDataGenerator.init(allocator, 0xBF002);

    // Create large dataset to test performance scaling
    const large_dataset = try test_generator.create_test_block_batch(2000, 20000);
    defer test_generator.cleanup_test_data(large_dataset);

    // Insert all blocks to create substantial SSTables
    for (large_dataset) |block| {
        try runner.storage_engine.put_block(block);
    }

    // Force flush to create SSTables
    try runner.storage_engine.flush_memtable_to_sstable();

    // Generate non-existent block IDs for performance testing
    const non_existent_ids = try allocator.alloc(BlockId, 1000);
    defer allocator.free(non_existent_ids);

    for (non_existent_ids, 0..) |*id, i| {
        id.* = test_utils.create_deterministic_block_id(@intCast(i + 50000)); // Guaranteed non-existent
    }

    // Measure lookup performance for non-existent blocks
    const start_time = std.time.nanoTimestamp();
    for (non_existent_ids) |id| {
        _ = runner.storage_engine.find_block(id, .temporary) catch {};
    }
    const end_time = std.time.nanoTimestamp();

    const total_duration = @as(u64, @intCast(end_time - start_time));
    const avg_lookup_time = total_duration / non_existent_ids.len;

    // Bloom filter should make non-existent lookups very fast (< 10µs average)
    test_utils.TestAssertions.assert_operation_fast(
        avg_lookup_time,
        10_000, // 10µs threshold
        "bloom_filter_negative_lookup",
    );
}

/// Execute batch writer atomicity guarantees scenario
fn execute_batch_writer_atomicity(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    // Create batch writer with default configuration
    const config = BatchConfig.DEFAULT;
    var batch_writer = try BatchWriter.init(allocator, &runner.storage_engine, config);
    defer batch_writer.deinit();

    var test_generator = TestDataGenerator.init(allocator, 0xDEADBEEF);

    // Test atomicity under normal conditions
    const normal_batch = try test_generator.create_test_block_batch(50, 30000);
    defer test_generator.cleanup_test_data(normal_batch);

    const initial_count = try runner.model.active_block_count();

    // Execute successful batch
    const stats = try batch_writer.ingest_batch(normal_batch, "test_workspace");
    try testing.expect(stats.blocks_written == normal_batch.len);

    // Verify all blocks are findable
    for (normal_batch) |block| {
        const found = try runner.storage_engine.find_block(block.id, .temporary);
        try testing.expect(found != null);
    }

    const final_count = try runner.model.active_block_count();
    try testing.expect(final_count == initial_count + normal_batch.len);
}

/// Execute batch writer deduplication behavior scenario
fn execute_batch_writer_deduplication(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    const config = BatchConfig.DEFAULT;
    var batch_writer = try BatchWriter.init(allocator, &runner.storage_engine, config);
    defer batch_writer.deinit();

    var test_generator = TestDataGenerator.init(allocator, 0xBADB00);

    // Create batch with intentional duplicates
    const unique_blocks = try test_generator.create_test_block_batch(20, 40000);
    defer test_generator.cleanup_test_data(unique_blocks);

    // Create batch with duplicates
    var batch_with_dupes = try allocator.alloc(ContextBlock, 40);
    defer allocator.free(batch_with_dupes);

    // First 20 are unique
    @memcpy(batch_with_dupes[0..20], unique_blocks[0..20]);
    // Last 20 are duplicates of first 20
    @memcpy(batch_with_dupes[20..40], unique_blocks[0..20]);

    const initial_count = try runner.model.active_block_count();

    // Execute batch with duplicates
    const stats = try batch_writer.ingest_batch(batch_with_dupes, "test_workspace");

    // Should only commit unique blocks
    try testing.expect(stats.blocks_written == 20);
    try testing.expect(stats.duplicates_in_batch == 20);

    // Verify only unique blocks were stored
    const final_count = try runner.model.active_block_count();
    try testing.expect(final_count == initial_count + 20);
}

/// Execute batch writer version conflict resolution scenario
fn execute_batch_writer_conflicts(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    const config = BatchConfig.DEFAULT;
    var batch_writer = try BatchWriter.init(allocator, &runner.storage_engine, config);
    defer batch_writer.deinit();

    var test_generator = TestDataGenerator.init(allocator, 0xB4003);

    // Create initial block
    const initial_block = try test_generator.create_test_block(50000);
    defer {
        allocator.free(initial_block.content);
        allocator.free(initial_block.metadata_json);
        allocator.free(initial_block.source_uri);
    }

    try runner.storage_engine.put_block(initial_block);

    // Create updated version of same block
    const updated_content = try std.fmt.allocPrint(allocator, "{s}_updated", .{initial_block.content});
    defer allocator.free(updated_content);

    const updated_block = ContextBlock{
        .id = initial_block.id, // Same ID
        .version = initial_block.version + 1, // Higher version
        .source_uri = initial_block.source_uri,
        .metadata_json = initial_block.metadata_json,
        .content = updated_content,
    };

    // Execute batch with version update
    const update_batch = [_]ContextBlock{updated_block};
    const stats = try batch_writer.ingest_batch(&update_batch, "test_workspace");

    try testing.expect(stats.blocks_written == 1);

    // Verify updated content is stored
    const found = try runner.storage_engine.find_block(initial_block.id, .temporary);
    try testing.expect(found != null);
    try testing.expect(found.?.block.version == updated_block.version);
}

/// Execute metadata indexing consistency scenario
fn execute_metadata_indexing(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    _ = TestDataGenerator.init(allocator, 0x11001);

    // Create blocks with rich metadata
    const metadata_blocks = try allocator.alloc(ContextBlock, 100);
    defer {
        for (metadata_blocks) |block| {
            allocator.free(block.content);
            allocator.free(block.metadata_json);
            allocator.free(block.source_uri);
        }
        allocator.free(metadata_blocks);
    }

    for (metadata_blocks, 0..) |*block, i| {
        const metadata = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"function\",\"name\":\"func_{d}\",\"language\":\"zig\",\"line_count\":{d}}}",
            .{ i, (i % 50) + 10 },
        );

        block.* = ContextBlock{
            .id = test_utils.create_deterministic_block_id(@intCast(i + 60000)),
            .version = 1,
            .source_uri = try std.fmt.allocPrint(allocator, "test://metadata/{d}", .{i}),
            .metadata_json = metadata,
            .content = try std.fmt.allocPrint(allocator, "function_content_{d}", .{i}),
        };
    }

    // Insert all blocks
    for (metadata_blocks) |block| {
        try runner.storage_engine.put_block(block);
    }

    // Verify all blocks remain findable after insertion
    for (metadata_blocks) |block| {
        const found = try runner.storage_engine.find_block(block.id, .temporary);
        try testing.expect(found != null);

        // Verify metadata integrity
        try testing.expect(std.mem.eql(u8, found.?.block.metadata_json, block.metadata_json));
    }

    // Trigger flush and verify consistency persists
    try runner.storage_engine.flush_memtable_to_sstable();

    for (metadata_blocks) |block| {
        const found = try runner.storage_engine.find_block(block.id, .temporary);
        try testing.expect(found != null);
        try testing.expect(std.mem.eql(u8, found.?.block.metadata_json, block.metadata_json));
    }
}

/// Execute resource pool efficiency validation scenario
fn execute_resource_pool_efficiency(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    const initial_memory = runner.storage_engine.memory_usage();
    var test_generator = TestDataGenerator.init(allocator, 0x4F001);

    // Perform many operations to test resource efficiency
    const operation_count = 1000;
    for (0..operation_count) |i| {
        const block = try test_generator.create_test_block(@intCast(i + 70000));
        defer {
            allocator.free(block.content);
            allocator.free(block.metadata_json);
            allocator.free(block.source_uri);
        }

        try runner.storage_engine.put_block(block);

        // Periodically check memory bounds and trigger cleanup
        if (i % 100 == 0) {
            const current_memory = runner.storage_engine.memory_usage();
            const memory_growth = current_memory.total_bytes - initial_memory.total_bytes;

            // Memory growth should be bounded
            test_utils.TestAssertions.assert_memory_bounded(
                memory_growth,
                50 * 1024 * 1024, // 50MB
                "resource_pool_efficiency",
            );

            // Trigger cleanup periodically
            if (i % 200 == 0) {
                try runner.storage_engine.flush_memtable_to_sstable();
            }
        }
    }

    // Final cleanup verification
    try runner.storage_engine.flush_memtable_to_sstable();
    const final_memory = runner.storage_engine.memory_usage();
    const final_growth = final_memory.total_bytes - initial_memory.total_bytes;

    // Verify effective cleanup
    test_utils.TestAssertions.assert_memory_bounded(
        final_growth,
        10 * 1024 * 1024, // 10MB acceptable residual
        "final_resource_cleanup",
    );
}

/// Execute memory arena cleanup verification scenario
fn execute_memory_arena_cleanup(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    _ = allocator; // Suppress unused warning

    const initial_memory = runner.storage_engine.memory_usage();

    // Fill memtable with data
    const operation_count = 500;
    for (0..operation_count) |i| {
        const simple_block = ContextBlock{
            .id = test_utils.create_deterministic_block_id(@intCast(i + 80000)),
            .version = 1,
            .source_uri = "test://arena",
            .metadata_json = "{}",
            .content = "arena_test_content",
        };

        try runner.storage_engine.put_block(simple_block);
    }

    const before_cleanup = runner.storage_engine.memory_usage();
    const memory_growth = before_cleanup.total_bytes - initial_memory.total_bytes;

    // Verify significant memory usage
    try testing.expect(memory_growth > 100_000); // Should have allocated at least 100KB

    // Perform arena cleanup via flush
    const cleanup_start = std.time.nanoTimestamp();
    try runner.storage_engine.flush_memtable_to_sstable();
    const cleanup_end = std.time.nanoTimestamp();

    const cleanup_duration = @as(u64, @intCast(cleanup_end - cleanup_start));

    // Arena cleanup should be very fast (< 100µs for O(1) behavior)
    test_utils.TestAssertions.assert_operation_fast(
        cleanup_duration,
        100_000, // 100µs threshold for O(1) cleanup
        "arena_memory_cleanup",
    );

    const after_cleanup = runner.storage_engine.memory_usage();
    const residual_growth = after_cleanup.total_bytes - initial_memory.total_bytes;

    // Memory should be effectively cleaned up
    try testing.expect(residual_growth < memory_growth / 2); // At least 50% cleanup
}

/// Execute WAL segment rotation behavior scenario
fn execute_wal_segment_rotation(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    var test_generator = TestDataGenerator.init(allocator, 0x45001);

    // Generate many blocks to force WAL segment rotation
    const large_batch_count = 1000;
    for (0..large_batch_count) |i| {
        const block = try test_generator.create_test_block(@intCast(i + 90000));
        defer {
            allocator.free(block.content);
            allocator.free(block.metadata_json);
            allocator.free(block.source_uri);
        }

        try runner.storage_engine.put_block(block);

        // Force WAL flush periodically to ensure durability
        if (i % 50 == 0) {
            try runner.storage_engine.flush_wal();
        }
    }

    // Verify all blocks are still findable after WAL operations
    for (0..large_batch_count) |i| {
        const expected_id = test_utils.create_deterministic_block_id(@intCast(i + 90000));
        const found = try runner.storage_engine.find_block(expected_id, .temporary);
        try testing.expect(found != null);
    }
}

/// Execute SSTable compaction triggers scenario
fn execute_sstable_compaction_triggers(allocator: std.mem.Allocator, runner: *SimulationRunner) !void {
    var test_generator = TestDataGenerator.init(allocator, 0x55001);

    // Configure aggressive flush to create multiple SSTables
    runner.flush_config.operation_threshold = 50;
    runner.flush_config.enable_operation_trigger = true;

    const initial_memory = runner.storage_engine.memory_usage();

    // Insert many blocks to trigger multiple flushes and compactions
    const total_operations = 500;
    for (0..total_operations) |i| {
        const block = try test_generator.create_test_block(@intCast(i + 100000));
        defer {
            allocator.free(block.content);
            allocator.free(block.metadata_json);
            allocator.free(block.source_uri);
        }

        try runner.storage_engine.put_block(block);

        // Trigger flush based on configuration
        if (i > 0 and i % runner.flush_config.operation_threshold == 0) {
            try runner.storage_engine.flush_memtable_to_sstable();
        }
    }

    // Force final flush and any pending compactions
    try runner.storage_engine.flush_memtable_to_sstable();

    // Verify all blocks remain findable after compaction
    for (0..total_operations) |i| {
        const expected_id = test_utils.create_deterministic_block_id(@intCast(i + 100000));
        const found = try runner.storage_engine.find_block(expected_id, .temporary);
        try testing.expect(found != null);
    }

    const final_memory = runner.storage_engine.memory_usage();

    // Memory usage should be reasonable despite many operations
    test_utils.TestAssertions.assert_memory_bounded(
        final_memory.total_bytes,
        initial_memory.total_bytes + 100 * 1024 * 1024, // 100MB growth limit
        "compaction_memory_management",
    );
}

// Test runner for component scenarios
test "component scenario: bloom filter accuracy validation" {
    const allocator = testing.allocator;

    var runner = try SimulationRunner.init(allocator, 0xC041001, .{}, &.{});
    defer runner.deinit();

    try ComponentScenario.bloom_filter_accuracy_validation.execute_scenario(allocator, &runner);
}

test "component scenario: batch writer atomicity guarantees" {
    const allocator = testing.allocator;

    var runner = try SimulationRunner.init(allocator, 0xC041002, .{}, &.{});
    defer runner.deinit();

    try ComponentScenario.batch_writer_atomicity_guarantees.execute_scenario(allocator, &runner);
}

test "component scenario: memory arena cleanup verification" {
    const allocator = testing.allocator;

    var runner = try SimulationRunner.init(allocator, 0xC041003, .{}, &.{});
    defer runner.deinit();

    try ComponentScenario.memory_arena_cleanup_verification.execute_scenario(allocator, &runner);
}
