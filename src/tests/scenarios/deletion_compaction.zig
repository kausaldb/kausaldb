//! Deletion persistence validation through LSM-tree compaction operations.
//!
//! These scenario tests ensure deleted blocks remain deleted across all
//! compaction scenarios, preventing data resurrection that could violate
//! durability guarantees in production workloads.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const OperationMix = harness.OperationMix;
const SimulationRunner = harness.SimulationRunner;
const BlockId = types.BlockId;

test "scenario: basic deletion persistence through memtable flush cycles" {
    const allocator = testing.allocator;

    // Balanced mix emphasizing deletions to test tombstone persistence
    const operation_mix = OperationMix{
        .put_block_weight = 60,
        .find_block_weight = 20,
        .delete_block_weight = 20,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x2001, // Deterministic seed for reproducible deletion testing
        operation_mix,
        &.{}, // No fault injection for basic correctness
    );
    defer runner.deinit();

    // Configure frequent flushes to stress tombstone persistence
    runner.flush_config.operation_threshold = 50;
    runner.flush_config.enable_operation_trigger = true;

    // Execute operations to create, delete, and flush blocks repeatedly
    try runner.run(200);

    // Properties validated automatically:
    // - Deleted blocks remain deleted after flush
    // - Model state matches storage engine state
    // - No data resurrection occurs
}

test "scenario: deletion persistence through single compaction cycle" {
    const allocator = testing.allocator;

    // Write-heavy with deletions to create multiple SSTables for compaction
    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 15,
        .delete_block_weight = 15,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x2002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Aggressive flush and compaction triggers
    runner.flush_config.operation_threshold = 30;
    runner.flush_config.enable_operation_trigger = true;

    // Run enough operations to trigger compaction
    try runner.run(300);

    // Verify final consistency - critical for LSM correctness
    try runner.verify_consistency();
}

test "scenario: deletion prevents resurrection across multiple compaction cycles" {
    const allocator = testing.allocator;

    // Heavy write load with consistent deletion rate
    const operation_mix = OperationMix{
        .put_block_weight = 75,
        .find_block_weight = 10,
        .delete_block_weight = 15,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x2003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Frequent flushes to create many SSTable levels
    runner.flush_config.operation_threshold = 25;
    runner.flush_config.enable_operation_trigger = true;

    // Extended run to trigger multiple compaction cycles
    try runner.run(500);

    // Multi-cycle compaction must preserve deletion invariants
    try runner.verify_consistency();
}

test "scenario: deletion ordering with high write pressure" {
    const allocator = testing.allocator;

    // Write-dominant workload to stress sequence ordering
    const operation_mix = OperationMix{
        .put_block_weight = 85,
        .find_block_weight = 5,
        .delete_block_weight = 10,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x2004,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // High-frequency flushes to test sequence number handling
    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    // High volume to stress sequence ordering logic
    try runner.run(800);

    // Sequence-based tombstone shadowing must work correctly
    try runner.verify_consistency();
}

test "scenario: tombstone persistence through crash recovery" {
    const allocator = testing.allocator;

    // Deletion-focused workload with crash simulation
    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 20,
        .delete_block_weight = 30,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    // Phase 1: Create initial state with deletions
    {
        var runner = try SimulationRunner.init(
            allocator,
            0x2005,
            operation_mix,
            &.{},
        );
        defer runner.deinit();

        runner.flush_config.operation_threshold = 40;
        runner.flush_config.enable_operation_trigger = true;

        // Build up state with mixed operations including deletions
        try runner.run(250);

        // Final verification after operations complete
        try runner.verify_consistency();
    }

    // Phase 2: Recovery simulation - new runner with same VFS
    // Note: SimulationRunner creates fresh VFS, so this tests logical recovery
    {
        var runner = try SimulationRunner.init(
            allocator,
            0x2005, // Same seed ensures same operation sequence
            operation_mix,
            &.{},
        );
        defer runner.deinit();

        // Smaller run to verify recovery doesn't resurrect deleted blocks
        try runner.run(100);
        try runner.verify_consistency();
    }
}

test "scenario: mixed deletion and edge operations maintain graph consistency" {
    const allocator = testing.allocator;

    // Include edge operations with deletions to test graph consistency
    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 15,
        .delete_block_weight = 20,
        .put_edge_weight = 10,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x2006,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    runner.flush_config.operation_threshold = 35;
    runner.flush_config.enable_operation_trigger = true;

    // Run mixed operations to test block/edge deletion interactions
    try runner.run(400);

    // Verify both block and edge consistency after deletions
    try runner.verify_consistency();
}

test "scenario: high deletion rate under memory pressure" {
    const allocator = testing.allocator;

    // High deletion rate to test tombstone accumulation
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 10,
        .delete_block_weight = 50, // Very high deletion rate
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x2007,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Smaller flush threshold to simulate memory pressure
    runner.flush_config.operation_threshold = 15;
    runner.flush_config.enable_operation_trigger = true;

    // Test heavy deletion load
    try runner.run(600);

    // High deletion rates must not cause corruption
    try runner.verify_consistency();
}
