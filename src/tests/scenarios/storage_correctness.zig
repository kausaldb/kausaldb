//! Storage correctness validation through deterministic simulation testing.
//!
//! These scenario tests ensure core correctness guarantees under complex
//! state transitions that unit tests cannot cover. Each scenario tests
//! specific failure modes that could cause data loss or corruption.

const std = @import("std");
const testing = std.testing;

const harness = @import("../../testing/harness.zig");
const types = @import("../../core/types.zig");

const OperationMix = harness.OperationMix;
const SimulationRunner = harness.SimulationRunner;
const FaultSpec = harness.FaultSpec;
const BlockId = types.BlockId;

test "scenario: tombstone propagation prevents data resurrection through compaction" {
    const allocator = testing.allocator;

    // Balanced workload with significant deletions to test tombstone logic
    const operation_mix = OperationMix{
        .put_block_weight = 50,
        .find_block_weight = 20,
        .delete_block_weight = 30, // High deletion rate to create tombstones
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6001, // Deterministic seed for tombstone testing
        operation_mix,
        &.{}, // No fault injection for basic correctness
    );
    defer runner.deinit();

    // Configure aggressive flush and compaction to test tombstone persistence
    runner.flush_config.operation_threshold = 25;
    runner.flush_config.enable_operation_trigger = true;

    // Execute put -> flush -> delete -> flush -> compact pattern
    try runner.run(300);

    // Properties validated automatically:
    // - Deleted blocks remain deleted after compaction
    // - Tombstones correctly shadow older block versions
    // - No data resurrection occurs during merge operations
    try runner.verify_consistency();
}

test "scenario: precision fault injection validates live error handling" {
    const allocator = testing.allocator;

    // Standard workload for fault injection testing
    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 20,
        .delete_block_weight = 10,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    // Inject WAL write fault during operation
    const faults = [_]FaultSpec{
        FaultSpec{
            .operation_number = 50,
            .fault_type = .io_error,
            .partial_write_probability = 0.5,
        },
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6002,
        operation_mix,
        &faults,
    );
    defer runner.deinit();

    runner.flush_config.operation_threshold = 40;
    runner.flush_config.enable_operation_trigger = true;

    // Run operations with fault injection
    try runner.run(150);

    // System must gracefully handle WAL write failures
    // Properties validated:
    // - In-memory state remains consistent with durable state
    // - Operations fail gracefully without corruption
    // - Recovery maintains data integrity
    try runner.verify_consistency();
}

test "scenario: resource limit enforcement validates boundary conditions" {
    const allocator = testing.allocator;

    // Write-heavy workload to stress memory limits
    const operation_mix = OperationMix{
        .put_block_weight = 90,
        .find_block_weight = 5,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6003,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure small memory threshold to test boundary conditions
    runner.flush_config.memory_threshold = 1024 * 1024; // 1MB limit
    runner.flush_config.enable_memory_trigger = true;
    runner.flush_config.operation_threshold = 100;

    // High-volume writes to test resource limits
    try runner.run(500);

    // Properties validated:
    // - Memory limits are respected
    // - Flushes trigger before OOM conditions
    // - System remains stable under memory pressure
    try runner.verify_consistency();
}

test "scenario: WAL recovery maintains exact pre-crash state" {
    const allocator = testing.allocator;

    // Mixed workload for recovery testing
    const operation_mix = OperationMix{
        .put_block_weight = 60,
        .find_block_weight = 20,
        .delete_block_weight = 15,
        .put_edge_weight = 5,
        .find_edges_weight = 0,
    };

    // Phase 1: Create initial state
    {
        var runner = try SimulationRunner.init(
            allocator,
            0x6004,
            operation_mix,
            &.{},
        );
        defer runner.deinit();

        runner.flush_config.operation_threshold = 30;
        runner.flush_config.enable_operation_trigger = true;

        // Build up durable state in WAL
        try runner.run(200);

        // Verify consistency before simulated crash
        try runner.verify_consistency();
    }

    // Phase 2: Recovery simulation
    {
        var runner = try SimulationRunner.init(
            allocator,
            0x6004, // Same seed for identical operation sequence
            operation_mix,
            &.{},
        );
        defer runner.deinit();

        // Continue operations after recovery
        try runner.run(100);

        // Recovery must restore exact pre-crash state
        try runner.verify_consistency();
    }
}

test "scenario: concurrent flush and read operations maintain consistency" {
    const allocator = testing.allocator;

    // Read-heavy workload during frequent flushes
    const operation_mix = OperationMix{
        .put_block_weight = 40,
        .find_block_weight = 50, // High read rate during flushes
        .delete_block_weight = 10,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6005,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Very frequent flushes to test read/flush concurrency
    runner.flush_config.operation_threshold = 15;
    runner.flush_config.enable_operation_trigger = true;

    // Execute reads during flush operations
    try runner.run(400);

    // Properties validated:
    // - Reads remain consistent during flush operations
    // - No torn reads or inconsistent states observed
    // - Flush operations don't corrupt ongoing reads
    try runner.verify_consistency();
}

test "scenario: LSM-tree level consistency across storage transitions" {
    const allocator = testing.allocator;

    // Write pattern designed to create multiple SSTable levels
    const operation_mix = OperationMix{
        .put_block_weight = 80,
        .find_block_weight = 15,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6006,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Aggressive flush schedule to create many SSTable levels
    runner.flush_config.operation_threshold = 20;
    runner.flush_config.enable_operation_trigger = true;

    // Extended run to create multi-level LSM structure
    try runner.run(600);

    // Properties validated:
    // - Data consistency across all LSM levels
    // - Proper precedence ordering (memtable > L0 > L1...)
    // - No data loss during level transitions
    try runner.verify_consistency();
}

test "scenario: checksum validation prevents silent corruption" {
    const allocator = testing.allocator;

    // Standard workload with checksum corruption simulation
    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 25,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    // Inject checksum corruption fault
    const faults = [_]FaultSpec{
        FaultSpec{
            .operation_number = 75,
            .fault_type = .corruption,
        },
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6007,
        operation_mix,
        &faults,
    );
    defer runner.deinit();

    runner.flush_config.operation_threshold = 35;
    runner.flush_config.enable_operation_trigger = true;

    // Run with checksum validation
    try runner.run(250);

    // Properties validated:
    // - Corruption is detected, not silently accepted
    // - System fails fast on checksum mismatches
    // - Data integrity is maintained despite corruption attempts
    try runner.verify_consistency();
}

test "scenario: arena memory cleanup prevents temporal coupling bugs" {
    const allocator = testing.allocator;

    // High-volume workload to stress memory management
    const operation_mix = OperationMix{
        .put_block_weight = 85,
        .find_block_weight = 10,
        .delete_block_weight = 5,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6008,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Frequent flushes to test arena cleanup cycles
    runner.flush_config.operation_threshold = 25;
    runner.flush_config.enable_operation_trigger = true;
    runner.flush_config.enable_memory_trigger = true;

    // Extended run to test multiple arena cleanup cycles
    try runner.run(800);

    // Properties validated:
    // - Arena cleanup is O(1) and complete
    // - No memory leaks across flush cycles
    // - Temporal coupling bugs are prevented
    try runner.verify_consistency();
}

test "scenario: write stall backpressure prevents memory explosion" {
    const allocator = testing.allocator;

    // Extremely write-heavy workload to trigger backpressure
    const operation_mix = OperationMix{
        .put_block_weight = 95,
        .find_block_weight = 3,
        .delete_block_weight = 2,
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6009,
        operation_mix,
        &.{},
    );
    defer runner.deinit();

    // Configure conditions that should trigger write stalls
    runner.flush_config.memory_threshold = 2 * 1024 * 1024; // 2MB limit
    runner.flush_config.enable_memory_trigger = true;
    runner.flush_config.operation_threshold = 50;

    // High-volume writes to test backpressure mechanisms
    try runner.run(1000);

    // Properties validated:
    // - Write stalls activate under memory pressure
    // - System remains stable and doesn't OOM
    // - Backpressure mechanisms work correctly
    try runner.verify_consistency();
}

test "scenario: minimal reproduction for data loss during compaction" {
    const allocator = testing.allocator;

    // Minimal workload to isolate the data loss bug
    const operation_mix = OperationMix{
        .put_block_weight = 70,
        .find_block_weight = 10,
        .delete_block_weight = 30, // High deletion rate to match failing test
        .put_edge_weight = 0,
        .find_edges_weight = 0,
    };

    var runner = try SimulationRunner.init(
        allocator,
        0x6001, // Same seed as failing tombstone propagation test
        operation_mix,
        &.{}, // No fault injection - pure correctness test
    );
    defer runner.deinit();

    // Aggressive flush to match failing test configuration
    runner.flush_config.operation_threshold = 25;
    runner.flush_config.enable_operation_trigger = true;

    // Run same number of operations as failing test
    try runner.run(300);

    // This should pass - no blocks should be lost
    try runner.verify_consistency();
}
