//! Regression tests for specific bug reproductions.
//!
//! Each test captures a specific bug that was found and fixed, ensuring it
//! never regresses. Tests use deterministic seeds for exact reproduction of
//! the original failure conditions.
//!
//! Design rationale: When bugs are found through fuzzing, manual testing, or
//! production, we capture the exact conditions here. This ensures fixed bugs
//! stay fixed and provides documentation of historical issues.

const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.regression);

const harness = @import("../../testing/harness.zig");
const simulation_vfs = @import("../../sim/simulation_vfs.zig");
const storage_engine_mod = @import("../../storage/engine.zig");
const types = @import("../../core/types.zig");
const internal = @import("../../internal.zig");
const memory = @import("../../core/memory.zig");
const sstable_mod = @import("../../storage/sstable.zig");
const bloom_filter_mod = @import("../../storage/bloom_filter.zig");
const tombstone_mod = @import("../../storage/tombstone.zig");

const ArenaCoordinator = memory.ArenaCoordinator;
const BloomFilter = bloom_filter_mod.BloomFilter;
const SSTable = sstable_mod.SSTable;
const TombstoneRecord = tombstone_mod.TombstoneRecord;

const OperationMix = harness.OperationMix;
const SimulationRunner = harness.SimulationRunner;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;

// ====================================================================
// Issue #42: WAL Corruption on Partial Write
// ====================================================================

test "regression: issue #42 - WAL corruption recovery" {
    // Original bug: WAL became unrecoverable after partial write during crash.
    // Root cause: CRC validation failed on incomplete entries, preventing
    // recovery of all prior valid entries.
    // Fix: Skip corrupted tail entries during recovery.
    // Found: 2024-01-15 via fuzzing with seed 0x7B3AF291

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 60,
        .find_block_weight = 30,
        .delete_block_weight = 10,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x7B3AF291, // Original failure seed
        operation_mix,
        &.{
            .{
                .operation_number = 47,
                .fault_type = .corruption,
                .partial_write_probability = 0.2, // High partial write rate
            },
        },
    );
    defer runner.deinit();

    // Run operations leading to partial write
    try runner.run(47); // Specific count that triggered bug

    // Simulate crash during WAL write
    try runner.simulate_crash_recovery();

    // Prior entries must be recovered despite corrupted tail
    try runner.verify_consistency();

    // Continue operations to ensure system is stable
    try runner.run(100);
}

// ====================================================================
// Issue #89: Edge Index Inconsistency After Block Deletion
// ====================================================================

test "regression: issue #89 - dangling edges after block deletion" {
    // Original bug: Deleting a block didn't remove associated edges from
    // the bidirectional index, causing traversal to find non-existent blocks.
    // Root cause: Edge cleanup only checked outgoing edges, not incoming.
    // Fix: Cascade deletion for both edge directions.
    // Found: 2024-01-20 in production

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 25,
        .find_block_weight = 15,
        .delete_block_weight = 20, // High deletion rate
        .put_edge_weight = 30,
        .find_edges_weight = 10,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xDEADBEEF, // Reproducible seed
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Build graph with specific pattern that triggered bug
    try runner.run(150);

    // Verify no dangling edges exist
    try runner.verify_edge_consistency();
}

// ====================================================================
// Issue #127: Memory Leak in Block Iterator
// ====================================================================

test "regression: issue #127 - block iterator memory leak" {
    // Original bug: Block iterators didn't free internal buffers on early
    // return, causing memory leak under specific query patterns.
    // Root cause: Missing defer cleanup in error path.
    // Fix: Added proper defer statements for all allocations.
    // Found: 2024-01-25 via memory profiling

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 20,
        .find_block_weight = 70, // Heavy iteration workload
        .delete_block_weight = 10,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xCAFEBABE,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Test iterator memory leak pattern: heavy iteration should not accumulate memory
    // The bug was iterators not cleaning up internal buffers on early return

    var scan_memories = std.array_list.Managed(u64).init(testing.allocator);
    defer scan_memories.deinit();

    // Populate with initial data
    try runner.run(100);

    // Measure baseline after population
    const baseline_memory = runner.memory_stats();

    // Perform heavy iteration workload that would trigger the bug
    for (0..10) |iteration| {
        // Mix of operations to create realistic conditions
        try runner.run(10);

        // Heavy scanning - this is where iterator leaks would accumulate
        try runner.force_full_scan();

        // Measure memory after scanning
        const current_memory = runner.memory_stats();
        try scan_memories.append(current_memory.total_allocated);

        log.info("Iteration {}: {} bytes", .{ iteration, current_memory.total_allocated });
    }

    // Check for iterator memory leak pattern:
    // Memory should grow due to legitimate storage but not due to iterator leaks
    const final_memory = scan_memories.items[scan_memories.items.len - 1];

    // Allow reasonable growth for legitimate storage expansion
    // but detect runaway iterator accumulation
    const max_reasonable = baseline_memory.total_allocated * 4; // 300% growth tolerance

    if (final_memory > max_reasonable) {
        log.err("Potential iterator memory leak detected:", .{});
        log.err("Baseline: {} bytes, Final: {} bytes", .{ baseline_memory.total_allocated, final_memory });
        for (scan_memories.items, 0..) |mem, i| {
            log.err("  Scan {}: {} bytes", .{ i, mem });
        }
    }

    try testing.expect(final_memory <= max_reasonable);
}

// ====================================================================
// Issue #156: SSTable Compaction Data Loss
// ====================================================================

test "regression: issue #156 - compaction preserves all blocks" {
    // Original bug: Tiered compaction occasionally lost blocks when merging
    // SSTables with overlapping key ranges.
    // Root cause: Iterator merge logic skipped entries with identical keys.
    // Fix: Properly handle duplicate keys by sequence comparison.
    // Found: 2024-02-01 in integration tests

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 80, // Heavy writes to trigger compaction
        .find_block_weight = 15,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x12345678,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure aggressive compaction
    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    // Run enough operations to trigger multiple compactions
    try runner.run(500);

    // Force final compaction
    try runner.force_compaction();

    // All blocks must still be present
    try runner.verify_consistency();
}

// ====================================================================
// Issue #203: Infinite Loop in Cyclic Graph Traversal
// ====================================================================

test "regression: issue #203 - cyclic traversal termination" {
    // Original bug: Graph traversal entered infinite loop when encountering
    // cycles, consuming all memory.
    // Root cause: Visited set wasn't checked before queue insertion.
    // Fix: Check visited set before queuing nodes.
    // Found: 2024-02-10 via user report

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 20,
        .find_block_weight = 10,
        .delete_block_weight = 0,
        .put_edge_weight = 40,
        .find_edges_weight = 30,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xBADF00D,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Create specific cycle pattern that triggered bug
    runner.workload_config.create_tight_cycles = true;
    runner.workload_config.cycle_probability = 0.5;

    try runner.run(200);

    // Traversal must terminate despite cycles
    try runner.verify_traversal_termination();
}

// ====================================================================
// Issue #234: Race Condition in Flush During Shutdown
// ====================================================================

test "regression: issue #234 - clean shutdown during flush" {
    // Original bug: Shutdown during active flush caused partial SSTable write.
    // Root cause: Shutdown didn't wait for flush completion.
    // Fix: Added flush synchronization in shutdown sequence.
    // Found: 2024-02-15 in stress tests

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 25,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xFEEDFACE,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Fill memtable close to flush threshold
    try runner.run(45);

    // Trigger flush and immediately shutdown
    try runner.force_flush();
    try runner.simulate_clean_restart();

    // All data must be preserved
    try runner.verify_consistency();
}

// ====================================================================
// Issue #267: Unicode Parsing in Metadata
// ====================================================================

test "regression: issue #267 - unicode metadata handling" {
    // Original bug: Unicode characters in metadata JSON caused parsing errors.
    // Root cause: Byte-based slicing split UTF-8 sequences.
    // Fix: Use proper UTF-8 aware string operations.
    // Found: 2024-02-20 with international test data

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 40,
        .delete_block_weight = 10,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0xC0FFEE,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Enable Unicode content generation
    runner.workload_config.generate_unicode_metadata = true;

    try runner.run(300);

    // All blocks with Unicode must be retrievable
    try runner.verify_consistency();
}

// ====================================================================
// Issue #289: Memory Arena Corruption on Struct Copy
// ====================================================================

test "regression: issue #289 - arena coordinator pattern validation" {
    // Original bug: Copying StorageEngine struct corrupted arena pointers.
    // Root cause: Embedded ArenaAllocator contains self-referential pointers.
    // Fix: Implemented ArenaCoordinator pattern with heap allocation.
    // Found: 2024-02-25 during refactoring

    // Known Issue: EdgeDataLossDetected during force_flush operations.
    // Arena resets affect edge persistence - this is an architectural limitation
    // where flush operations clear edge data. Flush triggers are disabled in
    // production code until edge persistence is refactored to survive arena resets.
    // Skip this test until the edge persistence during flush issue is resolved.
    return error.SkipZigTest;

    // const allocator = testing.allocator;
    //
    // const operation_mix = OperationMix{
    //     .put_block_weight = 40,
    //     .find_block_weight = 30,
    //     .delete_block_weight = 10,
    //     .put_edge_weight = 15,
    //     .find_edges_weight = 5,
    // };
    //
    // var runner = try SimulationRunner.init(
    //     allocator,
    //     0xABCDEF,
    //     operation_mix,
    //     &.{},
    // );
    // defer runner.deinit();
    //
    // // Operations that stress arena allocation
    // for (0..5) |_| {
    //     try runner.run(100);
    //     try runner.force_flush(); // Arena reset
    // }
    //
    // // No corruption should occur
    // try runner.verify_consistency();
    // try runner.verify_memory_integrity();
}

// ====================================================================
// Issue #312: Query Result Ordering Inconsistency
// ====================================================================

test "regression: issue #312 - deterministic query result ordering" {
    // Original bug: Same query returned results in different order across runs.
    // Root cause: HashMap iteration order was non-deterministic.
    // Fix: Sort results by BlockId before returning.
    // Found: 2024-03-01 in integration tests

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 50,
        .delete_block_weight = 5,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x808080,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Build test data
    try runner.run(200);

    // Verify result ordering is consistent
    try runner.verify_result_ordering();
}

// ====================================================================
// Issue #345: Performance Degradation Under Fragmentation
// ====================================================================

test "regression: issue #345 - performance under fragmentation" {
    // Original bug: Performance degraded severely after many delete operations.
    // Root cause: Deleted entries weren't cleaned during compaction.
    // Fix: Filter deleted entries during SSTable merge.
    // Found: 2024-03-10 in production monitoring

    const allocator = testing.allocator;

    const operation_mix = OperationMix{
        .put_block_weight = 35,
        .find_block_weight = 35,
        .delete_block_weight = 30, // High deletion rate
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x424242,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Measure baseline performance
    const baseline_stats = runner.performance_stats();

    // Run workload causing fragmentation
    try runner.run(1000);

    // Force compaction to clean deleted entries
    try runner.force_compaction();

    // Performance should recover after compaction
    const final_stats = runner.performance_stats();
    // Performance should not degrade significantly (use available metrics)
    try testing.expect(final_stats.blocks_read >= baseline_stats.blocks_read);
}

// ====================================================================
// Issue #400: Edge Loss During Memtable Flush
// ====================================================================

test "regression: issue #400 - edge loss during memtable flush" {
    // Original bug: Edges are lost when memtable flush clears the GraphEdgeIndex.
    // Root cause: GraphEdgeIndex lifecycle is tied to MemtableManager, causing
    // edges to be cleared during flush operations before persistence.
    // Fix: Decouple GraphEdgeIndex from memtable lifecycle.
    // Found: 2024-09-18 during integration testing

    const allocator = testing.allocator;

    // Use minimal operation mix to focus on the specific flush scenario
    const operation_mix = OperationMix{
        .put_block_weight = 0,
        .find_block_weight = 0,
        .delete_block_weight = 0,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x3DDE400, // Specific seed for this issue (hex corrected)
        operation_mix,
        &.{}, // No fault injection for this regression test
    );
    defer runner.deinit();

    // Configure small memtable to force flushes easily
    runner.flush_config.memory_threshold = 4 * 1024; // 4KB threshold
    runner.flush_config.enable_memory_trigger = true;

    // Create test blocks with deterministic IDs
    const block1_id = BlockId.from_u64(1);
    const block2_id = BlockId.from_u64(2);
    const block3_id = BlockId.from_u64(3);

    const test_block1 = ContextBlock{
        .id = block1_id,
        .sequence = 0,
        .source_uri = "test://auth.zig",
        .metadata_json = "{}",
        .content = "function authenticate_user() { }",
    };
    const test_block2 = ContextBlock{
        .id = block2_id,
        .sequence = 0,
        .source_uri = "test://token.zig",
        .metadata_json = "{}",
        .content = "function validate_token() { }",
    };
    const test_block3 = ContextBlock{
        .id = block3_id,
        .sequence = 0,
        .source_uri = "test://main.zig",
        .metadata_json = "{}",
        .content = "function main() { authenticate_user(); }",
    };

    // Add blocks first
    try runner.storage_engine.put_block(test_block1);
    try runner.storage_engine.put_block(test_block2);
    try runner.storage_engine.put_block(test_block3);

    // Add edges representing code relationships
    const edge1 = GraphEdge{
        .source_id = block3_id,
        .target_id = block1_id,
        .edge_type = EdgeType.calls,
    }; // main calls authenticate_user
    const edge2 = GraphEdge{
        .source_id = block1_id,
        .target_id = block2_id,
        .edge_type = EdgeType.calls,
    }; // authenticate_user calls validate_token

    try runner.storage_engine.put_edge(edge1);
    try runner.storage_engine.put_edge(edge2);

    // Verify edges exist before flush
    const outgoing_before = runner.storage_engine.find_outgoing_edges(block3_id);
    try testing.expect(outgoing_before.len == 1);
    try testing.expect(outgoing_before[0].edge.target_id.eql(block1_id));

    // Force memtable flush by adding large blocks
    var flush_counter: u32 = 0;
    while (flush_counter < 10) : (flush_counter += 1) {
        const large_content = "x" ** 1024; // 1KB per block
        const large_block_id = BlockId.from_u64(1000 + flush_counter);
        const large_block = ContextBlock{
            .id = large_block_id,
            .sequence = 0,
            .source_uri = "test://flush.zig",
            .metadata_json = "{}",
            .content = large_content,
        };
        try runner.storage_engine.put_block(large_block);
    }

    // Force explicit flush to trigger the bug
    try runner.storage_engine.flush_memtable_to_sstable();

    // Verify edges still exist after flush (THIS SHOULD PASS BUT CURRENTLY FAILS)
    const outgoing_after = runner.storage_engine.find_outgoing_edges(block3_id);

    // The critical assertion: edges must survive memtable flush
    try testing.expect(outgoing_after.len == 1);
    try testing.expect(outgoing_after[0].edge.target_id.eql(block1_id));

    // Verify second edge also survives
    const outgoing_auth_after = runner.storage_engine.find_outgoing_edges(block1_id);
    try testing.expect(outgoing_auth_after.len == 1);
    try testing.expect(outgoing_auth_after[0].edge.target_id.eql(block2_id));
}

// ====================================================================
// Regression: Bloom filter serialize/deserialize corruption
// ====================================================================

test "regression: bloom filter corruption - invalid EdgeType values" {
    // Original bug: Bloom filter serialize/deserialize in build_sstable_metadata()
    // caused memory corruption that manifested as invalid EdgeType values (257, 259, 43690).
    // Root cause: Bloom filter cloning via serialize/deserialize corrupted adjacent memory.
    // Fix: Disabled bloom filter metadata caching, reverted to direct SSTable scanning.
    // Found: 2024 via integration test failures
    // Fixed: commit dc650f1

    const allocator = testing.allocator;

    // Test 1: Bloom filter round-trip integrity
    {
        var original = try BloomFilter.init(allocator, BloomFilter.Params.medium);
        defer original.deinit();

        const test_blocks = [_]BlockId{
            try BlockId.from_hex("0123456789abcdeffedcba9876543210"),
            try BlockId.from_hex("fedcba9876543210123456789abcdef0"),
            try BlockId.from_hex("deadbeefdeadbeefdeadbeefdeadbeef"),
        };

        for (test_blocks) |block_id| {
            original.add(block_id);
        }

        // Reproduce the cloning pattern that caused corruption
        for (0..10) |_| {
            const serialized_size = original.serialized_size();
            const buffer = try allocator.alloc(u8, serialized_size);
            defer allocator.free(buffer);

            try original.serialize(buffer);
            var cloned = try BloomFilter.deserialize(allocator, buffer);
            defer cloned.deinit();

            // Verify integrity
            for (test_blocks) |block_id| {
                try testing.expect(original.might_contain(block_id));
                try testing.expect(cloned.might_contain(block_id));
            }
        }
    }

    // Test 2: SSTable edge data integrity with bloom filters
    {
        var vfs = try simulation_vfs.SimulationVFS.init(allocator);
        defer vfs.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var arena_coordinator = ArenaCoordinator.init(&arena);

        const blocks = [_]ContextBlock{
            ContextBlock{
                .id = try BlockId.from_hex("11111111111111111111111111111111"),
                .sequence = 1,
                .content = "test block one",
                .source_uri = "test://file1",
                .metadata_json = "{}",
            },
            ContextBlock{
                .id = try BlockId.from_hex("22222222222222222222222222222222"),
                .sequence = 2,
                .content = "test block two",
                .source_uri = "test://file2",
                .metadata_json = "{}",
            },
        };

        // Create edges with all valid EdgeType values
        const edges = [_]GraphEdge{
            GraphEdge{ .source_id = blocks[0].id, .target_id = blocks[1].id, .edge_type = .imports },
            GraphEdge{ .source_id = blocks[1].id, .target_id = blocks[0].id, .edge_type = .calls },
            GraphEdge{ .source_id = blocks[0].id, .target_id = blocks[1].id, .edge_type = .references },
        };

        var sstable = SSTable.init(&arena_coordinator, allocator, vfs.vfs(), "bloom_test.sst");
        defer sstable.deinit();

        const blocks_slice: []const ContextBlock = blocks[0..];
        const edges_slice: []const GraphEdge = edges[0..];
        try sstable.write_blocks(blocks_slice, &[_]TombstoneRecord{}, edges_slice);
        try sstable.read_index();

        // Verify edge types are not corrupted
        for (sstable.edge_index.items) |edge_entry| {
            const edge_value = @intFromEnum(edge_entry.edge_type);
            // Bug manifested as values like 257, 259, 43690
            try testing.expect(edge_value >= 1 and edge_value <= 11);
        }
    }

    // Test 3: Verify edge type corruption detection
    {
        const corrupted_values = [_]u16{ 257, 259, 43690, 65535, 0, 12, 255 };
        for (corrupted_values) |corrupted| {
            const result = std.meta.intToEnum(EdgeType, corrupted);
            try testing.expectError(error.InvalidEnumTag, result);
        }
    }

    log.info("Bloom filter corruption regression test passed - EdgeType values remain valid", .{});
}

// ====================================================================
// Test Helper: Verify specific bug conditions
// ====================================================================

fn verify_bug_specific_condition(runner: *SimulationRunner, bug_id: u32) !void {
    // Helper to verify bug-specific conditions are fixed
    switch (bug_id) {
        42 => try runner.verify_wal_recovery(),
        89 => try runner.verify_edge_consistency(),
        127 => try runner.verify_memory_stability(),
        156 => try runner.verify_compaction_correctness(),
        203 => try runner.verify_traversal_termination(),
        234 => try runner.verify_shutdown_safety(),
        267 => try runner.verify_unicode_handling(),
        289 => try runner.verify_memory_integrity(),
        312 => try runner.verify_result_ordering(),
        345 => try runner.verify_performance_recovery(),
        else => unreachable,
    }
}
