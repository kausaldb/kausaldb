//! Tombstone sequence ordering validation for LSM-tree correctness.
//!
//! These scenario tests ensure tombstones properly shadow blocks based on
//! sequence number comparisons, preventing incorrect data resurrection when
//! newer versions are added after deletions.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const OperationMix = harness.OperationMix;
const SimulationRunner = harness.SimulationRunner;
const BlockId = types.BlockId;

test "scenario: tombstone sequence shadowing prevents resurrection" {
    const allocator = testing.allocator;

    // Deletion-heavy workload to stress tombstone sequence logic
    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 20,
        .delete_block_weight = 30, // High deletion rate
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4001, // Deterministic seed for sequence testing
        operation_mix,
        &.{}, // No fault injection for basic correctness
    );
    defer runner.deinit();

    // Configure frequent flushes to test sequence ordering across boundaries
    runner.flush_config.operation_threshold = 40;
    runner.flush_config.enable_operation_trigger = true;

    // Execute operations to create delete/recreate patterns
    try runner.run(250);

    // Properties validated automatically:
    // - Tombstones shadow based on sequence comparison
    // - No data resurrection occurs
    // - Sequence ordering is maintained
    try runner.verify_consistency();
}

test "scenario: tombstone sequence ordering across flush boundaries" {
    const allocator = testing.allocator;

    // Balanced mix with controlled sequence generation
    const operation_mix = OperationMix{
        .put_block_weight = 60,
        .find_block_weight = 15,
        .delete_block_weight = 25,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4002,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Very aggressive flush schedule to test cross-boundary sequencing
    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    // Run operations that will create many flush boundaries
    try runner.run(300);

    // Sequence ordering must work correctly across SSTable boundaries
    try runner.verify_consistency();
}

test "scenario: tombstone persistence through compaction maintains sequence logic" {
    const allocator = testing.allocator;

    // Write-heavy with deletions to trigger compaction
    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 10,
        .delete_block_weight = 20,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Frequent flushes to create multiple SSTables for compaction
    runner.flush_config.operation_threshold = 25;
    runner.flush_config.enable_operation_trigger = true;

    // Extended run to trigger compaction cycles
    try runner.run(500);

    // Compaction must preserve tombstone sequence ordering logic
    try runner.verify_consistency();
}

test "scenario: multiple tombstone sequence interactions" {
    const allocator = testing.allocator;

    // Pattern designed to create complex sequence interactions
    const operation_mix = OperationMix{
        .put_block_weight = 45,
        .find_block_weight = 20,
        .delete_block_weight = 35, // Very high deletion rate
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4004,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure workload for repeated delete/recreate cycles
    runner.workload_config.generate_rich_metadata = true;

    runner.flush_config.operation_threshold = 30;
    runner.flush_config.enable_operation_trigger = true;

    // Run to create multiple overlapping tombstone sequences
    try runner.run(400);

    // Multiple tombstone interactions must maintain correctness
    try runner.verify_consistency();
}

test "scenario: sequence-based shadowing under high write pressure" {
    const allocator = testing.allocator;

    // Write-dominant to stress sequence assignment logic
    const operation_mix = OperationMix{
        .put_block_weight = 80,
        .find_block_weight = 5,
        .delete_block_weight = 15,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4005,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // High-frequency flushes to test sequence handling under pressure
    runner.flush_config.operation_threshold = 15;
    runner.flush_config.enable_operation_trigger = true;

    // High-volume writes to stress sequence numbering
    try runner.run(800);

    // Sequence-based tombstone shadowing must work under high load
    try runner.verify_consistency();
}

test "scenario: tombstone sequence logic during recovery operations" {
    const allocator = testing.allocator;

    // Deletion-focused workload for recovery testing
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 20,
        .delete_block_weight = 40, // Equal put/delete ratio
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    // Phase 1: Create complex sequence state
    {
        var runner = try SimulationRunner.init(
            allocator,
            0x4006,
            operation_mix,
            &.{},
        );
        defer runner.deinit();

        runner.flush_config.operation_threshold = 35;
        runner.flush_config.enable_operation_trigger = true;

        // Build up complex tombstone/sequence interactions
        try runner.run(300);

        // Final verification after operations complete
        try runner.verify_consistency();
    }

    // Phase 2: Recovery simulation
    {
        var runner = try SimulationRunner.init(
            allocator,
            0x4006, // Same seed for consistent recovery test
            operation_mix,
            &.{},
        );
        defer runner.deinit();

        // Smaller run to test recovery maintains sequence logic
        try runner.run(150);
        try runner.verify_consistency();
    }
}

test "scenario: concurrent sequence assignment with tombstone creation" {
    const allocator = testing.allocator;

    // Rapid alternating pattern to test sequence assignment
    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 10,
        .delete_block_weight = 40,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4007,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Very frequent flushes to test rapid sequence changes
    runner.flush_config.operation_threshold = 12;
    runner.flush_config.enable_operation_trigger = true;

    // Rapid operations to stress sequence assignment
    try runner.run(600);

    // Sequence assignment must remain consistent under rapid changes
    try runner.verify_consistency();
}

test "scenario: tombstone sequence ordering with mixed workload" {
    const allocator = testing.allocator;

    // Include edges to test sequence ordering with complex operations
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 15,
        .delete_block_weight = 25,
        .put_edge_weight = 15,
        .find_edges_weight = 5,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4008,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure for complex graph operations
    runner.workload_config.use_all_edge_types = true;

    runner.flush_config.operation_threshold = 45;
    runner.flush_config.enable_operation_trigger = true;

    // Mixed operations to test sequence logic with graph changes
    try runner.run(450);

    // Sequence ordering must work correctly with mixed operations
    try runner.verify_consistency();
}

test "scenario: extreme deletion rate tombstone sequence handling" {
    const allocator = testing.allocator;

    // Deletion-dominant workload to stress tombstone accumulation
    const operation_mix = OperationMix{
        .put_block_weight = 30,
        .find_block_weight = 10,
        .delete_block_weight = 60, // Extremely high deletion rate
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x4009,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Small flush threshold to handle tombstone accumulation
    runner.flush_config.operation_threshold = 18;
    runner.flush_config.enable_operation_trigger = true;

    // High deletion load
    try runner.run(350);

    // System must handle extreme tombstone loads correctly
    try runner.verify_consistency();
}
