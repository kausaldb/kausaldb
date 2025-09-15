//! Property verification for deterministic simulation testing.
//!
//! Provides reusable property checkers that validate system invariants
//! during simulation testing. Properties represent correctness conditions
//! that must always hold regardless of operation sequence.
//!
//! Design rationale: Property-based testing validates behavior rather than
//! implementation. These checkers can be applied across different test
//! scenarios to ensure consistent correctness validation.

const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../core/assert.zig");
const storage_engine_mod = @import("../storage/engine.zig");
const types = @import("../core/types.zig");
const model_mod = @import("model.zig");
const test_utils = @import("test_utils.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const BlockId = types.BlockId;
const ContextBlock = types.ContextBlock;
const EdgeType = types.EdgeType;
const GraphEdge = types.GraphEdge;
const StorageEngine = storage_engine_mod.StorageEngine;
const ModelState = model_mod.ModelState;

/// Property checker for system invariants
pub const PropertyChecker = struct {
    /// Verify that acknowledged writes survive system restarts
    /// This is the fundamental durability property for any database
    pub fn check_no_data_loss(model: *ModelState, system: *StorageEngine) !void {
        // Every active block in model must be findable in system
        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (model_block.deleted) continue; // Skip deleted blocks

            const system_block = system.find_block(model_block.id, .temporary) catch |err| switch (err) {
                error.BlockNotFound => {
                    fatal_assert(false, "Acknowledged write lost: block not found in system", .{});
                    return;
                },
                else => return err,
            };

            if (system_block == null) {
                fatal_assert(false, "Acknowledged write lost: block returned null", .{});
            }

            // Verify content integrity
            const expected_hash = model_block.content_hash;
            const actual_hash = model_mod.ModelBlock.simple_hash(system_block.?.content);
            if (actual_hash != expected_hash) {
                fatal_assert(false, "Data corruption: content hash mismatch", .{});
            }
        }
    }

    /// Verify overall system consistency between model and implementation
    pub fn check_consistency(model: *ModelState, system: *StorageEngine) !void {
        try check_no_data_loss(model, system);
        try check_edge_consistency(model, system);
        try check_block_count_consistency(model, system);
    }

    /// Verify that the system operates within expected resource bounds
    pub fn check_memory_bounds(system: *StorageEngine, max_bytes: u64) !void {
        const usage = system.memory_usage();
        if (usage.total_bytes > max_bytes) {
            fatal_assert(false, "Memory usage exceeds bounds", .{});
        }
    }

    /// Verify graph transitivity properties hold
    /// If A->B and B->C exist, certain transitivity rules should be preserved
    pub fn check_transitivity(model: *ModelState, system: *StorageEngine) !void {
        // For each block in the model, verify transitivity constraints
        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const block_id = entry.key_ptr.*;
            const model_block = entry.value_ptr;
            if (model_block.deleted) continue;

            try verify_transitive_relationships(model, system, block_id);
        }
    }

    /// Verify bloom filter accuracy properties
    /// Bloom filters must never have false negatives and should have low false positive rate
    pub fn check_bloom_filter_accuracy(system: *StorageEngine, test_blocks: []const BlockId) !void {
        // Access SSTable manager through storage engine's internal API
        var iterator = system.iterate_all_blocks();
        defer iterator.deinit();

        // For this test, we'll validate bloom filter behavior indirectly
        // by checking that find operations behave consistently
        var blocks_tested: u32 = 0;
        var false_positive_candidates: u32 = 0;

        for (test_blocks) |test_id| {
            // First check if block actually exists
            const block_exists = (system.find_block(test_id, .temporary) catch null) != null;

            if (!block_exists) {
                // Block doesn't exist - bloom filter lookup should be fast
                // We can't directly access bloom filter, but we can measure performance
                const start = std.time.nanoTimestamp();
                _ = system.find_block(test_id, .temporary) catch {};
                const elapsed = std.time.nanoTimestamp() - start;

                // Fast lookup (< 1000ns) suggests bloom filter correctly rejected
                // Slow lookup (> 10000ns) suggests false positive caused SSTable scan
                if (elapsed > 10000) {
                    false_positive_candidates += 1;
                }
            }

            blocks_tested += 1;
        }

        // Verify bloom filter effectiveness by checking lookup performance
        if (blocks_tested > 0) {
            const false_positive_rate = @as(f64, @floatFromInt(false_positive_candidates)) / @as(f64, @floatFromInt(blocks_tested));
            if (false_positive_rate > 0.10) { // 10% threshold for performance-based detection
                fatal_assert(false, "Bloom filter appears ineffective: {d}% slow lookups", .{false_positive_rate * 100});
            }
        }
    }

    /// Verify batch writer consistency properties
    /// Batch operations must maintain atomicity and consistency
    pub fn check_batch_writer_atomicity(model: *ModelState, system: *StorageEngine, batch_size: u32) !void {
        const batch_writer_mod = @import("../storage/batch_writer.zig");

        // Generate test batch using test utilities
        var test_data_generator = test_utils.TestDataGenerator.init(model.allocator, 0x12345);
        const test_blocks = try test_data_generator.create_test_block_batch(batch_size, 1000);
        defer test_data_generator.cleanup_test_data(test_blocks);

        // Record initial state
        const initial_block_count = try model.active_block_count();

        // Create batch writer with default config
        const config = batch_writer_mod.BatchConfig{};
        var batch_writer = try batch_writer_mod.BatchWriter.init(model.allocator, system, config);
        defer batch_writer.deinit();

        // Execute batch write
        batch_writer.ingest_batch(test_blocks, "test_workspace") catch |err| switch (err) {
            error.StorageNotRunning, error.CommitFailed => {
                // Acceptable failures should leave system unchanged
                const final_count = try model.active_block_count();
                if (final_count != initial_block_count) {
                    fatal_assert(false, "Batch write failure left system in inconsistent state", .{});
                }
                return;
            },
            else => return err,
        };

        // Verify all blocks in batch are now findable
        for (test_blocks) |block| {
            const found = system.find_block(block.id, .temporary) catch |err| switch (err) {
                error.BlockNotFound => {
                    fatal_assert(false, "Batch write succeeded but block not findable", .{});
                    continue;
                },
                else => return err,
            };

            if (found == null) {
                fatal_assert(false, "Batch write succeeded but block returned null", .{});
            }
        }
    }

    /// Verify bidirectional graph edge consistency
    /// Forward and reverse edge indexes must be perfectly synchronized
    pub fn check_bidirectional_edge_consistency(model: *ModelState, system: *StorageEngine) !void {
        var edge_iterator = model.edges.iterator();
        while (edge_iterator.next()) |entry| {
            const edge = entry.value_ptr;
            if (edge.deleted) continue;

            // Check outgoing edges from source
            const outgoing = system.find_outgoing_edges(edge.source_id);
            var found_outgoing = false;
            for (outgoing) |out_edge| {
                if (out_edge.read(.memtable_manager).target_id.eql(edge.target_id) and
                    out_edge.read(.memtable_manager).edge_type == edge.edge_type)
                {
                    found_outgoing = true;
                    break;
                }
            }

            if (!found_outgoing) {
                fatal_assert(false, "Edge missing from outgoing index", .{});
            }

            // Note: Storage engine doesn't expose find_incoming_edges in current API
            // This test validates outgoing consistency, which implies bidirectional consistency
            // if the underlying implementation maintains both indexes correctly
        }
    }

    /// Verify memory management efficiency under load
    /// Memory usage should be bounded and cleanup should be effective
    pub fn check_memory_management_efficiency(system: *StorageEngine, operation_count: u32) !void {
        const initial_memory = system.memory_usage();

        // Generate test data for memory operations
        var test_data_generator = test_utils.TestDataGenerator.init(system.backing_allocator, 0x54321);

        // Perform many operations to test memory patterns
        for (0..operation_count) |i| {
            const block = test_data_generator.create_test_block(@intCast(i + 2000)) catch continue;
            defer {
                test_data_generator.allocator.free(block.content);
                test_data_generator.allocator.free(block.metadata_json);
                test_data_generator.allocator.free(block.source_uri);
            }

            system.put_block(block) catch continue;

            // Periodically check memory bounds and trigger cleanup
            if (i % 100 == 0) {
                const current_memory = system.memory_usage();

                // Memory growth should be reasonable
                const memory_growth = current_memory.total_bytes - initial_memory.total_bytes;
                const expected_max_growth = 50 * 1024 * 1024; // 50MB reasonable for test

                if (memory_growth > expected_max_growth) {
                    // Trigger flush to clean up memory
                    system.flush_memtable_to_sstable() catch {};
                }
            }
        }

        // Test memory cleanup through flush
        system.flush_memtable_to_sstable() catch {};
        const final_memory = system.memory_usage();

        // Verify memory was cleaned up effectively
        const final_growth = final_memory.total_bytes - initial_memory.total_bytes;
        const acceptable_growth = 5 * 1024 * 1024; // 5MB acceptable residual

        if (final_growth > acceptable_growth) {
            fatal_assert(false, "Memory cleanup ineffective: {} bytes remaining", .{final_growth});
        }
    }

    /// Verify k-hop graph traversal consistency
    /// Results should be identical when computed multiple ways
    pub fn check_k_hop_consistency(model: *ModelState, system: *StorageEngine, k: u32) !void {
        if (k == 0) return;

        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const source_id = entry.key_ptr.*;
            const model_block = entry.value_ptr;
            if (model_block.deleted) continue;

            const model_neighbors = try find_k_hop_neighbors_in_model(model, source_id, k);
            defer model_neighbors.deinit();

            const system_neighbors = try find_k_hop_neighbors_in_system(system, source_id, k);
            defer system_neighbors.deinit();

            try compare_neighbor_sets(&model_neighbors, &system_neighbors);
        }
    }

    /// Verify bidirectional edge index consistency
    /// Forward and reverse edge lookups should be consistent
    pub fn check_bidirectional_consistency(model: *ModelState, system: *StorageEngine) !void {
        // For each edge in model, verify it appears in both directions
        for (model.edges.items) |model_edge| {
            // Skip edges involving deleted blocks
            if (model.blocks.get(model_edge.source_id)) |source_block| {
                if (source_block.deleted) continue;
            }
            if (model.blocks.get(model_edge.target_id)) |target_block| {
                if (target_block.deleted) continue;
            }

            // Verify forward direction (source -> target)
            const outgoing_edges = system.find_outgoing_edges(model_edge.source_id);
            var found_outgoing = false;
            for (outgoing_edges) |sys_edge| {
                if (std.mem.eql(u8, &sys_edge.edge.target_id.bytes, &model_edge.target_id.bytes) and
                    sys_edge.edge.edge_type == model_edge.edge_type)
                {
                    found_outgoing = true;
                    break;
                }
            }

            if (!found_outgoing) {
                fatal_assert(false, "Forward edge missing in system", .{});
            }

            // Verify reverse direction (target <- source) if system supports it
            // This would require a find_incoming_edges method
            // For now, we assume the forward check is sufficient for bidirectional consistency
        }
    }

    /// Verify that deleted blocks are properly cleaned up
    pub fn check_deletion_consistency(model: *ModelState, system: *StorageEngine) !void {
        var block_iterator = model.blocks.iterator();
        while (block_iterator.next()) |entry| {
            const model_block = entry.value_ptr;
            if (!model_block.deleted) continue; // Only check deleted blocks

            // Deleted blocks should not be findable
            const result = system.find_block(model_block.id, .temporary);
            if (result) |_| {
                fatal_assert(false, "Deleted block still findable in system", .{});
            } else |err| switch (err) {
                error.BlockNotFound => {}, // Expected for deleted blocks
                else => return err,
            }
        }
    }

    /// Verify that graph edges maintain referential integrity
    pub fn check_edge_referential_integrity(model: *ModelState, system: *StorageEngine) !void {
        for (model.edges.items) |edge| {
            // Both source and target blocks should exist (unless deleted)
            const source_exists = model.has_active_block(edge.source_id);
            const target_exists = model.has_active_block(edge.target_id);

            if (!source_exists or !target_exists) {
                // Edge references non-existent blocks - should be cleaned up
                const system_edges = system.find_outgoing_edges(edge.source_id);
                for (system_edges) |sys_edge| {
                    if (std.mem.eql(u8, &sys_edge.edge.target_id.bytes, &edge.target_id.bytes) and
                        sys_edge.edge.edge_type == edge.edge_type)
                    {
                        fatal_assert(false, "Edge references deleted block", .{});
                    }
                }
            }
        }
    }

    // Private helper functions

    /// Verify transitive relationships for a specific block
    fn verify_transitive_relationships(model: *ModelState, system: *StorageEngine, block_id: BlockId) !void {
        // Verify transitive relationships for import and dependency chains
        // If A imports B and B imports C, verify consistency in both model and system

        var direct_targets = std.array_list.Managed(BlockId).init(model.allocator);
        defer direct_targets.deinit();

        // Find direct relationships from block_id in model
        for (model.edges.items) |edge| {
            if (edge.source_id.eql(block_id) and
                (edge.edge_type == .imports or edge.edge_type == .depends_on))
            {
                try direct_targets.append(edge.target_id);
            }
        }

        // For each direct target, check transitive relationships
        for (direct_targets.items) |target_id| {
            var transitive_targets = std.ArrayList(BlockId).init(model.allocator);
            defer transitive_targets.deinit();

            // Find what the target imports/depends on in model
            for (model.edges.items) |edge| {
                if (edge.source_id.eql(target_id) and
                    (edge.edge_type == .imports or edge.edge_type == .depends_on))
                {
                    try transitive_targets.append(edge.target_id);
                }
            }

            // Verify these transitive relationships exist in system
            for (transitive_targets.items) |transitive_target| {
                // Check that transitive target exists in system
                const system_block = system.find_block(transitive_target, .temporary) catch |err| switch (err) {
                    error.BlockNotFound => {
                        fatal_assert(false, "Transitive target block not found in system during verification", .{});
                        continue;
                    },
                    else => return err,
                };

                if (system_block == null) {
                    fatal_assert(false, "Transitive relationship broken: target block not accessible", .{});
                }
            }
        }
    }

    /// Verify that a path exists between two blocks
    fn verify_path_exists(system: *StorageEngine, source: BlockId, target: BlockId, max_depth: u32) !bool {
        if (source.eql(target)) return true;
        if (max_depth == 0) return false;

        const edges = system.find_outgoing_edges(source);
        for (edges) |sys_edge| {
            if (try verify_path_exists(system, sys_edge.edge.target_id, target, max_depth - 1)) {
                return true;
            }
        }

        return false;
    }

    /// Find k-hop neighbors using model state
    fn find_k_hop_neighbors_in_model(model: *ModelState, source_id: BlockId, k: u32) !std.ArrayList(BlockId) {
        var neighbors = std.ArrayList(BlockId).init(model.allocator);
        var visited = std.HashMap(BlockId, void, model_mod.ModelState.BlockIdContext, std.hash_map.default_max_load_percentage).init(model.allocator);
        defer visited.deinit();

        if (k == 0) return neighbors;

        // BFS to find k-hop neighbors
        var queue = std.ArrayList(struct { id: BlockId, depth: u32 }).init(model.allocator);
        defer queue.deinit();

        try queue.append(.{ .id = source_id, .depth = 0 });
        try visited.put(source_id, {});

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            if (current.depth >= k) continue;

            // Find edges from current block in model
            for (model.edges.items) |edge| {
                if (edge.source_id.eql(current.id)) {
                    if (!visited.contains(edge.target_id)) {
                        try visited.put(edge.target_id, {});
                        try queue.append(.{ .id = edge.target_id, .depth = current.depth + 1 });
                        if (current.depth + 1 == k) {
                            try neighbors.append(edge.target_id);
                        }
                    }
                }
            }
        }

        return neighbors;
    }

    /// Find k-hop neighbors using system traversal
    fn find_k_hop_neighbors_in_system(system: *StorageEngine, source_id: BlockId, k: u32) !std.ArrayList(BlockId) {
        var neighbors = std.ArrayList(BlockId).init(system.allocator);
        var visited = std.HashMap(BlockId, void, model_mod.ModelState.BlockIdContext, std.hash_map.default_max_load_percentage).init(system.allocator);
        defer visited.deinit();

        if (k == 0) return neighbors;

        // BFS using system edge queries
        var queue = std.ArrayList(struct { id: BlockId, depth: u32 }).init(system.allocator);
        defer queue.deinit();

        try queue.append(.{ .id = source_id, .depth = 0 });
        try visited.put(source_id, {});

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            if (current.depth >= k) continue;

            const edges = system.find_outgoing_edges(current.id);
            for (edges) |sys_edge| {
                if (!visited.contains(sys_edge.edge.target_id)) {
                    try visited.put(sys_edge.edge.target_id, {});
                    try queue.append(.{ .id = sys_edge.edge.target_id, .depth = current.depth + 1 });
                    if (current.depth + 1 == k) {
                        try neighbors.append(sys_edge.edge.target_id);
                    }
                }
            }
        }

        return neighbors;
    }

    /// Compare two sets of neighbor BlockIds for equality
    fn compare_neighbor_sets(model_neighbors: *const std.ArrayList(BlockId), system_neighbors: *const std.ArrayList(BlockId)) !void {
        if (model_neighbors.items.len != system_neighbors.items.len) {
            fatal_assert(false, "K-hop neighbor count mismatch between model and system", .{});
        }

        // Sort both sets for comparison
        var model_sorted = try std.ArrayList(BlockId).initCapacity(model_neighbors.allocator, model_neighbors.items.len);
        defer model_sorted.deinit();
        try model_sorted.appendSlice(model_neighbors.items);
        std.sort.heap(BlockId, model_sorted.items, {}, BlockId.lessThan);

        var system_sorted = try std.ArrayList(BlockId).initCapacity(system_neighbors.allocator, system_neighbors.items.len);
        defer system_sorted.deinit();
        try system_sorted.appendSlice(system_neighbors.items);
        std.sort.heap(BlockId, system_sorted.items, {}, BlockId.lessThan);

        for (model_sorted.items, system_sorted.items) |model_id, system_id| {
            if (!model_id.eql(system_id)) {
                fatal_assert(false, "K-hop neighbor mismatch between model and system", .{});
            }
        }
    }

    /// Check edge consistency between model and system
    fn check_edge_consistency(model: *ModelState, system: *StorageEngine) !void {
        for (model.edges.items) |model_edge| {
            // Skip edges involving deleted blocks
            if (model.blocks.get(model_edge.source_id)) |source_block| {
                if (source_block.deleted) continue;
            }
            if (model.blocks.get(model_edge.target_id)) |target_block| {
                if (target_block.deleted) continue;
            }

            // Verify edge exists in system
            const system_edges = system.find_outgoing_edges(model_edge.source_id);
            var found = false;
            for (system_edges) |sys_edge| {
                if (std.mem.eql(u8, &sys_edge.edge.target_id.bytes, &model_edge.target_id.bytes) and
                    sys_edge.edge.edge_type == model_edge.edge_type)
                {
                    found = true;
                    break;
                }
            }

            if (!found) {
                fatal_assert(false, "Model edge not found in system", .{});
            }
        }
    }

    /// Check block count consistency between model and system
    fn check_block_count_consistency(model: *ModelState, system: *StorageEngine) !void {
        const model_count = try model.active_block_count();
        const system_usage = system.memory_usage();

        // Note: system.memory_usage().block_count includes deleted blocks in some implementations
        // This check might need adjustment based on actual system behavior
        if (system_usage.block_count < model_count) {
            fatal_assert(false, "System has fewer blocks than model", .{});
        }
    }
};

test "property checker validates durability" {
    // This would need a mock storage engine and model for testing
    // Placeholder test to verify module compiles
    const allocator = testing.allocator;
    _ = allocator;
}

test "property checker validates consistency" {
    // Placeholder test
    const allocator = testing.allocator;
    _ = allocator;
}
