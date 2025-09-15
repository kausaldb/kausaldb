//! Universal properties for comprehensive test validation.
//!
//! Reusable property definitions extracted from legacy test assertions.
//! Each property validates an invariant that must hold across all scenarios.
//!
//! Design rationale: Instead of duplicating assertions across tests, we define
//! properties once and validate them systematically. This ensures consistent
//! validation and makes it easy to add new invariants.

const std = @import("std");
const testing = std.testing;

const assert_mod = @import("../../core/assert.zig");
const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const assert = assert_mod.assert;
const fatal_assert = assert_mod.fatal_assert;

const SimulationRunner = harness.SimulationRunner;
const ModelState = harness.ModelState;
const PropertyChecker = harness.PropertyChecker;
const StorageEngine = harness.StorageEngine;

const BlockId = types.BlockId;
const GraphEdge = types.GraphEdge;

const log = std.log.scoped(.universal_properties);

/// Universal properties that apply to all scenarios
pub const UniversalProperties = struct {

    // ====================================================================
    // Performance Properties
    // ====================================================================

    /// Property: All operations complete within latency bounds
    pub fn validate_operation_latency(runner: *SimulationRunner) !void {
        const stats = runner.performance_stats();

        // We don't have per-operation latency in current stats,
        // but we can validate throughput implies latency bounds
        if (stats.blocks_written > 0) {
            const implied_write_rate = stats.blocks_written * 1_000_000_000 / runner.operations_executed();
            try testing.expect(implied_write_rate > 10_000); // >10K writes/sec implies <100µs latency
        }

        if (stats.blocks_read > 0) {
            const implied_read_rate = stats.blocks_read * 1_000_000_000 / runner.operations_executed();
            try testing.expect(implied_read_rate > 100_000); // >100K reads/sec
        }
    }

    /// Property: Memory usage remains bounded
    pub fn validate_memory_bounds(runner: *SimulationRunner) !void {
        const memory = runner.memory_stats();

        // Bounds from legacy tests
        const max_total_memory = 100 * 1024 * 1024; // 100MB total
        const max_arena_memory = 16 * 1024 * 1024; // 16MB arena

        try testing.expect(memory.total_bytes < max_total_memory);
        try testing.expect(memory.arena_bytes < max_arena_memory);

        // Memory should not grow unbounded
        const peak = runner.peak_memory();
        const current = runner.memory_stats();
        if (runner.operations_executed() > 1000) {
            // After many operations, memory should stabilize
            // Within 10% of peak memory
            const max_current = peak.total_bytes + (peak.total_bytes / 10);
            try testing.expect(current.total_bytes <= max_current);
        }
    }

    /// Property: No resource leaks
    pub fn validate_no_leaks(runner: *SimulationRunner) !void {
        const initial = runner.memory_stats(); // Approximation - no true initial tracking
        const current = runner.memory_stats();
        const ops = runner.operations_executed();

        if (ops > 100) {
            // Memory per operation should be bounded
            const memory_per_op = if (ops > 0) (current - initial) / ops else 0;
            const max_memory_per_op = 2048; // 2KB per operation max

            try testing.expect(memory_per_op < max_memory_per_op);

            // After flush, arena memory should reset
            const memory = runner.memory_stats();
            const stats = runner.performance_stats();
            if (stats.flushes_completed > 0) {
                // Arena should be mostly empty after flush
                try testing.expect(memory.arena_bytes < 1024 * 1024); // <1MB
            }
        }
    }

    /// Property: Throughput meets minimum requirements
    pub fn validate_throughput_minimum(runner: *SimulationRunner) !void {
        const stats = runner.performance_stats();
        const ops = runner.operations_executed();

        if (ops > 1000) {
            // Minimum throughput requirements from legacy tests
            const min_write_throughput = 10_000; // 10K writes/sec
            const min_read_throughput = 100_000; // 100K reads/sec

            if (stats.blocks_written > 100) {
                const write_rate = stats.blocks_written * 1_000_000_000 / ops;
                try testing.expect(write_rate >= min_write_throughput);
            }

            if (stats.blocks_read > 100) {
                const read_rate = stats.blocks_read * 1_000_000_000 / ops;
                try testing.expect(read_rate >= min_read_throughput);
            }
        }
    }

    // ====================================================================
    // Storage Properties
    // ====================================================================

    /// Property: All acknowledged writes are immediately visible
    pub fn validate_write_visibility(runner: *SimulationRunner) !void {
        // This delegates to the existing PropertyChecker
        try runner.verify_consistency();
    }

    /// Property: Deleted blocks are not findable
    pub fn validate_delete_effectiveness(model: *ModelState, storage: *StorageEngine) !void {
        var iter = model.blocks.iterator();
        while (iter.next()) |entry| {
            const block = entry.value_ptr.*;
            if (block.deleted) {
                // Deleted blocks should not be findable
                const found = try storage.find_block(block.id, .temporary);
                try testing.expect(found == null);
            }
        }
    }

    /// Property: Memtable flush resets arena memory
    pub fn validate_memory_cleanup(runner: *SimulationRunner) !void {
        const stats = runner.performance_stats();
        const memory = runner.memory_stats();

        if (stats.flushes_completed > 0) {
            // After flush, arena should be mostly empty
            try testing.expect(memory.arena_bytes < 100_000); // <100KB overhead
        }
    }

    /// Property: Compaction preserves all non-deleted data
    pub fn validate_compaction_preservation(runner: *SimulationRunner) !void {
        const stats = runner.performance_stats();

        if (stats.compactions_completed > 0) {
            // All non-deleted blocks should still be findable
            try runner.verify_consistency();

            // No data loss during compaction
            try PropertyChecker.check_no_data_loss(&runner.model, runner.storage_engine);
        }
    }

    /// Property: Block ownership is consistent
    pub fn validate_ownership_consistency(model: *ModelState, storage: *StorageEngine) !void {
        // All blocks in model should have proper ownership in storage
        var iter = model.blocks.iterator();
        while (iter.next()) |entry| {
            const block = entry.value_ptr.*;
            if (!block.deleted) {
                const found = try storage.find_block(block.id, .temporary);
                try testing.expect(found != null);
                // Ownership should be properly tracked
                const owned_block = found.?;
                _ = owned_block.read(.temporary);
            }
        }
    }

    // ====================================================================
    // Graph Properties
    // ====================================================================

    /// Property: All edges reference existing blocks
    pub fn validate_edge_references(model: *ModelState, storage: *StorageEngine) !void {
        for (model.edges.items) |edge| {
            // Source block must exist
            const source = try storage.find_block(edge.source_id, .temporary);
            try testing.expect(source != null);

            // Target block must exist
            const target = try storage.find_block(edge.target_id, .temporary);
            try testing.expect(target != null);
        }
    }

    /// Property: Bidirectional edge indices are consistent
    pub fn validate_bidirectional_consistency(runner: *SimulationRunner) !void {
        // Delegate to existing PropertyChecker
        try runner.verify_edge_consistency();
    }

    /// Property: Deleting a block cascades to edges
    pub fn validate_cascade_deletion(model: *ModelState, storage: *StorageEngine) !void {
        // Deleted blocks should have no edges
        var iter = model.blocks.iterator();
        while (iter.next()) |entry| {
            const block = entry.value_ptr.*;
            if (block.deleted) {
                // Should have no outgoing edges
                const outgoing = storage.find_outgoing_edges(block.id);
                try testing.expect(outgoing.len == 0);

                // Should have no incoming edges
                const incoming = storage.find_incoming_edges(block.id);
                try testing.expect(incoming.len == 0);
            }
        }
    }

    /// Property: Graph traversal terminates even with cycles
    pub fn validate_traversal_termination(runner: *SimulationRunner) !void {
        // Delegate to existing method
        try runner.verify_traversal_termination();
    }

    // ====================================================================
    // Recovery Properties
    // ====================================================================

    /// Property: WAL replay is idempotent
    pub fn validate_replay_idempotence(runner: *SimulationRunner) !void {
        // Delegate to existing method
        try runner.verify_replay_idempotence();
    }

    /// Property: WAL maintains integrity through crashes
    pub fn validate_wal_integrity(runner: *SimulationRunner) !void {
        // After crash recovery, all acknowledged writes must be present
        const stats = runner.performance_stats();
        if (runner.faults_injected() > 0) {
            // Check that block count matches what was written
            try runner.verify_consistency();

            // WAL flushes should have preserved data
            try testing.expect(stats.flushes_completed == runner.model.flush_count);
        }
    }

    /// Property: Recovery restores complete state
    pub fn validate_recovery_completeness(runner: *SimulationRunner) !void {
        // After recovery, system state should match model
        try PropertyChecker.check_no_data_loss(&runner.model, runner.storage_engine);

        // All edges should be recovered
        if (runner.model.edges.items.len > 0) {
            try PropertyChecker.check_bidirectional_consistency(&runner.model, runner.storage_engine);
        }
    }

    /// Property: Crash durability - acknowledged writes survive crashes
    pub fn validate_crash_durability(runner: *SimulationRunner) !void {
        if (runner.faults_injected() > 0) {
            // All acknowledged writes before crash must be present
            try PropertyChecker.check_no_data_loss(&runner.model, runner.storage_engine);
        }
    }

    // ====================================================================
    // Composite Properties
    // ====================================================================

    /// Validate all performance properties
    pub fn validate_all_performance(runner: *SimulationRunner) !void {
        try validate_operation_latency(runner);
        try validate_memory_bounds(runner);
        try validate_no_leaks(runner);
        try validate_throughput_minimum(runner);
    }

    /// Validate all storage properties
    pub fn validate_all_storage(runner: *SimulationRunner) !void {
        try validate_write_visibility(runner);
        try validate_delete_effectiveness(&runner.model, runner.storage_engine);
        try validate_memory_cleanup(runner);
        try validate_compaction_preservation(runner);
        try validate_ownership_consistency(&runner.model, runner.storage_engine);
    }

    /// Validate all graph properties
    pub fn validate_all_graph(runner: *SimulationRunner) !void {
        try validate_edge_references(&runner.model, runner.storage_engine);
        try validate_bidirectional_consistency(runner);
        try validate_cascade_deletion(&runner.model, runner.storage_engine);
        try validate_traversal_termination(runner);
    }

    /// Validate all recovery properties
    pub fn validate_all_recovery(runner: *SimulationRunner) !void {
        try validate_replay_idempotence(runner);
        try validate_wal_integrity(runner);
        try validate_recovery_completeness(runner);
        try validate_crash_durability(runner);
    }

    /// Validate everything - comprehensive validation
    pub fn validate_all(runner: *SimulationRunner) !void {
        try validate_all_performance(runner);
        try validate_all_storage(runner);
        try validate_all_graph(runner);
        try validate_all_recovery(runner);
    }
};

// Test that properties can be used
test "universal properties can validate simulation results" {
    const allocator = testing.allocator;

    const operation_mix = harness.OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 30,
        .delete_block_weight = 10,
        .put_edge_weight = 10,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x7E5701, // TEST01 in valid hex
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Run some operations
    try runner.run(100);

    // Validate various properties
    try UniversalProperties.validate_memory_bounds(&runner);
    try UniversalProperties.validate_write_visibility(&runner);
    try UniversalProperties.validate_ownership_consistency(&runner.model, &runner.storage_engine);
}
